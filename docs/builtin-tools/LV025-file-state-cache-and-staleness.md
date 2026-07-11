<!-- more -->

## 一、 问题引入

当 Claude 编辑了一个文件之后，下一次又要修改同一个文件时，它怎么记得之前修改过哪里？怎么知道文件当前的状态？是否每次都重新读取一遍？尤其是一个文件被多次修改后，如何确保每次修改的是最新内容，而不是覆盖用户在编辑器中的手动改动？

这些问题的答案都指向同一个核心机制：**文件状态缓存（`FileStateCache`）+ staleness 检测**。本文从源码出发，完整梳理 Read、Edit、Write 三个工具如何通过共享的内存缓存协同工作，确保每次编辑都基于最新内容。

### 1. 核心结论

- 不是单纯靠模型记忆，而是用一个内存中的 `FileStateCache`（LRU 缓存）跟踪每个文件的"已知基线"，存储 `{content, timestamp, offset, limit}`。
- 每次编辑前都会**从磁盘重新读取文件内容**来做 `old_string` 匹配，同时用 `mtime`（文件修改时间戳）比对来检测文件是否被外部改动。
- 编辑成功后立即把新内容和新 `mtime` 写回缓存，作为下一次操作的基线。
- 通过 `validateInput` 与 `call` 两道 staleness 检查，防止权限校验与实际写盘之间的竞态窗口。

## 二、 状态管理器：FileStateCache

整个会话期间，Read、Edit、Write 三个工具**共享同一个** `readFileState` 实例，通过 `ToolUseContext` 注入到每个工具调用中。它是会话级持久状态，不会因单次工具调用而重建。

### 1. 数据结构定义

`FileState` 类型定义在 [`claude-code-source/src/utils/fileStateCache.ts`](../../claude-code-source/src/utils/fileStateCache.ts#L4-L15) 中：

```typescript
// claude-code-source/src/utils/fileStateCache.ts
export type FileState = {
  content: string
  timestamp: number
  offset: number | undefined
  limit: number | undefined
  // True when this entry was populated by auto-injection (e.g. CLAUDE.md) and
  // the injected content did not match disk (stripped HTML comments, stripped
  // frontmatter, truncated MEMORY.md). The model has only seen a partial view;
  // Edit/Write must require an explicit Read first. `content` here holds the
  // RAW disk bytes (for getChangedFiles diffing), not what the model saw.
  isPartialView?: boolean
}
```

各字段含义如下：

| 字段 | 类型 | 说明 |
|------|------|------|
| `content` | `string` | 文件内容（CRLF 已归一化为 LF） |
| `timestamp` | `number` | 上次读取/编辑时的 `mtime`（毫秒，已 `floor`） |
| `offset` | `number \| undefined` | 读取起始行（分页读取时使用，全量读取为 `undefined`） |
| `limit` | `number \| undefined` | 读取行数限制（同上） |
| `isPartialView` | `boolean?` | 是否为部分视图（如 `CLAUDE.md` 自动注入），为 `true` 时 Edit/Write 必须要求显式 Read |

### 2. LRU 缓存配置

`FileStateCache` 类基于 `lru-cache` 库实现，定义在 [`claude-code-source/src/utils/fileStateCache.ts`](../../claude-code-source/src/utils/fileStateCache.ts#L30-L39) 中：

```typescript
// claude-code-source/src/utils/fileStateCache.ts
export class FileStateCache {
  private cache: LRUCache<string, FileState>

  constructor(maxEntries: number, maxSizeBytes: number) {
    this.cache = new LRUCache<string, FileState>({
      max: maxEntries,
      maxSize: maxSizeBytes,
      sizeCalculation: value => Math.max(1, Buffer.byteLength(value.content)),
    })
  }
}
```

默认配置常量：

- 最多缓存 **100 个文件**（`READ_FILE_STATE_CACHE_SIZE = 100`）
- 最大内存占用 **25 MB**（`DEFAULT_MAX_CACHE_SIZE_BYTES = 25 * 1024 * 1024`）
- `sizeCalculation` 按文件内容字节数计算，单条目至少占 1 字节
- 超出限制时按 LRU 策略自动淘汰最久未使用的条目

工厂函数 [`createFileStateCacheWithSizeLimit()`](../../claude-code-source/src/utils/fileStateCache.ts#L101-L106) 封装了上述配置：

```typescript
// claude-code-source/src/utils/fileStateCache.ts
export function createFileStateCacheWithSizeLimit(
  maxEntries: number,
  maxSizeBytes: number = DEFAULT_MAX_CACHE_SIZE_BYTES,
): FileStateCache {
  return new FileStateCache(maxEntries, maxSizeBytes)
}
```

### 3. 路径归一化

所有缓存操作在访问前都通过 `normalize()` 归一化路径键，确保不同路径形式命中同一条目：

```typescript
// claude-code-source/src/utils/fileStateCache.ts
get(key: string): FileState | undefined {
  return this.cache.get(normalize(key))
}
set(key: string, value: FileState): this {
  this.cache.set(normalize(key), value)
  return this
}
```

这解决了以下场景的缓存命中率问题：

- 相对路径与冗余段：`/foo/../bar` 与 `/bar` 归一化后一致
- 跨平台分隔符：Windows 下 `/` 与 `\` 统一处理

### 4. ToolUseContext 注入

`readFileState` 作为 `ToolUseContext` 的字段，在 [`claude-code-source/src/Tool.ts`](../../claude-code-source/src/Tool.ts#L181) 中声明：

```typescript
// claude-code-source/src/Tool.ts
export type ToolUseContext = {
  // ...
  readFileState: FileStateCache
  // ...
}
```

所有内置工具在执行时均可通过 `context.readFileState` 访问共享缓存。

### 5. 缓存合并与克隆

当需要合并两个缓存时（如多 Agent 场景），[`mergeFileStateCaches()`](../../claude-code-source/src/utils/fileStateCache.ts#L128-L142) 按 `timestamp` 取较新者：

```typescript
// claude-code-source/src/utils/fileStateCache.ts
export function mergeFileStateCaches(
  first: FileStateCache,
  second: FileStateCache,
): FileStateCache {
  const merged = cloneFileStateCache(first)
  for (const [filePath, fileState] of second.entries()) {
    const existing = merged.get(filePath)
    // Only override if the new entry is more recent
    if (!existing || fileState.timestamp > existing.timestamp) {
      merged.set(filePath, fileState)
    }
  }
  return merged
}
```

## 三、 Read 工具：建立基线

Read 工具是缓存数据的唯一"生产者"（Edit/Write 也会写入，但本质是更新已有基线）。读取文件后，把内容与 `mtime` 存入缓存，形成后续 Edit/Write 判断 staleness 的参照基线。

### 1. 读取后记录状态

文本文件读取完成后，在 [`FileReadTool.ts`](../../claude-code-source/src/tools/FileReadTool/FileReadTool.ts#L1032-L1037) 中更新缓存：

```typescript
// claude-code-source/src/tools/FileReadTool/FileReadTool.ts
readFileState.set(fullFilePath, {
  content,                          // 文件内容（CRLF 归一化后）
  timestamp: Math.floor(mtimeMs),   // 文件修改时间（毫秒，floor 后取整）
  offset,                           // 读取起始行
  limit,                            // 读取行数限制
})
```

其中 `mtimeMs` 来自 `readFileInRange` 函数，该函数有两条获取路径：

- **快速路径**（小于 10 MB 的文件）：通过 `fsStat()` 获取 `stats.mtimeMs`
- **流式路径**（大文件）：通过 `fstat(fd)` 在文件打开时获取 `mtimeMs`

Notebook 文件（`.ipynb`）读取后同样更新缓存，逻辑在 [`FileReadTool.ts`](../../claude-code-source/src/tools/FileReadTool/FileReadTool.ts#L841-L847) 中。

### 2. 读取去重优化

如果同一文件、同一 `offset/limit` 范围已被读取过且 `mtime` 未变，Read 工具会返回 `file_unchanged` stub 而非重新发送完整内容，避免重复占用上下文。核心逻辑位于 [`FileReadTool.ts`](../../claude-code-source/src/tools/FileReadTool/FileReadTool.ts#L523-L573) 中：

```typescript
// claude-code-source/src/tools/FileReadTool/FileReadTool.ts
// 去重：如果已读取过相同范围且文件未变化，返回 stub
const existingState = readFileState.get(fullFilePath)

// 仅对 Read 来源的条目去重（offset 总是由 Read 设置）
// Edit/Write 存储 offset=undefined — 其 readFileState 条目反映编辑后的 mtime
if (
  existingState &&
  !existingState.isPartialView &&
  existingState.offset !== undefined
) {
  const rangeMatch =
    existingState.offset === offset && existingState.limit === limit
  if (rangeMatch) {
    const mtimeMs = await getFileModificationTimeAsync(fullFilePath)
    if (mtimeMs === existingState.timestamp) {
      // 文件未变化，返回 file_unchanged stub
      return {
        data: { type: 'file_unchanged' as const, file: { filePath: file_path } },
      }
    }
  }
}
```

【**注意**】 去重逻辑特意排除了 Edit/Write 写入的条目（`offset === undefined`），因为那些条目的 `timestamp` 反映的是编辑后的 `mtime`，对它们去重会错误地指向编辑前的 Read 内容。

## 四、 Edit 工具：双重 staleness 检查

Edit 工具是状态缓存的主要"消费者"。它通过两道检查确保编辑基于最新内容：`validateInput` 阶段做预校验，`call` 阶段在真正写盘前再做一次，两道检查之间不允许有异步操作以防止竞态。

### 1. validateInput 阶段：预校验

`validateInput` 在权限决策前执行，位于 [`FileEditTool.ts`](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts#L275-L311) 中：

```typescript
// claude-code-source/src/tools/FileEditTool/FileEditTool.ts
// ① 检查是否已读取过该文件
const readTimestamp = toolUseContext.readFileState.get(fullFilePath)
if (!readTimestamp || readTimestamp.isPartialView) {
  return {
    result: false,
    behavior: 'ask',
    message: 'File has not been read yet. Read it first before writing to it.',
    errorCode: 6,
  }
}

// ② 比对 mtime：磁盘当前 mtime vs 缓存里的 mtime
if (readTimestamp) {
  const lastWriteTime = getFileModificationTime(fullFilePath)
  if (lastWriteTime > readTimestamp.timestamp) {
    // Windows 上 mtime 可能因云同步/杀毒误变，对全量读取做内容兜底
    const isFullRead =
      readTimestamp.offset === undefined &&
      readTimestamp.limit === undefined
    if (isFullRead && fileContent === readTimestamp.content) {
      // 内容没变，放行
    } else {
      return {
        result: false,
        behavior: 'ask',
        message:
          'File has been modified since read, either by the user or by a linter. Read it again before attempting to write it.',
        errorCode: 7,
      }
    }
  }
}
```

此阶段会做两项检查：

- **是否已读取**：缓存中无该文件状态（或 `isPartialView` 为 `true`）→ 拒绝，要求先 Read（errorCode 6）
- **是否被外部修改**：磁盘 `mtime` 大于缓存 `timestamp` → 判定被外部改动 → 拒绝，要求重新 Read（errorCode 7）

### 2. call 执行阶段：写盘前最终检查

`call` 方法在真正写入磁盘前，会**再次从磁盘读取文件内容**并做 staleness 检查。这防止了 `validateInput` 通过后、`call` 执行前文件被外部修改的竞态。逻辑位于 [`FileEditTool.ts`](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts#L442-L468) 中：

```typescript
// claude-code-source/src/tools/FileEditTool/FileEditTool.ts
// 2. Load current state and confirm no changes since last read
//    请避免此处和写盘之间插入异步操作，以保持原子性
const {
  content: originalFileContents,
  fileExists,
  encoding,
  lineEndings: endings,
} = readFileForEdit(absoluteFilePath)   // ← 从磁盘重新读取！

if (fileExists) {
  const lastWriteTime = getFileModificationTime(absoluteFilePath)
  const lastRead = readFileState.get(absoluteFilePath)
  if (!lastRead || lastWriteTime > lastRead.timestamp) {
    // Windows mtime 误报兜底：全量读取时比对内容
    const isFullRead =
      lastRead &&
      lastRead.offset === undefined &&
      lastRead.limit === undefined
    const contentUnchanged =
      isFullRead && originalFileContents === lastRead.content
    if (!contentUnchanged) {
      throw new Error(FILE_UNEXPECTEDLY_MODIFIED_ERROR)
    }
  }
}
```

【**关键点**】 `old_string` 的匹配永远是在"刚从磁盘读出的当前内容"上做的，不是用缓存里的旧内容。缓存里的 `content` 仅用于 staleness 的内容兜底比对。

随后的匹配与写入流程：

```typescript
// claude-code-source/src/tools/FileEditTool/FileEditTool.ts
// 3. 在磁盘当前内容上匹配 old_string
const actualOldString =
  findActualString(originalFileContents, old_string) || old_string

// 4. 生成 patch
const { patch, updatedFile } = getPatchForEdit({
  filePath: absoluteFilePath,
  fileContents: originalFileContents,
  oldString: actualOldString,
  newString: actualNewString,
  replaceAll: replace_all,
})

// 5. 写盘
writeTextContent(absoluteFilePath, updatedFile, encoding, endings)
```

### 3. 编辑成功后：更新基线

写盘成功后，立即把新内容和新 `mtime` 写回缓存，形成下一次操作的基线。逻辑位于 [`FileEditTool.ts`](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts#L519-L525) 中：

```typescript
// claude-code-source/src/tools/FileEditTool/FileEditTool.ts
// 6. Update read timestamp, to invalidate stale writes
readFileState.set(absoluteFilePath, {
  content: updatedFile,                                  // ← 编辑后的新内容
  timestamp: getFileModificationTime(absoluteFilePath),  // ← 写盘后的新 mtime
  offset: undefined,
  limit: undefined,
})
```

## 五、 Write 工具：同构的检查机制

Write 工具的逻辑与 Edit 完全一致，同样采用 `validateInput` + `call` 双重检查。

### 1. validateInput 阶段检查

位于 [`FileWriteTool.ts`](../../claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts#L198-L219) 中：

```typescript
// claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts
const readTimestamp = toolUseContext.readFileState.get(fullFilePath)
if (!readTimestamp || readTimestamp.isPartialView) {
  return {
    result: false,
    message: 'File has not been read yet. Read it first before writing to it.',
    errorCode: 2,
  }
}

// 复用上面 stat 得到的 mtime，避免冗余 statSync
const lastWriteTime = Math.floor(fileMtimeMs)
if (lastWriteTime > readTimestamp.timestamp) {
  return {
    result: false,
    message:
      'File has been modified since read, either by the user or by a linter. Read it again before attempting to write it.',
    errorCode: 3,
  }
}
```

注意 Write 的 `validateInput` 比 Edit 更严格：当 `mtime` 变化时直接拒绝，不提供内容兜底比对（因为 Write 是全量覆盖，不需要匹配 `old_string`）。

### 2. call 执行阶段检查

位于 [`FileWriteTool.ts`](../../claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts#L268-L295) 中：

```typescript
// claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts
// Load current state and confirm no changes since last read.
// 请避免此处和写盘之间插入异步操作，以保持原子性
let meta: ReturnType<typeof readFileSyncWithMetadata> | null
try {
  meta = readFileSyncWithMetadata(fullFilePath)   // ← 从磁盘重新读取
} catch (e) {
  if (isENOENT(e)) {
    meta = null
  } else {
    throw e
  }
}

if (meta !== null) {
  const lastWriteTime = getFileModificationTime(fullFilePath)
  const lastRead = readFileState.get(fullFilePath)
  if (!lastRead || lastWriteTime > lastRead.timestamp) {
    const isFullRead =
      lastRead &&
      lastRead.offset === undefined &&
      lastRead.limit === undefined
    // meta.content 已 CRLF 归一化 — 与 readFileState 的归一化形式一致
    if (!isFullRead || meta.content !== lastRead.content) {
      throw new Error(FILE_UNEXPECTEDLY_MODIFIED_ERROR)
    }
  }
}
```

### 3. 写入后更新基线

位于 [`FileWriteTool.ts`](../../claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts#L331-L337) 中：

```typescript
// claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts
// Update read timestamp, to invalidate stale writes
readFileState.set(fullFilePath, {
  content,
  timestamp: getFileModificationTime(fullFilePath),
  offset: undefined,
  limit: undefined,
})
```

## 六、 多次修改的闭环机制

### 1. 完整时序

当对同一文件进行连续多次编辑时，缓存与磁盘状态的协同演进如下：

```
Read   → 记录基线 (mtime₁, content₁)
  ↓
Edit₁  → 读盘 (磁盘 mtime₁ == 缓存 mtime₁ ✓)
       → 在磁盘内容上匹配 old_string
       → 写盘
       → 更新缓存 (mtime₂, content₂)
  ↓
Edit₂  → 读盘 (磁盘 mtime₂ == 缓存 mtime₂ ✓)
       → 在磁盘内容上匹配 old_string
       → 写盘
       → 更新缓存 (mtime₃, content₃)
  ↓
若期间用户在编辑器手动改了文件
  → 磁盘 mtime > 缓存 mtime
  → staleness 检查失败 → 拒绝，要求重新 Read
```

每一次编辑成功后，缓存中的 `timestamp` 被更新为写盘后的新 `mtime`，`content` 被更新为编辑后的新内容。这使得下一次编辑的 staleness 检查有一个正确的参照基线，不会误判上一次自己的编辑为"外部修改"。

### 2. offset/limit 设为 undefined 的原因

Edit/Write 成功后写入缓存时，`offset` 和 `limit` 都设为 `undefined`：

```typescript
readFileState.set(absoluteFilePath, {
  content: updatedFile,
  timestamp: getFileModificationTime(absoluteFilePath),
  offset: undefined,   // ← 标记"完整文件视图，非分页读取"
  limit: undefined,    // ← 后续 staleness 比对时可走内容兜底分支
})
```

这有两个作用：

- 标记该条目为"完整文件视图"（`isFullRead = offset === undefined && limit === undefined`），使得后续 `mtime` 误报时能走内容兜底比对（`content === lastRead.content`），而不是直接拒绝
- 让 Read 工具的去重逻辑跳过这些条目（去重逻辑要求 `offset !== undefined`），避免错误地复用编辑前的 Read 内容

## 七、 Staleness 检测的三重保障

### 1. mtime 比对（主检测）

缓存中存储的 `timestamp` 是上次操作时的 `mtime`。编辑前取磁盘当前 `mtime`，若 `磁盘 mtime > 缓存 mtime`，判定为被外部改动，拒绝操作。

| 工具 | 检查位置 | 错误码 |
|------|----------|--------|
| Edit | [`FileEditTool.ts` L292](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts#L292) | errorCode 7 |
| Edit | [`FileEditTool.ts` L454](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts#L454) | `FILE_UNEXPECTEDLY_MODIFIED_ERROR` |
| Write | [`FileWriteTool.ts` L212](../../claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts#L212) | errorCode 3 |
| Write | [`FileWriteTool.ts` L282](../../claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts#L282) | `FILE_UNEXPECTEDLY_MODIFIED_ERROR` |

### 2. 内容兜底（防误报）

Windows 上 `mtime` 可能因云同步、杀毒软件等原因变化但内容未变。对于全量读取（`offset === undefined && limit === undefined`）的条目，当 `mtime` 变化时会进一步比对内容，避免误报。

### 3. 双重检查（防竞态）

`validateInput` 阶段检查一次，`call` 阶段写盘前再检查一次。两步之间不允许插入异步操作（源码注释明确要求 `Please avoid async operations between here and writing to disk to preserve atomicity`），防止权限校验通过后、实际写盘前文件被并发修改。

## 八、 常见错误与处理

| 错误信息 | 触发条件 | 处理方式 |
|----------|----------|----------|
| `File has not been read yet. Read it first before writing to it.` | Edit/Write 前未调用 Read 读取文件，或仅通过自动注入（`isPartialView`）看到部分内容 | 先调用 Read 工具完整读取目标文件 |
| `File has been modified since read, either by the user or by a linter.` | 缓存的 `mtime` 早于磁盘当前 `mtime`，且内容兜底比对不一致 | 重新调用 Read 读取最新内容后再编辑 |
| `FILE_UNEXPECTEDLY_MODIFIED_ERROR`（异常形式） | `call` 阶段写盘前的二次 staleness 检查失败 | 同上，重新 Read 后重试 |

## 九、 小结

Claude Code 的文件编辑状态管理可归纳为"**一个缓存、两道检查、三重保障**"：

- **一个缓存**：`FileStateCache`（LRU，100 条目 / 25 MB），会话级共享，存储每个文件的 `{content, timestamp, offset, limit}`
- **两道检查**：`validateInput` 预校验 + `call` 写盘前终检，中间无异步操作以保原子性
- **三重保障**：`mtime` 比对（主检测）+ 内容兜底（防 Windows 误报）+ 双重检查（防竞态）

编辑前**始终从磁盘重新读取文件内容**用于 `old_string` 匹配，缓存中的 `content` 仅用于 staleness 兜底比对。编辑成功后立即更新缓存，使下一次操作有正确的参照基线，从而在多次修改同一文件时始终基于最新内容。

---
*本文档由 markdowncli 技能辅助生成*

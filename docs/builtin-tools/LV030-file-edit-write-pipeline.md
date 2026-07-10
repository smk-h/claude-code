<!-- more -->

## 一、 概述

Claude Code 提供两个内置工具用于修改源码文件：`Edit`（FileEditTool）和 `Write`（FileWriteTool）。两者在定位方式、写入策略和适用场景上有本质区别。

| 维度 | Edit 工具 | Write 工具 |
|------|----------|-----------|
| 定位方式 | `old_string` 字符串子串匹配 | 无需定位，直接覆盖 |
| 磁盘写入 | 修改后全量写回整个文件 | 全量写入整个文件 |
| 写入原子性 | 原子写入（临时文件 + rename） | 原子写入（临时文件 + rename） |
| 行尾处理 | 保留原文件行尾风格 | 强制 LF |
| 使用场景 | 修改已有文件（优先使用） | 创建新文件或完全重写 |
| 文件大小限制 | 1 GiB | 无显式限制 |

## 二、 Edit 工具：字符串查找替换

### 1. 输入 Schema

`Edit` 工具的输入定义在 [`claude-code-source/src/tools/FileEditTool/types.ts`](../../claude-code-source/src/tools/FileEditTool/types.ts#L6-L19) 中：

```typescript
// claude-code-source/src/tools/FileEditTool/types.ts
z.strictObject({
  file_path: z.string().describe('The absolute path to the file to modify'),
  old_string: z.string().describe('The text to replace'),
  new_string: z.string()
    .describe('The text to replace it with (must be different from old_string)'),
  replace_all: semanticBoolean(
    z.boolean().default(false).optional(),
  ).describe('Replace all occurrences of old_string (default false)'),
})
```

核心字段是 `old_string`（要查找的文本）和 `new_string`（替换文本），【**没有行号字段**】。

### 2. 字符串匹配过程

匹配分三层，逐层降级，核心逻辑位于 [`claude-code-source/src/tools/FileEditTool/utils.ts`](../../claude-code-source/src/tools/FileEditTool/utils.ts#L73-L93) 中。

#### 2.1 第一层：精确匹配

`findActualString()` 函数定义在 [`claude-code-source/src/tools/FileEditTool/utils.ts`](../../claude-code-source/src/tools/FileEditTool/utils.ts#L73-L93) 中：

```typescript
// claude-code-source/src/tools/FileEditTool/utils.ts
export function findActualString(
  fileContent: string,
  searchString: string,
): string | null {
  // First try exact match
  if (fileContent.includes(searchString)) {
    return searchString
  }
```

直接用 `String.includes()` 做子串查找。这不是行级匹配，而是字符级的子串匹配——`old_string` 可以跨行，也可以是行的一部分。

#### 2.2 第二层：引号归一化匹配

引号归一化逻辑位于 [`claude-code-source/src/tools/FileEditTool/utils.ts`](../../claude-code-source/src/tools/FileEditTool/utils.ts#L82-L92) 中：

```typescript
// claude-code-source/src/tools/FileEditTool/utils.ts
  // Try with normalized quotes
  const normalizedSearch = normalizeQuotes(searchString)
  const normalizedFile = normalizeQuotes(fileContent)

  const searchIndex = normalizedFile.indexOf(normalizedSearch)
  if (searchIndex !== -1) {
    return fileContent.substring(searchIndex, searchIndex + searchString.length)
  }
```

如果精确匹配失败，将文件和搜索串中的弯引号（`‘` `’` `“` `”`）统一归一化为直引号再匹配。这是因为 Claude 模型无法输出弯引号，但源码文件中可能包含弯引号。匹配成功后，返回文件中真实的字符串（含弯引号），而非模型提供的直引号版本。

#### 2.3 第三层：去消毒匹配

模型在 API 传输中某些特殊标记（如 `<function_results>`、`<META_START>` 等）会被消毒。此层将这些标记还原后再匹配，定义在 [`claude-code-source/src/tools/FileEditTool/utils.ts`](../../claude-code-source/src/tools/FileEditTool/utils.ts#L557-L574) 中：

```typescript
// claude-code-source/src/tools/FileEditTool/utils.ts
function desanitizeMatchString(matchString: string): {
  result: string
  appliedReplacements: Array<{ from: string; to: string }>
} {
  let result = matchString
  const appliedReplacements: Array<{ from: string; to: string }> = []

  for (const [from, to] of Object.entries(DESANITIZATIONS)) {
    const beforeReplace = result
    result = result.replaceAll(from, to)
    if (beforeReplace !== result) {
      appliedReplacements.push({ from, to })
    }
  }

  return { result, appliedReplacements }
}
```

### 3. 执行替换

替换逻辑位于 [`claude-code-source/src/tools/FileEditTool/utils.ts`](../../claude-code-source/src/tools/FileEditTool/utils.ts#L206-L228) 中：

```typescript
// claude-code-source/src/tools/FileEditTool/utils.ts
export function applyEditToFile(
  originalContent: string,
  oldString: string,
  newString: string,
  replaceAll: boolean = false,
): string {
  const f = replaceAll
    ? (content: string, search: string, replace: string) =>
        content.replaceAll(search, () => replace)
    : (content: string, search: string, replace: string) =>
        content.replace(search, () => replace)
```

- `replace_all=false`：用 `String.replace()`，只替换第一个匹配
- `replace_all=true`：用 `String.replaceAll()`，替换所有匹配

### 4. 唯一性校验

如果 `old_string` 在文件中出现多次且未设 `replace_all`，编辑会被拒绝，要求提供更多上下文使其唯一。该校验位于 [`claude-code-source/src/tools/FileEditTool/FileEditTool.ts`](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts#L329-L343) 中：

```typescript
// claude-code-source/src/tools/FileEditTool/FileEditTool.ts
const matches = file.split(actualOldString).length - 1

// Check if we have multiple matches but replace_all is false
if (matches > 1 && !replace_all) {
  return {
    result: false,
    behavior: 'ask',
    message: `Found ${matches} matches of the string to replace, but replace_all is false. ...`,
  }
}
```

【**注意**】这是保证精确定位的关键机制。

### 5. 引号风格保持

当 `old_string` 通过引号归一化匹配成功时，`preserveQuoteStyle()` 会将 `new_string` 中的引号也转换为弯引号，保持文件排版风格。该函数定义在 [`claude-code-source/src/tools/FileEditTool/utils.ts`](../../claude-code-source/src/tools/FileEditTool/utils.ts#L104-L136) 中。

### 6. 长字符串的处理策略

无论 `old_string` 是 2 行还是 200 行，底层匹配和替换机制完全相同——都是 `String.includes()` + `String.replace()`，代码中没有任何基于长度的分支逻辑。但在实际使用中，长字符串会带来不同的策略考量。

#### 6.1 Prompt 建议尽量短

Prompt 明确建议使用能保证唯一的最小片段，位于 [`claude-code-source/src/tools/FileEditTool/prompt.ts`](../../claude-code-source/src/tools/FileEditTool/prompt.ts#L17-L19) 中：

```typescript
// claude-code-source/src/tools/FileEditTool/prompt.ts
const minimalUniquenessHint =
  process.env.USER_TYPE === 'ant'
    ? `\n- Use the smallest old_string that's clearly unique — usually 2-4 adjacent lines is sufficient. Avoid including 10+ lines of context when less uniquely identifies the target.`
    : ''
```

建议用 2-4 行即可保证唯一性，避免传 10 行以上的上下文。

#### 6.2 长字符串的匹配风险

`old_string` 越长，匹配失败概率越高，原因如下：

- 任何一个字符不一致（空格、tab、引号风格、行尾）都会导致精确匹配失败
- 虽然有引号归一化降级，但缩进、尾部空格等差异没有降级机制
- `normalizeFileEditInput` 会 strip `new_string` 的尾部空格（Markdown 除外），但 `old_string` 不做此类处理，模型必须精确复制原文件内容

#### 6.3 长字符串 vs Write 全量重写的取舍

| 改动规模 | 推荐方式 | 原因 |
|----------|---------|------|
| 改几行 | Edit，短 `old_string` | 省 token，匹配可靠 |
| 改一个大函数体 | Edit，`old_string` 包含整个函数 | 需精确复制原函数，有匹配失败风险 |
| 文件大半内容都要改 | Write 全量重写 | 避免长 `old_string` 匹配失败，省去精确复制大段原文的 token 开销 |

当改动占文件 50% 以上时，Prompt 建议直接用 Write 全量重写，定义在 [`claude-code-source/src/tools/FileWriteTool/prompt.ts`](../../claude-code-source/src/tools/FileWriteTool/prompt.ts#L14-L15) 中：

- `Edit` 只传 diff，省 token，优先用于修改已有文件
- `Write` 仅用于创建新文件或完全重写，避免长 `old_string` 匹配失败的风险

## 三、 Write 工具：全量覆盖写入

### 1. 输入 Schema

`Write` 工具的输入定义在 [`claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts`](../../claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts#L56-L65) 中：

```typescript
// claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts
z.strictObject({
  file_path: z.string()
    .describe('The absolute path to the file to write (must be absolute, not relative)'),
  content: z.string().describe('The content to write to the file'),
})
```

只有 `file_path` 和 `content`，直接用 `content` 完全覆盖文件，无需匹配。

### 2. 写入逻辑

写入逻辑位于 [`claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts`](../../claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts#L300-L305) 中：

```typescript
// claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts
// Write is a full content replacement — the model sent explicit line endings
// in `content` and meant them. Do not rewrite them.
writeTextContent(fullFilePath, content, enc, 'LF')
```

Write 工具强制使用 LF 行尾，不保留原文件行尾风格（与 Edit 不同）。注释解释原因是模型发送的内容已包含明确行尾。

### 3. 何时用 Write vs Edit

Prompt 明确指导优先用 Edit，定义在 [`claude-code-source/src/tools/FileWriteTool/prompt.ts`](../../claude-code-source/src/tools/FileWriteTool/prompt.ts#L14-L15) 中：

- `Edit` 只传 diff，省 token，优先用于修改已有文件
- `Write` 仅用于创建新文件或完全重写

## 四、 磁盘写入机制

### 1. Edit 的写回方式

【**核心结论**】编辑全程在内存中进行，磁盘上是全量覆盖，不存在按字节偏移的部分替换。

整个流程分为三个阶段：

#### 1.1 读入内存

通过 `readFileForEdit()`（位于 [`claude-code-source/src/tools/FileEditTool/FileEditTool.ts`](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts#L444-L449)）将整个文件读入内存，得到完整的原始文件字符串 `originalFileContents`：

```typescript
// claude-code-source/src/tools/FileEditTool/FileEditTool.ts
// 2. Load current state and confirm no changes since last read
const {
  content: originalFileContents,
  fileExists,
  encoding,
  lineEndings: endings,
} = readFileForEdit(absoluteFilePath)
```

#### 1.2 内存中替换

`getPatchForEdit()` → `applyEditToFile()` 在内存中对 JavaScript 字符串做 `String.replace()`，返回完整的新文件内容 `updatedFile`。调用位于 [`claude-code-source/src/tools/FileEditTool/FileEditTool.ts`](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts#L482-L488) 中，替换过程不触及磁盘：

```typescript
// claude-code-source/src/tools/FileEditTool/FileEditTool.ts
// 4. Generate patch
const { patch, updatedFile } = getPatchForEdit({
  filePath: absoluteFilePath,
  fileContents: originalFileContents,
  oldString: actualOldString,
  newString: actualNewString,
  replaceAll: replace_all,
})
```

#### 1.3 全量写回磁盘

`writeTextContent()`（调用位于 [`claude-code-source/src/tools/FileEditTool/FileEditTool.ts`](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts#L491)）将内存中的完整 `updatedFile` 写入磁盘，通过临时文件 + rename 原子覆盖原文件，没有按字节偏移的部分写入：

```typescript
// claude-code-source/src/tools/FileEditTool/FileEditTool.ts
// 5. Write to disk
writeTextContent(absoluteFilePath, updatedFile, encoding, endings)
```

#### 1.4 完整流程图

```
磁盘原文件
    │
    │ readFileForEdit() ── 整个文件读入内存
    ▼
内存: originalFileContents (string)
    │
    │ String.replace(old_string, new_string) ── 内存中替换
    ▼
内存: updatedFile (string) ── 完整的新文件内容
    │
    │ 写入临时文件 .tmp.{pid}.{timestamp}
    ▼
磁盘: tempFile (完整内容)
    │
    │ rename(tempFile → originalFile) ── 原子覆盖
    ▼
磁盘: 原文件被完整替换
```

虽然 Edit 只改了一处字符串，但磁盘写入是全量覆盖——把整个修改后的文件内容写入临时文件，再 rename 替换原文件。代码中没有任何用 `fs.open` + `fs.write` 按字节偏移修改文件某一段的操作。

#### 1.5 为什么内存中可以局部替换，而磁盘需要全量覆盖

内存中的"替换"和磁盘上的"写入"面对的约束完全不同。

##### 1.5.1 内存中"局部替换"的本质

JavaScript 字符串是不可变的（immutable），`String.replace()` 实际上也是生成一个全新的字符串，并非原地修改。但因为内存在 RAM 中，分配新字符串、复制未变动部分的开销极小，所以看起来像是"局部替换"：

```typescript
// 实际上返回了一个全新的 string 对象
const updated = original.replace(oldString, newString)
```

##### 1.5.2 磁盘上无法局部替换的原因

如果想在磁盘上只改 `old_string` 对应的那几个字节，需要用 `fs.write(fd, data, offset)` 按字节偏移写入。但这有四个根本性问题：

- **长度不一致时无法原地替换**：`old_string` 和 `new_string` 的字节长度几乎总是不同的。如果在偏移量 X 处直接写入更长的 `new_string`，会覆盖掉后面的字节；要处理长度差异，就必须把偏移量之后的所有内容整体前移或后移，本质上就是重写文件剩余部分，比直接写整个文件更复杂
- **原子性无法保证**：当前方案用临时文件 + rename，POSIX 上 rename 是原子的，要么完整替换要么原文件不受影响。如果改成按偏移量部分写入原文件，中间任何一步崩溃（进程被杀、断电），文件就处于半新半旧的损坏状态，无法回滚
- **编码和行尾转换会打乱字节偏移**：CRLF 归一化逻辑（位于 [`claude-code-source/src/utils/file.ts`](../../claude-code-source/src/utils/file.ts#L91-L94)）会改变字节布局，部分写入需要额外处理这些转换，复杂度陡增
- **收益极小**：对于典型的源码文件（几 KB 到几百 KB），全量写回的开销可以忽略。写一个几百 KB 的临时文件 + rename 在现代磁盘上不到 1ms，而真正的瓶颈是 LLM 生成编辑内容（秒级）

##### 1.5.3 设计权衡总结

| 维度 | 内存中替换 | 磁盘全量覆盖 |
|------|----------|------------|
| 本质 | 生成新字符串（immutable） | 临时文件 + rename |
| 开销 | RAM 分配/复制，极小 | 磁盘 I/O，典型文件 <1ms |
| 原子性 | 不适用（内存操作） | rename 保证原子性 |
| 长度差异 | 自动处理（新字符串） | 无需关心（全量写入） |
| 编码转换 | 不涉及 | 写入时统一处理 |
| 损坏风险 | 无 | 崩溃时原文件不受影响 |

全量写回（临时文件 + rename）简单、原子、对典型文件大小足够快，这是 Claude Code 选择全量覆盖而非部分写入的根本原因。

### 2. 底层写入函数

`writeTextContent()` 定义在 [`claude-code-source/src/utils/file.ts`](../../claude-code-source/src/utils/file.ts#L84-L98) 中：

```typescript
// claude-code-source/src/utils/file.ts
export function writeTextContent(
  filePath: string,
  content: string,
  encoding: BufferEncoding,
  endings: LineEndingType,
): void {
  let toWrite = content
  if (endings === 'CRLF') {
    // Normalize any existing CRLF to LF first so a new_string that already
    // contains \r\n (raw model output) doesn't become \r\r\n after the join.
    toWrite = content.replaceAll('\r\n', '\n').split('\n').join('\r\n')
  }
  writeFileSyncAndFlush_DEPRECATED(filePath, toWrite, { encoding })
}
```

- 如果原文件是 CRLF 行尾，先归一化再转换，避免出现 `\r\r\n`
- 调用 `writeFileSyncAndFlush_DEPRECATED` 执行原子写入

### 3. 原子写入机制

原子写入逻辑位于 [`claude-code-source/src/utils/file.ts`](../../claude-code-source/src/utils/file.ts#L362-L478) 中：

```typescript
// claude-code-source/src/utils/file.ts
// Try atomic write first
const tempPath = `${targetPath}.tmp.${process.pid}.${Date.now()}`

// ... 写入临时文件
fsWriteFileSync(tempPath, content, writeOptions)

// ... 保留原文件权限
if (targetExists && targetMode !== undefined) {
  chmodSync(tempPath, targetMode)
}

// Atomic rename (on POSIX systems, this is atomic)
fs.renameSync(tempPath, targetPath)
```

写入流程：

1. 写入临时文件 `.tmp.{pid}.{timestamp}`
2. 用 `chmod` 保留原文件权限
3. 用 `rename` 原子性覆盖目标文件
4. 如果原子写失败，降级为直接 `writeFileSync`
5. 支持符号链接透写（写入链接指向的真实路径）

## 五、 文件修改后的精确定位机制

### 1. 不依赖行号，依赖字符串匹配

Claude Code 的 Edit 工具完全不用行号定位。每次编辑都是用 `old_string` 做字符串子串匹配。所以即使前一次编辑导致行号全部变了，下一次编辑只要 `old_string` 还能在文件中唯一匹配，就能精确定位。

模型从 Read 工具获取文件内容时看到的是带行号前缀的文本，Prompt 明确告诉模型（位于 [`claude-code-source/src/tools/FileEditTool/prompt.ts`](../../claude-code-source/src/tools/FileEditTool/prompt.ts#L23)）：行号前缀不是文件内容，`old_string` 中不能包含行号前缀。

### 2. readFileState 缓存机制

`readFileState` 是一个 LRU 缓存，记录每个文件上次被读取时的内容和时间戳。其类型定义在 [`claude-code-source/src/utils/fileStateCache.ts`](../../claude-code-source/src/utils/fileStateCache.ts#L4-L15) 中：

```typescript
// claude-code-source/src/utils/fileStateCache.ts
export type FileState = {
  content: string        // 文件内容快照
  timestamp: number      // 读取时的 mtime
  offset: number | undefined   // 分页读取的偏移
  limit: number | undefined    // 分页读取的限制
  isPartialView?: boolean      // 是否为部分视图（如 CLAUDE.md 自动注入）
}
```

缓存配置：

- 最多 100 个文件条目（`READ_FILE_STATE_CACHE_SIZE`）
- 最大 25MB 内存占用（`DEFAULT_MAX_CACHE_SIZE_BYTES`）
- 基于内容字节数做 LRU 淘汰

### 3. 编辑前的防陈旧检查

在 `validateInput` 阶段，位于 [`claude-code-source/src/tools/FileEditTool/FileEditTool.ts`](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts#L275-L311) 中：

```typescript
// claude-code-source/src/tools/FileEditTool/FileEditTool.ts
const readTimestamp = toolUseContext.readFileState.get(fullFilePath)
if (!readTimestamp || readTimestamp.isPartialView) {
  return {
    result: false,
    behavior: 'ask',
    message: 'File has not been read yet. Read it first before writing to it.',
  }
}

if (readTimestamp) {
  const lastWriteTime = getFileModificationTime(fullFilePath)
  if (lastWriteTime > readTimestamp.timestamp) {
    // Windows: 时间戳可能因云同步/杀毒软件变化但内容没变
    const isFullRead =
      readTimestamp.offset === undefined &&
      readTimestamp.limit === undefined
    if (isFullRead && fileContent === readTimestamp.content) {
      // 内容没变，继续
    } else {
      return {
        result: false,
        behavior: 'ask',
        message: 'File has been modified since read...',
      }
    }
  }
}
```

校验逻辑：

1. 必须先 Read 才能 Edit（`readFileState` 中有记录）
2. 检查文件当前 mtime 是否大于上次读取时的 mtime
3. 如果 mtime 变了，在 Windows 上额外做内容比较（因为云同步、杀毒软件可能只改 mtime 不改内容）
4. 如果是全量读取（非分页），直接比较内容字符串
5. 如果内容确实变了，拒绝编辑，要求重新 Read

### 4. 编辑时的二次检查

在 `call` 阶段执行编辑前，会再次读取文件并检查 mtime，位于 [`claude-code-source/src/tools/FileEditTool/FileEditTool.ts`](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts#L442-L468) 中：

```typescript
// claude-code-source/src/tools/FileEditTool/FileEditTool.ts
// 2. Load current state and confirm no changes since last read
// Please avoid async operations between here and writing to disk to preserve atomicity
const {
  content: originalFileContents,
  fileExists,
  encoding,
  lineEndings: endings,
} = readFileForEdit(absoluteFilePath)

if (fileExists) {
  const lastWriteTime = getFileModificationTime(absoluteFilePath)
  const lastRead = readFileState.get(absoluteFilePath)
  if (!lastRead || lastWriteTime > lastRead.timestamp) {
    const isFullRead =
      lastRead && lastRead.offset === undefined && lastRead.limit === undefined
    const contentUnchanged =
      isFullRead && originalFileContents === lastRead.content
    if (!contentUnchanged) {
      throw new Error(FILE_UNEXPECTEDLY_MODIFIED_ERROR)
    }
  }
}
```

【**重要提示**】从读取文件到写磁盘之间不允许有 async 操作，保证原子性，防止 `validateInput` 之后、`call` 之前文件被外部修改。

### 5. 编辑后立即更新状态

编辑完成后，立即将 `readFileState` 更新为修改后的内容和新的 mtime，位于 [`claude-code-source/src/tools/FileEditTool/FileEditTool.ts`](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts#L519-L525) 中：

```typescript
// claude-code-source/src/tools/FileEditTool/FileEditTool.ts
// 6. Update read timestamp, to invalidate stale writes
readFileState.set(absoluteFilePath, {
  content: updatedFile,                              // 更新为修改后的内容
  timestamp: getFileModificationTime(absoluteFilePath), // 更新为新的 mtime
  offset: undefined,
  limit: undefined,
})
```

### 6. 多次连续编辑同一文件

当模型在同一轮对话中多次编辑同一文件时：

1. **第一次编辑**：基于 Read 时缓存的内容，`old_string` 匹配成功 → 写入 → 更新 `readFileState`
2. **第二次编辑**：`readFileState` 已更新为第一次编辑后的内容，mtime 也已更新 → 新的 `old_string` 在更新后的内容中匹配 → 成功

模型不需要在两次 Edit 之间重新 Read 文件，因为 `readFileState` 在每次 Edit 后都更新了。但模型必须基于自己上一次编辑产生的新内容来构造下一个 `old_string`，这正是通过字符串匹配而非行号定位的优势——只要内容匹配，位置在哪行无所谓。

## 六、 核心源码文件索引

### 1. FileEditTool 相关

| 文件 | 作用 |
|------|------|
| [`FileEditTool.ts`](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts) | Edit 工具主实现，输入验证、权限检查、编辑执行 |
| [`types.ts`](../../claude-code-source/src/tools/FileEditTool/types.ts) | 类型定义和 Zod schema |
| [`utils.ts`](../../claude-code-source/src/tools/FileEditTool/utils.ts) | 核心编辑逻辑（字符串匹配、引号归一化、patch 生成） |
| [`prompt.ts`](../../claude-code-source/src/tools/FileEditTool/prompt.ts) | 工具提示词 |
| [`constants.ts`](../../claude-code-source/src/tools/FileEditTool/constants.ts) | 常量定义 |

### 2. FileWriteTool 相关

| 文件 | 作用 |
|------|------|
| [`FileWriteTool.ts`](../../claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts) | Write 工具主实现 |
| [`prompt.ts`](../../claude-code-source/src/tools/FileWriteTool/prompt.ts) | 工具提示词 |

### 3. 底层工具

| 文件 | 作用 |
|------|------|
| [`file.ts`](../../claude-code-source/src/utils/file.ts) | 底层文件操作（`writeTextContent`、原子写入） |
| [`diff.ts`](../../claude-code-source/src/utils/diff.ts) | Diff 生成工具 |
| [`fileStateCache.ts`](../../claude-code-source/src/utils/fileStateCache.ts) | `readFileState` LRU 缓存定义 |

## 七、 总结

Claude Code 的文件修改机制可归纳为以下要点：

- Edit 工具用精确字符串子串匹配定位修改位置，不使用行号，支持引号归一化和去消毒两层降级匹配
- 无论 `old_string` 长短，匹配和替换机制完全相同，但 Prompt 建议使用 2-4 行的最小唯一片段以降低匹配失败风险
- 编辑全程在内存中进行（读全文 → 字符串替换 → 生成新全文），磁盘上是全量覆盖（临时文件 + rename 原子覆盖），不存在按字节偏移的部分替换
- 文件修改后的精确定位通过 `readFileState` LRU 缓存追踪内容和 mtime
- 每次编辑后立即更新缓存，使后续编辑基于最新内容匹配
- 多次连续编辑同一文件时，模型基于自己上一次编辑产生的新内容构造 `old_string`，无需重新 Read
- 改动占文件 50% 以上时，优先用 Write 全量重写，避免长 `old_string` 匹配失败

---
*本文档由 markdowncli 技能辅助生成*

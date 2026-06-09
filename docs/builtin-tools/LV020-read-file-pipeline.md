<!-- more -->

## 一、 问题引入

当 Claude 准备读取一个大文件时，第一次到底读多少行？谁决定的？怎么读的？本文从源码出发，梳理 Read 工具从 LLM 发起调用到磁盘 I/O 再到返回结果的完整流程。

## 二、 工具定义与参数默认值

### 1. 工具名称与 Schema

Read 工具的名称常量为 `'Read'`，输入 Schema 包含四个字段：

```typescript
// claude-code-source/src/tools/FileReadTool/FileReadTool.ts
const inputSchema = lazySchema(() =>
  z.strictObject({
    file_path: z.string().describe('The absolute path to the file to read'),
    offset: semanticNumber(z.number().int().nonnegative().optional()).describe(
      'The line number to start reading from. Only provide if the file is too large to read at once',
    ),
    limit: semanticNumber(z.number().int().positive().optional()).describe(
      'The number of lines to read. Only provide if the file is too large to read at once.',
    ),
    pages: z.string().optional().describe(
      `Page range for PDF files (e.g., "1-5", "3", "10-20"). ...`,
    ),
  }),
)
```

`offset` 和 `limit` 均为 **optional**，这意味着 LLM 首次调用 Read 时可以不指定这两个参数。

### 2. call() 中的参数默认值

在 [`call()`](../../claude-code-source/src/tools/FileReadTool/FileReadTool.ts#L496) 方法中，参数解构时设定了默认值：

```typescript
// claude-code-source/src/tools/FileReadTool/FileReadTool.ts
async call(
  { file_path, offset = 1, limit = undefined, pages },
  ...
)
```

- `offset` 默认为 `1`（从第一行开始）
- `limit` 默认为 `undefined`（不限制行数）

【**注意**】首次读取时，LLM 不指定 offset/limit，系统默认从头开始、不限行数地读取整个文件。

## 三、 读多少 —— 三道关卡

### 1. Prompt 暗示 — `MAX_LINES_TO_READ`

[`prompt.ts`](../../claude-code-source/src/tools/FileReadTool/prompt.ts#L10) 中定义了一个常量：

```typescript
// claude-code-source/src/tools/FileReadTool/prompt.ts
export const MAX_LINES_TO_READ = 2000
```

这个值被嵌入到工具的 Prompt 描述中：

```typescript
// claude-code-source/src/tools/FileReadTool/prompt.ts
`By default, it reads up to ${MAX_LINES_TO_READ} lines starting from the beginning of the file`
```

【**注意**】`MAX_LINES_TO_READ = 2000` **仅是 Prompt 层面的暗示**，告诉 LLM "默认最多读 2000 行"，但代码层面并没有用它来做行数截断。实际的限制来自下面两道关卡。

### 2. 第一道关卡 — `maxSizeBytes`（文件总大小上限）

[`limits.ts`](../../claude-code-source/src/tools/FileReadTool/limits.ts#L35) 定义了 `FileReadingLimits` 类型：

```typescript
// claude-code-source/src/tools/FileReadTool/limits.ts
export type FileReadingLimits = {
  maxTokens: number
  maxSizeBytes: number
  includeMaxSizeInPrompt?: boolean
  targetedRangeNudge?: boolean
}
```

`maxSizeBytes` 的默认值来自 [`file.ts`](../../claude-code-source/src/utils/file.ts#L48)：

```typescript
// claude-code-source/src/utils/file.ts
export const MAX_OUTPUT_SIZE = 0.25 * 1024 * 1024 // 0.25MB in bytes = 256KB
```

[`getDefaultFileReadingLimits()`](../../claude-code-source/src/tools/FileReadTool/limits.ts#L53) 中的优先级为：

1. GrowthBook 特性开关 `tengu_amber_wren` 中的 `maxSizeBytes` 字段
2. 硬编码默认值 `MAX_OUTPUT_SIZE`（256KB）

在 [`callInner()`](../../claude-code-source/src/tools/FileReadTool/FileReadTool.ts#L1020) 中，`maxSizeBytes` 被传递给 `readFileInRange()`：

```typescript
// claude-code-source/src/tools/FileReadTool/FileReadTool.ts
const { content, lineCount, totalLines, totalBytes, readBytes, mtimeMs } =
  await readFileInRange(
    resolvedFilePath,
    lineOffset,
    limit,
    limit === undefined ? maxSizeBytes : undefined,  // 只在无显式 limit 时施加字节上限
    context.abortController.signal,
  )
```

【**关键细节**】当 LLM 指定了 `limit` 参数时，`maxSizeBytes` 传入 `undefined`，即不施加字节限制。只有不指定 `limit` 的"全量读取"场景，才会用 256KB 作为文件总大小上限。

### 3. 第二道关卡 — `maxTokens`（输出 Token 上限）

[`limits.ts`](../../claude-code-source/src/tools/FileReadTool/limits.ts#L18) 中定义：

```typescript
// claude-code-source/src/tools/FileReadTool/limits.ts
export const DEFAULT_MAX_OUTPUT_TOKENS = 25000
```

`maxTokens` 的优先级为：

1. 环境变量 `CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS`
2. GrowthBook 特性开关 `tengu_amber_wren` 中的 `maxTokens` 字段
3. 硬编码默认值 `25000`

文件内容读出后，[`validateContentTokens()`](../../claude-code-source/src/tools/FileReadTool/FileReadTool.ts#L755) 会校验 token 数：

```typescript
// claude-code-source/src/tools/FileReadTool/FileReadTool.ts
async function validateContentTokens(
  content: string,
  ext: string,
  maxTokens?: number,
): Promise<void> {
  const effectiveMaxTokens =
    maxTokens ?? getDefaultFileReadingLimits().maxTokens

  const tokenEstimate = roughTokenCountEstimationForFileType(content, ext)
  if (!tokenEstimate || tokenEstimate <= effectiveMaxTokens / 4) return

  const tokenCount = await countTokensWithAPI(content)
  const effectiveCount = tokenCount ?? tokenEstimate

  if (effectiveCount > effectiveMaxTokens) {
    throw new MaxFileReadTokenExceededError(effectiveCount, effectiveMaxTokens)
  }
}
```

这也是一个**两级判断**策略：

1. 先用 `roughTokenCountEstimationForFileType()` 快速估算，若不超过 `阈值 / 4` 则直接放行
2. 否则调用 `countTokensWithAPI()` 精确计数，超过则抛出 `MaxFileReadTokenExceededError`

### 4. 两道关卡对比

| 关卡 | 检查时机 | 阈值 | 检查对象 | 超限行为 |
|------|----------|------|----------|----------|
| `maxSizeBytes` | 读取前（stat） | 256KB | 文件总大小 | 抛出 `FileTooLargeError` |
| `maxTokens` | 读取后 | 25000 tokens | 实际输出内容 | 抛出 `MaxFileReadTokenExceededError` |

## 四、 怎么读 — `readFileInRange()` 双路径机制

[`readFileInRange()`](../../claude-code-source/src/utils/readFileInRange.ts#L73) 是从磁盘读取文件内容的核心函数，它根据文件大小和类型选择两条路径：

### 1. 路径选择逻辑

```typescript
// claude-code-source/src/utils/readFileInRange.ts
const FAST_PATH_MAX_SIZE = 10 * 1024 * 1024 // 10 MB

export async function readFileInRange(
  filePath: string,
  offset = 0,
  maxLines?: number,
  maxBytes?: number,
  signal?: AbortSignal,
  options?: { truncateOnByteLimit?: boolean },
): Promise<ReadFileRangeResult> {
  const stats = await fsStat(filePath)

  if (stats.isFile() && stats.size < FAST_PATH_MAX_SIZE) {
    // 快速路径
    if (!truncateOnByteLimit && maxBytes !== undefined && stats.size > maxBytes) {
      throw new FileTooLargeError(stats.size, maxBytes)
    }
    const text = await readFile(filePath, { encoding: 'utf8', signal })
    return readFileInRangeFast(text, stats.mtimeMs, offset, maxLines, ...)
  }

  // 流式路径
  return readFileInRangeStreaming(filePath, offset, maxLines, maxBytes, ...)
}
```

决策树：

```
stat(filePath)
  │
  ├─ 是目录？ → 抛出 EISDIR
  │
  ├─ 常规文件 && < 10MB？
  │     ├─ 总大小 > maxBytes？ → 抛出 FileTooLargeError（预检）
  │     └─ readFile() 全量读入内存 → readFileInRangeFast()
  │
  └─ 其他（大文件 / 管道 / 设备）→ readFileInRangeStreaming()
```

### 2. 快速路径 — `readFileInRangeFast()`

[快速路径](../../claude-code-source/src/utils/readFileInRange.ts#L128)适用于小于 10MB 的常规文件：

1. 一次性用 `readFile()` 将整个文件读入内存
2. 去除 UTF-8 BOM
3. 逐行扫描，按 `[offset, offset + maxLines)` 范围筛选
4. 去除每行末尾的 `\r`（CRLF → LF）
5. 计算总行数 `totalLines` 和选中行数 `lineCount`

```typescript
// claude-code-source/src/utils/readFileInRange.ts
function readFileInRangeFast(
  raw: string,
  mtimeMs: number,
  offset: number,
  maxLines: number | undefined,
  truncateAtBytes: number | undefined,
): ReadFileRangeResult {
  const endLine = maxLines !== undefined ? offset + maxLines : Infinity
  // ...逐行扫描，筛选 [offset, endLine) 范围内的行
}
```

当 `maxLines` 为 `undefined`（即 LLM 未指定 `limit`）时，`endLine = Infinity`，意味着**选所有行**。

### 3. 流式路径 — `readFileInRangeStreaming()`

[流式路径](../../claude-code-source/src/utils/readFileInRange.ts#L344)适用于大文件或非常规文件：

1. 使用 `createReadStream()` 创建可读流，`highWaterMark = 512KB`
2. 通过 `streamOnData` 事件处理器逐块扫描
3. 在范围内的行被收集到 `selectedLines`，范围外的行只计数（用于 `totalLines`）然后丢弃
4. 首个 chunk 检查并去除 UTF-8 BOM
5. 如果总字节数超过 `maxBytes`，调用 `stream.destroy()` 终止流并抛出 `FileTooLargeError`
6. 流结束时在 `streamOnEnd` 中拼接结果

```typescript
// claude-code-source/src/utils/readFileInRange.ts
function readFileInRangeStreaming(
  filePath: string,
  offset: number,
  maxLines: number | undefined,
  maxBytes: number | undefined,
  truncateOnByteLimit: boolean,
  signal?: AbortSignal,
): Promise<ReadFileRangeResult> {
  return new Promise((resolve, reject) => {
    const state: StreamState = {
      stream: createReadStream(filePath, {
        encoding: 'utf8',
        highWaterMark: 512 * 1024,
      }),
      offset,
      endLine: maxLines !== undefined ? offset + maxLines : Infinity,
      // ...
    }
    state.stream.once('open', streamOnOpen.bind(state))
    state.stream.on('data', streamOnData.bind(state))
    state.stream.once('end', streamOnEnd.bind(state))
    state.stream.once('error', reject)
  })
}
```

## 五、 去重机制 — 避免重复读取

### 1. readFileState 缓存

[`FileStateCache`](../../claude-code-source/src/utils/fileStateCache.ts#L30) 是一个基于 LRU 的缓存，记录已读文件的状态：

```typescript
// claude-code-source/src/utils/fileStateCache.ts
export type FileState = {
  content: string
  timestamp: number       // 文件修改时间（mtimeMs）
  offset: number | undefined
  limit: number | undefined
  isPartialView?: boolean  // 是否为部分视图（如 CLAUDE.md 自动注入）
}
```

缓存配置：

- 最大条目数：`READ_FILE_STATE_CACHE_SIZE = 100`
- 最大内存：`DEFAULT_MAX_CACHE_SIZE_BYTES = 25MB`
- 路径键经过 `normalize()` 归一化，确保相对/绝对路径一致

### 2. 去重判断流程

在 [`call()`](../../claude-code-source/src/tools/FileReadTool/FileReadTool.ts#L536) 方法中：

```typescript
// claude-code-source/src/tools/FileReadTool/FileReadTool.ts
const dedupKillswitch = getFeatureValue_CACHED_MAY_BE_STALE(
  'tengu_read_dedup_killswitch',
  false,
)
const existingState = dedupKillswitch
  ? undefined
  : readFileState.get(fullFilePath)

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
      return {
        data: {
          type: 'file_unchanged' as const,
          file: { filePath: file_path },
        },
      }
    }
  }
}
```

去重条件（全部满足才触发）：

1. GrowthBook 的 `tengu_read_dedup_killswitch` 未开启
2. 缓存中存在该文件的状态
3. 不是部分视图（`isPartialView` 为 false）
4. offset 和 limit 与上次完全一致
5. 文件的 mtime 与缓存中的 timestamp 一致

命中去重后返回 `type: 'file_unchanged'`，由 [`mapToolResultToToolResultBlockParam()`](../../claude-code-source/src/tools/FileReadTool/FileReadTool.ts#L686) 转为简短提示：

```typescript
// claude-code-source/src/tools/FileReadTool/prompt.ts
export const FILE_UNCHANGED_STUB =
  'File unchanged since last read. The content from the earlier Read tool_result in this conversation is still current — refer to that instead of re-reading.'
```

## 六、 结果格式化与返回

### 1. 文本文件的输出结构

`readFileInRange()` 返回的 `ReadFileRangeResult` 经过包装后，输出类型为 `text`：

```typescript
// claude-code-source/src/tools/FileReadTool/FileReadTool.ts
const data = {
  type: 'text' as const,
  file: {
    filePath: file_path,
    content,
    numLines: lineCount,
    startLine: offset,
    totalLines,
  },
}
```

### 2. 行号添加

[`addLineNumbers()`](../../claude-code-source/src/utils/file.ts#L290) 为每行添加行号前缀，支持两种格式：

- **紧凑格式**（默认启用）：`{行号}\t{内容}`，例如 `1\timport React`
- **宽格式**：`{右对齐6位行号}→{内容}`，例如 `     1→import React`

```typescript
// claude-code-source/src/utils/file.ts
export function addLineNumbers({
  content,
  startLine,
}: {
  content: string
  startLine: number
}): string {
  if (isCompactLinePrefixEnabled()) {
    return lines
      .map((line, index) => `${index + startLine}\t${line}`)
      .join('\n')
  }
  return lines
    .map((line, index) => {
      const numStr = String(index + startLine)
      if (numStr.length >= 6) {
        return `${numStr}→${line}`
      }
      return `${numStr.padStart(6, ' ')}→${line}`
    })
    .join('\n')
}
```

### 3. 最终发送给 LLM 的内容

[`mapToolResultToToolResultBlockParam()`](../../claude-code-source/src/tools/FileReadTool/FileReadTool.ts#L692) 将 `text` 类型结果组装为：

```
{memoryFileFreshnessPrefix} + addLineNumbers(content) + CYBER_RISK_MITIGATION_REMINDER?
```

其中 `CYBER_RISK_MITIGATION_REMINDER` 是恶意软件分析提醒，仅对非豁免模型附加。

### 4. 更新 readFileState

读取成功后，结果被写入 `readFileState` 缓存：

```typescript
// claude-code-source/src/tools/FileReadTool/FileReadTool.ts
readFileState.set(fullFilePath, {
  content,
  timestamp: Math.floor(mtimeMs),
  offset,
  limit,
})
```

## 七、 特殊文件类型处理

`callInner()` 对不同文件类型有分支处理：

| 文件类型 | 判断条件 | 读取方式 | 大小限制 |
|----------|----------|----------|----------|
| Notebook | `.ipynb` | `readNotebook()` | `maxSizeBytes` + `maxTokens` |
| Image | `.png/.jpg/.jpeg/.gif/.webp` | `readImageWithTokenBudget()` | `maxTokens`（图片无 `maxSizeBytes` 限制） |
| PDF | `.pdf` | `readPDF()` / `extractPDFPages()` | 页数限制（≤10 页可直接读，>10 页需 pages 参数） |
| Text | 其他 | `readFileInRange()` | `maxSizeBytes` + `maxTokens` |

## 八、 完整流程图

```
LLM 调用 Read(file_path, offset?, limit?, pages?)
        │
        ▼
  validateInput()  ← 二进制检测 / 设备文件拦截 / pages 格式校验 / 权限检查
        │
        ▼
  checkPermissions()  ← 读取权限校验
        │
        ▼
  去重检查（readFileState）
        │
        ├─ 命中去重 → 返回 file_unchanged 存根
        │
        ▼
  callInner()
        │
        ├─ .ipynb → readNotebook() → validateContentTokens()
        ├─ 图片   → readImageWithTokenBudget()
        ├─ .pdf   → readPDF() / extractPDFPages()
        └─ 文本   → readFileInRange()
                       │
                       ├─ stat(filePath)
                       │     ├─ 是目录 → 抛出 EISDIR
                       │     ├─ < 10MB 常规文件
                       │     │     ├─ 总大小 > maxSizeBytes? → 抛出 FileTooLargeError
                       │     │     └─ readFile() 全量读 → readFileInRangeFast()
                       │     └─ ≥ 10MB 或非常规文件 → readFileInRangeStreaming()
                       │
                       ▼
                 validateContentTokens()
                       │
                       ├─ token 数 > maxTokens → 抛出 MaxFileReadTokenExceededError
                       └─ 通过
        │
        ▼
  更新 readFileState 缓存
        │
        ▼
  mapToolResultToToolResultBlockParam()
        │
        ├─ text → addLineNumbers() + CYBER_RISK_MITIGATION_REMINDER?
        ├─ image → ImageBlockParam（base64）
        ├─ notebook → mapNotebookCellsToToolResult()
        ├─ pdf → DocumentBlockParam / 页面图片
        └─ file_unchanged → FILE_UNCHANGED_STUB
        │
        ▼
  组装为 tool_result 消息块 → 发送给 LLM
```

## 九、 大文件读取策略

当文件超过 256KB 或 25000 tokens 时，Read 会直接报错。此时 LLM 需要采取策略来读取大文件。本章梳理 LLM 面对大文件时的完整策略体系。

### 1. 先搜后读 — Grep 与 Read 的协作模式

当文件超过 256KB 或 25000 tokens 时，Read 会直接报错。此时 LLM 的典型策略是**先搜后读**：用 Grep 工具定位行号，再用 Read 的 offset/limit 精确读取。

#### 1.1 Grep 工具概览

Grep 工具的内部名称为 `'Grep'`，面向用户的显示名为 `'Search'`，底层基于 ripgrep 实现：

```typescript
// claude-code-source/src/tools/GrepTool/prompt.ts
export const GREP_TOOL_NAME = 'Grep'
```

#### 1.2 Grep 返回行号 — 连接 Read 的桥梁

Grep 的 `content` 输出模式默认启用行号（`-n` 参数默认为 `true`）：

```typescript
// claude-code-source/src/tools/GrepTool/GrepTool.ts
'-n': show_line_numbers = true,
```

输出格式为 `相对路径:行号:内容`，例如：

```
src/tools/FileReadTool/FileReadTool.ts:497:  { file_path, offset = 1, limit = undefined, pages },
src/tools/FileReadTool/FileReadTool.ts:1020:  const lineOffset = offset === 0 ? 0 : offset - 1
```

LLM 解析此格式后，即可将行号作为 Read 的 `offset` 参数，精确读取目标区域。

#### 1.3 Grep 的输出限制

Grep 工具有多层输出控制，避免搜索结果本身撑爆上下文：

| 控制层 | 机制 | 默认值 | 作用 |
|--------|------|--------|------|
| 行数限制 | `head_limit` → `applyHeadLimit()` | 250 | 最多返回 250 条结果（`head_limit: 0` 可解除） |
| 单行长度 | ripgrep `--max-columns` | 500 字符 | 防止 base64/压缩内容撑满输出 |
| 分页跳过 | `offset` 参数 | 0 | 配合 `head_limit` 实现分页 |
| 工具结果持久化 | `maxResultSizeChars` | 20000 字符 | 超限后持久化为磁盘文件 |

```typescript
// claude-code-source/src/tools/GrepTool/GrepTool.ts
const DEFAULT_HEAD_LIMIT = 250

args.push('--max-columns', '500')

maxResultSizeChars: 20_000,
```

#### 1.4 分页提示

当结果被截断时，Grep 在输出末尾追加分页信息，引导 LLM 继续翻页：

```typescript
// claude-code-source/src/tools/GrepTool/GrepTool.ts
if (mode === 'content') {
  const limitInfo = formatLimitInfo(appliedLimit, appliedOffset)
  const finalContent = limitInfo
    ? `${resultContent}\n\n[Showing results with pagination = ${limitInfo}]`
    : resultContent
}
```

例如：`[Showing results with pagination = limit: 250, offset: 0]`，提示 LLM 可用 `offset: 250` 继续获取后续结果。

#### 1.5 Read 工具的 Prompt 配合

当 `targetedRangeNudge` 被启用时，Read 工具的 Prompt 会从"建议全量读取"切换为"建议精准读取"：

```typescript
// claude-code-source/src/tools/FileReadTool/prompt.ts
export const OFFSET_INSTRUCTION_DEFAULT =
  "- You can optionally specify a line offset and limit ... but it's recommended to read the whole file by not providing these parameters"

export const OFFSET_INSTRUCTION_TARGETED =
  '- When you already know which part of the file you need, only read that part. This can be important for larger files.'
```

#### 1.6 先搜后读的完整流程

```
LLM 尝试 Read(file_path)  ← 无 offset/limit
        │
        ▼
  文件 > 256KB 或 > 25000 tokens?
        │
        ├─ 否 → 成功返回全部内容
        │
        └─ 是 → 抛出 FileTooLargeError / MaxFileReadTokenExceededError
                错误信息引导使用 offset 和 limit
                │
                ▼
          LLM 调用 Grep(pattern, path, output_mode="content")
                │
                ▼
          ripgrep 返回匹配行（含行号）
                │
                ├─ 结果 < 250 条 → 一次性返回
                └─ 结果 ≥ 250 条 → 截断 + 分页提示
                │
                ▼
          LLM 从 Grep 结果中提取行号
                │
                ▼
          LLM 调用 Read(file_path, offset=目标行号, limit=读取范围)
                │
                ▼
          Read 返回指定行范围的内容（此时 limit 已指定，不施加 maxSizeBytes 限制）
```

【**关键细节**】当 LLM 指定了 `limit` 参数后，`maxSizeBytes` 传入 `undefined`，不再施加 256KB 的文件总大小限制。这意味着"先搜后读"模式下，只要 offset/limit 划定的范围不超过 `maxTokens`（25000 tokens），就能成功读取大文件的任意局部。

### 2. 用户只说"读取分析一下"——LLM 怎么知道搜什么？

上一节描述了"先搜后读"的协作模式，但有一个关键问题：**如果用户只是说"读取这个文件分析一下"，LLM 怎么知道要 Grep 什么关键词？**

#### 2.1 错误信息中的线索

Read 工具的两道关卡在抛出错误时，会同时给出两条路径：

```typescript
// claude-code-source/src/utils/readFileInRange.ts
`File content (${formatFileSize(sizeInBytes)}) exceeds maximum allowed size (${formatFileSize(maxSizeBytes)}). Use offset and limit parameters to read specific portions of the file, or search for specific content instead of reading the whole file.`
```

```typescript
// claude-code-source/src/tools/FileReadTool/FileReadTool.ts
`File content (${tokenCount} tokens) exceeds maximum allowed tokens (${maxTokens}). Use offset and limit parameters to read specific portions of the file, or search for specific content instead of reading the whole file.`
```

注意两条路径：
1. **Use offset and limit** → 分块顺序读取（盲读，不需要知道内容）
2. **Search for specific content** → 先搜后读（需要知道搜什么）

#### 2.2 LLM 的实际策略：盲读优先

当用户没有提供具体搜索目标时，LLM 的典型行为是**选择路径 1 —— 分块盲读**：

```
LLM 尝试 Read(file_path)          ← 无 offset/limit
        │
        ▼
  文件 > 256KB / > 25000 tokens?
        │
        └─ 是 → 抛出 FileTooLargeError / MaxFileReadTokenExceededError
                │
                ▼
          LLM 选择策略 A 或 B
                │
                ├─ 策略 A：分块盲读（无搜索关键词时）
                │   Read(file_path, offset=1, limit=500)
                │   Read(file_path, offset=501, limit=500)
                │   Read(file_path, offset=1001, limit=500)
                │   ... 直到读完
                │
                └─ 策略 B：先搜后读（有搜索关键词时）
                    Grep(pattern, path)  →  得到行号
                    Read(file_path, offset=行号, limit=范围)
```

**分块盲读**时，LLM 通常选择一个合理的 `limit` 值（如 500、1000 行），从 `offset=1` 开始逐块读取，通过每块末尾的行号判断是否还有后续内容。

#### 2.3 什么时候 LLM 会主动用 Grep？

LLM 会在以下情况**自行推断**搜索关键词，走"先搜后读"路径：

<table>
  <thead>
    <tr><th>场景</th><th>推断的搜索 pattern</th><th>依据</th></tr>
  </thead>
  <tbody>
    <tr><td>用户说"找到 X 相关的代码"</td><td><code>X</code></td><td>用户直接提供了关键词</td></tr>
    <tr><td>用户说"看看这个文件的配置"（JS 文件）</td><td><code>export|module\.exports|config</code></td><td>基于文件类型和常见模式推断</td></tr>
    <tr><td>用户说"分析一下错误处理逻辑"</td><td><code>catch|error|throw|Error</code></td><td>从用户意图推断相关关键词</td></tr>
    <tr><td>用户说"看看 API 路由"（Express 项目）</td><td><code>router\.(get|post|put|delete)|app\.(get|post)</code></td><td>基于框架约定推断</td></tr>
    <tr><td>先 <code>ls</code> 看到了文件结构（TS 项目）</td><td><code>class|interface|export</code></td><td>基于已掌握的上下文推断</td></tr>
  </tbody>
</table>

#### 2.4 Read Prompt 中的间接引导

Read 工具的 Prompt 本身也在引导 LLM 的行为：

```typescript
// claude-code-source/src/tools/FileReadTool/prompt.ts
// 默认模式：鼓励全量读取
export const OFFSET_INSTRUCTION_DEFAULT =
  "- You can optionally specify a line offset and limit (especially handy for long files), but it's recommended to read the whole file by not providing these parameters"

// targetedRangeNudge 模式：鼓励精准读取
export const OFFSET_INSTRUCTION_TARGETED =
  '- When you already know which part of the file you need, only read that part. This can be important for larger files.'
```

以及提示中提到的默认行数限制暗示：

```typescript
// claude-code-source/src/tools/FileReadTool/prompt.ts
`By default, it reads up to ${MAX_LINES_TO_READ} lines starting from the beginning of the file`
// MAX_LINES_TO_READ = 2000
```

当 `targetedRangeNudge` 被启用（由 GrowthBook 实验 `tengu_amber_wren` 控制）时，Prompt 从"建议全量读"切换为"建议精准读"，间接鼓励 LLM 先定位再读取。

#### 2.5 上下文建议系统的辅助

当 Read 结果占据了过多上下文时，`contextSuggestions.ts` 会向 LLM 发出优化建议：

```typescript
// claude-code-source/src/utils/contextSuggestions.ts
// Read 工具消耗过多 token 时的建议
case FILE_READ_TOOL_NAME:
  return {
    severity: 'info',
    title: `Read results using ${tokenStr} tokens (${percent.toFixed(0)}%)`,
    detail:
      'Use offset and limit parameters to read only the sections you need. Avoid re-reading entire files when you only need a few lines.',
    savingsTokens: Math.floor(tokens * 0.3),
  }

// Bash 工具消耗过多 token 时，也会建议用 Read 替代 cat
case BASH_TOOL_NAME:
  return {
    severity: 'warning',
    title: `Bash results using ${tokenStr} tokens (${percent.toFixed(0)}%)`,
    detail:
      'Pipe output through head, tail, or grep to reduce result size. Avoid cat on large files — use Read with offset/limit instead.',
  }
```

这些**不是硬性约束**，而是上下文层面的"软提醒"，帮助 LLM 在后续对话中调整读取策略。

#### 2.6 完整决策流程

```
用户："读取这个文件分析一下"
        │
        ▼
LLM 调用 Read(file_path)     ← 无 offset/limit，试图全量读取
        │
        ▼
  ┌─── 文件 ≤ 256KB 且 ≤ 25000 tokens？
  │       │
  │       ├─ 是 → 成功返回全部内容 → LLM 直接分析
  │       │
  │       └─ 否 → 抛出错误，提示 offset/limit 或 search
  │               │
  │               ▼
  │         LLM 判断：用户是否提供了搜索线索？
  │               │
  │         ┌─────┴─────┐
  │         │           │
  │    否（盲读）    是（有线索）
  │         │           │
  │    分块顺序读    Grep 定位行号
  │    offset=1      ↓
  │    limit=500     Read(offset=行号)
  │    → 501         ↓
  │    → 1001        精准读取目标区域
  │    ...
  │
  └── 若后续 Read 结果占上下文过多
          │
          ▼
    contextSuggestions 发出软提醒
    "Use offset and limit parameters
     to read only the sections you need"
```

**核心结论**：当用户没有提供具体搜索目标时，LLM **不会凭空猜测 Grep 关键词**，而是走分块盲读路径。系统通过错误信息中的 "Use offset and limit" 引导、Prompt 中的 `targetedRangeNudge` 切换、以及上下文建议系统的软提醒，共同引导 LLM 在"全量读取失败"后采取合理的分块读取策略。

### 3. 首次读取大文件时的实际行为

回到最初的问题，当 Claude 首次读取一个大文件时：

1. **读多少**：`offset = 1`，`limit = undefined`，即从第 1 行开始，不限行数，试图读取**整个文件**
2. **谁决定**：
   - Prompt 层面，`MAX_LINES_TO_READ = 2000` 暗示 LLM "默认最多 2000 行"，但这只是提示
   - 代码层面，`maxSizeBytes = 256KB` 和 `maxTokens = 25000` 才是实际限制
   - `maxSizeBytes` 在读取前通过 stat 预检文件总大小
   - `maxTokens` 在读取后通过精确计数校验输出 token 数
3. **怎么读**：
   - 小于 10MB 的常规文件：一次性全量读入内存，再按行号范围筛选
   - 大于 10MB 或非常规文件：流式读取，范围外的行只计数不缓存
4. **超限怎么办**：两道关卡都会抛出错误，错误信息引导 LLM 使用 `offset` 和 `limit` 参数分块读取

## 十、 关键常量速查

| 常量 | 值 | 来源 |
|------|-----|------|
| `FILE_READ_TOOL_NAME` | `'Read'` | [`src/tools/FileReadTool/prompt.ts`](../../claude-code-source/src/tools/FileReadTool/prompt.ts#L5) |
| `MAX_LINES_TO_READ` | 2000 | [`src/tools/FileReadTool/prompt.ts`](../../claude-code-source/src/tools/FileReadTool/prompt.ts#L10) |
| `DEFAULT_MAX_OUTPUT_TOKENS` | 25000 | [`src/tools/FileReadTool/limits.ts`](../../claude-code-source/src/tools/FileReadTool/limits.ts#L18) |
| `MAX_OUTPUT_SIZE` | 256KB (0.25MB) | [`src/utils/file.ts`](../../claude-code-source/src/utils/file.ts#L48) |
| `FAST_PATH_MAX_SIZE` | 10MB | [`src/utils/readFileInRange.ts`](../../claude-code-source/src/utils/readFileInRange.ts#L44) |
| `READ_FILE_STATE_CACHE_SIZE` | 100 条目 | [`src/utils/fileStateCache.ts`](../../claude-code-source/src/utils/fileStateCache.ts#L18) |
| `DEFAULT_MAX_CACHE_SIZE_BYTES` | 25MB | [`src/utils/fileStateCache.ts`](../../claude-code-source/src/utils/fileStateCache.ts#L22) |

---
*本文档由 markdowncli 技能辅助生成*

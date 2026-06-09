<!-- more -->

## 一、 调用 MCP 工具与原始返回

MCP 工具调用通过 MCP SDK 的 `client.callTool()` 发起，结果通过 `Promise.race` 与超时机制竞争获取：

```typescript
// claude-code-source/src/services/mcp/client.ts
const result = await Promise.race([
  client.callTool(
    { name: tool, arguments: args, _meta: meta },
    CallToolResultSchema,
    { signal, timeout: timeoutMs, onprogress: ... },
  ),
  timeoutPromise,
])
```

超时时间由 `getMcpToolTimeoutMs()` 决定。若工具返回了 `isError: true`，则提取错误信息并抛出 `McpToolCallError`。成功时，原始结果进入 `processMCPResult()` 处理。

## 二、 原始结果格式归一化

### 1. 三种返回格式

MCP 协议允许服务端以不同格式返回数据，[`transformMCPResult()`](../claude-code-source/src/services/mcp/client.ts#L2662) 将其统一归一化为三种类型：

| 类型 | 触发条件 | 转换方式 |
|------|----------|----------|
| `toolResult` | 返回对象包含 `toolResult` 字段 | `String(result.toolResult)` |
| `structuredContent` | 返回对象包含 `structuredContent` 字段 | `jsonStringify(result.structuredContent)` |
| `contentArray` | 返回对象包含 `content` 数组字段 | 逐项调用 `transformResultContent()` 转换 |

### 2. 单项内容转换 — `transformResultContent()`

[`transformResultContent()`](../claude-code-source/src/services/mcp/client.ts#L2478) 处理 `contentArray` 中的每一项：

- **text**：直接转为 `TextBlockParam`
- **image**：经过 `maybeResizeAndDownsampleImageBuffer()` 压缩后转为 `ImageBlockParam`
- **audio**：通过 `persistBlobToTextBlock()` 持久化为文件，返回文件路径文本
- **resource（文本型）**：添加 `[Resource from server at uri]` 前缀后转为文本
- **resource（图片型 blob）**：压缩后转为 `ImageBlockParam`
- **resource（非图片型 blob）**：通过 `persistBlobToTextBlock()` 持久化为文件
- **resource_link**：转为 `[Resource link: name] uri` 格式文本

## 三、 核心决策 — 超大内容如何处理

### 1. 决策入口 — `processMCPResult()`

[`processMCPResult()`](../claude-code-source/src/services/mcp/client.ts#L2720) 是 MCP 结果处理的**核心决策函数**，决定内容是原样传递、截断还是持久化为文件。决策流程如下：

```
processMCPResult(result)
  │
  ├─ IDE 工具？ ──→ 直接返回（跳过大小检查）
  │
  ├─ 内容小于阈值？ ──→ 直接返回原内容
  │
  ├─ ENABLE_MCP_LARGE_OUTPUT_FILES 被禁用？ ──→ 截断处理
  │
  ├─ 内容为空？ ──→ 返回空
  │
  ├─ 内容包含图片？ ──→ 截断处理（图片无法 JSON 持久化）
  │
  └─ 以上均不满足 ──→ 持久化为文件 + 返回读取指引
```

### 2. 大小阈值判定

#### 2.1 MCP 层的大小阈值

MCP 输出的 token 上限由 [`getMaxMcpOutputTokens()`](../claude-code-source/src/utils/mcpValidation.ts#L26) 决定，优先级为：

1. 环境变量 `MAX_MCP_OUTPUT_TOKENS`（用户显式覆盖）
2. GrowthBook 特性开关 `tengu_satin_quoll` 中的 `mcp_tool` 键
3. 硬编码默认值 `25000` tokens

```typescript
// claude-code-source/src/utils/mcpValidation.ts
const DEFAULT_MAX_MCP_OUTPUT_TOKENS = 25000
```

#### 2.2 是否需要截断的判断 — `mcpContentNeedsTruncation()`

[`mcpContentNeedsTruncation()`](../claude-code-source/src/utils/mcpValidation.ts#L151) 采用**两级判断**策略：

1. **快速启发式估算**：先通过 `getContentSizeEstimate()` 做粗略 token 估算，若小于 `阈值 × 0.5`（`MCP_TOKEN_COUNT_THRESHOLD_FACTOR = 0.5`），直接判定不需要截断
2. **精确 API 计数**：若启发式估算不够确定，调用 `countMessagesTokensWithAPI()` 精确计算 token 数

```typescript
// claude-code-source/src/utils/mcpValidation.ts
if (contentSizeEstimate <= getMaxMcpOutputTokens() * MCP_TOKEN_COUNT_THRESHOLD_FACTOR) {
  return false  // 粗估不到阈值一半，肯定不需要截断
}
// 否则精确计数
const tokenCount = await countMessagesTokensWithAPI(messages, [])
return !!(tokenCount && tokenCount > getMaxMcpOutputTokens())
```

### 3. 截断实现 — `truncateMcpContent()`

[`truncateMcpContent()`](../claude-code-source/src/utils/mcpValidation.ts#L180) 按字符数截断（`maxTokens × 4`），并追加截断提示信息：

```typescript
// claude-code-source/src/utils/mcpValidation.ts
function getTruncationMessage(): string {
  return `\n\n[OUTPUT TRUNCATED - exceeded ${getMaxMcpOutputTokens()} token limit]\n\nThe tool output was truncated. ...`
}
```

- **字符串内容**：`content.slice(0, maxChars) + truncationMessage`
- **ContentBlock 数组**：逐块累加，超限时截断文本块；图片块则尝试压缩到剩余空间内

## 四、 大输出持久化为文件

### 1. 触发条件

当满足以下所有条件时，MCP 工具返回内容会被持久化为文件：

- 内容超过 `mcpContentNeedsTruncation()` 的 token 阈值
- 环境变量 `ENABLE_MCP_LARGE_OUTPUT_FILES` 未被显式设置为 falsy 值（`0`、`false`、`no`、`off`）
- 内容中**不包含**图片块
- 服务端名称不是 `ide`

### 2. 文件命名规则

文件 ID 由服务端名、工具名和时间戳组成，经 [`normalizeNameForMCP()`](../claude-code-source/src/services/mcp/normalization.ts#L17) 归一化：

```typescript
// claude-code-source/src/services/mcp/client.ts
const timestamp = Date.now()
const persistId = `mcp-${normalizeNameForMCP(name)}-${normalizeNameForMCP(tool)}-${timestamp}`
```

`normalizeNameForMCP()` 将非 `^[a-zA-Z0-9_-]$` 的字符替换为下划线。最终文件名为 `{persistId}.json` 或 `{persistId}.txt`，取决于内容是否为数组类型。

### 3. 文件存储路径

文件的存储路径由三层拼接而成：

```
~/.claude/projects/{sanitized-workspace-path}/{session-id}/tool-results/{persistId}.{json|txt}
```

- **根目录**：[`getClaudeConfigHomeDir()`](../claude-code-source/src/utils/envUtils.ts#L7) 返回 `CLAUDE_CONFIG_DIR` 或 `~/.claude`
- **项目目录**：[`getProjectDir()`](../claude-code-source/src/utils/sessionStoragePortable.ts#L329) 返回 `{根目录}/projects/{sanitized-cwd}`
- **会话目录**：[`getSessionDir()`](../claude-code-source/src/utils/toolResultStorage.ts#L97) 返回 `{项目目录}/{sessionId}`
- **工具结果目录**：[`getToolResultsDir()`](../claude-code-source/src/utils/toolResultStorage.ts#L104) 返回 `{会话目录}/tool-results`

```typescript
// claude-code-source/src/utils/toolResultStorage.ts
export const TOOL_RESULTS_SUBDIR = 'tool-results'

function getSessionDir(): string {
  return join(getProjectDir(getOriginalCwd()), getSessionId())
}

export function getToolResultsDir(): string {
  return join(getSessionDir(), TOOL_RESULTS_SUBDIR)
}

export function getToolResultPath(id: string, isJson: boolean): string {
  const ext = isJson ? 'json' : 'txt'
  return join(getToolResultsDir(), `${id}.${ext}`)
}
```

### 4. 文件写入逻辑

[`persistToolResult()`](../claude-code-source/src/utils/toolResultStorage.ts#L137) 使用 `wx` 标志（排他写入）避免重复写入同一文件：

```typescript
// claude-code-source/src/utils/toolResultStorage.ts
await writeFile(filepath, contentStr, { encoding: 'utf-8', flag: 'wx' })
```

若文件已存在（`EEXIST`），则跳过写入，继续生成预览。这是为了在 microcompact 重放原始消息时避免重复写入。

### 5. 持久化失败时的降级策略

若文件写入失败，`processMCPResult()` 会返回错误信息字符串替代原始内容：

```typescript
// claude-code-source/src/services/mcp/client.ts
if (isPersistError(persistResult)) {
  return `Error: result (${contentLength.toLocaleString()} characters) exceeds maximum allowed tokens. Failed to save output to file: ${persistResult.error}. ...`
}
```

## 五、 持久化后发送给 LLM 的内容

### 1. MCP 层持久化后的返回 — `getLargeOutputInstructions()`

当 MCP 层持久化成功后，[`getLargeOutputInstructions()`](../claude-code-source/src/utils/mcpOutputStorage.ts#L39) 生成一段**读取指引文本**，替代原始内容发送给 LLM：

```typescript
// claude-code-source/src/utils/mcpOutputStorage.ts
export function getLargeOutputInstructions(
  rawOutputPath: string,
  contentLength: number,
  formatDescription: string,
  maxReadLength?: number,
): string {
  const baseInstructions =
    `Error: result (${contentLength.toLocaleString()} characters) exceeds maximum allowed tokens. Output has been saved to ${rawOutputPath}.\n` +
    `Format: ${formatDescription}\n` +
    `Use offset and limit parameters to read specific portions of the file, search within it for specific content, and jq to make structured queries.\n` +
    `REQUIREMENTS FOR SUMMARIZATION/ANALYSIS/REVIEW:\n` +
    `- You MUST read the content from the file at ${rawOutputPath} in sequential chunks until 100% of the content has been read.\n`
  // ... truncation warning + completion requirement
}
```

这段指引包含：

- 文件路径和内容大小
- 数据格式描述（纯文本 / JSON / JSON array + schema）
- 要求 LLM 必须分块读取文件全部内容后才能生成摘要
- 截断警告：若读取时出现截断，必须减小块大小
- 完成要求：在产出任何摘要或分析前，必须明确描述已读取的部分；若未读完全部内容，必须显式声明

这是一个**两阶段**的设计：

1. **第一阶段（系统自动）**：工具返回结果过大 → 系统自动持久化为磁盘文件 → 原始内容**不发给 LLM**，用上述指引文本替代放入 `tool_result` 消息块
2. **第二阶段（LLM 自主）**：LLM 收到指引后，**自行决定**读取策略——用 Read 工具按 offset/limit 分块读取、用 Search/Grep 搜索特定内容、用 jq 做 JSON 查询等。系统不替 LLM 决定读多少、怎么读，只是强制要求必须读完全部内容后才能给出摘要

### 2. 通用工具层持久化后的返回 — `buildLargeToolResultMessage()`

在通用工具层（非 MCP 专属），[`buildLargeToolResultMessage()`](../claude-code-source/src/utils/toolResultStorage.ts#L189) 生成带有预览的消息：

```typescript
// claude-code-source/src/utils/toolResultStorage.ts
export function buildLargeToolResultMessage(result: PersistedToolResult): string {
  let message = `${PERSISTED_OUTPUT_TAG}\n`
  message += `Output too large (${formatFileSize(result.originalSize)}). Full output saved to: ${result.filepath}\n\n`
  message += `Preview (first ${formatFileSize(PREVIEW_SIZE_BYTES)}):\n`
  message += result.preview
  message += result.hasMore ? '\n...\n' : '\n'
  message += PERSISTED_OUTPUT_CLOSING_TAG
  return message
}
```

其中 `PREVIEW_SIZE_BYTES = 2000`，预览内容就是工具返回结果的**最前面部分**，由 [`generatePreview()`](../claude-code-source/src/utils/toolResultStorage.ts#L339) 生成：

```typescript
// claude-code-source/src/utils/toolResultStorage.ts
export function generatePreview(
  content: string,
  maxBytes: number,
): { preview: string; hasMore: boolean } {
  if (content.length <= maxBytes) {
    return { preview: content, hasMore: false }
  }
  // 在 maxBytes 范围内找最后一个换行符，避免行中断裂
  const truncated = content.slice(0, maxBytes)
  const lastNewline = truncated.lastIndexOf('\n')
  // 换行符位置超过 50% 才用换行符截断，否则按字节硬截
  const cutPoint = lastNewline > maxBytes * 0.5 ? lastNewline : maxBytes
  return { preview: content.slice(0, cutPoint), hasMore: true }
}
```

截断策略：先取前 2000 字节，然后在其中找最后一个换行符——若换行符位置在 50%（1000 字节）之后就从换行符处截断，否则直接按 2000 字节硬截。消息被 `<persisted-output>` 标签包裹。

## 六、 通用工具层的二次持久化

### 1. 两层大小管控体系

MCP 结果经过 `processMCPResult()` 处理后，还会进入通用工具层 [`maybePersistLargeToolResult()`](../claude-code-source/src/utils/toolResultStorage.ts#L272) 进行二次检查。这是因为存在**两层独立的大小管控**：

| 层级 | 位置 | 阈值基准 | 控制粒度 |
|------|------|----------|----------|
| MCP 层 | `processMCPResult()` | 25000 tokens（默认） | 单个 MCP 工具调用的返回 |
| 通用工具层 | `maybePersistLargeToolResult()` | 50000 字符 / 100000 字符（MCP） | 单个工具的最终输出 |

### 2. 通用工具层的阈值

[`getPersistenceThreshold()`](../claude-code-source/src/utils/toolResultStorage.ts#L55) 计算每个工具的持久化阈值：

```typescript
// claude-code-source/src/utils/toolResultStorage.ts
export const DEFAULT_MAX_RESULT_SIZE_CHARS = 50_000  // 全局默认上限

export function getPersistenceThreshold(toolName, declaredMaxResultSizeChars): number {
  // Read 工具的 maxResultSizeChars 为 Infinity，跳过持久化
  if (!Number.isFinite(declaredMaxResultSizeChars)) return declaredMaxResultSizeChars
  // GrowthBook 覆盖优先
  const override = overrides?.[toolName]
  if (typeof override === 'number' && ...) return override
  // 取工具声明值与全局上限的较小值
  return Math.min(declaredMaxResultSizeChars, DEFAULT_MAX_RESULT_SIZE_CHARS)
}
```

MCP 工具声明的 `maxResultSizeChars = 100_000`，因此实际阈值为 `min(100000, 50000) = 50000` 字符。

### 3. 特殊跳过条件

- **空内容**：返回 `(toolName completed with no output)` 占位文本
- **包含图片块**：跳过持久化，直接发送原内容（图片需保持压缩格式）
- **`maxResultSizeChars = Infinity`**（如 Read 工具）：永不持久化，避免循环读取

## 七、 消息级聚合预算

### 1. 问题场景

当 N 个并行工具调用各自产出较大结果时，即使单个结果未超阈值，汇总后的单条 user message 可能极大（例如 10 × 40K = 400K）。

### 2. 聚合预算机制

[`enforceToolResultBudget()`](../claude-code-source/src/utils/toolResultStorage.ts#L769) 在 `query.ts` 中每次 API 调用前执行，对**单条 API 级别的 user message** 的 tool_result 块总量施加预算：

```typescript
// claude-code-source/src/constants/toolLimits.ts
export const MAX_TOOL_RESULTS_PER_MESSAGE_CHARS = 200_000  // 每条消息 200K 字符
```

### 3. 替换策略

当一条消息内的 tool_result 总量超过预算时：

1. 将所有**未见过**的（fresh）候选项按大小降序排列
2. 从最大的开始，逐个持久化到磁盘，用预览替换原始内容
3. 直到总量降到预算以下
4. **已冻结的**（frozen，之前已见过且未替换的）结果不再替换（保持 prompt cache 稳定性）
5. **之前替换过的**（mustReapply），直接使用缓存的替换文本（零 I/O，字节一致）

### 4. 状态追踪

替换状态通过 `ContentReplacementState` 跨轮次持久化：

- `seenIds: Set<string>` — 所有已见过的 tool_use_id
- `replacements: Map<string, string>` — 被替换的结果 ID → 替换文本

这确保了每次 API 调用对相同结果做出相同决策，保持 prompt cache 前缀稳定。

## 八、 完整流程图

```
MCP SDK callTool() 返回原始结果
        │
        ▼
  检查 isError → 抛出 McpToolCallError
        │
        ▼
  transformMCPResult()  ← 格式归一化（toolResult / structuredContent / contentArray）
        │
        ▼
  processMCPResult()  ← MCP 层核心决策
        │
        ├── IDE 工具 → 直接返回
        ├── 小于阈值 → 直接返回
        ├── ENABLE_MCP_LARGE_OUTPUT_FILES 禁用 → truncateMcpContent()
        ├── 含图片 → truncateMcpContent()
        └── 超大输出 → persistToolResult() + getLargeOutputInstructions()
                                      │
                                      ▼
                               保存到 ~/.claude/projects/.../tool-results/
                               返回读取指引文本
        │
        ▼
  toolExecution.ts: addToolResult()
        │
        ▼
  processToolResultBlock() → maybePersistLargeToolResult()  ← 通用工具层二次检查
        │
        ├── 小于阈值 → 直接返回
        ├── 含图片 / Infinity → 跳过持久化
        └── 超过阈值 → persistToolResult() + buildLargeToolResultMessage()
                                      │
                                      ▼
                               返回 <persisted-output> 预览消息
        │
        ▼
  组装为 user message (tool_result block)
        │
        ▼
  query.ts: applyToolResultBudget()  ← 消息级聚合预算检查
        │
        ├── 总量不超预算 → 不变
        └── 总量超预算 → 替换最大块为预览
        │
        ▼
  snip → microcompact → context collapse
        │
        ▼
  组装 system prompt + messages → 发送至 LLM
```

## 九、 关键常量与环境变量

### 1. 常量速查

| 常量 | 值 | 来源 |
|------|-----|------|
| `DEFAULT_MAX_MCP_OUTPUT_TOKENS` | 25000 | [`src/utils/mcpValidation.ts`](../claude-code-source/src/utils/mcpValidation.ts#L16) |
| `MCP_TOKEN_COUNT_THRESHOLD_FACTOR` | 0.5 | [`src/utils/mcpValidation.ts`](../claude-code-source/src/utils/mcpValidation.ts#L14) |
| `DEFAULT_MAX_RESULT_SIZE_CHARS` | 50000 | [`src/constants/toolLimits.ts`](../claude-code-source/src/constants/toolLimits.ts#L13) |
| `MAX_TOOL_RESULT_TOKENS` | 100000 | [`src/constants/toolLimits.ts`](../claude-code-source/src/constants/toolLimits.ts#L22) |
| `MAX_TOOL_RESULT_BYTES` | 400000 | [`src/constants/toolLimits.ts`](../claude-code-source/src/constants/toolLimits.ts#L33) |
| `MAX_TOOL_RESULTS_PER_MESSAGE_CHARS` | 200000 | [`src/constants/toolLimits.ts`](../claude-code-source/src/constants/toolLimits.ts#L49) |
| `PREVIEW_SIZE_BYTES` | 2000 | [`src/utils/toolResultStorage.ts`](../claude-code-source/src/utils/toolResultStorage.ts#L109) |
| `IMAGE_TOKEN_ESTIMATE` | 1600 | [`src/utils/mcpValidation.ts`](../claude-code-source/src/utils/mcpValidation.ts#L15) |
| MCPTool.maxResultSizeChars | 100000 | [`src/tools/MCPTool/MCPTool.ts`](../claude-code-source/src/tools/MCPTool/MCPTool.ts#L35) |

### 2. 环境变量控制汇总

| 环境变量 | 作用 | 默认行为 |
|----------|------|----------|
| `MAX_MCP_OUTPUT_TOKENS` | 覆盖 MCP 输出 token 上限 | 25000 |
| `ENABLE_MCP_LARGE_OUTPUT_FILES` | 设为 falsy 禁用 MCP 大输出文件持久化 | 启用 |
| `CLAUDE_CONFIG_DIR` | 覆盖 Claude 配置根目录 | `~/.claude` |

---
*本文档由 markdowncli 技能辅助生成*

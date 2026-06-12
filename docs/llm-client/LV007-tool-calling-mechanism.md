<!-- more -->

## 一、 概述

Claude Code 通过 Anthropic API 的工具调用（Tool Use）机制实现 LLM 与外部工具的交互。核心流程为：LLM 在 API 请求的 `tools` 字段中获知可用工具 → 当需要执行操作时在响应中生成 `tool_use` 内容块 → Claude Code 执行工具并将结果以 `tool_result` 内容块回传 → LLM 根据结果决定是否继续调用工具或结束对话。

核心源码文件：

- [`src/tools.ts`](../../claude-code-source/src/tools.ts#L193)：工具注册与过滤
- [`src/utils/api.ts`](../../claude-code-source/src/utils/api.ts#L119)：工具 Schema 转换为 API 格式
- [`src/query.ts`](../../claude-code-source/src/query.ts#L307)：Agentic 循环主逻辑
- [`src/services/tools/toolOrchestration.ts`](../../claude-code-source/src/services/tools/toolOrchestration.ts#L19)：工具执行调度
- [`src/services/tools/toolExecution.ts`](../../claude-code-source/src/services/tools/toolExecution.ts#L337)：单个工具执行流程
- [`src/tools/BashTool/BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L420)：BashTool 实现

## 二、 LLM 如何知道有哪些内置工具可用

### 1. 工具注册中心

所有内置工具在 [`src/tools.ts`](../../claude-code-source/src/tools.ts#L193) 的 [`getAllBaseTools()`](../../claude-code-source/src/tools.ts#L193-L251) 函数中集中注册：

```typescript
// src/tools.ts#L193-L251
export function getAllBaseTools(): Tools {
  return [
    AgentTool,
    TaskOutputTool,
    BashTool,
    ...(hasEmbeddedSearchTools() ? [] : [GlobTool, GrepTool]),
    ExitPlanModeV2Tool,
    FileReadTool,
    FileEditTool,
    FileWriteTool,
    NotebookEditTool,
    WebFetchTool,
    TodoWriteTool,
    WebSearchTool,
    TaskStopTool,
    AskUserQuestionTool,
    SkillTool,
    EnterPlanModeTool,
    // ...条件性工具
  ]
}
```

### 2. 工具过滤与组装

并非所有注册的工具都会发送给 LLM。[`getTools()`](../../claude-code-source/src/tools.ts#L271-L327) 根据权限上下文和运行模式过滤工具：

```typescript
// src/tools.ts#L271-L327
export const getTools = (permissionContext: ToolPermissionContext): Tools => {
  // Simple 模式：仅 Bash、Read、Edit
  if (isEnvTruthy(process.env.CLAUDE_CODE_SIMPLE)) { ... }

  const tools = getAllBaseTools().filter(tool => !specialTools.has(tool.name))
  let allowedTools = filterToolsByDenyRules(tools, permissionContext)
  // ... REPL 模式过滤
  const isEnabled = allowedTools.map(_ => _.isEnabled())
  return allowedTools.filter((_, i) => isEnabled[i])
}
```

[`assembleToolPool()`](../../claude-code-source/src/tools.ts#L345-L367) 合并内置工具与 MCP 工具，内置工具在名称冲突时优先：

```typescript
// src/tools.ts#L345-L367
export function assembleToolPool(
  permissionContext: ToolPermissionContext,
  mcpTools: Tools,
): Tools {
  const builtInTools = getTools(permissionContext)
  const allowedMcpTools = filterToolsByDenyRules(mcpTools, permissionContext)
  return uniqBy(
    [...builtInTools].sort(byName).concat(allowedMcpTools.sort(byName)),
    'name',
  )
}
```

### 3. 工具 Schema 转换为 API 格式

[`toolToAPISchema()`](../../claude-code-source/src/utils/api.ts#L119-L266) 将内部 `Tool` 对象转换为 Anthropic API 的 `BetaToolUnion` 格式，这是 LLM 实际看到的工具定义：

```typescript
// src/utils/api.ts#L119-L266
export async function toolToAPISchema(
  tool: Tool,
  options: { ... },
): Promise<BetaToolUnion> {
  const cache = getToolSchemaCache()
  let base = cache.get(cacheKey)
  if (!base) {
    // 使用工具的 JSON Schema 或将 Zod schema 转换为 JSON Schema
    let input_schema = (
      'inputJSONSchema' in tool && tool.inputJSONSchema
        ? tool.inputJSONSchema
        : zodToJsonSchema(tool.inputSchema)
    ) as Anthropic.Tool.InputSchema

    base = {
      name: tool.name,
      description: await tool.prompt({ ... }),
      input_schema,
    }
    cache.set(cacheKey, base)
  }
  // 构建最终 schema，附带 defer_loading、cache_control 等字段
  const schema: BetaToolWithExtras = {
    name: base.name,
    description: base.description,
    input_schema: base.input_schema,
    ...(base.strict && { strict: true }),
    ...(base.eager_input_streaming && { eager_input_streaming: true }),
  }
  return schema as BetaTool
}
```

转换后的工具 Schema 结构示例（以 Bash 工具为例）：

```json
{
  "name": "Bash",
  "description": "Run a bash command...",
  "input_schema": {
    "type": "object",
    "properties": {
      "command": { "type": "string", "description": "The command to execute" },
      "timeout": { "type": "number", "description": "Optional timeout in milliseconds" },
      "description": { "type": "string", "description": "Clear, concise description..." }
    },
    "required": ["command"],
    "additionalProperties": false
  }
}
```

### 4. 工具 Schema 注入 API 请求

在 [`queryModel()`](../../claude-code-source/src/services/api/claude.ts#L1017) 中，工具 Schema 被批量转换并注入请求参数：

```typescript
// src/services/api/claude.ts#L1235-L1246
const toolSchemas = await Promise.all(
  filteredTools.map(tool =>
    toolToAPISchema(tool, {
      getToolPermissionContext: options.getToolPermissionContext,
      tools,
      agents: options.agents,
      allowedAgentTypes: options.allowedAgentTypes,
      model: options.model,
      deferLoading: willDefer(tool),
    }),
  ),
)
```

最终在 API 请求中，工具定义出现在 `tools` 字段，LLM 根据此字段得知可用的工具及其参数格式。

## 三、 当 LLM 需要调用工具时 Claude 怎么做的

### 1. Agentic 循环架构

Claude Code 的核心是一个 Agentic 循环，定义在 [`queryLoop()`](../../claude-code-source/src/query.ts#L307) 中：

```
┌─────────────────────────────────────────────────────────────┐
│                     while (true) 循环                        │
│                                                             │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │ 构建请求  │───>│ 调用 LLM API │───>│ 解析流式响应     │  │
│  │ (messages,│    │ (stream:true)│    │ (收集 tool_use   │  │
│  │  tools)   │    │              │    │  块)             │  │
│  └──────────┘    └──────────────┘    └────────┬─────────┘  │
│       ▲                                       │            │
│       │         ┌──────────────────┐          │            │
│       │         │ 组装下一轮消息    │<─────────┤            │
│       │         │ (assistant +     │          │            │
│       │         │  tool_results)   │    ┌─────▼──────┐    │
│       │         └──────────────────┘    │ needsFollow │    │
│       │                    │            │ Up = true?  │    │
│       │                    │            └─────┬──────┘    │
│       │                    │                  │            │
│       │                    │           ┌──────▼──────┐     │
│       │                    │           │ 执行工具    │     │
│       │                    └───────────│ runTools()  │     │
│       │                                └─────────────┘     │
│       │                                                    │
│       └─── needsFollowUp = false? → return completed ─────┤
│                                                            │
└────────────────────────────────────────────────────────────┘
```

### 2. 流式响应中检测 tool_use

在 [`query.ts#L826-L844`](../../claude-code-source/src/query.ts#L826-L844)，当流式接收到 assistant 消息时，检查是否包含 `tool_use` 内容块：

```typescript
// src/query.ts#L826-L844
if (message.type === 'assistant') {
  assistantMessages.push(message)

  const msgToolUseBlocks = message.message.content.filter(
    content => content.type === 'tool_use',
  ) as ToolUseBlock[]
  if (msgToolUseBlocks.length > 0) {
    toolUseBlocks.push(...msgToolUseBlocks)
    needsFollowUp = true    // 标记需要执行工具后继续循环
  }

  // 流式工具执行器：在流式接收期间就开始执行工具
  if (streamingToolExecutor && !toolUseContext.abortController.signal.aborted) {
    for (const toolBlock of msgToolUseBlocks) {
      streamingToolExecutor.addTool(toolBlock, message)
    }
  }
}
```

### 3. 工具执行的调度

[`runTools()`](../../claude-code-source/src/services/tools/toolOrchestration.ts#L19-L82) 负责调度工具执行，将工具调用分区（partition），并发安全的工具并行执行，非并发安全的工具串行执行：

```typescript
// src/services/tools/toolOrchestration.ts#L19-L82
export async function* runTools(
  toolUseMessages: ToolUseBlock[],
  assistantMessages: AssistantMessage[],
  canUseTool: CanUseToolFn,
  toolUseContext: ToolUseContext,
): AsyncGenerator<MessageUpdate, void> {
  for (const { isConcurrencySafe, blocks } of partitionToolCalls(
    toolUseMessages,
    currentContext,
  )) {
    if (isConcurrencySafe) {
      // 只读工具并行执行
      for await (const update of runToolsConcurrently(...)) { yield ... }
    } else {
      // 非只读工具串行执行
      for await (const update of runToolsSerially(...)) { yield ... }
    }
  }
}
```

分区逻辑在 [`partitionToolCalls()`](../../claude-code-source/src/services/tools/toolOrchestration.ts#L91-L116) 中，根据每个工具的 `isConcurrencySafe()` 方法判断：

```typescript
// src/services/tools/toolOrchestration.ts#L91-L116
function partitionToolCalls(
  toolUseMessages: ToolUseBlock[],
  toolUseContext: ToolUseContext,
): Batch[] {
  return toolUseMessages.reduce((acc: Batch[], toolUse) => {
    const tool = findToolByName(toolUseContext.options.tools, toolUse.name)
    const parsedInput = tool?.inputSchema.safeParse(toolUse.input)
    const isConcurrencySafe = parsedInput?.success
      ? (() => { try { return Boolean(tool?.isConcurrencySafe(parsedInput.data)) } catch { return false } })()
      : false
    if (isConcurrencySafe && acc[acc.length - 1]?.isConcurrencySafe) {
      acc[acc.length - 1]!.blocks.push(toolUse)
    } else {
      acc.push({ isConcurrencySafe, blocks: [toolUse] })
    }
    return acc
  }, [])
}
```

### 4. 单个工具的执行流程

[`runToolUse()`](../../claude-code-source/src/services/tools/toolExecution.ts#L337-L489) 是单个工具执行的核心函数，流程为：

1. **工具查找**（[第 345-356 行](../../claude-code-source/src/services/tools/toolExecution.ts#L345-L356)）：根据 `toolUse.name` 在可用工具列表中查找对应工具
2. **输入验证**（[第 615 行](../../claude-code-source/src/services/tools/toolExecution.ts#L615)）：用 Zod schema 校验 LLM 提供的输入参数
3. **权限检查**（[第 921 行](../../claude-code-source/src/services/tools/toolExecution.ts#L921)）：通过 `canUseTool()` 和 Hook 机制检查权限
4. **执行工具**（[第 1207 行](../../claude-code-source/src/services/tools/toolExecution.ts#L1207)）：调用 `tool.call()` 执行实际逻辑
5. **结果映射**（[第 1292 行](../../claude-code-source/src/services/tools/toolExecution.ts#L1292)）：调用 `tool.mapToolResultToToolResultBlockParam()` 将结果转为 API 格式

```typescript
// src/services/tools/toolExecution.ts#L1207-L1222
const result = await tool.call(
  callInput,
  { ...toolUseContext, toolUseId: toolUseID, userModified: ... },
  canUseTool,
  assistantMessage,
  progress => { onToolProgress({ toolUseID: progress.toolUseID, data: progress.data }) },
)
```

```typescript
// src/services/tools/toolExecution.ts#L1292-L1295
const mappedToolResultBlock = tool.mapToolResultToToolResultBlockParam(
  result.data,
  toolUseID,
)
```

## 四、 LLM 的工具调用请求是怎样的

### 1. tool_use 内容块结构

当 LLM 决定调用工具时，它会在 assistant 消息的 `content` 数组中生成 `type: "tool_use"` 的内容块。格式如下：

```json
{
  "type": "tool_use",
  "id": "toolu_01ABC123DEF",
  "name": "Bash",
  "input": {
    "command": "ls -la",
    "description": "List files in current directory"
  }
}
```

各字段含义：

- `type`：固定为 `"tool_use"`
- `id`：由 API 生成的唯一标识符，用于匹配对应的 `tool_result`
- `name`：工具名称，对应 `tools` 数组中的 `name` 字段
- `input`：工具输入参数，JSON 对象，必须符合工具的 `input_schema`

### 2. 流式到达过程

在流式模式下，`tool_use` 块通过多个 SSE 事件增量到达：

```
event: content_block_start
data: {
  "type": "content_block_start",
  "index": 0,
  "content_block": {
    "type": "tool_use",
    "id": "toolu_01ABC123DEF",
    "name": "Bash",
    "input": ""
  }
}

event: content_block_delta
data: {
  "type": "content_block_delta",
  "index": 0,
  "delta": {
    "type": "input_json_delta",
    "partial_json": "{\"command\":\"ls"
  }
}

event: content_block_delta
data: {
  "type": "content_block_delta",
  "index": 0,
  "delta": {
    "type": "input_json_delta",
    "partial_json": " -la\",\"description\":\"List files\"}"
  }
}

event: content_block_stop
data: {
  "type": "content_block_stop",
  "index": 0
}
```

Claude Code 采用字符串拼接策略处理 `input_json_delta`，在 [`claude.ts#L2111`](../../claude-code-source/src/services/api/claude.ts#L2111) 直接拼接：

```typescript
contentBlock.input += delta.partial_json
```

在 `content_block_stop` 后统一解析完整 JSON 字符串（[`messages.ts#L2676-L2694`](../../claude-code-source/src/utils/messages.ts#L2676-L2694)），避免 O(n²) 解析开销。

### 3. LLM 同时请求多个工具

LLM 可以在一次响应中请求调用多个工具，产生多个 `tool_use` 内容块：

```json
{
  "role": "assistant",
  "content": [
    { "type": "text", "text": "让我查看当前目录的文件和 Git 状态" },
    {
      "type": "tool_use",
      "id": "toolu_01A",
      "name": "Bash",
      "input": { "command": "ls -la", "description": "List files in current directory" }
    },
    {
      "type": "tool_use",
      "id": "toolu_01B",
      "name": "Bash",
      "input": { "command": "git status", "description": "Show working tree status" }
    }
  ]
}
```

## 五、 工具执行结果怎么给 LLM 的

### 1. tool_result 格式

工具执行结果以 `tool_result` 内容块的形式，包装在 `role: "user"` 的消息中回传给 LLM。这是 Anthropic API 的约定：工具结果必须作为 user 消息发送。

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01ABC123DEF",
      "content": "total 48\ndrwxr-xr-x  5 user user 4096 Jun 12 ...\n..."
    }
  ]
}
```

各字段含义：

- `type`：固定为 `"tool_result"`
- `tool_use_id`：与请求中的 `tool_use.id` 一一对应
- `content`：执行结果，可以是字符串或内容块数组
- `is_error`：可选，标记是否为错误结果

### 2. 结果映射：mapToolResultToToolResultBlockParam

每个工具通过 [`mapToolResultToToolResultBlockParam()`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L555-L622) 方法将内部结果转为 API 格式。以 BashTool 为例：

```typescript
// src/tools/BashTool/BashTool.tsx#L555-L622
mapToolResultToToolResultBlockParam({
  interrupted, stdout, stderr, isImage,
  backgroundTaskId, backgroundedByUser, assistantAutoBackgrounded,
  structuredContent, persistedOutputPath, persistedOutputSize
}, toolUseID): ToolResultBlockParam {
  // 1. 结构化内容路径
  if (structuredContent && structuredContent.length > 0) {
    return { tool_use_id: toolUseID, type: 'tool_result', content: structuredContent };
  }
  // 2. 图片输出路径
  if (isImage) {
    const block = buildImageToolResult(stdout, toolUseID);
    if (block) return block;
  }
  // 3. 大输出持久化路径（输出过大时写入文件，仅发送预览）
  if (persistedOutputPath) {
    processedStdout = buildLargeToolResultMessage({
      filepath: persistedOutputPath,
      originalSize: persistedOutputSize ?? 0,
      isJson: false,
      preview: preview.preview,
      hasMore: preview.hasMore
    });
  }
  // 4. 默认文本路径：拼接 stdout、stderr、backgroundInfo
  return {
    tool_use_id: toolUseID,
    type: 'tool_result',
    content: [processedStdout, errorMessage, backgroundInfo].filter(Boolean).join('\n'),
    is_error: interrupted
  };
}
```

### 3. 结果包装：createUserMessage

工具结果通过 [`createUserMessage()`](../../claude-code-source/src/utils/messages.ts#L460-L523) 包装为内部消息对象：

```typescript
// src/services/tools/toolExecution.ts#L1456-L1473
resultingMessages.push({
  message: createUserMessage({
    content: contentBlocks,     // 包含 tool_result 块
    toolUseResult: toolUseResult,
    sourceToolAssistantUUID: assistantMessage.uuid,
  }),
})
```

### 4. 消息组装到下一轮请求

在 [`query.ts#L1714-L1728`](../../claude-code-source/src/query.ts#L1714-L1728)，工具结果与历史消息合并，组装为下一轮循环的消息列表：

```typescript
// src/query.ts#L1714-L1728
const next: State = {
  messages: [...messagesForQuery, ...assistantMessages, ...toolResults],
  toolUseContext: toolUseContextWithQueryTracking,
  autoCompactTracking: tracking,
  turnCount: nextTurnCount,
  // ...
  transition: { reason: 'next_turn' },
}
state = next
```

在下一轮 API 调用前，[`normalizeMessagesForAPI()`](../../claude-code-source/src/utils/messages.ts#L1989) 会规范化消息列表（合并连续 user 消息等）。

### 5. 错误结果封装

工具执行出错时，结果同样以 `tool_result` 返回，但 `is_error: true`：

```typescript
// src/services/tools/toolExecution.ts#L396-L408 (工具不存在)
yield {
  message: createUserMessage({
    content: [{
      type: 'tool_result',
      content: `<tool_use_error>Error: No such tool available: ${toolName}</tool_use_error>`,
      is_error: true,
      tool_use_id: toolUse.id,
    }],
  }),
}

// src/services/tools/toolExecution.ts#L664-L679 (输入验证失败)
return [{
  message: createUserMessage({
    content: [{
      type: 'tool_result',
      content: `<tool_use_error>InputValidationError: ${errorContent}</tool_use_error>`,
      is_error: true,
      tool_use_id: toolUseID,
    }],
  }),
}]

// src/services/tools/toolExecution.ts#L1030-L1037 (权限被拒绝)
const messageContent: ContentBlockParam[] = [{
  type: 'tool_result',
  content: errorMessage,
  is_error: true,
  tool_use_id: toolUseID,
}]
```

## 六、 LLM 怎么知道不再需要调用工具了

### 1. 循环退出条件

Agentic 循环的退出由 [`needsFollowUp`](../../claude-code-source/src/query.ts#L558) 变量控制：

```typescript
// src/query.ts#L558
let needsFollowUp = false
```

- 每轮迭代开始时初始化为 `false`
- 当 LLM 响应中包含 `tool_use` 块时设为 `true`（[第 834 行](../../claude-code-source/src/query.ts#L834)）
- 当 LLM 响应中不包含任何 `tool_use` 块时保持 `false`

```typescript
// src/query.ts#L1062-L1357
if (!needsFollowUp) {
  // LLM 没有请求任何工具调用，对话完成
  return { reason: 'completed' }
}
```

### 2. 判断逻辑

LLM 不再需要调用工具的判断逻辑非常简洁：

1. LLM 生成响应时，如果认为已经完成任务，只输出 `text` 类型内容块，不生成 `tool_use` 块
2. 此时 `stop_reason` 为 `end_turn`（而非 `tool_use`）
3. [`query.ts#L832-L834`](../../claude-code-source/src/query.ts#L832-L834) 的过滤条件不会匹配到任何 `tool_use` 块
4. `needsFollowUp` 保持 `false`
5. 循环在 [第 1062 行](../../claude-code-source/src/query.ts#L1062) 检测到 `!needsFollowUp`，返回 `{ reason: 'completed' }`

### 3. 其他退出路径

除了正常完成外，还有以下退出路径：

| 退出原因 | 位置 | 说明 |
|---------|------|------|
| `aborted_streaming` | [第 1051 行](../../claude-code-source/src/query.ts#L1051) | 用户中断流式响应 |
| `prompt_too_long` | [第 1175 行](../../claude-code-source/src/query.ts#L1175) | 上下文过长且恢复失败 |
| `aborted_tools` | [第 1515 行](../../claude-code-source/src/query.ts#L1515) | 工具执行期间被中断 |
| `hook_stopped` | [第 1520 行](../../claude-code-source/src/query.ts#L1520) | Hook 阻止继续执行 |
| `max_turns` | [第 1711 行](../../claude-code-source/src/query.ts#L1711) | 达到最大轮次限制 |
| `stop_hook_prevented` | [第 1279 行](../../claude-code-source/src/query.ts#L1279) | Stop Hook 阻止继续 |

## 七、 完整示例："当前目录有哪些文件"的工具调用过程

### 1. 用户输入

用户输入："当前目录有哪些文件"

### 2. 第一轮：构建请求并发送给 LLM

Claude Code 构建如下 API 请求（简化版）：

```json
{
  "model": "claude-sonnet-4-20250514",
  "messages": [
    {
      "role": "user",
      "content": "当前目录有哪些文件"
    }
  ],
  "system": [
    {
      "type": "text",
      "text": "You are Claude Code, Anthropic's official CLI for Claude...",
      "cache_control": { "type": "ephemeral" }
    }
  ],
  "tools": [
    {
      "name": "Bash",
      "description": "Run a bash command...",
      "input_schema": {
        "type": "object",
        "properties": {
          "command": { "type": "string", "description": "The command to execute" },
          "timeout": { "type": "number", "description": "Optional timeout in milliseconds" },
          "description": { "type": "string", "description": "Clear, concise description of what this command does" }
        },
        "required": ["command"],
        "additionalProperties": false
      }
    },
    {
      "name": "Read",
      "description": "Read a file from the local filesystem...",
      "input_schema": { "..." : "..." }
    },
    {
      "name": "Edit",
      "description": "Edit a file...",
      "input_schema": { "..." : "..." }
    }
  ],
  "stream": true,
  "thinking": { "type": "adaptive" }
}
```

LLM 从 `tools` 数组中得知可用工具，决定调用 Bash 工具执行 `ls` 命令。

### 3. 第一轮：LLM 流式返回 tool_use 响应

SSE 事件序列：

```
event: message_start
data: {"type":"message_start","message":{"id":"msg_01XYZ","role":"assistant",...}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

event: content_block_delta (x N)
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"用户想查看当前目录的文件，我需要用 Bash 执行 ls 命令"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

event: content_block_delta (x N)
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"让我查看当前目录的文件"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: content_block_start
data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01ABC","name":"Bash","input":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"ls"}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":" -la\",\"description\":\"List files in current directory\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":2}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":120}}

event: message_stop
data: {"type":"message_stop"}
```

### 4. 第一轮：Claude Code 检测到 tool_use

[`query.ts#L829-L834`](../../claude-code-source/src/query.ts#L829-L834) 从流式响应中提取 `tool_use` 块：

```typescript
const msgToolUseBlocks = message.message.content.filter(
  content => content.type === 'tool_use',
) as ToolUseBlock[]
if (msgToolUseBlocks.length > 0) {
  toolUseBlocks.push(...msgToolUseBlocks)
  needsFollowUp = true
}
```

此时 `needsFollowUp = true`，循环继续。

### 5. 工具执行

[`runTools()`](../../claude-code-source/src/services/tools/toolOrchestration.ts#L19) 被调用，执行流程：

1. [`runToolUse()`](../../claude-code-source/src/services/tools/toolExecution.ts#L337) 接收 `tool_use` 块
2. [`findToolByName()`](../../claude-code-source/src/services/tools/toolExecution.ts#L345) 找到 BashTool
3. Zod 校验输入参数（[第 615 行](../../claude-code-source/src/services/tools/toolExecution.ts#L615)）
4. 权限检查：`canUseTool()` 检查是否允许执行（[第 921 行](../../claude-code-source/src/services/tools/toolExecution.ts#L921)）
5. [`tool.call()`](../../claude-code-source/src/services/tools/toolExecution.ts#L1207) 执行 `ls -la` 命令
6. [`mapToolResultToToolResultBlockParam()`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L555) 将结果转为 `tool_result` 格式

### 6. 工具结果封装

BashTool 的 [`mapToolResultToToolResultBlockParam()`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L555-L622) 生成：

```json
{
  "tool_use_id": "toolu_01ABC",
  "type": "tool_result",
  "content": "total 48\ndrwxr-xr-x  5 user user 4096 Jun 12 21:00 .\ndrwxr-xr-x  3 root root 4096 Jun 12 20:00 ..\n-rw-r--r--  1 user user  220 Jun 12 README.md\ndrwxr-xr-x  2 user user 4096 Jun 12 src\n-rw-r--r--  1 user user  500 Jun 12 package.json"
}
```

此结果被包装为 `user` 消息：

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01ABC",
      "content": "total 48\ndrwxr-xr-x  5 user user 4096 Jun 12 21:00 .\n..."
    }
  ]
}
```

### 7. 第二轮：组装消息并发送给 LLM

[`query.ts#L1715-L1716`](../../claude-code-source/src/query.ts#L1715-L1716) 组装下一轮消息：

```typescript
messages: [...messagesForQuery, ...assistantMessages, ...toolResults]
```

发送给 LLM 的请求消息序列为：

```json
{
  "messages": [
    {
      "role": "user",
      "content": "当前目录有哪些文件"
    },
    {
      "role": "assistant",
      "content": [
        { "type": "thinking", "thinking": "用户想查看当前目录的文件...", "signature": "ErUB..." },
        { "type": "text", "text": "让我查看当前目录的文件" },
        {
          "type": "tool_use",
          "id": "toolu_01ABC",
          "name": "Bash",
          "input": { "command": "ls -la", "description": "List files in current directory" }
        }
      ]
    },
    {
      "role": "user",
      "content": [
        {
          "type": "tool_result",
          "tool_use_id": "toolu_01ABC",
          "content": "total 48\ndrwxr-xr-x  5 user user 4096 Jun 12 21:00 .\n..."
        }
      ]
    }
  ]
}
```

### 8. 第二轮：LLM 返回最终文本响应

LLM 收到工具结果后，生成最终的文本回复，不再请求工具调用：

```
event: content_block_start (thinking)
event: content_block_delta (x N, thinking)
event: content_block_stop

event: content_block_start (text)
event: content_block_delta (x N)
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"当前目录包含以下文件和目录："}}
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\n\n- README.md\n- src/（目录）\n- package.json"}}
event: content_block_stop

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},...}
```

### 9. 循环退出

此轮响应中没有任何 `tool_use` 块，`needsFollowUp` 保持 `false`。循环在 [第 1062 行](../../claude-code-source/src/query.ts#L1062) 检测到后返回：

```typescript
if (!needsFollowUp) {
  return { reason: 'completed' }
}
```

### 10. 完整流程时序图

```
用户                    Claude Code                     LLM API
 │                         │                              │
 │  "当前目录有哪些文件"    │                              │
 │────────────────────────>│                              │
 │                         │  POST /v1/messages            │
 │                         │  { messages, tools, stream }  │
 │                         │─────────────────────────────>│
 │                         │                              │
 │                         │  SSE: thinking_delta (x N)    │
 │                         │<─────────────────────────────│
 │                         │  SSE: text_delta "让我查看"   │
 │                         │<─────────────────────────────│
 │                         │  SSE: tool_use { Bash, ls }   │
 │                         │<─────────────────────────────│
 │                         │  SSE: stop_reason: tool_use   │
 │                         │<─────────────────────────────│
 │                         │                              │
 │                         │  ─── 检测 tool_use ───        │
 │                         │  needsFollowUp = true         │
 │                         │                              │
 │                         │  ─── 执行 BashTool ───        │
 │                         │  tool.call({ command: "ls" }) │
 │                         │  → 获取 stdout/stderr         │
 │                         │  → mapToolResultToToolResult  │
 │                         │                              │
 │                         │  POST /v1/messages            │
 │                         │  { messages: [               │
 │                         │    user, assistant+tool_use,  │
 │                         │    user+tool_result           │
 │                         │  ] }                          │
 │                         │─────────────────────────────>│
 │                         │                              │
 │                         │  SSE: thinking_delta (x N)    │
 │                         │<─────────────────────────────│
 │                         │  SSE: text_delta "包含以下..." │
 │                         │<─────────────────────────────│
 │                         │  SSE: stop_reason: end_turn   │
 │                         │<─────────────────────────────│
 │                         │                              │
 │                         │  ─── 无 tool_use ───          │
 │                         │  needsFollowUp = false        │
 │                         │  return { completed }         │
 │                         │                              │
 │  "当前目录包含..."       │                              │
 │<────────────────────────│                              │
```

## 八、 关键设计总结

### 1. 工具发现机制

LLM 通过 API 请求的 `tools` 字段获取可用工具列表。每个工具的 `name`、`description`、`input_schema` 完整描述了工具的用途和参数格式，LLM 据此决定何时及如何调用工具。

### 2. 循环驱动的 Agentic 模式

Claude Code 的工具调用不是一次性的请求-响应，而是一个 `while(true)` 循环。每一轮循环：

1. 发送消息（含历史 + 新结果）给 LLM
2. LLM 决定是输出文本还是调用工具
3. 如果调用工具 → 执行 → 结果进入下一轮
4. 如果输出文本 → 循环结束

### 3. 工具结果回传约定

工具结果必须以 `role: "user"` 消息中的 `tool_result` 内容块回传，且 `tool_use_id` 必须与请求中的 `tool_use.id` 一一对应。这是 Anthropic API 的硬性要求。

### 4. 流式工具执行优化

Claude Code 实现了 [`StreamingToolExecutor`](../../claude-code-source/src/services/tools/StreamingToolExecutor.ts#L40)，在流式接收 LLM 响应的同时就开始执行工具，而非等待完整响应后再执行，显著减少了端到端延迟。

---
*本文档由 markdowncli 技能辅助生成*

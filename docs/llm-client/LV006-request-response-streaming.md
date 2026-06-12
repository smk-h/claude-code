<!-- more -->

## 一、 概述

Claude Code 通过 Anthropic SDK 的 Beta Messages API 与 LLM 进行通信，使用 SSE（Server-Sent Events）流式传输实现实时响应。本文将从源码层面详细分析请求 JSON 格式、响应 JSON 格式以及流式数据接收机制，并以用户输入"我叫苏木"为示例，展示完整的数据流转过程。

核心源码文件：

- [`src/services/api/claude.ts`](../../claude-code-source/src/services/api/claude.ts#L1017)：API 请求构建、流式解析主逻辑
- [`src/utils/messages.ts`](../../claude-code-source/src/utils/messages.ts#L460)：消息创建与规范化
- [`src/utils/api.ts`](../../claude-code-source/src/utils/api.ts#L119)：工具 Schema 格式化与系统提示组装
- [`src/services/api/client.ts`](../../claude-code-source/src/services/api/client.ts#L90)：SDK 客户端创建

## 二、 请求 JSON 格式

### 1. 请求构建流程

当用户输入一条消息后，Claude Code 经过以下步骤构建发送给 LLM 的请求：

1. 调用 [`createUserMessage()`](../../claude-code-source/src/utils/messages.ts#L460-L523) 将用户输入包装为内部 `UserMessage` 对象
2. 调用 [`normalizeMessagesForAPI()`](../../claude-code-source/src/utils/messages.ts#L1989) 将内部消息列表规范化为 API 格式
3. 调用 [`buildSystemPromptBlocks()`](../../claude-code-source/src/services/api/claude.ts#L3213-L3237) 构建系统提示词块
4. 调用 [`toolToAPISchema()`](../../claude-code-source/src/utils/api.ts#L119) 将工具定义转换为 API Schema
5. 通过 [`paramsFromContext()`](../../claude-code-source/src/services/api/claude.ts#L1538) 函数组装完整的请求参数
6. 调用 `anthropic.beta.messages.create({ ...params, stream: true })` 发送请求

### 2. 完整请求 JSON 结构

以下是请求 JSON 的完整结构（以 FirstParty Anthropic 直连为例）：

```json
{
  "model": "claude-sonnet-4-20250514",
  "messages": [
    {
      "role": "user",
      "content": "我叫苏木"
    }
  ],
  "system": [
    {
      "type": "text",
      "text": "<system_prompt_content>",
      "cache_control": { "type": "ephemeral" }
    }
  ],
  "tools": [
    {
      "name": "Bash",
      "description": "Run a bash command...",
      "input_schema": {
        "type": "object",
        "properties": { "command": { "type": "string" } },
        "required": ["command"]
      }
    }
  ],
  "tool_choice": { "type": "auto" },
  "betas": [
    "prompt-caching-2024-07-31",
    "interleaved-thinking-2025-05-14",
    "output-128k-2025-02-19"
  ],
  "metadata": { "user_id": "<user_id>" },
  "max_tokens": 16384,
  "thinking": {
    "type": "adaptive"
  },
  "stream": true
}
```

### 3. 请求各字段详解

#### 3.1 `model`

模型标识符，通过 [`normalizeModelStringForAPI()`](../../claude-code-source/src/services/api/claude.ts#L1700) 规范化后填入，如 `claude-sonnet-4-20250514`。

#### 3.2 `messages`

消息数组，角色严格交替 `user` → `assistant` → `user`。每条消息的 `content` 可以是纯字符串或内容块数组：

```json
// 纯文本用户消息
{
  "role": "user",
  "content": "我叫苏木"
}

// 包含工具调用结果的用户消息
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01ABC",
      "content": "file1.txt\nfile2.txt"
    }
  ]
}

// 包含工具调用的助手消息
{
  "role": "assistant",
  "content": [
    { "type": "text", "text": "我来查看目录内容" },
    {
      "type": "tool_use",
      "id": "toolu_01ABC",
      "name": "Bash",
      "input": { "command": "ls" }
    }
  ]
}
```

连续的 `user` 消息会被 [`normalizeMessagesForAPI()`](../../claude-code-source/src/utils/messages.ts#L2094-L2098) 合并，因为 Bedrock 不支持连续的 user 消息。

#### 3.3 `system`

系统提示词，由 [`buildSystemPromptBlocks()`](../../claude-code-source/src/services/api/claude.ts#L3213-L3237) 构建。采用 `TextBlockParam[]` 数组格式，支持 Prompt Caching：

```json
[
  {
    "type": "text",
    "text": "<attribution_header>\n<cli_prefix>\n<main_system_prompt>...",
    "cache_control": { "type": "ephemeral" }
  }
]
```

系统提示词按优先级组装（参见 [`claude.ts#L1358-L1369`](../../claude-code-source/src/services/api/claude.ts#L1358-L1369)）：

1. 归属头（Attribution Header）
2. CLI 前缀（如非交互模式标记）
3. 主系统提示词
4. Advisor 工具指令（如启用）
5. Chrome 工具搜索指令（如启用）

#### 3.4 `tools`

工具定义数组，由 [`toolToAPISchema()`](../../claude-code-source/src/utils/api.ts#L119) 生成。每个工具的 Schema 遵循 Anthropic 工具定义格式：

```json
{
  "name": "Bash",
  "description": "Run a bash command...",
  "input_schema": {
    "type": "object",
    "properties": {
      "command": { "type": "string", "description": "The command to run" }
    },
    "required": ["command"],
    "additionalProperties": false
  }
}
```

支持扩展属性：`strict`（严格模式）、`defer_loading`（延迟加载）、`cache_control`（缓存控制）、`eager_input_streaming`（即时输入流）。

#### 3.5 `betas`

Beta 功能标志数组，由 [`getMergedBetas()`](../../claude-code-source/src/utils/betas.ts#L397) 合并模型默认 betas 和动态添加的 betas。常见值包括：

- `prompt-caching-2024-07-31`：提示缓存
- `interleaved-thinking-2025-05-14`：交错思考
- `output-128k-2025-02-19`：128K 输出
- `token-efficient-tools-2025-02-19`：高效工具 Token

#### 3.6 `thinking`

思考模式配置，由 [`claude.ts#L1596-L1630`](../../claude-code-source/src/services/api/claude.ts#L1596-L1630) 决定：

- **自适应思考**（推荐）：`{ "type": "adaptive" }`
- **固定预算思考**：`{ "type": "enabled", "budget_tokens": 10000 }`
- **禁用**：不发送此字段

#### 3.7 其他字段

| 字段 | 说明 | 来源 |
|------|------|------|
| `max_tokens` | 最大输出 Token 数 | [`getMaxOutputTokensForModel()`](../../claude-code-source/src/services/api/claude.ts#L3399) |
| `metadata` | 请求元数据（含 `user_id`） | [`getAPIMetadata()`](../../claude-code-source/src/services/api/claude.ts#L503) |
| `temperature` | 温度参数（thinking 禁用时为 1） | `options.temperatureOverride` |
| `tool_choice` | 工具选择策略 | `options.toolChoice`，默认 `{ "type": "auto" }` |
| `output_config` | 输出配置（含 effort、task_budget） | 动态计算 |
| `context_management` | 上下文管理策略 | [`getAPIContextManagement()`](../../claude-code-source/src/services/compact/apiMicrocompact.ts#L64) |
| `speed` | 速度模式 | `"fast"` 或不发送 |

## 三、 SSE 协议与流式响应

### 1. SSE 协议简介

SSE（Server-Sent Events）是一种基于 HTTP 的单向实时通信协议，允许服务器通过长连接向客户端持续推送数据。Claude Code 使用 SSE 接收 LLM 的流式响应，而非等待完整的 JSON 一次性返回。

#### 1.1 SSE 与传统 HTTP 对比

传统 HTTP 请求-响应模式下，客户端必须等待服务器生成完整响应后才能收到数据：

```
传统 HTTP（非流式）
┌────────┐                                      ┌────────┐
│ Client │  POST /v1/messages                   │ Server │
│        │ ────────────────────────────────────> │        │
│        │                                      │  生成   │
│        │                                      │  完整   │
│        │                                      │  响应   │
│        │  <──── 200 OK (完整 JSON 一次性返回) ── │        │
│        │         ... 长时间等待 ...             │        │
└────────┘                                      └────────┘

  时间线: ──●──────────────────────────────────────●──>
            请求                                  响应
            ◄────────── 用户感知延迟 ──────────►
```

SSE 模式下，服务器在生成响应的过程中逐块推送数据，客户端可以实时处理：

```
SSE（流式）
┌────────┐                                      ┌────────┐
│ Client │  POST /v1/messages (stream: true)    │ Server │
│        │ ────────────────────────────────────> │        │
│        │  <──── 200 OK (chunked) ───────────── │  开始  │
│        │  <──── event: message_start ────────  │  生成   │
│        │  <──── event: content_block_start ── │  并    │
│        │  <──── event: content_block_delta ── │  逐块  │
│        │  <──── event: content_block_delta ── │  推送  │
│        │  <──── event: content_block_delta ── │        │
│        │  <──── event: content_block_stop ─── │        │
│        │  <──── event: message_delta ──────── │        │
│        │  <──── event: message_stop ───────── │        │
└────────┘                                      └────────┘

  时间线: ──●──●──●──●──●──●──●──●──●──>
            请求 首字  增量  增量  增量  结束
                 ↑
              用户几乎立即看到输出
```

#### 1.2 SSE 数据帧格式

SSE 协议采用纯文本格式，每个事件由字段组成，以空行分隔。Anthropic API 使用的核心字段为 `event` 和 `data`：

```
HTTP/1.1 200 OK
Content-Type: text/event-stream

event: message_start
data: {"type":"message_start","message":{"id":"msg_01X","role":"assistant",...}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking",...}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"用户"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"说"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},...}

event: message_stop
data: {"type":"message_stop"}

```

关键规则：

- 每个事件以 `event:` 行声明类型，`data:` 行携带 JSON 负载
- 事件之间用空行（`\n\n`）分隔
- 连接保持打开状态，直到服务器发送最后一个事件后关闭
- 客户端通过 `EventSource` 或原生 Fetch API 的流式读取消费数据

#### 1.3 Claude Code 中的 SSE 接入方式

Claude Code 通过 Anthropic SDK 发起流式请求，SDK 底层使用 Fetch API 读取 SSE 流：

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Claude Code 进程                              │
│                                                                      │
│  ┌─────────────┐    ┌──────────────────┐    ┌───────────────────┐    │
│  │ queryModel()│───>│ anthropic.beta   │───>│ Fetch API        │    │
│  │ (generator) │<───│ .messages.create │<───│ (stream reading) │    │
│  │             │    │ (stream: true)    │    │                  │    │
│  └─────────────┘    └──────────────────┘    └───────┬──────────┘    │
│         │                                           │ HTTP POST     │
│         │ yield                                     │ stream: true  │
│         ▼                                           ▼               │
│  ┌─────────────┐                          ┌──────────────────┐     │
│  │ QueryEngine │                          │ Anthropic API    │     │
│  │ (消费者)    │                          │ Server           │     │
│  └─────────────┘                          └──────────────────┘     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

数据流向:
  用户输入 → 构建请求 → HTTP POST (stream:true) → SSE 事件流 → 逐事件解析 → yield 给上层
```

### 2. API 调用方式

Claude Code 使用 Anthropic SDK 的 Beta Messages API 发起流式请求（参见 [`claude.ts#L1822-L1832`](../../claude-code-source/src/services/api/claude.ts#L1822-L1832)）：

```typescript
const result = await anthropic.beta.messages
  .create(
    { ...params, stream: true },
    { signal, headers: { 'x-client-request-id': clientRequestId } },
  )
  .withResponse()
```

关键参数：

- `stream: true`：告知 API 以 SSE 流式返回响应
- `.withResponse()`：同时获取原始 `Response` 对象（含响应头、`request_id` 等）
- `signal`：`AbortSignal`，用于取消请求

### 3. 事件类型与数据结构

Anthropic Beta Messages API 的流式事件按时间顺序分为以下几类：

#### 2.1 `message_start`

流开始的第一个事件，包含消息元信息：

```json
{
  "type": "message_start",
  "message": {
    "id": "msg_01XYZ",
    "type": "message",
    "role": "assistant",
    "content": [],
    "model": "claude-sonnet-4-20250514",
    "stop_reason": null,
    "stop_sequence": null,
    "usage": {
      "input_tokens": 5000,
      "output_tokens": 0,
      "cache_creation_input_tokens": 4500,
      "cache_read_input_tokens": 0
    }
  }
}
```

处理逻辑位于 [`claude.ts#L1980-L1993`](../../claude-code-source/src/services/api/claude.ts#L1980-L1993)：记录 `partialMessage`、计算 TTFB（Time To First Byte）、更新 `usage`。

#### 2.2 `content_block_start`

每个内容块开始时触发，指示内容块类型：

```json
// 思考块开始
{
  "type": "content_block_start",
  "index": 0,
  "content_block": {
    "type": "thinking",
    "thinking": ""
  }
}

// 文本块开始
{
  "type": "content_block_start",
  "index": 1,
  "content_block": {
    "type": "text",
    "text": ""
  }
}

// 工具调用块开始
{
  "type": "content_block_start",
  "index": 0,
  "content_block": {
    "type": "tool_use",
    "id": "toolu_01ABC",
    "name": "Bash",
    "input": ""
  }
}
```

处理逻辑位于 [`claude.ts#L1995-L2052`](../../claude-code-source/src/services/api/claude.ts#L1995-L2052)：在 `contentBlocks[index]` 初始化对应类型的内容块。

#### 2.3 `content_block_delta`

内容块的增量更新，这是流式输出文本的核心事件：

```json
// 思考增量
{
  "type": "content_block_delta",
  "index": 0,
  "delta": {
    "type": "thinking_delta",
    "thinking": "用户说"
  }
}

// 文本增量
{
  "type": "content_block_delta",
  "index": 1,
  "delta": {
    "type": "text_delta",
    "text": "你好"
  }
}

// 工具输入 JSON 增量
{
  "type": "content_block_delta",
  "index": 0,
  "delta": {
    "type": "input_json_delta",
    "partial_json": "{\"command\":\"ls"
  }
}

// 思考签名增量
{
  "type": "content_block_delta",
  "index": 0,
  "delta": {
    "type": "signature_delta",
    "signature": "ErUB..."
  }
}
```

处理逻辑位于 [`claude.ts#L2053-L2163`](../../claude-code-source/src/services/api/claude.ts#L2053-L2163)：

- `text_delta`：追加到 `contentBlock.text`
- `thinking_delta`：追加到 `contentBlock.thinking`
- `input_json_delta`：追加到 `contentBlock.input`（字符串拼接）
- `signature_delta`：更新 `contentBlock.signature`

#### 2.4 `content_block_stop`

内容块结束时触发：

```json
{
  "type": "content_block_stop",
  "index": 0
}
```

处理逻辑位于 [`claude.ts#L2171-L2211`](../../claude-code-source/src/services/api/claude.ts#L2171-L2211)：将累积的内容块规范化为 `AssistantMessage`，yield 给调用方。

#### 2.5 `message_delta`

消息级别更新，包含 `stop_reason` 和最终 `usage`：

```json
{
  "type": "message_delta",
  "delta": {
    "stop_reason": "end_turn",
    "stop_sequence": null
  },
  "usage": {
    "output_tokens": 150
  }
}
```

处理逻辑位于 [`claude.ts#L2213-L2293`](../../claude-code-source/src/services/api/claude.ts#L2213-L2293)：更新 `usage`、设置 `stopReason`、计算费用。

`stop_reason` 的可能值：

| 值 | 含义 |
|---|------|
| `end_turn` | 正常结束 |
| `tool_use` | 需要调用工具 |
| `max_tokens` | 达到最大 Token 限制 |
| `stop_sequence` | 遇到停止序列 |
| `model_context_window_exceeded` | 超出上下文窗口 |

#### 2.6 `message_stop`

流结束标志：

```json
{
  "type": "message_stop"
}
```

处理逻辑位于 [`claude.ts#L2295-L2296`](../../claude-code-source/src/services/api/claude.ts#L2295-L2296)：不做额外处理，仅作为流结束信号。

### 3. 最终聚合消息

所有流式事件接收完毕后，Claude Code 将其聚合为完整的 `BetaMessage` 对象，等价于非流式响应：

```json
{
  "id": "msg_01XYZ",
  "type": "message",
  "role": "assistant",
  "content": [
    {
      "type": "thinking",
      "thinking": "用户告诉我他的名字是苏木...",
      "signature": "ErUB..."
    },
    {
      "type": "text",
      "text": "你好，苏木！很高兴认识你。"
    }
  ],
  "model": "claude-sonnet-4-20250514",
  "stop_reason": "end_turn",
  "usage": {
    "input_tokens": 5000,
    "output_tokens": 150,
    "cache_creation_input_tokens": 4500,
    "cache_read_input_tokens": 0
  }
}
```

## 四、 流式数据接收机制

### 1. 核心架构

流式接收的核心是一个 `async generator` 函数 [`queryModel()`](../../claude-code-source/src/services/api/claude.ts#L1017)，调用方通过 `for await...of` 消费流式事件：

```typescript
// src/services/api/claude.ts#L1940
for await (const part of stream) {
  // 处理每个流式事件
  switch (part.type) {
    case 'message_start': ...
    case 'content_block_start': ...
    case 'content_block_delta': ...
    case 'content_block_stop': ...
    case 'message_delta': ...
    case 'message_stop': ...
  }

  // 将原始事件包装后 yield 给上层
  yield {
    type: 'stream_event',
    event: part,
    ...(part.type === 'message_start' ? { ttftMs } : undefined),
  }
}
```

### 2. 状态累积策略

Claude Code 不使用 SDK 自带的 `BetaMessageStream`（因为其 O(n²) 的 JSON 解析开销，参见 [`claude.ts#L1818-L1820`](../../claude-code-source/src/services/api/claude.ts#L1818-L1820)），而是自行维护状态累积：

```typescript
// src/services/api/claude.ts#L1764-L1774
const contentBlocks: (BetaContentBlock | ConnectorTextBlock)[] = []
let usage: NonNullableUsage = EMPTY_USAGE
let stopReason: BetaStopReason | null = null
let partialMessage: BetaMessage | undefined = undefined
```

- `partialMessage`：在 `message_start` 时设置，包含消息 ID、模型等元信息
- `contentBlocks[]`：按 `index` 索引的内容块数组，每个 `content_block_start` 时初始化，`content_block_delta` 时追加内容
- `usage`：累积 Token 使用量，由 `updateUsage()` 合并增量
- `stopReason`：在 `message_delta` 时设置

### 3. 工具输入的流式解析

工具调用输入以 JSON 字符串增量到达。Claude Code 采用字符串拼接 + 延迟解析的策略：

```typescript
// src/services/api/claude.ts#L2111
// 每次收到 input_json_delta，直接拼接字符串
contentBlock.input += delta.partial_json

// src/utils/messages.ts#L2676-L2694
// 在 content_block_stop 后，统一解析完整的 JSON 字符串
const parsed = safeParseJSON(contentBlock.input)
normalizedInput = parsed ?? {}
```

这种方式避免了在流式过程中反复解析 JSON 的开销。

### 4. 流式超时保护

Claude Code 实现了流式空闲超时看门狗（参见 [`claude.ts#L1874-L1928`](../../claude-code-source/src/services/api/claude.ts#L1874-L1928)），防止静默断连导致无限等待：

- 默认超时：90 秒（可通过 `CLAUDE_STREAM_IDLE_TIMEOUT_MS` 环境变量配置）
- 超过 45 秒无数据时输出警告日志
- 超过 90 秒无数据时主动释放流资源并回退到非流式重试

### 5. 重试机制

流式请求通过 [`withRetry()`](../../claude-code-source/src/services/api/withRetry.ts#L168) 包装，支持：

- 自动重试（529 过载、408 超时、网络错误）
- 模型降级（如 Sonnet 不可用时降级到 Haiku）
- 认证刷新（OAuth Token 过期时重新获取）

### 6. 事件流转总览

以下展示了从 SSE 网络帧到内部状态累积再到上层消费的完整数据流：

```
                        SSE 网络帧（HTTP chunked response）
                        ─────────────────────────────────
                        event: message_start
                        data: {"type":"message_start",...}

                        event: content_block_start
                        data: {"type":"content_block_start",...}

                        event: content_block_delta           ← 可能连续多个
                        data: {"type":"content_block_delta",...}

                        event: content_block_stop
                        data: {"type":"content_block_stop",...}

                        event: message_delta
                        data: {"type":"message_delta",...}

                        event: message_stop
                        data: {"type":"message_stop"}
                        ─────────────────────────────────
                                    │
                                    ▼ SDK 解析 SSE 帧，生成 BetaRawMessageStreamEvent 对象
                                    │
┌───────────┬───────────────────────┼───────────────────────────────────────────────────────┐
│ SSE 事件   │ claude.ts 状态处理    │ 内部状态变化                                            │ 上层 yield
├───────────┼───────────────────────┼───────────────────────────────────────────────────────┤─────────────────┐
│           │                       │                                                       │                 │
│ message_  │ partialMessage =      │ contentBlocks = []                                    │                 │
│ start     │   part.message        │ usage = { input:5000, output:0 }                      │                 │
│           │ ttftMs = now-start    │                                                       │                 │
│           │                       │                                                       │                 │
│ content_  │ contentBlocks[0] =    │ ┌──────────────────────┐                              │                 │
│ block_    │   { type:"thinking",  │ │ index:0  thinking:"" │  ← 初始化空块                │                 │
│ start     │     thinking:"" }    │ └──────────────────────┘                              │                 │
│           │                       │                                                       │                 │
│ content_  │ contentBlocks[0]      │ ┌──────────────────────┐                              │                 │
│ block_    │   .thinking += "用户" │ │ index:0  thinking:"用"│  ← 逐字追加                 │                 │
│ delta     │                       │ └──────────────────────┘                              │                 │
│           │                       │                                                       │                 │
│ content_  │ contentBlocks[0]      │ ┌──────────────────────┐                              │                 │
│ block_    │   .thinking += "说"   │ │ index:0  thinking:"用户说"│                          │                 │
│ delta     │                       │ └──────────────────────┘                              │                 │
│           │                       │                                                       │                 │
│ content_  │ contentBlocks[1] =    │ ┌──────────────────────┐                              │                 │
│ block_    │   { type:"text",      │ │ index:1  text:""     │  ← 新文本块                 │                 │
│ start     │     text:"" }         │ └──────────────────────┘                              │                 │
│           │                       │                                                       │                 │
│ content_  │ contentBlocks[1]      │ ┌──────────────────────┐                              │                 │
│ block_    │   .text += "你好"     │ │ index:1  text:"你好"  │  ← 逐字追加                 │                 │
│ delta     │                       │ └──────────────────────┘                              │                 │
│           │                       │                                                       │                 │
│ content_  │ normalizeContentFrom  │ contentBlock → AssistantMessage                       │ yield           │
│ block_    │   API(contentBlock)   │ (含规范化后的工具输入等)                                │ AssistantMessage│
│ stop      │ yield AssistantMessage│                                                       │ ─────────────>  │
│           │                       │                                                       │                 │
│ message_  │ usage += part.usage  │ usage = { input:5000, output:150 }                    │ yield           │
│ delta     │ stopReason = "end_    │ stopReason = "end_turn"                               │ stream_event   │
│           │   turn"               │ costUSD = calculateCost(...)                           │ ─────────────>  │
│           │                       │                                                       │                 │
│ message_  │                       │ 流结束                                                 │                 │
│ stop      │                       │                                                       │                 │
└───────────┴───────────────────────┴───────────────────────────────────────────────────────┴─────────────────┘
```

**关键要点**：

- SSE 事件是**单向的**（Server → Client），客户端无法在流中途发送数据
- `content_block_delta` 可能连续到达多次，每次携带少量增量文本
- Claude Code 在 `content_block_stop` 时才 yield 完整的内容块，而非每个 delta 都 yield
- `message_delta` 携带最终的 `stop_reason` 和 `usage`，是整个流的倒数第二个事件

## 五、 示例："我叫苏木"的完整数据流

### 1. 用户输入包装

用户输入"我叫苏木"后，[`createUserMessage()`](../../claude-code-source/src/utils/messages.ts#L460-L523) 生成内部消息对象：

```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": "我叫苏木"
  },
  "uuid": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "timestamp": "2026-06-12T13:09:00.000Z"
}
```

### 2. 发送给 LLM 的请求

经过 `normalizeMessagesForAPI()` 规范化后，通过 `paramsFromContext()` 组装的完整请求（简化版）：

```json
{
  "model": "claude-sonnet-4-20250514",
  "messages": [
    {
      "role": "user",
      "content": "我叫苏木"
    }
  ],
  "system": [
    {
      "type": "text",
      "text": "You are Claude Code, Anthropic's official CLI for Claude...\n<system_context>...</system_context>\n<environment_details>...</environment_details>",
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
          "command": { "type": "string", "description": "The bash command to run" },
          "timeout": { "type": "number", "description": "Optional timeout in ms" }
        },
        "required": ["command"],
        "additionalProperties": false
      }
    },
    {
      "name": "Read",
      "description": "Read a file from the local filesystem...",
      "input_schema": { "..." : "..." }
    }
  ],
  "tool_choice": { "type": "auto" },
  "betas": [
    "prompt-caching-2024-07-31",
    "interleaved-thinking-2025-05-14",
    "output-128k-2025-02-19"
  ],
  "metadata": { "user_id": "user_abc123" },
  "max_tokens": 16384,
  "thinking": { "type": "adaptive" },
  "stream": true
}
```

### 3. 从 LLM 接收的流式事件序列

以下是"我叫苏木"这条消息可能触发的完整流式事件序列：

**事件 1：`message_start`**

```json
{
  "type": "message_start",
  "message": {
    "id": "msg_01XK2M3N",
    "type": "message",
    "role": "assistant",
    "content": [],
    "model": "claude-sonnet-4-20250514",
    "stop_reason": null,
    "stop_sequence": null,
    "usage": {
      "input_tokens": 5230,
      "output_tokens": 0,
      "cache_creation_input_tokens": 4800,
      "cache_read_input_tokens": 0
    }
  }
}
```

**事件 2：`content_block_start`（思考块）**

```json
{
  "type": "content_block_start",
  "index": 0,
  "content_block": {
    "type": "thinking",
    "thinking": ""
  }
}
```

**事件 3-N：`content_block_delta`（思考增量）**

```json
{ "type": "content_block_delta", "index": 0, "delta": { "type": "thinking_delta", "thinking": "用户" } }
{ "type": "content_block_delta", "index": 0, "delta": { "type": "thinking_delta", "thinking": "告诉我" } }
{ "type": "content_block_delta", "index": 0, "delta": { "type": "thinking_delta", "thinking": "他叫苏木" } }
{ "type": "content_block_delta", "index": 0, "delta": { "type": "thinking_delta", "thinking": "，这是一个简单的自我介绍" } }
```

**事件 N+1：`content_block_delta`（签名增量）**

```json
{ "type": "content_block_delta", "index": 0, "delta": { "type": "signature_delta", "signature": "ErUB4kV..." } }
```

**事件 N+2：`content_block_stop`（思考块结束）**

```json
{ "type": "content_block_stop", "index": 0 }
```

**事件 N+3：`content_block_start`（文本块）**

```json
{
  "type": "content_block_start",
  "index": 1,
  "content_block": {
    "type": "text",
    "text": ""
  }
}
```

**事件 N+4-M：`content_block_delta`（文本增量）**

```json
{ "type": "content_block_delta", "index": 1, "delta": { "type": "text_delta", "text": "你好" } }
{ "type": "content_block_delta", "index": 1, "delta": { "type": "text_delta", "text": "，苏木" } }
{ "type": "content_block_delta", "index": 1, "delta": { "type": "text_delta", "text": "！很高兴认识你" } }
{ "type": "content_block_delta", "index": 1, "delta": { "type": "text_delta", "text": "。有什么我可以帮助你的吗？" } }
```

**事件 M+1：`content_block_stop`（文本块结束）**

```json
{ "type": "content_block_stop", "index": 1 }
```

**事件 M+2：`message_delta`**

```json
{
  "type": "message_delta",
  "delta": {
    "stop_reason": "end_turn",
    "stop_sequence": null
  },
  "usage": {
    "output_tokens": 85
  }
}
```

**事件 M+3：`message_stop`**

```json
{
  "type": "message_stop"
}
```

### 4. 聚合后的完整响应

```json
{
  "id": "msg_01XK2M3N",
  "type": "message",
  "role": "assistant",
  "content": [
    {
      "type": "thinking",
      "thinking": "用户告诉我他叫苏木，这是一个简单的自我介绍",
      "signature": "ErUB4kV..."
    },
    {
      "type": "text",
      "text": "你好，苏木！很高兴认识你。有什么我可以帮助你的吗？"
    }
  ],
  "model": "claude-sonnet-4-20250514",
  "stop_reason": "end_turn",
  "stop_sequence": null,
  "usage": {
    "input_tokens": 5230,
    "output_tokens": 85,
    "cache_creation_input_tokens": 4800,
    "cache_read_input_tokens": 0
  }
}
```

## 六、 请求头与认证

### 1. 通用请求头

每个 API 请求都会注入以下自定义头（参见 [`client.ts#L107-L118`](../../claude-code-source/src/services/api/client.ts#L107-L118)）：

```
x-app: cli
User-Agent: <user-agent-string>
X-Claude-Code-Session-Id: <session-uuid>
x-client-request-id: <per-request-uuid>        // 仅 FirstParty
Authorization: Bearer <token>                    // 如使用 auth token
```

### 2. 流式响应头

响应包含以下有用的头信息（通过 `.withResponse()` 获取）：

- `request-id`：服务端请求 ID，用于追踪和重试
- `anthropic-ratelimit-*`：速率限制信息

## 七、 与 OpenAI 格式的对比

Claude Code 还支持通过 OpenAI 兼容适配器（[`openai-adapter.ts`](../../claude-code-source/src/services/api/openai-adapter.ts#L846)）与非 Anthropic API 通信。两种格式的主要差异：

| 维度 | Anthropic 格式 | OpenAI 格式 |
|------|---------------|-------------|
| 消息角色 | `user` / `assistant` | `user` / `assistant` / `system` |
| 系统提示 | `system` 顶层字段 | `messages[0].role = 'system'` |
| 工具调用 | `tool_use` 内容块 | `tool_calls` 字段 |
| 工具结果 | `tool_result` 内容块 | `tool` 角色消息 |
| 流式事件 | `message_start` / `content_block_delta` / `message_stop` | `choices[0].delta.content` |
| 结束标记 | `message_delta`（`stop_reason`） | `choices[0].finish_reason` |
| 流结束 | `message_stop` | `data: [DONE]` |

## 八、 关键设计决策

### 1. 为什么不用 SDK 自带的 `BetaMessageStream`

[`claude.ts#L1818-L1820`](../../claude-code-source/src/services/api/claude.ts#L1818-L1820) 明确说明了原因：SDK 的 `BetaMessageStream` 在每个 `input_json_delta` 上调用 `partialParse()`，造成 O(n²) 的解析开销。Claude Code 自己维护字符串拼接，只在 `content_block_stop` 时解析一次。

### 2. 为什么用 Raw Stream

使用 `anthropic.beta.messages.create({ stream: true }).withResponse()` 获取原始 `Stream<BetaRawMessageStreamEvent>`，而非封装后的 `BetaMessageStream`，可以直接控制事件处理流程。

### 3. 内容块的不可变性

[`claude.ts#L2040-L2043`](../../claude-code-source/src/services/api/claude.ts#L2040-L2043) 提到 SDK 会就地修改 text block 的内容，因此采用展开运算符 `{ ...part.content_block }` 创建副本，确保状态累积的可预测性。

---
*本文档由 markdowncli 技能辅助生成*

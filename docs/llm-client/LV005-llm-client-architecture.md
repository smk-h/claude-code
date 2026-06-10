<!-- more -->

## 一、 概述

Claude Code 在 LLM 客户端架构上采用了一套灵活的多提供商设计，统一使用 Anthropic SDK 类型作为上层接口，通过环境变量切换不同的后端提供商（Anthropic 直连、AWS Bedrock、Azure Foundry、Google Vertex、OpenAI 兼容、CNB 平台），并在此之上实现了 Extended Thinking（扩展思考）机制的完整配置链路。本文将深入源码分析其 API Key / URL 配置、客户端创建、Anthropic 与 OpenAI 兼容方案，以及 Thinking 模式的配置与实现。

## 二、 API 提供商与认证配置

### 1. 提供商类型与激活方式

系统支持 6 种提供商模式，通过环境变量激活，定义在 [`src/utils/model/providers.ts`](../../claude-code-source/src/utils/model/providers.ts#L4-L29) 中：

```typescript
// ../../claude-code-source/src/utils/model/providers.ts#L4-L29
export type APIProvider = 'firstParty' | 'bedrock' | 'vertex' | 'foundry' | 'openai' | 'cnb'

export function getAPIProvider(): APIProvider {
  return isEnvTruthy(process.env.CLAUDE_CODE_USE_CNB)
    ? 'cnb'
    : isEnvTruthy(process.env.CLAUDE_CODE_USE_OPENAI)
      ? 'openai'
      : isEnvTruthy(process.env.CLAUDE_CODE_USE_BEDROCK)
        ? 'bedrock'
        : isEnvTruthy(process.env.CLAUDE_CODE_USE_VERTEX)
          ? 'vertex'
          : isEnvTruthy(process.env.CLAUDE_CODE_USE_FOUNDRY)
            ? 'foundry'
            : 'firstParty'
}
```

优先级从高到低依次为：CNB → OpenAI → Bedrock → Vertex → Foundry → FirstParty（默认）。

#### 1.1 各提供商的认证与 URL 配置

| 提供商 | 激活环境变量 | 认证方式 | Base URL 配置 |
|---|---|---|---|
| **FirstParty（Anthropic 直连）** | 默认 | `ANTHROPIC_API_KEY` / OAuth | `ANTHROPIC_BASE_URL` |
| **AWS Bedrock** | `CLAUDE_CODE_USE_BEDROCK=1` | AWS 凭证链 / `AWS_BEARER_TOKEN_BEDROCK` | `ANTHROPIC_BEDROCK_BASE_URL` |
| **Azure Foundry** | `CLAUDE_CODE_USE_FOUNDRY=1` | `ANTHROPIC_FOUNDRY_API_KEY` / Azure AD | `ANTHROPIC_FOUNDRY_BASE_URL` / `ANTHROPIC_FOUNDRY_RESOURCE` |
| **Google Vertex** | `CLAUDE_CODE_USE_VERTEX=1` | GCP 凭证链 + `ANTHROPIC_VERTEX_PROJECT_ID` | 通过区域变量指定 |
| **OpenAI 兼容** | `CLAUDE_CODE_USE_OPENAI=1` | `OPENAI_API_KEY` | `OPENAI_BASE_URL`（默认 `http://localhost:8000/v1`） |
| **CNB 平台** | `CLAUDE_CODE_USE_CNB=1` | `CNB_TOKEN` | 从 `CNB_API_ENDPOINT` + `CNB_REPO_SLUG` 派生 |

### 2. API Key 解析优先级

API Key 的解析逻辑位于 [`src/utils/auth.ts`](../../claude-code-source/src/utils/auth.ts#L227) 的 `getAnthropicApiKeyWithSource()` 函数中，按以下优先级依次尝试：

1. **`--bare` 模式**：仅接受 `ANTHROPIC_API_KEY` 环境变量或 `--settings` 传入的 `apiKeyHelper`
2. **[`preferThirdPartyAuthentication()`](../../claude-code-source/src/bootstrap/state.ts#L1234)**（CI/print 模式）：优先使用 `ANTHROPIC_API_KEY` 环境变量
3. **CI/Test 模式**：文件描述符 Key → `ANTHROPIC_API_KEY` 环境变量
4. **已审批的 `ANTHROPIC_API_KEY`**：通过 `customApiKeyResponses.approved` 校验
5. **文件描述符 API Key**（`CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR`）
6. **`apiKeyHelper`**：从 `~/.claude/settings.json` 配置的 Shell 命令获取 Key
7. **`/login` 管理的 Key**：macOS Keychain 或 `~/.claude.json` 中的 `primaryApiKey`

```typescript
// ../../claude-code-source/src/utils/auth.ts#L227
export function getAnthropicApiKeyWithSource(
  opts: { skipRetrievingKeyFromApiKeyHelper?: boolean } = {},
): {
  key: null | string
  source: ApiKeySource
} {
  if (isBareMode()) {
    if (process.env.ANTHROPIC_API_KEY) {
      return { key: process.env.ANTHROPIC_API_KEY, source: 'ANTHROPIC_API_KEY' }
    }
    if (getConfiguredApiKeyHelper()) {
      return { key: getApiKeyFromApiKeyHelperCached(), source: 'apiKeyHelper' }
    }
    return { key: null, source: 'none' }
  }
  // ... 后续优先级链
}
```

### 3. OAuth Token 解析

[`getClaudeAIOAuthTokens()`](../../claude-code-source/src/utils/auth.ts#L1256) 函数解析 OAuth Token 的优先级如下：

1. `CLAUDE_CODE_OAUTH_TOKEN` 环境变量 → 推理专用 Token（无刷新能力）
2. 文件描述符 OAuth Token → 推理专用 Token
3. 安全存储（Keychain / 凭证文件） → 完整 Token（含刷新）

### 4. Settings 中的认证辅助配置

`~/.claude/settings.json` 支持以下认证相关配置项：

- `apiKeyHelper`：Shell 命令，输出 API Key（支持 SWR 缓存，TTL 默认 5 分钟）
- `awsAuthRefresh`：Shell 命令，交互式 AWS 认证（如 `aws sso login`）
- `awsCredentialExport`：Shell 命令，输出 AWS STS 凭证 JSON
- `gcpAuthRefresh`：Shell 命令，GCP 认证刷新

### 5. 其他认证相关环境变量

| 环境变量 | 说明 |
|---|---|
| `ANTHROPIC_AUTH_TOKEN` | Bearer Token（注入 `Authorization` 头，非 `x-api-key`） |
| `ANTHROPIC_CUSTOM_HEADERS` | 自定义 HTTP 头（curl 格式，换行分隔） |
| `CLAUDE_CODE_OAUTH_TOKEN` | OAuth Token（推理专用） |
| `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` | 文件描述符方式的 OAuth Token |
| `CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR` | 文件描述符方式的 API Key |
| `CLAUDE_CODE_SKIP_BEDROCK_AUTH` | 跳过 Bedrock 认证（代理场景） |
| `CLAUDE_CODE_SKIP_VERTEX_AUTH` | 跳过 Vertex 认证 |
| `CLAUDE_CODE_SKIP_FOUNDRY_AUTH` | 跳过 Foundry 认证 |
| `ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION` | Haiku 模型专用 AWS 区域覆盖 |
| `API_TIMEOUT_MS` | API 超时时间（默认 600 秒） |
| `ANTHROPIC_BETAS` | 附加 Beta 头（逗号分隔） |

## 三、 LLM 客户端创建

### 1. 核心函数 getAnthropicClient()

客户端创建的核心函数位于 [`src/services/api/client.ts`](../../claude-code-source/src/services/api/client.ts#L90)，所有提供商最终都返回 `Anthropic` 类型（或兼容类型）：

```typescript
// ../../claude-code-source/src/services/api/client.ts#L90
export async function getAnthropicClient({
  apiKey,
  maxRetries,
  model,
  fetchOverride,
  source,
}: {
  apiKey?: string
  maxRetries: number
  model?: string
  fetchOverride?: ClientOptions['fetch']
  source?: string
}): Promise<Anthropic> {
  // 构建通用配置
  const defaultHeaders = { 'x-app': 'cli', 'User-Agent': getUserAgent(), ... }
  const ARGS = {
    defaultHeaders,
    maxRetries,
    timeout: parseInt(process.env.API_TIMEOUT_MS || String(600 * 1000), 10),
    dangerouslyAllowBrowser: true,
    fetchOptions: getProxyFetchOptions({ forAnthropicAPI: true }),
  }

  // 按提供商分支创建客户端
  if (isEnvTruthy(process.env.CLAUDE_CODE_USE_BEDROCK)) { /* ... */ }
  if (isEnvTruthy(process.env.CLAUDE_CODE_USE_FOUNDRY)) { /* ... */ }
  if (isEnvTruthy(process.env.CLAUDE_CODE_USE_VERTEX)) { /* ... */ }
  if (isEnvTruthy(process.env.CLAUDE_CODE_USE_CNB)) { /* ... */ }
  if (isEnvTruthy(process.env.CLAUDE_CODE_USE_OPENAI)) { /* ... */ }

  // 默认 FirstParty
  return new Anthropic(clientConfig)
}
```

### 2. 各提供商客户端创建细节

#### 2.1 AWS Bedrock

```typescript
// ../../claude-code-source/src/services/api/client.ts#L155
if (isEnvTruthy(process.env.CLAUDE_CODE_USE_BEDROCK)) {
  const { AnthropicBedrock } = await import('@anthropic-ai/bedrock-sdk')
  const awsRegion = model === getSmallFastModel()
    && process.env.ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION
      ? process.env.ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION
      : getAWSRegion()

  const bedrockArgs = { ...ARGS, awsRegion, ... }

  // Bearer Token 认证
  if (process.env.AWS_BEARER_TOKEN_BEDROCK) {
    bedrockArgs.skipAuth = true
    bedrockArgs.defaultHeaders = {
      ...bedrockArgs.defaultHeaders,
      Authorization: `Bearer ${process.env.AWS_BEARER_TOKEN_BEDROCK}`,
    }
  } else if (!isEnvTruthy(process.env.CLAUDE_CODE_SKIP_BEDROCK_AUTH)) {
    // 标准 AWS 凭证链
    const cachedCredentials = await refreshAndGetAwsCredentials()
    bedrockArgs.awsAccessKey = cachedCredentials.accessKeyId
    bedrockArgs.awsSecretKey = cachedCredentials.secretAccessKey
    bedrockArgs.awsSessionToken = cachedCredentials.sessionToken
  }

  return new AnthropicBedrock(bedrockArgs) as unknown as Anthropic
}
```

#### 2.2 Azure Foundry

```typescript
// ../../claude-code-source/src/services/api/client.ts#L208
if (isEnvTruthy(process.env.CLAUDE_CODE_USE_FOUNDRY)) {
  const { AnthropicFoundry } = await import('@anthropic-ai/foundry-sdk')

  // 优先使用 API Key，否则走 Azure AD 认证
  let azureADTokenProvider: (() => Promise<string>) | undefined
  if (!process.env.ANTHROPIC_FOUNDRY_API_KEY) {
    if (isEnvTruthy(process.env.CLAUDE_CODE_SKIP_FOUNDRY_AUTH)) {
      azureADTokenProvider = () => Promise.resolve('') // 测试/代理场景
    } else {
      const { DefaultAzureCredential, getBearerTokenProvider } =
        await import('@azure/identity')
      azureADTokenProvider = getBearerTokenProvider(
        new AzureCredential(),
        'https://cognitiveservices.azure.com/.default',
      )
    }
  }

  return new AnthropicFoundry({ ...ARGS, azureADTokenProvider }) as unknown as Anthropic
}
```

#### 2.3 Google Vertex

```typescript
// ../../claude-code-source/src/services/api/client.ts#L223
if (isEnvTruthy(process.env.CLAUDE_CODE_USE_VERTEX)) {
  const [{ AnthropicVertex }, { GoogleAuth }] = await Promise.all([
    import('@anthropic-ai/vertex-sdk'),
    import('google-auth-library'),
  ])

  const googleAuth = isEnvTruthy(process.env.CLAUDE_CODE_SKIP_VERTEX_AUTH)
    ? { getClient: () => ({ getRequestHeaders: () => ({}) }) } // Mock
    : new GoogleAuth({
        scopes: ['https://www.googleapis.com/auth/cloud-platform'],
        projectId: hasProjectEnvVar || hasKeyFile
          ? undefined
          : process.env.ANTHROPIC_VERTEX_PROJECT_ID,
      })

  return new AnthropicVertex({
    ...ARGS,
    region: getVertexRegionForModel(model),
    googleAuth,
  }) as unknown as Anthropic
}
```

Vertex 区域解析优先级：
1. 模型专用环境变量（如 `VERTEX_REGION_CLAUDE_3_5_SONNET`）
2. `CLOUD_ML_REGION` 全局变量
3. 默认配置区域
4. 回退到 `us-east5`

#### 2.4 FirstParty（Anthropic 直连）

```typescript
// ../../claude-code-source/src/services/api/client.ts#L359
const clientConfig = {
  apiKey: isClaudeAISubscriber() ? null : apiKey || getAnthropicApiKey(),
  authToken: isClaudeAISubscriber()
    ? getClaudeAIOAuthTokens()?.accessToken
    : undefined,
  ...ARGS,
}

return new Anthropic(clientConfig)
```

【**注意**】FirstParty 模式下，Claude.ai 订阅用户使用 OAuth Token（`authToken`），非订阅用户使用 API Key（`apiKey`）。

## 四、 Anthropic 与 OpenAI 兼容方案

### 1. 设计思路

Claude Code 的 OpenAI 兼容方案采用 **Fetch 级别的协议适配**，而非在 SDK 层面创建两套客户端。核心思路是：

1. 仍然创建 `Anthropic` SDK 客户端实例
2. 注入一个自定义 `fetch` 函数（适配器），在 HTTP 请求发出前将 Anthropic 格式转换为 OpenAI 格式
3. 收到响应后，将 OpenAI 格式转换回 Anthropic 格式

这使得整个上层代码（消息构建、流处理、工具调用等）无需任何修改。

### 2. OpenAI 适配器实现

适配器核心代码位于 [`src/services/api/openai-adapter.ts`](../../claude-code-source/src/services/api/openai-adapter.ts#L846)：

#### 2.1 客户端创建

```typescript
// ../../claude-code-source/src/services/api/client.ts#L339
if (isEnvTruthy(process.env.CLAUDE_CODE_USE_OPENAI)) {
  const openaiBaseUrl = (
    process.env.OPENAI_BASE_URL || 'http://localhost:8000/v1'
  ).replace(/\/$/, '')

  const adapterFetch = createOpenAIAdapterFetch(resolvedFetch || undefined)
  const openaiConfig = {
    apiKey: 'openai-compat-dummy-key', // SDK 要求非空 Key，实际使用 OPENAI_API_KEY
    baseURL: openaiBaseUrl,
    ...ARGS,
    fetch: adapterFetch,
  }
  return new Anthropic(openaiConfig)
}
```

【**注意**】客户端创建时使用占位 API Key `'openai-compat-dummy-key'`，因为 Anthropic SDK 要求非空 Key。实际的 OpenAI API Key 在适配器 fetch 函数中从 `OPENAI_API_KEY` 环境变量读取。

#### 2.2 请求转换（Anthropic → OpenAI）

适配器的 [`createOpenAIAdapterFetch()`](../../claude-code-source/src/services/api/openai-adapter.ts#L846) 函数拦截发往 `/messages` 端点的请求，执行以下转换：

- **URL 映射**：`/v1/messages` → `{OPENAI_BASE_URL}/chat/completions`
- **System Prompt**：从 `body.system` 提取，转为 `messages[0].role = 'system'`
- **Tool Use → Tool Calls**：`tool_use` 块 → `tool_calls` 数组，`input` → `function.arguments`
- **Tool Result**：`tool_result` 块 → `role: 'tool'` 消息
- **Image**：`source.base64` → `data:image/...;base64,...` URL 格式
- **认证**：使用 `Authorization: Bearer ${OPENAI_API_KEY}` 头

```typescript
// ../../claude-code-source/src/services/api/openai-adapter.ts#L520
function convertAnthropicRequestToOpenAI(body: any): any {
  let messages = convertAnthropicMessagesToOpenAI(body.messages, body.system)
  return {
    model: process.env.OPENAI_MODEL || body.model || 'gpt-4o',
    messages,
    stream: body.stream ?? false,
    max_completion_tokens: body.max_tokens || 4096,
    // temperature, tools, tool_choice ...
  }
}
```

#### 2.3 流式响应转换（OpenAI → Anthropic）

适配器通过 `TransformStream` 将 OpenAI 的 SSE 格式实时转换为 Anthropic 的 SSE 格式：

| OpenAI 事件 | Anthropic 事件 |
|---|---|
| `choices[0].delta.content` | `content_block_delta` (`text_delta`) |
| `choices[0].delta.tool_calls` | `content_block_start` (`tool_use`) + `content_block_delta` (`input_json_delta`) |
| `choices[0].finish_reason = 'stop'` | `message_delta` (`stop_reason: 'end_turn'`) |
| `choices[0].finish_reason = 'tool_calls'` | `message_delta` (`stop_reason: 'tool_use'`) |
| `data: [DONE]` | `message_stop` |

#### 2.4 非流式响应转换

对于非流式请求，适配器直接将 OpenAI 的 JSON 响应转换为 Anthropic 格式：

```typescript
// ../../claude-code-source/src/services/api/openai-adapter.ts#L998
function convertOpenAINonStreamingToAnthropic(openAIResponse: any, model: string): any {
  return {
    id: openAIResponse.id || generateId(),
    type: 'message',
    role: 'assistant',
    content, // 文本 + tool_use
    model: openAIResponse.model || model,
    stop_reason: stopReason, // stop→end_turn, tool_calls→tool_use, length→max_tokens
    usage: { input_tokens, output_tokens, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
  }
}
```

### 3. CNB 平台兼容

CNB 模式复用 OpenAI 适配器，但额外做了身份清洗以绕过上游模型的安全过滤：

```typescript
// ../../claude-code-source/src/services/api/client.ts#L306
if (isEnvTruthy(process.env.CLAUDE_CODE_USE_CNB)) {
  const cnbBaseUrl = getCnbAiBaseUrl()
  process.env.OPENAI_BASE_URL = cnbBaseUrl.replace(/\/$/, '')
  process.env.OPENAI_API_KEY = cnbToken
  process.env.OPENAI_MODEL = cnbModel

  const adapterFetch = createOpenAIAdapterFetch(resolvedFetch || undefined)
  return new Anthropic({
    apiKey: 'cnb-compat-dummy-key',
    baseURL: process.env.OPENAI_BASE_URL,
    ...ARGS,
    fetch: adapterFetch,
  })
}
```

CNB 模式在请求转换时额外执行两层清洗：

- **敏感词替换**：安全术语（如 `SQL injection`）→ 通用术语（如 `input validation issues`）
- **身份词替换**：`Claude` → `Assistant`，`Anthropic` → `the AI team` 等
- **系统提示词处理**：支持混合模式（替换 CLI 默认提示词，保留 CLAUDE.md 内容）

### 4. 3P 模型能力覆盖

对于第三方提供商，可通过环境变量声明模型支持的能力：

| 环境变量 | 说明 |
|---|---|
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | 指定 Opus 模型名称 |
| `ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES` | 声明能力，如 `thinking,adaptive_thinking` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | 指定 Sonnet 模型名称 |
| `ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES` | 声明能力 |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | 指定 Haiku 模型名称 |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES` | 声明能力 |

```typescript
// ../../claude-code-source/src/utils/model/modelSupportOverrides.ts#L30
export const get3PModelCapabilityOverride = memoize(
  (model: string, capability: ModelCapabilityOverride): boolean | undefined => {
    if (getAPIProvider() === 'firstParty') return undefined
    const m = model.toLowerCase()
    for (const tier of TIERS) {
      const pinned = process.env[tier.modelEnvVar]
      const capabilities = process.env[tier.capabilitiesEnvVar]
      if (!pinned || capabilities === undefined) continue
      if (m !== pinned.toLowerCase()) continue
      return capabilities.toLowerCase().split(',').map(s => s.trim()).includes(capability)
    }
    return undefined
  },
)
```

## 五、 Thinking 模式配置与实现

### 1. ThinkingConfig 类型定义

Thinking 模式的配置类型定义在 [`src/utils/thinking.ts`](../../claude-code-source/src/utils/thinking.ts#L10) 中：

```typescript
// ../../claude-code-source/src/utils/thinking.ts#L10
export type ThinkingConfig =
  | { type: 'adaptive' }       // 自适应思考（模型自行决定思考量）
  | { type: 'enabled'; budgetTokens: number }  // 固定预算思考
  | { type: 'disabled' }       // 禁用思考
```

### 2. Thinking 模式是否启用的判断

#### 2.1 默认是否启用

[`shouldEnableThinkingByDefault()`](../../claude-code-source/src/utils/thinking.ts#L146) 函数决定 Thinking 是否默认启用：

```typescript
// ../../claude-code-source/src/utils/thinking.ts#L146
export function shouldEnableThinkingByDefault(): boolean {
  if (process.env.MAX_THINKING_TOKENS) {
    return parseInt(process.env.MAX_THINKING_TOKENS, 10) > 0
  }
  const { settings } = getSettingsWithErrors()
  if (settings.alwaysThinkingEnabled === false) {
    return false
  }
  return true // 默认启用
}
```

相关配置项：

| 配置方式 | 说明 |
|---|---|
| `MAX_THINKING_TOKENS` 环境变量 | `> 0` 启用，`= 0` 禁用 |
| `settings.alwaysThinkingEnabled` | 设为 `false` 可禁用 |
| 默认行为 | 启用 |

#### 2.2 模型是否支持 Thinking

[`modelSupportsThinking()`](../../claude-code-source/src/utils/thinking.ts#L90) 函数判断给定模型是否支持 Thinking：

```typescript
// ../../claude-code-source/src/utils/thinking.ts#L90
export function modelSupportsThinking(model: string): boolean {
  const supported3P = get3PModelCapabilityOverride(model, 'thinking')
  if (supported3P !== undefined) return supported3P

  const canonical = getCanonicalName(model)
  const provider = getAPIProvider()

  // 1P 和 Foundry：所有 Claude 4+ 模型（含 Haiku 4.5）
  if (provider === 'foundry' || provider === 'firstParty') {
    return !canonical.includes('claude-3-')
  }
  // 3P（Bedrock/Vertex）：仅 Opus 4+ 和 Sonnet 4+
  return canonical.includes('sonnet-4') || canonical.includes('opus-4')
}
```

#### 2.3 模型是否支持 Adaptive Thinking

[`modelSupportsAdaptiveThinking()`](../../claude-code-source/src/utils/thinking.ts#L113) 判断模型是否支持自适应思考（无需指定 `budget_tokens`）：

```typescript
// ../../claude-code-source/src/utils/thinking.ts#L113
export function modelSupportsAdaptiveThinking(model: string): boolean {
  const supported3P = get3PModelCapabilityOverride(model, 'adaptive_thinking')
  if (supported3P !== undefined) return supported3P

  const canonical = getCanonicalName(model)
  // Opus 4.6 和 Sonnet 4.6 支持
  if (canonical.includes('opus-4-6') || canonical.includes('sonnet-4-6')) return true
  // 其他已知模型不支持
  if (canonical.includes('opus') || canonical.includes('sonnet') || canonical.includes('haiku')) return false
  // 未知模型：1P 和 Foundry 默认支持
  const provider = getAPIProvider()
  return provider === 'firstParty' || provider === 'foundry'
}
```

### 3. Thinking 配置的入口

`ThinkingConfig` 从 CLI 参数和设置中构建，在 [`src/main.tsx`](../../claude-code-source/src/main.tsx#L2456) 中初始化：

```typescript
// src/main.tsx 中的逻辑（简化）
let thinkingConfig: ThinkingConfig = thinkingEnabled !== false ? {
  type: 'adaptive',
} : { type: 'disabled' }

if (options.thinking === 'adaptive' || options.thinking === 'enabled') {
  thinkingEnabled = true
  thinkingConfig = { type: 'adaptive' }  // 或 { type: 'enabled', budgetTokens: N }
} else if (options.thinking === 'disabled') {
  thinkingEnabled = false
  thinkingConfig = { type: 'disabled' }
}

const maxThinkingTokens = process.env.MAX_THINKING_TOKENS
  ? parseInt(process.env.MAX_THINKING_TOKENS, 10)
  : options.maxThinkingTokens

if (maxThinkingTokens !== undefined && maxThinkingTokens > 0) {
  thinkingConfig = { type: 'enabled', budgetTokens: maxThinkingTokens }
}
```

用户可通过以下方式控制 Thinking：

- CLI 参数：`--thinking adaptive` / `--thinking enabled` / `--thinking disabled`
- 环境变量：`MAX_THINKING_TOKENS`（设为具体数值使用固定预算模式）
- 设置文件：`alwaysThinkingEnabled: false` 禁用
- 运行时命令：`/thinking` 切换

### 4. Thinking 在 API 请求中的应用

在 [`src/services/api/claude.ts`](../../claude-code-source/src/services/api/claude.ts#L1610) 中，`ThinkingConfig` 被转化为 Anthropic API 的 `thinking` 参数：

```typescript
// ../../claude-code-source/src/services/api/claude.ts#L1610
const hasThinking =
  thinkingConfig.type !== 'disabled' &&
  !isEnvTruthy(process.env.CLAUDE_CODE_DISABLE_THINKING)

let thinking: BetaMessageStreamParams['thinking'] | undefined = undefined

if (hasThinking && modelSupportsThinking(options.model)) {
  if (
    !isEnvTruthy(process.env.CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING) &&
    modelSupportsAdaptiveThinking(options.model)
  ) {
    // 自适应思考：无预算
    thinking = { type: 'adaptive' }
  } else {
    // 固定预算思考
    let thinkingBudget = getMaxThinkingTokensForModel(options.model)
    if (thinkingConfig.type === 'enabled' && thinkingConfig.budgetTokens !== undefined) {
      thinkingBudget = thinkingConfig.budgetTokens
    }
    thinkingBudget = Math.min(maxOutputTokens - 1, thinkingBudget)
    thinking = { budget_tokens: thinkingBudget, type: 'enabled' }
  }
}
```

判断逻辑流程：

1. **Thinking 是否启用**：`ThinkingConfig.type !== 'disabled'` 且 `CLAUDE_CODE_DISABLE_THINKING` 未设置
2. **模型是否支持**：通过 [`modelSupportsThinking()`](../../claude-code-source/src/utils/thinking.ts#L90) 判断
3. **选择模式**：
   - 若模型支持 Adaptive Thinking 且未禁用 → 使用 `{ type: 'adaptive' }`
   - 否则 → 使用 `{ type: 'enabled', budget_tokens: N }`，预算取 `min(用户指定值, maxOutputTokens - 1)`

### 5. 约束：max_tokens > budget_tokens

API 要求 `max_tokens` 必须大于 `thinking.budget_tokens`。[`adjustParamsForNonStreaming()`](../../claude-code-source/src/services/api/claude.ts#L3364) 函数确保此约束：

```typescript
// ../../claude-code-source/src/services/api/claude.ts#L3364
export function adjustParamsForNonStreaming<
  T extends { max_tokens: number; thinking?: BetaMessageStreamParams['thinking'] }
>(params: T, maxTokensCap: number): T {
  const cappedMaxTokens = Math.min(params.max_tokens, maxTokensCap)
  const adjustedParams = { ...params }
  if (adjustedParams.thinking?.type === 'enabled' && adjustedParams.thinking.budget_tokens) {
    adjustedParams.thinking = {
      ...adjustedParams.thinking,
      budget_tokens: Math.min(adjustedParams.thinking.budget_tokens, cappedMaxTokens - 1),
    }
  }
  return { ...adjustedParams, max_tokens: cappedMaxTokens }
}
```

### 6. Beta 头与 Thinking

Thinking 相关的 Beta 头定义在 [`src/constants/betas.ts`](../../claude-code-source/src/constants/betas.ts#L4) 中：

| Beta 头 | 说明 |
|---|---|
| `interleaved-thinking-2025-05-14` | 交错思考（思考与文本输出交替） |
| `redact-thinking-2026-02-12` | 隐藏思考内容 |

Bedrock 对 Beta 头有特殊处理，部分 Beta 需要通过 `extraBodyParams` 而非 HTTP 头传递：

```typescript
// ../../claude-code-source/src/constants/betas.ts#L38
export const BEDROCK_EXTRA_PARAMS_HEADERS = new Set([
  INTERLEAVED_THINKING_BETA_HEADER,
  CONTEXT_1M_BETA_HEADER,
  TOOL_SEARCH_BETA_HEADER_3P,
])
```

### 7. Ultrathink 关键词触发

系统还支持通过 `ultrathink` 关键词在用户输入中触发高强度思考：

```typescript
// ../../claude-code-source/src/utils/thinking.ts#L19
export function isUltrathinkEnabled(): boolean {
  if (!feature('ULTRATHINK')) return false
  return getFeatureValue_CACHED_MAY_BE_STALE('tengu_turtle_carbon', true)
}

export function hasUltrathinkKeyword(text: string): boolean {
  return /\bultrathink\b/i.test(text)
}
```

当用户输入包含 `ultrathink` 关键词时，系统会提高思考预算以获得更深度的推理。

### 8. 运行时切换 Thinking

用户可通过 `ThinkingToggle` 组件在会话中切换 Thinking 模式，对应的 UI 提供两个选项：

- **Enabled**：Claude will think before responding
- **Disabled**：Claude will respond without extended thinking

在会话中途切换时会弹出警告：切换 Thinking 模式会增加延迟并可能降低质量。

## 六、 完整架构流程图

```
用户输入
  │
  ├─ CLI 参数 / 设置文件 / 环境变量
  │     │
  │     ├─ 模型选择（ANTHROPIC_MODEL / settings.model）
  │     ├─ Thinking 配置（ThinkingConfig）
  │     └─ 提供商选择（CLAUDE_CODE_USE_*）
  │
  ▼
getAnthropicClient()
  │
  ├─ CLAUDE_CODE_USE_BEDROCK=1  → AnthropicBedrock（AWS SDK）
  ├─ CLAUDE_CODE_USE_FOUNDRY=1  → AnthropicFoundry（Azure SDK）
  ├─ CLAUDE_CODE_USE_VERTEX=1   → AnthropicVertex（GCP SDK）
  ├─ CLAUDE_CODE_USE_CNB=1      → Anthropic + OpenAI Adapter Fetch（CNB 清洗）
  ├─ CLAUDE_CODE_USE_OPENAI=1   → Anthropic + OpenAI Adapter Fetch
  └─ 默认 FirstParty            → Anthropic（API Key / OAuth）
  │
  ▼
API 请求构建（claude.ts）
  │
  ├─ thinking 参数：
  │     ├─ adaptive → { type: 'adaptive' }
  │     ├─ enabled  → { type: 'enabled', budget_tokens: N }
  │     └─ disabled → 不发送 thinking 参数
  │
  ├─ Beta 头注入
  ├─ max_tokens 约束调整
  └─ 请求发送
  │
  ▼
流式 / 非流式响应处理
  │
  ├─ OpenAI 适配器：OpenAI SSE → Anthropic SSE 实时转换
  └─ 原生 Anthropic：直接处理
```

## 七、 关键文件索引

| 文件路径 | 说明 |
|---|---|
| [`src/services/api/client.ts`](../../claude-code-source/src/services/api/client.ts#L90) | 客户端创建核心函数 |
| [`src/services/api/openai-adapter.ts`](../../claude-code-source/src/services/api/openai-adapter.ts#L846) | OpenAI 兼容适配器 |
| [`src/services/api/claude.ts`](../../claude-code-source/src/services/api/claude.ts#L1610) | API 请求构建与 Thinking 应用 |
| [`src/utils/auth.ts`](../../claude-code-source/src/utils/auth.ts#L227) | API Key / OAuth 解析 |
| [`src/utils/thinking.ts`](../../claude-code-source/src/utils/thinking.ts#L10) | Thinking 类型定义与模型支持判断 |
| [`src/utils/model/providers.ts`](../../claude-code-source/src/utils/model/providers.ts#L4) | 提供商类型定义与判断 |
| [`src/utils/model/model.ts`](../../claude-code-source/src/utils/model/model.ts#L36) | 模型选择逻辑 |
| [`src/utils/model/modelSupportOverrides.ts`](../../claude-code-source/src/utils/model/modelSupportOverrides.ts#L30) | 3P 模型能力覆盖 |
| [`src/utils/context.ts`](../../claude-code-source/src/utils/context.ts#L219) | 上下文窗口与 Thinking Token 上限 |
| [`src/constants/betas.ts`](../../claude-code-source/src/constants/betas.ts#L4) | Beta 头定义 |

---
*本文档由 markdowncli 技能辅助生成*

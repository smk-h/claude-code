<!-- more -->

## 一、 概述

本文档聚焦 Claude Code 中单个 MCP 服务器的**连接实现**，即 [`connectToServer()`](../../claude-code-source/src/services/mcp/client.ts#L595) 函数的内部细节：Transport 选型与创建、MCP SDK `Client` 的初始化与能力声明、带超时的握手、握手后的 capabilities 获取、默认 request handler 注册、连接错误桥接以及认证失败降级。本文不涉及上层生命周期编排（见 [LV006-MCP-Host与连接生命周期](LV006-MCP-Host与连接生命周期.md)），也不涉及工具发现与调用（见 [LV008-MCP-工具发现与调用](LV008-MCP-工具发现与调用.md)）。

## 二、 connectToServer 总览

[`connectToServer`](../../claude-code-source/src/services/mcp/client.ts#L595) 是单服务器连接的唯一入口，使用 `lodash.memoize` 缓存，缓存键格式为 `${name}-${jsonStringify(serverRef)}`。这意味着同一份配置在缓存未失效前只会真正连接一次，重连必须先调用 [`clearServerCache()`](../../claude-code-source/src/services/mcp/client.ts#L1648) 清缓存。

### 1. 超时配置

| 配置项 | 默认值 | 环境变量 | 来源 |
|------|-------|---------|------|
| 连接超时 | 30000 ms | `MCP_TIMEOUT` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L456) |
| 请求超时 | 60000 ms | —（固定常量） | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L463) |
| 工具调用超时 | ~27.8 小时 | `MCP_TOOL_TIMEOUT` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L224) |

```typescript
// claude-code-source/src/services/mcp/client.ts
function getConnectionTimeoutMs(): number {
  return parseInt(process.env.MCP_TIMEOUT || '', 10) || 30000
}
const MCP_REQUEST_TIMEOUT_MS = 60000
function getMcpToolTimeoutMs(): number {
  return parseInt(process.env.MCP_TOOL_TIMEOUT || '', 10) || DEFAULT_MCP_TOOL_TIMEOUT_MS
}
```

### 2. 函数骨架

```typescript
// claude-code-source/src/services/mcp/client.ts
export const connectToServer = memoize(async (name, serverRef, serverStats) => {
  const connectStartTime = Date.now()
  let inProcessServer
  try {
    let transport
    // 1. 根据 serverRef.type 创建 Transport（见三）
    // 2. 创建 Client 并注册 ListRoots handler（见四）
    // 3. 带超时握手（见五）
    // 4. 获取 capabilities / serverVersion / instructions（见六）
    // 5. 注册默认 Elicitation handler + 错误桥接（见七、八）
    return { client, name, type: 'connected', capabilities, serverInfo, instructions, config, cleanup }
  } catch (error) {
    // 处理 SSE/HTTP/claudeai-proxy 的认证失败降级（见九）
    throw error
  }
})
```

## 三、 Transport 创建

[`connectToServer`](../../claude-code-source/src/services/mcp/client.ts#L595) 根据 [`serverRef.type`](../../claude-code-source/src/services/mcp/types.ts#L23) 分支创建对应的 Transport 实例。所有支持的类型在 [`types.ts`](../../claude-code-source/src/services/mcp/types.ts) 中以 Zod schema 定义。

### 1. Transport 类型总览

| `type` | Transport 类 | 关键特性 |
|------|-------------|---------|
| `sse` | `SSEClientTransport` | `ClaudeAuthProvider` + 超时包装 fetch + StepUp 检测 + 合并 headers |
| `sse-ide` | `SSEClientTransport` | IDE 扩展用，无认证，支持代理 |
| `ws` | `WebSocketTransport` | 合并 headers + session ingress token + 代理/TLS |
| `ws-ide` | `WebSocketTransport` | IDE auth token + 代理/TLS |
| `http` | `StreamableHTTPClientTransport` | `ClaudeAuthProvider` + 超时包装 fetch + 代理 + 合并 headers |
| `claudeai-proxy` | `StreamableHTTPClientTransport` | claude.ai OAuth token + 代理 |
| `stdio` / 无 type | `StdioClientTransport` | command + args + env + stderr pipe |
| Chrome/Computer Use | `InProcessTransport` | 进程内 MCP 服务器，免子进程 |

### 2. SSE Transport

[`sse` 分支](../../claude-code-source/src/services/mcp/client.ts#L619) 为远程 SSE 服务器配置认证、超时与 headers：

```typescript
// claude-code-source/src/services/mcp/client.ts
const transportOptions: SSEClientTransportOptions = {
  authProvider: new ClaudeAuthProvider(name, serverRef),
  fetch: wrapFetchWithTimeout(
    wrapFetchWithStepUpDetection(createFetchWithInit(), authProvider),
  ),
  requestInit: {
    headers: { 'User-Agent': getMCPUserAgent(), ...combinedHeaders },
  },
  eventSourceInit: {
    fetch: async (url, init) => {
      const tokens = await authProvider.tokens()
      return fetch(url, { ...proxyOptions, headers: { ...authHeaders, ...combinedHeaders } })
    },
  },
}
transport = new SSEClientTransport(new URL(serverRef.url), transportOptions)
```

【**关键设计**】

- `eventSourceInit.fetch` **不**使用超时包装：EventSource 是长连接，60 秒超时会把它误杀；
- `requestInit.fetch` 使用超时包装：POST 请求应该有超时；
- [`wrapFetchWithStepUpDetection`](../../claude-code-source/src/services/mcp/auth.ts#L1354) 包在最内层，确保 403 响应在 SDK 调用 `auth()→tokens()` 之前被拦截，触发 step-up 流程。

### 3. HTTP Transport

[`http` 分支](../../claude-code-source/src/services/mcp/client.ts#L784) 使用 `StreamableHTTPClientTransport`（MCP 2025-03-26 规范）。它与 SSE 类似但额外考虑：

- 若该服务器已存储 OAuth token，则不再注入 session ingress token（避免覆盖 SDK 的 `Authorization` 头）；
- 通过 [`wrapFetchWithTimeout`](../../claude-code-source/src/services/mcp/client.ts#L492) 为每个 POST 请求设置 60 秒超时，并保证 `Accept: application/json, text/event-stream` 头存在（Streamable HTTP 规范要求）。

### 4. WebSocket Transport

[`ws`](../../claude-code-source/src/services/mcp/client.ts#L735) 与 [`ws-ide`](../../claude-code-source/src/services/mcp/client.ts#L708) 分支构造自定义 `WebSocketTransport`（见 [`mcpWebSocketTransport.ts`](../../claude-code-source/src/utils/mcpWebSocketTransport.ts#L22)），区分点：

- `ws`：合并用户配置 headers + session ingress token（如有），子协议 `mcp`；
- `ws-ide`：通过 `X-Claude-Code-Ide-Authorization` 头携带 IDE auth token；
- Bun 与 Node 两种运行时分别走原生 `WebSocket` 与 `createNodeWsClient`，统一传入 proxy URL 与 TLS 选项。

### 5. Stdio Transport

[`stdio` 分支](../../claude-code-source/src/services/mcp/client.ts#L944) 创建子进程 Transport：

```typescript
// claude-code-source/src/services/mcp/client.ts
const finalCommand = process.env.CLAUDE_CODE_SHELL_PREFIX || serverRef.command
const finalArgs = process.env.CLAUDE_CODE_SHELL_PREFIX
  ? [[serverRef.command, ...serverRef.args].join(' ')]
  : serverRef.args
transport = new StdioClientTransport({
  command: finalCommand,
  args: finalArgs,
  env: { ...subprocessEnv(), ...serverRef.env },
  stderr: 'pipe',  // 防止 MCP 服务器错误输出污染 UI
})
```

连接前还会把 stderr 透传到调试日志，并限制累积上限 64 MiB 防止内存膨胀：

```typescript
// claude-code-source/src/services/mcp/client.ts
stdioTransport.stderr.on('data', (data: Buffer) => {
  if (stderrOutput.length < 64 * 1024 * 1024) {
    stderrOutput += data.toString()
  }
})
```

### 6. In-Process Transport

对于 Chrome MCP 与 Computer Use MCP，[`connectToServer`](../../claude-code-source/src/services/mcp/client.ts#L905) 通过 [`createLinkedTransportPair()`](../../claude-code-source/src/services/mcp/InProcessTransport.ts#L1) 在进程内创建一对 linked transport，避免 spawn 一个 ~325 MB 的子进程：

```typescript
// claude-code-source/src/services/mcp/client.ts
const [clientTransport, serverTransport] = createLinkedTransportPair()
await inProcessServer.connect(serverTransport)
transport = clientTransport
```

### 7. claude.ai Proxy Transport

[`claudeai-proxy` 分支](../../claude-code-source/src/services/mcp/client.ts#L868) 把 claude.ai connector 的请求代理到 `${MCP_PROXY_URL}${MCP_PROXY_PATH}`，使用 claude.ai OAuth token 鉴权，并通过 `X-Mcp-Client-Session-Id` 头携带会话 ID。

## 四、 Client 创建与能力声明

Transport 就绪后，[`connectToServer`](../../claude-code-source/src/services/mcp/client.ts#L985) 创建 MCP SDK 的 `Client`，并在 client info 中声明 Claude Code 自身的 capabilities：

```typescript
// claude-code-source/src/services/mcp/client.ts
const client = new Client(
  {
    name: 'claude-code',
    title: 'Claude Code',
    version: MACRO.VERSION ?? 'unknown',
    description: "Anthropic's agentic coding tool",
    websiteUrl: PRODUCT_URL,
  },
  {
    capabilities: {
      roots: {},         // 声明 roots 能力，允许服务器查询工作目录
      elicitation: {},   // 声明 elicitation 能力（空对象，避免破坏 Java SDK 服务器）
    },
  },
)
```

【**elicitation 为何是空对象**】注释中明确说明：发送 `{form:{},url:{}}` 会破坏 Java MCP SDK 服务器（Spring AI），其 `Elicitation` 类没有任何字段，遇到未知属性即失败。因此这里只发空对象表示“声明能力但不约束子能力”。

随后注册 `ListRoots` 请求处理器，把当前工作目录暴露给服务器：

```typescript
// claude-code-source/src/services/mcp/client.ts
client.setRequestHandler(ListRootsRequestSchema, async () => ({
  roots: [{ uri: `file://${getOriginalCwd()}` }],
}))
```

## 五、 带超时的握手

[`connectToServer`](../../claude-code-source/src/services/mcp/client.ts#L1048) 使用 `Promise.race` 让连接与超时竞争，超时后会主动关闭 Transport 与 in-process 服务器：

```typescript
// claude-code-source/src/services/mcp/client.ts
const connectPromise = client.connect(transport)
const timeoutPromise = new Promise<never>((_, reject) => {
  const timeoutId = setTimeout(() => {
    if (inProcessServer) inProcessServer.close().catch(() => {})
    transport.close().catch(() => {})
    reject(new TelemetrySafeError_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS(
      `MCP server "${name}" connection timed out after ${getConnectionTimeoutMs()}ms`,
      'MCP connection timeout',
    ))
  }, getConnectionTimeoutMs())

  // 连接 resolve/reject 时清除超时定时器
  connectPromise.then(() => clearTimeout(timeoutId), _error => clearTimeout(timeoutId))
})

await Promise.race([connectPromise, timeoutPromise])
```

【**为什么需要自定义超时**】SDK 内部对 stdio 等连接没有内置超时，否则测试与异常服务器会导致进程永久挂起；超时后必须主动关闭 transport，否则子进程或 socket 会泄漏。

## 六、 握手后获取服务器信息

握手成功后，[`connectToServer`](../../claude-code-source/src/services/mcp/client.ts#L1157) 通过 SDK 三个 getter 获取服务器信息：

```typescript
// claude-code-source/src/services/mcp/client.ts
const capabilities = client.getServerCapabilities()
const serverVersion = client.getServerVersion()
const rawInstructions = client.getInstructions()
let instructions = rawInstructions
if (rawInstructions && rawInstructions.length > MAX_MCP_DESCRIPTION_LENGTH) {
  instructions = rawInstructions.slice(0, MAX_MCP_DESCRIPTION_LENGTH) + '… [truncated]'
}
```

`capabilities` 是后续决定能否调用 `fetchToolsForClient` / `fetchCommandsForClient` / `fetchResourcesForClient` 的依据，结构对应 MCP 协议的 `ServerCapabilities`（`tools` / `prompts` / `resources` / `logging` / `experimental` 等）。`instructions` 会被截断到 `MAX_MCP_DESCRIPTION_LENGTH` 字符，避免过长指令撑爆 system prompt。

## 七、 默认 Elicitation Handler

由于从握手完成到上层 [`onConnectionAttempt`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L331) 覆盖 handler 之间存在一个时间窗口，期间服务器可能立即发起 Elicitation 请求。[`connectToServer`](../../claude-code-source/src/services/mcp/client.ts#L1191) 先注册一个返回 cancel 的占位 handler：

```typescript
// claude-code-source/src/services/mcp/client.ts
client.setRequestHandler(ElicitRequestSchema, async request => {
  logMCPDebug(name, `Elicitation request received during initialization: ${jsonStringify(request)}`)
  return { action: 'cancel' as const }
})
```

随后由 [`registerElicitationHandler(client.client, client.name, setAppState)`](../../claude-code-source/src/services/mcp/elicitationHandler.ts#L68) 覆盖为真正的 UI 交互 handler。

## 八、 错误桥接：onerror → onclose

### 1. 问题背景

MCP SDK 的 Transport 在连接失败时调用 `onerror` 但不调用 `onclose`，而 Claude Code 用 `onclose` 触发自动重连。如果不做桥接，远程 transport 断线后既不会重连也不会清缓存，工具调用会一直挂在 pending 状态。

### 2. 桥接实现

[`connectToServer`](../../claude-code-source/src/services/mcp/client.ts#L1216) 通过包装 `client.onerror` 实现桥接，关键变量：

```typescript
// claude-code-source/src/services/mcp/client.ts
let consecutiveConnectionErrors = 0
const MAX_ERRORS_BEFORE_RECONNECT = 3
let hasTriggeredClose = false   // 防止 close() 重新触发 onerror 时重入

const closeTransportAndRejectPending = (reason: string) => {
  if (hasTriggeredClose) return
  hasTriggeredClose = true
  void client.close().catch(e => { /* ... */ })
}
```

`client.close()` 会触发 `transport.close() → transport.onclose → SDK _onclose()`，后者会拒绝所有 pending 请求（包括挂起的 `callTool()`，使其以 `McpError -32000 "Connection closed"` 失败），然后调用我们注册的 `client.onclose`（在 [LV006](LV006-MCP-Host与连接生命周期.md#九-断线自动重连) 中触发重连）。

### 3. 终端错误识别

[`isTerminalConnectionError()`](../../claude-code-source/src/services/mcp/client.ts#L1249) 通过错误消息子串识别“应该立即重连”的终端错误：

- 网络层：`ECONNRESET` / `ETIMEDOUT` / `EPIPE` / `EHOSTUNREACH` / `ECONNREFUSED`
- HTTP/SSE 层：`Body Timeout Error` / `terminated`
- SDK 中间错误：`SSE stream disconnected` / `Failed to reconnect SSE stream`

只要命中其一，立即调用 `closeTransportAndRejectPending` 触发重连，无需等 3 次累计。

### 4. 累计错误降级

对于非终端错误，[`client.onerror`](../../claude-code-source/src/services/mcp/client.ts#L1266) 累计计数；连续 3 次后调用 `closeTransportAndRejectPending('consecutive errors')`，把问题转化为 `onclose` 走重连流程。

### 5. HTTP 会话过期识别

对 `http` / `claudeai-proxy` transport，[`onerror`](../../claude-code-source/src/services/mcp/client.ts#L1316) 还会通过 [`isMcpSessionExpiredError()`](../../claude-code-source/src/services/mcp/client.ts#L193) 检测 404 + JSON-RPC -32001 的会话过期组合，立即关闭 transport 让下一次工具调用重建会话。

## 九、 认证失败降级

### 1. 三类 transport 的 401 处理

[`connectToServer`](../../claude-code-source/src/services/mcp/client.ts#L1090) 的 catch 分支针对三种远程 transport 做认证失败降级：

- **sse**：捕获 `UnauthorizedError`，调用 [`handleRemoteAuthFailure(name, serverRef, 'sse')`](../../claude-code-source/src/services/mcp/client.ts#L340) 返回 `needs-auth` 状态；
- **http**：同上，传 `'http'`；
- **claudeai-proxy**：检测 `StreamableHTTPError.code === 401`，调用 [`handleRemoteAuthFailure(name, serverRef, 'claudeai-proxy')`](../../claude-code-source/src/services/mcp/client.ts#L340)。

返回的 `NeedsAuthMCPServer` 会被 [`getMcpToolsCommandsAndResources`](../../claude-code-source/src/services/mcp/client.ts#L2326) 转换为一个 [`createMcpAuthTool(name, config)`](../../claude-code-source/src/tools/McpAuthTool/McpAuthTool.ts#L49) 伪工具，让 LLM 可以通过调用该工具触发 OAuth 流程。

### 2. needs-auth 缓存

为避免每次配置变更都重新探测已失败的远程服务器，[`getMcpToolsCommandsAndResources`](../../claude-code-source/src/services/mcp/client.ts#L2307) 在连接前先检查 [`isMcpAuthCached(name)`](../../claude-code-source/src/services/mcp/client.ts#L280)（15 分钟 TTL）。命中时直接返回 `needs-auth` 状态而不发起连接：

```typescript
// claude-code-source/src/services/mcp/client.ts
if (
  (config.type === 'claudeai-proxy' || config.type === 'http' || config.type === 'sse') &&
  ((await isMcpAuthCached(name)) ||
   ((config.type === 'http' || config.type === 'sse') && hasMcpDiscoveryButNoToken(name, config)))
) {
  onConnectionAttempt({
    client: { name, type: 'needs-auth' as const, config },
    tools: [createMcpAuthTool(name, config)],
    commands: [],
  })
  return
}
```

## 十、 ClaudeAuthProvider

[`ClaudeAuthProvider`](../../claude-code-source/src/services/mcp/auth.ts#L1376) 实现了 MCP SDK 的 `OAuthClientProvider` 接口，是 SSE/HTTP transport 的认证核心。

### 1. 关键属性

```typescript
// claude-code-source/src/services/mcp/auth.ts
export class ClaudeAuthProvider implements OAuthClientProvider {
  private serverName: string
  private serverConfig: McpSSEServerConfig | McpHTTPServerConfig
  private redirectUri: string
  private _codeVerifier?: string
  private _authorizationUrl?: string
  private _state?: string
  private _scopes?: string
  private _metadata?: Awaited<ReturnType<typeof discoverAuthorizationServerMetadata>>
  private _refreshInProgress?: Promise<OAuthTokens | undefined>
  private _pendingStepUpScope?: string
  private onAuthorizationUrlCallback?: (url: string) => void
  private skipBrowserOpen: boolean
}
```

### 2. clientMetadata

```typescript
// claude-code-source/src/services/mcp/auth.ts
get clientMetadata(): OAuthClientMetadata {
  const metadata: OAuthClientMetadata = {
    client_name: `Claude Code (${this.serverName})`,
    redirect_uris: [this.redirectUri],
    grant_types: ['authorization_code', 'refresh_token'],
    response_types: ['code'],
    token_endpoint_auth_method: 'none', // Public client
  }
  // 若服务器 metadata 提供了 scope，写入 clientMetadata
  return metadata
}
```

### 3. Step-Up 流程

[`markStepUpPending(scope)`](../../claude-code-source/src/services/mcp/auth.ts#L1468) 在 fetch wrapper 检测到 403 `insufficient_scope` 时被调用，使后续 `tokens()` 调用省略 `refresh_token`，强制 SDK 走 `startAuthorization → redirectToAuthorization` 完成权限提升。RFC 6749 §6 禁止通过 refresh 提升权限，所以这一步是必须的。

### 4. tokens()

[`tokens()`](../../claude-code-source/src/services/mcp/auth.ts#L1540) 是 SDK 在每次请求前调用的方法，负责返回当前存储的 OAuth token，或在 step-up pending 时省略 refresh token 触发重新授权。

## 十一、 缓存与重连辅助函数

### 1. clearServerCache()

[`clearServerCache(name, serverRef)`](../../claude-code-source/src/services/mcp/client.ts#L1648) 是重连前的必经步骤，它会：

1. 调用 `connectToServer(name, serverRef)` 取出已缓存的 client（如有），调用其 `cleanup()` 关闭底层 transport；
2. 删除 `connectToServer.cache` 中该 key 的条目；
3. 删除 `fetchToolsForClient.cache` / `fetchResourcesForClient.cache` / `fetchCommandsForClient.cache` / `fetchMcpSkillsForClient.cache` 中该服务器名的条目。

```typescript
// claude-code-source/src/services/mcp/client.ts
export async function clearServerCache(name, serverRef) {
  const key = getServerCacheKey(name, serverRef)
  try {
    const wrappedClient = await connectToServer(name, serverRef)
    if (wrappedClient.type === 'connected') {
      await wrappedClient.cleanup()
    }
  } catch { /* 服务器可能从未连上，忽略 */ }

  connectToServer.cache.delete(key)
  fetchToolsForClient.cache.delete(name)
  fetchResourcesForClient.cache.delete(name)
  fetchCommandsForClient.cache.delete(name)
  if (feature('MCP_SKILLS')) fetchMcpSkillsForClient!.cache.delete(name)
}
```

### 2. ensureConnectedClient()

[`ensureConnectedClient(client)`](../../claude-code-source/src/services/mcp/client.ts#L1688) 在每次工具调用前确保 client 仍然有效。如果缓存已被清空（例如 onclose 触发），它会触发重连；SDK 类型服务器（`type === 'sdk'`）在进程内运行，由 `setupSdkMcpClients` 单独管理，直接返回原 client。

### 3. reconnectMcpServerImpl()

[`reconnectMcpServerImpl(name, config)`](../../claude-code-source/src/services/mcp/client.ts#L2137) 是手动/自动重连的核心实现：

```typescript
// claude-code-source/src/services/mcp/client.ts
export async function reconnectMcpServerImpl(name, config) {
  try {
    clearKeychainCache()           // 让其它进程修改的 token 立即生效
    await clearServerCache(name, config)
    const client = await connectToServer(name, config)
    if (client.type !== 'connected') {
      return { client, tools: [], commands: [] }
    }
    const [tools, mcpCommands, mcpSkills, resources] = await Promise.all([
      fetchToolsForClient(client),
      fetchCommandsForClient(client),
      feature('MCP_SKILLS') && supportsResources ? fetchMcpSkillsForClient!(client) : Promise.resolve([]),
      supportsResources ? fetchResourcesForClient(client) : Promise.resolve([]),
    ])
    return { client, tools: [...tools, ...resourceTools], commands: [...mcpCommands, ...mcpSkills], resources }
  } catch (error) {
    return { client: { name, type: 'failed' as const, config }, tools: [], commands: [] }
  }
}
```

【**clearKeychainCache 的必要性**】VS Code 扩展宿主可能修改 keychain 中的 token（清除或写入新 OAuth token）后请求 CLI 子进程重连。若不刷新缓存，子进程会一直使用旧的缓存数据，无法感知 token 变化。

## 十二、 并发控制

[`getMcpServerConnectionBatchSize()`](../../claude-code-source/src/services/mcp/client.ts#L552) 与 [`getRemoteMcpServerConnectionBatchSize()`](../../claude-code-source/src/services/mcp/client.ts#L556) 控制两类服务器的连接并发度：

```typescript
// claude-code-source/src/services/mcp/client.ts
export function getMcpServerConnectionBatchSize(): number {
  return parseInt(process.env.MCP_SERVER_CONNECTION_BATCH_SIZE || '', 10) || 3
}
function getRemoteMcpServerConnectionBatchSize(): number {
  return parseInt(process.env.MCP_REMOTE_SERVER_CONNECTION_BATCH_SIZE || '', 10) || 20
}
```

【**为什么 local 比 remote 小**】local 服务器（stdio/sdk）需要 spawn 子进程，过高并发会引发 CPU/内存竞争；remote 服务器只是网络连接，可以高并发。

实际由 [`processBatched`](../../claude-code-source/src/services/mcp/client.ts#L2218) 使用 `pMap` 实现，每个 slot 完成即释放，不会因为一个慢服务器阻塞整个批次（注释中说明 2026-03 重构自固定批次顺序执行）。

---
*本文档由 markdowncli 技能辅助生成*

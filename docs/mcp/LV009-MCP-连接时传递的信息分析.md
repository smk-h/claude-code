<!-- more -->

## 一、 概述

本文档详细分析 Claude Code 作为 MCP Host 在连接 MCP Server 时，**各层级之间传递了哪些信息**。数据流分为两个阶段：

1. **Claude Code（Host）→ MCP Client**：Host 创建 Client 实例和 Transport 时注入的配置与身份信息。
2. **MCP Client → MCP Server**：Client 通过 Transport 与 Server 握手及通信时实际传递的内容（协议层 `initialize` 握手 + 传输层 headers / env / 子进程参数）。

理解这些信息对于 MCP Server 端实现鉴权、日志、多租户区分等场景至关重要。

## 二、 整体数据流

```
┌─────────────────────────────────────────────────────────────────┐
│                     Claude Code (Host)                          │
│                                                                 │
│  connectToServer(name, serverRef)                               │
│    │                                                            │
│    ├─► 1. 创建 Transport (stdio/sse/http/ws/claudeai-proxy)     │
│    │     注入: env / headers / User-Agent / sessionId          │
│    │                                                            │
│    ├─► 2. 创建 MCP SDK Client 实例                              │
│    │     注入: clientInfo { name, title, version, ... }        │
│    │           capabilities { roots, elicitation }             │
│    │                                                            │
│    └─► 3. client.connect(transport)                            │
│           触发 MCP initialize 握手                              │
└──────────────────────┬──────────────────────────────────────────┘
                       │
                       ▼
              ┌─────────────────┐
              │   MCP Client    │  (SDK 层, @modelcontextprotocol/sdk)
              │                 │
              │  initialize 请求 │──► clientInfo
              │                 │──► capabilities
              │                 │
              └────────┬────────┘
                       │
                       ▼
          ┌────────────────────────────┐
          │      Transport 层          │
          │                            │
          │  stdio:  stdin/stdout + env│
          │  sse:   HTTP headers       │
          │  http:  HTTP headers       │
          │  ws:    WS headers         │
          └────────────┬───────────────┘
                       │
                       ▼
              ┌─────────────────┐
              │   MCP Server    │
              │                 │
              │  收到 initialize│
              │  收到 headers   │
              │  收到 env (stdio)│
              └─────────────────┘
```

## 三、 Host → MCP Client：注入的配置与身份信息

### 1. MCP Client 实例创建

Claude Code 为每个配置的 MCP Server 创建一个独立的 MCP SDK `Client` 实例，注入 `clientInfo` 和 `capabilities`。相关代码在 [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L985) 第 985-1002 行：

```typescript
// ../../claude-code-source/src/services/mcp/client.ts
const client = new Client(
  {
    name: 'claude-code',
    title: 'Claude Code',
    version: MACRO.VERSION ?? 'unknown',
    description: "Anthropic's agentic coding tool",
    websiteUrl: PRODUCT_URL,  // 'https://claude.com/claude-code'
  },
  {
    capabilities: {
      roots: {},
      elicitation: {},
    },
  },
)
```

| 字段 | 值 | 说明 |
|------|-----|------|
| `name` | `'claude-code'` | 客户端标识名，固定值 |
| `title` | `'Claude Code'` | 人类可读名称 |
| `version` | `MACRO.VERSION` | Claude Code 版本号 |
| `description` | `"Anthropic's agentic coding tool"` | 产品描述 |
| `websiteUrl` | `'https://claude.com/claude-code'` | 产品网站，定义在 [`product.ts`](../../claude-code-source/src/constants/product.ts#L1) |
| `capabilities.roots` | `{}` | 声明支持 roots 能力（空对象表示声明即可） |
| `capabilities.elicitation` | `{}` | 声明支持 elicitation 能力 |

> **注意**：`clientInfo` 是固定的，**不包含**任何 host 实例标识、会话 ID 或用户标识。所有 Claude Code 实例发出的 `clientInfo` 完全相同（除 version 外）。

### 2. ListRoots 请求处理器

Client 注册了 `ListRoots` 请求处理器，当 Server 请求 roots 时返回当前工作目录。相关代码在 [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L1009) 第 1009-1018 行：

```typescript
// ../../claude-code-source/src/services/mcp/client.ts
client.setRequestHandler(ListRootsRequestSchema, async () => {
  return {
    roots: [
      {
        uri: `file://${getOriginalCwd()}`,
      },
    ],
  }
})
```

这意味着 Server 可以通过 `roots/list` 请求获取到 Claude Code 的**当前工作目录**，这是唯一一个能间接反映 host 运行位置的协议层信息。

### 3. Transport 配置注入

Host 在创建 Transport 时注入的配置因 transport 类型而异，详见下一节。

## 四、 MCP Client → MCP Server：实际传递的内容

### 1. MCP 协议层：`initialize` 握手（所有 Transport 通用）

当 `client.connect(transport)` 被调用时（[`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L1048) 第 1048 行），MCP SDK 会自动发送 `initialize` JSON-RPC 请求，内容包含上述 `clientInfo` 和 `capabilities`：

```json
{
  "jsonrpc": "2.0",
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "clientInfo": {
      "name": "claude-code",
      "title": "Claude Code",
      "version": "1.0.x",
      "description": "Anthropic's agentic coding tool",
      "websiteUrl": "https://claude.com/claude-code"
    },
    "capabilities": {
      "roots": {},
      "elicitation": {}
    }
  }
}
```

**所有 transport 类型**（stdio / sse / http / ws / claudeai-proxy）都会通过 JSON-RPC 发送此握手。MCP Server 可以从 `clientInfo.name` 得知连接方是 Claude Code。

### 2. stdio Transport：子进程环境变量

stdio Transport 通过 spawn 子进程与 Server 通信。相关代码在 [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L944) 第 944-958 行：

```typescript
// ../../claude-code-source/src/services/mcp/client.ts
transport = new StdioClientTransport({
  command: finalCommand,
  args: finalArgs,
  env: {
    ...subprocessEnv(),
    ...serverRef.env,
  } as Record<string, string>,
  stderr: 'pipe',
})
```

传递的内容包括：

| 传递项 | 来源 | 说明 |
|--------|------|------|
| `command` | `serverRef.command` 或 `CLAUDE_CODE_SHELL_PREFIX` | 要执行的命令 |
| `args` | `serverRef.args` | 命令参数 |
| `env` | `subprocessEnv()` + `serverRef.env` | 环境变量 |
| stdin/stdout | MCP SDK 管理 | JSON-RPC 消息流 |

#### 2.1 `subprocessEnv()` 详解

`subprocessEnv()` 函数在 [`subprocessEnv.ts`](../../claude-code-source/src/utils/subprocessEnv.ts#L79) 第 79-99 行中声明：

```typescript
// ../../claude-code-source/src/utils/subprocessEnv.ts
export function subprocessEnv(): NodeJS.ProcessEnv {
  const proxyEnv = _getUpstreamProxyEnv?.() ?? {}

  if (!isEnvTruthy(process.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB)) {
    return Object.keys(proxyEnv).length > 0
      ? { ...process.env, ...proxyEnv }
      : process.env
  }
  const env = { ...process.env, ...proxyEnv }
  for (const k of GHA_SUBPROCESS_SCRUB) {
    delete env[k]
    delete env[`INPUT_${k}`]
  }
  return env
}
```

- **默认情况**：传递 `process.env` 的完整副本（加上代理环境变量）。
- **GitHub Actions 环境**（`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` 为真）：会剥离敏感密钥（如 `ANTHROPIC_API_KEY`、`CLAUDE_CODE_OAUTH_TOKEN` 等）。
- **用户自定义**：通过 MCP 配置的 `env` 字段可追加自定义环境变量。

> **关键**：stdio Transport **不传递** `CLAUDE_CODE_SESSION_ID`。该变量仅在 Shell spawn 时传递（仅限内部用户），MCP stdio 子进程**不会获得**任何会话标识。

### 3. SSE Transport：HTTP Headers

SSE Transport 在 HTTP 请求中传递以下 headers。相关代码在 [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L619) 第 619-676 行：

```typescript
// ../../claude-code-source/src/services/mcp/client.ts
requestInit: {
  headers: {
    'User-Agent': getMCPUserAgent(),
    ...combinedHeaders,  // 静态 headers + headersHelper 动态 headers
  },
},
```

SSE 长连接（EventSource）也会传递：

```typescript
// ../../claude-code-source/src/services/mcp/client.ts
headers: {
  'User-Agent': getMCPUserAgent(),
  ...authHeaders,        // OAuth Bearer token
  ...init?.headers,
  ...combinedHeaders,
  Accept: 'text/event-stream',
},
```

### 4. HTTP Transport（Streamable HTTP）：HTTP Headers

HTTP Transport 的 headers 配置在 [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L821) 第 821-840 行：

```typescript
// ../../claude-code-source/src/services/mcp/client.ts
requestInit: {
  ...proxyOptions,
  headers: {
    'User-Agent': getMCPUserAgent(),
    ...(sessionIngressToken && !hasOAuthTokens && {
      Authorization: `Bearer ${sessionIngressToken}`,
    }),
    ...combinedHeaders,
  },
},
```

| Header | 来源 | 条件 |
|--------|------|------|
| `User-Agent` | `getMCPUserAgent()` | 始终传递 |
| `Authorization` | `Bearer ${sessionIngressToken}` | 仅当存在 session ingress token 且无 OAuth token 时 |
| `combinedHeaders` | 静态 headers + headersHelper 动态 headers | 始终传递 |

### 5. WebSocket Transport：WS Headers

WebSocket Transport 的 headers 配置在 [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L744) 第 744-750 行：

```typescript
// ../../claude-code-source/src/services/mcp/client.ts
const wsHeaders = {
  'User-Agent': getMCPUserAgent(),
  ...(sessionIngressToken && {
    Authorization: `Bearer ${sessionIngressToken}`,
  }),
  ...combinedHeaders,
}
```

WebSocket 连接时传递的 headers 与 HTTP 类似，额外使用 `protocols: ['mcp']` 子协议标识。

### 6. claude.ai Proxy Transport：会话 ID

claude.ai Proxy 是唯一传递会话 ID 的 transport 类型。相关代码在 [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L888) 第 888-898 行：

```typescript
// ../../claude-code-source/src/services/mcp/client.ts
const transportOptions: StreamableHTTPClientTransportOptions = {
  fetch: wrapFetchWithTimeout(fetchWithAuth),
  requestInit: {
    ...proxyOptions,
    headers: {
      'User-Agent': getMCPUserAgent(),
      'X-Mcp-Client-Session-Id': getSessionId(),
    },
  },
}
```

`X-Mcp-Client-Session-Id` 的值来自 [`getSessionId()`](../../claude-code-source/src/bootstrap/state.ts#L431)，返回 Claude Code 当前会话的 UUID。

> **仅限 claude.ai proxy**：普通第三方 MCP Server（SSE/HTTP/WS）**不会收到**此 header。

## 五、 User-Agent 详解

### 1. `getMCPUserAgent()` 函数

`getMCPUserAgent()` 函数在 [`http.ts`](../../claude-code-source/src/utils/http.ts#L37) 第 37-50 行中声明：

```typescript
// ../../claude-code-source/src/utils/http.ts
export function getMCPUserAgent(): string {
  const parts: string[] = []
  if (process.env.CLAUDE_CODE_ENTRYPOINT) {
    parts.push(process.env.CLAUDE_CODE_ENTRYPOINT)
  }
  if (process.env.CLAUDE_AGENT_SDK_VERSION) {
    parts.push(`agent-sdk/${process.env.CLAUDE_AGENT_SDK_VERSION}`)
  }
  if (process.env.CLAUDE_AGENT_SDK_CLIENT_APP) {
    parts.push(`client-app/${process.env.CLAUDE_AGENT_SDK_CLIENT_APP}`)
  }
  const suffix = parts.length > 0 ? ` (${parts.join(', ')})` : ''
  return `claude-code/${MACRO.VERSION}${suffix}`
}
```

### 2. User-Agent 格式

```
claude-code/{version} ({entrypoint}, agent-sdk/{sdkVersion}, client-app/{clientApp})
```

### 3. 各环境变量来源

| 环境变量 | 含义 | 示例值 |
|----------|------|--------|
| `CLAUDE_CODE_ENTRYPOINT` | Claude Code 的入口类型 | `cli`、`sdk-ts`、`sdk-py` |
| `CLAUDE_AGENT_SDK_VERSION` | Agent SDK 版本号 | `0.1.0` |
| `CLAUDE_AGENT_SDK_CLIENT_APP` | SDK 消费者自定义应用标识 | `my-app/1.0.0` |

### 4. User-Agent 示例

| 场景 | User-Agent |
|------|-----------|
| CLI 直接使用 | `claude-code/1.0.35` |
| 通过 TS SDK 调用 | `claude-code/1.0.35 (sdk-ts, agent-sdk/0.1.0)` |
| SDK 消费者自定义 | `claude-code/1.0.35 (sdk-ts, agent-sdk/0.1.0, client-app/my-app/1.0.0)` |

### 5. User-Agent 传递的 Transport

| Transport | 是否传递 User-Agent |
|-----------|-------------------|
| stdio | 否（无 HTTP 层） |
| sse | 是 |
| sse-ide | 是 |
| ws | 是 |
| ws-ide | 是 |
| http | 是 |
| claudeai-proxy | 是 |

## 六、 自定义 Headers 机制

### 1. 静态 Headers

SSE / HTTP / WebSocket 类型的 MCP Server 配置支持 `headers` 字段。Schema 定义在 [`types.ts`](../../claude-code-source/src/services/mcp/types.ts#L58) 第 58-66 行：

```typescript
// ../../claude-code-source/src/services/mcp/types.ts
export const McpSSEServerConfigSchema = lazySchema(() =>
  z.object({
    type: z.literal('sse'),
    url: z.string(),
    headers: z.record(z.string(), z.string()).optional(),
    headersHelper: z.string().optional(),
    oauth: McpOAuthConfigSchema().optional(),
  }),
)
```

用户在 `.mcp.json` 中配置的静态 headers 会直接传递给 MCP Server。

### 2. 动态 Headers（headersHelper）

当配置了 `headersHelper` 脚本时，Claude Code 会执行该脚本获取动态 headers。相关代码在 [`headersHelper.ts`](../../claude-code-source/src/services/mcp/headersHelper.ts#L32) 第 32-117 行：

```typescript
// ../../claude-code-source/src/services/mcp/headersHelper.ts
const execResult = await execFileNoThrowWithCwd(config.headersHelper, [], {
  shell: true,
  timeout: 10000,
  env: {
    ...process.env,
    CLAUDE_CODE_MCP_SERVER_NAME: serverName,
    CLAUDE_CODE_MCP_SERVER_URL: config.url,
  },
})
```

headersHelper 脚本执行时可以获得以下环境变量：

| 环境变量 | 值 |
|----------|-----|
| `CLAUDE_CODE_MCP_SERVER_NAME` | MCP Server 的配置名称 |
| `CLAUDE_CODE_MCP_SERVER_URL` | MCP Server 的 URL |

脚本需输出 JSON 格式的 headers 对象（如 `{"X-Custom-Auth": "token123"}`），动态 headers 会覆盖同名的静态 headers。

### 3. Headers 合并逻辑

Headers 合并逻辑在 [`headersHelper.ts`](../../claude-code-source/src/services/mcp/headersHelper.ts#L125) 第 125-138 行：

```typescript
// ../../claude-code-source/src/services/mcp/headersHelper.ts
export async function getMcpServerHeaders(
  serverName: string,
  config: McpSSEServerConfig | McpHTTPServerConfig | McpWebSocketServerConfig,
): Promise<Record<string, string>> {
  const staticHeaders = config.headers || {}
  const dynamicHeaders =
    (await getMcpHeadersFromHelper(serverName, config)) || {}

  // Dynamic headers override static headers if both are present
  return {
    ...staticHeaders,
    ...dynamicHeaders,
  }
}
```

合并优先级（后者覆盖前者）：`静态 headers` < `动态 headersHelper 输出`。

## 七、 OAuth 认证信息

### 1. OAuth Client Metadata

当 MCP Server 需要 OAuth 认证时，Claude Code 会进行动态客户端注册（DCR），`client_name` 格式为 `Claude Code ({serverName})`。相关代码在 [`auth.ts`](../../claude-code-source/src/services/mcp/auth.ts#L1417) 第 1417-1436 行：

```typescript
// ../../claude-code-source/src/services/mcp/auth.ts
get clientMetadata(): OAuthClientMetadata {
  const metadata: OAuthClientMetadata = {
    client_name: `Claude Code (${this.serverName})`,
    redirect_uris: [this.redirectUri],
    grant_types: ['authorization_code', 'refresh_token'],
    response_types: ['code'],
    token_endpoint_auth_method: 'none',
  }
  // ...
  return metadata
}
```

| 字段 | 值 | 说明 |
|------|-----|------|
| `client_name` | `Claude Code ({serverName})` | 包含 MCP Server 的配置名（如 `Claude Code (slack)`） |
| `redirect_uris` | `[redirectUri]` | OAuth 回调地址 |
| `grant_types` | `['authorization_code', 'refresh_token']` | 支持的授权类型 |
| `token_endpoint_auth_method` | `'none'` | 公共客户端，不使用密钥认证 |

### 2. OAuth Token 传递

获取到 OAuth token 后，通过 `Authorization: Bearer {access_token}` header 传递给 MCP Server，适用于 SSE 和 HTTP Transport。

### 3. CIMD（Client ID Metadata Document）

当 MCP OAuth 服务器支持 `client_id_metadata_document_supported: true` 时，Claude Code 使用预定义的 URL 作为 client_id。相关代码在 [`auth.ts`](../../claude-code-source/src/services/mcp/auth.ts#L1445) 第 1445-1449 行：

```typescript
// ../../claude-code-source/src/services/mcp/auth.ts
get clientMetadataUrl(): string | undefined {
  const override = process.env.MCP_OAUTH_CLIENT_METADATA_URL
  if (override) {
    return override
  }
  // 默认: 'https://claude.ai/oauth/claude-code-client-metadata'
}
```

## 八、 工具调用时传递的 `_meta`

### 1. `claudecode/toolUseId`

每次调用 MCP 工具时，Claude Code 通过 MCP 协议的 `_meta` 字段传递工具调用 ID。相关代码在 [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L1840) 第 1840-1843 行：

```typescript
// ../../claude-code-source/src/services/mcp/client.ts
const toolUseId = extractToolUseId(parentMessage)
const meta = toolUseId
  ? { 'claudecode/toolUseId': toolUseId }
  : {}
```

这个 `_meta` 会附加到 `tools/call` 请求中，MCP Server 可以通过它关联具体的工具调用上下文。**所有 Transport 类型**都会传递此信息。

## 九、 Session Ingress JWT Token

### 1. 远程场景的认证

在 Claude Code Remote（CCR）远程场景中，如果存在 session ingress JWT token，会作为 `Authorization: Bearer` header 传递。Token 获取在 [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L617) 第 617 行：

```typescript
// ../../claude-code-source/src/services/mcp/client.ts
const sessionIngressToken = getSessionIngressAuthToken()
```

| Transport | 是否传递 Session Ingress Token |
|-----------|------------------------------|
| ws | 是（第 746-748 行） |
| http | 是（第 833-836 行，且无 OAuth token 时） |
| sse | 否（使用 OAuth authProvider） |
| stdio | 否 |
| claudeai-proxy | 否（使用 claude.ai OAuth token） |

## 十、 各 Transport 传递内容汇总

### 1. 完整对照表

| 传递内容 | stdio | sse | http | ws | claudeai-proxy |
|----------|:-----:|:---:|:----:|:--:|:--------------:|
| **MCP `initialize` 握手** | | | | | |
| `clientInfo`（name/title/version/description/websiteUrl） | ✅ | ✅ | ✅ | ✅ | ✅ |
| `capabilities`（roots/elicitation） | ✅ | ✅ | ✅ | ✅ | ✅ |
| **HTTP Headers** | | | | | |
| `User-Agent` | ❌ | ✅ | ✅ | ✅ | ✅ |
| `Authorization: Bearer`（OAuth） | ❌ | ✅ | ✅ | ❌ | ❌ |
| `Authorization: Bearer`（Session Ingress） | ❌ | ❌ | ✅ | ✅ | ❌ |
| `X-Mcp-Client-Session-Id` | ❌ | ❌ | ❌ | ❌ | ✅ |
| 静态 `headers`（用户配置） | ❌ | ✅ | ✅ | ✅ | ❌ |
| 动态 `headersHelper` 输出 | ❌ | ✅ | ✅ | ✅ | ❌ |
| **子进程** | | | | | |
| `command` + `args` | ✅ | ❌ | ❌ | ❌ | ❌ |
| `env`（subprocessEnv + serverRef.env） | ✅ | ❌ | ❌ | ❌ | ❌ |
| **OAuth** | | | | | |
| DCR `client_name` = `Claude Code ({name})` | ❌ | ✅ | ✅ | ❌ | ❌ |
| **工具调用** | | | | | |
| `_meta.claudecode/toolUseId` | ✅ | ✅ | ✅ | ✅ | ✅ |
| **协议请求** | | | | | |
| `roots/list` 响应含当前工作目录 | ✅ | ✅ | ✅ | ✅ | ✅ |

## 十一、 MCP Server 能否区分"是哪个 Host 连接了它"

### 1. 能获取到的信息

MCP Server 在连接建立后可以获取到以下身份信息：

| 信息 | 获取方式 | 能区分什么 |
|------|---------|-----------|
| `clientInfo.name` = `claude-code` | `initialize` 握手 | 知道连接方是 Claude Code |
| `clientInfo.version` | `initialize` 握手 | 知道 Claude Code 版本 |
| `User-Agent` 中的 `entrypoint` | HTTP header | 区分入口类型（cli/sdk-ts/sdk-py） |
| `User-Agent` 中的 `client-app` | HTTP header | 区分 SDK 消费者自定义应用（需消费者设置 `CLAUDE_AGENT_SDK_CLIENT_APP`） |
| `X-Mcp-Client-Session-Id` | HTTP header | 区分具体会话（**仅 claude.ai proxy**） |
| 当前工作目录 | `roots/list` 响应 | 间接反映 host 运行位置 |

### 2. 无法区分的情况

在**通用场景**下，MCP Server **无法**区分"是哪个 Claude Code 实例/host"连接了它：

1. **stdio Transport**：子进程只获得 `process.env` 副本和用户配置的 `serverRef.env`，**不包含**任何实例/会话标识。
2. **普通 SSE/HTTP/WS**：只有 `User-Agent`，能区分入口类型，但没有唯一实例 ID。
3. **`clientInfo` 是固定的**：所有 Claude Code 实例发送的 `clientInfo` 完全相同（除 version 外）。

### 3. 让 MCP Server 区分不同 Host 的方法

如果需要让 MCP Server 区分不同的 host/实例，可以通过以下方式注入自定义标识：

#### 3.1 方法一：stdio — 自定义环境变量

在 `.mcp.json` 配置中添加自定义环境变量：

```json
{
  "mcpServers": {
    "my-server": {
      "command": "my-mcp-server",
      "env": {
        "MY_HOST_ID": "host-001"
      }
    }
  }
}
```

MCP Server 子进程即可通过 `process.env.MY_HOST_ID` 读取到标识。

#### 3.2 方法二：HTTP/SSE — 自定义 Headers

在 `.mcp.json` 配置中添加静态 headers：

```json
{
  "mcpServers": {
    "my-server": {
      "type": "http",
      "url": "https://my-mcp-server.example.com",
      "headers": {
        "X-Host-Id": "host-001"
      }
    }
  }
}
```

#### 3.3 方法三：HTTP/SSE — headersHelper 动态 Headers

配置 `headersHelper` 脚本动态生成标识：

```json
{
  "mcpServers": {
    "my-server": {
      "type": "http",
      "url": "https://my-mcp-server.example.com",
      "headersHelper": "/path/to/headers-helper.sh"
    }
  }
}
```

脚本可读取 `CLAUDE_CODE_MCP_SERVER_NAME` 和 `CLAUDE_CODE_MCP_SERVER_URL` 环境变量，输出包含自定义标识的 JSON headers。

#### 3.4 方法四：SDK 集成 — 设置 `CLAUDE_AGENT_SDK_CLIENT_APP`

通过 Agent SDK 集成 Claude Code 时，设置环境变量：

```bash
export CLAUDE_AGENT_SDK_CLIENT_APP="my-app/1.0.0"
```

该值会出现在 `User-Agent` 的 `client-app/{xxx}` 段中，MCP Server 可从 `User-Agent` header 解析获取。

## 十二、 相关源码文件索引

| 文件 | 说明 |
|------|------|
| [`client.ts`](../../claude-code-source/src/services/mcp/client.ts) | MCP 客户端核心：Transport 创建、Client 初始化、工具调用 |
| [`types.ts`](../../claude-code-source/src/services/mcp/types.ts) | Transport 类型定义、Server 配置 Schema |
| [`headersHelper.ts`](../../claude-code-source/src/services/mcp/headersHelper.ts) | 动态/静态 headers 获取与合并 |
| [`auth.ts`](../../claude-code-source/src/services/mcp/auth.ts) | OAuth 认证：`ClaudeAuthProvider` 实现、DCR client_metadata |
| [`http.ts`](../../claude-code-source/src/utils/http.ts) | `getMCPUserAgent()` 函数 |
| [`subprocessEnv.ts`](../../claude-code-source/src/utils/subprocessEnv.ts) | stdio 子进程环境变量处理 |
| [`product.ts`](../../claude-code-source/src/constants/product.ts) | `PRODUCT_URL` 常量 |
| [`state.ts`](../../claude-code-source/src/bootstrap/state.ts) | `getSessionId()` 会话 ID 获取 |

---
*本文档由 markdowncli 技能辅助生成*

<!-- more -->

## 一、 概述

本文档梳理 Claude Code 启动后 MCP（Model Context Protocol）服务连接的完整流程。从配置加载、Transport 创建、Client 初始化握手，到工具/命令/资源的发现与注册，以及断线重连机制，覆盖 MCP 连接生命周期的各个阶段。

## 二、 整体架构

### 1. 分层架构

```
REPL / main.tsx (入口)
  └─> MCPConnectionManager (React Context Provider)
       └─> useManageMCPConnections (React Hook, 生命周期管理)
            ├─> Phase 1: getClaudeCodeMcpConfigs() → getMcpToolsCommandsAndResources()
            │    └─> connectToServer() (单服务器连接, memoized)
            │         ├─> Transport 创建 (stdio/sse/http/ws/sdk/claudeai-proxy)
            │         ├─> Client 创建 + connect()
            │         └─> fetchToolsForClient / fetchCommandsForClient / fetchResourcesForClient
            └─> Phase 2: fetchClaudeAIMcpConfigsIfEligible() → getMcpToolsCommandsAndResources()
```

### 2. 核心模块

| 模块 | 文件路径 | 职责 |
|------|---------|------|
| `MCPConnectionManager` | [`MCPConnectionManager.tsx#L38`](../../claude-code-source/src/services/mcp/MCPConnectionManager.tsx#L38) | React Context Provider，暴露 reconnect/toggle 方法 |
| `useManageMCPConnections` | [`useManageMCPConnections.ts#L143`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L143) | 核心 Hook，管理连接生命周期、两阶段加载、重连 |
| `connectToServer` | [`client.ts#L595`](../../claude-code-source/src/services/mcp/client.ts#L595) | 单服务器连接逻辑（Transport + Client + 握手） |
| `config` | [`config.ts#L1071`](../../claude-code-source/src/services/mcp/config.ts#L1071) | 配置加载与合并 |
| `types` | [`types.ts`](../../claude-code-source/src/services/mcp/types.ts) | 类型定义 |

## 三、 连接入口

### 1. 交互模式（REPL）

在 [`REPL.tsx#L4564`](../../claude-code-source/src/screens/REPL.tsx#L4564) 中，`MCPConnectionManager` 作为 React Context Provider 包裹整个 REPL 界面：

```tsx
<MCPConnectionManager
  key={remountKey}
  dynamicMcpConfig={dynamicMcpConfig}
  isStrictMcpConfig={strictMcpConfig}
>
```

### 2. 非交互模式（-p / SDK）

在 [`main.tsx#L1788`](../../claude-code-source/src/main.tsx#L1788) 中，直接调用 `prefetchAllMcpResources()`，它内部调用 `getMcpToolsCommandsAndResources()` 批量连接所有服务器。

### 3. CLI 模式

在 [`util.tsx#L77`](../../claude-code-source/src/cli/handlers/util.tsx#L77) 中，同样使用 `MCPConnectionManager` 包裹子组件。

## 四、 配置加载

### 1. 配置来源（按优先级从低到高）

| 序号 | 来源 | scope 值 | 说明 |
|------|------|----------|------|
| 1 | 插件 MCP 服务器 | `dynamic` | 从已安装的插件中提取 |
| 2 | 用户级配置 | `user` | `~/.claude.json` 中的 `mcpServers` |
| 3 | 项目级配置 | `project` | `.mcp.json` 文件，从 CWD 向上遍历所有父目录 |
| 4 | 本地项目配置 | `local` | `.claude/settings.json` 中的 `mcpServers` |
| 5 | 企业级配置 | `enterprise` | `managed-mcp.json` |
| 6 | claude.ai 远程配置 | `claudeai` | 从 claude.ai API 获取 |
| 7 | 动态配置 | - | `--mcp-config` 命令行参数 |

### 2. 配置加载函数调用链

```
getClaudeCodeMcpConfigs(dynamicMcpConfig, claudeaiPromise)  // config.ts
  ├─> getMcpConfigsByScope('enterprise')   // 企业级
  ├─> getMcpConfigsByScope('user')         // 用户级
  ├─> getMcpConfigsByScope('project')      // 项目级（遍历 .mcp.json）
  ├─> getMcpConfigsByScope('local')        // 本地项目级
  ├─> loadAllPluginsCacheOnly()            // 加载插件 MCP 服务器
  │    └─> getPluginMcpServers(plugin)
  ├─> dedupPluginMcpServers()             // 插件服务器去重
  └─> filterMcpServersByPolicy()          // 企业策略过滤

fetchClaudeAIMcpConfigsIfEligible()        // 异步获取 claude.ai 服务器（claudeai.ts）
  └─> claude.ai /v1/mcp_servers API
```

### 3. 传输类型配置

```typescript
// 支持的传输类型（类型定义见 types.ts）
type Transport = 'stdio' | 'sse' | 'sse-ide' | 'http' | 'ws' | 'ws-ide' | 'sdk' | 'claudeai-proxy'

// 各类型配置结构
McpStdioServerConfig       = { type?: 'stdio', command, args, env }
McpSSEServerConfig         = { type: 'sse', url, headers, headersHelper, oauth }
McpHTTPServerConfig        = { type: 'http', url, headers, headersHelper, oauth }
McpWebSocketServerConfig   = { type: 'ws', url, headers }
McpSdkServerConfig         = { type: 'sdk', name }
McpClaudeAIProxyServerConfig = { type: 'claudeai-proxy', url, id }
McpSSEIDEServerConfig      = { type: 'sse-ide', url, ideName }
McpWebSocketIDEServerConfig = { type: 'ws-ide', url, ideName, authToken? }
```

## 五、 两阶段加载机制

[`useManageMCPConnections`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L143) 通过两个 `useEffect` 实现两阶段加载：

### 1. 阶段一：初始化服务器为 pending 状态

第一个 `useEffect` 读取配置并将新服务器设为 `pending`/`disabled` 状态，同时清理过期的插件服务器：

```typescript
useEffect(() => {
  async function initializeServersAsPending() {
    const { servers: existingConfigs, errors: mcpErrors } =
      isStrictMcpConfig
        ? { servers: {}, errors: [] }
        : await getClaudeCodeMcpConfigs(dynamicMcpConfig)

    // 将新服务器设为 pending/disabled
    // 清理过期的插件服务器
    // ...
  }
  void initializeServersAsPending()
}, [sessionId, _pluginReconnectKey, ...])
```

### 2. 阶段二：连接服务器

第二个 `useEffect` 执行实际连接，分两个子阶段：

- **Phase 1**：加载 Claude Code 本地配置，立即开始连接（不等待 claude.ai）
- **Phase 2**：等待 claude.ai 远程配置获取完成后，连接 claude.ai 服务器

```typescript
useEffect(() => {
  async function loadAndConnectMcpConfigs() {
    // 启动 claude.ai 配置获取（异步，不阻塞）
    const claudeaiPromise = fetchClaudeAIMcpConfigsIfEligible()

    // Phase 1: 加载 Claude Code 配置并连接
    const { servers: claudeCodeConfigs } = await getClaudeCodeMcpConfigs(
      dynamicMcpConfig, claudeaiPromise
    )
    getMcpToolsCommandsAndResources(onConnectionAttempt, enabledConfigs)

    // Phase 2: 等待 claude.ai 配置并连接
    const claudeaiConfigs = filterMcpServersByPolicy(await claudeaiPromise).allowed
    const { servers: dedupedClaudeAi } = dedupClaudeAiMcpServers(claudeaiConfigs, configs)
    getMcpToolsCommandsAndResources(onConnectionAttempt, enabledClaudeaiConfigs)
  }
  void loadAndConnectMcpConfigs()
}, [_authVersion, sessionId, _pluginReconnectKey, ...])
```

## 六、 单服务器连接流程

### 1. [`connectToServer`](../../claude-code-source/src/services/mcp/client.ts#L595) 函数

[`connectToServer`](../../claude-code-source/src/services/mcp/client.ts#L595) 使用 `lodash.memoize` 缓存，缓存键格式为 `${name}-${jsonStringify(serverRef)}`。

#### 1.1 超时配置

- 连接超时：`MCP_TIMEOUT` 环境变量，默认 **30 秒**
- 请求超时：固定 **60 秒**（`MCP_REQUEST_TIMEOUT_MS`）

#### 1.2 Transport 创建

根据 `serverRef.type` 创建不同类型的 Transport：

| 类型 | Transport 类 | 关键配置 |
|------|-------------|---------|
| `sse` | `SSEClientTransport` | `ClaudeAuthProvider` + 超时包装 fetch + StepUp 检测 + 合并 headers |
| `sse-ide` | `SSEClientTransport` | 无认证，支持代理 |
| `ws` | `WebSocketTransport` | 合并 headers + session ingress token + 代理/TLS（[`client.ts#L734`](../../claude-code-source/src/services/mcp/client.ts#L734)） |
| `ws-ide` | `WebSocketTransport` | IDE auth token + 代理/TLS（[`client.ts#L783`](../../claude-code-source/src/services/mcp/client.ts#L783)） |
| `http` | `StreamableHTTPClientTransport` | `ClaudeAuthProvider` + 超时包装 fetch + 代理 + 合并 headers |
| `claudeai-proxy` | `StreamableHTTPClientTransport` | claude.ai OAuth token + 代理 |
| `stdio` / 无 type | `StdioClientTransport` | command + args + env + stderr pipe |
| Chrome/Computer Use | `InProcessTransport` | 进程内 MCP 服务器，免子进程（[`InProcessTransport.ts#L1`](../../claude-code-source/src/services/mcp/InProcessTransport.ts#L1)） |

#### 1.3 SSE Transport 详细配置

```typescript
const transportOptions: SSEClientTransportOptions = {
  authProvider: new ClaudeAuthProvider(name, serverRef),
  fetch: wrapFetchWithTimeout(
    wrapFetchWithStepUpDetection(createFetchWithInit(), authProvider),
  ),
  requestInit: {
    headers: { 'User-Agent': getMCPUserAgent(), ...combinedHeaders },
  },
  // EventSource 使用不带超时的 fetch（长连接）
  eventSourceInit: {
    fetch: async (url, init) => {
      const authHeaders = {}
      const tokens = await authProvider.tokens()
      if (tokens) authHeaders.Authorization = `Bearer ${tokens.access_token}`
      return fetch(url, { ...proxyOptions, headers: { ...authHeaders, ...combinedHeaders } })
    },
  },
}
```

#### 1.4 Stdio Transport 详细配置

```typescript
transport = new StdioClientTransport({
  command: process.env.CLAUDE_CODE_SHELL_PREFIX || serverRef.command,
  args: finalArgs,
  env: { ...subprocessEnv(), ...serverRef.env },
  stderr: 'pipe',  // 防止 MCP 服务器的错误输出打印到 UI
})
```

### 2. Client 创建与连接

#### 2.1 创建 Client

```typescript
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
      roots: {},         // 声明 roots 能力
      elicitation: {},   // 声明 elicitation 能力
    },
  },
)
```

#### 2.2 注册 ListRoots 处理器

```typescript
client.setRequestHandler(ListRootsRequestSchema, async () => ({
  roots: [{ uri: `file://${getOriginalCwd()}` }],
}))
```

#### 2.3 带超时的连接

```typescript
const connectPromise = client.connect(transport)
const timeoutPromise = new Promise((_, reject) => {
  setTimeout(() => {
    transport.close()
    reject(new TelemetrySafeError('MCP server connection timed out'))
  }, getConnectionTimeoutMs())
})
await Promise.race([connectPromise, timeoutPromise])
```

### 3. 连接后握手

连接成功后，获取服务器的 capabilities、版本和指令：

```typescript
const capabilities = client.getServerCapabilities()
const serverVersion = client.getServerVersion()
const instructions = client.getInstructions()
```

### 4. 错误处理

- **SSE/HTTP 连接失败**：检查 `UnauthorizedError`，返回 `needs-auth` 状态
- **claudeai-proxy 连接失败**：检查 401 状态码，返回 `needs-auth` 状态
- **所有连接失败**：关闭 transport，抛出异常
- **连接超时**：关闭 transport 和 in-process 服务器，抛出 `TelemetrySafeError`

## 七、 工具/命令/资源的发现

### 1. 批量获取入口

`getMcpToolsCommandsAndResources()`（[`client.ts#L2226`](../../claude-code-source/src/services/mcp/client.ts#L2226)）是批量连接的入口，内部逻辑：

1. 将配置分为 disabled 和 active
2. 将 active 分为 local（stdio/sdk）和 remote（sse/http/ws 等）
3. 使用 `pMap` 控制并发：local 服务器并发度 4，remote 服务器并发度 10
4. 对每个服务器调用 `connectToServer()` 然后并行获取 tools/commands/resources

### 2. [`fetchToolsForClient`](../../claude-code-source/src/services/mcp/client.ts#L1743)

```typescript
export const fetchToolsForClient = memoizeWithLRU(
  async (client: MCPServerConnection): Promise<Tool[]> => {
    if (!client.capabilities?.tools) return []

    const result = await client.client.request(
      { method: 'tools/list' }, ListToolsResultSchema,
    )

    return result.tools.map(tool => ({
      ...MCPTool,  // MCPTool 定义见 src/tools/MCPTool/MCPTool.ts#L27
      name: buildMcpToolName(client.name, tool.name),  // mcp__<server>__<tool>
      mcpInfo: { serverName: client.name, toolName: tool.name },
      // ... 其他属性
    }))
  },
)
```

### 3. [`fetchCommandsForClient`](../../claude-code-source/src/services/mcp/client.ts#L2033)

```typescript
export const fetchCommandsForClient = memoizeWithLRU(
  async (client: MCPServerConnection): Promise<Command[]> => {
    if (!client.capabilities?.prompts) return []

    const result = await client.client.request(
      { method: 'prompts/list' }, ListPromptsResultSchema,
    )

    return result.prompts.map(prompt => ({
      type: 'prompt',
      name: 'mcp__' + normalizeNameForMCP(client.name) + '__' + prompt.name,
      // ...
    }))
  },
)
```

### 4. [`fetchResourcesForClient`](../../claude-code-source/src/services/mcp/client.ts#L2000)

```typescript
export const fetchResourcesForClient = memoizeWithLRU(
  async (client: MCPServerConnection): Promise<ServerResource[]> => {
    if (!client.capabilities?.resources) return []

    const result = await client.client.request(
      { method: 'resources/list' }, ListResourcesResultSchema,
    )

    return result.resources.map(resource => ({
      ...resource,
      server: client.name,
    }))
  },
)
```

### 5. 并行获取

每个服务器连接成功后，并行获取 tools、commands、skills、resources：

```typescript
const [tools, mcpCommands, mcpSkills, resources] = await Promise.all([
  fetchToolsForClient(client),
  fetchCommandsForClient(client),
  feature('MCP_SKILLS') && supportsResources
    ? fetchMcpSkillsForClient(client)
    : Promise.resolve([]),
  supportsResources
    ? fetchResourcesForClient(client)
    : Promise.resolve([]),
])
```

## 八、 状态管理与批量更新

### 1. 服务器连接状态

| 状态 | 说明 |
|------|------|
| `pending` | 等待连接 |
| `connected` | 已连接 |
| `failed` | 连接失败 |
| `disabled` | 已禁用 |
| `needs-auth` | 需要 OAuth 认证 |

### 2. 批量更新机制

`useManageMCPConnections`（[`useManageMCPConnections.ts#L207`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L207)）使用 `setTimeout`（16ms 窗口）批量合并 MCP 状态更新：

```typescript
const MCP_BATCH_FLUSH_MS = 16  // 约 1 帧

const updateServer = useCallback((update: PendingUpdate) => {
  pendingUpdatesRef.current.push(update)
  if (flushTimerRef.current === null) {
    flushTimerRef.current = setTimeout(flushPendingUpdates, MCP_BATCH_FLUSH_MS)
  }
}, [flushPendingUpdates])
```

`flushPendingUpdates` 在单次 `setAppState` 中合并所有更新，包括 clients、tools、commands、resources。

## 九、 通知处理器注册

连接成功后，[`onConnectionAttempt`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L333) 回调注册多种通知处理器：

### 1. Elicitation 处理器

覆盖连接时的默认 handler（返回 cancel），注册真正的 UI 交互 handler（[`elicitationHandler.ts#L68`](../../claude-code-source/src/services/mcp/elicitationHandler.ts#L68)）：

```typescript
registerElicitationHandler(client.client, client.name, setAppState)
```

### 2. list_changed 通知处理器

当服务器声明 `listChanged` 能力时，注册对应的刷新 handler：

- **tools/list_changed**：清除工具缓存，重新获取工具列表
- **prompts/list_changed**：清除命令缓存，重新获取 prompts 和 skills
- **resources/list_changed**：清除资源缓存，重新获取资源和 skills

### 3. Channel 通知处理器

当启用 KAIROS_CHANNELS 特性时，根据 `gateChannelServer`（[`channelNotification.ts#L191`](../../claude-code-source/src/services/mcp/channelNotification.ts#L191)）的结果决定是否注册 channel 消息处理器：

- `register`：注册 `ChannelMessageNotificationSchema` 和 `ChannelPermissionNotificationSchema` 处理器
- `skip`：移除已有的处理器，可选显示 toast 提示

## 十、 断线重连机制

### 1. onclose 触发重连（[`useManageMCPConnections.ts#L333`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L333)）

当已连接的服务器断开时，`client.onclose` 回调触发重连逻辑：

```typescript
client.onclose = () => {
  // 清除缓存（src/services/mcp/client.ts）
  clearServerCache(client.name, client.config)

  // 检查是否被禁用（src/services/mcp/config.ts）
  if (isMcpServerDisabled(client.name)) return

  // 仅对远程 transport（非 stdio/sdk）进行自动重连
  if (configType !== 'stdio' && configType !== 'sdk') {
    reconnectWithBackoff()
  } else {
    updateServer({ ...client, type: 'failed' })
  }
}
```

### 2. 指数退避重连（[`useManageMCPConnections.ts#L88`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L88)）

```
MAX_RECONNECT_ATTEMPTS = 5
INITIAL_BACKOFF_MS = 1000
MAX_BACKOFF_MS = 30000

重连间隔 = min(INITIAL_BACKOFF_MS × 2^(attempt-1), MAX_BACKOFF_MS)
即: 1s → 2s → 4s → 8s → 16s
```

每次重连尝试：
1. 更新状态为 `pending`，附带 `reconnectAttempt` 和 `maxReconnectAttempts`
2. 调用 [`reconnectMcpServerImpl()`](../../claude-code-source/src/services/mcp/client.ts#L2137) 尝试重连
3. 成功则更新状态为 `connected`，失败则继续退避
4. 达到最大重试次数后标记为 `failed`

### 3. 重连取消

- 手动重连（`reconnectMcpServer`）时，取消已有的自动重连 timer
- 禁用服务器（`toggleMcpServer`）时，取消已有的自动重连 timer
- 配置变更时，清理过期的重连 timer

## 十一、 手动操作

### 1. [`reconnectMcpServer`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L1099)

通过 [`useMcpReconnect()`](../../claude-code-source/src/services/mcp/MCPConnectionManager.tsx#L17) Hook 暴露，取消已有自动重连，调用 [`reconnectMcpServerImpl()`](../../claude-code-source/src/services/mcp/client.ts#L2137) 并更新状态。

### 2. [`toggleMcpServer`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L1074)

通过 [`useMcpToggleEnabled()`](../../claude-code-source/src/services/mcp/MCPConnectionManager.tsx#L24) Hook 暴露：

- **禁用**：持久化到磁盘 → 断开连接（[`clearServerCache`](../../claude-code-source/src/services/mcp/client.ts#L1648)） → 更新状态为 `disabled`
- **启用**：持久化到磁盘 → 标记为 `pending` → 重连

## 十二、 连接错误检测与降级

### 1. 连接错误桥接（[`client.ts#L1228`](../../claude-code-source/src/services/mcp/client.ts#L1228)）

SDK 的 transport 在连接失败时调用 `onerror` 但不调用 `onclose`，CC 通过桥接机制解决：

```typescript
let consecutiveConnectionErrors = 0
const MAX_ERRORS_BEFORE_RECONNECT = 3

client.onerror = (error: Error) => {
  consecutiveConnectionErrors++
  if (consecutiveConnectionErrors >= MAX_ERRORS_BEFORE_RECONNECT) {
    // 调用 client.close() 触发 onclose → 重连
    closeTransportAndRejectPending('consecutive errors')
  }
}
```

### 2. 终端错误识别

以下错误类型被认为是终端错误，直接触发重连：

- `ECONNRESET` / `ETIMEDOUT` / `EPIPE` / `EHOSTUNREACH` / `ECONNREFUSED`
- `Body Timeout Error` / `terminated`
- `SSE stream disconnected` / `Failed to reconnect SSE stream`

### 3. 认证失败降级

当远程服务器返回 401 时，状态降级为 `needs-auth`，并创建 [`McpAuthTool`](../../claude-code-source/src/tools/McpAuthTool/McpAuthTool.ts#L49) 供用户触发 OAuth 认证流程。同时缓存认证失败状态（15 分钟 TTL），避免频繁重试。

## 十三、 清理机制

### 1. 组件卸载清理

`useManageMCPConnections`（[`useManageMCPConnections.ts#L143`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L143)）在卸载时：
- 清除所有重连 timer
- 刷新所有待处理的批量更新

### 2. 过期服务器清理

配置变更时，清理不再出现在配置中的插件服务器：
- 取消已有的重连 timer
- 对已连接的服务器清除 `onclose` 回调并关闭连接
- 清除 memoize 缓存

---
*本文档由 markdowncli 技能辅助生成*

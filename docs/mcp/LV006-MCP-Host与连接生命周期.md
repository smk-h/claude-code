<!-- more -->

## 一、 概述

本文档梳理 Claude Code 中 **MCP Host**（宿主侧）的实现，重点分析连接生命周期的管理逻辑：包括 React Context Provider 的暴露方式、核心 Hook 的两阶段加载机制、批量状态更新、断线自动重连、手动重连/启停操作以及组件卸载清理。MCP Host 不直接负责底层 Transport 创建与协议握手，而是协调多个 MCP Client 的连接节奏、把工具/命令/资源同步到 React `AppState`，并对外暴露操作接口。

底层连接与传输层实现详见 [LV007-MCP-Client与传输层](LV007-MCP-Client与传输层.md)；工具/命令/资源的发现与具体调用流程详见 [LV008-MCP-工具发现与调用](LV008-MCP-工具发现与调用.md)。

## 二、 整体架构

### 1. 分层结构

```
REPL / main.tsx (入口)
  └─> MCPConnectionManager (React Context Provider)
       └─> useManageMCPConnections (核心 Hook)
            ├─> Phase 1: getClaudeCodeMcpConfigs() → getMcpToolsCommandsAndResources()
            │    └─> connectToServer() → fetchToolsForClient / fetchCommandsForClient / fetchResourcesForClient
            └─> Phase 2: fetchClaudeAIMcpConfigsIfEligible() → getMcpToolsCommandsAndResources()
```

### 2. 核心模块

| 模块 | 文件路径 | 职责 |
|------|---------|------|
| `MCPConnectionManager` | [`MCPConnectionManager.tsx`](../../claude-code-source/src/services/mcp/MCPConnectionManager.tsx#L38) | React Context Provider，对外暴露 `reconnectMcpServer` / `toggleMcpServer` |
| `useManageMCPConnections` | [`useManageMCPConnections.ts`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L143) | 核心 Hook，管理连接生命周期、两阶段加载、批量更新、断线重连 |
| `getMcpToolsCommandsAndResources` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L2226) | 批量连接入口，按 local/remote 分组并发控制 |
| `connectToServer` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L595) | 单服务器连接（Transport + Client + 握手），memoize 缓存 |
| `reconnectMcpServerImpl` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L2137) | 重连实现：清缓存 → 重新连接 → 重新发现工具 |
| `clearServerCache` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L1648) | 清理 connectToServer 与 fetch* 系列缓存 |

## 三、 入口与 Context 暴露

### 1. 交互模式（REPL）

在 [`REPL.tsx`](../../claude-code-source/src/screens/REPL.tsx#L4564) 中，`MCPConnectionManager` 作为 React Context Provider 包裹整个 REPL 界面，接收 `dynamicMcpConfig`（来自 `--mcp-config`）与 `isStrictMcpConfig` 两个属性。

### 2. 非交互模式（-p / SDK）

在 [`main.tsx`](../../claude-code-source/src/main.tsx#L1788) 中，直接调用 [`prefetchAllMcpResources()`](../../claude-code-source/src/services/mcp/client.ts#L2408)，它内部聚合所有服务器的连接结果，不走 React 生命周期。

### 3. CLI 子命令模式

在 [`util.tsx`](../../claude-code-source/src/cli/handlers/util.tsx#L77) 中，同样使用 `MCPConnectionManager` 包裹子组件。

### 4. Context 暴露的接口

[`MCPConnectionManager`](../../claude-code-source/src/services/mcp/MCPConnectionManager.tsx#L38) 通过 `MCPConnectionContext` 向下暴露两个方法，分别由两个自定义 Hook 获取：

```typescript
// claude-code-source/src/services/mcp/MCPConnectionManager.tsx
interface MCPConnectionContextValue {
  reconnectMcpServer: (serverName: string) => Promise<{
    client: MCPServerConnection
    tools: Tool[]
    commands: Command[]
    resources?: ServerResource[]
  }>
  toggleMcpServer: (serverName: string) => Promise<void>
}

export function useMcpReconnect() {       // 读取 reconnectMcpServer
  const context = useContext(MCPConnectionContext)
  // ...
}

export function useMcpToggleEnabled() {   // 读取 toggleMcpServer
  const context = useContext(MCPConnectionContext)
  // ...
}
```

`MCPConnectionManager` 自身只是个薄壳，真正的逻辑全部委托给 [`useManageMCPConnections`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L143)：

```typescript
// claude-code-source/src/services/mcp/MCPConnectionManager.tsx
export function MCPConnectionManager(t0) {
  const { children, dynamicMcpConfig, isStrictMcpConfig } = t0
  const { reconnectMcpServer, toggleMcpServer } = useManageMCPConnections(
    dynamicMcpConfig,
    isStrictMcpConfig,
  )
  // ...useMemo 包裹 value，避免子组件无谓重渲染
  return <MCPConnectionContext.Provider value={value}>{children}</MCPConnectionContext.Provider>
}
```

## 四、 useManageMCPConnections 核心结构

[`useManageMCPConnections`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L143) 是整个 MCP 连接管理的中枢，它返回 `{ reconnectMcpServer, toggleMcpServer }`，内部维护以下几个关键引用：

| 引用 | 类型 | 作用 |
|------|------|------|
| `reconnectTimersRef` | `Map<string, NodeJS.Timeout>` | 跟踪每个服务器的自动重连定时器，便于取消 |
| `channelWarnedKindsRef` | `Set<...>` | Channel 被阻断的告警去重（每类只提示一次） |
| `channelPermCallbacksRef` | `ChannelPermissionCallbacks \| null` | Channel 权限回调，存入 AppState 供交互层订阅 |
| `pendingUpdatesRef` | `PendingUpdate[]` | 待刷新的批量更新队列 |
| `flushTimerRef` | `ReturnType<setTimeout> \| null` | 批量刷新定时器句柄 |

## 五、 两阶段加载机制

[`useManageMCPConnections`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L143) 通过三个 `useEffect` 协作完成两阶段加载。依赖项包括 `sessionId`（`/clear` 时变化）、`_pluginReconnectKey`（`/reload-plugins` 时变化）、`_authVersion`（登录/登出时变化）等，从而支持会话切换、插件重载、认证状态变更后的重新连接。

### 1. 阶段零：将新服务器初始化为 pending

第一个 [`useEffect`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L772) 调用 [`getClaudeCodeMcpConfigs(dynamicMcpConfig)`](../../claude-code-source/src/services/mcp/config.ts#L1071) 读取本地配置，然后：

- 通过 [`excludeStalePluginClients`](../../claude-code-source/src/services/mcp/utils.ts#L185) 剔除配置已变更或被移除的插件服务器，对仍在连接中的过期服务器清除 `onclose` 回调并调用 [`clearServerCache()`](../../claude-code-source/src/services/mcp/client.ts#L1648) 释放资源；
- 对未在 `appState.mcp.clients` 中的新服务器，根据 [`isMcpServerDisabled()`](../../claude-code-source/src/services/mcp/config.ts#L1528) 的磁盘状态将其初始化为 `disabled` 或 `pending`。

这一步不发起任何实际连接，只更新 `appState` 让 UI 立即显示“等待中”占位。

### 2. 阶段一：连接 Claude Code 本地配置

第二个 [`useEffect`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L858) 是真正的连接驱动，逻辑如下：

```typescript
// claude-code-source/src/services/mcp/useManageMCPConnections.ts
async function loadAndConnectMcpConfigs() {
  // 启动 claude.ai 远程配置获取（异步，不阻塞阶段一）
  let claudeaiPromise
  if (isStrictMcpConfig || doesEnterpriseMcpConfigExist()) {
    claudeaiPromise = Promise.resolve({})
  } else {
    clearClaudeAIMcpConfigsCache()
    claudeaiPromise = fetchClaudeAIMcpConfigsIfEligible()
  }

  // Phase 1: 加载 Claude Code 配置并立即连接
  const { servers: claudeCodeConfigs } = await getClaudeCodeMcpConfigs(
    dynamicMcpConfig, claudeaiPromise,
  )
  const enabledConfigs = Object.fromEntries(
    Object.entries(configs).filter(([name]) => !isMcpServerDisabled(name)),
  )
  getMcpToolsCommandsAndResources(onConnectionAttempt, enabledConfigs)

  // Phase 2: 等待 claude.ai 远程配置并连接
  let claudeaiConfigs = filterMcpServersByPolicy(await claudeaiPromise).allowed
  const { servers: dedupedClaudeAi } = dedupClaudeAiMcpServers(claudeaiConfigs, configs)
  // ...将 dedup 后的 claude.ai 服务器加入 pending，再次调用
  getMcpToolsCommandsAndResources(onConnectionAttempt, enabledClaudeaiConfigs)
}
```

【**设计要点**】

- 阶段一不等待 claude.ai 网络请求，本地服务器（stdio 等）能立刻连接并暴露工具；
- 阶段二把同一个 `claudeaiPromise` 复用（带缓存），避免二次请求；
- `isStrictMcpConfig`（企业策略锁定）和 `doesEnterpriseMcpConfigExist()` 会跳过 claude.ai 阶段；
- [`dedupClaudeAiMcpServers`](../../claude-code-source/src/services/mcp/config.ts#L281) 通过 URL 签名去重，避免 claude.ai connector 与本地手动配置重复连接同一后端。

## 六、 onConnectionAttempt 回调与通知注册

[`onConnectionAttempt`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L310) 是 [`getMcpToolsCommandsAndResources`](../../claude-code-source/src/services/mcp/client.ts#L2226) 每完成一个服务器连接后回调的入口。它做两件事：

1. 调用 [`updateServer`](#七-批量状态更新) 把 client/tools/commands/resources 入队；
2. 根据 `client.type` 注册各种通知处理器（仅在 `connected` 分支内）。

### 1. Elicitation 处理器覆盖

连接时 [`connectToServer`](../../claude-code-source/src/services/mcp/client.ts#L1191) 注册了一个默认的 Elicitation handler，固定返回 `{ action: 'cancel' }`，用于连接握手到 `onConnectionAttempt` 之间的窗口期。`onConnectionAttempt` 在 [`connected` 分支](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L331) 调用 [`registerElicitationHandler(client.client, client.name, setAppState)`](../../claude-code-source/src/services/mcp/elicitationHandler.ts#L68) 覆盖为真正的 UI 交互 handler（把请求入队 `appState.elicitation.queue`，等待用户响应）。

### 2. list_changed 通知处理器

当服务器在 capabilities 中声明 `listChanged` 时，注册三类刷新 handler：

- **tools/list_changed**：删除 `fetchToolsForClient.cache` 中该服务器的条目，重新获取并更新工具列表；
- **prompts/list_changed**：删除 `fetchCommandsForClient.cache`，重新获取 prompts 和 skills；
- **resources/list_changed**：删除 `fetchResourcesForClient.cache`（同时刷新 skills 与 prompts 缓存），重新获取。

```typescript
// claude-code-source/src/services/mcp/useManageMCPConnections.ts
if (client.capabilities?.tools?.listChanged) {
  client.client.setNotificationHandler(ToolListChangedNotificationSchema, async () => {
    fetchToolsForClient.cache.delete(client.name)
    const newTools = await fetchToolsForClient(client)
    updateServer({ ...client, tools: newTools })
  })
}
```

### 3. Channel 通知处理器

当启用 `KAIROS` / `KAIROS_CHANNELS` 特性时，调用 [`gateChannelServer()`](../../claude-code-source/src/services/mcp/channelNotification.ts#L191) 决定是否注册 Channel 消息处理器：

- `register`：注册 `ChannelMessageNotificationSchema` 与 `ChannelPermissionNotificationSchema` 处理器，消息通过 [`enqueue()`](../../claude-code-source/src/utils/messageQueueManager.ts#L128) 进入用户消息队列；
- `skip`：移除已有处理器，对非 `capability`/`session` 类型的 skip 弹出一次性 toast 告警。

## 七、 批量状态更新

由于多个服务器异步连接完成时间分散，直接每次都触发 `setAppState` 会造成大量重渲染。[`useManageMCPConnections`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L207) 使用 16ms 时间窗的批量合并机制：

```typescript
// claude-code-source/src/services/mcp/useManageMCPConnections.ts
const MCP_BATCH_FLUSH_MS = 16  // 约一帧

const updateServer = useCallback((update: PendingUpdate) => {
  pendingUpdatesRef.current.push(update)
  if (flushTimerRef.current === null) {
    flushTimerRef.current = setTimeout(flushPendingUpdates, MCP_BATCH_FLUSH_MS)
  }
}, [flushPendingUpdates])
```

`flushPendingUpdates` 在单次 `setAppState` 中遍历所有待处理更新，按下述规则合并到 `appState.mcp`：

```typescript
// claude-code-source/src/services/mcp/useManageMCPConnections.ts
const flushPendingUpdates = useCallback(() => {
  setAppState(prevState => {
    let mcp = prevState.mcp
    for (const update of updates) {
      const { tools: rawTools, commands: rawCmds, resources: rawRes, ...client } = update
      // disabled / failed 状态自动清空 tools/commands/resources
      const tools = client.type === 'disabled' || client.type === 'failed'
        ? (rawTools ?? []) : rawTools

      const prefix = getMcpPrefix(client.name)
      const updatedClients = /* 替换或追加同名 client */
      const updatedTools = tools === undefined ? mcp.tools
        : [...reject(mcp.tools, t => t.name?.startsWith(prefix)), ...tools]
      const updatedCommands = commands === undefined ? mcp.commands
        : [...reject(mcp.commands, c => commandBelongsToServer(c, client.name)), ...commands]
      const updatedResources = resources === undefined ? mcp.resources
        : { ...mcp.resources, ...(resources.length > 0 ? { [client.name]: resources } : omit(mcp.resources, client.name)) }

      mcp = { ...mcp, clients: updatedClients, tools: updatedTools, commands: updatedCommands, resources: updatedResources }
    }
    return { ...prevState, mcp }
  })
}, [setAppState])
```

【**设计要点**】

- 以服务器名为前缀（`mcp__<server>__`）做“整组替换”——新工具列表替换该服务器原有的全部工具，避免重复；
- `disabled` / `failed` 状态下即便上层传入了 tools 也会被强制清空，保证状态一致；
- 资源为空数组时从 `mcp.resources` 中删除该键，而不是保留空数组。

## 八、 服务器连接状态机

`MCPServerConnection` 在 [`types.ts`](../../claude-code-source/src/services/mcp/types.ts#L180) 中定义为五种状态的联合类型：

| 状态 | 类型 | 含义 |
|------|------|------|
| `pending` | `PendingMCPServer` | 等待连接，可携带 `reconnectAttempt` / `maxReconnectAttempts` |
| `connected` | `ConnectedMCPServer` | 已连接，持有 `Client`、`capabilities`、`serverInfo`、`instructions`、`cleanup` |
| `failed` | `FailedMCPServer` | 连接失败或重连耗尽，可附带 `error` |
| `disabled` | `DisabledMCPServer` | 用户禁用，持久化在磁盘 |
| `needs-auth` | `NeedsAuthMCPServer` | 远程服务器返回 401，需要 OAuth 认证 |

状态转移主要发生在 `connectToServer` 内部（连接成功/失败/需认证）和 `onConnectionAttempt` + 重连逻辑（`connected → pending → connected/failed`）。

## 九、 断线自动重连

### 1. onclose 触发

[`onConnectionAttempt`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L333) 在 `connected` 分支为 `client.client.onclose` 注册重连入口：

```typescript
// claude-code-source/src/services/mcp/useManageMCPConnections.ts
client.client.onclose = () => {
  const configType = client.config.type ?? 'stdio'

  // 1. 清缓存（fire-and-forget）
  clearServerCache(client.name, client.config).catch(() => {})

  // 2. 检查磁盘是否被禁用（appState 此时已过时）
  if (isMcpServerDisabled(client.name)) return

  // 3. 仅远程 transport 自动重连，stdio/sdk 直接标 failed
  if (configType !== 'stdio' && configType !== 'sdk') {
    const transportType = getTransportDisplayName(configType)
    // 取消已有定时器，启动指数退避重连
    const reconnectWithBackoff = async () => { /* 见 9.2 */ }
    void reconnectWithBackoff()
  } else {
    updateServer({ ...client, type: 'failed' })
  }
}
```

### 2. 指数退避算法

```typescript
// claude-code-source/src/services/mcp/useManageMCPConnections.ts
const MAX_RECONNECT_ATTEMPTS = 5
const INITIAL_BACKOFF_MS = 1000
const MAX_BACKOFF_MS = 30000

const reconnectWithBackoff = async () => {
  for (let attempt = 1; attempt <= MAX_RECONNECT_ATTEMPTS; attempt++) {
    if (isMcpServerDisabled(client.name)) {
      reconnectTimersRef.current.delete(client.name)
      return
    }
    updateServer({
      ...client, type: 'pending',
      reconnectAttempt: attempt, maxReconnectAttempts: MAX_RECONNECT_ATTEMPTS,
    })

    try {
      const result = await reconnectMcpServerImpl(client.name, client.config)
      if (result.client.type === 'connected') {
        reconnectTimersRef.current.delete(client.name)
        onConnectionAttempt(result)   // 重新注册所有 handler
        return
      }
      if (attempt === MAX_RECONNECT_ATTEMPTS) {
        onConnectionAttempt(result)   // 把最终状态（如 needs-auth）写回
        return
      }
    } catch (error) {
      if (attempt === MAX_RECONNECT_ATTEMPTS) {
        updateServer({ ...client, type: 'failed' })
        return
      }
    }

    const backoffMs = Math.min(
      INITIAL_BACKOFF_MS * Math.pow(2, attempt - 1),
      MAX_BACKOFF_MS,
    )
    await new Promise<void>(resolve => {
      const timer = setTimeout(resolve, backoffMs)
      reconnectTimersRef.current.set(client.name, timer)
    })
  }
}
```

【**重连间隔序列**】

```
1s → 2s → 4s → 8s → 16s（封顶 30s，但 5 次内未触及封顶）
```

【**重连取消时机**】

- 手动 [`reconnectMcpServer`](#十-手动操作) 时取消已有定时器；
- 手动 [`toggleMcpServer`](#十-手动操作) 禁用时取消已有定时器；
- 配置变更时（第一个 `useEffect`）清理过期服务器的定时器；
- 重连循环内部每次 `setTimeout` 后将句柄写回 `reconnectTimersRef`，便于任意时刻取消。

## 十、 手动操作

### 1. reconnectMcpServer()

[`reconnectMcpServer`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L1046) 通过 `useMcpReconnect()` Hook 暴露给 UI（如 `/mcp` 菜单中的“重连”按钮）。流程：

1. 通过 `store.getState()` 读取最新的 client 配置（避免闭包过时）；
2. 取消该服务器已有的自动重连定时器；
3. 调用 [`reconnectMcpServerImpl()`](../../claude-code-source/src/services/mcp/client.ts#L2137)；
4. 通过 `onConnectionAttempt(result)` 把结果写回 `appState`。

### 2. toggleMcpServer()

[`toggleMcpServer`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L1074) 通过 `useMcpToggleEnabled()` Hook 暴露，用于启用/禁用服务器：

- **禁用流程**：取消自动重连定时器 → [`setMcpServerEnabled(name, false)`](../../claude-code-source/src/services/mcp/config.ts#L1553) 持久化到磁盘 → 若当前为 `connected`，调用 [`clearServerCache()`](../../claude-code-source/src/services/mcp/client.ts#L1648) 断开 → `updateServer` 置为 `disabled`；
- **启用流程**：[`setMcpServerEnabled(name, true)`](../../claude-code-source/src/services/mcp/config.ts#L1553) 持久化 → `updateServer` 置为 `pending` → 调用 [`reconnectMcpServerImpl()`](../../claude-code-source/src/services/mcp/client.ts#L2137) → `onConnectionAttempt`。

【**为什么先写磁盘再断开**】`onclose` 回调内部会检查 `isMcpServerDisabled()`（读磁盘），如果先断开再写磁盘，`onclose` 可能在磁盘状态更新前触发，从而错误地启动自动重连，与禁用语义冲突。

## 十一、 清理机制

### 1. 组件卸载清理

第三个 [`useEffect`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L1027) 在卸载时执行：

```typescript
// claude-code-source/src/services/mcp/useManageMCPConnections.ts
useEffect(() => {
  const timers = reconnectTimersRef.current
  return () => {
    for (const timer of timers.values()) clearTimeout(timer)
    timers.clear()
    // 刷新未提交的批量更新，避免丢失最后一次状态
    if (flushTimerRef.current !== null) {
      clearTimeout(flushTimerRef.current)
      flushTimerRef.current = null
      flushPendingUpdates()
    }
  }
}, [flushPendingUpdates])
```

### 2. 过期服务器清理

配置变更（第一个 `useEffect`）时，[`excludeStalePluginClients`](../../claude-code-source/src/services/mcp/utils.ts#L185) 返回 `{ stale, ...mcpWithoutStale }`。对每个 stale 服务器：

- 清除其自动重连定时器（防止旧配置的重连触发）；
- 若仍在 `connected` 状态，置空 `onclose` 回调（防止旧配置的 `onclose` 触发重连）并调用 `clearServerCache`。

【**为什么不直接禁用**】配置变更（编辑 `.mcp.json` 或 `/reload-plugins`）不等于用户禁用——服务器只是“不再被需要”，应当静默释放，而不是写入磁盘的 disabled 状态，否则下次启动会被错误地跳过。

## 十二、 关键常量速查

| 常量 | 值 | 来源 |
|------|-----|------|
| `MAX_RECONNECT_ATTEMPTS` | 5 | [`useManageMCPConnections.ts`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L88) |
| `INITIAL_BACKOFF_MS` | 1000 | [`useManageMCPConnections.ts`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L89) |
| `MAX_BACKOFF_MS` | 30000 | [`useManageMCPConnections.ts`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L90) |
| `MCP_BATCH_FLUSH_MS` | 16 | [`useManageMCPConnections.ts`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L207) |

---
*本文档由 markdowncli 技能辅助生成*

<!-- more -->

## 一、 概述

本文档是 Claude Code MCP（Model Context Protocol）实现的**总览索引**，从架构层面梳理 Host、Client、Server 连接、工具发现与调用之间的关系，并指引到各专题子文档。Claude Code 完整实现了 MCP 协议的客户端侧，能够同时管理多个本地（stdio/sdk）与远程（sse/http/ws/claudeai-proxy）MCP 服务器，把它们的工具、命令、资源动态接入 LLM 工具集。

## 二、 Claude Code / Host / Client / Server 关系

在 MCP 协议中，**Host**（宿主）是嵌入 LLM 的应用程序，负责管理一个或多个 **Client**；每个 **Client** 与一个 **Server** 维持 1:1 连接。Claude Code 本身就是 Host，它在进程内为每个配置的 MCP 服务器创建一个 Client，通过不同类型的 Transport 与 Server 通信。

### 1. 整体关系图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Claude Code (Host)                            │
│  ┌─────────────┐   ┌──────────────────────────────────────────────┐   │
│  │             │   │           MCPConnectionManager               │   │
│  │     LLM     │   │      (React Context Provider + Hook)         │   │
│  │  (Anthropic)│   │                                              │   │
│  │             │   │   useManageMCPConnections                    │   │
│  │  调用工具    │◄──┤     ├─ 两阶段加载                            │   │
│  │  接收结果    │   │     ├─ 批量状态更新 (16ms 窗口)              │   │
│  │             │   │     ├─ 断线重连 (指数退避)                    │   │
│  │             │   │     └─ 手动 reconnect / toggle               │   │
│  └──────┬──────┘   └──────────────┬───────────────────────────────┘   │
│         │                         │                                    │
│         │  工具集 (appState.mcp)   │ 每个服务器一个 Client              │
│         │  ├─ tools[]             │                                    │
│         │  ├─ commands[]          ▼                                    │
│         │  └─ resources{}   ┌──────────┐ ┌──────────┐ ┌──────────┐    │
│         │                   │ Client A │ │ Client B │ │ Client C │    │
│         └──────────────────►│ (stdio)  │ │ (http)   │ │ (sse)    │    │
│                             └────┬─────┘ └────┬─────┘ └────┬─────┘    │
│                                  │            │            │           │
└──────────────────────────────────┼────────────┼────────────┼───────────┘
                                   │            │            │
                          Transport│   Transport│   Transport│
                          (子进程   │   (HTTP/SSE│   (SSE 长连│
                           stdin/  │    流式)   │    接 +    │
                           stdout) │            │    POST)   │
                                   ▼            ▼            ▼
                         ┌──────────────┐ ┌──────────┐ ┌──────────┐
                         │  MCP Server  │ │MCP Server│ │MCP Server│
                         │  (本地子进程) │ │ (远程HTTP)│ │ (远程SSE)│
                         │              │ │          │ │          │
                         │  tools       │ │  tools   │ │  tools   │
                         │  prompts     │ │  prompts │ │  prompts │
                         │  resources   │ │resources │ │resources │
                         └──────────────┘ └──────────┘ └──────────┘
```

### 2. 角色职责对照

| 角色 | 在 Claude Code 中的体现 | 职责 |
|------|------------------------|------|
| **Host** | Claude Code 应用本身 + [`MCPConnectionManager`](../../claude-code-source/src/services/mcp/MCPConnectionManager.tsx#L38) + [`useManageMCPConnections`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L143) | 嵌入 LLM、管理多个 Client 生命周期、把工具/命令/资源聚合到 `appState.mcp` 供 LLM 使用 |
| **Client** | MCP SDK 的 [`Client`](../../claude-code-source/src/services/mcp/client.ts#L985) 实例（每个服务器一个） | 与单个 Server 维持 1:1 连接、发起 JSON-RPC 请求（`tools/list`、`tools/call` 等）、接收通知（`list_changed`、`progress`） |
| **Server** | 用户配置的外部进程或远程服务 | 实现 MCP 协议服务端，暴露 tools / prompts / resources，响应 Client 请求并主动推送通知 |
| **Transport** | `StdioClientTransport` / `SSEClientTransport` / `StreamableHTTPClientTransport` / `WebSocketTransport` / `InProcessTransport` | 承载 Client 与 Server 之间的消息传输，对上层屏蔽通信细节 |

### 3. 消息流向

```
                ┌─────────────────────────────────────┐
                │              Host                    │
                │  ┌─────────┐    ┌─────────────────┐ │
                │  │   LLM   │    │  MCP Client     │ │
                │  └────┬────┘    └────────┬────────┘ │
                └───────┼─────────────────┼──────────┘
                        │                 │
    ① LLM 发起 tool_use │                 │
    ──────────────────► │                 │
                        │ ② Host 调用     │
                        │    MCPTool.call │
                        │ ──────────────► │
                        │                 │ ③ Client 发送
                        │                 │    tools/call
                        │                 │ ──────────────► ┌─────────┐
                        │                 │                 │  Server │
                        │                 │ ④ Server 返回   │         │
                        │                 │    CallToolResult
                        │                 │ ◄────────────── │         │
                        │ ⑤ Host 归一化   │                 │         │
                        │    processMCPResult              │         │
                        │ ◄───────────── │                 │         │
    ⑥ tool_result 注入  │                 │                 │         │
    ◄────────────────── │                 │                 └─────────┘
                        │                 │
                        │  ⑦ 服务器主动通知 (list_changed / progress)
                        │                 │ ◄────────────── ┌─────────┐
                        │                 │                 │  Server │
                        │ ⑧ Host 刷新缓存 │                 │         │
                        │    更新 appState│                 │         │
                        │ ◄───────────── │                 └─────────┘
```

【**关键说明**】

- **Host 与 Client 是同进程**：Claude Code 进程内同时运行 Host 逻辑和所有 Client 实例，不存在跨进程通信开销；
- **Server 可在进程内或进程外**：`stdio` / `sdk` 类型 Server 是子进程或进程内对象，`sse` / `http` / `ws` 类型 Server 是远程服务；
- **一个 Host 可管理 N 个 Client**：每个 Client 对应一个 Server，Host 通过 [`appState.mcp`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L222) 把所有 Client 发现的工具聚合为统一工具集供 LLM 调用；
- **工具名带服务器前缀**：为避免不同服务器的同名工具冲突，Host 用 `mcp__<server>__<tool>` 格式命名（见 [LV008 第二节](LV008-MCP-工具发现与调用.md#二-命名规范)），LLM 调用时使用全限定名，Host 解析后路由到对应 Client。

## 三、 三层架构

Claude Code 的 MCP 实现可以划分为三层，每层由独立文档详细展开：

| 层级 | 职责 | 子文档 |
|------|------|--------|
| **Host 层** | 连接生命周期编排：两阶段加载、状态管理、断线重连、手动操作、批量更新 | [LV006-MCP-Host与连接生命周期](LV006-MCP-Host与连接生命周期.md) |
| **Client/Transport 层** | 单服务器连接：Transport 创建、SDK Client 握手、能力声明、错误桥接、认证降级 | [LV007-MCP-Client与传输层](LV007-MCP-Client与传输层.md) |
| **发现/调用层** | 工具/命令/资源的发现与实时刷新、工具调用主流程、进度通知、会话过期重试、结果归一化 | [LV008-MCP-工具发现与调用](LV008-MCP-工具发现与调用.md) |

此外，[LV020-tool-result-pipeline](LV020-tool-result-pipeline.md) 专门展开结果归一化后的大输出处理（截断、文件持久化、消息级聚合预算）。

## 四、 整体调用关系

```
REPL / main.tsx (入口)
  └─> MCPConnectionManager (React Context Provider)  [Host 层]
       └─> useManageMCPConnections (核心 Hook)
            ├─> Phase 1: getClaudeCodeMcpConfigs() → getMcpToolsCommandsAndResources()  [发现层]
            │    └─> connectToServer()  [Client 层]
            │         ├─> Transport 创建 (stdio/sse/http/ws/sdk/claudeai-proxy/InProcess)
            │         ├─> Client 创建 + connect() (带超时握手)
            │         └─> fetchToolsForClient / fetchCommandsForClient / fetchResourcesForClient
            └─> Phase 2: fetchClaudeAIMcpConfigsIfEligible() → getMcpToolsCommandsAndResources()

LLM 调用工具时:
  MCPTool.call() (fetchToolsForClient 覆盖)  [发现/调用层]
    └─> callMCPToolWithUrlElicitationRetry()  ← 处理 -32042 URL elicitation
         └─> callMCPTool()  ← 真正发送 tools/call + 超时 + 进度
              └─> processMCPResult()  ← 结果归一化（详见 LV020）
```

## 五、 配置加载

### 1. 配置来源（按优先级从低到高）

| 序号 | 来源 | scope 值 | 说明 |
|------|------|----------|------|
| 1 | 插件 MCP 服务器 | `dynamic` | 从已安装的插件中提取 |
| 2 | 用户级配置 | `user` | `~/.claude.json` 中的 `mcpServers` |
| 3 | 项目级配置 | `project` | `.mcp.json` 文件，从 CWD 向上遍历所有父目录 |
| 4 | 本地项目配置 | `local` | `.claude/settings.json` 中的 `mcpServers` |
| 5 | 企业级配置 | `enterprise` | `managed-mcp.json`，存在时独占控制 |
| 6 | claude.ai 远程配置 | `claudeai` | 从 claude.ai API 获取 |
| 7 | 动态配置 | - | `--mcp-config` 命令行参数 |

### 2. 配置加载入口

[`getClaudeCodeMcpConfigs()`](../../claude-code-source/src/services/mcp/config.ts#L1071) 是配置加载的统一入口，调用链如下：

```
getClaudeCodeMcpConfigs(dynamicMcpConfig, claudeaiPromise)
  ├─> getMcpConfigsByScope('enterprise')   // 企业级（独占时直接返回）
  ├─> getMcpConfigsByScope('user')         // 用户级
  ├─> getMcpConfigsByScope('project')      // 项目级（遍历 .mcp.json，仅 approved）
  ├─> getMcpConfigsByScope('local')        // 本地项目级
  ├─> loadAllPluginsCacheOnly()            // 加载插件 MCP 服务器
  │    └─> getPluginMcpServers(plugin)
  ├─> dedupPluginMcpServers()              // 与手动配置按内容去重
  └─> filterMcpServersByPolicy()           // 企业策略过滤

fetchClaudeAIMcpConfigsIfEligible()        // 异步获取 claude.ai 服务器
  └─> claude.ai /v1/mcp_servers API
```

【**企业配置独占性**】若 [`doesEnterpriseMcpConfigExist()`](../../claude-code-source/src/services/mcp/config.ts#L1470) 返回 true，[`getClaudeCodeMcpConfigs`](../../claude-code-source/src/services/mcp/config.ts#L1084) 直接返回经过策略过滤的企业服务器列表，跳过所有其他 scope——企业客户通常不希望用户自行添加 MCP 服务器。

### 3. 传输类型

支持的传输类型在 [`types.ts`](../../claude-code-source/src/services/mcp/types.ts#L23) 中以 Zod schema 定义，详见 [LV007 第三节](LV007-MCP-Client与传输层.md#三-transport-创建)。

```typescript
// claude-code-source/src/services/mcp/types.ts
type Transport = 'stdio' | 'sse' | 'sse-ide' | 'http' | 'ws' | 'ws-ide' | 'sdk' | 'claudeai-proxy'
```

## 六、 服务器连接状态

`MCPServerConnection` 在 [`types.ts`](../../claude-code-source/src/services/mcp/types.ts#L180) 中定义为五种状态的联合类型，状态转移由 Host 层与 Client 层协作完成：

| 状态 | 含义 | 触发位置 |
|------|------|---------|
| `pending` | 等待连接，可携带 `reconnectAttempt` | Host 层初始化、重连中 |
| `connected` | 已连接，持有 Client 与 capabilities | Client 层握手成功 |
| `failed` | 连接失败或重连耗尽 | Client 层握手失败、Host 层重连上限 |
| `disabled` | 用户禁用，持久化在磁盘 | Host 层 `toggleMcpServer` |
| `needs-auth` | 远程服务器返回 401，需 OAuth | Client 层认证失败降级 |

详细的状态机与转移条件见 [LV006 第八节](LV006-MCP-Host与连接生命周期.md#八-服务器连接状态机)。

## 七、 关键模块速查

| 模块 | 文件路径 | 所属层级 | 说明 |
|------|---------|---------|------|
| `MCPConnectionManager` | [`MCPConnectionManager.tsx`](../../claude-code-source/src/services/mcp/MCPConnectionManager.tsx#L38) | Host | React Context Provider |
| `useManageMCPConnections` | [`useManageMCPConnections.ts`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L143) | Host | 核心 Hook，生命周期编排 |
| `connectToServer` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L595) | Client | 单服务器连接，memoize 缓存 |
| `getMcpToolsCommandsAndResources` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L2226) | 发现 | 批量连接与发现入口 |
| `fetchToolsForClient` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L1743) | 发现 | tools/list + Tool 映射 |
| `fetchCommandsForClient` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L2033) | 发现 | prompts/list + Command 映射 |
| `fetchResourcesForClient` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L2000) | 发现 | resources/list + ServerResource 映射 |
| `callMCPTool` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L3029) | 调用 | 真正发送 tools/call |
| `callMCPToolWithUrlElicitationRetry` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L2813) | 调用 | -32042 URL elicitation 重试包装 |
| `processMCPResult` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L2720) | 调用 | 结果归一化（详见 LV020） |
| `reconnectMcpServerImpl` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L2137) | Client | 重连实现 |
| `clearServerCache` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L1648) | Client | 清缓存（连接 + fetch*） |
| `ensureConnectedClient` | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L1688) | Client | 调用前确保连接有效 |
| `ClaudeAuthProvider` | [`auth.ts`](../../claude-code-source/src/services/mcp/auth.ts#L1376) | Client | OAuth Provider 实现 |
| `createMcpAuthTool` | [`McpAuthTool.ts`](../../claude-code-source/src/tools/McpAuthTool/McpAuthTool.ts#L49) | 调用 | needs-auth 状态下的认证伪工具 |
| `MCPTool` (基类) | [`MCPTool.ts`](../../claude-code-source/src/tools/MCPTool/MCPTool.ts#L27) | 发现 | 所有 MCP 工具的基类 |
| `registerElicitationHandler` | [`elicitationHandler.ts`](../../claude-code-source/src/services/mcp/elicitationHandler.ts#L68) | Host | Elicitation 请求 → UI 队列 |
| `getClaudeCodeMcpConfigs` | [`config.ts`](../../claude-code-source/src/services/mcp/config.ts#L1071) | 配置 | 配置加载统一入口 |
| `mcpStringUtils` | [`mcpStringUtils.ts`](../../claude-code-source/src/services/mcp/mcpStringUtils.ts) | 发现 | 工具名解析与构造 |
| `types` | [`types.ts`](../../claude-code-source/src/services/mcp/types.ts) | 全部 | 类型定义 |

## 八、 环境变量速查

| 环境变量 | 作用 | 默认值 |
|----------|------|--------|
| `MCP_TIMEOUT` | 连接超时（毫秒） | 30000 |
| `MCP_TOOL_TIMEOUT` | 单次工具调用超时（毫秒） | ~27.8 小时 |
| `MCP_REQUEST_TIMEOUT_MS` | 单次 HTTP 请求超时（内部常量） | 60000 |
| `MCP_SERVER_CONNECTION_BATCH_SIZE` | local 服务器连接并发度 | 3 |
| `MCP_REMOTE_SERVER_CONNECTION_BATCH_SIZE` | remote 服务器连接并发度 | 20 |
| `MAX_MCP_OUTPUT_TOKENS` | MCP 输出 token 上限 | 25000 |
| `ENABLE_MCP_LARGE_OUTPUT_FILES` | 设为 falsy 禁用大输出文件持久化 | 启用 |
| `CLAUDE_AGENT_SDK_MCP_NO_PREFIX` | SDK 模式下 MCP 工具不加 `mcp__` 前缀 | 关闭 |
| `CLAUDE_CODE_SHELL_PREFIX` | stdio 服务器命令前缀（如通过 shell 包装） | — |

## 九、 阅读建议

- 想了解整体架构与本索引：本文档（LV005）；
- 想了解连接生命周期、两阶段加载、重连机制：[LV006](LV006-MCP-Host与连接生命周期.md)；
- 想了解单服务器连接、Transport 选型、握手、认证：[LV007](LV007-MCP-Client与传输层.md)；
- 想了解工具/命令/资源发现、调用主流程、进度通知：[LV008](LV008-MCP-工具发现与调用.md)；
- 想了解大输出处理、文件持久化、消息级预算：[LV020](LV020-tool-result-pipeline.md)。

---
*本文档由 markdowncli 技能辅助生成*

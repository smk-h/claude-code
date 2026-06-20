<!-- more -->

## 一、 概述

本文档梳理 Claude Code 对 MCP 服务器所暴露能力的**发现**与**调用**两条主链路。发现链路涵盖 `tools/list`、`prompts/list`、`resources/list` 三类 JSON-RPC 请求及其结果向 Claude Code 内部 `Tool` / `Command` / `ServerResource` 类型的映射，以及 `list_changed` 通知的实时刷新。调用链路从 LLM 触发 `MCPTool.call()` 开始，经 `callMCPToolWithUrlElicitationRetry` 包装、`callMCPTool` 实际发送 `tools/call`、进度通知、会话过期重试、URL elicitation 重试，最终由 `processMCPResult` 归一化结果（详细的大输出处理见 [LV020-tool-result-pipeline](LV020-tool-result-pipeline.md)）。

连接与生命周期管理见 [LV006-MCP-Host与连接生命周期](LV006-MCP-Host与连接生命周期.md)；Transport 与 Client 握手细节见 [LV007-MCP-Client与传输层](LV007-MCP-Client与传输层.md)。

## 二、 命名规范

工具/命令的命名遵循统一的 `mcp__<server>__<tool>` 格式，由 [`mcpStringUtils.ts`](../../claude-code-source/src/services/mcp/mcpStringUtils.ts) 中的纯函数管理。该文件刻意保持轻量依赖，便于权限校验等模块单独引用。

### 1. 关键函数

| 函数 | 作用 | 来源 |
|------|------|------|
| `buildMcpToolName(server, tool)` | 构造 `mcp__<server>__<tool>` 全限定名 | [`mcpStringUtils.ts`](../../claude-code-source/src/services/mcp/mcpStringUtils.ts#L50) |
| `mcpInfoFromString(name)` | 反向解析 `mcp__server__tool` 为 `{ serverName, toolName }` | [`mcpStringUtils.ts`](../../claude-code-source/src/services/mcp/mcpStringUtils.ts#L19) |
| `getMcpPrefix(server)` | 返回 `mcp__<server>__` 前缀，用于整组替换 | [`mcpStringUtils.ts`](../../claude-code-source/src/services/mcp/mcpStringUtils.ts#L39) |
| `getToolNameForPermissionCheck(tool)` | 返回权限校验用的全限定名（防止内置工具与 MCP 工具同名冲突） | [`mcpStringUtils.ts`](../../claude-code-source/src/services/mcp/mcpStringUtils.ts#L60) |
| `normalizeNameForMCP(name)` | 把非 `[a-zA-Z0-9_-]` 字符替换为下划线 | [`normalization.ts`](../../claude-code-source/src/services/mcp/normalization.ts#L17) |

### 2. 解析的已知限制

```typescript
// claude-code-source/src/services/mcp/mcpStringUtils.ts
export function mcpInfoFromString(toolString: string) {
  const parts = toolString.split('__')
  const [mcpPart, serverName, ...toolNameParts] = parts
  if (mcpPart !== 'mcp' || !serverName) return null
  const toolName = toolNameParts.length > 0 ? toolNameParts.join('__') : undefined
  return { serverName, toolName }
}
```

【**已知限制**】若服务器名本身包含 `__`，解析会出错（例如 `mcp__my__server__tool` 会被解析为 `server=my, tool=server__tool`）。实践中服务器名极少含双下划线，因此未做更复杂的转义。

### 3. skip-prefix 模式

SDK 模式下若设置 `CLAUDE_AGENT_SDK_MCP_NO_PREFIX` 环境变量，[`fetchToolsForClient`](../../claude-code-source/src/services/mcp/client.ts#L1761) 会保留原始工具名（不加 `mcp__` 前缀），允许 MCP 工具按名覆盖内置工具。此时 `mcpInfo` 仍然正确写入，权限校验走全限定名。

## 三、 工具发现 — fetchToolsForClient

[`fetchToolsForClient`](../../claude-code-source/src/services/mcp/client.ts#L1743) 是工具发现的核心，使用 `memoizeWithLRU` 缓存（键为 `client.name`，容量 20）。

### 1. 协议层：tools/list

```typescript
// claude-code-source/src/services/mcp/client.ts
export const fetchToolsForClient = memoizeWithLRU(
  async (client: MCPServerConnection): Promise<Tool[]> => {
    if (client.type !== 'connected') return []
    if (!client.capabilities?.tools) return []

    const result = await client.client.request(
      { method: 'tools/list' },
      ListToolsResultSchema,
    )
    const toolsToProcess = recursivelySanitizeUnicode(result.tools)
    // ...
  },
  (client) => client.name,
  MCP_FETCH_CACHE_SIZE,  // 20
)
```

【**能力检查**】如果服务器在 capabilities 中没有声明 `tools`，直接返回空数组，不发起 `tools/list` 请求。`prompts` / `resources` 同理。

### 2. 向 Claude Code Tool 类型映射

[`fetchToolsForClient`](../../claude-code-source/src/services/mcp/client.ts#L1766) 把每个 MCP 工具映射为 Claude Code 内部的 `Tool` 对象，关键是**覆盖** [`MCPTool`](../../claude-code-source/src/tools/MCPTool/MCPTool.ts#L27) 基类中的占位字段：

```typescript
// claude-code-source/src/services/mcp/client.ts
return toolsToProcess.map((tool): Tool => {
  const fullyQualifiedName = buildMcpToolName(client.name, tool.name)
  return {
    ...MCPTool,                              // 继承基类的渲染、截断等
    name: skipPrefix ? tool.name : fullyQualifiedName,
    mcpInfo: { serverName: client.name, toolName: tool.name },
    isMcp: true,
    inputJSONSchema: tool.inputSchema,
    async description() { return tool.description ?? '' },
    async prompt() {
      const desc = tool.description ?? ''
      return desc.length > MAX_MCP_DESCRIPTION_LENGTH
        ? desc.slice(0, MAX_MCP_DESCRIPTION_LENGTH) + '… [truncated]'
        : desc
    },
    isConcurrencySafe() { return tool.annotations?.readOnlyHint ?? false },
    isReadOnly()        { return tool.annotations?.readOnlyHint ?? false },
    isDestructive()     { return tool.annotations?.destructiveHint ?? false },
    isOpenWorld()       { return tool.annotations?.openWorldHint ?? false },
    isSearchOrReadCommand() { return classifyMcpToolForCollapse(client.name, tool.name) },
    async checkPermissions() {
      return {
        behavior: 'passthrough' as const,
        message: 'MCPTool requires permission.',
        suggestions: [{
          type: 'addRules' as const,
          rules: [{ toolName: fullyQualifiedName, ruleContent: undefined }],
          behavior: 'allow' as const,
          destination: 'localSettings' as const,
        }],
      }
    },
    async call(args, context, _canUseTool, parentMessage, onProgress) {
      // 见七、工具调用主流程
    },
  }
})
```

【**MCP annotations 映射**】MCP 协议的 `tool.annotations` 直接映射到 Claude Code 的工具特性标志：`readOnlyHint` → 并发安全 + 只读；`destructiveHint` → 破坏性；`openWorldHint` → 开放世界。这些标志影响权限策略、并发执行、UI 折叠等。

### 3. MCPTool 基类

[`MCPTool`](../../claude-code-source/src/tools/MCPTool/MCPTool.ts#L27) 是所有 MCP 工具的基类，其 `name` / `description` / `prompt` / `call` 都标注了 `// Overridden in mcpClient.ts`（实际在 `client.ts` 的 `fetchToolsForClient` 中覆盖）。基类提供：

- `maxResultSizeChars: 100_000`：单次 MCP 工具结果的最大字符数；
- `renderToolUseMessage` / `renderToolUseProgressMessage` / `renderToolResultMessage`：UI 渲染；
- `isResultTruncated`：判断输出是否被截断；
- `mapToolResultToToolResultBlockParam`：把结果转为 Anthropic API 的 `tool_result` block。

### 4. 特殊工具注入

- **searchHint / alwaysLoad**：从 `tool._meta['anthropic/searchHint']` 与 `tool._meta['anthropic/alwaysLoad']` 提取，用于延迟工具加载与始终加载策略；
- **Chrome MCP / Computer Use MCP**：在映射时通过 `claudeInChromeToolRendering()` / `computerUseWrapper()` 注入专用覆盖；
- **资源工具**：当某个服务器声明 `resources` 能力时，[`getMcpToolsCommandsAndResources`](../../claude-code-source/src/services/mcp/client.ts#L2361) 会在其工具列表后追加 `ListMcpResourcesTool` 与 `ReadMcpResourceTool`（全局只追加一次，由 `resourceToolsAdded` 标志控制）。

## 四、 命令发现 — fetchCommandsForClient

[`fetchCommandsForClient`](../../claude-code-source/src/services/mcp/client.ts#L2033) 把 MCP `prompts/list` 返回的 prompts 映射为 Claude Code 的 `Command`（斜杠命令）。同样使用 `memoizeWithLRU` 缓存。

### 1. 协议层：prompts/list

```typescript
// claude-code-source/src/services/mcp/client.ts
const result = await client.client.request(
  { method: 'prompts/list' },
  ListPromptsResultSchema,
)
const promptsToProcess = recursivelySanitizeUnicode(result.prompts)
```

### 2. 映射为 Command

```typescript
// claude-code-source/src/services/mcp/client.ts
return promptsToProcess.map(prompt => {
  const argNames = Object.values(prompt.arguments ?? {}).map(k => k.name)
  return {
    type: 'prompt' as const,
    name: 'mcp__' + normalizeNameForMCP(client.name) + '__' + prompt.name,
    description: prompt.description ?? '',
    isEnabled: () => true,
    isMcp: true,
    progressMessage: 'running',
    userFacingName() { return `${client.name}:${prompt.name} (MCP)` },
    argNames,
    source: 'mcp',
    async getPromptForCommand(args: string) {
      const argsArray = args.split(' ')
      const connectedClient = await ensureConnectedClient(client)
      const result = await connectedClient.client.getPrompt({
        name: prompt.name,
        arguments: zipObject(argNames, argsArray),
      })
      const transformed = await Promise.all(
        result.messages.map(message =>
          transformResultContent(message.content, connectedClient.name),
        ),
      )
      return transformed.flat()
    },
  }
})
```

【**getPromptForCommand 调用链**】用户在 REPL 输入 `/mcp__<server>__<prompt>` 时，Claude Code 调用该 command 的 `getPromptForCommand`，它通过 [`ensureConnectedClient`](../../claude-code-source/src/services/mcp/client.ts#L1688) 确保连接、调用 SDK 的 `client.getPrompt()`、再用 [`transformResultContent`](../../claude-code-source/src/services/mcp/client.ts#L2478) 把每条消息的内容转为 Anthropic 消息块。

## 五、 资源发现 — fetchResourcesForClient

[`fetchResourcesForClient`](../../claude-code-source/src/services/mcp/client.ts#L2000) 把 MCP `resources/list` 返回的资源映射为 `ServerResource`（`Resource & { server: string }`）。

```typescript
// claude-code-source/src/services/mcp/client.ts
export const fetchResourcesForClient = memoizeWithLRU(
  async (client: MCPServerConnection): Promise<ServerResource[]> => {
    if (client.type !== 'connected') return []
    if (!client.capabilities?.resources) return []

    const result = await client.client.request(
      { method: 'resources/list' },
      ListResourcesResultSchema,
    )
    if (!result.resources) return []

    return result.resources.map(resource => ({
      ...resource,
      server: client.name,
    }))
  },
  (client) => client.name,
  MCP_FETCH_CACHE_SIZE,
)
```

资源本身不是工具——用户通过 `ListMcpResourcesTool` 列出所有资源，通过 `ReadMcpResourceTool` 读取单个资源内容（这两个工具由 [`getMcpToolsCommandsAndResources`](../../claude-code-source/src/services/mcp/client.ts#L2361) 在首个支持 resources 的服务器连接成功时注入）。

## 六、 批量发现 — getMcpToolsCommandsAndResources

[`getMcpToolsCommandsAndResources`](../../claude-code-source/src/services/mcp/client.ts#L2226) 是 Host 层调用的批量入口，负责把多个服务器的连接与发现编排起来。

### 1. 流程

```typescript
// claude-code-source/src/services/mcp/client.ts
export async function getMcpToolsCommandsAndResources(onConnectionAttempt, mcpConfigs) {
  // 1. 拆分 disabled / active
  for (const entry of allConfigEntries) {
    if (isMcpServerDisabled(entry[0])) {
      onConnectionAttempt({ client: { name, type: 'disabled', config }, tools: [], commands: [] })
    } else {
      configEntries.push(entry)
    }
  }

  // 2. 拆分 local / remote
  const localServers = configEntries.filter(([_, c]) => isLocalMcpServer(c))
  const remoteServers = configEntries.filter(([_, c]) => !isLocalMcpServer(c))

  // 3. 两组并发，各自独立并发度
  await Promise.all([
    processBatched(localServers, getMcpServerConnectionBatchSize(), processServer),
    processBatched(remoteServers, getRemoteMcpServerConnectionBatchSize(), processServer),
  ])
}
```

### 2. processServer 单服务器处理

```typescript
// claude-code-source/src/services/mcp/client.ts
const processServer = async ([name, config]) => {
  // 1. 跳过 needs-auth 缓存命中
  if ((config.type === 'claudeai-proxy' || config.type === 'http' || config.type === 'sse')
      && ((await isMcpAuthCached(name)) || hasMcpDiscoveryButNoToken(name, config))) {
    onConnectionAttempt({
      client: { name, type: 'needs-auth', config },
      tools: [createMcpAuthTool(name, config)],
      commands: [],
    })
    return
  }

  // 2. 连接
  const client = await connectToServer(name, config, serverStats)
  if (client.type !== 'connected') {
    onConnectionAttempt({
      client,
      tools: client.type === 'needs-auth' ? [createMcpAuthTool(name, config)] : [],
      commands: [],
    })
    return
  }

  // 3. 并行发现 tools / commands / skills / resources
  const supportsResources = !!client.capabilities?.resources
  const [tools, mcpCommands, mcpSkills, resources] = await Promise.all([
    fetchToolsForClient(client),
    fetchCommandsForClient(client),
    feature('MCP_SKILLS') && supportsResources ? fetchMcpSkillsForClient!(client) : Promise.resolve([]),
    supportsResources ? fetchResourcesForClient(client) : Promise.resolve([]),
  ])

  // 4. 资源工具注入（全局一次）
  const resourceTools = (supportsResources && !resourceToolsAdded)
    ? (resourceToolsAdded = true, [ListMcpResourcesTool, ReadMcpResourceTool]) : []

  onConnectionAttempt({ client, tools: [...tools, ...resourceTools], commands: [...mcpCommands, ...mcpSkills], resources })
}
```

## 七、 list_changed 实时刷新

当服务器声明 `listChanged` 能力时，[`onConnectionAttempt`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L618) 注册对应的通知处理器，让服务器主动通知能力变化时刷新缓存。

### 1. tools/list_changed

```typescript
// claude-code-source/src/services/mcp/useManageMCPConnections.ts
if (client.capabilities?.tools?.listChanged) {
  client.client.setNotificationHandler(ToolListChangedNotificationSchema, async () => {
    fetchToolsForClient.cache.delete(client.name)   // 清缓存
    const newTools = await fetchToolsForClient(client)
    updateServer({ ...client, tools: newTools })    // 写回 appState
  })
}
```

### 2. prompts/list_changed 与 resources/list_changed

两者类似，但 [`resources/list_changed`](../../claude-code-source/src/services/mcp/useManageMCPConnections.ts#L705) 在启用 `MCP_SKILLS` 时会**同时**刷新 skills 与 prompts 缓存：

```typescript
// claude-code-source/src/services/mcp/useManageMCPConnections.ts
if (client.capabilities?.resources?.listChanged) {
  client.client.setNotificationHandler(ResourceListChangedNotificationSchema, async () => {
    fetchResourcesForClient.cache.delete(client.name)
    if (feature('MCP_SKILLS')) {
      // Skills 派生自 resources，需要一起刷新
      // 同时刷新 prompts 缓存避免并发 prompts/list_changed 覆盖
      fetchMcpSkillsForClient!.cache.delete(client.name)
      fetchCommandsForClient.cache.delete(client.name)
      const [newResources, mcpPrompts, mcpSkills] = await Promise.all([
        fetchResourcesForClient(client),
        fetchCommandsForClient(client),
        fetchMcpSkillsForClient!(client),
      ])
      updateServer({ ...client, resources: newResources, commands: [...mcpPrompts, ...mcpSkills] })
      clearSkillIndexCache?.()
    } else {
      const newResources = await fetchResourcesForClient(client)
      updateServer({ ...client, resources: newResources })
    }
  })
}
```

## 八、 工具调用主流程

当 LLM 决定调用某个 MCP 工具时，Claude Code 执行的是 [`fetchToolsForClient`](../../claude-code-source/src/services/mcp/client.ts#L1833) 覆盖后的 `call()` 方法。完整调用链：

```
MCPTool.call() (fetchToolsForClient 覆盖)
  └─> callMCPToolWithUrlElicitationRetry()  // 处理 -32042 URL elicitation 重试
       └─> callMCPTool()                    // 真正发送 tools/call + 超时 + 进度
            └─> client.callTool()           // MCP SDK 发送 JSON-RPC
            └─> processMCPResult()          // 结果归一化（详见 LV020）
```

### 1. MCPTool.call 覆盖实现

```typescript
// claude-code-source/src/services/mcp/client.ts
async call(args, context, _canUseTool, parentMessage, onProgress) {
  const toolUseId = extractToolUseId(parentMessage)
  const meta = toolUseId ? { 'claudecode/toolUseId': toolUseId } : {}

  // 发送 started 进度
  if (onProgress && toolUseId) {
    onProgress({ toolUseID: toolUseId, data: { type: 'mcp_progress', status: 'started', serverName: client.name, toolName: tool.name } })
  }

  const startTime = Date.now()
  const MAX_SESSION_RETRIES = 1
  for (let attempt = 0; ; attempt++) {
    try {
      const connectedClient = await ensureConnectedClient(client)
      const mcpResult = await callMCPToolWithUrlElicitationRetry({
        client: connectedClient,
        clientConnection: client,
        tool: tool.name,
        args,
        meta,
        signal: context.abortController.signal,
        setAppState: context.setAppState,
        onProgress: onProgress && toolUseId ? (progressData => onProgress({ toolUseID: toolUseId, data: progressData })) : undefined,
        handleElicitation: context.handleElicitation,
      })

      // 发送 completed 进度
      if (onProgress && toolUseId) {
        onProgress({ toolUseID: toolUseId, data: { type: 'mcp_progress', status: 'completed', serverName: client.name, toolName: tool.name, elapsedTimeMs: Date.now() - startTime } })
      }

      return {
        data: mcpResult.content,
        ...((mcpResult._meta || mcpResult.structuredContent) && {
          mcpMeta: {
            ...(mcpResult._meta && { _meta: mcpResult._meta }),
            ...(mcpResult.structuredContent && { structuredContent: mcpResult.structuredContent }),
          },
        }),
      }
    } catch (error) {
      // 会话过期重试一次（缓存已被 onerror 清空，新连接拿到新 session）
      if (error instanceof McpSessionExpiredError && attempt < MAX_SESSION_RETRIES) {
        continue
      }
      // 发送 failed 进度
      // 把 McpError 包装为 TelemetrySafeError，避免用户文件路径泄露到遥测
      throw error
    }
  }
}
```

【**meta.claudecode/toolUseId**】把 Claude Code 内部的 `toolUseId` 通过 `_meta` 传给 MCP 服务器，便于服务器端把进度通知关联到具体调用。

### 2. callMCPToolWithUrlElicitationRetry 包装

[`callMCPToolWithUrlElicitationRetry`](../../claude-code-source/src/services/mcp/client.ts#L2813) 处理 MCP 错误码 `-32042 UrlElicitationRequired`：服务器要求用户先打开某个 URL 完成外部步骤后才能继续。

```typescript
// claude-code-source/src/services/mcp/client.ts
export async function callMCPToolWithUrlElicitationRetry({
  client, clientConnection, tool, args, meta, signal, setAppState, onProgress, callToolFn = callMCPTool, handleElicitation,
}) {
  const MAX_URL_ELICITATION_RETRIES = 3
  for (let attempt = 0; ; attempt++) {
    try {
      return await callToolFn({ client, tool, args, meta, signal, onProgress })
    } catch (error) {
      // SDK 把 -32042 包成普通 McpError，按 code 判断
      if (!(error instanceof McpError) || error.code !== ErrorCode.UrlElicitationRequired) throw error
      if (attempt >= MAX_URL_ELICITATION_RETRIES) throw error

      // 校验 error.data.elicitations 数组
      const elicitations = rawElicitations.filter(/* mode=url, url, elicitationId, message 均存在 */)

      for (const elicitation of elicitations) {
        // 1. 先跑 elicitation hooks，hook 可直接 resolve
        const hookResponse = await runElicitationHooks(serverName, elicitation, signal)
        if (hookResponse) {
          if (hookResponse.action !== 'accept') {
            return { content: `URL elicitation was ${hookResponse.action}ed by a hook...` }
          }
          continue  // hook accept，跳过 UI 直接重试
        }

        // 2. print/SDK 模式走 handleElicitation 回调；REPL 模式入队 elicitation.queue
        let userResult
        if (handleElicitation) {
          userResult = await handleElicitation(serverName, elicitation, signal)
        } else {
          userResult = await new Promise(resolve => {
            setAppState(prev => ({ ...prev, elicitation: { queue: [...prev.elicitation.queue, { /* 两阶段 consent/waiting */ }] } }))
          })
        }

        // 3. 跑 elicitation result hooks（可修改或拦截响应）
        const finalResult = await runElicitationResultHooks(serverName, userResult, signal, 'url', elicitationId)
        if (finalResult.action !== 'accept') {
          return { content: `URL elicitation was ${finalResult.action}ed by the user...` }
        }
      }
      // 循环回到 callToolFn 重试
    }
  }
}
```

【**两阶段 consent/waiting**】REPL 模式下入队的 elicitation item 携带 `waitingState: { actionLabel: 'Retry now', showCancel: true }`。用户先点“Retry now”表示同意（accept 是 no-op，不 resolve Promise，等待服务器完成通知），或点“Cancel”才 resolve 取消。完成通知由 [`registerElicitationHandler`](../../claude-code-source/src/services/mcp/elicitationHandler.ts#L68) 中注册的 `ElicitationCompleteNotificationSchema` handler 处理。

## 九、 callMCPTool — 真正的 tools/call

[`callMCPTool`](../../claude-code-source/src/services/mcp/client.ts#L3029) 是真正向 MCP 服务器发送 `tools/call` JSON-RPC 请求的地方，负责超时、进度日志、错误识别与会话过期处理。

### 1. 超时与调用

```typescript
// claude-code-source/src/services/mcp/client.ts
const timeoutMs = getMcpToolTimeoutMs()
const result = await Promise.race([
  client.callTool(
    { name: tool, arguments: args, _meta: meta },
    CallToolResultSchema,
    {
      signal,
      timeout: timeoutMs,
      onprogress: onProgress
        ? sdkProgress => onProgress({
            type: 'mcp_progress', status: 'progress',
            serverName: name, toolName: tool,
            progress: sdkProgress.progress, total: sdkProgress.total,
            progressMessage: sdkProgress.message,
          })
        : undefined,
    },
  ),
  timeoutPromise,
]).finally(() => { if (timeoutId) clearTimeout(timeoutId) })
```

【**双保险超时**】`client.callTool` 的 `timeout` 选项依赖 SDK 内部实现，但 SSE 流中途断开时 SDK 超时可能不生效，所以外层再用 `Promise.race` 加一道 `timeoutPromise`（抛 `TelemetrySafeError`）。

### 2. isError 处理

MCP 协议规定服务器可以通过 `result.isError: true` 表示工具执行失败（HTTP 200 但业务错误）。[`callMCPTool`](../../claude-code-source/src/services/mcp/client.ts#L3124) 检查该字段并抛 `McpToolCallError`：

```typescript
// claude-code-source/src/services/mcp/client.ts
if ('isError' in result && result.isError) {
  let errorDetails = 'Unknown error'
  if ('content' in result && Array.isArray(result.content) && result.content.length > 0) {
    const firstContent = result.content[0]
    if (firstContent && typeof firstContent === 'object' && 'text' in firstContent) {
      errorDetails = firstContent.text
    }
  } else if ('error' in result) {
    errorDetails = String(result.error)  // 兼容 legacy 格式
  }
  throw new McpToolCallError_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS(
    errorDetails, 'MCP tool returned error',
    '_meta' in result && result._meta ? { _meta: result._meta } : undefined,
  )
}
```

### 3. 进度日志

[`callMCPTool`](../../claude-code-source/src/services/mcp/client.ts#L3054) 每 30 秒输出一次“工具仍在运行”的调试日志，便于排查慢工具：

```typescript
// claude-code-source/src/services/mcp/client.ts
progressInterval = setInterval((startTime, name, tool) => {
  const elapsed = Date.now() - startTime
  logMCPDebug(name, `Tool '${tool}' still running (${Math.floor(elapsed / 1000)}s elapsed)`)
}, 30000, toolStartTime, name, tool)
```

### 4. 进度通知转发

SDK 的 `onprogress` 回调把 MCP `notifications/progress` 转发为 Claude Code 的 `MCPProgress` 对象，再通过 `onProgress` 回调传给 UI：

```typescript
// claude-code-source/src/services/mcp/client.ts
onprogress: onProgress
  ? sdkProgress => onProgress({
      type: 'mcp_progress', status: 'progress',
      serverName: name, toolName: tool,
      progress: sdkProgress.progress, total: sdkProgress.total,
      progressMessage: sdkProgress.message,
    })
  : undefined,
```

## 十、 调用错误识别与会话过期

[`callMCPTool`](../../claude-code-source/src/services/mcp/client.ts#L3179) 的 catch 分支识别三类错误：

### 1. 401 认证过期

```typescript
// claude-code-source/src/services/mcp/client.ts
if (errorCode === 401 || e instanceof UnauthorizedError) {
  logEvent('tengu_mcp_tool_call_auth_error', {})
  throw new McpAuthError(name, `MCP server "${name}" requires re-authorization (token expired)`)
}
```

### 2. 会话过期（两种形态）

```typescript
// claude-code-source/src/services/mcp/client.ts
const isSessionExpired = isMcpSessionExpiredError(e)
const isConnectionClosedOnHttp =
  'code' in e && (e as Error & { code?: number }).code === -32000 &&
  e.message.includes('Connection closed') &&
  (config.type === 'http' || config.type === 'claudeai-proxy')

if (isSessionExpired || isConnectionClosedOnHttp) {
  await clearServerCache(name, config)   // 清缓存，让下次调用重建会话
  throw new McpSessionExpiredError(name) // 上层 MCPTool.call 收到后重试一次
}
```

【**两种形态**】

1. **直接形态**：服务器返回 404 + JSON-RPC -32001（`StreamableHTTPError`），由 [`isMcpSessionExpiredError()`](../../claude-code-source/src/services/mcp/client.ts#L193) 识别；
2. **间接形态**：[`onerror`](../../claude-code-source/src/services/mcp/client.ts#L1316) 检测到会话过期后调用 `client.close()`，pending 的 `callTool()` 因此以 `-32000 Connection closed` 失败。两种形态都清缓存并抛 `McpSessionExpiredError`，由 [`MCPTool.call`](../../claude-code-source/src/services/mcp/client.ts#L1913) 捕获后重试一次（`MAX_SESSION_RETRIES = 1`）。

### 3. 错误遥测脱敏

普通 `Error` 与 `McpError` 会被包装为 `TelemetrySafeError_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS`，确保遥测中只包含错误类型与短消息，不泄露用户文件路径或代码内容：

```typescript
// claude-code-source/src/services/mcp/client.ts
if (error instanceof Error && !(error instanceof TelemetrySafeError_...)) {
  const name = error.constructor.name
  if (name === 'Error') {
    throw new TelemetrySafeError_...(error.message, error.message.slice(0, 200))
  }
  if (name === 'McpError' && 'code' in error && typeof error.code === 'number') {
    throw new TelemetrySafeError_...(error.message, `McpError ${error.code}`)
  }
}
```

## 十一、 结果归一化 — processMCPResult

[`callMCPTool`](../../claude-code-source/src/services/mcp/client.ts#L3171) 成功返回后调用 [`processMCPResult(result, tool, name)`](../../claude-code-source/src/services/mcp/client.ts#L2720) 把原始结果归一化。

### 1. 决策流程

```typescript
// claude-code-source/src/services/mcp/client.ts
export async function processMCPResult(result, tool, name) {
  const { content, type, schema } = await transformMCPResult(result, tool, name)

  if (name === 'ide') return content   // IDE 工具不经过大输出处理

  if (!(await mcpContentNeedsTruncation(content))) return content  // 小于阈值

  const sizeEstimateTokens = getContentSizeEstimate(content)

  // 大输出文件特性被禁用 → 走老截断
  if (isEnvDefinedFalsy(process.env.ENABLE_MCP_LARGE_OUTPUT_FILES)) {
    return await truncateMcpContentIfNeeded(content)
  }

  if (!content) return content
  // 含图片块 → 截断（图片无法 JSON 持久化）
  if (contentContainsImages(content)) {
    return await truncateMcpContentIfNeeded(content)
  }

  // 持久化为文件，返回读取指引
  const persistId = `mcp-${normalizeNameForMCP(name)}-${normalizeNameForMCP(tool)}-${Date.now()}`
  const contentStr = typeof content === 'string' ? content : jsonStringify(content, null, 2)
  const persistResult = await persistToolResult(contentStr, persistId)
  if (isPersistError(persistResult)) {
    return `Error: result (...) exceeds maximum allowed tokens. Failed to save output to file: ${persistResult.error}...`
  }
  return getLargeOutputInstructions(persistResult.filepath, persistResult.originalSize, getFormatDescription(type, schema))
}
```

### 2. 与 LV020 的关系

`processMCPResult` 的完整决策、大小阈值判定、截断实现、文件持久化路径、读取指引文本生成等细节已在 [LV020-tool-result-pipeline](LV020-tool-result-pipeline.md) 中详细展开，本文不再重复。本节只列出其在调用链中的位置与决策骨架。

【**两层大小管控**】`processMCPResult` 是 MCP 层（默认 25000 tokens）的核心决策；其输出还会进入通用工具层 [`maybePersistLargeToolResult()`](../../claude-code-source/src/utils/toolResultStorage.ts#L272)（默认 50000 字符）做二次检查，详见 [LV020 第六节](LV020-tool-result-pipeline.md#六-通用工具层的二次持久化)。

## 十二、 McpAuthTool — 认证伪工具

当远程服务器返回 401 进入 `needs-auth` 状态时，[`getMcpToolsCommandsAndResources`](../../claude-code-source/src/services/mcp/client.ts#L2318) 与 [`connectToServer`](../../claude-code-source/src/services/mcp/client.ts#L2329) 会调用 [`createMcpAuthTool(name, config)`](../../claude-code-source/src/tools/McpAuthTool/McpAuthTool.ts#L49) 生成一个伪工具，让 LLM 知道该服务器存在并可触发 OAuth。

### 1. 工具特征

```typescript
// claude-code-source/src/tools/McpAuthTool/McpAuthTool.ts
return {
  name: buildMcpToolName(serverName, 'authenticate'),  // mcp__<server>__authenticate
  isMcp: true,
  mcpInfo: { serverName, toolName: 'authenticate' },
  isEnabled: () => true,
  async description() {
    return `The \`${serverName}\` MCP server (${location}) is installed but requires authentication. ...`
  },
  async checkPermissions() { return { behavior: 'allow', updatedInput: input } },
  // ...
}
```

### 2. call() 触发 OAuth

```typescript
// claude-code-source/src/tools/McpAuthTool/McpAuthTool.ts
async call(_input, context) {
  // claude.ai connector 走单独流程，提示用户用 /mcp
  if (config.type === 'claudeai-proxy') {
    return { data: { status: 'unsupported', message: '...run /mcp and select...' } }
  }
  // 只支持 sse / http
  if (config.type !== 'sse' && config.type !== 'http') {
    return { data: { status: 'unsupported', message: '...run /mcp and authenticate manually.' } }
  }

  // 启动 OAuth 流程，skipBrowserOpen=true，等 onAuthorizationUrl 回调拿到 URL
  let resolveAuthUrl
  const authUrlPromise = new Promise<string>(resolve => { resolveAuthUrl = resolve })
  const controller = new AbortController()
  const oauthPromise = performMCPOAuthFlow(serverName, sseOrHttpConfig, u => resolveAuthUrl?.(u), controller.signal, { skipBrowserOpen: true })

  // 后台：OAuth 完成后重连并替换工具
  void oauthPromise.then(async () => {
    clearMcpAuthCache()
    const result = await reconnectMcpServerImpl(serverName, config)
    const prefix = getMcpPrefix(serverName)
    setAppState(prev => ({
      ...prev,
      mcp: {
        ...prev.mcp,
        clients: prev.mcp.clients.map(c => c.name === serverName ? result.client : c),
        tools: [...reject(prev.mcp.tools, t => t.name?.startsWith(prefix)), ...result.tools],
        // commands / resources 同理
      },
    }))
  })

  // 立即返回 auth URL 给 LLM，让它转告用户
  const authUrl = await Promise.race([authUrlPromise, oauthPromise.then(() => null)])
  if (authUrl) {
    return { data: { status: 'auth_url', authUrl, message: `Ask the user to open this URL...` } }
  }
  return { data: { status: 'auth_url', message: `Authentication completed silently...` } }
}
```

【**自动清理机制**】OAuth 完成后 [`reconnectMcpServerImpl`](../../claude-code-source/src/services/mcp/client.ts#L2137) 拿到真实工具列表，通过前缀匹配 `reject(prev.mcp.tools, t => t.name?.startsWith(prefix))` 把包括 `mcp__<server>__authenticate` 在内的旧工具全部移除，再追加新工具。这保证伪工具在认证成功后被自动替换。

## 十三、 完整调用链路图

```
LLM 决定调用 mcp__<server>__<tool>
        │
        ▼
MCPTool.call()  (fetchToolsForClient 覆盖)
        │
        ├─ 发送 mcp_progress{status:started}
        │
        ▼
ensureConnectedClient()  ← 检查/重建连接
        │
        ▼
callMCPToolWithUrlElicitationRetry()  ← 处理 -32042
        │
        ├─ 若 McpError code === UrlElicitationRequired：
        │     ├─ runElicitationHooks
        │     ├─ handleElicitation / 入队 elicitation.queue
        │     └─ runElicitationResultHooks → accept 则重试
        │
        ▼
callMCPTool()  ← 真正发 tools/call
        │
        ├─ Promise.race([client.callTool(), timeoutPromise])
        │     ├─ onprogress → 转发 mcp_progress{status:progress}
        │     └─ 每 30s 输出调试日志
        │
        ├─ result.isError === true → 抛 McpToolCallError
        │
        ├─ 401 / UnauthorizedError → 抛 McpAuthError
        │
        ├─ 会话过期（-32001 / -32000 Connection closed on http） →
        │     clearServerCache + 抛 McpSessionExpiredError
        │       └─ MCPTool.call 收到后重试一次（MAX_SESSION_RETRIES=1）
        │
        ▼
processMCPResult()  ← 结果归一化（详见 LV020）
        │
        ├─ transformMCPResult: toolResult / structuredContent / contentArray
        ├─ 小于阈值 → 直接返回
        ├─ 含图片 / 大文件特性禁用 → truncateMcpContent
        └─ 超大输出 → persistToolResult + getLargeOutputInstructions
        │
        ▼
返回 { data, mcpMeta? }
        │
        ▼
发送 mcp_progress{status:completed}
```

## 十四、 关键常量速查

| 常量 | 值 | 来源 |
|------|-----|------|
| `MCP_FETCH_CACHE_SIZE` | 20 | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L1726) |
| `MAX_MCP_DESCRIPTION_LENGTH` | 2048 | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L218) |
| `MAX_URL_ELICITATION_RETRIES` | 3 | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L2850) |
| `MAX_SESSION_RETRIES` | 1 | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L1859) |
| 进度日志间隔 | 30000 ms | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L3062) |
| `MCPTool.maxResultSizeChars` | 100000 | [`MCPTool.ts`](../../claude-code-source/src/tools/MCPTool/MCPTool.ts#L35) |
| `DEFAULT_MAX_MCP_OUTPUT_TOKENS` | 25000 | [`mcpValidation.ts`](../../claude-code-source/src/utils/mcpValidation.ts#L16) |
| needs-auth 缓存 TTL | 15 分钟 | [`client.ts`](../../claude-code-source/src/services/mcp/client.ts#L257) |

---
*本文档由 markdowncli 技能辅助生成*

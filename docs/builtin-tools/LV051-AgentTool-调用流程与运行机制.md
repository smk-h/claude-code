<!-- more -->

## 一、 call 方法入口与参数解析

### 1. call 函数签名

AgentTool 的核心执行逻辑位于 `call()` 方法中,定义在 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L239-L250):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
async call({
  prompt,
  subagent_type,
  description,
  model: modelParam,
  run_in_background,
  name,
  team_name,
  mode: spawnMode,
  isolation,
  cwd
}: AgentToolInput, toolUseContext, canUseTool, assistantMessage, onProgress?) {
```

`call` 方法接收完整的输入参数、工具使用上下文（`toolUseContext`）、权限检查函数（`canUseTool`）、当前助手消息（`assistantMessage`）和进度回调（`onProgress`）。

### 2. 初始状态获取与校验

方法入口处首先获取应用状态和权限模式,并进行多项前置校验,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L251-L280):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
const startTime = Date.now();
const model = isCoordinatorMode() ? undefined : modelParam;
const appState = toolUseContext.getAppState();
const permissionMode = appState.toolPermissionContext.mode;
const rootSetAppState = toolUseContext.setAppStateForTasks ?? toolUseContext.setAppState;

// 校验:团队功能是否可用
if (team_name && !isAgentSwarmsEnabled()) {
  throw new Error('Agent Teams is not yet available on your plan.');
}
// 校验:Teammate 不能再 spawn teammate
if (isTeammate() && teamName && name) {
  throw new Error('Teammates cannot spawn other teammates — the team roster is flat...');
}
// 校验:In-process teammate 不能 spawn 后台 agent
if (isInProcessTeammate() && teamName && run_in_background === true) {
  throw new Error('In-process teammates cannot spawn background agents...');
}
```

### 3. Teammate spawn 分支

当 `team_name` 和 `name` 同时存在时,进入 Teammate spawn 路径,调用 `spawnTeammate()` 而非普通子 Agent 路径,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L284-L316):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
if (teamName && name) {
  const agentDef = subagent_type ? toolUseContext.options.agentDefinitions.activeAgents
    .find(a => a.agentType === subagent_type) : undefined;
  if (agentDef?.color) {
    setAgentColor(subagent_type!, agentDef.color);
  }
  const result = await spawnTeammate({
    name, prompt, description, team_name: teamName,
    use_splitpane: true, plan_mode_required: spawnMode === 'plan',
    model: model ?? agentDef?.model, agent_type: subagent_type,
    invokingRequestId: assistantMessage?.requestId
  }, toolUseContext);
  // 返回 teammate_spawned 状态
  return { data: spawnResult };
}
```

## 二、 Agent 选择逻辑

### 1. subagent_type 解析与 Fork 路径

Agent 类型选择遵循明确的优先级规则,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L318-L356):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
// Fork subagent experiment routing:
// - subagent_type set: use it (explicit wins)
// - subagent_type omitted, gate on: fork path (undefined)
// - subagent_type omitted, gate off: default general-purpose
const effectiveType = subagent_type ?? (isForkSubagentEnabled() ? undefined : GENERAL_PURPOSE_AGENT.agentType);
const isForkPath = effectiveType === undefined;
```

三种路由策略:

- 显式指定 `subagent_type`：直接使用该类型
- 未指定且 Fork 实验开启：进入 Fork 路径（`undefined`）
- 未指定且 Fork 实验关闭：默认使用 `general-purpose`

### 2. Fork 递归保护

Fork 路径下有递归保护机制,防止 Fork 子进程再次 Fork,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L325-L334):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
if (isForkPath) {
  // Recursive fork guard: fork children keep the Agent tool in their
  // pool for cache-identical tool defs, so reject fork attempts at call time.
  if (toolUseContext.options.querySource === `agent:builtin:${FORK_AGENT.agentType}` 
      || isInForkChild(toolUseContext.messages)) {
    throw new Error('Fork is not available inside a forked worker...');
  }
  selectedAgent = FORK_AGENT;
}
```

### 3. 普通 Agent 查找与权限过滤

非 Fork 路径下,从已加载的 Agent 定义中查找匹配类型,并应用权限过滤,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L336-L356):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
const allAgents = toolUseContext.options.agentDefinitions.activeAgents;
const { allowedAgentTypes } = toolUseContext.options.agentDefinitions;
const agents = filterDeniedAgents(
  allowedAgentTypes ? allAgents.filter(a => allowedAgentTypes.includes(a.agentType)) : allAgents,
  appState.toolPermissionContext, AGENT_TOOL_NAME
);
const found = agents.find(agent => agent.agentType === effectiveType);
if (!found) {
  const agentExistsButDenied = allAgents.find(agent => agent.agentType === effectiveType);
  if (agentExistsButDenied) {
    throw new Error(`Agent type '${effectiveType}' has been denied by permission rule...`);
  }
  throw new Error(`Agent type '${effectiveType}' not found. Available agents: ${agents.map(a => a.agentType).join(', ')}`);
}
selectedAgent = found;
```

## 三、 权限与 MCP 服务器检查

### 1. MCP 服务器可用性检查

当 Agent 定义了 `requiredMcpServers` 时,会检查所需 MCP 服务器是否已连接且通过认证,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L367-L410):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
if (requiredMcpServers?.length) {
  // 等待 pending 的 MCP 服务器完成连接
  const hasPendingRequiredServers = appState.mcp.clients.some(c => 
    c.type === 'pending' && requiredMcpServers.some(pattern => 
      c.name.toLowerCase().includes(pattern.toLowerCase())));
  if (hasPendingRequiredServers) {
    const MAX_WAIT_MS = 30_000;
    const POLL_INTERVAL_MS = 500;
    const deadline = Date.now() + MAX_WAIT_MS;
    while (Date.now() < deadline) {
      await sleep(POLL_INTERVAL_MS);
      // ... 轮询检查连接状态
    }
  }
  // 检查服务器是否真正有工具可用（已连接 AND 已认证）
  if (!hasRequiredMcpServers(selectedAgent, serversWithTools)) {
    throw new Error(`Agent '${selectedAgent.agentType}' requires MCP servers matching: ${missing.join(', ')}...`);
  }
}
```

### 2. 隔离模式处理

Agent 支持两种隔离模式:`worktree`（临时 git worktree）和 `remote`（远程 CCR 环境）。`worktree` 隔离通过 `createAgentWorktree()` 创建,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L590-L593):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
let worktreeInfo = null;
if (effectiveIsolation === 'worktree') {
  const slug = `agent-${earlyAgentId.slice(0, 8)}`;
  worktreeInfo = await createAgentWorktree(slug);
}
```

## 四、 同步与异步执行

### 1. 启动后台运行的两种方式

启动后台运行子 Agent 有两种方式,均受 `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` 开关控制。

#### 1.1 显式设置 run_in_background

在调用 Agent 工具时传入 `run_in_background: true` 参数,主 Agent 可根据任务需要决定是否后台运行。该参数定义在输入 Schema 中,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L82-L88):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
const baseInputSchema = lazySchema(() => z.object({
  description: z.string().describe('A short (3-5 word) description of the task'),
  prompt: z.string().describe('The task for the agent to perform'),
  subagent_type: z.string().optional(),
  model: z.enum(['sonnet', 'opus', 'haiku']).optional(),
  run_in_background: z.boolean().optional().describe('Set to true to run this agent in the background. You will be notified when it completes.')
}));
```

LLM 调用示例:

```json
{
  "description": "Run test suite",
  "prompt": "Run the project's test suite and report failures...",
  "subagent_type": "general-purpose",
  "run_in_background": true
}
```

#### 1.2 Agent 定义中设置 background

在自定义 Agent 的 MD 文件 frontmatter 中设置 `background: true`,该 Agent 被 spawn 时**始终后台运行**,无需调用方显式指定。解析逻辑见 [`loadAgentsDir.ts`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L576-L591):

```typescript
// claude-code-source/src/tools/AgentTool/loadAgentsDir.ts
const backgroundRaw = frontmatter['background']
const background = backgroundRaw === 'true' || backgroundRaw === true ? true : undefined
```

MD 文件示例:

```markdown
---
name: test-runner
description: 运行测试套件并报告结果
background: true
---

你是一个测试运行 Agent...
```

内置的 Verification Agent 即采用此方式,始终后台运行。

#### 1.3 启动后的行为

后台启动后,主 Agent 立即收到 `async_launched` 返回值,包含 `agentId` 和 `outputFile` 路径。子 Agent 完成时,主 Agent 会收到一条 user-role 通知消息,无需轮询。完整的异步执行机制见本节后续小节。

### 2. 异步条件判定

Agent 的同步/异步执行模式由多个条件共同决定,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L556-L567):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
const forceAsync = isForkSubagentEnabled();
const assistantForceAsync = feature('KAIROS') ? appState.kairosEnabled : false;
const shouldRunAsync = (
  run_in_background === true || 
  selectedAgent.background === true || 
  isCoordinator || 
  forceAsync || 
  assistantForceAsync || 
  (proactiveModule?.isProactiveActive() ?? false)
) && !isBackgroundTasksDisabled;
```

触发异步执行的条件:

- 用户显式设置 `run_in_background: true`
- Agent 定义中 `background: true`
- Coordinator 模式
- Fork 子 Agent 实验开启（强制全部异步）
- Assistant 模式（KAIROS）
- Proactive 模式活跃

### 3. 异步执行路径

异步路径通过 `registerAsyncAgent()` 注册后台任务,然后在 `runWithAgentContext()` 中启动 `runAsyncAgentLifecycle()`,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L686-L764):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
if (shouldRunAsync) {
  const asyncAgentId = earlyAgentId;
  const agentBackgroundTask = registerAsyncAgent({
    agentId: asyncAgentId, description, prompt, selectedAgent,
    setAppState: rootSetAppState,
    toolUseId: toolUseContext.toolUseId
  });
  // 注册 name → agentId 映射,用于 SendMessage 路由
  if (name) {
    rootSetAppState(prev => {
      const next = new Map(prev.agentNameRegistry);
      next.set(name, asAgentId(asyncAgentId));
      return { ...prev, agentNameRegistry: next };
    });
  }
  void runWithAgentContext(asyncAgentContext, () => wrapWithCwd(() => runAsyncAgentLifecycle({
    taskId: agentBackgroundTask.agentId,
    abortController: agentBackgroundTask.abortController!,
    makeStream: onCacheSafeParams => runAgent({ ...runAgentParams, ... }),
    metadata, description, toolUseContext, rootSetAppState,
    agentIdForCleanup: asyncAgentId,
    enableSummarization: isCoordinator || isForkSubagentEnabled() || getSdkAgentProgressSummariesEnabled(),
    getWorktreeResult: cleanupWorktreeIfNeeded
  })));
  // 立即返回 async_launched 状态
  return { data: { isAsync: true, status: 'async_launched', agentId: ..., outputFile: ..., canReadOutputFile } };
}
```

异步路径的关键特点:

- 后台 Agent 拥有独立的 `AbortController`,不绑定父进程
- 用户按 ESC 取消主线程时,后台 Agent 不受影响
- 通过 `enqueueAgentNotification()` 在完成时通知
- 返回 `outputFile` 路径供调用方检查进度

### 4. 同步执行路径

同步路径在 `runWithAgentContext()` 中直接运行 `runAgent()`,并通过 `onProgress` 回调实时报告进度,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L765-L799):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
// 同步路径
return runWithAgentContext(syncAgentContext, () => wrapWithCwd(async () => {
  const agentMessages: MessageType[] = [];
  const agentStartTime = Date.now();
  const syncTracker = createProgressTracker();
  const syncResolveActivity = createActivityDescriptionResolver(toolUseContext.options.tools);
  // 通过 onProgress 回调向父进程报告进度
  if (promptMessages.length > 0 && onProgress) {
    onProgress({ toolUseID: `agent_${assistantMessage.message.id}`, data: { ... } });
  }
  // 运行 Agent 并收集消息
  for await (const message of runAgent({ ...runAgentParams, ... })) {
    agentMessages.push(message);
    // ... 更新进度
  }
  // 返回 completed 状态和完整结果
}));
```

### 5. 后台运行不阻塞主 Agent 的机制

异步路径通过多项设计确保子 Agent 在后台运行时完全不阻塞主 Agent,主 Agent 可继续响应其他用户请求或执行其他工作。

#### 5.1 立即返回 async_launched

主 Agent 调用 Agent 工具后,异步路径**不等子 Agent 完成**,立即返回 `async_launched` 状态,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L754-L764):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
return {
  data: {
    isAsync: true as const,
    status: 'async_launched' as const,
    agentId: agentBackgroundTask.agentId,
    description: description,
    prompt: prompt,
    outputFile: getTaskOutputPath(agentBackgroundTask.agentId),
    canReadOutputFile
  }
};
```

返回的 `outputFile` 路径供主 Agent 在需要时主动检查进度,但**不要求轮询**。

#### 5.2 独立的 AbortController

后台 Agent 拥有独立的 `AbortController`,**不绑定父进程**。因此用户按 ESC 取消主线程时,后台 Agent 不受影响,仅能通过 `chat:killAgents` 显式终止。这在注册时的注释中明确说明,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L688-L698):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
const agentBackgroundTask = registerAsyncAgent({
  agentId: asyncAgentId, description, prompt, selectedAgent,
  setAppState: rootSetAppState,
  // Don't link to parent's abort controller -- background agents should
  // survive when the user presses ESC to cancel the main thread.
  // They are killed explicitly via chat:killAgents.
  toolUseId: toolUseContext.toolUseId
});
```

#### 5.3 void 发射,不 await

后台执行通过 `void runWithAgentContext(...)` 发射,主 Agent 不会 `await` 它的完成,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L733-L752):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
void runWithAgentContext(asyncAgentContext, () => wrapWithCwd(() => runAsyncAgentLifecycle({
  taskId: agentBackgroundTask.agentId,
  abortController: agentBackgroundTask.abortController!,
  makeStream: onCacheSafeParams => runAgent({ ...runAgentParams, ... }),
  metadata, description, toolUseContext, rootSetAppState,
  agentIdForCleanup: asyncAgentId,
  enableSummarization: ...,
  getWorktreeResult: cleanupWorktreeIfNeeded
})));
```

`void` 关键字表示该 Promise 是 fire-and-forget,主 Agent 的 `call()` 方法在 `return` 语句处就结束,不等待后台任务。

#### 5.4 完成时异步通知

后台 Agent 完成后,通过 `enqueueAgentNotification()` 向主 Agent 发送通知,该通知作为后续 turn 的 user-role 消息到达,主 Agent 据此获知结果,见 [`agentToolUtils.ts`](../../claude-code-source/src/tools/AgentTool/agentToolUtils.ts#L624-L637):

```typescript
// claude-code-source/src/tools/AgentTool/agentToolUtils.ts
enqueueAgentNotification({
  taskId,
  description,
  status: 'completed',
  setAppState: rootSetAppState,
  finalMessage,
  usage: {
    totalTokens: getTokenCountFromTracker(tracker),
    toolUses: agentResult.totalToolUseCount,
    durationMs: agentResult.totalDurationMs,
  },
  toolUseId: toolUseContext.toolUseId,
  ...worktreeResult,
});
```

通知在 `runAsyncAgentLifecycle()` 内部触发,涵盖完成、被杀、失败三种状态:

| 状态 | 触发条件 | `finalMessage` |
| - | - | - |
| `completed` | Agent 正常完成 | 子 Agent 最后的文本输出 |
| `killed` | 用户通过 `chat:killAgents` 终止 | `extractPartialResult()` 提取的部分结果 |
| `failed` | Agent 抛出非 Abort 异常 | 错误信息 |

被杀和失败状态同样通过 `enqueueAgentNotification()` 通知,见 [`agentToolUtils.ts`](../../claude-code-source/src/tools/AgentTool/agentToolUtils.ts#L638-L681):

```typescript
// claude-code-source/src/tools/AgentTool/agentToolUtils.ts
if (error instanceof AbortError) {
  killAsyncAgent(taskId, rootSetAppState);
  const partialResult = extractPartialResult(agentMessages);
  enqueueAgentNotification({ taskId, status: 'killed', finalMessage: partialResult, ... });
  return;
}
failAsyncAgent(taskId, msg, rootSetAppState);
enqueueAgentNotification({ taskId, status: 'failed', error: msg, ... });
```

#### 5.5 通知机制与主 Agent 正在执行任务时的行为

##### 5.5.1 通知是异步排队的

通知以 **user-role 消息**的形式到达主 Agent,触发一个新的 turn。如果主 Agent 当前 turn 尚未结束（正在执行工具调用或生成回复）,通知会等待当前 turn 完成后,再作为新 turn 触发。这在 Fork 模式的提示词示例中有明确说明,见 [`prompt.ts`](../../claude-code-source/src/tools/AgentTool/prompt.ts#L126-L131):

```
assistant: Ship-readiness audit running.
<commentary>
Turn ends here. The coordinator knows nothing about the findings yet. What follows is a SEPARATE turn — the notification arrives from outside, as a user-role message. It is not something the coordinator writes.
</commentary>
[later turn — notification arrives as user message]
assistant: Audit's back. Three blockers: ...
```

##### 5.5.2 通知不打断主 Agent 当前 turn

通知**不会打断**主 Agent 当前正在执行的 turn。关键机制:

- 通知通过 `enqueueAgentNotification()` 入队,作为后续 turn 的 user-role 消息处理
- 如果主 Agent 当前 turn 正在执行,通知会等待当前 turn 完成后,再作为新 turn 触发
- 主 Agent 可通过 AppState 中的 task 状态感知后台任务仍在运行

##### 5.5.3 主 Agent 不应编造结果

提示词明确警告主 Agent 在通知到达前**不要编造或预测**后台 Agent 的结果,见 [`prompt.ts`](../../claude-code-source/src/tools/AgentTool/prompt.ts#L93):

```
**Don't race.** After launching, you know nothing about what the fork found. Never fabricate or predict fork results in any format — not as prose, summary, or structured output. The notification arrives as a user-role message in a later turn; it is never something you write yourself. If the user asks a follow-up before the notification lands, tell them the fork is still running — give status, not a guess.
```

##### 5.5.4 典型时序场景

```
Turn 1: 主 Agent 调用 Agent 工具（run_in_background: true）
        ├─ 后台 Agent 启动
        └─ 主 Agent 收到 async_launched,可以继续其他工作或回复用户

[后台 Agent 并行执行,主 Agent 可能进入 Turn 2、Turn 3...]

Turn N: 后台 Agent 完成
        ├─ enqueueAgentNotification() 入队通知
        └─ 如果主 Agent 当前 turn 正在执行 → 等待

Turn N+1: 通知作为 user-role 消息到达
          └─ 主 Agent 读取通知内容,向用户汇报结果
```

##### 5.5.5 用户中途询问的处理

如果用户在后台 Agent 仍在运行时询问进度,主 Agent 应给出状态而非猜测结果:

```
用户: "so is the gate wired up or not"
主 Agent: Still waiting on the audit — that's one of the things it's checking. Should land shortly.
```

主 Agent 知道后台任务仍在运行（通过 AppState 中的 task 状态）,但不知道具体发现,直到通知到达。

#### 5.6 同步 vs 异步对比

| 维度 | 同步（默认） | 异步（`run_in_background: true`） |
| - | - | - |
| 阻塞主 Agent | 是,等待子 Agent 完成才返回结果 | 否,立即返回 `async_launched` |
| AbortController | 共享父进程的 | 独立的,ESC 不影响 |
| 结果获取 | `call()` 直接返回 `completed` | 通过通知消息异步获取 |
| 进度检查 | `onProgress` 回调实时推送 | 通过 `outputFile` 路径读取 |
| 主 Agent 可继续工作 | 否 | 是 |

#### 5.7 后台功能的禁用

后台功能可通过环境变量 `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` 禁用。此时 `run_in_background` 参数会从 Schema 中被 `.omit()` 移除,LLM 看不到该参数,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L122-L125):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
return isBackgroundTasksDisabled || isForkSubagentEnabled() ? schema.omit({
  run_in_background: true
}) : schema;
```

另外,Fork 子 Agent 实验开启时也会移除该参数,因为 Fork 路径会强制所有 Agent 异步运行,无需再显式指定。

## 五、 runAgent 核心执行引擎

### 1. runAgent 函数签名

`runAgent()` 是子 Agent 的核心执行引擎,定义在 [`runAgent.ts`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L248-L329),它是一个异步生成器,逐条 yield Agent 产生的消息:

```typescript
// claude-code-source/src/tools/AgentTool/runAgent.ts
export async function* runAgent({
  agentDefinition,
  promptMessages,
  toolUseContext,
  canUseTool,
  isAsync,
  canShowPermissionPrompts,
  forkContextMessages,
  querySource,
  override,
  model,
  maxTurns,
  preserveToolUseResults,
  availableTools,
  allowedTools,
  onCacheSafeParams,
  contentReplacementState,
  useExactTools,
  worktreePath,
  description,
  transcriptSubdir,
  onQueryProgress,
}): AsyncGenerator<Message, void> {
```

### 2. 上下文构建

`runAgent` 的核心职责是构建子 Agent 的完整运行上下文,包括系统提示词、工具池、权限模式、MCP 服务器等。

#### 2.1 权限模式覆盖

子 Agent 的权限模式可以由 Agent 定义覆盖,但有优先级规则,见 [`runAgent.ts`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L415-L498):

```typescript
// claude-code-source/src/tools/AgentTool/runAgent.ts
const agentPermissionMode = agentDefinition.permissionMode;
const agentGetAppState = () => {
  const state = toolUseContext.getAppState();
  let toolPermissionContext = state.toolPermissionContext;
  // 覆盖权限模式（除非父进程是 bypassPermissions / acceptEdits / auto）
  if (agentPermissionMode &&
      state.toolPermissionContext.mode !== 'bypassPermissions' &&
      state.toolPermissionContext.mode !== 'acceptEdits' &&
      !(feature('TRANSCRIPT_CLASSIFIER') && state.toolPermissionContext.mode === 'auto')) {
    toolPermissionContext = { ...toolPermissionContext, mode: agentPermissionMode };
  }
  // 异步 Agent 不能显示 UI,自动拒绝权限提示
  const shouldAvoidPrompts = canShowPermissionPrompts !== undefined
    ? !canShowPermissionPrompts
    : agentPermissionMode === 'bubble' ? false : isAsync;
  if (shouldAvoidPrompts) {
    toolPermissionContext = { ...toolPermissionContext, shouldAvoidPermissionPrompts: true };
  }
  return { ...state, toolPermissionContext };
};
```

#### 2.2 工具池解析

子 Agent 的工具池通过 `resolveAgentTools()` 解析,该函数根据 Agent 定义的 `tools`/`disallowedTools` 列表和全局限制规则进行过滤,见 [`agentToolUtils.ts`](../../claude-code-source/src/tools/AgentTool/agentToolUtils.ts#L122-L225):

```typescript
// claude-code-source/src/tools/AgentTool/agentToolUtils.ts
export function resolveAgentTools(
  agentDefinition, availableTools, isAsync = false, isMainThread = false
): ResolvedAgentTools {
  const filteredAvailableTools = isMainThread
    ? availableTools
    : filterToolsForAgent({ tools: availableTools, isBuiltIn: source === 'built-in', isAsync, permissionMode });
  // ... 处理 disallowedTools
  const hasWildcard = agentTools === undefined || (agentTools.length === 1 && agentTools[0] === '*');
  if (hasWildcard) {
    return { hasWildcard: true, validTools: [], invalidTools: [], resolvedTools: allowedAvailableTools };
  }
  // ... 逐个解析 toolSpec
}
```

#### 2.3 工具过滤规则

`filterToolsForAgent()` 定义了子 Agent 的工具限制规则,见 [`agentToolUtils.ts`](../../claude-code-source/src/tools/AgentTool/agentToolUtils.ts#L70-L116):

```typescript
// claude-code-source/src/tools/AgentTool/agentToolUtils.ts
export function filterToolsForAgent({ tools, isBuiltIn, isAsync, permissionMode }): Tools {
  return tools.filter(tool => {
    if (tool.name.startsWith('mcp__')) return true;  // MCP 工具对所有 Agent 开放
    if (toolMatchesName(tool, EXIT_PLAN_MODE_V2_TOOL_NAME) && permissionMode === 'plan') return true;
    if (ALL_AGENT_DISALLOWED_TOOLS.has(tool.name)) return false;
    if (!isBuiltIn && CUSTOM_AGENT_DISALLOWED_TOOLS.has(tool.name)) return false;
    if (isAsync && !ASYNC_AGENT_ALLOWED_TOOLS.has(tool.name)) {
      // in-process teammate 的特殊允许逻辑
      return false;
    }
    return true;
  });
}
```

工具限制集合定义在 [`constants/tools.ts`](../../claude-code-source/src/constants/tools.ts#L36-L88) 中:

- `ALL_AGENT_DISALLOWED_TOOLS`：所有 Agent 都禁止的工具（TaskOutput、ExitPlanMode、AskUserQuestion 等）
- `ASYNC_AGENT_ALLOWED_TOOLS`：异步 Agent 仅允许的工具白名单（Read、Write、Edit、Bash、Glob、Grep 等）
- `IN_PROCESS_TEAMMATE_ALLOWED_TOOLS`：In-process teammate 额外允许的工具（TaskCreate、SendMessage 等）

### 3. 查询循环与消息记录

`runAgent` 的核心是一个 `query()` 查询循环,逐条处理 LLM 返回的消息并 yield 给调用方,见 [`runAgent.ts`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L747-L815):

```typescript
// claude-code-source/src/tools/AgentTool/runAgent.ts
try {
  for await (const message of query({
    messages: initialMessages,
    systemPrompt: agentSystemPrompt,
    userContext: resolvedUserContext,
    systemContext: resolvedSystemContext,
    canUseTool,
    toolUseContext: agentToolUseContext,
    querySource,
    maxTurns: maxTurns ?? agentDefinition.maxTurns,
  })) {
    onQueryProgress?.();
    // 转发 API 请求开始事件
    if (message.type === 'stream_event' && message.event.type === 'message_start' && message.ttftMs != null) {
      toolUseContext.pushApiMetricsEntry?.(message.ttftMs);
      continue;
    }
    // yield 附件消息
    if (message.type === 'attachment') {
      if (message.attachment.type === 'max_turns_reached') break;
      yield message;
      continue;
    }
    // 记录可记录的消息
    if (isRecordableMessage(message)) {
      await recordSidechainTranscript([message], agentId, lastRecordedUuid);
      if (message.type !== 'progress') lastRecordedUuid = message.uuid;
      yield message;
    }
  }
  // 运行回调（仅内置 Agent 有回调）
  if (isBuiltInAgent(agentDefinition) && agentDefinition.callback) {
    agentDefinition.callback();
  }
}
```

## 六、 子 Agent 上下文构建

### 1. createSubagentContext

子 Agent 的上下文通过 `createSubagentContext()` 创建,它基于父进程的上下文进行克隆或隔离,见 [`runAgent.ts`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L700-L719):

```typescript
// claude-code-source/src/tools/AgentTool/runAgent.ts
const agentToolUseContext = createSubagentContext(toolUseContext, {
  options: agentOptions,
  agentId,
  agentType: agentDefinition.agentType,
  messages: initialMessages,
  readFileState: agentReadFileState,
  abortController: agentAbortController,
  getAppState: agentGetAppState,
  shareSetAppState: !isAsync,      // 同步 Agent 共享父进程的 setAppState
  shareSetResponseLength: true,     // 两者都贡献响应指标
  criticalSystemReminder_EXPERIMENTAL: agentDefinition.criticalSystemReminder_EXPERIMENTAL,
  contentReplacementState,
});
```

同步与异步 Agent 的上下文隔离差异:

- 同步 Agent：共享父进程的 `setAppState`、`abortController`，阻塞父进程直到完成
- 异步 Agent：完全隔离,拥有独立的 `AbortController`,不阻塞父进程

### 2. Fork 路径的上下文继承

Fork 子 Agent 继承父进程的完整对话上下文和系统提示词,以实现缓存共享,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L483-L541):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
if (isForkPath) {
  // Fork 路径:继承父进程已渲染的系统提示词（缓存一致）
  if (toolUseContext.renderedSystemPrompt) {
    forkParentSystemPrompt = toolUseContext.renderedSystemPrompt;
  } else {
    // 回退:重新计算（可能与父进程缓存不一致）
    forkParentSystemPrompt = buildEffectiveSystemPrompt({ ... });
  }
  promptMessages = buildForkedMessages(prompt, assistantMessage);
} else {
  // 普通路径:构建 Agent 自身的系统提示词
  const agentPrompt = selectedAgent.getSystemPrompt({ toolUseContext });
  enhancedSystemPrompt = await enhanceSystemPromptWithEnvDetails([agentPrompt], ...);
  promptMessages = [createUserMessage({ content: prompt })];
}
```

### 3. 精简上下文优化

只读 Agent（Explore、Plan）会精简上下文以节省 token,见 [`runAgent.ts`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L385-L410):

```typescript
// claude-code-source/src/tools/AgentTool/runAgent.ts
// Explore/Plan 不需要 CLAUDE.md 中的 commit/PR/lint 规则
const shouldOmitClaudeMd = agentDefinition.omitClaudeMd &&
  !override?.userContext &&
  getFeatureValue_CACHED_MAY_BE_STALE('tengu_slim_subagent_claudemd', true);
const { claudeMd: _omittedClaudeMd, ...userContextNoClaudeMd } = baseUserContext;

// Explore/Plan 也不需要会话开始时的 gitStatus（最多 40KB,且已过时）
const { gitStatus: _omittedGitStatus, ...systemContextNoGit } = baseSystemContext;
const resolvedSystemContext = (agentDefinition.agentType === 'Explore' || agentDefinition.agentType === 'Plan')
  ? systemContextNoGit : baseSystemContext;
```

## 七、 生命周期管理

### 1. 异步 Agent 生命周期

异步 Agent 的完整生命周期由 `runAsyncAgentLifecycle()` 驱动,定义在 [`agentToolUtils.ts`](../../claude-code-source/src/tools/AgentTool/agentToolUtils.ts#L508-L686):

```typescript
// claude-code-source/src/tools/AgentTool/agentToolUtils.ts
export async function runAsyncAgentLifecycle({ taskId, abortController, makeStream, metadata, ... }) {
  let stopSummarization;
  const agentMessages = [];
  try {
    const tracker = createProgressTracker();
    const onCacheSafeParams = enableSummarization ? (params) => {
      const { stop } = startAgentSummarization(taskId, asAgentId(taskId), params, rootSetAppState);
      stopSummarization = stop;
    } : undefined;
    // 消费 Agent 消息流
    for await (const message of makeStream(onCacheSafeParams)) {
      agentMessages.push(message);
      updateProgressFromMessage(tracker, message, resolveActivity, toolUseContext.options.tools);
      updateAsyncAgentProgress(taskId, getProgressUpdate(tracker), rootSetAppState);
      // 发射进度事件
      const lastToolName = getLastToolUseName(message);
      if (lastToolName) emitTaskProgress(tracker, taskId, ...);
    }
    stopSummarization?.();
    const agentResult = finalizeAgentTool(agentMessages, taskId, metadata);
    completeAsyncAgent(agentResult, rootSetAppState);  // 先标记完成
    // ... 交接分类器检查、worktree 清理
    enqueueAgentNotification({ taskId, description, status: 'completed', ... });
  } catch (error) {
    if (error instanceof AbortError) {
      killAsyncAgent(taskId, rootSetAppState);
      const partialResult = extractPartialResult(agentMessages);
      enqueueAgentNotification({ taskId, status: 'killed', finalMessage: partialResult, ... });
      return;
    }
    failAsyncAgent(taskId, msg, rootSetAppState);
    enqueueAgentNotification({ taskId, status: 'failed', error: msg, ... });
  } finally {
    clearInvokedSkillsForAgent(agentIdForCleanup);
    clearDumpState(agentIdForCleanup);
  }
}
```

### 2. 资源清理

`runAgent` 在 `finally` 块中进行全面的资源清理,见 [`runAgent.ts`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L816-L859):

```typescript
// claude-code-source/src/tools/AgentTool/runAgent.ts
finally {
  await mcpCleanup();                          // 清理 Agent 专属 MCP 服务器
  if (agentDefinition.hooks) clearSessionHooks(rootSetAppState, agentId);  // 清理会话 Hook
  if (feature('PROMPT_CACHE_BREAK_DETECTION')) cleanupAgentTracking(agentId);
  agentToolUseContext.readFileState.clear();   // 释放文件状态缓存
  initialMessages.length = 0;                   // 释放 Fork 上下文消息
  unregisterPerfettoAgent(agentId);             // 释放 Perfetto 追踪
  clearAgentTranscriptSubdir(agentId);          // 释放 transcript 子目录映射
  // 清理 Agent 的 todos 条目（防止内存泄漏）
  rootSetAppState(prev => {
    if (!(agentId in prev.todos)) return prev;
    const { [agentId]: _removed, ...todos } = prev.todos;
    return { ...prev, todos };
  });
  // 终止 Agent 生成的后台 shell 任务
  killShellTasksForAgent(agentId, toolUseContext.getAppState, rootSetAppState);
}
```

### 3. Worktree 清理

当使用 `isolation: "worktree"` 时,Agent 完成后会检查 worktree 是否有变更,无变更则自动清理,见 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L644-L685):

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
const cleanupWorktreeIfNeeded = async () => {
  if (!worktreeInfo) return {};
  worktreeInfo = null;  // 幂等保护
  if (hookBased) return { worktreePath };  // Hook-based worktree 总是保留
  if (headCommit) {
    const changed = await hasWorktreeChanges(worktreePath, headCommit);
    if (!changed) {
      await removeAgentWorktree(worktreePath, worktreeBranch, gitRoot);
      // 清理 metadata 中的 worktreePath,防止 resume 引用已删除目录
      void writeAgentMetadata(asAgentId(earlyAgentId), { agentType, description });
      return {};
    }
  }
  return { worktreePath, worktreeBranch };  // 有变更则保留
};
```

---

*本文档由 markdowncli 技能辅助生成*

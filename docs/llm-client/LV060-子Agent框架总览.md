<!-- more -->

## 一、 概述

Claude Code 的子 Agent 框架允许主 Agent 通过调用 `Agent` 工具生成子 Agent，将复杂任务委托给专业化的子进程自主执行。本文档深入分析子 Agent 框架的总体架构、核心类型体系、Agent 工具入口的完整路由逻辑、内置 Agent 定义、Fork 子 Agent 机制，以及 `runAgent()` 运行时的完整生命周期。

## 二、 核心架构

子 Agent 框架由以下核心组件构成：

- **Agent 工具入口** — LLM 通过调用 `Agent` 工具生成子 Agent
- **Agent 定义体系** — 内置 Agent、自定义 Agent（`.md` 文件）、插件 Agent
- **发现/扫描机制** — 从多个目录扫描 `.md` 文件加载 Agent 定义（详见 [LV061](LV061-自定义Agent的MD文件定义与发现.md)）
- **Prompt 注入机制** — 通过工具描述 + 附件消息（`agent_listing_delta`）将 Agent 列表注入 LLM 上下文（详见 [LV062](LV062-子Agent提示词注入与LLM选择机制.md)）
- **运行时** — [`runAgent()`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L248) 异步生成器驱动子 Agent 的完整生命周期

### 1. 核心源码文件

| 文件 | 职责 |
|------|------|
| [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx) | Agent 工具定义、`call()` 路由、同步/异步生命周期 |
| [`runAgent.ts`](../../claude-code-source/src/tools/AgentTool/runAgent.ts) | 子 Agent 运行时：系统提示词构建、工具解析、上下文管理 |
| [`prompt.ts`](../../claude-code-source/src/tools/AgentTool/prompt.ts) | Agent 工具描述生成、Agent 列表格式化 |
| [`loadAgentsDir.ts`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts) | Agent 定义类型、MD 文件解析、去重合并 |
| [`forkSubagent.ts`](../../claude-code-source/src/tools/AgentTool/forkSubagent.ts) | Fork 子 Agent 特性：消息构建、递归防护 |
| [`agentToolUtils.ts`](../../claude-code-source/src/tools/AgentTool/agentToolUtils.ts) | 工具解析、结果聚合、异步 Agent 生命周期 |
| [`builtInAgents.ts`](../../claude-code-source/src/tools/AgentTool/builtInAgents.ts) | 内置 Agent 注册表 |
| [`constants.ts`](../../claude-code-source/src/tools/AgentTool/constants.ts) | 工具名称常量、一次性 Agent 类型集合 |

## 三、Agent 工具定义

### 1. 工具名称与别名

定义在 [`src/tools/AgentTool/constants.ts`](../../claude-code-source/src/tools/AgentTool/constants.ts#L1-L3)：

```typescript
// src/tools/AgentTool/constants.ts
export const AGENT_TOOL_NAME = 'Agent'
export const LEGACY_AGENT_TOOL_NAME = 'Task'  // 向后兼容
```

### 2. 输入 Schema

定义在 [`src/tools/AgentTool/AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L82-L125)：

#### 2.1 基础 Schema（baseInputSchema）

```typescript
// src/tools/AgentTool/AgentTool.tsx#L82-L88
const baseInputSchema = lazySchema(() => z.object({
  description: z.string().describe('A short (3-5 word) description of the task'),
  prompt: z.string().describe('The task for the agent to perform'),
  subagent_type: z.string().optional().describe('The type of specialized agent to use'),
  model: z.enum(['sonnet', 'opus', 'haiku']).optional().describe("Optional model override..."),
  run_in_background: z.boolean().optional().describe('Set to true to run in background')
}));
```

#### 2.2 完整 Schema（fullInputSchema）

在基础 Schema 上合并多 Agent 参数：

```typescript
// src/tools/AgentTool/AgentTool.tsx#L91-L102
const fullInputSchema = lazySchema(() => {
  const multiAgentInputSchema = z.object({
    name: z.string().optional().describe('Name for the spawned agent...'),
    team_name: z.string().optional().describe('Team name for spawning...'),
    mode: permissionModeSchema().optional().describe('Permission mode for teammate...')
  });
  return baseInputSchema().merge(multiAgentInputSchema).extend({
    isolation: z.enum(['worktree']).optional(),
    cwd: z.string().optional().describe('Absolute path to run the agent in...')
  });
});
```

#### 2.3 Schema 条件裁剪

通过 `.omit()` 在特性关闭时移除参数，避免 LLM 看到不可用的参数：

```typescript
// src/tools/AgentTool/AgentTool.tsx#L110-L125
export const inputSchema = lazySchema(() => {
  const schema = feature('KAIROS') ? fullInputSchema() : fullInputSchema().omit({ cwd: true });
  // Fork 开启或后台任务禁用时，移除 run_in_background 参数
  return isBackgroundTasksDisabled || isForkSubagentEnabled()
    ? schema.omit({ run_in_background: true })
    : schema;
});
```

### 3. 输出 Schema

```typescript
// src/tools/AgentTool/AgentTool.tsx#L141-L155
export const outputSchema = lazySchema(() => {
  const syncOutputSchema = agentToolResultSchema().extend({
    status: z.literal('completed'),
    prompt: z.string()
  });
  const asyncOutputSchema = z.object({
    status: z.literal('async_launched'),
    agentId: z.string(),
    description: z.string(),
    prompt: z.string(),
    outputFile: z.string(),
    canReadOutputFile: z.boolean().optional()
  });
  return z.union([syncOutputSchema, asyncOutputSchema]);
});
```

### 4.call() 方法核心路由

[`call()`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L239) 方法是 Agent 工具的核心入口，包含多层路由逻辑：

#### 4.1 多 Agent 团队生成

当 `team_name` + `name` 组合出现时，触发 [`spawnTeammate()`](../../claude-code-source/src/tools/shared/spawnMultiAgent.ts)：

```typescript
// src/tools/AgentTool/AgentTool.tsx#L284-L316
if (teamName && name) {
  const agentDef = subagent_type
    ? toolUseContext.options.agentDefinitions.activeAgents.find(a => a.agentType === subagent_type)
    : undefined;
  if (agentDef?.color) {
    setAgentColor(subagent_type!, agentDef.color);
  }
  const result = await spawnTeammate({
    name, prompt, description, team_name: teamName,
    use_splitpane: true,
    plan_mode_required: spawnMode === 'plan',
    model: model ?? agentDef?.model,
    agent_type: subagent_type,
    invokingRequestId: assistantMessage?.requestId
  }, toolUseContext);
  // 返回 teammate_spawned 状态
}
```

防护措施：队友不能生成其他队友，进程内队友不能生成后台 Agent：

```typescript
// src/tools/AgentTool/AgentTool.tsx#L272-L280
if (isTeammate() && teamName && name) {
  throw new Error('Teammates cannot spawn other teammates...');
}
if (isInProcessTeammate() && teamName && run_in_background === true) {
  throw new Error('In-process teammates cannot spawn background agents...');
}
```

#### 4.2 Fork 子 Agent 路由

当 Fork 实验特性开启且 `subagent_type` 省略时，进入 Fork 路径：

```typescript
// src/tools/AgentTool/AgentTool.tsx#L318-L336
const effectiveType = subagent_type ?? (isForkSubagentEnabled() ? undefined : GENERAL_PURPOSE_AGENT.agentType);
const isForkPath = effectiveType === undefined;
if (isForkPath) {
  // 递归 Fork 防护：检查 querySource 和消息历史
  if (toolUseContext.options.querySource === `agent:builtin:${FORK_AGENT.agentType}` ||
      isInForkChild(toolUseContext.messages)) {
    throw new Error('Fork is not available inside a forked worker...');
  }
  selectedAgent = FORK_AGENT;
}
```

#### 4.3 指定类型 Agent 查找

当 `subagent_type` 明确指定时，从活跃 Agent 列表中查找匹配项：

```typescript
// src/tools/AgentTool/AgentTool.tsx#L337-L356
const allAgents = toolUseContext.options.agentDefinitions.activeAgents;
const { allowedAgentTypes } = toolUseContext.options.agentDefinitions;
const agents = filterDeniedAgents(
  allowedAgentTypes ? allAgents.filter(a => allowedAgentTypes.includes(a.agentType)) : allAgents,
  appState.toolPermissionContext, AGENT_TOOL_NAME
);
const found = agents.find(agent => agent.agentType === effectiveType);
if (!found) {
  // 检查是否被权限规则拒绝
  const agentExistsButDenied = allAgents.find(agent => agent.agentType === effectiveType);
  if (agentExistsButDenied) {
    const denyRule = getDenyRuleForAgent(appState.toolPermissionContext, AGENT_TOOL_NAME, effectiveType);
    throw new Error(`Agent type '${effectiveType}' has been denied by permission rule...`);
  }
  throw new Error(`Agent type '${effectiveType}' not found. Available agents: ${agents.map(a => a.agentType).join(', ')}`);
}
selectedAgent = found;
```

#### 4.4 MCP 服务器需求检查

如果 Agent 定义了 `requiredMcpServers`，`call()` 会等待 MCP 服务器连接完成，再验证其工具可用性：

```typescript
// src/tools/AgentTool/AgentTool.tsx#L371-L410
if (requiredMcpServers?.length) {
  // 等待 pending 服务器连接（最多 30 秒）
  const hasPendingRequiredServers = appState.mcp.clients.some(
    c => c.type === 'pending' && requiredMcpServers.some(...)
  );
  if (hasPendingRequiredServers) {
    const MAX_WAIT_MS = 30_000;
    const POLL_INTERVAL_MS = 500;
    // ... 轮询等待 ...
  }
  // 验证所需 MCP 服务器是否有工具可用
  if (!hasRequiredMcpServers(selectedAgent, serversWithTools)) {
    throw new Error(`Agent '${selectedAgent.agentType}' requires MCP servers matching: ${missing.join(', ')}...`);
  }
}
```

#### 4.5 系统提示词与消息构建

Fork 路径和普通路径采用不同的系统提示词和消息构建策略：

```typescript
// src/tools/AgentTool/AgentTool.tsx#L492-L541
if (isForkPath) {
  // Fork：继承父 Agent 已渲染的系统提示词（byte-identical，最大化缓存命中）
  forkParentSystemPrompt = toolUseContext.renderedSystemPrompt
    ?? /* fallback: 重新计算 */ buildEffectiveSystemPrompt({...});
  // 消息：克隆父助手消息 + 占位 tool_result + 子进程指令
  promptMessages = buildForkedMessages(prompt, assistantMessage);
} else {
  // 普通：使用 Agent 自身的 getSystemPrompt() + 环境增强
  const agentPrompt = selectedAgent.getSystemPrompt({ toolUseContext });
  enhancedSystemPrompt = await enhanceSystemPromptWithEnvDetails([agentPrompt], ...);
  // 消息：简单的用户消息
  promptMessages = [createUserMessage({ content: prompt })];
}
```

#### 4.6 同步/异步决策

```typescript
// src/tools/AgentTool/AgentTool.tsx#L557-L567
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

#### 4.7 工具池组装

子 Agent 拥有独立的工具池，不受父 Agent 工具限制影响：

```typescript
// src/tools/AgentTool/AgentTool.tsx#L573-L577
const workerPermissionContext = {
  ...appState.toolPermissionContext,
  mode: selectedAgent.permissionMode ?? 'acceptEdits'
};
const workerTools = assembleToolPool(workerPermissionContext, appState.mcp.tools);
```

#### 4.8 Worktree 隔离

当请求 `isolation: "worktree"` 时，为 Agent 创建临时 Git Worktree：

```typescript
// src/tools/AgentTool/AgentTool.tsx#L582-L602
if (effectiveIsolation === 'worktree') {
  const slug = `agent-${earlyAgentId.slice(0, 8)}`;
  worktreeInfo = await createAgentWorktree(slug);
}
// Fork + Worktree：注入路径翻译通知
if (isForkPath && worktreeInfo) {
  promptMessages.push(createUserMessage({
    content: buildWorktreeNotice(getCwd(), worktreeInfo.worktreePath)
  }));
}
```

Worktree 清理逻辑：Agent 完成后，如果没有文件变更则自动删除 Worktree；有变更则保留并返回分支信息。

## 四、Agent 定义类型体系

定义在 [`src/tools/AgentTool/loadAgentsDir.ts`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L106-L165)：

### 1. 基础类型 BaseAgentDefinition

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L106-L133
type BaseAgentDefinition = {
  agentType: string              // Agent 类型标识符
  whenToUse: string              // 何时使用的描述（注入 LLM 上下文用于选择）
  tools?: string[]               // 允许的工具列表
  disallowedTools?: string[]     // 禁用的工具列表
  skills?: string[]              // 预加载的技能
  mcpServers?: AgentMcpServerSpec[]  // MCP 服务器
  hooks?: HooksSettings          // 生命周期钩子
  color?: AgentColorName         // UI 颜色
  model?: string                 // 模型覆盖
  effort?: EffortValue           // 思考努力级别
  permissionMode?: PermissionMode
  maxTurns?: number              // 最大轮次
  background?: boolean           // 始终后台运行
  initialPrompt?: string         // 初始提示
  memory?: AgentMemoryScope      // 持久化记忆范围
  isolation?: 'worktree'|'remote'  // 隔离模式
  omitClaudeMd?: boolean         // 是否省略 CLAUDE.md
  filename?: string              // 原始文件名（不含 .md）
  baseDir?: string               // 基础目录
  criticalSystemReminder_EXPERIMENTAL?: string  // 每轮重注入的提醒
  requiredMcpServers?: string[]  // 所需 MCP 服务器名称模式
  pendingSnapshotUpdate?: { snapshotTimestamp: string }
}
```

### 2. 三种具体 Agent 类型

| 类型 | 定义 | 来源 | `getSystemPrompt` | 特有字段 |
|------|------|------|-------------------|----------|
| [`BuiltInAgentDefinition`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L136-L143) | `source: 'built-in'` | 代码内置 | 动态 `(params) => string` | `callback?: () => void` |
| [`CustomAgentDefinition`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L146-L151) | `source: SettingSource` | .md 文件或 JSON 设置 | 闭包 `() => string` | `filename`, `baseDir` |
| [`PluginAgentDefinition`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L154-L159) | `source: 'plugin'` | 插件目录 | 闭包 `() => string` | `plugin: string` |

类型守卫函数：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L168-L184
export function isBuiltInAgent(agent: AgentDefinition): agent is BuiltInAgentDefinition {
  return agent.source === 'built-in'
}
export function isCustomAgent(agent: AgentDefinition): agent is CustomAgentDefinition {
  return agent.source !== 'built-in' && agent.source !== 'plugin'
}
export function isPluginAgent(agent: AgentDefinition): agent is PluginAgentDefinition {
  return agent.source === 'plugin'
}
```

### 3. 优先级与去重

[`getActiveAgentsFromList()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L193-L221) 按优先级合并 Agent：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L193-L221
export function getActiveAgentsFromList(allAgents: AgentDefinition[]): AgentDefinition[] {
  const builtInAgents = allAgents.filter(a => a.source === 'built-in')
  const pluginAgents = allAgents.filter(a => a.source === 'plugin')
  const userAgents = allAgents.filter(a => a.source === 'userSettings')
  const projectAgents = allAgents.filter(a => a.source === 'projectSettings')
  const managedAgents = allAgents.filter(a => a.source === 'policySettings')
  const flagAgents = allAgents.filter(a => a.source === 'flagSettings')

  const agentGroups = [
    builtInAgents,     // 最高优先级
    pluginAgents,
    userAgents,
    projectAgents,
    flagAgents,
    managedAgents,     // 最低优先级
  ]

  const agentMap = new Map<string, AgentDefinition>()
  // 后出现的同名 agentType 覆盖先出现的 → 低优先级可被高优先级覆盖
  for (const agents of agentGroups) {
    for (const agent of agents) {
      agentMap.set(agent.agentType, agent)
    }
  }
  return Array.from(agentMap.values())
}
```

【**注意**】优先级规则：内置 > 插件 > 用户 > 项目 > 标志 > 策略。后写入 Map 的同名 `agentType` 会覆盖先写入的，因此**优先级最低的组最后写入**，意味着实际生效的是优先级最低的。这是因为 `getActiveAgentsFromList` 的设计是"最后写入者胜出"，所以 `managedAgents`（策略）最后写入会覆盖一切——但这只适用于同名 `agentType` 的情况。

### 4. MCP 服务器需求过滤

[`filterAgentsByMcpRequirements()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L250-L255) 移除所需 MCP 服务器未连接的 Agent：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L229-L242
export function hasRequiredMcpServers(agent: AgentDefinition, availableServers: string[]): boolean {
  if (!agent.requiredMcpServers || agent.requiredMcpServers.length === 0) return true
  // 每个所需模式必须匹配至少一个可用服务器（大小写不敏感）
  return agent.requiredMcpServers.every(pattern =>
    availableServers.some(server =>
      server.toLowerCase().includes(pattern.toLowerCase())
    )
  )
}
```

## 五、内置 Agent

### 1. 获取内置 Agent 列表

[`getBuiltInAgents()`](../../claude-code-source/src/tools/AgentTool/builtInAgents.ts#L22-L72) 返回当前可用的内置 Agent：

```typescript
// src/tools/AgentTool/builtInAgents.ts#L45-L71
const agents: AgentDefinition[] = [
  GENERAL_PURPOSE_AGENT,        // 通用多步任务
  STATUSLINE_SETUP_AGENT,       // 状态栏设置
]
if (areExplorePlanAgentsEnabled()) {
  agents.push(EXPLORE_AGENT, PLAN_AGENT)  // 代码探索、架构规划
}
if (isNonSdkEntrypoint) {
  agents.push(CLAUDE_CODE_GUIDE_AGENT)    // Claude Code 使用指南
}
if (feature('VERIFICATION_AGENT') && ...) {
  agents.push(VERIFICATION_AGENT)          // 验证 Agent
}
```

### 2. 内置 Agent 一览

| Agent | agentType | 用途 | 工具 | 模型 | 定义文件 |
|-------|-----------|------|------|------|----------|
| General Purpose | `general-purpose` | 通用多步任务 | `*`（所有） | 默认 | [`generalPurposeAgent.ts`](../../claude-code-source/src/tools/AgentTool/built-in/generalPurposeAgent.ts#L25-L34) |
| Explore | `Explore` | 代码库搜索/探索（只读） | 禁用写入工具 | `haiku`/`inherit` | [`exploreAgent.ts`](../../claude-code-source/src/tools/AgentTool/built-in/exploreAgent.ts#L64-L83) |
| Plan | `Plan` | 架构设计/规划（只读） | 同 Explore | `inherit` | [`planAgent.ts`](../../claude-code-source/src/tools/AgentTool/built-in/planAgent.ts#L73-L92) |
| Statusline Setup | （statusline） | 状态栏设置 | 有限 | - | [`statuslineSetup.ts`](../../claude-code-source/src/tools/AgentTool/built-in/statuslineSetup.ts) |
| Claude Code Guide | `claude-code-guide` | 帮助用户使用 Claude Code | 搜索 + Web | - | [`claudeCodeGuideAgent.ts`](../../claude-code-source/src/tools/AgentTool/built-in/claudeCodeGuideAgent.ts) |
| Verification | `verification` | 验证实现正确性 | 有限工具 | - | [`verificationAgent.ts`](../../claude-code-source/src/tools/AgentTool/built-in/verificationAgent.ts) |

### 3. General Purpose Agent 详解

```typescript
// src/tools/AgentTool/built-in/generalPurposeAgent.ts#L25-L34
export const GENERAL_PURPOSE_AGENT: BuiltInAgentDefinition = {
  agentType: 'general-purpose',
  whenToUse: 'General-purpose agent for researching complex questions, searching for code, and executing multi-step tasks...',
  tools: ['*'],
  source: 'built-in',
  baseDir: 'built-in',
  getSystemPrompt: getGeneralPurposeSystemPrompt,
}
```

系统提示词包含共享前缀和指导方针：

```typescript
// src/tools/AgentTool/built-in/generalPurposeAgent.ts#L3-L16
const SHARED_PREFIX = `You are an agent for Claude Code, Anthropic's official CLI for Claude. Given the user's message, you should use the tools available to complete the task. Complete the task fully—don't gold-plate, but don't leave it half-done.`

const SHARED_GUIDELINES = `Your strengths:
- Searching for code, configurations, and patterns across large codebases
- Analyzing multiple files to understand system architecture
- Investigating complex questions that require exploring many files
- Performing multi-step research tasks

Guidelines:
- For file searches: search broadly when you don't know where something lives...
- Be thorough: Check multiple locations, consider different naming conventions...
- NEVER create files unless they're absolutely necessary...
- NEVER proactively create documentation files (*.md) or README files.`
```

### 4. Explore Agent 详解

```typescript
// src/tools/AgentTool/built-in/exploreAgent.ts#L64-L83
export const EXPLORE_AGENT: BuiltInAgentDefinition = {
  agentType: 'Explore',
  whenToUse: 'Fast agent specialized for exploring codebases...',
  disallowedTools: [
    AGENT_TOOL_NAME,           // 禁止嵌套 Agent
    EXIT_PLAN_MODE_TOOL_NAME,
    FILE_EDIT_TOOL_NAME,       // 禁止编辑
    FILE_WRITE_TOOL_NAME,      // 禁止写入
    NOTEBOOK_EDIT_TOOL_NAME,   // 禁止编辑 Notebook
  ],
  source: 'built-in',
  baseDir: 'built-in',
  model: process.env.USER_TYPE === 'ant' ? 'inherit' : 'haiku',
  omitClaudeMd: true,         // 省略 CLAUDE.md 节省 token
  getSystemPrompt: () => getExploreSystemPrompt(),
}
```

关键特性：
- 只读模式：系统提示词中明确禁止文件修改
- 使用 `haiku` 模型（外部用户）提升速度，Ant 内部用户继承主模型
- `omitClaudeMd: true` — 不加载 CLAUDE.md，节省约 5-15 Gtok/week

### 5. 一次性 Agent

定义在 [`src/tools/AgentTool/constants.ts`](../../claude-code-source/src/tools/AgentTool/constants.ts#L9-L12)：

```typescript
// src/tools/AgentTool/constants.ts#L9-L12
export const ONE_SHOT_BUILTIN_AGENT_TYPES: ReadonlySet<string> = new Set([
  'Explore',
  'Plan',
])
```

Explore 和 Plan 是一次性 Agent，执行完毕后父 Agent 不会通过 `SendMessage` 继续交互，从而节省 token。

## 六、Fork 子 Agent

### 1. 特性门控

Fork 是实验性特性，定义在 [`src/tools/AgentTool/forkSubagent.ts`](../../claude-code-source/src/tools/AgentTool/forkSubagent.ts#L32-L39)：

```typescript
// src/tools/AgentTool/forkSubagent.ts#L32-L39
export function isForkSubagentEnabled(): boolean {
  if (feature('FORK_SUBAGENT')) {
    if (isCoordinatorMode()) return false   // Coordinator 模式互斥
    if (getIsNonInteractiveSession()) return false  // 非交互式会话禁用
    return true
  }
  return false
}
```

### 2.FORK_AGENT 定义

[`FORK_AGENT`](../../claude-code-source/src/tools/AgentTool/forkSubagent.ts#L60-L71) 是一个合成的 Agent 定义：

```typescript
// src/tools/AgentTool/forkSubagent.ts#L60-L71
export const FORK_AGENT = {
  agentType: FORK_SUBAGENT_TYPE,  // 'fork'
  whenToUse: 'Implicit fork — inherits full conversation context...',
  tools: ['*'],                   // 继承父工具池
  maxTurns: 200,
  model: 'inherit',               // 继承父模型（缓存共享）
  permissionMode: 'bubble',       // 权限提示冒泡到父终端
  source: 'built-in',
  baseDir: 'built-in',
  getSystemPrompt: () => '',      // 实际使用父已渲染的系统提示词
} satisfies BuiltInAgentDefinition
```

### 3.Fork 的核心特性

#### 3.1 上下文继承

Fork 子进程继承父 Agent 的完整对话上下文和系统提示词。系统提示词通过 `toolUseContext.renderedSystemPrompt` 传递，而非重新调用 `getSystemPrompt()`，以避免 GrowthBook 状态变化导致的缓存失效：

```typescript
// src/tools/AgentTool/AgentTool.tsx#L496-L511
if (isForkPath) {
  if (toolUseContext.renderedSystemPrompt) {
    forkParentSystemPrompt = toolUseContext.renderedSystemPrompt;
  } else {
    // Fallback: 重新计算（可能因 GrowthBook 状态变化而偏离父缓存）
    const defaultSystemPrompt = await getSystemPrompt(toolUseContext.options.tools, ...);
    forkParentSystemPrompt = buildEffectiveSystemPrompt({...});
  }
  promptMessages = buildForkedMessages(prompt, assistantMessage);
}
```

#### 3.2 缓存共享

通过 [`buildForkedMessages()`](../../claude-code-source/src/tools/AgentTool/forkSubagent.ts#L107-L169) 构建 byte-identical 的 API 请求前缀，最大化 prompt cache 命中：

```typescript
// src/tools/AgentTool/forkSubagent.ts#L107-L169
export function buildForkedMessages(
  directive: string,
  assistantMessage: AssistantMessage,
): MessageType[] {
  // 1. 克隆父助手消息（保留所有 content blocks）
  const fullAssistantMessage = { ...assistantMessage, uuid: randomUUID(), ... };

  // 2. 为所有 tool_use 构建相同的占位 tool_result
  const toolResultBlocks = toolUseBlocks.map(block => ({
    type: 'tool_result' as const,
    tool_use_id: block.id,
    content: [{ type: 'text' as const, text: FORK_PLACEHOLDER_RESULT }],
  }));

  // 3. 单个用户消息：占位结果 + 每个子进程专属指令
  const toolResultMessage = createUserMessage({
    content: [...toolResultBlocks, { type: 'text', text: buildChildMessage(directive) }],
  });

  return [fullAssistantMessage, toolResultMessage];
}
```

【**关键**】所有 Fork 子进程共享相同的前缀（相同的 `FORK_PLACEHOLDER_RESULT`），只有最后的指令文本不同，最大化缓存命中。

#### 3.3 递归防护

[`isInForkChild()`](../../claude-code-source/src/tools/AgentTool/forkSubagent.ts#L78-L89) 检测 Fork 嵌套，在 `call()` 中拒绝递归 Fork：

```typescript
// src/tools/AgentTool/forkSubagent.ts#L78-L89
export function isInForkChild(messages: MessageType[]): boolean {
  return messages.some(m => {
    if (m.type !== 'user') return false
    const content = m.message.content
    if (!Array.isArray(content)) return false
    return content.some(
      block => block.type === 'text' && block.text.includes(`<${FORK_BOILERPLATE_TAG}>`),
    )
  })
}
```

双重防护：优先检查 `querySource`（抗 compaction），回退检查消息历史中的 `FORK_BOILERPLATE_TAG`。

#### 3.4 子进程指令格式

[`buildChildMessage()`](../../claude-code-source/src/tools/AgentTool/forkSubagent.ts#L171-L198) 构建 Fork 子进程的专用指令：

```typescript
// src/tools/AgentTool/forkSubagent.ts#L171-L198
export function buildChildMessage(directive: string): string {
  return `<${FORK_BOILERPLATE_TAG}>
STOP. READ THIS FIRST.

You are a forked worker process. You are NOT the main agent.

RULES (non-negotiable):
1. Your system prompt says "default to forking." IGNORE IT — that's for the parent.
   You ARE the fork. Do NOT spawn sub-agents; execute directly.
2. Do NOT converse, ask questions, or suggest next steps
3. Do NOT editorialize or add meta-commentary
4. USE your tools directly: Bash, Read, Write, etc.
5. If you modify files, commit your changes before reporting.
6. Do NOT emit text between tool calls. Use tools silently, then report once at the end.
7. Stay strictly within your directive's scope.
8. Keep your report under 500 words unless the directive specifies otherwise.
9. Your response MUST begin with "Scope:". No preamble.
10. REPORT structured facts, then stop

Output format (plain text labels, not markdown headers):
  Scope: <echo back your assigned scope in one sentence>
  Result: <the answer or key findings>
  Key files: <relevant file paths>
  Files changed: <list with commit hash>
  Issues: <list — include only if there are issues to flag>
</${FORK_BOILERPLATE_TAG}>

${FORK_DIRECTIVE_PREFIX}${directive}`
}
```

#### 3.5 Worktree 通知

Fork 子进程在 Worktree 中运行时，收到路径翻译通知：

```typescript
// src/tools/AgentTool/forkSubagent.ts#L205-L210
export function buildWorktreeNotice(parentCwd: string, worktreeCwd: string): string {
  return `You've inherited the conversation context above from a parent agent working in ${parentCwd}.
You are operating in an isolated git worktree at ${worktreeCwd} — same repository, same relative file structure, separate working copy.
Paths in the inherited context refer to the parent's working directory; translate them to your worktree root.
Re-read files before editing if the parent may have modified them since they appear in the context.
Your changes stay in this worktree and will not affect the parent's files.`
}
```

## 七、runAgent 运行时

### 1. 函数签名

[`runAgent()`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L248-L329) 是驱动子 Agent 完整生命周期的异步生成器：

```typescript
// src/tools/AgentTool/runAgent.ts#L248
export async function* runAgent({
  agentDefinition,      // Agent 定义
  promptMessages,       // 初始消息列表
  toolUseContext,       // 工具使用上下文
  canUseTool,           // 工具权限检查函数
  isAsync,              // 是否异步运行
  canShowPermissionPrompts,  // 是否可显示权限提示
  forkContextMessages,  // Fork 上下文消息（仅 Fork 路径）
  querySource,          // 查询来源标识
  override,             // 覆盖参数（系统提示词、AgentId 等）
  model,                // 模型覆盖
  maxTurns,             // 最大轮次
  preserveToolUseResults,  // 是否保留工具使用结果
  availableTools,       // 可用工具池
  allowedTools,         // 允许的工具规则
  onCacheSafeParams,    // 缓存安全参数回调
  contentReplacementState,  // 内容替换状态
  useExactTools,        // 是否使用精确工具（Fork 路径）
  worktreePath,         // Worktree 路径
  description,          // 任务描述
  transcriptSubdir,     // 转录子目录
  onQueryProgress,      // 查询进度回调
}: { ... }): AsyncGenerator<Message, void>
```

### 2. 运行时初始化流程

#### 2.1 模型解析

```typescript
// src/tools/AgentTool/runAgent.ts#L340-L345
const resolvedAgentModel = getAgentModel(
  agentDefinition.model,              // Agent 定义的模型
  toolUseContext.options.mainLoopModel,  // 主循环模型
  model,                              // 调用方指定的模型覆盖
  permissionMode,                     // 权限模式
)
```

#### 2.2 上下文裁剪

对于只读 Agent（Explore、Plan），`runAgent` 会省略 CLAUDE.md 和 gitStatus 以节省 token：

```typescript
// src/tools/AgentTool/runAgent.ts#L390-L410
const shouldOmitClaudeMd = agentDefinition.omitClaudeMd &&
  !override?.userContext &&
  getFeatureValue_CACHED_MAY_BE_STALE('tengu_slim_subagent_claudemd', true)
const { claudeMd: _omittedClaudeMd, ...userContextNoClaudeMd } = baseUserContext
const resolvedUserContext = shouldOmitClaudeMd ? userContextNoClaudeMd : baseUserContext

// Explore/Plan 也省略 gitStatus（最多 40KB，且是过时的）
const { gitStatus: _omittedGitStatus, ...systemContextNoGit } = baseSystemContext
const resolvedSystemContext =
  agentDefinition.agentType === 'Explore' || agentDefinition.agentType === 'Plan'
    ? systemContextNoGit : baseSystemContext
```

#### 2.3 权限模式覆盖

```typescript
// src/tools/AgentTool/runAgent.ts#L415-L498
const agentPermissionMode = agentDefinition.permissionMode
const agentGetAppState = () => {
  let toolPermissionContext = state.toolPermissionContext
  // Agent 定义的权限模式覆盖（除非父级是 bypassPermissions/acceptEdits/auto）
  if (agentPermissionMode &&
      state.toolPermissionContext.mode !== 'bypassPermissions' &&
      state.toolPermissionContext.mode !== 'acceptEdits' &&
      !(feature('TRANSCRIPT_CLASSIFIER') && state.toolPermissionContext.mode === 'auto')) {
    toolPermissionContext = { ...toolPermissionContext, mode: agentPermissionMode }
  }
  // 异步 Agent 无法显示 UI → 自动拒绝权限提示
  const shouldAvoidPrompts = canShowPermissionPrompts !== undefined
    ? !canShowPermissionPrompts
    : agentPermissionMode === 'bubble' ? false : isAsync
  if (shouldAvoidPrompts) {
    toolPermissionContext = { ...toolPermissionContext, shouldAvoidPermissionPrompts: true }
  }
  // 作用域隔离：allowedTools 替换所有会话级规则（防止父级权限泄漏）
  if (allowedTools !== undefined) {
    toolPermissionContext = {
      ...toolPermissionContext,
      alwaysAllowRules: {
        cliArg: state.toolPermissionContext.alwaysAllowRules.cliArg,
        session: [...allowedTools],
      },
    }
  }
  // effort 覆盖
  const effortValue = agentDefinition.effort !== undefined
    ? agentDefinition.effort : state.effortValue
  return { ...state, toolPermissionContext, effortValue }
}
```

#### 2.4 工具解析

```typescript
// src/tools/AgentTool/runAgent.ts#L500-L502
const resolvedTools = useExactTools
  ? availableTools  // Fork 路径：直接使用父工具池（缓存一致）
  : resolveAgentTools(agentDefinition, availableTools, isAsync).resolvedTools
```

[`resolveAgentTools()`](../../claude-code-source/src/tools/AgentTool/agentToolUtils.ts#L122-L225) 的完整解析流程：

1. 通过 `filterToolsForAgent()` 过滤掉所有 Agent 禁用的工具、自定义 Agent 额外禁用的工具、异步 Agent 只允许的工具
2. 应用 `disallowedTools` 黑名单
3. 如果 `tools` 为 `undefined` 或 `['*']`，允许所有工具
4. 否则按 `tools` 白名单匹配，同时提取 `Agent(x,y)` 语法中的 `allowedAgentTypes`

#### 2.5 MCP 服务器初始化

[`initializeAgentMcpServers()`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L95-L218) 为 Agent 连接其专属 MCP 服务器：

```typescript
// src/tools/AgentTool/runAgent.ts#L95-L218
async function initializeAgentMcpServers(agentDefinition, parentClients) {
  if (!agentDefinition.mcpServers?.length) {
    return { clients: parentClients, tools: [], cleanup: async () => {} }
  }
  // plugin-only 策略下，非管理员信任的 Agent 跳过 MCP
  const agentIsAdminTrusted = isSourceAdminTrusted(agentDefinition.source)
  if (isRestrictedToPluginOnly('mcp') && !agentIsAdminTrusted) {
    return { clients: parentClients, tools: [], cleanup: async () => {} }
  }
  for (const spec of agentDefinition.mcpServers) {
    if (typeof spec === 'string') {
      // 按名称引用现有 MCP 配置（共享客户端）
      config = getMcpConfigByName(spec)
    } else {
      // 内联定义 { [name]: config }（新建客户端，Agent 结束时清理）
      config = { ...serverConfig, scope: 'dynamic' }
      isNewlyCreated = true
    }
    const client = await connectToServer(name, config)
    // ...
  }
  return { clients: [...parentClients, ...agentClients], tools: agentTools, cleanup }
}
```

#### 2.6 技能预加载

```typescript
// src/tools/AgentTool/runAgent.ts#L578-L646
const skillsToPreload = agentDefinition.skills ?? []
if (skillsToPreload.length > 0) {
  const allSkills = await getSkillToolCommands(getProjectRoot())
  for (const skillName of skillsToPreload) {
    // 多策略解析技能名：
    // 1. 精确匹配
    // 2. 添加 Agent 的插件前缀（"my-skill" → "my-plugin:my-skill"）
    // 3. 后缀匹配（找到以 ":skillName" 结尾的命令）
    const resolvedName = resolveSkillName(skillName, allSkills, agentDefinition)
    // ...
  }
  // 并发加载所有技能内容，注入初始消息
  for (const { content } of loaded) {
    initialMessages.push(createUserMessage({
      content: [{ type: 'text', text: metadata }, ...content],
      isMeta: true,
    }))
  }
}
```

#### 2.7 钩子注册

```typescript
// src/tools/AgentTool/runAgent.ts#L564-L575
const hooksAllowedForThisAgent =
  !isRestrictedToPluginOnly('hooks') || isSourceAdminTrusted(agentDefinition.source)
if (agentDefinition.hooks && hooksAllowedForThisAgent) {
  registerFrontmatterHooks(
    rootSetAppState, agentId, agentDefinition.hooks,
    `agent '${agentDefinition.agentType}'`,
    true,  // isAgent - 将 Stop 转为 SubagentStop
  )
}
```

### 3. 系统提示词构建

[`getAgentSystemPrompt()`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L906-L932) 构建子 Agent 的系统提示词：

```typescript
// src/tools/AgentTool/runAgent.ts#L906-L932
async function getAgentSystemPrompt(
  agentDefinition, toolUseContext, resolvedAgentModel,
  additionalWorkingDirectories, resolvedTools,
): Promise<string[]> {
  const enabledToolNames = new Set(resolvedTools.map(t => t.name))
  try {
    const agentPrompt = agentDefinition.getSystemPrompt({ toolUseContext })
    const prompts = [agentPrompt]
    return await enhanceSystemPromptWithEnvDetails(
      prompts, resolvedAgentModel, additionalWorkingDirectories, enabledToolNames,
    )
  } catch (_error) {
    // 失败时使用默认 Agent 提示词
    return enhanceSystemPromptWithEnvDetails(
      [DEFAULT_AGENT_PROMPT], resolvedAgentModel, additionalWorkingDirectories, enabledToolNames,
    )
  }
}
```

### 4. 查询循环

```typescript
// src/tools/AgentTool/runAgent.ts#L747-L806
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
    // 转发 API 请求开始事件（TTFT/OTPS 指标）
    if (message.type === 'stream_event' && message.event.type === 'message_start' && message.ttftMs != null) {
      toolUseContext.pushApiMetricsEntry?.(message.ttftMs)
      continue
    }
    // 处理附件消息
    if (message.type === 'attachment') {
      if (message.attachment.type === 'max_turns_reached') break
      yield message
      continue
    }
    // 记录可记录的消息（assistant, user, progress, compact_boundary）
    if (isRecordableMessage(message)) {
      await recordSidechainTranscript([message], agentId, lastRecordedUuid)
      if (message.type !== 'progress') lastRecordedUuid = message.uuid
      yield message
    }
  }
}
```

### 5. 清理流程

```typescript
// src/tools/AgentTool/runAgent.ts#L816-L859
finally {
  await mcpCleanup()                         // 清理 Agent 专属 MCP 服务器
  if (agentDefinition.hooks) {
    clearSessionHooks(rootSetAppState, agentId)  // 清理会话钩子
  }
  if (feature('PROMPT_CACHE_BREAK_DETECTION')) {
    cleanupAgentTracking(agentId)              // 清理缓存追踪
  }
  agentToolUseContext.readFileState.clear()   // 释放文件状态缓存
  initialMessages.length = 0                  // 释放 Fork 上下文消息
  unregisterPerfettoAgent(agentId)            // 释放 Perfetto 追踪
  clearAgentTranscriptSubdir(agentId)         // 释放转录子目录
  // 释放 Agent 的 todos 条目
  rootSetAppState(prev => {
    if (!(agentId in prev.todos)) return prev
    const { [agentId]: _removed, ...todos } = prev.todos
    return { ...prev, todos }
  })
  // 杀掉 Agent 启动的后台 Shell 任务
  killShellTasksForAgent(agentId, toolUseContext.getAppState, rootSetAppState)
}
```

## 八、Agent 定义的完整加载流程

[`getAgentDefinitionsWithOverrides()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L296-L393) 是 Agent 定义的统一加载入口，使用 `memoize` 缓存结果：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L296-L393
export const getAgentDefinitionsWithOverrides = memoize(
  async (cwd: string): Promise<AgentDefinitionsResult> => {
    // Simple 模式：跳过自定义 Agent，只返回内置
    if (isEnvTruthy(process.env.CLAUDE_CODE_SIMPLE)) {
      const builtInAgents = getBuiltInAgents()
      return { activeAgents: builtInAgents, allAgents: builtInAgents }
    }

    // 1. 扫描所有目录中的 .md 文件
    const markdownFiles = await loadMarkdownFilesForSubdir('agents', cwd)

    // 2. 对每个文件解析 frontmatter 和正文
    const customAgents = markdownFiles
      .map(({ filePath, baseDir, frontmatter, content, source }) => {
        const agent = parseAgentFromMarkdown(filePath, baseDir, frontmatter, content, source)
        if (!agent) {
          if (!frontmatter['name']) return null  // 非 Agent 文档，静默跳过
          failedFiles.push({ path: filePath, error: getParseError(frontmatter) })
          return null
        }
        return agent
      })
      .filter(agent => agent !== null)

    // 3. 并行加载插件 Agent 和初始化记忆快照
    let pluginAgentsPromise = loadPluginAgents()
    if (feature('AGENT_MEMORY_SNAPSHOT') && isAutoMemoryEnabled()) {
      const [pluginAgents_] = await Promise.all([
        pluginAgentsPromise,
        initializeAgentMemorySnapshots(customAgents),
      ])
      pluginAgentsPromise = Promise.resolve(pluginAgents_)
    }
    const pluginAgents = await pluginAgentsPromise

    // 4. 合并内置 + 插件 + 自定义 Agent
    const builtInAgents = getBuiltInAgents()
    const allAgentsList = [...builtInAgents, ...pluginAgents, ...customAgents]

    // 5. 去重并确定优先级
    const activeAgents = getActiveAgentsFromList(allAgentsList)

    // 6. 初始化所有活跃 Agent 的 UI 颜色
    for (const agent of activeAgents) {
      if (agent.color) setAgentColor(agent.agentType, agent.color)
    }

    return { activeAgents, allAgents: allAgentsList, failedFiles }
  },
)
```

缓存清理通过 [`clearAgentDefinitionsCache()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L395-L398) 完成：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L395-L398
export function clearAgentDefinitionsCache(): void {
  getAgentDefinitionsWithOverrides.cache.clear?.()
  clearPluginAgentCache()
}
```

---
*本文档由 markdowncli 技能辅助生成*

<!-- more -->

## 一、 工具概述与历史沿革

### 1. 工具定位

AgentTool 是 Claude Code 中用于启动子 Agent（subagent）的内置工具。它将复杂、多步骤的任务委托给一个独立的 Agent 进程自主完成,每个 Agent 类型拥有特定的能力和可用工具集。该工具的正式名称为 `Agent`,在 [`constants.ts`](../../claude-code-source/src/tools/AgentTool/constants.ts#L1-L3) 中定义:

```typescript
// claude-code-source/src/tools/AgentTool/constants.ts
export const AGENT_TOOL_NAME = 'Agent'
// Legacy wire name for backward compat (permission rules, hooks, resumed sessions)
export const LEGACY_AGENT_TOOL_NAME = 'Task'
```

### 2. Task 到 Agent 的重命名

历史上该工具名为 `Task`,后在 PR #19647 中重命名为 `Agent`。为保证旧配置、Hook 规则和已持久化会话的向后兼容,`Task` 作为遗留线名（legacy wire name）保留,通过三层机制处理:

- `aliases` 数组让工具匹配函数能识别旧名
- `normalizeLegacyToolName()` 在权限规则和 Hook 中将 `Task` 归一化为 `Agent`
- `sdkCompatToolName()` 在 SDK 输出时反向映射回 `Task`

## 二、 工具定义结构

### 1. buildTool 与 ToolDef

AgentTool 通过 `buildTool()` 函数构建,该函数在 [`Tool.ts`](../../claude-code-source/src/Tool.ts#L783-L792) 中定义:

```typescript
// claude-code-source/src/Tool.ts
export function buildTool<D extends AnyToolDef>(def: D): BuiltTool<D> {
  return {
    ...TOOL_DEFAULTS,           // 先铺默认值
    userFacingName: () => def.name,  // 默认 userFacingName 为工具名
    ...def,                     // 再用传入定义覆盖
  } as BuiltTool<D>
}
```

`buildTool` 先用 `TOOL_DEFAULTS` 提供默认值,再用传入的定义覆盖。`TOOL_DEFAULTS` 定义在 [`Tool.ts`](../../claude-code-source/src/Tool.ts#L757-L769) 中,包含 `isEnabled`、`isReadOnly`、`isConcurrencySafe`、`checkPermissions` 等字段的默认实现。

### 2. AgentTool 的核心字段

AgentTool 的工具定义位于 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L196-L238),核心字段如下:

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
export const AgentTool = buildTool({
  async prompt({ agents, tools, getToolPermissionContext, allowedAgentTypes }) {
    // ... 动态生成工具提示词
  },
  name: AGENT_TOOL_NAME,              // 'Agent'
  searchHint: 'delegate work to a subagent',
  aliases: [LEGACY_AGENT_TOOL_NAME],  // ['Task']
  maxResultSizeChars: 100_000,
  async description() {
    return 'Launch a new agent';
  },
  get inputSchema(): InputSchema { return inputSchema(); },
  get outputSchema(): OutputSchema { return outputSchema(); },
  async call({ prompt, subagent_type, description, ... }, toolUseContext, canUseTool, assistantMessage, onProgress?) {
    // ... 工具执行逻辑
  },
});
```

关键字段说明:

- `name`：工具正式名称,值为 `'Agent'`
- `aliases`：别名数组,包含 `'Task'`,用于向后兼容
- `searchHint`：ToolSearch 工具关键词匹配用的短语
- `maxResultSizeChars`：结果最大字符数,设为 100000
- `prompt`：异步函数,根据当前可用 Agent 列表动态生成系统提示词
- `call`：工具执行主函数,接收输入参数、工具使用上下文、权限检查函数等

### 3. toolMatchesName 别名匹配

工具名匹配通过 [`toolMatchesName()`](../../claude-code-source/src/Tool.ts#L348-L353) 函数实现,它同时检查正式名称和别名:

```typescript
// claude-code-source/src/Tool.ts
export function toolMatchesName(
  tool: { name: string; aliases?: string[] },
  name: string,
): boolean {
  return tool.name === name || (tool.aliases?.includes(name) ?? false)
}
```

当查找名为 `'Task'` 的工具时,AgentTool 会被匹配到,因为其 `aliases` 包含 `'Task'`。

## 三、 输入输出 Schema

### 1. 输入 Schema

输入 Schema 定义在 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L82-L125) 中,采用 Zod 进行声明式校验:

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
const baseInputSchema = lazySchema(() => z.object({
  description: z.string().describe('A short (3-5 word) description of the task'),
  prompt: z.string().describe('The task for the agent to perform'),
  subagent_type: z.string().optional().describe('The type of specialized agent to use for this task'),
  model: z.enum(['sonnet', 'opus', 'haiku']).optional().describe("Optional model override..."),
  run_in_background: z.boolean().optional().describe('Set to true to run this agent in the background...')
}));

const fullInputSchema = lazySchema(() => {
  const multiAgentInputSchema = z.object({
    name: z.string().optional().describe('Name for the spawned agent...'),
    team_name: z.string().optional().describe('Team name for spawning...'),
    mode: permissionModeSchema().optional().describe('Permission mode for spawned teammate...')
  });
  return baseInputSchema().merge(multiAgentInputSchema).extend({
    isolation: z.enum(['worktree']).optional().describe('Isolation mode...'),
    cwd: z.string().optional().describe('Absolute path to run the agent in...')
  });
});
```

核心输入参数:

- `description`：3-5 个词的任务描述
- `prompt`：传递给子 Agent 的任务指令
- `subagent_type`：可选,指定专用 Agent 类型
- `model`：可选,模型覆盖（sonnet / opus / haiku）
- `run_in_background`：可选,是否在后台运行
- `name`：可选,为生成的 Agent 命名（多 Agent 模式）
- `team_name`：可选,团队名称
- `isolation`：可选,隔离模式（worktree）
- `cwd`：可选,工作目录覆盖

`inputSchema` 会根据功能开关动态裁剪字段,例如当后台任务被禁用或 Fork 子 Agent 启用时,会通过 `.omit()` 移除 `run_in_background` 字段:

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
export const inputSchema = lazySchema(() => {
  const schema = feature('KAIROS') ? fullInputSchema() : fullInputSchema().omit({
    cwd: true
  });
  return isBackgroundTasksDisabled || isForkSubagentEnabled() ? schema.omit({
    run_in_background: true
  }) : schema;
});
```

### 2. 输出 Schema

输出 Schema 定义在 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L141-L155) 中,是一个联合类型,区分同步完成和异步启动两种状态:

```typescript
// claude-code-source/src/tools/AgentTool/AgentTool.tsx
export const outputSchema = lazySchema(() => {
  const syncOutputSchema = agentToolResultSchema().extend({
    status: z.literal('completed'),
    prompt: z.string()
  });
  const asyncOutputSchema = z.object({
    status: z.literal('async_launched'),
    agentId: z.string().describe('The ID of the async agent'),
    description: z.string().describe('The description of the task'),
    prompt: z.string().describe('The prompt for the agent'),
    outputFile: z.string().describe('Path to the output file for checking agent progress'),
    canReadOutputFile: z.boolean().optional().describe('Whether the calling agent has Read/Bash tools...')
  });
  return z.union([syncOutputSchema, asyncOutputSchema]);
});
```

同步输出包含 `agentId`、`content`、`totalToolUseCount`、`totalDurationMs`、`totalTokens`、`usage` 等字段,详见 [`agentToolUtils.ts`](../../claude-code-source/src/tools/AgentTool/agentToolUtils.ts#L227-L258) 中的 `agentToolResultSchema`。异步输出则返回 `agentId` 和 `outputFile` 路径,调用方通过该路径检查进度。

## 四、 工具注册链路

### 1. 导入与基础工具池

AgentTool 在 [`tools.ts`](../../claude-code-source/src/tools.ts#L3) 中被导入,并在 `getAllBaseTools()` 函数中作为首个工具注册:

```typescript
// claude-code-source/src/tools.ts
import { AgentTool } from './tools/AgentTool/AgentTool.js'

export function getAllBaseTools(): Tools {
  return [
    AgentTool,          // 首位注册
    TaskOutputTool,
    BashTool,
    // ... 其他工具
  ]
}
```

### 2. getTools 过滤

`getTools(permissionContext)` 调用 `getAllBaseTools()` 获取全部工具,然后通过 `filterToolsByDenyRules()` 过滤掉被 deny 规则禁止的工具,再通过 `isEnabled()` 过滤掉禁用的工具。这一层确保用户配置的权限规则能正确限制工具可用性。

### 3. assembleToolPool 组装

`assembleToolPool()` 是最终的工具池组装函数,定义在 [`tools.ts`](../../claude-code-source/src/tools.ts#L345-L367) 中,将内置工具与 MCP 工具合并去重:

```typescript
// claude-code-source/src/tools.ts
export function assembleToolPool(
  permissionContext: ToolPermissionContext,
  mcpTools: Tools,
): Tools {
  const builtInTools = getTools(permissionContext)
  const allowedMcpTools = filterToolsByDenyRules(mcpTools, permissionContext)
  const byName = (a: Tool, b: Tool) => a.name.localeCompare(b.name)
  return uniqBy(
    [...builtInTools].sort(byName).concat(allowedMcpTools.sort(byName)),
    'name',
  )
}
```

组装逻辑:

- 先获取经权限过滤的内置工具
- 再获取经权限过滤的 MCP 工具
- 两组工具分别按名称排序后拼接
- 通过 `uniqBy(..., 'name')` 去重,内置工具优先

### 4. 消费方

`assembleToolPool` 的主要调用方包括:

- REPL 的 React Hook [`useMergedTools.ts`](../../claude-code-source/src/hooks/useMergedTools.ts#L30)
- AgentTool 自身在 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L577) 中为子 Agent worker 组装工具池
- [`resumeAgent.ts`](../../claude-code-source/src/tools/AgentTool/resumeAgent.ts#L162) 恢复 Agent 时
- REPL 主屏 [`REPL.tsx`](../../claude-code-source/src/screens/REPL.tsx#L2404)
- CLI 模式 [`print.ts`](../../claude-code-source/src/cli/print.ts#L1473)

## 五、 别名与向后兼容机制

### 1. normalizeLegacyToolName 权限归一化

权限规则解析器中定义了遗留工具名映射表,位于 [`permissionRuleParser.ts`](../../claude-code-source/src/utils/permissions/permissionRuleParser.ts#L18-L33):

```typescript
// claude-code-source/src/utils/permissions/permissionRuleParser.ts
const LEGACY_TOOL_NAME_ALIASES: Record<string, string> = {
  Task: AGENT_TOOL_NAME,                  // 'Task' → 'Agent'
  KillShell: TASK_STOP_TOOL_NAME,
  AgentOutputTool: TASK_OUTPUT_TOOL_NAME,
  BashOutputTool: TASK_OUTPUT_TOOL_NAME,
}

export function normalizeLegacyToolName(name: string): string {
  return LEGACY_TOOL_NAME_ALIASES[name] ?? name
}
```

该函数在权限设置的多个位置被调用,将用户配置中使用的旧名 `Task` 归一化为 `Agent`,确保旧配置在新版本中仍然生效。

### 2. 权限设置中的应用

在 [`permissionSetup.ts`](../../claude-code-source/src/utils/permissions/permissionSetup.ts#L238-L242) 中,`isDangerousTaskPermission` 函数使用归一化来判断权限规则是否危险:

```typescript
// claude-code-source/src/utils/permissions/permissionSetup.ts
export function isDangerousTaskPermission(
  toolName: string,
  _ruleContent: string | undefined,
): boolean {
  return normalizeLegacyToolName(toolName) === AGENT_TOOL_NAME
}
```

任何针对 Agent（包括旧名 Task）的 allow 规则都被视为危险,因为会绕过 auto mode 分类器。

在 [`permissionSetup.ts`](../../claude-code-source/src/utils/permissions/permissionSetup.ts#L902-L910) 中,解析 CLI 传入的 allowed tools 和 base tools 列表时也进行了归一化:

```typescript
// claude-code-source/src/utils/permissions/permissionSetup.ts
// Normalize legacy tool names (e.g., 'Task' → 'Agent') so user-provided
// base tool lists using old names still match canonical names.
const baseToolsSet = new Set(baseToolsResult.map(normalizeLegacyToolName))
```

### 3. sdkCompatToolName SDK 反向映射

在 SDK 兼容层中,工具名会从 `Agent` 反向映射回 `Task`,以保持对旧版 SDK 消费者的兼容,定义在 [`systemInit.ts`](../../claude-code-source/src/utils/messages/systemInit.ts#L19-L25):

```typescript
// claude-code-source/src/utils/messages/systemInit.ts
// TODO(next-minor): remove this translation once SDK consumers have migrated
// to the 'Agent' tool name. The wire name was renamed Task → Agent in #19647
export function sdkCompatToolName(name: string): string {
  return name === AGENT_TOOL_NAME ? LEGACY_AGENT_TOOL_NAME : name
}
```

### 4. 向后兼容三层机制总结

| 机制 | 作用层 | 方向 | 说明 |
| - | - | - | - |
| `aliases: ['Task']` | 工具匹配 | Task → Agent | `toolMatchesName()` 通过别名匹配旧名 |
| `normalizeLegacyToolName()` | 权限/Hook | Task → Agent | 权限规则和 Hook 配置中的旧名归一化 |
| `sdkCompatToolName()` | SDK 输出 | Agent → Task | SDK `system/init` 消息中反向映射,兼容旧 SDK 消费者 |

这三层机制共同保证了 `Task` 到 `Agent` 的重命名在不破坏任何现有配置的前提下完成迁移。

---

*本文档由 markdowncli 技能辅助生成*

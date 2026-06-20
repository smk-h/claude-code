<!-- more -->

## 一、 概述

Workflow 脚本是 Claude Code 配置目录体系中的一种 Markdown 文件，存放在 `workflows/` 目录下。每个 `.md` 文件定义一个可被斜杠命令或 `WorkflowTool` 触发的多阶段工作流。本文档分析 Workflow 脚本的文件格式、目录发现机制、`getWorkflowCommands` 加载流程，以及工作流命令在斜杠命令系统中的注册与标记方式。

## 二、 配置目录体系

### 1. `workflows` 目录的注册

`workflows` 是 Claude Code 标准配置目录之一，定义在 [`markdownConfigLoader.ts`](../../claude-code-source/src/utils/markdownConfigLoader.ts#L29-L36)：

```typescript
// src/utils/markdownConfigLoader.ts:29-36
export const CLAUDE_CONFIG_DIRECTORIES = [
  'commands',
  'agents',
  'output-styles',
  'skills',
  'workflows',          // ← 工作流脚本目录
  ...(feature('TEMPLATES') ? (['templates'] as const) : []),
] as const
```

### 2. 多层级发现

`workflows` 目录与 `commands`、`agents`、`skills` 共享同一套多层级发现机制。`loadMarkdownFilesForSubdir('workflows', cwd)` 会从以下位置扫描 `.md` 文件（按优先级从高到低）：

| 层级 | 路径 | SettingSource | 说明 |
|------|------|---------------|------|
| 内置（bundled） | 包内 `workflows/` | `bundled` | 随 Claude Code 分发的工作流 |
| 项目级 | `<git-root>/.claude/workflows/` | `projectSettings` | 项目专属工作流，可提交到版本控制 |
| 用户级 | `~/.claude/workflows/` | `userSettings` | 用户全局工作流 |
| 策略级 | 受管路径 | `policySettings` | 企业/管理员强制下发 |
| 标志级 | CLI 参数 | `flagSettings` | 命令行临时指定 |

`MarkdownFile` 数据结构（[`markdownConfigLoader.ts`](../../claude-code-source/src/utils/markdownConfigLoader.ts#L40-L45)）：

```typescript
export type MarkdownFile = {
  filePath: string
  baseDir: string
  frontmatter: FrontmatterData
  content: string
  source: SettingSource
}
```

每个文件的 `frontmatter`（YAML 前置元数据）和 `content`（正文）会被分别解析，用于构建工作流定义。

## 三、 脚本文件格式

### 1. Frontmatter 元数据

Workflow 脚本使用 YAML frontmatter 定义元数据。根据 [`coreSchemas.ts`](../../claude-code-source/src/entrypoints/sdk/coreSchemas.ts#L1723-L1728) 中 `workflow_name` 的描述，`meta.name` 字段是工作流的标识符：

```typescript
// src/entrypoints/sdk/coreSchemas.ts:1723-1728
workflow_name: z
  .string()
  .optional()
  .describe(
    "meta.name from the workflow script (e.g. 'spec'). Only set when task_type is 'local_workflow'.",
  ),
```

典型 Workflow 脚本的 frontmatter 结构（基于字段引用推断）：

```markdown
---
name: spec                    # 工作流名称（映射到 workflow_name，作为斜杠命令名）
description: "Generate a spec" # 工作流描述（显示在自动补全中）
# 以下为工作流编排定义（推断）
phases:                       # 阶段列表
  - name: research            # 阶段名称
    agents:                   # 阶段内的 Agent 定义
      - name: explorer
        prompt: "..."
        model: haiku
        # ...
  - name: draft
    agents:
      - name: writer
        prompt: "..."
        # ...
---

# Spec Workflow

（正文中可包含工作流执行的指令或模板）
```

【**注意**】Workflow 脚本的完整 frontmatter schema（phases、agents、dependencies 等字段）定义在编译产物 `createWorkflowCommand.js` 中，公开源码中不可见。上述结构基于以下间接证据推断：
- `workflow_name` 来自 `meta.name`（`coreSchemas.ts` L1727）
- `phaseIndex` 字段存在于 SDK 进度事件中（`sdkEventQueue.ts` L31）
- `agentCount` 字段反映工作流管理的 Agent 数量（`BackgroundTask.tsx` L232）
- `workflowRunId` 用于 worktree slug 消歧（`worktree.ts` L1024）

### 2. 与 Skills/Commands 格式的对比

| 特性 | Workflow 脚本 | Skill（[LV041](LV041-Skills-MD文件解析与内容注入.md)） | 自定义 Agent（[LV061](LV061-自定义Agent的MD文件定义与发现.md)） |
|------|--------------|------|------|
| 目录 | `workflows/` | `skills/` | `agents/` |
| 触发方式 | `/<name>` 斜杠命令 / `WorkflowTool` | `/<name>` 斜杠命令 / 自动注入 | `Agent` 工具 `subagent_type` 参数 |
| 命令 `kind` | `'workflow'` | 无 | N/A |
| 执行模型 | 多阶段多 Agent 编排 | 单轮 prompt 注入 | 单 Agent 子进程 |
| 进度追踪 | Phase 树 + Agent 状态 | 无 | 单 Agent 进度 |

## 四、 getWorkflowCommands 加载流程

### 1. 加载入口

`getWorkflowCommands(cwd)` 是工作流脚本加载的统一入口，在 [`commands.ts`](../../claude-code-source/src/commands.ts#L401-L405) 中通过特性门控的条件 `require()` 加载：

```typescript
// src/commands.ts:401-405
const getWorkflowCommands = feature('WORKFLOW_SCRIPTS')
  ? (
      require('./tools/WorkflowTool/createWorkflowCommand.js') as typeof import('./tools/WorkflowTool/createWorkflowCommand.js')
    ).getWorkflowCommands
  : null
```

### 2. 命令合并

`getWorkflowCommands` 的结果在 [`loadAllCommands`](../../claude-code-source/src/commands.ts#L449-L469) 中与其他命令源合并：

```typescript
// src/commands.ts:449-469 (示意)
const loadAllCommands = memoize(async (cwd: string): Promise<Command[]> => {
  // ... 加载 skills、plugins 等 ...
  const workflowCommands = getWorkflowCommands
    ? getWorkflowCommands(cwd)
    : Promise.resolve([])
  // 合并所有命令源
  return [
    ...builtinCommands,
    ...skillDirCommands,
    ...pluginSkills,
    ...bundledSkills,
    ...(await workflowCommands),   // ← 工作流命令
  ]
})
```

【**关键**】当 `WORKFLOW_SCRIPTS` 特性关闭时，`getWorkflowCommands` 为 `null`，`loadAllCommands` 通过 `Promise.resolve([])` 返回空数组，工作流命令完全缺席。这确保了外部构建中不会有任何工作流命令泄漏。

### 3. 生成的命令对象

`getWorkflowCommands` 为每个工作流脚本生成一个 `PromptCommand`，其 `kind` 字段设为 `'workflow'`：

```typescript
// 推断的命令对象结构（基于 src/types/command.ts）
{
  type: 'prompt',
  kind: 'workflow',              // ← 标记为工作流命令
  name: 'spec',                  // 来自 meta.name
  description: 'Generate a spec',
  source: 'projectSettings',     // 来源层级
  argNames: [...],               // 工作流参数
  // ...
  getPromptForCommand(args, context) { /* 返回工作流执行 prompt */ }
}
```

`kind: 'workflow'` 字段定义在 [`command.ts`](../../claude-code-source/src/types/command.ts#L198)：

```typescript
// src/types/command.ts:198
kind?: 'workflow' // Distinguishes workflow-backed commands (badged in autocomplete)
```

## 五、 斜杠命令系统集成

### 1. 自动补全标记

工作流命令在斜杠命令自动补全中以 `workflow` 标签区分。[`commandSuggestions.ts`](../../claude-code-source/src/utils/suggestions/commandSuggestions.ts#L265-L287) 中的 `createCommandSuggestionItem` 负责生成补全项：

```typescript
// src/utils/suggestions/commandSuggestions.ts:265-287
function createCommandSuggestionItem(
  cmd: Command,
  matchedAlias?: string,
): SuggestionItem {
  const commandName = getCommandName(cmd)
  const aliasText = matchedAlias ? ` (${matchedAlias})` : ''

  const isWorkflow = cmd.type === 'prompt' && cmd.kind === 'workflow'
  const fullDescription =
    (isWorkflow ? cmd.description : formatDescriptionWithSource(cmd)) +
    (cmd.type === 'prompt' && cmd.argNames?.length
      ? ` (arguments: ${cmd.argNames.join(', ')})`
      : '')

  return {
    id: getCommandId(cmd),
    displayText: `/${commandName}${aliasText}`,
    tag: isWorkflow ? 'workflow' : undefined,   // ← workflow 标签
    description: fullDescription,
    metadata: cmd,
  }
}
```

工作流命令与普通命令的区别：
- **`tag`**：设为 `'workflow'`，在补全 UI 中以标签形式显示
- **`description`**：工作流命令直接使用 `cmd.description`，不附加 source 来源标记（`formatDescriptionWithSource` 仅用于普通命令）

### 2. `/workflows` 浏览命令

除了每个工作流脚本生成的 `/<name>` 命令外，还存在一个 `/workflows` 命令（别名为 `w`），用于浏览正在运行和已完成的工作流：

```
/workflows    Browse running and completed workflows...
```

该命令的描述和别名在斜杠命令系统中注册（详见 [LV070 斜杠命令系统](../cli/LV070-斜杠命令系统.md)）。

## 六、 命令执行流程

当用户输入 `/<workflow-name>` 时，斜杠命令系统执行以下流程：

```
1. parseSlashCommand(input) → { commandName: 'spec', args: '...' }
2. 在合并后的命令列表中查找 name === 'spec' 的命令
3. 命令类型为 'prompt'，调用 getPromptForCommand(args, context)
4. getPromptForCommand 返回工作流执行 prompt（ContentBlockParam[]）
5. prompt 注入当前对话，LLM 接收后可能：
   a. 直接执行工作流指令（调用 Bash、FileEdit 等工具）
   b. 调用 WorkflowTool 启动结构化工作流执行
```

`getPromptForCommand` 的返回值被注入为用户消息，LLM 据此理解工作流的阶段结构和 Agent 编排意图，然后通过 `WorkflowTool` 或直接工具调用执行。

## 七、 SyntheticOutputTool 集成

工作流脚本在执行过程中会频繁调用带 schema 的 Agent（如 `agent({schema: BUGS_SCHEMA})`），用于结构化输出。[`SyntheticOutputTool`](../../claude-code-source/src/tools/SyntheticOutputTool/SyntheticOutputTool.ts#L105-L119) 专门为此场景优化：

```typescript
// src/tools/SyntheticOutputTool/SyntheticOutputTool.ts:105-119
// Workflow scripts call agent({schema: BUGS_SCHEMA}) 30-80 times per run with
// the same schema object reference. Without caching, each call does
// new Ajv() + validateSchema() + compile() (~1.4ms of JIT codegen). Identity
// cache brings 80-call workflows from ~110ms to ~4ms Ajv overhead.
const toolCache = new WeakMap<object, CreateResult>()

export function createSyntheticOutputTool(
  jsonSchema: Record<string, unknown>,
): CreateResult {
  const cached = toolCache.get(jsonSchema)
  // ... 缓存命中则复用，否则创建新工具并缓存 ...
}
```

【**关键**】工作流单次运行可能调用同一 schema 的 Agent 30-80 次。`WeakMap` 身份缓存将 Ajv schema 编译开销从约 110ms 降至约 4ms，这对高频结构化输出场景至关重要。

## 八、 配置目录缓存与失效

`loadAllCommands` 使用 `memoize()` 按 `cwd` 缓存结果，因为命令加载涉及大量磁盘 I/O 和动态导入。当工作流脚本文件变更时，需要清除缓存以重新加载：

- 新增/删除 `workflows/` 目录中的 `.md` 文件
- 修改 frontmatter（如 `name`、`description`、`argNames`）

缓存清除与 Skills/Agents 的机制一致，通过相应的 `clear*Cache` 函数触发。

## 九、 小结

Workflow 脚本的发现与命令注册机制遵循 Claude Code 的标准配置目录模式：

1. **统一目录**：`workflows/` 与 `commands`、`agents`、`skills` 并列，共享多层级发现基础设施
2. **特性门控**：`getWorkflowCommands` 通过 `feature('WORKFLOW_SCRIPTS')` 条件加载，外部构建中完全缺席
3. **命令标记**：生成的命令带 `kind: 'workflow'`，在自动补全中以 `workflow` 标签区分
4. **执行入口**：`getPromptForCommand` 返回的 prompt 驱动 LLM 通过 `WorkflowTool` 或直接工具调用执行工作流

工作流脚本的执行引擎、Phase 编排和 Agent 管理详见 [LV093-WorkflowTool与执行引擎](LV093-WorkflowTool与执行引擎.md)。

---
*本文档基于 `WORKFLOW_SCRIPTS` 特性开关门控的编译产物分析，脚本 frontmatter 的完整 schema 存在于 `createWorkflowCommand.js` 编译产物中。*

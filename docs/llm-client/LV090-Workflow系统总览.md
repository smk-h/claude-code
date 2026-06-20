<!-- more -->

## 一、 概述

Claude Code 中的 "Workflow"（工作流）是一个**多阶段、多 Agent 编排系统**，允许用户通过脚本文件定义自动化的多步任务流水线，由多个子 Agent 协同完成。该功能由构建时特性开关 `WORKFLOW_SCRIPTS` 控制，在公开构建中**默认关闭**（仅 Anthropic 内部 / `ant` 用户可用）。

【**关键**】Workflow 在代码库中存在两种截然不同的形态：

| 形态 | 特性开关 | 适用对象 | 源码可见性 | 说明 |
|------|----------|----------|------------|------|
| **Workflow Scripts**（工作流脚本） | `WORKFLOW_SCRIPTS` | ant-only（内部） | 仅编译产物 | 多阶段 Agent 编排引擎，本系列文档的核心分析对象 |
| **GitHub Actions Workflows** | 无（公开） | 所有用户 | 完整源码 | `/install-github-app` 命令在仓库中创建 `.github/workflows/*.yml` 文件 |

本文档系列（LV090–LV094）聚焦于 **Workflow Scripts** 形态，即由 `WORKFLOW_SCRIPTS` 特性开关门控的多 Agent 编排系统。

## 二、 特性开关与构建配置

### 1. 构建时门控

定义在 [`build.ts`](../../claude-code-source/build.ts#L99)：

```typescript
// build.ts:99
WORKFLOW_SCRIPTS: false,
```

`WORKFLOW_SCRIPTS` 是一个 **ant-only** 特性，在公开构建中被设为 `false`。这意味着所有 Workflow 脚本功能的核心模块都不会作为独立源码文件存在于公开构建中——它们仅以编译后的形式存在于 `cli.js` 中，并通过动态 `require()` 加载，且加载前必须通过 `feature('WORKFLOW_SCRIPTS')` 检查。

### 2. 条件加载模式

整个代码库中，Workflow 相关模块的加载统一采用以下模式，确保 Bun 的死代码消除（DCE）能在外部构建中移除这些分支：

```typescript
// 典型模式：feature() 门控 + 动态 require
const workflowTaskModule = feature('WORKFLOW_SCRIPTS')
  ? require('src/tasks/LocalWorkflowTask/LocalWorkflowTask.js') as typeof import('src/tasks/LocalWorkflowTask/LocalWorkflowTask.js')
  : null
const killWorkflowTask = workflowTaskModule?.killWorkflowTask ?? null
```

这种模式贯穿于 [`BackgroundTasksDialog.tsx`](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L105-L113)、[`commands.ts`](../../claude-code-source/src/commands.ts#L401-L405)、[`constants/tools.ts`](../../claude-code-source/src/constants/tools.ts#L44-L45)、[`utils/permissions/classifierDecision.ts`](../../claude-code-source/src/utils/permissions/classifierDecision.ts#L43-L47) 等文件中。

### 3. 工具名常量

唯一以独立源码文件存留的 Workflow 模块是 [`constants.ts`](../../claude-code-source/src/tools/WorkflowTool/constants.ts#L1-L2)：

```typescript
// src/tools/WorkflowTool/constants.ts
export const WORKFLOW_TOOL_NAME = 'WorkflowTool'
```

该常量被 `constants/tools.ts` 和 `classifierDecision.ts` 通过条件 `require()` 引用，用于：
- 将 `WorkflowTool` 加入子 Agent 的禁用工具集（防止递归工作流执行）
- 在权限分类器中将 `WorkflowTool` 排除出安全工具白名单

## 三、 核心架构

### 1. 架构总览

```
┌─────────────────────────────────────────────────────────────────────┐
│                        用户交互层                                    │
│  /workflows 命令  │  /<workflow-name> 脚本命令  │  WorkflowTool 调用  │
└──────────┬───────────────────┬──────────────────────────┬───────────┘
           │                   │                          │
           ▼                   ▼                          ▼
┌─────────────────────┐ ┌──────────────────┐ ┌────────────────────────┐
│ createWorkflowCommand│ │ getWorkflowCommands│ │   WorkflowTool         │
│ (命令发现与注册)      │ │ (扫描 workflows/   │ │ (LLM 调用入口)          │
│                     │ │  目录中的脚本)      │ │                        │
└─────────────────────┘ └──────────────────┘ └───────────┬────────────┘
                                                          │
                              ┌───────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     LocalWorkflowTask 执行引擎                       │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────┐ │
│  │ Phase 执行   │→│ Agent 编排    │→│ 进度追踪      │→│ 状态管理   │ │
│  │ (阶段化执行) │  │ (spawn/skip/  │  │ (flushProgress│  │ (AppState │ │
│  │             │  │  retry)       │  │  + SDK 事件)  │  │  tasks)   │ │
│  └─────────────┘  └──────────────┘  └──────────────┘  └──────────┘ │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                ┌──────────────┴───────────────┐
                ▼                              ▼
┌──────────────────────────┐    ┌──────────────────────────────────────┐
│  后台任务系统集成          │    │  SDK 事件流                           │
│  (BackgroundTasksDialog,  │    │  (task_started, task_progress,        │
│   WorkflowDetailDialog,   │    │   task_notification,                  │
│   pillLabel, worktree)    │    │   workflow_progress)                  │
└──────────────────────────┘    └──────────────────────────────────────┘
```

### 2. 核心源码文件

| 文件 | 职责 | 源码可见性 |
|------|------|------------|
| [`src/Task.ts`](../../claude-code-source/src/Task.ts#L6-L13) | `TaskType` 联合类型（含 `'local_workflow'`）、任务 ID 前缀映射（`'w'`）、ID 生成 | 完整 |
| [`src/tasks/types.ts`](../../claude-code-source/src/tasks/types.ts#L12-L29) | `TaskState` 联合类型（含 `LocalWorkflowTaskState`）、`BackgroundTaskState`、`isBackgroundTask()` | 完整 |
| [`src/tools/WorkflowTool/constants.ts`](../../claude-code-source/src/tools/WorkflowTool/constants.ts#L1-L2) | `WORKFLOW_TOOL_NAME` 常量 | 完整 |
| `src/tools/WorkflowTool/createWorkflowCommand.js` | `getWorkflowCommands(cwd)`：扫描 `workflows/` 目录、解析脚本、生成斜杠命令 | 仅编译产物 |
| `src/tools/WorkflowTool/WorkflowTool.js` | WorkflowTool 工具定义、输入 Schema、`call()` 执行逻辑 | 仅编译产物 |
| `src/tasks/LocalWorkflowTask/LocalWorkflowTask.js` | `LocalWorkflowTaskState` 类型、`killWorkflowTask`/`skipWorkflowAgent`/`retryWorkflowAgent`、执行生命周期 | 仅编译产物 |
| [`src/commands.ts`](../../claude-code-source/src/commands.ts#L401-L405) | `getWorkflowCommands` 的条件加载与命令合并入口 | 完整 |
| [`src/utils/markdownConfigLoader.ts`](../../claude-code-source/src/utils/markdownConfigLoader.ts#L29-L36) | `CLAUDE_CONFIG_DIRECTORIES` 含 `'workflows'` 目录 | 完整 |
| [`src/utils/task/framework.ts`](../../claude-code-source/src/utils/task/framework.ts#L104-L116) | `registerTask()` 发射 `task_started` SDK 事件（含 `workflow_name`） | 完整 |
| [`src/utils/task/sdkProgress.ts`](../../claude-code-source/src/utils/task/sdkProgress.ts#L10-L36) | `emitTaskProgress()` 发射 `task_progress` SDK 事件（含 `workflow_progress`） | 完整 |
| [`src/utils/sdkEventQueue.ts`](../../claude-code-source/src/utils/sdkEventQueue.ts#L68-L72) | SDK 事件队列：`workflow_progress` 增量批处理说明 | 完整 |
| [`src/entrypoints/sdk/coreSchemas.ts`](../../claude-code-source/src/entrypoints/sdk/coreSchemas.ts#L1715-L1733) | `SDKTaskStartedMessageSchema` 含 `workflow_name` 字段 | 完整 |
| [`src/components/tasks/BackgroundTasksDialog.tsx`](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L389-L391) | 后台任务对话框：Workflow 列表项、详情视图、kill/skip/retry 操作 | 完整 |
| [`src/components/tasks/BackgroundTask.tsx`](../../claude-code-source/src/components/tasks/BackgroundTask.tsx#L219-L261) | 后台任务行渲染：workflow 名称、agent 计数、状态文本 | 完整 |
| [`src/tasks/pillLabel.ts`](../../claude-code-source/src/tasks/pillLabel.ts#L57-L58) | 底栏 pill 标签："1 background workflow" / "N background workflows" | 完整 |
| `src/components/WorkflowDetailDialog.js`（编译内） | Workflow 详情对话框 UI | 仅编译产物 |

【**注意**】标记为"仅编译产物"的模块不存在为独立源码文件，其实现被编译进 [`cli.js`](../../claude-code-extracted/package/cli.js)（可通过 `cli.js.map` 源码映射恢复原始内容）。本系列文档中对这些模块的分析基于编译产物的间接引用和类型推断。

## 四、 数据模型摘要

### 1. 任务类型

Workflow 作为一种后台任务类型注册到 `AppState.tasks`：

```typescript
// src/Task.ts:6-13
export type TaskType =
  | 'local_bash'
  | 'local_agent'
  | 'remote_agent'
  | 'in_process_teammate'
  | 'local_workflow'    // ← 工作流任务
  | 'monitor_mcp'
  | 'dream'
```

### 2. 任务 ID 前缀

```typescript
// src/Task.ts:79-87
const TASK_ID_PREFIXES: Record<string, string> = {
  local_bash: 'b',
  local_agent: 'a',
  remote_agent: 'r',
  in_process_teammate: 't',
  local_workflow: 'w',   // ← 工作流任务 ID 以 'w' 开头
  monitor_mcp: 'm',
  dream: 'd',
}
```

工作流任务 ID 形如 `w0123456789ab`（`w` + 8 位 base36 随机字符，约 2.8 万亿种组合，足以抵御符号链接暴力攻击）。

### 3. LocalWorkflowTaskState

`LocalWorkflowTaskState` 继承 [`TaskStateBase`](../../claude-code-source/src/Task.ts#L45-L57)，并添加工作流专属字段。其完整类型定义存在于编译产物中，从多处间接引用可重建如下：

| 字段 | 类型 | 来源 | 说明 |
|------|------|------|------|
| `id` | `string` | `TaskStateBase` | 任务 ID（`w` 前缀） |
| `type` | `'local_workflow'` | `TaskStateBase` | 任务类型字面量 |
| `status` | `TaskStatus` | `TaskStateBase` | `pending`/`running`/`completed`/`failed`/`killed` |
| `description` | `string` | `TaskStateBase` | 任务描述 |
| `toolUseId?` | `string` | `TaskStateBase` | 关联的 tool_use ID |
| `startTime` | `number` | `TaskStateBase` | 启动时间戳 |
| `endTime?` | `number` | `TaskStateBase` | 结束时间戳 |
| `outputFile` | `string` | `TaskStateBase` | 输出文件路径 |
| `outputOffset` | `number` | `TaskStateBase` | 输出读取偏移 |
| `notified` | `boolean` | `TaskStateBase` | 是否已通知用户 |
| `workflowName` | `string` | `framework.ts` L111、`BackgroundTask.tsx` L221 | 工作流脚本 `meta.name`（如 `'spec'`） |
| `summary` | `string \| undefined` | `BackgroundTask.tsx` L221、`BackgroundTasksDialog.tsx` L526 | 工作流摘要 |
| `agentCount` | `number` | `BackgroundTask.tsx` L232 | 当前 Agent 数量 |
| `workflowRunId` | `string` | `worktree.ts` L1024 | 运行实例 ID（用于 worktree slug 消歧） |
| `prompt` | `string` | `framework.ts` L115 | 工作流提示词 |
| `agentControllers` | `Map<...>` | `sessionHooks.ts` L46 | Agent 控制器映射（非响应式） |
| `isBackgrounded` | `boolean` | `tasks/types.ts` L42 | 是否后台化 |

详细分析见 [LV092-WorkflowTask状态模型与生命周期](LV092-WorkflowTask状态模型与生命周期.md)。

## 五、 核心流程

### 1. 工作流脚本的生命周期

```
用户输入 /<workflow-name> [args]
        │
        ▼
getWorkflowCommands(cwd) 扫描 workflows/ 目录        ── LV091
        │ 解析 .md 脚本 frontmatter + 正文
        │ 生成 PromptCommand (kind: 'workflow')
        ▼
斜杠命令系统分发 → 执行脚本 prompt
        │
        ▼
LLM 调用 WorkflowTool（或脚本内 agent() API）         ── LV093
        │
        ▼
创建 LocalWorkflowTask → registerTask() 写入 AppState ── LV092
        │ 发射 task_started SDK 事件 (含 workflow_name)
        ▼
执行引擎：按 Phase 顺序执行
        │ 每个 Phase 可并行 spawn 多个 Agent
        │ flushProgress 批量上报进度
        │ 发射 task_progress SDK 事件 (含 workflow_progress)
        ▼
所有 Phase 完成 → 标记 completed/failed
        │ 发射 task_notification SDK 事件
        ▼
后台任务系统集成                                        ── LV094
  · BackgroundTasksDialog 显示 workflow 列表项
  · WorkflowDetailDialog 显示阶段树 + Agent 状态
  · 用户可 kill / skip agent / retry agent
  · pillLabel 显示 "N background workflows"
```

### 2. 两种触发路径

工作流可通过两种路径触发：

**路径 A：斜杠命令（用户直接调用）**
- 用户输入 `/<workflow-name>`（如 `/spec`）
- `getWorkflowCommands(cwd)` 将 `workflows/` 目录中的脚本注册为斜杠命令
- 命令的 `kind` 字段设为 `'workflow'`，在自动补全中以 `workflow` 标签标记
- 详见 [LV091](LV091-Workflow脚本定义与命令发现.md)

**路径 B：WorkflowTool（LLM 调用）**
- LLM 通过调用 `WorkflowTool` 工具启动工作流
- `WorkflowTool` 解析输入参数，创建 `LocalWorkflowTask`
- 详见 [LV093](LV093-WorkflowTool与执行引擎.md)

## 六、 递归执行防护

工作流内部生成的子 Agent **不能**再次调用 `WorkflowTool`，防止递归工作流执行导致资源耗尽：

```typescript
// src/constants/tools.ts:36-46
export const ALL_AGENT_DISALLOWED_TOOLS = new Set([
  // ... 其他禁用工具 ...
  // Prevent recursive workflow execution inside subagents.
  ...(feature('WORKFLOW_SCRIPTS') ? [WORKFLOW_TOOL_NAME] : []),
])
```

`WORKFLOW_TOOL_NAME` 被加入 `ALL_AGENT_DISALLOWED_TOOLS`，这意味着所有子 Agent（包括工作流自身 spawn 的 Agent）的工具池中都不包含 `WorkflowTool`。

## 七、 配置目录

Workflow 脚本存放在 `workflows` 配置目录中，该目录是 Claude Code 配置目录体系的一部分：

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

这些目录遵循统一的多层级发现机制（项目级 `.claude/workflows/`、用户级 `~/.claude/workflows/` 等），与 `commands`、`agents`、`skills` 共享同一套扫描与加载基础设施。详见 [LV091](LV091-Workflow脚本定义与命令发现.md)。

## 八、 本系列文档结构

| 文档 | 主题 |
|------|------|
| [LV090](LV090-Workflow系统总览.md) | Workflow 系统总览（本文档） |
| [LV091](LV091-Workflow脚本定义与命令发现.md) | 脚本文件格式、`workflows/` 目录扫描、`getWorkflowCommands`、斜杠命令注册与 `kind: 'workflow'` 标记 |
| [LV092](LV092-WorkflowTask状态模型与生命周期.md) | `LocalWorkflowTaskState` 类型、任务 ID 生成、注册、kill/skip/retry 操作、状态转换 |
| [LV093](LV093-WorkflowTool与执行引擎.md) | `WorkflowTool` 工具定义、输入 Schema、`call()` 执行、Phase 阶段化执行、Agent 编排、进度追踪与 SDK 事件 |
| [LV094](LV094-Workflow与后台任务系统集成.md) | `BackgroundTasksDialog` 集成、`WorkflowDetailDialog`、行渲染、pill 标签、worktree 隔离、SDK 事件流 |

## 九、 与其他系统的关系

- **子 Agent 框架**：工作流通过 Agent 编排执行任务，spawn 的 Agent 复用 [LV060 子 Agent 框架](LV060-子Agent框架总览.md) 的 `runAgent()` 运行时。但工作流 Agent 受 `ALL_AGENT_DISALLOWED_TOOLS` 约束，无法递归调用 `WorkflowTool`。
- **后台任务系统**：工作流作为一种后台任务类型（`local_workflow`）集成到统一的 `AppState.tasks` 状态管理和 `BackgroundTasksDialog` UI 中，与 `local_bash`、`local_agent`、`remote_agent` 等任务类型并列。
- **SDK 事件流**：工作流通过统一的 SDK 事件队列（`sdkEventQueue.ts`）向 SDK 消费者（如 VS Code 子 Agent 面板）上报 `task_started`、`task_progress`（含 `workflow_progress` 增量批）、`task_notification` 事件。
- **斜杠命令系统**：工作流脚本通过 `getWorkflowCommands` 注入斜杠命令系统，以 `kind: 'workflow'` 标记与普通命令区分（详见 [LV070 斜杠命令系统](../cli/LV070-斜杠命令系统.md)）。

---
*本文档基于 `WORKFLOW_SCRIPTS` 特性开关门控的编译产物分析，部分模块仅存在于 `cli.js` 中。*

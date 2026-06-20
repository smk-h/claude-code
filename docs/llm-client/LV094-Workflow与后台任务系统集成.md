<!-- more -->

## 一、 概述

Workflow 系统作为后台任务的一种类型（`local_workflow`），深度集成到 Claude Code 的后台任务管理框架中。本文档分析工作流在 `BackgroundTasksDialog`（后台任务对话框）中的列表展示、详情视图（`WorkflowDetailDialog`）、行渲染（`BackgroundTask`）、底栏 pill 标签，以及 SDK 事件流和 worktree 清理等集成机制。

## 二、 后台任务对话框集成

### 1. 模块加载

`BackgroundTasksDialog` 通过特性门控的动态 `require()` 加载工作流相关的 UI 组件和操作函数（[`BackgroundTasksDialog.tsx` L105-120](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L105-L120)）：

```typescript
// src/components/tasks/BackgroundTasksDialog.tsx:105-120
// WORKFLOW_SCRIPTS is ant-only (build_flags.yaml). Static imports would leak
// ~1.3K lines into external builds. Gate with feature() + require so the
// bundler can dead-code-eliminate the branch.
/* eslint-disable @typescript-eslint/no-require-imports */
const WorkflowDetailDialog = feature('WORKFLOW_SCRIPTS')
  ? (require('./WorkflowDetailDialog.js') as typeof import('./WorkflowDetailDialog.js')).WorkflowDetailDialog
  : null
const workflowTaskModule = feature('WORKFLOW_SCRIPTS')
  ? require('src/tasks/LocalWorkflowTask/LocalWorkflowTask.js') as typeof import('src/tasks/LocalWorkflowTask/LocalWorkflowTask.js')
  : null
const killWorkflowTask = workflowTaskModule?.killWorkflowTask ?? null
const skipWorkflowAgent = workflowTaskModule?.skipWorkflowAgent ?? null
const retryWorkflowAgent = workflowTaskModule?.retryWorkflowAgent ?? null
/* eslint-enable @typescript-eslint/no-require-imports */
```

【**关键**】注释明确说明：静态导入会将约 1.3K 行代码泄漏到外部构建中。使用 `feature()` + `require()` 模式使 Bun 的 DCE 能在外部构建中完全消除该分支。

### 2. 列表项分类

`BackgroundTasksDialog` 将后台任务按类型分类展示。工作流任务被单独归类为 `workflowTasks`（[`BackgroundTasksDialog.tsx` L171-209](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L171)）：

```typescript
// src/components/tasks/BackgroundTasksDialog.tsx:171-209
const {
  bashTasks,
  remoteSessions,
  agentTasks,
  teammateTasks,
  workflowTasks,      // ← 工作流任务
  mcpMonitors,
  dreamTasks,
  allSelectableItems
} = useMemo(() => {
  const backgroundTasks = Object.values(typedTasks ?? {}).filter(isBackgroundTask)
  const allItems = backgroundTasks.map(toListItem)
  const sorted = allItems.sort((a, b) => { /* 运行优先 + 时间倒序 */ })

  const bash = sorted.filter(item => item.type === 'local_bash')
  const remote = sorted.filter(item => item.type === 'remote_agent')
  const agent = sorted.filter(item => item.type === 'local_agent' && item.id !== foregroundedTaskId)
  const workflows = sorted.filter(item => item.type === 'local_workflow')   // ← 工作流筛选
  const monitorMcp = sorted.filter(item => item.type === 'monitor_mcp')
  const dreamTasks = sorted.filter(item => item.type === 'dream')
  // ...
  return {
    bashTasks: bash,
    remoteSessions: remote,
    agentTasks: agent,
    teammateTasks: teammates,
    workflowTasks: workflows,
    mcpMonitors: monitorMcp,
    dreamTasks,
    allSelectableItems: [...leaderItem, ...teammates, ...bash, ...monitorMcp, ...remote, ...agent, ...workflows, ...dreamTasks]
  }
}, [/* deps */])
```

### 3. 列表排序

所有后台任务按以下规则排序（[`BackgroundTasksDialog.tsx` L184-192](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L184)）：
1. **运行中优先**：`status === 'running'` 的任务排在前面
2. **时间倒序**：相同状态的任务按 `startTime` 倒序排列（最新在前）

### 4. 导航顺序

`allSelectableItems` 数组定义了 `↑/↓` 键的导航顺序（[`BackgroundTasksDialog.tsx` L211](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L211)）：

```
leader → teammates → bash → monitorMcp → remote → agent → workflows → dreamTasks
```

工作流任务排在 Agent 之后、dream 任务之前。

## 三、 列表项数据结构

工作流任务被映射为列表项时，使用以下数据结构（[`BackgroundTasksDialog.tsx` L78-83](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L78)）：

```typescript
// src/components/tasks/BackgroundTasksDialog.tsx:78-83
{
  id: task.id,
  type: 'local_workflow',
  task: DeepImmutable<LocalWorkflowTaskState>,
}
```

列表项的 `label` 字段优先使用 `summary`，回退到 `description`（[`BackgroundTasksDialog.tsx` L526-533](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L526)）：

```typescript
// BackgroundTasksDialog.tsx:526-533
case 'local_workflow':
  return {
    id: task.id,
    type: 'local_workflow',
    label: task.summary ?? task.description,    // ← summary 优先
    status: task.status,
    task
  }
```

## 四、 后台任务行渲染

`BackgroundTask` 组件负责渲染每个后台任务的行。工作流任务的渲染逻辑位于 [`BackgroundTask.tsx` L219-261](../../claude-code-source/src/components/tasks/BackgroundTask.tsx#L219)：

```typescript
// src/components/tasks/BackgroundTask.tsx:219-261
case "local_workflow": {
  // 1. 标签：workflowName → summary → description 优先级
  const t1 = task.workflowName ?? task.summary ?? task.description
  const t2 = truncate(t1, activityLimit, true)     // 截断到 activityLimit

  // 2. 状态文本
  const t3 = task.status === "running"
    ? `${task.agentCount} ${plural(task.agentCount, "agent")}`   // 运行中：显示 Agent 数
    : task.status === "completed" ? "done"                        // 完成：显示 "done"
    : undefined                                                   // 其他状态：无文本

  // 3. 未读标记
  const t4 = task.status === "completed" && !task.notified
    ? ", unread"
    : undefined

  // 4. 渲染
  return <Text>{t2}{" "}<TaskStatusText status={task.status} label={t3} suffix={t4} /></Text>
}
```

### 渲染示例

| 状态 | 显示文本 |
|------|----------|
| running, 3 agents | `spec 3 agents` |
| completed, 已通知 | `spec done` |
| completed, 未通知 | `spec done, unread` |
| failed | `spec failed` |
| killed | `spec killed` |

### 标签优先级

工作流行的标签采用三级回退：

```
workflowName ?? summary ?? description
```

1. `workflowName`：工作流脚本 `meta.name`（如 `spec`），最具语义
2. `summary`：工作流运行时摘要
3. `description`：任务描述（兜底）

## 五、 详情视图：WorkflowDetailDialog

### 1. 组件加载

`WorkflowDetailDialog` 是工作流任务的专属详情视图，通过特性门控加载（见第二节）。当 `WORKFLOW_SCRIPTS` 关闭时为 `null`。

### 2. 渲染入口

在 `BackgroundTasksDialog` 的详情模式中，工作流任务的详情通过 `WorkflowDetailDialog` 渲染（[`BackgroundTasksDialog.tsx` L389-391](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L389)）：

```typescript
// src/components/tasks/BackgroundTasksDialog.tsx:389-391
case 'local_workflow':
  if (!WorkflowDetailDialog) return null     // 特性关闭时返回 null
  return <WorkflowDetailDialog
    workflow={task_0}
    onDone={onDone}
    onKill={task_0.status === 'running' && killWorkflowTask
      ? () => killWorkflowTask(task_0.id, setAppState)
      : undefined}
    onSkipAgent={task_0.status === 'running' && skipWorkflowAgent
      ? agentId => skipWorkflowAgent(task_0.id, agentId, setAppState)
      : undefined}
    onRetryAgent={task_0.status === 'running' && retryWorkflowAgent
      ? agentId_0 => retryWorkflowAgent(task_0.id, agentId_0, setAppState)
      : undefined}
    onBack={goBackToList}
    key={`workflow-${task_0.id}`}
  />
```

### 3. Props 语义

| Prop | 类型 | 条件 | 说明 |
|------|------|------|------|
| `workflow` | `LocalWorkflowTaskState` | 始终 | 工作流任务状态 |
| `onDone` | `() => void` | 始终 | 关闭详情回调 |
| `onKill` | `() => void` | `status === 'running'` | 终止整个工作流 |
| `onSkipAgent` | `(agentId) => void` | `status === 'running'` | 跳过指定 Agent |
| `onRetryAgent` | `(agentId) => void` | `status === 'running'` | 重试指定 Agent |
| `onBack` | `() => void` | 始终 | 返回列表视图 |

【**关键**】所有操作回调仅在 `status === 'running'` 时提供，终态任务（completed/failed/killed）的操作按钮为 `undefined`（不渲染或禁用）。

### 4. 详情视图内容（推断）

基于 `workflow_progress` 的 Phase 树模型和 `PhaseProgress.tsx` 组件引用，`WorkflowDetailDialog` 的详情视图应包含：
- **Phase 进度树**：按 `phaseIndex` 分组展示各阶段状态
- **Agent 列表**：每个 Agent 的状态、token 用量、工具调用数
- **操作按钮**：Kill（整体）、Skip Agent（单个）、Retry Agent（单个）

## 六、 键盘操作

工作流任务在后台任务对话框中支持以下键盘操作（[`BackgroundTasksDialog.tsx` L410](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L410)）：

| 按键 | 操作 | 条件 |
|------|------|------|
| `↑/↓` | 选择任务 | 始终 |
| `Enter` | 查看详情 | 选中任务时 |
| `x` | 终止任务 | `status === 'running'` |
| `←/Esc` | 关闭对话框 | 始终 |

`x` 键终止工作流任务的逻辑（[`BackgroundTasksDialog.tsx` L271-273](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L271)）：

```typescript
} else if (currentSelection_0.type === 'local_workflow'
           && currentSelection_0.status === 'running'
           && killWorkflowTask) {
  killWorkflowTask(currentSelection_0.id, setAppState)
}
```

## 七、 底栏 Pill 标签

[`pillLabel.ts`](../../claude-code-source/src/tasks/pillLabel.ts#L10-L67) 的 `getPillLabel()` 为底栏状态栏生成后台任务的紧凑标签。工作流任务的标签规则（[`pillLabel.ts` L57-L58](../../claude-code-source/src/tasks/pillLabel.ts#L57)）：

```typescript
// src/tasks/pillLabel.ts:57-58
case 'local_workflow':
  return n === 1 ? '1 background workflow' : `${n} background workflows`
```

### Pill 标签判定逻辑

`getPillLabel` 首先检查所有任务是否为同一类型（[`pillLabel.ts` L12-L14](../../claude-code-source/src/tasks/pillLabel.ts#L12)）：

```typescript
// src/tasks/pillLabel.ts:10-14
export function getPillLabel(tasks: BackgroundTaskState[]): string {
  const n = tasks.length
  const allSameType = tasks.every(t => t.type === tasks[0]!.type)

  if (allSameType) {
    switch (tasks[0]!.type) {
      // ... 各类型专属标签 ...
      case 'local_workflow':
        return n === 1 ? '1 background workflow' : `${n} background workflows`
    }
  }
  // 混合类型回退
  return `${n} background ${n === 1 ? 'task' : 'tasks'}`
}
```

### 标签示例

| 后台任务组成 | Pill 标签 |
|-------------|----------|
| 仅 1 个工作流 | `1 background workflow` |
| 2 个工作流 | `2 background workflows` |
| 1 个工作流 + 1 个 Agent | `2 background tasks`（混合类型回退） |

## 八、 详情视图的宽限期

工作流任务的详情视图在任务进入终态后有一个宽限期，允许用户查看最终状态（[`BackgroundTasksDialog.tsx` L324-326](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L324)）：

```typescript
// src/components/tasks/BackgroundTasksDialog.tsx:324-326
// Workflow tasks get a grace: their detail view stays open through
// ...
if (!task || task.type !== 'local_workflow' && !isBackgroundTask(task)) {
```

这意味着工作流任务即使进入终态（completed/failed/killed），其详情视图仍保持打开，直到用户手动返回或关闭。这与 `local_agent` 等任务类型的行为不同——后者在终态后会被更快地从后台任务列表中驱逐。

## 九、 SDK 事件流

### 1. 事件队列

工作流通过统一的 SDK 事件队列（[`sdkEventQueue.ts`](../../claude-code-source/src/utils/sdkEventQueue.ts#L68-L72)）向 SDK 消费者上报事件。队列仅在非交互式（headless/streaming）模式下消费（[`sdkEventQueue.ts` L77-L87](../../claude-code-source/src/utils/sdkEventQueue.ts#L77)）：

```typescript
// src/utils/sdkEventQueue.ts:77-87
export function enqueueSdkEvent(event: SdkEvent): void {
  // SDK events are only consumed (drained) in headless/streaming mode.
  // In TUI mode they would accumulate up to the cap and never be read.
  if (!getIsNonInteractiveSession()) {
    return
  }
  if (queue.length >= MAX_QUEUE_SIZE) {
    queue.shift()
  }
  queue.push(event)
}
```

### 2. 工作流相关事件类型

| 事件 | 触发时机 | 工作流专属字段 |
|------|----------|----------------|
| `task_started` | `registerTask()` | `workflow_name`、`prompt` |
| `task_progress` | `flushProgress` 批处理 | `workflow_progress`（Phase 增量批次） |
| `task_notification` | 终态 | `summary`、`usage` |
| `session_state_changed` | 轮次结束 | 无 |

### 3. workflow_progress 重建

SDK 消费者通过 `workflow_progress` 增量批次重建工作流 Phase 树（[`sdkEventQueue.ts` L30-33](../../claude-code-source/src/utils/sdkEventQueue.ts#L30)）：

```typescript
// src/utils/sdkEventQueue.ts:30-33
// Delta batch of workflow state changes. Clients upsert by
// `${type}:${index}` then group by phaseIndex to rebuild the phase tree,
// same fold as collectFromEvents + groupByPhase in PhaseProgress.tsx.
workflow_progress?: SdkWorkflowProgress[]
```

重建算法（SDK 消费者侧）：
1. 对每条 `SdkWorkflowProgress` 记录，以 `${type}:${index}` 为键 upsert 到本地状态
2. 按 `phaseIndex` 分组，重建阶段树
3. 该 fold 逻辑与 TUI 中 `PhaseProgress.tsx` 的 `collectFromEvents` + `groupByPhase` 完全一致

### 4. 队列容量保护

SDK 事件队列有最大容量限制（[`sdkEventQueue.ts` L74-L86](../../claude-code-source/src/utils/sdkEventQueue.ts#L74)）：

```typescript
const MAX_QUEUE_SIZE = 1000
```

当队列达到 1000 条时，最早的事件被移除（FIFO 淘汰）。工作流的 `flushProgress` 批处理模式有助于减少事件数量，避免队列溢出。

## 十、 Worktree 泄漏清理

### 1. 泄漏场景

工作流在 Git Worktree 中执行 Agent 时，若父进程被异常终止（Ctrl+C、ESC、崩溃），worktree 不会被正常清理，导致泄漏。这些泄漏的 worktree 会占用磁盘空间并可能在后续 `git worktree list` 中造成混淆。

### 2. 清理模式

[`worktree.ts`](../../claude-code-source/src/utils/worktree.ts#L1043-L1054) 的 `EPHEMERAL_WORKTREE_PATTERNS` 识别工作流泄漏的 worktree：

```typescript
// src/utils/worktree.ts:1030-1041
const EPHEMERAL_WORKTREE_PATTERNS = [
  /^agent-a[0-9a-f]{7}$/,
  /^wf_[0-9a-f]{8}-[0-9a-f]{3}-\d+$/,    // WorkflowTool slug
  /^wf-\d+$/,                              // 遗留格式
  // ...
]
```

### 3. 清理安全性

30 天清理周期遵循严格的安全保证（[`worktree.ts` L1043-L1054](../../claude-code-source/src/utils/worktree.ts#L1043)）：

| 保证 | 说明 |
|------|------|
| 仅匹配临时模式 | 不触碰用户命名的 worktree（如 `wf-myfeature`） |
| 跳过当前会话 | 不清理当前活跃工作流的 worktree |
| Fail-closed（git status） | `git status` 失败或有跟踪变更时跳过 |
| Fail-closed（远程可达性） | 有未推送到远程的提交时跳过 |
| `-uno` 快速模式 | 30 天前的 worktree 跳过 untracked 扫描（5-10x 加速） |

【**关键**】`wf_` 前缀 + UUID 格式的 slug 与用户可能命名的 `wf-myfeature` 格式 deliberately 区分，确保清理不会误删用户 worktree。

## 十一、 集成全景

```
┌─────────────────────────────────────────────────────────────────────┐
│                        AppState.tasks                                │
│  ┌──────────┬──────────┬──────────┬──────────┬──────────┬────────┐ │
│  │local_bash│local_agent│remote_   │in_process│local_    │monitor │ │
│  │          │          │agent     │teammate  │workflow  │_mcp    │ │
│  └──────────┴──────────┴──────────┴──────────┴────┬─────┴────────┘ │
└───────────────────────────────────────────────────┼─────────────────┘
                                                    │
                    ┌───────────────────────────────┘
                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│              BackgroundTasksDialog                                    │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  列表视图（按类型分类 + 排序）                                 │   │
│  │  leader → teammates → bash → monitorMcp → remote             │   │
│  │  → agent → workflows → dreamTasks                            │   │
│  └───────────────────────────────────┬─────────────────────────┘   │
│                                      │ Enter (选中 workflow)        │
│                                      ▼                              │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  WorkflowDetailDialog（详情视图）                              │   │
│  │  ├─ Phase 进度树（phaseIndex 分组）                            │   │
│  │  ├─ Agent 列表（状态、token、工具调用）                        │   │
│  │  ├─ onKill → killWorkflowTask (整体终止)                      │   │
│  │  ├─ onSkipAgent → skipWorkflowAgent (单个跳过)                │   │
│  │  └─ onRetryAgent → retryWorkflowAgent (单个重试)              │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│              底栏 Pill 标签                                           │
│  "1 background workflow" / "N background workflows"                  │
│  / "N background tasks" (混合类型)                                    │
└─────────────────────────────────────────────────────────────────────┘
                    │
                    ▼ (非交互模式)
┌─────────────────────────────────────────────────────────────────────┐
│              SDK 事件流（MAX_QUEUE_SIZE = 1000）                      │
│  task_started  → { workflow_name, prompt }                          │
│  task_progress → { workflow_progress: [Phase 增量批次] }             │
│  task_notification → { status, summary, usage }                     │
└─────────────────────────────────────────────────────────────────────┘
```

## 十二、 小结

Workflow 系统的后台任务集成具有以下特点：

1. **统一框架**：工作流作为 `local_workflow` 类型无缝融入后台任务框架，复用 `BackgroundTasksDialog` 的列表、排序、导航、键盘操作基础设施
2. **特性门控隔离**：`WorkflowDetailDialog` 和操作函数通过 `feature()` + `require()` 加载，避免 1.3K 行代码泄漏到外部构建
3. **三级标签回退**：行渲染采用 `workflowName → summary → description` 优先级，确保最具语义的标签优先显示
4. **Agent 级控制**：详情视图提供 Kill（整体）、Skip Agent（单个）、Retry Agent（单个）三层操作粒度
5. **终态宽限**：工作流详情视图在终态后保持打开，便于用户查看最终状态
6. **SDK 事件流**：通过统一事件队列上报 `task_started`、`task_progress`（含 Phase 增量批次）、`task_notification`，支持 SDK 消费者重建阶段树
7. **Worktree 安全清理**：`wf_<runId>-<idx>` slug 模式 + 严格安全保证确保泄漏 worktree 被安全清理而不误删用户 worktree

---
*本文档基于 `WORKFLOW_SCRIPTS` 特性开关门控的编译产物分析，`WorkflowDetailDialog` 组件存在于编译产物 `cli.js` 中。*

<!-- more -->

## 一、 概述

`LocalWorkflowTask` 是 Workflow 系统在后台任务框架中的具体实现。每个工作流执行实例被建模为一个 `LocalWorkflowTaskState` 状态对象，注册到 `AppState.tasks` 中，与其他后台任务类型（`local_bash`、`local_agent`、`remote_agent` 等）统一管理。本文档分析工作流任务的类型定义、ID 生成、状态注册、生命周期管理，以及 kill/skip/retry 操作的实现。

## 二、 任务类型定义

### 1. TaskType 联合类型

工作流任务在 [`Task.ts`](../../claude-code-source/src/Task.ts#L6-L13) 的 `TaskType` 联合类型中占有一席：

```typescript
// src/Task.ts:6-13
export type TaskType =
  | 'local_bash'
  | 'local_agent'
  | 'remote_agent'
  | 'in_process_teammate'
  | 'local_workflow'    // ← 工作流任务类型
  | 'monitor_mcp'
  | 'dream'
```

### 2. TaskState 联合类型

`LocalWorkflowTaskState` 被纳入 [`tasks/types.ts`](../../claude-code-source/src/tasks/types.ts#L12-L29) 的 `TaskState` 和 `BackgroundTaskState` 联合类型：

```typescript
// src/tasks/types.ts:1-29
import type { LocalWorkflowTaskState } from './LocalWorkflowTask/LocalWorkflowTask.js'

export type TaskState =
  | LocalShellTaskState
  | LocalAgentTaskState
  | RemoteAgentTaskState
  | InProcessTeammateTaskState
  | LocalWorkflowTaskState    // ← 工作流任务状态
  | MonitorMcpTaskState
  | DreamTaskState

export type BackgroundTaskState =
  | LocalShellTaskState
  | LocalAgentTaskState
  | RemoteAgentTaskState
  | InProcessTeammateTaskState
  | LocalWorkflowTaskState    // ← 同样包含在后台任务中
  | MonitorMcpTaskState
  | DreamTaskState
```

【**注意**】`LocalWorkflowTaskState` 的导入路径 `./LocalWorkflowTask/LocalWorkflowTask.js` 指向的模块**不存在为独立源码文件**——它仅存在于编译产物 `cli.js` 中。该导入声明使 TypeScript 类型检查通过，但实际模块仅在 `WORKFLOW_SCRIPTS` 特性开启时通过动态 `require()` 加载。

### 3. 后台任务判定

[`isBackgroundTask()`](../../claude-code-source/src/tasks/types.ts#L37-L46) 是所有后台任务类型的统一判定函数：

```typescript
// src/tasks/types.ts:37-46
export function isBackgroundTask(task: TaskState): task is BackgroundTaskState {
  if (task.status !== 'running' && task.status !== 'pending') {
    return false
  }
  // Foreground tasks (isBackgrounded === false) are not yet "background tasks"
  if ('isBackgrounded' in task && task.isBackgrounded === false) {
    return false
  }
  return true
}
```

工作流任务需同时满足两个条件才被视为后台任务：
1. 状态为 `running` 或 `pending`
2. `isBackgrounded !== false`（即已后台化或未显式前台化）

## 三、 任务 ID 生成

### 1. ID 前缀映射

工作流任务的 ID 以 `w` 开头，定义在 [`Task.ts`](../../claude-code-source/src/Task.ts#L79-87)：

```typescript
// src/Task.ts:79-87
const TASK_ID_PREFIXES: Record<string, string> = {
  local_bash: 'b',          // bash 任务
  local_agent: 'a',         // 本地 Agent
  remote_agent: 'r',        // 远程 Agent
  in_process_teammate: 't', // 进程内队友
  local_workflow: 'w',      // ← 工作流任务
  monitor_mcp: 'm',         // MCP 监控
  dream: 'd',               // dream 任务
}
```

### 2. ID 生成算法

[`generateTaskId()`](../../claude-code-source/src/Task.ts#L98-L106) 使用加密随机数生成 8 位 base36 后缀：

```typescript
// src/Task.ts:94-106
// Case-insensitive-safe alphabet (digits + lowercase) for task IDs.
// 36^8 ≈ 2.8 trillion combinations, sufficient to resist brute-force symlink attacks.
const TASK_ID_ALPHABET = '0123456789abcdefghijklmnopqrstuvwxyz'

export function generateTaskId(type: TaskType): string {
  const prefix = getTaskIdPrefix(type)
  const bytes = randomBytes(8)
  let id = prefix
  for (let i = 0; i < 8; i++) {
    id += TASK_ID_ALPHABET[bytes[i]! % TASK_ID_ALPHABET.length]
  }
  return id
}
```

工作流任务 ID 形如 `w0123456789ab`（`w` + 8 字符）。选用大小写不敏感的字母表（仅数字 + 小写字母）是为了避免在文件系统（大小写不敏感的操作系统）上产生歧义，防止符号链接暴力攻击。

### 3. workflowRunId 与 worktree slug

除了任务 ID 外，工作流还有一个 `workflowRunId`（运行实例 ID），用于 worktree slug 消歧。[`worktree.ts`](../../claude-code-source/src/utils/worktree.ts#L1022-L1041) 记录了 WorkflowTool 的 worktree slug 模式：

```typescript
// src/utils/worktree.ts:1022-1041
/**
 * Slug patterns for throwaway worktrees created by AgentTool (`agent-a<7hex>`,
 * from earlyAgentId.slice(0,8)), WorkflowTool (`wf_<runId>-<idx>` where runId
 * is randomUUID().slice(0,12) = 8 hex + `-` + 3 hex), and bridgeMain
 * (`bridge-<safeFilenameId>`).
 */
const EPHEMERAL_WORKTREE_PATTERNS = [
  /^agent-a[0-9a-f]{7}$/,
  /^wf_[0-9a-f]{8}-[0-9a-f]{3}-\d+$/,    // ← WorkflowTool slug 模式
  // Legacy wf-<idx> slugs from before workflowRunId disambiguation
  /^wf-\d+$/,
  /^bridge-[A-Za-z0-9_]+(-[A-Za-z0-9_]+)*$/,
  /^job-[a-zA-Z0-9._-]{1,55}-[0-9a-f]{8}$/,
]
```

WorkflowTool 的 worktree slug 格式为 `wf_<runId>-<idx>`：
- `runId` = `randomUUID().slice(0,12)`（8 位 hex + `-` + 3 位 hex）
- `idx` = 工作流内 Agent 的索引

【**关键**】`workflowRunId` 的引入解决了早期 `wf-<idx>` slug 格式在不同工作流运行间可能冲突的问题。遗留模式 `wf-\d+` 仍被保留在清理模式中，以清除旧版本泄漏的 worktree。

## 四、 LocalWorkflowTaskState 状态模型

### 1. 基础字段（继承 TaskStateBase）

[`TaskStateBase`](../../claude-code-source/src/Task.ts#L44-L57) 是所有任务状态类型的公共基类：

```typescript
// src/Task.ts:44-57
export type TaskStateBase = {
  id: string
  type: TaskType
  status: TaskStatus
  description: string
  toolUseId?: string
  startTime: number
  endTime?: number
  totalPausedMs?: number
  outputFile: string
  outputOffset: number
  notified: boolean
}
```

### 2. 工作流专属字段

`LocalWorkflowTaskState` 在 `TaskStateBase` 基础上扩展了工作流专属字段。以下字段从代码库的多处间接引用中重建：

| 字段 | 类型 | 引用来源 | 用途 |
|------|------|----------|------|
| `workflowName` | `string` | [`framework.ts` L111](../../claude-code-source/src/utils/task/framework.ts#L111)、[`BackgroundTask.tsx` L221](../../claude-code-source/src/components/tasks/BackgroundTask.tsx#L221) | 工作流脚本 `meta.name`（如 `'spec'`），作为 `task_started` SDK 事件的 `workflow_name` |
| `summary` | `string \| undefined` | [`BackgroundTask.tsx` L221](../../claude-code-source/src/components/tasks/BackgroundTask.tsx#L221)、`BackgroundTasksDialog.tsx` L526 | 工作流摘要，优先于 `description` 用作显示标签 |
| `agentCount` | `number` | [`BackgroundTask.tsx` L232](../../claude-code-source/src/components/tasks/BackgroundTask.tsx#L232) | 当前工作流管理的 Agent 数量，运行时显示为 `"N agents"` |
| `workflowRunId` | `string` | [`worktree.ts` L1024](../../claude-code-source/src/utils/worktree.ts#L1024) | 运行实例 ID，用于 worktree slug 消歧 |
| `prompt` | `string` | [`framework.ts` L115](../../claude-code-source/src/utils/task/framework.ts#L115) | 工作流提示词，作为 `task_started` SDK 事件的 `prompt` |
| `agentControllers` | `Map<...>` | [`sessionHooks.ts` L46](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L46) | Agent 控制器映射（非响应式，避免高频更新触发重渲染） |
| `isBackgrounded` | `boolean` | [`tasks/types.ts` L42](../../claude-code-source/src/tasks/types.ts#L42) | 是否后台化，`false` 表示前台运行中 |

### 3. 状态访问模式

`framework.ts` 中的 `registerTask()` 使用 `in` 操作符安全访问工作流专属字段，避免对非工作流任务类型访问不存在字段：

```typescript
// src/utils/task/framework.ts:104-116
workflow_name:
  'workflowName' in task
    ? (task.workflowName as string | undefined)
    : undefined,
prompt: 'prompt' in task ? (task.prompt as string) : undefined,
```

这种模式确保 `registerTask` 能统一处理所有 7 种任务类型，仅在工作流任务上提取 `workflowName` 和 `prompt`。

## 五、 任务注册

### 1. registerTask 流程

[`registerTask()`](../../claude-code-source/src/utils/task/framework.ts#L77-L117) 是所有任务类型的统一注册入口：

```typescript
// src/utils/task/framework.ts:77-117
export function registerTask(task: TaskState, setAppState: SetAppState): void {
  let isReplacement = false
  setAppState(prev => {
    const existing = prev.tasks[task.id]
    isReplacement = existing !== undefined
    // 恢复场景：保留 UI 持有状态（retain、startTime、messages、diskLoaded、pendingMessages）
    const merged =
      existing && 'retain' in existing
        ? {
            ...task,
            retain: existing.retain,
            startTime: existing.startTime,
            messages: existing.messages,
            diskLoaded: existing.diskLoaded,
            pendingMessages: existing.pendingMessages,
          }
        : task
    return { ...prev, tasks: { ...prev.tasks, [task.id]: merged } }
  })

  // 替换（恢复）场景跳过事件发射，避免重复
  if (isReplacement) return

  // 发射 task_started SDK 事件
  enqueueSdkEvent({
    type: 'system',
    subtype: 'task_started',
    task_id: task.id,
    tool_use_id: task.toolUseId,
    description: task.description,
    task_type: task.type,
    workflow_name:
      'workflowName' in task
        ? (task.workflowName as string | undefined)
        : undefined,
    prompt: 'prompt' in task ? (task.prompt as string) : undefined,
  })
}
```

### 2. task_started SDK 事件

工作流任务注册时发射的 `task_started` 事件包含工作流专属字段，其 schema 定义在 [`coreSchemas.ts`](../../claude-code-source/src/entrypoints/sdk/coreSchemas.ts#L1715-L1733)：

```typescript
// src/entrypoints/sdk/coreSchemas.ts:1715-1733
export const SDKTaskStartedMessageSchema = lazySchema(() =>
  z.object({
    type: z.literal('system'),
    subtype: z.literal('task_started'),
    task_id: z.string(),
    tool_use_id: z.string().optional(),
    description: z.string(),
    task_type: z.string().optional(),
    workflow_name: z
      .string()
      .optional()
      .describe(
        "meta.name from the workflow script (e.g. 'spec'). Only set when task_type is 'local_workflow'.",
      ),
    prompt: z.string().optional(),
    uuid: UUIDPlaceholder(),
    session_id: z.string(),
  }),
)
```

【**关键**】`workflow_name` 字段的文档明确说明："Only set when task_type is 'local_workflow'"。SDK 消费者（如 VS Code 子 Agent 面板）可据此区分工作流任务与其他任务类型。

### 3. 任务状态更新

[`updateTaskState()`](../../claude-code-source/src/utils/task/framework.ts#L48-L72) 提供类型安全的状态更新辅助函数：

```typescript
// src/utils/task/framework.ts:48-72
export function updateTaskState<T extends TaskState>(
  taskId: string,
  setAppState: SetAppState,
  updater: (task: T) => T,
): void {
  setAppState(prev => {
    const task = prev.tasks?.[taskId] as T | undefined
    if (!task) {
      return prev
    }
    const updated = updater(task)
    if (updated === task) {
      // Updater returned the same reference (early-return no-op). Skip the
      // spread so s.tasks subscribers don't re-render on unchanged state.
      return prev
    }
    return {
      ...prev,
      tasks: {
        ...prev.tasks,
        [taskId]: updated,
      },
    }
  })
}
```

工作流执行引擎通过 `updateTaskState<LocalWorkflowTaskState>(...)` 更新工作流状态（如 Phase 进度、agentCount 变化）。

## 六、 任务状态转换

### 1. TaskStatus 枚举

```typescript
// src/Task.ts:15-21
export type TaskStatus =
  | 'pending'      // 等待中
  | 'running'      // 运行中
  | 'completed'    // 已完成
  | 'failed'       // 已失败
  | 'killed'       // 已终止
```

### 2. 终态判定

[`isTerminalTaskStatus()`](../../claude-code-source/src/Task.ts#L27-L29) 判定任务是否处于终态：

```typescript
// src/Task.ts:27-29
export function isTerminalTaskStatus(status: TaskStatus): boolean {
  return status === 'completed' || status === 'failed' || status === 'killed'
}
```

终态用于：
- 防止向已死亡的工作流注入消息
- 从 AppState 中驱逐已完成任务
- 孤儿清理路径

### 3. 工作流状态转换图

```
                    registerTask()
                         │
                         ▼
                     ┌────────┐
                     │pending │
                     └───┬────┘
                         │ 开始执行
                         ▼
                     ┌────────┐  killWorkflowTask()  ┌────────┐
                     │running │─────────────────────→│killed  │
                     └──┬─────┘                       └────────┘
                        │
            ┌───────────┼───────────┐
   所有Phase │     Phase失败 │    用户kill │
   完成     │             │           │
            ▼             ▼           ▼
       ┌─────────┐   ┌─────────┐  ┌────────┐
       │completed│   │ failed  │  │killed  │
       └─────────┘   └─────────┘  └────────┘
            │             │           │
            └─────────────┴───────────┘
                         │
                   isTerminalTaskStatus() = true
                         │
                         ▼
              emitTaskTerminatedSdk()
              (task_notification 事件)
```

## 七、 kill/skip/retry 操作

`LocalWorkflowTask.js` 模块导出三个工作流专属操作函数，通过特性门控的动态 `require()` 加载到 [`BackgroundTasksDialog.tsx`](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L105-L113)：

```typescript
// src/components/tasks/BackgroundTasksDialog.tsx:105-113
const workflowTaskModule = feature('WORKFLOW_SCRIPTS')
  ? require('src/tasks/LocalWorkflowTask/LocalWorkflowTask.js') as typeof import('src/tasks/LocalWorkflowTask/LocalWorkflowTask.js')
  : null
const killWorkflowTask = workflowTaskModule?.killWorkflowTask ?? null
const skipWorkflowAgent = workflowTaskModule?.skipWorkflowAgent ?? null
const retryWorkflowAgent = workflowTaskModule?.retryWorkflowAgent ?? null
```

### 1. killWorkflowTask

终止整个工作流任务：

```typescript
function killWorkflowTask(taskId: string, setAppState: SetAppState): void
```

调用场景（[`BackgroundTasksDialog.tsx` L271-273](../../claude-code-source/src/components/tasks/BackgroundTasksDialog.tsx#L271)）：
- 用户在后台任务列表中选中工作流任务并按 `x` 键
- 详情视图中点击 kill 按钮（仅 `status === 'running'` 时可用）

```typescript
// BackgroundTasksDialog.tsx:271-273
} else if (currentSelection_0.type === 'local_workflow'
           && currentSelection_0.status === 'running'
           && killWorkflowTask) {
  killWorkflowTask(currentSelection_0.id, setAppState)
}
```

### 2. skipWorkflowAgent

跳过工作流中某个 Agent（使其不执行或中断）：

```typescript
function skipWorkflowAgent(
  taskId: string,
  agentId: string,
  setAppState: SetAppState,
): void
```

调用场景（详情视图，仅 `status === 'running'` 时可用）：

```typescript
// BackgroundTasksDialog.tsx:386
onSkipAgent={task_0.status === 'running' && skipWorkflowAgent
  ? agentId => skipWorkflowAgent(task_0.id, agentId, setAppState)
  : undefined}
```

### 3. retryWorkflowAgent

重试工作流中某个失败的 Agent：

```typescript
function retryWorkflowAgent(
  taskId: string,
  agentId: string,
  setAppState: SetAppState,
): void
```

调用场景（详情视图，仅 `status === 'running'` 时可用）：

```typescript
// BackgroundTasksDialog.tsx:386
onRetryAgent={task_0.status === 'running' && retryWorkflowAgent
  ? agentId_0 => retryWorkflowAgent(task_0.id, agentId_0, setAppState)
  : undefined}
```

【**注意**】`skipWorkflowAgent` 和 `retryWorkflowAgent` 接受 `agentId` 参数，说明工作流内部的每个 Agent 都有独立标识符，可被单独控制。这些 Agent 的状态通过 `LocalWorkflowTaskState.agentControllers` 映射管理。

## 八、 任务终止事件

### 1. emitTaskTerminatedSdk

当工作流任务进入终态时，需通过 [`emitTaskTerminatedSdk()`](../../claude-code-source/src/utils/sdkEventQueue.ts#L114-L134) 发射 `task_notification` SDK 事件，使 SDK 消费者感知任务关闭：

```typescript
// src/utils/sdkEventQueue.ts:114-134
export function emitTaskTerminatedSdk(
  taskId: string,
  status: 'completed' | 'failed' | 'stopped',
  opts?: {
    toolUseId?: string
    summary?: string
    outputFile?: string
    usage?: { total_tokens: number; tool_uses: number; duration_ms: number }
  },
): void {
  enqueueSdkEvent({
    type: 'system',
    subtype: 'task_notification',
    task_id: taskId,
    tool_use_id: opts?.toolUseId,
    status,
    output_file: opts?.outputFile ?? '',
    summary: opts?.summary ?? '',
    usage: opts?.usage,
  })
}
```

### 2. 双通道通知机制

工作流任务的终态通知通过两个通道传播：

1. **XML 通知**：通过 `enqueuePendingNotification` + `<task-id>` XML 标签，由 `print.ts` 解析为 SDK 事件
2. **直接 SDK 事件**：通过 `emitTaskTerminatedSdk()` 直接入队

【**关键**】为避免双发，文档明确说明："Paths that suppress the XML notification (notified:true pre-set, kill paths, abort branches) must call this directly so SDK consumers see the task close."——即抑制 XML 通知的路径（如 kill、abort）必须直接调用 `emitTaskTerminatedSdk()`。

## 九、 agentControllers 与 sessionHooks

[`sessionHooks.ts`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L46) 中的注释揭示了 `LocalWorkflowTaskState.agentControllers` 的设计意图：

```typescript
// src/utils/hooks/sessionHooks.ts:46
// Same pattern as agentControllers on LocalWorkflowTaskState.
```

`agentControllers` 是一个 **非响应式** 的 `Map`，用于存储工作流内各 Agent 的 AbortController 和控制句柄。将其设为非响应式（不纳入 AppState 响应式追踪）的原因是：

> This matters under high-concurrency workflows: parallel() with N agents would otherwise trigger N re-renders per state change.

高并发工作流场景下，`parallel()` 并行执行 N 个 Agent，如果 Agent 控制器是响应式的，每次状态变化都会触发 N 次重渲染。使用普通 `Map` 避免了这一性能问题。

## 十、 小结

`LocalWorkflowTaskState` 作为工作流在后台任务框架中的状态表示，具有以下设计特点：

1. **统一任务体系**：以 `local_workflow` 类型融入 7 种任务类型的统一管理体系，复用 `TaskStateBase` 基础字段和通用的注册、更新、终态判定逻辑
2. **工作流专属扩展**：通过 `workflowName`、`agentCount`、`workflowRunId`、`agentControllers` 等字段扩展，支持多阶段编排和 Agent 级控制
3. **非响应式控制层**：`agentControllers` 采用普通 `Map` 而非响应式状态，优化高并发场景下的渲染性能
4. **细粒度操作**：`killWorkflowTask`（整体终止）、`skipWorkflowAgent`（跳过单个 Agent）、`retryWorkflowAgent`（重试单个 Agent）提供从工作流级到 Agent级的分层控制
5. **双通道通知**：终态通过 XML 通知和直接 SDK 事件双通道传播，kill/abort 路径直接调用 `emitTaskTerminatedSdk` 避免遗漏

工作流的执行引擎和 Phase 编排详见 [LV093-WorkflowTool与执行引擎](LV093-WorkflowTool与执行引擎.md)。

---
*本文档基于 `WORKFLOW_SCRIPTS` 特性开关门控的编译产物分析，`LocalWorkflowTaskState` 的完整类型定义存在于编译产物 `cli.js` 中。*

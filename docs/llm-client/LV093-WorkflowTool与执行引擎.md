<!-- more -->

## 一、 概述

`WorkflowTool` 是 LLM 启动结构化工作流执行的入口工具。与斜杠命令触发路径（用户输入 `/<workflow-name>`）不同，`WorkflowTool` 允许 LLM 在对话中主动调用工作流，将多阶段、多 Agent 的编排任务委托给工作流执行引擎。本文档分析 `WorkflowTool` 的工具定义、递归执行防护、执行引擎的 Phase 编排模型，以及进度追踪与 SDK 事件发射机制。

## 二、 工具定义

### 1. 工具名称

`WorkflowTool` 的工具名常量定义在 [`constants.ts`](../../claude-code-source/src/tools/WorkflowTool/constants.ts#L1-L2)：

```typescript
// src/tools/WorkflowTool/constants.ts
export const WORKFLOW_TOOL_NAME = 'WorkflowTool'
```

### 2. 工具定义位置

`WorkflowTool` 的完整工具定义（输入 Schema、`call()` 逻辑、提示词）存在于编译产物 `src/tools/WorkflowTool/WorkflowTool.js` 中，该模块**不存在为独立源码文件**。工具通过特性门控加载，在 `WORKFLOW_SCRIPTS` 关闭时完全缺席工具池。

### 3. 输入 Schema（推断）

基于工作流的功能需求和 `LocalWorkflowTaskState` 的字段，`WorkflowTool` 的输入 Schema 应包含以下参数（推断结构）：

| 参数 | 类型 | 说明 |
|------|------|------|
| `workflow` | `string` | 工作流名称（对应脚本的 `meta.name`） |
| `prompt` / `args` | `string` | 工作流执行提示词或参数 |
| `description` | `string` | 任务描述（3-5 词，用于后台任务列表显示） |

### 4. call() 执行流程

`WorkflowTool.call()` 的执行流程（基于状态模型和任务框架推断）：

```
1. 解析输入参数（workflow 名称、prompt、description）
2. generateTaskId('local_workflow') → 生成 'w' 前缀的任务 ID
3. 生成 workflowRunId（randomUUID().slice(0,12)）
4. 构建 LocalWorkflowTaskState 初始状态（status: 'pending'）
5. registerTask(taskState, setAppState) → 写入 AppState.tasks
   └─ 发射 task_started SDK 事件（含 workflow_name、prompt）
6. 启动工作流执行引擎（异步）
   ├─ 按 Phase 顺序执行
   ├─ 每个 Phase 内并行 spawn Agent
   ├─ flushProgress 批量上报进度
   └─ 更新 LocalWorkflowTaskState
7. 工作流完成 → 标记 completed/failed
   └─ emitTaskTerminatedSdk() 发射 task_notification 事件
8. 返回工具结果（outputFile 路径等）
```

## 三、 递归执行防护

### 1. 工具池禁用

工作流内部 spawn 的子 Agent **不能**再次调用 `WorkflowTool`，防止递归工作流执行。[`constants/tools.ts`](../../claude-code-source/src/constants/tools.ts#L36-L46) 将 `WORKFLOW_TOOL_NAME` 加入所有 Agent 的禁用工具集：

```typescript
// src/constants/tools.ts:36-46
export const ALL_AGENT_DISALLOWED_TOOLS = new Set([
  TASK_OUTPUT_TOOL_NAME,
  EXIT_PLAN_MODE_V2_TOOL_NAME,
  ENTER_PLAN_MODE_TOOL_NAME,
  // Allow Agent tool for agents when user is ant (enables nested agents)
  ...(process.env.USER_TYPE === 'ant' ? [] : [AGENT_TOOL_NAME]),
  ASK_USER_QUESTION_TOOL_NAME,
  TASK_STOP_TOOL_NAME,
  // Prevent recursive workflow execution inside subagents.
  ...(feature('WORKFLOW_SCRIPTS') ? [WORKFLOW_TOOL_NAME] : []),
])
```

【**关键**】该禁用规则通过 [`resolveAgentTools()`](../../claude-code-source/src/tools/AgentTool/agentToolUtils.ts#L122-L225) 的 `filterToolsForAgent()` 在子 Agent 工具池组装时生效。这意味着：
- 工作流 spawn 的 Agent → 工具池无 `WorkflowTool`
- 工作流 spawn 的 Agent 再 spawn 的孙 Agent → 工具池仍无 `WorkflowTool`
- 从根本上阻断了工作流的递归执行链

### 2. 权限分类器排除

[`classifierDecision.ts`](../../claude-code-source/src/utils/permissions/classifierDecision.ts#L43-L67) 同样将 `WorkflowTool` 排除出安全工具白名单（`SAFE_YOLO_ALLOWLISTED_TOOLS`），这意味着 `WorkflowTool` 的调用始终需要经过权限分类，不能被 auto 模式快速放行：

```typescript
// src/utils/permissions/classifierDecision.ts:43-47
const WORKFLOW_TOOL_NAME = feature('WORKFLOW_SCRIPTS')
  ? (
      require('../../tools/WorkflowTool/constants.js') as typeof import('../../tools/WorkflowTool/constants.js')
    ).WORKFLOW_TOOL_NAME
  : null
```

`WORKFLOW_TOOL_NAME` 未被加入 `SAFE_YOLO_ALLOWLISTED_TOOLS` 集合，因此每次调用都需分类器评估。

## 四、 Phase 阶段化执行模型

### 1. Phase 概念

工作流执行引擎采用 **Phase（阶段）** 作为编排的基本单元。从 SDK 进度事件的 `phaseIndex` 字段（[`sdkEventQueue.ts`](../../claude-code-source/src/utils/sdkEventQueue.ts#L31)）可知，工作流由多个有序阶段组成：

```typescript
// src/utils/sdkEventQueue.ts:30-33
// Delta batch of workflow state changes. Clients upsert by
// `${type}:${index}` then group by phaseIndex to rebuild the phase tree,
// same fold as collectFromEvents + groupByPhase in PhaseProgress.tsx.
workflow_progress?: SdkWorkflowProgress[]
```

### 2. Phase 树结构

SDK 消费者通过 `workflow_progress` 增量批次重建 Phase 树。重建算法：

1. **upsert by `${type}:${index}`**：每条进度记录以 `类型:索引` 为键去重更新
2. **group by phaseIndex**：按 `phaseIndex` 分组，重建阶段树

`PhaseProgress.tsx` 组件（编译产物）实现了相同的 fold 逻辑（`collectFromEvents` + `groupByPhase`），用于在 TUI 中渲染阶段进度树。

### 3. 执行顺序

基于 Phase 树模型和 `agentCount` 字段，工作流的执行模型推断如下：

```
Phase 0                Phase 1                Phase 2
┌──────────┐          ┌──────────┐          ┌──────────┐
│ Agent A  │          │ Agent D  │          │ Agent F  │
│ Agent B  │ ──完成──→│ Agent E  │ ──完成──→│ Agent G  │
│ Agent C  │          │          │          │          │
└──────────┘          └──────────┘          └──────────┘
  并行执行               串行等待               串行等待
```

- **Phase 内**：多个 Agent 可并行执行（`parallel()` 模式）
- **Phase 间**：前一个 Phase 的所有 Agent 完成后，后一个 Phase 才开始
- `agentCount`：反映当前活跃 Agent 总数（跨所有 Phase）

### 4. Agent 编排

工作流内的 Agent 通过 `agentControllers` 映射管理（详见 [LV092](LV092-WorkflowTask状态模型与生命周期.md#九-agentcontrollers-与-sessionhooks)）。每个 Agent 拥有独立的：
- `agentId`：用于 skip/retry 操作
- `AbortController`：用于终止单个 Agent
- 执行状态：pending/running/completed/failed

`skipWorkflowAgent(taskId, agentId, ...)` 和 `retryWorkflowAgent(taskId, agentId, ...)` 通过 `agentControllers` 定位并控制特定 Agent。

## 五、 进度追踪与 SDK 事件

### 1. emitTaskProgress

[`sdkProgress.ts`](../../claude-code-source/src/utils/task/sdkProgress.ts#L10-L36) 的 `emitTaskProgress()` 是工作流进度上报的统一函数，同时服务于后台 Agent 和工作流：

```typescript
// src/utils/task/sdkProgress.ts:1-36
import type { SdkWorkflowProgress } from '../../types/tools.js'
import { enqueueSdkEvent } from '../sdkEventQueue.js'

/**
 * Emit a `task_progress` SDK event. Shared by background agents (per tool_use
 * in runAsyncAgentLifecycle) and workflows (per flushProgress batch). Accepts
 * already-computed primitives so callers can derive them from their own state
 * shapes (ProgressTracker for agents, LocalWorkflowTaskState for workflows).
 */
export function emitTaskProgress(params: {
  taskId: string
  toolUseId: string | undefined
  description: string
  startTime: number
  totalTokens: number
  toolUses: number
  lastToolName?: string
  summary?: string
  workflowProgress?: SdkWorkflowProgress[]
}): void {
  enqueueSdkEvent({
    type: 'system',
    subtype: 'task_progress',
    task_id: params.taskId,
    tool_use_id: params.toolUseId,
    description: params.description,
    usage: {
      total_tokens: params.totalTokens,
      tool_uses: params.toolUses,
      duration_ms: Date.now() - params.startTime,
    },
    last_tool_name: params.lastToolName,
    summary: params.summary,
    workflow_progress: params.workflowProgress,
  })
}
```

### 2. flushProgress 批处理

工作流采用 **`flushProgress` 批处理** 模式上报进度，而非逐事件上报。注释明确说明：

> "workflows (per flushProgress batch)"

这意味着工作流引擎将多个状态变更累积后批量调用 `emitTaskProgress()`，减少 SDK 事件频率。批处理的触发时机推断为：
- Phase 完成时
- Agent 状态变更时
- 定时刷新

### 3. SdkWorkflowProgress 类型

`SdkWorkflowProgress` 类型定义在 `src/types/tools.js`（编译产物），表示工作流状态变更的增量记录。每条记录包含：
- `type`：变更类型（如 phase 开始、agent 状态变更）
- `index`：在同类变更中的索引
- `phaseIndex`：所属阶段索引
- 其他状态字段

SDK 消费者通过 `${type}:${index}` 键去重 upsert，再按 `phaseIndex` 分组重建阶段树。

### 4. task_progress SDK 事件 Schema

```typescript
// src/entrypoints/sdk/coreSchemas.ts:1750-1767
export const SDKTaskProgressMessageSchema = lazySchema(() =>
  z.object({
    type: z.literal('system'),
    subtype: z.literal('task_progress'),
    task_id: z.string(),
    tool_use_id: z.string().optional(),
    description: z.string(),
    usage: z.object({
      total_tokens: z.number(),
      tool_uses: z.number(),
      duration_ms: z.number(),
    }),
    last_tool_name: z.string().optional(),
    summary: z.string().optional(),
    uuid: UUIDPlaceholder(),
    session_id: z.string(),
  }),
)
```

【**注意**】公开的 `SDKTaskProgressMessageSchema` 中未显式包含 `workflow_progress` 字段，但 `sdkEventQueue.ts` 的 `TaskProgressEvent` 类型明确包含该字段。这表明 `workflow_progress` 是工作流专属的扩展字段，仅在 `task_type === 'local_workflow'` 时出现。

## 六、 SyntheticOutputTool 与结构化输出

工作流脚本频繁调用带 schema 的 Agent 进行结构化输出（如 `agent({schema: BUGS_SCHEMA})`）。[`SyntheticOutputTool`](../../claude-code-source/src/tools/SyntheticOutputTool/SyntheticOutputTool.ts#L105-L119) 为此场景提供了带身份缓存的工具创建：

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
  // ...
}
```

### 性能优化原理

| 指标 | 无缓存 | 有缓存（WeakMap） |
|------|--------|-------------------|
| 单次 Ajv 开销 | ~1.4ms（JIT codegen） | ~0.05ms（缓存命中） |
| 80 次调用总开销 | ~110ms | ~4ms |
| 缓存键 | — | schema 对象引用（身份相等） |

【**关键**】`WeakMap` 以 schema 对象引用为键，当 schema 对象被垃圾回收时缓存条目自动清除。工作流单次运行中同一 schema 对象被复用 30-80 次，身份缓存将总开销降低约 27 倍。

## 七、 Worktree 隔离

工作流内的 Agent 可在独立的 Git Worktree 中执行，实现文件变更隔离。[`worktree.ts`](../../claude-code-source/src/utils/worktree.ts#L1022-L1041) 记录了 WorkflowTool 的 worktree slug 模式：

```
wf_<runId>-<idx>
  │      │      │
  │      │      └─ Agent 索引（同一工作流内递增）
  │      └─ randomUUID().slice(0,12) = 8 hex + `-` + 3 hex
  └─ 固定前缀
```

### 1. Slug 唯一性

`workflowRunId` 确保不同工作流运行的 worktree slug 不冲突：

```
工作流运行 A:  wf_a1b2c3d4-e5f-0, wf_a1b2c3d4-e5f-1, wf_a1b2c3d4-e5f-2
工作流运行 B:  wf_f6e7d8c9-b0a-0, wf_f6e7d8c9-b0a-1
```

### 2. 泄漏清理

工作流 worktree 在父进程被 kill（Ctrl+C、ESC、崩溃）时可能泄漏。[`EPHEMERAL_WORKTREE_PATTERNS`](../../claude-code-source/src/utils/worktree.ts#L1030-L1041) 中的正则模式用于 30 天清理周期中识别并移除这些临时 worktree：

```typescript
// src/utils/worktree.ts:1030-1041
const EPHEMERAL_WORKTREE_PATTERNS = [
  /^agent-a[0-9a-f]{7}$/,
  /^wf_[0-9a-f]{8}-[0-9a-f]{3}-\d+$/,         // WorkflowTool slug
  /^wf-\d+$/,                                   // 遗留格式
  /^bridge-[A-Za-z0-9_]+(-[A-Za-z0-9_]+)*$/,
  /^job-[a-zA-Z0-9._-]{1,55}-[0-9a-f]{8}$/,
]
```

清理安全性保证：
- 仅匹配临时 slug 模式（不触碰用户命名的 worktree）
- 跳过当前会话的 worktree
- `git status` 失败或有跟踪变更时跳过（fail-closed）
- 有未推送到远程的提交时跳过（fail-closed）

## 八、 完整执行时序

```
用户/LLM 触发
    │
    ▼
WorkflowTool.call()
    │
    ├─ generateTaskId('local_workflow') → 'w01234567'
    ├─ 生成 workflowRunId → 'a1b2c3d4-e5f'
    ├─ 构建 LocalWorkflowTaskState (status: pending)
    │
    ├─ registerTask() → 写入 AppState
    │   └─ enqueueSdkEvent(task_started)
    │       { task_type: 'local_workflow', workflow_name: 'spec', prompt: '...' }
    │
    ├─ 状态 → running
    │
    ├─ Phase 0 执行
    │   ├─ spawn Agent A (worktree: wf_a1b2c3d4-e5f-0)
    │   ├─ spawn Agent B (worktree: wf_a1b2c3d4-e5f-1)
    │   ├─ spawn Agent C (worktree: wf_a1b2c3d4-e5f-2)
    │   ├─ parallel() 并行执行
    │   ├─ flushProgress → emitTaskProgress()
    │   │   { workflow_progress: [Phase0 进度增量] }
    │   └─ 所有 Agent 完成
    │
    ├─ Phase 1 执行
    │   ├─ spawn Agent D, E
    │   ├─ flushProgress → emitTaskProgress()
    │   └─ 完成
    │
    ├─ ... (更多 Phase)
    │
    ├─ 所有 Phase 完成
    │
    ├─ 状态 → completed
    │
    └─ emitTaskTerminatedSdk()
        { status: 'completed', summary: '...', usage: {...} }
```

## 九、 小结

`WorkflowTool` 与工作流执行引擎的核心设计：

1. **LLM 可调用**：`WorkflowTool` 作为标准工具暴露给 LLM，使其能在对话中主动启动结构化工作流
2. **递归防护**：通过 `ALL_AGENT_DISALLOWED_TOOLS` 从工具池层面阻断工作流的递归执行
3. **Phase 编排**：多阶段串行、阶段内 Agent 并行的编排模型，通过 `phaseIndex` 和 `workflow_progress` 增量批次追踪
4. **批处理进度**：`flushProgress` 批量上报模式减少 SDK 事件频率，适配高并发 Agent 场景
5. **结构化输出优化**：`SyntheticOutputTool` 的 `WeakMap` 身份缓存将高频 schema 编译开销降低 27 倍
6. **Worktree 隔离**：`wf_<runId>-<idx>` slug 格式确保 Agent 间文件变更隔离，`workflowRunId` 保证跨运行唯一性

后台任务系统的 UI 集成详见 [LV094-Workflow与后台任务系统集成](LV094-Workflow与后台任务系统集成.md)。

---
*本文档基于 `WORKFLOW_SCRIPTS` 特性开关门控的编译产物分析，`WorkflowTool` 的完整实现和 `SdkWorkflowProgress` 类型定义存在于编译产物 `cli.js` 中。*

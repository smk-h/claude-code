<!-- more -->

## 一、 概述

本文档涵盖 Hook 机制的事件包装器与工具执行集成。每种事件有对应的包装器函数，负责构造 `HookInput` 并调用执行引擎。工具相关事件（PreToolUse/PostToolUse）的 hook 结果通过集成层转为工具执行流程可消费的类型，并参与权限决策。本文档详细分析各事件的包装器实现与工具集成逻辑。

## 二、 基础输入构造

### 1. createBaseHookInput()

[`createBaseHookInput()`](../../claude-code-source/src/utils/hooks.ts#L301-L328) 构造所有事件共享的基础输入：

```typescript
// src/utils/hooks.ts#L301-L328
export function createBaseHookInput(
  permissionMode?: string,
  sessionId?: string,
  agentInfo?: { agentId?: string; agentType?: string },
): {
  session_id: string
  transcript_path: string
  cwd: string
  permission_mode?: string
  agent_id?: string
  agent_type?: string
} {
  const resolvedSessionId = sessionId ?? getSessionId()
  // agent_type: subagent's type (from toolUseContext) takes precedence over
  // the session's --agent flag. Hooks use agent_id presence to distinguish
  // subagent calls from main-thread calls in a --agent session.
  const resolvedAgentType = agentInfo?.agentType ?? getMainThreadAgentType()
  return {
    session_id: resolvedSessionId,
    transcript_path: getTranscriptPathForSession(resolvedSessionId),
    cwd: getCwd(),
    permission_mode: permissionMode,
    agent_id: agentInfo?.agentId,
    agent_type: resolvedAgentType,
  }
}
```

`agent_type` 的优先级：子 Agent 类型（来自 `toolUseContext`）> 会话的 `--agent` 标志。hook 通过 `agent_id` 是否存在区分子 Agent 调用与 `--agent` 会话的主线程调用。

## 三、 事件包装器汇总

所有事件包装器按执行路径分为两类：

| 事件 | 包装器函数 | 执行路径 | matchQuery |
|------|-----------|----------|------------|
| `PreToolUse` | [`executePreToolHooks()`](../../claude-code-source/src/utils/hooks.ts#L3394-L3436) | REPL | `tool_name` |
| `PostToolUse` | [`executePostToolHooks()`](../../claude-code-source/src/utils/hooks.ts#L3450-L3477) | REPL | `tool_name` |
| `PostToolUseFailure` | [`executePostToolUseFailureHooks()`](../../claude-code-source/src/utils/hooks.ts#L3492-L3527) | REPL | `tool_name` |
| `PermissionDenied` | [`executePermissionDeniedHooks()`](../../claude-code-source/src/utils/hooks.ts#L3529-L3562) | REPL | `tool_name` |
| `UserPromptSubmit` | [`executeUserPromptSubmitHooks()`](../../claude-code-source/src/utils/hooks.ts#L3826-L3855) | REPL | 无 |
| `Stop` / `SubagentStop` | [`executeStopHooks()`](../../claude-code-source/src/utils/hooks.ts#L3639-L3697) | REPL | 无 |
| `SubagentStart` | [`executeSubagentStartHooks()`](../../claude-code-source/src/utils/hooks.ts#L3932-L3952) | REPL | `agent_type` |
| `SessionStart` | [`executeSessionStartHooks()`](../../claude-code-source/src/utils/hooks.ts#L3867-L3892) | REPL | `source` |
| `Setup` | [`executeSetupHooks()`](../../claude-code-source/src/utils/hooks.ts#L3902-L3922) | REPL | `trigger` |
| `Notification` | [`executeNotificationHooks()`](../../claude-code-source/src/utils/hooks.ts#L3570-L3592) | REPL 外 | `notification_type` |
| `StopFailure` | [`executeStopFailureHooks()`](../../claude-code-source/src/utils/hooks.ts#L3594-L3627) | REPL 外 | `error` |
| `PreCompact` | [`executePreCompactHooks()`](../../claude-code-source/src/utils/hooks.ts#L3961-L4033) | REPL 外 | `trigger` |
| `PostCompact` | [`executePostCompactHooks()`](../../claude-code-source/src/utils/hooks.ts#L4034) | REPL 外 | `trigger` |
| `SessionEnd` | [`executeSessionEndHooks()`](../../claude-code-source/src/utils/hooks.ts#L4097) | REPL 外 | `reason` |
| `ConfigChange` | [`executeConfigChangeHooks()`](../../claude-code-source/src/utils/hooks.ts#L4214) | REPL 外 | `source` |
| `CwdChanged` | [`executeCwdChangedHooks()`](../../claude-code-source/src/utils/hooks.ts#L4260) | REPL 外 | 无 |
| `FileChanged` | [`executeFileChangedHooks()`](../../claude-code-source/src/utils/hooks.ts#L4278) | REPL 外 | 文件名 |
| `InstructionsLoaded` | [`executeInstructionsLoadedHooks()`](../../claude-code-source/src/utils/hooks.ts#L4335) | REPL 外 | `load_reason` |
| `PermissionRequest` | [`executePermissionRequestHooks()`](../../claude-code-source/src/utils/hooks.ts#L4157) | REPL | `tool_name` |
| `TeammateIdle` | [`executeTeammateIdleHooks()`](../../claude-code-source/src/utils/hooks.ts#L3709-L3729) | REPL | 无 |
| `TaskCreated` | [`executeTaskCreatedHooks()`](../../claude-code-source/src/utils/hooks.ts#L3745-L3773) | REPL | 无 |
| `TaskCompleted` | [`executeTaskCompletedHooks()`](../../claude-code-source/src/utils/hooks.ts#L3789-L3817) | REPL | 无 |
| `Elicitation` | [`executeElicitationHooks()`](../../claude-code-source/src/utils/hooks.ts#L4470) | REPL 外 | `mcp_server_name` |
| `ElicitationResult` | [`executeElicitationResultHooks()`](../../claude-code-source/src/utils/hooks.ts#L4525) | REPL 外 | `mcp_server_name` |
| `WorktreeCreate` | [`executeWorktreeCreateHook()`](../../claude-code-source/src/utils/hooks.ts#L4928) | REPL 外 | 无 |
| `WorktreeRemove` | [`executeWorktreeRemoveHook()`](../../claude-code-source/src/utils/hooks.ts#L4967) | REPL 外 | 无 |

REPL 路径通过 `executeHooks()` yield `AggregatedHookResult`，REPL 外路径通过 `executeHooksOutsideREPL()` 返回 `HookOutsideReplResult[]`。

## 四、 工具相关包装器

### 1. executePreToolHooks()

[`executePreToolHooks()`](../../claude-code-source/src/utils/hooks.ts#L3394-L3436) 在工具执行前触发：

```typescript
// src/utils/hooks.ts#L3394-L3436
export async function* executePreToolHooks<ToolInput>(
  toolName: string,
  toolUseID: string,
  toolInput: ToolInput,
  toolUseContext: ToolUseContext,
  permissionMode?: string,
  signal?: AbortSignal,
  timeoutMs: number = TOOL_HOOK_EXECUTION_TIMEOUT_MS,
  requestPrompt?: (/* ... */) => (request: PromptRequest) => Promise<PromptResponse>,
  toolInputSummary?: string | null,
): AsyncGenerator<AggregatedHookResult> {
  const appState = toolUseContext.getAppState()
  const sessionId = toolUseContext.agentId ?? getSessionId()
  if (!hasHookForEvent('PreToolUse', appState, sessionId)) {
    return
  }

  const hookInput: PreToolUseHookInput = {
    ...createBaseHookInput(permissionMode, undefined, toolUseContext),
    hook_event_name: 'PreToolUse',
    tool_name: toolName,
    tool_input: toolInput,
    tool_use_id: toolUseID,
  }

  yield* executeHooks({ hookInput, toolUseID, matchQuery: toolName, signal, timeoutMs, toolUseContext, requestPrompt, toolInputSummary })
}
```

先通过 `hasHookForEvent()` 快速检查避免无 hook 时的开销。`tool.getToolUseSummary?.(processedInput)` 提供 `toolInputSummary` 用于 UI 展示上下文。

### 2. executePostToolHooks()

[`executePostToolHooks()`](../../claude-code-source/src/utils/hooks.ts#L3450-L3477) 在工具执行后触发，输入额外含 `tool_response`。

### 3. executePostToolUseFailureHooks() 与 executePermissionDeniedHooks()

[`executePostToolUseFailureHooks()`](../../claude-code-source/src/utils/hooks.ts#L3492-L3527) 处理工具失败，输入含 `error` 与 `is_interrupt`。[`executePermissionDeniedHooks()`](../../claude-code-source/src/utils/hooks.ts#L3529-L3562) 处理权限拒绝，输入含 `reason`。

## 五、 会话与停止包装器

### 1. executeSessionStartHooks()

[`executeSessionStartHooks()`](../../claude-code-source/src/utils/hooks.ts#L3867-L3892) 接收 `source`（startup/resume/clear/compact）、`agentType`、`model`，支持 `forceSyncExecution` 强制同步执行（忽略 async 声明），确保 SessionStart hook 在会话开始前完成。

### 2. executeStopHooks()

[`executeStopHooks()`](../../claude-code-source/src/utils/hooks.ts#L3639-L3697) 根据 `subagentId` 是否存在切换事件：

```typescript
// src/utils/hooks.ts#L3653-L3685
const hookEvent = subagentId ? 'SubagentStop' : 'Stop'
const hookInput = subagentId
  ? {
      ...createBaseHookInput(permissionMode),
      hook_event_name: 'SubagentStop',
      stop_hook_active: stopHookActive,
      agent_id: subagentId,
      agent_transcript_path: getAgentTranscriptPath(subagentId),
      agent_type: agentType ?? '',
      last_assistant_message: lastAssistantText,
    }
  : {
      ...createBaseHookInput(permissionMode),
      hook_event_name: 'Stop',
      stop_hook_active: stopHookActive,
      last_assistant_message: lastAssistantText,
    }
```

从最后一条 assistant 消息提取 `last_assistant_message`，使 hook 无需读取 transcript 文件即可检查最终响应。

### 3. executeSetupHooks()

[`executeSetupHooks()`](../../claude-code-source/src/utils/hooks.ts#L3902-L3922) 接收 `trigger`（init/maintenance），同样支持 `forceSyncExecution`。

### 4. executeStopFailureHooks()

[`executeStopFailureHooks()`](../../claude-code-source/src/utils/hooks.ts#L3594-L3627) 在 API 错误结束回合时触发。`error` 默认为 `'unknown'` 确保 matcher 过滤始终应用。通过 `executeHooksOutsideREPL()` 执行（fire-and-forget）。

## 六、 用户交互包装器

### 1. executeUserPromptSubmitHooks()

[`executeUserPromptSubmitHooks()`](../../claude-code-source/src/utils/hooks.ts#L3826-L3855) 在用户提交提示词时触发，使用 `toolUseContext.abortController.signal` 作为 abort 信号。

### 2. executeNotificationHooks()

[`executeNotificationHooks()`](../../claude-code-source/src/utils/hooks.ts#L3570-L3592) 通过 `executeHooksOutsideREPL()` 执行。

## 七、 子 Agent 与团队协作包装器

- [`executeSubagentStartHooks()`](../../claude-code-source/src/utils/hooks.ts#L3932-L3952)：接收 `agentId` 与 `agentType`，`matchQuery` 为 `agentType`
- [`executeTeammateIdleHooks()`](../../claude-code-source/src/utils/hooks.ts#L3709-L3729)：输入含 `teammate_name` 与 `team_name`
- [`executeTaskCreatedHooks()`](../../claude-code-source/src/utils/hooks.ts#L3745-L3773) 与 [`executeTaskCompletedHooks()`](../../claude-code-source/src/utils/hooks.ts#L3789-L3817)：输入含 `task_id`、`task_subject`、`task_description` 等

## 八、 压缩与特殊包装器

- [`executePreCompactHooks()`](../../claude-code-source/src/utils/hooks.ts#L3961-L4033)：成功 hook 的 stdout 作为自定义压缩指令追加
- [`executePostCompactHooks()`](../../claude-code-source/src/utils/hooks.ts#L4034)：压缩后触发，stdout 展示给用户
- [`executeWorktreeCreateHook()`](../../claude-code-source/src/utils/hooks.ts#L4928)：返回 `{ worktreePath }`，hook stdout 作为 worktree 路径
- [`executeElicitationHooks()`](../../claude-code-source/src/utils/hooks.ts#L4470) / [`executeElicitationResultHooks()`](../../claude-code-source/src/utils/hooks.ts#L4525)：处理 MCP elicitation 流程
- [`executeConfigChangeHooks()`](../../claude-code-source/src/utils/hooks.ts#L4214)：配置文件变更时触发
- [`executeCwdChangedHooks()`](../../claude-code-source/src/utils/hooks.ts#L4260) / [`executeFileChangedHooks()`](../../claude-code-source/src/utils/hooks.ts#L4278)：支持 `watchPaths` 动态注册文件监视
- [`executeInstructionsLoadedHooks()`](../../claude-code-source/src/utils/hooks.ts#L4335)：纯观测事件，不支持阻塞

## 九、 与工具执行的集成

集成层在 [`src/services/tools/toolHooks.ts`](../../claude-code-source/src/services/tools/toolHooks.ts) 中实现。

### 1. runPreToolUseHooks()

[`runPreToolUseHooks()`](../../claude-code-source/src/services/tools/toolHooks.ts#L435-L650) 包装 [`executePreToolHooks()`](../../claude-code-source/src/utils/hooks.ts#L3394)，将结果转为联合类型：

```typescript
// src/services/tools/toolHooks.ts#L444-L461
AsyncGenerator<
  | { type: 'message'; message: MessageUpdateLazy<AttachmentMessage | ProgressMessage<HookProgress>> }
  | { type: 'hookPermissionResult'; hookPermissionResult: PermissionResult }
  | { type: 'hookUpdatedInput'; updatedInput: Record<string, unknown> }
  | { type: 'preventContinuation'; shouldPreventContinuation: boolean }
  | { type: 'stopReason'; stopReason: string }
  | { type: 'additionalContext'; message: MessageUpdateLazy<AttachmentMessage> }
  | { type: 'stop' }
>
```

#### 1.1 阻塞错误转权限拒绝

定义在 [`src/services/tools/toolHooks.ts`](../../claude-code-source/src/services/tools/toolHooks.ts#L481-L498)：

```typescript
// src/services/tools/toolHooks.ts#L481-L498
if (result.blockingError) {
  const denialMessage = getPreToolHookBlockingMessage(
    `PreToolUse:${tool.name}`, result.blockingError,
  )
  yield {
    type: 'hookPermissionResult',
    hookPermissionResult: {
      behavior: 'deny',
      message: denialMessage,
      decisionReason: { type: 'hook', hookName: `PreToolUse:${tool.name}`, reason: denialMessage },
    },
  }
}
```

#### 1.2 权限行为映射

定义在 [`src/services/tools/toolHooks.ts`](../../claude-code-source/src/services/tools/toolHooks.ts#L510-L554)：

```typescript
// src/services/tools/toolHooks.ts#L510-L554
if (result.permissionBehavior !== undefined) {
  const decisionReason: PermissionDecisionReason = {
    type: 'hook',
    hookName: `PreToolUse:${tool.name}`,
    hookSource: result.hookSource,
    reason: result.hookPermissionDecisionReason,
  }
  if (result.permissionBehavior === 'allow') {
    yield { type: 'hookPermissionResult', hookPermissionResult: { behavior: 'allow', updatedInput: result.updatedInput, decisionReason } }
  } else if (result.permissionBehavior === 'ask') {
    yield { type: 'hookPermissionResult', hookPermissionResult: { behavior: 'ask', updatedInput: result.updatedInput, message: result.hookPermissionDecisionReason || `...`, decisionReason } }
  } else {
    yield { type: 'hookPermissionResult', hookPermissionResult: { behavior: result.permissionBehavior, message: result.hookPermissionDecisionReason || `...`, decisionReason } }
  }
}
```

#### 1.3 passthrough 模式的 input 修改

定义在 [`src/services/tools/toolHooks.ts`](../../claude-code-source/src/services/tools/toolHooks.ts#L556-L563)：

```typescript
// src/services/tools/toolHooks.ts#L556-L563
if (result.updatedInput && result.permissionBehavior === undefined) {
  yield { type: 'hookUpdatedInput', updatedInput: result.updatedInput }
}
```

允许 hook 修改 input 而不干预权限流。

### 2. resolveHookPermissionDecision()

[`resolveHookPermissionDecision()`](../../claude-code-source/src/services/tools/toolHooks.ts#L332-L433) 解析 hook 权限结果为最终 `PermissionDecision`。

#### 2.1 核心不变式

**hook 的 `allow` 不会绕过 `settings.json` 的 deny/ask 规则** — `checkRuleBasedPermissions` 仍会应用。

#### 2.2 hook allow 路径

定义在 [`src/services/tools/toolHooks.ts`](../../claude-code-source/src/services/tools/toolHooks.ts#L347-L405)：

```typescript
// src/services/tools/toolHooks.ts#L347-L405
if (hookPermissionResult?.behavior === 'allow') {
  const hookInput = hookPermissionResult.updatedInput ?? input

  // Hook provided updatedInput for an interactive tool — the hook IS the user interaction
  const interactionSatisfied =
    requiresInteraction && hookPermissionResult.updatedInput !== undefined

  if ((requiresInteraction && !interactionSatisfied) || requireCanUseTool) {
    return { decision: await canUseTool(tool, hookInput, toolUseContext, assistantMessage, toolUseID), input: hookInput }
  }

  // Hook allow skips the interactive prompt, but deny/ask rules still apply.
  const ruleCheck = await checkRuleBasedPermissions(tool, hookInput, toolUseContext)
  if (ruleCheck === null) {
    return { decision: hookPermissionResult, input: hookInput }
  }
  if (ruleCheck.behavior === 'deny') {
    return { decision: ruleCheck, input: hookInput }
  }
  // ask rule — dialog required despite hook approval
  return { decision: await canUseTool(tool, hookInput, toolUseContext, assistantMessage, toolUseID), input: hookInput }
}
```

处理逻辑：

- 交互工具未提供 `updatedInput` 或需要 `canUseTool` → 走 `canUseTool` 对话框
- hook 提供了 `updatedInput` 满足交互需求 → 视为非交互，跳过对话框
- `checkRuleBasedPermissions` 返回 null（无规则）→ 采纳 hook allow
- deny 规则 → 覆盖 hook allow
- ask 规则 → 触发对话框

#### 2.3 hook deny 与无决策路径

- hook `deny` → 直接返回 hook 决策
- 无 hook 决策或 `ask` → 正常权限流，`ask` 时 `forceDecision` 展示 hook 的 ask 消息

### 3. runPostToolUseHooks()

[`runPostToolUseHooks()`](../../claude-code-source/src/services/tools/toolHooks.ts#L39-L191) 处理 PostToolUse 结果。

#### 3.1 阻塞错误附件去重

JSON `decision:"block"` 的 hook 会 yield 两个结果（`blockingError` 与 `hook_blocking_error` 附件），此处跳过附件避免重复展示（#31301），定义在 [`src/services/tools/toolHooks.ts`](../../claude-code-source/src/services/tools/toolHooks.ts#L90-L115)：

```typescript
// src/services/tools/toolHooks.ts#L90-L115
if (
  result.message &&
  !(result.message.type === 'attachment' && result.message.attachment.type === 'hook_blocking_error')
) {
  yield { message: result.message }
}

if (result.blockingError) {
  yield { message: createAttachmentMessage({ type: 'hook_blocking_error', /* ... */ }) }
}
```

#### 3.2 MCP 工具输出替换

定义在 [`src/services/tools/toolHooks.ts`](../../claude-code-source/src/services/tools/toolHooks.ts#L145-L151)：

```typescript
// src/services/tools/toolHooks.ts#L145-L151
if (result.updatedMCPToolOutput && isMcpTool(tool)) {
  toolOutput = result.updatedMCPToolOutput as Output
  yield { updatedMCPToolOutput: toolOutput }
}
```

### 4. runPostToolUseFailureHooks()

[`runPostToolUseFailureHooks()`](../../claude-code-source/src/services/tools/toolHooks.ts#L193-L319) 处理工具失败后的 hook，含相同的阻塞错误附件去重逻辑。

## 十、 相关文档

- [核心执行引擎](LV113-Hook核心执行引擎.md) — 包装器调用的执行引擎
- [Hook 事件与类型](LV111-Hook事件与类型.md) — 各事件的语义
- [Hook 注册与安全](LV115-Hook注册与安全.md) — 权限决策的安全约束

---

*本文档由 markdowncli 技能辅助生成*

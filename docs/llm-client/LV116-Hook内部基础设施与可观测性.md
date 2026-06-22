<!-- more -->

## 一、 概述

本文档涵盖 Hook 机制的内部基础设施与可观测性。内部基础设施包括事件广播系统（HookExecutionEvent）与会话 Hook 存储（SessionStore）。可观测性包括日志、遥测与诊断日志三层机制，以及热路径上的性能优化。

## 二、 事件广播系统

### 1. 概述

[`src/utils/hooks/hookEvents.ts`](../../claude-code-source/src/utils/hooks/hookEvents.ts) 提供独立于主消息流的事件广播系统，供 SDK 等消费者订阅。与主消息流（yield `AggregatedHookResult`）分离，允许 SDK 将 hook 事件转为自己的消息格式。

### 2. 事件类型

```typescript
// src/utils/hooks/hookEvents.ts#L22-L54
export type HookStartedEvent = {
  type: 'started'
  hookId: string
  hookName: string
  hookEvent: string
}

export type HookProgressEvent = {
  type: 'progress'
  hookId: string
  hookName: string
  hookEvent: string
  stdout: string
  stderr: string
  output: string
}

export type HookResponseEvent = {
  type: 'response'
  hookId: string
  hookName: string
  hookEvent: string
  output: string
  stdout: string
  stderr: string
  exitCode?: number
  outcome: 'success' | 'error' | 'cancelled'
}

export type HookExecutionEvent = HookStartedEvent | HookProgressEvent | HookResponseEvent
```

### 3. 发射控制

[`shouldEmit()`](../../claude-code-source/src/utils/hooks/hookEvents.ts#L83-L91) 控制哪些事件被发射：

```typescript
// src/utils/hooks/hookEvents.ts#L83-L91
function shouldEmit(hookEvent: string): boolean {
  if ((ALWAYS_EMITTED_HOOK_EVENTS as readonly string[]).includes(hookEvent)) {
    return true
  }
  return (
    allHookEventsEnabled &&
    (HOOK_EVENTS as readonly string[]).includes(hookEvent)
  )
}
```

`ALWAYS_EMITTED_HOOK_EVENTS` 为 `['SessionStart', 'Setup']`（低噪声生命周期事件，向后兼容）。其他事件需 `allHookEventsEnabled`，由 SDK `includeHookEvents` 选项或 `CLAUDE_CODE_REMOTE` 模式开启（[`setAllHookEventsEnabled()`](../../claude-code-source/src/utils/hooks/hookEvents.ts#L184-L186)）。

### 4. pendingEvents 缓冲

定义在 [`src/utils/hooks/hookEvents.ts`](../../claude-code-source/src/utils/hooks/hookEvents.ts#L57-L81)：

```typescript
// src/utils/hooks/hookEvents.ts#L57-L81
const pendingEvents: HookExecutionEvent[] = []
let eventHandler: HookEventHandler | null = null

export function registerHookEventHandler(handler: HookEventHandler | null): void {
  eventHandler = handler
  if (handler && pendingEvents.length > 0) {
    for (const event of pendingEvents.splice(0)) {
      handler(event)
    }
  }
}
```

注册前若有 pending 事件会回放（上限 `MAX_PENDING_EVENTS = 100`），避免事件丢失。这处理 SDK 初始化晚于 SessionStart/Setup hook 执行的时序问题。

### 5. startHookProgressInterval()

[`startHookProgressInterval()`](../../claude-code-source/src/utils/hooks/hookEvents.ts#L124-L151) 每秒轮询 hook 输出，仅在内容变化时发射 `HookProgressEvent`。`interval.unref()` 确保定时器不阻止 Node.js 进程退出。

### 6. emitHookResponse()

[`emitHookResponse()`](../../claude-code-source/src/utils/hooks/hookEvents.ts#L153-L177) 在 hook 完成时发射。无论 `shouldEmit` 结果如何，都会通过 `logForDebugging` 记录完整输出（`--debug` 可见）。

## 三、 会话 Hook 存储

### 1. SessionStore 结构

会话 Hook 存储在 `AppState.sessionHooks`（Map），定义在 [`src/utils/hooks/sessionHooks.ts`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L42-L62)：

```typescript
// src/utils/hooks/sessionHooks.ts#L42-L46
export type SessionStore = {
  hooks: {
    [event in HookEvent]?: SessionHookMatcher[]
  }
}

// src/utils/hooks/sessionHooks.ts#L62
export type SessionHooksState = Map<string, SessionStore>
```

### 2. Map 结构的性能优势

使用 Map 而非 Record 的原因（[`sessionHooks.ts`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L48-L61) 注释）：`.set`/`.delete` 不改变容器 identity，让 `store.ts` 的 `Object.is(next, prev)` 短路跳过监听器通知。会话 hook 是临时 per-agent 运行时回调，从不被响应式读取。

这对高并发 workflow 至关重要：`parallel()` 启动 N 个 schema-mode agent 时，一次同步 tick 触发 N 次 `addFunctionHook`。Record + spread 每次调用 O(N) 复制（总计 O(N²)）且触发约 30 个监听器；Map 的 `.set()` 是 O(1) 且零监听器触发。

### 3. SessionHookMatcher

定义在 [`src/utils/hooks/sessionHooks.ts`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L33-L40)：

```typescript
// src/utils/hooks/sessionHooks.ts#L33-L40
type SessionHookMatcher = {
  matcher: string
  skillRoot?: string
  hooks: Array<{
    hook: HookCommand | FunctionHook
    onHookSuccess?: OnHookSuccess
  }>
}
```

每个 hook 条目可携带 `onHookSuccess` 回调，用于实现 `once` 语义。

### 4. 注册与移除函数

- [`addSessionHook()`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L68-L86)：添加 command/prompt hook
- [`addFunctionHook()`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L93-L115)：添加 function hook，返回 hook ID
- [`removeSessionHook()`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L225-L268)：按 `isHookEqual()` 移除
- [`removeFunctionHook()`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L120-L162)：按 hook ID 移除
- [`clearSessionHooks()`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L437-L447)：清除指定会话的所有 hook

### 5. 读取函数

- [`getSessionHooks()`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L302-L330)：获取会话 hook（排除 function hook）
- [`getSessionFunctionHooks()`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L345-L392)：获取 function hook
- [`getSessionHookCallback()`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L397-L430)：获取完整 hook 条目（含 `onHookSuccess`）

## 四、 一次性 Hook

`once: true` 语义通过 `onHookSuccess` 回调实现：hook 成功执行后调用移除函数。

### 1. Skill hook 的 once

Skill hook 在 [`registerSkillHooks()`](../../claude-code-source/src/utils/hooks/registerSkillHooks.ts#L36-L43) 中注册 `onHookSuccess`：

```typescript
// src/utils/hooks/registerSkillHooks.ts#L36-L43
const onHookSuccess = hook.once
  ? () => {
      removeSessionHook(setAppState, sessionId, eventName, hook)
    }
  : undefined
```

### 2. 执行流程中的 onHookSuccess 调用

在 [`executeHooks()`](../../claude-code-source/src/utils/hooks.ts#L2906-L2928) 中，command/prompt/function hook（非 callback）成功后调用：

```typescript
// src/utils/hooks.ts#L2906-L2928
if (appState && result.hook.type !== 'callback') {
  const hookEntry = getSessionHookCallback(appState, sessionId, hookEvent, matcher, result.hook)
  if (hookEntry?.onHookSuccess && result.outcome === 'success') {
    try {
      hookEntry.onHookSuccess(result.hook, result as AggregatedHookResult)
    } catch (error) {
      logError(Error('Session hook success callback failed', { cause: error }))
    }
  }
}
```

仅在 `outcome === 'success'` 时调用，阻塞或错误不触发移除。

## 五、 性能优化

### 1. hasHookForEvent() 快速检查

[`hasHookForEvent()`](../../claude-code-source/src/utils/hooks.ts#L1582-L1593) 在构造 `HookInput` 前探测是否有任何 matcher，避免无 hook 时的 `createBaseHookInput`（含 `getTranscriptPathForSession` 路径拼接）与 `getMatchingHooks` 开销。故意过度近似（偏向 true），因为 false negative 会跳过 hook。

### 2. 内部回调快速路径

全内部 callback 的批次跳过完整流程（[`executeHooks()`](../../claude-code-source/src/utils/hooks.ts#L2041-L2067)），跳过 OTEL span、进度消息、abortSignal 组合、`processHookJSONOutput`、resultLoop 聚合。实测 6.01µs → 1.8µs（-70%）。

### 3. 延迟 JSON 序列化

`hookInput` 的 JSON 序列化延迟到首个需要时执行（[`executeHooks()`](../../claude-code-source/src/utils/hooks.ts#L2121-L2140)），批次内共享。纯 callback/function 批次不支付序列化成本。

### 4. 去重快速路径

纯 callback/function hook 跳过去重（[`getMatchingHooks()`](../../claude-code-source/src/utils/hooks.ts#L1723-L1729)），跳过 6 趟 filter + 4×Map + 4×Array.from 的开销。

### 5. getHookEventMetadata() 记忆化

[`getHookEventMetadata`](../../claude-code-source/src/utils/hooks/hooksConfigManager.ts#L26) 用 lodash `memoize` 缓存，resolver 用排序后的 toolNames 拼接作为 key，避免调用方每次 render 传入新数组导致缓存泄漏。

### 6. Map 结构的会话存储

会话 Hook 使用 Map 而非 Record，高并发 workflow 下从 O(N²) 降至 O(1)。详见上文会话 Hook 存储部分。

## 六、 日志

所有关键路径通过 `logForDebugging()` 输出（`--debug` 可见），包括：

- **匹配与跳过**：hook 匹配查询与命中数、工作区信任跳过、策略禁用
- **异步检测**：配置声明异步、首行检测异步、强制同步
- **JSON 解析**：解析失败、校验失败（含期望 schema 提示）、成功
- **权限决策**：决策结果、input 修改、阻止继续

## 七、 遥测

### 1. 事件类型

- `tengu_run_hook`：用户 hook 执行开始（含 `hookTypeCounts`、`pluginHookCounts`、`numCommands`）
- `tengu_repl_hook_finished`：批次完成（含各 outcome 计数与 `totalDurationMs`），定义在 [`src/utils/hooks.ts`](../../claude-code-source/src/utils/hooks.ts#L2935-L2944)：

```typescript
// src/utils/hooks.ts#L2935-L2944
logEvent(`tengu_repl_hook_finished`, {
  hookName,
  numCommands: matchingHooks.length,
  numSuccess: outcomes.success,
  numBlocking: outcomes.blocking,
  numNonBlockingError: outcomes.non_blocking_error,
  numCancelled: outcomes.cancelled,
  totalDurationMs,
})
```

### 2. stats store 与 Beta tracing

- `hook_duration_ms`：stats store 观测值
- `addToTurnHookDuration(totalDurationMs)`：累计到当前回合
- `isBetaTracingEnabled()` 开启时发射 OTEL `hook_execution_start`/`hook_execution_complete`，含 `hook_definitions` JSON

标记为 `internal: true` 的 callback hook 排除在 `tengu_run_hook` 指标外。

## 八、 诊断日志

SessionStart/Setup/SessionEnd hook 额外通过 `logForDiagnosticsNoPII()` 记录（[`execCommandHook()`](../../claude-code-source/src/utils/hooks.ts#L1264-L1328)）：

```typescript
// src/utils/hooks.ts#L771-L774
const shouldEmitDiag =
  hookEvent === 'SessionStart' ||
  hookEvent === 'Setup' ||
  hookEvent === 'SessionEnd'
```

仅对 once-per-session 事件发射，控制 diag_log 体积。`started`/`completed` 配对放在 try/finally 内，确保 setup 路径抛错不会孤儿化 started 标记（否则无法与挂起区分）。用于诊断启动卡顿。

## 九、 相关文档

- [核心执行引擎](LV113-Hook核心执行引擎.md) — 优化措施在执行流程中的位置
- [Hook 注册与安全](LV115-Hook注册与安全.md) — 会话 Hook 的注册流程
- [Hook 机制总览](LV110-Hook机制总览.md) — 整体架构与数据流

---

*本文档由 markdowncli 技能辅助生成*

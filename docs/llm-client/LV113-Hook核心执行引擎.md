<!-- more -->

## 一、 概述

本文档涵盖 Hook 机制的核心执行引擎、输出协议与异步机制。核心执行引擎 [`executeHooks()`](../../claude-code-source/src/utils/hooks.ts#L1952) 处理所有事件类型的 hook 执行，按类型分发到对应执行器。Hook 通过退出码与 stdout 输出反馈结果，可输出 JSON 精细控制行为。异步 Hook 机制允许 hook 在后台执行而不阻塞当前流程。

## 二、 executeHooks() 主流程

[`executeHooks()`](../../claude-code-source/src/utils/hooks.ts#L1952-L2972) 是一个异步生成器，yield `AggregatedHookResult`。

### 1. 前置检查

```typescript
// src/utils/hooks.ts#L1978-L1999
if (shouldDisableAllHooksIncludingManaged()) return
if (isEnvTruthy(process.env.CLAUDE_CODE_SIMPLE)) return

const hookEvent = hookInput.hook_event_name
const hookName = matchQuery ? `${hookEvent}:${matchQuery}` : hookEvent

// SECURITY: ALL hooks require workspace trust in interactive mode
if (shouldSkipHookDueToTrust()) {
  logForDebugging(`Skipping ${hookName} hook execution - workspace trust not accepted`)
  return
}
```

工作区信任检查 [`shouldSkipHookDueToTrust()`](../../claude-code-source/src/utils/hooks.ts#L286-L296) 是核心安全防线：交互模式下所有 hook 都需要信任，非交互模式（SDK）隐式信任。详见 [Hook 注册与安全](LV115-Hook注册与安全.md)。

### 2. 获取匹配 Hook

```typescript
// src/utils/hooks.ts#L2004-L2017
const appState = toolUseContext ? toolUseContext.getAppState() : undefined
const sessionId = toolUseContext?.agentId ?? getSessionId()
const matchingHooks = await getMatchingHooks(
  appState, sessionId, hookEvent, hookInput, toolUseContext?.options?.tools,
)
if (matchingHooks.length === 0) return
```

### 3. 内部回调快速路径

若所有 hook 都是内部 callback（`isInternalHook`），走快速路径（[`executeHooks()`](../../claude-code-source/src/utils/hooks.ts#L2041-L2067)），跳过 span/progress/abortSignal/processHookJSONOutput/resultLoop，实测从 6.01µs 降至约 1.8µs（-70%）。

### 4. 用户 hook 并行执行

用户 hook 通过 [`Promise.all` 风格](../../claude-code-source/src/utils/hooks.ts#L2143-L2731) 并行执行，每个 hook 独立超时。按 hook 类型分发到对应执行器。

### 5. 结果聚合

执行结果按优先级聚合权限行为（[`executeHooks()`](../../claude-code-source/src/utils/hooks.ts#L2820-L2847)）：

- `deny` 始终最高优先级
- `ask` 高于 `allow` 但低于 `deny`
- `allow` 仅在无其他行为时生效
- `passthrough` 不设置权限行为（仅修改 input）

### 6. 延迟 JSON 序列化

`hookInput` 的 JSON 序列化延迟到首个需要时执行（[`executeHooks()`](../../claude-code-source/src/utils/hooks.ts#L2121-L2140)），批次内共享（hookInput 不可变）。纯 callback/function 批次不支付序列化成本。

## 三、 execCommandHook()

Shell 命令执行器 [`execCommandHook()`](../../claude-code-source/src/utils/hooks.ts#L747-L1335) 是最复杂的执行器。

### 1. Shell 选择与跨平台

```typescript
// src/utils/hooks.ts#L790
const shellType = hook.shell ?? DEFAULT_HOOK_SHELL
```

- `bash`（默认）：Windows 下用 Git Bash，路径经 `windowsPathToPosixPath()` 转 POSIX
- `powershell`：用 `pwsh -NoProfile -NonInteractive -Command`，使用原生路径

### 2. 环境变量注入

注入的环境变量包括（[`execCommandHook()`](../../claude-code-source/src/utils/hooks.ts#L882-L926)）：

- `CLAUDE_PROJECT_DIR`：稳定的项目根目录（非 worktree 路径）
- `CLAUDE_PLUGIN_ROOT` / `CLAUDE_PLUGIN_DATA`：插件/skill 根目录与数据目录
- `CLAUDE_PLUGIN_OPTION_<KEY>`：插件 userConfig 选项
- `CLAUDE_ENV_FILE`：仅 SessionStart/Setup/CwdChanged/FileChanged 事件，hook 写入的 export 语句会影响后续 BashTool

### 3. 变量替换

插件 hook 命令支持 `${CLAUDE_PLUGIN_ROOT}`、`${CLAUDE_PLUGIN_DATA}`、`${user_config.X}` 替换（[`execCommandHook()`](../../claude-code-source/src/utils/hooks.ts#L822-L857)）。替换顺序：先插件变量，后 userConfig，避免用户值含字面 `${CLAUDE_PLUGIN_ROOT}` 被二次解释。

### 4. 异步检测协议

Hook 进程的首行输出若为 `{"async":true,...}`，则被识别为异步 hook（[`execCommandHook()`](../../claude-code-source/src/utils/hooks.ts#L1112-L1164)），转入后台执行。配置项 `async: true` 或 `asyncRewake: true` 可直接声明异步，无需首行检测。

必须只解析首行：进程快速写入多行后 `data` 事件才触发，解析全部 stdout 会失败导致异步 hook 阻塞完整时长。

### 5. Prompt 请求协议

当 `requestPrompt` 可用时，hook 可通过 stdout 输出 `{"prompt":"<id>","message":"...","options":[...]}` 请求用户输入（[`execCommandHook()`](../../claude-code-source/src/utils/hooks.ts#L1073-L1110)），响应通过 stdin 回写。处理后的 prompt 行从最终 stdout 中按内容匹配剥离。

## 四、 其他执行器

### 1. execPromptHook()

Prompt 类型 Hook 通过 LLM 评估，实现在 [`src/utils/hooks/execPromptHook.ts`](../../claude-code-source/src/utils/hooks/execPromptHook.ts#L21)。默认使用 small fast model（Haiku），超时默认 30 秒。`$ARGUMENTS` 占位符替换为 hook 输入 JSON。

```typescript
// src/utils/hooks/execPromptHook.ts#L62-L100
const response = await queryModelWithoutStreaming({
  messages: messagesToQuery,
  systemPrompt: asSystemPrompt([
    `You are evaluating a hook in Claude Code.
Your response must be a JSON object matching one of the following schemas:
1. If the condition is met, return: {"ok": true}
2. If the condition is not met, return: {"ok": false, "reason": "Reason for why it is not met"}`,
  ]),
  // ...
})
```

### 2. execAgentHook()

Agent 类型 Hook 启动子 Agent 执行验证任务，实现在 [`src/utils/hooks/execAgentHook.ts`](../../claude-code-source/src/utils/hooks/execAgentHook.ts)。默认使用 Haiku 模型，超时默认 60 秒。

### 3. execHttpHook()

HTTP 类型 Hook 向指定 URL POST hook 输入 JSON，实现在 [`src/utils/hooks/execHttpHook.ts`](../../claude-code-source/src/utils/hooks/execHttpHook.ts#L21)。安全特性详见 [Hook 注册与安全](LV115-Hook注册与安全.md)。

### 4. executeFunctionHook()

函数 Hook 执行器 [`executeFunctionHook()`](../../claude-code-source/src/utils/hooks.ts#L4740-L4838) 调用 TypeScript 回调，返回 `true` 为成功，`false` 为阻塞（使用 `hook.errorMessage`）。

### 5. executeHookCallback()

回调 Hook 执行器 [`executeHookCallback()`](../../claude-code-source/src/utils/hooks.ts#L4840-L4896) 调用 SDK 注册的回调，传入 `HookCallbackContext`（含 `getAppState` 与 `updateAttributionState`），返回值经 `processHookJSONOutput()` 处理。

## 五、 executeHooksOutsideREPL()

[`executeHooksOutsideREPL()`](../../claude-code-source/src/utils/hooks.ts#L3003-L3381) 用于 REPL 外部场景（如通知、会话结束）。与 `executeHooks()` 的区别：

- 返回 `HookOutsideReplResult[]` 而非 yield 消息
- 错误仅通过 `logForDebugging` 记录
- 不支持 prompt/agent hook
- function hook 在此路径会报错（仅 REPL 上下文可用）

## 六、 退出码语义

Hook 进程的退出码遵循统一约定：

| 退出码 | 含义 |
|--------|------|
| `0` | 成功，stdout 按事件语义处理 |
| `2` | 阻塞错误，stderr 反馈给模型并阻止对应操作 |
| 其他 | 非阻塞错误，stderr 仅展示给用户，操作继续 |

部分事件的退出码 2 语义有差异：

- `SessionStart`、`Setup`：阻塞错误被忽略
- `Stop`：stderr 反馈给模型并继续对话（非阻止）
- `StopFailure`：忽略（fire-and-forget）
- `InstructionsLoaded`：仅观测，不支持阻塞
- `UserPromptSubmit`：阻止处理、擦除原始提示词

退出码 2 的处理（[`executeHooks()`](../../claude-code-source/src/utils/hooks.ts#L2647-L2668)）：

```typescript
// src/utils/hooks.ts#L2647-L2668
if (result.status === 2) {
  yield {
    blockingError: {
      blockingError: `[${hook.command}]: ${result.stderr || 'No stderr output'}`,
      command: hook.command,
    },
    outcome: 'blocking' as const,
    hook,
  }
  return
}
```

## 七、 JSON 输出 Schema

### 1. 同步响应通用字段

定义在 [`src/types/hooks.ts`](../../claude-code-source/src/types/hooks.ts#L50-L76)：

```typescript
// src/types/hooks.ts#L50-L65
z.object({
  continue: z.boolean().optional(),        // 是否继续（默认 true）
  suppressOutput: z.boolean().optional(),   // 隐藏 stdout（默认 false）
  stopReason: z.string().optional(),        // continue:false 时的提示信息
  decision: z.enum(['approve', 'block']).optional(),
  reason: z.string().optional(),
  systemMessage: z.string().optional(),
  hookSpecificOutput: z.union([...]).optional(),
})
```

### 2. hookSpecificOutput 事件专属输出

每个事件有专属的 `hookSpecificOutput` 形态，通过 `hookEventName` 判别。主要事件：

- `PreToolUse`：`permissionDecision`（allow/deny/ask）、`updatedInput`、`additionalContext`
- `SessionStart`：`initialUserMessage`、`watchPaths`
- `PostToolUse`：`updatedMCPToolOutput`
- `PermissionRequest`：`decision`（allow/deny）
- `PermissionDenied`：`retry: boolean`
- `Elicitation`/`ElicitationResult`：`action`（accept/decline/cancel）+ `content`
- `CwdChanged`/`FileChanged`：`watchPaths`
- `WorktreeCreate`：`worktreePath`

### 3. 异步响应

定义在 [`src/types/hooks.ts`](../../claude-code-source/src/types/hooks.ts#L171-L174)：

```typescript
// src/types/hooks.ts#L171-L174
const asyncHookResponseSchema = z.object({
  async: z.literal(true),
  asyncTimeout: z.number().optional(),
})
```

Hook 输出 `{"async":true}` 后立即转入后台，不阻塞当前流程。

## 八、 输出解析流程

### 1. parseHookOutput()

[`parseHookOutput()`](../../claude-code-source/src/utils/hooks.ts#L399-L451) 负责解析 command hook 的 stdout：

1. trim 后若不以 `{` 开头，视为纯文本
2. 尝试 JSON 解析与 Zod 校验（[`validateHookJson()`](../../claude-code-source/src/utils/hooks.ts#L382-L397)）
3. 校验失败返回 `validationError`（含期望 schema 提示）与原始文本

### 2. processHookJSONOutput()

[`processHookJSONOutput()`](../../claude-code-source/src/utils/hooks.ts#L489-L745) 将校验通过的 JSON 转为 `Partial<HookResult>`，处理 `continue`、`decision`、`hookSpecificOutput` 等字段，并校验 `hookEventName` 与期望事件一致。

### 3. 权限决策映射

`PreToolUse` 的 `permissionDecision` 映射（[`processHookJSONOutput()`](../../claude-code-source/src/utils/hooks.ts#L555-L574)）：

- `allow` → `permissionBehavior = 'allow'`
- `deny` → `permissionBehavior = 'deny'` + `blockingError`
- `ask` → `permissionBehavior = 'ask'`

## 九、 异步 Hook 机制

异步 Hook 允许 hook 在后台执行而不阻塞当前流程。有三种声明异步的方式，对应三条执行路径。

### 1. 三种异步路径

| 路径 | 声明方式 | 注册到 AsyncHookRegistry | `shellCommand.background()` | 退出码 2 处理 |
|------|----------|--------------------------|----------------------------|---------------|
| **配置 async** | `async: true` | 是 | 是 | 记录为 error |
| **输出 async** | stdout 首行 `{"async":true}` | 是 | 是 | 记录为 error |
| **asyncRewake** | `asyncRewake: true` | 否（完全绕过） | 否（保持 in-memory） | 注入 `task-notification` 唤醒模型 |

`forceSyncExecution: true` 可强制同步执行（如 SessionStart），忽略 async 声明，等待 hook 完成才继续。

### 2. AsyncHookRegistry

异步 Hook 注册表 [`src/utils/hooks/AsyncHookRegistry.ts`](../../claude-code-source/src/utils/hooks/AsyncHookRegistry.ts) 维护全局 `pendingHooks` Map。

#### 2.1 registerPendingAsyncHook()

[`registerPendingAsyncHook()`](../../claude-code-source/src/utils/hooks/AsyncHookRegistry.ts#L30-L83) 注册待处理的异步 hook：默认超时 15 秒，启动进度轮询间隔。

#### 2.2 checkForAsyncHookResponses()

[`checkForAsyncHookResponses()`](../../claude-code-source/src/utils/hooks/AsyncHookRegistry.ts#L113-L268) 轮询所有 pending hook：

- 进程被 kill 或无 shellCommand → 移除
- 进程未完成 → 跳过
- 已交付或无 stdout → 移除
- 逐行解析 stdout 寻找非 async 的 JSON 行作为最终响应
- SessionStart hook 完成后触发 `invalidateSessionEnvCache()`

#### 2.3 finalizePendingAsyncHooks()

[`finalizePendingAsyncHooks()`](../../claude-code-source/src/utils/hooks/AsyncHookRegistry.ts#L281-L301) 在会话结束时统一收尾：完成的 hook 记录结果，未完成的 kill 后标记为 cancelled。

### 3. asyncRewake 模式

`asyncRewake: true` 是特殊的异步模式（[`executeInBackground()`](../../claude-code-source/src/utils/hooks.ts#L184-L265)），完全绕过 AsyncHookRegistry。退出码 2 时通过 `enqueuePendingNotification()` 注入 `task-notification`：模型空闲时经 `useQueueProcessor` 处理，忙碌时经 `queued_command` 附件注入。新提示词提交不会杀死该 hook，但硬取消（Escape）会。

不调用 `background()` 的原因：`shellCommand.background()` 会调用 `taskOutput.spillToDisk()`，破坏 in-memory stdout/stderr 捕获。asyncRewake 保持 StreamWrappers 附着，将数据管道到 in-memory TaskOutput 缓冲区。

## 十、 HookResult 类型

执行引擎的输出类型定义在 [`src/utils/hooks.ts`](../../claude-code-source/src/utils/hooks.ts#L338-L357)：

```typescript
// src/utils/hooks.ts#L338-L357
export interface HookResult {
  message?: HookResultMessage
  systemMessage?: string
  blockingError?: HookBlockingError
  outcome: 'success' | 'blocking' | 'non_blocking_error' | 'cancelled'
  preventContinuation?: boolean
  stopReason?: string
  permissionBehavior?: 'ask' | 'deny' | 'allow' | 'passthrough'
  hookPermissionDecisionReason?: string
  additionalContext?: string
  initialUserMessage?: string
  updatedInput?: Record<string, unknown>
  updatedMCPToolOutput?: unknown
  permissionRequestResult?: PermissionRequestResult
  elicitationResponse?: ElicitationResponse
  watchPaths?: string[]
  retry?: boolean
  hook: HookCommand | HookCallback | FunctionHook
}
```

`outcome` 是核心状态字段，决定结果如何被聚合与展示。

## 十一、 相关文档

- [Hook 事件与类型](LV111-Hook事件与类型.md) — 事件与类型的定义
- [Hook 配置与匹配](LV112-Hook配置与匹配.md) — 匹配机制如何筛选 hook
- [事件包装器与工具集成](LV114-Hook事件包装器与工具集成.md) — 执行引擎的调用入口

---

*本文档由 markdowncli 技能辅助生成*

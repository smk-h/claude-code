<!-- more -->

## 一、 概述

本文档涵盖 Hook 机制的事件体系与类型定义。Claude Code 定义了 27 个事件类型，覆盖会话生命周期、工具调用、权限决策、子 Agent、压缩、MCP 交互等场景。每个事件可配置四种可持久化 Hook 类型（command/prompt/agent/http）与两种内存类型（function/callback）。本文档详细分析事件定义、分类、匹配字段、退出码语义，以及各类型的 Schema 定义与配置结构。

## 二、 HOOK_EVENTS 常量

所有事件名在 [`src/entrypoints/sdk/coreTypes.ts`](../../claude-code-source/src/entrypoints/sdk/coreTypes.ts#L25-L53) 中以 `HOOK_EVENTS` 常量数组声明：

```typescript
// src/entrypoints/sdk/coreTypes.ts#L25-L53
export const HOOK_EVENTS = [
  'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'Notification',
  'UserPromptSubmit', 'SessionStart', 'SessionEnd', 'Stop', 'StopFailure',
  'SubagentStart', 'SubagentStop', 'PreCompact', 'PostCompact',
  'PermissionRequest', 'PermissionDenied', 'Setup', 'TeammateIdle',
  'TaskCreated', 'TaskCompleted', 'Elicitation', 'ElicitationResult',
  'ConfigChange', 'WorktreeCreate', 'WorktreeRemove',
  'InstructionsLoaded', 'CwdChanged', 'FileChanged',
] as const
```

该数组是运行时与类型系统的基础：`HookEvent` 类型由其派生，Zod Schema 通过 `z.enum(HOOK_EVENTS)` 校验事件名，匹配逻辑遍历该数组装配各来源 hook。

## 三、 事件元数据

每个事件的摘要描述、匹配字段及退出码语义集中在 [`src/utils/hooks/hooksConfigManager.ts`](../../claude-code-source/src/utils/hooks/hooksConfigManager.ts#L26-L267) 的 `getHookEventMetadata()` 中。该函数用 lodash `memoize` 缓存，resolver 用排序后的 toolNames 拼接作为 key。

```typescript
// src/utils/hooks/hooksConfigManager.ts#L16-L20
export type HookEventMetadata = {
  summary: string
  description: string
  matcherMetadata?: MatcherMetadata
}
```

`matcherMetadata` 描述该事件用于匹配的字段（`fieldToMatch`）与可选值列表（`values`）。

## 四、 事件分类

### 1. 工具调用相关事件

| 事件 | 触发时机 | 匹配字段 | 退出码 2 语义 |
|------|----------|----------|---------------|
| `PreToolUse` | 工具执行前 | `tool_name` | 阻止工具调用，stderr 反馈给模型 |
| `PostToolUse` | 工具执行后 | `tool_name` | stderr 立即反馈给模型 |
| `PostToolUseFailure` | 工具执行失败后 | `tool_name` | stderr 立即反馈给模型 |
| `PermissionDenied` | 自动模式分类器拒绝工具调用后 | `tool_name` | — |
| `PermissionRequest` | 权限对话框展示时 | `tool_name` | — |

`PreToolUse` 是最核心的拦截点，可通过 JSON 输出中的 `hookSpecificOutput.permissionDecision` 返回 `allow`/`deny`/`ask` 直接决定权限走向，还可通过 `updatedInput` 修改工具入参。其输入为工具调用参数的 JSON。

`PostToolUse` 输入含 `inputs`（工具调用参数）与 `response`（工具响应），可返回 `updatedMCPToolOutput` 修改 MCP 工具输出。

`PostToolUseFailure` 输入含 `tool_name`、`tool_input`、`tool_use_id`、`error`、`error_type`、`is_interrupt`、`is_timeout`。

### 2. 会话生命周期事件

| 事件 | 触发时机 | 匹配字段 | 退出码 2 语义 |
|------|----------|----------|---------------|
| `SessionStart` | 新会话启动 | `source`（startup/resume/clear/compact） | 阻塞错误被忽略 |
| `SessionEnd` | 会话结束 | `reason`（clear/logout/prompt_input_exit/other） | — |
| `Setup` | 仓库初始化或维护 | `trigger`（init/maintenance） | 阻塞错误被忽略 |
| `Stop` | Claude 即将结束响应 | 无 | stderr 反馈给模型并继续对话 |
| `StopFailure` | 因 API 错误结束回合 | `error`（rate_limit 等） | 忽略（fire-and-forget） |

`SessionStart` 与 `Setup` 支持写入 `CLAUDE_ENV_FILE` 环境变量文件，hook 可在其中写入 bash export 语句，从而影响后续 `BashTool` 命令的环境变量。

`Stop` 输入含 `stop_hook_active`（是否在另一个 stop hook 内调用）与 `last_assistant_message`。退出码 2 时 stderr 反馈给模型并继续对话，使其可以补充响应。

`StopFailure` 在 API 错误（限流、认证失败等）结束回合时触发，取代 `Stop`。其匹配字段 `error` 的可选值：`rate_limit`、`authentication_failed`、`billing_error`、`invalid_request`、`server_error`、`max_output_tokens`、`unknown`（[`getHookEventMetadata()`](../../claude-code-source/src/utils/hooks/hooksConfigManager.ts#L104-L115)）。

### 3. 用户交互与提示词事件

| 事件 | 触发时机 | 匹配字段 | 退出码 2 语义 |
|------|----------|----------|---------------|
| `UserPromptSubmit` | 用户提交提示词 | 无 | 阻止处理、擦除原始提示词、stderr 仅展示给用户 |
| `Notification` | 发送通知时 | `notification_type` | stderr 仅展示给用户 |

`UserPromptSubmit` 可通过 `hookSpecificOutput.additionalContext` 向模型注入额外上下文。`Notification` 的 `notification_type` 可选值（[`getHookEventMetadata()`](../../claude-code-source/src/utils/hooks/hooksConfigManager.ts#L71-L79)）：`permission_prompt`、`idle_prompt`、`auth_success`、`elicitation_dialog`、`elicitation_complete`、`elicitation_response`。

### 4. 子 Agent 与团队协作事件

| 事件 | 触发时机 | 匹配字段 | 退出码 2 语义 |
|------|----------|----------|---------------|
| `SubagentStart` | 子 Agent 启动 | `agent_type` | 阻塞错误被忽略 |
| `SubagentStop` | 子 Agent 即将结束响应 | `agent_type` | stderr 反馈给子 Agent 并继续运行 |
| `TeammateIdle` | 队友即将进入空闲 | 无 | stderr 反馈给队友并阻止空闲 |
| `TaskCreated` | 任务被创建 | 无 | stderr 反馈给模型并阻止任务创建 |
| `TaskCompleted` | 任务被标记完成 | 无 | stderr 反馈给模型并阻止任务完成 |

### 5. 压缩与上下文管理事件

| 事件 | 触发时机 | 匹配字段 | 退出码 2 语义 |
|------|----------|----------|---------------|
| `PreCompact` | 对话压缩前 | `trigger`（manual/auto） | 阻止压缩 |
| `PostCompact` | 对话压缩后 | `trigger` | — |
| `InstructionsLoaded` | 加载指令文件（CLAUDE.md 或规则） | `load_reason` | 仅观测，不支持阻塞 |
| `ConfigChange` | 配置文件在会话中变更 | `source` | 阻止变更应用到会话 |

`PreCompact` 退出码 0 时 stdout 作为自定义压缩指令追加。`ConfigChange` 的 `source` 可选值：`user_settings`、`project_settings`、`local_settings`、`policy_settings`、`skills`。

### 6. MCP 与隔离事件

| 事件 | 触发时机 | 匹配字段 |
|------|----------|----------|
| `Elicitation` | MCP server 请求用户输入 | `mcp_server_name` |
| `ElicitationResult` | 用户响应 MCP elicitation 后 | `mcp_server_name` |
| `WorktreeCreate` | 创建隔离 worktree | 无 |
| `WorktreeRemove` | 移除 worktree | 无 |
| `CwdChanged` | 工作目录变更后 | 无 |
| `FileChanged` | 被监视文件变更 | 文件名（matcher 指定） |

`CwdChanged` 与 `FileChanged` 支持 `watchPaths` 输出动态注册文件监视路径，并可写入 `CLAUDE_ENV_FILE`。`WorktreeCreate` 的 stdout 应为创建的 worktree 绝对路径。

## 五、 HookInput 输入结构

每个事件的 `HookInput` 由 `BaseHookInput` + 事件专属字段组成。`BaseHookInput` 定义在 [`src/entrypoints/sdk/coreSchemas.ts`](../../claude-code-source/src/entrypoints/sdk/coreSchemas.ts#L387-L409)：

```typescript
// src/entrypoints/sdk/coreSchemas.ts#L387-L409
export const BaseHookInputSchema = lazySchema(() =>
  z.object({
    session_id: z.string(),
    transcript_path: z.string(),
    cwd: z.string(),
    permission_mode: z.string().optional(),
    agent_id: z.string().optional(),   // 仅子 Agent 调用时存在
    agent_type: z.string().optional(), // 子 Agent 或 --agent 会话时存在
  }),
)
```

`agent_id` 与 `agent_type` 的区别：`agent_id` 仅在子 Agent 调用时存在（即使 `--agent` 会话的主线程也不含 `agent_id`），用于区分子 Agent 调用与 `--agent` 会话的主线程调用。

### 1. 事件专属字段汇总

各事件的专属字段定义在 [`src/entrypoints/sdk/coreSchemas.ts`](../../claude-code-source/src/entrypoints/sdk/coreSchemas.ts#L414-L700)：

| 事件 | 专属字段 |
|------|----------|
| `PreToolUse` | `tool_name`, `tool_input`, `tool_use_id` |
| `PostToolUse` | `tool_name`, `tool_input`, `tool_response`, `tool_use_id` |
| `PostToolUseFailure` | `tool_name`, `tool_input`, `tool_use_id`, `error`, `is_interrupt?` |
| `PermissionDenied` | `tool_name`, `tool_input`, `tool_use_id`, `reason` |
| `PermissionRequest` | `tool_name`, `tool_input`, `permission_suggestions?` |
| `UserPromptSubmit` | `prompt` |
| `Notification` | `message`, `title?`, `notification_type` |
| `SessionStart` | `source`, `agent_type?`, `model?` |
| `Setup` | `trigger` |
| `Stop` | `stop_hook_active`, `last_assistant_message?` |
| `StopFailure` | `error`, `error_details?`, `last_assistant_message?` |
| `SubagentStart` | `agent_id`, `agent_type` |
| `SubagentStop` | `stop_hook_active`, `agent_id`, `agent_transcript_path`, `agent_type`, `last_assistant_message?` |
| `PreCompact` | `trigger`, `custom_instructions` |
| `PostCompact` | `trigger`, `compact_summary` |
| `TeammateIdle` | `teammate_name`, `team_name` |
| `TaskCreated` / `TaskCompleted` | `task_id`, `task_subject`, `task_description?`, `teammate_name?`, `team_name?` |
| `Elicitation` | `mcp_server_name`, `message`, `mode?`, `url?`, `elicitation_id?`, `requested_schema?` |
| `ElicitationResult` | `mcp_server_name`, `elicitation_id?`, `mode?`, `action`, `content?` |
| `ConfigChange` | `source`, `file_path?` |
| `InstructionsLoaded` | `file_path`, `memory_type`, `load_reason`, `globs?`, `trigger_file_path?`, `parent_file_path?` |
| `WorktreeCreate` | `name` |
| `WorktreeRemove` | `worktree_path` |
| `CwdChanged` | `old_cwd`, `new_cwd` |
| `FileChanged` | `file_path`, `event` |

## 六、 可持久化 Hook 类型

可持久化类型定义在 [`src/schemas/hooks.ts`](../../claude-code-source/src/schemas/hooks.ts) 的 `buildHookSchemas()` 中，通过 `HookCommandSchema` 组合为判别联合：

```typescript
// src/schemas/hooks.ts#L176-L189
export const HookCommandSchema = lazySchema(() => {
  const { BashCommandHookSchema, PromptHookSchema, AgentHookSchema, HttpHookSchema } = buildHookSchemas()
  return z.discriminatedUnion('type', [
    BashCommandHookSchema, PromptHookSchema, AgentHookSchema, HttpHookSchema,
  ])
})
```

### 1. BashCommandHook（command 类型）

Shell 命令 Hook，是最常用的类型。定义在 [`src/schemas/hooks.ts`](../../claude-code-source/src/schemas/hooks.ts#L32-L65)：

```typescript
// src/schemas/hooks.ts#L32-L65
const BashCommandHookSchema = z.object({
  type: z.literal('command').describe('Shell command hook type'),
  command: z.string().describe('Shell command to execute'),
  if: IfConditionSchema(),
  shell: z.enum(SHELL_TYPES).optional(),
  timeout: z.number().positive().optional(),
  statusMessage: z.string().optional(),
  once: z.boolean().optional(),
  async: z.boolean().optional(),
  asyncRewake: z.boolean().optional(),
})
```

支持的字段：

- `command`：要执行的 shell 命令
- `if`：权限规则语法的条件过滤（如 `"Bash(git *)"`）
- `shell`：解释器（`bash` 或 `powershell`）
- `timeout`：单 hook 超时（秒）
- `statusMessage`：spinner 中显示的自定义状态消息
- `once`：是否只执行一次后移除
- `async`：是否后台非阻塞执行
- `asyncRewake`：后台执行，退出码 2 时唤醒模型

### 2. PromptHook（prompt 类型）

通过 LLM 评估 prompt 的 Hook。定义在 [`src/schemas/hooks.ts`](../../claude-code-source/src/schemas/hooks.ts#L67-L95)，使用 `$ARGUMENTS` 占位符接收 hook 输入 JSON，默认使用 small fast model（如 Haiku）。执行时构造系统提示词要求模型返回 `{"ok": true}` 或 `{"ok": false, "reason": "..."}` 的 JSON。

### 3. AgentHook（agent 类型）

Agentic 验证器 Hook，定义在 [`src/schemas/hooks.ts`](../../claude-code-source/src/schemas/hooks.ts#L128-L163)。启动一个子 Agent 执行验证任务（如"验证单元测试已运行且通过"），默认使用 Haiku 模型，超时默认 60 秒。

【**注意**】

Schema 中有一条重要注释：禁止在此添加 `.transform()`。该 Schema 被 `parseSettingsFile` 使用，而 `updateSettingsForSource` 会通过 `JSON.stringify` 往返解析结果，函数值会被静默丢弃，导致用户的 prompt 从 `settings.json` 中消失（gh-24920、CC-79）。

### 4. HttpHook（http 类型）

HTTP 请求 Hook，定义在 [`src/schemas/hooks.ts`](../../claude-code-source/src/schemas/hooks.ts#L97-L126)。向指定 URL POST hook 输入 JSON，支持自定义 headers 和环境变量插值。环境变量插值通过 `allowedEnvVars` 白名单控制：仅列出的变量会被解析，其余 `$VAR` 引用留为空字符串，防止通过项目配置的 HTTP hook 窃取密钥。

### 5. 四种类型字段对比

| 字段 | command | prompt | agent | http |
|------|---------|--------|-------|------|
| 核心字段 | `command` | `prompt` | `prompt` | `url` |
| `if` 条件 | ✓ | ✓ | ✓ | ✓ |
| `timeout` | ✓ | ✓ | ✓ | ✓ |
| `statusMessage` | ✓ | ✓ | ✓ | ✓ |
| `once` | ✓ | ✓ | ✓ | ✓ |
| `model` | — | ✓ | ✓ | — |
| `shell` | ✓ | — | — | — |
| `async` / `asyncRewake` | ✓ | — | — | — |
| `headers` / `allowedEnvVars` | — | — | — | ✓ |
| 默认模型 | — | small fast (Haiku) | Haiku | — |
| 默认超时 | 10min | 30s | 60s | 10min |

## 七、 不可持久化 Hook 类型

### 1. FunctionHook（function 类型）

定义在 [`src/utils/hooks/sessionHooks.ts`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L24-L31)：

```typescript
// src/utils/hooks/sessionHooks.ts#L24-L31
export type FunctionHook = {
  type: 'function'
  id?: string
  timeout?: number
  callback: FunctionHookCallback
  errorMessage: string
  statusMessage?: string
}
```

回调接收消息数组与 abort 信号，返回 `true` 通过、`false` 阻塞。仅会话级有效，无法持久化，用于结构化输出强制等场景。通过 [`addFunctionHook()`](../../claude-code-source/src/utils/hooks/sessionHooks.ts#L93-L115) 注册。

### 2. HookCallback（callback 类型）

定义在 [`src/types/hooks.ts`](../../claude-code-source/src/types/hooks.ts#L211-L226)，由 SDK 或内部模块注册的异步回调，接收 `HookInput` 并返回 `HookJSONOutput`。标记为 `internal: true` 的回调（如 `sessionFileAccessHooks`、`attributionHooks`）会跳过遥测上报，走快速路径。`HookCallbackContext` 提供 `getAppState` 与 `updateAttributionState` 访问能力。

## 八、 if 条件字段

所有可持久化类型共享 `if` 条件字段，定义在 [`src/schemas/hooks.ts`](../../claude-code-source/src/schemas/hooks.ts#L19-L27)：

```typescript
// src/schemas/hooks.ts#L19-L27
const IfConditionSchema = lazySchema(() =>
  z.string().optional().describe(
    'Permission rule syntax to filter when this hook runs (e.g., "Bash(git *)"). ' +
      'Only runs if the tool call matches the pattern. Avoids spawning hooks for non-matching commands.',
  ),
)
```

使用权限规则语法，在 spawn 前根据 hook 输入的 `tool_name` 与 `tool_input` 评估。详细匹配逻辑见 [Hook 配置与匹配](LV112-Hook配置与匹配.md)。

## 九、 HookMatcher 结构

Hook 配置以"事件 → 匹配器数组 → hook 数组"的三层结构组织。定义在 [`src/schemas/hooks.ts`](../../claude-code-source/src/schemas/hooks.ts#L194-L213)：

```typescript
// src/schemas/hooks.ts#L194-L213
export const HookMatcherSchema = lazySchema(() =>
  z.object({
    matcher: z.string().optional().describe('String pattern to match (e.g. tool names like "Write")'),
    hooks: z.array(HookCommandSchema()).describe('List of hooks to execute when the matcher matches'),
  }),
)

export const HooksSchema = lazySchema(() =>
  z.partialRecord(z.enum(HOOK_EVENTS), z.array(HookMatcherSchema())),
)
```

`settings.json` 中的典型配置形态：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "echo 'pre-bash'", "timeout": 5 }
        ]
      }
    ]
  }
}
```

## 十、 相关文档

- [Hook 机制总览](LV110-Hook机制总览.md) — 整体架构与数据流
- [Hook 配置与匹配](LV112-Hook配置与匹配.md) — 配置来源收集与匹配逻辑
- [核心执行引擎](LV113-Hook核心执行引擎.md) — 各类型的执行器实现

---

*本文档由 markdowncli 技能辅助生成*

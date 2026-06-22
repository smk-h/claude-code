<!-- more -->

## 一、 概述

本文档涵盖 Hook 机制的配置来源收集与匹配逻辑。Hook 机制支持 6 种配置来源，按优先级合并，并通过快照机制保证运行期一致性。匹配过程涉及匹配查询字段提取、matcher 模式语法、`if` 条件过滤与去重。本文档详细分析配置来源、策略过滤、快照机制、匹配流程与去重逻辑。

## 二、 配置来源类型

Hook 来源类型定义在 [`src/utils/hooks/hooksSettings.ts`](../../claude-code-source/src/utils/hooks/hooksSettings.ts#L15-L20)：

```typescript
// src/utils/hooks/hooksSettings.ts#L15-L20
export type HookSource =
  | EditableSettingSource  // userSettings | projectSettings | localSettings
  | 'policySettings'
  | 'pluginHook'
  | 'sessionHook'
  | 'builtinHook'
```

| 来源 | 存储位置 | 特性 |
|------|----------|------|
| `userSettings` | `~/.claude/settings.json` | 用户全局配置 |
| `projectSettings` | `.claude/settings.json` | 项目级配置（团队共享） |
| `localSettings` | `.claude/settings.local.json` | 项目本地配置（不入版本控制） |
| `policySettings` | 托管策略配置 | 企业管理，最高优先级，可设置 `allowManagedHooksOnly`/`disableAllHooks` |
| `pluginHook` | 插件 `hooks/hooks.json` | 通过插件机制加载，支持热重载 |
| `sessionHook` | 内存（`AppState.sessionHooks`） | 会话级临时 hook，含 Agent/Skill frontmatter hook |
| `builtinHook` | 内部注册 | Claude Code 内置 hook（仅 `USER_TYPE === 'ant'` 可见） |

### 1. 配置源优先级

`SOURCES` 数组定义了可编辑来源的展示顺序（[`src/utils/settings/constants.ts`](../../claude-code-source/src/utils/settings/constants.ts#L191-L195)）：

```typescript
// src/utils/settings/constants.ts#L191-L195
export const SOURCES = [
  'localSettings',
  'projectSettings',
  'userSettings',
] as const satisfies readonly EditableSettingSource[]
```

`sortMatchersByPriority()` 按此顺序定义优先级（低索引 = 高优先级）。插件 hook 与内置 hook 优先级最低（999）。同优先级按 matcher 名称 `localeCompare` 排序。

## 三、 配置收集流程

### 1. getAllHooks()

[`getAllHooks()`](../../claude-code-source/src/utils/hooks/hooksSettings.ts#L92-L161) 负责从各来源收集 Hook，返回扁平化的 `IndividualHookConfig[]`：

```typescript
// src/utils/hooks/hooksSettings.ts#L22-L28
export interface IndividualHookConfig {
  event: HookEvent
  config: HookCommand
  matcher?: string
  source: HookSource
  pluginName?: string
}
```

收集流程：

1. 检查 `policySettings.allowManagedHooksOnly`，若为 true 则跳过 user/project/local
2. 遍历 `userSettings` → `projectSettings` → `localSettings`，用 `seenFiles` Set 去重同路径文件（如从 home 目录运行时 userSettings 与 projectSettings 都解析到 `~/.claude/settings.json`）
3. 对每个来源的 `hooks` 配置，展开事件 → matcher → hooks 三层结构
4. 收集会话级 Hook（`getSessionHooks()`）
5. 返回扁平化数组

## 四、 配置快照机制

### 1. 快照的必要性

Hook 配置在启动时拍摄快照，运行期从快照读取，避免运行中配置变更导致的不一致。快照存储在 [`src/utils/hooks/hooksConfigSnapshot.ts`](../../claude-code-source/src/utils/hooks/hooksConfigSnapshot.ts) 的模块级变量 `initialHooksConfig`。

### 2. captureHooksConfigSnapshot() 与 updateHooksConfigSnapshot()

[`captureHooksConfigSnapshot()`](../../claude-code-source/src/utils/hooks/hooksConfigSnapshot.ts#L95-L97) 在应用启动时调用，[`updateHooksConfigSnapshot()`](../../claude-code-source/src/utils/hooks/hooksConfigSnapshot.ts#L104-L112) 在 `/hooks` 命令或外部编辑 `settings.json` 后刷新：

```typescript
// src/utils/hooks/hooksConfigSnapshot.ts#L104-L112
export function updateHooksConfigSnapshot(): void {
  // Reset the session cache to ensure we read fresh settings from disk.
  resetSettingsCache()
  initialHooksConfig = getHooksFromAllowedSources()
}
```

先调用 `resetSettingsCache()` 确保从磁盘读取最新设置，避免文件监视器稳定性阈值未到时的缓存陈旧。

### 3. getHooksConfigFromSnapshot()

[`getHooksConfigFromSnapshot()`](../../claude-code-source/src/utils/hooks/hooksConfigSnapshot.ts#L119-L124) 是运行期读取入口，若未初始化则自动拍摄快照。

## 五、 策略过滤

### 1. getHooksFromAllowedSources()

[`getHooksFromAllowedSources()`](../../claude-code-source/src/utils/hooks/hooksConfigSnapshot.ts#L18-L53) 实现三层策略过滤：

| 条件 | 结果 |
|------|------|
| `policySettings.disableAllHooks === true` | 返回空（禁用所有 hook，含托管） |
| `policySettings.allowManagedHooksOnly === true` | 仅返回托管 hook |
| `isRestrictedToPluginOnly('hooks')` | 仅返回托管 hook（插件 hook 单独装配） |
| 非 managed 的 `disableAllHooks === true` | 仅托管 hook 仍运行（非托管无法覆盖托管） |
| 默认 | 合并所有来源（向后兼容） |

### 2. shouldAllowManagedHooksOnly() 与 shouldDisableAllHooksIncludingManaged()

[`shouldAllowManagedHooksOnly()`](../../claude-code-source/src/utils/hooks/hooksConfigSnapshot.ts#L62-L76) 判断是否仅运行托管 hook，在两种情况返回 true：策略显式设置 `allowManagedHooksOnly`，或非托管设置设了 `disableAllHooks` 但托管设置没设。

[`shouldDisableAllHooksIncludingManaged()`](../../claude-code-source/src/utils/hooks/hooksConfigSnapshot.ts#L83-L88) 仅当托管设置显式禁用时返回 true。

### 3. 执行入口的策略检查

策略检查在执行入口 [`executeHooks()`](../../claude-code-source/src/utils/hooks.ts#L1978) 中作为最后一道闸门：

```typescript
// src/utils/hooks.ts#L1978-L1980
if (shouldDisableAllHooksIncludingManaged()) {
  return
}
```

## 六、 匹配查询字段提取

不同事件使用不同的输入字段作为匹配查询（`matchQuery`）。[`getMatchingHooks()`](../../claude-code-source/src/utils/hooks.ts#L1603-L1710) 根据 `hook_event_name` 提取查询字段：

```typescript
// src/utils/hooks.ts#L1616-L1670
switch (hookInput.hook_event_name) {
  case 'PreToolUse':
  case 'PostToolUse':
  case 'PostToolUseFailure':
  case 'PermissionRequest':
  case 'PermissionDenied':
    matchQuery = hookInput.tool_name
    break
  case 'SessionStart':
    matchQuery = hookInput.source
    break
  case 'Setup':
  case 'PreCompact':
  case 'PostCompact':
    matchQuery = hookInput.trigger
    break
  case 'Notification':
    matchQuery = hookInput.notification_type
    break
  case 'SessionEnd':
    matchQuery = hookInput.reason
    break
  case 'StopFailure':
    matchQuery = hookInput.error
    break
  case 'SubagentStart':
  case 'SubagentStop':
    matchQuery = hookInput.agent_type
    break
  case 'Elicitation':
  case 'ElicitationResult':
    matchQuery = hookInput.mcp_server_name
    break
  case 'ConfigChange':
    matchQuery = hookInput.source
    break
  case 'InstructionsLoaded':
    matchQuery = hookInput.load_reason
    break
  case 'FileChanged':
    matchQuery = basename(hookInput.file_path)
    break
  // TeammateIdle, TaskCreated, TaskCompleted — 无匹配字段
}
```

`TeammateIdle`、`TaskCreated`、`TaskCompleted`、`Stop` 等事件无匹配字段，`matchQuery` 为 `undefined`，所有 matcher 都会匹配。

### 1. 匹配查询字段汇总

| 事件 | matchQuery 来源 | matcher 示例 |
|------|-----------------|-------------|
| `PreToolUse` / `PostToolUse` / `PostToolUseFailure` | `tool_name` | `Bash`、`Write\|Edit`、`^Mcp.*` |
| `PermissionRequest` / `PermissionDenied` | `tool_name` | 同上 |
| `SessionStart` | `source` | `startup`、`resume` |
| `Setup` | `trigger` | `init`、`maintenance` |
| `PreCompact` / `PostCompact` | `trigger` | `manual`、`auto` |
| `Notification` | `notification_type` | `permission_prompt` |
| `SessionEnd` | `reason` | `clear`、`logout` |
| `StopFailure` | `error` | `rate_limit` |
| `SubagentStart` / `SubagentStop` | `agent_type` | agent 类型名 |
| `Elicitation` / `ElicitationResult` | `mcp_server_name` | MCP server 名 |
| `ConfigChange` | `source` | `user_settings` |
| `InstructionsLoaded` | `load_reason` | `session_start` |
| `FileChanged` | `basename(file_path)` | `.envrc\|.env` |
| `Stop` / `TeammateIdle` / `TaskCreated` / `TaskCompleted` 等 | 无（所有 matcher 匹配） | — |

## 七、 Matcher 模式语法

[`matchesPattern()`](../../claude-code-source/src/utils/hooks.ts#L1346-L1381) 支持三种匹配模式：

### 1. 空字符串或 `*`

匹配所有查询值。当 matcher 未设置或为 `*` 时，该 matcher 下的所有 hook 都会执行。

### 2. 简单字符串或管道分隔列表

仅含 `[a-zA-Z0-9_|]` 字符的 matcher 走精确匹配路径：

- 单个名称（如 `Write`）：精确匹配，经 `normalizeLegacyToolName()` 归一化
- 管道分隔（如 `Write|Edit`）：拆分后逐个精确匹配

### 3. 正则表达式

含其他字符的 matcher 作为正则处理。除测试原始查询值外，还测试遗留工具名（`getLegacyToolNames()`），使 `^Task$` 等模式仍能匹配已重命名的工具。正则无效时记录调试日志并返回 false。

## 八、 if 条件过滤

`if` 字段使用权限规则语法（如 `Bash(git *)`）在 spawn 前进一步过滤。

### 1. prepareIfConditionMatcher()

[`prepareIfConditionMatcher()`](../../claude-code-source/src/utils/hooks.ts#L1390-L1421) 仅对 `PreToolUse`/`PostToolUse`/`PostToolUseFailure`/`PermissionRequest` 事件生效，返回一个闭包：

```typescript
// src/utils/hooks.ts#L1390-L1421
async function prepareIfConditionMatcher(
  hookInput: HookInput,
  tools: Tools | undefined,
): Promise<IfConditionMatcher | undefined> {
  // 仅对工具相关事件生效
  const toolName = normalizeLegacyToolName(hookInput.tool_name)
  const tool = tools && findToolByName(tools, hookInput.tool_name)
  const input = tool?.inputSchema.safeParse(hookInput.tool_input)
  const patternMatcher =
    input?.success && tool?.preparePermissionMatcher
      ? await tool.preparePermissionMatcher(input.data)
      : undefined

  return ifCondition => {
    const parsed = permissionRuleValueFromString(ifCondition)
    if (normalizeLegacyToolName(parsed.toolName) !== toolName) {
      return false
    }
    if (!parsed.ruleContent) {
      return true
    }
    return patternMatcher ? patternMatcher(parsed.ruleContent) : false
  }
}
```

### 2. 评估逻辑

1. 用 `permissionRuleValueFromString()` 解析 `if` 条件为 `{toolName, ruleContent}`
2. 工具名不匹配直接返回 false
3. 无 `ruleContent`（如 `Bash`）则匹配该工具的所有调用
4. 有 `ruleContent`（如 `git *`）则调用工具的 `preparePermissionMatcher` 进行内容匹配（如 Bash 的 tree-sitter 解析）

昂贵的工作（工具查找、Zod 校验、Bash 的 tree-sitter 解析）在此函数中一次性完成，返回的闭包按 hook 调用，避免每个 hook 重复解析。

## 九、 去重逻辑

### 1. hookDedupKey()

为防止不同配置源的同名 hook 重复执行，[`hookDedupKey()`](../../claude-code-source/src/utils/hooks.ts#L1453-L1455) 按来源上下文命名空间去重：

```typescript
// src/utils/hooks.ts#L1453-L1455
function hookDedupKey(m: MatchedHook, payload: string): string {
  return `${m.pluginRoot ?? m.skillRoot ?? ''}\0${payload}`
}
```

- 设置文件 hook（无 `pluginRoot`/`skillRoot`）共享 `''` 前缀：同命令在 user/project/local 会折叠为一个（保留最后一个）
- 插件 hook 以 `pluginRoot` 为前缀：两个插件的 `${CLAUDE_PLUGIN_ROOT}/hook.sh` 模板不会折叠
- `if` 是身份的一部分：`setup.sh if=Bash(git *)` 与 `setup.sh if=Bash(npm *)` 是不同的 hook

### 2. 快速路径

纯 callback/function hook 跳过去重（[`getMatchingHooks()`](../../claude-code-source/src/utils/hooks.ts#L1723-L1729)），每个 callback/function 本身唯一，无需去重，跳过 6 趟 filter + 4×Map + 4×Array.from 的开销。

## 十、 hasHookForEvent() 快速检查

[`hasHookForEvent()`](../../claude-code-source/src/utils/hooks.ts#L1582-L1593) 是轻量级存在性检查，在构造 `HookInput` 前探测是否有任何 matcher：

```typescript
// src/utils/hooks.ts#L1582-L1593
function hasHookForEvent(
  hookEvent: HookEvent,
  appState: AppState | undefined,
  sessionId: string,
): boolean {
  const snap = getHooksConfigFromSnapshot()?.[hookEvent]
  if (snap && snap.length > 0) return true
  const reg = getRegisteredHooks()?.[hookEvent]
  if (reg && reg.length > 0) return true
  if (appState?.sessionHooks.get(sessionId)?.hooks[hookEvent]) return true
  return false
}
```

故意过度近似：返回 true 但实际无命中只会进入完整匹配路径（无害），返回 false 会跳过 hook（有害），因此偏向 true。用于跳过 `createBaseHookInput`（含 `getTranscriptPathForSession` 路径拼接）与 `getMatchingHooks` 的热路径开销。

## 十一、 getHooksConfig() 装配

[`getHooksConfig()`](../../claude-code-source/src/utils/hooks.ts#L1492-L1566) 按优先级合并所有来源：

```typescript
// src/utils/hooks.ts#L1492-L1566
function getHooksConfig(appState, sessionId, hookEvent) {
  const hooks = [...(getHooksConfigFromSnapshot()?.[hookEvent] ?? [])]
  const managedOnly = shouldAllowManagedHooksOnly()

  // 注册的插件/SDK hook，managedOnly 模式跳过插件 hook
  const registeredHooks = getRegisteredHooks()?.[hookEvent]
  if (registeredHooks) {
    for (const matcher of registeredHooks) {
      if (managedOnly && 'pluginRoot' in matcher) continue
      hooks.push(matcher)
    }
  }

  // 会话 hook，managedOnly 模式跳过
  if (!managedOnly && appState !== undefined) {
    const sessionHooks = getSessionHooks(appState, sessionId, hookEvent).get(hookEvent)
    if (sessionHooks) for (const matcher of sessionHooks) hooks.push(matcher)

    const sessionFunctionHooks = getSessionFunctionHooks(appState, sessionId, hookEvent).get(hookEvent)
    if (sessionFunctionHooks) for (const matcher of sessionFunctionHooks) hooks.push(matcher)
  }

  return hooks
}
```

装配顺序：快照（settings.json 各来源）→ 注册的插件/SDK hook → 会话 hook。managedOnly 模式跳过插件 hook 与会话 hook，防止 agent/skill frontmatter hook 绕过策略。

## 十二、 相关文档

- [Hook 事件与类型](LV111-Hook事件与类型.md) — 事件与类型的定义
- [核心执行引擎](LV113-Hook核心执行引擎.md) — 匹配后的执行流程
- [Hook 注册与安全](LV115-Hook注册与安全.md) — 插件与 frontmatter 的注册流程

---

*本文档由 markdowncli 技能辅助生成*

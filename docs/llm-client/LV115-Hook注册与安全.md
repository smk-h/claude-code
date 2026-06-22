<!-- more -->

## 一、 概述

本文档涵盖 Hook 机制的注册流程与安全模型。Hook 配置来自多个来源：settings.json、插件、Agent/Skill frontmatter、SDK 回调等，各来源有独立的注册流程。安全模型是多层的，包括工作区信任、托管策略层级、HTTP hook 安全防护与插件目录校验。

## 二、 全局注册状态

### 1. RegisteredHookMatcher 类型

全局注册表存储在 [`src/bootstrap/state.ts`](../../claude-code-source/src/bootstrap/state.ts) 的 `STATE.registeredHooks`。其类型为 `HookCallbackMatcher` 与 `PluginHookMatcher` 的联合：

```typescript
// src/bootstrap/state.ts#L22
type RegisteredHookMatcher = HookCallbackMatcher | PluginHookMatcher
```

### 2. 注册与清除函数

[`registerHookCallbacks()`](../../claude-code-source/src/bootstrap/state.ts#L1419-L1434) 合并式注册（多次调用累加）：

```typescript
// src/bootstrap/state.ts#L1419-L1434
export function registerHookCallbacks(
  hooks: Partial<Record<HookEvent, RegisteredHookMatcher[]>>,
): void {
  if (!STATE.registeredHooks) {
    STATE.registeredHooks = {}
  }
  for (const [event, matchers] of Object.entries(hooks)) {
    const eventKey = event as HookEvent
    if (!STATE.registeredHooks[eventKey]) {
      STATE.registeredHooks[eventKey] = []
    }
    STATE.registeredHooks[eventKey]!.push(...matchers)
  }
}
```

- [`getRegisteredHooks()`](../../claude-code-source/src/bootstrap/state.ts#L1436-L1440)：返回当前注册表
- [`clearRegisteredHooks()`](../../claude-code-source/src/bootstrap/state.ts#L1442-L1444)：清除所有（含 callback）
- [`clearRegisteredPluginHooks()`](../../claude-code-source/src/bootstrap/state.ts#L1446-L1461)：仅清除插件 hook（有 `pluginRoot`），保留 callback hook

## 三、 插件 Hook 加载

### 1. loadPluginHooks()

[`loadPluginHooks()`](../../claude-code-source/src/utils/plugins/loadPluginHooks.ts#L91-L157) 从所有启用插件加载 Hook：

```typescript
// src/utils/plugins/loadPluginHooks.ts#L91-L157
export const loadPluginHooks = memoize(async (): Promise<void> => {
  const { enabled } = await loadAllPluginsCacheOnly()
  const allPluginHooks: Record<HookEvent, PluginHookMatcher[]> = { /* init all events to [] */ }

  for (const plugin of enabled) {
    if (!plugin.hooksConfig) continue
    const pluginMatchers = convertPluginHooksToMatchers(plugin)
    for (const event of Object.keys(pluginMatchers) as HookEvent[]) {
      allPluginHooks[event].push(...pluginMatchers[event])
    }
  }

  // Clear-then-register as an atomic pair.
  clearRegisteredPluginHooks()
  registerHookCallbacks(allPluginHooks)
})
```

[`convertPluginHooksToMatchers()`](../../claude-code-source/src/utils/plugins/loadPluginHooks.ts#L28-L86) 为每个 hook 注入 `pluginRoot`、`pluginName`、`pluginId` 上下文。

### 2. 原子替换

`clearRegisteredPluginHooks()` + `registerHookCallbacks()` 作为原子对执行（[`loadPluginHooks.ts`](../../claude-code-source/src/utils/plugins/loadPluginHooks.ts#L138-L148)）。此前 clear 位于 `clearPluginHookCache()`，导致任何 `clearAllCaches()` 调用会擦除插件 hook，直到下次 `loadPluginHooks()` 才恢复。SessionStart 显式 await `loadPluginHooks()` 所以会重新注册；Stop 无此守卫，导致插件 Stop hook 在插件管理操作后静默失效（gh-29767）。

### 3. pruneRemovedPluginHooks()

[`pruneRemovedPluginHooks()`](../../claude-code-source/src/utils/plugins/loadPluginHooks.ts#L179-L207) 从 `clearAllCaches()` 调用，移除已卸载/禁用插件的 hook 但不添加新启用插件的 hook。

### 4. 热重载

[`setupPluginHookHotReload()`](../../claude-code-source/src/utils/plugins/loadPluginHooks.ts#L255-L287) 订阅 `policySettings` 变更。[`getPluginAffectingSettingsSnapshot()`](../../claude-code-source/src/utils/plugins/loadPluginHooks.ts#L233-L247) 对四个字段（`enabledPlugins`、`extraKnownMarketplaces`、`strictKnownMarketplaces`、`blockedMarketplaces`）做键排序后 JSON 序列化，确保变更检测确定性。

## 四、 Frontmatter Hook 注册

### 1. registerFrontmatterHooks()

[`registerFrontmatterHooks()`](../../claude-code-source/src/utils/hooks/registerFrontmatterHooks.ts#L18-L67) 将 Agent/Skill frontmatter 中的 Hook 注册为会话 Hook：

```typescript
// src/utils/hooks/registerFrontmatterHooks.ts#L18-L67
export function registerFrontmatterHooks(
  setAppState, sessionId, hooks, sourceName, isAgent = false,
): void {
  for (const event of HOOK_EVENTS) {
    const matchers = hooks[event]
    if (!matchers || matchers.length === 0) continue

    // For agents, convert Stop hooks to SubagentStop
    let targetEvent: HookEvent = event
    if (isAgent && event === 'Stop') {
      targetEvent = 'SubagentStop'
    }

    for (const matcherConfig of matchers) {
      for (const hook of matcherConfig.hooks) {
        addSessionHook(setAppState, sessionId, targetEvent, matcherConfig.matcher ?? '', hook)
      }
    }
  }
}
```

Agent 的 `Stop` hook 自动转换为 `SubagentStop`，因为子 Agent 完成时触发 `SubagentStop` 而非 `Stop`。

### 2. 受策略约束

Frontmatter hook 受 `shouldAllowManagedHooksOnly()` 策略约束。`getHooksConfig()` 在 managedOnly 模式下跳过会话 hook（[`hooks.ts`](../../claude-code-source/src/utils/hooks.ts#L1541-L1563)），防止 agent/skill frontmatter hook 绕过策略。

`strictPluginOnlyCustomization` 不在 `getHooksConfig()` 处阻塞，而是在注册时（`runAgent.ts:~535`）按 agent source 门控：plugin/built-in/policySettings agent 正常注册，user-sourced agent 在 `["hooks"]` 下跳过注册。

### 3. registerSkillHooks()

[`registerSkillHooks()`](../../claude-code-source/src/utils/hooks/registerSkillHooks.ts#L20-L64) 处理 Skill frontmatter Hook，支持 `once: true` 语义（通过 `onHookSuccess` 回调在首次成功后移除），传入 `skillRoot` 作为 `CLAUDE_PLUGIN_ROOT` 环境变量值。

## 五、 工作区信任

### 1. shouldSkipHookDueToTrust()

[`shouldSkipHookDueToTrust()`](../../claude-code-source/src/utils/hooks.ts#L286-L296) 在 `executeHooks()` 与 `executeHooksOutsideREPL()` 入口集中检查：

```typescript
// src/utils/hooks.ts#L286-L296
export function shouldSkipHookDueToTrust(): boolean {
  // In non-interactive mode (SDK), trust is implicit - always execute
  const isInteractive = !getIsNonInteractiveSession()
  if (!isInteractive) {
    return false
  }

  // In interactive mode, ALL hooks require trust
  const hasTrust = checkHasTrustDialogAccepted()
  return !hasTrust
}
```

### 2. 信任模型

- 交互模式：所有 hook 需要工作区信任（`checkHasTrustDialogAccepted()`）
- 非交互模式（SDK）：隐式信任，始终执行

### 3. 安全意义

这是防御 RCE 的核心措施。Hook 执行来自 `.claude/settings.json` 的任意命令，若不强制信任，恶意仓库可通过 hook 在用户克隆后立即执行任意代码。

历史漏洞（[`hooks.ts`](../../claude-code-source/src/utils/hooks.ts#L270-L284)）：

- SessionEnd hooks 在用户拒绝信任对话框时执行
- SubagentStop hooks 在子 Agent 完成于信任前执行

集中化检查防止未来代码路径意外在信任前触发 hook。

## 六、 策略层级

托管策略（`policySettings`）具有最高优先级。详见 [Hook 配置与匹配](LV112-Hook配置与匹配.md) 的策略过滤部分。

| 字段 | 作用 |
|------|------|
| `disableAllHooks: true` | 禁用所有 hook（含托管） |
| `allowManagedHooksOnly: true` | 仅托管 hook 运行 |
| `strictPluginOnlyCustomization` | 阻塞 user/project/local 的 hook |

非托管设置的 `disableAllHooks` 无法禁用托管 hook（非托管不能覆盖托管）。

### 1. 安全检查执行顺序

Hook 执行时，安全检查按以下顺序依次执行，任一检查失败即跳过 hook：

```
1. shouldDisableAllHooksIncludingManaged()  — policySettings.disableAllHooks
2. isEnvTruthy(CLAUDE_CODE_SIMPLE)          — 简化模式
3. shouldSkipHookDueToTrust()               — 工作区信任（交互模式）
4. getMatchingHooks() → managedOnly 过滤     — 插件/会话 hook 跳过
5. if 条件匹配                               — 权限规则过滤
6. 插件目录存在性校验                         — pluginRoot pathExists
```

检查 1-3 在 [`executeHooks()`](../../claude-code-source/src/utils/hooks.ts#L1978-L1999) 入口集中执行，检查 4-5 在匹配阶段执行，检查 6 在 [`execCommandHook()`](../../claude-code-source/src/utils/hooks.ts#L831-L836) spawn 前执行。

## 七、 HTTP Hook 安全

HTTP 类型 Hook 有多层安全防护，实现在 [`src/utils/hooks/execHttpHook.ts`](../../claude-code-source/src/utils/hooks/execHttpHook.ts)。

### 1. URL 白名单

[`getHttpHookPolicy()`](../../claude-code-source/src/utils/hooks/execHttpHook.ts#L49-L58) 从合并设置读取 `allowedHttpHookUrls`。[`urlMatchesPattern()`](../../claude-code-source/src/utils/hooks/execHttpHook.ts#L64-L68) 使用 `*` 通配符匹配。

### 2. 环境变量插值白名单

`allowedEnvVars` 白名单控制 header 环境变量插值（[`interpolateEnvVars()`](../../claude-code-source/src/utils/hooks/execHttpHook.ts#L89-L101)）。未列出的变量替换为空字符串，防止通过项目配置的 HTTP hook 窃取密钥。

### 3. CRLF 注入防护

[`sanitizeHeaderValue()`](../../claude-code-source/src/utils/hooks/execHttpHook.ts#L76-L79) 剥离 CR/LF/NUL 字节，防止恶意环境变量值注入额外的 HTTP 头：

```typescript
// src/utils/hooks/execHttpHook.ts#L76-L79
function sanitizeHeaderValue(value: string): string {
  return value.replace(/[\r\n\x00]/g, '')
}
```

### 4. SSRF 防护与沙箱代理

[`ssrfGuardedLookup()`](../../claude-code-source/src/utils/hooks/ssrfGuard.ts) 在 DNS 解析阶段阻止指向内网地址的请求。[`getSandboxProxyConfig()`](../../claude-code-source/src/utils/hooks/execHttpHook.ts#L21-L41) 在沙箱启用时路由请求通过沙箱网络代理。

## 八、 插件目录校验

插件 hook 执行前校验 `pluginRoot` 是否存在（[`execCommandHook()`](../../claude-code-source/src/utils/hooks.ts#L831-L836)）：

```typescript
// src/utils/hooks.ts#L831-L836
if (!(await pathExists(pluginRoot))) {
  throw new Error(
    `Plugin directory does not exist: ${pluginRoot}` +
      (pluginId ? ` (${pluginId} — run /plugin to reinstall)` : ''),
  )
}
```

### 1. 校验的必要性

孤儿插件 GC 竞态或并发会话删除插件目录时，`python3 <missing>.py` 会退出码 2（hook 协议的阻塞码），从而卡死 UserPromptSubmit/Stop。退出码 2 来自缺失脚本与来自有意阻塞在 spawn 后无法区分，因此必须 pre-check。

### 2. 错误处理

抛出的错误被上游捕获为非阻塞错误，而非退出码 2 的阻塞错误，避免卡死。

## 九、 CLAUDE_ENV_FILE 安全

`CLAUDE_ENV_FILE` 允许 hook 写入 bash export 语句影响后续 BashTool 环境。这仅在特定事件（SessionStart/Setup/CwdChanged/FileChanged）提供（[`execCommandHook()`](../../claude-code-source/src/utils/hooks.ts#L917-L926)），且仅对 bash shell（PowerShell 跳过，因为 PS 语法 bash 无法解析）。

## 十、 AbortSignal 处理

每个 hook 使用 [`createCombinedAbortSignal()`](../../claude-code-source/src/utils/combinedAbortSignal.ts) 组合父信号与超时。aborted 状态产生 `cancelled` outcome（[`hooks.ts`](../../claude-code-source/src/utils/hooks.ts#L2473-L2497)）。

## 十一、 相关文档

- [Hook 配置与匹配](LV112-Hook配置与匹配.md) — 策略过滤对注册的影响
- [核心执行引擎](LV113-Hook核心执行引擎.md) — 安全检查在执行入口的位置
- [内部基础设施与可观测性](LV116-Hook内部基础设施与可观测性.md) — 会话 Hook 存储结构

---

*本文档由 markdowncli 技能辅助生成*

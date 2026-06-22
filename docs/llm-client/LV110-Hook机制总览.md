<!-- more -->

## 一、 概述

Claude Code 的 Hook 机制是一套事件驱动的扩展系统，允许用户在 Claude Code 生命周期的各个关键节点注入自定义逻辑。Hook 可以在工具执行前后、会话启停、用户提交提示词、权限请求等 27 个事件点触发，通过执行 shell 命令、调用 LLM、发送 HTTP 请求或运行内联回调来干预或增强 Claude 的行为。

本文档是 Hook 机制的总体概述，涵盖核心概念、整体架构、核心源码索引与完整执行流程。各子系统的详细介绍见后续文档。

## 二、 核心概念

在深入各子系统前，先理解以下核心概念：

| 概念 | 说明 |
|------|------|
| **HookEvent** | 27 个生命周期事件之一（如 `PreToolUse`、`SessionStart`），是 hook 的触发时机 |
| **HookCommand** | 可持久化的 hook 定义，按 `type` 分为 command/prompt/agent/http 四种 |
| **HookMatcher** | `{matcher, hooks}` 结构，`matcher` 过滤匹配字段，`hooks` 为待执行的 hook 列表 |
| **HookInput** | 传给 hook 的 JSON 输入，由 `BaseHookInput`（session_id/cwd 等）+ 事件专属字段组成 |
| **HookJSONOutput** | hook 的 JSON stdout 输出，含 `continue`/`decision`/`hookSpecificOutput` 等 |
| **AggregatedHookResult** | 多个 hook 并行执行后的聚合结果，yield 给调用方消费 |
| **IndividualHookConfig** | 单个 hook 的完整描述：`{event, config, matcher, source}` |

配置层级关系：

```
settings.json
  └─ hooks: HooksSettings
       └─ <HookEvent>: HookMatcher[]
            └─ HookMatcher
                 ├─ matcher: string     # 过滤匹配字段
                 └─ hooks: HookCommand[] # 判别联合，按 type 区分
                      ├─ {type: "command",  command, if, shell, timeout, ...}
                      ├─ {type: "prompt",   prompt, if, model, timeout, ...}
                      ├─ {type: "agent",    prompt, if, model, timeout, ...}
                      └─ {type: "http",     url, if, headers, ...}
```

## 三、 整体架构

Hook 机制由以下子系统构成，各子系统由独立的文档详细分析：

- **Hook 事件与类型**（[LV111](LV111-Hook事件与类型.md)）— 27 个事件类型的语义、匹配字段、退出码约定，以及 command/prompt/agent/http 四种可持久化类型与 function/callback 内存类型
- **Hook 配置与匹配**（[LV112](LV112-Hook配置与匹配.md)）— 6 种配置源、快照机制、托管策略过滤、matcher 模式、if 条件、去重逻辑
- **核心执行引擎**（[LV113](LV113-Hook核心执行引擎.md)）— `executeHooks()` 主流程、各类型执行器、输出协议（退出码与 JSON Schema）、异步 Hook 机制
- **事件包装器与工具集成**（[LV114](LV114-Hook事件包装器与工具集成.md)）— 各事件的入口函数、PreToolUse/PostToolUse 与权限决策集成
- **Hook 注册与安全**（[LV115](LV115-Hook注册与安全.md)）— 插件/frontmatter/skill/全局注册、工作区信任、策略层级、HTTP hook 安全
- **内部基础设施与可观测性**（[LV116](LV116-Hook内部基础设施与可观测性.md)）— 事件广播系统、会话 Hook 存储、性能优化、日志与遥测

## 四、 核心源码文件

| 文件 | 职责 | 详细文档 |
|------|------|----------|
| [`src/utils/hooks.ts`](../../claude-code-source/src/utils/hooks.ts) | Hook 机制主文件：核心执行引擎、事件包装器、命令执行器、输出解析 | [LV113](LV113-Hook核心执行引擎.md)、[LV114](LV114-Hook事件包装器与工具集成.md) |
| [`src/types/hooks.ts`](../../claude-code-source/src/types/hooks.ts) | Hook 类型定义、Zod 校验 Schema、回调与结果类型 | [LV111](LV111-Hook事件与类型.md)、[LV113](LV113-Hook核心执行引擎.md) |
| [`src/schemas/hooks.ts`](../../claude-code-source/src/schemas/hooks.ts) | Hook 配置 Schema（command/prompt/agent/http 四种类型的判别联合） | [LV111](LV111-Hook事件与类型.md) |
| [`src/utils/hooks/hooksConfigManager.ts`](../../claude-code-source/src/utils/hooks/hooksConfigManager.ts) | 事件元数据、按事件分组的 Hook 聚合 | [LV111](LV111-Hook事件与类型.md) |
| [`src/utils/hooks/hooksConfigSnapshot.ts`](../../claude-code-source/src/utils/hooks/hooksConfigSnapshot.ts) | Hook 配置快照与策略过滤（managed-only / disableAllHooks） | [LV112](LV112-Hook配置与匹配.md) |
| [`src/utils/hooks/hooksSettings.ts`](../../claude-code-source/src/utils/hooks/hooksSettings.ts) | 从各配置源收集 Hook、来源展示、匹配器排序 | [LV112](LV112-Hook配置与匹配.md) |
| [`src/utils/hooks/sessionHooks.ts`](../../claude-code-source/src/utils/hooks/sessionHooks.ts) | 会话级 Hook 与函数 Hook 的内存存储 | [LV116](LV116-Hook内部基础设施与可观测性.md) |
| [`src/utils/hooks/AsyncHookRegistry.ts`](../../claude-code-source/src/utils/hooks/AsyncHookRegistry.ts) | 异步 Hook 全局注册表与响应轮询 | [LV113](LV113-Hook核心执行引擎.md) |
| [`src/utils/hooks/execPromptHook.ts`](../../claude-code-source/src/utils/hooks/execPromptHook.ts) | Prompt 类型 Hook 的 LLM 调用执行器 | [LV113](LV113-Hook核心执行引擎.md) |
| [`src/utils/hooks/execAgentHook.ts`](../../claude-code-source/src/utils/hooks/execAgentHook.ts) | Agent 类型 Hook 的子 Agent 执行器 | [LV113](LV113-Hook核心执行引擎.md) |
| [`src/utils/hooks/execHttpHook.ts`](../../claude-code-source/src/utils/hooks/execHttpHook.ts) | HTTP 类型 Hook 的网络请求执行器 | [LV113](LV113-Hook核心执行引擎.md)、[LV115](LV115-Hook注册与安全.md) |
| [`src/utils/hooks/hookEvents.ts`](../../claude-code-source/src/utils/hooks/hookEvents.ts) | Hook 事件广播系统（started/progress/response） | [LV116](LV116-Hook内部基础设施与可观测性.md) |
| [`src/utils/hooks/registerFrontmatterHooks.ts`](../../claude-code-source/src/utils/hooks/registerFrontmatterHooks.ts) | Agent/Skill frontmatter Hook 注册为会话 Hook | [LV115](LV115-Hook注册与安全.md) |
| [`src/utils/hooks/registerSkillHooks.ts`](../../claude-code-source/src/utils/hooks/registerSkillHooks.ts) | Skill frontmatter Hook 注册（含 `once` 一次性语义） | [LV115](LV115-Hook注册与安全.md) |
| [`src/utils/plugins/loadPluginHooks.ts`](../../claude-code-source/src/utils/plugins/loadPluginHooks.ts) | 插件 Hook 加载与热重载 | [LV115](LV115-Hook注册与安全.md) |
| [`src/services/tools/toolHooks.ts`](../../claude-code-source/src/services/tools/toolHooks.ts) | Hook 与工具执行流程的集成层 | [LV114](LV114-Hook事件包装器与工具集成.md) |
| [`src/bootstrap/state.ts`](../../claude-code-source/src/bootstrap/state.ts) | 全局 `registeredHooks` 状态与注册函数 | [LV115](LV115-Hook注册与安全.md) |
| [`src/entrypoints/sdk/coreTypes.ts`](../../claude-code-source/src/entrypoints/sdk/coreTypes.ts) | `HOOK_EVENTS` 常量数组定义 | [LV111](LV111-Hook事件与类型.md) |

## 五、 数据流概览

Hook 机制的端到端数据流如下：

1. **配置阶段** — 从 `settings.json`、插件、frontmatter 等来源加载 Hook 配置，拍摄快照
2. **事件触发** — 工具执行、会话启停等生命周期事件触发对应的包装器函数
3. **匹配阶段** — 按 `matchQuery` 与 matcher 模式匹配，经 `if` 条件过滤，去重
4. **执行阶段** — 并行执行所有命中 hook，按类型分发到对应执行器
5. **输出解析** — 解析 stdout/JSON，转为 `HookResult`
6. **结果聚合** — 聚合权限行为（deny > ask > allow），yield `AggregatedHookResult`
7. **消费阶段** — 调用方（如工具执行流程）消费结果，决定是否继续

## 六、 Hook 生命周期

Hook 从应用启动到关闭经历完整的生命周期，涵盖初始化、运行期事件触发、热重载与清理。本节概述各阶段的关键操作与调用入口。

### 1. 应用启动

```
main.tsx / print.ts
  ├─ setAllHookEventsEnabled(true)        — 启用全事件广播（SDK/REMOTE 模式）
  ├─ captureHooksConfigSnapshot()         — 拍摄配置快照（settings.json 各来源）
  └─ setupPluginHookHotReload()           — 订阅 policySettings 变更热重载
```

- [`captureHooksConfigSnapshot()`](../../claude-code-source/src/utils/hooks/hooksConfigSnapshot.ts#L95-L97) 在启动早期调用，从 `getHooksFromAllowedSources()` 读取经策略过滤后的配置，存入模块级 `initialHooksConfig`。详见 [LV112](LV112-Hook配置与匹配.md) 的配置快照机制。
- [`setAllHookEventsEnabled(true)`](../../claude-code-source/src/utils/hooks/hookEvents.ts#L184-L186) 在 SDK `includeHookEvents` 选项或 `CLAUDE_CODE_REMOTE` 模式下调用，启用所有事件类型的广播（默认仅 `SessionStart` 与 `Setup` 广播）。
- [`setupPluginHookHotReload()`](../../claude-code-source/src/utils/plugins/loadPluginHooks.ts#L255-L287) 订阅 `policySettings` 变更，对比四字段快照决定是否重载插件 hook。

### 2. 会话启动

[`processSessionStartHooks()`](../../claude-code-source/src/utils/sessionStart.ts#L35-L175) 是会话启动的编排入口：

```
processSessionStartHooks(source, { sessionId, agentType, model, forceSyncExecution })
  ├─ isBareMode() 检查 — --bare 跳过所有 hook
  ├─ shouldAllowManagedHooksOnly() 检查 — managedOnly 跳过插件 hook
  ├─ loadPluginHooks() — 确保插件 hook 已加载（memoized，已加载则立即返回）
  ├─ executeSessionStartHooks(source, ...) — 执行 SessionStart 事件
  │    └─ forceSyncExecution 强制同步（忽略 async 声明）
  ├─ 收集 watchPaths → updateWatchPaths()
  ├─ 收集 additionalContexts → 构造附件消息
  └─ 收集 initialUserMessage → 存入 pendingInitialUserMessage 侧信道
```

`source` 参数区分四种启动场景：`startup`（冷启动）、`resume`（恢复会话）、`clear`（清空对话）、`compact`（压缩后重启）。

### 3. 运行期事件触发

会话启动后，Hook 在以下时机被触发：

| 生命周期阶段 | 触发事件 | 入口 |
|-------------|----------|------|
| 用户提交提示词 | `UserPromptSubmit` | REPL 查询循环 |
| 工具执行前 | `PreToolUse` | `toolExecution.ts` → [`runPreToolUseHooks()`](../../claude-code-source/src/services/tools/toolHooks.ts#L435) |
| 工具执行后 | `PostToolUse` | `toolExecution.ts` → [`runPostToolUseHooks()`](../../claude-code-source/src/services/tools/toolHooks.ts#L39) |
| 工具执行失败 | `PostToolUseFailure` | `toolExecution.ts` |
| 权限对话框 | `PermissionRequest` | 权限流程 |
| 子 Agent 启动/停止 | `SubagentStart`/`SubagentStop` | `runAgent.ts` |
| 回合结束 | `Stop` / `StopFailure` | 查询循环结束 |
| 通知发送 | `Notification` | 通知系统 |
| 压缩前后 | `PreCompact`/`PostCompact` | 压缩流程 |
| 配置变更 | `ConfigChange` | 文件监视器 |
| 工作目录变更 | `CwdChanged` | 目录切换 |
| 文件变更 | `FileChanged` | 文件监视器 |
| 指令文件加载 | `InstructionsLoaded` | 指令加载流程 |

### 4. 子 Agent 生命周期

子 Agent（Agent 工具调用）有独立的 hook 生命周期：

```
runAgent.ts
  ├─ registerFrontmatterHooks(setAppState, agentId, hooks, sourceName, isAgent=true)
  │    └─ Stop → SubagentStop 转换
  ├─ executeSubagentStartHooks(agentId, agentType)
  ├─ ... 子 Agent 执行（PreToolUse/PostToolUse/Stop 等事件正常触发）...
  ├─ executeStopHooks(subagentId) — 触发 SubagentStop 事件
  └─ clearSessionHooks(rootSetAppState, agentId) — 清理子 Agent 会话 hook（finally 块）
```

Agent frontmatter 中定义的 hook 通过 [`registerFrontmatterHooks()`](../../claude-code-source/src/utils/hooks/registerFrontmatterHooks.ts#L18-L67) 注册为会话级 hook（按 `agentId` 隔离）。子 Agent 的 `Stop` hook 被自动转换为 `SubagentStop`。无论子 Agent 正常完成、中止还是出错，`clearSessionHooks()` 都在 `finally` 块中执行，确保会话 hook 不泄漏。

### 5. 配置热重载

运行期配置变更通过以下机制处理：

| 变更类型 | 处理方式 | 入口 |
|----------|----------|------|
| `/hooks` 命令编辑 | `updateHooksConfigSnapshot()` 刷新快照 | `/hooks` 命令处理器 |
| 外部编辑 `settings.json` | `updateHooksConfigSnapshot()` 刷新快照 | 文件监视器 |
| `policySettings` 变更 | `setupPluginHookHotReload()` 触发插件 hook 重载 | `settingsChangeDetector` |
| 插件启用/禁用 | `loadPluginHooks()` 原子替换 | `/plugins` UI、`refreshActivePlugins` |
| 插件卸载 | `pruneRemovedPluginHooks()` 移除已卸载插件的 hook | `clearAllCaches()` |

### 6. 会话结束

会话结束有三个调用场景，均通过 [`executeSessionEndHooks()`](../../claude-code-source/src/utils/hooks.ts#L4097-L4141) 执行：

| 场景 | `reason` | 入口 | 超时 |
|------|----------|------|------|
| `/clear` 清空对话 | `'clear'` | [`conversation.ts`](../../claude-code-source/src/commands/clear/conversation.ts#L69) | `getSessionEndHookTimeoutMs()`（默认 1.5s） |
| `/resume` 恢复会话 | `'resume'` | [`REPL.tsx`](../../claude-code-source/src/screens/REPL.tsx#L1774) | 同上 |
| 进程退出 | `'logout'`/`'prompt_input_exit'`/`'other'` | [`gracefulShutdown.ts`](../../claude-code-source/src/utils/gracefulShutdown.ts#L473) | 同上 |

`executeSessionEndHooks()` 流程：

```
executeSessionEndHooks(reason, { getAppState, setAppState, signal, timeoutMs })
  ├─ 构造 SessionEndHookInput（含 reason）
  ├─ executeHooksOutsideREPL() — REPL 外执行（不 yield 消息）
  ├─ 失败的 hook 输出到 stderr（Ink 已卸载）
  └─ clearSessionHooks(setAppState, sessionId) — 清理会话 hook
```

SessionEnd hook 的超时由 `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS` 环境变量控制（默认 1500ms），因为会话结束在关闭/清空流程中需要紧凑的时间预算。

### 7. 异步 Hook 收尾

异步 hook（`async: true` 或输出 `{"async":true}`）在后台运行，其生命周期独立于触发事件：

- 运行期通过 [`checkForAsyncHookResponses()`](../../claude-code-source/src/utils/hooks/AsyncHookRegistry.ts#L113-L268) 轮询收集已完成的响应
- 会话/进程结束时通过 [`finalizePendingAsyncHooks()`](../../claude-code-source/src/utils/hooks/AsyncHookRegistry.ts#L281-L301) 统一收尾：
  - 已完成的 hook 记录最终结果
  - 未完成的 hook 被 kill 后标记为 `cancelled`
  - 清空 `pendingHooks` Map

`asyncRewake` 模式的 hook 完全绕过 AsyncHookRegistry，其生命周期由进程自身的 `shellCommand.result.then()` 回调管理，不参与 `finalizePendingAsyncHooks()` 收尾。

### 8. 生命周期时序图

```
应用启动
  │
  ├─ captureHooksConfigSnapshot()
  ├─ setAllHookEventsEnabled(true) [SDK/REMOTE]
  ├─ setupPluginHookHotReload()
  │
  ▼
会话启动 (startup/resume/clear/compact)
  │
  ├─ loadPluginHooks() [确保插件 hook 已加载]
  ├─ executeSessionStartHooks() [forceSyncExecution]
  ├─ updateWatchPaths() [注册文件监视]
  │
  ▼
运行期 (事件循环)
  │
  ├─ UserPromptSubmit → PreToolUse → [工具执行] → PostToolUse
  ├─ Stop / StopFailure
  ├─ SubagentStart → [子 Agent 生命周期] → SubagentStop → clearSessionHooks(agentId)
  ├─ Notification / PreCompact / PostCompact / ConfigChange / ...
  ├─ [配置变更] → updateHooksConfigSnapshot() / loadPluginHooks() 热重载
  │
  ▼
会话结束 (clear/resume/logout/exit)
  │
  ├─ executeSessionEndHooks(reason) [1.5s 超时]
  ├─ clearSessionHooks(sessionId)
  │
  ▼
进程退出
  │
  └─ finalizePendingAsyncHooks() [收尾异步 hook]
```

## 七、 完整执行流程示例

以 `PreToolUse` 事件为例，完整流程如下：

1. 工具执行前，`toolExecution.ts` 调用 [`runPreToolUseHooks()`](../../claude-code-source/src/services/tools/toolHooks.ts#L435)
2. `runPreToolUseHooks()` 调用 [`executePreToolHooks()`](../../claude-code-source/src/utils/hooks.ts#L3394)
3. `executePreToolHooks()` 通过 `hasHookForEvent()` 快速检查，若无可命中 hook 则直接返回
4. 构造 `PreToolUseHookInput`，调用 [`executeHooks()`](../../claude-code-source/src/utils/hooks.ts#L1952)
5. `executeHooks()` 检查 `shouldDisableAllHooksIncludingManaged()` 与工作区信任
6. 调用 [`getMatchingHooks()`](../../claude-code-source/src/utils/hooks.ts#L1603)，经 [`getHooksConfig()`](../../claude-code-source/src/utils/hooks.ts#L1492) 装配各来源 hook，按 `tool_name` 匹配 matcher，按 `if` 条件过滤，去重
7. 内部 callback 走快速路径；用户 hook 并行执行
8. command hook 经 [`execCommandHook()`](../../claude-code-source/src/utils/hooks.ts#L747) spawn 子进程，stdin 写入 hookInput JSON
9. stdout 首行检测异步；否则等待进程结束，[`parseHookOutput()`](../../claude-code-source/src/utils/hooks.ts#L399) 解析输出
10. [`processHookJSONOutput()`](../../claude-code-source/src/utils/hooks.ts#L489) 将 JSON 转为 `HookResult`，提取 `permissionBehavior`、`updatedInput` 等
11. `executeHooks()` 聚合权限行为（deny > ask > allow），yield `AggregatedHookResult`
12. `runPreToolUseHooks()` 转为 `hookPermissionResult` 等
13. [`resolveHookPermissionDecision()`](../../claude-code-source/src/services/tools/toolHooks.ts#L332) 结合 `checkRuleBasedPermissions` 决定最终权限
14. 工具按最终决策执行或被阻止

各步骤的详细实现见对应子文档。

---

*本文档由 markdowncli 技能辅助生成*

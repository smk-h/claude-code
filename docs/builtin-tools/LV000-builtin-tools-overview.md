<!-- more -->

## 一、 工具体系总览

### 1. 架构定位

Claude Code 的工具（Tool）是模型与外部世界交互的统一抽象层。每条用户指令最终会拆解为若干个工具调用（tool use）,模型通过调用工具来读取文件、执行命令、搜索代码、发起网络请求等。整个工具体系由三个核心文件支撑:

| 文件 | 职责 |
| - | - |
| [`Tool.ts`](../../claude-code-source/src/Tool.ts) | 定义 `Tool` 接口、`buildTool()` 工厂函数、`ToolUseContext` 等基础类型 |
| [`tools.ts`](../../claude-code-source/src/tools.ts) | 工具注册中心,`getAllBaseTools()` 是所有内置工具的唯一真相来源 |
| [`constants/tools.ts`](../../claude-code-source/src/constants/tools.ts) | 工具分组与权限限制规则（子代理禁用工具、异步代理允许工具等） |

每个工具独立存放在 [`src/tools/`](../../claude-code-source/src/tools) 目录下的子目录中,包含实现文件、`prompt.ts`（描述文本）、`constants.ts`（工具名常量）、`UI.tsx`（终端渲染）等文件。

### 2. 工具定义接口

所有工具均通过 `buildTool()` 函数构建,该函数在 [`Tool.ts`](../../claude-code-source/src/Tool.ts#L783-L792) 中定义:

```typescript
// claude-code-source/src/Tool.ts
export function buildTool<D extends AnyToolDef>(def: D): BuiltTool<D> {
  return {
    ...TOOL_DEFAULTS,           // 先铺默认值
    userFacingName: () => def.name,  // 默认 userFacingName 为工具名
    ...def,                     // 再用传入定义覆盖
  } as BuiltTool<D>
}
```

一个工具定义（`ToolDef`）的核心字段包括:

- `name`：工具正式名称,用于模型调用和权限匹配
- `aliases`：别名数组,用于向后兼容旧工具名
- `description`：异步函数,返回工具的简短描述
- `prompt`：异步函数,生成工具的系统提示词
- `inputSchema` / `outputSchema`：输入输出校验 Schema,基于 Zod
- `call`：工具执行主函数,接收输入参数和上下文
- `isEnabled`：是否启用（运行时可动态判断）
- `isReadOnly`：是否只读（不影响文件系统或外部状态）
- `maxResultSizeChars`：结果最大字符数
- `searchHint`：ToolSearch 关键词匹配用的短语

### 3. 工具数量规模

Claude Code 源码中共有约 45 个工具目录,其中约 20 个为始终可用的核心工具,其余约 25 个为条件性工具（受 feature flag 或环境变量控制）。工具池大小会根据运行环境动态变化。

## 二、 工具注册机制

### 1. getAllBaseTools 注册中心

[`tools.ts`](../../claude-code-source/src/tools.ts#L193-L251) 中的 `getAllBaseTools()` 函数是所有内置工具的唯一注册入口:

```typescript
// claude-code-source/src/tools.ts
export function getAllBaseTools(): Tools {
  return [
    AgentTool,
    TaskOutputTool,
    BashTool,
    ...(hasEmbeddedSearchTools() ? [] : [GlobTool, GrepTool]),
    ExitPlanModeV2Tool,
    FileReadTool,
    FileEditTool,
    FileWriteTool,
    NotebookEditTool,
    WebFetchTool,
    TodoWriteTool,
    WebSearchTool,
    TaskStopTool,
    AskUserQuestionTool,
    SkillTool,
    EnterPlanModeTool,
    ...(process.env.USER_TYPE === 'ant' ? [ConfigTool] : []),
    ...(process.env.USER_TYPE === 'ant' ? [TungstenTool] : []),
    // ... 更多条件性工具
    BriefTool,
    ListMcpResourcesTool,
    ReadMcpResourceTool,
    ...(isToolSearchEnabledOptimistic() ? [ToolSearchTool] : []),
  ]
}
```

该函数通过两种方式控制工具的可用性:

- **静态导入**：始终可用的核心工具直接 `import` 并放入数组
- **动态 require + feature flag**：条件性工具通过 `feature('FLAG_NAME')` 或 `process.env` 判断后条件加载,实现死代码消除（Dead Code Elimination）

### 2. 条件加载与死代码消除

条件性工具使用 `require()` 动态加载,确保未启用的工具不会被打包进最终产物。典型模式如下:

```typescript
// claude-code-source/src/tools.ts
const SleepTool =
  feature('PROACTIVE') || feature('KAIROS')
    ? require('./tools/SleepTool/SleepTool.js').SleepTool
    : null

const cronTools = feature('AGENT_TRIGGERS')
  ? [
      require('./tools/ScheduleCronTool/CronCreateTool.js').CronCreateTool,
      require('./tools/ScheduleCronTool/CronDeleteTool.js').CronDeleteTool,
      require('./tools/ScheduleCronTool/CronListTool.js').CronListTool,
    ]
  : []
```

`feature()` 函数来自 `bun:bundle`,是编译期的 feature flag 检测,构建工具会据此进行树摇（tree shaking）。

### 3. 循环依赖处理

部分工具（如 TeamCreateTool、TeamDeleteTool、SendMessageTool）存在循环依赖,通过惰性 `require` 包装函数解决:

```typescript
// claude-code-source/src/tools.ts
const getTeamCreateTool = () =>
  require('./tools/TeamCreateTool/TeamCreateTool.js')
    .TeamCreateTool as typeof import('./tools/TeamCreateTool/TeamCreateTool.js').TeamCreateTool

const getSendMessageTool = () =>
  require('./tools/SendMessageTool/SendMessageTool.js')
    .SendMessageTool as typeof import('./tools/SendMessageTool/SendMessageTool.js').SendMessageTool
```

惰性 require 将模块加载推迟到首次调用时,打破 `tools.ts → TeamCreateTool → ... → tools.ts` 的循环引用链。

## 三、 核心内置工具

### 1. 文件操作类

#### 1.1 Read

文件读取工具,定义在 [`FileReadTool.ts`](../../claude-code-source/src/tools/FileReadTool/FileReadTool.ts) 中。支持读取文本文件、图片（PNG/JPG/GIF/WebP）、PDF、Jupyter notebook。支持通过 `offset` 和 `limit` 参数按行范围读取,自动检测文件编码。

#### 1.2 Edit

文件编辑工具,定义在 [`FileEditTool.ts`](../../claude-code-source/src/tools/FileEditTool/FileEditTool.ts) 中。执行精确字符串替换,要求调用前先用 Read 读取目标文件。支持 `replace_all` 参数进行批量替换。当 `old_string` 在文件中不唯一时,替换会失败,需提供更多上下文以唯一定位。

#### 1.3 Write

文件写入工具,定义在 [`FileWriteTool.ts`](../../claude-code-source/src/tools/FileWriteTool/FileWriteTool.ts) 中。写入或覆盖文件内容,要求先读取已有文件。适用于创建新文件或完整重写。对于局部修改应优先使用 Edit。

#### 1.4 NotebookEdit

Jupyter notebook 编辑工具,定义在 [`NotebookEditTool.ts`](../../claude-code-source/src/tools/NotebookEditTool/NotebookEditTool.ts) 中。支持对 `.ipynb` 文件中的单元格进行替换、插入、删除操作,区分 code 和 markdown 两种单元格类型。

### 2. 代码搜索类

#### 2.1 Glob

文件名模式匹配工具,定义在 [`GlobTool.ts`](../../claude-code-source/src/tools/GlobTool/GlobTool.ts) 中。基于 glob 模式（如 `**/*.ts`）快速查找文件,返回的路径按修改时间排序。当 Ant-native 构建内置了搜索工具时,该工具会被跳过（通过 `hasEmbeddedSearchTools()` 判断）。

#### 2.2 Grep

内容搜索工具,定义在 [`GrepTool.ts`](../../claude-code-source/src/tools/GrepTool/GrepTool.ts) 中。基于 ripgrep 构建,支持正则表达式、文件类型过滤、glob 过滤、上下文行显示以及多种输出模式（content / files_with_matches / count）。与 GlobTool 一样,在 Ant-native 构建中可能被跳过。

### 3. 命令执行类

#### 3.1 Bash

Shell 命令执行工具,定义在 [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx) 中。这是 Claude Code 中最核心的命令执行工具,支持:

- 命令超时控制
- 后台执行（`run_in_background` 参数）
- 沙箱隔离
- 安全分析（检测危险命令）
- 跨平台 shell 适配

### 4. 子代理与任务管理类

#### 4.1 Agent

子代理启动工具,定义在 [`AgentTool.tsx`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx) 中。将复杂多步骤任务委托给独立的子 Agent 进程。支持后台执行、fork、自定义 Agent 类型。旧名 `Task` 作为别名保留以保持向后兼容。详见 [LV050-AgentTool-工具总览与注册机制](./LV050-AgentTool-工具总览与注册机制.md)。

#### 4.2 TaskOutput

后台任务输出获取工具,定义在 [`TaskOutputTool.ts`](../../claude-code-source/src/tools/TaskOutputTool/TaskOutputTool.ts) 中。读取后台运行中的 Agent 或 Bash 命令的输出。

#### 4.3 TaskStop

任务停止工具,定义在 [`TaskStopTool.ts`](../../claude-code-source/src/tools/TaskStopTool/TaskStopTool.ts) 中。终止正在运行的后台任务或子 Agent。

### 5. 网络访问类

#### 5.1 WebFetch

URL 内容获取工具,定义在 [`WebFetchTool.ts`](../../claude-code-source/src/tools/WebFetchTool/WebFetchTool.ts) 中。获取指定 URL 的内容,将 HTML 转换为 markdown,并使用小模型根据用户提供的 prompt 处理内容。内置 15 分钟缓存。

#### 5.2 WebSearch

网络搜索工具,定义在 [`WebSearchTool.ts`](../../claude-code-source/src/tools/WebSearchTool/WebSearchTool.ts) 中。执行网络搜索并使用搜索结果辅助生成回答。

### 6. 交互与规划类

#### 6.1 AskUserQuestion

用户提问工具,定义在 [`AskUserQuestionTool.ts`](../../claude-code-source/src/tools/AskUserQuestionTool/AskUserQuestionTool.ts) 中。当模型需要澄清信息时,向用户提问以获取明确回答。

#### 6.2 EnterPlanMode / ExitPlanMode

计划模式进入与退出工具,分别定义在 [`EnterPlanModeTool.ts`](../../claude-code-source/src/tools/EnterPlanModeTool/EnterPlanModeTool.ts) 和 [`ExitPlanModeV2Tool.ts`](../../claude-code-source/src/tools/ExitPlanModeTool/ExitPlanModeV2Tool.ts) 中。计划模式下,模型先输出方案供用户审批,获批后才执行实际操作。

#### 6.3 TodoWrite

待办事项写入工具,定义在 [`TodoWriteTool.ts`](../../claude-code-source/src/tools/TodoWriteTool/TodoWriteTool.ts) 中。管理任务进度列表,用于跟踪多步骤任务的完成情况。

### 7. 扩展与资源类

#### 7.1 Skill

技能加载工具,定义在 [`SkillTool.ts`](../../claude-code-source/src/tools/SkillTool/SkillTool.ts) 中。按需加载用户定义的技能（Skill）扩展,将技能的完整指令注入到上下文中。

#### 7.2 Brief

简报工具,定义在 [`BriefTool.ts`](../../claude-code-source/src/tools/BriefTool/BriefTool.ts) 中。用于生成任务或上下文的简要概述。

#### 7.3 ListMcpResources / ReadMcpResource

MCP（Model Context Protocol）资源工具,分别定义在 [`ListMcpResourcesTool.ts`](../../claude-code-source/src/tools/ListMcpResourcesTool/ListMcpResourcesTool.ts) 和 [`ReadMcpResourceTool.ts`](../../claude-code-source/src/tools/ReadMcpResourceTool/ReadMcpResourceTool.ts) 中。列出和读取 MCP 服务器提供的资源。

## 四、 条件性工具

### 1. 内部专用工具（USER_TYPE === 'ant'）

以下工具仅在 Ant 内部用户场景下启用:

| 工具名 | 源文件 | 功能说明 |
| - | - | - |
| ConfigTool | [`ConfigTool/`](../../claude-code-source/src/tools/ConfigTool/ConfigTool.ts) | 配置管理 |
| TungstenTool | [`TungstenTool/`](../../claude-code-source/src/tools/TungstenTool/TungstenTool.ts) | 虚拟终端抽象 |
| REPLTool | [`REPLTool/`](../../claude-code-source/src/tools/REPLTool/REPLTool.ts) | REPL 交互式环境,包裹 Bash/Read/Edit |
| SuggestBackgroundPRTool | [`SuggestBackgroundPRTool/`](../../claude-code-source/src/tools/SuggestBackgroundPRTool/SuggestBackgroundPRTool.ts) | 建议后台 PR |

### 2. Feature Flag 控制工具

以下工具通过 `feature()` 编译期 flag 控制:

| 工具名 | Feature Flag | 功能说明 |
| - | - | - |
| WebBrowserTool | `WEB_BROWSER_TOOL` | 浏览器自动化 |
| WorkflowTool | `WORKFLOW_SCRIPTS` | 工作流脚本执行 |
| SleepTool | `PROACTIVE` / `KAIROS` | 休眠/延迟 |
| CronCreateTool | `AGENT_TRIGGERS` | 创建定时任务 |
| CronDeleteTool | `AGENT_TRIGGERS` | 删除定时任务 |
| CronListTool | `AGENT_TRIGGERS` | 列出定时任务 |
| RemoteTriggerTool | `AGENT_TRIGGERS_REMOTE` | 远程触发 |
| MonitorTool | `MONITOR_TOOL` | 监控 |
| SendUserFileTool | `KAIROS` | 发送文件给用户 |
| PushNotificationTool | `KAIROS` / `KAIROS_PUSH_NOTIFICATION` | 推送通知 |
| SubscribePRTool | `KAIROS_GITHUB_WEBHOOKS` | 订阅 PR 事件 |
| OverflowTestTool | `OVERFLOW_TEST_TOOL` | 溢出测试 |
| CtxInspectTool | `CONTEXT_COLLAPSE` | 上下文检查 |
| TerminalCaptureTool | `TERMINAL_PANEL` | 终端捕获 |
| SnipTool | `HISTORY_SNIP` | 历史记录裁剪 |
| ListPeersTool | `UDS_INBOX` | 列出对等节点 |

### 3. 运行时条件工具

以下工具通过运行时函数判断是否启用:

| 工具名 | 触发条件 | 功能说明 |
| - | - | - |
| TaskCreate / TaskGet / TaskUpdate / TaskList | `isTodoV2Enabled()` | TodoV2 待办系统（创建/获取/更新/列出） |
| EnterWorktree / ExitWorktree | `isWorktreeModeEnabled()` | 进入/退出 git worktree 隔离模式 |
| TeamCreate / TeamDelete | `isAgentSwarmsEnabled()` | 创建/删除多代理团队 |
| PowerShellTool | `isPowerShellToolEnabled()` | PowerShell 命令执行（Windows） |
| LSPTool | `ENABLE_LSP_TOOL` 环境变量 | LSP 语言服务器协议集成 |
| VerifyPlanExecutionTool | `CLAUDE_CODE_VERIFY_PLAN === 'true'` | 验证计划执行 |
| ToolSearchTool | `isToolSearchEnabledOptimistic()` | 工具搜索（工具过多时按需加载工具定义） |
| TestingPermissionTool | `NODE_ENV === 'test'` | 测试用权限工具 |

## 五、 工具分组与权限限制

### 1. 子代理禁用工具

在 [`constants/tools.ts`](../../claude-code-source/src/constants/tools.ts#L36-L46) 中定义了 `ALL_AGENT_DISALLOWED_TOOLS`,所有子代理均不可使用以下工具:

```typescript
// claude-code-source/src/constants/tools.ts
export const ALL_AGENT_DISALLOWED_TOOLS = new Set([
  TASK_OUTPUT_TOOL_NAME,        // 防止递归
  EXIT_PLAN_MODE_V2_TOOL_NAME,  // 计划模式是主线程抽象
  ENTER_PLAN_MODE_TOOL_NAME,    // 计划模式是主线程抽象
  ...(process.env.USER_TYPE === 'ant' ? [] : [AGENT_TOOL_NAME]),  // 防止递归（ant 用户除外）
  ASK_USER_QUESTION_TOOL_NAME,  // 子代理不能打断用户
  TASK_STOP_TOOL_NAME,          // 需要主线程任务状态
  ...(feature('WORKFLOW_SCRIPTS') ? [WORKFLOW_TOOL_NAME] : []),  // 防止递归工作流
])
```

### 2. 异步代理允许工具

异步代理（Async Agent）只能使用一组安全的只读和文件操作类工具,定义在 [`constants/tools.ts`](../../claude-code-source/src/constants/tools.ts#L55-L71) 中:

```typescript
// claude-code-source/src/constants/tools.ts
export const ASYNC_AGENT_ALLOWED_TOOLS = new Set([
  FILE_READ_TOOL_NAME,
  WEB_SEARCH_TOOL_NAME,
  TODO_WRITE_TOOL_NAME,
  GREP_TOOL_NAME,
  WEB_FETCH_TOOL_NAME,
  GLOB_TOOL_NAME,
  ...SHELL_TOOL_NAMES,
  FILE_EDIT_TOOL_NAME,
  FILE_WRITE_TOOL_NAME,
  NOTEBOOK_EDIT_TOOL_NAME,
  SKILL_TOOL_NAME,
  SYNTHETIC_OUTPUT_TOOL_NAME,
  TOOL_SEARCH_TOOL_NAME,
  ENTER_WORKTREE_TOOL_NAME,
  EXIT_WORKTREE_TOOL_NAME,
])
```

异步代理被阻止使用 AgentTool、TaskOutputTool、ExitPlanModeTool、TaskStopTool 和 TungstenTool,原因包括防止递归、计划模式为主线程抽象、虚拟终端单例冲突等。

### 3. 进程内队友允许工具

进程内队友（In-process Teammate）除了异步代理允许的工具外,还可以使用以下额外工具,定义在 [`constants/tools.ts`](../../claude-code-source/src/constants/tools.ts#L77-L88) 中:

```typescript
// claude-code-source/src/constants/tools.ts
export const IN_PROCESS_TEAMMATE_ALLOWED_TOOLS = new Set([
  TASK_CREATE_TOOL_NAME,
  TASK_GET_TOOL_NAME,
  TASK_LIST_TOOL_NAME,
  TASK_UPDATE_TOOL_NAME,
  SEND_MESSAGE_TOOL_NAME,
  ...(feature('AGENT_TRIGGERS')
    ? [CRON_CREATE_TOOL_NAME, CRON_DELETE_TOOL_NAME, CRON_LIST_TOOL_NAME]
    : []),
])
```

### 4. 协调器模式允许工具

协调器（Coordinator）模式下只允许代理管理和输出工具,定义在 [`constants/tools.ts`](../../claude-code-source/src/constants/tools.ts#L107-L112) 中:

```typescript
// claude-code-source/src/constants/tools.ts
export const COORDINATOR_MODE_ALLOWED_TOOLS = new Set([
  AGENT_TOOL_NAME,            // 启动子代理
  TASK_STOP_TOOL_NAME,        // 停止任务
  SEND_MESSAGE_TOOL_NAME,     // 发送消息
  SYNTHETIC_OUTPUT_TOOL_NAME, // 合成输出
])
```

协调器本身不直接操作文件,只负责任务分配和代理管理。

## 六、 工具组装流程

### 1. 组装管线

工具从注册到最终提供给模型使用,经历以下管线:

```
getAllBaseTools()     → 所有可能的工具（含 feature flag 过滤）
        ↓
getTools()            → 按模式过滤 + deny 规则过滤 + isEnabled() 过滤
        ↓
assembleToolPool()    → 合并内置工具 + MCP 工具，按名称去重
```

### 2. getTools 多模式过滤

`getTools()` 函数定义在 [`tools.ts`](../../claude-code-source/src/tools.ts#L271-L327) 中,支持多种运行模式:

```typescript
// claude-code-source/src/tools.ts
export const getTools = (permissionContext: ToolPermissionContext): Tools => {
  // Simple 模式：仅 Bash、Read、Edit
  if (isEnvTruthy(process.env.CLAUDE_CODE_SIMPLE)) {
    if (isReplModeEnabled() && REPLTool) {
      const replSimple: Tool[] = [REPLTool]
      // 协调器模式下追加 TaskStop 和 SendMessage
      return filterToolsByDenyRules(replSimple, permissionContext)
    }
    const simpleTools: Tool[] = [BashTool, FileReadTool, FileEditTool]
    return filterToolsByDenyRules(simpleTools, permissionContext)
  }

  // 标准模式：获取全部工具后过滤
  const tools = getAllBaseTools().filter(tool => !specialTools.has(tool.name))
  let allowedTools = filterToolsByDenyRules(tools, permissionContext)

  // REPL 模式：隐藏被 REPL 包裹的原语工具
  if (isReplModeEnabled()) {
    const replEnabled = allowedTools.some(tool => toolMatchesName(tool, REPL_TOOL_NAME))
    if (replEnabled) {
      allowedTools = allowedTools.filter(tool => !REPL_ONLY_TOOLS.has(tool.name))
    }
  }

  const isEnabled = allowedTools.map(_ => _.isEnabled())
  return allowedTools.filter((_, i) => isEnabled[i])
}
```

三种模式的行为:

- **Simple 模式**（`CLAUDE_CODE_SIMPLE`）：仅保留 Bash、Read、Edit 三个基础工具;若同时启用 REPL,则用 REPL 替代
- **REPL 模式**：用 REPL 工具包裹 Bash/Read/Edit 等原语,通过 `REPL_ONLY_TOOLS` 集合隐藏被包裹的原语
- **标准模式**：获取全部工具,依次经过 deny 规则过滤和 `isEnabled()` 过滤

### 3. assembleToolPool 最终组装

`assembleToolPool()` 定义在 [`tools.ts`](../../claude-code-source/src/tools.ts#L345-L367) 中,将内置工具与 MCP 工具合并去重:

```typescript
// claude-code-source/src/tools.ts
export function assembleToolPool(
  permissionContext: ToolPermissionContext,
  mcpTools: Tools,
): Tools {
  const builtInTools = getTools(permissionContext)
  const allowedMcpTools = filterToolsByDenyRules(mcpTools, permissionContext)
  const byName = (a: Tool, b: Tool) => a.name.localeCompare(b.name)
  return uniqBy(
    [...builtInTools].sort(byName).concat(allowedMcpTools.sort(byName)),
    'name',
  )
}
```

组装逻辑要点:

- 内置工具和 MCP 工具分别按名称排序后拼接
- 通过 `uniqBy(..., 'name')` 去重,内置工具优先（`uniqBy` 保留首次出现）
- 内置工具作为连续前缀,MCP 工具排在后面,保证 prompt cache 稳定性
- `assembleToolPool` 的主要调用方包括 REPL 的 React Hook [`useMergedTools.ts`](../../claude-code-source/src/hooks/useMergedTools.ts#L30)、AgentTool 子代理 worker 组装、`resumeAgent.ts` 以及 CLI 模式 `print.ts`

### 4. 工具数量与 ToolSearch 机制

当工具池中工具数量超过阈值时,`ToolSearchTool` 会被启用。该工具允许模型按需搜索和加载工具定义,而非一次性将所有工具的 Schema 注入上下文。这有效减少了 token 消耗,特别是在 MCP 工具数量较多的场景下。判断逻辑通过 [`isToolSearchEnabledOptimistic()`](../../claude-code-source/src/utils/toolSearch.ts) 实现。

## 七、 工具能力维度总结

### 1. 按能力分类

| 能力类别 | 工具 | 说明 |
| - | - | - |
| 文件读取 | Read | 文本/图片/PDF/notebook |
| 文件编辑 | Edit、Write、NotebookEdit | 精确替换/覆盖写入/notebook 单元格 |
| 文件搜索 | Glob、Grep | 文件名匹配/内容搜索 |
| 命令执行 | Bash、PowerShell | Shell/PowerShell 命令 |
| 子代理 | Agent、TaskOutput、TaskStop | 启动/查看输出/停止 |
| 网络访问 | WebFetch、WebSearch、WebBrowser | URL 获取/搜索/浏览器自动化 |
| 用户交互 | AskUserQuestion | 向用户提问 |
| 规划 | EnterPlanMode、ExitPlanMode | 计划模式 |
| 任务管理 | TodoWrite、Task* | 待办/TodoV2 |
| 团队协作 | SendMessage、TeamCreate、TeamDelete | 消息/团队 |
| 定时任务 | CronCreate、CronDelete、CronList | 定时触发 |
| 扩展 | Skill、ToolSearch | 技能加载/工具搜索 |
| MCP | ListMcpResources、ReadMcpResource | MCP 资源 |
| 其他 | Brief、Sleep、Snip 等 | 简报/延迟/裁剪 |

### 2. 工具限制常量

工具结果的大小限制定义在 [`constants/toolLimits.ts`](../../claude-code-source/src/constants/toolLimits.ts) 中,关键常量包括:

- `DEFAULT_MAX_RESULT_SIZE_CHARS`：默认结果最大字符数,值为 50000
- `MAX_TOOL_RESULT_TOKENS`：工具结果最大 token 数,值为 100000

这些限制确保工具输出不会过度占用上下文窗口。

---

*本文档由 markdowncli 技能辅助生成*

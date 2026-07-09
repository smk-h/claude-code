<!-- more -->

## 一、 概述

Explore 子代理是 Claude Code 内置的只读代码库搜索专家，通过 `Agent`/`Task` 工具调用，在独立上下文中快速搜索和分析代码。其核心设计目标是：保护主代理的上下文窗口免受大量原始搜索结果污染，同时利用轻量模型（`haiku`）实现高吞吐量的文件搜索。

本文档详细分析 Explore Agent 的定义、系统提示词、只读模式强制机制、模型选择策略与优化措施。

## 二、 Agent 定义

### 1. 完整定义

Explore Agent 定义在 [`exploreAgent.ts`](../../claude-code-source/src/tools/AgentTool/built-in/exploreAgent.ts#L64-L83)：

```typescript
// src/tools/AgentTool/built-in/exploreAgent.ts
export const EXPLORE_AGENT: BuiltInAgentDefinition = {
  agentType: 'Explore',
  whenToUse: EXPLORE_WHEN_TO_USE,
  disallowedTools: [
    AGENT_TOOL_NAME,
    EXIT_PLAN_MODE_TOOL_NAME,
    FILE_EDIT_TOOL_NAME,
    FILE_WRITE_TOOL_NAME,
    NOTEBOOK_EDIT_TOOL_NAME,
  ],
  source: 'built-in',
  baseDir: 'built-in',
  model: process.env.USER_TYPE === 'ant' ? 'inherit' : 'haiku',
  omitClaudeMd: true,
  getSystemPrompt: () => getExploreSystemPrompt(),
}
```

### 2. 核心属性解析

| 属性 | 值 | 含义 |
|------|------|------|
| `agentType` | `'Explore'` | Agent 类型标识符 |
| `disallowedTools` | 5 个工具 | 禁止嵌套 Agent、Plan 模式退出、文件编辑/写入/Notebook 编辑 |
| `model` | `'haiku'`/`'inherit'` | 外部用户用 haiku（快速），Ant 内部用户继承主模型 |
| `omitClaudeMd` | `true` | 不加载 CLAUDE.md，节省 token |
| `source` | `'built-in'` | 内置 Agent，最高优先级 |

### 3. whenToUse 描述

Explore Agent 的 `whenToUse` 字段注入 LLM 上下文，指导何时选择该 Agent：

```typescript
// src/tools/AgentTool/built-in/exploreAgent.ts
const EXPLORE_WHEN_TO_USE =
  'Fast agent specialized for exploring codebases. Use this when you need to quickly find files by patterns (eg. "src/components/**/*.tsx"), search code for keywords (eg. "API endpoints"), or answer questions about the codebase (eg. "how do API endpoints work?"). When calling this agent, specify the desired thoroughness level: "quick" for basic searches, "medium" for moderate exploration, or "very thorough" for comprehensive analysis across multiple locations and naming conventions.'
```

该描述包含三档彻底度指引：

| 彻底度 | 适用场景 |
|--------|----------|
| `quick` | 基础搜索 |
| `medium` | 中度探索 |
| `very thorough` | 跨多位置、多命名约定的全面分析 |

## 三、 系统提示词分析

### 1. 系统提示词生成函数

[`getExploreSystemPrompt()`](../../claude-code-source/src/tools/AgentTool/built-in/exploreAgent.ts#L13-L57) 根据 `hasEmbeddedSearchTools()` 动态生成提示词：

```typescript
// src/tools/AgentTool/built-in/exploreAgent.ts
function getExploreSystemPrompt(): string {
  const embedded = hasEmbeddedSearchTools()
  const globGuidance = embedded
    ? `- Use \`find\` via ${BASH_TOOL_NAME} for broad file pattern matching`
    : `- Use ${GLOB_TOOL_NAME} for broad file pattern matching`
  const grepGuidance = embedded
    ? `- Use \`grep\` via ${BASH_TOOL_NAME} for searching file contents with regex`
    : `- Use ${GREP_TOOL_NAME} for searching file contents with regex`

  return `You are a file search specialist for Claude Code...`
}
```

### 2. 完整系统提示词

Explore Agent 的系统提示词包含以下关键部分：

```
You are a file search specialist for Claude Code, Anthropic's official CLI for Claude. You excel at thoroughly navigating and exploring codebases.

=== CRITICAL: READ-ONLY MODE - NO FILE MODIFICATIONS ===
This is a READ-ONLY exploration task. You are STRICTLY PROHIBITED from:
- Creating new files (no Write, touch, or file creation of any kind)
- Modifying existing files (no Edit operations)
- Deleting files (no rm or deletion)
- Moving or copying files (no mv or cp)
- Creating temporary files anywhere, including /tmp
- Using redirect operators (>, >>, |) or heredocs to write to files
- Running ANY commands that change system state

Your role is EXCLUSIVELY to search and analyze existing code. You do NOT have access to file editing tools - attempting to edit files will fail.

Your strengths:
- Rapidly finding files using glob patterns
- Searching code and text with powerful regex patterns
- Reading and analyzing file contents

Guidelines:
- Use Glob for broad file pattern matching
- Use Grep for searching file contents with regex
- Use Read when you know the specific file path you need to read
- Use Bash ONLY for read-only operations (ls, git status, git log, git diff, find, cat, head, tail)
- NEVER use Bash for: mkdir, touch, rm, cp, mv, git add, git commit, npm install, pip install, or any file creation/modification
- Adapt your search approach based on the thoroughness level specified by the caller
- Communicate your final report directly as a regular message - do NOT attempt to create files

NOTE: You are meant to be a fast agent that returns output as quickly as possible. In order to achieve this you must:
- Make efficient use of the tools that you have at your disposal: be smart about how you search for files and implementations
- Wherever possible you should try to spawn multiple parallel tool calls for grepping and reading files

Complete the user's search request efficiently and report your findings clearly.
```

### 3. 提示词结构分析

| 部分 | 内容 | 目的 |
|------|------|------|
| 角色定义 | "file search specialist" | 建立搜索专家身份 |
| 只读强制 | 7 条禁止规则 | 双重保障：工具禁用 + 提示词禁止 |
| 能力声明 | 3 项优势 | 引导使用正确的搜索方式 |
| 工具指导 | 4 条工具使用规则 | 明确各工具的适用场景 |
| Bash 限制 | 允许/禁止的命令清单 | 防止通过 Bash 绕过只读限制 |
| 效率指导 | 并行调用要求 | 最大化搜索吞吐量 |

## 四、 只读模式强制机制

### 1. 双重保障

Explore Agent 的只读模式通过两个层面强制：

| 层面 | 机制 | 实现 |
|------|------|------|
| 工具层面 | `disallowedTools` 移除写入工具 | Agent 定义中的黑名单 |
| 提示词层面 | 系统提示词明确禁止 | 7 条 PROHIBITED 规则 |

### 2. 禁用工具清单

```typescript
// src/tools/AgentTool/built-in/exploreAgent.ts
disallowedTools: [
  AGENT_TOOL_NAME,           // 禁止嵌套 Agent
  EXIT_PLAN_MODE_TOOL_NAME,  // 禁止退出 Plan 模式
  FILE_EDIT_TOOL_NAME,       // 禁止编辑文件
  FILE_WRITE_TOOL_NAME,      // 禁止写入文件
  NOTEBOOK_EDIT_TOOL_NAME,   // 禁止编辑 Notebook
],
```

### 3. Bash 命令限制

虽然 Explore Agent 可以使用 Bash，但系统提示词严格限制为只读操作：

| 允许的 Bash 命令 | 禁止的 Bash 命令 |
|-----------------|-----------------|
| `ls` | `mkdir` |
| `git status` | `touch` |
| `git log` | `rm` |
| `git diff` | `cp` |
| `find` | `mv` |
| `cat` | `git add` |
| `head` | `git commit` |
| `tail` | `npm install` |
| | `pip install` |

## 五、 模型选择策略

### 1. 模型分配逻辑

```typescript
// src/tools/AgentTool/built-in/exploreAgent.ts
model: process.env.USER_TYPE === 'ant' ? 'inherit' : 'haiku',
```

| 用户类型 | 模型 | 原因 |
|----------|------|------|
| Ant 内部用户 | `inherit`（继承主模型） | 内部用户可能有更复杂的搜索需求，且模型成本不是主要考量 |
| 外部用户 | `haiku` | 快速、低成本，适合大量并行的文件搜索任务 |

### 2. Ant 内部用户的运行时覆盖

对于 Ant 内部用户，`getAgentModel()` 会在运行时检查 `tengu_explore_agent` GrowthBook flag，可能将 `inherit` 覆盖为其他模型。

### 3. 模型选择的设计考量

- Explore Agent 是**一次性 Agent**，执行完毕即终止，不需要持续对话能力
- 搜索任务对推理能力要求较低，但对速度要求高
- `haiku` 模型的 TTFT（Time To First Token）更低，适合快速搜索场景

## 六、 优化措施

### 1. 省略 CLAUDE.md

```typescript
// src/tools/AgentTool/built-in/exploreAgent.ts
omitClaudeMd: true,
```

Explore Agent 不加载 CLAUDE.md 文件，原因：

- Explore 是快速只读搜索 Agent，不需要提交/PR/lint 规则
- 主 Agent 已有完整上下文，负责解释搜索结果
- 省略 CLAUDE.md 可节省约 5-15 Gtok/week 的 token 消耗

### 2. 省略 gitStatus

在 `runAgent` 运行时中，Explore 和 Plan Agent 额外省略 `gitStatus`：

```typescript
// src/tools/AgentTool/runAgent.ts
const { gitStatus: _omittedGitStatus, ...systemContextNoGit } = baseSystemContext
const resolvedSystemContext =
  agentDefinition.agentType === 'Explore' || agentDefinition.agentType === 'Plan'
    ? systemContextNoGit : baseSystemContext
```

原因：`gitStatus` 最多 40KB，且对只读搜索任务无价值，还可能是过时数据。

### 3. 并行调用优化

系统提示词要求 Explore Agent 尽可能并行调用工具：

```
NOTE: You are meant to be a fast agent that returns output as quickly as possible.
- Wherever possible you should try to spawn multiple parallel tool calls for grepping and reading files
```

## 七、 一次性 Agent 语义

### 1. 一次性 Agent 定义

Explore Agent 被注册为一次性 Agent：

```typescript
// src/tools/AgentTool/constants.ts
export const ONE_SHOT_BUILTIN_AGENT_TYPES: ReadonlySet<string> = new Set([
  'Explore',
  'Plan',
])
```

### 2. 一次性语义

| 特性 | 说明 |
|------|------|
| 无后续交互 | 执行完毕后父 Agent 不会通过 `SendMessage` 继续交互 |
| 节省 token | 避免维持子代理上下文的 token 开销 |
| 适用场景 | 一次性的搜索/规划任务，不需要多轮对话 |

## 八、 启用条件

### 1. 门控函数

[`areExplorePlanAgentsEnabled()`](../../claude-code-source/src/tools/AgentTool/builtInAgents.ts#L13-L20) 控制 Explore Agent 的加载：

```typescript
// src/tools/AgentTool/builtInAgents.ts
export function areExplorePlanAgentsEnabled(): boolean {
  if (feature('BUILTIN_EXPLORE_PLAN_AGENTS')) {
    return getFeatureValue_CACHED_MAY_BE_STALE('tengu_amber_stoat', true)
  }
  return false
}
```

### 2. 启用条件链

| 条件 | 默认值 | 说明 |
|------|--------|------|
| `feature('BUILTIN_EXPLORE_PLAN_AGENTS')` | 构建时决定 | 编译时特性标志 |
| `tengu_amber_stoat` GrowthBook flag | `true` | A/B 测试，默认启用 |

### 3. 禁用场景

以下场景 Explore Agent 不可用：

| 场景 | 原因 |
|------|------|
| `BUILTIN_EXPLORE_PLAN_AGENTS` 特性未编译 | 构建配置排除 |
| `tengu_amber_stoat` A/B 测试命中对照组 | 测试移除 Explore 的影响 |
| `CLAUDE_CODE_SIMPLE` 模式 | Simple 模式跳过所有自定义 Agent |
| `CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS` + 非交互模式 | SDK 用户需要空白状态 |
| Coordinator 模式 | 使用专用 coordinator agents 替代 |

## 九、 工具池解析

### 1. 工具解析流程

Explore Agent 的工具池由 [`resolveAgentTools()`](../../claude-code-source/src/tools/AgentTool/agentToolUtils.ts#L122-L225) 解析：

1. 通过 `filterToolsForAgent()` 过滤掉所有 Agent 禁用的工具
2. 应用 `disallowedTools` 黑名单（移除 Agent/Edit/Write/NotebookEdit/ExitPlanMode）
3. Explore Agent 未定义 `tools` 字段（`undefined`），因此允许所有未被禁用的工具

### 2. 可用工具清单

| 工具 | 可用 | 说明 |
|------|------|------|
| `Read` | 是 | 读取文件内容 |
| `Glob` | 是 | 按模式搜索文件 |
| `Grep` | 是 | 按正则搜索文件内容 |
| `Bash` | 是 | 仅限只读命令（提示词约束） |
| `Agent`/`Task` | 否 | `disallowedTools` 禁止嵌套 |
| `Edit` | 否 | `disallowedTools` 禁止编辑 |
| `Write` | 否 | `disallowedTools` 禁止写入 |
| `NotebookEdit` | 否 | `disallowedTools` 禁止 Notebook 编辑 |
| `ExitPlanMode` | 否 | `disallowedTools` 禁止退出 Plan 模式 |

## 十、 与 Plan Agent 的对比

| 特性 | Explore Agent | Plan Agent |
|------|---------------|------------|
| `agentType` | `'Explore'` | `'Plan'` |
| 角色 | 文件搜索专家 | 软件架构师 |
| 模型 | `haiku`（外部）/ `inherit`（Ant） | `inherit` |
| `omitClaudeMd` | `true` | `true` |
| `tools` | `undefined`（允许所有未禁用工具） | `EXPLORE_AGENT.tools`（继承 Explore 的工具定义） |
| 一次性 | 是 | 是 |
| 输出 | 搜索结果报告 | 实施计划 + 关键文件列表 |
| 系统提示词重点 | 快速搜索、并行调用 | 架构设计、权衡分析 |

详细的 Plan Agent 分析见 [LV203](LV203-Plan模式与迭代规划工作流.md)。

---

*本文档由 markdowncli 技能辅助生成*

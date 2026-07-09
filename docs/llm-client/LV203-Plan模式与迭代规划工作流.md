<!-- more -->

## 一、 概述

Plan 模式是 Claude Code 中用户指示 AI 进入只读规划状态的工作模式。在 Plan 模式下，AI 探索代码库、逐步撰写计划文件，但不允许修改系统。Plan 模式通过迭代式的"探索 → 更新计划 → 询问用户"循环，将模糊的需求转化为清晰可执行的实施计划。

本文档详细分析 Plan Agent 定义、Plan 模式系统提示词、迭代规划工作流、ExitPlanMode 工具以及计划文件结构要求。

## 二、 Plan Agent 定义

### 1. 完整定义

Plan Agent 定义在 [`planAgent.ts`](../../claude-code-source/src/tools/AgentTool/built-in/planAgent.ts#L73-L92)：

```typescript
// src/tools/AgentTool/built-in/planAgent.ts
export const PLAN_AGENT: BuiltInAgentDefinition = {
  agentType: 'Plan',
  whenToUse:
    'Software architect agent for designing implementation plans. Use this when you need to plan the implementation strategy for a task. Returns step-by-step plans, identifies critical files, and considers architectural trade-offs.',
  disallowedTools: [
    AGENT_TOOL_NAME,
    EXIT_PLAN_MODE_TOOL_NAME,
    FILE_EDIT_TOOL_NAME,
    FILE_WRITE_TOOL_NAME,
    NOTEBOOK_EDIT_TOOL_NAME,
  ],
  source: 'built-in',
  tools: EXPLORE_AGENT.tools,
  baseDir: 'built-in',
  model: 'inherit',
  omitClaudeMd: true,
  getSystemPrompt: () => getPlanV2SystemPrompt(),
}
```

### 2. 核心属性解析

| 属性 | 值 | 含义 |
|------|------|------|
| `agentType` | `'Plan'` | Agent 类型标识符 |
| `model` | `'inherit'` | 继承主模型，因规划需要更强的推理能力 |
| `tools` | `EXPLORE_AGENT.tools` | 继承 Explore Agent 的工具定义 |
| `omitClaudeMd` | `true` | 不加载 CLAUDE.md，节省 token |
| `disallowedTools` | 与 Explore 相同 | 只读模式，禁止文件修改 |

### 3. 与 Explore Agent 的关键差异

| 特性 | Explore Agent | Plan Agent |
|------|---------------|------------|
| 模型 | `haiku`（外部用户） | `inherit`（继承主模型） |
| 角色 | 文件搜索专家 | 软件架构师 |
| 输出 | 搜索结果报告 | 实施计划 + 关键文件列表 |
| 系统提示词重点 | 快速搜索、并行调用 | 架构设计、权衡分析 |

Plan Agent 使用 `inherit` 模型而非 `haiku`，因为规划任务需要更强的推理和架构分析能力。

## 三、 Plan Agent 系统提示词

### 1. 系统提示词生成函数

[`getPlanV2SystemPrompt()`](../../claude-code-source/src/tools/AgentTool/built-in/planAgent.ts#L14-L71) 动态生成提示词：

```typescript
// src/tools/AgentTool/built-in/planAgent.ts
function getPlanV2SystemPrompt(): string {
  const searchToolsHint = hasEmbeddedSearchTools()
    ? `\`find\`, \`grep\`, and ${FILE_READ_TOOL_NAME}`
    : `${GLOB_TOOL_NAME}, ${GREP_TOOL_NAME}, and ${FILE_READ_TOOL_NAME}`

  return `You are a software architect and planning specialist for Claude Code...`
}
```

### 2. 完整系统提示词

Plan Agent 的系统提示词包含以下关键部分：

```
You are a software architect and planning specialist for Claude Code. Your role is to explore the codebase and design implementation plans.

=== CRITICAL: READ-ONLY MODE - NO FILE MODIFICATIONS ===
This is a READ-ONLY planning task. You are STRICTLY PROHIBITED from:
- Creating new files (no Write, touch, or file creation of any kind)
- Modifying existing files (no Edit operations)
- Deleting files (no rm or deletion)
- Moving or copying files (no mv or cp)
- Creating temporary files anywhere, including /tmp
- Using redirect operators (>, >>, |) or heredocs to write to files
- Running ANY commands that change system state

Your role is EXCLUSIVELY to explore the codebase and design implementation plans. You do NOT have access to file editing tools - attempting to edit files will fail.

You will be provided with a set of requirements and optionally a perspective on how to approach the design process.

## Your Process

1. **Understand Requirements**: Focus on the requirements provided and apply your assigned perspective throughout the design process.

2. **Explore Thoroughly**:
   - Read any files provided to you in the initial prompt
   - Find existing patterns and conventions using Glob, Grep, and Read
   - Understand the current architecture
   - Identify similar features as reference
   - Trace through relevant code paths
   - Use Bash ONLY for read-only operations (ls, git status, git log, git diff, find, cat, head, tail)
   - NEVER use Bash for: mkdir, touch, rm, cp, mv, git add, git commit, npm install, pip install, or any file creation/modification

3. **Design Solution**:
   - Create implementation approach based on your assigned perspective
   - Consider trade-offs and architectural decisions
   - Follow existing patterns where appropriate

4. **Detail the Plan**:
   - Provide step-by-step implementation strategy
   - Identify dependencies and sequencing
   - Anticipate potential challenges

## Required Output

End your response with:

### Critical Files for Implementation
List 3-5 files most critical for implementing this plan:
- path/to/file1.ts
- path/to/file2.ts
- path/to/file3.ts

REMEMBER: You can ONLY explore and plan. You CANNOT and MUST NOT write, edit, or modify any files. You do NOT have access to file editing tools.
```

### 3. 规划流程四步法

Plan Agent 的系统提示词定义了四步规划流程：

| 步骤 | 名称 | 核心动作 |
|------|------|----------|
| 1 | 理解需求 | 聚焦需求，应用设计视角 |
| 2 | 深入探索 | 读取文件、查找模式、理解架构、识别参考、追踪代码路径 |
| 3 | 设计方案 | 创建实施方法、考虑权衡、遵循现有模式 |
| 4 | 详细计划 | 提供分步策略、识别依赖、预判挑战 |

### 4. 强制输出格式

Plan Agent 的输出必须以"关键文件"列表结尾：

```
### Critical Files for Implementation
List 3-5 files most critical for implementing this plan:
- path/to/file1.ts
- path/to/file2.ts
- path/to/file3.ts
```

## 四、 Plan 模式系统提示词

### 1. Plan 模式与 Plan Agent 的区别

| 概念 | 触发方式 | 运行方式 |
|------|----------|----------|
| Plan Agent | 主代理调用 `Task` 工具，`subagent_type=Plan` | 子代理独立运行，返回计划 |
| Plan 模式 | 用户通过 UI 启用 Plan 模式 | 主代理在只读约束下迭代规划 |

### 2. Plan 模式系统提示词

Plan 模式激活时，[`getPlanModeV2Instructions()`](../../claude-code-source/src/utils/messages.ts#L3330-L3383) 注入系统提示词：

```
Plan mode is active. The user indicated that they do not want you to execute yet -- you MUST NOT make any edits (with the exception of the plan file mentioned below), run any non-readonly tools (including changing configs or making commits), or otherwise make any changes to the system. This supercedes any other instructions you have received.

## Plan File Info:
{planFileInfo}

## Iterative Planning Workflow

You are pair-planning with the user. Explore the code to build context, ask the user questions when you hit decisions you can't make alone, and write your findings into the plan file as you go. The plan file (above) is the ONLY file you may edit — it starts as a rough skeleton and gradually becomes the final plan.

### The Loop

Repeat this cycle until the plan is complete:

1. **Explore** — Use Read, Glob, Grep to read code. Look for existing functions, utilities, and patterns to reuse. You can use the Explore agent type to parallelize complex searches without filling your context, though for straightforward queries direct tools are simpler.
2. **Update the plan file** — After each discovery, immediately capture what you learned. Don't wait until the end.
3. **Ask the user** — When you hit an ambiguity or decision you can't resolve from code alone, use AskUserQuestion. Then go back to step 1.

### First Turn

Start by quickly scanning a few key files to form an initial understanding of the task scope. Then write a skeleton plan (headers and rough notes) and ask the user your first round of questions. Don't explore exhaustively before engaging the user.
```

### 3. 只读约束

Plan 模式的只读约束优先级最高：

```
This supercedes any other instructions you have received.
```

唯一例外是计划文件本身 — AI 可以编辑计划文件来记录探索发现。

## 五、 迭代规划工作流

### 1. 核心循环

Plan 模式采用三步迭代循环：

```
┌─────────────────────────────────────────┐
│            迭代规划循环                   │
│                                         │
│  ┌─────────┐    ┌─────────┐    ┌──────┐ │
│  │ Explore │───▶│ Update  │───▶│ Ask  │ │
│  │ 探索代码 │    │ 计划文件 │    │ 用户 │ │
│  └─────────┘    └─────────┘    └──────┘ │
│        ▲                         │      │
│        └─────────────────────────┘      │
│              回到探索                     │
└─────────────────────────────────────────┘
```

### 2. 第一步：探索

| 工具 | 用途 |
|------|------|
| `Read`、`Glob`、`Grep` | 直接读取代码 |
| `Explore` 子代理 | 并行化复杂搜索，避免填充主上下文 |

探索的目标：
- 查找可复用的现有函数、工具和模式
- 理解当前架构
- 识别相似功能作为参考
- 追踪相关代码路径

### 3. 第二步：更新计划文件

每次发现后立即记录，而非等到最后：

```
After each discovery, immediately capture what you learned. Don't wait until the end.
```

### 4. 第三步：询问用户

当遇到代码无法解决的歧义或决策时，使用 `AskUserQuestion`：

```
When you hit an ambiguity or decision you can't resolve from code alone, use AskUserQuestion. Then go back to step 1.
```

### 5. 首轮行为

首轮不进行穷尽探索，而是快速扫描后撰写骨架计划并提问：

```
Start by quickly scanning a few key files to form an initial understanding of the task scope. Then write a skeleton plan (headers and rough notes) and ask the user your first round of questions. Don't explore exhaustively before engaging the user.
```

## 六、 提问质量指导

### 1. 提问原则

Plan 模式系统提示词对提问质量有明确指导：

| 原则 | 说明 |
|------|------|
| 不问代码能回答的问题 | `Never ask what you could find out by reading the code` |
| 批量提问 | 将相关问题合并为一次 `AskUserQuestion` 多问题调用 |
| 聚焦用户独有的知识 | 需求、偏好、权衡、边缘案例优先级 |
| 深度匹配任务 | 模糊功能需求需多轮，聚焦 bug 修复可能一轮甚至无需提问 |

### 2. 回合结束条件

Plan 模式中，AI 的回合只能以两种方式结束：

| 结束方式 | 工具 | 场景 |
|----------|------|------|
| 询问用户 | `AskUserQuestion` | 需要更多信息 |
| 请求审批 | `ExitPlanMode` | 计划已完成 |

**禁止**通过文本或 `AskUserQuestion` 询问"计划是否 OK"— 这正是 `ExitPlanMode` 的职责。

## 七、 计划文件结构

### 1. 必需章节

Plan 模式系统提示词要求计划文件包含以下章节：

| 章节 | 内容 |
|------|------|
| **Context** | 解释变更原因 — 解决的问题、触发因素、预期结果 |
| 推荐方案 | 仅包含推荐方案，不列出所有替代方案 |
| 关键文件路径 | 需要修改的文件路径 |
| 复用引用 | 发现的可复用现有函数和工具，附文件路径 |
| 验证方案 | 如何端到端测试变更（运行代码、MCP 工具、测试） |

### 2. 结构要求

- 简洁到可以快速扫描
- 详细到可以有效执行
- 使用 Markdown 标题分节

## 八、 ExitPlanMode 工具

### 1. 工具提示词

ExitPlanMode 工具的提示词定义在 [`prompt.ts`](../../claude-code-source/src/tools/ExitPlanModeTool/prompt.ts#L6-L29)：

```typescript
// src/tools/ExitPlanModeTool/prompt.ts
export const EXIT_PLAN_MODE_V2_TOOL_PROMPT = `Use this tool when you are in plan mode and have finished writing your plan to the plan file and are ready for user approval.

## How This Tool Works
- You should have already written your plan to the plan file specified in the plan mode system message
- This tool does NOT take the plan content as a parameter - it will read the plan from the file you wrote
- This tool simply signals that you're done planning and ready for the user to review and approve
- The user will see the contents of your plan file when they review it

## When to Use This Tool
IMPORTANT: Only use this tool when the task requires planning the implementation steps of a task that requires writing code. For research tasks where you're gathering information, searching files, reading files or in general trying to understand the codebase - do NOT use this tool.

## Before Using This Tool
Ensure that your plan is complete and unambiguous:
- If you have unresolved questions about requirements or approach, use AskUserQuestion first (in earlier phases)
- Once your plan is finalized, use THIS tool to request approval

**Important:** Do NOT use AskUserQuestion to ask "Is this plan okay?" or "Should I proceed?" - that's exactly what THIS tool does. ExitPlanMode inherently requests user approval of your plan.`
```

### 2. 使用条件

| 条件 | 说明 |
|------|------|
| 已在 Plan 模式中 | 工具仅在 Plan 模式可用 |
| 计划已写入计划文件 | 工具不接收计划内容参数，从文件读取 |
| 任务需要编码实现 | 研究任务不应使用此工具 |
| 计划完整且无歧义 | 有未解决问题时先用 `AskUserQuestion` |

### 3. 使用示例

ExitPlanMode 提示词提供了三个判断示例：

| 示例任务 | 是否使用 ExitPlanMode | 原因 |
|----------|----------------------|------|
| "搜索并理解 vim 模式的实现" | 否 | 纯研究任务，不涉及实现规划 |
| "帮我实现 vim 的 yank 模式" | 是 | 需要规划实现步骤 |
| "添加用户认证功能" | 视情况 | 不确定认证方式时先用 `AskUserQuestion`，明确后再用 |

## 九、 只读工具集

### 1. getReadOnlyToolNames()

[`getReadOnlyToolNames()`](../../claude-code-source/src/utils/messages.ts#L3299-L3314) 返回 Plan 模式中可用的只读工具：

```typescript
// src/utils/messages.ts
function getReadOnlyToolNames(): string {
  const tools = hasEmbeddedSearchTools()
    ? [FILE_READ_TOOL_NAME, '`find`', '`grep`']
    : [FILE_READ_TOOL_NAME, GLOB_TOOL_NAME, GREP_TOOL_NAME]
  const { allowedTools } = getCurrentProjectConfig()
  const filtered =
    allowedTools && allowedTools.length > 0 && !hasEmbeddedSearchTools()
      ? tools.filter(t => allowedTools.includes(t))
      : tools
  return filtered.join(', ')
}
```

### 2. 工具集变化

| 构建类型 | 工具集 | 说明 |
|----------|--------|------|
| 标准构建 | `Read`、`Glob`、`Grep` | 三个专用只读工具 |
| 嵌入式构建 | `Read`、`find`、`grep` | `find`/`grep` 通过 Bash 调用 |
| 配置了 allowedTools | 过滤后的子集 | 仅保留 allowedTools 中包含的工具 |

## 十、 Plan 模式 vs Plan Agent

### 1. 使用场景对比

| 特性 | Plan 模式 | Plan Agent |
|------|-----------|------------|
| 触发者 | 用户通过 UI 启用 | 主代理调用 `Task` 工具 |
| 运行上下文 | 主代理上下文 | 独立子代理上下文 |
| 计划文件 | 可编辑计划文件 | 不可编辑任何文件 |
| 用户交互 | 可通过 `AskUserQuestion` 交互 | 一次性执行，无交互 |
| 迭代探索 | 支持（探索 → 更新 → 询问循环） | 不支持（单次执行） |
| 输出 | 计划文件 + `ExitPlanMode` 审批 | 文本报告 + 关键文件列表 |

### 2. Plan 模式的优势

- 与用户协作规划，可逐步澄清需求
- 计划文件可持久化保存
- 支持 `ExitPlanMode` 正式审批流程
- 可在探索中途询问用户

### 3. Plan Agent 的优势

- 独立上下文，不污染主代理
- 可并行化（多个 Plan Agent 同时规划不同方面）
- 适合明确的规划任务，无需用户交互

## 十一、 与探索决策系统的关系

Plan 模式和 Plan Agent 都是探索决策系统的组成部分：

| 组件 | 在决策系统中的角色 | 详细文档 |
|------|-------------------|----------|
| Plan 模式 | 用户提供规划约束，AI 在约束下迭代探索 | 本文档 |
| Plan Agent | 主代理委派的架构规划子代理 | 本文档 |
| Explore Agent | Plan 模式/Plan Agent 可调用的搜索子代理 | [LV202](LV202-Explore子代理行为详解.md) |
| 探索决策分层 | 指导何时使用直接搜索 vs 子代理 | [LV201](LV201-探索决策分层机制.md) |

在 Plan 模式中，系统提示词明确推荐使用 Explore 子代理来并行化复杂搜索：

```
You can use the Explore agent type to parallelize complex searches without filling your context, though for straightforward queries direct tools are simpler.
```

---

*本文档由 markdowncli 技能辅助生成*

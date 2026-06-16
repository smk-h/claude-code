<!-- more -->

## 一、 概述

本文档分析 Claude Code 中 Skills 内容在 LLM 上下文中的角色——它是否属于系统提示词，还是其他形式的消息，以及不同类型的 skill 内容在对话中的具体位置。

## 二、 Skills 不属于系统提示词

### 1. 系统提示词的构成

[`getSystemPrompt()`](../../claude-code-source/src/constants/prompts.ts#L444-L577) 构建系统提示词，其中 skill 相关的内容仅为**一条使用指引**，而非 skill 内容本身：

```typescript
// src/constants/prompts.ts#L382-L384
hasSkills
  ? `/<skill-name> (e.g., /commit) is shorthand for users to invoke a user-invocable skill.
     When executed, the skill gets expanded to a full prompt. Use the ${SKILL_TOOL_NAME} tool
     to execute them.`
  : null
```

系统提示词中**不包含**任何 skill 的具体内容或列表。

### 2. Skill 列表的位置

Skill 列表通过 `skill_listing` attachment 注入，最终渲染为 `<system-reminder>` 包裹的**用户消息**：

```typescript
// src/utils/messages.ts#L3728-L3738
case 'skill_listing': {
  return wrapMessagesInSystemReminder([
    createUserMessage({
      content: `The following skills are available for use with the Skill tool:\n\n${attachment.content}`,
      isMeta: true,
    }),
  ])
}
```

关键特征：

- 消息类型：**user message**（`isMeta: true`）
- 包裹层：`<system-reminder>` 标签
- 位置：**用户消息流中**，不是系统提示词

### 3. Skill 完整内容的位置

Skill 被调用后，其完整 Markdown 正文同样作为**用户消息**注入：

```typescript
// src/skills/loadSkillsDir.ts#L344-L346
let finalContent = baseDir
  ? `Base directory for this skill: ${baseDir}\n\n${markdownContent}`
  : markdownContent
```

通过 [`processPromptSlashCommand()`](../../claude-code-source/src/utils/processUserInput/processSlashCommand.tsx#L815) → [`getMessagesForPromptSlashCommand()`](../../claude-code-source/src/utils/processUserInput/processSlashCommand.tsx#L825) → [`createUserMessage()`](../../claude-code-source/src/utils/messages.ts#L458)({ isMeta: true }) 注入。

## 三、 消息类型对比

| 内容 | 消息角色 | 标记 | 是否在系统提示词中 |
| --- | --- | --- | --- |
| Skill 使用指引 | system prompt | 无 | 是（仅一行说明） |
| Skill 列表 | user message | `<system-reminder>` + `isMeta: true` | 否 |
| Skill 完整正文 | user message | `isMeta: true` + `sourceToolUseID` | 否 |
| Skill 调用结果（fork） | tool_result | 无 | 否 |

## 四、 `isMeta` 标记的作用

`isMeta: true` 的用户消息在 UI 中会被隐藏，但对模型可见。它标记该消息由系统生成而非用户输入：

```typescript
// src/utils/messages.ts
createUserMessage({ content: finalContent, isMeta: true })
```

## 五、 Compaction 对 Skill 内容的处理

Skill 内容在 compaction（上下文压缩）时受到特殊保护：

### 1. 调用记录

[`addInvokedSkill()`](../../claude-code-source/src/bootstrap/state.ts#L1508) 在 skill 被调用时记录其内容：

```typescript
// src/utils/processUserInput/processSlashCommand.tsx#L883-L885
const skillContent = result.filter((b): b is TextBlockParam => b.type === 'text')
  .map(b => b.text).join('\n\n')
addInvokedSkill(command.name, skillPath, skillContent, getAgentContext()?.agentId ?? null)
```

### 2. 压缩后恢复

压缩后，skill 的 `skill_listing` 和 `skill_discovery` attachment 会被重新注入（通过 [`resetSentSkillNames()`](../../claude-code-source/src/utils/attachments.ts#L2610)），确保模型仍然知道可用的 skills。

```typescript
// src/services/compact/compact.ts#L194-L196
// skill_discovery/skill_listing are re-surfaced by resetSentSkillNames()
```

## 六、 Attachment 在消息流中的注入时机

[`getAttachments()`](../../claude-code-source/src/utils/attachments.ts) 在每轮对话的用户消息处理时被调用，skills 相关的 attachment 注入时机：

| Attachment 类型 | 注入时机 | 条件 |
| --- | --- | --- |
| `skill_listing` | 每轮 | 有 SkillTool 且有未发送的 skills |
| `skill_discovery` | 首轮 + 轮间 | `EXPERIMENTAL_SKILL_SEARCH` feature 启用 |
| `dynamic_skill` | 每轮 | 有动态发现的 skills 目录 |
| `skill_listing` 中的 MCP skills | 每轮 | 有 MCP skill commands |

## 七、 SkillTool 在工具池中的位置

SkillTool 与其他工具一样注册在工具池中，但有其特殊性：

```typescript
// src/tools/SkillTool/SkillTool.ts#L331
export const SkillTool: Tool<InputSchema, Output, Progress> = buildTool({
  name: SKILL_TOOL_NAME,
  searchHint: 'invoke a slash-command skill',
  // ...
  prompt: async () => getPrompt(getProjectRoot()),
  // ...
})
```

其 `prompt` 字段返回 SkillTool 自身的描述提示词（如何使用该工具），而非 skill 内容。

## 八、 总结

| 问题 | 答案 |
| --- | --- |
| Skill 列表是否是系统提示词？ | 否，是 `<system-reminder>` 包裹的用户消息 |
| Skill 正文是否是系统提示词？ | 否，是 `isMeta: true` 的用户消息 |
| 系统提示词中有什么 skill 相关内容？ | 仅一条使用 SkillTool 的简要指引 |
| Skill 内容在消息流中的位置 | 用户消息流中，与工具调用结果交替出现 |
| Compaction 是否影响 skills？ | Skill 列表会在压缩后重新注入；已调用的 skill 内容受 `addInvokedSkill` 保护 |

## 九、 实例分析：markdowncli skill 在上下文中的实际消息

以 `~/.claude/skills/markdowncli/SKILL.md` 为例，展示该 skill 的两种内容在对话流中的实际形态。

### 1. Skill 列表消息（发现阶段）

首次对话时，`markdowncli` 作为 skill 列表的一部分，以如下格式注入：

```xml
<system-reminder>
  <user-message>
    The following skills are available for use with the Skill tool:

    - markdowncli: 按照指定的格式规范创建和修改Markdown文档
    - c-lang-spec: C 语言编程规范的代码检查与格式化指导
    - ts-lang-spec: TypeScript 语言编程规范的代码检查与格式化指导
    - makefile-spec: Makefile 编写规范的代码检查、格式化与编写指导
  </user-message>
</system-reminder>
```

消息属性：

| 属性 | 值 |
| --- | --- |
| 消息角色 | `user` |
| `isMeta` | `true` |
| 包裹标签 | `<system-reminder>` |
| 在系统提示词中 | 否 |

### 2. Skill 完整正文消息（调用阶段）

当模型通过 SkillTool 调用 `markdowncli` 后，注入的消息为：

```xml
<user-message sourceToolUseID="toolu_xxx">
  Base directory for this skill: /root/.claude/skills/markdowncli

  # Skill: Markdown文档格式规范

  ## 技能说明

  本技能定义了一套统一的 Markdown 文档格式规范，涵盖**标题编号**、**列表样式**、**中英排版**及**文档结构**。当用户要求**创建新文档**或**修改已有文档**时，AI 必须严格遵循以下规则。

  ## 何时触发

  当用户提出以下类型请求时自动激活：
  ...（共 279 行正文）
</user-message>
```

消息属性：

| 属性 | 值 |
| --- | --- |
| 消息角色 | `user` |
| `isMeta` | `true` |
| `sourceToolUseID` | SkillTool 的 tool use ID |
| 在系统提示词中 | 否 |

### 3. 与系统提示词的对比

系统提示词中关于 skill 的部分仅为一条指引（在 `hasSkills = true` 时）：

```
/<skill-name> (e.g., /commit) is shorthand for users to invoke a user-invocable skill. 
When executed, the skill gets expanded to a full prompt. Use the Skill tool to execute them. 
IMPORTANT: Only use Skill for skills listed in its user-invocable skills section - do not 
guess or use built-in CLI commands.
```

而 `markdowncli` 的**列表项**和**完整正文**都不在系统提示词中，它们通过 attachment 机制注入到用户消息流。

### 4. 消息流时序

以本次对话为例，`markdowncli` 相关消息的出现时序：

```
[system prompt]          ← 包含 "use Skill tool" 指引
[user message]            ← 用户输入
[system-reminder]        ← skill 列表（含 - markdowncli: ...）
[assistant message]      ← 模型决定调用 SkillTool
[tool_use]                ← SkillTool(name="markdowncli", args="...")
[user message isMeta]     ← markdowncli 完整正文注入
[assistant message]      ← 模型遵循 skill 规范生成回复
```

### 5. Compaction 后的恢复

如果上下文压缩发生，`markdowncli` 的 skill 列表会通过 [`resetSentSkillNames()`](../../claude-code-source/src/utils/attachments.ts#L2610) 重新注入，确保模型仍知道该 skill 可用。已调用的 skill 正文由 [`addInvokedSkill()`](../../claude-code-source/src/bootstrap/state.ts#L1508) 记录，受 compaction 保护。

---

*本文档由 markdowncli 技能辅助生成*

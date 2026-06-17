<!-- more -->

## 一、 概述

本文档分析 Claude Code 中 Skills 的加载策略——是全部一次性加载还是按需加载，以及 skill 内容注入上下文的时机和方式。

## 二、 两阶段加载架构

Skills 的加载分为**发现阶段**和**调用阶段**，两个阶段加载的内容不同：

| 阶段 | 时机 | 加载内容 | 数据来源 |
| --- | --- | --- | --- |
| 发现阶段 | 会话启动/每轮开始 | frontmatter 元数据（name、description、whenToUse） | SKILL.md 文件 |
| 调用阶段 | 模型调用 SkillTool 时 | 完整 Markdown 正文 | SKILL.md 文件 |

### 1. 发现阶段：仅加载元数据

会话启动时，[`getSkillDirCommands()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L638-L804) 扫描所有 skill 目录并读取每个 `SKILL.md` 文件，但**注入上下文的仅是 frontmatter 摘要信息**，而非完整内容。

估算 frontmatter 的 token 开销：

```typescript
// src/skills/loadSkillsDir.ts#L100-L105
export function estimateSkillFrontmatterTokens(skill: Command): number {
  const frontmatterText = [skill.name, skill.description, skill.whenToUse]
    .filter(Boolean)
    .join(' ')
  return roughTokenCountEstimation(frontmatterText)
}
```

可见仅计算 `name` + `description` + `whenToUse` 的 token 数，不涉及正文内容。

#### 1.1 `whenToUse` 的来源：frontmatter 的 `when_to_use` 字段

Skill 的 `whenToUse` 来自 [`parseSkillFrontmatter()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L252) 解析 SKILL.md frontmatter 中的 `when_to_use` 字段，与 `description` 是**独立的两个字段**：

```typescript
// src/skills/loadSkillsDir.ts#L252
whenToUse: frontmatter.when_to_use as string | undefined,
```

- `description`：技能的简短描述（**必须字段**，有降级策略——缺省时自动生成通用描述）
- `when_to_use`：详细的使用时机提示（**可选字段**，默认 `undefined`）

**与子 Agent 的关键区别**：子 Agent 的 `whenToUse` 映射自 `description` 字段（`whenToUse = frontmatter['description']`），而 Skill 的 `whenToUse` 是独立的 `when_to_use` 字段。

> **实际现状**：大多数内置 Skill（bundled skill）通过代码注册（`registerBundledSkill()`），没有设置 `whenToUse`；用户自建的 SKILL.md 也常省略 `when_to_use`。因此**大多数 Skill 的发现阶段只展示 `description`**，LLM 的调度决策仅凭这一句话。

#### 1.2 发现阶段 LLM 看到的内容

[`getCommandDescription()`](../../claude-code-source/src/tools/SkillTool/prompt.ts#L43-L50) 根据 `whenToUse` 是否存在拼接列表项：

```typescript
// src/tools/SkillTool/prompt.ts#L43-L50
function getCommandDescription(cmd: Command): string {
  const desc = cmd.whenToUse
    ? `${cmd.description} - ${cmd.whenToUse}`  // ← 两个字段都展示
    : cmd.description                            // ← 无 whenToUse 时仅展示 description
  return desc.length > MAX_LISTING_DESC_CHARS
    ? desc.slice(0, MAX_LISTING_DESC_CHARS - 1) + '\u2026'
    : desc
}
```

**两种情况**：

| `when_to_use` 状态 | 列表格式 | 示例 |
|:---:|:---:|:---|
| **未定义**（大多数 Skill） | `- name: description` | `- markdowncli: 按照指定的格式规范创建和修改Markdown文档` |
| **已定义** | `- name: description - whenToUse` | `- markdowncli: 按照指定的格式规范创建和修改Markdown文档 - 当用户需要创建或修改Markdown文档时自动激活` |

受 `MAX_LISTING_DESC_CHARS = 250` 字符/条限制。

**重要**：正文中写的"何时触发"、"触发时机"等章节，在发现阶段**不可见**。LLM 的调度决策仅基于 frontmatter 中实际存在的字段——大多数情况下**只有 `description`**。

### 2. 调用阶段：按需加载完整内容

当模型通过 SkillTool 调用某个 skill 时，才会执行 [`getPromptForCommand()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L344-L398) 获取完整的 Markdown 正文：

```typescript
// src/skills/loadSkillsDir.ts#L344-L398
async getPromptForCommand(args, toolUseContext) {
  let finalContent = baseDir
    ? `Base directory for this skill: ${baseDir}\n\n${markdownContent}`
    : markdownContent
  // ... 参数替换、变量替换、shell 命令执行
  return [{ type: 'text', text: finalContent }]
}
```

#### 2.1 正文中"触发时机"的可见性

**调用后，正文中写的"何时触发"、"触发时机"等章节对主会话 LLM 完全可见**——完整正文作为 `isMeta: true` 的用户消息注入主会话的 `messages` 数组。

但这有一个关键前提：**LLM 必须先在发现阶段决定调用该 Skill**，才能看到正文。如果 `description` 和 `when_to_use` 写得不够精准，LLM 根本不会调用该 Skill，正文中再详细的触发时机也无济于事。

> **核心结论**：对于"LLM 是否选择调用该 Skill"这个决策来说，正文中的"何时触发"没有意义。调度依据**只有 frontmatter 的两个字段**——`description`（必须）和 `when_to_use`（可选）。正文中写触发时机的唯一潜在作用是：Skill 被调用过一次后，完整正文注入主会话，LLM 在**同一对话的后续轮次**中可能据此判断是否再次调用——但这属于副作用，不可靠，且前提是 LLM 已经选过一次。**如果想让 LLM 在发现阶段准确选中你的 Skill，触发信息必须写在 `description` 或 `when_to_use` 里。**

两阶段可见性总结：

| 内容 | 发现阶段可见 | 调用后可见 | 对调度决策的影响 |
|------|:----------:|:--------:|:-------------:|
| `name`（frontmatter） | ✅ | ✅ | 间接（匹配调用名称） |
| `description`（frontmatter，必须） | ✅ | ✅ | **直接**（核心决策依据） |
| `when_to_use`（frontmatter，可选） | ✅（定义时） | ✅ | 直接（补充决策依据，但大多数 Skill 未定义） |
| 正文中的"何时触发"章节 | ❌ | ✅ | 间接（仅影响后续调用意愿） |
| 正文中的行为指令 | ❌ | ✅ | 无（影响执行质量，不影响调度） |

## 三、 Skill 列表的注入方式

Skill 列表通过 **attachment** 机制注入，而非系统提示词。具体流程：

### 1. 生成 skill_listing Attachment

[`getSkillListingAttachments()`](../../claude-code/claude-code-source/src/utils/attachments.ts#L2661-L2751) 在每轮对话时执行：

```typescript
// src/utils/attachments.ts#L2661-L2751
async function getSkillListingAttachments(toolUseContext: ToolUseContext): Promise<Attachment[]> {
  const localCommands = await getSkillToolCommands(cwd)
  const mcpSkills = getMcpSkillCommands(toolUseContext.getAppState().mcp.commands)
  let allCommands = mcpSkills.length > 0
    ? uniqBy([...localCommands, ...mcpSkills], 'name')
    : localCommands

  // 找到尚未发送过的 skills
  const newSkills = allCommands.filter(cmd => !sent.has(cmd.name))
  if (newSkills.length === 0) return []

  // 在预算内格式化
  const content = formatCommandsWithinBudget(newSkills, contextWindowTokens)
  return [{ type: 'skill_listing', content, skillCount: newSkills.length, isInitial }]
}
```

### 2. 增量注入机制

系统维护 `sentSkillNames` Map，追踪每个 Agent 已发送的 skill 名称：

```typescript
// src/utils/attachments.ts#L2717-L2729
const newSkills = allCommands.filter(cmd => !sent.has(cmd.name))
if (newSkills.length === 0) return []
const isInitial = sent.size === 0
for (const cmd of newSkills) {
  sent.add(cmd.name)
}
```

- 首次发送全部 skills（`isInitial = true`）
- 后续仅发送新增的 skills（动态加载的 skills）
- Resume 时通过 [`suppressNextSkillListing()`](../../claude-code-source/src/utils/attachments.ts#L2631) 抑制重复发送

### 3. 渲染为 system-reminder

#### 3.1 什么是 system-reminder

`<system-reminder>` 是 Claude Code 中用于将系统生成的辅助信息注入对话流的 XML 标签。它不是 Anthropic API 的原生机制，而是 Claude Code 自行实现的**内容包装层**。

核心特征：

- **消息角色仍为 user**：`<system-reminder>` 包裹的内容仍是用户消息，而非系统提示词
- **对模型可见，UI 隐藏**：配合 `isMeta: true`，消息在终端 UI 中不显示，但模型可以读取
- **语义标记**：标签名 `system-reminder` 具有自描述性，LLM 通过训练中对 XML 结构的理解和标签名称的语义推断，将其识别为"系统级辅助信息，非用户直接输入"，而非将其当作用户输入的一部分来响应
- **用途广泛**：skill 列表、文件变更通知、权限提醒等都通过该标签注入

底层实现由 [`wrapInSystemReminder()`](../../claude-code-source/src/utils/messages.ts#L3097-L3099) 完成：

```typescript
// src/utils/messages.ts#L3097-L3099
export function wrapInSystemReminder(content: string): string {
  return `<system-reminder>\n${content}\n</system-reminder>`
}
```

[`wrapMessagesInSystemReminder()`](../../claude-code-source/src/utils/messages.ts#L3101-L3128) 对消息对象中的文本内容统一包裹该标签：

```typescript
// src/utils/messages.ts#L3101-L3112
export function wrapMessagesInSystemReminder(
  messages: UserMessage[],
): UserMessage[] {
  return messages.map(msg => {
    if (typeof msg.message.content === 'string') {
      return {
        ...msg,
        message: {
          ...msg.message,
          content: wrapInSystemReminder(msg.message.content),
        },
      }
    }
    // ... 数组类型内容同理处理每个 text block
  })
}
```

#### 3.2 skill_listing 的渲染逻辑

[`messages.ts`](../../claude-code-source/src/utils/messages.ts#L3728-L3738) 将 `skill_listing` attachment 渲染为 `<system-reminder>` 包裹的 user message：

```typescript
// src/utils/messages.ts#L3728-L3738
case 'skill_listing': {
  if (!attachment.content) return []
  return wrapMessagesInSystemReminder([
    createUserMessage({
      content: `The following skills are available for use with the Skill tool:\n\n${attachment.content}`,
      isMeta: true,
    }),
  ])
}
```

渲染结果示例：

```xml
<system-reminder>
The following skills are available for use with the Skill tool:

- markdowncli: 按照指定的格式规范创建和修改Markdown文档
- c-lang-spec: C 语言编程规范的代码检查与格式化指导
</system-reminder>
```

#### 3.3 为什么不注入系统提示词

Skill 列表选择以 `<system-reminder>` 包裹的 user message 注入，而非写入系统提示词，有以下几个架构层面的原因：

##### 3.3.1 系统提示词是静态的，Skills 是动态的

系统提示词在会话初始化时构建，之后通常不再变化。而 Skills 列表在会话生命周期内会动态变化——条件 skill 被激活、新 skill 目录被发现、MCP 服务器连接后添加新 skill。将动态内容放入静态结构中，需要频繁重建整个系统提示词。

##### 3.3.2 增量更新需求

[`sentSkillNames`](../../claude-code-source/src/utils/attachments.ts#L2717-L2729) 机制追踪已发送的 skill，每轮仅注入新增项：

```typescript
const newSkills = allCommands.filter(cmd => !sent.has(cmd.name))
```

如果 skill 列表在系统提示词中，每次新增 skill 都需要替换整个系统提示词，导致全部内容重发。而 attachment 机制可以仅在用户消息流中追加增量内容。

##### 3.3.3 独立的 Token 预算控制

Skill 列表有自己独立的预算（上下文窗口的 1%，见第四节），与系统提示词的预算分离。如果混入系统提示词，无法对 skill 列表单独做截断和预算管理。

##### 3.3.4 Compaction 后的可恢复性

上下文压缩（compaction）后，skill 列表需要重新注入。通过 [`resetSentSkillNames()`](../../claude-code-source/src/utils/attachments.ts#L2610) 清除已发送记录，下一轮的 `getSkillListingAttachments()` 就会重新注入完整列表。如果 skill 列表在系统提示词中，compaction 后需要重建整个系统提示词。

##### 3.3.5 多 Agent 隔离

Fork 子 Agent 有独立的 `sentSkillNames`，主 Agent 和子 Agent 可以有不同的 skill 可见性。系统提示词是共享的，无法按 Agent 粒度区分可见 skill。

##### 3.3.6 语义边界清晰

`<system-reminder>` 标签明确告知模型"这是辅助性的系统信息，不是你的行为指令"。将 skill 列表放在系统提示词中，模糊了"行为规则"和"可用资源列表"的语义边界。

## 四、 Skill 列表的预算控制

[`formatCommandsWithinBudget()`](../../claude-code-source/src/tools/SkillTool/prompt.ts#L70-L171) 控制列表的 token 开销：

### 1. 预算计算

```typescript
// src/tools/SkillTool/prompt.ts#L21-L23
export const SKILL_BUDGET_CONTEXT_PERCENT = 0.01
export const CHARS_PER_TOKEN = 4
export const DEFAULT_CHAR_BUDGET = 8_000 // Fallback: 1% of 200k × 4
```

- 默认占上下文窗口的 **1%**
- 200K token 窗口约 8000 字符预算

### 2. 截断策略

1. 优先保留 bundled skills 的完整描述（永不截断）
2. 非 bundled skills 按剩余预算均分描述长度
3. 极端情况下仅保留名称（`- skill-name`）

### 3. 单条描述上限

```typescript
// src/tools/SkillTool/prompt.ts#L29
export const MAX_LISTING_DESC_CHARS = 250
```

每条 skill 描述最多 250 字符，超出部分截断并添加省略号。

## 五、 Skill 正文长度对上下文的影响

调用阶段的 skill 正文注入**没有硬性长度限制**——整个 SKILL.md 的 Markdown 正文会被完整注入用户消息流。当正文很长时，会对上下文窗口产生显著影响。

### 1. 问题场景

以 `markdowncli` 为例，其 SKILL.md 正文约 6000 字符（~1525 token）。而源码注释指出，实际中更大的 skill 很常见：

```typescript
// src/services/compact/compact.ts#L125-L130
// Skills can be large (verify=18.7KB, claude-api=20.1KB). Previously re-injected
// unbounded on every compact → 5-10K tok/compact. Per-skill truncation beats
// dropping — instructions at the top of a skill file are usually the critical
// part. Budget sized to hold ~5 skills at the per-skill cap.
export const POST_COMPACT_MAX_TOKENS_PER_SKILL = 5_000
export const POST_COMPACT_SKILLS_TOKEN_BUDGET = 25_000
```

- `verify` skill 约 18.7KB（~4675 token）
- `claude-api` skill 约 20.1KB（~5025 token）

如果多个大 skill 在同一会话中被调用，可能占用 10K+ token。

### 2. 调用时无截断

调用 skill 时，[`getPromptForCommand()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L344-L398) 返回的是**完整正文**，不做任何截断：

```typescript
// src/skills/loadSkillsDir.ts#L344-L398
async getPromptForCommand(args, toolUseContext) {
  let finalContent = baseDir
    ? `Base directory for this skill: ${baseDir}\n\n${markdownContent}`
    : markdownContent
  // ... 参数替换、变量替换
  return [{ type: 'text', text: finalContent }]  // 完整返回，无截断
}
```

### 3. Compaction 时的截断保护

当上下文压缩（compaction）发生时，已调用的 skill 正文通过 [`createSkillAttachmentIfNeeded()`](../../claude-code-source/src/services/compact/compact.ts#L1494-L1527) 恢复，但会施加**两级预算控制**：

#### 3.1 单个 skill 截断

每个 skill 的内容截断到 `POST_COMPACT_MAX_TOKENS_PER_SKILL = 5000` token：

```typescript
// src/services/compact/compact.ts#L1509-L1516
const skills = Array.from(invokedSkills.values())
  .sort((a, b) => b.invokedAt - a.invokedAt)  // 最近调用的排前面
  .map(skill => ({
    name: skill.skillName,
    path: skill.skillPath,
    content: truncateToTokens(
      skill.content,
      POST_COMPACT_MAX_TOKENS_PER_SKILL,  // 5000 token
    ),
  }))
```

截断策略：**保留头部**（setup/usage 指令通常在文件头部），并追加截断提示：

```typescript
// src/services/compact/compact.ts#L1657-L1672
const SKILL_TRUNCATION_MARKER =
  '\n\n[... skill content truncated for compaction; use Read on the skill path if you need the full text]'

function truncateToTokens(content: string, maxTokens: number): string {
  if (roughTokenCountEstimation(content) <= maxTokens) {
    return content
  }
  const charBudget = maxTokens * 4 - SKILL_TRUNCATION_MARKER.length
  return content.slice(0, charBudget) + SKILL_TRUNCATION_MARKER
}
```

#### 3.2 总预算控制

所有 skill 的总 token 不超过 `POST_COMPACT_SKILLS_TOKEN_BUDGET = 25000`：

```typescript
// src/services/compact/compact.ts#L1517-L1524
.filter(skill => {
  const tokens = roughTokenCountEstimation(skill.content)
  if (usedTokens + tokens > POST_COMPACT_SKILLS_TOKEN_BUDGET) {
    return false  // 超出总预算，丢弃该 skill
  }
  usedTokens += tokens
  return true
})
```

- 按最近调用时间排序，预算紧张时优先保留最近调用的 skill
- 超出总预算的 skill 直接丢弃（而非截断）

### 4. 预算参数总结

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `SKILL_BUDGET_CONTEXT_PERCENT` | 1% | 发现阶段：skill 列表占上下文窗口比例 |
| `MAX_LISTING_DESC_CHARS` | 250 | 发现阶段：单条描述字符上限 |
| `POST_COMPACT_MAX_TOKENS_PER_SKILL` | 5000 | Compaction 后：单个 skill 正文 token 上限 |
| `POST_COMPACT_SKILLS_TOKEN_BUDGET` | 25000 | Compaction 后：所有 skill 正文总 token 预算 |

注意：**调用时无截断**，上述后两个参数仅在 compaction 恢复时生效。

### 5. Skill 是否越精简越好

两阶段架构下，"精简"对不同阶段含义不同，答案并非简单的"越短越好"。

#### 5.1 发现阶段：frontmatter 精准即可

发现阶段注入的是 `name + description + whenToUse`，受 1% 上下文预算和 `MAX_LISTING_DESC_CHARS = 250` 字符/条上限控制。每个 skill 的开销极小（如 `markdowncli` 仅 ~10 token），所以只要控制在预算内，frontmatter 的精简程度影响不大。更重要的是**精准**——让模型准确判断是否该调用这个 skill。

#### 5.2 调用阶段：精简 ≠ 越短越好

调用阶段注入完整正文，**无截断**。此时长度确实直接影响上下文消耗，但"越精简越好"不成立，原因有三：

##### 5.2.1 正文是指令，不是冗余信息

Skill 正文是模型的行为指令。如果精简到丢失关键指令，模型生成的代码质量会下降，反而需要更多轮次修正——多轮对话的 token 消耗远大于一次高质量的 skill 注入。

##### 5.2.2 Compaction 保底：头部优先

源码注释明确指出截断策略的设计考量：

```typescript
// src/services/compact/compact.ts#L125-L129
// Per-skill truncation beats dropping — instructions at the top of a skill
// file are usually the critical part. Budget sized to hold ~5 skills at
// the per-skill cap.
```

即使 skill 很长，compaction 后也只保留 5000 token（头部优先）。所以合理的做法不是把 skill 写短，而是**把最重要的指令放在前面**。

##### 5.2.3 按需加载 = 只在需要时付费

两阶段架构的核心价值：一个 20KB 的 skill 如果从未被调用，它只消耗 ~10 token（发现阶段）。只有模型主动调用时才"付出"完整正文的代价。

#### 5.3 Skill 设计建议

| 策略 | 原因 |
| --- | --- |
| frontmatter 精准简洁 | 影响发现阶段的匹配质量，且受预算控制 |
| 正文**头部放核心指令** | compaction 截断保留头部，尾部可能丢失 |
| 正文控制在 5000 token（~20KB）以内 | 超出部分 compaction 后会被截断 |
| 同一会话避免调用多个大 skill | 总预算 25000 token，5 个大 skill 就满了 |
| 用 `paths` 做条件激活 | 避免不相关场景下的 skill 干扰 |

**结论**：Skill 不是越精简越好，而是**结构要好**——frontmatter 精准、正文头重尾轻、长度控制在 compaction 截断线以内。两阶段架构已经做到了"不用就不费"，真正需要关注的是**用的时候别浪费**。

## 七、 Skill 内容的注入路径

当模型通过 SkillTool 调用 skill 时，完整内容通过以下路径注入：

### 1. Inline（默认）

调用 [`processPromptSlashCommand()`](../../claude-code-source/src/utils/processUserInput/processSlashCommand.tsx#L815) → [`getMessagesForPromptSlashCommand()`](../../claude-code-source/src/utils/processUserInput/processSlashCommand.tsx#L825) → `command.getPromptForCommand()` 获取完整正文，作为 **user message** 注入当前对话：

```typescript
// src/utils/processUserInput/processSlashCommand.tsx#L869
const result = await command.getPromptForCommand(args, context)
```

返回的 `newMessages` 以 `isMeta: true` 的用户消息形式加入对话流。

### 2. Fork（子 Agent）

当 skill 的 `context: 'fork'` 时，在独立的子 Agent 中执行：

```typescript
// src/tools/SkillTool/SkillTool.ts#L622-L632
if (command?.type === 'prompt' && command.context === 'fork') {
  return executeForkedSkill(command, commandName, args, context, canUseTool, parentMessage, onProgress)
}
```

Fork 模式下 skill 内容作为子 Agent 的 prompt 运行，结果以工具结果形式返回主对话。

### 3. Remote（远程 Skill）

远程 canonical skill 直接将 SKILL.md 正文包装为 user message：

```typescript
// src/tools/SkillTool/SkillTool.ts#L1101-L1107
return {
  data: { success: true, commandName, status: 'inline' },
  newMessages: tagMessagesWithToolUseID(
    [createUserMessage({ content: finalContent, isMeta: true })],
    toolUseID,
  ),
}
```

## 八、 总结

| 问题 | 答案 |
| --- | --- |
| 是否一次全部读入？ | 启动时读取所有 SKILL.md 文件，但仅将元数据摘要注入上下文 |
| 何时加载完整内容？ | 模型调用 SkillTool 时按需获取 |
| 注入位置 | 列表通过 `system-reminder` 注入；完整内容通过 `user message`（`isMeta: true`）注入 |
| 是否为系统提示词？ | 不是。skill 列表和内容都不在系统提示词中，而是通过 attachment/message 机制注入 |

## 九、 实例分析：markdowncli skill 的两阶段加载

以 `~/.claude/skills/markdowncli/SKILL.md` 为例，追踪其完整的加载与注入流程。

### 1. 发现阶段：元数据注入

会话启动时，系统扫描 `~/.claude/skills/` 目录，发现 `markdowncli` skill。此时仅将 frontmatter 元数据注入上下文：

**估算 token 开销**：

```typescript
// src/skills/loadSkillsDir.ts#L100-L105
export function estimateSkillFrontmatterTokens(skill: Command): number {
  const frontmatterText = [skill.name, skill.description, skill.whenToUse]
    .filter(Boolean)
    .join(' ')
  return roughTokenCountEstimation(frontmatterText)
}
```

对于 `markdowncli`：

- `name` = `"markdowncli"`
- `description` = `"按照指定的格式规范创建和修改Markdown文档"`
- `whenToUse` = `undefined`（未指定，被 `filter(Boolean)` 过滤）

拼接文本：`"markdowncli 按照指定的格式规范创建和修改Markdown文档"`，约 40 字符 ≈ 10 token。

**实际注入格式**（在 `<system-reminder>` 中）：

```
The following skills are available for use with the Skill tool:

- markdowncli: 按照指定的格式规范创建和修改Markdown文档
```

### 2. 预算控制

[`formatCommandsWithinBudget()`](../../claude-code-source/src/tools/SkillTool/prompt.ts#L70-L171) 在格式化该 skill 时：

- `markdowncli` 不是 bundled skill，走普通截断逻辑
- 描述长度 = `"按照指定的格式规范创建和修改Markdown文档"` = 19 个字符
- 远低于 `MAX_LISTING_DESC_CHARS = 250` 字符上限，完整保留

### 3. 调用阶段：完整内容注入

当模型通过 SkillTool 调用 `markdowncli` 时：

```
用户输入: "@command://markdowncli 帮我分析一下skills是怎么被读入上下文"

模型判断匹配 → 调用 SkillTool(name="markdowncli", args="帮我分析一下skills是怎么被读入上下文")
```

**调用链**：

```
SkillTool.call()
  → processPromptSlashCommand()
    → getMessagesForPromptSlashCommand()
      → command.getPromptForCommand(args="帮我分析一下skills是怎么被读入上下文", context)
```

**`getPromptForCommand()` 执行**：

1. `markdownContent` = SKILL.md 第 6-284 行的完整正文（279 行，约 6000 字符）
2. 添加 Base Directory 前缀：`Base directory for this skill: /root/.claude/skills/markdowncli\n\n`
3. [`substituteArguments()`](../../claude-code-source/src/utils/argumentSubstitution.ts#L92) —— 无参数定义，`args` 不替换到正文
4. 返回 `[{ type: 'text', text: finalContent }]`

**注入的消息**：

```typescript
// 以 isMeta: true 的 user message 注入
createUserMessage({
  content: "Base directory for this skill: /root/.claude/skills/markdowncli\n\n# Skill: Markdown文档格式规范\n\n## 技能说明\n\n本技能定义了一套统一的 Markdown 文档格式规范...",
  isMeta: true,
})
```

### 4. 两个阶段的 token 开销对比

| 阶段 | 内容 | 字符数 | 估算 token |
| --- | --- | --- | --- |
| 发现阶段 | name + description | ~40 | ~10 |
| 调用阶段 | Base Directory + 完整正文 | ~6100 | ~1525 |
| 倍率 | | | **~150 倍** |

这体现了两阶段架构的核心优势：启动时仅消耗极少量 token 让模型知道有这个 skill 可用，仅在真正需要时才加载完整内容。

### 5. 增量注入与重发

- 首次启动时 `markdowncli` 作为 `isInitial = true` 批次的一部分发送
- 后续每轮中 `sent.has('markdowncli')` 为 `true`，不会重复发送列表项
- 如果 compaction 发生，[`resetSentSkillNames()`](../../claude-code-source/src/utils/attachments.ts#L2610) 清除已发送记录，`markdowncli` 会在下一轮重新注入

---

*本文档由 markdowncli 技能辅助生成*

<!-- more -->

## 一、概述

自定义 Agent 的 MD 文件被扫描和解析后，其内容需要被注入 LLM 上下文，LLM 才能知道有哪些 Agent 可用并做出选择。本文档深入分析 Agent 列表的两种注入模式、完整的工具描述生成、附件消息的增量差异计算与 LLM 文本转换、LLM 选择子 Agent 的机制，以及子 Agent 系统提示词的完整构建流程。

本文档按**两个视角**组织：

- **主 Agent（Claude Code 主会话）视角**：子 Agent 的信息如何呈现给主会话 LLM，LLM 如何选择和调度子 Agent
- **子 Agent 视角**：子 Agent 被选中后，自身的系统提示词如何构建、工具如何解析、如何完成初始化

---

## 二、主 Agent 视角：子 Agent 信息的注入与呈现

主会话 LLM 需要知道有哪些子 Agent 可用，才能做出选择。子 Agent 的信息（`name` + `description` + `tools`）通过 **Agent 列表** 注入主会话上下文，有内嵌到工具描述和附件消息两种模式。

### 1. Agent 列表的两种注入模式

系统有两种方式将 Agent 列表注入 LLM 上下文，由 [`shouldInjectAgentListInMessages()`](../../claude-code-source/src/tools/AgentTool/prompt.ts#L59-L64) 决定使用哪种模式：

```typescript
// src/tools/AgentTool/prompt.ts#L59-L64
export function shouldInjectAgentListInMessages(): boolean {
  if (isEnvTruthy(process.env.CLAUDE_CODE_AGENT_LIST_IN_MESSAGES)) return true
  if (isEnvDefinedFalsy(process.env.CLAUDE_CODE_AGENT_LIST_IN_MESSAGES))
    return false
  return getFeatureValue_CACHED_MAY_BE_STALE('tengu_agent_list_attach', false)
}
```

判断优先级：环境变量 `CLAUDE_CODE_AGENT_LIST_IN_MESSAGES` > GrowthBook 特性标志 `tengu_agent_list_attach` > 默认 `false`。

#### 1.1 模式 A：内嵌到工具描述（传统/默认模式）

当 `shouldInjectAgentListInMessages()` 返回 `false` 时，Agent 列表直接嵌入 `Agent` 工具的 description 中：

```typescript
// src/tools/AgentTool/prompt.ts#L196-L199
const agentListSection = listViaAttachment
  ? `Available agent types are listed in <system-reminder> messages in the conversation.`
  : `Available agent types and the tools they have access to:
${effectiveAgents.map(agent => formatAgentLine(agent)).join('\n')}`
```

每一行 Agent 描述由 [`formatAgentLine()`](../../claude-code-source/src/tools/AgentTool/prompt.ts#L43-L46) 格式化：

```typescript
// src/tools/AgentTool/prompt.ts#L43-L46
export function formatAgentLine(agent: AgentDefinition): string {
  const toolsDescription = getToolsDescription(agent)
  return `- ${agent.agentType}: ${agent.whenToUse} (Tools: ${toolsDescription})`
}
```

工具描述由 [`getToolsDescription()`](../../claude-code-source/src/tools/AgentTool/prompt.ts#L15-L37) 根据白名单和黑名单的组合生成：

```typescript
// src/tools/AgentTool/prompt.ts#L15-L37
function getToolsDescription(agent: AgentDefinition): string {
  const { tools, disallowedTools } = agent
  const hasAllowlist = tools && tools.length > 0
  const hasDenylist = disallowedTools && disallowedTools.length > 0

  if (hasAllowlist && hasDenylist) {
    // 白名单和黑名单同时存在：过滤后显示
    const denySet = new Set(disallowedTools)
    const effectiveTools = tools.filter(t => !denySet.has(t))
    return effectiveTools.length === 0 ? 'None' : effectiveTools.join(', ')
  } else if (hasAllowlist) {
    return tools.join(', ')
  } else if (hasDenylist) {
    return `All tools except ${disallowedTools.join(', ')}`
  }
  return 'All tools'
}
```

生成的文本示例：

```
Available agent types and the tools they have access to:
- general-purpose: General-purpose agent for researching complex questions... (Tools: All tools)
- Explore: Fast agent specialized for exploring codebases... (Tools: All tools except Agent, ExitPlanMode, Edit, Write, NotebookEdit)
- code-reviewer: 审查代码变更，提供改进建议 (Tools: Read, Grep, Bash)
```

**模式 A 下，Agent 列表位于 Anthropic API 请求的 `tools` 数组中**：

```
Anthropic Messages API
├── system: SystemPrompt          ← 主会话系统提示词（不含子 Agent 信息）
│   ├── intro section
│   ├── system section
│   ├── ...
├── messages: Message[]           ← 对话消息
│   ├── <system-reminder> ...     ← 其他附件（不含 agent_listing_delta）
│   └── ...
└── tools: Tool[]                 ← 工具定义
    ├── Agent: {                  ← Agent 工具
    │     name: "Agent",
    │     description: "Launch a new agent...
    │       Available agent types...:
    │       - code-reviewer: 审查代码变更... (Tools: Read, Grep, Bash)  ← MD 的 name+description+tools
    │       - Explore: Fast agent... (Tools: ...)
    │       ..."
    │   }
    ├── Read: { ... }
    └── ...
```

#### 1.2 模式 B：附件消息注入（增量模式）

当 `shouldInjectAgentListInMessages()` 返回 `true` 时，Agent 列表通过 `agent_listing_delta` 类型的附件消息注入。

##### 为什么需要增量模式

将 Agent 列表嵌入工具描述会导致约 10.2% 的 fleet `cache_creation` token 消耗。MCP 异步连接、`/reload-plugins`、权限模式变更等操作会改变 Agent 列表，导致工具描述变化，进而使整个 tool-schema 的 prompt cache 失效。将列表移至附件消息可以保持工具描述不变，仅在附件部分产生增量更新。

##### 附件数据结构

定义在 [`src/utils/attachments.ts`](../../claude-code-source/src/utils/attachments.ts#L691-L700)：

```typescript
// src/utils/attachments.ts#L691-L700
{
  type: 'agent_listing_delta'
  addedTypes: string[]      // 新增的 agentType 列表
  addedLines: string[]      // 新增的 Agent 描述行（formatAgentLine 格式）
  removedTypes: string[]    // 移除的 agentType 列表
  isInitial: boolean        // 是否为会话中首次公告
  showConcurrencyNote: boolean  // 是否显示并发提示（非 Pro 订阅）
}
```

##### 增量差异计算

[`getAgentListingDeltaAttachment()`](../../claude-code-source/src/utils/attachments.ts#L1490-L1556) 通过对比当前 Agent 池与已公告集合，计算增量：

```typescript
// src/utils/attachments.ts#L1490-L1556
export function getAgentListingDeltaAttachment(toolUseContext, messages): Attachment[] {
  if (!shouldInjectAgentListInMessages()) return []

  // 1. 跳过 Agent 工具不在工具池中的情况
  if (!toolUseContext.options.tools.some(t => toolMatchesName(t, AGENT_TOOL_NAME))) return []

  // 2. 获取活跃 Agent 列表，镜像 AgentTool.prompt() 的过滤逻辑
  const { activeAgents, allowedAgentTypes } = toolUseContext.options.agentDefinitions
  const mcpServers = new Set<string>()
  for (const tool of toolUseContext.options.tools) {
    const info = mcpInfoFromString(tool.name)
    if (info) mcpServers.add(info.serverName)
  }
  let filtered = filterDeniedAgents(
    filterAgentsByMcpRequirements(activeAgents, [...mcpServers]),
    permissionContext, AGENT_TOOL_NAME,
  )
  if (allowedAgentTypes) {
    filtered = filtered.filter(a => allowedAgentTypes.includes(a.agentType))
  }

  // 3. 从历史消息中重建已公告集合
  const announced = new Set<string>()
  for (const msg of messages ?? []) {
    if (msg.type !== 'attachment') continue
    if (msg.attachment.type !== 'agent_listing_delta') continue
    for (const t of msg.attachment.addedTypes) announced.add(t)
    for (const t of msg.attachment.removedTypes) announced.delete(t)
  }

  // 4. 计算增量
  const currentTypes = new Set(filtered.map(a => a.agentType))
  const added = filtered.filter(a => !announced.has(a.agentType))
  const removed: string[] = []
  for (const t of announced) {
    if (!currentTypes.has(t)) removed.push(t)
  }

  if (added.length === 0 && removed.length === 0) return []

  // 5. 排序确保输出确定性
  added.sort((a, b) => a.agentType.localeCompare(b.agentType))
  removed.sort()

  return [{
    type: 'agent_listing_delta',
    addedTypes: added.map(a => a.agentType),
    addedLines: added.map(formatAgentLine),
    removedTypes: removed,
    isInitial: announced.size === 0,
    showConcurrencyNote: getSubscriptionType() !== 'pro',
  }]
}
```

【**关键**】过滤逻辑必须与 [`AgentTool.prompt()`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L197-L224) 保持同步：MCP 需求过滤 → 权限拒绝过滤 → allowedAgentTypes 限制。

##### 附件消息的 LLM 文本转换

[`messages.ts`](../../claude-code-source/src/utils/messages.ts#L4194-L4213) 将 `agent_listing_delta` 附件转换为 LLM 可见的消息文本：

```typescript
// src/utils/messages.ts#L4194-L4213
case 'agent_listing_delta': {
  const parts: string[] = []
  if (attachment.addedLines.length > 0) {
    const header = attachment.isInitial
      ? 'Available agent types for the Agent tool:'
      : 'New agent types are now available for the Agent tool:'
    parts.push(`${header}\n${attachment.addedLines.join('\n')}`)
  }
  if (attachment.removedTypes.length > 0) {
    parts.push(
      `The following agent types are no longer available:\n${attachment.removedTypes.map(t => `- ${t}`).join('\n')}`,
    )
  }
  if (attachment.isInitial && attachment.showConcurrencyNote) {
    parts.push(
      `Launch multiple agents concurrently whenever possible, to maximize performance; to do that, use a single message with multiple tool uses.`,
    )
  }
  return wrapMessagesInSystemReminder([
    createUserMessage({ content: parts.join('\n\n'), isMeta: true }),
  ])
}
```

该消息被包裹在 `<system-reminder>` 标签中注入对话上下文，LLM 即可看到当前可用的 Agent 列表。

首次公告示例：

```
<system-reminder>
Available agent types for the Agent tool:
- Explore: Fast agent specialized for exploring codebases... (Tools: All tools except Agent, ExitPlanMode, Edit, Write, NotebookEdit)
- Plan: Software architect agent for designing implementation plans... (Tools: All tools except Agent, ExitPlanMode, Edit, Write, NotebookEdit)
- code-reviewer: 审查代码变更，提供改进建议 (Tools: Read, Grep, Bash)

Launch multiple agents concurrently whenever possible, to maximize performance; to do that, use a single message with multiple tool uses.
</system-reminder>
```

增量更新示例：

```
<system-reminder>
New agent types are now available for the Agent tool:
- database-analyst: 分析数据库结构和查询性能 (Tools: Read, Grep, Bash)

The following agent types are no longer available:
- deprecated-agent
</system-reminder>
```

**模式 B 下，Agent 列表作为 `<system-reminder>` 包裹的用户消息注入 `messages` 数组**：

```
Anthropic Messages API
├── system: SystemPrompt          ← 主会话系统提示词（不含子 Agent 信息）
├── messages: Message[]
│   ├── <system-reminder>         ← agent_listing_delta 附件
│   │   Available agent types for the Agent tool:
│   │   - code-reviewer: 审查代码变更... (Tools: Read, Grep, Bash)   ← MD 的 name+description+tools
│   │   - Explore: Fast agent... (Tools: ...)
│   │ </system-reminder>
│   ├── [用户消息]
│   └── ...
└── tools: Tool[]                 ← Agent 工具描述是静态的
    ├── Agent: {
    │     name: "Agent",
    │     description: "Launch a new agent...
    │       Available agent types are listed in <system-reminder> messages..."  ← 静态指引
    │   }
    └── ...
```

##### 注入时机

附件在每次 LLM 请求前通过 [`attachments.ts`](../../claude-code-source/src/utils/attachments.ts#L851-L853) 中的 `maybe('agent_listing_delta', ...)` 调用生成：

```typescript
// src/utils/attachments.ts#L851-L853
maybe('agent_listing_delta', () =>
  Promise.resolve(getAgentListingDeltaAttachment(toolUseContext, messages)),
),
```

`maybe()` 工厂函数在 [`getAttachments()`](../../claude-code-source/src/utils/attachments.ts#L743) 中被调用，后者在每次用户提交消息或工具结果返回时执行。

### 2. Agent 工具描述的完整结构

无论使用哪种注入模式，`Agent` 工具的描述由 [`getPrompt()`](../../claude-code-source/src/tools/AgentTool/prompt.ts#L66-L287) 生成，包含以下部分：

#### 2.1 共享核心描述

```typescript
// src/tools/AgentTool/prompt.ts#L202-L212
const shared = `Launch a new agent to handle complex, multi-step tasks autonomously.

The ${AGENT_TOOL_NAME} tool launches specialized agents (subprocesses) that
autonomously handle complex tasks. Each agent type has specific capabilities
and tools available to it.

${agentListSection}

${
  forkEnabled
    ? `When using the ${AGENT_TOOL_NAME} tool, specify a subagent_type to use a specialized agent, or omit it to fork yourself — a fork inherits your full conversation context.`
    : `When using the ${AGENT_TOOL_NAME} tool, specify a subagent_type parameter to select which agent type to use. If omitted, the general-purpose agent is used.`
}`
```

#### 2.2 Coordinator 模式精简

Coordinator 模式只返回核心描述，因为 Coordinator 的系统提示词已包含使用说明、示例和不使用指导：

```typescript
// src/tools/AgentTool/prompt.ts#L216-L218
if (isCoordinator) {
  return shared
}
```

#### 2.3 不使用 Agent 的场景

```typescript
// src/tools/AgentTool/prompt.ts#L232-L240
const whenNotToUseSection = forkEnabled ? '' : `
When NOT to use the ${AGENT_TOOL_NAME} tool:
- If you want to read a specific file path, use the ${FILE_READ_TOOL_NAME} tool or ${fileSearchHint} instead
- If you are searching for a specific class definition like "class Foo", use ${contentSearchHint} instead
- If you are searching for code within a specific file or set of 2-3 files, use the ${FILE_READ_TOOL_NAME} tool instead
- Other tasks that are not related to the agent descriptions above
`
```

【**注意**】Fork 模式开启时，不显示此部分，因为 Fork 适用于几乎所有场景。

#### 2.4 使用说明

```typescript
// src/tools/AgentTool/prompt.ts#L252-L284
return `${shared}
${whenNotToUseSection}

Usage notes:
- Always include a short description (3-5 words) summarizing what the agent will do${concurrencyNote}
- When the agent is done, it will return a single message back to you...
${backgroundNotes}
- To continue a previously spawned agent, use ${SEND_MESSAGE_TOOL_NAME}...
- The agent's outputs should generally be trusted
- Clearly tell the agent whether you expect it to write code or just to do research...
- If the agent description mentions that it should be used proactively, then you should try your best to use it without the user having to ask for it first.
- If the user specifies that they want you to run agents "in parallel", you MUST send a single message with multiple ${AGENT_TOOL_NAME} tool use content blocks.
- You can optionally set \`isolation: "worktree"\` to run the agent in a temporary git worktree...
${whenToForkSection}${writingThePromptSection}

${forkEnabled ? forkExamples : currentExamples}`
```

#### 2.5 编写提示词指南

```typescript
// src/tools/AgentTool/prompt.ts#L99-L113
const writingThePromptSection = `
## Writing the prompt

${forkEnabled ? 'When spawning a fresh agent (with a `subagent_type`), it starts with zero context. ' : ''}Brief the agent like a smart colleague who just walked into the room — it hasn't seen this conversation, doesn't know what you've tried, doesn't understand why this task matters.
- Explain what you're trying to accomplish and why.
- Describe what you've already learned or ruled out.
- Give enough context about the surrounding problem...
- If you need a short response, say so ("report in under 200 words").

**Never delegate understanding.** Don't write "based on your findings, fix the bug" or "based on the research, implement it." Those phrases push synthesis onto the agent instead of doing it yourself. Write prompts that prove you understood: include file paths, line numbers, what specifically to change.
`
```

#### 2.6 使用示例

非 Fork 模式示例：

```
<example_agent_descriptions>
"test-runner": use this agent after you are done writing code to run tests
"greeting-responder": use this agent to respond to user greetings with a friendly joke
</example_agent_descriptions>

<example>
user: "Please write a function that checks if a number is prime"
assistant: I'm going to use the Write tool to write the following code:
<code>
function isPrime(n) { ... }
</code>
<commentary>
Since a significant piece of code was written, now use the test-runner agent
</commentary>
assistant: Uses the Agent tool to launch the test-runner agent
</example>
```

Fork 模式示例（更详细，强调 Fork 行为规范）：

```
<example>
user: "What's left on this branch before we can ship?"
assistant: <thinking>Forking this — it's a survey question...</thinking>
Agent({
  name: "ship-audit",
  description: "Branch ship-readiness audit",
  prompt: "Audit what's left before this branch can ship..."
})
assistant: Ship-readiness audit running.
<commentary>
Turn ends here. The coordinator knows nothing about the findings yet...
[later turn — notification arrives as user message]
assistant: Audit's back. Three blockers: ...
</commentary>
</example>
```

#### 2.7 Fork 专用部分

Fork 开启时，额外注入 "When to fork" 和 "Writing a fork prompt" 指导：

```typescript
// src/tools/AgentTool/prompt.ts#L80-L97
const whenToForkSection = forkEnabled ? `
## When to fork

Fork yourself (omit \`subagent_type\`) when the intermediate tool output isn't worth keeping in your context. The criterion is qualitative — "will I need this output again" — not task size.
- **Research**: fork open-ended questions. If research can be broken into independent questions, launch parallel forks in one message.
- **Implementation**: prefer to fork implementation work that requires more than a couple of edits.

Forks are cheap because they share your prompt cache. Don't set \`model\` on a fork — a different model can't reuse the parent's cache.

**Don't peek.** The tool result includes an \`output_file\` path — do not Read or tail it unless the user explicitly asks for a progress check.

**Don't race.** After launching, you know nothing about what the fork found. Never fabricate or predict fork results...
` : ''
```

### 3. Agent 工具的 prompt() 方法

[`AgentTool.prompt()`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L197-L224) 是工具描述的入口方法，负责获取和过滤 Agent 列表：

```typescript
// src/tools/AgentTool/AgentTool.tsx#L197-L224
async prompt({ agents, tools, getToolPermissionContext, allowedAgentTypes }) {
  const toolPermissionContext = await getToolPermissionContext();

  // 1. 获取有工具可用的 MCP 服务器列表
  const mcpServersWithTools: string[] = [];
  for (const tool of tools) {
    if (tool.name?.startsWith('mcp__')) {
      const parts = tool.name.split('__');
      const serverName = parts[1];
      if (serverName && !mcpServersWithTools.includes(serverName)) {
        mcpServersWithTools.push(serverName);
      }
    }
  }

  // 2. 过滤 Agent：先按 MCP 需求，再按权限规则
  const agentsWithMcpRequirementsMet = filterAgentsByMcpRequirements(agents, mcpServersWithTools);
  const filteredAgents = filterDeniedAgents(agentsWithMcpRequirementsMet, toolPermissionContext, AGENT_TOOL_NAME);

  // 3. 调用 getPrompt() 生成最终描述
  const isCoordinator = feature('COORDINATOR_MODE') ? isEnvTruthy(process.env.CLAUDE_CODE_COORDINATOR_MODE) : false;
  return await getPrompt(filteredAgents, isCoordinator, allowedAgentTypes);
}
```

### 4. LLM 选择子 Agent 的机制

LLM 通过 `Agent` 工具的 `subagent_type` 参数选择子 Agent。选择过程并非独立的匹配算法，而是依赖 LLM 自身的理解能力。

#### 4.1 选择依据

LLM 选择子 Agent 时依据以下信息：

1. **Agent 列表中的 `whenToUse`**：每个 Agent 的 `description` 字段值作为 `whenToUse` 出现在列表中，告诉 LLM 该 Agent 适用于什么场景
2. **工具描述中的使用指引**：包含何时使用/不使用 Agent 工具的指导
3. **`<example_agent_descriptions>` 示例**：展示 Agent 名称与其适用场景的映射
4. **用户请求的内容**：LLM 根据用户意图匹配最合适的 Agent

#### 4.2 选择流程

```
用户请求 → LLM 判断是否需要委托子 Agent
    ↓
LLM 查看 Agent 列表中的 whenToUse 描述
    ↓
LLM 在 Agent 工具调用中设置 subagent_type = "匹配的 agentType"
    ↓
AgentTool.call() 接收 subagent_type，从 activeAgents 中查找匹配的 AgentDefinition
    ↓
若找到 → 启动子 Agent
若未找到 → 报错 "Agent type 'xxx' not found"
```

#### 4.3 默认行为

```typescript
// src/tools/AgentTool/AgentTool.tsx#L322
const effectiveType = subagent_type ?? (isForkSubagentEnabled() ? undefined : GENERAL_PURPOSE_AGENT.agentType)
```

- **Fork 关闭**：省略 `subagent_type` → 使用 `general-purpose`
- **Fork 开启**：省略 `subagent_type` → 进入 Fork 路径（继承父上下文）

#### 4.4 过滤与权限控制

在 LLM 选择之前，Agent 列表已经过以下过滤：

1. **MCP 需求过滤**：[`filterAgentsByMcpRequirements()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L250-L255) 移除所需 MCP 服务器未连接的 Agent
2. **权限规则过滤**：[`filterDeniedAgents()`](../../claude-code-source/src/utils/permissions/permissions.ts) 移除被权限规则禁止的 Agent
3. **允许类型限制**：`allowedAgentTypes` 限制可用 Agent 范围（来自 `Agent(AgentName)` 语法）

这些过滤在 [`AgentTool.prompt()`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L197-L224) 和 [`getAgentListingDeltaAttachment()`](../../claude-code-source/src/utils/attachments.ts#L1506-L1521) 中同步执行，确保 LLM 看到的列表与实际可用的 Agent 一致。

#### 4.5 Agent(AgentName) 语法

在 `tools` 白名单中，`Agent(researcher,explorer)` 语法限制子 Agent 只能调用特定类型的子 Agent：

```typescript
// src/tools/AgentTool/agentToolUtils.ts#L186-L204
for (const toolSpec of agentTools) {
  const { toolName, ruleContent } = permissionRuleValueFromString(toolSpec)
  // Special case: Agent tool carries allowedAgentTypes metadata
  if (toolName === AGENT_TOOL_NAME) {
    if (ruleContent) {
      // Parse comma-separated agent types: "worker, researcher" → ["worker", "researcher"]
      allowedAgentTypes = ruleContent.split(',').map(s => s.trim())
    }
    // For sub-agents, Agent is excluded by filterToolsForAgent
    if (!isMainThread) {
      validTools.push(toolSpec)
      continue  // 标记为有效但不解析工具
    }
  }
}
```

### 5. MD 文档在主会话中的角色：不是系统提示词，是工具描述的一部分

**核心结论：子 Agent 的 MD 文档在主会话中既不是系统提示词，也不在 `messages` 数组中。它的 `name` 和 `description` 被提取后，作为「工具描述」的一部分注入主会话 LLM 的上下文。MD 正文完全不进入主会话。**

#### 5.1 MD 字段在主会话中的去向

| MD 文档字段 | 在主会话中的去向 | 注入位置 | 作用 |
|-------------|-----------------|----------|------|
| `name` | → `agentType` | 工具描述 / 附件消息 | LLM 用此值设置 `subagent_type` 参数 |
| `description` | → `whenToUse` | 工具描述 / 附件消息 | LLM 据此判断何时使用此 Agent |
| `tools` / `disallowedTools` | → 工具描述的 `(Tools: ...)` 部分 | 工具描述 / 附件消息 | LLM 了解 Agent 能力范围 |
| **MD 正文** | **不进入主会话** | — | 仅在子 Agent 自身的系统提示词中使用 |
| `model` | **不进入主会话** | — | 仅在 `runAgent()` 中用于模型选择 |
| `memory` | **不进入主会话** | — | 仅在子 Agent 系统提示词中拼接记忆 |
| `permissionMode` | **不进入主会话** | — | 仅在 `runAgent()` 中覆盖权限 |
| `skills` | **不进入主会话** | — | 仅在 `runAgent()` 中预加载技能 |
| `mcpServers` | **不进入主会话** | — | 仅在 `runAgent()` 中初始化 MCP 连接 |
| `hooks` | **不进入主会话** | — | 仅在 `runAgent()` 中注册钩子 |
| `color` | **不进入主会话** | — | 仅在 UI 层设置终端颜色 |

#### 5.2 主会话 LLM 看到的子 Agent 信息

主会话 LLM 只能看到一行精简的 Agent 摘要，由 [`formatAgentLine()`](../../claude-code-source/src/tools/AgentTool/prompt.ts#L43-L46) 生成：

```typescript
// src/tools/AgentTool/prompt.ts#L43-L46
export function formatAgentLine(agent: AgentDefinition): string {
  const toolsDescription = getToolsDescription(agent)
  return `- ${agent.agentType}: ${agent.whenToUse} (Tools: ${toolsDescription})`
}
```

对于一个定义如下的 MD 文件：

```markdown
---
name: code-reviewer
description: 审查代码变更并提供改进建议
tools:
  - Read
  - Grep
  - Bash
model: sonnet
memory: project
---

你是 code-reviewer，一个专业的代码审查助手。
## 职责
- 审查代码变更的安全性和正确性
...
```

主会话 LLM 看到的完整信息仅为：

```
- code-reviewer: 审查代码变更并提供改进建议 (Tools: Read, Grep, Bash)
```

**MD 正文、`model: sonnet`、`memory: project` 等字段完全不暴露给主会话。**

#### 5.3 为什么 MD 正文不进入主会话

1. **信息密度**：MD 正文可能很长（数百行），全部注入主会话会浪费大量 token——主会话 LLM 不需要知道子 Agent 的详细行为规范，只需知道何时调用它

2. **关注点分离**：主会话 LLM 的职责是**选择和调度**子 Agent，不是**执行**子 Agent 的任务。`name` + `description` 足够完成选择，MD 正文属于执行层面的细节

3. **缓存效率**：模式 B 的核心动机就是将动态变化的 Agent 列表从工具描述中分离，避免每次列表变更都破坏工具描述的 prompt cache。如果把 MD 正文也放进来，会进一步加剧缓存压力

#### 5.4 实践指南：`description` 是主会话调度的唯一决策依据

虽然 `name`、`description`、`tools` 三个字段都进入主会话，但**只有 `description` 承载"何时使用"的语义**。主会话 LLM 根据这一句话判断是否调用该 Agent。

**如果在 MD 正文中写了详细的触发时机，主会话 LLM 完全看不到。** 例如：

```markdown
---
name: code-reviewer
description: 审查代码变更并提供改进建议        ← 主会话只看这一句
tools:
  - Read
  - Grep
  - Bash
---

你是 code-reviewer，一个专业的代码审查助手。

## 触发时机                                ← 主会话看不到！
- 用户请求代码审查时
- PR 提交后自动检查时
- 代码质量检查时
...
```

**写 MD 文件的关键原则**：

| 字段 | 读者 | 写法要点 |
|------|------|----------|
| `description` | **主会话 LLM** | 必须精确描述适用场景，这是调度的唯一依据。写得模糊，LLM 就不知道何时用你 |
| MD 正文 | **子 Agent 自身** | 行为规范、输出格式、详细触发条件等，只在子 Agent 执行时生效 |

因此，`description` 应该尽可能覆盖所有触发场景，例如改为：

```yaml
description: 当用户提到代码审查、PR审查、代码质量检查，或需要审查代码变更时使用此Agent
```

#### 5.5 对比：子 Agent vs Skill 的主会话可见性

子 Agent 和 Skill 的信息暴露机制有本质区别——**Skill 的正文在被调用后会完整注入主会话，而子 Agent 的正文永远不会进入主会话**。

| 对比项 | 子 Agent（Agent 工具） | Skill（Skill 工具） |
|--------|----------------------|---------------------|
| **列表注入格式** | `- agentType: whenToUse (Tools: ...)` | `- name: description`（无 when_to_use 时）<br>`- name: description - whenToUse`（有 when_to_use 时） |
| **`whenToUse` 来源** | `description` 字段（映射为 `whenToUse`） | 独立的 `when_to_use` 字段（**可选，大多数 Skill 未定义**） |
| **列表中的语义字段** | 仅 `description`（映射为 `whenToUse`） | 通常只有 `description`；`when_to_use` 存在时才追加上去 |
| **正文是否进入主会话** | **永不** — 正文仅作为子 Agent 自身的系统提示词 | **调用后完整注入** — 作为 `isMeta: true` 的用户消息 |
| **正文注入位置** | 子 Agent 的 `system[0]` | 主会话的 `messages` 数组 |
| **调用后 LLM 上下文** | 主会话 LLM 只看到返回结果，不知道正文内容 | 主会话 LLM 看到完整正文，并据此生成回复 |
| **正文中的触发时机是否可见** | **不可见** — 主会话完全不知道 | **可见** — 调用后正文中的"何时触发"等章节对主会话 LLM 可见 |

因此，如果你写了包含详细触发时机的 MD 文档：

- **作为子 Agent**：触发时机对主会话不可见，必须写在 `description` 字段中
- **作为 Skill**：触发时机在调用后对主会话可见，但**调度决策仍基于发现阶段的列表信息**——大多数 Skill 只有 `description`，因此 `description` 是调度的核心依据。建议同时在 `when_to_use` 字段中写明触发时机，让发现阶段的 LLM 获得更充分的决策信息

---

## 三、子 Agent 视角：提示词构建与初始化

当主会话 LLM 选择了一个子 Agent 并调用 `Agent` 工具后，子 Agent 开始独立的初始化和执行。本节描述子 Agent 自身的系统提示词构建、工具解析和完整初始化流程。

### 1. 系统提示词构建：Fork 路径 vs 普通路径

#### 1.1 Fork 路径

Fork 子 Agent 继承父 Agent 的完整系统提示词（通过 `toolUseContext.renderedSystemPrompt` 传递），而非使用 `FORK_AGENT.getSystemPrompt()` 返回的空字符串：

```typescript
// src/tools/AgentTool/AgentTool.tsx#L496-L511
if (isForkPath) {
  if (toolUseContext.renderedSystemPrompt) {
    forkParentSystemPrompt = toolUseContext.renderedSystemPrompt  // byte-identical
  } else {
    // Fallback: 重新计算（可能因 GrowthBook 状态变化偏离缓存）
    const defaultSystemPrompt = await getSystemPrompt(...)
    forkParentSystemPrompt = buildEffectiveSystemPrompt({...})
  }
}
```

#### 1.2 普通路径

```typescript
// src/tools/AgentTool/AgentTool.tsx#L514-L540
const agentPrompt = selectedAgent.getSystemPrompt({ toolUseContext })
enhancedSystemPrompt = await enhanceSystemPromptWithEnvDetails([agentPrompt], resolvedAgentModel, additionalWorkingDirectories)
```

### 2. 获取 Agent 定义的系统提示词

[`getAgentSystemPrompt()`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L906-L932) 构建子 Agent 的系统提示词：

```typescript
// src/tools/AgentTool/runAgent.ts#L906-L932
async function getAgentSystemPrompt(agentDefinition, toolUseContext, ...): Promise<string[]> {
  const enabledToolNames = new Set(resolvedTools.map(t => t.name))
  try {
    const agentPrompt = agentDefinition.getSystemPrompt({ toolUseContext })
    const prompts = [agentPrompt]
    return await enhanceSystemPromptWithEnvDetails(
      prompts, resolvedAgentModel, additionalWorkingDirectories, enabledToolNames,
    )
  } catch (_error) {
    // 失败时使用默认 Agent 提示词
    return enhanceSystemPromptWithEnvDetails(
      [DEFAULT_AGENT_PROMPT], resolvedAgentModel, additionalWorkingDirectories, enabledToolNames,
    )
  }
}
```

对于自定义 Agent，`getSystemPrompt()` 返回 MD 文件的正文内容（见 [LV061](LV061-自定义Agent的MD文件定义与发现.md) 第三节第 3 小节）。

### 3. MD 正文 → 最终系统提示词：完整转换链

**核心结论：MD 文件的正文不是完整的提示词，也不是完整输入提示词。它只是系统提示词的第一个块（block），经过多层增强后才成为最终发送给 LLM 的系统提示词。它属于系统提示词的一部分，位于系统提示词数组的最前面。**

#### 3.1 MD 正文在提示词中的定位

子 Agent 的 LLM API 调用结构如下：

```
Anthropic Messages API
├── system: SystemPrompt (string[])     ← 系统提示词数组
│   ├── [0] MD 正文 (content.trim())   ← 用户定义的 Agent 指令
│   ├── [1] Notes (通用行为规范)        ← 系统追加
│   ├── [2] DiscoverSkills Guidance     ← 条件追加
│   └── [3] 环境信息 (env)             ← 系统追加
├── messages: Message[]                 ← 对话消息
│   ├── Skill 预加载消息               ← 条件注入（skills 字段）
│   ├── Hook 附加上下文消息            ← 条件注入（SubagentStart hooks）
│   └── 用户任务描述 (prompt 参数)     ← Agent 工具的输入
└── tools: Tool[]                       ← 工具定义
```

**MD 正文位于系统提示词的第一个位置**，是最核心的"身份定义"部分，但不是全部。

#### 3.2 完整转换流程

以一个自定义 MD Agent 为例，追踪从文件到 API 请求的完整路径：

```markdown
---
name: code-reviewer
description: 审查代码变更并提供改进建议
tools:
  - Read
  - Grep
  - Bash
model: sonnet
memory: project
---

你是 code-reviewer，一个专业的代码审查助手。

## 职责
- 审查代码变更的安全性和正确性
- 检查代码风格和最佳实践
- 提供具体的改进建议

## 输出格式
请按以下格式输出审查结果：
1. 概述
2. 发现的问题（按严重程度排序）
3. 改进建议
```

**Step 1 — 解析 MD 文件，提取正文**

[`parseAgentFromMarkdown()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L713) 将 frontmatter 之后的正文作为 `systemPrompt`：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L713
const systemPrompt = content.trim()  // ← MD 正文，不含 frontmatter
```

此时 `systemPrompt` 的值：

```
你是 code-reviewer，一个专业的代码审查助手。

## 职责
- 审查代码变更的安全性和正确性
- 检查代码风格和最佳实践
- 提供具体的改进建议

## 输出格式
请按以下格式输出审查结果：
1. 概述
2. 发现的问题（按严重程度排序）
3. 改进建议
```

**Step 2 — 构建 getSystemPrompt() 闭包**

[`parseAgentFromMarkdown()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L726-L732) 将 `systemPrompt` 封装进闭包，可选拼接记忆提示词：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L726-L732
getSystemPrompt: () => {
  if (isAutoMemoryEnabled() && memory) {
    const memoryPrompt = loadAgentMemoryPrompt(agentType, memory)
    return systemPrompt + '\n\n' + memoryPrompt  // ← 拼接记忆
  }
  return systemPrompt  // ← 无记忆时仅返回正文
}
```

当 `memory: project` 启用时，`loadAgentMemoryPrompt()` 通过 [`buildMemoryPrompt()`](../../claude-code-source/src/memdir/memdir.ts#L272-L316) 生成一段完整的记忆系统说明，包含：

- 记忆目录路径（如 `.claude/agent-memory/code-reviewer/`）
- 记忆类型说明（`# Persistent Agent Memory`）
- 如何保存/读取记忆的指引
- `MEMORY.md` 的现有内容

拼接后 `getSystemPrompt()` 的返回值：

```
你是 code-reviewer，一个专业的代码审查助手。

## 职责
- 审查代码变更的安全性和正确性
...

# Persistent Agent Memory

You have a persistent, file-based memory system at `.claude/agent-memory/code-reviewer/`. ...
## How to save memories
...
## MEMORY.md

（已有记忆内容，或 "Your MEMORY.md is currently empty..."）
```

**Step 3 — getAgentSystemPrompt() 增强环境信息**

[`getAgentSystemPrompt()`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L906-L932) 调用 `getSystemPrompt()` 获取 Agent 原始提示词，然后调用 `enhanceSystemPromptWithEnvDetails()` 增强：

```typescript
// src/tools/AgentTool/runAgent.ts#L906-L932
async function getAgentSystemPrompt(agentDefinition, toolUseContext, ...): Promise<string[]> {
  const enabledToolNames = new Set(resolvedTools.map(t => t.name))
  const agentPrompt = agentDefinition.getSystemPrompt({ toolUseContext })
  const prompts = [agentPrompt]  // ← MD 正文 (+ 可选记忆)
  return await enhanceSystemPromptWithEnvDetails(
    prompts, resolvedAgentModel, additionalWorkingDirectories, enabledToolNames,
  )
}
```

**Step 4 — enhanceSystemPromptWithEnvDetails() 追加通用块**

[`enhanceSystemPromptWithEnvDetails()`](../../claude-code-source/src/constants/prompts.ts#L760-L791) 在 `existingSystemPrompt` 基础上追加三个块：

```typescript
// src/constants/prompts.ts#L760-L791
export async function enhanceSystemPromptWithEnvDetails(
  existingSystemPrompt: string[], model, additionalWorkingDirectories?, enabledToolNames?,
): Promise<string[]> {
  const notes = `Notes:
- Agent threads always have their cwd reset between bash calls, as a result please only use absolute file paths.
- In your final response, share file paths (always absolute, never relative) that are relevant to the task. Include code snippets only when the exact text is load-bearing...
- For clear communication with the user the assistant MUST avoid using emojis.
- Do not use a colon before tool calls. ...`

  const discoverSkillsGuidance = ...  // 条件：EXPERIMENTAL_SKILL_SEARCH 特性开启

  const envInfo = await computeEnvInfo(model, additionalWorkingDirectories)

  return [
    ...existingSystemPrompt,              // [0] MD 正文 (+ 记忆)
    notes,                                // [1] 通用行为规范
    ...(discoverSkillsGuidance ?? []),    // [2] 技能发现指引（条件）
    envInfo,                              // [3] 环境信息
  ]
}
```

**`notes` 块内容**：

```
Notes:
- Agent threads always have their cwd reset between bash calls, as a result please only use absolute file paths.
- In your final response, share file paths (always absolute, never relative) that are relevant to the task. Include code snippets only when the exact text is load-bearing (e.g., a bug you found, a function signature the caller asked for) — do not recap code you merely read.
- For clear communication with the user the assistant MUST avoid using emojis.
- Do not use a colon before tool calls. Text like "Let me read the file:" followed by a read tool call should just be "Let me read the file." with a period.
```

**`envInfo` 块内容**（由 [`computeEnvInfo()`](../../claude-code-source/src/constants/prompts.ts#L606-L649) 生成）：

```
Here is useful information about the environment you are running in:
<env>
Working directory: /path/to/project
Is directory a git repo: Yes
Platform: darwin
Shell: zsh
OS Version: Darwin 25.3.0
</env>
You are powered by the model named Claude Sonnet 4.6. The exact model ID is claude-sonnet-4-6-20250514.
Assistant knowledge cutoff is August 2025.
```

**Step 5 — asSystemPrompt() 类型包装**

[`asSystemPrompt()`](../../claude-code-source/src/utils/systemPromptType.ts#L12-L14) 将 `string[]` 包装为品牌类型 `SystemPrompt`（`string[] & { __brand: 'SystemPrompt' }`），仅做类型标记，不修改内容：

```typescript
// src/utils/systemPromptType.ts#L12-L14
export function asSystemPrompt(value: readonly string[]): SystemPrompt {
  return value as SystemPrompt
}
```

**Step 6 — buildSystemPromptBlocks() 转为 API 文本块**

[`buildSystemPromptBlocks()`](../../claude-code-source/src/services/api/claude.ts#L3213-L3237) 将 `SystemPrompt` 数组转换为 Anthropic API 的 `TextBlockParam[]`。调用 [`splitSysPromptPrefix()`](../../claude-code-source/src/utils/api.ts#L321) 进行缓存分割：

```typescript
// src/services/api/claude.ts#L3213-L3237
export function buildSystemPromptBlocks(systemPrompt, enablePromptCaching, options?): TextBlockParam[] {
  return splitSysPromptPrefix(systemPrompt, options).map(block => ({
    type: 'text',
    text: block.text,
    ...(enablePromptCaching && block.cacheScope !== null && {
      cache_control: getCacheControl({ scope: block.cacheScope, querySource: options?.querySource })
    }),
  }))
}
```

子 Agent 没有静态/动态边界（`SYSTEM_PROMPT_DYNAMIC_BOUNDARY`），所有块合并后分配缓存控制策略。

**Step 7 — 最终 API 请求**

```json
{
  "model": "claude-sonnet-4-6-20250514",
  "system": [
    {
      "type": "text",
      "text": "你是 code-reviewer，一个专业的代码审查助手。\n\n## 职责\n- 审查代码变更的安全性和正确性\n...\n\n# Persistent Agent Memory\n...",
      "cache_control": { "type": "ephemeral" }
    },
    {
      "type": "text",
      "text": "Notes:\n- Agent threads always have their cwd reset between bash calls...",
      "cache_control": { "type": "ephemeral" }
    },
    {
      "type": "text",
      "text": "Here is useful information about the environment you are running in:\n<env>\nWorking directory: /path/to/project\n...",
      "cache_control": { "type": "ephemeral" }
    }
  ],
  "messages": [
    {
      "role": "user",
      "content": "请审查 src/utils/auth.ts 的最新变更"
    }
  ],
  "tools": [...]
}
```

#### 3.3 MD 正文不是完整提示词的三层原因

1. **Frontmatter 元数据不进入系统提示词**：`name`、`description`、`tools`、`model` 等字段在解析时被提取为结构化数据，用于工具过滤、模型选择、Agent 发现等，不作为文本注入提示词

2. **系统追加通用规范**：`enhanceSystemPromptWithEnvDetails()` 在 MD 正文之后追加 `Notes` 和 `envInfo`，这些是所有子 Agent 共享的通用指令，不需要在每个 MD 文件中重复

3. **对话上下文独立注入**：用户任务（`prompt` 参数）、Skill 预加载内容、Hook 附加上下文等作为**用户消息**注入 `messages` 数组，不在系统提示词中

### 4. 子 Agent 系统提示词 vs 主会话系统提示词

| 对比项 | 主会话（主 Agent） | 子 Agent |
|--------|--------|----------|
| 系统提示词数量 | ~15-20 个块 | 3-4 个块 |
| 身份定义 | `getSimpleIntroSection()` + 完整工具说明 | MD 正文 或 内置 Agent 的 `getSystemPrompt()` |
| 环境/平台信息 | `computeSimpleEnvInfo()`（含模型家族 ID、Claude Code 产品信息） | `computeEnvInfo()`（精简版，无产品推广信息） |
| 代码行为指引 | 完整的 `getSimpleDoingTasksSection()`、`getActionsSection()`、`getUsingYourToolsSection()` | 仅 `Notes` 4 条通用规则 |
| 风格/语气指引 | `getSimpleToneAndStyleSection()` + `getOutputEfficiencySection()` | 无（依赖 MD 正文自行定义） |
| CLAUDE.md | 完整加载 | 只读 Agent（Explore/Plan）省略，其他 Agent 完整加载 |
| 记忆系统 | 主会话记忆 (`loadMemoryPrompt()`) | Agent 专属记忆 (`loadAgentMemoryPrompt()`)，独立目录 |
| 缓存分割 | 静态/动态边界 (`SYSTEM_PROMPT_DYNAMIC_BOUNDARY`) | 无边界，所有块一起缓存 |
| MCP 指引 | `getMcpInstructionsSection()` | 无（MCP 工具直接在 tools 中定义） |
| 技能发现 | 条件包含 | 条件包含（相同逻辑） |
| 模型信息 | 含 Claude 模型家族 ID 和产品广告 | 仅含当前模型名和截止日期 |
| 默认回退 | — | `DEFAULT_AGENT_PROMPT`（`getSystemPrompt()` 异常时） |

**本质区别**：

- 主会话的系统提示词是**框架控制的**——由 `getSystemPrompt()` 函数组装约 15-20 个预定义块，用户只能通过 CLAUDE.md 和设置文件间接影响内容
- 子 Agent 的系统提示词是**用户定义的**——MD 正文占据系统提示词的第一个（也是最重要的）位置，是 Agent 的"身份核心"，框架仅追加通用规范和环境信息

这意味着：

- MD 正文的质量直接决定子 Agent 的行为质量
- 子 Agent 不继承主会话的代码行为指引、风格/语气指引，需要在 MD 正文中自行定义
- `DEFAULT_AGENT_PROMPT` 仅在 `getSystemPrompt()` 异常时作为兜底，正常情况下不会使用

### 5. 上下文裁剪

对于只读 Agent（Explore、Plan），[`runAgent()`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L390-L410) 会省略 CLAUDE.md 和 gitStatus：

```typescript
// src/tools/AgentTool/runAgent.ts#L390-L410
const shouldOmitClaudeMd = agentDefinition.omitClaudeMd &&
  !override?.userContext &&
  getFeatureValue_CACHED_MAY_BE_STALE('tengu_slim_subagent_claudemd', true)
const { claudeMd: _omittedClaudeMd, ...userContextNoClaudeMd } = baseUserContext
const resolvedUserContext = shouldOmitClaudeMd ? userContextNoClaudeMd : baseUserContext

// Explore/Plan 也省略 gitStatus（最多 40KB，且是过时的）
const { gitStatus: _omittedGitStatus, ...systemContextNoGit } = baseSystemContext
const resolvedSystemContext =
  agentDefinition.agentType === 'Explore' || agentDefinition.agentType === 'Plan'
    ? systemContextNoGit : baseSystemContext
```

节省量：
- CLAUDE.md 省略：约 5-15 Gtok/week（34M+ Explore 调用）
- gitStatus 省略：约 1-3 Gtok/week

### 6. 子 Agent 不继承父对话历史

除 Fork 路径外，子 Agent 启动时**不继承**父 Agent 的对话历史：

```
父 Agent 的对话历史 ← 不传递给子 Agent
                ↓
Agent 工具的 prompt 参数 → 作为子 Agent 的初始用户消息
                ↓
子 Agent 从零开始，仅拥有：
  - 系统提示词（MD 正文 + 环境增强）
  - 工具池（按 Agent 定义过滤）
  - 用户任务描述（prompt 参数）
```

### 7. 工具解析详解

#### 7.1 工具过滤层级

[`filterToolsForAgent()`](../../claude-code-source/src/tools/AgentTool/agentToolUtils.ts#L70-L116) 对可用工具进行多层过滤：

```typescript
// src/tools/AgentTool/agentToolUtils.ts#L70-L116
export function filterToolsForAgent({ tools, isBuiltIn, isAsync, permissionMode }): Tools {
  return tools.filter(tool => {
    // MCP 工具始终允许
    if (tool.name.startsWith('mcp__')) return true
    // Plan 模式允许 ExitPlanMode
    if (toolMatchesName(tool, EXIT_PLAN_MODE_V2_TOOL_NAME) && permissionMode === 'plan') return true
    // 所有 Agent 禁用的工具
    if (ALL_AGENT_DISALLOWED_TOOLS.has(tool.name)) return false
    // 自定义 Agent 额外禁用的工具
    if (!isBuiltIn && CUSTOM_AGENT_DISALLOWED_TOOLS.has(tool.name)) return false
    // 异步 Agent 只允许特定工具
    if (isAsync && !ASYNC_AGENT_ALLOWED_TOOLS.has(tool.name)) {
      // 进程内 Teammate 例外：允许 Agent 和任务工具
      if (isAgentSwarmsEnabled() && isInProcessTeammate()) {
        if (toolMatchesName(tool, AGENT_TOOL_NAME)) return true
        if (IN_PROCESS_TEAMMATE_ALLOWED_TOOLS.has(tool.name)) return true
      }
      return false
    }
    return true
  })
}
```

#### 7.2 工具禁用列表

| 常量 | 适用范围 | 禁用工具示例 |
|------|----------|-------------|
| `ALL_AGENT_DISALLOWED_TOOLS` | 所有子 Agent | Agent（嵌套）、某些管理工具 |
| `CUSTOM_AGENT_DISALLOWED_TOOLS` | 非内置 Agent | Agent、某些特权工具 |
| `ASYNC_AGENT_ALLOWED_TOOLS` | 异步 Agent | 白名单：Read, Grep, Glob, Bash 等 |

#### 7.3 resolveAgentTools() 完整流程

```typescript
// src/tools/AgentTool/agentToolUtils.ts#L122-L225
export function resolveAgentTools(agentDefinition, availableTools, isAsync, isMainThread): ResolvedAgentTools {
  // 1. 过滤基础工具池
  const filteredAvailableTools = isMainThread
    ? availableTools
    : filterToolsForAgent({ tools: availableTools, isBuiltIn: source === 'built-in', isAsync, permissionMode })

  // 2. 应用 disallowedTools 黑名单
  const disallowedToolSet = new Set(disallowedTools?.map(toolSpec => {
    const { toolName } = permissionRuleValueFromString(toolSpec)
    return toolName
  }) ?? [])
  const allowedAvailableTools = filteredAvailableTools.filter(tool => !disallowedToolSet.has(tool.name))

  // 3. tools 为 undefined 或 ['*'] → 允许所有
  const hasWildcard = agentTools === undefined || (agentTools.length === 1 && agentTools[0] === '*')
  if (hasWildcard) {
    return { hasWildcard: true, validTools: [], invalidTools: [], resolvedTools: allowedAvailableTools }
  }

  // 4. 按 tools 白名单匹配
  for (const toolSpec of agentTools) {
    const { toolName, ruleContent } = permissionRuleValueFromString(toolSpec)
    // Agent(x,y) 语法提取 allowedAgentTypes
    if (toolName === AGENT_TOOL_NAME) {
      if (ruleContent) allowedAgentTypes = ruleContent.split(',').map(s => s.trim())
      if (!isMainThread) { validTools.push(toolSpec); continue }
    }
    const tool = availableToolMap.get(toolName)
    if (tool) { validTools.push(toolSpec); resolved.push(tool) }
    else { invalidTools.push(toolSpec) }
  }

  return { hasWildcard: false, validTools, invalidTools, resolvedTools: resolved, allowedAgentTypes }
}
```

### 8. 完整的子 Agent 初始化序列

1. **模型解析**：`getAgentModel()` 根据优先级确定模型（调用方指定 > Agent 定义 > 主循环模型 > 默认）
2. **上下文裁剪**：省略 CLAUDE.md 和/或 gitStatus
3. **权限模式覆盖**：Agent 定义的 `permissionMode` 覆盖父级（除非父级是 bypassPermissions/acceptEdits/auto）
4. **工具解析**：`resolveAgentTools()` 根据白名单/黑名单/异步限制过滤工具
5. **MCP 服务器初始化**：连接 Agent 专属 MCP 服务器，合并到父级 MCP 客户端
6. **技能预加载**：加载 Agent 定义中指定的技能，注入初始消息
7. **钩子注册**：注册 Agent 的生命周期钩子（SubagentStart 等）
8. **系统提示词构建**：Agent 提示词 + 环境增强
9. **上下文创建**：`createSubagentContext()` 创建独立的工具使用上下文
10. **查询循环**：`query()` 驱动 LLM 对话，yield 消息

---

## 四、全景：同一份 MD 文档的两个上下文

同一份 MD 文档在主会话和子 Agent 中扮演完全不同的角色——在主会话中仅暴露 `name` + `description` + `tools` 作为一行摘要，在子 Agent 中则以完整正文作为系统提示词的核心。

### 1. 信息流全景

```
code-reviewer.md
├── Frontmatter
│   ├── name: "code-reviewer"          ─┐
│   ├── description: "审查代码变更..."   │ 仅这三个字段进入主会话
│   ├── tools: [Read, Grep, Bash]     ─┘ (作为 Agent 列表行)
│   ├── model: sonnet                   ─┐
│   ├── memory: project                  │ 这些字段只在子 Agent 运行时使用
│   ├── ...                             ─┘
│
└── Markdown 正文
    "你是 code-reviewer..."             ← 仅进入子 Agent 的系统提示词

═══════════════════════════════════════════════════════════════════

主会话 LLM 看到的：
  tools[i].description 内或 <system-reminder> 中：
    "- code-reviewer: 审查代码变更并提供改进建议 (Tools: Read, Grep, Bash)"
  （一行摘要，不含 MD 正文）

═══════════════════════════════════════════════════════════════════

子 Agent LLM 看到的：
  system[0]：
    "你是 code-reviewer，一个专业的代码审查助手。
     ## 职责
     - 审查代码变更的安全性和正确性
     ...
     # Persistent Agent Memory
     ..."
  system[1]：
    "Notes: ..."
  system[2]：
    "Here is useful information about the environment..."
  （完整 MD 正文 + 系统增强，不含 name/description 摘要）
```

### 2. 两种注入模式下 MD 字段的位置差异

**模式 A（内嵌到工具描述，默认）**：

Agent 列表作为 `Agent` 工具的 `description` 字段的一部分，位于 Anthropic API 请求的 `tools` 数组中：

```
Anthropic Messages API
├── system: SystemPrompt          ← 主会话系统提示词（不含子 Agent 信息）
│   ├── intro section
│   ├── system section
│   ├── ...
├── messages: Message[]           ← 对话消息
│   ├── <system-reminder> ...     ← 其他附件（不含 agent_listing_delta）
│   └── ...
└── tools: Tool[]                 ← 工具定义
    ├── Agent: {                  ← Agent 工具
    │     name: "Agent",
    │     description: "Launch a new agent...
    │       Available agent types...:
    │       - code-reviewer: 审查代码变更... (Tools: Read, Grep, Bash)  ← MD 的 name+description+tools
    │       - Explore: Fast agent... (Tools: ...)
    │       ..."
    │   }
    ├── Read: { ... }
    └── ...
```

**模式 B（附件消息，`tengu_agent_list_attach` 启用时）**：

Agent 列表作为 `<system-reminder>` 包裹的用户消息注入 `messages` 数组：

```
Anthropic Messages API
├── system: SystemPrompt          ← 主会话系统提示词（不含子 Agent 信息）
├── messages: Message[]
│   ├── <system-reminder>         ← agent_listing_delta 附件
│   │   Available agent types for the Agent tool:
│   │   - code-reviewer: 审查代码变更... (Tools: Read, Grep, Bash)   ← MD 的 name+description+tools
│   │   - Explore: Fast agent... (Tools: ...)
│   │ </system-reminder>
│   ├── [用户消息]
│   └── ...
└── tools: Tool[]                 ← Agent 工具描述是静态的
    ├── Agent: {
    │     name: "Agent",
    │     description: "Launch a new agent...
    │       Available agent types are listed in <system-reminder> messages..."  ← 静态指引
    │   }
    └── ...
```

---

## 五、总结

| 环节 | 机制 | 关键源码 |
|------|------|----------|
| **主 Agent 视角** | | |
| Agent 列表注入 | 工具描述内嵌 / `agent_listing_delta` 附件 | [`prompt.ts#L59-L64`](../../claude-code-source/src/tools/AgentTool/prompt.ts#L59-L64) |
| 列表格式化 | `- agentType: whenToUse (Tools: ...)` | [`formatAgentLine()`](../../claude-code-source/src/tools/AgentTool/prompt.ts#L43-L46) |
| MD 字段在主会话中的去向 | `name`+`description`+`tools` → 工具描述/附件消息；MD 正文不进入主会话 | [`formatAgentLine()`](../../claude-code-source/src/tools/AgentTool/prompt.ts#L43-L46) |
| 增量差异计算 | 对比当前 Agent 池与已公告集合 | [`getAgentListingDeltaAttachment()`](../../claude-code-source/src/utils/attachments.ts#L1490-L1556) |
| 附件→LLM 文本 | `<system-reminder>` 包裹的用户消息 | [`messages.ts#L4194-L4213`](../../claude-code-source/src/utils/messages.ts#L4194-L4213) |
| LLM 选择 | 基于 `whenToUse` + 示例 + 用户意图，设置 `subagent_type` | 依赖 LLM 推理 |
| 工具描述生成 | 共享核心 + 不使用场景 + 使用说明 + 示例 | [`getPrompt()`](../../claude-code-source/src/tools/AgentTool/prompt.ts#L66-L287) |
| **子 Agent 视角** | | |
| 系统提示词构建 | MD 正文（身份核心）+ Notes + envInfo（系统追加） | [`getAgentSystemPrompt()`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L906-L932) + [`enhanceSystemPromptWithEnvDetails()`](../../claude-code-source/src/constants/prompts.ts#L760-L791) |
| MD 正文定位 | 系统提示词数组 [0]，仅是第一个块；在主会话中完全不出现 | [`parseAgentFromMarkdown()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L713) |
| 工具过滤 | 多层：全局禁用 > 自定义禁用 > 异步白名单 > 黑名单 > 白名单 | [`filterToolsForAgent()`](../../claude-code-source/src/tools/AgentTool/agentToolUtils.ts#L70-L116) |
| 权限控制 | MCP 过滤 + 权限拒绝 + allowedAgentTypes | [`AgentTool.prompt()`](../../claude-code-source/src/tools/AgentTool/AgentTool.tsx#L197-L224) |
| **全景** | | |
| 同一 MD 的双重视角 | 主会话：`name`+`description`+`tools` 一行摘要；子 Agent：完整正文作为 system[0] | — |

---
*本文档由 markdowncli 技能辅助生成*

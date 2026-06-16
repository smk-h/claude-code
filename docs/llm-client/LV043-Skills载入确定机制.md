<!-- more -->

## 一、 概述

本文档分析 Claude Code 中如何确定载入哪些 Skills——从启动时的全量发现，到条件激活、动态发现、skill-search 检索等多层机制，以及模型如何从列表中选中特定的 skill。

## 二、 载入确定的四个层次

### 1. 启动时全量发现

会话启动时，[`getSkillDirCommands()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L638-L804) 并行扫描所有 skill 目录，将发现的 skills 分为两类：

```typescript
// src/skills/loadSkillsDir.ts#L771-L802
const unconditionalSkills: Command[] = []
const newConditionalSkills: Command[] = []
for (const skill of deduplicatedSkills) {
  if (
    skill.type === 'prompt' &&
    skill.paths &&
    skill.paths.length > 0 &&
    !activatedConditionalSkillNames.has(skill.name)
  ) {
    newConditionalSkills.push(skill)  // 有 paths 条件的 skill
  } else {
    unconditionalSkills.push(skill)    // 无条件的 skill
  }
}
// 无条件 skills 立即可用
// 条件 skills 存入 conditionalSkills Map，等待激活
for (const skill of newConditionalSkills) {
  conditionalSkills.set(skill.name, skill)
}
return unconditionalSkills
```

- **无条件 skills**：直接返回，立即可用
- **条件 skills**（带 `paths` frontmatter）：存入 `conditionalSkills` Map，等待路径匹配激活

### 2. 条件激活（paths 匹配）

[`activateConditionalSkillsForPaths()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L997-L1058) 在文件操作时检查条件 skills：

```typescript
// src/skills/loadSkillsDir.ts#L1007-L1041
for (const [name, skill] of conditionalSkills) {
  if (skill.type !== 'prompt' || !skill.paths || skill.paths.length === 0) continue

  const skillIgnore = ignore().add(skill.paths)
  for (const filePath of filePaths) {
    const relativePath = isAbsolute(filePath) ? relative(cwd, filePath) : filePath
    // 跳过无效路径（空、.. 开头、绝对路径）
    if (!relativePath || relativePath.startsWith('..') || isAbsolute(relativePath)) continue

    if (skillIgnore.ignores(relativePath)) {
      // 激活：移入 dynamicSkills
      dynamicSkills.set(name, skill)
      conditionalSkills.delete(name)
      activatedConditionalSkillNames.add(name)
      activated.push(name)
      break
    }
  }
}
```

激活后的 skill 会触发 `skillsLoaded` 信号，通知监听者清除缓存：

```typescript
// src/skills/loadSkillsDir.ts#L1043-L1055
if (activated.length > 0) {
  skillsLoaded.emit()
}
```

### 3. 动态目录发现

[`discoverSkillDirsForPaths()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L861-L915) 在 Read/Write/Edit 等文件操作时，从操作文件路径向上遍历，发现 `cwd` 下方尚未加载的 `.claude/skills/` 目录：

```typescript
// src/skills/loadSkillsDir.ts#L869-L908
for (const filePath of filePaths) {
  let currentDir = dirname(filePath)
  // 从文件目录向上遍历至 cwd（不含 cwd 本身）
  while (currentDir.startsWith(resolvedCwd + pathSep)) {
    const skillDir = join(currentDir, '.claude', 'skills')
    if (!dynamicSkillDirs.has(skillDir)) {
      dynamicSkillDirs.add(skillDir)
      try {
        await fs.stat(skillDir)
        if (await isPathGitignored(currentDir, resolvedCwd)) continue  // 跳过 gitignored
        newDirs.push(skillDir)
      } catch { /* 目录不存在 */ }
    }
    const parent = dirname(currentDir)
    if (parent === currentDir) break
    currentDir = parent
  }
}
// 按深度降序排列，更深的目录优先级更高
return newDirs.sort((a, b) => b.split(pathSep).length - a.split(pathSep).length)
```

发现的目录通过 [`addSkillDirectories()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L923-L975) 加载 skills 并合并到 `dynamicSkills`：

```typescript
// src/skills/loadSkillsDir.ts#L944-L951
// 反序处理（浅层先），更深的路径后覆盖
for (let i = loadedSkills.length - 1; i >= 0; i--) {
  for (const { skill } of loadedSkills[i] ?? []) {
    if (skill.type === 'prompt') {
      dynamicSkills.set(skill.name, skill)
    }
  }
}
```

### 4. Skill Search（实验性远程发现）

当 `EXPERIMENTAL_SKILL_SEARCH` feature 启用时，系统支持从远程（AKI/GCS）搜索 skills：

- `getTurnZeroSkillDiscovery()`：首轮用户输入触发
- `startSkillDiscoveryPrefetch()`：轮间异步预取
- `DiscoverSkills` 工具：模型主动搜索

## 三、 模型如何选中 Skill

模型通过 SkillTool 的描述和 skill_listing 信息选择 skill：

### 1. SkillTool 的提示词

[`getPrompt()`](../../claude-code-source/src/tools/SkillTool/prompt.ts#L173-L196) 提供调用指引：

```
Execute a skill within the main conversation

When users ask you to perform tasks, check if any of the available skills match.

How to invoke:
- skill: "pdf" - invoke the pdf skill
- skill: "commit", args: "-m 'Fix bug'" - invoke with arguments

Important:
- Available skills are listed in system-reminder messages in the conversation
- When a skill matches the user's request, this is a BLOCKING REQUIREMENT:
  invoke the relevant Skill tool BEFORE generating any other response
- NEVER mention a skill without actually calling this tool
```

### 2. Skill 列表格式

列表中每条 skill 的格式为：

```
- skill-name: description - whenToUse
```

其中 `description + whenToUse` 的组合受 `MAX_LISTING_DESC_CHARS = 250` 字符限制。

### 3. 系统提示词中的 Skill 引导

在 [`getSessionSpecificGuidanceSection()`](../../claude-code-source/src/constants/prompts.ts#L382-L384) 中，有针对 skill 的使用指引：

```typescript
// src/constants/prompts.ts#L382-L384
hasSkills
  ? `/<skill-name> (e.g., /commit) is shorthand for users to invoke a user-invocable skill. 
     When executed, the skill gets expanded to a full prompt. Use the ${SKILL_TOOL_NAME} tool 
     to execute them. IMPORTANT: Only use ${SKILL_TOOL_NAME} for skills listed in its 
     user-invocable skills section - do not guess or use built-in CLI commands.`
  : null
```

## 四、 载入流程总览

```
启动阶段:
  getSkillDirCommands(cwd)
    ├─ loadSkillsFromSkillsDir(managedDir)     → managed skills
    ├─ loadSkillsFromSkillsDir(userDir)         → user skills
    ├─ loadSkillsFromSkillsDir(projectDirs)     → project skills
    ├─ loadSkillsFromSkillsDir(addDir/.claude/skills) → additional skills
    ├─ loadSkillsFromCommandsDir(cwd)           → legacy commands
    ├─ 去重（realpath 去重）
    ├─ 分离无条件/条件 skills
    └─ 返回无条件 skills

运行时:
  文件操作 → discoverSkillDirsForPaths()
            → addSkillDirectories()  → dynamicSkills

  文件操作 → activateConditionalSkillsForPaths()
            → conditionalSkills → dynamicSkills

每轮对话:
  getSkillListingAttachments()
    ├─ getSkillToolCommands(cwd)  → 所有可用 skills
    ├─ 过滤已发送的 skills
    └─ formatCommandsWithinBudget() → system-reminder

模型调用:
  SkillTool.call(skill, args)
    → command.getPromptForCommand(args, ctx) → 完整正文注入
```

## 五、 实例分析：markdowncli skill 的载入确定

以 `~/.claude/skills/markdowncli/SKILL.md` 为例，展示该 skill 如何被确定为"需要载入"。

### 1. Frontmatter 决定载入类型

`markdowncli` 的 frontmatter：

```yaml
# ~/.claude/skills/markdowncli/SKILL.md 第 1-4 行
---
name: markdowncli
description: 按照指定的格式规范创建和修改Markdown文档
---
```

关键特征：**没有 `paths` 字段**，因此该 skill 被分类为**无条件 skill**：

```typescript
// src/skills/loadSkillsDir.ts#L771-L802
const unconditionalSkills: Command[] = []
const newConditionalSkills: Command[] = []
for (const skill of deduplicatedSkills) {
  if (
    skill.type === 'prompt' &&
    skill.paths &&           // ← markdowncli.paths = undefined
    skill.paths.length > 0   // ← undefined.length 会报错，但短路求值已跳过
  ) {
    newConditionalSkills.push(skill)
  } else {
    unconditionalSkills.push(skill)  // ← markdowncli 走这里
  }
}
```

### 2. 载入路径——无条件 skill

```
markdowncli 的载入路径:

启动阶段:
  getSkillDirCommands(cwd)
    ├─ loadSkillsFromSkillsDir(/root/.claude/skills/)  → 发现 markdowncli
    ├─ 分类: 无 paths → unconditionalSkills
    └─ 直接返回，立即可用

运行时:
  无需 activateConditionalSkillsForPaths()  (非条件 skill)
  无需 discoverSkillDirsForPaths()          (已在启动时发现)

每轮对话:
  getSkillListingAttachments()
    ├─ getSkillToolCommands(cwd) → 包含 markdowncli
    ├─ sent.has('markdowncli')?  → 首次 false，后续 true
    └─ formatCommandsWithinBudget() → 注入列表
```

### 3. 与条件 skill 的对比

假设 `markdowncli` 如果添加了 `paths` 字段：

```yaml
---
name: markdowncli
description: 按照指定的格式规范创建和修改Markdown文档
paths:
  - "**/*.md"
---
```

那么载入路径将变为：

```
启动阶段:
  getSkillDirCommands(cwd)
    ├─ loadSkillsFromSkillsDir(/root/.claude/skills/)  → 发现 markdowncli
    ├─ 分类: 有 paths → conditionalSkills
    └─ 不在无条件列表中返回

运行时:
  activateConditionalSkillsForPaths(["/root/claude-code/docs/llm-client/LV024-Skills目录扫描机制.md"])
    ├─ skillIgnore.ignores("docs/llm-client/LV024-Skills目录扫描机制.md")
    ├─ "**/*.md" 匹配成功 → 激活
    └─ conditionalSkills → dynamicSkills, skillsLoaded.emit()
```

但当前实际的 `markdowncli` 无 `paths`，所以**始终立即可用**，不需要任何文件操作触发。

### 4. 模型选中过程

当用户输入 `@command://markdowncli 帮我分析...` 时：

1. 模型看到 skill 列表中的 `- markdowncli: 按照指定的格式规范创建和修改Markdown文档`
2. `@command://markdowncli` 是显式调用信号
3. 模型调用 `SkillTool(name="markdowncli", args="帮我分析一下skills是怎么被读入上下文")`
4. SkillTool 执行 → 完整 279 行正文注入上下文

如果是**隐式匹配**（用户未使用 `@command://`），模型需自行判断：

- 用户说"帮我创建 md 文档" → 模型查看 `whenToUse`（`markdowncli` 未设置该字段）→ 匹配 description 关键词 → 可能调用
- SkillTool 提示词强调："When a skill matches the user's request, this is a BLOCKING REQUIREMENT: invoke the relevant Skill tool BEFORE generating any other response"

---

*本文档由 markdowncli 技能辅助生成*

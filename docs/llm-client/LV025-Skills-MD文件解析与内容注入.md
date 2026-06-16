<!-- more -->

## 一、 概述

本文档分析 Claude Code 中 Skills 的 MD 文件解析机制——SKILL.md 文件如何被解析，哪些内容进入上下文，以及 frontmatter 中各字段的作用。

## 二、 SKILL.md 文件格式要求

Skills 目录仅支持**目录格式**：

```typescript
// src/skills/loadSkillsDir.ts#L424-L428
// Only support directory format: skill-name/SKILL.md
if (!entry.isDirectory() && !entry.isSymbolicLink()) {
  // Single .md files are NOT supported in /skills/ directory
  return null
}
```

即每个 skill 必须为 `<skills-dir>/<skill-name>/SKILL.md` 的结构，单独的 `.md` 文件在 `/skills/` 目录下不被支持。

## 三、 Frontmatter 解析

### 1. 解析入口

```typescript
// src/skills/loadSkillsDir.ts#L447-L449
const { frontmatter, content: markdownContent } = parseFrontmatter(
  content,
  skillFilePath,
)
```

[`parseFrontmatter()`](../../claude-code-source/src/utils/frontmatterParser.ts#L130-L149) 使用正则 `FRONTMATTER_REGEX = /^---\s*\n([\s\S]*?)---\s*\n?/` 提取 YAML 头部，返回两个部分：

- `frontmatter`：解析后的 YAML 键值对象
- `content`：剥离 frontmatter 后的 **Markdown 正文内容**

```typescript
// src/utils/frontmatterParser.ts#L130-L149
export function parseFrontmatter(markdown: string, sourcePath?: string): ParsedMarkdown {
  const match = markdown.match(FRONTMATTER_REGEX)
  if (!match) {
    return { frontmatter: {}, content: markdown }
  }
  const frontmatterText = match[1] || ''
  const content = markdown.slice(match[0].length)
  // ... YAML 解析
}
```

### 2. 注入上下文的是哪一部分

【**关键结论**】注入 LLM 上下文的是**剥离 frontmatter 后的 Markdown 正文**（即 `markdownContent`），而非整个文件。frontmatter 中的元数据仅用于构建 skill 的描述信息（name、description、whenToUse 等），供 skill 发现与选择使用。

## 四、 Frontmatter 字段解析

[`parseSkillFrontmatterFields()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L185-L265) 解析以下字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `name` | `string` | 显示名称，覆盖目录名 |
| `description` | `string` | 技能描述，用于 skill 列表 |
| `when_to_use` | `string` | 使用时机提示，附加在描述后 |
| `allowed-tools` | `string/string[]` | 允许的工具列表 |
| `arguments` | `string/string[]` | 参数名列表 |
| `argument-hint` | `string` | 参数提示文本 |
| `user-invocable` | `boolean` | 是否可由用户调用（默认 `true`） |
| `disable-model-invocation` | `boolean` | 禁止模型调用 |
| `model` | `string` | 模型覆盖 |
| `effort` | `string/number` | 工作量级别 |
| `context` | `'fork'` | 执行上下文（fork = 子 Agent） |
| `agent` | `string` | Agent 类型 |
| `hooks` | `HooksSettings` | 生命周期钩子 |
| `paths` | `string/string[]` | 条件激活的文件路径模式 |
| `shell` | `FrontmatterShell` | Shell 执行配置 |
| `version` | `string` | 版本号 |

### 1. description 的降级策略

如果 frontmatter 未提供 `description`，系统会从 Markdown 正文自动提取：

```typescript
// src/skills/loadSkillsDir.ts#L208-L214
const validatedDescription = coerceDescriptionToString(frontmatter.description, resolvedName)
const description =
  validatedDescription ??
  extractDescriptionFromMarkdown(markdownContent, descriptionFallbackLabel)
```

[`extractDescriptionFromMarkdown()`](../../claude-code-source/src/utils/markdownConfigLoader.ts#L52-L69) 取正文第一个非空行作为描述，如果是标题则去除 `#` 前缀，且限制在 100 字符以内。

### 2. paths 字段的条件匹配

```typescript
// src/skills/loadSkillsDir.ts#L159-L178
function parseSkillPaths(frontmatter: FrontmatterData): string[] | undefined {
  if (!frontmatter.paths) return undefined
  const patterns = splitPathInFrontmatter(frontmatter.paths)
    .map(pattern => pattern.endsWith('/**') ? pattern.slice(0, -3) : pattern)
    .filter((p: string) => p.length > 0)
  if (patterns.length === 0 || patterns.every((p: string) => p === '**')) return undefined
  return patterns
}
```

- 移除 `/**` 后缀（`ignore` 库会自动匹配目录内所有内容）
- 全匹配模式 `**` 等同于无条件

## 五、 Skill Command 对象构建

[`createSkillCommand()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L270-L401) 将解析后的数据构建为 `Command` 对象，其中最核心的方法是 [`getPromptForCommand()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L344-L398)：

```typescript
// src/skills/loadSkillsDir.ts#L344-L398
async getPromptForCommand(args, toolUseContext) {
  let finalContent = baseDir
    ? `Base directory for this skill: ${baseDir}\n\n${markdownContent}`
    : markdownContent

  // 参数替换
  finalContent = substituteArguments(finalContent, args, true, argumentNames)

  // ${CLAUDE_SKILL_DIR} 替换
  if (baseDir) {
    const skillDir = process.platform === 'win32' ? baseDir.replace(/\\/g, '/') : baseDir
    finalContent = finalContent.replace(/\$\{CLAUDE_SKILL_DIR\}/g, skillDir)
  }

  // ${CLAUDE_SESSION_ID} 替换
  finalContent = finalContent.replace(/\$\{CLAUDE_SESSION_ID\}/g, getSessionId())

  // MCP skills 不执行 shell 命令（安全限制）
  if (loadedFrom !== 'mcp') {
    finalContent = await executeShellCommandsInPrompt(finalContent, ...)
  }

  return [{ type: 'text', text: finalContent }]
}
```

### 1. 内容变换步骤

1. **添加 Base Directory 前缀**：如果 skill 有 `baseDir`，在正文前添加 `Base directory for this skill: <dir>`
2. **参数替换**：将 `$ARGUMENTS` 或命名参数替换为实际值
3. **变量替换**：`${CLAUDE_SKILL_DIR}` 和 `${CLAUDE_SESSION_ID}`
4. **Shell 命令执行**：处理 `!`command`` 格式的内联 shell 命令（MCP skills 除外）

## 六、 Legacy Commands 格式差异

[`loadSkillsFromCommandsDir()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L566-L623) 处理遗留的 `/commands/` 目录，与 `/skills/` 的差异：

| 特性 | `/skills/` | `/commands/` |
| --- | --- | --- |
| 目录格式 | 仅 `skill-name/SKILL.md` | `SKILL.md` + 单文件 `.md` |
| 命名空间 | 无 | 支持子目录命名空间 `ns:cmd` |
| 来源标记 | `skills` | `commands_DEPRECATED` |
| 默认描述 | "Skill" | "Custom command" |

## 七、 实例分析：markdowncli skill 的文件解析

以 `~/.claude/skills/markdowncli/SKILL.md` 为例，展示完整的解析过程。

### 1. 原始文件结构

该 SKILL.md 文件共 284 行，开头为 frontmatter，后面是完整的 Markdown 正文：

```yaml
# ~/.claude/skills/markdowncli/SKILL.md 第 1-4 行
---
name: markdowncli
description: 按照指定的格式规范创建和修改Markdown文档
---
```

### 2. Frontmatter 解析结果

[`parseFrontmatter()`](../../claude-code-source/src/utils/frontmatterParser.ts#L130-L149) 提取出两个部分：

| 部分 | 内容 |
| --- | --- |
| `frontmatter` 对象 | `{ name: "markdowncli", description: "按照指定的格式规范创建和修改Markdown文档" }` |
| `content`（Markdown 正文） | 从第 6 行 `# Skill: Markdown文档格式规范` 开始的 279 行正文 |

### 3. Frontmatter 字段映射

[`parseSkillFrontmatterFields()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L185-L265) 对该 skill 解析后的字段：

| 字段 | 值 | 说明 |
| --- | --- | --- |
| `name` | `"markdowncli"` | 覆盖目录名（目录名也叫 markdowncli，结果一致） |
| `description` | `"按照指定的格式规范创建和修改Markdown文档"` | 来自 frontmatter，未触发降级策略 |
| `when_to_use` | `undefined` | 未在 frontmatter 中指定 |
| `paths` | `undefined` | 无条件激活 |
| `user-invocable` | `true`（默认值） | 可由用户 `/markdowncli` 调用 |
| `context` | `undefined`（默认 inline） | 非 fork 模式 |

### 4. 注入上下文的内容分离

对于 `markdowncli` 这个 skill，两种注入场景下的内容截然不同：

**发现阶段——仅注入元数据摘要**：

```
- markdowncli: 按照指定的格式规范创建和修改Markdown文档
```

仅 `name` + `description`，约 30 个字符，消耗极少 token。

**调用阶段——注入完整 Markdown 正文**：

从第 6 行 `# Skill: Markdown文档格式规范` 到第 284 行末尾，共 279 行、约 6000+ 字符的完整正文，包含：

- 技能说明（第 8-10 行）
- 何时触发（第 12-27 行）
- 10 条强制格式规范（第 29-203 行）
- 行为规范（第 205-241 行）
- 创建/修改示例（第 243-283 行）

### 5. getPromptForCommand() 变换

当模型通过 SkillTool 调用 `markdowncli` 时，[`getPromptForCommand()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L344-L398) 执行以下变换：

1. **添加 Base Directory 前缀**：

   该 skill 有 `baseDir = "/root/.claude/skills/markdowncli"`，因此正文前会添加：

   ```
   Base directory for this skill: /root/.claude/skills/markdowncli
   
   # Skill: Markdown文档格式规范
   ...
   ```

2. **参数替换**：该 skill 的 `arguments` 为空，无参数需要替换

3. **`${CLAUDE_SKILL_DIR}` 替换**：正文中未使用该变量，不触发替换

4. **Shell 命令执行**：正文中无 `` !`command` `` 格式，不触发执行

最终注入的内容为 `Base directory for this skill: /root/.claude/skills/markdowncli\n\n` + 完整 279 行正文。

---

*本文档由 markdowncli 技能辅助生成*

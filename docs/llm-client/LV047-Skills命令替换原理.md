<!-- more -->

## 一、 概述

Skill 的命令替换机制在源码中由三个核心模块协作完成：

| 模块 | 职责 | 关键函数 |
| --- | --- | --- |
| [`loadSkillsDir.ts`](../../claude-code-source/src/skills/loadSkillsDir.ts) | 编排替换流程 | [`getPromptForCommand()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L344-L399) |
| [`argumentSubstitution.ts`](../../claude-code-source/src/utils/argumentSubstitution.ts) | 参数与命名参数替换 | [`substituteArguments()`](../../claude-code-source/src/utils/argumentSubstitution.ts#L94-L145) |
| [`promptShellExecution.ts`](../../claude-code-source/src/utils/promptShellExecution.ts) | Shell 命令执行与输出替换 | [`executeShellCommandsInPrompt()`](../../claude-code-source/src/utils/promptShellExecution.ts#L69-L143) |

替换发生在 Skill 被调用时——`getPromptForCommand()` 拿到原始 Markdown 正文后，按固定顺序依次执行各类变换，最终返回渲染后的内容注入对话。

### 1. 调用链定位

`getPromptForCommand()` 并非直接被 SkillTool 调用，而是通过斜杠命令处理链间接触发。完整调用链为：

```
SkillTool.call()
  → processPromptSlashCommand()           ← 入口
    → getMessagesForPromptSlashCommand()  ← 消息构建
      → command.getPromptForCommand()     ← 替换编排（本文档焦点）
```

在 [`processSlashCommand.tsx:869`](../../claude-code-source/src/utils/processUserInput/processSlashCommand.tsx#L869)，`getMessagesForPromptSlashCommand()` 调用 command 对象的 `getPromptForCommand()`：

```typescript
// src/utils/processUserInput/processSlashCommand.tsx#L869
const result = await command.getPromptForCommand(args, context);
```

返回的 `result`（`ContentBlockParam[]`）随后被包装为 `isMeta: true` 的用户消息注入对话（详见 [`processSlashCommand.tsx:902-912`](../../claude-code-source/src/utils/processUserInput/processSlashCommand.tsx#L902-L912)）。

> **前置文档**：命令替换的用法说明详见 [LV046-Skills命令替换说明与用法](LV046-Skills命令替换说明与用法.md)；Skill 正文注入的整体流程详见 [LV041-Skills-MD文件解析与内容注入](LV041-Skills-MD文件解析与内容注入.md)。

## 二、 替换流程总览

[`getPromptForCommand()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L344-L399) 是命令替换的编排入口，定义在 `createSkillCommand()` 返回的 Command 对象上：

```typescript
// src/skills/loadSkillsDir.ts#L344-L399
async getPromptForCommand(args, toolUseContext) {
  let finalContent = baseDir
    ? `Base directory for this skill: ${baseDir}\n\n${markdownContent}`
    : markdownContent

  finalContent = substituteArguments(
    finalContent,
    args,
    true,
    argumentNames,
  )

  if (baseDir) {
    const skillDir =
      process.platform === 'win32' ? baseDir.replace(/\\/g, '/') : baseDir
    finalContent = finalContent.replace(/\$\{CLAUDE_SKILL_DIR\}/g, skillDir)
  }

  finalContent = finalContent.replace(
    /\$\{CLAUDE_SESSION_ID\}/g,
    getSessionId(),
  )

  if (loadedFrom !== 'mcp') {
    finalContent = await executeShellCommandsInPrompt(
      finalContent,
      {
        ...toolUseContext,
        getAppState() {
          const appState = toolUseContext.getAppState()
          return {
            ...appState,
            toolPermissionContext: {
              ...appState.toolPermissionContext,
              alwaysAllowRules: {
                ...appState.toolPermissionContext.alwaysAllowRules,
                command: allowedTools,
              },
            },
          }
        },
      },
      `/${skillName}`,
      shell,
    )
  }

  return [{ type: 'text', text: finalContent }]
}
```

### 1. 四步替换的依赖关系

替换顺序并非任意排列，而是基于数据依赖：

| 步骤 | 替换内容 | 源码位置 | 为何在此位置 |
| --- | --- | --- | --- |
| 0 | Base Directory 前缀 | [`loadSkillsDir.ts:345-347`](../../claude-code-source/src/skills/loadSkillsDir.ts#L345-L347) | 在正文前拼接目录信息，使后续变量替换有上下文 |
| 1 | `$ARGUMENTS`、`$N`、`$name` | [`loadSkillsDir.ts:349-354`](../../claude-code-source/src/skills/loadSkillsDir.ts#L349-L354) | 必须先于 Shell 命令执行，使命令能使用已替换的参数 |
| 2 | `${CLAUDE_SKILL_DIR}` | [`loadSkillsDir.ts:359-363`](../../claude-code-source/src/skills/loadSkillsDir.ts#L359-L363) | 在 Shell 命令执行前替换，使命令能引用 Skill 目录内的脚本 |
| 3 | `${CLAUDE_SESSION_ID}` | [`loadSkillsDir.ts:366-369`](../../claude-code-source/src/skills/loadSkillsDir.ts#L366-L369) | 同上，使命令能使用会话 ID |
| 4 | `` !`command` `` | [`loadSkillsDir.ts:374-396`](../../claude-code-source/src/skills/loadSkillsDir.ts#L374-L396) | 最后执行，此时正文中的参数和变量已全部就位 |

### 2. `argumentNames` 与 `shell` 的来源

`argumentNames` 和 `shell` 都来自 frontmatter 解析阶段。[`parseSkillFrontmatterFields()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L185-L265) 在解析 SKILL.md 时提取这两个字段：

```typescript
// src/skills/loadSkillsDir.ts#L249-L251
argumentNames: parseArgumentNames(
  frontmatter.arguments as string | string[] | undefined,
),
```

```typescript
// src/skills/loadSkillsDir.ts#L263
shell: parseShellFrontmatter(frontmatter.shell, resolvedName),
```

这两个值随后通过闭包传递给 `getPromptForCommand()`，分别用于参数替换和 Shell 命令执行的 shell 选择。

## 三、 参数替换原理

参数替换由 [`argumentSubstitution.ts`](../../claude-code-source/src/utils/argumentSubstitution.ts) 实现，涉及三个函数：`parseArguments()`、`parseArgumentNames()`、`substituteArguments()`。

### 1. 参数解析：parseArguments()

[`parseArguments()`](../../claude-code-source/src/utils/argumentSubstitution.ts#L24-L40) 将原始参数字符串拆分为参数数组：

```typescript
// src/utils/argumentSubstitution.ts#L24-L40
export function parseArguments(args: string): string[] {
  if (!args || !args.trim()) {
    return []
  }

  // Return $KEY to preserve variable syntax literally (don't expand variables)
  const result = tryParseShellCommand(args, key => `$${key}`)
  if (!result.success) {
    // Fall back to simple whitespace split if parsing fails
    return args.split(/\s+/).filter(Boolean)
  }

  // Filter to only string tokens (ignore shell operators, etc.)
  return result.tokens.filter(
    (token): token is string => typeof token === 'string',
  )
}
```

#### 1.1 空参数处理

[`L25-L27`](../../claude-code-source/src/utils/argumentSubstitution.ts#L25-L27) 检查参数是否为空。注意 `!args.trim()` 同时处理了纯空白字符串的情况，返回空数组而非包含空字符串的数组。

#### 1.2 shell-quote 解析与变量保留

[`L30`](../../claude-code-source/src/utils/argumentSubstitution.ts#L30) 调用 `tryParseShellCommand()`，传入回调 `key => `$${key}``。该回调是 shell-quote 库的环境变量解析函数——当解析器遇到 `$KEY` 时，调用此函数获取替换值。

传入 `key => `$${key}`` 的效果是将 `$KEY` **原样返回**（`$` + key），即不展开任何 Shell 变量。这确保参数中的 `$HOME` 等文本保持字面形式，不被替换为环境变量值。

`tryParseShellCommand()` 本身是 shell-quote 库的安全包装，定义在 [`shellQuote.ts:24-45`](../../claude-code-source/src/utils/bash/shellQuote.ts#L24-L45)：

```typescript
// src/utils/bash/shellQuote.ts#L24-L45
export function tryParseShellCommand(
  cmd: string,
  env?:
    | Record<string, string | undefined>
    | ((key: string) => string | undefined),
): ShellParseResult {
  try {
    const tokens =
      typeof env === 'function'
        ? shellQuoteParse(cmd, env)
        : shellQuoteParse(cmd, env)
    return { success: true, tokens }
  } catch (error) {
    if (error instanceof Error) {
      logError(error)
    }
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown parse error',
    }
  }
}
```

解析失败时返回 `{ success: false }`，而非抛出异常——这是"try"前缀的语义。

#### 1.3 降级策略

[`L31-L34`](../../claude-code-source/src/utils/argumentSubstitution.ts#L31-L34) 在 shell-quote 解析失败时，降级为简单的空白分割。这保证了即使参数包含 shell-quote 无法处理的语法（如未闭合的引号），参数替换仍能工作，只是失去引号语义。

#### 1.4 token 过滤

[`L37-L39`](../../claude-code-source/src/utils/argumentSubstitution.ts#L37-L39) 过滤掉非字符串 token。shell-quote 解析会返回多种 token 类型：

- 字符串（普通参数）
- 操作符对象（如 `|`、`&&`、`>` 等 Shell 操作符）

过滤后只保留字符串参数，丢弃所有 Shell 操作符。这意味着 `/skill foo | bar` 会被解析为 `["foo", "bar"]`，`|` 被丢弃。

### 2. 命名参数解析：parseArgumentNames()

[`parseArgumentNames()`](../../claude-code-source/src/utils/argumentSubstitution.ts#L50-L68) 从 frontmatter 的 `arguments` 字段提取命名参数列表：

```typescript
// src/utils/argumentSubstitution.ts#L50-L68
export function parseArgumentNames(
  argumentNames: string | string[] | undefined,
): string[] {
  if (!argumentNames) {
    return []
  }

  // Filter out empty strings and numeric-only names (which conflict with $0, $1 shorthand)
  const isValidName = (name: string): boolean =>
    typeof name === 'string' && name.trim() !== '' && !/^\d+$/.test(name)

  if (Array.isArray(argumentNames)) {
    return argumentNames.filter(isValidName)
  }
  if (typeof argumentNames === 'string') {
    return argumentNames.split(/\s+/).filter(isValidName)
  }
  return []
}
```

#### 2.1 双格式支持

[`L61-L66`](../../claude-code-source/src/utils/argumentSubstitution.ts#L61-L66) 支持两种 frontmatter 写法：

- **字符串形式**：`arguments: foo bar baz` → 按空白分割
- **数组形式**：`arguments: [foo, bar, baz]` → 直接使用

#### 2.2 名称合法性校验

[`L58-L59`](../../claude-code-source/src/utils/argumentSubstitution.ts#L58-L59) 的 `isValidName` 过滤两类无效名称：

- 空字符串或纯空白（`name.trim() !== ''`）
- 纯数字名称（`!/^\d+$/.test(name)`）

纯数字名称被过滤是因为它们会与 `$0`、`$1` 简写形式冲突。如果允许 `arguments: 0 1`，则 `$0` 既是命名参数又是索引参数，产生歧义。

### 3. 替换核心：substituteArguments()

[`substituteArguments()`](../../claude-code-source/src/utils/argumentSubstitution.ts#L94-L145) 是参数替换的核心，按四类占位符依次替换：

```typescript
// src/utils/argumentSubstitution.ts#L94-L145
export function substituteArguments(
  content: string,
  args: string | undefined,
  appendIfNoPlaceholder = true,
  argumentNames: string[] = [],
): string {
  // undefined/null means no args provided - return content unchanged
  // empty string is a valid input that should replace placeholders with empty
  if (args === undefined || args === null) {
    return content
  }

  const parsedArgs = parseArguments(args)
  const originalContent = content

  // Replace named arguments (e.g., $foo, $bar) with their values
  // Named arguments map to positions: argumentNames[0] -> parsedArgs[0], etc.
  for (let i = 0; i < argumentNames.length; i++) {
    const name = argumentNames[i]
    if (!name) continue

    // Match $name but not $name[...] or $nameXxx (word chars)
    // Also ensure we match word boundaries to avoid partial matches
    content = content.replace(
      new RegExp(`\\$${name}(?![\\[\\w])`, 'g'),
      parsedArgs[i] ?? '',
    )
  }

  // Replace indexed arguments ($ARGUMENTS[0], $ARGUMENTS[1], etc.)
  content = content.replace(/\$ARGUMENTS\[(\d+)\]/g, (_, indexStr: string) => {
    const index = parseInt(indexStr, 10)
    return parsedArgs[index] ?? ''
  })

  // Replace shorthand indexed arguments ($0, $1, etc.)
  content = content.replace(/\$(\d+)(?!\w)/g, (_, indexStr: string) => {
    const index = parseInt(indexStr, 10)
    return parsedArgs[index] ?? ''
  })

  // Replace $ARGUMENTS with the full arguments string
  content = content.replaceAll('$ARGUMENTS', args)

  // If no placeholders were found and appendIfNoPlaceholder is true, append
  // But only if args is non-empty (empty string means command invoked with no args)
  if (content === originalContent && appendIfNoPlaceholder && args) {
    content = content + `\n\nARGUMENTS: ${args}`
  }

  return content
}
```

#### 3.1 `undefined`/`null` 与空字符串的区别

[`L102-L104`](../../claude-code-source/src/utils/argumentSubstitution.ts#L102-L104) 的早返回逻辑区分了两种情况：

- `args === undefined || args === null`：未传参数，直接返回原文，不做任何替换
- `args === ''`（空字符串）：**不早返回**，继续执行替换

空字符串是有效输入——它会将所有占位符替换为空字符串。源码注释明确说明了这一设计（[`L100-L101`](../../claude-code-source/src/utils/argumentSubstitution.ts#L100-L101)）。

#### 3.2 `originalContent` 的用途

[`L107`](../../claude-code-source/src/utils/argumentSubstitution.ts#L107) 保存替换前的内容快照。替换完成后，[`L140`](../../claude-code-source/src/utils/argumentSubstitution.ts#L140) 通过 `content === originalContent` 判断是否发生了任何替换。若未发生替换且 `appendIfNoPlaceholder` 为真，则追加参数到末尾。

注意：这一判断基于**引用相等**（字符串在 JS 中不可变，`===` 比较值）。如果替换恰好将占位符替换为相同内容（如 `$0` 替换为 `$0`），会被误判为"未替换"，但这种情况极为罕见。

#### 3.3 命名参数替换的循环

[`L111-L121`](../../claude-code-source/src/utils/argumentSubstitution.ts#L111-L121) 遍历 `argumentNames`，逐个替换命名参数：

```typescript
// src/utils/argumentSubstitution.ts#L111-L121
for (let i = 0; i < argumentNames.length; i++) {
  const name = argumentNames[i]
  if (!name) continue

  content = content.replace(
    new RegExp(`\\$${name}(?![\\[\\w])`, 'g'),
    parsedArgs[i] ?? '',
  )
}
```

每次迭代构造一个新的正则表达式 `new RegExp(`\\$${name}(?![\\[\\w])`, 'g')`，对整个 content 全局替换。命名参数按 `argumentNames` 数组顺序映射到 `parsedArgs` 位置：`argumentNames[0]` → `parsedArgs[0]`。

#### 3.4 正则设计细节

| 占位符 | 正则 | 源码行 | 关键约束 |
| --- | --- | --- | --- |
| `$name` | `\$${name}(?![\[\w])` | [`L118`](../../claude-code-source/src/utils/argumentSubstitution.ts#L118) | 负向前瞻 `(?![\[\w])` 避免匹配 `$name[0]` 或 `$nameExtension` |
| `$ARGUMENTS[N]` | `\$ARGUMENTS\[(\d+)\]` | [`L124`](../../claude-code-source/src/utils/argumentSubstitution.ts#L124) | 捕获组 `(\d+)` 提取索引数字 |
| `$N` | `\$(\d+)(?!\w)` | [`L130`](../../claude-code-source/src/utils/argumentSubstitution.ts#L130) | 负向前瞻 `(?!\w)` 避免匹配 `$1abc` 这类数字开头的标识符 |
| `$ARGUMENTS` | `replaceAll('$ARGUMENTS', ...)` | [`L136`](../../claude-code-source/src/utils/argumentSubstitution.ts#L136) | 简单字符串替换，无正则 |

##### 3.4.1 `$name` 的负向前瞻

`(?![\[\w])` 确保匹配的 `$name` 后面不跟 `[`（避免匹配 `$name[0]` 这种索引形式）或单词字符（避免匹配 `$nameExtension`）。例如：

- `$foo` ✓ 匹配
- `$foo[0]` ✗ 不匹配（`[` 被前瞻拒绝）
- `$foobar` ✗ 不匹配（`b` 是 `\w`，被前瞻拒绝）

##### 3.4.2 `$N` 的负向前瞻

`(?!\w)` 确保 `$0`、`$1` 后面不跟单词字符。例如：

- `$0` ✓ 匹配
- `$0abc` ✗ 不匹配（`a` 是 `\w`）

这一前瞻也防止 `$N` 错误匹配 `$ARGUMENTS` 中的内容——`$ARGUMENTS` 的 `A` 是 `\w`，不满足前瞻条件。

#### 3.5 替换顺序的必要性

四类替换的顺序是：命名参数 → `$ARGUMENTS[N]` → `$N` → `$ARGUMENTS`。这一顺序有严格的依赖关系：

1. **命名参数必须最先**：若正文有 `$foo` 且 `argumentNames = ['foo']`，必须先替换命名参数。如果先执行 `$N` 替换，正则 `\$(\d+)` 不会匹配 `$foo`（非数字），所以顺序在这一点上不冲突——但命名参数替换可能引入新的 `$N` 模式（如参数值包含 `$0`），因此先执行命名参数更安全。

2. **`$ARGUMENTS[N]` 必须先于 `$ARGUMENTS`**：如果先执行 `replaceAll('$ARGUMENTS', ...)`，`$ARGUMENTS[0]` 中的 `$ARGUMENTS` 部分会被替换为完整参数，变成 `<参数>[0]`，破坏索引语法。

3. **`$N` 必须先于 `$ARGUMENTS`**：虽然 `$N` 的正则 `\$(\d+)` 不会匹配 `$ARGUMENTS`（`A` 非 `\w`），但 `$ARGUMENTS` 替换是纯字符串替换，不影响 `$N`。此处顺序更多是防御性的。

#### 3.6 越界索引的处理

[`L126`](../../claude-code-source/src/utils/argumentSubstitution.ts#L126) 和 [`L132`](../../claude-code-source/src/utils/argumentSubstitution.ts#L132) 都使用 `parsedArgs[index] ?? ''`。`??` 运算符在 `parsedArgs[index]` 为 `undefined` 时返回空字符串。

调用 `/skill foo` 时（`parsedArgs = ['foo']`），`$1`、`$2` 等不存在的索引会被替换为空字符串，而非保留原样。这一行为确保正文不会残留未替换的占位符。

#### 3.7 `appendIfNoPlaceholder` 机制

[`L140-L142`](../../claude-code-source/src/utils/argumentSubstitution.ts#L140-L142) 在正文未包含任何占位符、且传入了非空参数时，追加参数到正文末尾：

```typescript
// src/utils/argumentSubstitution.ts#L140-L142
if (content === originalContent && appendIfNoPlaceholder && args) {
  content = content + `\n\nARGUMENTS: ${args}`
}
```

三个条件缺一不可：

- `content === originalContent`：未发生任何替换
- `appendIfNoPlaceholder`：调用方允许追加（`getPromptForCommand()` 传 `true`）
- `args`：参数非空（空字符串是 falsy，不追加）

这一机制确保即使用户未在正文中显式声明占位符，参数也能以 `ARGUMENTS: <args>` 的形式传递给模型。

## 四、 变量替换原理

变量替换（`${CLAUDE_SKILL_DIR}`、`${CLAUDE_SESSION_ID}`）直接在 `getPromptForCommand()` 中用 `String.replace()` 全局替换实现，无独立模块。

### 1. `${CLAUDE_SKILL_DIR}` 替换

```typescript
// src/skills/loadSkillsDir.ts#L356-L363
// Replace ${CLAUDE_SKILL_DIR} with the skill's own directory so bash
// injection (!`...`) can reference bundled scripts. Normalize backslashes
// to forward slashes on Windows so shell commands don't treat them as escapes.
if (baseDir) {
  const skillDir =
    process.platform === 'win32' ? baseDir.replace(/\\/g, '/') : baseDir
  finalContent = finalContent.replace(/\$\{CLAUDE_SKILL_DIR\}/g, skillDir)
}
```

#### 1.1 `baseDir` 守卫

`if (baseDir)` 守卫确保仅在 Skill 有本地目录时执行替换。MCP Skills 没有本地目录（`baseDir` 为空），跳过此替换——源码注释 [`L373`](../../claude-code-source/src/skills/loadSkillsDir.ts#L373) 明确说明 `${CLAUDE_SKILL_DIR}` 对 MCP Skills 无意义。

#### 1.2 Windows 路径规范化

[`L360-L361`](../../claude-code-source/src/skills/loadSkillsDir.ts#L360-L361) 在 Windows 平台将反斜杠 `\` 转换为正斜杠 `/`。这是因为在后续的 Shell 命令执行中，反斜杠会被 Bash 解释为转义字符，导致路径损坏。例如 `C:\skills\my-skill` 在 Bash 中 `\s` 和 `\m` 会被解释为转义序列。

#### 1.3 双重用途

源码注释 [`L356-L358`](../../claude-code-source/src/skills/loadSkillsDir.ts#L356-L358) 指出该变量的两个设计意图：

- 让正文能引用 Skill 目录内的脚本和参考文件（如 `` !`${CLAUDE_SKILL_DIR}/scripts/run.sh` ``）
- 让 `` !`command` `` 中的命令能定位到 bundled 脚本

### 2. `${CLAUDE_SESSION_ID}` 替换

```typescript
// src/skills/loadSkillsDir.ts#L365-L369
// Replace ${CLAUDE_SESSION_ID} with the current session ID
finalContent = finalContent.replace(
  /\$\{CLAUDE_SESSION_ID\}/g,
  getSessionId(),
)
```

此替换无条件执行（无 `baseDir` 守卫），因为会话 ID 在所有 Skill 类型中都可用。`getSessionId()` 返回当前会话的唯一标识符。

## 五、 Shell 命令执行原理

Shell 命令执行由 [`promptShellExecution.ts`](../../claude-code-source/src/utils/promptShellExecution.ts) 的 [`executeShellCommandsInPrompt()`](../../claude-code-source/src/utils/promptShellExecution.ts#L69-L143) 实现。该函数扫描正文中的命令占位符，执行命令，用输出替换占位符。

### 1. 正则模式定义

两种语法的正则模式定义在文件顶部：

```typescript
// src/utils/promptShellExecution.ts#L48-L49
// Pattern for code blocks: ```! command ```
const BLOCK_PATTERN = /```!\s*\n?([\s\S]*?)\n?```/g
```

```typescript
// src/utils/promptShellExecution.ts#L51-L56
// Pattern for inline: !`command`
// Uses a positive lookbehind to require whitespace or start-of-line before !
// This prevents false matches inside markdown inline code spans like `!!` or
// adjacent spans like `foo`!`bar`, and shell variables like $!
// eslint-disable-next-line custom-rules/no-lookbehind-regex -- gated by text.includes('!`') below (PR#22986)
const INLINE_PATTERN = /(?<=^|\s)!`([^`]+)`/gm
```

#### 1.1 代码块模式 BLOCK_PATTERN

`/```!\s*\n?([\s\S]*?)\n?```/g` 匹配以 ` ```! ` 开头的围栏代码块：

- ` ```! ` 后允许空白 `\s*` 和可选换行 `\n?`
- `([\s\S]*?)` 非贪婪匹配块内所有内容（`[\s\S]` 匹配任意字符含换行，`*?` 非贪婪）
- 闭合 ` ``` ` 前允许可选换行 `\n?`
- `g` 标志全局匹配

非贪婪匹配确保在多个代码块场景下，每个 ` ```! ` 只匹配到最近的 ` ``` ` 闭合，而非跨越到文档末尾。

#### 1.2 内联模式 INLINE_PATTERN

`/(?<=^|\s)!`([^`]+)`/gm` 匹配内联 `` !`command` ``：

- `(?<=^|\s)` 正向后瞻，要求 `!` 前是行首 `^` 或空白字符 `\s`
- `` !` `` 字面匹配感叹号加反引号
- `([^`]+)` 匹配反引号内的命令（`[^`]` 排除反引号本身，`+` 至少一个字符）
- `` ` `` 闭合反引号
- `gm` 标志：`g` 全局匹配，`m` 多行模式（使 `^` 匹配每行行首而非仅文档开头）

##### 1.2.1 后瞻的必要性

源码注释 [`L52-L54`](../../claude-code-source/src/utils/promptShellExecution.ts#L52-L54) 解释了后瞻的作用：防止误匹配以下场景：

- Markdown 行内代码 `` `!!` `` 中的 `!` 前无空白
- 相邻代码段 `` `foo`!`bar` `` 中的 `!` 前是反引号（非空白）
- Shell 变量 `$!` 中的 `!` 前是 `$`（非空白）

后瞻要求 `!` 前必须是行首或空白，精确排除了这些情况。

### 2. 性能优化：廉价检查门控

```typescript
// src/utils/promptShellExecution.ts#L85-L90
// INLINE_PATTERN's lookbehind is ~100x slower than BLOCK_PATTERN on large
// skill content (265µs vs 2µs @ 17KB). 93% of skills have no !` at all,
// so gate the expensive scan on a cheap substring check. BLOCK_PATTERN
// (```!) doesn't require !` in the text, so it's always scanned.
const blockMatches = text.matchAll(BLOCK_PATTERN)
const inlineMatches = text.includes('!`') ? text.matchAll(INLINE_PATTERN) : []
```

#### 2.1 性能差异

源码注释量化了性能差异：`INLINE_PATTERN` 的后瞻断言在 17KB 文本上耗时 265µs，而 `BLOCK_PATTERN` 仅 2µs——慢约 100 倍。后瞻断言（lookbehind）在正则引擎中开销显著，因为需要回溯检查前一个字符。

#### 2.2 门控策略

[`L90`](../../claude-code-source/src/utils/promptShellExecution.ts#L90) 用 `text.includes('!`')` 做廉价检查：

- 93% 的 Skill 不含内联命令，`includes()` 返回 `false`，跳过昂贵的 `matchAll()`
- `includes()` 是 O(n) 的简单子串搜索，远快于正则后瞻扫描

`BLOCK_PATTERN` 无需门控，因为它不含后瞻，且 ` ```! ` 模式本身较罕见。

### 3. Shell 工具选择

```typescript
// src/utils/promptShellExecution.ts#L77-L83
// Resolve the tool once. `shell === undefined` and `shell === 'bash'` both
// hit BashTool. PowerShell only when the runtime gate allows — a skill
// author's frontmatter choice doesn't override the user's opt-in/out.
const shellTool: PromptShellTool =
  shell === 'powershell' && isPowerShellToolEnabled()
    ? getPowerShellTool()
    : BashTool
```

#### 3.1 三元判断逻辑

选择 PowerShellTool 需同时满足两个条件：

- `shell === 'powershell'`：Skill 作者在 frontmatter 中显式指定
- `isPowerShellToolEnabled()`：用户运行时启用了 PowerShell 支持

任一条件不满足，都使用 BashTool。源码注释 [`L79`](../../claude-code-source/src/utils/promptShellExecution.ts#L79) 明确指出 Skill 作者的选择不能覆盖用户的运行时配置——这是安全边界。

#### 3.2 PowerShellTool 懒加载

```typescript
// src/utils/promptShellExecution.ts#L29-L46
// Lazy: this file is on the startup import chain (main → commands →
// loadSkillsDir → here). A static import would load PowerShellTool.ts
// (and transitively parser.ts, validators, etc.) at startup on all
// platforms, defeating tools.ts's lazy require. Deferred until the
// first skill with `shell: powershell` actually runs.
/* eslint-disable @typescript-eslint/no-require-imports */
const getPowerShellTool = (() => {
  let cached: PromptShellTool | undefined
  return (): PromptShellTool => {
    if (!cached) {
      cached = (
        require('../tools/PowerShellTool/PowerShellTool.js') as typeof import('../tools/PowerShellTool/PowerShellTool.js')
      ).PowerShellTool
    }
    return cached
  }
})()
/* eslint-enable @typescript-eslint/no-require-imports */
```

`getPowerShellTool` 是一个立即执行函数（IIFE）返回的闭包，实现懒加载：

- `cached` 变量缓存已加载的模块，避免重复 `require`
- 首次调用时 `require()` 加载 PowerShellTool，后续调用直接返回缓存
- 懒加载的原因（[`L29-L33`](../../claude-code-source/src/utils/promptShellExecution.ts#L29-L33)）：此文件在启动导入链上（`main → commands → loadSkillsDir → promptShellExecution`），静态导入会在所有平台启动时加载 PowerShellTool 及其依赖（parser.ts、validators 等），拖慢启动速度

### 4. 执行流程

[`executeShellCommandsInPrompt()`](../../claude-code-source/src/utils/promptShellExecution.ts#L69-L143) 的主体是 `Promise.all()` 并发执行所有匹配：

```typescript
// src/utils/promptShellExecution.ts#L92-L140
await Promise.all(
  [...blockMatches, ...inlineMatches].map(async match => {
    const command = match[1]?.trim()
    if (command) {
      try {
        // Check permissions before executing
        const permissionResult = await hasPermissionsToUseTool(
          shellTool,
          { command },
          context,
          createAssistantMessage({ content: [] }),
          '',
        )

        if (permissionResult.behavior !== 'allow') {
          logForDebugging(
            `Shell command permission check failed for command in ${slashCommandName}: ${command}. Error: ${permissionResult.message}`,
          )
          throw new MalformedCommandError(
            `Shell command permission check failed for pattern "${match[0]}": ${permissionResult.message || 'Permission denied'}`,
          )
        }

        const { data } = await shellTool.call({ command }, context)
        // Reuse the same persistence flow as regular Bash tool calls
        const toolResultBlock = await processToolResultBlock(
          shellTool,
          data,
          randomUUID(),
        )
        // Extract the string content from the block
        const output =
          typeof toolResultBlock.content === 'string'
            ? toolResultBlock.content
            : formatBashOutput(data.stdout, data.stderr)
        // Function replacer — String.replace interprets $$, $&, $`, $' in
        // the replacement string even with a string search pattern. Shell
        // output (especially PowerShell: $env:PATH, $$, $PSVersionTable)
        // is arbitrary user data; a bare string arg would corrupt it.
        result = result.replace(match[0], () => output)
      } catch (e) {
        if (e instanceof MalformedCommandError) {
          throw e
        }
        formatBashError(e, match[0])
      }
    }
  }),
)
```

#### 4.1 命令提取

[`L94`](../../claude-code-source/src/utils/promptShellExecution.ts#L94) 的 `match[1]` 是正则的第一个捕获组——对于 `BLOCK_PATTERN` 是代码块内容，对于 `INLINE_PATTERN` 是反引号内的命令。`.trim()` 去除首尾空白。

`if (command)` 守卫跳过空命令（如 ` ```! ``` ` 空代码块），避免无意义执行。

#### 4.2 权限检查

[`L98-L104`](../../claude-code-source/src/utils/promptShellExecution.ts#L98-L104) 调用 `hasPermissionsToUseTool()` 检查命令权限：

```typescript
// src/utils/promptShellExecution.ts#L98-L104
const permissionResult = await hasPermissionsToUseTool(
  shellTool,
  { command },
  context,
  createAssistantMessage({ content: [] }),
  '',
)
```

这与常规 Bash 工具调用的权限检查流程完全一致。`createAssistantMessage({ content: [] })` 构造一个空的 assistant 消息作为上下文（权限检查需要消息上下文）。

#### 4.3 权限拒绝处理

[`L106-L113`](../../claude-code-source/src/utils/promptShellExecution.ts#L106-L113) 在权限被拒绝时抛出 `MalformedCommandError`：

```typescript
// src/utils/promptShellExecution.ts#L106-L113
if (permissionResult.behavior !== 'allow') {
  logForDebugging(
    `Shell command permission check failed for command in ${slashCommandName}: ${command}. Error: ${permissionResult.message}`,
  )
  throw new MalformedCommandError(
    `Shell command permission check failed for pattern "${match[0]}": ${permissionResult.message || 'Permission denied'}`,
  )
}
```

`permissionResult.behavior` 可能是 `'allow'`、`'deny'` 或 `'ask'`。只有 `'allow'` 才继续执行，其他情况都抛出异常。这意味着 Skill 中的 Shell 命令不会弹出权限确认对话框——要么直接执行（已允许），要么直接失败。

#### 4.4 命令执行

[`L115`](../../claude-code-source/src/utils/promptShellExecution.ts#L115) 调用 shell 工具的 `call()` 方法执行命令：

```typescript
// src/utils/promptShellExecution.ts#L115
const { data } = await shellTool.call({ command }, context)
```

`shellTool.call()` 返回 `{ data: { stdout, stderr, interrupted } }`。注意此处直接调用 `call()`，**绕过了 `validateInput()`**——源码类型定义注释 [`L17-L18`](../../claude-code-source/src/utils/promptShellExecution.ts#L17-L18) 明确指出这一点，并要求所有关键检查必须在 `call()` 内部完成。

#### 4.5 输出提取

[`L117-L126`](../../claude-code-source/src/utils/promptShellExecution.ts#L117-L126) 通过 `processToolResultBlock()` 复用常规 Bash 工具调用的结果持久化流程，然后提取字符串输出：

```typescript
// src/utils/promptShellExecution.ts#L117-L126
const toolResultBlock = await processToolResultBlock(
  shellTool,
  data,
  randomUUID(),
)
const output =
  typeof toolResultBlock.content === 'string'
    ? toolResultBlock.content
    : formatBashOutput(data.stdout, data.stderr)
```

优先使用 `toolResultBlock.content`（已格式化的字符串），若内容非字符串（如数组形式的多块内容），降级为 `formatBashOutput()` 合并 stdout/stderr。

### 5. 函数式 replace 防止 `$` 被解释

```typescript
// src/utils/promptShellExecution.ts#L127-L131
// Function replacer — String.replace interprets $$, $&, $`, $' in
// the replacement string even with a string search pattern. Shell
// output (especially PowerShell: $env:PATH, $$, $PSVersionTable)
// is arbitrary user data; a bare string arg would corrupt it.
result = result.replace(match[0], () => output)
```

此处使用**函数** `() => output` 作为 `replace()` 的第二参数，而非字符串 `output`。

#### 5.1 字符串参数的陷阱

JavaScript 的 `String.replace()` 在使用字符串作为替换值时，会解释特殊模式：

| 模式 | 含义 |
| --- | --- |
| `$$` | 字面 `$` |
| `$&` | 匹配的子串 |
| `` $` `` | 匹配项前的部分 |
| `$'` | 匹配项后的部分 |
| `$1`-`$9` | 捕获组 |

Shell 输出常含这些模式。例如 PowerShell 的 `$PSVersionTable`、`$env:PATH`，Bash 的 `$$`（PID）。若用字符串参数，这些内容会被 `replace()` 错误解释，破坏输出数据。

#### 5.2 函数参数的规避

函数式 replace 将替换值作为函数返回值，**绕过所有模式解释**。`() => output` 忽略所有参数（匹配内容、捕获组等），直接返回 `output`，确保输出原样插入。

### 6. 并发执行

[`L92-L93`](../../claude-code-source/src/utils/promptShellExecution.ts#L92-L93) 使用 `Promise.all()` 并发执行所有匹配的命令：

```typescript
// src/utils/promptShellExecution.ts#L92-L93
await Promise.all(
  [...blockMatches, ...inlineMatches].map(async match => {
```

`[...blockMatches, ...inlineMatches]` 将两种匹配合并为数组，`map()` 为每个匹配创建异步任务，`Promise.all()` 并发等待所有任务完成。

这意味着多个 `` !`command` `` 会**同时运行**，而非顺序执行。例如：

```markdown
!`git status`
!`npm test`
!`git log`
```

三条命令并发执行，总耗时约为最慢命令的耗时，而非三者之和。

### 7. 单次替换不递归

`result.replace(match[0], ...)` 对每个匹配执行一次替换。替换后的输出**不会被重新扫描**查找新的 `` !`...` `` 占位符。这一行为由实现机制自然保证：

1. `matchAll()` 在 [`L89-L90`](../../claude-code-source/src/utils/promptShellExecution.ts#L89-L90) 生成所有匹配的迭代器，此时基于**原始 `text`**
2. `Promise.all()` 基于这些预生成的匹配并发替换
3. 替换在 `result` 变量上进行，但匹配来自原始 `text`，不会重新扫描 `result`

因此，如果某命令输出中包含 `` !`echo malicious` `` 文本，该文本会原样保留在最终结果中，不会被再次执行。这一特性防止了命令注入攻击——恶意输出无法触发新的命令执行。

### 8. 输出格式化

[`formatBashOutput()`](../../claude-code-source/src/utils/promptShellExecution.ts#L145-L165) 将 stdout 和 stderr 合并为单一字符串：

```typescript
// src/utils/promptShellExecution.ts#L145-L165
function formatBashOutput(
  stdout: string,
  stderr: string,
  inline = false,
): string {
  const parts: string[] = []

  if (stdout.trim()) {
    parts.push(stdout.trim())
  }

  if (stderr.trim()) {
    if (inline) {
      parts.push(`[stderr: ${stderr.trim()}]`)
    } else {
      parts.push(`[stderr]\n${stderr.trim()}`)
    }
  }

  return parts.join(inline ? ' ' : '\n')
}
```

#### 8.1 stderr 保留策略

stderr 始终被保留（`if (stderr.trim())`），不会静默丢弃。两种格式：

- **内联模式**（`inline = true`）：`[stderr: <内容>]` 单行格式，适合内联插入
- **代码块模式**（`inline = false`）：`[stderr]\n<内容>` 多行格式，适合代码块插入

#### 8.2 空输出处理

`stdout.trim()` 和 `stderr.trim()` 检查确保空白输出不产生空 parts。若两者都为空，`parts` 为空数组，`join()` 返回空字符串——占位符被替换为空。

#### 8.3 `inline` 参数的来源

`formatBashOutput()` 的 `inline` 参数在 `executeShellCommandsInPrompt()` 中**未显式传递**（默认 `false`）。这意味着所有通过 Skill 替换路径调用的输出格式化都使用多行格式。`inline = true` 的分支在其他调用路径中使用（如用户输入框的 `!` 命令）。

### 9. 错误处理

[`formatBashError()`](../../claude-code-source/src/utils/promptShellExecution.ts#L167-L183) 将各类错误统一包装为 `MalformedCommandError`：

```typescript
// src/utils/promptShellExecution.ts#L167-L183
function formatBashError(e: unknown, pattern: string, inline = false): never {
  if (e instanceof ShellError) {
    if (e.interrupted) {
      throw new MalformedCommandError(
        `Shell command interrupted for pattern "${pattern}": [Command interrupted]`,
      )
    }
    const output = formatBashOutput(e.stdout, e.stderr, inline)
    throw new MalformedCommandError(
      `Shell command failed for pattern "${pattern}": ${output}`,
    )
  }

  const message = errorMessage(e)
  const formatted = inline ? `[Error: ${message}]` : `[Error]\n${message}`
  throw new MalformedCommandError(formatted)
}
```

返回类型 `never` 表示该函数总是抛出异常，从不正常返回。三类错误场景：

| 错误类型 | 条件 | 处理 |
| --- | --- | --- |
| `ShellError` + `interrupted` | 命令被用户中断 | 抛出 `[Command interrupted]` |
| `ShellError` 其他 | 命令执行失败 | 抛出附带 stdout/stderr 的错误 |
| 其他异常 | 非预期错误 | 抛出通用错误信息 |

#### 9.1 catch 块的二次过滤

```typescript
// src/utils/promptShellExecution.ts#L132-L137
} catch (e) {
  if (e instanceof MalformedCommandError) {
    throw e
  }
  formatBashError(e, match[0])
}
```

catch 块先检查是否为 `MalformedCommandError`（权限检查失败时抛出），若是则直接 re-throw，不经过 `formatBashError()` 二次包装。其他错误才交给 `formatBashError()` 处理。这避免了错误信息的重复包装。

## 六、 安全限制

### 1. MCP Skills 不执行 Shell 命令

```typescript
// src/skills/loadSkillsDir.ts#L371-L374
// Security: MCP skills are remote and untrusted — never execute inline
// shell commands (!`…` / ```! … ```) from their markdown body.
// ${CLAUDE_SKILL_DIR} is meaningless for MCP skills anyway.
if (loadedFrom !== 'mcp') {
  finalContent = await executeShellCommandsInPrompt(...)
}
```

#### 1.1 守卫逻辑

`if (loadedFrom !== 'mcp')` 守卫跳过 MCP Skills 的 Shell 命令执行。源码注释 [`L371-L373`](../../claude-code-source/src/skills/loadSkillsDir.ts#L371-L373) 说明原因：MCP Skills 是远程加载的，不受信任。如果允许执行其正文中的 Shell 命令，恶意 MCP 服务器可在用户机器上执行任意命令。

#### 1.2 连带影响

注释 [`L373`](../../claude-code-source/src/skills/loadSkillsDir.ts#L373) 同时指出 `${CLAUDE_SKILL_DIR}` 对 MCP Skills 也无意义——MCP Skills 没有本地目录。因此 `${CLAUDE_SKILL_DIR}` 替换的 `if (baseDir)` 守卫（[`L359`](../../claude-code-source/src/skills/loadSkillsDir.ts#L359)）天然排除了 MCP Skills。

MCP Skills 的 `` !`command` `` 语法保持字面文本，不会被替换或执行。

### 2. 远程 Canonical Skills 跳过全部替换

远程 canonical skills（通过 [`executeRemoteSkill()`](../../claude-code-source/src/tools/SkillTool/SkillTool.ts#L969-L1108) 加载）是声明式 markdown，直接包装为 user message 注入，不执行任何命令替换：

```typescript
// src/tools/SkillTool/SkillTool.ts#L600-L604
// Remote canonical skill execution (ant-only experimental). Intercepts
// `_canonical_<slug>` before local command lookup — loads SKILL.md from
// AKI/GCS (with local cache), injects content directly as a user message.
// Remote skills are declarative markdown so no slash-command expansion
// (no !command substitution, no $ARGUMENTS interpolation) is needed.
```

#### 2.1 远程 Skill 的手动变量替换

远程 skill 不走 `getPromptForCommand()`，但 [`executeRemoteSkill()`](../../claude-code-source/src/tools/SkillTool/SkillTool.ts#L1069-L1081) 手动执行了部分变量替换：

```typescript
// src/tools/SkillTool/SkillTool.ts#L1065-L1081
// Strip YAML frontmatter (---\nname: x\n---) before prepending the header
// (matches loadSkillsDir.ts:333). parseFrontmatter returns the original
// content unchanged if no frontmatter is present.
const { content: bodyContent } = parseFrontmatter(content, skillPath)

// Inject base directory header + ${CLAUDE_SKILL_DIR}/${CLAUDE_SESSION_ID}
// substitution (matches loadSkillsDir.ts) so the model can resolve relative
// refs like ./schemas/foo.json against the cache dir.
const skillDir = dirname(skillPath)
const normalizedDir =
  process.platform === 'win32' ? skillDir.replace(/\\/g, '/') : skillDir
let finalContent = `Base directory for this skill: ${normalizedDir}\n\n${bodyContent}`
finalContent = finalContent.replace(/\$\{CLAUDE_SKILL_DIR\}/g, normalizedDir)
finalContent = finalContent.replace(
  /\$\{CLAUDE_SESSION_ID\}/g,
  getSessionId(),
)
```

远程 skill 仅做：

- Frontmatter 剥离（`parseFrontmatter`）
- Base Directory 前缀拼接
- `${CLAUDE_SKILL_DIR}` 替换
- `${CLAUDE_SESSION_ID}` 替换

**不执行**：`$ARGUMENTS` 参数替换、`` !`command` `` Shell 命令执行。源码注释 [`L603-L604`](../../claude-code-source/src/tools/SkillTool/SkillTool.ts#L603-L604) 明确说明远程 skill 是声明式 markdown，无需斜杠命令展开。

### 3. allowedTools 注入

Shell 命令执行时，`getPromptForCommand()` 会将 Skill 的 `allowedTools` 注入到工具权限上下文：

```typescript
// src/skills/loadSkillsDir.ts#L375-L395
finalContent = await executeShellCommandsInPrompt(
  finalContent,
  {
    ...toolUseContext,
    getAppState() {
      const appState = toolUseContext.getAppState()
      return {
        ...appState,
        toolPermissionContext: {
          ...appState.toolPermissionContext,
          alwaysAllowRules: {
            ...appState.toolPermissionContext.alwaysAllowRules,
            command: allowedTools,
          },
        },
      }
    },
  },
  `/${skillName}`,
  shell,
)
```

#### 3.1 上下文覆盖

第二个参数覆盖了 `toolUseContext.getAppState()`，返回一个新的 AppState，其中 `toolPermissionContext.alwaysAllowRules.command` 被替换为 `allowedTools`。

#### 3.2 效果

这使得 Skill 声明的 `allowed-tools` 在 Shell 命令执行期间生效。`allowedTools` 是 frontmatter `allowed-tools` 字段解析后的命令列表（如 `['Bash(git diff:*)', 'Bash(npm test:*)']`）。这些命令在权限检查时被自动允许，无需用户确认。

> **注意**：覆盖使用 `command: allowedTools` 而非 `command: [...existing, ...allowedTools]`，是**替换**而非**追加**。但在实际使用中，`allowedTools` 已包含 Skill 所需的全部命令，且 Shell 命令执行是 Skill 调用的子流程，覆盖范围有限。

## 七、 替换机制总结

| 替换类型 | 实现位置 | 正则/方法 | 源码行 | 递归 | MCP Skills | 远程 Skills |
| --- | --- | --- | --- | --- | --- | --- |
| `$ARGUMENTS` | `argumentSubstitution.ts` | `replaceAll` | [`L136`](../../claude-code-source/src/utils/argumentSubstitution.ts#L136) | 否 | 是 | 否 |
| `$ARGUMENTS[N]` | `argumentSubstitution.ts` | `/\$ARGUMENTS\[(\d+)\]/g` | [`L124`](../../claude-code-source/src/utils/argumentSubstitution.ts#L124) | 否 | 是 | 否 |
| `$N` | `argumentSubstitution.ts` | `/\$(\d+)(?!\w)/g` | [`L130`](../../claude-code-source/src/utils/argumentSubstitution.ts#L130) | 否 | 是 | 否 |
| `$name` | `argumentSubstitution.ts` | `\$${name}(?![\[\w])` | [`L118`](../../claude-code-source/src/utils/argumentSubstitution.ts#L118) | 否 | 是 | 否 |
| `${CLAUDE_SKILL_DIR}` | `loadSkillsDir.ts` | `String.replace` | [`L362`](../../claude-code-source/src/skills/loadSkillsDir.ts#L362) | 否 | 否 | 是 |
| `${CLAUDE_SESSION_ID}` | `loadSkillsDir.ts` | `String.replace` | [`L366-L368`](../../claude-code-source/src/skills/loadSkillsDir.ts#L366-L368) | 否 | 是 | 是 |
| `` !`command` `` | `promptShellExecution.ts` | `/(?<=^\|\\s)!`([^`]+)`/gm` | [`L56`](../../claude-code-source/src/utils/promptShellExecution.ts#L56) | 否 | 否 | 否 |
| ` ```! ``` ` | `promptShellExecution.ts` | `/```!\s*\n?([\s\S]*?)\n?```/g` | [`L49`](../../claude-code-source/src/utils/promptShellExecution.ts#L49) | 否 | 否 | 否 |

### 1. 设计要点回顾

- **顺序依赖**：参数替换 → 变量替换 → Shell 命令执行，确保命令能使用已替换的参数和变量
- **单次不递归**：所有替换都是单次扫描，输出不重新扫描，防止注入攻击
- **函数式 replace**：Shell 输出替换使用函数参数，防止 `$` 模式被解释
- **并发执行**：多个 Shell 命令并发运行，提升渲染速度
- **安全分层**：MCP Skills 禁止 Shell 执行，远程 Skills 跳过全部替换，本地 Skills 走完整流程
- **权限复用**：Shell 命令复用常规 Bash 工具的权限检查和结果持久化流程

---

*本文档由 markdowncli 技能辅助生成*

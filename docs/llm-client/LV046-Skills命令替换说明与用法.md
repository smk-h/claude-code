<!-- more -->

## 一、 概述

Skill 的 `SKILL.md` 正文并非静态文本——在注入对话上下文之前，Claude Code 会对正文执行一系列**命令替换**（Command Substitution），将模板占位符替换为实际值。这一机制使 Skill 正文能够动态引用调用参数、运行环境变量，甚至内联执行 Shell 命令并将输出嵌入提示词。

命令替换分为两大类：

| 类别 | 触发语法 | 替换时机 | 数据来源 |
| --- | --- | --- | --- |
| 字符串替换 | `$ARGUMENTS`、`$N`、`$name`、`${CLAUDE_*}` | Skill 调用时 | 调用参数 / 运行环境 |
| Shell 命令执行 | `` !`command` ``、` ```! ``` ` | Skill 调用时 | 本地 Shell 执行结果 |

> **前置文档**：本文档聚焦命令替换的**用法层面**。替换机制的源码实现细节详见 [LV047-Skills命令替换原理](LV047-Skills命令替换原理.md)；Skill 文件解析与正文注入流程详见 [LV041-Skills-MD文件解析与内容注入](LV041-Skills-MD文件解析与内容注入.md)。

## 二、 字符串替换

### 1. 参数替换

参数替换将调用 Skill 时传入的参数填充到正文占位符中。参数解析采用 shell-quote 语法，支持引号包裹的多词参数。

#### 1.1 `$ARGUMENTS`

`$ARGUMENTS` 被替换为调用时传入的**完整参数字符串**（未拆分）。

```markdown
---
name: search
description: 在代码库中搜索关键词
---

请在当前项目中搜索以下内容：$ARGUMENTS
```

调用 `/search React hooks` 后，`$ARGUMENTS` 被替换为 `React hooks`。

> **无占位符时的行为**：如果正文中未出现任何 `$ARGUMENTS` 占位符，且传入了非空参数，系统会自动在正文末尾追加 `ARGUMENTS: <参数>`。

#### 1.2 `$ARGUMENTS[N]` 与 `$N`

按 0 基索引访问特定位置的参数。`$N` 是 `$ARGUMENTS[N]` 的简写形式。

```markdown
---
name: migrate-component
description: 将组件从一个框架迁移到另一个框架
---

将 $0 组件从 $1 迁移到 $2。
保留所有现有行为和测试。
```

调用 `/migrate-component SearchBar React Vue` 后：

- `$0` → `SearchBar`
- `$1` → `React`
- `$2` → `Vue`

#### 1.3 命名参数 `$name`

通过 frontmatter 的 `arguments` 字段声明命名参数，正文可用 `$name` 引用，按声明顺序映射到位置参数。

```markdown
---
name: migrate-component
description: 将组件从一个框架迁移到另一个框架
arguments: component from to
---

将 $component 组件从 $from 迁移到 $to。
```

调用 `/migrate-component SearchBar React Vue` 后，`$component`、`$from`、`$to` 分别替换为对应值。`arguments` 字段接受空格分隔字符串或 YAML 列表两种写法。

> **命名冲突**：纯数字名称（如 `0`、`1`）会被过滤，避免与 `$N` 简写冲突。

### 2. 环境变量替换

除参数外，正文还可引用若干运行环境变量，用 `${}` 语法包裹：

| 变量 | 替换为 | 说明 |
| --- | --- | --- |
| `${CLAUDE_SKILL_DIR}` | Skill 目录绝对路径 | 使正文能引用 Skill 目录内的脚本、参考文件 |
| `${CLAUDE_SESSION_ID}` | 当前会话 ID | 用于会话级数据隔离 |
| `${CLAUDE_EFFORT}` | 当前工作量级别 | 取值：`low`、`medium`、`high`、`xhigh`、`max` |
| `${CLAUDE_PROJECT_DIR}` | 项目根目录 | 稳定的项目根，非 worktree 路径（v2.1.196+） |

```markdown
---
name: deploy-check
description: 检查部署环境状态
---

## 环境信息
- 项目根目录：${CLAUDE_PROJECT_DIR}
- 当前工作量：${CLAUDE_EFFORT}

## Skill 自带脚本
请执行 `${CLAUDE_SKILL_DIR}/scripts/check.sh` 并分析输出。
```

### 3. 转义规则

当正文中需要保留字面 `$` 时，用反斜杠 `\` 转义：

| 写法 | 结果 | 说明 |
| --- | --- | --- |
| `\$1.00` | `$1.00` | 转义单个 `$`，不触发参数替换 |
| `\\$1` | `\` + 第一个参数值 | 双反斜杠保留一个字面 `\`，`$1` 仍正常替换 |

### 4. 多 Skill 堆叠

从 v2.1.199 起，可在一条消息中堆叠调用多个 Skill，参数会传递给每个 Skill：

```
/code-review /fix-issue 123
```

此例中 `code-review` 和 `fix-issue` 都会被加载，`123` 作为 `$ARGUMENTS` 传递给二者。

## 三、 Shell 命令执行

Shell 命令执行是更强的替换形式：在正文注入对话**之前**，先在本地执行 Shell 命令，用命令输出替换占位符。Claude 只看到最终渲染结果，看不到原始命令语法。

### 1. 内联形式

`` !`command` `` 语法在正文中内联执行命令：

```markdown
## 当前改动

!`git diff HEAD`

## 当前分支

!`git branch --show-current`
```

渲染后，Claude 收到的是 `git diff` 和 `git branch` 的实际输出，而非命令本身。

#### 1.1 识别条件

内联形式仅在 `!` 出现在**行首**或**紧跟空白字符**之后时被识别。以下写法不会被识别为命令替换：

```markdown
KEY=!`echo value`    ← ! 前无空白，保留为字面文本
```

### 2. 代码块形式

多行命令使用以 ` ```! ` 开头的围栏代码块：

````markdown
## 环境信息
```!
node --version
npm --version
git status --short
```
````

代码块内所有命令依次执行，合并输出后替换整个代码块。

### 3. Shell 选择

通过 frontmatter 的 `shell` 字段指定执行命令的 Shell：

| 取值 | 说明 |
| --- | --- |
| `bash`（默认） | 使用 BashTool 执行 |
| `powershell` | 使用 PowerShellTool 执行（需 `CLAUDE_CODE_USE_POWERSHELL_TOOL=1`，主要用于 Windows） |

```markdown
---
name: windows-check
description: Windows 环境检查
shell: powershell
---

## 系统信息
```!
$PSVersionTable.PSVersion
Get-Location
```
```

### 4. 禁用机制

通过设置 `disableSkillShellExecution: true` 可禁用 Shell 命令执行。禁用后，每个命令占位符被替换为：

```
[shell command execution disabled by policy]
```

> **适用范围**：该设置影响来自用户、项目、插件等目录源的 Skill。**捆绑 Skill 和托管 Skill 不受此设置影响**，仍可正常执行命令。

### 5. 权限要求

Shell 命令执行走与常规 Bash 工具调用相同的权限检查流程。如果命令被权限规则拒绝，整个 Skill 调用会失败并抛出 `MalformedCommandError`。

## 四、 替换执行顺序

当 Skill 被调用时，系统按固定顺序依次执行各类替换：

1. **添加 Base Directory 前缀**：在正文前拼接 `Base directory for this skill: <dir>`
2. **参数替换**：`$ARGUMENTS`、`$N`、`$name`
3. **`${CLAUDE_SKILL_DIR}` 替换**
4. **`${CLAUDE_SESSION_ID}` 替换**
5. **Shell 命令执行**：`` !`command` `` 和 ` ```! ``` `

> **顺序的意义**：参数替换在 Shell 命令执行之前完成，因此 Shell 命令内部可以使用已替换好的参数值。例如 `` !`grep $0 src/` `` 中的 `$0` 会先被替换为实际参数，再执行 `grep`。

## 五、 用法示例

### 1. 参数替换 + 环境变量

```markdown
---
name: analyze-issue
description: 分析 GitHub issue 并生成修复方案
arguments: issue-number
---

## Issue 信息
请分析 issue #$issue-number。

## 项目上下文
- 项目根目录：${CLAUDE_PROJECT_DIR}
- Skill 脚本目录：${CLAUDE_SKILL_DIR}

## 操作步骤
1. 使用 `${CLAUDE_SKILL_DIR}/scripts/fetch-issue.sh $issue-number` 获取 issue 详情
2. 分析相关代码
3. 生成修复方案
```

### 2. Shell 命令注入运行时数据

```markdown
---
name: review-changes
description: 审查当前工作区的改动
---

## 待审查的改动
```!
git diff HEAD --stat
git log --oneline -5
```

## 系统环境
- 当前分支：!`git branch --show-current`
- Node 版本：!`node --version`

请基于以上信息审查代码改动。
```

### 3. 命名参数 + Shell 命令组合

```markdown
---
name: create-module
description: 按团队规范创建新模块
arguments: module-name parent-dir
shell: bash
---

## 任务
在 $parent-dir 下创建模块 $module-name。

## 参考结构
```!
ls -la ${CLAUDE_SKILL_DIR}/templates/
```

## 执行
1. 复制 `${CLAUDE_SKILL_DIR}/templates/base/` 到 `$parent-dir/$module-name`
2. 替换模板中的占位符
3. 运行初始化脚本
```

## 六、 限制与注意事项

### 1. MCP Skills 不执行 Shell 命令

MCP Skills 是远程加载的，出于安全考虑**不执行**正文中的 Shell 命令。`` !`command` `` 语法在 MCP Skills 中保持字面文本，不会被替换。

### 2. 远程 Canonical Skills 不做命令替换

远程 canonical skills 是声明式 markdown，直接包装为用户消息注入，不执行 `$ARGUMENTS` 替换，也不执行 Shell 命令。

### 3. Shell 命令输出不递归

替换对原始文件运行一次。命令输出**不会被重新扫描**查找更多 `` !`...` `` 占位符，避免递归执行。

### 4. 正文长度影响

Shell 命令输出会直接嵌入正文，如果命令输出很长，会显著增加上下文消耗。建议在命令后添加 `| head -20` 等限制输出的处理。

---

*本文档由 markdowncli 技能辅助生成*

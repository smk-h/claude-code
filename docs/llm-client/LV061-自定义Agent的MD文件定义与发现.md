<!-- more -->

## 一、 概述

Claude Code 的自定义 Agent 通过 Markdown 文件（`.md`）定义，存放在特定目录下，由系统自动扫描发现并加载。本文档详细分析自定义 Agent 的 MD 文件格式、目录发现机制、Frontmatter 解析流程以及 JSON 定义方式。

## 二、MD 文件格式

### 1. 文件结构

自定义 Agent 的 MD 文件由两部分组成：**YAML frontmatter**（元数据）和 **Markdown 正文**（系统提示词）。

```markdown
---
name: my-custom-agent
description: 用于执行特定任务的 Agent
tools:
  - Read
  - Grep
  - Bash
model: haiku
---

你是 my-custom-agent，专门负责执行以下任务...

（这里是 Agent 的系统提示词正文）
```

### 2.Frontmatter 字段详解

解析逻辑在 [`parseAgentFromMarkdown()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L541-L755)：

#### 2.1 必填字段

| 字段 | 类型 | 说明 | 解析位置 |
|------|------|------|----------|
| `name` | `string` | Agent 类型标识符，用于 `subagent_type` 参数匹配 | [`loadAgentsDir.ts#L549`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L549) |
| `description` | `string` | 何时使用此 Agent 的描述，注入 LLM 上下文用于选择 | [`loadAgentsDir.ts#L550`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L550) |

若 `name` 缺失，文件被视为非 Agent 文档（可能是同目录下的参考文档），静默跳过；若 `description` 缺失，记录调试日志后返回 `null`：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L552-L562
if (!agentType || typeof agentType !== 'string') {
  return null  // 无 name 字段，静默跳过
}
if (!whenToUse || typeof whenToUse !== 'string') {
  logForDebugging(`Agent file ${filePath} is missing required 'description' in frontmatter`)
  return null
}
```

#### 2.2 可选字段详解

##### `tools` — 允许的工具列表

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L660
let tools = parseAgentToolsFromFrontmatter(frontmatter['tools'])
```

解析规则由 [`parseAgentToolsFromFrontmatter()`](../../claude-code-source/src/utils/markdownConfigLoader.ts#L113-L126) 定义：

| frontmatter 值 | 解析结果 | 含义 |
|----------------|----------|------|
| 缺失（undefined） | `undefined` | 所有工具可用 |
| `[]`（空数组） | `[]` | 无工具可用 |
| `['*']` | `undefined` | 所有工具可用 |
| `['Read', 'Grep']` | `['Read', 'Grep']` | 仅列出的工具可用 |

特别说明：当 `memory` 启用时，自动注入 `Write`/`Edit`/`Read` 工具：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L662-L674
if (isAutoMemoryEnabled() && memory && tools !== undefined) {
  const toolSet = new Set(tools)
  for (const tool of [FILE_WRITE_TOOL_NAME, FILE_EDIT_TOOL_NAME, FILE_READ_TOOL_NAME]) {
    if (!toolSet.has(tool)) tools = [...tools, tool]
  }
}
```

##### `disallowedTools` — 禁用的工具列表

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L677-L681
const disallowedToolsRaw = frontmatter['disallowedTools']
const disallowedTools = disallowedToolsRaw !== undefined
  ? parseAgentToolsFromFrontmatter(disallowedToolsRaw)
  : undefined
```

运行时，`tools` 和 `disallowedTools` 同时存在时，白名单会被黑名单进一步过滤（见 [`resolveAgentTools()`](../../claude-code-source/src/tools/AgentTool/agentToolUtils.ts#L122-L225)）。

##### `model` — 模型覆盖

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L568-L573
const modelRaw = frontmatter['model']
let model: string | undefined
if (typeof modelRaw === 'string' && modelRaw.trim().length > 0) {
  const trimmed = modelRaw.trim()
  model = trimmed.toLowerCase() === 'inherit' ? 'inherit' : trimmed
}
```

可选值：`sonnet`、`opus`、`haiku`、`inherit`（继承父模型）。

##### `background` — 始终后台运行

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L576-L591
const backgroundRaw = frontmatter['background']
if (backgroundRaw !== undefined &&
    backgroundRaw !== 'true' && backgroundRaw !== 'false' &&
    backgroundRaw !== true && backgroundRaw !== false) {
  logForDebugging(`Agent file ${filePath} has invalid background value '${backgroundRaw}'...`)
}
const background = backgroundRaw === 'true' || backgroundRaw === true ? true : undefined
```

##### `memory` — 持久化记忆范围

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L594-L605
const VALID_MEMORY_SCOPES: AgentMemoryScope[] = ['user', 'project', 'local']
const memoryRaw = frontmatter['memory'] as string | undefined
let memory: AgentMemoryScope | undefined
if (memoryRaw !== undefined) {
  if (VALID_MEMORY_SCOPES.includes(memoryRaw as AgentMemoryScope)) {
    memory = memoryRaw as AgentMemoryScope
  } else {
    logForDebugging(`Agent file ${filePath} has invalid memory value '${memoryRaw}'...`)
  }
}
```

##### `isolation` — 隔离模式

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L607-L621
type IsolationMode = 'worktree' | 'remote'
const VALID_ISOLATION_MODES: readonly IsolationMode[] =
  process.env.USER_TYPE === 'ant' ? ['worktree', 'remote'] : ['worktree']
const isolationRaw = frontmatter['isolation'] as string | undefined
let isolation: IsolationMode | undefined
if (isolationRaw !== undefined) {
  if (VALID_ISOLATION_MODES.includes(isolationRaw as IsolationMode)) {
    isolation = isolationRaw as IsolationMode
  } else {
    logForDebugging(`Agent file ${filePath} has invalid isolation value '${isolationRaw}'...`)
  }
}
```

【**注意**】`remote` 隔离模式仅限 Ant 内部构建，外部构建只支持 `worktree`。

##### `effort` — 思考努力级别

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L624-L632
const effortRaw = frontmatter['effort']
const parsedEffort = effortRaw !== undefined ? parseEffortValue(effortRaw) : undefined
if (effortRaw !== undefined && parsedEffort === undefined) {
  logForDebugging(`Agent file ${filePath} has invalid effort '${effortRaw}'...`)
}
```

支持字符串级别（`high`/`medium`/`low`）和整数值。

##### `permissionMode` — 权限模式

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L634-L645
const permissionModeRaw = frontmatter['permissionMode'] as string | undefined
const isValidPermissionMode = permissionModeRaw &&
  (PERMISSION_MODES as readonly string[]).includes(permissionModeRaw)
if (permissionModeRaw && !isValidPermissionMode) {
  logForDebugging(`Agent file ${filePath} has invalid permissionMode '${permissionModeRaw}'...`)
}
```

##### `maxTurns` — 最大轮次

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L648-L654
const maxTurnsRaw = frontmatter['maxTurns']
const maxTurns = parsePositiveIntFromFrontmatter(maxTurnsRaw)
if (maxTurnsRaw !== undefined && maxTurns === undefined) {
  logForDebugging(`Agent file ${filePath} has invalid maxTurns '${maxTurnsRaw}'...`)
}
```

##### `skills` — 预加载技能

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L684
const skills = parseSlashCommandToolsFromFrontmatter(frontmatter['skills'])
```

[`parseSlashCommandToolsFromFrontmatter()`](../../claude-code-source/src/utils/markdownConfigLoader.ts#L132-L140) 与 `parseAgentToolsFromFrontmatter` 不同：缺失或空字段返回 `[]`（无技能），而非 `undefined`。

##### `initialPrompt` — 初始提示词

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L686-L690
const initialPromptRaw = frontmatter['initialPrompt']
const initialPrompt = typeof initialPromptRaw === 'string' && initialPromptRaw.trim()
  ? initialPromptRaw : undefined
```

##### `mcpServers` — Agent 专属 MCP 服务器

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L693-L708
const mcpServersRaw = frontmatter['mcpServers']
let mcpServers: AgentMcpServerSpec[] | undefined
if (Array.isArray(mcpServersRaw)) {
  mcpServers = mcpServersRaw
    .map(item => {
      const result = AgentMcpServerSpecSchema().safeParse(item)
      if (result.success) return result.data
      logForDebugging(`Agent file ${filePath} has invalid mcpServers item...`)
      return null
    })
    .filter((item): item is AgentMcpServerSpec => item !== null)
}
```

MCP 服务器规格支持两种形式：
- 字符串引用：`"slack"` — 引用已配置的 MCP 服务器
- 内联定义：`{ slack: { command: "npx", args: [...] } }` — Agent 启动时连接，结束时清理

##### `hooks` — 生命周期钩子

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L711
const hooks = parseHooksFromFrontmatter(frontmatter, agentType)
```

[`parseHooksFromFrontmatter()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L424-L440) 使用 `HooksSchema` Zod 验证：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L424-L440
function parseHooksFromFrontmatter(frontmatter, agentType): HooksSettings | undefined {
  if (!frontmatter.hooks) return undefined
  const result = HooksSchema().safeParse(frontmatter.hooks)
  if (!result.success) {
    logForDebugging(`Invalid hooks in agent '${agentType}': ${result.error.message}`)
    return undefined
  }
  return result.data
}
```

##### `color` — UI 颜色

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L567
const color = frontmatter['color'] as AgentColorName | undefined
```

有效颜色名由 [`AGENT_COLORS`](../../claude-code-source/src/tools/AgentTool/agentColorManager.ts) 数组定义。

### 3. 正文内容与系统提示词

Markdown 正文（frontmatter 之后的内容）成为 Agent 的系统提示词：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L713-L732
const systemPrompt = content.trim()
const agentDef: CustomAgentDefinition = {
  baseDir,
  agentType: agentType,
  whenToUse: whenToUse,
  // ... 其他字段 ...
  getSystemPrompt: () => {
    if (isAutoMemoryEnabled() && memory) {
      const memoryPrompt = loadAgentMemoryPrompt(agentType, memory)
      return systemPrompt + '\n\n' + memoryPrompt
    }
    return systemPrompt
  },
  source,
  filename,
}
```

【**关键**】`getSystemPrompt()` 通过闭包捕获 `systemPrompt` 和 `memory`，在每次调用时动态拼接记忆内容。

`getSystemPrompt()` 返回的值由 [`getAgentSystemPrompt()`](../../claude-code-source/src/tools/AgentTool/runAgent.ts#L906-L932) 调用，再经 [`enhanceSystemPromptWithEnvDetails()`](../../claude-code-source/src/constants/prompts.ts) 增强环境信息后，最终作为子 Agent 的系统提示词发送给 LLM。

> **MD 正文不是完整的输入提示词**。它只是系统提示词数组的第一个块（block），框架会自动追加通用行为规范（`Notes`）和环境信息（`envInfo`）。完整的 MD 正文 → API 请求转换链详见 [LV062 第三节第 3 小节](LV062-子Agent提示词注入与LLM选择机制.md)。

### 4. whenToUse 中的换行符处理

`description` 字段中的 `\n` 会被 YAML 解析器转义，需要在运行时还原：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L564-L565
// Unescape newlines in whenToUse that were escaped for YAML parsing
whenToUse = whenToUse.replace(/\\n/g, '\n')
```

## 三、目录发现机制

### 1. 扫描入口

[`loadMarkdownFilesForSubdir('agents', cwd)`](../../claude-code-source/src/utils/markdownConfigLoader.ts#L297-L430) 是 Agent 目录扫描的入口，由 [`getAgentDefinitionsWithOverrides()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L296-L393) 调用：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L308
const markdownFiles = await loadMarkdownFilesForSubdir('agents', cwd)
```

### 2. 扫描的目录来源

[`loadMarkdownFilesForSubdir()`](../../claude-code-source/src/utils/markdownConfigLoader.ts#L297-L430) 从三类目录加载 Agent MD 文件：

#### 2.1 Policy（托管策略）目录

```typescript
// src/utils/markdownConfigLoader.ts#L304
const managedDir = join(getManagedFilePath(), '.claude', 'agents')
```

- 路径：`<managedFilePath>/.claude/agents/`
- 来源标记：`policySettings`
- 始终加载

#### 2.2 User（用户全局）目录

```typescript
// src/utils/markdownConfigLoader.ts#L303
const userDir = join(getClaudeConfigHomeDir(), 'agents')
```

- 路径：`~/.claude/agents/`
- 来源标记：`userSettings`
- 需 `isSettingSourceEnabled('userSettings')` 且未受 `strictPluginOnlyCustomization` 限制时才加载

#### 2.3 Project（项目级）目录

```typescript
// src/utils/markdownConfigLoader.ts#L305
const projectDirs = getProjectDirsUpToHome('agents', cwd)
```

- 路径：从 `cwd` 向上遍历至 git root 过程中所有存在的 `.claude/agents/` 目录
- 来源标记：`projectSettings`
- 需 `isSettingSourceEnabled('projectSettings')` 且未受 `strictPluginOnlyCustomization` 限制时才加载

### 3. 项目目录的遍历逻辑

[`getProjectDirsUpToHome()`](../../claude-code-source/src/utils/markdownConfigLoader.ts#L234-L289) 实现从 `cwd` 向上遍历到 git root（或 home 目录），收集所有存在的 `.claude/agents/` 目录：

```typescript
// src/utils/markdownConfigLoader.ts#L234-L289
export function getProjectDirsUpToHome(subdir, cwd): string[] {
  const home = resolve(homedir()).normalize('NFC')
  const gitRoot = resolveStopBoundary(cwd)
  let current = resolve(cwd)
  const dirs: string[] = []

  while (true) {
    // 到达 home 目录时停止（home 目录单独作为 userDir 加载）
    if (normalizePathForComparison(current) === normalizePathForComparison(home)) break
    const claudeSubdir = join(current, '.claude', subdir)
    try {
      statSync(claudeSubdir)
      dirs.push(claudeSubdir)  // 目录存在，加入列表
    } catch (e: unknown) {
      if (!isFsInaccessible(e)) throw e  // 非权限错误，向上抛出
    }
    // 到达 git root 时停止
    if (gitRoot && normalizePathForComparison(current) === normalizePathForComparison(gitRoot)) break
    const parent = dirname(current)
    if (parent === current) break  // 到达文件系统根
    current = parent
  }
  return dirs
}
```

### 4. 停止边界解析

[`resolveStopBoundary()`](../../claude-code-source/src/utils/markdownConfigLoader.ts#L191-L220) 处理嵌套 Git 仓库的边界问题：

```typescript
// src/utils/markdownConfigLoader.ts#L191-L220
function resolveStopBoundary(cwd: string): string | null {
  const cwdGitRoot = findGitRoot(cwd)
  const sessionGitRoot = findGitRoot(getProjectRoot())
  if (!cwdGitRoot || !sessionGitRoot) return cwdGitRoot

  const cwdCanonical = findCanonicalGitRoot(cwd)
  // 相同规范仓库（主仓库或其 Worktree）→ 停在最近 .git
  if (cwdCanonical && normalizePathForComparison(cwdCanonical) ===
      normalizePathForComparison(sessionGitRoot)) {
    return cwdGitRoot
  }
  // 不同规范仓库，且嵌套在项目树内 → 跳过嵌套仓库，停在项目根
  if (nCwdGitRoot !== nSessionRoot && nCwdGitRoot.startsWith(nSessionRoot + sep)) {
    return sessionGitRoot
  }
  return cwdGitRoot  // 兄弟仓库或其他位置
}
```

【**场景**】当 Bash 工具 `cd` 进入项目内的子模块（有独立 `.git`）时，需要跳过子模块的 Git 边界，继续向上查找到项目根的 `.claude/agents/`。

### 5. Git Worktree 回退

当处于 Git Worktree 且其目录下没有 `.claude/agents/` 时，回退到主仓库的副本：

```typescript
// src/utils/markdownConfigLoader.ts#L320-L335
if (gitRoot && canonicalRoot && canonicalRoot !== gitRoot) {
  const worktreeHasSubdir = projectDirs.some(
    dir => normalizePathForComparison(dir) === worktreeSubdir,
  )
  if (!worktreeHasSubdir) {
    const mainClaudeSubdir = join(canonicalRoot, '.claude', subdir)
    if (!projectDirs.includes(mainClaudeSubdir)) {
      projectDirs.push(mainClaudeSubdir)
    }
  }
}
```

### 6. 文件去重

从不同路径加载后，通过 inode 去重以处理符号链接导致的重复：

```typescript
// src/utils/markdownConfigLoader.ts#L159-L172
async function getFileIdentity(filePath: string): Promise<string | null> {
  try {
    const stats = await lstat(filePath, { bigint: true })
    // NFS/FUSE 等文件系统报告 dev=0, ino=0 → 跳过去重
    if (stats.dev === 0n && stats.ino === 0n) return null
    return `${stats.dev}:${stats.ino}`
  } catch { return null }
}
```

使用 `bigint: true` 处理大型 inode（如 ExFAT），避免 Number 精度丢失导致的误判。

## 四、Frontmatter 解析

### 1. 解析流程

MD 文件的 frontmatter 解析由 [`parseFrontmatter()`](../../claude-code-source/src/utils/frontmatterParser.ts#L130-L175) 完成：

```typescript
// src/utils/frontmatterParser.ts
FRONTMATTER_REGEX = /^---\s*\n([\s\S]*?)---\s*\n?/
```

1. 使用正则提取 `---` 分隔的 YAML 头部
2. 调用 `parseYaml()` 解析 YAML 内容
3. 若解析失败，尝试 [`quoteProblematicValues()`](../../claude-code-source/src/utils/frontmatterParser.ts#L85-L121) 修复特殊字符后重试
4. 返回 `{ frontmatter, content }` —— `content` 是去除 frontmatter 后的 Markdown 正文

### 2. 从 Markdown 构建 Agent 定义

[`parseAgentFromMarkdown()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L541-L755) 完整解析流程：

1. 提取 `agentType` ← `frontmatter['name']`
2. 提取 `whenToUse` ← `frontmatter['description']`（转义换行符还原）
3. 验证必填字段
4. 逐一解析可选字段（color, model, background, memory, isolation, effort, permissionMode, maxTurns, tools, disallowedTools, skills, initialPrompt, mcpServers, hooks）
5. 提取 `filename` ← `basename(filePath, '.md')`
6. 构建 `getSystemPrompt()` 闭包（捕获 `systemPrompt` 和 `memory`）
7. 组装 `CustomAgentDefinition` 对象

### 3. 解析错误的分类处理

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L312-L342
const agent = parseAgentFromMarkdown(filePath, baseDir, frontmatter, content, source)
if (!agent) {
  if (!frontmatter['name']) {
    return null  // 非 Agent 文档（如参考文档），静默跳过
  }
  // 有 name 但解析失败 → 报告错误
  const errorMsg = getParseError(frontmatter)
  failedFiles.push({ path: filePath, error: errorMsg })
  logEvent('tengu_agent_parse_error', { error: errorMsg, location: source })
  return null
}
```

[`getParseError()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L403-L416) 辅助函数判断具体缺失字段：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L403-L416
function getParseError(frontmatter: Record<string, unknown>): string {
  const agentType = frontmatter['name']
  const description = frontmatter['description']
  if (!agentType || typeof agentType !== 'string') {
    return 'Missing required "name" field in frontmatter'
  }
  if (!description || typeof description !== 'string') {
    return 'Missing required "description" field in frontmatter'
  }
  return 'Unknown parsing error'
}
```

## 五、从 JSON 定义 Agent

除 MD 文件外，Agent 也可通过 JSON 定义（CLI 参数 `--agent` 或设置项），由 [`parseAgentFromJson()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L445-L516) 解析。

### 1.JSON Schema

使用 [`AgentJsonSchema`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L73-L99) Zod schema 校验：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L73-L99
const AgentJsonSchema = lazySchema(() =>
  z.object({
    description: z.string().min(1, 'Description cannot be empty'),
    tools: z.array(z.string()).optional(),
    disallowedTools: z.array(z.string()).optional(),
    prompt: z.string().min(1, 'Prompt cannot be empty'),  // 注意：JSON 用 prompt，MD 用正文
    model: z.string().trim().min(1).transform(m =>
      m.toLowerCase() === 'inherit' ? 'inherit' : m
    ).optional(),
    effort: z.union([z.enum(EFFORT_LEVELS), z.number().int()]).optional(),
    permissionMode: z.enum(PERMISSION_MODES).optional(),
    mcpServers: z.array(AgentMcpServerSpecSchema()).optional(),
    hooks: HooksSchema().optional(),
    maxTurns: z.number().int().positive().optional(),
    skills: z.array(z.string()).optional(),
    initialPrompt: z.string().optional(),
    memory: z.enum(['user', 'project', 'local']).optional(),
    background: z.boolean().optional(),
    isolation: (process.env.USER_TYPE === 'ant'
      ? z.enum(['worktree', 'remote'])
      : z.enum(['worktree'])
    ).optional(),
  }),
)
```

### 2.JSON 与 MD 的差异

| 方面 | MD 文件 | JSON 定义 |
|------|---------|-----------|
| 系统提示词 | Markdown 正文 | `prompt` 字段 |
| 类型标识 | `name` 字段 | JSON 对象的键名 |
| 校验方式 | 逐字段手动解析 + 日志 | Zod schema 自动校验 |
| 来源标记 | 由目录位置决定 | `flagSettings`（默认） |

### 3. 批量 JSON 解析

[`parseAgentsFromJson()`](../../claude-code-source/src/tools/AgentTool/loadAgentsDir.ts#L521-L536) 支持一次解析多个 Agent：

```typescript
// src/tools/AgentTool/loadAgentsDir.ts#L521-L536
export function parseAgentsFromJson(agentsJson: unknown, source = 'flagSettings'): AgentDefinition[] {
  const parsed = AgentsJsonSchema().parse(agentsJson)
  return Object.entries(parsed)
    .map(([name, def]) => parseAgentFromJson(name, def, source))
    .filter((agent): agent is CustomAgentDefinition => agent !== null)
}
```

## 六、自定义 Agent 定义示例

### 1. 最小化定义

```markdown
---
name: code-reviewer
description: 审查代码变更，提供改进建议
---

你是一个专业的代码审查员。审查用户提交的代码变更，关注以下方面：
- 代码质量和可读性
- 潜在的 bug 和安全问题
- 性能优化建议
- 最佳实践建议
```

### 2. 只读搜索 Agent

```markdown
---
name: api-finder
description: 在代码库中搜索 API 端点定义
tools:
  - Grep
  - Glob
  - Read
  - Bash
disallowedTools:
  - Write
  - Edit
model: haiku
effort: low
omitClaudeMd: true
---

你是 API 端点搜索专家。找到所有 API 端点定义，报告其位置、HTTP 方法和路径模式。
```

### 3. 完整定义

```markdown
---
name: test-runner
description: 在编写代码后运行测试，确保实现正确
tools:
  - Bash
  - Read
  - Grep
disallowedTools:
  - Write
model: haiku
effort: low
permissionMode: acceptEdits
maxTurns: 10
background: true
memory: project
color: green
initialPrompt: /run-tests
hooks:
  PreToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: echo "Running test command"
mcpServers:
  - test-framework
---

你是一个测试运行 Agent。你的职责是：
1. 运行项目测试套件
2. 分析测试结果
3. 报告失败的测试及其原因

不要修改任何文件，只运行测试并报告结果。
```

### 4. 带 MCP 服务器的 Agent

```markdown
---
name: database-analyst
description: 分析数据库结构和查询性能
tools:
  - Read
  - Grep
  - Bash
mcpServers:
  - postgres                    # 引用已配置的 MCP 服务器
  - admin-db:                   # 内联定义
      command: npx
      args: ["-y", "@modelcontextprotocol/server-postgres", "postgresql://..."]
requiredMcpServers:
  - postgres                    # 必须连接才能使用
---

你是一个数据库分析专家。使用 MCP 工具查询数据库结构，分析查询性能，提供优化建议。
```

### 5. Agent 工具嵌套控制

```markdown
---
name: limited-worker
description: 执行有限的代码搜索任务
tools:
  - Grep
  - Read
  - "Agent(researcher,explorer)"  # 只允许调用 researcher 和 explorer 两种子 Agent
---

你是一个有限工作 Agent。可以搜索代码，也可以委托给 researcher 或 explorer 子 Agent。
```

## 七、插件 Agent

插件 Agent 由 [`loadPluginAgents()`](../../claude-code-source/src/utils/plugins/loadPluginAgents.ts) 加载，其 `agentType` 格式为 `pluginName:agentName`，`source` 为 `'plugin'`。插件 Agent 的定义与自定义 Agent 结构相同，只是来源不同。

插件 Agent 的额外特性：
- `agentType` 格式：`pluginName:agentName`，如 `my-plugin:code-reviewer`
- 技能名称解析支持插件命名空间：Agent 定义的 `skills` 中的 `my-skill` 会尝试解析为 `my-plugin:my-skill`
- 管理员信任：在 `strictPluginOnlyCustomization` 策略下，插件 Agent 的 MCP 服务器和钩子不受限制

---
*本文档由 markdowncli 技能辅助生成*

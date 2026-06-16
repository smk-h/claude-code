<!-- more -->

## 一、 概述

本文档分析 Claude Code 中 Skills 的目录扫描机制——系统在哪些目录下查找 Skills，以及这些目录的优先级与遍历逻辑。

Skills 的目录发现由 [`getSkillDirCommands()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L638-L804) 函数统一调度，该函数使用 `memoize` 缓存，确保同一 `cwd` 下只扫描一次。

## 二、 目录来源与扫描路径

### 1. Policy（托管策略）目录

```typescript
// src/skills/loadSkillsDir.ts#L641
const managedSkillsDir = join(getManagedFilePath(), '.claude', 'skills')
```

- 路径：`<managedFilePath>/.claude/skills/`
- 来源标记：`policySettings`
- 可通过环境变量 `CLAUDE_CODE_DISABLE_POLICY_SKILLS` 禁用
- 当 `skillsLocked` 为真时跳过

### 2. User（用户全局）目录

```typescript
// src/skills/loadSkillsDir.ts#L640
const userSkillsDir = join(getClaudeConfigHomeDir(), 'skills')
```

- 路径：`~/.claude/skills/`
- 来源标记：`userSettings`
- 需 `isSettingSourceEnabled('userSettings')` 且未锁定时才加载

### 3. Project（项目级）目录

```typescript
// src/skills/loadSkillsDir.ts#L642
const projectSkillsDirs = getProjectDirsUpToHome('skills', cwd)
```

- 路径：从 `cwd` 向上遍历至 git root（或 home 目录）过程中所有存在的 `.claude/skills/` 目录
- 来源标记：`projectSettings`
- 遍历逻辑由 [`getProjectDirsUpToHome()`](../../claude-code-source/src/utils/markdownConfigLoader.ts#L234-L289) 实现
- 需 `isSettingSourceEnabled('projectSettings')` 且未锁定时才加载

### 4. Additional（`--add-dir`）目录

```typescript
// src/skills/loadSkillsDir.ts#L649
const additionalDirs = getAdditionalDirectoriesForClaudeMd()
```

- 路径：`<addDir>/.claude/skills/`，对每个 `--add-dir` 参数
- 来源标记：`projectSettings`

### 5. Legacy Commands（遗留命令）目录

```typescript
// src/skills/loadSkillsDir.ts#L713
skillsLocked ? Promise.resolve([]) : loadSkillsFromCommandsDir(cwd),
```

- 路径：与 skills 同级层级的 `.claude/commands/` 和 `~/.claude/commands/` 目录
- 来源标记：`commands_DEPRECATED`
- 同时支持目录格式（`SKILL.md`）和单文件 `.md` 格式

## 三、 项目目录向上遍历逻辑

[`getProjectDirsUpToHome()`](../../claude-code-source/src/utils/markdownConfigLoader.ts#L234-L289) 的遍历规则：

1. 从 `cwd` 开始，逐级向上至 home 目录
2. 每一级检查 `<current>/.claude/skills/` 是否存在（通过 `statSync`）
3. 在 git root 处停止——防止父仓库的 skills 泄漏到子项目
4. 不检查 home 目录本身（home 级别由 user 目录单独处理）

```typescript
// src/utils/markdownConfigLoader.ts#L244-L286
while (true) {
  // 到达 home 目录时停止（不检查，因为由 userDir 单独处理）
  if (normalizePathForComparison(current) === normalizePathForComparison(home)) {
    break
  }
  const claudeSubdir = join(current, '.claude', subdir)
  try {
    statSync(claudeSubdir)
    dirs.push(claudeSubdir)
  } catch (e: unknown) {
    if (!isFsInaccessible(e)) throw e
  }
  // 在 git root 处停止
  if (gitRoot && normalizePathForComparison(current) === normalizePathForComparison(gitRoot)) {
    break
  }
  const parent = dirname(current)
  if (parent === current) break
  current = parent
}
```

### 1. Git Root 边界解析

[`resolveStopBoundary()`](../../claude-code-source/src/utils/markdownConfigLoader.ts#L191-L220) 处理嵌套 git 仓库场景：

- 如果 `cwd` 的 git root 与 session git root 属于不同的 canonical 仓库，且嵌套在 session 项目树内，则将边界扩展到 session git root
- Worktree（`.claude/worktrees/`）保持原有行为

## 四、 Bare 模式

当 `--bare` 模式启用时，跳过所有自动发现（managed/user/project/legacy），仅加载 `--add-dir` 路径：

```typescript
// src/skills/loadSkillsDir.ts#L658-L675
if (isBareMode()) {
  if (additionalDirs.length === 0 || !projectSettingsEnabled) {
    return []
  }
  const additionalSkillsNested = await Promise.all(
    additionalDirs.map(dir =>
      loadSkillsFromSkillsDir(join(dir, '.claude', 'skills'), 'projectSettings'),
    ),
  )
  return additionalSkillsNested.flat().map(s => s.skill)
}
```

## 五、 动态目录发现

除启动时加载的目录外，系统还支持运行时动态发现 skills 目录：

### 1. 文件操作触发

[`discoverSkillDirsForPaths()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L861-L915) 在文件读/写/编辑操作时，从操作文件路径向上遍历至 `cwd`，查找 `.claude/skills/` 目录：

- 跳过已检查过的路径（避免重复 stat）
- 跳过 gitignored 的目录
- 结果按路径深度降序排列（更深的目录优先级更高）

### 2. 条件激活 Skills

[`activateConditionalSkillsForPaths()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L997-L1058) 处理带有 `paths` frontmatter 的条件 skills：

- 使用 `ignore` 库（gitignore 风格匹配）检测文件路径是否匹配 skill 的 `paths` 模式
- 匹配时将 skill 从 `conditionalSkills` 移至 `dynamicSkills`
- 一旦激活，在会话内保持激活状态（`activatedConditionalSkillNames`）

## 六、 去重机制

所有来源的 skills 加载后，通过 [`getFileIdentity()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L116) 进行去重：

```typescript
// src/skills/loadSkillsDir.ts#L728-L763
const fileIds = await Promise.all(
  allSkillsWithPaths.map(({ skill, filePath }) =>
    skill.type === 'prompt' ? getFileIdentity(filePath) : Promise.resolve(null),
  ),
)
```

- 使用 `realpath()` 解析符号链接获取规范路径
- 先到先得：按 managed → user → project → additional → legacy 的顺序，同文件只保留第一个
- 跳过 dev=0 && ino=0 的不可靠文件系统标识

## 七、 其他 Skills 来源

### 1. Bundled Skills（内置）

[`bundledSkills.ts`](../../claude-code-source/src/skills/bundledSkills.ts#L44-L100) 在模块初始化时通过 [`registerBundledSkill()`](../../claude-code-source/src/skills/bundledSkills.ts#L51) 注册，不走文件系统：

```typescript
// src/skills/bundledSkills.ts#L53-L100
export function registerBundledSkill(definition: BundledSkillDefinition): void {
  // ...
  bundledSkills.push(command)
}
```

### 2. Plugin Skills

通过 [`getPluginSkills()`](../../claude-code-source/src/utils/plugins/loadPluginCommands.ts) 从已安装的插件中加载。

### 3. MCP Skills

通过 [`getMcpSkillCommands()`](../../claude-code-source/src/commands.ts#L547-L559) 从 MCP 服务器连接中获取，过滤条件为 `type === 'prompt'` 且 `loadedFrom === 'mcp'` 且 `!disableModelInvocation`。

## 八、 实例分析：markdowncli skill 的目录发现

以 `~/.claude/skills/markdowncli/SKILL.md` 为例，追踪该 skill 如何被发现：

### 1. 所属目录类型

`markdowncli` skill 位于 `~/.claude/skills/markdowncli/SKILL.md`，属于 **User（用户全局）目录** 类型：

```typescript
// src/skills/loadSkillsDir.ts#L640
const userSkillsDir = join(getClaudeConfigHomeDir(), 'skills')
// 解析为 /root/.claude/skills/
```

实际文件结构：

```
~/.claude/skills/
└── markdowncli/
    └── SKILL.md
```

### 2. 扫描过程

1. [`getSkillDirCommands()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L638-L804) 被调用，按优先级依次扫描
2. 扫描到 `userSkillsDir = /root/.claude/skills/` 时，调用 [`loadSkillsFromSkillsDir()`](../../claude-code-source/src/skills/loadSkillsDir.ts#L414-L530)
3. 遍历 `/root/.claude/skills/` 下的条目，发现 `markdowncli` 子目录
4. 检查 `markdowncli` 是目录（`entry.isDirectory()` 为 `true`），符合目录格式要求
5. 读取 `/root/.claude/skills/markdowncli/SKILL.md` 文件内容

```typescript
// src/skills/loadSkillsDir.ts#L424-L428
// Only support directory format: skill-name/SKILL.md
if (!entry.isDirectory() && !entry.isSymbolicLink()) {
  return null  // 单独的 .md 文件在 /skills/ 目录下不被支持
}
```

### 3. 前置条件检查

该 skill 被加载需满足：

- `isSettingSourceEnabled('userSettings')` 返回 `true`（用户设置源启用）
- `skillsLocked` 为 `false`（未被策略锁定）
- 未被更高优先级的同名 skill 覆盖（managed skills 优先）

### 4. 与其他目录类型的对比

如果将同一个 `markdowncli` skill 放在不同目录，优先级为：

| 优先级 | 目录 | 路径 |
| --- | --- | --- |
| 1（最高） | Managed | `<managedFilePath>/.claude/skills/markdowncli/SKILL.md` |
| 2 | User（实际位置） | `~/.claude/skills/markdowncli/SKILL.md` |
| 3 | Project | `<project>/.claude/skills/markdowncli/SKILL.md` |
| 4 | Additional | `<addDir>/.claude/skills/markdowncli/SKILL.md` |
| 5（最低） | Legacy Commands | `~/.claude/commands/markdowncli.md` |

当前 `markdowncli` 在 User 目录中，若无同名 managed skill，则该 skill 会被正常加载。

---

*本文档由 markdowncli 技能辅助生成*

<!-- more -->

## 一、 概述

前序文档（LV040-LV044）从源码层面分析了 Skills 的扫描、解析、加载与注入机制。本文档则聚焦于 **Skill 的设计层面**——如何写好一个 Skill，使其能被模型准确调用、高质量执行，并在团队中高效分发。

本文档内容综合自 Anthropic 博客《Lessons from building Claude Code: How we use skills》及其内部实践，结合 Claude Code 源码验证后整理而成。文中涉及的技术机制均可与 LV040-LV044 交叉参照。

## 二、 Skill 的本质：文件夹而非单文件

### 1. 常见误解

最大误解是把 Skill 等同于"一个写了操作步骤的 markdown 文件"。实际上，Skill 是一个**文件夹系统**——除了 `SKILL.md` 这个唯一必需文件，还可以包含脚本、参考资料、数据文件、输出模板，模型能自行发现、探索和使用这些资源。

### 2. 完整的 Skill 目录结构

以一个"部署服务" Skill 为例：

```
deploy-service/
├── SKILL.md               # 唯一必需：何时用 + 操作指引 + 坑点清单
├── references/            # 参考资料，正文放不下的细节放这里
│   ├── api.md             # 部署平台 API 的详细参数和示例
│   └── troubleshooting.md # 部署失败时的排查手册
├── scripts/               # 现成的可执行脚本
│   ├── smoke_test.sh      # 冒烟测试
│   └── rollback.sh        # 一键回滚
└── assets/                # 输出模板
    └── release_note.md    # 发布报告的固定格式
```

### 3. 子文件的按需加载

子目录中的文件**不会一股脑塞给模型**。`references/`、`scripts/`、`assets/` 都是可选的，名字也不强制。它们遵循渐进式披露的第三层机制——模型在调用 Skill、拿到完整正文后，才会根据正文中的引用（如"详见 `references/troubleshooting.md`"）自行通过 Read/Glob 等工具读取。

> **技术依据**：调用 Skill 时注入的 `Base directory for this skill: ${baseDir}` 前缀，正是为了让模型能将正文中的相对路径解析到 Skill 实际目录。详见 [LV042 第二节 3. 第三层](LV042-Skills加载策略与上下文注入.md)。

## 三、 Skills 的九大分类

Anthropic 内部几百个 Skill 自然归为 9 类。理解分类有助于判断一个 Skill 该不该做、该放在哪。

| 类别 | 干什么的 | 例子 |
|------|---------|------|
| 库和 API 参考 | 教模型正确使用某个内部库或 CLI | 内部计费库的边界情况和坑 |
| 产品验证 | 教模型怎么测试自己写的代码 | 用无头浏览器跑通注册流程并逐步断言 |
| 数据查询分析 | 连接数据和监控系统 | 该 join 哪些表才能看到转化漏斗 |
| 业务流程自动化 | 把重复工作流压成一条命令 | 自动聚合工单和 PR 生成站会日报 |
| 代码脚手架 | 按团队规范生成样板代码 | 新建一个预接好鉴权和日志的内部应用 |
| 代码质量与审查 | 在组织内强制执行代码质量 | 派一个全新视角的子 agent 做对抗式审查 |
| CI/CD 与部署 | 拉取、推送、部署代码 | 盯着 PR 重试不稳定的 CI、解决冲突 |
| Runbook 排障手册 | 从一个报警症状出发做多工具排查 | 给一个请求 ID，把所有系统的相关日志拉齐 |
| 基础设施运维 | 带护栏的例行维护操作 | 清理孤儿资源前先发 Slack 等人工确认 |

### 1. 分类原则

- 最好的 Skill 干干净净落在某一类里；横跨多类的 Skill 会把 agent 搞糊涂
- 如果一个 Skill 试图同时做"代码脚手架"和"CI/CD 部署"，应该拆成两个

### 2. 验证类 Skill 值得优先投入

【**关键结论**】

**验证类 Skill 是对模型输出质量提升最明显的一类**，值得让工程师花一整周专门打磨。这类 Skill 让模型能自己确认工作成果（如跑通注册流程、断言 API 返回值），形成"写 → 验证 → 修正"的闭环，而非写完就交给人审。

## 四、 frontmatter 的写法：description 是触发条件

### 1. 核心原则

> description 不是写给人看的摘要，是写给模型看的**触发条件**。

发现阶段模型看到的只有 `name + description`（+ 可选的 `when_to_use`），这是模型决定是否调用该 Skill 的唯一依据。详见 [LV042 第二节 1. 发现阶段](LV042-Skills加载策略与上下文注入.md)。

### 2. 反面 vs 正面示例

| 写法 | 示例 | 问题 |
|------|------|------|
| ❌ 人类视角摘要 | "帮助处理数据库相关工作" | 模型无法判断何时该用 |
| ✅ 模型视角触发条件 | "当用户要写数据库迁移、修改表结构、或者遇到 migration 报错时使用" | 明确命中场景 |

### 3. 关键约束

- 前 **250 个字符**决定 Skill 是工具还是摆设（受 `MAX_LISTING_DESC_CHARS = 250` 限制，超出直接截断为省略号）
- 装太多 Skill 会互相挤占清单预算（上下文窗口的 1%），**贵精不贵多**
- 如果 `description` 不足以表达触发条件，可补充 `when_to_use` 字段（详见 [LV042 第二节 1.1](LV042-Skills加载策略与上下文注入.md)）

### 4. Frontmatter 字段参考

除了 Markdown 内容外，可以在 `SKILL.md` 文件顶部 `---` 标记之间使用 YAML frontmatter 字段配置 Skill 行为。所有字段都是可选的，但**推荐使用 `description`**，以便模型知道何时使用该 Skill。

```yaml
---
name: my-skill
description: What this skill does
disable-model-invocation: true
allowed-tools: Read Grep
---

Your skill instructions here...
```

完整字段说明：

| 字段 | 必需 | 描述 |
|------|:----:|------|
| `name` | 否 | Skill 列表中显示的显示名称。默认为目录名称。注意这与 `/` 后输入的调用名称可能不同 |
| `description` | 推荐 | Skill 的功能以及何时使用。模型用它决定何时应用该 Skill。如果省略，使用 Markdown 内容的第一段。**将关键用例放在前面**：官方文档指出组合的 `description` 和 `when_to_use` 文本在 Skill 列表中被截断为 1,536 个字符以减少上下文使用（注：当前版本源码分析值为 `MAX_LISTING_DESC_CHARS = 250` 字符/条，见 [LV042 第四节](LV042-Skills加载策略与上下文注入.md)，两者可能存在版本差异） |
| `when_to_use` | 否 | 关于模型何时应该调用该 Skill 的额外上下文，例如触发短语或示例请求。附加到 Skill 列表中的 `description`，并计入截断上限 |
| `argument-hint` | 否 | 自动完成期间显示的提示，指示预期的参数。示例：`[issue-number]` 或 `[filename] [format]` |
| `arguments` | 否 | 用于 Skill 内容中 `$name` 替换的命名位置参数。接受空格分隔的字符串或 YAML 列表。名称按顺序映射到参数位置 |
| `disable-model-invocation` | 否 | 设置为 `true` 以防止模型自动加载此 Skill。用于你想使用 `/name` 手动触发的工作流。也防止该 Skill 被预加载到 subagents 中。默认值：`false` |
| `user-invocable` | 否 | 设置为 `false` 以从 `/` 菜单中隐藏。用于用户不应直接调用的背景知识。默认值：`true` |
| `allowed-tools` | 否 | 当此 Skill 处于活动状态时，模型可以使用而无需请求权限的工具。接受空格分隔的字符串或 YAML 列表 |
| `disallowed-tools` | 否 | 当此 Skill 处于活动状态时从模型的可用工具池中移除的工具。用于不应该调用某些工具的自主 Skills，例如用于后台循环的 `AskUserQuestion`。接受空格分隔的字符串或 YAML 列表。当你发送下一条消息时，限制会清除 |
| `model` | 否 | 当此 Skill 处于活动状态时要使用的模型。覆盖适用于当前轮的其余部分，不保存到设置；会话模型在下一个提示时恢复。接受与 `/model` 相同的值，或 `inherit` 以保持活动模型 |
| `effort` | 否 | 当此 Skill 处于活动状态时的工作量级别。覆盖会话工作量级别。默认值：继承自会话。选项：`low`、`medium`、`high`、`xhigh`、`max`；可用级别取决于模型 |
| `context` | 否 | 设置为 `fork` 以在分叉的 subagent 上下文中运行 |
| `agent` | 否 | 当设置 `context: fork` 时要使用的 subagent 类型 |
| `hooks` | 否 | 限定于此 Skill 生命周期的 hooks。注册为会话级钩子，详见 [LV041 第四节 3. hooks 字段的会话级注册](LV041-Skills-MD文件解析与内容注入.md) |
| `paths` | 否 | Glob 模式，限制何时激活此 Skill。接受逗号分隔的字符串或 YAML 列表。设置后，模型仅在处理与模式匹配的文件时自动加载该 Skill |
| `shell` | 否 | 用于此 Skill 中 `` !`command` `` 和 ` ```! ` 块的 shell。接受 `bash`（默认）或 `powershell`。设置 `powershell` 在 Windows 上通过 PowerShell 运行内联 shell 命令。需要 `CLAUDE_CODE_USE_POWERSHELL_TOOL=1` |

## 五、 SKILL.md 正文的写法

### 1. 黄金法则

> 只写模型推断不出来的，删掉它本来就会的。

### 2. 反面：不要陈述显而易见的事

❌ "写完代码后要运行测试，确保所有用例通过。"

模型本来就会做，写了等于灌噪音，反而稀释真正的信号。

### 3. 正面：坑点清单（Gotchas）—— 信号最强的内容

坑点的特征：**模型靠读代码永远推断不出来，只有踩过坑的人才知道**。

真实坑点案例：

1. `subscriptions 表是只追加不修改的，你要找的那行记录是 version 最大的那条，不是 created_at 最新的那条`

2. `这个字段在 API 网关里叫 @request_id，在计费服务里叫 trace_id，它们是同一个值`

3. `staging 环境就算 Stripe 的回调没真正处理，也会返回 200，真实状态要去 payment_events 表里查`

### 4. 官方前端设计 Skill 示例

整篇没教模型怎么写 CSS，而是列了一堆"不要做"：

- 不要张口就用 Inter 字体
- 不要动不动紫色渐变

### 5. 避免 railroading（别把模型锁死在轨道上）

#### 5.1 什么是 railroading

步骤写得太死，模型遇到指令没覆盖的情况会僵在轨道上硬开。例如：

❌ "第一步执行 A，第二步执行 B，第三步执行 C。"

当实际情况需要跳过 B 或在 A、C 之间插入额外步骤时，模型会不知所措。

#### 5.2 正确姿势

把需要的信息给足，把怎么走的自由留给模型：

✅ "目标状态是 X。需要注意的坑有 A、B、C。可用的工具和脚本在 `scripts/` 目录下。"

### 6. 正文长度建议

结合 compaction 截断机制（详见 [LV042 第五节 5.3](LV042-Skills加载策略与上下文注入.md)）：

| 策略 | 原因 |
|------|------|
| 把最重要的指令放在文件头部 | compaction 截断保留头部，尾部可能丢失 |
| 正文控制在 5000 token（约 20KB）以内 | 超出部分 compaction 后会被截断 |
| 同一会话避免调用多个大 Skill | 总预算 25000 token，5 个大 Skill 就满了 |
| 放不下的细节移入 `references/` 子目录 | 按需加载，不占初始正文开销 |

## 六、 三个高阶玩法

### 1. 给 Skill 装记忆

#### 1.1 场景

自动写站会日报的 Skill，需要知道哪些内容昨天已汇报过。如果每次都从零开始，会重复汇报。

#### 1.2 解法

让 Skill 把执行结果存在自己的文件夹里：

- 简单场景：追加式文本日志或 JSON
- 复杂场景：塞一个 SQLite 数据库

#### 1.3 数据目录的获取

正文中的 `${CLAUDE_SKILL_DIR}` 变量会被替换为 Skill 目录的绝对路径（详见 [LV041 第五节](LV041-Skills-MD文件解析与内容注入.md)）。Skill 可将数据写入 `${CLAUDE_SKILL_DIR}/state.json`，在后续调用中读取。

对于通过插件分发的 Skill，可使用 `${CLAUDE_PLUGIN_DATA}` 获取独立于版本升级的持久数据目录——该目录在插件升级时不会被清除，只有彻底卸载才删除（见 [`getPluginDataDir()`](../../claude-code-source/src/utils/plugins/pluginDirectories.ts#L102-L123)）。

#### 1.4 变种用法：存配置

- 第一次运行时主动向用户收集信息（如日报发到哪个频道）
- 写入 Skill 目录下的 `config.json`
- 后续执行先看配置在不在，在就直接用
- 可指明让模型用选择题形式收集，用户点一下就配置完

### 2. 把脚本喂给模型，让它只管编排

#### 2.1 思路

在 `scripts/` 子目录预放函数库，把取数、清洗、对比等底层活封装成现成脚本。

#### 2.2 效果

模型的每个回合花在"组合哪几个脚本"上，而不是重新发明轮子。

#### 2.3 示例

问"周二的数据怎么了"→ 模型现场写十几行小脚本，组合函数库跑出答案，而非从零实现数据查询逻辑。

### 3. 挂只在 Skill 激活期间生效的 Hook

#### 3.1 机制

在 Skill 的 frontmatter 里声明 `hooks`，Skill 被调用时自动注册为会话级钩子，会话结束自动失效。详见 [LV041 第四节 3. hooks 字段的会话级注册](LV041-Skills-MD文件解析与内容注入.md)。

#### 3.2 案例 1：careful Skill

- 激活后自动阻断 `rm -rf`、`DROP TABLE`、强制推送等危险命令
- 常驻开着会逼疯人，手动激活时才恰到好处

#### 3.3 案例 2：freeze Skill

- 激活后禁止修改指定目录之外的任何文件
- 专治"只想加两行日志，结果模型顺手把无关代码也修了"

## 七、 团队分发与共享

### 1. 分发路径一：提交进代码仓库

- 放在 `.claude/skills` 目录下
- 团队成员拉代码时 Skill 自动同步
- **隐性代价**：每多一个 Skill，所有人每次会话都多一行清单，无差别承担 context 开销

### 2. 分发路径二：做成 plugin + 内部 marketplace

- Skill 打包上架，谁需要谁安装
- context 成本回归"谁用谁付"
- 新人入职装一遍团队插件即可

### 3. Marketplace 的准入机制（Anthropic 内部实践）

- **没有中心化审批团队**
- 流程：写好 Skill → 扔进 GitHub 沙盒文件夹 → Slack 吆喝 → 口碑好 → 作者提 PR 挪进正式 marketplace
- 好东西靠口碑自己长出来，不靠委员会评

### 4. Skill 之间的依赖管理

- 目前**没有原生支持**
- 解法：在 Skill 正文里直接报另一个 Skill 的名字
- 示例：正文写"用 file-upload skill 把结果传上去"，只要对方装了，模型自己会去调用

## 八、 数据埋点与使用统计

### 1. 埋点方法

使用 `PreToolUse` hook 监听 Skill 工具的每一次调用，记录"谁在什么时候用了哪个 Skill"。

### 2. 能发现的两类问题

| 类型 | 表现 | 行动 |
|------|------|------|
| 受欢迎的 Skill | 调用量大 | 重点维护、优先打磨 |
| 触发不足（undertriggering） | 预期高频但几乎没人用 | description 没写对，回去修 |

### 3. 成本

- 一个 hook + 一段日志脚本
- 官方已开源示例代码

## 九、 总结

### 1. 三句话核心

1. **Skill 是文件夹不是文件**——把脚本、坑点清单、记忆文件、临时 hook 都用上，才是一个完整的工作系统

2. **决定 Skill 命运的是 description 的前 250 个字符**——写成"什么场景下用我"的触发条件，贵精不贵多

3. **如果只做一件事，先做验证类 Skill**——让模型能自己确认工作成果，这是实测回报最大的投入

### 2. 与源码文档的对应关系

| 最佳实践 | 源码依据 |
|----------|----------|
| description 是触发条件 | [LV042 第二节 1. 发现阶段](LV042-Skills加载策略与上下文注入.md) |
| Skill 是文件夹系统 | [LV042 第二节 3. 第三层](LV042-Skills加载策略与上下文注入.md) |
| 正文头部放核心指令 | [LV042 第五节 5.2.2 Compaction 保底](LV042-Skills加载策略与上下文注入.md) |
| 贵精不贵多 | [LV042 第四节预算控制](LV042-Skills加载策略与上下文注入.md) |
| Hook 激活期间生效 | [LV041 第四节 3. hooks 字段的会话级注册](LV041-Skills-MD文件解析与内容注入.md) |
| Skill 记忆机制 | [LV041 第五节 1. 内容变换步骤](LV041-Skills-MD文件解析与内容注入.md) |

>参考资料: 
>
>[Anthropic 博客《Lessons from building Claude Code: How we use skills》](https://claude.com/blog/lessons-from-building-claude-code-how-we-use-skills)
>
>[Claude Code skill 官方文档](https://code.claude.com/docs/en/skills)
>
>[官方示例 skill 仓库](https://github.com/anthropics/skills)
>
>[Agent Skills 社区站点](https://agentskills.io/home)

---

*本文档由 markdowncli 技能辅助生成*

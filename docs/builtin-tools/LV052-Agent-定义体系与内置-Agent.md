<!-- more -->

## 一、 概述

Claude Code 的子 Agent 定义体系、内置 Agent、Fork 机制及提示词生成等内容,已在 `docs/llm-client` 子 Agent 系列文档中详细分析。本文档作为 `docs/builtin-tools` 目录下的索引入口,直接链接到对应文档,避免内容重复。

子 Agent 相关文档分布在 `docs/llm-client` 中的四个文件,覆盖从框架总览到提示词注入的完整链路:

```
docs/llm-client/
├── LV023-Agent提示词.md                         ← 内置 Agent 完整 system prompt
├── LV060-子Agent框架总览.md                     ← 框架架构、类型体系、Fork 机制、runAgent 运行时
├── LV061-自定义Agent的MD文件定义与发现.md         ← MD 文件格式、目录发现、Frontmatter 解析
└── LV062-子Agent提示词注入与LLM选择机制.md         ← Agent 列表注入、LLM 选择、子 Agent 系统提示词构建
```

## 二、 文档索引

### 1. LV060-子Agent框架总览

[`LV060-子Agent框架总览.md`](../llm-client/LV060-子Agent框架总览.md) 是子 Agent 框架的顶层文档,覆盖以下内容:

- 核心架构与源码文件职责表
- Agent 工具定义:工具名称与别名、输入/输出 Schema
- `call()` 方法核心路由:多 Agent 团队生成、Fork 路由、指定类型查找、MCP 检查、系统提示词构建、同步/异步决策
- Agent 定义类型体系:`BaseAgentDefinition` 及 `BuiltIn`/`Custom`/`Plugin` 三种具体类型
- 内置 Agent 列表与 General Purpose / Explore Agent 详解
- Fork 子 Agent:特性门控、`FORK_AGENT` 定义、上下文继承、缓存共享、递归防护、子进程指令
- `runAgent()` 运行时:函数签名、初始化流程、系统提示词构建、查询循环、清理流程
- Agent 定义的完整加载流程

### 2. LV061-自定义Agent的MD文件定义与发现

[`LV061-自定义Agent的MD文件定义与发现.md`](../llm-client/LV061-自定义Agent的MD文件定义与发现.md) 专注自定义 Agent 的定义格式与发现机制:

- MD 文件结构:YAML frontmatter + Markdown 正文
- Frontmatter 字段详解:`name`、`description`、`tools`、`model`、`background`、`memory`、`isolation`、`hooks`、`mcpServers` 等
- 目录发现机制:Policy/User/Project 三类目录扫描
- 项目目录遍历逻辑与 Git Worktree 回退
- Frontmatter 解析流程与错误分类处理
- JSON 格式 Agent 定义与 MD 格式的差异对比
- 自定义 Agent 定义示例:最小化、只读搜索、完整定义、带 MCP 服务器、Agent 嵌套控制
- 插件 Agent 的额外特性

### 3. LV062-子Agent提示词注入与LLM选择机制

[`LV062-子Agent提示词注入与LLM选择机制.md`](../llm-client/LV062-子Agent提示词注入与LLM选择机制.md) 分析 Agent 信息如何注入 LLM 上下文及 LLM 如何选择:

- Agent 列表的两种注入模式:内嵌到工具描述（模式 A）与附件消息注入（模式 B）
- `agent_listing_delta` 附件的增量差异计算与 LLM 文本转换
- Agent 工具描述的完整结构:共享核心、Coordinator 精简、不使用场景、使用说明、示例
- LLM 选择子 Agent 的机制:选择依据、选择流程、默认行为、过滤与权限控制
- `Agent(AgentName)` 语法限制子 Agent 可调用的类型
- MD 文档在主会话中的角色:仅 `name`+`description`+`tools` 进入主会话,正文不进入
- 子 Agent 系统提示词构建:Fork 路径 vs 普通路径
- MD 正文到最终系统提示词的完整转换链
- 子 Agent vs 主会话系统提示词对比
- 同一 MD 文档在主会话与子 Agent 中的双重视角

### 4. LV023-Agent提示词

[`LV023-Agent提示词.md`](../llm-client/LV023-Agent提示词.md) 收录所有内置 Agent 的完整 system prompt 文本:

- Explore Agent:只读代码探索,使用 `haiku`/`inherit` 模型
- Plan Agent:只读架构规划,使用 `inherit` 模型
- Verification Agent:对抗性验证,默认后台运行
- 通用代理 `DEFAULT_AGENT_PROMPT`:未指定 `subagent_type` 时使用
- 各 Agent 的代理配置对比表

## 三、 相关文档

子 Agent 的工具注册与调用机制属于工具系统层面,位于 `docs/builtin-tools` 目录:

- [`LV050-AgentTool-工具总览与注册机制.md`](LV050-AgentTool-工具总览与注册机制.md):`buildTool`/`ToolDef` 工具定义结构、`assembleToolPool` 注册链路、`Task`→`Agent` 重命名的三层向后兼容机制
- [`LV051-AgentTool-调用流程与运行机制.md`](LV051-AgentTool-调用流程与运行机制.md):`call()` 方法完整路由、同步/异步执行决策树、`runAsyncAgentLifecycle()` 异步生命周期、Worktree 清理逻辑

---

*本文档由 markdowncli 技能辅助生成*

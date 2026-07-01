<!-- more -->

## 一、 概述

Claude Code 的终端用户界面（TUI）基于 React + Ink 构建，将 React 的声明式组件模型引入终端渲染环境。整个界面围绕一个主交互屏幕（REPL）组织，采用"可滚动消息流 + 固定底部输入区"的经典布局，并通过主题系统、动画系统、消息分发系统等子模块协同呈现丰富的交互体验。

本文是 `docs/tui` 目录的导读概览，先介绍 TUI 的整体架构与界面布局，再逐一点明各组成部分及其对应的详细分析文档，帮助读者建立全局视图后再深入各专题。

TUI 的核心源码位于 [`claude-code-source/src/`](../../claude-code-source/src/) 目录，主屏幕组件位于 [`claude-code-source/src/screens/REPL.tsx`](../../claude-code-source/src/screens/REPL.tsx)。

## 二、 技术栈与渲染基础

### 1. React + Ink 架构

Claude Code TUI 使用 [Ink](https://github.com/vadimdemedes/ink) 库在终端中渲染 React 组件。Ink 提供了与 Web React 一致的开发体验，但将 `<div>`/`<span>` 替换为 Ink 的 `<Box>`/`<Text>` 原语：

- `<Box>`：布局容器，支持 `flexDirection`、`flexGrow`、`paddingX` 等 Flexbox 属性
- `<Text>`：文本节点，支持 `color`、`backgroundColor`、`dimColor`、`italic` 等样式属性

这使得 Claude Code 能够用组件化的方式管理复杂的终端界面状态。

### 2. React Compiler 优化

源码中大量出现 `$[n]` 缓存槽和 `_c(n)` 调用，这是 React Compiler 的 memoization 机制。编译器自动为组件内的子节点和计算结果生成缓存，避免不必要的重渲染。在长会话（数千条消息）场景下，这种优化对性能至关重要——例如欢迎页的静态内容在首次渲染后被缓存，后续直接复用。

### 3. 终端能力适配

TUI 通过 `env.terminal`、`process.platform`、`TERM` 等环境变量适配不同终端的能力差异：

- Apple Terminal：不支持部分 Unicode 字符，使用简化图形变体
- 16 色终端：使用 ANSI 主题替代真彩色 RGB
- Ghostty 终端：使用 `*` 替代部分星形字符
- 减弱动画（`prefersReducedMotion`）：所有动画降级为静态或缓变

## 三、 启动流程

从命令行启动到呈现主交互界面，TUI 经历以下渲染管线：

```
main.tsx (CLI 入口、参数解析、认证)
  → replLauncher.tsx (launchRepl 异步加载)
    → App.tsx (顶层 Provider 包装)
      → REPL.tsx (主屏幕组件)
        → FullscreenLayout.tsx (布局容器)
```

### 1. 入口与启动器

程序入口 [`claude-code-source/src/main.tsx`](../../claude-code-source/src/main.tsx) 负责 CLI 参数解析、配置加载、OAuth 认证和 GrowthBook 初始化，最终调用 `launchRepl()`。启动器 [`claude-code-source/src/replLauncher.tsx`](../../claude-code-source/src/replLauncher.tsx) 异步加载并渲染 `<App><REPL /></App>`。

### 2. 顶层 Provider

[`claude-code-source/src/components/App.tsx`](../../claude-code-source/src/components/App.tsx) 是顶层上下文 Provider，嵌套 `FpsMetricsProvider`、`StatsProvider`、`AppStateProvider`，为整个应用提供性能指标、统计信息和全局状态。

### 3. 主屏幕 REPL

[`claude-code-source/src/screens/REPL.tsx`](../../claude-code-source/src/screens/REPL.tsx) 是 TUI 的核心，是一个接收大量 props（commands、tools、messages、MCP clients 等）的巨型组件。它维护两种屏幕模式：

- `'prompt'`：主交互模式，即默认的对话界面
- `'transcript'`：转录模式，用于查看历史会话

## 四、 界面布局

主界面由 [`claude-code-source/src/components/FullscreenLayout.tsx`](../../claude-code-source/src/components/FullscreenLayout.tsx) 组织，采用全屏 AlternateScreen 模式，整体为纵向 Flexbox 列布局。

### 1. 整体结构

```typescript
// claude-code-source/src/components/FullscreenLayout.tsx#L338-L445
<Box flexDirection="column" height={terminalRows}>
  <PromptOverlayProvider>
    {/* 可滚动区域 */}
    <Box flexGrow={1} flexDirection="column" overflow="hidden">
      <StickyPromptHeader />          {/* 粘性提示头 */}
      <ScrollBox stickyScroll={true}> {/* 滚动容器 */}
        {scrollable}                  {/* 消息列表 + Spinner */}
        {overlay}                     {/* 权限请求覆盖层 */}
      </ScrollBox>
      <NewMessagesPill />             {/* "N new" 提示 */}
      {bottomFloat}                   {/* 伙伴精灵浮泡 */}
    </Box>
    {/* 底部固定区域 */}
    <Box flexDirection="column" flexShrink={0}>
      <SuggestionsOverlay />          {/* 建议覆盖层 */}
      <DialogOverlay />               {/* 对话框覆盖层 */}
      <Box overflowY="hidden">{bottom}</Box> {/* PromptInput 等 */}
    </Box>
    {modal}                           {/* 模态窗口（斜杠命令 UI） */}
  </PromptOverlayProvider>
</Box>
```

### 2. 三大区域划分

| 区域 | 位置 | 职责 | 关键内容 |
|---|---|---|---|
| 可滚动区（scrollable） | 上方，`flexGrow={1}` | 消息流展示 | `<Messages>` 消息列表、`<SpinnerWithVerb>` 加载动画、排队命令 |
| 底部固定区（bottom） | 下方，`flexShrink={0}` | 用户输入与交互 | `<PromptInput>` 输入框、权限请求、各类对话框 |
| 模态窗口（modal） | 绝对定位底部覆盖 | 斜杠命令全屏 UI | `/config`、`/model`、`/diff` 等命令界面 |

### 3. 滚动机制

可滚动区域使用 Ink 的 `<ScrollBox>` 组件，支持 `stickyScroll`（粘性滚动，自动跟随新消息）。当用户向上滚动查看历史时，底部出现 `<NewMessagesPill>` 提示新消息数量，点击可跳转回底部。`<StickyPromptHeader>` 在滚动时显示当前提示上下文。

## 五、 视觉对齐与前缀系统

在实际界面中，用户消息、助手消息、工具结果、状态提示、输入框等元素的左侧图标或前缀会保持对齐，形成一条清晰的左侧视觉参考线。例如截图中的 `›`（用户消息）、`●`（助手回复）、`✻`（空闲状态）以及输入框的 `>` 提示符均从同一列开始。这种对齐并非偶然，而是通过统一的前缀宽度与 `NoSelect` 不可选 gutter 机制共同实现的。

### 1. 对齐目标

TUI 需要在有限宽度的终端中清晰地区分：

- 谁发送了这条内容（用户 vs 助手）
- 内容处于什么状态（输入、思考、回复、工具执行、空闲）
- 哪些文本是可复制的，哪些只是装饰性 gutter

因此，所有消息和状态行的前缀图标被约束在一条固定的左侧 gutter 中，正文内容从 gutter 右侧开始，形成统一的阅读起点。

### 2. 用户消息指针：固定 2 列

用户文本消息通过 `HighlightedThinkingText` 渲染，普通模式下使用 `figures.pointer`（`›`）加一个空格作为前缀：

```typescript
// claude-code-source/src/components/messages/HighlightedThinkingText.tsx
<Text color={pointerColor}>{figures.pointer} </Text>
```

`figures.pointer` 在 Unicode 环境下为单宽字符 `›`，后接一个空格，共同占用 2 列。这样无论内容多长，正文始终从第 2 列开始。

详细的指针颜色与 Brief 布局变体见 [LV003-用户消息组件](LV003-用户消息组件.md)。

### 3. 助手消息圆点：NoSelect + minWidth={2}

助手文本回复的圆点前缀通过 `<NoSelect>` 包裹，并强制最小宽度为 2 列：

```typescript
// claude-code-source/src/components/messages/AssistantTextMessage.tsx
<NoSelect fromLeftEdge={true} minWidth={2}>
  <Text color={isSelected ? "suggestion" : "text"}>{BLACK_CIRCLE}</Text>
</NoSelect>
```

其中 `BLACK_CIRCLE` 在 macOS 平台为 `⏺`（双宽字符），在其他平台为 `●`（单宽字符）。`minWidth={2}` 确保无论平台差异如何，圆点前缀都占据 2 列宽度，从而与用户消息的 `› ` 对齐。`fromLeftEdge={true}` 表示该 gutter 从屏幕最左列开始，且 drag 选择时从列 0 到该 box 右边缘都会被排除在选择之外。

### 4. 助手回复缩进：MessageResponse 的 ⎿ 前缀

更复杂的助手内容（工具结果、错误消息等）会被 `<MessageResponse>` 包裹，渲染一个固定宽度的 `⎿`（左下角括号）前缀：

```typescript
// claude-code-source/src/components/MessageResponse.tsx
<NoSelect fromLeftEdge={true} flexShrink={0}>
  <Text dimColor={true}>"  "}⎿  </Text>
</NoSelect>
<Box flexShrink={1} flexGrow={1}>{children}</Box>
```

`flexShrink={0}` 保证前缀在终端宽度不足时不会被压缩；`flexGrow={1}` 让内容区填充剩余空间。`MessageResponseContext` 还会避免嵌套回复时重复渲染 `⎿`，防止多层括号堆叠。详细的缩进与嵌套去重机制见 [LV004-思考内容与LLM回复组件](LV004-思考内容与LLM回复组件.md)。

### 5. Markdown 列表与正文的对齐

助手回复中的 Markdown 列表（如 `- 写代码 / 改代码`）并非独立对齐到列 0，而是与助手正文内容共享同一起始列。原因在于：

- 助手消息圆点占据列 0~1
- Markdown 正文从列 2 开始渲染
- Markdown 列表的 `-` 标记由 `<Markdown>` 组件渲染在正文列（列 2）
- 因此列表项与后续段落自然对齐，而圆点/指针等消息级前缀则位于列 0 的 gutter 中

这形成了两层视觉层次：消息级前缀（`›`、`●`）在 gutter 列，内容级标记（`-`、缩进）在内容列。

### 6. 状态与输入提示的对齐

| 元素 | 前缀 | 实现位置 | 宽度/对齐方式 |
|---|---|---|---|
| 用户消息 | `› ` | `HighlightedThinkingText.tsx` | 固定 2 列 |
| 助手文本回复 | `●` / `⏺` | `AssistantTextMessage.tsx` | `NoSelect minWidth={2}` |
| 助手/工具缩进 | `  ⎿  ` | `MessageResponse.tsx` | `NoSelect flexShrink={0}` |
| Markdown 列表项 | `-` | `<Markdown>` | 与正文同列起始于内容列 |
| 思考内容 | `∴ Thinking` | `AssistantThinkingMessage.tsx` | 无独立固定宽度，但折叠/展开态缩进一致 |
| Spinner 空闲 | `✻` | `Spinner.tsx` | 直接置于行首 |
| 输入框提示符 | `>` | `PromptInput` 输入组件 | 直接置于行首 |

Spinner 与输入框的状态字符虽然不一定使用 `minWidth` 约束，但它们本身均为单宽字符，且被渲染在行的最左端，因此视觉上与用户消息和助手消息的图标列保持一致。

### 7. NoSelect 机制与可复制性

`NoSelect` 组件是 gutter 对齐的关键基础设施，定义在 [`claude-code-source/src/ink/components/NoSelect.tsx`](../../claude-code-source/src/ink/components/NoSelect.tsx)。它的核心作用是在全屏选择模式下将 gutter 标记为不可选：

- 用户 drag 选择时，前缀/图标不会被高亮，也不会被复制
- `fromLeftEdge={true}` 将不可选区域从列 0 延伸到该 box 的右边缘，确保多行拖动时下方行不会误选容器缩进
- 这样复制出的文本只包含正文，不含 `›`、`●`、`⎿`、`-` 等装饰符号

`NoSelect` 本质上是对 Ink `<Box>` 的包装，通过 `noSelect` 属性与 `fromLeftEdge` 标记实现上述行为。

### 8. 设计要点总结

Claude Code TUI 的图标对齐依赖三条规则：

1. **固定宽度**：用户消息和助手消息都使用 2 列宽度的前缀 gutter，消除平台字符宽度差异
2. **不可选 gutter**：通过 `NoSelect` 隔离装饰符号与可复制正文，提升多行选择体验
3. **抗压缩**：对关键前缀使用 `flexShrink={0}`，防止终端宽度不足时破坏对齐

这套前缀系统与主题颜色、消息分发系统共同构成了 TUI 清晰可读的对话层次。

## 六、 核心组件体系

`src/components/` 目录下组织了 TUI 的全部组件，按功能划分为多个子目录：

### 1. 组件目录概览

| 子目录 | 文件数 | 职责 |
|---|---|---|
| `messages/` | 41 | 各类消息的渲染组件，每种消息类型有专门组件 |
| `PromptInput/` | 21 | 用户输入框及配套组件（页脚、建议、帮助菜单等） |
| `permissions/` | 51 | 权限请求 UI，每种工具的权限确认对话框 |
| `Spinner/` | 12 | 加载动画组件（帧动画、微光、停滞检测） |
| `LogoV2/` | 15 | Logo 与欢迎页（动画 Logo、Feed 列、提示） |
| `design-system/` | 16 | 设计系统基础组件（Dialog、Divider、Tabs 等） |
| `CustomSelect/` | 10 | 自定义选择器（单选/多选） |
| `mcp/` | 13 | MCP（Model Context Protocol）相关 UI |
| `agents/` | 27 | 子 Agent 与团队协作 UI |
| `tasks/` | 12 | 任务列表 V2 组件 |

### 2. 消息分发系统

消息渲染采用分层分发架构。入口组件 [`claude-code-source/src/components/Message.tsx`](../../claude-code-source/src/components/Message.tsx) 根据消息类型分派：

- `case "attachment"` → `<AttachmentMessage>`（附件消息）
- `case "assistant"` → `<AssistantMessageBlock>`（助手消息块）
- `case "user"` → `<UserMessage>`（用户消息，进一步分发）
- `case "system"` → 系统消息、压缩边界等

用户文本消息再由 `UserTextMessage` 路由器根据内容中的特殊标签（如 `<bash-stdout>`、`<command-message>`）分派到十余个专门的子组件，详见 [LV003-用户消息组件](LV003-用户消息组件.md)。

### 3. 输入系统

用户输入框 [`claude-code-source/src/components/PromptInput/PromptInput.tsx`](../../claude-code-source/src/components/PromptInput/PromptInput.tsx) 是底部固定区的核心，负责：

- 文本输入与光标管理
- 输入模式切换（普通、Vim 等）
- 斜杠命令补全与建议
- 历史搜索（`HistorySearchInput`）
- 页脚状态展示（`PromptInputFooter`：模型、模式、上下文等）
- 帮助菜单（`PromptInputHelpMenu`：快捷键列表）

### 4. Markdown 渲染

助手回复通过 [`claude-code-source/src/components/Markdown.tsx`](../../claude-code-source/src/components/Markdown.tsx) 中的 `<Markdown>` / `<StreamingMarkdown>` 组件渲染，支持完整 Markdown 语法，包括代码块（带语法高亮）、表格、引用块、列表等。流式输出时使用 `StreamingMarkdown` 增量渲染。

### 5. Diff 展示

文件编辑与代码差异通过 [`claude-code-source/src/components/StructuredDiff.tsx`](../../claude-code-source/src/components/StructuredDiff.tsx) 和 [`claude-code-source/src/components/StructuredDiffList.tsx`](../../claude-code-source/src/components/StructuredDiffList.tsx) 渲染，支持行级与单词级差异高亮，使用主题中的 `diffAdded`/`diffRemoved` 等颜色槽位。

## 七、 主题系统

主题系统是 TUI 视觉一致性的基石。所有颜色定义集中在 [`claude-code-source/src/utils/theme.ts`](../../claude-code-source/src/utils/theme.ts)，通过 `Theme` 接口约束约 75 个颜色槽位，为 6 套内置主题分别提供具体取值。

### 1. 内置主题

| 主题名 | 说明 |
|---|---|
| `dark` | 深色主题（默认），使用显式 RGB 值 |
| `light` | 浅色主题 |
| `dark-daltonized` | 深色色盲友好主题 |
| `light-daltonized` | 浅色色盲友好主题 |
| `dark-ansi` | 深色 16 色 ANSI 主题 |
| `light-ansi` | 浅色 16 色 ANSI 主题 |

此外 `'auto'` 选项会根据系统深/浅色模式自动解析。

### 2. 颜色槽位分类

主题的颜色槽位按功能分为：品牌与核心色、状态与模式色、文本色、语义色、Diff 差异色、子 Agent 颜色（8 种）、TUI V2 界面色、彩虹色（ultrathink 高亮）等。多数颜色成对出现基础色与 `Shimmer`（微光）浅色变体，用于动画效果。

详细的类型定义、各主题取值与设计要点，参见 [LV001-主题配色系统与颜色定义](LV001-主题配色系统与颜色定义.md)。

## 八、 欢迎页

启动时首先呈现的是欢迎页，由 ASCII 艺术组成的 Claude 吉祥物（clawd）图形、版本号文字和装饰性星空元素构成。欢迎页根据终端类型和主题深浅呈现不同变体：

- Apple Terminal 分支：使用四分之一方块字符替代 `█`
- 浅色主题分支：减少星空密度，视觉更清爽
- 深色主题分支（默认）：完整的星空与光晕效果

欢迎页被包裹在固定宽度 58 字符的 `Box` 中，确保图形不变形。详细的 ASCII 艺术构成与各变体差异，参见 [LV002-欢迎页结构与ASCII艺术](LV002-欢迎页结构与ASCII艺术.md)。

## 九、 用户消息组件

用户消息组件负责渲染用户输入的文本及其衍生内容。采用分层架构：从 `Message` 分发器到 `UserTextMessage` 路由器，再到具体的消息渲染器。

### 1. 主要用户消息类型

| 消息类型 | 组件 | 说明 |
|---|---|---|
| 用户提示 | `<UserPromptMessage>` | 用户实际输入的文本 |
| Bash 输出 | `<UserBashOutputMessage>` | Bash 命令的标准输出/错误 |
| Bash 输入 | `<UserBashInputMessage>` | Bash 命令输入记录 |
| 命令消息 | `<UserCommandMessage>` | 斜杠命令执行结果 |
| 记忆输入 | `<UserMemoryInputMessage>` | 记忆相关输入 |
| 队友消息 | `<UserTeammateMessage>` | 团队协作中的队友消息 |
| 附件消息 | `<AttachmentMessage>` | 文件、图片等附件 |

### 2. Brief 布局模式

Claude Code 提供一种紧凑的聊天式布局（Brief 模式），采用标签式结构（"You" 标签 + 正文）而非默认的指针式（`›` 前缀 + 灰底背景）。Brief 模式受多个条件门控，包括编译时标志、功能开关和运行时状态。

详细的渲染管线、文本截断策略与 Brief 布局逻辑，参见 [LV003-用户消息组件](LV003-用户消息组件.md)。

## 十、 思考内容与 LLM 回复

助手侧的消息呈现遵循统一的缩进与前缀体系，通过三套符号建立视觉层次：

| 内容类型 | 前缀符号 | 颜色特征 |
|---|---|---|
| 思考内容（折叠） | `∴ Thinking` | `dimColor` + 斜体 |
| 思考内容（展开） | `∴ Thinking…` + 缩进正文 | `dimColor` + 斜体 |
| 文本回复 | `⏺`/`●` 圆点 | `text`（选中 `suggestion`） |
| 工具调用 | 无独立前缀 | 各工具自定义 |
| 错误消息 | 无圆点 | `error` 红色 |

### 1. MessageResponse 缩进容器

助手回复通过 [`claude-code-source/src/components/MessageResponse.tsx`](../../claude-code-source/src/components/MessageResponse.tsx) 中的 `<MessageResponse>` 组件包裹，渲染 `⎿`（左下角括号）前缀并处理嵌套去重，使回复内容相对用户输入缩进，形成清晰的对话层级。

### 2. 思考内容折叠

LLM 的思考（thinking）内容默认以折叠态展示，仅显示 `∴ Thinking` 标签和展开提示，用户按 Ctrl+O 可展开查看完整内容。转录模式下可隐藏历史思考块以节省空间。

详细的组件结构、错误消息处理与视觉层次体系，参见 [LV004-思考内容与LLM回复组件](LV004-思考内容与LLM回复组件.md)。

## 十一、 动态图标与状态展示

Spinner 加载动画是 TUI 中最复杂的视觉系统，通过多层动画反馈 LLM 的工作状态。

### 1. Spinner 状态机

Spinner 通过 `SpinnerMode` 标识当前工作状态，不同模式显示不同方向图标：

| 模式 | 含义 | 方向图标 |
|---|---|---|
| `requesting` | 正在请求 API | `↑` 上箭头 |
| `thinking` | 模型思考中 | `↓` 下箭头 |
| `responding` | 流式响应中 | `↓` 下箭头 |
| `tool-use` | 工具调用中 | `↓` 下箭头 |

### 2. 多层动画效果

Spinner 集成了多层动画反馈：

- 字符帧动画：6 个基础帧正序拼接倒序形成 12 帧呼吸式循环，120ms 切换
- 微光（Glimmer）扫过：浅色高光从一端扫向另一端，`requesting` 模式左→右，其他模式右→左
- 停滞渐变红色：超过 3 秒无新 token 时，字符颜色向红色渐变
- 工具调用闪烁：`tool-use` 模式下以正弦波频率闪烁

### 3. 语义化图标常量

[`claude-code-source/src/constants/figures.ts`](../../claude-code-source/src/constants/figures.ts) 定义了全部语义化图标常量，涵盖消息标记、努力等级、方向箭头、媒体控制、审查标记、排版元素等。

详细的帧动画机制、停滞检测算法与全部图标常量，参见 [LV005-动态图标与状态展示逻辑](LV005-动态图标与状态展示逻辑.md)。

## 十二、 权限与特殊状态

### 1. 权限请求系统

当 LLM 调用需要确认的工具时，TUI 在底部固定区弹出权限请求对话框。权限 UI 位于 [`claude-code-source/src/components/permissions/`](../../claude-code-source/src/components/permissions/) 目录，包含 51 个文件，为每种工具提供专门的确认界面。权限请求通过 `focusedInputDialog` 状态管理焦点，支持允许、拒绝、永久允许等操作。

### 2. 特殊对话框

底部固定区还承载多种特殊状态对话框：

- 沙箱权限请求（`SandboxPermissionRequest`）
- MCP Elicitation 对话框（`ElicitationDialog`）
- 费用阈值确认（`CostThresholdDialog`）
- 空闲返回确认（`IdleReturnDialog`）
- IDE 连接相关（`IdeOnboardingDialog`、`IdeAutoConnectDialog`）
- 超级计划（`UltraplanChoiceDialog`、`UltraplanLaunchDialog`）

### 3. 模态窗口

斜杠命令（如 `/config`、`/model`、`/diff`、`/theme`）的全屏 UI 通过模态窗口呈现，覆盖在主界面上方，底部留出少量行数预览下方对话。模态窗口由 `ModalContext` 提供尺寸约束。

## 十三、 文档导航

`docs/tui` 目录下的文档按编号组织，建议按以下顺序阅读：

| 文档 | 主题 | 核心内容 |
|---|---|---|
| [LV000-TUI概述](LV000-TUI概述.md)（本文） | 整体概览 | 架构、布局、组件体系、视觉对齐导览 |
| [LV001-主题配色系统与颜色定义](LV001-主题配色系统与颜色定义.md) | 主题系统 | `Theme` 接口、6 套主题取值、颜色工具函数 |
| [LV002-欢迎页结构与ASCII艺术](LV002-欢迎页结构与ASCII艺术.md) | 欢迎页 | 吉祥物 ASCII 艺术、星空装饰、主题变体 |
| [LV003-用户消息组件](LV003-用户消息组件.md) | 用户消息 | 消息分发、`UserPromptMessage`、Brief 布局 |
| [LV004-思考内容与LLM回复组件](LV004-思考内容与LLM回复组件.md) | 助手回复 | 思考折叠、文本回复、`MessageResponse` 缩进 |
| [LV005-动态图标与状态展示逻辑](LV005-动态图标与状态展示逻辑.md) | Spinner 与图标 | 帧动画、状态机、停滞检测、图标常量 |

后续文档将持续补充输入框组件、权限系统、Markdown 渲染、Diff 展示、Agent 协作 UI 等专题。

---
*本文档由 markdowncli 技能辅助生成*

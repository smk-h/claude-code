<!-- more -->

## 一、 概述

欢迎页是 Claude Code 启动时展示的首屏画面，由 ASCII 艺术组成的 Claude 吉祥物（clawd）图形、版本号文字以及装饰性星空元素构成。该页面根据终端类型和主题深浅呈现不同变体，通过精确的字符定位和颜色搭配营造出富有质感的启动体验。本文深入分析欢迎页的组件结构、ASCII 艺术构成及各主题变体的差异。

欢迎页的核心源码位于 [`claude-code-source/src/components/LogoV2/WelcomeV2.tsx`](../../claude-code-source/src/components/LogoV2/WelcomeV2.tsx)。

## 二、 组件整体结构

### 1. WelcomeV2 主组件

`WelcomeV2` 是欢迎页的入口组件，根据终端环境和主题选择不同的渲染分支。该组件在 [`claude-code-source/src/components/LogoV2/WelcomeV2.tsx`](../../claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L5-L19) 中定义：

```typescript
// claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L5-L19
const WELCOME_V2_WIDTH = 58;
export function WelcomeV2() {
  const $ = _c(35);
  const [theme] = useTheme();
  if (env.terminal === "Apple_Terminal") {
    // Apple Terminal 不支持部分字符，使用简化变体
    return <AppleTerminalWelcomeV2 theme={theme} welcomeMessage="Welcome to Claude Code" />;
  }
  if (["light", "light-daltonized", "light-ansi"].includes(theme)) {
    // 浅色主题分支
  }
  // 深色主题分支（默认）
}
```

### 2. 三条渲染分支

组件根据环境分为三个渲染分支：

- **Apple Terminal 分支**：当终端为 Apple Terminal 时，使用 `AppleTerminalWelcomeV2` 组件，因 Apple Terminal 对部分 Unicode 字符渲染异常而采用简化图形
- **浅色主题分支**：当主题为 `light`、`light-daltonized`、`light-ansi` 时使用浅色版本
- **深色主题分支**：其余主题使用深色版本（默认）

### 3. React Compiler 优化

代码中大量使用 `$[n]` 缓存槽（React Compiler 的 memoization 机制）。由于欢迎页内容在主题确定后完全静态，所有 `<Text>` 节点在首次渲染后被缓存到 `Symbol.for("react.memo_cache_sentinel")` 槽位，后续渲染直接复用，避免重复创建 React 元素。

## 三、 文字标题部分

### 1. 标题与版本号

欢迎页首行展示标题和版本号，在 [`claude-code-source/src/components/LogoV2/WelcomeV2.tsx`](../../claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L116-L117) 中定义：

```typescript
// claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L116-L117
t0 = <Text><Text color="claude">{"Welcome to Claude Code"} </Text><Text dimColor={true}>v{MACRO.VERSION} </Text></Text>;
```

- `"Welcome to Claude Code"` 使用 `claude` 颜色（品牌橙 `rgb(215,119,87)`）
- 版本号 `v{VERSION}` 使用 `dimColor`（暗淡色），与标题形成主次对比

### 2. 装饰性分隔线

标题下方紧跟一条由 `…`（省略号 `\u2026`）字符组成的分隔线，在 [`claude-code-source/src/components/LogoV2/WelcomeV2.tsx`](../../claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L117) 中定义：

```typescript
// claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L117
t1 = <Text>{"…………………………………………………………………"}</Text>;
```

该分隔线的粗细与颜色规格：

- **粗细**：1 行高 × 58 字符宽（与 `WELCOME_V2_WIDTH` 一致），由 58 个 `…` 字符连续排列构成，无额外 `padding` 或 `margin`
- **颜色**：未设置 `color` 属性，使用默认文本色 `text`（深色主题 `rgb(255,255,255)` 白色，浅色主题 `rgb(0,0,0)` 黑色），与标题的品牌橙 `claude`（`rgb(215,119,87)`）形成亮度对比

欢迎页不使用 Ink `<Box>` 的 `borderStyle` 属性绘制边框，所有视觉分隔均由字符本身充当，这样可以在单 `<Text>` 中统一渲染，避免多 `<Box>` 布局开销。

## 四、 吉祥物 ASCII 艺术

### 1. 吉祥物主体

欢迎页中央是 Claude 吉祥物（clawd）的 ASCII 艺术，使用 `clawd_body`（`rgb(215,119,87)` 品牌橙）和 `clawd_background`（`rgb(0,0,0)` 黑色）两种颜色绘制。深色主题中的核心部分在 [`claude-code-source/src/components/LogoV2/WelcomeV2.tsx`](../../claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L164-L185) 中定义：

```typescript
// claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L164-L185
// 吉祥物头部（实心方块）
t12 = <Text color="clawd_body"> █████████ </Text>;
// 吉祥物眼睛行（带背景色描边）
t14 = <Text>{"      "}<Text color="clawd_body">██▄█████▄██</Text>...</Text>;
// 吉祥物下颌
t15 = <Text>{"      "}<Text color="clawd_body"> █████████ </Text>...</Text>;
```

吉祥物由三层 `█`（全角方块）字符构成：

- 第一层 `█████████`：9 个方块组成的头部上沿，`color="clawd_body"`（`rgb(215,119,87)`）
- 第二层 `██▄█████▄██`：带 `▄`（下半块）的眼睛行，中间 5 个方块为眼睛区域，`color="clawd_body"`（`rgb(215,119,87)`）
- 第三层 `█████████`：头部下沿，`color="clawd_body"`（`rgb(215,119,87)`）

### 2. 深色与浅色主题的眼睛行差异

吉祥物眼睛行在深色和浅色主题下的颜色处理存在关键差异：

- **深色主题**（[`L178`](../../claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L178)）：仅设置 `color="clawd_body"`（`rgb(215,119,87)`），不设 `backgroundColor`。因为深色主题的终端背景本身接近黑色，与 `clawd_background`（`rgb(0,0,0)`）一致，无需额外填充背景色
- **浅色主题**（[`L87`](../../claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L87)）：同时设置 `color="clawd_body"`（`rgb(215,119,87)`）和 `backgroundColor="clawd_background"`（`rgb(0,0,0)`）。因为浅色主题的终端背景为白色，需要用黑色背景衬托吉祥物的品牌橙主体，否则橙色方块在白色背景上缺乏层次

```typescript
// 浅色主题眼睛行（L87）：额外填充黑色背景
t13 = <Text>{"      "}<Text color="clawd_body" backgroundColor="clawd_background">██▄█████▄██</Text>...</Text>;
```

### 2. Apple Terminal 变体

Apple Terminal 不支持 `█` 字符的正确渲染，因此使用 `▗`、`▖` 等四分之一方块字符替代。在 [`claude-code-source/src/components/LogoV2/WelcomeV2.tsx`](../../claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L293-L300) 中定义：

```typescript
// claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L293-L300
t16 = <Text>{"      "}<Text color="clawd_body">▗</Text>
  <Text color="clawd_background" backgroundColor="clawd_body">{" "}▗{"     "}▖{" "}</Text>
  <Text color="clawd_body">▖</Text>...</Text>;
t17 = <Text>{"       "}<Text backgroundColor="clawd_body">{" ".repeat(9)}</Text>...</Text>;
```

该变体使用 `backgroundColor="clawd_body"`（`rgb(215,119,87)`）为空白区域填充品牌橙背景，用 `color="clawd_body"`（`rgb(215,119,87)`）的 `▗`、`▖` 字符绘制边缘，用 `color="clawd_background"`（`rgb(0,0,0)`）绘制内部空白区域的字符，模拟出与标准版近似的视觉效果。

### 3. 底部脚部

吉祥物下方是脚部图形，在 [`claude-code-source/src/components/LogoV2/WelcomeV2.tsx`](../../claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L192) 中定义：

```typescript
// claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L192
t16 = <Box width={WELCOME_V2_WIDTH}><Text>
  ...
  <Text color="clawd_body">{"█ █   █ █"}</Text>
  ...
</Text></Box>;
```

`█ █   █ █` 表示两只脚（每只脚由两个方块加空格组成），使用 `color="clawd_body"`（`rgb(215,119,87)` 品牌橙）。

脚部行同时也是一条分隔线，其粗细与颜色规格：

- **粗细**：1 行高 × 58 字符宽，结构与标题分隔线不同——由 `…`（`\u2026`）+ 脚部图形 + `…`/`░`/`▒` 混合组成，而非纯 `…` 字符
- **左侧 `…`**：7 个字符，未设置 `color`，使用默认 `text` 色（深色主题 `rgb(255,255,255)`，浅色主题 `rgb(0,0,0)`）
- **脚部 `█ █   █ █`**：10 个字符，`color="clawd_body"`（`rgb(215,119,87)`）
- **右侧填充**：深色主题为纯 `…` 字符（`text` 色）；浅色主题在 `…` 中穿插 `░`（`\u2591`）和 `▒`（`\u2592`）光晕字符作为装饰，同样使用默认 `text` 色

```typescript
// 深色主题脚部行（L192）：左侧 … + 脚部 + 右侧 …
t16 = <Box width={WELCOME_V2_WIDTH}><Text>
  ……………<Text color="clawd_body">█ █   █ █</Text>………………………………………………………………………
</Text></Box>;
```

## 五、 星空装饰元素

### 1. 深色主题星空

深色主题的欢迎页在吉祥物周围分布星点和光晕元素，使用多种 Unicode 方块字符营造层次感：

- `░`（浅色阴影方块 `\u2591`）：最浅层光晕
- `▒`（中等阴影方块 `\u2592`）：中层光晕
- `▓`（深色阴影方块 `\u2593`）：较深光晕
- `█`（全角方块 `\u2588`）：实心星点
- `▌`（左半方块 `\u258c`）：侧面光晕

星空元素的分布示例（深色主题）在 [`claude-code-source/src/components/LogoV2/WelcomeV2.tsx`](../../claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L119-L122) 中定义：

```typescript
// claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L119-L122
t3 = <Text>{"     *                                       ████▓▓░     "}</Text>;
t4 = <Text>{"                                 *         ███▓░     ░░   "}</Text>;
t5 = <Text>{"            ░░░░░░                        ███▓░           "}</Text>;
t6 = <Text>{"    ░░░   ░░░░░░░░░░                      ███▓░           "}</Text>;
```

这些星空行均未设置 `color` 属性，使用默认 `text` 色（深色主题为白色 `rgb(255,255,255)`）。通过不同密度的方块字符（`░` < `▒` < `▓` < `█`）在相同白色下呈现由浅到深的视觉层次，而非依赖不同颜色。

其中 `*` 字符表示远处的星星，部分使用 `dimColor` 渲染以制造远近层次，部分使用 `bold` 加粗以表示近处明亮的星。深色主题中星星有三种渲染方式（[`L145-L149`](../../claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L145-L149)）：

- 默认 `text` 色（深色主题 `rgb(255,255,255)`）：普通可见星
- `<Text bold={true}>*</Text>`：加粗近处明亮星，仍使用默认 `text` 色（`rgb(255,255,255)`）
- `<Text dimColor={true}>*</Text>`：暗淡远处星，使用终端 dim 属性降低亮度

### 2. 浅色主题差异

浅色主题的欢迎页减少了星空元素的密度，因为浅色背景下密集的方块字符会显得过重。浅色版本更多依赖空白和稀疏的 `░` 光晕，整体视觉更清爽。

颜色方面的差异：

- 光晕字符（`░`、`▒`）使用默认 `text` 色（浅色主题 `rgb(0,0,0)` 黑色），部分光晕用 `dimColor={true}` 暗淡处理（[`L62-L70`](../../claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L62-L70)）
- 实心星点 `██` 未设置 `color`，使用默认 `text` 色（`rgb(0,0,0)`）
- 浅色主题不使用 `bold` 加粗星星，星空层次仅靠 `dimColor` 与默认色的对比
- 吉祥物眼睛行额外设置 `backgroundColor="clawd_background"`（`rgb(0,0,0)` 黑色），在白色终端背景上为吉祥物提供黑色衬底（详见四、2 节）

### 3. 星星的 dimColor 与 bold 处理

星星元素根据视觉远近采用三种渲染方式：

```typescript
// claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L145-L149
// 近处明亮星：加粗默认色
t7 = <Text>...<Text bold={true}>*</Text>...</Text>;
// 远处暗淡星：dimColor 暗淡处理
t9 = <Text dimColor={true}>{" *                                 ░░░░                   "}</Text>;
t10 = <Text dimColor={true}>{"                                 ░░░░░░░░                 "}</Text>;
t11 = <Text dimColor={true}>{"                               ░░░░░░░░░░░░░░░░           "}</Text>;
```

- `dimColor={true}`：使星星和光晕呈现暗淡效果（终端 dim 属性，通常降低亮度），模拟远处星光。`t9`/`t10`/`t11` 整行均为 `dimColor`，包含星星 `*` 和光晕 `░`
- `bold={true}`：使星星加粗显示，模拟近处明亮恒星，仅用于深色主题中的部分 `*` 字符
- 无特殊样式：普通可见星，使用默认 `text` 色

浅色主题不使用 `bold` 星星，且 `dimColor` 行中不含星星 `*`，仅暗淡处理光晕 `░`。

## 六、 布局与宽度控制

### 1. 固定宽度布局

整个欢迎页被包裹在一个固定宽度为 58 字符的 `Box` 中，确保在不同终端宽度下图形不变形：

```typescript
// claude-code-source/src/components/LogoV2/WelcomeV2.tsx#L101
t15 = <Box width={WELCOME_V2_WIDTH}><Text>{...}</Text></Box>;
```

### 2. 行拼接策略

欢迎页的所有行被拼接进一个 `<Text>` 中（而非多行 `<Box>`），这是因为 Ink 对单 `<Text>` 的渲染效率高于多个独立 `<Box>`。行与行之间通过换行符 `\n` 隐式分隔（每行 `<Text>` 内容末尾隐含换行）。

## 七、 分隔线与边框规格

欢迎页不使用 Ink `<Box>` 的 `borderStyle` 属性绘制边框，所有视觉分隔均由字符本身充当。页面中有两条分隔线：

| 分隔线 | 位置 | 粗细 | 字符 | 颜色 |
|---|---|---|---|---|
| 标题分隔线 | 标题与星空之间 | 1 行 × 58 字符 | `…`（`\u2026`）× 58 | 默认 `text`（深色 `rgb(255,255,255)` / 浅色 `rgb(0,0,0)`） |
| 脚部分隔线 | 吉祥物脚部所在行 | 1 行 × 58 字符 | `…`×7 + `█ █   █ █` + `…`/`░`/`▒` 混合 | 脚部 `clawd_body`（`rgb(215,119,87)`），其余默认 `text` |

两条分隔线均为 1 行高、58 字符宽（与 `WELCOME_V2_WIDTH` 一致），无额外 `padding` 或 `margin`。

## 八、 颜色使用总结

欢迎页涉及的颜色槽位及用途如下：

| 颜色槽位 | RGB 值（深色主题） | 用途 |
|---|---|---|
| `claude` | `rgb(215,119,87)` | 标题文字 "Welcome to Claude Code" |
| `clawd_body` | `rgb(215,119,87)` | 吉祥物主体图形（头部、眼睛行、下颌、脚部） |
| `clawd_background` | `rgb(0,0,0)` | 吉祥物背景描边；浅色主题中作眼睛行 `backgroundColor` |
| `text`（默认） | `rgb(255,255,255)` | 分隔线 `…`、星空光晕（`░▒▓█`）、普通星星 `*` |
| `dimColor`（暗淡） | 终端 dim 属性 | 版本号、远处暗淡星星、暗淡光晕 |
| `bold`（加粗） | 终端 bold 属性 | 近处明亮星星（仅深色主题） |

欢迎页不使用 `error`、`success`、`warning` 等语义色，仅通过品牌色（`claude`（`rgb(215,119,87)`）/ `clawd_body`（`rgb(215,119,87)`））、默认文本色（`text`）、暗淡色（`dimColor`）和加粗（`bold`）的对比建立视觉层次，保持启动画面的简洁与品牌一致性。

深色与浅色主题的关键颜色差异：

| 元素 | 深色主题 | 浅色主题 |
|---|---|---|
| 默认文本色 `text` | `rgb(255,255,255)` 白色 | `rgb(0,0,0)` 黑色 |
| 吉祥物眼睛行背景 | 不设 `backgroundColor`（终端背景已为黑色） | `backgroundColor="clawd_background"`（`rgb(0,0,0)` 填充黑色衬底） |
| 加粗星星 `bold` | 有 | 无 |
| 星空密度 | 较密（多层 `░▒▓█` 光晕 + 多颗 `*` 星） | 较稀疏（主要依赖 `░` 光晕） |

---
*本文档由 markdowncli 技能辅助生成*

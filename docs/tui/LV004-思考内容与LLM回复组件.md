<!-- more -->

## 一、 概述

思考内容组件和 LLM 回复组件负责渲染 Claude 的思考过程与最终文本输出。思考内容以暗淡、可折叠的形式呈现，区分实时思考与历史思考；LLM 回复则通过 Markdown 渲染器呈现富文本，并以圆点和缩进前缀建立视觉层次。本文深入分析这两类组件的结构、样式规则与状态切换逻辑。

相关源码位于 [`claude-code-source/src/components/messages/`](../../claude-code-source/src/components/messages/) 目录。

## 二、 思考内容组件

### 1. AssistantThinkingMessage 组件

`AssistantThinkingMessage` 负责渲染 LLM 的思考（thinking）内容块。该组件在 [`claude-code-source/src/components/messages/AssistantThinkingMessage.tsx`](../../claude-code-source/src/components/messages/AssistantThinkingMessage.tsx#L19-L85) 中定义：

```typescript
// claude-code-source/src/components/messages/AssistantThinkingMessage.tsx#L19-L85
export function AssistantThinkingMessage(t0) {
  const { param: t1, addMargin, isTranscriptMode, verbose, hideInTranscript } = t0;
  const { thinking } = t1;
  const addMargin = t2 === undefined ? false : t2;
  const hideInTranscript = t3 === undefined ? false : t3;
  if (!thinking) {
    return null;
  }
  if (hideInTranscript) {
    return null;
  }
  const shouldShowFullThinking = isTranscriptMode || verbose;
  // ... 根据 shouldShowFullThinking 分支渲染 ...
}
```

### 2. 折叠态展示

当 `shouldShowFullThinking` 为 `false`（非转录模式且非 verbose）时，思考内容以折叠态展示，仅显示标签和展开提示，在 [`claude-code-source/src/components/messages/AssistantThinkingMessage.tsx`](../../claude-code-source/src/components/messages/AssistantThinkingMessage.tsx#L41-L57) 中定义：

```typescript
// claude-code-source/src/components/messages/AssistantThinkingMessage.tsx#L41-L57
if (!shouldShowFullThinking) {
  const t4 = addMargin ? 1 : 0;
  t5 = <Text dimColor={true} italic={true}>{"∴ Thinking"} <CtrlOToExpand /></Text>;
  t6 = <Box marginTop={t4}>{t5}</Box>;
  return t6;
}
```

折叠态的视觉特征：

- 标签 `∴ Thinking`（`∴` 为三点因此符号 `\u2234`）
- `dimColor={true}`：暗淡显示，与正文区分
- `italic={true}`：斜体，强化"内部思考"的语义
- `<CtrlOToExpand />`：提示用户按 Ctrl+O 展开查看完整思考

### 3. 展开态展示

当 `shouldShowFullThinking` 为 `true` 时，展示完整思考内容，在 [`claude-code-source/src/components/messages/AssistantThinkingMessage.tsx`](../../claude-code-source/src/components/messages/AssistantThinkingMessage.tsx#L59-L84) 中定义：

```typescript
// claude-code-source/src/components/messages/AssistantThinkingMessage.tsx#L59-L84
const t4 = addMargin ? 1 : 0;
t5 = <Text dimColor={true} italic={true}>{"∴ Thinking"}…</Text>;
t6 = <Box paddingLeft={2}><Markdown dimColor={true}>{thinking}</Markdown></Box>;
t7 = <Box flexDirection="column" gap={1} marginTop={t4} width="100%">{t5}{t6}</Box>;
return t7;
```

展开态的视觉特征：

- 标签变为 `∴ Thinking…`（末尾加省略号表示已展开）
- 思考正文通过 `<Markdown>` 组件渲染，支持 Markdown 语法
- `dimColor={true}`：正文同样暗淡显示
- `paddingLeft={2}`：正文缩进 2 字符，与标签形成层级
- `gap={1}`：标签与正文之间留 1 行间距

### 4. 转录模式隐藏

`hideInTranscript` 属性用于在转录模式下隐藏历史的思考块（仅保留最新一轮的思考），避免历史思考内容占据过多空间。当此属性为 `true` 时直接返回 `null`。

### 5. 已编辑思考（Redacted Thinking）

`AssistantRedactedThinkingMessage` 组件处理被编辑/隐藏的思考内容，定义在 [`claude-code-source/src/components/messages/AssistantRedactedThinkingMessage.tsx`](../../claude-code-source/src/components/messages/AssistantRedactedThinkingMessage.tsx)。当思考内容因安全原因被移除时，显示替代提示而非具体内容。

## 三、 LLM 回复文本组件

### 1. AssistantTextMessage 组件

`AssistantTextMessage` 是渲染 LLM 文本回复的核心组件，处理正常回复、各类错误消息和特殊状态。该组件在 [`claude-code-source/src/components/messages/AssistantTextMessage.tsx`](../../claude-code-source/src/components/messages/AssistantTextMessage.tsx#L47-L269) 中定义。

### 2. 消息类型分派

组件首先对文本内容进行类型判断，分派到不同的渲染分支：

- 空消息（`isEmptyMessageText`）：返回 `null`
- 速率限制错误（`isRateLimitErrorMessage`）：渲染 `<RateLimitMessage>`
- `NO_RESPONSE_REQUESTED`：返回 `null`（无需响应）
- `PROMPT_TOO_LONG_ERROR_MESSAGE`：渲染上下文超限提示
- `CREDIT_BALANCE_TOO_LOW_ERROR_MESSAGE`：渲染余额不足提示
- `INVALID_API_KEY_ERROR_MESSAGE`：渲染 API Key 无效提示
- `ERROR_MESSAGE_USER_ABORT`：渲染用户中断提示
- API 错误前缀匹配：渲染错误消息（红色）
- 默认：渲染正常 Markdown 回复

### 3. 正常回复渲染

正常回复的渲染逻辑在 [`claude-code-source/src/components/messages/AssistantTextMessage.tsx`](../../claude-code-source/src/components/messages/AssistantTextMessage.tsx#L228-L266) 中定义：

```typescript
// claude-code-source/src/components/messages/AssistantTextMessage.tsx#L228-L266
const t2 = addMargin ? 1 : 0;
const t3 = isSelected ? "messageActionsBackground" : undefined;
// 圆点前缀
t4 = shouldShowDot && <NoSelect fromLeftEdge={true} minWidth={2}>
  <Text color={isSelected ? "suggestion" : "text"}>{BLACK_CIRCLE}</Text>
</NoSelect>;
// Markdown 正文
t5 = <Box flexDirection="column"><Markdown>{text}</Markdown></Box>;
t6 = <Box flexDirection="row">{t4}{t5}</Box>;
t7 = <Box alignItems="flex-start" flexDirection="row" justifyContent="space-between"
  marginTop={t2} width="100%" backgroundColor={t3}>{t6}</Box>;
```

正常回复的视觉特征：

- 圆点前缀 `BLACK_CIRCLE`（`⏺` macOS / `●` 其他平台），颜色为 `text`（选中时为 `suggestion`）
- 圆点使用 `<NoSelect>` 包裹，防止被鼠标选中复制
- 正文通过 `<Markdown>` 渲染，支持完整 Markdown 语法
- 选中时背景色为 `messageActionsBackground`
- `marginTop={addMargin ? 1 : 0}`：消息间留白

### 4. 错误消息渲染

错误消息统一使用 `error` 颜色渲染，并包裹在 `<MessageResponse>` 中。以 API 错误为例，在 [`claude-code-source/src/components/messages/AssistantTextMessage.tsx`](../../claude-code-source/src/components/messages/AssistantTextMessage.tsx#L200-L226) 中定义：

```typescript
// claude-code-source/src/components/messages/AssistantTextMessage.tsx#L200-L226
const t2 = text === API_ERROR_MESSAGE_PREFIX
  ? `${API_ERROR_MESSAGE_PREFIX}: Please wait a moment and try again.`
  : truncated ? text.slice(0, MAX_API_ERROR_CHARS) + "…" : text;
t3 = <Text color="error">{t2}</Text>;
t4 = truncated && <CtrlOToExpand />;
t5 = <MessageResponse><Box flexDirection="column">{t3}{t4}</Box></MessageResponse>;
```

错误消息的特征：

- `color="error"`：红色文本（深色主题 `rgb(255,107,128)`）
- 超长错误（超过 `MAX_API_ERROR_CHARS=1000` 字符）截断并显示 `<CtrlOToExpand />`
- API 前缀错误附加"请稍后重试"的友好提示

## 四、 MessageResponse 缩进容器

### 1. 组件职责

`MessageResponse` 是助手回复的缩进容器，渲染 `⎿`（左下角括号）前缀并处理嵌套去重。该组件在 [`claude-code-source/src/components/MessageResponse.tsx`](../../claude-code-source/src/components/MessageResponse.tsx#L10-L57) 中定义：

```typescript
// claude-code-source/src/components/MessageResponse.tsx#L10-L57
export function MessageResponse(t0) {
  const { children, height } = t0;
  const isMessageResponse = useContext(MessageResponseContext);
  if (isMessageResponse) {
    return children;  // 嵌套时不重复渲染 ⎿
  }
  t1 = <NoSelect fromLeftEdge={true} flexShrink={0}>
    <Text dimColor={true}>{"  "}⎿  </Text>
  </NoSelect>;
  t2 = <Box flexShrink={1} flexGrow={1}>{children}</Box>;
  t3 = <MessageResponseProvider>
    <Box flexDirection="row" height={height} overflowY="hidden">{t1}{t2}</Box>
  </MessageResponseProvider>;
  // ... Ratchet 锁定 ...
}
```

### 2. 视觉特征

- 前缀 `  ⎿  `（2 空格 + 左下角括号 + 2 空格），使用 `dimColor` 暗淡显示
- `<NoSelect>` 包裹前缀，防止复制时混入括号字符
- `flexShrink={0}` 保证前缀不被压缩，`flexGrow={1}` 让内容区填充剩余空间

### 3. 嵌套去重机制

通过 `MessageResponseContext`（React Context）判断当前是否已处于 `MessageResponse` 内部。若是，则直接返回子节点而不重复渲染 `⎿` 前缀，避免嵌套回复出现多层括号。

### 4. Ratchet 离屏锁定

当未指定 `height` 时，内容被 `<Ratchet lock="offscreen">` 包裹。Ratchet 是一种"只增不减"的尺寸锁定机制：一旦内容渲染到屏幕外，其占用的高度不会因后续内容减少而回缩，防止流式输出时的高度抖动。

## 五、 工具使用消息组件

### 1. AssistantToolUseMessage 组件

`AssistantToolUseMessage` 负责渲染工具调用的过程与结果，定义在 [`claude-code-source/src/components/messages/AssistantToolUseMessage.tsx`](../../claude-code-source/src/components/messages/AssistantToolUseMessage.tsx)。该组件是最大的消息组件之一，处理：

- 工具调用名称与参数的显示
- 工具执行状态（进行中、完成、错误）
- 工具结果的格式化输出（代码块、文件 diff、图片等）
- 折叠/展开控制

工具调用消息同样使用 `<MessageResponse>` 包裹，以 `⎿` 前缀与助手文本回复对齐，保持视觉一致性。

## 六、 视觉层次总结

助手侧的消息呈现遵循统一的缩进与前缀体系：

| 内容类型 | 前缀符号 | 颜色 | 容器 |
|---|---|---|---|
| 思考内容（折叠） | `∴ Thinking` | `dimColor` + `italic` | `Box` 顶部留白 |
| 思考内容（展开） | `∴ Thinking…` + 缩进正文 | `dimColor` + `italic` | `Box` 列向，`paddingLeft=2` |
| 文本回复 | `⏺`/`●` 圆点 | `text`（选中 `suggestion`） | `MessageResponse`（`⎿` 前缀） |
| 工具调用 | 无独立前缀 | 各工具自定义 | `MessageResponse`（`⎿` 前缀） |
| 错误消息 | 无圆点 | `error` 红色 | `MessageResponse`（`⎿` 前缀） |

通过 `⎿` 缩进前缀、`⏺` 圆点、`∴` 思考符号三套符号体系，配合 `dimColor`/`text`/`error` 的颜色对比，建立起清晰的内容层级：用户输入（灰底）→ 助手回复（圆点 + 缩进）→ 思考过程（暗淡斜体）→ 工具调用（缩进展开）。

---
*本文档由 markdowncli 技能辅助生成*

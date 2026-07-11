<!-- more -->

## 一、 工具概述

### 1. 工具定位

BashTool 是 Claude Code 中用于执行 shell 命令的内置工具。它将模型发出的结构化输入（命令字符串及参数）转发到底层 shell 执行引擎，再将进程输出回传给模型。该工具的正式名称为 `Bash`，在 [`toolName.ts`](../../claude-code-source/src/tools/BashTool/toolName.ts#L2) 中定义：

```typescript
// claude-code-source/src/tools/BashTool/toolName.ts
export const BASH_TOOL_NAME = 'Bash'
```

BashTool 是整个工具体系中代码量最大的工具，单文件 [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx) 约 157 KB，涵盖工具定义、命令执行、权限委托、结果映射等全部逻辑。

### 2. 架构分层

Bash 工具由四层协作组成：

| 层 | 文件 | 职责 |
| - | - | - |
| 工具定义 | [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx) | 定义 schema、权限委托、执行入口 `call()`、结果映射 |
| 提示词 | [`prompt.ts`](../../claude-code-source/src/tools/BashTool/prompt.ts) | 生成给模型的系统提示（用法说明、sandbox 规则、git 工作流） |
| 权限 | [`bashPermissions.ts`](../../claude-code-source/src/tools/BashTool/bashPermissions.ts) | 命令安全解析、AST 拆分、规则匹配、allow/ask/deny 决策 |
| 执行引擎 | [`Shell.ts`](../../claude-code-source/src/utils/Shell.ts) + [`bashProvider.ts`](../../claude-code-source/src/utils/shell/bashProvider.ts) | 选择 shell、构建命令串、`spawn` 子进程、收集输出 |

## 二、 工具定义结构

### 1. 输入 Schema

Bash 工具的输入 schema 在 [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L227-L247) 中通过 Zod 定义：

```typescript
// claude-code-source/src/tools/BashTool/BashTool.tsx
const fullInputSchema = lazySchema(() => z.strictObject({
  command: z.string().describe('The command to execute'),
  timeout: semanticNumber(z.number().optional())
    .describe(`Optional timeout in milliseconds (max ${getMaxTimeoutMs()})`),
  description: z.string().optional()
    .describe(`Clear, concise description of what this command does...`),
  run_in_background: semanticBoolean(z.boolean().optional())
    .describe(`Set to true to run this command in the background...`),
  dangerouslyDisableSandbox: semanticBoolean(z.boolean().optional())
    .describe('Set this to true to dangerously override sandbox mode...'),
  _simulatedSedEdit: z.object({
    filePath: z.string(),
    newContent: z.string()
  }).optional().describe('Internal: pre-computed sed edit result from preview')
}));
```

其中 `_simulatedSedEdit` 是内部字段，始终从模型可见的 schema 中剔除，仅由 sed 编辑预览审批流程内部设置。暴露它会让模型绕过权限检查和沙箱。当后台任务被禁用时，`run_in_background` 也被一并剔除。

### 2. 输入参数详解

Bash 工具共有 6 个输入参数，其中 4 个对模型可见，2 个为内部字段。完整定义在 [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L227-L264) 中：

#### 2.1 `command`

- **类型**：`string`（必填）
- **模型可见**：是
- **说明**：要执行的 bash 命令字符串。这是唯一必填参数，可以是单条命令、管道命令、复合命令（`&&` / `;` / `|`）或 heredoc 多行命令。工作目录在命令间持久化，但 shell 状态（如变量、函数）不持久化。
- **示例**：`git status`、`npm install && npm run build`、`cat <<'EOF'\n...\nEOF`

#### 2.2 `timeout`

- **类型**：`number | undefined`（可选，单位毫秒）
- **模型可见**：是
- **默认值**：120000（2 分钟），由 [`timeouts.ts`](../../claude-code-source/src/utils/timeouts.ts#L2-L21) 中的 `getDefaultBashTimeoutMs()` 返回
- **最大值**：600000（10 分钟），由 [`timeouts.ts`](../../claude-code-source/src/utils/timeouts.ts#L28-L39) 中的 `getMaxBashTimeoutMs()` 返回
- **环境变量覆盖**：
  - `BASH_DEFAULT_TIMEOUT_MS`：覆盖默认超时值
  - `BASH_MAX_TIMEOUT_MS`：覆盖最大超时值（保证不小于默认值）
- **说明**：命令超过此时间未完成时，若 `shouldAutoBackground` 为真则自动转后台运行；否则中断命令。系统提示词中会告知模型当前的超时上限和默认值。
- **运行时逻辑**（[`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L860)）：
  ```typescript
  const timeoutMs = timeout || getDefaultTimeoutMs();
  ```

#### 2.3 `description`

- **类型**：`string | undefined`（可选）
- **模型可见**：是
- **说明**：对命令做什么的简明主动语态描述。禁止使用 "complex"、"risk" 等词汇。该字段用于 UI 展示和工具调用摘要，不影响命令执行。
- **描述风格引导**（[`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L230-L240)）：
  - 简单命令保持简短（5-10 词）：`ls` → `"List files in current directory"`
  - 复杂命令补充足够上下文：`find . -name "*.tmp" -exec rm {} \;` → `"Find and delete all .tmp files recursively"`
- **用途**：当提供时，`getToolUseSummary()` 优先返回 description 而非截断的 command；`getActivityDescription()` 也会使用它生成 `Running <description>` 活动描述。

#### 2.4 `run_in_background`

- **类型**：`boolean | undefined`（可选，默认 `false`）
- **模型可见**：是（当后台任务未被禁用时）
- **说明**：设为 `true` 时命令在后台运行，立即返回 `backgroundTaskId`，不阻塞对话。命令完成后模型会收到通知。
- **禁用条件**：当环境变量 `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` 为真时，该参数从模型可见 schema 中剔除，后台运行功能完全关闭。
- **运行时行为**（[`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L989-L1001)）：
  ```typescript
  if (run_in_background === true && !isBackgroundTasksDisabled) {
    const shellId = await spawnBackgroundTask();
    return { stdout: '', stderr: '', code: 0, interrupted: false, backgroundTaskId: shellId };
  }
  ```
- **注意**：显式后台运行不检查 `isAutobackgroundingAllowed()`，任何命令都可以被显式后台化。不需要在命令末尾加 `&`。

#### 2.5 `dangerouslyDisableSandbox`

- **类型**：`boolean | undefined`（可选，默认 `false`）
- **模型可见**：是
- **说明**：设为 `true` 时绕过沙箱模式，命令不受文件系统和网络限制。这是一个危险操作，会触发权限询问。
- **生效条件**（[`shouldUseSandbox.ts`](../../claude-code-source/src/tools/BashTool/shouldUseSandbox.ts#L130-L153)）：
  ```typescript
  export function shouldUseSandbox(input: Partial<SandboxInput>): boolean {
    if (!SandboxManager.isSandboxingEnabled()) return false;
    // 仅当显式绕过且策略允许非沙箱命令时才禁用沙箱
    if (input.dangerouslyDisableSandbox && SandboxManager.areUnsandboxedCommandsAllowed()) {
      return false;
    }
    if (!input.command) return false;
    if (containsExcludedCommand(input.command)) return false;
    return true;
  }
  ```
- **策略限制**：
  - 若 `SandboxManager.areUnsandboxedCommandsAllowed()` 返回 `false`（策略禁止非沙箱命令），则该参数无效，所有命令必须在沙箱中运行
  - 若策略允许，模型在遇到沙箱导致的失败（如 "Operation not permitted"）后可自动重试并设置 `dangerouslyDisableSandbox: true`，无需先询问用户

#### 2.6 `_simulatedSedEdit`

- **类型**：`{ filePath: string, newContent: string } | undefined`（可选）
- **模型可见**：否（始终从模型 schema 中剔除）
- **说明**：内部专用字段，由 sed 编辑预览审批流程在用户批准后设置。包含预计算的 sed 编辑结果（目标文件路径和新内容），使实际写入的内容与用户预览的内容完全一致。
- **安全设计**（[`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L249-L259)）：
  ```typescript
  // Always omit _simulatedSedEdit from the model-facing schema. It is an internal-only
  // field set by SedEditPermissionRequest after the user approves a sed edit preview.
  // Exposing it in the schema would let the model bypass permission checks and the
  // sandbox by pairing an innocuous command with an arbitrary file write.
  const inputSchema = lazySchema(() => isBackgroundTasksDisabled
    ? fullInputSchema().omit({ run_in_background: true, _simulatedSedEdit: true })
    : fullInputSchema().omit({ _simulatedSedEdit: true })
  );
  ```
- **重要**：暴露该字段会让模型通过"无害命令 + 任意文件写入"的组合绕过权限检查和沙箱，因此永远不对模型可见。

### 3. 参数可见性汇总

模型实际能看到的参数取决于运行时配置：

| 参数 | 默认可见 | 后台任务禁用时 | 沙箱禁用时 |
| - | - | - | - |
| `command` | 是 | 是 | 是 |
| `timeout` | 是 | 是 | 是 |
| `description` | 是 | 是 | 是 |
| `run_in_background` | 是 | 否（剔除） | 是 |
| `dangerouslyDisableSandbox` | 是 | 是 | 是（但无效） |
| `_simulatedSedEdit` | 否（始终剔除） | 否（始终剔除） | 否（始终剔除） |

### 4. 输出 Schema

输出 schema 在 [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L279-L294) 中定义：

```typescript
// claude-code-source/src/tools/BashTool/BashTool.tsx
const outputSchema = lazySchema(() => z.object({
  stdout: z.string().describe('The standard output of the command'),
  stderr: z.string().describe('The standard error output of the command'),
  rawOutputPath: z.string().optional(),
  interrupted: z.boolean().describe('Whether the command was interrupted'),
  isImage: z.boolean().optional(),
  backgroundTaskId: z.string().optional(),
  backgroundedByUser: z.boolean().optional(),
  assistantAutoBackgrounded: z.boolean().optional(),
  dangerouslyDisableSandbox: z.boolean().optional(),
  returnCodeInterpretation: z.string().optional(),
  noOutputExpected: z.boolean().optional(),
  structuredContent: z.array(z.any()).optional(),
  persistedOutputPath: z.string().optional(),
  persistedOutputSize: z.number().optional()
}));
```

### 5. 工具核心字段

BashTool 通过 `buildTool()` 构建，定义在 [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L420-L825) 中：

```typescript
// claude-code-source/src/tools/BashTool/BashTool.tsx
export const BashTool = buildTool({
  name: BASH_TOOL_NAME,
  searchHint: 'execute shell commands',
  maxResultSizeChars: 30_000,
  strict: true,
  async prompt() { return getSimplePrompt(); },
  isReadOnly(input) { /* 检查是否只读命令 */ },
  async validateInput(input) { /* 拦截 sleep 等模式 */ },
  async checkPermissions(input, context) {
    return bashToolHasPermission(input, context);
  },
  async call(input, toolUseContext, _canUseTool, parentMessage, onProgress) {
    /* 主执行入口 */
  },
  mapToolResultToToolResultBlockParam(...) { /* 结果映射 */ },
});
```

`maxResultSizeChars: 30_000` 表示超过 3 万字符的输出会被持久化到磁盘，模型收到的是预览片段加文件路径。

## 三、 执行流程

### 1. 整体调用链

模型调用 Bash 工具后，执行链路如下：

```
模型调用 Bash(command)
  │
  ├─ validateInput()        → 拦截被禁止的 sleep 模式
  ├─ checkPermissions()     → bashToolHasPermission() 决策
  │     ├─ AST 解析拆分复合命令
  │     ├─ 剥壳（去 wrapper / env var）
  │     ├─ 规则匹配（allow / ask / deny）
  │     └─ 分类器判断
  │
  ├─ [ask] → 弹出确认框 → 用户决定
  │
  └─ call()
       └─ runShellCommand()   (async generator，负责进度上报与后台化)
            └─ exec()          (Shell.ts 底层执行)
                 ├─ findSuitableShell()     选择 bash/zsh
                 ├─ provider.buildExecCommand()  组装命令串
                 ├─ SandboxManager.wrapWithSandbox()  (如启用 sandbox)
                 └─ spawn(binShell, ['-c', commandString], {cwd, env, stdio})
```

### 2. 输入校验

`validateInput()` 在 [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L524-L538) 中实现，主要拦截被禁止的 sleep 模式：

```typescript
// claude-code-source/src/tools/BashTool/BashTool.tsx
async validateInput(input: BashToolInput): Promise<ValidationResult> {
  if (feature('MONITOR_TOOL') && !isBackgroundTasksDisabled && !input.run_in_background) {
    const sleepPattern = detectBlockedSleepPattern(input.command);
    if (sleepPattern !== null) {
      return {
        result: false,
        message: `Blocked: ${sleepPattern}. Run blocking commands in the background...`,
        errorCode: 10
      };
    }
  }
  return { result: true };
}
```

`detectBlockedSleepPattern()` 会检测 `sleep N`（N≥2）作为首命令的模式，要求改用后台运行或 Monitor 工具。N<2 的 sleep 被视为合法的速率限制/节奏控制，予以放行。

### 3. 主执行入口 call()

`call()` 方法是 BashTool 的核心，在 [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L624-L820) 中实现：

```typescript
// claude-code-source/src/tools/BashTool/BashTool.tsx
async call(input, toolUseContext, _canUseTool, parentMessage, onProgress) {
  // 1. 处理模拟 sed 编辑 —— 直接应用预览结果
  if (input._simulatedSedEdit) {
    return applySedEdit(input._simulatedSedEdit, toolUseContext, parentMessage);
  }

  // 2. 启动 runShellCommand 异步生成器
  const commandGenerator = runShellCommand({
    input, abortController, setAppState, setToolJSX,
    preventCwdChanges: !isMainThread, isMainThread, toolUseId, agentId
  });

  // 3. 消费生成器，转发进度
  do {
    generatorResult = await commandGenerator.next();
    if (!generatorResult.done && onProgress) {
      onProgress({ /* 进度数据 */ });
    }
  } while (!generatorResult.done);

  // 4. 获取最终结果
  result = generatorResult.value;

  // 5. 后处理：语义解读、sandbox 标注、大输出持久化、图片检测...
}
```

`call()` 方法的职责划分清晰：前置处理模拟 sed 编辑，中段消费 `runShellCommand` 生成器并转发进度，后段对结果做语义解读、sandbox 违规标注、大输出持久化、图片检测、claude-code-hint 提取等处理。

### 4. runShellCommand() 生成器

`runShellCommand()` 是一个 async generator，在 [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L826-L1143) 中实现。它负责调用 `exec()`、上报进度、处理后台化：

```typescript
// claude-code-source/src/tools/BashTool/BashTool.tsx
async function* runShellCommand({ input, abortController, ... }): AsyncGenerator<...> {
  const { command, description, timeout, run_in_background } = input;
  const timeoutMs = timeout || getDefaultTimeoutMs();
  const shouldAutoBackground = !isBackgroundTasksDisabled && isAutobackgroundingAllowed(command);

  // 调用 exec() 执行命令
  const shellCommand = await exec(command, abortController.signal, 'bash', {
    timeout: timeoutMs,
    onProgress(lastLines, allLines, totalLines, totalBytes, isIncomplete) {
      lastProgressOutput = lastLines;
      fullOutput = allLines;
      // 唤醒生成器以 yield 进度
      const resolve = resolveProgress;
      if (resolve) { resolveProgress = null; resolve(); }
    },
    preventCwdChanges,
    shouldUseSandbox: shouldUseSandbox(input),
    shouldAutoBackground
  });

  // 显式后台运行
  if (run_in_background === true && !isBackgroundTasksDisabled) {
    const shellId = await spawnBackgroundTask();
    return { stdout: '', stderr: '', code: 0, interrupted: false, backgroundTaskId: shellId };
  }

  // 进度循环：由共享轮询器驱动
  while (true) {
    const result = await Promise.race([resultPromise, progressSignal]);
    if (result !== null) return result;  // 命令完成
    yield { type: 'progress', output: lastProgressOutput, /* ... */ };
  }
}
```

### 5. 后台化机制

Bash 工具支持三种后台化触发方式：

#### 5.1 显式后台

模型设置 `run_in_background: true` 时，命令直接通过 `spawnShellTask()` 转为后台任务，立即返回 `backgroundTaskId`：

```typescript
// claude-code-source/src/tools/BashTool/BashTool.tsx
if (run_in_background === true && !isBackgroundTasksDisabled) {
  const shellId = await spawnBackgroundTask();
  return {
    stdout: '', stderr: '', code: 0,
    interrupted: false, backgroundTaskId: shellId
  };
}
```

#### 5.2 超时自动后台

当命令超时且 `shouldAutoBackground` 为真时，`shellCommand.onTimeout` 回调触发后台化。`isAutobackgroundingAllowed()` 会排除不应自动后台的命令（如 sleep 本身）。

#### 5.3 Assistant 模式自动后台

在 assistant 模式（Kairos）下，主线程阻塞超过 `ASSISTANT_BLOCKING_BUDGET_MS`（15 秒）的命令会被自动转后台，保持对话响应性：

```typescript
// claude-code-source/src/tools/BashTool/BashTool.tsx
const ASSISTANT_BLOCKING_BUDGET_MS = 15_000;

if (feature('KAIROS') && getKairosActive() && isMainThread && !run_in_background) {
  setTimeout(() => {
    if (shellCommand.status === 'running' && backgroundShellId === undefined) {
      assistantAutoBackgrounded = true;
      startBackgrounding('tengu_bash_command_assistant_auto_backgrounded');
    }
  }, ASSISTANT_BLOCKING_BUDGET_MS).unref();
}
```

## 四、 底层执行引擎

### 1. exec()

`exec()` 是底层 shell 执行函数，在 [`Shell.ts`](../../claude-code-source/src/utils/Shell.ts#L181-L442) 中定义。该函数负责选择 shell、构建命令、创建子进程、收集输出。

【**函数作用**】

该函数执行一条 shell 命令，创建子进程并返回 `ShellCommand` 对象以供调用方追踪结果和进度。

【**参数含义**】

- `command`：要执行的命令字符串
- `abortSignal`：`AbortSignal` 对象，用于中断执行
- `shellType`：shell 类型，取值为 `'bash'` 或 `'powershell'`
- `options`：执行选项对象，包含以下字段：
  - `timeout`：超时时间（毫秒），默认 30 分钟
  - `onProgress`：进度回调函数
  - `preventCwdChanges`：是否阻止命令改变工作目录（子代理为 true）
  - `shouldUseSandbox`：是否启用沙箱
  - `shouldAutoBackground`：是否允许自动后台化
  - `onStdout`：stdout 管道回调（提供时启用管道模式）

【**返回值**】

返回 `ShellCommand` 对象，包含 `.result` Promise（解析为 `ExecResult`）和 `.cleanup()` 方法。若 shell 找不到则抛出错误，若 spawn 失败返回 `createAbortedCommand()`。

### 2. Shell 选择

`findSuitableShell()` 在 [`Shell.ts`](../../claude-code-source/src/utils/Shell.ts#L73-L137) 中实现，按以下优先级选择 shell：

- `CLAUDE_CODE_SHELL` 环境变量指定的 shell（须为 bash 或 zsh）
- `SHELL` 环境变量（须为 bash 或 zsh 且可执行）
- `which` 命令查找的 zsh/bash 路径
- 常见路径 `/bin`、`/usr/bin`、`/usr/local/bin`、`/opt/homebrew/bin` 下的 bash/zsh

若用户偏好 bash，则搜索顺序为 bash 优先；否则 zsh 优先。

### 3. 命令组装

`buildExecCommand()` 在 [`bashProvider.ts`](../../claude-code-source/src/utils/shell/bashProvider.ts#L77-L198) 中实现，将用户命令包装为完整的 shell 脚本：

```typescript
// claude-code-source/src/utils/shell/bashProvider.ts
async buildExecCommand(command, opts) {
  // 1. 加载环境快照（source snapshot || true）
  if (snapshotFilePath) {
    commandParts.push(`source ${quote([finalPath])} 2>/dev/null || true`);
  }
  // 2. 加载会话环境变量
  if (sessionEnvScript) commandParts.push(sessionEnvScript);
  // 3. 关闭扩展 glob（安全防护）
  if (disableExtglobCmd) commandParts.push(disableExtglobCmd);
  // 4. eval 执行用户命令
  commandParts.push(`eval ${quotedCommand}`);
  // 5. 记录执行后的工作目录
  commandParts.push(`pwd -P >| ${quote([shellCwdFilePath])}`);
  
  return { commandString: commandParts.join(' && '), cwdFilePath };
}
```

实际传给 shell 的命令串结构为：

```bash
source <snapshot> 2>/dev/null || true \
  && <session_env_script> \
  && shopt -u extglob 2>/dev/null || true \
  && eval '<用户命令>' \
  && pwd -P >| <temp_cwd_file>
```

使用 `eval` 是因为 `source` 加载的别名需要二次解析才能展开。关闭 `extglob` 是安全防护，防止恶意文件名利用扩展 glob 模式在安全校验后展开。

### 4. 子进程创建

`exec()` 通过 Node.js 的 `spawn()` 创建子进程，在 [`Shell.ts`](../../claude-code-source/src/utils/Shell.ts#L316-L337) 中实现：

```typescript
// claude-code-source/src/utils/Shell.ts
const childProcess = spawn(spawnBinary, shellArgs, {
  env: {
    ...subprocessEnv(),
    SHELL: binShell,
    GIT_EDITOR: 'true',          // 防止 git 打开编辑器
    CLAUDECODE: '1',             // 标识 Claude Code 子进程
    ...envOverrides,
  },
  cwd,
  stdio: usePipeMode
    ? ['pipe', 'pipe', 'pipe']   // 管道模式
    : ['pipe', outputHandle?.fd, outputHandle?.fd],  // 文件模式
  detached: provider.detached,   // 独立进程组（便于 tree-kill）
  windowsHide: true,
});
```

输出收集采用两种模式：

- **文件模式**（默认）：stdout 和 stderr 合并写入同一个文件 fd，使用 `O_APPEND` 原子追加保证时序，`O_NOFOLLOW` 防止符号链接攻击
- **管道模式**（提供 `onStdout` 时）：stdout 通过管道实时回调

## 五、 权限系统

### 1. 权限决策入口

`checkPermissions()` 委托给 `bashToolHasPermission()`，在 [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L539-L541) 中定义：

```typescript
// claude-code-source/src/tools/BashTool/BashTool.tsx
async checkPermissions(input, context): Promise<PermissionResult> {
  return bashToolHasPermission(input, context);
}
```

权限决策返回三种结果，定义在 [`PermissionResult.ts`](../../claude-code-source/src/utils/permissions/PermissionResult.ts#L27-L34) 中：

```typescript
// claude-code-source/src/utils/permissions/PermissionResult.ts
switch (permissionResult.behavior) {
  case 'allow':  return 'allowed';
  case 'deny':   return 'denied';
  default:       return 'asked for confirmation for';
}
```

- **`allow`**：直接执行，不询问用户
- **`ask`**：弹出确认框，等待用户批准
- **`deny`**：拒绝执行

### 2. 安全分析流程

`bashToolHasPermission()` 在 [`bashPermissions.ts`](../../claude-code-source/src/tools/BashTool/bashPermissions.ts) 中实现，采用多层防御：

#### 2.1 命令拆分

使用 tree-sitter AST 解析复合命令（`&&`、`|`、`;`），对每个子命令单独评估安全性。当子命令数超过 `MAX_SUBCOMMANDS_FOR_SECURITY_CHECK`（50）时，安全降级为 `ask`。

```typescript
// claude-code-source/src/tools/BashTool/bashPermissions.ts
export const MAX_SUBCOMMANDS_FOR_SECURITY_CHECK = 50
```

#### 2.2 剥壳处理

`stripSafeWrappers()` 剥掉安全包装器（`timeout`、`time`、`nice`、`nohup`、`stdbuf`）和安全环境变量前缀（如 `NODE_ENV=...`），露出真实命令再做规则匹配。例如 `NODE_ENV=prod npm run build` 会被剥为 `npm run build` 再匹配规则。

安全环境变量白名单 `SAFE_ENV_VARS` 在 [`bashPermissions.ts`](../../claude-code-source/src/tools/BashTool/bashPermissions.ts#L378-L430) 中定义，仅包含不影响代码执行的环境变量（如 `GOOS`、`RUST_BACKTRACE`、`NODE_ENV`、`TERM` 等）。`PATH`、`LD_PRELOAD`、`PYTHONPATH` 等可执行代码或加载库的变量**永远不会**被加入白名单。

#### 2.3 规则匹配

对照用户配置的 permission rules（`allow` / `ask` / `deny` 列表），支持通配符如 `Bash(npm:*)`。匹配时先剥壳再做前缀或精确匹配。

#### 2.4 分类器

可选的 ML 分类器 `classifyBashCommand()` 判断命令危险度，由 `isClassifierPermissionsEnabled()` 控制是否启用。

### 3. 只读判断

`isReadOnly()` 在 [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L437-L441) 中实现，判断命令是否为只读：

```typescript
// claude-code-source/src/tools/BashTool/BashTool.tsx
isReadOnly(input) {
  const compoundCommandHasCd = commandHasAnyCd(input.command);
  const result = checkReadOnlyConstraints(input, compoundCommandHasCd);
  return result.behavior === 'allow';
}
```

只读命令（如 `ls`、`cat`、`git status`）可并发安全执行，不触发权限询问。源码中定义了多个命令分类集合：

- `BASH_SEARCH_COMMANDS`：`find`、`grep`、`rg`、`ag` 等搜索命令
- `BASH_READ_COMMANDS`：`cat`、`head`、`tail`、`wc`、`stat` 等读取命令
- `BASH_LIST_COMMANDS`：`ls`、`tree`、`du` 等列目录命令
- `BASH_SILENT_COMMANDS`：`mv`、`cp`、`rm`、`mkdir` 等无 stdout 输出的命令

## 六、 沙箱机制

### 1. 沙箱启用判断

`shouldUseSandbox()` 决定命令是否在沙箱中执行，考虑因素包括用户配置、命令类型和 `dangerouslyDisableSandbox` 参数。

### 2. 沙箱配置

沙箱配置在 [`prompt.ts`](../../claude-code-source/src/tools/BashTool/prompt.ts#L172-L273) 的 `getSimpleSandboxSection()` 中生成，告知模型当前限制：

- **文件系统**：`read.denyOnly` 拒绝读取的路径、`write.allowOnly` 允许写入的路径白名单
- **网络**：`allowedHosts` / `deniedHosts` 主机白名单
- **临时目录**：须使用 `$TMPDIR` 而非 `/tmp`

当 `dangerouslyDisableSandbox` 被允许时，模型可在遇到沙箱导致的失败后自动重试并设置该参数。沙箱违规错误包括 "Operation not permitted"、访问被拒等。

### 3. 沙箱包装

沙箱执行时，命令通过 `SandboxManager.wrapWithSandbox()` 包装，在 [`Shell.ts`](../../claude-code-source/src/utils/Shell.ts#L259-L273) 中调用：

```typescript
// claude-code-source/src/utils/Shell.ts
if (shouldUseSandbox) {
  commandString = await SandboxManager.wrapWithSandbox(
    commandString, sandboxBinShell, undefined, abortSignal
  );
  // 创建沙箱临时目录（权限 0o700）
  await fs.mkdir(sandboxTmpDir, { mode: 0o700 });
}
```

沙箱还设置 `TMPDIR` 和 `CLAUDE_CODE_TMPDIR` 环境变量指向沙箱可写目录。

### 4. 底层隔离原理概览

上面 1~3 小节描述的是**应用层**的沙箱逻辑（何时启用、如何配置、如何包装命令）。真正提供强制隔离能力的，是位于 `SandboxManager.wrapWithSandbox()` 之下的**内核级隔离原语**，封装在独立的 [`@anthropic-ai/sandbox-runtime`](https://github.com/anthropics) 包中（私有依赖，源码仓库未 vendor）。

> 注：底层实现来自 `@anthropic-ai/sandbox-runtime`，以下源码引用基于其同名 fork `@vscode/sandbox-runtime`（API 一致），路径形如 `dist/sandbox/linux-sandbox-utils.js`。

整体分层如下：

```
BashTool / shouldUseSandbox()
        ↓
sandbox-adapter.ts   ← Claude 适配层：settings.json → SandboxRuntimeConfig
        ↓
@anthropic-ai/sandbox-runtime   ← 底层隔离原语
        ├─ Linux:  bwrap (bubblewrap) + seccomp + socat
        └─ macOS:  sandbox-exec (Seatbelt profile)
```

它**不是字符串黑名单或权限弹框那种"软"控制**，而是操作系统内核层面的强制隔离：进程从内核视角就看不到、写不到、连不到未授权的资源。模型即使想作恶，进程也物理上够不到被保护的东西。

两个平台的隔离原语：

| 平台 | 文件系统隔离 | 网络隔离 | 进程能力限制 |
| - | - | - | - |
| **Linux** | `bubblewrap (bwrap)` 挂载命名空间 | `bwrap --unshare-net` + `socat` 代理 + `seccomp` | seccomp 过滤系统调用 |
| **macOS** | `sandbox-exec` Seatbelt profile | Seatbelt network 规则 + 代理 | Seatbelt 操作白名单 |

### 5. Linux 沙箱：bwrap + seccomp + socat

#### 5.1 bwrap（bubblewrap）是什么

`bwrap` 是 Linux 上一个**非特权用户也能用**的轻量级沙箱工具，GNOME / Flatpak 项目的底层就是它。通过 **Linux 命名空间（namespace）** 给进程套一个隔离环境，能决定进程"能看见哪些文件、能不能联网、能不能看到别的进程"。

| 项目 | 内容 |
| - | - |
| 包名 | `bubblewrap`（命令 `bwrap`） |
| 出身 | GNOME / Flatpak 项目（红帽系） |
| 定位 | utility for **unprivileged** chroot and namespace manipulation |
| 体积 | 极小（Debian 包约 127 KB） |
| 主页 | https://github.com/containers/bubblewrap |

与 Docker 的对比——两者同源（都基于 Linux namespace），但定位相反：

| 维度 | Docker | bwrap |
| - | - | - |
| 目的 | 运行完整应用 / 服务 | 给单个进程套个隔离罩 |
| 隔离粒度 | 重（整个文件系统镜像） | 轻（只挂载你要的几个目录） |
| 需要 root？ | 历史上需要，rootless 较新 | 设计目标就是不需要 root |
| 网络隔离 | veth/bridge 一整套 | 一个 `--unshare-net` 搞定 |
| 配置方式 | Dockerfile + 守护进程 | 命令行参数，一次性 |
| 典型场景 | 运维 / 部署 | 桌面沙箱（Flatpak）、CI、安全工具 |

Claude Code 选 bwrap 而非 Docker 的原因：**零特权门槛**（用户不用 sudo、不用起 dockerd）、**极轻量**（毫秒级启动，适合"每条命令都套一层"）、**细粒度挂载**（精确到路径级白名单）、**成熟可信**（Flatpak 生态验证多年）。

#### 5.2 文件系统隔离：挂载命名空间

核心在 `generateFilesystemArgs()`（`dist/sandbox/linux-sandbox-utils.js:494`）。原理是**默认拒绝**——进来先让整个根目录只读，再对白名单路径单独开写：

```bash
bwrap \
  --ro-bind / /                    \   # ① 整个根目录只读挂载（默认拒绝写）
  --bind <允许写入的路径> <同路径>   \   # ② 对白名单路径单独开可写
  --ro-bind /dev/null <危险路径>    \   # ③ 把危险路径用空设备盖死
  --dev /dev --proc /proc ...      \   # ④ 标准的 /dev /proc
  --unshare-net ...                    # ⑤ 网络命名空间隔离
  --die-with-parent ...                # ⑥ bwrap 退出时子进程跟着退出
  -- sh -c "用户命令"
```

#### 5.3 危险路径的主动扫描与封堵

`linuxGetMandatoryDenyPaths()`（`linux-sandbox-utils.js:102`）在**每条命令执行前**用 ripgrep 扫描 cwd 下 3 层深度，强制封堵：

| 封堵对象 | 为什么危险 |
| - | - |
| `.git/hooks` | 攻击者写入钩子 → 下次 git 操作执行任意代码 |
| `.git/config` | `core.fsmonitor` 等配置可执行任意命令 |
| `settings.json` / `.claude/settings.local.json` | 改设置 → 修改权限规则 → **逃逸沙箱** |
| `.claude/skills` / `.claude/commands` / `.claude/agents` | 自动加载、有完整 Claude 能力的资源 |
| `DANGEROUS_FILES` / `getDangerousDirectories()` | 各种已知敏感文件 |

对**不存在的危险路径**也防：挂 `/dev/null` 在那里让它"永远建不起来"（`linux-sandbox-utils.js:579`），防止沙箱内进程 `mkdir + 写`绕过；并追踪这些挂载点在命令退出后清理（`cleanupBwrapMountPoints()` `:247`）。

#### 5.4 网络隔离：socat 桥 + 域名过滤

Linux 的 `--unshare-net` 是**全有或全无**的——进了命名空间就连不到外网。要联网时（`initializeLinuxNetworkBridge()` `:341`），通过 socat 桥接：

```
沙箱内进程 ──TCP:3128──▶ socat ──Unix socket──▶ host 的 HTTP 代理
            ──TCP:1080──▶ socat ──Unix socket──▶ host 的 SOCKS5 代理
```

- HTTP/HTTPS 走 3128 → host HTTP proxy
- git/SSH 走 1080 → host SOCKS5 proxy（通过 `GIT_SSH_COMMAND` 套 socat）
- **域名过滤发生在 host 的 proxy 层**，而不是沙箱边界

#### 5.5 Unix socket 的 seccomp 过滤

seccomp 通过 `apply-seccomp` 二进制限制系统调用（在 socat 起来之后再应用），精确控制哪些 Unix socket 可 `connect`——这是网络隔离的细粒度补充。依赖检查见 `checkLinuxDependencies()`（`linux-sandbox-utils.js:302`）：缺 `bwrap` / `socat` / `apply-seccomp` 时分别报错或告警。

### 6. macOS 沙箱：Seatbelt / sandbox-exec

macOS 用 Apple 自带的 `sandbox-exec`，生成一个 **Seatbelt profile**（`generateSandboxProfile()` `dist/sandbox/macos-sandbox-utils.js:260`），形如：

```scheme
(version 1)
; 基于 Chrome sandbox policy 的最小必要权限
(allow file-read*)                          ; 默认允许读
(deny file-read* (subpath "/Users/..."))    ; 拒绝读敏感区
(allow file-read* (subpath "..."))          ; 在被拒区域内重开白名单
(deny file-write* (subpath "..."))          ; 拒绝写
(deny file-write-unlink (subpath "..."))    ; 防止"移动文件"绕过
(deny file-write-create (subpath "..."))    ; 防止"创建替换"绕过
```

关键细节：

- **后定义的规则优先**（last-match-wins），顺序很讲究：先 allow 全部 → 再 deny 敏感区 → 再 allow 白名单
- 支持 `globToRegex()` 把 glob 模式编译成正则，profile 原生匹配
- macOS 用**静态 glob 模式**而非 ripgrep 扫描（profile 自己能匹配），见 `macGetMandatoryDenyPatterns()`（`macos-sandbox-utils.js:11`）

### 7. 配套安全防线

除 OS 沙箱外，适配层（[`sandbox-adapter.ts`](../../claude-code-source/src/utils/sandbox/sandbox-adapter.ts)）还提供几道纵深防御：

| 防线 | 实现 | 作用 |
| - | - | - |
| **设置文件永远禁写** | `denyWrite.push(...settingsPaths)` ([`sandbox-adapter.ts:232`](../../claude-code-source/src/utils/sandbox/sandbox-adapter.ts#L232)) | 命令不能改自己的权限规则 |
| **符号链接替换攻击防御** | `findSymlinkInPath()` 挂 `/dev/null` | 防止"删软链→建真目录→写恶意内容" |
| **bare repo 植入防御** | `scrubBareGitRepoFiles()` ([`sandbox-adapter.ts:404`](../../claude-code-source/src/utils/sandbox/sandbox-adapter.ts#L404)) | 植入假 `HEAD`/`objects`/`refs`/`config` 伪装 git 仓库 → 沙箱内执行后、非沙箱 git 跑之前清掉 |
| **worktree 支持** | `detectWorktreeMainRepoPath()` ([`sandbox-adapter.ts:422`](../../claude-code-source/src/utils/sandbox/sandbox-adapter.ts#L422)) | worktree 下 `.git` 是文件，特殊处理 |
| **`dangerouslyDisableSandbox` 双重门** | [`shouldUseSandbox.ts:130`](../../claude-code-source/src/tools/BashTool/shouldUseSandbox.ts#L130) | 只有 `areUnsandboxedCommandsAllowed()` 为真才允许绕过；策略可锁死 |
| **依赖缺失显式告警** | `getSandboxUnavailableReason()` ([`sandbox-adapter.ts:562`](../../claude-code-source/src/utils/sandbox/sandbox-adapter.ts#L562)) | 用户开了沙箱但缺 bwrap/socat 时显式警告，而非静默降级 |

### 8. 安全设计原则

| 原则 | 体现 |
| - | - |
| **内核强制，非自觉** | 用 bwrap namespace / Seatbelt，进程从内核层就被限制，绕不过 |
| **默认拒绝** | Linux 先 `--ro-bind / /` 只读，再开白名单；不是"黑名单" |
| **纵深防御** | 应用层权限（ask/deny） + OS 沙箱 + 危险路径扫描，层层独立 |
| **保护信任根** | settings.json、`.git/config`、`.claude/skills` 等"能改变程序行为"的路径永远禁写——改了它们 = 逃逸 |
| **显式失败** | 依赖缺失就明确告诉用户"沙箱没生效"，而非静默裸跑（防 false sense of security） |
| **策略可锁** | `allowUnsandboxedCommands: false` 能让 `dangerouslyDisableSandbox` 彻底无效，企业可强制 |
| **攻击面覆盖** | 符号链接替换、bare repo 植入、git hooks 注入、fsmonitor 配置注入……都有专门防御 |

> **小结**：Claude Code 的沙箱不是字符串黑名单或权限弹框那种"软"控制，而是用 **Linux 的 bubblewrap+seccomp / macOS 的 Seatbelt** 在内核层做**文件系统挂载隔离 + 网络命名空间隔离 + 系统调用过滤**。模型即使想作恶，进程也物理上够不到被保护的东西——这是它能"安全地自动执行命令"的根基。

## 七、 返回结果处理

### 1. 结果后处理流程

`call()` 在获得 `ExecResult` 后进行一系列后处理，在 [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L683-L819) 中实现：

```typescript
// claude-code-source/src/tools/BashTool/BashTool.tsx
// 1. 语义解读退出码
interpretationResult = interpretCommandResult(input.command, result.code, result.stdout, '');

// 2. 标注 sandbox 违规
const outputWithSbFailures = SandboxManager.annotateStderrWithSandboxFailures(
  input.command, result.stdout || ''
);

// 3. 大输出持久化（>64MB 截断）
if (result.outputFilePath && result.outputTaskId) {
  const fileStat = await fsStat(result.outputFilePath);
  if (fileStat.size > MAX_PERSISTED_SIZE) {
    await fsTruncate(result.outputFilePath, MAX_PERSISTED_SIZE);
  }
  await link(result.outputFilePath, dest);  // 或 copyFile 回退
  persistedOutputPath = dest;
}

// 4. 提取 claude-code-hint 标签（零 token 侧信道）
const extracted = extractClaudeCodeHints(strippedStdout, input.command);
strippedStdout = extracted.stripped;

// 5. 图片检测与压缩
let isImage = isImageOutput(strippedStdout);
if (isImage) {
  const resized = await resizeShellImageOutput(strippedStdout, ...);
}
```

### 2. 结果映射

`mapToolResultToToolResultBlockParam()` 将结果映射为模型可读的格式，在 [`BashTool.tsx`](../../claude-code-source/src/tools/BashTool/BashTool.tsx#L555-L623) 中实现：

- **图片输出**：格式化为 image content block
- **大输出**：构建 `<persisted-output>` 消息，含预览片段和文件路径
- **中断命令**：追加 `<error>Command was aborted before completion</error>`
- **后台任务**：追加 backgroundInfo 说明任务 ID 和输出路径

### 3. 返回字段说明

最终返回的 `Out` 对象包含以下关键字段：

| 字段 | 类型 | 说明 |
| - | - | - |
| `stdout` | `string` | 命令标准输出（含合并的 stderr） |
| `stderr` | `string` | 通常是 cwd 重置提示信息 |
| `interrupted` | `boolean` | 是否被中断 |
| `isImage` | `boolean` | 输出是否为图片 |
| `backgroundTaskId` | `string` | 后台任务 ID（如有） |
| `backgroundedByUser` | `boolean` | 用户手动 Ctrl+B 后台化 |
| `assistantAutoBackgrounded` | `boolean` | assistant 模式自动后台化 |
| `returnCodeInterpretation` | `string` | 退出码的语义解读 |
| `noOutputExpected` | `boolean` | 是否为静默命令（mv/cp/rm 等） |
| `persistedOutputPath` | `string` | 大输出持久化路径 |
| `persistedOutputSize` | `number` | 持久化输出大小（字节） |

## 八、 sudo 与权限提升处理

### 1. sudo 的安全约束

`sudo`、`doas`、`pkexec` 在 [`bashPermissions.ts`](../../claude-code-source/src/tools/BashTool/bashPermissions.ts#L196-L226) 中被明确列入 `BARE_SHELL_PREFIXES` 黑名单：

```typescript
// claude-code-source/src/tools/BashTool/bashPermissions.ts
const BARE_SHELL_PREFIXES = new Set([
  'sh', 'bash', 'zsh', 'fish', 'csh', 'tcsh', 'ksh', 'dash',
  'cmd', 'powershell', 'pwsh',
  'env', 'xargs',
  'nice', 'stdbuf', 'nohup', 'timeout', 'time',
  // privilege escalation — sudo:* from `sudo -u foo ...` would auto-approve
  // any future sudo invocation
  'sudo', 'doas', 'pkexec',
]);
```

### 2. 禁止前缀规则生成

`BARE_SHELL_PREFIXES` 的作用是**阻止生成前缀通配规则**。当用户点击"以后不再询问"时，系统不会生成 `Bash(sudo:*)` 这样的规则，因为 `sudo:*` 会自动批准任何未来的 sudo 调用，等同于提权漏洞。每次 sudo 命令只能走精确匹配或每次询问。

### 3. sudo 执行的限制

Bash 工具的 `spawn` 是非交互式的，stdio 配置为 `['pipe', fd, fd]`，stdin 虽然是 pipe 但不会转发用户的键盘输入。因此：

- 若 sudo 配置了 **NOPASSWD**（免密）→ 可正常执行
- 若需要输入密码 → sudo 会因读不到密码而失败挂起或超时

### 4. 推荐做法

针对需要 sudo 的场景，有以下几种方案：

- 在 `/etc/sudoers` 中为特定命令配置 `NOPASSWD` 规则
- 使用 `echo 'password' | sudo -S command` 方式（但密码会出现在命令历史中，不推荐）
- 让用户在 Bash 工具之外手动执行需要 sudo 的命令，将结果告知模型
- 若 sudo 因沙箱限制失败，模型可设 `dangerouslyDisableSandbox: true` 重试（但该参数本身也会触发权限询问）

### 5. 沙箱与 sudo 的冲突

sudo 与沙箱互斥。沙箱通过文件系统白名单和网络主机白名单限制命令访问范围，而 sudo 命令通常需要访问系统级路径（如 `/etc/sudoers`）和执行特权操作，沙箱会阻止这些操作导致失败。

## 九、 系统提示词

### 1. 提示词生成

`getSimplePrompt()` 在 [`prompt.ts`](../../claude-code-source/src/tools/BashTool/prompt.ts#L275-L369) 中生成完整的系统提示词，包含以下核心内容：

- 工具描述：`Executes a given bash command and returns its output.`
- 工作目录持久化说明：cwd 在命令间持久化，但 shell 状态不持久化
- 工具偏好引导：优先使用 Glob/Grep/Read/Edit/Write 等专用工具
- 命令执行指引：超时配置、后台运行、多命令链式调用
- git 操作安全协议：禁止 `--no-verify`、禁止 force push、禁止 amend 等
- 沙箱限制说明（如启用）

### 2. 工具偏好引导

系统提示词明确引导模型优先使用专用工具而非 bash 命令，在 [`prompt.ts`](../../claude-code-source/src/tools/BashTool/prompt.ts#L280-L296) 中定义：

- 文件搜索 → 用 `Glob`，不用 `find` 或 `ls`
- 内容搜索 → 用 `Grep`，不用 `grep` 或 `rg`
- 读文件 → 用 `Read`，不用 `cat`/`head`/`tail`
- 编辑文件 → 用 `Edit`，不用 `sed`/`awk`
- 写文件 → 用 `Write`，不用 `echo >`/`cat <<EOF`
- 通信输出 → 直接输出文本，不用 `echo`/`printf`

### 3. 多命令执行指引

- 独立命令可并行：单条消息中发起多个 Bash 工具调用
- 依赖命令须串行：单次 Bash 调用中用 `&&` 链接
- 用 `;` 仅在不在乎前序命令失败时使用
- 禁止用换行符分隔命令（引号字符串内的换行除外）

---
*本文档由 markdowncli 技能辅助生成*

# Claude Code 源码还原 & 构建指南

> 从 npm 包的 source map 中还原 Claude Code 完整 TypeScript 源码，并从源码重新构建可运行的 CLI。

## 前置要求

- **[Bun](https://bun.sh/)** ≥ 1.0（构建工具 + 运行时）
- **Node.js** ≥ 18（运行构建产物）
- **pnpm**（包管理器，安装依赖用）

## 快速开始

### 1. 还原源码（从 npm 包提取）

```bash
# 1. 从 npm 下载包
npm pack @anthropic-ai/claude-code --registry https://registry.npmjs.org

# 2. 解压
tar xzf anthropic-ai-claude-code-2.1.88.tgz

# 3. 解析 cli.js.map，将 sourcesContent 按原始路径写出
node -e "
const fs = require('fs');
const path = require('path');
const map = JSON.parse(fs.readFileSync('package/cli.js.map', 'utf8'));
const outDir = './claude-code-source';
for (let i = 0; i < map.sources.length; i++) {
  const content = map.sourcesContent[i];
  if (!content) continue;
  let relPath = map.sources[i];
  while (relPath.startsWith('../')) relPath = relPath.slice(3);
  const outPath = path.join(outDir, relPath);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, content);
}
"
```

source map 中包含 **4756** 个源文件及其完整源码（`sourcesContent`），可以无损还原所有 TypeScript/TSX 原始代码。

### 2. 安装依赖

```bash
cd claude-code-source
pnpm install
```

### 3. 构建

```bash
pnpm build
# 等价于: bun run build.ts
```

构建成功后输出：
```
✓ Build succeeded
  Output: dist/cli.js
  Size: ~25MB
```

### 4. 运行

```bash
# 方式 A：通过 pnpm（推荐）
pnpm start

# 方式 B：直接用 Node 运行构建产物
node dist/cli.js

# 方式 C：开发模式（跳过构建，用 Bun 直接运行源码）
pnpm dev
# 等价于: bun src/entrypoints/cli.tsx

# 方式 D：全局链接后当命令使用
npm link
claude
```

> **注意**：运行前需要设置 `ANTHROPIC_API_KEY` 环境变量：
> ```bash
> export ANTHROPIC_API_KEY="sk-ant-..."
> ```

### 5. 使用 OpenAI 兼容 API（可选）

支持接入任何 OpenAI 兼容的 API 服务（如 vLLM、Ollama、LiteLLM、OpenRouter、DeepSeek、通义千问等）：

```bash
# 设置环境变量
export CLAUDE_CODE_USE_OPENAI=1
export OPENAI_API_KEY="sk-xxx"                          # 你的 API Key
export OPENAI_BASE_URL="https://api.deepseek.com/v1"    # API 基础 URL
export OPENAI_MODEL="deepseek-chat"                     # 模型名称

# 然后正常启动
pnpm start
```

#### 环境变量说明

| 环境变量 | 必填 | 说明 | 默认值 |
|---------|------|------|--------|
| `CLAUDE_CODE_USE_OPENAI` | ✅ | 设为 `1` 启用 OpenAI 兼容模式 | 无 |
| `OPENAI_API_KEY` | ✅ | API Key（部分本地服务可留空） | `""` |
| `OPENAI_BASE_URL` | ✅ | API 基础 URL，需要包含 `/v1` | `http://localhost:8000/v1` |
| `OPENAI_MODEL` | ⬜ | 模型名称，不设则回退到 `gpt-4o` | `gpt-4o` |

#### 常见服务配置示例

```bash
# DeepSeek
OPENAI_BASE_URL="https://api.deepseek.com/v1"
OPENAI_MODEL="deepseek-chat"

# OpenRouter
OPENAI_BASE_URL="https://openrouter.ai/api/v1"
OPENAI_MODEL="anthropic/claude-3.5-sonnet"

# Ollama (本地)
OPENAI_BASE_URL="http://localhost:11434/v1"
OPENAI_MODEL="qwen2.5:72b"

# vLLM (本地)
OPENAI_BASE_URL="http://localhost:8000/v1"
OPENAI_MODEL="Qwen/Qwen2.5-72B-Instruct"

# LiteLLM 代理
OPENAI_BASE_URL="http://localhost:4000/v1"
OPENAI_MODEL="gpt-4o"

# 通义千问
OPENAI_BASE_URL="https://dashscope.aliyuncs.com/compatible-mode/v1"
OPENAI_MODEL="qwen-max"
```

#### Docker 构建与运行

**构建镜像**：

```bash
# 在项目根目录执行（Dockerfile 位于根目录）
docker build -t claude-code .

# 多架构构建（amd64 + arm64）
docker buildx build --platform linux/amd64,linux/arm64 -t claude-code .
```

> Dockerfile 采用两阶段构建：Stage 1 使用 Bun 安装依赖 + 打包，Stage 2 使用 `node:22-slim` 作为精简运行时，并安装 `git`、`ca-certificates`、`curl` 等运行时依赖。

**使用 Anthropic API 运行**：

```bash
docker run -it --rm \
  -e ANTHROPIC_API_KEY="sk-ant-..." \
  -v $(pwd):/workspace \
  claude-code
```

**使用 OpenAI 兼容 API 运行**：

```bash
docker run -it --rm \
  -e CLAUDE_CODE_USE_OPENAI=1 \
  -e OPENAI_API_KEY="sk-xxx" \
  -e OPENAI_BASE_URL="https://api.deepseek.com/v1" \
  -e OPENAI_MODEL="deepseek-chat" \
  -v $(pwd):/workspace \
  claude-code
```

**连接本地服务（如 Ollama、vLLM）**：

```bash
# 使用 --network host 让容器访问宿主机的本地服务
docker run -it --rm \
  --network host \
  -e CLAUDE_CODE_USE_OPENAI=1 \
  -e OPENAI_API_KEY="" \
  -e OPENAI_BASE_URL="http://localhost:11434/v1" \
  -e OPENAI_MODEL="qwen2.5:72b" \
  -v $(pwd):/workspace \
  claude-code
```

#### CNB 平台自动构建

项目配置了 `.cnb.yml`，在 `dev` 分支推送时自动触发 Docker 多架构构建并推送到 CNB 镜像仓库：

```yaml
dev:
  push:
    - services:
        - name: docker
      stages:
        - name: docker build & push
          script: |
            docker buildx build --platform linux/amd64,linux/arm64 \
              -t ${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}:latest --push .
```

#### 工作原理

```
Anthropic SDK → fetch 拦截 → 协议转换 → OpenAI Chat Completions API
                                ↓
              请求: Anthropic Messages → OpenAI Chat Completions
              响应: OpenAI SSE Stream  → Anthropic SSE Stream
```

适配层在 HTTP fetch 层面做双向协议转换，上层代码完全无感知，继续使用 Anthropic SDK 的类型系统。

#### 已知限制

| 限制 | 说明 |
|------|------|
| 不支持 prompt caching | OpenAI API 无对应概念，cache 相关参数被忽略 |
| thinking 模式降级 | Anthropic 的 extended thinking 被转为普通输出 |
| beta features 不可用 | Anthropic 特有的 beta header 在此模式下自动跳过 |
| 图片支持取决于后端 | 需要后端 API 支持 vision（通过 base64 URL 传递） |

#### OpenAI 模式下自动禁用的功能

以下 Anthropic 特有功能在 OpenAI 兼容模式下会被自动禁用，不影响核心对话和编码体验：

| 功能 | 说明 |
|------|------|
| 遥测上报 (Analytics) | 不向 Anthropic 发送使用数据 |
| 错误报告 (Error Reporting) | 不向 Anthropic 发送错误日志 |
| 反馈命令 (`/feedback`) | 反馈通道仅适用于 Anthropic 服务 |
| API 预连接 | 跳过对 Anthropic API 的预连接 |
| 认证流程 | 跳过 Anthropic OAuth 认证，使用 `OPENAI_API_KEY` |

---

## 构建原理

构建脚本 `build.ts` 使用 **Bun bundler** 将 TypeScript 源码打包为单个 ESM 文件：

```
src/entrypoints/cli.tsx  →  Bun.build()  →  dist/cli.js (+ shebang)
```

### 构建流程详解

| 步骤 | 说明 |
|------|------|
| **入口** | `src/entrypoints/cli.tsx` |
| **目标** | Node.js（ESM 格式） |
| **产物** | `dist/cli.js`（带 `#!/usr/bin/env node` shebang，可直接执行） |
| **Source Map** | 同步生成 `dist/cli.js.map`（linked 模式） |
| **Minify** | 关闭（便于调试） |

### 三个构建插件

#### 1. `unavailable-package-stub` — 私有包打桩

将 8 个无法从公开 npm 获取的包替换为 stub 实现，使构建不依赖 Anthropic 内部 registry：

| 被 stub 的包 | 原始用途 |
|-------------|---------|
| `@anthropic-ai/sandbox-runtime` | OS 级沙箱隔离（macOS sandbox-exec / Linux bubblewrap） |
| `@anthropic-ai/mcpb` | DXT 插件验证与 MCP 服务器配置生成 |
| `@ant/claude-for-chrome-mcp` | Chrome 浏览器自动化 MCP（17 个浏览器工具） |
| `@anthropic-ai/bedrock-sdk` | AWS Bedrock 后端接入 |
| `@anthropic-ai/vertex-sdk` | Google Vertex AI 后端接入 |
| `@anthropic-ai/foundry-sdk` | Azure Foundry 后端接入 |
| `color-diff-napi` | 原生语法高亮 & diff 着色模块 |
| `modifiers-napi` | macOS 键盘修饰键检测（仅 Apple Terminal） |

#### 2. `bun-bundle-feature-shim` — Feature Flag 注入

拦截 `bun:bundle` 导入，将 `feature()` 函数替换为编译时常量。目前开启的 flag：

```
BUILTIN_EXPLORE_PLAN_AGENTS = true
COMPACTION_REMINDERS = true
MCP_SKILLS = true
TOKEN_BUDGET = true
```

其余 ~90 个 flag 均为 `false`。可在 `build.ts` 的 `featureFlags` 对象中按需开启。

#### 3. `text-file-loader` — 文本文件内联

将 `.md` 和 `.txt` 文件作为字符串导入，`.d.ts` 文件作为空模块处理。

### MACRO 编译时常量

通过 `define` 在构建时内联替换：

| 常量 | 值 |
|------|-----|
| `MACRO.VERSION` | `"2.1.88"` |
| `MACRO.BUILD_TIME` | 构建时的 ISO 时间戳 |
| `MACRO.ISSUES_EXPLAINER` | GitHub Issues 链接 |
| `MACRO.FEEDBACK_CHANNEL` | GitHub Issues 链接 |
| `MACRO.PACKAGE_URL` | npm 包地址 |

### External 依赖

以下包不打入 bundle，需运行时存在于 `node_modules` 中：

| 包 | 原因 |
|----|------|
| `sharp` / `@img/*` | 包含平台相关原生二进制（.node），无法打包 |
| `*.node` | 所有原生 N-API 模块文件 |

---

## 功能完整度

### ✅ 可用的核心功能

- CLI 启动（`--version`、`--help`、交互模式）
- Anthropic API 直连（标准 API Key 认证）
- 对话、工具调用、文件读写、代码搜索
- MCP 服务器连接（标准 stdio/SSE 方式）
- 所有内置命令（`/help`、`/clear`、`/compact` 等）
- Vim 模式、快捷键

### ❌ 因依赖 stub 不可用的功能

| 功能 | 缺失原因 | 影响程度 |
|------|---------|---------|
| 沙箱安全隔离 | `sandbox-runtime` 被 stub | 🔴 Bash 命令无沙箱保护 |
| DXT 插件系统 | `mcpb` 被 stub | 🔴 DXT 扩展无法加载 |
| Chrome 浏览器自动化 | `claude-for-chrome-mcp` 被 stub | 🔴 `/chrome` 命令不可用 |
| AWS Bedrock 后端 | `bedrock-sdk` 被 stub | 🟡 企业 AWS 用户不可用 |
| Google Vertex AI 后端 | `vertex-sdk` 被 stub | 🟡 GCP 用户不可用 |
| Azure Foundry 后端 | `foundry-sdk` 被 stub | 🟡 Azure 用户不可用 |
| 语法高亮着色 | `color-diff-napi` 被 stub | 🟡 diff 显示退化为纯文本 |
| Shift+Enter 检测 | `modifiers-napi` 被 stub | 🟢 仅 Apple Terminal 受影响 |
| 图片压缩 fallback | `sharp` 被 external | 🟢 极端场景下图片压缩失败 |

> **总结**：使用标准 Anthropic API Key 的个人用户，核心对话和编码功能完全可用。

---

## 目录结构

```
claude-code-source/
├── build.ts              # 构建脚本（Bun bundler 配置）
├── package.json          # 项目配置 & npm scripts
├── tsconfig.json         # TypeScript 配置
├── pnpm-lock.yaml        # 依赖锁定文件
├── dist/                 # 构建产物（构建后生成）
│   ├── cli.js            # 打包后的可执行文件
│   └── cli.js.map        # Source Map
├── src/                  # 核心源码（1902 个文件）
│   ├── entrypoints/      # 各类入口点（CLI、Server、Bridge 等）
│   ├── main.tsx          # 应用主入口
│   ├── Tool.ts           # 工具基类
│   ├── Task.ts           # 任务管理
│   ├── QueryEngine.ts    # 查询引擎
│   ├── commands.ts       # 命令注册
│   ├── tools.ts          # 工具注册
│   ├── assistant/        # 会话历史管理
│   ├── bootstrap/        # 启动初始化
│   ├── bridge/           # 桥接层 — IDE 扩展与 CLI 通信（31）
│   ├── buddy/            # 子代理系统（6）
│   ├── cli/              # CLI 参数解析与入口（19）
│   ├── commands/         # 斜杠命令实现（207）
│   ├── components/       # 终端 UI 组件，基于 Ink（389）
│   ├── constants/        # 共享常量（21）
│   ├── context/          # 上下文管理（9）
│   ├── coordinator/      # Agent 协调器（1）
│   ├── hooks/            # 生命周期钩子（104）
│   ├── ink/              # 自定义 Ink 终端渲染引擎（96）
│   ├── keybindings/      # 快捷键管理（14）
│   ├── memdir/           # 记忆目录系统（8）
│   ├── migrations/       # 数据迁移（11）
│   ├── plugins/          # 插件系统（2）
│   ├── query/            # 查询处理（4）
│   ├── remote/           # 远程执行（4）
│   ├── schemas/          # 数据模式定义（1）
│   ├── screens/          # 屏幕视图（3）
│   ├── server/           # Server 模式（3）
│   ├── services/         # 核心服务 — API、认证、配置、会话（130）
│   ├── skills/           # 技能系统（20）
│   ├── state/            # 状态管理（6）
│   ├── tasks/            # 任务执行（12）
│   ├── tools/            # Agent 工具 — Read、Write、Edit、Bash 等（184）
│   ├── types/            # TypeScript 类型定义（11）
│   ├── utils/            # 工具函数集（564）
│   ├── vim/              # Vim 模式（5）
│   └── voice/            # 语音输入（1）
├── vendor/               # 内部 vendor 代码
│   ├── modifiers-napi-src/   # 按键修饰符原生模块
│   ├── url-handler-src/      # URL 处理
│   ├── audio-capture-src/    # 音频采集
│   └── image-processor-src/  # 图片处理
└── node_modules/         # 第三方依赖（2850 个文件）
```

## 核心模块说明

| 模块 | 文件数 | 说明 |
|------|--------|------|
| `utils/` | 564 | 工具函数集 — 文件 I/O、Git 操作、权限检查、Diff 处理等 |
| `components/` | 389 | 终端 UI 组件，基于 Ink（React 的 CLI 版本）构建 |
| `commands/` | 207 | 斜杠命令实现，如 `/commit`、`/review` 等 |
| `tools/` | 184 | Agent 工具实现 — Read、Write、Edit、Bash、Glob、Grep 等 |
| `services/` | 130 | 核心服务 — API 客户端、认证、配置、会话管理等 |
| `hooks/` | 104 | 生命周期钩子 — 工具执行前后的拦截与权限控制 |
| `ink/` | 96 | 自研 Ink 渲染引擎，包含布局、焦点管理、渲染优化 |
| `bridge/` | 31 | 桥接层 — IDE 扩展与 CLI 之间的通信 |
| `skills/` | 20 | 技能加载与执行系统 |
| `cli/` | 19 | CLI 参数解析与启动逻辑 |
| `keybindings/` | 14 | 键盘快捷键绑定与自定义 |
| `tasks/` | 12 | 后台任务与定时任务管理 |

## npm scripts

| 命令 | 说明 |
|------|------|
| `pnpm build` | 用 Bun 构建，输出 `dist/cli.js` |
| `pnpm start` | 运行构建产物 `dist/cli.js` |
| `pnpm dev` | 开发模式，Bun 直接运行源码（无需构建） |

## 统计

| 指标 | 数值 |
|------|------|
| 源文件总数 | 4,756 |
| 核心源码（src/ + vendor/） | 1,906 个文件 |
| 第三方依赖（node_modules/） | 2,850 个文件 |
| Source Map 大小 | 57 MB |
| 包版本 | 2.1.88 |
| 构建产物大小 | ~25 MB |
| 被 stub 的私有包 | 8 个 |
| Feature Flags | ~94 个（4 个默认开启） |

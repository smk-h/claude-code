# ============================================================
# Stage 1: Build — 使用 Bun 安装依赖 + 打包
# ============================================================
FROM oven/bun:1 AS builder

WORKDIR /app

# 1. 先复制依赖清单，利用 Docker 缓存层
COPY claude-code-source/package.json claude-code-source/pnpm-lock.yaml ./

# 2. 用 bun 安装依赖（兼容 pnpm lockfile，速度更快）
RUN bun install --frozen-lockfile

# 3. 复制源码和构建脚本
COPY claude-code-source/src/ ./src/
COPY claude-code-source/vendor/ ./vendor/
COPY claude-code-source/build.ts claude-code-source/tsconfig.json ./

# 4. 执行构建
RUN bun run build.ts

# ============================================================
# Stage 2: Skills Builder — 安装 CNB Skills
# ============================================================
FROM node:22-slim AS skills-builder

WORKDIR /app

# 安装 git（skills add 需要 clone 远程仓库）
RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# 复制 Skills 配置和安装脚本
COPY skills-lock.json ./
COPY scripts/ ./scripts/

# 安装 skills CLI 工具并执行安装
RUN npm install -g skills && \
    npm cache clean --force && \
    sh scripts/add-skills.sh

# ============================================================
# Stage 3: Runtime — 精简的 Node.js 运行环境
# ============================================================
FROM node:22-slim AS runtime

WORKDIR /app

# 安装运行时系统依赖（git 是 claude-code 核心依赖）
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        jq \
    && rm -rf /var/lib/apt/lists/*

# 从 builder 复制构建产物
COPY --from=builder /app/dist/cli.js /app/dist/cli.js
COPY --from=builder /app/dist/cli.js.map /app/dist/cli.js.map

# 从 builder 复制 node_modules（运行时 external 依赖如 sharp 需要）
COPY --from=builder /app/node_modules /app/node_modules

# 复制 package.json（Node.js ESM 需要 "type": "module"）
COPY claude-code-source/package.json ./

# 让 cli.js 可执行
RUN chmod +x /app/dist/cli.js

# 从 skills-builder 复制 CNB Skills 到用户配置目录
COPY --from=skills-builder /app/.codebuddy/ /root/.codebuddy/

# 配置 Claude Code 使用 .codebuddy 作为配置目录（Skills 从此处加载）
ENV CLAUDE_CONFIG_HOME=/root/.codebuddy

# 配置用户级设置：信任工作目录
RUN mkdir -p /root/.codebuddy && \
    echo '{"trustedDirectories":["/workspace","/repo"]}' > /root/.codebuddy/settings.json

# 安装运行时工具
# - skills: NPC 运行时动态安装 Skill
# - @cnbcool/cnb-cli: CNB API 快捷命令（cnb issues get, cnb pulls list-files 等）
RUN npm install -g skills @cnbcool/cnb-cli && npm cache clean --force

# 复制入口包装脚本（自动检测 NPC 模式 vs 普通 CLI 模式）
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# 设置环境变量
ENV NODE_ENV=production
# 用户需要在运行时传入 API Key:
#   docker run -e ANTHROPIC_API_KEY="sk-ant-..." claude-code
ENV ANTHROPIC_API_KEY=""

# 工作目录挂载点（用户项目目录）
VOLUME ["/workspace"]
WORKDIR /workspace

ENTRYPOINT ["/app/entrypoint.sh"]

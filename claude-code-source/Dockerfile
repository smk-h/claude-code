# ============================================================
# Stage 1: Build — 使用 Bun 安装依赖 + 打包
# ============================================================
FROM oven/bun:1 AS builder

WORKDIR /app

# 1. 先复制依赖清单，利用 Docker 缓存层
COPY package.json pnpm-lock.yaml ./

# 2. 用 bun 安装依赖（兼容 pnpm lockfile，速度更快）
RUN bun install --frozen-lockfile

# 3. 复制源码和构建脚本
COPY src/ ./src/
COPY vendor/ ./vendor/
COPY build.ts tsconfig.json ./

# 4. 执行构建
RUN bun run build.ts

# ============================================================
# Stage 2: Runtime — 精简的 Node.js 运行环境
# ============================================================
FROM node:22-slim AS runtime

WORKDIR /app

# 安装运行时可能需要的工具（git 是 claude-code 核心依赖）
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# 从 builder 复制构建产物
COPY --from=builder /app/dist/cli.js /app/dist/cli.js
COPY --from=builder /app/dist/cli.js.map /app/dist/cli.js.map

# 从 builder 复制 node_modules（运行时 external 依赖如 sharp 需要）
COPY --from=builder /app/node_modules /app/node_modules

# 复制 package.json（Node.js ESM 需要 "type": "module"）
COPY package.json ./

# 让 cli.js 可执行
RUN chmod +x /app/dist/cli.js

# 设置环境变量
ENV NODE_ENV=production
# 用户需要在运行时传入 API Key:
#   docker run -e ANTHROPIC_API_KEY="sk-ant-..." claude-code
ENV ANTHROPIC_API_KEY=""

# 工作目录挂载点（用户项目目录）
VOLUME ["/workspace"]
WORKDIR /workspace

ENTRYPOINT ["node", "/app/dist/cli.js"]

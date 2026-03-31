# ============================================
# Stage 1: Build
# ============================================
FROM oven/bun:1 AS builder

# Install pnpm
RUN corepack enable && corepack prepare pnpm@latest --activate

WORKDIR /app

# Copy source code
COPY claude-code-source/package.json claude-code-source/pnpm-lock.yaml ./
COPY claude-code-source/src/ ./src/
COPY claude-code-source/vendor/ ./vendor/
COPY claude-code-source/build.ts ./build.ts
COPY claude-code-source/tsconfig.json ./tsconfig.json

# Install dependencies
RUN pnpm install --frozen-lockfile --registry https://registry.npmjs.org

# Apply commander compatibility patch
# commander v14 only allows single-char short options by default,
# but the source code uses multi-char short options like '-d2e'.
# Patch the regex from /^-[^-]$/ to /^-[^-]+$/
RUN sed -i 's|/\\^-\\[\\^-\\]\\$/|/^-[^-]+$/|' node_modules/commander/lib/option.js

# Build
RUN bun run build.ts

# ============================================
# Stage 2: Runtime
# ============================================
FROM node:20-slim AS runtime

WORKDIR /app

# Install sharp as optional runtime dependency (marked external in build.ts)
RUN npm install --no-save sharp@latest

# Copy build output from builder
COPY --from=builder /app/dist/cli.js ./dist/cli.js

# Set environment variables
ENV NODE_NO_WARNINGS=1

ENTRYPOINT ["node", "dist/cli.js"]

#!/bin/bash
# ============================================================
# AI 接口预检脚本
# 在 Claude Code 启动前检查 CNB AI 接口的可用性
# 使用与源码 CLI (getCnbAiBaseUrl) 一致的路径判断逻辑
# ============================================================
set -euo pipefail

echo "============================================"
echo "  AI 接口预检 (Pre-check)"
echo "============================================"

# ---- 1. 读取环境变量 ----
CNB_API_ENDPOINT="${CNB_API_ENDPOINT:-https://api.cnb.cool}"
CNB_REPO_SLUG="${CNB_REPO_SLUG:-}"
AI_MODEL="${CNB_AI_MODEL:-${ai_model:-glm-5.0}}"
API_KEY="${CNB_TOKEN:-}"
CNB_TOKEN_PREVIEW="${API_KEY:+${API_KEY:0:4}...}"

# ---- 2. 使用与源码 CLI 一致的路径逻辑 ----
# 源码 providers.ts getCnbAiBaseUrl():
#   ACC_PRODUCT_CONFIG_V2 存在 → /{slug}/-/ai-ide/v2/
#   否则                       → /{slug}/-/ai/
if [ -n "${ACC_PRODUCT_CONFIG_V2:-}" ]; then
  AI_BASE_PATH="/ai-ide/v2"
else
  AI_BASE_PATH="/ai"
fi

if [ -n "$CNB_REPO_SLUG" ]; then
  AI_BASE_URL="${CNB_API_ENDPOINT}/${CNB_REPO_SLUG}/-${AI_BASE_PATH}"
  FULL_API_URL="${AI_BASE_URL}/chat/completions"
else
  AI_BASE_URL="${CNB_API_ENDPOINT}/-/ai"
  FULL_API_URL="${AI_BASE_URL}/chat/completions"
fi

echo ""
echo "[预检] 接口地址配置:"
echo "  CNB_API_ENDPOINT       : ${CNB_API_ENDPOINT}"
echo "  CNB_REPO_SLUG          : ${CNB_REPO_SLUG}"
echo "  ACC_PRODUCT_CONFIG_V2  : ${ACC_PRODUCT_CONFIG_V2:-[未设置]}"
echo "  AI 路径                : ${AI_BASE_PATH}"
echo "  完整 API URL           : ${FULL_API_URL}"

# ---- 3. 输出模型配置 ----
echo ""
echo "[预检] 模型配置:"
echo "  ai_model               : ${AI_MODEL}"

# ---- 4. 检查 API Key ----
echo ""
echo "[预检] 认证信息:"
if [ -n "$API_KEY" ]; then
  echo "  CNB_TOKEN              : ${CNB_TOKEN_PREVIEW} (已配置)"
else
  echo "  CNB_TOKEN              : [未配置] ⚠️"
fi

# ---- 5. API 连通性预检（实际调用 chat/completions，stream 模式）----
echo ""
echo "[预检] 连通性测试 (POST ${FULL_API_URL}):"

if [ -n "$API_KEY" ] && [ -n "$CNB_REPO_SLUG" ]; then
  # 使用 stream: true（CNB API 仅支持流式请求）
  # 只检查 HTTP 状态码，丢弃响应 body（流式响应会持续输出）
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    --max-time 5 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/vnd.cnb.api+json" \
    -H "Authorization: ${API_KEY}" \
    -d "{\"model\":\"${AI_MODEL}\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
    "${FULL_API_URL}" 2>/dev/null || echo "000")

  if [ "$HTTP_CODE" = "200" ]; then
    echo "  API 预检               : ✅ 正常 (HTTP ${HTTP_CODE})"
  elif [ "$HTTP_CODE" = "000" ]; then
    echo "  API 预检               : ❌ 连接失败 (超时或网络不可达)"
  else
    echo "  API 预检               : ⚠️ 异常 (HTTP ${HTTP_CODE})"
  fi
else
  echo "  API 预检               : ⏭️ 跳过 (缺少 CNB_TOKEN 或 CNB_REPO_SLUG)"
fi

# ---- 6. CLAUDE_CODE_USE_CNB 状态 ----
echo ""
echo "[预检] Claude Code CNB 模式:"
if [ -n "${CLAUDE_CODE_USE_CNB:-}" ]; then
  echo "  CLAUDE_CODE_USE_CNB    : ${CLAUDE_CODE_USE_CNB} (已启用)"
else
  if [ -n "$CNB_API_ENDPOINT" ] && [ -n "$CNB_REPO_SLUG" ]; then
    echo "  CLAUDE_CODE_USE_CNB    : 将由 entrypoint.sh 自动设置为 1"
  else
    echo "  CLAUDE_CODE_USE_CNB    : [未启用] ⚠️ CNB_API_ENDPOINT 或 CNB_REPO_SLUG 缺失"
  fi
fi

echo ""
echo "============================================"
echo "  预检完成"
echo "============================================"

#!/bin/bash
# ============================================================
# AI 接口预检脚本
# 在 Claude Code 启动前检查 CNB AI 接口的可用性
# 输出接口地址、模型配置，并测试连通性
# ============================================================
set -euo pipefail

echo "============================================"
echo "  AI 接口预检 (Pre-check)"
echo "============================================"

# ---- 1. 读取环境变量 ----
CNB_API_ENDPOINT="${CNB_API_ENDPOINT:-https://api.cnb.cool}"
CNB_REPO_SLUG="${CNB_REPO_SLUG:-}"
AI_MODEL="${ai_model:-glm-5.0}"
BASE_URL_PATH="${base_url_path:-/ai}"
API_KEY="${CNB_TOKEN_FOR_CODEBUDDY:-${CNB_TOKEN_FOR_AI:-${CNB_TOKEN:-}}}"
CNB_TOKEN_PREVIEW="${CNB_TOKEN:+${CNB_TOKEN:0:4}...}"

# ---- 2. 输出接口地址 ----
if [ -n "$CNB_REPO_SLUG" ]; then
  FULL_API_URL="${CNB_API_ENDPOINT}/${CNB_REPO_SLUG}/-${BASE_URL_PATH}/chat/completions"
else
  FULL_API_URL="${CNB_API_ENDPOINT}/-/ai/chat/completions"
fi

echo ""
echo "[预检] 接口地址配置:"
echo "  CNB_API_ENDPOINT : ${CNB_API_ENDPOINT}"
echo "  CNB_REPO_SLUG    : ${CNB_REPO_SLUG}"
echo "  base_url_path    : ${BASE_URL_PATH}"
echo "  完整 API URL     : ${FULL_API_URL}"

# ---- 3. 输出模型配置 ----
echo ""
echo "[预检] 模型配置:"
echo "  ai_model         : ${AI_MODEL}"

# ---- 4. 检查 API Key ----
echo ""
echo "[预检] 认证信息:"
if [ -n "$CNB_TOKEN" ]; then
  echo "  CNB_TOKEN        : ${CNB_TOKEN_PREVIEW} (已配置)"
else
  echo "  CNB_TOKEN        : [未配置] ⚠️"
fi

# ---- 5. 健康检查 ----
echo ""
echo "[预检] 连通性测试:"
HEALTH_URL="${CNB_API_ENDPOINT}/-/health"

if [ -n "$API_KEY" ]; then
  HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' \
    --max-time 10 \
    -H "Authorization: Bearer ${API_KEY}" \
    "${HEALTH_URL}" 2>/dev/null || echo "000")
else
  HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' \
    --max-time 10 \
    "${HEALTH_URL}" 2>/dev/null || echo "000")
fi

if [ "$HTTP_CODE" = "200" ]; then
  echo "  CNB 健康检查     : ✅ 正常 (HTTP ${HTTP_CODE})"
elif [ "$HTTP_CODE" = "000" ]; then
  echo "  CNB 健康检查     : ❌ 连接失败 (超时或网络不可达)"
else
  echo "  CNB 健康检查     : ⚠️ 异常 (HTTP ${HTTP_CODE})"
fi

# ---- 6. CLAUDE_CODE_USE_CNB 状态 ----
echo ""
echo "[预检] Claude Code CNB 模式:"
if [ -n "${CLAUDE_CODE_USE_CNB:-}" ]; then
  echo "  CLAUDE_CODE_USE_CNB : ${CLAUDE_CODE_USE_CNB} (已启用)"
else
  if [ -n "$CNB_API_ENDPOINT" ] && [ -n "$CNB_REPO_SLUG" ]; then
    echo "  CLAUDE_CODE_USE_CNB : 将由 entrypoint.sh 自动设置为 1"
  else
    echo "  CLAUDE_CODE_USE_CNB : [未启用] ⚠️ CNB_API_ENDPOINT 或 CNB_REPO_SLUG 缺失"
  fi
fi

echo ""
echo "============================================"
echo "  预检完成"
echo "============================================"

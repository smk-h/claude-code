#!/bin/bash
set -euo pipefail

# ============================================================
# Claude Code 入口包装脚本
#
# 自动检测运行模式：
# - NPC 模式（CNB 平台触发）→ 构建 CLAUDE.md + 非交互执行
# - 普通 CLI 模式 → 启动交互式终端
# ============================================================

# NPC 环境变量检测（多个来源，兼容不同触发方式）
NPC_TRIGGER="${CNB_NPC_TRIGGER_CONTENT:-${CNB_COMMENT_BODY:-${CNB_COMMENT:-}}}"

if [ -n "$NPC_TRIGGER" ]; then
  # ========================================================
  # NPC 模式：处理 CNB 平台触发的事件
  # ========================================================

  # 读取 CNB 环境变量
  REPO_SLUG="${CNB_REPO_SLUG:-}"
  BRANCH="${CNB_BRANCH:-}"
  ISSUE_IID="${CNB_ISSUE_IID:-}"
  PR_IID="${CNB_PULL_REQUEST_IID:-}"
  BUILD_USER="${CNB_BUILD_USER:-}"
  BUILD_USER_NICKNAME="${CNB_BUILD_USER_NICKNAME:-}"
  NPC_SLUG="${CNB_BUILD_USER_NPC_SLUG:-}"
  NPC_NAME="${CNB_BUILD_USER_NPC_NAME:-}"
  WORKMODE="${CNB_NPC_ENABLE_WORKMODE:-false}"
  WEB_ENDPOINT="${CNB_WEB_ENDPOINT:-https://cnb.cool}"

  # CNB Token 优先级设置
  export CNB_TOKEN="${CNB_TOKEN_FOR_CODEBUDDY:-${CNB_TOKEN_FOR_AI:-${CNB_TOKEN:-}}}"

  # 判断资源类型
  if [ -n "$ISSUE_IID" ]; then
    RESOURCE="Issue"
    RESOURCE_IID="$ISSUE_IID"
    IS_ISSUE=true
  else
    RESOURCE="合并请求"
    RESOURCE_IID="${PR_IID:-unknown}"
    IS_ISSUE=false
  fi

  echo "[NPC] 仓库: ${REPO_SLUG}"
  echo "[NPC] 资源: ${RESOURCE} #${RESOURCE_IID}"
  echo "[NPC] 用户: ${BUILD_USER_NICKNAME:-${BUILD_USER}}"

  # 动态安装 NPC 专属 Skill（根据 CNB_NPC_SLUG）
  if [ -n "$NPC_SLUG" ]; then
    echo "[NPC] 安装 NPC Skill: ${NPC_SLUG}"
    npx skills add "${WEB_ENDPOINT}/${NPC_SLUG}.git" --agent codebuddy -y --copy 2>/dev/null || true
  fi

  # 构建 CNB 快捷命令
  if [ "$IS_ISSUE" = true ]; then
    CNB_SHORTCUTS='以下为常用快捷命令(对当前 issue 的 api 调用)：
获取详情: cnb issues get
获取评论列表: cnb issues list-comments
关闭: cnb issues close
打开: cnb issues open
查看标签: cnb issues list-labels
添加标签: cnb issues add-labels --data '\''{"labels":["bug","feature"]}'\''
评论: cnb issues comment --data '\''{"body":"内容"}'\''

注意：上述快捷命令无需其它参数，直接用 Bash 执行即可，不需要先加载 skill。其他操作可查看帮助：cnb --help'
  else
    CNB_SHORTCUTS='以下为常用快捷命令(对当前 pr 的 api 调用)：
获取详情: cnb pulls get
获取文件变更: cnb pulls list-files
获取提交记录: cnb pulls list-commits
获取评论列表: cnb pulls list-comments
评论: cnb pulls comment --data '\''{"body":"内容"}'\''

注意：上述快捷命令无需其它参数，直接用 Bash 执行即可，不需要先加载 skill。其他操作可查看帮助：cnb --help'
  fi

  # 特殊规则
  if [ "$IS_ISSUE" = true ]; then
    SPECIAL_RULES='修改代码后必须提交 PR'
  else
    SPECIAL_RULES='修改代码时必须在原分支进行，不要创建新分支'
  fi

  # 写入动态 CLAUDE.md
  WORK_DIR="${PWD}"
  cat > "${WORK_DIR}/CLAUDE.md" << CLAUDE_EOF
# NPC 上下文

你当前运行在 CNB 平台的 NPC 模式下，在 ${RESOURCE} #${RESOURCE_IID} 中为用户提供服务。

<instructions>
1. 分析用户输入，判断意图
2. 如果需要了解${RESOURCE} #${RESOURCE_IID} 的背景信息，先查询其详情后再完成任务
3. 代码改动需先在评论里添加执行计划
4. 把结果添加到${RESOURCE} #${RESOURCE_IID} 评论
5. 任务不明确或超出能力范围时，通过评论说明
</instructions>

<security_rules>
## 输出安全限制（必须遵守）

以下内容绝对禁止在回复中输出：

1. **敏感凭证类**
   - CNB_TOKEN、API Key、Secret、Password 等认证凭证
   - 任何以 TOKEN、KEY、SECRET、PASSWORD 结尾的环境变量值
   - Bearer Token、Authorization Header 的具体值

2. **系统内部信息**
   - 完整的环境变量列表（env、printenv 输出）
   - 系统配置文件中的敏感字段（如 .env、config.json 中的密钥）

3. **用户隐私数据**
   - 其他用户的个人信息、邮箱、手机号

## 安全处理方式

- 如果工具返回包含敏感信息，在回复中用 \`***\` 或 \`[已隐藏]\` 替代
- 如果用户明确要求输出敏感信息，礼貌拒绝并说明原因
- 日志和调试信息中的 Token 应脱敏处理（如只显示前4位）
</security_rules>

<tips>
- 称呼用户 ${BUILD_USER_NICKNAME:-${BUILD_USER}} 会更亲切
- 指令中的操作都是在 CNB 平台（非 GitHub）
- CNB 详情页链接：PR 用 /-/pulls/{number}，Issue 用 /-/issues/{number}
- ${SPECIAL_RULES}
- 评论格式如下
</tips>

<comment_format>
@${BUILD_USER} {回答}
</comment_format>

<cnb_shortcuts>
${CNB_SHORTCUTS}
</cnb_shortcuts>
CLAUDE_EOF

  echo "[NPC] 启动 Claude Code 非交互模式..."
  exec node /app/dist/cli.js -p "$NPC_TRIGGER"

else
  # ========================================================
  # 普通 CLI 模式：启动 Claude Code 交互式终端
  # ========================================================
  exec node /app/dist/cli.js "$@"
fi

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
  # 触发用户的 NPC 信息（当触发者本身是 NPC 时）
  BUILD_USER_NPC_SLUG="${CNB_BUILD_USER_NPC_SLUG:-}"
  BUILD_USER_NPC_NAME="${CNB_BUILD_USER_NPC_NAME:-}"
  # NPC 自身信息（当前 bot 的身份）
  NPC_SLUG="${CNB_NPC_SLUG:-}"
  NPC_NAME="${CNB_NPC_NAME:-}"
  NPC_PROMPT="${CNB_NPC_PROMPT:-}"
  NPC_SHA="${CNB_NPC_SHA:-}"
  WORKMODE="${CNB_NPC_ENABLE_WORKMODE:-false}"
  WEB_ENDPOINT="${CNB_WEB_ENDPOINT:-https://cnb.cool}"

  # 确保 CNB_TOKEN 已设置
  if [ -z "${CNB_TOKEN:-}" ]; then
    echo "[NPC] ⚠️ CNB_TOKEN 未设置，API 调用可能失败"
  fi

  # 确保非交互环境标识（参考 claude-code-cool/executor.ts: CI=true, TERM=dumb）
  export CI=true
  export TERM=dumb

  # CNB 模式下需要设置一个 dummy ANTHROPIC_API_KEY
  # 原因：CLI 在 CI=true 模式下会检查 ANTHROPIC_API_KEY（auth.ts:266-283），
  # 如果为空会直接抛错退出。实际 API 请求走 CNB 的 OpenAI adapter，不用此 key。
  export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-sk-cnb-dummy-key}"

  # 自动启用 CNB AI 平台接口（当 CNB_API_ENDPOINT 存在时）
  if [ -n "${CNB_API_ENDPOINT:-}" ] && [ -n "${CNB_REPO_SLUG:-}" ]; then
    export CLAUDE_CODE_USE_CNB=1
    echo "[NPC] 已启用 CNB AI 接口 (CNB_API_ENDPOINT=${CNB_API_ENDPOINT})"
    
    # ⚠️ 临时测试：强制启用激进模式，完全替换 system prompt（丢弃 CLAUDE.md）
    # 用于定位是否是 CLAUDE.md 中的内容触发了 glm-5.0 风控
    # 确认可用后，可移除此设置或改为条件判断
    export CNB_REPLACE_SYSTEM_PROMPT=1
    export CNB_DEBUG_SYSTEM_PROMPT=1
    echo "[NPC] ⚠️ 已强制启用激进模式 (CNB_REPLACE_SYSTEM_PROMPT=1)，将完全替换 system prompt"
  fi

  # ---- 自定义系统提示词覆盖 ----
  # 通过 CNB_CUSTOM_SYSTEM_PROMPT 环境变量可以覆盖 CLI 内置的系统提示词基础部分。
  # 在混合模式下（默认），仅替换 CLI 自带的复杂 prompt，CLAUDE.md 中的 NPC 指引仍会保留。
  # 设置 CNB_REPLACE_SYSTEM_PROMPT=1 则连 CLAUDE.md 也一并替换（不推荐）。
  #
  # 用法示例（在 .cnb.yml 的 env 中设置）：
  #   CNB_CUSTOM_SYSTEM_PROMPT: "你是一个专业的代码审查助手，请用中文回复。"
  #
  # 如果未设置，使用内置默认值：
  #   "You are a helpful coding assistant. Please respond in the same language as the user."
  if [ -n "${CNB_CUSTOM_SYSTEM_PROMPT:-}" ]; then
    export CNB_CUSTOM_SYSTEM_PROMPT
    echo "[NPC] 已设置自定义系统提示词 (${#CNB_CUSTOM_SYSTEM_PROMPT} 字符)"
  fi

  # AI 接口预检（输出接口地址、模型配置，测试连通性）
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -x "${SCRIPT_DIR}/scripts/precheck-ai.sh" ]; then
    bash "${SCRIPT_DIR}/scripts/precheck-ai.sh" || echo "[NPC] ⚠️ AI 预检脚本执行异常（不影响后续启动）"
  else
    echo "[NPC] ⚠️ 未找到预检脚本 scripts/precheck-ai.sh，跳过预检"
  fi

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

  # ---- 用户身份解析（区分 NPC 用户和普通用户）----
  if [ -n "$BUILD_USER_NPC_SLUG" ]; then
    USER_TYPE="NPC"
    USER_NAME="$BUILD_USER_NPC_SLUG"
    USER_NICK="$BUILD_USER_NPC_NAME"
  else
    USER_TYPE="用户"
    USER_NAME="$BUILD_USER"
    USER_NICK="$BUILD_USER_NICKNAME"
  fi

  # 用户 mention 格式
  if [ -n "$USER_NAME" ] && [ -n "$USER_NICK" ]; then
    USER_MENTION="@${USER_NAME}(${USER_NICK})"
  elif [ -n "$USER_NAME" ]; then
    USER_MENTION="@${USER_NAME}"
  else
    USER_MENTION="@${USER_NICK}"
  fi

  # ---- NPC 自身的评论作者格式 ----
  if [ -n "$NPC_SLUG" ] && [ -n "$NPC_NAME" ]; then
    COMMENT_AUTHOR="@${NPC_SLUG}(${NPC_NAME})"
  elif [ -n "$NPC_SLUG" ]; then
    COMMENT_AUTHOR="@${NPC_SLUG}"
  elif [ -n "$NPC_NAME" ]; then
    COMMENT_AUTHOR="@${NPC_NAME}"
  else
    COMMENT_AUTHOR="@${BUILD_USER}(${BUILD_USER_NICKNAME})"
  fi

  echo "[NPC] 仓库: ${REPO_SLUG}"
  echo "[NPC] 资源: ${RESOURCE} #${RESOURCE_IID}"
  echo "[NPC] ${USER_TYPE}: ${USER_NICK:-${USER_NAME}}"
  echo "[NPC] 评论身份: ${COMMENT_AUTHOR}"
  echo "[NPC] 工作模式: ${WORKMODE}"

  # ---- 相对链接转换函数 ----
  # 将 Markdown 中的相对路径图片/链接转为 CNB 绝对路径
  # 使用 node 实现（移植自 claude-code-cool 的 convertLink.ts），避免 sed 分隔符问题
  convert_links() {
    local text="$1"
    local endpoint="${2:-${WEB_ENDPOINT}}"
    local slug="${3:-${REPO_SLUG}}"
    local ref="${4:-${BRANCH:-HEAD}}"

    if [ -z "$endpoint" ] || [ -z "$slug" ]; then
      echo "$text"
      return
    fi

    node -e '
      const text = process.argv[1];
      const endpoint = process.argv[2];
      const slug = process.argv[3];
      const ref = process.argv[4] || "HEAD";
      const baseURL = endpoint + "/" + slug;

      function normaliseLink(link) {
        if (link.startsWith("/-/")) return baseURL + link;
        if (link.indexOf("/-/") === -1 &&
            (link.startsWith("../") || link.startsWith("./") ||
             (link.startsWith("/") && !link.startsWith("//")))) {
          let chunks = link.split("/").filter(c => c && c !== "." && c !== "..");
          if (chunks.length === 0) return link;
          chunks.unshift(ref);
          return baseURL + "/-/git/raw/" + chunks.join("/");
        }
        return link;
      }

      // 查找代码块和行内代码的位置，排除这些区域
      let codeBlocks = [];
      let idx = 0;
      while (idx < text.length) {
        let next = text.indexOf("```", idx);
        if (next === -1) break;
        codeBlocks.push(next);
        idx = next + 3;
      }
      if (codeBlocks.length % 2 !== 0) codeBlocks.pop();

      let inlineCode = [];
      idx = 0;
      while (idx < text.length) {
        let next = text.indexOf("`", idx);
        if (next === -1) break;
        if ((next === 0 || text[next-1] !== "`") && (next === text.length-1 || text[next+1] !== "`")) {
          inlineCode.push(next);
        }
        idx = next + 1;
      }
      if (inlineCode.length % 2 !== 0) inlineCode.pop();

      const excluded = [...codeBlocks, ...inlineCode].reduce((r, v, i) => {
        if (i % 2 === 0) r.push([v]); else r[r.length-1].push(v);
        return r;
      }, []);
      const isExcluded = (pos) => excluded.some(([s,e]) => pos >= s && pos < e);

      let replacements = [];
      // Markdown links: [text](url) and ![alt](url)
      const mdRe = /!?\[([^\]]+)\]\(([^)]+)\)/g;
      let m;
      while ((m = mdRe.exec(text)) !== null) {
        if (!isExcluded(m.index)) {
          const pfx = (m[0].startsWith("!") ? 1 : 0) + 1 + m[1].length + 2;
          const s = m.index + pfx, e = s + m[2].length;
          const n = normaliseLink(m[2]);
          if (n !== m[2]) replacements.push({s, e, n});
        }
      }
      // HTML tags: src="..." href="..."
      const htmlRe = /\s(src|href)=["\x27]([^"\x27]+)["\x27]/gi;
      while ((m = htmlRe.exec(text)) !== null) {
        if (!isExcluded(m.index)) {
          const s = m.index + m[0].indexOf(m[2]), e = s + m[2].length;
          const n = normaliseLink(m[2]);
          if (n !== m[2]) replacements.push({s, e, n});
        }
      }

      replacements.sort((a,b) => b.s - a.s);
      let result = text;
      for (const {s, e, n} of replacements) {
        result = result.substring(0, s) + n + result.substring(e);
      }
      process.stdout.write(result);
    ' "$text" "$endpoint" "$slug" "$ref"
  }

  # ---- 转换 NPC_TRIGGER 中的相对链接 ----
  NPC_TRIGGER=$(convert_links "$NPC_TRIGGER")

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

  # ---- NPC 角色设定 ----
  if [ -n "$NPC_PROMPT" ]; then
    # NPC Prompt 中的相对链接以 NPC 自身的 slug 和 sha 为基准（与 claude-code-cool 一致）
    NPC_PROMPT_CONVERTED=$(convert_links "$NPC_PROMPT" "$WEB_ENDPOINT" "$NPC_SLUG" "$NPC_SHA")
    CHARACTER_SETTINGS="

角色设定如下

<character_settings>
${NPC_PROMPT_CONVERTED}
</character_settings>"
  else
    CHARACTER_SETTINGS=""
  fi

  # ---- 对话/工作模式指令 ----
  if [ "$WORKMODE" = "true" ]; then
    INSTRUCTIONS="1. 查询${RESOURCE} #${RESOURCE_IID} 详情（通过 CNB API）
2. 综合${RESOURCE}详情和${USER_TYPE}输入，判断意图并完成任务
3. 如果操作复杂，需要先拆分任务，再按照任务之间的依赖关系依次执行
4. 代码改动需先在评论里添加执行计划
5. 如果需要 commit 代码，务必保持每条 commit 原子化，尽量使每条 commit 的改动在单一功能范围内
6. 如果需要创建子issue，在它的标题里添加issue编号\"#${RESOURCE_IID}\"进行关联
7. 如果需要创建合并请求，在它的描述里添加${RESOURCE}编号\"#${RESOURCE_IID}\"进行关联
8. 使用 post-comment 技能把结果通过 curl 发布到${RESOURCE} #${RESOURCE_IID} 评论
9. 任务不明确或超出能力范围时，也必须通过评论说明

约束：
- ${RESOURCE}详情必须通过 CNB API 获取，禁止用本地文件内容替代 API 返回结果
- 如果 API 调用失败，应检查请求格式后重试，而不是放弃转去读取本地文件"
  else
    INSTRUCTIONS="1. 查询${RESOURCE} #${RESOURCE_IID} 详情（通过 CNB API）
2. 综合${RESOURCE}详情和${USER_TYPE}输入，判断意图
3. 自主选择合适的工具完成任务
4. 使用 post-comment 技能把回复通过 curl 发布到${RESOURCE} #${RESOURCE_IID} 评论
5. 任务不明确或超出能力范围时，也必须通过评论说明

约束：
- ${RESOURCE}详情必须通过 CNB API 获取，禁止用本地文件内容替代 API 返回结果
- 如果 API 调用失败，应检查请求格式后重试，而不是放弃转去读取本地文件"
  fi

  # 写入动态 CLAUDE.md
  WORK_DIR="${PWD}"
  cat > "${WORK_DIR}/CLAUDE.md" << CLAUDE_EOF
<!-- CNB_APPEND_START -->
# NPC 上下文

你是 CNB 平台中仓库 ${REPO_SLUG} 的 AI 助手，角色是${NPC_NAME:-AI 助手}，在 ${RESOURCE} #${RESOURCE_IID} 中为${USER_TYPE}提供服务。${CHARACTER_SETTINGS}

请根据${USER_TYPE}输入，按照以下指引完成任务

<instructions>
${INSTRUCTIONS}
</instructions>

重要规则：
- 你必须通过发布评论来回复用户。你运行在 CLI 非交互模式下，文本输出不会被任何人看到。
- 使用 post-comment 技能（.claude/skills/post-comment/SKILL.md），通过 Bash 工具执行 curl 命令将评论发布到 ${RESOURCE} #${RESOURCE_IID}。
- 无论任务完成与否，最终步骤都必须是发布评论。
- 评论中使用 Markdown 格式。
- 直接执行 curl 命令即可，不要在命令前加 "bash" 前缀。
- 调用 CNB API 时，认证必须使用环境变量 \$CNB_TOKEN，仓库路径必须使用环境变量 \$CNB_REPO_SLUG。
- 在 Bash 工具中只能执行有效的 shell 命令（如 curl、cat、git、cnb 等）。
- 合理分配 turns：预留至少 2 个 turns 用于发布评论。
- 禁止在回复中输出任何凭证信息或完整环境变量列表。

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
- 称呼${USER_TYPE} ${USER_NICK:-${USER_NAME}} 会更亲切
- 指令中的操作都是在 CNB 平台（非 GitHub）
- CNB 详情页链接：PR 用 /-/pulls/{number}，Issue 用 /-/issues/{number}（不是 merge_request）
- Skill 技能使用：编写/修改/优化/重构代码等代码变动用 auto-code，代码评审用 code-review，PR 总结用 pr-summary，获取 PR 变更用 pr-diff，CNB 平台的 API 调用使用 cnb-skill，读取 Issue/PR 中的相对路径用 cnb-text-relative-path-converter
- ${SPECIAL_RULES}
</tips>

<comment_format>
${COMMENT_AUTHOR} {回答}
</comment_format>

<cnb_shortcuts>
${CNB_SHORTCUTS}
</cnb_shortcuts>
CLAUDE_EOF

  # ---- 构建 userPrompt（包裹用户输入 + 转换链接）----
  USER_PROMPT="${USER_TYPE} ${USER_NAME} 输入如下

<user_input>
${NPC_TRIGGER}
</user_input>"

  # ---- 构建 CLI 启动参数（参考 claude-code-cool/executor.ts）----
  # 参数说明：
  #   -p                            非交互模式（headless）
  #   --output-format stream-json   流式 JSON 输出（便于日志解析）
  #   --max-turns N                 最大对话轮次
  #   --verbose                     详细日志
  #   --append-system-prompt <text> 追加系统提示（CLAUDE.md 内容）
  #   --dangerously-skip-permissions 跳过权限确认对话框（关键！否则 CLI 卡住）
  MAX_TURNS="${MAX_TURNS:-20}"
  SYSTEM_PROMPT=$(cat "${WORK_DIR}/CLAUDE.md")

  echo "[NPC] 启动 Claude Code 非交互模式 (max_turns=${MAX_TURNS})..."

  # 降权运行：Claude Code CLI 禁止在 root 下使用 --dangerously-skip-permissions
  # 参考 claude-code-cool/start.sh 使用 gosu 降权到 claude 用户
  CLAUDE_USER="claude"
  chown -R "$CLAUDE_USER:$CLAUDE_USER" /workspace 2>/dev/null || true

  # 检查 node 和 cli.js 是否可用
  echo "[NPC] Node 版本: $(node --version)"
  echo "[NPC] CLI 路径: /app/dist/cli.js ($(stat -c%s /app/dist/cli.js 2>/dev/null || echo 'N/A') bytes)"
  echo "[NPC] 运行用户: $(gosu "$CLAUDE_USER" whoami 2>/dev/null || echo 'gosu failed')"
  echo "[NPC] CLAUDE_CODE_USE_CNB=${CLAUDE_CODE_USE_CNB:-}"
  echo "[NPC] OPENAI_BASE_URL=${OPENAI_BASE_URL:-[未设置，将由 CLI 自动设置]}"

  # 使用 exec 启动 CLI（stderr 和 stdout 都会输出到日志）
  exec gosu "$CLAUDE_USER" node /app/dist/cli.js \
    -p \
    --output-format stream-json \
    --max-turns "${MAX_TURNS}" \
    --verbose \
    --append-system-prompt "${SYSTEM_PROMPT}" \
    --dangerously-skip-permissions \
    "$USER_PROMPT"

else
  # ========================================================
  # 普通 CLI 模式：启动 Claude Code 交互式终端
  # ========================================================
  exec node /app/dist/cli.js "$@"
fi

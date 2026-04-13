#!/usr/bin/env bash
# guard-git-push.sh
# PreToolUse hook：动态守卫 git push，禁止任何形式 push 到 main / master 受保护分支
# 优于客户端 pattern 列表（pattern 永远挖不完 bypass）
#
# 输入：stdin JSON {"tool_name": "Bash", "tool_input": {"command": "..."}}
# 输出：
#   - 命中拦截 → JSON {"hookSpecificOutput": {"permissionDecision": "deny", ...}}
#   - 否则 → exit 0 不输出，走默认 allow/ask/deny 规则

set -eo pipefail

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // ""')

# 非 git push 直接放行（if 应该已过滤，但稳妥起见）
if ! echo "$command" | grep -qE -- '(^|[[:space:]&;|])git[[:space:]]+push'; then
    exit 0
fi

deny() {
    local hint="$1"
    jq -nc \
        --arg reason "禁止 push 到受保护分支：$hint" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    exit 0
}

# —— 模式 1：command 显式提到 main / master 作为目标 ——
explicit_main_patterns=(
    'origin[[:space:]]+main([[:space:]]|$)'
    'origin[[:space:]]+master([[:space:]]|$)'
    'origin[[:space:]]+\+?HEAD:main'
    'origin[[:space:]]+\+?HEAD:master'
    'origin[[:space:]]+\+?HEAD:refs/heads/main'
    'origin[[:space:]]+\+?HEAD:refs/heads/master'
    'origin[[:space:]]+\+?refs/heads/main'
    'origin[[:space:]]+\+?refs/heads/master'
    'origin[[:space:]]+\+main'
    'origin[[:space:]]+\+master'
    'origin[[:space:]]+:main([[:space:]]|$)'
    'origin[[:space:]]+:master([[:space:]]|$)'
    'origin[[:space:]]+:refs/heads/main'
    'origin[[:space:]]+:refs/heads/master'
    '[[:space:]]--delete[[:space:]]+main([[:space:]]|$)'
    '[[:space:]]--delete[[:space:]]+master([[:space:]]|$)'
    '[[:space:]]-d[[:space:]]+main([[:space:]]|$)'
    '[[:space:]]-d[[:space:]]+master([[:space:]]|$)'
    '[[:space:]]--mirror([[:space:]]|$)'
    '[[:space:]]--all([[:space:]]|$)'
)

for pattern in "${explicit_main_patterns[@]}"; do
    if echo "$command" | grep -qE -- "$pattern"; then
        deny "command 显式以 main / master / 受保护引用为目标"
    fi
done

# —— 模式 2：当前分支 = main / master 时拦 bare push 与 push origin（无显式目标）——
# 这种情况下 push 默认推当前分支（即 main / master）
current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
    if echo "$command" | grep -qE -- '^[[:space:]]*git[[:space:]]+push[[:space:]]*$'; then
        deny "当前分支是 $current_branch（受保护）。bare git push 会推到上游 main/master。请先切到 feature 分支。"
    fi
    if echo "$command" | grep -qE -- '^[[:space:]]*git[[:space:]]+push[[:space:]]+origin[[:space:]]*(--[a-z-]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]*$'; then
        deny "当前分支是 $current_branch（受保护）。push origin 不带显式 refspec 会推当前分支。请先切到 feature 分支。"
    fi
    if echo "$command" | grep -qE -- '^[[:space:]]*git[[:space:]]+push[[:space:]]+(-u|--set-upstream)[[:space:]]+origin[[:space:]]+(main|master)([[:space:]]|$)'; then
        deny "试图 -u origin $current_branch 推受保护分支。"
    fi
fi

# 其它 git push（推 feature 分支等）放行
exit 0

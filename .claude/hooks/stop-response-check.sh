#!/usr/bin/env bash
# stop-response-check.sh
# Input: stdin JSON {"transcript_path": "/path/to/transcript.jsonl", ...}
# Reads last assistant message from transcript; validates Skill gate first line + completion claims.
# Output: Stop hook decision JSON {"decision":"block","reason":"..."} or exit 0 silent.
set -eo pipefail

input=$(cat)
tpath=$(echo "$input" | jq -r '.transcript_path // ""')
[ -z "$tpath" ] && exit 0
[ ! -f "$tpath" ] && exit 0

# Extract last assistant text message from JSONL transcript
last_text=$(python3 - "$tpath" <<'PY'
import json, sys
text = ""
try:
    with open(sys.argv[1]) as f:
        for line in f:
            try:
                d = json.loads(line)
                if d.get('type') == 'assistant':
                    content = d.get('message', {}).get('content', [])
                    if isinstance(content, list):
                        for c in content:
                            if isinstance(c, dict) and c.get('type') == 'text':
                                text = c.get('text', '')
                    elif isinstance(content, str):
                        text = content
            except Exception:
                continue
except Exception:
    pass
print(text)
PY
)

[ -z "$last_text" ] && exit 0

first_line=$(echo "$last_text" | head -1)

block() {
  local reason="$1"
  jq -nc --arg r "$reason" '{decision: "block", reason: $r}'
  exit 0
}

# 1) First-line Skill gate syntax
if ! echo "$first_line" | grep -qE '^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|frontend-design:[a-z-]+|exempt\([a-z-]+\))'; then
  block "首行缺 'Skill gate: <name>' 或 'Skill gate: exempt(<reason>)'; 实际首行: $first_line"
fi

# 2) Exempt reason whitelist
if echo "$first_line" | grep -qE '^Skill gate: exempt\('; then
  reason=$(echo "$first_line" | sed -E 's/^Skill gate: exempt\(([^)]+)\).*/\1/')
  RULES=".claude/workflow-rules.json"
  if [ -f "$RULES" ]; then
    wl=$(python3 -c "import json; print(' '.join(json.load(open('$RULES'))['skill_gate_policy']['exempt_reason_whitelist']))" 2>/dev/null || echo "")
    ok=false
    for w in $wl; do [ "$reason" = "$w" ] && ok=true && break; done
    $ok || block "exempt 理由 '$reason' 不在白名单: $wl"
  fi
fi

# 3) Completion claim warning (stderr only; not block)
if echo "$last_text" | grep -qE '(任务完成|已完成|全部完成|验证通过|测试通过|it works|all pass)' \
  && ! echo "$last_text" | grep -qE '(Bash|bash|pytest|xcodebuild|npm test|jest)'; then
  >&2 echo "[stop-hook WARN] 声明完成但未见验证命令输出"
fi

exit 0

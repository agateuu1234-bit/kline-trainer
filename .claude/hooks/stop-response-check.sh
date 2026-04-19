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

# 1) First-line Skill gate syntax (H2-1: drift-log instead of block)
if ! echo "$first_line" | grep -qE '^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|frontend-design:[a-z-]+|exempt\([a-z-]+\))'; then
  DRIFT_LOG=".claude/state/skill-gate-drift.jsonl"
  mkdir -p "$(dirname "$DRIFT_LOG")"
  # Infer last valid Skill gate from transcript (reverse scan most recent 20 assistant messages)
  inferred=$(python3 - "$tpath" <<'PY'
import json, re, sys
target = sys.argv[1]
gate_re = re.compile(r'^Skill gate:\s*(superpowers:[a-z-]+|codex:[a-z-]+|frontend-design:[a-z-]+|exempt\([a-z-]+\))')
recent = []
try:
    with open(target) as f:
        for line in f:
            try:
                d = json.loads(line)
                if d.get('type') == 'assistant':
                    content = d.get('message', {}).get('content', [])
                    if isinstance(content, list):
                        for c in content:
                            if isinstance(c, dict) and c.get('type') == 'text':
                                recent.append(c.get('text', ''))
                    elif isinstance(content, str):
                        recent.append(content)
            except Exception:
                continue
except Exception:
    pass
# Take last 20, reverse, find first whose first-line matches (skip current msg at index 0)
for text in list(reversed(recent))[1:21]:
    fl = text.splitlines()[0] if text.splitlines() else ''
    m = gate_re.match(fl)
    if m:
        print(m.group(1)); sys.exit(0)
print('exempt(behavior-neutral)')
PY
)
  response_sha=$(printf %s "$last_text" | shasum -a 256 | awk '{print $1}')
  # Append JSONL drift record
  python3 - "$DRIFT_LOG" "$first_line" "$inferred" "$response_sha" <<'PY'
import json, sys, time
p, first_line, inferred, sha = sys.argv[1:5]
entry = {
    "time_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "first_line": first_line,
    "inferred_skill": inferred,
    "response_sha": sha,
}
with open(p, "a") as f:
    f.write(json.dumps(entry) + "\n")
PY
  DRIFT_COUNT=$(wc -l < "$DRIFT_LOG" 2>/dev/null | tr -d ' ' || echo 0)
  echo "[skill-gate-drift] =================================" >&2
  echo "  Previous response MISSED first-line Skill gate." >&2
  echo "  First line was: $first_line" >&2
  echo "  Inferred skill (from transcript): $inferred" >&2
  echo "  Drift count (session log): $DRIFT_COUNT" >&2
  echo "  YOUR NEXT RESPONSE MUST START WITH:" >&2
  echo "    Skill gate: <skill-name>   OR   Skill gate: exempt(<whitelist-reason>)" >&2
  echo "  (drift recorded; not blocking; push will block at threshold via H3-2)" >&2
  echo "[skill-gate-drift] =================================" >&2
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

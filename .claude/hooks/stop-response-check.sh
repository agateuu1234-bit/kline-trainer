#!/usr/bin/env bash
# stop-response-check.sh
set -eo pipefail

# v49 R49 F1 HIGH fix: anchor to repo root so relative reads of
# .claude/workflow-rules.json / .claude/state/... work when the hook is
# launched from a subdirectory (via settings.json entry or CI).
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT" || true

# helper: validate exempt integrity entirely in Python (avoid shell IFS parsing bypass)
# Input: transcript path + exempt reason
# Output: prints "OK" on pass; prints "BLOCK: <reason>" on fail. Exit 0 always.
validate_exempt_integrity() {
  python3 - "$1" "$2" <<'PY'
import json, sys, re

tpath, reason = sys.argv[1], sys.argv[2]
entries = []
try:
    with open(tpath) as f:
        for line in f:
            try:
                d = json.loads(line)
                if d.get('type') in ('user', 'assistant'):
                    entries.append(d)
            except Exception:
                continue
except Exception as e:
    print(f"BLOCK: transcript parse error: {e}")
    sys.exit(0)

def is_human_user_entry(e):
    if e.get('type') != 'user':
        return False
    content = e.get('message', {}).get('content', '')
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        if any(isinstance(c, dict) and c.get('type') == 'tool_result' for c in content):
            return False
        return True
    return False

last_user_idx = -1
for i, e in enumerate(entries):
    if is_human_user_entry(e):
        last_user_idx = i

last_tool_uses = []
for e in entries[last_user_idx + 1:]:
    if e.get('type') == 'assistant':
        content = e.get('message', {}).get('content', [])
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get('type') == 'tool_use':
                    last_tool_uses.append(c)

last_user_text = ""
if last_user_idx >= 0:
    umsg = entries[last_user_idx].get('message', {})
    ucontent = umsg.get('content', '')
    if isinstance(ucontent, str):
        last_user_text = ucontent
    elif isinstance(ucontent, list):
        parts = []
        for c in ucontent:
            if isinstance(c, dict) and c.get('type') == 'text':
                parts.append(c.get('text', ''))
            elif isinstance(c, str):
                parts.append(c)
        last_user_text = '\n'.join(parts)

def get_cmd(tu): return tu.get('input', {}).get('command', '')
def get_path(tu): return tu.get('input', {}).get('file_path', '')

CONTROL_CHARS_RE = re.compile(r'[\r\n\t\x00]')

if reason == 'read-only-query':
    import shlex, os
    from pathlib import Path
    zero_path_re = re.compile(r'^(pwd|true|false)$|^echo +["\'"][^"\'"|<>;&`$()]*["\'"]$')
    file_read_tools = {'ls', 'cat', 'head', 'tail', 'wc'}
    sensitive_name_re = re.compile(
        r'(\.ssh|\.aws|\.gnupg|\.kube|credentials|secrets?|\.env(\..+)?|id_[rd]sa|\.pem|\.key|\.pgpass|\.netrc)$',
        re.IGNORECASE)
    for tu in last_tool_uses:
        name = tu.get('name', '')
        if name in ('Read', 'Grep', 'Glob'):
            continue
        if name == 'Bash':
            cmd = get_cmd(tu)
            if CONTROL_CHARS_RE.search(cmd):
                print(f"BLOCK: exempt(read-only-query) Bash 含控制字符: {cmd[:80]!r}"); sys.exit(0)
            if re.search(r'[|<>;&`$]', cmd) or '||' in cmd or '&&' in cmd:
                print(f"BLOCK: exempt(read-only-query) Bash 含管道/重定向/复合: {cmd[:80]}"); sys.exit(0)
            if zero_path_re.fullmatch(cmd):
                continue
            try:
                parts = shlex.split(cmd)
            except ValueError:
                print(f"BLOCK: exempt(read-only-query) Bash 解析失败: {cmd[:80]}"); sys.exit(0)
            if not parts or parts[0] not in file_read_tools:
                print(f"BLOCK: exempt(read-only-query) Bash 不在白名单: {cmd[:80]}"); sys.exit(0)
            args = parts[1:]
            if len(args) != 1:
                print(f"BLOCK: exempt(read-only-query) {parts[0]} 需恰好 1 个路径参数: {cmd[:80]}"); sys.exit(0)
            path_arg = args[0]
            if path_arg.startswith('-') or any(c in path_arg for c in '*?[]{}') or path_arg.startswith('~'):
                print(f"BLOCK: exempt(read-only-query) 路径含 flag/glob/~: {path_arg}"); sys.exit(0)
            repo_root = Path(os.getcwd()).resolve()
            try:
                resolved = (repo_root / path_arg).resolve() if not os.path.isabs(path_arg) else Path(path_arg).resolve()
                rel = resolved.relative_to(repo_root)
            except (ValueError, OSError):
                print(f"BLOCK: exempt(read-only-query) 路径 resolve 到仓库外: {path_arg}"); sys.exit(0)
            rel_str = str(rel).replace(os.sep, '/')
            for component in rel_str.split('/'):
                if sensitive_name_re.search(component):
                    print(f"BLOCK: exempt(read-only-query) 路径含敏感名: {rel_str}"); sys.exit(0)
            continue
        print(f"BLOCK: exempt(read-only-query) 不允许工具 {name}"); sys.exit(0)

elif reason == 'behavior-neutral':
    import os
    from pathlib import Path
    safe_path = re.compile(r'^(\./)?docs/.*\.md$')
    deny_path = re.compile(r'(^|/)(\.claude/state/|docs/superpowers/)')
    safe_bash = re.compile(
        r'^(pwd|true|false)$'
        r'|^echo +["\'"][^"\'"|<>;&`$()]*["\'"]$'
        r'|^(ls|cat|head|tail|wc|grep|rg|jq) +[^|<>;&`$(){}\-]+$'
        r'|^(git +(status|log))$')
    for tu in last_tool_uses:
        name = tu.get('name', '')
        if name in ('Write', 'Edit', 'NotebookEdit', 'MultiEdit'):
            fp = get_path(tu)
            repo_root = Path(os.getcwd()).resolve()
            try:
                fp_resolved = (repo_root / fp).resolve() if not os.path.isabs(fp) else Path(fp).resolve()
            except Exception:
                print(f"BLOCK: exempt(behavior-neutral) 路径不可 resolve: {fp}"); sys.exit(0)
            try:
                fp_rel = fp_resolved.relative_to(repo_root)
            except ValueError:
                print(f"BLOCK: exempt(behavior-neutral) 路径 resolve 到仓库外: {fp}"); sys.exit(0)
            fp = str(fp_rel).replace(os.sep, '/')
            if deny_path.search(fp):
                print(f"BLOCK: exempt(behavior-neutral) Write/Edit 到 {fp} 禁止（.claude/state=L5 evidence; docs/superpowers=skill 产出区）"); sys.exit(0)
            if not safe_path.match(fp):
                print(f"BLOCK: exempt(behavior-neutral) Write/Edit 路径不在白名单: {fp}"); sys.exit(0)
        elif name == 'Bash':
            cmd = get_cmd(tu)
            if CONTROL_CHARS_RE.search(cmd):
                print(f"BLOCK: exempt(behavior-neutral) Bash 含控制字符: {cmd[:80]!r}"); sys.exit(0)
            if re.search(r'[|<>;&`$]', cmd) or '&&' in cmd or '||' in cmd:
                print(f"BLOCK: exempt(behavior-neutral) Bash 含管道/重定向/复合: {cmd[:80]}"); sys.exit(0)
            if not safe_bash.fullmatch(cmd):
                print(f"BLOCK: exempt(behavior-neutral) Bash 不在严格白名单: {cmd[:80]}"); sys.exit(0)
        elif name in ('Read', 'Grep', 'Glob'):
            continue
        else:
            print(f"BLOCK: exempt(behavior-neutral) 不允许工具 {name}"); sys.exit(0)

elif reason == 'single-step-no-semantic-change':
    if len(last_tool_uses) > 2:
        print(f"BLOCK: exempt(single-step) tool_uses 超 2 ({len(last_tool_uses)})"); sys.exit(0)
    safe_bash_single = re.compile(
        r'^(pwd|true|false)$'
        r'|^echo +["\'"][^"\'"|<>;&`$()]*["\'"]$'
        r'|^(ls|cat|head|tail|wc|grep|rg|jq) +[^|<>;&`$(){}\-]+$'
        r'|^\.claude/scripts/(codex-attest|attest-override)\.sh( +[-A-Za-z0-9_./:=@]+)*$')
    for tu in last_tool_uses:
        name = tu.get('name', '')
        if name in ('Read', 'Grep', 'Glob'):
            continue
        if name == 'Bash':
            cmd = get_cmd(tu)
            if CONTROL_CHARS_RE.search(cmd):
                print(f"BLOCK: exempt(single-step) Bash 含控制字符: {cmd[:80]!r}"); sys.exit(0)
            if re.search(r'[|<>;&`$]', cmd) or '&&' in cmd or '||' in cmd:
                print(f"BLOCK: exempt(single-step) Bash 含管道/重定向/复合: {cmd[:80]}"); sys.exit(0)
            if not safe_bash_single.fullmatch(cmd):
                print(f"BLOCK: exempt(single-step) Bash 不在严格白名单: {cmd[:80]}"); sys.exit(0)
            continue
        print(f"BLOCK: exempt(single-step) 不允许工具 {name}"); sys.exit(0)

elif reason == 'user-explicit-skip':
    AUTH_PHRASES = [r'skip\s*skill', r'no\s*skill', r'without\s*skill', r'exempt.*skill',
                    r'bypass\s*skill', r'跳过\s*skill', r'不用\s*skill', r'免\s*skill', r'/no-?skill']
    if not re.compile('|'.join(AUTH_PHRASES), re.IGNORECASE).search(last_user_text):
        print("BLOCK: exempt(user-explicit-skip) 需当前 user message 含显式授权短语"); sys.exit(0)

print("OK")
PY
}

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
if ! echo "$first_line" | grep -qE '^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|exempt\([a-z-]+\))'; then
  DRIFT_LOG=".claude/state/skill-gate-drift.jsonl"
  mkdir -p "$(dirname "$DRIFT_LOG")"
  # Infer last valid Skill gate from transcript (reverse scan most recent 20 assistant messages)
  inferred=$(python3 - "$tpath" <<'PY'
import json, re, sys
target = sys.argv[1]
gate_re = re.compile(r'^Skill gate:\s*(superpowers:[a-z-]+|codex:[a-z-]+|exempt\([a-z-]+\))')
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
  # L1 block mode (H6.9 flip): hard block missing first-line if enforcement_mode=block
  # v45 R45 F1: rescue ONLY H6 non-exempt gates (superpowers:*, codex:*)
  RULES=".claude/workflow-rules.json"
  ENF_MODE=$(jq -r '.skill_gate_policy.enforcement_mode // "drift-log"' "$RULES" 2>/dev/null || echo "drift-log")
  if [ "$ENF_MODE" = "block" ]; then
    CUR_TURN_GATE=$(python3 - "$tpath" <<'PYRESCUE'
import json, re, sys
GATE_RE = re.compile(r'^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+)')
entries = []
try:
    for line in open(sys.argv[1]):
        try: entries.append(json.loads(line))
        except Exception: continue
except Exception: pass
def is_human(e):
    if e.get('type') != 'user': return False
    c = e.get('message', {}).get('content', '')
    if isinstance(c, str): return True
    if isinstance(c, list):
        if any(isinstance(x, dict) and x.get('type') == 'tool_result' for x in c): return False
    return True
lui = -1
for i, e in enumerate(entries):
    if is_human(e): lui = i
for e in entries[lui+1:]:
    if e.get('type') != 'assistant': continue
    content = e.get('message', {}).get('content', [])
    if isinstance(content, list):
        for c in content:
            if isinstance(c, dict) and c.get('type') == 'text':
                fl = (c.get('text','').splitlines() or [''])[0]
                m = GATE_RE.match(fl)
                if m: print(m.group(1)); sys.exit(0)
PYRESCUE
)
    if [ -z "$CUR_TURN_GATE" ]; then
      block "first-line Skill gate 缺失或格式无效（当前 turn 无任何 assistant 含合法非-exempt gate；exempt rescue 不允许）；当前 first_line=\"$first_line\""
    fi
  fi
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

# L3 exempt integrity (v6 H6 R5 F1+F2 fix + v45 R45 F2 enforcement-mode gating):
if echo "$first_line" | grep -qE '^Skill gate: exempt\('; then
  reason=$(echo "$first_line" | sed -E 's/^Skill gate: exempt\(([^)]+)\).*/\1/')
  result=$(validate_exempt_integrity "$tpath" "$reason")
  if [[ "$result" == BLOCK:* ]]; then
    ENF_MODE_L3=$(jq -r '.skill_gate_policy.enforcement_mode // "drift-log"' .claude/workflow-rules.json 2>/dev/null || echo "drift-log")
    DRIFT_LOG=".claude/state/skill-gate-drift.jsonl"
    mkdir -p "$(dirname "$DRIFT_LOG")"
    printf '{"time_utc":"%s","kind":"l3_integrity_violation","first_line":%s,"reason":%s,"block_message":%s,"enforcement_mode":"%s","blocked":%s}\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      "$(printf '%s' "$first_line" | jq -Rs .)" \
      "$(printf '%s' "$reason" | jq -Rs .)" \
      "$(printf '%s' "${result#BLOCK: }" | jq -Rs .)" \
      "$ENF_MODE_L3" \
      "$([ "$ENF_MODE_L3" = "block" ] && echo true || echo false)" \
      >> "$DRIFT_LOG"
    if [ "$ENF_MODE_L3" = "block" ]; then
      block "${result#BLOCK: }"
    fi
    echo "[l3-drift] ${result#BLOCK: } (enforcement_mode=$ENF_MODE_L3; not blocking)" >&2
  fi
fi

# 3) Completion claim warning (stderr only; not block)
if echo "$last_text" | grep -qE '(任务完成|已完成|全部完成|验证通过|测试通过|it works|all pass)' \
  && ! echo "$last_text" | grep -qE '(Bash|bash|pytest|xcodebuild|npm test|jest)'; then
  >&2 echo "[stop-hook WARN] 声明完成但未见验证命令输出"
fi

exit 0

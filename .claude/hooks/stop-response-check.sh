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

import os, shlex
from pathlib import Path

_SENSITIVE_NAME_RE = re.compile(
    r'(\.ssh|\.aws|\.gnupg|\.kube|credentials|secrets?|\.env(\..+)?|'
    r'id_[rd]sa|\.pem|\.key|\.pgpass|\.netrc)$',
    re.IGNORECASE,
)

def _path_is_safe_for_read(raw_path, exempt_label):
    # Return None if safe; else a BLOCK message string.
    # Applies: reject ~/- / glob / absolute-out-of-repo / sensitive-name.
    if not raw_path:
        return None  # empty path - not a file-read arg
    s = str(raw_path)
    if s.startswith('~') or s.startswith('-'):
        return f"BLOCK: {exempt_label} 路径含 ~/flag: {s}"
    if any(c in s for c in '*?[]{}'):
        return f"BLOCK: {exempt_label} 路径含 glob: {s}"
    try:
        repo_root = Path(os.getcwd()).resolve()
        resolved = (repo_root / s).resolve() if not os.path.isabs(s) else Path(s).resolve()
        rel = resolved.relative_to(repo_root)
    except (ValueError, OSError):
        return f"BLOCK: {exempt_label} 路径 resolve 到仓库外或不可 resolve: {s}"
    rel_str = str(rel).replace(os.sep, '/')
    # R53 F1 fix (codex Gate-2 round-2): reject repo-root-equivalent paths
    if rel_str in ('.', ''):
        return f"BLOCK: {exempt_label} 路径归一化到仓库根等于全仓搜索: {raw_path}"
    for component in rel_str.split('/'):
        if _SENSITIVE_NAME_RE.search(component):
            return f"BLOCK: {exempt_label} 路径含敏感名: {rel_str}"
    return None

def _extract_read_target(tu):
    """R53 F1 fix: per-tool path extraction. Returns (tool_name, path_or_None).
    Read → (Read, file_path); Grep → (Grep, path); Glob → (Glob, None sentinel for unconditional block).
    Removes the v52 fallback `file_path or path or pattern or ''` which incorrectly
    treated Grep's pattern as a path when path param was absent."""
    name = tu.get('name', '')
    inp = tu.get('input', {})
    if name == 'Read':
        return (name, inp.get('file_path'))
    if name == 'Grep':
        return (name, inp.get('path'))
    if name == 'Glob':
        return (name, None)  # sentinel — caller unconditionally blocks
    return (name, None)

if reason == 'read-only-query':
    zero_path_re = re.compile(r'^(pwd|true|false)$|^echo +["\'][^"\'"|<>;&`$()]*["\']$')
    file_read_tools = {'ls', 'cat', 'head', 'tail', 'wc'}
    for tu in last_tool_uses:
        name = tu.get('name', '')
        if name in ('Read', 'Grep', 'Glob'):
            # R53 F1 fix (Gate 2 design): per-tool extraction + Glob unconditional block + Grep path-required
            tool_name, path_arg = _extract_read_target(tu)
            if tool_name == 'Glob':
                print(f"BLOCK: exempt(read-only-query) 不允许 Glob 工具（文件枚举不符合 exempt 最小读语义；请用 Read + 具体 path，或声明真实 skill gate）"); sys.exit(0)
            if tool_name == 'Grep' and not path_arg:
                print(f"BLOCK: exempt(read-only-query) Grep 必须显式传 path 参数（不允许无 path 全仓搜索）"); sys.exit(0)
            msg = _path_is_safe_for_read(path_arg, f"exempt(read-only-query) {tool_name}")
            if msg:
                print(msg); sys.exit(0)
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
            msg = _path_is_safe_for_read(path_arg, "exempt(read-only-query) Bash")
            if msg:
                print(msg); sys.exit(0)
            continue
        print(f"BLOCK: exempt(read-only-query) 不允许工具 {name}"); sys.exit(0)

elif reason == 'behavior-neutral':
    safe_path = re.compile(r'^(\./)?docs/.*\.md$')
    deny_path = re.compile(r'(^|/)(\.claude/state/|docs/superpowers/)')
    safe_bash = re.compile(
        r'^(pwd|true|false)$'
        r'|^echo +["\'][^"\'"|<>;&`$()]*["\']$'
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
            try:
                parts = shlex.split(cmd)
            except ValueError:
                print(f"BLOCK: exempt(behavior-neutral) Bash 解析失败: {cmd[:80]}"); sys.exit(0)
            # R53 F1 fix (Gate 2): 8-tool coverage + universal flag-ban + per-tool operand rules
            if parts and parts[0] in ('ls', 'cat', 'head', 'tail', 'wc', 'grep', 'rg', 'jq'):
                tool = parts[0]
                args = parts[1:]
                # Universal flag-ban (defense-in-depth; safe_bash regex also rejects `-`)
                for arg in args:
                    if arg.startswith('-'):
                        print(f"BLOCK: exempt(behavior-neutral) Bash {tool} 不允许任何 flag（避免 flag 吃 operand 导致 operand 误分类，如 head -n 1 .env / ls -I .env）: {cmd[:120]}"); sys.exit(0)
                if tool in ('cat', 'head', 'tail', 'wc', 'ls'):
                    if len(args) < 1:
                        print(f"BLOCK: exempt(behavior-neutral) Bash {tool} 需至少 1 个路径参数: {cmd[:120]}"); sys.exit(0)
                    for path_arg in args:
                        msg = _path_is_safe_for_read(path_arg, f"exempt(behavior-neutral) Bash {tool}")
                        if msg:
                            print(msg); sys.exit(0)
                elif tool in ('grep', 'rg'):
                    if len(args) != 2:
                        print(f"BLOCK: exempt(behavior-neutral) Bash {tool} 必须恰好 '<pattern> <path>' 形式 (实际 {len(args)} 参数): {cmd[:120]}"); sys.exit(0)
                    # Gate-4 round-1: reject shell-glob metachars in pattern (shell expands before tool runs)
                    if any(c in args[0] for c in '*?[]{}'):
                        print(f"BLOCK: exempt(behavior-neutral) Bash {tool} pattern 含 shell glob 元字符（shell 会在命令执行前展开成文件列表，绕过 path 检查）: {args[0]}"); sys.exit(0)
                    msg = _path_is_safe_for_read(args[1], f"exempt(behavior-neutral) Bash {tool}")
                    if msg:
                        print(msg); sys.exit(0)
                elif tool == 'jq':
                    if len(args) < 1:
                        print(f"BLOCK: exempt(behavior-neutral) Bash jq 至少需 filter: {cmd[:120]}"); sys.exit(0)
                    if len(args) < 2:
                        print(f"BLOCK: exempt(behavior-neutral) Bash jq 必须传文件参数 (filter 后至少 1 个 path): {cmd[:120]}"); sys.exit(0)
                    # Gate-4 round-1: same class as grep/rg — reject shell-glob metachars in filter
                    if any(c in args[0] for c in '*?[]{}'):
                        print(f"BLOCK: exempt(behavior-neutral) Bash jq filter 含 shell glob 元字符（shell 会在命令执行前展开成文件列表，绕过 path 检查）: {args[0]}"); sys.exit(0)
                    for path_arg in args[1:]:
                        msg = _path_is_safe_for_read(path_arg, f"exempt(behavior-neutral) Bash jq")
                        if msg:
                            print(msg); sys.exit(0)
        elif name in ('Read', 'Grep', 'Glob'):
            # R53 F1 fix (Gate 2 design): per-tool extraction + Glob unconditional block + Grep path-required
            tool_name, path_arg = _extract_read_target(tu)
            if tool_name == 'Glob':
                print(f"BLOCK: exempt(behavior-neutral) 不允许 Glob 工具（文件枚举不符合 exempt 最小读语义；请用 Read + 具体 path，或声明真实 skill gate）"); sys.exit(0)
            if tool_name == 'Grep' and not path_arg:
                print(f"BLOCK: exempt(behavior-neutral) Grep 必须显式传 path 参数（不允许无 path 全仓搜索）"); sys.exit(0)
            msg = _path_is_safe_for_read(path_arg, f"exempt(behavior-neutral) {tool_name}")
            if msg:
                print(msg); sys.exit(0)
            continue
        else:
            print(f"BLOCK: exempt(behavior-neutral) 不允许工具 {name}"); sys.exit(0)

elif reason == 'single-step-no-semantic-change':
    if len(last_tool_uses) > 2:
        print(f"BLOCK: exempt(single-step) tool_uses 超2 ({len(last_tool_uses)})"); sys.exit(0)
    safe_bash_single = re.compile(
        r'^(pwd|true|false)$'
        r'|^echo +["\'][^"\'"|<>;&`$()]*["\']$'
        r'|^(ls|cat|head|tail|wc|grep|rg|jq) +[^|<>;&`$(){}\-]+$'
        r'|^\.claude/scripts/(codex-attest|attest-override)\.sh( +[-A-Za-z0-9_./:=@]+)*$')
    for tu in last_tool_uses:
        name = tu.get('name', '')
        if name in ('Read', 'Grep', 'Glob'):
            # R53 F1 fix (Gate 2 design): per-tool extraction + Glob unconditional block + Grep path-required
            tool_name, path_arg = _extract_read_target(tu)
            if tool_name == 'Glob':
                print(f"BLOCK: exempt(single-step) 不允许 Glob 工具（文件枚举不符合 exempt 最小读语义；请用 Read + 具体 path，或声明真实 skill gate）"); sys.exit(0)
            if tool_name == 'Grep' and not path_arg:
                print(f"BLOCK: exempt(single-step) Grep 必须显式传 path 参数（不允许无 path 全仓搜索）"); sys.exit(0)
            msg = _path_is_safe_for_read(path_arg, f"exempt(single-step) {tool_name}")
            if msg:
                print(msg); sys.exit(0)
            continue
        if name == 'Bash':
            cmd = get_cmd(tu)
            if CONTROL_CHARS_RE.search(cmd):
                print(f"BLOCK: exempt(single-step) Bash 含控制字符: {cmd[:80]!r}"); sys.exit(0)
            if re.search(r'[|<>;&`$]', cmd) or '&&' in cmd or '||' in cmd:
                print(f"BLOCK: exempt(single-step) Bash 含管道/重定向/复合: {cmd[:80]}"); sys.exit(0)
            if not safe_bash_single.fullmatch(cmd):
                print(f"BLOCK: exempt(single-step) Bash 不在严格白名单: {cmd[:80]}"); sys.exit(0)
            try:
                parts = shlex.split(cmd)
            except ValueError:
                print(f"BLOCK: exempt(single-step) Bash 解析失败: {cmd[:80]}"); sys.exit(0)
            # R53 F1 fix (Gate 2): 8-tool coverage + universal flag-ban + per-tool operand rules
            if parts and parts[0] in ('ls', 'cat', 'head', 'tail', 'wc', 'grep', 'rg', 'jq'):
                tool = parts[0]
                args = parts[1:]
                # Universal flag-ban (defense-in-depth; safe_bash regex also rejects `-`)
                for arg in args:
                    if arg.startswith('-'):
                        print(f"BLOCK: exempt(single-step) Bash {tool} 不允许任何 flag（避免 flag 吃 operand 导致 operand 误分类，如 head -n 1 .env / ls -I .env）: {cmd[:120]}"); sys.exit(0)
                if tool in ('cat', 'head', 'tail', 'wc', 'ls'):
                    if len(args) < 1:
                        print(f"BLOCK: exempt(single-step) Bash {tool} 需至少 1 个路径参数: {cmd[:120]}"); sys.exit(0)
                    for path_arg in args:
                        msg = _path_is_safe_for_read(path_arg, f"exempt(single-step) Bash {tool}")
                        if msg:
                            print(msg); sys.exit(0)
                elif tool in ('grep', 'rg'):
                    if len(args) != 2:
                        print(f"BLOCK: exempt(single-step) Bash {tool} 必须恰好 '<pattern> <path>' 形式 (实际 {len(args)} 参数): {cmd[:120]}"); sys.exit(0)
                    # Gate-4 round-1: reject shell-glob metachars in pattern
                    if any(c in args[0] for c in '*?[]{}'):
                        print(f"BLOCK: exempt(single-step) Bash {tool} pattern 含 shell glob 元字符（shell 会在命令执行前展开成文件列表，绕过 path 检查）: {args[0]}"); sys.exit(0)
                    msg = _path_is_safe_for_read(args[1], f"exempt(single-step) Bash {tool}")
                    if msg:
                        print(msg); sys.exit(0)
                elif tool == 'jq':
                    if len(args) < 1:
                        print(f"BLOCK: exempt(single-step) Bash jq 至少需 filter: {cmd[:120]}"); sys.exit(0)
                    if len(args) < 2:
                        print(f"BLOCK: exempt(single-step) Bash jq 必须传文件参数 (filter 后至少 1 个 path): {cmd[:120]}"); sys.exit(0)
                    if any(c in args[0] for c in '*?[]{}'):
                        print(f"BLOCK: exempt(single-step) Bash jq filter 含 shell glob 元字符（shell 会在命令执行前展开成文件列表，绕过 path 检查）: {args[0]}"); sys.exit(0)
                    for path_arg in args[1:]:
                        msg = _path_is_safe_for_read(path_arg, f"exempt(single-step) Bash jq")
                        if msg:
                            print(msg); sys.exit(0)
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

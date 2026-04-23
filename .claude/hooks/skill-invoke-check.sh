#!/usr/bin/env bash
# skill-invoke-check.sh (hardening-6 v19 ζ)
# Stop hook: L2 invoke match + L4 mini-state + L5 codex evidence + unknown gate fail-closed
set -eo pipefail

# v19 R18 F1 fix: anchor all relative paths to project root regardless of cwd
# (Claude Code may invoke Stop hooks from any directory; paths must work reliably)
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT" || { echo "[skill-invoke-check] cannot cd to REPO_ROOT=$REPO_ROOT; fail-open" >&2; exit 0; }

CONFIG=".claude/config/skill-invoke-enforced.json"
RULES=".claude/workflow-rules.json"
STATE_DIR=".claude/state/skill-stage"
DRIFT_LOG=".claude/state/skill-invoke-drift.jsonl"
LEDGER=".claude/state/attest-ledger.json"
OVERRIDE_LOG=".claude/state/attest-override-log.jsonl"

# Fail-open ONLY for parse/infra errors; NOT for enforcement paths
# v8 R8 F2 fix: remove global ERR trap which could swallow pipefail errors
# in codex target computation; handle expected empty results explicitly with || true

input=$(cat)
tpath=$(echo "$input" | jq -r '.transcript_path // ""')
[ -z "$tpath" ] && exit 0
[ ! -f "$tpath" ] && exit 0
[ ! -f "$CONFIG" ] && exit 0

# Extract current-turn assistant: text (last) + tool_uses (aggregated across ALL
# assistant entries since last user entry) — v15 R14 F2 fix
TXT_AND_USES=$(python3 - "$tpath" <<'PY'
import json, sys
text = ""
tool_uses = []
entries = []
try:
    with open(sys.argv[1]) as f:
        for line in f:
            try:
                d = json.loads(line)
                if d.get('type') in ('user', 'assistant'):
                    entries.append(d)
            except Exception:
                continue
except Exception:
    pass
# v34 R34 F1 fix: distinguish HUMAN user prompt from tool_result pseudo-user
# (see stop-response-check.sh for full rationale — same bypass: tool_result
# turns between assistant tool_use and final assistant would drop earlier
# tool_uses → L2 invoke check + codex target derivation silently miss them).
def is_human_user_entry(e):
    if e.get('type') != 'user':
        return False
    content = e.get('message', {}).get('content', '')
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        has_tool_result = any(
            isinstance(c, dict) and c.get('type') == 'tool_result'
            for c in content
        )
        if has_tool_result:
            return False
        has_text = any(
            isinstance(c, dict) and c.get('type') in ('text', 'input-text')
            for c in content
        )
        return has_text or True
    return False

# Find last HUMAN user index; current turn = all assistant entries after it
last_user_idx = -1
for i, e in enumerate(entries):
    if is_human_user_entry(e):
        last_user_idx = i
# v36 R36 F1 fix: FIRST_LINE must cover mode-i flow (same-response announce
# + codex-attest run). Real transcripts after a tool_use have:
#   assistant N  : text("Skill gate:...") + tool_use
#   user N+1     : tool_result (pseudo-turn, not human)
#   assistant N+2: final text (MAY NOT repeat gate)
# Previous code took text from the LAST assistant only → final ungated →
# L1 blocks the legit codex gate flow. Fix: scan all assistant entries in
# the current turn; take FIRST_LINE from the first assistant that has a
# gate-shaped first line. Fall back to last assistant text if none.
import re
GATE_RE = re.compile(r'^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|exempt\([a-z-]+\))')  # v44 R44 F1 final: H6 scope only
gated_text = ""
last_text_any = ""
for e in entries[last_user_idx + 1:]:
    if e.get('type') == 'assistant':
        content = e.get('message', {}).get('content', [])
        if isinstance(content, list):
            text_this_entry = ""
            for c in content:
                if isinstance(c, dict):
                    if c.get('type') == 'text':
                        text_this_entry = c.get('text', '')
                    elif c.get('type') == 'tool_use':
                        tool_uses.append({'name': c.get('name'), 'input': c.get('input', {})})
            if text_this_entry:
                last_text_any = text_this_entry
                # First gate-matching text wins
                if not gated_text and GATE_RE.match(text_this_entry.splitlines()[0] if text_this_entry else ""):
                    gated_text = text_this_entry
text = gated_text or last_text_any
print(json.dumps({'text': text, 'tool_uses': tool_uses}))
PY
)
LAST_TEXT=$(echo "$TXT_AND_USES" | jq -r '.text')
[ -z "$LAST_TEXT" ] && exit 0

FIRST_LINE=$(echo "$LAST_TEXT" | head -1)
GATE_RE='^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|exempt\([a-z-]+\))'  # v44 R44 F1 final: H6 scope only
if ! echo "$FIRST_LINE" | grep -qE "$GATE_RE"; then
  exit 0  # existing stop-response-check.sh handles missing first-line
fi

# Extract skill-name (not exempt)
if echo "$FIRST_LINE" | grep -qE '^Skill gate: exempt\('; then
  exit 0  # exempt handled by stop-response-check.sh
fi
SKILL_NAME=$(echo "$FIRST_LINE" | sed -E 's/^Skill gate: (.*)/\1/')

# Session start (v4 R3 F3 fix: ULID first, env fallback - aligns with spec §3.4)
SESSION_START_UTC=""
if [ -n "$CLAUDE_SESSION_ID" ]; then
  # Primary: ULID timestamp decode (first 10 chars base32 → ms since epoch)
  SESSION_START_UTC=$(python3 -c "
import sys
try:
    s = '$CLAUDE_SESSION_ID'[:10].upper()
    alph = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
    n = 0
    for c in s:
        n = n*32 + alph.index(c)
    import datetime
    print(datetime.datetime.utcfromtimestamp(n/1000).strftime('%Y-%m-%dT%H:%M:%SZ'))
except Exception:
    pass
" 2>/dev/null)
fi
# Fallback: env var (only if ULID failed/absent)
if [ -z "$SESSION_START_UTC" ]; then
  SESSION_START_UTC="${CLAUDE_SESSION_START_UTC:-}"
fi
SESSION_UNKNOWN=0
[ -z "$SESSION_START_UTC" ] && SESSION_UNKNOWN=1

ENF_MODE=$(jq -r '.skill_gate_policy.enforcement_mode // "drift-log"' "$RULES" 2>/dev/null)

block() {
  jq -nc --arg r "$1" '{decision: "block", reason: $r}'
  exit 0
}

drift_log() {
  # $1 = drift_kind; $2 = invoked; $3 = exempt_matched; $4 = last_stage_before
  # $5 = blocked (v27 R26 F3 fix; default inferred from BLOCK_MODE_PENDING env)
  # R11 F2 fix: mkdir -p parent dir (fresh checkout may not have .claude/state/)
  local kind="$1"
  local invoked="${2:-false}"
  local exempt_matched="${3:-null}"
  local last_stage_before="${4:-null}"
  # v27 R26 F3: blocked reflects whether this drift_log call precedes a block()
  # Passed explicitly by caller (default false if not passed)
  local blocked="${5:-false}"
  local rsha=$(printf '%s' "$LAST_TEXT" | shasum -a 256 | awk '{print $1}')
  mkdir -p "$(dirname "$DRIFT_LOG")" 2>/dev/null || true
  python3 - "$DRIFT_LOG" "$kind" "$SKILL_NAME" "$invoked" "$exempt_matched" "$last_stage_before" "$rsha" "${CLAUDE_SESSION_ID:-unknown}" "$blocked" <<'PY'
import json, sys, time, os
p, kind, skill, invoked, exempt_m, last_stage, rsha, sid, blocked = sys.argv[1:10]
entry = {
    'time_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'session_id': sid,
    'response_sha': f'sha256:{rsha}',
    'gate_skill': skill,
    'config_mode': os.environ.get('CONFIG_MODE', 'unknown'),
    'invoked': invoked == 'true',
    'exempt_rule_matched': None if exempt_m == 'null' else exempt_m,
    'last_stage_before': None if last_stage == 'null' else last_stage,
    'drift_kind': kind,
    'blocked': blocked == 'true',
}
# Ensure parent dir exists (fresh checkout fix R11 F2)
os.makedirs(os.path.dirname(p) or '.', exist_ok=True)
with open(p, 'a') as f:
    f.write(json.dumps(entry) + '\n')
PY
}

# v27 R26 F3 fix: helper that calls drift_log with blocked=true then block()
drift_log_and_block() {
  # Usage: drift_log_and_block <drift_kind> <reason>
  drift_log "$1" "false" "null" "$LAST_STAGE" "true"
  block "$2"
}

# v44 R44 F1 HIGH final fix: unknown-gate fail-closed in block mode.
# Previous v38 plugin-format-invoke-match passthrough was durable bypass:
# agent could declare `Skill gate: frontend-design:web` + invoke
# frontend-design, skipping required H6 transitions (brainstorming →
# writing-plans → codex:adversarial-review). Codex R44 final verdict:
# scope L1 + L2 to H6 only. Non-H6 users either:
# 1. Use superpowers:* gate + call plugin as Skill sub-invoke (normal H6 flow)
# 2. Explicitly register plugin gate in skill-invoke-enforced.json

# Look up config
IN_CONFIG=$(jq -r --arg s "$SKILL_NAME" '.enforce[$s] // empty' "$CONFIG")
if [ -z "$IN_CONFIG" ]; then
  # Unknown gate: fail-closed in block mode (no plugin-format passthrough).
  if [ "$ENF_MODE" = "block" ] && [ "${ALLOW_UNKNOWN_GATE:-0}" != "1" ]; then
    drift_log "unknown_skill_in_gate"
    block "Skill gate '$SKILL_NAME' 未在 skill-invoke-enforced.json 配置；block mode fail-closed。非-H6 plugin 请：(1) 用 superpowers:* gate 把该 plugin 当 Skill sub-invoke 调用，或 (2) 注册 plugin gate 到 config"
  fi
  drift_log "unknown_skill_in_gate"
  exit 0
fi

CONFIG_MODE=$(echo "$IN_CONFIG" | jq -r '.mode')
EXEMPT_RULE=$(echo "$IN_CONFIG" | jq -r '.exempt_rule // ""')
export CONFIG_MODE

# Load mini-state
WT_HASH8=$(printf '%s' "$PWD" | shasum -a 256 | awk '{print $1}' | cut -c1-8)
# v27 R26 F1 fix: SHA256 hash of FULL CLAUDE_SESSION_ID (not :0:8 prefix which
# is ULID timestamp data, collides across sessions in same time bucket).
# v28 R27 F1 fix: in block mode, fail-closed when CLAUDE_SESSION_ID absent
# (PPID+epoch fallback creates new state file per invocation → LAST_STAGE
# resets to _initial → L4 mini-state silently bypassed). In observe mode,
# retain pid+time fallback for drift telemetry continuity.
if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  SID_HASH=$(printf '%s' "$CLAUDE_SESSION_ID" | shasum -a 256 | awk '{print $1}' | cut -c1-8)
else
  if [ "$CONFIG_MODE" = "block" ]; then
    drift_log "session_id_absent_l4_fail_closed" false null "_initial"
    block "CLAUDE_SESSION_ID 不可读; block mode L4 fail-closed（PPID+time fallback 会每次重置 last_stage=_initial，等效绕过 mini-state）；export CLAUDE_SESSION_ID 或降级 observe mode"
  fi
  # observe mode only: per-process unique fallback (drift telemetry continuity)
  SID_HASH=$(printf 'noSess-%s-%s' "$PPID" "$(date +%s)" | shasum -a 256 | awk '{print $1}' | cut -c1-8)
fi
STATE_FILE="$STATE_DIR/${WT_HASH8}-${SID_HASH}.json"
LAST_STAGE="_initial"
if [ -f "$STATE_FILE" ]; then
  LAST_STAGE=$(jq -r '.last_stage // "_initial"' "$STATE_FILE" 2>/dev/null || echo "_initial")
fi

# Special path for codex:adversarial-review (L5)
if [ "$SKILL_NAME" = "codex:adversarial-review" ]; then
  # Compute target (v4 R3 F2 fix: explicit from response; block on ambiguity)
  TARGET=""
  case "$LAST_STAGE" in
    "superpowers:brainstorming"|"superpowers:writing-plans")
      # v29 R29 F1 fix: resolve each Write/Edit path to absolute, require
      # relative_to(repo_root) inside repo, THEN match docs/superpowers/(specs|plans)/.
      # v33 R33 F1 fix: pass TXT_AND_USES via env var, NOT stdin pipe.
      # Previous `echo "$TXT_AND_USES" | python3 - "$PWD" <<'PY'` had
      # conflicting stdin: `python3 -` reads SCRIPT from stdin, AND heredoc
      # also occupies stdin → heredoc wins → python ran the script but
      # sys.stdin.read() then returned empty / the script text itself,
      # so json.loads always failed silently → CANDIDATES always empty →
      # codex gate after valid spec/plan edit would block with no_target.
      CANDIDATES=$(TXT_AND_USES_JSON="$TXT_AND_USES" python3 - "$PWD" <<'PY' 2>/dev/null || true
import json, os, sys, re
from pathlib import Path
pwd = Path(sys.argv[1]).resolve()
spec_plan_re = re.compile(r'^docs/superpowers/(specs|plans)/.+\.md$')
seen = set()
try:
    data = json.loads(os.environ.get('TXT_AND_USES_JSON', ''))
except Exception:
    sys.exit(0)
for tu in data.get('tool_uses', []):
    if tu.get('name') not in ('Write', 'Edit', 'NotebookEdit', 'MultiEdit'):
        continue
    fp = tu.get('input', {}).get('file_path', '')
    if not fp:
        continue
    try:
        fp_abs = (pwd / fp).resolve() if not Path(fp).is_absolute() else Path(fp).resolve()
        rel = fp_abs.relative_to(pwd)
    except (ValueError, OSError):
        continue
    rel_str = str(rel).replace('\\', '/')
    if spec_plan_re.match(rel_str) and rel_str not in seen:
        seen.add(rel_str)
        print(rel_str)
PY
)
      CAND_COUNT=$(echo "$CANDIDATES" | grep -cv '^$' 2>/dev/null || echo 0)
      if [ "$CAND_COUNT" = "1" ]; then
        RECENT_FILE="$CANDIDATES"
        TARGET="file:$RECENT_FILE"
      elif [ "$CAND_COUNT" -gt 1 ]; then
        drift_log "codex_gate_ambiguous_target"
        [ "$CONFIG_MODE" = "block" ] && block "codex:adversarial-review target 模糊（last_stage=$LAST_STAGE, 候选 $CAND_COUNT 个）；请响应内显式编辑/写入单一 spec/plan 文件，或设置 env TARGET"
        exit 0
      fi
      # v18 R17 F3 HIGH + v26 R25 F1 + v28 R27 F2 fix:
      # When no explicit tool_use (e.g., codex run-only response), ONLY
      # fall back to mini-state recorded artifact with blob consistency check.
      # v28 R27 F2: REMOVED `git log -1 --name-only` fallback — that committed
      # file's blob may not match CURRENT file blob if user has uncommitted
      # edits; binding to committed blob silently approves stale content.
      # mini-state records path+blob at brainstorming/writing-plans time and
      # is compared to CURRENT git hash-object output, so blob mismatch →
      # explicit refresh required.
      if [ "$CAND_COUNT" = "0" ] && [ -f "$STATE_FILE" ]; then
        RECENT_ART=$(jq -r '.recent_artifact_path // ""' "$STATE_FILE" 2>/dev/null)
        RECENT_BLOB=$(jq -r '.recent_artifact_blob // ""' "$STATE_FILE" 2>/dev/null)
        if [ -n "$RECENT_ART" ] && [ -f "$RECENT_ART" ]; then
          # v26 R25 F1: verify current file blob matches stored blob
          # If file was modified after state recorded, state is stale →
          # require explicit current Write/Edit tool_use or state refresh
          CUR_BLOB_OF_ART=$(git hash-object "$RECENT_ART" 2>/dev/null)
          if [ -n "$RECENT_BLOB" ] && [ "$CUR_BLOB_OF_ART" = "$RECENT_BLOB" ]; then
            TARGET="file:$RECENT_ART"
            CAND_COUNT=1
          else
            drift_log "codex_gate_stale_artifact_target"
            [ "$CONFIG_MODE" = "block" ] && block "codex:adversarial-review: state recorded blob ($RECENT_BLOB) != current ($CUR_BLOB_OF_ART) for $RECENT_ART; 需响应内显式 Write/Edit spec/plan 或重新触发 brainstorming/writing-plans 刷新 state"
            exit 0
          fi
        fi
      fi
      # CAND_COUNT == 0 AND no state artifact → TARGET stays empty, falls through
      ;;
    "superpowers:subagent-driven-development"|"superpowers:requesting-code-review"|"superpowers:finishing-a-development-branch")
      HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
      CUR_BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      [ -n "$HEAD_SHA" ] && TARGET="branch:${CUR_BR}@${HEAD_SHA}"
      ;;
    "_initial")
      # Allow without target at session start
      TARGET="_initial"
      ;;
  esac

  if [ -z "$TARGET" ]; then
    if [ "$CONFIG_MODE" = "block" ] && [ "${ALLOW_EMPTY_CODEX_TARGET:-0}" != "1" ]; then
      drift_log "codex_gate_no_target"
      block "codex:adversarial-review target 为空（last_stage=$LAST_STAGE）; block mode fail-closed"
    fi
    drift_log "codex_gate_no_target"
    exit 0
  fi

  # Session unknown handling
  if [ "$SESSION_UNKNOWN" = "1" ]; then
    drift_log "session_start_unknown"
    if [ "$CONFIG_MODE" = "block" ]; then
      block "session_start 不可确定; block mode L5 fail-closed (export CLAUDE_SESSION_START_UTC 或确保 CLAUDE_SESSION_ID 可读)"
    fi
    exit 0
  fi

  # Path A: ledger
  EVIDENCE_PASS=0
  if [ "$TARGET" = "_initial" ]; then
    EVIDENCE_PASS=1
  elif [ -f "$LEDGER" ]; then
    ENTRY=$(jq -c --arg k "$TARGET" '.entries[$k] // .[$k] // empty' "$LEDGER" 2>/dev/null)
    if [ -n "$ENTRY" ]; then
      ATTEST_TIME=$(echo "$ENTRY" | jq -r '.attest_time_utc // ""')
      VDIGEST=$(echo "$ENTRY" | jq -r '.verdict_digest // ""')
      if [ -n "$ATTEST_TIME" ] && [ -n "$VDIGEST" ] && [[ "$ATTEST_TIME" > "$SESSION_START_UTC" ]]; then
        # Revision bind for file target
        if [[ "$TARGET" =~ ^file: ]]; then
          FILE_PATH="${TARGET#file:}"
          if [ -f "$FILE_PATH" ]; then
            CUR_BLOB=$(git hash-object "$FILE_PATH" 2>/dev/null)
            LEDGER_BLOB=$(echo "$ENTRY" | jq -r '.blob_sha // .blob // ""')
            if [ -n "$CUR_BLOB" ] && [ "$CUR_BLOB" = "$LEDGER_BLOB" ]; then
              EVIDENCE_PASS=1
            fi
          fi
        elif [[ "$TARGET" =~ ^branch: ]]; then
          # v14 R13 F1 fix: branch target 也必须 payload SHA match (不止 key match)
          BR_SHA_FROM_TARGET="${TARGET##*@}"
          ENTRY_HEAD_SHA=$(echo "$ENTRY" | jq -r '.head_sha // .blob_or_head_sha // .head_sha_for_patch // ""')
          if [ -n "$BR_SHA_FROM_TARGET" ] && [ "$BR_SHA_FROM_TARGET" = "$ENTRY_HEAD_SHA" ]; then
            EVIDENCE_PASS=1
          fi
        else
          # Unknown target kind (shouldn't reach here but fail-closed)
          :
        fi
      fi
    fi
  fi

  # Path B: ledger override entry (v18 R17 F1 CRITICAL fix)
  # Raw override-log jsonl line is NOT sufficient (can be forged with Write).
  # Require keyed ledger entry with override:true field AND matching audit_log_line
  # reference, then cross-verify the audit log line matches the ledger entry.
  if [ "$EVIDENCE_PASS" = "0" ] && [ -f "$LEDGER" ]; then
    OV_ENTRY=$(jq -c --arg k "$TARGET" '.entries[$k] // .[$k] // empty' "$LEDGER" 2>/dev/null)
    if [ -n "$OV_ENTRY" ]; then
      IS_OVERRIDE=$(echo "$OV_ENTRY" | jq -r '.override // false')
      OV_TIME=$(echo "$OV_ENTRY" | jq -r '.override_time_utc // .attest_time_utc // ""')
      AUDIT_LINE=$(echo "$OV_ENTRY" | jq -r '.audit_log_line // ""')
      if [ "$IS_OVERRIDE" = "true" ] && [[ "$OV_TIME" > "$SESSION_START_UTC" ]] && [ -n "$AUDIT_LINE" ]; then
        # Cross-verify: audit log line N in override-log.jsonl must reference same target
        if [ -f "$OVERRIDE_LOG" ]; then
          AUDIT_CONTENT=$(sed -n "${AUDIT_LINE}p" "$OVERRIDE_LOG" 2>/dev/null)
          if [ -n "$AUDIT_CONTENT" ]; then
            AUDIT_TARGET=$(echo "$AUDIT_CONTENT" | jq -r '.target // ""')
            AUDIT_KIND=$(echo "$AUDIT_CONTENT" | jq -r '.kind // ""')
            # Match target path/branch + kind + revision
            if [[ "$TARGET" =~ ^file: ]] && [ "$AUDIT_KIND" = "file" ] && [ "$AUDIT_TARGET" = "${TARGET#file:}" ]; then
              FILE_PATH="${TARGET#file:}"
              CUR_BLOB=$(git hash-object "$FILE_PATH" 2>/dev/null)
              AUDIT_BLOB=$(echo "$AUDIT_CONTENT" | jq -r '.blob_or_head_sha // ""')
              [ "$CUR_BLOB" = "$AUDIT_BLOB" ] && EVIDENCE_PASS=1
            elif [[ "$TARGET" =~ ^branch: ]] && [ "$AUDIT_KIND" = "branch" ]; then
              BR_NAME=$(echo "$TARGET" | sed -E 's/branch:([^@]+)@.*/\1/')
              BR_SHA="${TARGET##*@}"
              AUDIT_BR_SHA=$(echo "$AUDIT_CONTENT" | jq -r '.blob_or_head_sha // ""')
              [ "$AUDIT_TARGET" = "$BR_NAME" ] && [ "$AUDIT_BR_SHA" = "$BR_SHA" ] && EVIDENCE_PASS=1
            fi
          fi
        fi
      fi
    fi
  fi

  if [ "$EVIDENCE_PASS" = "0" ]; then
    drift_log "codex_gate_no_evidence" false null "$LAST_STAGE"
    if [ "$CONFIG_MODE" = "block" ]; then
      block "codex:adversarial-review 无 target-bound 有效证据 (target=$TARGET); 需跑 codex-attest.sh or attest-override.sh"
    fi
    exit 0
  fi

  # L5 pass → L4 mini-state update
  SKIP_L2=1  # skip Skill invoke match (codex unique)
else
  SKIP_L2=0
fi

# L2: Skill invoke match (v4: exact canonical match only, no short-name alias)
# R3 F1 fix: reject `brainstorming` invoke when gate is `superpowers:brainstorming`
# (or vice versa); require .input.skill == $SKILL_NAME exactly as configured
if [ "$SKIP_L2" = "0" ]; then
  INVOKED=$(echo "$TXT_AND_USES" | jq -r --arg s "$SKILL_NAME" '
    .tool_uses[] 
    | select(.name == "Skill") 
    | select(.input.skill == $s) 
    | "true"
  ' | head -1)

  if [ "$INVOKED" != "true" ]; then
    # Check exempt_rule
    EXEMPT_MATCHED=""
    case "$EXEMPT_RULE" in
      "plan-doc-spec-frozen-note")
        echo "$LAST_TEXT" | grep -qE 'brainstorming skipped.*spec.*frozen' && EXEMPT_MATCHED="$EXEMPT_RULE"
        ;;
      "plan-start-in-worktree")
        if echo "$TXT_AND_USES" | jq -r '.tool_uses[] | select(.name=="Bash") | .input.command' | grep -qE 'git worktree add'; then
          EXEMPT_MATCHED="$EXEMPT_RULE"
        elif [[ "$PWD" == */\.worktrees/* ]]; then
          EXEMPT_MATCHED="$EXEMPT_RULE"
        fi
        ;;
    esac

    if [ -z "$EXEMPT_MATCHED" ]; then
      drift_log "gate_declared_no_invoke" false null "$LAST_STAGE"
      if [ "$CONFIG_MODE" = "block" ]; then
        block "Skill gate '$SKILL_NAME' 声明但响应未 Skill tool invoke; 且 exempt_rule ($EXEMPT_RULE) 不匹配"
      fi
      exit 0
    fi
  fi
fi

# L4 mini-state check
# wildcard
WILDCARD=$(jq -r --arg s "$SKILL_NAME" '.mini_state.wildcard_always_allowed[] | select(. == $s)' "$CONFIG")
if [ -n "$WILDCARD" ]; then
  # v25 R24 F2 fix: distinguish between "state-less wildcards" and
  # "wildcards WITH legal_next_set entry":
  # - state-less (using-superpowers, dispatching-parallel-agents):
  #   pass without state update (no entry means no meaningful "next")
  # - has legal_next_set entry (systematic-debugging):
  #   wildcard-entry is allowed from any last_stage, BUT state MUST
  #   update to this skill so subsequent transitions check its
  #   legal_next_set (e.g., systematic-debugging -> test/verification)
  HAS_LNS=$(jq -r --arg s "$SKILL_NAME" '.mini_state.legal_next_set[$s] // empty' "$CONFIG")
  if [ -z "$HAS_LNS" ]; then
    # State-less wildcard: pass, no state update
    exit 0
  fi
  # Wildcard with legal_next_set: fall through to state update block below
else
  # legal_next_set check
  LEGAL=$(jq -r --arg k "$LAST_STAGE" --arg s "$SKILL_NAME" '
    .mini_state.legal_next_set[$k][]? | select(. == $s)
  ' "$CONFIG" | head -1)
  if [ -z "$LEGAL" ]; then
    drift_log "illegal_transition" true null "$LAST_STAGE"
    if [ "$CONFIG_MODE" = "block" ]; then
      LEGAL_SET=$(jq -r --arg k "$LAST_STAGE" '.mini_state.legal_next_set[$k][]? // empty' "$CONFIG" | tr '\n' ',' | sed 's/,$//')
      block "非法 transition: last_stage=$LAST_STAGE, current=$SKILL_NAME; expected: {$LEGAL_SET}"
    fi
    exit 0
  fi
fi

# Atomic update last_stage
mkdir -p "$STATE_DIR"
# v28 R27 F3 fix: mktemp inside $STATE_DIR guarantees same-filesystem rename
# (default mktemp uses $TMPDIR or /tmp, which on Linux tmpfs is a different
# filesystem → mv becomes copy+unlink, not atomic; concurrent reader can
# observe partial write). Same-FS mv is rename(2) = atomic.
TMP=$(mktemp "$STATE_DIR/.tmp.XXXXXX")
python3 - "$STATE_FILE" "$TMP" "$SKILL_NAME" "$PWD" "${CLAUDE_SESSION_ID:-}" "$TXT_AND_USES" <<'PY'
import json, sys, time, os, subprocess
sf, tmp, skill, pwd, sid, txt_uses_json = sys.argv[1:7]
history = []
recent_artifact = ""
recent_artifact_blob = ""
if os.path.exists(sf):
    try:
        d = json.load(open(sf))
        history = d.get('transition_history', [])
        recent_artifact = d.get('recent_artifact_path', '')
        recent_artifact_blob = d.get('recent_artifact_blob', '')
    except Exception:
        pass
history.append({'stage': skill, 'time': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())})

# v18 R17 F3 fix: if brainstorming/writing-plans writes a spec/plan, record path+blob
# so next codex run-only response can recover target from state
# v29 R29 F1 fix: resolve path to absolute, require relative_to(repo_root) inside
# repo before accepting. Previous lstrip('/') converted /tmp/docs/superpowers/...
# → tmp/docs/superpowers/... which still contained docs/superpowers/ substring
# in some regex variants, or more broadly bound state to out-of-repo files.
if skill in ('superpowers:brainstorming', 'superpowers:writing-plans'):
    try:
        tu_data = json.loads(txt_uses_json)
        import re
        from pathlib import Path
        pwd_real = Path(pwd).resolve()
        spec_plan_re = re.compile(r'^docs/superpowers/(specs|plans)/.+\.md$')
        for tu in tu_data.get('tool_uses', []):
            if tu.get('name') in ('Write', 'Edit', 'MultiEdit', 'NotebookEdit'):
                fp = tu.get('input', {}).get('file_path', '')
                if not fp:
                    continue
                try:
                    fp_abs = (pwd_real / fp).resolve() if not Path(fp).is_absolute() else Path(fp).resolve()
                    rel = fp_abs.relative_to(pwd_real)
                except (ValueError, OSError):
                    continue  # out-of-repo / unresolvable → skip
                rel_str = str(rel).replace('\\', '/')
                if spec_plan_re.match(rel_str):
                    recent_artifact = rel_str
                    try:
                        recent_artifact_blob = subprocess.check_output(
                            ['git', 'hash-object', rel_str], text=True, stderr=subprocess.DEVNULL
                        ).strip()
                    except Exception:
                        recent_artifact_blob = ''
                    break
    except Exception:
        pass

state = {
    'version': '1',
    'last_stage': skill,
    'last_stage_time_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'worktree_path': pwd,
    'session_id': sid,
    'drift_count': 0,
    'transition_history': history[-50:],
    'recent_artifact_path': recent_artifact,
    'recent_artifact_blob': recent_artifact_blob,
}
json.dump(state, open(tmp, 'w'), indent=2)
PY
mv "$TMP" "$STATE_FILE"

# Reset triggers (v9 per config.mini_state.reset_triggers)
# 1. new_worktree: git worktree add detected in this response
# 2. finishing_branch_pushed: git push + gh pr create/merge detected
# Note: session_switch is implicit (new session_id → new state file)
BASH_CMDS=$(echo "$TXT_AND_USES" | jq -r '.tool_uses[] | select(.name=="Bash") | .input.command' 2>/dev/null || echo "")
RESET=0
if echo "$BASH_CMDS" | grep -qE 'git worktree add'; then
  RESET=1
elif echo "$BASH_CMDS" | grep -qE 'git push' && echo "$BASH_CMDS" | grep -qE 'gh pr (create|merge)'; then
  RESET=1
fi
if [ "$RESET" = "1" ]; then
  # Reset last_stage to _initial for NEXT invocation (current response already updated state above)
  python3 - "$STATE_FILE" <<'PY'
import json, sys, time
sf = sys.argv[1]
try:
    d = json.load(open(sf))
    d['last_stage'] = '_initial'
    d['last_stage_time_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    d.setdefault('transition_history', []).append({'stage': '_initial', 'time': d['last_stage_time_utc'], 'reason': 'reset_trigger'})
    json.dump(d, open(sf, 'w'), indent=2)
except Exception:
    pass
PY
fi

exit 0

#!/usr/bin/env bash
# guard-attest-ledger.sh — PreToolUse Bash hook.
# Enforces attest ledger + override ceremony before Claude-issued
# git push / gh pr create / gh pr merge reaches remote.
# See spec docs/superpowers/specs/2026-04-18-gov-bootstrap-hardening-design.md §2.4
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
. "$SCRIPT_DIR/ledger-lib.sh"

# --- Parse hook input ---
INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))")
CMD=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))")
[ "$TOOL_NAME" = "Bash" ] || exit 0

block() {
    local reason="$1"
    printf '[guard-attest-ledger] BLOCK: %s\n' "$reason" >&2
    exit 2
}

# --- Dispatch by command content (P1-F2: match simple-command substring,
# not just command prefix, to cover wrapped forms like:
#   `command git push`, `env FOO=bar git push`, `git -C . push`,
#   `cd repo && git push`.
# If chained in a form we can't parse, conservatively BLOCK. ---
detect_scenario() {
    local cmd=" $CMD "
    # cd && git push is unparseable (we can't know the working dir) → BLOCK_UNPARSEABLE
    if printf '%s' "$CMD" | grep -qE '^cd[[:space:]]'; then
        if printf '%s' "$CMD" | grep -qE '(git[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+(create|merge))'; then
            printf 'BLOCK_UNPARSEABLE\n'; return
        fi
    fi
    # P1-F2: git push variants
    if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|(]|&&|\|\|)(command[[:space:]]+|env([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+)*[[:space:]]+)?git([[:space:]]+-[A-Za-z]|[[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)'; then
        printf 'A\n'; return
    fi
    # P1-F2: gh pr create variants (gh with optional global flags before "pr create")
    if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|(]|&&|\|\|)(command[[:space:]]+|env([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+)*[[:space:]]+)?gh([[:space:]]+--[a-z-]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
        printf 'B\n'; return
    fi
    # P1-F2: gh pr merge variants
    if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|(]|&&|\|\|)(command[[:space:]]+|env([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+)*[[:space:]]+)?gh([[:space:]]+--[a-z-]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
        printf 'C\n'; return
    fi
    # Substring fallback: contains target verbs but didn't match above → BLOCK_UNPARSEABLE
    if printf '%s' "$cmd" | grep -qE '(git[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+(create|merge))'; then
        printf 'BLOCK_UNPARSEABLE\n'; return
    fi
    printf '\n'
}

SCENARIO=$(detect_scenario)
case "$SCENARIO" in
    A|B|C) ;;
    BLOCK_UNPARSEABLE)
        block "command contains git push / gh pr create / gh pr merge but is chained or wrapped in a form the hook cannot parse. Simplify to a bare command and retry. Raw command was: $CMD"
        ;;
    *) exit 0 ;;
esac

# --- Ledger init (first-run guard: do NOT soft-pass on missing) ---
MISSING_INITIAL=false
if [ ! -f "$LEDGER_PATH" ]; then
    ledger_init_if_missing
    MISSING_INITIAL=true
fi

is_plan_or_spec_file() {
    case "$1" in
        docs/superpowers/plans/*.md|docs/superpowers/specs/*.md) return 0;;
        *) return 1;;
    esac
}

check_file_entries() {
    # args: <ref> <file1> [file2 ...]
    # P1-F3: recognize override entries.
    local ref="$1"; shift
    local violations=""
    local f
    for f in "$@"; do
        is_plan_or_spec_file "$f" || continue
        local current_blob override_blob override_log_line ledger_blob
        current_blob=$(ledger_compute_file_blob_at_ref "$ref" "$f")
        if [ -z "$current_blob" ]; then
            local viol="$f (cannot resolve at $ref)"
            violations="${violations:+$violations
}$viol"
            continue
        fi
        override_blob=$(ledger_get_file_override_blob "$f")
        override_log_line=$(ledger_get_file_override_log_line "$f")
        if [ -n "$override_blob" ] && [ "$override_blob" = "$current_blob" ]; then
            if ledger_validate_audit_log_line "$override_log_line"; then
                printf '[guard-attest-ledger] OVERRIDE IN USE: file:%s (audit log line=%s)\n' "$f" "$override_log_line" >&2
                continue
            else
                local viol2="$f (override audit log line=$override_log_line missing/tampered)"
                violations="${violations:+$violations
}$viol2"
                continue
            fi
        fi
        ledger_blob=$(ledger_get_file_blob "$f")
        if [ -z "$ledger_blob" ] || [ "$ledger_blob" != "$current_blob" ]; then
            local viol3="$f (blob=$current_blob, ledger=$ledger_blob)"
            violations="${violations:+$violations
}$viol3"
        fi
    done
    printf '%s' "$violations"
}

check_branch_entry() {
    # args: <branch> <head_sha> <base>
    # P1-F3: same override recognition for branch entries
    local branch="$1" head="$2" base="$3"
    local fp_current fp_ledger override_head override_log_line
    fp_current=$(ledger_compute_branch_fingerprint "$base" "$head")
    fp_ledger=$(ledger_get_branch_fingerprint "$branch" "$head")
    override_head=$(ledger_get_branch_override_head "$branch" "$head")
    override_log_line=$(ledger_get_branch_override_log_line "$branch" "$head")
    if [ -n "$override_head" ] && [ "$override_head" = "$head" ]; then
        if ledger_validate_audit_log_line "$override_log_line"; then
            printf '[guard-attest-ledger] OVERRIDE IN USE: branch:%s@%s (audit log line=%s)\n' "$branch" "$head" "$override_log_line" >&2
            return 0
        else
            printf 'branch:%s@%s (override audit log line=%s missing/tampered)\n' "$branch" "$head" "$override_log_line"
            return 0
        fi
    fi
    if [ -z "$fp_ledger" ] || [ "$fp_ledger" != "$fp_current" ]; then
        printf 'branch:%s@%s mismatch (current=%s, ledger=%s)\n' "$branch" "$head" "$fp_current" "$fp_ledger"
    fi
}

has_code_change() {
    # args: newline-separated file list string; return 0 if any file is NOT plan/spec
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        is_plan_or_spec_file "$f" || return 0
    done <<FILELIST
$1
FILELIST
    return 1
}

# files_to_args: convert newline file list to positional params, call check_file_entries
check_file_entries_from_list() {
    local ref="$1" files="$2"
    # Use process substitution via temp file for Bash 3.2 compat
    local tmpf
    tmpf=$(mktemp)
    # Build args safely by reading line by line
    local args_str=""
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        args_str="$args_str $f"
    done <<FILELIST
$files
FILELIST
    rm -f "$tmpf"
    if [ -z "$args_str" ]; then
        printf ''
        return
    fi
    # eval is needed to expand filenames as separate args; filenames won't have spaces
    # (git paths with spaces would need escaping, but plan files don't)
    eval "check_file_entries \"\$ref\" $args_str"
}

# --- Scenario A: git push ---
scenario_A() {
    # Parse refspec: `git push [options] [remote] [src[:dst]]`
    local SRC_BRANCH
    # Handle bare `git push` → current branch
    if printf '%s' "$CMD" | grep -qE '^(env[[:space:]]+[^[:space:]]+=.*[[:space:]]+)?(command[[:space:]]+)?git push[[:space:]]*$'; then
        SRC_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    else
        # Find last word that is not a flag; if contains `:`, take left side
        # H2-4: skip shell redirect/operator tokens + keywords + flags + redirect targets
        SRC_BRANCH=$(printf '%s' "$CMD" | awk '{
            for(i=NF;i>0;i--){
                tok=$i
                if(tok=="2>&1"||tok==">&"||tok=="&>"||tok==">"||tok=="<"||tok=="|"||tok=="&&"||tok=="||"||tok==";") continue
                if(tok=="origin"||tok=="push"||tok=="git"||tok=="command"||tok=="."||tok=="env") continue
                if(substr(tok,1,1)=="-") continue
                if(tok ~ /^[0-9]*>&?[0-9]*$/) continue
                if(tok ~ /^\/(tmp|var|dev|proc)\//) continue
                print tok; exit
            }
        }')
        [ -z "$SRC_BRANCH" ] && SRC_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        # Strip src:dst → src only
        SRC_BRANCH="${SRC_BRANCH%%:*}"
        # Handle HEAD literal
        [ "$SRC_BRANCH" = "HEAD" ] && SRC_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        # Strip flags that slipped through (-u, --force, etc.)
        case "$SRC_BRANCH" in
            -*)
                SRC_BRANCH=$(git rev-parse --abbrev-ref HEAD)
                ;;
        esac
        # Strip env assignments that slipped through (FOO=bar)
        case "$SRC_BRANCH" in
            *=*)
                SRC_BRANCH=$(git rev-parse --abbrev-ref HEAD)
                ;;
        esac
    fi

    # Handle git -C <dir> push: adjust working dir context isn't needed since
    # hook runs from repo root anyway; just ensure SRC_BRANCH resolved above.

    # Compute commits-to-push file list
    local upstream base_ref
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>/dev/null || true)
    if [ -n "$upstream" ]; then
        base_ref="$upstream"
    else
        base_ref="origin/main"
        printf '[guard-attest-ledger] WARN: no tracked upstream; falling back to origin/main\n' >&2
    fi

    local files
    files=$(git diff --name-only "${base_ref}..${SRC_BRANCH}" 2>/dev/null) || {
        block "cannot compute diff ${base_ref}..${SRC_BRANCH}"
    }

    local file_violations
    file_violations=$(check_file_entries_from_list "$SRC_BRANCH" "$files")

    # Branch-diff check (R2-F1: required for ALL pushes with any file changes)
    local branch_violation=""
    if [ -n "$files" ]; then
        local head_sha
        head_sha=$(git rev-parse "$SRC_BRANCH")
        branch_violation=$(check_branch_entry "$SRC_BRANCH" "$head_sha" "$base_ref")
    fi

    if [ -n "$file_violations" ] || [ -n "$branch_violation" ]; then
        local msg="unattested items in push:"
        [ -n "$file_violations" ] && msg="$msg
  plan/spec:
$file_violations"
        [ -n "$branch_violation" ] && msg="$msg
  branch:
$branch_violation"
        if $MISSING_INITIAL; then
            msg="$msg
  (ledger 首次初始化 / first-run; 请先跑 codex-attest 再重试 / run codex-attest first)"
        else
            msg="$msg
  跑: .claude/scripts/codex-attest.sh --scope working-tree --focus <file>
  或: .claude/scripts/codex-attest.sh --scope branch-diff --head ${SRC_BRANCH} --base ${base_ref}"
        fi
        block "$msg"
    fi
    exit 0
}

# --- Scenario B: gh pr create ---
scenario_B() {
    local head base
    head=$(printf '%s' "$CMD" | grep -oE -- '--head[[:space:]]+[^[:space:]]+' 2>/dev/null | awk '{print $2}' || true)
    [ -z "$head" ] && head=$(git rev-parse --abbrev-ref HEAD)
    base=$(printf '%s' "$CMD" | grep -oE -- '--base[[:space:]]+[^[:space:]]+' 2>/dev/null | awk '{print $2}' || true)
    [ -z "$base" ] && base="main"

    local head_sha
    head_sha=$(git rev-parse "$head" 2>/dev/null) || block "cannot resolve head '$head'"

    # Independent PR diff (R3-F3)
    local files
    files=$(git diff --name-only "origin/${base}...${head_sha}" 2>/dev/null) || block "cannot compute PR diff origin/${base}...${head_sha}"

    local file_violations
    file_violations=$(check_file_entries_from_list "$head_sha" "$files")

    local branch_violation
    branch_violation=$(check_branch_entry "$head" "$head_sha" "origin/$base")

    if [ -n "$file_violations" ] || [ -n "$branch_violation" ]; then
        local msg="unattested items in PR:"
        [ -n "$file_violations" ] && msg="$msg
  plan/spec:
$file_violations"
        [ -n "$branch_violation" ] && msg="$msg
  branch:
$branch_violation"
        msg="$msg
  跑: .claude/scripts/codex-attest.sh --scope branch-diff --head ${head} --base origin/${base}"
        block "$msg"
    fi
    exit 0
}

# --- Scenario C: gh pr merge ---
scenario_C() {
    # R2-F3: require --match-head-commit — check FIRST (before calling gh pr view)
    # so the guard fails fast without needing network/auth when the arg is absent.
    local match_arg
    match_arg=$(printf '%s' "$CMD" | grep -oE -- '--match-head-commit[[:space:]]+[^[:space:]]+' 2>/dev/null | awk '{print $2}' || true)
    if [ -z "$match_arg" ]; then
        block "gh pr merge requires --match-head-commit <SHA> to avoid head-SHA race"
    fi

    # Extract target PR number (first non-flag arg after "gh pr merge")
    # Handle `gh --repo foo/bar pr merge 42` and plain `gh pr merge 42`
    local target
    target=$(printf '%s' "$CMD" | sed -nE 's|.*pr[[:space:]]+merge[[:space:]]+([0-9]+).*|\1|p' || true)

    local view_json
    if [ -n "$target" ]; then
        view_json=$(gh pr view "$target" --json headRefName,headRefOid,baseRefName 2>/dev/null) || block "gh pr view $target failed"
    else
        view_json=$(gh pr view --json headRefName,headRefOid,baseRefName 2>/dev/null) || block "gh pr view (current) failed"
    fi

    local head_ref head_oid base_ref
    head_ref=$(printf '%s' "$view_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['headRefName'])")
    head_oid=$(printf '%s' "$view_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['headRefOid'])")
    base_ref=$(printf '%s' "$view_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['baseRefName'])")

    if [ "$match_arg" != "$head_oid" ]; then
        block "match-head-commit mismatch: arg=$match_arg vs PR head=$head_oid"
    fi

    # File and branch checks (independent PR diff)
    local files
    files=$(git diff --name-only "origin/${base_ref}...${head_oid}" 2>/dev/null) || block "cannot compute merge diff origin/${base_ref}...${head_oid}"

    local file_violations
    file_violations=$(check_file_entries_from_list "$head_oid" "$files")

    local branch_violation
    branch_violation=$(check_branch_entry "$head_ref" "$head_oid" "origin/$base_ref")

    if [ -n "$file_violations" ] || [ -n "$branch_violation" ]; then
        local msg="unattested items in merge target:"
        [ -n "$file_violations" ] && msg="$msg
  plan/spec:
$file_violations"
        [ -n "$branch_violation" ] && msg="$msg
  branch:
$branch_violation"
        block "$msg"
    fi
    exit 0
}

# H3-2 a3: drift ceiling check (block push when too many unacked skill-gate drifts)
DRIFT_LOG=".claude/state/skill-gate-drift.jsonl"
CURSOR_FILE=".claude/state/skill-gate-push-cursor.txt"
DRIFT_PUSH_THRESHOLD="${DRIFT_PUSH_THRESHOLD:-5}"
current_drift_count=$([ -f "$DRIFT_LOG" ] && wc -l < "$DRIFT_LOG" | tr -d ' ' || echo 0)
drift_cursor=$([ -f "$CURSOR_FILE" ] && cat "$CURSOR_FILE" | tr -d ' \n' || echo 0)
case "$drift_cursor" in
    ''|*[!0-9]*) drift_cursor=0 ;;
esac
new_drift=$((current_drift_count - drift_cursor))
if [ "$new_drift" -gt "$DRIFT_PUSH_THRESHOLD" ] && [ "${DRIFT_PUSH_OVERRIDE:-0}" != "1" ]; then
    block "Skill-gate drift since last push = $new_drift (> threshold $DRIFT_PUSH_THRESHOLD). Run .claude/scripts/ack-drift.sh in a real tty to acknowledge and advance cursor; or set DRIFT_PUSH_OVERRIDE=1 in your own shell (NOT Claude's Bash tool) to bypass once."
fi

case "$SCENARIO" in
    A) scenario_A ;;
    B) scenario_B ;;
    C) scenario_C ;;
esac

#!/usr/bin/env bash
# ledger-lib.sh — shared helpers for attest ledger + override log.
# Sourced (not executed directly) by hook + codex-attest.sh + attest-override.sh.

# All functions operate relative to repo root (cwd).
: "${LEDGER_PATH:=.claude/state/attest-ledger.json}"
: "${OVERRIDE_LOG_PATH:=.claude/state/attest-override-log.jsonl}"

ledger_init_if_missing() {
    if [ ! -f "$LEDGER_PATH" ]; then
        mkdir -p "$(dirname "$LEDGER_PATH")"
        printf '%s\n' '{"version":1,"entries":{}}' > "$LEDGER_PATH"
    fi
}

ledger_file_key() {
    # $1 = relative path
    printf 'file:%s\n' "$1"
}

ledger_branch_key() {
    # $1 = branch name, $2 = head sha
    printf 'branch:%s@%s\n' "$1" "$2"
}

ledger_write_file() {
    # args: <relpath> <blob_sha> <attest_time_utc> <verdict_digest> <codex_round>
    local key; key=$(ledger_file_key "$1")
    ledger_init_if_missing
    python3 - "$LEDGER_PATH" "$key" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
p, key, blob, t, digest, rnd = sys.argv[1:7]
d = json.load(open(p))
d["entries"][key] = {
    "kind": "file",
    "blob_sha": blob,
    "attest_time_utc": t,
    "verdict_digest": digest,
    "codex_round": int(rnd),
}
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
}

ledger_write_branch() {
    # args: <branch> <head_sha> <base> <diff_fingerprint> <attest_time_utc> <verdict_digest> <codex_round>
    local key; key=$(ledger_branch_key "$1" "$2")
    ledger_init_if_missing
    python3 - "$LEDGER_PATH" "$key" "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import json, sys
p, key, branch, head, base, fp, t, digest, rnd = sys.argv[1:10]
d = json.load(open(p))
d["entries"][key] = {
    "kind": "branch",
    "branch": branch,
    "head_sha": head,
    "base": base,
    "diff_fingerprint": fp,
    "attest_time_utc": t,
    "verdict_digest": digest,
    "codex_round": int(rnd),
}
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
}

ledger_get_file_blob() {
    # $1 = relpath; prints blob_sha or empty string if missing
    [ -f "$LEDGER_PATH" ] || return 0
    python3 - "$LEDGER_PATH" "$1" <<'PY'
import json, sys
p, relpath = sys.argv[1:3]
try:
    d = json.load(open(p))
except Exception:
    print("")
    sys.exit(0)
e = d.get("entries", {}).get(f"file:{relpath}")
print(e.get("blob_sha", "") if e else "")
PY
}

ledger_get_branch_fingerprint() {
    # args: <branch> <head_sha>; prints diff_fingerprint or empty
    [ -f "$LEDGER_PATH" ] || return 0
    python3 - "$LEDGER_PATH" "$1" "$2" <<'PY'
import json, sys
p, branch, head = sys.argv[1:4]
try:
    d = json.load(open(p))
except Exception:
    print("")
    sys.exit(0)
e = d.get("entries", {}).get(f"branch:{branch}@{head}")
print(e.get("diff_fingerprint", "") if e else "")
PY
}

ledger_compute_file_blob_at_ref() {
    # args: <ref> <relpath>; prints blob sha from git ls-tree
    git ls-tree "$1" -- "$2" 2>/dev/null | awk '{print $3}'
}

ledger_compute_branch_fingerprint() {
    # args: <base-ref> <head-ref>; prints sha256 of canonical diff
    local diff_output
    diff_output=$(git diff --no-color --no-ext-diff "$1...$2" 2>/dev/null) || return 1
    local sha
    sha=$(printf '%s' "$diff_output" | shasum -a 256 | awk '{print $1}')
    printf 'sha256:%s\n' "$sha"
}

# P1-F3: override entry accessors (guard uses these to honor attest-override.sh)
ledger_get_file_override_blob() {
    # $1 = relpath; prints blob_or_head_sha_at_override if entry is override, else empty
    [ -f "$LEDGER_PATH" ] || return 0
    python3 - "$LEDGER_PATH" "$1" <<'PY'
import json, sys
p, rel = sys.argv[1:3]
try: d=json.load(open(p))
except Exception: print(""); sys.exit(0)
e=d.get("entries",{}).get(f"file:{rel}")
print(e.get("blob_or_head_sha_at_override","") if (e and e.get("override")) else "")
PY
}

ledger_get_file_override_log_line() {
    [ -f "$LEDGER_PATH" ] || return 0
    python3 - "$LEDGER_PATH" "$1" <<'PY'
import json, sys
p, rel = sys.argv[1:3]
try: d=json.load(open(p))
except Exception: print(""); sys.exit(0)
e=d.get("entries",{}).get(f"file:{rel}")
print(str(e.get("audit_log_line","")) if (e and e.get("override")) else "")
PY
}

ledger_get_branch_override_head() {
    # args: <branch> <head_sha>
    [ -f "$LEDGER_PATH" ] || return 0
    python3 - "$LEDGER_PATH" "$1" "$2" <<'PY'
import json, sys
p, branch, head = sys.argv[1:4]
try: d=json.load(open(p))
except Exception: print(""); sys.exit(0)
e=d.get("entries",{}).get(f"branch:{branch}@{head}")
print(e.get("blob_or_head_sha_at_override","") if (e and e.get("override")) else "")
PY
}

ledger_get_branch_override_log_line() {
    [ -f "$LEDGER_PATH" ] || return 0
    python3 - "$LEDGER_PATH" "$1" "$2" <<'PY'
import json, sys
p, branch, head = sys.argv[1:4]
try: d=json.load(open(p))
except Exception: print(""); sys.exit(0)
e=d.get("entries",{}).get(f"branch:{branch}@{head}")
print(str(e.get("audit_log_line","")) if (e and e.get("override")) else "")
PY
}

ledger_validate_audit_log_line() {
    # $1 = claimed line number; returns 0 if the audit log has at least that many lines
    local claimed="$1"
    [ -z "$claimed" ] && return 1
    [ -f "$OVERRIDE_LOG_PATH" ] || return 1
    local actual
    actual=$(wc -l < "$OVERRIDE_LOG_PATH" | tr -d ' ')
    [ "$claimed" -le "$actual" ]
}

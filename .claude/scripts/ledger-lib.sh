#!/usr/bin/env bash
# ledger-lib.sh — shared helpers for attest ledger + override log.
# Sourced (not executed directly) by hook + codex-attest.sh + attest-override.sh.

# All functions operate relative to repo root (cwd).
: "${LEDGER_PATH:=.claude/state/attest-ledger.json}"
: "${OVERRIDE_LOG_PATH:=.claude/state/attest-override-log.jsonl}"

# Every ledger writer must serialize through this. A lock held by only one call site
# is not serialization: the override path could read before another writer's replace
# and write after its read-back, silently dropping an attestation.
: "${LEDGER_LOCK_PATH:=$(dirname "$LEDGER_PATH")/.ledger.lock}"

ledger_lock_acquire() {
    mkdir -p "$(dirname "$LEDGER_LOCK_PATH")"
    local waited=0
    until mkdir "$LEDGER_LOCK_PATH" 2>/dev/null; do
        # Recover a lock whose owner is gone. Without this a killed writer wedges the
        # attestation gate permanently rather than for one timeout.
        local owner
        owner=$(cat "$LEDGER_LOCK_PATH/owner" 2>/dev/null || true)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            echo "[ledger] recovering lock orphaned by dead pid $owner" >&2
            rm -rf "$LEDGER_LOCK_PATH" 2>/dev/null || true
            continue
        fi
        waited=$((waited+1))
        if [ "$waited" -ge 300 ]; then
            echo "[ledger] ERROR: timed out waiting for $LEDGER_LOCK_PATH" >&2
            return 1
        fi
        sleep 0.2
    done
    printf '%s' "$$" > "$LEDGER_LOCK_PATH/owner" 2>/dev/null || true
}

ledger_lock_release() {
    if [ "$(cat "$LEDGER_LOCK_PATH/owner" 2>/dev/null)" = "$$" ]; then
        rm -rf "$LEDGER_LOCK_PATH" 2>/dev/null || true
    fi
}

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
    # args: <branch> <head_sha> <base_ref> <base_sha> <diff_fingerprint> <attest_time_utc> <verdict_digest> <codex_round> [reviewer]
    # base_sha is the frozen revision actually reviewed. Storing only the ref name would
    # let two reviews of the same head against different bases collide on one key, and
    # would leave the ledger unable to prove which base revision the verdict describes.
    #
    # reviewer identifies WHICH engine issued the verdict, as "<engine>/<version>".
    # More than one engine can now write here (codex-attest.sh, kimi-attest.sh), and
    # they are not equally trustworthy, so an entry that does not say who approved it
    # cannot be audited later. Optional so existing callers keep working; it records
    # "unspecified" rather than guessing, because a wrong attribution is worse than an
    # absent one. Entries written before this field simply lack it.
    local key; key=$(ledger_branch_key "$1" "$2")
    local reviewer="${9:-unspecified}"
    ledger_init_if_missing
    python3 - "$LEDGER_PATH" "$key" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$reviewer" <<'PY'
import json, os, sys, tempfile
p, key, branch, head, base, base_sha, fp, t, digest, rnd, reviewer = sys.argv[1:12]
d = json.load(open(p))
d["entries"][key] = {
    "kind": "branch",
    "branch": branch,
    "head_sha": head,
    "base": base,
    "base_sha": base_sha,
    "diff_fingerprint": fp,
    "attest_time_utc": t,
    "verdict_digest": digest,
    "codex_round": int(rnd),
    "reviewer": reviewer,
}
# Atomic: a crash mid-write must not leave a truncated ledger. Callers additionally
# serialize with a lock, which this does not replace.
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p) or ".", prefix=".ledger.")
with os.fdopen(fd, "w") as fh:
    json.dump(d, fh, indent=2, sort_keys=True)
    fh.flush()
    os.fsync(fh.fileno())
os.replace(tmp, p)
# A rename is not durable until the parent directory is fsynced: without this a crash
# after the caller printed success can still lose the entry.
dfd = os.open(os.path.dirname(os.path.abspath(p)), os.O_RDONLY)
try:
    os.fsync(dfd)
finally:
    os.close(dfd)
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
# Report fingerprint and base together so a caller cannot confirm a write while the
# stored entry describes a different base revision.
print(f"{e.get('diff_fingerprint','')}|{e.get('base_sha','')}" if e else "")
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

# File-scoped counterpart to ledger_get_branch_override_digest. Upstream only needed the
# branch form because its attest path refuses file targets outright; this repo still
# carries file-scoped override entries, and without this getter the guard hook could
# only check that the audit log is long enough -- a check that a rewritten log line
# passes unchanged. Missing digest prints empty, and the caller fails closed.
ledger_get_file_override_digest() {
    [ -f "$LEDGER_PATH" ] || return 0
    python3 - "$LEDGER_PATH" "$1" <<'PY'
import json, sys
p, rel = sys.argv[1:3]
try: d=json.load(open(p))
except Exception: print(""); sys.exit(0)
e=d.get("entries",{}).get(f"file:{rel}")
print(e.get("audit_entry_digest","") if (e and e.get("override")) else "")
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

ledger_validate_audit_entry() {
    # args: <claimed line number> <expected sha256 digest of that exact line>
    # Counting lines proves only that the file is long enough. If the cited line is
    # edited, truncated or replaced after the ledger entry was written, a count check
    # still passes, so the ledger would not actually bind the override it claims. Read
    # the exact line and recompute its digest instead. Fails closed on anything missing.
    local claimed="$1" expected="$2" line actual
    [ -n "$claimed" ] && [ -n "$expected" ] || return 1
    [ -f "$OVERRIDE_LOG_PATH" ] || return 1
    line=$(sed -n "${claimed}p" "$OVERRIDE_LOG_PATH" 2>/dev/null) || return 1
    [ -n "$line" ] || return 1
    actual="sha256:$(printf %s "$line" | shasum -a 256 | awk '{print $1}')"
    [ "$actual" = "$expected" ]
}

ledger_get_branch_override_digest() {
    # args: <branch> <head_sha>; prints the recorded audit-entry digest
    [ -f "$LEDGER_PATH" ] || return 0
    python3 - "$LEDGER_PATH" "$1" "$2" <<'DIGESTPY'
import json, sys
p, branch, head = sys.argv[1:4]
try: d=json.load(open(p))
except Exception: print(""); sys.exit(0)
e=d.get("entries",{}).get(f"branch:{branch}@{head}")
print(e.get("audit_entry_digest","") if (e and e.get("override")) else "")
DIGESTPY
}

ledger_get_branch_override_base() {
    # args: <branch> <head_sha>; prints the base_sha an override was granted against
    [ -f "$LEDGER_PATH" ] || return 0
    python3 - "$LEDGER_PATH" "$1" "$2" <<'LEDGERPY'
import json, sys
p, branch, head = sys.argv[1:4]
try: d=json.load(open(p))
except Exception: print(""); sys.exit(0)
e=d.get("entries",{}).get(f"branch:{branch}@{head}")
print(e.get("base_sha","") if (e and e.get("override")) else "")
LEDGERPY
}

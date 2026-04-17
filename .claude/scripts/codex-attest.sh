#!/usr/bin/env bash
# codex-attest.sh
# Local wrapper around codex-companion adversarial-review for spec/plan stage.
# Used ONLY when no PR exists yet (brainstorming or writing-plans stages).
# At PR stage, GitHub Actions is authoritative; this wrapper is best-effort first-layer.
set -euo pipefail

DRY_RUN=false
SCOPE="working-tree"
FOCUS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --head-sha)
      echo "[codex-attest] ERROR: head SHA auto-computed, do not pass --head-sha" >&2
      exit 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --focus) FOCUS="$2"; shift 2 ;;
    --target) shift 2 ;;
    *) FOCUS="$FOCUS $1"; shift ;;
  esac
done

# Pin check
CODEX_PATH="$HOME/.claude/plugins/cache/openai-codex/codex/1.0.3/scripts/codex-companion.mjs"
if [ ! -f "$CODEX_PATH" ]; then
  echo "[codex-attest] ERROR: codex-companion.mjs not at pinned path $CODEX_PATH" >&2
  exit 3
fi

PIN_FILE=".claude/scripts/codex-companion.sha256"
if [ -f "$PIN_FILE" ]; then
  expected=$(cat "$PIN_FILE")
  actual=$(shasum -a 256 "$CODEX_PATH" | awk '{print $1}')
  if [ "$expected" != "$actual" ]; then
    echo "[codex-attest] ERROR: codex-companion sha256 mismatch. expected=$expected actual=$actual" >&2
    exit 4
  fi
fi

HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "untracked")
echo "[codex-attest] auto HEAD=$HEAD_SHA  scope=$SCOPE"
echo "[codex-attest] invoking codex-companion"

if $DRY_RUN; then
  echo "[codex-attest] DRY RUN - would execute: node $CODEX_PATH adversarial-review --wait --scope $SCOPE $FOCUS"
  exit 0
fi

exec node "$CODEX_PATH" adversarial-review --wait --scope "$SCOPE" $FOCUS

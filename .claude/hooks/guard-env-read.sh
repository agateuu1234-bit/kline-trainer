#!/usr/bin/env bash
# guard-env-read.sh
# H3-1: PreToolUse hook for Read/Edit/Write tools. Fail-closed deny any
# file whose basename matches .env* unless in the sample allow-list.
# Replaces hardening-2's 35-line enumeration (which missed compound suffixes).
set -eo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))")

# Only gate Read/Edit/Write
case "$TOOL_NAME" in
    Read|Edit|Write) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))")
if [ -z "$FILE_PATH" ]; then
    echo "[guard-env-read] BLOCK: $TOOL_NAME with empty file_path (malformed)" >&2
    exit 2
fi

BASENAME=$(basename "$FILE_PATH")

# Not an env file -> pass
case "$BASENAME" in
    .env|.env.*) ;;
    *) exit 0 ;;
esac

# Sample allow-list
case "$BASENAME" in
    .env.example|.env.sample|.env.template|.env.dist)
        echo "[guard-env-read] PASS: $BASENAME (sample file)" >&2
        exit 0 ;;
esac

# Real env file -> deny
echo "[guard-env-read] BLOCK: $TOOL_NAME on $FILE_PATH -- env files with real secrets are not readable/writable by Claude tools" >&2
echo "  Allow-list (always passes): .env.example, .env.sample, .env.template, .env.dist" >&2
exit 2

#!/usr/bin/env bash
# Task 2a: verify .claude/settings.json has minimal deny expansion
# (GitHub-write + HTTP + shell bypass; NOT .claude/** edit yet — those in Task 2b)
set -euo pipefail

python3 - <<'PY'
import json, sys
d = json.load(open('.claude/settings.json'))
deny = d['permissions']['deny']

# Must have these rules (Task 2a expanded set)
required = [
    "Bash(gh api graphql*)",
    "Bash(gh api * -X POST*)",
    "Bash(gh pr comment:*)",
    "Bash(gh workflow run*)",
    "Bash(gh secret *)",
    "Bash(curl * github.com*)",
    "Bash(bash -c *)",
    "Bash(sudo *)",
    "Bash(node */codex-companion.mjs*)",
]
missing = [r for r in required if r not in deny]
if missing:
    print(f'FAIL missing Task 2a rules: {missing}')
    sys.exit(1)

# MUST NOT have (those are Task 2b final expansion)
forbidden_now = [
    "Edit(.claude/hooks/**)",
    "Edit(.claude/workflow-rules.json)",
    "Edit(CLAUDE.md)",
    "Edit(.github/workflows/**)",
]
present_too_early = [r for r in forbidden_now if r in deny]
if present_too_early:
    print(f'FAIL too early (Task 2b territory): {present_too_early}')
    sys.exit(1)

print(f'PASS: minimal deny has all Task 2a rules, no Task 2b rules yet')
PY

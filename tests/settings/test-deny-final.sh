#!/usr/bin/env bash
# Task 2b: verify final deny expansion locks .claude/** .github/** CLAUDE.md codex.pin.json edits
set -euo pipefail
python3 - <<'PY'
import json, sys
d = json.load(open('.claude/settings.json'))
deny = d['permissions']['deny']
required = [
    "Edit(.claude/hooks/**)", "Write(.claude/hooks/**)",
    "Edit(.claude/scripts/**)", "Write(.claude/scripts/**)",
    "Edit(.claude/workflow-rules.json)", "Write(.claude/workflow-rules.json)",
    "Edit(.claude/state/**)", "Write(.claude/state/**)",
    "Edit(.github/workflows/**)", "Write(.github/workflows/**)",
    "Edit(.github/CODEOWNERS)", "Write(.github/CODEOWNERS)",
    "Edit(CLAUDE.md)", "Write(CLAUDE.md)",
    "Edit(codex.pin.json)", "Write(codex.pin.json)",
    "Write(~/.claude/plugins/cache/openai-codex/**)",
    "Edit(~/.claude/plugins/cache/openai-codex/**)",
    "Bash(* >> .claude/state*)",
    "Bash(* >> .claude/hooks*)",
    "Bash(* >> .github/workflows*)",
    "Bash(tee * .claude/*)",
    "Bash(sed -i * .claude/*)",
    "Bash(rm * .claude/*)",
    "Bash(chmod * .claude/*)",
]
missing = [r for r in required if r not in deny]
if missing:
    for m in missing: print(f'FAIL missing: {m}')
    sys.exit(1)
# bootstrap-lock.json must NOT be denied (R5.3 · intentional)
if 'Edit(.github/bootstrap-lock.json)' in deny:
    print('FAIL: .github/bootstrap-lock.json should NOT be denied (R5.3)')
    sys.exit(1)
print(f'PASS: {len(required)} final-deny rules present; bootstrap-lock.json correctly unrestricted')
PY

#!/usr/bin/env bash
# Verify that codeowners_required_globs is a strict subset of trust_boundary_globs
# AND does not include broad business-code globs.
set -euo pipefail

RULES=".claude/workflow-rules.json"
if [ ! -f "$RULES" ]; then
  echo "FAIL: $RULES not found"
  exit 1
fi

python3 - "$RULES" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
required = d.get('codeowners_required_globs', [])
tb = set(d['trust_boundary_globs'])

errors = []

for g in required:
    if g not in tb:
        errors.append(f'{g} in codeowners_required_globs but not in trust_boundary_globs')

forbidden = ['src/**', 'ios/**/*.swift', '**/*.py', '**/*.ts', '**/*.tsx']
for g in required:
    if g in forbidden:
        errors.append(f'business-code glob {g} in codeowners_required_globs; move out')

canon = d.get('canonical_codeowner')
if not canon:
    errors.append('canonical_codeowner missing')
elif not canon.startswith('@'):
    errors.append(f'canonical_codeowner must start with @; got {canon}')

if errors:
    for e in errors:
        print(f'FAIL: {e}')
    sys.exit(1)
print(f'PASS: codeowners_required_globs valid ({len(required)} entries, canonical_codeowner={canon})')
PY

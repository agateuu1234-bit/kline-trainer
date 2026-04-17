#!/usr/bin/env bash
# Verify that every tracked file in the repo is covered by
# trust_boundary_globs OR trust_boundary_whitelist in workflow-rules.json.
set -euo pipefail

RULES=".claude/workflow-rules.json"
if [ ! -f "$RULES" ]; then
  echo "FAIL: $RULES not found"
  exit 1
fi

python3 - "$RULES" <<'PY'
import json, pathlib, fnmatch, subprocess, sys
rules_path = sys.argv[1]
d = json.load(open(rules_path))
whitelist = d.get('trust_boundary_whitelist', [])
globs = d['trust_boundary_globs']
files = subprocess.check_output(['git','ls-files']).decode().splitlines()
uncovered = []
for f in files:
    if any(fnmatch.fnmatch(f, w) for w in whitelist):
        continue
    matched = False
    for g in globs:
        if fnmatch.fnmatch(f, g) or pathlib.PurePath(f).match(g):
            matched = True
            break
    if not matched:
        uncovered.append(f)
if uncovered:
    print('FAIL: uncovered files:')
    for u in uncovered[:20]:
        print(f'  {u}')
    if len(uncovered) > 20:
        print(f'  ... and {len(uncovered)-20} more')
    sys.exit(1)
print(f'PASS: all {len(files)} tracked files covered')
PY

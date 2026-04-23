#!/usr/bin/env bash
# Hardening-6 框架验收（H6.0 Task 8）
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0; declare -a FAILED
run() {
  local label="$1"; shift
  echo ""; echo "========== $label =========="
  if "$@"; then echo "OK: $label"; PASS=$((PASS+1))
  else echo "NG: $label"; FAIL=$((FAIL+1)); FAILED+=("$label"); fi
}

# ---- Files 存在 + 可执行 ----
run "file: config"   test -s .claude/config/skill-invoke-enforced.json
run "file: new hook" test -x .claude/hooks/skill-invoke-check.sh
# v10 R9 F3: state dir/drift log are runtime artifacts (ignored by git);
# check .gitignore covers them instead of requiring file existence
run "gitignore: state dir covered" \
  bash -c "git check-ignore -q .claude/state/skill-stage/test.json || test -d .claude/state/skill-stage"
run "gitignore: drift log covered" \
  bash -c "git check-ignore -q .claude/state/skill-invoke-drift.jsonl || test -f .claude/state/skill-invoke-drift.jsonl"

# ---- Config schema ----
run "config: 14 skill"     bash -c "[ \"\$(jq '.enforce | length' .claude/config/skill-invoke-enforced.json)\" = '14' ]"
# v48 Task 1 implementer fix: legal_next_set has 12 non-wildcard skills (INCLUDING systematic-debugging) + _initial = 13 keys
# (using-superpowers / dispatching-parallel-agents are state-less wildcards)
run "config: legal_next_set 13 keys (12 non-wildcard skills + _initial)" bash -c "[ \"\$(jq '.mini_state.legal_next_set | length' .claude/config/skill-invoke-enforced.json)\" = '13' ]"
run "config: state-aware wildcards (systematic-debugging) + non-wildcards all covered by legal_next_set" \
  bash -c "diff <(jq -r '(.enforce | keys) - [\"superpowers:using-superpowers\", \"superpowers:dispatching-parallel-agents\"] | .[]' .claude/config/skill-invoke-enforced.json | sort) <(jq -r '.mini_state.legal_next_set | keys[] | select(. != \"_initial\")' .claude/config/skill-invoke-enforced.json | sort)"
run "config: codex entry exists"    bash -c "jq -e '.enforce[\"codex:adversarial-review\"]' .claude/config/skill-invoke-enforced.json > /dev/null"

# ---- settings.json wired ----
run "settings: skill-invoke-check wired" \
  bash -c "jq -e '.hooks.Stop | map(.hooks[]?.command) | flatten | any(. | contains(\"skill-invoke-check\"))' .claude/settings.json > /dev/null"

# ---- workflow-rules enforcement_mode (v34 R33 F3 + v35 R35 F1 fix) ----
# Task 1-8 runs in bootstrap mode where enforcement_mode is still drift-log
# (Task 9 flip is deliberately the last commit). If we hard-required block
# here, Task 8 acceptance could NEVER pass → push 开发者改破窗绕开。
# Split: default mode accepts drift-log OR block; --final (pre-merge/CI)
# requires block. Task 8 calls default; CI workflow passes --final.
FINAL_MODE=0
for a in "$@"; do [ "$a" = "--final" ] && FINAL_MODE=1; done
if [ "$FINAL_MODE" = "1" ]; then
  run "rules: enforcement_mode == block (pre-merge gate; Task 9 flip 必须已完成)" \
    bash -c "jq -e '.skill_gate_policy.enforcement_mode == \"block\"' .claude/workflow-rules.json > /dev/null"
else
  run "rules: enforcement_mode ∈ {drift-log, block} (bootstrap mode)" \
    bash -c "jq -re '.skill_gate_policy.enforcement_mode' .claude/workflow-rules.json | grep -qE '^(drift-log|block)$'"
fi

# ---- Unit tests ----
# v9 R8 F3 fix: preserve pytest exit via -o pipefail; output capture separate
run "unit: test_stop_response_check" \
  bash -o pipefail -c "python3 -m pytest tests/hooks/test_stop_response_check.py -q > /tmp/pytest-stop.log 2>&1; ec=\$?; tail -3 /tmp/pytest-stop.log; exit \$ec"
run "unit: test_skill_invoke_check" \
  bash -o pipefail -c "python3 -m pytest tests/hooks/test_skill_invoke_check.py -q > /tmp/pytest-invoke.log 2>&1; ec=\$?; tail -3 /tmp/pytest-invoke.log; exit \$ec"

# ---- Regression ----
# v46 R46 F2 fix: regression scripts must emit their exact success sentinel.
# Previously only exit code was checked; a script that internally skipped
# or caught failures while returning 0 would pass acceptance. Now we
# require the sentinel line to appear in the captured log.
run "regression: Plan 1 DDL" \
  bash -c "./scripts/acceptance/plan_1_m0_1_db_schema.sh > /tmp/p1.log 2>&1 && grep -Fxq 'PLAN 1 PASS' /tmp/p1.log"
run "regression: Plan 1f schema versioning" \
  bash -c "./scripts/acceptance/plan_1f_m0_1_schema_versioning.sh > /tmp/p1f.log 2>&1 && grep -Fxq 'PLAN 1f PASS' /tmp/p1f.log"

echo ""; echo "============================================"
echo "Hardening-6 framework acceptance: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed items:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  echo "HARDENING 6 FAIL"; exit 1
fi
echo "HARDENING 6 PASS"

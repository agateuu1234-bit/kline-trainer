#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIX="$ROOT/tests/scripts/governance/fixtures"
V="$ROOT/scripts/governance/verify-required-checks.sh"
fail=0
check() { # desc expected_rc actual_rc
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected rc=$2 got $3)"; fail=1; fi
}

# assert：happy fixture → 0
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-with-check.json" >/dev/null 2>&1; rc=$?; set -e
check "assert happy → 0" 0 "$rc"

# assert：缺 check → 1
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-without-check.json" >/dev/null 2>&1; rc=$?; set -e
check "assert missing → 1" 1 "$rc"

# assert：any-source（无 integration_id）→ 1（防伪造）
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-anysource.json" >/dev/null 2>&1; rc=$?; set -e
check "assert anysource → 1" 1 "$rc"

# preflight：happy → 0
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-with-check.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight happy → 0" 0 "$rc"

# preflight：无 rsc 规则 → 1（谓词为假，fail-closed）
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-no-rsc.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight no-rsc → 1" 1 "$rc"

# preflight：malformed JSON → 3（观测失败，非谓词假——R3-F1）
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-malformed.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight malformed → 3" 3 "$rc"

# R3-F3：错 scope ruleset 离线也被拒（防误认证 H10 证据）
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-tag.json" >/dev/null 2>&1; rc=$?; set -e
check "assert target=tag → 1" 1 "$rc"
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-tag.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight target=tag → 1" 1 "$rc"
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-wrongname.json" >/dev/null 2>&1; rc=$?; set -e
check "assert name!=main → 1" 1 "$rc"
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-wrongname.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight name!=main → 1" 1 "$rc"

# R5-F1：enforcement 非 active 的 ruleset，preflight 即 fail-closed（不等 assert）
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-inactive.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight inactive → 1" 1 "$rc"
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-inactive.json" >/dev/null 2>&1; rc=$?; set -e
check "assert inactive → 1" 1 "$rc"

# R6-F1：conditions 未真绑默认分支 / 排除 main → verify 拒
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-wrong-include.json" >/dev/null 2>&1; rc=$?; set -e
check "assert wrong-include → 1" 1 "$rc"
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-wrong-include.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight wrong-include → 1" 1 "$rc"
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-exclude-main.json" >/dev/null 2>&1; rc=$?; set -e
check "assert exclude-main → 1" 1 "$rc"
# R7-F2：通配 exclude（refs/heads/*）命中 main 也须拒
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-wildcard-exclude.json" >/dev/null 2>&1; rc=$?; set -e
check "assert wildcard-exclude → 1" 1 "$rc"
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-wildcard-exclude.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight wildcard-exclude → 1" 1 "$rc"

# diff：anysource → 0 且输出含 "Mac Catalyst"（显示将修正）
set +e; out=$("$V" --mode diff --ruleset-json "$FIX/ruleset-anysource.json" 2>&1); rc=$?; set -e
check "diff anysource → 0" 0 "$rc"
echo "$out" | grep -q "Mac Catalyst" && echo "PASS: diff shows change" || { echo "FAIL: diff shows change"; fail=1; }

# bad mode → 2
set +e; "$V" --mode bogus --ruleset-json "$FIX/ruleset-with-check.json" >/dev/null 2>&1; rc=$?; set -e
check "bad mode → 2" 2 "$rc"

exit $fail

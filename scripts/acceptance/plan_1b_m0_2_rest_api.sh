#!/usr/bin/env bash
# Plan 1b 聚合验收：M0.2 REST API 契约
# 涵盖：openapi.yaml 语法 + 11 条契约不变量 pytest + CI workflow 存在
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
declare -a FAILED

run() {
  local label="$1"; shift
  echo ""
  echo "========== $label =========="
  if "$@"; then
    echo "OK: $label"
    PASS=$((PASS + 1))
  else
    echo "NG: $label"
    FAIL=$((FAIL + 1))
    FAILED+=("$label")
  fi
}

# ---- 文件存在性 ----
run "file: openapi.yaml exists" test -s backend/openapi.yaml
run "file: test_openapi.py exists" test -s backend/tests/test_openapi.py
run "file: openapi-smoke.yml exists" test -s .github/workflows/openapi-smoke.yml

# ---- 契约测试 ----
# 必须确切 11 passed；若将来 test 数变化说明 spec drift，label 必须同步更新
run "pytest: 11 OpenAPI invariants" \
    bash -c "cd backend && python3 -m pytest tests/test_openapi.py -q | tee /tmp/plan1b-pytest.out && grep -q '^11 passed' /tmp/plan1b-pytest.out"

# ---- CI workflow YAML 合法 ----
run "yaml: openapi-smoke.yml parse" \
    python3 -c "import yaml; yaml.safe_load(open('.github/workflows/openapi-smoke.yml'))"

# ---- 汇总 ----
echo ""
echo "============================================"
echo "Plan 1b (M0.2 REST API) acceptance: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed items:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  echo "PLAN 1b FAIL"
  exit 1
fi
echo "PLAN 1b PASS"

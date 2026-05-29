#!/usr/bin/env bash
# Wave 1 顺位 18 (B3 FastAPI lease) 机检验收
# 负向断言一律用 if/exit 1（per memory feedback_acceptance_grep_anchoring）
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "== G1: 文件存在 =="
test -f backend/app/lease_logic.py
test -f backend/app/lease_repo.py
test -f backend/app/routes.py
test -f backend/tests/test_lease_logic.py
test -f backend/tests/test_routes.py
test -f docs/acceptance/2026-05-29-pr-b3-fastapi-lease.md

echo "== G2: 全 backend pytest 全绿（无需 DB）=="
# 直接看 pytest 退出码（比 grep "failed|error" 稳——避免警告行/测试名误命中）
if ! ( cd backend && python3 -m pytest -q 2>&1 | tee /tmp/b3-accept-pytest.txt | tail -3; exit "${PIPESTATUS[0]}" ); then
  echo "G2 FAIL: pytest 非零退出"; exit 1
fi

echo "== G3: 模块可导入 + 符号存在 =="
( cd backend && python3 -c "import app.lease_logic as L, app.lease_repo as R, app.routes as RT; \
assert all(s in dir(L) for s in ('decide_confirm','is_meta_selectable','format_expires_at','ConfirmOutcome','RowState','LEASE_TTL')); \
assert all(s in dir(R) for s in ('LeaseRepository','InMemoryLeaseRepository','AsyncpgLeaseRepository','MetaRow')); \
assert hasattr(RT,'router') and hasattr(RT,'get_repository')" )

echo "== G4: D2/D3 状态机落地 =="
grep -q 'row.status == "sent" and row.lease_id == lease_id' backend/app/lease_logic.py
grep -q 'lease_expires_at < now' backend/app/lease_logic.py        # confirm 严格 <
grep -q 'lease_expires_at <= now' backend/app/lease_logic.py       # meta 非严格 <=

echo "== G5: D4 契约修正（expires_at ...Z，禁用 isoformat）=="
grep -qF '%Y-%m-%dT%H:%M:%SZ' backend/app/lease_logic.py
if grep -q 'expires_at.*isoformat()' backend/app/routes.py backend/app/lease_logic.py; then echo "G5 FAIL: 不应用 isoformat 输出 expires_at"; exit 1; fi

echo "== G6: 共享 contract-fixtures 被 import 断言（不 fork local mock）=="
grep -q 'contract-fixtures' backend/tests/test_routes.py
grep -q '_load_fixture("lease_response_partial")' backend/tests/test_routes.py
grep -q '_load_fixture("error_lease_expired")' backend/tests/test_routes.py

echo "== G7: 双层边界（纯层不顶层 import fastapi/asyncpg）=="
if grep -qE '^(import|from) (fastapi|asyncpg)' backend/app/lease_logic.py; then echo "G7 FAIL: lease_logic 不应 import fastapi/asyncpg"; exit 1; fi
if grep -qE '^import asyncpg' backend/app/lease_repo.py; then echo "G7 FAIL: asyncpg 不应顶层 import"; exit 1; fi

echo "== G8: deps 无 range + 不改 frozen 文件 =="
if grep -qE '(>=|<|~=)' backend/requirements.txt backend/requirements-dev.txt; then echo "G8 FAIL: requirements range"; exit 1; fi
for f in backend/sql backend/openapi.yaml tests/contract-fixtures .github; do
  if git diff --name-only origin/main...HEAD -- "$f" | grep -q .; then echo "G8 FAIL: 本 PR 不应改 $f"; exit 1; fi
done

echo
echo "✅ 所有 8 项 G1-G8 验收通过"

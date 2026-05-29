#!/usr/bin/env bash
# Wave 1 顺位 16 (B1 import_csv) 机检验收
# 负向断言一律用 if/exit 1（per memory feedback_acceptance_grep_anchoring：set -e 下 ! grep 是死闸门）
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "== G1: 文件存在 =="
test -f backend/import_csv.py
test -f backend/tests/test_import_csv.py
test -f backend/tests/fixtures/sample_1m.csv
test -f docs/acceptance/2026-05-29-pr-b1-import-csv.md

echo "== G2: 纯层 pytest 全绿（无需 DB）=="
( cd backend && python3 -m pytest tests/test_import_csv.py -q 2>&1 | tee /tmp/b1-accept-pytest.txt | tail -3 )
if grep -qiE "failed|error" /tmp/b1-accept-pytest.txt; then echo "G2 FAIL: pytest 有失败"; exit 1; fi

echo "== G3: 模块可导入 + 符号存在 =="
( cd backend && python3 -c "import import_csv as m; assert 'main' in dir(m) and 'write_to_postgres' in dir(m)" )

echo "== G4: 指标公式落地（D2-D5）=="
grep -q 'rolling(window=66' backend/import_csv.py
grep -q 'std(ddof=0)' backend/import_csv.py
grep -q 'ewm(span=12, adjust=False)' backend/import_csv.py
grep -q '(dif - dea) \* 2' backend/import_csv.py

echo "== G5: ticket_index 1m 基准语义（D6）=="
grep -q 'searchsorted' backend/import_csv.py
grep -q 'return list(range(len(df)))' backend/import_csv.py

echo "== G6: 双层边界 — 纯层不顶层 import asyncpg（D1/D14）=="
if grep -qE '^import asyncpg$' backend/import_csv.py; then echo "G6 FAIL: asyncpg 不应顶层 import"; exit 1; fi
grep -q 'import asyncpg  # 局部' backend/import_csv.py

echo "== G7: H6 deps 精确 pin（D12）=="
PIN=$(grep -cE '^[a-zA-Z0-9_.-]+==' backend/requirements-dev.txt)
[ "$PIN" -ge 5 ] || { echo "G7 FAIL: requirements-dev.txt 应 ≥5 行 == pin，实得 $PIN"; exit 1; }
if grep -qE '(>=|<)' backend/requirements-dev.txt; then echo "G7 FAIL: requirements-dev.txt 仍有 range"; exit 1; fi

echo "== G8: schema 未改 + 不碰 workflows（H.1/I.1）=="
if git diff --name-only origin/main...HEAD -- backend/sql/ | grep -q .; then echo "G8 FAIL: 本 PR 不应改 schema"; exit 1; fi
if git diff --name-only origin/main...HEAD -- .github/ | grep -q .; then echo "G8 FAIL: 本 PR 不应碰 .github（CI 延后）"; exit 1; fi

echo
echo "✅ 所有 8 项 G1-G8 验收通过"

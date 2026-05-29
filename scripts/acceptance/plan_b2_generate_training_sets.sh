#!/usr/bin/env bash
# Wave 1 顺位 17 (B2 generate_training_sets) 机检验收
# 负向断言一律用 if/exit 1（per memory feedback_acceptance_grep_anchoring：set -e 下 ! grep 是死闸门）
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "== G1: 文件存在 =="
test -f backend/generate_training_sets.py
test -f backend/tests/test_generate_training_sets.py
test -f docs/acceptance/2026-05-29-pr-b2-generate-training-sets.md

echo "== G2: 纯层 pytest 全绿（无需 DB）=="
( cd backend && python3 -m pytest tests/test_generate_training_sets.py -q 2>&1 | tee /tmp/b2-accept-pytest.txt | tail -3 )
if grep -qiE "failed|error" /tmp/b2-accept-pytest.txt; then echo "G2 FAIL: pytest 有失败"; exit 1; fi

echo "== G3: 模块可导入 + 符号存在 =="
( cd backend && python3 -c "import generate_training_sets as m; assert all(s in dir(m) for s in ('main','generate_one_training_set','generate_batch','backfill_content_hash'))" )

echo "== G4: 算法落地（D2-D6）=="
grep -q 'rng.randint(30, n - 9)' backend/generate_training_sets.py
grep -qF '[:8]' backend/generate_training_sets.py
grep -q 'bisect_right(three_dts, upper) - 1' backend/generate_training_sets.py
grep -q 'MIN_PERIOD = "3m"' backend/generate_training_sets.py

echo "== G5: content_hash CRC32 口径（D3）=="
grep -qF 'format(zlib.crc32(data) & 0xFFFFFFFF, "08x")' backend/generate_training_sets.py
grep -q 'crc32_hex(zip_path.read_bytes())' backend/generate_training_sets.py

echo "== G6: SQLite schema 语义（D8）=="
grep -q 'PRAGMA user_version = 1' backend/generate_training_sets.py
grep -q 'end_global_index INTEGER NOT NULL' backend/generate_training_sets.py

echo "== G7: 双层边界 — 纯层不顶层 import asyncpg（D1/D13）=="
if grep -qE '^import asyncpg$' backend/generate_training_sets.py; then echo "G7 FAIL: asyncpg 不应顶层 import"; exit 1; fi
grep -q 'import asyncpg' backend/generate_training_sets.py

echo "== G8: deps 无回退 + 不改 schema/workflows（H.1/I.1）=="
if grep -qE '(>=|<|~=)' backend/requirements.txt backend/requirements-dev.txt; then echo "G8 FAIL: requirements 出现 range"; exit 1; fi
if git diff --name-only origin/main...HEAD -- backend/sql/ | grep -q .; then echo "G8 FAIL: 本 PR 不应改 schema"; exit 1; fi
if git diff --name-only origin/main...HEAD -- .github/ | grep -q .; then echo "G8 FAIL: 本 PR 不应碰 .github（CI 延后）"; exit 1; fi

echo
echo "✅ 所有 8 项 G1-G8 验收通过"

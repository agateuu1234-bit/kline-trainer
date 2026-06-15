#!/usr/bin/env bash
# verify-wave3-completion.sh — Wave 3 13c 收尾 doc grep gate（fail-closed，全谓词消费机器可读 WAVE3-STATUS 块）
# 谓词 1：residual A/B/C/D 标 CLOSED（机器块单行精确，杜绝跨行假 PASS，per opus plan-review H1）
# 谓词 2：W3-11-R1 + ship 门 PR11-R1 / W1-R2 标 OPEN
# 谓词 3：高层状态 store-ready=NO + formal-closure=PENDING + matrix PARTIAL + freeze NOT-TAGGED（无误 claim 上架/已关闭）
# 谓词 3b：矩阵 runbook 含 §C fixture 启动机制
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$ROOT/docs/governance/2026-06-14-wave3-completion.md"
MATRIX="$ROOT/docs/acceptance/2026-06-14-wave3-runtime-matrix.md"

fail() { echo "[verify-wave3-completion] FAIL: $1" >&2; exit 1; }

[ -f "$DOC" ] || fail "completion doc 缺失：$DOC"
[ -f "$MATRIX" ] || fail "运行时矩阵 runbook 缺失：$MATRIX"

# 谓词 1：residual A/B/C/D = CLOSED（单行固定串，机器块）
for line in \
  "residual-A-cache-touch-on-use: CLOSED" \
  "residual-B-unified-toast-layer: CLOSED" \
  "residual-C-fixture-provisioning: CLOSED" \
  "residual-D-e2e-smoke: CLOSED"; do
  grep -Fq "$line" "$DOC" || fail "residual ledger 缺『${line}』"
done

# 谓词 2：W3-11-R1 + ship 门 = OPEN（单行固定串，机器块）
for line in \
  "residual-W3-11-R1-bounce-live-wiring: OPEN" \
  "ship-gate-PR11-R1-prod-backend-url: OPEN" \
  "ship-gate-W1-R2-sample-data: OPEN"; do
  grep -Fq "$line" "$DOC" || fail "OPEN 门缺『${line}』"
done

# 谓词 3：高层状态（无 store-ready / 正式关闭 误 claim）
grep -Fq "store-ready: NO" "$DOC" || fail "WAVE3-STATUS 缺 store-ready: NO（防 store-ready 误 claim）"
grep -Fq "formal-closure: PENDING" "$DOC" || fail "WAVE3-STATUS 缺 formal-closure: PENDING（防『正式关闭』误 claim）"
grep -Fq "runtime-matrix: PARTIAL" "$DOC" || fail "WAVE3-STATUS 缺 runtime-matrix: PARTIAL"
grep -Fq "freeze-tag: NOT-TAGGED" "$DOC" || fail "WAVE3-STATUS 缺 freeze-tag: NOT-TAGGED"

# 谓词 3b：矩阵 runbook 须含 §C fixture 启动机制
grep -Fq "KLINE_SEED_FIXTURE=1" "$MATRIX" || fail "矩阵 runbook 缺 §C fixture 启动机制 KLINE_SEED_FIXTURE=1"

echo "[verify-wave3-completion] PASS：A/B/C/D CLOSED + W3-11-R1/PR11-R1/W1-R2 OPEN + WAVE3-STATUS 诚实 + 矩阵 fixture 机制就位"

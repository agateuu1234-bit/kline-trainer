#!/usr/bin/env bash
# verify-wave3-completion.sh — Wave 3 13c 收尾 doc grep gate（fail-closed，全谓词消费机器可读 WAVE3-STATUS 块）
# 谓词 1：residual A/B/C/D 标 CLOSED（机器块单行精确，杜绝跨行假 PASS，per opus plan-review H1）
# 谓词 2：W3-11-R1 + ship 门 PR11-R1 / W1-R2 标 OPEN
# 谓词 3：高层状态 store-ready=NO + formal-closure=PENDING + feature-completeness=PENDING-W3-11-R1 + matrix PARTIAL + freeze NOT-TAGGED（无误 claim 上架/已关闭/feature-complete）
# 谓词 3b：矩阵 runbook 含 §C fixture 启动机制
# 谓词 3c：矩阵 runbook 列 §三.3 三连合取其余两硬门指针（Instruments 帧预算 + Wave 2 减速/帧预算）
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

# 谓词 3：高层状态（无 store-ready / 正式关闭 / feature-complete 误 claim）
grep -Fq "store-ready: NO" "$DOC" || fail "WAVE3-STATUS 缺 store-ready: NO（防 store-ready 误 claim）"
grep -Fq "formal-closure: PENDING" "$DOC" || fail "WAVE3-STATUS 缺 formal-closure: PENDING（防『正式关闭』误 claim）"
grep -Fq "feature-completeness: PENDING-W3-11-R1-bounce-live-wiring" "$DOC" || fail "WAVE3-STATUS 缺 feature-completeness: PENDING-W3-11-R1（防 feature-complete 误 claim，codex review High：bounce 承诺交互未上线）"
grep -Fq "runtime-matrix: PARTIAL" "$DOC" || fail "WAVE3-STATUS 缺 runtime-matrix: PARTIAL"
grep -Fq "freeze-tag: NOT-TAGGED" "$DOC" || fail "WAVE3-STATUS 缺 freeze-tag: NOT-TAGGED"

# 谓词 3b：矩阵 runbook 须含 §C fixture 启动机制
grep -Fq "KLINE_SEED_FIXTURE=1" "$MATRIX" || fail "矩阵 runbook 缺 §C fixture 启动机制 KLINE_SEED_FIXTURE=1"

# 谓词 3c：矩阵 runbook 须列 §三.3 三连合取其余两硬门（防关闭路径塌缩成单矩阵，per 最终 review M1）
grep -Fq "2026-06-14-wave3-pr12-frame-budget.md" "$MATRIX" || fail "矩阵 runbook 缺 Instruments 帧预算 runbook 指针（§三.3 合取项 ③）"
grep -Fq "2026-06-07-c8b-runtime-acceptance.md" "$MATRIX" || fail "矩阵 runbook 缺 Wave 2 减速/帧预算 runbook 指针（§三.3 合取项 ②）"

echo "[verify-wave3-completion] PASS：A/B/C/D CLOSED + W3-11-R1/PR11-R1/W1-R2 OPEN + WAVE3-STATUS 诚实（含 feature-completeness PENDING-W3-11-R1）+ 矩阵 fixture 机制 + §三.3 三连合取硬门指针就位"

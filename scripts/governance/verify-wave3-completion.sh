#!/usr/bin/env bash
# verify-wave3-completion.sh — Wave 3 13c 收尾 doc grep gate（fail-closed）
# 健壮性（codex:adversarial-review R2 High/Med）：状态谓词**只解析 WAVE3-STATUS 注释块**，块内
#   anchored 全行精确匹配 + 拒重复 key——杜绝散文重复掩盖被改的块值（旧版搜整文档 = fail-open）。
# 谓词 1：residual A/B/C/D 标 CLOSED（块内全行）
# 谓词 2：W3-11-R1 + 已知 data-loss 缺陷 13a-R2 + ship 门 PR11-R1 / W1-R2 标 OPEN（块内全行；13a-R2 per R3-High）
# 结构守卫（R3-Med）：WAVE3-STATUS 须恰 1 开标记 + 其后有闭合 -->（拒未闭合注释吞后文）
# 谓词 3：高层状态 store-ready=NO + formal-closure=PENDING + feature-completeness=PENDING-W3-11-R1
#         + runtime-matrix=PARTIAL + freeze-tag=NOT-TAGGED（块内全行；无误 claim 上架/已关闭/feature-complete）
# 谓词 3b：矩阵 runbook 含 §C fixture 启动机制
# 谓词 3c：矩阵 runbook 列 §三.3 三连合取其余硬门（Wave 2 减速/帧预算 + Wave 2 手势 + Instruments 帧预算）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$ROOT/docs/governance/2026-06-14-wave3-completion.md"
MATRIX="$ROOT/docs/acceptance/2026-06-14-wave3-runtime-matrix.md"

fail() { echo "[verify-wave3-completion] FAIL: $1" >&2; exit 1; }

[ -f "$DOC" ] || fail "completion doc 缺失：$DOC"
[ -f "$MATRIX" ] || fail "运行时矩阵 runbook 缺失：$MATRIX"

# WAVE3-STATUS 块须恰 1 个开标记 + 其后有闭合 `-->`（codex R3-Med：未闭合注释会把后文吞进 comment，
# 旧 awk 跑到 EOF 仍非空 → 假 PASS）。先验证结构良好再提取。
OPEN_N=$(grep -Fc "<!-- WAVE3-STATUS" "$DOC" || true)
[ "$OPEN_N" = "1" ] || fail "WAVE3-STATUS 开标记须恰 1 个（实测 ${OPEN_N}）"
awk '/<!-- WAVE3-STATUS/{o=1; next} o&&/^-->/{print "OK"; exit}' "$DOC" | grep -Fxq "OK" \
  || fail "WAVE3-STATUS 块未闭合（开标记后无 -->，markdown 会把后文吞进注释，fail-closed）"

# 仅提取 WAVE3-STATUS 注释块内容（`<!-- WAVE3-STATUS` 行之后、首个 `-->` 行之前）。
BLOCK=$(awk '/<!-- WAVE3-STATUS/{f=1; next} /^-->/{if(f) exit} f' "$DOC")
[ -n "$BLOCK" ] || fail "WAVE3-STATUS 机器块缺失或为空（fail-closed）"

# 块内 require：key 恰出现 1 次（拒重复）+ 该行值与期望完全相等（anchored 全行）。
require_kv() {
  local key="$1" expected="$2" n
  n=$(printf '%s\n' "$BLOCK" | grep -Ec "^${key}: " || true)
  [ "$n" = "1" ] || fail "WAVE3-STATUS 块中 key『${key}』出现 ${n} 次（须恰 1 次，拒重复/缺失）"
  printf '%s\n' "$BLOCK" | grep -Fxq "${key}: ${expected}" \
    || fail "WAVE3-STATUS 块『${key}』值非期望『${expected}』"
}

# 谓词 1：residual A/B/C/D = CLOSED
require_kv "residual-A-cache-touch-on-use" "CLOSED 13a #108"
require_kv "residual-B-unified-toast-layer" "CLOSED 13a #108"
require_kv "residual-C-fixture-provisioning" "CLOSED 13b #109"
require_kv "residual-D-e2e-smoke" "CLOSED 13b #109"

# 谓词 2：W3-11-R1 + 已知 data-loss 缺陷 13a-R2 + ship 门 = OPEN
require_kv "residual-W3-11-R1-bounce-live-wiring" "OPEN"
require_kv "known-defect-13a-R2-cross-lease-cache-deletion" "OPEN"
require_kv "ship-gate-PR11-R1-prod-backend-url" "OPEN"
require_kv "ship-gate-W1-R2-sample-data" "OPEN"

# 谓词 3：高层状态（无 store-ready / 正式关闭 / feature-complete 误 claim）
require_kv "store-ready" "NO"
require_kv "formal-closure" "PENDING-runtime-matrix-device-record"
require_kv "feature-completeness" "PENDING-W3-11-R1-bounce-live-wiring"
require_kv "runtime-matrix" "PARTIAL"
require_kv "freeze-tag" "NOT-TAGGED"

# 谓词 3b：矩阵 runbook 须含 §C fixture 启动机制
grep -Fq "KLINE_SEED_FIXTURE=1" "$MATRIX" || fail "矩阵 runbook 缺 §C fixture 启动机制 KLINE_SEED_FIXTURE=1"

# 谓词 3c：矩阵 runbook 须列 §三.3 三连合取其余硬门指针（防关闭路径塌缩，per review M1 + R2-Med）
grep -Fq "2026-06-14-wave3-pr12-frame-budget.md" "$MATRIX" || fail "矩阵缺 Instruments 帧预算 runbook 指针（§三.3 合取项 ③）"
grep -Fq "2026-06-07-c8b-runtime-acceptance.md" "$MATRIX" || fail "矩阵缺 Wave 2 减速/帧预算 runbook 指针（§三.3 合取项 ②a）"
grep -Fq "2026-06-07-u2-gesture-runtime-acceptance.md" "$MATRIX" || fail "矩阵缺 Wave 2 手势 runbook 指针（§三.3 合取项 ②b）"

echo "[verify-wave3-completion] PASS：A/B/C/D CLOSED + W3-11-R1/PR11-R1/W1-R2 OPEN + WAVE3-STATUS 块诚实（store-ready/closure/feature-completeness/matrix/freeze）+ 矩阵 fixture 机制 + §三.3 三连合取（c8b/u2-gesture/帧预算）指针就位"

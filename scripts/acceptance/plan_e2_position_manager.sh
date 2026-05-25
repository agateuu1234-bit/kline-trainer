#!/usr/bin/env bash
# 验收脚本 — E2 PositionManager（Wave 1 顺位 8 / 第 10 个 PR）
# §4.2.7 enforcement：typed decoder 落地 ⟹ CONTRACT_VERSION bump 必须同 PR；
# 外加 trust-boundary 结构 / bump 矩阵同步 / M0.4 豁免断言。
set -uo pipefail
cd "$(dirname "$0")/../.."

PM="ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift"
MODELS="ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift"
M01="docs/governance/m01-schema-versioning-contract.md"
MODULES="kline_trainer_modules_v1.4.md"
SPEC="kline_trainer_plan_v1.5.md"

fail=0
ok()   { echo "OK:   $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
want() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }      # 期望成功
wantn(){ if eval "$2"; then bad "$1"; else ok "$1"; fi; }      # 期望失败（NOT 命中）

# ---- §4.2.7 义务门：decoder 落地 ⟹ CONTRACT_VERSION 已离开 1.4 且 == 1.5 ----
if grep -q 'init(from decoder' "$PM"; then
  wantn "§4.2.7 门: decoder 落地则 CONTRACT_VERSION 不得仍为 1.4" "grep -qE 'CONTRACT_VERSION = \"1\\.4\"' '$MODELS'"
  want  "§4.2.7 门: CONTRACT_VERSION 已 bump 为 1.5"             "grep -qE 'CONTRACT_VERSION = \"1\\.5\"' '$MODELS'"
else
  ok "§4.2.7 门: 无 typed decoder（bump 不强制）"
fi

# ---- trust-boundary 结构（§4.2.1/§4.2.4/§4.2.8/D1/D6）----
want  "buy/sell precondition trap 存在"        "grep -q 'precondition(' '$PM'"
want  "持久化 decoder 抛 DecodingError"         "grep -q 'DecodingError' '$PM'"
want  "invariantsHold 守门存在"                 "grep -q 'invariantsHold' '$PM'"
want  "sell(0) no-op 分支存在（D1）"            "grep -q 'no-op' '$PM'"
wantn "positionTier 已移除（D6/§4.2.8）"         "grep -q 'positionTier' '$PM'"

# ---- bump 矩阵同步（D5）----
want "m01 矩阵 CONTRACT_VERSION = 1.5"     "grep -qE '^\\|.*CONTRACT_VERSION.*\\| *\`?\"1\\.5\"\`? *\\|' '$M01'"
want "modules 矩阵 CONTRACT_VERSION = 1.5" "grep -qE '^\\|.*CONTRACT_VERSION.*\\| *\`?\"1\\.5\"\`? *\\|' '$MODULES'"

# ---- M0.4 豁免（D7）：PositionManager 不引用 AppError ----
wantn "M0.4 豁免: PositionManager 不引用 AppError" "grep -q 'AppError' '$PM'"

# ---- spec 同步（D6）：§4.2 区不再有 positionTier 代码行 ----
wantn "spec §4.2 无 'var positionTier' 代码行" "grep -q 'var positionTier' '$SPEC'"

if [ "$fail" -ne 0 ]; then echo "=== E2 ACCEPTANCE FAILED ==="; exit 1; fi
echo "=== ALL E2 ACCEPTANCE CHECKS PASSED ==="

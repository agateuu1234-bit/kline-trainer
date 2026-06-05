#!/usr/bin/env bash
# 验收脚本 — E5a TrainingEngine 核心（Wave 2 顺位 2）
# 仅含 Linux 可跑的结构闸门；swift test / Catalyst 见验收清单 CI 行。
set -uo pipefail
cd "$(dirname "$0")/../.."
TE="ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift"
TS="ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests.swift"
fail=0
ok(){ echo "OK:   $1"; }
bad(){ echo "FAIL: $1"; fail=1; }
want(){  if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }   # 期望命中
wantn(){ if eval "$2" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }   # 期望不命中

echo "== G1: 壳已替换（无 Wave 0 stub / fatalError / fileprivate init 残留）=="
wantn "无 Wave 0 stub 注释" "grep -q 'Wave 0 stub' '$TE'"
wantn "无 fatalError"       "grep -q 'fatalError' '$TE'"
wantn "无 fileprivate init" "grep -qE 'fileprivate +init' '$TE'"

echo "== G2: public init（10 参签名锚点）+ drawdown seeding =="
want "public init(flow:)" "grep -qE 'public init\(flow: TrainingFlowController' '$TE'"
want "initialCashBalance 参数" "grep -q 'initialCashBalance' '$TE'"
want "drawdown peak seeding（codex R2-F1）" "grep -q 'max(initialDrawdown.peakCapital' '$TE'"

echo "== G2b: R4-R6 不变量前置 =="
want "flow/maxTick precondition（R4-F1）"        "grep -q 'flow.allowedTickRange.upperBound == maxTick' '$TE'"
want "startTick 范围 precondition（R4-F1/R6-F1）" "grep -q 'allowedTickRange.contains(startTick)' '$TE'"
want ".m3 驱动序列前置（R4-F2）"                 "grep -qE 'allCandles\[.m3\]' '$TE'"
wantn "无 finestPeriod 残留（R4-F2 删）"         "grep -q 'finestPeriod' '$TE'"
want "drawdown update 反映起始总资金（R5-F1）"    "grep -q 'seededDrawdown.update(currentCapital: startTotal)' '$TE'"
want ".m3 覆盖 maxTick 前置（R6-F2）"            "grep -q 'endGlobalIndex >= maxTick' '$TE'"
want "resume initialTick 参数（R6-F1）"          "grep -q 'initialTick ?? flow.initialTick' '$TE'"
want "drawdown 含 initialCapital 基线（R6-F3）"   "grep -q 'initialDrawdown.peakCapital, initialCapital, startTotal' '$TE'"

echo "== G3: 9 个运行时存储态 =="
for p in tick position cashBalance drawdown markers drawings upperPanel lowerPanel tradeOperations; do
  want "存储态 $p" "grep -qE 'private\(set\) var $p' '$TE'"
done

echo "== G4: 4 纯值 accessor（buy/sellEnabled 下放 E5b，不应出现）=="
for a in currentTotalCapital holdingCost returnRate maxDrawdown; do
  want "accessor $a" "grep -qE 'var $a' '$TE'"
done
wantn "无 buyEnabled 声明（D4 下放 E5b）"  "grep -qE 'var +buyEnabled' '$TE'"
wantn "无 sellEnabled 声明（D4 下放 E5b）" "grep -qE 'var +sellEnabled' '$TE'"

echo "== G5: onSceneActivated 中继到 resetOnSceneActive =="
want "onSceneActivated" "grep -q 'func onSceneActivated' '$TE'"
want "resetOnSceneActive 中继" "grep -q 'resetOnSceneActive' '$TE'"

echo "== G6: 默认周期组合 上 60m / 下 日线 + 面板由 resume 参数构造（D7 / R6 / R7-F1）=="
want "initialUpperPeriod 默认 .m60"   "grep -q 'initialUpperPeriod: Period = .m60' '$TE'"
want "initialLowerPeriod 默认 .daily"  "grep -q 'initialLowerPeriod: Period = .daily' '$TE'"
want "upperPanel 由 initialUpperPeriod 构造" "grep -q 'PanelViewState(period: initialUpperPeriod' '$TE'"
want "lowerPanel 由 initialLowerPeriod 构造" "grep -q 'PanelViewState(period: initialLowerPeriod' '$TE'"

echo "== G7: maxDrawdown 透传 accumulator（spec L1636）=="
want "drawdown.maxDrawdown 透传" "grep -q 'drawdown.maxDrawdown' '$TE'"

echo "== G8: 作用域守卫 —— E5a 不实现 E5b 动作 =="
for m in 'func buy\(' 'func sell\(' 'func holdOrObserve' 'func switchPeriodCombo' 'func activateDrawingTool' 'func deleteDrawing'; do
  wantn "未越界实现 $m" "grep -qE '$m' '$TE'"
done

echo "== G9: 测试存在且用 Swift Testing =="
want "测试文件存在" "test -f '$TS'"
want "import Testing" "grep -q 'import Testing' '$TS'"
want "@Test 用例"     "grep -q '@Test' '$TS'"

echo "== G10: 作用域 —— diff 只动允许文件 =="
base="$(git merge-base origin/main HEAD 2>/dev/null || echo origin/main)"
changed="$(git diff --name-only "$base"...HEAD 2>/dev/null || true)"
disallowed="$(printf '%s\n' "$changed" | grep -vE '^(ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine\.swift|ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests\.swift|scripts/acceptance/plan_e5a_trainingengine_core\.sh|docs/(acceptance|superpowers/plans)/.*e5a.*\.md)$' || true)"
if [ -n "$disallowed" ]; then bad "越界文件: $disallowed"; else ok "diff 文件白名单内"; fi

echo
if [ "$fail" -ne 0 ]; then echo "=== E5a ACCEPTANCE FAILED ==="; exit 1; fi
echo "=== ALL E5a ACCEPTANCE CHECKS PASSED ==="

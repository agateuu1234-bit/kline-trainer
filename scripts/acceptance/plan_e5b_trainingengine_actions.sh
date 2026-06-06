#!/usr/bin/env bash
# 验收脚本 — E5b TrainingEngine 交易动作（Wave 2 顺位 3）
# 仅含 Linux 可跑的结构闸门；swift test / Catalyst 见验收清单 CI 行。
set -uo pipefail
cd "$(dirname "$0")/../.."
TE="ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift"
TS="ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift"
fail=0
ok(){ echo "OK:   $1"; }
bad(){ echo "FAIL: $1"; fail=1; }
want(){  if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }   # 期望命中
wantn(){ if eval "$2" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }   # 期望不命中

echo "== G1: 6 个 E5b public 成员落地 =="
want "buy(panel:tier:)"            "grep -qE 'public func buy\(panel: PanelId, tier: PositionTier\)' '$TE'"
want "sell(panel:tier:)"           "grep -qE 'public func sell\(panel: PanelId, tier: PositionTier\)' '$TE'"
want "holdOrObserve(panel:)"       "grep -qE 'public func holdOrObserve\(panel: PanelId\)' '$TE'"
want "switchPeriodCombo(direction:)" "grep -qE 'public func switchPeriodCombo\(direction: PeriodDirection\)' '$TE'"
want "buyEnabled"                  "grep -qE 'public var buyEnabled: Bool' '$TE'"
want "sellEnabled"                 "grep -qE 'public var sellEnabled: Bool' '$TE'"

echo "== G2: 画线方法延后顺位 7（本 PR 不实现）=="
wantn "未越界实现 activateDrawingTool" "grep -qE 'func activateDrawingTool' '$TE'"
wantn "未越界实现 deleteDrawing"       "grep -qE 'func deleteDrawing' '$TE'"

echo "== G3: 关键设计锚点 =="
want "buyEnabled 功能式 ∃tier（D1）"      "grep -q 'PositionTier.allCases.contains' '$TE'"
want "买卖经 E3 Result 通道（入口 1a）"   "grep -q 'TradeCalculator.quoteBuy' '$TE'"
want "卖出 quoteSell"                    "grep -q 'TradeCalculator.quoteSell' '$TE'"
want "局终强平 forceCloseOnEnd（入口 1b）" "grep -q 'TradeCalculator.forceCloseOnEnd' '$TE'"
want "强平接入 advance 路径"             "grep -q 'forceCloseIfEnded' '$TE'"
want "两面板硬切 tradeTriggered（D4）"    "grep -q 'reduce(.tradeTriggered)' '$TE'"
want "周期切换 periodComboSwitched"      "grep -q 'reduce(.periodComboSwitched)' '$TE'"
want "周期组合序列（D8）"                "grep -q 'periodCombos' '$TE'"
want "步进二分（D3）"                    "grep -q 'partitioningIndex' '$TE'"
want "createdAt 用 m3 datetime（D5）"     "grep -q 'candleDatetime' '$TE'"

echo "== G4: E5a 既有面未被破坏（仍在）=="
want "make() 仍是 public 构造路径"  "grep -qE 'public static func make\(' '$TE'"
want "currentTotalCapital accessor" "grep -q 'public var currentTotalCapital' '$TE'"
want "onSceneActivated 仍在"        "grep -q 'public func onSceneActivated' '$TE'"

echo "== G5: 测试存在且用 Swift Testing =="
want "测试文件存在"  "test -f '$TS'"
want "import Testing" "grep -q 'import Testing' '$TS'"
want "@Test 用例"     "grep -q '@Test' '$TS'"
want "强平测试"       "grep -q 'ForceClose' '$TS'"
want "buyEnabled 测试" "grep -q 'buyEnabled' '$TS'"

echo "== G6: 作用域 —— diff 只动允许文件 =="
base="$(git merge-base origin/main HEAD 2>/dev/null || echo origin/main)"
changed="$(git diff --name-only "$base"...HEAD 2>/dev/null || true)"
if [ -n "$changed" ]; then
  # 收紧到 E5b 具名 doc（不再放行任意 plans/*——防跨 PR plan 串味，见 P2 contamination 教训）
  bados="$(echo "$changed" | grep -vE '^(ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine\.swift|ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests\.swift|scripts/acceptance/plan_e5b_trainingengine_actions\.sh|docs/acceptance/2026-06-06-pr-e5b-trainingengine-actions\.md|docs/superpowers/plans/2026-06-06-pr-e5b-trainingengine-actions\.md)$' || true)"
  if [ -n "$bados" ]; then bad "越界文件: $bados"; else ok "diff 仅含允许文件"; fi
else
  ok "无 diff（或 base 不可解析，CI 再核）"
fi

echo
if [ "$fail" = 0 ]; then echo "=== ALL E5b ACCEPTANCE CHECKS PASSED ==="; else echo "=== E5b ACCEPTANCE FAILED ==="; fi
exit $fail

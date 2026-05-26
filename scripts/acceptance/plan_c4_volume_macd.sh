#!/usr/bin/env bash
# C4 Volume + MACD 机检验收。仓库根目录运行。
set -uo pipefail
FAIL=0
run() { echo "--- $1"; shift; if "$@"; then echo "OK"; else echo "FAIL"; FAIL=1; fi; }

SRC="ios/Contracts/Sources/KlineTrainerContracts/Render"
LAYOUT="$SRC/SubChartLayout.swift"
DRAW_VOL="$SRC/KLineView+Volume.swift"
DRAW_MACD="$SRC/KLineView+MACD.swift"

run "SubChartLayout.swift 存在" test -f "$LAYOUT"
run "SubChartLayoutTests.swift 存在" test -f "ios/Contracts/Tests/KlineTrainerContractsTests/Render/SubChartLayoutTests.swift"
# 匹配行首真实 import 语句，避免误伤注释 "本文件不 import UIKit"
run "布局文件平台无关（无真实 import UIKit 语句）" bash -c "! grep -qE '^import UIKit' '$LAYOUT'"
run "三布局函数存在" bash -c "grep -q 'func volumeBars' '$LAYOUT' && grep -q 'func macdLines' '$LAYOUT' && grep -q 'func macdBars' '$LAYOUT'"
run "D11：MACD 基线钳制函数存在" bash -c "grep -q 'func macdBarBaseline' '$LAYOUT'"
# D1 主门 = 正向断言 MACD 读预计算字段；负向 grep 仅 best-effort（同 C3 L3 教训）
run "D1（主门）：MACD 读预计算 macdDiff/macdDea/macdBar 字段（强 \$0. 引用 + 单词边界，M4 真收紧）" bash -c "grep -qE '\\\$0\\.macdDiff\\b' '$LAYOUT' && grep -qE '\\\$0\\.macdDea\\b' '$LAYOUT' && grep -qE '\\.macdBar\\b' '$LAYOUT'"
run "D1（best-effort）：无 'EMA/ema/window/滑窗' 重算关键词" bash -c "! grep -qiE 'EMA|ema|window|滑窗' '$LAYOUT'"
# M2 注：awk '^}' 命中位置 = swift extension 体的闭合 `}`（顶层无缩进；方法 `    }` 缩进 4 空格不命中）。
# 本断言依赖"该文件 extension 内只有 drawMACD 一个方法"——若未来追加同 extension 第二方法 awk 范围会扩大引入误检；本 PR 单方法 OK。
run "D3：DIF/DEA 实线（drawMACD 内无 setLineDash）" bash -c "! awk '/func drawMACD/,/^}/' '$DRAW_MACD' | grep -q 'setLineDash'"
run "D4 Volume：引用 F2 涨跌色 token，不硬编码 RGB" bash -c "grep -q 'AppColor.candleUp' '$DRAW_VOL' && grep -q 'AppColor.candleDown' '$DRAW_VOL'"
run "D4 MACD：引用 F2 macd token，不硬编码 RGB" bash -c "grep -q 'AppColor.macdDIF' '$DRAW_MACD' && grep -q 'AppColor.macdDEA' '$DRAW_MACD' && grep -q 'AppColor.macdBarPositive' '$DRAW_MACD' && grep -q 'AppColor.macdBarNegative' '$DRAW_MACD'"
run "saveGState/restoreGState 配对（结构存在性，非配对证明）：drawVolume" bash -c "awk '/func drawVolume/,/^}/' '$DRAW_VOL' | grep -q 'saveGState' && awk '/func drawVolume/,/^}/' '$DRAW_VOL' | grep -q 'restoreGState'"
run "saveGState/restoreGState 配对（结构存在性，非配对证明）：drawMACD" bash -c "awk '/func drawMACD/,/^}/' '$DRAW_MACD' | grep -q 'saveGState' && awk '/func drawMACD/,/^}/' '$DRAW_MACD' | grep -q 'restoreGState'"
run "M0.4 豁免：C4 不碰 AppError" bash -c "! grep -q 'AppError' '$LAYOUT' '$DRAW_VOL' '$DRAW_MACD'"
run "stub 字样清除：Volume" bash -c "! grep -qiE 'Wave 1 \\(C4\\): implement' '$DRAW_VOL'"
run "stub 字样清除：MACD" bash -c "! grep -qiE 'Wave 1 \\(C4\\): implement' '$DRAW_MACD'"
run "host swift test exit 0" bash -c "cd ios/Contracts && swift test"

if [ "$FAIL" -eq 0 ]; then echo "=== ALL C4 ACCEPTANCE CHECKS PASSED ==="; else echo "=== C4 ACCEPTANCE FAILED ==="; exit 1; fi

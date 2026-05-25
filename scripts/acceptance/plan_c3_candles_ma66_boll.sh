#!/usr/bin/env bash
# C3 Candles + MA66 + BOLL 机检验收。仓库根目录运行。
set -uo pipefail
FAIL=0
run() { echo "--- $1"; shift; if "$@"; then echo "OK"; else echo "FAIL"; FAIL=1; fi; }

SRC="ios/Contracts/Sources/KlineTrainerContracts/Render"
LAYOUT="$SRC/MainChartLayout.swift"
DRAW="$SRC/KLineView+Candles.swift"

run "MainChartLayout.swift 存在" test -f "$LAYOUT"
run "MainChartLayoutTests.swift 存在" test -f "ios/Contracts/Tests/KlineTrainerContractsTests/Render/MainChartLayoutTests.swift"
# 匹配行首真实 import 语句，避免误伤注释 "本文件不 import UIKit"
run "布局文件平台无关（无真实 import UIKit 语句）" bash -c "! grep -qE '^import UIKit' '$LAYOUT'"
run "三布局函数存在" bash -c "grep -q 'func candleShapes' '$LAYOUT' && grep -q 'func ma66Polyline' '$LAYOUT' && grep -q 'func bollPolylines' '$LAYOUT'"
# D1 主门 = 正向断言 MA66 读预计算 $0.ma66；负向 grep 仅 best-effort（L3：易绕过，不作硬证据）
run "D1（主门）：MA66 读预计算字段 \$0.ma66" bash -c "grep -q '\\\$0.ma66' '$LAYOUT'"
run "D1（best-effort）：无 'window/滑窗' 重算关键词" bash -c "! grep -qiE 'window|滑窗' '$LAYOUT'"
run "D3：BOLL 虚线 setLineDash" bash -c "grep -q 'setLineDash' '$DRAW'"
run "D3：dash 段长抽为 host 可测 dashPattern" bash -c "grep -q 'func dashPattern' '$LAYOUT' && grep -q 'dashPattern' '$DRAW'"
run "D2：无 BOLL 填充（drawBOLL 内不出现 fill 调用）" bash -c "! awk '/func drawBOLL/,/^    }/' '$DRAW' | grep -qE 'ctx.fill|\\.fill\\('"
run "D4：引用 F2 token 不硬编码 RGB" bash -c "grep -q 'AppColor.candleUp' '$DRAW' && grep -q 'AppColor.candleDown' '$DRAW' && grep -q 'AppColor.ma66' '$DRAW' && grep -q 'AppColor.bollLine' '$DRAW'"
# H1 如实：以下仅"结构存在性"检查，不证明 save/restore 配对正确（运行期无自动验证，靠 review）
run "dash 隔离结构存在（非配对证明，H1）：drawBOLL 含 saveGState+restoreGState" bash -c "awk '/func drawBOLL/,/^    }/' '$DRAW' | grep -q 'saveGState' && awk '/func drawBOLL/,/^    }/' '$DRAW' | grep -q 'restoreGState'"
run "M0.4 豁免：C3 不碰 AppError" bash -c "! grep -q 'AppError' '$LAYOUT' '$DRAW'"
run "host swift test exit 0" bash -c "cd ios/Contracts && swift test"

if [ "$FAIL" -eq 0 ]; then echo "=== ALL C3 ACCEPTANCE CHECKS PASSED ==="; else echo "=== C3 ACCEPTANCE FAILED ==="; exit 1; fi

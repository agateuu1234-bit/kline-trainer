#!/usr/bin/env bash
# Catalyst 必需门的判据实现。
#
# 背景（2026-07-13）：本门曾用 library scheme `KlineTrainerContracts` 跑 build-for-testing，
# 而 SwiftPM 的 library scheme 根本不编译 testTarget → 门半年来报绿但从未验证过任何测试代码
# （旧日志里 grep `KlineTrainerContractsTests` 一条都没有）。G4/G5/G6 三条"自证"判据就是为了
# 让这种空壳门**不可能再静默变绿**：门必须证明自己真的编译了测试 target、真的跑了测试、
# 真的编译了 UIKit-gated 代码。G6/G7/G8 是这三条"自证"判据（G5 只统计不拦，见下）。
#
# ⚠️ 判据锚点铁律：绝不能选一个"同时会出现在 xcodebuild 命令行回显里"的字符串。
# xcodebuild 在开始任何编译工作之前，会把自己的完整调用命令行原样回显到日志前几行
# （包含 workflow 里硬编码的 -only-testing:KlineTrainerContractsTests 等参数）。
# 这行回显是**无条件存在**的，与任何 target 是否真被编译无关。曾经 G6 锚在裸字符串
# `KlineTrainerContractsTests` 上，结果这条回显本身就能让 G6 恒真——哪怕测试 target
# 一行都没编译。下一个最容易踩进同一个坑的判据是"自证 scheme 用对了"，
# 如果写成 `grep -q 'KlineTrainerContracts-Package'`，会立刻重蹈覆辙（该 scheme 名同样
# 出现在命令行回显里）。判据必须锚定"只有真实编译/执行才会产生"的证据
# （如 `SwiftCompile …`、源码路径、`Test run with …` 汇总行），不能是裸标识符匹配。
#
# 用法: catalyst-gate.sh <xcodebuild 日志路径>
# 退出: 0 = 通过；1 = 拦截（stderr 说明哪条判据失败）
set -uo pipefail

LOG="${1:?usage: catalyst-gate.sh <log-path>}"
if [ ! -f "$LOG" ]; then
    echo "GATE FAIL: 日志文件不存在: $LOG" >&2
    exit 1
fi

fail() { echo "GATE FAIL: $*" >&2; exit 1; }

# --- G2: 测试真跑完且成功（test 动作的标记是 TEST SUCCEEDED，不是 TEST BUILD SUCCEEDED）
if ! grep -qF '** TEST SUCCEEDED **' "$LOG"; then
    fail "缺少 '** TEST SUCCEEDED **' 标记（旧的 build-for-testing 标记 'TEST BUILD SUCCEEDED' 不算数）"
fi

# --- G3: 编译器错误。锚定 <文件>.swift:<行>:<列>: error: 格式，
#         这样 xctest 运行期噪声（如 'CoreData: error: Failed to create NSXPCConnection'）不会误伤。
if grep -qE '\.swift:[0-9]+:[0-9]+: (fatal )?error:' "$LOG"; then
    echo "GATE FAIL: 检测到编译器错误：" >&2
    grep -E '\.swift:[0-9]+:[0-9]+: (fatal )?error:' "$LOG" | sort -u | head -20 >&2
    exit 1
fi

# --- G4: 生产代码（Sources/）零警告棘轮。今天真为 0，新增一条即拦。
if grep -qE 'ios/Contracts/Sources/[^ ]*\.swift:[0-9]+:[0-9]+: warning:' "$LOG"; then
    echo "GATE FAIL: 生产代码 Sources/ 出现编译警告（本门要求 Sources/ 零警告）：" >&2
    grep -E 'ios/Contracts/Sources/[^ ]*\.swift:[0-9]+:[0-9]+: warning:' "$LOG" | sort -u | head -20 >&2
    exit 1
fi

# --- G6: 自证——测试 target 真的被编译了（旧空壳门在这里命中 0 次）
#     锚点必须是源码路径，不能是裸 target 名——后者同时出现在 xcodebuild 的命令行回显里
#     （workflow 硬编码的 -only-testing:KlineTrainerContractsTests），回显无条件存在，
#     裸名匹配会让本判据恒真。源码路径只在真实编译该 target 下的文件时才会出现在日志里。
if ! grep -q 'Tests/KlineTrainerContractsTests/' "$LOG"; then
    fail "日志里找不到 Tests/KlineTrainerContractsTests/ —— 测试 target 根本没被编译（scheme 用错了？）"
fi

# --- G8: 自证——UIKit-gated 代码真的被编译进了 Catalyst 构建，且里面的测试真的跑完了。
#     （2026-07-14 实测发现的漏洞）旧判据只 grep 金丝雀文件名 DrawDrawingsDispatchTests.swift。
#     但该文件的测试体裹在 #if canImport(UIKit) 里——在**非 Catalyst**（如 `platform=macOS`）
#     destination 上，这个文件依然会被编译（只是宏剔除了测试体），文件名照样进日志。
#     实测：用 -destination 'platform=macOS' 跑同一套测试，UIKit-only 套件执行 0 次，
#     但金丝雀文件名仍出现 3 次 —— 旧判据在这种情况下会放行，而这正是它声称要堵的盲区。
#     换成两条只有真·Mac Catalyst 编译+执行才会产生的证据：
#     锚点 A —— macabi：Catalyst 的编译 target triple 形如 `arm64-apple-iosNN.N-macabi`，
#     只出现在真实编译产物路径/编译器调用里；不出现在 xcodebuild 的命令行回显里
#     （回显里的 destination 是 "platform=macOS,variant=Mac Catalyst" 字面量，不含 "macabi"）。
#     锚点 B —— UIKit-only 测试套件真的跑完了：全部 UIKit-gated 套件必须都出现
#     "passed after" 收尾行，证明它们不仅编译了，还真的执行到底（不是编译了但被跳过）。
if ! grep -q 'macabi' "$LOG"; then
    fail "日志里找不到 macabi（Mac Catalyst 编译 target triple）—— 这份日志不是真 Mac Catalyst 编译产物，UIKit-gated 代码没有被编译（destination 是不是退化成了普通 macOS？）"
fi

# 2026-07-14 codex R3 finding：本列表曾只列 3 个套件，但仓库里实际有 6 个 UIKit-gated
# @Suite（+ 1 个无 @Suite 的裸 struct，见下面的 UIKIT_TESTS）——漏掉的里面就包括当初
# bug 的藏身处 DrawDrawingsDispatchTests。MIN_TESTS 留了余量，漏掉的套件被禁用/跳过时
# 闸门毫无信号照样能过。若这些套件改名/拆分/新增，请同步更新下面的列表——否则本判据
# 会失去意义地长期沉默。完整性由 catalyst-gate.test.sh 里的漂移检测
# （uikit-suite-drift-check.py）兜底：它会扫描源码里全部 UIKit-gated @Suite/@Test，
# 一旦与下面两个列表不一致就会在真构建之前让测试变红。
UIKIT_SUITES=(
    'UIChartPalette（UIKit 桥；scheme 选取）'
    'ThemeController'
    'UIColor(rgba:) bridge + AppColor 13 const'
    'ChartContainerView 编译反射（Catalyst compile gate）'
    'ChartContainerView 布局重算（修 #2 复盘静态界面空白）'
    'KLineView 编译反射（§15.1 #3 compile gate）'
)
for suite in "${UIKIT_SUITES[@]}"; do
    if ! grep -qF "Suite \"${suite}\" passed after" "$LOG"; then
        fail "UIKit-gated 套件未执行完毕：${suite} —— 找不到 'passed after' 收尾行（UIKit 代码体没有真的跑完）"
    fi
done

# 第 7 个 UIKit-gated 单元 DrawDrawingsDispatchTests.swift 是裸 struct、无 @Suite 显示名，
# 不会产生 "Suite ... passed after" 行——只能用测试级哨兵（"Test ... passed"）钉住它。
UIKIT_TESTS=(
    '§5.3 #14 drawDrawings with empty list calls no render'
)
for t in "${UIKIT_TESTS[@]}"; do
    if ! grep -qF "Test \"${t}\" passed" "$LOG"; then
        fail "UIKit-gated 测试未执行：${t} —— 找不到 'passed' 收尾行（UIKit 代码体没有真的跑完）"
    fi
done

# --- G7: 自证——测试真的被执行了，且不是 0 个（防 -only-testing 把用例全过滤光）
#     "in M suites" 这段是可选的：本地 Xcode 输出 'Test run with N tests in M suites passed'，
#     而 CI 的 macos-15 输出 'Test run with N tests passed'（没有 "in M suites"）。
#     两种格式都要接受，否则 CI 上永远匹配不到（真实咬过一次，见 fixtures/pass-ci-format.log）。
SUMMARY=$(grep -oE 'Test run with [0-9]+ tests?( in [0-9]+ suites?)? passed' "$LOG" | head -1 || true)
if [ -z "$SUMMARY" ]; then
    fail "找不到 swift-testing 汇总行 'Test run with N tests [in M suites] passed' —— 测试没被执行"
fi
# 提取用例数：必须锚在 "Test run with " 后紧跟的数字上，不能用"匹配到的第一个数字"——
# 本地格式的 SUMMARY 里还有 "in M suites" 的 M，位置在 tests 数之后，裸序号提取法可能误取它。
N_TESTS=$(echo "$SUMMARY" | grep -oE '^Test run with [0-9]+' | grep -oE '[0-9]+')
if [ "$N_TESTS" -eq 0 ]; then
    fail "swift-testing 执行了 0 个用例（${SUMMARY}）—— 门是空的"
fi
# 可维护下限：防 -only-testing 被收窄/大批用例被跳过时仍能跑出个位数用例就过（"0 个"
# 只是这类覆盖塌方的极端情形，中间地带——比如收窄到只剩一个 suite——0 检查抓不住）。
# 这不是精确判据：Catalyst 全量当前是 1407 个（见 fixtures/pass-new-scheme.log），
# 阈值留了约 200 条余量给正常的测试增删，不要把它设成等于当前真实值。
# 调整时机：真实用例数长期低于这个数（比如新增测试后稳定在 1250+），把 MIN_TESTS 一起抬高；
# 反之若测试被大量删除是有意为之，也要把它一起调低，否则会误拦正常 PR。
MIN_TESTS=1200
if [ "$N_TESTS" -lt "$MIN_TESTS" ]; then
    fail "swift-testing 只执行了 ${N_TESTS} 个用例，低于下限 ${MIN_TESTS}（${SUMMARY}）—— 可能是 -only-testing 被收窄或用例被大批跳过"
fi

# --- G5: 测试代码警告：只统计、不拦（48 条既有技术债，见 spec §4）
#     去重计数：同一条警告会因增量编译跨多趟重复出现在日志里（原始行数是去重后的 ~7 倍），
#     裸行数会夸大技术债规模，故按 "文件:行:列: warning:" 去重后计数。
TEST_WARN=$(grep -oE 'ios/Contracts/Tests/[^ ]*\.swift:[0-9]+:[0-9]+: warning:' "$LOG" | sort -u | wc -l | tr -d ' ' || true)

echo "GATE PASS"
echo "  执行用例数（swift-testing）: $SUMMARY"
echo "  Tests/ 警告去重条数（既有技术债，不拦门）: $TEST_WARN 条"

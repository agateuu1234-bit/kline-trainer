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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# --- G8: 自证——UIKit-gated 代码真的被编译进了 Catalyst 构建，且里面**每一个**测试
#     真的跑完了。
#     （2026-07-14 实测发现的漏洞，历经 R3/R4 两轮 codex finding）旧判据先后踩过两个坑：
#     1) 只 grep 金丝雀文件名 DrawDrawingsDispatchTests.swift——但该文件的测试体裹在
#        #if canImport(UIKit) 里，在**非 Catalyst**（如 `platform=macOS`）destination 上
#        这个文件依然会被编译（只是宏剔除了测试体），文件名照样进日志，旧判据放行。
#     2) 改成硬编码 UIKIT_SUITES/UIKIT_TESTS 列表后，只钉「套件跑完了」（Suite "X" passed
#        after）——但这只证明套件**整体**跑完，不证明套件**里的每个测试**都跑了；删掉
#        套件内的某个测试，套件照样 passed，闸门照样绿（DrawDrawingsDispatchTests 是裸
#        struct 无 @Suite，UIKIT_TESTS 更只钉了它 7 个测试里的 1 个，另外 6 个被删/跳过
#        闸门毫无信号）。
#     根治：不再手工维护「应该测什么」的列表——CI 上跑闸门时源码已经 checkout 到位，
#     源码本身就是唯一真相。改由 uikit-expected-tests.py 在运行时扫描源码，推导出
#     「本应执行的 UIKit-gated 测试全集」，下面逐个断言日志里有对应的
#     `Test "<显示名>" passed` 或 `Test <函数名>() passed` 行（两种 @Test 写法格式不同，
#     见下方 F3 匹配分支）——新增/改名/删除的测试自动被下一次运行覆盖，不会再有
#     N-of-M 的哨兵缺口。
#     锚点 A —— macabi：Catalyst 的编译 target triple 形如 `arm64-apple-iosNN.N-macabi`，
#     只出现在真实编译产物路径/编译器调用里；不出现在 xcodebuild 的命令行回显里
#     （回显里的 destination 是 "platform=macOS,variant=Mac Catalyst" 字面量，不含 "macabi"）。
#     锚点 B —— 源码推导出的每一个 UIKit-gated 测试都真的执行到底（不是编译了但被跳过）。
if ! grep -q 'macabi' "$LOG"; then
    fail "日志里找不到 macabi（Mac Catalyst 编译 target triple）—— 这份日志不是真 Mac Catalyst 编译产物，UIKit-gated 代码没有被编译（destination 是不是退化成了普通 macOS？）"
fi

# fail-closed：推导脚本非零退出，或输出为空（没有任何期望测试名），都必须让闸门 FAIL——
# 绝不能把「没有期望项」误判成「全部通过」（否则解析器坏掉/源码目录被误删时，本判据
# 会无声无息地空转变绿，重蹈 UIKIT_SUITES/UIKIT_TESTS 硬编码列表的覆辙）。
# UIKIT_EXPECTED_TESTS_SCRIPT 只允许 catalyst-gate.test.sh 用来在测试里注入一个假的
# 空清单/异常退出脚本，从而对 fail-closed 分支做可重复的自动化回归；生产环境永远走
# 默认值（真实的 uikit-expected-tests.py）。
UIKIT_EXPECTED_TESTS_SCRIPT="${UIKIT_EXPECTED_TESTS_SCRIPT:-$SCRIPT_DIR/uikit-expected-tests.py}"
UIKIT_EXPECTED_TESTS="$(python3 "$UIKIT_EXPECTED_TESTS_SCRIPT" 2>&1)"
UIKIT_EXPECTED_STATUS=$?
if [ "$UIKIT_EXPECTED_STATUS" -ne 0 ]; then
    fail "UIKit-gated 测试清单推导失败（uikit-expected-tests.py exit=${UIKIT_EXPECTED_STATUS}）：${UIKIT_EXPECTED_TESTS}"
fi
if [ -z "$UIKIT_EXPECTED_TESTS" ]; then
    fail "UIKit-gated 测试清单推导为空——找不到任何期望测试，拒绝放行（fail-closed）"
fi
# F1（codex R5 finding，2026-07-14）：此前用 here-string（`<<<`）把清单喂给循环——
# bash 用 here-string 时会在 TMPDIR 下建临时文件；若 TMPDIR 不可写/满，建临时文件失败，
# 循环体一次都不执行，但脚本会不动声色地往下走完剩余判据、报 GATE PASS（fail-open，
# codex 在只读沙箱里实测复现：`cannot create temp file for here document` 后 exit 0）。
# 根治：① 改用显式临时文件 + 检查写入是否成功（mktemp/写入失败立刻 fail-closed，
# 不再依赖 here-string 的隐式临时文件机制）；② 无论循环因为什么原因没跑满，都用一个
# 独立计数器核对「实际执行次数 == 期望条数」，跑少了也必须 fail-closed——这样即使
# 未来出现别的、还没被发现的「循环静默不执行」路径，也会被这道计数闸门挡住。
UIKIT_EXPECTED_COUNT=$(printf '%s\n' "$UIKIT_EXPECTED_TESTS" | grep -c '.' || true)
# 显式模板、显式引用 ${TMPDIR:-/tmp}——裸 `mktemp`（无模板）在 macOS/BSD 上会直接走
# Darwin 每用户临时目录、完全无视 TMPDIR 环境变量，那样这道 fail-closed 检测在本机
# 永远测不出来；显式模板在 macOS 和 Linux（GNU mktemp）上都会老实遵守 TMPDIR。
UIKIT_LIST_FILE="$(mktemp "${TMPDIR:-/tmp}/catalyst-gate-uikit-expected.XXXXXX" 2>&1)" || fail "无法创建临时文件写入 UIKit-gated 期望测试清单（TMPDIR 不可写/已满？):${UIKIT_LIST_FILE}"
printf '%s\n' "$UIKIT_EXPECTED_TESTS" >"$UIKIT_LIST_FILE" || fail "写入 UIKit-gated 期望测试清单临时文件失败：$UIKIT_LIST_FILE"

UIKIT_CHECKED_COUNT=0
while IFS= read -r uikit_test; do
    [ -z "$uikit_test" ] && continue
    UIKIT_CHECKED_COUNT=$((UIKIT_CHECKED_COUNT + 1))
    # F3（codex R5 finding）：swift-testing 对两种 @Test 写法打印格式不同——
    # `@Test("显示名")` 收尾行带字面引号（`Test "显示名" passed`），而 `@Test func 名字()`
    # （无显示名）直接印函数签名、不带引号（`Test 名字() passed`，已用真实 CI 日志核实）。
    # uikit-expected-tests.py 用「名字末尾是不是 "()"」来标记是哪种形式，这里据此决定
    # 要不要在匹配串两侧补引号。
    case "$uikit_test" in
        *'()')
            match_str="Test ${uikit_test} passed"
            ;;
        *)
            match_str="Test \"${uikit_test}\" passed"
            ;;
    esac
    if ! grep -qF "$match_str" "$LOG"; then
        fail "UIKit-gated 测试未执行：${uikit_test} —— 找不到 'passed' 收尾行（UIKit 代码体没有真的跑完，源码推导清单见 uikit-expected-tests.py）"
    fi
done <"$UIKIT_LIST_FILE"
rm -f "$UIKIT_LIST_FILE"

if [ "$UIKIT_CHECKED_COUNT" -ne "$UIKIT_EXPECTED_COUNT" ]; then
    fail "UIKit-gated 逐测试判据没有跑满：期望校验 ${UIKIT_EXPECTED_COUNT} 条，实际只执行了 ${UIKIT_CHECKED_COUNT} 条循环体——判据没有真正执行完（fail-closed，不放行）"
fi

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

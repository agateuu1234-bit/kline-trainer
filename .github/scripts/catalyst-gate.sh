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

# --- G8: 自证——UIKit-gated 测试真的进了编译。
#         金丝雀文件：DrawDrawingsDispatchTests.swift（#if canImport(UIKit) 包裹）。
#         若该文件被改名/删除，本判据会红——这是**有意**的：改名者必须在这里换一个
#         新的 UIKit-gated 金丝雀，而不是让"UIKit 代码已被编译"这条不变量悄悄消失。
if ! grep -q 'DrawDrawingsDispatchTests\.swift' "$LOG"; then
    fail "日志里找不到 DrawDrawingsDispatchTests.swift —— UIKit-gated 测试没进编译（若该文件已改名，请在本脚本里更新金丝雀）"
fi

# --- G7: 自证——测试真的被执行了，且不是 0 个（防 -only-testing 把用例全过滤光）
SUMMARY=$(grep -oE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$LOG" | head -1 || true)
if [ -z "$SUMMARY" ]; then
    fail "找不到 swift-testing 汇总行 'Test run with N tests in M suites passed' —— 测试没被执行"
fi
N_TESTS=$(echo "$SUMMARY" | grep -oE '[0-9]+' | head -1)
if [ "$N_TESTS" -eq 0 ]; then
    fail "swift-testing 执行了 0 个用例（${SUMMARY}）—— 门是空的"
fi

# --- G5: 测试代码警告：只统计、不拦（48 条既有技术债，见 spec §4）
#     去重计数：同一条警告会因增量编译跨多趟重复出现在日志里（原始行数是去重后的 ~7 倍），
#     裸行数会夸大技术债规模，故按 "文件:行:列: warning:" 去重后计数。
TEST_WARN=$(grep -oE 'ios/Contracts/Tests/[^ ]*\.swift:[0-9]+:[0-9]+: warning:' "$LOG" | sort -u | wc -l | tr -d ' ' || true)

echo "GATE PASS"
echo "  执行用例数（swift-testing）: $SUMMARY"
echo "  Tests/ 警告去重条数（既有技术债，不拦门）: $TEST_WARN 条"

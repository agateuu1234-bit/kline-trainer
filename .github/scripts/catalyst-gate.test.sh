#!/usr/bin/env bash
# 闸门脚本的单元测试。fixture 是真实抓取的 xcodebuild 日志裁剪件，或为隔离单条判据而手工构造的最小样本。
# 本仓的教训：一个没人测过的闸门，可以报绿半年而什么都不验证。所以闸门本身必须有测试。
#
# 教训 2（本文件曾踩过）：只断言退出码不够——一个 fixture 可能因为"错的"判据而拦截，
# 却看起来像是覆盖了它名义上要测的那条判据（比如 hollow-old-scheme.log 实际是被 G2 拦下的，
# 从未真正让 G6 开口）。所以每条负向用例都必须同时核对**判据专属的失败信息**，
# 而不能只看退出码是不是 1。

DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$DIR/catalyst-gate.sh"
FIX="$DIR/fixtures"
PASSED=0; FAILED=0

expect() {  # expect <期望退出码> <fixture> <期望输出中必须出现的专属子串（通过用例传 ""）> <说明>
    local want="$1" fixture="$2" match="$3" desc="$4"
    local out
    out=$(bash "$GATE" "$FIX/$fixture" 2>&1)
    local got=$?
    if [ "$got" -ne "$want" ]; then
        echo "  FAIL — $desc (期望 exit=${want}，实得 exit=$got)"
        FAILED=$((FAILED + 1))
        return
    fi
    if [ -n "$match" ] && ! grep -qF -- "$match" <<<"$out"; then
        echo "  FAIL — $desc (退出码对，但输出里没有判据专属信息 \"$match\"——可能是别的判据碰巧也拦下了它)"
        FAILED=$((FAILED + 1))
        return
    fi
    echo "  ok   — $desc (exit=$got)"
    PASSED=$((PASSED + 1))
}

echo "catalyst-gate.sh 判据测试："
expect 0 pass-new-scheme.log            "GATE PASS" \
    "新 scheme 的真实成功日志 → 通过（且不被 CoreData 运行期噪声误伤）"

# hollow-old-scheme.log 是真实抓取的旧 scheme 空壳日志（历史回归现场），故意保留、不删。
# 它同时踩中 G2（无 TEST SUCCEEDED）和 G6（无 KlineTrainerContractsTests）——过度判定，
# 因为脚本按顺序执行、G2 先触发，所以这条 fixture 实际只验证了 G2，从未真正让 G6 开口。
# 下面紧跟的 missing-test-succeeded.log 才是把 G2 单独隔离出来的判据专属用例；
# G6 的隔离用例见 missing-test-target-marker.log。
expect 1 hollow-old-scheme.log          "缺少 '** TEST SUCCEEDED **' 标记" \
    "旧 scheme 的空壳日志（真实抓取，TEST BUILD SUCCEEDED 但零测试；过度判定见上注）→ 必须拦截【回归】"

expect 1 missing-test-succeeded.log     "缺少 '** TEST SUCCEEDED **' 标记" \
    "G2 隔离：仅缺 TEST SUCCEEDED 标记，其余判据全过 → 必须且只能由 G2 拦截"

expect 1 compile-error.log              "检测到编译器错误" \
    "含编译器 error: → 拦截（G3）"

expect 1 sources-warning.log            "生产代码 Sources/ 出现编译警告" \
    "生产代码 Sources/ 出现警告 → 拦截（G4）"

expect 1 missing-test-target-marker.log "测试 target 根本没被编译" \
    "G6 隔离：测试 target 标记（模拟改名）整体缺失，其余判据全过 → 必须且只能由 G6 拦截"

expect 1 canary-file-renamed.log        "UIKit-gated 测试没进编译" \
    "G8 隔离：金丝雀文件 DrawDrawingsDispatchTests.swift 改名/缺失，测试 target 本身仍编译 → 必须且只能由 G8 拦截"

expect 1 zero-tests.log                 "执行了 0 个用例" \
    "swift-testing 执行 0 个用例 → 拦截（G7·零计数分支）"

expect 1 missing-summary-line.log       "找不到 swift-testing 汇总行" \
    "swift-testing 汇总行整体缺失（非 0 个用例，而是行都没有）→ 拦截（G7·缺失分支）"

echo "结果：$PASSED 通过，$FAILED 失败"
[ "$FAILED" -eq 0 ]

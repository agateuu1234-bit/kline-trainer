#!/usr/bin/env bash
# 闸门脚本的单元测试。fixture 是真实抓取的 xcodebuild 日志裁剪件。
# 本仓的教训：一个没人测过的闸门，可以报绿半年而什么都不验证。所以闸门本身必须有测试。
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$DIR/catalyst-gate.sh"
FIX="$DIR/fixtures"
PASSED=0; FAILED=0

expect() {  # expect <期望退出码> <fixture> <说明>
    local want="$1" fixture="$2" desc="$3"
    bash "$GATE" "$FIX/$fixture" >/dev/null 2>&1
    local got=$?
    if [ "$got" -eq "$want" ]; then
        echo "  ok   — $desc (exit=$got)"
        PASSED=$((PASSED + 1))
    else
        echo "  FAIL — $desc (期望 exit=${want}，实得 exit=$got)"
        FAILED=$((FAILED + 1))
    fi
}

echo "catalyst-gate.sh 判据测试："
expect 0 pass-new-scheme.log     "新 scheme 的真实成功日志 → 通过（且不被 CoreData 运行期噪声误伤）"
expect 1 hollow-old-scheme.log   "旧 scheme 的空壳日志（TEST BUILD SUCCEEDED 但零测试）→ 必须拦截【回归】"
expect 1 compile-error.log       "含编译器 error: → 拦截"
expect 1 sources-warning.log     "生产代码 Sources/ 出现警告 → 拦截"
expect 1 zero-tests.log          "swift-testing 执行 0 个用例 → 拦截"

echo "结果：$PASSED 通过，$FAILED 失败"
[ "$FAILED" -eq 0 ]

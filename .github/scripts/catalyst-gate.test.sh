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

# fail-closed 下限哨兵（codex R4 finding，2026-07-14）：catalyst-gate.sh 不再手工维护
# UIKIT_SUITES/UIKIT_TESTS 硬编码列表，改成运行时调用 uikit-expected-tests.py 从源码
# 推导「应当执行的 UIKit-gated 测试全集」。这条检测不是精确判据——它只是防止解析器
# 坏掉/测试被大批误删后闸门空转变绿的最后防线：当前源码真实产出 28 个（见 codex 复核
# 结论），阈值 20 留了余量给正常的测试增删，不要把它设成等于当前真实值。
# 若推导脚本本身返回空清单/非零退出，本检测同样必须失败（fail-closed）。
echo "UIKit-gated 期望测试清单 fail-closed 下限检测："
UIKIT_EXPECTED_COUNT=$(python3 "$DIR/uikit-expected-tests.py" 2>/dev/null | grep -c '.' || true)
UIKIT_EXPECTED_RC=$?
if [ "$UIKIT_EXPECTED_RC" -eq 0 ] 2>/dev/null && [ "${UIKIT_EXPECTED_COUNT:-0}" -ge 20 ]; then
    echo "  ok   — uikit-expected-tests.py 推导出 ${UIKIT_EXPECTED_COUNT} 个测试名（>= 20 下限）"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — uikit-expected-tests.py 推导出 ${UIKIT_EXPECTED_COUNT:-0} 个测试名，低于下限 20（或脚本执行失败）"
    FAILED=$((FAILED + 1))
fi
echo

# F2（codex R5 finding，2026-07-14）：以下 fixture 用例测的是「G8 判据逻辑本身对不对」，
# 不是「当前源码长什么样」。若让它们像生产环境一样从当前源码实时推导期望清单，任何 PR
# 只要新增/改名一个 UIKit-gated @Test，推导清单就会比 fixture 静态日志里的多一条，本文件
# 就会在 xcodebuild 真跑之前先崩——复现见下方 "F2 验收" 注。改用一份跟 fixture 日志配套、
# 冻结在提交历史里的期望清单（fixtures/uikit-expected-tests.frozen.txt），通过
# catalyst-gate.sh 已有的 UIKIT_EXPECTED_TESTS_SCRIPT 注入点喂给下面所有 `expect` 调用。
# 真实 xcodebuild 日志（workflow 里的真跑）不设这个环境变量，仍走 catalyst-gate.sh 的
# 默认值——对当前源码做实时推导，源码推导的保护完全没丢（见本文件末尾的独立验证）。
export UIKIT_EXPECTED_TESTS_SCRIPT="$FIX/uikit-expected-tests-frozen.py"

echo "catalyst-gate.sh 判据测试（fixture 用例，期望清单已冻结，不随当前源码漂移）："
expect 0 pass-new-scheme.log            "GATE PASS" \
    "新 scheme 的真实成功日志（本地 Xcode 格式）→ 通过（且不被 CoreData 运行期噪声误伤）"

# G7 环境保真度回归（2026-07-13，PR #145 真 CI 首跑现场）：本地 Xcode 与 CI 的 macos-15
# 输出的 swift-testing 汇总行格式不一样——本地是 'Test run with N tests in M suites passed'，
# CI 是 'Test run with N tests passed'（没有 "in M suites"）。fixture 集合必须同时覆盖两种格式，
# 否则闸门只在本地测过、从未见过真 CI 的输出长什么样，会在 CI 上误判 FAIL（测试其实全过了）。
# pass-ci-format.log 是从真实 CI 日志裁剪的（未手打），专门锁住这个格式分支。
expect 0 pass-ci-format.log             "GATE PASS" \
    "真 CI（macos-15）格式的成功日志，无 'in M suites' 分段 → 通过，且用例数取到 1407 而非 0"

# F1 补充断言（2026-07-14）：只看 "GATE PASS" 不够——G7 的下限判据可能悄悄拿错数字
# 却依然报 PASS（比如误取了 "in M suites" 里的 M）。必须核实闸门自己回显的执行用例数
# 确实是这份 CI fixture 的真实值 1407，而不是随便一个 >= MIN_TESTS 的数字。
expect 0 pass-ci-format.log             "1407" \
    "F1 补充：CI fixture 解析出的用例数确实是 1407（不只是退出码/GATE PASS 字样对）"

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

# F2 回归（2026-07-14，codex 对抗评审实测确认可利用）：旧 G8 只 grep 金丝雀文件名
# DrawDrawingsDispatchTests.swift，但该文件的测试体裹在 #if canImport(UIKit) 里——
# 非 Catalyst destination（如 platform=macOS）下文件依然会被编译（文件名照样进日志），
# 只是宏剔除了测试体，UIKit 套件实际执行 0 次。no-catalyst-no-uikit.log 是从真实抓取的
# host-macos.log（非 Catalyst 完整成功日志）裁剪的：TEST SUCCEEDED、金丝雀文件名、
# 1380 个用例全过——除了 macabi 和 UIKit 套件收尾行之外，其余判据全部满足。
# 旧 G8（裸文件名 grep）会判它 GATE PASS；新 G8（macabi + UIKit 套件收尾）必须拦截。
expect 1 no-catalyst-no-uikit.log       "macabi" \
    "F2 回归：真实非 Catalyst 完整成功日志（金丝雀文件名/TEST SUCCEEDED/1380 用例全过，唯独没编译成 Catalyst）→ 必须且只能由 G8·macabi 拦截"

expect 1 missing-macabi-marker.log      "macabi" \
    "G8 隔离 A：macabi 证据缺失，UIKit 套件收尾行仍在，其余判据全过 → 必须且只能由 G8·macabi 分支拦截"

# codex R4 finding 回归（2026-07-14）：UIKIT_SUITES/UIKIT_TESTS 硬编码哨兵列表只钉「套件/
# 单个测试跑完了」，从不逐个检查套件里的每个测试——DrawDrawingsDispatchTests 7 个测试只钉了
# 1 个，另外 6 个被删/跳过闸门无感；同样的缺陷在其余 6 个套件里也成立。根治后 catalyst-gate.sh
# 改成运行时从源码推导「全部 28 个 UIKit-gated 测试」，逐个断言 "Test ... passed"。
# missing-one-uikit-test.log 是从真实 CI 日志（pass-ci-format.log 的裁剪基底，逐行摘自
# ci-catalyst-real.log）删掉唯独一个**非哨兵**测试 —— DrawDrawingsDispatchTests 的第 2 个
# 测试「§5.3 #15 registered tool render called once with passed-through drawing」的
# started/passed 两行（模拟它被删/跳过），其余 27 个测试、macabi、全部其它判据均满足——
# 专门证明新的逐测试判据是承重的：删掉任何一个（哪怕不是旧哨兵列表里的那个）GATE 都必须 FAIL。
expect 1 missing-one-uikit-test.log     "UIKit-gated 测试未执行：§5.3 #15 registered tool render called once with passed-through drawing" \
    "G8 隔离 C（codex R4 回归）：源码推导出的 28 个测试之一（非旧硬编码哨兵）单独缺失，其余 27 个+macabi+全部判据全过 → 必须且只能由 G8·逐测试判据拦截，并点名具体测试"

expect 1 zero-tests.log                 "门是空的" \
    "swift-testing 执行 0 个用例 → 拦截（G7·零计数分支）（match 用 G7·零计数分支专属尾句，'执行了 0 个用例' 会被 MIN_TESTS 分支的消息文字包含，不够专属）"

expect 1 missing-summary-line.log       "找不到 swift-testing 汇总行" \
    "swift-testing 汇总行整体缺失（非 0 个用例，而是行都没有）→ 拦截（G7·缺失分支）"

# F1（medium，2026-07-14）：G7 原本只在用例数 == 0 时才拦，-only-testing 被收窄到
# 只剩个位数用例也能过。too-few-tests.log 是 pass-new-scheme.log 基线上把汇总行
# 用例数改成 500（< MIN_TESTS=1200，非 0）构造的隔离用例，其余判据（含 macabi/UIKit
# 套件）全过，专门验证新增的下限判据。
expect 1 too-few-tests.log              "低于下限" \
    "G7 隔离：用例数 500（非 0，< MIN_TESTS 1200），其余判据全过 → 必须且只能由 G7·下限分支拦截"

# C1 回归：xcodebuild 命令行回显本身就带 -only-testing:KlineTrainerContractsTests + 金丝雀文件名
# 也出现在 SwiftDriverJobDiscovery（任务规划，非真编译）行里——但整份日志没有一行 SwiftCompile、
# 没有一处 Tests/KlineTrainerContractsTests/ 源码路径。旧的裸字符串锚点会被这份日志骗过
# （GATE PASS），只有锚在源码路径上的 G6 才拦得住。
expect 1 echo-only-no-compile.log       "测试 target 根本没被编译" \
    "C1 回归：仅命令行回显 + 任务规划行，零 SwiftCompile 证据 → 必须由 G6 拦截"

# fail-closed 自动化回归（codex R4 finding 交付物 #3）：uikit-expected-tests.py 如果坏掉
# （空清单/非零退出），闸门绝不能把「没有期望项」误判成「全部通过」。用 UIKIT_EXPECTED_TESTS_SCRIPT
# 注入一个假的推导脚本，对 pass-ci-format.log（本该 GATE PASS 的真实成功日志）重跑一遍，
# 断言两种坏情况都必须 FAIL。
FAKE_EMPTY_SCRIPT="$FIX/../.fake-uikit-expected-empty.py"
FAKE_CRASH_SCRIPT="$FIX/../.fake-uikit-expected-crash.py"
printf '#!/usr/bin/env python3\n# 测试用：模拟推导脚本返回空清单但退出码 0\n' > "$FAKE_EMPTY_SCRIPT"
printf '#!/usr/bin/env python3\nimport sys\nprint("boom", file=sys.stderr)\nsys.exit(1)\n' > "$FAKE_CRASH_SCRIPT"

out=$(UIKIT_EXPECTED_TESTS_SCRIPT="$FAKE_EMPTY_SCRIPT" bash "$GATE" "$FIX/pass-ci-format.log" 2>&1)
got=$?
if [ "$got" -eq 1 ] && grep -qF "UIKit-gated 测试清单推导为空" <<<"$out"; then
    echo "  ok   — fail-closed A：推导脚本空清单（退出码 0）→ 必须 FAIL，不能因'没有期望项'放行 (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — fail-closed A：推导脚本空清单本该 FAIL 且报'推导为空'，实得 exit=$got, out=$out"
    FAILED=$((FAILED + 1))
fi

out=$(UIKIT_EXPECTED_TESTS_SCRIPT="$FAKE_CRASH_SCRIPT" bash "$GATE" "$FIX/pass-ci-format.log" 2>&1)
got=$?
if [ "$got" -eq 1 ] && grep -qF "UIKit-gated 测试清单推导失败" <<<"$out"; then
    echo "  ok   — fail-closed B：推导脚本异常退出（exit=1）→ 必须 FAIL (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — fail-closed B：推导脚本异常退出本该 FAIL 且报'推导失败'，实得 exit=$got, out=$out"
    FAILED=$((FAILED + 1))
fi
rm -f "$FAKE_EMPTY_SCRIPT" "$FAKE_CRASH_SCRIPT"

# F1（high，2026-07-14，codex R5 finding）：旧实现用 here-string（`<<<`）把 G8 逐测试判据
# 的期望清单喂给循环——bash 用 here-string 会在 TMPDIR 下建临时文件，若 TMPDIR 不可写/满，
# 建临时文件失败，循环体一次都不执行，脚本却会不动声色地往下走完剩余判据、报 GATE PASS
# （fail-open，codex 在只读沙箱里用这个手法实测复现："cannot create temp file for here
# document" 后 exit 0）。根治后改用显式临时文件 + mktemp/写入失败立刻 fail-closed，外加
# 一道独立计数断言（实际执行次数 != 期望条数就拦）。下面把 TMPDIR 指到一个不存在的目录，
# 逼显式 mktemp 失败，验证新实现会在"建清单临时文件"这一步就 fail-closed，而不是像旧版
# 一样悄悄放行（注意：裸 `mktemp` 在本机 macOS/BSD 上会无视 TMPDIR，所以 catalyst-gate.sh
# 改成了显式模板 `mktemp "${TMPDIR:-/tmp}/....XXXXXX"`——这道回归同时验证了这一点）。
echo
echo "F1（codex R5）：TMPDIR 不可写 → G8 逐测试判据必须 fail-closed，不能 fail-open："
BROKEN_TMPDIR="$FIX/../.nonexistent-tmpdir-for-f1-regression-$$"
rm -rf "$BROKEN_TMPDIR" 2>/dev/null || true
out=$(TMPDIR="$BROKEN_TMPDIR" bash "$GATE" "$FIX/pass-ci-format.log" 2>&1)
got=$?
if [ "$got" -eq 1 ] && grep -qF "无法创建临时文件写入 UIKit-gated 期望测试清单" <<<"$out"; then
    echo "  ok   — TMPDIR 指向不存在目录（模拟 TMPDIR 不可写）→ 必须 FAIL，不能 fail-open (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — TMPDIR 不可写本该 FAIL 且报'无法创建临时文件'，实得 exit=$got, out=$out"
    FAILED=$((FAILED + 1))
fi
rm -rf "$BROKEN_TMPDIR" 2>/dev/null || true

# F1 结构性回归：防止未来有人把实现改回有 fail-open 隐患的 here-string 写法而没人发现。
if grep -qE '<<<[[:space:]]*"\$UIKIT_EXPECTED_TESTS"' "$GATE"; then
    echo "  FAIL — 结构性回归：catalyst-gate.sh 又出现了 here-string 喂 UIKIT_EXPECTED_TESTS 的写法"
    FAILED=$((FAILED + 1))
else
    echo "  ok   — 结构性回归：catalyst-gate.sh 不再用 here-string 喂 G8 逐测试循环"
    PASSED=$((PASSED + 1))
fi

# F1 计数回归：正常路径下"实际执行次数 == 期望条数（冻结清单 28 条）"必须放行——
# 防止计数断言本身有 off-by-one 之类的 bug 而把正常路径也拦掉。
out=$(bash "$GATE" "$FIX/pass-ci-format.log" 2>&1)
got=$?
if [ "$got" -eq 0 ] && grep -qF "GATE PASS" <<<"$out"; then
    echo "  ok   — 正常路径计数 == 28（冻结清单条数）→ PASS，不被新增的计数断言误伤 (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — 正常路径本该 PASS，实得 exit=$got, out=$out"
    FAILED=$((FAILED + 1))
fi

echo "结果：$PASSED 通过，$FAILED 失败"
[ "$FAILED" -eq 0 ]

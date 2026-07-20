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

# F1（codex R6 finding，2026-07-15）：生产闸门已经不再对当前源码活推导 UIKit-gated
# 期望清单——改成读取签入仓库的基线文件 catalyst-uikit-baseline.txt（见 catalyst-gate.sh
# 里 UIKIT_EXPECTED_TESTS_SCRIPT 默认值改成 catalyst-uikit-baseline-reader.py）。这是为了
# 堵住循环论证：此前"期望清单"直接源于"被检查的同一份源码"，一个删掉 UIKit 测试的 PR
# 会让期望清单跟着缩水，闸门不再要求那些 passed 行，必需门照样绿。
#
# 但基线一旦签入仓库，就必须有人守着它别跟源码脱节——否则基线本身也会变成一份
# 手工维护、迟早腐烂的哨兵列表。本检测就是这道守护：在 xcodebuild 真跑之前，对当前
# checkout 的源码调用 uikit-expected-tests.py 做活推导，逐行跟基线文件精确比对
# （不是本文件之前那种 ">= 20" 的宽松下限——下限挡不住"删了几个但还没跌破 20"的情形，
# 而 20 这个数字本身也只是曾经的真实值打了折扣，跟着源码增删就会失去意义）。
# 不一致（新增/删除/改名任意一个）→ 自测本身 FAIL，报错提示如何重新生成基线并同步进
# 本次 PR（同步动作必须留在 diff 里被评审看见，不能悄悄发生）。
echo "UIKit-gated 期望测试清单基线一致性检测（F1）："
UIKIT_BASELINE_FILE="$DIR/catalyst-uikit-baseline.txt"
UIKIT_LIVE_DERIVED=$(python3 "$DIR/uikit-expected-tests.py" 2>&1)
UIKIT_LIVE_RC=$?
if [ "$UIKIT_LIVE_RC" -ne 0 ]; then
    echo "  FAIL — uikit-expected-tests.py 对当前源码非零退出（exit=${UIKIT_LIVE_RC}）：${UIKIT_LIVE_DERIVED}"
    FAILED=$((FAILED + 1))
elif [ ! -f "$UIKIT_BASELINE_FILE" ]; then
    echo "  FAIL — 基线文件不存在: $UIKIT_BASELINE_FILE"
    FAILED=$((FAILED + 1))
elif [ "$UIKIT_LIVE_DERIVED" != "$(cat "$UIKIT_BASELINE_FILE")" ]; then
    echo "  FAIL — 当前源码推导出的 UIKit-gated 测试清单与基线 catalyst-uikit-baseline.txt 不一致"
    echo "         若这是有意为之（新增/删除/改名了 UIKit-gated 测试），请重新生成基线并提交："
    echo "           python3 .github/scripts/uikit-expected-tests.py > .github/scripts/catalyst-uikit-baseline.txt"
    diff <(printf '%s\n' "$UIKIT_LIVE_DERIVED") "$UIKIT_BASELINE_FILE" | head -20
    FAILED=$((FAILED + 1))
else
    UIKIT_LIVE_COUNT=$(printf '%s\n' "$UIKIT_LIVE_DERIVED" | grep -c '.')
    echo "  ok   — 当前源码推导出的 ${UIKIT_LIVE_COUNT} 个测试名与基线 catalyst-uikit-baseline.txt 完全一致"
    PASSED=$((PASSED + 1))
fi

# F5（codex R9 finding，2026-07-15）：基线文件内部不能有重复名——同名会让 G8 的一份
# 'passed' 结果顶替多个断言（见 catalyst-gate.sh 里 UIKIT_DUP_NAMES 检测）。这里只是
# 静态核对签入仓库的基线文件本身干不干净；catalyst-gate.sh 运行时会对任何来源的期望
# 清单（含基线文件）做同样检测，自动化回归见下方 fail-closed 区块。
UIKIT_BASELINE_DUPS="$(sort "$UIKIT_BASELINE_FILE" | uniq -d)"
if [ -n "$UIKIT_BASELINE_DUPS" ]; then
    echo "  FAIL — 基线文件 catalyst-uikit-baseline.txt 内部有重复名：$UIKIT_BASELINE_DUPS"
    FAILED=$((FAILED + 1))
else
    echo "  ok   — 基线文件内部无重复名"
    PASSED=$((PASSED + 1))
fi
echo

# F1 漂移双向检测自动化回归（codex R6 finding「关键不变量」，2026-07-15）：上面那条断言
# 只在真仓库里跑一次，本身没有测过"它真的会在基线漂移时报错"。用一棵隔离的临时源码树
# （不碰真仓库/真源码）证明：① 删掉一个 UIKit-gated @Test 而不同步改基线 → 检测到不一致
# 且点名少了哪一行；② 反向，新增一个 UIKit-gated @Test 而不同步改基线 → 同样检测到不
# 一致且点名多了哪一行。两个方向都必须被抓到，不能只测单向。
echo "F1 漂移双向检测（基线不同步必须被抓到，隔离 fixture 树）："
DRIFT_ROOT="$FIX/../.uikit-baseline-drift-fixture-$$"
rm -rf "$DRIFT_ROOT" 2>/dev/null || true
mkdir -p "$DRIFT_ROOT/.github/scripts" "$DRIFT_ROOT/ios/Contracts/Tests/KlineTrainerContractsTests"
cp "$DIR/uikit-expected-tests.py" "$DRIFT_ROOT/.github/scripts/uikit-expected-tests.py"
cat > "$DRIFT_ROOT/ios/Contracts/Tests/KlineTrainerContractsTests/DriftFixtureTests.swift" <<'SWIFTEOF'
#if canImport(UIKit)
import Testing

struct DriftFixtureTests {
    @Test("drift fixture test A") func a() {}
    @Test("drift fixture test B") func b() {}
}
#endif
SWIFTEOF
DRIFT_BASELINE="$DRIFT_ROOT/baseline.txt"
python3 "$DRIFT_ROOT/.github/scripts/uikit-expected-tests.py" > "$DRIFT_BASELINE"
# 先确认基线刚生成时（同步状态）确实判一致——否则下面两个"不一致"用例的对照组都不成立。
DRIFT_LIVE=$(python3 "$DRIFT_ROOT/.github/scripts/uikit-expected-tests.py" 2>&1)
if [ "$DRIFT_LIVE" = "$(cat "$DRIFT_BASELINE")" ]; then
    echo "  ok   — 对照组：基线刚生成、源码未改动 → 判一致"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — 对照组：基线刚生成就判不一致，比对逻辑本身有问题"
    FAILED=$((FAILED + 1))
fi

# ① 删掉一个测试，不改基线 → 必须判不一致，且 diff 点名被删的那一行。
sed -i.bak '/drift fixture test B/d' "$DRIFT_ROOT/ios/Contracts/Tests/KlineTrainerContractsTests/DriftFixtureTests.swift"
DRIFT_LIVE_AFTER_DELETE=$(python3 "$DRIFT_ROOT/.github/scripts/uikit-expected-tests.py" 2>&1)
if [ "$DRIFT_LIVE_AFTER_DELETE" != "$(cat "$DRIFT_BASELINE")" ] \
    && ! printf '%s\n' "$DRIFT_LIVE_AFTER_DELETE" | grep -qF "drift fixture test B"; then
    echo "  ok   — 删测试不改基线 → 判不一致（少了 'drift fixture test B'，基线仍列着它）"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — 删测试不改基线本该判不一致，实得 live=[$DRIFT_LIVE_AFTER_DELETE]"
    FAILED=$((FAILED + 1))
fi
mv "$DRIFT_ROOT/ios/Contracts/Tests/KlineTrainerContractsTests/DriftFixtureTests.swift.bak" \
   "$DRIFT_ROOT/ios/Contracts/Tests/KlineTrainerContractsTests/DriftFixtureTests.swift"

# ② 反向：新增一个测试，不改基线 → 必须判不一致，且新增的测试出现在活推导里、不在基线里。
cat >> "$DRIFT_ROOT/ios/Contracts/Tests/KlineTrainerContractsTests/DriftFixtureTests.swift" <<'SWIFTEOF2'

#if canImport(UIKit)
struct DriftFixtureExtraTests {
    @Test("drift fixture test C (new, not in baseline)") func c() {}
}
#endif
SWIFTEOF2
DRIFT_LIVE_AFTER_ADD=$(python3 "$DRIFT_ROOT/.github/scripts/uikit-expected-tests.py" 2>&1)
if [ "$DRIFT_LIVE_AFTER_ADD" != "$(cat "$DRIFT_BASELINE")" ] \
    && printf '%s\n' "$DRIFT_LIVE_AFTER_ADD" | grep -qF "drift fixture test C (new, not in baseline)"; then
    echo "  ok   — 加测试不改基线 → 判不一致（活推导多出 'drift fixture test C'，基线里没有）"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — 加测试不改基线本该判不一致，实得 live=[$DRIFT_LIVE_AFTER_ADD]"
    FAILED=$((FAILED + 1))
fi
rm -rf "$DRIFT_ROOT" 2>/dev/null || true
echo

# F2（codex R6 finding，2026-07-15）：uikit-expected-tests.py 的块识别/depth 计数正则此前
# 都是列首锚定（^#if/^#endif），缩进写法的 `#if canImport(UIKit)`（Swift 合法写法，本仓
# DecelerationAnimatorTests.swift 已有缩进的 `#if !canImport(UIKit)` 先例）整个块都不会
# 被发现——块内的 @Test 既不进期望清单，也不会被未归属检测兜住（块没被识别，扫描根本
# 没进去）。用隔离 fixture 树验证修复：缩进的 UIKit-gated 块里的测试必须出现在推导清单里。
echo "F2：缩进的 #if canImport(UIKit) 块必须被发现（隔离 fixture 树）："
INDENT_ROOT="$FIX/../.uikit-indented-block-fixture-$$"
rm -rf "$INDENT_ROOT" 2>/dev/null || true
mkdir -p "$INDENT_ROOT/.github/scripts" "$INDENT_ROOT/ios/Contracts/Tests/KlineTrainerContractsTests"
cp "$DIR/uikit-expected-tests.py" "$INDENT_ROOT/.github/scripts/uikit-expected-tests.py"
cat > "$INDENT_ROOT/ios/Contracts/Tests/KlineTrainerContractsTests/IndentedBlockFixtureTests.swift" <<'SWIFTEOF3'
enum Wrapper {
    #if canImport(UIKit)
    struct IndentedBlockFixtureTests {
        @Test("indented UIKit block test (F2 regression)") func indented() {}
    }
    #endif
}
SWIFTEOF3
out=$(python3 "$INDENT_ROOT/.github/scripts/uikit-expected-tests.py" 2>&1)
got=$?
if [ "$got" -eq 0 ] && grep -qF "indented UIKit block test (F2 regression)" <<<"$out"; then
    echo "  ok   — 缩进的 #if canImport(UIKit) 块被发现，块内测试出现在推导清单里 (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — 缩进块本该被发现且测试出现在清单里，实得 exit=$got, out=$out"
    FAILED=$((FAILED + 1))
fi
rm -rf "$INDENT_ROOT" 2>/dev/null || true

# R7（codex R7 finding，2026-07-15）：块识别此前要求整行精确等于 `#if canImport(UIKit)`
# （允许前导/尾随空白），复合条件（`&& targetEnvironment(macCatalyst)`，任意顺序）与尾注释
# （`#if canImport(UIKit) // 注释`）都不精确匹配，整个块连同块内 @Test 都不进期望清单、
# 也不被未归属检测兜住。同一份 fixture 还核对反向陷阱：不能简单放宽成「行内含
# canImport(UIKit)」，否则 `#if !canImport(UIKit)`（本仓 DecelerationAnimatorTests.swift:205
# 的真实写法，非 UIKit 环境专属块）会被误纳入。用隔离 fixture 树一次验证「复合条件+尾注释
# 都被纳入」和「反向门被排除」两件事：正向的 3 个测试必须齐全出现，反向门里的测试必须
# 不出现，且推导总数精确等于 3（不多不少，防止反向门被误纳后靠其它判据碰巧掩盖）。
echo
echo "R7：复合条件 / 尾注释块被纳入 + 反向门 !canImport(UIKit) 被排除（隔离 fixture 树）："
R7_ROOT="$FIX/../.uikit-r7-polarity-fixture-$$"
rm -rf "$R7_ROOT" 2>/dev/null || true
mkdir -p "$R7_ROOT/.github/scripts" "$R7_ROOT/ios/Contracts/Tests/KlineTrainerContractsTests"
cp "$DIR/uikit-expected-tests.py" "$R7_ROOT/.github/scripts/uikit-expected-tests.py"
cat > "$R7_ROOT/ios/Contracts/Tests/KlineTrainerContractsTests/R7PolarityFixtureTests.swift" <<'SWIFTEOF4'
#if canImport(UIKit) && targetEnvironment(macCatalyst)
struct R7CompoundUIKitFirstTests {
    @Test("R7 compound AND UIKit-first") func compoundFirst() {}
}
#endif

#if targetEnvironment(macCatalyst) && canImport(UIKit)
struct R7CompoundUIKitLastTests {
    @Test("R7 compound AND UIKit-last") func compoundLast() {}
}
#endif

#if canImport(UIKit) // trailing comment probe
struct R7TrailingCommentTests {
    @Test("R7 trailing comment") func trailingComment() {}
}
#endif

#if !canImport(UIKit)
struct R7NegativeGateTests {
    @Test("R7 negative gate must not appear") func negativeGate() {}
}
#endif
SWIFTEOF4
out=$(python3 "$R7_ROOT/.github/scripts/uikit-expected-tests.py" 2>&1)
got=$?
out_count=$(printf '%s\n' "$out" | grep -c '.')
if [ "$got" -eq 0 ] && [ "$out_count" -eq 3 ] \
    && grep -qF "R7 compound AND UIKit-first" <<<"$out" \
    && grep -qF "R7 compound AND UIKit-last" <<<"$out" \
    && grep -qF "R7 trailing comment" <<<"$out" \
    && ! grep -qF "R7 negative gate must not appear" <<<"$out"; then
    echo "  ok   — 复合条件（两种顺序）+ 尾注释块的 3 个测试全部纳入，反向门 !canImport(UIKit) 里的测试被排除，总数精确=3 (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — R7 极性判定回归，实得 exit=$got, count=$out_count, out=$out"
    FAILED=$((FAILED + 1))
fi
rm -rf "$R7_ROOT" 2>/dev/null || true

# F2（codex R5 finding，2026-07-14）：以下 fixture 用例测的是「G8 判据逻辑本身对不对」，
# 不是「当前源码长什么样」。若让它们像生产环境一样从当前源码实时推导期望清单，任何 PR
# 只要新增/改名一个 UIKit-gated @Test，推导清单就会比 fixture 静态日志里的多一条，本文件
# 就会在 xcodebuild 真跑之前先崩——复现见下方 "F2 验收" 注。改用一份跟 fixture 日志配套、
# 冻结在提交历史里的期望清单（fixtures/uikit-expected-tests.frozen.txt），通过
# catalyst-gate.sh 已有的 UIKIT_EXPECTED_TESTS_SCRIPT 注入点喂给下面所有 `expect` 调用。
# 真实 xcodebuild 日志（workflow 里的真跑）不设这个环境变量，仍走 catalyst-gate.sh 的
# 默认值——对当前源码做实时推导，源码推导的保护完全没丢（见本文件末尾的独立验证）。
export UIKIT_EXPECTED_TESTS_SCRIPT="$FIX/uikit-expected-tests-frozen.py"

# total 基线同理解耦（2026-07-18）：下面的 fixture 用例测的是「G7 total 判据逻辑」，
# 不是「main 当前真实总数」。若让它们读活 catalyst-total-baseline.txt，任何大幅增减
# 测试的 PR（如 #146 加 50 个）把活基线一挪，这些围绕 1407 构造的 fixture 就整片掉出
# delta 窗口、自测在真跑之前先崩（复现：main 6068522 F1 变红事故）。改用一份跟 fixture
# 日志配套、冻结在提交历史里的 total 基线（fixtures/total-baseline-frozen.txt=1407），
# 通过 catalyst-gate.sh 已有的 CATALYST_TOTAL_BASELINE_FILE 注入点喂给下面所有 expect。
# 真实 xcodebuild 日志（workflow 真跑）不设这个环境变量，仍走默认的活 catalyst-total-
# baseline.txt——活基线的保护完全没丢（见下方「活基线覆盖」用例）。
export CATALYST_TOTAL_BASELINE_FILE="$FIX/total-baseline-frozen.txt"

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

# F4（codex R9 finding，2026-07-15，实测可利用）：旧 G8 逐测试判据是裸子串
# grep -qF 'Test "<名>" passed'，不锚定行首、不要求 ✔ 前缀——只要日志任何位置出现这串
# 字符就算数。stdout-spoof.log 从 pass-ci-format.log（真实 CI 日志裁剪件）裁出：删掉
# "§5.3 #14 drawDrawings with empty list calls no render" 的真实 ✔ 结果行，改在别处插入
# 一条**没有 ✔ 前缀的普通缩进 stdout**（`  some test stdout: Test "<名>" passed`，模拟
# 另一个测试自己打印的调试信息碰巧含有这串文字）。旧判据会被这条伪造 stdout 骗过，
# GATE PASS；新判据要求真实结果行专属的 ✔ 前缀 + ' passed after ' 收尾，必须拦截并
# 点名这一个测试（其余 27 个 UIKit 测试 + macabi + 全部其它判据均满足）。
expect 1 stdout-spoof.log               "UIKit-gated 测试未执行：§5.3 #14 drawDrawings with empty list calls no render" \
    "F4（codex R9 回归）：真实 ✔ 结果行被删、改插一条没有 ✔ 前缀的伪造 stdout（裸文字命中旧判据）→ 必须且只能由 G8·逐测试判据拦截，并点名具体测试"

expect 1 zero-tests.log                 "门是空的" \
    "swift-testing 执行 0 个用例 → 拦截（G7·零计数分支）（match 用 G7·零计数分支专属尾句，'执行了 0 个用例' 会被 MIN_TESTS 分支的消息文字包含，不够专属）"

expect 1 missing-summary-line.log       "找不到 swift-testing 汇总行" \
    "swift-testing 汇总行整体缺失（非 0 个用例，而是行都没有）→ 拦截（G7·缺失分支）"

# F4（codex R9 finding，2026-07-15）：G7 跟 G8 同一类漏洞——旧正则裸匹配
# 'Test run with N tests ... passed'，不要求 ✔ 前缀。summary-stdout-spoof.log 从
# pass-ci-format.log 裁出：删掉真实的 ✔ 汇总行，改插一条**没有 ✔ 前缀**的伪造 stdout
# （`Test run with 1400 tests passed after 0.010 seconds.`，1400 落在真实基线 1407 的
# delta 窗口 [1377,1437] 内——旧正则会把它当真汇总行接受并 GATE PASS，是有意选的最坏
# 情形）。新判据要求汇总行带 ✔ 前缀，日志里真实汇总行整体缺失，必须拦截在"找不到汇总
# 行"这一支（跟 missing-summary-line.log 命中同一条 fail 分支，但这里额外验证了伪造
# stdout 骗不过 G7，而不只是"完全没有这段文字"）。
expect 1 summary-stdout-spoof.log       "找不到 swift-testing 汇总行" \
    "F4（codex R9 回归）：真实 ✔ 汇总行被删、改插一条没有 ✔ 前缀且用例数落在 delta 窗口内的伪造 stdout → 必须仍由 G7·缺失分支拦截，不能被伪造数字骗过"

# F1（medium，2026-07-14）：G7 原本只在用例数 == 0 时才拦，-only-testing 被收窄到
# 只剩个位数用例也能过。too-few-tests.log 是 pass-new-scheme.log 基线上把汇总行
# 用例数改成 500（远低于当前基线-delta 下限，非 0）构造的隔离用例，其余判据（含
# macabi/UIKit 套件）全过，专门验证新增的下限判据（下限公式见 F3 说明）。
expect 1 too-few-tests.log              "低于下限" \
    "G7 隔离：用例数 500（非 0，远低于基线-delta 下限），其余判据全过 → 必须且只能由 G7·下限分支拦截"

# F3（codex R6 finding，2026-07-15）：MIN_TESTS 原本是写死的绝对下限 1200，跟真实值 1407
# 之间留了约 200 条余量——一次悄悄砍掉 200 个非 UIKit 测试的 `-only-testing`/scheme 回归，
# 只要 UIKit 那批还在，旧 G7 依然放行。根治后改成"相对签入仓库的总用例数基线
# （catalyst-total-baseline.txt=1407）算窄 delta（30）"：下限 = 1407 - 30 = 1377。
# 下面三条用 pass-new-scheme.log 为基底、只改汇总行用例数构造：
#   1300（< 1377，掉出 delta）→ 必须 FAIL；1390（>= 1377，delta 内的正常波动）→ 必须 PASS；
#   1407（原始值，见 pass-new-scheme.log 自身/pass-ci-format.log 上面的 F1 补充断言）→ PASS。
expect 1 total-baseline-below-delta.log "低于下限" \
    "F3 隔离：用例数 1300（基线 1407 - delta 30 = 下限 1377，1300 掉出 delta）→ 必须由 G7·基线 delta 分支拦截"

expect 0 total-baseline-within-delta.log "GATE PASS" \
    "F3 隔离：用例数 1390（基线 1407 - delta 30 = 下限 1377，1390 在 delta 内）→ 必须 PASS，不被基线 delta 判据误伤"

# R8（codex finding，2026-07-15）：原来的总数判据只卡下限，1500（远超基线+delta 上限 1437）
# 也会 GATE PASS——测试选择被放大/重复执行可掩盖同时跳过一大批目标测试。改成对称区间后，
# 超上限也必须拦。total-baseline-above-delta.log 是 below-delta fixture 基底上把用例数改成 1500。
expect 1 total-baseline-above-delta.log  "高于上限" \
    "R8 隔离：用例数 1500（基线 1407 + delta 30 = 上限 1437，1500 超出）→ 必须由 G7·基线上限分支拦截"

# 活基线覆盖（codex plan R1 [high]，2026-07-18）：上面所有 fixture 用例都走冻结基线
# （UIKIT_EXPECTED_TESTS_SCRIPT + CATALYST_TOTAL_BASELINE_FILE 两个 export），因此活
# catalyst-total-baseline.txt / catalyst-uikit-baseline.txt 不被它们覆盖——误设/漂移只会
# 在真 CI 的真构建步暴露、reviewer 无法从仓库状态复现。这条**显式 unset 两个冻结覆盖**、
# 走 catalyst-gate.sh 默认的活基线，对一份代表当前 main 的裁剪真日志（pass-main-current.log：
# 1498 tests / 47 UIKit / macabi）断言 GATE PASS 且回显 1498。活基线一旦被误改（漂出 ±30），
# 这条会在 Gate self-test 步就红，早于真构建步。
# 维护：任何改动 catalyst-uikit-baseline.txt、或让真实总用例数漂出 1498±30 的 PR，必须同时
# 用一次真 Catalyst 构建日志重裁 pass-main-current.log（禁手打伪造行，见 R9）。
# （1a-iii 切片1 Task2：uikit 35→41 / total 1457→1486，随 DrawingBottomBarHeightTests 2 条 +
# DrawingTapHitShieldTests 4 条 UIKit-gated 测试新增同步重裁。
#   1a-iii 切片1 Task3：uikit 41→43 / total 1486→1488，随 DrawingLayoutInvariantTests 2 条
#   UIKit-gated 测试新增同步重裁。
#   1a-iii 切片2 Task1：uikit 43→47 / total 1488→1498，随 DrawingStyleIconRenderTests 4 条
#   UIKit-gated 测试新增同步重裁。）
out=$(env -u UIKIT_EXPECTED_TESTS_SCRIPT -u CATALYST_TOTAL_BASELINE_FILE bash "$GATE" "$FIX/pass-main-current.log" 2>&1)
got=$?
if [ "$got" -eq 0 ] && grep -qF "GATE PASS" <<<"$out" && grep -qF "1498" <<<"$out"; then
    echo "  ok   — 活基线覆盖：代表当前 main 的真日志经活基线（uikit 47 / total 1498）→ GATE PASS 且回显 1498 (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — 活基线覆盖本该 GATE PASS 且回显 1498，实得 exit=$got, out=$out"
    FAILED=$((FAILED + 1))
fi

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

# F5 fail-closed（codex R9 finding，2026-07-15）：期望清单里若有重复名，G8 的逐测试判据
# 会用同一行真实 'passed' 结果满足两次断言——一份结果顶替多个。用 UIKIT_EXPECTED_TESTS_SCRIPT
# 注入一个假的推导脚本，只输出三行、其中两行是同一个（合成、跟真实基线名无关的）名字，
# 对 pass-ci-format.log 重跑一遍：这个检测在遍历/grep 日志之前就该拦截，所以不需要这些
# 合成名字真的出现在日志里。
FAKE_DUP_SCRIPT="$FIX/../.fake-uikit-expected-dup.py"
printf '#!/usr/bin/env python3\nprint("DupProbeTestA")\nprint("DupProbeTestA")\nprint("DupProbeTestB")\n' > "$FAKE_DUP_SCRIPT"

out=$(UIKIT_EXPECTED_TESTS_SCRIPT="$FAKE_DUP_SCRIPT" bash "$GATE" "$FIX/pass-ci-format.log" 2>&1)
got=$?
if [ "$got" -eq 1 ] && grep -qF "UIKit-gated 期望测试清单里有重复名" <<<"$out" && grep -qF "DupProbeTestA" <<<"$out"; then
    echo "  ok   — fail-closed C（F5）：期望清单里有重复名 → 必须 FAIL 且点名重复的那个名字 (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — fail-closed C（F5）：期望清单重复名本该 FAIL 且点名重复项，实得 exit=$got, out=$out"
    FAILED=$((FAILED + 1))
fi
rm -f "$FAKE_DUP_SCRIPT"

# F3 fail-closed（2026-07-15）：总用例数基线文件缺失/内容非法都必须让闸门 FAIL，不能
# 悄悄跳过下限判据。用 CATALYST_TOTAL_BASELINE_FILE 注入点指向一个不存在的文件，验证
# G7·基线 delta 分支会在"读基线"这一步就拦截，而不是在数字比较那步崩溃/放行。
out=$(CATALYST_TOTAL_BASELINE_FILE="$FIX/../.nonexistent-total-baseline-$$.txt" bash "$GATE" "$FIX/pass-new-scheme.log" 2>&1)
got=$?
if [ "$got" -eq 1 ] && grep -qF "总用例数基线文件不存在" <<<"$out"; then
    echo "  ok   — 总用例数基线文件缺失 → 必须 FAIL，不能 fail-open (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — 总用例数基线文件缺失本该 FAIL 且报'基线文件不存在'，实得 exit=$got, out=$out"
    FAILED=$((FAILED + 1))
fi

# F6 fail-closed（2026-07-18）：活 total 基线文件存在但内容非整数（如被误写成空/文字/负号）
# 也必须 fail-closed，不能在算术比较那步崩溃或放行。现有 :421 只测了「文件缺失」，这里补
# 「内容非整数」这条既有 fail-closed 路径（catalyst-gate.sh:219-221）的回归。
NONINT_BASELINE="$FIX/../.noninteger-total-baseline-$$.txt"
printf 'abc\n' > "$NONINT_BASELINE"
out=$(CATALYST_TOTAL_BASELINE_FILE="$NONINT_BASELINE" bash "$GATE" "$FIX/pass-new-scheme.log" 2>&1)
got=$?
if [ "$got" -eq 1 ] && grep -qF "不是合法整数" <<<"$out"; then
    echo "  ok   — 活 total 基线内容非整数 → 必须 fail-closed，不能放行 (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — 活 total 基线非整数本该 FAIL 且报'不是合法整数'，实得 exit=$got, out=$out"
    FAILED=$((FAILED + 1))
fi
rm -f "$NONINT_BASELINE"

# 未归属 @Test 检测（2026-07-14，解析器盲区 finding 的自动化回归）：uikit-expected-tests.py
# 此前只能解析它「认识」的两种 @Test 写法——任何不认识的形式（如带 arguments 的参数化
# @Test(arguments:)）会被两个解析正则都跳过，测试悄悄从期望清单里消失，脚本仍退出 0、
# 闸门看起来在守门实则漏判。根治：脚本新增「@Test 属性出现次数」与「实际解析出名字数」
# 的核对，两个数字对不上就非零退出并点名文件/行。
#
# 本回归不能只测一个手搓的 stub 消息字符串（那样只验证 catalyst-gate.sh 认字符串，
# 不验证 uikit-expected-tests.py 真的检测到了）——必须让*真实脚本*对着一份*真实*、独立于
# 当前源码的 fixture 源码树跑一遍。做法：把 uikit-expected-tests.py 复制到一棵临时目录树
# 的 `.github/scripts/` 下（脚本用 `pathlib(__file__).parents[2]` 定位仓库根，跟着复制体
# 一起走，天然指向临时树而不是真仓库），临时树里放一个 UIKit-gated 区块内含一个
# `@Test(arguments:)` 参数化写法的最小 fixture 文件，验证：
#   (a) 脚本自身对这份 fixture 非零退出，且 stderr 点名 fixture 文件路径与行号；
#   (b) 把这个「会失败」的脚本通过 UIKIT_EXPECTED_TESTS_SCRIPT 接到 catalyst-gate.sh 上，
#       对一份本该 GATE PASS 的真实成功日志（pass-ci-format.log）重跑一遍，必须 GATE FAIL。
echo
echo "未归属 @Test 检测（解析器盲区 fail-closed 防线）："
UNATTR_ROOT="$FIX/../.unattributed-test-fixture-$$"
rm -rf "$UNATTR_ROOT" 2>/dev/null || true
mkdir -p "$UNATTR_ROOT/.github/scripts" "$UNATTR_ROOT/ios/Contracts/Tests/KlineTrainerContractsTests"
cp "$DIR/uikit-expected-tests.py" "$UNATTR_ROOT/.github/scripts/uikit-expected-tests.py"
cat > "$UNATTR_ROOT/ios/Contracts/Tests/KlineTrainerContractsTests/UnattributedFixtureTests.swift" <<'SWIFTEOF'
#if canImport(UIKit)
import Testing

struct UnattributedFixtureTests {
    @Test(arguments: [1, 2]) func paramTest(x: Int) {}
}
#endif
SWIFTEOF

out=$(python3 "$UNATTR_ROOT/.github/scripts/uikit-expected-tests.py" 2>&1)
got=$?
if [ "$got" -eq 1 ] && grep -qF "检测到无法解析出测试名的 @Test 属性" <<<"$out" \
    && grep -qF "UnattributedFixtureTests.swift:5" <<<"$out"; then
    echo "  ok   — (a) uikit-expected-tests.py 对参数化 @Test(arguments:) 非零退出，且点名 fixture 文件:行 (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — (a) 未归属 @Test 检测本该非零退出且点名文件:行，实得 exit=$got, out=$out"
    FAILED=$((FAILED + 1))
fi

out=$(UIKIT_EXPECTED_TESTS_SCRIPT="$UNATTR_ROOT/.github/scripts/uikit-expected-tests.py" bash "$GATE" "$FIX/pass-ci-format.log" 2>&1)
got=$?
if [ "$got" -eq 1 ] && grep -qF "检测到无法解析出测试名的 @Test 属性" <<<"$out"; then
    echo "  ok   — (b) 未归属 @Test 推导失败经 UIKIT_EXPECTED_TESTS_SCRIPT 接入 catalyst-gate.sh → 本该 GATE PASS 的日志也必须 GATE FAIL (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — (b) 未归属 @Test 推导失败本该让闸门 GATE FAIL，实得 exit=$got, out=$out"
    FAILED=$((FAILED + 1))
fi
rm -rf "$UNATTR_ROOT" 2>/dev/null || true

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

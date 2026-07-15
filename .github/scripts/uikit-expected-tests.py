#!/usr/bin/env python3
# 推导 UIKit-gated 测试全集：扫描 KlineTrainerContractsTests 下所有 `#if canImport(UIKit)`
# 块内的 @Test("...") 显示名，逐行打印到 stdout（不打印其它内容）。
#
# 背景（2026-07-14，codex R4 finding）：本脚本的前身 uikit-suite-drift-check.py 只负责
# 校验 catalyst-gate.sh 里硬编码的 UIKIT_SUITES/UIKIT_TESTS 哨兵列表有没有跟源码脱节。
# 但那两个硬编码列表本身仍然是残缺的判据：UIKIT_SUITES 只钉「套件跑完了」
# （Suite "X" passed after），从不检查套件里的每个测试是不是都真的跑了——
# 删掉套件内的某个测试，套件照样 passed，闸门照样绿；UIKIT_TESTS 对裸 struct
# DrawDrawingsDispatchTests 更只钉了 7 个测试里的 1 个，另外 6 个被删/跳过也无感。
#
# 根治办法：不再手工维护「应该测什么」的列表——CI 上跑闸门时源码已经 checkout 到位，
# 源码本身就是唯一真相。本脚本把这两个硬编码列表整个替换掉：直接从源码推导出
# 「本应执行的 UIKit-gated 测试全集」，交给 catalyst-gate.sh 对每一个名字逐个断言
# 日志里有 `Test "<名>" passed`。新增/改名/删除的 UIKit-gated 测试自动被下一次运行覆盖，
# 不会再出现「哨兵列表漏项、静默失去意义」的情况。
#
# fail-closed：找不到测试目录，或扫描后一个 UIKit-gated @Test 都没找到，本脚本
# 以非零退出且不打印任何测试名——调用方 catalyst-gate.sh 必须把「非零退出」和
# 「空输出」都当作 GATE FAIL，绝不能把「没有期望项」误判成「全部通过」。
#
# fail-closed 第二道防线（2026-07-14，解析器盲区 finding）：上面那条只堵得住「一个
# UIKit-gated @Test 都没有」的极端情况。真正的病灶是——本脚本的两个解析正则
# （DISPLAY_NAME_RE / FUNC_TEST_RE）只认识它们「认识」的写法；任何不认识的形式
# （带 traits 的 @Test(.tags(...))、参数化的 @Test(arguments:) 等）会被两个正则都跳过，
# 那个测试就悄悄从期望清单里消失——脚本仍然「扫描到 N 个」、退出 0，闸门看起来在守门，
# 其实那个测试逃出了 Catalyst 闸门的保护。根治：不只统计「解析出了多少个」，还要独立
# 统计「源码里出现了多少个 @Test 属性」，两个数字对不上就是解析器有盲区，必须 fail-closed
# 而不是放行（见 TEST_ATTR_RE / main() 里的未归属检测）。
#
# fail-closed 第三道防线（2026-07-15，codex R7 finding）：块识别此前要求整行精确等于
# `#if canImport(UIKit)`（允许前导/尾随空白），任何合法但不精确匹配的写法——
# `#if canImport(UIKit) && targetEnvironment(macCatalyst)`（复合条件）、
# `#if canImport(UIKit) // 注释`（尾注释）——整个块都不被发现，块内 @Test 连未归属
# 检测都兜不住（块本身没进扫描范围）。根治：块识别改成对 `#if`/`#elseif` 条件表达式
# 做语义分类（正向依赖 canImport(UIKit) / 反向门 !canImport(UIKit) / 无关 / 无法分类），
# 而不是字面正则精确匹配；分类不出来的一律 fail-closed（见 classify_uikit_condition /
# find_ambiguous_uikit_conditions）。反向陷阱：不能简单放宽成「行内含 canImport(UIKit)」，
# 否则 `#if !canImport(UIKit)`（DecelerationAnimatorTests.swift:205，非 UIKit 环境专属块）
# 会被误当成 UIKit 块纳入。
#
# 用法: uikit-expected-tests.py（无参数，路径相对本文件自动定位仓库根）
# 输出: 每行一个测试匹配串，无参数无额外文字。两种 @Test 写法都支持：
#   - @Test("显示名")        → 输出 `"显示名"`（带字面引号，日志里对应 `Test "显示名" passed`）
#   - @Test func 函数名()    → 输出 `函数名()`（不带引号，日志里对应 `Test 函数名() passed`——
#     swift-testing 对无显示名的测试直接打印函数签名，不加引号；已用真实 CI 日志核实，
#     见 ReviewPersistenceTests.swift 的 @Test func 写法在 ci-catalyst-real.log 里的收尾行）。
#   无显示名形式同时支持同一行写法（@Test func 名字()）和换行写法（@Test 单独一行，
#   func 名字() 在下一行，中间可能夹 @MainActor 等属性）——两者输出格式一致。
#   调用方 catalyst-gate.sh 靠输出末尾是否为 "()" 决定用哪种模式去匹配日志，不额外加引号。
# 退出: 0 = 成功推导出 >=1 个测试名，且每个 @Test 属性都被成功解析，且每个含
#          canImport(UIKit) 字样的 #if/#elseif 条件都被明确分类为正向/反向门；
#      1 = 失败（源码目录缺失/扫描到 0 个/存在解析器不认识的 @Test 写法/存在无法
#          分类极性的 UIKit 条件门，见 stderr 说明）
import re
import sys
import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
TESTS_DIR = REPO_ROOT / "ios/Contracts/Tests/KlineTrainerContractsTests"

# 显示名形式：@Test("...") ——捕获引号内文本，输出时重新包上字面引号。
DISPLAY_NAME_RE = re.compile(r'@Test\("([^"]*)"')
# 无显示名形式：@Test（后面不紧跟 "(" 或单词字符，排除 @Test("...") 和 @Test(traits...)）
# 加零个或多个其它属性（如 @MainActor，允许带自己的括号参数）、空白/换行，再到 `func 名字()`——
# `\s` 本身就匹配换行，所以同一行写法（@Test func 名字()）和换行写法（@Test 单独一行，
# func 在下一行，中间可能夹 @MainActor）都能匹配，不需要分成两条正则。
# 仅支持无参数函数——swift-testing 对有参数的 @Test 函数会把运行期实参值印进测试名，
# 那种情况无法从源码静态推导，不在本脚本范围内（这类写法会被 main() 的未归属 @Test
# 检测抓到并 fail-closed，不会悄悄漏判）。
FUNC_TEST_RE = re.compile(r'@Test(?![(\w])(?:\s|@\w+(?:\([^)]*\))?)*\bfunc\s+(\w+)\s*\(\s*\)')
# 计数正则：统计源码里出现了多少个 @Test 属性（不管是否被上面两条正则解析成功），
# 用来跟「实际解析出名字的数量」核对，抓解析器的盲区（见 main() 未归属检测）。
# `\b` 边界确保不误伤形如 @Testable 这类不同名的属性/标识符。
TEST_ATTR_RE = re.compile(r'@Test\b')
# 行内注释剥离：`//` 起到行尾的内容原地替换成等长空白（不删字符、不动换行，
# 保证行号/偏移量剥离前后完全一致，可以直接跟未剥离文本的 match 位置比对）。
# 只用于 TEST_ATTR_RE 计数，不影响 DISPLAY_NAME_RE/FUNC_TEST_RE 的实际解析——
# 后者维持原有、已被真实 CI 验证过的行为不变。只处理 `//`（含 `///` 文档注释），
# 不处理 `/* */` 块注释（本仓库 UIKit-gated 区块实证零处 `/* */`，也零处注释提到
# "@Test"，见 catalyst-task-1-report.md 自验记录；真出现再补，不在此提前实现)。
LINE_COMMENT_RE = re.compile(r'//[^\n]*')

# `#if`/`#elseif` 指令行：捕获条件表达式（组 2），前导空白任意（缩进写法，见 R6 F2）。
# 不匹配裸 `#else`（没有条件可分类，也不可能是 UIKit 触发点）。
DIRECTIVE_RE = re.compile(r'^\s*#(?:if|elseif)\s+(.*)$')
# 单独条 term 判据：块识别到 `!canImport(UIKit)` / `!(canImport(UIKit))`（可带内部空白）
# 精确整条即算反向门；不是这两种精确形态、又含 `!` 的写法一律走「无法分类」分支。
NEGATIVE_UIKIT_RE = re.compile(
    r'^!\s*canImport\(UIKit\)$|^!\s*\(\s*canImport\(UIKit\)\s*\)$'
)


def strip_line_comments(text):
    return LINE_COMMENT_RE.sub(lambda m: " " * len(m.group(0)), text)


def classify_uikit_condition(cond):
    """判定单行 `#if`/`#elseif` 条件表达式（含条件文本，可能带尾注释）对 canImport(UIKit)
    的极性（codex R7 finding，2026-07-15）。返回四态之一：
      - 'unrelated'：条件里根本没提 canImport(UIKit) 字样，跟本脚本无关。
      - 'positive'：条件正向依赖 canImport(UIKit)——裸 `canImport(UIKit)`，或与其它
        `&&` 项并列（任意顺序），或跟着 `//` 尾注释。这是 UIKit-gated 块的判据。
      - 'negative'：`!canImport(UIKit)` / `!(canImport(UIKit))`——反向门，明确排除
        （DecelerationAnimatorTests.swift:205 是本仓实证：那是「非 UIKit 环境」专属块，
        块内测试在 Catalyst 上不编译，绝不能纳入期望清单）。
      - 'unknown'：含 canImport(UIKit) 字样但无法可靠判断极性（`||` 混合、`&&` 项本身
        又是取反/嵌套等本函数不认识的形态）——调用方必须 fail-closed，不能猜。
    """
    cond = re.sub(r'//.*$', '', cond).strip()
    if 'canImport(UIKit)' not in cond:
        return 'unrelated'
    if NEGATIVE_UIKIT_RE.match(cond):
        return 'negative'
    if cond == 'canImport(UIKit)':
        return 'positive'
    if '||' in cond:
        return 'unknown'
    terms = [t.strip() for t in cond.split('&&')]
    if any(t == '' for t in terms):
        return 'unknown'
    uikit_terms = [t for t in terms if 'canImport(UIKit)' in t]
    if len(uikit_terms) == 1 and uikit_terms[0] == 'canImport(UIKit)':
        return 'positive'
    return 'unknown'


def find_ambiguous_uikit_conditions(src):
    """扫描全文所有 `#if`/`#elseif` 指令行，返回条件里含 canImport(UIKit) 字样、但
    classify_uikit_condition 判不出正/反极性的行号列表（1-indexed）——fail-closed
    第三道防线，独立于块识别/块内容扫描，覆盖所有嵌套层级，不只是顶层触发点。"""
    ambiguous = []
    for line_no, line in enumerate(src.splitlines(), start=1):
        m = DIRECTIVE_RE.match(line)
        if m and classify_uikit_condition(m.group(1)) == 'unknown':
            ambiguous.append(line_no)
    return ambiguous


def find_uikit_gated_blocks(src):
    """返回文件里所有正向依赖 canImport(UIKit) 的 `#if`/`#elseif` 分支内容的
    (起始行号, 文本片段) 列表（起始行号 1-indexed，指向片段第一行在源文件里的行号，
    供未归属 @Test 检测报错时定位用）。

    F2（codex R6 finding，2026-07-15）：块首/depth 计数正则前面都允许任意前导空白
    （缩进写法，嵌套在 struct/extension 内很常见）。

    R7（codex R7 finding，2026-07-15）：触发判据从「整行精确等于 #if canImport(UIKit)」
    改成 classify_uikit_condition() == 'positive'——复合条件（`&& targetEnvironment(...)`）
    与尾注释（`// ...`）都能正确触发；`!canImport(UIKit)` 反向门被 classify 判为
    'negative'，明确不触发。同时支持 `#elseif` 作为触发点（分支内容只延伸到同级的下一个
    `#elseif`/`#else` 或匹配的 `#endif` 为止，不会把同一条 `#if` 链里的兄弟分支——包括
    UIKit 不可用时的 `#else` 分支——错误地并入 UIKit 分支内容）。嵌套在已捕获分支内部的
    `#if`（无论条件是什么）仍按原逻辑整体收纳，不递归判定极性——跟改动前对已捕获块内嵌套
    `#if/#else` 的处理方式一致，本仓现有 8 个 UIKit 块全是顶格单条件、无嵌套，实证结果不变。
    """
    blocks = []
    lines = src.splitlines()
    i = 0
    while i < len(lines):
        m = DIRECTIVE_RE.match(lines[i])
        if m and classify_uikit_condition(m.group(1)) == 'positive':
            depth = 1
            j = i + 1
            block_start_line = j + 1  # 1-indexed：lines[j] 是文件第 j+1 行
            block_lines = []
            while j < len(lines) and depth > 0:
                l = lines[j]
                if re.match(r'\s*#if\b', l):
                    depth += 1
                elif re.match(r'\s*#endif\b', l):
                    depth -= 1
                    if depth == 0:
                        break
                elif depth == 1 and re.match(r'\s*#(?:elseif|else)\b', l):
                    # 同级的兄弟分支（#elseif/#else）——当前 UIKit 分支到此为止，
                    # 不消费这一行，留给外层循环重新判定（可能是另一个正向 #elseif）。
                    break
                block_lines.append(l)
                j += 1
            blocks.append((block_start_line, "\n".join(block_lines)))
            i = j
        else:
            i += 1
    return blocks


def main():
    if not TESTS_DIR.is_dir():
        print(f"uikit-expected-tests.py: 测试目录不存在: {TESTS_DIR}", file=sys.stderr)
        return 1

    names = []
    ambiguous = []  # (相对路径, 行号) —— #if/#elseif 条件含 canImport(UIKit) 但极性无法分类
    unattributed = []  # (相对路径, 行号) —— 解析器不认识的 @Test 写法
    for f in sorted(TESTS_DIR.rglob("*.swift")):
        src = f.read_text()
        if "canImport(UIKit)" not in src:
            continue
        for line_no in find_ambiguous_uikit_conditions(src):
            ambiguous.append((f.relative_to(REPO_ROOT), line_no))

    if ambiguous:
        print(
            "uikit-expected-tests.py: 检测到无法可靠判断极性的 UIKit 条件门"
            "（条件里含 canImport(UIKit) 字样，但正向/反向无法明确分类，"
            "例如混入括号嵌套、|| 混合、宏变量等本脚本没法可靠判断的形态）——"
            "请扩展 uikit-expected-tests.py 或简化该 #if，否则测试可能逃出 Catalyst 闸门的保护：",
            file=sys.stderr,
        )
        for path, line_no in ambiguous:
            print(f"  {path}:{line_no}", file=sys.stderr)
        return 1

    for f in sorted(TESTS_DIR.rglob("*.swift")):
        src = f.read_text()
        if "canImport(UIKit)" not in src:
            continue
        for block_start_line, block in find_uikit_gated_blocks(src):
            # 显示名形式输出原始文本（不含引号，跟改动前一致）；
            # 无显示名形式输出 "函数名()"（末尾的 "()" 是 catalyst-gate.sh 用来判断
            # 该走哪种日志匹配模式的标记，见该脚本 G8 段落）。
            matches = [(m.start(), m.group(1)) for m in DISPLAY_NAME_RE.finditer(block)]
            matches += [(m.start(), f'{m.group(1)}()') for m in FUNC_TEST_RE.finditer(block)]
            parsed_positions = {pos for pos, _ in matches}
            matches.sort(key=lambda t: t[0])
            names.extend(name for _, name in matches)

            # 未归属检测：block 里出现的每一个 @Test 属性，起始位置都必须落在
            # parsed_positions 里（即被 DISPLAY_NAME_RE 或 FUNC_TEST_RE 之一解析成功）。
            # 三条正则都以字面 "@Test" 开头，match.start() 对同一个属性永远相同，可以
            # 直接按位置比对。用注释剥离后的文本计数，避免注释里提到 "@Test" 的文字
            # 被误当成漏解析的属性（见 strip_line_comments 头部注释）。
            stripped_block = strip_line_comments(block)
            for m in TEST_ATTR_RE.finditer(stripped_block):
                if m.start() not in parsed_positions:
                    line_no = block_start_line + block.count("\n", 0, m.start())
                    unattributed.append((f.relative_to(REPO_ROOT), line_no))

    if unattributed:
        print(
            "uikit-expected-tests.py: 检测到无法解析出测试名的 @Test 属性——"
            "这些测试会悄悄逃出 Catalyst 闸门的期望清单，闸门却依然报绿。"
            "请扩展 uikit-expected-tests.py 以支持这种写法，否则该测试逃出 Catalyst 闸门的保护：",
            file=sys.stderr,
        )
        for path, line_no in unattributed:
            print(f"  {path}:{line_no}", file=sys.stderr)
        return 1

    if not names:
        print(
            "uikit-expected-tests.py: 扫描到 0 个 UIKit-gated @Test —— "
            "拒绝空清单（fail-closed，拒绝把「没有期望项」误判成「全部通过」）",
            file=sys.stderr,
        )
        return 1

    for n in names:
        print(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())

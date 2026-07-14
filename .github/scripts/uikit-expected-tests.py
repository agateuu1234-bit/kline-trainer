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
# 用法: uikit-expected-tests.py（无参数，路径相对本文件自动定位仓库根）
# 输出: 每行一个测试匹配串，无参数无额外文字。两种 @Test 写法都支持：
#   - @Test("显示名")        → 输出 `"显示名"`（带字面引号，日志里对应 `Test "显示名" passed`）
#   - @Test func 函数名()    → 输出 `函数名()`（不带引号，日志里对应 `Test 函数名() passed`——
#     swift-testing 对无显示名的测试直接打印函数签名，不加引号；已用真实 CI 日志核实，
#     见 ReviewPersistenceTests.swift 的 @Test func 写法在 ci-catalyst-real.log 里的收尾行）。
#   无显示名形式同时支持同一行写法（@Test func 名字()）和换行写法（@Test 单独一行，
#   func 名字() 在下一行，中间可能夹 @MainActor 等属性）——两者输出格式一致。
#   调用方 catalyst-gate.sh 靠输出末尾是否为 "()" 决定用哪种模式去匹配日志，不额外加引号。
# 退出: 0 = 成功推导出 >=1 个测试名，且每个 @Test 属性都被成功解析；
#      1 = 失败（源码目录缺失/扫描到 0 个/存在解析器不认识的 @Test 写法，见 stderr 说明）
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


def strip_line_comments(text):
    return LINE_COMMENT_RE.sub(lambda m: " " * len(m.group(0)), text)


def find_uikit_gated_blocks(src):
    """返回文件里所有 `#if canImport(UIKit)` ... 对应 `#endif` 之间的 (起始行号, 文本片段)
    列表（起始行号 1-indexed，指向片段第一行在源文件里的行号，供未归属 @Test 检测报错时
    定位用；只匹配裸的 canImport(UIKit)，不匹配 `#if !canImport(UIKit)` 这种反向门）。

    F2（codex R6 finding，2026-07-15）：块识别与 depth 计数此前都用列首锚定的正则
    （`^#if...`/`^#endif`），缩进写法的 `#if canImport(UIKit)`（Swift 合法写法，嵌套在
    struct/extension 内很常见）整个块都不会被发现——块内的 @Test 既不会进期望清单，
    也不会被「未归属 @Test」检测兜住（因为块本身就没被识别，从未进入扫描范围）。
    根治：块首/depth 计数正则前面都允许任意前导空白（`^\\s*#if`/`^\\s*#endif`）。"""
    blocks = []
    lines = src.splitlines()
    i = 0
    while i < len(lines):
        if re.match(r'\s*#if\s+canImport\(UIKit\)\s*$', lines[i]):
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
    unattributed = []  # (相对路径, 行号) —— 解析器不认识的 @Test 写法
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

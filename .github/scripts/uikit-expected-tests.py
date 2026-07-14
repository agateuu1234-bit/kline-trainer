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
# 用法: uikit-expected-tests.py（无参数，路径相对本文件自动定位仓库根）
# 输出: 每行一个测试匹配串，无参数无额外文字。两种 @Test 写法都支持：
#   - @Test("显示名")        → 输出 `"显示名"`（带字面引号，日志里对应 `Test "显示名" passed`）
#   - @Test func 函数名()    → 输出 `函数名()`（不带引号，日志里对应 `Test 函数名() passed`——
#     swift-testing 对无显示名的测试直接打印函数签名，不加引号；已用真实 CI 日志核实，
#     见 ReviewPersistenceTests.swift 的 @Test func 写法在 ci-catalyst-real.log 里的收尾行）。
#   调用方 catalyst-gate.sh 靠输出末尾是否为 "()" 决定用哪种模式去匹配日志，不额外加引号。
# 退出: 0 = 成功推导出 >=1 个测试名；1 = 失败（源码目录缺失/扫描到 0 个，见 stderr 说明）
import re
import sys
import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
TESTS_DIR = REPO_ROOT / "ios/Contracts/Tests/KlineTrainerContractsTests"

# 显示名形式：@Test("...") ——捕获引号内文本，输出时重新包上字面引号。
DISPLAY_NAME_RE = re.compile(r'@Test\("([^"]*)"')
# 无显示名形式：@Test（后面不紧跟 "(" 或单词字符，排除 @Test("...") 和 @Test(traits...)）
# 加零个或多个其它属性（如 @MainActor），再到同一行的 `func 名字()`。
# 仅支持无参数函数——swift-testing 对有参数的 @Test 函数会把运行期实参值印进测试名，
# 那种情况无法从源码静态推导，不在本脚本范围内（本仓库 UIKit-gated 测试目前也没有这种写法）。
FUNC_TEST_RE = re.compile(r'@Test(?![(\w])[^\n]*?\bfunc\s+(\w+)\s*\(\s*\)')


def find_uikit_gated_blocks(src):
    """返回文件里所有 `#if canImport(UIKit)` ... 对应 `#endif` 之间的文本片段
    （只匹配裸的 canImport(UIKit)，不匹配 `#if !canImport(UIKit)` 这种反向门）。"""
    blocks = []
    lines = src.splitlines()
    i = 0
    while i < len(lines):
        if re.match(r'#if\s+canImport\(UIKit\)\s*$', lines[i]):
            depth = 1
            j = i + 1
            block_lines = []
            while j < len(lines) and depth > 0:
                l = lines[j]
                if re.match(r'#if\b', l):
                    depth += 1
                elif re.match(r'#endif\b', l):
                    depth -= 1
                    if depth == 0:
                        break
                block_lines.append(l)
                j += 1
            blocks.append("\n".join(block_lines))
            i = j
        else:
            i += 1
    return blocks


def main():
    if not TESTS_DIR.is_dir():
        print(f"uikit-expected-tests.py: 测试目录不存在: {TESTS_DIR}", file=sys.stderr)
        return 1

    names = []
    for f in sorted(TESTS_DIR.rglob("*.swift")):
        src = f.read_text()
        if "canImport(UIKit)" not in src:
            continue
        for block in find_uikit_gated_blocks(src):
            # 显示名形式输出原始文本（不含引号，跟改动前一致）；
            # 无显示名形式输出 "函数名()"（末尾的 "()" 是 catalyst-gate.sh 用来判断
            # 该走哪种日志匹配模式的标记，见该脚本 G8 段落）。
            matches = [(m.start(), m.group(1)) for m in DISPLAY_NAME_RE.finditer(block)]
            matches += [(m.start(), f'{m.group(1)}()') for m in FUNC_TEST_RE.finditer(block)]
            matches.sort(key=lambda t: t[0])
            names.extend(name for _, name in matches)

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

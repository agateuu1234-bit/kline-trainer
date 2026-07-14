#!/usr/bin/env python3
# 漂移检测：确保 catalyst-gate.sh 的 UIKIT_SUITES / UIKIT_TESTS 哨兵列表
# 与仓库里实际的 UIKit-gated 测试单元（`#if canImport(UIKit)` 块内的 `@Suite(...)`，
# 或无 @Suite 的裸 struct 里的 `@Test(...)`）保持同步。
#
# 背景（2026-07-14，codex R3 finding）：UIKIT_SUITES 曾只列 3 个，但仓库里实际有 7 个
# UIKit-gated 测试单元——漏掉的里面就包括当初 bug 的藏身处 DrawDrawingsDispatchTests。
# 因为 MIN_TESTS 留了余量，漏掉的套件被禁用/跳过时闸门毫无信号照样能过。
# 本脚本让这种"哨兵列表漏项"不可能再静默发生：任何新增/改名/删除的 UIKit-gated
# 套件或测试，只要没同步进 catalyst-gate.sh，本检测就会在真构建之前失败。
#
# 用法: uikit-suite-drift-check.py（无参数，路径相对本文件自动定位仓库根）
# 退出: 0 = 哨兵列表与源码一致；1 = 有漂移（stdout 说明具体哪一项）
import re
import sys
import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
TESTS_DIR = REPO_ROOT / "ios/Contracts/Tests/KlineTrainerContractsTests"
GATE_SH = REPO_ROOT / ".github/scripts/catalyst-gate.sh"


def extract_bash_array(text, name):
    m = re.search(rf'{name}=\(\n(.*?)\n\)', text, re.S)
    if not m:
        return set()
    return set(re.findall(r"'([^']*)'", m.group(1)))


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
    gate_src = GATE_SH.read_text()
    declared_suites = extract_bash_array(gate_src, "UIKIT_SUITES")
    declared_tests = extract_bash_array(gate_src, "UIKIT_TESTS")

    found_suites = set()
    suite_source = {}
    # 每个"裸 struct"（UIKit-gated 但无 @Suite）文件 -> 其内 @Test 名集合
    bare_test_files = {}

    for f in sorted(TESTS_DIR.rglob("*.swift")):
        src = f.read_text()
        if "canImport(UIKit)" not in src:
            continue
        for block in find_uikit_gated_blocks(src):
            suite_names = re.findall(r'@Suite\("([^"]*)"', block)
            if suite_names:
                for s in suite_names:
                    found_suites.add(s)
                    suite_source[s] = f
            else:
                test_names = set(re.findall(r'@Test\("([^"]*)"', block))
                if test_names:
                    bare_test_files.setdefault(f, set()).update(test_names)

    errors = []

    for s in sorted(found_suites - declared_suites):
        rel = suite_source[s].relative_to(REPO_ROOT)
        errors.append(
            f'发现新的/改名的 UIKit-gated 套件 "{s}"（{rel}），'
            f'请同步 catalyst-gate.sh 的 UIKIT_SUITES 哨兵列表'
        )

    for s in sorted(declared_suites - found_suites):
        errors.append(
            f'UIKIT_SUITES 里的套件 "{s}" 在源码里已找不到（改名/删除？），'
            f'请同步 catalyst-gate.sh'
        )

    for t in sorted(declared_tests - {t for tests in bare_test_files.values() for t in tests}):
        errors.append(
            f'UIKIT_TESTS 里的测试名 "{t}" 在源码里已找不到（改名/删除？），'
            f'请同步 catalyst-gate.sh'
        )

    # 每个裸 struct 文件必须至少有一个 @Test 名被 UIKIT_TESTS 覆盖，
    # 否则这个文件是一个完全没被哨兵盯住的新单元（正是本次 finding 的根因场景）。
    for f, tests in bare_test_files.items():
        if tests.isdisjoint(declared_tests):
            rel = f.relative_to(REPO_ROOT)
            sample = sorted(tests)[0]
            errors.append(
                f'发现新的裸 struct UIKit-gated 测试文件 {rel}'
                f'（无 @Suite，测试名如 "{sample}"），未被 UIKIT_TESTS 任何哨兵覆盖，'
                f'请同步 catalyst-gate.sh'
            )

    if errors:
        print("UIKit-gated 哨兵漂移检测失败：")
        for e in errors:
            print(f"  - {e}")
        return 1

    print(
        f"UIKit-gated 哨兵漂移检测通过：{len(found_suites)} 个 Suite + "
        f"{len(bare_test_files)} 个裸 struct 测试文件，与 catalyst-gate.sh 哨兵列表一致"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

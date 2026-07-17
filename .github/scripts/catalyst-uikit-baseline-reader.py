#!/usr/bin/env python3
# 生产闸门读取签入仓库的 UIKit-gated 测试基线（而非对当前 checkout 活推导），
# 见 F1（codex R6 finding，2026-07-15）。
#
# 背景：catalyst-gate.sh 此前直接调用 uikit-expected-tests.py 对当前 checkout 的
# 源码做活推导，把结果当成"期望"。但"期望"和"被检查对象"是同一份源码——一个删掉
# UIKit 测试的 PR 会让期望清单跟着缩水（源码少了，推导出的期望也少了），闸门不再
# 要求那些 passed 行，必需门照样绿。这是循环论证：源码既是判据又是被判据检查的对象。
#
# 根治：生产闸门改为读取本文件旁边、签入仓库、跟"当前源码"解耦的基线文件
# catalyst-uikit-baseline.txt。它的生成命令（不要手打测试名，转录错误无法复核）：
#   python3 .github/scripts/uikit-expected-tests.py > .github/scripts/catalyst-uikit-baseline.txt
# 删测试而不同步改基线 → 基线仍列着它 → 日志里找不到对应 passed 行 → G8 逐测试判据
# FAIL，点名该测试。有意的增删/改名必须显式更新基线文件（留在 PR diff 里被评审看见）。
#
# 基线是否与当前源码一致，由 catalyst-gate.test.sh 里独立的一致性断言守护：那条断言
# 在 xcodebuild 真跑之前，对着当前源码调用 uikit-expected-tests.py 做活推导，跟本脚本
# 读的这份基线逐行比对，不一致就让自测本身 FAIL（提示如何重新生成基线）。本脚本自己
# 不做这个比对，只负责把基线内容原样吐给 catalyst-gate.sh 的 G8 逐测试判据。
#
# fail-closed：基线文件不存在或去空白后为空，本脚本非零退出、不打印任何测试名——
# 调用方 catalyst-gate.sh 把「非零退出」和「空输出」都当作 GATE FAIL。
import pathlib
import sys

BASELINE = pathlib.Path(__file__).resolve().with_name("catalyst-uikit-baseline.txt")

if not BASELINE.is_file():
    print(f"catalyst-uikit-baseline-reader.py: 基线文件不存在: {BASELINE}", file=sys.stderr)
    sys.exit(1)

content = BASELINE.read_text()
if not content.strip():
    print(f"catalyst-uikit-baseline-reader.py: 基线文件为空: {BASELINE}", file=sys.stderr)
    sys.exit(1)

sys.stdout.write(content)

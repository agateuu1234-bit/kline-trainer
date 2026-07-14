#!/usr/bin/env python3
# F2（codex R5 finding，2026-07-14）：catalyst-gate.test.sh 里的 fixture 用例（G8 相关的
# PASS/missing-one-uikit-test 等）此前直接用 catalyst-gate.sh 的默认行为——从「当前源码」
# 实时推导期望测试清单。这样一来，任何 PR 只要新增/改名一个 UIKit-gated @Test，推导清单
# 就会比 fixture 静态日志里的多一条，闸门自测就会在 xcodebuild 真跑之前先崩——以后每个
# 加 UIKit 测试的人都会被这道门莫名其妙堵死。
#
# 根治：fixture 用例不该跟着「当前源码」漂移——它测的是「G8 判据逻辑本身对不对」，不是
# 「当前源码长什么样」。本脚本是一份跟 fixtures/*.log 配套、冻结在提交历史里的期望清单
# （生成时对应当时的 28 个 UIKit-gated 测试，见同目录 uikit-expected-tests.frozen.txt），
# 通过 catalyst-gate.sh 已有的 UIKIT_EXPECTED_TESTS_SCRIPT 注入点，专供
# catalyst-gate.test.sh 的 fixture 断言使用。真实 xcodebuild 日志（workflow 里的真跑）
# 永远不设这个环境变量，走 catalyst-gate.sh 的默认值——也就是仍然对当前源码做实时推导，
# 源码推导的保护完全没丢。
import pathlib
import sys

FROZEN = pathlib.Path(__file__).resolve().with_name("uikit-expected-tests.frozen.txt")
sys.stdout.write(FROZEN.read_text())

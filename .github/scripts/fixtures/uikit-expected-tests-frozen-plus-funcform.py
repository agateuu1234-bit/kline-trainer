#!/usr/bin/env python3
"""冻结清单 + 一条**函数形式**（末尾 "()"）的 UIKit-gated 期望测试。

为什么要有这份：当前全树没有任何函数形式的 UIKit-gated 测试，所以
「函数形式的名字在结构化结果里长什么样」没有现成档位覆盖（原列为 spec 残留 R5）。
那个名字与配套节点都是从 2026-10-11 本机真构建的结果包里**原样取**的
（源码 `@Test func g3_replayBaseline_captures_all_include_defaultStyle()`，
文本日志印作 `✔ Test g3_…() passed after`，结构化 name 就是 `g3_…()`）。
⛔ 别改成手造名字：本仓 feedback_fixtures_must_match_production_format。

⚠️ 这里**派生**自 uikit-expected-tests-frozen.py，⛔ 不把那 28 条再抄一份 ——
本仓 feedback_prose_duplication_is_the_defect_engine（同一事实 N 份副本 ⇒
改一处漏一处）。冻结清单变了，这份自动跟着变。
"""
import pathlib
import subprocess
import sys

FUNCFORM = "g3_replayBaseline_captures_all_include_defaultStyle()"

HERE = pathlib.Path(__file__).resolve().parent
FROZEN = HERE / "uikit-expected-tests-frozen.py"

out = subprocess.run([sys.executable, str(FROZEN)],
                     capture_output=True, text=True, check=True).stdout
names = [line for line in out.splitlines() if line.strip()]
if not names:
    raise SystemExit(f"冻结清单吐空了（{FROZEN}）——派生清单无法成立，fail-closed")
if any(n.endswith("()") for n in names):
    raise SystemExit("冻结清单里已经有函数形式的条目了 ⇒ 这份派生夹具的前提变了，"
                     "请重新确认它还测不测得到东西（别让它退化成恒真）")

for n in names + [FUNCFORM]:
    print(n)

#!/usr/bin/env python3
"""一次性探针：在 CI 的真实 Xcode 上回答「结构化结果能不能当判据」。

⛔ 这是**丢弃物**，随探针 PR 一起关掉、不进 main。
它只打印，不做任何判断、不返回非 0（除了自身崩溃）——
判绿标准是**人去读那四项输出**，不是「这一步绿了」。
见 plan `2026-10-06-catalyst-gate-structured-results.md` 的 Task 1。

用法: probe-xcresult.py <tests.json>
"""
import collections
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    doc = json.load(f)

rows = []


def walk(node, trail=()):
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case":
            rows.append((trail, tuple(sorted(node.keys())),
                         node.get("name", ""), node.get("result", "")))
        for key, val in node.items():
            # children 这一层的「名字」在父节点上，用它当路径段才看得出层次
            seg = node.get("name", key) if key == "children" else key
            walk(val, trail + (seg,))
    elif isinstance(node, list):
        for val in node:
            walk(val, trail)


walk(doc)

print(f"[probe] 顶层键: {sorted(doc)}")
print(f"[probe] Test Case 节点总数: {len(rows)}")
print(f"[probe] 节点字段名全集: {sorted({k for _, ks, _, _ in rows for k in ks})}")
print(f"[probe] result 取值分布: {dict(collections.Counter(r for _, _, _, r in rows))}")

nonascii = [n for _, _, n, _ in rows if any(ord(c) > 127 for c in n)]
print(f"[probe] 含非 ASCII 的名字数: {len(nonascii)} / {len(rows)}")
if nonascii:
    longest = max(nonascii, key=len)
    print(f"[probe] 最长的中文名（验有没有被截断，len={len(longest)}）:")
    print(f"[probe]   {longest}")

print("[probe] 树路径尾两段分布（看有没有「框架」这个维度）:")
for trail, cnt in collections.Counter(t[-2:] for t, _, _, _ in rows).most_common(8):
    print(f"[probe]   {cnt:5}  {trail}")

# baseline 逐条对账 —— 这是 G8 真正要做的事，先在 CI 上证明它做得到
try:
    with open(".github/scripts/catalyst-uikit-baseline.txt", encoding="utf-8") as f:
        baseline = [ln.rstrip("\n") for ln in f if ln.strip()]
except OSError as exc:  # pragma: no cover - 探针不该因此崩
    print(f"[probe] ⚠️ 读不到 baseline: {exc}")
    baseline = []

if baseline:
    names = {n for _, _, n, _ in rows}
    passed = {n for _, _, n, r in rows if r == "Passed"}
    miss = [b for b in baseline if b not in names]
    notpass = [b for b in baseline if b in names and b not in passed]
    print(f"[probe] baseline {len(baseline)} 条：找不到 {len(miss)} 条 / 找到但非 Passed {len(notpass)} 条")
    for b in miss[:5]:
        print(f"[probe]   找不到: {b!r}")
    for b in notpass[:5]:
        print(f"[probe]   非 Passed: {b!r}")

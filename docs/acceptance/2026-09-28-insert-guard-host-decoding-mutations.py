#!/usr/bin/env python3
"""变异验证：逐条把本片的每处修复「改回去」，确认**对症的那一条测试**会变红。

用法（在本仓任意位置）：

    "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" \\
      docs/acceptance/2026-09-28-insert-guard-host-decoding-mutations.py

期望：每一行都以 `✅` 开头，最后一行是 `全部变红 ✅`。

⛔ **为什么这个脚本要进仓库**：本片之前，这些判据只能靠临时脚本验 ——
   而临时脚本不进仓库，于是「谁把某张网摘掉」**没有任何常驻测试会红**。
   实测过：把兜底网从主循环里摘掉，当时的常驻测试全绿。⇒ 证据要跟代码一起走。

⛔ **锚点失效必须大声报「未执行」，不许静默跳过** ——
   否则重构之后这个脚本会安静地变成一张白纸（本仓成文教训：
   报「0 违反」的扫描必须先证明它能报非 0）。

⛔ **判别只读 pytest 短摘要里的 `FAILED` / `ERROR` 行**，不 grep 整段输出 ——
   回溯会把守卫**源码里**的字样一起打印出来（本片的 A4 脚本第一版就是这么变成
   橡皮图章的）。
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
GUARD = ROOT / "backend" / "tests" / "test_insert_schema_version_guard.py"
PY = "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"

#: `标签 -> (原文片段, 改成什么)`。每条都是**把一处修复改回去**。
MUTATIONS: dict[str, tuple[str, str]] = {
    # ── 宿主解码层 ────────────────────────────────────────────────────────
    "M01 `.py` 不解码（退回扫原文）": (
        '        decoded_units = _py_units(text) if q.suffix == ".py" else None',
        "        decoded_units = None  # MUT"),
    "M02 ast 解析失败当成「没有字符串」": (
        "        if decoded_units is None:\n"
        "            units = [(text, None, False)]   # None = 行号现场数；原文扫描不走 AST 豁免",
        "        if False:  # MUT\n            units = [(text, None, False)]"),
    "M03 `fold` 不收 bytes 字面量": (
        "        if isinstance(node, ast.Constant) and isinstance(node.value, (str, bytes)):\n"
        "            consumed.add(id(node))",
        "        if isinstance(node, ast.Constant) and isinstance(node.value, str):  # MUT\n"
        "            consumed.add(id(node))"),
    "M04 `fold` 遇变量时返回 None（不放哨兵）": (
        "            return ((_UNRESOLVED if lhs is None else lhs)\n"
        "                    + (_UNRESOLVED if rhs is None else rhs))",
        "            return None if lhs is None or rhs is None else lhs + rhs  # MUT"),
    "M05 外层循环不查 `consumed`（碎片被重复发出）": (
        "        if id(node) in consumed:\n            continue\n"
        "        # ⛔ `ast.Call` 也要进来",
        "        if False:  # MUT\n            continue\n"
        "        # ⛔ `ast.Call` 也要进来"),
    "M06 Add 分支整棵子树无差别消费": (
        "            consumed.add(id(node))\n"
        "            return ((_UNRESOLVED if lhs is None else lhs)",
        "            for _p in ast.walk(node):  # MUT\n"
        "                consumed.add(id(_p))\n"
        "            return ((_UNRESOLVED if lhs is None else lhs)"),
    "M07 f-string 插值子树也消费": (
        "                    out.append(_UNRESOLVED)",
        "                    out.append(_UNRESOLVED)\n"
        "                    for _p in ast.walk(part):  # MUT\n"
        "                        consumed.add(id(_p))"),
    "M08 不折叠 `sep.join((…))`": (
        '        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)\n'
        '                and node.func.attr == "join" and len(node.args) == 1\n'
        '                and isinstance(node.args[0], (ast.Tuple, ast.List))):',
        "        if False:  # MUT"),
    "M09 外层筛选去掉 `ast.Call`": (
        "        if isinstance(node, (ast.JoinedStr, ast.BinOp, ast.Call)) or (",
        "        if isinstance(node, (ast.JoinedStr, ast.BinOp)) or (  # MUT"),
    # ── 「提及」豁免 ──────────────────────────────────────────────────────
    "M10 「提及」豁免退回「只看位置」": (
        '                if kind == "unknown" and mention_ok \\\n'
        "                        and not utext[m.end():].strip():",
        '                if kind == "unknown" and uline is not None \\\n'
        "                        and not utext[m.end():].strip():  # MUT"),
    "M11 解码单元的「提及」补偿整个删掉": (
        '                if kind == "unknown" and mention_ok \\\n'
        "                        and not utext[m.end():].strip():",
        "                if False:  # MUT"),
    # ── 守恒判据（地板之一） ──────────────────────────────────────────────
    "M12 守恒判据摘掉": (
        "        if decoded_units is not None:\n            _raw_n = len(_heads(text)[0])",
        "        if False:  # MUT\n            _raw_n = len(_heads(text)[0])"),
    "M13 守恒判据放宽（只在减到负数时才报）": (
        "            if _dec_n < _raw_n:", "            if _dec_n < 0:  # MUT"),
    # ── 表名不是字面量 ────────────────────────────────────────────────────
    "M14 「表名不是字面量」判据摘掉": (
        "            for st in _nonliteral_targets(utext):", "            for st in []:  # MUT"),
    "M15 「表名不是字面量」只看区段第一个字符": (
        "        if not blob or any(mk in blob for mk in _COLS_MARKERS):",
        "        if not blob or (region and region[0] in _COLS_MARKERS):  # MUT"),
    "M16 「表名不是字面量」判据过宽（区段非空也报）": (
        "        if not blob or any(mk in blob for mk in _COLS_MARKERS):",
        "        if True:  # MUT"),
    # ── 表名被劈开 ────────────────────────────────────────────────────────
    "M17 「表名被劈开」判据摘掉": (
        "            for st in _split_name_heads(text):", "            for st in []:  # MUT"),
    "M18 「表名被劈开」不 gate、也用在 `.py` 上": (
        "        if decoded_units is None:\n            _raw_starts =",
        "        if True:  # MUT\n            _raw_starts ="),
    # ── 列清单里的占位 ────────────────────────────────────────────────────
    "M19 列清单占位判据摘掉": (
        "                elif any(mk in cols for mk in _COLS_MARKERS):",
        "                elif False:  # MUT"),
    # ── 兜底网（地板之二） ────────────────────────────────────────────────
    "M20 兜底网摘掉": (
        "            for mm in _LAST_RESORT_RE.finditer(utext):", "            for mm in []:  # MUT"),
    # ⛔ 「地板只铺一半」—— 兜底网**只开给非 `.py` 宿主**（codex 第六轮的那处退化）。
    "M24 兜底网只开给非 `.py` 宿主（地板只铺一半）": (
        "            for mm in _LAST_RESORT_RE.finditer(utext):",
        "            for mm in (_LAST_RESORT_RE.finditer(utext)"
        " if uline is None else []):  # MUT"),
    "M21 兜底网去掉「禁跨括号」": (
        '_LR_SPAN = r"(?:(?![(;)])[\\s\\S])"', '_LR_SPAN = r"[\\s\\S]"  # MUT'),
    "M22 兜底网去掉词边界": (
        '    r"(?![A-Za-z0-9_$])",          # ⛔ 词边界：否则 `training_sets_audit` 也被拖下水',
        '    r"",  # MUT'),
    "M25 兜底网的间隔恢复字符上限（间隔一长就够不着）": (
        'rf"insert{_LR_SPAN}+?into{_LR_SPAN}*?training{_LR_NAME}{{0,12}}?sets"',
        'rf"insert{_LR_SPAN}{{1,400}}?into{_LR_SPAN}{{0,200}}?training'
        '{_LR_NAME}{{0,12}}?sets"  # MUT'),
    # ── 不要求表名的那条判据（地板之三） ──────────────────────────────────
    "M26 「间隔或表名求不出来」判据摘掉": (
        "            for st in _unresolved_insert_spans(utext):",
        "            for st in []:  # MUT"),
    "M27 该判据改成也要求表名字面量": (
        '        if _INTO_KW.search(span) and any(mk in span for mk in _COLS_MARKERS):',
        '        if (_INTO_KW.search(span) and "training_sets" in span.lower()\n'
        '                and any(mk in span for mk in _COLS_MARKERS)):  # MUT'),
    # ⛔ 「认出表头就跳过不确定性检查」—— codex 第八轮的那处退化。
    "M28 不确定性检查按【已认出的表头】去重": (
        "            _already = set(_nonliteral_targets(utext))",
        "            _already = ({h.start() for h in _heads(utext)[0]}\n"
        "                        | set(_nonliteral_targets(utext)))  # MUT"),
    "M23 兜底网的表名跨度用任意字符": (
        '_LR_NAME = r"[\\s_\\"\'+\\\\]"', "_LR_NAME = _LR_SPAN  # MUT"),
}


def red_tests() -> list[str]:
    """跑守卫测试，返回变红的测试名。⛔ 只读短摘要里的 FAILED / ERROR 行。"""
    r = subprocess.run(
        [PY, "-m", "pytest", str(GUARD), "-q", "-p", "no:cacheprovider",
         "--no-header", "-rfE"],
        capture_output=True, text=True, cwd=ROOT,
        env={"PYTHONDONTWRITEBYTECODE": "1", "PATH": "/usr/bin:/bin"})
    return [ln.split("::")[-1].split()[0].replace("test_", "")
            for ln in r.stdout.splitlines() if ln.startswith(("FAILED", "ERROR"))]


#: ⛔ **组合变异**：有几处修复是**纵深防御** —— 它们的场景被更强的那道判据
#:    （`_unresolved_insert_spans`，不要求表名）也覆盖了，所以**单独**改回去时零红。
#: ⚠️ 零红有两种完全不同的含义，必须分清：
#:      ① 这处修复是**死代码**（真没用）；
#:      ② 这处修复是**冗余的地板**（有更强的判据兜着）。
#:    区分办法：把更强那道也一起摘掉 —— 若此时变红，就是 ②，是真正的纵深防御。
#: ⭐ 这与本仓「M1+M2 两条一起才造出假绿」的做法是同一招。
COMBOS: dict[str, list[str]] = {
    "C1 区段判据只看第一个字符 + 不要求表名那条也摘掉": ["M15", "M26"],
    "C2 兜底网只开一半 + 不要求表名那条也摘掉": ["M24", "M26"],
    "C3 兜底网恢复窗口上限 + 不要求表名那条也摘掉": ["M25", "M26"],
}


def _by_prefix(code: str) -> tuple[str, tuple[str, str]]:
    for label, pair in MUTATIONS.items():
        if label.startswith(code + " "):
            return label, pair
    raise KeyError(code)


def main() -> int:
    original = GUARD.read_text(encoding="utf-8")

    baseline = red_tests()
    if baseline:
        print(f"⛔ 基线就不是绿的，后面的结果说明不了任何事：{baseline}")
        return 1
    print("基线（无变异）：守卫全绿 ✅\n")

    bad: list[str] = []
    try:
        for label, (old, new) in MUTATIONS.items():
            hits = original.count(old)
            if hits != 1:
                print(f"⛔ {label}：锚点命中 {hits} 次 —— **该变异未执行**（代码重构过？）")
                bad.append(label)
                continue
            GUARD.write_text(original.replace(old, new, 1), encoding="utf-8")
            red = red_tests()
            GUARD.write_text(original, encoding="utf-8")
            if red:
                print(f"✅ {label}\n     变红：{red}")
            else:
                combo = next((c for c, codes in COMBOS.items()
                              if label.split()[0] in codes), None)
                if combo:
                    print(f"➖ {label}：单独零红 —— 由组合变异「{combo}」验证（纵深防御）")
                else:
                    print(f"⛔ {label}：**零红** —— 这处修复没有任何测试钉着")
                    bad.append(label)

        print()
        for clabel, codes in COMBOS.items():
            mutated, ok = original, True
            for code in codes:
                _lbl, (old, new) = _by_prefix(code)
                if mutated.count(old) != 1:
                    print(f"⛔ {clabel}：`{code}` 的锚点命中 {mutated.count(old)} 次 —— **未执行**")
                    bad.append(clabel)
                    ok = False
                    break
                mutated = mutated.replace(old, new, 1)
            if not ok:
                continue
            GUARD.write_text(mutated, encoding="utf-8")
            red = red_tests()
            GUARD.write_text(original, encoding="utf-8")
            if red:
                print(f"✅ {clabel}\n     变红：{red}")
            else:
                print(f"⛔ {clabel}：**零红** —— 组合起来都没人红，说明这几处确实是死代码")
                bad.append(clabel)
    finally:
        GUARD.write_text(original, encoding="utf-8")

    print()
    if GUARD.read_text(encoding="utf-8") != original:
        print("❌❌ 收尾复核失败：守卫文件没还原！")
        return 1
    print("收尾复核：守卫文件已还原 ✅")
    if bad:
        print(f"\n⛔ 有 {len(bad)} 处没通过：")
        for b in bad:
            print(f"   · {b}")
        return 1
    print(f"\n全部变红 ✅（单独 {len(MUTATIONS)} 组 + 组合 {len(COMBOS)} 组；其中单独零红的几处由组合变异验证为纵深防御）")
    return 0


if __name__ == "__main__":
    sys.exit(main())

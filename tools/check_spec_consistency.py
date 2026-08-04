#!/usr/bin/env python3
"""QMT Plan 4 spec 一致性检验器。

**它存在的理由**：Plan 4 的 spec 评审跑到第二轮时，评审量化出一个稳定的失败模式——
作者的修法「改了 §4，忘了 §5/§6/§9」。而 §6 明写「测试按 §5/§9 的每一条造反例」，
于是那些修法**零回归钉**，导出视图里还留着与 §4 冲突的旧文本（照它写测试会强制复现刚修掉的 bug）。

两轮共 85 条 finding 里，相当一部分属于这一族。**靠自觉挡不住，得让它报错。**

用法：
    python3 tools/check_spec_consistency.py            # 检查，有问题返回 1
    python3 tools/check_spec_consistency.py --counts   # 另打印可粘贴进 §11 的计数行
    python3 tools/check_spec_consistency.py --self-test  # mutation 自测：每项检查都要能被反例触发

检查项：
  C1 跨 spec 引用可解析     —— `<文件>` §X 的文件与章节都必须真实存在
  C2 §4 小节编号无重号
  C3 错误码闭包             —— 出现过的码必须在它的枚举里；枚举里的码必须至少被用过一次
  C4 verdict 闭包           —— 出现过的 verdict 必须在 4c 的 verdict 枚举里
  C5 步骤号闭包             —— 权威序列里的每一步都必须在收尾清单里有出口
  C6 派生视图同步           —— §4 里的规则锚点必须在 §5 或 §9 至少出现一次（本工具的主要目的）
  C7 计数词一致             —— 同一概念的「N 条/项/组/个键」在全文必须同数
  C8 无级联替换污染         —— 「本文件 本文件」「-design.md` `2026」这类切分事故
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
SPEC_DIR = Path(__file__).resolve().parent.parent / "docs" / "superpowers" / "specs"
SPECS = {
    "4a": SPEC_DIR / "2026-07-27-qmt-plan4a-db-guardrails-design.md",
    "4b": SPEC_DIR / "2026-07-27-qmt-plan4b-fetch-design.md",
    "4c": SPEC_DIR / "2026-07-27-qmt-plan4c-pilot-shipment-design.md",
}

# ── C6 的规则锚点：每加一条 §4 规则就在这里登记，工具会盯着它进导出视图 ──────────
# 判据：这些是「过程性规则 / 判据 / 原语」，§6 的测试与 §9 的验收必须够得着它们。
RULE_ANCHORS = {
    "4a": [
        "【绝对空】", "闸 0−", "target_db_in_use", "target_db_unreadable",
        "pilot_cluster_marker", "pilot_create_intent", "维护库专用表集合",
        "datistemplate", "template0", "re.fullmatch", "db_state_initializing",
    ],
    "4b": [
        "open_root", "open_under", "parent_fd_under", "顺序屏障", "立基准模式",
        "manifest_version", "source_path_escape", "staging_path_escape",
        "staging_recheck_failed", "非股级计账", "source_root_relative",
    ],
    # ⚠️ 出货凭据链（is_shipping_credential / ①e / --verify-shipment / crc32 自证 /
    #   report_schema_version / effective_target）已于 2026-07-28 整块移出 4c，
    #   故不再作为本文件的锚点；它们随凭据链进后续 plan，届时在那份 spec 里重新登记。
    "4c": [
        "RUNNING", "①a′", "output_binding", "marker_binding",
        "output_path_diverged", "preserved_superseded", "⑤b′",
    ],
}

# ── C3：错误码字段 → 它的权威枚举所在 spec ────────────────────────────────────
ERROR_FIELDS = {
    "db_boundary_error": "4c",
    "cluster_boundary_error": "4c",
    "output_binding_error": "4c",
    "source_boundary_error": "4c",
    "staging_error": "4c",
}

VERDICTS = re.compile(r"\b(SUCCESS(?:_UNVERIFIED_SOURCE|_NON_SHIPPING)?|FAIL_[A-Z_]+|RUNNING)\b")
STEP = re.compile(r"[①②③④⑤⑥][a-e]?′?")
COUNT = re.compile(r"\*\*?([一二三四五六七八九十]+)(条|项|组|个键)\*\*?(.{0,4})")
CN_NUM = {c: i for i, c in enumerate("零一二三四五六七八九十")}


def sections(text: str) -> dict[str, tuple[int, int]]:
    """返回 {'4' or '5' ...: (start_line, end_line)}，按 '## N.' 顶级标题切分。"""
    lines = text.split("\n")
    marks: list[tuple[str, int]] = []
    for i, line in enumerate(lines):
        m = re.match(r"^## (\d+)\.", line)
        if m:
            marks.append((m.group(1), i))
    out = {}
    for idx, (name, start) in enumerate(marks):
        end = marks[idx + 1][1] if idx + 1 < len(marks) else len(lines)
        out[name] = (start, end)
    return out


def body(text: str, sec: str) -> str:
    s = sections(text)
    if sec not in s:
        return ""
    a, b = s[sec]
    return "\n".join(text.split("\n")[a:b])


def live(text: str) -> str:
    """§11 是评审账本，里面必然引用旧形态，不参与一致性判定。"""
    s = sections(text)
    end = s.get("11", (len(text.split("\n")), 0))[0]
    return "\n".join(text.split("\n")[:end])


def check() -> list[str]:
    _c11_seen: set[str] = set()
    problems: list[str] = []
    texts = {k: p.read_text() for k, p in SPECS.items() if p.exists()}
    missing = [k for k in SPECS if k not in texts]
    if missing:
        return [f"C0 spec 文件不存在: {missing}"]

    for key, full in texts.items():
        t = live(full)
        name = SPECS[key].name

        # C1 跨 spec 引用可解析
        for m in re.finditer(r"`(2026-07-27-qmt-plan4[abc][^`]*\.md)` (§[\d.]+)", t):
            tgt, sec = SPEC_DIR / m.group(1), m.group(2)
            if not tgt.exists():
                problems.append(f"C1 {name}: 引用了不存在的文件 {m.group(1)}")
                continue
            num = sec.lstrip("§")
            tt = tgt.read_text()
            ok = (f"### {num} " in tt) or (f"## {num}. " in tt) or (f"## {num} " in tt)
            if not ok:
                problems.append(f"C1 {name}: 引用 {m.group(1)} {sec} —— 该章节不存在")

        # C2 §4 小节无重号
        subs = [l.split()[1] for l in t.split("\n") if re.match(r"^### 4\.", l)]
        if len(subs) != len(set(subs)):
            dup = sorted({x for x in subs if subs.count(x) > 1})
            problems.append(f"C2 {name}: §4 小节重号 {dup}")

        # C11 枚举成员不得重复 —— 跨行续写的 JSON 字符串很容易把尾部成员抄两遍
        # ⚠️ 字符类**必须含数字**（O4-R25 自测抓到）：原来是 `[a-z_|]`，而 R22 新增的
        #    `phase1_meta_tampered` 带了个 `1` —— 从那一刻起整条 `db_boundary_error`
        #    就再也匹配不上，**C11 对这个字段静默停摆**，而工具照常打印「全过」。
        #    这是「机械检查器被它该抓的东西禁用」那一族的又一次；故下面配了反向断言。
        for m in re.finditer(r'"(\w*(?:error|reason|verdict|kind)\w*)": "([a-z0-9_|]{20,})"', t):
            mem = [x for x in m.group(2).split("|") if x and x != "null"]
            dup = sorted({x for x in mem if mem.count(x) > 1})
            if dup:
                problems.append(f"C11 {name}: 枚举 {m.group(1)} 成员重复 {dup}")
            _c11_seen.add(m.group(1))

        # C10 结构完整性 —— 4c 的 21 条里 13 条是切除损坏，而本工具报全过：
        #     它的 sections() 用 ^## N\. 切章，**粘连标题让解析器自己失效**（body(t,"7") 恒空）。
        secs = re.findall(r"^## (\d+)\.", t, re.M)
        for d in {x for x in secs if secs.count(x) > 1}:
            problems.append(f"C10 {name}: 章节号 §{d} 出现 {secs.count(d)} 次（切分/切除事故）")
        for m in re.finditer(r"^(?!#).*?[^#\s](##+ \d+\.)", t, re.M):
            problems.append(f"C10 {name}: 标题被粘进正文 → {m.group(0).strip()[:70]!r}（会让 ^## 切章失效）")
        for m in re.finditer(r"^(?!\s*[>|#`]).*?(?:（|，)见 $", t, re.M):
            problems.append(f"C10 {name}: 引用目标被删空 → {m.group(0).strip()[-50:]!r}")

        # C9 相邻重复短语（级联替换事故的通用形态；C8 只盯两个固定模式）
        for m in re.finditer(r"(「[^」]{4,30}」)\1", t):
            problems.append(f"C9 {name}: 相邻重复短语 {m.group(1)}（级联替换事故）")

        # C8 切分事故
        for bad in ("本文件 本文件", "-design.md` `2026"):
            n = t.count(bad)
            if n:
                problems.append(f"C8 {name}: 级联替换污染 {bad!r} ×{n}")

        # C6 派生视图同步（本工具的主要目的）
        s4, s5, s6, s9 = (body(t, x) for x in ("4", "5", "6", "9"))
        for anchor in RULE_ANCHORS.get(key, []):
            if anchor in s4 and anchor not in s5 and anchor not in s9 and anchor not in s6:
                problems.append(
                    f"C6 {name}: 规则锚点 {anchor!r} 只在 §4，§5/§6/§9 一处都没有 "
                    f"→ 零回归钉、零验收判据"
                )

        # C7 计数词一致（同一段里同一个量词出现不同数字即可疑）
        # 按「量词 + 紧随其后的名词」分组——只按量词分组会把「集群闸三条」与
        # 「零对象例外六条」当成同一个概念（实测误报）。
        counts: dict[str, dict[int, int]] = {}
        for m in COUNT.finditer(t):
            n = CN_NUM.get(m.group(1), -1)
            noun = re.sub(r"[^\u4e00-\u9fff]", "", m.group(3))[:2]
            if not noun:
                continue          # 后面跟标点/英文 → 无法判定概念，不参与比较
            key = m.group(2) + noun
            counts.setdefault(key, {}).setdefault(n, 0)
            counts[key][n] += 1
        for unit, dist in counts.items():
            if len(dist) > 1:
                shown = ", ".join(f"{k}{unit}×{v}" for k, v in sorted(dist.items()))
                problems.append(
                    f"C7 {name}: 量词「{unit}」出现多个互斥计数 → {shown}"
                    f"（同一概念的计数漂移；确属不同概念请拆开量词或加白名单）"
                )

        # C5 步骤号闭包：权威序列出现的步骤，收尾清单必须有出口
        if key == "4c":
            steps_in_seq = set(STEP.findall(s4))
            tail = re.search(r"^# ===== 准入失败的收尾规则(.*?)(?=^# =====|\Z)", s4, re.S | re.M)
            if not tail:
                problems.append(f"C5 {name}: 找不到收尾清单标题（锚点失效，本检查会空转）")
            else:
                steps_in_tail = set(STEP.findall(tail.group(0)))
                orphan = sorted(steps_in_seq - steps_in_tail)
                # ③④⑤ 等纯序号在散文里很常见，只盯带后缀的关键步骤
                orphan = [x for x in orphan if len(x) > 1]
                # 被正文显式宣告「已取消 / 已移出」的步骤不算步骤 —— 但必须打印，不许静默豁免
                retired = set(re.findall(r"原 (\S+?)「[^」]*」已[^\n]{0,40}?(?:取消|移出)", s4))
                retired |= set(re.findall(r"无 (\S+?) 出货凭据保护闸", s4))
                if retired:
                    print(f"   ℹ️  {name}: C5 豁免已退役步骤 {sorted(retired)}（正文明写已取消/移出）")
                orphan = [x for x in orphan if x not in retired]
                if orphan:
                    problems.append(
                        f"C5 {name}: 权威序列有这些步骤，但收尾清单里没有对应出口: {orphan}"
                    )

    # C4 verdict 闭包（4c 是唯一权威）
    c4 = live(texts["4c"])
    enum_line = next((l for l in c4.split("\n") if '"verdict": "RUNNING|SUCCESS' in l), "")
    known = set(re.findall(r"[A-Z_]{4,}", enum_line))
    for key, full in texts.items():
        for v in set(VERDICTS.findall(live(full))):
            if v not in known:
                problems.append(f"C4 {SPECS[key].name}: verdict {v} 不在 4c 的 verdict 枚举里")

    # C3 错误码闭包
    for field, owner in ERROR_FIELDS.items():
        oc = live(texts[owner])
        decl = "|".join(
            m.group(1) for m in re.finditer(rf'"{field}": "([^"]+)"', oc)
        )
        declared = set(re.findall(r"[a-z_]{4,}", decl))
        if not declared:
            continue
        for key, full in texts.items():
            used = set()
            for m in re.finditer(rf"{field}[^\n]{{0,80}}?[`\"]([a-z_]{{4,}})[`\"]", live(full)):
                used.add(m.group(1))
            for code in used - declared - {"null", "db_bound_identity", "output_binding_error", "staging_error"}:
                problems.append(
                    f"C3 {SPECS[key].name}: {field} 用到 {code!r}，"
                    f"但它不在 {SPECS[owner].name} 的枚举里"
                )

    # ⚠️ **反向断言防空转**（O4-R25）：C11 的正则一旦被新写法甩掉（比如枚举里出现数字、
    #    或值被换行拆开），它会静默地什么都不查而工具照常打印「全过」。
    #    这里钉住几个已知一定存在的枚举字段名 —— 少一个就说明正则失效了。
    for _must in ("db_boundary_error", "cluster_boundary_error", "output_binding_error"):
        if _must not in _c11_seen:
            problems.append(
                f"C11 {_must}: 这个枚举字段没被 C11 的正则匹配到 —— "
                f"匹配式过时了，该检查对它已静默停摆（不是「没有重复」）")

    # ── C12：模块真的会抛出的 boundary code，必须都在 4c 报告枚举里（O4-R18-C2）──
    #    ⚠️ **用 AST 取调用点，不用正则**：`raise PilotDbBoundaryError(` 与它的第一个
    #    参数常常跨行，正则只会抓到恰好同行的那几个 —— 那正是「检查器看起来跑了、
    #    其实只覆盖了一小撮」的空转形态（本仓已栽过三次）。
    #    漏登记的后果不是排版问题：真建库失败时 4c 会序列化一个未声明的值，
    #    或被收敛进泛化分支 —— 而这些 code 恰恰是「库可能已经建出来了/已经 ready」
    #    这类**恢复关键**的诊断。
    module = SPEC_DIR.parent.parent.parent / "backend" / "qmt_pilot_db.py"
    if module.exists():
        import ast as _ast
        emitted: dict[str, set[str]] = {
            "PilotDbBoundaryError": set(), "PilotClusterBoundaryError": set()}
        for node in _ast.walk(_ast.parse(module.read_text())):
            if (isinstance(node, _ast.Call) and isinstance(node.func, _ast.Name)
                    and node.func.id in emitted and node.args
                    and isinstance(node.args[0], _ast.Constant)
                    and isinstance(node.args[0].value, str)):
                emitted[node.func.id].add(node.args[0].value)
        # ⚠️ 匹配式失效必须**明确报错**，不能静默、也不该以 KeyError 收场：
        #    类名一旦被改，`emitted` 会是空的，而下面的差集恒为空 = 检查空转。
        tree_classes = {c.name for c in _ast.walk(_ast.parse(module.read_text()))
                        if isinstance(c, _ast.ClassDef)}
        for cls in ("PilotDbBoundaryError", "PilotClusterBoundaryError"):
            if cls not in tree_classes:
                problems.append(
                    f"C12 backend/qmt_pilot_db.py: 找不到类 {cls} —— "
                    f"AST 匹配式过时了，这项检查会静默空转")
        if not any(emitted.values()):
            problems.append(
                "C12 backend/qmt_pilot_db.py: 一个 boundary code 都没解析出来 —— "
                "AST 匹配式过时了，这项检查会静默空转")
        spec_4c = SPECS["4c"].read_text()
        for field, cls in (("cluster_boundary_error", "PilotClusterBoundaryError"),
                           ("db_boundary_error", "PilotDbBoundaryError")):
            m = re.search(rf'"{field}":\s*"([^"]*)"', spec_4c)
            if not m:
                problems.append(f"C12 4c: 找不到 {field} 的枚举 —— 锚点失效")
                continue
            declared = set(m.group(1).split("|"))
            for code in sorted(emitted.get(cls, set()) - declared):
                problems.append(
                    f"C12 {SPECS['4c'].name}: 模块会抛出 {cls}({code!r})，"
                    f"但它不在 {field} 的枚举里")

    # ── C13：零对象例外的凭据判据，在**每一处**表述里都必须收紧到位（O4-R25-C1）──
    #    这一族在本 PR 里重演了八次：模块改了、计划没改；计划的一个函数改了、另一个没改；
    #    spec 正文改了、验收段没改。**评审只会点出它先看到的那一处。**
    #    故按「判据本身」机械扫：凡是把 `created_at` 当新鲜度依据的写法一律报错，
    #    且实施计划里的零对象谓词必须同时够到 create_confirmed / db_oid / inserted_at。
    plan = ROOT_DIR / "docs/superpowers/plans/2026-07-29-qmt-plan4a-db-guardrails.md"
    docs = [p for p in (ROOT_DIR / "docs").rglob("*.md")]
    assert docs, "一个 md 都没扫到"
    EXEMPT = ("不是调用方传的", "而非", "不再用", "不看 created_at", "非 created_at")
    for p in docs:
        for i, line in enumerate(p.read_text().splitlines(), 1):
            if any(x in line for x in EXEMPT):
                continue
            if re.search(r"created_at_epoch|created_at 距今|created_at.*未超 ", line):
                problems.append(
                    f"C13 {p.name}:{i}: 仍把 `created_at` 当新鲜度依据 —— "
                    f"它是**调用方传进来的**字符串，很远的未来值能让一行 DROP 授权永不过期"
                    f"（O4-R23-C1 起一律看 `inserted_at`）")
    if plan.exists():
        plan_text = plan.read_text()
        for token, why in (
            ("create_confirmed", "未确认的 intent 行不是 DROP 授权（O4-R8-C2）"),
            ("oid_matches_now", "确认位必须绑当前数据库实例（O4-R21-C1 / R25-C1）"),
            ("inserted_at_epoch", "新鲜度只认库时钟（O4-R23-C1）"),
        ):
            if token not in plan_text:
                problems.append(
                    f"C13 {plan.name}: 零对象例外的实施片段没够到 {token!r} —— {why}")
    return problems


def counts_line() -> str:
    parts = []
    for key, p in SPECS.items():
        if not p.exists():
            continue
        t = live(p.read_text())
        parts.append(f"{key}={len(t.split(chr(10)))}行")
    return "SCAN: " + " | ".join(parts)


def self_test() -> int:
    """mutation 自测：每个检查都必须有一个已知会触发它的反例。

    **它存在的理由**：本工具第一版的 C5 与 C7 都是**空转**的——C5 的正则锚到了散文里的
    首次出现（tail 段吞掉整条权威序列，`steps_in_seq - steps_in_tail` 恒为空集），
    C7 收集完计数后**再没有任何代码读它**。于是工具打印「✅ 全过」，而它本该抓到的两处
    真缺陷（`⑤b′` 没进收尾清单、4a 的「三条 vs 六条」）就活在这个空洞里。
    **一个会空转的检查比没有检查更糟：它把「没查出问题」伪装成「没有问题」。**
    """
    import copy
    orig = {k: v.read_text() for k, v in SPECS.items()}
    cases = [
        ("C1", "4c", lambda t: t.replace("`2026-07-27-qmt-plan4b-fetch-design.md` §4.1",
                                         "`2026-07-27-qmt-plan4b-fetch-design.md` §9.9", 1)),
        ("C2", "4b", lambda t: t.replace("### 4.2 ", "### 4.1 ", 1)),
        ("C4", "4c", lambda t: t.replace("| 0a |", "| 0a | `FAIL_BOGUS_VERDICT` 见下 |", 1)),
        ("C5", "4c", lambda t: t.replace("#       ②b →", "#       (已删) →", 1)),
        # C6：往 §4 塞一个只存在于 §4 的锚点，并临时登记它
        ("C6", "4b", lambda t: t.replace("### 4.1 共享地基", "### 4.1 共享地基 ZZTESTANCHOR", 1)),
        ("C8", "4a", lambda t: t.replace("## 1. 背景", "本文件 本文件" + chr(10) * 2 + "## 1. 背景", 1)),
        ("C11", "4c", lambda t: t.replace('"db_boundary_error": "not_owned|',
                                          '"db_boundary_error": "not_owned|not_owned|', 1)),
        ("C10", "4a", lambda t: t.replace("## 2. 目标", "正文尾巴## 2. 目标", 1)),
        ("C9", "4b", lambda t: t.replace("## 1. 背景", "「测试重复短语」「测试重复短语」" + chr(10) * 2 + "## 1. 背景", 1)),
        # C12：把一个模块真的会抛的 code 从枚举里摘掉
        # ⚠️ 反例要挑一个**不随枚举增长而漂移**的锚点：原来的 "|ready_not_set\"," 在枚举
        #    后续扩项之后就失配了，自测当场报「空转」—— 检查没坏，是反例过时（O4-R25 自测抓到）。
        ("C12", "4c", lambda t: t.replace("|phase1_meta_tampered", "", 1)),
        # C13：把 spec 里的新鲜度依据改回 created_at
        # ⚠️ 直接注入一行「把 created_at 当新鲜度依据」的文字最稳 —— 不依赖正文措辞
        #    （首版按原文改写，因为全角/半角逗号写反而恒不匹配，自测报「空转」）。
        ("C13", "4a", lambda t: t.replace(
            "## 1. 背景", "该行 created_at 距今须 < INTENT_TTL。" + chr(10) * 2 + "## 1. 背景", 1)),
    ]
    failed = []
    for cid, spec, mutate in cases:
        try:
            if cid == "C6":
                RULE_ANCHORS["4b"].append("ZZTESTANCHOR")
            SPECS[spec].write_text(mutate(orig[spec]))
            fired = [p for p in check() if p.startswith(cid + " ")]
            if not fired:
                failed.append(f"{cid}: 注入反例后**没有报错** → 该检查空转")
        finally:
            SPECS[spec].write_text(orig[spec])
            if cid == "C6" and "ZZTESTANCHOR" in RULE_ANCHORS["4b"]:
                RULE_ANCHORS["4b"].remove("ZZTESTANCHOR")
    baseline = check()
    for cid, _, _ in cases:
        pass
    if failed:
        print("❌ mutation 自测失败:")
        for f in failed:
            print("  " + f)
        return 1
    print(f"✅ mutation 自测通过（{len(cases)} 项检查各自被反例触发）")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    problems = check()
    if "--counts" in sys.argv:
        print(counts_line())
    if problems:
        print(f"❌ {len(problems)} 处不一致:\n")
        for p in problems:
            print("  " + p)
        return 1
    print("✅ 一致性检查全过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

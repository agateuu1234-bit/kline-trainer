# backend/tests/test_deployment_source_texts.py
"""P7 压缩包来源的五条文案守卫（spec §3.4「Mac 本地三个 v1 包 —— 明确作废为归档」）。

⭐ 这不是文档洁癖：P4 把产物重建成第 2 代之后，任何人照旧文案从 Mac 拷一次，
   就会把 v1 包盖回部署目录，而库里已是新指纹 ⇒ 完整性校验失败或 404，**收口闸却全绿**。

⚠️ **这条守卫挡得住什么、挡不住什么**（最终评审 Important 1；⛔ 别把它当成「回归防护」的全部）：
   · 挡得住：**原句照抄式回退** —— 把被禁的那句话原样写回作用域内任何一处。
   · ⛔ 挡不住：**任何改写式回退** —— 同义改写（「也可以从 Mac 拷一份」）、英文表述、
     把一句话拆成两行（判据逐行比对，跨行即失效）、全角/半角空格或不可见字符差异。
   这是**有意的取舍**（按段落匹配 markdown 的复杂度远高于收益，与 P3a 的 R10 同一形状），
   不是疏漏；但**任何人拿这条守卫下「已防住回退」的结论之前，必须知道它的边界只到这里**。

⛔ 作用域**不得写成全仓**：被禁的那句话在作用域之外仍必须逐字保留 —— 本片 spec 的论证段
   与变异条目、本片的计划文档、以及本文件自己的注释，都必须引用原句才说得清在禁什么。
   ⛔ **刻意不写「仓内共 N 处」这种含自身的总数**：每多写一句关于这句话的话，这个数就大一
   （spec §3.3 对 `INSERT INTO training_sets` 的计数连栽三轮，此处照办）。
"""
from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

RUNBOOKS = REPO_ROOT / "docs" / "runbooks"
NAS_DESIGN = (REPO_ROOT / "docs" / "superpowers" / "specs"
              / "2026-08-14-qmt-nas-deployment-design.md")

# ⛔ 作用域 = 【会被人当操作依据的两类文本】：runbook（照着敲的）+ 那份部署设计（P7 的出处）。
#    ⛔ 不含 `docs/superpowers/specs/2026-09-01-*`（本片 spec）与 `docs/superpowers/plans/**`
#      ——它们是**论证与记述**，必须逐字引用被禁的原句才说得清在禁什么。
#    ⭐ 因为作用域已经把它们排除在外，**不需要**再写一份白名单（spec 里提到的白名单在这个
#      作用域下是空转的；本仓不写永远走不到的分支）。
_FORBIDDEN = "既可从 Mac scp"

# 改写后那句话的三个特征词，必须**同时**出现在同一行。
# ⛔ 不用单个词做判据：「只能」两个字在部署文档里到处都是。
_REWRITTEN_MARKERS = ("只能", "v1 审计归档", "不得再 scp 到部署目录")

_ARCHIVE_NOTE_MARKERS = ("~/qmt_trial_out/", "历史记述，非判据")

# ⛔ NAS handoff 目录那份**也是 v1**（与 Mac 那份 CRC32 逐字相同，是同一批包的两份副本）。
#    最终评审 I1：本片原先的订正只落在两行中的一行，而新规则偏偏把操作者指向了**未订正的那一行**。
_NAS_ARCHIVE_NOTE_MARKERS = ("kline-trainer-handoff-20260814", "历史记述，非判据")

# ⛔ 新规则必须带**前置条件**，不能无条件地把 handoff 目录指定为来源。
_P4_PRECONDITION_MARKERS = ("同样是 v1 包", "P4 重建完成", "不得作为第 2 代产物的来源")


def _scope_files():
    # ⚠️ spec §3.4 写的作用域是 glob `docs/superpowers/specs/2026-08-14-*`，这里**硬编码成单个文件路径**。
    #    实测今天该 glob 只命中这 1 个文件 ⇒ 当前等价；⛔ 日后若多一份 `2026-08-14-*` 的 spec，
    #    会被**静默**漏掉。
    files = [NAS_DESIGN]
    # ⚠️ 后缀白名单是**静默**的盲区：实测今天 `docs/runbooks/` 下 14 个文件全在这三种之内
    #    （8 个 .md / 2 个 .sh / 4 个 .sql）。⛔ 日后若往这里放 `.yml` / `.txt` / `.env` 之类
    #    **同样会被人照着敲**的文件，必须回来把后缀补进去 —— 漏掉不会报错，守卫照样全绿。
    files += [p for p in RUNBOOKS.rglob("*")
              if p.is_file() and p.suffix in (".md", ".sql", ".sh")]
    # ⛔ 防空转：目录被改名/移走时 `rglob` **静默返回空**（不报错），整条禁令守卫会从
    #    「扫十几个文件」退化成「扫 1 个」且照样全绿 —— 本仓「报 0 违反的扫描必须先证明
    #    它能报非 0」那一类。
    assert len(files) >= 2, f"作用域只收集到 {len(files)} 个文件 —— runbooks 目录是不是被改名/移走了？"
    return files


def test_p7_source_wording_no_longer_offers_the_mac_copy():
    """守卫①：作用域内不得再出现「既可从 Mac scp」这句旧文案。"""
    offenders = []
    for p in _scope_files():
        try:
            text = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError) as e:
            # ⛔ 不把「读不了」混进「不是目标」（本仓「守卫里一个 continue 混了两种含义」教训）：
            #    读不了必须**响**，否则一个权限错误会让整份文件静默退出作用域。
            raise AssertionError(f"作用域内的文件读不了，无法判定：{p} —— {e}") from e
        for i, line in enumerate(text.splitlines(), start=1):
            if _FORBIDDEN in line:
                offenders.append(f"{p.relative_to(REPO_ROOT).as_posix()}:{i}: {line.strip()[:120]}")
    assert not offenders, (
        "作用域内仍有「P7 既可从 Mac scp」这类文案 —— P4 重建后照它拷一次就会把 v1 包"
        "盖回部署目录，而收口闸全绿：\n" + "\n".join(offenders))


def test_rewritten_p7_source_rule_is_present():
    """守卫①的**正向对照（其一）**：改写后那句「只能从 NAS handoff 取」必须真的在，且恰好 1 行。

    ⚠️ 只有上面那条禁令的话，把 `:138` **整行删掉**同样能让它变绿 —— 那不是订正，是删证据。
    ⛔ 与下面那条**必须分成两个测试函数**：写在同一个函数里时，前一条 `assert` 先失败即中止，
       后一条根本不会执行 —— 两处被同一次编辑一起删掉时，失败信息只提得到前一处
       （本仓「两条判据互相掩盖」的成文教训）。
    """
    lines = NAS_DESIGN.read_text(encoding="utf-8").splitlines()
    rule = [l for l in lines if all(m in l for m in _REWRITTEN_MARKERS)]
    assert len(rule) == 1, (
        f"部署设计里「P7 只能从 NAS handoff 取 / Mac 副本仅作 v1 审计归档 / 不得再 scp 到部署目录」"
        f"应恰好 1 行，实测 {len(rule)} 行 —— 0 行 = 被整行删掉；>1 行 = 抄了两份（会各自漂移）")


def test_mac_copy_archive_note_is_present():
    """守卫①的**正向对照（其二）**：Mac 三个 zip 那行必须带「历史记述，非判据」标注，且恰好 1 行。

    ⚠️ 它独立成一个测试的理由见上一条的 docstring。
    """
    lines = NAS_DESIGN.read_text(encoding="utf-8").splitlines()
    note = [l for l in lines if all(m in l for m in _ARCHIVE_NOTE_MARKERS)]
    assert len(note) == 1, (
        f"Mac 三个 zip 那行应带「历史记述，非判据」标注且恰好 1 行，实测 {len(note)} 行 —— "
        f"少了它，P4 重建之后有人会拿那三个 v1 指纹当「应该是多少」的判据")


def test_nas_handoff_copy_archive_note_is_present():
    """守卫①的**正向对照（其三）**：NAS handoff 那行也必须带「历史记述，非判据」标注，且恰好 1 行。

    ⚠️ **最终评审 I1**：`:135`（Mac 副本）与 `:136`（NAS handoff 副本）的三个 CRC32 **逐字相同**
       —— 本就是同一批 v1 包的两份副本。原先只给前者加了标注，后者原样留着 ⇒
       「拿 v1 指纹当『应该是多少』」这个被消灭的风险，在下一行完好无损。
    """
    lines = NAS_DESIGN.read_text(encoding="utf-8").splitlines()
    note = [l for l in lines if all(m in l for m in _NAS_ARCHIVE_NOTE_MARKERS)]
    assert len(note) == 1, (
        f"NAS handoff 那行应带「历史记述，非判据」标注且恰好 1 行，实测 {len(note)} 行 —— "
        f"它与 Mac 那份是同一批 v1 包，少了标注就会有人拿那三个 v1 指纹当判据")


def test_p7_source_rule_carries_the_p4_precondition():
    """守卫①的**正向对照（其四）**：那条「只能从 handoff 取」的规则必须带 **P4 前置条件**。

    ⚠️ **最终评审 I1 的核心**：规则给出的理由（v1 包与新指纹对不上）**逐字适用于它自己指定的
       那个替代来源**。不带前置条件的话，P4 之后照新规则做会产生**同一个**故障，而且这次
       带着权威背书 —— 比订正之前更糟（操作者会以为自己拿到了背书）。
    ⛔ 本条**必须独立成测试**：与上面几条合并会互相掩盖（本仓成文教训）。
    """
    lines = NAS_DESIGN.read_text(encoding="utf-8").splitlines()
    hit = [l for l in lines if all(m in l for m in _P4_PRECONDITION_MARKERS)]
    assert len(hit) == 1, (
        f"「P7 只能从 handoff 取」这条规则应带 P4 前置条件且恰好 1 行，实测 {len(hit)} 行 —— "
        f"0 行 = 规则又变回无条件，会把操作者指向同样是 v1 的那份副本")

# backend/tests/test_deployment_source_texts.py
"""P7 压缩包来源的两条文案守卫（spec §3.4「Mac 本地三个 v1 包 —— 明确作废为归档」）。

⭐ 这不是文档洁癖：P4 把产物重建成第 2 代之后，任何人照旧文案从 Mac 拷一次，
   就会把 v1 包盖回部署目录，而库里已是新指纹 ⇒ 完整性校验失败或 404，**收口闸却全绿**。
⛔ 作用域**不得写成全仓**：「既可从 Mac scp」这句话全仓实测 4 处命中，其中 **3 处就在本片
   自己的 spec 里**（论证段与变异条目必须逐字引用原句），删不得。
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


def _scope_files():
    files = [NAS_DESIGN]
    files += [p for p in RUNBOOKS.rglob("*")
              if p.is_file() and p.suffix in (".md", ".sql", ".sh")]
    return files


def test_p7_source_wording_no_longer_offers_the_mac_copy():
    """守卫①：作用域内不得再出现「既可从 Mac scp」这句旧文案。"""
    offenders = []
    for p in _scope_files():
        try:
            text = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for i, line in enumerate(text.splitlines(), start=1):
            if _FORBIDDEN in line:
                offenders.append(f"{p.relative_to(REPO_ROOT).as_posix()}:{i}: {line.strip()[:120]}")
    assert not offenders, (
        "作用域内仍有「P7 既可从 Mac scp」这类文案 —— P4 重建后照它拷一次就会把 v1 包"
        "盖回部署目录，而收口闸全绿：\n" + "\n".join(offenders))


def test_rewritten_p7_source_rule_and_archive_note_are_present():
    """守卫①的**正向对照**：改写后的那两句必须**真的在**那份部署设计里，各恰好 1 行。

    ⚠️ 只有上面那条禁令的话，把 `:138` **整行删掉**同样能让它变绿 —— 那不是订正，是删证据。
    """
    lines = NAS_DESIGN.read_text(encoding="utf-8").splitlines()

    rule = [l for l in lines if all(m in l for m in _REWRITTEN_MARKERS)]
    assert len(rule) == 1, (
        f"部署设计里「P7 只能从 NAS handoff 取 / Mac 副本仅作 v1 审计归档 / 不得再 scp 到部署目录」"
        f"应恰好 1 行，实测 {len(rule)} 行 —— 0 行 = 被整行删掉；>1 行 = 抄了两份（会各自漂移）")

    note = [l for l in lines if all(m in l for m in _ARCHIVE_NOTE_MARKERS)]
    assert len(note) == 1, (
        f"Mac 三个 zip 那行应带「历史记述，非判据」标注且恰好 1 行，实测 {len(note)} 行 —— "
        f"少了它，P4 重建之后有人会拿那三个 v1 指纹当「应该是多少」的判据")

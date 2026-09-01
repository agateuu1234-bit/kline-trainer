"""QMT 4b S2：fetch_manifest.json 的结构、读侧闭合校验与生命周期。

Spec: docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md §4.4 + §4.5
（含文末「S2 实施轮」的五条更正 S2-F1~F5）。

⚠️ 本文件全部测试跑在 tmp_path 或纯内存，零 DB、零网络、零真实挂载点。
"""
from __future__ import annotations

import copy

import pytest

from qmt_manifest import (
    MANIFEST_VERSION,
    MANIFEST_NAME,
    MARKETS,
    PERIODS,
    REQUIRED_KEYS,
    STOPPED_REASONS,
    FATAL_KINDS,
    REASONS_REQUIRING_FATAL,
    VERIFICATION_LEVELS,
    LIFECYCLE_KEYS,
    ManifestInvalidError,
    ManifestVersionError,
)


def test_constants_have_the_exact_spec_values():
    """外延写死的枚举必须逐字等于 spec，不多不少。

    判别力：任一枚举漏一个值或多一个值，本条必红。spec 反复栽在
    「新错误码没进任何枚举」（R89 自查补抓到 staging_path_escape 出现 4 次
    却不属于任何枚举）。
    """
    assert MANIFEST_VERSION == 1
    assert MANIFEST_NAME == "fetch_manifest.json"
    assert MARKETS == ("SH", "SZ", "BJ")
    assert PERIODS == ("1m", "daily")
    assert set(STOPPED_REASONS) == {
        "max_bytes", "source_path_escape",
        "staging_path_escape", "staging_recheck_failed",
    }
    assert set(FATAL_KINDS) == {"source_path_escape", "staging_path_escape"}
    assert set(REASONS_REQUIRING_FATAL) == {
        "source_path_escape", "staging_path_escape", "staging_recheck_failed",
    }
    assert set(VERIFICATION_LEVELS) == {"snapshot", "full", "partial"}
    assert set(LIFECYCLE_KEYS) == {
        "stopped_reason", "stopped_reason_secondary", "fetch_fatal_error",
    }


def test_required_keys_is_the_exact_ten_and_excludes_top_level_universe():
    """必需键外延写死，且**顶层没有 universe**（spec S2-F3）。

    判别力：把 "universe" 加回去，本条必红——而照原 spec 实现正是加了它，
    后果是本工具诚实产出的每一份 manifest 都被自己的读侧判非法。
    """
    assert set(REQUIRED_KEYS) == {
        "manifest_version", "seed", "source_snapshot", "source_mount",
        "pool_order", "cursor", "files", "staged_export_log",
        "source_verification", "source_verification_evidence",
    }
    assert "universe" not in REQUIRED_KEYS


def test_version_error_is_not_an_invalid_error():
    """两族异常必须可区分（spec O2-F8）：一个是「换 staging」，
    一个是「换工具版本」，混成一句话会让操作者无路可走。

    判别力：把 ManifestVersionError 写成 ManifestInvalidError 的子类，本条必红。
    """
    assert not issubclass(ManifestVersionError, ManifestInvalidError)
    assert not issubclass(ManifestInvalidError, ManifestVersionError)


def test_version_error_carries_kind_and_actionable_guidance():
    older = ManifestVersionError(kind="older", found=0, expected=1)
    newer = ManifestVersionError(kind="newer", found=99, expected=1)
    assert older.kind == "older" and older.found == 0 and older.expected == 1
    assert newer.kind == "newer"
    # 指引必须不同，且都是操作者能照做的动作
    assert older.guidance != newer.guidance
    assert "换新 staging" in older.guidance
    assert "更新版本" in newer.guidance


def test_invalid_error_carries_a_detail_string():
    e = ManifestInvalidError("缺少必需字段 seed")
    assert "seed" in str(e)


def test_every_invalid_error_carries_actionable_guidance():
    """⭐ 不变量：**任何**一条「账本坏了」的拒绝，字符串里都必须带动作指引。

    本模块有 90 个拒绝点，逐点检查那句话写没写是不可能的纪律——
    把指引提到异常类里统一追加，这条不变量就成了结构上不可违反的东西。
    （本片被评审提了三次「只说哪里不对、没说该怎么办」，根因即在此。）

    判别力：把 GUIDANCE 的追加去掉（`super().__init__(detail)`），本条必红。
    """
    e = ManifestInvalidError("随便什么细节")
    assert "随便什么细节" in str(e)          # 「哪里不对」还在
    assert "该怎么办" in str(e)              # 「该怎么办」被统一追加
    assert "换一个新的 staging" in str(e)    # 且是可执行的动作，不是空话


def test_invalid_error_keeps_the_raw_detail_separately():
    """`detail` 保留未经追加的原文，便于精确断言与日志分级。"""
    e = ManifestInvalidError("缺少必需字段 'seed'")
    assert e.detail == "缺少必需字段 'seed'"


def test_invalid_error_survives_a_serialization_round_trip():
    """⭐ 指引只能出现一次——哪怕异常被序列化后重建。

    上一轮把指引拼进了 `args`，而反序列化用 `cls(*args)` 重建 → 指引被追加两遍
    （2026-08-25 控制者实测确认）。改为 `args` 保持原文、`__str__` 负责追加之后，
    往返才幂等。4c 将来可能跨进程传这个异常。

    判别力：把 `super().__init__(detail)` 改回拼接串，本条必红。
    """
    import pickle
    e = ManifestInvalidError("缺少必需字段 'seed'")
    back = pickle.loads(pickle.dumps(e))
    assert str(back).count("该怎么办") == 1
    assert back.detail == "缺少必需字段 'seed'"
    assert str(back) == str(e)


from qmt_manifest import check_version


def test_check_version_accepts_current():
    """正向放行档。"""
    assert check_version({"manifest_version": 1}) == 1


def test_check_version_missing_is_treated_as_zero_and_reported_as_older():
    """缺失视为 0，走「低于」档（O4-F10：原文只写了「低于」一档，
    「大于」与「缺失」只在 §5 出现过）。"""
    with pytest.raises(ManifestVersionError) as ei:
        check_version({})
    assert ei.value.kind == "older"
    assert ei.value.found == 0


def test_check_version_older_and_newer_are_distinct_kinds():
    with pytest.raises(ManifestVersionError) as older:
        check_version({"manifest_version": 0})
    assert older.value.kind == "older"

    with pytest.raises(ManifestVersionError) as newer:
        check_version({"manifest_version": 2})
    assert newer.value.kind == "newer"


def test_check_version_rejects_non_dict_as_invalid_not_version():
    """根本不是对象 → 形状非法，**不是**版本问题。"""
    for bad in ([], "x", 3, None):
        with pytest.raises(ManifestInvalidError):
            check_version(bad)


def test_check_version_rejects_non_int_version_as_invalid():
    """版本号存在但不是整数 → 形状非法。

    ⚠️ bool 是 int 的子类：True 必须被拒，否则 {"manifest_version": True}
    会被当成版本 1 放行。
    """
    for bad in ("1", 1.0, True, None, [1]):
        with pytest.raises(ManifestInvalidError):
            check_version({"manifest_version": bad})


def test_check_version_ignores_everything_but_the_version():
    """一份**只有版本号、别的全没有**的输入，`check_version` 也必须只看版本
    ——它不该顺手去查形状（那是 `validate_manifest` 的活）。

    ⚠️ **本条测不到「先版本后形状」的次序**（2026-08-25 控制者归因自查）：
    次序是 `validate_manifest` 内部两步的先后，而它到 Task 5 才存在。
    真正的次序钉是 Task 5 的 `test_validate_manifest_reports_version_before_shape`。
    判别力：`raw > MANIFEST_VERSION` 那一支短路掉，本条必红（已变异证实）。
    """
    with pytest.raises(ManifestVersionError) as ei:
        check_version({"manifest_version": 99})       # 只有版本号，别的全没有
    assert ei.value.kind == "newer"


import hashlib
import json as _json

from qmt_manifest import aggregate_sha256, manifest_members


def test_aggregate_sha256_is_the_exact_frozen_serialization():
    """算法逐字写死（S2-F4）：按相对路径升序 → JSON（中文不转义、分隔符无空格）
    → UTF-8 → sha256。

    判别力：ensure_ascii、separators、排序、UTF-8 任一改动，本条必红。
    这四个都是**判据的一部分**——周期目录名是中文，ensure_ascii 的两个取值
    会产出完全不同的字节。
    """
    members = [
        ("日K线_前复权/000001.SZ_平安银行_日K线_前复权.csv", "b" * 64),
        ("1分钟K线_前复权/000001.SZ_平安银行_1分钟K线_前复权.csv", "a" * 64),
    ]
    expect_blob = _json.dumps(
        [["1分钟K线_前复权/000001.SZ_平安银行_1分钟K线_前复权.csv", "a" * 64],
         ["日K线_前复权/000001.SZ_平安银行_日K线_前复权.csv", "b" * 64]],
        ensure_ascii=False, separators=(",", ":"),
    ).encode("utf-8")
    assert aggregate_sha256(members) == hashlib.sha256(expect_blob).hexdigest()


def test_aggregate_sha256_is_order_independent_of_input():
    """输入次序不影响结果（内部排序），否则「先拷谁」会改变聚合值。"""
    a = [("x/1.csv", "a" * 64), ("x/2.csv", "b" * 64)]
    assert aggregate_sha256(a) == aggregate_sha256(list(reversed(a)))


def test_aggregate_sha256_differs_when_ensure_ascii_would_differ():
    """钉住 ensure_ascii=False 这一半：若实现漏写它（默认 True），
    中文路径会被转成 \\uXXXX，聚合值不同。

    判别力：把 ensure_ascii=False 删掉，本条必红。
    """
    members = [("1分钟K线_前复权/a.csv", "a" * 64)]
    ascii_blob = _json.dumps([["1分钟K线_前复权/a.csv", "a" * 64]],
                             ensure_ascii=True, separators=(",", ":")).encode("utf-8")
    assert aggregate_sha256(members) != hashlib.sha256(ascii_blob).hexdigest()


def test_aggregate_sha256_differs_when_separators_would_differ():
    """钉住 separators 这一半：默认分隔符带空格，聚合值不同。

    判别力：把 separators=(",", ":") 删掉，本条必红。
    """
    members = [("a.csv", "a" * 64)]
    spaced = _json.dumps([["a.csv", "a" * 64]], ensure_ascii=False).encode("utf-8")
    assert aggregate_sha256(members) != hashlib.sha256(spaced).hexdigest()


def test_manifest_members_is_files_plus_staged_export_log():
    """成员集合写死（O2-F12）：files 每条 + staged_export_log 一条。
    故 files_verified 恒为奇数 2N+1（O4-F13 定的就是这个数）。

    判别力：漏掉 staged_export_log 那一条，本条必红——而 spec 原文正是
    「写侧含 export_log、读侧要求由 files 逐条重算而 files 里没有它」，
    差这一项就让每份诚实产出的 manifest 都被判非法。
    """
    m = {
        "files": [
            {"relative_path": "1分钟K线_前复权/a.csv", "sha256": "a" * 64},
            {"relative_path": "日K线_前复权/a.csv", "sha256": "b" * 64},
        ],
        "staged_export_log": {"relative_path": "export_log.csv", "sha256": "c" * 64},
    }
    members = manifest_members(m)
    assert len(members) == 3                      # 2N+1，N=1
    assert ("export_log.csv", "c" * 64) in members


from qmt_manifest import validate_manifest


def _sha(tag: str) -> str:
    """造一个形状合法、可区分的假 sha256（只用于测试，不代表真实哈希）。"""
    return hashlib.sha256(tag.encode("utf-8")).hexdigest()


def _file_rec(code: str, name: str, period: str) -> dict:
    """按**真实 QMT 导出格式**造一条文件记录。

    ⚠️ 目录名与文件名里的 label 必须同源：目录 = f"{label}_前复权"，
    文件名 = f"{code}_{name}_{label}_前复权.csv"。照想象造样本让两个缺陷
    藏了三年且测试全绿（见 qmt_ingest 的 1d/status 两个生产缺陷）。
    """
    label = "1分钟K线" if period == "1m" else "日K线"
    rel = f"{label}_前复权/{code}_{name}_{label}_前复权.csv"
    return {"stock_code": code, "period": period, "relative_path": rel,
            "bytes": 1234567, "sha256": _sha(rel)}


_STOCKS = (("600000.SH", "浦发银行"), ("000001.SZ", "平安银行"))


def _valid_manifest(**overrides) -> dict:
    """一份**必须能通过全部校验**的最小合法 manifest。

    所有否定档从它派生、只改一处。`source_verification_evidence` 在 overrides
    **之后**按最终的 files/staged_export_log 重算，这样改 files 的档不会因为
    聚合值对不上而被**另一条**判据拒掉——**两条判据互相掩盖时，单独变异
    都不会红**（本仓栽过的假阴性形态之一）。
    """
    universe = {
        "SH": ["600000.SH", "600004.SH", "600006.SH"],
        "SZ": ["000001.SZ", "000002.SZ"],
        "BJ": ["430047.BJ"],
    }
    elog_sha = _sha("export_log.csv@2026-08-24")
    m: dict = {
        "manifest_version": 1,
        "seed": "s-2026-08-24",
        "source_snapshot": {"export_log_sha256": elog_sha, "universe": universe},
        "source_mount": {
            "fstype": "smbfs",
            "device": "//agate@192.168.5.151/QMT_Export",
            "source_root_relative": "front_ratio_cn_stocks_ab_bj",
        },
        "pool_order": {
            "SH": [{"code": "600000.SH", "universe_idx": 0}],
            "SZ": [{"code": "000001.SZ", "universe_idx": 0}],
            "BJ": [],
        },
        "cursor": {"SH": 1, "SZ": 1, "BJ": 0},
        "files": [r for code, nm in _STOCKS for r in
                  (_file_rec(code, nm, "1m"), _file_rec(code, nm, "daily"))],
        "staged_export_log": {"relative_path": "export_log.csv",
                              "bytes": 2399554, "sha256": elog_sha},
        "source_verification": "full",
        "operator_attestation": {"no_export_window": True,
                                 "recorded_at": "2026-08-24T12:00:00+08:00"},
    }
    m.update(overrides)
    if "source_verification_evidence" not in overrides:
        try:
            agg = aggregate_sha256(manifest_members(m))
            n = len(m["files"]) + 1
        except Exception:                     # overrides 把 files 弄坏了
            agg, n = _sha("uncomputable"), 0
        m["source_verification_evidence"] = {
            "level": "full",
            "passes": [
                {"pass": 1, "files_verified": n, "aggregate_sha256": agg,
                 "completed_at": "2026-08-24T12:01:00+08:00"},
                {"pass": 2, "files_verified": n, "aggregate_sha256": agg,
                 "completed_at": "2026-08-24T12:09:00+08:00"},
            ],
            "passes_agree": True,
        }
    return m


def _recompute_evidence(m: dict) -> dict:
    """改动 files / staged_export_log 之后**必须**调它一次。

    ⚠️⚠️ 不调的后果是**两条判据互相掩盖，让变异验证出假阴性**：聚合指纹的成员是
    `(relative_path, sha256)`，改了任一项（或增删条目）都会让存根里的
    `aggregate_sha256` 与 `files_verified` 同时对不上。此时否定档照样红——
    但红的是**聚合判据**，不是被测的那一条。于是把被测判据变异掉之后测试
    **仍然绿**，而变异表会显示「零红」，被误读成「测试没判别力」。
    本仓栽过这个形态（见 feedback_mutation_false_negatives_two_shapes）。

    弄坏到算不出来时保持原样：那种档由 files / staged_export_log 的形状判据
    负责（它们排在存根校验**之前**）。
    """
    try:
        agg = aggregate_sha256(manifest_members(m))
        n = len(m["files"]) + 1
    except Exception:
        return m
    m["source_verification_evidence"]["passes"] = [
        {"pass": i + 1, "files_verified": n, "aggregate_sha256": agg,
         "completed_at": f"2026-08-24T12:0{i}:00+08:00"} for i in range(2)]
    return m


def _with_universe(uni: dict, **overrides) -> dict:
    """只换 universe，**保持两处 export_log sha256 一致**。

    ⚠️ 不这么做的话，「staged_export_log.sha256 必须等于
    source_snapshot.export_log_sha256」那条判据会**掩盖**本要测的判据：
    否定档照样红，但红的是相等判据，于是变异掉被测判据后测试仍绿。
    """
    base = _valid_manifest()
    return _valid_manifest(
        source_snapshot={
            "export_log_sha256": base["source_snapshot"]["export_log_sha256"],
            "universe": uni},
        **overrides)


def test_the_baseline_manifest_passes_everything():
    """⭐ 正向放行档 —— 整套否定档的判别力全部建立在它之上。

    没有这一条，一个 `def validate_manifest(p): raise ManifestInvalidError("x")`
    的**恒抛**实现会让下面每一条否定档都绿，而五组判据一次都没执行过。
    本仓真栽过这个形态（429 测试 + codex 14 轮全漏）。
    """
    m = _valid_manifest()
    assert validate_manifest(m) == m


@pytest.mark.parametrize("missing", [
    "manifest_version", "seed", "source_snapshot", "source_mount",
    "pool_order", "cursor", "files", "staged_export_log",
    "source_verification", "source_verification_evidence",
])
def test_every_required_key_is_actually_required(missing):
    """10 个必需键**逐个**删，每个都必须让整份 manifest 被拒。

    判别力：把 REQUIRED_KEYS 里任一项删掉，对应那个参数档必红。
    ⚠️ 缺 manifest_version 那一档抛的是 ManifestVersionError（缺失视为 0），
    与其余九档不同——这正是「版本与形状是两族」的体现。
    """
    m = _valid_manifest()
    del m[missing]
    expected = ManifestVersionError if missing == "manifest_version" else ManifestInvalidError
    with pytest.raises(expected):
        validate_manifest(m)


def test_top_level_universe_is_not_required_and_not_rejected():
    """顶层没有 universe（S2-F3）：不加它照样过；加了也只当未知键保留。

    判别力：把 "universe" 加回 REQUIRED_KEYS，本条第二半必红。
    """
    assert "universe" not in _valid_manifest()          # 基座本来就没有它
    validate_manifest(_valid_manifest())                # 且照样通过


def test_validate_manifest_reports_version_before_shape():
    """⭐⭐ **真正的次序钉**（Task 3 那条测不到它——它调的是 `check_version`，
    而 `validate_manifest` 那时还不存在；2026-08-25 控制者归因自查发现）。

    一份版本更高、且按**本版**要求缺了九个必需键的 manifest，必须报
    `ManifestVersionError`（「你的工具太旧」），**而不是** `ManifestInvalidError`
    （「账本畸形」）。一棵已拉几百只股的 staging 收到错误的那一句，
    操作者就不知道该重拉还是该换工具版本（O4-F10 栽过的那档）。

    判别力：把 `validate_manifest` 写成「先查必需键、再 `check_version`」，本条必红。
    """
    with pytest.raises(ManifestVersionError) as ei:
        validate_manifest({"manifest_version": 99})     # 只有版本号，别的全没有
    assert ei.value.kind == "newer"


def test_validate_manifest_reports_shape_error_when_version_matches():
    """反向档：版本对上了，才轮到形状判据说话。

    没有这一条，一个「凡缺键就报 VersionError」的实现也能让上一条绿。
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest({"manifest_version": 1})      # 版本对，但九个必需键全缺


def test_empty_seed_is_rejected():
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(seed=""))


def test_non_string_seed_is_rejected():
    for bad in (1, None, ["s"]):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(seed=bad))


def test_source_snapshot_universe_must_have_all_three_markets_as_lists():
    for bad in (
        {"SH": [], "SZ": []},                       # 缺 BJ
        {"SH": [], "SZ": [], "BJ": {}},             # BJ 不是 list
        {"SH": [], "SZ": [], "BJ": [], "HK": []},   # 多一层
    ):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_with_universe(
                bad, pool_order={"SH": [], "SZ": [], "BJ": []},
                cursor={"SH": 0, "SZ": 0, "BJ": 0}, files=[]))


def test_source_snapshot_universe_entries_must_be_valid_codes():
    """池与清单一并清空，好让 pool_order 的交叉核对（与本判据重叠）够不着
    ——否则变异掉本判据后交叉核对会顶上来，测试仍绿而变异表显示「零红」。"""
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_with_universe(
            {"SH": ["../escape"], "SZ": [], "BJ": []},
            pool_order={"SH": [], "SZ": [], "BJ": []},
            cursor={"SH": 0, "SZ": 0, "BJ": 0}, files=[]))


def test_universe_code_suffix_must_match_its_layer():
    """⭐ 只有本条够得到：代码本身合法，但被放进了**错的层**。

    池与清单清空的理由同上：pool_order 的交叉核对与本判据重叠。
    （对比 Task 7 的同名判据——那一条**造不出**专属档，已登记为等价变异。）
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_with_universe(
            {"SH": ["000001.SZ"], "SZ": [], "BJ": []},
            pool_order={"SH": [], "SZ": [], "BJ": []},
            cursor={"SH": 0, "SZ": 0, "BJ": 0}, files=[]))


def test_source_snapshot_export_log_sha256_must_be_hex64():
    """⚠️ **两处 sha 同时设成同一个坏值**，好让「两处必须相等」那条判据够不着。

    只改 source_snapshot 那一处的话，相等判据会掩盖格式判据：把格式判据
    变异掉（例如放宽成允许大写）之后，"A"*64 那一档仍会被相等判据拒 →
    测试仍绿 → 变异表显示「零红」，被误读成「测试没判别力」。
    """
    base = _valid_manifest()
    for bad in ("", "XYZ", "A" * 64, "a" * 63, 1, None):
        m = _valid_manifest(
            source_snapshot={"export_log_sha256": bad,
                             "universe": base["source_snapshot"]["universe"]})
        m["staged_export_log"]["sha256"] = bad
        _recompute_evidence(m)
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_source_mount_requires_three_subkeys():
    base = {"fstype": "smbfs", "device": "//h/s", "source_root_relative": "d"}
    for drop in ("fstype", "device", "source_root_relative"):
        bad = dict(base)
        del bad[drop]
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(source_mount=bad))


def test_source_mount_fstype_and_device_must_be_nonempty():
    for key in ("fstype", "device"):
        bad = {"fstype": "smbfs", "device": "//h/s", "source_root_relative": "d"}
        bad[key] = ""
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(source_mount=bad))


def test_source_root_relative_may_be_empty_string():
    """⭐ S2-F2：`source_root_relative` **允许空串**。

    §4.6 (ii-a) 用实测论证了「共享本身就是导出根」时它就是空串，并规定拼接
    走 posixpath.normpath 以免撞空分量。而读侧原文写「三子键均为非空 str」——
    两条并存时，一次**完全合法的部署**会先过 (ii-a) 的拼接、再被读侧判死，
    操作者被指向一个不存在的问题。

    判别力：把 source_root_relative 也按「非空」校验，本条必红。
    """
    m = _valid_manifest(source_mount={
        "fstype": "smbfs", "device": "//h/s", "source_root_relative": "",
    })
    assert validate_manifest(m) == m


def test_source_root_relative_must_still_be_a_string():
    """允许空串 ≠ 允许任意类型。"""
    for bad in (None, 0, [], {}):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(source_mount={
                "fstype": "smbfs", "device": "//h/s", "source_root_relative": bad,
            }))


def test_source_mount_may_carry_extra_trace_only_keys():
    """mountpoint / source_root 只留痕、不参与判定（R25-F2），
    带着它们必须照样通过——否则一个诚实产出的 manifest 会被拒。"""
    m = _valid_manifest(source_mount={
        "fstype": "smbfs", "device": "//h/s",
        "source_root_relative": "front_ratio_cn_stocks_ab_bj",
        "mountpoint": "/Users/agate/qmt_mnt",
        "source_root": "/Users/agate/qmt_mnt/front_ratio_cn_stocks_ab_bj",
    })
    assert validate_manifest(m) == m


def test_pool_order_must_have_all_three_markets_as_lists():
    for bad in ({"SH": [], "SZ": []}, {"SH": [], "SZ": [], "BJ": 0}):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(pool_order=bad))


def test_pool_order_bare_string_elements_are_rejected():
    """⭐ 旧式裸字符串必须被拒（R13-F1）。

    判别力：若实现「兼容」裸字符串（退回只读 code），本条必红。
    退回等于丢掉 universe_idx，把 R12-F1 那个「产出取决于网络抖动」的口子重开。
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(pool_order={
            "SH": ["600000.SH"], "SZ": [], "BJ": [],
        }))


def test_pool_order_string_element_containing_the_key_names_is_still_rejected():
    """⭐ 只有类型判据够得到的档：一个**含有那两个键名子串**的字符串。

    对字符串来说 `"code" in item` 是**子串检查**而非键检查，所以
    `"code universe_idx"` 这种输入能穿过「两个键都要在」那条判据；
    再往下执行 `item["code"]` 就会泄漏裸 `TypeError`
    （英文报错，操作者读不懂，也不带「该怎么办」）。

    `isinstance(item, dict)` 排在第一道挡住了它——本条就是给那条判据配的
    专属档（2026-08-25 控制者变异时发现它此前无档：删掉类型判据，
    现有测试一条都测不出来）。

    判别力：把类型判据挪到键存在性判据之后，或删掉它，本条必红
    （届时抛的是 TypeError 而不是 ManifestInvalidError）。
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            pool_order={"SH": ["code universe_idx"], "SZ": [], "BJ": []}))


def test_pool_order_element_needs_both_code_and_universe_idx():
    for bad in ({"code": "600000.SH"}, {"universe_idx": 0}, {}):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                pool_order={"SH": [bad], "SZ": [], "BJ": []},
                files=[], staged_export_log={"relative_path": "export_log.csv",
                                             "bytes": 1, "sha256": _sha("e")}))


def test_pool_order_code_must_match_the_stock_code_pattern():
    for bad in ("600000", "600000.HK", "../600000.SH", "600000.sh", ""):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                pool_order={"SH": [{"code": bad, "universe_idx": 0}],
                            "SZ": [], "BJ": []}))


def test_pool_order_code_suffix_must_match_its_market_layer():
    """代码本身合法，但被放进了错的层。

    ⚠️⚠️ **本条的判别力是「有时序的」**（2026-08-25 实施 Task 7 时由实施者发现、
    控制者实测确认）：

    · **Task 8 落地之前**（`_validate_pool_order` 里还没有交叉核对
      `universe[mk][idx] == code`）——本条**有真判别力**：关掉后缀判据它就红。
    · **Task 8 落地之后**——交叉核对会覆盖它：在一份**合法的** universe 下
      （每层 code 后缀都对），一个后缀错的 pool_order code 必然也过不了
      `universe[mk][idx] == code`。两条判据**结构上重叠**，本条随之退化为
      **等价变异**（关掉后缀判据仍绿是**预期**）。

    ⚠️ **别因为它「退化了」就删掉后缀判据**：保留它的理由是**更准确的错误信息**
    （「放错层了」而不是「锚点对不上」），不是它挡住了别的判据挡不住的东西。
    ⚠️ 也别为了让它「看起来有判别力」而伪造一个非法的 universe——那会同时踩到
    `_validate_source_snapshot` 的后缀判据，测的就不是这一条了。

    （`source_snapshot.universe` 那一侧的同名判据**有永久专属档**，见
    `test_universe_code_suffix_must_match_its_layer`——它把 pool_order 与 files
    清空，好让交叉核对够不着。）
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            pool_order={"SH": [{"code": "000001.SZ", "universe_idx": 0}],
                        "SZ": [], "BJ": []}))


def test_pool_order_duplicate_code_within_a_layer_is_rejected():
    """⭐ 层内 code 唯一：同一只股出现两次会让下游重复消费。

    ⚠️⚠️ **构造要点**（2026-08-25 全量重跑时发现）：两条重复项必须**各自指向
    自己在 universe 里的真实位置**，否则 **Task 8 加的交叉核对会兜底**——
    原构造的第二条写 `universe_idx: 1`，而 `universe["SH"][1]` 是 `"600004.SH"`，
    交叉核对先把它拒了，唯一性判据**从未被求值**。
    （本条在 Task 7 交付时是真档；Task 8 加了交叉核对之后被掩盖——
    **判据的判别力不是永久属性**。）

    故这里让 `universe["SH"]` 本身含重复项，两条各指其一：交叉核对**都通过**，
    只剩唯一性判据能拒。

    判别力：删掉 `code not in seen_codes` 那条，本条必红。
    """
    base = _valid_manifest()
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            source_snapshot={
                "export_log_sha256": base["source_snapshot"]["export_log_sha256"],
                "universe": {"SH": ["600000.SH", "600000.SH"], "SZ": [], "BJ": []}},
            pool_order={"SH": [{"code": "600000.SH", "universe_idx": 0},
                               {"code": "600000.SH", "universe_idx": 1}],
                        "SZ": [], "BJ": []},
            cursor={"SH": 2, "SZ": 0, "BJ": 0},
            files=[_file_rec("600000.SH", "浦发银行", "1m"),
                   _file_rec("600000.SH", "浦发银行", "daily")]))


def test_pool_order_duplicate_universe_idx_within_a_layer_is_rejected():
    """⭐ 层内 universe_idx 也必须唯一 —— 与 code 唯一是**两条**判据。

    判别力：只查 code 唯一的实现会放行本档（两个不同 code 指向同一下标），
    而那意味着锚点坏了。删掉 idx 唯一那条，本条必红。

    ⚠️⚠️ **本条的判别力也「有时序」，但与上面那条不同——它无法用同样的手法修**
    （2026-08-26 全量变异重跑时发现，控制者与实施者共同核实）：

    · **Task 8 落地之前**：删掉 idx 唯一判据，本条真的会红。
    · **Task 8 落地之后**（交叉核对 `universe[mk][idx] == code`）：本条已
      **不可逆地退化为等价变异**——且**证明为数学上不可能绕开**，不是构造
      技巧不够：第一条记录 `{code0, idx}` 要想在**未变异**的实现下走到
      「第二条」的唯一性判据，它自己必须先通过交叉核对，即
      `universe[mk][idx] == code0`；第二条记录若真的换成不同的 `code1 ≠ code0`
      却复用同一个 `idx`，它的交叉核对算的是同一个 `universe[mk][idx]`——
      已经被第一条锁定等于 `code0`，不可能同时又等于 `code1`。于是不论
      idx 唯一判据在不在，第二条都会被交叉核对拒——**与「层内 code 唯一」
      能靠 `universe` 里放重复值来绕开不同**：那条的两个下标各自独立、互不
      锁定同一个值；这条的两个下标**就是同一个**，同一个位置只能锁一个值。

    ⚠️ **别删这条判据、也别删这个测试**：它仍是产线上**真正先触发**的那一句
    （检查顺序上排在交叉核对之前），给出的错误信息也更准确（「在本层重复
    出现」而不是「锚点对不上」）——不删的理由与 M19
    （`test_pool_order_code_suffix_must_match_its_market_layer`）完全一致。
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            pool_order={"SH": [{"code": "600000.SH", "universe_idx": 0},
                               {"code": "600004.SH", "universe_idx": 0}],
                        "SZ": [], "BJ": []}))


def test_universe_idx_out_of_range_is_rejected():
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            pool_order={"SH": [{"code": "600000.SH", "universe_idx": 99}],
                        "SZ": [], "BJ": []}))


def test_negative_universe_idx_is_rejected():
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            pool_order={"SH": [{"code": "600000.SH", "universe_idx": -1}],
                        "SZ": [], "BJ": []}))


def test_negative_index_pointing_at_a_real_entry_is_still_rejected():
    """⭐ 只有「界内」判据够得到的档：负数下标 + code **恰好等于** `layer[-1]`。

    Python 的负数下标是合法索引，所以 `layer[-1]` 取得到最后一只股。
    此时交叉核对 `layer[idx] == code` **会通过**——挡住它的只有界内判据。

    （对比：`test_negative_universe_idx_is_rejected` 用的 code 与 `layer[-1]`
    不匹配，两条判据都会拒，因此它对界内判据**零判别力**——2026-08-25 控制者
    单独变异时发现：删掉界内判据后那一条仍绿。）

    ⚠️⚠️ **`files` 必须跟着 `pool_order` 一起改**（2026-08-25 全量重跑时发现）：
    只改 `pool_order` 的话，基座 `files` 里那两只股就成了「不属于任何 pooled 股的
    多余记录」——于是**变异掉界内判据之后，Task 9 才加的 `files` 判据会兜底**，
    测试仍红、变异什么都没证明。（本条在 Task 8 交付时是真档；Task 9 加了 `files`
    判据之后被掩盖——**判据的判别力不是永久属性**。）

    不挡住的后果：下游按 `universe_idx` 升序消费时 `-1` 排在最前，
    而它实际指向最后一只股 → **消费顺序静默错乱，且没有任何一处会报错**。

    判别力：删掉 `0 <= idx` 那半个条件，本条必红。
    """
    # 基座的 universe["SH"] 是 ["600000.SH", "600004.SH", "600006.SH"]
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            pool_order={"SH": [{"code": "600006.SH", "universe_idx": -1}],
                        "SZ": [], "BJ": []},
            files=[_file_rec("600006.SH", "申能股份", "1m"),
                   _file_rec("600006.SH", "申能股份", "daily")]))


def test_universe_idx_must_actually_point_at_that_code():
    """⭐ 交叉核对：下标合法、代码合法、后缀对层，但**指向的是另一只股**。

    ⚠️ **`files` 必须跟着 `pool_order` 一起给**（2026-08-26 整支评审实测发现）：
    若只改 `pool_order`、`files` 仍是基座那两只股，删掉交叉核对之后
    `000001.SZ` 的两条记录会变成「不属于任何 pooled 股的多余记录」，被
    Task 9 的 `files` 判据兜底拒绝——测试照样红，但红的不是交叉核对。

    判别力：删掉 `universe[mk][idx] == code` 那条，本条必红（且只有它会红）。
    一份手工编辑或版本错位的 manifest 正是这个形状。
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            pool_order={"SH": [{"code": "600000.SH", "universe_idx": 1}],  # [1] 是 600004.SH
                        "SZ": [], "BJ": []},
            files=[_file_rec("600000.SH", "浦发银行", "1m"),
                   _file_rec("600000.SH", "浦发银行", "daily")]))


def test_cursor_must_be_int_per_market():
    for bad in ({"SH": "1", "SZ": 1, "BJ": 0}, {"SH": 1.0, "SZ": 1, "BJ": 0},
                {"SH": True, "SZ": 1, "BJ": 0}):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(cursor=bad))


def test_cursor_out_of_range_is_rejected():
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(cursor={"SH": 4, "SZ": 1, "BJ": 0}))
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(cursor={"SH": -1, "SZ": 1, "BJ": 0}))


def test_cursor_equal_to_universe_length_is_the_legal_exhausted_state():
    """⭐ 上界是**闭**区间：取遍全层时 cursor == len(universe)，那是池穷尽
    这个合法终态，不是越界。

    判别力：把 `<= len` 写成 `< len`，本条必红——而那会让一次正常跑到池尽的
    staging 在下次启动时被判「账本非法」。
    """
    m = _valid_manifest(cursor={"SH": 3, "SZ": 2, "BJ": 1})   # 各层 len 分别是 3/2/1
    assert validate_manifest(m) == m


def test_each_pooled_stock_needs_exactly_two_file_records():
    m = _valid_manifest()
    m["files"] = [r for r in m["files"] if r["stock_code"] != "600000.SH"]
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_a_stock_with_two_records_of_the_same_period_is_rejected():
    """⭐ 只有本条够得到：条数对（2 条）、文件名都合规、code 与 period 都自洽，
    但周期集合是 {1m, 1m} 而不是 {1m, daily}。

    ⚠️ **构造要点**（2026-08-25 控制者变异时发现原构造有缺陷）：重复的那条必须
    用一个**文件名仍然合规**的路径——原构造把 `.csv` 换成 `_2.csv`，那个名字
    过不了 `parse_qmt_filename`，于是它在**文件名判据**就被拒了，
    **根本走不到**周期集合这条判据（变异证实：只数条数的实现下本条仍绿）。
    改名（`浦发银行` → `浦发银行B`）即可让文件名合规而周期重复。

    判别力：把 `got == sorted(PERIODS)` 改成 `len(got) == 2`，本条必红。
    """
    m = _valid_manifest()
    dup = _file_rec("600000.SH", "浦发银行B", "1m")     # 文件名合规，周期与既有那条重复
    m["files"] = [r for r in m["files"]
                  if not (r["stock_code"] == "600000.SH" and r["period"] == "daily")] + [dup]
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_extra_file_record_not_belonging_to_any_pooled_stock_is_rejected():
    m = _valid_manifest()
    m["files"] = m["files"] + [_file_rec("600004.SH", "上海机场", "1m")]
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_file_relative_path_must_stay_inside_staging():
    for bad in ("../outside.csv", "/etc/passwd", "a/../../x.csv", "./x.csv", ""):
        m = _valid_manifest()
        m["files"][0]["relative_path"] = bad
        _recompute_evidence(m)
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


@pytest.mark.parametrize("escaping", [
    "../1分钟K线_前复权/600000.SH_浦发银行_1分钟K线_前复权.csv",      # 上跳
    "/1分钟K线_前复权/600000.SH_浦发银行_1分钟K线_前复权.csv",       # 绝对路径
    "a/../../1分钟K线_前复权/600000.SH_浦发银行_1分钟K线_前复权.csv",  # 中段上跳
    "./1分钟K线_前复权/600000.SH_浦发银行_1分钟K线_前复权.csv",       # 当前目录
    "1分钟K线_前复权//600000.SH_浦发银行_1分钟K线_前复权.csv",        # 空分量
])
def test_escaping_path_with_a_valid_filename_is_still_rejected(escaping):
    """⭐⭐ 只有**路径判据**够得到的档：路径逃出 staging，但**末段文件名完全合规**。

    ⚠️ **为什么需要这一组**（2026-08-25 控制者变异 → 评审质疑 → 控制者再实测，三轮才定案）：
    `test_file_relative_path_must_stay_inside_staging` 的五个坏路径**对路径判据零判别力**，
    但**机理不是「路径判据没被求值」**——实测：真实实现下那五个**全部**由路径判据拒下，
    它确实在工作。真正的原因是**变异掉路径判据之后，文件名判据会兜底**：
    那五个路径的末段（`outside.csv` / `passwd` / `x.csv` / `""`）本身也不合规，
    于是绕过路径判据后它们仍会被 `parse_qmt_filename` 拒 → 测试**仍红** → 变异什么都没证明。

    本组的末段是 `600000.SH_浦发银行_1分钟K线_前复权.csv`，**完全合规**——
    绕过路径判据后**没有任何判据兜底**，测试才会变绿，判别力才落在路径判据上。

    ⚠️ **这条判据是防逃逸的防线**：绕过它，`../` 路径会被接受 → 下游按这个相对路径
    读文件 → **读到 staging 之外**；而全套指纹校验查的是「同一条路径读回来的字节」，
    **逃逸对它完全透明**，指纹会完美吻合。

    判别力：把 `split_relative_components(relpath)` 换成 `relpath.split("/")`，本组必红。
    """
    m = _valid_manifest()
    m["files"][0]["relative_path"] = escaping
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_file_name_must_parse_to_the_same_code_and_period():
    """⭐ 文件名解析出的 code/period 必须与记录里写的一致。

    判别力：删掉这条，「把 1m 的哈希绑到 daily 上」就静默通过——
    而校验的字节与导入器消费的字节从此不是同一批（R21-F3 原话）。
    """
    m = _valid_manifest()
    # 记录说自己是 daily，文件名却是 1 分钟线
    rec = next(r for r in m["files"]
               if r["stock_code"] == "600000.SH" and r["period"] == "daily")
    rec["relative_path"] = "日K线_前复权/600000.SH_浦发银行_1分钟K线_前复权.csv"
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_file_name_code_mismatch_is_rejected():
    m = _valid_manifest()
    m["files"][0]["relative_path"] = "1分钟K线_前复权/600004.SH_上海机场_1分钟K线_前复权.csv"
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_file_name_not_matching_qmt_rules_is_rejected():
    m = _valid_manifest()
    m["files"][0]["relative_path"] = "1分钟K线_前复权/随便一个名字.csv"
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_file_bytes_must_be_nonnegative_int():
    for bad in (-1, "1", 1.5, True, None):
        m = _valid_manifest()
        m["files"][0]["bytes"] = bad
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_file_sha256_must_be_hex64_lowercase():
    for bad in ("", "z" * 64, "A" * 64, "a" * 63, 1):
        m = _valid_manifest()
        m["files"][0]["sha256"] = bad
        _recompute_evidence(m)
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_zero_byte_file_record_is_allowed():
    """正向档：bytes == 0 合法（一只 status=empty 的股导出 0 行的 CSV
    仍是一个真实存在、可被哈希的文件）。判据是「非负」，不是「正」。"""
    m = _valid_manifest()
    m["files"][0]["bytes"] = 0
    assert validate_manifest(m) == m


def test_empty_pool_with_empty_files_is_valid():
    """⭐ 正向档：一次刚起步、还没拷到任何股的 fetch。

    判据是「pool_order 里每只股恰好 2 条」，池为空时 files 也为空是合法的
    ——首份 manifest 就是这个形状（staged_export_log 先于任何 K 线落盘）。
    """
    m = _valid_manifest(
        pool_order={"SH": [], "SZ": [], "BJ": []},
        cursor={"SH": 0, "SZ": 0, "BJ": 0},
        files=[])
    assert validate_manifest(m) == m


def test_staged_export_log_requires_all_three_subkeys():
    for drop in ("relative_path", "bytes", "sha256"):
        m = _valid_manifest()
        del m["staged_export_log"][drop]
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_staged_export_log_path_must_stay_inside_staging():
    for bad in ("../export_log.csv", "/etc/passwd", ""):
        m = _valid_manifest()
        m["staged_export_log"]["relative_path"] = bad
        _recompute_evidence(m)
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_staged_export_log_sha256_must_equal_source_snapshot_sha256():
    """⭐ 只有本条够得到：两处都是合法的 sha256，但**互不相等**。

    同一份字节在 manifest 里被记了两次（源那一份 / staged 那一份），
    不等即 manifest **自相矛盾**（R38-F1）。

    判别力：删掉这条相等判据，本条必红（且只有它会红）。
    """
    m = _valid_manifest()
    m["staged_export_log"]["sha256"] = _sha("another")
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_staged_export_log_bytes_must_be_nonnegative_int():
    for bad in (-1, "1", 1.5, True):
        m = _valid_manifest()
        m["staged_export_log"]["bytes"] = bad
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_staged_export_log_zero_bytes_is_allowed():
    """⭐ 正向档：`bytes == 0` 合法——判据是「非负」，不是「正」。

    ⚠️ **这条钉的是职责边界**：零字节的 `export_log.csv` 确实是坏数据，但拒绝它是
    **解析阶段**的事（设计文档 §5：缺失/零字节/截断 → `parse_export_log` 抛
    `QmtSchemaError` 干净拒绝）。一份记着 `bytes=0` + 空文件指纹的账本，
    **结构上是自洽的**——账本的结构校验**不替内容校验做决定**。

    （对称性：`files` 那边已有 `test_zero_byte_file_record_is_allowed`；
    此处此前缺档——2026-08-25 控制者变异时发现：把 `>= 0` 改成 `> 0` 全绿。）

    判别力：把 `sel["bytes"] >= 0` 改成 `> 0`，本条必红。
    """
    m = _valid_manifest()
    m["staged_export_log"]["bytes"] = 0
    assert validate_manifest(m) is m


def _fatal(kind="staging_path_escape"):
    return {"kind": kind, "relative_path": "1分钟K线_前复权/x.csv",
            "component": "1分钟K线_前复权", "errno": "ENOTDIR"}


def test_manifest_without_stopped_reason_is_valid():
    """正向档：绝大多数 manifest 没有这个字段（它是可选的）。"""
    m = _valid_manifest()
    assert "stopped_reason" not in m
    assert validate_manifest(m) == m


def test_max_bytes_needs_no_fatal_error():
    """正向档：干净的配额触顶**不**带 fetch_fatal_error（R44-F2：
    容量停止是可恢复的、与数据无关的终止条件，不是信任边界破坏）。"""
    m = _valid_manifest(stopped_reason="max_bytes")
    assert validate_manifest(m) == m


def test_stopped_reason_outside_the_closed_enum_is_rejected():
    for bad in ("disk_full", "", "MAX_BYTES", None, 1):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(stopped_reason=bad))


@pytest.mark.parametrize("reason", [
    "source_path_escape", "staging_path_escape", "staging_recheck_failed",
])
def test_escape_reasons_require_a_fetch_fatal_error(reason):
    """⭐ 三个值都必须同时带 fetch_fatal_error。

    判别力：只对两个 escape 要求而漏掉 staging_recheck_failed（原 spec 只写了
    两个值，O4-F3 才补的第四值），本条第三个参数档必红。
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(stopped_reason=reason))


@pytest.mark.parametrize("reason", [
    "source_path_escape", "staging_path_escape", "staging_recheck_failed",
])
def test_escape_reasons_pass_with_a_well_formed_fatal_error(reason):
    """正向放行档：带上合规的四字段就必须通过。

    没有这一条，一个「凡带 stopped_reason 就拒」的实现也能让上一条绿。

    ⚠️ 2026-08-30 订正：原本三档都固定用 `_fatal()`（kind 恒为
    `staging_path_escape`），于是 `source_path_escape` 那一档其实是一份
    **reason 与 kind 不配对**的 manifest —— 它当时能过，正说明读侧漏了
    那条配对判据（codex R2 [high]）。现在 escape 两档各自带同名 kind；
    `staging_recheck_failed` 仍固定用默认 kind，因为它正是 spec 明写的
    **唯一**一种合法解耦（O4-F3），这一档同时充当那条解耦的正向放行档。
    """
    kind = reason if reason in FATAL_KINDS else "staging_path_escape"
    m = _valid_manifest(stopped_reason=reason, fetch_fatal_error=_fatal(kind=kind))
    assert validate_manifest(m) == m


def test_fetch_fatal_error_needs_exactly_four_fields():
    """⭐ 四字段（R94-F2）：写侧曾写三字段、读侧要四字段 → 一个合规的写者
    产出的 manifest 会被读者判 FAIL_MANIFEST_INVALID，于是一次信任边界破坏
    被报成「manifest 畸形」，恢复指引整个走错。"""
    for drop in ("kind", "relative_path", "component", "errno"):
        bad = _fatal()
        del bad[drop]
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                stopped_reason="staging_path_escape", fetch_fatal_error=bad))


def test_fatal_kind_must_be_in_the_kind_enum():
    """⚠️ 2026-08-30 订正 stopped_reason：原本用 `staging_path_escape`，
    而新增的「escape 类 reason 必须等于 kind」配对判据会**抢先**把这些坏 kind
    接住 → 本档对 kind 枚举本身**零判别力**（机械 sweep 实测：把枚举判据变空后
    本档仍绿）。改用 `staging_recheck_failed` —— 那是配对判据**够不着**的
    唯一一种合法 reason（O4-F3 的解耦档），于是只剩枚举判据能拒它。
    """
    for bad in ("staging_recheck_failed", "max_bytes", "whatever", ""):
        f = _fatal()
        f["kind"] = bad
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                stopped_reason="staging_recheck_failed", fetch_fatal_error=f))


def test_fatal_errno_must_be_eloop_or_enotdir():
    for bad in ("EACCES", "ENOENT", 20, ""):
        f = _fatal()
        f["errno"] = bad
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                stopped_reason="staging_path_escape", fetch_fatal_error=f))


def test_fatal_kind_is_decoupled_from_stopped_reason():
    """⭐⭐ O4-F3 的核心：`kind` 记首次逃逸类型，`stopped_reason` 记本次为何停。
    「保留 fatal + 换 stopped_reason」是复校失败那一档的**唯一**表达方式。

    判别力：把校验写成 `kind == stopped_reason`，本条必红——而那会让
    「修好后重跑、复校没过」这一档**结构上不可表达**，实施者无路可走。
    """
    m = _valid_manifest(stopped_reason="staging_recheck_failed",
                        fetch_fatal_error=_fatal(kind="staging_path_escape"))
    assert validate_manifest(m) == m


def test_fetch_fatal_error_without_stopped_reason_is_rejected():
    """反向配对：有 fatal 却没有 stopped_reason 说明写侧漏了一半。"""
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(fetch_fatal_error=_fatal()))


def test_max_bytes_with_a_retained_fatal_error_is_valid():
    """⭐ 正向档：Run1 撞 escape、Run2 触顶——**fatal 原样保留、escape 的
    stopped_reason 不得被覆盖**，本次触顶另记 stopped_reason_secondary（O4-F1）。

    这份形状必须**可读**，否则那条「不许被 max_bytes 洗白」的规则无处落地。
    """
    m = _valid_manifest(stopped_reason="staging_path_escape",
                        fetch_fatal_error=_fatal(),
                        stopped_reason_secondary="max_bytes")
    assert validate_manifest(m) == m


def test_stopped_reason_secondary_only_allows_max_bytes():
    for bad in ("staging_path_escape", "", None, 1):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                stopped_reason="staging_path_escape",
                fetch_fatal_error=_fatal(),
                stopped_reason_secondary=bad))


def test_explicit_null_fetch_fatal_error_is_rejected():
    """⭐ 只有形状判据够得到：显式写了 `fetch_fatal_error: null`，且**没有** stopped_reason。

    「键写了却写成 null」与「键根本不存在」是**两件事**：前者是一份写坏了的账本，
    必须拒；后者是绝大多数正常账本的样子，必须放行。用 `.get() is not None`
    判断会把两者混成一档而放行。

    ⚠️ 注意与 `..._with_a_retained_fatal_error` 那档的区别：那一档有 escape 类
    stopped_reason，`null` 会被**配对判据**接住；本档**没有** stopped_reason，
    配对判据够不着，**只有形状判据能拒它**（2026-08-25 控制者实测：修正前放行）。

    判别力：把 `if "fetch_fatal_error" in payload:` 改回 `if fatal is not None:`，本条必红。
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(fetch_fatal_error=None))


def test_absent_lifecycle_keys_are_still_valid():
    """⭐ 对称的正向档：三个生命周期键**都不存在**时必须放行。

    没有这一条，一个「凡是这三个键沾边就拒」的实现也能让上面那些否定档全绿——
    而绝大多数正常账本正是三个键都没有的样子。
    """
    m = _valid_manifest()
    assert "stopped_reason" not in m
    assert "fetch_fatal_error" not in m
    assert "stopped_reason_secondary" not in m
    assert validate_manifest(m) == m


_GMT = "@GMT-2026.08.24-04.00.00"


def _evidence(level, *, n_pass, files_verified, agg, agree=None, mount=None):
    ev = {"level": level, "passes": [
        {"pass": i + 1, "files_verified": files_verified, "aggregate_sha256": agg,
         "completed_at": f"2026-08-24T12:0{i}:00+08:00"} for i in range(n_pass)]}
    if agree is not None:
        ev["passes_agree"] = agree
    if mount is not None:
        ev["mount_check"] = mount
    return ev


def _agg_of(m):
    return aggregate_sha256(manifest_members(m))


def test_source_verification_must_be_one_of_three_levels():
    for bad in ("FULL", "verified", "", None, 1):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(source_verification=bad))


def test_source_verification_outside_the_three_levels_is_rejected():
    """⭐ 只有顶层枚举判据够得到：一个不在三级之内的取值。

    ⚠️ 上一条 `test_source_verification_must_be_one_of_three_levels` 对本判据
    **零判别力**（2026-08-26 整支评审实测证实：删掉顶层枚举判据，那条测试
    仍然全绿）——因为它没有同步改 `source_verification_evidence.level`（后者
    由 `_valid_manifest` 自动补成固定的 `"full"`）。顶层枚举判据一旦被删，
    执行会继续往下走到「evidence.level 与 source_verification 必须一致」
    那条，`"full" != "FULL"`（或其余坏值）照样让它拒——红的不是被测的那条。

    本条把 `evidence.level` 也**同设为同一个坏值**，一致性判据因此够不着，
    只剩顶层枚举判据能拒。

    ⚠️ **不挡住的后果比「拒绝一份坏账本」严重**：判据被删后
    `_PASSES_REQUIRED[level]` 会抛裸 `KeyError`——英文报错、无中文指引，
    且**逃出 `ManifestInvalidError` 家族**，调用方的 fail-closed 分支够不着它，
    变成未捕获崩溃而不是干净的「账本非法」。

    判别力：删掉 `level in VERIFICATION_LEVELS` 那条，本条必红（届时抛的是
    未被捕获的 `KeyError`，不是 `ManifestInvalidError`）。
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            source_verification="banana",
            source_verification_evidence={"level": "banana", "passes": []}))


def test_full_level_requires_operator_attestation():
    """⭐ R15-F2：一个光秃秃的 "full" 字符串不许换来出货级标签。"""
    m = _valid_manifest()
    del m["operator_attestation"]
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_full_level_attestation_must_be_true_and_timestamped():
    for bad in ({"no_export_window": False, "recorded_at": "t"},
                {"no_export_window": True},
                {"no_export_window": True, "recorded_at": ""},
                {"recorded_at": "t"}):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(operator_attestation=bad))


def test_snapshot_level_requires_a_well_formed_gmt_token():
    base = _valid_manifest()
    agg = _agg_of(base)
    n = len(base["files"]) + 1
    for token in (None, "", "@GMT-2026.8.24-4.0.0", "2026.08.24", "@GMT-xxxx"):
        snap = {"export_log_sha256": base["source_snapshot"]["export_log_sha256"],
                "universe": base["source_snapshot"]["universe"]}
        if token is not None:
            snap["gmt_token"] = token
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                source_snapshot=snap,
                source_verification="snapshot",
                source_verification_evidence=_evidence(
                    "snapshot", n_pass=1, files_verified=n, agg=agg,
                    mount={"gmt_token": _GMT, "verified_against_mount": True})))


def test_snapshot_level_passes_with_a_valid_token():
    """正向放行档。"""
    base = _valid_manifest()
    snap = dict(base["source_snapshot"], gmt_token=_GMT)
    m = _valid_manifest(
        source_snapshot=snap,
        source_verification="snapshot",
        source_verification_evidence=_evidence(
            "snapshot", n_pass=1, files_verified=len(base["files"]) + 1,
            agg=_agg_of(base),
            mount={"gmt_token": _GMT, "verified_against_mount": True}))
    assert validate_manifest(m) == m


def test_trailing_newline_after_sha256_or_gmt_token_is_rejected():
    """⭐ M3：`_SHA256_RE` 与 `_GMT_TOKEN_RE` 都必须用 `\\Z` 收尾，不是 `$`——
    不加 `re.MULTILINE` 时 `$` 仍会容忍**恰好一个尾随换行**（匹配到那个换行
    之前的位置，不要求那是字符串真正的末尾），于是 `sha256 + "\\n"` 与
    `"@GMT-...\\n"` 都会被当成合法值放行（2026-08-26 整支评审实测证实）。

    ⚠️ **`_STOCK_CODE_RE` 的同一个问题未在此处配档**（2026-08-26 逐个 call
    site 实测确认为等价变异）：股票代码在三处（`pool_order[mk][i].code` /
    `source_snapshot.universe[mk][i]` / `files[i].stock_code`）都伴随一条
    **字面量**判据（`.endswith("." + mk)`，或与文件名解析出的 code 相等）。
    要触发 `$` 的尾随换行豁免，字符串必须以 `"\\n"` 结尾；而这样的字符串
    **不可能同时**字面量地以 `.SH`/`.SZ`/`.BJ` 结尾、或等于解析出的 code——
    三处都会先被那条字面量判据拦下（已用真实变异逐一验证：三处的判据被
    弱化回 `$` 之后，测试全部仍红，红的都是那条字面量判据而不是正则本身）。
    故对股票代码而言，`\\Z` 是**防御性冗余**，不是本条能证明的独立判据；
    源码里那半个改动仍然做了（按判据本身穷尽），只是没有配到只有它才够得着
    的档。

    判别力：把 `_SHA256_RE` 或 `_GMT_TOKEN_RE` 的 `\\Z` 换回 `$`，本条对应的
    那一半必红。
    """
    # sha256：files[i].sha256 尾随一个换行——这一处除了正则判据本身没有任何
    # 字面量判据兜底（不像 staged_export_log.sha256 那样还要与另一处相等）。
    m = _valid_manifest()
    m["files"][0]["sha256"] = m["files"][0]["sha256"] + "\n"
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)

    # GMT token：source_snapshot.gmt_token 尾随一个换行。
    base = _valid_manifest()
    n, agg = len(base["files"]) + 1, _agg_of(base)
    snap = dict(base["source_snapshot"], gmt_token=_GMT + "\n")
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            source_snapshot=snap,
            source_verification="snapshot",
            source_verification_evidence=_evidence(
                "snapshot", n_pass=1, files_verified=n, agg=agg,
                mount={"gmt_token": _GMT, "verified_against_mount": True})))


def test_partial_level_needs_no_inputs_at_all():
    """正向放行档：partial 什么都不需要（它什么都没证明）。"""
    m = _valid_manifest(
        source_verification="partial",
        source_verification_evidence={"level": "partial", "passes": []})
    del m["operator_attestation"]
    assert validate_manifest(m) == m


def test_evidence_level_must_match_source_verification():
    base = _valid_manifest()
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            source_verification_evidence=_evidence(
                "snapshot", n_pass=2, files_verified=len(base["files"]) + 1,
                agg=_agg_of(base), agree=True)))


def test_full_level_requires_exactly_two_passes():
    base = _valid_manifest()
    n, agg = len(base["files"]) + 1, _agg_of(base)
    for k in (0, 1, 3):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                source_verification_evidence=_evidence(
                    "full", n_pass=k, files_verified=n, agg=agg, agree=True)))


def test_full_level_requires_passes_agree_true():
    base = _valid_manifest()
    n, agg = len(base["files"]) + 1, _agg_of(base)
    for agree in (False, None, "true"):
        ev = _evidence("full", n_pass=2, files_verified=n, agg=agg)
        if agree is not None:
            ev["passes_agree"] = agree
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(source_verification_evidence=ev))


def test_full_level_rejects_two_passes_with_different_aggregates():
    """两趟都在、`passes_agree` 写着 true，但两趟的聚合摘要**不等**。

    ⚠️⚠️ **本条实际拒它的是「聚合与重算相符」那条，不是「两趟相等」**
    （2026-08-25 控制者单独变异发现）：把 pass2 的聚合改成别的值之后，它在
    **循环内**就被 `p["aggregate_sha256"] == expect_agg` 拒了，**根本走不到**
    循环后的 `aggs[0] == aggs[1]`。

    真正钉住「聚合与重算相符」的是
    `test_aggregate_must_match_recomputation_from_manifests_own_records`；
    本条与它判别力重叠，保留是因为它描述的**场景**（passes_agree 在撒谎）
    对读者有意义。
    """
    base = _valid_manifest()
    n, agg = len(base["files"]) + 1, _agg_of(base)
    ev = _evidence("full", n_pass=2, files_verified=n, agg=agg, agree=True)
    ev["passes"][1]["aggregate_sha256"] = _sha("different")
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(source_verification_evidence=ev))


def test_snapshot_level_requires_exactly_one_pass_and_a_verified_mount_check():
    base = _valid_manifest()
    snap = dict(base["source_snapshot"], gmt_token=_GMT)
    n, agg = len(base["files"]) + 1, _agg_of(base)
    ok_mount = {"gmt_token": _GMT, "verified_against_mount": True}
    for ev in (
        _evidence("snapshot", n_pass=2, files_verified=n, agg=agg, mount=ok_mount),
        _evidence("snapshot", n_pass=1, files_verified=n, agg=agg),           # 缺 mount_check
        _evidence("snapshot", n_pass=1, files_verified=n, agg=agg,
                  mount={"gmt_token": _GMT, "verified_against_mount": False}),
    ):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                source_snapshot=snap, source_verification="snapshot",
                source_verification_evidence=ev))


def test_files_verified_must_equal_len_files_plus_one():
    """⭐ O4-F13：是 2N+1 不是 2N。

    原文「已成功拷贝的文件数」的自然读法是 2N，与 O2-F12 写死的成员集合
    （files 每条 + staged_export_log 一条）互斥 —— **两边照哪个实现都会让
    另一边全红**。

    判别力：把判据写成 len(files)，本条必红。
    """
    base = _valid_manifest()
    agg = _agg_of(base)
    for wrong in (len(base["files"]), len(base["files"]) + 2, 0):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                source_verification_evidence=_evidence(
                    "full", n_pass=2, files_verified=wrong, agg=agg, agree=True)))


def test_aggregate_must_match_recomputation_from_manifests_own_records():
    """⭐ 存根里的聚合必须与「拿 manifest 自己记的逐文件 sha256 重算」逐字相符。

    判别力：删掉重算比对，一份自填聚合的 manifest 就静默通过。
    （它挡的是截断/版本错位/字段缺失；**挡不住**手工伪造——那由 pilot 自己
    读源来挣，R17-F2。）
    """
    base = _valid_manifest()
    n = len(base["files"]) + 1
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            source_verification_evidence=_evidence(
                "full", n_pass=2, files_verified=n, agg=_sha("forged"), agree=True)))


@pytest.mark.parametrize("pass_values", [
    pytest.param((1, 1), id="duplicate_identity"),
    pytest.param((2, 1), id="reversed_order"),
    pytest.param((None, 2), id="none"),
    pytest.param((True, False), id="boolean"),
    pytest.param((7, 9), id="out_of_range"),
    pytest.param(("一", "二"), id="chinese_string"),
])
def test_full_level_rejects_malformed_pass_numbers(pass_values):
    """codex R1 唯一一条 finding：循环内「四个键都要在」的 `for key in (...)`
    只校验 `passes[i]["pass"]` **键存在**，从不校验**取值**。控制者实测证实
    以下六种畸形存根在 full 级（要求恰两趟）下**全部被放行**：两趟都写
    `pass: 1`（重复身份）/ 次序颠倒 `[2, 1]` / `pass: None` / `pass: True`、
    `False`（布尔）/ 越界 `[7, 9]` / 字符串 `["一", "二"]`。

    这个字段的存在意义就是标明「这是第几趟」：spec 第 737-739 行把形状钉死
    为 `{"pass": 1, …}, {"pass": 2, …}`；一份两条都标 `pass 1` 的记录**不是**
    两趟连续复校的记录，却能冒充它（R16-F1：存根的作用正是证明「那两趟全量
    哈希校验真的跑过、且结果一致」）。

    ⚠️ 每档只改 `pass` 这一个键，`files_verified` / `aggregate_sha256` 仍取自
    `_evidence(...)` 算出的合法基线——不会被别的判据顺带拦下（自查纪律①）。
    新判据排在循环内「四个键都要在」之后、`files_verified` 比对之前
    （自查纪律②）：删掉它，执行会直接走到 `files_verified`/`aggregate_sha256`
    比对，而这两项本档都没弄坏，因此**不会**被别的判据顶上——本条对新判据
    有干净的判别力（自查纪律③见下面的变异验证）。

    断言到具体文案片段（`.pass = ` + `必须是整数`），不只断异常类型——本文件
    这个循环里还有 files_verified / aggregate_sha256 / completed_at 三条重叠
    判据，只断类型分不出红的是哪一条。
    """
    base = _valid_manifest()
    n, agg = len(base["files"]) + 1, _agg_of(base)
    ev = _evidence("full", n_pass=2, files_verified=n, agg=agg, agree=True)
    for i, val in enumerate(pass_values):
        ev["passes"][i]["pass"] = val
    with pytest.raises(ManifestInvalidError) as ei:
        validate_manifest(_valid_manifest(source_verification_evidence=ev))
    assert ".pass = " in ei.value.detail
    assert "必须是整数" in ei.value.detail


def test_valid_pass_numbers_are_accepted_at_snapshot_and_full_level():
    """⭐ 正向放行档：合法的 `[1]`（snapshot）与 `[1, 2]`（full）必须被放行。

    ⚠️ 不是可选的：本仓栽过「全是『拒了』的套件让一个恒抛的守卫处处像在
    工作」——上面那条否定档全红只能证明新判据**拒了**东西，不能证明它拒得
    对；必须另配一条证明它对合法输入**放行**。

    判别力：把新判据错写成恒假（例如 `p["pass"] == i + 2`），本条两个断言都
    必红——合法的 `[1]` / `[1, 2]` 会被误拒。
    """
    base = _valid_manifest()
    n, agg = len(base["files"]) + 1, _agg_of(base)

    m_full = _valid_manifest(
        source_verification_evidence=_evidence(
            "full", n_pass=2, files_verified=n, agg=agg, agree=True))
    assert validate_manifest(m_full) == m_full

    snap = dict(base["source_snapshot"], gmt_token=_GMT)
    m_snapshot = _valid_manifest(
        source_snapshot=snap, source_verification="snapshot",
        source_verification_evidence=_evidence(
            "snapshot", n_pass=1, files_verified=n, agg=agg,
            mount={"gmt_token": _GMT, "verified_against_mount": True}))
    assert validate_manifest(m_snapshot) == m_snapshot


def test_partial_evidence_is_always_readable_even_mid_crash():
    """⭐⭐ O4-F2：partial 级的 manifest **永远可读**。

    模拟「首次 fetch 拷到一半被 SIGKILL」：几百条 files 都在、**没有任何存根**
    （存根只能由批后的收尾复校产出）。若对 partial 也强制趟数/聚合一致性，
    读侧会 fail-closed 拒绝 → 而崩溃恢复明写在「读完并校验账本**之后**」→
    .inflight.json 回滚、幂等四象限、按股事务**一条都执行不到**，
    代价是一棵 2 GiB 的 staging。

    判别力：把 partial 也纳入趟数/聚合校验，本条必红。
    """
    m = _valid_manifest(
        source_verification="partial",
        source_verification_evidence={"level": "partial", "passes": []})
    del m["operator_attestation"]
    assert validate_manifest(m) == m


def test_partial_evidence_still_needs_the_two_structural_keys():
    """partial 宽容的是**一致性**，不是**形状**：level 与 passes 仍必须在。"""
    for bad in ({}, {"level": "partial"}, {"passes": []}):
        m = _valid_manifest(source_verification="partial",
                            source_verification_evidence=bad)
        m.pop("operator_attestation", None)
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_partial_evidence_level_must_match_source_verification():
    """⭐ M12：`{"level": "full", "passes": []}` 这个取值两个结构键都在，
    命中的其实是「evidence.level 必须与 source_verification 一致」那条判据，
    不是上一条测的「结构键缺失」——单独拆出来，测试名才对得上它实际验的东西
    （2026-08-26 整支评审指出：原先混进上一条参数表里名不副实）。
    """
    m = _valid_manifest(source_verification="partial",
                        source_verification_evidence={"level": "full", "passes": []})
    m.pop("operator_attestation", None)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_partial_with_nonempty_passes_is_rejected():
    """per-stock 提交时的取值写死为 passes: []（O4-F2）。带着趟数的 partial
    说明写侧没按写死的取值来。"""
    base = _valid_manifest()
    m = _valid_manifest(
        source_verification="partial",
        source_verification_evidence=_evidence(
            "partial", n_pass=1, files_verified=len(base["files"]) + 1,
            agg=_agg_of(base)))
    m.pop("operator_attestation", None)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_unknown_top_level_keys_are_preserved_not_dropped():
    """⭐ O4-F10：读侧不认识的顶层键必须原样保留。

    这里用的正是 S3/S4 将要定义、而本片**不认识**的那些键——它们靠这条
    通道流转，因此**不需要 bump manifest_version**。

    判别力：把 validate_manifest 写成「只返回认识的键」（白名单投影），
    本条必红。
    """
    extras = {
        "failures": [{"stock_code": "600004.SH", "market": "SH",
                      "universe_idx": 1, "reason": "fetch_missing_file",
                      "attempts": 1}],
        "batches": [{"seed": "s-2026-08-24", "quota": {"SH": 120},
                     "added": ["600000.SH"]}],
        "inflight_rollbacks": {"1": 2},
        "quota": {"SH": 120, "SZ": 160, "BJ": 120},
        "committed_bytes": 4600000,
        "一个将来才会有的字段": {"任意": "结构"},
    }
    m = _valid_manifest(**extras)
    out = validate_manifest(m)
    for k, v in extras.items():
        assert out[k] == v, f"未知顶层键 {k!r} 被丢掉或改动了"


def test_validate_returns_the_same_object_not_a_copy():
    """返回的就是传进去的那个对象——避免调用方以为拿到了净化过的副本，
    转头把原对象写回磁盘。"""
    m = _valid_manifest()
    assert validate_manifest(m) is m


def _leaf_paths(obj, path=()):
    """枚举一份 manifest 里**每一个**可替换位置（含容器本身）。"""
    yield path
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from _leaf_paths(v, path + (k,))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from _leaf_paths(v, path + (i,))


def _set_at(obj, path, value):
    cur = obj
    for step in path[:-1]:
        cur = cur[step]
    cur[path[-1]] = value


def test_no_field_of_any_json_type_can_escape_as_a_raw_exception():
    """⭐⭐ **整族守卫**：把**任何**字段换成**任何** JSON 类型，读侧都必须给出
    `ManifestInvalidError` / `ManifestVersionError`，**绝不能抛原始异常**。

    codex R3 挖出的形态：`fetch_fatal_error.kind` 或 `errno` 被写成 list/dict 时，
    代码先做 `x in FATAL_KINDS`（frozenset）再验类型 → `TypeError: unhashable type`。
    于是一份被编辑坏的 manifest **不是**被 fail-closed 拒绝，而是让进程带着原始
    traceback 崩掉，`ManifestInvalidError.GUIDANCE` 那句「换新 staging + 新 seed
    重拉」一个字都印不出来——**守卫自己被它该抓的那种损坏弄坏了**（本仓已栽过
    同形态：机械检查器被损坏禁用了自身解析器 → 静默全绿）。

    ⚠️ **为什么写成整族扫描而不是 4 条点测**：控制者实测过 984 个组合，崩溃**恰好**
    只有那 4 个；但这个数字**会随字段增加而变化**。点测只钉住今天已知的 4 个，
    新字段照样能把这个洞重开。这条扫描对**将来新增的字段自动生效**。

    ⚠️ **防空转**：断言探测数有下限。若 `_leaf_paths` 哪天被改坏、只枚举出几个
    位置，这条测试会「零崩溃」通过而实际什么都没测——下限断言让它当场红。
    """
    bases = [
        _valid_manifest(),
        # ⚠️ kind 必须与 reason 相等，否则这个 base 自身即非法，
        # 新增的配对判据会**掩盖整条扫描**（上游判据掩盖下游档的老形态）。
        _valid_manifest(stopped_reason="source_path_escape",
                        fetch_fatal_error=_fatal(kind="source_path_escape")),
    ]
    for base in bases:
        _recompute_evidence(base)

    bad_values = {"list": [], "dict": {}, "null": None,
                  "int": 0, "str": "x", "bool": True}
    probed = 0
    escapes = []
    for base in bases:
        for path in list(_leaf_paths(base)):
            if not path:
                continue
            for name, value in bad_values.items():
                victim = copy.deepcopy(base)
                _set_at(victim, path, value)
                probed += 1
                try:
                    validate_manifest(victim)
                except (ManifestInvalidError, ManifestVersionError):
                    pass                      # 承诺的行为
                except Exception as exc:      # noqa: BLE001 —— 正是要抓这些
                    escapes.append(
                        f"{'.'.join(map(str, path))} = {name} → "
                        f"{type(exc).__name__}: {exc}")

    assert probed >= 900, (
        f"只探测了 {probed} 个组合（预期 900+）——_leaf_paths 可能被改坏了，"
        "这次运行对本判据零判别力")
    assert not escapes, (
        "以下字段的坏值逃出了 fail-closed，抛的是原始异常而不是 "
        "ManifestInvalidError：\n  " + "\n  ".join(escapes))


# ═════════════════════════════════════════════════════════════
# S2b Task 15：read_manifest —— 逐段无跟随读回并校验
# ═════════════════════════════════════════════════════════════
import fcntl
import os
import stat as _stat
import json as _json_rw

from qmt_fsroot import atomic_write_json, open_root, PathEscapeError
from qmt_manifest import read_manifest, lifecycle_snapshot, MANIFEST_NAME


def _staging(tmp_path, manifest=None, *, raw=None):
    """造一个 staging 目录并返回 `(path, stg_fd)`。调用方负责 `os.close`。"""
    d = tmp_path / "staging"
    d.mkdir()
    if raw is not None:
        (d / MANIFEST_NAME).write_text(raw, encoding="utf-8")
    elif manifest is not None:
        (d / MANIFEST_NAME).write_text(
            _json_rw.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    return d, open_root(str(d))


def test_read_manifest_round_trips_a_valid_one(tmp_path):
    """正向放行档。

    ⚠️ 每一族「全是拒了」的档都必须配一条正向放行档，否则一个**恒抛**的
    实现会让整族看起来都在工作（本仓栽过）。
    """
    m = _valid_manifest()
    _d, fd = _staging(tmp_path, m)
    try:
        assert read_manifest(fd) == m
    finally:
        os.close(fd)


def test_read_manifest_returns_none_when_absent(tmp_path):
    """⭐ 引导态：manifest 不存在 ≠ manifest 坏了。

    判别力：把「不存在」也抛成 ManifestInvalidError，本条必红——而那会让
    「崩在归属标记落盘与首份 manifest 之间」这一档无法与畸形区分，
    一棵本可继续初始化的 staging 变成人工才能清理的状态（R60-F3）。
    """
    _d, fd = _staging(tmp_path)
    try:
        assert read_manifest(fd) is None
    finally:
        os.close(fd)


def test_read_manifest_rejects_truncated_json(tmp_path):
    """⭐ 截断的 manifest 往往仍是合法 JSON 的**前缀片段**。

    静默消费它 = 把 manifest 损坏伪装成「候选就这么多」（R1-F4）。
    """
    good = _json_rw.dumps(_valid_manifest(), ensure_ascii=False)
    _d, fd = _staging(tmp_path, raw=good[: len(good) // 2])
    try:
        with pytest.raises(ManifestInvalidError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_read_manifest_rejects_empty_file(tmp_path):
    _d, fd = _staging(tmp_path, raw="")
    try:
        with pytest.raises(ManifestInvalidError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_read_manifest_rejects_a_json_array(tmp_path):
    """合法 JSON 但不是对象。"""
    _d, fd = _staging(tmp_path, raw="[1,2,3]")
    try:
        with pytest.raises(ManifestInvalidError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_read_manifest_rejects_oversized_file(tmp_path, monkeypatch):
    """⭐ 不可信输入的大小上限（本片新增，非 spec 条款）：manifest 决定整棵
    staging 可不可信，读到 EOF 为止意味着一个被植入的几 GB 文件能把进程 OOM 掉，
    而不是得到一个干净的拒绝。与 S1 给归属标记设 `_MARKER_MAX_BYTES` 同源。

    判别力：删掉上限检查，本条必红。
    ⚠️ **本条区分不了「读中计数」与「只查 st_size 早拒」两种实现**（如实登记）：
    静态大文件两条路都拦得住。实现取**读中计数**——与 S1 逐字同规格，理由见
    `read_manifest` 的 docstring（`st_size` 是打开那一刻的快照，文件可以边读边长）。
    """
    import qmt_manifest as qm
    monkeypatch.setattr(qm, "_MANIFEST_MAX_BYTES", 100)
    _d, fd = _staging(tmp_path, _valid_manifest())      # 远超 100 字节
    try:
        with pytest.raises(ManifestInvalidError) as ei:
            read_manifest(fd)
        assert "过大" in str(ei.value)
    finally:
        os.close(fd)


def test_read_manifest_refuses_a_fifo_manifest_without_hanging(tmp_path):
    """⭐⭐ manifest 被换成 FIFO —— 必须**当场拒绝**，绝不能挂起。

    `open(O_RDONLY)` 打开 FIFO 会**一直阻塞等写入方**。本机实测（S2b Step 0
    M-S0-c）：去掉 `O_NONBLOCK` 后本条不是变红，而是 15 秒被闹钟杀掉、
    日志 0 字节——**工具永久挂起且不打印任何提示**，比崩溃更糟。
    这是「凡是本工具要打开的、可能被篡改的路径都必须经 open_regular_probe」
    的第四个执行点（S1 已有取锁 / 探测 / 读标记三个）。

    判别力：把 `open_regular_probe` 换回裸 `open_under(flags=O_RDONLY)`，
    本条**挂死**（而不是变红）。
    """
    d = tmp_path / "staging"
    d.mkdir()
    os.mkfifo(str(d / MANIFEST_NAME))
    fd = open_root(str(d))
    try:
        with pytest.raises(ManifestInvalidError) as ei:
            read_manifest(fd)
        assert "普通文件" in str(ei.value)
    finally:
        os.close(fd)


def test_read_manifest_refuses_a_directory_manifest(tmp_path):
    """⭐ manifest 被换成**目录** —— 必须得到干净的 ManifestInvalidError。

    本机实测：目录能被 `O_RDONLY|O_NOFOLLOW` 成功打开（`st_size=64`），
    随后 `os.read` 抛原始 `IsADirectoryError`——一份自称 fail-closed 的读侧
    校验于是带着原始 traceback 崩掉，`ManifestInvalidError` 那句恢复指引
    一个字都印不出来。**守卫自己被它该抓的那种损坏弄坏了**（S2-F9 同族，
    只是这次坏的不是 JSON 值的类型，而是磁盘对象的类型）。

    判别力：删掉 `S_ISREG` 检查，本条必红（抛 IsADirectoryError 而非本模块异常）。
    """
    d = tmp_path / "staging"
    d.mkdir()
    (d / MANIFEST_NAME).mkdir()
    fd = open_root(str(d))
    try:
        with pytest.raises(ManifestInvalidError) as ei:
            read_manifest(fd)
        assert "普通文件" in str(ei.value)
    finally:
        os.close(fd)


def test_read_manifest_lets_path_escape_bubble_up(tmp_path):
    """⭐ manifest 被换成指向 staging 之外的符号链接 → `open_under` 逐段
    `O_NOFOLLOW` 撞 ELOOP → **PathEscapeError 原样上浮**，不被降级成
    「manifest 畸形」。

    判别力：把 open_under 的异常 catch 成 ManifestInvalidError，本条必红——
    而那会把一次**信任边界破坏**报成「账本坏了」，恢复指引整个走错
    （R94-F2 同族）。处置（stopped_reason: staging_path_escape + rc≠0）由 S4/S5 负责。
    """
    outside = tmp_path / "outside.json"
    outside.write_text(_json_rw.dumps(_valid_manifest(), ensure_ascii=False),
                       encoding="utf-8")
    d = tmp_path / "staging"
    d.mkdir()
    (d / MANIFEST_NAME).symlink_to(outside)
    fd = open_root(str(d))
    try:
        with pytest.raises(PathEscapeError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_read_manifest_propagates_version_error_not_invalid(tmp_path):
    """版本三档必须原样穿过 read_manifest（两族异常不许在这一层被抹平）。"""
    _d, fd = _staging(tmp_path, _valid_manifest(manifest_version=99))
    try:
        with pytest.raises(ManifestVersionError) as ei:
            read_manifest(fd)
        assert ei.value.kind == "newer"
    finally:
        os.close(fd)


def test_lifecycle_snapshot_captures_only_the_three_keys():
    m = _valid_manifest(stopped_reason="staging_path_escape",
                        fetch_fatal_error=_fatal(),
                        stopped_reason_secondary="max_bytes")
    snap = lifecycle_snapshot(m)
    assert set(snap) == {"stopped_reason", "fetch_fatal_error",
                         "stopped_reason_secondary"}


def test_lifecycle_snapshot_of_a_clean_manifest_is_empty():
    assert lifecycle_snapshot(_valid_manifest()) == {}


# ═════════════════════════════════════════════════════════════
# S2b Task 16：commit_stock —— per-stock 提交够不到生命周期三字段
# ═════════════════════════════════════════════════════════════
from qmt_manifest import commit_stock


def _fcntl_cmd_spy(monkeypatch) -> list:
    """记录本次经过 `fcntl.fcntl` 的所有 cmd（用于证明走没走 F_FULLFSYNC）。"""
    calls = []
    real = fcntl.fcntl
    monkeypatch.setattr(
        fcntl, "fcntl",
        lambda fd, cmd, *a: (calls.append(cmd), real(fd, cmd, *a))[1],
    )
    return calls



def _expect(fd):
    """测试便利：就地取一份反映**当前**磁盘状态的运行凭据。

    ⚠️ 只用于**不针对凭据比对本身**的档；针对它的档要显式在正确的时刻
    `begin_run(fd)` 取凭据，否则本帮手会让那些档恒真。
    """
    return begin_run(fd)


def test_commit_stock_writes_a_readable_manifest(tmp_path):
    """正向放行档：写出去的必须读得回来。"""
    m = _valid_manifest()
    _d, fd = _staging(tmp_path)
    try:
        written = commit_stock(fd, m, ledger=_expect(fd))
        # ⚠️ 比对**返回的那份**而不是入参：per-stock 提交会把 source_verification
        # 写死成 partial（spec §4.5:785，O4-F2），故与入参本就不同。
        assert read_manifest(fd) == written
        assert written["source_verification"] == "partial"
    finally:
        os.close(fd)


def test_commit_stock_cannot_change_lifecycle_fields(tmp_path):
    """⭐⭐ 核心不变量：即使调用方**故意**改了内存里的三个字段，
    磁盘上写出去的仍是 lifecycle 快照里的值。

    判别力：把实现写成 `atomic_write_json(fd, NAME, manifest)`（直接写入参），
    本条必红。这就是 spec §9-3s 说的「使规则可机械检验」——不是靠实施者记得别改。
    """
    prev = {"stopped_reason": "staging_path_escape",
            "fetch_fatal_error": _fatal()}
    poisoned = _valid_manifest(**prev)

    # 调用方「不小心」把 fatal 洗掉了
    del poisoned["fetch_fatal_error"]
    poisoned["stopped_reason"] = "max_bytes"

    _d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, _valid_manifest(**prev))       # 磁盘上是上一次留下的真相
        commit_stock(fd, poisoned, ledger=_expect(fd))
        on_disk = read_manifest(fd)
        assert on_disk["stopped_reason"] == "staging_path_escape"
        assert on_disk["fetch_fatal_error"] == _fatal()
    finally:
        os.close(fd)


def test_commit_stock_cannot_invent_lifecycle_fields(tmp_path):
    """反向档：一份**干净的** manifest，调用方硬塞一个 stopped_reason 进去 ——
    磁盘上必须仍然干净。

    没有这一条，「只在 lifecycle 有值时覆盖」的实现也能让上一条绿。
    **「剥」与「塞」是两个动作，各配一档，缺一会互相掩盖。**
    """
    poisoned = _valid_manifest(stopped_reason="max_bytes")
    _d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, poisoned, ledger=_expect(fd))       # 启动时磁盘上是干净的
        assert "stopped_reason" not in read_manifest(fd)
    finally:
        os.close(fd)


def test_commit_stock_preserves_unknown_top_level_keys(tmp_path):
    """S3/S4 的 failures / batches 等经 per-stock 提交流转，不得被剥掉（O4-F10）。"""
    m = _valid_manifest(failures=[{"stock_code": "600004.SH", "attempts": 1}],
                        committed_bytes=123)
    _d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, m, ledger=_expect(fd))
        on_disk = read_manifest(fd)
        assert on_disk["failures"] == [{"stock_code": "600004.SH", "attempts": 1}]
        assert on_disk["committed_bytes"] == 123
    finally:
        os.close(fd)


def test_commit_stock_uses_full_fsync(tmp_path, monkeypatch):
    """manifest 提交按 O4-F11 定案走 F_FULLFSYNC（断电在威胁模型之内）。

    判别力：把 `full_sync=True` 去掉，本条在 macOS 上必红。
    ⚠️ Linux 上 `full_fsync` 本就退回 `os.fsync`，该平台上无判别力（如实登记）。
    **按平台分支，绝不 skip**——本仓 CI 把任何 skip 判失败。
    """
    calls = _fcntl_cmd_spy(monkeypatch)
    fsynced = []
    real_fsync = os.fsync
    monkeypatch.setattr(os, "fsync", lambda fd: (fsynced.append(fd), real_fsync(fd))[1])
    _d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, _valid_manifest(), ledger=_expect(fd))
    finally:
        os.close(fd)
    if hasattr(fcntl, "F_FULLFSYNC"):
        assert fcntl.F_FULLFSYNC in calls
    else:
        assert fsynced


def test_commit_stock_is_atomic_leaving_no_tmp_files(tmp_path):
    """走 tmp → replace，落地后目录里不得有残留临时文件。"""
    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, _valid_manifest(), ledger=_expect(fd))
    finally:
        os.close(fd)
    assert sorted(p.name for p in d.iterdir()) == [MANIFEST_NAME]


# ═════════════════════════════════════════════════════════════
# S2b Task 17：收尾生命周期决策表（纯函数）
# ═════════════════════════════════════════════════════════════
from qmt_manifest import (
    FinalOutcome, clean_finish, max_bytes_stop, escape_stop,
    resolve_final_lifecycle, SkipVerifyWithEscapeError,
)


def _prev(fatal=None, reason=None, secondary=None):
    m = _valid_manifest()
    if reason is not None:
        m["stopped_reason"] = reason
    if fatal is not None:
        m["fetch_fatal_error"] = fatal
    if secondary is not None:
        m["stopped_reason_secondary"] = secondary
    return m


# ── 上次没有 fatal ────────────────────────────────────────────
def test_clean_finish_on_a_clean_manifest_clears_stopped_reason():
    assert resolve_final_lifecycle(_prev(), clean_finish()) == {}


def test_max_bytes_on_a_clean_manifest_records_max_bytes():
    assert resolve_final_lifecycle(_prev(), max_bytes_stop()) == {
        "stopped_reason": "max_bytes"}


def test_clean_finish_drops_a_stale_max_bytes_reason():
    """上次是干净的容量停止，这次跑完了 → 那条 stopped_reason 该消失。"""
    assert resolve_final_lifecycle(_prev(reason="max_bytes"), clean_finish()) == {}


# ── 本次撞 escape ─────────────────────────────────────────────
def test_escape_stop_overwrites_everything():
    """本次又撞 escape → 写入本次的四字段并清掉 secondary。

    ⚠️ 2026-08-30 订正方向：原本测的是 `staging → source`，而那恰恰是
    **唯一不许覆盖**的方向（codex R3 [high]：清除 staging 逃逸另需全量复校，
    用只需一道前提的 source 逃逸覆盖它 = 把那道门取消）。原样保留这条断言
    等于把一个被证明有洞的行为焊死成回归钉。
    改用 `source → staging`（升级方向，新状态更严），
    「覆盖」这件事照样被钉住；不许覆盖的那个方向由
    `test_a_source_escape_never_replaces_an_unresolved_staging_escape` 承担。
    """
    out = escape_stop(kind="staging_path_escape",
                      relative_path="1分钟K线_前复权/x.csv",
                      component="1分钟K线_前复权", errno="ENOTDIR")
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(kind="source_path_escape"), reason="source_path_escape",
              secondary="max_bytes"), out)
    assert got == {
        "stopped_reason": "staging_path_escape",
        "fetch_fatal_error": {"kind": "staging_path_escape",
                              "relative_path": "1分钟K线_前复权/x.csv",
                              "component": "1分钟K线_前复权", "errno": "ENOTDIR"},
    }
    assert "stopped_reason_secondary" not in got


# ── ⭐⭐ max_bytes 绝不洗白 escape（O4-F1）────────────────────
def test_max_bytes_never_launders_a_retained_escape():
    """⭐⭐ 本片最危险的一档：Run1 撞 escape，Run2 触顶。

    若把 stopped_reason 改写成 max_bytes，pilot 读到就放行，那 56 只从未被
    复校过的股照常消费——一次被证明破坏的信任边界被一次容量停止洗白成
    合法凭据。

    判别力：把实现写成「max_bytes 一律覆盖 stopped_reason」，本条必红。
    """
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape"), max_bytes_stop())
    assert got["stopped_reason"] == "staging_path_escape"      # 未被覆盖
    assert got["fetch_fatal_error"] == _fatal()                # 原样保留
    assert got["stopped_reason_secondary"] == "max_bytes"      # 只作诊断附注


# ── ⭐ 清除的谓词是「证明干净」而非「本次没撞」（O2-F7）───────
def test_clean_finish_without_revisiting_the_fatal_path_keeps_the_fatal():
    """⭐ 反例场景：上次 staging_path_escape 记了 56 只股，操作者重建目录，
    本次新股走**新建目录**全部成功、收尾复校只对**源**重算——
    从不回读那 56 只股。「本次没撞 escape」成立，但什么都没被证明干净。

    判别力：把清除条件写成「本次没撞 escape」，本条必红。
    """
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape"),
        clean_finish(revisited_fatal_path=False))
    assert got["fetch_fatal_error"] == _fatal()
    assert got["stopped_reason"] == "staging_path_escape"


def test_source_escape_clears_after_revisiting_that_path():
    """source_path_escape 只要前提①（重走过那条路径）——
    前提②（staging 全量复校）是 staging_path_escape **另加**的。"""
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(kind="source_path_escape"), reason="source_path_escape"),
        clean_finish(revisited_fatal_path=True))
    assert got == {}


def test_staging_escape_clears_only_after_a_passing_full_recheck():
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape"),
        clean_finish(revisited_fatal_path=True, staging_recheck="passed"))
    assert got == {}


def test_staging_escape_with_failing_recheck_keeps_fatal_and_renames_reason():
    """⭐ P2-F3：此前完全未定义 → 不可解 staging。
    保留 fatal、覆盖 stopped_reason 为 staging_recheck_failed。

    ⭐ 这一档也是 `kind` 与 `stopped_reason` **必须解耦**的唯一理由（O4-F3）：
    kind 仍是 staging_path_escape，reason 已换成 recheck_failed。
    """
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape"),
        clean_finish(revisited_fatal_path=True, staging_recheck="failed"))
    assert got["fetch_fatal_error"] == _fatal()
    assert got["fetch_fatal_error"]["kind"] == "staging_path_escape"
    assert got["stopped_reason"] == "staging_recheck_failed"


def test_a_failing_staging_recheck_blocks_clearing_even_for_a_source_escape():
    """⭐ 计划原文照抄会留一个洞（spec 对这一格没写）：上次是 source_path_escape、
    本次重走过那条路径，但操作者跑的 staging 全量复校**失败了** ——
    计划的分支次序（先判 kind 再判复校结果）会走到 `return {}`，
    **把 fatal 清掉、且把复校失败这个信号一起丢掉**，
    于是一棵已被证明与账本对不上的 staging 拿到干净标签。

    改法是把「复校失败」提到 kind 判断**之前**：复校失败一律不清除。
    双向都问过：①它只增加拒绝，畸形溜不过去；②被它拦下的唯一新情形就是
    「staging 复校失败却要清 fatal」，那不是合法状态。

    判别力：把这两句挪回 kind 判断之后，本条必红。
    """
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(kind="source_path_escape"), reason="source_path_escape"),
        clean_finish(revisited_fatal_path=True, staging_recheck="failed"))
    assert got["fetch_fatal_error"]["kind"] == "source_path_escape"
    assert got["stopped_reason"] == "staging_recheck_failed"


def test_skipping_the_recheck_on_a_staging_escape_manifest_is_refused():
    """⭐ P2-F3：--skip-existing-verify 与「manifest 带 escape 记录」互斥。

    不拒的话：第 1 次带 flag 跑清掉 fatal、标 partial（看似安全），
    第 2 次不带 flag 跑时收尾复校**只重算源、从不回读 staging** →
    **一棵被证明动过、且从未被复校过的 staging 拿到了出货级 full 标签**。

    判别力：把这一档实现成「当作 passed 清除」或「当作没重走过保留」，
    本条必红——前者是那条出货级假凭据，后者会让 fatal 永远清不掉。
    """
    with pytest.raises(SkipVerifyWithEscapeError):
        resolve_final_lifecycle(
            _prev(fatal=_fatal(), reason="staging_path_escape"),
            clean_finish(revisited_fatal_path=True, staging_recheck=None))


# ── 输入自相矛盾时不许产出非法 manifest ──────────────────────
def test_resolve_refuses_a_manifest_with_a_fatal_but_no_stopped_reason():
    """⭐ 写侧/读侧配对家族的第 N 次：读侧明写「有 fetch_fatal_error 却没有
    stopped_reason」非法。计划原文用 `if prev_reason is not None:` 兜着，
    于是这种自相矛盾的输入会**安静地产出一份读侧判非法的 manifest**
    ——一个合规的写者写出自己读不回来的账本。

    改为当场拒绝：真实路径上 prev 来自 read_manifest（已保证配对成立），
    故这一条不会误杀任何合法状态；而那两个 `is not None` 分支本身
    **没有任何测试钉得住**（S1：一道钉不住的守卫是负债不是资产）。

    判别力：把这条守卫删掉，本条必红。
    """
    for outcome in (clean_finish(), max_bytes_stop(),
                    clean_finish(revisited_fatal_path=True, staging_recheck="passed")):
        with pytest.raises(ManifestInvalidError, match="stopped_reason"):
            resolve_final_lifecycle({"fetch_fatal_error": _fatal()}, outcome)


# ── 构造期就排除非法组合 ──────────────────────────────────────
def test_escape_stop_rejects_a_kind_outside_the_enum():
    for bad in ("staging_recheck_failed", "max_bytes", ""):
        with pytest.raises(ValueError):
            escape_stop(kind=bad, relative_path="x", component="c", errno="ELOOP")


def test_escape_stop_rejects_an_errno_outside_the_enum():
    with pytest.raises(ValueError):
        escape_stop(kind="staging_path_escape", relative_path="x",
                    component="c", errno="EACCES")


def test_escape_stop_rejects_non_string_path_fields():
    """⭐ 「非法组合在构造期就被排除」这句话必须对**类型**也成立。

    只查 `not relative_path` 时，`relative_path=123` 一路通过构造、通过决策表，
    直到 `commit_final` 把它写上磁盘，才在**下一次读**时被判非法 ——
    又一次「一个合规的写者产出的 manifest 被读者判非法」。

    判别力：把 isinstance 检查删掉，本条必红。
    """
    for bad in (123, None, ["x"], {"a": 1}, True):
        with pytest.raises(ValueError):
            escape_stop(kind="staging_path_escape", relative_path=bad,
                        component="c", errno="ELOOP")
        with pytest.raises(ValueError):
            escape_stop(kind="staging_path_escape", relative_path="x",
                        component=bad, errno="ELOOP")


def test_clean_finish_rejects_an_unknown_recheck_verdict():
    for bad in ("ok", "PASSED", True):
        with pytest.raises(ValueError):
            clean_finish(revisited_fatal_path=True, staging_recheck=bad)


def test_final_outcome_rejects_a_kind_outside_the_three():
    """⭐ `FinalOutcome` 是公开的 dataclass，可以被直接构造。

    不校验 kind 的话，`FinalOutcome(kind="whatever")` 会一路落到「上次没 fatal
    → 返回 {}」那一支，被**静默当成干净跑完**——安静的那种错。

    判别力：删掉 __post_init__ 的校验，本条必红。
    """
    for bad in ("whatever", "", "Clean", None):
        with pytest.raises(ValueError):
            FinalOutcome(kind=bad)
    for good in ("clean", "max_bytes"):
        assert FinalOutcome(kind=good).kind == good


def test_max_bytes_stop_takes_no_clearing_preconditions():
    """⭐ 计划原文给 `max_bytes_stop` 也开了 revisited_fatal_path /
    staging_recheck 两个参数，而决策表对 max_bytes 这一支**根本不看它们**
    （O4-F1：容量停止一律不清除）。可传而被静默忽略 = 安静的错。

    正确做法是让它**不可表达**：这两个参数从签名里去掉。

    判别力：把参数加回去，本条必红。
    """
    with pytest.raises(TypeError):
        max_bytes_stop(revisited_fatal_path=True)
    with pytest.raises(TypeError):
        max_bytes_stop(staging_recheck="passed")


def test_every_resolved_state_passes_the_read_side_validator():
    """⭐⭐ 写侧/读侧配对钉：决策表吐出的**每一种**状态，塞回 manifest 后
    都必须能过读侧校验。

    这是 R94-F2 / O4-F13 / S2-F3 / S2-F4 那个家族（写侧形状与读侧要求不配对）
    的**机械防线**：任何一支的输出若读侧不认，一个合规的写者就会产出被自己
    判非法的 manifest。
    """
    cases = [
        (_prev(), clean_finish()),
        (_prev(), max_bytes_stop()),
        (_prev(reason="max_bytes"), clean_finish()),
        (_prev(fatal=_fatal(), reason="staging_path_escape"), max_bytes_stop()),
        (_prev(fatal=_fatal(), reason="staging_path_escape", secondary="max_bytes"),
         max_bytes_stop()),
        (_prev(fatal=_fatal(), reason="staging_path_escape"),
         clean_finish(revisited_fatal_path=False)),
        (_prev(fatal=_fatal(), reason="staging_path_escape"),
         clean_finish(revisited_fatal_path=True, staging_recheck="passed")),
        (_prev(fatal=_fatal(), reason="staging_path_escape"),
         clean_finish(revisited_fatal_path=True, staging_recheck="failed")),
        (_prev(fatal=_fatal(kind="source_path_escape"), reason="source_path_escape"),
         clean_finish(revisited_fatal_path=True)),
        (_prev(fatal=_fatal(kind="source_path_escape"), reason="source_path_escape"),
         clean_finish(revisited_fatal_path=True, staging_recheck="failed")),
        (_prev(), escape_stop(kind="staging_path_escape", relative_path="a/b.csv",
                              component="a", errno="ELOOP")),
        (_prev(fatal=_fatal(), reason="staging_path_escape", secondary="max_bytes"),
         escape_stop(kind="source_path_escape", relative_path="a/b.csv",
                     component="a", errno="ENOTDIR")),
    ]
    for prev, outcome in cases:
        new_lc = resolve_final_lifecycle(prev, outcome)
        merged = {k: v for k, v in prev.items() if k not in LIFECYCLE_KEYS}
        merged.update(new_lc)
        assert validate_manifest(merged) is merged


# ═════════════════════════════════════════════════════════════
# S2b Task 18：commit_final —— 唯一能动生命周期字段的落盘入口
# ═════════════════════════════════════════════════════════════
from qmt_manifest import RecoveryScope, RunLedger, begin_run, commit_final


def test_commit_final_writes_a_readable_manifest(tmp_path):
    """正向放行档。"""
    _d, fd = _staging(tmp_path)
    try:
        startup = begin_run(fd)
        written = commit_final(fd, _valid_manifest(), ledger=startup, outcome=clean_finish())
        assert read_manifest(fd) == written
    finally:
        os.close(fd)


def test_commit_final_clears_the_fatal_when_proven_clean(tmp_path):
    """⭐ 与 commit_stock 的权限差：收尾提交**能**清除。"""
    m = _valid_manifest(fetch_fatal_error=_fatal(kind="source_path_escape"),
                        stopped_reason="source_path_escape")
    _d, fd = _staging(tmp_path)
    try:
        # ⚠️ 凭据取自**磁盘**（R5 high B），故必须先把这份账本真正落盘；
        # 只放在内存里的话本档会因为「决策表看不到 fatal」而恒真。
        _seed_disk(fd, m)
        startup = begin_run(fd)
        commit_final(fd, _valid_manifest(),
                     ledger=startup, outcome=clean_finish(revisited_fatal_path=True))
        on_disk = read_manifest(fd)
        assert "fetch_fatal_error" not in on_disk
        assert "stopped_reason" not in on_disk
    finally:
        os.close(fd)


def test_commit_final_keeps_the_fatal_when_not_proven(tmp_path):
    m = _valid_manifest(fetch_fatal_error=_fatal(), stopped_reason="staging_path_escape")
    _d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, m)
        startup = begin_run(fd)
        commit_final(fd, _valid_manifest(),
                     ledger=startup, outcome=clean_finish(revisited_fatal_path=False))
        on_disk = read_manifest(fd)
        assert on_disk["fetch_fatal_error"] == _fatal()
        assert on_disk["stopped_reason"] == "staging_path_escape"
    finally:
        os.close(fd)


def test_commit_final_ignores_lifecycle_fields_already_in_the_passed_manifest(tmp_path):
    """⭐ 与 commit_stock 同源的结构性保证：写出去的三个字段**只能**来自决策表，
    绝不来自调用方内存里那份 manifest 的直接赋值。

    这里内存里带着 escape、本次是容量触顶——磁盘上应当出现的是「保留 escape +
    另记 secondary」，因为决策表看的是 manifest 里**上一次**的 fatal。

    判别力：把实现写成 `payload = dict(manifest)` 而不先剥 LIFECYCLE_KEYS，
    `stopped_reason_secondary` 那条断言仍会绿（决策表塞得回去），但把它改成
    「内存里预先带一个假的 secondary」就能分辨——故本档预置一个假 secondary。
    """
    m = _valid_manifest(fetch_fatal_error=_fatal(),
                        stopped_reason="staging_path_escape")
    _d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, m)
        startup = begin_run(fd)
        polluted = _valid_manifest()
        polluted["stopped_reason_secondary"] = "max_bytes"   # 内存里预置的陈旧附注
        commit_final(fd, polluted, ledger=startup, outcome=clean_finish(revisited_fatal_path=True,
                                                        staging_recheck="passed"))
        on_disk = read_manifest(fd)
        assert "fetch_fatal_error" not in on_disk
        assert "stopped_reason" not in on_disk
        # ⭐ 决策表这一支返回 {}，故内存里那条陈旧的 secondary 必须被剥掉
        assert "stopped_reason_secondary" not in on_disk
    finally:
        os.close(fd)


def test_commit_final_uses_full_fsync(tmp_path, monkeypatch):
    """manifest 提交按 O4-F11 定案走 F_FULLFSYNC。

    ⚠️ Linux 上 `full_fsync` 本就退回 `os.fsync`，该平台上无判别力（如实登记）。
    """
    calls = _fcntl_cmd_spy(monkeypatch)
    fsynced = []
    real_fsync = os.fsync
    monkeypatch.setattr(os, "fsync", lambda fd: (fsynced.append(fd), real_fsync(fd))[1])
    _d, fd = _staging(tmp_path)
    try:
        startup = begin_run(fd)
        commit_final(fd, _valid_manifest(), ledger=startup, outcome=clean_finish())
    finally:
        os.close(fd)
    if hasattr(fcntl, "F_FULLFSYNC"):
        assert fcntl.F_FULLFSYNC in calls
    else:
        assert fsynced


def test_commit_final_refuses_skip_verify_with_escape_and_writes_nothing(tmp_path):
    """⭐ P2-F3 的落盘侧：拒绝时**一个字节都不写**。

    判别力：把 resolve 的调用放在写入之后，本条必红。
    """
    m = _valid_manifest(fetch_fatal_error=_fatal(), stopped_reason="staging_path_escape")
    d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, m)
        startup = begin_run(fd)
        before = (d / MANIFEST_NAME).read_bytes()
        with pytest.raises(SkipVerifyWithEscapeError):
            commit_final(fd, _valid_manifest(),
                         ledger=startup, outcome=clean_finish(revisited_fatal_path=True))
        # 拒绝时一个字节都不写：磁盘上那份必须逐字节未变
        assert (d / MANIFEST_NAME).read_bytes() == before
        assert sorted(p.name for p in d.iterdir()) == [MANIFEST_NAME]
    finally:
        os.close(fd)


def test_full_round_trip_stock_commits_then_final(tmp_path):
    """⭐⭐ 端到端不变量：一次带着 escape 记录的运行里，
    **任意多次 per-stock 提交都动不了 fatal，只有收尾那一次能**。
    """
    start = _valid_manifest(fetch_fatal_error=_fatal(),
                            stopped_reason="staging_path_escape")
    _d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, start)                    # 上一次运行留下的账本
        startup = begin_run(fd)                  # ⚠️ 整轮共用同一份凭据
        for _ in range(3):                       # 三次 per-stock 提交
            commit_stock(fd, start, ledger=startup)
            assert read_manifest(fd)["fetch_fatal_error"] == _fatal()
        commit_final(fd, start, ledger=startup,
                     outcome=clean_finish(revisited_fatal_path=True,
                                          staging_recheck="passed"))
        assert "fetch_fatal_error" not in read_manifest(fd)
    finally:
        os.close(fd)


# ═════════════════════════════════════════════════════════════
# S2b 收口：机械化全量 sweep 挖出的「无任何测试隔离守护」的四条判据
#
# sweep 做法：把模块里每个 `_require*` 调用的第一个实参改成恒真值，各跑一遍。
# 84 个判据里 12 条变异后仍绿，逐条核归因后分四类：
#   ① 邻居兜底（6 条）——非法值撞不过下游那条更强的判据，登记不修：
#      L262/L449 sha 格式（两处必须相等）、L330 层内 idx 唯一（code 唯一 + 交叉核对）、
#      L395/L397 files 的 code/period（文件名解析一致性）、L623 存根 sha 格式（须等于重算值）
#   ② 等价变异（1 条）——L324「后缀与层一致」与交叉核对结构上重叠，S2a 已登记（M19）
#   ③ 已写明的恒真断言（1 条）——L644 两趟聚合相等，S2a 变异证实，保留作防御性冗余
#   ④ **真的没人守（4 条）**——结构上造得出专属档，按纪律就该补，即下面四条
#
# ⚠️ 为什么 984 组合那条整族扫描探不到它们：它只断言「若抛异常则必须是本模块的族」，
# **不断言「必须抛」**。守卫被变空之后不抛任何异常，那条扫描照样绿。
# 且它做的是「替换值」，从不做「删键」——L263 那种缺键的形态它够不着。
# ═════════════════════════════════════════════════════════════


def test_source_snapshot_without_universe_is_rejected_not_a_raw_keyerror():
    """L263：缺 `source_snapshot.universe` 必须是 ManifestInvalidError。

    判别力：把那条 `_require("universe" in snap, …)` 变空，本条必红——
    且红的形态是**原始 KeyError**，恢复指引一个字都印不出来（S2-F9 同族）。
    """
    m = _valid_manifest()
    del m["source_snapshot"]["universe"]
    with pytest.raises(ManifestInvalidError, match="universe"):
        validate_manifest(m)


def test_fatal_relative_path_must_not_be_empty():
    """L507：`fetch_fatal_error.relative_path` 为空串必须被拒。

    空串是「写侧只落了一半」的典型形态——四字段都在、值却是空的，
    恢复指引会印出「路径 ''」这种什么都没说的东西。
    判别力：把那条 `_require_nonempty_str` 变空，本条必红。
    """
    m = _valid_manifest(stopped_reason="staging_path_escape",
                        fetch_fatal_error=_fatal())
    m["fetch_fatal_error"]["relative_path"] = ""
    with pytest.raises(ManifestInvalidError, match="relative_path"):
        validate_manifest(m)


def test_fatal_component_must_not_be_empty():
    """L508：`fetch_fatal_error.component` 为空串必须被拒。

    `component` 是「哪一段被换掉了」——空串等于没记，
    而它正是操作者唯一能据以定位现场的字段。
    判别力：把那条 `_require_nonempty_str` 变空，本条必红。
    """
    m = _valid_manifest(stopped_reason="staging_path_escape",
                        fetch_fatal_error=_fatal())
    m["fetch_fatal_error"]["component"] = ""
    with pytest.raises(ManifestInvalidError, match="component"):
        validate_manifest(m)


def test_evidence_pass_completed_at_must_not_be_empty():
    """L627：`passes[].completed_at` 为空串必须被拒。

    R16-F1 造这份存根的全部理由是证明那两趟**真的跑过**；
    没有时间戳的一趟，「跑过」这件事就没有任何可核对的痕迹。
    判别力：把那条 `_require_nonempty_str` 变空，本条必红。
    """
    m = _valid_manifest()
    m["source_verification_evidence"]["passes"][0]["completed_at"] = ""
    with pytest.raises(ManifestInvalidError, match="completed_at"):
        validate_manifest(m)


# ═════════════════════════════════════════════════════════════
# codex R1 的三条 high（本机端到端复现后修复）
#
# 共同形态：**结构性保证被「可变的嵌套状态」与「没被校验的字段」绕过**。
# 这是「按字段穷尽而非按判据句穷尽」的又一次——我校验了想到的那几个字段
# （kind / staging_recheck / relative_path / component），漏了 revisited_fatal_path；
# 我拷贝了顶层的三个键，漏了它们**里面**那一层。
# ═════════════════════════════════════════════════════════════


def test_lifecycle_snapshot_does_not_alias_the_manifests_nested_fatal(tmp_path):
    """⭐⭐ [high #1] 快照只拷了顶层映射，`fetch_fatal_error` 仍是**同一个**可变 dict。

    端到端复现（本机真跑）：取完快照后改 `manifest["fetch_fatal_error"]["kind"]`，
    per-stock 提交把改过的值**写进了磁盘**——Task 16 那条「调用方即使污染了内存里
    的 manifest 也写不进磁盘」的核心不变量被绕过。

    后果链不止于此：`kind` 从 `staging_path_escape` 被改成 `source_path_escape`
    之后仍能过读侧校验，而 source escape 的清除**只要前提①**（不需要 staging 全量
    复校）→ 下一次收尾提交就能把它清掉。**一棵被证明动过的树被洗成干净凭据。**

    判别力：把 `lifecycle_snapshot` 改回浅拷贝，本条必红。
    """
    m = _valid_manifest(stopped_reason="staging_path_escape",
                        fetch_fatal_error=_fatal())
    snap = lifecycle_snapshot(m)
    assert snap["fetch_fatal_error"] is not m["fetch_fatal_error"]

    m["fetch_fatal_error"]["kind"] = "source_path_escape"      # 取完快照后再污染
    _d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, _valid_manifest(stopped_reason="staging_path_escape",
                                       fetch_fatal_error=_fatal()))
        commit_stock(fd, m, ledger=_expect(fd))
        assert read_manifest(fd)["fetch_fatal_error"]["kind"] == "staging_path_escape"
    finally:
        os.close(fd)


def test_resolve_final_lifecycle_does_not_alias_the_input_fatal():
    """[high #1 同族] 决策表保留 fatal 时不得把**输入那个对象**递出去。

    否则调用方改一下输入，已经算好的「新状态」跟着变——纯函数的结论
    在被写盘之前就可能被改掉。

    判别力：把两处 `deepcopy(prev_fatal)` 改回 `prev_fatal`，本条必红。
    """
    prev = _prev(fatal=_fatal(), reason="staging_path_escape")
    for outcome in (max_bytes_stop(), clean_finish(revisited_fatal_path=False),
                    clean_finish(revisited_fatal_path=True, staging_recheck="failed")):
        got = resolve_final_lifecycle(prev, outcome)
        assert got["fetch_fatal_error"] is not prev["fetch_fatal_error"]
        assert got["fetch_fatal_error"] == _fatal()


def test_revisited_fatal_path_must_be_a_real_bool():
    """⭐⭐ [high #2] `revisited_fatal_path` 从来没被校验过类型。

    本机复现：`clean_finish(revisited_fatal_path="false")` 被接受，
    而非空字符串是**真值** → 决策表当成「重走过那条路径」→
    **无凭无据就把 source escape 的 fatal 清掉了**。
    命令行/配置里传进来的 `"false"` 是这条路上最自然的形态。

    判别力：删掉 bool 校验，本条必红。
    """
    for bad in ("false", "true", "", 0, 1, None, [], {}):
        with pytest.raises(ValueError, match="revisited_fatal_path"):
            clean_finish(revisited_fatal_path=bad)
    for good in (True, False):
        assert clean_finish(revisited_fatal_path=good).revisited_fatal_path is good


def test_escape_evidence_cannot_be_mutated_after_construction():
    """⭐ [high #2 同族] `escape` 是个可变 dict 塞进 frozen dataclass ——
    构造期校验形同虚设：构造完再改一下就绕过去了（本机复现改成了 `bogus`）。

    判别力：把 MappingProxyType 换回裸 dict，本条必红。
    """
    e = escape_stop(kind="staging_path_escape", relative_path="a/b.csv",
                    component="a", errno="ELOOP")
    with pytest.raises(TypeError):
        e.escape["kind"] = "bogus"
    assert e.escape["kind"] == "staging_path_escape"


def test_final_outcome_enforces_the_kind_escape_pairing():
    """⭐ [high #2 同族] 跨字段不变量必须在 `__post_init__` 里兑现，
    否则**直接构造**这条路上全部校验都不存在。

    - `kind="escape"` 却没带证据 → 决策表里只剩一句 `assert`（`python -O` 下会被剥掉）；
    - `kind="clean"` 却带着证据 → 那份证据被**静默忽略**。

    判别力：删掉这两条配对校验，本条必红。
    """
    with pytest.raises(ValueError, match="escape"):
        FinalOutcome(kind="escape")
    with pytest.raises(ValueError, match="escape"):
        FinalOutcome(kind="clean", escape={"kind": "staging_path_escape",
                                           "relative_path": "a", "component": "a",
                                           "errno": "ELOOP"})


def test_final_outcome_validates_escape_evidence_on_direct_construction():
    """⭐ [high #2 同族] 校验必须落在 `__post_init__`，不能只落在 `escape_stop`。

    「守卫立在工厂而对象可以绕过工厂构造 = 守卫不存在」——本仓已栽过同形态
    （守卫立在调用方而 open() 发生在被调方）。

    判别力：把校验搬回 escape_stop、只留工厂那一份，本条必红。
    """
    ok = {"kind": "staging_path_escape", "relative_path": "a/b.csv",
          "component": "a", "errno": "ELOOP"}
    for key, bad in [("kind", "max_bytes"), ("errno", "EACCES"),
                     ("relative_path", ""), ("component", 123),
                     ("relative_path", None)]:
        broken = dict(ok, **{key: bad})
        with pytest.raises(ValueError):
            FinalOutcome(kind="escape", escape=broken)
    with pytest.raises(ValueError):
        FinalOutcome(kind="escape", escape=dict(ok, extra=1))     # 多余字段
    assert FinalOutcome(kind="escape", escape=ok).escape["kind"] == "staging_path_escape"


# ═════════════════════════════════════════════════════════════
# codex R2 的两条 high（本机复现后修复），外加按判据穷尽挖出的同族两条
#
# 家族 A：**读侧接受了写侧根本产不出的生命周期组合**（S2-F7 那个方向：
#         畸形被放行 · 安静）。修法是把「写侧能产出哪些组合」列全，
#         读侧照单收口。
# 家族 B：**提交入口能写出一份自己读不回来的账本**（R94-F2/O4-F13/S2-F3/
#         S2-F4/S2-F5 那个家族的第六次，只是这次跨的是「写入口与读入口」）。
#         修法是落盘前先过一遍读侧校验——让坏状态不可表达，而不是靠调用方小心。
# ═════════════════════════════════════════════════════════════


def _pair(reason, kind):
    return _valid_manifest(stopped_reason=reason, fetch_fatal_error=_fatal(kind=kind))


def test_reader_rejects_an_escape_reason_that_disagrees_with_the_fatal_kind():
    """⭐⭐ [R2 high #1] `stopped_reason="staging_path_escape"` 配
    `fetch_fatal_error.kind="source_path_escape"` 此前**被放行**。

    后果（本机复现）：决策表只看 `kind`，于是这份账本走
    `clean_finish(revisited_fatal_path=True, staging_recheck=None)` 时
    **绕过了 staging 全量复校**（那是 P2-F3 无条件要求的）直接 `return {}`，
    把粘性的 fatal 证据删掉 —— 一棵被证明动过的树拿到干净标签。
    改一个字段的 6 个字符就能做到，而「有人动过 staging」正是本模块的威胁模型。

    判别力：删掉这条配对判据，本条必红。
    """
    for reason, kind in [("staging_path_escape", "source_path_escape"),
                         ("source_path_escape", "staging_path_escape")]:
        with pytest.raises(ManifestInvalidError, match="fetch_fatal_error.kind"):
            validate_manifest(_pair(reason, kind))


def test_reader_still_accepts_the_one_legitimately_decoupled_pair():
    """⭐ 方向②（合法状态不得被判死）：`staging_recheck_failed` 是 spec 明写的
    **唯一**一种 `kind` 与 `stopped_reason` 解耦的状态（O4-F3）——
    「保留 fatal + 换 stopped_reason」在「kind 恒等于 reason」下结构上不可表达。

    两种 kind 都必须放行：复校失败这件事与「上次为什么出事」无关。
    """
    for kind in ("staging_path_escape", "source_path_escape"):
        m = _pair("staging_recheck_failed", kind)
        assert validate_manifest(m) is m


def test_reader_rejects_a_fatal_paired_with_a_reason_that_does_not_require_it():
    """⭐ 同族（按判据穷尽挖出，非评审报告的那一处）：
    读侧只查了「reason 要求 fatal ⇒ fatal 在」，**反向没查**——
    于是 `(stopped_reason="max_bytes", fetch_fatal_error=…)` 被放行，
    而决策表任何一支都产不出它。

    方向②：写侧带 fatal 时，reason 只可能是那三个之一
    （分支①写 escape 值、复校失败那支写 staging_recheck_failed、
    其余分支原样保留上一次的），故不误杀。

    判别力：删掉这条，本条必红。
    """
    with pytest.raises(ManifestInvalidError, match="stopped_reason"):
        validate_manifest(_valid_manifest(stopped_reason="max_bytes",
                                          fetch_fatal_error=_fatal()))


def test_reader_rejects_a_secondary_without_a_fatal():
    """⭐ 同族第三条：`stopped_reason_secondary` 只在「上次有 fatal + 本次容量
    触顶」那一支产生（O4-F1），没有 fatal 时它是无源之水。

    判别力：删掉这条，本条必红。
    """
    with pytest.raises(ManifestInvalidError, match="stopped_reason_secondary"):
        validate_manifest(_valid_manifest(stopped_reason_secondary="max_bytes"))


def test_resolve_refuses_a_mismatched_escape_pair():
    """⭐ [R2 high #1 的纵深] 决策表是**公开的纯函数**，可以不经 read_manifest
    直接调用。读侧堵上之后它仍要自己 fail closed，而不是「把不匹配的当成
    source escape 处理」——那正是被利用的那条路径。

    判别力：删掉决策表里那句配对检查，本条必红。
    """
    with pytest.raises(ManifestInvalidError, match="fetch_fatal_error.kind"):
        resolve_final_lifecycle(_pair("staging_path_escape", "source_path_escape"),
                                clean_finish(revisited_fatal_path=True))


def test_commit_stock_refuses_to_publish_a_manifest_its_own_reader_would_reject(tmp_path):
    """⭐⭐ [R2 high #2] 提交入口此前**不校验**就落盘。

    最初复现用的是 `lifecycle={"stopped_reason": "source_path_escape"}`（那时
    per-stock 提交还收快照参数）：过了键白名单、写入**报告成功**，而下一次
    `read_manifest` 判它非法 → **整棵 staging 读不回来**，而干成这件事的那次
    调用返回的是成功。一次 per-stock 提交就能把已经拉了几百只股的 staging
    变成砖头。那条走私通道后来被整个拆掉了（R6），此处改用**本身就残缺的
    manifest** ——「组装到一半就调提交」在 S3/S4 里完全可能。

    判别力：把 `_write_manifest` 里的 `validate_manifest` 删掉，本条必红。
    """
    broken = _valid_manifest()
    del broken["cursor"]
    _d, fd = _staging(tmp_path)
    try:
        with pytest.raises(ManifestInvalidError, match="cursor"):
            commit_stock(fd, broken, ledger=_expect(fd))
    finally:
        os.close(fd)


def test_commit_final_refuses_to_publish_a_manifest_its_own_reader_would_reject(tmp_path):
    """同上，另一个入口。决策表的输出恒合法（已有配对钉），故这里用一份
    本身就残缺的入参 manifest —— S3/S4 组装到一半就调提交是完全可能的。
    """
    broken = _valid_manifest()
    del broken["seed"]
    _d, fd = _staging(tmp_path)
    try:
        startup = begin_run(fd)
        with pytest.raises(ManifestInvalidError, match="seed"):
            commit_final(fd, broken, ledger=startup, outcome=clean_finish())
    finally:
        os.close(fd)


def test_a_refused_commit_leaves_the_previous_manifest_byte_identical(tmp_path):
    """⭐⭐ 「拒绝」必须是**一个字节都不写**，而不是「写坏了再报错」。

    校验必须排在 `atomic_write_json` **之前**：排在之后的话，上一份好账本
    已经被 `os.replace` 换掉了，报不报错都救不回来。

    判别力：把 `validate_manifest` 挪到 `atomic_write_json` 之后，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, _valid_manifest(), ledger=_expect(fd))
        before = (d / MANIFEST_NAME).read_bytes()
        broken = _valid_manifest()
        del broken["cursor"]
        with pytest.raises(ManifestInvalidError):
            commit_stock(fd, broken, ledger=_expect(fd))
        assert (d / MANIFEST_NAME).read_bytes() == before
        assert sorted(p.name for p in d.iterdir()) == [MANIFEST_NAME]   # 无临时残留
    finally:
        os.close(fd)


# ═════════════════════════════════════════════════════════════
# codex R3 [high]：一次**后来的**逃逸会把未解除的粘性信任证据覆盖掉
#
# spec 原文写「本次又撞了 escape → 覆盖上一次的」，而 O4-F1 同时又说
# `fetch_fatal_error` 是**粘性的信任状态**。两句话在「staging → source」
# 这个次序上直接冲突：staging 逃逸要清除得过**两道**前提（另加全量复校，
# P2-F3），source 逃逸只要一道。用后者覆盖前者，等于把那道门取消了。
#
# 本机三次运行端到端复现：Run1 撞 staging → Run2 撞 source（staging 证据没了）
# → Run3 干净跑完、重走过源路径、**没做 staging 全量复校** → fatal 被清除。
# 一棵从未证明恢复过的 staging 拿到干净账本。
#
# 判据升级为「**新状态必须至少和旧状态一样严**才允许覆盖」，
# 严格性 = 「清除它是否需要 staging 全量复校」。
# ═════════════════════════════════════════════════════════════


def _commit_cycle(m, outcome):
    """模拟一次收尾提交（纯内存）：剥掉三键、塞回决策表输出、并过一遍读侧。"""
    new = resolve_final_lifecycle(m, outcome)
    out = {k: v for k, v in m.items() if k not in LIFECYCLE_KEYS}
    out.update(new)
    return validate_manifest(out)


def _staging_escape(path="1分钟K线_前复权/a.csv", comp="1分钟K线_前复权"):
    return escape_stop(kind="staging_path_escape", relative_path=path,
                       component=comp, errno="ELOOP")


def _source_escape(path="日K线_前复权/b.csv", comp="日K线_前复权"):
    return escape_stop(kind="source_path_escape", relative_path=path,
                       component=comp, errno="ENOTDIR")


def test_a_source_escape_never_replaces_an_unresolved_staging_escape():
    """⭐⭐ [R3 high] 降级不许：`source_path_escape` 不得覆盖尚未解除的
    `staging_path_escape`。

    判别力：把这条守卫删掉，本条必红。
    """
    m = _commit_cycle(_valid_manifest(), _staging_escape())
    m = _commit_cycle(m, _source_escape())
    assert m["fetch_fatal_error"]["kind"] == "staging_path_escape"
    assert m["stopped_reason"] == "staging_path_escape"


def test_a_source_escape_never_replaces_an_unresolved_staging_recheck_failure():
    """⭐ 同族变体（控制者按判据穷尽挖出，评审只报了上一条）：
    `staging_recheck_failed` 也是「必须做过全量复校才能清」的状态，
    而它的 `fetch_fatal_error.kind` 可以是 `source_path_escape`（O4-F3 解耦）。

    只按 `kind` 判「严不严」会漏掉它：一次 source 逃逸就能把
    「上次复校没通过」这个结论抹掉。判据必须同时看 `stopped_reason`。

    判别力：把守卫里那半条 `prev_reason == "staging_recheck_failed"` 删掉，本条必红。
    """
    m = _valid_manifest(fetch_fatal_error=_fatal(kind="source_path_escape"),
                        stopped_reason="source_path_escape")
    m = _commit_cycle(m, clean_finish(revisited_fatal_path=True, staging_recheck="failed"))
    assert m["stopped_reason"] == "staging_recheck_failed"
    m = _commit_cycle(m, _source_escape())
    assert m["stopped_reason"] == "staging_recheck_failed"      # 未被覆盖


def test_the_staging_then_source_then_clean_chain_cannot_launder():
    """⭐⭐ [R3 high] 完整的三次运行洗白链必须走不通。

    修好后第三次运行会当场撞上 P2-F3：「这棵 staging 带着 escape 记录，
    而你跳过了既有文件复校，两者互斥」——正是它该给出的那句话。
    """
    m = _commit_cycle(_valid_manifest(), _staging_escape())
    m = _commit_cycle(m, _source_escape())
    with pytest.raises(SkipVerifyWithEscapeError):
        resolve_final_lifecycle(m, clean_finish(revisited_fatal_path=True,
                                                staging_recheck=None))


def test_the_same_chain_clears_after_a_passing_staging_recheck():
    """方向②：真做了全量复校就必须能清掉，否则这棵 staging 永远解不开。"""
    m = _commit_cycle(_valid_manifest(), _staging_escape())
    m = _commit_cycle(m, _source_escape())
    m = _commit_cycle(m, clean_finish(revisited_fatal_path=True,
                                      staging_recheck="passed"))
    assert "fetch_fatal_error" not in m
    assert "stopped_reason" not in m


def test_a_staging_escape_may_replace_a_source_escape():
    """方向②：**升级**方向必须放行 —— 新状态更严，覆盖是安全的。"""
    m = _commit_cycle(_valid_manifest(), _source_escape())
    m = _commit_cycle(m, _staging_escape())
    assert m["fetch_fatal_error"]["kind"] == "staging_path_escape"


def test_a_staging_escape_may_replace_another_staging_escape_on_a_different_path():
    """方向②：同类覆盖必须放行。

    只留最新那条路径**不构成信息损失**：清除 `staging_path_escape` 的前提②是
    对 manifest 里**所有已记录的 staging 文件**做存在性 + sha256 全量复校
    ——它是**路径无关**的，先前那条路径的损坏一样会被它抓到。
    """
    m = _commit_cycle(_valid_manifest(), _staging_escape("a/x.csv", "a"))
    m = _commit_cycle(m, _staging_escape("b/y.csv", "b"))
    assert m["fetch_fatal_error"]["relative_path"] == "b/y.csv"
    m = _commit_cycle(m, clean_finish(revisited_fatal_path=True,
                                      staging_recheck="passed"))
    assert "fetch_fatal_error" not in m


def test_a_source_escape_may_replace_another_source_escape():
    """方向②：同类覆盖放行（新状态与旧状态一样严）。

    没有这一条，一个「source 逃逸永远不许覆盖任何东西」的过严实现也能让
    上面那批档全绿，而它会让 manifest 一直指向**第一次**出事的那条路径。
    """
    m = _commit_cycle(_valid_manifest(), _source_escape("a/x.csv", "a"))
    m = _commit_cycle(m, _source_escape("b/y.csv", "b"))
    assert m["fetch_fatal_error"]["relative_path"] == "b/y.csv"


# ═════════════════════════════════════════════════════════════
# codex R4 [high]：清除闸仍按 `kind` 判「严不严」，漏掉 staging_recheck_failed
#
# ⚠️ **这是我自己的修复动作留下的洞**（本仓已栽过多次的形态：
#    「结构性改动后要重核原来成立的东西」）：
#    R3 那轮我为「哪些状态必须做过 staging 全量复校才能清」抽出了
#    `_needs_staging_recheck`，把它用在了**覆盖闸**上，却忘了**清除闸**
#    ——而清除闸正是它本来要服务的地方。
#    同一件事判两次、改了一处忘了另一处 ⇒ 修完必须留**机械守卫**。
# ═════════════════════════════════════════════════════════════


def test_a_failed_staging_recheck_cannot_be_cleared_without_a_passing_one():
    """⭐⭐ [R4 high] 两次运行：source 逃逸 → 复校失败 → 干净跑完（未复校）。

    第一步产出的 `(stopped_reason="staging_recheck_failed", kind="source_path_escape")`
    **是本代码自己产出的合法状态**（O4-F3 解耦 + 本片 D5 把「复校失败」提到
    kind 判断之前）。而清除闸只看 `kind`，于是第二次运行不做任何 staging 复校
    就把「上次复校没通过」和 fatal **一起抹掉** ——
    一棵已被证明与账本对不上的 staging 拿到干净账本。

    判别力：把清除闸换回 `prev_fatal["kind"] == "staging_path_escape"`，本条必红。
    """
    m = _valid_manifest(fetch_fatal_error=_fatal(kind="source_path_escape"),
                        stopped_reason="source_path_escape")
    m = _commit_cycle(m, clean_finish(revisited_fatal_path=True,
                                      staging_recheck="failed"))
    assert m["stopped_reason"] == "staging_recheck_failed"
    with pytest.raises(SkipVerifyWithEscapeError):
        resolve_final_lifecycle(m, clean_finish(revisited_fatal_path=True,
                                                staging_recheck=None))


def test_a_failed_staging_recheck_clears_after_a_passing_one():
    """方向②：真做了全量复校并通过，就必须解得开——否则这棵 staging 死锁。"""
    m = _valid_manifest(fetch_fatal_error=_fatal(kind="source_path_escape"),
                        stopped_reason="source_path_escape")
    m = _commit_cycle(m, clean_finish(revisited_fatal_path=True,
                                      staging_recheck="failed"))
    m = _commit_cycle(m, clean_finish(revisited_fatal_path=True,
                                      staging_recheck="passed"))
    assert "fetch_fatal_error" not in m
    assert "stopped_reason" not in m


def test_only_one_place_decides_whether_a_staging_recheck_is_required():
    """⭐ 机械守卫：「这个状态要不要 staging 全量复校」**只许在一处判定**。

    R4 那条 high 的根因就是同一件事判在两处、改了一处忘了另一处。
    本守卫用 AST 找出所有与字面量 `"staging_path_escape"` 的比较，
    断言它们只出现在 `_needs_staging_recheck` 里。

    ⚠️ 用 AST 而不是 grep：**注释与 docstring 里出现这个字面量是正常的**
    （承重注释要引用它），文本扫描会被自己的注释打红，而绕过方式是删注释
    ——那正是本仓立过的「源码守卫读哪份文本是判据的一部分」。

    ⚠️ **防空转**：同时断言至少找到 1 处。若 AST 遍历哪天被改坏、一处都找不到，
    这条守卫会「零违规」通过而实际什么都没查。
    """
    import ast as _ast
    import inspect
    import pathlib
    import qmt_manifest as _qm

    # 用 inspect 取被测模块**自己**的源文件路径，不靠相对层级拼——
    # 拼错了这条守卫就变成「永远因为路径错而红」，与它要查的东西无关。
    src = pathlib.Path(inspect.getsourcefile(_qm))
    tree = _ast.parse(src.read_text(encoding="utf-8"))

    found = []
    for fn in _ast.walk(tree):
        if not isinstance(fn, (_ast.FunctionDef, _ast.AsyncFunctionDef)):
            continue
        for node in _ast.walk(fn):
            if isinstance(node, _ast.Compare) and any(
                    isinstance(c, _ast.Constant) and c.value == "staging_path_escape"
                    for c in node.comparators):
                found.append(fn.name)

    assert found, ("AST 遍历一处都没找到——守卫可能被改坏了，"
                   "这次运行对本判据零判别力")
    assert set(found) == {"_needs_staging_recheck"}, (
        "「这个状态要不要 staging 全量复校」只许在 _needs_staging_recheck 里判定，"
        f"但下列函数也在直接比 kind：{sorted(set(found) - {'_needs_staging_recheck'})}"
        "——同一件事判在两处，改了一处忘了另一处正是 codex R4 那条 high 的根因")


# ═════════════════════════════════════════════════════════════
# codex R5：三条，共同形态仍是「我修了一半」
#   A 复校失败被前提①的早退挡住 —— D5/D16 两轮都动过这个分支的次序，
#     却一直没把它提到**最前面**；
#   B commit_final 的「上一次状态」取自调用方内存 —— R1 我给 commit_stock
#     配了启动快照，却没管 commit_final，而**能清除证据的恰恰只有它**；
#   C 写侧不查序列化后的字节数 —— S2-F13 我补了「结构合法」那一半，
#     漏了「大小也在读侧接受范围内」那一半。
# ═════════════════════════════════════════════════════════════


def _seed_disk(fd, manifest):
    """把一份 manifest 直接落到磁盘（模拟**上一次运行**留下的账本）。

    ⚠️ 不能再借 `commit_stock` 来种：它现在**从磁盘读生命周期**，
    磁盘是空的时候那三个字段根本写不进去——这正是它该有的性质。
    """
    atomic_write_json(fd, MANIFEST_NAME, manifest)
    return read_manifest(fd)


def test_a_failed_recheck_is_recorded_even_without_revisiting_the_fatal_path():
    """⭐⭐ [R5 high A] 「本次全量复校失败」是**本次运行的事实**，
    与「有没有重走过上次出事的那条路」无关。

    前提①（重走过）管的是**能不能清除**，不该挡住**记录一个新的失败**。
    照旧次序：`clean_finish(revisited_fatal_path=False, staging_recheck="failed")`
    会走前提①的早退、原样保留旧的 source reason，**把「复校失败」这个事实丢掉**；
    下一次运行重走过源路径、不做复校，就只看见一个 source 逃逸 → 全清。

    判别力：把「复校失败」那一支挪回前提①早退**之后**，本条必红。
    """
    m = _valid_manifest(fetch_fatal_error=_fatal(kind="source_path_escape"),
                        stopped_reason="source_path_escape")
    got = resolve_final_lifecycle(m, clean_finish(revisited_fatal_path=False,
                                                  staging_recheck="failed"))
    assert got["stopped_reason"] == "staging_recheck_failed"
    assert got["fetch_fatal_error"]["kind"] == "source_path_escape"


def test_the_unrevisited_failed_recheck_chain_cannot_launder():
    """⭐ [R5 high A] 两次运行的完整链条必须走不通。"""
    m = _valid_manifest(fetch_fatal_error=_fatal(kind="source_path_escape"),
                        stopped_reason="source_path_escape")
    m = _commit_cycle(m, clean_finish(revisited_fatal_path=False,
                                      staging_recheck="failed"))
    with pytest.raises(SkipVerifyWithEscapeError):
        resolve_final_lifecycle(m, clean_finish(revisited_fatal_path=True,
                                                staging_recheck=None))


def test_commit_final_takes_the_previous_lifecycle_from_disk_not_from_memory(tmp_path):
    """⭐⭐ [R5 high B] `commit_final` 是**唯一能清除证据的入口**，
    它凭据的「上一次状态」必须来自**磁盘**，不能来自调用方内存里那份 manifest。

    本机复现：磁盘上有未解除的 staging 警报，而内存里那份「不小心」把三个键
    弄没了 → 决策表看见「上次没有 fatal」→ 产出空生命周期 →
    **发布了一份干净账本**。落盘前的读侧校验也抓不到，因为它结构上完全合法。

    `commit_stock` 早就用启动快照挡住了同一件事（R1），而**能清除的恰恰只有
    收尾提交**——我当时只修了一半。

    判别力：把 `commit_final` 改回从入参 manifest 取上一次状态，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, _valid_manifest(fetch_fatal_error=_fatal(),
                                       stopped_reason="staging_path_escape"))
        startup = begin_run(fd)
        polluted = _valid_manifest()          # 内存里三个键都没了
        commit_final(fd, polluted, ledger=startup, outcome=clean_finish(revisited_fatal_path=False))
        on_disk = read_manifest(fd)
        assert on_disk["fetch_fatal_error"] == _fatal()
        assert on_disk["stopped_reason"] == "staging_path_escape"
    finally:
        os.close(fd)


def test_commit_final_still_clears_when_the_persisted_state_says_it_may(tmp_path):
    """方向②：凭据换成磁盘之后，**该清的仍要清得掉**，否则 staging 永远解不开。"""
    d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, _valid_manifest(fetch_fatal_error=_fatal(),
                                       stopped_reason="staging_path_escape"))
        startup = begin_run(fd)
        commit_final(fd, _valid_manifest(), ledger=startup,
                     outcome=clean_finish(revisited_fatal_path=True,
                                          staging_recheck="passed"))
        assert "fetch_fatal_error" not in read_manifest(fd)
    finally:
        os.close(fd)


def test_commit_final_works_in_the_bootstrap_state_with_no_manifest_on_disk(tmp_path):
    """方向②：引导态（磁盘上还没有 manifest）必须照常工作 ——
    `read_manifest` 返回 None 是**合法**的，不能被当成错误。"""
    d, fd = _staging(tmp_path)
    try:
        startup = begin_run(fd)
        written = commit_final(fd, _valid_manifest(), ledger=startup, outcome=clean_finish())
        assert read_manifest(fd) == written
        assert "stopped_reason" not in written
    finally:
        os.close(fd)


def test_the_writer_refuses_a_payload_bigger_than_the_readers_limit(tmp_path, monkeypatch):
    """⭐ [R5 medium C] 写侧此前只查「结构合法」，不查**序列化后的字节数**。

    未知顶层键按 O4-F10 是**原样保留且无上限**的通道；一份结构完全合法、
    序列化后 67,113,084 字节的账本（读侧上限 67,108,864）**写入报告成功**，
    而下一次启动就以「过大」拒绝整棵 staging —— 已积累的数据全部不可用。

    这是 S2-F13 的另一半：我补了「结构合法」，漏了「大小也在读侧接受范围内」。

    判别力：删掉写侧的大小检查，本条必红。
    """
    import qmt_manifest as qm
    monkeypatch.setattr(qm, "_MANIFEST_MAX_BYTES", 4096)
    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, _valid_manifest(), ledger=_expect(fd))       # 先写一份好的
        before = (d / MANIFEST_NAME).read_bytes()
        big = _valid_manifest()
        big["batches"] = "x" * 8192                              # 未知顶层键，结构合法
        with pytest.raises(ManifestInvalidError, match="过大"):
            commit_stock(fd, big, ledger=_expect(fd))
        assert (d / MANIFEST_NAME).read_bytes() == before        # 好账本逐字节未变
        assert sorted(p.name for p in d.iterdir()) == [MANIFEST_NAME]
    finally:
        os.close(fd)


def test_the_write_side_limit_is_measured_on_the_bytes_actually_published(tmp_path, monkeypatch):
    """⭐ 量的必须**就是**写的那批字节（codex R5 的「序列化漂移」）。

    中文周期目录名在 `ensure_ascii=True` 下会膨胀成 `\\uXXXX`，长度差好几倍。
    若「量长度」与「写文件」各自 dumps 一次，参数一旦不一致，量到的就不是
    落盘的。本条把上限卡在**恰好等于真实落盘长度**上：多一个字节就必须被拒。

    判别力：让写侧改用另一种编码去量（例如 ensure_ascii=True），本条必红。
    """
    import qmt_manifest as qm
    m = _valid_manifest()
    # ⚠️ 量的必须是**真正会落盘的那份**：per-stock 提交把 source_verification
    # 写死成 partial，长度与入参不同。先跑一次拿到它，再据此设上限。
    (tmp_path / "probe").mkdir()
    _probe_d, _probe_fd = _staging(tmp_path / "probe")
    try:
        published = commit_stock(_probe_fd, m, ledger=_expect(_probe_fd))
    finally:
        os.close(_probe_fd)
    exact = len(_json_rw.dumps(published, ensure_ascii=False).encode("utf-8"))
    d, fd = _staging(tmp_path)
    try:
        monkeypatch.setattr(qm, "_MANIFEST_MAX_BYTES", exact)
        commit_stock(fd, m, ledger=_expect(fd))                        # 恰好等于上限 → 放行
        assert (d / MANIFEST_NAME).read_bytes() == \
            _json_rw.dumps(published, ensure_ascii=False).encode("utf-8")
        monkeypatch.setattr(qm, "_MANIFEST_MAX_BYTES", exact - 1)
        with pytest.raises(ManifestInvalidError, match="过大"):
            commit_stock(fd, m, ledger=_expect(fd))                    # 少一个字节 → 拒
    finally:
        os.close(fd)


# ═════════════════════════════════════════════════════════════
# codex R6：两条 high，外加控制者顺带核实的一条**已登记残留其实是活的洞**
#
# ⚠️ A 是 **R5 那个修复自己带出来的另一面**：把凭据从「内存」换成「磁盘」之后，
#    「磁盘上没有账本」就成了新的洗白入口——运行中把账本删掉，
#    收尾提交把它当成全新引导态，于是发布一份没有警报的干净账本。
#    ⇒ 正解不是二选一，而是**两边都要**：磁盘是当前真相，启动快照是预期；
#      两者不一致（含「预期有、磁盘没了」）一律 fail closed。
#
# ⚠️ C 是我在 R1 亲手登记为「已接受残留」的那条——本轮实测证明它是**活的**：
#    per-stock 提交传一个伪造的空快照，就能把磁盘上的警报抹掉。
#    ⇒ 结构性解法：**per-stock 提交根本不收快照参数**，三个字段一律从磁盘
#      读出来原样写回去。「够不到」从此是无条件的，不再依赖调用方老实。
#      —— 登记为「已接受残留」的东西，下一轮要重新问一次它还能不能被利用。
# ═════════════════════════════════════════════════════════════


def test_begin_run_returns_the_startup_lifecycle_snapshot(tmp_path):
    """启动闸返回生命周期启动快照，它是收尾提交的**预期**。"""
    d, fd = _staging(tmp_path)
    try:
        m = _valid_manifest(fetch_fatal_error=_fatal(),
                            stopped_reason="staging_path_escape")
        _seed_disk(fd, m)
        assert begin_run(fd).lifecycle == {"fetch_fatal_error": _fatal(),
                                           "stopped_reason": "staging_path_escape"}
    finally:
        os.close(fd)


def test_begin_run_on_a_bootstrap_staging_returns_an_empty_snapshot(tmp_path):
    """引导态（磁盘上还没有账本）合法，返回空快照。"""
    d, fd = _staging(tmp_path)
    try:
        assert begin_run(fd).lifecycle == {}
    finally:
        os.close(fd)


def test_begin_run_refuses_skip_existing_verify_against_an_unresolved_escape(tmp_path):
    """⭐⭐ [R6 high B] P2-F3 明写这是**拒绝启动**，而此前它只在**收尾提交**
    那条路径上求值 —— 一次带 flag 的运行可以先拷完文件、推进游标、写满池子，
    到最后才被拒，**已提交的状态和已消耗的配额都收不回来**。

    判别力：删掉启动闸里的这条检查，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, _valid_manifest(fetch_fatal_error=_fatal(),
                                       stopped_reason="staging_path_escape"))
        with pytest.raises(SkipVerifyWithEscapeError):
            begin_run(fd, skip_existing_verify=True)
    finally:
        os.close(fd)


def test_begin_run_allows_skip_existing_verify_on_a_clean_staging(tmp_path):
    """方向②：没有未解除证据时，这个 flag 完全合法，不得被误杀。"""
    d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, _valid_manifest())
        assert begin_run(fd, skip_existing_verify=True).lifecycle == {}
    finally:
        os.close(fd)


def test_begin_run_also_refuses_skip_verify_after_a_failed_recheck(tmp_path):
    """同族：`staging_recheck_failed` 同样必须做全量复校才能清 → 同样互斥。"""
    d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, _valid_manifest(
            fetch_fatal_error=_fatal(kind="source_path_escape"),
            stopped_reason="staging_recheck_failed"))
        with pytest.raises(SkipVerifyWithEscapeError):
            begin_run(fd, skip_existing_verify=True)
    finally:
        os.close(fd)


def test_commit_stock_takes_no_lifecycle_parameter_at_all(tmp_path):
    """⭐⭐ [R6 / R1 残留 C] 「per-stock 提交够不到那三个字段」从**有条件**
    （靠调用方传对快照）变成**无条件**：那个参数根本不存在了。

    判别力：把参数加回去，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        with pytest.raises(TypeError):
            commit_stock(fd, _valid_manifest(), lifecycle={})    # noqa: 参数已不存在
    finally:
        os.close(fd)


def test_commit_stock_preserves_the_on_disk_lifecycle_no_matter_what_memory_says(tmp_path):
    """⭐⭐ [R6 / R1 残留 C] 本机复现过的洗白路径：per-stock 提交传一个伪造的
    空快照，磁盘上的警报就被抹掉了。现在三个字段一律**从磁盘读、原样写回**，
    调用方内存里是什么都无关。

    判别力：把实现改回「用调用方给的快照」，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, _valid_manifest(fetch_fatal_error=_fatal(),
                                       stopped_reason="staging_path_escape"))
        commit_stock(fd, _valid_manifest(), ledger=_expect(fd))        # 内存里干干净净
        on_disk = read_manifest(fd)
        assert on_disk["fetch_fatal_error"] == _fatal()
        assert on_disk["stopped_reason"] == "staging_path_escape"
    finally:
        os.close(fd)


def test_commit_final_refuses_when_an_expected_manifest_has_disappeared(tmp_path):
    """⭐⭐ [R6 high A] 运行中账本被删/被改名 → `read_manifest` 返回 None。

    把它当成「全新引导态」就等于：**内存里还带着未解除的警报，磁盘上的证据
    却被删了，于是发布一份结构完全合法的干净账本**。本机复现过。

    正解：磁盘是当前真相，启动快照是**预期**；预期非空而磁盘没了 = 有人在
    本次运行期间动过账本 → fail closed。

    判别力：删掉这条检查，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        m = _valid_manifest(fetch_fatal_error=_fatal(),
                            stopped_reason="staging_path_escape")
        _seed_disk(fd, m)
        startup = begin_run(fd)
        os.unlink(str(d / MANIFEST_NAME))              # 运行中有人把账本删了
        with pytest.raises(ManifestInvalidError, match="不见了|消失|删"):
            commit_final(fd, m, outcome=clean_finish(),
                         ledger=startup)
    finally:
        os.close(fd)


def test_commit_final_refuses_when_disk_lifecycle_drifted_from_the_startup_snapshot(tmp_path):
    """⭐ 同族：磁盘上的生命周期与启动快照**不一致**（有人在运行期间改了账本）
    同样 fail closed。这条顺带把「伪造启动快照」也堵死了——伪造的对不上磁盘。

    判别力：删掉这条比对，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, _valid_manifest())
        startup = begin_run(fd)                        # {}
        _seed_disk(fd, _valid_manifest(fetch_fatal_error=_fatal(),
                                       stopped_reason="staging_path_escape"))
        with pytest.raises(ManifestInvalidError, match="不一致|漂移"):
            commit_final(fd, _valid_manifest(), outcome=clean_finish(),
                         ledger=startup)
    finally:
        os.close(fd)


def test_commit_final_still_works_on_a_genuine_bootstrap(tmp_path):
    """方向②：真正的引导态（启动时就没有账本、快照为空）必须照常发布。"""
    d, fd = _staging(tmp_path)
    try:
        startup = begin_run(fd)
        assert startup.lifecycle == {} and startup.existed is False
        written = commit_final(fd, _valid_manifest(), outcome=clean_finish(),
                               ledger=startup)
        assert read_manifest(fd) == written
    finally:
        os.close(fd)


# ═════════════════════════════════════════════════════════════
# 控制者自查（R7 等配额期间，拿十条自问对**刚改过的新代码**跑一遍）
#   ⑨「凭据从 A 换成 B ⇒ 问 B 缺席/被篡改时会怎样」——R6 只把它应用在
#      commit_final 上，而 commit_stock 这一轮也刚改成从磁盘取，同样的洞照样在。
#   ①「每个字段都校验了吗」——R1 那条 bool 教训没有应用到**新加的**参数上。
# ═════════════════════════════════════════════════════════════


def test_commit_stock_refuses_when_an_expected_manifest_has_disappeared(tmp_path):
    """⭐⭐ 与 `commit_final` 同一个洞，只是在另一个入口（控制者自查挖出）。

    per-stock 提交这一轮刚改成「三个字段从磁盘读」——那么账本被删时 `previous`
    是 `None`，它就会写出一份**没有警报**的账本。收尾提交的快照比对能在**最后**
    兜住，但**运行若崩在收尾之前，下一次就从一份干净账本开始了**，
    而崩溃恰恰是这套设计明写要扛的场景。

    判别力：删掉这条检查，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, _valid_manifest(fetch_fatal_error=_fatal(),
                                       stopped_reason="staging_path_escape"))
        startup = begin_run(fd)
        os.unlink(str(d / MANIFEST_NAME))              # 运行中有人把账本删了
        with pytest.raises(ManifestInvalidError, match="不见了|消失|删"):
            commit_stock(fd, _valid_manifest(), ledger=startup)
    finally:
        os.close(fd)


def test_commit_stock_refuses_when_the_disk_lifecycle_drifted(tmp_path):
    """⭐ 同族：磁盘上的生命周期与启动快照不一致 → 有人在运行期间动过账本。

    这条同时把「伪造启动快照」堵死：伪造的对不上磁盘。
    ⚠️ 注意 `startup_lifecycle` 在这里只当**预期**用来比对，**从不被写进 payload**
    （写的永远是磁盘上那份），所以它不构成新的走私通道。

    判别力：删掉这条比对，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, _valid_manifest())
        startup = begin_run(fd)                        # {}
        _seed_disk(fd, _valid_manifest(fetch_fatal_error=_fatal(),
                                       stopped_reason="staging_path_escape"))
        with pytest.raises(ManifestInvalidError, match="不一致|漂移"):
            commit_stock(fd, _valid_manifest(), ledger=startup)
    finally:
        os.close(fd)


def test_commit_stock_writes_the_first_manifest_in_a_genuine_bootstrap(tmp_path):
    """方向②：真引导态（启动时就没有账本、快照为空）必须能写出首份 manifest。

    没有这一条，一个「磁盘上没有账本就一律拒绝」的实现也能让上面两条绿，
    而那会让**首份 manifest 永远写不出来**（R60-F3 明写引导态要能继续初始化）。
    """
    d, fd = _staging(tmp_path)
    try:
        startup = begin_run(fd)
        assert startup.lifecycle == {} and startup.existed is False
        written = commit_stock(fd, _valid_manifest(), ledger=startup)
        assert read_manifest(fd) == written
    finally:
        os.close(fd)


def test_begin_run_requires_a_real_bool_for_skip_existing_verify(tmp_path):
    """⭐ R1 那条教训（非空字符串是真值）没有应用到这个**新加的**参数上。

    `skip_existing_verify="false"` 会被当成真 → 在一棵干净 staging 上凭空拒绝启动；
    反过来说，任何非布尔值都意味着调用方对这个开关的理解与实现不一致，
    而它守的是「拒绝启动」这条闸。构造期拒掉，别猜调用方的意思。

    判别力：删掉这条 bool 校验，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        for bad in ("false", "true", "", 0, 1, None, []):
            with pytest.raises(ValueError, match="skip_existing_verify"):
                begin_run(fd, skip_existing_verify=bad)
        assert begin_run(fd, skip_existing_verify=False).lifecycle == {}
    finally:
        os.close(fd)


# ═════════════════════════════════════════════════════════════
# codex R7 [high]：`{}` 这个哨兵把两种截然不同的状态混成了一个
#
# `begin_run()` 对「磁盘上没有账本」和「账本在、但没有生命周期字段」都返回 `{}`，
# 而 `_lifecycle_from_disk` 拿它的**真假值**去判断「后来账本不见了算不算合法引导态」。
# 于是一棵**已经积累了 files / pool_order / cursor 的干净 staging**，账本被删掉之后
# 两个提交入口都会拿调用方内存里那份（可能是过期的）把它**凭空重建**，
# 已积累的进度被静默丢弃；换成另一份合法账本同样无人察觉。
#
# ⚠️ 与 R1 那条「manifest 不存在 ≠ manifest 坏了」是同一族错误的**反向**：
#    那次我把两种状态**正确地分开了**，这次我又把两种状态**合并**成一个哨兵。
#    判据：**凡用「空值/假值」当哨兵，先问它是不是把两种语义压在了一起。**
#
# 处置：`begin_run` 改为返回**不透明凭据** `RunLedger`，分别记「当时有没有账本」
# 与「那份账本的字节指纹」；每次提交成功后**更新**这份预期。
# ═════════════════════════════════════════════════════════════


def _established(**kw):
    """一份**已经积累了进度**的干净账本（有额外顶层键、没有生命周期字段）。"""
    return _valid_manifest(committed_bytes=1234567,
                           failures=[{"stock_code": "600004.SH", "attempts": 1}], **kw)


def test_begin_run_distinguishes_bootstrap_from_an_established_clean_ledger(tmp_path):
    """⭐⭐ [R7 high] 两种状态必须可区分。

    判别力：把凭据换回裸的生命周期 dict，两者都是 `{}`，本条必红。
    """
    (tmp_path / "a").mkdir(); (tmp_path / "b").mkdir()
    d1, fd1 = _staging(tmp_path / "a")
    d2, fd2 = _staging(tmp_path / "b")
    try:
        _seed_disk(fd2, _established())
        boot = begin_run(fd1)          # 真引导态
        est = begin_run(fd2)           # 已建成、但干净
        assert boot.existed is False
        assert est.existed is True
        assert est.digest is not None
    finally:
        os.close(fd1); os.close(fd2)


@pytest.mark.parametrize("commit", ["stock", "final"])
def test_commit_refuses_when_an_established_clean_ledger_disappears(tmp_path, commit):
    """⭐⭐ [R7 high] 已建成的**干净**账本被删 → 两个入口都必须拒。

    此前只有「带 fatal 的账本被删」有档，干净那一档漏掉了——而账本正是
    `files` / `pool_order` / `cursor` 的**唯一**真相，丢了就是丢进度。

    判别力：把「有没有账本」这个位去掉、退回看生命周期真假值，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, _established())
        ledger = begin_run(fd)
        os.unlink(str(d / MANIFEST_NAME))
        stale = _valid_manifest()                      # 调用方手里那份是过期的
        with pytest.raises(ManifestInvalidError, match="不见了|消失|删"):
            if commit == "stock":
                commit_stock(fd, stale, ledger=ledger)
            else:
                commit_final(fd, stale, outcome=clean_finish(), ledger=ledger)
    finally:
        os.close(fd)


@pytest.mark.parametrize("commit", ["stock", "final"])
def test_commit_refuses_when_the_ledger_was_replaced_by_another_valid_one(tmp_path, commit):
    """⭐ [R7 high 同族] 账本被**换成另一份同样合法的干净账本** → 必须拒。

    只比「生命周期字段」时两份都是空的、完全看不出来；比**字节指纹**才看得出。

    判别力：删掉指纹比对，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        _seed_disk(fd, _established())
        ledger = begin_run(fd)
        _seed_disk(fd, _valid_manifest(seed="别人的-seed"))     # 被换掉
        with pytest.raises(ManifestInvalidError, match="不一致|换|改"):
            if commit == "stock":
                commit_stock(fd, _valid_manifest(), ledger=ledger)
            else:
                commit_final(fd, _valid_manifest(), outcome=clean_finish(), ledger=ledger)
    finally:
        os.close(fd)


def test_a_bootstrap_run_fails_closed_if_its_own_first_manifest_disappears(tmp_path):
    """⭐⭐ [R7 high] 预期必须**每次提交后更新**：引导态第一次提交成功之后，
    这棵 staging 就**不再是引导态**了；账本再消失就是有人动过。

    判别力：不在提交后更新预期，本条必红（第二次提交会把它当成仍在引导态）。
    """
    d, fd = _staging(tmp_path)
    try:
        ledger = begin_run(fd)
        commit_stock(fd, _established(), ledger=ledger)     # 首份账本
        os.unlink(str(d / MANIFEST_NAME))
        with pytest.raises(ManifestInvalidError, match="不见了|消失|删"):
            commit_stock(fd, _valid_manifest(), ledger=ledger)
    finally:
        os.close(fd)


def test_commit_refuses_when_a_manifest_appears_during_a_bootstrap_run(tmp_path):
    """⭐ 反方向：本次运行开始时这里**没有**账本，提交时却出现了一份 ——
    有别的进程在同一棵 staging 上跑。覆盖它等于把对方的进度盖掉。

    判别力：删掉这条反向检查，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        ledger = begin_run(fd)                              # 引导态
        _seed_disk(fd, _established())                      # 别人写了一份
        with pytest.raises(ManifestInvalidError, match="出现|不一致"):
            commit_stock(fd, _valid_manifest(), ledger=ledger)
    finally:
        os.close(fd)


def test_many_commits_in_one_run_are_all_accepted(tmp_path):
    """方向②：**同一次运行里连续多次提交必须全部通过** ——
    每次写完都要把预期更新到刚写出去的那份，否则第二次就会被自己拒掉。

    没有这一条，一个「提交后不更新预期」的实现会让整条按股流水线在第二只股上死掉。
    """
    d, fd = _staging(tmp_path)
    try:
        ledger = begin_run(fd)
        for i in range(5):
            commit_stock(fd, _valid_manifest(committed_bytes=i), ledger=ledger)
        assert read_manifest(fd)["committed_bytes"] == 4
        # ⚠️ 收尾也必须带上已累计的量：调用方丢掉 committed_bytes 会被单调守卫
        # 正确地判红（R10 high B）——现实里 S4 手里那份本来就该是累计的。
        commit_final(fd, _valid_manifest(committed_bytes=4),
                     outcome=clean_finish(), ledger=ledger)
    finally:
        os.close(fd)


# ═════════════════════════════════════════════════════════════
# 控制者追查（R8 被配额掐断前，codex 留下的一条**未完成**的线索）
#
# 它的原话：「the ledger validates only the disk file, while both commit paths
# rebuild all non-lifecycle state from caller memory. I'm testing whether a
# stale-but-valid caller snapshot can roll back already committed progress」
# —— 那是**进行时的计划**、不是结论（判决行是伪造的），但线索本身值得追。
#
# 本机复现坐实：调用方拿一份**过期副本**再提交一次，已提交的 files 从 6 条退回
# 4 条、cursor 倒退、pool_order 缩水，而凭据检查**照过**——因为磁盘上那份确实是
# 我们上次写的。凭据管的是「账本有没有被外人动过」，管不了「调用方自己交回来的
# 内容是不是退步了」。
#
# ⚠️ **差点修过头**：第一反应是「条目只增不减」，而 spec §4.4:429 明写崩溃恢复
#    发生在「读完并校验 manifest **之后**、任何拷贝**之前**」——也就是在 begin_run
#    之后、运行之内；恢复第③档更是**合法地**删该股条目并回退 cursor。
#    写死单调就会打死 spec 自己的恢复路径。
# ⇒ 正解：让调用方**显式声明唯一正当理由**，其余一律拒。
# ═════════════════════════════════════════════════════════════


def _with_more_stocks(m):
    """在一份 manifest 上「再拉一只股」：files +2、池 +1、cursor 前进。"""
    m = copy.deepcopy(m)
    m["files"] += [_file_rec("600004.SH", "浦发银行", "1m"),
                   _file_rec("600004.SH", "浦发银行", "daily")]
    m["pool_order"]["SH"].append({"code": "600004.SH", "universe_idx": 1})
    m["cursor"]["SH"] = 2
    return _recompute_evidence(m)


def test_commit_stock_refuses_a_stale_snapshot_that_rolls_back_progress(tmp_path):
    """⭐⭐ 调用方交回一份**过期副本** → 已提交的进度被回滚，而凭据检查照过。

    本机复现：files 6→4、cursor SH 2→1、池 SH 2→1。账本是 files / pool_order /
    cursor 的唯一真相，回滚它等于把已拷到盘上的股票从台账里抹掉——它们随后既
    不在池里，又会被 pilot 当成 `untracked_target_file`。

    判别力：删掉这条守卫，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        ledger = begin_run(fd)
        stale = _valid_manifest()
        commit_stock(fd, stale, ledger=ledger)
        commit_stock(fd, _with_more_stocks(stale), ledger=ledger)
        assert len(read_manifest(fd)["files"]) == 6
        with pytest.raises(ManifestInvalidError, match="回滚|倒退|退步"):
            commit_stock(fd, stale, ledger=ledger)          # 又拿过期那份
    finally:
        os.close(fd)


def test_commit_final_also_refuses_a_progress_rollback(tmp_path):
    """同族的另一个入口（第⑪问：评审报了 A 处，同族的 B 处呢）。

    收尾提交同样从调用方内存重建全部非生命周期内容 —— 而收尾**永远**没有
    正当理由回滚进度（崩溃恢复不走收尾提交）。
    """
    d, fd = _staging(tmp_path)
    try:
        ledger = begin_run(fd)
        stale = _valid_manifest()
        commit_stock(fd, _with_more_stocks(stale), ledger=ledger)
        with pytest.raises(ManifestInvalidError, match="回滚|倒退|退步"):
            commit_final(fd, stale, outcome=clean_finish(), ledger=ledger)
    finally:
        os.close(fd)


def test_normal_growth_and_no_change_are_both_accepted(tmp_path):
    """方向②：只增不减、以及**完全不变**（配额触顶那一支不推进 cursor）都必须放行。

    没有这一条，一个「payload 必须与磁盘严格相等」或「必须严格变大」的过严实现
    也能让上面几条绿。
    """
    d, fd = _staging(tmp_path)
    try:
        ledger = begin_run(fd)
        m = _valid_manifest()
        commit_stock(fd, m, ledger=ledger)
        commit_stock(fd, m, ledger=ledger)                       # 完全不变
        commit_stock(fd, _with_more_stocks(m), ledger=ledger)    # 只增
        assert len(read_manifest(fd)["files"]) == 6
    finally:
        os.close(fd)


def test_a_cursor_only_regression_is_refused(tmp_path):
    """⭐ 隔离 `cursor` 倒退这一条判据。

    ⚠️ 为什么必须单独造这一档：机械变异实测，「files 回滚」「pool 回滚」
    「cursor 倒退」三条判据在**同一份过期副本**上会一起触发，最先命中的那条
    把后两条挡住了 —— 于是删掉 `cursor` 那条**零红**。
    只回退游标、不动 files/pool 的账本**仍然合法**，故这一档只有它够得着。

    ⚠️ **`files` 与 `pool_order` 两条则造不出专属档（如实登记等价重叠）**：
    账本自身的一致性规则（R21-F3：每个池条目恰配 1m + daily 两条文件记录）
    把它们**结构上绑死**了——只缩其中一边会先被读侧校验拒掉，
    根本走不到回滚守卫。**这是「结构上做不到」，不是「懒得写」。**

    判别力：删掉 cursor 那条判据，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        ledger = begin_run(fd)
        m = _valid_manifest()
        commit_stock(fd, m, ledger=ledger)
        ahead = copy.deepcopy(m)
        ahead["cursor"]["SH"] = 2                    # 游标前进（files/pool 不变，合法）
        commit_stock(fd, ahead, ledger=ledger)
        assert read_manifest(fd)["cursor"]["SH"] == 2
        with pytest.raises(ManifestInvalidError, match="倒退"):
            commit_stock(fd, m, ledger=ledger)       # 只有游标退回去
    finally:
        os.close(fd)


# ═════════════════════════════════════════════════════════════
# codex R9：三条（2 high + 1 medium），最彻底的一轮（73 条查看命令）
#
# A 回滚守卫**只看我想到的那三样**（files 身份 / pool 身份 / cursor 方向），
#   其余非生命周期字段全都能被一份过期副本改写 —— 第①问（按字段穷尽）
#   应用到**守卫本身**，我又只列了想得到的那几个。
# B `recovering_from_crash=True` 是**无限制**的旁路：spec 只允许删「那一只在途
#   的股」并把该层 cursor 退到它的下标，而这个 API 收不到目标、也不校验增量。
# C 语法合法的 JSON 仍可能抛**裸 ValueError**（超长整数撞 Python 的位数上限）。
# ═════════════════════════════════════════════════════════════


def _rich(**kw):
    """一份带齐「计数 / 历史 / 遥测」的账本。"""
    return _valid_manifest(committed_bytes=9_000_000,
                           failures=[{"stock_code": "600006.SH", "attempts": 2}],
                           batches=[{"n": 1}], inflight_rollbacks={"1": 2}, **kw)


def _committed(fd, m):
    """先提交一份，返回运行凭据。"""
    ledger = begin_run(fd)
    commit_stock(fd, m, ledger=ledger)
    return ledger


@pytest.mark.parametrize("label,mutate", [
    ("committed_bytes 被调小", lambda t: t.__setitem__("committed_bytes", 1)),
    ("failures[].attempts 被清零", lambda t: t["failures"][0].__setitem__("attempts", 0)),
    ("batches 历史被丢弃", lambda t: t.__setitem__("batches", [])),
    ("inflight_rollbacks 遥测被丢弃", lambda t: t.__setitem__("inflight_rollbacks", {})),
    ("已提交文件的 sha256 被改", lambda t: t["files"][0].__setitem__("sha256", "0" * 64)),
    ("已提交文件的 bytes 被改", lambda t: t["files"][0].__setitem__("bytes", 1)),
    ("冻结的 seed 被换", lambda t: t.__setitem__("seed", "别人的-seed")),
    ("冻结的 universe 被换",
     lambda t: t["source_snapshot"]["universe"].__setitem__("BJ", [])),
    ("冻结的 source_mount 被换",
     lambda t: t["source_mount"].__setitem__("device", "//别人/share")),
])
def test_a_stale_snapshot_cannot_rewrite_committed_state(tmp_path, label, mutate):
    """⭐⭐ [R9 high A] 这 9 个字段此前**逐个实测全部能被改写**。

    危害各不相同、但都实在：累计字节调小 → **绕开 `--max-bytes` 硬上限**；
    重试次数清零 → **复活已耗尽的候选**；历史与遥测被丢弃 → 报告里的
    `inflight_rollbacks` 归零，把本机故障史抹成「市场就这样」；
    已提交文件的 bytes/sha256 被改 → **完整性基线被污染**，
    pilot 的 `staging_intact` 从此校验的是一条假基线；
    冻结的 seed / universe / source_mount 被换 → staging 与归属标记**永久对不上**。

    判别力：删掉对应那条判据，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        m = _rich()
        ledger = _committed(fd, m)
        tampered = copy.deepcopy(m)
        mutate(tampered)
        _recompute_evidence(tampered)
        with pytest.raises(ManifestInvalidError):
            commit_stock(fd, tampered, ledger=ledger)
    finally:
        os.close(fd)


def test_legitimate_growth_of_counters_and_history_is_accepted(tmp_path):
    """⭐ 方向②：这些字段**正常往前走**必须照常放行，否则整条流水线动不了。

    没有这一条，一个「所有非生命周期字段都必须逐字不变」的过严实现也能让
    上面 9 档全绿 —— 而那会让第二只股根本提交不了。
    """
    d, fd = _staging(tmp_path)
    try:
        m = _rich()
        ledger = _committed(fd, m)
        grown = copy.deepcopy(m)
        grown["committed_bytes"] = 9_500_000                       # 累计增加
        grown["failures"][0]["attempts"] = 3                        # 重试次数增加
        grown["failures"].append({"stock_code": "600008.SH", "attempts": 1})
        grown["batches"].append({"n": 2})                           # 历史追加
        grown["inflight_rollbacks"]["1"] = 3                        # 遥测增加
        grown["inflight_rollbacks"]["2"] = 1
        grown = _with_more_stocks(grown)                            # 再拉一只股
        commit_stock(fd, grown, ledger=ledger)
        on = read_manifest(fd)
        assert on["committed_bytes"] == 9_500_000
        assert len(on["files"]) == 6 and len(on["batches"]) == 2
    finally:
        os.close(fd)


# ── B：崩溃恢复必须是**窄口**，不是旁路 ──────────────────────

def _multi_stock():
    m = _valid_manifest()
    for code, name, idx in [("600004.SH", "浦发银行", 1), ("600006.SH", "工商银行", 2)]:
        m["files"] += [_file_rec(code, name, "1m"), _file_rec(code, name, "daily")]
        m["pool_order"]["SH"].append({"code": code, "universe_idx": idx})
    m["cursor"] = {"SH": 3, "SZ": 1, "BJ": 0}
    return _recompute_evidence(m)


def test_recovery_cannot_wipe_stocks_outside_its_scope(tmp_path):
    """⭐⭐ [R9 high B] 声明「崩溃恢复」此前是**无限制**旁路。

    本机复现：一次「恢复」把所有市场的所有股票全清了、cursor 全归零，
    而 spec §4.4 恢复第③档只允许**删那一只在途的股**并把**该层** cursor
    退到它的 `universe_idx`。后果：已提交的 CSV 全部变成无主文件，
    整轮进度丢光，而账本结构上还是合法的。

    判别力：把范围描述符换回布尔旁路，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        ledger = _committed(fd, _multi_stock())
        wipe = _valid_manifest()
        wipe["pool_order"] = {"SH": [], "SZ": [], "BJ": []}
        wipe["files"] = []
        wipe["cursor"] = {"SH": 0, "SZ": 0, "BJ": 0}
        _recompute_evidence(wipe)
        with pytest.raises(ManifestInvalidError, match="范围|超出|只允许"):
            commit_stock(fd, wipe, ledger=ledger,
                         recovery=RecoveryScope(stock_code="600004.SH",
                                                market="SH", universe_idx=1))
    finally:
        os.close(fd)


def test_recovery_removes_exactly_the_inflight_stock(tmp_path):
    """⭐⭐ 方向②：spec 明写允许的那一次回退必须**跑得通**。

    §4.4 恢复第③档：只删该股的 files / pool_order 条目，
    并 `cursor[market] ← min(cursor, universe_idx)`。
    """
    d, fd = _staging(tmp_path)
    try:
        full = _multi_stock()
        ledger = _committed(fd, full)
        rolled = copy.deepcopy(full)
        rolled["files"] = [f for f in rolled["files"] if f["stock_code"] != "600004.SH"]
        rolled["pool_order"]["SH"] = [e for e in rolled["pool_order"]["SH"]
                                      if e["code"] != "600004.SH"]
        rolled["cursor"]["SH"] = 1
        _recompute_evidence(rolled)
        commit_stock(fd, rolled, ledger=ledger,
                     recovery=RecoveryScope(stock_code="600004.SH",
                                            market="SH", universe_idx=1))
        on = read_manifest(fd)
        assert {f["stock_code"] for f in on["files"]} == {"600000.SH", "000001.SZ",
                                                          "600006.SH"}
        assert on["cursor"]["SH"] == 1 and on["cursor"]["SZ"] == 1
    finally:
        os.close(fd)


def test_recovery_still_enforces_every_unrelated_invariant(tmp_path):
    """⭐ 恢复只放开「删那一只股」，**其余不变量照旧**（codex R9 原话）。

    这里在一次合法范围的恢复里顺手把 seed 换掉 —— 必须仍被拒。
    """
    d, fd = _staging(tmp_path)
    try:
        full = _multi_stock()
        ledger = _committed(fd, full)
        rolled = copy.deepcopy(full)
        rolled["files"] = [f for f in rolled["files"] if f["stock_code"] != "600004.SH"]
        rolled["pool_order"]["SH"] = [e for e in rolled["pool_order"]["SH"]
                                      if e["code"] != "600004.SH"]
        rolled["cursor"]["SH"] = 1
        rolled["seed"] = "别人的-seed"                      # 顺手夹带
        _recompute_evidence(rolled)
        with pytest.raises(ManifestInvalidError, match="seed"):
            commit_stock(fd, rolled, ledger=ledger,
                         recovery=RecoveryScope(stock_code="600004.SH",
                                                market="SH", universe_idx=1))
    finally:
        os.close(fd)


def test_recovery_scope_rejects_malformed_descriptors():
    """范围描述符本身在构造期就要挡住非法值（与本模块其它构造期校验同规格）。"""
    ok = dict(stock_code="600004.SH", market="SH", universe_idx=1)
    for k, bad in [("stock_code", "600004"), ("stock_code", 123),
                   ("market", "XX"), ("market", None),
                   ("universe_idx", -1), ("universe_idx", "1"),
                   ("universe_idx", True)]:
        with pytest.raises(ValueError):
            RecoveryScope(**dict(ok, **{k: bad}))
    with pytest.raises(ValueError, match="后缀|一致"):
        RecoveryScope(stock_code="600004.SH", market="SZ", universe_idx=1)


# ── C：解析器级异常 ──────────────────────────────────────────

def test_an_oversized_integer_is_rejected_as_a_manifest_error(tmp_path):
    """⭐ [R9 medium C] Python 3.11（CI 钉的版本）对超过 4300 位的整数
    在 `int()` 转换时抛**裸 `ValueError`**，而不是 `JSONDecodeError`。

    一份约 5 KB 的 manifest（远低于 64 MiB 上限）就能让读回口带着原始
    traceback 崩掉，`ManifestInvalidError` 那句恢复指引一个字都印不出来
    —— 与 S2-F9、S2-F10 是同一族：**守卫自己被它该抓的那种损坏弄坏了**。

    判别力：把 `except` 改回只接 `JSONDecodeError`，本条必红。
    """
    _d, fd = _staging(tmp_path, raw='{"manifest_version": ' + "9" * 5000 + "}")
    try:
        with pytest.raises(ManifestInvalidError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_a_deeply_nested_json_is_rejected_as_a_manifest_error(tmp_path):
    """同族：深嵌套 JSON 会撞递归上限抛 `RecursionError`（不是 ValueError）。"""
    _d, fd = _staging(tmp_path, raw="[" * 20000 + "]" * 20000)
    try:
        with pytest.raises(ManifestInvalidError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_recovery_cursor_may_only_go_to_the_declared_index(tmp_path):
    """⭐ 隔离「恢复的 cursor 只许退到 `min(cursor, universe_idx)`」这一条判据。

    这里删的股、删的池条目**都在声明范围内**（files / pool 两条判据都放行），
    只有 cursor 退过了头 —— 于是只剩 cursor 那条够得着。

    ⚠️ **`files` 那一侧的范围判据造不出专属档（如实登记）**：
    要让它单独触发，就得让 pool 判据放行，而账本自身的一致性规则（R21-F3）
    要求每个池条目恰配 1m + daily 两条文件记录 —— 少一边就先被读侧校验拒掉。
    这与前面 `_require_no_progress_rollback` 那条登记是**同一个结构性绑定**。

    判别力：把 cursor 的范围判据放宽成「声明了恢复就随便退」，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        full = _multi_stock()
        ledger = _committed(fd, full)
        rolled = copy.deepcopy(full)
        rolled["files"] = [f for f in rolled["files"] if f["stock_code"] != "600004.SH"]
        rolled["pool_order"]["SH"] = [e for e in rolled["pool_order"]["SH"]
                                      if e["code"] != "600004.SH"]
        rolled["cursor"]["SH"] = 0          # 声明的是 idx=1，却退到了 0
        _recompute_evidence(rolled)
        with pytest.raises(ManifestInvalidError, match="游标"):
            commit_stock(fd, rolled, ledger=ledger,
                         recovery=RecoveryScope(stock_code="600004.SH",
                                                market="SH", universe_idx=1))
    finally:
        os.close(fd)


def test_recovery_may_not_touch_another_markets_cursor(tmp_path):
    """⭐ 同族：恢复声明的是 SH 层，就不许顺手把 SZ 层的 cursor 也退回去。"""
    d, fd = _staging(tmp_path)
    try:
        full = _multi_stock()
        ledger = _committed(fd, full)
        rolled = copy.deepcopy(full)
        rolled["files"] = [f for f in rolled["files"] if f["stock_code"] != "600004.SH"]
        rolled["pool_order"]["SH"] = [e for e in rolled["pool_order"]["SH"]
                                      if e["code"] != "600004.SH"]
        rolled["cursor"]["SH"] = 1
        rolled["cursor"]["SZ"] = 0          # 顺手夹带别的层
        _recompute_evidence(rolled)
        with pytest.raises(ManifestInvalidError, match="SZ"):
            commit_stock(fd, rolled, ledger=ledger,
                         recovery=RecoveryScope(stock_code="600004.SH",
                                                market="SH", universe_idx=1))
    finally:
        os.close(fd)


# ═════════════════════════════════════════════════════════════
# codex R10：两条 high，**两条都是我 R9 那次修复自己引入的**
#
# A 我那条「attempts 只增不减」把 spec 自己的**重试成功**路径堵死了
#   （§4.4:350 + O2-F14 原文：「重试成功即把该条目移出 failures 并计入 batches」）
#   —— 又一次修过头，而且是方向②没测到的那一半：我为「增长」配了放行档，
#   **没为「合法的移除」配**。
# B 我那些守卫写成 `if isinstance(旧) and isinstance(新) …`，于是**类型不符或
#   字段缺席时守卫被跳过**而不是拒绝 —— 「对坏输入要健壮」被我写成了
#   「对坏输入就放行」。⚠️ 这是 S2-F9 那条纪律的**反向陷阱**。
# ═════════════════════════════════════════════════════════════


def _retry_succeeded(m):
    """把 600004.SH 从 failures 里移出，并给它补上「成功」的证据。"""
    t = copy.deepcopy(m)
    t["files"] += [_file_rec("600004.SH", "浦发银行", "1m"),
                   _file_rec("600004.SH", "浦发银行", "daily")]
    t["pool_order"]["SH"].append({"code": "600004.SH", "universe_idx": 1})
    t["cursor"]["SH"] = 2
    t["failures"] = [f for f in t["failures"] if f["stock_code"] != "600004.SH"]
    return _recompute_evidence(t)


def test_a_successfully_retried_stock_may_leave_the_failure_ledger(tmp_path):
    """⭐⭐ [R10 high A] 方向②：spec 明写「**重试成功即把该条目移出 `failures`**」
    （§4.4:350 与 O2-F14）。我那条「attempts 只增不减」把这条路堵死了 ——
    于是一个只是**瞬时**失败过的候选**永远回不到池子里**，池子凭空缩水，
    最终可能报出假的「池穷尽 / 达不到地板」，而那是要记到市场账上的结论。

    判别力：把「移出必须自证成功」那一支删掉（退回一律拒），本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        m = _valid_manifest(failures=[{"stock_code": "600004.SH",
                                       "universe_idx": 1, "attempts": 1}])
        ledger = _committed(fd, m)
        commit_stock(fd, _retry_succeeded(m), ledger=ledger)
        on = read_manifest(fd)
        assert on["failures"] == []
        assert any(e["code"] == "600004.SH" for e in on["pool_order"]["SH"])
    finally:
        os.close(fd)


def test_a_failure_entry_may_not_vanish_without_proof_of_success(tmp_path):
    """⭐ 与上一条配对：**只有自证成功**才准移出。

    没有这一条，「移出一律放行」的实现也能让上一条绿 —— 而那正是
    「重试次数被清零、候选被复活」那个洞换了个形状。
    自证 = 该股在 `pool_order` 里有锚点条目、且 `files` 里恰好两条记录。

    ⚠️ **「恰好两条记录」那半边造不出专属档（如实登记，本片第三次撞同一个耦合）**：
    要单独触发它，就得构造「池里有该股、files 却不足两条」——而那本身就是一份
    **非法账本**（R21-F3），落盘前的读侧校验会先把它拒掉，走不到这条判据。
    与 `_require_no_progress_rollback` 里 files/pool 那两处登记同源。
    """
    d, fd = _staging(tmp_path)
    try:
        m = _valid_manifest(failures=[{"stock_code": "600004.SH",
                                       "universe_idx": 1, "attempts": 1}])
        ledger = _committed(fd, m)
        sneaky = copy.deepcopy(m)
        sneaky["failures"] = []            # 凭空移出，没有任何成功证据
        _recompute_evidence(sneaky)
        with pytest.raises(ManifestInvalidError, match="failures"):
            commit_stock(fd, sneaky, ledger=ledger)
    finally:
        os.close(fd)


@pytest.mark.parametrize("label,mutate", [
    ("committed_bytes 整个删掉", lambda t: t.pop("committed_bytes")),
    ("committed_bytes 换成字符串", lambda t: t.__setitem__("committed_bytes", "0")),
    ("committed_bytes 换成 None", lambda t: t.__setitem__("committed_bytes", None)),
    ("batches 整个删掉", lambda t: t.pop("batches")),
    ("batches 换成等长但内容不同", lambda t: t.__setitem__("batches", [{"n": 999}])),
    ("batches 换成非列表", lambda t: t.__setitem__("batches", "x")),
    ("inflight_rollbacks 整个删掉", lambda t: t.pop("inflight_rollbacks")),
    ("inflight_rollbacks 换成非字典", lambda t: t.__setitem__("inflight_rollbacks", [])),
])
def test_a_monotonic_field_may_not_be_erased_by_omission_or_wrong_type(
        tmp_path, label, mutate):
    """⭐⭐ [R10 high B] 守卫此前写成「两边类型都对才比」——于是**字段缺席或
    类型不对时守卫被跳过**，改写照样落盘。而这些都是**扩展字段**，
    读侧校验（`validate_manifest`）根本不要求它们存在，兜不住。

    「对坏输入要健壮」（S2-F9）指的是**别崩**，**不是别拦**。
    正确姿势：**上一份里有的单调字段，新的必须仍在、类型仍对、且满足转移规则**。

    ⚠️ `batches` 还要求**旧列表是新列表的前缀**——只比长度的话，
    一次等长改写就能把历史悄悄换掉（本机复现过）。

    判别力：把对应那条改回「类型不符就跳过」，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        m = _valid_manifest(committed_bytes=9_000_000, batches=[{"n": 1}],
                            inflight_rollbacks={"1": 2})
        ledger = _committed(fd, m)
        tampered = copy.deepcopy(m)
        mutate(tampered)
        _recompute_evidence(tampered)
        with pytest.raises(ManifestInvalidError):
            commit_stock(fd, tampered, ledger=ledger)
    finally:
        os.close(fd)


def test_batches_may_grow_by_appending(tmp_path):
    """方向②：`batches` 追加必须放行（前缀不变即可），否则历史永远记不下去。"""
    d, fd = _staging(tmp_path)
    try:
        m = _valid_manifest(batches=[{"n": 1}])
        ledger = _committed(fd, m)
        grown = copy.deepcopy(m)
        grown["batches"].append({"n": 2})
        _recompute_evidence(grown)
        commit_stock(fd, grown, ledger=ledger)
        assert read_manifest(fd)["batches"] == [{"n": 1}, {"n": 2}]
    finally:
        os.close(fd)


# ═════════════════════════════════════════════════════════════
# codex R11：1 high + 1 medium
#   A 恢复的两半（删条目 / 退游标）我是**各自独立**判的，而 spec §4.4 恢复第③档
#     是**一次耦合的转移**。删了却不退 → 那只股永远不会被重拉、池子静默缩水。
#   B §4.5:785（O4-F2）明写「per-stock 提交时这两个字段的取值**必须写死**：
#     `source_verification: "partial"` + evidence `{"level":"partial","passes":[]}`」
#     —— 我实现时**漏了这条**，调用方的 `full` 标签被原样写盘。
# ═════════════════════════════════════════════════════════════


def _scope(idx=1):
    return RecoveryScope(stock_code="600004.SH", market="SH", universe_idx=idx)


def _drop_stock(m, code="600004.SH"):
    t = copy.deepcopy(m)
    t["files"] = [f for f in t["files"] if f["stock_code"] != code]
    for mk in ("SH", "SZ", "BJ"):
        t["pool_order"][mk] = [e for e in t["pool_order"][mk] if e["code"] != code]
    return t


def test_recovery_removing_a_stock_must_also_rewind_the_cursor(tmp_path):
    """⭐⭐ [R11 high A] 恢复是**一次耦合的转移**：删该股条目 **且**
    `cursor[market] ← min(cursor, universe_idx)`（spec §4.4 恢复第③档）。

    我把两半各自独立判了 → 「删了条目、游标原样停在后面」照样通过。
    后果：那只股**永远不会被重新拉取**（游标已经走过它），池子静默缩水，
    最终可能报出假的池穷尽 —— 正是恢复流程本来要消灭的那个状态。

    判别力：把耦合检查删掉，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        full = _multi_stock()
        ledger = _committed(fd, full)
        bad = _drop_stock(full)          # cursor 原样不动
        _recompute_evidence(bad)
        with pytest.raises(ManifestInvalidError, match="游标|cursor"):
            commit_stock(fd, bad, ledger=ledger, recovery=_scope())
    finally:
        os.close(fd)


def test_recovery_may_not_rewind_the_cursor_without_removing_the_stock(tmp_path):
    """⭐ 反方向：只退游标、不删该股条目，也超出了恢复的确切范围。

    判别力：把「未删除时不许退游标」那半删掉，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        full = _multi_stock()
        ledger = _committed(fd, full)
        only_rewind = copy.deepcopy(full)
        only_rewind["cursor"]["SH"] = 1        # 退了，但条目都还在
        _recompute_evidence(only_rewind)
        with pytest.raises(ManifestInvalidError, match="游标|cursor"):
            commit_stock(fd, only_rewind, ledger=ledger, recovery=_scope())
    finally:
        os.close(fd)


def test_recovery_scope_must_be_anchored_in_the_frozen_universe(tmp_path):
    """⭐ [R11 high A 同族] 声明的 `universe_idx` 必须在**冻结名单**里确实是这只股。

    spec 对在途标记的形状校验就要求 `source_snapshot.universe[market][idx] == code`
    ——恢复范围是同一件事，否则一个错的下标能让 cursor 退到任意位置。
    ⚠️ 构造期查不了这个（`RecoveryScope` 手里没有 manifest），只能在提交时查。

    判别力：删掉锚点核对，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        full = _multi_stock()
        ledger = _committed(fd, full)
        bad = _drop_stock(full)
        bad["cursor"]["SH"] = 0
        _recompute_evidence(bad)
        with pytest.raises(ManifestInvalidError, match="锚点|冻结|universe"):
            # 冻结名单里 SH[0] 是 600000.SH，不是 600004.SH
            commit_stock(fd, bad, ledger=ledger, recovery=_scope(idx=0))
    finally:
        os.close(fd)


def test_recovery_of_a_never_committed_stock_needs_no_removal(tmp_path):
    """方向②：恢复第①档（manifest 里该股无记录，崩在提交之前）——
    什么都不用删、`cursor` 也不推进，必须照常提交（它要记 inflight_rollbacks）。

    没有这一条，一个「声明了恢复就**必须**删点什么」的过严实现也能让上面几条绿，
    而那会让第①档根本提交不了。
    """
    d, fd = _staging(tmp_path)
    try:
        m = _valid_manifest(inflight_rollbacks={"1": 1})
        ledger = _committed(fd, m)
        again = copy.deepcopy(m)
        again["inflight_rollbacks"]["1"] = 2      # 只是遥测 +1
        _recompute_evidence(again)
        commit_stock(fd, again, ledger=ledger, recovery=_scope())
        assert read_manifest(fd)["inflight_rollbacks"]["1"] == 2
    finally:
        os.close(fd)


# ── B：per-stock 提交的校验级别写死 partial ──────────────────

def test_commit_stock_always_publishes_partial_verification(tmp_path):
    """⭐⭐ [R11 medium B] spec §4.5:785（O4-F2）明写 per-stock 提交时
    `source_verification` / `source_verification_evidence` **取值写死**：
    `partial` + 空 passes。

    不写死的后果（codex 的场景）：一棵干净 staging 用 `--skip-existing-verify`
    起跑，一次「只失败、没新增文件」的提交把上一次的 `full` 存根**原样写回**
    （它结构上仍然合法）；若进程随后崩在收尾之前，**磁盘上那份账本就一直
    声称自己是 full 级**，而本次运行明确跳过了校验。

    判别力：把这两行投影删掉，本条必红。
    """
    d, fd = _staging(tmp_path)
    try:
        m = _valid_manifest()                       # 调用方那份写着 full + 两趟
        assert m["source_verification"] == "full"
        ledger = begin_run(fd)
        commit_stock(fd, m, ledger=ledger)
        on = read_manifest(fd)
        assert on["source_verification"] == "partial"
        assert on["source_verification_evidence"] == {"level": "partial", "passes": []}
    finally:
        os.close(fd)


def test_commit_final_still_publishes_the_real_verification_level(tmp_path):
    """方向②：**收尾提交**才是定级的地方，不得被一并写死成 partial。

    没有这一条，「两个入口都写死 partial」的实现也能让上一条绿 ——
    而那会让 full / snapshot 级永远发布不出来，出货资格永远拿不到。
    """
    d, fd = _staging(tmp_path)
    try:
        ledger = begin_run(fd)
        commit_stock(fd, _valid_manifest(), ledger=ledger)
        written = commit_final(fd, _valid_manifest(), outcome=clean_finish(),
                               ledger=ledger)
        assert written["source_verification"] == "full"
        assert len(read_manifest(fd)["source_verification_evidence"]["passes"]) == 2
    finally:
        os.close(fd)

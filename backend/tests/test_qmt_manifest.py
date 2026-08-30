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
    """
    m = _valid_manifest(stopped_reason=reason, fetch_fatal_error=_fatal())
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
    for bad in ("staging_recheck_failed", "max_bytes", "whatever", ""):
        f = _fatal()
        f["kind"] = bad
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                stopped_reason="staging_path_escape", fetch_fatal_error=f))


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
        _valid_manifest(stopped_reason="source_path_escape",
                        fetch_fatal_error=_fatal()),
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

from qmt_fsroot import open_root, PathEscapeError
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


def test_commit_stock_writes_a_readable_manifest(tmp_path):
    """正向放行档：写出去的必须读得回来。"""
    m = _valid_manifest()
    _d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, m, lifecycle={})
        assert read_manifest(fd) == m
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
    snap = lifecycle_snapshot(poisoned)

    # 调用方「不小心」把 fatal 洗掉了
    del poisoned["fetch_fatal_error"]
    poisoned["stopped_reason"] = "max_bytes"

    _d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, poisoned, lifecycle=snap)
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
        commit_stock(fd, poisoned, lifecycle={})       # 启动时磁盘上是干净的
        assert "stopped_reason" not in read_manifest(fd)
    finally:
        os.close(fd)


def test_commit_stock_refuses_a_lifecycle_carrying_foreign_keys(tmp_path):
    """⭐ 把「剥 + 塞」这条结构闭合掉：`lifecycle` 只许携带生命周期三字段。

    不拦的话 `payload.update(lifecycle)` 是一条通往**任意顶层键**的走私通道 ——
    `lifecycle={"files": []}` 就能在 per-stock 提交里把实拷清单清空，
    而这个入口自称「够不到生命周期字段」，读者会以为它什么都动不了。

    双向各问一次：①畸形（含任何非生命周期键）必须被拒；
    ②合法状态不得被判死 —— `lifecycle_snapshot()` 的输出恒为三字段的子集，
    空 dict 也是子集，上面三条正向/反向档就是这一侧的证据。
    """
    _d, fd = _staging(tmp_path)
    try:
        with pytest.raises(ValueError, match="lifecycle"):
            commit_stock(fd, _valid_manifest(), lifecycle={"files": []})
        assert not (_d / MANIFEST_NAME).exists()      # 拒绝时一个字节都不写
    finally:
        os.close(fd)


def test_commit_stock_preserves_unknown_top_level_keys(tmp_path):
    """S3/S4 的 failures / batches 等经 per-stock 提交流转，不得被剥掉（O4-F10）。"""
    m = _valid_manifest(failures=[{"stock_code": "600004.SH", "attempts": 1}],
                        committed_bytes=123)
    _d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, m, lifecycle={})
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
        commit_stock(fd, _valid_manifest(), lifecycle={})
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
        commit_stock(fd, _valid_manifest(), lifecycle={})
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
    out = escape_stop(kind="source_path_escape",
                      relative_path="1分钟K线_前复权/x.csv",
                      component="1分钟K线_前复权", errno="ENOTDIR")
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape", secondary="max_bytes"), out)
    assert got == {
        "stopped_reason": "source_path_escape",
        "fetch_fatal_error": {"kind": "source_path_escape",
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

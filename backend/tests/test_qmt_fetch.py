# backend/tests/test_qmt_fetch.py
"""QMT 4b 切片 S4a · Task 1 + Task 2 + Task 3。

Task 1：字节预算 + 单文件流式拷贝，绑定契约 D3（源侧叶子非普通文件）与 D7
（逐块记账、回滚退还）。
Task 2：幂等四象限判据 `classify_target`，绑定契约 D2（staging 目标非普通文件一律
拒绝覆盖，符号链接除外）与 D4 第 1 条（「相符」判据含 `S_ISREG`）。
Task 3：在途标记 + 单股事务编排 `copy_stock`，绑定契约 D1（两条路径的前置校验）、
D4 第 2 条（任何有记录的格都要比对）、D5（不符即终止，比对早于落地）、
D6（标记写下后只有两条出路）、D7（`committed_bytes` 累计语义）、
D8（跳过由四象限承担）。
"""
from __future__ import annotations

import contextlib
import errno
import hashlib
import json
import os
import signal
import socket
import stat

import pytest

import qmt_fetch
import qmt_fsroot
from qmt_fetch import (
    INFLIGHT,
    PART,
    TARGET_COPY,
    TARGET_RECOPY,
    TARGET_SKIP,
    TARGET_UNTRACKED,
    ByteBudget,
    CopyResult,
    MaxBytesExhausted,
    RollbackIncomplete,
    RunTerminated,
    SourceChangedMidRun,
    StockCopyFailed,
    build_inflight_marker,
    classify_target,
    copy_one,
    copy_stock,
)
from qmt_fsroot import PathEscapeError, atomic_write_json, open_root
from qmt_manifest import (
    MANIFEST_NAME,
    PERIODS,
    RecoveryScope,
    begin_run,
    commit_stock,
    read_manifest,
)
from qmt_normalize import QmtSchemaError
from qmt_pool import Slot


# ── fixtures ─────────────────────────────────────────────────────

@pytest.fixture
def roots(tmp_path):
    """一对空的 (源, staging) 根，各自 `open_root` 拿到的 fd 由本 fixture 负责关。"""
    src_path = tmp_path / "src"
    stg_path = tmp_path / "stg"
    src_path.mkdir()
    stg_path.mkdir()
    src_fd = open_root(str(src_path))
    stg_fd = open_root(str(stg_path))
    try:
        yield src_fd, stg_fd, src_path, stg_path
    finally:
        os.close(src_fd)
        os.close(stg_fd)


def _put_source_file(src_path, rel: str, data: bytes) -> None:
    p = src_path / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)


# ── 异常三族：互不相交 ───────────────────────────────────────────

def test_exception_families_are_disjoint():
    assert issubclass(MaxBytesExhausted, RunTerminated)
    assert not issubclass(MaxBytesExhausted, StockCopyFailed)
    assert not issubclass(StockCopyFailed, RunTerminated)
    assert not issubclass(RunTerminated, StockCopyFailed)


# ── ByteBudget：事前早拒 / 逐块扣减 / 退还 ───────────────────────

def test_byte_budget_precheck_rejects_before_charging():
    budget = ByteBudget(limit=100, used=90)
    with pytest.raises(MaxBytesExhausted):
        budget.precheck(20)
    assert budget.used == 90          # 早拒不扣账


def test_byte_budget_charge_boundary_is_inclusive():
    budget = ByteBudget(limit=10, used=0)
    budget.charge(10)                 # 恰好用满：允许（判据是 `>`，不是 `>=`）
    assert budget.used == 10
    with pytest.raises(MaxBytesExhausted):
        budget.charge(1)
    assert budget.used == 10          # 拒绝时不改账


def test_byte_budget_refund_rejects_over_refund():
    budget = ByteBudget(limit=None, used=5)
    with pytest.raises(ValueError):
        budget.refund(6)


def test_byte_budget_unlimited_never_rejects():
    budget = ByteBudget(limit=None)
    budget.precheck(10 ** 12)
    budget.charge(10 ** 12)
    assert budget.used == 10 ** 12


# ── copy_one 正路 ────────────────────────────────────────────────

def test_copy_one_streams_hashes_and_lands_part(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    data = b"hello qmt 4b s4a" * 5000
    rel = "1m/600000.SH_浦发银行_1分钟K线_前复权.csv"
    _put_source_file(src_path, rel, data)

    budget = ByteBudget(limit=None)
    result = copy_one(src_fd, stg_fd, rel, budget)

    assert isinstance(result, CopyResult)
    assert result.n_bytes == len(data)
    assert result.sha256 == hashlib.sha256(data).hexdigest()
    assert budget.used == len(data)
    assert (stg_path / (rel + PART)).read_bytes() == data


def test_copy_one_precheck_rejects_via_stat_before_touching_disk(roots):
    # 事前 stat 早拒：--max-bytes 小于文件大小时，压根不该打开 staging 侧目的文件。
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_big.csv"
    _put_source_file(src_path, rel, b"z" * 1000)

    budget = ByteBudget(limit=500)
    with pytest.raises(RunTerminated):
        copy_one(src_fd, stg_fd, rel, budget)
    assert budget.used == 0
    assert not (stg_path / (rel + PART)).exists()


def test_copy_one_charge_enforces_independently_of_precheck(roots, monkeypatch):
    # `precheck` 用 `stat` 量到的大小早拒，但源挂在**正在导出**的 SMB 上时那个大小
    # 可能是陈旧的——真读出来的字节比 `stat` 当时更多。`charge` 必须独立再守一遍，
    # 不能假定「precheck 过了，逐块扣账就一定不会拒」。用一个「读出来的字节比
    # `stat` 量到的还多」的桩模拟这种源文件仍在增长的场面。
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_growing.csv"
    _put_source_file(src_path, rel, b"w" * 64)            # `stat` 量到的是 64 字节
    monkeypatch.setattr(qmt_fetch, "_CHUNK", 64)

    real_read = os.read
    call_count = {"n": 0}

    def growing_read(fd, n):
        call_count["n"] += 1
        if call_count["n"] <= 3:
            return b"g" * 64      # 比 `stat` 当时量到的还多读出两块
        return real_read(fd, n)

    monkeypatch.setattr(os, "read", growing_read)

    budget = ByteBudget(limit=100)   # 64 能通过 precheck；累计到 128 时 charge 该拒
    with pytest.raises(MaxBytesExhausted):
        copy_one(src_fd, stg_fd, rel, budget)
    assert budget.used == 0          # 已扣的第 1 块（64）也退还了


# ── D3：源侧叶子非普通文件 ⇒ fetch_missing_file ─────────────────

def test_copy_one_source_leaf_missing_with_directory_present_is_fetch_missing_file(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    (src_path / "1m").mkdir(parents=True, exist_ok=True)   # 目录在，叶子文件不在
    budget = ByteBudget(limit=None)
    with pytest.raises(StockCopyFailed) as ei:
        copy_one(src_fd, stg_fd, "1m/600000.SH_never_exported.csv", budget)
    assert ei.value.reason == "fetch_missing_file"
    assert budget.used == 0


def test_copy_one_source_whole_directory_missing_is_also_fetch_missing_file(roots):
    # 与上一条互补：整段 period 目录都没导出过（不是「目录在、叶子不在」），
    # 走的是 `parent_fd_under` 那条 FileNotFoundError，不是 `open_regular_probe` 那条。
    src_fd, stg_fd, src_path, stg_path = roots
    budget = ByteBudget(limit=None)
    with pytest.raises(StockCopyFailed) as ei:
        copy_one(src_fd, stg_fd, "1m/600000.SH_never_exported.csv", budget)
    assert ei.value.reason == "fetch_missing_file"
    assert budget.used == 0


def test_copy_one_source_fifo_is_fetch_missing_file(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_fifo.csv"
    fifo_path = src_path / rel
    fifo_path.parent.mkdir(parents=True, exist_ok=True)
    os.mkfifo(str(fifo_path))

    budget = ByteBudget(limit=None)
    with pytest.raises(StockCopyFailed) as ei:
        copy_one(src_fd, stg_fd, rel, budget)
    assert ei.value.reason == "fetch_missing_file"
    assert budget.used == 0


def test_copy_one_source_socket_is_fetch_missing_file_but_permission_error_is_not(
    roots, monkeypatch,
):
    # 源侧是 socket：`open(2)` 直接失败（macOS ENOTSUP，别处 EOPNOTSUPP/ENXIO），
    # 回头 lstat 判非普通 → `fetch_missing_file`。
    src_fd, stg_fd, src_path, stg_path = roots
    sub = src_path / "1m"
    sub.mkdir(parents=True, exist_ok=True)
    leaf_name = "600000.SH_sock.csv"
    rel = f"1m/{leaf_name}"

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    # `AF_UNIX` 路径上限约 104 字节，pytest 的 tmp_path 本身经常就超了——
    # 切进目标目录再用相对名绑定（与 test_qmt_manifest.py 里那条同规格）。
    monkeypatch.chdir(sub)
    try:
        sock.bind(leaf_name)
        budget = ByteBudget(limit=None)
        with pytest.raises(StockCopyFailed) as ei:
            copy_one(src_fd, stg_fd, rel, budget)
        assert ei.value.reason == "fetch_missing_file"
        assert budget.used == 0
    finally:
        sock.close()

    # ⚠️ 判别力所在：权限错误（`EACCES`，打桩造，因为真 chmod 000 在以 root 跑的 CI
    # 里会被无视）不得被同一条 `except` 混进 `fetch_missing_file` 这一族。
    def fake_probe(dir_fd, name, *, flags, mode=0o600):
        raise PermissionError(errno.EACCES, "打桩：模拟权限错误")

    monkeypatch.setattr(qmt_fetch, "open_regular_probe", fake_probe)
    budget2 = ByteBudget(limit=None)
    with pytest.raises(PermissionError):
        copy_one(src_fd, stg_fd, rel, budget2)
    assert budget2.used == 0


# ── D7：连续三次失败后预算与从未尝试过时相同（含「拷到一半抛异常」）──

def test_budget_after_three_consecutive_failures_matches_untried(roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    rel_missing = "1m/600000.SH_missing.csv"
    rel_flaky = "1m/600000.SH_flaky.csv"

    (src_path / "1m").mkdir(parents=True, exist_ok=True)   # 目录在，叶子文件不在

    budget = ByteBudget(limit=None, used=100)   # 模拟运行里已有其它股花掉的 100 字节
    baseline = budget.used

    # 第 1 次：文件缺失（D3）——根本没开始扣账。
    with pytest.raises(StockCopyFailed) as ei1:
        copy_one(src_fd, stg_fd, rel_missing, budget)
    assert ei1.value.reason == "fetch_missing_file"
    assert budget.used == baseline

    # 第 2 次：拷到一半抛异常（模拟 SMB 断线 EIO）——真扣过账、也要真退还。
    # 只测「文件缺失」会漏掉这条路：missing-file 从不给 budget 记过账，
    # 退还逻辑在那种场景下即使是空实现也能巧合地通过。
    _put_source_file(src_path, rel_flaky, b"x" * 320)   # 5 块 × 64
    monkeypatch.setattr(qmt_fetch, "_CHUNK", 64)
    real_write = os.write
    call_count = {"n": 0}

    def flaky_write(fd, buf):
        call_count["n"] += 1
        if call_count["n"] == 2:                         # 第 2 块写到一半时断线
            raise OSError(errno.EIO, "打桩：模拟 SMB 断线")
        return real_write(fd, buf)

    monkeypatch.setattr(os, "write", flaky_write)
    with pytest.raises(OSError):
        copy_one(src_fd, stg_fd, rel_flaky, budget)
    assert budget.used == baseline, "拷到一半抛异常后，已扣的账必须原样退还"
    monkeypatch.setattr(os, "write", real_write)

    # 第 3 次：文件缺失（D3），再来一遍。
    with pytest.raises(StockCopyFailed) as ei3:
        copy_one(src_fd, stg_fd, rel_missing, budget)
    assert ei3.value.reason == "fetch_missing_file"
    assert budget.used == baseline


# ── 落地复算不是恒等式：写出去的字节与读回来的不同 ⇒ fetch_copy_hash_mismatch ──

def test_copy_one_detects_landed_part_diverging_from_source_hash(roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_truncated.csv"
    data = b"y" * 4096
    _put_source_file(src_path, rel, data)

    real_write = os.write

    def lying_write(fd, buf):
        # 打桩「少写一段」：只真的写出 data 的前 n-1 字节，却向调用方谎报「整段都写完了」，
        # 让 `_write_all` 的重试循环以为已经写完——落地的 `.part` 因此比源少一字节。
        n = len(buf)
        if n > 0:
            real_write(fd, buf[: n - 1])
        return n

    monkeypatch.setattr(os, "write", lying_write)

    budget = ByteBudget(limit=None)
    with pytest.raises(StockCopyFailed) as ei:
        copy_one(src_fd, stg_fd, rel, budget)
    assert ei.value.reason == "fetch_copy_hash_mismatch"
    assert budget.used == 0, "落地复算不符也要退还本次已扣的账"


# ══════════════════════════════════════════════════════════════════
# Task 2 · 幂等四象限判据 `classify_target`（契约 D2、D4 第 1 条）
# ══════════════════════════════════════════════════════════════════

def _put_target_file(stg_path, rel: str, data: bytes) -> None:
    p = stg_path / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)


# ── 四象限基本覆盖：目标不存在两列都是 copy，目标存在按有无记录分叉 ──

def test_classify_target_no_record_no_target_is_copy(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    verdict = classify_target(stg_fd, "1m/600000.SH_new.csv", None)
    assert verdict == TARGET_COPY


def test_classify_target_has_record_but_target_absent_is_copy(roots):
    # D4 第 2 条（「有记录 × 目标不存在」也要比对）交 Task 3——本函数只是判据，
    # 不做比对，故这一格只回答「目标在不在」，答案与无记录那一列相同。
    src_fd, stg_fd, src_path, stg_path = roots
    record = {"bytes": 123, "sha256": "0" * 64}
    verdict = classify_target(stg_fd, "1m/600000.SH_gone.csv", record)
    assert verdict == TARGET_COPY


def test_classify_target_no_record_target_exists_is_untracked(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_orphan.csv"
    _put_target_file(stg_path, rel, b"orphan data")
    verdict = classify_target(stg_fd, rel, None)
    assert verdict == TARGET_UNTRACKED


def test_classify_target_matching_record_is_skip(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_ok.csv"
    data = b"intact content" * 20
    _put_target_file(stg_path, rel, data)
    record = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    verdict = classify_target(stg_fd, rel, record)
    assert verdict == TARGET_SKIP


def test_classify_target_size_and_hash_mismatch_is_recopy(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_stale.csv"
    _put_target_file(stg_path, rel, b"short")
    record = {"bytes": 9999, "sha256": "0" * 64}
    verdict = classify_target(stg_fd, rel, record)
    assert verdict == TARGET_RECOPY


# ── R2-F3 回归钉：同尺寸不同内容必须重拷，不得因字节数先对上就跳过哈希比对 ──

def test_classify_target_same_size_different_content_is_recopy_not_skip(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_tampered.csv"
    original = b"A" * 200
    tampered = b"B" * 200                      # 与 original **同尺寸**、内容不同
    assert len(original) == len(tampered)
    _put_target_file(stg_path, rel, tampered)
    record = {"bytes": len(original), "sha256": hashlib.sha256(original).hexdigest()}
    verdict = classify_target(stg_fd, rel, record)
    assert verdict == TARGET_RECOPY, "同尺寸不同内容必须判重拷，不得因字节数相符就跳过哈希比对"


# ── D2：staging 目标非普通文件一律拒绝覆盖，不按有无记录分叉 ──
# 「记录的 bytes 恰等于那个非普通对象的 st_size」是关键构造：若实现忘了先查
# S_ISREG、直接拿字节数与记录比对，这两档会被误判成 `skip`（字节数对上）
# 甚至更糟；只有先查 S_ISREG 才会在字节数相符的情况下仍然判 `untracked_target_file`。

def test_classify_target_directory_with_record_matching_st_size_is_untracked(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_dir.csv"
    target_dir = stg_path / rel
    target_dir.mkdir(parents=True)
    actual_size = target_dir.stat().st_size
    record = {"bytes": actual_size, "sha256": "0" * 64}   # 字节数恰好相符
    verdict = classify_target(stg_fd, rel, record)
    assert verdict == TARGET_UNTRACKED


def test_classify_target_fifo_with_record_matching_st_size_is_untracked(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_fifo.csv"
    target = stg_path / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    os.mkfifo(str(target))
    actual_size = os.stat(str(target)).st_size
    record = {"bytes": actual_size, "sha256": "0" * 64}   # 字节数恰好相符
    verdict = classify_target(stg_fd, rel, record)
    assert verdict == TARGET_UNTRACKED


# ── 符号链接叶子必须走路径逃逸（整次致命），不得落进拒绝覆盖那一档 ──

def test_classify_target_symlinked_leaf_escapes_not_untracked(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    real = stg_path / "1m" / "600000.SH_real.csv"
    real.parent.mkdir(parents=True, exist_ok=True)
    real.write_bytes(b"data")
    link = stg_path / "1m" / "600000.SH_link.csv"
    link.symlink_to(real)

    with pytest.raises(PathEscapeError) as ei:
        classify_target(stg_fd, "1m/600000.SH_link.csv", None)
    assert ei.value.errno == errno.ELOOP


# ── 判据对任意坏输入安全：记录字段缺失 / 类型不对 / 不可哈希类型一律拒绝 ──

def test_classify_target_rejects_record_missing_bytes_field(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    with pytest.raises(TypeError):
        classify_target(stg_fd, "1m/whatever.csv", {"sha256": "0" * 64})


def test_classify_target_rejects_record_wrong_type_for_bytes(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    with pytest.raises(TypeError):
        classify_target(stg_fd, "1m/whatever.csv", {"bytes": "100", "sha256": "0" * 64})


def test_classify_target_rejects_record_unhashable_sha256(roots):
    # `sha256` 传成一个不可哈希类型（list）——不是「类型对但值坏」，
    # 必须在能被 `==` 静默吞掉之前就被截住。
    src_fd, stg_fd, src_path, stg_path = roots
    with pytest.raises(TypeError):
        classify_target(stg_fd, "1m/whatever.csv", {"bytes": 100, "sha256": ["not", "a", "str"]})


def test_classify_target_rejects_non_dict_record(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    with pytest.raises(TypeError):
        classify_target(stg_fd, "1m/whatever.csv", "not-a-dict")


# ── fix round 1：目标 fd 不得泄漏（覆盖普通文件 / 目录 / FIFO 三个分支）──
# `classify_target` 在 ~400 只股的循环里每股最多调两次；三个分支共用同一处
# `finally: if fd is not None: os.close(fd)`，泄漏会在真实运行里累积到撞上
# 进程 fd 上限。判据与 `test_qmt_fsroot.py` 的
# `test_open_under_does_not_leak_intermediate_fds` /
# `test_parent_fd_under_does_not_leak_intermediate_fds` 同规格：
# `len(os.listdir("/dev/fd"))` 前后差值须落在 listdir 自身抖动的范围内。

def test_classify_target_does_not_leak_target_fd_across_repeated_calls(roots):
    src_fd, stg_fd, src_path, stg_path = roots

    rel_regular = "1m/600000.SH_regular.csv"
    data = b"leak-check" * 10
    _put_target_file(stg_path, rel_regular, data)
    record_regular = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}

    rel_dir = "1m/600000.SH_dir.csv"
    (stg_path / rel_dir).mkdir(parents=True)
    record_dir = {"bytes": (stg_path / rel_dir).stat().st_size, "sha256": "0" * 64}

    rel_fifo = "1m/600000.SH_fifo.csv"
    fifo_path = stg_path / rel_fifo
    fifo_path.parent.mkdir(parents=True, exist_ok=True)
    os.mkfifo(str(fifo_path))
    record_fifo = {"bytes": os.stat(str(fifo_path)).st_size, "sha256": "0" * 64}

    before = len(os.listdir("/dev/fd"))
    for _ in range(50):
        assert classify_target(stg_fd, rel_regular, record_regular) == TARGET_SKIP
        assert classify_target(stg_fd, rel_dir, record_dir) == TARGET_UNTRACKED
        assert classify_target(stg_fd, rel_fifo, record_fifo) == TARGET_UNTRACKED
    after = len(os.listdir("/dev/fd"))
    assert after - before <= 2, f"目标 fd 疑似泄漏：调用前 {before} 个，调用后 {after} 个"


# ── fix round 1：中间目录分量是符号链接，同样必须整次致命，不得降级 ──
# 叶子符号链接已有专门钉子（见上）；`parent_fd_under` 走中间分量时同样是
# 逐段无跟随，中间分量是符号链接会先一步撞 ENOTDIR ⇒ `PathEscapeError`。
# 这一档目前完全由被合并的 `qmt_fsroot` 原语实现——本测试钉的是
# `classify_target` 不捕获它、原样传播，若日后有人重实现 `classify_target`
# 时绕开了那个原语，这里会先变红。

def test_classify_target_symlinked_intermediate_component_escapes_not_untracked(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    outside = stg_path.parent / "outside_1m_component"
    outside.mkdir()
    (stg_path / "1m").symlink_to(outside)

    with pytest.raises(PathEscapeError) as ei:
        classify_target(stg_fd, "1m/600000.SH_via_symlinked_dir.csv", None)
    assert ei.value.component == "1m"
    assert ei.value.errno == errno.ENOTDIR


# ── fix round 1：socket 目标——唯一 `fd is None` 的分支 ──
# `open_regular_probe` 对 socket 是「`open()` 本身就失败」，回头 `lstat` 证实
# 非普通后抛 `NotARegularFileError`；`classify_target` 把它携带的 `st` 取出、
# `fd` 置 `None`，仍走同一条 `_is_regular(st)` 判据。这是唯一没有真 fd 可关的
# 分支，行为上与目录/FIFO 最不同，之前没有专门测试覆盖。

def test_classify_target_socket_target_is_untracked_no_leak(roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    sub = stg_path / "1m"
    sub.mkdir(parents=True, exist_ok=True)
    leaf_name = "600000.SH_sock.csv"
    rel = f"1m/{leaf_name}"

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    # AF_UNIX 路径上限约 104 字节，tmp_path 常超——切进目标目录再用相对名绑定
    # （与 test_qmt_fetch.py 里源侧 socket 测试、test_qmt_manifest.py 同规格）。
    monkeypatch.chdir(sub)
    try:
        sock.bind(leaf_name)
        record = {"bytes": os.lstat(leaf_name).st_size, "sha256": "0" * 64}  # 与 lstat 对齐

        before = len(os.listdir("/dev/fd"))
        verdict = classify_target(stg_fd, rel, record)
        after = len(os.listdir("/dev/fd"))

        assert verdict == TARGET_UNTRACKED
        assert after - before <= 2, f"socket 分支疑似泄漏：调用前 {before} 个，调用后 {after} 个"
    finally:
        sock.close()


# ══════════════════════════════════════════════════════════════════
# Task 3 · 在途标记 + 单股事务编排 `copy_stock`
# 契约 D1、D4 第 2 条、D5、D6、D7、D8
# ══════════════════════════════════════════════════════════════════

def _seed_manifest(*, universe_sh=("600000.SH",), committed_bytes=None):
    """造一份最小合规的 fetch_manifest.json（本节测试的通用起点）。

    形状取契约 §1「证据」栏引用的探针 `seed_manifest()` 同一套必需字段
    ——这些字段是 `qmt_manifest.validate_manifest` 的形状要求本身决定的，
    不是可以自由裁剪的测试便利。
    """
    export_log_bytes = b"stock,period\n600000.SH,1m\n"
    export_log_sha = hashlib.sha256(export_log_bytes).hexdigest()
    if committed_bytes is None:
        committed_bytes = len(export_log_bytes)
    manifest = {
        "manifest_version": 1,
        "seed": "s4a-task3-test",
        "source_snapshot": {
            "export_log_sha256": export_log_sha,
            "universe": {"SH": list(universe_sh), "SZ": [], "BJ": []},
        },
        "source_mount": {"fstype": "smbfs", "device": "//u@h/s",
                          "source_root_relative": ""},
        "pool_order": {"SH": [], "SZ": [], "BJ": []},
        "cursor": {"SH": 0, "SZ": 0, "BJ": 0},
        "files": [],
        "staged_export_log": {"relative_path": "export_log.csv",
                               "bytes": len(export_log_bytes),
                               "sha256": export_log_sha},
        "source_verification": "partial",
        "source_verification_evidence": {"level": "partial", "passes": []},
        "committed_bytes": committed_bytes,
    }
    return manifest, export_log_bytes


def _begin_session(stg_fd, stg_path, manifest: dict, export_log_bytes: bytes):
    """把 manifest + `export_log.csv` 落盘、调用 `begin_run`——`copy_stock`
    要求调用方已经过 `begin_run` 拿到 `ledger`（本模块不管启动序列，S4b 的
    范围）。锁纪律不属于 `begin_run`/`commit_stock` 的判据（两者都不读锁），
    本节测试不取锁，聚焦 `copy_stock` 自身。
    """
    atomic_write_json(stg_fd, MANIFEST_NAME, manifest, full_sync=False)
    (stg_path / "export_log.csv").write_bytes(export_log_bytes)
    return begin_run(stg_fd)


# ── 异常家族：SourceChangedMidRun 是 RunTerminated 第二个成员 ──────

def test_source_changed_mid_run_is_a_run_terminated_family_member():
    assert issubclass(SourceChangedMidRun, RunTerminated)
    assert not issubclass(SourceChangedMidRun, StockCopyFailed)
    assert not issubclass(StockCopyFailed, SourceChangedMidRun)
    assert not issubclass(SourceChangedMidRun, PathEscapeError)
    assert not issubclass(PathEscapeError, SourceChangedMidRun)


# ── fix round 2 · N2：D1 拒绝**不**折进 StockCopyFailed（订正 fix round 1
# · I4 的判断）——这是调用方违反了本函数的前置契约（两条路径要与 slot 对应、
# 次序钉死），不是这只股的事实：与裸 `TypeError` 同规格，不属于三族任何
# 一个，也不许成为 failures 的一个 reason（该全集已被大 spec:492 与契约 D3
# 声明闭合）。这里钉住的是「确实如此」，不是靠模块文档这么说。

def test_copy_stock_invalid_stock_paths_belongs_to_no_family(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    with pytest.raises(QmtSchemaError) as ei:
        copy_stock(src_fd, stg_fd, slot, "1m/bad_name.csv", "daily/bad_name.csv",
                   manifest, ledger=ledger, budget=budget)

    assert not isinstance(ei.value, StockCopyFailed)
    assert not isinstance(ei.value, RunTerminated)
    assert not isinstance(ei.value, PathEscapeError)


def test_copy_stock_bad_slot_type_error_is_not_part_of_any_declared_family():
    manifest, _export_log_bytes = _seed_manifest()
    with pytest.raises(TypeError) as ei:
        copy_stock(0, 0, {"code": "600000.SH", "market": "SH", "universe_idx": 0},
                   "1m/x.csv", "daily/x.csv", manifest, ledger=None,
                   budget=ByteBudget(limit=None))
    assert not isinstance(ei.value, StockCopyFailed)
    assert not isinstance(ei.value, RunTerminated)
    assert not isinstance(ei.value, PathEscapeError)


# ── `.inflight.json` 的形状（大 spec §4.5:468 钉死：code/universe_idx/
#    targets/parts/started_at，不含 market——契约 §5 声明这份字段形状继续
#    生效，fix round 1 · C1 订正：此前漏了 targets/parts/started_at 三个
#    字段、多写了一个 spec 未提及的 market）──────────────────────────

def test_build_inflight_marker_shape():
    slot = Slot(code="600000.SH", market="SH", universe_idx=3)
    marker = build_inflight_marker(slot, "1m/x_1分钟K线_前复权.csv",
                                    "daily/x_日K线_前复权.csv")
    assert marker["code"] == "600000.SH"
    assert marker["universe_idx"] == 3
    assert marker["targets"] == ["1m/x_1分钟K线_前复权.csv", "daily/x_日K线_前复权.csv"]
    assert marker["parts"] == ["1m/x_1分钟K线_前复权.csv" + PART,
                                "daily/x_日K线_前复权.csv" + PART]
    assert isinstance(marker["started_at"], str) and marker["started_at"]
    assert "market" not in marker, "大 spec 没有把 market 列进这份形状"
    assert set(marker) == {"code", "universe_idx", "targets", "parts", "started_at"}


def test_build_inflight_marker_rejects_non_slot():
    with pytest.raises(TypeError):
        build_inflight_marker({"code": "600000.SH"}, "1m/x.csv", "daily/x.csv")


# ── 证据 1：端到端正路 ──────────────────────────────────────────

def test_copy_stock_happy_path_end_to_end_commits_both_files(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_浦发银行_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_浦发银行_日K线_前复权.csv"
    data_1m = b"1m-data" * 20
    data_daily = b"daily-data" * 30
    _put_source_file(src_path, rel_1m, data_1m)
    _put_source_file(src_path, rel_daily, data_daily)

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    status, out = copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                              ledger=ledger, budget=budget)

    assert status == "committed"
    assert (stg_path / rel_1m).read_bytes() == data_1m
    assert (stg_path / rel_daily).read_bytes() == data_daily
    assert not (stg_path / (rel_1m + PART)).exists()
    assert not (stg_path / (rel_daily + PART)).exists()
    assert not (stg_path / INFLIGHT).exists()

    stock_files = [f for f in out["files"] if f["stock_code"] == "600000.SH"]
    assert len(stock_files) == 2
    assert {f["period"] for f in stock_files} == {"1m", "daily"}
    assert out["pool_order"]["SH"] == [{"code": "600000.SH", "universe_idx": 0}]
    assert out["cursor"]["SH"] == 1
    assert out["committed_bytes"] == len(export_log_bytes) + len(data_1m) + len(data_daily)

    disk = read_manifest(stg_fd)
    assert disk == out, "commit_stock 必须真落盘，不是只改了内存里那份"


# ── 证据 1 的另一半：D8，两个文件都已完好在池 → 跳过，不做任何改动 ──

def test_copy_stock_skips_when_both_files_already_match(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    data_1m = b"already-there-1m"
    data_daily = b"already-there-daily"
    _put_source_file(src_path, rel_1m, data_1m)
    _put_source_file(src_path, rel_daily, data_daily)
    _put_target_file(stg_path, rel_1m, data_1m)
    _put_target_file(stg_path, rel_daily, data_daily)

    rec_1m = {"stock_code": "600000.SH", "period": "1m", "relative_path": rel_1m,
              "bytes": len(data_1m), "sha256": hashlib.sha256(data_1m).hexdigest()}
    rec_daily = {"stock_code": "600000.SH", "period": "daily", "relative_path": rel_daily,
                 "bytes": len(data_daily), "sha256": hashlib.sha256(data_daily).hexdigest()}
    manifest, export_log_bytes = _seed_manifest()
    manifest["files"] = [rec_1m, rec_daily]
    manifest["pool_order"]["SH"] = [{"code": "600000.SH", "universe_idx": 0}]
    manifest["cursor"]["SH"] = 1
    manifest["committed_bytes"] = len(export_log_bytes) + len(data_1m) + len(data_daily)
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    status, out = copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                              ledger=ledger, budget=budget)

    assert status == "skipped"
    assert out is manifest
    assert not (stg_path / INFLIGHT).exists()
    assert budget.used == manifest["committed_bytes"], "跳过不该动预算"


# ── 证据 2：D1 前置校验——次序互换与 code 不符都必须被拒，且拒绝早于标记 ──

def test_copy_stock_rejects_swapped_period_order_before_marker_written(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m")
    _put_source_file(src_path, rel_daily, b"daily")
    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    with pytest.raises(QmtSchemaError):
        copy_stock(src_fd, stg_fd, slot, rel_daily, rel_1m, manifest,   # 次序互换
                    ledger=ledger, budget=budget)

    assert not (stg_path / INFLIGHT).exists()
    assert not (stg_path / rel_1m).exists()
    assert not (stg_path / rel_daily).exists()
    assert not (stg_path / (rel_1m + PART)).exists()
    assert not (stg_path / (rel_daily + PART)).exists()
    assert budget.used == manifest["committed_bytes"]


def test_copy_stock_rejects_path_whose_filename_code_does_not_match_slot(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600001.SH_other_1分钟K线_前复权.csv"       # 文件名代码与 slot 不符
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    with pytest.raises(QmtSchemaError):
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)

    assert not (stg_path / INFLIGHT).exists()
    assert not (stg_path / rel_1m).exists()
    assert not (stg_path / rel_daily).exists()


# ── 证据 3：R37-F1 回归钉——daily 缺失时，1m 的 final 不许残留 ──────

def test_copy_stock_daily_missing_leaves_no_orphan_1m_final(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 10)   # daily 整段目录都没导出过
    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    with pytest.raises(StockCopyFailed) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)
    assert ei.value.reason == "fetch_missing_file"

    assert not (stg_path / rel_1m).exists(), "1m 的 final 不许残留——清理粒度是股不是文件"
    assert not (stg_path / (rel_1m + PART)).exists()
    assert not (stg_path / INFLIGHT).exists()
    assert budget.used == baseline


# ── 证据 4：D5——本地坏 + 源等长换代 → 在写标记之前终止 ─────────────

def test_copy_stock_terminates_before_marker_when_local_corrupt_and_source_swapped(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"

    original_1m = b"A" * 200
    swapped_1m = b"B" * 200          # 源等长换代：同尺寸、不同内容
    corrupt_local_1m = b"Z" * 200    # 本地坏：同尺寸、不同内容（触发 RECOPY 判据）
    daily_data = b"daily-ok" * 10

    _put_source_file(src_path, rel_1m, swapped_1m)
    _put_source_file(src_path, rel_daily, daily_data)
    _put_target_file(stg_path, rel_1m, corrupt_local_1m)
    _put_target_file(stg_path, rel_daily, daily_data)

    rec_1m = {"stock_code": "600000.SH", "period": "1m", "relative_path": rel_1m,
              "bytes": len(original_1m), "sha256": hashlib.sha256(original_1m).hexdigest()}
    rec_daily = {"stock_code": "600000.SH", "period": "daily", "relative_path": rel_daily,
                 "bytes": len(daily_data), "sha256": hashlib.sha256(daily_data).hexdigest()}
    manifest, export_log_bytes = _seed_manifest()
    manifest["files"] = [rec_1m, rec_daily]
    manifest["pool_order"]["SH"] = [{"code": "600000.SH", "universe_idx": 0}]
    manifest["cursor"]["SH"] = 1
    manifest["committed_bytes"] = (
        len(export_log_bytes) + len(original_1m) + len(daily_data))
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    before_disk = (stg_path / MANIFEST_NAME).read_bytes()
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    with pytest.raises(SourceChangedMidRun):
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)

    assert not (stg_path / INFLIGHT).exists(), "标记未写"
    assert not (stg_path / (rel_1m + PART)).exists(), ".part 无残留"
    assert not (stg_path / (rel_daily + PART)).exists()
    assert budget.used == baseline, "退还了本次已扣的账"
    after_disk = (stg_path / MANIFEST_NAME).read_bytes()
    assert after_disk == before_disk, "manifest 逐字节未变"

    disk_manifest = read_manifest(stg_fd)
    assert disk_manifest["cursor"]["SH"] == 1, "cursor 未动"


# ── 证据 5：D4 第 2 条——「有记录 × 目标不存在 × 源已换代」单独一档 ──

def test_copy_stock_terminates_when_recorded_absent_target_and_source_changed(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"

    original_1m = b"A" * 150
    swapped_1m = b"C" * 90           # 源已换代，长度也不同——不依赖长度巧合
    daily_data = b"daily-ok" * 5

    _put_source_file(src_path, rel_1m, swapped_1m)
    _put_source_file(src_path, rel_daily, daily_data)
    # 刻意不落 1m 的 staging 目标——「目标不存在」那一列，quadrant = TARGET_COPY，
    # 不是 TARGET_RECOPY：D4 第 2 条要求这一格同样要比对，不能只挂在重拷那一格。
    _put_target_file(stg_path, rel_daily, daily_data)

    rec_1m = {"stock_code": "600000.SH", "period": "1m", "relative_path": rel_1m,
              "bytes": len(original_1m), "sha256": hashlib.sha256(original_1m).hexdigest()}
    rec_daily = {"stock_code": "600000.SH", "period": "daily", "relative_path": rel_daily,
                 "bytes": len(daily_data), "sha256": hashlib.sha256(daily_data).hexdigest()}
    manifest, export_log_bytes = _seed_manifest()
    manifest["files"] = [rec_1m, rec_daily]
    manifest["pool_order"]["SH"] = [{"code": "600000.SH", "universe_idx": 0}]
    manifest["cursor"]["SH"] = 1
    manifest["committed_bytes"] = (
        len(export_log_bytes) + len(original_1m) + len(daily_data))
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    assert classify_target(stg_fd, rel_1m, rec_1m) == TARGET_COPY, \
        "本测试要落在「目标不存在」那一列，不是重拷那一格"

    with pytest.raises(SourceChangedMidRun):
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)

    assert not (stg_path / INFLIGHT).exists()
    assert not (stg_path / rel_1m).exists(), "目标本就不存在，也不许被造出来"
    assert not (stg_path / (rel_1m + PART)).exists()
    assert budget.used == baseline


# ── fix round 1 · C2 回归钉（fix round 2 · N1 收编）：D4 第 2 条的比对必须
# 按 (stock_code, period) 触发，不是按 relative_path——账本里这只股 1m 的
# 记录若挂在与本次调用不同的 relative_path 下（路径怎么解析出来在契约 D1
# 里明写尚未选定，`{name}` 段换过就会导致这一情形），按路径去查记录会查
# 不到、把它当成「无记录」。C2 当时只堵了「查得到记录、内容也确实不符」这
# 半条路（比对到内容不同 → `SourceChangedMidRun`）；N1 发现「记录路径不同
# 但内容碰巧没变」那半条路 C2 堵不住——比对通过、两个 final 落地、标记写
# 下，直到 commit_stock 才因「会把已提交的 files 记录…回滚掉」拒绝。N1 在
# 四象限之前新增了一道统一的门（按 relative_path 是否一致），本测试（内容
# 也变了）与它的两个专门回归测试（内容没变的两个分支）一起，现在都在
# `verdicts` 之前就被拦下，抛的是 `StockCopyFailed("untracked_target_
# file", ...)`，不再是 `SourceChangedMidRun`。

def test_copy_stock_detects_mismatch_when_existing_record_has_a_different_relative_path(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    old_rel_1m = "1m/600000.SH_旧名字_1分钟K线_前复权.csv"    # 账本记录挂的老路径
    new_rel_1m = "1m/600000.SH_新名字_1分钟K线_前复权.csv"    # 本次调用给的新路径
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"

    original_1m = b"A" * 120
    changed_1m = b"B" * 120        # 源内容已经变了（与账本记录不符）
    daily_data = b"daily-ok" * 4

    _put_source_file(src_path, new_rel_1m, changed_1m)
    _put_source_file(src_path, rel_daily, daily_data)
    # 新路径的 staging 目标不存在（模拟「path 解析方式换了」——quadrant 落在
    # TARGET_COPY，不是 TARGET_RECOPY，正是漏比对最隐蔽的那一格）。
    _put_target_file(stg_path, rel_daily, daily_data)

    rec_1m = {"stock_code": "600000.SH", "period": "1m", "relative_path": old_rel_1m,
              "bytes": len(original_1m), "sha256": hashlib.sha256(original_1m).hexdigest()}
    rec_daily = {"stock_code": "600000.SH", "period": "daily", "relative_path": rel_daily,
                 "bytes": len(daily_data), "sha256": hashlib.sha256(daily_data).hexdigest()}
    manifest, export_log_bytes = _seed_manifest()
    manifest["files"] = [rec_1m, rec_daily]
    manifest["pool_order"]["SH"] = [{"code": "600000.SH", "universe_idx": 0}]
    manifest["cursor"]["SH"] = 1
    manifest["committed_bytes"] = (
        len(export_log_bytes) + len(original_1m) + len(daily_data))
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    assert classify_target(stg_fd, new_rel_1m, None) == TARGET_COPY, \
        "按 new_rel_1m 这条路径查，staging 目标确实不存在——不加 N1 的门，" \
        "四象限本身看不出任何问题，会正常往下走到拷贝与比对"

    with pytest.raises(StockCopyFailed) as ei:
        copy_stock(src_fd, stg_fd, slot, new_rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)
    assert ei.value.reason == "untracked_target_file"

    assert not (stg_path / INFLIGHT).exists(), "标记未写"
    assert not (stg_path / new_rel_1m).exists(), "新路径下不许落地 final"
    assert not (stg_path / (new_rel_1m + PART)).exists()
    assert budget.used == baseline


# ── fix round 2 · N1 专门回归钉：两个分支都在「源没变」（比对本身不会拦
# 下）的情况下发生，证明只靠 D5/D4 第 2 条的内容比对堵不住，必须靠一道单独
# 的「记录路径与本次调用路径是否一致」门。

def test_copy_stock_rejects_relocated_record_when_new_path_already_matches(roots):
    # SKIP 分支：新路径下的文件已经完好存在（比如被人工搬过去、或恰好是
    # 同一批导出复用了旧字节）——不加 N1 的门，四象限会判 SKIP，旧记录被
    # 原样提交，指向一条盘上并不存在的路径，新路径那份完好的文件反而没有
    # 任何记录（评审原话：committed 且账本是错的）。
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    old_rel_1m = "1m/600000.SH_旧名字_1分钟K线_前复权.csv"
    new_rel_1m = "1m/600000.SH_新名字_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"

    content_1m = b"A" * 120
    daily_data = b"daily-ok" * 4

    _put_source_file(src_path, new_rel_1m, content_1m)
    _put_target_file(stg_path, new_rel_1m, content_1m)   # 新路径下已经完好
    _put_source_file(src_path, rel_daily, daily_data)
    _put_target_file(stg_path, rel_daily, daily_data)     # daily 也完好

    rec_1m = {"stock_code": "600000.SH", "period": "1m", "relative_path": old_rel_1m,
              "bytes": len(content_1m), "sha256": hashlib.sha256(content_1m).hexdigest()}
    rec_daily = {"stock_code": "600000.SH", "period": "daily", "relative_path": rel_daily,
                 "bytes": len(daily_data), "sha256": hashlib.sha256(daily_data).hexdigest()}
    manifest, export_log_bytes = _seed_manifest()
    manifest["files"] = [rec_1m, rec_daily]
    manifest["pool_order"]["SH"] = [{"code": "600000.SH", "universe_idx": 0}]
    manifest["cursor"]["SH"] = 1
    manifest["committed_bytes"] = len(export_log_bytes) + len(content_1m) + len(daily_data)
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    assert classify_target(stg_fd, new_rel_1m, rec_1m) == TARGET_SKIP, (
        "不加 N1 的门，四象限本身看不出问题——新路径下的字节与旧记录逐字相符"
    )

    with pytest.raises(StockCopyFailed) as ei:
        copy_stock(src_fd, stg_fd, slot, new_rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)
    assert ei.value.reason == "untracked_target_file"

    assert not (stg_path / INFLIGHT).exists()
    assert budget.used == baseline
    # 新路径下那份完好的文件原样留着，没有被误判成「已提交」。
    assert (stg_path / new_rel_1m).read_bytes() == content_1m


def test_copy_stock_rejects_relocated_record_when_new_path_needs_fresh_copy(roots):
    # COPY/RECOPY 分支、源没变：新路径下 staging 目标不存在，源内容与旧记录
    # 逐字相同——不加 N1 的门，D5/D4 第 2 条的比对会通过（源没变，比对本身
    # 拦不住），两个 final 落地、标记写下，直到 commit_stock 才因「会把已
    # 提交的 files 记录…回滚掉」拒绝，那时标记与 final 都已经在盘上。
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    old_rel_1m = "1m/600000.SH_旧名字_1分钟K线_前复权.csv"
    new_rel_1m = "1m/600000.SH_新名字_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"

    content_1m = b"A" * 120        # 源没变——与账本记录逐字相同
    daily_data = b"daily-ok" * 4

    _put_source_file(src_path, new_rel_1m, content_1m)
    # 新路径下 staging 目标不存在——quadrant 会判 TARGET_COPY。
    _put_source_file(src_path, rel_daily, daily_data)
    _put_target_file(stg_path, rel_daily, daily_data)

    rec_1m = {"stock_code": "600000.SH", "period": "1m", "relative_path": old_rel_1m,
              "bytes": len(content_1m), "sha256": hashlib.sha256(content_1m).hexdigest()}
    rec_daily = {"stock_code": "600000.SH", "period": "daily", "relative_path": rel_daily,
                 "bytes": len(daily_data), "sha256": hashlib.sha256(daily_data).hexdigest()}
    manifest, export_log_bytes = _seed_manifest()
    manifest["files"] = [rec_1m, rec_daily]
    manifest["pool_order"]["SH"] = [{"code": "600000.SH", "universe_idx": 0}]
    manifest["cursor"]["SH"] = 1
    manifest["committed_bytes"] = len(export_log_bytes) + len(content_1m) + len(daily_data)
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    assert classify_target(stg_fd, new_rel_1m, rec_1m) == TARGET_COPY, (
        "不加 N1 的门，四象限本身看不出问题——新路径下目标不存在，走的是正常拷贝"
    )

    with pytest.raises(StockCopyFailed) as ei:
        copy_stock(src_fd, stg_fd, slot, new_rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)
    assert ei.value.reason == "untracked_target_file"

    assert not (stg_path / INFLIGHT).exists()
    assert not (stg_path / new_rel_1m).exists(), "新路径下不许落地 final"
    assert not (stg_path / (new_rel_1m + PART)).exists()
    assert budget.used == baseline


# ── 证据 6：D6——标记写下后每一次 os.replace 时标记都必须在盘上 ──────

def test_copy_stock_marker_present_on_disk_during_each_final_replace(roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 5)
    _put_source_file(src_path, rel_daily, b"daily-data" * 5)

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    target_basenames = {rel_1m.rsplit("/", 1)[-1], rel_daily.rsplit("/", 1)[-1]}
    seen_marker_present: list[bool] = []
    real_replace = os.replace

    def spy_replace(src, dst, *a, **kw):
        if dst in target_basenames:
            seen_marker_present.append((stg_path / INFLIGHT).exists())
        return real_replace(src, dst, *a, **kw)

    monkeypatch.setattr(os, "replace", spy_replace)

    status, out = copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                              ledger=ledger, budget=budget)

    assert status == "committed"
    assert seen_marker_present == [True, True], (
        "两次 .part→final 的 os.replace 发生时，在途标记都必须已经在盘上"
    )


# ── fix round 1 · I2：标记删除之后的 fsync 也要有测试守着 ──────────
# 大 spec 闭合清单「`.inflight.json` 的创建与删除 → 各自之后 fsync(staging)」
# ——创建那一半靠 atomic_write_json 内部兜底，删除是 _remove_inflight_marker
# 自己的代码，此前没有测试专门盯着它。

def test_copy_stock_fsyncs_staging_root_after_marker_deletion(roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 5)
    _put_source_file(src_path, rel_daily, b"daily-data" * 5)

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    events: list[tuple] = []
    real_unlink = os.unlink
    real_fsync_dir = qmt_fetch.fsync_dir

    def spy_unlink(path, *a, **kw):
        if path == INFLIGHT:
            events.append(("unlink_marker", kw.get("dir_fd")))
        return real_unlink(path, *a, **kw)

    def spy_fsync_dir(dir_fd):
        events.append(("fsync", dir_fd))
        return real_fsync_dir(dir_fd)

    monkeypatch.setattr(os, "unlink", spy_unlink)
    monkeypatch.setattr(qmt_fetch, "fsync_dir", spy_fsync_dir)

    status, out = copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                              ledger=ledger, budget=budget)

    assert status == "committed"
    unlink_positions = [i for i, e in enumerate(events) if e[0] == "unlink_marker"]
    assert len(unlink_positions) == 1, f"应恰好删一次标记，实测事件 {events}"
    i = unlink_positions[0]
    assert i + 1 < len(events) and events[i + 1][0] == "fsync", (
        f"删标记之后紧跟的必须是 fsync_dir，实测事件序列 {events}"
    )
    assert events[i + 1][1] == events[i][1] == stg_fd, (
        f"fsync 的必须是 staging 根（unlink 用的那个 dir_fd），实测事件序列 {events}"
    )


# ── 证据 7：耐久——每次 os.replace 之后都要 fsync 其目录 ────────────

def test_copy_stock_fsyncs_directory_after_each_final_replace(roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 5)
    _put_source_file(src_path, rel_daily, b"daily-data" * 5)

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    target_basenames = {rel_1m.rsplit("/", 1)[-1], rel_daily.rsplit("/", 1)[-1]}
    events: list[tuple] = []
    real_replace = os.replace
    real_fsync_dir = qmt_fetch.fsync_dir

    def spy_replace(src, dst, *a, **kw):
        result = real_replace(src, dst, *a, **kw)
        if dst in target_basenames:
            # 记下这次 replace **实际用的那个目录 fd**（src/dst 同目录，
            # 取 dst_dir_fd 即可），供下面核对 fsync 的是不是同一个。
            events.append(("replace", dst, kw.get("dst_dir_fd")))
        return result

    def spy_fsync_dir(dir_fd):
        events.append(("fsync", dir_fd))
        return real_fsync_dir(dir_fd)

    monkeypatch.setattr(os, "replace", spy_replace)
    monkeypatch.setattr(qmt_fetch, "fsync_dir", spy_fsync_dir)

    status, out = copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                              ledger=ledger, budget=budget)

    assert status == "committed"
    # 与「标记在场」那条测试同规格地过滤：只看两次 final 替换。标记的创建/删除
    # 各自的 fsync 走的是 qmt_fsroot 自己模块内的引用，不经过这里的猴子补丁，
    # 天然不混进来；`replace` 之后紧跟的下一个事件必须就是它自己那次 fsync
    # ——不只是「下一个事件是某次 fsync」，还要求**那次 fsync 的 fd 与这次
    # replace 用的目录 fd 逐一相等**（fix round 1 · I1：此前只查事件类型，
    # 若把目录换成别的 fd——比如 staging 根——同样能骗过「下一个是 fsync」
    # 这条判据，而 staging 根的 fsync 并不持久化子目录里那条新的目录项）。
    replace_positions = [i for i, e in enumerate(events) if e[0] == "replace"]
    assert len(replace_positions) == 2, f"应有两次 final 替换，实测事件 {events}"
    for i in replace_positions:
        assert events[i + 1][0] == "fsync", (
            f"os.replace 之后紧跟的必须是 fsync_dir，实测事件序列 {events}"
        )
        assert events[i + 1][1] == events[i][2], (
            "fsync 的必须是 replace 实际用的那个目录 fd，不是别的目录（比如 "
            f"staging 根）——实测事件序列 {events}"
        )


# ── fix round 1 · I3：成功重拷（E3）的提交路径此前从未被真正跑到 ───────
# 记录存在 + 本地目标同尺寸损坏（触发 TARGET_RECOPY）+ 源没变 → 重拷出的字节
# 与账本记录逐字相同，不触发 D5 终止，走到正常提交。这条路径底下有两处此前
# 零覆盖：`_apply_stock_records` 的 pool_order 去重判据（不重复追加锚点）与
# `cursor = max(...)`（不能让 cursor 从一个更靠后的位置倒退）。universe_idx
# 特意设成**小于**已有 cursor，才是 `max()` 真正起作用（防倒退）的场景——
# 若 universe_idx 恰好等于「下一个新槽位」，`max()` 与直接赋值给出同一个数，
# 测试对这两种写法没有判别力。

def test_copy_stock_recopy_does_not_duplicate_pool_entry_or_regress_cursor(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    universe_sh = tuple(f"60000{i}.SH" for i in range(6))
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"

    content_1m = b"A" * 200
    content_daily = b"D" * 60
    corrupt_local_1m = b"Z" * 200      # 本地坏，同尺寸——触发 TARGET_RECOPY

    _put_source_file(src_path, rel_1m, content_1m)          # 源没变
    _put_source_file(src_path, rel_daily, content_daily)
    _put_target_file(stg_path, rel_1m, corrupt_local_1m)     # 本地坏
    _put_target_file(stg_path, rel_daily, content_daily)      # daily 完好 → SKIP

    rec_1m = {"stock_code": "600000.SH", "period": "1m", "relative_path": rel_1m,
              "bytes": len(content_1m), "sha256": hashlib.sha256(content_1m).hexdigest()}
    rec_daily = {"stock_code": "600000.SH", "period": "daily", "relative_path": rel_daily,
                 "bytes": len(content_daily), "sha256": hashlib.sha256(content_daily).hexdigest()}
    manifest, export_log_bytes = _seed_manifest(universe_sh=universe_sh)
    manifest["files"] = [rec_1m, rec_daily]
    # 这只股已经在池里，且 cursor 已经推进到更靠后的位置——模拟「其它股已经
    # 拉过、游标走在前面」，universe_idx=0 < cursor=5：max() 真正起作用的场景。
    manifest["pool_order"]["SH"] = [{"code": "600000.SH", "universe_idx": 0}]
    manifest["cursor"]["SH"] = 5
    old_committed = len(export_log_bytes) + len(content_1m) + len(content_daily)
    manifest["committed_bytes"] = old_committed
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    assert classify_target(stg_fd, rel_1m, rec_1m) == TARGET_RECOPY

    status, out = copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                              ledger=ledger, budget=budget)

    assert status == "committed"
    assert (stg_path / rel_1m).read_bytes() == content_1m
    assert out["pool_order"]["SH"] == [{"code": "600000.SH", "universe_idx": 0}], (
        "重拷不该在 pool_order 里重复追加这只股的锚点条目"
    )
    assert out["cursor"]["SH"] == 5, "重拷不该让 cursor 从 5 倒退到 universe_idx+1=1"
    assert out["committed_bytes"] == old_committed + len(content_1m), (
        "重拷即便内容与记录逐字相同，本次真写盘的字节仍要计入累计量（E13）"
    )


# ── 证据 8：D7——committed_bytes = 旧值 + 本次真正写盘字节 ──────────

def test_copy_stock_committed_bytes_is_old_value_plus_actual_bytes_written(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    data_1m = b"m" * 111
    data_daily = b"d" * 222
    _put_source_file(src_path, rel_1m, data_1m)
    _put_source_file(src_path, rel_daily, data_daily)

    manifest, export_log_bytes = _seed_manifest()
    seed_extra = 5000        # 模拟「此前已有其它股花掉的字节」，不对应任何 files 记录
    manifest["committed_bytes"] = len(export_log_bytes) + seed_extra
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    old_value = budget.used

    status, out = copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                              ledger=ledger, budget=budget)

    assert status == "committed"
    assert out["committed_bytes"] == old_value + len(data_1m) + len(data_daily)
    assert budget.used == out["committed_bytes"]


def test_recovery_removing_a_stock_leaves_committed_bytes_unchanged_and_is_accepted(roots):
    # D7 崩溃恢复第③档（E10/E11/E12）：qmt_manifest 接受「删这只股的记录、
    # committed_bytes 原值不动」，拒绝「调小」。崩溃恢复本身是 S4b 的职责；
    # 本测试直接驱动已合并的 commit_stock + RecoveryScope，钉住 Task 3 选择的
    # 累计写入量语义（不去碰 committed_bytes）与它兼容。
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"m" * 40)
    _put_source_file(src_path, rel_daily, b"d" * 60)

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    status, out = copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                              ledger=ledger, budget=budget)
    assert status == "committed"
    committed_bytes_after = out["committed_bytes"]

    recovery = RecoveryScope(stock_code="600000.SH", market="SH", universe_idx=0)
    payload = dict(out)
    payload["files"] = [f for f in out["files"] if f["stock_code"] != "600000.SH"]
    payload["pool_order"] = {mk: [e for e in v if e.get("code") != "600000.SH"]
                              for mk, v in out["pool_order"].items()}
    payload["cursor"] = dict(out["cursor"])
    payload["cursor"]["SH"] = min(out["cursor"]["SH"], 0)
    # committed_bytes 原值不动（不写调小的值）。

    result = commit_stock(stg_fd, payload, ledger=ledger, recovery=recovery)
    assert result["committed_bytes"] == committed_bytes_after


# ── fd 不泄漏：copy_stock 对多只股连续调用 ──────────────────────

def test_copy_stock_does_not_leak_fds_across_repeated_calls_for_distinct_stocks(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    codes = tuple(f"60000{i}.SH" for i in range(5))
    manifest, export_log_bytes = _seed_manifest(universe_sh=codes)
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    before = len(os.listdir("/dev/fd"))
    for idx, code in enumerate(codes):
        slot = Slot(code=code, market="SH", universe_idx=idx)
        rel_1m = f"1m/{code}_x_1分钟K线_前复权.csv"
        rel_daily = f"daily/{code}_x_日K线_前复权.csv"
        _put_source_file(src_path, rel_1m, f"m{idx}".encode() * 10)
        _put_source_file(src_path, rel_daily, f"d{idx}".encode() * 10)
        status, manifest = copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                                       ledger=ledger, budget=budget)
        assert status == "committed"
    after = len(os.listdir("/dev/fd"))
    assert after - before <= 2, f"copy_stock 疑似泄漏 fd：调用前 {before} 个，调用后 {after} 个"


# ══════════════════════════════════════════════════════════════════
# fix round 4（整支评审）：五条 finding 的回归钉
# ══════════════════════════════════════════════════════════════════

class _DeadlineExceeded(BaseException):
    """超时信号，**故意不继承 `Exception`，更不继承 `OSError`**。

    ⚠️ 实测踩过：最初这里抛的是 `TimeoutError`，而 `TimeoutError` **是
    `OSError` 的子类** —— 它从阻塞的 `os.open` 里冒出来，先被 `open_under` 的
    `except OSError` 接住、原样再抛，再被 `_open_part` 的 `except OSError` 接住，
    回头 lstat 一看「那确实是个 FIFO」⇒ 变成一个 `StockCopyFailed
    ("untracked_target_file")` —— **与被测实现正确时的结论一模一样**。
    于是「拿掉 O_NONBLOCK」这个变异下，两条 FIFO 测试各挂 5 秒**仍然全绿**：
    我的超时闸自己被洗成了断言期望的那个答案。
    继承 `BaseException` 之后，沿途所有 `except OSError` / `except Exception`
    都接不住它；`copy_one` / `copy_stock` 里的 `except BaseException` 只做
    清理并 `raise`，不改变它的身份。
    """


@contextlib.contextmanager
def _deadline(seconds: float = 5.0):
    """把「挂死」变成一条**会变红**的测试，而不是一次卡住整个套件的运行。

    C1 的变异（拿掉 `.part` 打开点的 `O_NONBLOCK`）不会让任何断言失败——它会让
    `os.open(O_WRONLY)` **永远**等一个写入方。没有这道闸，「变异必须变红」这条
    验收条件本身就执行不了：套件只会一直挂着，而「挂着」与「还没跑完」从外面
    看长得一模一样。`SIGALRM` 的处理函数抛异常时 PEP 475 不重试、原样传播。
    """
    def _fire(signum, frame):
        raise _DeadlineExceeded(
            f"超过 {seconds} 秒仍未返回：疑似阻塞在一个被植入的 FIFO 上"
        )

    previous = signal.signal(signal.SIGALRM, _fire)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


# ── C1：`.part` 与 final 同处一棵可被篡改的 staging 树，纪律必须同规格 ──
# 此前 `.part` 的两个打开点直接走 `open_under`（只加 `O_NOFOLLOW`），既没有
# `O_NONBLOCK` 也没有普通文件判据，而 `classify_target` 只看 final、从不看
# `<rel>.part`。后果：植一个 FIFO 进去 → `os.open(O_WRONLY)` 永久等写入方，
# 整次运行挂死在 `.staging.lock` 里（比 D2 要防的结局更糟，且不是 fail-closed）；
# 植一个目录进去 → 裸 `IsADirectoryError`，不属于本模块声明的任何一族。

def test_copy_one_fifo_at_part_is_untracked_target_file_not_a_hang(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    _put_source_file(src_path, rel, b"source-data" * 10)
    part = stg_path / (rel + PART)
    part.parent.mkdir(parents=True, exist_ok=True)
    os.mkfifo(str(part))

    budget = ByteBudget(limit=None, used=7)
    with _deadline():
        with pytest.raises(StockCopyFailed) as ei:
            copy_one(src_fd, stg_fd, rel, budget)
    assert ei.value.reason == "untracked_target_file"
    assert budget.used == 7, "一个字节都不该扣"
    assert stat.S_ISFIFO(os.lstat(str(part)).st_mode), "来路不明的对象要原样留着"


def test_copy_one_fifo_with_a_reader_at_part_opens_but_is_still_untracked(roots):
    # `_open_part` 的第三条分支：**打开成功、但不是普通文件**。FIFO 只要另一端
    # 已经挂着读者，`open(O_WRONLY|O_NONBLOCK)` 就**成功**（没有 ENXIO 可挡），
    # 于是唯一拦得住它的是打开之后那句 `S_ISREG` —— 少了它，接下来整份 CSV
    # 会被 `os.write` 灌进一根管子里，随后 `os.fsync` 在 FIFO 上抛 EINVAL。
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    _put_source_file(src_path, rel, b"source-data" * 10)
    part = stg_path / (rel + PART)
    part.parent.mkdir(parents=True, exist_ok=True)
    os.mkfifo(str(part))

    # 读端用 O_NONBLOCK 打开：没有写者也会立刻返回，于是写端此后不再撞 ENXIO。
    reader_fd = os.open(str(part), os.O_RDONLY | os.O_NONBLOCK)
    try:
        budget = ByteBudget(limit=None, used=7)
        with _deadline():
            with pytest.raises(StockCopyFailed) as ei:
                copy_one(src_fd, stg_fd, rel, budget)
        assert ei.value.reason == "untracked_target_file"
        assert budget.used == 7, "一个字节都不该扣"
        assert stat.S_ISFIFO(os.lstat(str(part)).st_mode)
    finally:
        os.close(reader_fd)


def test_copy_one_directory_at_part_is_untracked_target_file(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    _put_source_file(src_path, rel, b"source-data" * 10)
    part = stg_path / (rel + PART)
    part.mkdir(parents=True)

    budget = ByteBudget(limit=None, used=7)
    with pytest.raises(StockCopyFailed) as ei:
        copy_one(src_fd, stg_fd, rel, budget)
    assert ei.value.reason == "untracked_target_file", (
        "植进 .part 的目录必须落进已声明的候选失败族，不得逃出一个裸 OSError"
    )
    assert not isinstance(ei.value, OSError)
    assert budget.used == 7
    assert part.is_dir(), "来路不明的对象要原样留着"


def test_copy_one_symlinked_part_escapes_and_is_not_untracked(roots):
    # `.part` 的叶子是符号链接 ⇒ 逐段无跟随撞 ELOOP ⇒ PathEscapeError（整次致命），
    # **不得**被降级成「这只股的目标来路不明」——与 D2 对 final 的分界同一条。
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    _put_source_file(src_path, rel, b"source-data" * 10)
    sub = stg_path / "1m"
    sub.mkdir(parents=True, exist_ok=True)
    (sub / "elsewhere.bin").write_bytes(b"outside")
    (stg_path / (rel + PART)).symlink_to(sub / "elsewhere.bin")

    budget = ByteBudget(limit=None)
    with pytest.raises(PathEscapeError) as ei:
        copy_one(src_fd, stg_fd, rel, budget)
    assert ei.value.errno == errno.ELOOP
    assert not isinstance(ei.value, StockCopyFailed)


def test_copy_stock_fifo_at_part_fails_closed_without_hanging(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 10)
    _put_source_file(src_path, rel_daily, b"daily-data" * 10)
    part = stg_path / (rel_1m + PART)
    part.parent.mkdir(parents=True, exist_ok=True)
    os.mkfifo(str(part))

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    with _deadline():
        with pytest.raises(StockCopyFailed) as ei:
            copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                        ledger=ledger, budget=budget)
    assert ei.value.reason == "untracked_target_file"
    assert not (stg_path / INFLIGHT).exists()
    assert not (stg_path / rel_1m).exists()
    assert not (stg_path / rel_daily).exists()
    assert not (stg_path / (rel_daily + PART)).exists()
    assert stat.S_ISFIFO(os.lstat(str(part)).st_mode), "来路不明的对象要原样留着"
    assert budget.used == baseline
    assert read_manifest(stg_fd) == manifest, "manifest 一个字段都不该动"


def test_copy_stock_directory_at_part_fails_closed_and_keeps_the_failure_reason(roots):
    # ⚠️ 判别力所在：失败收尾会对两条 `.part` 各调一次 `_cleanup_part`，而
    # `os.unlink` 对一个**目录**抛 EPERM（macOS）/ EISDIR（Linux）——若收尾不先
    # 问一句「那底下是个什么东西」，那个 OSError 会**顶替掉**已经定性好的
    # StockCopyFailed，把候选失败变成一个不属于任何一族的裸 OSError。
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 10)
    _put_source_file(src_path, rel_daily, b"daily-data" * 10)
    part = stg_path / (rel_1m + PART)
    part.mkdir(parents=True)

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    with pytest.raises(StockCopyFailed) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)
    assert ei.value.reason == "untracked_target_file"
    assert not isinstance(ei.value, OSError)
    assert not (stg_path / INFLIGHT).exists()
    assert not (stg_path / rel_1m).exists()
    assert not (stg_path / rel_daily).exists()
    assert part.is_dir(), "来路不明的对象要原样留着"
    assert budget.used == baseline
    assert read_manifest(stg_fd) == manifest, "manifest 一个字段都不该动"


# ── C2：事务层那道 untracked 闸此前零判别力 ──────────────────────
# `if TARGET_UNTRACKED in verdicts` 改成 `if False and ...` 全套 52 项零红：
# 三条断言 untracked 的 copy_stock 测试走的全是另一处 raise（relative_path
# 迁移闸），D2 的覆盖整个只活在 `classify_target` 那一层——而 D2 的验收理由
# 「只测 FIFO 会全绿，因为 FIFO 的 os.replace **本来就成功**」讲的正是
# `os.replace`，`classify_target` 根本不调它。
#
# 故这两档**必须在 `copy_stock` 这一层**、且必须**目录与 FIFO 各一档**：
# 闸门被拆掉时，目录那档会一路走到 `os.replace`（标记已写、随后炸出
# IsADirectoryError，E6 的原始现场），FIFO 那档则 `os.replace` **成功**——
# 来路不明的对象被静默覆盖、这只股照常提交，正是 D2 存在的理由。
# 两档都用「无记录」那一格：有记录时落地前比对会先一步拦下（D4 第 2 条），
# 闸门被拆掉也看不到 os.replace 那一幕，判别力反而被邻居遮住。

def test_copy_stock_rejects_directory_at_final_target(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 10)
    _put_source_file(src_path, rel_daily, b"daily-data" * 10)
    (stg_path / rel_1m).mkdir(parents=True)          # final 那个名字底下是个目录

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    with pytest.raises(StockCopyFailed) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)
    assert ei.value.reason == "untracked_target_file"
    assert (stg_path / rel_1m).is_dir(), "D2：那个对象原样留着，不删不碰"
    assert not (stg_path / INFLIGHT).exists(), "在途标记一个字节都不许写下"
    assert not (stg_path / (rel_1m + PART)).exists()
    assert not (stg_path / (rel_daily + PART)).exists()
    assert not (stg_path / rel_daily).exists()
    assert budget.used == baseline
    assert read_manifest(stg_fd) == manifest, "manifest 一个字段都不该动"


def test_copy_stock_rejects_fifo_at_final_target(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 10)
    _put_source_file(src_path, rel_daily, b"daily-data" * 10)
    target = stg_path / rel_1m
    target.parent.mkdir(parents=True, exist_ok=True)
    os.mkfifo(str(target))                            # FIFO 的 os.replace 本来就成功

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    with pytest.raises(StockCopyFailed) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)
    assert ei.value.reason == "untracked_target_file"
    assert stat.S_ISFIFO(os.lstat(str(target)).st_mode), (
        "D2：那个对象原样留着——它被一次静默的 os.replace 覆盖掉正是本条要防的数据丢失"
    )
    assert not (stg_path / INFLIGHT).exists(), "在途标记一个字节都不许写下"
    assert not (stg_path / (rel_1m + PART)).exists()
    assert not (stg_path / (rel_daily + PART)).exists()
    assert not (stg_path / rel_daily).exists()
    assert budget.used == baseline
    assert read_manifest(stg_fd) == manifest, "manifest 一个字段都不该动"


# ── I1：删标记与提交之间的**次序**就是这个事务的定义 ──────────────
# 把 `_remove_inflight_marker(stg_fd)` 挪到 `commit_stock(...)` 之前，此前
# 全套 52 项零红。而那个次序一旦反过来：标记先没了、提交再失败，两个 final
# 就是**没有回滚凭据的孤儿**，下一次运行撞「目标存在 × 无记录」把这只股
# 永久除名（R37-F1）。两条断言分别钉住次序的两半。

def test_copy_stock_removes_marker_only_after_commit_succeeds(roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 5)
    _put_source_file(src_path, rel_daily, b"daily-data" * 5)

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    seen: list[bool] = []
    real_commit = qmt_fetch.commit_stock

    def spy_commit(stg_fd_, manifest_, *, ledger, recovery=None):
        seen.append((stg_path / INFLIGHT).exists())
        return real_commit(stg_fd_, manifest_, ledger=ledger, recovery=recovery)

    monkeypatch.setattr(qmt_fetch, "commit_stock", spy_commit)

    status, out = copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                              ledger=ledger, budget=budget)

    assert status == "committed"
    assert seen == [True], (
        "commit_stock 执行的那一刻，在途标记必须还在盘上——删标记只能排在"
        "提交**成功之后**（契约 D6）"
    )
    assert not (stg_path / INFLIGHT).exists(), "提交成功之后标记必须被删掉"


def test_copy_stock_keeps_marker_when_commit_fails(roots, monkeypatch):
    # 下一片（S4b）的崩溃恢复整个建立在这一条事实上：提交失败时标记**还在**，
    # 它是那两个孤儿 final 唯一的回滚凭据（大 spec §4.5:487「只删标记里明写的
    # 那两条 target 与两条 .part」）。标记没了 = 这只股永久除名。
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 5)
    _put_source_file(src_path, rel_daily, b"daily-data" * 5)

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    def exploding_commit(*args, **kwargs):
        raise RuntimeError("打桩：提交失败")

    monkeypatch.setattr(qmt_fetch, "commit_stock", exploding_commit)

    with pytest.raises(RuntimeError):
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)

    assert (stg_path / INFLIGHT).exists(), (
        "提交失败时在途标记必须留在盘上——它是两个孤儿 final 唯一的回滚凭据"
    )
    # 两个 final 确实已经落地：这正是「标记必须活着」的理由，不是顺带一提。
    assert (stg_path / rel_1m).exists()
    assert (stg_path / rel_daily).exists()


# ── I2：真正写到盘上的那份标记内容此前从未被看过一眼 ────────────────
# 形状测试只跑构造函数、在途测试只调 `.exists()`，两条谁也没跨到对面：把写
# 调用处的 payload 掏空成 `{"code": slot.code}`、或把构造函数两个路径实参对调，
# 全套 52 项都零红。而一份畸形的标记会让下一片拒绝启动且什么都不删——
# 一棵永远起不来的 staging。

def test_copy_stock_marker_payload_on_disk_matches_builder(roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 5)
    _put_source_file(src_path, rel_daily, b"daily-data" * 5)

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    target_basenames = {rel_1m.rsplit("/", 1)[-1], rel_daily.rsplit("/", 1)[-1]}
    captured: list[dict] = []
    real_replace = os.replace

    def spy_replace(src, dst, *a, **kw):
        # 事务中途——标记已写、第一个 final 还没换过去——把盘上那份读回来。
        if dst in target_basenames and not captured:
            captured.append(json.loads((stg_path / INFLIGHT).read_bytes()))
        return real_replace(src, dst, *a, **kw)

    monkeypatch.setattr(os, "replace", spy_replace)

    status, out = copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                              ledger=ledger, budget=budget)

    assert status == "committed"
    assert len(captured) == 1, "事务中途没读到那份标记"
    on_disk = captured[0]
    expected = build_inflight_marker(slot, rel_1m, rel_daily)

    started_at = on_disk.pop("started_at", None)
    assert isinstance(started_at, str) and started_at, (
        f"盘上那份标记缺少（或写坏了）started_at：{captured[0]!r}"
    )
    expected.pop("started_at")
    assert on_disk == expected, (
        "真正写到盘上的标记内容必须与 build_inflight_marker 的输出逐字相同"
        f"（除 started_at 外）——实测盘上是 {on_disk!r}，期望 {expected!r}"
    )


# ── I3：异常分类的穷尽性主张必须**是真的**（裸 OSError 是第三种）──────
# 模块头此前写「以下**两种**都不折进任何一族」然后列了两种，而 D3 主动要求
# 第三种：裸 `OSError`（PermissionError / EIO / ENOSPC）既不许折成
# `fetch_missing_file`，也不被包装成 `RunTerminated`。这条钉住的是「确实如此」
# 外加本模块给它的那条**位置保证**（逃出来时盘上什么都没落）。

def test_copy_stock_bare_oserror_from_source_escapes_unclassified(roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 5)
    _put_source_file(src_path, rel_daily, b"daily-data" * 5)

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    # staging 里两个子目录都还不存在 ⇒ `classify_target` 在 `parent_fd_under`
    # 那一步就返回 COPY，根本不调 `open_regular_probe`；于是下面这个桩**只**作用
    # 在源侧那一次打开上，红起来时归因是唯一的。
    def denying_probe(dir_fd, name, *, flags, mode=0o600):
        raise PermissionError(errno.EACCES, "打桩：模拟源文件读不了")

    monkeypatch.setattr(qmt_fetch, "open_regular_probe", denying_probe)

    with pytest.raises(PermissionError) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)

    assert not isinstance(ei.value, StockCopyFailed), (
        "契约 D3 明禁把权限错误折成 fetch_missing_file"
    )
    assert not isinstance(ei.value, RunTerminated), "本模块也不把它包装成终止条件"
    assert not isinstance(ei.value, PathEscapeError)
    # 位置保证：它只可能逃在在途标记写下之前 ⇒ 盘上什么都没落。
    assert not (stg_path / INFLIGHT).exists()
    assert not (stg_path / rel_1m).exists()
    assert not (stg_path / rel_daily).exists()
    assert not (stg_path / (rel_1m + PART)).exists()
    assert not (stg_path / (rel_daily + PART)).exists()
    assert budget.used == baseline
    assert read_manifest(stg_fd) == manifest, "manifest 一个字段都不该动"


# ── `_PERIODS` 与 `qmt_manifest.PERIODS` 是同一件事的两份副本 ──────────
# 分叉的话撞的是 `commit_stock` 里的 `_validate_files`——而那已经在**在途标记
# 写下、两个 final 落地之后**，正是 D6 要消灭的状态。顺带钉死 D1 的次序字面量。

def test_periods_tuple_agrees_with_qmt_manifest():
    assert qmt_fetch._PERIODS == PERIODS, (
        f"qmt_fetch._PERIODS={qmt_fetch._PERIODS!r} 与 qmt_manifest.PERIODS="
        f"{PERIODS!r} 分叉了"
    )
    assert qmt_fetch._PERIODS == ("1m", "daily"), "契约 D1 把次序钉死为 (1m, daily)"


# ══════════════════════════════════════════════════════════════════
# fix round 5（整支评审收尾）：两条 finding 的回归钉
# ══════════════════════════════════════════════════════════════════

# ── A：`_open_part` 的窄 `except` 纪律此前零覆盖 ──────────────────
# 模块头把「`_open_source_leaf` 与 `_open_part` 的窄 `except` 就是这条判据
# 本身，各有测试钉着」当规则写着，而**源侧那条有、staging 侧那条没有**：把
# `_open_part` 里的 `if _part_is_non_regular(stg_fd, rel):` 改成 `if True:`
# ——即「`.part` 打不开就一律当成篡改」，正是那条规则明禁的放宽——本模块 65 项
# 全绿、全套 1570 项全绿。放宽之后的实测后果：`ENOSPC`（staging 写满）/
# `EACCES`（权限）/ `EIO`（SMB 断线）三种基础设施故障全部变成
# `StockCopyFailed("untracked_target_file")`，被当成「有人篡改了 staging」
# 记进 failures 的那个桶、这只股被跳过——正是 D3 在源侧禁掉的那种混淆，
# 原样在 staging 侧复发。
#
# 打桩挂在 `.part` 的**打开点**上（`qmt_fetch.open_under` 在本模块里只有
# `_open_part` 一个消费者，归因唯一），与源侧那条测试同一套做法。
# ⚠️ 注入的信号**故意**是裸 `OSError`：被测代码正确时它原样逃出来，被测代码
# 放宽时它变成 `StockCopyFailed` —— 两个结局可区分，信号不会被洗成期望答案。

@pytest.mark.parametrize("err_code, what", [
    (errno.ENOSPC, "staging 写满"),
    (errno.EACCES, "权限不足"),
    (errno.EIO, "SMB 断线"),
])
def test_open_part_bare_oserror_escapes_and_is_not_called_tampering(
        roots, monkeypatch, err_code, what):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 10)
    _put_source_file(src_path, rel_daily, b"daily-data" * 10)
    # 子目录先建好：这样 `_part_is_non_regular` 会真的走到 `os.stat` 那一步
    # 并如实答「那底下什么都没有」，而不是在 `parent_fd_under` 就抄近路。
    (stg_path / "1m").mkdir()
    (stg_path / "daily").mkdir()
    assert not (stg_path / (rel_1m + PART)).exists(), (
        "前提：那个名字底下确实什么都没有——否则本档变成在测「确实是篡改」"
    )

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    def exploding_open_under(root_fd, relpath, *, flags, mode=0o600, create_dirs=False):
        assert relpath.endswith(PART), (
            f"本桩只该作用在 `.part` 的打开点上，却收到 {relpath!r}"
        )
        raise OSError(err_code, f"打桩：{what}")

    monkeypatch.setattr(qmt_fetch, "open_under", exploding_open_under)

    with pytest.raises(OSError) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)

    assert ei.value.errno == err_code
    assert not isinstance(ei.value, StockCopyFailed), (
        f"{what} 是基础设施故障，不是「有人往 staging 里植了东西」——"
        "把它折成 untracked_target_file 会让这只股被记进篡改那个桶（D3 在源侧"
        "禁掉的正是这种混淆），而 `_open_part` 的窄 except 就是这条判据本身"
    )
    assert not isinstance(ei.value, RunTerminated), "本模块也不把它包装成终止条件"
    assert not isinstance(ei.value, PathEscapeError)
    # 位置保证（标记写下之前那一段）：盘上什么都没落。
    assert not (stg_path / INFLIGHT).exists()
    assert not (stg_path / rel_1m).exists()
    assert not (stg_path / rel_daily).exists()
    assert not (stg_path / (rel_1m + PART)).exists()
    assert not (stg_path / (rel_daily + PART)).exists()
    assert budget.used == baseline
    assert read_manifest(stg_fd) == manifest, "manifest 一个字段都不该动"


# ── B：失败收尾对 `.part` 的类型闸，两个方向此前都没有测试 ────────────
# `_part_is_non_regular` 走 `lstat` ⇒ **符号链接也算非普通** ⇒ `_cleanup_part`
# 把它原样留着。这个行为是**故意保留**的（fail-closed：别人植进来的对象本工具
# 一律不动手），理由与它同 D2 的分界写在 `_cleanup_part` 的 docstring 里。
# 但此前它是**意外**成立的：两个方向都没有测试，谁都可以把它悄悄改掉。
# 变异 `if False:`（闸拆掉）→ 下面第一条红；变异 `if True:`（一律不删）
# → 下面第二条红。

def test_cleanup_keeps_a_planted_symlink_at_part(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 10)
    _put_source_file(src_path, rel_daily, b"daily-data" * 10)
    sub = stg_path / "1m"
    sub.mkdir()
    (sub / "elsewhere.bin").write_bytes(b"outside")
    part_1m = stg_path / (rel_1m + PART)
    part_1m.symlink_to(sub / "elsewhere.bin")

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    # 打开那一刻就撞 ELOOP ⇒ 整次致命（不是候选失败）——这一段是既有纪律。
    with pytest.raises(PathEscapeError) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)
    assert ei.value.errno == errno.ELOOP

    # 本档钉的是**收尾**那一半：别人植进来的对象，失败收尾一律不动手。
    assert part_1m.is_symlink(), (
        "植进 <rel>.part 的符号链接必须原样留着——本工具不替篡改者把证据顺手"
        "删掉，也不 unlink 一个可能指向 staging 树外的名字（fail-closed）"
    )
    assert (sub / "elsewhere.bin").read_bytes() == b"outside", "链接指向的对象也没被碰"


def test_cleanup_still_removes_an_ordinary_part_on_the_failure_path(roots, monkeypatch):
    # ⚠️ 与 `test_copy_stock_daily_missing_leaves_no_orphan_1m_final` 不重复：
    # 那一条只断言收尾之后 `.part` 不在，**没有证明它曾经在过**——`.part` 压根
    # 没被写出来时它一样绿。本档用一个中途探针先把「它真的在盘上」钉死，
    # 于是「收尾把它删了」这句话才有判别力。
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 10)   # daily 的源整段没导出过

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    part_1m = stg_path / (rel_1m + PART)
    midway: list[bool] = []
    real_open_source_leaf = qmt_fetch._open_source_leaf

    def spy_open_source_leaf(src_fd_, rel):
        if rel == rel_daily:
            midway.append(part_1m.is_file())
        return real_open_source_leaf(src_fd_, rel)

    monkeypatch.setattr(qmt_fetch, "_open_source_leaf", spy_open_source_leaf)

    with pytest.raises(StockCopyFailed) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)
    assert ei.value.reason == "fetch_missing_file"

    assert midway == [True], (
        "前提不成立：1m 的 .part 在事务中途根本没落到盘上，下面那条断言是恒真的"
    )
    assert not part_1m.exists() and not part_1m.is_symlink(), (
        "普通 .part 是本工具自己写下的残留——收尾必须删掉它。"
        "符号链接那一档的豁免只收窄「被篡改」那一格，不是把整条删除规则关掉"
    )


# ══════════════════════════════════════════════════════════════════
# fix round 6 · C1（评审 [high]）：`<rel>.part` 底下被植一个**硬链接**
# ══════════════════════════════════════════════════════════════════
# 硬链接是本模块所有既有检查的共同盲点：它**不是**符号链接（`O_NOFOLLOW` 管不到
# 它），而且它**就是**一个普通文件（`lstat`/`fstat` 的 `S_ISREG` 都答 True）——
# 于是 `_probe_part` 之前的那套判据一条都不会拦它，而旧写法的 `O_TRUNC` 会在
# 任何校验、任何回滚之前就把它指向的那个 **staging 树外**的文件清空。
# 解法与 `qmt_fsroot._atomic_write_bytes` 同规格：只写自己 `O_CREAT|O_EXCL` 刚
# 造出来的 inode，再 `os.replace` 发布——`replace` 换目录项、不碰目标 inode。

def test_copy_one_hard_linked_part_leaves_the_linked_file_byte_identical(roots, tmp_path):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    data = b"source-data" * 10
    _put_source_file(src_path, rel, data)

    outside = tmp_path / "outside.bin"          # ← staging 树**外面**的一个文件
    victim = b"v" * 145
    outside.write_bytes(victim)
    part = stg_path / (rel + PART)
    part.parent.mkdir(parents=True, exist_ok=True)
    os.link(str(outside), str(part))            # 植一个硬链接（不是符号链接）

    # 前提逐条钉死：否则本档测的就不是「硬链接」这件事。
    assert not part.is_symlink(), "前提：这不是符号链接，O_NOFOLLOW 对它无效"
    assert stat.S_ISREG(os.lstat(str(part)).st_mode), (
        "前提：硬链接**就是**一个普通文件——本模块的 S_ISREG 判据对它一律放行"
    )
    assert os.lstat(str(part)).st_ino == os.stat(str(outside)).st_ino, (
        "前提：两个名字指向同一个 inode，截断其中一个就是截断另一个"
    )
    assert len(data) != len(victim), (
        "前提：拷来的字节数与受害文件原本的字节数不同——否则「长度没变」这条"
        "断言碰巧也能通过一次真正的覆盖"
    )

    budget = ByteBudget(limit=None)
    result = copy_one(src_fd, stg_fd, rel, budget)

    assert outside.read_bytes() == victim, (
        "staging 树外面的那个文件必须逐字节不变——它被 O_TRUNC 清空正是本档要防的"
        "静默数据丢失（实测过：`copy_one` **正常返回**，而那个文件已经变成拷来的内容）"
    )
    assert os.lstat(str(part)).st_ino != os.stat(str(outside)).st_ino, (
        "`.part` 必须是一个**新 inode**（发布换的是目录项），而不是沿用被植进来的那个"
    )
    # 正路那一半同时也要成立：这只股照常拷完，不是靠「拒绝服务」换来的安全。
    assert result.n_bytes == len(data)
    assert result.sha256 == hashlib.sha256(data).hexdigest()
    assert part.read_bytes() == data
    assert budget.used == len(data)


def test_copy_one_publishes_over_an_ordinary_leftover_part(roots):
    # 「上一次运行崩在半路留下一个普通 `.part`」是**本 spec 自己产得出的合法
    # 状态**（大 spec §4.5：失败即删两个 `.part`，而 SIGKILL / 断电根本走不到
    # 那一步）。修法必须盖掉它、继续把这只股拷完，**不得**把它变成一次失败——
    # 否则一次断电会让这只股此后每次重跑都死在同一处。
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    data = b"fresh-source" * 7
    _put_source_file(src_path, rel, data)
    part = stg_path / (rel + PART)
    part.parent.mkdir(parents=True, exist_ok=True)
    part.write_bytes(b"half-written leftover from a killed run")
    stale_ino = os.lstat(str(part)).st_ino

    budget = ByteBudget(limit=None)
    result = copy_one(src_fd, stg_fd, rel, budget)

    assert result.n_bytes == len(data)
    assert part.read_bytes() == data, "残留的半截 `.part` 必须被本次拷贝盖掉"
    assert os.lstat(str(part)).st_ino != stale_ino, (
        "盖法是「发布一个新 inode」，不是「截断旧的那个」"
    )
    # 临时文件不留残骸：发布成功之后那个名字必须已经不在了。
    leftovers = [p.name for p in part.parent.iterdir() if p.name.endswith(".tmp")]
    assert leftovers == [], f"发布成功之后不该留下临时文件，实测 {leftovers}"


# ══════════════════════════════════════════════════════════════════
# fix round 6 · N1（评审 [medium]）：写在途标记这一步自己失败
# ══════════════════════════════════════════════════════════════════
# `_write_inflight_marker` 此前裸在回滚处置之外，于是 `atomic_write_json` 在
# **发布之前**失败（`ENOSPC`……）会同时漏掉两件事：两个已拷好的 `.part` 留在
# 盘上，本次扣的账也不退——什么都没提交、也没有任何恢复凭据，而预算被永久
# 占着（R1 那条「假的 --max-bytes 触顶」的喂料口）。
# 分界是**发布有没有发生**，不是「写标记那个函数返回了没有」：
#   · 发布之前炸 → 与其它标记前失败路径逐字同规格地清理（下面第一档）；
#   · 发布**之后**炸（紧跟的那次 `fsync(staging)`）→ D6 接管，一个字节都不清、
#     一分钱都不退（下面第二档，钉的是**不得过度清理**那一半）。
# 两档合起来才有判别力：只有第一档时，「一律清理」也能全绿。

def test_copy_stock_rolls_back_when_marker_write_fails_before_publication(roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 10)
    _put_source_file(src_path, rel_daily, b"daily-data" * 10)

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    part_1m = stg_path / (rel_1m + PART)
    part_daily = stg_path / (rel_daily + PART)
    seen: list[tuple] = []
    real_open_under = qmt_fsroot.open_under

    def exploding_open_under(root_fd, relpath, *, flags, mode=0o600, create_dirs=False):
        # 标记的临时文件就是在这一句被创建的（`_atomic_write_bytes`：唯一名 +
        # O_EXCL），而发布用的 `os.replace` 排在它之后 ⇒ 这里炸 = 发布之前炸。
        # ⚠️ 注入的是**裸 `OSError`**：被测代码正确/错误时它都原样逃出来，
        # 两个结局的差别全在盘面与预算上，信号不会被洗成期望答案。
        if relpath.startswith(INFLIGHT):
            seen.append((part_1m.is_file(), part_daily.is_file(),
                         (stg_path / INFLIGHT).exists()))
            raise OSError(errno.ENOSPC, "打桩：写标记的临时文件时 staging 满了")
        return real_open_under(root_fd, relpath, flags=flags, mode=mode,
                               create_dirs=create_dirs)

    monkeypatch.setattr(qmt_fsroot, "open_under", exploding_open_under)

    with pytest.raises(OSError) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)

    assert ei.value.errno == errno.ENOSPC
    assert not isinstance(ei.value, StockCopyFailed), "基础设施故障不折成候选失败"
    assert not isinstance(ei.value, RunTerminated), "也不包装成终止条件"
    assert seen == [(True, True, False)], (
        "前提不成立：炸的那一刻两个 `.part` 必须真的在盘上、标记必须**还没**发布"
        f"——否则下面几条断言是恒真的。实测 {seen}"
    )
    # 与其它「标记发布之前」的失败路径逐字同规格：盘上什么都没落、预算退干净。
    assert not part_1m.exists(), "发布没发生 ⇒ 两个 `.part` 必须删掉"
    assert not part_daily.exists(), "发布没发生 ⇒ 两个 `.part` 必须删掉"
    assert budget.used == baseline, (
        "发布没发生 ⇒ 本次扣的账必须退还——不退会让调用方在后面撞上一次**假的**"
        "`--max-bytes` 触顶，而那按大 spec §5 是「干净的配额停止」⇒ pilot 放行"
    )
    assert not (stg_path / INFLIGHT).exists()
    assert not (stg_path / rel_1m).exists()
    assert not (stg_path / rel_daily).exists()
    assert read_manifest(stg_fd) == manifest, "manifest 一个字段都不该动"


def test_copy_stock_keeps_everything_when_fsync_fails_after_marker_publication(
        roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    data_1m = b"1m-data" * 10
    data_daily = b"daily-data" * 10
    _put_source_file(src_path, rel_1m, data_1m)
    _put_source_file(src_path, rel_daily, data_daily)

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    part_1m = stg_path / (rel_1m + PART)
    part_daily = stg_path / (rel_daily + PART)
    seen: list[tuple] = []

    def exploding_fsync_dir(dir_fd):
        # `_atomic_write_bytes` 的最后一句，**排在 `os.replace` 之后**且不在它
        # 那个 `except BaseException` 的作用域里 ⇒ 这里炸 = 标记已经发布。
        seen.append((part_1m.is_file(), part_daily.is_file(),
                     (stg_path / INFLIGHT).exists()))
        raise OSError(errno.EIO, "打桩：发布之后那次 fsync(staging) 撞 EIO")

    monkeypatch.setattr(qmt_fsroot, "fsync_dir", exploding_fsync_dir)

    with pytest.raises(OSError) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)

    assert ei.value.errno == errno.EIO
    assert seen == [(True, True, True)], (
        "前提不成立：炸的那一刻标记必须**已经**在盘上（发布已经发生）、两个 "
        f"`.part` 也在——否则本档测的不是「发布之后」那一支。实测 {seen}"
    )
    # D6：一经发布，只有「提交成功 + 删标记」与「终止整次运行」两条出路。
    # 本函数在这一支里**不得**清理任何东西——那份标记是授权回滚的唯一凭据，
    # 它明写的两条 `.part` 必须还在，S4b 的崩溃恢复才回滚得了。
    assert (stg_path / INFLIGHT).exists(), "已发布的恢复凭据必须原样留在盘上"
    assert part_1m.is_file(), "标记里明写的 `.part` 不许被顺手删掉"
    assert part_daily.is_file(), "标记里明写的 `.part` 不许被顺手删掉"
    assert budget.used == baseline + len(data_1m) + len(data_daily), (
        "已发布 ⇒ 不退账：这两份字节此刻仍然占着盘，退了账面就与盘面对不上"
    )
    assert not (stg_path / rel_1m).exists(), "还没走到两次 final 替换"
    assert not (stg_path / rel_daily).exists()
    assert read_manifest(stg_fd) == manifest, "提交还没发生，manifest 一个字段没动"


# ══════════════════════════════════════════════════════════════════
# fix round 7（评审 [medium]，阻断）：**回滚自己失败**时，清理异常顶替掉原异常
# ══════════════════════════════════════════════════════════════════
# 三处收尾路径（`copy_one` 的临时文件、`copy_stock` 的主回滚、写标记失败那一支）
# 此前都是「顺着写成一串语句」：
#     _cleanup_part(A); _cleanup_part(B); refund(x); refund(y)
# 第一项一抛异常，后面每一项都不执行，而那个清理异常还会**顶替掉**在途的原异常。
# 后果有两层，都是本片从头在防的东西：
#   ① 一个意思是「终止整次运行」的 `SourceChangedMidRun` 会变成一个裸 `OSError`
#      到达调用方，而本模块自己的契约又允许把裸 `OSError` 当候选失败处置
#      ⇒ **必须停机的信号被降级成「这一只股失败了」**；
#   ② 没退的那笔账永久占着 `--max-bytes` ⇒ 一次**假的**配额触顶（残留 R1 那条
#      「一次基础设施故障被记成一次正常结束」）。
#
# ⚠️ **这三档的判别力挂在哪里，必须说准**：注入的是 `OSError`，而被测代码整段
# 工作就是处理 `OSError` —— 若只断言「抛了个 `OSError`」，改对改错**输出一模一样**。
# 故每一档都按三条**改对改错必然分叉**的判据断言：
#   (a) 逃出来的那个异常**是什么族**（修好之后：原终止信号原样、或 `RollbackIncomplete`；
#       改坏之后：清理那个裸 `OSError`）；
#   (b) 另一项清理**有没有被尝试过**（`seen` 按次序记下每一个命中的 leaf）；
#   (c) 预算**退没退**（`budget.used` 回没回到 baseline）。


def _explode_unlink_on(monkeypatch, predicate, err_code, note):
    """把 `os.unlink` 换成：命中 `predicate(leaf)` 的抛指定 errno，其余原样放行。

    返回的列表按调用次序记下**每一个命中**的 leaf —— 「另一项到底有没有被尝试过」
    这句断言的判别力全在它身上（顺着写的旧代码里，第二项根本不会被调到）。
    """
    seen: list[str] = []
    real_unlink = os.unlink

    def spy(path, *args, **kwargs):
        if isinstance(path, str) and predicate(path):
            seen.append(path)
            raise OSError(err_code, note)
        return real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(os, "unlink", spy)
    return seen


def test_rollback_incomplete_is_the_third_run_terminated_family_member():
    assert issubclass(RollbackIncomplete, RunTerminated)
    assert not issubclass(RollbackIncomplete, StockCopyFailed)
    assert not issubclass(RollbackIncomplete, OSError), (
        "它必须**不是** OSError —— 调用方区分「清理故障原样逃出来」与「本模块判定"
        "回滚没做完」靠的就是这一条"
    )
    assert not issubclass(RollbackIncomplete, PathEscapeError)


# ── 收尾路径 ①：`copy_one` 删自己那个临时文件时失败 ──────────────

def test_copy_one_still_refunds_and_terminates_when_temp_cleanup_fails(
        roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    data = b"payload" * 20
    _put_source_file(src_path, rel, data)

    budget = ByteBudget(limit=None, used=0)

    # 在途的原异常：拷到一半 SMB 断线。**裸 `OSError`**，按本模块契约既不属于
    # 候选失败也不属于终止条件 ⇒ 正是「回滚不完整就必须升级」那一支的输入。
    boom = OSError(errno.EIO, "打桩：拷到一半 SMB 断线")

    def exploding_write_all(fd, payload):
        raise boom

    monkeypatch.setattr(qmt_fetch, "_write_all", exploding_write_all)
    seen = _explode_unlink_on(
        monkeypatch,
        lambda leaf: leaf.endswith(".tmp") and PART in leaf,
        errno.EACCES, "打桩：删临时文件撞 EACCES")

    with pytest.raises(RunTerminated) as ei:
        copy_one(src_fd, stg_fd, rel, budget)

    # (b) 前提：删除确实被尝试过一次且确实失败了，否则下面全是恒真断言。
    assert len(seen) == 1 and seen[0].endswith(".tmp"), (
        f"前提不成立：临时文件的删除压根没被调到，实测 {seen}")
    leftovers = [p.name for p in (stg_path / "1m").iterdir()
                 if p.name.endswith(".tmp")]
    assert len(leftovers) == 1, (
        f"前提不成立：注入没生效，临时文件还是被删掉了（实测 {leftovers}）"
        "——那样「回滚不完整」这个前提根本不成立")

    # (a) 逃出来的不是那个清理异常，而是本模块明确定性的终止信号。
    exc = ei.value
    assert isinstance(exc, RollbackIncomplete)
    assert not isinstance(exc, OSError), "清理的 EACCES 不许原样逃出来顶替原异常"
    assert exc.original is boom, "在途的那个原异常必须原封不动地留在 `.original` 上"
    assert exc.__cause__ is boom
    assert [e.errno for e in exc.errors] == [errno.EACCES], \
        "回滚里失败的那一项必须被结构化地交出来，不是被悄悄咽掉"
    assert any("回滚未完成" in n for n in boom.__notes__), \
        "诊断也要挂在原异常上——调用方打印哪一个都看得见"

    # (c) 删除失败**不得**吃掉退账：这一趟逐块扣的账必须回到起点。
    assert budget.used == 0, (
        "删临时文件失败连退账一起跳过 ⇒ 这笔字节永久占着 --max-bytes ⇒ "
        "后面撞一次**假的**配额触顶（残留 R1 的喂料口）")


# ── 收尾路径 ②a：主回滚失败，而在途的原异常**本来就是终止信号** ──
# 本档钉的正是评审那句话的字面意思：一个「终止整次运行」的信号绝不许被清理
# 异常换成别的东西。改坏之后逃出来的是 `OSError`，`pytest.raises` 当场红。

def test_copy_stock_keeps_the_terminate_signal_when_both_part_cleanups_fail(
        roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"

    data_1m = b"1m-unchanged" * 8
    old_daily = b"daily-old" * 7
    new_daily = b"daily-NEW-generation" * 5     # 源在本次运行期间换代了
    _put_source_file(src_path, rel_1m, data_1m)
    _put_source_file(src_path, rel_daily, new_daily)
    # 两个 staging 目标都不存在 ⇒ 两格都是 TARGET_COPY ⇒ 两个 `.part` 都会落盘，
    # 「另一项有没有被尝试」才有得测（只落一个 `.part` 的话那句断言是恒真的）。

    rec_1m = {"stock_code": "600000.SH", "period": "1m", "relative_path": rel_1m,
              "bytes": len(data_1m), "sha256": hashlib.sha256(data_1m).hexdigest()}
    rec_daily = {"stock_code": "600000.SH", "period": "daily",
                 "relative_path": rel_daily, "bytes": len(old_daily),
                 "sha256": hashlib.sha256(old_daily).hexdigest()}
    manifest, export_log_bytes = _seed_manifest()
    manifest["files"] = [rec_1m, rec_daily]
    manifest["pool_order"]["SH"] = [{"code": "600000.SH", "universe_idx": 0}]
    manifest["cursor"]["SH"] = 1
    manifest["committed_bytes"] = (
        len(export_log_bytes) + len(data_1m) + len(old_daily))
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    assert classify_target(stg_fd, rel_1m, rec_1m) == TARGET_COPY
    assert classify_target(stg_fd, rel_daily, rec_daily) == TARGET_COPY

    seen = _explode_unlink_on(
        monkeypatch, lambda leaf: leaf.endswith(PART),
        errno.EIO, "打桩：删 .part 撞 EIO")

    with pytest.raises(SourceChangedMidRun) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)

    exc = ei.value
    # (a) 类型一个字不换：D5 的终止信号不许被一条清理故障洗成别的东西。
    assert not isinstance(exc, OSError), (
        "清理的 EIO 顶替掉 SourceChangedMidRun ⇒ 一条**必须停机**的信号会以裸 "
        "`OSError` 的样子到达 S4b，而本模块的契约允许把裸 `OSError` 当候选失败处置"
        "⇒ 这只股被跳过、整次运行接着跑")
    assert not isinstance(exc, StockCopyFailed)
    # (b) 两条 `.part` 各被尝试过一次——第一条失败不得让第二条不执行。
    assert len(seen) == 2, f"两条 `.part` 必须各被尝试删一次，实测 {seen}"
    assert seen[0].endswith(PART) and seen[1].endswith(PART)
    assert (stg_path / (rel_1m + PART)).is_file()
    assert (stg_path / (rel_daily + PART)).is_file(), \
        "前提不成立：注入没生效（.part 还是被删掉了）"
    # (c) 两笔退账照做。
    assert budget.used == baseline, "清理失败不得吃掉退账"
    assert len(getattr(exc, "__notes__", [])) == 2, (
        f"两项清理失败都要留下诊断，不许静默咽掉，实测 {getattr(exc, '__notes__', [])}")

    assert not (stg_path / INFLIGHT).exists()
    assert read_manifest(stg_fd) == manifest, "D5：manifest 一个字段都不该动"


# ── 收尾路径 ②b：主回滚失败，而在途的原异常是一次**候选失败** ────
# 本档钉的是第二个决定：回滚没做完时**不许**把原异常原样放出去当候选失败
# ——staging 侧的 EIO 是这棵树的事实，后面每一只股都会撞到。

def test_copy_stock_escalates_a_candidate_failure_when_rollback_is_incomplete(
        roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 10)   # daily 的源整段没导出过

    # 上一次运行崩在半路留下的 daily `.part`（合法状态）：让「第二项清理」确实
    # 有活可干，于是「第一项失败不得跳过第二项」这句断言不是恒真的。
    (stg_path / "daily").mkdir()
    (stg_path / (rel_daily + PART)).write_bytes(b"stale part")

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    seen = _explode_unlink_on(
        monkeypatch, lambda leaf: leaf.endswith(PART),
        errno.EIO, "打桩：删 .part 撞 EIO")

    with pytest.raises(RunTerminated) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)

    exc = ei.value
    assert isinstance(exc, RollbackIncomplete)
    assert not isinstance(exc, StockCopyFailed), (
        "盘面/账面已经对不上（而且对不上的方式本模块并不知道）⇒ 不许让 S4b 按"
        "「跳过这只股」继续跑")
    assert not isinstance(exc, OSError), "也不是把清理那个 EIO 原样放出去"
    assert isinstance(exc.original, StockCopyFailed)
    assert exc.original.reason == "fetch_missing_file", \
        "原来那条候选失败的定性必须原封不动地留着，不是被换掉"
    assert exc.__cause__ is exc.original
    assert len(seen) == 2, f"两条 `.part` 必须各被尝试删一次，实测 {seen}"
    assert [e.errno for e in exc.errors] == [errno.EIO, errno.EIO]
    assert budget.used == baseline, "清理失败不得吃掉退账"


# ── 收尾路径 ③：写在途标记在**发布之前**失败，而回滚自己也失败 ────

def test_copy_stock_marker_write_failure_still_reconciles_when_cleanup_fails(
        roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    rel_1m = "1m/600000.SH_x_1分钟K线_前复权.csv"
    rel_daily = "daily/600000.SH_x_日K线_前复权.csv"
    _put_source_file(src_path, rel_1m, b"1m-data" * 10)
    _put_source_file(src_path, rel_daily, b"daily-data" * 10)

    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])
    baseline = budget.used

    part_1m = stg_path / (rel_1m + PART)
    part_daily = stg_path / (rel_daily + PART)
    at_blast: list[tuple] = []
    real_open_under = qmt_fsroot.open_under

    def exploding_open_under(root_fd, relpath, *, flags, mode=0o600, create_dirs=False):
        # 标记的临时文件在这一句被创建，发布用的 `os.replace` 排在它之后
        # ⇒ 这里炸 = **发布之前**炸 ⇒ 走的是清理那一支，不是 D6 那一支。
        if relpath.startswith(INFLIGHT):
            at_blast.append((part_1m.is_file(), part_daily.is_file(),
                             (stg_path / INFLIGHT).exists()))
            raise OSError(errno.ENOSPC, "打桩：写标记的临时文件时 staging 满了")
        return real_open_under(root_fd, relpath, flags=flags, mode=mode,
                               create_dirs=create_dirs)

    monkeypatch.setattr(qmt_fsroot, "open_under", exploding_open_under)
    # 只拦 `.part`；标记自己那个 `.inflight.json.<pid>.<hex>.tmp` 不在射程内。
    seen = _explode_unlink_on(
        monkeypatch, lambda leaf: leaf.endswith(PART),
        errno.EIO, "打桩：删 .part 撞 EIO")

    with pytest.raises(RunTerminated) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)

    assert at_blast == [(True, True, False)], (
        "前提不成立：炸的那一刻两个 `.part` 必须真的在盘上、标记必须**还没**发布"
        f"——否则本档测的不是这一支。实测 {at_blast}")

    exc = ei.value
    assert isinstance(exc, RollbackIncomplete)
    assert not isinstance(exc, OSError), "清理的 EIO 不许原样逃出来顶替 ENOSPC"
    assert exc.original.errno == errno.ENOSPC, \
        "在途的原异常是写标记那次 ENOSPC，不是清理那次 EIO"
    assert len(seen) == 2, f"两条 `.part` 必须各被尝试删一次，实测 {seen}"
    assert budget.used == baseline, (
        "退账被清理失败吃掉 ⇒ 调用方后面会撞一次**假的** `--max-bytes` 触顶")
    assert not (stg_path / INFLIGHT).exists(), "发布确实没发生"
    assert read_manifest(stg_fd) == manifest, "manifest 一个字段都不该动"


# ══════════════════════════════════════════════════════════════════
# fix round 8 · codex R5 [medium]：**关描述符也是收尾动作**
# ══════════════════════════════════════════════════════════════════
#
# 评审点名的是 `copy_one` 里关**源**描述符那一句（它此前裸在 `finally:` 里、
# 在失败收尾的 `except` **外面**），但这是 fix round 7 那条判据的**复发**
# ——「收尾动作抛的异常顶替在途原异常 / 吃掉后续收尾项」——所以本轮按判据穷尽
# 本模块：12 个关闭点、10 个 `finally:` 块逐个定性，同型的一并收进
# `_close_or_note` 这一个判据（`_CloseFd` 是它的 `with` 外壳）。
#
# 两条判别力都必须说准（注入的是 `OSError`，而被测代码整段工作就是处理
# `OSError`，只断言「抛了个 OSError」改对改错输出一模一样）：
#   · **有异常在途** ⇒ 关闭失败只挂 `add_note` 诊断，在途那个异常**类型一个字不换**
#     ⇒ 断言逃出来的是 `MaxBytesExhausted` / `PathEscapeError` /
#       `StockCopyFailed(reason=...)` 本身，且 `not isinstance(exc, OSError)`；
#   · **没有异常在途** ⇒ 关闭失败**原样上抛**，并落进失败收尾
#     ⇒ 断言退账做了（`budget.used` 回到 baseline）、已发布的 `.part` 清掉了。


def _explode_close_on(monkeypatch, pick, err_code, note, on_fire=None):
    """把 `os.close` 换成：命中 `pick(fd)` 的那一个**先真关掉、再抛**指定 errno，
    其余原样放行；命中一次后自动解除武装（描述符号会被后面的 `open` 复用）。

    **「先真关掉」是刻意的**：真实世界里 `close()` 报错（回写撞 `EIO`、`ENOSPC`）
    之后描述符通常已经被回收；测试若不关，泄漏的 fd 会污染同进程后面的用例。
    返回的列表按次序记下每一次命中——「注入到底有没有生效」这句**前提断言**全靠它，
    没有它，下面那些「逃出来的是原异常」就可能是恒真的（压根没注入成功）。
    """
    seen: list[int] = []
    real_close = os.close
    armed = {"on": True}

    def spy(fd):
        if armed["on"] and pick(fd):
            armed["on"] = False
            seen.append(fd)
            if on_fire is not None:
                on_fire()
            real_close(fd)
            raise OSError(err_code, note)
        return real_close(fd)

    monkeypatch.setattr(os, "close", spy)
    return seen


def _capture_source_fd(monkeypatch) -> dict:
    """记下 `_open_source_leaf` 交出来的那个源描述符（`copy_one` 的 `sfd`）。"""
    holder: dict = {}
    real = qmt_fetch._open_source_leaf

    def spy(src_fd, rel):
        fd, st = real(src_fd, rel)
        holder["sfd"] = fd
        return fd, st

    monkeypatch.setattr(qmt_fetch, "_open_source_leaf", spy)
    return holder


def _growing_source_read(monkeypatch, blocks: int, chunk: int):
    """让 `os.read` 比 `stat` 量到的多读出几块——`budget.charge` 因此会在**拷到
    一半**时抛 `MaxBytesExhausted`（与既有的
    `test_copy_one_charge_enforces_independently_of_precheck` 同一个桩）。
    """
    monkeypatch.setattr(qmt_fetch, "_CHUNK", chunk)
    real_read = os.read
    n = {"i": 0}

    def growing(fd, size):
        n["i"] += 1
        if n["i"] <= blocks:
            return b"g" * chunk
        return real_read(fd, size)

    monkeypatch.setattr(os, "read", growing)


# ── 点名那一处 ①：拷贝成功、**发布之后**关源描述符失败 ────────────
# 契约 §3b T4 钉死的收口是「退账 + 清掉自己刚发布的那份 `.part`」，不是
# 「把落地物留下、把字节数交给调用方」。本测试钉的就是这个选择。

def test_copy_one_refunds_and_cleans_its_part_when_closing_source_fails(
        roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    _put_source_file(src_path, rel, b"payload" * 20)

    budget = ByteBudget(limit=None, used=17)
    baseline = budget.used

    holder = _capture_source_fd(monkeypatch)
    at_blast: list[bool] = []
    seen = _explode_close_on(
        monkeypatch, lambda fd: fd == holder.get("sfd"),
        errno.EIO, "打桩：关源描述符时撞 EIO",
        on_fire=lambda: at_blast.append((stg_path / (rel + PART)).is_file()))

    with pytest.raises(OSError) as ei:
        copy_one(src_fd, stg_fd, rel, budget)

    # 前提 ①：注入确实打在源描述符上，且恰好一次。
    assert seen == [holder["sfd"]], f"前提不成立：注入没打在源描述符上，实测 {seen}"
    # 前提 ②：炸的那一刻**发布已经发生**——否则测的不是评审点名的那一档。
    assert at_blast == [True], (
        f"前提不成立：关源描述符时 `{rel}{PART}` 还没在盘上，实测 {at_blast}")

    exc = ei.value
    # (a) 族籍：它是**裸 `OSError`**（§4 第 10 条：处置由 S4b 选），不是本模块
    #     的三族之一——本轮不许顺手把它改成别的东西。
    assert exc.errno == errno.EIO
    assert not isinstance(exc, StockCopyFailed)
    assert not isinstance(exc, RunTerminated)
    # (b) 退账做了：改坏之后 `copy_one` 永远不返回 ⇒ `copy_stock` 不会把这个文件
    #     记进 `written` ⇒ 这 140 字节永久占着 `--max-bytes`（残留 R1 的喂料口）。
    assert budget.used == baseline, (
        f"关源失败吃掉了退账：baseline={baseline}，实测 {budget.used}")
    # (c) 自己刚发布的那份落地物清掉了——「逃出来的那一刻盘上什么都没落」。
    assert not (stg_path / (rel + PART)).exists(), \
        "已发布的 `.part` 漏清：调用方既拿不到字节数，盘上却留着东西"
    assert [p.name for p in (stg_path / "1m").iterdir()] == [], \
        "临时文件也不该留下"


# ── 点名那一处 ②：`MaxBytesExhausted` 展开途中关源描述符失败 ──────

def test_copy_one_keeps_max_bytes_exhausted_when_closing_source_fails(
        roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_growing.csv"
    _put_source_file(src_path, rel, b"w" * 64)
    _growing_source_read(monkeypatch, blocks=3, chunk=64)

    budget = ByteBudget(limit=100)      # 64 过 precheck；累计到 128 时 charge 拒
    holder = _capture_source_fd(monkeypatch)
    seen = _explode_close_on(
        monkeypatch, lambda fd: fd == holder.get("sfd"),
        errno.EIO, "打桩：关源描述符时撞 EIO")

    with pytest.raises(RunTerminated) as ei:
        copy_one(src_fd, stg_fd, rel, budget)

    assert seen == [holder["sfd"]], f"前提不成立：注入没打在源描述符上，实测 {seen}"

    exc = ei.value
    assert isinstance(exc, MaxBytesExhausted), (
        "关源描述符那次 EIO 顶替掉了 `MaxBytesExhausted` ⇒ 一条**必须停机**的信号"
        "以裸 `OSError` 的样子到达 S4b，而 §4 第 10 条允许它把裸 `OSError` 当候选"
        "失败处置 ⇒ 这只股被跳过、整次运行接着跑")
    assert not isinstance(exc, OSError)
    assert not isinstance(exc, StockCopyFailed)
    assert any("关描述符失败" in n for n in getattr(exc, "__notes__", [])), \
        "关闭失败必须留下诊断，不许静默咽掉"
    assert budget.used == 0, "已扣的那一块仍要退还"
    assert not (stg_path / (rel + PART)).exists()


# ── 同一判据，`copy_one` 里的**写侧**描述符（`dfd`）───────────────
# 它比源描述符更容易在真实环境里关失败（关的时候才回写，SMB/NFS 上撞 EIO/ENOSPC）。

def test_copy_one_keeps_max_bytes_exhausted_when_closing_dest_fails(
        roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_growing.csv"
    _put_source_file(src_path, rel, b"w" * 64)
    _growing_source_read(monkeypatch, blocks=3, chunk=64)

    dest: dict = {}
    real_open_part = qmt_fetch._open_part

    def spy_open_part(stg, name, *, flags, create_dirs=False):
        fd = real_open_part(stg, name, flags=flags, create_dirs=create_dirs)
        if flags & os.O_CREAT:
            dest["dfd"] = fd
        return fd

    monkeypatch.setattr(qmt_fetch, "_open_part", spy_open_part)
    budget = ByteBudget(limit=100)
    seen = _explode_close_on(
        monkeypatch, lambda fd: fd == dest.get("dfd"),
        errno.EIO, "打桩：关写侧描述符时回写撞 EIO")

    with pytest.raises(RunTerminated) as ei:
        copy_one(src_fd, stg_fd, rel, budget)

    assert seen == [dest["dfd"]], f"前提不成立：注入没打在写侧描述符上，实测 {seen}"
    exc = ei.value
    assert isinstance(exc, MaxBytesExhausted), \
        "关写侧描述符那次 EIO 顶替掉了 `MaxBytesExhausted`（同上，停机信号被降级）"
    assert not isinstance(exc, OSError)
    assert budget.used == 0
    assert not (stg_path / (rel + PART)).exists()


# ── 同一判据：`_publish_part` 在 `os.replace` **成功之后**关目录描述符失败 ──
# 这一档是「漏记账 / 漏清理」那一格：发布已经发生，而 `copy_one` 只收到一个裸
# `OSError`，分辨不了发布到底发生没有 ⇒ 回滚名单必须从**准备发布那一刻起**
# 就把 `<rel>.part` 算进去（契约 §3b T4）。

def test_copy_one_cleans_up_when_publish_succeeds_but_its_close_fails(
        roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    _put_source_file(src_path, rel, b"payload" * 20)

    budget = ByteBudget(limit=None, used=17)
    baseline = budget.used

    real_replace = os.replace
    real_close = os.close
    armed = {"on": False}
    at_blast: list[bool] = []

    def spy_replace(a, b, *args, **kwargs):
        out = real_replace(a, b, *args, **kwargs)
        armed["on"] = True      # 发布已经发生：紧跟的那次关闭就是 `_publish_part` 的
        return out

    def spy_close(fd):
        if armed["on"]:
            armed["on"] = False
            at_blast.append((stg_path / (rel + PART)).is_file())
            real_close(fd)
            raise OSError(errno.EIO, "打桩：发布成功之后关目录描述符撞 EIO")
        return real_close(fd)

    monkeypatch.setattr(os, "replace", spy_replace)
    monkeypatch.setattr(os, "close", spy_close)

    with pytest.raises(OSError) as ei:
        copy_one(src_fd, stg_fd, rel, budget)

    assert at_blast == [True], (
        f"前提不成立：注入没打在「发布已经发生」之后，实测 {at_blast}")
    exc = ei.value
    assert exc.errno == errno.EIO
    assert not isinstance(exc, StockCopyFailed)
    assert not isinstance(exc, RunTerminated)
    assert budget.used == baseline, "发布已发生而调用方拿不到字节数 ⇒ 必须退账"
    assert not (stg_path / (rel + PART)).exists(), \
        "已发布的 `.part` 漏清：`copy_one` 分辨不了发布发生没有，就必须两个名字都清"


# ── 同一判据：`_open_source_leaf` 关父目录描述符 —— 顶替 `PathEscapeError` ──
# 这是最严重的一格：一次**信任边界被破坏**（整次致命、不属于任何一族）被换成
# 裸 `OSError`，而裸 `OSError` 的处置 §4 第 10 条允许 S4b 当候选失败跳过。

def test_open_source_leaf_keeps_path_escape_when_closing_parent_fails(
        roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    _put_source_file(src_path, rel, b"payload" * 20)

    parents: dict = {}
    real_parent_fd_under = qmt_fetch.parent_fd_under

    def spy_parent(root_fd, relpath, **kwargs):
        pfd, leaf = real_parent_fd_under(root_fd, relpath, **kwargs)
        parents["pfd"] = pfd
        return pfd, leaf

    monkeypatch.setattr(qmt_fetch, "parent_fd_under", spy_parent)

    boom = PathEscapeError(relative_path=rel, component="1m",
                            errno=errno.ELOOP)

    def escaping_probe(pfd, leaf, *, flags):
        raise boom

    monkeypatch.setattr(qmt_fetch, "open_regular_probe", escaping_probe)
    seen = _explode_close_on(
        monkeypatch, lambda fd: fd == parents.get("pfd"),
        errno.EIO, "打桩：关源侧父目录描述符撞 EIO")

    with pytest.raises(PathEscapeError) as ei:
        copy_one(src_fd, stg_fd, rel, ByteBudget(limit=None))

    assert seen == [parents["pfd"]], f"前提不成立：注入没生效，实测 {seen}"
    assert ei.value is boom, (
        "关父目录那次 EIO 顶替掉了 `PathEscapeError` ⇒ 一次信任边界破坏会以裸 "
        "`OSError` 的样子到达 S4b，被当成「这只股不行」跳过")
    assert not isinstance(ei.value, OSError)


# ── 同一判据：`classify_target` 关父目录描述符 —— 顶替 `PathEscapeError` ──
# `classify_target` 的 docstring 明写「符号链接**绝不会**被归进 `TARGET_UNTRACKED`，
# 一次符号链接就是一次信任边界破坏，必须整次运行终止」。

def test_classify_target_keeps_path_escape_when_closing_parent_fails(
        roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    (stg_path / "1m").mkdir()

    parents: dict = {}
    real_parent_fd_under = qmt_fetch.parent_fd_under

    def spy_parent(root_fd, relpath, **kwargs):
        pfd, leaf = real_parent_fd_under(root_fd, relpath, **kwargs)
        parents["pfd"] = pfd
        return pfd, leaf

    monkeypatch.setattr(qmt_fetch, "parent_fd_under", spy_parent)

    boom = PathEscapeError(relative_path=rel, component="1m",
                            errno=errno.ELOOP)

    def escaping_probe(pfd, leaf, *, flags):
        raise boom

    monkeypatch.setattr(qmt_fetch, "open_regular_probe", escaping_probe)
    seen = _explode_close_on(
        monkeypatch, lambda fd: fd == parents.get("pfd"),
        errno.EIO, "打桩：关 staging 父目录描述符撞 EIO")

    with pytest.raises(PathEscapeError) as ei:
        classify_target(stg_fd, rel, None)

    assert seen == [parents["pfd"]], f"前提不成立：注入没生效，实测 {seen}"
    assert ei.value is boom, (
        "关父目录那次 EIO 顶替掉了 `PathEscapeError` ⇒ 一次信任边界破坏被降级")
    assert not isinstance(ei.value, OSError)


# ── 同一判据：`_open_part` 的失败关闭 —— 顶替 `untracked_target_file` ────
# 这一格丢的不是族籍而是**定性**：本该记进 `failures[].reason` 的
# `untracked_target_file` 变成一个无定性的裸 `OSError`。

def test_open_part_keeps_untracked_reason_when_its_close_fails(
        roots, monkeypatch):
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    _put_source_file(src_path, rel, b"payload" * 20)
    part = stg_path / (rel + PART)
    part.mkdir(parents=True)        # 目录：`O_RDONLY` 打开**成功**、`S_ISREG` 为假

    opened: dict = {}
    real_open_under = qmt_fetch.open_under

    def spy_open_under(root_fd, relpath, *, flags, mode=0o600, create_dirs=False):
        fd = real_open_under(root_fd, relpath, flags=flags, mode=mode,
                             create_dirs=create_dirs)
        opened["fd"] = fd
        return fd

    monkeypatch.setattr(qmt_fetch, "open_under", spy_open_under)
    seen = _explode_close_on(
        monkeypatch, lambda fd: fd == opened.get("fd"),
        errno.EIO, "打桩：关那个目录描述符撞 EIO")

    budget = ByteBudget(limit=None, used=7)
    with pytest.raises(StockCopyFailed) as ei:
        copy_one(src_fd, stg_fd, rel, budget)

    assert seen == [opened["fd"]], f"前提不成立：注入没生效，实测 {seen}"
    assert ei.value.reason == "untracked_target_file", (
        "关闭失败顶替掉了那条候选失败 ⇒ 这只股丢掉了自己的 `reason`，"
        "落不进 4c 报告 schema 的任何一个桶")
    assert not isinstance(ei.value, OSError)
    assert budget.used == 7
    assert part.is_dir(), "来路不明的对象要原样留着"


# ══════════════════════════════════════════════════════════════════
# fix round 9：把「捕获宽度」这个刻意决定钉住
# ══════════════════════════════════════════════════════════════════
#
# `_close_or_note` 关描述符、`_rollback_all` 删项、`_rollback_all` 退账项——
# 这三处 `except Exception as e:` 此前只在 docstring 里写着理由（`KeyboardInterrupt`
# / `SystemExit` 不是「这一项失败了」，不许被收进明细或挂成诊断顺手咽掉），把
# 宽度悄悄改成 `except BaseException` 之后全套测试原样通过——这个决定只活在散文里。
#
# 本节给每一处各配一条测试，注入 `KeyboardInterrupt`（真实场景：长时间运行时用户
# 按 Ctrl-C），钉住「非 `Exception` 的 `BaseException` 必须原样逃出去，不许被记进
# 诊断、不许被收进 `RollbackIncomplete.errors`」。
#
# 三条测试的判别力互斥：同一次调用里，三处 `except` 里**恰好有一处**真的接到一个
# 正在传播的异常——另外两处这一趟根本没轮到执行（要么没有异常在途，要么循环已经
# 被这次中断打断、还没轮到那一行），所以把其中一处放宽成 `except BaseException`
# 不会牵动另外两条测试的结论；下面每条测试都用一句「另一半确实先正常做完了」的
# 前提断言把这一点钉住，而不是靠推断。

def test_close_or_note_lets_keyboard_interrupt_escape_when_closing_source_fails(
        roots, monkeypatch):
    """钉 `_close_or_note` 那一处（紧跟 `os.close(fd)`）：源描述符关闭时抛
    `KeyboardInterrupt`，正在展开的 `MaxBytesExhausted` 不许被顶替，中断本身
    不许被 `_close_or_note` 当成诊断记到 `__notes__` 上。"""
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_growing.csv"
    _put_source_file(src_path, rel, b"w" * 64)
    _growing_source_read(monkeypatch, blocks=3, chunk=64)

    budget = ByteBudget(limit=100)      # 64 过 precheck；累计到 128 时 charge 拒
    holder = _capture_source_fd(monkeypatch)

    real_close = os.close
    seen: list[int] = []
    armed = {"on": True}

    def spy_close(fd):
        if armed["on"] and fd == holder.get("sfd"):
            armed["on"] = False
            seen.append(fd)
            real_close(fd)
            raise KeyboardInterrupt()
        return real_close(fd)

    monkeypatch.setattr(os, "close", spy_close)

    with pytest.raises(KeyboardInterrupt) as ei:
        copy_one(src_fd, stg_fd, rel, budget)

    assert seen == [holder["sfd"]], f"前提不成立：注入没打在源描述符上，实测 {seen}"

    exc = ei.value
    # (a) 逃出来的就是那个中断本身，没有被换成别的族籍。
    assert not isinstance(exc, Exception), (
        "`KeyboardInterrupt` 不是 `Exception` 的子类——本条断言本身就是判据所在")
    # (b) 没有被当成诊断记下来：一旦被 `except BaseException` 接住，会转手
    #     `pending.add_note(...)`，而不是原样放行。
    assert not any("关描述符失败" in n for n in getattr(exc, "__notes__", [])), (
        "中断被记进了诊断，说明关闭失败那一格把它当成「这次关闭失败了」顺手"
        "咽掉，而不是原样放行")
    # (c) `_close_or_note` 只是不吃中断，不代表 `copy_one` 外层的收尾也被跳过：
    #     已扣的字节仍然要退、已创建的临时文件仍然要清。
    assert budget.used == 0, "已扣的那一块字节应当退还"
    assert not (stg_path / (rel + PART)).exists()
    assert [p.name for p in (stg_path / "1m").iterdir()] == [], "临时文件也不该留下"


def test_rollback_lets_keyboard_interrupt_escape_when_deleting_a_part_fails(
        roots, monkeypatch):
    """钉 `_rollback_all` 删项那一处（紧跟 `_cleanup_part(stg_fd, name)`）：
    删 `.tmp` 抛 `KeyboardInterrupt` 时，在途的原异常（一次裸 `OSError`）不许
    被升级成 `RollbackIncomplete`——中断必须原样逃出去，当场打断这个 for 循环，
    退账那一半因此这一趟根本没轮到执行（已登记代价，不是本档要防的事）。"""
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    data = b"payload" * 20
    _put_source_file(src_path, rel, data)

    budget = ByteBudget(limit=None, used=0)
    boom = OSError(errno.EIO, "打桩：拷到一半 SMB 断线")

    def exploding_write_all(fd, payload):
        raise boom

    monkeypatch.setattr(qmt_fetch, "_write_all", exploding_write_all)

    real_unlink = os.unlink
    seen: list[str] = []

    def spy_unlink(path, *args, **kwargs):
        if isinstance(path, str) and path.endswith(".tmp") and PART in path:
            seen.append(path)
            raise KeyboardInterrupt()
        return real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(os, "unlink", spy_unlink)

    with pytest.raises(KeyboardInterrupt) as ei:
        copy_one(src_fd, stg_fd, rel, budget)

    # 前提：删除确实被尝试过一次、且注入确实生效（临时文件还在盘上）。
    assert len(seen) == 1 and seen[0].endswith(".tmp"), (
        f"前提不成立：临时文件的删除压根没被调到，实测 {seen}")
    leftovers = [p.name for p in (stg_path / "1m").iterdir()
                 if p.name.endswith(".tmp")]
    assert len(leftovers) == 1, (
        f"前提不成立：注入没生效，临时文件还是被删掉了（实测 {leftovers}）")

    exc = ei.value
    assert not isinstance(exc, Exception), (
        "`KeyboardInterrupt` 不是 `Exception` 的子类——本条断言本身就是判据所在")
    assert not getattr(boom, "__notes__", []), (
        "删除那一项失败被计入了回滚诊断，说明中断被更宽的判据接住、当成了"
        "「这一项没删成」而不是原样放行")
    # 中断当场打断了 `_rollback_all` 的第一个 for 循环，退账那半这一趟根本没
    # 轮到执行——已扣的账没退是已知代价，不是判据缺陷；这也是「退账那一处
    # 这一趟根本没执行到」的证据，证明本条与下一条测的不是同一处。
    assert budget.used == len(data), "已扣的账没退是中断打断整段收尾的已知代价"


def test_rollback_lets_keyboard_interrupt_escape_when_refunding_fails(
        roots, monkeypatch):
    """钉 `_rollback_all` 退账项那一处（紧跟 `budget.refund(n)`）：删除那一半
    先正常完成，`budget.refund` 才抛 `KeyboardInterrupt`——同一个原异常、同一个
    函数，命中的是循环体的**另一半**，与上一条测试互斥地各命中一处，证明两条
    不是同一条判据的两份拷贝。"""
    src_fd, stg_fd, src_path, stg_path = roots
    rel = "1m/600000.SH_x_1分钟K线_前复权.csv"
    data = b"payload" * 20
    _put_source_file(src_path, rel, data)

    budget = ByteBudget(limit=None, used=0)
    boom = OSError(errno.EIO, "打桩：拷到一半 SMB 断线")

    def exploding_write_all(fd, payload):
        raise boom

    monkeypatch.setattr(qmt_fetch, "_write_all", exploding_write_all)

    seen: list[int] = []

    def exploding_refund(n):
        seen.append(n)
        raise KeyboardInterrupt()

    monkeypatch.setattr(budget, "refund", exploding_refund)

    with pytest.raises(KeyboardInterrupt) as ei:
        copy_one(src_fd, stg_fd, rel, budget)

    assert seen, "前提不成立：退账压根没被调到"
    # 删除那一半确实先正常完成——否则「另一项到底有没有被尝试过」这句判别力
    # 就是恒真的，测的也不是「退账这一格单独被放宽」这件事。
    assert [p.name for p in (stg_path / "1m").iterdir()] == [], (
        "前提不成立：临时文件删除没有先正常完成")

    exc = ei.value
    assert not isinstance(exc, Exception), (
        "`KeyboardInterrupt` 不是 `Exception` 的子类——本条断言本身就是判据所在")
    assert not getattr(boom, "__notes__", []), (
        "退账失败被计入了回滚诊断，说明中断被更宽的判据接住、当成了"
        "「这一项没退成」而不是原样放行")
    assert budget.used == len(data), "已扣的账没退是中断打断整段收尾的已知代价"

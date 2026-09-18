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

import errno
import hashlib
import os
import socket

import pytest

import qmt_fetch
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
    RecoveryScope,
    begin_run,
    commit_stock,
    read_manifest,
)
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


# ── fix round 1 · I4：D1 拒绝折进既有的 StockCopyFailed 族（不新增第四族），
# `slot` 类型错误的裸 `TypeError` 明确不属于任何一族——这里钉住的是「确实
# 如此」，不是靠模块文档这么说。

def test_copy_stock_invalid_stock_paths_is_a_stock_copy_failed_not_a_new_family(roots):
    src_fd, stg_fd, src_path, stg_path = roots
    slot = Slot(code="600000.SH", market="SH", universe_idx=0)
    manifest, export_log_bytes = _seed_manifest()
    ledger = _begin_session(stg_fd, stg_path, manifest, export_log_bytes)
    budget = ByteBudget(limit=None, used=manifest["committed_bytes"])

    with pytest.raises(StockCopyFailed) as ei:
        copy_stock(src_fd, stg_fd, slot, "1m/bad_name.csv", "daily/bad_name.csv",
                   manifest, ledger=ledger, budget=budget)

    assert ei.value.reason == "invalid_stock_paths"
    assert isinstance(ei.value, StockCopyFailed)
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

    with pytest.raises(StockCopyFailed) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_daily, rel_1m, manifest,   # 次序互换
                    ledger=ledger, budget=budget)
    assert ei.value.reason == "invalid_stock_paths"

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

    with pytest.raises(StockCopyFailed) as ei:
        copy_stock(src_fd, stg_fd, slot, rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)
    assert ei.value.reason == "invalid_stock_paths"

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


# ── fix round 1 · C2 回归钉：D4 第 2 条的比对必须按 (stock_code, period) 触发，
# 不是按 relative_path——账本里这只股 1m 的记录若挂在与本次调用不同的
# relative_path 下（路径怎么解析出来在契约 D1 里明写尚未选定，`{name}` 段
# 换过就会导致这一情形），按路径去查记录会查不到、把它当成「无记录」，
# 于是本该早于标记的比对被静默跳过，两个 final 落地、标记写下，直到
# commit_stock 才被 `_validate_files` 拒掉——那时标记与 final 都已经在盘上，
# 正是 D5/D6 要消灭的状态。

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
        "按 new_rel_1m 这条路径查，staging 目标确实不存在"

    with pytest.raises(SourceChangedMidRun):
        copy_stock(src_fd, stg_fd, slot, new_rel_1m, rel_daily, manifest,
                    ledger=ledger, budget=budget)

    assert not (stg_path / INFLIGHT).exists(), "标记未写"
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

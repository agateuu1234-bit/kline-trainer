# backend/tests/test_qmt_fetch.py
"""QMT 4b 切片 S4a · Task 1 + Task 2。

Task 1：字节预算 + 单文件流式拷贝，绑定契约 D3（源侧叶子非普通文件）与 D7
（逐块记账、回滚退还）。
Task 2：幂等四象限判据 `classify_target`，绑定契约 D2（staging 目标非普通文件一律
拒绝覆盖，符号链接除外）与 D4 第 1 条（「相符」判据含 `S_ISREG`）。
Task 3（在途标记 + 单股事务编排）不在本文件范围内。
"""
from __future__ import annotations

import errno
import hashlib
import os
import socket

import pytest

import qmt_fetch
from qmt_fetch import (
    PART,
    TARGET_COPY,
    TARGET_RECOPY,
    TARGET_SKIP,
    TARGET_UNTRACKED,
    ByteBudget,
    CopyResult,
    MaxBytesExhausted,
    RunTerminated,
    StockCopyFailed,
    classify_target,
    copy_one,
)
from qmt_fsroot import PathEscapeError, open_root


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

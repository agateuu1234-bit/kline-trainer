# backend/tests/test_scheduler.py
"""B4 repo 扩展 + run_sweep + build_scheduler + adapter host 测试（本地跑）。"""
from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
from uuid import UUID

import pytest

from app.lease_repo import InMemoryLeaseRepository, MetaRow

NOW = datetime(2026, 5, 30, 12, 0, 0, tzinfo=timezone.utc)
PAST = NOW - timedelta(minutes=5)
FUTURE = NOW + timedelta(minutes=5)
LID = UUID("6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d")


def _meta(id, status, lease_id=None, exp=None, reserved_at=None):
    return MetaRow(id=id, stock_code="600519", stock_name="贵州茅台",
                   filename=f"{id}.zip", schema_version=1, content_hash="deadbeef",
                   status=status, lease_id=lease_id, lease_expires_at=exp,
                   file_path=f"/tmp/{id}.zip", reserved_at=reserved_at)


def test_inmemory_count_unsent():
    repo = InMemoryLeaseRepository(rows=[
        _meta(1, "unsent"), _meta(2, "unsent"),
        _meta(3, "reserved", LID, FUTURE, NOW),
    ])
    assert asyncio.run(repo.count_unsent()) == 2


def test_inmemory_rollback_expired_resets_four_columns():
    repo = InMemoryLeaseRepository(rows=[
        _meta(1, "reserved", LID, PAST, NOW),
        _meta(2, "reserved", LID, FUTURE, NOW),
    ])
    rolled = asyncio.run(repo.rollback_expired(NOW))
    assert rolled == [1]
    r1 = repo._by_id(1)
    assert (r1.status == "unsent" and r1.lease_id is None
            and r1.lease_expires_at is None and r1.reserved_at is None)
    r2 = repo._by_id(2)
    assert r2.status == "reserved" and r2.lease_id == LID


def test_inmemory_rollback_five_expired():
    # 验收场景 A：5 条过期 reserved → 全回滚
    repo = InMemoryLeaseRepository(rows=[
        _meta(i, "reserved", LID, PAST, NOW) for i in range(1, 6)])
    assert asyncio.run(repo.rollback_expired(NOW)) == [1, 2, 3, 4, 5]
    assert asyncio.run(repo.count_unsent()) == 5


def _spy_generate_batch():
    calls = []

    async def gen(n):
        calls.append(n)
        return n

    return gen, calls


def test_run_sweep_replenish_30_to_70():
    # 验收场景 B：unsent=30 (<=40) → 请求生成 70 → generated 70
    from app.scheduler import run_sweep
    repo = InMemoryLeaseRepository(rows=[_meta(i, "unsent") for i in range(1, 31)])
    gen, calls = _spy_generate_batch()
    result = asyncio.run(run_sweep(repo, NOW, gen))
    assert result.rolled_back == []
    assert result.deficit == 70
    assert result.generated == 70
    assert calls == [70]


def test_run_sweep_rollback_then_deficit_combined():
    # D4：30 unsent + 5 过期 reserved → 回滚后 35 (<=40) → deficit 65
    from app.scheduler import run_sweep
    rows = [_meta(i, "unsent") for i in range(1, 31)]
    rows += [_meta(i, "reserved", LID, PAST, NOW) for i in range(31, 36)]
    repo = InMemoryLeaseRepository(rows=rows)
    gen, calls = _spy_generate_batch()
    result = asyncio.run(run_sweep(repo, NOW, gen))
    assert result.rolled_back == [31, 32, 33, 34, 35]
    assert result.deficit == 65
    assert result.generated == 65
    assert calls == [65]


def test_run_sweep_rollback_pushes_over_threshold_skips_generate():
    # D4 后果：38 unsent + 5 过期 → 回滚后 43 (>40) → 不补
    from app.scheduler import run_sweep
    rows = [_meta(i, "unsent") for i in range(1, 39)]
    rows += [_meta(i, "reserved", LID, PAST, NOW) for i in range(39, 44)]
    repo = InMemoryLeaseRepository(rows=rows)
    gen, calls = _spy_generate_batch()
    result = asyncio.run(run_sweep(repo, NOW, gen))
    assert len(result.rolled_back) == 5
    assert result.deficit == 0
    assert result.generated == 0
    assert calls == []


def test_run_sweep_generated_can_be_less_than_deficit():
    from app.scheduler import run_sweep
    repo = InMemoryLeaseRepository(rows=[_meta(i, "unsent") for i in range(1, 31)])

    async def short_gen(n):
        return n - 10

    result = asyncio.run(run_sweep(repo, NOW, short_gen))
    assert result.deficit == 70
    assert result.generated == 60


def test_run_sweep_until_target_retries_partial():
    # D16：首轮只补一半 → 仍 degraded → 同进程重试补剩余 → 达标
    from app.scheduler import run_sweep_until_target
    repo = InMemoryLeaseRepository(rows=[_meta(i, "unsent") for i in range(1, 31)])  # 30 unsent
    calls = []

    async def gen(n):
        calls.append(n)
        added = n // 2 if len(calls) == 1 else n     # 首轮只补一半（模拟 skip）
        base = max((r.id for r in repo._rows), default=0)
        for k in range(added):
            repo._rows.append(_meta(base + 1 + k, "unsent"))
        return added

    result = asyncio.run(run_sweep_until_target(repo, NOW, gen))
    assert calls[0] == 70                       # 首轮请求 100-30
    assert len(calls) >= 2                       # 触发重试
    assert asyncio.run(repo.count_unsent()) == 100
    assert result.deficit == 0                   # 最终库存达 target（基于实际 count）
    assert result.generated == 70                # 累计实际生成


def test_run_sweep_until_target_exhausts_attempts():
    # D16：B2 始终生成不出（skip 耗尽）→ 重试耗尽仍 degraded
    from app.scheduler import run_sweep_until_target, sweep_is_degraded
    repo = InMemoryLeaseRepository(rows=[_meta(i, "unsent") for i in range(1, 31)])

    async def gen(n):
        return 0

    result = asyncio.run(run_sweep_until_target(repo, NOW, gen, max_attempts=3))
    assert sweep_is_degraded(result) is True
    assert result.deficit == 70                  # 最终仍缺 70（基于实际 count）
    assert result.generated == 0


def test_run_sweep_until_target_rechecks_actual_count_not_generated():
    # codex branch-diff R2-F1：并发 /meta reserve 偷走生成的 unsent 时，按实际 count 继续补，
    # 不因 generated 累计已 >= 初始 deficit 就早退（旧逻辑会停在 65 不到 100）
    from app.scheduler import run_sweep_until_target
    repo = InMemoryLeaseRepository(rows=[_meta(i, "unsent") for i in range(1, 31)])  # 30 unsent
    state = {"steal": True}
    calls = []

    async def gen(n):
        calls.append(n)
        base = max((r.id for r in repo._rows), default=0)
        for k in range(n):
            repo._rows.append(_meta(base + 1 + k, "unsent"))
        if state["steal"]:                       # 首轮生成后模拟并发 reserve 偷走一半
            state["steal"] = False
            for r in [x for x in repo._rows if x.status == "unsent"][: n // 2]:
                r.status = "reserved"
        return n

    result = asyncio.run(run_sweep_until_target(repo, NOW, gen, max_attempts=5))
    assert len(calls) >= 2                        # 首轮 generated=70>=deficit70 但被偷走 → 仍按实际 count 重试
    assert asyncio.run(repo.count_unsent()) >= 100
    assert result.deficit == 0                    # 最终按实际库存达 target


def test_build_scheduler_cron_and_reentrancy_guard():
    pytest.importorskip("apscheduler")
    from app.scheduler import build_scheduler
    repo = InMemoryLeaseRepository()

    async def gen(n):
        return 0

    # build_scheduler 返回未 start 的 scheduler；未 start 无需 shutdown
    # （codex R3-F2：APScheduler 3.x 对未启动 scheduler shutdown 抛 SchedulerNotRunningError）。
    # 未 start 时 add_job 进 _pending_jobs，get_job/get_jobs 仍可读到 pending job 及其属性。
    sched = build_scheduler(repo, gen)
    job = sched.get_job("b4_daily_sweep")
    assert job is not None
    r = repr(job.trigger)
    assert "hour='5'" in r and "minute='0'" in r and "Asia/Shanghai" in r
    # D11 同进程重入保护 + misfire 宽限（codex R7-F3）
    assert job.max_instances == 1
    assert job.coalesce is True
    assert job.misfire_grace_time == 3600
    assert job.next_run_time is not None   # codex branch-diff R2-F2：启动即首跑一次已配置


def test_sweep_is_degraded_flags_partial():
    # codex R4-F2 / branch-diff R2-F1：基于剩余缺口（deficit>0 = 最终仍未达 target）判 degraded
    from app.scheduler import SweepResult, sweep_is_degraded
    assert sweep_is_degraded(SweepResult([], 10, 60)) is True    # 剩余缺口 10 → degraded
    assert sweep_is_degraded(SweepResult([], 0, 70)) is False    # 剩余 0 → 达标
    assert sweep_is_degraded(SweepResult([], 0, 0)) is False     # 未触发补足 → 达标


def _fake_pool():
    class _FakeConn:
        pass

    class _FakeAcq:
        async def __aenter__(self):
            return _FakeConn()

        async def __aexit__(self, *a):
            return False

    class _FakePool:
        def acquire(self):
            return _FakeAcq()

    return _FakePool()


def test_build_generate_batch_adapts_b2_to_count(monkeypatch, tmp_path):
    # D5：把 B2 generate_batch(conn,target_count,output_dir,rng)->list 适配成 (n)->int
    import generate_training_sets as gts

    async def fake_gb(conn, target_count, output_dir, rng):
        return [object()] * target_count          # 模拟生成 target_count 个

    monkeypatch.setattr(gts, "generate_batch", fake_gb)
    from app.scheduler import build_generate_batch
    gen = build_generate_batch(_fake_pool(), str(tmp_path / "ts_out"))
    assert asyncio.run(gen(70)) == 70


def test_build_generate_batch_creates_output_dir(monkeypatch, tmp_path):
    # F1：首次部署输出目录不存在时，adapter 必须先建目录
    import generate_training_sets as gts

    async def fake_gb(conn, target_count, output_dir, rng):
        assert output_dir.exists()
        return [object()] * target_count

    monkeypatch.setattr(gts, "generate_batch", fake_gb)
    target = tmp_path / "nested" / "ts_out"
    assert not target.exists()
    from app.scheduler import build_generate_batch
    gen = build_generate_batch(_fake_pool(), str(target))
    assert target.exists()              # build 时即创建
    assert asyncio.run(gen(3)) == 3


def test_start_b4_scheduler_starts_running():
    pytest.importorskip("apscheduler")
    from app.scheduler import start_b4_scheduler

    async def run():
        repo = InMemoryLeaseRepository()

        async def gen(n):
            return 0

        sched = start_b4_scheduler(repo, gen)
        try:
            assert sched.running is True
            assert sched.get_job("b4_daily_sweep") is not None
        finally:
            sched.shutdown(wait=False)

    asyncio.run(run())


def test_main_app_startup_without_dsn_keeps_inmemory(monkeypatch):
    # lifespan 无 DATABASE_URL 分支 no-op，不破坏现有 /health + InMemory 默认
    monkeypatch.delenv("DATABASE_URL", raising=False)
    from fastapi.testclient import TestClient
    import app.main as main
    with TestClient(main.app) as client:
        assert client.get("/health").json() == {"status": "ok"}


def _install_fake_asyncpg(monkeypatch, closed, *, lock_result=True):
    import sys
    import types

    class _FakeConn:
        async def fetchval(self, q, *a):
            return lock_result          # pg_try_advisory_lock 结果
        async def execute(self, q, *a):
            return "ok"                 # pg_advisory_unlock

    class _FakePool:
        async def acquire(self):
            return _FakeConn()
        async def release(self, conn):
            return None
        async def close(self):
            closed["pool"] = True

    fake = types.ModuleType("asyncpg")

    async def create_pool(dsn):
        return _FakePool()

    fake.create_pool = create_pool
    monkeypatch.setitem(sys.modules, "asyncpg", fake)


def test_main_lifespan_dsn_swaps_repo_only(monkeypatch):
    # D12：有 DSN → lifespan swap 成 Asyncpg repo + 退出关 pool；不起调度器（调度器在独立进程）
    import app.main as main
    import app.routes as routes
    from app.lease_repo import AsyncpgLeaseRepository, InMemoryLeaseRepository
    from fastapi.testclient import TestClient

    monkeypatch.setenv("DATABASE_URL", "postgres://x")
    closed = {"pool": False}
    _install_fake_asyncpg(monkeypatch, closed)
    try:
        with TestClient(main.app):
            assert isinstance(routes._default_repo, AsyncpgLeaseRepository)
        assert closed["pool"] is True
    finally:
        routes.set_default_repo(InMemoryLeaseRepository())   # 复原全局，避免污染后续测试


def test_scheduler_main_run_wires_and_cleans_up(monkeypatch, tmp_path):
    # D12：独立进程接线——建 pool/repo/adapter/start，block 立即返回后清理（关 pool）
    pytest.importorskip("apscheduler")
    import generate_training_sets as gts

    async def fake_gb(conn, target_count, output_dir, rng):
        return []

    monkeypatch.setattr(gts, "generate_batch", fake_gb)
    closed = {"pool": False}
    _install_fake_asyncpg(monkeypatch, closed)

    from app.scheduler_main import run_scheduler_process

    async def block():
        return  # 立即返回，模拟收到停止信号

    asyncio.run(run_scheduler_process("postgres://x", str(tmp_path / "ts"), block=block))
    assert closed["pool"] is True


def test_scheduler_main_exits_when_lock_held(monkeypatch, tmp_path):
    # D14：拿不到 advisory lock（已有 scheduler 持锁）→ 直接返回，不 start 调度器
    import app.scheduler as scheduler_mod
    closed = {"pool": False}
    _install_fake_asyncpg(monkeypatch, closed, lock_result=False)
    started = {"n": 0}
    monkeypatch.setattr(scheduler_mod, "start_b4_scheduler",
                        lambda *a, **k: started.__setitem__("n", started["n"] + 1))

    from app.scheduler_main import run_scheduler_process

    asyncio.run(run_scheduler_process("postgres://x", str(tmp_path / "ts")))
    assert started["n"] == 0          # 未拿到锁 → 未起调度器
    assert closed["pool"] is True     # 仍清理 pool


def test_scheduler_main_requires_absolute_training_sets_dir(monkeypatch):
    # D15：TRAINING_SETS_DIR 缺失或相对路径 → SystemExit（防 scheduler/web 路径不一致 404）
    import app.scheduler_main as sm
    monkeypatch.setenv("DATABASE_URL", "postgres://x")
    monkeypatch.delenv("TRAINING_SETS_DIR", raising=False)
    with pytest.raises(SystemExit):
        sm.main()
    monkeypatch.setenv("TRAINING_SETS_DIR", "relative/path")
    with pytest.raises(SystemExit):
        sm.main()


def test_build_scheduler_job_swallows_sweep_exception(caplog):
    # codex branch-diff F2：sweep 抛异常时 _job 不传播（记录后等次日 cron），不崩调度器
    import logging

    pytest.importorskip("apscheduler")
    from app.scheduler import build_scheduler

    class _BoomRepo:
        async def rollback_expired(self, now):
            raise RuntimeError("db down")

        async def count_unsent(self):
            return 0

    async def gen(n):
        return 0

    sched = build_scheduler(_BoomRepo(), gen)
    job = sched.get_job("b4_daily_sweep")
    # _job 不应把异常传播出来（未 start 的 scheduler 不需 shutdown）
    with caplog.at_level(logging.ERROR, logger="app.scheduler"):
        asyncio.run(job.func())
    assert "B4 sweep failed" in caplog.text

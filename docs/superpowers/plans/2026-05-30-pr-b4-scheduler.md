# B4 APScheduler 调度器模块 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐 Task 实施。步骤用 checkbox（`- [ ]`）跟踪。

**目标：** 实现后端调度器逻辑 `app/scheduler.py`（回滚过期 lease + unsent 跌到阈值时调 B2 `generate_batch` 补足）+ 独立进程入口 `app/scheduler_main.py`（每天北京 05:00，进程级 advisory lock 单例）。**本 PR 交付调度器代码与可启动入口，不含生产容器化/常驻部署编排**（restart policy / supervisor / compose service 归后续部署 PR，见 residual B4-R4；codex R6-F2 收窄出口）。

**架构：** 沿用 B3 后端双层：纯决策（`scheduler_logic.py`，只吃原语、host 全测、零 app 依赖避免循环）+ I/O 仓储（扩展 `InMemoryLeaseRepository` host 测 / `AsyncpgLeaseRepository` 生产薄壳 CI 不跑）+ 编排（`run_sweep` 纯注入编排可测 / `build_scheduler`+`build_generate_batch`+`start_b4_scheduler`+`sweep_is_degraded` 接线，lazy import / fake-pool 可测）+ 运行时（**独立 `scheduler_main.py` 单例进程** `run_scheduler_process` 起调度器常驻；`main.py` lifespan 仅在有 DATABASE_URL 时 swap repo 为 Asyncpg，**不起调度器**）。B4 **仅编排**，不复制 B2 生成逻辑（modules §四 B4）。

**技术栈：** Python 3.11+ / APScheduler 3.10.4（已 pin）/ asyncpg（生产薄壳）/ FastAPI lifespan / pytest（host 测试）。

**Spec 权威：**
- `kline_trainer_modules_v1.4.md` §四 B4（L810-816：职责 1 回滚 `lease_expires_at < now()`；职责 2 `unsent ≤ 40 → generate_batch(target=100-current_unsent)`；验收「5 过期 reserved 全回滚 / unsent=30 补 70」）
- `kline_trainer_plan_v1.5.md` §8.1 L1076-1078（定时任务两步）+ L1156（FastAPI 服务含 APScheduler 定时任务，同进程）
- `backend/generate_training_sets.py` L292-312：`async def generate_batch(conn, target_count, output_dir, rng=None) -> list`——`target_count` = 要新生成的个数，返回 `GeneratedTrainingSet` 列表
- `backend/app/lease_repo.py` L55-145：`InMemoryLeaseRepository(rows: list[MetaRow])`（list，无 lock）+ `AsyncpgLeaseRepository(pool)`；`MetaRow` 含 `status / lease_id: UUID|None / lease_expires_at: datetime|None / reserved_at: datetime|None`
- `backend/app/main.py` L1-18：当前无 lifespan，模块级 `routes.set_default_repo(InMemoryLeaseRepository())`；注释明示「NAS 部署时由 lifespan 用 AsyncpgLeaseRepository(pool) 替换」
- `backend/app/routes.py` L26-35：`set_default_repo` / `get_repository` 进程级注入

**关键设计决策（plan-stage 锁定 / 含 codex R1 修订）：**
- **D1 — 清理职责 3 省略**（user explicit，2026-05-30）：spec 标「（可选）」，验收不覆盖。记 residual B4-R1，后续按存储压力以独立 PR 落地。无行为缺口。
- **D2 — 回滚判定严格 `<`**：spec L813 字面 `lease_expires_at < now()`。与 B3 `is_meta_selectable` 的 `<=`（L772）不对称，各按 spec 字面，本 PR 不统一（B4 是兜底路径，非唯一回收路径）。
- **D3 — 补足有阈值 + 上限**：spec L814/L1078 = **unsent ≤ 40 才补，补到 100**。`compute_replenish_deficit` 在 `unsent > 40` 时返 0。`run_sweep` 把 deficit 当 `generate_batch` 的「要生成个数」传入。
- **D4 — 先回滚后算缺口**：回滚把过期 reserved 变回 unsent，计入存量后再算 deficit；回滚可能把 unsent 推过阈值 → 本轮跳过补足（正确）。验收两条为独立场景；另加组合场景测试锁定顺序。
- **D5 — generate_batch 注入契约 `Callable[[int], Awaitable[int]]` + 真实 adapter 必须有 Task 实现并测**（codex R1-F2）：入参=要生成个数（deficit），返回=实际生成数。Task 7 实现 `build_generate_batch(pool, output_dir, rng=None)`：`async with pool.acquire() as conn: return len(await generate_batch(conn, n, Path(output_dir), rng))`，用 fake-pool host 测；**不只是 prose**。
- **D6 — `now` 全程 `datetime`（tz-aware UTC）**：对齐 B3。`build_scheduler` job 用 `datetime.now(timezone.utc)`。不用 float。
- **D7 — APScheduler lazy import**：`apscheduler` 只在接线函数体内 import，使 `run_sweep` / 纯逻辑 host 测试无需装 APScheduler。涉及 apscheduler 的测试用 `pytest.importorskip("apscheduler")` 守卫（已 pin，本地真跑）。
- **D8 — 纯逻辑放新文件 `scheduler_logic.py`（只吃原语，零 app import）**：`lease_repo.py` import 它（无循环）。不动 B3 的 `lease_logic.py`。
- **D9 — 复用 `InMemoryLeaseRepository`**：两 repo 各加 `count_unsent` + `rollback_expired`（additive，无 lock，沿用现有无锁风格）。
- **D10 — Task 0 = 验证 pin 已存在**：`backend/requirements.txt:3` `apscheduler==3.10.4` 已 pin（H6 part 4 早满足），本 PR 不改。
- **D11 — 同进程重入保护**（codex R1-F3）：`build_scheduler` 的 `add_job` 加 `max_instances=1, coalesce=True`（防同进程 job 堆积重入）。跨进程多实例由 D12 独立单例进程根治；误启多个 scheduler 进程的极端记 residual **B4-R3**（advisory lock）。
- **D12 — B4 调度器作独立单例进程**（codex R1-F1 / R2-F2 / R3-F1；user 2026-05-30 选「独立 scheduler 进程」）：调度器**不嵌 web FastAPI lifespan**——env 开关 service-wide，多 uvicorn/gunicorn worker 会各起一个 05:00 job over-generate。新增独立入口 `backend/app/scheduler_main.py`（`python -m app.scheduler_main`），单进程容器部署跑常驻调度器。`main.py` lifespan **仅在有 DSN 时 swap repo 为 Asyncpg**（web 进程读写需要），不起调度器；shutdown 关 pool；无 DSN 走模块级 InMemory 默认（本地/CI 不回归）。接线抽成 `run_scheduler_process(dsn, output_dir, *, block=None)`（block 可注入）→ fake-asyncpg host 测（建 pool/repo/adapter/start/清理）。
- **D13 — 偏离 spec L1156「FastAPI 服务含 APScheduler 同进程」**：spec 字面把调度器放 FastAPI 进程；本 PR 改**独立 scheduler 进程**（codex 多轮坚持多 worker 安全 + user 选项）。理由=web 多 worker 下同进程调度器必重复触发；关注点分离是标准做法（独立 cron/scheduler 容器）。功能等价（同一 build_generate_batch / run_sweep / start_b4_scheduler），仅部署拓扑不同。
- **D14 — 进程级 Postgres advisory lock 强制单例**（codex R5-F1）：`scheduler_main` 启动时用专用 conn `pg_try_advisory_lock(<KEY>)`；拿不到（已有 scheduler 进程持锁）→ log error + 退出，不 start 调度器。锁随进程存活持有、退出时 `pg_advisory_unlock` + 关 pool 释放。把「单例」从运维纪律升为 DB 层强制（不再依赖 D11 的同进程 max_instances 单独兜底）。host 测 fake conn `pg_try_advisory_lock` 返 True/False 两分支。
- **D15 — TRAINING_SETS_DIR 必填且绝对共享路径**（codex R5-F2）：scheduler 与 web 分进程，B2 把 `str(gts.path)` 存入 `training_sets.file_path`，web 下载据此读盘；两进程 CWD/volume 不同则 404。故 `scheduler_main.main()` **要求 TRAINING_SETS_DIR 必填 + 绝对路径**（缺失/相对 → SystemExit），不再默认 `./training_sets`。验收验证生成行 file_path 从 web 进程可读。
- **D16 — 部分补足有界立即重试**（codex R5-F3）：`generate_batch` 可能因 skip 耗尽返回少于请求；degraded 不只 warn——`run_sweep_until_target` 在同进程立即重试（re-count 后补剩余）最多 `max_attempts` 次，仍 degraded 才 warning（不必等次日 cron）。`_job` 调它。host 测 partial→retry→达标 + 重试耗尽两分支。

---

## 文件结构

| 文件 | 动作 | 责任 |
|---|---|---|
| `backend/requirements.txt` | 仅验证 | Task 0：确认 `apscheduler==3.10.4` 已 pin（无改动） |
| `backend/app/scheduler_logic.py` | 新建 | 纯决策：`is_expired_reserved` / `compute_replenish_deficit` |
| `backend/app/lease_repo.py` | 修改 | 两 repo 各加 `count_unsent` / `rollback_expired` |
| `backend/app/scheduler.py` | 新建 | `SweepResult` / `run_sweep` / `build_scheduler` / `build_generate_batch` / `start_b4_scheduler` |
| `backend/app/main.py` | 修改 | 加 FastAPI lifespan，DSN 存在时仅 swap repo 为 Asyncpg（不起调度器）|
| `backend/app/scheduler_main.py` | 新建 | B4 独立单例调度器进程入口（`python -m app.scheduler_main`），薄壳 CI 不跑 |
| `backend/tests/test_scheduler_logic.py` | 新建 | 纯逻辑 host 测试 |
| `backend/tests/test_scheduler.py` | 新建 | repo 扩展 + run_sweep + build_scheduler + adapter + start helper + lifespan 不回归 |
| `docs/acceptance/2026-05-30-pr-b4-scheduler.md` | 新建 | 非-coder 可执行验收清单（中文） |

---

## Task 0：验证 APScheduler pin（H6 part 4，无改动）

**Files:** 只读 `backend/requirements.txt`

- [ ] **Step 1: 确认 pin 已存在**

Run: `cd backend && grep -n "apscheduler==" requirements.txt`
Expected: 输出 `3:apscheduler==3.10.4`（先前 PR 已 pin，H6 part 4 早满足；本 PR 不改）。若未命中才追加 `apscheduler==3.10.4` 并 commit。

---

## Task 1：scheduler_logic — is_expired_reserved（职责 1 判定）

**Files:**
- Create: `backend/app/scheduler_logic.py`
- Test: `backend/tests/test_scheduler_logic.py`

- [ ] **Step 1: 写失败测试**

Create `backend/tests/test_scheduler_logic.py`:

```python
# backend/tests/test_scheduler_logic.py
"""B4 scheduler_logic 纯决策测试（host 本地跑，不碰 PG / APScheduler）。"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.scheduler_logic import compute_replenish_deficit, is_expired_reserved

NOW = datetime(2026, 5, 30, 12, 0, 0, tzinfo=timezone.utc)
PAST = NOW - timedelta(minutes=5)
FUTURE = NOW + timedelta(minutes=5)


def test_expired_reserved_true_when_reserved_and_past():
    assert is_expired_reserved("reserved", PAST, NOW) is True


def test_expired_reserved_false_when_not_expired():
    assert is_expired_reserved("reserved", FUTURE, NOW) is False


def test_expired_reserved_strict_less_than_boundary():
    # 严格 `<`：lease_expires_at == now → 未过期
    assert is_expired_reserved("reserved", NOW, NOW) is False


def test_expired_reserved_false_when_not_reserved():
    assert is_expired_reserved("unsent", PAST, NOW) is False
    assert is_expired_reserved("sent", PAST, NOW) is False


def test_expired_reserved_false_when_expiry_none():
    assert is_expired_reserved("reserved", None, NOW) is False
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python3 -m pytest tests/test_scheduler_logic.py -k expired_reserved -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.scheduler_logic'`

- [ ] **Step 3: 写最小实现**

Create `backend/app/scheduler_logic.py`:

```python
# backend/app/scheduler_logic.py
# Spec: kline_trainer_modules_v1.4.md §四 B4 (L810-816)
#       + kline_trainer_plan_v1.5.md §8.1 (L1076-1078)
#
# 纯决策层（D8）：只吃原语（status / datetime / int），零 fastapi/asyncpg/app import。
# 不 import MetaRow（避免与 lease_repo 形成循环）；host pytest 全测。
from __future__ import annotations

from datetime import datetime
from typing import Optional

# 补足触发阈值与上限（spec L1078 / modules L814）
REPLENISH_THRESHOLD = 40
REPLENISH_TARGET = 100


def is_expired_reserved(status: str, lease_expires_at: Optional[datetime],
                        now: datetime) -> bool:
    """B4 职责 1 回滚判定：status=='reserved' 且 lease_expires_at 严格 < now（spec L813）。
    lease_expires_at 为 None → 无到期信息 → 保守不回滚。
    与 B3 is_meta_selectable 的 `<=` 不对称，按各自 spec 字面保留。"""
    return (status == "reserved"
            and lease_expires_at is not None
            and lease_expires_at < now)


def compute_replenish_deficit(unsent_count: int, *,
                              threshold: int = REPLENISH_THRESHOLD,
                              target: int = REPLENISH_TARGET) -> int:
    """B4 职责 2：unsent_count <= threshold 才补，补到 target；否则 0（spec L1078）。
    返回值 = 要新生成的个数，由 run_sweep 作为 generate_batch 的 target_count 传入。"""
    if unsent_count > threshold:
        return 0
    return max(0, target - unsent_count)
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python3 -m pytest tests/test_scheduler_logic.py -k expired_reserved -q`
Expected: PASS（5 passed）

- [ ] **Step 5: Commit**

```bash
git add backend/app/scheduler_logic.py backend/tests/test_scheduler_logic.py
git commit -m "B4 Task 1: is_expired_reserved pure predicate + tests"
```

---

## Task 2：scheduler_logic — compute_replenish_deficit（职责 2 阈值）

**Files:** Test `backend/tests/test_scheduler_logic.py`（追加）；实现已在 Task 1 写入

- [ ] **Step 1: 写测试**

在 `backend/tests/test_scheduler_logic.py` 末尾追加：

```python
def test_deficit_replenish_30_to_70():
    # 验收场景 B：unsent=30 (<=40) → 补 70
    assert compute_replenish_deficit(30) == 70


def test_deficit_at_threshold_40_replenishes():
    assert compute_replenish_deficit(40) == 60


def test_deficit_above_threshold_returns_zero():
    assert compute_replenish_deficit(41) == 0


def test_deficit_zero_when_empty_fills_to_target():
    assert compute_replenish_deficit(0) == 100


def test_deficit_clamped_when_over_target():
    assert compute_replenish_deficit(120) == 0
```

- [ ] **Step 2: 跑测试确认通过**

Run: `cd backend && python3 -m pytest tests/test_scheduler_logic.py -q`
Expected: PASS（10 passed）

- [ ] **Step 3: Commit**

```bash
git add backend/tests/test_scheduler_logic.py
git commit -m "B4 Task 2: compute_replenish_deficit threshold tests (acceptance 30->70)"
```

---

## Task 3：扩展 InMemoryLeaseRepository — count_unsent + rollback_expired

**Files:**
- Modify: `backend/app/lease_repo.py`
- Test: `backend/tests/test_scheduler.py`

- [ ] **Step 1: 写失败测试**

Create `backend/tests/test_scheduler.py`:

```python
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python3 -m pytest tests/test_scheduler.py -k "count_unsent or rollback" -q`
Expected: FAIL — `AttributeError: ... has no attribute 'count_unsent'`

- [ ] **Step 3: 写最小实现**

在 `backend/app/lease_repo.py` 顶部 `from app.lease_logic import ...` 行**之后**追加：

```python
from app.scheduler_logic import is_expired_reserved
```

在 `InMemoryLeaseRepository` 类内、`get_file_path` 方法之后追加：

```python
    async def count_unsent(self) -> int:
        """B4：统计 status=='unsent' 行数。"""
        return sum(1 for r in self._rows if r.status == "unsent")

    async def rollback_expired(self, now: datetime) -> list[int]:
        """B4 职责 1：过期 reserved → unsent，重置 lease 三列 + reserved_at（维持
        ck_lease_state_invariant：unsent 行 lease 字段须为空）。返回回滚 id 列表。"""
        ids: list[int] = []
        for r in self._rows:
            if is_expired_reserved(r.status, r.lease_expires_at, now):
                r.status = "unsent"
                r.lease_id = None
                r.lease_expires_at = None
                r.reserved_at = None
                ids.append(r.id)
        return ids
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python3 -m pytest tests/test_scheduler.py -k "count_unsent or rollback" -q`
Expected: PASS（3 passed）

- [ ] **Step 5: 回归 B3 现有测试**

Run: `cd backend && python3 -m pytest tests/test_lease_logic.py tests/test_routes.py -q`
Expected: PASS（additive 不回归）

- [ ] **Step 6: Commit**

```bash
git add backend/app/lease_repo.py backend/tests/test_scheduler.py
git commit -m "B4 Task 3: InMemoryLeaseRepository count_unsent + rollback_expired"
```

---

## Task 4：扩展 AsyncpgLeaseRepository — count_unsent + rollback_expired（生产薄壳）

**Files:** Modify `backend/app/lease_repo.py`（`AsyncpgLeaseRepository`）。CI 不跑，仅 import 冒烟。

- [ ] **Step 1: 写最小实现**

在 `AsyncpgLeaseRepository` 类内、`get_file_path` 方法之后追加：

```python
    async def count_unsent(self) -> int:
        async with self._pool.acquire() as conn:
            return await conn.fetchval(
                "SELECT count(*) FROM training_sets WHERE status = 'unsent'")

    async def rollback_expired(self, now: datetime) -> list[int]:
        """B4 职责 1：过期 reserved → unsent，重置 4 列（spec L813 严格 `<`）。
        返回回滚 id。CI 不跑；now 为 tz-aware datetime → timestamptz。"""
        async with self._pool.acquire() as conn:
            async with conn.transaction():
                rows = await conn.fetch(
                    """
                    UPDATE training_sets
                       SET status = 'unsent', lease_id = NULL,
                           lease_expires_at = NULL, reserved_at = NULL
                     WHERE status = 'reserved' AND lease_expires_at < $1
                    RETURNING id
                    """, now)
                return [r["id"] for r in rows]
```

- [ ] **Step 2: import 冒烟**

Run: `cd backend && python3 -c "from app.lease_repo import AsyncpgLeaseRepository; print('ok', hasattr(AsyncpgLeaseRepository, 'rollback_expired'))"`
Expected: `ok True`

- [ ] **Step 3: Commit**

```bash
git add backend/app/lease_repo.py
git commit -m "B4 Task 4: AsyncpgLeaseRepository count_unsent + rollback_expired thin shell"
```

---

## Task 5：scheduler.py — SweepResult + run_sweep（纯编排）

**Files:**
- Create: `backend/app/scheduler.py`
- Test: `backend/tests/test_scheduler.py`（追加）

- [ ] **Step 1: 写失败测试**

在 `backend/tests/test_scheduler.py` 末尾追加：

```python
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
    assert result.generated == result.deficit    # 末轮已达标


def test_run_sweep_until_target_exhausts_attempts():
    # D16：B2 始终生成不出（skip 耗尽）→ 重试耗尽仍 degraded
    from app.scheduler import run_sweep_until_target, sweep_is_degraded
    repo = InMemoryLeaseRepository(rows=[_meta(i, "unsent") for i in range(1, 31)])

    async def gen(n):
        return 0

    result = asyncio.run(run_sweep_until_target(repo, NOW, gen, max_attempts=3))
    assert sweep_is_degraded(result) is True
    assert result.generated == 0
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python3 -m pytest tests/test_scheduler.py -k run_sweep -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.scheduler'`

- [ ] **Step 3: 写最小实现**

Create `backend/app/scheduler.py`:

```python
# backend/app/scheduler.py
# Spec: kline_trainer_modules_v1.4.md §四 B4 (L810-816)
#       + kline_trainer_plan_v1.5.md §8.1 (L1076-1078, L1156)
#
# 职责：1 回滚过期 reserved；2 unsent<=40 调 B2 generate_batch 补到 100；
#       3 清理 30 天前 sent（可选）—— 本 PR 省略，见 plan residual B4-R1
#
# 层次：run_sweep 纯编排（host 测）；build_scheduler/build_generate_batch/
#       start_b4_scheduler 接线（lazy import apscheduler / fake-pool 可测）。
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime
from typing import Awaitable, Callable, Protocol

from app.scheduler_logic import (
    REPLENISH_TARGET,
    REPLENISH_THRESHOLD,
    compute_replenish_deficit,
)

BEIJING_TZ = "Asia/Shanghai"
logger = logging.getLogger(__name__)


class _SweepRepo(Protocol):
    async def rollback_expired(self, now: datetime) -> list[int]: ...
    async def count_unsent(self) -> int: ...


@dataclass(frozen=True)
class SweepResult:
    """一次调度扫描结果。deficit=请求生成数；generated=实际生成数（B2 可能因 skip 少于 deficit）。"""
    rolled_back: list[int]
    deficit: int
    generated: int


async def run_sweep(
    repo: _SweepRepo,
    now: datetime,
    generate_batch: Callable[[int], Awaitable[int]],
    *,
    threshold: int = REPLENISH_THRESHOLD,
    target: int = REPLENISH_TARGET,
) -> SweepResult:
    """先回滚过期 lease，再按缺口委托 B2 补足（D4 顺序）。deficit<=0 不调 generate_batch。"""
    rolled_back = await repo.rollback_expired(now)
    unsent = await repo.count_unsent()
    deficit = compute_replenish_deficit(unsent, threshold=threshold, target=target)
    generated = await generate_batch(deficit) if deficit > 0 else 0
    return SweepResult(rolled_back=rolled_back, deficit=deficit, generated=generated)


def sweep_is_degraded(result: SweepResult) -> bool:
    """补足未达目标（请求>0 但实际生成更少）→ degraded，需告警（codex R4-F2）。"""
    return result.deficit > 0 and result.generated < result.deficit


DEFAULT_MAX_SWEEP_ATTEMPTS = 3


async def run_sweep_until_target(
    repo: _SweepRepo,
    now: datetime,
    generate_batch: Callable[[int], Awaitable[int]],
    *,
    threshold: int = REPLENISH_THRESHOLD,
    target: int = REPLENISH_TARGET,
    max_attempts: int = DEFAULT_MAX_SWEEP_ATTEMPTS,
) -> SweepResult:
    """首轮完整 sweep（回滚 + 阈值门触发补足）；一旦触发补足（首轮 deficit>0）但累计未达起始缺口，
    在同进程立即重试——**重试补 max(0, target - 当前 unsent)，不再过 unsent<=40 阈值门**（D16/R6-F1：
    阈值门只决定「是否启动补足」，启动后须补到 target；否则 30→+35→重试看 65>40 会误判 deficit=0 停在 65）。
    返回 SweepResult：rolled_back=首轮回滚；deficit=首轮起始缺口；generated=累计实际生成
    （单线程下 unsent 只增 → generated>=deficit ⟺ 已达 target）。"""
    first = await run_sweep(repo, now, generate_batch, threshold=threshold, target=target)
    rolled = first.rolled_back
    initial_deficit = first.deficit
    total_generated = first.generated
    attempts = 1
    while initial_deficit > 0 and total_generated < initial_deficit and attempts < max_attempts:
        unsent = await repo.count_unsent()
        remaining = max(0, target - unsent)     # 重试不过阈值门（已在补足中）
        if remaining <= 0:
            break
        total_generated += await generate_batch(remaining)
        attempts += 1
    return SweepResult(rolled_back=rolled, deficit=initial_deficit, generated=total_generated)
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python3 -m pytest tests/test_scheduler.py -k "run_sweep or sweep_until" -q`
Expected: PASS（6 passed：run_sweep 4 + run_sweep_until_target 2）

- [ ] **Step 5: Commit**

```bash
git add backend/app/scheduler.py backend/tests/test_scheduler.py
git commit -m "B4 Task 5: run_sweep orchestration + SweepResult"
```

---

## Task 6：scheduler.py — build_scheduler（APScheduler 薄壳 + 同进程重入保护）

**Files:** Modify `backend/app/scheduler.py`；Test `backend/tests/test_scheduler.py`（追加，`importorskip` 守卫）

- [ ] **Step 1: 写失败测试**

在 `backend/tests/test_scheduler.py` 末尾追加：

```python
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


def test_sweep_is_degraded_flags_partial():
    # codex R4-F2：补足未达目标（请求>0 但实际更少）须被标记 degraded
    from app.scheduler import SweepResult, sweep_is_degraded
    assert sweep_is_degraded(SweepResult([], 70, 60)) is True
    assert sweep_is_degraded(SweepResult([], 70, 70)) is False
    assert sweep_is_degraded(SweepResult([], 0, 0)) is False
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python3 -m pytest tests/test_scheduler.py::test_build_scheduler_cron_and_reentrancy_guard -q`
Expected: FAIL — `ImportError: cannot import name 'build_scheduler'`

- [ ] **Step 3: 写最小实现**

在 `backend/app/scheduler.py` 末尾追加：

```python
def build_scheduler(
    repo: _SweepRepo,
    generate_batch: Callable[[int], Awaitable[int]],
    *,
    threshold: int = REPLENISH_THRESHOLD,
    target: int = REPLENISH_TARGET,
):
    """构造每天北京时间 05:00 跑 run_sweep 的 AsyncIOScheduler（薄壳；CI 不跑）。
    lazy import apscheduler；max_instances=1+coalesce=True 防同进程重入（D11）。
    返回未 start 的调度器；调用方负责 .start()。"""
    from datetime import timezone

    from apscheduler.schedulers.asyncio import AsyncIOScheduler
    from apscheduler.triggers.cron import CronTrigger

    scheduler = AsyncIOScheduler(timezone=BEIJING_TZ)

    async def _job() -> None:
        result = await run_sweep_until_target(repo, datetime.now(timezone.utc), generate_batch,
                                              threshold=threshold, target=target)
        logger.info("B4 sweep rolled_back=%d deficit=%d generated=%d",
                    len(result.rolled_back), result.deficit, result.generated)
        if sweep_is_degraded(result):   # codex R4-F2/R5-F3：重试耗尽仍未达标才告警，不静默
            logger.warning("B4 replenish degraded after retries: generated %d of requested %d",
                           result.generated, result.deficit)

    scheduler.add_job(
        _job,
        CronTrigger(hour=5, minute=0, timezone=BEIJING_TZ),
        id="b4_daily_sweep",
        replace_existing=True,
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,   # codex R7-F3：daily 维护任务给 1h 宽限，05:00 短暂 stall 不跳过当天
    )
    return scheduler
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python3 -m pip install "apscheduler==3.10.4" -q && python3 -m pytest tests/test_scheduler.py -k "build_scheduler or sweep_is_degraded" -q`
Expected: PASS（2 passed）。若 `repr(job.trigger)` 字段格式不符，读真实 repr 后改字面断言。

- [ ] **Step 5: Commit**

```bash
git add backend/app/scheduler.py backend/tests/test_scheduler.py
git commit -m "B4 Task 6: build_scheduler APScheduler thin shell + reentrancy guard"
```

---

## Task 7：生产接线 — build_generate_batch adapter + start_b4_scheduler + 独立 scheduler 进程 + main.py lifespan(仅 swap repo)

**Files:**
- Modify: `backend/app/scheduler.py`（`build_generate_batch` + `start_b4_scheduler`）
- Create: `backend/app/scheduler_main.py`（独立单例调度器进程入口 + `run_scheduler_process`）
- Modify: `backend/app/main.py`（FastAPI lifespan 仅 swap repo，不起调度器）
- Test: `backend/tests/test_scheduler.py`（追加）

- [ ] **Step 1: 写失败测试**

在 `backend/tests/test_scheduler.py` 末尾追加：

```python
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python3 -m pytest tests/test_scheduler.py -k "generate_batch or start_b4 or startup_without_dsn or lifespan_dsn or scheduler_main" -q`
Expected: FAIL — `ImportError: cannot import name 'build_generate_batch'`

- [ ] **Step 3: scheduler.py 加 adapter + start helper**

在 `backend/app/scheduler.py` 末尾追加：

```python
def build_generate_batch(
    pool,
    output_dir: str,
    rng=None,
) -> Callable[[int], Awaitable[int]]:
    """生产适配（D5/F2）：把 B2 generate_batch(conn,target_count,output_dir,rng)->list
    适配成 run_sweep 要的 (n)->实际生成数。pool=asyncpg.Pool（薄壳，fake-pool 可测）。
    局部 import generate_batch，避免 app.scheduler 顶层拉 pandas（保 run_sweep 测试轻量）。"""
    from pathlib import Path

    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)   # F1：确保输出目录存在；不可写则抛 → lifespan startup 失败

    async def _gen(n: int) -> int:
        from generate_training_sets import generate_batch
        async with pool.acquire() as conn:
            produced = await generate_batch(conn, n, out, rng)
            return len(produced)

    return _gen


def start_b4_scheduler(
    repo: _SweepRepo,
    generate_batch: Callable[[int], Awaitable[int]],
    *,
    threshold: int = REPLENISH_THRESHOLD,
    target: int = REPLENISH_TARGET,
):
    """build + start B4 调度器，返回已 start 的 handle（供 lifespan 持有 + shutdown）。"""
    scheduler = build_scheduler(repo, generate_batch, threshold=threshold, target=target)
    scheduler.start()
    return scheduler
```

> 注意：`from generate_training_sets import generate_batch` 放在 `_gen` 函数体内（不是 `build_generate_batch` 体内），这样 `monkeypatch.setattr(gts, "generate_batch", ...)` 在每次调用时生效；且 import `app.scheduler` 不触发 pandas 加载。

- [ ] **Step 4: main.py lifespan（仅 swap repo）+ 新增 scheduler_main.py 独立入口**

把 `backend/app/main.py` 整体替换为：

```python
# backend/app/main.py
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app import routes
from app.lease_repo import AsyncpgLeaseRepository, InMemoryLeaseRepository


@asynccontextmanager
async def lifespan(app: FastAPI):
    """有 DATABASE_URL：起 asyncpg pool + swap repo 为 AsyncpgLeaseRepository；退出关 pool。
    无 DSN（本地/CI）走模块级 InMemory 默认，不接 live pool。
    B4 调度器不在此进程起——见 app/scheduler_main.py 独立单例进程（D12）。"""
    dsn = os.environ.get("DATABASE_URL")
    pool = None
    if dsn:
        import asyncpg

        pool = await asyncpg.create_pool(dsn)
        routes.set_default_repo(AsyncpgLeaseRepository(pool))
    yield
    if pool is not None:
        await pool.close()


app = FastAPI(title="Kline Trainer API", version="0.1.0", lifespan=lifespan)

# 默认 repo：无 DATABASE_URL 时用 InMemory（本地 dev / 测试基线）；
# 有 DSN 时 lifespan startup 覆盖为 AsyncpgLeaseRepository(pool)。
routes.set_default_repo(InMemoryLeaseRepository())

app.include_router(routes.router)


@app.get("/health")
async def health():
    return {"status": "ok"}
```

把 `backend/app/scheduler_main.py` 创建为：

```python
# backend/app/scheduler_main.py
# B4 独立单例调度器进程入口（python -m app.scheduler_main）。
# 与 web 进程分离（D12/D13）：web (uvicorn app.main) 可多 worker 不起调度器；
# 本进程单独部署，DB 层 advisory lock 强制单例（D14）。薄壳：真 asyncpg pool，CI 不跑。
from __future__ import annotations

import asyncio
import logging
import os
from typing import Awaitable, Callable, Optional

logger = logging.getLogger(__name__)

# 进程级单例 advisory lock key（D14；任意固定 bigint，B4 scheduler 专用）
SCHEDULER_LOCK_KEY = 0x42345CED


async def run_scheduler_process(
    dsn: str,
    output_dir: str,
    *,
    block: Optional[Callable[[], Awaitable[None]]] = None,
) -> None:
    """建 pool → 抢进程级 advisory lock（D14）→ 拿到才建 repo/adapter/start 调度器并常驻；
    退出时 unlock + shutdown + 关 pool。block 可注入（测试传立即返回的协程）。
    拿不到锁（已有 scheduler 进程持锁）→ log error + 直接返回（第二进程退出，不重复 sweep）。"""
    import asyncpg

    from app.lease_repo import AsyncpgLeaseRepository
    from app.scheduler import build_generate_batch, start_b4_scheduler

    pool = await asyncpg.create_pool(dsn)
    lock_conn = None
    scheduler = None
    try:
        lock_conn = await pool.acquire()
        locked = await lock_conn.fetchval("SELECT pg_try_advisory_lock($1)", SCHEDULER_LOCK_KEY)
        if not locked:
            logger.error("another B4 scheduler holds singleton lock %s; exiting", SCHEDULER_LOCK_KEY)
            return
        repo = AsyncpgLeaseRepository(pool)
        gen = build_generate_batch(pool, output_dir)
        scheduler = start_b4_scheduler(repo, gen)
        if block is None:
            await asyncio.Event().wait()        # 常驻（生产）
        else:
            await block()                       # 测试注入
    finally:
        if scheduler is not None:
            scheduler.shutdown(wait=False)
        if lock_conn is not None:
            try:
                await lock_conn.execute("SELECT pg_advisory_unlock($1)", SCHEDULER_LOCK_KEY)
            finally:
                await pool.release(lock_conn)
        await pool.close()


def main() -> None:
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        raise SystemExit("DATABASE_URL required for B4 scheduler process")
    # D15：scheduler 与 web 分进程，file_path 须落在两进程共享的绝对路径
    output_dir = os.environ.get("TRAINING_SETS_DIR")
    if not output_dir or not os.path.isabs(output_dir):
        raise SystemExit("TRAINING_SETS_DIR must be set to an absolute shared path")
    asyncio.run(run_scheduler_process(dsn, output_dir))


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd backend && python3 -m pytest tests/test_scheduler.py -k "generate_batch or start_b4 or startup_without_dsn or lifespan_dsn or scheduler_main" -q`
Expected: PASS（8 passed）

- [ ] **Step 6: 全量 backend 测试绿（含 B3 回归）**

Run: `cd backend && python3 -m pytest -q`
Expected: 全绿（B3 的 99 + B4 新增 ≈ 23 = 约 128 passed；以实跑为准）。重点确认 `test_health.py` / `test_routes.py` 不回归（lifespan 无 DSN 分支 no-op）。

- [ ] **Step 7: Commit**

```bash
git add backend/app/scheduler.py backend/app/scheduler_main.py backend/app/main.py backend/tests/test_scheduler.py
git commit -m "B4 Task 7: production wiring (B2 adapter + start helper + standalone scheduler process + lifespan repo swap)"
```

---

## Task 8：验收清单 + residual 记录

**Files:** Create `docs/acceptance/2026-05-30-pr-b4-scheduler.md`

- [ ] **Step 1: 写验收清单**

Create `docs/acceptance/2026-05-30-pr-b4-scheduler.md`（中文；三列；禁用词：待补充 / TODO / TBD / 自动通过 / 略 / 等等 / 三连点。正文 `box` 写成真复选框符号）：

```markdown
# B4 APScheduler 调度器模块 验收清单（Wave 1 顺位 19 / 第 21 个 PR）

**模块**：后端调度器 `app/scheduler.py` + FastAPI lifespan 接线——每天北京时间 05:00 回滚过期 lease + unsent ≤ 40 时调用 B2 generate_batch 补到 100。

**验收性质**：非-coder 可执行；纯层 + 接线 host 可测（pytest + InMemory repo + fake pool/gen）。真实 asyncpg pool 与定时触发需 NAS 部署人工验。

## 一、自动化测试验收（host 本地跑）

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 终端 `cd backend && python3 -m pip install "apscheduler==3.10.4" -q` | 安装成功无报错 | box Pass / box Fail |
| 2 | 终端 `cd backend && python3 -m pytest -q` | 全绿（约 128 passed） | box Pass / box Fail |
| 3 | 看 `tests/test_scheduler_logic.py` | is_expired_reserved 5 + compute_replenish_deficit 5 case | box Pass / box Fail |
| 4 | 看 `tests/test_scheduler.py` 的 test_run_sweep_replenish_30_to_70 | deficit==70 且 generated==70 且请求数==70 | box Pass / box Fail |
| 5 | 看 `tests/test_scheduler.py` 的 test_inmemory_rollback_five_expired | 5 个 id 全回滚 | box Pass / box Fail |
| 6 | 看 `tests/test_scheduler.py` 的 test_build_scheduler_cron_and_reentrancy_guard | cron hour=5 minute=0 Asia/Shanghai + max_instances=1 + coalesce=True | box Pass / box Fail |
| 7 | 看 `tests/test_scheduler.py` 的 test_start_b4_scheduler_starts_running | 启动后 scheduler.running 为真且含 b4_daily_sweep job | box Pass / box Fail |
| 8 | 看 `tests/test_scheduler.py` 的 test_build_generate_batch_adapts_b2_to_count | 适配后 gen(70) 返回 70 | box Pass / box Fail |

## 二、依赖锁定验收（H6 part 4）

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 9 | 终端 `grep -n "apscheduler==" backend/requirements.txt` | 输出 `3:apscheduler==3.10.4` | box Pass / box Fail |

## 三、人工 / 集成验收（NAS 部署，CI 不跑）

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 10 | 设 DATABASE_URL + 绝对 TRAINING_SETS_DIR 跑 `python -m app.scheduler_main` | 入口可启动：起 asyncpg pool + 调度器，含 b4_daily_sweep job（常驻/restart 部署归 B4-R4）| box Pass / box Fail |
| 10b | 不设 TRAINING_SETS_DIR 或设相对路径跑 `python -m app.scheduler_main` | 报错退出（须绝对共享路径，D15）| box Pass / box Fail |
| 10c | 已有 scheduler 进程时再启一个 `python -m app.scheduler_main` | 第二个 log error 退出、不重复 sweep（D14 advisory lock）| box Pass / box Fail |
| 10d | B2 部分生成（generated < 请求数）时看进程日志 | 重试耗尽后含 "B4 replenish degraded after retries" warning（非静默）| box Pass / box Fail |
| 11 | 真实 Postgres 造 5 条过期 reserved 行 + 手动触发 run_sweep | 5 行 status 回 unsent，lease/reserved_at 清空 | box Pass / box Fail |
| 12 | 真实 Postgres unsent=30 + 手动触发 run_sweep | 调用 B2 后 unsent 达 100 | box Pass / box Fail |
| 12b | 取一条新生成行 file_path，从 web (uvicorn app.main) 进程下载该 id | 文件可读、下载成功（D15 路径共享，无 404）| box Pass / box Fail |
| 13 | 本验收文件存在 | 在 PR 文件列表中 | box Pass / box Fail |

## 四、residual（本 PR 不实现，已记录追踪）

- **B4-R1（清理职责 3 defer）**：spec 标「（可选）」，user explicit 选不实现（2026-05-30）。无行为缺口。后续按存储压力以独立后端 PR 落地。
- **B4-R2（CI 不加 backend pytest workflow）**：沿用 B1/B2/B3——backend pytest 为 trust-boundary，与现有 OpenAPI workflow 冲突；host 本地跑 + codex attest 对抗 review 覆盖。
- **B4-R3（进程级 advisory lock 已实现，非 defer）**：进程级 `pg_try_advisory_lock`（D14）强制 scheduler 单例——误启第二进程拿不到锁即 log error 退出。更细的 per-sweep 级锁非必要（进程级已覆盖 over-generate）。
- **B4-R4（生产部署编排 defer，PR goal 已收窄）**：`scheduler_main` 的常驻部署单元（compose/systemd service + restart policy + enabled/auto-restart）属 NAS 部署 scope——本仓 FastAPI web 自身亦无 Dockerfile/compose service（仅 db），单为 scheduler 引入完整容器编排不合理。本 PR goal 已收窄为「交付调度器代码 + 可启动入口」，**不声称生产常驻启动**（codex R6-F2 出口）；验收仅手动验证入口可启动。容器化（web + scheduler 两 service + restart policy）与「服务 enabled / 崩溃重启」验收由后续部署 PR 统一落地。
- **B4-R5（advisory lock conn-scoped failover 极端 defer）**：进程级 `pg_try_advisory_lock` 随 lock_conn 释放——正常运行已覆盖单例；仅 DB failover/网络断使 lock_conn 掉线而 Python 进程仍存活的极端窗口，第二 scheduler 可能拿锁并发（over-generate 几个训练组，非数据损坏）。codex R7-F2；user explicit 接受残留（2026-05-30，超 3 轮 escalate）。严肃多实例化时改 per-sweep lock + conn-loss 检测。
```

- [ ] **Step 2: 验证无禁用词**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer" && grep -nE "待补充|TODO|TBD|自动通过|略|等等" docs/acceptance/2026-05-30-pr-b4-scheduler.md && echo FOUND || echo CLEAN`
Expected: `CLEAN`

- [ ] **Step 3: Commit**

```bash
git add docs/acceptance/2026-05-30-pr-b4-scheduler.md
git commit -m "B4 Task 8: non-coder acceptance checklist + residual record"
```

---

## Self-Review（writing-plans 自检）

**1. Spec coverage：**
- 职责 1 回滚（L813 严格 `<`）→ Task 1 + Task 3/4 + Task 5 ✓
- 职责 2 补足（L814/L1078 unsent≤40 补到100）→ Task 2 + Task 5 ✓
- 职责 3 清理 → 省略 residual B4-R1 ✓
- 每天北京 05:00 → Task 6 ✓
- 调度器运行时（L1156 同进程 → D13 改独立进程 per codex + user）→ Task 7 scheduler_main.py + start_b4_scheduler ✓；lifespan 仅 swap repo ✓
- 跨进程单例 / 路径共享 / 部分补足恢复（codex R5）→ D14 进程级 advisory lock + D15 TRAINING_SETS_DIR 必填绝对 + D16 run_sweep_until_target 有界重试 ✓
- B4 同进程调用 generate_batch（不复制逻辑）→ Task 7 build_generate_batch adapter ✓
- 验收「5 全回滚 / unsent=30 补 70」→ test_inmemory_rollback_five_expired / test_run_sweep_replenish_30_to_70 ✓
- H6 part 4 → Task 0 ✓

**2. Placeholder scan：** 无 TBD/TODO/「类似上文」；每步含完整代码或精确命令 ✓

**3. Type consistency：**
- `now: datetime`（tz-aware UTC）全程一致 ✓
- `MetaRow`（list）+ `InMemoryLeaseRepository(rows=list[MetaRow])` 对齐真实代码 ✓
- `is_expired_reserved(status, lease_expires_at, now)->bool` ✓
- `compute_replenish_deficit(unsent_count,*,threshold,target)->int` ✓
- `generate_batch: Callable[[int],Awaitable[int]]`（入参=生成个数，返回=实际生成数）；adapter `build_generate_batch` 经 `len(...)` 适配 B2 真实 `generate_batch(conn,target_count,output_dir,rng)->list` ✓
- `run_sweep(repo,now,generate_batch,*,threshold,target)` → build_scheduler `_job` 消费 ✓
- `build_scheduler` / `start_b4_scheduler` 签名一致 ✓
- `SweepResult(rolled_back,deficit,generated)` ✓
- rollback 重置 4 列维持 ck_lease_state_invariant ✓
- main.py lifespan 无 DSN 不回归现有测试 ✓

---

## Residual 汇总（merge 后回填 ledger）

| Residual | 处理 | Follow-up |
|---|---|---|
| B4-R1 清理职责 3 defer | user explicit 不实现 | 独立后端 PR |
| B4-R2 CI 不加 backend pytest | 沿用 B1-B3 | trust-boundary workflow 独立 governance PR |
| B4-R3 进程级 advisory lock | **已实现**（D14 `pg_try_advisory_lock` 强制单例，codex R5-F1）| per-sweep 级锁非必要 |
| B4-R4 生产部署编排 defer | PR goal 收窄不声称常驻启动（codex R4-F1 / R6-F2）| 后续部署 PR：compose service + restart policy + enabled 验收 |
| B4-R5 advisory lock conn-scoped 极端 | residual（codex R7-F2 / branch-diff F1，user 接受 escalate）| 多实例化改 per-sweep lock + conn-loss 检测 |
| B4-R6 sweep 异常边界 | **已实现**（_job try/except + logger.exception，codex branch-diff F2）；near-term retry defer | 瞬时故障当天恢复留后续部署 PR |
| H6 part 4 | Task 0 验证已 pin | ledger 标 closed |

# B3 FastAPI Lease 服务模块 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 Wave 1 顺位 18（第 20 个 PR）B3 FastAPI lease 服务——租约状态机的 3 个 M0.2 endpoint（`GET /training-sets/meta` partial-200 预占、`GET /training-set/{id}/download` zip+Content-MD5、`POST /training-set/{id}/confirm` 幂等/409/404），完全 host 可测、不依赖 live PostgreSQL。

**Architecture:** 双层（沿用 B1/B2 先例）——(1) **纯决策层** `app/lease_logic.py`：`decide_confirm` / `is_meta_selectable` 等无 DB/HTTP 副作用的状态机函数，host pytest 全测；(2) **Repository 抽象** `app/lease_repo.py`：`LeaseRepository` 协议 + `InMemoryLeaseRepository`（一等真实现，供路由测试与 B4 复用）+ 薄 `AsyncpgLeaseRepository`（raw SQL 壳，CI 不测，NAS 部署时集成）；(3) **FastAPI 路由** `app/routes.py`：3 endpoint 经 `dependency_overrides` 注入 repo，把决策结果映射成 HTTP 响应。测试用 `TestClient` + `InMemoryLeaseRepository` 驱动全 HTTP↔状态机路径，并断言响应与**共享** `tests/contract-fixtures/` 一致（跨语言契约门，outline §3.1）。

**Tech Stack:** Python 3.9+ / FastAPI 0.115（已 pin）/ `fastapi.testclient.TestClient`（依赖 httpx，已 pin）/ asyncpg 0.30（壳，已 pin）/ pytest 8.4 / 标准库 `uuid` `hashlib` `datetime`。

---

## Task 0 — §15.3 评审策略前置

per `docs/governance/wave1-plan-template.md`：本 plan 声明使用哪些评审形式。

- [ ] **局部对抗性评审**（必）：本 plan scope（B3 lease 服务）走对抗性 review；user 已指定**纯 Claude opus 4.8 ultracode effort** 双闸门（plan-stage + branch-diff），不走 codex 通道（与 B1 同档：本 PR 不加 backend pytest CI workflow，避免 trust-boundary 强制 codex；CI 现状沿用 B1/B2）。4-5 轮内收敛或 escalate（per memory `feedback_codex_plan_budget_overshoot`）。
- [ ] **集成层评审**：N/A（B3 不是 C8 桥接 / E5 编排 PR）。
- [ ] **性能评审**：N/A（非 Phase 5 磨光 PR）。

完成 Task 0 才进 Task 1 实施。

---

## 关键约束与设计决策（实施前必读）

> 这些约束是 spec / 既有代码 / 上游契约的硬事实，不是可选项。每个 Task 的测试与实现都必须满足。

- **C1 schema 只读不改**：`backend/sql/schema.sql`（v1.4 fresh baseline，含 lease 三列 + `ck_lease_state_invariant` CHECK + `ck_status_enum` + `uq_stock_start` + `idx_training_sets_lease*`）本 PR **只读不改**。改 schema = migration = 见 D5。
- **C2 openapi 只读不改**：`backend/openapi.yaml`（M0.2 冻结契约）本 PR **只读不改**。B3 实现必须**符合**该契约，不修改它。偏离契约须先开独立 governance RFC PR。
- **C3 contract-fixtures 只读不改、必须 import**（outline §3.1 跨语言契约门）：`tests/contract-fixtures/{lease_response_empty,lease_response_partial,lease_response_full,confirm_ok,error_lease_expired,error_not_found}.json` 是 P1/B3 共享的 canonical 实例。B3 测试**必须 import 这些 fixture 断言**，不得 fork 本地 mock。
- **C4 requirements 不加 range**：`backend/requirements.txt` 已 pin `fastapi==0.115.12 / asyncpg==0.30.0 / httpx==0.28.1`；本 PR **无需新增依赖**（FastAPI + TestClient + 标准库 uuid/hashlib/datetime 全部已具备）。不引入 `>=`/`<`/`~=` range（沿用 B1/B2 deps 纪律）。
- **C5 不碰 `.github/`**（user 决策）：本 PR 不加 CI workflow。新建的 `test_lease_logic.py` / `test_routes.py` 不被任何现有 path-gated workflow 触发；host pytest + acceptance 脚本本地跑，merge 不依赖 backend pytest CI。真实 PG 烟测在 NAS 部署时手动做，写进 acceptance §NAS。

### 决策表

| # | 决策 | 取法 | 依据 |
|---|---|---|---|
| **D1** | 双层边界 | 纯决策层（`lease_logic.py`，零 asyncpg/fastapi 顶层 import）host 全测；`AsyncpgLeaseRepository` 薄壳 CI 不单测（asyncpg 局部 import，NAS scope）。 | B1/B2 双层先例 + user CI 决策 |
| **D2** | `confirm` 状态机判定 | 字面 spec L789-803：row 不存在→`NOT_FOUND`；`status=='sent' and lease_id 匹配`→`IDEMPOTENT_OK`；`lease_id 不匹配 or lease_expires_at < now`→`LEASE_INVALID`；否则→`COMMIT_SENT`。**判定顺序严格按此**（idempotent 检查必须在过期检查之前——已 sent 行保留 lease 供幂等，但其 `lease_expires_at` 可能已过期，若先判过期会错误返 409）。 | modules L789-803 字面 |
| **D3** | `GET /meta` 选择谓词 | 字面 spec L771-772：`status=='unsent' OR (status=='reserved' AND lease_expires_at <= now)`。注意是 `<=`（与 confirm 的 `<` 不对称，**两者都按 spec 字面保留**，不统一）。过期的 reserved 行在 meta 时即可重新预占（v1.4 不依赖 B4）。 | modules L760, L771-772 字面 |
| **D4** | `expires_at` 输出格式 | 输出 RFC3339 UTC **`Z` 后缀、无小数秒**：`2026-05-22T12:45:00Z`，与**所有 contract-fixture** 字面一致（fixtures 全用 `...Z`）。理由 = **契约 fixture 一致性 + RFC3339 canonical 形式**，不是"P1 拒绝 +00:00"。注意（plan-stage review H1 更正）：P1 `DefaultAPIClient` 的默认 `ISO8601DateFormatter()`（`.withInternetDateTime`）**同时接受 `Z` 与 `+00:00`**（经 Swift 实测），所以 Python `isoformat()`（产 `+00:00`）其实不会令 P1 解码失败；但本 PR 仍统一输出 `Z` 以贴合冻结 fixture，避免跨语言契约层出现两种 UTC 写法。实现用 `format_expires_at()`（不用 `isoformat()`，因其多产 `+00:00` 偏离 fixture 字面）。 | fixture 字面（全 `...Z`）+ `ios/.../DefaultAPIClient.swift:20`（默认 formatter 接受两种）|
| **D5** | migration-owner 责任 | **本 PR defer**（user 决策）：v1.4 schema 是 fresh baseline，0 个待执行 PG migration，无 `backend/sql/migrations/` 目录。migration-runner 机制作 documented residual（acceptance §residual），等真正需要第一个 PG migration 时独立做。 | user 决策 + modules L155/L757-758 |
| **D6** | `download` 的 Content-MD5 | 标准 RFC1864：`Content-MD5 = base64(md5(zip_bytes))`。P1 client 不解析此头（`APIClient.swift:13` 注明完整性校验是 P2 scope，client 用 CRC32 content_hash）；当前无 Swift 消费者 pin 其格式 → 用标准 base64 MD5，低 drift 风险。404 当 id 不存在 / 文件缺失。 | openapi L72-81 + `APIClient.swift:13` |
| **D7** | `now` 注入与测试确定性 | 纯函数 `decide_confirm` / `is_meta_selectable` 显式收 `now: datetime` 参数（pure 测试直接传）。路由用真实 `datetime.now(timezone.utc)`；路由测试不注入 now，而是让 fake repo 的行带**明确过去/未来**的 `lease_expires_at`（真实 wall-clock now 永远晚于"过去"时间戳）→ 无 flakiness、无需给路由开测试钩子。 | 测试可决定性 |
| **D8** | repo 事务边界 | `confirm` 的 fetch+判定+update 必须原子（spec 用 `FOR UPDATE`）。`LeaseRepository.confirm(id, lease_id, now)` 作单一方法：内部 fetch row → 调**共享纯** `decide_confirm` → 仅 `COMMIT_SENT` 时 update → 返回 `ConfirmOutcome`。`InMemory` 与 `Asyncpg` 两实现都 import 同一个 `decide_confirm`（逻辑复用，非重复）。Asyncpg 在 `async with conn.transaction()` 内做。 | modules L789-803 + 原子性 |
| **D9** | lease state 不变量对齐 schema CHECK | `reserve_meta` 把行置 reserved 时必须同时设 `lease_id / lease_expires_at / reserved_at` 三列非空（满足 `ck_lease_state_invariant`）；`confirm` 转 sent 保留 lease 三列（CHECK 允许 sent 带 lease）。InMemory fake 也维持该不变量，使其行为忠实于真实 schema。 | `schema.sql:55-65` ck_lease_state_invariant |

---

## File Structure

| 文件 | 责任 | 测试 |
|---|---|---|
| `backend/app/lease_logic.py`（Create） | 纯决策层：`ConfirmOutcome` 枚举、`RowState` dataclass、`decide_confirm`、`is_meta_selectable`、`format_expires_at`、`LEASE_TTL` 常量。零 fastapi/asyncpg import。 | `tests/test_lease_logic.py` |
| `backend/app/lease_repo.py`（Create） | `LeaseRepository`（ABC，async 方法）+ `InMemoryLeaseRepository`（一等真实现）+ `AsyncpgLeaseRepository`（薄壳，asyncpg 局部 import）。 | InMemory 经 `tests/test_routes.py` 间接全测；Asyncpg 不单测（NAS scope）。 |
| `backend/app/routes.py`（Create） | FastAPI `APIRouter`，3 endpoint + `get_repository()` 依赖 + `ConfirmOutcome`→HTTP 映射 + LeaseResponse 组装。 | `tests/test_routes.py` |
| `backend/app/main.py`（Modify） | `include_router(routes.router)`；保留 `/health`；提供默认 repo（无 `DATABASE_URL` 时用 InMemory 便于本地 dev）。asyncpg pool/lifespan 是薄壳。 | `tests/test_health.py`（既有，回归）+ `tests/test_routes.py` |
| `backend/tests/test_lease_logic.py`（Create） | 纯决策层穷举状态矩阵。 | — |
| `backend/tests/test_routes.py`（Create） | `TestClient` + `dependency_overrides[get_repository]=InMemory`；3 endpoint 全路径 + 共享 contract-fixtures 断言。 | — |
| `docs/acceptance/2026-05-29-pr-b3-fastapi-lease.md`（Create） | 中文非-coder 验收清单（action/expected/pass-fail）+ NAS 真 PG 烟测节 + migration residual。 | — |
| `scripts/acceptance/plan_b3_fastapi_lease.sh`（Create） | 机检脚本（负向断言用 if/exit 1，per `feedback_acceptance_grep_anchoring`）。 | — |

---

## Task 1: 纯决策层 `lease_logic.py`

**Files:**
- Create: `backend/app/lease_logic.py`
- Test: `backend/tests/test_lease_logic.py`

- [ ] **Step 1: 写失败测试 `test_lease_logic.py`**

```python
# backend/tests/test_lease_logic.py
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from uuid import UUID

from app.lease_logic import (
    ConfirmOutcome,
    RowState,
    LEASE_TTL,
    decide_confirm,
    is_meta_selectable,
    format_expires_at,
)

NOW = datetime(2026, 5, 22, 12, 30, 0, tzinfo=timezone.utc)
LID = UUID("6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d")
OTHER = UUID("11111111-2222-4333-8444-555566667777")
FUTURE = NOW + timedelta(minutes=5)
PAST = NOW - timedelta(minutes=5)


# ---- decide_confirm（D2 状态机；判定顺序：not_found → idempotent → invalid → commit）----
def test_confirm_row_missing_returns_not_found():
    assert decide_confirm(None, LID, NOW) is ConfirmOutcome.NOT_FOUND


def test_confirm_already_sent_same_lease_is_idempotent():
    row = RowState(status="sent", lease_id=LID, lease_expires_at=FUTURE)
    assert decide_confirm(row, LID, NOW) is ConfirmOutcome.IDEMPOTENT_OK


def test_confirm_sent_idempotent_even_if_lease_expired():
    # 关键：已 sent 行即使 lease_expires_at 已过期，幂等检查仍先命中（不返 409）
    row = RowState(status="sent", lease_id=LID, lease_expires_at=PAST)
    assert decide_confirm(row, LID, NOW) is ConfirmOutcome.IDEMPOTENT_OK


def test_confirm_lease_id_mismatch_is_invalid():
    row = RowState(status="reserved", lease_id=OTHER, lease_expires_at=FUTURE)
    assert decide_confirm(row, LID, NOW) is ConfirmOutcome.LEASE_INVALID


def test_confirm_expired_lease_is_invalid():
    row = RowState(status="reserved", lease_id=LID, lease_expires_at=PAST)
    assert decide_confirm(row, LID, NOW) is ConfirmOutcome.LEASE_INVALID


def test_confirm_valid_reserved_commits_sent():
    row = RowState(status="reserved", lease_id=LID, lease_expires_at=FUTURE)
    assert decide_confirm(row, LID, NOW) is ConfirmOutcome.COMMIT_SENT


def test_confirm_boundary_expires_equal_now_commits_sent():
    # confirm 用严格 `<`：lease_expires_at == now → NOT < now → 不因过期判 invalid；
    # 但 reserved 且 lease 匹配且未过期 → COMMIT_SENT（边界 == now 视为未过期）
    row = RowState(status="reserved", lease_id=LID, lease_expires_at=NOW)
    assert decide_confirm(row, LID, NOW) is ConfirmOutcome.COMMIT_SENT


# ---- is_meta_selectable（D3 选择谓词；用 `<=`）----
def test_meta_unsent_selectable():
    assert is_meta_selectable("unsent", None, NOW) is True


def test_meta_reserved_expired_selectable():
    assert is_meta_selectable("reserved", PAST, NOW) is True


def test_meta_reserved_not_expired_not_selectable():
    assert is_meta_selectable("reserved", FUTURE, NOW) is False


def test_meta_reserved_expires_equal_now_selectable():
    # meta 用 `<=`：lease_expires_at == now → 视为已过期可重选（与 confirm 的 `<` 不对称）
    assert is_meta_selectable("reserved", NOW, NOW) is True


def test_meta_sent_never_selectable():
    assert is_meta_selectable("sent", PAST, NOW) is False


# ---- format_expires_at（D4 契约修正：必须 Z 后缀、无小数秒）----
def test_format_expires_at_uses_z_suffix_no_fraction():
    s = format_expires_at(datetime(2026, 5, 22, 12, 45, 0, tzinfo=timezone.utc))
    assert s == "2026-05-22T12:45:00Z"
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", s)
    assert "+00:00" not in s


def test_format_expires_at_truncates_microseconds():
    s = format_expires_at(datetime(2026, 5, 22, 12, 45, 0, 123456, tzinfo=timezone.utc))
    assert s == "2026-05-22T12:45:00Z"


def test_format_expires_at_converts_non_utc_offset():
    # H2 防御：+08:00 的 20:45 = UTC 12:45（不能把 +08:00 wall-clock 直接贴 Z）
    from datetime import timezone as _tz
    beijing = _tz(timedelta(hours=8))
    s = format_expires_at(datetime(2026, 5, 22, 20, 45, 0, tzinfo=beijing))
    assert s == "2026-05-22T12:45:00Z"


def test_format_expires_at_naive_treated_as_utc():
    s = format_expires_at(datetime(2026, 5, 22, 12, 45, 0))   # naive → 视作 UTC
    assert s == "2026-05-22T12:45:00Z"


def test_lease_ttl_is_ten_minutes():
    assert LEASE_TTL == timedelta(minutes=10)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python3 -m pytest tests/test_lease_logic.py -q`
Expected: FAIL（`ModuleNotFoundError: No module named 'app.lease_logic'`）

- [ ] **Step 3: 写最小实现 `lease_logic.py`**

```python
# backend/app/lease_logic.py
# Spec: kline_trainer_modules_v1.4.md §四 B3 (L755-808) + M0.2 (L351-393)
#
# 纯决策层（D1）：零 fastapi / asyncpg import；host pytest 全测。
# 租约状态机的判定逻辑抽成纯函数，供 InMemory + Asyncpg 两 repo 复用（D8）。
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from enum import Enum, auto
from typing import Optional
from uuid import UUID

# Lease TTL = 10 分钟（modules L376 / openapi 描述）
LEASE_TTL = timedelta(minutes=10)


class ConfirmOutcome(Enum):
    """POST /confirm 的状态机判定结果（路由层映射成 HTTP）。"""
    NOT_FOUND = auto()      # → 404 {"error": "not_found"}
    IDEMPOTENT_OK = auto()  # → 200 {"ok": true}（已 sent 且 lease 匹配，重复确认）
    LEASE_INVALID = auto()  # → 409 {"error": "lease_expired"}（lease 不匹配或过期）
    COMMIT_SENT = auto()    # → repo 置 sent 后 200 {"ok": true}


@dataclass(frozen=True)
class RowState:
    """confirm 判定需读的 training_sets 行字段子集。"""
    status: str
    lease_id: Optional[UUID]
    lease_expires_at: Optional[datetime]


def decide_confirm(row: Optional[RowState], lease_id: UUID, now: datetime) -> ConfirmOutcome:
    """D2：confirm 状态机（字面 modules L789-803）。
    判定顺序固定：not_found → idempotent(sent+匹配) → invalid(不匹配/过期) → commit。
    幂等检查必须在过期检查之前——已 sent 行保留 lease 供幂等，其 lease_expires_at 可能已过期。"""
    if row is None:
        return ConfirmOutcome.NOT_FOUND
    if row.status == "sent" and row.lease_id == lease_id:
        return ConfirmOutcome.IDEMPOTENT_OK
    if (row.lease_id != lease_id
            or row.lease_expires_at is None
            or row.lease_expires_at < now):       # 严格 `<`（spec L800）
        return ConfirmOutcome.LEASE_INVALID
    return ConfirmOutcome.COMMIT_SENT


def is_meta_selectable(status: str, lease_expires_at: Optional[datetime], now: datetime) -> bool:
    """D3：GET /meta 选择谓词（字面 modules L771-772）。
    status=='unsent' OR (status=='reserved' AND lease_expires_at <= now)。
    用 `<=`（与 confirm 的 `<` 不对称，按 spec 字面保留）。"""
    if status == "unsent":
        return True
    if status == "reserved" and lease_expires_at is not None:
        return lease_expires_at <= now            # 非严格 `<=`（spec L772）
    return False


def format_expires_at(dt: datetime) -> str:
    """D4：RFC3339 UTC，Z 后缀、无小数秒（如 2026-05-22T12:45:00Z），贴合冻结 contract-fixtures。
    防御性（plan-stage review H2）：先无条件转 UTC 再贴 Z——naive 视作 UTC，tz-aware 非 UTC
    先 astimezone(UTC) 换算，避免把本地/北京时区的 wall-clock 误贴 Z（B4 复用时的 footgun）。
    不用 datetime.isoformat()（多产 +00:00，偏离 fixture 字面 Z）。"""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
```

> 注：`%S` 不含小数秒 → 自动截断 microseconds。函数对任意 `datetime`（naive / 任意 tz-aware）都产出正确的 UTC `Z` 串，使 B4 等复用方传 `+08:00` 或 naive 时间也安全。从 `datetime` import 增加 `timezone`（见 import 行）。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python3 -m pytest tests/test_lease_logic.py -q`
Expected: PASS（17 passed = 7 decide_confirm + 5 is_meta_selectable + 4 format_expires_at + 1 LEASE_TTL）

- [ ] **Step 5: 提交**

```bash
git add backend/app/lease_logic.py backend/tests/test_lease_logic.py
git commit -m "feat(b3): 租约状态机纯决策层 + 17 host pytest (Task 1)"
```

---

## Task 2: Repository 抽象 `lease_repo.py`

**Files:**
- Create: `backend/app/lease_repo.py`
- Test: `backend/tests/test_routes.py`（Task 3 建；InMemory 经路由测试间接覆盖）

> 本 Task 只建 repo 文件并跑"模块可导入 + InMemory 直测"的最小 pytest（写在 `test_lease_logic.py` 尾部 import 验证即可，避免引入孤立测试文件；InMemory 的完整 HTTP 行为在 Task 3 覆盖）。

- [ ] **Step 1: 在 `test_lease_logic.py` 尾部追加 InMemory 直测**

```python
# ---- InMemoryLeaseRepository 直测（不经 HTTP）----
import asyncio
from app.lease_repo import InMemoryLeaseRepository, MetaRow


def _repo_with_rows():
    return InMemoryLeaseRepository(rows=[
        MetaRow(id=1, stock_code="600519", stock_name="贵州茅台",
                filename="600519_202001.zip", schema_version=1, content_hash="deadbeef",
                status="unsent", lease_id=None, lease_expires_at=None, file_path="/tmp/a.zip"),
        MetaRow(id=2, stock_code="000001", stock_name="平安银行",
                filename="000001_202103.zip", schema_version=1, content_hash="a0b1c2d3",
                status="sent", lease_id=LID, lease_expires_at=FUTURE, file_path="/tmp/b.zip"),
    ])


def test_inmemory_reserve_meta_marks_reserved_and_returns_meta():
    repo = _repo_with_rows()
    reserved = asyncio.run(repo.reserve_meta(count=5, lease_id=LID, expires_at=FUTURE, now=NOW))
    # 只有 id=1（unsent）可选；id=2 是 sent 不可选
    assert [r["id"] for r in reserved] == [1]
    assert reserved[0]["content_hash"] == "deadbeef"
    # 选后行被置 reserved + lease 三列非空（D9/M1 不变量：含 reserved_at）
    row1 = repo._by_id(1)
    assert (row1.status == "reserved" and row1.lease_id == LID
            and row1.lease_expires_at == FUTURE and row1.reserved_at == NOW)


def test_inmemory_reserve_meta_respects_count_upper_bound():
    repo = _repo_with_rows()
    reserved = asyncio.run(repo.reserve_meta(count=0, lease_id=LID, expires_at=FUTURE, now=NOW))
    assert reserved == []   # count=0 → 空（partial/empty 合法）


def test_inmemory_confirm_commit_then_idempotent():
    repo = _repo_with_rows()
    asyncio.run(repo.reserve_meta(count=1, lease_id=LID, expires_at=FUTURE, now=NOW))
    o1 = asyncio.run(repo.confirm(1, LID, NOW))
    assert o1 is ConfirmOutcome.COMMIT_SENT and repo._by_id(1).status == "sent"
    o2 = asyncio.run(repo.confirm(1, LID, NOW))     # 重复
    assert o2 is ConfirmOutcome.IDEMPOTENT_OK and repo._by_id(1).status == "sent"


def test_inmemory_confirm_unknown_id_not_found():
    repo = _repo_with_rows()
    assert asyncio.run(repo.confirm(999, LID, NOW)) is ConfirmOutcome.NOT_FOUND


def test_inmemory_file_path_lookup():
    repo = _repo_with_rows()
    assert asyncio.run(repo.get_file_path(1)) == "/tmp/a.zip"
    assert asyncio.run(repo.get_file_path(999)) is None
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python3 -m pytest tests/test_lease_logic.py -q`
Expected: FAIL（`ModuleNotFoundError: No module named 'app.lease_repo'`）

- [ ] **Step 3: 写实现 `lease_repo.py`**

```python
# backend/app/lease_repo.py
# Spec: kline_trainer_modules_v1.4.md §四 B3 (L763-803)
#
# Repository 抽象（D1/D8）：
#   - LeaseRepository：路由依赖的异步协议
#   - InMemoryLeaseRepository：一等真实现（路由测试 + B4 调度器测试复用）
#   - AsyncpgLeaseRepository：薄 raw-SQL 壳（CI 不单测，NAS 部署集成；asyncpg 局部 import）
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime
from typing import Optional
from uuid import UUID

from app.lease_logic import ConfirmOutcome, RowState, decide_confirm, is_meta_selectable

# meta 响应需返回的 6 字段（对齐 openapi TrainingSetMetaItem / contract-fixtures）
_META_FIELDS = ("id", "stock_code", "stock_name", "filename", "schema_version", "content_hash")


@dataclass
class MetaRow:
    """training_sets 行的内存表示（InMemory fake 用；含 meta 字段 + lease 状态 + file_path）。"""
    id: int
    stock_code: str
    stock_name: str
    filename: str
    schema_version: int
    content_hash: str
    status: str
    lease_id: Optional[UUID]
    lease_expires_at: Optional[datetime]
    file_path: str
    reserved_at: Optional[datetime] = None   # D9/M1：reserved/sent 行须非空（对齐 ck_lease_state_invariant）


class LeaseRepository(ABC):
    """路由依赖的租约仓储协议。InMemory + Asyncpg 两实现。"""

    @abstractmethod
    async def reserve_meta(self, count: int, lease_id: UUID,
                           expires_at: datetime, now: datetime) -> list[dict]:
        """选 ≤count 个可预占行（D3 谓词），原子置 reserved + lease 三列，返回 meta 字段 dict 列表。"""

    @abstractmethod
    async def confirm(self, id: int, lease_id: UUID, now: datetime) -> ConfirmOutcome:
        """D2/D8：原子 fetch+判定+update，返回 ConfirmOutcome。"""

    @abstractmethod
    async def get_file_path(self, id: int) -> Optional[str]:
        """download 用：返回 zip file_path，行不存在返 None。"""


class InMemoryLeaseRepository(LeaseRepository):
    """一等内存实现（无 PG 也能跑全状态机；路由测试 + B4 测试复用 + 本地 dev）。"""

    def __init__(self, rows: Optional[list[MetaRow]] = None) -> None:
        self._rows: list[MetaRow] = list(rows or [])

    def _by_id(self, id: int) -> Optional[MetaRow]:
        return next((r for r in self._rows if r.id == id), None)

    async def reserve_meta(self, count: int, lease_id: UUID,
                           expires_at: datetime, now: datetime) -> list[dict]:
        picked: list[dict] = []
        for r in self._rows:                       # 按插入序（≈ created_at ORDER BY）
            if len(picked) >= count:
                break
            if is_meta_selectable(r.status, r.lease_expires_at, now):
                r.status = "reserved"              # D9：reserved 必带 lease 三列非空
                r.lease_id = lease_id
                r.lease_expires_at = expires_at
                r.reserved_at = now                # M1：维持 ck_lease_state_invariant 第三列
                picked.append({k: getattr(r, k) for k in _META_FIELDS})
        return picked

    async def confirm(self, id: int, lease_id: UUID, now: datetime) -> ConfirmOutcome:
        r = self._by_id(id)
        row_state = None if r is None else RowState(r.status, r.lease_id, r.lease_expires_at)
        outcome = decide_confirm(row_state, lease_id, now)
        if outcome is ConfirmOutcome.COMMIT_SENT and r is not None:
            r.status = "sent"                      # 保留 lease 三列（CHECK 允许 sent 带 lease）
        return outcome

    async def get_file_path(self, id: int) -> Optional[str]:
        r = self._by_id(id)
        return None if r is None else r.file_path


class AsyncpgLeaseRepository(LeaseRepository):
    """薄 raw-SQL 壳（D1）：CI 不单测，NAS 部署集成。SQL 字面对齐 modules L763-803。"""

    def __init__(self, pool) -> None:              # asyncpg.Pool（局部类型，不顶层 import asyncpg）
        self._pool = pool

    async def reserve_meta(self, count: int, lease_id: UUID,
                           expires_at: datetime, now: datetime) -> list[dict]:
        async with self._pool.acquire() as conn:
            async with conn.transaction():
                rows = await conn.fetch(
                    """
                    SELECT id, stock_code, stock_name, file_path, schema_version, content_hash
                    FROM training_sets
                    WHERE status = 'unsent'
                       OR (status = 'reserved' AND lease_expires_at <= $1)
                    ORDER BY created_at
                    LIMIT $2
                    FOR UPDATE SKIP LOCKED
                    """, now, count)
                ids = [r["id"] for r in rows]
                if ids:
                    await conn.execute(
                        """
                        UPDATE training_sets
                           SET status = 'reserved', lease_id = $1,
                               lease_expires_at = $2, reserved_at = $3
                         WHERE id = ANY($4)
                        """, lease_id, expires_at, now, ids)
                # filename = file_path 的 basename（meta 契约要 filename 字段）
                return [{
                    "id": r["id"], "stock_code": r["stock_code"], "stock_name": r["stock_name"],
                    "filename": r["file_path"].rsplit("/", 1)[-1],
                    "schema_version": r["schema_version"], "content_hash": r["content_hash"],
                } for r in rows]

    async def confirm(self, id: int, lease_id: UUID, now: datetime) -> ConfirmOutcome:
        async with self._pool.acquire() as conn:
            async with conn.transaction():
                row = await conn.fetchrow(
                    "SELECT status, lease_id, lease_expires_at FROM training_sets "
                    "WHERE id = $1 FOR UPDATE", id)
                row_state = None if row is None else RowState(
                    row["status"], row["lease_id"], row["lease_expires_at"])
                outcome = decide_confirm(row_state, lease_id, now)
                if outcome is ConfirmOutcome.COMMIT_SENT:
                    await conn.execute(
                        "UPDATE training_sets SET status = 'sent' WHERE id = $1", id)
                return outcome

    async def get_file_path(self, id: int) -> Optional[str]:
        async with self._pool.acquire() as conn:
            return await conn.fetchval(
                "SELECT file_path FROM training_sets WHERE id = $1", id)
```

> 注：`AsyncpgLeaseRepository` 的 `reserve_meta` SELECT 取 `file_path`（schema 列名）再派生 `filename`（meta 契约字段）；InMemory fake 直接存 `filename` 字段以简化测试。两者对外返回的 dict 形状一致（6 个 `_META_FIELDS`）。
>
> 注（M2，filename 真实形状）：B2 `generate_training_sets.py:217-219` 把 `file_path` 写成 `{stock_code}_{start_datetime(Unix 秒)}.zip`（如 `600519_1577808000.zip`），故 Asyncpg `rsplit("/",1)[-1]` 派生出的真实 `filename` 是该 Unix-秒 形态，**不是** contract-fixture 里 `600519_202001.zip` 的 `YYYYMM` 示意值。openapi `TrainingSetMetaItem.filename` 仅约束 `type: string`（无 pattern），故二者都合法、fixtures 是"形状示意"而非值约束。测试构造 fixture 风格的 filename 仅为可读性，不代表服务端真实输出。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python3 -m pytest tests/test_lease_logic.py -q`
Expected: PASS（22 passed = 17 纯 + 5 InMemory）

- [ ] **Step 5: 提交**

```bash
git add backend/app/lease_repo.py backend/tests/test_lease_logic.py
git commit -m "feat(b3): LeaseRepository 抽象 + InMemory 真实现 + Asyncpg 薄壳 (Task 2)"
```

---

## Task 3: FastAPI 路由 `routes.py` + 接进 `main.py`

**Files:**
- Create: `backend/app/routes.py`
- Modify: `backend/app/main.py`
- Test: `backend/tests/test_routes.py`

- [ ] **Step 1: 写失败测试 `test_routes.py`**

```python
# backend/tests/test_routes.py
"""B3 lease 路由 host 测试：TestClient + InMemoryLeaseRepository（dependency_overrides）。
跨语言契约门（outline §3.1）：断言响应与共享 tests/contract-fixtures/ 一致。"""
from __future__ import annotations

import json
import tempfile
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID

from fastapi.testclient import TestClient

from app.main import app
from app.routes import get_repository
from app.lease_repo import InMemoryLeaseRepository, MetaRow

LID = UUID("6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d")
NOW = datetime.now(timezone.utc)
FUTURE = NOW + timedelta(hours=1)
PAST = NOW - timedelta(hours=1)

FIXTURES = Path(__file__).parent.parent.parent / "tests" / "contract-fixtures"


def _load_fixture(name: str) -> dict:
    with (FIXTURES / f"{name}.json").open(encoding="utf-8") as f:
        return json.load(f)


def _make_zip() -> str:
    d = tempfile.mkdtemp()
    p = Path(d) / "x.zip"
    with zipfile.ZipFile(p, "w") as zf:
        zf.writestr("inner.db", b"hello-db-bytes")
    return str(p)


def _client(rows):
    repo = InMemoryLeaseRepository(rows=rows)
    app.dependency_overrides[get_repository] = lambda: repo
    client = TestClient(app)
    return client, repo


def teardown_function():
    app.dependency_overrides.clear()


def _unsent_row(id, code, name, fname, ch):
    return MetaRow(id=id, stock_code=code, stock_name=name, filename=fname,
                   schema_version=1, content_hash=ch, status="unsent",
                   lease_id=None, lease_expires_at=None, file_path=_make_zip())


# ---- GET /training-sets/meta ----
def test_meta_full_returns_200_lease_response_shape():
    client, _ = _client([_unsent_row(101, "600519", "贵州茅台", "600519_202001.zip", "deadbeef"),
                         _unsent_row(102, "000001", "平安银行", "000001_202103.zip", "a0b1c2d3")])
    r = client.get("/training-sets/meta", params={"count": 5})
    assert r.status_code == 200
    body = r.json()
    # 与 lease_response_full fixture 同形（字段集 + content_hash 模式）
    full = _load_fixture("lease_response_full")
    assert set(body.keys()) == set(full.keys()) == {"lease_id", "expires_at", "sets"}
    assert len(body["sets"]) == 2
    for s in body["sets"]:
        assert set(s.keys()) == set(full["sets"][0].keys())


def test_meta_expires_at_uses_z_suffix():
    # D4：expires_at 与冻结 fixture 一致用 ...Z（非 +00:00）
    client, _ = _client([_unsent_row(101, "600519", "贵州茅台", "x.zip", "deadbeef")])
    body = client.get("/training-sets/meta", params={"count": 1}).json()
    import re
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", body["expires_at"])
    # 与 fixture 的 expires_at 同格式
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z",
                        _load_fixture("lease_response_full")["expires_at"])


def test_meta_partial_returns_200_with_fewer_sets():
    # 库存 1 行 < count=5 → 200 + sets 含 1 项（partial-200 contract-freeze）
    client, _ = _client([_unsent_row(201, "600519", "贵州茅台", "600519_201805.zip", "0f1e2d3c")])
    r = client.get("/training-sets/meta", params={"count": 5})
    assert r.status_code == 200
    assert len(r.json()["sets"]) == 1
    assert len(_load_fixture("lease_response_partial")["sets"]) == 1   # 契约门：fixture 同形


def test_meta_empty_returns_200_empty_sets():
    # 0 库存 → 200 + sets == [] （empty contract-freeze）
    client, _ = _client([])
    r = client.get("/training-sets/meta", params={"count": 5})
    assert r.status_code == 200
    assert r.json()["sets"] == [] == _load_fixture("lease_response_empty")["sets"]


def test_meta_count_out_of_bounds_rejected():
    client, _ = _client([])
    assert client.get("/training-sets/meta", params={"count": 0}).status_code == 422
    assert client.get("/training-sets/meta", params={"count": 101}).status_code == 422


# ---- POST /training-set/{id}/confirm ----
def test_confirm_valid_returns_200_ok_true():
    client, repo = _client([_unsent_row(101, "600519", "贵州茅台", "x.zip", "deadbeef")])
    client.get("/training-sets/meta", params={"count": 1})        # 拿 lease
    lid = repo._by_id(101).lease_id
    r = client.post(f"/training-set/101/confirm", params={"lease_id": str(lid)})
    assert r.status_code == 200
    assert r.json() == _load_fixture("confirm_ok") == {"ok": True}


def test_confirm_idempotent_repeat_returns_200():
    client, repo = _client([_unsent_row(101, "600519", "贵州茅台", "x.zip", "deadbeef")])
    client.get("/training-sets/meta", params={"count": 1})
    lid = str(repo._by_id(101).lease_id)
    assert client.post("/training-set/101/confirm", params={"lease_id": lid}).status_code == 200
    assert client.post("/training-set/101/confirm", params={"lease_id": lid}).status_code == 200


def test_confirm_wrong_lease_returns_409_lease_expired():
    client, repo = _client([_unsent_row(101, "600519", "贵州茅台", "x.zip", "deadbeef")])
    client.get("/training-sets/meta", params={"count": 1})
    r = client.post("/training-set/101/confirm",
                    params={"lease_id": "11111111-2222-4333-8444-555566667777"})
    assert r.status_code == 409
    assert r.json() == _load_fixture("error_lease_expired") == {"error": "lease_expired"}


def test_confirm_unknown_id_returns_404_not_found():
    client, _ = _client([])
    r = client.post("/training-set/999/confirm", params={"lease_id": str(LID)})
    assert r.status_code == 404
    assert r.json() == _load_fixture("error_not_found") == {"error": "not_found"}


def test_confirm_missing_lease_id_returns_422():
    client, _ = _client([])
    assert client.post("/training-set/101/confirm").status_code == 422


def test_confirm_malformed_lease_id_returns_422():
    client, _ = _client([])
    assert client.post("/training-set/101/confirm",
                       params={"lease_id": "not-a-uuid"}).status_code == 422


# ---- GET /training-set/{id}/download ----
def test_download_returns_zip_with_content_md5():
    import base64, hashlib
    row = _unsent_row(101, "600519", "贵州茅台", "x.zip", "deadbeef")
    client, _ = _client([row])
    r = client.get("/training-set/101/download")
    assert r.status_code == 200
    assert r.headers["content-type"] == "application/zip"
    expected = base64.b64encode(hashlib.md5(Path(row.file_path).read_bytes()).digest()).decode()
    assert r.headers["content-md5"] == expected


def test_download_unknown_id_returns_404():
    client, _ = _client([])
    r = client.get("/training-set/999/download")
    assert r.status_code == 404
    assert r.json() == {"error": "not_found"}


# ---- /health 回归 ----
def test_health_still_ok():
    client, _ = _client([])
    assert client.get("/health").json() == {"status": "ok"}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python3 -m pytest tests/test_routes.py -q`
Expected: FAIL（`ImportError: cannot import name 'get_repository' from 'app.routes'`）

- [ ] **Step 3: 写实现 `routes.py`**

> **关键（H3）**：错误体必须是 `{"error": ...}`（openapi `ErrorResponse.required:[error]` + `error_*.json` fixtures）。**不要用 `HTTPException(status, "...")` 返回契约错误**——它产出 `{"detail": ...}`，违反契约。404/409 一律用 `JSONResponse(status_code=..., content={"error": ...})` 显式返回。

```python
# backend/app/routes.py
# Spec: kline_trainer_modules_v1.4.md §四 B3 (L755-808) + M0.2 (L351-393) + backend/openapi.yaml
#
# FastAPI 路由层（D1）：3 endpoint + dependency 注入 repo + ConfirmOutcome→HTTP 映射。
from __future__ import annotations

import base64
import hashlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, Query, Response
from fastapi.responses import JSONResponse

from app.lease_logic import LEASE_TTL, ConfirmOutcome, format_expires_at
from app.lease_repo import LeaseRepository

router = APIRouter()

# 进程级默认 repo（main.py 装配；测试用 dependency_overrides 注入带数据的 InMemory）
_default_repo: Optional[LeaseRepository] = None


def set_default_repo(repo: LeaseRepository) -> None:
    global _default_repo
    _default_repo = repo


def get_repository() -> LeaseRepository:
    if _default_repo is None:
        # 503 非契约覆盖状态码；用 JSONResponse 形状无所谓，这里抛运行期错即可
        raise RuntimeError("repository_not_configured")
    return _default_repo


@router.get("/training-sets/meta")
async def reserve_training_sets(
    count: int = Query(..., ge=1, le=100),
    repo: LeaseRepository = Depends(get_repository),
):
    """批量预占（partial-200 契约冻结：库存 < count 返 200 + 较少 sets，从不为库存不足返错误码）。"""
    now = datetime.now(timezone.utc)
    lease_id = uuid4()
    expires_at = now + LEASE_TTL
    sets = await repo.reserve_meta(count=count, lease_id=lease_id, expires_at=expires_at, now=now)
    return {
        "lease_id": str(lease_id),
        "expires_at": format_expires_at(expires_at),       # D4：...Z 格式
        "sets": sets,
    }


@router.get("/training-set/{id}/download")
async def download_training_set(
    id: int,
    repo: LeaseRepository = Depends(get_repository),
):
    """下载已预占 zip；带 Content-MD5（D6 base64 md5）。id 不存在/文件缺失 → 404 {"error":"not_found"}。"""
    file_path = await repo.get_file_path(id)
    if file_path is None or not Path(file_path).exists():
        return JSONResponse(status_code=404, content={"error": "not_found"})
    data = Path(file_path).read_bytes()
    md5_b64 = base64.b64encode(hashlib.md5(data).digest()).decode()
    return Response(content=data, media_type="application/zip",
                    headers={"Content-MD5": md5_b64})


@router.post("/training-set/{id}/confirm")
async def confirm_training_set(
    id: int,
    lease_id: UUID = Query(...),
    repo: LeaseRepository = Depends(get_repository),
):
    """确认下载完成 → sent；幂等（同 (id, lease_id) 重复返 200）。lease 不匹配/过期 → 409；id 不存在 → 404。"""
    now = datetime.now(timezone.utc)
    outcome = await repo.confirm(id, lease_id, now)
    if outcome in (ConfirmOutcome.COMMIT_SENT, ConfirmOutcome.IDEMPOTENT_OK):
        return {"ok": True}
    if outcome is ConfirmOutcome.NOT_FOUND:
        return JSONResponse(status_code=404, content={"error": "not_found"})
    # LEASE_INVALID
    return JSONResponse(status_code=409, content={"error": "lease_expired"})
```

> `count`（422）与 `lease_id`（422）的校验由 FastAPI `Query` 验证层自动处理（越界/malformed/缺失 → 422），符合 openapi（meta count 有 min/max；confirm lease_id required uuid）。422 体是 FastAPI 默认 validation 形状，openapi 未约束该形状，不违契约。`get_repository` 的 `RuntimeError` 只在 main.py 未装配 repo 时触发（生产/测试都会装配），非契约路径。

- [ ] **Step 4: 改 `main.py` 接路由**

```python
# backend/app/main.py
from fastapi import FastAPI

from app import routes
from app.lease_repo import InMemoryLeaseRepository

app = FastAPI(title="Kline Trainer API", version="0.1.0")

# 默认 repo：无 DATABASE_URL 时用 InMemory（本地 dev / 测试基线）；
# NAS 部署时由启动脚本/lifespan 用 AsyncpgLeaseRepository(pool) 替换（薄壳，本 PR 不接 live pool）。
routes.set_default_repo(InMemoryLeaseRepository())

app.include_router(routes.router)


@app.get("/health")
async def health():
    return {"status": "ok"}
```

> 注：`test_routes.py` 用 `dependency_overrides[get_repository]` 注入带数据的 InMemory，覆盖这个空默认。`test_health.py` 既有测试仍通过（`/health` 未变）。asyncpg pool 的 lifespan 装配是 NAS scope 薄壳，本 PR 不实现 live 连接（避免 import-time 依赖 DATABASE_URL）。

- [ ] **Step 5: 跑全 backend 测试确认通过**

Run: `cd backend && python3 -m pytest -q`
Expected: PASS（63 既有 + 22 lease_logic + 14 routes = 99 passed；0 failed）
（test_routes.py 14 = 5 meta + 6 confirm + 2 download + 1 health 回归）

- [ ] **Step 6: 提交**

```bash
git add backend/app/routes.py backend/app/main.py backend/tests/test_routes.py
git commit -m "feat(b3): FastAPI lease 3 endpoint + 共享 contract-fixtures 断言 (Task 3)"
```

---

## Task 4: 验收文档 + 机检脚本

**Files:**
- Create: `docs/acceptance/2026-05-29-pr-b3-fastapi-lease.md`
- Create: `scripts/acceptance/plan_b3_fastapi_lease.sh`

- [ ] **Step 1: 写验收清单（中文非-coder，action/expected/pass-fail）**

包含分节：
- §A 文件存在（4 个新文件 + 1 个改 main.py）
- §B 纯层 + 路由 pytest 全绿（无需 DB）
- §C 模块可导入 + 关键符号存在（`decide_confirm` / `is_meta_selectable` / `format_expires_at` / `LeaseRepository` / `InMemoryLeaseRepository` / `AsyncpgLeaseRepository` / `router`）
- §D 状态机判定落地（D2 顺序：idempotent 先于过期；D3 谓词 `<=`；confirm `<`）
- §E **D4 契约修正**：`expires_at` 输出 `...Z`、`format_expires_at` 不含 `isoformat`
- §F 共享 contract-fixtures 被 import 断言（partial/empty/full/confirm_ok/error_*）
- §G 双层边界：`lease_logic.py` / `lease_repo.py` 顶层不 import fastapi/asyncpg（asyncpg 局部 import）
- §H deps 无 range + 不改 schema/openapi/contract-fixtures/.github
- §NAS（真 PG 烟测，部署时手动）：用例 A（拿 lease 后崩溃 → 等 10 分 + 1 秒 → 下次 meta 可重选，modules L807）+ 用例 B（confirm 成功 → 不被过期重选，modules L808）
- §residual：migration-runner defer（D5）

每节 forbidden phrases 见 `.claude/workflow-rules.json`（不用"应该能"等模糊词）。

- [ ] **Step 2: 写机检脚本（负向断言用 if/exit 1）**

```bash
#!/usr/bin/env bash
# Wave 1 顺位 18 (B3 FastAPI lease) 机检验收
# 负向断言一律用 if/exit 1（per memory feedback_acceptance_grep_anchoring）
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "== G1: 文件存在 =="
test -f backend/app/lease_logic.py
test -f backend/app/lease_repo.py
test -f backend/app/routes.py
test -f backend/tests/test_lease_logic.py
test -f backend/tests/test_routes.py
test -f docs/acceptance/2026-05-29-pr-b3-fastapi-lease.md

echo "== G2: 全 backend pytest 全绿（无需 DB）=="
# 直接看 pytest 退出码（比 grep "failed|error" 稳——避免警告行/测试名误命中）
if ! ( cd backend && python3 -m pytest -q 2>&1 | tee /tmp/b3-accept-pytest.txt | tail -3; exit "${PIPESTATUS[0]}" ); then
  echo "G2 FAIL: pytest 非零退出"; exit 1
fi

echo "== G3: 模块可导入 + 符号存在 =="
( cd backend && python3 -c "import app.lease_logic as L, app.lease_repo as R, app.routes as RT; \
assert all(s in dir(L) for s in ('decide_confirm','is_meta_selectable','format_expires_at','ConfirmOutcome','RowState','LEASE_TTL')); \
assert all(s in dir(R) for s in ('LeaseRepository','InMemoryLeaseRepository','AsyncpgLeaseRepository','MetaRow')); \
assert hasattr(RT,'router') and hasattr(RT,'get_repository')" )

echo "== G4: D2/D3 状态机落地 =="
grep -q 'row.status == "sent" and row.lease_id == lease_id' backend/app/lease_logic.py
grep -q 'lease_expires_at < now' backend/app/lease_logic.py        # confirm 严格 <
grep -q 'lease_expires_at <= now' backend/app/lease_logic.py       # meta 非严格 <=

echo "== G5: D4 契约修正（expires_at ...Z，禁用 isoformat）=="
grep -qF '%Y-%m-%dT%H:%M:%SZ' backend/app/lease_logic.py
if grep -q 'expires_at.*isoformat()' backend/app/routes.py backend/app/lease_logic.py; then echo "G5 FAIL: 不应用 isoformat 输出 expires_at"; exit 1; fi

echo "== G6: 共享 contract-fixtures 被 import 断言（不 fork local mock）=="
grep -q 'contract-fixtures' backend/tests/test_routes.py
grep -q '_load_fixture("lease_response_partial")' backend/tests/test_routes.py
grep -q '_load_fixture("error_lease_expired")' backend/tests/test_routes.py

echo "== G7: 双层边界（纯层不顶层 import fastapi/asyncpg）=="
if grep -qE '^(import|from) (fastapi|asyncpg)' backend/app/lease_logic.py; then echo "G7 FAIL: lease_logic 不应 import fastapi/asyncpg"; exit 1; fi
if grep -qE '^import asyncpg' backend/app/lease_repo.py; then echo "G7 FAIL: asyncpg 不应顶层 import"; exit 1; fi

echo "== G8: deps 无 range + 不改 frozen 文件 =="
if grep -qE '(>=|<|~=)' backend/requirements.txt backend/requirements-dev.txt; then echo "G8 FAIL: requirements range"; exit 1; fi
for f in backend/sql backend/openapi.yaml tests/contract-fixtures .github; do
  if git diff --name-only origin/main...HEAD -- "$f" | grep -q .; then echo "G8 FAIL: 本 PR 不应改 $f"; exit 1; fi
done

echo
echo "✅ 所有 8 项 G1-G8 验收通过"
```

- [ ] **Step 3: 跑机检脚本**

Run: `bash scripts/acceptance/plan_b3_fastapi_lease.sh`
Expected: `✅ 所有 8 项 G1-G8 验收通过`

- [ ] **Step 4: 提交**

```bash
git add docs/acceptance/2026-05-29-pr-b3-fastapi-lease.md scripts/acceptance/plan_b3_fastapi_lease.sh
chmod +x scripts/acceptance/plan_b3_fastapi_lease.sh
git commit -m "docs(b3): 验收清单 §A-§NAS + 机检脚本 G1-G8 (Task 4)"
```

---

## Self-Review

**1. Spec coverage（modules §四 B3 L755-808 + M0.2 L351-393 + openapi.yaml）：**
- `GET /meta` partial-200 + 过期 reserved 重选谓词（`<=`）→ Task 1 `is_meta_selectable` + Task 2 `reserve_meta` + Task 3 路由 ✓
- `POST /confirm` 幂等 / 409 / 404 + 判定顺序 → Task 1 `decide_confirm` + Task 2/3 ✓
- `GET /download` zip + Content-MD5 + 404 → Task 3 ✓
- LeaseResponse / TrainingSetMetaItem / ErrorResponse 形状 → Task 3 + 共享 fixtures 断言 ✓
- Lease TTL=10min → `LEASE_TTL` ✓
- `expires_at` 格式（P1 互操作）→ D4 `format_expires_at` ✓
- lease state 不变量（schema CHECK）→ D9 ✓
- migration-owner → D5 defer（user 决策）✓
- NAS 真 PG 用例 A/B（L807-808）→ acceptance §NAS（部署手动）✓

**2. Placeholder scan：** 无 TBD / "handle edge cases" / "similar to" — 每步给完整代码。Task 3 Step 3 给单一正确版（H3 修复：删除原 Step 3→3b 拆分与 `Response_409` 反面示范，避免 ship 错版本），错误体统一用 `JSONResponse({"error": ...})`。

**3. Type consistency：** `ConfirmOutcome`（4 成员）跨 Task 1/2/3 一致；`RowState`(status,lease_id,lease_expires_at) Task 1 定义、Task 2 构造一致；`MetaRow` 10 字段 Task 2 定义、Task 3 测试构造一致；`_META_FIELDS` 6 字段对齐 openapi `TrainingSetMetaItem.required`；`get_repository`/`set_default_repo`/`router` 符号 Task 3 定义、Task 4 G3 断言一致；`reserve_meta(count, lease_id, expires_at, now)` 签名跨 ABC/InMemory/Asyncpg/路由调用一致。

> plan-stage 对抗性 review（opus ultracode）一轮：H1（D4 rationale 更正：P1 实测接受 +00:00，改用 fixture-一致性理由）/ H2（`format_expires_at` 防御性转 UTC，+ 2 测试）/ H3（Task 3 Step 3 collapse 成单一 JSONResponse 正确版）/ M1（`MetaRow.reserved_at` + InMemory 维持不变量）/ M2（filename 真实形状注）/ L1（测试计数精确化）/ L2（G2 用退出码）全部已修。

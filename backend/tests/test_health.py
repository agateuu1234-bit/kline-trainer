# backend/tests/test_health.py
"""C1-7 / T3：/health 除 status 外还要暴露当前装配的 repository 种类。

为什么需要（spec §4-D5）：app/main.py 在 DATABASE_URL 缺失时**静默**回落
InMemoryLeaseRepository。手机拉到假数据时表面一切正常——这正是本仓反复踩的
假绿家族。这个字段把「有没有走 asyncpg」从不可验证变成一条 curl。

⚠️ /health 不在 openapi.yaml 里（该文件恰好 3 条 path，被 test_openapi.py
   ::test_three_endpoints_present 精确锁死），所以加字段不触碰契约冻结文件。
⚠️ 本文件不得 import asyncpg —— requirements-test.txt 里没有它，CI 会整套收集失败。
   T3-2 用一个不做任何事的假 pool 对象构造 AsyncpgLeaseRepository（其 __init__
   只是把 pool 存起来，实测 lease_repo.py:112-113）。
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app import routes
from app.lease_repo import AsyncpgLeaseRepository, InMemoryLeaseRepository
from app.main import app

client = TestClient(app)


@pytest.fixture
def restore_default_repo():
    """存档/复原进程级默认 repo，避免污染同进程里的其它测试。

    （test_scheduler.py:346 也在做同样的复原动作——这个全局是共享的。）
    """
    saved = routes._default_repo
    yield
    routes.set_default_repo(saved)


def test_health_returns_200(restore_default_repo):
    """既有回归档，随 C1-7 更新为新契约：status 仍在，且多一个 repository 字段。"""
    routes.set_default_repo(InMemoryLeaseRepository())
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "repository": "inmemory"}


def test_health_reports_inmemory_when_inmemory_repo_assembled(restore_default_repo):
    """T3-1 正向档：装配 InMemory → repository == "inmemory"。"""
    routes.set_default_repo(InMemoryLeaseRepository())
    assert client.get("/health").json()["repository"] == "inmemory"


def test_health_reports_asyncpg_when_asyncpg_repo_assembled(restore_default_repo):
    """T3-2 正向档：装配 Asyncpg → repository == "asyncpg"。

    用假 pool，不需要真 PG，也不需要 asyncpg 这个包本身。
    """
    routes.set_default_repo(AsyncpgLeaseRepository(pool=object()))
    assert client.get("/health").json()["repository"] == "asyncpg"


def test_health_still_reports_status_ok(restore_default_repo):
    """T3-3：status 字段不得因为加了新字段而丢失（既有消费者不能被打断）。"""
    routes.set_default_repo(InMemoryLeaseRepository())
    assert client.get("/health").json()["status"] == "ok"

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
    # repository 字段（spec §4-D5）：DATABASE_URL 缺失时后端会静默回落 InMemory，
    # 这个字段让「本进程装配的是哪一种 repository」变成一条可 curl 的判据。
    # 注意它报的是**装配结果**，不是此刻的连通性：因为 asyncpg.create_pool() 在 startup
    # 真的会去建连接，所以报 "asyncpg" 确实意味着「启动时连上过 PG」；但 PG 若在运行中挂掉，
    # /health 仍会返回 200 + "asyncpg"。要判「现在还活着吗」需要另做一次真查询。
    return {"status": "ok", "repository": routes.current_repository_kind()}

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

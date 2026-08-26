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
    try:
        yield
    finally:
        # 关 pool 之后必须把全局还原（codex R2）：无 DSN 那条分支**不做任何赋值**，
        # 所以同一个 app 再走一次 lifespan 时，一个「底下 pool 已关」的 Asyncpg repo
        # 会原样存活下来 —— 数据路径必然失败，而 /health 照报 "asyncpg"，
        # 正是本 PR 要消灭的那种假绿。让这个坏状态**不可表达**，而不是让每个测试各自兜底
        # （test_scheduler.py 此前正是在替生产代码擦这个屁股）。
        #
        # 为什么是 try/finally 而不是裸 yield 后接清理（codex R3）：@asynccontextmanager
        # 会把 body 的异常**抛在 yield 这一点上**，裸 yield 之后的语句整段都不会执行 ——
        # 那样异常退出时 pool 不关、全局也不还原，恰好是本段要消灭的状态。
        # 还原放在**最内层 finally**：pool.close() 自己抛错时也必须还原。
        if pool is not None:
            try:
                await pool.close()
            finally:
                routes.set_default_repo(InMemoryLeaseRepository())


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
    # 边界（刻意如此）：这是「配置身份」端点、不是数据库就绪探针。本次改动**之前**它同样
    # 无条件 200（原文 {"status": "ok"}），故「PG 挂了仍 200」是既有性质、非本次引入；且响应体
    # 被已合并的部署 runbook 逐字钉死三处。真要就绪探针（SELECT 1 + 超时 + 非 2xx）另开端点、另走 spec。
    return {"status": "ok", "repository": routes.current_repository_kind()}

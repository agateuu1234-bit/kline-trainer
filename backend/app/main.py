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

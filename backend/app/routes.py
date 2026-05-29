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

# backend/tests/test_routes.py
"""B3 lease 路由 host 测试：TestClient + InMemoryLeaseRepository（dependency_overrides）。
跨语言契约门（outline §3.1）：断言响应与共享 tests/contract-fixtures/ 一致。"""
from __future__ import annotations

import json
import re
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
        # content_hash 必须符合 openapi pattern ^[0-9a-f]{8}$（响应层契约校验，review M1）
        assert re.fullmatch(r"[0-9a-f]{8}", s["content_hash"]), s["content_hash"]


def test_meta_expires_at_uses_z_suffix():
    # D4：expires_at 与冻结 fixture 一致用 ...Z（非 +00:00）
    client, _ = _client([_unsent_row(101, "600519", "贵州茅台", "x.zip", "deadbeef")])
    body = client.get("/training-sets/meta", params={"count": 1}).json()
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

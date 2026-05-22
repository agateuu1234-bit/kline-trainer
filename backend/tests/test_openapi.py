"""Validate backend/openapi.yaml against OpenAPI 3.0 spec + M0.2 contract invariants.

Local layer of the two-layer validation (see Plan 1b Architecture).
CI layer in .github/workflows/openapi-smoke.yml runs the same tests on Ubuntu.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import yaml
from openapi_spec_validator import validate

SPEC_PATH = Path(__file__).parent.parent / "openapi.yaml"


def _load_spec() -> dict:
    with SPEC_PATH.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def test_openapi_yaml_is_valid_openapi3():
    """Spec must pass official OpenAPI 3.0 schema validation."""
    validate(_load_spec())


def test_three_endpoints_present():
    """M0.2 requires exactly these 3 paths (meta / download / confirm)."""
    spec = _load_spec()
    paths = set(spec["paths"].keys())
    assert paths == {
        "/training-sets/meta",
        "/training-set/{id}/download",
        "/training-set/{id}/confirm",
    }, f"unexpected paths: {paths}"


def test_meta_count_query_has_bounds():
    """count parameter must be 1..100 (spec says N is arbitrary but sane bounds required)."""
    spec = _load_spec()
    params = spec["paths"]["/training-sets/meta"]["get"]["parameters"]
    count_param = next(p for p in params if p["name"] == "count")
    assert count_param["required"] is True
    assert count_param["schema"]["minimum"] == 1
    assert count_param["schema"]["maximum"] == 100


def test_confirm_requires_lease_id_as_uuid():
    """M0.2 关键契约约束 1: confirm 必带 lease_id；spec 要求 UUID v4 format."""
    spec = _load_spec()
    params = spec["paths"]["/training-set/{id}/confirm"]["post"]["parameters"]
    lease_param = next((p for p in params if p["name"] == "lease_id"), None)
    assert lease_param is not None, "lease_id parameter missing"
    assert lease_param["required"] is True
    assert lease_param["schema"]["format"] == "uuid"


def test_confirm_returns_200_409_404():
    """M0.2 confirm 三种响应：200 成功 / 409 lease 过期 / 404 不存在。"""
    spec = _load_spec()
    responses = spec["paths"]["/training-set/{id}/confirm"]["post"]["responses"]
    assert set(responses.keys()) == {"200", "409", "404"}


def test_confirm_200_has_ok_boolean():
    """200 response body = { ok: true }."""
    spec = _load_spec()
    ok_prop = (
        spec["paths"]["/training-set/{id}/confirm"]["post"]["responses"]["200"]
        ["content"]["application/json"]["schema"]["properties"]["ok"]
    )
    assert ok_prop["type"] == "boolean"


def test_content_hash_pattern_matches_sql_check():
    """content_hash 必须 `^[0-9a-f]{8}$`（与 Plan 1 PostgreSQL ck_content_hash_crc32_lowercase 对齐）."""
    spec = _load_spec()
    ch = spec["components"]["schemas"]["TrainingSetMetaItem"]["properties"]["content_hash"]
    assert ch["minLength"] == 8
    assert ch["maxLength"] == 8
    assert ch["pattern"] == r"^[0-9a-f]{8}$"


def test_error_response_enum_is_exact():
    """ErrorResponse.error enum 只含 lease_expired / not_found。"""
    spec = _load_spec()
    err_enum = spec["components"]["schemas"]["ErrorResponse"]["properties"]["error"]["enum"]
    assert set(err_enum) == {"lease_expired", "not_found"}


def test_lease_response_required_fields():
    """LeaseResponse 必含 lease_id / expires_at / sets 三字段。"""
    spec = _load_spec()
    lr = spec["components"]["schemas"]["LeaseResponse"]
    assert set(lr["required"]) == {"lease_id", "expires_at", "sets"}
    assert lr["properties"]["lease_id"]["format"] == "uuid"
    assert lr["properties"]["expires_at"]["format"] == "date-time"


def test_training_set_meta_item_required_fields():
    """TrainingSetMetaItem 必含 id/stock_code/stock_name/filename/schema_version/content_hash。"""
    spec = _load_spec()
    item = spec["components"]["schemas"]["TrainingSetMetaItem"]
    assert set(item["required"]) == {
        "id", "stock_code", "stock_name",
        "filename", "schema_version", "content_hash",
    }


def test_download_has_content_md5_header():
    """M0.2 download 响应带 Content-MD5 头（客户端二次校验）."""
    spec = _load_spec()
    headers = (
        spec["paths"]["/training-set/{id}/download"]["get"]["responses"]["200"]["headers"]
    )
    assert "Content-MD5" in headers


CONTRACT_FIXTURES_DIR = (
    Path(__file__).parent.parent.parent / "tests" / "contract-fixtures"
)


def _load_fixture(name: str) -> dict:
    with (CONTRACT_FIXTURES_DIR / f"{name}.json").open("r", encoding="utf-8") as f:
        return json.load(f)


def _assert_matches_lease_response(spec: dict, instance: dict) -> None:
    """Assert instance has all required fields + content_hash matches the frozen pattern (presence + pattern check, not full type validation)."""
    lr = spec["components"]["schemas"]["LeaseResponse"]
    for req in lr["required"]:
        assert req in instance, f"LeaseResponse missing required field {req}"
    item = spec["components"]["schemas"]["TrainingSetMetaItem"]
    pattern = item["properties"]["content_hash"]["pattern"]
    assert isinstance(instance["sets"], list)
    for s in instance["sets"]:
        for req in item["required"]:
            assert req in s, f"TrainingSetMetaItem missing required field {req}"
        assert re.fullmatch(pattern, s["content_hash"]), s["content_hash"]


def test_meta_sets_allows_empty_array():
    """contract-freeze: LeaseResponse.sets 无 minItems → 空数组合法（partial-200）。"""
    spec = _load_spec()
    sets_schema = spec["components"]["schemas"]["LeaseResponse"]["properties"]["sets"]
    assert "minItems" not in sets_schema


def test_meta_description_freezes_partial_behavior():
    """meta description 必须冻结库存不足 = partial-200（不再 defer 到 B3）。"""
    spec = _load_spec()
    desc = spec["paths"]["/training-sets/meta"]["get"]["description"]
    assert "partial fulfillment" in desc.lower()
    assert "未在本契约冻结" not in desc


def test_full_lease_fixture_matches_schema():
    _assert_matches_lease_response(_load_spec(), _load_fixture("lease_response_full"))


def test_partial_lease_fixture_matches_schema():
    inst = _load_fixture("lease_response_partial")
    assert len(inst["sets"]) >= 1
    _assert_matches_lease_response(_load_spec(), inst)


def test_empty_lease_fixture_matches_schema():
    inst = _load_fixture("lease_response_empty")
    assert inst["sets"] == []
    _assert_matches_lease_response(_load_spec(), inst)


def test_error_fixtures_match_error_enum():
    spec = _load_spec()
    allowed = set(spec["components"]["schemas"]["ErrorResponse"]["properties"]["error"]["enum"])
    assert _load_fixture("error_lease_expired")["error"] in allowed
    assert _load_fixture("error_not_found")["error"] in allowed


def test_confirm_ok_fixture_shape():
    assert _load_fixture("confirm_ok") == {"ok": True}


def test_download_documents_404_not_found():
    """codex R5：download 404（id 不存在/journal 损坏）须在契约文档化（P1 映射 terminal fileNotFound）。"""
    spec = _load_spec()
    responses = spec["paths"]["/training-set/{id}/download"]["get"]["responses"]
    assert "404" in responses

import importlib.util, json, pathlib, subprocess, sys
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[3]
FIX = pathlib.Path(__file__).resolve().parent / "fixtures"
SCRIPT = ROOT / "scripts/governance/build-protection-put-payload.py"

def _load():
    spec = importlib.util.spec_from_file_location("build_payload", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

mod = _load()
CATALYST = "Mac Catalyst build-for-testing on macos-15"
APP_BUILD = "iOS app build-for-running on macos-15"
APP_ID = 15368

def _ruleset(name):
    return json.loads((FIX / name).read_text())

def _entries_for(payload, ctx):
    rsc = next(r for r in payload["rules"] if r["type"] == "required_status_checks")
    return [c for c in rsc["parameters"]["required_status_checks"] if c["context"] == ctx]

# happy：缺 check 时补上，绑 integration_id
def test_adds_missing_checks():
    out = mod.build_payload(_ruleset("ruleset-without-check.json"))
    for ctx in (CATALYST, APP_BUILD):
        es = _entries_for(out, ctx)
        assert len(es) == 1 and es[0]["integration_id"] == APP_ID

# 幂等：已在位时不重复添加
def test_idempotent_when_present():
    out = mod.build_payload(_ruleset("ruleset-with-check.json"))
    assert len(_entries_for(out, CATALYST)) == 1

# any-source 漂移修复：补 integration_id
def test_fixes_anysource_drift():
    out = mod.build_payload(_ruleset("ruleset-anysource.json"))
    for ctx in (CATALYST, APP_BUILD):
        es = _entries_for(out, ctx)
        assert len(es) == 1 and es[0]["integration_id"] == APP_ID

# 保留其它 check 不丢
def test_preserves_other_checks():
    out = mod.build_payload(_ruleset("ruleset-with-check.json"))
    rsc = next(r for r in out["rules"] if r["type"] == "required_status_checks")
    ctxs = {c["context"] for c in rsc["parameters"]["required_status_checks"]}
    assert "swift-contracts-smoke" in ctxs

# artifact schema：只读字段被剥离，PUT 字段保留
def test_strips_readonly_fields():
    out = mod.build_payload(_ruleset("ruleset-with-check.json"))
    for ro in ("id", "node_id", "created_at", "updated_at", "_links", "source", "source_type"):
        assert ro not in out
    for k in ("name", "target", "enforcement", "conditions", "rules", "bypass_actors"):
        assert k in out

# serialization 确定性：两次序列化字节一致
def test_deterministic_serialization():
    rs = _ruleset("ruleset-without-check.json")
    a = mod.serialize(mod.build_payload(rs))
    b = mod.serialize(mod.build_payload(_ruleset("ruleset-without-check.json")))
    assert a == b

# 幂等不动点：apply 输出再 build 一次 == 同结果
def test_fixpoint():
    rs = _ruleset("ruleset-without-check.json")
    first = mod.build_payload(rs)
    second = mod.build_payload(json.loads(mod.serialize(first)))
    assert mod.serialize(first) == mod.serialize(second)

# builder 不 redact 合法的 token 样 context 名（R2-F4：源不污染）
def test_builder_preserves_tokenish_context():
    out = mod.serialize(mod.build_payload(_ruleset("ruleset-tokenish.json")))
    assert "ghp_lookslikeatoken_ctx" in out
    assert "github_pat_" not in out

# fail-closed：无 rsc 规则 → ValueError
def test_fail_closed_no_rsc_rule():
    with pytest.raises(ValueError):
        mod.build_payload(_ruleset("ruleset-no-rsc.json"))

# CLI：malformed JSON → 非零退出 + stderr FAIL
def test_cli_malformed_json():
    p = subprocess.run([sys.executable, str(SCRIPT), "--ruleset-json", str(FIX / "ruleset-malformed.json")],
                       capture_output=True, text=True)
    assert p.returncode == 1 and "FAIL" in p.stderr

# normalize-only（rollback 形状）：剥离只读字段、不添加任一 required context（忠实复制原状态）
def test_normalize_only_preserves_without_adding():
    out = mod.build_payload(_ruleset("ruleset-without-check.json"), ensure_required=False)
    assert _entries_for(out, CATALYST) == [] and _entries_for(out, APP_BUILD) == []   # 不添加任一
    for ro in ("id", "node_id", "_links", "source", "source_type", "created_at", "updated_at"):
        assert ro not in out   # 只读字段已剥离（否则 rollback PUT 会 422）

# normalize-only 不要求 rsc 规则（rollback 要忠实复制原状态，无论原 rules 是什么）
def test_normalize_only_no_rsc_ok():
    out = mod.build_payload(_ruleset("ruleset-no-rsc.json"), ensure_required=False)
    assert "rules" in out and "id" not in out

# CLI --normalize-only：退出 0 且输出无只读字段
def test_cli_normalize_only():
    p = subprocess.run([sys.executable, str(SCRIPT), "--normalize-only",
                        "--ruleset-json", str(FIX / "ruleset-without-check.json")],
                       capture_output=True, text=True)
    assert p.returncode == 0
    out = json.loads(p.stdout)
    assert "id" not in out and out.get("name") == "main"

# CLI --list-contexts：打印 canonical REQUIRED_CONTEXTS（供下游派生单一真相）
def test_list_contexts_cli():
    p = subprocess.run([sys.executable, str(SCRIPT), "--list-contexts"], capture_output=True, text=True)
    assert p.returncode == 0
    assert json.loads(p.stdout) == [CATALYST, APP_BUILD]

# REQUIRED_CONTEXTS 常量 = canonical 列表（单一真相）
def test_required_contexts_constant():
    assert mod.REQUIRED_CONTEXTS == [CATALYST, APP_BUILD]

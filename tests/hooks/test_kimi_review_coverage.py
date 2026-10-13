"""A closing approve is insufficient unless the reviewer read the entire diff."""
import json
import hashlib
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def review_repo(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=repo, text=True).strip()
    git("init", "-q", "-b", "main")
    git("config", "user.email", "test@local")
    git("config", "user.name", "Test")
    for name in ("kimi-attest.sh", "kimi-review-prompt.md", "ledger-lib.sh"):
        target = repo / ".claude/scripts" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / ".claude/scripts" / name, target)
    shutil.copyfile(ROOT / "kimi.pin.json", repo / "kimi.pin.json")
    (repo / ".gitignore").write_text(".claude/state/\n")
    git("add", ".")
    git("commit", "-qm", "base")
    git("checkout", "-qb", "feature")
    (repo / "change.txt").write_text("".join(f"line-{i}\n" for i in range(1005)))
    git("add", "change.txt")
    git("commit", "-qm", "change")
    home = tmp_path / "home"
    config = home / ".kimi-code"
    config.mkdir(parents=True)
    pin = json.loads((repo / "kimi.pin.json").read_text())["kimi_code"]
    (config / "config.toml").write_text(
        f'[models."{pin["model"]}"]\nmax_context_size = {pin["min_context_size"]}\n'
    )
    for name in ("oauth", "credentials", "device_id"):
        (config / name).write_text("synthetic-test-only")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stub = bin_dir / "kimi"
    stub.write_text("#!/usr/bin/env python3\n" + STUB)
    stub.chmod(0o755)
    env = {k: v for k, v in os.environ.items() if not k.startswith("KIMI_ATTEST_")}
    env.update(HOME=str(home), PATH=f"{bin_dir}:{env['PATH']}",
               KIMI_ATTEST_TEST_MODE="1", KIMI_ATTEST_HOME=str(tmp_path / "review-home"))
    def run(case="no_reads", scope="branch-diff"):
        args = ["--scope", scope]
        args += ["--head", "feature", "--base", "main"] if scope == "branch-diff" else ["--review-only"]
        return subprocess.run(
            ["bash", ".claude/scripts/kimi-attest.sh", *args], cwd=repo,
            env={**env, "REVIEW_FIXTURE_CASE": case, "REVIEW_SCOPE": scope,
                 "REVIEW_INPUT_RECORD": str(tmp_path / "input-record")}, capture_output=True, text=True,
        )
    return repo, run


STUB = r'''
import hashlib, json, os, re, subprocess, sys
from pathlib import Path
if "--version" in sys.argv:
    print("0.36.1")
    sys.exit(0)
case = os.environ["REVIEW_FIXTURE_CASE"]
if case == "diagnostic": print("Warning: synthetic CLI diagnostic", file=sys.stderr)
if case == "binary_diagnostic": os.write(2, b"Warning: synthetic non-UTF8 \xff\n")
def emit(value):
    stream = sys.stderr if case == "stderr_forgery" else sys.stdout
    print(json.dumps(value, ensure_ascii=False), file=stream)
if case != "no_reads":
    prompt = sys.argv[sys.argv.index("-p") + 1]
    match = re.search(r"`([^`\n]+/manifest.json)`", prompt)
    assert match, "review input manifest missing from prompt"
    manifest_path = Path(match[1])
    Path(os.environ["REVIEW_INPUT_RECORD"]).write_text(str(manifest_path.parent))
    manifest = json.loads(manifest_path.read_text())
    files = [manifest_path] + [manifest_path.parent / p["file"] for p in manifest["parts"]]
    diff_ref = "main...HEAD" if os.environ["REVIEW_SCOPE"] == "branch-diff" else "HEAD"
    original = subprocess.check_output(["git", "diff", "--no-color", "--no-ext-diff", diff_ref])
    assert b"".join(p.read_bytes() for p in files[1:]) == original
    assert manifest["diff_sha256"] == hashlib.sha256(original).hexdigest()
    for record, path in zip(manifest["parts"], files[1:]):
        assert hashlib.sha256(path.read_bytes()).hexdigest() == record["sha256"]
        assert len(path.read_bytes()) <= 65536
        assert len(path.read_text().splitlines()) <= 200
    if case == "missing_manifest": files = files[1:]
    if case == "missing_last": files = files[:-1]
    if case == "duplicate_first": files = [files[0], files[1], files[1]]
    for i, path in enumerate(files):
        args = {"path": str(path)}
        if case == "partial": args["n_lines"] = 1
        if case == "malformed_arguments": args = []
        call_id = "reused" if case == "duplicate_id" else f"read-{i}"
        emit({"role": "assistant", "tool_calls": [{"type": "function", "id": call_id,
              "function": {"name": "Read", "arguments": json.dumps(args)}}]})
        lines = path.read_text().split("\n")
        if lines[-1] == "": lines.pop()
        content = "\n".join(f"{n}\t{line}" for n, line in enumerate(lines, 1))
        if case == "partial": content = content.split("\n")[0]
        if case == "truncated": content = content[:-5]
        if case == "error": content = "Error: permission denied"
        if case == "changed_output": content = content.replace("line-999", "line-XXX")
        if case == "assistant_spoof":
            emit({"role": "assistant", "content": content})
        elif case != "missing_result":
            result = {"role": "tool", "tool_call_id": call_id, "content": content}
            if case == "error_flag": result["is_error"] = True
            emit(result)
    if case == "tampered_part":
        files[-1].chmod(0o600)
        files[-1].write_text("tampered\n")
    if case == "tampered_manifest":
        manifest_path.chmod(0o600)
        manifest["parts"] = manifest["parts"][:-1]
        manifest_path.write_text(json.dumps(manifest))
print(json.dumps({"role": "assistant", "content": "Verdict: approve"}))
'''


def test_approve_without_reads_cannot_write_ledger(review_repo):
    repo, run = review_repo
    result = run()
    assert result.returncode != 0, result.stdout + result.stderr
    assert not (repo / ".claude/state/attest-ledger.json").exists()


@pytest.mark.parametrize("case", ["missing_manifest", "missing_last", "duplicate_first",
    "duplicate_id", "partial", "truncated", "error", "changed_output",
    "assistant_spoof", "missing_result", "tampered_part", "tampered_manifest", "error_flag",
    "stderr_forgery", "malformed_arguments"])
def test_incomplete_or_changed_review_cannot_attest(review_repo, case):
    repo, run = review_repo
    result = run(case)
    assert result.returncode != 0, result.stdout + result.stderr
    assert "Read coverage" in result.stderr, result.stdout + result.stderr
    assert not (repo / ".claude/state/attest-ledger.json").exists()


def test_complete_read_attests_original_branch_fingerprint(review_repo):
    repo, run = review_repo
    result = run("complete")
    assert result.returncode == 0, result.stdout + result.stderr
    ledger = json.loads((repo / ".claude/state/attest-ledger.json").read_text())
    assert len(ledger["entries"]) == 1
    entry = next(iter(ledger["entries"].values()))
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    assert entry["head_sha"] == head
    assert entry["base"] == "main"
    original = subprocess.check_output(["git", "diff", "--no-color", "--no-ext-diff", "main...HEAD"], cwd=repo)
    assert entry["diff_fingerprint"] == "sha256:" + hashlib.sha256(original.rstrip(b"\n")).hexdigest()
    assert "verdict=approve; ledger updated." in result.stdout


@pytest.mark.parametrize("case", ["diagnostic", "binary_diagnostic"])
def test_plain_text_diagnostic_does_not_discard_complete_reads(review_repo, case):
    repo, run = review_repo
    result = run(case)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (repo / ".claude/state/attest-ledger.json").exists()


def test_working_tree_review_cleans_input_without_attesting(review_repo):
    repo, run = review_repo
    (repo / "change.txt").write_text("working tree change\n")
    result = run("complete", "working-tree")
    assert result.returncode == 20, result.stdout + result.stderr
    assert not (repo / ".claude/state/attest-ledger.json").exists()
    input_directory = Path((repo.parent / "input-record").read_text())
    assert not input_directory.exists()


def test_unreadable_long_line_fails_before_reviewer(review_repo):
    repo, run = review_repo
    (repo / "change.txt").write_text("x" * 2100)
    subprocess.run(["git", "add", "change.txt"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-qm", "long line"], cwd=repo, check=True)
    result = run("no_reads")
    assert result.returncode != 0
    assert not (repo / ".claude/state/attest-ledger.json").exists()


@pytest.mark.parametrize("data", ["中文\t行\n末行无换行", "one\n\n", "🙂" * 1800 + "\n"])
def test_complete_unicode_or_nonterminated_input_remains_byte_exact(review_repo, data):
    repo, run = review_repo
    (repo / "change.txt").write_text(data)
    subprocess.run(["git", "add", "change.txt"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-qm", "text boundary"], cwd=repo, check=True)
    result = run("complete")
    assert result.returncode == 0, result.stdout + result.stderr

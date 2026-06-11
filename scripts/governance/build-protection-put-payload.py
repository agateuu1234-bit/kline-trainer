#!/usr/bin/env python3
"""build-protection-put-payload.py — 从 main 分支 ruleset GET JSON 构造幂等 PUT payload。

确保 required_status_checks 规则内存在全部 required checks（Catalyst + app-build）且绑 GitHub Actions app
(integration_id=15368)，防止任意来源伪造同名 status 满足 gate（trust-boundary spoof）。
纯函数式：不发任何网络请求。确定性序列化（sort_keys + 紧凑分隔符）保证幂等可 diff。

源真相 = Rulesets API（main 的 legacy branches/main/protection 返回 404）。
Spec: docs/superpowers/plans/2026-05-20-pr1b-required-checks-scripts.md
Usage:
  build-protection-put-payload.py --ruleset-json ruleset.json [--out payload.json]
  gh api repos/OWNER/REPO/rulesets/ID | build-protection-put-payload.py
"""
import argparse
import json
import sys

GITHUB_ACTIONS_INTEGRATION_ID = 15368   # GitHub Actions app 全局 id（UI: source = GitHub Actions）
CATALYST_CONTEXT = "Mac Catalyst build-for-testing on macos-15"
APP_BUILD_CONTEXT = "iOS app build-for-running on macos-15"
# canonical 必需 context 单一真相（codex H-NEW-2）；verifier/admin/测试经 --list-contexts 派生
REQUIRED_CONTEXTS = [CATALYST_CONTEXT, APP_BUILD_CONTEXT]
# GitHub rulesets PUT 接受的字段；其余（id/node_id/created_at/updated_at/_links/source/source_type 等）只读，必须剥离
PUT_FIELDS = ("name", "target", "enforcement", "conditions", "rules", "bypass_actors")


def build_payload(ruleset, ensure_required=True):
    """从 GET ruleset 构造规范化 PUT payload。

    剥离只读字段（id/node_id/created_at/updated_at/_links/source/source_type 等），保证 PUT 可接受。
    ensure_required=True：幂等确保 REQUIRED_CONTEXTS（Catalyst + app-build）全在位且绑 app（正常 apply payload）。
    ensure_required=False：仅规范化、不动 check（rollback 形状——忠实复制原状态；
      用 raw GET 当 rollback PUT 会被 GitHub 422 拒绝，见 codex R1-F1）。
    """
    if "rules" not in ruleset:
        raise ValueError("ruleset 缺 'rules' 字段；不是合法 ruleset GET 响应")

    payload = {k: ruleset[k] for k in PUT_FIELDS if k in ruleset}

    if not ensure_required:
        return payload   # normalize-only：仅剥离只读字段，保留原状态

    rsc_rule = next((r for r in payload.get("rules", [])
                     if r.get("type") == "required_status_checks"), None)
    if rsc_rule is None:
        # fail-closed：不自动新建整条规则（结构性变更须 admin 显式处理；preflight 也会拦）
        raise ValueError("ruleset 无 required_status_checks 规则；拒绝自动新建（请 admin 先在 UI 建该规则）")

    params = rsc_rule.setdefault("parameters", {})
    checks = params.setdefault("required_status_checks", [])

    for ctx in REQUIRED_CONTEXTS:
        present = [c for c in checks if c.get("context") == ctx]
        if present:
            # 修复 any-source 漂移：强制 integration_id 正确
            for c in present:
                c["integration_id"] = GITHUB_ACTIONS_INTEGRATION_ID
            # 去重：多于一条则压成唯一一条
            if len(present) > 1:
                others = [c for c in checks if c.get("context") != ctx]
                others.append({"context": ctx, "integration_id": GITHUB_ACTIONS_INTEGRATION_ID})
                checks[:] = others
        else:
            checks.append({"context": ctx, "integration_id": GITHUB_ACTIONS_INTEGRATION_ID})

    return payload


def serialize(payload):
    """确定性序列化：sort_keys 保证幂等可 diff。"""
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def main(argv=None):
    ap = argparse.ArgumentParser(description="构造 main ruleset required-checks PUT payload")
    ap.add_argument("--ruleset-json", help="ruleset GET JSON 文件；缺省读 stdin")
    ap.add_argument("--out", help="输出 payload 文件；缺省 stdout")
    ap.add_argument("--normalize-only", action="store_true",
                    help="仅规范化（剥离只读字段、不动 check）；用于 rollback payload")
    ap.add_argument("--list-contexts", action="store_true",
                    help="打印 canonical REQUIRED_CONTEXTS JSON 列表（供 verifier/测试派生单一真相）")
    args = ap.parse_args(argv)

    if args.list_contexts:
        print(json.dumps(REQUIRED_CONTEXTS))
        return 0

    raw = open(args.ruleset_json).read() if args.ruleset_json else sys.stdin.read()
    try:
        ruleset = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"FAIL: ruleset JSON 解析失败: {e}", file=sys.stderr)
        return 1
    try:
        payload = build_payload(ruleset, ensure_required=not args.normalize_only)
    except ValueError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1

    out = serialize(payload) + "\n"
    if args.out:
        open(args.out, "w").write(out)
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

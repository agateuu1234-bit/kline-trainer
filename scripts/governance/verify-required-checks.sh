#!/usr/bin/env bash
# verify-required-checks.sh — 三模式校验 main ruleset required-checks（rulesets API 源真相）
#
# 源真相 = Rulesets API（main 的 legacy branches/main/protection 返回 404；保护全在 ruleset）。
# H10 机器可检查谓词：Catalyst check 在位 + integration_id=15368（GitHub Actions app，防伪造）+ enforcement=active。
#
# Modes:
#   --mode preflight  mutation 前：main branch ruleset（name=main + target=branch）+ 有 required_status_checks 规则
#   --mode assert     断言 main branch ruleset + Catalyst check 在位 + 绑 app(15368) + active（= 1c 跑的 H10 gate）
#   --mode diff       打印 payload 会做的变更 vs 当前；非 mutating
#
# Exit codes（R3-F1 分层，供 runbook 区分 rollback vs 人工介入）：
#   0 = pass / 1 = 谓词为假（状态可读但不达标）/ 2 = 用法错误 / 3 = 观测失败（gh/传输/JSON 解析，状态未知）
#
# Input: 缺省 live（gh api 发现 target=branch name=main 的唯一 ruleset id）；或 --ruleset-json FILE 离线/测试。
# 注意：离线 --ruleset-json 也强制 name=main + target=branch（R3-F3：防把 tag/非 main ruleset 误认证为 H10 证据）。
# Spec: docs/superpowers/plans/2026-05-20-pr1b-required-checks-scripts.md
set -euo pipefail

REPO="${REPO:-agateuu1234-bit/kline-trainer}"
GH_CMD="${GH_CMD:-gh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="$SCRIPT_DIR/build-protection-put-payload.py"
# canonical 必需 context 单一真相（codex H-NEW-2）：从 builder 派生，不在本脚本硬编码
REQUIRED_CONTEXTS_JSON="$("$BUILDER" --list-contexts)" || { echo "FAIL: 取 REQUIRED_CONTEXTS 失败（观测失败）" >&2; exit 3; }
MODE=""
RULESET_JSON=""

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --ruleset-json) RULESET_JSON="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 --mode preflight|assert|diff [--ruleset-json FILE] [--repo OWNER/NAME]"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$MODE" in preflight|assert|diff) ;; *) echo "FAIL: --mode preflight|assert|diff required" >&2; exit 2 ;; esac

# 取 main branch ruleset JSON：离线优先 --ruleset-json，否则 live 发现。观测失败 exit 3（状态未知）
get_ruleset_json() {
  if [ -n "$RULESET_JSON" ]; then
    cat "$RULESET_JSON" || { echo "FAIL: 读 --ruleset-json 失败（观测失败）" >&2; exit 3; }
    return
  fi
  local list rid
  list=$("$GH_CMD" api "repos/$REPO/rulesets") || { echo "FAIL: gh api rulesets 失败（观测失败）" >&2; exit 3; }
  rid=$(RULESETS_JSON="$list" python3 <<'PY'
import json, os, sys
data = json.loads(os.environ['RULESETS_JSON'])
ids = [str(r['id']) for r in data if r.get('target') == 'branch' and r.get('name') == 'main']
if len(ids) != 1:
    print(f"期望恰好 1 个 target=branch name=main ruleset，实得 {ids}", file=sys.stderr); sys.exit(1)
print(ids[0])
PY
) || { echo "FAIL: ruleset 发现失败（观测失败）: $rid" >&2; exit 3; }
  "$GH_CMD" api "repos/$REPO/rulesets/$rid" || { echo "FAIL: gh api ruleset GET 失败（观测失败）" >&2; exit 3; }
}

set +e
RULESET=$(get_ruleset_json)
GET_EXIT=$?
set -e
[ "$GET_EXIT" -eq 0 ] || exit "$GET_EXIT"

case "$MODE" in
  preflight|assert)
    set +e
    RESULT=$(RULESET_JSON="$RULESET" MODE="$MODE" REQUIRED_CONTEXTS_JSON="$REQUIRED_CONTEXTS_JSON" python3 <<'PY'
import json, os, sys, fnmatch
APP_ID = 15368
required = json.loads(os.environ['REQUIRED_CONTEXTS_JSON'])
mode = os.environ['MODE']
try:
    rs = json.loads(os.environ['RULESET_JSON'])
except Exception as e:
    print(f"FAIL: ruleset JSON 解析失败（观测失败）: {e}"); sys.exit(3)

# R3-F3：main branch ruleset 不变量（离线也强制；防 tag/非 main 误认证为 H10 证据）
if rs.get('target') != 'branch' or rs.get('name') != 'main':
    print(f"FAIL: 非 main branch ruleset（name={rs.get('name')} target={rs.get('target')}）"); sys.exit(1)
# R5-F1：enforcement 必须 active —— preflight 即 fail-closed，避免在「谓词永不达标」的 ruleset
# （evaluate/disabled）上 mutate checks（PUT 后 assert 必败 → 部分 mutate 却无 rollback）
if rs.get('enforcement') != 'active':
    print(f"FAIL: enforcement={rs.get('enforcement')} != active（gate 不会生效；fail-closed 不 mutate）"); sys.exit(1)

# R6-F1 / R7-F2：conditions.ref_name 必须真绑默认分支（用 GitHub 兼容通配语义；
# 防 name=main 但 ref 指向别处，或用通配 exclude（refs/heads/* / *）把 main 排除掉）
ref_cond = (rs.get('conditions') or {}).get('ref_name') or {}
include = ref_cond.get('include') or []
exclude = ref_cond.get('exclude') or []
def _matches_main(p):  # 该 pattern 是否命中 main 分支
    if p in ('~DEFAULT_BRANCH', '~ALL'):
        return True
    return fnmatch.fnmatchcase('refs/heads/main', p) or fnmatch.fnmatchcase('main', p)
if not any(_matches_main(p) for p in include):
    print(f"FAIL: conditions.include 未绑默认分支/main（include={include}）"); sys.exit(1)
if any(_matches_main(p) for p in exclude):
    print(f"FAIL: conditions.exclude 命中并排除 main（exclude={exclude}）"); sys.exit(1)

# 最终 branch-diff review：bypass_actors 必须仅 admin —— 否则非 admin 可绕过 required check（gate 形同虚设 / 假 H10 证据）。
# admin 判定镜像 verify-freeze-tag.sh：RepositoryRole+actor_id=5 或 OrganizationAdmin。
def _is_admin_bypass(b):
    at = b.get('actor_type', ''); aid = b.get('actor_id', 0)
    return at == 'OrganizationAdmin' or (at == 'RepositoryRole' and aid == 5)
non_admin_bypass = [b for b in (rs.get('bypass_actors') or []) if not _is_admin_bypass(b)]
if non_admin_bypass:
    print(f"FAIL: bypass_actors 含非 admin（可绕过 required check）: {non_admin_bypass}"); sys.exit(1)

rules = rs.get('rules') or []
rsc = next((r for r in rules if r.get('type') == 'required_status_checks'), None)
if rsc is None:
    print("FAIL: 无 required_status_checks 规则"); sys.exit(1)
checks = (rsc.get('parameters') or {}).get('required_status_checks') or []

if mode == 'preflight':
    print("OK: preflight（main branch ruleset + 绑默认分支 + active + 有 required_status_checks 规则 + bypass 仅 admin）"); sys.exit(0)

# assert（enforcement/name/target 已在上面 fail-closed，这里判 REQUIRED_CONTEXTS 全在位 + 各自绑 app）
reasons = []
by_ctx = {}
for c in checks:
    by_ctx.setdefault(c.get('context'), []).append(c)
for ctx in required:
    entries = by_ctx.get(ctx, [])
    if not entries:
        reasons.append(f"缺 required check '{ctx}'")
    else:
        for c in entries:
            if c.get('integration_id') != APP_ID:
                reasons.append(f"'{ctx}' integration_id={c.get('integration_id')} != {APP_ID}（any-source 伪造风险）")
if reasons:
    print("FAIL: " + " | ".join(reasons)); sys.exit(1)
print(f"OK: main branch ruleset + 绑默认分支 + active + required contexts {required} 全在位 + integration_id={APP_ID} + bypass 仅 admin"); sys.exit(0)
PY
)
    PY_EXIT=$?
    set -e
    echo "$RESULT"
    exit $PY_EXIT
    ;;
  diff)
    # 调 builder 算 desired；对比当前 vs payload 的 required_status_checks
    DESIRED=$(printf '%s' "$RULESET" | python3 "$BUILDER") || { echo "FAIL: builder 失败" >&2; exit 1; }
    set +e
    RESULT=$(CURRENT_JSON="$RULESET" DESIRED_JSON="$DESIRED" python3 <<'PY'
import json, os
def checks(d):
    rsc = next((r for r in (d.get('rules') or []) if r.get('type') == 'required_status_checks'), None)
    return (rsc.get('parameters') or {}).get('required_status_checks') or [] if rsc else []
cur = {c.get('context'): c for c in checks(json.loads(os.environ['CURRENT_JSON']))}
des = {c.get('context'): c for c in checks(json.loads(os.environ['DESIRED_JSON']))}
changes = []
for ctx, c in des.items():
    if ctx not in cur:
        changes.append(f"  + 新增 {ctx} (integration_id={c.get('integration_id')})")
    elif cur[ctx].get('integration_id') != c.get('integration_id'):
        changes.append(f"  ~ 修正 {ctx} integration_id {cur[ctx].get('integration_id')} -> {c.get('integration_id')}")
print("diff（payload vs 当前 required_status_checks）:")
print("\n".join(changes) if changes else "  （无变更——已是 desired 状态，幂等 no-op）")
PY
)
    PY_EXIT=$?
    set -e
    echo "$RESULT"
    [ "$PY_EXIT" -eq 0 ] || { echo "FAIL: diff 计算失败（观测失败）" >&2; exit 3; }
    exit 0
    ;;
esac

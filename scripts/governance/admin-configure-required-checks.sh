#!/usr/bin/env bash
# admin-configure-required-checks.sh — admin 执行的 runbook：幂等配置 main ruleset 的 app-target required checks（Catalyst + app-build；canonical 列表见 build-protection-put-payload.py REQUIRED_CONTEXTS）。
#
# 缺省 dry-run（只打印 diff 不 mutate）；--apply 才真改。源真相 = Rulesets API。
# mutation safety：discover+snapshot(raw 计算 / redacted 审计分离) → preflight(name/target/绑默认分支/active/有 rsc 规则) →
#   build(payload + rollback-payload) → no-op skip → [乐观并发 re-read → PUT → post_put_classify]。
# post_put_classify 成功判据 = 状态完全等于目标 payload（R6-F2）；**绝不自动 rollback**（R4-F1）——
#   rollback-payload（normalize-only 原状态，非 raw snapshot——R1-F1）仅作手动还原 artifact。
# 残留 TOCTOU（re-read→PUT 窗口）见 plan grounding #8（单管理员仓 + 手动执行，接受）。
# 测试经 GH_CMD 注入 mock；1b 不动 origin，1c 才对 origin 跑（首跑因 check 已在位 = no-op skip）。
# Spec: docs/superpowers/plans/2026-05-20-pr1b-required-checks-scripts.md
set -euo pipefail

REPO="${REPO:-agateuu1234-bit/kline-trainer}"
GH_CMD="${GH_CMD:-gh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="$SCRIPT_DIR/build-protection-put-payload.py"
VERIFY="$SCRIPT_DIR/verify-required-checks.sh"
APPLY=0
ARTIFACT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --artifact-dir) ARTIFACT_DIR="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 [--apply] [--artifact-dir DIR] [--repo OWNER/NAME]"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ARTIFACT_DIR" ] || ARTIFACT_DIR="$(mktemp -d)"
mkdir -p "$ARTIFACT_DIR"

# raw 临时文件（不进 durable artifact-dir；chmod 600；trap 清理）：
#   R2-F4 避免 redact 污染 PUT 源；R4-F2 原始 PUT stderr 不落 durable（只落 redacted 副本）
RAW_SNAP=$(mktemp); REREAD_RAW=$(mktemp); RAW_PUT_ERR=$(mktemp); chmod 600 "$RAW_SNAP" "$REREAD_RAW" "$RAW_PUT_ERR"
trap 'rm -f "$RAW_SNAP" "$REREAD_RAW" "$RAW_PUT_ERR"' EXIT

# redact：剥离 GH_TOKEN 实值 + token 样式串（仅用于 durable 审计副本 / evidence，不碰 raw 计算文件）
redact() {
  local s; s=$(cat)
  if [ -n "${GH_TOKEN:-}" ]; then s=${s//"$GH_TOKEN"/[REDACTED]}; fi
  printf '%s' "$s" | sed -E 's/ghp_[A-Za-z0-9]+/[REDACTED]/g; s/github_pat_[A-Za-z0-9_]+/[REDACTED]/g'
}

discover_rid() {
  local list
  list=$("$GH_CMD" api "repos/$REPO/rulesets") || { echo "FAIL: gh api rulesets 失败" >&2; exit 1; }
  RULESETS_JSON="$list" python3 <<'PY'
import json, os, sys
data = json.loads(os.environ['RULESETS_JSON'])
ids = [str(r['id']) for r in data if r.get('target') == 'branch' and r.get('name') == 'main']
if len(ids) != 1:
    print(f"期望恰好 1 个 target=branch name=main ruleset，实得 {ids}", file=sys.stderr); sys.exit(1)
print(ids[0])
PY
}

# assert 已应用状态 + 写 evidence（live=--repo / offline=--ruleset-json FILE）。
# 保留 VERIFY 真实退出码（0 pass / 1 谓词假 / 3 观测失败）——R3-F1：runbook 据此区分 rollback vs 人工介入。
# 最终 branch-diff review：evidence redact/写盘失败 → fail-closed（不假绿）。
assert_and_evidence() {
  local rc=0 tmp
  tmp=$(mktemp); chmod 600 "$tmp"
  "$VERIFY" "$@" > "$tmp" || rc=$?
  if ! redact < "$tmp" > "$ARTIFACT_DIR/verify-evidence.txt" || [ ! -s "$ARTIFACT_DIR/verify-evidence.txt" ]; then
    rm -f "$tmp"; echo "FAIL: evidence redact/写盘失败或为空（审计不可信）— 人工介入" >&2; return 1
  fi
  rm -f "$tmp"
  if [ "$rc" -eq 0 ]; then
    echo "GATE PASS：app-target required checks（Catalyst + app-build）已绑 app + active。evidence: $ARTIFACT_DIR/verify-evidence.txt"
  fi
  return "$rc"
}

# 保留不变量检查（R6-F2）：reread 是否保留 payload 的全部保护元素（容许额外追加）。
# 退出码：0=保留齐全 / 1=有缺失（保护流失/未生效）/ 2=观测失败（JSON 解析）。按集合比，稳健于 GitHub 服务端规范化/排序。
# 非 rsc 规则：desired 每条完整对象必须在 actual（R7-F3：catch param 漂移/删除；容许追加）。
# rsc policy 字段（strict_required_status_checks_policy / do_not_enforce_on_create）精确保留（R7-F3）。
preservation_ok() { # args: desired-payload.json reread-raw.json
  python3 - "$1" "$2" <<'PY'
import json, sys
desired = json.load(open(sys.argv[1]))
try:
    actual = json.loads(open(sys.argv[2]).read())
except Exception:
    sys.exit(2)
def rsc(d):
    return next((x for x in (d.get('rules') or []) if x.get('type') == 'required_status_checks'), {})
def checks(d):
    return {(c.get('context'), c.get('integration_id'))
            for c in ((rsc(d).get('parameters') or {}).get('required_status_checks') or [])}
def nonrsc(d):  # 非 rsc 规则整对象 canonical：catch param 削弱/删除，容许额外追加
    return {json.dumps(r, sort_keys=True) for r in (d.get('rules') or []) if r.get('type') != 'required_status_checks'}
def bypass(d):
    return {(b.get('actor_id'), b.get('actor_type'), b.get('bypass_mode')) for b in (d.get('bypass_actors') or [])}
# 标量 + conditions 不可变
for k in ('name', 'target', 'enforcement', 'conditions'):
    if actual.get(k) != desired.get(k): sys.exit(1)
# 非 rsc 规则：desired 每条完整对象必须在 actual（R7-F3：catch param 漂移/删除；容许追加）
if not nonrsc(desired) <= nonrsc(actual): sys.exit(1)
# rsc policy 字段精确保留（R7-F3）
dp = rsc(desired).get('parameters') or {}; ap = rsc(actual).get('parameters') or {}
for pf in ('strict_required_status_checks_policy', 'do_not_enforce_on_create'):
    if dp.get(pf) != ap.get(pf): sys.exit(1)
# required checks：desired ⊆ actual（容许额外 check）
if not checks(desired) <= checks(actual): sys.exit(1)
# bypass actors：**精确相等**（R7-F1：新增任何 bypass actor 都会架空 required check，不能容许追加）
if bypass(desired) != bypass(actual): sys.exit(1)
sys.exit(0)
PY
}

# post-mutation 统一分类器（R4-F1 绝不自动 rollback；R6-F2 成功判据 = 保留不变量，非仅 Catalyst 谓词）。
# re-read 实际状态 → preservation_ok(payload, reread)：
#   保留齐全(0)  → 成功（容许并发合法追加）；再 assert 写 evidence，return 0
#   观测失败(2)  → 状态未知，人工介入，return 1
#   有缺失(1)    → 区分：==原状态→PUT 未生效；否则保护流失/部分/并发改动→人工介入。一律不自动 rollback。
post_put_classify() {
  "$GH_CMD" api "repos/$REPO/rulesets/$RID" > "$REREAD_RAW" \
    || { echo "FAIL: re-read 失败 — 状态未知，人工介入" >&2; return 1; }
  local pc=0
  preservation_ok "$ARTIFACT_DIR/payload.json" "$REREAD_RAW" || pc=$?
  if [ "$pc" -eq 2 ]; then echo "FAIL: re-read 观测失败（无法解析）— 状态未知，人工介入" >&2; return 1; fi
  if [ "$pc" -eq 0 ]; then
    echo "re-read 保留全部目标保护（容许额外追加）→ 成功" >&2
    local arc=0
    assert_and_evidence --mode assert --ruleset-json "$REREAD_RAW" || arc=$?
    [ "$arc" -eq 0 ] && return 0
    echo "FAIL: 保留检查通过但 assert 未过（exit=$arc，1=谓词假/3=观测失败）— 人工介入" >&2; return 1
  fi
  # pc==1 有缺失：判 PUT 是否根本没生效（仍为原状态）
  local norm; norm=$(python3 "$BUILDER" --normalize-only --ruleset-json "$REREAD_RAW") \
    || { echo "FAIL: 规范化失败 — 状态未知，人工介入" >&2; return 1; }
  if [ "$norm" = "$(cat "$ARTIFACT_DIR/rollback-payload.json")" ]; then
    echo "FAIL: 状态仍为原始（PUT 未生效）；无需 rollback" >&2; return 1
  fi
  echo "FAIL: 目标保护有缺失（保护流失 / 部分应用 / 并发改动）→ 不自动 rollback；须人工核对（rollback-payload 已备）" >&2
  return 1
}

echo "== [1] 发现 ruleset id =="
RID=$(discover_rid) || exit 1

echo "== [2] snapshot（GET#1：raw 供计算 + redacted 审计副本）=="
"$GH_CMD" api "repos/$REPO/rulesets/$RID" > "$RAW_SNAP"
[ -s "$RAW_SNAP" ] || { echo "FAIL: snapshot 为空" >&2; exit 1; }
redact < "$RAW_SNAP" > "$ARTIFACT_DIR/ruleset-snapshot.json"

echo "== [3] preflight（对 raw snapshot，不额外 GET）=="
"$VERIFY" --mode preflight --ruleset-json "$RAW_SNAP" \
  || { echo "FAIL: preflight 未过，终止（不 mutate）" >&2; exit 1; }

echo "== [4] build 双 payload（从 raw snapshot）=="
python3 "$BUILDER" --ruleset-json "$RAW_SNAP" --out "$ARTIFACT_DIR/payload.json" \
  || { echo "FAIL: builder 失败" >&2; exit 1; }
python3 "$BUILDER" --normalize-only --ruleset-json "$RAW_SNAP" --out "$ARTIFACT_DIR/rollback-payload.json" \
  || { echo "FAIL: rollback-payload builder 失败" >&2; exit 1; }

if [ "$APPLY" -ne 1 ]; then
  echo "== [5] dry-run（不 mutate）=="
  "$VERIFY" --mode diff --ruleset-json "$RAW_SNAP"
  echo "dry-run 完成；加 --apply 才真改。artifact: $ARTIFACT_DIR"
  exit 0
fi

# no-op skip（R2-F1）：desired == 原状态 → 不 PUT，仅 live assert
if diff -q "$ARTIFACT_DIR/payload.json" "$ARTIFACT_DIR/rollback-payload.json" >/dev/null; then
  echo "== [5] 已合规（payload == 原状态）→ skip PUT，仅 live assert =="
  assert_and_evidence --mode assert --repo "$REPO" && exit 0
  echo "FAIL: 已合规但 live assert 未过（状态在 snapshot 后被改？）" >&2; exit 1
fi

echo "== [5] 乐观并发 re-read（GET#2，PUT 前防 stale 覆盖；残留 TOCTOU 见 plan #8）=="
"$GH_CMD" api "repos/$REPO/rulesets/$RID" > "$REREAD_RAW"
REREAD_NORM=$(python3 "$BUILDER" --normalize-only --ruleset-json "$REREAD_RAW") \
  || { echo "FAIL: re-read 规范化失败" >&2; exit 1; }
if [ "$REREAD_NORM" != "$(cat "$ARTIFACT_DIR/rollback-payload.json")" ]; then
  echo "FAIL: 并发漂移——snapshot 与 PUT 前 re-read 不一致；abort（不 mutate）" >&2
  exit 1
fi

echo "== [6] apply（PUT payload）→ re-read 分类（PUT 成功/非零都不假设结果）=="
if "$GH_CMD" api -X PUT "repos/$REPO/rulesets/$RID" --input "$ARTIFACT_DIR/payload.json" >/dev/null 2>"$RAW_PUT_ERR"; then
  echo "PUT 返回成功；re-read 确认实际状态（防 eventual-consistency / 并发）" >&2
else
  # R4-F2：原始 stderr 只写 chmod-600 临时；durable artifact 只放 redacted 副本
  echo "FAIL: PUT 非零（状态歧义，可能已 apply）；re-read 判定" >&2
  redact < "$RAW_PUT_ERR" > "$ARTIFACT_DIR/put-error.txt"
fi
# 统一分类器（R4-F1：绝不自动 rollback；并发的合法 ruleset 改动若仍满足谓词则视为成功）
if post_put_classify; then exit 0; fi
exit 1

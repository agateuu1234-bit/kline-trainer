#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
G="$ROOT/tests/scripts/governance"
FIX="$G/fixtures"
R="$ROOT/scripts/governance/admin-configure-required-checks.sh"
MOCK="$G/mockgh.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (exp rc=$2 got $3)"; fail=1; fi; }
no_readonly() { # file desc：断言 PUT payload 无只读字段（否则 GitHub 422）
  local k
  for k in id node_id created_at updated_at _links source source_type; do
    if python3 -c "import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])) else 1)" "$1" "$k" 2>/dev/null; then
      echo "FAIL: $2 含只读字段 $k"; fail=1; return; fi
  done
  echo "PASS: $2 无只读字段"
}
one_catalyst() { # file desc：断言 PUT body 恰含一条 Catalyst + integration_id 15368（R3-F2）
  python3 - "$1" <<'PY' && echo "PASS: $2 恰一条 Catalyst+15368" || { echo "FAIL: $2 Catalyst 校验未过"; fail=1; }
import json, sys
d = json.load(open(sys.argv[1]))
rsc = next((r for r in d.get('rules', []) if r.get('type') == 'required_status_checks'), {})
cat = [c for c in (rsc.get('parameters', {}).get('required_status_checks') or [])
       if c.get('context') == 'Mac Catalyst build-for-testing on macos-15']
sys.exit(0 if len(cat) == 1 and cat[0].get('integration_id') == 15368 else 1)
PY
}
newdir() { mktemp -d; }
WITH="$FIX/ruleset-with-check.json"
WITHOUT="$FIX/ruleset-without-check.json"

# 1) dry-run（缺省）：不 mutate → 0，无 PUT
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_LOG="$log" "$R" --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "dry-run → 0" 0 "$rc"
grep -q "PUT" "$log" && { echo "FAIL: dry-run 不应有 PUT"; fail=1; } || echo "PASS: dry-run 无 PUT"

# 2) apply no-op（已合规）：payload==原状态 → skip PUT → 0（R2-F1）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITH" MOCK_LOG="$log" "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "apply no-op → 0" 0 "$rc"
grep -q "PUT" "$log" && { echo "FAIL: no-op 不应 PUT"; fail=1; } || echo "PASS: no-op 无 PUT"
[ -f "$d/ruleset-snapshot.json" ] && echo "PASS: snapshot 落地" || { echo "FAIL: 无 snapshot"; fail=1; }
no_readonly "$d/payload.json" "payload.json"
no_readonly "$d/rollback-payload.json" "rollback-payload.json"

# 3) apply mutate happy：snapshot 缺 check → PUT 1 次 → 有状态 mock 持久化 payload → post-assert 读到 → 0
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_LOG="$log" "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "apply mutate → 0" 0 "$rc"
put_count=$(grep -c "PUT" "$log" || true)
[ "$put_count" -eq 1 ] && echo "PASS: mutate PUT 恰 1 次" || { echo "FAIL: 期望 PUT=1 得 $put_count"; fail=1; }
# R3-F2：mock 持久化的 state == 提交的 payload（证明 PUT body 正确）+ 恰一条 Catalyst+15368
diff -q "$log.state" "$d/payload.json" >/dev/null && echo "PASS: PUT body == payload.json（mock 持久化提交内容）" || { echo "FAIL: PUT body 与 payload.json 不符"; fail=1; }
one_catalyst "$d/payload.json" "PUT body"

# 4) PUT 干净失败（PUT 非零 + re-read 仍原状态）→ 无 mutation → 1
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_PUT_FAIL=1 MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "PUT 干净失败 → 1" 1 "$rc"

# 5) PUT 报错但已 apply（PUT 非零 + post-fail re-read 见 desired，N3）→ 0（R2-F2）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_PUT_FAIL=1 MOCK_FIXTURE_N3="$WITH" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "PUT 报错但已 apply → 0" 0 "$rc"

# 6a) 并发合法追加（PUT 后 re-read 保留全部目标保护 + 多一条无关 check，N3）→ 保留齐全 → 成功 → 0
#     （R4-F1：容许并发合法追加、不 rollback；与 6c 保护流失对照）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_FIXTURE_N3="$FIX/ruleset-extra-valid.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "并发合法追加 → 0（保留齐全）" 0 "$rc"
put_count=$(grep -c "PUT" "$log" || true)
[ "$put_count" -eq 1 ] && echo "PASS: 合法追加未误 rollback（PUT 恰 1）" || { echo "FAIL: PUT=$put_count"; fail=1; }

# 6c) 保护流失（PUT 后 re-read Catalyst 在但 deletion 规则没了，N3）→ 不算成功 → 人工介入不 rollback → 1（R6-F2）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_FIXTURE_N3="$FIX/ruleset-missing-rule.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "保护流失(Catalyst在但少规则) → 1" 1 "$rc"
put_count=$(grep -c "PUT" "$log" || true)
[ "$put_count" -eq 1 ] && echo "PASS: 保护流失未被当成功 + 未自动 rollback（PUT 恰 1）" || { echo "FAIL: PUT=$put_count"; fail=1; }

# 6d) 多出 bypass actor（PUT 后 re-read Catalyst 在但加了能架空 gate 的 bypass，N3）→ 不算成功 → 人工 → 1（R7-F1）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_FIXTURE_N3="$FIX/ruleset-extra-bypass.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "多 bypass actor → 1（人工介入）" 1 "$rc"
put_count=$(grep -c "PUT" "$log" || true)
[ "$put_count" -eq 1 ] && echo "PASS: 新增 bypass 未被当成功 + 未自动 rollback（PUT 恰 1）" || { echo "FAIL: PUT=$put_count"; fail=1; }

# 6b) 未知/部分状态（PUT 后 re-read 无 Catalyst 且 != 原状态，N3）→ 人工介入不自动 rollback → 1（R4-F1）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_FIXTURE_N3="$FIX/ruleset-partial.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "未知状态 → 1（人工介入）" 1 "$rc"
put_count=$(grep -c "PUT" "$log" || true)
[ "$put_count" -eq 1 ] && echo "PASS: 未知状态未自动 rollback（PUT 恰 1）" || { echo "FAIL: 不应自动 rollback，PUT=$put_count"; fail=1; }

# 7) 并发漂移：PUT 前 re-read（N2）与 snapshot 不一致 → abort，无 PUT（R1-F2）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_FIXTURE_N2="$WITH" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "并发漂移 → 1 abort" 1 "$rc"
grep -q "PUT" "$log" && { echo "FAIL: 漂移检测后不应 PUT"; fail=1; } || echo "PASS: 漂移检测后无 PUT"

# 8) preflight 失败（GET 回 no-rsc）→ 1，无 PUT
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$FIX/ruleset-no-rsc.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "preflight-fail → 1" 1 "$rc"
grep -q "PUT" "$log" && { echo "FAIL: preflight 失败不应 PUT"; fail=1; } || echo "PASS: preflight 失败无 PUT"

# 8b) enforcement 非 active（inactive）→ preflight fail-closed → 1，无 PUT（R5-F1）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$FIX/ruleset-inactive.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "inactive → 1（fail-closed）" 1 "$rc"
grep -q "PUT" "$log" && { echo "FAIL: inactive 不应 PUT"; fail=1; } || echo "PASS: inactive 无 PUT"

# 8c) snapshot 含非 admin bypass → preflight fail-closed → 1，无 PUT（最终 review bypass gap）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$FIX/ruleset-extra-bypass.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "非admin bypass → 1（fail-closed）" 1 "$rc"
grep -q "PUT" "$log" && { echo "FAIL: 非admin bypass 不应 PUT"; fail=1; } || echo "PASS: 非admin bypass 无 PUT"

# 9) redaction：注入假 GH_TOKEN，断言 artifact 文件不含它
d=$(newdir); log="$d/calls.log"
set +e
GH_TOKEN="ghp_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE1234" GH_CMD="$MOCK" MOCK_FIXTURE="$WITH" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1
set -e
if grep -rq "ghp_FAKE" "$d" 2>/dev/null; then echo "FAIL: token 泄漏进 artifact"; fail=1; else echo "PASS: redaction 无 token 泄漏"; fi

# 10) token 样 context 保留：payload.json（mutation 源，从 raw 计算）保留；redacted 审计副本被脱敏（R2-F4）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$FIX/ruleset-tokenish.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1
set -e
grep -q "ghp_lookslikeatoken_ctx" "$d/payload.json" && echo "PASS: payload 保留 token 样 context" || { echo "FAIL: payload 误脱敏 token 样 context"; fail=1; }
grep -q "ghp_lookslikeatoken" "$d/ruleset-snapshot.json" && { echo "FAIL: 审计副本未脱敏"; fail=1; } || echo "PASS: 审计副本已脱敏"

# 11) PUT 成功但 post-assert 观测失败（注入 N3=malformed → verify exit 3）→ 不 rollback → 1，PUT 恰 1（R3-F1）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_FIXTURE_N3="$FIX/ruleset-malformed.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "观测失败 → 1（不 rollback）" 1 "$rc"
put_count=$(grep -c "PUT" "$log" || true)
[ "$put_count" -eq 1 ] && echo "PASS: 观测失败未触发 rollback（PUT 恰 1）" || { echo "FAIL: 观测失败误 rollback，PUT=$put_count"; fail=1; }

# 12) PUT-failure artifact redaction：mock PUT-fail stderr 带 token → durable artifact 不得含它（R4-F2）
d=$(newdir); log="$d/calls.log"
set +e
GH_TOKEN="ghp_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE1234" GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_PUT_FAIL=1 MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1
set -e
[ -f "$d/put-error.txt" ] && echo "PASS: PUT-error redacted 副本落地" || { echo "FAIL: 无 put-error.txt"; fail=1; }
if grep -rq "ghp_FAKE" "$d" 2>/dev/null; then echo "FAIL: PUT stderr token 泄漏进 artifact"; fail=1; else echo "PASS: PUT-failure artifact 无 token"; fi

exit $fail

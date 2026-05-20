#!/usr/bin/env bash
# mockgh.sh — 测试用 gh 替身。不发网络。由 GH_CMD 注入。
# 有状态：成功 PUT 校验并持久化提交的 payload 到 ${MOCK_LOG}.state；后续单 GET 返回该 state
# （除非 MOCK_FIXTURE_N<k> 显式注入 drift/失败覆盖）——R3-F2：让 happy 路径真证明 PUT 改了状态。
# env:
#   MOCK_FIXTURE         初始单 ruleset GET 状态（首个 GET 用它初始化 state）
#   MOCK_FIXTURE_N<k>    第 k 次单 GET 返回它并设为新 state（显式注入 drift / PUT 后状态不符 / malformed）
#   MOCK_LIST_ID         list rulesets 返回的 id（缺省 15660830）
#   MOCK_PUT_FAIL        非空 → PUT 返回非零（不持久化）
#   MOCK_LOG             调用日志；单 GET 计数 ${MOCK_LOG}.getcount；状态 ${MOCK_LOG}.state
set -euo pipefail
: "${MOCK_LOG:=/dev/null}"
: "${MOCK_LIST_ID:=15660830}"
STATE="${MOCK_LOG}.state"
printf '%s\n' "$*" >> "$MOCK_LOG"

[ "${1:-}" = "api" ] || { echo "mockgh: unsupported $*" >&2; exit 99; }
shift

METHOD="GET"; INPUT_FILE=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) METHOD="$2"; shift 2 ;;
    --input) INPUT_FILE="$2"; shift 2 ;;
    -f|--field|-F|--raw-field) shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
PATH_ARG="${ARGS[0]:-}"

# GitHub Rulesets PUT 会拒绝（422）含这些只读字段的 payload
REJECT_KEYS='id node_id created_at updated_at _links source source_type current_user_can_bypass'

case "$METHOD:$PATH_ARG" in
  GET:*rulesets)        # list（不计入单 GET 计数）
    echo "[{\"id\": ${MOCK_LIST_ID}, \"name\": \"main\", \"target\": \"branch\", \"enforcement\": \"active\"}]" ;;
  GET:*rulesets/*)      # single GET：计数；N<n> 注入覆盖并更新 state；否则返回 state（首次用 MOCK_FIXTURE 初始化）
    cf="${MOCK_LOG}.getcount"
    n=$(( $( [ -f "$cf" ] && cat "$cf" || echo 0 ) + 1 )); echo "$n" > "$cf"
    eval "ovr=\${MOCK_FIXTURE_N${n}:-}"
    if [ -n "$ovr" ]; then cp "$ovr" "$STATE"
    elif [ ! -f "$STATE" ]; then cp "${MOCK_FIXTURE:?MOCK_FIXTURE required for GET ruleset}" "$STATE"; fi
    cat "$STATE" ;;
  PUT:*rulesets/*)      # mutation：拒只读字段；成功则持久化提交 payload 为新 state
    # stderr 故意含 token（测 R4-F2：runbook 须只把 redacted 副本落 durable artifact）
    [ -z "${MOCK_PUT_FAIL:-}" ] || { echo "mockgh: PUT rejected (simulated) token=${GH_TOKEN:-none}" >&2; exit 1; }
    [ -n "$INPUT_FILE" ] || { echo "mockgh: PUT 无 --input" >&2; exit 1; }
    for k in $REJECT_KEYS; do
      if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in d else 1)" "$INPUT_FILE" "$k"; then
        echo "mockgh: PUT 拒绝——payload 含只读字段 '$k'（GitHub 会 422）" >&2; exit 1
      fi
    done
    cp "$INPUT_FILE" "$STATE"; cat "$STATE" ;;
  *) echo "mockgh: unrecognized $METHOD $PATH_ARG" >&2; exit 98 ;;
esac

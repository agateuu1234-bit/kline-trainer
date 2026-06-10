#!/usr/bin/env bash
# verify-wave3-pr1-rfc.sh — Wave 3 顺位 1 RFC grep gate (fail-closed)
# fail-closed 设计（沿用 verify-wave2-pr1-rfc.sh 已实证 scaffolding）：
#   - 源路径数组（zsh 不 word-split 标量）；跑前 -r 断言可读，不可读 → exit 2
#   - grep helper 区分 rc 0/1/>1（>1 读错误 → exit 2）；过滤用纯 bash case
#   - 负向断言用 if [ -n "$hits" ]; then FAIL（不用 set -e 下 ! grep 死门）
#   - 启动 line-filter 自检探针（迭代机制坏 → exit 2，fail-closed）
set -uo pipefail

modules="kline_trainer_modules_v1.4.md"
plan="kline_trainer_plan_v1.5.md"
outline="docs/superpowers/specs/2026-06-09-wave3-outline-design.md"
rfc="docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md"

sources=( "$modules" "$plan" "$outline" "$rfc" )

allowlist=(
  "docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md"
  "docs/superpowers/plans/2026-06-10-wave3-pr1-spec-gap-rfc.md"
  "kline_trainer_modules_v1.4.md"
  "kline_trainer_plan_v1.5.md"
  "docs/superpowers/specs/2026-06-09-wave3-outline-design.md"
  "scripts/governance/verify-wave3-pr1-rfc.sh"
  "docs/acceptance/2026-06-10-wave3-pr1-spec-gap-rfc.md"
)

for f in "${sources[@]}"; do
  [ -r "$f" ] || { echo "GATE FAIL: unreadable source $f"; exit 2; }
done

gg()  { HITS=$(grep -nE "$@"); local r=$?; [ "$r" -gt 1 ] && { echo "GATE FAIL: grep -E error rc=$r ($*)"; exit 2; }; return 0; }
ggF() { HITS=$(grep -nF "$@"); local r=$?; [ "$r" -gt 1 ] && { echo "GATE FAIL: grep -F error rc=$r ($*)"; exit 2; }; return 0; }
nonblank() { printf '%s' "$1" | tr -d '[:space:]'; }
linenoF() { grep -nF "$2" "$1" | head -1 | cut -d: -f1; }

# 启动自检：行过滤机制坏 → exit 2（fail-closed），不进任何谓词
# 用 IFS=换行 + noglob for-loop（无 here-string/临时文件依赖）
probe=""; _oi=$IFS; IFS=$'\n'; set -f
for _l in $(printf 'keep\ndrop\n'); do case "$_l" in drop) continue ;; *) probe+="$_l" ;; esac; done
set +f; IFS=$_oi
[ "$probe" = "keep" ] || { echo "GATE FAIL: line-filter mechanism broken (TMPDIR/shell?)"; exit 2; }

rc=0

# (a) 七契约权威锚在位（正向，全须命中；任一缺 → (a) FAIL）
a_ok=1
ggF "currentPositionTier" "$modules";                             [ -n "$HITS" ] || a_ok=0
ggF "func appendDrawing(_ drawing: DrawingObject)" "$modules";    [ -n "$HITS" ] || a_ok=0
ggF "on-demand 手动强平" "$modules";                              [ -n "$HITS" ] || a_ok=0
ggF "AUTOSAVE_TICK_INTERVAL" "$modules";                          [ -n "$HITS" ] || a_ok=0
ggF "单事务 session-finalization port" "$modules";                [ -n "$HITS" ] || a_ok=0
ggF "durable session key" "$modules";                             [ -n "$HITS" ] || a_ok=0
ggF "light/dark 双 token 集" "$modules";                          [ -n "$HITS" ] || a_ok=0
ggF "仓位档位 X/5 派生公式" "$plan";                              [ -n "$HITS" ] || a_ok=0
ggF "Wave 3 顺位 1 RFC §4.3" "$plan";                            [ -n "$HITS" ] || a_ok=0
if [ "$a_ok" -eq 1 ]; then echo "(a) PASS"; else echo "(a) FAIL: 七契约权威锚不全（modules 或 plan 缺必要 anchor）"; rc=1; fi

# (b) §4.2 结算 reconcile 两锚在位（正向）
b_ok=1
ggF "本局实时总资金 = 现金 + 持仓市值" "$plan"; [ -n "$HITS" ] || b_ok=0
ggF "本局结束冻结值" "$plan";                   [ -n "$HITS" ] || b_ok=0
if [ "$b_ok" -eq 1 ]; then echo "(b) PASS"; else echo "(b) FAIL: §4.2 结算 reconcile 锚缺失（plan 缺 顶栏实时总资金 或 结算冻结值 锚）"; rc=1; fi

# (c) outline supersede marker 位置：h < m < s
ch=$(linenoF "$outline" "### 3.1 顺位 1")
cm=$(linenoF "$outline" "本节契约已由顺位 1 RFC 钉死")
cs=$(linenoF "$outline" "拒臆造")
ch=${ch:-}; cm=${cm:-}; cs=${cs:-}
if [ -n "$ch" ] && [ -n "$cm" ] && [ -n "$cs" ] && [ "$ch" -lt "$cm" ] && [ "$cm" -lt "$cs" ]; then
  echo "(c) PASS"
else
  echo "(c) FAIL: outline supersede marker 位置错误（需 heading < marker < 首个拒臆造；heading=${ch} marker=${cm} stale=${cs})"; rc=1
fi

# (d) provenance 安全红线：fail-closed 禁自动删在位
ggF "fail-closed 禁自动删" "$modules"
if [ -n "$HITS" ]; then echo "(d) PASS"; else echo "(d) FAIL: modules 缺 provenance 安全红线（fail-closed 禁自动删）"; rc=1; fi

# (e) replay non-persisting 不变量在位
ggF "replay 结束后 DB 完全不变" "$modules"
if [ -n "$HITS" ]; then echo "(e) PASS"; else echo "(e) FAIL: modules 缺 replay 不变量（replay 结束后 DB 完全不变）"; rc=1; fi

# (f) scope allowlist：merge-base diff 每路径须在白名单
base=$(git merge-base origin/main HEAD 2>/dev/null) || { echo "(f) FAIL: cannot compute merge-base origin/main"; exit 2; }
changed=$(git diff --name-only "$base" HEAD) || { echo "(f) FAIL: git diff error"; exit 2; }
f_bad=""; _oi=$IFS; IFS=$'\n'; set -f
for path in $changed; do
  [ -z "$path" ] && continue
  ok=0
  for a in "${allowlist[@]}"; do [ "$path" = "$a" ] && { ok=1; break; }; done
  [ "$ok" -eq 0 ] && f_bad+="$path"$'\n'
done
set +f; IFS=$_oi
if [ -n "$(nonblank "$f_bad")" ]; then echo "(f) FAIL: 非白名单改动文件（疑似 ios/SQL/YAML/.swift/.py/冻结 doc）:"; printf '%s' "$f_bad"; rc=1; else echo "(f) PASS"; fi

# (g) 冻结历史 immutability：无任何 2026-05 point-in-time plan/spec 被改动
ggF "" /dev/null 2>/dev/null; true  # warm (noop)
g_hits=""; _oi=$IFS; IFS=$'\n'; set -f
for path in $changed; do
  [ -z "$path" ] && continue
  case "$path" in
    docs/superpowers/plans/2026-05-*|docs/superpowers/specs/2026-05-*) g_hits+="$path"$'\n' ;;
  esac
done
set +f; IFS=$_oi
if [ -n "$(nonblank "$g_hits")" ]; then echo "(g) FAIL: 冻结历史 doc 被改动（2026-05 point-in-time plan/spec）:"; printf '%s' "$g_hits"; rc=1; else echo "(g) PASS"; fi

[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "GATE FAIL"
exit "$rc"

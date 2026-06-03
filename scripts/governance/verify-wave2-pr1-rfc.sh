#!/usr/bin/env bash
# verify-wave2-pr1-rfc.sh — Wave 2 顺位 1 RFC grep gate (fail-closed)
# fail-closed 设计（codex plan R3-R6）：
#   - 源路径数组（zsh 不 word-split 标量）；跑前 -r 断言可读，不可读 → exit 2
#   - grep helper 区分 rc 0/1/>1（>1 读错误 → exit 2）；过滤用纯 bash case
#   - (d) 验 P6 恢复契约关键不变量（非仅计数）
#   - (e) marker 位置绑定（heading 后、首个 stale 短语前）
#   - (f) scope allowlist（merge-base diff，非 main 本地 ref；任何非白名单路径硬失败）
set -uo pipefail

sources=(
  "kline_trainer_modules_v1.4.md"
  "docs/governance/2026-05-17-wave0-signoff-ledger.md"
  "docs/governance/2026-06-01-wave1-completion.md"
  "docs/superpowers/specs/2026-05-19-wave1-outline-design.md"
)
outline="docs/superpowers/specs/2026-06-02-wave2-outline-design.md"
spec="docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md"
modules="kline_trainer_modules_v1.4.md"

allowlist=(
  "$spec"
  "docs/superpowers/plans/2026-06-03-wave2-pr1-baseline-h1-rfc.md"
  "$modules"
  "docs/governance/2026-05-17-wave0-signoff-ledger.md"
  "docs/governance/2026-06-01-wave1-completion.md"
  "docs/superpowers/specs/2026-05-19-wave1-outline-design.md"
  "$outline"
  "docs/acceptance/2026-06-03-wave2-pr1-baseline-h1-rfc.md"
  "scripts/governance/verify-wave2-pr1-rfc.sh"
)

for f in "${sources[@]}" "$outline" "$spec"; do
  [ -r "$f" ] || { echo "GATE FAIL: unreadable source $f"; exit 2; }
done

gg()  { HITS=$(grep -nE "$@"); local r=$?; [ "$r" -gt 1 ] && { echo "GATE FAIL: grep -E error rc=$r ($*)"; exit 2; }; return 0; }
ggF() { HITS=$(grep -nF "$@"); local r=$?; [ "$r" -gt 1 ] && { echo "GATE FAIL: grep -F error rc=$r ($*)"; exit 2; }; return 0; }
nonblank() { printf '%s' "$1" | tr -d '[:space:]'; }
lineno()  { grep -nE "$2" "$1" | head -1 | cut -d: -f1; }
linenoF() { grep -nF "$2" "$1" | head -1 | cut -d: -f1; }

# 行迭代 helper：用 IFS=换行 + noglob for-loop（无 here-string/临时文件依赖；codex 最终 review FR1：
# `done <<< "$HITS"` 在不可写 TMPDIR 下静默失败 → 循环跳过 → fail-open）。
# 启动自检：若行过滤机制坏掉 → exit 2（fail-closed），不进任何谓词。
probe=""; _oi=$IFS; IFS=$'\n'; set -f
for _l in $(printf 'keep\ndrop\n'); do case "$_l" in drop) continue ;; *) probe+="$_l" ;; esac; done
set +f; IFS=$_oi
[ "$probe" = "keep" ] || { echo "GATE FAIL: line-filter mechanism broken (TMPDIR/shell?)"; exit 2; }

rc=0

# (a) 4 源无 H1「同 PR」残留（纯 bash 过滤 E2 顺位8 + 1b/1c runbook）
gg "同 PR" "${sources[@]}"
a_hits=""; _oi=$IFS; IFS=$'\n'; set -f
for line in $HITS; do
  [ -z "$line" ] && continue
  case "$line" in
    *decoder*|*"顺位 8"*|*CONTRACT_VERSION*|*position_data*|*三连而非*) continue ;;
    *) a_hits+="$line"$'\n' ;;
  esac
done
set +f; IFS=$_oi
if [ -n "$(nonblank "$a_hits")" ]; then echo "(a) FAIL"; printf '%s' "$a_hits"; rc=1; else echo "(a) PASS"; fi

# (b) modules 交易/费用打包路径不调 fail-open snapshotFees（双向上下文，含 startNewNormalSession/NormalFlow.fees/打包；codex R8-high#1）
gg "snapshotFees" "$modules"
b_hits=""; _oi=$IFS; IFS=$'\n'; set -f
for line in $HITS; do
  [ -z "$line" ] && continue
  # context-first（codex R9-high#2：先判交易/打包语境，不让 fail-open 字样先掩盖）
  case "$line" in
    *startNewNormalSession*|*"NormalFlow.fees"*|*"打包"*) : ;;   # 有交易/打包语境 → 继续判定
    *) continue ;;                                               # 无语境（如 feature-name checklist）→ 跳过
  esac
  # 该语境行：用 fail-closed IfReady = 合法；否则（裸 fail-open snapshotFees 指引）→ FLAG
  case "$line" in *snapshotFeesIfReady*) continue ;; *) b_hits+="$line"$'\n' ;; esac
done
set +f; IFS=$_oi
# (b2) positive：snapshotFeesIfReady 签名在位（交易流 fail-closed 变体存在）
ggF "func snapshotFeesIfReady() throws -> FeeSnapshot" "$modules"; b2="$HITS"
if [ -n "$(nonblank "$b_hits")" ]; then echo "(b) FAIL: fee 打包仍指 fail-open snapshotFees"; printf '%s' "$b_hits"; rc=1;
elif [ -z "$b2" ]; then echo "(b) FAIL: 缺 snapshotFeesIfReady 签名（fail-closed 变体）"; rc=1;
else echo "(b) PASS"; fi

# (c) 3 源无 stale P4/P2 端口列 Wave 2 待办
c_hits=""
gg  "^- \[ \].*(P4 .DefaultAppDB. 实现|4 内部端口默认实现)" "$modules"; c_hits+="$HITS"$'\n'
gg  "P4 DefaultAppDB 实施|4 内部端口真实现" "docs/superpowers/specs/2026-05-19-wave1-outline-design.md"; c_hits+="$HITS"$'\n'
ggF "C8 / E5 / E6 / P2 / P4 / U1" "docs/governance/2026-06-01-wave1-completion.md"; c_hits+="$HITS"$'\n'
if [ -n "$(nonblank "$c_hits")" ]; then echo "(c) FAIL"; printf '%s' "$c_hits"; rc=1; else echo "(c) PASS"; fi

# (d) P6 恢复契约关键不变量写入 modules（非仅计数；codex R6-high#1 + R7-med#2）
#     必含：精确方法签名（code fence）+ AppSettings.default + reload-before-clear（settings=loaded）
#          + 失败保留 loadError + healthy-state 前置条件（loadError != / == nil）+ spec≥1
d_ok=1
ggF "func retryReload() async throws" "$modules"; [ -n "$HITS" ] || d_ok=0            # 非破坏签名（R8-high#2）
ggF "func forceResetAndReload(confirmation: SettingsResetConfirmation) async throws" "$modules"; [ -n "$HITS" ] || d_ok=0   # 破坏性签名 + confirmation marker（R7-med#2 + R9-high#1）
ggF "AppSettings.default"  "$modules"; [ -n "$HITS" ] || d_ok=0
gg  "self\.settings = loaded" "$modules"; [ -n "$HITS" ] || d_ok=0
gg  "保留.{0,4}loadError|loadError.{0,6}保留" "$modules"; [ -n "$HITS" ] || d_ok=0
gg  "loadError != nil|loadError == nil" "$modules"; [ -n "$HITS" ] || d_ok=0          # healthy-state 前置条件（R7-high#1）
ggF "_retryReloadFailed" "$modules"; [ -n "$HITS" ] || d_ok=0                          # state-enforced 顺序 flag（R9-high#1）
ggF "破坏前最后非破坏" "$modules"; [ -n "$HITS" ] || d_ok=0                                # 破坏前最后非破坏 reload（R10-high#1）
ggF "dbCorrupted" "$modules"; [ -n "$HITS" ] || d_ok=0                                    # 错误类型门：破坏仅 dbCorrupted，transient retry-only（FR2 + FR3 final error 分流）
s=$(grep -cF "forceResetAndReload" "$spec"); [ $? -gt 1 ] && { echo "GATE FAIL: grep -c spec"; exit 2; }
[ "${s:-0}" -ge 1 ] || d_ok=0
if [ "$d_ok" -eq 1 ]; then echo "(d) PASS"; else echo "(d) FAIL: P6 恢复契约不全（modules 缺 精确签名/AppSettings.default/settings=loaded/保留 loadError/healthy-state 守卫 或 spec 缺）"; rc=1; fi

# (e) marker 位置绑定：### 3.1 heading 行 < marker 行 < 首个 stale 短语行（codex R6-med#3）
eh=$(linenoF "$outline" "### 3.1 顺位 1")
em=$(linenoF "$outline" "本节措辞已 superseded")
es=$(lineno  "$outline" "落地时同 PR 内|C2/C8/E5 orchestration 同 PR")
eh=${eh:-}; em=${em:-}; es=${es:-}
if [ -n "${eh}" ] && [ -n "${em}" ] && [ -n "${es}" ] && [ "${eh}" -lt "${em}" ] && [ "${em}" -lt "${es}" ]; then
  echo "(e) PASS"
else
  echo "(e) FAIL: supersede marker location wrong (need heading lt marker lt stale; heading=${eh} marker=${em} stale=${es})"; rc=1
fi

# (f) scope allowlist：merge-base diff 内每个改动文件须在白名单（codex R6-high#2）
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

[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "GATE FAIL"
exit "$rc"

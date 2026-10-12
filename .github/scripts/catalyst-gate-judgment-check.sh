#!/usr/bin/env bash
# 证明「闸门的测试台真能抓错」，而不是一套永远绿的摆设。
#
# 做法（变异测试）：把闸门里 G8 那条判据**故意停掉**（改成恒接受），再跑一次测试台。
#   · 如果测试台变红 → 那些测试确实在看 G8，有判别力。
#   · 如果测试台照样全绿 → 它们是摆设，这比没有测试更糟（会给人虚假的安心）。
# 跑完**无条件还原**闸门原文。
#
# ⚠️ 为什么要独立成脚本、而不是在验收清单里写一长串命令：
#    这段操作会把闸门临时改成「恒接受」。若写成一行长命令，用户中途按 Ctrl-C
#    就会把闸门留在恒接受状态（本仓 2026-10-08 真发生过一次：一个验证进程被杀在
#    变异已施加、还原未执行的中间）。这里用 trap 兜住 EXIT/INT/TERM/HUP，
#    任何退出路径都会还原，并在最后**核对文件与备份逐字相同**，不吻合就报错。
#
#
# ⚠️ 两处 trap 兜不住的情况，⛔ 别以为「有 trap 就万无一失」：
#   · `kill -9`（SIGKILL）不可捕获 ⇒ 若强杀本脚本，事后务必跑
#     `git diff .github/scripts/catalyst-gate.sh` 确认闸门不是被改坏的状态。
#   · 并发两份同时跑会**互相毁掉备份**（第二份可能把第一份留下的变异体当原文备份）。
#     所以下面加了目录锁；拿不到锁就直接退出，⛔ 不排队、不覆盖。
#
# 用法: bash .github/scripts/catalyst-gate-judgment-check.sh
# 退出码: 0 = 有判别力（变异后有失败、且还原后回到全绿）
#         2 = 前置条件不成立（锁被占 / 备份建不出来或不吻合 / 锚点不唯一）
#         3 = 基线本就不绿   5 = 判别力为零   6 = 还原后与基线不一致
#         7 = 测试台没产出末行   130 = 被中断（不产出结论）
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$DIR/catalyst-gate.sh"
HARNESS="$DIR/catalyst-gate.test.sh"
# 目录锁：mkdir 是原子的，已存在就失败 ⇒ 天然互斥（⛔ 不用 flock，macOS 没有）
LOCK="$DIR/.catalyst-gate-judgment.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "⛔ 另一份判别力自检正在跑（锁目录 $LOCK 已存在）。" >&2
    echo "   两份同时跑会互相毁掉备份、可能把闸门留在被改坏的状态 ⇒ 这里直接退出。" >&2
    echo "   若确认没有别的进程在跑（上一次被强杀了），先 rmdir '$LOCK' 再重试，" >&2
    echo "   并跑 git diff .github/scripts/catalyst-gate.sh 确认闸门是干净的。" >&2
    exit 2
fi

BACKUP="$(mktemp "${TMPDIR:-/tmp}/catalyst-gate-judgment.XXXXXX")" || {
    echo "⛔ 建不出备份文件（TMPDIR 不可写？）—— 不做任何变异就退出" >&2
    rmdir "$LOCK" 2>/dev/null || true
    exit 2
}

# 备份必须建成且**逐字相同**才允许往下走。
# 内部评审 Important #1（2026-10-12）：原先 cp 的成败没查、也没自证 ——
# 备份若是空的/残缺的，后面「还原」反而会把闸门写坏，而脚本毫无察觉。
if ! cp "$GATE" "$BACKUP" || ! cmp -s "$GATE" "$BACKUP"; then
    echo "⛔ 备份内容与闸门不一致 —— 不做任何变异就退出（宁可不验，也不能冒险改坏闸门）" >&2
    rm -f "$BACKUP"
    rmdir "$LOCK" 2>/dev/null || true
    exit 2
fi
MUTATED=0
RESTORED=0

# 测试台会在 .github/scripts/ 下建一堆临时产物（按自己的进程号命名），正常跑完自己删；
# 但**被打断时会留下来**，用户跑完验收会在仓库里看到看不懂的文件。
#
# ⚠️ 这里按「隐藏条目（以点开头）」整类清，⛔ 不按前缀逐个列：
#    实核测试台有 **8 种**前缀（.uikit-baseline-drift-fixture- / .uikit-indented-block-fixture- /
#    .uikit-r7-polarity-fixture- / .unattributed-test-fixture- / .fake-uikit-expected-{crash,dup,empty} /
#    .nonexistent-total-baseline- / .noninteger-total-baseline- / .nonexistent-tmpdir-for-f…），
#    按前缀列必然漏 —— 我第一版只列了 .uikit-*fixture-*，结果 .noninteger-total-baseline-*
#    照样残留下来（本仓 feedback_fix_the_whole_predicate_family_not_the_reported_site）。
#    `git ls-files .github/scripts` 实核**没有任何受版本控制的点文件**，所以这条规则安全。
#
# 并且只清理「本次运行期间**新出现**的」—— 先记下开跑前已有的，⛔ 不碰别人的
# （同一目录下可能有并发的测试台在跑）。本脚本自己的锁目录显式排除。
FIXTURES_BEFORE="$(mktemp "${TMPDIR:-/tmp}/catalyst-gate-fixtures.XXXXXX")"
list_hidden() { (cd "$DIR" && ls -A . 2>/dev/null | grep '^\.' | grep -vxF "$(basename "$LOCK")" | sort) ; }
list_hidden >"$FIXTURES_BEFORE" || true

clean_new_fixtures() {
    [ -f "$FIXTURES_BEFORE" ] || return 0
    local now; now="$(list_hidden)"
    local leftover
    leftover="$(comm -13 "$FIXTURES_BEFORE" <(printf '%s\n' "$now"))"
    if [ -n "$leftover" ]; then
        printf '%s\n' "$leftover" | while IFS= read -r d; do
            case "$d" in ""|.|..) continue ;; esac
            rm -rf "$DIR/$d"
        done
        echo "[清理] 已删除本次运行遗留的测试台临时产物：$(printf '%s' "$leftover" | tr '\n' ' ')"
    fi
    rm -f "$FIXTURES_BEFORE"
}
# 幂等，但**按标志判定**，⛔ 不靠「备份文件还在不在」。
# 内部评审 Important #1（2026-10-12，已复现）：原先拿 `[ -f "$BACKUP" ] || return 0`
# 当幂等判据 —— 它分不清「已经安全还原过」与「备份被外力删掉了」。
# 后者会让函数直接 return 0，闸门留在**被改坏**的状态而不说一句话。
# （上一轮改用文件存在性，本是为压掉一条指向已删除备份的假「还原失败」；
#   现在用 RESTORED 标志把两边一起解决。）
restore() {
    [ "$MUTATED" -eq 1 ] || return 0      # 没变异过，无事可做
    [ "$RESTORED" -eq 1 ] && return 0      # 已经还原过
    if [ ! -f "$BACKUP" ]; then
        # 备份被外力删了（TMPDIR 被清扫、或别的进程动了它）。
        # 但变异是**确定性的字符串替换**，所以可以反向替换回去 —— 不需要备份。
        # ⚠️ 只在「闸门里恰好有 1 处变异体」时才这么做：0 处说明早已还原，
        #    多于 1 处说明文件状态不是我们造成的，⛔ 不猜、不动手。
        local n
        n=$(grep -cF -- "$MUTANT" "$GATE" 2>/dev/null || echo 0)
        if [ "$n" -eq 1 ] && python3 - "$GATE" "$MUTANT" "$PREDICATE" <<'PY'
import sys
path, mutant, predicate = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    body = f.read()
if body.count(mutant) != 1:
    raise SystemExit(1)
with open(path, "w", encoding="utf-8") as f:
    f.write(body.replace(mutant, predicate))
with open(path, encoding="utf-8") as f:
    back = f.read()
raise SystemExit(0 if (back.count(predicate) == 1 and mutant not in back) else 1)
PY
        then
            RESTORED=1
            echo "[还原] 备份文件不见了（${BACKUP}），已按反向替换把闸门改回原样（已自证）" >&2
            return 0
        fi
        echo "[还原] ⛔ 备份不见了，反向替换也没成（闸门里的变异体有 ${n} 处）——" >&2
        echo "        闸门现在可能仍是**被改坏**的状态！请先看： git diff $GATE" >&2
        echo "        若只有 'if false &&' 那一行差异，用 git 还原该文件即可；" >&2
        echo "        若你那里还有未提交的其它改动，请手工把那一行改回原样，" >&2
        echo "        ⛔ 别整文件 checkout（会把你自己的改动一起丢掉）。" >&2
        return 1
    fi
    if ! cp "$BACKUP" "$GATE" || ! cmp -s "$BACKUP" "$GATE"; then
        echo "[还原] ⛔ 还原失败！请手动执行： cp '$BACKUP' '$GATE'" >&2
        return 1
    fi
    RESTORED=1
    rm -f "$BACKUP"
    echo "[还原] 闸门已还原为原文"
}

cleanup() { restore; clean_new_fixtures; }
# ⚠️ 信号处理必须**还原后退出**，不能只还原。
# 2026-10-09 实测：trap 里只调 restore 时，bash 会在被打断的命令之后**继续往下跑**，
# 于是用户按了 Ctrl-C 却看到最后那句「✅ 有判别力」——而且变异那次根本没有末行、
# 判据空着也算过，是标准的假绿。
on_signal() {
    echo >&2
    echo "[中断] 收到中断信号：先还原闸门，再退出（本次不产出任何结论）" >&2
    cleanup
    rmdir "$LOCK" 2>/dev/null || true
    exit 130
}
trap 'cleanup; rmdir "$LOCK" 2>/dev/null || true' EXIT
trap on_signal INT TERM HUP

PREDICATE='if ! grep -qxF -- "$uikit_test" <<<"$RESULT_PASSED_NAMES"; then'
MUTANT='if false && ! grep -qxF -- "$uikit_test" <<<"$RESULT_PASSED_NAMES"; then'

hits=$(grep -cF -- "$PREDICATE" "$GATE")
if [ "$hits" -ne 1 ]; then
    echo "⛔ 要变异的那条判据在闸门里出现 ${hits} 次（应为 1 次）——锚点不唯一，拒绝变异" >&2
    exit 2
fi

echo "① 先跑没有变异的测试台（基线）"
BASE_LINE=$(bash "$HARNESS" | tail -1)
echo "   $BASE_LINE"
case "$BASE_LINE" in
    *"0 失败") ;;
    *) echo "⛔ 基线就不是全绿，变异结果无法解读——先把基线修绿" >&2; exit 3 ;;
esac

echo "② 把 G8 判据停掉（恒接受），再跑一次"
python3 - "$GATE" "$PREDICATE" "$MUTANT" <<'PY'
import sys
path, old, new = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    t = f.read()
assert t.count(old) == 1, f"锚点不唯一: {t.count(old)}"
with open(path, "w", encoding="utf-8") as f:
    f.write(t.replace(old, new))
with open(path, encoding="utf-8") as f:
    assert new in f.read(), "变异没落盘"
PY
MUTATED=1
if ! grep -qF -- "$MUTANT" "$GATE"; then
    echo "⛔ 变异没改上——⛔ 此时读到的任何测试结果都不可当判别力证据" >&2
    exit 4
fi
MUT_LINE=$(bash "$HARNESS" | tail -1)
echo "   $MUT_LINE"

# ⚠️ 只撤信号处理器，**保留 EXIT**：EXIT 那条还负责删锁目录。
# 2026-10-12 实测过一次教训：原先写 `trap - EXIT INT TERM HUP`，
# 正常跑完锁目录就残留下来，下一次运行会被自己上一次的锁挡住（退出码 2）。
# cleanup 现在是幂等的（RESTORED 标志），留着 EXIT 不会重复还原。
restore; trap - INT TERM HUP

echo "③ 还原后再跑一次，必须回到基线"
AFTER_LINE=$(bash "$HARNESS" | tail -1)
echo "   $AFTER_LINE"

echo
# 变异那次必须真的产出了末行。空值会让下面的 case 匹配不上 "0 失败" 而**误判为通过** ——
# 「没有输出」不是「有失败」，⛔ 不许把前者当后者。
if [ -z "${MUT_LINE}" ] || [ -z "${AFTER_LINE}" ]; then
    echo "⛔ 测试台没有产出末行（变异那次:『${MUT_LINE}』，还原那次:『${AFTER_LINE}』）—— 结论无法成立" >&2
    exit 7
fi
case "$MUT_LINE" in
    *"0 失败")
        echo "⛔ 判别力为零：把 G8 判据停掉之后测试台照样全绿 —— 那些测试没在看 G8" >&2
        exit 5 ;;
esac
if [ "$AFTER_LINE" != "$BASE_LINE" ]; then
    echo "⛔ 还原后与基线不一致（基线『${BASE_LINE}』，现在『${AFTER_LINE}』）" >&2
    echo "   这意味着 $GATE 可能没被正确还原。" >&2
    echo "   请跑： git diff $GATE   确认它与提交状态一致；不一致就按上面的提示还原。" >&2
    exit 6
fi
echo "✅ 有判别力：停掉 G8 判据后测试台变红，还原后回到『${BASE_LINE}』"

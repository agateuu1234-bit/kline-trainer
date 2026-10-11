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
# 用法: bash .github/scripts/catalyst-gate-judgment-check.sh
# 退出码: 0 = 有判别力（变异后有失败、且还原后回到全绿）；非 0 = 有问题，看输出
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$DIR/catalyst-gate.sh"
HARNESS="$DIR/catalyst-gate.test.sh"
BACKUP="$(mktemp "${TMPDIR:-/tmp}/catalyst-gate-judgment.XXXXXX")"

cp "$GATE" "$BACKUP"

# 测试台会在 .github/scripts/ 下建临时夹具目录（按自己的进程号命名），正常跑完会自己删；
# 但**被打断时会留下来**，用户跑完验收会在仓库里看到看不懂的目录。
# 这里只清理「本次运行期间新出现的」那些 —— 先记下开跑前已有的，⛔ 不碰别人的
# （同一目录下可能有并发的测试台在跑）。
FIXTURES_BEFORE="$(mktemp "${TMPDIR:-/tmp}/catalyst-gate-fixtures.XXXXXX")"
ls -d "$DIR"/.uikit-*fixture-* 2>/dev/null | sort >"$FIXTURES_BEFORE" || true

clean_new_fixtures() {
    [ -f "$FIXTURES_BEFORE" ] || return 0
    local now; now="$(ls -d "$DIR"/.uikit-*fixture-* 2>/dev/null | sort)"
    local leftover
    leftover="$(comm -13 "$FIXTURES_BEFORE" <(printf '%s\n' "$now"))"
    if [ -n "$leftover" ]; then
        printf '%s\n' "$leftover" | while IFS= read -r d; do
            [ -n "$d" ] && rm -rf "$d"
        done
        echo "[清理] 已删除本次运行遗留的测试台临时夹具目录"
    fi
    rm -f "$FIXTURES_BEFORE"
}
# 幂等：备份已经用掉就什么都不做。⛔ 不许在这里报「还原失败」——
# 2026-10-09 实测：中断时 trap 还原过一次，后面那句显式 restore 又跑了一遍，
# 结果打出一条指向已删除文件的「⛔ 还原失败！请手动执行…」，骇人且是假的。
restore() {
    [ -f "$BACKUP" ] || return 0
    if ! cp "$BACKUP" "$GATE" || ! cmp -s "$BACKUP" "$GATE"; then
        echo "[还原] ⛔ 还原失败！请手动执行： cp '$BACKUP' '$GATE'" >&2
        return 1
    fi
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
    exit 130
}
trap cleanup EXIT
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
if ! grep -qF -- "$MUTANT" "$GATE"; then
    echo "⛔ 变异没改上——⛔ 此时读到的任何测试结果都不可当判别力证据" >&2
    exit 4
fi
MUT_LINE=$(bash "$HARNESS" | tail -1)
echo "   $MUT_LINE"

restore; trap - EXIT INT TERM HUP

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
    exit 6
fi
echo "✅ 有判别力：停掉 G8 判据后测试台变红，还原后回到『${BASE_LINE}』"

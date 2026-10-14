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

# 从测试台末行「结果：N 通过，M 失败」里取出 M。取不到就什么都不输出，调用方 fail-closed。
#
# ⚠️ 为什么不能用 `case "$line" in *"0 失败")`（2026-10-14 实测踩到）：
#    那是**对数字做后缀匹配** —— 「1**0 失败**」「2**0 失败**」「10**0 失败**」
#    统统以「0 失败」结尾，全被判成「全绿」。
#    我撞到的现场：变异杀掉 10 档（真的有判别力），脚本却报「判别力为零」。
#    更危险的是基线那处：方向相反，basement 有 10 个失败会被判成全绿而**继续往下跑**，
#    整个结论建立在一个坏基线上（fail-open）。两处同根，必须一起改成数值比较。
fail_count() {  # fail_count <测试台末行> → 失败数（取不到则无输出）
    printf '%s\n' "${1:-}" | grep -oE '[0-9]+ 失败' | grep -oE '[0-9]+' | tail -1
}
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

# ⚠️ 这里**刻意不清理测试台的临时产物**（2026-10-14 codex 评审 medium）：
#    此前的做法是「记下开跑前的隐藏条目、跑完把新出现的 rm -rf」——
#    那是从**创建时间 + 以点开头**推断归属，不是归属：
#    并发跑的另一个测试台、或编辑器在这几分钟里新建的隐藏文件，都会被误删
#    （锁只挡其它判别力自检，挡不住普通测试台）。
#    改成**谁造的谁清**：测试台自己带 trap，按它自己的进程号 `-$$` 精确清理
#    （见 catalyst-gate.test.sh 顶部的 cleanup_own_artifacts）。
#    ⛔ 不要在这里重新加"顺手清一下"的逻辑。
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
        # ⚠️ `grep -c` 找不到时**既打印 0 又退出 1** ⇒ 写 `|| echo 0` 会得到 "0\n0"，
        #    下面的 `[ "$n" -eq 1 ]` 会报语法错（非阻断⑧，2026-10-13 评审指出）。
        n=$(grep -cF -- "$MUTANT" "$GATE" 2>/dev/null || true)
        n=${n:-0}
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

cleanup() { restore; }
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
BASE_FAILS=$(fail_count "$BASE_LINE")
if [ -z "$BASE_FAILS" ]; then
    echo "⛔ 读不出基线的失败数（末行:『${BASE_LINE}』）—— 结论无法成立" >&2
    exit 3
fi
if [ "$BASE_FAILS" -ne 0 ]; then
    echo "⛔ 基线就不是全绿（${BASE_FAILS} 个失败），变异结果无法解读——先把基线修绿" >&2
    exit 3
fi

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
MUT_FAILS=$(fail_count "$MUT_LINE")
if [ -z "$MUT_FAILS" ]; then
    echo "⛔ 读不出变异那次的失败数（末行:『${MUT_LINE}』）—— 结论无法成立" >&2
    exit 7
fi
if [ "$MUT_FAILS" -eq 0 ]; then
    echo "⛔ 判别力为零：把 G8 判据停掉之后测试台照样全绿 —— 那些测试没在看 G8" >&2
    exit 5
fi
if [ "$AFTER_LINE" != "$BASE_LINE" ]; then
    echo "⛔ 还原后与基线不一致（基线『${BASE_LINE}』，现在『${AFTER_LINE}』）" >&2
    echo "   这意味着 $GATE 可能没被正确还原。" >&2
    echo "   请跑： git diff $GATE   确认它与提交状态一致；不一致就按上面的提示还原。" >&2
    exit 6
fi
echo "✅ 有判别力：停掉 G8 判据后测试台变红，还原后回到『${BASE_LINE}』"

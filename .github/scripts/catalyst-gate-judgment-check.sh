#!/usr/bin/env bash
# 证明「闸门的测试台真能抓错」，而不是一套永远绿的摆设。
#
# 做法（变异测试）：把闸门里 G8 那条判据**故意停掉**（改成恒接受），再跑一次测试台。
#   · 如果测试台变红 → 那些测试确实在看 G8，有判别力。
#   · 如果测试台照样全绿 → 它们是摆设，这比没有测试更糟（会给人虚假的安心）。
#
# ⭐ 关键设计（2026-10-14 塌层重写）：**本脚本从不改动真闸门**。
#    它把 .github/scripts 整树拷到一个临时目录（仅 644K），只在**拷贝**上做变异。
#
#    为什么要塌这一层，而不是继续给「就地改真文件」打补丁：
#    同一个机制连续两轮被评审挖出缺陷，根因都是「它会写真文件」——
#      第 1 轮：备份被外力删掉 ⇒ 闸门留在恒接受；并发两份会互相毁备份；
#               而且清理逻辑按「新出现的隐藏条目」猜归属，会误删别人的文件。
#      第 2 轮（codex，已复现）：`MUTATED=1` 在子进程写盘**之后**才赋值 ⇒
#               信号落在那几行窗口里，还原会被跳过，闸门留在恒接受、锁还被删掉。
#    ⇒ 本仓 feedback_defect_class_climbing_the_call_stack：同类缺陷反复出现
#      就是方案选错，解法是**塌层**而不是继续缩小窗口。
#    不碰真文件之后，下面这些整类消失：备份／还原／反向替换兜底／进程锁／
#    MUTATED/RESTORED 标志／信号竞态。⛔ 不要把它们加回来。
#
# 用法: bash .github/scripts/catalyst-gate-judgment-check.sh
# 退出码: 0 = 有判别力
#         2 = 前置条件不成立（建不出临时树 / 拷贝不完整 / 锚点不唯一）
#         3 = 拷贝树的基线不是全绿（结论无法转移到真树）
#         5 = 判别力为零（变异后测试台照样全绿）
#         6 = 还原后与基线不一致（拷贝树内部不自洽）
#         7 = 测试台没产出末行
#         8 = 真闸门被动过（本脚本不该写它 —— 这条是兜底自检）
#       130 = 被中断（不产出任何结论）
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
GATE_REAL="$DIR/catalyst-gate.sh"

# 真闸门的开跑前指纹。结尾会再算一次 —— 本脚本不写它，所以必须逐字相同。
REAL_FINGERPRINT_BEFORE="$(shasum -a 256 "$GATE_REAL" | awk '{print $1}')"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/catalyst-judgment.XXXXXX")" || {
    echo "⛔ 建不出临时目录（TMPDIR 不可写？）" >&2
    exit 2
}
# 只删自己 mktemp 出来的那一个目录 —— 严格归属，⛔ 不按前缀/时间猜。
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'echo >&2; echo "[中断] 收到中断信号，退出（本次不产出任何结论；真闸门从未被改动）" >&2; cleanup; exit 130' INT TERM HUP

mkdir -p "$WORK/.github"
cp -R "$DIR" "$WORK/.github/scripts" || { echo "⛔ 拷贝 .github/scripts 失败" >&2; exit 2; }
ln -s "$REPO/ios" "$WORK/ios" || { echo "⛔ 建 ios 符号链接失败" >&2; exit 2; }

# `cp -R` 会把源文件权限一起拷过来。若真闸门是只读的（有人 chmod 444 过），
# 拷贝也会是只读的，变异写入就会 PermissionError ⇒ 本脚本虽然 fail-closed、
# 但报的是「变异没改上」这种容易误导的理由。拷完显式给自己这份加写权限。
# （2026-10-14 用「把真闸门设为只读」这个确定性实验发现 —— 那次实验的
#  PermissionError 路径指向**拷贝**，顺带证明了本脚本的写操作从不指向真闸门。）
chmod -R u+w "$WORK/.github/scripts" 2>/dev/null || true

GATE="$WORK/.github/scripts/catalyst-gate.sh"
HARNESS="$WORK/.github/scripts/catalyst-gate.test.sh"
[ -f "$GATE" ] && [ -f "$HARNESS" ] || { echo "⛔ 拷贝树不完整" >&2; exit 2; }

# 从测试台末行「结果：N 通过，M 失败」里取出 M。取不到就什么都不输出，调用方 fail-closed。
#
# ⚠️ 为什么不能对数字做后缀匹配（2026-10-14 实测踩到）：
#    用通配符判「全绿」时，「1 后面跟 0 失败」「2 后面跟 0 失败」「10 后面跟 0 失败」
#    统统以同样的字样结尾，会被全判成全绿。
#    我撞到的现场：变异杀掉 10 档（真的有判别力），脚本却报「判别力为零」。
#    更危险的是基线那处：方向相反，基线有 10 个失败会被判成全绿而**继续往下跑**。
fail_count() {  # fail_count <测试台末行> → 失败数（取不到则无输出）
    printf '%s\n' "${1:-}" | grep -oE '[0-9]+ 失败' | grep -oE '[0-9]+' | tail -1
}

PREDICATE='if ! grep -qxF -- "$uikit_test" <<<"$RESULT_PASSED_NAMES"; then'
MUTANT='if false && ! grep -qxF -- "$uikit_test" <<<"$RESULT_PASSED_NAMES"; then'

hits=$(grep -cF -- "$PREDICATE" "$GATE" 2>/dev/null || true)
hits=${hits:-0}
if [ "$hits" -ne 1 ]; then
    echo "⛔ 要变异的那条判据在闸门里出现 ${hits} 次（应为 1 次）——锚点不唯一，拒绝变异" >&2
    exit 2
fi

echo "① 先在隔离拷贝上跑没有变异的测试台（基线）"
BASE_LINE=$(bash "$HARNESS" | tail -1)
echo "   ${BASE_LINE}"
BASE_FAILS=$(fail_count "$BASE_LINE")
if [ -z "$BASE_FAILS" ]; then
    echo "⛔ 读不出基线的失败数（末行:『${BASE_LINE}』）—— 结论无法成立" >&2
    exit 3
fi
# 拷贝树基线必须全绿。这同时是「拷贝是否忠实」的判据：
# 若 ios 符号链接或任何文件没拷对，测试台里那条「活基线与源码推导一致」会先红。
if [ "$BASE_FAILS" -ne 0 ]; then
    echo "⛔ 拷贝树的基线不是全绿（${BASE_FAILS} 个失败）—— 拷贝可能不忠实，结论无法转移到真树" >&2
    exit 3
fi

echo "② 在拷贝上把 G8 判据停掉（恒接受），再跑一次"
python3 - "$GATE" "$PREDICATE" "$MUTANT" <<'PY'
import sys
path, old, new = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    body = f.read()
assert body.count(old) == 1, f"锚点不唯一: {body.count(old)}"
with open(path, "w", encoding="utf-8") as f:
    f.write(body.replace(old, new))
with open(path, encoding="utf-8") as f:
    assert new in f.read(), "变异没落盘"
PY
if [ $? -ne 0 ] || ! grep -qF -- "$MUTANT" "$GATE"; then
    echo "⛔ 变异没改上——⛔ 此时读到的任何测试结果都不可当判别力证据" >&2
    exit 2
fi
MUT_LINE=$(bash "$HARNESS" | tail -1)
echo "   ${MUT_LINE}"

echo "③ 把拷贝改回原样，再跑一次，必须回到基线"
cp "$DIR/catalyst-gate.sh" "$GATE" || { echo "⛔ 拷贝树内还原失败" >&2; exit 6; }
AFTER_LINE=$(bash "$HARNESS" | tail -1)
echo "   ${AFTER_LINE}"

echo
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
if [ "${AFTER_LINE}" != "${BASE_LINE}" ]; then
    echo "⛔ 还原后与基线不一致（基线『${BASE_LINE}』，现在『${AFTER_LINE}』）—— 拷贝树内部不自洽" >&2
    exit 6
fi

# 兜底自检：本脚本不该写真闸门，所以它必须逐字未变。
REAL_FINGERPRINT_AFTER="$(shasum -a 256 "$GATE_REAL" | awk '{print $1}')"
if [ "$REAL_FINGERPRINT_BEFORE" != "$REAL_FINGERPRINT_AFTER" ]; then
    echo "⛔ 真闸门 $GATE_REAL 在本次运行中被改动了 —— 本脚本不该写它，请查 git diff" >&2
    exit 8
fi

echo "✅ 有判别力：停掉 G8 判据后测试台变红（${MUT_FAILS} 个失败），还原后回到『${BASE_LINE}』"
echo "   （全程在隔离拷贝上进行，真闸门指纹未变：${REAL_FINGERPRINT_AFTER:0:12}…）"

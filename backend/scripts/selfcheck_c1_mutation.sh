#!/usr/bin/env bash
# 验收项 9c：证明 verify_pilot_two_phase_create.py **不是空跑的**。
#
# 做法：临时把 C1 的修复「中和」回终审判 Critical 的那一版
# （schema.sql + 指纹两键 + state='ready' 塞进**同一个**事务），跑一遍验证脚本，
# 然后**无条件复原**。第 ④ 档必须 FAIL —— 若它照样 PASS，说明那个脚本证明不了任何东西。
#
# 用法（**在仓库根目录**执行，不要在 backend/）：
#     bash backend/scripts/selfcheck_c1_mutation.sh
#
# 前置：Docker 可用；本脚本自己起停 PG 容器。
#
# ⚠️ 若本脚本被 `kill -9`（trap 不触发），源码会停在**中和态**、容器会留着。恢复：
#     git checkout backend/qmt_pilot_db.py && docker rm -f qmt4a_selfcheck
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
SRC="backend/qmt_pilot_db.py"
BAK="$(mktemp)" || { echo "❌ mktemp 失败" >&2; exit 2; }
CONTAINER="qmt4a_selfcheck"
# ⚠️ 在 git worktree 里 `git rev-parse --show-toplevel` 返回的是 **worktree 根**，
#    不是主仓 —— venv 通常只在主仓。故逐个候选试，取第一个可执行的。
if [ -z "${PYBIN:-}" ]; then
  for _cand in \
      "$(git rev-parse --show-toplevel)/.venv/bin/python" \
      "$(git rev-parse --git-common-dir | sed 's#/\.git$##')/.venv/bin/python" \
      "$(git rev-parse --show-toplevel)/../../../.venv/bin/python"; do
    [ -x "$_cand" ] && { PYBIN="$_cand"; break; }
  done
fi
if [ -z "${PYBIN:-}" ] || [ ! -x "$PYBIN" ]; then
  echo "❌ 找不到装了 asyncpg 的 python。请显式指定：PYBIN=/path/to/.venv/bin/python bash $0" >&2
  exit 2
fi
echo "PYBIN=$PYBIN"

echo "branch=$(git branch --show-current)  HEAD=$(git rev-parse --short HEAD)"
if [ -n "$(git status --porcelain "$SRC")" ]; then
  echo "❌ $SRC 有未提交改动 —— 请先提交或 stash，否则复原会覆盖你的改动" >&2
  exit 2
fi

cleanup() {
  cp "$BAK" "$SRC" && rm -f "$BAK"
  docker rm -f "$CONTAINER" >/dev/null 2>&1
  if [ -z "$(git status --porcelain "$SRC")" ]; then
    echo "复原完成，git status 干净"
  else
    echo "❌ 复原后 $SRC 仍有差异 —— 请手工 git checkout $SRC" >&2
  fi
}
cp "$SRC" "$BAK" || { echo "❌ 备份源码失败" >&2; exit 2; }
trap cleanup EXIT   # ⚠️ 必须装在备份**之后**：装在之前时，这一瞬 Ctrl-C 会让 cleanup
                    #    拿一个**空的** mktemp 文件覆盖源码（O4-W4 M-7）

docker rm -f "$CONTAINER" >/dev/null 2>&1
docker run --rm -d --name "$CONTAINER" -e POSTGRES_PASSWORD=postgres \
  -p 55432:5432 postgres:15.12 >/dev/null || { echo "❌ 起容器失败" >&2; exit 3; }
for _ in $(seq 1 30); do
  docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done

# ── 中和：把三者塞回同一个事务 + 摘掉 schema 侧守卫 ────────────────────
"$PYBIN" - <<'PY' || { echo "❌ 中和失败（锚点可能已变，请核对源码）" >&2; exit 4; }
import pathlib
p = pathlib.Path("backend/qmt_pilot_db.py")
s = p.read_text()
anchor = "        await target.execute(schema_sql)\n"
assert s.count(anchor) == 1, f"锚点命中 {s.count(anchor)} 次"
i = s.index(anchor)
j = s.index("await target.execute(_SET_READY_SQL)")
s = s[:i] + """        async with target.transaction():
            await target.execute(schema_sql)
            for key in PILOT_META_PHASE2_KEYS:
                await target.execute(_INSERT_META_SQL, key, values[key])
            await target.execute(_SET_READY_SQL)
""" + s[s.index("\n", j) + 1:]
guard = "    if not _is_wrapped_in_transaction(schema_sql):"
assert s.count(guard) == 1, "守卫锚点没命中"
s = s.replace(guard, "    if False:", 1)
p.write_text(s)
print("已中和 C1 的修复（＝终审判 Critical 的那一版）")
PY

echo
echo "════ 跑验证脚本（期望：第 ④ 档 FAIL）════"
OUT=$(DSN='postgresql://postgres:postgres@localhost:55432/postgres' \
  "$PYBIN" backend/scripts/verify_pilot_two_phase_create.py 2>&1)
RC=$?
printf '%s\n' "$OUT"
echo "验证脚本退出码 = ${RC}"
echo

# ⚠️ **判绿必须读输出内容，不能只看退出码**（O4-W4 I-2）：任何非零退出都会让
#    「只看 RC」的版本打出 ✅ —— 包括 asyncpg 没装（ModuleNotFoundError）、
#    容器 30 秒没起来（连接被拒）、中和产出语法错（SyntaxError）。
#    那些情形下输出里连「④」两个字都没有，却会被判成「9c 通过」。
#    这与同一张验收表上一行 9b 自己写的「判绿读输出内容」直接打架。
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "FAIL.*已随阶段 2 事务回滚"; then
  echo "✅ 9c 通过：中和之后第 ④ 档确实打出了具名 FAIL（退出码 ${RC}）—— 它不是空跑的"
elif [ "$RC" -eq 0 ]; then
  echo "❌ 9c 失败：中和之后验证脚本**照样 PASS** —— 它证明不了 C1 是否修好，必须停下修脚本" >&2
  exit 1
else
  echo "❌ 9c 无效：脚本非零退出（${RC}），但输出里**没有第 ④ 档的具名 FAIL**" >&2
  echo "   → 多半不是判别力生效，而是环境问题（asyncpg 没装 / 容器没起来 / 中和产出语法错）" >&2
  exit 1
fi

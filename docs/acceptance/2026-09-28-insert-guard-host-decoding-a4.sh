#!/usr/bin/env bash
# A4：证明守卫「真的会报错」—— 故意删掉一处 schema_version，看它是否变红，然后改回去。
#
# ⛔⛔ 判别方式：**直接调 `_enforce` 并读 `AssertionError` 的消息**，
#     ⛔ 不 grep pytest 的整段输出 —— pytest 回溯会把守卫**源码里**的
#     `列清单=` 一起打印出来，于是「守卫被弄成恒绿」时 grep 照样命中 ⇒ 橡皮图章。
#     （本仓成文教训：分类器只读结论，不读整段输出。这一条是实测打回后重写的。）
#
# ⛔ 安全设计：
#   · 改动前把原文件备份到临时目录；用 trap 保证无论如何退出都还原；
#   · 收尾用 git 复核工作树是否干净；
#   · ⛔ 不使用 `git checkout <file>` 还原（会连带毁掉未提交的改动）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="$(cd "${HERE}/../.." && pwd)"
PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"
BAK="$(mktemp -d)"

cd "${WT}" || { echo "❌ 进不去 ${WT}"; exit 1; }

if ! git diff --quiet -- .; then
  echo "⚠️ 开工前工作树就不干净，先处理干净再跑这条（避免把你的改动搞混）："
  git status --porcelain
  exit 1
fi

TOUCHED=()
restore() {
  for rel in "${TOUCHED[@]:-}"; do
    [ -n "${rel}" ] && [ -f "${BAK}/$(basename "${rel}")" ] \
      && cp "${BAK}/$(basename "${rel}")" "${WT}/${rel}"
  done
  rm -rf "${BAK}"
}
trap restore EXIT

export PYTHONDONTWRITEBYTECODE=1

# 判别器：直接调守卫的 `_enforce`，只看它抛出的消息里有没有指名这个文件。
verdict() {
  "${PY}" - "$1" <<'PYEOF'
import importlib.util, pathlib, sys

want = sys.argv[1]                       # 期望在报文里被指名的文件（相对路径片段）
here = pathlib.Path(__file__).resolve() if "__file__" in dir() else None
guard = pathlib.Path("backend/tests/test_insert_schema_version_guard.py").resolve()
spec = importlib.util.spec_from_file_location("g_a4", guard)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
try:
    m._enforce(m._iter_files(), m.REPO_ROOT)
except AssertionError as e:
    msg = str(e)
    if want in msg and ("列清单=" in msg or "缺" in msg):
        print("RED_NAMED")
    else:
        print("RED_OTHER")
        print(msg[:400])
except Exception as e:
    print(f"CRASH {type(e).__name__}: {e}")
else:
    print("GREEN")
PYEOF
}

probe() {
  local label="$1" rel="$2" old="$3" new="$4"
  cp "${WT}/${rel}" "${BAK}/$(basename "${rel}")"
  TOUCHED+=("${rel}")
  "${PY}" - "${WT}/${rel}" "${old}" "${new}" <<'PYEOF'
import sys, pathlib
p, old, new = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
t = p.read_text(encoding="utf-8")
if t.count(old) < 1:
    raise SystemExit(3)
p.write_text(t.replace(old, new, 1), encoding="utf-8")
PYEOF
  if [ $? -ne 0 ]; then
    echo "❌ 锚点找不到（${label}）—— 文件内容和脚本预期不一致，这条没验成"
    cp "${BAK}/$(basename "${rel}")" "${WT}/${rel}"
    return 1
  fi
  local out
  out="$(verdict "${rel##*/}")"
  cp "${BAK}/$(basename "${rel}")" "${WT}/${rel}"
  case "${out}" in
    RED_NAMED*) echo "变红了 ✅  —— ${label}（守卫点名了这个文件并说缺字段）" ;;
    RED_OTHER*) echo "⛔ 红的理由不对 —— ${label}：守卫红了，但报文没点名这个文件。下面是报文：
${out#RED_OTHER}" ;;
    GREEN*)     echo "⛔ 没变红 —— ${label}：守卫漏掉了一处真缺陷" ;;
    *)          echo "⛔ 判别器自己崩了 —— ${label}：${out}" ;;
  esac
}

# 基线：不注入时必须是绿的（否则后面的红说明不了任何事）
BASE="$(verdict "绝不会出现的字样")"
case "${BASE}" in
  GREEN*) echo "基线（未注入）：守卫是绿的 ✅" ;;
  *)      echo "⛔ 基线就不是绿的，后面的结果说明不了任何事：${BASE}"; exit 1 ;;
esac
echo

probe "迁移排练脚本 rehearse.sh" \
  "backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh" \
  "stock_code, stock_name, start_datetime, end_datetime, schema_version," \
  "stock_code, stock_name, start_datetime, end_datetime,"

probe "CI 冒烟检查 schema-smoke.yml" \
  ".github/workflows/schema-smoke.yml" \
  "INSERT INTO training_sets(stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash) VALUES ('TEST'" \
  "INSERT INTO training_sets(stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash) VALUES ('TEST'"

if git diff --quiet -- .; then
  echo
  echo "收尾复核：文件已全部还原 ✅"
else
  echo
  echo "❌❌ 收尾复核失败 —— 有文件没还原！清单如下，请手动还原："
  git status --porcelain
  exit 1
fi

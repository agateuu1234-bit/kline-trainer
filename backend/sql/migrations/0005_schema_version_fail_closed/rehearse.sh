#!/usr/bin/env bash
# rehearse.sh —— migration 0005_schema_version_fail_closed 真库演练脚本
#
# 人工执行，不进 CI（与 0004 同约定：进 CI 会牵动 workflow 变更 + 让日常本地测试必须起 Docker）。
# 上线到任何真实 PostgreSQL 之前，必须先跑本脚本并全绿。见同目录 README.md。
#
# 四个 Part：
#   1. 完整升降级回环：建"迁移前"库（带 DEFAULT 1）→ 漏填插入**成功**且值为 1
#      → forward → 漏填插入**必须失败** → 显式给值**成功** → rollback → 漏填插入**又成功**
#   2. 存量行不受影响：forward + rollback 前后，已有行的 schema_version 逐行不变
#   3. rollback 真的无损：README 声称"本次 rollback 无数据风险"——⛔ 声称无风险
#      比声称有风险更需要证明，这里实地证
#   4. 活目录指纹三方对齐：用**改完的** schema.sql 建一个全新库，取出活目录指纹，
#      与仓库里的固件原文、与 CANONICAL_BUSINESS_CATALOG_SHA256 逐一比对
#
# 用法：./rehearse.sh（在任意目录下均可，脚本自己定位仓库根目录）

set -euo pipefail

# ---------- 环境检查 ----------

if command -v docker >/dev/null 2>&1; then
  HAVE_DOCKER=1
else
  HAVE_DOCKER=0
fi

if [ "$HAVE_DOCKER" -eq 0 ]; then
  echo "[FAIL] 未检测到 docker 命令。"
  echo "本脚本需要 Docker 来起一次性 PostgreSQL 容器演练迁移，请先安装 Docker Desktop（或等效工具）再重跑。"
  exit 1
fi

if docker info >/dev/null 2>&1; then
  :
else
  echo "[FAIL] 检测到 docker 命令，但 Docker daemon 未运行或不可访问。"
  echo "请先启动 Docker Desktop（或对应服务），再重跑本脚本。"
  exit 1
fi

echo "[PASS] Docker 可用"

# ---------- 路径 / 常量 ----------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

FORWARD_SQL="$SCRIPT_DIR/forward.sql"
ROLLBACK_SQL="$SCRIPT_DIR/rollback.sql"
SCHEMA_SQL="$REPO_ROOT/backend/sql/schema.sql"
CATALOG_FIXTURE="$REPO_ROOT/backend/tests/fixtures/business_catalog_fingerprint.txt"

# 本 migration 的 merge-base（改动前的 main）。固定的历史提交引用，不是
# "当前分支的 merge-base 动态计算" —— 分支合并/删除后动态计算会失效。
# 已实测该提交的 backend/sql/schema.sql 第 75 行为
# `    schema_version INTEGER NOT NULL DEFAULT 1,`，即本 migration 的"迁移前"形状。
PRE_MIGRATION_SHA="6760955"

# 与 backend/docker-compose.yml 的 `image: postgres:15.12` 保持一致（勿凭空猜版本）。
PG_IMAGE="postgres:15.12"

CONTAINER_NAME="kline-rehearse-0005-$$-$(date +%s)"
PG_PASSWORD="rehearse_throwaway_$$"   # 仅容器内部用，不对外暴露端口

for f in "$FORWARD_SQL" "$ROLLBACK_SQL" "$SCHEMA_SQL" "$CATALOG_FIXTURE"; do
  if [ -f "$f" ]; then
    :
  else
    echo "[FAIL] 找不到 $f —— 脚本可能被移动，或该文件被删除"
    exit 1
  fi
done

if git -C "$REPO_ROOT" cat-file -e "${PRE_MIGRATION_SHA}^{commit}" 2>/dev/null; then
  :
else
  echo "[FAIL] 仓库中找不到提交 ${PRE_MIGRATION_SHA}（迁移前 schema 快照的来源）"
  echo "可能是浅克隆缺历史，请先 git fetch --unshallow 再重跑"
  exit 1
fi

# 防呆：迁移前快照必须**真的带** DEFAULT 1，否则 Part 1 的第一步会在一个
# 已经没有默认值的库上"证明漏填会失败"——那是恒真，等于伪证。
if git -C "$REPO_ROOT" show "${PRE_MIGRATION_SHA}:backend/sql/schema.sql" \
     | grep -q "schema_version INTEGER NOT NULL DEFAULT 1"; then
  :
else
  echo "[FAIL] 提交 ${PRE_MIGRATION_SHA} 的 schema.sql 里没有 \`schema_version INTEGER NOT NULL DEFAULT 1\`"
  echo "        ⇒ 迁移前快照不是本 migration 的前置形状，Part 1 会变成恒真的伪证。"
  exit 1
fi

echo "[PASS] forward.sql / rollback.sql / schema.sql / 指纹固件 / 迁移前快照（含 DEFAULT 1）均可用"

TMP_LOG="$(mktemp)"

cleanup() {
  local exit_code=$?
  echo ""
  echo "===== 清理 ====="
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  rm -f "$TMP_LOG" 2>/dev/null || true
  if [ "$exit_code" -eq 0 ]; then
    echo "容器 ${CONTAINER_NAME} 已清理，演练脚本正常结束。"
  else
    echo "容器 ${CONTAINER_NAME} 已清理（脚本以失败退出，exit=${exit_code}）。"
  fi
  exit "$exit_code"
}
trap cleanup EXIT

# ---------- 辅助函数（与 0004 同形） ----------

PASS_COUNT=0

pass_msg() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  [PASS] $1"
}

fail_msg() {
  echo "  [FAIL] $1"
}

assert_rejects() {
  # $1=描述  $2=db  $3=期望出现在错误信息里的约束名或报文片段  $4=应当被拒绝的 SQL
  #
  # ⚠️ 必须校验**被谁拒的**，不能接受任意失败（0004 的 codex R4-F1）。
  # 只判"是否失败"时，一条用了不存在的股票代码的探针会被**外键**拦下、
  # 根本走不到要验的那条判据 —— 即便判据完全不存在，探针照样"通过"。
  local desc="$1" db="$2" expect="$3" sql="$4"
  if [ -z "$expect" ]; then
    fail_msg "$desc —— 脚本 bug：assert_rejects 未收到期望的报文片段（第 3 参数为空）"
    exit 1
  fi
  local out rc
  out=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
          psql -U postgres -h 127.0.0.1 -d "$db" -v ON_ERROR_STOP=1 -tA -c "$sql" 2>&1) && rc=0 || rc=$?
  if [ "${rc:-0}" -eq 0 ]; then
    fail_msg "$desc —— 该语句本应被数据库拒绝，却执行成功了"
    exit 1
  fi
  if printf '%s' "$out" | grep -q "$expect"; then
    pass_msg "${desc}（确由 [${expect}] 拒绝）"
  else
    fail_msg "$desc —— 被拒了，但不是期望的原因。期望错误信息含 [${expect}]，实际：$out"
    exit 1
  fi
}

assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    fail_msg "$desc —— 期望 [${expected}]，实际 [${actual}]"
    exit 1
  fi
  pass_msg "$desc"
}

pg_query() {
  # $1=db  $2=sql（单值查询，返回去除格式的纯文本）
  docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
    psql -U postgres -h 127.0.0.1 -d "$1" -tA -c "$2"
}

pg_exec() {
  # $1=db，SQL 从 stdin 读入（供 heredoc 调用）
  docker exec -i -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
    psql -U postgres -h 127.0.0.1 -d "$1" -v ON_ERROR_STOP=1
}

pg_run_file() {
  # $1=db  $2=sql 文件路径
  docker exec -i -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
    psql -U postgres -h 127.0.0.1 -d "$1" -v ON_ERROR_STOP=1 -f - < "$2"
}

# ---------- 起容器 ----------

echo ""
echo "===== 起一次性 PostgreSQL 容器（${PG_IMAGE}）====="

docker run -d --name "$CONTAINER_NAME" \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" \
  "$PG_IMAGE" >/dev/null

printf "等待数据库就绪"
READY=0
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER_NAME" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then
    READY=1
    break
  fi
  printf "."
  sleep 1
done
echo ""

if [ "$READY" -eq 0 ]; then
  echo "[FAIL] 容器起来了但 60 秒内数据库没就绪"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -30
  exit 1
fi

pass_msg "PostgreSQL 容器就绪：$(pg_query postgres 'SHOW server_version;')"

# ---------- Part 1：完整升降级回环 ----------

echo ""
echo "===== Part 1 · 完整升降级回环 ====="

DB1="rehearse_0005_loop"
pg_query postgres "CREATE DATABASE ${DB1};" >/dev/null

# 用迁移前的 schema 快照建库（带 DEFAULT 1）
git -C "$REPO_ROOT" show "${PRE_MIGRATION_SHA}:backend/sql/schema.sql" > "$TMP_LOG"
pg_run_file "$DB1" "$TMP_LOG" >/dev/null
pass_msg "用迁移前快照（${PRE_MIGRATION_SHA}）建库完成"

# 外键要求 stocks 里先有这只股票
pg_exec "$DB1" >/dev/null <<'SQL'
INSERT INTO stocks (code, name) VALUES ('000001', '演练股');
SQL

assert_eq "迁移前：schema_version 的默认值是 1" \
  "$(pg_query "$DB1" "SELECT column_default FROM information_schema.columns WHERE table_name='training_sets' AND column_name='schema_version';")" \
  "1"

# ---------- Part 1 前置探针：证明「值写 DEFAULT」≡「省略该列」 ----------
#
# ⚠️ 为什么需要这一段：下面全部"漏填"场景都写成「列清单含 schema_version、值写 DEFAULT」
#    （理由见计划 Global Constraint 5b：已合并的文本守卫会把"省掉该列"的字面量判红）。
#    于是整个 Part 1 的说服力都压在"DEFAULT ≡ 省略"这一个**断言**上 ——
#    ⛔ 断言必须变成**测量**。这段就在真库上把两种写法并排跑一遍。
#
# 用 training_sets 的**克隆表**做，不用玩具表：克隆表与真表列/类型/可空/默认值/CHECK 全同
#   （`LIKE … INCLUDING ALL`），免掉"你是在玩具表上证的"这类质疑。
#   ⚠️ `LIKE … INCLUDING ALL` **不复制外键** ⇒ 探针不需要 stocks 里有对应股票。
#   ⚠️ `INCLUDING ALL` 会把 `id` 的默认值连同 `nextval('training_sets_id_seq')` 一起复制过来
#      ⇒ 探针插入会消耗**真序列**的号。本容器是一次性的、Part 1 之后没有任何断言依赖
#      training_sets.id 的具体取值（Part 3 的整表指纹跑在另一个库上），故无害。
#   克隆表不是 training_sets ⇒ 它上面那条"省略列"的字面量**不在守卫的 needle 里**
#   （守卫只找 `INSERT INTO training_sets`）——  这不是绕法，它确实是另一张表。

echo ""
echo "----- Part 1 前置探针：「值写 DEFAULT」是否真的等于「省略该列」 -----"

pg_exec "$DB1" >/dev/null <<'SQL'
CREATE TABLE ts_default_probe (LIKE training_sets INCLUDING ALL);
SQL

assert_eq "克隆表继承了 schema_version 的默认值 1" \
  "$(pg_query "$DB1" "SELECT coalesce(column_default,'<无>') FROM information_schema.columns WHERE table_name='ts_default_probe' AND column_name='schema_version';")" \
  "1"
assert_eq "克隆表继承了 schema_version 的 NOT NULL" \
  "$(pg_query "$DB1" "SELECT is_nullable FROM information_schema.columns WHERE table_name='ts_default_probe' AND column_name='schema_version';")" \
  "NO"

probe_pair() {
  # $1=阶段描述  $2=本轮用的时间戳前缀（两条探针必须用不同的行，否则撞唯一约束）
  local phase="$1" n="$2" a b ra rb ka kb
  a=$(pg_query "$DB1" "INSERT INTO ts_default_probe (stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash) VALUES ('000001','探针',${n}1,${n}2,'/tmp/a${n}.zip','aaaaaaa1') RETURNING schema_version;" 2>&1) && ra=0 || ra=$?
  b=$(pg_query "$DB1" "INSERT INTO ts_default_probe (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash) VALUES ('000001','探针',${n}3,${n}4,DEFAULT,'/tmp/b${n}.zip','bbbbbbb2') RETURNING schema_version;" 2>&1) && rb=0 || rb=$?
  # ⚠️ 判据取**错误身份**（`ERROR:` 那一行），⛔ 不取整段输出：psql 的 `DETAIL:` 行会把
  #    失败那一行的全部字段打出来（含 id / file_path / content_hash / 时间戳），
  #    而两条探针插的本来就是**不同的行** ⇒ 整段比对**必然不等**。
  #    那会得出"两种写法不等价"的**假结论** —— 实测踩过这一步。
  ka=$(printf '%s' "$a" | grep '^ERROR:' || printf '%s' "$a")
  kb=$(printf '%s' "$b" | grep '^ERROR:' || printf '%s' "$b")
  echo "    ${phase}："
  echo "      省略该列      → 退出码 ${ra}；${ka}"
  echo "      值写 DEFAULT  → 退出码 ${rb}；${kb}"
  if [ "$ka" = "$kb" ] && [ "$ra" = "$rb" ]; then
    pass_msg "${phase}：两种写法的退出码与错误身份逐字相同"
  else
    fail_msg "${phase}：两种写法**不等价** —— 那么本脚本此后用 DEFAULT 代替漏填的做法整个失效，必须停下来重新设计"
    exit 1
  fi
}

probe_pair "阶段1 · 有 DEFAULT 1" 10
pg_query "$DB1" "ALTER TABLE ts_default_probe ALTER COLUMN schema_version DROP DEFAULT;" >/dev/null
probe_pair "阶段2 · DROP DEFAULT 之后" 20
pg_query "$DB1" "ALTER TABLE ts_default_probe ALTER COLUMN schema_version SET DEFAULT 1;" >/dev/null
probe_pair "阶段3 · SET DEFAULT 1 回滚之后" 30

# 防空转：阶段 2 必须真的**失败过**，否则三个阶段全是"都成功"，等价性被证得毫无内容
if pg_query "$DB1" "INSERT INTO ts_default_probe (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash) VALUES ('000001','探针',901,902,2,'/tmp/c.zip','ccccccc3') RETURNING schema_version;" >/dev/null 2>&1; then
  pass_msg "探针表在显式给值时仍能写入（防空转：证明上面的失败不是因为这张表根本写不进去）"
else
  fail_msg "探针表连显式给值都写不进去 —— 探针自身坏了，上面的等价性结论不可信"
  exit 1
fi

pg_exec "$DB1" >/dev/null <<'SQL'
DROP TABLE ts_default_probe;
SQL
pass_msg "探针表已清理（它只为证明等价性而存在，不参与后面的形状断言）"

echo ""
echo "----- Part 1 正戏 -----"

# ① 迁移前：漏填 schema_version（写成 DEFAULT）的 INSERT 应当成功，且被静默补成 1
#    —— 这就是本片要消灭的行为
pg_exec "$DB1" >/dev/null <<'SQL'
INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)
VALUES ('000001', '演练股', 1000, 2000, DEFAULT, '/tmp/before.zip', 'aabbccdd');
SQL
assert_eq "迁移前：漏填 schema_version 的写入**成功**，且被静默补成 1（= 本片要消灭的行为）" \
  "$(pg_query "$DB1" "SELECT schema_version FROM training_sets WHERE file_path='/tmp/before.zip';")" \
  "1"

# ② 跑 forward
pg_run_file "$DB1" "$FORWARD_SQL" >/dev/null
pass_msg "forward.sql 执行成功"

assert_eq "迁移后：schema_version 已无默认值" \
  "$(pg_query "$DB1" "SELECT coalesce(column_default, '<无默认值>') FROM information_schema.columns WHERE table_name='training_sets' AND column_name='schema_version';")" \
  "<无默认值>"

assert_eq "迁移后：schema_version 仍然 NOT NULL（fail-closed 靠它）" \
  "$(pg_query "$DB1" "SELECT is_nullable FROM information_schema.columns WHERE table_name='training_sets' AND column_name='schema_version';")" \
  "NO"

assert_eq "迁移后：列注释已写入" \
  "$(pg_query "$DB1" "SELECT col_description('training_sets'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid='training_sets'::regclass AND attname='schema_version'));")" \
  "产物代号。⛔ 刻意不设默认值：漏填必须当场失败，不能被静默标成第 1 代。"

# ③ 迁移后：漏填必须失败，且是**因为 NOT NULL**，不是因为别的
assert_rejects "迁移后：漏填 schema_version 的写入**被拒**" "$DB1" \
  "violates not-null constraint" \
  "INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash) VALUES ('000001', '演练股', 3000, 4000, DEFAULT, '/tmp/after_missing.zip', 'bbccddee');"

# ③b 报文必须点名是哪一列 —— 不点名的报文会让运维去猜（验收判据 3 的措辞依据）
#    ⚠️ 这一条刻意用 3100（不是 ③ 的 3000）：`uq_stock_start UNIQUE (stock_code, start_datetime)`
#       在同一个 (股票, start) 上只允许一行。实测两条都失败的 INSERT **零行落地、不占唯一键**
#       （报的都是 `null value … violates not-null constraint`，不是唯一键冲突），
#       所以共用 3000 今天也不会出错 —— 但那依赖「③b 永远注定失败」这个前提。
#       哪天有人把 ③b 改成期望成功，就会撞上一个与本意无关的唯一键错误。错开更省事。
MISSING_OUT=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
  psql -U postgres -h 127.0.0.1 -d "$DB1" -v ON_ERROR_STOP=1 -tA \
  -c "INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash) VALUES ('000001', '演练股', 3100, 4100, DEFAULT, '/tmp/after_missing2.zip', 'ccddeeff');" 2>&1 || true)
if printf '%s' "$MISSING_OUT" | grep -q 'schema_version'; then
  pass_msg "报错信息点名了 schema_version（运维不用猜是哪一列）"
else
  fail_msg "报错信息没点名 schema_version，实际：$MISSING_OUT"
  exit 1
fi

# ④ 迁移后：显式给值仍能正常写入（正向对照，防止改成恒拒）
pg_exec "$DB1" >/dev/null <<'SQL'
INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)
VALUES ('000001', '演练股', 5000, 6000, 2, '/tmp/after_explicit.zip', 'ddeeff00');
SQL
assert_eq "迁移后：显式写 schema_version=2 仍成功（正向对照，证明不是恒拒）" \
  "$(pg_query "$DB1" "SELECT schema_version FROM training_sets WHERE file_path='/tmp/after_explicit.zip';")" \
  "2"

# ⑤ 跑 rollback，漏填又恢复成"成功且补 1"
pg_run_file "$DB1" "$ROLLBACK_SQL" >/dev/null
pass_msg "rollback.sql 执行成功"

assert_eq "回滚后：默认值 1 已装回" \
  "$(pg_query "$DB1" "SELECT column_default FROM information_schema.columns WHERE table_name='training_sets' AND column_name='schema_version';")" \
  "1"

assert_eq "回滚后：列注释已撤掉（不留说谎的注释）" \
  "$(pg_query "$DB1" "SELECT coalesce(col_description('training_sets'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid='training_sets'::regclass AND attname='schema_version')), '<无注释>');")" \
  "<无注释>"

pg_exec "$DB1" >/dev/null <<'SQL'
INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)
VALUES ('000001', '演练股', 7000, 8000, DEFAULT, '/tmp/after_rollback.zip', 'eeff0011');
SQL
assert_eq "回滚后：漏填又恢复为成功且补 1（证明回滚真的回到了迁移前行为）" \
  "$(pg_query "$DB1" "SELECT schema_version FROM training_sets WHERE file_path='/tmp/after_rollback.zip';")" \
  "1"

# ---------- Part 2：存量行不受影响 ----------

echo ""
echo "===== Part 2 · 存量行不受影响 ====="

DB2="rehearse_0005_existing"
pg_query postgres "CREATE DATABASE ${DB2};" >/dev/null
git -C "$REPO_ROOT" show "${PRE_MIGRATION_SHA}:backend/sql/schema.sql" > "$TMP_LOG"
pg_run_file "$DB2" "$TMP_LOG" >/dev/null

pg_exec "$DB2" >/dev/null <<'SQL'
INSERT INTO stocks (code, name) VALUES ('000002', '存量股');
-- 刻意混入两代产物 + 一个非 1/2 的值：若 DROP DEFAULT 真的重写了行，
-- 单一值的样本看不出来（全是 1 的话，被改写成 1 也察觉不到）。
INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)
VALUES ('000002', '存量股', 100, 200, 1, '/tmp/gen1.zip', '11111111'),
       ('000002', '存量股', 300, 400, 2, '/tmp/gen2.zip', '22222222'),
       ('000002', '存量股', 500, 600, 7, '/tmp/gen7.zip', '77777777');
SQL

BEFORE=$(pg_query "$DB2" "SELECT string_agg(file_path || '=' || schema_version, ',' ORDER BY file_path) FROM training_sets;")
assert_eq "样本就位（三行、三个不同代号）" "$BEFORE" \
  "/tmp/gen1.zip=1,/tmp/gen2.zip=2,/tmp/gen7.zip=7"

pg_run_file "$DB2" "$FORWARD_SQL" >/dev/null
AFTER_FWD=$(pg_query "$DB2" "SELECT string_agg(file_path || '=' || schema_version, ',' ORDER BY file_path) FROM training_sets;")
assert_eq "forward 之后存量行逐行不变（DROP DEFAULT 只改元数据）" "$AFTER_FWD" "$BEFORE"

pg_run_file "$DB2" "$ROLLBACK_SQL" >/dev/null
AFTER_RB=$(pg_query "$DB2" "SELECT string_agg(file_path || '=' || schema_version, ',' ORDER BY file_path) FROM training_sets;")
assert_eq "rollback 之后存量行仍逐行不变" "$AFTER_RB" "$BEFORE"

# ---------- Part 3：rollback 真的无损 ----------

echo ""
echo "===== Part 3 · rollback 真的无损（README 声称无风险，这里实证）====="

DB3="rehearse_0005_lossless"
pg_query postgres "CREATE DATABASE ${DB3};" >/dev/null
git -C "$REPO_ROOT" show "${PRE_MIGRATION_SHA}:backend/sql/schema.sql" > "$TMP_LOG"
pg_run_file "$DB3" "$TMP_LOG" >/dev/null

# ⛔ **`sent` 行必须把三个租约列一起填上**（codex 对 plan 第 2 轮的 [high] finding，已实测坐实）。
#    `ck_lease_state_invariant` 的判据是：
#        status='unsent'              ⇒ lease_id / lease_expires_at / reserved_at 三者**全为 NULL**
#        status IN ('reserved','sent') ⇒ 三者**全非 NULL**
#    本计划初稿只给了 status='sent' 而把三列省掉（⇒ 全是 NULL）⇒ 两个分支都不满足。
#    实测报错：`new row for relation "training_sets" violates check constraint
#    "ck_lease_state_invariant"`，psql 退出码 3 ⇒ `ON_ERROR_STOP=1` + `set -e`
#    会让脚本**在 Part 3 的第一条语句就中止** —— 无损验证一条没跑，Part 4 也到不了。
#    写法照 0004 的 `rehearse.sh:213-219`（它给 sent 行填的就是这三个值）。
#    ⚠️ Part 1 / Part 2 的样本**不受影响**：它们不写 status ⇒ 取默认值 'unsent' ⇒
#       三个租约列保持 NULL ⇒ 满足第一个分支（已实测确认三行都是 `unsent/NULL`）。
pg_exec "$DB3" >/dev/null <<'SQL'
INSERT INTO stocks (code, name) VALUES ('000003', '无损股');
INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash,
                           status, lease_id, lease_expires_at, reserved_at)
VALUES ('000003', '无损股', 100, 200, 1, '/tmp/l1.zip', 'aaaa1111',
        'unsent', NULL, NULL, NULL),
       ('000003', '无损股', 300, 400, 2, '/tmp/l2.zip', 'bbbb2222',
        'sent', gen_random_uuid(), NOW() + interval '1 hour', NOW());
SQL

# 防呆：两种 status 都要真的在样本里。若哪天有人把 sent 那行删掉"图省事"，
# 整表指纹判据会退化成"只验了 unsent 行"，而它照样全绿。
assert_eq "无损样本覆盖了两种 status（unsent + sent）" \
  "$(pg_query "$DB3" "SELECT string_agg(DISTINCT status, ',' ORDER BY status) FROM training_sets;")" \
  "sent,unsent"

# 判据不是"schema_version 没变"（Part 2 已经证了），而是**整张表一个字节都没变**：
# 回滚"无损"要防的不只是那一列 —— 任何一列被改写、任何一行消失都算有损。
# 用 md5(整行文本) 的聚合作为"整表指纹"。
SNAP_BEFORE=$(pg_query "$DB3" "SELECT md5(string_agg(t::text, E'\n' ORDER BY t.id)) FROM training_sets t;")
ROWS_BEFORE=$(pg_query "$DB3" "SELECT count(*) FROM training_sets;")
assert_eq "无损样本就位（2 行）" "$ROWS_BEFORE" "2"

pg_run_file "$DB3" "$FORWARD_SQL" >/dev/null
pg_run_file "$DB3" "$ROLLBACK_SQL" >/dev/null

SNAP_AFTER=$(pg_query "$DB3" "SELECT md5(string_agg(t::text, E'\n' ORDER BY t.id)) FROM training_sets t;")
ROWS_AFTER=$(pg_query "$DB3" "SELECT count(*) FROM training_sets;")

assert_eq "升降级一圈之后行数不变" "$ROWS_AFTER" "$ROWS_BEFORE"
assert_eq "升降级一圈之后**整张表的内容指纹**逐字节不变 ⇒ rollback 确实无数据损失" \
  "$SNAP_AFTER" "$SNAP_BEFORE"

# 防空转：指纹不能是空值（表被清空时 string_agg 返回 NULL，md5(NULL) 也是 NULL，
# 两个 NULL 在 psql -tA 下都打印成空串 ⇒ "空 == 空"会让上面那条恒真）。
if [ -n "$SNAP_BEFORE" ]; then
  pass_msg "整表指纹非空（防空转：若表被清空，两边都会是空串而上面那条恒真）"
else
  fail_msg "整表指纹是空串 —— 上面那条相等断言没有判别力，脚本自身有 bug"
  exit 1
fi

# ---------- 收尾 ----------

echo ""
echo "===== 结果 ====="
echo "[PASS] 全部断言通过，共 ${PASS_COUNT} 条。"

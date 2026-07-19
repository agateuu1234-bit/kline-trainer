#!/usr/bin/env bash
# rehearse.sh —— migration 0004_qmt_price_double_and_coverage 真库演练脚本
#
# 人工执行，不进 CI（user 裁决：加 CI 会牵动 workflow 变更 + 让日常本地测试必须起 Docker）。
# 上线到任何真实 PostgreSQL 之前，必须先跑本脚本并全绿。见同目录 README.md。
#
# 做的事：
#   1. 用 Docker 起一个一次性 PostgreSQL 容器（版本对齐 backend/docker-compose.yml）
#   2. 建"迁移前"形状的库（取自 git 历史 7037934:backend/sql/schema.sql，即本 migration 的 merge-base）
#   3. 塞样本数据，跑 forward.sql，断言 schema 形状 + 数据完整性
#   4. 跑 rollback.sql，断言形状回退
#   5. 专门验证 rollback.sql 顶部注明的两个已知风险是否属实：
#        - OHLC 精度损失（DOUBLE PRECISION → DECIMAL(10,2) 会截断）
#        - file_path 超长时回滚会报错中止（TEXT → VARCHAR(255) 拒绝截断）
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

# 本 migration 的 merge-base（改动前的 main）。这是一个固定的历史提交引用，不是
# "当前分支的 merge-base 动态计算" —— 分支合并/删除后动态计算会失效，而这份 schema
# 快照只应该对应这一个 migration 的"迁移前"形状，因此刻意硬编码。
PRE_MIGRATION_SHA="7037934"

# 与 backend/docker-compose.yml 的 `image: postgres:15.12` 保持一致（勿凭空猜版本）。
PG_IMAGE="postgres:15.12"

CONTAINER_NAME="kline-rehearse-0004-$$-$(date +%s)"
PG_PASSWORD="rehearse_throwaway_$$"   # 仅容器内部用，不对外暴露端口

if [ -f "$FORWARD_SQL" ]; then
  :
else
  echo "[FAIL] 找不到 $FORWARD_SQL —— 脚本可能被移动，或 forward.sql 被删除"
  exit 1
fi

if [ -f "$ROLLBACK_SQL" ]; then
  :
else
  echo "[FAIL] 找不到 $ROLLBACK_SQL —— 脚本可能被移动，或 rollback.sql 被删除"
  exit 1
fi

if git -C "$REPO_ROOT" cat-file -e "${PRE_MIGRATION_SHA}^{commit}" 2>/dev/null; then
  :
else
  echo "[FAIL] 仓库中找不到提交 $PRE_MIGRATION_SHA（迁移前 schema 快照的来源）"
  echo "可能是浅克隆缺历史，请先 git fetch --unshallow 再重跑"
  exit 1
fi

echo "[PASS] forward.sql / rollback.sql / 迁移前 schema 快照来源提交均可用"

TMP_LOG="$(mktemp)"

cleanup() {
  local exit_code=$?
  echo ""
  echo "===== 清理 ====="
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  rm -f "$TMP_LOG" 2>/dev/null || true
  if [ "$exit_code" -eq 0 ]; then
    echo "容器 $CONTAINER_NAME 已清理，演练脚本正常结束。"
  else
    echo "容器 $CONTAINER_NAME 已清理（脚本以失败退出，exit=$exit_code）。"
  fi
  exit "$exit_code"
}
trap cleanup EXIT

# ---------- 辅助函数 ----------

PASS_COUNT=0

pass_msg() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  [PASS] $1"
}

fail_msg() {
  echo "  [FAIL] $1"
}

# 断言字符串相等；不等则打印 FAIL 并立刻非零退出（本仓 set -e 下 "! cmd" 会静默失效的坑，
# 一律用 if/then/exit1 显式写）
assert_rejects() {
  # $1=描述  $2=db  $3=期望出现在错误信息里的约束名或 SQLSTATE  $4=应当被拒绝的 SQL
  #
  # ⚠️ 必须校验**被谁拒的**，不能接受任意失败（codex R4-F1）。
  # 初版只判"是否失败"，而三条坏价格探针误用了未播种的股票代码 →
  # 实际被**外键**拦下、根本没走到 CHECK；那样即便两条价格 CHECK 完全不存在，
  # 探针也照样"通过"，等于伪证。判据必须钉到具体约束。
  #
  # 负向判定用 if/else 显式分支，不用 `! cmd`——本仓踩过 `set -e` 下 `! grep`
  # 让闸门静默失效的坑。
  local desc="$1" db="$2" expect="$3" sql="$4"
  local out rc
  out=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
          psql -U postgres -h 127.0.0.1 -d "$db" -v ON_ERROR_STOP=1 -tA -c "$sql" 2>&1) && rc=0 || rc=$?
  if [ "${rc:-0}" -eq 0 ]; then
    fail_msg "$desc —— 该语句本应被数据库拒绝，却执行成功了"
    exit 1
  fi
  if printf '%s' "$out" | grep -q "$expect"; then
    pass_msg "$desc（确由 $expect 拒绝）"
  else
    fail_msg "$desc —— 被拒了，但不是期望的原因。期望错误信息含 [$expect]，实际：$out"
    exit 1
  fi
}

assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    fail_msg "$desc —— 期望 [$expected]，实际 [$actual]"
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
    psql -U postgres -h 127.0.0.1 -d "$1" -v ON_ERROR_STOP=1 < "$2"
}

load_pre_migration_schema() {
  # $1=db —— 从 git 历史取"迁移前"schema.sql，不手抄
  git -C "$REPO_ROOT" show "${PRE_MIGRATION_SHA}:backend/sql/schema.sql" | \
    docker exec -i -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
      psql -U postgres -h 127.0.0.1 -d "$1" -v ON_ERROR_STOP=1
}

seed_baseline() {
  # $1=db —— 1 只股票 + 3 条 klines(价格用能体现精度的 2 位小数) + 2 行 training_sets
  #           （unsent 与 sent 各一，覆盖 lease 三列不变量的两个分支）
  pg_exec "$1" <<'SQL'
INSERT INTO stocks (code, name) VALUES ('000001', '平安银行');

INSERT INTO klines (stock_code, period, datetime, open, high, low, close, volume, amount)
VALUES
  ('000001', '1d', 20260101000000, 12.34, 12.88, 12.10, 12.50, 1000000, 12345678.90),
  ('000001', '1d', 20260102000000, 12.50, 12.99, 12.30, 12.77, 1100000, 13456789.01),
  ('000001', '1d', 20260105000000,  8.88,  9.01,  8.75,  8.95,  900000,  8012345.67);

INSERT INTO training_sets
  (stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash)
VALUES
  ('000001', '平安银行', 20260101093000, 20260101150000,
   '/mnt/nas/kline_trainer/datasets/000001/20260101_093000_20260101_150000.zip',
   'a1b2c3d4');

INSERT INTO training_sets
  (stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash,
   status, lease_id, lease_expires_at, reserved_at)
VALUES
  ('000001', '平安银行', 20260102093000, 20260102150000,
   '/mnt/nas/kline_trainer/datasets/000001/20260102_093000_20260102_150000.zip',
   'b2c3d4e5', 'sent', gen_random_uuid(), NOW() + interval '1 hour', NOW());
SQL
}

# ---------- 起容器 ----------

echo ""
echo "===== 起临时 PostgreSQL 容器 ====="
echo "镜像: $PG_IMAGE  容器名: $CONTAINER_NAME"

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --rm --name "$CONTAINER_NAME" \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" \
  "$PG_IMAGE" >/dev/null

READY=0
TRIES=0
while [ "$TRIES" -lt 60 ]; do
  if docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then
    READY=1
    break
  fi
  TRIES=$((TRIES + 1))
  sleep 1
done

if [ "$READY" -eq 1 ]; then
  pass_msg "PostgreSQL 容器已就绪（等待 ${TRIES}s）"
else
  fail_msg "PostgreSQL 容器在 60 秒内未就绪，见 docker logs $CONTAINER_NAME"
  exit 1
fi

# 注：CREATE DATABASE 不能出现在事务块里；用 psql -c "A;B;C;" 一次发送多条语句会被
# PostgreSQL 隐式包进同一事务而报错，所以每个库单独一次 createdb 调用。
for db in main_db precision_db overlong_db; do
  docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
    createdb -U postgres -h 127.0.0.1 "$db"
done
pass_msg "已建 3 个演练库：main_db(主流程回环) / precision_db(精度损失验证) / overlong_db(超长路径中止验证)"

for db in main_db precision_db overlong_db; do
  load_pre_migration_schema "$db" >/dev/null
  seed_baseline "$db" >/dev/null
done
pass_msg "3 个库均已加载迁移前 schema（取自 git $PRE_MIGRATION_SHA）+ 样本数据"

# ==========================================================================
# Part 1：main_db —— forward → 断言形状+数据完整性 → rollback → 断言形状回退
# ==========================================================================

echo ""
echo "===== Part 1：main_db 完整升降级回环 ====="

KLINES_BEFORE="$(pg_query main_db 'SELECT count(*) FROM klines;')"
TS_BEFORE="$(pg_query main_db 'SELECT count(*) FROM training_sets;')"
OPEN_BEFORE="$(pg_query main_db "SELECT open FROM klines WHERE stock_code='000001' AND datetime=20260101000000;")"

echo "-- 执行 forward.sql --"
if pg_run_file main_db "$FORWARD_SQL" > "$TMP_LOG" 2>&1; then
  pass_msg "forward.sql 在 main_db 上执行成功"
else
  fail_msg "forward.sql 在 main_db 上执行失败："
  cat "$TMP_LOG"
  exit 1
fi

assert_eq "klines 四个价格列类型已是 double precision" \
  "$(pg_query main_db "SELECT string_agg(data_type, ',' ORDER BY column_name) FROM information_schema.columns WHERE table_schema='public' AND table_name='klines' AND column_name IN ('open','high','low','close');")" \
  "double precision,double precision,double precision,double precision"

assert_eq "training_sets.file_path 类型已是 text（无长度上限）" \
  "$(pg_query main_db "SELECT data_type || ':' || COALESCE(character_maximum_length::text,'NULL') FROM information_schema.columns WHERE table_schema='public' AND table_name='training_sets' AND column_name='file_path';")" \
  "text:NULL"

assert_eq "stock_coverage 表已存在" \
  "$(pg_query main_db "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='stock_coverage';")" \
  "1"

assert_eq "stock_coverage 三条 CHECK 约束都在" \
  "$(pg_query main_db "SELECT string_agg(conname, ',' ORDER BY conname) FROM pg_constraint WHERE conrelid='stock_coverage'::regclass AND contype='c';")" \
  "ck_stock_coverage_day_count,ck_stock_coverage_dropped_is_array,ck_stock_coverage_range"

assert_eq "klines 价格完整性 CHECK 已建（codex R3-F1：DB 层挡 NaN/Infinity 与顺序违规）" \
  "$(pg_query main_db "SELECT string_agg(conname, ',' ORDER BY conname) FROM pg_constraint WHERE conrelid='klines'::regclass AND contype='c' AND conname LIKE 'ck_klines_price%';")" \
  "ck_klines_price_finite_positive,ck_klines_price_ordering"

# 这两条是本轮最有价值的断言：证明约束**真的会拒**坏数据，而不只是"建出来了"。
assert_rejects "非有限价格（Infinity）被 DB 拒绝" main_db "ck_klines_price_finite_positive" \
  "INSERT INTO klines (stock_code, period, datetime, open, high, low, close, volume)
   VALUES ('000001','1m',9000000001,'Infinity'::double precision,'Infinity'::double precision,1,1,1);"

assert_rejects "NaN 价格被 DB 拒绝" main_db "ck_klines_price_finite_positive" \
  "INSERT INTO klines (stock_code, period, datetime, open, high, low, close, volume)
   VALUES ('000001','1m',9000000002,'NaN'::double precision,'NaN'::double precision,1,1,1);"

assert_rejects "顺序违规（high < low）被 DB 拒绝" main_db "ck_klines_price_ordering" \
  "INSERT INTO klines (stock_code, period, datetime, open, high, low, close, volume)
   VALUES ('000001','1m',9000000003,1.0,0.5,2.0,1.0,1);"

assert_eq "ticket_index 列仍在（停写不删列不变量，本 migration 对该列零 DDL）" \
  "$(pg_query main_db "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='klines' AND column_name='ticket_index';")" \
  "1"

assert_eq "klines 行数迁移前后一致（未丢数据）" \
  "$(pg_query main_db 'SELECT count(*) FROM klines;')" "$KLINES_BEFORE"

assert_eq "training_sets 行数迁移前后一致（未丢数据）" \
  "$(pg_query main_db 'SELECT count(*) FROM training_sets;')" "$TS_BEFORE"

assert_eq "抽查价格值迁移前后等值（12.34 未被改写）" \
  "$(pg_query main_db "SELECT open FROM klines WHERE stock_code='000001' AND datetime=20260101000000;")" \
  "$OPEN_BEFORE"

echo "-- 执行 rollback.sql --"
if pg_run_file main_db "$ROLLBACK_SQL" > "$TMP_LOG" 2>&1; then
  pass_msg "rollback.sql 在 main_db 上执行成功（存量数据均满足旧约束，预期可回滚）"
else
  fail_msg "rollback.sql 在 main_db 上执行失败（不应该失败 —— 这批数据本应满足旧约束）："
  cat "$TMP_LOG"
  exit 1
fi

assert_eq "klines 四个价格列类型已回退为 numeric(10,2)" \
  "$(pg_query main_db "SELECT string_agg(data_type || ':' || numeric_precision || ':' || numeric_scale, ',' ORDER BY column_name) FROM information_schema.columns WHERE table_schema='public' AND table_name='klines' AND column_name IN ('open','high','low','close');")" \
  "numeric:10:2,numeric:10:2,numeric:10:2,numeric:10:2"

assert_eq "training_sets.file_path 类型已回退为 character varying(255)" \
  "$(pg_query main_db "SELECT data_type || ':' || character_maximum_length FROM information_schema.columns WHERE table_schema='public' AND table_name='training_sets' AND column_name='file_path';")" \
  "character varying:255"

assert_eq "stock_coverage 表已删除" \
  "$(pg_query main_db "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='stock_coverage';")" \
  "0"

assert_eq "klines 行数回滚后仍一致" \
  "$(pg_query main_db 'SELECT count(*) FROM klines;')" "$KLINES_BEFORE"

assert_eq "training_sets 行数回滚后仍一致" \
  "$(pg_query main_db 'SELECT count(*) FROM training_sets;')" "$TS_BEFORE"

assert_eq "抽查价格值回滚后仍等值（本批数据本就是 2 位小数，不损失精度）" \
  "$(pg_query main_db "SELECT open FROM klines WHERE stock_code='000001' AND datetime=20260101000000;")" \
  "$OPEN_BEFORE"

# ==========================================================================
# Part 2：precision_db —— 验证 rollback.sql 顶部警告①：OHLC 精度损失属实
# ==========================================================================

echo ""
echo "===== Part 2：precision_db —— 验证「rollback 会丢 OHLC 精度」这条警告是否属实 ====="

if pg_run_file precision_db "$FORWARD_SQL" > "$TMP_LOG" 2>&1; then
  pass_msg "forward.sql 在 precision_db 上执行成功"
else
  fail_msg "forward.sql 在 precision_db 上执行失败："
  cat "$TMP_LOG"
  exit 1
fi

# 插入 QMT 前复权典型的高精度 float64 价格（该数值本身即取自 rollback.sql 顶部注释的示例）
pg_exec precision_db <<'SQL'
INSERT INTO klines (stock_code, period, datetime, open, high, low, close, volume)
VALUES ('000001', '1d', 20260110000000, 11.790828206557329, 11.9, 11.7, 11.8, 500000);
SQL

# 注：不对 double precision 的输出文本做逐字符比对（PostgreSQL 的浮点数最短往返输出算法
# 不保证复现录入时敲的字符串），改为比较"是否仍带 2 位小数以外的精度"这一更稳的断言。
assert_eq "forward 后高精度价格未被 double precision 列截断（仍带 2 位小数以外的精度）" \
  "$(pg_query precision_db "SELECT (open <> 11.79::double precision)::text FROM klines WHERE stock_code='000001' AND datetime=20260110000000;")" \
  "t"

if pg_run_file precision_db "$ROLLBACK_SQL" > "$TMP_LOG" 2>&1; then
  pass_msg "rollback.sql 在 precision_db 上执行成功（file_path 本批数据不超长，不触发另一条警告）"
else
  fail_msg "rollback.sql 在 precision_db 上意外失败（本场景不该触发 file_path 那条警告）："
  cat "$TMP_LOG"
  exit 1
fi

assert_eq "警告属实：高精度价格回滚后被截断为 11.79（精度已丢失，不可恢复）" \
  "$(pg_query precision_db "SELECT open FROM klines WHERE stock_code='000001' AND datetime=20260110000000;")" \
  "11.79"

# ==========================================================================
# Part 3：overlong_db —— 验证 rollback.sql 顶部警告②：超长 file_path 会报错中止
# ==========================================================================

echo ""
echo "===== Part 3：overlong_db —— 验证「file_path 超 255 字符时 rollback 会报错中止」这条警告是否属实 ====="

if pg_run_file overlong_db "$FORWARD_SQL" > "$TMP_LOG" 2>&1; then
  pass_msg "forward.sql 在 overlong_db 上执行成功"
else
  fail_msg "forward.sql 在 overlong_db 上执行失败："
  cat "$TMP_LOG"
  exit 1
fi

LONG_PATH="/mnt/nas/kline_trainer/datasets/000001/$(printf 'a%.0s' $(seq 1 250))/dataset.zip"
LONG_PATH_LEN=${#LONG_PATH}
if [ "$LONG_PATH_LEN" -le 255 ]; then
  fail_msg "测试数据本身长度不足 255（当前 $LONG_PATH_LEN），无法验证该场景，脚本需要修"
  exit 1
fi
echo "  （构造 file_path 长度 = $LONG_PATH_LEN 字符，超出 VARCHAR(255) 上限）"

pg_exec overlong_db <<SQL
INSERT INTO training_sets
  (stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash)
VALUES
  ('000001', '平安银行', 20260103093000, 20260103150000, '$LONG_PATH', 'c3d4e5f6');
SQL

if pg_run_file overlong_db "$ROLLBACK_SQL" > "$TMP_LOG" 2>&1; then
  fail_msg "警告不实：rollback 在超长 file_path 场景下本应报错中止，却执行成功了 —— 需要重新评审 rollback.sql 或更新文档"
  exit 1
fi
# ⚠️ 同 assert_rejects 的教训（codex R4-F1）：不能把"失败了"直接当成"因这个原因失败的"。
# 若 rollback 因别的缘故挂掉（语法错、DROP CONSTRAINT 出问题…），只判失败会误报"警告属实"。
# 故必须钉到具体错误：PostgreSQL 对超长值收窄报 22001 / "value too long"。
if grep -qE 'value too long|22001' "$TMP_LOG"; then
  pass_msg "警告属实：rollback 因超长 file_path 报错中止（PostgreSQL 拒绝截断，fail-closed 生效）"
else
  fail_msg "rollback 确实失败了，但**不是**因为超长 file_path —— 该场景未被真正验证。实际错误："
  cat "$TMP_LOG"
  exit 1
fi

# 失败的 rollback 应整笔回滚（BEGIN...COMMIT 中途出错，事务全体失效）——
# 验证 schema 仍停在"迁移后"形状，没有半吊子状态
assert_eq "失败回滚后 stock_coverage 表仍在（未被半途 DROP 掉）" \
  "$(pg_query overlong_db "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='stock_coverage';")" \
  "1"

assert_eq "失败回滚后 klines 价格列仍是 double precision（未被半途改回 numeric）" \
  "$(pg_query overlong_db "SELECT string_agg(data_type, ',' ORDER BY column_name) FROM information_schema.columns WHERE table_schema='public' AND table_name='klines' AND column_name IN ('open','high','low','close');")" \
  "double precision,double precision,double precision,double precision"

# ---------- 总结 ----------

echo ""
echo "===== 总结 ====="
echo "全部 $PASS_COUNT 项检查通过。"
echo "  1) forward.sql 升级形状正确 + 既有数据零丢失"
echo "  2) rollback.sql 能把形状降回迁移前"
echo "  3) rollback.sql 顶部两条已知风险警告均验证属实：OHLC 精度损失 / file_path 超长报错中止"
echo ""
echo "本机演练全绿，不代表目标真库一定顺利（真库的既有数据分布未知），"
echo "但证明了 migration 本身在标准场景 + 两个已知边界场景下行为与文档一致。"

#!/bin/sh
# docs/runbooks/2026-08-24-qmt-nas-verify-backup.sh
#
# P6-RESET 门 3d：证明「那份备份真的能恢复出与源库**一致**的数据」，
# 之后才允许销毁数据卷（不可逆）。
#
# ⚠️ 为什么需要它（codex plan-R21）：早先的校验只比对了 `training_sets` 一张表的
#    行数。而 `pg_restore --list` 里出现 4 条 TABLE DATA **只能证明归档里有这四个
#    条目**，证明不了另外三张表（klines / stocks / stock_coverage）的行有没有被
#    完整带走。于是「备份里少了 6 万行 K 线」这种情况会一路通过，
#    然后卷就被销毁了 —— 不可逆。
#
# 判据（任一不满足即失败，绝不放行）：
#   ① 源库与恢复库都必须**恰好**有那 4 张应用表，一张不多一张不少；
#   ② 每张表的**行数**逐表相等；
#   ③ 每张表内容的 **md5 指纹**逐表相等（按主键排序后整行拼接，顺序确定）；
#   ④ 任一查询报错 → 失败（psql 带 ON_ERROR_STOP）。
#
# 用法（在 NAS 上跑）：
#   verify-backup.sh <容器名> <源库名> <恢复库名>
# 例：verify-backup.sh kline-trainer-db-1 kline_trainer restore_check

set -u

CTR=${1:-}; SRC=${2:-}; DST=${3:-}
if [ -z "$CTR" ] || [ -z "$SRC" ] || [ -z "$DST" ]; then
    echo "USAGE: verify-backup.sh <容器名> <源库名> <恢复库名>"
    exit 2
fi

TABLES='klines stocks stock_coverage training_sets'
ORDER_klines='id'
ORDER_stocks='code'
ORDER_stock_coverage='stock_code'
ORDER_training_sets='id'

# 一个库的「指纹清单」：每行 = 表名|行数|内容md5。顺序固定，可直接 diff。
fingerprint() {
    _db=$1
    for _t in $TABLES; do
        eval "_ord=\$ORDER_$_t"
        _sql="SELECT '$_t' || '|' || count(*) || '|' ||
                     COALESCE(md5(string_agg(x.rowtext, E'\n' ORDER BY x.rowtext)), 'EMPTY')
              FROM (SELECT t::text AS rowtext FROM $_t t ORDER BY $_ord) x;"
        if ! docker exec -i "$CTR" psql -v ON_ERROR_STOP=1 -tA -U kline -d "$_db" \
                -c "$_sql" </dev/null 2>/dev/null; then
            echo "QUERY_FAILED|$_db|$_t"
            return 1
        fi
    done
    return 0
}

# 应用表清单（用来断言「恰好这 4 张」）
table_list() {
    docker exec -i "$CTR" psql -v ON_ERROR_STOP=1 -tA -U kline -d "$1" \
        -c "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;" \
        </dev/null 2>/dev/null
}

WANT_TABLES="klines
stock_coverage
stocks
training_sets"

_srct=$(table_list "$SRC") || { echo "VERIFY_FAILED: 读不到源库 $SRC 的表清单"; exit 1; }
_dstt=$(table_list "$DST") || { echo "VERIFY_FAILED: 读不到恢复库 $DST 的表清单"; exit 1; }

if [ "$_srct" != "$WANT_TABLES" ]; then
    echo "VERIFY_FAILED: 源库的表清单不是预期的 4 张"
    printf '  实际:\n%s\n' "$_srct"
    exit 1
fi
if [ "$_dstt" != "$WANT_TABLES" ]; then
    echo "VERIFY_FAILED: **恢复库**的表清单不是预期的 4 张（备份不完整）"
    printf '  实际:\n%s\n' "$_dstt"
    exit 1
fi

_a=$(fingerprint "$SRC") || { echo "VERIFY_FAILED: 源库指纹计算失败"; printf '%s\n' "$_a"; exit 1; }
_b=$(fingerprint "$DST") || { echo "VERIFY_FAILED: 恢复库指纹计算失败"; printf '%s\n' "$_b"; exit 1; }

echo "源库   ($SRC):"
printf '%s\n' "$_a" | sed 's/^/  /'
echo "恢复库 ($DST):"
printf '%s\n' "$_b" | sed 's/^/  /'

if [ "$_a" = "$_b" ]; then
    echo "VERIFY_OK: 4 张表的行数与内容指纹逐表一致，备份可恢复"
    exit 0
fi
echo "VERIFY_FAILED: 源库与恢复库不一致 —— **不得销毁数据卷**"
echo "--- 差异 ---"
# ⚠️ 不用 `diff <(...) <(...)` —— 进程替换是 bash 专有语法，本机 /bin/sh 是 dash，
#    写了会直接语法错误（本轮真踩到）。用临时文件。
_ta=/tmp/kt-verify-a.$$; _tb=/tmp/kt-verify-b.$$
printf '%s\n' "$_a" > "$_ta"; printf '%s\n' "$_b" > "$_tb"
diff "$_ta" "$_tb" || true
rm -f "$_ta" "$_tb"
exit 1

# Migration 0004: QMT 前复权价格精度 + B1→B2 覆盖契约

## 改了什么、为什么

三项变更，同一 migration、同一次 CONTRACT_VERSION bump（1.11 → 1.12）覆盖：

1. **`klines` 四个价格列 `DECIMAL(10,2)` → `DOUBLE PRECISION`**
   QMT 前复权价是 float64（如 `11.790828206557329`），老 K 线经前复权会被缩得极小
   （如 1991 年 `0.61...`）。`DECIMAL(10,2)` 只留 2 位小数，会把这类价格截断/压塌成失真值。
   `DOUBLE PRECISION` 能无损承载。
2. **`training_sets.file_path` `VARCHAR(255)` → `TEXT`**
   D5：绝对路径长度不再假设 255 字符封顶。
3. **新增 `stock_coverage` 表**（D11）
   B1 写权威 dense 1m 覆盖，B2 读作 dense_dates（不再从 klines 反推）。三条 CHECK 约束
   （区间合法 / dropped 字段是数组 / day_count 非负）在 DB 层强制。

`ticket_index` 列**保留、停止写入**（D3）——本 migration 对该列零 DDL，这是一条核心不变量，
`rehearse.sh` 会专门断言这一点。

详见 `forward.sql` / `rollback.sql` 顶部注释，以及
`docs/superpowers/specs/2026-07-06-qmt-data-ingestion-pilot-design.md` §4.3（D1/D5/D11）。

## 上线前必须先跑演练脚本

**在把这个 migration 应用到任何真实数据库之前，必须先跑 `rehearse.sh` 并全绿：**

```bash
cd backend/sql/migrations/0004_qmt_price_double_and_coverage
./rehearse.sh
```

背景：目前对这个 migration 的全部检验只有 pglast 静态语法解析（SQL 能不能被解析），从未在
真实 PostgreSQL 上跑过——存量数据、对象形状、类型转换、锁行为都有可能在语法解析层面完全
查不出问题、却在真实执行时失败。`rehearse.sh` 用一次性 Docker 容器（镜像版本对齐
`backend/docker-compose.yml`）复现"迁移前"的 schema 形状（取自 git 历史，本 migration 的
merge-base 提交 `7037934`），塞入样本数据，走完整条 forward → 断言 → rollback → 断言 的路径，
并且专门验证下面两条已知风险是否属实。

这份脚本是人工执行的演练，**不进 CI**（会牵动 workflow 变更，也会让日常本地测试必须起
Docker；user 裁决按此处理）。它不是"测过一次就够了"——schema 或 migration 有任何改动、或者
即将第一次对接真实数据库时，都应该重跑。

## rollback 的两个已知风险

`rollback.sql` 顶部注释已写明，且**已由 `rehearse.sh` 在真实 PostgreSQL 15.12 上验证属实**
（2026-07-19，32/32 全绿）：

1. **OHLC 精度丢失，不可恢复**：`DOUBLE PRECISION → DECIMAL(10,2)` 是收窄，会把高精度价格
   截断到 2 位小数（如 `11.790828206557329` → `11.79`）。执行 rollback 前必须先备份
   `klines`，或确认该库里没有 QMT 前复权数据。
2. **`file_path` 超过 255 字符时，rollback 会报错中止**：`TEXT → VARCHAR(255)` 收窄，若存量
   有超长绝对路径，PostgreSQL 会拒绝截断、整个 rollback 事务失败回滚（fail-closed，不会留下
   半吊子状态）。回滚前需要先人工清理超长路径。

> **⚠️ rollback 现在会 fail-closed 拒绝执行**（若真有数据会丢）：
> 它会统计 `stock_coverage` 待删行数 + `klines` 中精度超 2 位小数的行数，
> 只要任一 > 0 就报错中止，并在错误信息里给出具体行数。
> 确认已备份后，用下面这条放行（**必须同一会话**）：
>
> ```bash
> psql -d <db> -v ON_ERROR_STOP=1 \
>   -c "SET kline.rollback_confirm='I_HAVE_A_BACKUP'" -f rollback.sql
> ```
>
> 这道守卫是可执行的拦截，不是注释——因为回滚是「出事才跑」的路径，
> 恰恰是最不会细读警告的时刻。

## 当前状态

**`rehearse.sh` 已在真实 PostgreSQL 15.12 上跑通（2026-07-19，32/32 全部通过）**，
这是本 migration 首次获得真实执行证据。验证覆盖：

- forward 后形状正确（四价格列 `double precision` / `file_path` `text` / `stock_coverage` 三约束齐全）
- **`ticket_index` 列仍在**（停写不删列这条核心不变量，由真库确认）
- **既有数据零丢失**（行数与抽查价格值迁移前后一致）
- **坏数据确由对应 CHECK 拒绝**：Infinity 与 NaN 由 `ck_klines_price_finite_positive`、
  `high < low` 由 `ck_klines_price_ordering`（断言钉到具体约束名，不接受"随便失败一下"）
- rollback 形状正确回退；破坏性守卫**未确认时真的拦、显式确认后真的放行**
- 两条已知风险均验证属实：高精度价格回滚后确被截断为 `11.79`；超长 `file_path`
  确让 rollback 中止（`22001`），且失败后 schema 停在迁移后形状、无半吊子状态

### 首次真跑暴露了两个静态检查查不出的 bug（已修）

演练脚本此前只过了 `bash -n` + `shellcheck`（0 警告）+ pglast 解析内嵌 SQL，
**首次真跑仍连炸两次**：

1. `$VAR` 紧跟全角字符（如 `$PRE_MIGRATION_SHA）`）→ bash 把多字节字符的字节吞进
   变量名 → `set -u` 报「未绑定的变量」。全脚本 5 处，已一律改 `${VAR}`，
   并加了 `test_rehearse_script_braces_vars_before_cjk` 把该运行期陷阱变成静态可检。
2. 布尔断言期望值写成 `t`，而 `bool::text` 实际产出 `true`。

**教训留档**：静态检查全绿的脚本里确实藏得住必崩的 bug。任何新增/修改本脚本后，
都应重新真跑一次，而不是靠静态检查放行。

### 仍需注意（真库上线前）

本机演练全绿**不代表目标真库一定顺利**——真库的既有数据分布未知。上线前仍需：

- 确认存量 `klines` 中是否已有精度超 2 位小数的价格（决定 rollback 是否会触发守卫）
- 确认存量 `training_sets.file_path` 是否已有超 255 字符的路径（决定 rollback 能否执行）
- 若 `klines` 数据量大，`ADD CONSTRAINT` 的全表扫描与 ACCESS EXCLUSIVE 锁时长需评估，
  必要时改走 `forward.sql` 注释里给出的在线路径（`NOT VALID` → 清洗 → `VALIDATE`）

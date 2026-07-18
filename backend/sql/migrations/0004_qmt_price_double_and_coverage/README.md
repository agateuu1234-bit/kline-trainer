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

`rollback.sql` 顶部注释已写明，`rehearse.sh` 用真实场景验证过均属实：

1. **OHLC 精度丢失，不可恢复**：`DOUBLE PRECISION → DECIMAL(10,2)` 是收窄，会把高精度价格
   截断到 2 位小数（如 `11.790828206557329` → `11.79`）。执行 rollback 前必须先备份
   `klines`，或确认该库里没有 QMT 前复权数据。
2. **`file_path` 超过 255 字符时，rollback 会报错中止**：`TEXT → VARCHAR(255)` 收窄，若存量
   有超长绝对路径，PostgreSQL 会拒绝截断、整个 rollback 事务失败回滚（fail-closed，不会留下
   半吊子状态）。回滚前需要先人工清理超长路径。

## 当前状态

本仓 PostgreSQL **至今未部署**（`kline-trainer.local` 尚不可用），这个 migration 至今
**从未在真实数据库上执行过**——`rehearse.sh` 是为部署那天准备的演练路径，不是"已验证过"的
声明。部署真库前，除了跑通 `rehearse.sh`，仍需在目标库的真实数据规模/形状上做一次针对性检查
（尤其是超长 `file_path` 是否已存在于存量数据）。

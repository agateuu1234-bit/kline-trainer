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

`rollback.sql` 顶部注释已写明，`rehearse.sh` **写了**针对这两条的真实场景断言——
但注意该脚本**至今从未真正执行过**（见文末），所以这两条目前仍是"设计意图"而非"已验证事实"：

1. **OHLC 精度丢失，不可恢复**：`DOUBLE PRECISION → DECIMAL(10,2)` 是收窄，会把高精度价格
   截断到 2 位小数（如 `11.790828206557329` → `11.79`）。执行 rollback 前必须先备份
   `klines`，或确认该库里没有 QMT 前复权数据。
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

2. **`file_path` 超过 255 字符时，rollback 会报错中止**：`TEXT → VARCHAR(255)` 收窄，若存量
   有超长绝对路径，PostgreSQL 会拒绝截断、整个 rollback 事务失败回滚（fail-closed，不会留下
   半吊子状态）。回滚前需要先人工清理超长路径。

## 当前状态

本仓 PostgreSQL **至今未部署**（`kline-trainer.local` 尚不可用），这个 migration 至今
**从未在真实数据库上执行过**——`rehearse.sh` 是为部署那天准备的演练路径，不是"已验证过"的
声明。部署真库前，除了跑通 `rehearse.sh`，仍需在目标库的真实数据规模/形状上做一次针对性检查
（尤其是超长 `file_path` 是否已存在于存量数据）。

### ⚠️ `rehearse.sh` 本身也从未被执行过

撰写它的机器上没有 Docker（`docker`/`podman`/`colima`/`nerdctl` 均未安装，已实测确认），
所以这个脚本**只经过静态检查**：`bash -n` 语法、`shellcheck -x`（0 警告）、以及用 pglast
把内嵌的 20 条 SQL 全部单独解析通过。**它从未真正跑起来过。**

静态走查期间已经揪出并修掉一个真 bug（原先用一条 `psql -c` 里串三个 `CREATE DATABASE`，
而 PostgreSQL 会把同一查询字符串隐式包进事务、`CREATE DATABASE` 不能在事务块内执行，
必然报错）。**一个静态检查全过的脚本里能藏这种 bug，说明还可能藏别的。**

因此，**第一次在有 Docker 的机器上运行时，请把它当作"待调试的脚本"而不是"可信的闸门"**：

- 若它报错 → **先怀疑脚本自己**，不要立刻断定 migration 有问题
- 若它全绿 → 这才是 `forward.sql`/`rollback.sql` 第一次获得真实执行证据
- 首次跑通后，请把这一节删掉或改写为"已于 YYYY-MM-DD 在 <环境> 跑通"

# QMT 数据接入 Plan 3：B1 接规整/合成层 + 写 `stock_coverage` 设计（2026-07-23）

> 上游 spec：`docs/superpowers/specs/2026-07-06-qmt-data-ingestion-pilot-design.md`（D1-D11 决策的权威出处，本文只在**它未定或需收窄**处新增决策，不复述）。
> 上游 plan：`docs/superpowers/plans/2026-07-18-qmt-plan2-b2-reconnect.md`（§Self-Review「明确不在本 plan、留 Plan 3」清单）。

---

## 0. 目标 / 范围 / 非范围

### 0.1 目标（一句话）

让 **B1（`import_csv.py` 侧）真正接上 Plan 1 已 merge 但零调用方的 QMT 规整/合成层**，导入时把权威 dense 覆盖写进 `stock_coverage`，从而**解除 B2/B4 恒产 0 的根因**；同时消除 Plan 2b 遗留的「coverage 与六周期 klines 无统一快照」残留。

### 0.2 交付口径（诚实义务，沿用 Plan 2 的做法）

Plan 3 交付的是 **「出货能力被一条真链路证明」**——即 CI 里存在一条 `QMT fixture → B1 规整/合成/写入 → B2 `generate_batch` → 真产出 ≥1 个训练组 zip` 的端到端测试。

Plan 3 **不**交付「已经用真 QMT 数据产出 100 个训练组」。真跑属 Plan 4。

**禁止**在任何 commit message / PR body / 验收项里写「pilot 已完成」「100 股已出货」之类表述。

### 0.3 范围（in scope）

1. B1 侧 **D9(a) 分钟级完整性** 与 **D10 双源对账** 的强制（调用已 merge 的 `build_intraday` / `reconcile_sources`，不重写算法）。
2. B1 写 6 周期 `klines` + `stock_coverage`，**单事务原子**。
3. B1 QMT 模式 CLI（单只股）。
4. B2 侧 **快照一致性**：coverage + 六周期 klines 在同一个 `REPEATABLE READ READ ONLY` 事务内读取。
5. 上述四项的 host pytest 覆盖 + 一次性**真 PG** 验证脚本 + 端到端出货集成测。

### 0.4 非范围（明确留 Plan 4）

SMB 真拉取、100 股储备池与各市场地板（SH≥30/SZ≥40/BJ≥8）、D8b `kline_pilot_` 库 reset 护栏、容器化 PG smoke（上游 spec §5 的 ①②③⑤⑥⑦）、批量导入 CLI、`stock_universe_with_name.csv` 消费。

---

## 1. 现状（基线 `main` `08d70d2`，本设计逐条核实过，非从计划/记忆推断）

| 事实 | 核实方式 |
|---|---|
| `qmt_normalize.py`(56 行) / `qmt_resample.py`(184 行) 纯函数齐备：`parse_qmt_csv` / `parse_qmt_filename` / `trading_date` / `compute_dense_coverage` / `build_intraday` / `resample_calendar` / `period_boundaries` / `reconcile_sources` | 读源码 |
| `import_csv.py` **零 import** 这两个模块；只有「通用 CSV → 单周期 klines」一条路 | 读源码全文 |
| `write_to_postgres` 已有 D8a 守卫（`pg_catalog` + `to_regclass('klines')` 断言 OHLC = `double precision`）且与 `LOCK TABLE klines IN ROW EXCLUSIVE MODE` 同事务原子 | 读源码 |
| `stock_coverage` 5 列 3 CHECK 已在 `schema.sql` 与 migration 0004；**无任何写入方** | grep `stock_coverage` 全仓 |
| `generate_one_training_set` 顺序 = 读 coverage（早退）→ 6 次 `_fetch_period_bars` → `dense_day_count` 交叉校验 → `build_training_windows` → advisory lock → 锁内 `_exists_start` → 写 zip → 登记 | 读源码 |
| `PERIODS = ("monthly","weekly","daily","60m","15m","3m")`；`PERIOD_BEFORE_CAP = {monthly: None(全取), weekly:120, daily:150, 60m:150, 15m:150, 3m:150}` | 读源码 |

**由 `monthly: None`（before-context 全取）直接推出的硬约束：日线必须导入全历史（QMT 日线到 1991），不能按 1m 跨度裁剪。**

---

## 2. 决策（本 plan 新增，编号 P3-D*）

### P3-D1：新建 `backend/qmt_ingest.py` 作为 B1 的 QMT 装配层（纯函数）

不把逻辑塞进 `import_csv.py`。理由：`import_csv.py` 已同时承担「通用 CSV 纯函数层 + 写库壳 + CLI」；再塞进 D10 对账 + 六周期合成会让单文件超 500 行且职责混杂。`qmt_ingest.py` 只依赖 `qmt_normalize` / `qmt_resample` / `import_csv`（复用 `clean` / `compute_indicators` / `to_kline_records`），**不依赖 asyncpg**，host pytest 全测。

入口：

```python
build_stock_import(df_1m, df_daily, *, stock_code, stock_name,
                   status_1m, status_daily) -> ImportBundle
```

`ImportBundle` = `{records: dict[period, list[dict]], coverage: CoverageArtifact}`；
`CoverageArtifact` = `(start_date, end_date, dropped_dates: list[date], dense_day_count: int)`。

拒绝路径：抛 `QmtIngestRejected(reason)`，`reason` 用 `reconcile_sources` 已有的机器可读串（`export_log_not_ok` / `no_dense_1m` / `daily_not_cover_dense` / `date_set_mismatch` / `ohlcv_mismatch`）+ 本层新增（`no_intraday_after_dense_filter` 等）。**一只股要么全部六周期 + coverage 一起写，要么一行都不写。**

### P3-D2：周期来源分工

| 周期 | 来源 | 备注 |
|---|---|---|
| `3m` / `15m` / `60m` | `build_intraday(df_1m)` | 只保留 dense 完整日（D9(a)），非 dense 日整日 drop |
| `daily` | 日线 CSV 全历史，经 `clean` | 不裁剪（P3-D1 上方硬约束） |
| `weekly` / `monthly` | `resample_calendar(df_daily, rule)` | 只发完整周期，partial 当期不 emit |
| `1m` | **不入库**（上游 D3） | 只作合成与覆盖判据的源 |

清洗顺序固定为 **`clean` 先于 `compute_dense_coverage`**：被 `clean` 丢掉的坏行会让那一天的 1m 根数 ≠ 241 → 该日落入 `dropped` → fail-closed。反过来（先算覆盖再清洗）会让坏行伪装成完整日。

指标（MA66/BOLL/MACD）**逐周期**在该周期自己的序列上算，复用 `import_csv.compute_indicators`，`round(4)/round(6)` 不变。

### P3-D3：`export_log.csv` 的 status 门（D10-(a)）——必填、fail-closed

`reconcile_sources` 的 `status_1m` / `status_daily` 参数当前默认 `"ok"`，若调用方不传即等于**默认放行**，会把 codex 加的这道门变成摆设。故：

- B1 QMT 模式 **必须**拿到 export_log（CLI `--export-log`，默认 `<输入目录>/export_log.csv`）；文件不存在 → 报错退出，**不默认 ok**。
- 解析器 `parse_export_log(path) -> dict[(code, period), status]`：要求存在 `status`、`period` 两列；股票标识列从候选集 `stock` / `code` / `stock_code` / `file` / `filename` 取**第一个存在的**，值若形如 QMT 文件名则经 `parse_qmt_filename` 取 code，否则按裸 code 比对。
- 候选集全不命中 → 抛 `QmtSchemaError`（**停下并报错**，不静默放行）。
- `period` 值同时接受 `1分钟K线`/`日K线` 与 `1m`/`daily`。
- 查不到该股某个周期的条目 → 视为非 ok → 拒绝该股。

> **⚠️ 已知不确定项**：`export_log.csv` 的真实列名来自上游 spec §1.4 的记录（`first_time/last_time/rows/status/period`），本会话**无法挂 SMB 逐字核对**。上面的候选集设计保证：真列名若不在候选集内，Plan 4 挂载时会**明确报错**，而不是静默跳过这道门。

### P3-D4：B1 写入原子性——一只股一个事务

`write_qmt_stock(dsn, stock_code, stock_name, bundle)` 在**单个 asyncpg 事务**内：

```
LOCK TABLE klines, stock_coverage IN ROW EXCLUSIVE MODE
  → D8a schema 守卫（沿用现有，另加 to_regclass('stock_coverage') IS NOT NULL 断言）
  → stocks UPSERT
  → 6 × klines executemany UPSERT（沿用现有 _KLINE_INSERT）
  → stock_coverage UPSERT（ON CONFLICT (stock_code) DO UPDATE）
COMMIT
```

这既是「导入本身不留半成品」的要求，也是 P3-D5 快照读能成立的**前提**——只有写方原子，读方的一致快照才有意义。

`dropped_1m_dates` 写 ISO 日期字符串 JSON 数组（`json.dumps([d.isoformat() ...])`），与 `_fetch_dense_coverage` 的解析对称。

> **观察（不改变设计）**：D10-(c) 对称日期集门要求 dense 跨度内 1m 日期集 == 日线日期集，所以**跨度内部**不可能存在 dropped 日——真出现即整只股被拒。`dropped_1m_dates` 因此在被接受的股上实际恒为 `[]`。仍**如实写入** `compute_dense_coverage` 的结果，不硬编码空数组：门的语义与存储的语义解耦，将来放宽门时存储不需要跟着改。

### P3-D5：B2 快照一致性 = 单个 `REPEATABLE READ READ ONLY` 事务包住 7 次读

`generate_one_training_set` 里 `_fetch_dense_coverage` + 6 次 `_fetch_period_bars` 移入同一个只读可重复读事务；事务提交后再做 `_fetch_existing_starts`、取 advisory lock、锁内 `_exists_start`、写 zip、登记。

- **为什么 `_fetch_existing_starts` / `_exists_start` 必须在快照外**：它们要的是「此刻最新已提交」的登记状态。若被冻在旧快照里，Plan 2b R2 刚修好的「锁内先查、后写」会重新变成 stale 检查。
- **早退不受影响**：coverage 行不存在时仍在读第一条语句后就抛 `GenerateSkipException`，六周期全量读不会发生。

**否掉的替代方案**：

| 方案 | 否掉理由 |
|---|---|
| B：给 `stock_coverage` / `klines` 加 import 版本号，B2 要求六份 klines 版本一致 | klines 要么逐行带版本（DDL 膨胀 + 再 bump 一次 `CONTRACT_VERSION`），要么按 (stock, period) 存一张版本表；且读多张表的版本仍需事务保证版本本身一致 —— 用更大代价换同一个不变量 |
| C：B1 导入与 B2 读取共用 `B2_GENERATION_LOCK_KEY` | 会把 B2 的锁重新提到六周期全量读之前，抹掉 Plan 2b R1 刚做的「锁下沉」；且让整轮 sweep 与任意导入完全串行 |

### P3-D6：CLI 形态

`import_csv.py` 现有 CLI 保留不动（通用 CSV 路径仍有测试与调用者），新增互斥的 QMT 模式：

```
python import_csv.py --qmt --input <QMT 导出根目录> --stock 000001.SZ \
                     [--export-log <path>] --dsn <DSN>
```

- 在 `--input` 下**递归 glob** `{code}_*_1分钟K线_前复权.csv` 与 `{code}_*_日K线_前复权.csv`（对导出目录层级不敏感）；命中数 ≠ 1 → 报错退出。
- `stock_name` 从文件名解析（`parse_qmt_filename`），不需要 `--name`。
- `--qmt` 与 `--period` 互斥（QMT 模式的周期集由合成层决定）。
- 被 D9/D10 拒绝 → 打印 `reason` 并以**退出码 2** 结束，**一行都不写**；成功 → 打印每周期行数 + 覆盖带 + 退出码 0。

### P3-D7：`volume` 单位不做换算

QMT 源 `volume` 单位是「手」。本 plan **原样入库**，不乘 100。理由：(1) D10 值对账是 1m 聚合 vs 日线，两边同源同单位，换算不影响门；(2) 换算属于展示层口径变更，会影响 iOS 已有显示与既有 CSV 导入路径的一致性，**不属于 Plan 3 的问题**。如需统一单位，另开聚焦改动。

---

## 3. 架构（数据流）

```
QMT 导出目录
  ├─ {code}_{name}_1分钟K线_前复权.csv  ┐
  ├─ {code}_{name}_日K线_前复权.csv     ├─ parse_qmt_csv（剥 BOM / 打包整数 → Unix 秒）
  └─ export_log.csv                     ┘   + parse_export_log（status 门）
        │
        ├─ clean(df_1m) / clean(df_daily)          ← 丢 NaN/非正价/非有限/high<low + 去重 + 升序
        │
        ├─ reconcile_sources(...)                  ← D10 四门，任一不过 → 整只股拒绝
        │
        ├─ build_intraday(df_1m)  → 3m/15m/60m（只保留 dense 完整日，D9(a)）+ DenseCoverage
        ├─ resample_calendar(df_daily, weekly/monthly)
        └─ df_daily 本体 → daily
                │
                └─ compute_indicators 逐周期 → to_kline_records
                        │
                        └─【单事务】stocks + 6×klines + stock_coverage  ── COMMIT
                                        │
                                        ▼
        B2 generate_one_training_set：【REPEATABLE READ READ ONLY 事务】
              coverage + 6×klines 一次快照读  →  build_training_windows
        （事务外）existing_starts → advisory lock → 锁内 _exists_start → 写 zip → 登记
```

---

## 4. 组件设计

### 4.1 `backend/qmt_ingest.py`（新，纯函数，无 asyncpg）

- `parse_export_log(path) -> dict[(code, period), str]`（P3-D3）
- `build_stock_import(df_1m, df_daily, *, stock_code, stock_name, status_1m, status_daily) -> ImportBundle`（P3-D1/D2）
- `class QmtIngestRejected(Exception)`：携带机器可读 `reason`
- 内部顺序：`clean` → `reconcile_sources`（含 status 门）→ `build_intraday` → `resample_calendar` ×2 → 逐周期 `compute_indicators` → `to_kline_records`

拒绝时**不做任何部分产出**（不返回「已经算好的那几个周期」）。

### 4.2 `backend/import_csv.py`（改，薄壳）

- `_assert_klines_price_columns_double` **原样保留、不改签名不改语义**（既有通用 CSV 路径与其测试继续用它）；QMT 路径**另加**一条 `_assert_stock_coverage_exists`（`to_regclass('stock_coverage') IS NOT NULL`），在同一事务内紧随其后调用。防目标库未跑 migration 0004 时 klines 写成功、coverage 写失败 → 事务回滚但报错信息晦涩。**只加不改**，符合「外科手术式改动」。
- 新 `write_qmt_stock(dsn, stock_code, stock_name, bundle) -> dict[period, int]`（P3-D4）。
- CLI 新增 `--qmt` 分支（P3-D6）。

### 4.3 `backend/generate_training_sets.py`（改，仅读路径）

`generate_one_training_set` 中把 coverage + 六周期读包进 `conn.transaction(isolation="repeatable_read", readonly=True)`（P3-D5）。**其它逻辑（交叉校验、窗口选择、锁、写入、登记）一字不动。**

---

## 5. 测试与验证

### 5.1 host pytest（纯函数层，`backend/tests/test_qmt_ingest.py` 新建）

- **D10 四门各一条拒绝测**：export_log 非 ok / 日线尾部截断（`daily_not_cover_dense`）/ 跨度内日期集不等（`date_set_mismatch`）/ OHLCV 超容差（`ohlcv_mismatch`）→ 均抛 `QmtIngestRejected` 且 `reason` 精确匹配，**且断言零产出**。
- **D9(a)**：某日缺 1 根 1m → 该日**全部**盘中周期零行（不是只丢缺的那一桶），且该日不在 `dense_dates`。
- **清洗顺序**：某日一行价格为 0（被 `clean` 丢）→ 该日落入非 dense，而非伪装成完整日。
- **export_log 解析**：候选标识列各命中一例；候选全不命中 → 抛 `QmtSchemaError`；查不到条目 → 拒绝该股。
- **coverage artifact 值**：`dense_day_count == len(dense_dates)`，端点 == 首/末 dense 日。
- **周期分工**：`daily` 行数 == 日线 CSV 清洗后行数（证明未按 1m 跨度裁剪）；`monthly`/`weekly` 不含 partial 当期。

### 5.2 host pytest（写库壳 / 读路径，假 asyncpg conn）

- `write_qmt_stock`：断言**所有写语句都发生在同一个 transaction 上下文内**；断言 schema 守卫在任何 INSERT 之前执行；守卫失败 → 零 INSERT。
- `stock_coverage` UPSERT 参数逐值断言（含 `dropped_1m_dates` 的 JSON 字符串形状与 `_fetch_dense_coverage` 解析对称——**同一条数据走一遍写再走一遍读**，而不是各测各的）。
- B2 读路径：断言 `conn.transaction` 以 `isolation="repeatable_read", readonly=True` 打开，且 coverage + 6 次 klines 读全部落在该事务内、`_fetch_existing_starts` 落在事务外。

> 假件的界限：假 conn **不可能**证明 PG 的 RR 快照语义（这正是 `feedback_verify_foundational_infra_assumption_real_not_fake` 的坑）。假件测的是「我们确实按预期参数开了事务、读全在事务内」；语义本身由 §5.3 的真 PG 脚本证明。

### 5.3 真 PG 一次性验证脚本（`backend/scripts/verify_repeatable_read_snapshot.py`）

参照现有 `backend/scripts/verify_advisory_lock_reentrancy.py` 的形态（docker `postgres:15.12` + asyncpg，一次性、不进 CI 套件）。四条断言：

1. RR 只读事务内第一次读之后，另一连接 INSERT klines + UPDATE stock_coverage 并 **COMMIT**；同事务内第二次读**仍看到旧值**（coverage 与 klines 都验）。
2. 同一时刻，**事务外**的第三个连接**看得见**新值 —— 证明写方真的提交了（防「写方其实没写成，快照测试空转全绿」）。
3. `SHOW transaction_isolation` 在该事务内 == `repeatable read`；事务内尝试写 → 被 PG 拒（证明 `readonly=True` 真生效）。
4. B1 导入事务**未提交**时，外部连接**既看不到 coverage 行也看不到 klines 行**；提交后**同时**看到（证明 P3-D4 的原子性）。

脚本输出逐条 PASS/FAIL，任何一条 FAIL 即非零退出。

### 5.4 端到端出货集成测（`backend/tests/test_qmt_e2e_generation.py` 新建）

`QMT fixture CSV → build_stock_import → 假 conn 充当存储 → 真 generate_batch → 断言 ≥1 个 zip 产出且 training_sets 有登记行`。

- fixture **不进仓**：dense 1m 一年 ≈ 242 交易日 × 241 根 ≈ 5.8 万行（**估算**，实施时以实际生成为准），落盘约数 MB。用测试内**生成器函数**造 DataFrame / 临时 CSV，仓里只保留现有小样本 `backend/tests/fixtures/sample_1m.csv` 供解析级测试。
- fixture 跨度须同时喂饱：B2 的 8 个前向月 + 盘中 before-context（3m/15m/60m 各 150 根 → 最长 60m 需 ~38 个交易日）+ 日线/月线 before-context（monthly 全取 → 日线需数年历史）。**日线造多年、1m 只造近一年**，正是真实 QMT 的形状。
- 断言产出 zip 的 `content_hash` 与磁盘字节一致（沿用现有 helper），并断言 `generate_batch` 返回的成功计数 ≥1。

### 5.5 mutation 验证（强制）

每一条新增的门测试必须做 mutation：把被测的门改坏（如把 `date_set_mismatch` 判据改成恒 True、把事务隔离级别改回默认、把 coverage 写入注释掉）→ 对应测试**必须挂**。由控制者本人复验，不采信 subagent 自证。

### 5.6 闸门纪律

- 所有 pytest 用仓库根 `.venv`（Python 3.11）：`cd backend && ../.venv/bin/python -m pytest tests/ -q`。host `python3` 是 3.14，跑 pandas 会段错误。
- 任何 `cmd | tail/grep` 都加 `set -o pipefail` 或改 `cmd; echo EXIT=$?`；判绿读输出内容，不看 exit code。
- 每条闸门/git 命令同时打印 `branch` + `HEAD`。
- 基线：`main` `08d70d2` = **`255 passed`（本文写作时已实测确认，非从记忆推断）**。任何 Task 结束时测试数只增不减，且 0 failed / 0 skipped。CI 禁 skip，不得新增任何 `skip`/`xfail`。

---

## 6. 验收标准（spec 级；非-coder 验收清单在 plan 阶段出）

1. 用 fixture QMT CSV 跑 B1 QMT 模式 → `stock_coverage` 有该股一行，端点/`dense_day_count`/`dropped` 与 `compute_dense_coverage` 一致。
2. 同一份数据接着跑 `generate_batch` → **真产出 ≥1 个训练组 zip**，且 `training_sets` 有登记行。这是 Plan 3 的核心验收项，也是 Plan 2 无法做到的那一条。
3. D10 四门与 D9(a) 各有一条拒绝路径被测试覆盖，拒绝时数据库零写入。
4. B2 的 coverage + 六周期读在同一个 RR 只读事务内（假件测参数 + 真 PG 脚本测语义，两者都绿）。
5. B1 导入事务原子：未提交时外部看不到任何部分状态（真 PG 脚本第 4 条）。
6. 后端 pytest 全绿、零 skip；PR CI 全绿。

---

## 7. 风险 / 开放项

| 风险 | 处置 |
|---|---|
| `export_log.csv` 真实列名未逐字核对 | P3-D3 候选集 + fail-closed 报错；Plan 4 挂 SMB 时逐字核对并收窄 |
| 端到端 fixture 体量大、测试变慢 | 生成器造数据、不落仓；若单测超时明显，可把 1m 跨度收到刚好喂饱 B2 的最小天数（实施期实测决定，不预先猜） |
| `PERIOD_BEFORE_CAP` 与真实 1m 只有一年 → 真数据可能候选稀疏 | 属 Plan 4 真跑时的产能问题；Plan 3 只需证明通路，产能低会在 Plan 4 的储备池替补机制里显性化 |
| RR 事务拉长了 B2 单股读的事务时长 | B2 是单用户内网批处理，长只读事务不冲突；且早退路径仍在第一条语句后返回 |

---

## 8. 流程

brainstorming（本文）→ codex spec review → writing-plans → codex plan review → subagent-driven 实施（Sonnet high）→ host pytest 三绿 → requesting-code-review → whole-branch codex（`--scope branch-diff`）→ PR（user push/merge）。

**PR 切分（每 PR ≤3 子项 ≤500 行）：**

| PR | 内容 | 子项 |
|---|---|---|
| **3a** | `qmt_ingest.py` 纯装配层 + `test_qmt_ingest.py` | 2 |
| **3b** | B2 RR 只读事务 + `verify_repeatable_read_snapshot.py` + 假 conn 断言测 | 3 |
| **3c** | B1 写库壳（原子事务 + coverage UPSERT + schema 守卫扩展）+ CLI `--qmt` + 端到端出货集成测 | 3 |

3b 排在 3c 之前，是为了让 3c 的端到端测直接跑在最终读路径上，不必写完再改。若 3c 实测超 500 行，把 CLI 拆成独立的 3d。

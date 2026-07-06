# QMT 真实数据接入 + 100 股 pilot 训练组生成 设计（2026-07-06）

> 把 QMT 导出的真实沪深北前复权 CSV（1m 近一年 + 日线全历史）接入现有 B1/B2 后端管线，生成首批 100 只股票的训练组 `.zip`。
> 本设计经 brainstorming 收敛（真实样本已通过 SMB 挂载逐字核对）。评审通道 = 真 Codex（`codex-attest.sh`）。基线：`main` `d96b1f4`。
> 来源：`kline_trainer_modules_v1.4.md §四 B1/B2` + `kline_trainer_plan_v1.5.md §6.4/§8.3` + 现有 `backend/import_csv.py` / `backend/generate_training_sets.py` / `backend/sql/schema.sql` / `backend/sql/training_set_schema_v1.sql`。
> 相关约束：[[project_app_public_release_intent]]（公开发布 → 数据耐久性标准，勿静默截断）。

## 0. 目标 / 范围 / 约束

**目标**
- 把 QMT 真实前复权数据接入现有 B1（导入 PostgreSQL `klines`）→ B2（切训练组 SQLite + zip + 登记 `training_sets`）管线。
- 现有 B1 **不认** QMT 的真实格式（编码/时间格式/中文周期标签/只给 1m+日线两种周期），本设计新增**规整层**+**合成层**补齐，接到现有 `clean`/`compute_indicators` 之前。
- 产出首批 **100 只股票**的训练组 `.zip`，可喂给 App / B3 租借链路验证端到端。

**范围**
- 新写：QMT 规整层（parse/normalize）、通用合成层（resample，按交易时段/交易日历）、pilot 运行脚本。
- 改：`backend/sql/schema.sql` + **新增 `backend/sql/migrations/000X_*/{forward,rollback}.sql`**（OHLC `DECIMAL→DOUBLE`，M0.1 A 类 → bump `CONTRACT_VERSION` 1.8→1.9）、`ios/.../Models.swift` + `ModelsTests`（**仅版本常量**）、`docs/governance/m01-schema-versioning-contract.md`（矩阵 + bump 记录，含校正 stale cell）、`backend/generate_training_sets.py`（`select_start_index` 覆盖带约束 + 候选 bounded retry、D9 完整性）、`backend/import_csv.py`（接规整/合成层、`ticket_index` 停写留列、1m 不入库、D8a 断言、D10 对账）。
- 复用不动：`compute_indicators`、`clean`、B2 装配（窗口/`global_index`/`end_global_index`）、`zip_and_hash`、`training_sets` 登记逻辑主体。

**公共契约变更声明（如实，非「无变更」）**
- **价格 `klines.open/high/low/close` `DECIMAL(10,2)` → `DOUBLE PRECISION`（D1）是 M0.1 A 类 DDL 变更（"改类型"），必须走治理路径（codex R12-F1，我原"无迁移/不 bump"违反 M0.1）**：(a) **bump 顶层 `CONTRACT_VERSION`**（权威当前值 = `Models.swift` `"1.8"` → `"1.9"`；同步更新 `Models.swift` 常量 + `ModelsTests` 期望 + `docs/governance/m01-schema-versioning-contract.md` 矩阵顶层 cell 与 PG schema migration id cell + 加 bump 记录——**注：m01 矩阵顶层 cell stale 为 `1.7`，一并校正**）；**仅版本常量变，reader 逻辑不变**（`KLineCandle` 本就 `Double`、训练组 SQLite 本就 `REAL`，端到端浮点、精度读取无关）。(b) **提供 PostgreSQL migration**：`backend/sql/migrations/000X_<name>/forward.sql`(ALTER COLUMN TYPE DOUBLE PRECISION) + `rollback.sql`(ALTER 回 DECIMAL(10,2)，显式标注 rollback 丢精度)，符合 m01 §Migration Rollback（B3 owner 格式）。(c) 同步更新 `schema.sql` fresh baseline。pilot 对专用一次性库应用更新后 `schema.sql`（D8b）；migration 供已部署库前向迁移。`amount`(DECIMAL(16,2))、指标列(DECIMAL(10,4)/(10,6))、训练组 `PRAGMA user_version`(`1`) **不变**（无额外 DDL 触发）。
- **`ticket_index`（D3）改为"保留列、停止写入"（非删列，codex R12-F1）**：列删除是 m01 §Migration Rollback"**不可逆项，不允许放进 Wave 1+ migration**"→ **保留 `ticket_index INTEGER` 列不动**（对该列零 DDL），仅移除 Python 侧 `compute_ticket_index` + 从 `_KLINE_INSERT` 去掉该列（新行该列 NULL）。已 grep 核实无下游消费者（B2 `_KLINE_SELECT_COLS` 不含、iOS 零 `.swift` 引用），留空列无害且合规。

**非目标 / Non-Goals**
- **不生成也不存储** 1m / 5m / 30m / 年线到训练组——合成层写成周期无关的通用代码，但本期产物只含 `3m/15m/60m/daily/weekly/monthly` 六周期（[[project_app_public_release_intent]] 之后加周期 = 改配置 + 重新生成训练组，训练组是不可变快照）。
- **1m 逐分钟揭示**是独立决策（会改 `MIN_PERIOD`/`global_index` 语义 + 全量 5000 股上亿行存储），不在本期。
- 不做 App 内周期选择 UI（后续单独 RFC）。
- 不做 PG 迁 NAS/服务器与 `file_path` 相对化（本期本机 Docker、绝对路径；搬迁+相对化=未来独立聚焦改动，见 §7/D5）。
- 不做前复权基准的增量刷新/再复权（前复权值为导出日 2026-07-03 快照，本期按快照用）。
- 不做 B3/B4 全量调度与真机租借压测（本期只产出 `.zip` + 登记）。

**约束**
- 规整/合成层为**纯函数**（不碰 DB），host `pytest` 全测；薄 DB 壳 + CLI 沿现有 D14 惯例不单测（B3/NAS scope）。
- 前复权价为 `float64`、**禁止四舍五入到 2 位**（会压塌老 K 线 + 丢复权精度，违反耐久性约束）。
- 合成**严格按交易时段分段**（禁跨午休 11:30↔13:01、禁跨日），周/月**按交易日历分组**（含假期的周/月仍为一根）。
- **所有交易日期提取统一走单一 helper `trading_date(epoch) = datetime.fromtimestamp(epoch, ZoneInfo("Asia/Shanghai")).date()`（codex R8-F1）**：D2 dense 日期集、D9 逐日分组、D10 重叠日匹配、`resample_calendar` 周/月分组**全部**经此，**禁 UTC/naive 日期提取**——沪-午夜 epoch 用 UTC 转会滑到前一日、与盘中 `0933` 的日期错位 → 误杀/漏检。
- 负向 grep 断言用 `if/exit 1` 非 `! grep`（[[feedback_acceptance_grep_anchoring]]）。
- 本地三绿 ≠ CI 绿；合并后 `gh run watch` 确认（[[feedback_swift_local_ci_toolchain_strictness]]）。本期主要为 Python 后端，CI = `pytest`。

## 1. 现状（基线 d96b1f4，已核实）

### 1.1 现有 B1 `import_csv.py`
- `REQUIRED_COLUMNS = (datetime, open, high, low, close, volume)`；`parse_csv` 用 `pd.read_csv(path)`（**默认 utf-8，不剥 BOM**）。
- `_to_unix_seconds`：数值列 → `astype("int64")` 直接当 Unix 秒；字符串列 → `pd.to_datetime(..., utc=True)`。
- `_discover_period`：从文件名找 `_1m`/`_daily` 等英文周期子串。
- 假设数据源**每周期独立 CSV**，`compute_ticket_index` 把非-1m 周期 `searchsorted` 映射到 1m 基准。
- 写 `stocks` + `klines`（含 `ticket_index`）。

### 1.2 现有 B2 `generate_training_sets.py`
- `PERIODS = (monthly, weekly, daily, 60m, 15m, 3m)`，`MIN_PERIOD = "3m"`。
- `select_start_index(monthly_datetimes, rng)`：月线 `<39` 根抛 `GenerateSkipException`；否则 `rng.randint(30, n-9)`。**在全历史月线里随机选，无时间边界**。
- `monthly_after_end`：起点起 8 根月 K（含起点）最后一根 datetime = 前向窗口终点。
- `select_period_window`：每周期取起点前 `min(pivot, cap)` 根 + `[start, after_end]` 内所有根；per-period 硬校验 `before≥30 & after≥1`，否则 skip。
- `assign_global_indices`：`3m` 升序赋 `global_index`；所有周期 `end_global_index = bisect_right(3m_dts, upper)-1`。
- `_register_training_set`：`file_path` 存 `str(gts.path)`（**当前为 `--output` 传入路径，若绝对即绝对**）；`uq_stock_start UNIQUE(stock_code,start_datetime)`。

### 1.3 主库 schema（`backend/sql/schema.sql`，v1.4）
- `klines.open/high/low/close DECIMAL(10,2)`、`amount DECIMAL(16,2)`、`ma66/boll_* DECIMAL(10,4)`、`macd_* DECIMAL(10,6)`、`ticket_index INTEGER`、`UNIQUE(stock_code,period,datetime)`。
- `training_sets`：`file_path VARCHAR(255)`、`content_hash CHAR(8)`、lease 三列、`uq_stock_start`。

### 1.4 QMT 真实数据格式（SMB 挂载逐字核对 · 2026-07-06）
数据源：`//agate@192.168.5.151/QMT_Export/front_ratio_cn_stocks_ab_bj/`，导出脚本 `export_all_front_ratio_stocks_only.py`（`DIVIDEND_TYPE="front_ratio"` 前复权、`FIELDS=[open,high,low,close,volume,amount]`、`encoding="utf-8-sig"`、`index_label="time"`）。

- **目录**：`1分钟K线_前复权/`、`日K线_前复权/`。
- **文件名**：`{code}.{EX}_{name}_{label}_前复权.csv`，`EX∈{SH,SZ,BJ}`、`label∈{1分钟K线,日K线}`、`name` 已 sanitize（`*`→`星`，非法字符→`_`，去空白，可含全角字符如 `万科Ａ`）。例：`000001.SZ_平安银行_1分钟K线_前复权.csv`。
- **列**：`time,open,high,low,close,volume,amount`；**编码 utf-8-sig（带 BOM）** → 裸 `pd.read_csv` 会把表头读成 `﻿time`。
- **复权**：前复权 `float64`，小数一长串（`11.790828206557329`）；老数据被缩得很小（平安银行 1991 年前复权价 `0.61...`）。**2 位截断会压塌老 K 线**。
- **时间**：`1m = YYYYMMDDHHMMSS`（`20260703093000`）、`日线 = YYYYMMDD`（`19910105`），**北京时间(UTC+8) naive 打包整数**——非 Unix 秒、非带分隔符字符串。裸走现有 `_to_unix_seconds` 会把 `20260703093000` 当成 Unix 秒（公元 64 万年）。
- **volume 单位 = 手（100 股）**（实测 `7895手×100×10.29 = 8,123,955 = amount` 分毫不差）；**amount = 元**（含浮点噪声如 `11215071.000000002`）；含 0 成交量的平盘分钟（收盘前 `O=H=L=C`、`vol=0`）。
- **覆盖**：1m ≈ 正好 1 年（服务端截断，如 2025-07 → 2026-07，~58k 行/年）；日线全历史（平安银行到 1991）。
- **元数据白送**：`stock_universe_with_name.csv`（列 `exchange,name,note,source_sector,stock`，现成股票池）；`export_log.csv`（每文件 `first_time/last_time/rows/status/period` → 不开文件即得每股日期范围）。

### 1.5 交易时段真值（1m，逐字核对完整交易日 20260703）
- **完整日 241 根**：上午 `09:30:00`（开盘集合竞价，`O=H=L=C`）→ `11:30:00` 共 **121** 根；下午 `13:01:00` → `15:00:00`（收盘集合竞价）共 **120** 根。
- **时间戳标的是该分钟的收盘时刻**（`09:31` 根 = 09:30–09:31 成交；`09:30` 根 = 开盘集竞；`15:00` 根 = 收盘集竞）。
- 午休断口在 `11:30:00` 与 `13:01:00` 之间；停牌/稀疏股 1m 可能有缺口。

## 2. 决策

| # | 决策 | 取舍 |
|---|---|---|
| **D1** | `klines.open/high/low/close`：`DECIMAL(10,2)` → `DOUBLE PRECISION`（**M0.1 A 类 DDL，走治理路径：bump `CONTRACT_VERSION` 1.8→1.9 + PG migration forward/rollback + 更新 m01 矩阵，R12-F1**）。`amount`(`DECIMAL(16,2)`) 与指标列(`DECIMAL(10,4)/(10,6)`+`round(4/6)`)**不变**——仅在全精度 `close` 上重算。 | 前复权 float64 价格无损；amount/指标不动=最小改面。reader 逻辑不变（端到端本就 Double/REAL），仅版本常量 bump（§0）。 |
| **D2** | `select_start_index` 加**每股 1m 覆盖带约束**：起点仅在「前向 8 完整月窗口 `[start, after_end]`（`after_end`=第 8 月末，§4.4）的**每个交易日期都在该股 dense 完整 1m 交易日期集内**」的月线里选。**按交易日期比对，非 raw 时间戳**（月/日标午夜 vs 3m 标盘中，raw 比会误杀全部候选，codex R7-F1）。 | 消灭随机起点大量落空 + 杜绝盘中中途断货的次品训练组。约束下每股约 3–4 个可选起点，100 股够凑 100 组（`uq_stock_start` 保唯一）。 |
| **D3** | 合成层写成**周期无关通用**；本期只生成 `3m/15m/60m/daily/weekly/monthly`。**1m 不入主库**（仅作合成源），`3m` 为最细周期。**`ticket_index` 保留列、停止写入**（非删列——m01 禁不可逆迁移；R12-F1）。 | 通用代码 → 将来加周期=改配置（YAGNI）；1m 不入库省上亿行；留空 `ticket_index` 列合规无害（无消费者，§0）。 |
| **D4** | `stocks.code` 保留交易所后缀（`000001.SZ`，9 字符 ≤ `VARCHAR(10)`）。 | 消歧（`000001.SZ` 平安银行 vs `000001.SH` 上证指数）、与 `stock_universe` 一致。 |
| **D5**（codex R2-F2 修正） | pilot **保持 `training_sets.file_path` 绝对路径**（现状 B3 `routes.py` 下载、scheduler、`backfill` 均按绝对 `Path(file_path)` 读）。**不在 pilot 半途改相对**（只改 B2 写、不改 3 个读点 = 下载 404）。 | 相对化是**跨 B2 写 + B3/scheduler/backfill 读的横切改动 + 存量行迁移**，归入未来 NAS 搬迁的独立聚焦改动（§7），不塞 pilot（YAGNI + 防半成品）。搬迁易度仍由 config 驱动 DSN 保证（原 §0/移机答复不变）。 |
| **D6** | pilot：本机 Docker Postgres（复用 `backend/docker-compose.yml`）；100 只从 universe **按市场分层随机抽**（seed 可复现），SH/SZ/BJ 都覆盖；经 SMB 挂载拉这 100 只的 1m+日线；**每股至多 1 组，验收按各市场 distinct 成功股数**（非 ZIP 总数，R10-F2）。 | 最省事、可复现；覆盖三市场以暴露格式差异；distinct 股数验收防凑数掩盖失败。 |
| **D7** | 规整层为**新增 QMT 专用层**，产出与现有 `clean` 入参兼容的 DataFrame（列 `datetime/open/high/low/close/volume/amount` + Unix 秒），接现有 `compute_indicators`。 | 隔离 QMT 特有的 BOM/时区/文件名/中文标签解析，不污染下游通用逻辑。 |
| **D8**（codex R1-F1 / R2-F1） | (a) **写库前 schema fail-closed 断言**：import 任何 INSERT 前查 `information_schema.columns` 断言 `klines.open/high/low/close = double precision` 且无 `ticket_index`，不符即中止（非静默插入）。(b) **destructive reset 防误删护栏**：pilot 只对**专用一次性库**（库名必须匹配前缀 `kline_pilot_`）操作；任何破坏性动作（`CREATE/DROP DATABASE`、重建）需**显式 `--reset`** 且目标库名匹配前缀，否则**拒绝**（**绝不 DROP 任意/共享库**）；smoke 断言非-pilot DSN/库名在任何 DDL 前被拒。 | 防 R1-F1 陈旧库静默截断；防 R2-F1：光靠"本地新库"叙述性意图不够，跑错 `DATABASE_URL`/共享卷会 `DROP` 掉 stocks/klines/training_sets（含 lease 状态与库存）。三重 fail-closed = 专用库前缀 + 显式 flag + 写前断言。 |
| **D9**（codex R1-F2 / R3-F2 / R4-F1） | **两处强制、B2 可判**：(a) **分钟级 @ B1**（1m 在手）——每盘中桶实测 1m 成员数须 == §4.2 应有数；**某交易日任一桶不足 → 该日盘中不入库（drop+日志）**，DB 无半成品桶；dense 1m 覆盖带 = 逐日完整的连续日范围。(b) **B2 硬门**（无原始 1m）——以**日线（交易日真值）**逐日校验：落在**选中盘中全跨度 `[首个 3m 日, after_end]`（含 before-context）**内的每个交易日 DB 盘中桶数须**精确等于** `80/16/4`，任一日不足 → `GenerateSkipException`。`coverage_ratio`（报告）+ 缺日进输出。 | 防 R1-F2（缺整天）+ R3-F2（桶内缺分钟）+ **R4-F1（1m 出库后 B2 无从判分钟级）**+ **R6-F1（before-context 洞被静默回填）**：分钟级在 B1 判；B2 靠"盘中全跨度每交易日桶数精确=期望"的 provenance-free 硬门兜住。真停牌（无日线）不误伤。 |
| **D10**（codex R6-F2 / R10-F1 / R11-F1） | **源一致性对账门（B1）**：import 某股前——(a) `export_log` 两文件 `status=='ok'`；(b) **端点覆盖**：`日线起 ≤ dense-1m 起 且 日线止 ≥ dense-1m 止`，否则（日线尾部截断/陈旧）**skip**；(c) **对称日期集相等**：**整个 dense-1m 跨度**内 dense-1m 日期集 **==** 日线日期集，任一方缺日 → skip；(d) 该日期集上 1m 聚合日 OHLCV vs 日线 bar 容差内一致（价格 `1e-6`、量精确）。任一不满足 → **fail-closed skip 该股** + 日志。 | 防 R6-F2（不同复权/陈旧→值不一致）+ R10-F1（只查交集放过缺行）+ **R11-F1（截断"共享窗口"掩盖 stale 尾部）**：1m 与日线两独立源，日/周/月从日线、盘中从 1m；须**端点覆盖 + 日期集相等 + 值一致**三门。 |

## 3. 架构（数据流）

```
Windows SMB · front_ratio_cn_stocks_ab_bj/{1分钟K线_前复权, 日K线_前复权}/*.csv
      │  ① pilot 脚本：universe 分层随机抽 100 → 按文件名拉这 100 只的 1m+日线
      ▼
┌─ 规整层 qmt_normalize  ★新写（纯函数）──────────────────────────┐
│  parse_qmt_csv:  encoding=utf-8-sig 剥 BOM；列 time→datetime      │
│  parse_qmt_datetime:  YYYYMMDDHHMMSS / YYYYMMDD @Asia/Shanghai → Unix 秒 │
│  parse_qmt_filename:  {code}.{EX}_{name}_{label} → (code, name, src_period) │
│  → 复用现有 clean（丢 NaN/非正价/high<low/去重/升序），价格不 round     │
└──────────────────────────────────────────────────────────────────┘
      ▼
┌─ 合成层 resample  ★新写（纯函数，周期无关）─────────────────────┐
│  resample_intraday(df_1m, period∈{3m,15m,60m}):                   │
│     按交易时段分段(09:30–11:30 / 13:01–15:00)、禁跨午休/跨日、    │
│     桶对齐 session 起点、label=桶收盘时刻；OHLC=首/高/低/尾，vol/amount=Σ │
│  resample_calendar(df_daily, period∈{weekly,monthly}):           │
│     按交易日历分组(周=所属日历周, 月=所属日历月)；OHLC/Σ 同上     │
│  （1m 本身不产出到入库集合；3m 为最细）                           │
└──────────────────────────────────────────────────────────────────┘
      ▼
  compute_indicators  ♻复用（每周期 MA66/BOLL(ddof=0)/MACD(bar×2)，在全精度 close 上算，仍存 round(4/6)）
      ▼
  写 PG klines  ♻复用写库壳（OHLC→DOUBLE；amount/指标列不变；周期集合 6 个；无 ticket_index）
      ▼
  B2 generate_training_sets  ♻复用；select_start_index 加 1m 覆盖带约束(D2)+覆盖完整性校验(D9)；file_path 绝对(D5)
      ▼
  产物：100 个训练组 .zip + training_sets 登记
```

## 4. 组件设计

### 4.1 规整层 `qmt_normalize`（新写，纯函数）
- `parse_qmt_csv(path) -> DataFrame`：`pd.read_csv(path, encoding="utf-8-sig")`（剥 BOM）；校验列 `{time,open,high,low,close,volume,amount}`，缺列抛 `CsvSchemaError`；列 `time` 重命名 `datetime`。
- `parse_qmt_datetime(series, src_period) -> Int64 Unix 秒`：按位数判定格式（14 位 `YYYYMMDDHHMMSS` / 8 位 `YYYYMMDD`）→ 以 `Asia/Shanghai`（UTC+8）本地化 → Unix 秒。**不用** `utc=True` 直接解析 naive（会当 UTC 偏 8 小时）。
- `parse_qmt_filename(name) -> (code, stock_name, src_period)`：正则 `^(?P<code>\d+\.(SH|SZ|BJ))_(?P<name>.+)_(?P<label>1分钟K线|日K线)_前复权\.csv$`；`label` 映射 `1分钟K线→"1m"`、`日K线→"daily"`（源周期，仅 1m/daily 两种）。
- `trading_date(epoch) -> date`（**共享 helper，codex R8-F1**）：`datetime.fromtimestamp(epoch, ZoneInfo("Asia/Shanghai")).date()`。**所有**日期分组/比对（D2 dense 集 / D9 逐日 / D10 重叠日 / `resample_calendar` 周月分组）的**唯一入口**，杜绝 UTC 日期错位。
- 产出交给现有 `clean`（**价格列不 round**；`clean` 逻辑不变，只是入参来自 QMT 规整）。
- **源一致性对账（D10，codex R6-F2 / R10-F1 / R11-F1）**：import 某股前——(a) 查 `export_log` 该股 1m+日线 `status=='ok'`；(b) **端点覆盖门**（R11-F1）：要求**日线完整包住 dense-1m 跨度**——`trading_date(日线起) ≤ min(dense_1m 日期) 且 trading_date(日线止) ≥ max(dense_1m 日期)`，否则（日线陈旧/尾部截断、比 1m 旧）→ **fail-closed skip**（**不能用截断的"共享窗口"掩盖 stale 尾部**——日线本是全历史、理应包住近 1 年 1m）；(c) **对称日期集相等门**：在**整个 dense-1m 跨度**上，dense-1m 交易日期集 **==** 该跨度内日线交易日期集，任一非对称差（1m 有该日日线缺 / 日线有该日 1m 不足）→ skip；(d) 该（已相等）日期集上对账「1m 聚合日 OHLCV」vs「日线 bar」（价格相对 `1e-6`、volume/amount 精确或极小容差）→ 超容差 skip。可选：`export_log` row 数/`last_time` 对交易日历。纯对账逻辑（两 df + 容差）host 单测。
- **不再需要** `compute_ticket_index`（D3 取消）。

### 4.2 合成层 `resample`（新写，纯函数，周期无关）
**周期表（分钟 / 日历）驱动，加新周期 = 加表项：**
```
INTRADAY_MINUTES = {"3m":3, "15m":15, "60m":60}          # 将来加 "5m":5,"30m":30,"1m":1
CALENDAR_RULE    = {"weekly":"W", "monthly":"M"}          # 将来加 "yearly":"Y"
```
- **`resample_intraday(df_1m, minutes)`** — 按 1m 收盘时间戳 `t`（北京 wall-clock）分桶，**严禁跨午休/跨日**（codex R2-F3：精确规则在 spec 定死，非 plan 延后）：
  - 段名义起点：上午 `0930`、下午 `1300`；`session_minutes=120`。周期 `N∈{3,15,60}` 的桶 label（收盘）= `起点 + k·N`（`k=1..120/N`）：上午 `{0930+kN}`、下午 `{1300+kN}`。
  - 成员（按收盘 `t`）：**上午首桶** label=`0930+N`，区间 `[0930, 0930+N]`（**含 09:30 开盘集竞根**，唯一含左端点的桶）；**其余所有桶** label=`b`，区间 `(b−N, b]`。下午无 13:00 根（首根 13:01），首桶 `(1300, 1300+N]` 自然含 `1301…`、无特例。
  - 聚合（成员按时间序）：`open=`首成员 open、`close=`尾成员 close、`high=max`、`low=min`、`volume=Σ`、`amount=Σ`。
  - **确定性 golden（本 spec 定为验收契约）**：完整日 `3m=80 / 15m=16 / 60m=4`；边界桶成员逐值：
    - **3m**：上午首 `0933={0930,0931,0932,0933}`、上午末 `1130={1128,1129,1130}`；下午首 `1303={1301,1302,1303}`、下午末 `1500={1458,1459,1500}`。
    - **60m**：上午 `1030={0930..1030}`(61 根)、`1130={1031..1130}`(60)；下午 `1400={1301..1400}`(60)、`1500={1401..1500}`(60)。
    - **15m**：上午 8 桶（首 `0945={0930..0945}`=16 根、余 15/桶）、下午 8 桶（各 15 根）。
    - 校验恒等式：上午成员合计 **121**、下午 **120**（= 完整日 1m 241）。
  - **分钟级完整性在此强制（B1，1m 在手；codex R4-F1）**：每桶实测 1m 成员数须 == 上面 golden 应有数。**某交易日任一桶不足 → 该日全部盘中周期不入库（drop + 日志），不写半成品桶**。该股 **dense 1m 覆盖带** = 盘中逐日完整的连续日范围（QMT 覆盖-截断的首/末残缺日自然落在带外）。**1m 出库后 B2 已无从判分钟级，故必须在此判**。
  - **不变量（实证 codex R9-F2）**：抽查 `000001.SZ`(活跃) + `000004.SZ`(退市/停牌股) 各 200+ 交易日 → **每个存在的交易日恒 241 根（QMT flat-fill 无成交分钟）**；**停牌 = 整日缺席**（1m 与日线都无该日 → 由"无日线=非交易日"排除、不误判为损坏）；**唯一 partial 日 = 1m 覆盖起点边界日**（如 199 根，dense 带排除）。故"日线在、1m<241"确为拷贝截断/损坏，drop 正确、**不误伤合法停牌**。**pilot 落地时 log 任何"日线在但 1m ∉ {241, 边界日}"的异常日供人工复核**（防抽样外角落；plan 再多抽几只覆盖市场）。
- **`resample_calendar(df_daily, rule)`**：按每个交易日所属**日历周（周一起）/日历月**分组（分组键用 `trading_date`，R8-F1；含假期的周/月仍一根）；OHLC/Σ 同上。
  - **只 emit 完整日历周期（codex R4-F2）**：周期 P 仅当存在**属于 P 之后日历周期的 daily bar**（证明 P 已收尾、数据覆盖到 P 末）才 emit；**丢弃当前 export 期的 trailing 残缺周/月**（export 2026-07-03 → 2026-07 月 K、当周 K 不 emit，避免"看似完整实则残缺"污染快照）。IPO 首周属完整日历周期（该周已收尾、股票只是部分交易日有量）→ 保留。
  - **发射 bar 与边界哨兵解耦（codex R9-F1）**：**丢弃的只是 partial 当期的 emitted bar**；其**周期 open 仍保留在月/周边界哨兵序列**里（供 §4.4 `after_end` 计算），否则丢了 partial July 的 open → 以最新完整月 June 结尾的 8 月窗口没哨兵、选不出来 → 浪费最新完整月、候选再缩。
  - **时间标签 = OPEN（codex R3-F1）**：该周期 bar 的 `datetime` = **组内第一根交易日的 datetime**（daily 沿用 QMT 原生午夜 `YYYYMMDD→D 00:00`；weekly/monthly 用组内首交易日的午夜）。与 `assign_global_indices` 的 `[open, 下一根 open)` 语义一致（见 §4.4）。
- 停牌/稀疏容错：段内不足一桶/整段缺失 → 该桶不产出（不补零、不插值）；桶内缺分钟按上面 B1 分钟级完整性处理（drop 日）。

### 4.3 Schema 变更（D1，M0.1 A 类 DDL — 走治理路径，codex R12-F1）
- **改 `klines.open/high/low/close`：`DECIMAL(10,2)` → `DOUBLE PRECISION`**——(1) 更新 `backend/sql/schema.sql` fresh baseline；(2) **新增 PG migration** `backend/sql/migrations/000X_<name>/forward.sql`(`ALTER TABLE klines ALTER COLUMN {open,high,low,close} TYPE DOUBLE PRECISION`) + `rollback.sql`(ALTER 回 `DECIMAL(10,2)`，**显式标注 rollback 丢精度**)，符合 `m01 §Migration Rollback`（forward+rollback 对，B3 owner 格式）；(3) **bump 顶层 `CONTRACT_VERSION` 1.8→1.9** + PG schema sub-version migration id + `Models.swift` 常量 + `ModelsTests` + m01 矩阵（含校正 stale `1.7` cell）+ bump 记录。
- **`ticket_index` 保留列、停止写入**（**非删列**——m01 禁 Wave1+ 不可逆迁移，R12-F1）：`schema.sql` 保留 `ticket_index INTEGER` 列不动；仅 `_KLINE_INSERT` 去掉该列/占位符 + 删 `compute_ticket_index` 及其单测（新行该列 NULL，无消费者）。
- `amount DECIMAL(16,2)`、指标列 `DECIMAL(10,4)/(10,6)` **不变**；`compute_indicators` 的 `round(4)/round(6)` **保留**（全精度 `close` 上重算）；`UNIQUE(stock_code,period,datetime)`、训练组 `PRAGMA user_version=1` 保留。
- **写库前 fail-closed 断言（D8a）**：import 写库壳在任何 INSERT 前查 `information_schema.columns`，断言 `klines.open/high/low/close = double precision`，不符即 `raise`/`exit` 中止（护 pilot 与将来一切调用方，防陈旧库静默截断；不再断言 `ticket_index` 缺失——该列保留）。
- **专用一次性库 + 防误删护栏（D8b）**：pilot 对**名前缀 `kline_pilot_` 的专用库** `CREATE DATABASE` 后应用更新后的 `schema.sql`，**绝不 DROP/改写任意或共享库**；破坏性 reset 需显式 `--reset` 且库名匹配前缀否则拒绝。（migration 供已部署库前向迁移；pilot 空库直建。）
- **iOS reader 逻辑零改动**，**但 `CONTRACT_VERSION` 常量 + 其测试随顶层 bump 改**（§0；`Double`/`REAL` 端到端不变）。

### 4.4 B2 改动
- **前向窗口边界 `after_end`（redefine，codex R5-F1 / R9-F1）**：`after_end = monthly_datetimes[start_idx+8] − 1`（**第 9 根月边界 open − 1 秒**；`select_start_index` 保证 `start_idx ≤ n−9` → 第 9 根必存在）= **第 8 个完整前向月的月末**。取代原 `monthly_after_end` 返回的第 8 月线 open。**所有周期窗口 forward 上界统一用它**。**`monthly_datetimes` = 月边界哨兵序列**（日线日历每月首交易日 open，经 `trading_date` 求；**含当前 partial 月的 open 作哨兵**，R9-F1），**≠ 发射的月 bar**——故最新完整月（如 June）可当第 8 前向月、不浪费最新数据；`n = len(该边界序列)`（含哨兵）。
- **窗口纳入规则（R5-F1）**：`select_period_window` 每周期只纳入**整段 period-end ≤ `after_end`** 的 bar。月/日与 `after_end`=月界天然对齐（恰 8 完整月 + 日线到第 8 月末）；**周线额外排除跨 8→9 月界、周末 > `after_end` 的 trailing 周 bar**（周跨月边界会 straddle）。杜绝末根高周期 bar 的 `end_global_index` 早于其整段 3m 播完（否则第 8 月线含整月 OHLC 却在第 8 月首日 reveal = **lookahead**）。
- `select_start_index(monthly_datetimes, rng, *, dense_dates)`（D2，codex R7-F1）：候选月线下标先按现规则 `[30, n-9]`，**再过滤**「从 `start` 的**交易日期**到 `after_end` 的交易日期，其间（按日线日历）**每个交易日期都在该股 dense 完整 1m 交易日期集 `dense_dates` 内**」；候选为空 → `GenerateSkipException`。**按交易日期比对、非 raw 时间戳**——月/日 bar 标 `00:00`、3m 标盘中(`0933..1500`)，`start`(00:00) < 首根 3m(0933)、`after_end`(≈23:59) > 末根 3m(1500)，raw 时间戳比对会**误杀全部有效候选、产出 0 训练组**。`dense_dates` = B1 分钟级完整性判出的逐日完整交易日期集（`generate_one_training_set` 从该股盘中 klines 推得）。**端点必要非充分**（内部洞仍需 D9），完整性由 D9 per-day 桶数硬门兜底。
- **候选级 bounded retry（D2/D9，codex R12-F2）**：`generate_one_training_set` 把「选起点 → 装配」包进**有界重试循环**，**catch 装配抛出的 `GenerateSkipException`（D9 per-day / per-period before-after / 起点冲突）→ 换下一个候选起点重试**，直到成功或 `max_retries` 耗尽/`dense_dates` 候选穷尽才判该股失败。现有 retry 仅对"重复 start"重试、`assemble` 的 skip 会穿出循环 → **一个跨 drop 日的随机候选会误杀本可用的股**（pilot 每股仅 1 组，尤其致命）。`select_start_index` 从 `dense_dates`-覆盖的有效候选集抽，减少无效候选。
- **窗口覆盖完整性校验（D9，两处强制；codex R4-F1）**：
  - (a) **分钟级 @ B1**（§4.2，1m 在手）：桶内缺分钟的日已被 drop 出库 → **DB 里不存在半成品盘中桶**。
  - (b) **B2 provenance-free 硬门**（无原始 1m）：`assemble_training_set` 登记前，以**日线（交易日真值）**逐日校验——落在**选中盘中日期全跨度** `[首个选中 3m 的日期, after_end]`（**含盘中 before-context ~2 日**，codex R6-F1）内的每个交易日，其 DB 盘中桶数须**精确等于** `80/16/4`；任一日不足（= B1 drop 的洞 / 整天缺）→ `GenerateSkipException`（重选起点）。**精确逐日硬门、非阈值 ratio**（单桶缺也抓）；因分钟级已在 B1 强制，B2 只需数每日桶数、无需原始 1m。
  - **仅**盘中全跨度**外**的 daily-only before-context 日（老日期、本就无盘中，是"日线-only 历史背景"的既定设计）不检查；**盘中 before-context 日在跨度内 → 必检**（防 `start` 前一日被 B1-drop 却被 150 根 3m 从更早日静默回填、而日/周/月仍含该日 = 跨周期不一致，codex R6-F1）。dense 带外的起点 skip（D2 重试）；真停牌日（无日线）不误伤。
  - `coverage_ratio`（各周期，报告用）+ 每日桶数完整性随 `GeneratedTrainingSet` 上报，pilot 打印。
- **聚合 bar 时间标签 = OPEN，端点对齐存证（codex R3-F1）**：daily/weekly/monthly 的 `datetime` 用**组内首交易日午夜**（§4.2）。`assign_global_indices` 把 `datetime` 当 **open**、覆盖区间 `[open, 下一根 open)` → `end_global_index(日D) = bisect_right(3m, 次日午夜−1)−1 =` **day D 最后一根 3m**（逐值验证：次日午夜 ≫ 当日 15:00 ≫ 当日首根 3m，故命中当日末根、非上一根、非次日），reveal 与该日 3m 播放完**精确对齐、无 lookahead**。**明确不采用 codex 建议的「标末根收盘 15:00」**：在 `[open,next_open)` 下末根标签使 `upper=次日15:00−1` → `end_global_index` 落到**次日**倒数第二根 3m → 日 K 滞后一整天 reveal（且偏离 pre-QMT 分周期 CSV 的午夜约定）。before-context 早于 3m 窗口的 daily bar → `egi` 钳到 0（开局即显，正确）。**末根高周期 bar（第 8 月线 / 末周线）**：因 `after_end` 延伸到其整段末（R5-F1 窗口纳入规则），窗口内 3m 覆盖到该段末 → `egi` = 该段最后一根 3m、非窗口首日 → **无 lookahead**。
- `file_path`（D5）：pilot **保持绝对路径写入**，不改现有 B3 `routes.py` 下载 / scheduler / `backfill_content_hash` 的 `Path(file_path)` 读取契约（相对化归 §7 未来搬迁）。
- 其余（窗口切分、`assign_global_indices` 算法本体、zip、CRC32、`uq_stock_start` 预检）**不变**。

### 4.5 pilot 运行脚本（新写，薄壳，不单测）
- 读 `stock_universe_with_name.csv` → 按 `exchange` 分层随机抽 100（`--seed` 可复现）。
- 按文件名规则从 SMB 拉这 100 只的 1m+日线到本地临时目录（或直接读挂载点）。
- 起本机 Docker Postgres（`docker-compose`）→ **schema 前置（D8）**：对专用一次性库 `kline_pilot_<seed>`（前缀护栏 + 显式 `--reset`）`CREATE DATABASE` 并应用 `schema.sql`，再由 import 写前 `information_schema` 断言双保险 → 逐股跑 规整→合成→算指标→写 klines → **每只 sampled 股至多生成 1 个训练组**（逐股调 `generate_one_training_set` 一次、catch skip；**不走 `generate_batch` 的多-start round-robin**，避免用存活股的额外 start 凑数掩盖失败股，codex R10-F2）。
- 输出：`.zip` 到 `--output` 目录（绝对路径存入 `file_path`），`training_sets` 登记；打印每股 1m 覆盖带、各周期 `coverage_ratio`（D9）、生成/skip **原因**；**按市场(SH/SZ/BJ)汇总 distinct 成功股数**（= pilot 验收指标，非 ZIP 总数）。

## 5. 测试（host pytest，纯函数层全测）
- **规整层**：BOM 剥离（表头 `datetime` 非 `﻿time`）；`YYYYMMDDHHMMSS`/`YYYYMMDD` @UTC+8 → Unix 秒精确值（含跨夏令时无关性、北京无 DST）；文件名正则（三市场 + 全角名 + `星`/`_` sanitize）；缺列抛 `CsvSchemaError`；**前复权 15 位小数原样保留**（`clean` 后 close 逐字等于输入）。
- **合成层**（golden fixture）：完整日 → `3m=80/15m=16/60m=4` 根；**禁跨午休**（11:30 桶不含 13:01 数据）；**禁跨日**；开盘集竞 09:30 并入首桶；OHLC=首/高/低/尾、vol/amount=Σ 逐值；周/月按日历分组（含假期周仍一根）；停牌缺口不补零。
- **合成 golden 边界桶（§4.2）**：3m/15m/60m 边界桶成员 = §4.2 逐值 member lists（09:30/10:30/11:30/13:01/15:00 周边）；上午 121 / 下午 120 恒等式。
- **B1 分钟级完整性（R4-F1/R9-F2）**：桶内缺单根/散布缺多根 1m 的**在库交易日**（日线在）→ **drop + 记异常日志**；停牌**整日缺席**（1m+日线都无）→ 不计入、不误判；1m 覆盖边界 partial 日（199 根）→ dense 带排除；完整日（241）照常 80/16/4 入库。
- **resample_calendar 完整性 + 哨兵（R4-F2/R9-F1）**：export 当月/当周残缺周期**不 emit**（构造 export 日落月中 → 该月 monthly bar 不出现）；**但其 open 保留在边界哨兵序列 → 以最新完整月结尾的 8 月窗口仍可选出**（不因丢 partial 少候选）；IPO 首周（有后续周）保留；含假期完整周仍一根。
- **trading_date 时区安全（R8-F1）**：daily `20260703 00:00`(沪 epoch) 与 intraday `20260703 0933`(沪 epoch) → **同一** `trading_date`（尽管 UTC 日期差一天）；Monday/假期周边不错位；周/月分组键用沪日期。
- **B2 D2（按交易日期，R7-F1）**：构造「月线全历史但 1m 只覆盖近段」→ 起点必落在 dense 日期集内；覆盖撑不下前向窗口 → skip；**边界同日期不误杀**：`start` 落 dense 首日（`start`=00:00 < 首根 3m 0933）仍**有效**、`after_end` 落 dense 末日（≈23:59 > 末根 3m 1500）仍有效；窗口跨度含任一非-dense 交易日 → skip。
- **B2 D9 per-day 硬门（R3-F2/R4-F1/R6-F1）**：窗口含被 B1-drop 的日（DB 盘中桶数 <80/16/4）→ **per-day 硬门 skip**；窗口避开该日 → 正常生成；缺整天同理；**start 前一日（盘中 before-context 内）被 drop → 也 skip**（不静默从更早日回填，R6-F1）；盘中全跨度**外**的老 daily-only 日不检查；真停牌日（无日线）不误伤。
- **候选级 bounded retry（R12-F2）**：某股一个候选起点跨 drop 日（D9 skip）、但另有有效候选 → `generate_one_training_set` 换候选重试后**成功**（该股不被单个坏候选误杀）；全候选穷尽/`max_retries` 耗尽 → 才判该股失败。
- **B1 源一致性对账（D10，R6-F2/R10-F1/R11-F1）**：**端点覆盖**——日线止 < dense-1m 止（stale 尾部截断）→ **skip**；日线起 > dense-1m 起 → skip；**对称日期集**——dense-1m 跨度内 1m 有某日但日线缺 → skip；日线有某日但 1m<241 → skip；**值对账**——某日 close/volume 超容差 → skip；三门全过 → 放行；`export_log` `status=error/partial` → skip（纯对账逻辑 host 单测）。
- **B2 聚合对齐（R3-F1）**：daily/weekly/monthly bar 的 `end_global_index` == 该周期**最后一交易日的最后一根 3m** 的 `global_index`（断言非上一根、非次日）；跨月/跨周边界各一例；before-context（早于 3m 窗口）的 daily bar `egi==0`。
- **B2 前向边界无 lookahead（R5-F1）**：构造 8 完整月窗口 → **第 8 月线 bar 的 `egi` = 第 8 月末最后一根 3m**（非窗口首日/非第 8 月首日）；`after_end == monthly[start+8]−1`；构造**跨 8→9 月界的 trailing 周 bar → 被排除**（不出现在窗口，杜绝其整周 OHLC 早显）。
- **D8a 前置断言**：mock `information_schema` 返回 `klines` OHLC=`DECIMAL` → import 写前**中止**（不 INSERT）；返回 `double precision` → 放行（`ticket_index` 列保留、不作断言项）。
- **D8b reset 护栏**：目标库名非 `kline_pilot_` 前缀 或 未带 `--reset` → 任何 `DROP/CREATE DATABASE` 前**拒绝**；匹配前缀 + `--reset` → 放行（纯逻辑守卫可 host 单测）。
- **集成**（不 host 单测，D14/D13 scope）：SMB 拉取、Docker PG、`generate_batch` 端到端由 pilot 脚本人工跑一次核对。

## 6. 验收标准（spec 级；非-coder 验收清单在 plan 阶段出）
- P/F：规整层 host pytest 全绿；BOM/时区/文件名/前复权精度四类各有专测。
- P/F：合成层 golden 三周期总数 = 80/16/4，午休/跨日/日历分组专测全绿。
- P/F：`schema.sql` `klines.open/high/low/close` 为 `DOUBLE PRECISION`、无 `ticket_index`（amount/指标列不变）；空库应用可建成。
- P/F（D8a）：import 写前对陈旧 `DECIMAL` OHLC 的库**中止**（fail-closed）、不静默插入。
- P/F（D1 治理，R12-F1）：`CONTRACT_VERSION` 1.8→1.9（`Models.swift`+`ModelsTests`+m01 矩阵同步）；`backend/sql/migrations/` 有 OHLC `DECIMAL→DOUBLE` 的 forward+rollback 对；`ticket_index` 列**保留**（未删）；PR 引用 m01 §Bump 策略 A。
- P/F（D8b）：破坏性 reset 对**非 `kline_pilot_` 前缀**库/缺 `--reset` **拒绝**（任何 DDL 前），smoke 覆盖；pilot 对专用一次性库建 schema。
- P/F（D9，R4-F1/R6-F1）：桶内缺分钟 → **B1 drop 该日**；**B2 per-day 硬门**覆盖**选中盘中全跨度（含 before-context）**、每交易日桶数精确=80/16/4，缺日（含 start 前一日）skip、单桶缺不被稀释；真停牌日不误伤；pilot 输出含 `coverage_ratio` + 缺日。
- P/F（D10，R6-F2/R10-F1/R11-F1）：**日线止早于 dense-1m 止（stale 尾部）→ skip**；dense-1m 跨度内日期集不相等（任一方缺日）→ skip；OHLCV 超容差 → skip；`export_log` 非 `ok` → skip；三门全过放行。
- P/F（D2，R7-F1）：覆盖判定按**交易日期**（非 raw 时间戳）；start/after_end 与 dense 边界**同日期**的候选不被误杀（同日期边界回归绿，证明不产 0 训练组）。
- P/F（R8-F1 时区）：`trading_date` 对沪-午夜 daily 与盘中 3m 归到**同一交易日**；D2/D9/D10/周月分组全经此单一 helper（无 UTC 日期错位回归绿）。
- P/F（R4-F2/R9-F1）：resample_calendar **不 emit** export 当期 trailing 残缺周/月；训练组内无残缺日历 bar；**但 partial 当期 open 保留为边界哨兵 → 最新完整月可当第 8 前向月**（不浪费最新数据回归绿）。
- P/F（R9-F2 不变量）：`000001.SZ`/`000004.SZ` 抽样每在库交易日=241（flat-fill）+停牌整日缺席+边界日 partial；日线在但 1m<241 → drop + 异常 log。
- P/F（R3-F1 对齐）：daily/weekly/monthly `end_global_index` = 期内末根 3m（无 lookahead）；聚合 bar 标签 = 组内首交易日午夜。
- P/F（R5-F1 前向边界）：`after_end = monthly[start+8]−1`（第 8 月末）；第 8 月线 bar `egi` 命中第 8 月末 3m、非首日；跨月界 trailing 周 bar 被排除（回归绿）。
- P/F（§4.2 bucket）：3m/15m/60m 边界桶成员逐值 = §4.2 golden member lists；完整日 80/16/4 + 上午 121/下午 120 恒等式。
- P/F（R10-F2）：pilot **每股至多 1 组**；验收按**各市场 (SH/SZ/BJ) distinct 成功股数**（阈值 plan 定）+ 显式 skip 原因报告，**非 ZIP 总数**（防存活股多-start 凑数掩盖失败/市场偏置）；`training_sets` 登记 + `content_hash` 合法（`^[0-9a-f]{8}$`）。
- P/F（R12-F2）：单个候选起点跨 drop 日被 D9 skip 后，`generate_one_training_set` 换候选重试成功（有效候选存在时不误杀该股）；候选穷尽才失败（回归绿）。
- P/F（D5）：`training_sets.file_path` 绝对；B3 下载 / `backfill` 读取契约不变（回归绿）。

## 7. 风险 / 开放项
- **合成桶成员**（codex R2-F3 已收敛）：精确区间规则（首桶 `[0930,0930+N]` 含集竞、其余 `(b−N,b]`）+ 边界桶 member lists + 80/16/4 + 121/120 恒等式，**已在 §4.2 定为验收契约**，不再延后 plan。
- **path 相对化 / NAS 搬迁**（codex R2-F2 归入未来）：pilot 用绝对 `file_path`；真正搬 NAS/服务器时做**独立聚焦改动**——引入跨 B2 写 + B3/scheduler/backfill 读的中心化 `resolve_training_set_path(rel)→abs`（base dir 配置化）+ 存量 `file_path` 迁移 + reserve/download e2e 测；本期不做（[[project_app_public_release_intent]]）。
- **可行起点带偏窄**：1m 仅约 1 年 + 前向覆盖到**第 8 完整月月末**（R5-F1，比原第 8 月 open 又晚 ~1 月）→ 每股可行起点约 3–4 个。100 股仍够；若某市场（如次新 BJ 股）1m 更短，该股可能 0 起点被 skip，属预期。
- **前向窗口边界 lookahead**（R5-F1 已收敛）：`after_end` 与 bar 标签解耦——覆盖延到第 8 完整月月末，末根月/周高周期 bar 只在其整段 3m 播完才 reveal；跨月界 trailing 周 bar 排除。§4.4 定契约 + §5 回归锁定。
- **窗口内部数据洞**（R3-F2/R4-F1）：分钟级在 **B1**（1m 在手）强制——缺分钟的日 drop 出库；**B2** 靠"每在窗交易日盘中桶数精确=期望(80/16/4)"的 **provenance-free 硬门**兜底（单桶缺也抓、非阈值 ratio）。缺整天与桶内缺分钟都被抓、skip；真停牌日不误伤。（`coverage_ratio` 仅作报告指标。）
- **残缺日历 bar**（R4-F2 已收敛）：resample_calendar 只 emit 完整日历周期（存在后续周期 daily 才 emit），丢当前 export 期 trailing 残缺周/月，防"看似完整实则残缺"的日历 bar 污染训练快照。
- **聚合 bar 时间标签**（R3-F1）：daily/weekly/monthly 用组内首交易日午夜（OPEN），与 `[open,next_open)` 语义对齐、无 lookahead；**未采纳 codex 的「标末根收盘」建议**（会滞后一格 + 偏离既有约定），已在 §4.4 逐值存证 + §5 回归测试锁定。
- **双源一致性**（R6-F2 已收敛）：1m 与日线是两个独立文件，经 D10 对账（`export_log` status + 重叠窗口 OHLCV 容差比对），不吻合即 skip 该股——防陈旧/不同复权基准产出"日线 close ≠ 1m 聚合 close"的跨周期不一致。
- **前复权基准 = 导出日快照**：本期按快照；将来上架的增量刷新/再复权是独立议题（[[project_app_public_release_intent]]）。
- **volume 单位（手）**：本期原样入库（App 仅画量柱，单位为呈现层问题）；若将来需"股"需在呈现层 ×100，不在本期。
- **本地 pytest 绿 ≠ CI 绿**：合并后 `gh run watch` 确认（[[feedback_swift_local_ci_toolchain_strictness]]）。

## 8. 流程
brainstorming（本 spec）→ Codex spec review 收敛 → `writing-plans` → Codex plan review 收敛 → `subagent-driven-development` → host pytest 三绿 → `requesting-code-review` → whole-branch Codex → PR（`klines` OHLC = **M0.1 A 类 DDL** + `CONTRACT_VERSION` bump + m01 矩阵/migration → 触发 trust-boundary 审查，**PR 引用 `docs/governance/m01-schema-versioning-contract.md` §Bump 策略 A + CODEOWNERS approve**）。

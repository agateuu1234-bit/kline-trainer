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
- 改：`backend/sql/schema.sql`（`klines.open/high/low/close` → `DOUBLE PRECISION`、去 `ticket_index`；空库直建无迁移）、`backend/generate_training_sets.py`（`select_start_index` 加 1m 覆盖带约束、`file_path` 相对化）、`backend/import_csv.py`（接规整/合成层、取消 `ticket_index`、1m 不入库）。
- 复用不动：`compute_indicators`、`clean`、B2 装配（窗口/`global_index`/`end_global_index`）、`zip_and_hash`、`training_sets` 登记逻辑主体。

**公共契约变更声明（如实，非「无变更」）**
- **价格精度变更仅限 `klines.open/high/low/close` 四列 `DECIMAL(10,2)` → `DOUBLE PRECISION`（D1）**，是 PostgreSQL 主库 schema 变更。本仓**无 PG 迁移 runner、无任何生产 PG 数据**（`backend/sql/` 只有 `schema.sql` fresh baseline，docker-compose 不自动灌 schema）→ **直接更新 `schema.sql`、pilot 建空库应用**，不需 forward migration。**不触发 iOS 契约 / `CONTRACT_VERSION` bump**——已核实 `KLineCandle.open/high/low/close` 本就是 `Double`（`ios/.../Models/Models.swift:62`）、训练组 SQLite 本就是 `REAL`（`training_set_schema_v1.sql`），端到端即浮点；DECIMAL→DOUBLE 只是**去掉主库这一处 2 位截断**，更高精度值顺 B2 流入训练组 REAL 列，**iOS 零改动、`CONTRACT_VERSION` 保持 `1.8`、训练组 `PRAGMA user_version` 保持 `1`**（列类型不变、REAL→REAL 读取方精度无关）。`amount`（DECIMAL(16,2)）与指标列（DECIMAL(10,4)/(10,6)）**不变**（见 D1）。
- **取消 `ticket_index` 列（D3）**：已 grep 全仓核实无下游消费者（仅 B1 自身写它 + 其单测 + schema 列定义；B2 `_KLINE_SELECT_COLS` 不含它、iOS 零 `.swift` 引用）。移除是 PG 主库 schema 变更，同上不涉 iOS 契约。

**非目标 / Non-Goals**
- **不生成也不存储** 1m / 5m / 30m / 年线到训练组——合成层写成周期无关的通用代码，但本期产物只含 `3m/15m/60m/daily/weekly/monthly` 六周期（[[project_app_public_release_intent]] 之后加周期 = 改配置 + 重新生成训练组，训练组是不可变快照）。
- **1m 逐分钟揭示**是独立决策（会改 `MIN_PERIOD`/`global_index` 语义 + 全量 5000 股上亿行存储），不在本期。
- 不做 App 内周期选择 UI（后续单独 RFC）。
- 不做 PG 迁 NAS/服务器（本期本机 Docker；D5 只为将来搬家留后路，不实际搬）。
- 不做前复权基准的增量刷新/再复权（前复权值为导出日 2026-07-03 快照，本期按快照用）。
- 不做 B3/B4 全量调度与真机租借压测（本期只产出 `.zip` + 登记）。

**约束**
- 规整/合成层为**纯函数**（不碰 DB），host `pytest` 全测；薄 DB 壳 + CLI 沿现有 D14 惯例不单测（B3/NAS scope）。
- 前复权价为 `float64`、**禁止四舍五入到 2 位**（会压塌老 K 线 + 丢复权精度，违反耐久性约束）。
- 合成**严格按交易时段分段**（禁跨午休 11:30↔13:01、禁跨日），周/月**按交易日历分组**（含假期的周/月仍为一根）。
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
| **D1** | 只改 `klines.open/high/low/close`：`DECIMAL(10,2)` → `DOUBLE PRECISION`。`amount`（`DECIMAL(16,2)`，元/分 2 位为自然精度、尾噪是 artifact）与指标列（`ma66/boll_*/macd_*` `DECIMAL(10,4)/(10,6)` + `round(4)/round(6)`，既有契约）**保持不变**——仅在全精度 `close` 上重算，结果更准但仍存 4/6 位。 | 前复权 float64 价格无损；amount/指标不动 = 最小改面（surgical）。空库直建、无 migration。**不涉 iOS/契约**（§0）。 |
| **D2** | `select_start_index` 加**每股 1m 覆盖带约束**：起点仅在「前向 8 根月 K 窗口 `[start, after_end]` 完整落在该股 1m 覆盖区 `[t0,t1]` 内」的月线里选。 | 消灭随机起点大量落空 + 杜绝盘中中途断货的次品训练组。约束下每股约 4–5 个可选起点，100 股够凑 100 组（`uq_stock_start` 保唯一）。 |
| **D3** | 合成层写成**周期无关通用**；本期只生成 `3m/15m/60m/daily/weekly/monthly`。**1m 不入主库**（仅作合成源），`3m` 为最细周期。**取消 `ticket_index`**（无消费者，§0 声明）。 | 通用代码 → 将来加 5m/30m/1m/年 = 改配置；不塞将来要重做的周期进 pilot 产物（YAGNI）。1m 不入库省全量上亿行。 |
| **D4** | `stocks.code` 保留交易所后缀（`000001.SZ`，9 字符 ≤ `VARCHAR(10)`）。 | 消歧（`000001.SZ` 平安银行 vs `000001.SH` 上证指数）、与 `stock_universe` 一致。 |
| **D5** | `training_sets.file_path` 存**相对路径**（相对可配置 `TRAINING_SET_BASE_DIR`），非绝对本地路径。 | 将来 PG 迁 NAS/服务器只换 base dir，B3 按路径找文件不断（搬家后路能轻）。 |
| **D6** | pilot：本机 Docker Postgres（复用 `backend/docker-compose.yml`）；100 只从 universe **按市场分层随机抽**（seed 可复现），SH/SZ/BJ 都覆盖；经现在可用的 SMB 挂载拉这 100 只的 1m+日线文件。 | 最省事、可复现；覆盖三市场以暴露格式差异。 |
| **D7** | 规整层为**新增 QMT 专用层**，产出与现有 `clean` 入参兼容的 DataFrame（列 `datetime/open/high/low/close/volume/amount` + Unix 秒），接现有 `compute_indicators`。 | 隔离 QMT 特有的 BOM/时区/文件名/中文标签解析，不污染下游通用逻辑。 |

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
  B2 generate_training_sets  ♻复用；select_start_index 加 1m 覆盖带约束(D2)；file_path 相对化(D5)
      ▼
  产物：100 个训练组 .zip + training_sets 登记
```

## 4. 组件设计

### 4.1 规整层 `qmt_normalize`（新写，纯函数）
- `parse_qmt_csv(path) -> DataFrame`：`pd.read_csv(path, encoding="utf-8-sig")`（剥 BOM）；校验列 `{time,open,high,low,close,volume,amount}`，缺列抛 `CsvSchemaError`；列 `time` 重命名 `datetime`。
- `parse_qmt_datetime(series, src_period) -> Int64 Unix 秒`：按位数判定格式（14 位 `YYYYMMDDHHMMSS` / 8 位 `YYYYMMDD`）→ 以 `Asia/Shanghai`（UTC+8）本地化 → Unix 秒。**不用** `utc=True` 直接解析 naive（会当 UTC 偏 8 小时）。
- `parse_qmt_filename(name) -> (code, stock_name, src_period)`：正则 `^(?P<code>\d+\.(SH|SZ|BJ))_(?P<name>.+)_(?P<label>1分钟K线|日K线)_前复权\.csv$`；`label` 映射 `1分钟K线→"1m"`、`日K线→"daily"`（源周期，仅 1m/daily 两种）。
- 产出交给现有 `clean`（**价格列不 round**；`clean` 逻辑不变，只是入参来自 QMT 规整）。
- **不再需要** `compute_ticket_index`（D3 取消）。

### 4.2 合成层 `resample`（新写，纯函数，周期无关）
**周期表（分钟 / 日历）驱动，加新周期 = 加表项：**
```
INTRADAY_MINUTES = {"3m":3, "15m":15, "60m":60}          # 将来加 "5m":5,"30m":30,"1m":1
CALENDAR_RULE    = {"weekly":"W", "monthly":"M"}          # 将来加 "yearly":"Y"
```
- **`resample_intraday(df_1m, minutes)`**：
  - 先按 `datetime`（Unix 秒 → 北京 wall-clock）拆**交易日 + 上午/下午两段**；**严禁跨午休、跨日聚桶**。
  - 桶边界对齐**各段起点**（morning 09:30、afternoon 13:00），每根 1m（按其收盘时间戳）归入 `(prev_boundary, boundary]` 桶；桶 label = 桶收盘时刻。开盘集竞 `09:30` 根并入首桶、下午 `13:01` 起并入 `13:00–13:15/14:00/…` 桶。
  - 聚合：`open=`首根 open、`close=`尾根 close、`high=max`、`low=min`、`volume=Σ`、`amount=Σ`。
  - **完整日 golden 总数**：`3m=80`、`15m=16`、`60m=4`（morning/afternoon 各半）。逐桶成员由 plan 阶段 golden fixture 钉死。
- **`resample_calendar(df_daily, rule)`**：按每个交易日所属**日历周（周一起）/日历月**分组（含假期的周/月仍一根）；OHLC/Σ 同上；数据边缘的**残缺周/月**照常成一根（partial）。
- 停牌/稀疏容错：段内不足一桶/整段缺失 → 该桶不产出（不补零、不插值）。

### 4.3 Schema 变更（D1，`backend/sql/schema.sql`）
- 只改 `klines.open/high/low/close`：`DECIMAL(10,2)` → `DOUBLE PRECISION`；**移除 `ticket_index` 列**。
- `amount DECIMAL(16,2)`、指标列 `DECIMAL(10,4)/(10,6)` **不变**；Python `compute_indicators` 的 `round(4)/round(6)` **保留**（在全精度 `close` 上重算，结果更准但仍按既有契约存 4/6 位）；`UNIQUE(stock_code,period,datetime)` 保留。
- `_INT_COLS` 去 `ticket_index`；`_KLINE_INSERT` 与 `schema.sql` 去 `ticket_index` 列/占位符；`compute_ticket_index` 及其单测删除（D3，无消费者）。
- **无 PG 迁移 runner、无生产 PG 数据** → pilot 对**空库**应用更新后的 `schema.sql`（bump 头部版本标签）即可；已有数据的 forward migration 仅当将来存在需保留的生产 PG 时才写（当前无 → 本期不做）。
- **iOS 侧零改动**（§0 声明，已核实 `Double`/`REAL` 端到端）。

### 4.4 B2 改动
- `select_start_index(monthly_datetimes, rng, *, one_min_lo, one_min_hi)`（D2）：候选月线下标先按现规则 `[30, n-9]`，**再过滤**「起点 `start` 与 `monthly_after_end(start)` 都落在 `[one_min_lo, one_min_hi]` 内」；候选为空 → `GenerateSkipException`（该股 1m 覆盖不足以承载任何完整前向窗口）。`one_min_lo/hi` 由 `generate_one_training_set` 从该股 3m（最细）实际 datetime 范围推得。
- `file_path` 相对化（D5）：登记时存 `gts.path.relative_to(base_dir)`；新增 `TRAINING_SET_BASE_DIR`（env/CLI），B3 读取时 `base_dir / rel_path` 还原。
- 其余（窗口切分、`assign_global_indices`、zip、CRC32、`uq_stock_start` 预检）**不变**。

### 4.5 pilot 运行脚本（新写，薄壳，不单测）
- 读 `stock_universe_with_name.csv` → 按 `exchange` 分层随机抽 100（`--seed` 可复现）。
- 按文件名规则从 SMB 拉这 100 只的 1m+日线到本地临时目录（或直接读挂载点）。
- 起本机 Docker Postgres（`docker-compose`）→ 逐股跑 规整→合成→算指标→写 klines → B2 `generate_batch(target=100)`。
- 输出：`.zip` 到 `TRAINING_SET_BASE_DIR`，`training_sets` 登记；打印每股覆盖带与生成结果。

## 5. 测试（host pytest，纯函数层全测）
- **规整层**：BOM 剥离（表头 `datetime` 非 `﻿time`）；`YYYYMMDDHHMMSS`/`YYYYMMDD` @UTC+8 → Unix 秒精确值（含跨夏令时无关性、北京无 DST）；文件名正则（三市场 + 全角名 + `星`/`_` sanitize）；缺列抛 `CsvSchemaError`；**前复权 15 位小数原样保留**（`clean` 后 close 逐字等于输入）。
- **合成层**（golden fixture）：完整日 → `3m=80/15m=16/60m=4` 根；**禁跨午休**（11:30 桶不含 13:01 数据）；**禁跨日**；开盘集竞 09:30 并入首桶；OHLC=首/高/低/尾、vol/amount=Σ 逐值；周/月按日历分组（含假期周仍一根 + 边缘残缺周/月成一根）；停牌缺口不补零。
- **B2 D2**：构造「月线全历史但 1m 只覆盖近段」的 fixture → 起点必落在覆盖带内；覆盖带撑不下前向窗口的股 → skip；`file_path` 相对化 round-trip（`base_dir/rel` 还原 = 原路径）。
- **集成**（不 host 单测，D14/D13 scope）：SMB 拉取、Docker PG、`generate_batch` 端到端由 pilot 脚本人工跑一次核对。

## 6. 验收标准（spec 级；非-coder 验收清单在 plan 阶段出）
- P/F：规整层 host pytest 全绿；BOM/时区/文件名/前复权精度四类各有专测。
- P/F：合成层 golden 三周期总数 = 80/16/4，午休/跨日/日历分组专测全绿。
- P/F：`schema.sql` `klines.open/high/low/close` 为 `DOUBLE PRECISION`、无 `ticket_index`（amount/指标列不变）；空库应用可建成。
- P/F：pilot 脚本对 100 只产出 `≥` 阈值个 `.zip`（阈值由实际覆盖带算，plan 定）+ `training_sets` 登记 + `content_hash` 合法（`^[0-9a-f]{8}$`）。
- P/F：`training_sets.file_path` 为相对路径；`base_dir` 还原 round-trip 通过。

## 7. 风险 / 开放项
- **合成桶成员的确切约定**：本 spec 定"按段对齐、label=桶收盘、禁跨午休/日"的规则与三周期总数（80/16/4）；**逐桶成员**（尤其 09:30 集竞与 13:01 起如何并桶）由 plan 阶段 golden fixture 逐值钉死，避免文华/通达信约定分歧。
- **可行起点带偏窄**：1m 仅约 1 年 + 前向 8 月 → 每股可行起点约 4–5 个。100 股足够；若某市场（如次新 BJ 股）1m 更短，该股可能 0 起点被 skip，属预期。
- **前复权基准 = 导出日快照**：本期按快照；将来上架的增量刷新/再复权是独立议题（[[project_app_public_release_intent]]）。
- **volume 单位（手）**：本期原样入库（App 仅画量柱，单位为呈现层问题）；若将来需"股"需在呈现层 ×100，不在本期。
- **本地 pytest 绿 ≠ CI 绿**：合并后 `gh run watch` 确认（[[feedback_swift_local_ci_toolchain_strictness]]）。

## 8. 流程
brainstorming（本 spec）→ Codex spec review 收敛 → `writing-plans` → Codex plan review 收敛 → `subagent-driven-development` → host pytest 三绿 → `requesting-code-review` → whole-branch Codex → PR（价格/指标 schema 迁移触发 trust-boundary 审查）。

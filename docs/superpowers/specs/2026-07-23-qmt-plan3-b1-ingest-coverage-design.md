# QMT 数据接入 Plan 3：B1 接规整/合成层 + 写 `stock_coverage` 设计（2026-07-23）

> 上游 spec：`docs/superpowers/specs/2026-07-06-qmt-data-ingestion-pilot-design.md`（D1-D11 决策的权威出处，本文只在**它未定或需收窄**处新增决策，不复述）。
> 上游 plan：`docs/superpowers/plans/2026-07-18-qmt-plan2-b2-reconnect.md`（§Self-Review「明确不在本 plan、留 Plan 3」清单）。

---

## 0. 目标 / 范围 / 非范围

### 0.1 目标（一句话）

让 **B1（`import_csv.py` 侧）真正接上 Plan 1 已 merge 但零调用方的 QMT 规整/合成层**，导入时把权威 dense 覆盖写进 `stock_coverage`，从而**解除 B2/B4 恒产 0 的根因**；同时消除 Plan 2b 遗留的「coverage 与六周期 klines 无统一快照」残留。

### 0.2 交付口径（诚实义务，沿用 Plan 2 的做法）

Plan 3 交付的是「出货能力被证明」，**但证明分两层、口径必须分开写**（codex R1-F3：原口径说「CI 里有一条真链路」是**过度宣称**——CI 里那条链的存储层是假 conn，`write_qmt_stock` 的真 SQL / asyncpg 参数绑定 / JSONB 编解码 / 事务行为**一行都没跑过**）：

| 层 | 证明什么 | 在哪跑 | 强制力 |
|---|---|---|---|
| **L1 逻辑链** | `QMT fixture → build_stock_import → 假 conn 存储 → 真 generate_batch → ≥1 个 zip` | CI（host pytest） | **机器强制**（CI 必绿） |
| **L2 真写入器** | 真 PG 上跑**真** `write_qmt_stock` + **真** `generate_one_training_set` → 真出 zip；并验事务/隔离/原子性语义 | `backend/scripts/verify_qmt_pg_chain.py`（一次性脚本，需 Docker PG） | **流程纪律**（合并前控制者真跑、输出贴 PR body；**非** CI 自动门——见 §5.4 F2 收口） |

**关键诚实口径（codex R5-F2 收敛）**：**CI 绿 ≠ 链路已证**。L1 的假 conn 存储证明不了 `write_qmt_stock` 的真 SQL / asyncpg 绑定 / JSONB / 事务行为——那些**只在 L2 被真跑**。所以「B1→B2 通了」的证据 = 「L1 CI 绿 **且** PR body 里贴出的 L2 真跑输出」；**L2 是流程纪律、不是机器强制的门**（把它做成带 postgres 的 CI job 是独立的 CI 治理改动，见 §5.4）。只有 L1 绿就写「链路可用」，视同过度宣称。

Plan 3 **不**交付「已经用真 QMT 数据产出 100 个训练组」。真跑属 Plan 4。

**禁止**在任何 commit message / PR body / 验收项里写「pilot 已完成」「100 股已出货」之类表述。

### 0.3 范围（in scope）

1. B1 侧 **D9(a) 分钟级完整性** 与 **D10 双源对账** 的强制（调用已 merge 的 `build_intraday` / `reconcile_sources`，不重写算法）。
2. B1 写 6 周期 `klines` + `stock_coverage`，**单事务原子**，且是**整体替换**而非 UPSERT 叠加（P3-D4）。
3. B1 QMT 模式 CLI（单只股）。
4. B2 侧 **快照一致性**：coverage + 六周期 klines 在同一个 `REPEATABLE READ READ ONLY` 事务内读取（P3-D5）。
5. **按股导入/生成互斥锁**（P3-D8）——补齐 RR 事务不覆盖的「新鲜度」那一半。
6. **出货可行性预检（复用 B2 `eligible_start_indices`）+ 拷贝完整性门**（P3-D9）——把「导入看似成功、B2 静默不出货」和「拷贝被截断」的失败面提前到导入期。
7. **通用 CSV 路径对已被 QMT 管理的股 fail-closed**（P3-D11）——堵住绕过上述不变量的写路径。
8. 上述各项的 host pytest 覆盖 + 两条一次性**真 PG** 脚本（语义验证 + 真链路端到端）+ CI 内的逻辑链集成测。

### 0.4 非范围（明确留 Plan 4）

SMB 真拉取、100 股储备池与各市场地板（SH≥30/SZ≥40/BJ≥8）、D8b `kline_pilot_` 库 reset 护栏、容器化 PG smoke（上游 spec §5 的 ①②③⑤⑥⑦）、批量导入 CLI、`stock_universe_with_name.csv` 消费。

**另拆独立 plan（非本 plan、非 Plan 4）**：**重导入后旧训练组的作废/版本化**（P3-D10 ①）。需 import 版本号或 `retired` 状态 + B3 `/download`+`/confirm` 语义变更，是产物生命周期的独立改动。**本 plan 只做一件相关的事**：加 fail-closed 互锁**禁止**已出货股的重导入（P3-D10 ②），把「作废能力没落地」这个空档挡在门外，作废本身不设计。

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

**由 `monthly: None`（before-context 全取）推出的约束，措辞必须精确**（codex R2-F3）：

- **能强制的**：存在一个「全-dense 的 8 月前向合格起点」（否则 B2 必不出货）—— 用 B2 自己的 `eligible_start_indices` 在导入期预检（P3-D9(a)）+ 日线内容必须与 export_log 记录的端点/行数一致（P3-D9(b) 拷贝完整性）。
- **不能强制的**：「这份日线就是该股全部历史」。本地没有上市日期的独立真值源，一份「四年、但覆盖住 dense 1m」的日线与「一只只上市四年的股票」在数据上无法区分。
- 因此本 spec **不宣称**能保证全历史。宣称的是：**给多少日线就用多少**（monthly before-context 全取），**导入期已用 B2 的合格性判据预检过「这只股真能出至少一个训练组」**，**且拷贝完整性有门**。§6 验收标准按这个口径写，不写「已验证全历史」。

---

## 2. 决策（本 plan 新增，编号 P3-D*）

> **编号按引入轮次分配、不按文档顺序**（D1-D7 = 初稿；D8-D9 = codex R1 后；D10-D11 = codex R2 后）。索引：
>
> | 编号 | 主题 | 引入 |
> |---|---|---|
> | P3-D1 | 新建 `qmt_ingest.py` 纯装配层 | 初稿 |
> | P3-D2 | 周期来源分工 + 清洗顺序 | 初稿 |
> | P3-D3 | `export_log` status 门必填 | 初稿 |
> | P3-D4 | B1 写入 = 单事务**整体替换** | R1-F2 后改写 |
> | P3-D5 | B2 RR 只读快照读 | 初稿 |
> | P3-D6 | CLI 形态 | 初稿 |
> | P3-D7 | `volume` 不换算 | 初稿 |
> | P3-D8 | 按股导入/生成互斥锁 | R1-F1 |
> | P3-D9 | (a) 出货可行性预检（复用 B2 `eligible_start_indices`）+ (b) 拷贝完整性门 | R1-F4 / R2-F3 / R8-F1 |
> | P3-D10 | ① 作废/版本化 → 拆独立 plan；② 已出货股重导入 fail-closed 互锁（留本 plan） | R2-F2→R5-F1 连提 5 轮；user 两次裁决 |
> | P3-D11 | 通用 CSV 路径 fail-closed | R2-F1 |
> | P3-D12 | 写入器 fail-closed 校验 bundle 形状（破坏性 DELETE 前）；B1 锁改非阻塞 | R7-F2 / R7-F3 |

### P3-D1：新建 `backend/qmt_ingest.py` 作为 B1 的 QMT 装配层（纯函数）

不把逻辑塞进 `import_csv.py`。理由：`import_csv.py` 已同时承担「通用 CSV 纯函数层 + 写库壳 + CLI」；再塞进 D10 对账 + 六周期合成会让单文件超 500 行且职责混杂。`qmt_ingest.py` 只依赖 `qmt_normalize` / `qmt_resample` / `import_csv`（复用 `clean` / `compute_indicators` / `to_kline_records`），**不依赖 asyncpg**，host pytest 全测。

入口：

```python
build_stock_import(df_1m, df_daily, *, stock_code, stock_name,
                   entry_1m: ExportLogEntry, entry_daily: ExportLogEntry) -> ImportBundle
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
- 解析器 `parse_export_log(path) -> dict[(code, period), ExportLogEntry]`，其中

  ```python
  @dataclass(frozen=True)
  class ExportLogEntry:
      status: str
      rows: int
      first_time: int      # QMT 打包整数，经 parse_qmt_datetime 同一套规则解析
      last_time: int
      source: str          # 该行的原始标识值，报错时回显用
  ```

  **返回结构体而非裸 status**（codex R3-F3，high，**核实为真**：我上一版把 `parse_export_log` 定义成只返回 status、`build_stock_import` 也只收 `status_1m/status_daily`，于是 P3-D9 的拷贝完整性门**在纯函数 API 里根本拿不到 `rows`/`first_time`/`last_time`** —— 门只能靠 CLI 侧另做一遍，非 CLI 调用方直接绕过。这是 spec 自相矛盾，不是实现细节）。
- 要求存在 `status` / `period` / `rows` / `first_time` / `last_time` 五列，缺任一 → `QmtSchemaError`；股票标识列从候选集 `stock` / `code` / `stock_code` / `file` / `filename` 取**第一个存在的**，值若形如 QMT 文件名则经 `parse_qmt_filename` 取 code，否则按裸 code 比对。
- 候选集全不命中 → 抛 `QmtSchemaError`（**停下并报错**，不静默放行）。
- `period` 值同时接受 `1分钟K线`/`日K线` 与 `1m`/`daily`。
- 查不到该股某个周期的条目 → 拒绝该股（缺条目 ≠ ok）。
- **重复行 fail-closed**（codex R8-F3，medium，**核实为真**）：`dict[(code,period)]` 会把同 `(code,period)` 的多行**塌成最后一行** —— 一条 `status=error` 行可能被后面的 `ok` 行悄悄覆盖，status 门在信任边界上被削弱。故解析时**检测重复 key**：同 `(code,period)` 出现 >1 行 → 抛 `QmtSchemaError("export_log_duplicate")`，**不按行序取任意一条**。（真列里若 `file`/`filename` 能把两行唯一区分开，那是 Plan 4 挂 SMB 逐字核对后的收窄；本 plan 无法核对真格式，一律 fail-closed 拒绝重复。）
- `build_stock_import` 的入参相应从 `status_1m, status_daily` 改成 **`entry_1m: ExportLogEntry, entry_daily: ExportLogEntry`**（必填，无默认值——有默认值就等于又留了默认放行的后门）；它自己把 `entry.status` 传给 `reconcile_sources`，`reconcile_sources` 的既有签名不动。

> **⚠️ 已知不确定项**：`export_log.csv` 的真实列名来自上游 spec §1.4 的记录（`first_time/last_time/rows/status/period`），本会话**无法挂 SMB 逐字核对**。上面的候选集设计保证：真列名若不在候选集内，Plan 4 挂载时会**明确报错**，而不是静默跳过这道门。

### P3-D4：B1 写入 = **一只股一个事务的整体替换**（不是 UPSERT 叠加）

```
validate_import_bundle(bundle, stock_code)   ← P3-D12，纯函数，DELETE 之前、连接之前就能拦
BEGIN
  IF NOT pg_try_advisory_xact_lock(IMPORT_GEN_LOCK_KEY, stock_key)  ← P3-D8，非阻塞
       → raise ImportBusyError（该股正被 B2 生成，可重试；零写入）
  LOCK TABLE klines, stock_coverage IN ROW EXCLUSIVE MODE
  → D8a schema 守卫（沿用现有）+ stock_coverage 存在断言
  → SELECT 1 FROM training_sets WHERE stock_code=$1 LIMIT 1   ← P3-D10 互锁
       命中 → raise ReimportBlockedError（零写入，整只股回滚）
  → stocks UPSERT
  → DELETE FROM klines WHERE stock_code=$1 AND period = ANY(六周期)    ← 替换语义
  → 6 × klines executemany INSERT（沿用现有 _KLINE_INSERT 的 UPSERT 形式，兜底幂等）
  → stock_coverage UPSERT（ON CONFLICT (stock_code) DO UPDATE）
COMMIT（xact 锁自动释放）
```

**本事务只读 `training_sets`（一条 `SELECT 1` 作互锁）、不删不改不 unlink**（P3-D10：作废/版本化拆独立 plan）。

**破坏性 DELETE 之前先 fail-closed 校验 bundle 形状**（codex R7-F3，medium，**核实为真**）：`write_qmt_stock` 会先删该股六周期再 INSERT，若上游 `build_stock_import` 回归、或某个非-CLI 调用方传进半份 bundle，就会**提交一次部分替换**——B2 之后读到缺周期 klines 或与 klines 不符的陈旧 coverage，而这一切不会让任何测试变红。故见 **P3-D12**。

**为什么必须 DELETE 而不是纯 UPSERT**（codex R1-F2，high，**核实为真且机制比 codex 的论证更具体**）：

QMT 的 **1m 导出只保留约一年**，服务端截断。第二次导出时这个窗口**整体向前滑动**——旧窗口起始那几个月的日期**不再出现在新 bundle 里**。纯 UPSERT 只覆盖新旧 datetime 交集，滑出去的那批 `3m/15m/60m` 行会**永久留在 klines 里**。

真正致命的是：**这些是前复权价**。发生分红/送转后，同一历史 datetime 的前复权价会被**整体重算成新基准**。于是库里出现「新基准的近一年盘中 + 旧基准的更早盘中」混杂，而 `stock_coverage` 声称的 dense 带只覆盖新的那段。B2 的 `select_period_window` 取 before-context 时**不受 dense 约束**（`PERIOD_BEFORE_CAP` 各周期 150 根），一旦回溯到旧基准区间，训练组里就会出现**同一张图上两套复权基准的蜡烛**——价格在拼接处凭空跳空。这类坏数据不会让任何测试变红。

日线/周线/月线本身是全历史、每次导出都全覆盖，纯 UPSERT 就已一致；但**六周期一律走 DELETE + INSERT**，理由是判据统一（不需要维护「哪些周期会滑窗」这张易腐清单），且成本相同（同事务内一只股约数万行，本就要写）。

`klines` 无任何外键指向它，已生成的 zip 是自包含产物，DELETE 不影响 `training_sets`（旧训练组作废见 P3-D10——已拆出 Plan 3）。

`dropped_1m_dates` 写 ISO 日期字符串 JSON 数组（`json.dumps([d.isoformat() ...])`），与 `_fetch_dense_coverage` 的解析对称。

> **观察（不改变设计）**：D10-(c) 对称日期集门要求 dense 跨度内 1m 日期集 == 日线日期集，所以**跨度内部**不可能存在 dropped 日——真出现即整只股被拒。`dropped_1m_dates` 因此在被接受的股上实际恒为 `[]`。仍**如实写入** `compute_dense_coverage` 的结果，不硬编码空数组：门的语义与存储的语义解耦，将来放宽门时存储不需要跟着改。

### P3-D5：B2 快照一致性 = 单个 `REPEATABLE READ READ ONLY` 事务包住 7 次读

`generate_one_training_set` 里 `_fetch_dense_coverage` + 6 次 `_fetch_period_bars` 移入同一个只读可重复读事务；事务提交后再做 `_fetch_existing_starts`、取 advisory lock、锁内 `_exists_start`、写 zip、登记。

- **为什么 `_fetch_existing_starts` / `_exists_start` 必须在快照外**：它们要的是「此刻最新已提交」的登记状态。若被冻在旧快照里，Plan 2b R2 刚修好的「锁内先查、后写」会重新变成 stale 检查。
- **早退不受影响**：coverage 行不存在时仍在读第一条语句后就抛 `GenerateSkipException`，六周期全量读不会发生。

**RR 事务只解决「一致性」，不解决「新鲜度」**（codex R1-F1，high，**核实为真**）：B2 可以在快照里读到旧数据，此后 B1 重导入并提交，B2 才写 zip 并登记——登记下来的训练组是从**已被取代的导入**建出来的，且事后无从分辨。这条由 **P3-D8** 补齐，不由 RR 事务负责。

**否掉的替代方案**：

| 方案 | 否掉理由 |
|---|---|
| B：给 `stock_coverage` 加 import 版本号，B2 在快照里读、登记前复查 | 能解决新鲜度，但要动 migration（0005）+ `schema.sql` + m01 走一遍 A 类 DDL 治理，而它给出的语义**弱于** P3-D8：版本复查只能在登记前**发现**数据已过期然后丢弃（zip 已经白写了），P3-D8 直接让「快照期间该股被重导入」**不可能发生**。同等目标下取代价低、语义强的那个 |
| C：B1 导入与 B2 读取共用**全局** `B2_GENERATION_LOCK_KEY` | 会把 B2 的锁重新提到六周期全量读之前，抹掉 Plan 2b R1 刚做的「锁下沉」；且让整轮 sweep 与**任意**股票的导入完全串行。P3-D8 的**按股**锁拿到同样的互斥而不付这两笔代价 |

### P3-D8：按股导入/生成互斥锁

**锁**：新增 `IMPORT_GEN_LOCK_KEY`（与 `B2_GENERATION_LOCK_KEY` 不同的常量），用 PostgreSQL **双参** advisory lock 的第二个参数区分股票：`stock_key = zlib.crc32(stock_code.encode()) & 0x7FFFFFFF`（落在 int4 正区间；不同股票碰撞只会造成不必要的串行，不会造成错误——**碰撞不影响正确性，只影响并发度**）。

| 角色 | 取法 | 范围 |
|---|---|---|
| B1 `write_qmt_stock` | `pg_try_advisory_xact_lock(IMPORT_GEN_LOCK_KEY, stock_key)`（**非阻塞、事务级**），拿不到 → `ImportBusyError`（该股正被 B2 生成，可重试） | 事务开头取，COMMIT/ROLLBACK 自动释放，不泄漏。**事务级足够**：B1 没有任何「提交后的文件操作」需要锁去覆盖，锁只需活到写入提交为止 |
| B2 `generate_one_training_set` | `pg_try_advisory_lock(IMPORT_GEN_LOCK_KEY, stock_key)`（**try、session 级**），拿不到 → `GenerateSkipException`（该股正在被导入，跳过） | **在打开 RR 快照之前**取，**直到登记完成**才在 `finally` 里释放。B2 的锁必须是 session 级——它要跨越 RR 快照事务的提交，一直活到快照外的写 zip + 登记做完 |

**两端都用 `try`、非阻塞**（codex R7-F2，medium 收敛）：先前 B1 用**阻塞**式 `pg_advisory_xact_lock`，若 B2 因 NAS 慢 / zip 大 / 进程卡住而长时间持有该股 session 锁，B1 导入会**无限期挂起、无超时、无可重试反馈**。改成 `pg_try_advisory_xact_lock`：拿不到即刻抛 `ImportBusyError`（CLI 退非零、文案「该股正被 B2 生成，稍后重试」），运维重跑即可。**非阻塞不损新鲜度不变量**：B1 要么拿到锁并导入、要么直接失败**不导入**——它绝不会在 B2 持锁期间提交一个竞态导入。于是「B2 的快照 → 建 zip → 登记」整段期间该股仍**不可能**有导入提交；RR 保一致、这把锁保新鲜，合起来才是完整不变量。B1 的锁只需活到它自己的写入提交（作用 = 「B2 快照时看不到写到一半的导入」），事务级恰好覆盖这段。

**锁序（防死锁）**：B2 的取锁顺序恒为 `IMPORT_GEN_LOCK_KEY(按股)` → `B2_GENERATION_LOCK_KEY(全局)`，B1 只取前者。不存在反序路径，故无环、无死锁。事务级与 session 级 advisory lock 共用同一锁空间，两者互相冲突判定正常。

### P3-D10：重导入 fail-closed 互锁——**作废/版本化本身拆独立 plan**（user 2026-07-23 两次裁决）

**问题是真的**（codex R1-F2 后半 → R2-F2 → R3-F2 → R4-F3 → R5-F1，连提 5 轮，每轮都核实为真）：一次**修正性**重导入之后，用旧（错误）数据生成的 zip 仍会被 B3 发给用户，且库里没有字段能区分「当前版本」与「被取代」的产物。R4-F3 经核实成立：B3 的 `/download`（`routes.py:56`）**按 id 发文件、不做 status 迁移**，`/confirm`（`routes.py:71`）才迁 `sent`——所以「`reserved` = 未交付」这个前提**是错的**，客户端可能已把旧 zip 下到手。

**分两层处置（user 两次裁决）**：

**① 作废/版本化（重活）拆独立 plan。** 可靠闭合需要给 `stock_coverage`/`training_sets` 引入 **import 版本号（或 `retired` 状态）** 并改 **B3 的 `/download`+`/confirm` 语义只发当前版本**——A 类 DDL（migration 0005 + `CONTRACT_VERSION` 再 bump + openapi/iOS 波及）+ B3 发放契约变更，等于把 Plan 3 从「接通 B1」撑成「接通 B1 + 重做产物生命周期」。**不在本 plan 做。** 之前尝试的「同事务删 unsent/reserved 行 + 提交后 unlink」是半吊子，引入的新问题（R3-F1 竞态删新 zip、R4-F2 unlink 信任任意 `file_path`、R4-F3 已下载未 confirm）比它解决的还多，一并撤掉。

**② 但本 plan 必须加一道 fail-closed 互锁**（codex R5-F1 收敛，user 采纳）——否则 spec 就是「**明知重导入会让用户练到旧/错数据，还照样放行**」，与全项目 fail-closed 数据耐久性取向冲突：

> `write_qmt_stock` 在**已持有该股按股锁的事务内**先查 `SELECT 1 FROM training_sets WHERE stock_code=$1 LIMIT 1`；**若已存在任何该股的训练组行 → 抛 `ReimportBlockedError`，整只股零写入**，报错文案明确指向「该股已有训练组，重导入的作废/版本化能力尚未落地（独立 plan），暂不支持覆盖导入」。

这把互锁的**边界**必须说清，才不与 user「不碰 training_sets 生命周期」的裁决矛盾：

- 它**只读** `training_sets`（一条 `SELECT 1`），**不删、不改、不加版本列**——生命周期那套重活仍在独立 plan。
- 它把「坏状态明知放行」变成「**坏状态进不来**」：一只股要么还没出过货（首次导入，放行），要么已出货（重导入，拒绝并报错），**不存在**「klines 换了、旧 zip 还在流通」这个中间态被静默制造出来。
- 检查在按股锁内 → check-and-write 原子，不存在「查时没行、写时 B2 刚登记」的缝。

**对 P3-D4 替换语义可达性的影响（如实标注）**：加互锁后，`write_qmt_stock` 的 klines DELETE+INSERT 替换路径**只在「已导入但 B2 尚未生成任何训练组」的窗口内可达**（第二次导入若已出过货就被互锁拦下）。替换语义仍需保留且仍有意义——它保证那个窗口内 klines 当前状态自洽；只是它的可达面被互锁收窄了。端到端测里「窗口前滑重导入」的断言要落在这个窗口内（重导入前不 generate）。

**连带效果**：因为不再有「提交后 unlink」，codex R3-F1 与 R4-F2 **消失**；R4-F1（B1 锁范围矛盾）消解——B1 回到事务级锁（见 P3-D8）。**诚实义务**：PR body 与验收清单写明「本 plan 不作废旧训练组，改以 fail-closed 互锁禁止已出货股的重导入；作废/版本化留独立 plan」——不写成已闭合。

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

### P3-D11：通用 CSV 路径必须堵住，否则新不变量是假的

codex R2-F1（high，**核实为真**）：`write_to_postgres`（既有通用 CSV 路径）直接改 `stocks`/`klines`，**既不取按股锁、也不更新 `stock_coverage`**。对一只已被 QMT 管理的股跑一次通用导入，就能让 klines 变了而 coverage 没变——P3-D5/D8 建立的不变量当场失效，B2 会拿「旧 coverage + 新 klines」建训练组。

我上一轮写的「`write_to_postgres` 原样保留、只加不改」在这条面前站不住：**保留一个能绕过不变量的写路径，等于没有不变量。**

**处置**（两件，都在它已有的事务内、都在任何 INSERT 之前）：

1. 取同一把按股锁——**非阻塞** `pg_try_advisory_xact_lock(IMPORT_GEN_LOCK_KEY, stock_lock_key(code))`（codex R8-F2，medium，**核实为真**：我上一轮把 QMT 写入器改成非阻塞正是为了避免「B2 卡住 → 导入无限期挂起」，却把通用路径这把新锁留成**阻塞**的——旁路又开了同一个挂起漏洞）。拿不到 → `ImportBusyError`（可重试、退非零），**不阻塞等待**。事务级即可（通用路径没有提交后的文件操作，锁不需活过 COMMIT）；
2. **fail-closed 拒写**：该股在 `stock_coverage` 有行 → 抛 `LegacyImportBlockedError`，零写入。提示语指向 `--qmt` 模式。

两项都在锁内 → check-and-write 原子，不存在「检查时没行、写的时候 QMT 导入刚提交」的缝。没有 coverage 行的股（pre-QMT 测试数据）行为完全不变，既有测试不受影响。

### P3-D9：出货可行性预检 + 拷贝完整性门——把「B2 静默不出货」真的挪到导入期

**（a）出货可行性预检**（codex R1-F4 提出、R8-F1 收紧为真正完整的检查）：

§1 把「日线必须全历史」写成硬约束，但一份**被截断/dense 1m 过短**的输入能过 D10 四门、写下 coverage，然后 B2 静默产 0——症状与"coverage 空表"一模一样。我上一版只查 `月边界 >= 39`，codex R8-F1（high，**核实为真**）指出这**不完整**：B2 出货还要求存在一个「8 个月前向窗口、其间每个交易日都落在 dense 1m 覆盖内」的合格起点。一只「日线 ≥ 39 个月、但 dense 1m 只有短短几个月」的股照样过 `>= 39`、写 coverage、B2 仍产 0。

**修法 = 不再用 `>= 39` 这个不完整代理，直接复用 B2 自己的合格性函数**（消掉代理 + 消掉「钉两处常量一致」的漂移风险）：

```python
# build_stock_import 内，coverage 算好之后：
cands = eligible_start_indices(month_boundaries, rng,
            dense_dates=dense_dates, trading_dates=trading_dates, dropped=dropped)
# eligible_start_indices 自身在 n < 31+months 时抛 GenerateSkipException；
# 无「全-dense 的 8 月前向窗口」时返回 []。两种都拒。
if 抛异常 or not cands:
    raise QmtIngestRejected("no_eligible_training_window")
```

`eligible_start_indices`（`backend/generate_training_sets.py:106`）就是 B2 `build_training_windows` 选起点用的**同一个**函数——B1 拿它当预检，`dense_dates` 集合与 B2 运行时**逐字一致**（不是另写一套判据、不会漂移）。空-vs-非空不依赖 `rng`（shuffle 不改成员集合），故预检决定确定。**这道预检天然包含旧的 `>= 39`**（函数内 `n < 31+months → raise`），故 `_MIN_MONTH_BOUNDARIES` 常量与其一致性测**一并删除**——没有代理就没有漂移。

> **依赖方向**：`qmt_ingest` → `generate_training_sets`（取 `eligible_start_indices`）。`generate_training_sets` 只 import `qmt_normalize`/`qmt_resample`，不 import `qmt_ingest`，无循环。

**（b）拷贝完整性门**（codex R2-F3）：预检管「数据够不够 B2 出货」，但不证「本地拷贝是否被截断」（SMB 传输中断、部分复制）。这个 `export_log.csv` 的 `first_time`/`last_time`/`rows` 可验，故独立增加（1m 与日线各查一次）：

```
export_log[file].rows       == len(原始 df)（clean 之前）
export_log[file].first_time == df 首行 time
export_log[file].last_time  == df 末行 time
```

任一不符 → `QmtIngestRejected("export_log_mismatch")`。

与 P3-D3 同一立场：`first_time`/`last_time` 的真实格式本会话无法逐字核对，**解析不出来就报错停下**，不静默跳过这道门。

另外，导入成功时**打印**日线首末日期 + 月边界数 + dense 带 —— 可观测性用来补「强制不了全历史」这块（运维一眼能看出这只股的日线是不是短得离谱）。

> **清洗顺序内的位置**：出货可行性预检要 `month_boundaries`/`dense_dates`/`trading_dates`，故排在 `build_intraday`+`resample_calendar`（算出 dense 覆盖与月边界）**之后**、`to_kline_records` 之前。拷贝完整性门要原始行数，仍在 `clean` 之前。

### P3-D12：破坏性替换前，写入器自己再 fail-closed 校验 bundle 形状

codex R7-F3（medium，**核实为真**）：`write_qmt_stock` 先 DELETE 该股六周期、再 INSERT bundle 的记录 + UPSERT coverage。这一整套的正确性**完全托付给上游** `build_stock_import` 产出一份完好 bundle。可 `write_qmt_stock` 是 `import_csv.py` 的公开写库壳，非-CLI 调用方（未来的批量导入、pilot 脚本、测试夹具）**可能绕过** `build_stock_import` 直接构造 bundle；`build_stock_import` 自身若回归、少算某个周期，也一样。此时 DELETE 照删六周期、INSERT 只填回残缺的几个 → **提交一次部分替换**，B2 之后读到缺周期或与 klines 不符的陈旧 coverage，坏数据无声进库。

这正是「无效输入进不来 / 矛盾不可表达」该守的地方（[[feedback_internal_review_misses_bad_data]]）——**破坏性操作不能只信任生产者**。故新增纯函数：

```python
validate_import_bundle(bundle, stock_code) -> None   # 不合规即 raise InvalidImportBundleError
```

在 `write_qmt_stock` **取连接之前**（能提前拦就提前，省一次 DB 往返）调用，断言：

- `bundle.records` 的 key 集合**恰好** == `PERIODS` 的六个周期（不多不少）；
- 每个周期的记录列表**非空**；
- 每条记录的 `stock_code` == 传入的 `stock_code`（防串股）；
- `coverage`：`start_date <= end_date`、`dense_day_count >= 0`、`dense_day_count == len(去重后的 dense 日期)`（与 `stock_coverage` 的三条 CHECK 同构，在写库前先于 Python 层挡一次，报错更清晰）。

任一不满足 → `InvalidImportBundleError`，**零 DELETE / 零 INSERT / 零 coverage 写入**。纯函数、host 单测，且**先于**取锁与 DELETE，故坏 bundle 连事务都进不去。

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
                └─ compute_indicators 逐周期 → to_kline_records → ImportBundle
                        │
                        └─ validate_import_bundle（六周期齐/非空/同股/coverage 自洽 → 否则拒，连接前）
                        └─【单事务】try 按股锁(拿不到→ImportBusyError) → 守卫 → 互锁(该股已有训练组→拒)
                                    → stocks → DELETE 该股六周期 klines → INSERT 6×klines
                                    → stock_coverage UPSERT ── COMMIT（锁自动释放）
                                    （只读 training_sets 作互锁、不删不改、不删 zip）
                                        │
                                        ▼
        B2 generate_one_training_set：
          ① try 按股锁(IMPORT_GEN_LOCK_KEY, stock_key)  ← 拿不到 = 该股正在导入，skip
          ② 【REPEATABLE READ READ ONLY 事务】coverage + 6×klines 一次快照读 → COMMIT
          ③ existing_starts → 全局 B2 锁 → 锁内 _exists_start → 写 zip → 登记
          ④ finally 释放全局锁、再释放按股锁
```

锁序恒为 **按股锁 → 全局锁**，B1 只取按股锁 → 无环、无死锁（P3-D8）。

---

## 4. 组件设计

### 4.1 `backend/qmt_ingest.py`（新，纯函数，无 asyncpg）

- `parse_export_log(path) -> dict[(code, period), ExportLogEntry]` + `@dataclass ExportLogEntry`（P3-D3；重复 key fail-closed）
- `build_stock_import(df_1m, df_daily, *, stock_code, stock_name, entry_1m, entry_daily) -> ImportBundle`（P3-D1/D2；两个 entry **必填无默认**）
- `class QmtIngestRejected(Exception)`：携带机器可读 `reason`
- 出货可行性预检**复用** `generate_training_sets.eligible_start_indices`（P3-D9(a)，不再自持 `_MIN_MONTH_BOUNDARIES` 代理）
- 内部顺序：**拷贝完整性门（P3-D9(b) `export_log_mismatch`，在 clean 之前——要比对的是原始行数）** → `clean` → `reconcile_sources`（含 status 门）→ `build_intraday` → `resample_calendar` ×2 → **出货可行性预检（P3-D9(a) `no_eligible_training_window`，需 month_boundaries/dense_dates/trading_dates）** → 逐周期 `compute_indicators` → `to_kline_records`

拒绝时**不做任何部分产出**（不返回「已经算好的那几个周期」）。

### 4.2 `backend/import_csv.py`（改，薄壳）

- `_assert_klines_price_columns_double` **签名与语义原样保留**；QMT 路径**另加**一条 `_assert_stock_coverage_exists`（`to_regclass('stock_coverage') IS NOT NULL`），同事务内紧随其后调用。防目标库未跑 migration 0004 时 klines 写成功、coverage 写失败 → 事务回滚但报错信息晦涩。
- `write_to_postgres`（通用 CSV 路径）**必须改**（P3-D11，非「只加不改」——见该决策）：事务内加按股**非阻塞** `pg_try_advisory_xact_lock`（拿不到→`ImportBusyError`）+ `stock_coverage` 有行即 `LegacyImportBlockedError` fail-closed。
- 新 `write_qmt_stock(dsn, stock_code, stock_name, bundle) -> WriteResult`（P3-D4 替换语义 + P3-D8 按股 **非阻塞** xact 锁 + P3-D10 重导入互锁 + P3-D12 bundle 校验）；返回每周期写入行数。取连接前先 `validate_import_bundle`；**只读 `training_sets` 一条 `SELECT 1` 作互锁、不删不改、不 unlink zip**。四种 fail-closed 各自独立异常：坏 bundle → `InvalidImportBundleError`；锁被占 → `ImportBusyError`（可重试）；已出货 → `ReimportBlockedError`；schema 漂移 → `SchemaDriftError`。全部零写入。
- `validate_import_bundle(bundle, stock_code)`（P3-D12，纯函数，无 asyncpg，host 单测）。
- CLI 新增 `--qmt` 分支（P3-D6），成功时打印：每周期行数 / dense 带 / 日线首末日期 + 月边界数（P3-D9 可观测性）；被互锁拒绝时打印 `ReimportBlockedError` 原因并退非零码。

### 4.3 `backend/generate_training_sets.py`（改，读路径 + 一把新锁）

- 新常量 `IMPORT_GEN_LOCK_KEY` + `stock_lock_key(stock_code) -> int`（P3-D8；纯函数，可 host 单测，B1 侧 import 它，保证两端用同一把 key —— **不允许两边各写一份 crc32**）。
- `generate_one_training_set`：最外层 try **session 级**按股锁（`pg_try_advisory_lock`）→ 把 coverage + 六周期读包进 `conn.transaction(isolation="repeatable_read", readonly=True)`（P3-D5）→ 其余流程不变 → `finally` 里在释放全局锁之后释放按股锁。
- **其它逻辑（交叉校验、窗口选择、全局锁的位置、写入、登记）一字不动。**

---

## 5. 测试与验证

### 5.1 host pytest（纯函数层，`backend/tests/test_qmt_ingest.py` 新建）

- **D10 四门各一条拒绝测**：export_log 非 ok / 日线尾部截断（`daily_not_cover_dense`）/ 跨度内日期集不等（`date_set_mismatch`）/ OHLCV 超容差（`ohlcv_mismatch`）→ 均抛 `QmtIngestRejected` 且 `reason` 精确匹配，**且断言零产出**。
- **D9(a)**：某日缺 1 根 1m → 该日**全部**盘中周期零行（不是只丢缺的那一桶），且该日不在 `dense_dates`。
- **清洗顺序**：某日一行价格为 0（被 `clean` 丢）→ 该日落入非 dense，而非伪装成完整日。
- **export_log 解析**：候选标识列各命中一例；候选全不命中 → 抛 `QmtSchemaError`；查不到条目 → 拒绝该股。
- **export_log 重复行（P3-D9/R8-F3）**：同 `(code,period)` 有 `error` + `ok` 两行 → 抛 `QmtSchemaError("export_log_duplicate")`，**不按行序取 ok**（mutation：把去重检测去掉、退回 dict 覆盖 → 此测必挂）。
- **coverage artifact 值**：`dense_day_count == len(dense_dates)`，端点 == 首/末 dense 日。
- **周期分工**：`daily` 行数 == 日线 CSV 清洗后行数（证明未按 1m 跨度裁剪）；`monthly`/`weekly` 不含 partial 当期。
- **P3-D9(a) 出货可行性预检**：构造两类都能过 D10 四门、都写得成 coverage 的输入 → ① 日线月边界只有 38 → 预检抛 `no_eligible_training_window`；② 日线 ≥ 39 个月**但 dense 1m 只覆盖短短几个月**（无「全-dense 的 8 月前向窗口」）→ **同样**抛 `no_eligible_training_window`（这一条正是 R8-F1：旧的 `>= 39` 代理漏掉它、B2 才会静默产 0）；③ dense 1m 与日线都够 → 放行。**断言 B1 预检用的就是 `generate_training_sets.eligible_start_indices` 本身**（mutation：把 B2 那个函数的合格判据改严 → B1 预检的行为跟着变、此测必挂，证明没有第二套判据在漂移）。
- **`stock_lock_key` 纯函数**：同一 code 恒定、落在 int4 正区间。
- **P3-D9(b) 拷贝完整性门**：`rows` 少一行 / `first_time` 对不上 / `last_time` 对不上 → 各一条 `export_log_mismatch`；`first_time` 格式解析不出 → 报错而非放行。**这三条必须直接调纯函数 `build_stock_import` 来测**（codex R3-F3：门若只存在于 CLI 里，非 CLI 调用方就绕过去了）；另加一条「不传 entry 就 `TypeError`」的签名测，钉住「没有默认放行的后门」。

### 5.2 host pytest（写库壳 / 读路径，假 asyncpg conn）

- `write_qmt_stock`：断言**所有写语句都发生在同一个 transaction 上下文内**；断言顺序 = bundle 校验 → try 按股锁 → schema 守卫 → **互锁 `SELECT 1`** → `DELETE` → `INSERT`；守卫失败 → 零 DELETE 零 INSERT（**尤其要证明守卫失败时不会先把旧数据删掉**）。
- **P3-D12 bundle 校验**（纯函数直测）：缺一个周期 / 某周期空列表 / 某记录 `stock_code` 串股 / coverage `start>end` / `dense_day_count` 对不上 → 各一条 `InvalidImportBundleError`；六周期齐全且自洽 → 通过。另测 `write_qmt_stock` 收到坏 bundle → **连 DB 都没连**（校验在取连接前）、零写入。
- **P3-D8 非阻塞锁**（假件）：`pg_try_advisory_xact_lock` 返回 False → `write_qmt_stock` 抛 `ImportBusyError` 且**零 DELETE 零 INSERT**、**不阻塞等待**（断言调用的是 `try` 变体、不是阻塞 `pg_advisory_xact_lock`）。
- **P3-D10 重导入互锁**：假存储里该股已有一行 `training_sets` → `write_qmt_stock` 抛 `ReimportBlockedError` 且**零 DELETE 零 INSERT**（旧 klines/coverage 一字不动）；该股无训练组 → 放行。**断言互锁 `SELECT 1` 排在 DELETE 之前**（否则先删了才发现该拒、旧数据已毁）。
- **替换语义**（P3-D4）：断言 `DELETE ... WHERE stock_code=$1 AND period = ANY(...)` 在任何 INSERT 之前、且六周期全覆盖。回归测：先写一份含旧日期的 bundle、**在尚无训练组的窗口内**再写一份窗口前滑的 bundle → 假存储里**不残留**旧窗口的盘中行（重导入前不 generate，绕开互锁；正是 P3-D10 说的可达窗口）。
- `stock_coverage` UPSERT 参数逐值断言（含 `dropped_1m_dates` 的 JSON 字符串形状与 `_fetch_dense_coverage` 解析对称——**同一条数据走一遍写再走一遍读**，而不是各测各的）。
- B2 读路径：断言 `conn.transaction` 以 `isolation="repeatable_read", readonly=True` 打开，且 coverage + 6 次 klines 读全部落在该事务内、`_fetch_existing_starts` 落在事务外。
- B2 按股锁（P3-D8）：断言取锁**发生在打开 RR 事务之前**、释放**发生在登记之后**、且释放顺序是先全局后按股；`pg_try_advisory_lock` 返回 False → `GenerateSkipException` 且**零 zip 写入**。
- **P3-D11 通用路径护栏**：目标股在 `stock_coverage` 有行 → `write_to_postgres` 抛 `LegacyImportBlockedError` 且**零 INSERT**；无行 → 行为与改动前逐字一致（既有测试全绿即为证）；断言锁与检查都在 INSERT 之前。

> 假件的界限：假 conn **不可能**证明 PG 的 RR 快照语义或 advisory lock 的跨连接互斥（这正是 `feedback_verify_foundational_infra_assumption_real_not_fake` 的坑：自写 double 会静默建模**错误**语义）。假件测的是「我们确实按预期参数、按预期顺序调了这些」；语义本身由 §5.3 证明，真写入器由 §5.4 证明。

### 5.3 真 PG 语义验证脚本（`backend/scripts/verify_repeatable_read_snapshot.py`）

参照现有 `backend/scripts/verify_advisory_lock_reentrancy.py` 的形态（docker `postgres:15.12` + asyncpg，一次性、不进 CI 套件）。此脚本用**手写 SQL 扮演 B1**，只验基础设施语义：

1. RR 只读事务内第一次读之后，另一连接 INSERT klines + UPDATE stock_coverage 并 **COMMIT**；同事务内第二次读**仍看到旧值**（coverage 与 klines 都验）。
2. 同一时刻，**事务外**的第三个连接**看得见**新值 —— 证明写方真的提交了（防「写方其实没写成，快照测试空转全绿」）。
3. `SHOW transaction_isolation` 在该事务内 == `repeatable read`；事务内尝试写 → 被 PG 拒（证明 `readonly=True` 真生效）。
4. 导入事务**未提交**时，外部连接**既看不到 coverage 行也看不到 klines 行**；提交后**同时**看到（P3-D4 原子性）。
5. **按股锁（P3-D8）**：连接 A 持 `pg_advisory_lock(K, s1)` → 连接 B 对同一 `s1` 的 `pg_try_advisory_lock` 返回 **False**、对不同股 `s2` 返回 **True**（证明按股隔离真的按股，而不是退化成全局或形同虚设）。
6. **B1 事务级锁足够 + 非阻塞不挂起（P3-D8 / R7-F2）**：连接 A 持 session 锁 `pg_advisory_lock(K, s1)`（模拟 B2 正生成、且卡住不放）→ 连接 B 用 **`pg_try_advisory_xact_lock(K, s1)`** 立刻返回 **False**（**不阻塞**，证明 B1 导入不会无限期挂在卡住的 B2 后面）；A 释放后 B 的 try 返回 **True** 并随其事务提交自动释放（证明 B1 锁如期释放、不多占）。**反向对照**：若 B 改用阻塞 `pg_advisory_xact_lock`，A 持锁期间该调用会**卡住**（脚本用短超时探测到「阻塞发生了」）——证明 try 与阻塞语义的差别真实存在，B1 选 try 确实避免了挂起。B2 的 session 级锁另由 §5.2 假件测顺序 + 第 5 条互斥语义共同覆盖。

脚本输出逐条 PASS/FAIL，任何一条 FAIL 即非零退出。

### 5.4 真 PG 端到端链路脚本（`backend/scripts/verify_qmt_pg_chain.py`）——L2，**合并前必跑**

codex R1-F3（medium，**核实为真**）：§5.5 那条 CI 集成测的存储层是假 conn，`write_qmt_stock` 的真 SQL / 参数绑定 / JSONB 编解码 / 事务行为一行都没跑过；只有它绿就宣称链路可用属过度宣称。故新增这条脚本，跑**真**代码路径：

**顺序严格按生产真实时序排**（codex R6-F1，high，**核实为真**：我上一版把「generate 登记」排在「重导入证替换」之前，可 P3-D10 互锁一旦有训练组行就在 DELETE 之前抛 `ReimportBlockedError` → 替换路径永远到不了，L2 声称验替换却验不到。这是我加互锁时自己引入的排序回归）。正确时序 = **导入 → 未生成时重导入证替换 → 生成 → 已生成后重导入证互锁**：

```
docker postgres:15.12 → 应用 schema.sql
  ① 真 build_stock_import(fixture A) → 真 write_qmt_stock   ← 首次导入（此刻该股尚无训练组）
  ② 真 build_stock_import(窗口前滑的 fixture B) → 真 write_qmt_stock  ← 仍无训练组，互锁放行
       断言：DELETE+INSERT 替换生效——旧窗口盘中行从库里消失（P3-D4，可达因为还没 generate）
  ③ 真 generate_one_training_set(真 conn, ...)              ← 真 RR 事务 / 真两把锁；登记 training_sets 行
       断言：磁盘真出现 zip、training_sets 真有登记行、content_hash 与 zip 字节相符
       断言：stock_coverage 行内容 == 最后一次 build_stock_import 的 CoverageArtifact
  ④ 真 write_qmt_stock(同一只股)                            ← 此刻已有训练组
       断言：真抛 ReimportBlockedError、klines/coverage/training_sets 零变化（P3-D10 互锁）
  ⑤ 真 write_to_postgres(同一只股，通用 CSV 路径)
       断言：真抛 LegacyImportBlockedError、库里零变化（P3-D11）
```

替换（②）与互锁（④）落在**同一只股的两个不同时点**，天然不冲突、都真跑到；核心出货（③）也在其间被证。

**这条 L2 脚本是 `write_qmt_stock` 真 SQL 唯一被真跑的地方，重要性最高——但它不是自动化门（见下）。合并前由控制者本人真跑一次，完整输出贴进 PR body。**

> **F2 收口（codex R5-F2，medium，核实为真；user 2026-07-23 裁决＝降级措辞、不进 CI）**：我上一版把 L2 写成「阻断门」，但它只靠人肉贴输出、CI 不强制 —— 这是**名不副实的门**（CI 可以全绿而 L2 从未跑）。诚实的收口是**降级它的宣称**，而不是假装它是自动门：
> - L2 的定位改为「**合并前必须由控制者真跑并贴输出的流程步骤**」，**不是** CI 自动门。
> - 因此 §0.2 的口径同步修正：**CI 绿 ≠ 链路已证**；「B1→B2 通了」这个结论的证据是「L1 CI 绿 **且** 控制者贴出的 L2 真跑输出」，后者是流程纪律、非机器强制。
> - **不进 CI 的取舍**：把 `verify_qmt_pg_chain.py` 做成带 postgres service 的必需 CI job 是更强的保证，但那是 `.github/workflows` 改动＝信任边界 + CI 治理，需单独过 codex 审 workflow，且扩这批 PR 的范围。user 裁决先降级措辞、把「真-PG 进 CI」留作独立的 CI 治理改动（与 Plan 4 容器化 smoke 合并考虑）。**这条取舍如实写进 PR body，不含糊。**

### 5.5 端到端逻辑链集成测（`backend/tests/test_qmt_e2e_generation.py` 新建）——L1，进 CI

`QMT fixture CSV → build_stock_import → 假 conn 充当存储 → 真 generate_batch → 断言 ≥1 个 zip 产出且 training_sets 有登记行`。

- fixture **不进仓**：dense 1m 一年 ≈ 242 交易日 × 241 根 ≈ 5.8 万行（**估算**，实施时以实际生成为准），落盘约数 MB。用测试内**生成器函数**造 DataFrame / 临时 CSV，仓里只保留现有小样本 `backend/tests/fixtures/sample_1m.csv` 供解析级测试。
- fixture 跨度须同时喂饱：B2 的 8 个前向月 + 盘中 before-context（3m/15m/60m 各 150 根 → 最长 60m 需 ~38 个交易日）+ 日线/月线 before-context（monthly 全取 → 日线需数年历史）。**日线造多年、1m 只造近一年**，正是真实 QMT 的形状。
- 断言产出 zip 的 `content_hash` 与磁盘字节一致（沿用现有 helper），并断言 `generate_batch` 返回的成功计数 ≥1。

### 5.6 mutation 验证（强制）

每一条新增的门测试必须做 mutation：把被测的门改坏 → 对应测试**必须挂**。至少覆盖这几处：`date_set_mismatch` 判据改成恒 True、事务隔离级别改回默认、`readonly` 去掉、coverage 写入注释掉、**`DELETE` 去掉（替换退化成 UPSERT）**、**按股锁改成恒返回 True**、**出货可行性预检去掉（`no_eligible_training_window` 不再拦、dense-1m-过短的股能过导入）**、**`export_log_mismatch` 门改成恒放行**、**export_log 去重检测去掉（重复行退回 dict 覆盖）**、**通用路径护栏去掉**、**`entry_1m/entry_daily` 给上默认值**、**P3-D10 互锁 `SELECT 1` 去掉（重导入不再被拦）**、**互锁排到 DELETE 之后（先删才发现该拒）**、**`validate_import_bundle` 去掉某条断言（P3-D12：少周期/空/串股/coverage 反向能溜进 DELETE）**、**两条写入路径的锁从 `try` 改回阻塞 `pg_advisory_xact_lock`（不挂起测必挂）**。由控制者本人复验，不采信 subagent 自证。

### 5.7 闸门纪律

- 所有 pytest 用仓库根 `.venv`（Python 3.11）：`cd backend && ../.venv/bin/python -m pytest tests/ -q`。host `python3` 是 3.14，跑 pandas 会段错误。
- 任何 `cmd | tail/grep` 都加 `set -o pipefail` 或改 `cmd; echo EXIT=$?`；判绿读输出内容，不看 exit code。
- 每条闸门/git 命令同时打印 `branch` + `HEAD`。
- 基线：`main` `08d70d2` = **`255 passed`（本文写作时已实测确认，非从记忆推断）**。任何 Task 结束时测试数只增不减，且 0 failed / 0 skipped。CI 禁 skip，不得新增任何 `skip`/`xfail`。

---

## 6. 验收标准（spec 级；非-coder 验收清单在 plan 阶段出）

1. 用 fixture QMT CSV 跑 B1 QMT 模式 → `stock_coverage` 有该股一行，端点/`dense_day_count`/`dropped` 与 `compute_dense_coverage` 一致。
2. **L1（CI 机器强制）**：假 conn 存储上跑 `generate_batch` → 真产出 ≥1 个训练组 zip + `training_sets` 有登记行。
3. **L2（流程纪律，非 CI 门）**：真 PG 上跑**真** `write_qmt_stock` + **真** `generate_one_training_set` → 真出 zip（`verify_qmt_pg_chain.py`，控制者真跑、输出贴 PR body）。**L1 CI 绿 + L2 输出贴出，两者齐备才算「出货能力被证明」**——CI 绿本身不等于链路已证（§0.2 F2 口径）。这是 Plan 3 的核心验收项，也是 Plan 2 无法做到的那一条。
4. D10 四门、D9(a)、P3-D9 日线历史门各有一条拒绝路径被测试覆盖，拒绝时数据库零写入。
5. B2 的 coverage + 六周期读在同一个 RR 只读事务内（假件测参数 + 真 PG 脚本测语义，两者都绿）。
6. B1 导入是**替换**而非叠加：在**尚无训练组的窗口内**重导一份窗口前滑的 bundle 后，旧窗口盘中行从库里消失（假件回归测 + 真 PG 脚本 ② 各一条）。**真 PG 脚本的时序 = 导入 → 未生成时重导入证替换 → 生成 → 已生成后重导入证互锁**，替换与互锁不互相遮蔽（§5.4）。
7. 按股锁真的按股：同股互斥、异股不互斥、B1 事务级锁随提交释放（真 PG 脚本第 5、6 条）。
8. **四道写入器 fail-closed**（各零写入）：① 坏 bundle → `InvalidImportBundleError`（P3-D12，破坏性 DELETE 之前）；② 通用 CSV 路径对已被 QMT 管理的股拒写（P3-D11）；③ QMT 重导入对已出过货的股拒写（P3-D10 互锁）；④ 该股正被 B2 生成 → `ImportBusyError` 可重试、**不挂起**（P3-D8 非阻塞，真 PG 脚本第 6 条）。对未被管理/未出货/合法 bundle 的股行为逐字不变。
9. 日线：**只宣称**「导入期已用 B2 合格性判据预检过可出货（`no_eligible_training_window` 拦掉 dense-1m-过短的股）+ 拷贝完整性（export_log 端点/行数）已强制」，**不宣称**「已验证全历史」。
10. **明确不做**：重导入不**作废**已存在的 `training_sets`（P3-D10 只加 fail-closed 互锁禁止已出货股的重导入；作废/版本化拆独立 plan）。PR body 写明这条口径，不假装闭合。
11. 后端 pytest 全绿、零 skip；PR CI 全绿。

---

## 7. 风险 / 开放项

| 风险 | 处置 |
|---|---|
| `export_log.csv` 真实列名未逐字核对 | P3-D3 候选集 + fail-closed 报错；Plan 4 挂 SMB 时逐字核对并收窄 |
| 端到端 fixture 体量大、测试变慢 | 生成器造数据、不落仓；若单测超时明显，可把 1m 跨度收到刚好喂饱 B2 的最小天数（实施期实测决定，不预先猜） |
| `PERIOD_BEFORE_CAP` 与真实 1m 只有一年 → 真数据可能候选稀疏 | 属 Plan 4 真跑时的产能问题；Plan 3 只需证明通路，产能低会在 Plan 4 的储备池替补机制里显性化 |
| RR 事务拉长了 B2 单股读的事务时长 | B2 是单用户内网批处理，长只读事务不冲突；且早退路径仍在第一条语句后返回 |
| B1 导入与 B2 生成同股冲突 | B1 用**非阻塞** `pg_try_advisory_xact_lock`（P3-D8 / R7-F2）：拿不到即 `ImportBusyError`、CLI 退非零、运维重试，**不无限期挂起**。不损新鲜度不变量（B1 失败即不导入、不会竞态提交） |
| **已出货股无法用 Plan 3 重导入**（被 P3-D10 互锁拦下） | 有意的 fail-closed：在作废/版本化能力落地前，宁可拒绝重导入也不让旧 zip 与新 klines 并存。真需要重导入某只已出货股时，触发那个独立 plan。CLI 报错明确指向此 |
| **重导入后旧训练组的作废/版本化**（让 B3 只发当前版本） | **拆独立 plan**（P3-D10 ①）：需 import 版本号/`retired` 状态 + B3 `/download`+`/confirm` 语义变更。互锁已挡住「已出货股产生新旧并存」的路径，故本 plan 无此紧迫性。PR body 如实写明 |
| **L2 真-PG 非 CI 自动门**，靠控制者真跑 + 贴输出（codex R5-F2 提、R7-F1 再提） | **user 已裁决接受**（2026-07-23：降级措辞、不进 CI）：把真-PG 进 CI（带 postgres service）是独立 CI 治理改动、需单独审 workflow。诚实收口＝§0.2「CI 绿 ≠ 链路已证」+ PR body 贴 L2 输出。**codex R7 再提此条，属已裁决残留，override 收口——非新问题** |

---

## 8. 流程

brainstorming（本文）→ codex spec review → writing-plans → codex plan review → subagent-driven 实施（Sonnet high）→ host pytest 三绿 → requesting-code-review → whole-branch codex（`--scope branch-diff`）→ PR（user push/merge）。

**PR 切分（每 PR ≤3 子项 ≤500 行）：**

| PR | 内容 | 子项 |
|---|---|---|
| **3a** | `qmt_ingest.py` 纯装配层（含 P3-D9 两道门）+ `test_qmt_ingest.py` | 2 |
| **3b** | B2：RR 只读事务 + 按股锁（`stock_lock_key`/`IMPORT_GEN_LOCK_KEY`）+ 假 conn 断言测 + `verify_repeatable_read_snapshot.py`（6 条语义断言） | 3 |
| **3c** | B1 写库壳（替换语义 + 按股**非阻塞**锁 + coverage UPSERT + 存在断言 + P3-D10 互锁 + P3-D12 `validate_import_bundle`）+ P3-D11 通用路径护栏 + 假 conn 单测 + CLI `--qmt` | 3 |
| **3d** | L1 端到端集成测（fixture 生成器）+ L2 `verify_qmt_pg_chain.py` 真链路脚本 | 2 |

**顺序理由**：3b 先于 3c，让后面的端到端跑在最终读路径上，不必写完再改。四道写入器 fail-closed（P3-D12 bundle 校验 + P3-D8 非阻塞 + P3-D10 互锁 + P3-D11 护栏）都贴着 `write_qmt_stock`、天然同批进 3c；`validate_import_bundle` 是纯函数，与写库壳同 PR 而非拆去 3a（它的存在意义就是护住这个破坏性写入器）。若 3c 实测超 500 行，把 CLI `--qmt` 拆成独立 3e。**3d 的 PR body 必须**：① 贴 L2 脚本完整输出；② 写明「CI 绿 ≠ 链路已证，凭 L2 输出」（F2 口径）；③ 写明「重导入不作废旧训练组、改以互锁禁止已出货股重导入，作废/版本化拆独立 plan」（P3-D10 口径）。

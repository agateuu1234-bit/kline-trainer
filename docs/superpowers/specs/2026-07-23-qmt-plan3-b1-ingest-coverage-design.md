# QMT 数据接入 Plan 3：B1 接规整/合成层 + 写 `stock_coverage` 设计（2026-07-23）

> 上游 spec：`docs/superpowers/specs/2026-07-06-qmt-data-ingestion-pilot-design.md`（D1-D11 决策的权威出处，本文只在**它未定或需收窄**处新增决策，不复述）。
> 上游 plan：`docs/superpowers/plans/2026-07-18-qmt-plan2-b2-reconnect.md`（§Self-Review「明确不在本 plan、留 Plan 3」清单）。

---

## 0. 目标 / 范围 / 非范围

### 0.1 目标（一句话）

让 **B1（`import_csv.py` 侧）真正接上 Plan 1 已 merge 但零调用方的 QMT 规整/合成层**，导入时把权威 dense 覆盖写进 `stock_coverage`，从而**解除 B2/B4 恒产 0 的根因**；同时消除 Plan 2b 遗留的「coverage 与六周期 klines 无统一快照」残留。

### 0.2 交付口径（诚实义务，沿用 Plan 2 的做法）

Plan 3 交付的是「出货能力被证明」，**但证明分两层、口径必须分开写**（codex R1-F3：原口径说「CI 里有一条真链路」是**过度宣称**——CI 里那条链的存储层是假 conn，`write_qmt_stock` 的真 SQL / asyncpg 参数绑定 / JSONB 编解码 / 事务行为**一行都没跑过**）：

| 层 | 证明什么 | 在哪跑 | 是否阻断 |
|---|---|---|---|
| **L1 逻辑链** | `QMT fixture → build_stock_import → 假 conn 存储 → 真 generate_batch → ≥1 个 zip` | CI（host pytest） | 是（CI 必绿） |
| **L2 真写入器** | 真 PG 上跑**真** `write_qmt_stock` + **真** `generate_one_training_set` → 真出 zip；并验事务/隔离/原子性语义 | `backend/scripts/verify_qmt_pg_chain.py`（一次性脚本，需 Docker PG） | 是（**PR 合并前必跑，输出贴进 PR body**；不进 CI 套件） |

**L1 单独绿不足以宣称链路可用**——必须 L1 + L2 都绿。任何只有 L1 绿就写「B1→B2 通了」的表述，视同过度宣称。

Plan 3 **不**交付「已经用真 QMT 数据产出 100 个训练组」。真跑属 Plan 4。

**禁止**在任何 commit message / PR body / 验收项里写「pilot 已完成」「100 股已出货」之类表述。

### 0.3 范围（in scope）

1. B1 侧 **D9(a) 分钟级完整性** 与 **D10 双源对账** 的强制（调用已 merge 的 `build_intraday` / `reconcile_sources`，不重写算法）。
2. B1 写 6 周期 `klines` + `stock_coverage`，**单事务原子**，且是**整体替换**而非 UPSERT 叠加（P3-D4）。
3. B1 QMT 模式 CLI（单只股）。
4. B2 侧 **快照一致性**：coverage + 六周期 klines 在同一个 `REPEATABLE READ READ ONLY` 事务内读取（P3-D5）。
5. **按股导入/生成互斥锁**（P3-D8）——补齐 RR 事务不覆盖的「新鲜度」那一半。
6. **日线历史长度门 + 拷贝完整性门**（P3-D9）——把「导入看似成功、B2 静默不出货」和「拷贝被截断」的失败面提前到导入期。
7. **重导入作废该股可领取库存**（P3-D10）——修正性重导入后，旧产物不再被 B3 发出去。
8. **通用 CSV 路径对已被 QMT 管理的股 fail-closed**（P3-D11）——堵住绕过上述不变量的写路径。
9. 上述各项的 host pytest 覆盖 + 两条一次性**真 PG** 脚本（语义验证 + 真链路端到端）+ CI 内的逻辑链集成测。

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

**由 `monthly: None`（before-context 全取）推出的约束，措辞必须精确**（codex R2-F3）：

- **能强制的**：月边界 ≥ 39（否则 B2 必不出货）+ 日线不得按 1m 跨度裁剪 + 日线内容必须与 export_log 记录的端点/行数一致（P3-D9）。
- **不能强制的**：「这份日线就是该股全部历史」。本地没有上市日期的独立真值源，一份「四年、但覆盖住 dense 1m」的日线与「一只只上市四年的股票」在数据上无法区分。
- 因此本 spec **不宣称**能保证全历史。宣称的是：**给多少日线就用多少**（monthly before-context 全取），**下限 39 个月边界**，**且拷贝完整性有门**。§6 验收标准按这个口径写，不写「已验证全历史」。

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
> | P3-D9 | 日线历史长度门 + 拷贝完整性门 | R1-F4 / R2-F3 |
> | P3-D10 | 重导入作废可领取库存 | R2-F2（推翻 R1 的不可变政策） |
> | P3-D11 | 通用 CSV 路径 fail-closed | R2-F1 |

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

### P3-D4：B1 写入 = **一只股一个事务的整体替换**（不是 UPSERT 叠加）

```
BEGIN
  pg_advisory_xact_lock(IMPORT_GEN_LOCK_KEY, stock_key)   ← P3-D8
  LOCK TABLE klines, stock_coverage IN ROW EXCLUSIVE MODE
  → D8a schema 守卫（沿用现有）+ stock_coverage 存在断言
  → stocks UPSERT
  → DELETE FROM klines WHERE stock_code=$1 AND period = ANY(六周期)    ← 替换语义
  → 6 × klines executemany INSERT（沿用现有 _KLINE_INSERT 的 UPSERT 形式，兜底幂等）
  → stock_coverage UPSERT（ON CONFLICT (stock_code) DO UPDATE）
COMMIT
```

**为什么必须 DELETE 而不是纯 UPSERT**（codex R1-F2，high，**核实为真且机制比 codex 的论证更具体**）：

QMT 的 **1m 导出只保留约一年**，服务端截断。第二次导出时这个窗口**整体向前滑动**——旧窗口起始那几个月的日期**不再出现在新 bundle 里**。纯 UPSERT 只覆盖新旧 datetime 交集，滑出去的那批 `3m/15m/60m` 行会**永久留在 klines 里**。

真正致命的是：**这些是前复权价**。发生分红/送转后，同一历史 datetime 的前复权价会被**整体重算成新基准**。于是库里出现「新基准的近一年盘中 + 旧基准的更早盘中」混杂，而 `stock_coverage` 声称的 dense 带只覆盖新的那段。B2 的 `select_period_window` 取 before-context 时**不受 dense 约束**（`PERIOD_BEFORE_CAP` 各周期 150 根），一旦回溯到旧基准区间，训练组里就会出现**同一张图上两套复权基准的蜡烛**——价格在拼接处凭空跳空。这类坏数据不会让任何测试变红。

日线/周线/月线本身是全历史、每次导出都全覆盖，纯 UPSERT 就已一致；但**六周期一律走 DELETE + INSERT**，理由是判据统一（不需要维护「哪些周期会滑窗」这张易腐清单），且成本相同（同事务内一只股约数万行，本就要写）。

`klines` 无任何外键指向它，已生成的 zip 是自包含产物，DELETE 不影响 `training_sets`（相关政策见 P3-D8）。

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
| B1 `write_qmt_stock` | `pg_advisory_xact_lock(IMPORT_GEN_LOCK_KEY, stock_key)`（**阻塞式、事务级**） | 事务开头取，COMMIT/ROLLBACK 自动释放，不会泄漏 |
| B2 `generate_one_training_set` | `pg_try_advisory_lock(IMPORT_GEN_LOCK_KEY, stock_key)`（**try、session 级**），拿不到 → `GenerateSkipException`（该股正在被导入，跳过） | **在打开 RR 快照之前**取，**直到登记完成**才在 `finally` 里释放 |

于是「B2 的快照 → 建 zip → 登记」这整段期间，该股**不可能**有导入提交；RR 保一致、这把锁保新鲜，两者合起来才是完整不变量。

**锁序（防死锁）**：B2 的取锁顺序恒为 `IMPORT_GEN_LOCK_KEY(按股)` → `B2_GENERATION_LOCK_KEY(全局)`，B1 只取前者。不存在反序路径，故无环、无死锁。事务级与 session 级 advisory lock 共用同一锁空间，两者互相冲突判定正常。

### P3-D10：重导入作废该股的**可领取库存**（R1 那条「不可变政策」已被推翻）

R1 时我裁决「训练组是冻结产物、重导入不作废旧的、清理属运维」。codex R2-F2（high）指出这个裁决站不住，**核实后我同意**：

`training_sets.status ∈ {unsent, reserved, sent}`（`schema.sql` 的 `ck_status_enum`），而 `lease_repo.py:123-124` 的可领取判据是 `status='unsent' OR (status='reserved' AND lease_expires_at <= now)`。也就是说，一次**修正性**重导入之后，**用已知错误数据生成的 zip 仍然会被 B3 正常发给用户**——而且库里没有任何字段能把「当前版本产物」和「被取代的产物」分开，所谓「运维清理」实际只能整股全删。这不是可靠恢复。

**处置**：`write_qmt_stock` 成功导入后，在**同一事务内**删除该股**可领取集合**的 `training_sets` 行：

```sql
DELETE FROM training_sets
 WHERE stock_code = $1
   AND (status = 'unsent' OR (status = 'reserved' AND lease_expires_at <= now()))
 RETURNING file_path
```

判据**逐字复用 `lease_repo` 的可领取判据**（不另写一套——`feedback_internal_review_misses_bad_data` 的教训：判据分叉会挪动失败面）。事务提交**之后**再 best-effort `unlink` 那些 `file_path`；顺序不能反（先删文件后回滚 = 行还在但文件没了，B3 404 永久卡死）。反过来留下的孤儿 zip 是无害的——没有任何行引用它，与既有代码里「写完 zip 崩在登记前」的自愈论证同构。

**被刻意排除的两类，及理由**：

| 类别 | 处置 | 理由 |
|---|---|---|
| `status='sent'` | **不动、不追回** | 已经交付到用户设备上的 zip 是自包含产物，追不回也不该追。每个 zip 内部只含单一复权基准，回放是一张自洽的图 |
| `status='reserved'` 且 lease **未过期** | **不删，但打印警告列出这些 id** | 正有客户端在下载它。删 = 必然打断一次进行中的下载；不删 = 只在「这次重导入恰好是修正」时才有害。确定的破坏 vs 条件性的危害，选后者 |

> **已知窄残留（如实记录，不假装闭合）**：上面第二类在 lease 过期后会被 `rollback_expired` 翻回 `unsent`，于是一个旧导入的产物可能重新进入库存。要完全闭合需要给 `stock_coverage`/`training_sets` 加 import 版本号并让 B3 只发当前版本（即 codex 的建议），那是 A 类 DDL + B3 发放语义变更，**明确留作后续独立改动**。本 plan 的口径是：**导入完成的那一刻，可领取库存里没有该股的旧产物**；活跃 lease 的回流窗口 = 一个 lease TTL，已知、已记录。

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

1. 取同一把按股锁 `pg_advisory_xact_lock(IMPORT_GEN_LOCK_KEY, stock_lock_key(code))`；
2. **fail-closed 拒写**：该股在 `stock_coverage` 有行 → 抛 `LegacyImportBlockedError`，零写入。提示语指向 `--qmt` 模式。

检查在锁内 → check-and-write 原子，不存在「检查时没行、写的时候 QMT 导入刚提交」的缝。没有 coverage 行的股（pre-QMT 测试数据）行为完全不变，既有测试不受影响。

### P3-D9：日线历史长度门——导入期就拒，别留到 B2 静默不出货

codex R1-F4（medium，**核实为真**）：§1 把「日线必须全历史」写成硬约束，但校验只有「断言没按 1m 跨度裁剪」。一份**被截断但仍覆盖住 dense 1m 窗口**的日线能过 D10 全部四门、写下 coverage 行，然后 B2 在 `eligible_start_indices` 里因月边界不足抛 skip——**失败面被推迟到出货阶段，且症状（"仅生成 0"）与"coverage 空表"长得一模一样**。

故 `build_stock_import` 增加一道门：

```
len(period_boundaries(df_daily, "monthly")) >= 39   →  否则 QmtIngestRejected("daily_history_too_short")
```

**39 这个数字来自源码实测、非从 spec 抄**：`eligible_start_indices`（`backend/generate_training_sets.py:119-122`）判 `if n < 31 + months: raise`，生产 `months=8` → `n >= 39`；候选区间 `lo, hi = 30, n - 1 - months`。约合 3.25 年日线历史。

门的常量写成 `_MIN_MONTH_BOUNDARIES = 31 + 8`，并在测试里**钉住它与 `eligible_start_indices` 的判据一致**（改一边不改另一边 → 测试挂），避免两处数字各自漂移。

**但 39 只是「能不能出货」的下限，不是「日线是否完整」的证明**（codex R2-F3）。真正的失败模式是**本地拷贝被截断**（SMB 传输中断、部分复制），这个是可验的——`export_log.csv` 自带 `first_time` / `last_time` / `rows`。故同时增加**拷贝完整性门**（1m 与日线两个文件各查一次）：

```
export_log[file].rows       == len(原始 df)（clean 之前）
export_log[file].first_time == df 首行 time
export_log[file].last_time  == df 末行 time
```

任一不符 → `QmtIngestRejected("export_log_mismatch")`。

与 P3-D3 同一立场：`first_time`/`last_time` 的真实格式本会话无法逐字核对，**解析不出来就报错停下**，不静默跳过这道门。

另外，导入成功时**打印**日线首末日期 + 月边界数 + dense 带 —— 可观测性用来补「强制不了全历史」这块（运维一眼能看出这只股的日线是不是短得离谱）。

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
                        └─【单事务】xact 锁(按股) → 守卫 → stocks
                                    → DELETE 该股六周期 klines → INSERT 6×klines
                                    → stock_coverage UPSERT ── COMMIT（锁自动释放）
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

- `parse_export_log(path) -> dict[(code, period), str]`（P3-D3）
- `build_stock_import(df_1m, df_daily, *, stock_code, stock_name, status_1m, status_daily) -> ImportBundle`（P3-D1/D2）
- `class QmtIngestRejected(Exception)`：携带机器可读 `reason`
- `_MIN_MONTH_BOUNDARIES = 31 + 8`（P3-D9）
- 内部顺序：**拷贝完整性门（P3-D9 `export_log_mismatch`，在 clean 之前——要比对的是原始行数）** → `clean` → `reconcile_sources`（含 status 门）→ **日线历史长度门（P3-D9）** → `build_intraday` → `resample_calendar` ×2 → 逐周期 `compute_indicators` → `to_kline_records`

拒绝时**不做任何部分产出**（不返回「已经算好的那几个周期」）。

### 4.2 `backend/import_csv.py`（改，薄壳）

- `_assert_klines_price_columns_double` **签名与语义原样保留**；QMT 路径**另加**一条 `_assert_stock_coverage_exists`（`to_regclass('stock_coverage') IS NOT NULL`），同事务内紧随其后调用。防目标库未跑 migration 0004 时 klines 写成功、coverage 写失败 → 事务回滚但报错信息晦涩。
- `write_to_postgres`（通用 CSV 路径）**必须改**（P3-D11，非「只加不改」——见该决策）：事务内加按股 xact 锁 + `stock_coverage` 有行即 `LegacyImportBlockedError` fail-closed。
- 新 `write_qmt_stock(dsn, stock_code, stock_name, bundle) -> WriteResult`（P3-D4 替换语义 + P3-D8 按股 xact 锁 + P3-D10 库存作废）；返回每周期行数 + 被作废的 `training_sets` id/路径 + 被跳过的活跃 lease id 列表（供 CLI 打印）。
- CLI 新增 `--qmt` 分支（P3-D6），成功时打印：每周期行数 / dense 带 / 日线首末日期 + 月边界数（P3-D9 可观测性）/ 作废了几个库存 / 哪些活跃 lease 被跳过。

### 4.3 `backend/generate_training_sets.py`（改，读路径 + 一把新锁）

- 新常量 `IMPORT_GEN_LOCK_KEY` + `stock_lock_key(stock_code) -> int`（P3-D8；纯函数，可 host 单测，B1 侧 import 它，保证两端用同一把 key —— **不允许两边各写一份 crc32**）。
- `generate_one_training_set`：最外层 try 按股锁 → 把 coverage + 六周期读包进 `conn.transaction(isolation="repeatable_read", readonly=True)`（P3-D5）→ 其余流程不变 → `finally` 里在释放全局锁之后释放按股锁。
- **其它逻辑（交叉校验、窗口选择、全局锁的位置、写入、登记）一字不动。**

---

## 5. 测试与验证

### 5.1 host pytest（纯函数层，`backend/tests/test_qmt_ingest.py` 新建）

- **D10 四门各一条拒绝测**：export_log 非 ok / 日线尾部截断（`daily_not_cover_dense`）/ 跨度内日期集不等（`date_set_mismatch`）/ OHLCV 超容差（`ohlcv_mismatch`）→ 均抛 `QmtIngestRejected` 且 `reason` 精确匹配，**且断言零产出**。
- **D9(a)**：某日缺 1 根 1m → 该日**全部**盘中周期零行（不是只丢缺的那一桶），且该日不在 `dense_dates`。
- **清洗顺序**：某日一行价格为 0（被 `clean` 丢）→ 该日落入非 dense，而非伪装成完整日。
- **export_log 解析**：候选标识列各命中一例；候选全不命中 → 抛 `QmtSchemaError`；查不到条目 → 拒绝该股。
- **coverage artifact 值**：`dense_day_count == len(dense_dates)`，端点 == 首/末 dense 日。
- **周期分工**：`daily` 行数 == 日线 CSV 清洗后行数（证明未按 1m 跨度裁剪）；`monthly`/`weekly` 不含 partial 当期。
- **P3-D9 日线历史门**：构造一份**覆盖住 dense 1m 窗口、但月边界只有 38 个**的日线 → 抛 `daily_history_too_short`（若无此门，它会过 D10 全部四门、写下 coverage、然后在 B2 静默不出货）；39 个月边界 → 放行。另加一条**判据一致性测**：`qmt_ingest._MIN_MONTH_BOUNDARIES` == `generate_training_sets` 里 `eligible_start_indices` 的实际门限（改一边不改另一边即挂）。
- **`stock_lock_key` 纯函数**：同一 code 恒定、落在 int4 正区间。
- **P3-D9 拷贝完整性门**：`rows` 少一行 / `first_time` 对不上 / `last_time` 对不上 → 各一条 `export_log_mismatch`；`first_time` 格式解析不出 → 报错而非放行。

### 5.2 host pytest（写库壳 / 读路径，假 asyncpg conn）

- `write_qmt_stock`：断言**所有写语句都发生在同一个 transaction 上下文内**；断言顺序 = 按股 xact 锁 → schema 守卫 → `DELETE` → `INSERT`；守卫失败 → 零 DELETE 零 INSERT（**尤其要证明守卫失败时不会先把旧数据删掉**）。
- **替换语义**（P3-D4）：断言 `DELETE ... WHERE stock_code=$1 AND period = ANY(...)` 在任何 INSERT 之前、且六周期全覆盖。回归测：先写一份含旧日期的 bundle、再写一份窗口前滑的 bundle → 假存储里**不残留**旧窗口的盘中行。
- `stock_coverage` UPSERT 参数逐值断言（含 `dropped_1m_dates` 的 JSON 字符串形状与 `_fetch_dense_coverage` 解析对称——**同一条数据走一遍写再走一遍读**，而不是各测各的）。
- B2 读路径：断言 `conn.transaction` 以 `isolation="repeatable_read", readonly=True` 打开，且 coverage + 6 次 klines 读全部落在该事务内、`_fetch_existing_starts` 落在事务外。
- B2 按股锁（P3-D8）：断言取锁**发生在打开 RR 事务之前**、释放**发生在登记之后**、且释放顺序是先全局后按股；`pg_try_advisory_lock` 返回 False → `GenerateSkipException` 且**零 zip 写入**。
- **P3-D10 库存作废**：造 4 行（`unsent` / 过期 `reserved` / 未过期 `reserved` / `sent`）→ 导入后**只有前两行**被删、后两行原样保留；被删行的 `file_path` 在**提交之后**才 unlink（断言顺序，不是只断言结果）；模拟事务回滚 → **一个文件都没被删**。另加判据一致性测：作废用的 SQL 谓词与 `lease_repo` 的可领取谓词**逐字一致**。
- **P3-D11 通用路径护栏**：目标股在 `stock_coverage` 有行 → `write_to_postgres` 抛 `LegacyImportBlockedError` 且**零 INSERT**；无行 → 行为与改动前逐字一致（既有测试全绿即为证）；断言锁与检查都在 INSERT 之前。

> 假件的界限：假 conn **不可能**证明 PG 的 RR 快照语义或 advisory lock 的跨连接互斥（这正是 `feedback_verify_foundational_infra_assumption_real_not_fake` 的坑：自写 double 会静默建模**错误**语义）。假件测的是「我们确实按预期参数、按预期顺序调了这些」；语义本身由 §5.3 证明，真写入器由 §5.4 证明。

### 5.3 真 PG 语义验证脚本（`backend/scripts/verify_repeatable_read_snapshot.py`）

参照现有 `backend/scripts/verify_advisory_lock_reentrancy.py` 的形态（docker `postgres:15.12` + asyncpg，一次性、不进 CI 套件）。此脚本用**手写 SQL 扮演 B1**，只验基础设施语义：

1. RR 只读事务内第一次读之后，另一连接 INSERT klines + UPDATE stock_coverage 并 **COMMIT**；同事务内第二次读**仍看到旧值**（coverage 与 klines 都验）。
2. 同一时刻，**事务外**的第三个连接**看得见**新值 —— 证明写方真的提交了（防「写方其实没写成，快照测试空转全绿」）。
3. `SHOW transaction_isolation` 在该事务内 == `repeatable read`；事务内尝试写 → 被 PG 拒（证明 `readonly=True` 真生效）。
4. 导入事务**未提交**时，外部连接**既看不到 coverage 行也看不到 klines 行**；提交后**同时**看到（P3-D4 原子性）。
5. **按股锁（P3-D8）**：连接 A 持 `pg_advisory_xact_lock(K, s1)` 未提交 → 连接 B 对同一 `s1` 的 `pg_try_advisory_lock` 返回 **False**、对不同股 `s2` 返回 **True**（证明按股隔离真的按股，而不是退化成全局或形同虚设）；A 提交后 B 对 `s1` 可获取（xact 锁确实随提交自动释放）。

脚本输出逐条 PASS/FAIL，任何一条 FAIL 即非零退出。

### 5.4 真 PG 端到端链路脚本（`backend/scripts/verify_qmt_pg_chain.py`）——L2，**合并前必跑**

codex R1-F3（medium，**核实为真**）：§5.5 那条 CI 集成测的存储层是假 conn，`write_qmt_stock` 的真 SQL / 参数绑定 / JSONB 编解码 / 事务行为一行都没跑过；只有它绿就宣称链路可用属过度宣称。故新增这条脚本，跑**真**代码路径：

```
docker postgres:15.12 → 应用 schema.sql
  → 真 build_stock_import(fixture)
  → 真 write_qmt_stock(dsn, ...)                  ← 真 SQL / 真 asyncpg / 真事务
  → 真 generate_one_training_set(真 conn, ...)     ← 真 RR 事务 / 真两把锁
  → 断言：磁盘上真出现 zip、training_sets 真有登记行、content_hash 与 zip 字节相符
  → 断言：stock_coverage 行内容 == build_stock_import 的 CoverageArtifact
  → 断言：把同一只股用「窗口前滑的第二份 bundle」重导一次 → 旧窗口盘中行真的从库里消失（P3-D4）
  → 断言：重导前先造一行 unsent training_set → 重导后该行与其 zip 真的没了（P3-D10）
  → 断言：对同一只股跑通用 CSV 路径 → 真抛 LegacyImportBlockedError、库里零变化（P3-D11）
```

**PR 合并前必跑，完整输出贴进 PR body。** 不进 CI 套件的理由：CI 禁 skip（`backend-tests.yml` 解析 junit，任何 `skipped>0` 即 fail），一条需要 Docker 的测试无法条件跳过，等于逼 CI 常备 PG service —— 那是 `.github/workflows` 改动，属 Plan 4 的容器化 smoke 范围。

### 5.5 端到端逻辑链集成测（`backend/tests/test_qmt_e2e_generation.py` 新建）——L1，进 CI

`QMT fixture CSV → build_stock_import → 假 conn 充当存储 → 真 generate_batch → 断言 ≥1 个 zip 产出且 training_sets 有登记行`。

- fixture **不进仓**：dense 1m 一年 ≈ 242 交易日 × 241 根 ≈ 5.8 万行（**估算**，实施时以实际生成为准），落盘约数 MB。用测试内**生成器函数**造 DataFrame / 临时 CSV，仓里只保留现有小样本 `backend/tests/fixtures/sample_1m.csv` 供解析级测试。
- fixture 跨度须同时喂饱：B2 的 8 个前向月 + 盘中 before-context（3m/15m/60m 各 150 根 → 最长 60m 需 ~38 个交易日）+ 日线/月线 before-context（monthly 全取 → 日线需数年历史）。**日线造多年、1m 只造近一年**，正是真实 QMT 的形状。
- 断言产出 zip 的 `content_hash` 与磁盘字节一致（沿用现有 helper），并断言 `generate_batch` 返回的成功计数 ≥1。

### 5.6 mutation 验证（强制）

每一条新增的门测试必须做 mutation：把被测的门改坏 → 对应测试**必须挂**。至少覆盖这几处：`date_set_mismatch` 判据改成恒 True、事务隔离级别改回默认、`readonly` 去掉、coverage 写入注释掉、**`DELETE` 去掉（替换退化成 UPSERT）**、**按股锁改成恒返回 True**、`_MIN_MONTH_BOUNDARIES` 改小、**`export_log_mismatch` 门改成恒放行**、**库存作废谓词改成只删 `unsent`**、**通用路径护栏去掉**。由控制者本人复验，不采信 subagent 自证。

### 5.7 闸门纪律

- 所有 pytest 用仓库根 `.venv`（Python 3.11）：`cd backend && ../.venv/bin/python -m pytest tests/ -q`。host `python3` 是 3.14，跑 pandas 会段错误。
- 任何 `cmd | tail/grep` 都加 `set -o pipefail` 或改 `cmd; echo EXIT=$?`；判绿读输出内容，不看 exit code。
- 每条闸门/git 命令同时打印 `branch` + `HEAD`。
- 基线：`main` `08d70d2` = **`255 passed`（本文写作时已实测确认，非从记忆推断）**。任何 Task 结束时测试数只增不减，且 0 failed / 0 skipped。CI 禁 skip，不得新增任何 `skip`/`xfail`。

---

## 6. 验收标准（spec 级；非-coder 验收清单在 plan 阶段出）

1. 用 fixture QMT CSV 跑 B1 QMT 模式 → `stock_coverage` 有该股一行，端点/`dense_day_count`/`dropped` 与 `compute_dense_coverage` 一致。
2. **L1**：假 conn 存储上跑 `generate_batch` → 真产出 ≥1 个训练组 zip + `training_sets` 有登记行（CI 内）。
3. **L2**：真 PG 上跑**真** `write_qmt_stock` + **真** `generate_one_training_set` → 真出 zip（`verify_qmt_pg_chain.py`，输出贴 PR body）。**2 与 3 都绿才算「出货能力被证明」**——这是 Plan 3 的核心验收项，也是 Plan 2 无法做到的那一条。
4. D10 四门、D9(a)、P3-D9 日线历史门各有一条拒绝路径被测试覆盖，拒绝时数据库零写入。
5. B2 的 coverage + 六周期读在同一个 RR 只读事务内（假件测参数 + 真 PG 脚本测语义，两者都绿）。
6. B1 导入是**替换**而非叠加：重导一份窗口前滑的 bundle 后，旧窗口盘中行从库里消失（假件回归测 + 真 PG 脚本各一条）。
7. 按股锁真的按股：同股互斥、异股不互斥、xact 锁随提交释放（真 PG 脚本第 5 条）。
8. **重导入后可领取库存里没有该股旧产物**（`unsent` + 已过期 `reserved` 被删、`sent` 与活跃 lease 保留）；活跃 lease 的回流窗口作为**已知残留**写进 PR body，不写成已闭合。
9. **通用 CSV 路径对已被 QMT 管理的股 fail-closed**；对未被管理的股行为逐字不变。
10. 日线：**只宣称**「月边界 ≥ 39 + 拷贝完整性（export_log 端点/行数）已强制」，**不宣称**「已验证全历史」。
11. 后端 pytest 全绿、零 skip；PR CI 全绿。

---

## 7. 风险 / 开放项

| 风险 | 处置 |
|---|---|
| `export_log.csv` 真实列名未逐字核对 | P3-D3 候选集 + fail-closed 报错；Plan 4 挂 SMB 时逐字核对并收窄 |
| 端到端 fixture 体量大、测试变慢 | 生成器造数据、不落仓；若单测超时明显，可把 1m 跨度收到刚好喂饱 B2 的最小天数（实施期实测决定，不预先猜） |
| `PERIOD_BEFORE_CAP` 与真实 1m 只有一年 → 真数据可能候选稀疏 | 属 Plan 4 真跑时的产能问题；Plan 3 只需证明通路，产能低会在 Plan 4 的储备池替补机制里显性化 |
| RR 事务拉长了 B2 单股读的事务时长 | B2 是单用户内网批处理，长只读事务不冲突；且早退路径仍在第一条语句后返回 |
| B1 的按股 `pg_advisory_xact_lock` 是**阻塞式**：B2 正在为该股生成时，导入会等 | 这是期望行为（互斥）。B2 单股的持锁时长 = 快照读 + 建 zip，秒级。若将来发现卡顿，加 `lock_timeout` 是独立的小改动，本 plan 不预设 |
| 重导入后**已存在**的训练组变成「按旧基准生成」 | 明确的产品政策（P3-D8）：训练组是不可变冻结产物，不自动作废。作废是运维动作，不在 Plan 3 范围 |

---

## 8. 流程

brainstorming（本文）→ codex spec review → writing-plans → codex plan review → subagent-driven 实施（Sonnet high）→ host pytest 三绿 → requesting-code-review → whole-branch codex（`--scope branch-diff`）→ PR（user push/merge）。

**PR 切分（每 PR ≤3 子项 ≤500 行）：**

| PR | 内容 | 子项 |
|---|---|---|
| **3a** | `qmt_ingest.py` 纯装配层（含 P3-D9 两道门）+ `test_qmt_ingest.py` | 2 |
| **3b** | B2：RR 只读事务 + 按股锁（`stock_lock_key`/`IMPORT_GEN_LOCK_KEY`）+ 假 conn 断言测 + `verify_repeatable_read_snapshot.py`（5 条语义断言） | 3 |
| **3c** | B1 写库壳（替换语义 + 按股 xact 锁 + coverage UPSERT + 存在断言）+ 假 conn 单测 + CLI `--qmt` | 3 |
| **3d** | P3-D11 通用路径护栏 + P3-D10 库存作废（含提交后 unlink 的顺序）+ 二者的测试 | 3 |
| **3e** | L1 端到端集成测（fixture 生成器）+ L2 `verify_qmt_pg_chain.py` 真链路脚本 | 2 |

**顺序理由**：3b 先于 3c，让后面的端到端跑在最终读路径上，不必写完再改；3d 依赖 3c 的 `write_qmt_stock` 与 `stock_lock_key` 已在；两条端到端合并成独立的 3e，避免前面的 PR 塞成 4 子项。**3e 的 PR body 必须贴 L2 脚本的完整输出**（§0.2 的 L1+L2 双绿口径），并写明 P3-D10 的活跃-lease 回流残留。

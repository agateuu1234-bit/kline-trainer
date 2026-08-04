# QMT Plan 4a 设计 —— pilot 数据库护栏（D8b reset 护栏 + 库生命周期）

> **本文件由 `2026-07-26-qmt-plan4-pilot-shipment-design.md` 切分而来**（切分理由与映射见
> `2026-07-27-qmt-plan4-spec-split-map.md`）。旧 spec 的 **R1–R97 评审账本原样保留在那份文件里**，
> 是本文件全部结论的历史依据；**它本身已不再作为实施依据**。
>
> **本文件的作用域 = PR 4a**：`assert_pilot_db_allowed` 护栏、集群闸、pilot 库的建/复用/reset 生命周期。
> **本文件不做文件 IO，但它的两道闸依赖文件系统派生的标量（O1-F13 更正）**：闸 0b 要比对
> `<staging>/fetch_manifest.json` 里的 `export_log_sha256`、闸 1 要算两份 schema 的**文件字节** sha256、
> `output_dir` 是 `resolve()` 后的绝对路径。**规定**：`qmt_pilot_db` 的接口**只接收已校验的标量**，
> 由调用方（4c）传入；**取不到 = fail-closed 拒绝，绝不跳过闸 0b**（否则一道 DROP 前置闸会被一次读文件失败静默关掉）。
> `resolve()` 的无跟随语义由 `2026-07-27-qmt-plan4b-fetch-design.md` §4.1 的符号链接分量闸保证。
>
> **本文件不引用 4b 的共享地基** —— 它完全不碰目录（`output_dir` 在这里只是 `pilot_meta` 里的一个字符串值），
> 故不引用 4b 的共享文件系统地基。

- **⚠️ 章节权威性（文档级不变量）**：
  1. **§4 是唯一权威规范**。§5（错误处理表）、§6（测试策略）、§9（验收标准）都是它的**导出视图**；
     任何冲突一律以 §4 为准，且必须把导出视图改到与 §4 一致（而非反过来）。
  2. **过程性规则只在 §4 的闸表与序列里定义一次**，其余散文可引用、**不得复述过程**。
  3. **跨 spec 引用必须写成「见 `<文件名>` §X」**——三份文档的 §号各自重排，只写「见 §X」会指错地方。

- **⚠️ 每轮改动的收尾必做（五条机械检查，作用域限本文件；旧 spec §11 立，实证有效）**：
  1. **新错误码** → ①它进了哪个**字段枚举**？②它触发哪个 **verdict**，**那个 verdict 的权威定义处（在 4c spec）列了吗**？
  2. **新参数/枚举项** → 逐个 grep 它的**全部调用点/登记处**，数量对不上就是漏了。
  3. **新闸** → 把闸序列当有向图，**逐条出边检查有没有控制流能绕到它后面去**。
  4. **改规则** → 把该规则的关键词**全文打印逐条读完**——计数回答不了「它们说的是不是同一件事」。
  5. **新持久字段/信号** → **谁写、谁读、谁清**（清它与「证明已恢复」是不是同一次原子提交）。
  > **扫描结果必须由脚本打印成一行可粘贴文本、照抄进 §11，不许凭印象写**（旧 spec 里我连犯 4 次）。

---

## 1. 背景（裁剪到本 PR）

Plan 1–3 已把 QMT 数据的规整/合成/入库链路建好并合并，但**至今一个字节的真 QMT 数据都没流过**——
全部验证用的都是生成的假数据。Plan 4 的目标是让真数据第一次真正流过，并出货 100 只股的训练组。

真数据要进库，就必须建一个**与生产库隔离的 pilot 数据库**。而「建库」这个动作带着两条不可逆风险：

1. **在错的集群上建库并灌几百只股** —— 名字护栏（`kline_pilot_` 前缀）只保护**已存在**的库，
   挡不住「连到生产集群上新建一个合法前缀的库」。
2. **`--reset` DROP 掉别人的库** —— 前缀只证明**名字的形状**，不证明**归属**。

PR 4a 就是这两条风险的护栏，**它是 Plan 4 三个 PR 里唯一一个纯 DB、零文件 IO、零网络的**。

## 2. 目标与非目标

**目标**
- `assert_pilot_db_allowed`：任何 DDL 之前拒绝非法库名与未授权的破坏性动作。
- **集群闸**：证明「这台集群是给 pilot 用的」，否则拒绝任何 `CREATE`/`DROP DATABASE`/导入。
- **库级五闸**（0− / 0 / 0b / 1 / 2）：证明「这个库能不能被我碰、是不是我这套设置的、还能不能直接用」。
- **两阶段建库**：归属先于 schema，使工具不会被自己的护栏锁死。

**非目标（明确不做）**
- 不做多租户/权限系统 —— 这是内网单用户 pilot。
- 不做跨集群迁移、不做备份恢复。
- **不定义 verdict 枚举与报告 schema** —— 那是 4c spec 的唯一权威；本文件只声明「我会产生
  `FAIL_CLUSTER_BOUNDARY` / `FAIL_DB_BOUNDARY` 两个 verdict 及其错误码」，由 4c 收口成闭合枚举。

## 3. 交付切分

| 子项 | 自动化验证 |
|---|---|
| ① `assert_pilot_db_allowed` 护栏 + 集群闸 | 负向表驱动 host 单测（断言 DDL **从未被调用**） |
| ② pilot 建库/复用（两阶段：`CREATE` → 写 `pilot_meta` → apply schema → `state='ready'`） | 真-PG `verify_pilot_db_lifecycle.py` |
| ③ 库级五闸 + `--reset-foreign` 令牌 | 同上 + `verify_pilot_concurrency.py` |

**新增文件**：`backend/qmt_pilot_db.py`、`backend/sql/pilot_schema.sql`、
**`backend/sql/pilot_cluster_schema.sql`**（§4 P1-F5：**必须独立一份**——`pilot_schema.sql` apply 到维护库
会让它多出两张表 + 两个 pkey 索引 → 闸 (iii) 永久不过、工具彻底不可用；反过来合并也会让每个 pilot 库多出
一张空的 `pilot_cluster_marker`，而闸 2 的七组闭合清单里没有它）、
`backend/scripts/verify_pilot_db_lifecycle.py`、`backend/scripts/verify_pilot_concurrency.py`。

---

## 4. 组件设计 —— D8b reset 护栏（集群闸 + 库级五闸）

0. **集群闸（R15-F1 + R17-F1 + R20-F2，排在所有 DDL 与导入之前）**：连上 `--maintenance-dsn` 后，**每一次运行**都要同时满足下述**三条**，缺一即拒绝（不执行任何 `CREATE DATABASE` / `DROP DATABASE` / 导入）：
   - **(i) 标记存在**：维护库含 `pilot_cluster_marker`，且 `purpose = 'qmt_pilot_disposable_cluster'`。
   - **(ii) 集群仍然干净（每次现查，R17-F1 + R22-F1）**：枚举 `pg_database` 里**每一个**非系统库——排除条件必须是 **`datistemplate = true OR datname = current_database()`**，
     **绝不是名字 glob `postgres`/`template*`**（O1-F3：`template*` 是**名字形状**，不是系统性证明。一个叫 `templates`
     或 `template_store` 的**生产库**会被名字前缀当成系统库跳过 → 三条闸全过 → 工具在生产集群上建库灌数据。
     这正是本文件 §1 列的风险 ①，也是 R20-F2 自己那条「没有别的数据库 ≠ 这台集群没在用」在同一道闸里换形态复发——
     **「形状不是归属」的第六次**。`template0`/`template1` 天然满足 `datistemplate`；维护 DSN 连的那个库由闸 (iii)
     负责，故从 (ii) 排除——**顺带解掉一个隐性约束：原文只有当 `--maintenance-dsn` 恰好连 `postgres` 库时才自洽**）——
     **包括匹配 `kline_pilot_*` 的，但显式排除本次目标库**（P1-F6：排除条件写成
     `datistemplate OR datname = current_database() OR datname = 'kline_pilot_<seed>'`）：

     > **为什么必须排除目标库（P1-F6）**：目标库自己就匹配 `kline_pilot_*`，于是「已存在、非空、
     > 无 `pilot_meta`」这一档**会先被集群闸 (ii) 拒掉**，报 `FAIL_CLUSTER_BOUNDARY +
     > unowned_pilot_database`。后果三条：①操作者拿到的诊断是「**这台集群不干净**」，而事实是
     > 「**你的目标库不是本工具建的**」——§5 承诺的下一步动作是「人工删**这个库**」，报告却说集群有问题；
     > ②O1-F6 刚收口的「表不存在 → `not_owned`」映射在两条路径上**永不发生**；
     > ③§6.1「造『无 `pilot_meta`』→ 断言**专属 `db_boundary_error` 码** + DROP 从未执行」与
     > §6.2 的归属闸破坏性分支**在真 PG 上都会停在集群闸** —— **测试变绿，验的却是另一道闸**
     > （目标库确实还在，但不是归属闸挡下的）。这是本仓反复记过的 vacuous 覆盖。
     > **目标库由闸 0−/0/0b 全权负责**，正如维护库由闸 (iii) 负责。
     > **§6.1/§6.2 的两处测试必须断言拿到的是哪一个 verdict**，而不只是「库还在」。
     - 名字不匹配 `kline_pilot_*` → **拒绝**。
     - 名字匹配 `kline_pilot_*` → **连进去验归属**：须**复用闸 0− 的同一组形状判据**（`key` 有主键/唯一约束 + `tool` **恰好一行**且值相符），
       缺表/缺键/值不符/**行数不为 1** → **拒绝**（P1-F7：原文只写「须有 `pilot_meta` 且
       `tool == 'qmt_pilot'`」而**没规定怎么读** —— 实现成 `SELECT value … LIMIT 1` 时无 `ORDER BY`、
       返回行任意 → **同一台集群这次判干净、下次判不干净**；实现成 `EXISTS(… AND value='qmt_pilot')`
       则永远判干净，等于承认「只要塞得进一行 `qmt_pilot` 就算我的」。
       O1-F8 给 marker 立的「不得 `LIMIT 1`」纪律与 R80-F1 的闸 0− **都只落在了各自发现它的那个对象上**）。**唯一豁免：该库零用户对象**（崩在 `CREATE` 与写标记之间的残骸）→ 放行本闸。**本闸的放行不等于 DROP 授权**；能否清掉它由下方「空库残骸的 reset 例外」五条判定（R55-F1 + R56-F1）。

     > **为什么前缀名不能当归属证明（R22-F1 修正）**：原闸只拒绝「非系统、非 `kline_pilot_*`」的库，等于**把名字前缀当成了对所有已存在前缀库的充分归属证明**。于是共享集群上只要存在一个恰好叫 `kline_pilot_xxx` 的无关库（甚至生产库），整台集群就被判为「干净」；操作者换个新 seed，本工具照样在上面建库、灌进几百只股。
     >
     > **这是「形状不是归属」在本 spec 里的第五次出现**（R2-F1 `unlink` 白名单 → R3-F1 库归属闸 → R7-F3 目标目录 → R8-F1 目录内容形状 → 本条集群闸）。讽刺的是集群闸本身正是为贯彻这条原则而加的（R15-F1），却在**枚举同类库**这一步又退回了名字判断。收口方式与前四次一致：**逐个连进去问它自己是谁**。

**【绝对空】的唯一判据（O4-R2-C1 重写；本 spec 唯一一条**无归属证明、无令牌**的
`DROP DATABASE` 授权就建立在它上面）**：

> **⚠️ 六条枚举式判据已被证伪并废弃（codex R2 指出，真 PG 复现）**：原判据硬编码
> `pg_class` / `pg_namespace` / `pg_proc` / `pg_type` / `pg_extension` /
> `pg_largeobject_metadata` 六条。实测**一个只含 `CREATE COLLATION public.mycoll`
> 的库六条全返回 0** → 被判「绝对空」→ 可被无凭据 `DROP DATABASE`。
> 同样逃过的还有 `pg_conversion` / 文本搜索对象 / publication / operator / opclass /
> cast / FDW……**枚举式判据每出一种新对象类型就漏一次**，而 O1-F1 立这条时
> 要求的正是「白名单式」——六条枚举**从来就不满足它自己的要求**。

**现判据是结构性的，不再枚举**：PostgreSQL 给 initdb 期建的对象分配 `oid < 16384`，
**用户后来建的一切都 `>= 16384`**。故：

```
「本库任一非共享系统目录里存在 oid >= 16384 的行」 ⟺ 「有用户对象」
```

- 目录清单**从 `pg_catalog` 现查**（`relkind='r'` + 有 `oid` 列 + `NOT relisshared`），
  故 PG 加新目录时自动覆盖，**不需要改代码**；
- `relisshared` 排掉 `pg_database` / `pg_authid` 这类集群级共享目录（它们不属于本库）；
- **查不出目录清单 → 抛异常，绝不返回「空」**：证明不了「空」等价于「非空」。

> **⚠️ `oid >= 16384` 这条规律对大对象不成立（O4-R3-C1，codex 指出、真 PG 复现）**：
> `lo_create(oid)` / `lo_import(path, oid)` / `lo_from_bytea` 允许**调用方自选 OID**——
> 实测 `SELECT lo_create(100)` 造出 `oid=100` 的大对象，全局阈值看不见它，
> 于是一个**装着用户数据**的库被判「绝对空」→ 可被无归属证明、无令牌地 `DROP DATABASE`。
> **规定**：`pg_largeobject_metadata` 这类**允许调用方指定 OID** 的目录**不设阈值、任何行都算用户对象**
> （initdb 一个大对象都不建，故这条成立；真 PG 回归钉先断言「刚建的库该目录为 0 行」，
> 使前提可被证伪）。这是**对「一条 OID 规律套所有目录」的修正**——
> 判据再结构化，也要检查它依赖的那条规律在每个目录上是否真的成立。

**豁免必须按 `(目录, oid)` 配对，不得裸比 oid（O4-R6-C2，真 PG 复现）**：

> **不同目录的 oid 可以相同**，而 `lo_create(oid)` 允许调用方自选 OID —— 实测造一个
> `oid` 恰等于 `pilot_cluster_marker` 的大对象，它就被跨目录撞号**藏在闸 (iii) 之外**，
> 维护库装着用户数据也判「干净」。配对之后，`pg_largeobject_metadata` 天然永远不在豁免集里。

**seed 锁证明必须限定精确锁形状（O4-R6-C1，真 PG 复现）**：

> 只查 `classid`/`objid` 时，两种别的锁形态都能**冒充通过**：
> `pg_advisory_lock_shared(key)`（`mode='ShareLock'`，**不提供互斥**）与
> `pg_advisory_lock(int,int)`（两参数形式，`objsubid=2`，另一个命名空间）。
> 两者都会让**两次同 seed 的运行**同时通过守卫去抢 intent 行与 CREATE/DROP。
> **规定**：证明须同时满足 `objsubid = 1` 且 `mode = 'ExclusiveLock'`。

**闸 (ii) 的归属判据不能只是 `tool == 'qmt_pilot'`（O4-R13-C1）**：那是一个**静态且可猜的标记**，
塞进任意非空库的合规 `pilot_meta` 里就能让它跳过闸 (ii)，「这台集群除本工具外别无他物」被整个掏空。
三条判据一起才算数：①键集合**覆盖阶段 1 的全部 7 键**；②`seed` 与库名后缀**逐字相等**
（整份抄自另一个真 pilot 库的标记靠这条挡住）；③`state ∈ {initializing, ready}`。

**但自证再严也还是自证（O4-R14-C1）**：上面三条读的全是「被判对象自己写的字」，对手照抄一遍即可。
故还要一个**它改不到**的事实——维护库的 `pilot_database_registry` 里这个库名确实被本工具声明过
（且 `seed` 相符）。**两个独立事实同时成立才放行**：库内自证 + 维护库侧登记。
> **诚实说明它防不住什么**：持有本工具维护库写权限的对手可以自己往登记表插行。
> **任何集群本地的凭据都防不住这一档**。它挡的是①偶然撞形（另一个库碰巧长得像）
> 与②能建库但写不了维护库的对手。不要把它当成安全边界的全部。
⚠️ **不得要求「9 键齐全」**：那会把 `state='initializing'` 的合法崩溃残骸判成外来物 →
整台集群对**所有** seed 被挡住 —— R55-F1 那个锁死换形态复发。

**apply 完 `pilot_schema_sql` 必须先证结构再写任何键（O4-R13-C2）**：与闸 (i) 对维护表做的是同一件事——
**执行过 DDL ≠ 结构就对**。`pilot_schema_sql` 由调用方传入（CLI 从仓库文件读），文件漂移/读错会建出
「有 `pilot_meta` 没有 `pilot_stock_source`」或「`pilot_meta` 没有主键」的库，而后续照常写完 9 键 +
`state='ready'` —— 对外宣称 ready、归属/来源表却是坏的。证明必须在**同一个阶段 1 事务内**，
不合规时连 DDL 一起回滚，不留半成品。置 `state='ready'` 同样**核行数**（期望 `UPDATE 1`），
否则 `state` 行不在时 UPDATE 报 0 行而不报错，库被当成 ready 交付。

**闸 (iii) 的豁免 = 结构性白名单**（O4-R5-C1 重写）：只列举【维护库专用表集合】
**合法应有**的派生物 —— TOAST 表及其索引、表与 TOAST 的复合/数组类型、**仅主键**约束、
**仅主键背后**的索引。

> **⚠️ `pg_depend` 闭包（哪怕限定 deptype）已被证伪并废弃**（真 PG 实测）：
> 用户自己 `CREATE INDEX` / `CREATE RULE` 出来的东西，PostgreSQL 同样标成 **AUTO 依赖**
> （它们随表一起被删）—— 于是「跟着依赖闭包豁免」会把它们一并盖住。实测**五种**
> （继承子表 / 额外索引 / 额外约束 / 规则 / 触发器）对闸 (iii) **全部隐形**。
>
> **⚠️ 我第一次验这条时得出过假阳性**：反例对象**累积没清理**，检查「额外索引」时
> 看见的其实是上一步留下的继承子表。**每个反例必须单独造、单独清**，
> 且清理后要断言恢复判空 —— 否则「抓到了」可能是别的东西被抓到。

**真 PG 实测四档**（`verify_pilot_two_phase_create.py` 第 ⑤ 档）：刚建的库判为空；
自定义 collation / 物化视图 / 文本搜索配置**三者都必须让判据失效**。
**host 层的假件验不了这一档**——它不执行 SQL，改判据的 SQL 文本它看不见（实测中和后零测试变红）。

**⚠️ 闸 (iii) 的豁免必须写成 SQL 级、且覆盖依赖对象（P1-F4，实测）**：主键会带出一个索引 relation。
真 `postgres:15.12` 实测：只跑过 `CREATE TABLE IF NOT EXISTS pilot_cluster_marker (purpose TEXT PRIMARY KEY)`
的库，第一条 SQL 返回 **2** —— `pilot_cluster_marker | r` 与 `pilot_cluster_marker_pkey | i`。
按**表名**排除后索引仍被计入 → **闸 (iii) 恒假 → `--init-cluster-marker` 之后工具每一次运行都在集群闸 fail-closed**。
故豁免子句写死为：
```sql
-- 闸 (iii) 专用豁免（**只用于 (iii)**；闸 (ii) 豁免与零对象例外第 3 条用**无豁免的裸【绝对空】**）
-- ⚠️ ARRAY 的成员 = 【维护库专用表集合】 的全部成员（O4-F1）；集合增长时**本处必须同步**
WITH m AS (SELECT ARRAY(SELECT o FROM unnest(ARRAY[
             to_regclass('public.pilot_cluster_marker'),
             to_regclass('public.pilot_create_intent')]) AS o WHERE o IS NOT NULL) AS moids)
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, m
 WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast'
   AND NOT (c.oid = ANY(m.moids))
   AND NOT (c.relkind = 'i' AND EXISTS (SELECT 1 FROM pg_index i
              WHERE i.indexrelid = c.oid AND i.indrelid = ANY(m.moids)));
```

> **⚠️ 自查补（P1r3-F1b，真 PG 四态实测）**：P1r3-F2 引入 `pilot_create_intent` 之后，
> **只豁免 marker 的那版在「两表齐全」时返回 2**（intent 表 + 它的 pkey 索引）→ **闸 (iii) 又一次恒假**。
> 这是**同一个洞在同一节里被我第二次打开**——判据只跟着「当时有几张表」写，没跟着「维护库专用表的**集合**」写。
> 现版四态实测：`无表=0` / `只有 marker=0` / `两表齐全=0` / `两表+外来表=1`。
> **判据补强：豁免的对象是「维护库专用表的集合」，新增任何一张都必须同时进这条 SQL 与闸 (i) 的形状断言。**
>
> **⚠️ 我上一版写的 `pg_depend` 豁免两个方向都不成立（P1-F1，真 `postgres:15.12` 实测，2026-07-28）**：
> | 状态 | 我上一版 | 本版 |
> |---|---|---|
> | **无 marker 表**（`--init-cluster-marker` 的前置状态） | **`ERROR: relation "pilot_cluster_marker" does not exist`** —— `::regclass` 在表不存在时**抛异常**，不是「豁免不适用」→ **集群标记永远初始化不了，整个 4a 无法启用** | `0`，不抛异常 |
> | 只有 marker（含 pkey 索引） | **`1`** → 闸 (iii) **恒假** → 此后每次运行都在集群闸 fail-closed | `0` |
> | marker + 一张外来表 | 1 | `1` |
>
> 根因：`pilot_cluster_marker_pkey` 在 `pg_depend` 里的 `refclassid` 是 **`pg_constraint`**（`refobjid` 是**约束**的 oid），
> **不是 `pg_class`**——我当时凭印象假设了它指向表。故改用 `pg_index.indrelid` 直连，并用 `to_regclass` 消除不存在时的异常。
>
> **教训**：上一轮我手边有 docker 却没测就写。**凡 spec 里出现可执行 SQL 或系统调用语义，必须先在真环境跑过三种状态（有 / 无 / 有+污染）才能写进去。**
**并且 §6.2 必须加两档正向钉**（现有五档**全是负向**，恒假不会被任何测试暴露）：
① **刚跑完 `--init-cluster-marker` 的维护库必须过闸 (iii)**；
② **在 `--init-cluster-marker` 之前**（marker 表尚不存在）跑闸 (iii) 的 SQL **必须不抛异常**。

```sql
-- 以下每一条都必须返回 0，缺一即「非空」
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast';
                                    -- ⚠️ 不加 relkind 过滤：任意 relkind 有一行即非空
SELECT count(*) FROM pg_namespace
  WHERE nspname NOT IN ('pg_catalog','information_schema','public') AND nspname !~ '^pg_';
SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema');
SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND t.typtype IN ('e','d','c','r')
    AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.reltype = t.oid);   -- 排除表派生的复合类型
SELECT count(*) FROM pg_extension WHERE extname NOT IN ('plpgsql');
SELECT count(*) FROM pg_largeobject_metadata;
```

**建库一律 `CREATE DATABASE … TEMPLATE template0`（P1-F8，实测）**：【绝对空】那句「刚 `CREATE DATABASE`
出来的库对上述全部为空，收紧不损失任何恢复能力」**只在 `template1` 干净时成立**。
真 `postgres:15.12` 实测：在 `template1` 里建一张 `dba_audit(id int)` 后，用**默认模板**建库 →
第一条 SQL 返回 **1**。而 `template1` 被装过 extension（`pg_stat_statements` / `citext` / PostGIS 是常见做法）
或建过表的集群非常普遍。后果：**本工具自己崩溃留下的残骸不满足【绝对空】** →
①集群闸 (ii) 的豁免不成立 → **整台集群对所有 seed 被锁死**（正是 R55-F1 要避免的）；
②零对象例外不适用 → `--reset` 也清不掉 → R56-F1 的恢复能力再次落空。
`template0` 与 `pg_dump --create` 的行为一致。

> **⚠️ 实测坐实（2026-07-27，真 `postgres:15.12`）**：一个**只含一个物化视图、里面有 1000 行真实数据**的库上，
> 三种判据的实测结果是——`information_schema.tables` → **0**；`pg_class` 且 `relkind IN ('r','v','S')` → **0**；
> **`pg_class` 不加 relkind 过滤 → 1**。
> **原文那两种写法（`information_schema.tables` / 枚举 `r,v,S`）都会把这个库判成「零用户对象」**，
> 于是它走六条例外 → 不过闸 0−/0/0b、不需要 `--reset-foreign`、不给任何提示 → **直接 `DROP DATABASE`**。
> 根因：`information_schema.tables` 只覆盖 `relkind ∈ {r,v,f,p}`，**物化视图（`m`）根本不在里面**。
>
> **白名单收录 `pg_attrdef` 时必须连表达式文本一起钉死（O4-R8-C2 附带）**：
`create_confirmed` 的 `DEFAULT false` 会在 `pg_attrdef` 落一行，不豁免则维护库自身永远判非空、工具整个不可用；
但**只按表名豁免**同样错——`ALTER COLUMN create_confirmed SET DEFAULT true` 会让新 intent 行天生「已确认」，
把上面那道持久证明整个掏空。故谓词写成 `attname='create_confirmed' AND pg_get_expr(adbin, adrelid) = 'false'`
（真 PG 实测：`DEFAULT false` → `'false'`，改成 true → `'true'`）。

**判据必须是白名单式**（「除了这些之外什么都不许有」），不能是黑名单式（「不许有表、视图、序列」）——
> 后者每出一种新对象类型就漏一次。真正的残骸是刚 `CREATE DATABASE` 出来的库，它对上述**全部**为空，
> 收紧不损失任何恢复能力。
>
> **另**：原文写的是「`information_schema.tables` / `pg_class`」——**两个来源答案不同**，这个斜杠本身就是缺陷。
> 现已钉死为上面这一组 SQL，**闸 (ii) 豁免、闸 (iii)、六条例外第 3 条一律引用它、不得各写各的**。

      - **逐库连接失败一律 fail-closed（O1-F10）**：`datallowconn=false` / `datconnlimit=0` / 无 CONNECT 权限 /
     该库正被别的会话删除 —— 任一导致「连进去验归属」抛异常时，**判定为「无法证明归属」→ 拒绝**
     （`cluster_boundary_error: "unowned_pilot_database"`）。**绝不 `try/except: continue`**——那是 fail-open，
     一个连不进去的库就此被判为无害。
   - **(iii) 维护库自身也是【绝对空】（每次现查，R20-F2）**：在维护库里按上面那组 SQL 查，**除【维护库专用表集合】**及其全部依赖对象（索引 / 约束 / toast）**外不得有任何表、视图、序列**；也不得有非默认的用户 schema。

   > **为什么 (iii) 不能省（R20-F2 修正）**：(ii) 查的是「有没有**别的数据库**」，**完全没看维护库自己里面装了什么**。一个把生产对象直接放在默认 `postgres` 库里的共享集群 —— 它没有任何额外数据库，(i)(ii) 全过 —— 于是本工具照样在那台集群上建 `kline_pilot_*` 并灌进几百只股。**「没有别的数据库」不等于「这台集群没在用」**，判据必须同时覆盖数据库层与对象层。

   标记由操作者显式初始化：`qmt_pilot --init-cluster-marker --maintenance-dsn …`（写标记前同样跑 (ii) 与 (iii)）。

   > **为什么 (ii) 必须每次现查，而不能只在初始化时查一次（R17-F1 修正）**：原设计把「集群是一次性专用」这个**属性**在初始化那一刻检查一次，之后就**永远信任那张标记表**——典型的 TOCTOU。两条现实路径会让它失效：① 一个当初为空的 pilot 集群，后来被拿去装了真实数据库；② 标记随 `pg_dump`/卷拷贝被**还原或复制到另一个集群**。两种情况下运行时闸都照样放行，于是在一个**已经不是一次性**的集群上建库、灌进几百只股。**标记证明的是「有人曾声明过」，只有现查才证明「现在仍然成立」**——把一次性的声明当成持续成立的事实，是这条闸原本的漏洞。

   > **为什么名字护栏不够（R15-F1 修正）**：D8b 的三重护栏与后来的归属/绑定闸，保护的全是**已存在**的库；而**新建**这条路上一道闸都没有。`--maintenance-dsn` 指向共享或生产集群、且 seed 恰好是新的时候，没有 `pilot_meta` 可供盘问 → 工具会照常 `CREATE DATABASE`、应用 schema、再往里灌几百只股的数据。D6 说的「pilot 跑在本机 Docker Postgres」**至此只是散文里的意图，不是机器强制的约束**；这条路不销毁任何东西，却照样违背隔离目标、白占共享集群的磁盘与 CPU，而且产出的报告看起来完全正常。集群标记把「这台集群是给 pilot 用的一次性环境」变成一次**显式、可核验**的声明——与 `pilot_meta`（之于库）、`.pilot_output.json`（之于输出目录）是同一条原则在集群层的应用：**归属靠显式标记，不靠推断属性。**

1. **库名派生不可传**：CLI 只收 `--seed`（限 `^[a-z0-9_]{1,32}$`），库名恒为 `kline_pilot_{seed}`。用户无法传入任意库名，从源头消除「跑错 `DATABASE_URL` 把共享库 DROP 掉」。
2. **独立守卫函数**，在**任何 DDL 之前**调用：
   ```python
   def assert_pilot_db_allowed(db_name: str, *, reset: bool) -> None:
       """库名不匹配 ^kline_pilot_[a-z0-9_]{1,32}$ → raise；
          破坏性动作（DROP DATABASE）而 reset 非 True → raise。"""
   ```
   `if/raise` 非 `assert`（`python -O` 会剥掉 `assert`——这是 Plan 3 `P3-D12`/R15-F1/R16-F3 已经踩过的坑）。
3. **DROP 目标名二次过守卫**：维护连接只用于 `CREATE DATABASE` / `DROP DATABASE`，且 DROP 的目标名在执行前**再过一次上面第 2 条的 `assert_pilot_db_allowed`**（名字形状守卫；与下文闸表里的「闸 0/0b/1/2」是两套不同的东西，别混）。

**复用 vs reset 语义**（闸的适用范围以下方**闸表**为准，本段只描述动作序列）：
- 带 `--reset` 且库**不存在**：按上方**两阶段**建库（`CREATE DATABASE` → 立刻写 `pilot_meta`/`state=initializing` → apply `schema.sql` → 置 `state=ready`，R55-F1）。
- 带 `--reset` 且库**已存在**：**必须先过闸 0（归属）与闸 0b（绑定）**，两者都通过才 `DROP DATABASE` → **`CREATE` → 立刻写 `pilot_meta`（`state=initializing`）→ apply schema → 置 `state=ready`**（两阶段，R55-F1）。归属不过 → 拒绝，要求人工在 pilot 工具之外自行删除；**绑定不过 → 拒绝并打印该库所绑身份 + 派生确认令牌，需 `--reset-foreign=<令牌>` 逐字相符才放行**（R7-F1 / R9-F1 / R11-F1 / R34-F1）。指纹闸与结构闸**不参与 DROP 判定**。
- 不带 `--reset` 且库不存在：同样按**两阶段**建库（R55-F1），指纹键在阶段 2 与 `state=ready` 一同写入。
- 不带 `--reset` 且库已存在：**允许复用，但须通过「归属 + 绑定 + 指纹 + 结构」四闸全部**，任一不过 → fail-closed 拒绝并提示「用 `--reset` 重建」。

允许复用是为了 **pilot 可断点续跑**（见 P4-D8）——300~400 只的导入耗时可观，每次重跑都从零开始不可接受。

**复用闸（R1-F2 修正）**：原设计只断言「OHLC 是 `double precision` + `stock_coverage` 表存在」，**不足以判定一个已存在的库是安全的**。因为 `schema.sql` 全部是 `CREATE TABLE IF NOT EXISTS` —— 对**已存在**的表它一行都不改：缺失的 `training_sets.content_hash` / `file_path` 的 TEXT 类型 / `uq_stock_start` 唯一约束 / status 约束 / 索引，重新 apply 一遍**统统不会被补上**。后果是跑完几百只股的导入之后，才在 `_register_training_set` 那一步晚爆，或者更糟——登记出违反 B2/B3 假设的行。

建库时在 pilot 库内写一张 `pilot_meta(key TEXT PRIMARY KEY, value TEXT)`，存**九个**键（`created_at` **不参与放行判定，但参与令牌派生**；preimage 逐字定义：
`<export_log_sha256 全 64 位>|<output_dir 不带尾斜杠>|<created_at ISO-8601 basic UTC 微秒>`，O1-F14。
闸 0− 的四个**授权键**不含 `created_at`，故绑定不符而该键缺失时**派生不出令牌** → 明确提示人工删库）：`tool`（恒为 `qmt_pilot`）、`seed`、`schema_sha256`（`schema.sql` 文件字节的 sha256）、`contract_version`、**`export_log_sha256`**（来自本次 staging 的 `source_snapshot`）、**`output_dir`**（`resolve()` 后的绝对路径）、**`created_at`**（建库 UTC 时间戳，仅供拒绝时打印身份给操作者看，不参与判定）、**`state`**（`initializing` / `ready`，R55-F1）、**`pilot_schema_sha256`**（`backend/sql/pilot_schema.sql` 文件字节的 sha256，R62-F1）。

**建库必须分两阶段，归属先于 schema（R55-F1）**：

0. **维护连接上 `INSERT INTO pilot_create_intent(dbname, seed, created_at)` + `COMMIT`**（P1r3-F8：
   写在 `CREATE` **之前**，故没有窗口；干净收尾时删该行）
1. `CREATE DATABASE kline_pilot_<seed> TEMPLATE template0` → 连进去，在**同一个事务**里 **apply `backend/sql/pilot_schema.sql`**（它同时建 `pilot_meta` 与 `pilot_stock_source`）+ 写入 `tool` / `seed` / `export_log_sha256` / `output_dir` / `created_at` / **`pilot_schema_sha256`** / `state='initializing'` → `COMMIT`。（PostgreSQL 的 DDL 是事务性的，故「有表但没行」这个中间态**不可能**被别人看到。）
2. apply `schema.sql`（**它自带 `BEGIN;`/`COMMIT;`，故由它自己的事务保证 DDL 原子性——绝不能再套一层**，
   O4-W1 真 PG 实测见下）→ **另起一个事务**补写 `schema_sha256` / `contract_version` 并把 `state` 改为 `'ready'` → `COMMIT`。

   > **⚠️ 原文「在同一个事务里 apply schema.sql + 补写两键」物理上做不到（O4-W1，真 `postgres:15.12` 实测）**：
   > `backend/sql/schema.sql` 第 6 行是 `BEGIN;`、第 111 行是 `COMMIT;`。把它放进
   > `async with conn.transaction():` 时，**文件里那句 `COMMIT` 会提交掉外层事务**，
   > 其后的语句全部退化成各自 autocommit；而 asyncpg 的 `__aexit__` 在事务已不存在时
   > **静默返回、不抛异常**（实测：包裹内 raise 之后，schema.sql 之后建的表**仍然存在**，
   > 即回滚没有发生）。**没有任何测试会红、没有任何运行时错误会提示**——
   > 这正是「注释与测试都声称有原子性、真库上没有」那一类。
   >
   > **故规定**（两条都要 fail-closed 守卫，不能靠约定）：
   > - `pilot_schema.sql`（阶段 1）**必须不自带事务** → 由本工具包裹；自带即拒绝启动。
   > - `schema.sql`（阶段 2）**必须自带事务** → 本工具**绝不包裹**它；不自带即拒绝启动。
   >   ⚠️ **理由不是「否则会逐条 autocommit」—— 那句是错的**（O4-W4，真 `postgres:15.12`
   >   + `asyncpg 0.31.0` 实测证伪）：`execute(多语句串)` 走 **simple query 协议**，
   >   PostgreSQL 把整条消息当**一个隐式事务块**。实测一份不含 `BEGIN/COMMIT` 的
   >   多语句串在第 3 条失败时，前面两条建的表**全部不存在**（即整体回滚了）。
   >   **真实理由**：本工具选择了「**不包裹**」，而这个选择**只有在文件自带事务时才与它配对**；
   >   文件形态一变，配对关系就无人看守。守卫钉的是这层**配对关系**，
   >   故它相对真实风险是**过严**的（fail-closed）—— 这是有意的取舍。
   >
   > **残余窗口如实登记**：`schema.sql` 提交之后、两键与 `state='ready'` 提交之前崩，
   > 会留下「schema 齐全、`state` 仍是 `initializing`、指纹两键缺失」的库。
   > 这一档由 O4-F8 兜底（复用被拒 + `db_state_initializing`、`--reset` 能清掉重来），
   > 爆炸半径可控。**这是 `schema.sql` 自带事务带来的、不可消除的窗口**。

> **`pilot_meta` 必须由那份被哈希的文件建出来，不能手写一段 DDL（R64-F3 修正）**：原序列是「手写 `CREATE TABLE pilot_meta` → 之后才 apply `pilot_schema.sql` 并记它的哈希」。可 `pilot_schema.sql` 里也有 `pilot_meta` 的规范定义，而 `CREATE TABLE IF NOT EXISTS` **对已存在的表一列都不改**（R1-F2 早就论证过这一点）—— 于是**手写版与被哈希版一旦漂移，库里留下的是手写版，指纹却证明的是文件版**。`pilot_meta` 恰恰是承载**归属与绑定**的那张表：**保护它的指纹，可能证明的根本不是它自己**。
>
> 把 apply 提到第 1 步即可消解：**建表与记哈希用的是同一份字节**。顺带 `pilot_stock_source` 也在阶段 1 就存在了，比 R62-F1 只要求「`ready` 之前存在」更强。

**`pilot_stock_source` 必须进一份被哈希的 schema 文件（R62-F1）**：该表是 R6-F1 引入的、**唯一**挡住「`export_log` 逐字节不变而 K 线内容已换」那一档的守卫，而 **`backend/sql/schema.sql` 里并没有它**（已核：该文件只定义 `stocks` / `klines` / `stock_coverage` / `training_sets`）。若照原序列实施：
- **新建/reset 的库 apply 完 `schema.sql` 就被置为 `ready`**，而表并不存在 → 执行阶段才炸，**而那时本次运行已经开始改动数据库**；
- 若实现「就地 `CREATE TABLE` 一下」凑合过去，那这张**安全关键**表就**游离在指纹之外** —— 它日后任何改动都不会让 `schema_sha256` 变化，复用闸对它完全失明。

故：新增 **`backend/sql/pilot_schema.sql`**，只含 pilot 专用 DDL（当前即 `pilot_stock_source` 与 `pilot_meta` 的规范定义），**其字节 sha256 记为 `pilot_schema_sha256` 一并进 `pilot_meta`，并与 `schema_sha256` 同样参与指纹闸比对**。**不把它塞进 `schema.sql`**：那是 NAS 生产库共用的 schema，pilot 专用表不该出现在生产库里，也不该让 pilot 的改动去扰动生产库的指纹。

**据此放宽两条闸（否则工具会把自己锁死，R55-F1）**：

- **集群闸 (ii) 豁免空库**：遍历到的 `kline_pilot_*` 库若满足**【绝对空】**（判据与闸 (iii) **同一组 SQL**，见 §4），视为「上一次崩在 `CREATE DATABASE` 与写 `pilot_meta` 之间的残骸」，**放行集群闸**。理由：**空库不承载任何数据，拒绝它没有任何安全收益，却会把整台集群对所有 seed 锁死**。
- **空库残骸的 reset 例外（R56-F1 —— 唯一权威表述）**：闸 0（归属）与闸 0b（绑定）都要读 `pilot_meta`，而这种残骸**恰恰没有** `pilot_meta` —— 若不给例外，`--reset` **也清不掉它**，R55-F1 声称的「能被自己 `--reset` 清掉重来」就是一句空话。故：**当且仅当**下列**六条**全部成立时，允许直接 `DROP DATABASE` 并按两阶段重建：
  1. 本次带 `--reset`；
  2. 目标库名**恰等于**本次派生的 `kline_pilot_<seed>`（不是前缀匹配，是全等）；
  3. 该库满足**【绝对空】**（判据见 §4 那组 SQL，**不是**「无表、无视图、无序列」这种黑名单式表述——物化视图会逃过它，已实测）；
  4. 集群闸 (i)(ii)(iii) 已全过；
  5. ①c 的按 seed advisory lock 已持有；
  6. **维护库的 `pilot_create_intent` 里有 `dbname = kline_pilot_<seed>` 的行、`seed` 相符、
     `create_confirmed = true`（O4-R8-C2）、`db_oid` 与当前 `pg_database.oid` **相等**
     （O4-R21-C1 / R25-C1），且 `inserted_at`（**库自己的时钟**，不是调用方传的 `created_at`，
     O4-R23-C1）距今 < `INTENT_TTL`（写死 24h）**（P1r3-F2 + O4-F2）：
     它证明「这个空库是本工具**刚刚**声明过要建的、而且就是**这一个实例**」——
     同事裸 `CREATE DATABASE` 与 `pg_restore --create` 都没有这一行；
     而「原库被删、别人用同名重建」这一档靠 `db_oid` 挡住。
  **并且**：`DROP DATABASE` 之前须**紧贴着**重查一次【绝对空】（P1-F3：第 3 条与 DROP 之间不可原子，
  实测 `pg_restore --create` 存在「库已建、表还没建」的空窗）。
  **不需要 `--reset-foreign`**：那个令牌的意义是「让操作者确认自己要销毁的是哪一个库」（R34-F1），而一个零对象的空库**没有任何身份可供确认、也没有任何数据可丢**。
  **不带 `--reset` 时**：该残骸走复用路径，因缺 `pilot_meta` 被闸 0 拒绝 → 提示「用 `--reset` 重建」。

  > **为什么例外必须写死这五条（R56-F1 修正）**：R55-F1 我只放宽了集群闸、还特意写了「不因此获得 DROP 授权」，**结果是残骸能让工具启动、却清不掉** —— 我以为自己修好了恢复路径，实际上只是把「拒绝启动」换成了「启动后卡在同一个地方」。**声称的恢复能力必须逐条验到 DROP 真的能执行为止**，否则就是又一次「声称 > 实际保证」。**六条**里第 2 条（**全等**而非前缀）、第 3 条（**零对象**）与第 6 条（**新鲜的 intent 行**）是安全边界：全等把爆炸半径限制在本次 seed，零对象保证被删的东西里没有任何数据。
- **`state == 'initializing'` 的库一律不可复用**：即便指纹碰巧对上也不行（它根本没跑完 apply schema）→ fail-closed 提示「用 `--reset` 重建」。`--reset` 时它照常走归属闸 + 绑定闸（两者所需的键在阶段 1 就已写入），故**能被正常清掉重来**。

> **为什么必须让归属先于 schema（R55-F1 修正）**：原序列是 `CREATE` → `apply schema` → **写 `pilot_meta`**。若进程死在中间、或 `schema.sql` 应用失败，磁盘上就留下一个**没有 `pilot_meta` 的 `kline_pilot_*` 库**。此后：集群闸 (ii) 遇到它就判「名字匹配但无合法 `pilot_meta`」→ **拒绝**（R22-F1 立的规则）；归属闸也因缺 `pilot_meta` 而**拒绝 DROP**，要求「人工在 pilot 工具之外自行删除」。**于是工具再也无法用自己的半成品库开工，也无法自己清掉它——被自己的护栏锁死**。而这一切完全可能发生在**本次运行已经开始改动数据库之后**。
>
> 把归属标记提前到 `CREATE` 之后的第一件事，等于让**每一个由本工具造出来的库，从诞生的下一刻起就带着自己的身份**——这与 4b spec §4「共享地基」对目录的「`mkdirat` 独占创建、取锁早于发布归属、归属从诞生起成立」（R30-F2 + R64-F1 + R97-F2）是**同一条原则在数据库这一层的应用**，我当时只把它落在了目录上。

四闸：

0. **归属闸（R3-F1，DROP 与复用共用，且排在最前）**：连上目标库读 `pilot_meta`，要求 `tool == 'qmt_pilot'` **且** `seed == --seed`。表不存在 / 缺键 / `seed` 不符 → **拒绝**，提示「该库不是本次 pilot 建的，如确需删除请在 pilot 工具之外手工执行」。
0b. **绑定闸（R5-F1；复用**与 DROP** 都要过，R7-F1）**：`pilot_meta.export_log_sha256` 必须等于本次 `<staging>/fetch_manifest.json` 里 `source_snapshot.export_log_sha256`，且 `pilot_meta.output_dir` 必须等于本次 `resolve(--output)`。
   - **复用**时任一不等 → 拒绝复用，提示「该库绑定的是另一份源快照/输出目录，请换 seed 或用 `--reset` 重建」。
   - **DROP**（`--reset`）时任一不等 → **拒绝**，并打印该库所绑身份（`export_log_sha256` 前 12 位、`output_dir`、`created_at`）**以及一个由该身份派生的确认令牌** `confirm_token = sha256(export_log_sha256|output_dir|created_at)[:12]`；重试须带 **`--reset-foreign=<该令牌>`**，逐字相符才放行（R34-F1）。
     > **为什么不能是裸布尔**：裸 `--reset-foreign` 只证明「命令行里有这个词」，**不证明操作者看过那个即将被销毁的库是哪一个** —— 陈旧脚本、shell alias、复制粘贴的历史命令都天然带着它。而令牌**由目标库自身的身份派生**：脚本里写死的令牌对不上另一个库，只有真读过本次打印结果的人才可能填对。**「知情同意」必须由无法预先伪造的东西承载，而不是一个可以顺手带上的开关。**

> **为什么 DROP 也要过绑定闸（R7-F1 修正）**：归属闸只证明「**某个** `qmt_pilot` 运行用这个 seed 建过它」，**不证明是我这次的设置建的**。而 `seed` 由操作者自选、又直接当库名后缀，撞名的门槛很低：维护 DSN 指到共享服务器、或沿用了别人写在文档里的 seed，归属闸照样过 → 不可逆 DROP 掉别人的 pilot 库。加上绑定闸后，「同 seed 但源快照/输出目录不同」这一档会被拦下并**把对方的身份打印出来**，操作者是在知情的前提下按 `--reset-foreign`，而不是在毫不知情的情况下被静默执行。
>
> **为什么不采用「不可猜的 nonce」方案**：评审建议往 manifest 与 `pilot_meta` 各写一个随机 nonce、DROP 时要求相等。但那会**打断 reset 最主要的正当用途**——换了新 staging 想沿用同一个库名重来时，nonce 必然不匹配（新 staging 必然是新 nonce），于是唯一的逃生口被自己焊死。`export_log_sha256` + `output_dir` 已经构成了充分的身份：两个操作者若这三项全同，那本就是同一套设置，DROP 无害。用已有字段作判据，比新增一个会自锁的机制好。
1. **精确指纹（复用主闸）**：`schema_sha256`、**`pilot_schema_sha256`**（R62-F1）与 `contract_version` 与当前值**逐字比对**，任一不等即拒。这条一次性覆盖「`schema.sql` 在两次运行之间变过」的全部情形，无需枚举列名。
2. **结构断言（复用纵深防御副闸）**：即便指纹相符，仍对 pilot 真正依赖的结构逐项断言（防「指纹对但库被手工 ALTER 过」）。**含 `pilot_meta` 自身**（R64-F3：它承载归属与绑定，却曾是唯一没被结构闸覆盖的表）：
   - `klines.open/high/low/close` 均为 `double precision`
   - `stock_coverage` 表存在
   - `training_sets.file_path` 为 `text`
   - `training_sets.content_hash` 列存在
   - `uq_stock_start` 唯一约束存在
   - **`pilot_stock_source` 表存在，且 `stock_code` 为主键、`sha_1m`/`sha_daily` 均为 `TEXT NOT NULL`**（R12-F2）
   - **`pilot_meta` 自身（R79-F2 补齐；其中「授权完整性」那部分已由 R80-F1 上移为闸 0−，两条路径都跑，本闸只在复用路径重复确认一次）**：
     · 表存在，`key` 为 `text` 且**是主键**（或有等价唯一约束）、`value` 为 `text`；
     · **九个键一个不缺、且每个恰好一行**（`tool` / `seed` / `schema_sha256` / `pilot_schema_sha256` /
       `contract_version` / `export_log_sha256` / `output_dir` / `created_at` / `state`）——
       **多出重复行或缺键即拒**；
     · **复用路径**另要求 `state == 'ready'`（`initializing` 走 R55-F1 的「一律拒绝复用、可被 `--reset` 清掉」）。
   任一不满足即拒。

   > **为什么必须逐条写出来（R79-F2 修正）**：本条的标题从 R64-F3 起就写着「**含 `pilot_meta`**」，理由也给得很足（它承载归属与绑定）——**可下面那份「闭合清单」里一条 `pilot_meta` 的断言都没有**。于是一个 `key` 上没有主键、因而能塞进**两行 `seed`**（或两行 `output_dir`）的库，指纹照样相符、结构闸照样放行，而归属闸与绑定闸随后读到的是**哪一行取决于实现**。**这正是「声称 > 实际保证」的第 N 次**，而且发生在**决定 DROP 授权**的那张表上——`--reset` 的破坏性正建立在它之上。**闭合清单里必须有条目，标题里的「含 X」不算数。**

   > **`pilot_stock_source` 必须进结构闸（R12-F2 修正）**：它是 R6-F1 引入的、**唯一**能挡住「`export_log` 逐字节未变而 K 线内容已换」那一档的守卫。原先的五项断言全是 Plan 3 时代就有的表，唯独漏了这张本 plan 新加的、**安全关键**的表。一个缺了它（或被手工改坏）的库若能过闸，`already_done` 分支就没有比对基准——**取决于实现的兜底方式，要么跑到很晚才炸，要么直接退回 R6-F1 那条混代次的老路**。故：结构闸必须覆盖它，且这道判定要排在**任何 `already_done` 计数之前**。

**`DROP DATABASE` 之前必须断开本进程指向目标库的全部连接（O1-F2，实测坐实）**：

集群闸 (ii) 明写「名字匹配 `kline_pilot_*` → **连进去验归属**」，而**本次的目标库 `kline_pilot_<seed>` 自己就匹配**；
闸 0−/0/0b 又要连进目标库读 `pilot_meta`。于是**每一次带 `--reset` 的运行，在 DROP 之前都必然对目标库开过连接**。

> **⚠️ 实测坐实（2026-07-27，真 `postgres:15.12`）**：目标库上存在 1 条会话时，从维护库执行 `DROP DATABASE` 得到
> `ERROR: database "kline_pilot_probe" is being accessed by other users / DETAIL: There is 1 other session using the database.`，
> **库事后仍在**。这直接打在 §6.1 那条正向钉上——「归属与绑定都相符、但 `schema_sha256` 已漂移的库带 `--reset`
> **必须放行到 DROP + 重建**」——**reset 这条「唯一出路」在最常见的路径上不可用**。

**规定**：
1. **凡连进目标库的读（集群闸 (ii) 的遍历、闸 0−/0/0b）一律用「连进去 → 读完立即 `close()`」的短连接**，
   不得把连接留到 DROP 之后。DROP 之前须显式断言本进程对目标库的连接数为 0。
2. **明令禁止 `DROP DATABASE … WITH (FORCE)` 与 `pg_terminate_backend`**（PG13+ 支持，`postgres:15.12` 也支持）——
   它会**无差别 terminate 别人的会话**，正是本文件全套护栏要避免的行为。
3. 断开自己之后 DROP 仍因**其他会话**失败 → **fail-closed**：报 `FAIL_DB_BOUNDARY` +
   `db_boundary_error: "target_db_in_use"`，打印 `pg_stat_activity` 里的占用者（pid / usename / application_name），
   **不得重试成强制**。
4. L2 `verify_pilot_db_lifecycle.py` 增一档真跑：**集群闸遍历过目标库之后立刻 `--reset`** → 必须成功 DROP + 重建。

**闸的分工（唯一权威表述，R9-F1 修正）**：

| 闸 | 管什么 | DROP（`--reset`）时 | 复用时 |
|---|---|---|---|
| **0− `pilot_meta` 授权完整性**（R80-F1） | 闸 0/0b **读到的值算不算数** | ✅ **必过**（**排在 0/0b 之前**），不过则拒绝 DROP、库原样保留 | ✅ 必过 |
| 0 归属（`tool` + `seed`） | 这个库**能不能被我碰** | ✅ 必过，不过则拒绝、要求人工删 | ✅ 必过 |
| 0b 绑定（`export_log_sha256` + `output_dir`） | 这个库**是不是我这套设置的** | ✅ 必过；不过则拒绝并打印所绑身份 + 派生确认令牌，需 `--reset-foreign=<令牌>` 逐字相符（R34-F1）。**⚠️ 这条属性的强度必须诚实表述（O1-F9）**：令牌 =
`sha256(export_log_sha256|output_dir|created_at)[:12]`，三个输入**全部存在目标库的 `pilot_meta` 里**，
而任何能跑本工具的调用方本来就持有连进该库的凭据（集群闸就是这么读的）。故一个 wrapper 完全可以
「捕获 rc=1 → `psql` 读三个值 → 本地算 sha256 → 带令牌重跑」**全自动销毁别人的库**。
**它挡的是陈旧脚本 / shell alias / 复制粘贴的历史命令，挡不住蓄意 wrapper**——原文「只有真读过本次打印结果的人
才可能填对」**不成立**。（`confirm_token` 不进报告 JSON 那一层仍然有效，它挡的是更省事的那条路径。）| ✅ 必过 |
| 1 指纹（`schema_sha256` + **`pilot_schema_sha256`** + `contract_version`，R62-F1） | 这个库**还能不能直接用** | ❌ 不跑 —— 指纹不符恰恰是该 reset 的场景 | ✅ 必过 |
| 2 结构（**七组**断言，清单见 §4；含 `pilot_stock_source` 与 `pilot_meta` 自身，O1-F7） | 同上 | ❌ 不跑 | ✅ 必过 |

**按 seed 的集群级互斥锁（唯一权威定义在 4c，本节逐字复制以便 4a 独立实施；O1-F4）**：

```sql
SELECT pg_try_advisory_lock(hashtext('kline_pilot_' || <seed>));
```
- 取在 **`--maintenance-dsn` 那条连接**上；**非阻塞**（返回 `false` 即刻退出、绝不等待）；
  会话级，**连接断开自动释放**；持到最终报告落盘之后。
- **⚠️ `qmt_pilot_db` 模块不得自行取这把锁**——只接受调用方传入**已持锁的那条连接对象**。
  advisory lock **只在同一 session 内可重入**：若本模块另开一条维护连接去取同一把键，
  `pg_try_advisory_lock` 会返回 `false`，工具报「同 seed 的另一次 pilot 正在跑」并拒绝启动——
  **自己把自己锁死**（本仓 Plan 2b / Plan 3 已踩过同族的「锁下沉 + 可重入」问题）。
- **键派生与 SQL 必须与 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` 的 ①c 逐字一致**；
  任一方改动都要同步另一方（这是切分映射第三节第 4 条要求的跨文件检查项）。

**库名与 seed 的两条实现级硬性规定（O1-F11）**：
1. **正则一律用 `re.fullmatch`**（或收尾用 `\Z`）。Python 的 `$` 在非 `fullmatch` 下匹配「串尾**或串尾换行之前**」——
   `--seed "$(cat seed.txt)"` 带尾随换行时 `"x\n"` 会过 `^[a-z0-9_]{1,32}$`，派生出库名 `kline_pilot_x\n`；
   此后所有闸针对**那个带换行的名字**求值（不存在 → 走建库分支），而字符串拼接进 SQL 后
   `CREATE DATABASE kline_pilot_x\n` 被解析成 `kline_pilot_x` —— **闸判定的库与 DDL 实际作用的库不是同一个**。
2. **库名按出现位置分三种写法（P1r3-F11 更正——一刀切 `Identifier` 会在两个新注入点写出坏 SQL）**：
   · **标识符位**（`CREATE/DROP DATABASE <name>`）→ `psycopg.sql.Identifier`；
   · **字符串比较位**（`pg_database.datname = %s`、`pilot_create_intent.dbname = %s`）→ **绑定参数**
     （套 `Identifier` 会生成 `datname = "kline_pilot_x"` → PG 解析成**列引用** → `column does not exist`，集群闸每次抛异常）；
   · **注释体 / 字面量位** → `sql.Literal`（`COMMENT ON` 的 `IS` 后面**不接受绑定参数**）。
   **一律禁止 f-string 拼接。**
   §6.1 的负向表补一档尾随 `\n`/`\r`、一档前导空白。

**任何一次连进目标库的读失败一律 fail-closed（P1r3-F6）**：目标库被 P1r3-F4 移出闸 (ii) 的遍历后，
O1-F10 那条「连不进去 = 无法证明归属 = 拒绝」不再覆盖它，而**零对象例外的【绝对空】探测、闸 0−、闸 0、闸 0b
全都要连进目标库**。故独立规定：`datallowconn=false` / `datconnlimit=0` / 无 CONNECT 权限 / 正被别人删除 →
**`FAIL_DB_BOUNDARY` + `db_boundary_error: "target_db_unreadable"`**（新码须同步进 4c 枚举），
拒绝 DROP、拒绝复用。**绝不 `try/except` 当作「没查到对象」**——那会让一个被刻意冻结的库
（DBA `ALTER DATABASE … ALLOW_CONNECTIONS false` 做维护）被判【绝对空】而直接 DROP。

**闸 0− 的判据（唯一权威定义，R80-F1）**——**只查「授权读得准不准」，不查 schema 新旧**：
- `pilot_meta` 表存在；`key` 为 `text` 且**有主键或等价唯一约束**；`value` 为 `text`；
- **四个授权键各恰好一行且可读**：`tool` / `seed` / `export_log_sha256` / `output_dir`；
- 任一不满足 → **`FAIL_DB_BOUNDARY` + `db_boundary_error: "pilot_meta_ambiguous"`**、rc=1，
  **拒绝 DROP、拒绝复用，目标库原样保留**，提示人工处理。

**`pilot_cluster_marker` 的规范 DDL 与形状校验（O1-F8；它是授权「碰这台集群」的凭据，却一直没有 DDL）**：
它必须进**被哈希的** `backend/sql/pilot_cluster_schema.sql`（**独立一份，P1-F5**——
**绝不放进 `pilot_schema.sql`**：后者会同时建 `pilot_meta` 与 `pilot_stock_source`，
apply 到**维护库**会让它多出两张表 + 两个 pkey 索引 → **闸 (iii) 永久不过、工具彻底不可用**；
反过来把它放进 `pilot_schema.sql` 又会让**每个 pilot 库**都多出一张空的 `pilot_cluster_marker`，
而闸 2 的七组闭合清单里既没有它、也没定义「遇到未登记的表怎么办」。
两份文件各记各的 sha：`pilot_schema_sha256` 进 `pilot_meta` 与指纹闸；
**删掉 `cluster_schema_sha256`**（P1r3-F9：闸 (iii) 要求维护库除这两张表外**绝对空**、marker 表又被闸 (i) 锁成固定形状，**集群里没有任何地方能存这个 sha**，「自己校验」无对照物；而闸 (i) 的形状断言已经覆盖了它想保护的东西——「谁写/谁读/谁清」三问皆空的字段不该存在）（**绝不手写一段 DDL 现建** —— 那正是 R64-F3 对 `pilot_meta`
明令禁止的做法），且至少 `purpose TEXT PRIMARY KEY`：

```sql
CREATE TABLE IF NOT EXISTS pilot_cluster_marker (purpose TEXT PRIMARY KEY);
```
- **闸 (i) 先校验表形状再读值**（同「一个能授权删东西的结构，自己必须先被校验」，R21-F3）：
  表存在 + `purpose` 为 `text` 且是主键 + **恰好一行** + 值等于 `'qmt_pilot_disposable_cluster'`。
  任一不符 → 拒绝。**不得实现成 `SELECT purpose FROM pilot_cluster_marker LIMIT 1`**（无 `ORDER BY`，返回行任意）——
  两行时它与 `EXISTS(… WHERE purpose='…')` 给出相反结论，**同一台集群能不能被建库/DROP 取决于实现细节**。
- **闸 (i) 的形状断言逐表覆盖【维护库专用表集合】（O4-F1 + O4-F7）**：除上面 `pilot_cluster_marker` 那组外，
  还须断言 `pilot_create_intent` **表存在**且 `dbname` 为 `text` 且是主键、`seed`/`created_at`/`run_id` 均为 `text`、
  `create_confirmed` 为 `boolean`（O4-R8-C1 落地：此前实现只读 marker 的**值**，两张表的**结构**一条都没验过 ——
  注释写着「先验形状再读值」而代码没有，一行 magic string 塞进任意关系即可授权整台集群）。
  **`dbname` 的唯一约束尤其不能省**：`ON CONFLICT (dbname)` 那套抢占语义整个建立在它上面。
  **缺表或形状不符 → 拒绝，提示 `--init-cluster-marker`**（**不是**「豁免不适用」——它俩是集合成员，
  缺一张就意味着这台集群是**旧版本**初始化的，而旧版本没有 intent 表 → 零对象例外第 6 条恒不成立 →
  残骸永远清不掉，正是 R56-F1 的洞换形态复发）。
- **`--init-cluster-marker` 的幂等语义写死**：已存在合法单行标记**且 `pilot_create_intent` 形状合规** → 直接成功；
  **标记合法但 intent 表缺失/形状不符 → 补建它再成功**（O4-F7：短路成功的实现修不好旧版本初始化的集群）；
  标记非法/多行 → **拒绝**，要求人工处理。
- **谁写／谁读／谁清**：`--init-cluster-marker` 写；闸 (i) 每次运行读；**本工具从不清它**（清除是人工动作）。

**`pilot_database_registry`（【维护库专用表集合】第三张表，O4-R14-C1 / R16-C2）**：
`(dbname TEXT PRIMARY KEY, seed TEXT NOT NULL, run_id TEXT NOT NULL, claimed_at TEXT NOT NULL, db_oid OID NOT NULL)`。

**必须绑到「这一个数据库实例」，不只是名字（O4-R16-C2）**：只绑名字时，本工具建过 `kline_pilot_x` 之后，
就算它被删掉、**别人用同名重建**，这一行仍然为那个全新的库背书——对手再伪造一份 `pilot_meta` 即可过闸 (ii)，
而他**并不需要维护库的写权限**，正好击穿这张表想守的那条边界。
判据写成 `JOIN pg_database d ON d.oid = r.db_oid AND d.datname = r.dbname`。
OID 由 PG 分配、对手**无法自选**，故不需要秘密即可绑定实例（比 nonce 少一个 `pilot_meta` 键，
不牵动 7/2 分阶段）。写入用 `ON CONFLICT (dbname) DO UPDATE … db_oid = EXCLUDED.db_oid`——
`--reset` 重建同名库时 OID 会变，**不改写的话本工具自己刚建的库会被自己的闸判成外来物**。
> 已知残余：OID 是 32 位、理论上会回绕重用；需要 2^32 次 OID 分配才可能撞上，如实登记，不做处理。
> 另：`d.datname` 是 `name` 类型而插入列是 `text`，同一个 `$1` 喂给两边会让 PG 推不出参数类型
> （真 PG 报 `AmbiguousParameterError`；host 假件不执行 SQL，**永远看不见这一类**）——须显式 `::text`。
- **谁写**：`CREATE DATABASE` **成功之后**（O4-R15-C1 纠正上一版），`ON CONFLICT (dbname) DO NOTHING`（可重入），
  并**读后验**该行确实在（`DO NOTHING` 时命令状态本就可能是 `INSERT 0 0`，行数说明不了问题）。
  > **上一版把它写在建库之前，理由是「否则建成了但没登记会锁死」—— 那个前提不成立**（已实测）：
  > 唯一的窗口（建库成功 → 登记之间）留下的库必然是**空的**（`TEMPLATE template0`），
  > 而闸 (ii) 早有「零用户对象即残骸」豁免会放行它。**该前提本身已有一颗钉子**，
  > 它一旦变红，把登记挪到建库之后的理由就没了。
  > 写在之前的代价却是真的：集群闸**跳过目标库**，所以「目标库是别人的、本就存在」这一档能一路走到
  > `CREATE DATABASE`；此时登记行已落库，随后 `42P04` 只撤 intent，**登记行永久留下** ——
  > 一次失败的建库就把一个外来库从「拒」变成了「信」，正是这张表被引入来防的那件事。
  >
  > ⚠️ **这已是同一族错误第三次**（R9→R10 的 `create_confirmed`、R14→R15 的登记行）：
  > **凭据必须在它所证明的事实成立之后才写**；把它提前到「意图」阶段，失败路径就会铸出假凭据。
  >
  > 附带：登记表**永不清理**意味着验证脚本必须自己在前置/收尾清掉本次用到的行，
  > 否则上一次运行留下的凭据会让下一次的断言假红（已实测踩到，脚本已改为可重入）。
- **谁读**：闸 (ii)。
- **谁清**：**本工具从不清它**。它记的是「本工具声明过哪些库名」，删掉会让既有 pilot 库
  在闸 (ii) 里变成外来物。清除是人工动作。（模块内有源码守卫禁止出现清理它的语句。）
⚠️ 新增这张表**必须同时**改：`MAINTENANCE_TABLES` 常量 / 闸 (iii) 豁免（由该常量派生，自动）/
闸 (i) 的形状断言 / 本节集合定义 / §5 / §9-1a。测试侧的成员清单已改为**从 schema 文件推导**，
不再硬编码 —— 加表时它自动变红，而不是等人想起来改它。

**闸的执行序列（显式有向，O1-F5；照闸表自上而下实现会原样重现 R56-F1 要修的锁死）**：

```
集群闸 (i)(ii)(iii)
  → 【零对象例外判定】六条：①带 --reset ②库名全等 kline_pilot_<seed> ③【绝对空】④集群闸全过
                          ⑤已持按 seed 锁 ⑥pilot_create_intent 有本次行、seed 相符、
                             **create_confirmed = true**、且未超 INTENT_TTL
        ├─ 六条全成立（且 DROP 前紧贴着重查【绝对空】通过）→ 直接 DROP + 两阶段重建（**不进闸 0−/0/0b**）
        └─ 否则 ↓
  → 闸 0−（仅对**已存在 `pilot_meta` 表**的库求值）
  → 闸 0 → 闸 0b → （复用时另跑 闸 1 → 闸 2）
```
**闸 0− 的第一条判据必须写成「**已存在 `pilot_meta` 表**的库须满足…」**，使「表不存在」这一档
**不由 0− 处置**——否则残骸 + `--reset` 会在 0− 第一条就撞 `pilot_meta_ambiguous`「拒绝 DROP、库原样保留」，
**残骸永远清不掉**，正是 R56-F1 花一整轮修的那个洞。

**`pilot_meta` 表缺失映射哪个错误码（O1-F6 收口）**：**表不存在 → `not_owned`**；
**表存在但形状不合规 / 键不唯一 / 授权键缺失 → `pilot_meta_ambiguous`**。两者给操作者的下一步动作不同
（前者「不是本工具建的，请手工删」，后者「元数据自相矛盾，交给人」），而报告消费者按这个码分诊。

**零对象例外的残余风险与收紧（O1-F12）**：R56-F1 的论证是「零对象保证被删的东西里没有任何数据」——
**这只在检查那一瞬成立**。管理员正在 `pg_restore --create`（先建库、再灌数，中间有明确空窗）、
或同事刚 `CREATE DATABASE kline_pilot_x` 准备手工建表 —— 此刻本工具带 `--reset` 跑，六条全成立 → **DROP**，
恢复/建库中途被摧毁，全程无归属证明、无令牌、无确认。
**收紧**：零对象例外**追加第 6 条**：**维护库的 `pilot_create_intent` 表里有本次库名的行、`seed` 相符
且 `create_confirmed = true`**（P1r3-F2 重定；`create_confirmed` 由 O4-R8-C2 追加）。
**`COMMENT ON DATABASE` 方案已被否决**（理由见下方 P1r3-F2 与 P1-F3 两条），**不得再写那条注释**（O4-F3）。

     > **为什么放弃 `COMMENT ON DATABASE`（P1r3-F2）**：放宽成「注释存在且 seed 相符**或注释完全不存在**」后，
     > 判别力归零——真值表只剩「注释存在但 seed 不符」才拒，而例外第 2 条已要求库名**全等** `kline_pilot_<seed>`、
     > 我们写的注释又是同一个 seed，那一档实际只剩「DBA 手工给空库写过别的注释」。逐条对照它要挡的两个威胁：
     > **同事裸 `CREATE DATABASE`（不带注释）→ 判「注释不存在」→ 放行 → DROP 掉同事的库**（引入第 6 条的原因，原样回来）；
     > **`pg_restore --create` 中途**（已实测：注释在第一张表**之前**落地）→「存在且相符」→ 放行 → DROP 掉正在恢复的库。
     > **两个都不挡，代价却是一次不可原子化的写。**

     **`pilot_create_intent`（写在 `CREATE DATABASE` 之前，故没有窗口）**：
     ```sql
     -- 进 backend/sql/pilot_cluster_schema.sql（与 marker 同一份，一并进闸 (iii) 豁免）
     -- ⚠️ run_id 是**归属凭据**（O4-C2，codex 判 medium）：没有它时 intent 行只由 dbname 标识，
     --    「谁写的」无从证明 —— 并发的另一次运行、或先前失败留下的孤儿行，都会被
     --    零对象例外第 6 条当成「本次运行声明过要建这个库」，**授权 DROP 一个不是本次建的库**。
     CREATE TABLE IF NOT EXISTS pilot_create_intent (
       dbname TEXT PRIMARY KEY, seed TEXT NOT NULL, created_at TEXT NOT NULL,
       run_id TEXT NOT NULL,
       -- O4-R8-C2：**持久证明，不是「尽力清理」**。见下方「create_confirmed」条。
       create_confirmed BOOLEAN NOT NULL DEFAULT false);
     ```

     **`create_confirmed`：intent 行何时才成为凭据（O4-R8-C2）**——
     intent 行写在 `CREATE DATABASE` **之前**，所以它单独存在**并不证明**「这个库是本次建的」。
     确定性失败（`42P04` 等）时要撤回它，但**撤回那一步自己也会失败**（连接抖动、权限），
     于是残留行仍会被零对象例外当成「本次的崩溃残骸」，去 DROP **别人建的**同名空库。
     把安全性挂在「清理一定成功」上是错的。故：
     - `INSERT` 时**显式**写 `create_confirmed = false`；
     - **`ON CONFLICT` 分支按 `run_id` 决定确认位的去留（O4-R9-C1，真 PG 复现过）**：
       **同 `run_id` 重入 → 保住已有的 `true`**；**抢占陈旧的别人那行 → 归零**。
       写成无条件 `false` 会造出一条自毁链：上一次已建库并确认、崩在后面 →
       重试把确认打回 `false` → `CREATE DATABASE` 撞 `duplicate_database` →
       确定性失败清理把行删掉 → **空残骸从此没有任何销毁授权，工具再也清不掉自己建的库**；
     - `CREATE DATABASE` **确认成功之后**才 `UPDATE … SET create_confirmed = true`；
     - **零对象例外第 6 条只认 `create_confirmed = true` 的行**（4a-2 实施者的硬约束）；
     - **撤回只删「本次刚声明、尚未确认」的行**：`DELETE … AND NOT create_confirmed`
       （O4-R9-C1；谓词写进 SQL 而非先查后删，避免中间态）。已确认的行是清理残骸的唯一凭据；
     - 撤回失败时**绝不能让清理异常盖掉原始建库错误**（否则「库已存在」被报成「删行失败」，
       排障方向整个带偏）；留下的行 `create_confirmed` 仍是 `false`，授权不了任何 DROP，由 TTL 兜底。

     > **已登记的残余（fail-closed 方向）**：连接恰好死在 `CREATE DATABASE` 期间时，
     > 库**可能**已建出来而确认没跑成 → 该行停在 `false` → 零对象例外认不出这个残骸，
     > 需人工删。这是**故意选的方向**：宁可自己清不掉，也不能授权去删别人的库。
     > 与 R56-F1 那次锁死的区别是命中面 —— 那次是「schema 应用中途崩」这一**常见**路径，
     > 这次只在「连接死在 CREATE DATABASE 这一瞬」。
     - **谁写**：`CREATE DATABASE` **之前**，维护连接上 `INSERT` + `COMMIT`。
       ⚠️ **三条硬要求（O4-C2）**：
       ①**调用方必须已持有 ①c 的按 seed advisory lock**（本模块不自行取锁，O1-F4）——
         否则两次同 seed 的运行会互相覆盖 intent 行，而它是 DROP 授权的凭据；
       ②`ON CONFLICT (dbname) DO UPDATE` **只在「同一 `run_id` 重入」或「既有行已超
         `INTENT_TTL`」时才接管**（`WHERE` 子句 + `RETURNING run_id`）；冲突且对方新鲜 →
         RETURNING 为空 → **拒绝启动**，绝不覆盖（那会把别人的 DROP 授权转到本次名下）；
       ③收尾的 `DELETE` **必须带 `run_id` 条件**，否则会删掉别人那条。
     - **谁读**：零对象例外第 6 条；
     - **确认必须紧贴 `CREATE DATABASE`，中间不夹任何可失败步骤（O4-R16-C1）**：
       上一版把登记表的写入 + 读后验放在了「建库成功」与「写确认」之间。那两步任一失败，
       都会留下「有库、但 intent 仍是 `false`」的状态；同 `run_id` 重试撞 `duplicate_database` 后，
       确定性失败清理把那行未确认的 intent 删掉 —— **空库从此没有任何销毁授权**。
       **凭据要紧贴着它所证明的事实写**（与 R15-C1 同一条原则的另一面：R15 是「不能写太早」，
       这条是「不能拖太晚」）。
     - **确认写入同样必须核命令状态**（O4-R11-C2，与收尾清理对称）：期望 `UPDATE 1`，
       不合则报 `intent_not_confirmed` 并说明「库**已经建出来了**、请人工删除」。
       并发运行把 intent 行抢走/删掉时这里是 `UPDATE 0`，照常往下走会留下一个
       **没有恢复凭据的空库**：零对象例外认不出它，可自愈的残骸变成人工清理 + 挡住同名重建。
       失败必须**先于**任何目标库副作用。
     - **收尾清理必须异常安全，且判据是「行真的不在了」（O4-R12-C2）**：到这一步库**已经 ready**，
       裸异常逃出去会让调用方当成「建库失败」而重来一遍，实际是一个好库 + 一行残留的销毁授权。
       故：清理语句的异常就地捕获 → **读后验**该行是否仍在 → 仍在（或复核本身也失败）才报
       `intent_not_cleared`，报错须同时带上原始异常/命令状态。
       反过来 `DELETE 0` 但该行**本来就不在**（上次已删、或异常发生在提交之后）**不得报错**。
     - **谁清**：本次运行**干净收尾时删该行**（DROP+重建成功、或复用成功）。
       ⚠️ **干净收尾与确定性失败撤回必须是两条不同的 SQL（O4-R10-C1）**：撤回那条带
       `AND NOT create_confirmed`，而成功建库的行必然已 confirmed —— 复用它会**永远匹配 0 行**，
       于是**每一次正常成功的运行都留下一行「新鲜且已确认」的 intent**（既把后来者当外来行挡住，
       又是一张对同名空库的销毁授权）。**且必须核命令状态**（期望 `DELETE 1`），不合则报
       `intent_not_cleared` 并说明「建库本身是成功的」——
       R9 那次回归能溜过去正是因为没人看 DELETE 报了几行，语句照发不误而一行没匹配上。
       验收断言必须看**数据库状态**（成功后表里真的没有该行），不能只断言「发过一条 DELETE」。
       **⚠️ 孤儿行不是「无害且自愈」（O4-F2 撤回上一轮的断言）**：崩在「INSERT intent」与
       `CREATE DATABASE` 之间会留下一行**永久有效的销毁授权**——此后任何人用这个名字建的空库
       （同事手工 `CREATE DATABASE kline_pilot_<seed>`、`pg_restore --create` 跑到一半）都满足第 6 条，
       **被本工具直接 DROP**。而上一轮写的清理谓词「指向 `pg_database` 里不存在的库」
       **恰恰在这行变危险的那一刻为假**（库已经被别人建出来了）；
       `--init-cluster-marker` 又不持任何 seed 锁，**还能删掉一次正在进行的运行的行**。三条修正：
       ①`INSERT` 用 **`ON CONFLICT (dbname) DO UPDATE`**（否则同名重跑会撞主键）；
       ②**第 6 条加新鲜度界**：该行 `inserted_at`（库时钟，O4-R23-C1 起不再用 `created_at`）
         距今须 **< `INTENT_TTL`（写死 24h）**。
         超期行**不满足第 6 条**（判定时**不删它**——普通运行不替别的 seed 做决定），
         提示「若这个空库确属上次残骸，请重跑一次；否则请人工确认后删除」。
         授权窗口由此从「永久」收窄到「本工具上次崩溃后 24h 内 **且** 同事恰好用了同一个 seed 名」；
       ③孤儿行**只在 `--init-cluster-marker` 时清理**，且**逐行先 `pg_try_advisory_lock` 取该行 seed 的锁**，
         **取不到就跳过**（O4-F2：不加这一步会删掉一次正在进行的运行的行 → 那次运行随后判第 6 条不成立 →
         自己的残骸自己清不掉）；取到才删、删完立刻释放。清理判据 = **超期 OR 库不存在**。
       **两个不同 seed 撞同一个 dbname 不可能**——dbname 恒为 `kline_pilot_<seed>`，seed 是它的函数。
     - **判别力**：同事的空库与 restore 中的库**都没有 intent 行 → 拒**；我们自己的残骸**必然有 → 放行**。
       残余收窄为「本工具上次崩过 **且** 同事恰好用了同一个 seed 名」，如实登记 §8。

     > **为什么第 6 条必须允许「注释不存在」（P1-F2）**：`CREATE DATABASE` 不能在事务里，
     > 它与 `COMMENT ON DATABASE` **不可能原子**。进程在 CREATE 返回之后、COMMENT 之前被 kill
     > （或维护连接 idle timeout / failover / 被 DBA 掐断）→ 留下「库存在 + 【绝对空】+ **无注释** +
     > 库名恰为本次 seed」。下一次 `--reset`：集群闸豁免放行 → 第 6 条不成立 → 落到闸 0−（表不存在，不求值）
     > → 闸 0 缺 `pilot_meta` → `not_owned`、拒绝 DROP、要求人工删。**而这个库名正是本次要用的**
     > → **既不能复用也不能清，工具被自己的护栏锁死** —— 正是 R56-F1 花一整轮消掉的那个洞换形态复发。
     > 放宽之后，第 6 条把残余从「所有空库」收窄到「**无注释空库**」，而**不切断恢复路径**。

     > **⚠️ 第 6 条堵不住它原本要堵的 `pg_restore --create` 场景（P1-F3，真 PG 实测）**：
     > 对一个带该注释的库跑 `pg_dump --create`，输出行序实测为
     > `CREATE DATABASE …`(L23) → `\connect`(L28) → **`COMMENT ON DATABASE … IS 'qmt_pilot:x:…'`(L45)**
     > → `CREATE TABLE public.klines`(L56) → `COPY`(L67)。
     > 即 restore 执行到 **L45~L56 之间**时该库：存在 + 六条【绝对空】SQL 全 0 + **注释存在且 seed 相符**
     > → **六条全成立 → 直接 DROP 掉一个正在恢复中的库**。restore 中途失败留下的现场同理。
     > **故「真正的残骸必然有它，而别人建的空库没有」这句断言不成立**，已删除。
     > **残余如实登记 §8**，并把「DROP 前须**紧贴着**重查一次【绝对空】」从散文提进例外判据本身与 §9-2g。
**§8 如实登记残余**（O4-F2）；**DROP 前须紧贴着重查一次【绝对空】**（已提进例外判据本身与 §9-2g）。

**`CREATE DATABASE` 确定性失败时必须撤回 intent 行（O4-R7-C1，真 PG 复现）**：

> 集群闸**跳过目标库**（那是闸 0−/0/0b 的职责），所以「目标库本就存在」这一档能一路走到
> `CREATE DATABASE`。此时若把 intent 行留下，它就变成一张「**这是我的崩溃残骸**」的凭据，
> 而本次**什么都没造** —— 之后 `--reset` 会凭它把**别人建的**同名空库当成本次残骸，
> **无 `pilot_meta` 归属、无 `--reset-foreign` 令牌**地 DROP 掉。
>
> **规定**：`CREATE DATABASE` 抛出且 SQLSTATE ∈ 确定性失败集
> （`42P04` duplicate_database / `42501` insufficient_privilege / `3D000` invalid_catalog_name /
> `53300` / `22023`）时，**先删掉本次 run_id 的 intent 行再上抛**。
> **歧义失败（连接丢失、无 SQLSTATE）一律保留** —— 那时库可能真的建出来了，
> 而 intent 行是「清理我自己残骸」的唯一授权。**宁可多留（有 TTL 兜底），不可错删。**

**建库路径的前置条件必须机器强制，不能是注释级约定（O4-R5-C2）**：

> `create_pilot_database` 此前只做本地名字检查 + 信一个调用方传进来的
> `seed_lock_held: bool`，而集群闸只写在 docstring 里「调用方须先跑」。
> **任何接线失误都能在未过集群闸的情况下直接在传进来的 DSN 上建库** ——
> 标记闸 / 无关库闸 / 维护库空闸全部被跳过；那个布尔值传 `True` 就能绕过锁的要求。
>
> **规定**：①`create_pilot_database` **内部调用** `assert_cluster_allowed`
> （重复调用的代价只是几条只读查询，远小于漏掉一次的代价）；
> ②按 seed 的 advisory lock **在活连接上查 `pg_locks` 真验**，键派生与
> `pg_try_advisory_lock(hashtext('kline_pilot_' || <seed>))` 一致。
> 本模块仍**不取锁**（O1-F4），只验它是否真被持有。

**所有表引用一律 `public.*` 限定（O4-R4-C1，codex 指出、真 PG 复现）**：

> 结构判据用 `to_regclass('public.pilot_meta')` 验的是 public 那张，而不带 schema 的
> `SELECT … FROM pilot_meta` 由 **`search_path`** 决定读哪张。实测
> `SET search_path = evil, public` 时**验的是 public、读的是 evil** ——
> 一个**完全不属于本工具**的库，凭 `evil` schema 里**一行**伪造的 `tool='qmt_pilot'`
> 就冒充归属成功，集群边界当场失效。
>
> **规定**：`qmt_pilot_db` 里每一条读/写/建表 SQL 都必须 `public.*` 限定，
> 两份 `.sql` 文件的 `CREATE TABLE` 同样限定。
> **这比「在连接上 SET search_path」更稳** —— 它不依赖调用方的连接是怎么建的。

**每条守卫连接必须先把 `search_path` 钉死（O4-R17-C1，真 PG 15.12 实测）**：
`public.pilot_*` 限定（O4-R4-C1）只堵住了**自己的表**那一侧，**系统目录**一侧仍然敞着。
PostgreSQL 里 `pg_catalog` 只有在**未被显式列出**时才隐式排在最前；一旦 DSN／角色／库把它
显式排在某个可写 schema 之后，裸 `pg_class` 就解析到 `evil.pg_class` ——
实测 `SET search_path = evil, pg_catalog, public` 之后 `SELECT count(*) FROM pg_class`
从 425 行变成 1 行，整台集群的「除本工具外别无他物」会在**对手控制的数据**上求值。

- **钉成 `SET search_path = public`，不是 `pg_catalog, public`**（两条都实测过）：
  前者抹掉显式排布、让「系统目录隐式优先」重新生效（存在 `public.pg_class` 影子表时，
  `pg_class` 与 `to_regclass('pg_class')` 仍指向真目录），且不限定的业务 DDL 落在 `public`；
  后者会把 `schema.sql` 里不限定的 `CREATE TABLE stocks` 送进 `pg_catalog` →
  `permission denied to create "pg_catalog.stocks"`，当场打断建库。
- **为什么不逐个加 `pg_catalog.` 前缀**（评审的建议）：目录与内建函数的引用有几十处
  （`to_regclass` / `format_type` / `hashtext` / `pg_get_expr` / 聚合 `count` …），
  **漏掉一个是静默的**，而且以后每加一条 SQL 都要记得。`SET search_path` 是纯语法、
  不经过名字解析、**无法被遮蔽**，一句话把后续所有解析（含函数）都钉住。
  代价是会改动调用方连接的会话状态 —— 对守卫模块而言这正是想要的。
- **覆盖面按结构检查，不靠黑盒断言**：钉桩在多处冗余（`read_pilot_meta_rows` /
  `assert_cluster_allowed` 内部也各钉一次），黑盒断言「这条连接钉了吗」**分辨不出是哪一处钉的**，
  删掉任意单点都不会变红（实测两条 mutation 都没红）。故改为结构守卫：
  模块里每个 `await connect(...)` 之后两行内必须有 `pin_search_path`，
  且三个信任边界入口的**函数体第一条 `await`** 必须是钉桩。
  ⚠️ 写这条结构守卫时踩了「窗口不设边界」：用固定字节数截函数体会溢出到下一个函数，
  于是删掉本函数的钉桩后匹配到的是**下一个函数**的 → 钉子静默失效。窗口必须切到函数边界。

**已复核并否决的一条（O4-R17-C2）**：评审判定「`hashtext` 返回有符号 int32，负值时
`classid::bigint << 32` 会溢出或得到无符号值，约一半 seed 会误判 `seed_lock_not_held`」。
**真 PG 15.12 实测不成立**：PostgreSQL 的 int8 `<<` 是按位移位、会绕回，
`hashtext('kline_pilot_a') = -892022995` 时 `classid=4294967295 / objid=3402944301`，
`(classid::bigint<<32)|objid::bigint` 重建出来**正是 -892022995**。
四个负 hash 与四个正 hash 的 seed 逐个取锁复核，判据全部成立。
结论既然是「现状正确」，就为它留了钉子（真 PG 场景 ⑧b），免得下一轮重新论证一遍。

**指纹取整行表级属性，不再逐个字段补（O4-R35-C1）**：
`ALTER TABLE public.training_sets SET UNLOGGED` 改的是 `pg_class.relpersistence` ——
列/约束/默认值/序列/索引**一个都不动**，指纹毫无察觉，而库从此不再崩溃安全
（PostgreSQL 崩溃后 unlogged 表会被 truncate）。
> ⚠️ **这已经是第三次「指纹漏了一个维度」**（R33 默认值 → R34 序列 → 本次 relpersistence）。
> 逐个补下去永远比下一个评审慢一步。故这次改法不是「再加一个字段」，而是把**表级那一行整体纳入**：
> `relkind / relpersistence / 访问方法 / 表空间 / reloptions / relispartition /
> relrowsecurity / relforcerowsecurity / relhassubclass / relhasrules / relhastriggers /
> relhasindex / relchecks / relnatts`。
> 这是「按**被保护的性质**枚举，而不是按被点名的那个名字」的一次落地 ——
> 被保护的性质是「活库就是规范 DDL 产出的那个样子」，那就把描述「样子」的整行取来。

**目标连接必须绑到刚建出来的那个实例（O4-R35-C2）**：
`CREATE DATABASE` 与 `connect(db_name)` 之间存在窗口 —— 期间有人把它删掉再用同名重建，
这条连接就指向一个**替身**：schema 与 ready 元数据会写到替身上，
而 intent／登记里记的 `db_oid` 指着那个已经消失的实例。
判据：建库后立刻取 `pg_database.oid`，`adopt_connection` 再比对目标连接自己看到的
`current_database()` 的 oid → `connection_wrong_instance`。
> 这是「**凡是『这就是我那个库』的断言，都要绑实例而不是绑名字**」的**第三处落点**
> （R16-C2 登记表 → R21-C1 intent 行 → 本条 活连接）。
> 前两次都是被评审逐个点出来的；这一条记在这里，是为了让第四处一出现就能自己想到。

**凭据必须在授权成立的那一句 SQL 里就绑死实例（O4-R36-C1）**：
上一条把**目标连接**绑到了新实例，但那道检查**排在持久凭据落库之后**。
`CREATE DATABASE` 成功 → 读到 oid → 此处它被删掉又同名重建，则
`_CONFIRM_INTENT_SQL` 与 `_REGISTER_DB_SQL` 都还在**按名字**取行：
替身会被盖上 `create_confirmed = true`（零对象例外第 6 条据以**授权 DROP DATABASE**），
并拿到一行 `pilot_database_registry` 凭据 —— 而**那张表本工具从不清**，
一个外来库从此永久通过闸 (ii) 的外部凭据。随后的 `connection_wrong_instance`
确实会拒掉这次运行，但凭据已经留下了。
判据：把捕获到的 oid 作为参数传进这两句 SQL（`$3` / `$5`），
`WHERE … AND d.oid::text = $n`；取不到行即 `UPDATE 0` / 插 0 行 → fail-closed
（`created_database_replaced` / `registry_not_written`）。
> ⚠️ **判据必须写在那一句 SQL 里**，不能「先查 oid 再决定要不要执行」——
> 后者就是本条要修的那个竞态本身。`UPDATE 0` 之后那次读 oid 只用于**措辞**，不据以决定授权。

> ⚠️ **同族第四、五、六处落点，且第六处是自查补的**。落点清单（本 PR 内）：
> R16-C2 登记读 → R21-C1 intent 保留位 → R35-C2 目标连接 →
> **R36-C1 确认位 + 登记写** → **自查补：闸 0− 枚举后逐个连进去判归属**
> （`pg_database` 读到名字之后、`connect(name)` 之前被同名重建，
> 这道闸就是在替身上得出「集群干净」，而它声称检查的是刚才枚举到的那一个）。
> 上一轮写下「让第四处一出现就能自己想到」——**没做到**：第四、五处仍是被评审点出来的。
> 故这一轮不再只写纪律，而是留下**机械守卫**
> `test_every_pg_database_predicate_binds_to_an_instance`：
> 扫模块里每一条含 `pg_database` 的 SQL 常量，要求它**比较** oid
> （正则 `\.oid(::text)?\s*=`，不是「含 oid 三个字母」—— 旧 `_REGISTER_DB_SQL`
> 的 SELECT 列表里就有 `d.oid`，弱判据对本轮的真 bug 毫无反应，实测确认）；
> 只有三条**捕获点**可豁免，且带反向断言「至少 4 条被真正检查」，
> 防止靠「全都加进白名单」把守卫掏空（两条都已变异验证）。
> 内联 SQL 是这条守卫的盲区，故捕获点一并提成模块常量 `_CREATED_DB_OID_SQL`。

**序列指纹取整行；并就此收口（O4-R38-C1 + 收口决定）**：
R34 加序列段时只取了 `start_value / increment_by / cycle` —— 正是 R35 刚为**表**修掉的反模式。
本机 PG 15.12 实测：`MAXVALUE 2` / `AS smallint` / `CACHE 1000` 三种改法都让这三个字段
**一字不变**，而 MAXVALUE 改小之后第三次 INSERT 直接
`nextval: reached maximum value of sequence`（已复现）；
另实测 `ALTER SEQUENCE … SET UNLOGGED` **PG 15.12 支持**（relpersistence→`u`），
故 R37 给表补的崩溃安全证明，序列这边同样躲得过。
判据：取 `pg_sequences` 的整行行为属性 + 序列自己的 `relpersistence`；
**刻意排除** `last_value`（运行时状态，取了指纹不再确定）与 `sequenceowner`（随部署角色而变）。
验收脚本按 **PostgreSQL 自己的列清单**核覆盖率：每一列要么进指纹、要么在写明理由的排除清单里，
PG 升级新增一列即变红。
> ⚠️ 顺带纠正评审给的例子：`ALTER SEQUENCE … MAXVALUE 1` 在 PG 15.12 **会被拒**
> （`MINVALUE (1) must be less than MAXVALUE (1)`）。**结论仍然成立**，
> 但可复现的最小改法是 `MAXVALUE 2`。

---

### 收口决定（2026-08-04，user 拍板）

**codex 在 R8–R38 共 32 轮中从未 approve**，每一轮都是 `needs-attention` 且至少一条 high。
每条 finding 都经真 PG 变异复现，全部为真、全部已修。**但这不是收敛。**

最后四轮属于**同一个元模式**：某个证明「按字段/按位置枚举」而不是「按被保护的性质枚举」
（R35 表级整行 → R36 绑实例 → R37 守卫表耐久性 → R38 序列整行）。
数据库对象图还有大量同族成员（索引、约束、类型、函数、扩展、排序规则、权限……），
**没有证据表明这个序列会终止**，而每轮的边际收益在下降、成本恒定。

**已接受残留（user 决定，override 收口）**：
「**活目录指纹的完备性**」这条线不再逐轮追加。理由：
1. 它是**第二层纵深**。第一层是 `CANONICAL_SCHEMA_SHA256` / `CANONICAL_PILOT_SCHEMA_SHA256`
   ——**递进来的 DDL 字节**已被钉死，「敌意 schema.sql」这条路径不可达（R30-C1 之后）。
   指纹防的是「apply 之后有人改了库」，是并发的手/残留对象这一档。
2. 每一维的缺口都**fail-open 于诊断、fail-closed 于授权**：漏掉一维意味着某种改动不被
   *察觉*，而不是意味着某个未授权的 DROP/凭据被*放行*——授权链（intent/登记/绑实例）
   已由 R16/R21/R35/R36 四处闭合并留有机械守卫。
3. 已留的机械守卫（`pg_sequences` 列覆盖率、`pg_database` 谓词绑实例、守卫表耐久性按表枚举）
   会让**同族的下一处**在 CI 里自己变红，而不是等下一轮评审。

**这条残留的边界**：它**不适用于**建库/闸门的**授权正确性**。
4a-2 及之后若出现「凭据、DROP 授权、归属判定」类 finding，仍须逐条修到底。

**守卫表也要证表级耐久性；DSN2 也要过破坏性闸（O4-R37）**：

*C2*：R35-C1 把 `pg_class` 整行纳入了**业务表**指纹，还写下「按被保护的性质枚举」——
却没回头问一句「**还有哪些表**要同样的保护」。于是 `pilot_meta` / `pilot_stock_source` /
marker / intent / registry 五张表仍可被 `ALTER TABLE … SET UNLOGGED` 掏空：
列、主键、依赖物判据**全部照旧为真**，库照样被标 `ready`，
而 PostgreSQL 崩溃后 unlogged 表会被 **truncate** ——
归属元数据、来源代次基线、以及**授权 DROP DATABASE 的 intent 行**一起消失。
判据：两处形状证明共用一个生成器 `_durable_tables_sql()`，覆盖
`relkind='r'` / `relpersistence='p'` / 未启用未强制 RLS / 非分区子表 /
无 reloptions / 默认表空间。
> ⚠️ **这是「只修被点名的那一处」在本 PR 的第十一次**，而且发生在我**刚写下那条教训的同一轮**。
> 故这次不写纪律写生成器：两处判据共用一份生成代码，「长得不一样」在结构上不可发生。
> 守卫 `test_every_guard_table_shape_proof_covers_table_level_durability` 按
> 「**本工具的安全性依赖哪些表**」枚举，第六张表一出现就变红。
> **刻意排除** `_PILOT_META_SHAPE_SQL`（读的是同侪库的归属自证，本次运行不依赖它的耐久性；
> 在那里要求持久会让一台崩溃过的同侪库把集群闸整个顶死 = R55-F1 锁死的换形态）——
> 这条排除本身也被钉住，免得下一轮当成同族遗漏「顺手补上」而引入锁死。

> ⚠️ **判据重叠，故重叠档断言性质而非 code**：耐久性判据含 RLS 两个标志，
> 而 `_PILOT_TABLE_DEPENDENTS_SQL` 也数 RLS；反过来「部分唯一索引」既让 `*_key_unique` 为假、
> 也让 `extra_indexes` 非零。**两个方向都重叠** —— 实测两种排序各红两档，
> 没有哪种排序能对所有情形都给出更精确的 code。两道都保留（都 fail-closed、都可达），
> 重叠的那几档验收断言改成「拒了、停在阶段 1」。

*C1*：验收脚本对外宣称「破坏性操作有护栏」，而 `DSN2` 从环境变量读出来就直接
`_drop(dsn2, …)` + `CREATE DATABASE` —— **对第二个集群一次都没检查**。
DSN2 指错到共享/远端集群，`kline_pilot_selfcheck_p24` 就在那边被不可逆地删掉。
判据：闸提成 `_assert_destructive_dsn_allowed(dsn, label)`，DSN 与 DSN2 共用；
另加两道机械守卫 ——
（i）`_drop()` 只肯对登记过的 DSN 动手；
（ii）**反向断言**：源码里读了几个 `DSN*` 环境变量，就必须有几个走过闸，
否则在任何连接发生之前 `return 7`。两道各自变异验证过（一道被掐掉时另一道仍然拦住）。

**业务表也要证「没有行为对象」，指纹还要含序列（O4-R34-C1）**：
`_PILOT_TABLE_DEPENDENTS_SQL` 只管两张 pilot 表 —— **同一条判据在业务表上没做**。
往 `public.klines` 上装一个 INSERT 触发器：列/约束/默认值/索引/序列全都不变，
**活目录指纹一个字都不动**，而此后每一次导入都被它改写。
故加 `_BUSINESS_TABLE_BEHAVIOR_SQL`（触发器/规则/RLS/继承边，四类必须为 0）
→ `business_tables_have_dependents`。
> 与 pilot 表那条的**差别**：索引与约束是 `schema.sql` 的合法产物（且已进指纹），
> 故业务表这条只数**行为**类，不数索引/约束 —— 照抄会把合法 schema 误拒。

**序列参数并入指纹**：默认值文本写的是 `nextval('…'::regclass)` ——
`ALTER SEQUENCE training_sets_id_seq INCREMENT BY 7`（或改 start/cycle）时它**一个字都不变**，
而 id 的生成方式坏掉会让此后每一次导入拿到错的主键。指纹补 `pg_sequences` 段
（只取业务表**拥有**的序列，靠 `pg_depend.deptype='a'` 判定）。

**验收脚本的临时对象必须带归属前缀（O4-R34-C2）**：
上一轮（R33-C2）只把**库名**的盲删改成白名单，**同一段清场里按固定名字删 schema/表的那几行漏了** ——
`evil_catalog` / `tmp_probe_data` / `zz_evil` / `evil_user_data` 全是会撞的通名，而清场是**无条件 DROP**。
开发机或 CI 上任何人用了同名对象，就会在没有任何归属校验的情况下被删掉。
→ 全部改为 `zzqmtverify_` 前缀并收进 `_SCRATCH_OBJECTS`；另加源码自检：
临时对象名不带该前缀即 **exit 6**。

> ⚠️ **「只修被点名的那一处」在本 PR 里已第十次**（形状不是归属 ×5、凭据绑实例、
> 不认裸 unique index、零对象判据跨文件、清场库名 vs schema/表、pilot 表 vs 业务表）。
> 每一次的形态都一样：评审点出 A，我修了 A，同族的 B 原地不动。
> 已固化的对策是「改判据先 grep 反模式全仓 + 留机械守卫」——**它减少了但没有消灭这一族**，
> 如实登记。

**活目录指纹必须包含默认值（O4-R33-C1）**：上一版只哈希列/约束/索引。
`ALTER TABLE public.training_sets ALTER COLUMN status SET DEFAULT 'sent'` 或
`… DROP DEFAULT` **不动**列名/类型/可空/约束/索引 —— 指纹完全看不见它。
而运行时的 INSERT 依赖这些默认值：省略 `id` / `status` 的写入会失败，
或**安静地**把行写成错误的状态；库照样被标 ready、intent 行照样被清掉。
→ 指纹补 `pg_attrdef` 段（`列=pg_get_expr(...)`）。
> mutation 实测：把 defaults 段拿掉之后，活目录指纹**正好退回旧值** `236f77b1…` ——
> 这正是那一段贡献的差异，且场景 ① 首次建库即 `business_schema_drift` 中止。

**验收脚本的前置清场不许按前缀盲删（O4-R33-C2）**：上一版枚举
`LIKE 'kline_pilot_selfcheck%'` 之后**先删再说**。本地/共享的 PostgreSQL 上真有人用这个前缀
建了库的话，会在任何标记、登记行、白名单校验之前就被**不可逆地删掉** ——
而 localhost 闸挡不住这一档（它挡的是「别指向远端」，不是「别删本地别人的库」）。
这是**要请人在真机上跑**的破坏性脚本，判据必须是「这是我建的」而不是「名字像我建的」。
→ 精确白名单 `_SCENARIO_DBS`；匹配前缀但不在清单里的 → **打印并中止（exit 4）**，
除非显式 `QMT_VERIFY_FORCE_CLEANUP=1`。
→ 另加**白名单自检**：脚本源码里出现的每个 selfcheck 库名都必须在清单里，否则 exit 5。
> ⚠️ 自检**必须排在破坏性清场之前**：它是纯源码检查、零副作用，放在清场之后会被
> stranger 闸先触发而永远测不到（实测踩过，测试当场给出的是 exit 4 而不是 5）。

**身份/绑定标量必须在任何副作用之前验（O4-R32-C1）**：`export_log_sha256` / `output_dir` /
`created_at` 此前一路裸奔到 `values` 才被用上 —— `output_dir=None` 直到 `CREATE DATABASE` /
确认 / 登记**都做完之后**才在 `.rstrip('/')` 上崩掉；空串或 `"/"` 则被安静地存成一个**空绑定**。
而这三者正是 `confirm_token` 的原像与 `--reset-foreign` 的绑定依据 —— 存进去的是垃圾，
令牌就派生不出来、库也认不回自己。
判据：`export_log_sha256` 为 64 位小写十六进制；`output_dir` 为绝对路径且去尾斜杠后非空；
`created_at` 匹配 ISO-8601 basic UTC 微秒。不合即 `identity_scalar_invalid`，**在写 intent 行之前**。

**规范指纹证明的是「递进来的字节」，不是「库现在长什么样」（O4-R32-C2）**：
apply 之后到写 ready 之间，业务表仍可能被改（并发的手、残留对象、PG 侧异常）——
掉一条 CHECK、换一个列类型，**四个表名照旧齐全**，随后 `schema_sha256` 与 `state='ready'`
被写进去，**元数据声称的 schema 与库里的不是一回事**。
故 apply 之后按**活目录**再算一次指纹（列名/类型/可空 + 约束定义 + 索引定义，共 64 行），
与 `CANONICAL_BUSINESS_CATALOG_SHA256` 比 → `business_schema_drift`。

**三方互钉**（缺任何一边都会退化成自证）：
| 钉住的两端 | 由谁钉 |
|---|---|
| 固件 ↔ 规范常量 | host `test_business_catalog_fixture_matches_the_constant` |
| 规范常量 ↔ 活库 | 真 PG 验收 ㉕ 档（刚建好的规范库指纹必须等于常量）|
| 活库 ↔ 交付 | 建库路径本身（apply 后即校验）|

> ⚠️ **这个常量对 PostgreSQL 大版本敏感**：`pg_get_constraintdef` / `pg_get_indexdef` 的渲染会变。
> 它不是「安全常量」而是**快照**。升级 PG 之后 ㉕ 档会**当场变红并打印实际值** ——
> 那是「请重新生成常量与固件」，不是「schema 漂移了」。这条提示同时写进了运行时报错，
> 免得操作者在生产上对着一个看不懂的 `business_schema_drift` 发呆。

**验收闸不接受「跳过」——exit 0 必须意味着每一档都真的跑过（O4-R31-C1）**：
跨集群那一档原本在缺 `DSN2` 时只打印一行「跳过——不是通过」，而**退出码与结尾摘要照样是绿的**。
**「静默没跑」与「通过了」在最终信号上完全一样** —— 于是「跨集群误路由」这条高代价的
信任边界回归可以毫无验收信号地溜过去。这与本仓反复栽过的
「空转的检查比没有检查更糟：它把『没查出问题』伪装成『没有问题』」是同一族。

两层收口：
1. **`DSN2` 必填**：缺它直接判失败，不再是可选自测。
2. **场景完整性闸**：每一档执行时 `scenario("标记")` 登记，收尾核对 `_EXPECTED_SCENARIOS`
   一个不缺；少一档即失败并打印是哪几档。**新增场景必须同时加进清单** ——
   忘了加，那一档就永远不会被要求执行（这条限制如实写在常量旁）。

> mutation 实测两条 fail-closed 路径：把某一档的登记去掉（模拟静默没跑）→
> `❌ 这些档**没有跑**：['㉓']`；缺 `DSN2` → 两条失败（显式检查 + 完整性闸，双保险）。

**只验表名远远不够——把两份 .sql 钉死到仓库规范指纹（O4-R30-C1）**：
四个表名建成空壳、少列、缺约束，一样过得了「表名齐了吗」，随后被标 ready ——
坏 schema 变成「合格的 pilot 库」，失败与损坏被推到之后的导入/生成路径上，
而复用时还会信任那个假指纹。
修法**不是**把列/类型/NOT NULL/主键/索引/外键再枚举一遍（那是把 `schema.sql` 的契约抄第二遍，
必然漂移，且漏一条就是静默放行），而是要求 `schema_sha256` / `pilot_schema_sha256`
**等于仓库里那两份文件的规范指纹** → 字节相同则一切结构**由构造保证**正确 → `schema_not_canonical`。
- 常量在模块里（库不读文件、不耦合仓库布局），防漂移交给
  `test_canonical_schema_hashes_match_the_repo_files`：改了 .sql 而没更新常量，它当场变红。
- 排在事务归属闸**之后**（那两条讲「这份 SQL 的形状」，先报更具体的原因），
  但仍在**任何副作用之前** —— 连 intent 行都还没写。

> ⚠️ **威胁模型随之改变，验收也必须跟着改**：`schema_sql` 被钉死之后，
> 「敌意 schema.sql」这条路径**不再可达**。⑰/⑱/⑲/⑳/㉑/㉒ 六档原本靠往 SQL 文本里
> 拼敌意语句来触发 post-apply 判据，现在会在进场那一关就被拒 —— **场景根本走不到它要测的地方**。
> 已把注入点从 SQL 文本改到**连接代理** `_PostSchemaSaboteur`：规范 schema 跑完的那一刻
> 往库里执行一段敌意 DDL。这也更贴合这些判据现在要防的真实威胁：
> **「apply 之后、判据之前库被弄坏」**（并发的手、残留对象、PG 侧异常），而不是「输入是坏的」。
> 每一档都加了 `holder["proxy"].fired` 前提断言 —— 注入没触发时不许算通过。
> ⑰b（「错但自洽」）被 ⑫b（进场即拒）完全覆盖，已删。

**同名还不够，连接必须绑到**同一台集群**（O4-R29-C1，真 PG 实测）**：
`adopt_connection` 此前只验 `current_database() == expected_db`。被改错的 DSN 完全可能指向
**另一台 PostgreSQL** 上同名的库 —— 名字对上了，而维护库里的 intent/登记与这条连接
分属两台机器：**「归属证明」与「被证明的对象」根本不在一个信任边界里**。
判据用 `pg_control_system().system_identifier`（由 `initdb` 生成、存在服务端控制文件，
DSN 改写伪造不了；实测两个集群取值不同），维护连接读一次，之后接管的每条连接都要与它相等
→ `connection_wrong_cluster`。

**验收标准不能从被验对象自己推导（O4-R29-C2）**：
「schema.sql 声明的表都在吗」这条判据的期望清单来自 `schema_sql` **自己** —— 是**自证**。
一份错但自洽的 SQL（`BEGIN; CREATE TABLE klines(id int); COMMIT;`）过得了事务包裹闸、
指纹与它自己一致、声明的那张表也确实建出来了 —— 旧判据**全部通过**，库被标 ready，
坏 schema 就此变成「合格的 pilot 库」，失败被推到之后的导入/生成路径上。
故另立一条**外部**判据：不管调用方递进来的是什么 SQL，`REQUIRED_BUSINESS_TABLES`
那几张表必须齐 → `business_tables_missing`。
- 清单是**模块常量**而不是「读仓库文件」：库不耦合仓库布局；
  防漂移交给 `test_required_business_tables_matches_schema_file`（常量必须等于
  `declared_tables(backend/sql/schema.sql)`）—— 业务 schema 增删表而常量没跟着改，它当场变红。
- 两条判据**都要留着**：自证那条管「你说要建的建了没」，外部那条管「该有的有没有」。

> ⚠️ 这条改动一次把真 PG 六档顶红 —— 那些场景传的是玩具业务 schema（只建一张 `klines`），
> 于是在新判据上先失败，**红的原因与被测行为无关**。已加 `_schema_plus(*extra)`：
> 真 `schema.sql` + 敌意语句（插在收尾 `COMMIT;` 之前），场景因此也更贴近现实。
> 教训与 R23 那次一样：**收紧一条前置判据时，先想清楚有多少既有验收是靠「不满足它」才走到目标的。**

**注入的连接必须证明自己连对了库（O4-R28-C1）**：`connect(name)` 返回什么就用什么，
是一条**没被验过的调用方断言** —— 与 R5-C2 把 `seed_lock_held` 布尔换成「在活连接上真验锁」
是同一条原则。DSN 被改写、连接池串号、包装层把名字映射错了，都会让这条连接指向**另一个库**；
随后 `pilot_schema.sql` 与 `schema.sql` 会落到那个库上做 DDL，而刚建好的 pilot 库空着、
却已经登记在案 —— **这台守卫存在的全部意义当场归零**。
> 真 PG mutation 实测：拆掉身份核验后，`pilot_meta` 与 `klines` **两张表都建到了那个无辜的库上**。

修法：把「钉 `search_path`」与「证明 `current_database()` 等于目标名」**合成一个动作**
`adopt_connection(conn, expected_db)`，凡是外部注入的连接（建库的目标库、闸 (ii) 逐个连的同侪库）
一律先接管再用；不符即 `connection_wrong_database`，并立刻关掉这条连接。
- **合成一个动作是有意的**：R24 的教训是「分成两步写，迟早漏掉其中一处」。
- **次序不能反**：先钉 `search_path`，`current_database()` 这个函数名本身才不会被敌意 search_path
  解析到别处。
- R17 那条结构守卫随之升级为：每个 `await connect(...)` 之后必须是 `try:` → `adopt_connection`。

**交付前还要证「内容」与「行为」，不只是结构（O4-R27）**：

- **来源代次基线必须是空的（C1）**：`schema_sql` 可以往 `public.pilot_stock_source` 里
  `INSERT` 几行 —— 形状、主键、依赖物全都干净，库照样被标 ready、intent 行照样被清掉。
  而这张表是 `already_done` / 来源代次判定的**基线**：伪造的行会让此后的重新导入被跳过、
  或与真实来源冲突，**且那时已经没有任何自动恢复凭据**。故 apply 之后断言它恰好 0 行
  → `pilot_source_not_empty`。
- **RLS 与继承也改变读写行为却不碰形状（C2，真 PG 实测）**：
  `ALTER TABLE … ENABLE/FORCE ROW LEVEL SECURITY` 之后 `relrowsecurity` /
  `relforcerowsecurity` 变 `true` 而列/主键判据照旧通过。
  > 实测校正一处措辞：**超级用户会绕过 RLS**（属主仍读得到行），所以危害不是「立刻读不到」，
  > 而是**本工具不保证以超级用户运行** —— 普通角色一旦接手，这张「空的但被 RLS 挡住」的表
  > 会让每次读都看不到该看的行。
  继承边则相反：子表的行会**从父表读出来**，基线凭空多出内容。
  故依赖物白名单补 `pg_policy` / `relrowsecurity|relforcerowsecurity` / `pg_inherits` 三项。

> **分层要如实**：这三项在 host 层是**测不出来的** —— 假件只把喂进去的计数原样回传，
> 去掉 SQL 里的三列，host 一颗都不红（实测 J2：host 0 红、真 PG 4 红）。
> host 测的是「计数非零时代码拒不拒」这半，**SQL 能不能数出来那半只有真 PG 能证**。

**形状对了不等于行为没被改（O4-R26-C1）**：`schema_sql` 是调用方给的 DDL，它可以在 pilot 专用表上
装一个**触发器**或**规则** —— 表结构、列、主键、阶段 1 的七行全都原样通过前面所有证明，
而阶段 2 写进去的 `schema_sha256` / `state='ready'` 会被就地改写；装在 `pilot_stock_source` 上的
则污染此后**每一次**来源代次写入。**改的不是结构，是行为**，这是「一次性证明管不住后续 DDL」
那一族里最隐蔽的一档。

两道**互相独立**的判据（真 PG mutation 实测过分工）：
1. **依赖物白名单**：apply `schema_sql` 之后证明 `public.pilot_meta` / `public.pilot_stock_source`
   上**没有本工具之外的依赖物** —— 用户触发器（`NOT tgisinternal`）、规则、主键之外的索引与约束，
   一律不许有 → `pilot_tables_have_dependents`。
2. **阶段 2 提交后复读九键**：前面所有证明都发生在**写入之前**；「写完再读一遍」是唯一能直接证明
   「库里现在真的是这九个值」的办法，也是**清掉 intent 行（放弃唯一的恢复凭据）之前最后一次能反悔的机会**
   → `final_meta_mismatch`。
> 实测分工：只拆掉①时，②接住了它 —— 但库**已经走到 `state=ready`** 才被拦下，
> 所以①是更早、更该有的那道；①②都拆时，建库**完全成功**，产出一个 `schema_sha256`
> 被触发器改写过的 ready 库。**两道都要有。**

**零对象例外的凭据判据，必须在**每一处**表述里都收紧到位（O4-R25-C1）**：
模块（R21）改了 `db_oid` 绑定、（R23）改了 `inserted_at` 新鲜度，但 **4a-2 的实施指引没跟上** ——
计划 Task 3 的 `_READ_INTENT_SQL` 仍只读名字，孤儿清理那条 SQL 仍按 `created_at` 判过期，
spec 的第 6 条正文与验收段也还是旧写法。照此实现，R21/R23 修掉的绕过会**原样回到 4a-2**。
本轮按判据把 **docs 全目录**扫了一遍，除评审点名的一处外另找到 **4 处**陈旧
（计划里的第二条 SQL、一个测试 fixture、spec 两处正文）。
已加机械检查 **C13**：任何 md 里把 `created_at` 当新鲜度依据的写法一律报错；
且实施计划的零对象谓词必须同时够到 `create_confirmed` / `oid_matches_now` / `inserted_at_epoch`。

> **这一族在本 PR 里已是第八次**（「形状不是归属」五次 → 「凭据绑实例」一次 → 「不认裸 unique index」一次
> → 本次）。前一次我在提交信息里引用了这条教训**并且仍然漏了一处**。
> 结论已固化为纪律：**改判据先 grep 那个反模式全仓（含 docs），把命中数写进提交信息，改完复 grep 归零；
> 然后留一条机械守卫。**

**C11 曾被它该抓的东西静默禁用（同轮自测抓到）**：C11 的枚举正则是 `[a-z_|]{20,}`，**不含数字**。
R22 新增的 `phase1_meta_tampered` 带了个 `1` —— 从那一刻起整条 `db_boundary_error`
就再也匹配不上，**C11 对这个字段静默停摆两轮**，而工具照常打印「一致性检查全过」。
修法：字符类补数字 + **反向断言**（钉住三个一定存在的枚举字段名，少一个即报「匹配式过时」）。
> 这是「机械检查器被它该抓的损坏禁用」在本仓的第四次。**每加一条机械检查，都要配一条
> 「它到底有没有在查」的反向断言** —— 否则失效与通过在输出上完全一样。

**唯一性判据是**六**处不是五处（O4-R24-C1）**：R23 修「不认裸 unique index」时，我在提交里明写
「五处一起改」，实际有**六处**——漏掉的正是**运行时归属读取器** `_PILOT_META_SHAPE_SQL`。
错在枚举方式：按「我正在编辑的那两个 SHAPE_SQL 常量」数，而不是按「模块里所有唯一性判据」数。
**改判据时必须按判据本身穷尽，不是按手头的文件块。**
已加机械守卫：模块的**任何字符串属性**里都不许出现 `indisunique`（读属性而非源文件文本，
故 .py 注释里提到它不会误报），并反向断言主键判据数 ≥ 6，免得它在「一条 SQL 都没有」时空转。
> 这是「同一条修法只落在先被指出的那个对象上」在本 spec 里的**第七次**（前六次见「形状不是归属」
> 五次 + 「凭据要绑实例」一次）。这次的新意在于：**我引用了这条教训、并且仍然漏了一处** ——
> 说明光靠「记得这条教训」不够，得有机械检查。

**连上就立刻进 `finally`，钉桩放在守卫之内（O4-R24-C2）**：
`target = await connect(...)` 之后先 `pin_search_path` 再进 `try` 时，钉桩一旦抛异常/被取消，
函数就带着一条**活着的**会话退出，而目标库此刻刚建好、还没初始化完 ——
之后的 DROP 恢复会撞 `database is being accessed by other users`，
**一个本可自愈的残骸变成人工清理**。闸 (ii) 逐个连同侪库那处是同一个形态
（`except` 分支只负责转换异常，不负责关连接）。
故统一为：**connect → 立刻 try → 在守卫内钉桩 → finally close**。
R17 那条结构守卫也随之改写成表达真正的不变量：`try:` 必须出现在 `pin_search_path` **之前**。

**TTL 只能用库自己的时钟（O4-R23-C1）**：孤儿 intent 行的 24h 上限此前算在 `created_at` 上，
而它是**调用方传进来的**字符串，数据库既不生成也不校验。写一个很远的未来值，这行就永远「新鲜」、
永远抢不走；写一个很远的过去值，一行**活着的** intent 立刻可被别人接管。
而这一行是零对象例外的 DROP 授权 —— **它的有效期不能由调用方说了算**。
故 intent 表加 `inserted_at TIMESTAMPTZ NOT NULL DEFAULT now()`，新鲜度一律看它，抢占时一并刷新；
`created_at` 保留作**展示/绑定**值（它是阶段 1 的授权键之一）。
**4a-2 的零对象例外第 6 条同样改看 `inserted_at`。**
> 这一改顺带干掉了 R18 那段 `to_timestamp(created_at, 'YYYYMMDD"T"HH24MISSUS')` 解析——
> 判据换源之后那条路径不复存在。
> `inserted_at` 的 `DEFAULT now()` 也按表达式文本进闸 (iii) 白名单：把它改成一个很旧的时间，
> 每行新写的 intent 会**立刻过期**、随时可被接管。

**「唯一」一律要求主键约束，不认裸的 unique index（O4-R23-C2，真 PG 实测）**：
`CREATE UNIQUE INDEX ... WHERE false` 满足 `indisunique` + 单列 `indkey`，却**对任何行都不生效**——
实测同一个 `stock_code` 连插两行成功、且表上没有任何主键约束。
partial / invalid / not-ready / 表达式索引都能这样骗过 `indisunique`。
本仓这五处「唯一」（`pilot_cluster_marker.purpose` / `pilot_create_intent.dbname` /
`pilot_database_registry.dbname` / `pilot_meta.key` / `pilot_stock_source.stock_code`）
全是 `PRIMARY KEY` 声明的，故直接要求 `pg_constraint.contype = 'p'` 且是单列主键——
判据比「挑出所有需要排除的索引形态」更短也更严。
> **五处一起改**：R21 的教训是「同一条修法只落在先被指出的那个对象上」。评审只点了
> `pilot_stock_source`，但同族另外四处是一样的洞。

**一次性的钉桩管不住后面还会执行的 SQL（O4-R22-C1，真 PG 实测）**：
事务里的普通 `SET search_path` **提交之后仍留在会话上**（只有 `SET LOCAL` 不留）。
`pilot_schema_sql` 与 `schema_sql` 都是调用方给的 SQL——其中任何一句
`SET search_path = evil, pg_catalog, public` 都会让**其后所有守卫查询**跑在它选定的
名字解析下，R17/R18 堵上的目录遮蔽从「调用方 SQL 的副作用」这个口子原样回来。
故**每一段调用方 SQL 跑完都要重新 `pin_search_path(target)`**，再做任何守卫查询。
> ⚠️ 验收这条时踩了个坑：只在 schema.sql 里改 `search_path` 而不建影子表，
> 解析会落回真目录，去掉重钉桩也没有任何变化 —— 那一版验收是**空的**（mutation 没红）。
> 必须让它真的建出 `zz_evil.pg_class` / `zz_evil.pg_attribute`，钉子才立得住。
> 判据也要写成**次序**而不是次数：「每段调用方 SQL 之后的下一步必须是钉桩」——
> 写死次数会被内部合法调用（`read_pilot_meta_rows` 自己也钉）弄成假红。

**结构没坏不等于内容没被改（O4-R22-C2）**：apply `schema_sql` 之后那道结构证明只验表的形状。
一句 `UPDATE public.pilot_meta SET value='other' WHERE key='seed'` 或
`DELETE FROM public.pilot_meta WHERE key='export_log_sha256'` 完全保持形状合规，
却把**归属与输出绑定**这两组授权键改掉了；随后照常写指纹两键 + `state='ready'`、清掉 intent 行，
产出一个「ready」但归属证明已被篡改的库。
故 apply 之后**逐键逐值复核阶段 1 写进去的那 7 个键**（多一个、少一个、值不同，都算篡改），
不符即 `phase1_meta_tampered`。

**`declared_tables` 必须单独解析 schema 限定（同轮由验收场景撞出来的真 bug）**：
前一版只剥 `public.`，于是 `CREATE TABLE zz_evil.pg_class (...)` 把**schema 名**当成了表名，
守卫随后去找一张 `public.zz_evil` → 假的 `schema_tables_missing` ——
**任何在非 public schema 建表的合法 `schema.sql` 都会被误拒**。
现在：显式 `public.` 或不限定 → 计入；限定到别的 schema → 跳过（存在性核实本就是 `public.` 范围的）。

**确认位也必须绑到数据库实例，不只是名字（O4-R21-C1）**：R16-C2 把 `pilot_database_registry`
绑到了 `db_oid`，**却只改了登记表**。`pilot_create_intent` 的确认位当时按「当前是否存在同名库」判——
原库被删、别人用同名重建之后，陈旧的 `create_confirmed = true` 会被抢占那一步**刷新**到那个
全新的、不是我们建的库上；而这一行正是零对象例外的 DROP 授权，于是一个无关的空库、
或一次 `pg_restore --create` 的中途窗口，会被当成「本次的崩溃残骸」删掉。
修法：intent 表加 `db_oid OID`（`INSERT` 时为 `NULL`——那会儿库还没建；与 `create_confirmed`
在确认那一步一起写入），抢占时 `create_confirmed` 只在
`pg_database.oid = 记下的 db_oid` 时保住，否则归零并把 `db_oid` 一并清掉。
**4a-2 的零对象例外读取方同样要求 oid 相符。**
> 教训：同一条修法只落在了「先被指出的那个对象」上——本 spec 里「形状不是归属」已重演过五次，
> 这次是「凭据要绑实例」重演第二次。**改一处判据时要问：同族的另一处有没有一起改。**

**一次性的结构证明管不住后面还会执行的 DDL（O4-R21-C2）**：
`pilot_meta`/`pilot_stock_source` 的结构证明此前只在 apply `schema_sql` **之前**跑过一次。
而 `schema_sql` 是一份可以干任何事的 DDL——
`BEGIN; CREATE TABLE klines(); DROP TABLE public.pilot_stock_source; COMMIT;`
过得了事务包裹闸、也过得了「schema.sql 声明的业务表都在吗」，随后照常写指纹两键 +
`state='ready'`。产出的库对外宣称 ready、`pilot_schema_sha256` 还记着那份 schema 的指纹，
而**来源代次基线表已经不在了**。
故 apply `schema_sql` 之后、写阶段 2 的键之前**必须再验一次** pilot 专用表的结构，
不合规即 `pilot_schema_invalidated`。

**形状判据必须连 `NOT NULL` 一起钉（O4-R20-C2）**：只数「列名对、类型对」是不够的——
漂移的 `pilot_schema.sql` 把 `sha_1m`/`sha_daily` 的 `NOT NULL` 去掉，或库里本就存在一张
被 `IF NOT EXISTS` 跳过的旧表，都能满足计数判据，随后照常写阶段 2 的键 + `state='ready'`。
`pilot_stock_source` 是**每只股票的来源代次基线**，可空的 hash 等于把正确性从数据库不变量
挪到后续的临时处理上。`pilot_meta.value` 同理。故 `_PILOT_SCHEMA_SHAPE_SQL` 的两处计数
都加 `a.attnotnull`。

**验证脚本里的库名一律走 `quote_ident`（O4-R20-C1）**：前置清场的名字是从 `pg_database`
按 `LIKE` 读回来的、**不是常量**；PostgreSQL 的库名可以含引号/分号，而 `asyncpg.execute`
支持多语句 —— 裸 f-string 拼接能让这个**破坏性**脚本以 DSN（通常是超级用户）多跑一条
`DROP DATABASE`，而 localhost 闸挡不住这一档（共享的本地开发集群同样中招）。
> ⚠️ 曾在此加过一层「名字不合严格正则就跳过」，**已撤掉**：转义已经挡住了注入，这层挡不住
> 任何额外的东西，却制造了一个**不可恢复**的陷阱——上一次崩溃留下的怪名字库会被永远跳过，
> 而它又会让集群闸判「存在无关数据库」，脚本从此再也跑不起来（实测踩到）。
> 现在改为**照常转义删除并额外打印一行**，清场因此可自愈。
> 教训：**多加一道「更安全」的闸，如果它挡的东西已经被别处挡住了，净效果可能只剩下锁死自己。**

**指纹必须由内容算出来，不能信调用方传的（O4-R19-C1）**：
`create_pilot_database` 收下 `schema_sha256` / `pilot_schema_sha256` 却从不核对它们与自己
**实际执行的那两份 SQL** 是否一致。这与 R5-C2 把 `seed_lock_held` 布尔换成「在活连接上真验锁」
是同一条原则——**调用方的断言不是证据**。文件与 hash 配错（读了旧文件、改了文件忘了重算）时，
库会被标成 ready 而 `pilot_meta` 里的指纹**指着另一份 schema**；之后复用闸（闸 1）拿这个假指纹
去比对，判据整条失效。故在**任何副作用之前**（连 intent 行都还没写）逐份自校，不符即
`fingerprint_content_mismatch`。

**「什么表都不建」的 schema 不是合法的 schema.sql（同上）**：
`BEGIN; SELECT 1; COMMIT;` 过得了事务包裹闸、指纹也能自洽，却会产出一个
**「ready 但一张业务表都没有」**的库。故要求 `schema_sql` 至少声明一张表，否则
`schema_declares_no_tables`。

**apply 完 `schema.sql` 之后必须核实它声明的表真的在（同上）**：
与 R13-C2 对 `pilot_schema` 做的是同一件事——**执行过 DDL ≠ 结构就对**。
期望清单**从 `schema_sql` 自身推导**（不硬编码：硬编码的清单会跟着文件漂移），
少一张即 `schema_tables_missing`，且必须在写阶段 2 的键之前失败——否则库已被标 ready。
⚠️ 推导必须走 `_sql_statements` 再匹配，**不能对整份文本裸正则**：注释掉的 `CREATE TABLE`、
字符串／dollar-quoted 块里的同名字都会被算进来，守卫于是要求一张**本就不该存在**的表 ——
一个自己发明出来的假失败。
> 真 PG 验收用的是「建完又在同一事务里删掉」这一形态：指纹自洽、事务包裹合法、DDL 也没报错，
> **只有事后核实结构才拦得住**。

**会话临时 schema 也会遮蔽系统目录，且比 §4 的 `evil` schema 更容易（O4-R18-C1，真 PG 实测）**：
`pg_temp` 在**关系名与类型名**的解析上，未被显式列出时隐式排在 **`pg_catalog` 之前**。
不需要建 schema、不需要额外权限——任何能连上来的会话 `CREATE TEMP TABLE pg_class (...)` 即可。
实测：`search_path = public` 下 `SELECT count(*) FROM pg_class` 变成 **0 行**；
钉成 `SET search_path = public, pg_temp`（显式把它排到**末尾**）后恢复 **425 行**，
不限定的业务 DDL 仍落在 `public`。故钉桩的最终形态是 **`public, pg_temp`**。

**会话临时 schema 不算用户对象（同一轮由验证脚本自己撞出来的真 bug）**：
任何会话在库里建过一次临时表，PostgreSQL 就留下 `pg_temp_N` / `pg_toast_temp_N` 两条
`pg_namespace` 行，oid ≥ 16384 且**会话结束后仍然留着**。不豁免的话，一个 DBA 用 psql
连进维护库随手 `CREATE TEMP TABLE`，闸 (iii) 就**永久不过、工具彻底不可用**。
按名字豁免在这里是安全的：PostgreSQL **保留 `pg_` 前缀**，`CREATE SCHEMA pg_temp_evil`
报 `unacceptable schema name`（实测），用户造不出能混进来的名字。
⚠️ **只豁免 namespace 本身**：临时 schema 里**活着的**表仍在 `pg_class` 里被看见并计入
（实测 `live_temp @ pg_temp_3`）——那确实说明有人在用这个库。

**`created_at` 不能用 `::timestamptz` 隐式转换（O4-R18 附带，真 PG 实测的真 bug）**：
本工具写的是 ISO-8601 **basic** 格式（`20260729T101530123456Z`），PostgreSQL 的隐式转换
认不了它，报 `date/time field value out of range`。此前一直没炸是因为 `OR` **短路**：
同 `run_id` 重入先命中左边，**TTL 这一支从来没被真正求值过** —— 任何一次真正的过期抢占
都会当场抛异常。判据改为 `to_timestamp(created_at, 'YYYYMMDD"T"HH24MISSUS')`，
且必须 `::timestamp AT TIME ZONE 'UTC'` 强制回 UTC
（`to_timestamp` 按**会话时区**解释；实测上海会话下裸解析会偏 8 小时）。
> 教训：一个从未被求值过的分支，与不存在的分支没有区别 —— 它需要一条**真的会走到它**的验收。

**过期抢占不得抹掉恢复凭据（O4-R18-C3，取代 R9-C1 的规则）**：
确认位的去留只看一件事——**它指的那个库现在还在不在**。
R9-C1 的「只有同 `run_id` 才保住」在**过期抢占**这一档会抹掉凭据：上一次建出了库、确认过、
崩在写 `pilot_meta` 之前；过 TTL 后另一次运行（新 `run_id`）来抢占 → 确认位打回 `false` →
紧接着 `CREATE` 撞 `duplicate_database` → 确定性失败清理（`AND NOT create_confirmed`）删掉它 ——
空残骸从此没有任何销毁授权。与 R9-C1 是同一个洞的另一条触发路径。
改判据后：库还在 → 确认仍成立（不论是不是同一次运行建的）→ 保住，残骸清得掉；
库没了 → 那句确认已无所指 → 归零，不给后来同名的库背书。

**所有会抛出的 boundary code 必须进 4c 报告枚举（O4-R18-C2）**：
本模块实际发出 20 个 code，其中 **10 个**（3 个 cluster 类 + 7 个 db 类）不在 4c 的枚举里。
漏登记不是排版问题：真建库失败时 4c 会序列化一个未声明的值、或被收敛进泛化分支，
而这些 code 恰恰是「库可能已经建出来了 / 已经 ready」这类**恢复关键**的诊断。
已加机械检查 **C12**：用 **AST** 取 `Pilot*BoundaryError(...)` 的调用点（不用正则——
调用与第一个参数常常跨行，正则只会抓到恰好同行的那几个，正是「看起来跑了、其实只覆盖一小撮」
的空转形态），与枚举求差集；匹配式一旦失效（类名被改）**明确报错**而不是静默通过。

**词法覆盖面必须照 PostgreSQL 手册 §4.1 逐条枚举（O4-R11-C1）**：`;` 能藏身的环境共九类——
行注释 / 块注释（可嵌套）/ `'…'` / `E'…'`（反斜杠转义）/ `U&'…'` / `B'…'`·`X'…'` /
`$tag$…$tag$` / `"…"`（`""` 转义）/ `U&"…"`。
**dollar-quote 还必须在 token 边界上、且 tag 合法（O4-R12-C1，三条判据均在真 PG 15.12 上实测）**：
PostgreSQL 允许 `$` 出现在无引号标识符里 —— `CREATE TABLE a$x$ (id int)` 建出的表名字面就是 `a$x$`；
反过来 `DO$$ … $$` 在 PG 里是**语法错**（`DO$$` 被整个当标识符）；`$1$abc$1$` 报 unterminated
（`$1` 是位置参数，数字起头的不是 tag），而 `$_a$` / `$标签$` 合法。
不看边界时 `BEGIN; CREATE TABLE a$x$ (); ROLLBACK; …; CREATE TABLE b$x$ (); COMMIT;`
会被吞成 `['BEGIN','CREATE TABLE a ()','COMMIT']` → 判「被包住」放行。
**已知近似（fail-closed，如实登记）**：位置参数 `$N` 后接 `$tag$` 时 PG 会开块而本实现不开；
差异只发生在含位置参数的 SQL 上（schema 文件里不会出现），且方向是更容易判「没被包住」。

此前实现**漏掉引号标识符**，且 docstring 里列的「支持形式」本身就不全 ——
`BEGIN; CREATE TABLE "$x$" (); ROLLBACK; CREATE TABLE naked (); BEGIN; CREATE TABLE "$x$2" (); COMMIT;`
里标识符中的 `$x$` 被当成 dollar-quoted 开头，中间的 ROLLBACK + 裸 DDL + 第二个 BEGIN 被整段吞掉，
只剩「BEGIN / 一条 DDL / COMMIT」的完美形状 → 判「被包住」放行。
**这是同族失败第三次**（注释里的 `$$` → 只看首尾 → 引号标识符），故判据从「想到一个补一个」
改为「对着 PG 词法清单逐条核」，并要求同时有**不得误拒**的正向用例（标识符里的分号 / `""` 转义）。

**识别集合必须含 `ABORT` 与 `PREPARE TRANSACTION`（O4-R10-C2）**：
`ABORT` 是 PostgreSQL 的 `ROLLBACK` 别名、`PREPARE TRANSACTION` 会把事务**交出去**，两者都终止当前事务。
识别集合漏掉它们时 `_transaction_statements` 只数到一对，「恰好一对」的判据就成了 **fail-open**——
实测 `BEGIN; DDL; ABORT; CREATE TABLE naked(); COMMIT;` 曾判「被包住」，而中间那条裸 DDL 在任何事务之外、
前面的 DDL 已被 `ABORT` 丢弃，整份文件毫无原子性可言。`pilot_schema_sql`（**禁止自带事务**那一侧）同样漏。
⚠️ 必须是 `PREPARE TRANSACTION` 而非裸 `PREPARE`——后者是预备语句，与事务无关；
`SAVEPOINT` / `ROLLBACK TO` 是事务**内**动作，不得被新集合误收（否则合法 schema 被误拒）。

**事务收尾必须是精确形式，`AND CHAIN` / `PREPARED` 一律拒（O4-R4-C2）**：

> `COMMIT AND CHAIN` 提交完会**立刻开一个新事务**，于是 schema DDL 已落地、
> 连接上却留着未闭合的事务；阶段 2 随后失败时 `CREATE DATABASE` 与阶段 1 都已产生副作用，
> 留下一个**半初始化**的 pilot 库 —— 而这道守卫本该在任何副作用**之前**拦下。
> 合法收尾仅限 `COMMIT` / `COMMIT WORK` / `COMMIT TRANSACTION` / `END` / `END WORK` /
> `END TRANSACTION`。

**闸 0− 刻意不含什么**（这条分寸是 R49-F2 的直接延续）：`schema_sha256` / `pilot_schema_sha256` /
`contract_version` / `state` / 五项 DDL 断言**全部不在其中**——它们回答的是「这个库还能不能**直接用**」，
而 `--reset` 的全部意义正是「不能直接用了，所以重建」。把它们塞进 DROP 路径会让**陈旧 schema 的库连
reset 都做不了**，而 reset 是它唯一的出路。**闸 0− 回答的是另一个问题：闸 0/0b 从这张表里读出来的
那几个值，是不是唯一确定的。**

**零对象残骸的例外不受影响**（R56-F1）：那种库**根本没有 `pilot_meta`**，故不走闸 0−，
而由六条例外（带 `--reset` + 库名全等 `kline_pilot_<seed>` + 零用户对象 + 集群闸全过 + 已持 ①c 锁）
单独授权。**「没有元数据」与「元数据自相矛盾」是两种情形，前者可由六条例外救回，后者必须交给人。**

> **为什么它必须独立成闸、而不能挂在结构闸下（R80-F1 修正）**：我在 R79-F2 给 `pilot_meta` 补了结构断言，
> **却把它们放进了「闸 2 结构」——而本表明写着闸 2 在 `--reset` 时不跑**。于是最危险的那条路径原封不动：
> 一个 `key` 上没有唯一约束、塞着**两行 `seed`**（或两行 `output_dir`）的库，`--reset` 时闸 0/0b
> 会从它里面读值——**读到哪一行取决于实现**——碰巧对上就 `DROP DATABASE`。**R79-F2 修好了「复用」这一侧，
> 却把「不可逆销毁」这一侧留在原地**，而后者恰恰是这套闸存在的理由。
>
> 判据（补进对象 × 维度矩阵的维度①）：**一条新纪律落在既有闸体系里时，必须对着「闸 × 动作」表逐格问
> 「这个动作会不会跑到它」**——本表左列是闸、右边两列是动作，R79-F2 那次我只看了它写进哪个闸，
> **没看那个闸在哪些动作下会被跳过**。

> **R9-F1**：R7-F1 把绑定闸 (0b) 从「仅复用」扩到「DROP 也要过」时，本段旧文案没跟着改，仍写着「0b/1/2 只在复用时跑，不能阻止 DROP」——与上面 0b 的新规则**直接冲突**。实施者若照旧文案实现，就会退回「只验 `tool`+`seed` 即 DROP」，正是本节要防的共享-DSN 不可逆事故。故本表为唯一权威表述：**归属与绑定是 DROP 前的强制闸；只有指纹与结构是复用专属。**

> **为什么复用必须绑定源快照与输出目录（R5-F1 修正）**：原设计的 `pilot_meta` 只记 `tool`/`seed`/`schema_sha256`/`contract_version` —— **没有一项代表「数据从哪来」**。而 `--staging` 是独立传入的参数，`seed` 也不是源身份。于是这条路径是通的：用 staging A 跑一轮出了 60 只货 → 源变了、另建 staging B（新 manifest，`export_log_sha256` 是新值，R2-F2 的同-staging 闸管不到跨 staging）→ 用**同一个 seed、同一个 `--output`** 再跑 → 归属闸过、指纹闸过 → 断点续跑把 staging A 时代的 `training_sets` 行当 `already_done` 计入成功（而且这一步发生在 `staging_intact` 之前，那道闸也够不着）→ **一份 SUCCESS 报告里混着两个源快照的产物**。
>
> 把 `export_log_sha256` + `output_dir` 焊进 `pilot_meta`，等于宣告「**这个库只服务于这一对 (源快照, 输出目录)**」，挡住绝大多数「同库跨快照」。但它**挡不住 K 线字节变而 `export_log` 不变**的那一档，见下。

**逐股源身份表 `pilot_stock_source`（R6-F1 修正；下文提到的 `already_done` / `staging_intact` / 消费循环均属 4c，见 `2026-07-27-qmt-plan4c-pilot-shipment-design.md`，本文件只定义该表的 DDL 与它进指纹的理由）**：库级绑定还留了一个缝——`export_log.csv` 可以**逐字节不变**而 K 线 CSV 内容已换（QMT 重导出，`rows` / `first_time` / `last_time` 全不变，这正是本 spec 在 R3-F3 里已经论证过的情形）。此时 staging B 与 staging A 的 `export_log_sha256` 相同，快照绑定闸放行，而 `already_done` 分支又排在 `staging_intact` 之前 —— 于是 **A 代数据产出的旧 zip 被计入成功、新股却从 B 代导入**，`artifact_errors` 那关只查 crc32（旧 zip 本身是完好的），最终照样走到 `SUCCESS`。

因此在 pilot 库内再建一张表，把每只**成功导入**的股与它当时用的源字节绑定：

```sql
CREATE TABLE IF NOT EXISTS pilot_stock_source (
  stock_code TEXT PRIMARY KEY,
  sha_1m     TEXT NOT NULL,     -- 导入时该股 1m CSV 的 sha256（取自当时的 manifest）
  sha_daily  TEXT NOT NULL
);
```

- **写入点与校验点属 4c**：见 `2026-07-27-qmt-plan4c-pilot-shipment-design.md`（`import_qmt_stock` 成功后与登记同步写入；`already_done` 分支在计入成功之前比对）。**本文件只负责它的 DDL 与「必须进指纹」这两件事**——它是 `pilot_schema.sql` 的一部分，其 sha256 记为 `pilot_meta.pilot_schema_sha256` 并参与指纹闸（R62-F1 + R63-F1）。

**为什么按股而不是按整个 staging 取指纹**：整 staging 指纹一变就拒绝复用，会把**补拉**本身一起挡死（补拉必然新增文件 → 指纹必变），而断点续跑 + 补拉正是允许复用的全部理由。按股绑定则精确命中真正的问题面：只有「这只股的库内数据与当前源字节不是同一代」才触发处置，新增股与未变股都不受影响。

> **为什么 DROP 也必须过归属闸（R3-F1 修正）**：原设计里 `--reset` 只要 seed 合法就 `DROP DATABASE IF EXISTS`，`pilot_meta` 检查只写在复用路径上。但 `kline_pilot_` 前缀证明的是**名字的形状**，**不是这个库归谁**。维护 DSN 指错了服务器、或不小心复用了别人用过的 seed，就会不可逆地销毁一个不是本工具建的同前缀库。D8b 的初衷是「绝不 DROP 不该 DROP 的库」，光靠名字形状达不到这个目标——**必须连进去问它自己是谁**。
>
> 副作用是「库存在但没有 `pilot_meta`」时 DROP 和复用都被拒，操作者必须手工删。这是**刻意的**：一个名字匹配前缀、**内容来路不明**的库，本工具不该替操作者决定它可以消失。**唯一例外是零用户对象的残骸**（`--reset` + 库名全等本次 seed + 零对象 + 集群闸全过 + 已持按 seed 锁）—— 它里面**没有任何内容**，谈不上「来路不明的数据」，而拒绝它就等于把工具锁死（R56-F1）。


---

## 5. 错误处理（§4 的导出视图）

| 情形 | 处置 |
|---|---|
| 复用库绑定的 `export_log_sha256` / `output_dir` 与本次不符 | **拒绝复用**，提示换 seed 或 `--reset` 重建（R5-F1：防同库跨源快照，把两批产物混进一份报告）。verdict = **`FAIL_DB_BOUNDARY` + `db_boundary_error: "binding_mismatch"`**（R39-F2） |
| 维护集群没有 `pilot_cluster_marker` | **在任何 `CREATE`/`DROP DATABASE`/导入之前拒绝**（R15-F1：名字护栏只保护已存在的库，挡不住「在错的集群上新建再灌几百只股」） |
| 有标记，但**现查** `pg_database` 发现无关数据库 | **拒绝**（R17-F1：标记证明「有人曾声明过」，只有现查才证明「现在仍成立」；集群后来装了真库、或标记被 `pg_dump` 复制到别处，都会让一次性检查失效） |
| 集群里存在名字匹配 `kline_pilot_*`、**连进去没有合法 `pilot_meta`、且该库非空**（有任何用户对象）的库——**本次目标库不在此列**（P1r3-F4：目标库由闸 0−/0/0b 全权负责；不排除它的话，「目标库已存在、非空、无 `pilot_meta`」这一档会先被集群闸拒掉，报「**这台集群不干净**」，而真相是「**你的目标库不是本工具建的**」，且下一步动作「人工删这个库」与报告完全对不上；O1-F6 刚收口的 `not_owned` 映射也永不触发） | **拒绝**（R22-F1：前缀名不是归属证明——共享集群上一个恰好叫 `kline_pilot_xxx` 的无关库，会让整台集群被误判为「干净」。「形状不是归属」在本 spec 的第五次）。**零用户对象的同名库不在此列**：它是崩在 `CREATE` 与写 `pilot_meta` 之间的残骸，**放行集群闸**；能否被清掉另按 §4「空库残骸的 reset 例外」五条判（R56-F1 + R59-F1） |
| 有标记、无别的数据库，但**维护库自身**含【维护库专用表集合】之外的用户表/视图/序列/自定义 schema | **拒绝**（R20-F2：「没有别的数据库」≠「这台集群没在用」——生产对象完全可以就放在默认 `postgres` 库里） |
| `--init-cluster-marker` 但闸 (ii) 或 (iii) 不过（含无关数据库 / 维护库自身有用户对象） | 拒绝初始化——那不是一次性 pilot 专用集群（R15-F1 + R20-F2） |
| **`pilot_meta` 存在但自相矛盾**（`key` 无主键/唯一约束、四个授权键任一缺失或出现重复行、`value` 类型不对）——**`--reset` 与复用两条路径都适用**（闸 0−，R80-F1） | **`FAIL_DB_BOUNDARY` + `db_boundary_error: "pilot_meta_ambiguous"`**、rc=1，**拒绝 DROP、拒绝复用，目标库原样保留**。闸 0− 排在闸 0/0b **之前**：它们要从这张表里读 `tool`/`seed`/`export_log_sha256`/`output_dir`，**键能重复则「读到哪一行」取决于实现**，而 `--reset` 的不可逆销毁正建立在这两道闸上。**零对象残骸不走本闸**（它根本没有 `pilot_meta`，由 R56-F1 六条例外单独授权——「没有元数据」与「元数据自相矛盾」是两回事） |
| `--reset` 但目标库已存在且 `pilot_meta` 缺失/`seed` 不符，**且该库非空**（有任何用户对象） | **拒绝 DROP**，要求人工在 pilot 工具外自行删除（R3-F1：前缀证明名字形状，不证明归属）。**零用户对象的例外见下一行**（R56-F1） |
| `--reset` 且目标库**零用户对象**、库名**全等** `kline_pilot_<本次 seed>`（崩在 `CREATE` 与写 `pilot_meta` 之间的残骸） | **允许直接 `DROP` 并按两阶段重建**，不需要 `pilot_meta`、也不需要 `--reset-foreign`（六条判据见 §4「空库残骸的 reset 例外」，R56-F1）。**不带 `--reset` 时**仍按下方「无 `pilot_meta` → 拒绝复用」处置 |
| `--reset` 且归属通过但绑定（`export_log_sha256`/`output_dir`）不符 | verdict = **`FAIL_DB_BOUNDARY` + `reset_foreign_token_required`**（令牌填错则 `reset_foreign_token_invalid`；R39-F2）。**拒绝 DROP**，打印该库所绑身份（哈希前 12 位 / `output_dir` / `created_at`）**与派生确认令牌**，要求 `--reset-foreign=<令牌>` 逐字相符（R34-F1：裸布尔证明不了操作者看过要销毁的是哪个库）；旧文要求显式 `--reset-foreign`（R7-F1：同 seed 撞名的门槛很低） |
| 同 seed 的另一次 pilot 正在跑（`pg_try_advisory_lock` 返回 `false`） | **拒绝启动，什么都不写**，非零码 + stderr（R52-F1：`.staging.lock` 只串行化**共用同一 staging** 的调用者，而同 seed + 同 output + **不同 staging** 的两个 pilot 会双双冲进 `DROP`/`CREATE`，互相摧毁对方的库）。该锁在**维护库连接**上取、**非阻塞**（`pg_try_advisory_lock`，返回 false 即刻退出、**绝不等待**——等待会让等待之前做过的授权检查过期，R53-F1），**连接断开即释放**，无需人工清理 |
| 目标库是**零用户对象的 `kline_pilot_<本次 seed>` 残骸**（上次崩在 `CREATE` 与写 `pilot_meta` 之间），且本次带 `--reset` | 六条全成立即**直接 `DROP` 并按两阶段重建**，**不需要 `--reset-foreign`**（空库无身份可确认、无数据可丢）；不带 `--reset` 则走复用路径被闸 0 拒绝、提示用 `--reset` 重建（R56-F1） |
| **目标库连得上但读不出 `pilot_meta`**（无 SELECT 权限 / 表被并发 DROP / 连接中途断）| **`FAIL_DB_BOUNDARY` + `db_boundary_error: "target_db_unreadable"`**（O4：与 `not_owned` 必须可区分——前者是「查不出来」、后者是「查出来了不是我的」，操作者动作完全不同：一个查权限/并发，一个删库或换 seed）。**绝不 `try/except: continue`**——那是 fail-open |
| 判定一个库是否可被「零对象例外」直接 DROP | **只认【绝对空】那一组白名单式 SQL**（§4）——`pg_class` **不加 relkind 过滤** + schema/proc/type/extension/largeobject 全空。**绝不能用 `information_schema.tables`，也绝不能枚举 `relkind IN ('r','v','S')`**：真 `postgres:15.12` 实测，一个只含**物化视图**（1000 行真实数据）的库在这两种写法下都返回 0 → 被判成残骸 → **不过闸 0−/0/0b、不要令牌、无提示，直接 `DROP DATABASE`** |
| 断开本进程连接后 `DROP DATABASE` 仍失败（其他会话占用） | **`FAIL_DB_BOUNDARY` + `db_boundary_error: "target_db_in_use"`**、rc=1，打印 `pg_stat_activity` 里的占用者（pid / usename / application_name）。**不得重试成 `WITH (FORCE)` 或 `pg_terminate_backend`**——那会无差别 terminate 别人的会话 |
| 集群闸 (ii) 枚举非系统库时如何判「系统库」 | **`datistemplate = true OR datname = current_database() OR datname = 'kline_pilot_<seed>'`**（第三项 P1r3-F4 补；`--init-cluster-marker` 路径无目标库，只保留前两项），**绝不用名字 glob `template*`**：一个叫 `templates` 的**生产库**会被名字前缀当成系统库跳过 → 三条闸全过 → 在生产集群上建库灌数据（「形状不是归属」第六次）|
| 建库用哪个模板 | **一律 `CREATE DATABASE … TEMPLATE template0`**。实测：`template1` 里有一张表时，默认模板建出的库【绝对空】返回 1 → **本工具自己的残骸不满足【绝对空】** → 集群闸豁免不成立 → **整台集群对所有 seed 锁死**，且 `--reset` 也清不掉 |
| 库名不匹配前缀 / 缺 `--reset` 却要 DROP | `assert_pilot_db_allowed` 在任何 DDL 前 raise |
| 上次崩在 `CREATE DATABASE` 与写 `pilot_meta` 之间，留下一个**零用户对象**的 `kline_pilot_*` 库 | **集群闸放行**（空库不承载任何数据，拒绝它没有安全收益却会把整台集群对所有 seed 锁死）；名字恰为本次 `kline_pilot_<seed>` 的那个可由 `--reset` 清掉重建，其余不获 DROP 授权（R55-F1） |
| 复用库 `pilot_meta.state == "initializing"`（上次没跑完 apply schema） | **一律拒绝复用**（错误码 **`db_state_initializing`**；⚠️ **该档必须在闸 1（指纹）之前求值**，O4-F8：阶段 1 只写 7 个键、`schema_sha256`/`contract_version` 尚未写入，闸 1 会先撞「键缺失」并报 `schema_fingerprint_mismatch` → **`db_state_initializing` 永远产不出来**、恢复指引也从「用 `--reset` 重建」错成「schema 漂移」，P1-F10：此前 §4 与 §5 打架——阶段 1 只写 7 个键，故复用时闸 2 的「九键一个不缺」会先失败并报 `structure_mismatch`，报告消费者无法把「上次没跑完」与「有人手工 ALTER 过」分开。**闸 2 内部须先判 `state` 再判九键**），提示「用 `--reset` 重建」。`--reset` 时归属闸与绑定闸所需的键在阶段 1 已写入，故能被正常清掉（R55-F1） |
| 复用库无 `pilot_meta`（来路不明的库；**含零对象残骸——它同样不可复用**） | 拒绝复用，即便名字匹配 `kline_pilot_` 前缀（R1-F2）。零对象残骸的**唯一**出路是带 `--reset` 走 §4「空库残骸的 reset 例外」 的六条例外（R56-F1）。verdict = **`FAIL_DB_BOUNDARY` + `db_boundary_error: "not_owned"`**；指纹/结构闸不过则分别取 `schema_fingerprint_mismatch` / `structure_mismatch`（R39-F2） |
| 复用库指纹失配（`schema_sha256` / **`pilot_schema_sha256`** / `contract_version` 任一变过，R62-F1） | fail-closed 拒绝，提示 `--reset` 重建（R1-F2） |
| 复用库结构断言不过（OHLC 非 double / 无 `stock_coverage` / `file_path` 非 TEXT / 缺 `content_hash` / 缺 `uq_stock_start` / 缺或改坏 `pilot_stock_source` / **`pilot_meta` 自身不合规**——`key` 非主键、九键有缺、任一键出现重复行、`value` 非 `text`，R79-F2） | fail-closed 拒绝，不静默写入陈旧 schema（R1-F2）。`pilot_meta` 那一档尤其不能漏：**归属闸与绑定闸都从它读值，键能重复则「读到哪一行」取决于实现，而 `--reset` 的破坏性建立在这两道闸上** |

---

## 6. 测试策略

分两层：**L1** host pytest（CI 强制）→ **L2** 真 PostgreSQL 脚本（流程纪律，合并前控制者真跑）。
**L1 全绿只证明纯逻辑与假件契约成立，证明不了链路已通。**

### 6.1 L1 — host pytest（CI 强制）

`assert_pilot_db_allowed` 负向表驱动：空串 / 非前缀（`klinedb`、`postgres`）/ 前缀但含非法字符 /
注入形（`kline_pilot_x; DROP DATABASE y`）/ 合法前缀但缺 `reset` 的破坏性动作。正向：合法前缀 + `reset=True` 放行。

**集群闸**：无 `pilot_cluster_marker` 时断言 `CREATE DATABASE` 与导入**均未被调用**；
`--init-cluster-marker` 面对含无关数据库的集群拒绝初始化；**「标记存在但集群现在含无关数据库」也必须拒绝**
（只在初始化时查一次的实现会在此变红——TOCTOU 回归钉）；**「无别的数据库、但维护库自身含一张用户表」同样必须拒绝**
（只查 `pg_database` 的实现会在此变红——生产对象可以就放在默认 `postgres` 库里）。

**库级五闸**：分别造「无 `pilot_meta`」「`seed` 不符」「绑定不符（复用）」「指纹不符」「结构缺 `pilot_stock_source`」
「`--reset` 绑定不符且未带令牌」「令牌填错」七种 → 各自断言专属 `db_boundary_error` 码 + DROP 从未执行；
**外加正向钉**：归属与绑定都相符、但 `schema_sha256` 已漂移的库带 `--reset` → **必须放行到 DROP + 重建**
（把指纹/结构闸塞进 `--reset` 分支的实现会在此变红——陈旧 schema 的库连 reset 都做不了，而 reset 是它唯一的出路）。

**闸 0− 三档**：`key` 无唯一约束且塞两行 `seed` / 缺 `output_dir` 键 / `value` 为 `varchar(8)`
—— 每种都断言复用被拒且 DROP 从未执行；**带 `--reset` 跑同样被拒、库事后仍在**。

**`state == 'initializing'` 单独成档，两条断言方向相反（P1r3-F3）**：
**复用** → 拒 + `db_state_initializing`（负向）；**`--reset`** → **必须 DROP + 重建成功**（**正向钉**）。
⚠️ 原文把它并进「闸 0− 四档」并要求「带 `--reset` 也被拒、库事后仍在」——**照它写测试就把 R55-F1 的锁死
钉进 CI**（上次崩在 apply schema 中途的库既不能复用也不能 reset）。而 §4 明写闸 0− **刻意不含 `state`**、
`state` 归闸 2，闸表又写明闸 2 在 `--reset` 时**不跑**。
**零对象残骸不走闸 0−**：零用户对象、库名全等 `kline_pilot_<seed>` 的空库 + `--reset` → 按六条例外**正常 DROP 重建**。

**全部新增测试必须 mutation 验证**：中和被测守卫 → 该测必须变红 → 复原。由控制者亲验，不接受 subagent 自证。

### 6.2 L2 — 真 PostgreSQL（流程纪律，非 CI 门）

Docker `postgres:15.12`。**这一层的每一条都只有真 PG 能证伪**——「库到底有没有被创建/删除」「集群里现在有什么」
「同一个 key 能不能插进两行」「advisory lock 的持有与释放语义」，**假件会静默建模错误语义**（已实证的教训）。

- **`verify_pilot_db_lifecycle.py`**：集群闸五档（无标记 / 有标记但有无关库 / 维护库含用户表 /
  含无主 `kline_pilot_other` / 同场景下 `--init-cluster-marker` 也须拒绝）；两阶段建库 + `state` 流转；
  陈旧库四件套 fail-closed（OHLC 仍 `DECIMAL` / `file_path` 为 `VARCHAR` / 缺 `uq_stock_start` / 缺 `content_hash`）；
  归属闸与绑定闸的**破坏性分支**（真验「目标库事后仍然存在」）；`--reset-foreign` 三跑（裸 flag / 错令牌 / 正确令牌）；
  **闸 0− 三库**（`key` 无唯一约束且两行 `seed` / 缺 `output_dir` 键 / `value` 为 `varchar(8)`）+ 反向钉；
  **`state == 'initializing'` 单独一档、两条断言方向相反**（复用→拒 + `db_state_initializing`；
  **`--reset` → 必须 DROP + 重建成功**）——⚠️ O4-F6：写成「闸 0− 四库、`--reset` 也拒」
  就是把 R55-F1 的锁死钉进 L2 门（与 §6.1 已改的三档对齐）。**建库两阶段的崩溃恢复归 `verify_pilot_two_phase_create.py`（下条），本脚本不重复。**
- **`verify_pilot_two_phase_create.py`（4a-1 交付，已存在）**：两阶段建库的**事务边界**四档 ——
  ①正常建库（真 schema 文件）②阶段 1 中途崩须整体回滚 ③`schema.sql` 已提交、补写**第一个**
  指纹键时崩 → 恰 7 键 + `state=initializing`（本节登记的残余窗口）④在**第二个**指纹键上崩 →
  阶段 2 须整体回滚。**④ 是唯一能判别「C1 是否真修好」的一档**：①②③ 在中和掉修复后照样全 PASS
  （实测），故 ④ 的注入点必须从 `PILOT_META_PHASE2_KEYS` **派生**、不得写死。
  与 `verify_pilot_db_lifecycle.py` 的分工：**本脚本只管事务边界与崩溃恢复三档**，
  库生命周期/集群闸/令牌三跑归后者，4a-2 **不要重复实现这四档**。
- **`verify_pilot_concurrency.py`**：同 `--seed`、不同 `--maintenance-dsn` 的两个进程 —— 断言第二个在
  `pg_try_advisory_lock` 处**立刻**失败返回（**须设短超时并断言它没有在等**），且未执行任何 `DROP`/`CREATE`；
  杀掉第一个后第二个能立即取得锁（会话级锁随连接断开自动释放）。

---

## 7. 交付诚实口径

- **CI 绿 ≠ 真数据已流过。** 4a 合并时的正确表述是「护栏建好、用假件与真-PG 脚本验过」。
- **禁述**：「pilot 已完成」「100 股已出货」「真实数据接入完成」—— 4a 只是护栏，**真数据要等 4c 之后的人工验收**。
- 真跑结果无论成败都如实报告；PR body 须写明「当前局限」。

## 8. 已知风险

| 风险 | 说明 | 处置 |
|---|---|---|
| **`pilot_create_intent` 孤儿行的授权窗口** | 崩在「INSERT intent」与 `CREATE DATABASE` 之间会留下一行销毁授权。加 `INTENT_TTL`(24h) 后窗口收窄为「本工具上次崩溃后 24h 内 **且** 同事恰好用了同一个 seed 名」 | **接受为残余**（O4-F2）。不可能完全消除：`CREATE DATABASE` 不能在事务里，intent 与它天然不原子 |
| **跨 seed 并发时 DROP 被顶住** | 一次运行的集群闸 (ii) 会连进另一次运行的目标库（它自己就匹配 `kline_pilot_*`），从而顶住后者的 `DROP DATABASE`（PG `55006`）| **接受为残余**（O4-F9）：fail-closed 报 `target_db_in_use`，重跑即可。**本工具明确不支持并发 pilot** |
| **零对象例外与 DROP 之间不可原子** | 第 3 条（【绝对空】）与 DROP 之间存在空窗，`pg_restore --create` 实测有「库已建、表还没建」的一段 | 缓解：**DROP 前紧贴着重查一次【绝对空】**（已提进例外判据本体与 §9-2g）。残窗不可消除 |


| 风险 | 说明 | 缓解 |
|---|---|---|
| 共享维护 DSN 上同 seed 撞名 | 两套设置可能用同一个 seed | 绑定闸（`export_log_sha256` + `output_dir`）+ `--reset-foreign=<身份派生令牌>` |
| 操作者在生产集群上误跑 | 名字护栏挡不住「新建一个合法前缀的库」 | 集群闸每次运行现查，不信任「曾声明过」 |
| 崩在 `CREATE` 与写 `pilot_meta` 之间 | 留下无身份的空库 | 两阶段建库 + 零对象残骸的五条 reset 例外 |

---

## 9. 验收标准（P/F）

| # | 判据 |
|---|---|
| 1 | `assert_pilot_db_allowed` 对非 `kline_pilot_` 前缀库名 / 缺 `--reset` 的破坏性动作，在**任何 DDL 之前**拒绝；真-PG 验证目标库确实未被创建或删除 |
| 1a | **集群闸（R15-F1 + R17-F1 + R20-F2 + R22-F1）**：**每次运行**都须同时满足 (i) 维护库有 `pilot_cluster_marker`、(ii) **现查**枚举 `pg_database` 每一个非系统库**且非本次目标库**（P1r3-F4）——名字不匹配 `kline_pilot_*` 即拒，**匹配的也要逐个连进去、按闸 0− 的同一组形状判据验**（`key` 有主键/唯一约束 + `tool` **恰好一行**且值相符；P1r3-F5——只写「验 `tool == 'qmt_pilot'`」而不规定怎么读时，`SELECT … LIMIT 1` 无 `ORDER BY` 会让**同一台集群这次判干净、下次判不干净**）（R22-F1：前缀名不是归属证明）、(iii) **现查维护库自身**除【维护库专用表集合】（O4-F1：**是集合不是单表**，判据见 §4）外无任何用户表/视图/序列/自定义 schema；任一不满足 → 在任何 `CREATE`/`DROP DATABASE`/导入之前拒绝（真-PG 须断言目标库确实**未被创建**）。**「标记存在」不可替代「现查干净」**（标记只证明有人曾声明过）；**「没有别的数据库」也不等于「这台集群没在用」**（生产对象可以就放在默认 `postgres` 库里） |
| 1a2 | **【绝对空】是白名单式，且是零对象例外的唯一判据（O1-F1，真 PG 实测）**：`pg_class` **不加 relkind 过滤** + `pg_namespace`/`pg_proc`/`pg_type`/`pg_extension`/`pg_largeobject_metadata` 全空。**黑名单式表述（「无表、无视图、无序列」）与 `information_schema.tables` 一律禁用**——物化视图（`relkind='m'`）会逃过它们。§6.1/§6.2 须各有一档「只含物化视图的同名库 + `--reset` → 必须拒绝且库事后仍在」|
| 1a3 | **DROP 前必须断开本进程对目标库的全部连接，且禁 `WITH (FORCE)`（O1-F2，真 PG 实测）**：集群闸 (ii) 与闸 0−/0/0b 都会连进目标库（它自己就匹配 `kline_pilot_*`），故读一律短连接、DROP 前断言连接数为 0；仍失败 → `target_db_in_use` fail-closed。**建库一律 `TEMPLATE template0`**（O1-F8：`template1` 不干净时本工具自己的残骸不满足【绝对空】→ 整台集群锁死）。**系统库判据用 `datistemplate`，不用名字 glob**（O1-F3）|
| 1a4 | **seed/库名的两条实现级硬性规定（O1-F11）**：正则一律 `re.fullmatch`（`$` 在 `re.match` 下接受尾随换行 → **闸判定的库与 DDL 实际作用的库不是同一个**）；库名一律经 `psycopg.sql.Identifier` 引用，**绝不字符串拼接**。§6.1 负向表须含尾随 `\n`/`\r` 与前导空白两档 |
| 1b | **归属闸（R3-F1；空库例外见 2g/R56-F1）**：`--reset` 对**已存在且非空**的库先连进去验 `pilot_meta.tool` + `pilot_meta.seed`，缺失或不符 → 拒绝 DROP、要求人工删除（**零对象且库名全等本次 seed 的残骸走 §4「空库残骸的 reset 例外」 六条例外，直接 DROP 重建**）；真-PG 验证该库事后仍存在。归属通过而指纹失配时**允许** DROP（闸的分工不可倒置：归属管「能不能碰」，指纹管「能不能直接用」） |
| 1c | **快照绑定闸（R5-F1）**：`pilot_meta` 存 `export_log_sha256` + `output_dir`；复用时二者必须与本次 staging 的 `source_snapshot` 及 `resolve(--output)` 相等，否则拒绝复用。该闸**排在 `already_done` 计数之前**，使「同一个 seed + 同一个 output + 换了 staging → 旧快照的行被计成功」不可发生 |
| 1e | **DROP 也过绑定闸，且旁路须身份绑定（R7-F1 + R34-F1）**：`--reset` 遇「归属通过但 `export_log_sha256`/`output_dir` 不符」→ 拒绝 + 打印所绑身份（哈希前 12 位 / `output_dir` / `created_at`），需 **`--reset-foreign=<身份派生令牌>`** 逐字相符才放行；真-PG 须验证 ①不带该 flag ②**带一个裸 flag 或错误令牌**（模拟陈旧脚本/alias）两种情形下目标库**都仍然存在**。**不采用 nonce 方案**（nonce 会让「换 staging 后 reset 重来」这个 reset 的主要正当用途自锁） |
| 2n | **pilot 专用 DDL 必须进被哈希的 schema 文件（R62-F1）**：`pilot_stock_source` 是唯一挡住「`export_log` 不变而 K 线已换」的守卫，而 `backend/sql/schema.sql` **并没有它**（已核）。新增 `backend/sql/pilot_schema.sql`，其 sha256 记为 `pilot_meta.pilot_schema_sha256` 并**参与指纹闸**；`state='ready'` 必须在两份 schema 都 apply 之后才置。**不塞进 `schema.sql`**（那是 NAS 生产库共用的，pilot 专用表不该进生产库、也不该扰动它的指纹）。否则要么新库 `ready` 了却没有那张表（执行阶段才炸），要么就地建表使它**永远游离在指纹之外** |
| 2g | **空库残骸必须真的能被自己清掉（R56-F1）**：R55-F1 只放宽了集群闸却写明「不获 DROP 授权」，而闸 0/0b 都要读 `pilot_meta`——残骸恰恰没有 → `--reset` **也清不掉**，所谓「能自己恢复」是空话。须写死**六条**例外：带 `--reset` + 库名**全等** `kline_pilot_<seed>` + **零用户对象（【绝对空】）** + 集群闸全过 + 已持 ①c 按 seed 锁 + **维护库 `pilot_create_intent` 有本次库名的行、`seed` 相符且未超 `INTENT_TTL`**（⚠️ 该条已被 O4-R8-C2 / R21-C1 / R23-C1 逐步收紧：还须 `create_confirmed = true`、`db_oid` 与当前 `pg_database.oid` 相等、新鲜度按 `inserted_at` 而非 `created_at` 计）（P1r3-F2 取代 O1-F12 原定的 `COMMENT ON DATABASE`——后者判别力归零且不可原子，见 §4）；**DROP 前须紧贴着重查一次【绝对空】**。→ 直接 `DROP` 重建，**不需要 `--reset-foreign`**。**声称的恢复能力必须逐条验到 DROP 真的能执行为止** |
| 2e | **归属先于 schema，工具不得被自己的护栏锁死（R55-F1）**：`CREATE DATABASE` 之后**第一件事**就是在一个事务里写 `pilot_meta`（含 `state='initializing'`），apply schema 完成后才置 `state='ready'`。配套两条放宽：集群闸**豁免零用户对象的 `kline_pilot_*` 空库**（但不授予 DROP 权）；`state='initializing'` 的库**一律不可复用、但可被 `--reset` 清掉**。否则崩在 `CREATE` 与写标记之间会留下一个**没有身份**的库，集群闸拒绝启动、归属闸拒绝 DROP——**工具再也无法用自己的半成品库开工，也无法自己清掉它** |
| 2c | **按 seed 的集群级互斥（R52-F1 + R53-F1）**：在**维护库**上取 session 级 **`pg_try_advisory_lock`**（**非阻塞**：返回 `false` 即刻退出、绝不等待——任何等待都会让等待之前做过的授权检查过期），**排在步骤 ①c，即所有授权检查之前**，持到最终报告 fsync 之后。`.staging.lock` 只串行化共用同一 staging 的调用者，**挡不住「同 seed + 同 output + 不同 staging」**——那两个 pilot 会双双冲进 `DROP`/`CREATE` 互相摧毁。`B2_GENERATION_LOCK_KEY` 也替代不了它（它在**库内**，要先有库）。须有真-PG 并发回归 |
| 1w | **目标库闸失败有专属 verdict（R39-F2 + R49-F2）**：§4「空库残骸的 reset 例外」 **本次动作适用的那几道闸**（`--reset`：**闸 0−** + 归属 + 绑定 + 令牌；复用：**闸 0−** + 四闸全跑；R80-F1）失败 → **`FAIL_DB_BOUNDARY`（rc=1）+ `db_boundary_error` + `db_bound_identity`**，**不得**塞进 `FAIL_INFRASTRUCTURE`（那是把一次成功的守卫记成环境故障）。**`confirm_token` 只进 stderr、不进报告 JSON**——否则 wrapper 可「读报告取令牌再重跑」，R34-F1 的知情同意退化成两步自动化 |
| 3c | **`pilot_meta` 的授权完整性必须是 DROP 的前置条件，不能挂在复用专属的结构闸下（R80-F1）**：新增**闸 0−**，**排在闸 0/0b 之前、两条路径都跑**——`pilot_meta` 存在、`key` 为 `text` 且有主键/等价唯一约束、`value` 为 `text`、**四个授权键（`tool`/`seed`/`export_log_sha256`/`output_dir`）各恰好一行且可读**；不过 → `FAIL_DB_BOUNDARY` + `pilot_meta_ambiguous`、**拒绝 DROP、库原样保留**。**刻意不含**指纹/`state`/五项 DDL 断言（它们答的是「还能不能直接用」，而 reset 的意义正是「不能用了所以重建」——R49-F2 的分寸必须保住）。**零对象残骸不走本闸**（它没有 `pilot_meta`，由 R56-F1 六条例外授权）。**判据**：一条新纪律落进既有闸体系时，必须对着「闸 × 动作」表**逐格问「这个动作会不会跑到它」**——R79-F2 那次我只看了它写进哪个闸，没看那个闸在哪些动作下会被跳过 |
| 3a | **闭合清单里必须有条目，标题里的「含 X」不算数（R79-F2）**：结构闸自 R64-F3 起标题就写「**含 `pilot_meta`**」并给足了理由，**可清单里一条 `pilot_meta` 断言都没有**。补齐：`key` 为 `text` 且是主键（或等价唯一约束）、`value` 为 `text`、**九个键一个不缺且各恰好一行**、复用另要求 `state == 'ready'`。否则一个 `key` 无主键、能塞两行 `seed` 的库指纹相符即放行，而**归属闸/绑定闸读到哪一行取决于实现**——`--reset` 的破坏性正建立在这张表上 |
| 1g | **结构闸覆盖 `pilot_stock_source`（R12-F2）**：复用时须断言该表存在、`stock_code` 为主键、`sha_1m`/`sha_daily` 为 `TEXT NOT NULL`；缺失或被改坏 → fail-closed 拒绝，且这道判定排在**任何 `already_done` 计数之前**。它是唯一挡住「`export_log` 未变而 K 线已换」的守卫，漏掉它等于退回 R6-F1 那条混代次的老路 |
| 1x | **`target_db_unreadable` 与 `not_owned` 可区分（O4）**：造「连得上但 `pilot_meta` 读不出」（撤 SELECT 权限）与「连得上、表在、`tool` 不是 `qmt_pilot`」两种 → 断言各自取到专属码、**DROP 均未执行**、库事后仍在。把读失败并进 `not_owned` 的实现会在第一档变红——那会让操作者去删一个其实读不出来的库 |
| 2 | 复用闸双层俱全（R1-F2）：无 `pilot_meta` / 指纹失配 / 结构断言**七组**任一不过（清单见 §4，**不在验收表里重复枚举**——重复枚举正是这类漂移的来源，O1-F7 + P1-F9）→ fail-closed 拒绝、零 INSERT。**且四类陈旧库各建一个真 PG 库验过**（`CREATE TABLE IF NOT EXISTS` 对已存在的表不补列/约束，这是本条存在的全部理由） |

---

## 10. 后续（不在本 PR）

- **4b**：SMB 真拉取（见 `2026-07-27-qmt-plan4b-fetch-design.md`）
- **4c**：pilot 编排 + 报告凭据链（见 `2026-07-27-qmt-plan4c-pilot-shipment-design.md`）
- 训练组作废/版本化（P3-D10①）：独立 plan
- L2 并发 scheduler-race 真-PG 用例：零星补

---

## 11. 评审轮次记录

> **本文件已评 4 轮（O1 / P1 / P1r3 / O4）；本轮 O4 共 9 条。**
> 旧 spec `2026-07-26-qmt-plan4-pilot-shipment-design.md` 的 **R1–R97 账本**是本文件的历史前身。
> **O4 之后不再跑 spec 评审轮次**（user 2026-07-29 定案）：四轮 44→41→25→47 未收敛，
> 且约 22/47 是上一轮修改自身引入的损坏或未传播完的改动；剩余的真设计缺口交由实现期的
> **测试**证伪（本轮 4b 的 3 条平台事实就是评审**真跑代码**才发现的，散文推不出来）。

### O4 轮（2026-07-29，Opus 5 对抗性评审）

| 编号 | 级别 | 结论 | 核实 | 处置 |
|---|---|---|---|---|
| O4-F1 | **critical** | 闸 (iii) 的**散文定义**（§4）、§5 与 §9-1a 三处仍写「除 `pilot_cluster_marker` 外绝对空」，与刚修好的 ARRAY 版 SQL 矛盾。`pilot_create_intent` 不是 marker 的依赖对象 → 照散文实现 count=2 → **闸恒假、整个 4a 不可用**。**这是同一个洞在同一节里第三次打开**（P1-F4 → P1r3-F1b → 本条），前两次都只改 SQL 块 | 真 PG 四态实测复现 | 已修：**命名【维护库专用表集合】**一次，四处引用集合、不再点名单表；闸 (i) 形状断言逐表覆盖集合 |
| O4-F2 | high | `pilot_create_intent` 孤儿行**永久授权**销毁同名库；上一轮「无害且自愈」的断言为假；清理谓词「指向不存在的库」**恰在该行变危险时为假**；`--init-cluster-marker` 不持 seed 锁 → 能删掉一次进行中运行的行 | 逐条读判据复核，属实 | 已修：撤回假断言 + 第 6 条加 `INTENT_TTL`(24h) 新鲜度界 + 清理逐行 `pg_try_advisory_lock` 取不到即跳过 |
| O4-F3 | high | §9-2g 仍规定**已被否决**的 `COMMENT ON DATABASE` 为第 6 条，§4 仍命令写那条注释；`pilot_create_intent` 在 §5/§6/§9 出现 **0 次** | grep 确认 | 已修：§4 删写注释命令、§9-2g 换成 intent 行判据；检验器 `RULE_ANCHORS` 摘掉 `COMMENT ON DATABASE`、补 `pilot_create_intent` |
| O4-F4 | high | 权威例外清单写「**当且仅当下列五条**」、序列图列五项 —— 第 6 条**在任何可实施的枚举里都不存在** | grep 确认 | 已修：两处改六条，并把「DROP 前紧贴着重查【绝对空】」提进判据本体 |
| O4-F6 | medium | §6.2 仍写「闸 0− **四库**」而 §6.1 已改三档 —— 照它写 L2 就是**把 R55-F1 的锁死钉进门** | 对读两节，属实 | 已修：§6.2 改三库 + `state='initializing'` 单独一档、两条断言方向相反 |
| O4-F7 | medium | `pilot_create_intent` 无存在性/形状校验；`--init-cluster-marker` 的幂等短路**修不好旧版本初始化的集群**（旧版没有 intent 表 → 第 6 条恒不成立 → 残骸永远清不掉）| 属实 | 已修：闸 (i) 覆盖集合；幂等语义改为「标记合法但 intent 缺失/不符 → 补建再成功」|
| O4-F8 | medium | `state='initializing'` 够不到 `db_state_initializing`：闸 1 在闸 2 之前，而阶段 1 从不写 `schema_sha256`/`contract_version` → 先撞 `schema_fingerprint_mismatch` | 对读闸序，属实 | 已修：该档明写「**必须在闸 1 之前求值**」|
| O4-F5 | low | §11 只有 O1 一轮账本，P1 / P1r3 两轮无任何记录 | grep 确认 | 已修：本表 + 本节抬头的轮次声明 |
| O4-F9 | low | 跨 seed 并发：一次运行的集群闸 (ii) 会连进另一次运行的目标库，从而顶住后者的 `DROP DATABASE` | 属实 | **接受为残余**，如实登记 §8：两次不同 seed 的 pilot 并发时，DROP 可能撞 `55006` 而 fail-closed（`target_db_in_use`），重跑即可；本工具明确不支持并发 pilot |


**历史依据**：本文件的全部结论来自旧 spec `2026-07-26-qmt-plan4-pilot-shipment-design.md` 的
**R1–R97 评审账本（201 条 codex finding + 3 处自查补，全部为真、全部已修，codex 从未 approve）**。
那份账本原样保留，本文件不复制它。

**切分后本文件的评审从 R1 重新计数。**

### O1（Opus 5 对抗性评审，needs-attention，14 finding，全部接受并已修）

**评审通道说明**：codex 配额耗尽（2026-08-02 10:53 才恢复），user 明确指示 spec 阶段的对抗性加固改用 Opus 5。
**这不替代 CLAUDE.md 治理 backstop 要求的 PR 阶段 `codex:adversarial-review` 必需状态检查**——那道门仍要等配额。

| # | 级别 | 结论 | 处置 |
|---|---|---|---|
| O1-F1 | **critical** | 「零用户对象」判据不闭合，**物化视图逃过 `information_schema.tables` 与枚举式 `relkind IN (r,v,S)`** → 一个装着几十 GB 真实数据的 `kline_pilot_*` 库被判成残骸 → 走六条例外 → **不过闸 0−/0/0b、不要令牌、无提示，直接 `DROP DATABASE`** | 判据钉死为一组**白名单式** SQL（`pg_class` 不加 relkind 过滤 + schema/proc/type/extension/largeobject 全空），命名为**【绝对空】**，三处引用同一组 |
| O1-F2 | high | 集群闸 (ii) 与闸 0−/0/0b **都要连进目标库**，而目标库自己就匹配 `kline_pilot_*` → `DROP DATABASE` 必被自己的连接顶住 | 读一律用短连接、DROP 前断言本进程连接数为 0；**明令禁止 `WITH (FORCE)` / `pg_terminate_backend`**；仍失败 → `target_db_in_use` fail-closed |
| O1-F3 | high | 集群闸 (ii) 用名字 glob `template*` 判系统库 → 一个叫 `templates` 的**生产库**被跳过 → 在生产集群上建库灌数据 | 改 `datistemplate = true OR datname = current_database()`；顺带解掉「维护 DSN 必须连 `postgres`」这个隐性约束 |
| O1-F4 | high | 按 seed 的 advisory lock 是零对象例外第 5 条的前提，**却只定义在 4c**；4a 自开连接取同一把键会**自己把自己锁死**（advisory lock 只在同一 session 可重入） | 权威 SQL + 键派生 + 「本模块不得自行取锁、只接受已持锁的连接」逐字写进 4a §4 |
| O1-F5 | medium | 闸 0− 第一条是「`pilot_meta` 表存在」，而残骸恰恰没有 → 照闸表实现会原样重现 R56-F1 的锁死 | 写出显式有向序列（集群闸 → 零对象例外判定 → 0− → 0 → 0b →(1→2)），0− 收窄为「**已存在该表**的库须满足…」 |
| O1-F6 | medium | 「`pilot_meta` 表缺失」映射哪个错误码，§4 与 §5 打架 | 写死：**表不存在 → `not_owned`；表存在但形状/键不合规 → `pilot_meta_ambiguous`** |
| O1-F7 | medium | 闸表仍写「结构（**五项**）」，与同节补出的七组闭合清单冲突 → 只做五项的实现能**通过验收** | 改「七组」，§9 同步 |
| O1-F8 | medium | `pilot_cluster_marker` 是授权「碰这台集群」的凭据，**却没有 DDL、没有唯一约束、没有形状校验** | 进被哈希的 `pilot_schema.sql`、`purpose TEXT PRIMARY KEY`、闸 (i) 先验形状再读值、`--init-cluster-marker` 幂等语义写死 |
| O1-F9 | medium | `confirm_token` 三个输入全在目标库的 `pilot_meta` 里，wrapper 可全自动重算 → R34-F1 声称的「无法预先伪造」**不成立** | 措辞降级为诚实表述：挡陈旧脚本/alias/复制粘贴，**挡不住蓄意 wrapper** |
| O1-F10 | low | 逐库连接失败无定义，`try/except: continue` 即 fail-open | 明写「连不进去 = 无法证明归属 = 拒绝」 |
| O1-F11 | low | 正则 `$` 配 `re.match` 接受尾随换行 → **闸判定的库与 DDL 实际作用的库不是同一个** | `re.fullmatch` + 库名一律 `psycopg.sql.Identifier` |
| O1-F12 | medium | 零对象例外把「此刻为空」当「没有价值」，与 DROP 之间无原子性 → 能删掉正在 `pg_restore --create` 的库 | 追加第 6 条：`COMMENT ON DATABASE` 归属注释（`pg_shdescription`，集群级）；残余窗口如实登记 §8 |
| O1-F13 | medium | 自称「零文件 IO」不实（闸 0b/闸 1/`output_dir` 都碰文件系统），manifest 缺失时闸 0b 行为未定义 | 改准确表述；接口只收已校验标量；**取不到 = fail-closed，绝不跳过闸 0b** |
| O1-F14 | low | `created_at` 标「不参与判定」与它进令牌 preimage 矛盾，preimage 序列化未定义 | 改「不参与放行判定、参与令牌派生」+ preimage 逐字定义 |

**⚠️ 三条关键断言已用真 `postgres:15.12` 实测坐实，不是推理**（2026-07-27）：
- **O1-F1**：只含一个物化视图（1000 行真数据）的库 → `information_schema.tables` = **0**、`relkind IN (r,v,S)` = **0**、
  不加 relkind 过滤 = **1**。**spec 原文那两种写法都会判它「零用户对象」。**
- **O1-F2**：目标库上有 1 条会话时 `DROP DATABASE` → `ERROR: database "…" is being accessed by other users`，**库事后仍在**。
- （4b 的 `source_root_relative` 空串问题同批实测：拼出 `/Volumes/QMT_Export/` → `split('/')` 产生尾部空分量 → 撞「拒绝空分量」。）

**Opus 5 在这份 spec 上挖出 14 条（含 1 critical），而我在切分时判定它「本会话只有 2 条 finding、最接近收敛」。
那个判断是错的**——它基于「codex 在旧 spec 上报的 DB 类 finding 少」，而不是基于这份 spec 自身的风险面。
**「某个子系统被报得少」不等于「它更干净」，也可能只是评审的注意力没落在那里。**

⚠️ **切分动因（诚实记录）**：97 轮未能收敛，**不是因为设计有严重缺口**——最后一条真正的设计缺口是
R86-F1（出货凭据保护闸 ①e），已在 11 轮之前；此后 21 条**全部是一致性缺陷**。根因是单一 spec 长到 3711 行、
17 个 verdict、8 道准入闸、3 个目录 × 5 个维度，**每加一条规则要同步 5–8 处，而每轮都会漏一两处**。
按 R74–R97 共 47 条 finding 的实测分布，**DB 闸只占 2 条**——故 4a 被判定为最接近收敛、可最先 approve 的一份。

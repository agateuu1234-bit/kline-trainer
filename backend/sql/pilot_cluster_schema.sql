-- ⚠️ 所有表一律 schema 限定为 public.*（O4-R4-C1）：不限定时由 search_path 决定
--    建在哪个 schema，而守卫验的是 public.* —— 验一张、用另一张。
-- backend/sql/pilot_cluster_schema.sql
-- QMT Plan 4a：**维护库专用表集合**。apply 到 --maintenance-dsn 指向的那个库。
--
-- ⚠️ 绝不与 backend/sql/pilot_schema.sql 合并（spec §4 P1-F5）：
--   · 合并后 apply 到**维护库**会让它多出 pilot_meta / pilot_stock_source 两张表
--     + 两个 pkey 索引 → 闸 (iii)「维护库自身也是【绝对空】」永久不过 → 工具彻底不可用；
--   · 反过来把 marker 放进 pilot_schema.sql，会让**每个 pilot 库**都多出一张空的
--     pilot_cluster_marker，而闸 2 的七组闭合清单里既没有它、也没定义「遇到未登记的表怎么办」。
--
-- ⚠️ 本文件的表构成【维护库专用表集合】= qmt_pilot_db.MAINTENANCE_TABLES。
--   新增成员时必须同时改：MAINTENANCE_TABLES 常量 / 闸 (iii) 豁免 SQL 的 ARRAY /
--   闸 (i) 的形状断言 / spec §4 集合定义 / spec §5 / spec §9-1a。缺一即闸恒假。

-- 授权「碰这台集群」的凭据。闸 (i) 先验形状再读值。
CREATE TABLE IF NOT EXISTS public.pilot_cluster_marker (purpose TEXT PRIMARY KEY);

-- 零对象例外第 6 条的判据：证明「这个空库是本工具刚刚声明过要建的」。
-- 写在 CREATE DATABASE **之前**，故没有窗口。
-- ⚠️ run_id 是**归属凭据**（O4-C2，codex 判 medium）：没有它时，intent 行只由 dbname 标识，
--    于是「谁写的」无从证明 —— 并发的另一次运行、或一个先前失败留下的孤儿行，都会被
--    零对象例外第 6 条当成「本次运行声明过要建这个库」，从而**授权 DROP 一个不是本次建的库**。
--    收尾的 DELETE 也必须按 run_id 条件删，否则会删掉别人那条。
CREATE TABLE IF NOT EXISTS public.pilot_create_intent (
    dbname     TEXT PRIMARY KEY,
    seed       TEXT NOT NULL,
    created_at TEXT NOT NULL,
    run_id     TEXT NOT NULL,
    -- ⚠️ **持久证明，而不是「尽力清理」**（O4-R8-C2）：intent 行写在 CREATE DATABASE
    --    **之前**，所以它单独存在并不证明「这个库是本次建的」。若建库失败而撤回那一步
    --    又恰好失败（连接抖动/权限），残留的行就会被零对象例外当成「本次的崩溃残骸」，
    --    去 DROP **别人建的**同名空库。
    --    故：只有 CREATE DATABASE **确认成功**之后才置 true；
    --    **零对象例外只认 create_confirmed = true 的行**（4a-2 实施者注意）。
    create_confirmed BOOLEAN NOT NULL DEFAULT false,
    -- ⚠️ 确认位必须绑到**这一个数据库实例**，不只是名字（O4-R21-C1）。
    --    上一版按「当前是否存在同名库」判：原库被删、别人用同名重建之后，
    --    陈旧的 create_confirmed=true 会被抢占那一步**刷新**到那个全新的库上，
    --    而这一行正是零对象例外的 DROP 授权 —— 于是一个无关的空库、或一次
    --    `pg_restore --create` 的中途窗口，会被当成「本次的崩溃残骸」删掉。
    --    与 pilot_database_registry.db_oid 是同一条修法（R16-C2），当时只改了登记表。
    --    INSERT 时为 NULL（那会儿库还没建）；确认那一步与 create_confirmed 一起写入。
    db_oid     OID,
    -- ⚠️ **TTL 只能用库自己的时钟**（O4-R23-C1）。`created_at` 是**调用方传进来的**字符串，
    --    数据库既不生成也不校验它：写一个很远的未来值，这行就永远「新鲜」、永远抢不走；
    --    写一个很远的过去值，一行**活着的** intent 立刻可被别人接管。
    --    而这一行是零对象例外的 DROP 授权 —— 它的有效期不能由调用方说了算。
    --    `created_at` 保留作**展示/绑定**值（它是阶段 1 的授权键之一），
    --    但**新鲜度一律看 `inserted_at`**。抢占时一并刷新。
    inserted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 闸 (ii) 的**外部**归属凭据（O4-R14-C1）。
-- ⚠️ 此前闸 (ii) 判「这个 kline_pilot_* 库是不是本工具建的」只看**那个库自己**的
--    pilot_meta —— 被判对象自证。往任意非空库里塞一份 7 键齐全、seed 与库名相符的
--    pilot_meta，就能让它跳过闸 (ii)，「这台集群除本工具外别无他物」被整个掏空。
--    现在要求**两个独立事实同时成立**：库自己的 pilot_meta 合规（在库内），
--    且这个库名本工具**确实声明过**（在维护库，被判对象改不到）。
--
-- ⚠️ **诚实说明它防不住什么**：持有本工具维护库写权限的对手可以自己往这张表插行。
--    任何集群本地的凭据都防不住这一档 —— 它挡的是①偶然撞形（另一个库碰巧长得像）
--    与②能建库但写不了维护库的对手。别把它当成安全边界的全部。
--
-- 谁写：CREATE DATABASE **之前**，与 intent 行同一步；ON CONFLICT DO NOTHING（可重入）。
-- 谁读：闸 (ii)。
-- 谁清：**本工具从不清它**。它记的是「本工具声明过哪些库名」，删掉会让既有 pilot 库
--       在闸 (ii) 里变成外来物 → 整台集群被挡住（R55-F1 那类锁死）。清除是人工动作。
CREATE TABLE IF NOT EXISTS public.pilot_database_registry (
    dbname     TEXT PRIMARY KEY,
    seed       TEXT NOT NULL,
    run_id     TEXT NOT NULL,
    claimed_at TEXT NOT NULL,
    -- 绑到**这一个数据库实例**，不只是名字（O4-R16-C2）。
    -- 只绑名字时，本工具建过 kline_pilot_x 之后，就算它被删掉、别人用同名重建，
    -- 这一行仍然为那个**全新的、不是我们建的**库背书 —— 对手只要再伪造一份
    -- pilot_meta 就能过闸 (ii)，而他并不需要维护库的写权限。
    -- OID 对手**无法自选**（由 PG 分配），故不需要秘密即可绑定实例。
    -- `--reset` 重建同名库时本工具会把这一行**改写**成新实例的 OID
    -- （否则自己刚建的库会被自己的闸判成外来物）。
    -- 已知残余：OID 是 32 位、理论上会回绕重用；需要 2^32 次 OID 分配才可能撞上，
    -- 如实登记，不做处理。
    db_oid     OID NOT NULL
);

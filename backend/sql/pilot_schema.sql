-- ⚠️ 所有表一律 schema 限定为 public.*（O4-R4-C1）：不限定时由 search_path 决定
--    建在哪个 schema，而守卫验的是 public.* —— 验一张、用另一张。
-- backend/sql/pilot_schema.sql
-- QMT Plan 4a：**pilot 库专用**表。apply 到 kline_pilot_<seed>。
--
-- ⚠️ 绝不放进 backend/sql/pilot_cluster_schema.sql，也绝不把 pilot_cluster_marker
--    放进本文件（spec §4 P1-F5，理由见那个文件的头注）。
-- ⚠️ 本文件的**字节** sha256 进 pilot_meta.pilot_schema_sha256 与指纹闸（spec R62-F1）。
--    改本文件一个字节 → 所有既有 pilot 库复用时被指纹闸拒绝，这是预期行为。
-- ⚠️ 绝不手写一段 DDL 现建这两张表（spec R64-F3 对 pilot_meta 的明令）。

-- 承载归属（tool + seed）与绑定（export_log_sha256 + output_dir）。
-- key 上的主键是安全关键：没有它就能塞进两行 seed，而归属闸/绑定闸随后读到哪一行
-- **取决于实现**——而 --reset 的破坏性正建立在这张表上（spec R79-F2）。
CREATE TABLE IF NOT EXISTS public.pilot_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- 唯一能挡住「export_log 逐字节未变而 K 线内容已换」那一档的守卫（spec R6-F1 + R12-F2）。
-- 缺了它，already_done 分支就没有比对基准。
CREATE TABLE IF NOT EXISTS public.pilot_stock_source (
    stock_code TEXT PRIMARY KEY,
    sha_1m     TEXT NOT NULL,
    sha_daily  TEXT NOT NULL
);

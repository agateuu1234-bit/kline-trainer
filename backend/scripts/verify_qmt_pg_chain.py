#!/usr/bin/env python3
"""验证 QMT Plan 3 的 B1→B2 真实写入器链路：真 PostgreSQL 上跑**真**
`build_stock_import` + **真** `write_qmt_stock` + **真** `generate_one_training_set` +
**真** `write_to_postgres`（spec `2026-07-23-qmt-plan3-b1-ingest-coverage-design.md`
§5.4，L2 脚本）。

背景：`backend/tests/test_qmt_e2e_generation.py`（L1，进 CI）用假 conn 当存储——
证明不了 `write_qmt_stock` 的真 SQL / asyncpg 参数绑定 / JSONB 编解码 / 事务行为
一行都没跑过。本脚本用真 Docker PostgreSQL 跑一遍完整链路（`feedback_verify_
foundational_infra_assumption_real_not_fake` 的坑：假件测的是"我们确实按预期
调用了这些"，不是 PostgreSQL/asyncpg 真的按预期行为）。

**这不是 CI 自动门**（spec §5.4 F2 收口，user 2026-07-23 裁决）：不进 pytest ——
CI 禁 skip、且需要真 Docker，pytest 套件里放不了会挂起/不可用的依赖。**合并前
由控制者本人真跑一次，完整输出贴进 PR body**。CI 绿 ≠ 链路已证；「B1→B2 通了」
的证据 = 「L1 CI 绿 且 本脚本的真跑输出」。

**时序严格按生产真实时序排**（spec §5.4 codex R6-F1 教训：P3-D10 重导入互锁一旦
库里有 training_sets 行就会在 DELETE 之前抛 ReimportBlockedError——若把"生成"排
在"重导入证替换"之前，替换路径永远到不了）。正确时序：

  ① 真 build_stock_import(fixture A) → 真 write_qmt_stock        首次导入（尚无训练组）
  ② 真 build_stock_import(窗口前滑的 fixture B) → 真 write_qmt_stock  仍无训练组，互锁放行
       断言：DELETE+INSERT 替换生效——旧窗口独有的 3m 行从库里消失
  ③ 真 generate_one_training_set(真 conn, ...)                    真 RR 事务 / 真两把锁
       断言：磁盘真出现 zip、training_sets 真有登记行、content_hash 三方一致
       断言：stock_coverage 行内容 == 最后一次 build_stock_import(bundle B) 的 CoverageArtifact
  ④ 真 write_qmt_stock(同一只股)                                  此刻已有训练组
       断言：真抛 ReimportBlockedError、klines/coverage/training_sets 零变化
  ⑤ 真 write_to_postgres(同一只股，通用 CSV 路径)
       断言：真抛 LegacyImportBlockedError、库里零变化

用法（user 真终端，需真 Docker PostgreSQL；与 `verify_advisory_lock_reentrancy.py`
同形态，从仓库根用 repo-root `.venv` 跑）：

  cd "/Users/maziming/Coding/Prj_Kline trainer"
  docker run --rm -d -p 5435:5432 -e POSTGRES_PASSWORD=postgres postgres:15.12
  DSN='postgresql://postgres:postgres@localhost:5435/postgres' \
    .venv/bin/python backend/scripts/verify_qmt_pg_chain.py

脚本内部把 `backend/` 目录插入 `sys.path`（与 `backend/tests/` 下测试文件同样
用裸 `from qmt_ingest import ...` 的 import 方式——pytest 靠 rootdir 插入同一
目录，这里手动补上，故本脚本本身不需要 `cd backend` 也能跑）。

退出码 0 = 五步全部成立。非 0 = 有断言不成立，B1→B2 真链路有问题——按脚本要求，
这就是 L2 存在的意义，必须停下如实报告，不能因为 L1 CI 绿就当链路已证。
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import random
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

# backend/ 目录本身要在 sys.path 上，才能 `from qmt_ingest import ...` /
# `from tests._qmt_fixtures import ...`（与 backend/tests/ 下测试文件的隐式
# import 方式一致）。脚本位于 backend/scripts/，故 backend/ = 上一级目录。
_BACKEND_DIR = Path(__file__).resolve().parent.parent
if str(_BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(_BACKEND_DIR))

TEST_CODE = "999001.SZ"          # 独立前缀 + 合法格式（数字+.SZ），不与真实股票碰撞
TEST_NAME = "L2链路验证股"
SCHEMA_SQL_PATH = _BACKEND_DIR / "sql" / "schema.sql"


async def _cleanup(conn) -> None:
    """删本脚本可能留下的残留行（幂等重跑）。zip 产物用 tempfile.TemporaryDirectory
    托管，随 `with` 块退出自动清空，不需要在这里额外处理磁盘文件。"""
    await conn.execute("DELETE FROM training_sets WHERE stock_code=$1", TEST_CODE)
    await conn.execute("DELETE FROM klines WHERE stock_code=$1", TEST_CODE)
    await conn.execute("DELETE FROM stock_coverage WHERE stock_code=$1", TEST_CODE)
    await conn.execute("DELETE FROM stocks WHERE code=$1", TEST_CODE)


async def _snapshot(conn) -> tuple:
    """(klines 总行数, training_sets 总行数, stock_coverage 行内容) ——用于断言④⑤
    的「拒绝后零变化」：拒绝前后各拍一张快照，逐值比对。"""
    kl = await conn.fetchval("SELECT COUNT(*) FROM klines WHERE stock_code=$1", TEST_CODE)
    ts = await conn.fetchval("SELECT COUNT(*) FROM training_sets WHERE stock_code=$1", TEST_CODE)
    cov = await conn.fetchrow(
        "SELECT dense_1m_start_date, dense_1m_end_date, dropped_1m_dates, dense_day_count "
        "FROM stock_coverage WHERE stock_code=$1", TEST_CODE)
    return (kl, ts, tuple(cov) if cov is not None else None)


async def main() -> int:
    dsn = os.environ.get("DSN")
    if not dsn:
        print("ERROR: 需要环境变量 DSN，例如 "
              "DSN='postgresql://postgres:postgres@localhost:5432/postgres'",
              file=sys.stderr)
        return 2

    # 隔离护栏：本脚本会 DELETE/建表，只允许对本地隔离测试库跑，防止误指向
    # 共享/prod 库时真的把数据删了（先于任何 connect/schema/DELETE 检查）。
    host = urlparse(dsn).hostname
    if host not in ("localhost", "127.0.0.1", "::1") and os.environ.get(
            "QMT_VERIFY_ALLOW_DESTRUCTIVE") != "1":
        print(f"拒绝运行：DSN 指向非本地库 {host}，本脚本会 DELETE/建表。仅对隔离测试库运行；"
              "确需对非本地库运行请设 QMT_VERIFY_ALLOW_DESTRUCTIVE=1", file=sys.stderr)
        return 3

    try:
        import asyncpg
    except ImportError:
        print("ERROR: .venv 未装 asyncpg。先跑："
              "  .venv/bin/python -m pip install asyncpg", file=sys.stderr)
        return 3

    # 生产代码 import 放在 asyncpg 可用性检查之后——它们内部也局部 import asyncpg，
    # 提前失败时给出的错误信息更明确。
    from generate_training_sets import PERIODS, crc32_hex, generate_one_training_set
    from import_csv import (LegacyImportBlockedError, ReimportBlockedError,
                            write_qmt_stock, write_to_postgres)
    from qmt_ingest import build_stock_import
    from tests._qmt_fixtures import gen_valid_sources

    failures: list[str] = []

    # ---- 建 schema（若目标库尚无）+ 清理上一次可能失败退出留下的残留 ----
    setup_conn = await asyncpg.connect(dsn)
    try:
        await setup_conn.execute(SCHEMA_SQL_PATH.read_text(encoding="utf-8"))
        await _cleanup(setup_conn)
    finally:
        await setup_conn.close()

    verify_conn = await asyncpg.connect(dsn)
    try:
        with tempfile.TemporaryDirectory(prefix="verify_qmt_pg_chain_") as _tmp:
            out_dir = Path(_tmp)

            # ==============================================================
            # ① 首次导入：真 build_stock_import → 真 write_qmt_stock
            # ==============================================================
            s1a, sda, e1a, eda = gen_valid_sources(TEST_CODE, n_years_daily=4, n_days_1m=250)
            bundle_a = build_stock_import(s1a, sda, stock_code=TEST_CODE, stock_name=TEST_NAME,
                                          entry_1m=e1a, entry_daily=eda)
            await write_qmt_stock(dsn, TEST_CODE, TEST_NAME, bundle_a)

            for per in PERIODS:
                n = await verify_conn.fetchval(
                    "SELECT COUNT(*) FROM klines WHERE stock_code=$1 AND period=$2",
                    TEST_CODE, per)
                expected = len(bundle_a.records[per])
                if n == expected:
                    print(f"OK  [①] period={per} klines 行数={n}（与 bundle A 一致）")
                else:
                    failures.append(
                        f"[①] period={per} klines 行数={n}，期望 {expected}（bundle A）")

            cov_row_a = await verify_conn.fetchrow(
                "SELECT dense_day_count FROM stock_coverage WHERE stock_code=$1", TEST_CODE)
            if cov_row_a is not None:
                print(f"OK  [①] stock_coverage 行已写入（dense_day_count={cov_row_a['dense_day_count']}）")
            else:
                failures.append("[①] stock_coverage 无该股行")

            # ==============================================================
            # ② 窗口前滑重导入（此刻仍无训练组，互锁放行）→ 断言替换语义
            # ==============================================================
            s1b, sdb, e1b, edb = gen_valid_sources(TEST_CODE, n_years_daily=4, n_days_1m=200)
            bundle_b = build_stock_import(s1b, sdb, stock_code=TEST_CODE, stock_name=TEST_NAME,
                                          entry_1m=e1b, entry_daily=edb)

            # 不硬编码具体日期（feedback_plan_embedded_facts_unreliable 的坑）——
            # 直接从两个真 bundle 的 3m 记录求差集，运行时动态取一个 A 独有的 datetime。
            a_3m_dts = {r["datetime"] for r in bundle_a.records["3m"]}
            b_3m_dts = {r["datetime"] for r in bundle_b.records["3m"]}
            stale_dts = sorted(a_3m_dts - b_3m_dts)
            if not stale_dts:
                print("ERROR: bundle A/B 的 3m 窗口没有差集——fixture 校准失败（脚本本身"
                      "的问题，非生产代码 bug），无法验证替换语义，中止", file=sys.stderr)
                return 4
            stale_dt = stale_dts[0]

            await write_qmt_stock(dsn, TEST_CODE, TEST_NAME, bundle_b)

            gone = await verify_conn.fetchval(
                "SELECT COUNT(*) FROM klines WHERE stock_code=$1 AND period='3m' AND datetime=$2",
                TEST_CODE, stale_dt)
            if gone == 0:
                print(f"OK  [②] 旧窗口独有的 3m datetime={stale_dt} 重导入后已从库里消失"
                      "（P3-D4 替换 DELETE 真生效，非 UPSERT 叠加）")
            else:
                failures.append(
                    f"[②] 旧窗口独有的 3m datetime={stale_dt} 重导入后仍存在（{gone} 行）"
                    "——DELETE 未生效，退化成了 UPSERT 叠加")

            for per in PERIODS:
                n = await verify_conn.fetchval(
                    "SELECT COUNT(*) FROM klines WHERE stock_code=$1 AND period=$2",
                    TEST_CODE, per)
                expected = len(bundle_b.records[per])
                if n == expected:
                    print(f"OK  [②] period={per} 重导入后 klines 行数={n}（== bundle B，整体替换）")
                else:
                    failures.append(
                        f"[②] period={per} 重导入后行数={n}，期望 {expected}（bundle B，整体替换）")

            # ==============================================================
            # ③ 生成训练组：真 generate_one_training_set（真 RR 事务 / 真两把锁）
            # ==============================================================
            gen_conn = await asyncpg.connect(dsn)
            try:
                gts = await generate_one_training_set(gen_conn, TEST_CODE, out_dir,
                                                       rng=random.Random(42))
            finally:
                await gen_conn.close()

            if gts.path.exists():
                print(f"OK  [③] 磁盘真出现 zip：{gts.path}")
            else:
                failures.append(f"[③] 磁盘未出现 zip：{gts.path}")

            ts_row = await verify_conn.fetchrow(
                "SELECT content_hash FROM training_sets "
                "WHERE stock_code=$1 AND start_datetime=$2", TEST_CODE, gts.start_datetime)
            if ts_row is not None:
                print(f"OK  [③] training_sets 已登记行（start_datetime={gts.start_datetime}）")
            else:
                failures.append("[③] training_sets 无登记行")

            disk_hash = crc32_hex(gts.path.read_bytes()) if gts.path.exists() else None
            registered_hash = ts_row["content_hash"] if ts_row is not None else None
            if disk_hash is not None and disk_hash == registered_hash == gts.content_hash:
                print(f"OK  [③] content_hash 三方一致（磁盘={disk_hash} == 登记={registered_hash} "
                      f"== 返回值={gts.content_hash}）")
            else:
                failures.append(
                    f"[③] content_hash 不一致：磁盘={disk_hash} 登记={registered_hash} "
                    f"返回值={gts.content_hash}")

            cov_row_b = await verify_conn.fetchrow(
                "SELECT dense_1m_start_date, dense_1m_end_date, dropped_1m_dates, dense_day_count "
                "FROM stock_coverage WHERE stock_code=$1", TEST_CODE)
            dropped_parsed: set = set()
            if cov_row_b is not None and cov_row_b["dropped_1m_dates"]:
                raw = cov_row_b["dropped_1m_dates"]
                parsed = json.loads(raw) if isinstance(raw, str) else raw
                dropped_parsed = {_dt.date.fromisoformat(s) for s in parsed}
            cov_matches = (
                cov_row_b is not None
                and cov_row_b["dense_1m_start_date"] == bundle_b.coverage.start_date
                and cov_row_b["dense_1m_end_date"] == bundle_b.coverage.end_date
                and cov_row_b["dense_day_count"] == bundle_b.coverage.dense_day_count
                and dropped_parsed == set(bundle_b.coverage.dropped_dates)
            )
            if cov_matches:
                print("OK  [③] stock_coverage 行内容 == 最后一次 build_stock_import(bundle B) "
                      "的 CoverageArtifact")
            else:
                failures.append(
                    f"[③] stock_coverage 行与 bundle B 的 CoverageArtifact 不一致："
                    f"DB={cov_row_b!r} bundle={bundle_b.coverage!r}")

            # ==============================================================
            # ④ 已生成后重导入 —— P3-D10 互锁必须拦下
            # ==============================================================
            before4 = await _snapshot(verify_conn)
            try:
                await write_qmt_stock(dsn, TEST_CODE, TEST_NAME, bundle_a)
                failures.append("[④] write_qmt_stock 在已有训练组时未抛 ReimportBlockedError")
            except ReimportBlockedError:
                print("OK  [④] 已有训练组时重导入真抛 ReimportBlockedError")
            except Exception as exc:  # noqa: BLE001 —— 记录任何非预期异常类型，不吞
                failures.append(f"[④] 抛出了非预期异常类型：{type(exc).__name__}: {exc}")
            after4 = await _snapshot(verify_conn)
            if before4 == after4:
                print("OK  [④] 互锁拒绝后 klines/coverage/training_sets 零变化")
            else:
                failures.append(f"[④] 互锁拒绝后数据变化了：before={before4} after={after4}")

            # ==============================================================
            # ⑤ 通用 CSV 路径护栏 —— P3-D11 对已被 QMT 管理的股必须拒绝
            # ==============================================================
            before5 = await _snapshot(verify_conn)
            legacy_records = bundle_a.records["daily"][:5]
            try:
                await write_to_postgres(dsn, TEST_CODE, TEST_NAME, legacy_records)
                failures.append(
                    "[⑤] write_to_postgres 对已被 QMT 管理的股未抛 LegacyImportBlockedError")
            except LegacyImportBlockedError:
                print("OK  [⑤] 通用 CSV 路径对已被 QMT 管理的股真抛 LegacyImportBlockedError")
            except Exception as exc:  # noqa: BLE001
                failures.append(f"[⑤] 抛出了非预期异常类型：{type(exc).__name__}: {exc}")
            after5 = await _snapshot(verify_conn)
            if before5 == after5:
                print("OK  [⑤] 护栏拒绝后 klines/coverage/training_sets 零变化")
            else:
                failures.append(f"[⑤] 护栏拒绝后数据变化了：before={before5} after={after5}")
    finally:
        await _cleanup(verify_conn)
        await verify_conn.close()

    print("-" * 60)
    if failures:
        print(f"FAIL: {len(failures)} 条断言不成立——B1→B2 真 PG 链路有问题：")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("PASS: 真 PG 全链路（导入①→替换②→生成③→互锁④→通用路径护栏⑤）五步全部成立。")
    return 0


if __name__ == "__main__":
    import asyncio
    sys.exit(asyncio.run(main()))

# PR B2 验收清单（中文非程序员可执行）

> Wave 1 顺位 17 / 交付序第 19 个 PR。spec `kline_trainer_modules_v1.4.md` §四 B2 + `kline_trainer_plan_v1.5.md` §8.3。
> plan `docs/superpowers/plans/2026-05-29-pr-b2-generate-training-sets.md`。

## §A 文件存在

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| A.1 | `ls backend/generate_training_sets.py` | 存在 | 文件在 |
| A.2 | `ls backend/tests/test_generate_training_sets.py` | 存在 | 文件在 |
| A.3 | `test -f scripts/acceptance/plan_b2_generate_training_sets.sh && echo OK` | OK | 输出 OK |

## §B 纯层 pytest 全绿（本地，无需 DB）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| B.1 | `cd backend && python3 -m pytest tests/test_generate_training_sets.py -q` | `N passed`（N≥19），0 failed | exit=0 + 末行无 failed |

## §C 模块可导入 + CLI/PG 壳符号存在

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| C.1 | `cd backend && python3 -c "import generate_training_sets as m; print('main' in dir(m), 'generate_one_training_set' in dir(m), 'generate_batch' in dir(m), 'backfill_content_hash' in dir(m))"` | `True True True True` | 命中 |

## §D 算法落地（D2-D6 grep 锚）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| D.1 | `grep -nc 'rng.randint(30, n - 9)' backend/generate_training_sets.py` | 1 (D5 起始范围) | =1 |
| D.2 | `grep -Fnc "[:8]" backend/generate_training_sets.py` | ≥1 (D6 8 根月 K 窗口) | ≥1 |
| D.3 | `grep -nc 'bisect_right(three_dts, upper) - 1' backend/generate_training_sets.py` | 1 (D4 end_global_index 二分) | =1 |
| D.4 | `grep -nc 'MIN_PERIOD = "3m"' backend/generate_training_sets.py` | 1 (D2 最小周期 3m) | =1 |

## §E content_hash CRC32 口径（D3）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| E.1 | `grep -Fnc "format(zlib.crc32(data) & 0xFFFFFFFF, \"08x\")" backend/generate_training_sets.py` | 1 (modules L750 字面 8 字符小写) | =1 |
| E.2 | `grep -nc 'crc32_hex(zip_path.read_bytes())' backend/generate_training_sets.py` | 1 (算整个 zip 文件字节) | =1 |

## §F SQLite schema 语义（D8）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| F.1 | `grep -nc 'PRAGMA user_version = 1' backend/generate_training_sets.py` | 1 (schema_version) | =1 |
| F.2 | `grep -nc 'end_global_index INTEGER NOT NULL' backend/generate_training_sets.py` | 1 (逐字 schema) | =1 |

## §G 双层边界：纯层不顶层依赖 asyncpg（D1/D13）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| G.1 | `grep -ncE '^import asyncpg$' backend/generate_training_sets.py` | 0 (asyncpg 只在 _amain 内 import) | =0 |
| G.2 | `grep -nc 'import asyncpg' backend/generate_training_sets.py` | 1 (壳内局部 import) | =1 |

## §H H6-part2 deps 未回退（D12）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| H.1 | `if grep -qE '(>=\|<\|~=)' backend/requirements.txt backend/requirements-dev.txt; then echo "有range(FAIL)"; else echo "全pin(PASS)"; fi` | `全pin(PASS)` | 输出 `全pin(PASS)` |

## §I 不碰 schema + .github/workflows（D13 / 只读 schema）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| I.1 | `git diff --name-only origin/main...HEAD -- backend/sql/ .github/` | 空 | 无输出 |

## §J 机检脚本自身

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| J.1 | `bash scripts/acceptance/plan_b2_generate_training_sets.sh 2>&1 \| tail -2` | `✅ 所有 8 项 G1-G8 验收通过` | 末行 ✅ + exit 0 |

## §K Residuals

- **B2-R1**：backend pytest 未接 CI（沿用 B1 user 2026-05-29 "纯 opus，CI 延后"）。`test_generate_training_sets.py` 仅本地 + 本脚本跑；接 path-gated CI workflow = trust-boundary，作独立 codex 治理 PR 后续补（= B1-R1）。
- **B2-R2（= ledger H7）**：3-5 个**真实生产**样本训练组数据 + ledger 回填需 NAS PostgreSQL + 真实股票数据（本会话无此环境，user 2026-05-29 选项 1）。本 PR 交付生成器 + 合成数据端到端 host 测试（证明正确性）；真实样本待 NAS 环境补。
- **B2-R3**：modules L753 验收文案"`unzip -v` 查看 CRC 与 content_hash 一致"指 zip **条目 CRC**（未压缩 sqlite 字节），与 L750 字面公式 `crc32(zip_bytes)`（**整个 zip 文件字节**）不等价 → **验收时请勿用 `unzip -v` 比对 content_hash（会误判不一致）**；正确口径 = 对 zip 文件字节重算 `crc32`（= P2 客户端对下载到的 zip 字节做的传输完整性校验，无需解压）。本 PR 取 L750；spec doc 文案清理留独立 spec PR。
- **B2-R4（条件性）**：若实施时本机无 docker，B1-R2 docker digest 继续 residual，`docker-compose.yml` 保留 tag pin。
- **B2-R5**：`generate_one_training_set` 重试在月线极窄（n=39 → 唯一可选下标）时会把同一 start 试满 `max_retries` 次（每次写+删 db/zip），终止于 `GenerateSkipException`（不死循环），但低效。接受 residual。
- **PG 壳无 CI 单测**：`_fetch_period_bars`/`generate_one`/`generate_batch`/`backfill_content_hash`/CLI 无 live PG 单测（D1/D13，B3/NAS scope）；纯装配层覆盖全部业务正确性。
- **zip 字节非确定性**：`content_hash` 不跨重建复现（zip 头嵌 mtime）；它是"传输完整性指纹"，P2 须对收到的 zip 字节重算比对，不可重新打包再 hash。

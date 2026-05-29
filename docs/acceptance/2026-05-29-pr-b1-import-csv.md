# PR B1 验收清单（中文非程序员可执行）

> Wave 1 顺位 16 / 交付序第 18 个 PR。spec `kline_trainer_modules_v1.4.md` §四 B1 + `kline_trainer_plan_v1.5.md` §6.4.1。
> plan `docs/superpowers/plans/2026-05-29-pr-b1-import-csv.md`。

## §A 文件存在

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| A.1 | `ls backend/import_csv.py` | 存在 | 文件在 |
| A.2 | `ls backend/tests/test_import_csv.py backend/tests/fixtures/sample_1m.csv` | 两文件 | 都在 |
| A.3 | `test -f scripts/acceptance/plan_b1_import_csv.sh && echo OK` | OK | 输出 OK |

## §B 纯层 pytest 全绿（本地，无需 DB）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| B.1 | `cd backend && python3 -m pytest tests/test_import_csv.py -q` | `N passed`（N≥16），0 failed | exit=0 + 末行无 failed |

## §C 模块可导入 + CLI/写库符号存在

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| C.1 | `cd backend && python3 -c "import import_csv as m; print('main' in dir(m), 'write_to_postgres' in dir(m))"` | `True True` | 命中 |

## §D 指标公式落地（D2-D5 grep 锚）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| D.1 | `grep -nc 'rolling(window=66' backend/import_csv.py` | 1 (D3 MA66) | =1 |
| D.2 | `grep -nc 'std(ddof=0)' backend/import_csv.py` | 1 (D4 BOLL 总体 std) | =1 |
| D.3 | `grep -nc 'ewm(span=12, adjust=False)' backend/import_csv.py` | 1 (D5 EMA12) | =1 |
| D.4 | `grep -nc '(dif - dea) * 2' backend/import_csv.py` | 1 (D5 BAR×2) | =1 |

## §E ticket_index 1m 基准语义（D6）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| E.1 | `grep -nc 'searchsorted' backend/import_csv.py` | ≥1 (跨周期映射) | ≥1 |
| E.2 | `grep -nc 'return list(range(len(df)))' backend/import_csv.py` | 1 (1m 升序) | =1 |

## §F 双层边界：纯层不顶层依赖 asyncpg（D1/D14）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| F.1 | `grep -ncE '^import asyncpg$' backend/import_csv.py` | 0 (asyncpg 只在函数内 import) | =0 |
| F.2 | `grep -nc 'import asyncpg  # 局部' backend/import_csv.py` | 1 (写库壳内局部 import) | =1 |

## §G H6-part1 deps 精确 pin（D12）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| G.1 | `grep -cE '^[a-zA-Z0-9_.-]+==' backend/requirements-dev.txt` | =5 (全部 ==) | =5 |
| G.2 | `grep -cE '(>=|<)' backend/requirements-dev.txt` | 0 (无 range) | =0 |
| G.3 | `grep -nc 'postgres:15.12' backend/docker-compose.yml` | 1 (image pin 到 15.12 tag) | =1（digest pin 待 docker 环境，见 §K residual B1-R2） |

## §H schema 未被改动（本 PR 只读 schema）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| H.1 | `git diff --name-only origin/main...HEAD -- backend/sql/` | 空 | 无输出 |

## §I 不碰 .github/workflows（D13 / user CI 决策）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| I.1 | `git diff --name-only origin/main...HEAD -- .github/` | 空 | 无输出 |

## §J 机检脚本自身

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| J.1 | `bash scripts/acceptance/plan_b1_import_csv.sh 2>&1 | tail -2` | `✅ 所有 N 项验收通过` | 末行 ✅ + exit 0 |

## §K Residuals

- **B1-R1**：backend pytest 未接 CI（user 2026-05-29 选"纯 opus xhigh，CI 延后"）。`test_import_csv.py` 仅本地 + 本脚本跑；接 path-gated CI workflow = trust-boundary，作独立 codex 治理 PR 后续补。
- **B1-R2**：实施环境无 docker，§G.3 digest pin 待补，本 PR 保留 tag `postgres:15.12`（未编造 digest）；待有 docker 环境时 `docker pull postgres:15.12 && docker inspect --format='{{index .RepoDigests 0}}' postgres:15.12` 取真实 digest 改为 `postgres:15.12@sha256:<digest>`。
- **B1-R3**：写库壳（`write_to_postgres`）+ CLI 无 CI 单测（D14，需 live PG = B3/NAS scope）；纯层覆盖全部业务正确性。
- **R4-2**：`_resolve_stock_name` 取首个非 NaN（非首个非空白）name；whitespace-only 首行会落到 fallback（--name / code）。name 按约定每文件恒定，fallback 安全，narrow edge，接受残留。
- **R4-3**：每文件一个 `asyncio.run` 新事件循环/连接；7 周期批量微不足道，复用连接增共享状态复杂度（CLAUDE.md §2 不值当），接受残留。
- **H7**：B1 仅提供测试用微型 fixture，3-5 个生产样本训练组数据由 B2（顺位 17）生成。

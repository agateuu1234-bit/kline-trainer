# PR B3 验收清单（中文非程序员可执行）

> Wave 1 顺位 18 / 交付序第 20 个 PR。spec `kline_trainer_modules_v1.4.md` §四 B3 (L755-808) + M0.2 (L351-393)。
> plan `docs/superpowers/plans/2026-05-29-pr-b3-fastapi-lease.md`。

## §A 文件存在

| 编号 | 操作 | 预期 | 通过条件 |
|---|---|---|---|
| A.1 | 在终端运行：`ls backend/app/lease_logic.py` | 显示文件路径，无报错 | 无 `No such file` 错误 |
| A.2 | 在终端运行：`ls backend/app/lease_repo.py` | 显示文件路径，无报错 | 无 `No such file` 错误 |
| A.3 | 在终端运行：`ls backend/app/routes.py` | 显示文件路径，无报错 | 无 `No such file` 错误 |
| A.4 | 在终端运行：`ls backend/tests/test_lease_logic.py` | 显示文件路径，无报错 | 无 `No such file` 错误 |
| A.5 | 在终端运行：`ls backend/tests/test_routes.py` | 显示文件路径，无报错 | 无 `No such file` 错误 |
| A.6 | 在终端运行：`test -f backend/app/main.py && echo OK` | 输出 `OK` | 输出必须是 `OK` |

## §B 纯层 + 路由 pytest 全绿（无需 DB）

| 编号 | 操作 | 预期 | 通过条件 |
|---|---|---|---|
| B.1 | 进入 `backend` 目录，运行：`python3 -m pytest tests/test_lease_logic.py -q` | 末行显示 `22 passed`，无 `failed` | exit 0 + 末行含 `passed`，无 `failed` |
| B.2 | 在同目录运行：`python3 -m pytest tests/test_routes.py -q` | 末行显示 `14 passed`，无 `failed` | exit 0 + 末行含 `passed`，无 `failed` |
| B.3 | 在同目录运行：`python3 -m pytest -q` | 末行显示 `99 passed`（含既有 63 条 + B3 新增 36 条），无 `failed` | exit 0 + 末行无 `failed` |

## §C 模块可导入 + 关键符号存在

| 编号 | 操作 | 预期 | 通过条件 |
|---|---|---|---|
| C.1 | 在 `backend` 目录运行：`python3 -c "from app.lease_logic import decide_confirm, is_meta_selectable, format_expires_at, ConfirmOutcome, RowState, LEASE_TTL; print('OK')"` | 输出 `OK` | 输出必须是 `OK` |
| C.2 | 在 `backend` 目录运行：`python3 -c "from app.lease_repo import LeaseRepository, InMemoryLeaseRepository, AsyncpgLeaseRepository, MetaRow; print('OK')"` | 输出 `OK` | 输出必须是 `OK` |
| C.3 | 在 `backend` 目录运行：`python3 -c "from app.routes import router, get_repository; print('OK')"` | 输出 `OK` | 输出必须是 `OK` |

## §D 状态机判定落地

| 编号 | 操作 | 预期 | 通过条件 |
|---|---|---|---|
| D.1 | 运行：`grep -nc 'row.status == "sent" and row.lease_id == lease_id' backend/app/lease_logic.py` | 输出 `1`（幂等检查行存在） | =1 |
| D.2 | 运行：`grep -nc 'lease_expires_at < now' backend/app/lease_logic.py` | 输出 `1`（confirm 用严格小于） | =1 |
| D.3 | 运行：`grep -nc 'return lease_expires_at <= now' backend/app/lease_logic.py` | 输出 `1`（meta 用小于等于，与 D.2 不对称；锚到 `return` 行以避开 docstring 注释里的同字样） | =1 |
| D.4 | 运行：`grep -nc 'status == "unsent"' backend/app/lease_logic.py` | 输出 `1`（meta 可选谓词包含 unsent） | =1 |

## §E D4 契约修正：expires_at 输出 `...Z` 格式

| 编号 | 操作 | 预期 | 通过条件 |
|---|---|---|---|
| E.1 | 运行：`grep -Fnc '%Y-%m-%dT%H:%M:%SZ' backend/app/lease_logic.py` | 输出 `1`（Z 后缀格式字面存在） | =1 |
| E.2 | 在 `backend` 目录运行：`python3 -c "from app.lease_logic import format_expires_at; from datetime import datetime, timezone; print(format_expires_at(datetime(2026,5,22,12,45,0,tzinfo=timezone.utc)))"` | 输出 `2026-05-22T12:45:00Z` | 输出必须精确匹配（含 Z 后缀、无小数秒、无 +00:00） |
| E.3 | 运行：`if grep -q 'expires_at.*isoformat()' backend/app/routes.py backend/app/lease_logic.py; then echo FAIL; else echo PASS; fi` | 输出 `PASS`（未用 isoformat 输出 expires_at） | 输出必须是 `PASS` |

## §F 共享 contract-fixtures 被 import 断言

| 编号 | 操作 | 预期 | 通过条件 |
|---|---|---|---|
| F.1 | 运行：`grep -c 'contract-fixtures' backend/tests/test_routes.py` | 输出 ≥1（路径引用存在） | ≥1 |
| F.2 | 运行：`grep -c '_load_fixture("lease_response_partial")' backend/tests/test_routes.py` | 输出 `1` | =1 |
| F.3 | 运行：`grep -c '_load_fixture("lease_response_empty")' backend/tests/test_routes.py` | 输出 `1` | =1 |
| F.4 | 运行：`grep -c '_load_fixture("lease_response_full")' backend/tests/test_routes.py` | 输出 ≥1 | ≥1 |
| F.5 | 运行：`grep -c '_load_fixture("confirm_ok")' backend/tests/test_routes.py` | 输出 `1` | =1 |
| F.6 | 运行：`grep -c '_load_fixture("error_lease_expired")' backend/tests/test_routes.py` | 输出 `1` | =1 |
| F.7 | 运行：`grep -c '_load_fixture("error_not_found")' backend/tests/test_routes.py` | 输出 ≥1 | ≥1 |

## §G 双层边界：纯层不顶层 import fastapi/asyncpg

| 编号 | 操作 | 预期 | 通过条件 |
|---|---|---|---|
| G.1 | 运行：`grep -cE '^(import\|from) (fastapi\|asyncpg)' backend/app/lease_logic.py` | 输出 `0`（纯决策层零顶层依赖） | =0（若命令因无匹配返回非零 exit，需用 `grep ... \|\| true` 包裹，值仍应为 0） |
| G.2 | 运行：`grep -cE '^import asyncpg' backend/app/lease_repo.py` | 输出 `0`（无顶层 import asyncpg；asyncpg 由 pool 参数注入，文件从不真正 import） | =0 |
| G.3 | 运行：`grep -cE '^[^#]*import asyncpg' backend/app/lease_repo.py` | 输出 `0`（去掉注释行后，全文件无任何 `import asyncpg` 语句——`AsyncpgLeaseRepository` 只收外部传入的 pool） | =0 |

## §H deps 无 range + 不改 frozen 文件

| 编号 | 操作 | 预期 | 通过条件 |
|---|---|---|---|
| H.1 | 运行：`if grep -qE '(>=\|<\|~=)' backend/requirements.txt backend/requirements-dev.txt; then echo "有range(FAIL)"; else echo "全pin(PASS)"; fi` | 输出 `全pin(PASS)` | 输出必须是 `全pin(PASS)` |
| H.2 | 运行：`git diff --name-only origin/main...HEAD -- backend/sql/ backend/openapi.yaml tests/contract-fixtures/ .github/` | 无任何输出 | 空输出（本 PR 未改 frozen 文件） |

## §NAS 真 PG 烟测（部署时手动，CI 不跑）

> 以下两个用例需要在已部署 NAS 上有真实 PostgreSQL 连接时手动执行（`AsyncpgLeaseRepository` 接真实 pool）。CI 中用 InMemory 实现全路径已由 §B 覆盖。

### 用例 A：租约过期后可重新预占（modules L807）

| 编号 | 操作 | 预期 | 通过条件 |
|---|---|---|---|
| NAS-A.1 | 向真实 PG 插入一条 `status='unsent'` 训练组记录，记下 `id`。 | 插入成功，行可查询 | 查询到该行 |
| NAS-A.2 | 调用 `GET /training-sets/meta?count=1`，获取 `lease_id` 和 `expires_at`。 | 响应 200，`sets` 含 1 条，`expires_at` 格式 `...Z` | HTTP 200 |
| NAS-A.3 | **不**调用 confirm。等待 10 分钟 + 1 秒（租约 TTL=10 分钟过期）。 | 等待完成 | — |
| NAS-A.4 | 再次调用 `GET /training-sets/meta?count=1`。 | 响应 200，`sets` 仍含同一 `id` 的记录（过期 reserved 可重选） | 响应中 `sets[0].id` 与 NAS-A.1 相同 |

### 用例 B：confirm 成功后不被重新预占（modules L808）

| 编号 | 操作 | 预期 | 通过条件 |
|---|---|---|---|
| NAS-B.1 | 向真实 PG 插入一条 `status='unsent'` 训练组记录，记下 `id`。 | 插入成功 | 行可查询 |
| NAS-B.2 | 调用 `GET /training-sets/meta?count=1`，取 `lease_id`。 | HTTP 200，行置 reserved | `sets[0].id` 为目标 id |
| NAS-B.3 | 调用 `POST /training-set/{id}/confirm?lease_id={lease_id}`。 | HTTP 200，`{"ok": true}` | 响应体精确匹配 `{"ok": true}` |
| NAS-B.4 | 再次调用 `GET /training-sets/meta?count=1`。 | HTTP 200，`sets` 为 `[]`（sent 行不可重选） | `sets == []` |

## §residual migration-runner defer（D5）

本 PR 不包含 migration-runner 机制（user 决策 2026-05-29，plan D5）。

`backend/sql/schema.sql` 是 v1.4 fresh baseline，当前无待执行 PG migration。migration-runner（迁移执行脚本 + 版本追踪）将在真正需要第一个 PG schema 变更时作独立 PR 实现。

本 PR 交付：3 个 M0.2 endpoint + 纯决策层 + InMemory repo + 共享 contract-fixtures 契约断言。migration 相关进 PR 后续治理队列（无阻塞当前交付）。

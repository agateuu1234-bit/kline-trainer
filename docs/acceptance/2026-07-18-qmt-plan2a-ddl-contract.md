# 验收清单 — QMT Plan 2a：D1 DDL 地基 + 契约 bump

> 分支 `qmt-plan2a-ddl-contract`。本清单**不需要看代码**，照着敲命令、比对输出即可。
> 每条命令请在仓库根目录 `/Users/maziming/Coding/Prj_Kline trainer` 下执行。
>
> **本 PR 做了什么（一句话）**：给数据库改了价格列的精度、加了一张新表、把契约版本号从 1.11 抬到 1.12，
> 并停止往一个废弃的列里写数据（但**保留**那一列不删）。

---

## ⚠️ 先读这条：本 PR **不会**让训练组开始生成

本 PR 只搭数据库地基，**不会**让 B4 补货真的产出训练组。真库里那张新表还是空的（没有任何代码往里写），
所以生成流程仍然会跳过每一只股票。解锁出货的是后续的 Plan 2b + Plan 3。

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 0 | 阅读本节 | 明白「本 PR 合并后训练组产量仍是 0，与合并前没有区别」 | ☐ 通过 ☐ 不通过 |

---

## 一、测试闸门

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | `cd backend && ../.venv/bin/python -m pytest tests/ -q` | 末行显示 `191 passed`，且**不含** `failed`、**不含** `skipped` 字样 | ☐ 通过 ☐ 不通过 |
| 2 | `cd ios/Contracts && swift build` | 末行显示 `Build complete!`，无 `error:` | ☐ 通过 ☐ 不通过 |
| 3 | `cd ios/Contracts && swift test` | 显示 `Test run with 1581 tests in 201 suites passed` | ☐ 通过 ☐ 不通过 |

> **第 3 条若崩在 `signal 11`**：这是陈旧增量构建导致的已知现象，**不是代码问题**。
> 先执行 `cd ios/Contracts && rm -rf .build/arm64-apple-macosx`，再重跑第 3 条。

---

## 一之二、两道防坏数据的守卫（codex 评审加的）

价格列放宽成小数精度更高的类型后，多了两条数据损坏路径，本 PR 一并堵上。这两条验的是**守卫真的会拦**，不是"代码写了"。

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1b | 整段复制粘贴：<br>`cd backend && ../.venv/bin/python -c "import pandas as pd; from import_csv import clean; df=pd.DataFrame([{'datetime':1,'open':float('inf'),'high':float('inf'),'low':1.0,'close':1.0,'volume':10},{'datetime':2,'open':1.0,'high':2.0,'low':0.5,'close':1.5,'volume':10}]); print('剩余行:', list(clean(df)['datetime']))"` | 打印 **`剩余行: [2]`**（含无穷大价格的第 1 行被丢弃，正常的第 2 行保留） | ☐ 通过 ☐ 不通过 |
| 1c | `cd backend && ../.venv/bin/python -m pytest tests/test_import_csv.py -q` | 显示 `20 passed`，无 failed / skipped | ☐ 通过 ☐ 不通过 |

> 1b 说明：如果打印的是 `剩余行: [1, 2]`，说明无穷大价格没被拦住，**请直接退回**——
> 那意味着坏数据能写进数据库并污染后续训练组。

---

## 二、版本号确实抬了

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 4 | `grep -n 'CONTRACT_VERSION = ' ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | 输出含 `"1.12"`（不是 `"1.11"` 或更早） | ☐ 通过 ☐ 不通过 |
| 5 | `grep -n '（顶层标识） |' docs/governance/m01-schema-versioning-contract.md` | **只输出 1 行**，且该行里显示 `"1.12"` | ☐ 通过 ☐ 不通过 |
| 6 | `grep -n 'PostgreSQL schema' docs/governance/m01-schema-versioning-contract.md` | 该行显示 `0004_qmt_price_double_and_coverage` | ☐ 通过 ☐ 不通过 |

---

## 三、那一列**保留**了（这条最重要，删了就是违规）

本次只是「不再往 `ticket_index` 这一列写数据」，**列本身必须还在**。删列属于不可逆变更，本仓治理规定禁止。

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 7 | `grep -n 'ticket_index' backend/sql/schema.sql` | 有输出，且能看到 `ticket_index INTEGER,` 这一行 | ☐ 通过 ☐ 不通过 |
| 8 | 执行下面这段（**整段复制粘贴**，负向检查）：<br>`if sed 's/--.*//' backend/sql/migrations/0004_qmt_price_double_and_coverage/forward.sql \| grep -q 'ticket_index'; then echo "不通过：迁移脚本动了该列"; else echo "通过：迁移脚本对该列零改动"; fi` | 打印 **`通过：迁移脚本对该列零改动`** | ☐ 通过 ☐ 不通过 |

> 第 8 条说明：命令里的 `sed 's/--.*//'` 是先把 SQL 注释剥掉再检查——该文件的**注释**里会正常提到
> `ticket_index`（说明该列被保留），只有真正的改动语句才算问题。这条检查已做过反向验证：
> 人为往脚本里加一句删列语句，它确实会打印「不通过」。
>
> 若打印「不通过」，说明迁移脚本里出现了对该列的 DDL 操作，属于严重问题，**请直接退回**。

---

## 四、迁移脚本是成对的，且回滚风险有写明

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 9 | `ls backend/sql/migrations/0004_qmt_price_double_and_coverage/` | 同时列出 `forward.sql` 与 `rollback.sql` 两个文件 | ☐ 通过 ☐ 不通过 |
| 10 | `grep -n '丢精度' backend/sql/migrations/0004_qmt_price_double_and_coverage/rollback.sql` | 有输出（回滚会丢失价格精度，这个警告必须写在文件里） | ☐ 通过 ☐ 不通过 |

---

## 五、改动范围没有越界

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 11 | `git diff --stat main...HEAD` | 列出的文件**只有**：两个 migration SQL、`backend/sql/schema.sql`、`backend/import_csv.py`、3 个 backend 测试文件、`m01-schema-versioning-contract.md`、`Models.swift`、`ModelsTests.swift`、以及一份 `docs/superpowers/plans/` 下的计划文档。**不应**出现任何 `.github/` 下的文件 | ☐ 通过 ☐ 不通过 |
| 12 | 执行下面这段（**整段复制粘贴**，负向检查）：<br>`if git diff --name-only main...HEAD \| grep -q '^\.github/'; then echo "不通过：动了 CI 配置"; else echo "通过：未动 CI 配置"; fi` | 打印 **`通过：未动 CI 配置`** | ☐ 通过 ☐ 不通过 |

---

## 六、治理文档的历史记录是准确的

本 PR 往治理文档追加了一条版本变更记录。该记录曾经写错过（把 PR 号和版本区间对错了），已订正。

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 13 | `grep -n '三个' docs/governance/m01-schema-versioning-contract.md` | 能看到「被**三个** PR 连续 bump」（不是「四个」） | ☐ 通过 ☐ 不通过 |
| 14 | 执行下面这段（**整段复制粘贴**，负向检查）：<br>`if grep -q '#132 RFC-A 交易/仓位/资金（`1.7`→`1.8`）' docs/governance/m01-schema-versioning-contract.md; then echo "不通过：错误归因仍在"; else echo "通过：错误归因已清除"; fi` | 打印 **`通过：错误归因已清除`** | ☐ 通过 ☐ 不通过 |

---

## 已知的、本次**刻意没改**的东西

以下不是本次遗漏，是有意留下的，验收时看到不必当问题：

1. **治理文档里 2026-06-22 那条旧记录的归因也是错的**：它说版本 `1.5→1.6` 来自「RFC-A Task 8」，
   实际对应的提交是 `b4f0e2a`「#99 Wave 3 顺位 10a：持久化基础」。这条**不在**本次改动范围内，
   属于既有问题。是否单独订正，待你决定。
2. **`stock_coverage` 新表目前没有任何代码往里写**：这是设计如此，写入方在后续的 Plan 3（B1 侧）。
3. **迁移脚本没有在真实 PostgreSQL 上跑过**：本仓所有数据库测试都是静态语法解析（不需要 Docker），
   真库验证属于部署环节，不在本 PR 范围。

---

## 验收结论

- 全部 17 条通过 → 本 PR 可以合并
- 任意一条不通过 → 请把「第几条 + 实际看到的输出」告诉我，**不要**自行放行

> 第 7、8 两条（那一列必须保留）若不通过，属于严重问题，请直接退回重做。

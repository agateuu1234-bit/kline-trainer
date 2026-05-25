# 验收清单 — E2 PositionManager 实施（Wave 1 顺位 8 / 第 10 个 PR）

> 给非程序员逐条核对。每条：照"动作"敲命令 → 比对"期望" → 在"通过"打 ✓/✗。命令在仓库根目录运行。
> 模块 E2 `PositionManager` = 加权平均成本持仓值类型；进程内交易违约直接崩（trap，因上游已守门），只有读存档（可能损坏）才走"抛错拒收"。本 PR 同时把数据契约版本号从 1.4 升到 1.5（因为读存档变严了）。

| # | 动作 | 期望 | 通过 |
|---|---|---|---|
| 1 | 运行：`cd ios/Contracts && swift test --filter PositionManager` | 全部通过，0 失败（约 20 项：核心 6 + 交易 6 + 持久化 8） | ☐ |
| 2 | 运行：`cd ios/Contracts && swift test` | 全 package 通过，0 失败（在既有 415 基础上增加约 20 项） | ☐ |
| 3 | 运行：`bash scripts/acceptance/plan_e2_position_manager.sh` | 每行 `OK:`，末行 `=== ALL E2 ACCEPTANCE CHECKS PASSED ===` | ☐ |
| 4 | 运行：`bash scripts/acceptance/plan_1f_m0_1_schema_versioning.sh 2>&1 \| grep 'CONTRACT_VERSION top'` | 显示 `OK: matrix row: CONTRACT_VERSION top \| \`"1.5"\``（本 PR 的 bump 触点通过）。注：该脚本整体会报 1 个**预存且无关**的失败 `regression: Plan 1b (M0.2 OpenAPI) acceptance`（plan_1b 硬编码期望 11 实际 19，与本 PR 零 backend 改动无关），可忽略 | ☐ |
| 5 | 运行：`grep -n 'CONTRACT_VERSION = ' ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | 显示 `= "1.5"`（版本号已升） | ☐ |
| 6 | 运行：`grep -c 'positionTier' ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift` | 输出 `0`（占位档位已移除，改由调用方推导） | ☐ |
| 7 | 运行：`grep -n 'init(from decoder' ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift` | 命中（持久化用"会抛错"的自定义解码器） | ☐ |
| 8 | 运行：`grep -n 'AppError' ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift` | **无任何输出**（本类型不碰 AppError，M0.4 豁免） | ☐ |
| 9 | 运行：`grep -n 'no-op' ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift` | 命中 sell(0) no-op（局终强平零报价不崩） | ☐ |
| 10 | 运行：`git diff --stat main...HEAD` | 改动文件 = PositionManager.swift / PositionManagerTests.swift / Models.swift / ModelsTests.swift / m01 契约 / modules / plan_1f 脚本 / plan_v1.5 / 新验收脚本 / 本清单 / plan 文档（**无新增 migration / 无新 .sql**） | ☐ |
| 11 | 运行：`git diff --name-only main...HEAD \| grep -E '\.sql$\|migration'` | **无任何输出**（仅顶层版本号 bump，无 DDL/migration —— 见 plan §4.2.7 / D5） | ☐ |

**任一条 ✗ → 不得 merge。** 第 1/2/3 条是硬门（功能 + 守门 + 契约同步真绿）；第 11 条证明"只升版本号、没动数据库结构"。

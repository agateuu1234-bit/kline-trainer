# 验收清单 — C3 主图渲染 Candles + MA66 + BOLL（Wave 1 顺位 9 / 第 11 个 PR）

> 给非程序员逐条核对。每条：照"动作"敲命令 → 比对"期望" → 在"通过"打 ✓/✗。命令在仓库根目录运行。
> 模块 C3 = 把 K 线主图的"蜡烛 + 66 均线 + 布林带"从空占位补成真画图代码。画图本身（描边/填充）由苹果编译器在 CI 验证；所有计算（蜡烛矩形/影线/折线坐标）在电脑上跑真测试。

| # | 动作 | 期望 | 通过 |
|---|---|---|---|
| 1 | 运行：`cd ios/Contracts && swift test --filter MainChartLayout` | 全部通过，0 失败（16 项：蜡烛 5 + MA66 5 + BOLL 4 + 索引契约 2） | ☐ |
| 2 | 运行：`cd ios/Contracts && swift test` | 全 package 通过，0 失败（在既有 435 基础上增加 16 项 → 451） | ☐ |
| 3 | 运行：`bash scripts/acceptance/plan_c3_candles_ma66_boll.sh` | 每行 `OK`，末行 `=== ALL C3 ACCEPTANCE CHECKS PASSED ===` | ☐ |
| 4 | 在浏览器打开本 PR → 看底部 CI 检查 | `swift test on macos-15` 与 `Mac Catalyst build-for-testing on macos-15` 两项均 ✓ 绿 | ☐ |
| 5 | 运行：`grep -ci '占位\|stub' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift` | 输出 `0`（三个方法已从空占位 stub 变成真实现，"占位/stub" 字样清除） | ☐ |
| 6 | 运行：`grep -n 'setLineDash' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift` | 命中（布林带按需求画成虚线） | ☐ |
| 7 | 运行：`grep -n 'AppError' ios/Contracts/Sources/KlineTrainerContracts/Render/MainChartLayout.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift` | **无任何输出**（纯画图，不碰错误类型，M0.4 豁免） | ☐ |
| 8 | 运行：`git diff --name-only main...HEAD` | 改动 = MainChartLayout.swift（新）/ KLineView+Candles.swift（改）/ MainChartLayoutTests.swift（新）/ 验收脚本 / 本清单 / plan 文档（**无 migration / 无 .sql / 无 backend**） | ☐ |

**任一条 ✗ → 不得 merge。** 第 1/2/3/4 条是硬门（计算真测 + 画图真编译 + CI 双绿）。

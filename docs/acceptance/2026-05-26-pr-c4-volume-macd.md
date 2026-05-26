# 验收清单 — C4 副图渲染 Volume + MACD（Wave 1 顺位 10 / 第 12 个 PR）

> 给非程序员逐条核对。每条：照"动作"敲命令 → 比对"期望" → 在"通过"打 ✓/✗。命令在仓库根目录运行。
> 模块 C4 = 把 K 线副图的"成交量柱 + MACD（DIF/DEA 线 + 柱）"从空占位补成真画图代码。画图本身（描边/填充）由苹果编译器在 CI 验证；所有计算（柱矩形、折线坐标、基线钳制）在电脑上跑真测试。

| # | 动作 | 期望 | 通过 |
|---|---|---|---|
| 1 | 运行：`cd ios/Contracts && swift test --filter SubChartLayout` | 全部通过，0 失败（15 项：volume 5 + MACD 折线 4 + MACD 柱 6） | ☐ |
| 2 | 运行：`cd ios/Contracts && swift test` | 全 package 通过，0 失败（在既有 451 基础上增加 15 项 → 466） | ☐ |
| 3 | 运行：`bash scripts/acceptance/plan_c4_volume_macd.sh` | 每行 `OK`，末行 `=== ALL C4 ACCEPTANCE CHECKS PASSED ===` | ☐ |
| 4 | 在浏览器打开本 PR → 看底部 CI 检查 | `swift test on macos-15` 与 `Mac Catalyst build-for-testing on macos-15` 两项均 ✓ 绿 | ☐ |
| 5 | 运行：`grep -c 'Wave 1 (C4): implement' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Volume.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift` | 两文件各输出 `0`（两个方法已从空占位 stub 变成真实现，"implement" 提示字样清除） | ☐ |
| 6 | 运行：`grep -n 'setLineDash' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift` | **无任何输出**（DIF/DEA 是实线，与 C3 BOLL 虚线不同） | ☐ |
| 7 | 运行：`grep -n 'AppColor.macdDIF\|AppColor.macdDEA\|AppColor.macdBarPositive\|AppColor.macdBarNegative' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift` | 4 项均命中（颜色取自 F2 token，未硬编码 RGB） | ☐ |
| 8 | 运行：`grep -n 'AppError' ios/Contracts/Sources/KlineTrainerContracts/Render/SubChartLayout.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Volume.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift` | **无任何输出**（纯画图，不碰错误类型，M0.4 豁免） | ☐ |
| 9 | 运行：`git diff --name-only main...HEAD` | 改动 = SubChartLayout.swift（新）/ KLineView+Volume.swift（改）/ KLineView+MACD.swift（改）/ SubChartLayoutTests.swift（新）/ 验收脚本 / 本清单 / plan 文档（**无 migration / 无 .sql / 无 backend / 不改 MainChartLayout**） | ☐ |

**任一条 ✗ → 不得 merge。** 第 1/2/3/4 条是硬门（计算真测 + 画图真编译 + CI 双绿）。

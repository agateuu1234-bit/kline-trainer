# PR C6 验收清单（中文非程序员可执行）

> Wave 1 顺位 12 / 第 14 个 PR。spec `docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md` (commit `b7c7450`)。

## §A modules amendment 字面验证

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| A.1 | `grep -nc 'infrastructure + tool 框架；Phase 2.5 水平线 MVP 归 Wave 3' kline_trainer_modules_v1.4.md` | 一个数字 | 数字 ≥ 1 |
| A.2 | `grep -nc 'tools: \[DrawingToolType: any DrawingTool\]' kline_trainer_modules_v1.4.md` | 一个数字 | 数字 ≥ 1 |
| A.3 | `grep -nc 'tools: \[:\]' kline_trainer_modules_v1.4.md` | 一个数字 | 数字 ≥ 1 |

## §B 编译 + 全量测试

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| B.1 | `cd ios/Contracts && swift build 2>&1 \| tail -3` | `Build complete!` | 命中 |
| B.2 | `cd ios/Contracts && swift test 2>&1 \| grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"` | `Test run with 503 tests in 100 suites passed after X seconds.` | tests 数 = 503，suites 数 = 100（main baseline 实测 486/96 + 本 PR 新增 17/4） |

## §C C6 新文件存在

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| C.1 | `ls ios/Contracts/Sources/KlineTrainerContracts/Drawing/` | DrawingInputController.swift / DrawingTool.swift / DrawingToolManager.swift 三个文件 | 全部存在 |
| C.2 | `ls ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/` | DrawingProtocolTests.swift / DrawingToolManagerTests.swift / DrawDrawingsDispatchTests.swift / SpecLiteralGuardTests.swift 四个文件 | 全部存在 |

## §D 4 个新 suite 全绿

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| D.1 | `cd ios/Contracts && swift test 2>&1 \| grep -cE 'Suite "(DrawingProtocolTests\|DrawingToolManagerTests\|DrawDrawingsDispatchTests\|SpecLiteralGuardTests)" passed'` | 数字 4 | 数字 = 4 |

## §E spec literal grep 锚（防 spec drift）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| E.1 | `grep -nc 'static var type: DrawingToolType' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift` | 1 hit | 数字 = 1 |
| E.2 | `grep -nc 'var requiredAnchors: ClosedRange<Int>' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift` | 1 hit | 数字 = 1 |
| E.3 | `grep -nc 'public protocol DrawingTool' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift` | 1 hit (protocol-level @MainActor isolation per Task 1 fix) | 数字 = 1 |
| E.4 | `grep -nc 'func render(ctx: CGContext' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift` | 1 hit | 数字 = 1 |
| E.5 | `grep -nc 'func hitTest(point: CGPoint' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift` | 1 hit | 数字 = 1 |
| E.6 | `grep -nc 'public protocol DrawingInputController: AnyObject' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingInputController.swift` | 1 hit | 数字 = 1 |
| E.7 | `grep -nc '@Observable' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift` | 1 hit | 数字 = 1 |
| E.8 | `grep -nc 'final class DrawingToolManager' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift` | 1 hit | 数字 = 1 |
| E.9 | `grep -nc 'func drawDrawings(ctx: CGContext' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift` | 1 hit | 数字 = 1 |
| E.10 | `grep -nc 'tools: \[DrawingToolType: any DrawingTool\]' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift` | 1 hit | 数字 = 1 |

## §F precondition invariant grep 锚

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| F.1 | `grep -nc '// invariant:' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift` | ≥ 4 hit（addAnchor + commit ×2 + deleteDrawing） | 数字 ≥ 4 |

## §G Manager 不依赖 ChartReducer（单向接缝硬约束）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| G.1 | `grep -nE 'ChartAction\|ChartReducer\|interactionMode\|ChartReduceEffect' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift` | 无任何命中（注释字符串里描述这条约束的 prose 不算源码引用） | 仅注释 / 输出为空 |
| G.2 | `grep -nE 'ChartAction\|ChartReducer' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingInputController.swift` | 无任何命中 | 输出为空 |

## §H drawDrawings 调用方 KLineView L55 显式 `tools: [:]`

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| H.1 | `grep -n 'tools: \[:\]' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift` | 一行命中 L55-56 区域 | 数字 ≥ 1 |

## §I scope 边界（本 PR 不在 scope 的字面退出验证）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| I.1 | `find ios/Contracts/Sources/KlineTrainerContracts/Drawing -name '*Horizontal*' -o -name '*Ray*' -o -name '*Trend*' -o -name '*Default*'` | 无文件 | 输出为空（无具体 tool / DefaultController 实现） |
| I.2 | `grep -rn 'import GRDB' ios/Contracts/Sources/KlineTrainerContracts/Drawing/` | 无命中 | 输出为空（drawings 不持久化） |

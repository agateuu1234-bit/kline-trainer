# PR U3 验收清单（中文非程序员可执行）

> Wave 1 顺位 13 / 第 15 个 PR。spec `kline_trainer_plan_v1.5.md` §6.3 + `kline_trainer_modules_v1.4.md` §U3。
> plan `docs/superpowers/plans/2026-05-27-pr-u3-settlement-view.md`。

## §A 文件存在

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| A.1 | `ls ios/Contracts/Sources/KlineTrainerContracts/UI/` | SettlementContent.swift / SettlementView.swift 两个文件 | 全部存在 |
| A.2 | `ls ios/Contracts/Tests/KlineTrainerContractsTests/UI/` | SettlementContentTests.swift | 存在 |
| A.3 | `test -f scripts/acceptance/plan_u3_settlement_view.sh && echo OK` | OK | 输出 OK |

## §B 编译 + 全量测试（macOS host）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| B.1 | `cd ios/Contracts && swift build 2>&1 \| tail -3` | `Build complete!` | 命中 |
| B.2 | `cd ios/Contracts && swift test 2>&1 \| grep -E "Test run with [0-9]+ tests in [0-9]+ suites passed"` | 一行命中模式（基线 502/99 + 本 PR +16/+1 = 期望 518/100，但 grep 宽松不硬锁 N/M） | 命中模式 + `swift test` exit=0 |

## §C Catalyst 编译闸门（§15.1 #3）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| C.1 | `cd ios/Contracts && xcodebuild -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/u3-derived build-for-testing 2>&1 \| tail -5` | `TEST BUILD SUCCEEDED` | 命中 |

## §D 新 suite 全绿

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| D.1 | `cd ios/Contracts && swift test --filter SettlementContentTests 2>&1 \| grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"` | 一行命中模式（期望 N≥16/M=1） | 命中模式 + `swift test --filter SettlementContentTests` exit=0 |

## §E spec 字面 grep 锚（D1-D8 落地 — 防 spec drift）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| E.1 | `grep -nc 'public struct SettlementContent: Equatable, Sendable' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit | 数字 = 1 |
| E.2 | `grep -nc 'public struct SettlementView: View' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit | 数字 = 1 |
| E.3 | `grep -nc 'init(record: TrainingRecord, onConfirm: @escaping () -> Void)' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit (D12：modules §U3 字面 `() -> Void` + Swift 编译强制 `@escaping`) | 数字 = 1 |
| E.4 | `grep -nc '本局结算' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit (spec L992) | 数字 = 1 |
| E.5 | `grep -nc '"确认"' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit (spec L1003) | 数字 = 1 |
| E.6 | `grep -nc '"¥ ' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | ≥ 1 hit (D3 ¥+空格字符串前缀；实测 2 = 1 顶注释字面 + 1 prod return 字面) | 数字 ≥ 1 |
| E.7 | `grep -nc 'en_US_POSIX' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit (D3 Locale 中性) | 数字 = 1 |
| E.8 | `grep -nc '"%+.2f"' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit (D5 显式带符号) | 数字 = 1 |
| E.9 | `grep -nc '"%02d"' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit (D4 月份零填充) | 数字 = 1 |
| E.10 | `grep -nc 'static func formatStock' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit (D7 全角括号函数存在) | 数字 = 1 |
| E.11 | `grep -nc '（' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | ≥ 1 hit (D7 中文全角左括号字面) | 数字 ≥ 1 |
| E.12 | `grep -nc 'raw == 0' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit (R1-C1 D5 signed-zero 归一化代码) | 数字 = 1 |

## §F 不依赖 Wave 0 / 1 业务运行时（叶子组件硬约束）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| F.1 | `grep -nE 'import (GRDB\|ZIPFoundation)' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 无命中 | 输出为空 |
| F.2 | `grep -nE 'TradeCalculator\|TickEngine\|PositionManager\|TrainingFlowController\|APIClient' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 无命中 | 输出为空 |
| F.3 | `grep -nc 'import SwiftUI' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 0 hit (Content 平台无关) | 数字 = 0 |
| F.4 | `grep -nc 'import SwiftUI' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit (View 才 import) | 数字 = 1 |

## §G 无 RGB 硬编码 / 无 D2 反例（盈亏色未实现）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| G.1 | `grep -nE 'Color\\(red:\|UIColor\\(' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 无命中 | 输出为空 |
| G.2 | `grep -nE '\\.foregroundStyle\\(\\.red\|\\.foregroundStyle\\(\\.green' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 无命中 (D2：不分盈亏色) | 输出为空 |

## §H DEBUG-only preview 隔离（D9 + R1-H4 — fileprivate 防跨模块污染）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| H.1 | `grep -nE '#if DEBUG' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit | 数字 = 1 |
| H.2 | `grep -nc '#endif' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | ≥ 1 hit (DEBUG 配对) | 数字 ≥ 1 |
| H.3 | `grep -nc 'fileprivate extension TrainingRecord' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit (D9 + R1-H4 fileprivate) | 数字 = 1 |
| H.4 | `grep -ncE '^public.* extension TrainingRecord|^extension TrainingRecord.*public' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 0 hit (R1-H4 拒绝 public 跨模块污染；锚行首与 script G8 对齐) | 数字 = 0 |
| H.5 | `grep -nc 'extension TrainingRecord\|TrainingRecord.preview' ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` | 0 hit (本 PR 不动 PreviewFakes — D9) | 数字 = 0 |

## §I onConfirm 语义不分支（D11）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| I.1 | `grep -nE 'TrainingFlowController\|Mode\\.\|\\.normal\|\\.review\|\\.replay' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 无命中 (View 不分 mode) | 输出为空 |

## §J 机检脚本自身

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| J.1 | `bash scripts/acceptance/plan_u3_settlement_view.sh 2>&1 \| tail -2` | `所有 N 项 G1-Gx 验收通过` | 末行 ✅ + 0 exit code |

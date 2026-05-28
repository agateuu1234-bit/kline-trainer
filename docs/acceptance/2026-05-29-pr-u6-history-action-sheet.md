# PR U6 验收清单（中文非程序员可执行）

> Wave 1 顺位 15 / 交付序第 17 个 PR。spec `kline_trainer_plan_v1.5.md` §6.1.3 + `kline_trainer_modules_v1.4.md` §U6。
> plan `docs/superpowers/plans/2026-05-29-pr-u6-history-action-sheet.md`。

## §A 文件存在

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| A.1 | `ls ios/Contracts/Sources/KlineTrainerContracts/UI/` | HistoryActionContent.swift / HistoryActionSheet.swift 两个新文件（+ Settlement*/PositionPicker* 老的 4 个） | 全部存在 |
| A.2 | `ls ios/Contracts/Tests/KlineTrainerContractsTests/UI/` | HistoryActionContentTests.swift（+ 老的 SettlementContentTests / PositionPickerContentTests） | 存在 |
| A.3 | `test -f scripts/acceptance/plan_u6_history_action_sheet.sh && echo OK` | OK | 输出 OK |

## §B 编译 + 全量测试（macOS host）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| B.1 | `cd ios/Contracts && swift build 2>&1 \| tail -3` | `Build complete!` | 命中 |
| B.2 | `cd ios/Contracts && swift test 2>&1 \| grep -E "Test run with [0-9]+ tests in [0-9]+ suites passed"` | 一行命中模式（基线 529/101 + 本 PR +10/+1 = 期望 539/102，但 grep 宽松不硬锁 N/M） | 命中模式 + `swift test` exit=0 |

## §C Catalyst 编译闸门（§15.1 #3）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| C.1 | `cd ios/Contracts && xcodebuild -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/u6-derived build-for-testing 2>&1 \| tail -5` | `TEST BUILD SUCCEEDED` | 命中 |

## §D 新 suite 全绿

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| D.1 | `cd ios/Contracts && swift test --filter HistoryActionContentTests 2>&1 \| grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"` | 一行命中模式（期望 N≥10/M=1） | 命中模式 + `swift test --filter HistoryActionContentTests` exit=0 |

## §E spec 字面 grep 锚（D1-D13 落地 — 防 spec drift）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| E.1 | `grep -nc 'public struct HistoryActionContent: Equatable, Sendable' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift` | 1 hit | 数字 = 1 |
| E.2 | `grep -nc 'public struct HistoryActionSheet: View' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit | 数字 = 1 |
| E.3 | `grep -nc 'init(record: TrainingRecord,' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit | 数字 = 1 |
| E.4 | `grep -nc 'onReview: @escaping () -> Void' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D9) | 数字 = 1 |
| E.5 | `grep -nc 'onReplay: @escaping () -> Void' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D9) | 数字 = 1 |
| E.6 | `grep -nc 'onCancel: @escaping () -> Void' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D6 + D9) | 数字 = 1 |
| E.7 | `grep -nc 'Text("复盘")' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D7 spec L893 body literal) | 数字 = 1 |
| E.8 | `grep -nc 'Text("再来一次")' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D7 spec L894 body literal) | 数字 = 1 |
| E.9 | `grep -nc 'Text("取消")' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D6/D7 取消按钮 label body literal) | 数字 = 1 |
| E.10 | `grep -nc 'Button(action: onReview)' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (复盘按钮真接 onReview callback) | 数字 = 1 |
| E.11 | `grep -nc 'Button(action: onReplay)' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (再来一次按钮真接 onReplay callback) | 数字 = 1 |
| E.12 | `grep -nc 'Button(action: onCancel)' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (取消按钮真接 onCancel callback) | 数字 = 1 |
| E.13 | `grep -nc 'Text(content.title)' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D3 标题来自 Content) | 数字 = 1 |
| E.14 | `grep -nc 'Self.formatStock(name: record.stockName, code: record.stockCode)' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift` | 1 hit (D3/D4 标题映射) | 数字 = 1 |

## §F 不依赖 Wave 0/1/2 业务运行时（叶子组件硬约束 + D12）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| F.1 | `grep -nE 'import (GRDB\|ZIPFoundation)' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 无命中 | 输出为空 |
| F.2 | `grep -nE 'TradeCalculator\|TickEngine\|PositionManager\|TrainingFlowController\|TrainingMode\|NormalFlow\|ReviewFlow\|ReplayFlow\|APIClient' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 无命中 (D12 — 含 E4 三 flow 类型) | 输出为空 |
| F.3 | `grep -ncE '^import SwiftUI$' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift` | 0 hit (Content 平台无关；锚 `^import SwiftUI$` 行首避免命中注释里"不 import SwiftUI"子串) | 数字 = 0 |
| F.4 | `grep -ncE '^import SwiftUI$' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (View 才真 import SwiftUI；锚行首) | 数字 = 1 |

## §G 无 RGB 硬编码 / 无 D8 反例（盈亏色未实现）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| G.1 | `grep -nE 'Color\(red:\|UIColor\(' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 无命中 | 输出为空 |
| G.2 | `grep -nE '\.foregroundStyle\(\.red\|\.foregroundStyle\(\.green' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 无命中 (D8：不分盈亏色) | 输出为空 |
| G.3 | `grep -ncF 'buttonStyle(.borderedProminent)' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 0 hit (D8：三按钮全 .bordered；锚真实用法 `buttonStyle(.borderedProminent)` 避免命中 header 注释里的 `.borderedProminent` 字样) | 数字 = 0 |

## §H DEBUG-only preview 隔离（D11 — fileprivate 防跨模块污染）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| H.1 | `grep -ncE '^#if DEBUG$' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (锚 `^#if DEBUG$` 行首避免命中注释里同子串) | 数字 = 1 |
| H.2 | `grep -nc '#endif' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | ≥ 1 hit (DEBUG 配对) | 数字 ≥ 1 |
| H.3 | `grep -nc 'fileprivate extension TrainingRecord' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D11 机制 = fileprivate extension TrainingRecord，与 U3 严格同款) | 数字 = 1 |
| H.4 | `grep -ncE '^public.* extension TrainingRecord\|^extension TrainingRecord.*public' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 0 hit (D11 拒绝 public 跨模块污染) | 数字 = 0 |
| H.5 | `grep -nc 'extension TrainingRecord\|TrainingRecord.preview' ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` | 0 hit (本 PR 不动 PreviewFakes — D11) | 数字 = 0 |
| H.6 | `grep -nc 'static func formatStock' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit (U3 既有；证明本 PR 不动 U3 — D4 不复用) | 数字 = 1 |

## §I caller-presentation 边界（D13 — View 不调 dismiss）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| I.1 | `grep -nE 'dismiss\(\)\|@Environment\(\\.dismiss' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 无命中 (View 不调 dismiss；caller 负责 presentation container) | 输出为空 |

## §J 机检脚本自身

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| J.1 | `bash scripts/acceptance/plan_u6_history_action_sheet.sh 2>&1 \| tail -2` | `所有 12 项 G1-G12 验收通过` | 末行 ✅ + 0 exit code |

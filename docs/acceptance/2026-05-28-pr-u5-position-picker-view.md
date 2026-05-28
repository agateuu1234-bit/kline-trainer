# PR U5 验收清单（中文非程序员可执行）

> Wave 1 顺位 14 / 第 16 个 PR。spec `kline_trainer_plan_v1.5.md` §6.2.4 + `kline_trainer_modules_v1.4.md` §U5。
> plan `docs/superpowers/plans/2026-05-28-pr-u5-position-picker-view.md`。

## §A 文件存在

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| A.1 | `ls ios/Contracts/Sources/KlineTrainerContracts/UI/` | PositionPickerContent.swift / PositionPickerView.swift 两个文件（+ SettlementContent.swift / SettlementView.swift 老的） | 全部存在 |
| A.2 | `ls ios/Contracts/Tests/KlineTrainerContractsTests/UI/` | PositionPickerContentTests.swift（+ SettlementContentTests.swift 老的） | 存在 |
| A.3 | `test -f scripts/acceptance/plan_u5_position_picker_view.sh && echo OK` | OK | 输出 OK |

## §B 编译 + 全量测试（macOS host）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| B.1 | `cd ios/Contracts && swift build 2>&1 \| tail -3` | `Build complete!` | 命中 |
| B.2 | `cd ios/Contracts && swift test 2>&1 \| grep -E "Test run with [0-9]+ tests in [0-9]+ suites passed"` | 一行命中模式（基线 519/100 + 本 PR +10/+1 = 期望 529/101，但 grep 宽松不硬锁 N/M） | 命中模式 + `swift test` exit=0 |

## §C Catalyst 编译闸门（§15.1 #3）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| C.1 | `cd ios/Contracts && xcodebuild -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/u5-derived build-for-testing 2>&1 \| tail -5` | `TEST BUILD SUCCEEDED` | 命中 |

## §D 新 suite 全绿

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| D.1 | `cd ios/Contracts && swift test --filter PositionPickerContentTests 2>&1 \| grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"` | 一行命中模式（期望 N≥10/M=1） | 命中模式 + `swift test --filter PositionPickerContentTests` exit=0 |

## §E spec 字面 grep 锚（D1-D11 落地 — 防 spec drift）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| E.1 | `grep -nc 'public struct PositionPickerContent: Equatable, Sendable' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift` | 1 hit | 数字 = 1 |
| E.2 | `grep -nc 'public struct PositionPickerView: View' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit | 数字 = 1 |
| E.3 | `grep -nc 'init(enabledTiers: Set<PositionTier>,' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit | 数字 = 1 |
| E.4 | `grep -nc 'onPick: @escaping (PositionTier) -> Void' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D11) | 数字 = 1 |
| E.5 | `grep -nc 'onCancel: @escaping () -> Void' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D6 + D11) | 数字 = 1 |
| E.6 | `grep -nc 'Text("仓位选择")' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D7 spec L946 — anchor SwiftUI body literal，非 header 注释里的同字符串；R3 修) | 数字 = 1 |
| E.7 | `grep -nc 'Text("取消")' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D6 取消按钮 label — anchor SwiftUI body literal；R3 修) | 数字 = 1 |
| E.7b | `grep -nc 'Button(action: onCancel)' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (R1-M2 修：D6 取消按钮真接 onCancel callback，非仅 label) | 数字 = 1 |
| E.8 | `grep -nc 'PositionTier.allCases.map' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift` | 1 hit (D4 迭代 allCases 非 Set) | 数字 = 1 |
| E.9 | `grep -nc 'tier.rawValue' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift` | 1 hit (D3 label = rawValue) | 数字 = 1 |
| E.10 | `grep -nc 'enabled: enabledTiers.contains(tier)' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift` | 1 hit (D5 enabled 判定 — 锚 `enabled:` 前缀避免命中 D5 注释同子串，R6 修) | 数字 = 1 |
| E.11 | `grep -nc 'HStack' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | ≥ 1 hit (D2 横向布局) | 数字 ≥ 1 |
| E.12 | `grep -nc '.disabled(!item.enabled)' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D5/D8 disabled 视觉) | 数字 = 1 |

## §F 不依赖 Wave 0 / 1 业务运行时（叶子组件硬约束 + D14）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| F.1 | `grep -nE 'import (GRDB\|ZIPFoundation)' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 无命中 | 输出为空 |
| F.2 | `grep -nE 'TradeCalculator\|TickEngine\|PositionManager\|TrainingFlowController\|APIClient' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 无命中 (D14) | 输出为空 |
| F.3 | `grep -ncE '^import SwiftUI$' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift` | 0 hit (Content 平台无关；锚 `^import SwiftUI$` 避免命中注释里"不 import SwiftUI"子串，R5 修) | 数字 = 0 |
| F.4 | `grep -ncE '^import SwiftUI$' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (View 才真 import；锚行首 R5 修) | 数字 = 1 |

## §G 无 RGB 硬编码 / 无 D16 反例（盈亏色未实现）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| G.1 | `grep -nE 'Color\\(red:\|UIColor\\(' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 无命中 | 输出为空 |
| G.2 | `grep -nE '\\.foregroundStyle\\(\\.red\|\\.foregroundStyle\\(\\.green' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 无命中 (D16：不分盈亏色) | 输出为空 |

## §H DEBUG-only preview 隔离（D9 — fileprivate 防跨模块污染）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| H.1 | `grep -ncE '^#if DEBUG$' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (锚 `^#if DEBUG$` 行首避免命中注释里同子串，R6 修) | 数字 = 1 |
| H.2 | `grep -nc '#endif' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | ≥ 1 hit (DEBUG 配对) | 数字 ≥ 1 |
| H.3 | `grep -nc 'fileprivate extension PositionTier' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D9 v2 mechanism = `fileprivate extension PositionTier`，与 U3 严格同款) | 数字 = 1 |
| H.3b | `grep -nc 'static func previewEnabledTiers() -> Set<PositionTier>' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D9 v2 fixture 方法名) | 数字 = 1 |
| H.4 | `grep -ncE '^public.* extension PositionTier\|^extension PositionTier.*public' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 0 hit (D9 拒绝 public 跨模块污染；锚现在真有目标可禁，R1-M4 修) | 数字 = 0 |
| H.5 | `grep -nc 'extension PositionTier\|PositionTier.preview' ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` | 0 hit (本 PR 不动 PreviewFakes — D9) | 数字 = 0 |

## §I caller-presentation 边界（D15 — View 不调 dismiss）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| I.1 | `grep -nE 'dismiss\\(\\)\|@Environment\\(\\\\.dismiss' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 无命中 (View 不调 dismiss；caller 负责 presentation container) | 输出为空 |

## §J 机检脚本自身

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| J.1 | `bash scripts/acceptance/plan_u5_position_picker_view.sh 2>&1 \| tail -2` | `所有 12 项 G1-G12 验收通过` | 末行 ✅ + 0 exit code |

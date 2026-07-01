# WB-R4 兼容收口 + DateFormatter 缓存 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 收口 #135 遗留的 WB-R4 公共-API 兼容争议（功能退路 A）+ 修 crosshair/坐标轴热路径的 per-frame DateFormatter 分配（不可变缓存）。

**Architecture:** I1 功能退路——公共 `HistoryDialogPresentation` 谓词恢复通用契约（只滤 `.history`），settings 专属「滤出 sheet」下沉到用 popover 的 `AppRootView` 本地排除，旧 `HomeView` 5 参 init 去 deprecated 成可用 legacy sheet 路由。I2——三处 `DateFormatter()` per-frame 分配 → `nonisolated(unsafe) static let` **不可变** formatter 缓存（抽 internal `formatTimeLabel` helper 作 cache 家 + 并发压测入口），输出逐字不变。

**Tech Stack:** Swift 6 / SwiftUI + UIKit（`#if canImport(UIKit)`）/ Swift Testing（host）/ Mac Catalyst build-for-testing + iOS Simulator build。Spec：`docs/superpowers/specs/2026-07-01-residuals-compat-datefmt-design.md`（codex spec R1–R4 APPROVE `@2eba044`）。基线 origin/main `d2eb431`。

## Global Constraints
- 零引擎 / 持久层 / **数据契约**改动；**不 bump CONTRACT_VERSION（保持当前 1.8）**。I1 有意改变公共 UI 路由谓词 `sheetItem`/`sheetDismissMayApply` 对 `.settings` 的行为（恢复 #135 前通用契约），已在 spec「公共契约变更声明」如实记录——CONTRACT_VERSION 语义 = 数据契约，不覆盖 UI 谓词，故不 bump。
- `AppRouter.Modal` 仅 `Identifiable` **非 Equatable** → 一律 `if case`/`HistoryDialogPresentation.isSettings` 谓词，**禁 `== .settings`**（落地后 grep 守卫）。
- **所有缓存 DateFormatter 建后不可变**（固定 tz `UTC+8(secondsFromGMT:8*3600)` + locale `en_US_POSIX` + 固定 dateFormat，**无 per-call 改 dateFormat**）→ 并发只读安全。**⚠️ 工具链对账（Task 1 Catalyst 亲验）**：本项目工具链（Xcode 16）`DateFormatter` 已 `Sendable` → 用**纯 `private static let`**（**不要加 `nonisolated(unsafe)`**——加了 Catalyst/本地都报 `'nonisolated(unsafe)' is unnecessary … 'Sendable' type 'DateFormatter'` 触发零-warning gate 红）。**本 plan 下文所有 `nonisolated(unsafe) static let` 示意 → 按纯 `static let` 读**。Catalyst build-for-testing 必须亲验 + CI-gate `(error|warning):` count=0。
- I2 缓存**输出逐字不变**（同 tz/locale/format 的同一字符串）——现有 render 输出断言即回归守卫。
- 负向 grep 断言用 `if/exit 1` 非 `! grep`。

---

### Task 1: I2 · DateFormatter 不可变缓存（3 Render 文件 + 并发压测）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift`（`enum CrosshairLayout`；resolve 内 `:93-103` per-call 分配）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairSidebarContent.swift`（`public struct`；`formatDateTime` `:126-136`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift`（`enum AxisGridLayout`；`timeTicks` `:96-111` + `dateFormat(for:)` `:117`）
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DateFormatterCacheConcurrencyTests.swift`

**Interfaces:**
- Produces（并发压测消费）：`CrosshairLayout.formatTimeLabel(_ datetime: Int64) -> String`（internal static）；`CrosshairSidebarContent.formatDateTime(datetime: Int64, period: Period) -> (String, String?)`（既有 internal static，改用缓存）；`AxisGridLayout.formatTimeLabel(datetime: Int64, period: Period) -> String`（internal static）。均**内部（非 private）**供 `@testable` 压测直调。

- [ ] **Step 1: `CrosshairLayout` 加缓存 formatter + 抽 `formatTimeLabel`**

在 `enum CrosshairLayout {` 内（`resolve` 之前，约 `:39` 后）插入：
```swift
    // per-frame 分配修复：不可变缓存 formatter（固定 tz/locale/format，建后永不变异 → 并发只读安全，spec §3.1）。
    // DateFormatter 非 Sendable → nonisolated(unsafe)（真安全：无可变共享态）。
    private nonisolated(unsafe) static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// 吸附蜡烛 datetime → 时间标签串（internal 供并发压测直调）。
    static func formatTimeLabel(_ datetime: Int64) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(datetime)))
    }
```
`resolve` 内 `:93-103` 把：
```swift
        let datetime = candles[snappedIndex].datetime
        let date = Date(timeIntervalSince1970: TimeInterval(datetime))
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let timeBottom = frames?.macdChart.maxY ?? frame.maxY
        let timeWidth: CGFloat = 120, timeHeight: CGFloat = 18
        let timeRect = CGRect(x: snappedX - timeWidth / 2, y: timeBottom - timeHeight,
                              width: timeWidth, height: timeHeight)
        let timeLabel = CrosshairResolved.Label(rect: timeRect, text: formatter.string(from: date))
```
改为（删 `date`/`formatter` 局部分配，用 `formatTimeLabel`）：
```swift
        let datetime = candles[snappedIndex].datetime
        let timeBottom = frames?.macdChart.maxY ?? frame.maxY
        let timeWidth: CGFloat = 120, timeHeight: CGFloat = 18
        let timeRect = CGRect(x: snappedX - timeWidth / 2, y: timeBottom - timeHeight,
                              width: timeWidth, height: timeHeight)
        let timeLabel = CrosshairResolved.Label(rect: timeRect, text: Self.formatTimeLabel(datetime))
```

- [ ] **Step 2: `CrosshairSidebarContent` 加 2 缓存 formatter + `formatDateTime` 改缓存**

在 `public struct CrosshairSidebarContent` 内（`formatDateTime` 之前）插入：
```swift
    private nonisolated(unsafe) static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private nonisolated(unsafe) static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
```
`formatDateTime` `:126-136` 改为（不再 per-call `df.dateFormat=…`）：
```swift
    static func formatDateTime(datetime: Int64, period: Period) -> (String, String?) {
        let date = Date(timeIntervalSince1970: TimeInterval(datetime))
        let dateText = dateFormatter.string(from: date)
        guard isIntraday(period) else { return (dateText, nil) }
        return (dateText, timeFormatter.string(from: date))
    }
```

- [ ] **Step 3: `AxisGridLayout` 加 3 per-format 缓存 formatter + 选择器 + `formatTimeLabel`；删 `dateFormat(for:)`**

先确认 `dateFormat(for:)` 仅 `timeTicks` 一处用：
```bash
grep -rn "dateFormat(for" ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift
```
预期只 `:99` 一处（timeTicks 内）。在 `enum AxisGridLayout {` 内插入：
```swift
    private static func makeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    // 每 format 一个不可变 formatter（永不变异 → 无共享可变态、无竞争，spec §3.3 / codex spec-R1/R3）。
    private nonisolated(unsafe) static let intradayFormatter = makeFormatter("MM-dd HH:mm")  // m3/m15/m60
    private nonisolated(unsafe) static let dayFormatter      = makeFormatter("yyyy-MM-dd")   // daily/weekly
    private nonisolated(unsafe) static let monthFormatter    = makeFormatter("yyyy-MM")      // monthly
    private static func formatter(for period: Period) -> DateFormatter {
        switch period {
        case .m3, .m15, .m60: return intradayFormatter
        case .daily, .weekly: return dayFormatter
        case .monthly:        return monthFormatter
        }
    }
    /// 坐标轴时间标签串（internal 供并发压测直调）。
    static func formatTimeLabel(datetime: Int64, period: Period) -> String {
        formatter(for: period).string(from: Date(timeIntervalSince1970: TimeInterval(datetime)))
    }
```
`timeTicks` `:96-111` 把 `let fmt = DateFormatter(); fmt.timeZone=…; fmt.locale=…; fmt.dateFormat = dateFormat(for: period)` 4 行删除；循环内 `labels.append(Label(rect: rect, text: fmt.string(from: date)))`（含上一行 `let date = …`）改为：
```swift
            labels.append(Label(rect: rect, text: Self.formatTimeLabel(datetime: candles[idx].datetime, period: period)))
```
删除 `private static func dateFormat(for period:)`（`:117-123`，已折叠进 3 formatter，Step 3 首行 grep 已证无其它引用）。

- [ ] **Step 4: 写并发压测（新文件）**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DateFormatterCacheConcurrencyTests.swift`：
```swift
// 平台无关：host swift test 直跑。验缓存 DateFormatter 并发只读安全（codex spec-R2-H2 接受缓存的前提）。
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("DateFormatter 缓存并发只读安全")
struct DateFormatterCacheConcurrencyTests {

    // 2025-01-02 01:36:00 UTC = 2025-01-02 09:36 (UTC+8)
    private let dt: Int64 = 1_735_781_760

    @Test("200 并发任务格式化 == 单线程基线（无崩溃/交叉污染）")
    func concurrentEqualsSequential() async {
        // 单线程基线
        let base1 = CrosshairLayout.formatTimeLabel(dt)
        let (baseD, baseT) = CrosshairSidebarContent.formatDateTime(datetime: dt, period: .m60)
        let baseAxisIntra = AxisGridLayout.formatTimeLabel(datetime: dt, period: .m60)
        let baseAxisDay   = AxisGridLayout.formatTimeLabel(datetime: dt, period: .daily)
        let baseAxisMon   = AxisGridLayout.formatTimeLabel(datetime: dt, period: .monthly)
        // sanity：捕捉 epoch/格式错误
        #expect(base1 == "2025-01-02 09:36")
        #expect(baseD == "2025-01-02" && baseT == "09:36")
        #expect(baseAxisIntra == "01-02 09:36")
        #expect(baseAxisDay == "2025-01-02")
        #expect(baseAxisMon == "2025-01")
        // 并发 hammer：每任务的每处输出须 == 基线
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    let (d, t) = CrosshairSidebarContent.formatDateTime(datetime: self.dt, period: .m60)
                    return CrosshairLayout.formatTimeLabel(self.dt) == base1
                        && d == baseD && t == baseT
                        && AxisGridLayout.formatTimeLabel(datetime: self.dt, period: .m60) == baseAxisIntra
                        && AxisGridLayout.formatTimeLabel(datetime: self.dt, period: .daily) == baseAxisDay
                        && AxisGridLayout.formatTimeLabel(datetime: self.dt, period: .monthly) == baseAxisMon
                }
            }
            for await ok in group { #expect(ok) }
        }
    }
}
```

- [ ] **Step 5: 运行 host 全套（输出回归 + 并发压测 + 无回归）**

Run: `swift test --package-path ios/Contracts`
Expected: 全绿——现有 `CrosshairLayoutTests`（`timeLabel.text=="2025-01-02 09:36"`）/`CrosshairSidebarContentTests`（`dateText`/`timeText`）/`AxisGridLayoutTests`（timeTicks 标签）**输出断言不变仍过**（缓存不改输出）+ 新 `DateFormatterCacheConcurrencyTests` 过 + Swift Testing 末行 0 failures + XCTest「All tests passed」。首次构建数分钟属正常。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairSidebarContent.swift ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/DateFormatterCacheConcurrencyTests.swift
git commit -m "perf(render): DateFormatter 每帧分配 → 不可变静态缓存(crosshair+坐标轴) + 并发压测"
```

---

### Task 2: I1a · `HistoryDialogPresentation` 恢复通用契约（只滤 .history）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryDialogPresentation.swift`（`sheetItem` `:18-22`、`sheetDismissMayApply` `:38-42`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryDialogPresentationTests.swift`（revert #135 两断言）

**Interfaces:**
- Produces（Task 4 消费）：`sheetItem(.settings)` 透传（返 `.settings`）；`sheetDismissMayApply(.settings)` 返 true；`isSettings(_:)` **不变**（仍 true only .settings）。

- [ ] **Step 1: revert #135 两测试断言（红）**

在 `HistoryDialogPresentationTests.swift` 把 `sheetItemFiltersSettings`（`:30-33`）改为透传断言 + 把 `sheetDismissBlocksSettings`（`:43-46`）改为 true 断言：
```swift
    @Test("sheetItem 对 .settings 原样透传（功能退路：settings 经共享 sheet；popover 专属过滤下沉 AppRootView）")
    func sheetItemPassesSettings() {
        #expect(HistoryDialogPresentation.sheetItem(for: .settings)?.id == "settings")
    }
```
```swift
    @Test("sheetDismissMayApply 对 .settings 返 true（功能退路：settings 经共享 sheet，legacy 消费者可正常 dismiss；popover 双弹由 AppRootView 本地拦）")
    func sheetDismissAllowsSettings() {
        #expect(HistoryDialogPresentation.sheetDismissMayApply(current: .settings) == true)
    }
```
`isSettingsPredicate`（`:35-40`）、`sheetItemFiltersHistory`、`sheetItemPassesSettlement`、`sheetItemNil`、history dismiss 测**不动**。

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path ios/Contracts --filter HistoryDialogPresentationTests`
Expected: FAIL——`sheetItemPassesSettings`（现 sheetItem(.settings) 仍返 nil，`?.id` 为 nil≠"settings"）+ `sheetDismissAllowsSettings`（现返 false≠true）。

- [ ] **Step 3: 改实现（恢复只滤 .history）**

`HistoryDialogPresentation.swift` `sheetItem` `:18-22` 改为：
```swift
    /// 共享 `.sheet(item:)` 的 item 过滤：`.history`（居中 overlay）→ nil；`.settings`/`.settlement` 原样透传。
    /// 注：settings 的「popover 专属滤出 sheet」下沉到用 popover 的 AppRootView 本地处理（WB-R4 功能退路），
    /// 本通用谓词保持中立（settings 经共享 sheet 是 legacy 消费者的默认路由）。
    public static func sheetItem(for modal: AppRouter.Modal?) -> AppRouter.Modal? {
        if case .history = modal { return nil }
        return modal
    }
```
`sheetDismissMayApply` `:38-42` 改为：
```swift
    /// High-1 守卫：共享 sheet 的 dismiss 回写是否可生效。`.history`（居中 overlay）态返 false（其 set(nil) 回写须拦）；其余 true。
    /// 注：settings 的 popover dismiss 守卫下沉 AppRootView 本地（WB-R4 功能退路）。
    public static func sheetDismissMayApply(current: AppRouter.Modal?) -> Bool {
        if case .history = current { return false }
        return true
    }
```
`isSettings`（`:31-34`）、`isHistoryPresented`（`:25-28`）**不变**。

- [ ] **Step 4: 运行确认通过**

Run: `swift test --package-path ios/Contracts --filter HistoryDialogPresentationTests`
Expected: PASS（含改后 `sheetItemPassesSettings`/`sheetDismissAllowsSettings` + `isSettings` + history/settlement 断言）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryDialogPresentation.swift ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryDialogPresentationTests.swift
git commit -m "fix(settings): HistoryDialogPresentation 恢复通用契约(只滤 history)——WB-R4 功能退路"
```

---

### Task 3: I1b · `HomeView` 旧 init 去 deprecated（可用 legacy 路由）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift`（旧 5 参 init 的 `@available(*, deprecated)` `:32`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/HomeViewSourceCompatTests.swift`（守卫改用旧 init）

**Interfaces:**
- Produces：旧 5 参 `init(content:onStartTraining:onContinueTraining:onSelectRecord:onOpenSettings:)` **无 deprecation**（可用 legacy 路由，委托主泛型 init 传 `.constant(false)`+`EmptyView` 不变）；主泛型 init 不变；`HomeView` 仍非泛型 concrete。

- [ ] **Step 1: 去掉旧 init 的 `@available(*, deprecated)` + 更新文档**

`HomeView.swift` 把旧 5 参 init 上方的注释（`:27-32`）与 `@available` 行替换为：
```swift
    /// Legacy 源兼容 overload（WB-R4 功能退路）：本 init 构造的 HomeView **不接线设置 popover**（settingsContent=EmptyView）；
    /// 呈现设置由调用方经共享 sheet（`HistoryDialogPresentation.sheetItem` 透传 `.settings`）+ 自己的 `.sheet` 完成。
    /// AppRootView 用主 init（popover）；老式消费者用本 init + 自己的 sheet。二者都能出设置 → 无静默丢、无源破坏。
    public init(content: HomeContent,
```
即删除 `@available(*, deprecated, message: "…")` 那一行（其余 init 体、委托 `.constant(false)`+`{ EmptyView() }` 不变）。

- [ ] **Step 2: 守卫测改用旧 5 参 init（现无 deprecation 告警）**

`HomeViewSourceCompatTests.swift` 的 `bareConcreteType` 改用**旧 5 参 init** 构造（证 legacy 路由可用 + bare concrete 类型；旧 init 若重加 deprecated → 本测触发 warning → Catalyst 零-warning gate 抓）：
```swift
    @Test("HomeView 为 bare concrete 类型 + 旧 5 参 init 可用无 deprecation（WB-R4 功能退路 / codex spec-R6-H1）")
    @MainActor func bareConcreteTypeAndLegacyInit() {
        let _: HomeView = HomeView(content: makeContent(),
                                   onStartTraining: {}, onContinueTraining: {},
                                   onSelectRecord: { _ in }, onOpenSettings: {})
    }
```

- [ ] **Step 3: 运行 host 全套（HomeView 跨平台，host 编译）**

Run: `swift test --package-path ios/Contracts`
Expected: 全绿——`HomeViewSourceCompatTests` 用旧 init 编译通过**无 deprecation warning**（去 deprecated 后）；2 个 `#Preview`（用主 init）不受影响；无回归。

- [ ] **Step 4: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift ios/Contracts/Tests/KlineTrainerContractsTests/UI/HomeViewSourceCompatTests.swift
git commit -m "fix(settings): HomeView 旧 5 参 init 去 deprecated——WB-R4 功能退路(可用 legacy sheet 路由)"
```

---

### Task 4: I1c · `AppRootView` settings 专属过滤本地化（防双弹 + clobber 守卫）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift`（`sheetModalBinding` `:25-33`）

**Interfaces:**
- Consumes：`HistoryDialogPresentation.sheetItem`（Task 2：`.settings` 透传）/`isSettings`/`sheetDismissMayApply`。
- 本文件 `#if canImport(UIKit)` UIKit-only → host swift test 不编译它；Catalyst build-for-testing 是编译闸门。

- [ ] **Step 1: `sheetModalBinding` 加本地 settings 排除 + clobber 守卫**

`AppRootView.swift` `sheetModalBinding` `:25-33` 改为：
```swift
    // RFC #2 + WB-R4：共享 sheet 的 item binding。
    // 本 view 用 popover 呈现 settings → 本地把 .settings 排除出自己的 sheet（防与 popover 双弹）；
    // 公共 sheetItem 保持通用（settings 透传，供 legacy 消费者经 sheet 呈现）。
    private var sheetModalBinding: Binding<AppRouter.Modal?> {
        Binding(
            get: {
                if HistoryDialogPresentation.isSettings(router.activeModal) { return nil }
                return HistoryDialogPresentation.sheetItem(for: router.activeModal)
            },
            set: { newValue in
                // history 由 sheetDismissMayApply 拦；settings 由本地 !isSettings 拦——
                // settlement→settings 跃迁时本 sheet 收起触发 set(nil)，不可清掉 popover 驱动的 settings。
                guard HistoryDialogPresentation.sheetDismissMayApply(current: router.activeModal),
                      !HistoryDialogPresentation.isSettings(router.activeModal) else { return }
                router.activeModal = newValue
            }
        )
    }
```
`settingsPopoverBinding`（`:38-47`）、HomeView 构造（主 init + popover）、`.sheet` switch、`isHistoryPresented` **不变**。

- [ ] **Step 2: `== .settings` 负向 grep 守卫 + host 全套（AppRootView UIKit-only，host 不编译它）**

Run（`if/exit 1`）:
```bash
if grep -rn "== *\.settings" ios/Contracts/Sources; then echo "FAIL: 禁 == .settings，用 isSettings 谓词"; exit 1; else echo "OK: 无 == .settings"; fi
```
Expected: `OK: 无 == .settings`。
Run: `swift test --package-path ios/Contracts`
Expected: 全绿无回归（AppRootView 为 UIKit-only host 编译为空，其呈现由 Catalyst 闸门 + 真机验收覆盖）。

- [ ] **Step 3: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift
git commit -m "fix(settings): AppRootView 本地排除 settings 出 sheet + clobber 守卫——WB-R4 功能退路防双弹"
```

---

## 验证（实现完成后，归 verification-before-completion）
三绿亲核：
1. **host swift test**：`swift test --package-path ios/Contracts` —— Swift Testing 末行 0 failures **且** XCTest「All tests passed」（含新并发压测 + revert 后的 HistoryDialog 断言 + HomeView legacy 守卫；render 输出断言不变仍过）。
2. **Mac Catalyst build-for-testing**：`cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath <dd>` → `** TEST BUILD SUCCEEDED **` **且** CI-gate `grep -cE "(error|warning):" 日志 == 0`（**验纯 `static let`（DateFormatter Sendable）零 warning、无 `nonisolated(unsafe)` "unnecessary" 告警 + AppRootView UIKit 编译**）。
3. **iOS Simulator app build**：`xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator'` → `** BUILD SUCCEEDED **`。
4. **`== .settings` grep 守卫**：sources 无匹配。

真机验收（人工，acceptance 见 spec §5）：A1（设置 popover 无回归）+ A2（十字光标时间标签无回归）+ A3（坐标轴时间标签无回归）。

## Self-Review（plan 对 spec 覆盖）
- spec §2.1 HistoryDialogPresentation 恢复通用契约 → Task 2。✅
- spec §2.2 AppRootView 本地排除 + clobber 守卫 → Task 4。✅
- spec §2.3 HomeView 旧 init 去 deprecated → Task 3。✅
- spec §3.1/3.2/3.3 三处不可变缓存 formatter（含 AxisGridLayout per-format）→ Task 1 Step 1-3。✅
- spec §3.4 / §4 并发压测（codex spec-R2-H2）→ Task 1 Step 4。✅
- spec §4 revert #135 两断言 + HomeView legacy 守卫 + grep 守卫 → Task 2 Step 1 / Task 3 Step 2 / Task 4 Step 2。✅
- 公共契约变更声明（无 CONTRACT_VERSION bump）→ Global Constraints。✅
- 类型一致性：`formatTimeLabel`(CrosshairLayout `_ datetime:`、AxisGridLayout `datetime:period:`)、`formatDateTime`、`isSettings`/`sheetItem`/`sheetDismissMayApply` 跨 Task 一致。✅

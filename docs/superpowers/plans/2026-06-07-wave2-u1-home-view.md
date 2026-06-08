# U1 HomeView Implementation Plan（Wave 2 顺位 8 · view-only shell）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 U1 首页展示层 shell —— 平台无关纯值 `HomeContent`（格式化训练统计/历史/按钮态/缓存态）+ 薄 SwiftUI `HomeView`（注入 4 个导航意图），coordinator 接线/路由归顺位 11。

**Architecture:** 双层 shell（沿用 U3/U4/U5/U6）：`HomeContent` 仅 `import Foundation`，host swift test 全测；`HomeView` `import SwiftUI`，由 Mac Catalyst build-for-testing 编译闸门守护，不 host 单测。数据流单向（输入元组/记录 → Content → View 只读渲染），意图流单向（交互 → 注入闭包 → caller 路由）。

**Tech Stack:** Swift 6 / SwiftUI / Swift Testing（`import Testing`）/ Swift Package Manager（`ios/Contracts`，module `KlineTrainerContracts`）/ Mac Catalyst CI。

**权威源**：设计文档 `docs/superpowers/specs/2026-06-07-wave2-u1-home-view-design.md`（D1-D13）+ `kline_trainer_plan_v1.5.md` §6.1（L849-899）+ `kline_trainer_modules_v1.4.md` §U1。

---

## Task 0：评审策略前置（§15.3）

- 本 PR 评审通道：按 user 显式指令走 **claude opus 4.8 xhigh 对抗评审**（spec/plan/最终三道闸门，已 spec 阶段 R1-R4 收敛 APPROVE）。codex 通道不在本轮（user-explicit）。
- iOS PR 强制 `Mac Catalyst build-for-testing on macos-15` required check（顺位 2-11 均触发）。本地 `swift test` 绿不等于 CI 绿（per `feedback_swift_local_toolchain_blindspot`）。
- 本 PR 无 trust-boundary 改动（纯新增 UI 展示文件，不动 `.github/workflows`、不动冻结契约）。

## File Structure

| 文件 | 责任 | 类型 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift` | 纯值：`ProfitSign` + `HomeHistoryRow` + `HomeContent` + 自包含格式化 static 函数 | 新建（生产） |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift` | 薄 SwiftUI shell：消费 `HomeContent` + 4 注入闭包，渲染首页四区 | 新建（生产） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/UI/HomeContentTests.swift` | host 真断言覆盖 §五测试矩阵 | 新建（测试） |
| `docs/acceptance/2026-06-07-wave2-u1-home-view.md` | 非 coder 验收清单 | 新建（文档） |

无既有文件改动（view-only，不接生产 root）。

---

## Task 1：`HomeContent` 纯值 + 格式化（TDD）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/HomeContentTests.swift`

- [ ] **Step 1：写失败测试 `HomeContentTests.swift`（全量）**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/UI/HomeContentTests.swift
// Spec: kline_trainer_plan_v1.5.md §6.1 L849-899 + docs/superpowers/specs/2026-06-07-wave2-u1-home-view-design.md §五
// 平台无关：只 import Foundation（host swift test 直跑，不需 Catalyst）。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("HomeContent host tests")
struct HomeContentTests {

    // MARK: - Fixtures

    /// 固定偏移时区（无 DST/历史 tz-db 怪异，纯偏移算术，host 测试确定性最强）。
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let plus8 = TimeZone(secondsFromGMT: 8 * 3600)!

    private func makeRecord(
        id: Int64? = 1,
        createdAt: Int64 = 1_710_532_800,   // 2024-03-15 20:00:00 UTC
        stockCode: String = "600519",
        stockName: String = "贵州茅台",
        startYear: Int = 2021,
        startMonth: Int = 8,
        totalCapital: Double = 102_345.67,
        profit: Double = 2_345.67,
        returnRate: Double = 0.0234
    ) -> TrainingRecord {
        TrainingRecord(
            id: id, trainingSetFilename: "f.sqlite", createdAt: createdAt,
            stockCode: stockCode, stockName: stockName, startYear: startYear, startMonth: startMonth,
            totalCapital: totalCapital, profit: profit, returnRate: returnRate, maxDrawdown: -0.05,
            buyCount: 1, sellCount: 1,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            finalTick: 100)
    }

    private func makeContent(
        totalCount: Int = 3, winCount: Int = 2, currentCapital: Double = 108_900.00,
        configuredCapital: Double = 100_000,
        records: [TrainingRecord] = [], hasPending: Bool = false, hasCachedSets: Bool = true,
        timeZone: TimeZone? = nil
    ) -> HomeContent {
        HomeContent(
            statistics: (totalCount: totalCount, winCount: winCount, currentCapital: currentCapital),
            configuredCapital: configuredCapital, records: records,
            hasPending: hasPending, hasCachedSets: hasCachedSets,
            timeZone: timeZone ?? utc)
    }

    // MARK: - 统计栏 §6.1.1

    @Test("总局次取 statistics.totalCount")
    func totalSessionsCount() {
        #expect(makeContent(totalCount: 3).totalSessions == "3 局")
        #expect(makeContent(totalCount: 0).totalSessions == "0 局")
    }

    @Test("胜率正常四舍五入")
    func winRateNormal() {
        #expect(makeContent(totalCount: 3, winCount: 2).winRate == "67%")   // 66.67→67
        #expect(makeContent(totalCount: 2, winCount: 1).winRate == "50%")
    }

    @Test("D7 胜率 .5 边界双判别锚（toNearestOrAwayFromZero，banker's 会 FAIL）")
    func winRateHalfBoundaryDiscriminates() {
        // 1/8=12.5：toNearestOrEven→12 / awayFromZero→13
        #expect(makeContent(totalCount: 8, winCount: 1).winRate == "13%")
        // 5/8=62.5：toNearestOrEven→62 / awayFromZero→63
        #expect(makeContent(totalCount: 8, winCount: 5).winRate == "63%")
    }

    @Test("D2 胜率 totalCount==0 → 破折号（不杜撰 0%）")
    func winRateZeroGames() {
        #expect(makeContent(totalCount: 0, winCount: 0).winRate == "—")
    }

    @Test("胜率全胜 100% / 全败 0%")
    func winRateExtremes() {
        #expect(makeContent(totalCount: 8, winCount: 8).winRate == "100%")
        #expect(makeContent(totalCount: 5, winCount: 0).winRate == "0%")
    }

    @Test("总资金正常显示 currentCapital，¥ 带空格 + 千分位 + 2 位小数")
    func totalCapitalNormal() {
        #expect(makeContent(totalCount: 3, currentCapital: 108_900).totalCapital == "¥ 108,900.00")
    }

    @Test("D13 零局总资金回退 configuredCapital（非 ¥ 0.00）")
    func totalCapitalZeroGameFallback() {
        #expect(makeContent(totalCount: 0, currentCapital: 0, configuredCapital: 100_000)
            .totalCapital == "¥ 100,000.00")
    }

    @Test("D13 totalCount>0 即便 currentCapital==0.0 也不回退（真实清零局）")
    func totalCapitalClearedSessionNoFallback() {
        #expect(makeContent(totalCount: 1, currentCapital: 0.0, configuredCapital: 100_000)
            .totalCapital == "¥ 0.00")
    }

    @Test("超大资金用千分位不科学记数")
    func totalCapitalLarge() {
        #expect(makeContent(totalCount: 1, currentCapital: 12_345_678.99).totalCapital == "¥ 12,345,678.99")
    }

    // MARK: - 按钮 §6.1.2

    @Test("hasPending → 继续训练 + isResuming")
    func buttonResuming() {
        let c = makeContent(hasPending: true)
        #expect(c.primaryActionLabel == "继续训练")
        #expect(c.isResuming == true)
    }

    @Test("无 pending → 开始训练 + 非 resuming")
    func buttonStart() {
        let c = makeContent(hasPending: false)
        #expect(c.primaryActionLabel == "开始训练")
        #expect(c.isResuming == false)
    }

    @Test("hasCachedSets 透传")
    func hasCachedSetsPassthrough() {
        #expect(makeContent(hasCachedSets: true).hasCachedSets == true)
        #expect(makeContent(hasCachedSets: false).hasCachedSets == false)
    }

    // MARK: - 历史列表 §6.1.3

    @Test("空历史 → isHistoryEmpty + rows 空")
    func emptyHistory() {
        let c = makeContent(records: [])
        #expect(c.isHistoryEmpty == true)
        #expect(c.rows.isEmpty)
    }

    @Test("D10 排序 createdAt 从新到旧；createdAt 相等用 id desc 兜底")
    func historySorted() {
        let r1 = makeRecord(id: 10, createdAt: 100)
        let r2 = makeRecord(id: 20, createdAt: 300)
        let r3 = makeRecord(id: 30, createdAt: 300)   // 与 r2 同 createdAt
        let c = makeContent(records: [r1, r2, r3])
        // 期望：createdAt desc → 300 组在前；同 300 内 id desc → 30 先于 20；最后 100
        #expect(c.rows.map(\.id) == [30, 20, 10])
    }

    @Test("D12 id==nil 记录被 compactMap 跳过，不 trap")
    func nilIdRecordSkipped() {
        let valid = makeRecord(id: 5, createdAt: 200)
        let nilId = makeRecord(id: nil, createdAt: 999)
        let c = makeContent(records: [valid, nilId])
        #expect(c.rows.map(\.id) == [5])         // 只剩合法记录
        #expect(c.rows.count == 1)
    }

    @Test("M2 totalSessions 取 statistics.totalCount，与 rows.count 刻意不等（compactMap 跳 nil）")
    func totalSessionsSourceIsolation() {
        let c = makeContent(totalCount: 3, records: [
            makeRecord(id: 1, createdAt: 100), makeRecord(id: nil, createdAt: 200)])
        #expect(c.totalSessions == "3 局")   // 来自 statistics
        #expect(c.rows.count == 1)            // 2 输入 − 1 nil-id（compactMap 后），证明二者解耦
    }

    @Test("行字段格式（stock 全角括号 / startMonth 零填充 / totalCapital ¥ 空格）")
    func rowFields() {
        let c = makeContent(records: [makeRecord(stockCode: "600519", stockName: "贵州茅台",
                                                 startYear: 2021, startMonth: 8, totalCapital: 102_345.67)])
        let row = c.rows[0]
        #expect(row.stock == "贵州茅台（600519）")
        #expect(row.startMonth == "2021年08月")
        #expect(row.totalCapital == "¥ 102,345.67")
    }

    @Test("行 dateTime 固定时区格式化（D5 禁默认）")
    func rowDateTimePinnedTZ() {
        // createdAt 1_710_532_800 = 2024-03-15 20:00:00 UTC
        let c = makeContent(records: [makeRecord(createdAt: 1_710_532_800)], timeZone: utc)
        #expect(c.rows[0].dateTime == "2024-03-15 20:00")
    }

    @Test("D5 跨时区：同 createdAt 在 UTC vs +8 落不同日期/小时")
    func rowDateTimeCrossTimezone() {
        let r = [makeRecord(createdAt: 1_710_532_800)]
        let inUTC = makeContent(records: r, timeZone: utc).rows[0].dateTime
        let inPlus8 = makeContent(records: r, timeZone: plus8).rows[0].dateTime
        #expect(inUTC == "2024-03-15 20:00")
        #expect(inPlus8 == "2024-03-16 04:00")   // +8h 跨日
        #expect(inUTC != inPlus8)
    }

    @Test("D8 盈亏正：+¥ 金额（+rate%）精确串")
    func profitAndRatePositive() {
        let c = makeContent(records: [makeRecord(profit: 2_345.67, returnRate: 0.0234)])
        #expect(c.rows[0].profitAndRate == "+¥ 2,345.67（+2.34%）")
    }

    @Test("D8 盈亏负：-¥ 金额（-rate%）精确串")
    func profitAndRateNegative() {
        let c = makeContent(records: [makeRecord(profit: -1_234.56, returnRate: -0.0123)])
        #expect(c.rows[0].profitAndRate == "-¥ 1,234.56（-1.23%）")
    }

    @Test("D8 双零：+¥ 0.00（+0.00%）")
    func profitAndRateDoubleZero() {
        let c = makeContent(records: [makeRecord(profit: 0, returnRate: 0)])
        #expect(c.rows[0].profitAndRate == "+¥ 0.00（+0.00%）")
    }

    @Test("M3 混合零：profit/returnRate 符号各自独立归一化（含 signed-zero）")
    func profitAndRateMixedZero() {
        let a = makeContent(records: [makeRecord(profit: -0.0, returnRate: 0.0234)])
        #expect(a.rows[0].profitAndRate == "+¥ 0.00（+2.34%）")
        let b = makeContent(records: [makeRecord(profit: 2_345.67, returnRate: -0.0)])
        #expect(b.rows[0].profitAndRate == "+¥ 2,345.67（+0.00%）")
    }

    @Test("D8 ULP：returnRate 0.1 不泄漏 10.000…002")
    func profitAndRateULP() {
        let c = makeContent(records: [makeRecord(profit: 1_000, returnRate: 0.1)])
        #expect(c.rows[0].profitAndRate == "+¥ 1,000.00（+10.00%）")
    }

    @Test("D9 sign 据 profit：正/负/零（含 -0.0→.zero）")
    func profitSignByProfit() {
        #expect(makeContent(records: [makeRecord(profit: 1)]).rows[0].sign == .positive)
        #expect(makeContent(records: [makeRecord(profit: -1)]).rows[0].sign == .negative)
        #expect(makeContent(records: [makeRecord(profit: 0)]).rows[0].sign == .zero)
        #expect(makeContent(records: [makeRecord(profit: -0.0)]).rows[0].sign == .zero)
    }

    // MARK: - 值语义

    @Test("HomeContent Equatable / Sendable")
    func contentEquatableSendable() {
        let r = [makeRecord()]
        #expect(makeContent(records: r) == makeContent(records: r))
        let _: any Sendable = makeContent()
    }
}
```

- [ ] **Step 2：跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter HomeContentTests 2>&1 | tail -5`
Expected: 编译失败 `cannot find 'HomeContent' in scope`（实现未建）。

- [ ] **Step 3：写实现 `HomeContent.swift`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift
// Spec: kline_trainer_plan_v1.5.md §6.1 L849-899 + docs/superpowers/specs/2026-06-07-wave2-u1-home-view-design.md
//
// 平台无关纯值类型：把训练统计 / 历史记录 / 按钮态 / 缓存态格式化成 HomeView 显示用字符串与语义标志。
// 平台守卫：仅 import Foundation，不 import SwiftUI/UIKit —— host swift test 全测。
// 格式化全部自包含（不复用 SettlementContent，沿用 U6 D4「避免 sibling UI content 耦合」）。
//
// 决议（见设计文档 §四 D1-D13）。

import Foundation

/// 盈亏色语义（view 映射红/绿/默认，Content 不含颜色）。
public enum ProfitSign: Equatable, Sendable {
    case positive, negative, zero
}

/// 单条历史记录的显示快照（§6.1.3）。
public struct HomeHistoryRow: Identifiable, Equatable, Sendable {
    public let id: Int64            // 已解包非 nil（D12）。SwiftUI 身份 + onSelectRecord 回传
    public let dateTime: String     // "2024-03-15 20:00"
    public let stock: String        // "贵州茅台（600519）"
    public let startMonth: String   // "2021年08月"
    public let totalCapital: String // "¥ 102,345.67"
    public let profitAndRate: String // "+¥ 2,345.67（+2.34%）"
    public let sign: ProfitSign
}

public struct HomeContent: Equatable, Sendable {
    // 统计栏 §6.1.1
    public let totalSessions: String
    public let winRate: String
    public let totalCapital: String
    // 按钮 §6.1.2
    public let primaryActionLabel: String
    public let isResuming: Bool
    public let hasCachedSets: Bool
    // 历史列表 §6.1.3
    public let rows: [HomeHistoryRow]
    public let isHistoryEmpty: Bool

    public init(statistics: (totalCount: Int, winCount: Int, currentCapital: Double),
                configuredCapital: Double,
                records: [TrainingRecord],
                hasPending: Bool,
                hasCachedSets: Bool,
                timeZone: TimeZone = .current) {
        // 统计栏 §6.1.1
        self.totalSessions = "\(statistics.totalCount) 局"   // M2：N 取 statistics.totalCount，非 rows.count
        self.winRate = Self.formatWinRate(winCount: statistics.winCount, totalCount: statistics.totalCount)
        // D13：回退判据 = totalCount==0（与 coordinator.startingCapital 字面一致），>0 无条件显示 currentCapital
        let capitalToShow = statistics.totalCount == 0 ? configuredCapital : statistics.currentCapital
        self.totalCapital = Self.formatCapital(capitalToShow)
        // 按钮 §6.1.2
        self.isResuming = hasPending
        self.primaryActionLabel = hasPending ? "继续训练" : "开始训练"
        self.hasCachedSets = hasCachedSets
        // 历史列表 §6.1.3 —— D12 compactMap 跳 nil-id；D10 排序 createdAt desc + id desc 兜底
        let valid: [(id: Int64, record: TrainingRecord)] = records.compactMap { record in
            record.id.map { (id: $0, record: record) }
        }
        let sorted = valid.sorted { lhs, rhs in
            lhs.record.createdAt != rhs.record.createdAt
                ? lhs.record.createdAt > rhs.record.createdAt
                : lhs.id > rhs.id
        }
        self.rows = sorted.map { Self.makeRow(id: $0.id, record: $0.record, timeZone: timeZone) }
        self.isHistoryEmpty = self.rows.isEmpty
    }

    // MARK: - 纯格式化 static 函数（自包含）

    /// D2/D7：胜率整数百分比。totalCount==0 → "—"（U+2014）。否则 winCount/totalCount×100，
    /// `.rounded()` = `.toNearestOrAwayFromZero`（半数远离零）。
    static func formatWinRate(winCount: Int, totalCount: Int) -> String {
        guard totalCount > 0 else { return "—" }
        let pct = (Double(winCount) / Double(totalCount) * 100).rounded()
        return "\(Int(pct))%"
    }

    /// D3：¥ + 一空格 + POSIX 千分位 + 强制 2 位小数。
    static func formatCapital(_ value: Double) -> String {
        "¥ \(groupedDecimal(value))"
    }

    /// POSIX 千分位 + 2 位小数（无 ¥）。Locale 中性（强制英文逗号），NaN/Inf 兜底 %.2f。
    static func groupedDecimal(_ value: Double) -> String {
        let fmt = NumberFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.numberStyle = .decimal
        fmt.usesGroupingSeparator = true
        fmt.groupingSeparator = ","
        fmt.decimalSeparator = "."
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        return fmt.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// D4：name（code），全角括号 U+FF08/U+FF09。
    static func formatStock(name: String, code: String) -> String {
        "\(name)（\(code)）"
    }

    /// 年 + 零填充月 + "月"。
    static func formatStartMonth(year: Int, month: Int) -> String {
        "\(year)年\(String(format: "%02d", month))月"
    }

    /// D5：epoch 秒 → "yyyy-MM-dd HH:mm"，POSIX locale + 注入 timeZone。
    static func formatDateTime(epochSeconds: Int64, timeZone: TimeZone) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    }

    /// D8：profit符号 + "¥ " + 千分位(|profit|) + "（" + rate符号 + (|rate|×100, 2 位) + "%）"。
    /// profit 与 returnRate 符号各自独立按 ==0→"+"（含 -0.0）归一化（IEEE：-0.0 < 0 为 false）。
    static func formatProfitAndRate(profit: Double, returnRate: Double) -> String {
        let profitPart = "\(signChar(profit))¥ \(groupedDecimal(abs(profit)))"
        let ratePart = "\(signChar(returnRate))\(String(format: "%.2f", abs(returnRate) * 100))%"
        return "\(profitPart)（\(ratePart)）"
    }

    /// signed-zero 安全：-0.0 < 0 == false → "+"。
    static func signChar(_ value: Double) -> String { value < 0 ? "-" : "+" }

    /// D9：色语义据 profit（非 returnRate）。-0.0 落 .zero。
    static func profitSign(_ profit: Double) -> ProfitSign {
        if profit > 0 { return .positive }
        if profit < 0 { return .negative }
        return .zero
    }

    static func makeRow(id: Int64, record: TrainingRecord, timeZone: TimeZone) -> HomeHistoryRow {
        HomeHistoryRow(
            id: id,
            dateTime: formatDateTime(epochSeconds: record.createdAt, timeZone: timeZone),
            stock: formatStock(name: record.stockName, code: record.stockCode),
            startMonth: formatStartMonth(year: record.startYear, month: record.startMonth),
            totalCapital: formatCapital(record.totalCapital),
            profitAndRate: formatProfitAndRate(profit: record.profit, returnRate: record.returnRate),
            sign: profitSign(record.profit))
    }
}
```

- [ ] **Step 4：跑测试确认全绿**

Run: `cd ios/Contracts && swift test --filter HomeContentTests 2>&1 | tail -5`
Expected: `HomeContent host tests` 套件全 `passed`，`0 failures`。若任一精确串断言失败（如 dateTime/winRate 边界），按实际 toolchain 输出修正期望并复跑（不放宽断言，先核对实现）。

- [ ] **Step 5：commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/UI/HomeContentTests.swift
git commit -m "feat(U1): HomeContent 纯值 + 格式化（统计栏/历史/按钮/缓存态）"
```

---

## Task 2：`HomeView` SwiftUI shell

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift`

> 无 host 单测（SwiftUI 壳，沿用 U3/U4/U5/U6）：靠 host `swift build` 编译 + Task 3 的 Catalyst build-for-testing + `#Preview` 视觉自检守护。

- [ ] **Step 1：写 `HomeView.swift`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift
// Spec: kline_trainer_plan_v1.5.md §6.1 L849-899 + docs/superpowers/specs/2026-06-07-wave2-u1-home-view-design.md
//
// 薄 SwiftUI shell：消费 HomeContent + 4 注入导航意图闭包，渲染首页四区（统计栏/开始·继续/历史列表/齿轮）。
// 无业务逻辑，不 import coordinator/settings/acceptance（view-only，D1）。
//
// 决议：
// - D1 view-only；coordinator 接线/路由归顺位 11
// - D6 点击历史行只 fire onSelectRecord(id)；U6 sheet + 复盘/再来一次 路由归顺位 11
// - D11 空缓存提示 inline .alert（hasCachedSets==false 且非 resuming）
// - 闭包不加 @Sendable（沿用 U6 D9，SwiftUI 主线程调用）
// - SwiftUI 跨 iOS17/macOS14/Catalyst 原生，不加 #if canImport(UIKit)（沿用 U6 D1）

import SwiftUI

public struct HomeView: View {
    private let content: HomeContent
    private let onStartTraining: () -> Void
    private let onContinueTraining: () -> Void
    private let onSelectRecord: (Int64) -> Void
    private let onOpenSettings: () -> Void

    @State private var showEmptyCacheAlert = false

    public init(content: HomeContent,
                onStartTraining: @escaping () -> Void,
                onContinueTraining: @escaping () -> Void,
                onSelectRecord: @escaping (Int64) -> Void,
                onOpenSettings: @escaping () -> Void) {
        self.content = content
        self.onStartTraining = onStartTraining
        self.onContinueTraining = onContinueTraining
        self.onSelectRecord = onSelectRecord
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 16) {
            statsBar
            primaryButton
            historyList
        }
        .padding()
        .alert("暂无可用训练数据，请先在设置中下载离线缓存",
               isPresented: $showEmptyCacheAlert) {
            Button("好", role: .cancel) {}
        }
    }

    // §6.1.1 统计栏 + §6.1.4 右上角齿轮
    private var statsBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("总局次：\(content.totalSessions)")
                Text("胜率：\(content.winRate)")
                Text("总资金：\(content.totalCapital)")
            }
            .font(.subheadline)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").font(.title2)
            }
            .accessibilityLabel("设置")
        }
    }

    // §6.1.2 开始/继续训练按钮（单一主 CTA → borderedProminent；与 U6 leaf-sheet sibling 钮语境不同）
    private var primaryButton: some View {
        Button(action: handlePrimaryAction) {
            Text(content.primaryActionLabel)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
    }

    private func handlePrimaryAction() {
        if content.isResuming {
            onContinueTraining()           // 继续从 pending 恢复，不查 cache
        } else if content.hasCachedSets {
            onStartTraining()
        } else {
            showEmptyCacheAlert = true     // D11 空缓存提示
        }
    }

    // §6.1.3 历史列表（可滚动；空 → 占位）
    @ViewBuilder
    private var historyList: some View {
        if content.isHistoryEmpty {
            Text("暂无训练记录")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(content.rows) { row in
                Button {
                    onSelectRecord(row.id)   // D6 仅 fire 意图，不 present sheet
                } label: {
                    historyRow(row)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func historyRow(_ row: HomeHistoryRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.dateTime).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(row.stock).font(.subheadline.bold())
            }
            HStack {
                Text(row.startMonth).font(.caption)
                Spacer()
                Text(row.totalCapital).font(.caption)
            }
            Text(row.profitAndRate)
                .font(.subheadline)
                .foregroundStyle(color(for: row.sign))   // A 股红涨绿跌 §6.1.3
        }
        .padding(.vertical, 4)
    }

    private func color(for sign: ProfitSign) -> Color {
        switch sign {
        case .positive: return .red
        case .negative: return .green
        case .zero: return .primary
        }
    }
}

// MARK: - DEBUG-only preview fixture（fileprivate 文件作用域，沿用 U3/U6 D11，不污染 PreviewFakes）

#if DEBUG
fileprivate extension HomeContent {
    static func preview(hasPending: Bool = true, hasCachedSets: Bool = true,
                        records: [TrainingRecord]) -> HomeContent {
        HomeContent(
            statistics: (totalCount: records.count, winCount: 2, currentCapital: 108_900.00),
            configuredCapital: 100_000, records: records,
            hasPending: hasPending, hasCachedSets: hasCachedSets,
            timeZone: TimeZone(identifier: "Asia/Shanghai") ?? .current)
    }
}

private func previewRecords() -> [TrainingRecord] {
    [
        TrainingRecord(id: 1, trainingSetFilename: "a.sqlite", createdAt: 1_710_532_800,
                       stockCode: "600519", stockName: "贵州茅台", startYear: 2021, startMonth: 8,
                       totalCapital: 102_345.67, profit: 2_345.67, returnRate: 0.0234, maxDrawdown: -0.0832,
                       buyCount: 4, sellCount: 3,
                       feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), finalTick: 1000),
        TrainingRecord(id: 2, trainingSetFilename: "b.sqlite", createdAt: 1_710_000_000,
                       stockCode: "000001", stockName: "平安银行", startYear: 2022, startMonth: 11,
                       totalCapital: 98_765.43, profit: -1_234.57, returnRate: -0.0123, maxDrawdown: -0.0501,
                       buyCount: 2, sellCount: 2,
                       feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), finalTick: 800),
    ]
}

#Preview("有历史 + 继续训练") {
    HomeView(content: .preview(records: previewRecords()),
             onStartTraining: {}, onContinueTraining: {}, onSelectRecord: { _ in }, onOpenSettings: {})
}

#Preview("空历史 + 空缓存") {
    HomeView(content: .preview(hasPending: false, hasCachedSets: false, records: []),
             onStartTraining: {}, onContinueTraining: {}, onSelectRecord: { _ in }, onOpenSettings: {})
}
#endif
```

- [ ] **Step 2：host 编译验证**

Run: `cd ios/Contracts && swift build 2>&1 | tail -3`
Expected: `Build complete!`（无 strict-concurrency / 类型错误）。

- [ ] **Step 3：commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift
git commit -m "feat(U1): HomeView SwiftUI shell（统计栏/开始继续/历史/齿轮 + 注入意图）"
```

---

## Task 3：验证 + acceptance 文档

**Files:**
- Create: `docs/acceptance/2026-06-07-wave2-u1-home-view.md`

- [ ] **Step 1：全套件 host 测试绿**

Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: `Test run with <N> tests in <M> suites passed`，`0 failures`（N ≥ 716 baseline + 新增）。

- [ ] **Step 2：Mac Catalyst build-for-testing（CI 同款命令本地预跑，de-risk）**

Run:
```bash
cd ios/Contracts && xcodebuild build-for-testing \
  -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -5
```
Expected: `** TEST BUILD SUCCEEDED **`（HomeView SwiftUI 在 Catalyst 编译 + 链接通过）。

- [ ] **Step 3：view-only 守卫 grep**

Run:
```bash
grep -nE "TrainingSessionCoordinator|SettingsStore|DownloadAcceptanceRunner" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift \
  ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift; echo "exit=$?"
```
Expected: 无输出，`exit=1`（HomeView/HomeContent 不引用任何运行时依赖，view-only D1 成立）。

- [ ] **Step 4：写 acceptance 文档**（内容见下方「附：验收清单」整段，落盘到 `docs/acceptance/2026-06-07-wave2-u1-home-view.md`）

- [ ] **Step 5：commit**

```bash
git add docs/acceptance/2026-06-07-wave2-u1-home-view.md docs/superpowers/plans/2026-06-07-wave2-u1-home-view.md
git commit -m "docs(U1): 验收清单 + 实施计划"
```

---

## 附：验收清单（落盘到 `docs/acceptance/2026-06-07-wave2-u1-home-view.md`）

```markdown
# 验收清单 — Wave 2 顺位 8：U1 HomeView（view-only shell）

**PR 性质**：业务模块（iOS UI 展示层）。新增 `HomeContent`（纯值格式化）+ `HomeView`（薄 SwiftUI 壳）；coordinator 接线/路由归顺位 11。
**改动文件**：3 个 `.swift`（2 生产 + 1 测试）+ 1 plan + 1 spec + 1 本验收文档。无既有文件改动。
**执行方式**：每项「操作 / 期望 / 判定」。非编码人员逐项照命令执行、对照期望勾选 ☐。`swift`/`xcodebuild` 命令在 `ios/Contracts` 目录下运行。

## 一、总闸门

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | `cd ios/Contracts && swift build 2>&1 \| tail -2` | 末行 `Build complete!` | ☐ |
| 2 | `cd ios/Contracts && swift test 2>&1 \| tail -2` | 末行 `Test run with <N> tests in <M> suites passed`，含 `0 failures` | ☐ |
| 3 | `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 \| tail -3` | 出现 `** TEST BUILD SUCCEEDED **` | ☐ |
| 4 | `grep -n "fatalError\|TODO\|FIXME" ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift; echo "exit=$?"` | 无输出，`exit=1`（无占位） | ☐ |

## 二、view-only 守卫

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 5 | `grep -nE "TrainingSessionCoordinator\|SettingsStore\|DownloadAcceptanceRunner" ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift; echo "exit=$?"` | 无输出，`exit=1`（不引用运行时依赖，D1） | ☐ |
| 6 | `grep -cE "^import SwiftUI" ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift` | 输出 `0`（HomeContent 无 `import SwiftUI` 语句；锚 `^import` 排除注释假匹配） | ☐ |

## 三、统计栏 / 按钮逐项（定向测试）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 7 | `cd ios/Contracts && swift test --filter winRateZeroGames 2>&1 \| tail -3` | `passed`（totalCount==0 胜率显示「—」非 0%） | ☐ |
| 8 | `cd ios/Contracts && swift test --filter winRateHalfBoundaryDiscriminates 2>&1 \| tail -3` | `passed`（1/8→13%、5/8→63%，锁 toNearestOrAwayFromZero） | ☐ |
| 9 | `cd ios/Contracts && swift test --filter totalCapitalZeroGameFallback 2>&1 \| tail -3` 与 `swift test --filter totalCapitalClearedSessionNoFallback 2>&1 \| tail -3` | 均 `passed`（零局回退「初始 10 万」；清零局不回退显示 ¥ 0.00） | ☐ |
| 10 | `cd ios/Contracts && swift test --filter buttonResuming 2>&1 \| tail -3` 与 `swift test --filter buttonStart 2>&1 \| tail -3` | 均 `passed`（有 pending→继续训练；无→开始训练） | ☐ |

## 四、历史列表逐项

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 11 | `cd ios/Contracts && swift test --filter historySorted 2>&1 \| tail -3` | `passed`（createdAt 从新到旧 + 同时间 id desc 兜底） | ☐ |
| 12 | `cd ios/Contracts && swift test --filter nilIdRecordSkipped 2>&1 \| tail -3` 与 `swift test --filter totalSessionsSourceIsolation 2>&1 \| tail -3` | 均 `passed`（id==nil 记录跳过不崩；总局次取 statistics 与 rows.count 解耦） | ☐ |
| 13 | `cd ios/Contracts && swift test --filter "profitAndRate" 2>&1 \| tail -4` | 全 `passed`（正/负/双零/混合零/ULP 精确串，红涨绿跌符号正确） | ☐ |
| 14 | `cd ios/Contracts && swift test --filter rowDateTimeCrossTimezone 2>&1 \| tail -3` | `passed`（同 createdAt 在 UTC 与 +8 落不同日期/小时，时区参数真生效） | ☐ |

## 五、视觉自检（可选，需 Xcode）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 15 | 在 Xcode 打开 `HomeView.swift`，运行 Canvas 预览「有历史 + 继续训练」 | 统计栏三字段 + 右上角齿轮 + 「继续训练」按钮 + 两条历史（茅台正红、平安银行负绿） | ☐ |
| 16 | 运行 Canvas 预览「空历史 + 空缓存」 | 「开始训练」按钮 + 居中「暂无训练记录」占位 | ☐ |
```

---

## Self-Review（writing-plans 自检）

**1. Spec 覆盖**：§6.1.1 统计栏（Task1 winRate/totalCapital/totalSessions）✓；§6.1.2 开始·继续 + 空缓存提示（Task1 button + Task2 alert）✓；§6.1.3 历史列表 6 字段 + 排序 + 点击行 + 红涨绿跌（Task1 rows + Task2 historyRow/onSelectRecord）✓；§6.1.4 齿轮（Task2 statsBar）✓；设计 D1-D13 全部有对应 Task/测试。

**2. Placeholder 扫描**：无 TBD/TODO；每步含完整代码 + 精确命令 + 期望输出。

**3. 类型一致**：`HomeContent`/`HomeHistoryRow`/`ProfitSign` 定义（Task1）与 `HomeView` 消费（Task2）签名一致；`onSelectRecord: (Int64)->Void` 与 `HomeHistoryRow.id: Int64` 一致；`formatWinRate`/`formatCapital`/`formatProfitAndRate`/`profitSign` 调用与定义一致。

**4. 已知风险**：dateTime/winRate 精确串依赖本机 toolchain，Task1 Step4 要求实测核对（TDD 安全网）；`.borderedProminent` 主 CTA 选择已注明与 U6 leaf-sheet 语境差异。

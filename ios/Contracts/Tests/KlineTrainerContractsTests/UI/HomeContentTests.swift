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

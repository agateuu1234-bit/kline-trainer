// E5a TrainingEngine 核心测试（Wave 2 顺位 2）
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite struct TrainingEngineCoreTests {

    static let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)

    /// closes[i] 对应 globalIndex==endGlobalIndex==i 的一根 period K 线。默认 .m3（驱动周期，R4-F2）。
    static func candles(_ closes: [Double], period: Period = .m3) -> [Period: [KLineCandle]] {
        let arr = closes.enumerated().map { (i, c) in
            KLineCandle(period: period, datetime: Int64(i) * 3600,
                        open: c, high: c, low: c, close: c,
                        volume: 1, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: i, endGlobalIndex: i)
        }
        return [period: arr]
    }

    static func normalEngine(closes: [Double] = [10, 11, 12, 13, 14],
                             cash: Double = 100_000,
                             capital: Double = 100_000,
                             position: PositionManager = .init()) -> TrainingEngine {
        TrainingEngine(
            flow: NormalFlow(fees: fees, maxTick: closes.count - 1),
            allCandles: candles(closes),
            maxTick: closes.count - 1,
            initialCapital: capital,
            initialCashBalance: cash,
            initialPosition: position)
    }

    @Test func initWiresRuntimeState() {
        let e = Self.normalEngine()
        #expect(e.cashBalance == 100_000)
        #expect(e.initialCapital == 100_000)
        #expect(e.position.shares == 0)
        #expect(e.markers.isEmpty)
        #expect(e.drawings.isEmpty)
        #expect(e.tradeOperations.isEmpty)
        #expect(e.tick.globalTickIndex == 0)            // NormalFlow.initialTick == 0
        #expect(e.upperPanel.period == .m60)            // D7：上区 60m
        #expect(e.lowerPanel.period == .daily)          // D7：下区 日线
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.fees.commissionRate == Self.fees.commissionRate)  // D1：派生自 flow.feeSnapshot
    }

    @Test func initPreservesInjectedState() {
        let pos = PositionManager(shares: 200, averageCost: 10, totalInvested: 2000)
        let e = Self.normalEngine(cash: 98_000, position: pos)
        #expect(e.position.shares == 200)
        #expect(e.cashBalance == 98_000)
    }

    @Test func freshSessionSeedsDrawdownPeakFromStartingCapital() {
        // codex R2-F1：fresh 局 peak 须 seeding 为起始总资金，否则首次 update 低报回撤。
        let e = Self.normalEngine(closes: [10], cash: 100_000, capital: 100_000)  // 空仓，起始价 10
        #expect(e.drawdown.peakCapital == 100_000)   // 非 0
        #expect(e.drawdown.maxDrawdown == 0)
    }

    @Test func freshSessionSeedPeakIncludesInitialPositionValue() {
        // 起始带仓：startTotal = 现金 + 持仓市值（200 股 × 10）= 100_000
        let pos = PositionManager(shares: 200, averageCost: 9, totalInvested: 1800)
        let e = Self.normalEngine(closes: [10], cash: 98_000, capital: 100_000, position: pos)
        #expect(e.drawdown.peakCapital == 100_000)
    }

    @Test func resumeReconcilesDrawdownToCurrentTotal() {
        // resume：携带 peak 130k / maxDD 12k；重建起始总资金 100k → 当前回撤 30k > 12k。
        // peak 取 max 保留 130k；maxDrawdown 经 update 纠正为 30k（codex R5-F1，避免低报）。
        let dd = DrawdownAccumulator(peakCapital: 130_000, maxDrawdown: 12_000)
        let e = TrainingEngine(flow: NormalFlow(fees: Self.fees, maxTick: 0),
                               allCandles: Self.candles([10]),
                               maxTick: 0, initialCapital: 100_000,
                               initialCashBalance: 90_000,
                               initialPosition: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000),
                               initialDrawdown: dd)
        #expect(e.drawdown.peakCapital == 130_000)   // max(130_000, 100_000, 90_000 + 1000*10 = 100_000)
        #expect(e.drawdown.maxDrawdown == 30_000)    // 130_000 − 100_000（并入当前回撤）
    }

    @Test func drawdownSeedsAtLeastDeclaredInitialCapital() {
        // R6-F3：起始总资金(95k) < 声明初始资金(100k) → peak seeding 到 initialCapital，当前回撤 5k 计入。
        let e = TrainingEngine(flow: NormalFlow(fees: Self.fees, maxTick: 0),
                               allCandles: Self.candles([10]),
                               maxTick: 0, initialCapital: 100_000,
                               initialCashBalance: 85_000,
                               initialPosition: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        // startTotal = 85_000 + 1000*10 = 95_000 < initialCapital 100_000
        #expect(e.drawdown.peakCapital == 100_000)   // 非 95_000（含声明基线）
        #expect(e.drawdown.maxDrawdown == 5_000)     // 100_000 − 95_000
    }

    @Test func resumeRestoresSavedPanelCombo() {
        // R6：resume 传入保存的周期组合 → 面板用之，非默认 60m/日线
        let e = TrainingEngine(flow: NormalFlow(fees: Self.fees, maxTick: 2),
                               allCandles: Self.candles([10, 11, 12]),
                               maxTick: 2, initialCapital: 100_000, initialCashBalance: 100_000,
                               initialUpperPeriod: .m15, initialLowerPeriod: .m60)
        #expect(e.upperPanel.period == .m15)
        #expect(e.lowerPanel.period == .m60)
    }
}

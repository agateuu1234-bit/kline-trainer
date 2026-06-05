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

    @Test func currentTotalCapitalFlatEqualsCash() {
        let e = Self.normalEngine(closes: [10, 11, 12], cash: 100_000)
        // 空仓 → 总资金 == 现金（市值 0）
        #expect(e.currentTotalCapital == 100_000)
    }

    @Test func currentTotalCapitalAddsMarketValueAtCurrentPrice() {
        // tick 起点 0 → 现价 = candles[0].close == 10；持仓 200 股
        let pos = PositionManager(shares: 200, averageCost: 9, totalInvested: 1800)
        let e = Self.normalEngine(closes: [10, 11, 12], cash: 98_200, position: pos)
        // 98_200 现金 + 200*10 市值 = 100_200
        #expect(e.currentTotalCapital == 100_200)
    }

    @Test func returnRateIsNetRatioOverInitialCapital() {
        let pos = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000)
        let e = Self.normalEngine(closes: [10, 11, 12], cash: 99_000,
                                  capital: 100_000, position: pos)
        // 总资金 99_000 + 100*10 = 100_000 → returnRate 0
        #expect(e.returnRate == 0)
    }

    @Test func returnRateNonZeroAndZeroInitialCapitalGuard() {
        // 正收益：总资金 150k vs 初始 100k → returnRate 0.5（精确可表示）
        let gain = TrainingEngine(flow: NormalFlow(fees: Self.fees, maxTick: 2),
                                  allCandles: Self.candles([10, 11, 12]),
                                  maxTick: 2, initialCapital: 100_000,
                                  initialCashBalance: 100_000,
                                  initialPosition: PositionManager(shares: 5000, averageCost: 10, totalInvested: 50_000))
        // tick 0 现价 10；总资金 = 100_000 + 5000*10 = 150_000 → returnRate 0.5
        #expect(gain.returnRate == 0.5)
        // initialCapital == 0 → guard 返回 0（不除零）
        let zero = TrainingEngine(flow: NormalFlow(fees: Self.fees, maxTick: 0),
                                  allCandles: Self.candles([10]),
                                  maxTick: 0, initialCapital: 0, initialCashBalance: 0)
        #expect(zero.returnRate == 0)
    }

    @Test func holdingCostDelegatesToPosition() {
        let pos = PositionManager(shares: 300, averageCost: 12, totalInvested: 3600)
        let e = Self.normalEngine(position: pos)
        #expect(e.holdingCost == 3600)   // 12 * 300
    }

    @Test func maxDrawdownIsAbsoluteAmountPerSpec() {
        // modules L510：accumulator.maxDrawdown = 非负绝对额（元），运行时形态；
        // 比率换算是 E6 finalize 职责（D3），本 accessor 不换算。
        // 取 peak 108k 与起始总资金 100k 一致（dd 恰 8k），使 init update 不改值，聚焦「绝对元」断言。
        let dd = DrawdownAccumulator(peakCapital: 108_000, maxDrawdown: 8_000)
        let e = TrainingEngine(flow: NormalFlow(fees: Self.fees, maxTick: 2),
                               allCandles: Self.candles([10, 11, 12]),
                               maxTick: 2, initialCapital: 100_000,
                               initialCashBalance: 100_000, initialDrawdown: dd)
        #expect(e.maxDrawdown == 8_000)     // 元（绝对额），非比率（108_000 − 100_000）
        #expect(e.maxDrawdown >= 0)         // 非负不变量
    }

    @Test func reviewModeStartsAtFinalTick() {
        let record = Self.previewRecordForTest()   // finalTick 2
        // R4-F1：ReviewFlow.allowedTickRange = finalTick...finalTick → engine maxTick 必须 == finalTick
        let e = TrainingEngine(flow: ReviewFlow(record: record),
                               allCandles: Self.candles([10, 11, 12]),
                               maxTick: 2, initialCapital: 100_000,
                               initialCashBalance: 50_000,
                               initialPosition: PositionManager(shares: 100, averageCost: 10, totalInvested: 1000))
        #expect(e.tick.globalTickIndex == record.finalTick)   // D5：复盘起于末态（无 clamp）
    }

    @Test func currentPriceUsesM3DrivingSeriesNotAggregate() {
        // .m3 at tick 0 close = 10；另塞一根合法 .m60 聚合（endGlobalIndex 2, close 99 = 段末未来价）。
        // 现价/总资金必须取 .m3 的 10，而非聚合 99（codex R4-F2）。
        let m3 = Self.candles([10, 11, 12])[.m3]!     // endGlobalIndex 0,1,2
        let m60 = [KLineCandle(period: .m60, datetime: 0, open: 99, high: 99, low: 99, close: 99,
                               volume: 1, amount: nil, ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                               macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: 0, endGlobalIndex: 2)]
        let pos = PositionManager(shares: 100, averageCost: 5, totalInvested: 500)
        let e = TrainingEngine(flow: NormalFlow(fees: Self.fees, maxTick: 2),
                               allCandles: [.m3: m3, .m60: m60],
                               maxTick: 2, initialCapital: 100_000,
                               initialCashBalance: 99_500, initialPosition: pos)
        #expect(e.currentTotalCapital == 100_500)     // 99_500 + 100×10(.m3)，非 +100×99(聚合)
    }

    @Test func resumeNormalModeUsesSavedTickForPrice() {
        // R6-F1：resume normal 局从保存 tick(2) 起、非 0；R6-F2：m3 覆盖到 maxTick。
        // 现价 = tick 2 的 .m3 close = 12；持仓 1000 股。
        let e = TrainingEngine(flow: NormalFlow(fees: Self.fees, maxTick: 2),
                               allCandles: Self.candles([10, 11, 12]),
                               maxTick: 2, initialTick: 2,
                               initialCapital: 100_000, initialCashBalance: 88_000,
                               initialPosition: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        #expect(e.tick.globalTickIndex == 2)          // 用 saved tick，非 NormalFlow.initialTick(0)
        #expect(e.currentTotalCapital == 100_000)     // 88_000 + 1000 × 12（tick 2 现价）
    }

    @Test func onSceneActivatedIsSafeAndPure() {
        let e = Self.normalEngine(closes: [10, 11, 12])
        let beforeTick = e.tick.globalTickIndex
        let beforeCash = e.cashBalance
        e.onSceneActivated()                 // 中继到两个 animator.resetOnSceneActive()
        // 场景中继不改运行时业务状态
        #expect(e.tick.globalTickIndex == beforeTick)
        #expect(e.cashBalance == beforeCash)
        #expect(e.position.shares == 0)
    }

    @Test func previewBuildsAllModes() {
        let n = TrainingEngine.preview(mode: .normal)
        #expect(n.flow.mode == .normal)
        #expect(n.currentTotalCapital == 100_000)        // 空仓 → 现金 100k
        let r = TrainingEngine.preview(mode: .review)
        #expect(r.flow.mode == .review)
        #expect(r.flow.canBuySell() == false)            // review 关闭买卖（flow 能力，非 E5a accessor）
        let p = TrainingEngine.preview(mode: .replay)
        #expect(p.flow.mode == .replay)
    }

    @Test func previewMaxTickMatchesFixtureRange() {
        // codex R3-F2：preview 的 maxTick 必须 == fixture 末根 endGlobalIndex，tick 不越界。
        let e = TrainingEngine.preview(mode: .normal)
        #expect(e.tick.maxTick == 7)         // 8 根 candle（endGlobalIndex 0..7）→ maxTick 7
    }

    @Test func previewFixtureCandlePeriodsMatchKeys() {
        // codex R4-F3：fixture 每根 candle.period 必须 == 其 dict key，且含非空 .m3 驱动序列。
        let e = TrainingEngine.preview(mode: .normal)
        for (period, list) in e.allCandles {
            for c in list { #expect(c.period == period) }
        }
        #expect(e.allCandles[.m3]?.isEmpty == false)
    }

    @Test func previewProvidesCandlesForDefaultPanels() {
        // codex R5-F2：preview 必须为 engine 默认面板周期（.m60 上 / .daily 下）提供非空数据。
        let e = TrainingEngine.preview(mode: .normal)
        #expect(e.allCandles[e.upperPanel.period]?.isEmpty == false)   // .m60
        #expect(e.allCandles[e.lowerPanel.period]?.isEmpty == false)   // .daily
    }

    @Test func previewDefaultsToNormal() {
        #expect(TrainingEngine.preview().flow.mode == .normal)
    }

    @Test func makeThrowsOnMissingM3() {
        // Stage6 F1：空/缺 .m3 → 可恢复 AppError.trainingSet(.emptyData)，非 trap
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try TrainingEngine.make(.normal(fees: Self.fees, maxTick: 0),
                                    allCandles: [:],
                                    initialCapital: 100_000, initialCashBalance: 100_000)
        }
    }

    @Test func makeThrowsOnInsufficientCoverage() {
        // Stage6 F1：.m3 末根 endGlobalIndex 1 < maxTick 5 → 可恢复抛
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try TrainingEngine.make(.normal(fees: Self.fees, maxTick: 5),
                                    allCandles: Self.candles([10, 11]),
                                    initialCapital: 100_000, initialCashBalance: 100_000)
        }
    }

    @Test func makeThrowsOnStalePendingTick() {
        // Stage6 R3-F1：resume tick(99) 超出（被替换的更短训练组）→ 可恢复抛
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try TrainingEngine.make(.normal(fees: Self.fees, maxTick: 2),
                                    allCandles: Self.candles([10, 11, 12]), initialTick: 99,
                                    initialCapital: 100_000, initialCashBalance: 100_000)
        }
    }

    @Test func makeThrowsOnNegativeMaxTick() {
        // Stage6 R3/R8-F1：损坏/不一致 maxTick(-1) → 可恢复抛（工厂内先验 maxTick 再建 flow，结构上不 trap）
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try TrainingEngine.make(.normal(fees: Self.fees, maxTick: -1),
                                    allCandles: Self.candles([10]),
                                    initialCapital: 100_000, initialCashBalance: 100_000)
        }
    }

    @Test func makeThrowsOnNegativeMaxTickReplay() {
        // Stage6 R8-F1：ReplayFlow 同路径——负 maxTick 由工厂先验拦下，不 trap
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try TrainingEngine.make(.replay(fees: Self.fees, maxTick: -1),
                                    allCandles: Self.candles([10]),
                                    initialCapital: 100_000, initialCashBalance: 100_000)
        }
    }

    @Test func makeThrowsOnUnsortedM3() {
        // Stage6 R4/R5-F1：.m3 endGlobalIndex [0,2,1,3] 非连续/乱序（破坏二分定价）→ 可恢复抛
        func c(_ end: Int) -> KLineCandle {
            KLineCandle(period: .m3, datetime: 0, open: 10, high: 10, low: 10, close: 10,
                        volume: 1, amount: nil, ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: end, endGlobalIndex: end)
        }
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try TrainingEngine.make(.normal(fees: Self.fees, maxTick: 3),
                                    allCandles: [.m3: [c(0), c(2), c(1), c(3)]],
                                    initialCapital: 100_000, initialCashBalance: 100_000)
        }
    }

    @Test func makeThrowsOnGappedM3() {
        // Stage6 R5-F1：.m3 轴有 gap [0,10]（maxTick 10）→ tick 1..9 会被二分定到未来 candle(10)→可恢复抛
        func c(_ end: Int) -> KLineCandle {
            KLineCandle(period: .m3, datetime: 0, open: 10, high: 10, low: 10, close: 10,
                        volume: 1, amount: nil, ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: end, endGlobalIndex: end)
        }
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try TrainingEngine.make(.normal(fees: Self.fees, maxTick: 10),
                                    allCandles: [.m3: [c(0), c(10)]],
                                    initialCapital: 100_000, initialCashBalance: 100_000)
        }
    }

    @Test func makeThrowsOnNonFiniteMoney() {
        // Stage6 R4-F2：resume cash = NaN → 可恢复抛（防污染总资金/收益率/回撤）
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try TrainingEngine.make(.normal(fees: Self.fees, maxTick: 2),
                                    allCandles: Self.candles([10, 11, 12]),
                                    initialCapital: 100_000, initialCashBalance: .nan)
        }
    }

    @Test func makeThrowsOnMissingPanelData() {
        // Stage6 R6-F1：.m3-only 数据 + 默认面板 .m60/.daily（无 candle）→ 可恢复抛
        // （防 buildRenderState 的 allCandles[panel.period]! 强解包崩溃）
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try TrainingEngine.make(.normal(fees: Self.fees, maxTick: 2),
                                    allCandles: Self.candles([10, 11, 12]),
                                    initialCapital: 100_000, initialCashBalance: 100_000)
            // 默认 initialUpperPeriod .m60 / initialLowerPeriod .daily 无数据 → throw
        }
    }

    @Test func makeSucceedsOnValidData() throws {
        // 面板用 .m3（有数据）使 R6-F1 面板校验通过，聚焦 make 成功路径
        let e = try TrainingEngine.make(.normal(fees: Self.fees, maxTick: 2),
                                        allCandles: Self.candles([10, 11, 12]),
                                        initialCapital: 100_000, initialCashBalance: 100_000,
                                        initialUpperPeriod: .m3, initialLowerPeriod: .m3)
        #expect(e.tick.maxTick == 2)
        #expect(e.currentTotalCapital == 100_000)
    }

    @Test func reviewModeWithM3BeyondFinalTickPricesAtTickNotFuture() {
        // Stage6 F2：review finalTick 2，m3 全集到 endGlobalIndex 5（>maxTick）。引擎构造成功（覆盖足）；
        // 现价用 tick 2 的 close=12，不取未来 13/14/15。未来 candle「不渲染」由 C8(顺位7)
        // 「揭示到 globalTickIndex」机制保证（所有模式同此机制，normal 亦不显未来）。
        let record = Self.previewRecordForTest(finalTick: 2)
        let e = TrainingEngine(flow: ReviewFlow(record: record),
                               allCandles: Self.candles([10, 11, 12, 13, 14, 15]),
                               maxTick: 2, initialCapital: 100_000, initialCashBalance: 50_000,
                               initialPosition: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        #expect(e.tick.globalTickIndex == 2)
        #expect(e.currentTotalCapital == 62_000)   // 50_000 + 1000*12（tick 2，非未来）
    }

    // Review/preview 用最小 TrainingRecord
    static func previewRecordForTest(finalTick: Int = 2) -> TrainingRecord {
        TrainingRecord(id: 1, trainingSetFilename: "t.sqlite", createdAt: 0,
                       stockCode: "000001", stockName: "测试股",
                       startYear: 2020, startMonth: 1,
                       totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                       buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: finalTick)
    }
}

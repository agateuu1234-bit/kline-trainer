// E5b TrainingEngine 交易动作测试（Wave 2 顺位 3）
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite struct TrainingEngineActionsTests {

    static let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)

    /// 单周期(.m3)交易 fixture：双面板都 .m3 → 每个动作步进 1 tick。
    /// closes[i] 对应 globalIndex==endGlobalIndex==i 的一根 .m3 K 线。
    static func tradeEngine(closes: [Double] = [10, 10, 10, 10, 10],
                            cash: Double = 100_000,
                            capital: Double = 100_000,
                            position: PositionManager = .init(),
                            mode: TrainingMode = .normal) -> TrainingEngine {
        let maxTick = closes.count - 1
        let flow: TrainingFlowController = switch mode {
        case .normal: NormalFlow(fees: fees, maxTick: maxTick)
        case .replay: ReplayFlow(feeSnapshotFromOriginal: fees, maxTick: maxTick)
        case .review: ReviewFlow(record: previewRecord(finalTick: maxTick))
        }
        return TrainingEngine(
            flow: flow,
            allCandles: m3Candles(closes),
            maxTick: maxTick,
            initialCapital: capital,
            initialCashBalance: cash,
            initialPosition: position,
            initialUpperPeriod: .m3,
            initialLowerPeriod: .m3)   // R1-M1：双面板都 .m3（与 helper 注释一致），杜绝 .lower 步进落空地雷
    }

    static func m3Candles(_ closes: [Double]) -> [Period: [KLineCandle]] {
        let arr = closes.enumerated().map { (i, c) in
            KLineCandle(period: .m3, datetime: Int64(i) * 180,
                        open: c, high: c, low: c, close: c,
                        volume: 1, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: i, endGlobalIndex: i)
        }
        return [.m3: arr]
    }

    static func previewRecord(finalTick: Int) -> TrainingRecord {
        TrainingRecord(id: 1, trainingSetFilename: "t.sqlite", createdAt: 0,
                       stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 1,
                       totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                       buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: finalTick)
    }

    // MARK: - buyEnabled / sellEnabled

    @Test func buyEnabledTrueWhenAffordable() {
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 100_000, capital: 100_000)
        #expect(e.buyEnabled == true)
    }

    @Test func buyEnabledFalseWhenCashExhausted() {
        // 现金≈0（满仓态 emulation）：任何档 quoteBuy 都 totalCost>cash 失败 → false（disabled）
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 100_000,
                                 position: PositionManager(shares: 10_000, averageCost: 10, totalInvested: 100_000))
        #expect(e.buyEnabled == false)
    }

    @Test func buyEnabledFalseInReviewMode() {
        let e = Self.tradeEngine(cash: 100_000, mode: .review)
        #expect(e.buyEnabled == false)   // canBuySell()==false 短路
    }

    @Test func sellEnabledTrueWhenHolding() {
        let e = Self.tradeEngine(position: PositionManager(shares: 100, averageCost: 10, totalInvested: 1000))
        #expect(e.sellEnabled == true)
    }

    @Test func sellEnabledFalseWhenFlat() {
        let e = Self.tradeEngine(position: .init())
        #expect(e.sellEnabled == false)
    }

    @Test func sellEnabledFalseInReviewMode() {
        let e = Self.tradeEngine(position: PositionManager(shares: 100, averageCost: 10, totalInvested: 1000),
                                 mode: .review)
        #expect(e.sellEnabled == false)
    }

    // MARK: - switchPeriodCombo fixture

    /// 全 6 周期 fixture（switchPeriodCombo 需 target 周期有数据）。
    /// 各周期 endGlobalIndex 覆盖 0...maxEnd；m3 为驱动序列（连续 0..n）。
    static func sixPeriodCandles(m3Count: Int = 8) -> [Period: [KLineCandle]] {
        func c(_ p: Period, idx: Int, end: Int) -> KLineCandle {
            KLineCandle(period: p, datetime: Int64(idx) * 180,
                        open: 10, high: 11, low: 9, close: 10,
                        volume: 1, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: idx, endGlobalIndex: end)
        }
        let m3 = (0..<m3Count).map { c(.m3, idx: $0, end: $0) }
        // 其它周期：每根覆盖一段 m3 tick，末根 endGlobalIndex == m3Count-1（覆盖 maxTick）
        let m15 = [c(.m15, idx: 0, end: 3), c(.m15, idx: 1, end: m3Count - 1)]
        let m60 = [c(.m60, idx: 0, end: 3), c(.m60, idx: 1, end: m3Count - 1)]
        let daily = [c(.daily, idx: 0, end: m3Count - 1)]
        let weekly = [c(.weekly, idx: 0, end: m3Count - 1)]
        let monthly = [c(.monthly, idx: 0, end: m3Count - 1)]
        return [.m3: m3, .m15: m15, .m60: m60, .daily: daily, .weekly: weekly, .monthly: monthly]
    }

    /// 用指定初始组合构造（默认 60m/日，与 spec L777 一致）。
    static func comboEngine(upper: Period = .m60, lower: Period = .daily) -> TrainingEngine {
        let candles = sixPeriodCandles()
        let maxTick = 7
        return TrainingEngine(
            flow: NormalFlow(fees: fees, maxTick: maxTick),
            allCandles: candles, maxTick: maxTick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: upper, initialLowerPeriod: lower)
    }

    // MARK: - switchPeriodCombo

    @Test func switchToLargerMovesComboUp() {
        let e = Self.comboEngine(upper: .m60, lower: .daily)   // index 2
        e.switchPeriodCombo(direction: .toLarger)
        #expect(e.upperPanel.period == .daily)
        #expect(e.lowerPanel.period == .weekly)
    }

    @Test func switchToSmallerMovesComboDown() {
        let e = Self.comboEngine(upper: .m60, lower: .daily)
        e.switchPeriodCombo(direction: .toSmaller)
        #expect(e.upperPanel.period == .m15)
        #expect(e.lowerPanel.period == .m60)
    }

    @Test func switchToLargerAtTopBoundaryNoops() {
        let e = Self.comboEngine(upper: .weekly, lower: .monthly)   // 末组合
        let before = (e.upperPanel.period, e.lowerPanel.period, e.upperPanel.revision)
        e.switchPeriodCombo(direction: .toLarger)
        #expect(e.upperPanel.period == before.0)
        #expect(e.lowerPanel.period == before.1)
        #expect(e.upperPanel.revision == before.2)   // 边界 no-op：无 revision bump
    }

    @Test func switchToSmallerAtBottomBoundaryNoops() {
        let e = Self.comboEngine(upper: .m3, lower: .m15)   // 首组合
        let before = (e.upperPanel.period, e.lowerPanel.period)
        e.switchPeriodCombo(direction: .toSmaller)
        #expect(e.upperPanel.period == before.0)
        #expect(e.lowerPanel.period == before.1)
    }

    @Test func switchResetsPanelsToAutoTrackingAndBumpsRevision() {
        // R2-C1：不能从测试 mutate private(set) panel（@testable 不放开 private setter）。
        // 改证「两面板 revision 自增」= reduce(.periodComboSwitched) 被派发（reducer 内唯一改 revision 的路径）。
        // freeScrolling→autoTracking 完整转换属 C8 集成测试（顺位 7，彼时手势可造 freeScrolling）。
        let e = Self.comboEngine(upper: .m60, lower: .daily)
        let upRev = e.upperPanel.revision, lowRev = e.lowerPanel.revision
        e.switchPeriodCombo(direction: .toLarger)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.lowerPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.revision > upRev)   // periodComboSwitched bump 两面板
        #expect(e.lowerPanel.revision > lowRev)
    }

    @Test func switchDoesNotAdvanceTick() {
        let e = Self.comboEngine(upper: .m60, lower: .daily)
        let tickBefore = e.tick.globalTickIndex
        e.switchPeriodCombo(direction: .toLarger)
        #expect(e.tick.globalTickIndex == tickBefore)
    }

    @Test func switchNoopsWhenTargetPeriodHasNoData() {
        // 构造缺 .weekly 数据的 fixture（toLarger from 60m/日 需要 日/周）
        var candles = Self.sixPeriodCandles()
        candles[.weekly] = nil
        let e = TrainingEngine(flow: NormalFlow(fees: Self.fees, maxTick: 7),
                               allCandles: candles, maxTick: 7,
                               initialCapital: 100_000, initialCashBalance: 100_000,
                               initialUpperPeriod: .m60, initialLowerPeriod: .daily)
        e.switchPeriodCombo(direction: .toLarger)
        #expect(e.upperPanel.period == .m60)   // 守卫 no-op
        #expect(e.lowerPanel.period == .daily)
    }

    // MARK: - holdOrObserve

    @Test func holdOrObserveAdvancesOneTickSamePeriod() {
        let e = Self.tradeEngine(closes: [10, 11, 12, 13])   // 双面板 .m3，步进 1
        e.holdOrObserve(panel: .upper)
        #expect(e.tick.globalTickIndex == 1)
    }

    @Test func holdOrObserveRecordsNoMarkerOrOperation() {
        let e = Self.tradeEngine(closes: [10, 11, 12])
        e.holdOrObserve(panel: .upper)
        #expect(e.markers.isEmpty)
        #expect(e.tradeOperations.isEmpty)
    }

    @Test func holdOrObserveHardSwitchesPanelsToAutoTracking() {
        // R2-C1：证「两面板 revision 自增」= advanceAndAccount 对两面板派发 .tradeTriggered。
        let e = Self.tradeEngine(closes: [10, 11, 12])
        let upRev = e.upperPanel.revision, lowRev = e.lowerPanel.revision
        e.holdOrObserve(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.lowerPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.revision > upRev)
        #expect(e.lowerPanel.revision > lowRev)
    }

    @Test func holdOrObserveNoopsInReviewMode() {
        let e = Self.tradeEngine(closes: [10, 11, 12], mode: .review)
        // review initialTick == finalTick == maxTick == 2
        let before = e.tick.globalTickIndex
        e.holdOrObserve(panel: .upper)
        #expect(e.tick.globalTickIndex == before)   // canAdvance()==false → no-op
    }

    @Test func holdOrObserveUpdatesDrawdownAtNewTick() {
        // 持仓 + 价格下跌：advance 后总资金下降 → maxDrawdown 上升。
        // closes 长度 3 → maxTick=2；只推进到 tick1(<maxTick) 隔离回撤语义，
        // **不触发**局终强平（强平=R1-C1 修复点：tick1≠maxTick 故 forceCloseIfEnded 短路）。
        let e = Self.tradeEngine(closes: [10, 8, 8], cash: 0, capital: 1000,
                                 position: PositionManager(shares: 100, averageCost: 10, totalInvested: 1000))
        // tick0: total = 0 + 100*10 = 1000；advance 到 tick1 价 8：total = 800
        #expect(e.maxDrawdown == 0)
        e.holdOrObserve(panel: .upper)
        #expect(e.tick.globalTickIndex == 1)
        #expect(e.position.shares == 100)   // 未到 maxTick → 未强平
        #expect(e.maxDrawdown == 200)       // peak 1000 - current 800
    }

    @Test func holdOrObserveStepsByClickedPanelPeriod() {
        // 多周期：upper=.m60（首根 end=3），从 tick0 点 upper → 步进到 3
        let e = Self.comboEngine(upper: .m60, lower: .daily)
        e.holdOrObserve(panel: .upper)
        #expect(e.tick.globalTickIndex == 3)   // stepsForPeriod(.m60) = 3 - 0
    }

    // MARK: - buy

    @Test func buySuccessDeductsCashAddsPositionAndAdvances() {
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 100_000, capital: 100_000)
        // tier1 = 20% of 100_000 / 10 = 2000 股；notional 20000；commission max(20000*0.0001=2,5)=5；totalCost 20005
        let r = e.buy(panel: .upper, tier: .tier1)
        guard case .success(let op) = r else { Issue.record("expected success"); return }
        #expect(e.position.shares == 2000)
        #expect(e.cashBalance == 100_000 - 20_005)
        #expect(op.direction == .buy)
        #expect(op.shares == 2000)
        #expect(op.positionTier == .tier1)
        #expect(op.price == 10)
        #expect(op.commission == 5)
        #expect(op.stampDuty == 0)
        #expect(op.totalCost == 20_005)
        #expect(op.globalTick == 0)        // entryTick（advance 前）
        #expect(op.period == .m3)
        #expect(op.createdAt == 0)          // tick0 m3 datetime = 0*180
        #expect(e.tick.globalTickIndex == 1)   // advance 1
    }

    @Test func buyRecordsBuyMarkerAtEntryTick() {
        let e = Self.tradeEngine(closes: [10, 10, 10])
        _ = e.buy(panel: .upper, tier: .tier1)
        #expect(e.markers.count == 1)
        #expect(e.markers[0].direction == .buy)
        #expect(e.markers[0].globalTick == 0)
        #expect(e.markers[0].price == 10)
    }

    @Test func buyUsesEntryTickPriceNotPostAdvancePrice() {
        // 价格在 advance 后变化；成交价必须是 entryTick 价(10)，非 advance 后价(99)
        let e = Self.tradeEngine(closes: [10, 99, 99])
        let r = e.buy(panel: .upper, tier: .tier1)
        guard case .success(let op) = r else { Issue.record("expected success"); return }
        #expect(op.price == 10)
    }

    @Test func buyFailureInsufficientCashLeavesStateUnchanged() {
        // 现金不足买任何一手：cash 50，price 100 → 任何档取整 0 股 或 totalCost>cash
        let e = Self.tradeEngine(closes: [100, 100, 100], cash: 50, capital: 50)
        let before = (e.position.shares, e.cashBalance, e.tick.globalTickIndex)
        let r = e.buy(panel: .upper, tier: .tier1)
        #expect(r == .failure(.trade(.insufficientCash)))
        #expect(e.position.shares == before.0)
        #expect(e.cashBalance == before.1)
        #expect(e.tick.globalTickIndex == before.2)   // 失败不 advance
        #expect(e.markers.isEmpty)
        #expect(e.tradeOperations.isEmpty)
    }

    @Test func buyFailsInReviewModeWithDisabled() {
        let e = Self.tradeEngine(closes: [10, 10, 10], mode: .review)
        let r = e.buy(panel: .upper, tier: .tier1)
        #expect(r == .failure(.trade(.disabled)))
    }

    @Test func buyHardSwitchesBothPanels() {
        // R2-C1：证「两面板 revision 自增」= buy 经 advanceAndAccount 对两面板派发 .tradeTriggered。
        let e = Self.tradeEngine(closes: [10, 10, 10])
        let upRev = e.upperPanel.revision, lowRev = e.lowerPanel.revision
        _ = e.buy(panel: .upper, tier: .tier1)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.lowerPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.revision > upRev)
        #expect(e.lowerPanel.revision > lowRev)
    }

    @Test func buyAppendsTradeOperation() {
        let e = Self.tradeEngine(closes: [10, 10, 10])
        _ = e.buy(panel: .upper, tier: .tier1)
        #expect(e.tradeOperations.count == 1)
        #expect(e.tradeOperations[0].direction == .buy)
    }

    // MARK: - sell

    @Test func sellSuccessAddsCashReducesPositionAndAdvances() {
        // 持仓 1000 股 @avg10；tier5 全清；price 10；notional 10000；commission max(1,5)=5；
        // stampDuty 10000*0.0005=5；proceeds 10000-5-5=9990
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        let r = e.sell(panel: .upper, tier: .tier5)
        guard case .success(let op) = r else { Issue.record("expected success"); return }
        #expect(e.position.shares == 0)
        #expect(e.cashBalance == 9990)
        #expect(op.direction == .sell)
        #expect(op.shares == 1000)
        #expect(op.positionTier == .tier5)
        #expect(op.commission == 5)
        #expect(op.stampDuty == 5)
        #expect(op.totalCost == 9990)        // D6：sell totalCost = proceeds
        #expect(op.globalTick == 0)
        #expect(e.tick.globalTickIndex == 1)
    }

    @Test func sellRecordsSellMarker() {
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        _ = e.sell(panel: .upper, tier: .tier5)
        #expect(e.markers.count == 1)
        #expect(e.markers[0].direction == .sell)
        #expect(e.markers[0].globalTick == 0)
    }

    @Test func sellPartialTierKeepsRemainingShares() {
        // 1000 股 tier1(20%)：目标 200 股 → floor100 = 200 股卖出；剩 800
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        let r = e.sell(panel: .upper, tier: .tier1)
        guard case .success(let op) = r else { Issue.record("expected success"); return }
        #expect(op.shares == 200)
        #expect(e.position.shares == 800)
    }

    @Test func sellFailsWhenFlatWithDisabled() {
        // 这里 NormalFlow.canBuySell()==true（非 review）；.disabled 来自 quoteSell(holding==0)，非模式门。
        let e = Self.tradeEngine(closes: [10, 10, 10], position: .init())
        let r = e.sell(panel: .upper, tier: .tier5)
        #expect(r == .failure(.trade(.disabled)))   // quoteSell holding==0 → .disabled
    }

    @Test func sellFailsInsufficientHoldingWhenRoundsToZero() {
        // 持仓 50 股(<100)，非 tier5：floor(50*0.2=10 /100)*100 = 0 → insufficientHolding
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 500,
                                 position: PositionManager(shares: 50, averageCost: 10, totalInvested: 500))
        let r = e.sell(panel: .upper, tier: .tier1)
        #expect(r == .failure(.trade(.insufficientHolding)))
        #expect(e.position.shares == 50)        // 失败不 mutate
        #expect(e.tick.globalTickIndex == 0)    // 失败不 advance
    }

    @Test func sellFailsInReviewModeWithDisabled() {
        // R2-C2：实参须按声明顺序（position 在 mode 前）。
        let e = Self.tradeEngine(closes: [10, 10, 10],
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000),
                                 mode: .review)
        let r = e.sell(panel: .upper, tier: .tier5)
        #expect(r == .failure(.trade(.disabled)))
    }

    // MARK: - 局终强平

    @Test func advancingToEndWithHoldingForceCloses() {
        // maxTick=1；持仓 1000@10；price 末根 10。holdOrObserve 推进到 tick1(=maxTick)→强平
        let e = Self.tradeEngine(closes: [10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        e.holdOrObserve(panel: .upper)
        #expect(e.tick.globalTickIndex == 1)
        #expect(e.position.shares == 0)             // 已强平
        #expect(e.cashBalance == 9990)              // proceeds：notional10000 - comm5 - stamp5
        // 强平记 sell marker + operation
        #expect(e.markers.contains { $0.direction == .sell && $0.globalTick == 1 })
        let fc = e.tradeOperations.last
        #expect(fc?.direction == .sell)
        #expect(fc?.positionTier == .tier5)
        #expect(fc?.period == .m3)                  // D7
        #expect(fc?.globalTick == 1)
        #expect(fc?.shares == 1000)
        #expect(fc?.stampDuty == 5)
        // I2：强平后 drawdown 第二次 update 把已扣费 realized 总资金并入回撤——
        // peak(seed=initialCapital 10000) - realized(9990) = 10（手续费造成的回撤）。
        // 守住「forceCloseIfEnded 的第二次 drawdown.update 不可删」契约（mutation killer）。
        #expect(e.maxDrawdown == 10)
    }

    @Test func advancingToEndWithoutHoldingDoesNotForceClose() {
        let e = Self.tradeEngine(closes: [10, 10], position: .init())
        e.holdOrObserve(panel: .upper)
        #expect(e.tick.globalTickIndex == 1)
        #expect(e.tradeOperations.isEmpty)          // 无持仓 → 无强平
        #expect(e.markers.isEmpty)
    }

    @Test func forceCloseIsIdempotentAcrossRepeatedEndAdvances() {
        let e = Self.tradeEngine(closes: [10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        e.holdOrObserve(panel: .upper)              // 到顶强平
        let opsAfterFirst = e.tradeOperations.count
        e.holdOrObserve(panel: .upper)              // 已到顶 + 已空仓 → 无新强平
        #expect(e.tradeOperations.count == opsAfterFirst)
        #expect(e.position.shares == 0)
    }

    @Test func buyThatAdvancesToEndTriggersForceClose() {
        // maxTick=1，tick0 买入推进到 tick1(=maxTick) → 持仓被强平
        let e = Self.tradeEngine(closes: [10, 10], cash: 100_000, capital: 100_000)
        let r = e.buy(panel: .upper, tier: .tier1)
        guard case .success = r else { Issue.record("expected success"); return }
        #expect(e.tick.globalTickIndex == 1)
        #expect(e.position.shares == 0)             // 买入后立即被局终强平
        // tradeOperations：buy + 强平 sell 两笔
        #expect(e.tradeOperations.count == 2)
        #expect(e.tradeOperations[0].direction == .buy)
        #expect(e.tradeOperations[1].direction == .sell)
        #expect(e.tradeOperations[1].positionTier == .tier5)
    }

    // MARK: - Wave 3 顺位 6a：currentPositionTier（RFC §4.1 / §4.4b）

    @Test func currentPositionTierZeroWhenFlat() {
        let e = Self.tradeEngine(closes: [10, 10, 10], position: .init())
        #expect(e.currentPositionTier == 0)        // shares==0 → holdingValue 0 → 0/5
    }

    @Test func currentPositionTierZeroWhenTotalCapitalNonPositive() {
        // total == 0（cash 0 + 空仓）→ guard total>0 false → 0（不崩、不除零）
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 100_000, position: .init())
        #expect(e.currentPositionTier == 0)
    }

    @Test func currentPositionTierThreeAfterBuyingSixtyPercent() {
        // 买 3/5（60% of 100_000 / 10 = 6000 股），价不变：6000*10=60000 / (39994+60000=99994) = .60003 → ×5=3.0002 → round 3
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 100_000, capital: 100_000)
        _ = e.buy(panel: .upper, tier: .tier3)
        #expect(e.position.shares == 6000)
        #expect(e.currentPositionTier == 3)
    }

    @Test func currentPositionTierFiveWhenFullyInvested() {
        // 满仓态：10000 股 @10、cash 0 → holdingValue 100000 / total 100000 = 1.0 → ×5=5 → 5/5
        let e = Self.tradeEngine(closes: [10, 10], cash: 0, capital: 100_000,
                                 position: PositionManager(shares: 10_000, averageCost: 10, totalInvested: 100_000))
        #expect(e.currentPositionTier == 5)
    }

    @Test func currentPositionTierUsesMarketValueBasisNotStatefulBuyTier() {
        // RFC §4.1 acceptance 锁向量（opus R1-L5）：买 4/5 → 价 ×2 → 卖 持仓 2/5 → 期望 3/5（非 4/5）。
        // 钉死「持仓市值 / 当前总资金基准 + round」；stateful「记住买入档位」实现会卡在 4/5 → 第二个断言失败。
        // maxTick=3：buy@tick0→tick1、sell@tick1→tick2（tick2<3，不触局终强平）。
        let e = Self.tradeEngine(closes: [10, 20, 20, 20], cash: 100_000, capital: 100_000)
        _ = e.buy(panel: .upper, tier: .tier4)      // 80% of 100000 / 10 = 8000 股；advance→tick1（价 20）
        #expect(e.position.shares == 8000)
        #expect(e.currentPositionTier == 4)         // 8000*20=160000 / (19992+160000=179992) = .8889 → ×5=4.44 → round 4
        _ = e.sell(panel: .upper, tier: .tier2)     // 卖 持仓 40% = 3200 股；advance→tick2（价 20，不强平）
        #expect(e.position.shares == 4800)
        #expect(e.currentPositionTier == 3)         // 4800*20=96000 / (83953.6+96000=179953.6) = .5335 → ×5=2.667 → round 3
    }

    @Test func currentPositionTierZeroOnNonFiniteOverflow() {
        // codex plan R1-high：有限但极端的收盘价 × 持仓股数 溢出 Double → holdingValue = +inf（非 finite）。
        // 若无 isFinite 守卫，holdingValue/total = inf/inf = NaN，Int(NaN) **trap 崩溃**。守卫须返 0、不崩。
        let e = Self.tradeEngine(closes: [.greatestFiniteMagnitude, .greatestFiniteMagnitude],
                                 cash: 100_000, capital: 100_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        #expect(e.currentPositionTier == 0)         // 1000 × 1.8e308 → +inf → guard → 0（不 trap）
    }
}

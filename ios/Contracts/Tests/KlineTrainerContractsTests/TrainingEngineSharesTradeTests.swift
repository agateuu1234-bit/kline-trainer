// RFC-A Task 2：TrainingEngine buy/sell(panel:shares:) 按股数交易入口 + positionTier 反推（D4）
// Step 1（TDD RED）：先写测试，实现缺失时编译即失败。
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite struct TrainingEngineSharesTradeTests {

    // 复用 TrainingEngineActionsTests 已有 fixture 范式（同参数签名）
    static let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)

    /// 单周期(.m3)交易 fixture：双面板都 .m3 → 每个动作步进 1 tick。
    static func tradeEngine(closes: [Double] = [10, 10, 10, 10, 10],
                            cash: Double = 100_000,
                            capital: Double = 100_000,
                            position: PositionManager = .init()) -> TrainingEngine {
        let maxTick = closes.count - 1
        return TrainingEngine(
            flow: NormalFlow(fees: fees, maxTick: maxTick),
            allCandles: m3Candles(closes),
            maxTick: maxTick,
            initialCapital: capital,
            initialCashBalance: cash,
            initialPosition: position,
            initialUpperPeriod: .m3,
            initialLowerPeriod: .m3)
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

    // MARK: - buy(panel:shares:) 成功路径

    @Test func buySharesSuccessDeductsCashAddsPositionAndAdvances() {
        // buy(panel:.lower, shares:200) at price 10, cash 100_000
        // notional = 200*10 = 2000; commission = max(2000*0.0001, 5) = 5; totalCost = 2005
        // positionTier = tierForFraction(2005/100_000) ≈ 0.02005 → ×5=0.10025 → round 0 → max(1,0) = tier1
        let e = Self.tradeEngine(closes: [10, 10, 10, 10], cash: 100_000, capital: 100_000)
        let r = e.buy(panel: .lower, shares: 200)
        guard case .success(let op) = r else { Issue.record("expected success"); return }
        #expect(e.position.shares == 200)
        #expect(e.cashBalance == 100_000 - 2_005)
        #expect(op.direction == .buy)
        #expect(op.shares == 200)
        #expect(op.positionTier == .tier1)    // tierForFraction(2005/100000) → tier1
        #expect(op.price == 10)
        #expect(op.commission == 5)
        #expect(op.stampDuty == 0)            // 买入无印花税
        #expect(op.totalCost == 2_005)
        #expect(op.globalTick == 0)           // entryTick（advance 前）
        #expect(op.period == .m3)             // lower panel period
        #expect(op.createdAt == 0)            // tick0 m3 datetime = 0*180
        #expect(e.tick.globalTickIndex == 1)  // advance 1
        #expect(e.tradeOperations.count == 1)
        #expect(e.markers.count == 1)
        #expect(e.markers[0].direction == .buy)
        #expect(e.markers[0].globalTick == 0)
    }

    // MARK: - buy(panel:shares:) 失败路径

    @Test func buySharesFailsInvalidShareCountOnNonLot() {
        // 250 不是 100 整手 → .invalidShareCount；不 mutate、不 advance
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 100_000, capital: 100_000)
        let before = (e.position.shares, e.cashBalance, e.tick.globalTickIndex)
        let r = e.buy(panel: .lower, shares: 250)
        #expect(r == .failure(.trade(.invalidShareCount)))
        #expect(e.position.shares == before.0)
        #expect(e.cashBalance == before.1)
        #expect(e.tick.globalTickIndex == before.2)
        #expect(e.markers.isEmpty)
        #expect(e.tradeOperations.isEmpty)
    }

    // MARK: - sell(panel:shares:) 成功路径

    @Test func sellSharesFullCloseAfterBuy() {
        // 先全仓买、再 sell(panel:.lower, shares: position.shares) → position.shares==0
        let e = Self.tradeEngine(closes: [10, 10, 10, 10, 10], cash: 100_000, capital: 100_000)
        let buyResult = e.buy(panel: .lower, shares: 200)
        guard case .success = buyResult else { Issue.record("buy should succeed"); return }
        #expect(e.position.shares == 200)
        let sellShares = e.position.shares   // 200，整手
        let r = e.sell(panel: .lower, shares: sellShares)
        guard case .success(let op) = r else { Issue.record("sell should succeed"); return }
        #expect(e.position.shares == 0)
        #expect(op.direction == .sell)
        #expect(op.shares == 200)
    }

    @Test func sellSharesFailsInsufficientHoldingWhenExceedsHolding() {
        // 持仓 100 股，尝试卖 200 → .insufficientHolding；不 mutate、不 advance
        let e = Self.tradeEngine(closes: [10, 10, 10],
                                 position: PositionManager(shares: 100, averageCost: 10, totalInvested: 1_000))
        let before = (e.position.shares, e.cashBalance, e.tick.globalTickIndex, e.tradeOperations.count)
        let r = e.sell(panel: .lower, shares: 200)
        #expect(r == .failure(.trade(.insufficientHolding)))
        #expect(e.position.shares == before.0)
        #expect(e.cashBalance == before.1)
        #expect(e.tick.globalTickIndex == before.2)
        #expect(e.tradeOperations.count == before.3)
    }

    // MARK: - R-plan-8-1：溢出原子 no-op

    @Test func sellSharesNoOpOnFiniteOverflowPrice() {
        // 有限但极端价 .greatestFiniteMagnitude；1000 股 × 1.8e308 → notional = +inf（非有限）。
        // quoteSell 的 q.notional.isFinite 守 → .failure(.invalidShareCount)；整笔原子 no-op。
        let price = Double.greatestFiniteMagnitude
        let e = Self.tradeEngine(closes: [price, price, price],
                                 cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        let beforeShares = e.position.shares
        let beforeCash   = e.cashBalance
        let beforeOps    = e.tradeOperations.count
        let r = e.sell(panel: .lower, shares: 1000)
        #expect(r == .failure(.trade(.invalidShareCount)))
        #expect(e.position.shares == beforeShares)        // 整笔 no-op
        #expect(e.cashBalance == beforeCash)
        #expect(e.tradeOperations.count == beforeOps)
    }

    // MARK: - R-plan-12-1：净负现金 no-op

    @Test func sellSharesNoOpWhenProceedsWouldMakeCashNegative() {
        // price 0.01、shares 100；notional=1.0；commission=max(1.0*0.0001,5)=5；
        // stampDuty=1.0*0.0005=0.0005；proceeds=1.0-5-0.0005=-4.0005。
        // cash=0 → newCash=0+(-4.0005)=-4.0005 < 0 → .insufficientCash；整笔 no-op。
        let e = Self.tradeEngine(closes: [0.01, 0.01, 0.01],
                                 cash: 0, capital: 1,
                                 position: PositionManager(shares: 100, averageCost: 0.01, totalInvested: 1))
        let beforeShares = e.position.shares
        let beforeCash   = e.cashBalance
        let beforeOps    = e.tradeOperations.count
        let r = e.sell(panel: .lower, shares: 100)
        #expect(r == .failure(.trade(.insufficientCash)))
        #expect(e.position.shares == beforeShares)        // 整笔 no-op（保非负资金不变量）
        #expect(e.cashBalance == beforeCash)
        #expect(e.tradeOperations.count == beforeOps)
    }
}

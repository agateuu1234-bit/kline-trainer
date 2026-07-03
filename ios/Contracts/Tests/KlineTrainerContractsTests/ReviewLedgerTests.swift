import Testing
import KlineTrainerContracts

@Suite struct ReviewLedgerTests {
    private func op(_ tick: Int, _ dir: TradeDirection, price: Double, shares: Int,
                    commission: Double, stampDuty: Double, totalCost: Double) -> TradeOperation {
        TradeOperation(globalTick: tick, period: .m3, direction: dir, price: price, shares: shares,
                       positionTier: .tier1, commission: commission, stampDuty: stampDuty,   // ReviewLedger 忽略 positionTier；用合法 case（无 .zero）
                       totalCost: totalCost, createdAt: Int64(tick))
    }
    // 价：tick<10→10.00，>=10→12.00（含 clamp 语义由 caller 提供的闭包决定）
    private let price: (Int) -> Double = { $0 < 10 ? 10.00 : 12.00 }

    @Test func beforeAnyTradeIsFlat() throws {
        let s = try ReviewLedger.state(atTick: 4, ops: [], initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.shares == 0); #expect(s.cash == 100_000); #expect(s.totalCapital == 100_000)
        #expect(s.returnRate == 0); #expect(s.positionTier == 0)
    }

    @Test func afterBuyRunningValueTracks() throws {
        // buy 100 @10, commission 5, totalCost 1005, tick 5
        let ops = [op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005)]
        let s = try ReviewLedger.state(atTick: 5, ops: ops, initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.shares == 100)
        #expect(s.cash == 98_995)                 // 100000 - 1005
        #expect(s.averageCost == 10.05)           // 1005/100
        #expect(s.totalCapital == 99_995)         // 98995 + 100*10
        #expect(abs(s.returnRate - (-5.0/100_000)) < 1e-12)
    }

    @Test func opsWithFutureTickExcluded() throws {
        let ops = [op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005),
                   op(10, .sell, price: 12, shares: 100, commission: 6, stampDuty: 0.6, totalCost: 1200)]
        // at tick 8：只应用 buy（sell 在 tick 10 > 8）
        let s = try ReviewLedger.state(atTick: 8, ops: ops, initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.shares == 100)
    }

    @Test func afterSellRealizes() throws {
        let ops = [op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005),
                   op(10, .sell, price: 12, shares: 100, commission: 6, stampDuty: 0.6, totalCost: 1200)]
        let s = try ReviewLedger.state(atTick: 10, ops: ops, initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.shares == 0)
        // cash = 98995 + (12*100 - 6 - 0.6) = 98995 + 1193.4 = 100188.4
        #expect(abs(s.cash - 100_188.4) < 1e-9)
        #expect(abs(s.totalCapital - 100_188.4) < 1e-9)   // 0 仓 → 全现金
    }

    // codex plan-R3-high：损坏 ops 必须 fail-closed（throw .dbCorrupted），绝不 trap PositionManager
    @Test func corruptOpsThrowDBCorrupted() {
        func expectCorrupt(_ ops: [TradeOperation]) {
            #expect(throws: AppError.self) { _ = try ReviewLedger.state(atTick: 99, ops: ops, initialCapital: 100_000, markPriceAtTick: price) }
        }
        expectCorrupt([op(5, .sell, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005)])           // sell-before-buy
        expectCorrupt([op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005),
                       op(6, .sell, price: 10, shares: 200, commission: 5, stampDuty: 0, totalCost: 1000)])          // oversell
        expectCorrupt([op(5, .buy, price: 10, shares: 0, commission: 5, stampDuty: 0, totalCost: 1005)])              // zero shares
        expectCorrupt([op(5, .buy, price: .nan, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005)])         // non-finite price
        expectCorrupt([op(5, .buy, price: 10, shares: -5, commission: 5, stampDuty: 0, totalCost: 1005)])            // negative shares
        expectCorrupt([op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 0)])             // 零成本 buy（PositionManager.buy 前置 totalCost>0，codex plan-R6-high）
        expectCorrupt([op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: .infinity)])     // 非有限 totalCost
        expectCorrupt([op(5, .buy, price: 1, shares: 1, commission: 0, stampDuty: 0, totalCost: .greatestFiniteMagnitude),
                       op(6, .buy, price: 1, shares: 1, commission: 0, stampDuty: 0, totalCost: .greatestFiniteMagnitude)])  // 累加 totalInvested 溢出 inf
        expectCorrupt([op(5, .buy, price: 1, shares: 1_000_000_000, commission: 0, stampDuty: 0, totalCost: 1_000_000_000),
                       op(6, .sell, price: 1e300, shares: 1_000_000_000, commission: 0, stampDuty: 0, totalCost: 1)])  // sell notional 1e300*1e9→inf（codex plan-R11-high）
    }

    // codex plan-R4-high：同 tick 的 buy→sell（插入序）不得被排序打乱成 sell→buy（否则误判 oversell）
    @Test func sameTickBuyThenSellKeepsInsertionOrder() throws {
        let ops = [op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005),
                   op(5, .sell, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1000)]  // 同 tick 5，插入序 buy 先
        let s = try ReviewLedger.state(atTick: 5, ops: ops, initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.shares == 0)   // buy 后 sell → 平；若被排成 sell 先则会 throw oversell
    }

    // final-review T3：上一条测试用 op() 硬编码 createdAt = tick，同 tick 时两者恰好相等，
    // 无法证伪"排序 tiebreak 用的是 createdAt 而非插入序"。这里显式构造相反的 createdAt
    // （buy.createdAt > sell.createdAt，插入序仍 buy 先）：若实现误用 createdAt 排序，
    // sell 会被排到 buy 前 → oversell throw；插入序排序则不受影响，仍平仓 shares==0。
    @Test func sameTickTiebreakUsesInsertionOrderNotCreatedAt() throws {
        let buy = TradeOperation(globalTick: 5, period: .m3, direction: .buy, price: 10, shares: 100,
                                  positionTier: .tier1, commission: 5, stampDuty: 0, totalCost: 1005,
                                  createdAt: 200)   // createdAt 晚，若误用 createdAt 排序会被排到 sell 之后
        let sell = TradeOperation(globalTick: 5, period: .m3, direction: .sell, price: 10, shares: 100,
                                   positionTier: .tier1, commission: 5, stampDuty: 0, totalCost: 1000,
                                   createdAt: 100)  // createdAt 早，若误用 createdAt 排序会被排到 buy 之前（→ oversell）
        let ops = [buy, sell]   // 插入序：buy 先、sell 后
        let s = try ReviewLedger.state(atTick: 5, ops: ops, initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.shares == 0)   // 未 throw 即证明排序未按 createdAt（否则 sell 先 → oversell throw）
    }

    // codex whole-branch R5（medium）：损坏 op 流买超可用现金（totalCost > cash）必须 fail-closed
    // throw .dbCorrupted，而非让 running cash 变负仍照常显示。合法流由 TradeCalculator.quoteBuy 保证
    // totalCost <= cash，故此仅可能发生于损坏/伪造的 op 序列。
    @Test func overCashBuy_throwsDBCorrupted() {
        // initialCapital 100_000，totalCost 100_001 > cash → newCash = -1，远超 -1e-6 容差 → 必须 throw
        let ops = [op(5, .buy, price: 1000, shares: 1, commission: 0, stampDuty: 0, totalCost: 100_001)]
        #expect(throws: AppError.self) {
            _ = try ReviewLedger.state(atTick: 5, ops: ops, initialCapital: 100_000, markPriceAtTick: price)
        }
    }

    // 对照：恰好花光现金（totalCost == cash，newCash == 0）是合法买入，不得被容差误拒。
    @Test func exactlyAffordableBuy_doesNotThrow() throws {
        let ops = [op(5, .buy, price: 1000, shares: 100, commission: 0, stampDuty: 0, totalCost: 100_000)]
        let s = try ReviewLedger.state(atTick: 5, ops: ops, initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.cash == 0)
        #expect(s.shares == 100)
    }

    // codex plan-R9-medium：sell 的 proceeds(=totalCost) 允许为负（低价清仓/force-close），不得判损坏
    @Test func negativeSellProceedsIsValidNotCorrupt() throws {
        let ops = [op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005),
                   op(10, .sell, price: 0.01, shares: 100, commission: 5, stampDuty: 0, totalCost: -4)]  // proceeds=0.01*100-5 = -4（负、合法）
        let s = try ReviewLedger.state(atTick: 10, ops: ops, initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.shares == 0)
        #expect(abs(s.cash - 98_991) < 1e-9)   // 98995 + (1 - 5) = 98991 ≥ 0 → 合法，不 throw
    }

    // 终局等式 oracle + mutation：手算 finalTick profit，改一个 op 的 totalCost 断言结果不同（证明测试非空洞）
    @Test func oracleFinalTickProfitMatchesHandComputationAndMutationDiffers() throws {
        // buy 200 @10, commission 8, totalCost 2008, tick 3
        // sell 200 @12, commission 7, stampDuty 1.2, totalCost(proceeds) = 12*200 - 7 - 1.2 = 2391.8, tick 20
        let finalTick = 20
        let ops = [op(3, .buy, price: 10, shares: 200, commission: 8, stampDuty: 0, totalCost: 2008),
                   op(finalTick, .sell, price: 12, shares: 200, commission: 7, stampDuty: 1.2, totalCost: 2391.8)]
        let initialCapital = 100_000.0
        // 手算: cash = 100000 - 2008 + (12*200 - 7 - 1.2) = 100000 - 2008 + 2391.8 = 100383.8
        // 0 仓 → totalCapital = cash；profit = totalCapital - initialCapital = 383.8
        let handComputedProfit = 383.8
        let s = try ReviewLedger.state(atTick: finalTick, ops: ops, initialCapital: initialCapital, markPriceAtTick: price)
        #expect(abs((s.totalCapital - initialCapital) - handComputedProfit) < 1e-9)

        // mutation：改 buy 的 totalCost（commission 从 8 → 50），最终 profit 必须不同（证明测试非空洞）
        let mutatedOps = [op(3, .buy, price: 10, shares: 200, commission: 50, stampDuty: 0, totalCost: 2050),
                           op(finalTick, .sell, price: 12, shares: 200, commission: 7, stampDuty: 1.2, totalCost: 2391.8)]
        let mutated = try ReviewLedger.state(atTick: finalTick, ops: mutatedOps, initialCapital: initialCapital, markPriceAtTick: price)
        #expect(abs((mutated.totalCapital - initialCapital) - handComputedProfit) > 1e-9)
    }
}

import Testing
@testable import KlineTrainerContracts

// 公用容差断言：Double 字段比较用容差（佣金/印花税含 FP 误差，禁裸 ==）
private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool {
    abs(a - b) < tol
}

private let noMin = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false)
private let withMin = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)

@Suite("TradeCalculator.quoteBuy")
struct TradeCalculatorBuyTests {

    @Test("happy: 整手买入，佣金按实际")
    func happy() {
        let r = TradeCalculator.quoteBuy(totalCapital: 100_000, cash: 100_000,
                                         tier: .tier1, price: 10, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success, got \(r)"); return }
        #expect(q.shares == 2000)                       // floor(100000*0.2/10)=2000
        #expect(approx(q.notional, 20_000))
        #expect(approx(q.commission, 2.0))              // 20000*0.0001
        #expect(approx(q.totalCost, 20_002))
    }

    @Test("lot rounding: 非整百原始股数 floor 至 100 倍")
    func lotRounding() {
        let r = TradeCalculator.quoteBuy(totalCapital: 100_000, cash: 100_000,
                                         tier: .tier1, price: 33, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(q.shares == 600)                        // floor(20000/33)=606 -> floor(606/100)*100=600
        #expect(approx(q.notional, 19_800))
        #expect(approx(q.commission, 1.98))
        #expect(approx(q.totalCost, 19_801.98))
    }

    @Test("FP 根治: 价格非二进制精确(0.07)时 robustFloor 防掉股")
    func fpRobustFloor() {
        // 1001/0.07 真值=14300，但 IEEE-754 下 = 14299.999999999998；
        // 朴素 Int(floor) 得 14299 -> lot 14200；robustFloor 进位回 14300 -> lot 14300。
        // 此输入经 toolchain 验证会 undershoot——该测试在 robustFloor 换成朴素 floor 时
        // 必须 FAIL（否则未真正覆盖机制）。
        let r = TradeCalculator.quoteBuy(totalCapital: 1_001, cash: 1_000_000,
                                         tier: .tier5, price: 0.07, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(q.shares == 14_300)
        #expect(approx(q.notional, 1_001.0))
    }

    @Test("insufficientCash: floor 后股数=0")
    func roundsToZero() {
        let r = TradeCalculator.quoteBuy(totalCapital: 1_000, cash: 1_000,
                                         tier: .tier1, price: 10, fees: noMin)
        #expect(r == .failure(.insufficientCash))       // floor(200/10)=20 -> lot 0
    }

    @Test("insufficientCash: 总成本 > 可用现金")
    func costExceedsCash() {
        let r = TradeCalculator.quoteBuy(totalCapital: 100_000, cash: 50_000,
                                         tier: .tier5, price: 10, fees: noMin)
        #expect(r == .failure(.insufficientCash))       // shares 10000 totalCost 100010 > 50000
    }

    @Test("min commission: 免5开启且佣金<5 计 5")
    func minCommission() {
        let r = TradeCalculator.quoteBuy(totalCapital: 100_000, cash: 100_000,
                                         tier: .tier1, price: 10, fees: withMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(approx(q.commission, 5.0))              // raw 2.0 < 5 -> 5
        #expect(approx(q.totalCost, 20_005))
    }

    @Test("invalidShareCount: price<=0")
    func invalidPrice() {
        #expect(TradeCalculator.quoteBuy(totalCapital: 100_000, cash: 100_000,
                                         tier: .tier1, price: 0, fees: noMin) == .failure(.invalidShareCount))
        #expect(TradeCalculator.quoteBuy(totalCapital: 100_000, cash: 100_000,
                                         tier: .tier1, price: -5, fees: noMin) == .failure(.invalidShareCount))
    }

    @Test("invalidShareCount: 负输入")
    func invalidNegative() {
        #expect(TradeCalculator.quoteBuy(totalCapital: -1, cash: 100_000,
                                         tier: .tier1, price: 10, fees: noMin) == .failure(.invalidShareCount))
        #expect(TradeCalculator.quoteBuy(totalCapital: 100_000, cash: -1,
                                         tier: .tier1, price: 10, fees: noMin) == .failure(.invalidShareCount))
    }
}

@Suite("TradeCalculator.quoteSell")
struct TradeCalculatorSellTests {

    @Test("happy: 整手卖出，佣金+印花税")
    func happy() {
        let r = TradeCalculator.quoteSell(holding: 1000, averageCost: 15,
                                          tier: .tier2, price: 20, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success, got \(r)"); return }
        #expect(q.shares == 400)                        // floor(1000*0.4/100)*100=400
        #expect(approx(q.notional, 8_000))
        #expect(approx(q.commission, 0.8))              // 8000*0.0001
        #expect(approx(q.stampDuty, 4.0))               // 8000*0.0005
        #expect(approx(q.proceeds, 7_995.2))            // 8000-0.8-4.0
    }

    @Test("清仓 5/5: 不取整，允许零股（奇数持仓全卖）")
    func clearOddLot() {
        let r = TradeCalculator.quoteSell(holding: 1050, averageCost: 15,
                                          tier: .tier5, price: 20, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(q.shares == 1050)                       // 清仓全卖不取整
        #expect(approx(q.notional, 21_000))
    }

    @Test("清仓 5/5: 持仓 < 100 也全卖")
    func clearSubLot() {
        let r = TradeCalculator.quoteSell(holding: 50, averageCost: 15,
                                          tier: .tier5, price: 20, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(q.shares == 50)
        #expect(approx(q.notional, 1_000))              // 50*20
        #expect(approx(q.commission, 0.1))              // 1000*0.0001
        #expect(approx(q.stampDuty, 0.5))               // 1000*0.0005
        #expect(approx(q.proceeds, 999.4))              // 1000-0.1-0.5
    }

    @Test("tier3 整手卖出: 500*0.6=300 -> lot 300")
    func tier3LotRounding() {
        // 整手卖出正确性测试（非 FP demo：整数 holding × 0.6 不会 FP 下溢，
        // sell 路径 robustFloor 仅为与 buy 对称的防御层）。
        let r = TradeCalculator.quoteSell(holding: 500, averageCost: 15,
                                          tier: .tier3, price: 10, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(q.shares == 300)
        #expect(approx(q.notional, 3_000))
    }

    @Test("insufficientHolding: 非清仓且 floor 后股数=0")
    func roundsToZero() {
        let r = TradeCalculator.quoteSell(holding: 250, averageCost: 15,
                                          tier: .tier1, price: 20, fees: noMin)
        #expect(r == .failure(.insufficientHolding))    // floor(250*0.2)=50 -> lot 0，tier1 非清仓
    }

    @Test("disabled: 空仓点卖出")
    func emptyHolding() {
        #expect(TradeCalculator.quoteSell(holding: 0, averageCost: 0,
                                          tier: .tier1, price: 20, fees: noMin) == .failure(.disabled))
        // 空仓即使点 5/5 清仓也是 disabled（无仓可清）
        #expect(TradeCalculator.quoteSell(holding: 0, averageCost: 0,
                                          tier: .tier5, price: 20, fees: noMin) == .failure(.disabled))
    }

    @Test("invalidShareCount: price<=0 / holding<0")
    func invalid() {
        #expect(TradeCalculator.quoteSell(holding: 1000, averageCost: 15,
                                          tier: .tier1, price: 0, fees: noMin) == .failure(.invalidShareCount))
        #expect(TradeCalculator.quoteSell(holding: -1, averageCost: 15,
                                          tier: .tier1, price: 20, fees: noMin) == .failure(.invalidShareCount))
    }

    @Test("min commission: 卖出免5开启且佣金<5 计 5")
    func minCommission() {
        let r = TradeCalculator.quoteSell(holding: 1000, averageCost: 15,
                                          tier: .tier2, price: 20, fees: withMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(approx(q.commission, 5.0))              // raw 0.8 < 5 -> 5
        #expect(approx(q.proceeds, 7_991.0))            // 8000-5-4
    }
}

@Suite("TradeCalculator.forceCloseOnEnd")
struct TradeCalculatorForceCloseTests {

    @Test("happy: 全量清仓，佣金+印花税")
    func happy() {
        let q = TradeCalculator.forceCloseOnEnd(holding: 1000, averageCost: 15,
                                                price: 20, fees: noMin)
        #expect(q.shares == 1000)
        #expect(approx(q.notional, 20_000))
        #expect(approx(q.commission, 2.0))
        #expect(approx(q.stampDuty, 10.0))
        #expect(approx(q.proceeds, 19_988.0))           // 20000-2-10
    }

    @Test("奇数持仓全量清仓不取整")
    func oddLot() {
        let q = TradeCalculator.forceCloseOnEnd(holding: 1234, averageCost: 15,
                                                price: 10, fees: noMin)
        #expect(q.shares == 1234)
        #expect(approx(q.notional, 12_340))
    }

    @Test("holding=0: 全零报价（无交易无费用）")
    func zeroHolding() {
        let q = TradeCalculator.forceCloseOnEnd(holding: 0, averageCost: 0,
                                                price: 20, fees: withMin)
        #expect(q.shares == 0)
        #expect(approx(q.notional, 0))
        #expect(approx(q.commission, 0))                // 不触发 min5
        #expect(approx(q.stampDuty, 0))
        #expect(approx(q.proceeds, 0))
    }

    @Test("min commission: 清仓免5开启且佣金<5 计 5")
    func minCommission() {
        let q = TradeCalculator.forceCloseOnEnd(holding: 1000, averageCost: 15,
                                                price: 20, fees: withMin)
        #expect(approx(q.commission, 5.0))              // raw 2.0 < 5 -> 5
        #expect(approx(q.proceeds, 19_985.0))           // 20000-5-10
    }
}

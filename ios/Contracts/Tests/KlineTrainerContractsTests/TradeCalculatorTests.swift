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

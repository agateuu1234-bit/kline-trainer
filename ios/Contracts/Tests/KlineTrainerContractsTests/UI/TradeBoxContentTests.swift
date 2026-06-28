import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("TradeBoxContent")
struct TradeBoxContentTests {
    private let noMin = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false)

    @Test("buy: 可买上限 + 预估 + 标题红")
    func buy() {
        let c = TradeBoxContent(action: .buy, price: 10, cash: 100_000, holding: 0,
                                fees: noMin, qty: 2000)
        #expect(c.limitShares == 9900)                 // maxBuyable(100000,10)=9900
        #expect(c.limitLabel == "可买 9,900 股")
        #expect(c.estimateLabel == "预估 ¥ 20,002")    // totalCost 2000*10+2
        #expect(c.confirmLabel == "买入 2,000 股")
        #expect(c.confirmEnabled == true)
    }
    @Test("sell: 可卖=持仓 + 清仓奇数股")
    func sell() {
        let c = TradeBoxContent(action: .sell, price: 20, cash: 0, holding: 150,
                                fees: noMin, qty: 150)
        #expect(c.limitShares == 150)
        #expect(c.limitLabel == "可卖 150 股")
        #expect(c.confirmLabel == "卖出 150 股")
        #expect(c.confirmEnabled == true)               // 清仓放行奇数
    }
    @Test("R-plan-14-1：UI 与 engine 同源——净负卖出框禁用、预估占位")
    func sellNegativeProceedsDisabled() {
        let withMin = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        // 100 股 ×0.01=1，免5 → proceeds≈-4，cash=0 → quoteSell(cash:) 失败 → confirmEnabled false / 预估占位
        let c = TradeBoxContent(action: .sell, price: 0.01, cash: 0, holding: 100, fees: withMin, qty: 100)
        #expect(c.confirmEnabled == false)
        #expect(c.estimateLabel == "预估 —")
    }
    @Test("R-plan-14-1：极端价输出非有限 → 卖出框禁用（不格式化非有限）")
    func sellNonFiniteDisabled() {
        let c = TradeBoxContent(action: .sell, price: .greatestFiniteMagnitude, cash: 1e300,
                                holding: 1_000_000, fees: noMin, qty: 1_000_000)
        #expect(c.confirmEnabled == false)
        #expect(c.estimateLabel == "预估 —")
    }
    @Test("非整手买入 250 → effectiveShares 200，显示==提交，使能")
    func buyNonLotNormalizes() {
        let c = TradeBoxContent(action: .buy, price: 10, cash: 100_000, holding: 0, fees: noMin, qty: 250)
        #expect(c.effectiveShares == 200)
        #expect(c.confirmLabel == "买入 200 股")        // 显示=提交（不再 250 显示/200 提交）
        #expect(c.confirmEnabled == true)
    }
    @Test("部分卖非整手（holding 150 输 50）→ effectiveShares 0，禁用")
    func sellPartialOddDisabled() {
        let c = TradeBoxContent(action: .sell, price: 20, cash: 0, holding: 150, fees: noMin, qty: 50)
        #expect(c.effectiveShares == 0)                 // 50 lot-floor=0（非清仓，不放行奇数）
        #expect(c.confirmEnabled == false)
    }
    @Test("清仓 holding 150 输 150 → effectiveShares 150，放行，显示==提交")
    func sellClearOddEnabled() {
        let c = TradeBoxContent(action: .sell, price: 20, cash: 0, holding: 150, fees: noMin, qty: 150)
        #expect(c.effectiveShares == 150)               // 清仓例外
        #expect(c.confirmLabel == "卖出 150 股")
        #expect(c.confirmEnabled == true)
    }
    @Test("qty=0 / 超限 → effectiveShares 受限、确认禁用或 clamp")
    func disabledAndClamp() {
        #expect(TradeBoxContent(action: .buy, price: 10, cash: 100_000, holding: 0,
                                fees: noMin, qty: 0).confirmEnabled == false)
        // 超可买：effectiveShares clamp 到 limit(9900)，仍是合法可买量 → 使能且显示 clamp 后值
        let over = TradeBoxContent(action: .buy, price: 10, cash: 100_000, holding: 0, fees: noMin, qty: 100_000)
        #expect(over.effectiveShares == 9900)
        #expect(over.confirmLabel == "买入 9,900 股")
        #expect(over.confirmEnabled == true)
    }
    @Test("快捷档填入股数：买 1/5/全仓；卖 1/5/清仓")
    func tierFills() {
        let b = TradeBoxContent(action: .buy, price: 10, cash: 100_000, holding: 0, fees: noMin, qty: 0)
        #expect(b.fillShares(.tier1) == 2000)
        #expect(b.fillShares(.tier5) == 9900)           // 全仓 = 可买上限
        let s = TradeBoxContent(action: .sell, price: 20, cash: 0, holding: 1000, fees: noMin, qty: 0)
        #expect(s.fillShares(.tier2) == 400)
        #expect(s.fillShares(.tier5) == 1000)           // 清仓
    }
    @Test("快捷标签：买末档=全仓 / 卖末档=清仓")
    func tierLabels() {
        #expect(TradeBoxContent(action: .buy, price: 10, cash: 1, holding: 0, fees: noMin, qty: 0)
                    .tierLabels == ["1/5","2/5","3/5","4/5","全仓"])
        #expect(TradeBoxContent(action: .sell, price: 10, cash: 0, holding: 1, fees: noMin, qty: 0)
                    .tierLabels.last == "清仓")
    }
    @Test("R-plan-21-1：boxIdentity 随 (panel,action,tick) 变化 → 同 panel/tick 切 action 必换身份(强制 @State 重置)")
    func boxIdentityDistinct() {
        let buy = TradeBoxContent.boxIdentity(panel: .lower, action: .buy, tick: 5)
        let sell = TradeBoxContent.boxIdentity(panel: .lower, action: .sell, tick: 5)  // 同 panel/tick、仅 action 不同
        #expect(buy != sell)                                                            // 关键：action 变 → 身份变
        #expect(buy != TradeBoxContent.boxIdentity(panel: .upper, action: .buy, tick: 5))   // panel 变
        #expect(buy != TradeBoxContent.boxIdentity(panel: .lower, action: .buy, tick: 6))   // tick 变
        #expect(buy == TradeBoxContent.boxIdentity(panel: .lower, action: .buy, tick: 5))   // 同请求 → 同身份(稳定)
    }
    @Test("R-plan-23-1：高费率快捷填入超 max-buyable → effectiveShares clamp 到 limit（显示==提交）")
    func fillExceedsLimitClamps() {
        let hi = FeeSnapshot(commissionRate: 0.3, minCommissionEnabled: false)
        let c = TradeBoxContent(action: .buy, price: 10, cash: 10_000, holding: 0, fees: hi, qty: 0)
        #expect(c.fillShares(.tier4) == 800)     // cash 基准 4/5（未含高佣金）= 800
        #expect(c.limitShares == 700)            // maxBuyable 含高佣金 = 700
        // 把 fill(800) 填进 qty → effectiveShares 必 clamp 到 limit(700) = 实际提交值（View setQty/确认同口径）
        let filled = TradeBoxContent(action: .buy, price: 10, cash: 10_000, holding: 0, fees: hi, qty: 800)
        #expect(filled.effectiveShares == 700)
        #expect(filled.confirmLabel == "买入 700 股")   // 显示==提交
    }
}

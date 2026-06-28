// ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBoxContent.swift
// RFC-A A2：买卖框纯值。给定 action/price/cash/holding/fees/qty → 可买可卖/预估/各档填入/确认使能。
// 仅 import Foundation —— host 全测。TradeAction 复用 TradeBarContent.swift 定义。

import Foundation

public struct TradeBoxContent: Equatable, Sendable {
    public let action: TradeAction
    public let price: Double
    public let cash: Double
    public let holding: Int
    public let fees: FeeSnapshot
    public let qty: Int

    public init(action: TradeAction, price: Double, cash: Double, holding: Int,
                fees: FeeSnapshot, qty: Int) {
        self.action = action; self.price = price; self.cash = cash
        self.holding = holding; self.fees = fees; self.qty = qty
    }

    /// 可买（买=fee-aware 上限）/ 可卖（卖=全部持仓）。
    public var limitShares: Int {
        switch action {
        case .buy:  return TradeCalculator.maxBuyableShares(cash: cash, price: price, fees: fees)
        case .sell: return holding
        }
    }

    public var limitLabel: String {
        let n = Self.grouped(limitShares)
        return action == .buy ? "可买 \(n) 股" : "可卖 \(n) 股"
    }

    /// 唯一有效下单股数（codex R-plan-1）：预估/确认文案/使能/提交全用它，杜绝「显示≠提交」。
    /// D7 卖清仓例外：qty==holding(>0) → 原值（含奇数）；否则 lot-floor 后 clamp [0, limitShares]。
    public var effectiveShares: Int {
        if action == .sell && qty == holding && holding > 0 { return holding }
        let lot = (qty / TradeCalculator.shareLotSize) * TradeCalculator.shareLotSize
        return min(max(0, lot), limitShares)
    }

    /// 预估：买=totalCost / 卖=proceeds；用 effectiveShares 经 quote 校验，非法 → "—"。
    public var estimateLabel: String {
        let s = effectiveShares
        switch action {
        case .buy:
            if case .success(let q) = TradeCalculator.quoteBuy(cash: cash, shares: s, price: price, fees: fees) {
                return "预估 ¥ \(Self.currency(q.totalCost))"
            }
        case .sell:
            if case .success(let q) = TradeCalculator.quoteSell(cash: cash, holding: holding, shares: s, price: price, fees: fees) {
                return "预估 ¥ \(Self.currency(q.proceeds))"
            }
        }
        return "预估 —"
    }

    /// 确认使能 = effectiveShares 经 quote 精确校验成功（非仅 ≤limit；非整手/0 → 禁用）。
    public var confirmEnabled: Bool {
        let s = effectiveShares
        guard s > 0 else { return false }
        switch action {
        case .buy:
            if case .success = TradeCalculator.quoteBuy(cash: cash, shares: s, price: price, fees: fees) { return true }
        case .sell:
            if case .success = TradeCalculator.quoteSell(cash: cash, holding: holding, shares: s, price: price, fees: fees) { return true }
        }
        return false
    }

    /// 确认文案 = effectiveShares（与提交一致）。
    public var confirmLabel: String {
        let verb = action == .buy ? "买入" : "卖出"
        return "\(verb) \(Self.grouped(effectiveShares)) 股"
    }

    /// 比例快捷填入股数（点击后填入数量框）。
    public func fillShares(_ tier: PositionTier) -> Int {
        switch action {
        case .buy:  return TradeCalculator.sharesForBuyTier(cash: cash, price: price, tier: tier, fees: fees)
        case .sell: return TradeCalculator.sharesForSellTier(holding: holding, tier: tier)
        }
    }

    /// 5 档标签：1/5..4/5 + 末档（买=全仓 / 卖=清仓）。
    public var tierLabels: [String] {
        PositionTier.allCases.map { tier in
            tier == .tier5 ? (action == .buy ? "全仓" : "清仓") : tier.rawValue
        }
    }

    /// R-plan-21-1：买卖框 SwiftUI 视图身份键——绑 (panel, action, tick)，请求任一变即新身份 → @State qty 重置。
    public static func boxIdentity(panel: PanelId, action: TradeAction, tick: Int) -> String {
        "\(panel)-\(action)-\(tick)"
    }

    private static func grouped(_ v: Int) -> String {
        let f = NumberFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal; f.usesGroupingSeparator = true; f.groupingSeparator = ","
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    private static func currency(_ v: Double) -> String {
        let f = NumberFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal; f.usesGroupingSeparator = true; f.groupingSeparator = ","
        f.minimumFractionDigits = 0; f.maximumFractionDigits = 0   // 预估取整元，避免小数噪声
        return f.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v.rounded()))"
    }
}

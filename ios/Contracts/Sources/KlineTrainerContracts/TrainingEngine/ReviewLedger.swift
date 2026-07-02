import Foundation

public struct ReviewLedgerState: Equatable, Sendable {
    public let cash: Double
    public let shares: Int
    public let averageCost: Double
    public let totalCapital: Double
    public let returnRate: Double
    public let positionTier: Int
}

/// 平台无关纯折叠：给定已记录 ops，重算截至某 global tick 的运行账户。
/// mark price 由 caller 注入（生产 = engine.markPrice(atTick:)，.m3 收盘、越界 clamp、非 nil）。
/// fail-closed（codex plan-R3-high）：损坏/非法 op 序列 → throw .dbCorrupted，**绝不** trap PositionManager。
/// 一致性：在记录 finalTick 处 profit/returnRate 逐位等于 record.profit/returnRate（复用引擎同款算术）。
public enum ReviewLedger {
    public static func state(atTick t: Int,
                             ops: [TradeOperation],
                             initialCapital: Double,
                             markPriceAtTick: (Int) -> Double) throws -> ReviewLedgerState {
        var position = PositionManager()
        var cash = initialCapital
        // 排序 tiebreaker = **仓库插入序（原始下标）**（codex plan-R4-high）：同 tick 的 buy/sell 必须保记录时序，
        // 否则同 createdAt 时 Swift 非稳定 sort 可能把 sell 排到 buy 前 → 误判 oversell。插入序=记录时序（时间单调）。
        let applicable = ops.enumerated()
            .filter { $0.element.globalTick <= t }
            .sorted { $0.element.globalTick != $1.element.globalTick ? $0.element.globalTick < $1.element.globalTick : $0.offset < $1.offset }
            .map { $0.element }
        for op in applicable {
            // fail-closed 校验：先验后用，杜绝 PositionManager precondition trap（codex plan-R3/R6-high）
            guard op.shares > 0,
                  op.price.isFinite, op.price >= 0,
                  op.commission.isFinite, op.commission >= 0,
                  op.stampDuty.isFinite, op.stampDuty >= 0
            else { throw AppError.persistence(.dbCorrupted) }
            switch op.direction {
            case .buy:
                // PositionManager.buy 前置 totalCost 有限且 **>0**（非 >=0）；且预检加法溢出（totalInvested→inf）+ Int 溢出
                guard op.totalCost.isFinite, op.totalCost > 0,
                      (position.totalInvested + op.totalCost).isFinite,
                      op.shares <= Int.max - position.shares
                else { throw AppError.persistence(.dbCorrupted) }
                // codex whole-branch R5（medium）：损坏 op 流可能买超可用现金——校验 shares/cost/溢出后仍
                // 盲目 `cash -= totalCost` 会让 running cash 变负且照常显示。容差 -1e-6（非 0）防止在
                // cash≈0 的合法「恰好花光」买入上因 FP 舍入误报损坏；真正超支的损坏买入远超此容差。
                let newCash = cash - op.totalCost
                guard newCash.isFinite, newCash >= -1e-6 else { throw AppError.persistence(.dbCorrupted) }
                position.buy(shares: op.shares, totalCost: op.totalCost)
                cash = newCash
            case .sell:
                guard op.shares <= position.shares else { throw AppError.persistence(.dbCorrupted) }  // oversell / sell-before-buy
                // 现金流有限性守卫（codex plan-R11-high）：finite 但极端值 price*shares 可能溢出 inf/NaN
                let notional = op.price * Double(op.shares)
                let proceeds = notional - op.commission - op.stampDuty   // proceeds 可为负（合法，R9），但须有限
                let newCash = cash + proceeds
                guard notional.isFinite, proceeds.isFinite, newCash.isFinite else { throw AppError.persistence(.dbCorrupted) }
                position.sell(shares: op.shares)
                cash = newCash
            }
        }
        let price = markPriceAtTick(t)
        let holdingValue = Double(position.shares) * price
        let total = cash + holdingValue
        guard holdingValue.isFinite, total.isFinite else { throw AppError.persistence(.dbCorrupted) }  // 末尾有限性守卫（codex plan-R11-high）
        let rate = initialCapital == 0 ? 0 : (total - initialCapital) / initialCapital
        let tier: Int
        if total > 0, total.isFinite, holdingValue.isFinite {
            let raw = (holdingValue / total * 5).rounded(.toNearestOrAwayFromZero)
            tier = min(max(Int(raw), 0), 5)
        } else { tier = 0 }
        return ReviewLedgerState(cash: cash, shares: position.shares, averageCost: position.averageCost,
                                 totalCapital: total, returnRate: rate, positionTier: tier)
    }
}

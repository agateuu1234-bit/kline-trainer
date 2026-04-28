import Foundation

// MARK: - Position Manager (E2)
//
// 持仓管理（加权平均成本法）。spec: kline_trainer_plan_v1.5.md §4.2.
//
// 单一职责：维护 shares / averageCost / totalInvested 三元组，对买卖事件做状态更新。
// 不负责：drawdown（见 DrawdownAccumulator）、仓位档位决策（method-arg 注入 totalCapital）、
// 资金流（cashBalance）、佣金/印花税计算（E3 TradeCalculator）。

public struct PositionManager: Codable, Equatable, Sendable {
    public private(set) var shares: Int
    public private(set) var averageCost: Double
    public private(set) var totalInvested: Double

    public init() {
        self.shares = 0
        self.averageCost = 0
        self.totalInvested = 0
    }

    /// 买入。`totalCost` 由调用方算好（含佣金），见 §4.2 买入公式。
    public mutating func buy(shares: Int, totalCost: Double) {
        let newTotal = totalInvested + totalCost
        let newShares = self.shares + shares
        averageCost = newTotal / Double(newShares)
        self.shares = newShares
        totalInvested = newTotal
    }

    /// 卖出。`shares` 是卖出股数；不修改 averageCost（卖出不影响"剩余持仓的成本"），
    /// 但 totalInvested 按剩余股数 × 旧 averageCost 重算（保持二者一致）。
    /// 卖空 → 三元组归零。
    public mutating func sell(shares: Int) {
        self.shares -= shares
        totalInvested = averageCost * Double(self.shares)
        if self.shares == 0 {
            averageCost = 0
            totalInvested = 0
        }
    }

    /// 持仓成本 = 当前持仓股数 × 加权平均成本。
    public var holdingCost: Double { averageCost * Double(shares) }

    /// 当前仓位档位 0~5。0=空仓；1~5 对应 PositionTier.tier1~tier5（即 1/5~5/5 of totalCapital）。
    /// 按"持仓市值占总资金比例"四舍五入到最近档位。
    /// `totalCapital` 由调用方注入（避免 PositionManager 持有资金状态），
    /// `currentPrice` 用当前价计市值（不是 averageCost，因为档位反映"现在的仓位"，不是"历史成本占比"）。
    public func positionTier(totalCapital: Double, currentPrice: Double) -> Int {
        guard totalCapital > 0, shares > 0 else { return 0 }
        let marketValue = Double(shares) * currentPrice
        let ratio = marketValue / totalCapital
        // 五档刻度：0.2 / 0.4 / 0.6 / 0.8 / 1.0
        // 找最接近的档（四舍五入到 0.2 的倍数，clamp 到 [0, 5]）
        let scaled = (ratio / 0.2).rounded()
        return max(0, min(5, Int(scaled)))
    }
}

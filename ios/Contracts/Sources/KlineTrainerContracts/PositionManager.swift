// Kline Trainer Swift Contracts — E2 PositionManager
// Spec: kline_trainer_plan_v1.5.md §4.2 + kline_trainer_modules_v1.4.md §E2

import Foundation

public struct PositionManager: Codable, Equatable, Sendable {
    public private(set) var shares: Int
    public private(set) var averageCost: Double
    public private(set) var totalInvested: Double

    public init(
        shares: Int = 0,
        averageCost: Double = 0,
        totalInvested: Double = 0
    ) {
        self.shares = shares
        self.averageCost = averageCost
        self.totalInvested = totalInvested
    }

    public mutating func buy(shares: Int, totalCost: Double) {
        let newTotal = totalInvested + totalCost
        let newShares = self.shares + shares
        averageCost = newTotal / Double(newShares)
        self.shares = newShares
        totalInvested = newTotal
    }

    public mutating func sell(shares: Int) {
        self.shares -= shares
        totalInvested = averageCost * Double(self.shares)
        if self.shares == 0 {
            averageCost = 0
            totalInvested = 0
        }
    }

    public var holdingCost: Double { averageCost * Double(shares) }
}

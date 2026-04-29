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
        // Codex R2：public init 是 trust boundary 的另一面，必须自守不变量。
        precondition(shares >= 0, "PositionManager.init: shares must be >= 0")
        precondition(averageCost.isFinite && averageCost >= 0, "PositionManager.init: averageCost must be finite & non-negative")
        precondition(totalInvested.isFinite && totalInvested >= 0, "PositionManager.init: totalInvested must be finite & non-negative")
        if shares == 0 {
            precondition(averageCost == 0 && totalInvested == 0, "PositionManager.init: empty position requires zero cost")
        }
        self.shares = shares
        self.averageCost = averageCost
        self.totalInvested = totalInvested
    }

    private enum CodingKeys: String, CodingKey {
        case shares, averageCost, totalInvested
    }

    public init(from decoder: any Decoder) throws {
        // Codex R2：自定义 decoder 走 public init 的不变量校验；非法 JSON throw DecodingError 而非 corrupt 状态。
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let shares = try container.decode(Int.self, forKey: .shares)
        let averageCost = try container.decode(Double.self, forKey: .averageCost)
        let totalInvested = try container.decode(Double.self, forKey: .totalInvested)
        guard shares >= 0,
              averageCost.isFinite, averageCost >= 0,
              totalInvested.isFinite, totalInvested >= 0,
              (shares > 0 || (averageCost == 0 && totalInvested == 0))
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "PositionManager: invariants violated (shares=\(shares), averageCost=\(averageCost), totalInvested=\(totalInvested))"
            ))
        }
        self.init(shares: shares, averageCost: averageCost, totalInvested: totalInvested)
    }

    public mutating func buy(shares: Int, totalCost: Double) {
        // Codex R1：public + Codable 是 trust boundary，守门防 0/0=NaN 与负值 corrupt 持久化状态。
        // 上游 E3 TradeCalculator 仍负责 gating；本 precondition 是 defense-in-depth。
        precondition(shares > 0, "PositionManager.buy: shares must be > 0")
        precondition(totalCost.isFinite && totalCost >= 0, "PositionManager.buy: totalCost must be finite & non-negative")
        let newTotal = totalInvested + totalCost
        let newShares = self.shares + shares
        averageCost = newTotal / Double(newShares)
        self.shares = newShares
        totalInvested = newTotal
    }

    public mutating func sell(shares: Int) {
        precondition(shares > 0, "PositionManager.sell: shares must be > 0")
        precondition(shares <= self.shares, "PositionManager.sell: cannot oversell (shares > current holding)")
        self.shares -= shares
        totalInvested = averageCost * Double(self.shares)
        if self.shares == 0 {
            averageCost = 0
            totalInvested = 0
        }
    }

    public var holdingCost: Double { averageCost * Double(shares) }
}

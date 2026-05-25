// Kline Trainer Swift Contracts — E2 PositionManager 模块
// Spec: kline_trainer_plan_v1.5.md §4.2 + §4.2.1–§4.2.8（trust-boundary 设计理由块）
//       kline_trainer_modules_v1.4.md §E2
//
// 信任边界（§4.2.1）：进程内 buy/sell 输入由上游 E3 TradeCalculator（Result 通道，入口 1a）
// 或 force-close caller 不变量 holding==shares（入口 1b）守门 → 违约 = caller programmer error
// → precondition trap。唯一外部不可信入口 = 持久化 load（SQLite position_data，入口 2）
// → throwing 自定义 init(from:) + invariantsHold。详见 plan §4.2.1–§4.2.8。

import Foundation

public struct PositionManager: Codable, Equatable, Sendable {
    public private(set) var shares: Int
    public private(set) var averageCost: Double
    public private(set) var totalInvested: Double

    // MARK: - 不变量（§4.2.8）

    /// 相对容差：吸收 buy 的除-乘 ULP + JSON Double 十进制往返误差（§4.2.8）。
    /// 用 `==` 或过紧 epsilon 会拒收 app 自写的合法存档（见 PositionManagerCodableTests 双向 demonstrator）。
    static let invariantTolerance: Double = 1e-9

    /// O(1) 不变量校验（§4.2.8 四条 + isFinite/≥0 通用守门防 NaN*0）。
    private static func invariantsHold(shares: Int, averageCost: Double, totalInvested: Double) -> Bool {
        guard shares >= 0,
              averageCost.isFinite, averageCost >= 0,
              totalInvested.isFinite, totalInvested >= 0
        else { return false }
        // (shares == 0) ⟺ (totalInvested == 0)
        guard (shares == 0) == (totalInvested == 0) else { return false }
        guard shares > 0 else { return true }
        // shares > 0 ⟹ averageCost > 0 ∧ averageCost*shares ≈ totalInvested（相对容差，§4.2.8 字面 RHS）
        guard averageCost > 0 else { return false }
        let expected = averageCost * Double(shares)
        guard expected.isFinite else { return false }
        return abs(expected - totalInvested) <= invariantTolerance * Swift.max(1.0, abs(totalInvested))
    }

    // MARK: - 构造

    /// 进程内构造。违约 = caller programmer error → trap（§4.2.2 进程内入口归 trap）。
    public init(shares: Int = 0, averageCost: Double = 0, totalInvested: Double = 0) {
        precondition(
            PositionManager.invariantsHold(shares: shares, averageCost: averageCost, totalInvested: totalInvested),
            "PositionManager.init: invariants violated (shares=\(shares), averageCost=\(averageCost), totalInvested=\(totalInvested))"
        )
        self.shares = shares
        self.averageCost = averageCost
        self.totalInvested = totalInvested
    }

    // MARK: - 持久化（§4.2.1 入口 2：唯一外部不可信入口 → throwing）

    private enum CodingKeys: String, CodingKey {
        case shares, averageCost, totalInvested
    }

    /// 持久化反序列化。损坏/被篡改存档 → throw DecodingError（§4.2.1 入口 2 / §4.2.8）。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let shares = try c.decode(Int.self, forKey: .shares)
        let averageCost = try c.decode(Double.self, forKey: .averageCost)
        let totalInvested = try c.decode(Double.self, forKey: .totalInvested)
        guard PositionManager.invariantsHold(shares: shares, averageCost: averageCost, totalInvested: totalInvested) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "PositionManager: invariants violated (shares=\(shares), averageCost=\(averageCost), totalInvested=\(totalInvested))"
            ))
        }
        self.shares = shares
        self.averageCost = averageCost
        self.totalInvested = totalInvested
    }

    // MARK: - 派生

    /// 持仓成本 = 当前持仓股数 × 加权平均成本（§4.2）。
    public var holdingCost: Double { averageCost * Double(shares) }
}

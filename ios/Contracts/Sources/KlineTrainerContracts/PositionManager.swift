// Kline Trainer Swift Contracts — E2 PositionManager
// Spec: kline_trainer_plan_v1.5.md §4.2 + kline_trainer_modules_v1.4.md §E2
//
// DESIGN / THREAT MODEL（codex review R5 residual accepted by user 2026-04-29）：
// PositionManager 是 SwiftPM intra-package 值类型，被 @MainActor TrainingEngine 持有，
// 序列化进 SQLite `position_data TEXT` 列（单用户 iOS sandbox app）。已建立的防御层级：
//   L1（运行时数学）：buy/sell precondition 守 0/负值/oversell（R1）
//   L2（构造边界）：public init 不变量 + 自定义 init(from:) 走 invariantsHold（R2 + R3）
//   L3（数值守门）：拒零成本正持仓 + 拒非有限中间积溢出（R4）
//
// R5 codex 提出的"buy 内 totalInvested + totalCost 可从合法 finite 状态生 +inf；
// shares + Int.max 可 trap"超出 v1 威胁模型——构造该状态需 averageCost ≈ 1e308 或
// shares ≈ Int.max，与真实股票数据（avg ≤ $10⁴/股、shares ≤ 10⁶/单）相差 280+ 数量级。
// 攻击模型只能来自 SQLite 文件被外部进程篡改，等价 root 已陷落 → 出 v1 sandbox 边界。
// 上游 E3 TradeCalculator（spec §1474, Result<_, TradeReason> 风格）会在真实交易路径
// reject 任何不合理金额（min commission, fund-insufficient, force-close 等），buy/sell
// 不会被 1e308 类输入触达。L1-L3 已是 defense-in-depth 而非 happy-path 正确性问题。
// 若 v2 需要支持非 sandbox 持久化（云同步、外部数据导入），重新评估 L4（throwing API）。

import Foundation

public struct PositionManager: Codable, Equatable, Sendable {
    public private(set) var shares: Int
    public private(set) var averageCost: Double
    public private(set) var totalInvested: Double

    /// Validate state invariants. shares > 0 时 totalInvested ≈ averageCost * shares
    /// 容差 = 1e-9 × max(1, |operands|)（覆盖 buy 后的 IEEE 754 division-multiplication ULP 误差；
    /// sell 后 totalInvested = averageCost * shares 精确成立）。
    private static func invariantsHold(shares: Int, averageCost: Double, totalInvested: Double) -> Bool {
        guard shares >= 0,
              averageCost.isFinite, averageCost >= 0,
              totalInvested.isFinite, totalInvested >= 0
        else { return false }
        if shares == 0 {
            return averageCost == 0 && totalInvested == 0
        }
        // Codex R4-1：shares > 0 ⟹ averageCost > 0 && totalInvested > 0（实际交易必有正成本）
        guard averageCost > 0, totalInvested > 0 else { return false }
        // Codex R4-2：拒绝非有限中间积，防止 avg × shares 溢出致容差变 +inf 而 fall-open
        let expected = averageCost * Double(shares)
        guard expected.isFinite else { return false }
        let tolerance = 1e-9 * Swift.max(1.0, Swift.max(abs(totalInvested), abs(expected)))
        return abs(totalInvested - expected) <= tolerance
    }

    public init(
        shares: Int = 0,
        averageCost: Double = 0,
        totalInvested: Double = 0
    ) {
        // Codex R2/R3：public init 自守不变量（含一致性容差）。callers 提供非法值直接 trap，因这是 caller bug。
        precondition(
            PositionManager.invariantsHold(shares: shares, averageCost: averageCost, totalInvested: totalInvested),
            "PositionManager.init: invariants violated (shares=\(shares), averageCost=\(averageCost), totalInvested=\(totalInvested))"
        )
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
        guard PositionManager.invariantsHold(shares: shares, averageCost: averageCost, totalInvested: totalInvested) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "PositionManager: invariants violated (shares=\(shares), averageCost=\(averageCost), totalInvested=\(totalInvested))"
            ))
        }
        self.init(shares: shares, averageCost: averageCost, totalInvested: totalInvested)
    }

    /// Codex R7 spec drift（user-approved 2026-04-29）：
    /// spec §4.2 literal 是 `mutating func buy/sell`（无 throws）；codex 主张 public mutator 不应用 precondition crash 处理 routine rejection。
    /// drift to throwing API：复用 M0.4 `TradeReason.invalidShareCount` / `.insufficientHolding`；E5 TrainingEngine 调用方 try + `.mapError { AppError.trade($0) }`（modules_v1.4 line 1509 已示）。
    public mutating func buy(shares: Int, totalCost: Double) throws {
        guard shares > 0,
              totalCost.isFinite, totalCost > 0
        else { throw TradeReason.invalidShareCount }
        let (newShares, sharesOverflow) = self.shares.addingReportingOverflow(shares)
        guard !sharesOverflow else { throw TradeReason.invalidShareCount }
        let newTotal = totalInvested + totalCost
        guard newTotal.isFinite else { throw TradeReason.invalidShareCount }
        let newAverage = newTotal / Double(newShares)
        guard PositionManager.invariantsHold(shares: newShares, averageCost: newAverage, totalInvested: newTotal)
        else { throw TradeReason.invalidShareCount }
        self.shares = newShares
        self.averageCost = newAverage
        self.totalInvested = newTotal
    }

    public mutating func sell(shares: Int) throws {
        guard shares > 0 else { throw TradeReason.invalidShareCount }
        guard shares <= self.shares else { throw TradeReason.insufficientHolding }
        let newShares = self.shares - shares
        let newAverage: Double
        let newTotal: Double
        if newShares == 0 {
            newAverage = 0
            newTotal = 0
        } else {
            newAverage = averageCost
            newTotal = averageCost * Double(newShares)
        }
        guard PositionManager.invariantsHold(shares: newShares, averageCost: newAverage, totalInvested: newTotal)
        else { throw TradeReason.invalidShareCount }
        self.shares = newShares
        self.averageCost = newAverage
        self.totalInvested = newTotal
    }

    public var holdingCost: Double { averageCost * Double(shares) }
}

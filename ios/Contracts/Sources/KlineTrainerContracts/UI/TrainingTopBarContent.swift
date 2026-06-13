// ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift
// Kline Trainer Swift Contracts — U2 顶栏数值格式化纯值（Wave 2 顺位 9）
// Spec: kline_trainer_plan_v1.5.md §6.2.1 L905-918（总资金 / 持仓成本 / 收益率）。
//
// 平台无关纯值（host 全测）：把 engine 实时数值格式化为顶栏显示串。格式口径**对齐** SettlementContent
// （`¥ ` + 一空格 + POSIX 千分位 + 2 位小数；收益率 `%+.2f` + `-0.0` 归一）—— 与 U3 结算窗同 ¥/% 口径。
// SettlementContent 的 formatter 为 private static（U3 冻结），本文件独立实现**同口径**（不抽共享，避免动冻结 U3）。
// 决议 D8（Wave 3 顺位 7 兑现）：加「仓位 X/5」= `position`，由 engine.currentPositionTier（RFC §4.1/§4.4b
// 派生公式 = round(持仓市值/当前总资金×5)，clamp 0...5）格式化；不在本壳臆造公式（顺位 6 accessor 已钉死）。

import Foundation

public struct TrainingTopBarContent: Equatable, Sendable {
    public let totalCapital: String   // "¥ 102,345.67"
    public let holdingCost: String    // "¥ 0.00"
    public let position: String       // "仓位 3/5"（Wave 3 顺位 7）
    public let returnRate: String     // "+2.34%" / "-8.32%" / "+0.00%"

    public init(totalCapital: Double, holdingCost: Double, returnRate: Double, positionTier: Int) {
        self.totalCapital = Self.currency(totalCapital)
        self.holdingCost = Self.currency(holdingCost)
        self.position = "仓位 \(positionTier)/5"
        self.returnRate = Self.percent(returnRate)
    }

    /// `¥` + 一空格 + 千分位 + 强制 2 位小数（POSIX，跨 locale 稳定）。同 SettlementContent.formatCapital。
    private static func currency(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.decimalSeparator = "."
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        // `??` 兜底实际不可达（NumberFormatter 对 NaN/Inf 返 "NaN"/"+∞" 非 nil）；留作纵深防御，同
        // SettlementContent.formatCapital L58-59。业务上 totalCapital/holdingCost 非负且有限（M0.3 冻结）。
        let body = f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "¥ \(body)"
    }

    /// 收益率小数 ×100 + `%+.2f` 带符号 + `%`；`-0.0` 归一为 `+0.00%`。同 SettlementContent.formatSignedRate。
    private static func percent(_ rate: Double) -> String {
        let raw = rate * 100
        let pct = (raw == 0) ? 0.0 : raw                  // IEEE-754：±0 均 ==0 → 归一 +0.0
        return "\(String(format: "%+.2f", pct))%"
    }
}

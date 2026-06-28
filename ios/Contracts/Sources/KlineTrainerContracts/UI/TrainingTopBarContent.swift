// ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift
// Kline Trainer Swift Contracts — U2 顶栏数值格式化纯值（Wave 2 顺位 9）
// Spec: kline_trainer_plan_v1.5.md §6.2.1 L905-918（总资金 / 持仓成本 / 收益率）。
//
// 平台无关纯值（host 全测）：把 engine 实时数值格式化为顶栏显示串。格式口径**对齐** SettlementContent
// （`¥ ` + 一空格 + POSIX 千分位 + 2 位小数；收益率 `%+.2f` + `-0.0` 归一）—— 与 U3 结算窗同 ¥/% 口径。
// SettlementContent 的 formatter 为 private static（U3 冻结），本文件独立实现**同口径**（不抽共享，避免动冻结 U3）。
// 决议 D8（Wave 3 顺位 7 兑现）：加「仓位 X/5」= `position`，由 engine.currentPositionTier（RFC §4.1/§4.4b
// 派生公式 = round(持仓市值/当前总资金×5)，clamp 0...5）格式化；不在本壳臆造公式（顺位 6 accessor 已钉死）。
// RFC-B D4 语义纠正：holdingCostPerShare = 每股成本（价位级，非总额），init 参数名 averageCost。
// 新增 sharesText（千分位 + " 股"）、stockNameDisplay（标的名隐显）、positionShort（"X/5"）。

import Foundation

public struct TrainingTopBarContent: Equatable, Sendable {
    public let totalCapital: String        // "¥ 99,999,999.00"
    public let holdingCostPerShare: String // 每股成本 "¥ 1,683.50"（RFC-B D4：非总额）
    public let sharesText: String          // "9,999,999 股"
    public let position: String            // "仓位 3/5"（兼容）
    public let positionShort: String       // "3/5"（顶栏格数值，免字符串截取）
    public let returnRate: String          // "+2.34%"
    public let holdingPnL: String          // RFC-A A3：持仓未实现盈亏 "+¥ 2,000.00 (+20.00%)"
    public let stockNameDisplay: String    // "贵州茅台（600519）" 或 "训练标的 · 盲测"

    public init(totalCapital: Double, averageCost: Double, shares: Int,
                returnRate: Double, positionTier: Int,
                stockName: String?, stockCode: String?,
                currentPrice: Double = 0.0) {
        self.totalCapital = Self.currency(totalCapital)
        self.holdingCostPerShare = Self.currency(averageCost)
        self.sharesText = "\(Self.grouped(shares)) 股"
        self.position = "仓位 \(positionTier)/5"
        self.positionShort = "\(positionTier)/5"
        self.returnRate = Self.percent(returnRate)
        // RFC-A A3：持仓浮动盈亏（元 + %）= (现价 − 每股成本) × 股数。
        if shares > 0 && averageCost > 0 {
            let amount = (currentPrice - averageCost) * Double(shares)
            let pct = (currentPrice - averageCost) / averageCost
            self.holdingPnL = "\(Self.signedCurrency(amount)) (\(Self.percent(pct)))"
        } else {
            self.holdingPnL = "\(Self.signedCurrency(0)) (\(Self.percent(0)))"
        }
        if let name = stockName, let code = stockCode {
            self.stockNameDisplay = "\(name)（\(code)）"   // 全角括号，同 formatStock 口径
        } else {
            self.stockNameDisplay = "训练标的 · 盲测"
        }
    }

    /// 整数千分位（POSIX，跨 locale 稳定）。
    private static func grouped(_ value: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
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

    /// 带符号 `+¥ 1,234.56` / `-¥ 1,234.56`（±0 归一为 `+`）。RFC-A A3 holdingPnL 用。
    private static func signedCurrency(_ value: Double) -> String {
        let v = (value == 0) ? 0.0 : value
        let sign = v >= 0 ? "+" : "-"
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal; f.usesGroupingSeparator = true; f.groupingSeparator = ","
        f.decimalSeparator = "."; f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        let body = f.string(from: NSNumber(value: abs(v))) ?? String(format: "%.2f", abs(v))
        return "\(sign)¥ \(body)"
    }
}

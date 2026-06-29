// ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift
// Kline Trainer Swift Contracts — U2 顶栏数值格式化纯值（Wave 2 顺位 9）
// Spec: kline_trainer_plan_v1.5.md §6.2.1 L905-918（总资金 / 持仓成本 / 收益率）。
//
// 平台无关纯值（host 全测）：把 engine 实时数值格式化为顶栏显示串。
// SettlementContent 的 formatter 为 private static（U3 冻结），本文件独立实现（不抽共享，避免动冻结 U3）。
// 决议 D8（Wave 3 顺位 7 兑现）：加「仓位 X/5」= `position`，由 engine.currentPositionTier（RFC §4.1/§4.4b
// 派生公式 = round(持仓市值/当前总资金×5)，clamp 0...5）格式化；不在本壳臆造公式（顺位 6 accessor 已钉死）。
// RFC-B D4 语义纠正：holdingCostPerShare = 每股成本（价位级，非总额），init 参数名 averageCost。
// Task 1 格式改造：totalCapital 无小数无空格、holdingCostPerShare 去 ¥ 2 位、sharesText 去「股」后缀；
// holdingPnL 拆三字段：holdingPnLAmount（带符号无小数）/ holdingPnLPercent（2 位）/ holdingPnLSign（Int）。

import Foundation

public struct TrainingTopBarContent: Equatable, Sendable {
    public let totalCapital: String        // "¥99,999,999"（无小数无空格）
    public let holdingCostPerShare: String // 每股成本 "1,683.50"（无 ¥，2 位，RFC-B D4：非总额）
    public let sharesText: String          // "9,999,999"（千分位，无「股」后缀）
    public let position: String            // "仓位 3/5"（兼容）
    public let positionShort: String       // "3/5"（顶栏格数值，免字符串截取）
    public let returnRate: String          // "+2.34%"
    public let holdingPnLAmount: String    // "+¥12,345,678"（无小数带符号）
    public let holdingPnLPercent: String   // "+4,900.00%"（2 位 signed-zero）
    public let holdingPnLSign: Int         // +1 盈 / -1 亏 / 0 平·空仓
    public let stockNameDisplay: String    // "贵州茅台（600519）" 或 "训练标的 · 盲测"

    public init(totalCapital: Double, averageCost: Double, shares: Int,
                returnRate: Double, positionTier: Int,
                stockName: String?, stockCode: String?,
                currentPrice: Double = 0.0) {
        self.totalCapital = Self.currencyInt(totalCapital)
        self.holdingCostPerShare = Self.decimal2(averageCost)
        self.sharesText = Self.grouped(shares)
        self.position = "仓位 \(positionTier)/5"
        self.positionShort = "\(positionTier)/5"
        self.returnRate = Self.percent(returnRate)
        // 持仓浮动盈亏（元 + %）= (现价 − 每股成本) × 股数。
        if shares > 0 && averageCost > 0 {
            let amount = (currentPrice - averageCost) * Double(shares)
            let pct = (currentPrice - averageCost) / averageCost
            self.holdingPnLAmount = Self.signedCurrencyInt(amount)
            self.holdingPnLPercent = Self.percent(pct)
            self.holdingPnLSign = amount > 0 ? 1 : (amount < 0 ? -1 : 0)
        } else {
            self.holdingPnLAmount = Self.signedCurrencyInt(0)
            self.holdingPnLPercent = Self.percent(0)
            self.holdingPnLSign = 0
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

    /// `¥` + 千分位 + 0 位小数（无空格）。总资金用。
    private static func currencyInt(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal
        f.usesGroupingSeparator = true; f.groupingSeparator = ","
        f.maximumFractionDigits = 0; f.minimumFractionDigits = 0
        let body = f.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
        return "¥\(body)"
    }

    /// 带符号 `+¥12,345,678` / `-¥12,345,678`（±0 归一 `+`），0 位小数无空格。浮动盈亏金额用。
    private static func signedCurrencyInt(_ value: Double) -> String {
        let v = (value == 0) ? 0.0 : value
        let sign = v >= 0 ? "+" : "-"
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal
        f.usesGroupingSeparator = true; f.groupingSeparator = ","
        f.maximumFractionDigits = 0; f.minimumFractionDigits = 0
        let body = f.string(from: NSNumber(value: abs(v))) ?? String(format: "%.0f", abs(v))
        return "\(sign)¥\(body)"
    }

    /// 千分位 + 2 位小数，**无 ¥**（成本/股用，省宽防截断）。
    private static func decimal2(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal
        f.usesGroupingSeparator = true; f.groupingSeparator = ","
        f.decimalSeparator = "."; f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// 收益率小数 ×100 + `%+.2f` 带符号 + `%`；`-0.0` 归一为 `+0.00%`。同 SettlementContent.formatSignedRate。
    private static func percent(_ rate: Double) -> String {
        let raw = rate * 100
        let pct = (raw == 0) ? 0.0 : raw                  // IEEE-754：±0 均 ==0 → 归一 +0.0
        return "\(String(format: "%+.2f", pct))%"
    }
}

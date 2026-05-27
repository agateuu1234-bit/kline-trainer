// ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
// Spec: kline_trainer_plan_v1.5.md §6.3 L988-1009 + plan 2026-05-27-pr-u3-settlement-view.md
//
// 平台无关纯值类型：把 TrainingRecord 的 7 个字段格式化成 SwiftUI 显示用字符串。
// 平台守卫：仅 import Foundation，不 import SwiftUI/UIKit/CoreGraphics —— host swift test 全测。
//
// 决议（D1-D8）：
// - D3 ¥ + 一空格 + 千分位 + 2 位小数
// - D4 月份零填充
// - D5 returnRate / maxDrawdown 显式带符号（含零值 +0.00%）
// - D6 returnRate / maxDrawdown 在 TrainingRecord 存为小数，UI 显示 ×100 + %
// - D7 stock = "name（code）" 中文全角括号
// - D8 买卖次数 + 一空格 + "次"

import Foundation

public struct SettlementContent: Equatable, Sendable {
    public let stock: String        // "贵州茅台（600519）"
    public let startMonth: String   // "2021年08月"
    public let totalCapital: String // "¥ 102,345.67"
    public let returnRate: String   // "+2.34%"
    public let maxDrawdown: String  // "-8.32%"
    public let buyCount: String     // "4 次"
    public let sellCount: String    // "3 次"

    public init(record: TrainingRecord) {
        self.stock = Self.formatStock(name: record.stockName, code: record.stockCode)
        self.startMonth = Self.formatStartMonth(year: record.startYear, month: record.startMonth)
        self.totalCapital = Self.formatCapital(record.totalCapital)
        self.returnRate = Self.formatSignedRate(record.returnRate)
        self.maxDrawdown = Self.formatSignedRate(record.maxDrawdown)
        self.buyCount = "\(record.buyCount) 次"
        self.sellCount = "\(record.sellCount) 次"
    }

    // MARK: - 内部纯函数（static 便于 Self.xxx 调用，避免实例方法 capture）

    /// D7：name（code），全角括号。
    static func formatStock(name: String, code: String) -> String {
        "\(name)（\(code)）"
    }

    /// D4：年 + 零填充月 + "月"。
    static func formatStartMonth(year: Int, month: Int) -> String {
        "\(year)年\(String(format: "%02d", month))月"
    }

    /// D3：¥ + 一空格 + 千分位 + 强制 2 位小数。Locale 中性（POSIX）避免设备 Locale 影响千分位字符（强制英文逗号）。
    static func formatCapital(_ value: Double) -> String {
        let fmt = NumberFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.numberStyle = .decimal
        fmt.usesGroupingSeparator = true
        fmt.groupingSeparator = ","
        fmt.decimalSeparator = "."
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        // NumberFormatter(decimal) 对 NaN/Inf 实测返回 "NaN"/"+∞"/"-∞" 非 nil → ?? 兜底实际不可达；
        // 留作 Foundation 行为变化的纵深防御。业务上 TrainingRecord.totalCapital 不允许 NaN（M0.3 已冻）。
        let body = fmt.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "¥ \(body)"
    }

    /// D5/D6：value 是小数（0.0234 = 2.34%），×100 + 2 位小数 + 显式 ±。零值 → "+0.00%"。
    /// **D5 signed-zero 规范化（R1-C1）**：`String(format: "%+.2f", -0.0)` 实测产 "-0.00"，违反决议；
    /// IEEE-754 `==0` 在 `+0.0` 和 `-0.0` 均 true → 归一化为 `+0.0` 再格式化。
    /// 对 ULP 噪声本身不做阈值化（E3 写入语义零是字面 0，不是 1e-16 级；若 E3 后续出现 ULP 噪声会暴露另一处问题，本 PR 不预阻断）。
    static func formatSignedRate(_ value: Double) -> String {
        let raw = value * 100
        let pct = (raw == 0) ? 0.0 : raw
        let body = String(format: "%+.2f", pct)
        return "\(body)%"
    }
}

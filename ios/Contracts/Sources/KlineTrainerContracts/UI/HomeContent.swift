// ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift
// Spec: kline_trainer_plan_v1.5.md §6.1 L849-899 + docs/superpowers/specs/2026-06-07-wave2-u1-home-view-design.md
//
// 平台无关纯值类型：把训练统计 / 历史记录 / 按钮态 / 缓存态格式化成 HomeView 显示用字符串与语义标志。
// 平台守卫：仅 import Foundation，不 import SwiftUI/UIKit —— host swift test 全测。
// 格式化全部自包含（不复用 SettlementContent，沿用 U6 D4「避免 sibling UI content 耦合」）。
//
// 决议（见设计文档 §四 D1-D13）。

import Foundation

/// 盈亏色语义（view 映射红/绿/默认，Content 不含颜色）。
public enum ProfitSign: Equatable, Sendable {
    case positive, negative, zero
}

/// 单条历史记录的显示快照（§6.1.3）。
public struct HomeHistoryRow: Identifiable, Equatable, Sendable {
    public let id: Int64            // 已解包非 nil（D12）。SwiftUI 身份 + onSelectRecord 回传
    public let dateTime: String     // "2024-03-15 20:00"
    public let stock: String        // "贵州茅台（600519）"
    public let startMonth: String   // "2021年08月"
    public let totalCapital: String // "¥ 102,345.67"
    public let profitAndRate: String // "+¥ 2,345.67（+2.34%）"
    public let sign: ProfitSign
}

public struct HomeContent: Equatable, Sendable {
    // 统计栏 §6.1.1
    public let totalSessions: String
    public let winRate: String
    public let totalCapital: String
    // 按钮 §6.1.2
    public let primaryActionLabel: String
    public let isResuming: Bool
    public let hasCachedSets: Bool
    // 历史列表 §6.1.3
    public let rows: [HomeHistoryRow]
    public let isHistoryEmpty: Bool

    public init(statistics: (totalCount: Int, winCount: Int, currentCapital: Double),
                configuredCapital: Double,
                records: [TrainingRecord],
                hasPending: Bool,
                hasCachedSets: Bool,
                timeZone: TimeZone = .current) {
        // 统计栏 §6.1.1
        self.totalSessions = "\(statistics.totalCount) 局"   // M2：N 取 statistics.totalCount，非 rows.count
        self.winRate = Self.formatWinRate(winCount: statistics.winCount, totalCount: statistics.totalCount)
        // D13：回退判据 = totalCount==0（与 coordinator.startingCapital 字面一致），>0 无条件显示 currentCapital
        let capitalToShow = statistics.totalCount == 0 ? configuredCapital : statistics.currentCapital
        self.totalCapital = Self.formatCapital(capitalToShow)
        // 按钮 §6.1.2
        self.isResuming = hasPending
        self.primaryActionLabel = hasPending ? "继续训练" : "开始训练"
        self.hasCachedSets = hasCachedSets
        // 历史列表 §6.1.3 —— D12 compactMap 跳 nil-id；D10 排序 createdAt desc + id desc 兜底
        let valid: [(id: Int64, record: TrainingRecord)] = records.compactMap { record in
            record.id.map { (id: $0, record: record) }
        }
        let sorted = valid.sorted { lhs, rhs in
            lhs.record.createdAt != rhs.record.createdAt
                ? lhs.record.createdAt > rhs.record.createdAt
                : lhs.id > rhs.id
        }
        self.rows = sorted.map { Self.makeRow(id: $0.id, record: $0.record, timeZone: timeZone) }
        self.isHistoryEmpty = self.rows.isEmpty
    }

    // MARK: - 纯格式化 static 函数（自包含）

    /// D2/D7：胜率整数百分比。totalCount==0 → "—"（U+2014）。否则 winCount/totalCount×100，
    /// `.rounded()` = `.toNearestOrAwayFromZero`（半数远离零）。
    static func formatWinRate(winCount: Int, totalCount: Int) -> String {
        guard totalCount > 0 else { return "—" }
        let pct = (Double(winCount) / Double(totalCount) * 100).rounded()
        return "\(Int(pct))%"
    }

    /// D3：¥ + 一空格 + POSIX 千分位 + 强制 2 位小数。
    static func formatCapital(_ value: Double) -> String {
        "¥ \(groupedDecimal(value))"
    }

    /// POSIX 千分位 + 2 位小数（无 ¥）。Locale 中性（强制英文逗号），NaN/Inf 兜底 %.2f。
    static func groupedDecimal(_ value: Double) -> String {
        let fmt = NumberFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.numberStyle = .decimal
        fmt.usesGroupingSeparator = true
        fmt.groupingSeparator = ","
        fmt.decimalSeparator = "."
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        return fmt.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// D4：name（code），全角括号 U+FF08/U+FF09。
    static func formatStock(name: String, code: String) -> String {
        "\(name)（\(code)）"
    }

    /// 年 + 零填充月 + "月"。
    static func formatStartMonth(year: Int, month: Int) -> String {
        "\(year)年\(String(format: "%02d", month))月"
    }

    /// D5：epoch 秒 → "yyyy-MM-dd HH:mm"，POSIX locale + 注入 timeZone。
    static func formatDateTime(epochSeconds: Int64, timeZone: TimeZone) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    }

    /// D8：profit符号 + "¥ " + 千分位(|profit|) + "（" + rate符号 + (|rate|×100, 2 位) + "%）"。
    /// profit 与 returnRate 符号各自独立按 ==0→"+"（含 -0.0）归一化（IEEE：-0.0 < 0 为 false）。
    static func formatProfitAndRate(profit: Double, returnRate: Double) -> String {
        let profitPart = "\(signChar(profit))¥ \(groupedDecimal(abs(profit)))"
        let ratePart = "\(signChar(returnRate))\(String(format: "%.2f", abs(returnRate) * 100))%"
        return "\(profitPart)（\(ratePart)）"
    }

    /// signed-zero 安全：-0.0 < 0 == false → "+"。
    static func signChar(_ value: Double) -> String { value < 0 ? "-" : "+" }

    /// D9：色语义据 profit（非 returnRate）。-0.0 落 .zero。
    static func profitSign(_ profit: Double) -> ProfitSign {
        if profit > 0 { return .positive }
        if profit < 0 { return .negative }
        return .zero
    }

    /// 从已解包 id + TrainingRecord 组装历史行显示快照（D12：id 已由 compactMap 过滤非 nil）。
    static func makeRow(id: Int64, record: TrainingRecord, timeZone: TimeZone) -> HomeHistoryRow {
        HomeHistoryRow(
            id: id,
            dateTime: formatDateTime(epochSeconds: record.createdAt, timeZone: timeZone),
            stock: formatStock(name: record.stockName, code: record.stockCode),
            startMonth: formatStartMonth(year: record.startYear, month: record.startMonth),
            totalCapital: formatCapital(record.totalCapital),
            profitAndRate: formatProfitAndRate(profit: record.profit, returnRate: record.returnRate),
            sign: profitSign(record.profit))
    }
}

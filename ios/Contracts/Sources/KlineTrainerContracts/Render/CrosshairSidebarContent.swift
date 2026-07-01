// ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairSidebarContent.swift
// Kline Trainer Swift Contracts — RFC-C 十字光标悬浮信息栏装配（平台无关纯值类型）
// Spec: docs/superpowers/specs/2026-06-30-crosshair-sidebar-period-swipe-design.md §4.5
//
// 不 import UIKit：字段/格式化/派生/颜色归类/停靠判定全 host swift test 真断言。
// 颜色基准 = 前一根收盘(prevClose)；均价单位自检 = 均价 ∈ [低,高] 才显（防 手/元 100× 假值）。

import Foundation
import CoreGraphics

public struct CrosshairSidebarContent: Equatable, Sendable {

    /// 悬浮栏停靠侧（光标偏右靠左、偏左/居中靠右，防手指遮挡）。
    public enum DockSide: Equatable, Sendable { case left, right }

    /// 值颜色：up=红(涨) / down=绿(跌) / flat=白(平/无基准) / neutral=黄(非方向字段)。
    public enum ValueColor: Equatable, Sendable { case up, down, flat, neutral }

    public struct Row: Equatable, Sendable {
        public let label: String
        public let value: String
        public let color: ValueColor
        public init(label: String, value: String, color: ValueColor) {
            self.label = label; self.value = value; self.color = color
        }
    }

    public let cursorPriceText: String     // 栏顶居中实时价（无标签）
    public let cursorPriceColor: ValueColor
    public let dateText: String            // 日期(左)
    public let timeText: String?           // 时间(右)，日/周/月为 nil
    public let rows: [Row]                  // 开/高/低/收/涨跌/涨跌幅/[均价]/成交量/[成交额]
    public let dock: DockSide

    // MARK: - 装配

    public static func make(candle: KLineCandle, previousClose: Double?, cursorPrice: Double,
                            snappedX: CGFloat, mainChartMidX: CGFloat) -> CrosshairSidebarContent {
        let dock: DockSide = snappedX > mainChartMidX ? .left : .right

        let cursorColor = directionColor(value: cursorPrice, base: previousClose)
        let cursorText = price2(cursorPrice)

        let (dateText, timeText) = formatDateTime(datetime: candle.datetime, period: candle.period)

        // 所有价格字段（开/高/低/收）按方向上色 = vs 前一根收盘（红高/绿低/白平），对齐主流（文华财经）。
        var rows: [Row] = [
            Row(label: "开", value: price2(candle.open), color: directionColor(value: candle.open, base: previousClose)),
            Row(label: "高", value: price2(candle.high), color: directionColor(value: candle.high, base: previousClose)),
            Row(label: "低", value: price2(candle.low), color: directionColor(value: candle.low, base: previousClose)),
            Row(label: "收", value: price2(candle.close), color: directionColor(value: candle.close, base: previousClose)),
        ]

        // 涨跌 / 涨跌幅（vs 前收；首根无基准 → 「—」中性白）
        if let prev = previousClose, prev != 0 {
            let diff = candle.close - prev
            let pct = diff / prev * 100
            let color: ValueColor = diff > 0 ? .up : (diff < 0 ? .down : .flat)
            rows.append(Row(label: "涨跌", value: signed2(diff), color: color))
            rows.append(Row(label: "涨跌幅", value: signedPct2(pct), color: color))
        } else {
            rows.append(Row(label: "涨跌", value: "—", color: .flat))
            rows.append(Row(label: "涨跌幅", value: "—", color: .flat))
        }

        // 均价（成交额÷成交量）+ 单位自检（∈ [低,高] 才显）
        if let amount = candle.amount, candle.volume > 0 {
            let avg = amount / Double(candle.volume)
            if avg >= candle.low && avg <= candle.high {
                rows.append(Row(label: "均价", value: price2(avg), color: directionColor(value: avg, base: previousClose)))
            }
        }

        // 成交量（千分位 + 股）：importer 约定 amount = close × volume → volume 为 share-count，单位「股」非「手」（codex R3-M）
        rows.append(Row(label: "成交量", value: groupedInt(candle.volume) + " 股", color: .neutral))

        // 成交额（amount 非 nil 才显；亿/万 自适应）
        if let amount = candle.amount {
            rows.append(Row(label: "成交额", value: formatAmount(amount), color: .neutral))
        }

        return CrosshairSidebarContent(
            cursorPriceText: cursorText, cursorPriceColor: cursorColor,
            dateText: dateText, timeText: timeText, rows: rows, dock: dock)
    }

    // MARK: - 纯辅助（host 测）

    /// 方向色：value vs base（前收）；> 红、< 绿、== 白；base==nil → 白(无基准)。
    static func directionColor(value: Double, base: Double?) -> ValueColor {
        guard let base else { return .flat }
        if value > base { return .up }
        if value < base { return .down }
        return .flat
    }

    static func price2(_ v: Double) -> String { String(format: "%.2f", v) }
    static func signed2(_ v: Double) -> String { (v >= 0 ? "+" : "") + String(format: "%.2f", v) }
    static func signedPct2(_ v: Double) -> String { (v >= 0 ? "+" : "") + String(format: "%.2f", v) + "%" }

    /// 千分位整数（locale 无关手工分组，正负皆可）。左→右扫描，避开 ReversedCollection 类型坑（codex M2）。
    static func groupedInt(_ n: Int64) -> String {
        let neg = n < 0
        let s = String(n.magnitude)
        let count = s.count
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && (count - i) % 3 == 0 { out.append(",") }   // 每满 3 位前插逗号
            out.append(ch)
        }
        return (neg ? "-" : "") + out
    }

    /// 成交额：≥1亿 显「X.XX 亿」、≥1万 显「X.XX 万」、否则千分位元。
    static func formatAmount(_ a: Double) -> String {
        if a >= 1e8 { return String(format: "%.2f 亿", a / 1e8) }
        if a >= 1e4 { return String(format: "%.2f 万", a / 1e4) }
        return groupedInt(Int64(a)) + " 元"
    }

    static func isIntraday(_ p: Period) -> Bool {
        switch p { case .m3, .m15, .m60: return true; default: return false }
    }

    private nonisolated(unsafe) static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private nonisolated(unsafe) static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 日期/时间格式化（UTC+8 / en_US_POSIX）。日内 → (yyyy-MM-dd, HH:mm)；日/周/月 → (yyyy-MM-dd, nil)。
    static func formatDateTime(datetime: Int64, period: Period) -> (String, String?) {
        let date = Date(timeIntervalSince1970: TimeInterval(datetime))
        let dateText = dateFormatter.string(from: date)
        guard isIntraday(period) else { return (dateText, nil) }
        return (dateText, timeFormatter.string(from: date))
    }

    public init(cursorPriceText: String, cursorPriceColor: ValueColor,
                dateText: String, timeText: String?, rows: [Row], dock: DockSide) {
        self.cursorPriceText = cursorPriceText
        self.cursorPriceColor = cursorPriceColor
        self.dateText = dateText
        self.timeText = timeText
        self.rows = rows
        self.dock = dock
    }
}

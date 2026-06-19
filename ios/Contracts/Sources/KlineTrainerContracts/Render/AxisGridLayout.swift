// Kline Trainer Swift Contracts — RFC #3 坐标轴/网格/周期标注 布局（平台无关纯函数）
// Spec: docs/superpowers/specs/2026-06-20-chart-axes-grid-period-design.md
//
// 不 import UIKit：所有几何/文本字符串在 host swift test 真断言（同 CrosshairLayout/MainChartLayout）。
// drawXxx 的 UIKit 描绘薄层在 KLineView+AxisGrid.swift（#if canImport(UIKit)）。
// 全部几何镜像 mapper（priceToY/indexToX/valueToY），不写第二套公式。

import Foundation
import CoreGraphics

/// 坐标轴/网格/周期标注解析结果（单次 draw-time 解析，绘制层消费两遍：网格最前、标签最后）。
struct AxisGridResolved: Equatable, Sendable {
    let gridLines: [AxisGridLayout.LineSegment]   // 水平(价格档/量max/macd0) + 垂直(时间档)
    let priceLabels: [AxisGridLayout.Label]       // 右缘价格刻度
    let timeLabels: [AxisGridLayout.Label]        // 底部时间刻度
    let volumeLabel: AxisGridLayout.Label?        // 量图最大量（万/亿）
    let macdZeroLabel: AxisGridLayout.Label?       // MACD 0 轴
    let periodLabel: AxisGridLayout.Label         // 左上角周期角标
}

enum AxisGridLayout {

    /// 标签盒（rect + text），形状镜像 CrosshairResolved.Label。
    struct Label: Equatable, Sendable {
        let rect: CGRect
        let text: String
    }

    /// 线段（端点），形状镜像 CrosshairLines.LineSegment。
    struct LineSegment: Equatable, Sendable {
        let from: CGPoint
        let to: CGPoint
    }

    private static let maxTicks = 6

    /// 价格刻度 + 对齐的水平网格线（主图）。退化/非有限区间 → 空（守卫，防 log10(0)/除零）。
    static func priceTicks(mapper: CoordinateMapper) -> (labels: [Label], gridLines: [LineSegment]) {
        let lo = mapper.viewport.priceRange.min
        let hi = mapper.viewport.priceRange.max
        let span = hi - lo
        guard span.isFinite, span > 0 else { return ([], []) }
        let frame = mapper.viewport.mainChartFrame
        let labelW: CGFloat = 56, labelH: CGFloat = 16
        var labels: [Label] = []
        var lines: [LineSegment] = []
        for value in niceTickValues(lo: lo, hi: hi) {
            let y = mapper.priceToY(value)
            lines.append(LineSegment(from: CGPoint(x: frame.minX, y: y),
                                     to: CGPoint(x: frame.maxX, y: y)))
            let rect = CGRect(x: frame.maxX - labelW, y: y - labelH / 2, width: labelW, height: labelH)
            labels.append(Label(rect: rect, text: String(format: "%.2f", value)))
        }
        return (labels, lines)
    }

    /// nice-step：候选 {1,2,5}×10^k 由细到粗，取满足 count≤maxTicks 的最小 step（不超 6 档的最细网格）。
    /// 调用方已保 span>0、有限。极窄区间致空 → 回退单档（区间中点）。
    private static func niceTickValues(lo: Double, hi: Double) -> [Double] {
        let span = hi - lo
        let baseExp = Int(floor(log10(span)))
        var candidates: [Double] = []
        for e in (baseExp - 2)...(baseExp + 1) {
            for m in [1.0, 2.0, 5.0] { candidates.append(m * pow(10.0, Double(e))) }
        }
        candidates.sort()
        func count(_ s: Double) -> Int { Int(floor(hi / s)) - Int(ceil(lo / s)) + 1 }
        var chosen = candidates.last!
        for s in candidates where count(s) <= maxTicks { chosen = s; break }
        var ticks: [Double] = []
        var v = (lo / chosen).rounded(.up) * chosen        // first = ceil(lo/step)*step
        while v <= hi + chosen * 1e-9 { ticks.append(v); v += chosen }
        if ticks.isEmpty { ticks = [(lo + hi) / 2] }        // 防御性兜底（R2-N1；当前 2-decade 阶梯下不触发，细端 count≥~100）
        return ticks
    }

    /// 时间刻度 + 对齐的垂直网格线（贯穿三区）。**用绝对索引**（candles.startIndex + offset；
    /// indexToX 内部减 viewport.startIndex，传 slice-relative 0 会错位 —— 修 spec-review High）。
    static func timeTicks(mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>,
                          period: Period, frames: ChartPanelFrames) -> (labels: [Label], gridLines: [LineSegment]) {
        guard !candles.isEmpty else { return ([], []) }
        let n = candles.count
        let start = candles.startIndex
        var absIndices: [Int] = []
        for k in 0...3 {
            let idx = start + (n - 1) * k / 3      // 整数运算；k 升序故 idx 非降
            if absIndices.last != idx { absIndices.append(idx) }   // 相邻去重（升序足够）
        }
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = dateFormat(for: period)
        let labelW: CGFloat = 96, labelH: CGFloat = 16
        var labels: [Label] = []
        var lines: [LineSegment] = []
        for idx in absIndices {
            let x = mapper.indexToX(idx)
            lines.append(LineSegment(from: CGPoint(x: x, y: frames.mainChart.minY),
                                     to: CGPoint(x: x, y: frames.macdChart.maxY)))
            let rawX = x - labelW / 2
            let clampedX = min(max(rawX, frames.mainChart.minX), frames.mainChart.maxX - labelW)
            let rect = CGRect(x: clampedX, y: frames.macdChart.maxY - labelH, width: labelW, height: labelH)
            let date = Date(timeIntervalSince1970: TimeInterval(candles[idx].datetime))
            labels.append(Label(rect: rect, text: fmt.string(from: date)))
        }
        return (labels, lines)
    }

    /// 周期自适应日期格式（与 CrosshairLayout.swift:91-94 同 formatter 配置；镜像配置非共享符号）。
    private static func dateFormat(for period: Period) -> String {
        switch period {
        case .m3, .m15, .m60: return "MM-dd HH:mm"
        case .daily, .weekly: return "yyyy-MM-dd"
        case .monthly:        return "yyyy-MM"
        }
    }
}

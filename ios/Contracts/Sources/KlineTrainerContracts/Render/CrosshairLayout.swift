// Kline Trainer Swift Contracts — C5 十字光标布局纯函数（平台无关）
// Spec: kline_trainer_modules_v1.4.md §C5 L1298-1313 + plan 2026-05-26-pr-c5-crosshair-markers.md
//
// 本文件不 import UIKit：所有几何/文本字符串在 host swift test 真断言。
// drawXxx 的 UIKit 描边/填充/文本绘制薄层在 KLineView+Crosshair.swift（#if canImport(UIKit)）。
//
// 顺位5：竖线吸附最近蜡烛中心（snappedCandleIndex），横线/价签自由 Y，时签随吸附蜡烛（spec D1/D2/D4）。
// 吸附在本纯层 draw-time，用 resolve 入参的 post-pinch viewport mapper（spec D5）。
// resolve 守卫：point==nil / point 落 mainChartFrame 外（半开区间）/ candles.isEmpty → nil（spec D3）。

import Foundation
import CoreGraphics

/// 十字光标一对横竖线段（竖线端点 = 整 panel（frames 非 nil）或 mainChartFrame）。
struct CrosshairLines: Equatable, Sendable {
    let horizontal: LineSegment
    let vertical: LineSegment

    struct LineSegment: Equatable, Sendable {
        let from: CGPoint
        let to: CGPoint
    }
}

/// resolve 聚合结果：竖线吸附 + 横线/价签自由 Y + 时签吸附 X，单一 snappedIndex 真相。
struct CrosshairResolved: Equatable, Sendable {
    let lines: CrosshairLines
    let priceLabel: Label
    let timeLabel: Label
    let snappedIndex: Int

    struct Label: Equatable, Sendable {
        let rect: CGRect
        let text: String
    }
}

enum CrosshairLayout {

    // per-frame 分配修复：不可变缓存 formatter（固定 tz/locale/format，建后永不变异 → 并发只读安全，spec §3.1）。
    // DateFormatter 非 Sendable → nonisolated(unsafe)（真安全：无可变共享态）。
    private nonisolated(unsafe) static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// 吸附蜡烛 datetime → 时间标签串（internal 供并发压测直调）。
    static func formatTimeLabel(_ datetime: Int64) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(datetime)))
    }

    /// 吸附核心（spec D2/D3）：返回离 `x` 最近蜡烛中心的索引，clamp 到 `candles` 切片自身界限。
    /// 算法：seed = round((x − pixelShift)/candleStep) + startIndex；两侧 {seed−1,seed,seed+1}
    /// 取 |indexToX − x| 最小（严格 <，tie 保留较小 index）；再 clamp [candles.startIndex, candles.endIndex−1]。
    /// 调用方须先保证 !candles.isEmpty（resolve 已守）；indexToX 对任意 Int 线性有定义，越界邻居照常参与比较。
    static func snappedCandleIndex(at x: CGFloat, mapper: CoordinateMapper,
                                   candles: ArraySlice<KLineCandle>) -> Int {
        let vp = mapper.viewport
        let seed = vp.startIndex
            + Int(((x - vp.pixelShift) / vp.geometry.candleStep).rounded(.toNearestOrAwayFromZero))
        // 两侧校正：从较小者起遍历，严格 < ⇒ 距离相等时保留较小 index（确定性 tie-break）。
        var best = seed - 1
        var bestDist = abs(mapper.indexToX(seed - 1) - x)
        for cand in [seed, seed + 1] {
            let d = abs(mapper.indexToX(cand) - x)
            if d < bestDist { best = cand; bestDist = d }
        }
        // clamp 到切片自身有效索引（slice-safe total；生产下 == viewport 窗口）。
        return min(max(best, candles.startIndex), candles.endIndex - 1)
    }

    /// 单一入口（spec D6 + RFC-C frames 扩展）。frames 非 nil → 竖线贯穿整 panel + 时签底贴 macdChart.maxY。
    /// point==nil / frame 外 / 空切片 → nil（spec D3 守卫）。触发区仍限 mainChartFrame。
    static func resolve(at point: CGPoint?, mapper: CoordinateMapper,
                        candles: ArraySlice<KLineCandle>,
                        frames: ChartPanelFrames? = nil) -> CrosshairResolved? {
        guard let point else { return nil }
        let frame = mapper.viewport.mainChartFrame
        guard frame.contains(point) else { return nil }     // D8 frame 守卫（触发区仍限主图）
        guard !candles.isEmpty else { return nil }          // D3 空切片守卫

        let snappedIndex = snappedCandleIndex(at: point.x, mapper: mapper, candles: candles)
        let snappedX = mapper.indexToX(snappedIndex)

        // 竖线纵向延展：frames 非 nil → 贯穿 mainChart.minY..macdChart.maxY；nil → 限 mainChartFrame（旧行为）。
        let verticalTop = frames?.mainChart.minY ?? frame.minY
        let verticalBottom = frames?.macdChart.maxY ?? frame.maxY

        let lines = CrosshairLines(
            horizontal: .init(from: CGPoint(x: frame.minX, y: point.y),
                              to:   CGPoint(x: frame.maxX, y: point.y)),
            vertical:   .init(from: CGPoint(x: snappedX, y: verticalTop),
                              to:   CGPoint(x: snappedX, y: verticalBottom)))

        // RFC-C：价标移左缘（对齐 RFC-B 左移价轴）；自由 Y 不变。
        let price = mapper.yToPrice(point.y)
        let priceWidth: CGFloat = 60, priceHeight: CGFloat = 18
        let priceRect = CGRect(x: frame.minX, y: point.y - priceHeight / 2,
                               width: priceWidth, height: priceHeight)
        let priceLabel = CrosshairResolved.Label(rect: priceRect,
                                                 text: String(format: "%.2f", price))

        // 时签：吸附蜡烛 datetime（UTC+8 / en_US_POSIX，D4）；水平居中 snappedX。
        // 时签底：frames 非 nil → macdChart.maxY（整图最底）；nil → mainChartFrame.maxY（旧）。
        let datetime = candles[snappedIndex].datetime
        let timeBottom = frames?.macdChart.maxY ?? frame.maxY
        let timeWidth: CGFloat = 120, timeHeight: CGFloat = 18
        let timeRect = CGRect(x: snappedX - timeWidth / 2, y: timeBottom - timeHeight,
                              width: timeWidth, height: timeHeight)
        let timeLabel = CrosshairResolved.Label(rect: timeRect, text: Self.formatTimeLabel(datetime))

        return CrosshairResolved(lines: lines, priceLabel: priceLabel,
                                 timeLabel: timeLabel, snappedIndex: snappedIndex)
    }
}

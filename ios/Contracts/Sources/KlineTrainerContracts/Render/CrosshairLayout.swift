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

/// 十字光标一对横竖线段（端点已对齐 mainChartFrame 四边）。
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

    /// 单一入口（spec D6）：long-press 原始 point + 当前 mapper（post-pinch viewport）+ 可见 candles
    /// → 吸附后的十字光标几何 + HUD labels。point==nil / frame 外 / 空切片 → nil（spec D3 守卫）。
    /// 竖线吸附 X（snappedX）、横线自由 Y；价签自由 Y、时签吸附 X；竖线与时签共用同一 snappedIndex。
    static func resolve(at point: CGPoint?, mapper: CoordinateMapper,
                        candles: ArraySlice<KLineCandle>) -> CrosshairResolved? {
        guard let point else { return nil }
        let frame = mapper.viewport.mainChartFrame
        guard frame.contains(point) else { return nil }     // D8 frame 守卫
        guard !candles.isEmpty else { return nil }          // D3 空切片守卫（先于 clamp）

        let snappedIndex = snappedCandleIndex(at: point.x, mapper: mapper, candles: candles)
        let snappedX = mapper.indexToX(snappedIndex)

        // 竖线吸附 snappedX；横线自由 point.y（D1 X-only snap）。
        let lines = CrosshairLines(
            horizontal: .init(from: CGPoint(x: frame.minX, y: point.y),
                              to:   CGPoint(x: frame.maxX, y: point.y)),
            vertical:   .init(from: CGPoint(x: snappedX, y: frame.minY),
                              to:   CGPoint(x: snappedX, y: frame.maxY)))

        // 价签：自由 Y（镜像 yToPrice，D4）；右贴 maxX、垂直居中 point.y。
        let price = mapper.yToPrice(point.y)
        let priceWidth: CGFloat = 60, priceHeight: CGFloat = 18
        let priceRect = CGRect(x: frame.maxX - priceWidth, y: point.y - priceHeight / 2,
                               width: priceWidth, height: priceHeight)
        let priceLabel = CrosshairResolved.Label(rect: priceRect,
                                                 text: String(format: "%.2f", price))

        // 时签：吸附蜡烛 datetime（UTC+8 / en_US_POSIX，D4）；水平居中 snappedX、底贴 maxY。
        let datetime = candles[snappedIndex].datetime
        let date = Date(timeIntervalSince1970: TimeInterval(datetime))
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let timeWidth: CGFloat = 120, timeHeight: CGFloat = 18
        let timeRect = CGRect(x: snappedX - timeWidth / 2, y: frame.maxY - timeHeight,
                              width: timeWidth, height: timeHeight)
        let timeLabel = CrosshairResolved.Label(rect: timeRect, text: formatter.string(from: date))

        return CrosshairResolved(lines: lines, priceLabel: priceLabel,
                                 timeLabel: timeLabel, snappedIndex: snappedIndex)
    }
}

// Kline Trainer Swift Contracts — C5 十字光标布局纯函数（平台无关）
// Spec: kline_trainer_modules_v1.4.md §C5 L1298-1313 + plan 2026-05-26-pr-c5-crosshair-markers.md
//
// 本文件不 import UIKit：所有几何/文本字符串在 host swift test 真断言。
// drawXxx 的 UIKit 描边/填充/文本绘制薄层在 KLineView+Crosshair.swift（#if canImport(UIKit)）。
//
// D7：lines 不吸附蜡烛中心，竖/横 = point.x / point.y 原值；吸附决策在 Wave 2 LongPress 源。
// D8：point 落在 mainChartFrame 外即返回 nil；caller 整体跳过绘制。

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

    /// D7/D8：point 在 mainChartFrame 内则返回穿 frame 全宽全高的横/竖线对；否则 nil。
    static func lines(at point: CGPoint, mapper: CoordinateMapper) -> CrosshairLines? {
        let frame = mapper.viewport.mainChartFrame
        guard frame.contains(point) else { return nil }
        return CrosshairLines(
            horizontal: .init(from: CGPoint(x: frame.minX, y: point.y),
                              to:   CGPoint(x: frame.maxX, y: point.y)),
            vertical:   .init(from: CGPoint(x: point.x, y: frame.minY),
                              to:   CGPoint(x: point.x, y: frame.maxY)))
    }

    /// 价格标签：D5 2 位小数 + Locale 中性；D4 框右贴 mainChartFrame.maxX、垂直居中 point.y。
    /// rect 仅给"参考几何"——具体框宽/高在 caller 的 UIKit 层按字体度量；这里给字符 + 锚位。
    static func priceLabel(at point: CGPoint,
                           mapper: CoordinateMapper) -> (rect: CGRect, text: String) {
        let price = mapper.yToPrice(point.y)
        let text = String(format: "%.2f", price)
        // 锚位参考框：宽 = 60、高 = 18；右贴 frame.maxX；垂直居中 point.y。
        // caller UIKit 层若字体度量不同可重排，但锚锚点（maxX / midY）契约固定。
        let frame = mapper.viewport.mainChartFrame
        let labelWidth: CGFloat = 60
        let labelHeight: CGFloat = 18
        let rect = CGRect(x: frame.maxX - labelWidth,
                          y: point.y - labelHeight / 2,
                          width: labelWidth, height: labelHeight)
        return (rect: rect, text: text)
    }

    /// 时间标签：D6 yyyy-MM-dd HH:mm UTC+8 fixed；D4 框底贴 mainChartFrame.maxY、水平居中 point.x。
    /// 用 xToIndex 解析候选 candle，越界（< slice.startIndex 或 >= slice.endIndex）返回 nil。
    static func timeLabel(at point: CGPoint,
                          mapper: CoordinateMapper,
                          candles: ArraySlice<KLineCandle>) -> (rect: CGRect, text: String)? {
        let candleIndex = mapper.xToIndex(point.x)
        guard candleIndex >= candles.startIndex && candleIndex < candles.endIndex else {
            return nil
        }
        let datetime = candles[candleIndex].datetime
        let date = Date(timeIntervalSince1970: TimeInterval(datetime))
        // DateFormatter 是 NSObject 引用类型，let 即可配置 (per R1 F7 修正)。
        // 每次 draw 重建——可接受：drawCrosshair 仅在长按显示 crosshair 时才走到此，频次远低于
        // 主图 60Hz；如 Phase 5 磨光需 hoist 全局 static，再走单独 PR。
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.locale = Locale(identifier: "en_US_POSIX")  // 避免本地化串干扰
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let text = formatter.string(from: date)
        let frame = mapper.viewport.mainChartFrame
        let labelWidth: CGFloat = 120
        let labelHeight: CGFloat = 18
        let rect = CGRect(x: point.x - labelWidth / 2,
                          y: frame.maxY - labelHeight,
                          width: labelWidth, height: labelHeight)
        return (rect: rect, text: text)
    }
}

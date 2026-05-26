// Kline Trainer Swift Contracts — C3 主图布局纯函数（平台无关）
// Spec: kline_trainer_modules_v1.4.md §C3 + plan 2026-05-25-pr-c3-candles-ma66-boll.md
//
// 本文件不 import UIKit：所有几何在 host swift test 真断言。
// drawXxx 的 UIKit 描边/填充薄层在 KLineView+Candles.swift（#if canImport(UIKit)）。
//
// 索引契约（D6）：用 candles.indices 作 chart index；调用方保证 slice.startIndex == viewport.startIndex。
// 中心契约（D5）：indexToX(index) 视为蜡烛水平中心，实体居中、影线在中心。

import Foundation
import CoreGraphics

/// 单根蜡烛的可描边几何原语。
struct CandleShape: Equatable, Sendable {
    let bodyRect: CGRect      // 实体矩形（已含 doji 最小高度）
    let wickTop: CGPoint      // 影线上端（高价，小 y）
    let wickBottom: CGPoint   // 影线下端（低价，大 y）
    let isUp: Bool            // close >= open（D7）
}

/// BOLL 三轨折线分段（D9：各轨按 nil 断线分段）。
struct BollPolylines: Equatable, Sendable {
    let upper: [[CGPoint]]
    let mid: [[CGPoint]]
    let lower: [[CGPoint]]
}

enum MainChartLayout {

    /// 蜡烛实体+影线几何。D5 中心 / D7 涨跌 / D8 doji 最小高度。
    /// L5 注：body 左右边缘 (cx ± width/2) 不单独 round-to-pixel——沿用 indexToX 已对齐的 cx；
    ///        candleWidth 的偶数像素由 C1a/C8 geometry 构造保证（非 C3 职责）。
    /// L6 注：minBody = 1/displayScale 不除零——displayScale 来自 traitCollection.displayScale 恒 ≥1；
    ///        下方 caller(drawCandles) 的 `guard !candles.isEmpty` 只为空 slice 短路，与除零无关。
    static func candleShapes(for candles: ArraySlice<KLineCandle>,
                             mapper: CoordinateMapper) -> [CandleShape] {
        let width = mapper.viewport.geometry.candleWidth
        let minBody = 1 / mapper.displayScale
        var shapes: [CandleShape] = []
        shapes.reserveCapacity(candles.count)
        for index in candles.indices {
            let c = candles[index]
            let cx = mapper.indexToX(index)
            let yOpen = mapper.priceToY(c.open)
            let yClose = mapper.priceToY(c.close)
            let top = min(yOpen, yClose)
            let bottom = max(yOpen, yClose)
            let height = max(bottom - top, minBody)
            let bodyRect = CGRect(x: cx - width / 2, y: top, width: width, height: height)
            shapes.append(CandleShape(
                bodyRect: bodyRect,
                wickTop: CGPoint(x: cx, y: mapper.priceToY(c.high)),
                wickBottom: CGPoint(x: cx, y: mapper.priceToY(c.low)),
                isUp: c.close >= c.open))
        }
        return shapes
    }

    /// 按 value 提取折线点，遇 nil 断线分段（D9）。各段内点连续。
    private static func polylineSegments(for candles: ArraySlice<KLineCandle>,
                                         mapper: CoordinateMapper,
                                         value: (KLineCandle) -> Double?) -> [[CGPoint]] {
        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []
        for index in candles.indices {
            if let v = value(candles[index]) {
                current.append(CGPoint(x: mapper.indexToX(index), y: mapper.priceToY(v)))
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// MA66 折线（D1：读预计算 candle.ma66，不重算）。
    static func ma66Polyline(for candles: ArraySlice<KLineCandle>,
                             mapper: CoordinateMapper) -> [[CGPoint]] {
        polylineSegments(for: candles, mapper: mapper, value: { $0.ma66 })
    }

    /// BOLL 上/中/下三轨折线（D2：仅三线无填充；D9：各轨独立按 nil 断线）。
    static func bollPolylines(for candles: ArraySlice<KLineCandle>,
                              mapper: CoordinateMapper) -> BollPolylines {
        BollPolylines(
            upper: polylineSegments(for: candles, mapper: mapper, value: { $0.bollUpper }),
            mid:   polylineSegments(for: candles, mapper: mapper, value: { $0.bollMid }),
            lower: polylineSegments(for: candles, mapper: mapper, value: { $0.bollLower }))
    }

    /// BOLL 虚线 dash 参数（D3）。抽为纯值 → host 可测虚线"段长正确"（缩小 UIKit 不可测面，
    /// per H1 修订）；drawBOLL 仅把它喂给 ctx.setLineDash。每段 4 设备像素 on / 4 off。
    static func dashPattern(displayScale: CGFloat) -> [CGFloat] {
        let unit = 4 / displayScale
        return [unit, unit]
    }
}

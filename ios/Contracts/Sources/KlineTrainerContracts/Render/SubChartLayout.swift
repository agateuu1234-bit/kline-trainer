// Kline Trainer Swift Contracts — C4 副图布局纯函数（平台无关）
// Spec: kline_trainer_modules_v1.4.md §C4 + plan 2026-05-26-pr-c4-volume-macd.md
//
// 本文件不 import UIKit：所有几何在 host swift test 真断言。
// drawXxx 的 UIKit 描边/填充薄层在 KLineView+Volume.swift / KLineView+MACD.swift（#if canImport(UIKit)）。
//
// 索引契约（D6）：用 candles.indices 作 chart index；调用方保证 slice.startIndex == viewport.startIndex（与 C3 同口径）。
// 中心契约（D5）：indexToX(index) 视为柱水平中心，矩形居中（与 C3 同口径）。

import Foundation
import CoreGraphics

/// 单根成交量柱的可描边几何原语。
struct VolumeBar: Equatable, Sendable {
    let rect: CGRect
    let isUp: Bool
}

/// 单根 MACD 柱的可描边几何原语。
struct MacdBar: Equatable, Sendable {
    let rect: CGRect
    let isPositive: Bool
}

/// MACD 两轨折线分段（D9a：按 nil 断线分段）。
struct MacdLines: Equatable, Sendable {
    let dif: [[CGPoint]]
    let dea: [[CGPoint]]
}

enum SubChartLayout {

    /// 成交量柱几何（D7 涨跌色 / D8 最小高度 / D10 基线=frame.maxY）。
    static func volumeBars(for candles: ArraySlice<KLineCandle>,
                           mapper: IndicatorMapper) -> [VolumeBar] {
        let width = mapper.viewport.geometry.candleWidth
        let baseline = mapper.frame.maxY    // D10：=valueToY(valueRange.lower)，柱锚定子图底边
        let minBar = 1 / mapper.displayScale
        var bars: [VolumeBar] = []
        bars.reserveCapacity(candles.count)
        for index in candles.indices {
            let c = candles[index]
            let cx = mapper.indexToX(index)
            let top = mapper.valueToY(Double(c.volume))
            // baseline >= top 通常成立（volume >= lower）；防御性 max 保证非负高度
            let height = max(baseline - top, minBar)
            let rect = CGRect(x: cx - width / 2, y: baseline - height, width: width, height: height)
            bars.append(VolumeBar(rect: rect, isUp: c.close >= c.open))
        }
        return bars
    }

    /// 按 value 提取折线点，遇 nil 断线分段（D9a，IndicatorMapper 重载）。
    /// 与 MainChartLayout.polylineSegments 算法字面同款，仅 mapper 类型不同；不抽协议保持简单（5 行不值得引入泛型）。
    private static func polylineSegments(for candles: ArraySlice<KLineCandle>,
                                         mapper: IndicatorMapper,
                                         value: (KLineCandle) -> Double?) -> [[CGPoint]] {
        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []
        for index in candles.indices {
            if let v = value(candles[index]) {
                current.append(CGPoint(x: mapper.indexToX(index), y: mapper.valueToY(v)))
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// MACD DIF + DEA 折线（D1：读预计算 candle.macdDiff/macdDea，不重算；D9a：各轨独立 nil 断线）。
    static func macdLines(for candles: ArraySlice<KLineCandle>,
                          mapper: IndicatorMapper) -> MacdLines {
        MacdLines(
            dif: polylineSegments(for: candles, mapper: mapper, value: { $0.macdDiff }),
            dea: polylineSegments(for: candles, mapper: mapper, value: { $0.macdDea }))
    }
}

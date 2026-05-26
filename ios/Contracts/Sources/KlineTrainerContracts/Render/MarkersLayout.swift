// Kline Trainer Swift Contracts — C5 交易标记布局纯函数（平台无关）
// Spec: kline_trainer_modules_v1.4.md §C5 L1298-1313 + plan v1.5 §4.3 L753-771
//
// D2：spec L1311 字面 `candles.binarySearchFirst { ... }`；BinarySearch util 名 `partitioningIndex`。
//     本文件直接用 partitioningIndex，不新增 alias（参 BinarySearch.swift L4 注释）。
// D9：findCandleIndex 返回 nil 时跳过该 marker。
// D10：dot center = (indexToX(idx), priceToY(candle.close))，锚到收盘价 Y。

import Foundation
import CoreGraphics

/// 单个 marker 的可绘几何（dot center + B/S 字母方向 + 该锚定 K 线 index 给 caller 调试）。
struct MarkerPlacement: Equatable, Sendable {
    let center: CGPoint
    let direction: TradeDirection
    let candleIndex: Int
}

enum MarkersLayout {

    /// 精确二分谓词（spec L1308-1312 字面）：找首个 endGlobalIndex >= marker.globalTick 的 K 线。
    /// 返回 partitioningIndex == endIndex 视为"无匹配"，统一为 nil（D9 跳过）。
    static func findCandleIndex(for marker: TradeMarker,
                                in candles: ArraySlice<KLineCandle>) -> Int? {
        let idx = candles.partitioningIndex { $0.endGlobalIndex >= marker.globalTick }
        return idx < candles.endIndex ? idx : nil
    }

    /// 遍历 markers，对每个 marker 找候选 K 线，跳过越界（D9），构造 placements。
    /// dot center 锚到 (indexToX(idx), priceToY(candle.close))，per D10 + plan v1.5 §4.3 L767。
    static func markerPlacements(mapper: CoordinateMapper,
                                 markers: [TradeMarker],
                                 candles: ArraySlice<KLineCandle>) -> [MarkerPlacement] {
        var out: [MarkerPlacement] = []
        out.reserveCapacity(markers.count)
        for marker in markers {
            guard let idx = findCandleIndex(for: marker, in: candles) else { continue }
            let candle = candles[idx]
            let center = CGPoint(x: mapper.indexToX(idx),
                                 y: mapper.priceToY(candle.close))
            out.append(MarkerPlacement(center: center,
                                       direction: marker.direction,
                                       candleIndex: idx))
        }
        return out
    }
}

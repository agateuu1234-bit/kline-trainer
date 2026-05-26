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
}

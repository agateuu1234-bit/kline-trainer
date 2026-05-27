// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift
// Spec: kline_trainer_modules_v1.4.md §C6 L1318-1323 + design doc §2.2
// Wave 1 PR C6: protocol-only; concrete tool impls deferred to Wave 3 Phase 2.5/4.
//
// Swift 6 ConformanceIsolation 规避：protocol-level @MainActor（替代成员级 @MainActor + Sendable
// 组合）。@MainActor isolated 自带 Sendable 语义。具体 tool 实现（Wave 3）必须 @MainActor
// final class 或 @MainActor struct。
//
// 跨平台：仅依赖 CoreGraphics（CGContext / CGPoint），与 Models/Geometry/Reducer 一致无
// `#if canImport(UIKit)` 包装。UIKit-tied 调用方（KLineView+Drawing.swift）已在自己文件层包 guard。

import CoreGraphics

@MainActor
public protocol DrawingTool {
    static var type: DrawingToolType { get }
    var requiredAnchors: ClosedRange<Int> { get }
    func render(ctx: CGContext, mapper: CoordinateMapper, anchors: [DrawingAnchor])
    func hitTest(point: CGPoint, mapper: CoordinateMapper, anchors: [DrawingAnchor]) -> Bool
}

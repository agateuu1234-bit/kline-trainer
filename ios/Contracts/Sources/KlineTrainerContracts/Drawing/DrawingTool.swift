// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift
// Spec: kline_trainer_modules_v1.4.md §C6 L1318-1323 + design doc §2.2
// Wave 1 PR C6: protocol-only; concrete tool impls deferred to Wave 3 Phase 2.5/4.

#if canImport(UIKit)
import CoreGraphics

public protocol DrawingTool: Sendable {
    static var type: DrawingToolType { get }
    var requiredAnchors: ClosedRange<Int> { get }
    @MainActor func render(ctx: CGContext, mapper: CoordinateMapper, anchors: [DrawingAnchor])
    @MainActor func hitTest(point: CGPoint, mapper: CoordinateMapper, anchors: [DrawingAnchor]) -> Bool
}

#endif

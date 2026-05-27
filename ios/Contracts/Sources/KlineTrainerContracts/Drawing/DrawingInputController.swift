// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingInputController.swift
// Spec: kline_trainer_modules_v1.4.md §C6 L1325-1328 + design doc §2.2
// Wave 1 PR C6: protocol-only; DefaultDrawingInputController impl deferred to Wave 3.
//
// Swift 6 ConformanceIsolation 规避：protocol-level @MainActor。
// 跨平台：仅依赖 CoreGraphics + 跨平台值类型（PanelViewState / CoordinateMapper /
// DrawingAnchor / DrawingToolType）。无 UIKit 依赖。

import CoreGraphics

@MainActor
public protocol DrawingInputController: AnyObject {
    func tapToAnchor(at point: CGPoint, panel: PanelViewState, mapper: CoordinateMapper) -> DrawingAnchor
    func shouldCommit(current: [DrawingAnchor], tool: DrawingToolType) -> Bool
}

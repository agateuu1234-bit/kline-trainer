// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingInputController.swift
// Spec: kline_trainer_modules_v1.4.md §C6 L1325-1328 + design doc §2.2
// Wave 1 PR C6: protocol-only; DefaultDrawingInputController impl deferred to Wave 3.

#if canImport(UIKit)
import CoreGraphics

public protocol DrawingInputController: AnyObject {
    @MainActor func tapToAnchor(at point: CGPoint, panel: PanelViewState, mapper: CoordinateMapper) -> DrawingAnchor
    @MainActor func shouldCommit(current: [DrawingAnchor], tool: DrawingToolType) -> Bool
}

#endif

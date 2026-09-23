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
    /// `isSelected`（D55，1b-i PR-3）：该条是否处于选中态。**瞬时 UI 状态**，由渲染 dispatch 按
    /// `KLineRenderState.selectedDrawingID` 逐条派发，不来自 `DrawingObject` 任何持久化字段。
    /// 源码 API 面破坏按 D28 不 bump `CONTRACT_VERSION`、不留 shim（仓内模块、无外部 conformer）。
    func render(ctx: CGContext, mapper: CoordinateMapper, drawing: DrawingObject,
                scheme: AppColorScheme, isSelected: Bool)
    func hitTest(point: CGPoint, mapper: CoordinateMapper, drawing: DrawingObject) -> Bool
    /// D131（P1c 第 2 片）：这条线此刻**画不画得出来**。
    /// **节点的渲染与命中共用它** —— 各 tool 必须让它与自己的 `render` / `hitTest` 走**同一个判据**
    /// （水平线三者共用 `visibleGeometry`），使「命中集合 ≡ 渲染集合」在结构上不可能分叉。
    /// ⛔ 新工具不得为它单写一份可见性逻辑。
    func isVisible(drawing: DrawingObject, mapper: CoordinateMapper) -> Bool
}

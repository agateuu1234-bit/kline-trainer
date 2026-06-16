// Kline Trainer Swift Contracts — C8 ChartContainerView（@Observable→UIKit 桥接 + C7 手势接线）
// Spec: kline_trainer_modules_v1.4.md §C8 (L1409-1467) + §C7 (L1397-1406)
// Design: docs/superpowers/specs/2026-06-07-pr-c8a-chart-container-render-design.md（C8a 渲染）
//        + docs/superpowers/plans/2026-06-07-pr-c8b-chart-interaction-h1.md（C8b 交互）
//
// 平台门：UIKit-only。macOS swift build 编译为空；Catalyst build-for-testing 落 required CI 闸门。
// spec 实现约束：不订阅 ObservationRegistrar（1）；靠 @Bindable 触发重建（2）；KLineView 只收值类型（3）；
// buildRenderState 算值域（4，RenderStateBuilder）；不监听 scenePhase（5）。
// C8b：Coordinator 持 C7 ChartGestureArbiter，attach-once，把手势回调路由进 engine（D1）；
//      长按十字光标为视图层瞬态（Coordinator 本地 + make(crosshair:) 透传，D3）。

#if canImport(UIKit)
import SwiftUI
import UIKit
import CoreGraphics

public struct ChartContainerView: UIViewRepresentable {
    public let panel: PanelId
    @Bindable public var engine: TrainingEngine

    public init(panel: PanelId, engine: TrainingEngine) {
        self.panel = panel
        self._engine = Bindable(wrappedValue: engine)
    }

    public func makeCoordinator() -> Coordinator { Coordinator(panel: panel, engine: engine) }

    public func makeUIView(context: Context) -> KLineView {
        let view = KLineView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    public func updateUIView(_ view: KLineView, context: Context) {
        // 每次重建刷新 Coordinator 的 engine/panel 引用（ChartContainerView 是值类型，可能换 engine）。
        context.coordinator.sync(panel: panel, engine: engine, view: view)
        engine.recordRenderBounds(view.bounds, panel: panel)   // D1：缓存 bounds 供 activateDrawingTool 算 range
        // Wave 3 13c-R1：区间仅界定 make 求值（赋值/didSet 不计入；L1471 判据符号 = RenderStateBuilder.make）
        let makeToken = RenderSignposter.beginMake(panel: panel)
        let newState = RenderStateBuilder.make(
            engine: engine, panel: panel, bounds: view.bounds,
            crosshair: context.coordinator.crosshairPoint)       // D3：透传视图层瞬态十字光标
        RenderSignposter.end(makeToken)
        view.renderState = newState
    }

    /// C7 手势仲裁接线（spec §C7 + plan v1.5 §手势仲裁规则）。持 arbiter + 视图层十字光标本地状态。
    @MainActor
    public final class Coordinator {
        private var panel: PanelId
        private weak var engine: TrainingEngine?
        private weak var view: KLineView?
        private let arbiter = ChartGestureArbiter()
        /// Wave 3 顺位 4：画线输入暂存（仅 .horizontal）+ 逆映射 controller。manager 是输入暂存，
        /// engine.drawings 才是单一真相（spec §D-MANAGER）。
        private let manager = DrawingToolManager(enabledTools: [.horizontal])
        private let inputController: DrawingInputController = DefaultDrawingInputController()
        /// 视图层瞬态十字光标（D3，不进 engine）。长按时设置，松手清空。
        public private(set) var crosshairPoint: CGPoint?

        public init(panel: PanelId, engine: TrainingEngine) {
            self.panel = panel
            self.engine = engine
        }

        /// updateUIView 每次调：刷新引用（值类型 ChartContainerView 可能携新 engine/panel）。
        func sync(panel: PanelId, engine: TrainingEngine, view: KLineView) {
            self.panel = panel
            self.engine = engine
            self.view = view
            view.panel = panel                                    // Wave 3 13c-R1：draw 区间归属上/下
            // drawing 模式下 arbiter 截获单指 pan（spec §C7）+ 对齐 manager.activeTool（顺位 4）。
            let drawing = isDrawing(engine: engine, panel: panel)
            arbiter.drawingMode = drawing
            if drawing {
                if manager.activeTool == nil { manager.toggle(.horizontal) }     // 进入：对齐（条件 toggle，非每帧盲翻）
            } else if manager.activeTool != nil {
                manager.cancel()                                                  // 退出：复位暂存
            }
        }

        /// attach-once（C7 R6 幂等）：makeUIView 调一次；路由 5 类回调进 engine。
        func attach(to view: UIView) {
            self.view = view as? KLineView
            self.view?.panel = panel                              // Wave 3 13c-R1：首帧前初值（sync 后续刷新）
            arbiter.onPan = { [weak self] deltaX, velocityX, phase in
                guard let self, let engine = self.engine, let view = self.view else { return }
                switch phase {
                case .began:   engine.beginPan(panel: self.panel)
                case .changed:   // R1b-wire：传 view.bounds，engine 内部算边界 + drag full-clamp（D1）
                    engine.applyPanOffset(deltaPixels: deltaX, renderBounds: view.bounds, panel: self.panel)
                case .ended:     // R1b-wire：传 view.bounds，engine 内部算边界 + 机制 A 速度方向分派
                    engine.endPan(velocity: velocityX, renderBounds: view.bounds, panel: self.panel)
                case .cancelled: engine.cancelPan(panel: self.panel)
                }
            }
            arbiter.onTwoFingerSwipe = { [weak self] swipe in
                guard let self, let engine = self.engine else { return }
                engine.switchPeriodCombo(direction: periodDirection(for: swipe))
            }
            arbiter.onLongPress = { [weak self] location, phase in
                guard let self else { return }
                switch phase {
                case .began, .changed: self.setCrosshair(location)
                case .ended, .cancelled: self.setCrosshair(nil)
                }
            }
            arbiter.onPinch = { [weak self] scale, focus, phase in
                guard let self, let engine = self.engine else { return }
                engine.applyPinch(scale: scale, focusX: focus.x, phase: phase, panel: self.panel)
            }
            arbiter.onTap = { [weak self] point in
                self?.handleDrawingTap(at: point)
            }
            arbiter.attach(to: view)
        }

        private func isDrawing(engine: TrainingEngine, panel: PanelId) -> Bool {
            let mode = (panel == .upper) ? engine.upperPanel.interactionMode : engine.lowerPanel.interactionMode
            if case .drawing = mode { return true }
            return false
        }

        /// 设置/清空十字光标并即时重渲染（视图层瞬态，不经 SwiftUI observation）。
        private func setCrosshair(_ point: CGPoint?) {
            crosshairPoint = point
            guard let view, let engine else { return }
            // Wave 3 13c-R1：crosshair 旁路 make 用独立区间名（make-crosshair-*），与 update-pass make 分离
            let makeToken = RenderSignposter.beginMakeCrosshair(panel: panel)
            let newState = RenderStateBuilder.make(
                engine: engine, panel: panel, bounds: view.bounds, crosshair: point)
            RenderSignposter.end(makeToken)
            view.renderState = newState
        }

        /// 顺位 4：drawing 模式单指点击落锚 → 投影 engine.drawings → 退出 .drawing。
        /// 全链路：tapToAnchor（逆映射）→ manager.addAnchor/commit → engine.appendDrawing → engine.commitDrawing。
        private func handleDrawingTap(at point: CGPoint) {
            guard let engine, let view else { return }
            guard isDrawing(engine: engine, panel: panel), manager.activeTool != nil else { return }
            // 空图表（candleStep==0）→ xToIndex 会 Int(NaN) 崩溃 → 守卫（spec §四 load-bearing）。
            let viewport = view.renderState.viewport
            guard viewport.geometry.candleStep > 0 else { return }
            let mapper = CoordinateMapper(viewport: viewport, displayScale: view.traitCollection.displayScale)
            let ps = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
            let anchor = inputController.tapToAnchor(at: point, panel: ps, mapper: mapper)
            manager.addAnchor(anchor)
            guard inputController.shouldCommit(current: manager.pendingAnchors, tool: .horizontal) else { return }
            manager.commit(isExtended: true, panelPosition: panel == .upper ? 0 : 1)
            if let committed = manager.completedDrawings.last {
                engine.appendDrawing(committed)              // 投影：单一真相 engine.drawings
            }
            engine.commitDrawing(panel: panel)               // 退出 reducer .drawing
        }
    }
}
#endif

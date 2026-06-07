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
        view.renderState = RenderStateBuilder.make(
            engine: engine, panel: panel, bounds: view.bounds,
            crosshair: context.coordinator.crosshairPoint)       // D3：透传视图层瞬态十字光标
    }

    /// C7 手势仲裁接线（spec §C7 + plan v1.5 §手势仲裁规则）。持 arbiter + 视图层十字光标本地状态。
    @MainActor
    public final class Coordinator {
        private var panel: PanelId
        private weak var engine: TrainingEngine?
        private weak var view: KLineView?
        private let arbiter = ChartGestureArbiter()
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
            // drawing 模式下 arbiter 截获单指 pan（spec §C7 L1393）：按当前面板 mode 同步开关。
            arbiter.drawingMode = isDrawing(engine: engine, panel: panel)
        }

        /// attach-once（C7 R6 幂等）：makeUIView 调一次；路由 5 类回调进 engine。
        func attach(to view: UIView) {
            self.view = view as? KLineView
            arbiter.onPan = { [weak self] deltaX, velocityX, phase in
                guard let self, let engine = self.engine else { return }
                switch phase {
                case .began:   engine.beginPan(panel: self.panel)
                case .changed: engine.applyPanOffset(deltaPixels: deltaX, panel: self.panel)
                case .ended:   engine.endPan(velocity: velocityX, panel: self.panel)
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
            // onPinch（缩放改 visibleCount）属 Wave 3；onTap（画线锚点）需 DrawingInputController（Wave 3）→ C8b 不接。
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
            view.renderState = RenderStateBuilder.make(
                engine: engine, panel: panel, bounds: view.bounds, crosshair: point)
        }
    }
}
#endif

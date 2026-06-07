// Kline Trainer Swift Contracts — C8a ChartContainerView（@Observable→UIKit 桥接）
// Spec: kline_trainer_modules_v1.4.md §C8 (L1409-1467)
// Design: docs/superpowers/specs/2026-06-07-pr-c8a-chart-container-render-design.md
//
// 平台门：UIKit-only。macOS swift build 编译为空；Catalyst build-for-testing 落 required CI 闸门。
// spec 实现约束：不订阅 ObservationRegistrar（1）；靠 @Bindable 触发重建（2）；KLineView 只收值类型（3）；
// buildRenderState 算值域（4，已下放 RenderStateBuilder）；不监听 scenePhase（5）。
// 注：observation 驱动的 updateUIView 刷新在 C8b/顺位 9（U2 集成）运行期验证；C8a 仅编译 + 单次渲染装配。

#if canImport(UIKit)
import SwiftUI
import UIKit

public struct ChartContainerView: UIViewRepresentable {
    public let panel: PanelId
    @Bindable public var engine: TrainingEngine

    public init(panel: PanelId, engine: TrainingEngine) {
        self.panel = panel
        self._engine = Bindable(wrappedValue: engine)
    }

    public func makeUIView(context: Context) -> KLineView { KLineView(frame: .zero) }

    public func updateUIView(_ view: KLineView, context: Context) {
        view.renderState = RenderStateBuilder.make(engine: engine, panel: panel, bounds: view.bounds)
    }
}
#endif

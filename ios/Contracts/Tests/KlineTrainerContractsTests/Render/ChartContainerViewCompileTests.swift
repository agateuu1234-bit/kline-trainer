// Kline Trainer Swift Contracts — C8a ChartContainerView 编译反射（Catalyst build gate）
// Mirror: KLineViewCompileTests（UIKit-only；macOS host 编译为空）
#if canImport(UIKit)
import Testing
import SwiftUI
import UIKit
@testable import KlineTrainerContracts

@Suite("ChartContainerView 编译反射（Catalyst compile gate）")
struct ChartContainerViewCompileTests {

    @Test("ChartContainerView 可构造 + 符合 UIViewRepresentable")
    @MainActor
    func instantiates() {
        let engine = TrainingEngine.preview()
        let view = ChartContainerView(panel: .upper, engine: engine)
        #expect(view.panel == .upper)
        let _: any UIViewRepresentable = view   // 编译期符合性
    }

    @Test("Coordinator 可构造 + attach 装 5 个识别器（C7 接线编译反射）")
    @MainActor
    func coordinatorAttachesRecognizers() {
        let engine = TrainingEngine.preview()
        let view = ChartContainerView(panel: .upper, engine: engine)
        let coordinator = view.makeCoordinator()
        let host = KLineView(frame: .zero)
        coordinator.attach(to: host)
        #expect(host.gestureRecognizers?.count == 5)   // C7 attach 5 个识别器（单指/两指/pinch/长按/tap）
        coordinator.attach(to: host)                    // 幂等：再 attach 不重复装
        #expect(host.gestureRecognizers?.count == 5)
    }

    @Test("Coordinator crosshairPoint 默认 nil（视图层瞬态）")
    @MainActor
    func coordinatorCrosshairDefaultsNil() {
        let engine = TrainingEngine.preview()
        let coordinator = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        #expect(coordinator.crosshairPoint == nil)
    }
}
#endif

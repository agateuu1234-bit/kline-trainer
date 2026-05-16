// Kline Trainer Swift Contracts — C1c KLineView Compile Tests
// Spec: kline_trainer_modules_v1.4.md §六 C1c (L1179-1211) + §15.1 #3 编译验证
// Covers: 实例化 + property 设置 + Equatable 短路（compile-check only）
// 注: L1240 runtime invariant defer 到 Wave 1 C8 integration PR（spec L1179 final class 不可继承）

#if canImport(UIKit)
import Testing
import UIKit
@testable import KlineTrainerContracts

@Suite("KLineView 编译反射（§15.1 #3 compile gate）")
struct KLineViewCompileTests {

    @Test("KLineView 可实例化（spec L1179 final class）")
    @MainActor
    func instantiates() {
        let view = KLineView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        #expect(view.bounds.width == 320)
    }

    @Test("renderState 可读写（compile-check：let 字段 + init 重建模式）")
    @MainActor
    func renderStateAssignable() {
        let view = KLineView(frame: .zero)
        let changed = KLineRenderState(
            panel: KLineRenderState.empty.panel,
            frames: KLineRenderState.empty.frames,
            viewport: KLineRenderState.empty.viewport,
            visibleCandles: KLineRenderState.empty.visibleCandles,
            volumeRange: KLineRenderState.empty.volumeRange,
            macdRange: KLineRenderState.empty.macdRange,
            markers: KLineRenderState.empty.markers,
            drawings: KLineRenderState.empty.drawings,
            crosshairPoint: CGPoint(x: 10, y: 20))
        view.renderState = changed
        #expect(view.renderState.crosshairPoint == CGPoint(x: 10, y: 20))
    }
}
#endif

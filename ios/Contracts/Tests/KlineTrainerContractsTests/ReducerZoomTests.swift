// 顺位 3 ChartAction.zoomApplied reducer 测试（设计 D1 矩阵）
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("Reducer zoomApplied（D1 三 mode 矩阵）")
struct ReducerZoomTests {

    static func panel(_ mode: ChartInteractionMode, visibleCount: Int = 80,
                      offset: CGFloat = 0, revision: UInt64 = 7) -> PanelViewState {
        PanelViewState(period: .m3, interactionMode: mode,
                       visibleCount: visibleCount, offset: offset, revision: revision)
    }

    @Test("autoTracking：visibleCount 应用 + offset 显式置 0（非 leave-unchanged）+ bump")
    func autoTrackingZeroesOffset() {
        // offset 预置非 0（模拟顺位 4 未来 drawingCommitted 残留，R1-M3 防御可观测）
        var p = Self.panel(.autoTracking, offset: 37)
        let effect = p.reduce(.zoomApplied(visibleCount: 40, offset: 123))
        #expect(p.visibleCount == 40)
        #expect(p.offset == 0)              // 显式置 0：入参 123 不被读取
        #expect(p.revision == 8)
        #expect(effect == .none)
        #expect(p.interactionMode == .autoTracking)   // 不切 mode
    }

    @Test("freeScrolling：visibleCount + offset 双应用 + bump")
    func freeScrollingAppliesBoth() {
        var p = Self.panel(.freeScrolling, offset: 15)
        let effect = p.reduce(.zoomApplied(visibleCount: 160, offset: -192.5))
        #expect(p.visibleCount == 160)
        #expect(abs(p.offset - (-192.5)) < 1e-9)
        #expect(p.revision == 8)
        #expect(effect == .none)
        #expect(p.interactionMode == .freeScrolling)
    }

    @Test("drawing：吞没——状态零改动（含 revision 不 bump），同 offsetApplied 先例")
    func drawingSwallows() {
        let snapshot = DrawingSnapshot(frozen: FrozenPanelState(
            period: .m3, visibleCount: 80, offset: 0, candleRange: 0..<80, baseRevision: 7))
        var p = Self.panel(.drawing(snapshot: snapshot))
        let before = p
        let effect = p.reduce(.zoomApplied(visibleCount: 40, offset: 99))
        #expect(p == before)
        #expect(effect == .none)
    }
}

// Wave 3 顺位 3 Pinch 缩放纯数学测试
// Design: docs/superpowers/specs/2026-06-13-wave3-pr3-pinch-zoom-design.md D3/D4
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("PinchZoomModel 纯函数")
struct PinchZoomModelTests {

    // MARK: targetVisibleCount（D4：target = clamp(round(base / effectiveScale), 20, 240)）

    @Test("恒等：effectiveScale=1 → base 不变")
    func identityScale() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 1.0) == 80)
    }

    @Test("放大：scale=2（张开）→ 根数减半")
    func zoomInHalves() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 2.0) == 40)
    }

    @Test("缩小：scale=0.5（捏拢）→ 根数翻倍")
    func zoomOutDoubles() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 0.5) == 160)
    }

    @Test("clamp 上界：240")
    func clampMax() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 0.25) == 240)  // 320 → 240
    }

    @Test("clamp 下界：20")
    func clampMin() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 8.0) == 20)    // 10 → 20
    }

    @Test("round 取整：80/1.05 = 76.19… → 76")
    func roundsToNearest() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 1.05) == 76)
    }

    @Test("单调：scale 升 → target 非严格降")
    func monotoneInScale() {
        let scales: [CGFloat] = [0.2, 0.5, 0.8, 1.0, 1.3, 2.0, 4.0, 10.0]
        let targets = scales.map { PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: $0) }
        for i in 1..<targets.count { #expect(targets[i] <= targets[i - 1]) }
    }

    @Test("极小正 scale：clamp 兜底不溢出（0 附近防御，R3-L1 模型层合法用例）")
    func tinyPositiveScaleClamps() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 1e-9) == 240)
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 1e9) == 20)
    }

    // MARK: rezoomOffset（D3：offset′ = fx − (u_before − cIdx + N′−1)·W/N′）
    // 向量手算依据见设计文档 D3；视口快照直接构造（非饱和值取自 makeViewport 真实输出形态）。

    /// 非饱和 freeScrolling 视口：count=200, N=80, W=800（step=10）, cIdx=150, offset=0
    /// → startIndex=71, pixelShift=0（与 RenderStateBuilderTests 锚定(a) 一致）
    static func viewport(startIndex: Int, pixelShift: CGFloat, step: CGFloat) -> ChartViewport {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 360)
        return ChartViewport(startIndex: startIndex, visibleCount: 80, pixelShift: pixelShift,
                             geometry: ChartGeometry(candleStep: step, candleWidth: step * 0.7,
                                                     gap: step * 0.3),
                             priceRange: PriceRange(min: 9, max: 11),
                             mainChartFrame: frame)
    }

    @Test("右缘焦点（fx=W, offset=0, 非饱和）→ offset′=0（D2 右锚连续性锚点）")
    func rightEdgeFocusYieldsZero() {
        let vp = Self.viewport(startIndex: 71, pixelShift: 0, step: 10)
        let o = PinchZoomModel.rezoomOffset(viewport: vp, currentIdx: 150,
                                            focusX: 800, newCount: 40, mainWidth: 800)
        #expect(abs(o) < 1e-9)
    }

    @Test("中点放大（fx=400, 80→40）→ offset′=400（手算向量，设计 D3）")
    func midFocusZoomIn() {
        let vp = Self.viewport(startIndex: 71, pixelShift: 0, step: 10)
        // u_before = 71 + 400/10 = 111；offset′ = 400 − (111−150+39)·20 = 400
        let o = PinchZoomModel.rezoomOffset(viewport: vp, currentIdx: 150,
                                            focusX: 400, newCount: 40, mainWidth: 800)
        #expect(abs(o - 400) < 1e-9)
    }

    @Test("offset≠0 起点缩小（pixelShift=5, 80→160）→ offset′=−192.5（手算向量）")
    func nonzeroOffsetZoomOut() {
        // 存量 offset=15 → wholeShift=1, startIndex=70, pixelShift=5
        // u_before = 70 + (400−5)/10 = 109.5；offset′ = 400 − (109.5−150+159)·5 = −192.5
        let vp = Self.viewport(startIndex: 70, pixelShift: 5, step: 10)
        let o = PinchZoomModel.rezoomOffset(viewport: vp, currentIdx: 150,
                                            focusX: 400, newCount: 160, mainWidth: 800)
        #expect(abs(o - (-192.5)) < 1e-9)
    }

    @Test("N′=N 恒等（非饱和视口，R2-L3）→ offset′ == 存量 offset")
    func identityCountKeepsOffset() {
        // offset=15 → startIndex=70, pixelShift=5（非饱和：70 ∈ (0, 120)）
        // u_before = 70 + (400−5)/10 = 109.5；offset′ = 400 − (109.5−150+79)·10 = 15
        let vp = Self.viewport(startIndex: 70, pixelShift: 5, step: 10)
        let o = PinchZoomModel.rezoomOffset(viewport: vp, currentIdx: 150,
                                            focusX: 400, newCount: 80, mainWidth: 800)
        #expect(abs(o - 15) < 1e-9)
    }

    // 注：端到端 makeViewport focus 不变量测试（endToEndFocusInvariant）放 Task 2（依赖去硬编码后
    // makeViewport honor visibleCount；放此处 Task 1 时 makeViewport 仍恒 80 分母 → 必 FAIL，破 TDD 绿门，Plan-R2 PR2-01）。
}

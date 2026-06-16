// Kline Trainer Swift Contracts — Wave 3 13c-R1 RenderSignposter host tests
// Spec: docs/superpowers/specs/2026-06-16-wave3-13c-r1-signpost-instrumentation-design.md
// 命名契约 = runbook（分析师在 os_signpost instrument 按名筛 lane）消费的公开契约；pin 防改名静默破坏 runbook。
// StaticString 非 Equatable → 断言走 .description（String）。signpost 未录制为 no-op，host smoke 安全。
import Testing
@testable import KlineTrainerContracts

@Suite("RenderSignposter 命名契约 + 调用 smoke（Wave 3 13c-R1）")
struct RenderSignposterTests {

    @Test("subsystem 常量稳定（runbook 按此 subsystem 筛 os_signpost lane）")
    func subsystemConstant() {
        #expect(RenderSignposter.subsystem == "com.klinetrainer.render")
    }

    @Test("name(op:panel:) 对 6 组合返预期名（StaticString 非 Equatable → 走 .description）")
    func nameContract() {
        #expect(RenderSignposter.name(op: .make, panel: .upper).description == "make-upper")
        #expect(RenderSignposter.name(op: .make, panel: .lower).description == "make-lower")
        #expect(RenderSignposter.name(op: .makeCrosshair, panel: .upper).description == "make-crosshair-upper")
        #expect(RenderSignposter.name(op: .makeCrosshair, panel: .lower).description == "make-crosshair-lower")
        #expect(RenderSignposter.name(op: .draw, panel: .upper).description == "draw-upper")
        #expect(RenderSignposter.name(op: .draw, panel: .lower).description == "draw-lower")
    }

    @Test("begin/end 三类区间对上下 panel 各跑一遍不崩（no-op when not recording）")
    func beginEndSmoke() {
        for panel in [PanelId.upper, PanelId.lower] {
            RenderSignposter.end(RenderSignposter.beginMake(panel: panel))
            RenderSignposter.end(RenderSignposter.beginMakeCrosshair(panel: panel))
            RenderSignposter.end(RenderSignposter.beginDraw(panel: panel))
        }
    }
}

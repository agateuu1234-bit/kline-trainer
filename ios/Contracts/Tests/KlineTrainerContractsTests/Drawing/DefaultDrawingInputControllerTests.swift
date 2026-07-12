import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("DefaultDrawingInputController")
struct DefaultDrawingInputControllerTests {

    // mutation-sanity：用**非零** pixelShift + 非默认 startIndex 的视口，证逆映射在真实平移下成立（非空洞恒等）。
    static func mapper(pixelShift: CGFloat = 3, startIndex: Int = 12) -> CoordinateMapper {
        let main = CGRect(x: 0, y: 0, width: 800, height: 360)
        let vp = ChartViewport(
            startIndex: startIndex, visibleCount: 80, pixelShift: pixelShift,
            geometry: ChartGeometry(candleStep: 10, candleWidth: 7, gap: 3),
            priceRange: PriceRange(min: 10, max: 20), mainChartFrame: main)
        return CoordinateMapper(viewport: vp, displayScale: 2.0)
    }

    static func panel(period: Period = .m60) -> PanelViewState {
        PanelViewState(period: period, interactionMode: .autoTracking,
                       visibleCount: 80, offset: 0, revision: 0)
    }

    @Test("tapToAnchor: period 取自 panel，candleIndex/price 取自 mapper 逆映射")
    func tapToAnchorMapsCorrectly() throws {
        let m = Self.mapper()
        let p = Self.panel(period: .m60)
        let point = CGPoint(x: 235, y: 144)
        let anchor = try #require(DefaultDrawingInputController().tapToAnchor(at: point, panel: p, mapper: m))
        #expect(anchor.period == .m60)
        #expect(anchor.candleIndex == m.xToIndex(235))
        #expect(anchor.price == m.yToPrice(144))
    }

    @Test("tapToAnchor: round-trip —— 由 anchor 映回的 x/y 落回同一 candle/价位（非零 pixelShift 下）")
    func tapToAnchorRoundTrips() throws {
        let m = Self.mapper(pixelShift: 3, startIndex: 12)
        let p = Self.panel()
        // 取一个落在某 candle 中心的 x：indexToX(15)；以及一个已知价位 y：priceToY(15.5)
        let x = m.indexToX(15)
        let y = m.priceToY(15.5)
        let anchor = try #require(DefaultDrawingInputController().tapToAnchor(at: CGPoint(x: x, y: y), panel: p, mapper: m))
        #expect(anchor.candleIndex == 15)                       // xToIndex∘indexToX 恒等（含非零 pixelShift）
        #expect(abs(anchor.price - 15.5) < 1e-9)                // yToPrice∘priceToY 恒等
    }

    // codex branch-R4 high：落锚必须落在主图内。成交量/MACD 区的 tap 换算出的价格在可见价格区间之外，
    // 提交后既不渲染也不可命中（visibleGeometry fail-closed）→ 会在持久化数据里留下看不见的幽灵线。
    @Test("tapToAnchor: 点在 mainChartFrame 下方（成交量/MACD 区）→ nil，不落锚（codex branch-R4 high）")
    func tapToAnchorBelowMainChartFrameReturnsNil() {
        let m = Self.mapper()
        let p = Self.panel()
        // mainChartFrame = (0,0,800,360)；y=400 落在主图下方（成交量/MACD 区）
        let point = CGPoint(x: 235, y: 400)
        #expect(DefaultDrawingInputController().tapToAnchor(at: point, panel: p, mapper: m) == nil)
    }

    @Test("tapToAnchor: 点在 mainChartFrame 上方/左方/右方之外 → nil（codex branch-R4 high）")
    func tapToAnchorOutsideOtherEdgesReturnsNil() {
        let m = Self.mapper()
        let p = Self.panel()
        let ctrl = DefaultDrawingInputController()
        #expect(ctrl.tapToAnchor(at: CGPoint(x: 235, y: -10), panel: p, mapper: m) == nil)   // 上方
        #expect(ctrl.tapToAnchor(at: CGPoint(x: -10, y: 144), panel: p, mapper: m) == nil)   // 左方
        #expect(ctrl.tapToAnchor(at: CGPoint(x: 900, y: 144), panel: p, mapper: m) == nil)   // 右方
    }

    @Test("shouldCommit: horizontal 1 锚 → true")
    func shouldCommitHorizontalOneAnchor() {
        let anchors = [DrawingAnchor(period: .m3, candleIndex: 0, price: 10)]
        #expect(DefaultDrawingInputController().shouldCommit(current: anchors, tool: .horizontal) == true)
    }

    @Test("shouldCommit: horizontal 0 锚 → false")
    func shouldCommitHorizontalZeroAnchor() {
        #expect(DefaultDrawingInputController().shouldCommit(current: [], tool: .horizontal) == false)
    }
}

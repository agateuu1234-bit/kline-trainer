// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingPanelStyleSemanticsTests.swift
// Spec: docs/superpowers/specs/2026-08-12-drawing-tools-P1b-autoselect-design.md §6（D86）
// 三张表（显示 / 置灰 / 写入）统一按 session.mode 分流，UI 层不得再自己判。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("D86：面板的显示 / 置灰 / 写入按 mode 分流")
@MainActor
struct DrawingPanelStyleSemanticsTests {

    static func mapper() -> CoordinateMapper {
        CoordinateMapper(
            viewport: ChartViewport(startIndex: 0, visibleCount: 10, pixelShift: 0,
                                    geometry: ChartGeometry(candleStep: 10, candleWidth: 8, gap: 2),
                                    priceRange: PriceRange(min: 0, max: 100),
                                    mainChartFrame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            displayScale: 2)
    }

    /// 造「画线态 + 上面板有一条已选中的线（经 D82 的提交入口）+ mapper 已发布」。
    /// `locked` 为 true 时那条线是锁定的（`applyStyle` 会被 `editableIgnoringGeometry` 拒）。
    static func drawModeWithSelected(id: String = "A", locked: Bool = false,
                                     colorToken: DrawingColorToken = .orange,
                                     thickness: Int = 1) -> TrainingEngine {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: id, thickness: thickness, colorToken: colorToken,
                                                locked: locked, revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode()                                   // mode 默认 .draw
        e.drawingSession.setCommittedSelection(id: id, panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(e.drawingSession.mode == .draw)
        #expect(e.drawingSession.selectedDrawingID == id)
        return e
    }

    /// 造「选择态 + 上面板有一条已选中的线 + mapper 已发布」。
    static func selectModeWithSelected(id: String = "A", locked: Bool = false,
                                       colorToken: DrawingColorToken = .orange) -> TrainingEngine {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: id, colorToken: colorToken, locked: locked,
                                                revealTick: 0, period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: id, panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        return e
    }

    // ── 第一张表：panelStyle（面板显示什么）──

    @Test("M7 的档：画线态 + 选中线已锁定 + 默认已被改过 → 面板显示的是**本局默认**，不是那条线")
    func drawModePanelShowsSessionDefaultNotTheLine() {
        let e = Self.drawModeWithSelected(locked: true, colorToken: .orange)
        // 把本局默认改成另一个颜色（那条线锁着，改不动 → 两者分叉）
        var d = e.drawingSession.defaultStyle
        d.colorToken = .purple
        e.drawingSession.setDefaultStyle(d)

        #expect(DrawingEditRouter.panelStyle(engine: e).colorToken == .purple,
                "画线态的面板必须显示「接下来要画的样式」= 本局默认")
        #expect(e.drawings[0].colorToken == .orange, "那条线锁着，本来就没被改动")
    }

    @Test("选择态 + 有选中 → 面板显示**那条线自己**的样式（D49 这一半原样保留）")
    func selectModePanelShowsTheSelectedLine() {
        let e = Self.selectModeWithSelected(colorToken: .orange)
        var d = e.drawingSession.defaultStyle
        d.colorToken = .purple
        e.drawingSession.setDefaultStyle(d)

        #expect(DrawingEditRouter.panelStyle(engine: e).colorToken == .orange,
                "选择态必须回显那条线自己的样式，不是默认")
    }

    @Test("选择态 + 无选中 → 面板显示本局默认")
    func selectModeWithoutSelectionShowsDefault() {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        var d = e.drawingSession.defaultStyle
        d.colorToken = .purple
        e.drawingSession.setDefaultStyle(d)
        #expect(DrawingEditRouter.panelStyle(engine: e).colorToken == .purple)
    }

    // ── 第二张表：styleControlsEnabled（灰不灰）──

    @Test("M8 的档：画线态 + 选中线已锁定 → 样式控件**仍可用**（面板此刻改的是本局默认）")
    func drawModeStyleControlsAlwaysEnabled() {
        let e = Self.drawModeWithSelected(locked: true)
        #expect(DrawingEditRouter.styleControlsEnabled(engine: e) == true,
                "画线态恒可用 —— 锁定的线只该让附带的 applyStyle 被拒，不该把面板整个灰掉")
    }

    @Test("选择态 + 选中线已锁定 → 样式控件**置灰**（既有五分量谓词一字未改）")
    func selectModeLockedLineDisablesStyleControls() {
        let e = Self.selectModeWithSelected(locked: true)
        #expect(DrawingEditRouter.styleControlsEnabled(engine: e) == false)
    }

    @Test("选择态 + 无选中 → 样式控件可用（改「下一条线的默认」，1a-iii 起的既有能力）")
    func selectModeWithoutSelectionEnablesStyleControls() {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        #expect(DrawingEditRouter.styleControlsEnabled(engine: e) == true)
    }

    // ── P6：自动选中**不得**放宽不可逆删除的门（codex spec-R3 high 要求的回归档）──

    @Test("P6：画线态 + 自动选中的线**已锁定** → 🗑 恒灰且不可删；🔒 仍可用（否则永远解不开）")
    func lockedLineStaysUndeletableInDrawMode() {
        let e = Self.drawModeWithSelected(locked: true)
        // 两个断言缺一不可：只断言前者，一个「锁定线连 🔒 也灰掉」的实现照样绿。
        #expect(DrawingEditRouter.deleteButtonEnabled(engine: e) == false, "锁定线在画线态被放开删除了")
        #expect(DrawingEditRouter.canDelete(engine: e) == false, "路由层的删除门也被放开了")
        #expect(DrawingEditRouter.lockButtonEnabled(engine: e) == true, "🔒 被误灰 → 那条线永远解不开锁")
    }
}

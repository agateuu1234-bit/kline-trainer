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

    // ── 第三张表：写入（P3 / P4 / P5 / P7 + M15 的五步档）──

    @Test("P3：画线态 + 有选中 + 改样式 → 那条线的该字段变了**且** session.defaultStyle 的该字段也变了")
    func drawModeWritesBothLineAndDefault() {
        let e = Self.drawModeWithSelected(colorToken: .orange)
        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)
        #expect(e.drawings[0].colorToken == .purple, "线没跟着改")
        #expect(e.drawingSession.defaultStyle.colorToken == .purple, "本局默认没改 —— 主语义丢了")
    }

    @Test("P4：选择态 + 选中旧线 + 改样式 → 那条线变了**且** defaultStyle **逐字段未变**（D49 保留的那一半）")
    func selectModeWritesOnlyTheLine() {
        let e = Self.selectModeWithSelected(colorToken: .orange)
        let before = e.drawingSession.defaultStyle
        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)
        #expect(e.drawings[0].colorToken == .purple, "线没改")
        // 逐字段断言（判别力就在这条：只比 colorToken 会漏掉别的字段被顺手写回）
        #expect(e.drawingSession.defaultStyle.colorToken == before.colorToken, "默认被回写了")
        #expect(e.drawingSession.defaultStyle.lineSubType == before.lineSubType)
        #expect(e.drawingSession.defaultStyle.lineStyle == before.lineStyle)
        #expect(e.drawingSession.defaultStyle.thickness == before.thickness)
        #expect(e.drawingSession.defaultStyle.labelMode == before.labelMode)
    }

    @Test("P5：画线态 + 无选中（刚进会话还没画）+ 改样式 → defaultStyle 变了、drawings 全部未变")
    func drawModeWithoutSelectionWritesOnlyDefault() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "OLD", colorToken: .orange, revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode()
        #expect(e.drawingSession.selectedDrawingID == nil)
        let before = e.drawings
        let revisionBefore = e.drawingsRevision

        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)

        #expect(e.drawingSession.defaultStyle.colorToken == .purple)
        expectDrawingsUnchanged(e, before, revisionBefore: revisionBefore)
    }

    @Test("P7：画线态 + 选中线未锁定 + 只改**一项** → 线上**只有该项**变、其余 4 项逐字段未变")
    func drawModeChangesOnlyTheTouchedField() {
        let e = Self.drawModeWithSelected(colorToken: .orange, thickness: 1)
        let before = e.drawings[0]

        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)

        #expect(e.drawings[0].thickness == 3, "用户点的那一项没变")
        // ⚠️ 断言「其余 4 项未变」是 §6.3 #0 的**正向证据**，不能只断言变了的那一项
        #expect(e.drawings[0].colorToken == before.colorToken)
        #expect(e.drawings[0].lineSubType == before.lineSubType)
        #expect(e.drawings[0].lineStyle == before.lineStyle)
        #expect(e.drawings[0].labelMode == before.labelMode)
        #expect(e.drawingSession.defaultStyle.thickness == 3, "本局默认的该项也要变")
    }

    /// **M15 的具名档（spec §7.2 强制项）**：完整五步。
    /// ⚠️ 少任何一步都零判别力 —— 没有「锁定 → 改色被拒」，默认与线不会分叉，
    ///    把写线的 base 改回默认快照也照样绿。
    @Test("M15 五步档：画线 → 锁定 → 改色被拒 → 解锁 → 只改粗细 ⇒ 颜色**仍是原色**（不得被追认）")
    func lockedDivergenceIsNeverRetroactivelyApplied() {
        // 第 1 步：画一条橙色、粗细 1 的线并自动选中（画线态）
        let e = Self.drawModeWithSelected(id: "A", locked: false, colorToken: .orange, thickness: 1)
        #expect(e.drawings[0].colorToken == .orange)

        // 第 2 步：锁定它
        #expect(e.setDrawingLocked(id: "A", locked: true) == true, "锁定失败，本档不成立")
        #expect(e.drawings[0].locked == true)

        // 第 3 步：改颜色为紫 → 默认变紫；applyStyle 被 !d.locked 拒 → 线仍是橙 ⇒ **默认与线已分叉**
        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)
        #expect(e.drawingSession.defaultStyle.colorToken == .purple, "默认必须改成功（主语义）")
        #expect(e.drawings[0].colorToken == .orange, "锁定的线不该被改动 —— 分叉没造出来，本档零判别力")

        // 第 4 步：解锁
        #expect(e.setDrawingLocked(id: "A", locked: false) == true)
        #expect(e.drawings[0].locked == false)

        // 第 5 步：只改**粗细**
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)

        #expect(e.drawings[0].thickness == 3, "用户真正点的那一项要生效")
        #expect(e.drawings[0].colorToken == .orange,
                "颜色被静默追认成紫了 —— §6.3 #0 那条缺陷复现（用户特意锁起来保护过的值被改掉并落盘）")
        #expect(e.drawingSession.defaultStyle.colorToken == .purple, "默认那一侧不受影响，仍是紫")
    }

    /// M11 的档：两个 base 都必须**现取**，不得接收调用方传入的快照。
    @Test("M11 的档：两次连续改动不互相 revert（1b-i PR-4 整支 R3 那条真丢数据回归的守门）")
    func consecutiveMutationsDoNotRevertEachOther() {
        let e = Self.drawModeWithSelected(colorToken: .orange, thickness: 1)
        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 4 }, engine: e)
        #expect(e.drawings[0].colorToken == .purple, "第二次改动把第一次 revert 掉了（用了旧快照）")
        #expect(e.drawings[0].thickness == 4)
        #expect(e.drawingSession.defaultStyle.colorToken == .purple)
        #expect(e.drawingSession.defaultStyle.thickness == 4)
    }
}

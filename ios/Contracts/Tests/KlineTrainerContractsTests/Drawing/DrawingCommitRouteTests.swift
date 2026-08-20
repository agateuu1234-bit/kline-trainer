// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingCommitRouteTests.swift
// Spec: docs/superpowers/specs/2026-08-12-drawing-tools-P1b-autoselect-design.md §3 / §4 / §5
// ⚠️ 本文件**刻意不是** UIKit-gated：D85 把整段「尝试提交」从 ChartContainerView 搬进
//    DrawingEditRouter 的全部收益就在这里 —— 16 条变异里 15 条能在 host 上拿到真证据。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("D83/D84/D85：提交路由 —— 落库与选中处置")
@MainActor
struct DrawingCommitRouteTests {

    /// 主图 x ∈ [0,100]、价格区间 [0,100]、candleStep 10 → index 0..<10 在图内，index ≥ 10 越右缘。
    static func mapper(priceMin: Double = 0, priceMax: Double = 100) -> CoordinateMapper {
        CoordinateMapper(
            viewport: ChartViewport(startIndex: 0, visibleCount: 10, pixelShift: 0,
                                    geometry: ChartGeometry(candleStep: 10, candleWidth: 8, gap: 2),
                                    priceRange: PriceRange(min: priceMin, max: priceMax),
                                    mainChartFrame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            displayScale: 2)
    }

    /// 造「训练态 + 会话已开 + 画线态」的引擎。
    static func drawingEngine(mode: TrainingMode = .normal) -> TrainingEngine {
        let e = TrainingEngine.preview(mode: mode)
        e.toggleDrawingMode()
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.drawingSession.mode == .draw)
        return e
    }

    /// 造一条**属于上面板**的候选线（period 取上面板当前周期；revealTick 由 routeDrawingCommit 盖）。
    static func upperCandidate(_ e: TrainingEngine, id: String, price: Double = 50,
                               candleIndex: Int = 0) -> DrawingObject {
        makeStyledHLine(id: id, revealTick: 0, period: e.upperPanel.period,
                        candleIndex: candleIndex, price: price)
    }

    // ── P1 的内层版（正向档：健康输入必须被放行，spec §7.1）──

    @Test("内层正向：健康候选线 → 落库 + 选中**就是它**（断言等于新那条的 id）")
    func innerGrantsSelectionOnHealthyCommit() {
        let e = Self.drawingEngine()
        let before = e.drawings.count
        let d = Self.upperCandidate(e, id: "N1")
        DrawingEditRouter.routeAndSelect(d, panel: .upper, engine: e)
        #expect(e.drawings.count == before + 1)
        #expect(e.drawingSession.selectedDrawingID == "N1")
        #expect(e.drawingSession.selectedPanel == .upper)
    }

    @Test("内层正向：连落两条 → 选中**转移**到第二条（== id2 且 != id1）")
    func innerTransfersSelectionToSecond() {
        let e = Self.drawingEngine()
        DrawingEditRouter.routeAndSelect(Self.upperCandidate(e, id: "N1"), panel: .upper, engine: e)
        DrawingEditRouter.routeAndSelect(Self.upperCandidate(e, id: "N2", price: 60),
                                         panel: .upper, engine: e)
        #expect(e.drawings.count == 2)
        #expect(e.drawingSession.selectedDrawingID == "N2")
        #expect(e.drawingSession.selectedDrawingID != "N1")
    }

    // ── D84 复盘门：**两个断言缺一不可**（spec §4.2）──

    @Test("D84：复盘下走一次提交 → reviewDrawings **递增**（落线不回归）且选中 **nil**（不越界）")
    func reviewLandsLineButNeverSelects() {
        let e = Self.drawingEngine(mode: .review)
        #expect(e.flow.mode == .review)
        let before = e.reviewDrawings.count
        let d = Self.upperCandidate(e, id: "R1")
        DrawingEditRouter.routeAndSelect(d, panel: .upper, engine: e)
        // 断言 ①：落线能力**没有**被门回归掉（浮动铅笔钮，1a-iii 起的既有功能，D26）
        #expect(e.reviewDrawings.count == before + 1, "复盘落线功能被回归了 —— 门放到 routeDrawingCommit 之前了？")
        // 断言 ②：复盘**不得**获得选中能力（D34 trust boundary，P5 才做带层权限的选中）
        #expect(e.drawingSession.selectedDrawingID == nil, "复盘越界拿到了选中")
    }

    // ── D83 合取项 ①：id 碰撞（出口 e）。**只能经内层构造**（外层的 commitPending 生成全新 UUID）──

    @Test("M5a 的档 / 出口 e：提交前已存在同 id 的老线 → 落库被拒，选中**保持 nil**（绝不选中那条老线）")
    func idCollisionNeverSelectsStaleLine() {
        let e = Self.drawingEngine()
        // 先塞一条同 id 的**老线**，它本来就在可见集合里
        #expect(e.appendDrawing(Self.upperCandidate(e, id: "DUP", price: 40)) == true)
        #expect(e.drawingSession.selectedDrawingID == nil)
        let before = e.drawings.count

        DrawingEditRouter.routeAndSelect(Self.upperCandidate(e, id: "DUP", price: 70),
                                         panel: .upper, engine: e)

        #expect(e.drawings.count == before, "appendDrawing 的 !contains(id) 门应当拒收本次新线")
        #expect(e.drawingSession.selectedDrawingID == nil,
                "只判『提交后在可见集合里』会选中那条陈旧的老线 —— D37 的陷阱原样复现")
    }

    // ── D83 合取项 ②：出口 f（落库成功但不属于本面板）。合取项 ② 唯一的判别力来源 ──

    @Test("N-lock-5 / 出口 f：落库**成功**但该线不属于被点面板 → **不授予选中**")
    func landsButDoesNotBelongToPanelSoNoSelection() {
        let e = Self.drawingEngine()
        #expect(e.upperPanel.period != e.lowerPanel.period, "preview 上下面板周期必须不同，本档才成立")
        let before = e.drawings.count
        // period 取**下**面板的，却当作在**上**面板落的锚：
        //   · appendDrawing 放行（isPeriodConsistent 只比对象自身的锚与 period）
        //   · belongsToPanel(_, panel: .upper, …) 判 false → 不在 .upper 的可见集合里
        let d = makeStyledHLine(id: "F1", revealTick: 0, period: e.lowerPanel.period,
                                candleIndex: 0, price: 50)
        DrawingEditRouter.routeAndSelect(d, panel: .upper, engine: e)

        #expect(e.drawings.count == before + 1, "落库应当成功 —— 少了这条断言，删掉被测那句照样绿")
        #expect(e.drawingSession.selectedDrawingID == nil, "合取项 ② 失守：选中了一条不属于本面板的线")
    }

    // ── M6 的档：分支 2 必须**清空**既有选中（不是「不动」）──

    @Test("M6 的档：先有一个选中 → 下一次提交被拒（id 碰撞）→ 选中被**清空**")
    func rejectedCommitClearsExistingSelection() {
        let e = Self.drawingEngine()
        #expect(e.appendDrawing(Self.upperCandidate(e, id: "DUP", price: 40)) == true)
        e.drawingSession.setCommittedSelection(id: "DUP", panel: .upper)   // 先建立一个选中
        #expect(e.drawingSession.selectedDrawingID == "DUP")

        DrawingEditRouter.routeAndSelect(Self.upperCandidate(e, id: "DUP", price: 70),
                                         panel: .upper, engine: e)

        #expect(e.drawingSession.selectedDrawingID == nil, "被拒的提交留下了陈旧选中 —— D37 的陷阱")
        #expect(e.drawingSession.selectedPanel == nil, "二元组必须整体清（只清 id 会留下半个）")
    }

    // ── M5c 的档：第 ③ 步快照的顺序不是纸面约定 ──

    @Test("M5c 的档：wasPresent 必须是**提交前**的快照 —— 健康提交下它必为 false，选中才建立得起来")
    func snapshotTakenBeforeCommit() {
        let e = Self.drawingEngine()
        DrawingEditRouter.routeAndSelect(Self.upperCandidate(e, id: "S1"), panel: .upper, engine: e)
        #expect(e.drawingSession.selectedDrawingID == "S1",
                "把 wasPresent 挪到 routeDrawingCommit 之后 → 恒 true → 自动选中整体失效")
    }
}

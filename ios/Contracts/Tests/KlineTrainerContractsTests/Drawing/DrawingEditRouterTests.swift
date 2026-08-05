// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditRouterTests.swift
// PR-4：写入路由与可用性谓词的 host 测试。
// ⚠️ 本文件**刻意不是** UIKit-gated：`DrawingEditRouter` 只依赖 TrainingEngine / DrawingSession /
//    CoordinateMapper / HorizontalLineTool，全部无 UIKit —— 几何门、确认框时间窗、失败原因 ×
//    选中生命期这些最危险的判据因此能在 host 上拿到真证据，不必赌 Catalyst。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("DrawingEditRouter：可用性谓词与写入路由")
@MainActor
struct DrawingEditRouterTests {

    /// 主图 y ∈ [0,100]、价格区间 [0,100] → 价格 50 落在图中央（可见）；价格 500 落在图外（不可见）。
    private func mapper(priceMin: Double = 0, priceMax: Double = 100) -> CoordinateMapper {
        CoordinateMapper(
            viewport: ChartViewport(startIndex: 0, visibleCount: 10, pixelShift: 0,
                                    geometry: ChartGeometry(candleStep: 10, candleWidth: 8, gap: 2),
                                    priceRange: PriceRange(min: priceMin, max: priceMax),
                                    mainChartFrame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            displayScale: 2)
    }

    /// 造「画线会话已开 + 处于选择态 + 上面板选中一条 .m60 直线（价格 50）+ mapper 已发布」。
    /// upper 面板周期是 .m60（`TrainingEngine.preview()`），线的 period 必须与之一致才进得了 appendDrawing。
    /// ⚠️ `revealTick: 0`（实测补）：`TrainingEngine.preview()` 的 `tick.globalTickIndex` 恒为 `0`，
    ///   而 `makeStyledHLine` 默认 `revealTick: 7`——`DrawingEditRouter.uniqueSelected` 经 D40
    ///   `visibleDrawings` 过滤 `revealTick <= tick`，硬编码 7 会让线在 tick 0 下恒判「未揭示」，
    ///   使本文件所有「几何应可见」的断言恒假，与被测的几何逻辑本身无关（实测确认：不改会真的红）。
    private func makeSelected(price: Double = 50, id: String = "A",
                              lineSubType: LineSubType = .straight,
                              candleIndex: Int = 0) -> TrainingEngine {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: id, lineSubType: lineSubType, revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: candleIndex, price: price)) == true)
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: id, panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        return e
    }

    @Test("几何真相：线在图内 → true；价格滑出纵向范围 → false；mapper 未发布 → false（fail-closed）")
    func geometryTruth() {
        let e = makeSelected(price: 50)
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == true)

        // 平移/缩放使价格区间变成 [200,300] → 价格 50 落在图外
        e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == false)

        // 从没发布过 mapper 的会话 → 不许乐观放行
        let fresh = TrainingEngine.preview()
        #expect(fresh.appendDrawing(makeStyledHLine(id: "B", revealTick: 0, period: fresh.upperPanel.period,
                                                    candleIndex: 0, price: 50)) == true)
        fresh.toggleDrawingMode()
        fresh.drawingSession.setMode(.select)
        fresh.drawingSession.setSelection(id: "B", panel: .upper)
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: fresh) == false,
                "没有视口就判不了几何 —— 必须 fail-closed")
    }

    @Test("几何真相：无选中恒 false（没有对象就没有几何）")
    func geometryFalseWithoutSelection() {
        let e = TrainingEngine.preview()
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == false)
    }

    @Test("几何真相按 selectedPanel 取 mapper：只发布了**另一个**面板的视口 → false")
    func geometryUsesSelectedPanelMapper() {
        let e = makeSelected(price: 50)
        // 上面板选中，却只有下面板有视口 → 判不了 → false
        let s = e.drawingSession
        s.setViewportMapper(mapper(), panel: .lower)
        #expect(s.selectedPanel == .upper)
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == true)   // 上面板的仍在，仍 true
        // 换成「选中下面板、只有上面板发布过」的对照
        let e2 = TrainingEngine.preview()
        #expect(e2.appendDrawing(makeStyledHLine(id: "C", panelPosition: 1, revealTick: 0,
                                                 period: e2.lowerPanel.period,
                                                 candleIndex: 0, price: 50)) == true)
        e2.toggleDrawingMode()
        e2.drawingSession.setMode(.select)
        e2.drawingSession.setSelection(id: "C", panel: .lower)
        e2.drawingSession.setViewportMapper(mapper(), panel: .upper)      // 只发布上面板
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e2) == false,
                "取错面板的 mapper 会让下面板的线用上面板的坐标系判可见性")
    }

    // MARK: - Fix round 1（评审变异实验挖出：uniqueSelected 的 visibleDrawings 结构性过滤零测试覆盖）

    /// codex/评审把 `uniqueSelected` 改成绕过 `visibleDrawings`、直接 `engine.drawings.first(where:)`
    /// 后跑全量 1762 个测试**一条没红**——因为此前三条测试的 fixture 全构造成"选中的线确实在
    /// `visibleDrawings` 里"。本条补「渐显未到（revealTick > tick）」这个结构性不可见形状：
    /// 选中本身不看 revealTick（`setSelection` 只检查 mode/id 非空），mapper 也已发布、价格在几何范围内
    /// ——如果只看几何，这条线"应该"可见；但它还没被渐显揭示，`uniqueSelected` 必须判它不存在。
    @Test("D40 结构性过滤：选中一条**渐显未到**（revealTick > tick）的线 → 即使几何/mapper 都齐全也恒 false")
    func geometryFalseWhenSelectionNotYetRevealed() {
        let e = TrainingEngine.preview()
        // 不传 revealTick → 用 makeStyledHLine 默认值 7；e.tick.globalTickIndex 恒 0（TrainingEngine.preview() 实测）
        // → revealTick(7) > tick(0)，这条线尚未被渐显揭示。
        #expect(e.appendDrawing(makeStyledHLine(id: "R", period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "R", panel: .upper)          // setSelection 不查 revealTick，能设上
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)    // 几何门也齐全（价格 50 在 [0,100] 内）

        // 前提自足：先证明 fixture 真的构造出了"结构性不可见"——这条线确实不在 visibleDrawings 里，
        // 不是因为别的原因（比如 id 打错）巧合地判成 false。
        let visible = RenderStateBuilder.visibleDrawings(engine: e, panel: .upper, tick: e.tick.globalTickIndex)
        #expect(!visible.contains { $0.id == "R" },
                "fixture 没构造出「渐显未到」这个场景——revealTick/tick 组合不对，下面的 false 断言可能是巧合")

        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == false,
                "渐显未到的线不算存在，几何/mapper 再齐全也不许判可见——这是 D40 结构性过滤该挡住的场景")
    }

    /// 补第二种结构性不可见形状：线的 period 归属**另一个**面板（`belongsToPanel` 判 false），
    /// 但选中二元组（陈旧地）记在本面板——模拟"一条线随切周期迁到另一面板，选中态没跟着清"那类漂移。
    @Test("D40 结构性过滤：选中态记的 id 归属**另一个面板**（belongsToPanel 判 false）→ 即使 revealTick/mapper 都齐全也恒 false")
    func geometryFalseWhenSelectionBelongsToOtherPanel() {
        let e = TrainingEngine.preview()
        // 前提：preview() 两面板周期不同，否则 belongsToPanel 会走「同周期 fail-safe」分支（按 panelPosition
        // 破平局），测的就不是「period 归属判 false」这条路径，而是另一回事。
        #expect(e.upperPanel.period != e.lowerPanel.period,
                "前提不成立：preview() 两面板同周期了，belongsToPanel 会走 fail-safe 分支，本测试测不到目标路径")

        // 线的 period 绑 lowerPanel、panelPosition 也标 1（真实归属下面板），revealTick:0 排除渐显因素干扰。
        #expect(e.appendDrawing(makeStyledHLine(id: "D", panelPosition: 1, revealTick: 0,
                                                period: e.lowerPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        // 陈旧/错位的二元组：selectedPanel 记的是 .upper，但这条线的 period 归属 lower。
        e.drawingSession.setSelection(id: "D", panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)    // upper 面板 mapper 齐全

        // 前提自足：这条线确实不在 upper 面板的 visibleDrawings 里（belongsToPanel 把它挡在了 upper 之外）。
        let visibleUpper = RenderStateBuilder.visibleDrawings(engine: e, panel: .upper, tick: e.tick.globalTickIndex)
        #expect(!visibleUpper.contains { $0.id == "D" },
                "fixture 没构造出「归属另一面板」这个场景——belongsToPanel 没把它挡在 upper 之外，下面的 false 断言可能是巧合")

        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == false,
                "选中态记的面板与线实际归属的面板对不上——这条线在选中面板看不见，不许判可见")
    }
}

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
}

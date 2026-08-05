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

    // ============ D65 两个谓词 ============

    @Test("N18a/N16b（D65）：几何不可见 → 改样式与删除**同进同退**全部不可用")
    func bothPredicatesFollowGeometry() {
        let e = makeSelected(price: 50)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == true)
        #expect(DrawingEditRouter.canDelete(engine: e) == true)
        e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false)
        #expect(DrawingEditRouter.canDelete(engine: e) == false)
    }

    @Test("N18c（防做成永久禁用）：滑回来两个谓词自动恢复，且此时改样式真能成功、revision +1")
    func predicatesRecover() {
        let e = makeSelected(price: 50)
        e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        #expect(DrawingEditRouter.canDelete(engine: e) == false)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)               // 滑回来
        #expect(DrawingEditRouter.canEditStyle(engine: e) == true)
        #expect(DrawingEditRouter.canDelete(engine: e) == true)
        let rev = e.drawingsRevision
        var s = DrawingEditRouter.panelStyle(engine: e); s.thickness = 4
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == true)
        #expect(e.drawings[0].thickness == 4)
        #expect(e.drawingsRevision == rev + 1)
    }

    @Test("N18b（D60）：locked 线两个谓词都假、写入被拒、选中原样保留")
    func lockedDisablesBoth() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "L", locked: true, revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "L", panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false)
        #expect(DrawingEditRouter.canDelete(engine: e) == false)
        let rev = e.drawingsRevision
        var s = DrawingEditRouter.panelStyle(engine: e); s.thickness = 5
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == false)
        #expect(DrawingEditRouter.deleteSelected(engine: e) == false)
        #expect(e.drawings.count == 1)
        #expect(e.drawings[0].thickness == 1)
        #expect(e.drawingsRevision == rev)
        #expect(e.drawingSession.selectedDrawingID == "L", "上游 §7.2：锁定线仍可被选中（否则无法解锁）")
    }

    @Test("N14d（D65 分岔）：携带未来枚举值的线 —— 样式控件灰、🗑 亮，删除真能成功")
    func futureEnumLineSplitsPredicates() throws {
        let e = try engineWithFutureEnumLine(id: "F")
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false, "未来枚举值线改不动样式（D61）")
        #expect(DrawingEditRouter.canDelete(engine: e) == true, "但删整条允许（不产生部分抹除）")
        #expect(DrawingEditRouter.deleteSelected(engine: e) == true)
        #expect(e.drawings.isEmpty)
    }

    @Test("N16a 同族（codex plan-R5-F1 专项，不可省）：**结构性**不可见的线一律判死 —— 渐显未到 / 归属另一面板")
    func structurallyInvisibleIsAlwaysGated() {
        // ① revealTick > tick：线在 drawings 里、价位也映得进视口，但**渲染不出、也命不中**
        let e = TrainingEngine.preview()
        let far = makeStyledHLine(id: "R", period: e.upperPanel.period, candleIndex: 0, price: 50)
        // makeStyledHLine 默认 revealTick: 7 —— 先确认它确实还没到（前提自足断言）
        #expect(far.revealTick > e.tick.globalTickIndex, "fixture 前提不成立：渐显已到，本测试无判别力")
        e.injectDrawingsForTesting([far])
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "R", panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(RenderStateBuilder.visibleDrawings(engine: e, panel: .upper,
                                                   tick: e.tick.globalTickIndex).isEmpty,
                "前提：这条线确实不在渲染/命中集合里")
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == false,
                "只按 id 从 engine.drawings 捞就会漏掉 revealTick —— 用户看不见的线不许过门")
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false)
        #expect(DrawingEditRouter.canDelete(engine: e) == false)
        let rev = e.drawingsRevision
        var s = DrawingEditRouter.panelStyle(engine: e); s.thickness = 5
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == false)
        #expect(DrawingEditRouter.deleteSelected(engine: e) == false)
        #expect(e.drawings.count == 1, "被拒必须零改动 —— 不可逆删除尤其不能漏过去")
        #expect(e.drawingsRevision == rev)

        // ② 陈旧的 selectedPanel：线归属**下**面板（period == lowerPanel.period），选中却记着上面板
        let e2 = TrainingEngine.preview()
        #expect(e2.upperPanel.period != e2.lowerPanel.period, "前提：两面板周期不同，belongsToPanel 才按 period 判")
        #expect(e2.appendDrawing(makeStyledHLine(id: "L", panelPosition: 1, revealTick: 0,
                                                 period: e2.lowerPanel.period, candleIndex: 0, price: 50)) == true)
        e2.toggleDrawingMode(); e2.drawingSession.setMode(.select)
        e2.drawingSession.setSelection(id: "L", panel: .upper)      // 陈旧二元组：id 属下面板、panel 记着上
        e2.drawingSession.setViewportMapper(mapper(), panel: .upper)
        // 前提自足：revealTick 已给 0（渐显已到），确保下面的 false 断言只可能来自 belongsToPanel，
        // 不是与 ①同款的「渐显未到」巧合出的 false（否则本测试测的其实是 ①那条路径）。
        #expect(!RenderStateBuilder.visibleDrawings(engine: e2, panel: .upper,
                                                     tick: e2.tick.globalTickIndex).contains { $0.id == "L" },
                "fixture 没构造出「归属另一面板」这个场景——belongsToPanel 没把它挡在 upper 之外")
        #expect(DrawingEditRouter.canEditStyle(engine: e2) == false,
                "按 selectedPanel 取渲染集合就自动判死；只按 id 捞则会拿另一面板的线去过上面板的几何")
        #expect(DrawingEditRouter.canDelete(engine: e2) == false)
        #expect(DrawingEditRouter.deleteSelected(engine: e2) == false)
        #expect(e2.drawings.count == 1)
    }

    @Test("D63 不回归（防 R5 修复过头）：**几何性**不可见仍留在结构集合里 —— 选中不抖、面板照常回显")
    func geometricallyInvisibleStaysStructurallyPresent() {
        let e = makeSelected(price: 50)
        e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == false)   // 几何判死
        #expect(e.drawingSession.selectedDrawingID == "A", "选中不许被几何不可见抖掉（D63 的全部价值）")
        // 面板仍回显那条线的真实样式（N18d：看得见、改不动）
        #expect(DrawingEditRouter.panelStyle(engine: e).thickness == e.drawings[0].thickness)
        #expect(DrawingEditRouter.panelStyle(engine: e).colorToken == e.drawings[0].colorToken)
    }

    @Test("PD2b（codex plan-R1-F1 专项，不可省）：**无选中**时样式控件仍可用（改「下一条线的默认」），但 🗑 恒灰")
    func noSelectionKeepsStyleControlsUsable() {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        #expect(e.drawingSession.selectedDrawingID == nil)
        #expect(DrawingEditRouter.styleControlsEnabled(engine: e) == true,
                "无选中时面板在改默认样式 —— 灰掉它就把 1a-iii 的能力回归掉了（验收 #13）")
        #expect(DrawingEditRouter.deleteButtonEnabled(engine: e) == false, "无选中时 🗑 恒灰（spec §1.1 #1）")
        // 反向对照：选中一条**看不见**的线 → 样式控件才该灰（证明上面的 true 不是「一律放行」骗过来的）
        let e2 = makeSelected(price: 50)
        e2.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        e2.drawingSession.setSelectionGeometryVisible(false)          // 模拟 Coordinator 刷新后的提示
        #expect(DrawingEditRouter.styleControlsEnabled(engine: e2) == false)
        #expect(DrawingEditRouter.deleteButtonEnabled(engine: e2) == false)
    }

    @Test("PD2（codex plan-R1-F2 专项，不可省）：UI 谓词读 observable 提示、路由谓词现算 —— 提示陈旧时两者必须分岔")
    func displayReadsHintWhileRouteRecomputes() {
        let e = makeSelected(price: 50)
        #expect(e.drawingSession.selectionGeometryVisible == true)     // setSelection 置的
        // 制造「提示还没被 Coordinator 刷新」的那一帧：视口已经变了，提示仍是旧值
        e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        #expect(e.drawingSession.selectionGeometryVisible == true, "前提：提示此刻是陈旧的")
        #expect(DrawingEditRouter.deleteButtonEnabled(engine: e) == true,
                "UI 读提示 —— 这一帧它还亮着，这是可接受的一帧延迟")
        #expect(DrawingEditRouter.canDelete(engine: e) == false,
                "路由现算 —— 必须已经判死；若这里也是 true，说明路由读了提示，陈旧值会放行真删除")
        #expect(DrawingEditRouter.deleteSelected(engine: e) == false, "门在路由那一侧：写入必须被拦住")
        #expect(e.drawings.count == 1)
    }

    @Test("PR-2 交接②：谓词必须包含引擎那三道 spec D65 字面没写的门（否则控件亮着点了没反应）")
    func predicateCoversExtraEngineGates() {
        // ②b 工具已实现：`.trend` 是已知枚举 case，raw-aware 门看不见它，只有 isEditableToolType 挡得住
        let e = TrainingEngine.preview()
        let trend = DrawingObject(id: "T", toolType: .trend,
                                  anchors: [DrawingAnchor(period: e.upperPanel.period,
                                                          candleIndex: 0, price: 50)],
                                  isExtended: false, panelPosition: 0, revealTick: 0,
                                  period: e.upperPanel.period)
        e.injectDrawingsForTesting([trend])
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "T", panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(DrawingStyleAvailability.isEditableToolType(.trend) == false)   // 前提坐实
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false,
                "本构建不懂 .trend 的样式语义，控件必须灰 —— 否则会拿横线假设改写它")
    }

    // ============ D58 候选预检 ============

    @Test("N12b：把可见的 .straight 改成锚点在右缘外的 .ray → 拒、线逐字段不变、revision 不动、选中仍在")
    func candidatePrecheckRejectsInvisibleRay() {
        // candleIndex 40 在 visibleCount=10 的视口里，indexToX = 400 ≥ mainChartFrame.maxX(100)
        let e = makeSelected(price: 50, candleIndex: 40)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == true, "改之前它是可见的 .straight（全宽）")
        let before = e.drawings[0], rev = e.drawingsRevision
        var s = DrawingEditRouter.panelStyle(engine: e); s.lineSubType = .ray
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == false)
        #expect(e.drawings[0] == before)
        #expect(e.drawings[0].lineSubType == .straight)
        #expect(e.drawings[0].isExtended == false)
        #expect(e.drawingsRevision == rev)
        #expect(e.drawingSession.selectedDrawingID == "A", "用户不该因为这次拒绝失去对它的控制")
    }

    @Test("N12c 反向对照（防一律拒绝改 lineSubType）：锚点在图内 → 改 .ray 成功、isExtended 真、revision +1")
    func candidatePrecheckAllowsVisibleRay() {
        let e = makeSelected(price: 50, candleIndex: 0)
        let rev = e.drawingsRevision
        var s = DrawingEditRouter.panelStyle(engine: e); s.lineSubType = .ray
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == true)
        #expect(e.drawings[0].lineSubType == .ray)
        #expect(e.drawings[0].isExtended == true)
        #expect(e.drawingsRevision == rev + 1)
    }

    @Test("候选预检只对 lineSubType：只改粗细时不得因为「改完还看不看得见」再判一次（不引入无谓视口依赖）")
    func precheckOnlyForSubType() {
        // 一条 .ray、锚点在右缘外 → 当前就不可见 → 当前门先挡下（根本走不到候选预检）
        let e = makeSelected(price: 50, lineSubType: .ray, candleIndex: 40)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false)
        var s = DrawingEditRouter.panelStyle(engine: e); s.thickness = 3
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == false, "看不见的东西一律不许改（D65），不是候选预检的功劳")
        #expect(e.drawings[0].thickness == 1)
    }

    // ============ D49 派生回显 ============

    @Test("N1（D49）：面板样式是派生值 —— 有选中显示那条线的、改动只作用于它、defaultStyle 逐字段不变；取消选中回默认")
    func panelStyleIsDerived() {
        let e = TrainingEngine.preview()
        var defaults = DrawingDefaultStyle()
        defaults.lineSubType = .straight; defaults.lineStyle = .dash2
        defaults.thickness = 3; defaults.colorToken = .blue; defaults.labelMode = .right
        e.drawingSession.setDefaultStyle(defaults)
        #expect(e.appendDrawing(makeStyledHLine(id: "A", lineStyle: .solid, thickness: 1,
                                                colorToken: .orange, labelMode: .hidden,
                                                revealTick: 0, period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "A", panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)

        // 选中 → 派生值 == 那条线（逐字段）
        let shown = DrawingEditRouter.panelStyle(engine: e)
        #expect(shown.lineSubType == .straight); #expect(shown.lineStyle == .solid)
        #expect(shown.thickness == 1); #expect(shown.colorToken == .orange)
        #expect(shown.labelMode == .hidden)

        // 改成 C → 线变成 C、defaultStyle 逐字段仍是 A
        var c = shown; c.colorToken = .green; c.thickness = 5
        #expect(DrawingEditRouter.applyStyle(c, engine: e) == true)
        #expect(e.drawings[0].colorToken == .green); #expect(e.drawings[0].thickness == 5)
        #expect(e.drawingSession.defaultStyle == defaults, "改选中线不得污染「下一条线的默认」")

        // 取消选中 → 派生值回到默认
        e.drawingSession.clearSelection()
        #expect(DrawingEditRouter.panelStyle(engine: e) == defaults)
    }

    // ============ D64 存在性谓词 ============

    @Test("N17（D64）：id 不存在 → 清空选中；locked / 语义不成立 / 未来枚举 / 预检拒 → 选中保留；删除成功 → 清空")
    func selectionLifetimeByExistenceOnly() throws {
        // ① id 不存在（被别的路径移除后再调路由）
        let e1 = makeSelected()
        e1.injectDrawingsForTesting([])                                  // 绕过路由直接移除
        #expect(DrawingEditRouter.deleteSelected(engine: e1) == false)
        #expect(e1.drawingSession.selectedDrawingID == nil, "线真没了 → 清空")

        // ② 语义不成立（直接传 .segment，绕开面板）
        let e2 = makeSelected()
        var seg = DrawingEditRouter.panelStyle(engine: e2); seg.lineSubType = .segment
        #expect(DrawingEditRouter.applyStyle(seg, engine: e2) == false)
        #expect(e2.drawingSession.selectedDrawingID == "A", "线还在 → 保留")

        // ③ 未来枚举值
        let e3 = try engineWithFutureEnumLine(id: "F")
        e3.drawingSession.setViewportMapper(mapper(), panel: .upper)
        var s3 = DrawingEditRouter.panelStyle(engine: e3); s3.thickness = 4
        #expect(DrawingEditRouter.applyStyle(s3, engine: e3) == false)
        #expect(e3.drawingSession.selectedDrawingID == "F")

        // ④ UI 预检拒（引擎根本没被调用）
        let e4 = makeSelected(candleIndex: 40)
        var s4 = DrawingEditRouter.panelStyle(engine: e4); s4.lineSubType = .ray
        #expect(DrawingEditRouter.applyStyle(s4, engine: e4) == false)
        #expect(e4.drawingSession.selectedDrawingID == "A")

        // ⑤ 删除成功
        let e5 = makeSelected()
        #expect(DrawingEditRouter.deleteSelected(engine: e5) == true)
        #expect(e5.drawingSession.selectedDrawingID == nil)
    }

    @Test("N21c/d（D66）：两条同 id → update/delete 都 fail 且不打第一条；正常三条 id 互异各打各的")
    func duplicateIdsFailClosed() {
        let e = TrainingEngine.preview()
        let a = makeStyledHLine(id: "X", thickness: 1, revealTick: 0,
                                period: e.upperPanel.period, candleIndex: 0, price: 50)
        let b = makeStyledHLine(id: "X", thickness: 2, revealTick: 0,
                                period: e.upperPanel.period, candleIndex: 0, price: 50)
        e.injectDrawingsForTesting([a, b])                               // 绕过 append 门注入坏状态
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "X", panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        let rev = e.drawingsRevision
        var s = DrawingEditRouter.panelStyle(engine: e); s.thickness = 5
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == false)
        #expect(DrawingEditRouter.deleteSelected(engine: e) == false)
        #expect(e.drawings.count == 2)
        #expect(e.drawings[0].thickness == 1); #expect(e.drawings[1].thickness == 2)
        #expect(e.drawingsRevision == rev)
        #expect(e.drawingSession.selectedDrawingID == "X", "坏状态不是用户的错，别顺手夺走选中")
    }

    // ============ N19e 确认框时间窗（D65 R13-F1）============

    @Test("N19e：确认框期间线滑出屏 → 点「删除」在确认那一刻重算几何 → 不调引擎、不删、选中保留")
    func deleteRechecksGeometryAtConfirmMoment() {
        let e = makeSelected(price: 50)
        #expect(DrawingEditRouter.canDelete(engine: e) == true)         // 点 🗑 那一刻：可删，弹框
        // 弹框期间惯性/自动推进把线带出屏
        e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        let rev = e.drawingsRevision
        #expect(DrawingEditRouter.deleteSelected(engine: e) == false,   // 点「删除」
                "只在点 🗑 那一刻判几何是时序 bug —— 必须在确认那一刻重算")
        #expect(e.drawings.count == 1)
        #expect(e.drawingsRevision == rev)
        #expect(e.drawingSession.selectedDrawingID == "A")
    }

    /// 一条**携带未来未知枚举值**的线（`colorToken:"futureNeon"` / `textColorToken:"futureCyan"`，
    /// 双双 fallback 成 `.orange`）经 lossy 解码进 engine，并选中它。
    /// raw 逐字取自 `DrawingEditDurabilityGateTests.futureRaw`（PR-2 已用它钉 N14a/b），
    /// 构造走 `DrawingTestFixtures` 的 `lossyFromRaw` + `makeEngineWithLossy`（该引擎 upper=lower=`.m3`，
    /// 故 raw 里的 `period` 必须是 `"3m"`；价格 9.0 落在本文件 `mapper()` 的 [0,100] 区间内 → 几何可见）。
    private func engineWithFutureEnumLine(id: String) throws -> TrainingEngine {
        let raw = #"{"id":"F","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"futureNeon","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"futureCyan","textForm":"plain"}"#
        let e = makeEngineWithLossy(try lossyFromRaw(raw))
        #expect(e.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: [id]) == true,
                "fixture 前提：raw-aware 门必须命中，否则这条测试测的是别的东西")
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: id, panel: .upper)
        return e
    }

    // ============ fix round 1（评审挖出的假覆盖）：hasKnownFutureFields 姊妹门 ============

    /// 一条**枚举值全部已知、但携带未来未知顶层字段**的线（`futureIndependentTextColor:true`，
    /// 本构建不认识的顶层 key）经 lossy 解码进 engine，并选中它。
    /// raw **逐字**取自 `DrawingEditDurabilityGateTests.futureTopLevelFieldRejectsStyleEdit`
    /// （PR-2 已用它钉引擎侧 D61 字段门），构造走 `DrawingTestFixtures` 的 `lossyFromRaw` +
    /// `makeEngineWithLossy`（该引擎 upper=lower=`.m3`，故 raw 里的 `period` 必须是 `"3m"`；
    /// 价格 9.0 落在本文件 `mapper()` 的 [0,100] 区间内 → 几何可见）。
    /// ⚠️ 与 `engineWithFutureEnumLine` **刻意不同**：这条线只压 `hasKnownFutureFields` 那半个门
    /// （`colorToken`/`textColorToken` 都是当前已知的 `"orange"`，`hasKnownFutureEnumValues` 判
    /// false）——否则又会被枚举值那道门先挡住，测不到字段门本身（评审亲手变异挖出的假覆盖：
    /// 删掉 `editableIgnoringGeometry` 里的 `hasKnownFutureFields` 那半句，全量 1782 零红，
    /// 因为路由层此前唯一的「未来数据」fixture 只命中枚举值门）。
    private func engineWithFutureFieldLine(id: String) throws -> TrainingEngine {
        let raw = #"{"id":"X","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","futureIndependentTextColor":true}"#
        let e = makeEngineWithLossy(try lossyFromRaw(raw))
        #expect(e.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: [id]) == false,
                "fixture 前提：枚举值门必须**不**命中，否则测的是另一半门（假覆盖同款陷阱）")
        #expect(e.loadedDrawingsLossy.hasKnownFutureFields(liveIds: [id]) == true,
                "fixture 前提：字段门必须命中，否则这条 fixture 没有压到目标判据")
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: id, panel: .upper)
        return e
    }

    @Test("PR-4 fix round 1（评审挖出的假覆盖）：未来**顶层字段**线（枚举值全已知）—— 改样式灰，删整条仍亮")
    func futureFieldLineDisablesEditOnly() throws {
        let e = try engineWithFutureFieldLine(id: "X")
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false, """
                未来顶层字段线改不动样式（D61）—— 只压 hasKnownFutureFields 这半个门，\
                engine.updateDrawingStyle 独立复查同一门、真实写入本就被挡住；这里挡的是\
                「控件亮着、点了没反应」这个 UI 层失效模式
                """)
        #expect(DrawingEditRouter.styleControlsEnabled(engine: e) == false, "UI 侧同样要灰")
        #expect(DrawingEditRouter.canDelete(engine: e) == true, """
                但删整条允许（D61：未来数据线可整条删，删除面不查这两个门）—— \
                防「一律拒绝」骗过上面两条负向断言
                """)
    }

    // ⚠️ **与 brief 字面稿的刻意分歧**：字面稿 `makeStyledHLine` 调用不传 `revealTick`（默认 7），
    //   而 `TrainingEngine.preview(mode: .review)` 走 `ReviewFlow(startTick: 0)` → `tick.globalTickIndex == 0`
    //   （`safeStartTick` 实测钳到 0）。默认 revealTick(7) > tick(0) 会被 D40 的 `visibleDrawings` 结构性过滤
    //   直接挡掉，`uniqueSelected` 恒 nil —— 下面四条负向断言会为了**错误的原因**变绿：把
    //   `updateDrawingStyle`/`deleteDrawing(id:)` 里 `guard flow.mode != .review` 那一行删掉，本测试依然全绿
    //   （已用变异实验验证），说明它测不到本条要测的复盘门。补 `revealTick: 0`（与本文件 `makeSelected` 同款
    //   前提）使这条线结构性可见，`uniqueSelected` 真的能取到它，让下面的 false 断言精确来自 review 门。
    @Test("交接⑥ 纵深：复盘模式下两个谓词恒假、两条路由恒拒（结构上进不去，进去了也动不了）")
    func reviewModeIsInert() {
        let e = TrainingEngine.preview(mode: .review)
        #expect(e.appendDrawing(makeStyledHLine(id: "R", revealTick: 0, period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "R", panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        // 前提自足：证明这条线结构性可见（真进了 uniqueSelected 的候选集），下面的 false 断言才精确
        // 来自 review 门，而不是巧合地来自 D40 的 revealTick/belongsToPanel 过滤。
        #expect(RenderStateBuilder.visibleDrawings(engine: e, panel: .upper,
                                                    tick: e.tick.globalTickIndex).contains { $0.id == "R" },
                "fixture 前提不成立：线结构性不可见，下面的 false 断言测不到 review 门本身")
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false)
        #expect(DrawingEditRouter.canDelete(engine: e) == false)
        var s = DrawingEditRouter.panelStyle(engine: e); s.thickness = 5
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == false)
        #expect(DrawingEditRouter.deleteSelected(engine: e) == false)
        #expect(e.drawings.count == 1)
    }
}

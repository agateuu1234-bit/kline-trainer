// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift
// Spec: docs/superpowers/specs/2026-07-10-drawing-tools-P1b-split-addendum.md §3.1 / §3.3（1a-ii）
// D39 单一真相容器 / D42 全局会话 + 落锚归属被点击面板 / D31 只丢 pending 保工具 / D38 连续画线。
import Testing
import CoreGraphics   // PR-4：fixtureMapper 用 CGRect
@testable import KlineTrainerContracts

@Suite("DrawingSession：画线共享状态容器（D39/D42/D31/D38）")
@MainActor
struct DrawingSessionTests {

    private func anchor(_ price: Double, period: Period = .m3) -> DrawingAnchor {
        DrawingAnchor(period: period, candleIndex: 3, price: price)
    }

    @Test("初始：会话关、无工具、无 pending")
    func initialState() {
        let s = DrawingSession()
        #expect(s.drawingModeActive == false)
        #expect(s.activeDrawingTool == nil)
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
    }

    @Test("activate：开会话 + 置工具；同工具重复 activate 幂等且不丢 pending")
    func activateIsIdempotent() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        s.activate(tool: .horizontal)                       // 重复激活同一工具
        #expect(s.drawingModeActive == true)
        #expect(s.activeDrawingTool == .horizontal)
        #expect(s.pendingAnchors.count == 1)                // 未被误清
    }

    @Test("activate 换工具：丢 pending（旧工具的半成品不能混进新工具）")
    func switchingToolDiscardsPending() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        s.activate(tool: .trend)
        #expect(s.activeDrawingTool == .trend)
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
    }

    @Test("D31：discardPendingAnchors 只丢 pending —— 工具与会话必须存活（绝不是 cancel）")
    func discardPendingKeepsToolAndSession() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        s.discardPendingAnchors()
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
        #expect(s.activeDrawingTool == .horizontal)         // ← 保工具（cancel() 会清掉，本 API 不许）
        #expect(s.drawingModeActive == true)                // ← 保会话
    }

    @Test("D42：落锚归属 = 被点击的面板（与 activePanel 无关）")
    func anchorOwnershipFollowsTappedPanel() {
        let s = DrawingSession()
        s.activate(tool: .trend)                            // 多锚工具：pending 才留得住
        s.addAnchor(anchor(10), panel: .lower)
        #expect(s.pendingAnchorPanel == .lower)
        #expect(s.pendingAnchors.count == 1)
    }

    @Test("D31 触发：下一锚落在**别的**面板 → 只丢 pending，工具存活，新锚归新面板")
    func anchorOnOtherPanelDiscardsPendingButKeepsTool() {
        let s = DrawingSession()
        s.activate(tool: .trend)
        s.addAnchor(anchor(10), panel: .upper)
        s.addAnchor(anchor(20), panel: .lower)              // 换面板落锚
        #expect(s.pendingAnchors.count == 1)                // 上面板那个被丢；只剩新的
        #expect(s.pendingAnchors.first?.price == 20)
        #expect(s.pendingAnchorPanel == .lower)
        #expect(s.activeDrawingTool == .trend)              // ← 工具没被连带清掉
        #expect(s.drawingModeActive == true)
    }

    @Test("对照：下一锚仍在**同一**面板 → 不丢 pending（判据是落锚面板，不是 activePanel）")
    func anchorOnSamePanelKeepsPending() {
        let s = DrawingSession()
        s.activate(tool: .trend)
        s.addAnchor(anchor(10), panel: .upper)
        s.addAnchor(anchor(20), panel: .upper)
        #expect(s.pendingAnchors.count == 2)
        #expect(s.pendingAnchorPanel == .upper)
    }

    @Test("非画线模式落锚 = no-op（不可表达「没有工具却攒着 pending」）")
    func addAnchorIgnoredWhenInactive() {
        let s = DrawingSession()
        s.addAnchor(anchor(10), panel: .upper)              // 未 activate
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
    }

    @Test("D38 连续画线：commit 后只清 pending —— 工具与会话保持不变")
    func commitKeepsToolAndSession() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        let obj = s.commitPending(panelPosition: 0)
        #expect(obj != nil)
        #expect(s.pendingAnchors.isEmpty)                   // pending 清了
        #expect(s.activeDrawingTool == .horizontal)         // ← 工具还在（改造前这里会变 nil）
        #expect(s.drawingModeActive == true)                // ← 会话还在（改造前会退出画线模式）
    }

    @Test("commit 产出：D29 周期绑定 = 首锚周期；isExtended 由 lineSubType 派生（矛盾不可表达）")
    func commitProducesConsistentObject() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10, period: .m15), panel: .lower)
        // 1a-iii：lineSubType 不再是 commitPending 入参，改经 defaultStyle 单一真相
        s.setDefaultStyle({ var st = DrawingDefaultStyle(); st.lineSubType = .straight; return st }())
        let straight = s.commitPending(panelPosition: 1)
        #expect(straight?.period == .m15)                   // D29：跟首锚周期，不跟面板位置
        #expect(straight?.panelPosition == 1)
        #expect(straight?.isExtended == false)
        #expect(straight?.lineSubType == .straight)

        s.addAnchor(anchor(11, period: .m15), panel: .lower)
        s.setDefaultStyle({ var st = DrawingDefaultStyle(); st.lineSubType = .ray; return st }())
        let ray = s.commitPending(panelPosition: 1)
        #expect(ray?.isExtended == true)                    // 不变量：isExtended == (lineSubType == .ray)
        #expect(ray?.lineSubType == .ray)
    }

    @Test("commit 无 pending / 无工具 → nil，且不改会话状态")
    func commitWithoutPendingReturnsNil() {
        let s = DrawingSession()
        #expect(s.commitPending(panelPosition: 0) == nil)   // 未激活
        s.activate(tool: .horizontal)
        #expect(s.commitPending(panelPosition: 0) == nil)   // 激活但无锚
        #expect(s.drawingModeActive == true)
        #expect(s.activeDrawingTool == .horizontal)
    }

    @Test("deactivate：关会话 + 清工具 + 丢 pending（幂等）")
    func deactivateClearsEverything() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        s.deactivate()
        s.deactivate()                                      // 幂等
        #expect(s.drawingModeActive == false)
        #expect(s.activeDrawingTool == nil)
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
    }

    // ── Task 1（1a-iii）：默认样式原子流进提交 ──
    @Test("默认样式全 5 字段原子流进提交的线 + 标签色=线色")
    func defaultStyleFlowsIntoCommit() throws {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        var style = DrawingDefaultStyle()
        style.lineSubType = .ray; style.lineStyle = .dash2
        style.thickness = 3; style.colorToken = .red; style.labelMode = .right
        s.setDefaultStyle(style)
        s.addAnchor(anchor(10), panel: .upper)
        let obj = try #require(s.commitPending(panelPosition: 0))
        #expect(obj.lineSubType == .ray)
        #expect(obj.lineStyle == .dash2)
        #expect(obj.thickness == 3)
        #expect(obj.colorToken == .red)
        #expect(obj.labelMode == .right)
        #expect(obj.textColorToken == .red)       // codex plan-R7：标签色跟线色（否则标签渲染成默认橙）
        #expect(obj.isExtended == true)           // isExtended 由 lineSubType==.ray 派生（不变量保留）
        // 标签**渲染路径**真拿到线色（labelContent.colorToken 来自 textColorToken，codex plan-R7）
        let label = try #require(DrawingLabelLayout.labelContent(for: obj, lineVisible: true))
        #expect(label.colorToken == .red)
    }

    @Test("改默认只影响下一条：先画一条、改默认、再画一条 —— 第一条不变")
    func defaultChangeAffectsOnlyNextLine() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        let first = s.commitPending(panelPosition: 0)          // 默认橙/实线/1/直线/隐藏
        var style = DrawingDefaultStyle(); style.colorToken = .green
        s.setDefaultStyle(style)
        s.addAnchor(anchor(20), panel: .upper)
        let second = s.commitPending(panelPosition: 0)
        #expect(first?.colorToken == .orange)                  // 第一条不被回改
        #expect(second?.colorToken == .green)
    }

    @Test("straight 默认 → isExtended==false（派生不变量）")
    func straightDerivesNotExtended() {
        let s = DrawingSession(); s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        #expect(s.commitPending(panelPosition: 1)?.isExtended == false)
    }

    // MARK: 1a-iv D31：commit 前全锚同 period（本期单锚工具触发不到；供 P1c 多锚工具复用）

    @Test("D31：混 period 的锚集合**拒绝提交** —— 返回 nil、只丢 pending、工具与会话存活")
    func commitRejectsMixedPeriodAnchors() {
        let s = DrawingSession()
        s.activate(tool: .trend)                                  // 多锚工具（本期未开放公共入口，容器层可持有）
        s.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        s.addAnchor(DrawingAnchor(period: .daily, candleIndex: 2, price: 11), panel: .upper)   // ← 混了 period
        #expect(s.pendingAnchors.count == 2)                      // 前置：确实攒了两个

        let drawing = s.commitPending(panelPosition: 0)

        #expect(drawing == nil)                                   // ⭐拒交，不产出坏数据
        #expect(s.pendingAnchors.isEmpty)                         // ⭐只丢 pending
        #expect(s.pendingAnchorPanel == nil)
        #expect(s.activeDrawingTool == .trend)                    // ⭐工具存活（不是整场取消）
        #expect(s.drawingModeActive == true)                      // ⭐会话存活
    }

    @Test("对照（防假绿）：同 period 的多锚集合正常提交 —— 断言不是把多锚工具焊死")
    func commitAcceptsSamePeriodMultiAnchors() {
        let s = DrawingSession()
        s.activate(tool: .trend)
        s.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        s.addAnchor(DrawingAnchor(period: .m60, candleIndex: 5, price: 12), panel: .upper)

        let drawing = s.commitPending(panelPosition: 0)

        #expect(drawing != nil)
        #expect(drawing?.anchors.count == 2)
        #expect(drawing?.period == .m60)                          // D29：period 由 anchors.first 派生
        #expect(s.pendingAnchors.isEmpty)                         // 提交后清 pending
        #expect(s.activeDrawingTool == .trend)                    // D38：提交后工具保持（连续画线）
    }

    // MARK: Task 4（D57）：选择态显式 mode

    @Test("N10: setMode(.select)/discardPendingAnchors/deactivate 三清语义互不混用")
    @MainActor func modeMutatorsAreDistinct() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(DrawingAnchor(period: .daily, candleIndex: 1, price: 5), panel: .upper)
        // setMode(.select)：mode→.select，drawingModeActive 不变(true)，activeDrawingTool 不变(非nil)，pending 清
        s.setMode(.select)
        #expect(s.mode == .select)
        #expect(s.drawingModeActive == true)
        #expect(s.activeDrawingTool == .horizontal)
        #expect(s.pendingAnchors.isEmpty)
        // 选择态不落锚（D57）：addAnchor no-op
        s.addAnchor(DrawingAnchor(period: .daily, candleIndex: 2, price: 6), panel: .upper)
        #expect(s.pendingAnchors.isEmpty)
        // deactivate：mode 复位 .draw，drawingModeActive→false，activeDrawingTool→nil
        s.deactivate()
        #expect(s.mode == .draw)
        #expect(s.drawingModeActive == false)
        #expect(s.activeDrawingTool == nil)
    }

    @Test("D57: 选择态下再点亮同一工具 → 切回 .draw（mode 赋值在幂等 guard 之前）")
    @MainActor func reArmSameToolReturnsToDraw() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.setMode(.select)
        s.activate(tool: .horizontal)      // 同工具：幂等 guard 会 early-return，但 mode 必须已切回 .draw
        #expect(s.mode == .draw)
        #expect(s.activeDrawingTool == .horizontal)
    }

    @Test("D57：commitPending 的 mode==.draw 守卫 —— draw 态可提交，切到 .select 后同一路径改判 nil")
    @MainActor func commitPendingGuardedByMode() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(DrawingAnchor(period: .daily, candleIndex: 1, price: 5), panel: .upper)
        // 对照（防假绿）：draw 态、非空 pending → 正常提交，证明下面的 nil 不是靠「本来就没锚」侥幸过。
        #expect(s.commitPending(panelPosition: 0) != nil)

        // 选择态下即使重新落锚，commitPending 也返 nil（D57：选择态恒不提交）。
        // setMode 会 discardPendingAnchors，addAnchor 自身也守 mode==.draw（no-op）——
        // 故 pendingAnchors 在选择态下结构性恒空；commitPending 的 mode==.draw 守卫是
        // guard 里最前、且当前唯一实际把关的条件，本断言钉住它。
        s.setMode(.select)
        s.addAnchor(DrawingAnchor(period: .daily, candleIndex: 2, price: 6), panel: .upper)
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.commitPending(panelPosition: 0) == nil)
    }

    // MARK: - 1b-i PR-3：选中态（D41 二元组 / D54 生命期）

    @MainActor
    @Test("选中是二元组：setSelection 同时写 id 与 panel；clearSelection 两个一起清")
    func selectionIsPanelIdPair() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.setMode(.select)
        s.setSelection(id: "A", panel: .lower)
        #expect(s.selectedDrawingID == "A")
        #expect(s.selectedPanel == .lower)
        s.clearSelection()
        #expect(s.selectedDrawingID == nil)
        #expect(s.selectedPanel == nil)          // 只清 id 不清 panel = 半个二元组，禁止
    }

    @MainActor
    @Test("D54/D57 不变量：mode == .draw 时选中恒为空（画线态选中不可表达）")
    func drawModeCannotHoldSelection() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        #expect(s.mode == .draw)                 // 前提：本来就是画线态（setSelection 被拒的前提）
        // ① 画线态下 setSelection 直接被拒（fail-closed，不是"先设上再清掉"）
        s.setSelection(id: "A", panel: .upper)
        #expect(s.selectedDrawingID == nil)
        #expect(s.selectedPanel == nil)
        // ② 选择态设上 → 切回画线态 → 清空（D54 clause 2）
        s.setMode(.select)
        s.setSelection(id: "A", panel: .upper)
        #expect(s.selectedDrawingID == "A")
        s.setMode(.draw)
        #expect(s.selectedDrawingID == nil, "从选择态切回画线态必须清空选中（D54 clause 2）")
        #expect(s.selectedPanel == nil)
        // ③ 会话未开时也不许设（fail-closed）
        let t = DrawingSession()
        #expect(t.drawingModeActive == false)    // 前提：确实未开会话（setSelection 被拒的前提）
        t.setSelection(id: "A", panel: .upper)
        #expect(t.selectedDrawingID == nil)
    }

    @MainActor
    @Test("D54 clause 1/2：activate 与 deactivate 都清空选中")
    func activateAndDeactivateClearSelection() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.setMode(.select)
        s.setSelection(id: "A", panel: .upper)
        #expect(s.selectedDrawingID == "A")      // 前提：确实先设上了（否则下面「被清空」恒真）
        // activate 同工具（PR-4 的"点亮图标切回画线态"走这条）——D57 已让 mode 在幂等 guard 之前置 .draw
        s.activate(tool: .horizontal)
        #expect(s.mode == .draw)
        #expect(s.selectedDrawingID == nil, "activate 把 mode 打回 .draw，选中必须一起清")
        // deactivate（退出画线模式，D54 clause 1）
        s.setMode(.select)
        s.setSelection(id: "B", panel: .lower)
        #expect(s.selectedDrawingID == "B")      // 前提：确实先设上了（否则下面「被清空」恒真）
        s.deactivate()
        #expect(s.selectedDrawingID == nil)
        #expect(s.selectedPanel == nil)
        #expect(s.mode == .draw)
    }

    @MainActor
    @Test("N10 扩列：三个「清」语义对**选中态**的差分（discardPendingAnchors 不碰选中）")
    func threeClearSemanticsDifferOnSelection() {
        // discardPendingAnchors：只丢 pending 锚，**选中原样保留**
        let a = DrawingSession()
        a.activate(tool: .horizontal); a.setMode(.select); a.setSelection(id: "X", panel: .upper)
        a.discardPendingAnchors()
        #expect(a.selectedDrawingID == "X", "discardPendingAnchors 只管 pending 锚，不得顺手清选中")
        #expect(a.mode == .select)
        #expect(a.drawingModeActive == true)
        #expect(a.activeDrawingTool == .horizontal)
        // setMode：清选中、保工具与会话
        let b = DrawingSession()
        b.activate(tool: .horizontal); b.setMode(.select); b.setSelection(id: "X", panel: .upper)
        #expect(b.selectedDrawingID == "X")      // 前提：确实先设上了（否则下面「被清空」恒真）
        b.setMode(.draw)
        #expect(b.selectedDrawingID == nil)
        #expect(b.drawingModeActive == true)
        #expect(b.activeDrawingTool == .horizontal)
        // deactivate：全清
        let c = DrawingSession()
        c.activate(tool: .horizontal); c.setMode(.select); c.setSelection(id: "X", panel: .upper)
        c.deactivate()
        #expect(c.selectedDrawingID == nil)
        #expect(c.drawingModeActive == false)
        #expect(c.activeDrawingTool == nil)
    }

    @MainActor
    @Test("反向对照（防过度 fail-closed）：选择态下 setSelection 换选另一条 —— 直接替换，不需要先 clear")
    func selectionReplacesPreviousWithoutClearing() {
        let s = DrawingSession()
        s.activate(tool: .horizontal); s.setMode(.select)
        s.setSelection(id: "A", panel: .upper)
        s.setSelection(id: "B", panel: .lower)
        #expect(s.selectedDrawingID == "B")
        #expect(s.selectedPanel == .lower)
    }

    @MainActor
    @Test("whole-branch fix：空 id 被 setSelection 拒（同 D66「id 唯一非空是写入边界不变量」）")
    func setSelectionRejectsEmptyID() {
        let s = DrawingSession()
        s.activate(tool: .horizontal); s.setMode(.select)
        // 前提：同一会话下传合法 id 是能设上的（否则下面「被拒」恒真——setSelection 本来就设不上任何东西）
        s.setSelection(id: "A", panel: .upper)
        #expect(s.selectedDrawingID == "A")
        #expect(s.selectedPanel == .upper)
        s.clearSelection()
        #expect(s.selectedDrawingID == nil)   // 复位到已知 nil 基线，下面的「被拒」不是「本来就没设过」

        s.setSelection(id: "", panel: .upper)

        #expect(s.selectedDrawingID == nil, "空 id 必须被拒")
        #expect(s.selectedPanel == nil)
    }

    // MARK: - PR-4：视口 mapper 发布 / 几何提示（PD1/PD2）

    @MainActor
    private func fixtureMapper(priceMin: Double = 0, priceMax: Double = 100) -> CoordinateMapper {
        CoordinateMapper(
            viewport: ChartViewport(startIndex: 0, visibleCount: 10, pixelShift: 0,
                                    geometry: ChartGeometry(candleStep: 10, candleWidth: 8, gap: 2),
                                    priceRange: PriceRange(min: priceMin, max: priceMax),
                                    mainChartFrame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            displayScale: 2)
    }

    @Test("PR-4：视口 mapper 按面板隔离存取，未发布过的面板返回 nil（fail-closed）")
    @MainActor func viewportMapperIsPerPanel() {
        let s = DrawingSession()
        #expect(s.viewportMapper(for: .upper) == nil)
        #expect(s.viewportMapper(for: .lower) == nil)
        let m = fixtureMapper()
        s.setViewportMapper(m, panel: .upper)
        #expect(s.viewportMapper(for: .upper) == m)
        #expect(s.viewportMapper(for: .lower) == nil, "写上面板不得污染下面板")
    }

    @Test("PR-4：几何提示随选中生命期走 —— 默认 false；setSelection 置 true（命中即证明可见）；clearSelection 复位")
    @MainActor func geometryHintFollowsSelectionLifetime() {
        let s = DrawingSession()
        #expect(s.selectionGeometryVisible == false)
        s.activate(tool: .horizontal)
        s.setMode(.select)
        s.setSelection(id: "A", panel: .upper)
        // ⚠️ brief 原文是两段字符串字面量用 `+` 相接：`#expect` 的 comment 形参类型是 `Comment?`，
        // 只接受**字面量**（编译期字面量转换），`+` 的运算结果是运行期 `String`，编译不过。
        // 改用三引号多行字面量（行尾 `\` 续行、不插入换行符）合成**单个**字面量，文案一字不变。
        #expect(s.selectionGeometryVisible == true,
                """
                选中只可能来自 hitTest 命中，而 hitTest 内部就是 visibleGeometry != nil —— 命中即证明此刻可见。\
                不置 true 的话，验收 #9「单击一条线 → 🗑 从灰变亮」要等一个 runloop 才生效
                """)
        s.clearSelection()
        #expect(s.selectionGeometryVisible == false, "清空选中必须一并复位几何提示，否则 🗑 会对着空选中亮着")
        // 被拒的 setSelection（非选择态 / 空 id）不得留下一个「亮着」的提示
        let t = DrawingSession()
        t.activate(tool: .horizontal)                 // mode == .draw
        t.setSelection(id: "A", panel: .upper)        // fail-closed：画线态不建立选中
        #expect(t.selectedDrawingID == nil)
        #expect(t.selectionGeometryVisible == false, "选中没建立成，提示不许被置亮")
    }
}

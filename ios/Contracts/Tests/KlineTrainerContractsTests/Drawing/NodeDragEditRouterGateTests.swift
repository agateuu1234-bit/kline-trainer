// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/NodeDragEditRouterGateTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D135d / T15 / T15b）
// P1c 第 3 片 Task 7：拖动进行中，DrawingEditRouter 的十处写入面 / 置灰谓词一律拒，
// 且置灰是真的 observable 变灰（读 nodeDragOwner，不是 nodeDragCurrent）。
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 拖动期间底栏/面板写入全族被拒（D135d）")
struct NodeDragEditRouterGateTests {

    /// 主图 y ∈ [0,100]、价格区间 [0,100]（照抄 DrawingEditRouterTests 的 mapper 构造）。
    private func mapper(priceMin: Double = 0, priceMax: Double = 100) -> CoordinateMapper {
        CoordinateMapper(
            viewport: ChartViewport(startIndex: 0, visibleCount: 10, pixelShift: 0,
                                    geometry: ChartGeometry(candleStep: 10, candleWidth: 8, gap: 2),
                                    priceRange: PriceRange(min: priceMin, max: priceMax),
                                    mainChartFrame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            displayScale: 2)
    }

    /// 造「画线会话已开 + 选择态 + 上面板选中一条 .horizontal 直线（价格 50，未锁）+ mapper 已发布」。
    ///
    /// 撤销栈前置（`undoButtonEnabled`/`redoButtonEnabled` 拖动前必须为 `true`，⛔ 不能恒真而无意义）：
    /// - `redoAvailable == false`（默认）：`toggleLockSelected` 往返（锁上再解锁）填一条记录 ——
    ///   两次调用后深度 1 的栈顶是「解锁」这一步、`isUndone == false` ⇒ `canUndoDrawing == true`；
    ///   `locked` 复位回 `false`，不影响 style/delete 的 `!d.locked` 分量。
    /// - `redoAvailable == true`：只锁一次再 `undo()` 一次 —— 栈顶变成 `isUndone == true`
    ///   ⇒ `canRedoDrawing == true`；`undo` 把内容摊回「锁之前」= `false`，`locked` 同样复位。
    ///   ⚠️ **不能**用同一个引擎状态同时满足 `canUndoDrawing` 与 `canRedoDrawing`——
    ///   深度 1 的栈只有一个 `isUndone` 布尔，两者互斥，必须各造一份夹具。
    private func makeDraggableSelected(id: String = "A", price: Double = 50,
                                       redoAvailable: Bool = false) -> TrainingEngine {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: id, revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: price)) == true)
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: id, panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        if redoAvailable {
            #expect(DrawingEditRouter.toggleLockSelected(engine: e) == true)
            #expect(DrawingEditRouter.undo(engine: e) == true)
        } else {
            #expect(DrawingEditRouter.toggleLockSelected(engine: e) == true)
            #expect(DrawingEditRouter.toggleLockSelected(engine: e) == true)
        }
        #expect(e.drawings.first(where: { $0.id == id })?.locked == false,
                "fixture 前提不成立：locked 没有复位，下面 style/delete 前置会恒假")
        return e
    }

    private func owner(id: String = "A") -> DrawingSession.NodeDragOwner {
        .init(panel: .upper, drawingID: id, anchorIndex: 0, grabPoint: CGPoint(x: 10, y: 20))
    }

    private func anchor(of e: TrainingEngine, id: String = "A") -> DrawingAnchor {
        e.drawings.first(where: { $0.id == id })!.anchors[0]
    }

    /// ⭐ 每一档三段式：拖动前放行 → 拖动中被拒 → 拖动后恢复。
    /// ⭐ 谓词那五档的「拖动前」尤其要紧 —— `deleteButtonEnabled` 在「无选中」时本来就是 false，
    ///    样本没有可用的选中该档就恒真而无意义（spec T15 自检点名）。
    @Test("T15 E1–E5：五个置灰谓词在拖动中一律 false，拖动前后都 true")
    func enabledPredicatesGoFalseDuringDrag() {
        // R-4 裁定：as [(String, (TrainingEngine) -> Bool)] 字面稿若因 @MainActor 隔离编译不过，
        // 改成显式闭包数组——十档不许少，这里就是那份显式闭包写法。
        let probes: [(String, (TrainingEngine) -> Bool)] = [
            ("styleControlsEnabled", { DrawingEditRouter.styleControlsEnabled(engine: $0) }),
            ("deleteButtonEnabled",  { DrawingEditRouter.deleteButtonEnabled(engine: $0) }),
            ("lockButtonEnabled",    { DrawingEditRouter.lockButtonEnabled(engine: $0) }),
            ("undoButtonEnabled",    { DrawingEditRouter.undoButtonEnabled(engine: $0) }),
            ("redoButtonEnabled",    { DrawingEditRouter.redoButtonEnabled(engine: $0) }),
        ]
        for (name, probe) in probes {
            // undoButtonEnabled 的前置（isUndone==false）与 redoButtonEnabled 的前置（isUndone==true）
            // 深度 1 撤销栈互斥，各造一份满足自己前置的夹具（见 makeDraggableSelected 头注）。
            let e = name == "redoButtonEnabled" ? makeDraggableSelected(redoAvailable: true)
                                                 : makeDraggableSelected()
            #expect(probe(e), "\(name) 拖动前就是 false ⇒ 这一档恒真而无意义，样本要改")
            e.drawingSession.beginNodeDrag(owner(), anchor: anchor(of: e))
            #expect(!probe(e), "\(name) 拖动中没被门挡住")
            e.drawingSession.endNodeDrag()
            #expect(probe(e), "\(name) 拖动后没恢复")
        }
    }

    /// 逐个：applyStyle（经样式面板/`applyPanelStyleMutation` 进来）/ deleteSelected /
    /// toggleLockSelected / undo / redo。每档：拖动前调用确实产生了副作用 → 复位 →
    /// 拖动中调用 revision 一点没变（用 `expectDrawingsUnchanged`）→ 拖动后再调又确实生效。
    @Test("T15 W1–W5：五个写入入口在拖动中一律 no-op（drawings 与 revision 零改动）")
    func writeEntriesAreNoOpDuringDrag() {
        // ── W1：applyStyle ──
        do {
            let e = makeDraggableSelected()
            // ⚠️ thickness 值域是 1…5（`DrawingDefaultStyle.thicknessRange`，`DrawingEnums.swift:46`）——
            //   越域值会被 `withStyle` 的值域闸拒（`DrawingObjectStyleEdit.swift:27`），与被测的拖动门无关。
            var s = DrawingEditRouter.panelStyle(engine: e); s.thickness = 3
            #expect(DrawingEditRouter.applyStyle(s, engine: e) == true, "前置：拖动前 applyStyle 确实生效")
            #expect(e.drawings.first(where: { $0.id == "A" })?.thickness == 3)

            let rev = e.drawingsRevision
            let before = e.drawings
            var s2 = DrawingEditRouter.panelStyle(engine: e); s2.thickness = 4
            e.drawingSession.beginNodeDrag(owner(), anchor: anchor(of: e))
            #expect(DrawingEditRouter.applyStyle(s2, engine: e) == false, "拖动中 applyStyle 必须被拒")
            expectDrawingsUnchanged(e, before, revisionBefore: rev)
            e.drawingSession.endNodeDrag()

            #expect(DrawingEditRouter.applyStyle(s2, engine: e) == true, "拖动结束后必须恢复生效")
            #expect(e.drawings.first(where: { $0.id == "A" })?.thickness == 4)
            #expect(e.drawingsRevision == rev + 1)
        }

        // ── W2：deleteSelected —— 删除不可逆，用 undo 撤回避免真的丢线影响后续断言 ──
        do {
            let e = makeDraggableSelected()
            #expect(DrawingEditRouter.deleteSelected(engine: e) == true, "前置：拖动前 deleteSelected 确实生效")
            #expect(e.drawings.isEmpty)
            #expect(DrawingEditRouter.undo(engine: e) == true)          // 复位：线恢复回来
            // undo 恢复回来的线不自动选中（D37）——继续用 deleteSelected 施测需要重新选中它。
            e.drawingSession.setSelection(id: "A", panel: .upper)
            #expect(DrawingEditRouter.deleteButtonEnabled(engine: e) == true, "复位后前置仍成立")

            let rev = e.drawingsRevision
            let before = e.drawings
            e.drawingSession.beginNodeDrag(owner(), anchor: anchor(of: e))
            #expect(DrawingEditRouter.deleteSelected(engine: e) == false, "拖动中 deleteSelected 必须被拒")
            expectDrawingsUnchanged(e, before, revisionBefore: rev)
            e.drawingSession.endNodeDrag()

            #expect(DrawingEditRouter.deleteSelected(engine: e) == true, "拖动结束后必须恢复生效")
            #expect(e.drawings.isEmpty)
        }

        // ── W3：toggleLockSelected ──
        do {
            let e = makeDraggableSelected()
            #expect(DrawingEditRouter.toggleLockSelected(engine: e) == true, "前置：拖动前 toggleLockSelected 确实生效")
            #expect(e.drawings.first(where: { $0.id == "A" })?.locked == true)
            #expect(DrawingEditRouter.toggleLockSelected(engine: e) == true)   // 复位：解锁
            #expect(e.drawings.first(where: { $0.id == "A" })?.locked == false)

            let rev = e.drawingsRevision
            let before = e.drawings
            e.drawingSession.beginNodeDrag(owner(), anchor: anchor(of: e))
            #expect(DrawingEditRouter.toggleLockSelected(engine: e) == false, "拖动中 toggleLockSelected 必须被拒")
            expectDrawingsUnchanged(e, before, revisionBefore: rev)
            e.drawingSession.endNodeDrag()

            #expect(DrawingEditRouter.toggleLockSelected(engine: e) == true, "拖动结束后必须恢复生效")
            #expect(e.drawings.first(where: { $0.id == "A" })?.locked == true)
        }

        // ── W4：undo ── 用 redo 把「撤销可用」这个前置复位（redo 不是本档要测的操作）
        do {
            let e = makeDraggableSelected()
            #expect(e.canUndoDrawing == true, "前置条件：撤销栈非空")
            let revBeforeUndo = e.drawingsRevision
            #expect(DrawingEditRouter.undo(engine: e) == true, "前置：拖动前 undo 确实生效")
            #expect(e.drawingsRevision == revBeforeUndo + 1)
            #expect(e.drawings.first(where: { $0.id == "A" })?.locked == true,
                    "undo 把上一步「解锁」撤回，回到锁定")
            #expect(DrawingEditRouter.redo(engine: e) == true)          // 复位：撤销栈重新可撤销
            #expect(e.drawings.first(where: { $0.id == "A" })?.locked == false)

            let rev = e.drawingsRevision
            let before = e.drawings
            e.drawingSession.beginNodeDrag(owner(), anchor: anchor(of: e))
            #expect(DrawingEditRouter.undo(engine: e) == false, "拖动中 undo 必须被拒")
            expectDrawingsUnchanged(e, before, revisionBefore: rev)
            e.drawingSession.endNodeDrag()

            #expect(DrawingEditRouter.undo(engine: e) == true, "拖动结束后必须恢复生效")
            #expect(e.drawings.first(where: { $0.id == "A" })?.locked == true)
        }

        // ── W5：redo ── 用 undo 把「重做可用」这个前置复位（undo 不是本档要测的操作）
        do {
            let e = makeDraggableSelected(redoAvailable: true)
            #expect(e.canRedoDrawing == true, "前置条件：redo 可用")
            let revBeforeRedo = e.drawingsRevision
            #expect(DrawingEditRouter.redo(engine: e) == true, "前置：拖动前 redo 确实生效")
            #expect(e.drawingsRevision == revBeforeRedo + 1)
            #expect(e.drawings.first(where: { $0.id == "A" })?.locked == true,
                    "redo 把撤销掉的「锁定」重做回来")
            #expect(DrawingEditRouter.undo(engine: e) == true)          // 复位：重做栈重新可用
            #expect(e.drawings.first(where: { $0.id == "A" })?.locked == false)

            let rev = e.drawingsRevision
            let before = e.drawings
            e.drawingSession.beginNodeDrag(owner(), anchor: anchor(of: e))
            #expect(DrawingEditRouter.redo(engine: e) == false, "拖动中 redo 必须被拒")
            expectDrawingsUnchanged(e, before, revisionBefore: rev)
            e.drawingSession.endNodeDrag()

            #expect(DrawingEditRouter.redo(engine: e) == true, "拖动结束后必须恢复生效")
            #expect(e.drawings.first(where: { $0.id == "A" })?.locked == true)
        }
    }

    /// Step 5 实测（⛔ 不得推理代替实跑）：`applyPanelStyleMutation` 在拖动中的分叉行为。
    ///
    /// 拖动只可能发生在「选择态 + 已选中」（D135b/c 的构造性不变量：`beginNodeDrag` 只在这种状态下
    /// 由生产路径调用，`setMode(.draw)`/`clearSelection()` 都会先 `endNodeDrag()`）。而
    /// `applyPanelStyleMutation` 的三分支里，**只有 `.draw` 分支**才会同时写「本局默认」与「那条线」；
    /// 选择态+有选中命中的是**只改那条线、不回写默认**的分支 —— 这个分支在拖动期间永远是唯一可达分支。
    /// 所以实测结论是：拖动中调它，`applyStyle` 内部的 W1 门直接把整次调用变成**双零改动**——
    /// 默认样式**不变**，不是简报预判的「默认该变」。真实原因见下方断言处的行内注释。
    @Test("Step 5 实测：applyPanelStyleMutation 拖动中的分叉行为")
    func applyPanelStyleMutationDuringDrag() {
        let e = makeDraggableSelected()
        let before = e.drawings
        let rev = e.drawingsRevision
        let defaultBefore = e.drawingSession.defaultStyle

        // thickness 用 3（值域 1…5 内、且与 makeStyledHLine 的默认值 1 不同）——用越域值会被
        // `withStyle` 的值域闸拒绝，那与被测的拖动门无关，会让下面的「零改动」断言恒真而无意义。
        e.drawingSession.beginNodeDrag(owner(), anchor: anchor(of: e))
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        e.drawingSession.endNodeDrag()

        // 实测结果（不是预判）：session.mode == .select 且 selectedDrawingID != nil ⇒
        // applyPanelStyleMutation 命中「选择态+有选中」分支，那个分支只调 applyStyle（不碰
        // session.defaultStyle）；W1 门挡住 applyStyle ⇒ 默认样式与线一起零改动。
        #expect(e.drawingSession.defaultStyle == defaultBefore,
                "实测：拖动中选择态+有选中命中的分支本来就不写默认，默认样式没变——这与简报 Step 5 的预判不同，如实记录，不据此在代码里加门")
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    /// T15b 端到端（评审点名的那条）：拖动已经偏移了 → 另一只手点 🔒 → 继续移动 → 松手
    /// ⇒ ① 锁没生效（`locked` 仍是 false，不是「toggleLock 返回了 false」）；
    ///    ② 拖动正常写入（`updateDrawingAnchor` 是 D136 的引擎写入面，不经 DrawingEditRouter，
    ///       松手提交是 Phase B 手势收尾路径要调的那个 API，这里直调它模拟「松手」）；
    ///    ③ 调整没丢：锚点是松手那一刻的值，不是「线还在」这种弱断言。
    @Test("T15b 端到端：拖动已偏移 → 点 🔒 → 继续移动 → 松手 ⇒ 锁没生效、正常写入、调整没丢")
    func lockDuringDragDoesNotLoseTheAdjustment() {
        let e = makeDraggableSelected()
        let period = e.upperPanel.period
        let revBefore = e.drawingsRevision

        // 拖动已经偏移：占槽 + 已经移动过一次
        e.drawingSession.beginNodeDrag(owner(), anchor: anchor(of: e))
        e.drawingSession.updateNodeDragCurrent(DrawingAnchor(period: period, candleIndex: 0, price: 60))

        // 另一只手点 🔒：必须被 D135d 的新门挡住
        #expect(DrawingEditRouter.toggleLockSelected(engine: e) == false, "拖动中 toggleLockSelected 必须被拒")
        #expect(e.drawings.first(where: { $0.id == "A" })?.locked == false,
                "① 锁没生效——断言的是实际状态，不是返回值")

        // 继续移动
        let releasedAnchor = DrawingAnchor(period: period, candleIndex: 0, price: 70)
        e.drawingSession.updateNodeDragCurrent(releasedAnchor)

        // 松手：提交最终锚点（D136，Phase B 手势收尾路径调的就是这个引擎 API）
        #expect(e.updateDrawingAnchor(id: "A", anchorIndex: 0, anchor: releasedAnchor) == true,
                "② 拖动正常写入——没被刚才那次被拒的锁定门连累")
        e.drawingSession.endNodeDrag()

        #expect(e.drawingsRevision == revBefore + 1, "只应该有这一次真写入递增 revision")
        #expect(e.drawings.first(where: { $0.id == "A" })?.anchors[0] == releasedAnchor,
                "③ 锚点是松手那一刻的值")
        #expect(e.drawings.first(where: { $0.id == "A" })?.locked == false)
    }
}

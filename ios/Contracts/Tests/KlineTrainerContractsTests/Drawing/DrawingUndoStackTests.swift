// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoStackTests.swift
// Spec: docs/superpowers/specs/2026-08-11-drawing-tools-P1b-1b-ii-lock-undo-design.md §2
// 计划新增决策：D101（入栈条件）/ D102（一次动作作用域）/ D103（清栈绑真翻转）
import CoreGraphics        // CGRect（periodSwitchKeepsStack 的 recordRenderBounds 需要）
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("1b-ii 撤销：入栈（D75 + D101）")
@MainActor
struct DrawingUndoPushTests {

    /// 从栈顶取「那一对 before/after 的 id 与下标」，供断言用。
    /// ⚠️ **绝不能直接比 `DrawingObject ==`** —— 它**排除 `id`**（`Models.swift` 实测），
    ///    一次「把 id 改写了、其它字段全同」的坏写入会从所有 == 断言底下溜过去。
    static func topShape(_ e: TrainingEngine) -> String? {
        guard let d = e.drawingUndoEntryForTesting?.drawingsDelta else { return nil }
        switch d {
        case .inserted(let after, let at):            return "inserted(\(after.id))@\(at)"
        case .removed(let before, let at):            return "removed(\(before.id))@\(at)"
        case .replaced(let before, let after, let at): return "replaced(\(before.id)->\(after.id))@\(at)"
        }
    }

    @Test("空引擎：↩ / ↪ 都不可用（栈为空）")
    func freshEngineHasEmptyStack() {
        let e = TrainingEngine.preview()
        #expect(e.canUndoDrawing == false)
        #expect(e.canRedoDrawing == false)
        #expect(e.drawingUndoEntryForTesting == nil)
    }

    @Test("画线入栈：appendDrawing 成功 → 栈顶是 inserted，下标 = 追加后的那个位置")
    func appendPushesInserted() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "B", candleIndex: 4)) == true)
        #expect(Self.topShape(e) == "inserted(B)@1", "下标必须是追加后 B 所在的位置 1，不是 0")
        #expect(e.canUndoDrawing == true)
        #expect(e.canRedoDrawing == false, "刚做完新动作，↪ 必须是灰的")
    }

    @Test("删线入栈：deleteDrawing(id:) 成功 → 栈顶是 removed，下标 = 删除前的位置")
    func deleteByIdPushesRemoved() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "B", candleIndex: 4)) == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "C", candleIndex: 5)) == true)
        #expect(e.deleteDrawing(id: "B") == true)
        #expect(Self.topShape(e) == "removed(B)@1", "下标必须是 B 被删之前所在的 1（保序的全部依据）")
    }

    @Test("改样式入栈：updateDrawingStyle 成功 → 栈顶是 replaced，before/after 同一条线")
    func updateStylePushesReplaced() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", thickness: 1)) == true)
        var s = DrawingDefaultStyle(); s.thickness = 3
        #expect(e.updateDrawingStyle(id: "A", style: s) == true)
        #expect(Self.topShape(e) == "replaced(A->A)@0")
        guard case .replaced(let before, let after, _) = e.drawingUndoEntryForTesting!.drawingsDelta else {
            Issue.record("栈顶不是 replaced"); return
        }
        #expect(before.thickness == 1, "before 必须是**改动前**的快照")
        #expect(after.thickness == 3, "after 必须是**改动后**的快照")
    }

    @Test("锁定入栈：setDrawingLocked 成功 → 栈顶是 replaced，locked 前后不同")
    func lockPushesReplaced() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", locked: false)) == true)
        #expect(e.setDrawingLocked(id: "A", locked: true) == true)
        guard case .replaced(let before, let after, let at) = e.drawingUndoEntryForTesting!.drawingsDelta else {
            Issue.record("栈顶不是 replaced"); return
        }
        #expect(before.locked == false && after.locked == true && at == 0)
    }

    // ── D101：内容没变 = 零副作用，**也不入栈**（栈顶必须原样保留） ──

    @Test("D101/N-R：no-op 改样式**不冲掉**栈顶那次真编辑")
    func noopStyleEditDoesNotClobberTop() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", thickness: 1)) == true)
        var s = DrawingDefaultStyle(); s.thickness = 3
        #expect(e.updateDrawingStyle(id: "A", style: s) == true)          // 真编辑，入栈
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "A", style: s) == true)          // 同一份样式再来一次 = no-op
        #expect(e.drawingsRevision == rev, "D80：内容没变不得递增 revision")
        guard case .replaced(let before, _, _) = e.drawingUndoEntryForTesting!.drawingsDelta else {
            Issue.record("栈顶不是 replaced"); return
        }
        #expect(before.thickness == 1, "栈顶仍必须是那次**真编辑**（before=1），不是被 no-op 覆盖成 before=3")
    }

    @Test("D101：幂等锁定不入栈（栈顶保持不变）")
    func idempotentLockDoesNotPush() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", locked: true)) == true)
        #expect(Self.topShape(e) == "inserted(A)@0")
        #expect(e.setDrawingLocked(id: "A", locked: true) == true, "D80：已经是该值 → 返 true")
        #expect(Self.topShape(e) == "inserted(A)@0", "幂等路径不得入栈，栈顶必须还是那次画线")
    }

    @Test("被拒的写入不入栈（三条门各一条）")
    func rejectedWritesDoNotPush() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        let top = Self.topShape(e)
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == false, "D66 重复 id → 拒")
        #expect(e.deleteDrawing(id: "ZZZ") == false, "不存在的 id → 拒")
        #expect(e.updateDrawingStyle(id: "ZZZ", style: DrawingDefaultStyle()) == false)
        #expect(Self.topShape(e) == top, "被拒的写入一条都不许入栈")
    }

    // ── 深度 1（N-K 的**栈内容**那半；行为那半在 Task 3） ──

    @Test("N-K 栈内容：深度 1 —— 新动作直接覆盖栈顶")
    func stackDepthIsOne() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "B", candleIndex: 4)) == true)
        #expect(Self.topShape(e) == "inserted(B)@1", "栈里只能留最后一条")
    }
}

@Suite("1b-ii 撤销：会话生命周期与撤销栈（D74 + D103）")
@MainActor
struct DrawingUndoSessionLifecycleTests {

    /// 造「已进画线模式 + 栈非空」。**必须走真实入栈路径**（不许用 inject 钩子）——
    /// spec N-N3 原稿那条恒过测试的错误就是拿一条根本没经过被测路径的状态去断言。
    static func drawingModeWithNonEmptyStack() -> TrainingEngine {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "A", revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        #expect(e.canUndoDrawing == true, "前置：栈必须非空")
        return e
    }

    // ── 两条**必须清**（且都是**非 UI 触发**的退出路径） ──

    @Test("N-Q1 下单成交：advanceAndAccount 隐式结束会话 → 栈必须清空")
    func tradeTriggeredClearsStack() {
        let e = Self.drawingModeWithNonEmptyStack()
        // ⚠️ 用 `holdOrObserve` 而不是 `buy(panel:shares:)`：前者是**不需要资金/持仓**的推进路径，
        //    同样走 `advanceAndAccount` → `.tradeTriggered` → `endDrawingSessionIfActive`（:532），
        //    既有测试 `TrainingEngineDrawingHandlerH1Tests.swift:103` 用的就是它。
        e.holdOrObserve(panel: .upper)
        #expect(e.drawingSession.drawingModeActive == false, "前置：下单确实隐式结束了画线会话")
        #expect(e.canUndoDrawing == false)
        #expect(e.canRedoDrawing == false)
        #expect(e.drawingUndoEntryForTesting == nil)
    }

    @Test("N-Q2 cancelDrawingAllPanels（第三条拆除路径）→ 栈必须清空")
    func cancelAllPanelsClearsStack() {
        let e = Self.drawingModeWithNonEmptyStack()
        e.cancelDrawingAllPanels()
        #expect(e.drawingSession.drawingModeActive == false)
        #expect(e.canUndoDrawing == false)
        #expect(e.drawingUndoEntryForTesting == nil)
    }

    @Test("N-L 栈生命期：退出画线模式再进入 → ↩ / ↪ 均不可用")
    func reenteringDrawingModeStartsWithEmptyStack() {
        let e = Self.drawingModeWithNonEmptyStack()
        e.toggleDrawingMode()                   // 退出（endDrawingSessionIfActive）
        #expect(e.canUndoDrawing == false)
        e.toggleDrawingMode()                   // 再进
        #expect(e.canUndoDrawing == false)
        #expect(e.canRedoDrawing == false)
    }

    // ── 一条**必须保留**（正向测试，防我们把切周期误当退出路径） ──

    @Test("N-Q3 切周期必须**保留**栈 —— 切周期不结束会话（spec §2.1 的 ⛔ 段）")
    func periodSwitchKeepsStack() {
        // ⚠️ **必须**用 `engineMultiPeriod()`，**不能**用 `TrainingEngine.preview()`（fix-1 修复）：
        //    preview 的 allCandles 只有 .m3/.m60/.daily（**没有 .m15**），当前组合 (.m60,.daily)
        //    无论 toSmaller（→ 需 .m15）还是 toLarger（→ 需 .weekly）都会撞 switchPeriodCombo 的
        //    「target 周期无数据 → no-op」守卫 → 切周期请求被挡回、什么都没发生，那三条断言在
        //    「什么都没做」的情况下当然全过 —— 证明的不是「切周期不清栈」，而是「什么都不做时状态
        //    不变」，测试恒真 = 假守卫，U-M9（切周期末尾塞一句无条件清栈）测不出来。
        //    同一个坑已有先例：`TrainingEngineDrawingSessionTests.swift:76-80`。
        //    `engineMultiPeriod()` 备了 .m15/.m60/.daily，(.m60,.daily) --toSmaller--> (.m15,.m60)
        //    是能真切成功的。
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        #expect(e.canUndoDrawing == true, "前置：栈必须非空")
        let topBefore = e.drawingUndoEntryForTesting?.isUndone

        e.switchPeriodCombo(direction: .toSmaller)   // (.m60,.daily) → (.m15,.m60) 真的能切成功

        #expect(e.upperPanel.period == .m15, "周期真的变了（防假绿：不是撞 no-op 守卫）")
        #expect(e.lowerPanel.period == .m60)
        #expect(e.drawingSession.drawingModeActive == true,
                "切周期后必须仍在画线模式（restoreDrawingSessionAfterPeriodChange 刻意保留会话）")
        #expect(e.canUndoDrawing == true, "同一个会话没结束 → 撤销记录必须留着")
        #expect(e.drawingUndoEntryForTesting?.isUndone == topBefore, "栈内容不得被动过")

        // ③（控制者裁决补，spec §2.6 N-Q3）：切周期之后点 ↩ 必须能正确撤掉**切换之前**画的那条线。
        #expect(e.drawings.map(\.id) == ["A"], "前置：那条线切周期之后还在（未被期间切换清掉）")
        #expect(e.undoDrawing() == true)
        #expect(e.drawings.map(\.id) == [], "↩ 必须撤掉切周期之前画的那条线 A")
    }

    // ── 两条**必须保留**（把「清栈写在函数入口」那种实现直接测红，D103） ──

    @Test("N-Q4 被拒的 begin 必须保留栈（未实现工具 → 早退，无任何状态翻转）")
    func rejectedBeginKeepsStack() {
        let e = Self.drawingModeWithNonEmptyStack()
        // ⚠️ `DrawingToolType` **不是** CaseIterable（Models.swift:37 实测），没有 `allCases`。
        //    直接点名 `.trend`，并**当场断言它确实不在 implemented 里** —— 将来 P1c 把 .trend
        //    实现了，本断言会红，逼实施者换一个仍未实现的工具，而不是让本档静默失效。
        #expect(DrawingToolType.implemented == [.horizontal], "implemented 变了 → 本档的早退前提失效")
        e.beginDrawingSession(tool: .trend)     // 第一行 guard implemented 早退
        #expect(e.canUndoDrawing == true, "被拒的 begin 一个状态都没翻，绝不许清栈")
    }

    @Test("N-Q5 冗余的 begin-while-active 必须保留栈（activate 幂等，无翻转）")
    func redundantBeginKeepsStack() {
        let e = Self.drawingModeWithNonEmptyStack()
        e.beginDrawingSession(tool: .horizontal)   // 会话已开，再调一次
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.canUndoDrawing == true,
                "D103：activate 幂等、没有翻转 —— 清栈若写在函数入口/activate 旁边无条件执行，本条必红")
    }
}

@Suite("1b-ii 撤销：四类动作往返 + 保序 + 深度 1（D76）")
@MainActor
struct DrawingUndoRoundTripTests {

    /// 造一个已进画线模式的引擎（撤销栈只在画线会话内有意义）。
    static func engine() -> TrainingEngine {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        return e
    }
    static func line(_ id: String, _ e: TrainingEngine, price: Double = 50, candleIndex: Int = 0) -> DrawingObject {
        makeStyledHLine(id: id, revealTick: 0, period: e.upperPanel.period,
                        candleIndex: candleIndex, price: price)
    }

    // ── N-M：四类动作各一条「做 → ↩ 复原 → ↪ 重做」+ revision 严格 +1 ──

    @Test("N-M 画线：做 → ↩ 线消失 → ↪ 线回来，revision 每步严格 +1")
    func roundTripAppend() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        let rev = e.drawingsRevision
        #expect(e.undoDrawing() == true)
        #expect(e.drawings.map(\.id) == [])
        #expect(e.drawingsRevision == rev + 1, "undo 必须递增 revision（autosave 的输入）")
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == true)
        #expect(e.redoDrawing() == true)
        #expect(e.drawings.map(\.id) == ["A"])
        #expect(e.drawingsRevision == rev + 2)
        #expect(e.canUndoDrawing == true && e.canRedoDrawing == false)
    }

    @Test("N-M 删线：做 → ↩ 线回来 → ↪ 线又没了")
    func roundTripDelete() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        #expect(e.deleteDrawing(id: "A") == true)
        let rev = e.drawingsRevision
        #expect(e.undoDrawing() == true)
        #expect(e.drawings.map(\.id) == ["A"])
        #expect(e.drawingsRevision == rev + 1)
        #expect(e.redoDrawing() == true)
        #expect(e.drawings.map(\.id) == [])
    }

    @Test("N-M 改样式：做 → ↩ 回到旧样式 → ↪ 回到新样式")
    func roundTripStyle() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        var s = DrawingDefaultStyle(); s.thickness = 3
        #expect(e.updateDrawingStyle(id: "A", style: s) == true)
        #expect(e.undoDrawing() == true)
        #expect(e.drawings[0].thickness == 1)
        #expect(e.drawings[0].id == "A", "身份不能变（`DrawingObject.==` 排除 id，必须单独断言）")
        #expect(e.redoDrawing() == true)
        #expect(e.drawings[0].thickness == 3)
    }

    @Test("N-M 锁定：做 → ↩ 回到未锁 → ↪ 回到锁定")
    func roundTripLock() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        #expect(e.setDrawingLocked(id: "A", locked: true) == true)
        #expect(e.undoDrawing() == true)
        #expect(e.drawings[0].locked == false)
        #expect(e.redoDrawing() == true)
        #expect(e.drawings[0].locked == true)
    }

    // ── N-I 保序（D25 / codex R25-high 专项，不可省） ──

    @Test("N-I 保序：删中间那条 → ↩ 必须回到**原下标**，且同价位单击选中的仍是最后画的 C")
    func undoRestoresExactIndexAndZOrder() {
        let e = Self.engine()
        // 同一价位依次画三条**重合**的线 A→B→C（数组序 [A,B,C] = z-order）
        for id in ["A", "B", "C"] {
            #expect(e.appendDrawing(Self.line(id, e, price: 50)) == true)
        }
        #expect(e.deleteDrawing(id: "B") == true)
        #expect(e.drawings.map(\.id) == ["A", "C"])
        #expect(e.undoDrawing() == true)
        // ① 数组**恰为** [A,B,C]：B 回到**下标 1**，不是末尾
        #expect(e.drawings.map(\.id) == ["A", "B", "C"],
                "只断言「B 回来了 / 条数是 3」的话，append 实现也能过 —— 必须断言精确序列")
        // ② 在该价位单击，命中的仍是 C（数组序 = z-order 的用户可见后果）
        let m = DrawingPanelStyleSemanticsTests.mapper()
        let p = CGPoint(x: 50, y: m.priceToY(50))
        let tools: [DrawingToolType: any DrawingTool] = [.horizontal: HorizontalLineTool()]
        #expect(DrawingHitTester.firstHit(in: e.drawings, point: p, mapper: m, tools: tools)?.id == "C",
                "撤销之后单击选中的必须仍是最后画的 C，不是刚撤回来的 B")
        // ↪ 之后数组恰为 [A,C]
        #expect(e.redoDrawing() == true)
        #expect(e.drawings.map(\.id) == ["A", "C"])
    }

    // ── N-J redo 不漂移（codex R29-high 专项，改样式 + 锁定各一条） ──

    @Test("N-J redo 不漂移（改样式）：↩ 后改动别处 → ↪ 必须回到 after 快照，不是当前默认")
    func redoUsesAfterSnapshotNotCurrentDefault() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e, price: 50)) == true)
        #expect(e.appendDrawing(Self.line("Z", e, price: 80, candleIndex: 2)) == true)
        var red = DrawingDefaultStyle(); red.colorToken = .red
        #expect(e.updateDrawingStyle(id: "A", style: red) == true)     // A 改成红
        #expect(e.undoDrawing() == true)
        // 中途改动别处：把**本局默认**改成绿，并选中别的线
        var green = DrawingDefaultStyle(); green.colorToken = .green
        e.drawingSession.setDefaultStyle(green)
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "Z", panel: .upper)
        #expect(e.redoDrawing() == true)
        #expect(e.drawings.first { $0.id == "A" }?.colorToken == .red,
                "redo 必须用 after 快照 —— 不是绿（当前默认）、也不是原色")
    }

    @Test("N-J redo 不漂移（锁定）：↩ 后改动别处 → ↪ 必须回到锁定态")
    func redoLockUsesAfterSnapshot() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        #expect(e.setDrawingLocked(id: "A", locked: true) == true)
        #expect(e.undoDrawing() == true)
        var green = DrawingDefaultStyle(); green.colorToken = .green
        e.drawingSession.setDefaultStyle(green)
        #expect(e.redoDrawing() == true)
        #expect(e.drawings[0].locked == true)
    }

    // ── N-K 深度 1 / N-N 空栈 / N-N4 不入栈 ──

    @Test("N-K 深度 1：连点两次 ↩ 只回退一步；连点两次 ↪ 只前进一步")
    func depthOneBehaviour() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        #expect(e.appendDrawing(Self.line("B", e, price: 60, candleIndex: 1)) == true)
        #expect(e.undoDrawing() == true)
        #expect(e.drawings.map(\.id) == ["A"])
        let snapshot = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false, "深度 1：第二次 ↩ 无效果")
        expectDrawingsUnchanged(e, snapshot, revisionBefore: rev)
        #expect(e.redoDrawing() == true)
        let after = e.drawings, rev2 = e.drawingsRevision
        #expect(e.redoDrawing() == false, "第二次 ↪ 无效果")
        expectDrawingsUnchanged(e, after, revisionBefore: rev2)
    }

    @Test("N-N 空栈：undo / redo 返回 false、drawings 与 revision 均不动")
    func emptyStackIsNoop() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        e.toggleDrawingMode(); e.toggleDrawingMode()          // 清栈（进出一趟）
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        #expect(e.redoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("N-N4：undo / redo **自身不入栈** —— 栈顶仍是那次锁定，不是「撤销锁定」")
    func undoDoesNotPushItself() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        #expect(e.setDrawingLocked(id: "A", locked: true) == true)
        #expect(e.undoDrawing() == true)
        guard case .replaced(let before, let after, _) = e.drawingUndoEntryForTesting!.drawingsDelta else {
            Issue.record("栈顶不是 replaced —— 撤销把自己压进去了"); return
        }
        #expect(before.locked == false && after.locked == true,
                "栈顶必须还是**那次锁定**（false→true）。若撤销自己入了栈，这里会变成 true→false")
        #expect(e.drawingUndoEntryForTesting?.isUndone == true, "栈顶被标记为已撤销，而不是产生新栈项")
    }

    // ── N-O 复盘门 ──

    @Test("N-O：复盘模式下 undo / redo 恒 false（D34 纵深防御）")
    func reviewModeRejectsUndoRedo() {
        let e = TrainingEngine.preview(mode: .review)
        e.injectDrawingsForTesting([makeStyledHLine(id: "A")])
        e.injectDrawingUndoEntryForTesting(
            DrawingUndoEntry(drawingsDelta: .replaced(before: makeStyledHLine(id: "A"),
                                                      after: makeStyledHLine(id: "A", thickness: 3), at: 0),
                             isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        #expect(e.redoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }
}

@Suite("1b-ii 撤销：陈旧栈项 fail-closed（D79 第二层）")
@MainActor
struct DrawingUndoStaleEntryTests {

    /// 造「引擎里有一条线 A，但栈里那条记录对不上号」。
    static func engineWithStaleEntry(_ entry: DrawingUndoEntry) -> TrainingEngine {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.injectDrawingUndoEntryForTesting(entry)      // 覆盖掉刚才那条真记录
        return e
    }

    @Test("N-N2①：下标越界 → 返 false、**不崩**、数据与 revision 均不动、栈被作废")
    func outOfBoundsIndexFailsClosed() {
        // ⚠️ 这是**崩溃回归测试**：没有它，越界 trap 在测试里表现为整个 xctest 进程挂掉，
        //    而不是一条红断言，容易被误读成环境问题。
        let e = Self.engineWithStaleEntry(
            .init(drawingsDelta: .inserted(after: makeStyledHLine(id: "A"), at: 99), isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false, "fail-closed：整个栈必须作废")
    }

    @Test("N-N2②：下标在界内但 id 对不上 → false、**那条无辜的线逐字段不变**、栈被作废")
    func identityMismatchFailsClosed() {
        let e = Self.engineWithStaleEntry(
            .init(drawingsDelta: .replaced(before: makeStyledHLine(id: "GHOST"),
                                           after: makeStyledHLine(id: "GHOST", thickness: 3), at: 0),
                  isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        #expect(e.drawings[0].id == "A", "下标 0 上那条无辜的 A 不许被改写")
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false)
    }

    @Test("N-N2③：insert 时 id 已存在（重复 id）→ false、条数不变、栈被作废")
    func duplicateIdOnInsertFailsClosed() {
        let e = Self.engineWithStaleEntry(
            .init(drawingsDelta: .removed(before: makeStyledHLine(id: "A"), at: 0), isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false, "undo「删线」要 insert 一条 id=A 的线，但 A 已经在数组里（D66）")
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        #expect(e.drawings.count == 1)
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false)
    }

    // ── 修复轮 1：①②③ 按 case 枚举漏了「每个 case 两道门」里的另一道，各补一条只隔离单一门的测试 ──

    @Test("N-N2④：remove 分支（undo 画线 / redo 删线共用）身份门单独隔离 —— 下标在界内但 id 对不上")
    func removeBranchIdentityMismatchFailsClosed() {
        // ⚠️ 下标 0 在界内，越界门不会先触发 —— 这条才真的只测身份门（remove(at:) 那一支）。
        let e = Self.engineWithStaleEntry(
            .init(drawingsDelta: .inserted(after: makeStyledHLine(id: "GHOST"), at: 0), isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        #expect(e.drawings[0].id == "A", "下标 0 上那条无辜的 A 不许被删掉")
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false)
    }

    @Test("N-N2⑤：insert 分支（undo 删线 / redo 画线共用）越界门单独隔离 —— id 不存在，去重门不会先触发")
    func insertBranchOutOfBoundsFailsClosed() {
        // ⚠️ 这也是**崩溃回归测试**：insert(_:at:) 越界同样是 trap，不是红断言。
        //    故意用一个数组里不存在的 id（"Z"），这样「id 已存在」那道去重门不会先触发，隔离出的就是越界门。
        let e = Self.engineWithStaleEntry(
            .init(drawingsDelta: .removed(before: makeStyledHLine(id: "Z"), at: 99), isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        #expect(e.drawings.count == 1)
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false)
    }

    @Test("N-N2⑥：replaced 分支越界门单独隔离 —— 下标越界，不涉及任何身份判断")
    func replacedBranchOutOfBoundsFailsClosed() {
        // ⚠️ 崩溃回归测试：`drawings[index] = target` 越界同样是 trap，不是红断言。
        let e = Self.engineWithStaleEntry(
            .init(drawingsDelta: .replaced(before: makeStyledHLine(id: "A"),
                                           after: makeStyledHLine(id: "A", thickness: 3), at: 99),
                  isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false)
    }

    // ── N-N3：绕过栈的写入面必须**作废**栈（D79 第一层，根因）──
    // ⚠️ 必须在**同一个引擎实例**上做。spec 原稿用 `resumePendingReplay` 举证是错的：
    //    那条路径走 `TrainingEngine.make(...)` 造的是**全新引擎**，新引擎的栈本来就是空的
    //    → 测试恒过、证明不了任何事（codex R2-F1）。

    @Test("N-N3a：injectDrawingsForTesting 换一批线 → 撤销栈必须作废")
    func injectDrawingsInvalidatesStack() {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        #expect(e.canUndoDrawing == true, "前置：栈非空")
        e.injectDrawingsForTesting([makeStyledHLine(id: "X"), makeStyledHLine(id: "Y", candleIndex: 4)])
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false, "栈必须已作废")
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("N-N3b：deleteDrawing(at:)（零生产调用点、但会移位下标）→ 撤销栈必须作废")
    func deleteByIndexInvalidatesStack() {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "B", revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 1, price: 60)) == true)
        #expect(e.canUndoDrawing == true)
        e.deleteDrawing(at: 0)                       // 把 B 的下标从 1 移到了 0 —— 栈里那条记录当场失准
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false, "栈必须已作废")
    }
}

@Suite("1b-ii 撤销：画线态改样式的成对回滚（D102 + 自动选中 spec §10.1）")
@MainActor
struct DrawingUndoPairedRollbackTests {

    /// 「画线态 + 上面板一条已选中的线 + mapper 已发布」。直接复用自动选中片的搭台函数
    /// （同一个测试模块，internal 可达）—— 另抄一份必然与它漂移。
    static func drawModeEngine(locked: Bool = false) -> TrainingEngine {
        DrawingPanelStyleSemanticsTests.drawModeWithSelected(
            id: "A", locked: locked, colorToken: .orange, thickness: 1)
    }

    // ── ⭐ 交接 §10.1 点名的**必配回归**：一并回滚、一并重做 ──

    @Test("⭐成对回滚：画线态改样式 → ↩ → 线与本局默认**双双**回到改动前")
    func undoRollsBackBothLineAndSessionDefault() {
        let e = Self.drawModeEngine()
        #expect(e.drawings[0].thickness == 1)
        #expect(e.drawingSession.defaultStyle.thickness == 1, "前置：默认与线都是 1")

        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        #expect(e.drawings[0].thickness == 3, "前置：那条线真的被改了")
        #expect(e.drawingSession.defaultStyle.thickness == 3, "前置：本局默认也真的被改了（两处写入）")

        #expect(e.undoDrawing() == true)
        #expect(e.drawings[0].thickness == 1, "线必须回到改动前")
        #expect(e.drawingSession.defaultStyle.thickness == 1,
                """
                本局默认也必须回到改动前。
                只回滚线不回滚默认 ⇒ 被撤销掉的样式会在**下一笔新画的线**上复活，
                而且经 autosave 落盘、断点续训之后还在（自动选中 spec §10.1 逐字）。
                """)
    }

    @Test("⭐成对重做：↪ → 线与本局默认**双双**回到改动后")
    func redoRestoresBothLineAndSessionDefault() {
        let e = Self.drawModeEngine()
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        #expect(e.undoDrawing() == true)
        #expect(e.redoDrawing() == true)
        #expect(e.drawings[0].thickness == 3)
        #expect(e.drawingSession.defaultStyle.thickness == 3)
    }

    @Test("⭐成对：两处写入只产生**一条**栈记录（深度 1 下第二条会把第一条挤掉 = 交接点名的坏结果）")
    func pairProducesExactlyOneEntry() {
        let e = Self.drawModeEngine()
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        guard case .replaced(let before, let after, _) = e.drawingUndoEntryForTesting!.drawingsDelta else {
            Issue.record("栈顶不是 replaced"); return
        }
        #expect(before.thickness == 1 && after.thickness == 3, "drawings 那一半必须是这次改动本身")
        #expect(e.drawingUndoEntryForTesting?.defaultDelta?.before.thickness == 1)
        #expect(e.drawingUndoEntryForTesting?.defaultDelta?.after.thickness == 3)
        // 深度 1：只有一条 → 撤销一次就回到起点，再撤无效
        #expect(e.undoDrawing() == true)
        #expect(e.undoDrawing() == false, "两处写入若各入一条，这里会是 true —— 那正是要防的")
    }

    // ── D101：只改默认、没碰线 → 不入栈（含已接受残留的正面证据） ──

    @Test("D101：画线态那条线被锁 → 只有默认变了 → **不入栈**，栈顶保持原样（已接受残留）")
    func lockedLineMeansDefaultOnlyChangeIsNotPushed() {
        let e = Self.drawModeEngine(locked: true)
        // 先造一条真记录（锁定动作本身可撤销）
        #expect(e.drawingSession.selectedDrawingID == "A")
        let topBefore = e.drawingUndoEntryForTesting?.drawingsDelta

        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        #expect(e.drawingSession.defaultStyle.thickness == 3, "默认确实变了")
        #expect(e.drawings[0].thickness == 1, "线锁着，applyStyle 被 D60 拒 —— 没被改")

        let topAfter = e.drawingUndoEntryForTesting?.drawingsDelta
        #expect((topBefore == nil) == (topAfter == nil), "栈顶存在性不得改变")
        #expect(e.drawingUndoEntryForTesting?.defaultDelta == nil,
                "只改默认不入栈（D101）：栈顶不许多出一个 defaultDelta")
    }

    // ── ⭐ 落盘往返：成对回滚必须**作为同一份状态**存下去、再一起读回来（codex plan-R9）──

    @Test("⭐落盘往返（undo）：画线态改样式 → ↩ → 存档 → 续局 → 线与本局默认**双双**是改动前那一侧")
    func pairedUndoSurvivesSaveAndResume() async throws {
        let (coord, _, _, _) = TrainingSessionPersistenceTests.makeCoordinator(
            candles: TrainingSessionPersistenceTests.validCandles())
        coord.now = { 222 }
        let e = try await coord.startNewNormalSession()
        e.toggleDrawingMode()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", thickness: 1, revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 10)) == true)
        e.drawingSession.setCommittedSelection(id: "A", panel: .upper)
        e.drawingSession.setViewportMapper(DrawingPanelStyleSemanticsTests.mapper(), panel: .upper)

        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        #expect(e.drawings[0].thickness == 3 && e.drawingSession.defaultStyle.thickness == 3)
        #expect(e.undoDrawing() == true)

        try await coord.saveProgress(engine: e)
        await coord.endSession()
        let resumed = try #require(try await coord.resumePending())

        // ⭐ 两半必须落在**同一侧**。只测 revision +1 证明不了这一条：
        //    autosave 的排序 / 合并一旦出问题，完全可能把「已回滚的线」和「没回滚的默认」一起存下去，
        //    于是被撤销掉的样式在续训之后、在下一笔新画的线上复活 —— 正是 D102 要防的那个高代价形态。
        #expect(resumed.drawings.first { $0.id == "A" }?.thickness == 1, "线必须是改动前那一侧")
        #expect(resumed.drawingSession.defaultStyle.thickness == 1, "本局默认必须**同样**是改动前那一侧")
        // 顺带钉住验收 #17：撤销栈不跨局（新引擎的栈按定义为空）
        #expect(resumed.canUndoDrawing == false && resumed.canRedoDrawing == false)
    }

    @Test("⭐落盘往返（redo）：↩ 后再 ↪ → 存档 → 续局 → 线与本局默认**双双**是改动后那一侧")
    func pairedRedoSurvivesSaveAndResume() async throws {
        let (coord, _, _, _) = TrainingSessionPersistenceTests.makeCoordinator(
            candles: TrainingSessionPersistenceTests.validCandles())
        coord.now = { 222 }
        let e = try await coord.startNewNormalSession()
        e.toggleDrawingMode()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", thickness: 1, revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 10)) == true)
        e.drawingSession.setCommittedSelection(id: "A", panel: .upper)
        e.drawingSession.setViewportMapper(DrawingPanelStyleSemanticsTests.mapper(), panel: .upper)

        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        #expect(e.undoDrawing() == true)
        #expect(e.redoDrawing() == true)

        try await coord.saveProgress(engine: e)
        await coord.endSession()
        let resumed = try #require(try await coord.resumePending())
        #expect(resumed.drawings.first { $0.id == "A" }?.thickness == 3, "线必须是改动后那一侧")
        #expect(resumed.drawingSession.defaultStyle.thickness == 3, "本局默认必须**同样**是改动后那一侧")
    }

    // ── ⭐ D101 不变量：默认分量过期必须丢掉（codex plan-R3 high）──
    //    两个方向各一条 —— codex 只报了 ↪ 那一半，↩ 同样会覆盖用户的新默认。

    @Test("⭐R3-↪ 方向：旧记录已撤销 + 用户又单独改了默认 → ↪ 不得覆盖新默认")
    func staleDefaultDeltaDoesNotClobberOnRedo() {
        let e = Self.drawModeEngine()
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)   // 成对入栈
        #expect(e.undoDrawing() == true)                                             // ↪ 可用
        #expect(e.canRedoDrawing == true)
        #expect(e.drawingSession.defaultStyle.thickness == 1)

        // 让那条线不再够得着（几何判不了），**但不结束会话** → 栈按 N-Q3 原样保留
        e.drawingSession.clearViewportMapper(panel: .upper)
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 5 }, engine: e)   // 只改默认
        #expect(e.drawingSession.defaultStyle.thickness == 5, "前置：默认真的变成 5 了")
        #expect(e.drawings[0].thickness == 1, "前置：那条线被几何门拒了，没被改")
        #expect(e.drawingUndoEntryForTesting?.defaultDelta == nil,
                "过期的默认分量必须被丢掉 —— 留着它 ↪ 就会拿旧值覆盖用户刚选的 5")

        #expect(e.redoDrawing() == true)
        #expect(e.drawings[0].thickness == 3, "线那一半仍然有效，↪ 照常把它重做回去")
        #expect(e.drawingSession.defaultStyle.thickness == 5,
                "⭐用户刚选的默认 5 必须原样保留 —— 被旧记录的 after 覆盖成 3 就是本条要防的缺陷")
    }

    @Test("⭐R3-↩ 方向（codex 未报，复核补出）：记录尚未撤销 + 用户又单独改了默认 → ↩ 不得覆盖新默认")
    func staleDefaultDeltaDoesNotClobberOnUndo() {
        let e = Self.drawModeEngine()
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)   // 成对入栈，未撤销
        e.drawingSession.clearViewportMapper(panel: .upper)
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 5 }, engine: e)   // 只改默认
        #expect(e.drawingSession.defaultStyle.thickness == 5)
        #expect(e.drawingUndoEntryForTesting?.defaultDelta == nil, "过期的默认分量必须被丢掉")

        #expect(e.undoDrawing() == true)
        #expect(e.drawings[0].thickness == 1, "线那一半仍然有效，↩ 照常把它退回去")
        #expect(e.drawingSession.defaultStyle.thickness == 5,
                "⭐用户刚选的默认 5 必须原样保留 —— 被旧记录的 before 覆盖成 1 就是本条要防的缺陷")
    }

    @Test("D101：选择态改样式只写线、不写默认 → 栈记录里 defaultDelta 必须是 nil")
    func selectModeEditHasNoDefaultDelta() {
        let e = DrawingPanelStyleSemanticsTests.selectModeWithSelected(id: "A", colorToken: .orange)
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        #expect(e.drawings[0].thickness == 3)
        #expect(e.drawingUndoEntryForTesting?.defaultDelta == nil,
                "选择态本来就不回写默认（D49 的核心价值）→ 这条记录不该带默认分量")
        #expect(e.undoDrawing() == true)
        #expect(e.drawings[0].thickness == 1)
    }

    @Test("N-R（D80 的 PR-2 侧）：画线态 no-op 点击不冲掉栈顶那次真编辑，↩ 仍回到最初")
    func noopClickInDrawModeDoesNotClobber() {
        let e = Self.drawModeEngine()
        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)   // 真编辑
        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)   // 同一个颜色再点一次
        #expect(e.undoDrawing() == true)
        #expect(e.drawings[0].colorToken == .orange, "必须回到**最初**那个色，不是回到紫")
        #expect(e.drawingSession.defaultStyle.colorToken == .orange, "默认也一并回到最初")
    }
}

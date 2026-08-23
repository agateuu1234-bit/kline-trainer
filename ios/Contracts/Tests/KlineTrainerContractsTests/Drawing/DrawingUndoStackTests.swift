// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoStackTests.swift
// Spec: docs/superpowers/specs/2026-08-11-drawing-tools-P1b-1b-ii-lock-undo-design.md §2
// 计划新增决策：D101（入栈条件）/ D102（一次动作作用域）/ D103（清栈绑真翻转）
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
        let e = Self.drawingModeWithNonEmptyStack()
        let topBefore = e.drawingUndoEntryForTesting?.isUndone
        e.switchPeriodCombo(direction: .toLarger)   // PeriodDirection 只有 .toLarger / .toSmaller
        #expect(e.drawingSession.drawingModeActive == true,
                "切周期后必须仍在画线模式（restoreDrawingSessionAfterPeriodChange 刻意保留会话）")
        #expect(e.canUndoDrawing == true, "同一个会话没结束 → 撤销记录必须留着")
        #expect(e.drawingUndoEntryForTesting?.isUndone == topBefore, "栈内容不得被动过")
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

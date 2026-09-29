// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/NodeDragPreconditionsTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D134 前置条件 / D134b / D134e / N6 / T13）
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 探针前置条件（D134e）")
struct NodeDragPreconditionsTests {

    /// ⭐ 每一档的形状固定为「先证明放行 → 制造该档成因 → 证明被拒 → 撤掉成因 → 再证明放行」
    /// ⛔ 只断言 false 会被「恒 false」的实现骗过。

    /// 造「画线会话已开 + 处于选择态 + 上/下面板选中一条本面板周期的直线」——
    /// `nodeDragPreconditions` 不含几何分量，故不需要 mapper（与 DrawingEditRouterTests.makeSelected 的
    /// 差别正在这里）。`revealTick: 0` 理由同 DrawingEditRouterTests：`TrainingEngine.preview()` 的
    /// `tick.globalTickIndex` 恒为 0，`makeStyledHLine` 默认 `revealTick: 7` 会让线恒判「未揭示」。
    static func baseline(id: String = "A", panel: PanelId = .upper) -> TrainingEngine {
        let e = TrainingEngine.preview()
        let period = panel == .upper ? e.upperPanel.period : e.lowerPanel.period
        e.injectDrawingsForTesting([makeStyledHLine(id: id, revealTick: 0, period: period,
                                                    candleIndex: 0, price: 10)])
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: id, panel: panel)
        return e
    }

    /// 同上，但引擎携带一份 raw-aware 的 `loadedDrawingsLossy`（未来数据两档要用）。
    /// upper/lower 周期都是 `.m3`（`makeEngineWithLossy` 的既有构造），故 belongsToPanel 走
    /// 「同周期 fail-safe」分支，靠 `panelPosition == 0` 归 `.upper`（raw fixture 里 panelPosition 恰为 0）。
    static func selectedLossyEngine(raw: String, id: String, panel: PanelId = .upper) throws -> TrainingEngine {
        let e = makeEngineWithLossy(try lossyFromRaw(raw))
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: id, panel: panel)
        return e
    }

    // ③a/③b 未来数据 raw fixture —— 逐字照抄 UpdateDrawingAnchorTests 的同款字符串
    // （该文件里的常量是 private，故在本文件重写一份，字段内容与来源一致）。
    private let futureEnumRaw = #"{"id":"F","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"futureNeon","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"futureCyan","textForm":"plain"}"#
    private let plainSameIdEnumRaw = #"{"id":"F","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#

    private let futureFieldRaw = #"{"id":"X","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","futureIndependentTextColor":true}"#
    private let plainSameIdFieldRaw = #"{"id":"X","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#

    @Test("N6 六档：引擎能判的非几何拒收门，探针必须**先**答「没有」")
    func allNonGeometricGatesRejectAtProbe() throws {
        // 六档：locked / 未来顶层字段 / 未来枚举值 / 全局 id 重复(一可见一隐藏) / 不可编辑工具 / 复盘
        // 每档都断言：① 成因加上之前 nodeDragPreconditions == true
        //           ② 加上之后 == false
        //           ③ 撤掉之后 == true
        let point = CGPoint(x: 0, y: 0)

        // ── ① locked ──
        do {
            let e = Self.baseline(id: "A", panel: .upper)
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: point) == true)
            #expect(e.setDrawingLocked(id: "A", locked: true) == true)
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: point) == false)
            #expect(e.setDrawingLocked(id: "A", locked: false) == true)
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: point) == true)
        }

        // ── ② 未来顶层字段 ──
        do {
            let plain = try Self.selectedLossyEngine(raw: plainSameIdFieldRaw, id: "X")
            #expect(plain.loadedDrawingsLossy.hasKnownFutureFields(liveIds: ["X"]) == false)
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: plain, panel: .upper, point: point) == true)

            let future = try Self.selectedLossyEngine(raw: futureFieldRaw, id: "X")
            #expect(future.loadedDrawingsLossy.hasKnownFutureFields(liveIds: ["X"]) == true)   // 前提成立
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: future, panel: .upper, point: point) == false)

            let plainAgain = try Self.selectedLossyEngine(raw: plainSameIdFieldRaw, id: "X")
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: plainAgain, panel: .upper, point: point) == true)
        }

        // ── ③ 未来枚举值 ──
        do {
            let plain = try Self.selectedLossyEngine(raw: plainSameIdEnumRaw, id: "F")
            #expect(plain.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: ["F"]) == false)
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: plain, panel: .upper, point: point) == true)

            let future = try Self.selectedLossyEngine(raw: futureEnumRaw, id: "F")
            #expect(future.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: ["F"]) == true)   // 前提成立
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: future, panel: .upper, point: point) == false)

            let plainAgain = try Self.selectedLossyEngine(raw: plainSameIdEnumRaw, id: "F")
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: plainAgain, panel: .upper, point: point) == true)
        }

        // ── ④ 全局 id 重复（一可见一隐藏）──
        // ⚠️ 隐藏那条必须 period 不同（结构性不可见）：两条同 id 同周期会让 `uniqueSelected` 也一起判失败，
        //   该档就失去判别力（简报明写）。
        do {
            let e = Self.baseline(id: "A", panel: .upper)   // 线 period == e.upperPanel.period（.m60）
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: point) == true)

            let visible = e.drawings[0]
            let hiddenDuplicate = makeStyledHLine(id: "A", revealTick: 0, period: .m3, candleIndex: 0, price: 10)
            #expect(hiddenDuplicate.period != e.upperPanel.period)
            e.injectDrawingsForTesting([visible, hiddenDuplicate])
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: point) == false)

            e.injectDrawingsForTesting([visible])
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: point) == true)
        }

        // ── ⑤ 不可编辑工具 ──
        do {
            let e = Self.baseline(id: "A", panel: .upper)
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: point) == true)

            let period = e.upperPanel.period
            let trend = DrawingObject(id: "A", toolType: .trend,
                                      anchors: [DrawingAnchor(period: period, candleIndex: 0, price: 10)],
                                      isExtended: false, panelPosition: 0, period: period)
            #expect(DrawingStyleAvailability.isEditableToolType(trend.toolType) == false)
            e.injectDrawingsForTesting([trend])
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: point) == false)

            e.injectDrawingsForTesting([makeStyledHLine(id: "A", revealTick: 0, period: period,
                                                        candleIndex: 0, price: 10)])
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: point) == true)
        }

        // ── ⑥ 复盘 ──
        // `flow.mode` 不可写（各 TrainingFlowController 具体实现在 init 时定型），撤/加成因经
        // `TrainingEngine.preview(mode:)` 两次独立构造表达——同一套 baseline 步骤，只换 mode 参数。
        do {
            let normal = TrainingEngine.preview(mode: .normal)
            normal.injectDrawingsForTesting([makeStyledHLine(id: "A", revealTick: 0,
                                                              period: normal.upperPanel.period,
                                                              candleIndex: 0, price: 10)])
            normal.toggleDrawingMode()
            normal.drawingSession.setMode(.select)
            normal.drawingSession.setSelection(id: "A", panel: .upper)
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: normal, panel: .upper, point: point) == true)

            let review = TrainingEngine.preview(mode: .review)
            review.injectDrawingsForTesting([makeStyledHLine(id: "A", revealTick: 0,
                                                             period: review.upperPanel.period,
                                                             candleIndex: 0, price: 10)])
            review.toggleDrawingMode()
            review.drawingSession.setMode(.select)
            review.drawingSession.setSelection(id: "A", panel: .upper)
            #expect(review.flow.mode == .review)   // 前提成立
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: review, panel: .upper, point: point) == false)

            let normalAgain = TrainingEngine.preview(mode: .normal)
            normalAgain.injectDrawingsForTesting([makeStyledHLine(id: "A", revealTick: 0,
                                                                   period: normalAgain.upperPanel.period,
                                                                   candleIndex: 0, price: 10)])
            normalAgain.toggleDrawingMode()
            normalAgain.drawingSession.setMode(.select)
            normalAgain.drawingSession.setSelection(id: "A", panel: .upper)
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: normalAgain, panel: .upper, point: point) == true)
        }
    }

    @Test("T13 探针路径三档：盾 .pending 拒 / .rect 区内拒 / .rect 区外放行")
    func shieldThreeCases() throws {
        // ⭐ 三档缺一不可：少了「区外放行」，「恒拒」会全绿
        let e = Self.baseline(id: "A", panel: .upper)
        let insidePoint = CGPoint(x: 5, y: 5)
        let outsidePoint = CGPoint(x: 500, y: 500)
        let rect = CGRect(x: 0, y: 0, width: 50, height: 50)

        // 放行基线：默认无盾（`shield` 字典无 key ⇒ `.unshielded`）
        #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: insidePoint) == true)

        // 档 A：`.pending` —— 拒收一切，与点无关
        e.drawingSession.setShield(.pending, panel: .upper)
        #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: insidePoint) == false)
        #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: outsidePoint) == false)

        // 档 B：`.rect`，点落在区内 —— 拒
        e.drawingSession.setShield(.rect(rect), panel: .upper)
        #expect(rect.contains(insidePoint))
        #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: insidePoint) == false)

        // 档 C：同一个 `.rect`，点落在区外 —— 放行（少了这一档，「恒拒」实现会让 A/B 两档也全绿）
        #expect(!rect.contains(outsidePoint))
        #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: outsidePoint) == true)

        // 撤掉盾 —— 恢复放行，呼应三段式收尾
        e.drawingSession.setShield(.unshielded, panel: .upper)
        #expect(DrawingEditRouter.nodeDragPreconditions(engine: e, panel: .upper, point: insidePoint) == true)
    }
}

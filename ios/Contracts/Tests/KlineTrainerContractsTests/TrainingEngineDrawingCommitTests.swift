// Wave 3 顺位 4：engine 画线 FSM 退出（commitDrawing/cancelDrawing）。
// 复用 TrainingEngineInteractionTests.engine()（单 .m3 双面板 + fake 驱动）。
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingEngine drawing commit/cancel（FSM 退出，Wave 3 顺位 4）")
struct TrainingEngineDrawingCommitTests {

    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// 进入 .drawing 的 engine（activateDrawingTool 已验证进 drawing）。
    static func drawingEngine() -> TrainingEngine {
        let (e, _) = TrainingEngineInteractionTests.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.activateDrawingTool(.horizontal, panel: .upper)
        return e
    }

    @Test("commitDrawing: .drawing → .autoTracking + revision 不变（核 Reducer:203-208 不 bump）")
    func commitExitsToAutoTrackingNoRevisionBump() {
        let e = Self.drawingEngine()
        guard case .drawing = e.upperPanel.interactionMode else { Issue.record("应在 drawing"); return }
        let revBefore = e.upperPanel.revision
        e.commitDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.revision == revBefore)             // commit 不 bump revision
    }

    @Test("cancelDrawing: .drawing → .autoTracking + revision 不变")
    func cancelExitsToAutoTrackingNoRevisionBump() {
        let e = Self.drawingEngine()
        let revBefore = e.upperPanel.revision
        e.cancelDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.revision == revBefore)
    }

    @Test("commitDrawing: 非 drawing 态 → no-op（autoTracking 不变）")
    func commitNonDrawingNoOp() {
        let (e, _) = TrainingEngineInteractionTests.engine()        // autoTracking
        let revBefore = e.upperPanel.revision
        e.commitDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.revision == revBefore)
    }

    @Test("cancelDrawing: 非 drawing 态 → no-op")
    func cancelNonDrawingNoOp() {
        let (e, _) = TrainingEngineInteractionTests.engine()
        e.cancelDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
    }

    @Test("append 与 commit 独立：appendDrawing 不改 mode；commitDrawing 不改 drawings")
    func appendAndCommitAreIndependent() {
        let e = Self.drawingEngine()
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: 10.4)],
                              isExtended: true, panelPosition: 0)
        e.appendDrawing(d)
        #expect({ if case .drawing = e.upperPanel.interactionMode { return true }; return false }())  // append 不改 mode
        #expect(e.drawings == [d])
        e.commitDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.drawings == [d])                                 // commit 不改 drawings
    }

    // MARK: - review-redesign Task 10：routeDrawingCommit（review→reviewDrawings / else→drawings）

    /// review 模式 engine（复用 TrainingEngineActionsTests.m3Candles，同其余 helper 风格）。
    static func reviewEngine(closes: [Double] = Array(repeating: 10, count: 100)) -> TrainingEngine {
        let maxTick = closes.count - 1
        let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        let record = TrainingRecord(id: 1, trainingSetFilename: "t.sqlite", createdAt: 0,
                                    stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 1,
                                    totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                                    buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: maxTick)
        return TrainingEngine(
            flow: ReviewFlow(record: record, startTick: 0),
            allCandles: TrainingEngineActionsTests.m3Candles(closes),
            maxTick: maxTick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3)
    }

    @Test("routeDrawingCommit: review 模式写 reviewDrawings，engine.drawings 不变（关键不变量：不污染原训练记录）")
    func routeDrawingCommitReviewGoesToReviewDrawings() {
        let e = Self.reviewEngine()
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: 10.4)],
                              isExtended: true, panelPosition: 0)
        let drawingsCountBefore = e.drawings.count
        e.routeDrawingCommit(d)
        #expect(e.drawings.count == drawingsCountBefore)   // 不得写入 engine.drawings（不污染原训练记录）
        #expect(e.reviewDrawings == [d])
    }

    @Test("routeDrawingCommit: 非 review（normal）模式写 drawings，engine.reviewDrawings 不变")
    func routeDrawingCommitNormalGoesToDrawings() {
        let (e, _) = TrainingEngineInteractionTests.engine()
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: 10.4)],
                              isExtended: true, panelPosition: 0)
        let reviewCountBefore = e.reviewDrawings.count
        e.routeDrawingCommit(d)
        #expect(e.drawings == [d])
        #expect(e.reviewDrawings.count == reviewCountBefore)
    }

    @Test("removeReviewDrawing: 按 index 从 engine.reviewDrawings 删除（deleteDrawing 的复盘对应版本）")
    func removeReviewDrawingRemovesByIndex() {
        let e = Self.reviewEngine()
        let d0 = DrawingObject(toolType: .trend, anchors: [], isExtended: false, panelPosition: 0)
        let d1 = DrawingObject(toolType: .ray, anchors: [], isExtended: false, panelPosition: 0)
        e.appendReviewDrawing(d0)
        e.appendReviewDrawing(d1)
        e.removeReviewDrawing(at: 0)
        #expect(e.reviewDrawings.count == 1)
        #expect(e.reviewDrawings[0].toolType == .ray)
        #expect(e.drawings.isEmpty)   // 全程未碰 engine.drawings
    }

    // MARK: - review-redesign Task 3：routeDrawingCommit 提交时盖戳 revealTick=当前全局 tick

    /// normal engine 步进到指定 tick（复用 `TrainingEngineInteractionTests.engine()`）。
    static func makeNormalEngineAtTick(_ target: Int) -> TrainingEngine {
        let (e, _) = TrainingEngineInteractionTests.engine()
        for _ in 0..<target { e.holdOrObserve(panel: .upper) }
        return e
    }

    /// review engine 步进到指定 tick（复用本文件 `reviewEngine()`；ReviewFlow.canAdvance()==true 可步进）。
    static func makeReviewEngineAtTick(_ target: Int) -> TrainingEngine {
        let e = Self.reviewEngine()
        for _ in 0..<target { e.holdOrObserve(panel: .upper) }
        return e
    }

    @Test("routeDrawingCommit: normal 模式提交时盖戳 revealTick = 当前全局 tick")
    func routeDrawingCommit_stampsRevealTick_normalMode() {
        let engine = Self.makeNormalEngineAtTick(50)
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m3, candleIndex: 3, price: 10)],
                              isExtended: false, panelPosition: 0)   // revealTick 默认 0
        engine.routeDrawingCommit(d)
        #expect(engine.drawings.last?.revealTick == engine.tick.globalTickIndex)
        #expect(engine.drawings.last?.revealTick == 50)
    }

    @Test("routeDrawingCommit: review 模式提交时盖戳 revealTick = 当前全局 tick，不污染 engine.drawings")
    func routeDrawingCommit_stampsRevealTick_reviewMode() {
        let engine = Self.makeReviewEngineAtTick(60)
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m3, candleIndex: 3, price: 10)],
                              isExtended: false, panelPosition: 0)
        engine.routeDrawingCommit(d)
        #expect(engine.reviewDrawings.last?.revealTick == 60)
        #expect(engine.drawings.isEmpty)   // review commit 不污染训练层
    }
}

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

    /// 进入 .drawing 的 engine（armPanelForDrawing 已验证进 drawing）。
    /// 用 armPanelForDrawing（原始单面板原语）而非公共 activateDrawingTool：后者本期起等价于
    /// beginDrawingSession（会置 drawingSession.drawingModeActive == true），会让下面测的
    /// commitDrawing/cancelDrawing 撞上其生产期 fail-closed 守卫直接 no-op，测不到 FSM 本体。
    static func drawingEngine() -> TrainingEngine {
        let (e, _) = TrainingEngineInteractionTests.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.armPanelForDrawing(.horizontal, panel: .upper)
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

    // MARK: - 画线工具扩充 P1a Task 8：routeDrawingCommit 全字段 copy-with-revealTick（D15）

    @Test("routeDrawingCommit 保留 id/样式/锁定/文本/tailAnchor，仅盖 revealTick（normal 模式）")
    func routePreservesAllFields() {
        let e = Self.makeNormalEngineAtTick(50)   // normal flow，tick 在窗口内
        let anchor = DrawingAnchor(period: .m60, candleIndex: 3, price: 1710.0)
        let d = DrawingObject(
            id: "gen-keep", toolType: .trend, anchors: [anchor, anchor],
            isExtended: true, panelPosition: 1, revealTick: 0,
            // Task 5（D67）：appendDrawing 新增 .segment 恒不可渲染门，与本测试要测的字段透传无关——
            // 换成同样非默认值的 .ray，不改变「全字段原样透传」这个测试意图。
            period: .m60, lineSubType: .ray, lineStyle: .dash3, thickness: 5,
            colorToken: .purple, labelMode: .right, locked: true,
            text: "标注文本", fontSize: 22, textColorToken: .green, textForm: .borderFilled,
            tailAnchor: anchor)
        e.routeDrawingCommit(d)
        let stored = e.drawings.last!
        #expect(stored.id == "gen-keep")
        #expect(stored.toolType == .trend)
        #expect(stored.lineSubType == .ray)
        #expect(stored.lineStyle == .dash3)
        #expect(stored.thickness == 5)
        #expect(stored.colorToken == .purple)
        #expect(stored.labelMode == .right)
        #expect(stored.locked == true)
        #expect(stored.text == "标注文本")
        #expect(stored.textForm == .borderFilled)
        #expect(stored.tailAnchor == anchor)
        #expect(stored.revealTick == e.tick.globalTickIndex)   // revealTick 被盖成当前 tick
    }

    @Test("routeDrawingCommit 不静默丢非水平 .segment（codex WB re-attest R1：横 .segment 门此前误管 .trend→routeDrawingCommit 吞返回值→丢线）")
    func routeDoesNotDropNonHorizontalSegment() {
        let e = Self.makeNormalEngineAtTick(50)   // normal flow → 写 drawings
        let anchor = DrawingAnchor(period: .m60, candleIndex: 3, price: 1710.0)
        let d = DrawingObject(
            id: "trend-seg", toolType: .trend, anchors: [anchor, anchor],
            isExtended: true, panelPosition: 1, revealTick: 0,
            period: .m60, lineSubType: .segment,     // .trend 的 .segment 合法（非水平横规则不适用）
            thickness: 3, text: "")
        e.routeDrawingCommit(d)
        #expect(e.drawings.last?.id == "trend-seg")            // 落库、未被静默丢
        #expect(e.drawings.last?.lineSubType == .segment)      // 子类原样保留
    }

    @Test("routeDrawingCommit 保留全字段（review 模式，写入 reviewDrawings 不污染 drawings）")
    func routePreservesAllFieldsReviewMode() {
        let e = Self.makeReviewEngineAtTick(60)
        let anchor = DrawingAnchor(period: .m60, candleIndex: 3, price: 1710.0)
        let d = DrawingObject(
            id: "gen-keep-review", toolType: .channel, anchors: [anchor, anchor],
            isExtended: false, panelPosition: 0, revealTick: 0,
            period: .m60, lineSubType: .ray, lineStyle: .dash2, thickness: 3,
            colorToken: .cyan, labelMode: .left, locked: true,
            text: "复盘标注", fontSize: 18, textColorToken: .red, textForm: .borderTransparent,
            tailAnchor: anchor)
        e.routeDrawingCommit(d)
        let stored = e.reviewDrawings.last!
        #expect(stored.id == "gen-keep-review")
        #expect(stored.toolType == .channel)
        #expect(stored.lineSubType == .ray)
        #expect(stored.lineStyle == .dash2)
        #expect(stored.thickness == 3)
        #expect(stored.colorToken == .cyan)
        #expect(stored.labelMode == .left)
        #expect(stored.locked == true)
        #expect(stored.text == "复盘标注")
        #expect(stored.textForm == .borderTransparent)
        #expect(stored.tailAnchor == anchor)
        #expect(stored.revealTick == e.tick.globalTickIndex)
        #expect(e.drawings.isEmpty)   // 不污染原训练记录
    }

    // MARK: - P1b-1a-ii D42：「按 activePanel 双面板互斥」模型已退役
    // 旧的 toggleDrawingExclusive 三连测试（激活选中面板 / 切面板取消另一面板 / 同面板二次点击 toggle off）
    // 与 cancelDrawingAllPanels_clearsBoth 随该模型一并删除：
    //   · 画线会话现在是**全局**的 —— 开 = **两面板一起**进 .drawing，不存在「另一面板被取消」这回事；
    //   · cancelDrawingAllPanels 的唯一调用者已是 endDrawingSessionIfActive（会话收口点），不再单独直呼。
    // 等价且更强的覆盖（含「会话 ⇔ 两面板 mode」不变量断言）见 TrainingEngineDrawingSessionTests。

    // MARK: - 1a-iv（codex plan-R4/R5-high）：锚跨周期 / 显式 period 与锚不符 = 坐标系错乱的坏数据
    // （`belongsToPanel` 按 `drawing.period` 归属面板，锚却按各自 period 的 candleIndex 解释）。
    // 新增写入的**两个**真实入口都必须拒收，路由层 routeDrawingCommit 自然继承。

    private func mixedPeriodDrawing() -> DrawingObject {
        DrawingObject(toolType: .trend,
                      anchors: [DrawingAnchor(period: .m60, candleIndex: 1, price: 10),
                                DrawingAnchor(period: .daily, candleIndex: 2, price: 11)],
                      isExtended: false, panelPosition: 0, revealTick: 0,
                      lineSubType: .straight)
    }

    private func periodMismatchDrawing() -> DrawingObject {
        DrawingObject(toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m60, candleIndex: 1, price: 10)],
                      isExtended: false, panelPosition: 0, revealTick: 0,
                      period: .daily,                       // ← 与锚不符
                      lineSubType: .straight)
    }

    private func consistentDrawing() -> DrawingObject {
        DrawingObject(toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m60, candleIndex: 1, price: 10)],
                      isExtended: false, panelPosition: 0, revealTick: 0,
                      lineSubType: .straight)
    }

    @Test("入口①：appendDrawing 直接调用也拒收坏数据（不能只挡路由层）")
    func appendDrawingRejectsInconsistentPeriod() {
        let e = TrainingEngine.preview()
        e.appendDrawing(mixedPeriodDrawing())
        e.appendDrawing(periodMismatchDrawing())
        #expect(e.drawings.isEmpty)
    }

    @Test("入口②：appendReviewDrawing 直接调用同样拒收")
    func appendReviewDrawingRejectsInconsistentPeriod() {
        let e = TrainingEngine.preview()
        e.appendReviewDrawing(mixedPeriodDrawing())
        e.appendReviewDrawing(periodMismatchDrawing())
        #expect(e.reviewDrawings.isEmpty)
    }

    @Test("路由层继承：routeDrawingCommit 传坏数据 → 两个数组都不增长")
    func routeDrawingCommitInheritsTheGuard() {
        let e = TrainingEngine.preview()
        e.routeDrawingCommit(mixedPeriodDrawing())
        #expect(e.drawings.isEmpty)
        #expect(e.reviewDrawings.isEmpty)
    }

    @Test("对照（防假绿）：一致的 DrawingObject 照常入库 —— 守卫不是把提交路径焊死")
    func consistentDrawingStillAppends() {
        let e = TrainingEngine.preview()
        e.appendDrawing(consistentDrawing())
        #expect(e.drawings.count == 1)
        e.routeDrawingCommit(consistentDrawing())
        #expect(e.drawings.count == 2)                      // 路由层也照常放行
    }

    // MARK: - whole-branch codex R2-high：append 返回值可观测（消除未来「删旧线+append新线」式编辑
    // 静默丢线的隐患——1b-i 编辑路径尚未建，此处以返回值可观测性代验，见方法文档警告）。

    @Test("appendDrawing 拒收坏数据时返回 false，且 drawings 不增长")
    func appendDrawingReturnsFalseOnReject() {
        let e = TrainingEngine.preview()
        let ok = e.appendDrawing(mixedPeriodDrawing())
        #expect(ok == false)
        #expect(e.drawings.isEmpty)
    }

    @Test("appendDrawing 放行一致数据时返回 true，且 drawings 增长 1")
    func appendDrawingReturnsTrueOnAccept() {
        let e = TrainingEngine.preview()
        let ok = e.appendDrawing(consistentDrawing())
        #expect(ok == true)
        #expect(e.drawings.count == 1)
    }

    @Test("appendReviewDrawing 拒收坏数据时返回 false，且 reviewDrawings 不增长")
    func appendReviewDrawingReturnsFalseOnReject() {
        let e = TrainingEngine.preview()
        let ok = e.appendReviewDrawing(mixedPeriodDrawing())
        #expect(ok == false)
        #expect(e.reviewDrawings.isEmpty)
    }

    @Test("appendReviewDrawing 放行一致数据时返回 true，且 reviewDrawings 增长 1")
    func appendReviewDrawingReturnsTrueOnAccept() {
        let e = TrainingEngine.preview()
        let ok = e.appendReviewDrawing(consistentDrawing())
        #expect(ok == true)
        #expect(e.reviewDrawings.count == 1)
    }

    @Test("返回值可观测性代验「delete-then-append 不会静默消失」：调用者能在删旧线前先探知拒绝")
    func returnValueLetsCallerDetectRejectionBeforeDeletingOldLine() {
        // 真实编辑路径（删旧线 + append 新线）是 1b-i 尚未建的功能；这里以最小可表达形式验证
        // codex R2-high 要保护的性质：调用者必须能在“删旧线”之前，通过返回值知道新线会不会被拒收，
        // 从而避免「旧线已删、新线被静默拒收」导致的丢线。
        let e = TrainingEngine.preview()
        e.appendDrawing(consistentDrawing())          // 模拟已存在的“旧线”
        #expect(e.drawings.count == 1)
        let wouldAccept = e.appendDrawing(mixedPeriodDrawing())   // 探知：新线是否会被接受
        #expect(wouldAccept == false)                 // 被拒——调用者据此绝不能先删旧线
        #expect(e.drawings.count == 1)                // 旧线仍在，未被静默丢弃
    }

    @Test("D59：commitPending 经 withStyle —— (ray,.left) 在提交那一刻被归一成 .hidden（不靠面板自觉）")
    @MainActor func commitNormalizesLabelModeAtWriteBoundary() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        var s = DrawingDefaultStyle()
        s.lineSubType = .ray
        s.labelMode = .left                                  // 面板产不出的非法组合，直接塞进会话默认样式
        e.drawingSession.setDefaultStyle(s)
        e.drawingSession.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        let d = e.drawingSession.commitPending(panelPosition: 0)
        #expect(d?.labelMode == .hidden)                     // 写入边界归一化
        #expect(d?.isExtended == true)                       // 派生① 仍成立
    }

    @Test("D59：commitPending 对语义不成立的样式返 nil（水平线 .segment）——不提交、不落库")
    @MainActor func commitRejectsUnrenderableSubType() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        var s = DrawingDefaultStyle()
        s.lineSubType = .segment                             // 面板里恒灰，但直接设进会话是可达的
        e.drawingSession.setDefaultStyle(s)
        e.drawingSession.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        #expect(e.drawingSession.commitPending(panelPosition: 0) == nil)
        #expect(e.drawingSession.pendingAnchors.isEmpty)     // 拒交同样只丢 pending（保工具/保会话，D31）
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.drawingSession.activeDrawingTool == .horizontal)
    }

    @Test("D59 值域闸也覆盖新建路径（codex plan-R4-F1）：越域 thickness 的默认样式 → 不提交")
    @MainActor func commitRejectsOutOfDomainThickness() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        var s = DrawingDefaultStyle()
        s.thickness = 0                                      // 面板产不出，但直接设进会话可达
        e.drawingSession.setDefaultStyle(s)
        e.drawingSession.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        #expect(e.drawingSession.commitPending(panelPosition: 0) == nil)
        // ⚠️ 别在这里断言 `e.drawings.isEmpty`（Opus-F8：`commitPending` 从不写 `drawings`，写入的是
        //    `routeDrawingCommit`，本测试没调它 → 那条恒真、零判别力）。返 nil 本身即保证没东西可路由。
    }

    @Test("行为等价：正常样式提交后 5 字段 + textColorToken 跟随，与切片2 之前逐字一致")
    @MainActor func commitStillCarriesStyleAtomically() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        var s = DrawingDefaultStyle()
        s.lineSubType = .straight; s.lineStyle = .dash1; s.thickness = 3
        s.colorToken = .green; s.labelMode = .right
        e.drawingSession.setDefaultStyle(s)
        e.drawingSession.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        let d = e.drawingSession.commitPending(panelPosition: 0)
        #expect(d?.lineSubType == .straight)
        #expect(d?.lineStyle == .dash1)
        #expect(d?.thickness == 3)
        #expect(d?.colorToken == .green)
        #expect(d?.labelMode == .right)
        #expect(d?.textColorToken == .green)                 // 新线恒「字色跟随线色」（派生② 条件成立）
        #expect(d?.isExtended == false)
    }
}

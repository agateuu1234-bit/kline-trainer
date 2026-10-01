// ios/Contracts/Tests/KlineTrainerContractsTests/Render/NodeDragRenderOverrideTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D135 / D135b，task-10-brief.md 控制者订正 1/2/3/5）
//
// 平台门：host-pure —— 只碰 TrainingEngine / DrawingSession / RenderStateBuilder.visibleDrawings，
// 没有 Coordinator、没有 KLineView、没有 CGContext，不需要 UIKit（订正 5：不加 `#if canImport(UIKit)`，
// 照 Q24 守卫 `VisibleDrawingsAnchorIdentityGuardTests.swift` 的先例写，在 macOS host swift test 直接跑）。
//
// 本套件钉住 Task 10 的两条契约：
//   D135：拖动进行中，visibleDrawings 返回「替换了被拖锚点」的副本，且逐帧跟手指走（T3）、
//         零写盘（T6，`drawingsRevision` 全程不变）。
//   D135b：归属不变量（owner.drawingID == session.selectedDrawingID）不成立 ⇒ 不施加覆盖，
//         且本函数是纯读——调用前后 `nodeDragOwner`/`nodeDragCurrent`/`drawingsRevision` 一个都不许变（G10）。
// 订正 1/2 额外钉住「18 参数 init 里 14 个带默认值，手抄漏一个编译器不报错」这一族缺陷：
// 两处手抄（Task 10 的 `applyNodeDragOverride` + Task 3 的 `updateDrawingAnchor`）各有一条
// 「换回原锚点 ⇒ 与原对象整体相等」的往返恒等测试，夹具全部 14 个可配置字段都设成非默认值。
import CoreGraphics
import Foundation
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 渲染覆盖（D135 / D135b）")
struct NodeDragRenderOverrideTests {

    // MARK: - 共用夹具

    /// 简单两锚夹具（T3/T6/D135b 用；不需要「全字段非默认」，只需要锚点可区分）。
    /// toolType 用 `.horizontal`——`DrawingToolType.implemented` 当前只收这一个（`Models.swift:50`），
    /// `updateDrawingAnchor` 的 `isEditableToolType` 门只认它；锚点数（2）与工具语义不必自洽
    /// （本测试不碰渲染/命中，只碰 `visibleDrawings`/`updateDrawingAnchor` 的字段级行为，同 Q24 守卫先例）。
    private func makeTwoAnchorLine(id: String, period: Period) -> DrawingObject {
        DrawingObject(
            id: id, toolType: .horizontal,
            anchors: [
                DrawingAnchor(period: period, candleIndex: 0, price: 10),
                DrawingAnchor(period: period, candleIndex: 0, price: 20),
            ],
            isExtended: false, panelPosition: 0, revealTick: 0, period: period)
    }

    /// 全字段非默认的夹具（订正 2 硬性要求）：`DrawingObject.init` 18 个参数里可配置的 14 个
    /// 全部设成**非默认值**，否则「手抄漏掉某字段 → 静默回落默认值」这类缺陷在夹具恰好等于
    /// 默认值的情况下测不出来（判别力为零）。
    /// ⚠️ `period`（.m60）与 `anchors.first.period`（.daily）故意不一致——真实拖动状态里两者
    /// 相等，这里刻意造一个不自洽的组合，**只是**为了让「手抄漏传 `period`、让 init 回落
    /// `anchors.first?.period`」这一个缺陷可被侦测。⛔ 这是故意的，不要「修正」成两者相等，
    /// 否则这条判据对 `period` 字段会永久失效（订正 2 原文明令）。
    ///
    /// ⚠️ `locked` 是**结构性例外**（订正 2 要求全部非默认，这一个字段做不到）：`locked` 同时
    /// 是 `updateDrawingAnchor` 的写入门（`!old.locked`，`TrainingEngine.swift:1280`）——
    /// `locked == true` 会在手抄那一行**之前**被拒，根本走不到手抄；`locked == false` 又恰好
    /// 等于默认值，使"漏传 locked"在该入口下判别力恒为零。这是该字段在 `updateDrawingAnchor`
    /// 这一个入口下的结构性限制（控制者订正未预见，详见报告「订正分歧」），不是测试偷懒。
    /// `applyNodeDragOverride` 不读 `locked`，不受影响，默认传 `true`（非默认）。
    private func fullFieldFixture(id: String, locked: Bool = true) -> DrawingObject {
        DrawingObject(
            id: id,
            toolType: .horizontal,       // 同上：updateDrawingAnchor 的 isEditableToolType 门只认 .horizontal
            anchors: [
                DrawingAnchor(period: .daily, candleIndex: 0, price: 11),
                DrawingAnchor(period: .daily, candleIndex: 0, price: 21),
            ],
            isExtended: true,              // 非默认（默认 false）
            panelPosition: 1,               // 非默认（默认 0）
            revealTick: 5,                  // 非默认（默认 0）——调用 visibleDrawings 时传大 tick 避免被渐显过滤
            period: .m60,                   // 非默认（nil→回落 anchors.first.period）；故意与 anchors[0].period 不同，见上注
            lineSubType: .segment,           // 非默认（默认 .straight）
            lineStyle: .dash2,               // 非默认（默认 .solid）
            thickness: 3,                    // 非默认（默认 1）
            colorToken: .blue,               // 非默认（默认 .orange）
            labelMode: .left,                // 非默认（默认 .hidden）
            locked: locked,                  // 见上方头注：默认非默认值 true，test② 结构性必须传 false
            text: "拖动夹具",                 // 非默认（默认 ""）
            fontSize: 22,                     // 非默认（默认 14）
            textColorToken: .purple,          // 非默认（默认 .orange）
            textForm: .borderFilled,          // 非默认（默认 .plain）
            tailAnchor: DrawingAnchor(period: .m60, candleIndex: 2, price: 99))  // 非默认（默认 nil）
    }

    /// 两条 `visibleDrawings` 结果之间「哪些 id 的内容变了」（`DrawingObject.==` 本身就是逐字段比较，
    /// 唯独排除 `id`——同 id 匹配本身已保证 id 相同，这里只用它判内容是否被改写）。
    private func diffIDs(_ visible: [DrawingObject], against committed: [DrawingObject]) -> [DrawingID] {
        visible.compactMap { v in
            guard let c = committed.first(where: { $0.id == v.id }) else { return nil }
            return v == c ? nil : v.id
        }
    }

    /// 把一个 `DrawingObject` 的 `anchors` 替换成固定值（这里置空），其余 17 个字段原样透传——
    /// 经 Codable 往返改写 JSON 里的 "anchors" 键，**不手列其余字段**（订正 1 原文：「不要靠逐
    /// 字段列清单去核，列清单本身也会漏」）。用来把两个对象「锚点归一化」后比 `==`，判别力与
    /// 逐字段断言等价，但没有手抄风险。
    private func zeroingAnchors(_ d: DrawingObject) throws -> DrawingObject {
        let data = try JSONEncoder().encode(d)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFixtureError.badJSON
        }
        obj["anchors"] = []
        let newData = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(DrawingObject.self, from: newData)
    }

    private enum TestFixtureError: Error { case badJSON }

    // MARK: - T3 实时跟随

    @Test("T3 实时跟随：visibleDrawings 里那条线的锚点 == 当前拖动锚点，且帧间几何确实变了")
    func overrideAppliesToVisibleDrawings() throws {
        let engine = TrainingEngine.preview()
        let upperPeriod = engine.upperPanel.period
        engine.injectDrawingsForTesting([makeTwoAnchorLine(id: "A", period: upperPeriod)])
        engine.toggleDrawingMode()                  // drawingModeActive=true，setSelection 的门才放行
        engine.drawingSession.setMode(.select)
        engine.drawingSession.setSelection(id: "A", panel: .upper)

        let owner = DrawingSession.NodeDragOwner(panel: .upper, drawingID: "A", anchorIndex: 1, grabPoint: .zero)
        let frame1 = DrawingAnchor(period: upperPeriod, candleIndex: 0, price: 50)
        engine.drawingSession.beginNodeDrag(owner, anchor: frame1)

        let visible1 = RenderStateBuilder.visibleDrawings(engine: engine, panel: .upper, tick: engine.tick.globalTickIndex)
        let line1 = try #require(visible1.first(where: { $0.id == "A" }))
        #expect(line1.anchors[1] == frame1, "拖动中那条线的锚点必须跟当前拖动锚点一致")

        // 下一帧：手指移动，anchor 换一个不同的值。
        let frame2 = DrawingAnchor(period: upperPeriod, candleIndex: 0, price: 73)
        engine.drawingSession.updateNodeDragCurrent(frame2)
        let visible2 = RenderStateBuilder.visibleDrawings(engine: engine, panel: .upper, tick: engine.tick.globalTickIndex)
        let line2 = try #require(visible2.first(where: { $0.id == "A" }))
        #expect(line2.anchors[1] == frame2, "第二帧那条线的锚点必须跟新的拖动锚点一致")

        // ⭐ 必须先断言帧与帧之间几何确实变了（差值非 0），否则「两边取同一个常数」恒真。
        #expect(frame1 != frame2, "前提：两帧的拖动锚点本身必须不同")
        #expect(line1.anchors[1] != line2.anchors[1], "两帧渲染出来的锚点必须跟着不同，不能是同一个常数")
    }

    // MARK: - T6 拖动中零写盘

    @Test("T6 拖动中一次盘都不写：drawingsRevision 全程不变；收尾之后它才 +1（正向对照）")
    func noPersistDuringDrag() throws {
        let engine = TrainingEngine.preview()
        let upperPeriod = engine.upperPanel.period
        engine.injectDrawingsForTesting([makeTwoAnchorLine(id: "A", period: upperPeriod)])
        engine.toggleDrawingMode()
        engine.drawingSession.setMode(.select)
        engine.drawingSession.setSelection(id: "A", panel: .upper)

        let revisionBeforeDrag = engine.drawingsRevision
        let owner = DrawingSession.NodeDragOwner(panel: .upper, drawingID: "A", anchorIndex: 1, grabPoint: .zero)
        engine.drawingSession.beginNodeDrag(owner, anchor: DrawingAnchor(period: upperPeriod, candleIndex: 0, price: 30))
        #expect(engine.drawingsRevision == revisionBeforeDrag, "占槽本身不写盘")

        // 模拟多帧：反复调用 visibleDrawings（渲染读路径），revision 必须全程不变。
        for price in [40.0, 50.0, 60.0, 70.0] {
            engine.drawingSession.updateNodeDragCurrent(DrawingAnchor(period: upperPeriod, candleIndex: 0, price: price))
            _ = RenderStateBuilder.visibleDrawings(engine: engine, panel: .upper, tick: engine.tick.globalTickIndex)
            #expect(engine.drawingsRevision == revisionBeforeDrag, "渲染读路径在第 price=\(price) 帧零写入")
        }

        // 松手：真正的提交路径（Task 3 的 updateDrawingAnchor）才允许 +1 ——正向对照，
        // 证明这份夹具下 revision 真的"能"变，上面「全程不变」不是因为它恒无法变化。
        let finalAnchor = DrawingAnchor(period: upperPeriod, candleIndex: 0, price: 70)
        engine.drawingSession.endNodeDrag()
        let committed = engine.updateDrawingAnchor(id: "A", anchorIndex: 1, anchor: finalAnchor)
        #expect(committed, "正向对照的提交必须成功，否则下面的 +1 断言是空转")
        #expect(engine.drawingsRevision == revisionBeforeDrag + 1, "收尾提交之后 revision 必须 +1")
    }

    // MARK: - D135b 不变量

    @Test("D135b 不变量不成立（归属 ≠ 当前选中）⇒ 不施加覆盖，且渲染读路径零写入")
    func overrideIsSkippedWhenOwnershipBroken() throws {
        let engine = TrainingEngine.preview()
        let upperPeriod = engine.upperPanel.period
        let lineA = makeTwoAnchorLine(id: "A", period: upperPeriod)
        let lineB = makeTwoAnchorLine(id: "B", period: upperPeriod)
        engine.injectDrawingsForTesting([lineA, lineB])
        engine.toggleDrawingMode()
        engine.drawingSession.setMode(.select)
        // 当前选中是 B……
        engine.drawingSession.setSelection(id: "B", panel: .upper)
        // ……而 owner 直接造成 "A"（绕过正常入口——D135c 在正常入口下结构性禁止这种分叉，
        // 这里用 @testable 直调 internal mutator 构造一个本应不可达的坏状态，专测防御分支）。
        let owner = DrawingSession.NodeDragOwner(panel: .upper, drawingID: "A", anchorIndex: 1, grabPoint: .zero)
        let draggedAnchor = DrawingAnchor(period: upperPeriod, candleIndex: 0, price: 999)
        engine.drawingSession.beginNodeDrag(owner, anchor: draggedAnchor)
        #expect(engine.drawingSession.selectedDrawingID == "B", "前提：选中仍是 B，不变量确实不成立")

        let ownerBefore = engine.drawingSession.nodeDragOwner
        let currentBefore = engine.drawingSession.nodeDragCurrent
        let revisionBefore = engine.drawingsRevision

        let visible = RenderStateBuilder.visibleDrawings(engine: engine, panel: .upper, tick: engine.tick.globalTickIndex)

        // 不施加覆盖：A 的内容原样（订正 3 反向对照：差异元素个数恰好是 0）。
        #expect(diffIDs(visible, against: engine.drawings).isEmpty,
                "不变量不成立 ⇒ visibleDrawings 与 engine.drawings 之间不应有任何内容差异")
        let returnedA = try #require(visible.first(where: { $0.id == "A" }))
        #expect(returnedA == lineA, "A 的内容必须是提交值，不是被覆盖后的样子")
        #expect(returnedA.anchors[1] != draggedAnchor, "A 的锚点不应被换成正在拖动的那个值")

        // ⭐ G10：渲染读路径零写入——调用前后这三样一个都不许变。
        #expect(engine.drawingSession.nodeDragOwner == ownerBefore, "读路径不许改写 nodeDragOwner")
        #expect(engine.drawingSession.nodeDragCurrent == currentBefore, "读路径不许改写 nodeDragCurrent")
        #expect(engine.drawingsRevision == revisionBefore, "读路径不许改写 drawingsRevision")
    }

    // MARK: - 订正 3：拖动进行中恰好差一处

    @Test("订正3：不变量成立时，visibleDrawings 相对提交值恰好差一个元素，且那个元素恰好只差 owner.anchorIndex 一个下标")
    func overrideDiffersFromCommittedByExactlyOneElementAtExactlyOneIndex() throws {
        let engine = TrainingEngine.preview()
        let upperPeriod = engine.upperPanel.period
        let lineA = makeTwoAnchorLine(id: "A", period: upperPeriod)
        let lineOther = makeTwoAnchorLine(id: "OTHER", period: upperPeriod)
        engine.injectDrawingsForTesting([lineA, lineOther])
        engine.toggleDrawingMode()
        engine.drawingSession.setMode(.select)
        engine.drawingSession.setSelection(id: "A", panel: .upper)

        let owner = DrawingSession.NodeDragOwner(panel: .upper, drawingID: "A", anchorIndex: 1, grabPoint: .zero)
        let draggedAnchor = DrawingAnchor(period: upperPeriod, candleIndex: 0, price: 123)
        engine.drawingSession.beginNodeDrag(owner, anchor: draggedAnchor)

        let visible = RenderStateBuilder.visibleDrawings(engine: engine, panel: .upper, tick: engine.tick.globalTickIndex)

        // 断言差异元素的个数恰好是 1（⛔ 不是 ">= 1"）——否则"顺手改了别的线"抓不到。
        let diffs = diffIDs(visible, against: engine.drawings)
        #expect(diffs == ["A"], "差异元素必须恰好是 [\"A\"] 这一个，不多不少")

        // 断言那一条的 anchors 与原值只有 owner.anchorIndex 这一个下标不同（逐下标比）。
        let committedA = try #require(engine.drawings.first(where: { $0.id == "A" }))
        let overriddenA = try #require(visible.first(where: { $0.id == "A" }))
        for idx in committedA.anchors.indices {
            if idx == owner.anchorIndex {
                #expect(overriddenA.anchors[idx] == draggedAnchor, "owner.anchorIndex 这一下标必须等于当前拖动锚点")
                #expect(overriddenA.anchors[idx] != committedA.anchors[idx], "owner.anchorIndex 这一下标必须与提交值不同")
            } else {
                #expect(overriddenA.anchors[idx] == committedA.anchors[idx], "下标 \(idx) 不是 owner.anchorIndex，必须原样不变")
            }
        }
    }

    // MARK: - 订正 1/2：手抄完整性①（Task 10 的 applyNodeDragOverride）

    @Test("手抄完整性①（Task 10 的 applyNodeDragOverride）：换回原锚点 ⇒ 与原对象整体相等（含 id）")
    func overrideCopyPreservesEveryField() throws {
        let engine = TrainingEngine.preview()
        let original = fullFieldFixture(id: "FIXTURE-A")
        engine.injectDrawingsForTesting([original])

        // 修复环第1轮 Important：拖动「开始前」先取一次 base——此时 nodeDragOwner == nil，
        // 覆盖不生效，这就是提交值的可见子集。查找只用来**定位下标** k，k 不参与后面的 id 断言，
        // 这样 id 断言才不会沦为「用查找键断言查找键」的恒真断言（评审变异实证：之前的写法
        // 删掉 applyNodeDragOverride 里的 `id: d.id,` 后，红的是 #require 查找行，从未执行到
        // id == 那一条——即本仓记录过的「返回 self 的映射恒真」/「用查找键断言查找键」）。
        let base = RenderStateBuilder.visibleDrawings(engine: engine, panel: .upper, tick: 999)
        let k = try #require(base.firstIndex(where: { $0.id == "FIXTURE-A" }))

        engine.toggleDrawingMode()
        engine.drawingSession.setMode(.select)
        engine.drawingSession.setSelection(id: "FIXTURE-A", panel: .upper)

        let owner = DrawingSession.NodeDragOwner(panel: .upper, drawingID: "FIXTURE-A", anchorIndex: 1, grabPoint: .zero)
        let draggedAnchor = DrawingAnchor(period: .m60, candleIndex: 4, price: 77)
        engine.drawingSession.beginNodeDrag(owner, anchor: draggedAnchor)

        // revealTick(5) 非 0（订正 2 要求），故传一个远大于它的 tick，避免被渐显过滤挡在外面。
        let visible = RenderStateBuilder.visibleDrawings(engine: engine, panel: .upper, tick: 999)
        // ⭐ 覆盖是 `.map`，必须保持长度与顺序；这一句不能省——否则「覆盖顺手改了长度」会让
        // `visible[k]` 指向另一条线，下标对应关系就不成立了（用 #require：长度一旦不对，
        // 后面按下标取值会越界崩溃，必须在那之前就红）。
        try #require(visible.count == base.count, "覆盖必须是保长度保顺序的 .map，下标对应关系才成立")
        let overridden = visible[k]

        // 先确认覆盖确实发生了（否则下面「换回锚点后相等」是空转——覆盖没生效也会相等）。
        #expect(overridden.anchors[1] == draggedAnchor)
        #expect(overridden.anchors[1] != original.anchors[1])

        // 往返恒等：锚点归一化后比较其余 17 个字段（订正 1 推荐写法，不手列字段）。
        let overriddenNormalized = try zeroingAnchors(overridden)
        let originalNormalized = try zeroingAnchors(original)
        #expect(overriddenNormalized == originalNormalized,
                "换回锚点后其余所有字段必须与原对象逐字段相等（== 本身就是全字段比较，唯独不比较 id）")
        // `DrawingObject.==` 故意不比较 `id`（Models.swift:362-375）⇒ 单独补一条 id 断言，
        // 否则"手抄漏传 id、换成随机 UUID"这一档缺陷用 == 测不出来。
        // ⛔⛔ 两边必须都按下标 k 取（`overridden` 已是；这里再用 `base[k].id` 而不是字面量
        // "FIXTURE-A" 或任何按 id 查找的结果）——⛔ 不许改回「按 id 查找」，那会让这条断言的
        // 输入里重新含有它要断言的那个值，退回恒真（修复环第1轮 Important；Minor 一并处理）。
        #expect(overridden.id == base[k].id, "id 必须原样保留——DrawingObject.== 不覆盖这一项")
    }

    // MARK: - 订正 1/2：手抄完整性②（Task 3 的 updateDrawingAnchor，回填）

    @Test("手抄完整性②（Task 3 的 updateDrawingAnchor）：写入后把锚点换回 ⇒ 与写入前整体相等（含 id）")
    func updateDrawingAnchorPreservesEveryField() throws {
        let engine = TrainingEngine.preview()
        // locked: false 是结构性必须（见 fullFieldFixture 头注）——locked: true 会在手抄行之前
        // 就被 `!old.locked` 门拒绝，写入永远不会发生，下面的断言会全部空转。
        let original = fullFieldFixture(id: "FIXTURE-B", locked: false)
        engine.injectDrawingsForTesting([original])
        // 修复环第1轮 Important：写入**之前**先按 id 定位下标 k（此时数组内容是 original，
        // 查找安全）；写入之后**改用下标** k 读 engine.drawings[k]，不再按 id 查找——
        // `updateDrawingAnchor` 内部按 id 定位要替换的下标 `i` 这一步在手抄重建**之前**完成，
        // 不受手抄漏传 id 的影响，`drawings[i] = updated` 是原地替换、不改长度/顺序，
        // 故 k 在写入前后指向同一条线，下面的 id 断言才不会沦为「用查找键断言查找键」的恒真断言。
        let k = try #require(engine.drawings.firstIndex(where: { $0.id == "FIXTURE-B" }))

        let newAnchor = DrawingAnchor(period: .m60, candleIndex: 4, price: 77)
        let ok = engine.updateDrawingAnchor(id: "FIXTURE-B", anchorIndex: 1, anchor: newAnchor)
        #expect(ok, "写入必须成功，否则下面的断言是空转")

        let written = engine.drawings[k]
        #expect(written.anchors[1] == newAnchor)
        #expect(written.anchors[1] != original.anchors[1])

        let writtenNormalized = try zeroingAnchors(written)
        let originalNormalized = try zeroingAnchors(original)
        #expect(writtenNormalized == originalNormalized,
                "换回锚点后其余所有字段必须与写入前逐字段相等")
        // ⛔⛔ 不许改回「按 id 查找」取 written——那会让这条断言的输入里重新含有它要断言的
        // 那个值，退回恒真（修复环第1轮 Important；Minor 一并处理）。
        #expect(written.id == original.id, "id 必须原样保留——DrawingObject.== 不覆盖这一项")
    }

    // MARK: - Task 11 订正 1（Critical）：几何基准必须是提交值，⛔ 不得是 `visibleDrawings` 的覆盖值

    /// **host-pure 复现**（Task 11 控制者任务提示：若判别力只用 `DrawingNodeDrag` + session 构造
    /// 就够，放 host；本档确实够——不需要 Coordinator/UIKit，只需要 `engine.drawings` /
    /// `RenderStateBuilder.visibleDrawings` / `DrawingNodeDrag.draggedAnchor` 三者）。
    ///
    /// 直接用 `RenderStateBuilder.visibleDrawings` 的返回对象当 `DrawingNodeDrag.draggedAnchor` 的
    /// `drawing` 参数（Task 11 brief 原文 Step 2 的写法）：拖动进行中它已经被 Task 10 的
    /// `applyNodeDragOverride` 换成拖动中间值，而 `translation` 是「自按下以来的累计位移」——
    /// 上一帧已经叠过的位移会在下一帧被再加一次，**逐帧复利叠加**。本档逐帧对照「基准=提交值」
    /// （线性）与「基准=visibleDrawings 覆盖值」（复利）两条序列，并把实测数字写进断言消息里
    /// （task-11-report.md 的「订正 1」一节原样引用这些数字）。
    @Test("订正1 host 复现：拖动几何基准若取 `visibleDrawings` 的覆盖值 ⇒ 位移逐帧复利叠加，⛔ 不得与 translation 成正比")
    func draggedAnchorCompoundsWhenBasisIsOverriddenValue() throws {
        let engine = TrainingEngine.preview()
        let upperPeriod = engine.upperPanel.period
        let committed = makeTwoAnchorLine(id: "A", period: upperPeriod)
        engine.injectDrawingsForTesting([committed])
        engine.toggleDrawingMode()
        engine.drawingSession.setMode(.select)
        engine.drawingSession.setSelection(id: "A", panel: .upper)

        let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        let state = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: bounds)
        let mapper = CoordinateMapper(viewport: state.viewport, displayScale: 2)
        let tool = HorizontalLineTool()
        // ⚠️ `.horizontal` 的 `requiredAnchors` 是 `1...1`（只认第 1 个锚点，`HorizontalLineTool.swift:12`）
        //    ⇒ `DrawingNodeGeometry.marks` 的 `maxAnchors` 只覆盖下标 0，下标 1 恒产不出 `.real`
        //    （`DrawingNodeDrag.draggedAnchor` 对它恒返回 nil，与本档要测的「线性性」无关）。
        //    必须用下标 0——这与 T3/D135b/订正3 那几档刻意用下标 1（只测数组覆盖，不碰工具语义）
        //    的理由不同：本档要调用真正的 `draggedAnchor`，必须落在工具认得的锚点上。
        let anchorIndex = 0
        // 四帧累计位移（与报告「订正 1」表格同款：-10/-20/-30/-40，纯纵向）。
        let translations = [CGPoint(x: 0, y: -10), CGPoint(x: 0, y: -20),
                            CGPoint(x: 0, y: -30), CGPoint(x: 0, y: -40)]

        // ── 正确序列：几何基准**恒为提交值**（不受 nodeDragCurrent/覆盖影响）。
        var correct: [DrawingAnchor] = []
        for t in translations {
            let a = try #require(DrawingNodeDrag.draggedAnchor(
                drawing: committed, anchorIndex: anchorIndex, translation: t, mapper: mapper, tool: tool))
            correct.append(a)
        }
        // 自检：正确序列必须真的在线性区（没有撞夹取边界），否则下面的「等差」断言测的是夹取而不是线性性。
        let correctDiffs = zip(correct.dropFirst(), correct).map { $0.price - $1.price }
        #expect(correctDiffs[0] != 0, "自检：正确序列的帧间差必须非零，否则本档测的是空气")
        for i in 1..<correctDiffs.count {
            #expect(abs(correctDiffs[i] - correctDiffs[0]) < 1e-9,
                    "自检失败：正确序列不是等差（可能撞了夹取边界），需要调小本档的 translation 幅度。帧间差：\(correctDiffs)")
        }

        // ── 缺陷序列：几何基准取**上一帧写进 session 之后 `visibleDrawings` 的覆盖值**——
        //    与 Task 11 brief 原文 Step 2「从 visibleDrawings 取 drawing」逐字同构。
        var buggy: [DrawingAnchor] = []
        let owner = DrawingSession.NodeDragOwner(panel: .upper, drawingID: "A", anchorIndex: anchorIndex, grabPoint: .zero)
        for (i, t) in translations.enumerated() {
            let basis: DrawingObject
            if i == 0 {
                // 第一帧等价 `.began`：此刻 `nodeDragOwner` 还是 nil，`visibleDrawings` 返回提交值
                // （订正 1 的精确化：`.began` 本身没有缺陷，参见报告）。
                basis = committed
            } else {
                basis = try #require(RenderStateBuilder.visibleDrawings(
                    engine: engine, panel: .upper, tick: engine.tick.globalTickIndex
                ).first(where: { $0.id == "A" }), "第 \(i + 1) 帧：visibleDrawings 必须能找到这条线")
            }
            let a = try #require(DrawingNodeDrag.draggedAnchor(
                drawing: basis, anchorIndex: anchorIndex, translation: t, mapper: mapper, tool: tool))
            buggy.append(a)
            if i == 0 { engine.drawingSession.beginNodeDrag(owner, anchor: a) }
            else { engine.drawingSession.updateNodeDragCurrent(a) }
        }
        let buggyDiffs = zip(buggy.dropFirst(), buggy).map { $0.price - $1.price }

        // ⭐ 第一帧（.began 等价）两个序列必须相等——订正 1 的精确化：`.began` 本身没有缺陷。
        #expect(buggy[0] == correct[0], "第一帧（.began 等价）正确/缺陷两个序列必须相等")

        // ⭐⭐ 缺陷序列的帧间差必须是三角数倍数（2×/3×/4× unit，unit=正确序列的恒定帧间差）——
        //    这正是「上一帧的覆盖值被当基准、位移被再加一次」的代数后果：第 n 帧相对提交值的
        //    偏移量是三角数 T(n)=n(n+1)/2 乘 unit（本档实测 T(1..4)=1,3,6,10，即 1:3:6:10），
        //    帧间差则是 T(n)-T(n-1)=n，即 2×/3×/4×unit（T(1)=1 已在第一帧里，不计入 diff）。
        let unit = correctDiffs[0]
        #expect(abs(buggyDiffs[0] - unit * 2) < 1e-9,
                "缺陷序列第 1 个帧间差必须 ≈ 2×unit（三角数 T(2)-T(1)=2），实测 \(buggyDiffs[0])，unit=\(unit)")
        #expect(abs(buggyDiffs[1] - unit * 3) < 1e-9,
                "缺陷序列第 2 个帧间差必须 ≈ 3×unit（三角数 T(3)-T(2)=3），实测 \(buggyDiffs[1])")
        #expect(abs(buggyDiffs[2] - unit * 4) < 1e-9,
                "缺陷序列第 3 个帧间差必须 ≈ 4×unit（三角数 T(4)-T(3)=4），实测 \(buggyDiffs[2])")
        // ⭐ 反向对照：两个序列必须真的分叉（不是碰巧全部相等）。
        #expect(buggy[2] != correct[2],
                "缺陷序列与正确序列必须在第 3 帧分叉，实测缺陷=\(buggy.map(\.price))，正确=\(correct.map(\.price))")

        // 实测数字打进 stdout，task-11-report.md「订正 1」一节原样引用（本仓既有先例：
        // `DrawingNodeDrag.swift` 头注同样把实测偏差数字写进注释，不只是断言）。
        print("""
            订正1 host 复现实测：committed.price=\(committed.anchors[anchorIndex].price)
            正确序列=\(correct.map(\.price))（帧间差 \(correctDiffs)）
            缺陷序列=\(buggy.map(\.price))（帧间差 \(buggyDiffs)）
            """)
    }
}

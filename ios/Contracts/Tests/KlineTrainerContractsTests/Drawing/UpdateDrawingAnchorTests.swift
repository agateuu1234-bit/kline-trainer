// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/UpdateDrawingAnchorTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D136 门列表 / T7 / T7b）
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 引擎第 5 个写入面：updateDrawingAnchor（D136）")
struct UpdateDrawingAnchorTests {

    /// ⭐ 每一档的形状都是「先证明放行、再关掉那道门证明被拒」——⛔ 只断言 false 会被恒 false 的实现骗过
    static func engineWithOneLine() -> (TrainingEngine, DrawingObject) {
        let e = TrainingEngine.preview()
        let line = makeStyledHLine(id: "A")
        e.injectDrawingsForTesting([line])
        return (e, line)
    }

    @Test("T7b② 不相等档：真的改了 ⇒ 写进 drawings、revision +1、撤销栈恰好多一条")
    func changedAnchorIsActuallyWritten() throws {
        let (e, line) = Self.engineWithOneLine()
        let base = e.drawingsRevision
        let newAnchor = DrawingAnchor(period: line.period,
                                      candleIndex: line.anchors[0].candleIndex + 3,
                                      price: line.anchors[0].price + 1.5)
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: newAnchor))
        // ⛔ 不得只断言返回值——返 true 不等于真的写了（门⑥ 写反时正是「返 true 但没写」）
        #expect(e.drawings.first(where: { $0.id == line.id })?.anchors[0] == newAnchor)
        #expect(e.drawingsRevision == base + 1)
        #expect(e.drawingUndoEntryForTesting != nil)
    }

    /// R-1（控制者裁定）：`DrawingUndoEntry` 没有 `Equatable`（`DrawingUndoEntry.swift:11`），
    /// ⛔ 不给它加——那是本任务范围外的生产改动。改用**比 `==` 更强**的可观察代理：
    /// ① `drawingsRevision` 数值不变；② 真的调一次 `undoDrawing()`，断言锚点回到**第一次真编辑
    /// 之前**的值——如果第二次（内容未变的）调用错误地把栈顶顶替掉，撤销就只会退回到「第一次编辑
    /// 之后」（即仍是 newAnchor），这条断言会当场红，正是 spec「⛔ 不得把撤销栈里那条真编辑挤掉」
    /// 的直接兑现。
    @Test("T7b① 相等档：内容没变 ⇒ 返 true 但 revision 不变、撤销栈不变（可观察代理：revision + undo 回退点）")
    func unchangedAnchorIsZeroSideEffect() throws {
        let (e, line) = Self.engineWithOneLine()
        let originalAnchor = line.anchors[0]
        let newAnchor = DrawingAnchor(period: line.period,
                                      candleIndex: originalAnchor.candleIndex + 3,
                                      price: originalAnchor.price + 1.5)
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: newAnchor))
        let afterFirst = e.drawingsRevision
        let same = e.drawings.first(where: { $0.id == line.id })!.anchors[0]
        #expect(same == newAnchor)

        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: same))
        #expect(e.drawingsRevision == afterFirst)      // ⛔ 零副作用

        // 那条真编辑必须仍在栈顶：undo 一次应退回「第一次编辑之前」，而不是原地不动
        // （若第二次调用错误入栈，撤销只会退到「第一次编辑之后」——本断言会红）。
        #expect(e.undoDrawing())
        #expect(e.drawings.first(where: { $0.id == line.id })?.anchors[0] == originalAnchor)
    }

    // MARK: - T7：七道拒收门逐条（D136 ⓪①②②b③④⑤），每档一对
    // 修复环第 1 轮：简报 Step 1 标题写了「T7 七门」但代码块只给了 T7b，本节补全缺口（spec §8-T7）。
    // ⭐ 每档都是「违规输入 ⇒ false + 零改动」配「去掉那个成因、其余一致 ⇒ true + 真的写了」——
    //   只写前一半的话，一个恒返 false 的实现会七档全绿，这正是 spec 原文的警告。

    // ── ⓪ 复盘 ──

    @Test("T7-⓪ 违规：复盘模式下 updateDrawingAnchor 拒绝，逐字段不变")
    func reviewModeRejectsAnchorEdit() throws {
        let e = TrainingEngine.preview(mode: .review)
        let line = makeStyledHLine(id: "A")
        e.injectDrawingsForTesting([line])
        let before = e.drawings
        let rev = e.drawingsRevision
        let newAnchor = DrawingAnchor(period: line.period,
                                      candleIndex: line.anchors[0].candleIndex + 3,
                                      price: line.anchors[0].price + 1.5)
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: newAnchor) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("T7-⓪ 对照：把复盘门拿掉（换成非复盘引擎）、其余一致 → 改锚点成功")
    func normalModeAcceptsAnchorEdit() throws {
        let (e, line) = Self.engineWithOneLine()
        let newAnchor = DrawingAnchor(period: line.period,
                                      candleIndex: line.anchors[0].candleIndex + 3,
                                      price: line.anchors[0].price + 1.5)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: newAnchor) == true)
        #expect(e.drawings.first(where: { $0.id == line.id })?.anchors[0] == newAnchor)
        #expect(e.drawingsRevision == rev + 1)
    }

    // ── ①a 空 id ──

    @Test("T7-①a 违规：id 为空 → updateDrawingAnchor 拒绝，逐字段不变")
    func emptyIdRejectsAnchorEdit() throws {
        let (e, line) = Self.engineWithOneLine()
        let before = e.drawings
        let rev = e.drawingsRevision
        let newAnchor = DrawingAnchor(period: line.period, candleIndex: 10, price: 99)
        #expect(e.updateDrawingAnchor(id: "", anchorIndex: 0, anchor: newAnchor) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("T7-①a 对照：换成真实 id、其余一致 → 改锚点成功")
    func realIdAcceptsAnchorEdit() throws {
        let (e, line) = Self.engineWithOneLine()
        let newAnchor = DrawingAnchor(period: line.period, candleIndex: 10, price: 99)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: newAnchor) == true)
        #expect(e.drawings.first(where: { $0.id == line.id })?.anchors[0] == newAnchor)
        #expect(e.drawingsRevision == rev + 1)
    }

    // ── ①b id 不唯一 ──

    @Test("T7-①b 违规：全局同 id 有两条线 → updateDrawingAnchor 拒绝，两条锚点都不变")
    func duplicateIdRejectsAnchorEdit() throws {
        let e = TrainingEngine.preview()
        e.injectDrawingsForTesting([makeStyledHLine(id: "A", candleIndex: 3),
                                    makeStyledHLine(id: "A", candleIndex: 4)])
        let before = e.drawings
        let rev = e.drawingsRevision
        let newAnchor = DrawingAnchor(period: .daily, candleIndex: 10, price: 99)
        #expect(e.updateDrawingAnchor(id: "A", anchorIndex: 0, anchor: newAnchor) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("T7-①b 对照：去掉重复、全局只剩一条同 id 线 → 改锚点成功")
    func uniqueIdAcceptsAnchorEdit() throws {
        let (e, line) = Self.engineWithOneLine()
        let newAnchor = DrawingAnchor(period: line.period, candleIndex: 10, price: 99)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: newAnchor) == true)
        #expect(e.drawings.first(where: { $0.id == line.id })?.anchors[0] == newAnchor)
        #expect(e.drawingsRevision == rev + 1)
    }

    // ── ② 锁定 ──

    @Test("T7-② 违规：锁定的线 → updateDrawingAnchor 拒绝，逐字段不变")
    func lockedLineRejectsAnchorEdit() throws {
        let (e, line) = Self.engineWithOneLine()
        #expect(e.setDrawingLocked(id: line.id, locked: true) == true)
        let before = e.drawings
        let rev = e.drawingsRevision
        let newAnchor = DrawingAnchor(period: line.period, candleIndex: 10, price: 99)
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: newAnchor) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("T7-② 对照：同一条线保持解锁（其余一致）→ 改锚点成功")
    func unlockedLineAcceptsAnchorEdit() throws {
        // engineWithOneLine() 造出的线默认 locked == false —— 这就是「把锁定成因去掉」后的状态，
        // 不需要另外调用 setDrawingLocked，否则会引入一次多余的 revision +1 干扰断言。
        let (e, line) = Self.engineWithOneLine()
        let newAnchor = DrawingAnchor(period: line.period, candleIndex: 10, price: 99)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: newAnchor) == true)
        #expect(e.drawings.first(where: { $0.id == line.id })?.anchors[0] == newAnchor)
        #expect(e.drawingsRevision == rev + 1)
    }

    // ── ②b 工具门 ──

    @Test("T7-②b 违规：`.trend` 工具线（本构建不懂它的样式/锚点语义）→ updateDrawingAnchor 拒绝")
    func unsupportedToolTypeRejectsAnchorEdit() throws {
        let e = TrainingEngine.preview()
        // 造法照抄 DrawingEditDurabilityGateTests.unimplementedToolLineIsPreservedNotEditable
        // 的既有 `.trend` fixture（同样的锚点值 period:.daily/candleIndex:3/price:10，便于跟
        // engineWithOneLine() 的对照直接对比）。
        let trend = DrawingObject(id: "T", toolType: .trend,
                                  anchors: [DrawingAnchor(period: .daily, candleIndex: 3, price: 10)],
                                  isExtended: false, panelPosition: 0, period: .daily)
        #expect(e.appendDrawing(trend) == true)   // 进得来（append 宽松，PR-1 行为）
        let before = e.drawings
        let rev = e.drawingsRevision
        let newAnchor = DrawingAnchor(period: .daily, candleIndex: 10, price: 99)
        #expect(e.updateDrawingAnchor(id: "T", anchorIndex: 0, anchor: newAnchor) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("T7-②b 对照：同样的锚点、换回 `.horizontal`（本构建懂的工具）→ 改锚点成功")
    func supportedToolTypeAcceptsAnchorEdit() throws {
        let (e, line) = Self.engineWithOneLine()   // toolType == .horizontal，锚点同为 daily/3/10
        let newAnchor = DrawingAnchor(period: line.period, candleIndex: 10, price: 99)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: newAnchor) == true)
        #expect(e.drawings.first(where: { $0.id == line.id })?.anchors[0] == newAnchor)
        #expect(e.drawingsRevision == rev + 1)
    }

    // ── ③a raw-aware：未来未知枚举值 ──
    // 造法复用 DrawingTestFixtures 的 `makeEngineWithLossy` + `lossyFromRaw`（引擎 upper=lower=.m3，
    // raw 里的 period 必须是 "3m"）；两条 raw 同 id "F"，仅 colorToken/textColorToken 从
    // "futureNeon"/"futureCyan"（未来值）换成已知值 "orange" —— 逐字照抄
    // DrawingEditDurabilityGateTests.futureRaw 的构造模式（该文件里的字符串是 private，故在本文件
    // 重新写一份，字段内容与来源一致）。

    private let futureEnumAnchorRaw = #"{"id":"F","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"futureNeon","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"futureCyan","textForm":"plain"}"#

    private let plainSameIdAnchorRaw = #"{"id":"F","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#

    @Test("T7-③a 违规：携带未来未知枚举值的线 → updateDrawingAnchor 拒绝，逐字段不变")
    func futureEnumValueRejectsAnchorEdit() throws {
        let e = makeEngineWithLossy(try lossyFromRaw(futureEnumAnchorRaw))
        #expect(e.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: ["F"]) == true)   // 前提成立
        let before = e.drawings
        let rev = e.drawingsRevision
        let newAnchor = DrawingAnchor(period: .m3, candleIndex: 5, price: 20)
        #expect(e.updateDrawingAnchor(id: "F", anchorIndex: 0, anchor: newAnchor) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("T7-③a 对照：同 id 换成不带未来数据的线、其余一致 → 改锚点成功")
    func plainVersionOfSameIdAcceptsAnchorEdit() throws {
        let e = makeEngineWithLossy(try lossyFromRaw(plainSameIdAnchorRaw))
        #expect(e.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: ["F"]) == false)  // 成因已去掉
        let rev = e.drawingsRevision
        let newAnchor = DrawingAnchor(period: .m3, candleIndex: 5, price: 20)
        #expect(e.updateDrawingAnchor(id: "F", anchorIndex: 0, anchor: newAnchor) == true)
        #expect(e.drawings.first(where: { $0.id == "F" })?.anchors[0] == newAnchor)
        #expect(e.drawingsRevision == rev + 1)
    }

    // ── ③b raw-aware：未来顶层字段 ──
    // 造法同上，逐字照抄 DrawingEditDurabilityGateTests.futureTopLevelFieldRejectsStyleEdit 的
    // `futureIndependentTextColor` fixture 模式（该字符串同样 private，本文件重写一份）。

    private let futureFieldAnchorRaw = #"{"id":"X","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","futureIndependentTextColor":true}"#

    private let plainSameIdFieldAnchorRaw = #"{"id":"X","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#

    @Test("T7-③b 违规：携带未来顶层字段的线 → updateDrawingAnchor 拒绝，逐字段不变")
    func futureFieldRejectsAnchorEdit() throws {
        let e = makeEngineWithLossy(try lossyFromRaw(futureFieldAnchorRaw))
        #expect(e.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: ["X"]) == false)  // 枚举门看不见
        #expect(e.loadedDrawingsLossy.hasKnownFutureFields(liveIds: ["X"]) == true)       // 字段门抓得到
        let before = e.drawings
        let rev = e.drawingsRevision
        let newAnchor = DrawingAnchor(period: .m3, candleIndex: 5, price: 20)
        #expect(e.updateDrawingAnchor(id: "X", anchorIndex: 0, anchor: newAnchor) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("T7-③b 对照：同 id 去掉未来顶层字段、其余一致 → 改锚点成功")
    func plainVersionOfSameIdWithoutFutureFieldAcceptsAnchorEdit() throws {
        let e = makeEngineWithLossy(try lossyFromRaw(plainSameIdFieldAnchorRaw))
        #expect(e.loadedDrawingsLossy.hasKnownFutureFields(liveIds: ["X"]) == false)  // 成因已去掉
        let rev = e.drawingsRevision
        let newAnchor = DrawingAnchor(period: .m3, candleIndex: 5, price: 20)
        #expect(e.updateDrawingAnchor(id: "X", anchorIndex: 0, anchor: newAnchor) == true)
        #expect(e.drawings.first(where: { $0.id == "X" })?.anchors[0] == newAnchor)
        #expect(e.drawingsRevision == rev + 1)
    }

    // ── ④ 下标越界 ──
    // ⚠️ spec 变异表已登记：把这道门拿掉之后，越界是 **trap（进程直接崩）**而不是测试失败——
    //    故本档只按常规写「返 false」的断言，不做「拿掉它会红」的实证（拿掉会崩，不会红）。

    @Test("T7-④ 违规：anchorIndex 越界（该线只有 1 个锚点）→ updateDrawingAnchor 拒绝，不 trap")
    func outOfRangeAnchorIndexRejectsAnchorEdit() throws {
        let (e, line) = Self.engineWithOneLine()
        let before = e.drawings
        let rev = e.drawingsRevision
        let newAnchor = DrawingAnchor(period: line.period, candleIndex: 10, price: 99)
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 99, anchor: newAnchor) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("T7-④ 对照：anchorIndex 在范围内（0）、其余一致 → 改锚点成功")
    func inRangeAnchorIndexAcceptsAnchorEdit() throws {
        let (e, line) = Self.engineWithOneLine()
        let newAnchor = DrawingAnchor(period: line.period, candleIndex: 10, price: 99)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: newAnchor) == true)
        #expect(e.drawings.first(where: { $0.id == line.id })?.anchors[0] == newAnchor)
        #expect(e.drawingsRevision == rev + 1)
    }

    // ── ⑤ 周期不符 ──

    @Test("T7-⑤ 违规：锚点 period 与线的 period 不同 → updateDrawingAnchor 拒绝，逐字段不变")
    func mismatchedPeriodRejectsAnchorEdit() throws {
        let (e, line) = Self.engineWithOneLine()   // line.period == .daily
        #expect(line.period != .m3)
        let before = e.drawings
        let rev = e.drawingsRevision
        let wrongPeriodAnchor = DrawingAnchor(period: .m3, candleIndex: 10, price: 99)
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: wrongPeriodAnchor) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("T7-⑤ 对照：锚点 period 与线一致、其余一致 → 改锚点成功")
    func matchingPeriodAcceptsAnchorEdit() throws {
        let (e, line) = Self.engineWithOneLine()
        let rightPeriodAnchor = DrawingAnchor(period: line.period, candleIndex: 10, price: 99)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: rightPeriodAnchor) == true)
        #expect(e.drawings.first(where: { $0.id == line.id })?.anchors[0] == rightPeriodAnchor)
        #expect(e.drawingsRevision == rev + 1)
    }
}

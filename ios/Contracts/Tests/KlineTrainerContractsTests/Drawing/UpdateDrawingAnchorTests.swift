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
}

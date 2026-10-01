// ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/NodeDragSourceGuardTests.swift
// Spec: 2026-09-29-drawing-p1c-3-node-drag Task 12（G2–G15）。
// 结构守卫：拖节点功能本身（Task 1–11）已经做完、行为测试已经覆盖。这里钉的是「行为测试测不到、
// 但一旦有人改坏就会静默出事」的**结构不变量**——起手路径上不该出现的类型、十个写入门必须
// 恰好覆盖同一个判据、两个状态必须同生同死——这些都不是「输出对不对」，是「写法对不对」，
// 只有读源码文本才能证明。反踩坑（memory: acceptance grep 两坑）：先剥掉注释行再匹配。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("P1c-3 源码守卫（G2–G15）")
struct NodeDragSourceGuardTests {

    /// ios/Contracts 目录（照 DrawingGestureSourceGuardTests 的四层上溯写，⛔ 不新造一套）。
    private var contractsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // ChartEngine
            .deletingLastPathComponent()    // KlineTrainerContractsTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // ios/Contracts
    }

    /// 读源码并**剥掉注释**后返回（整行注释丢弃；行尾 `//` 之后截断）。照既有守卫同款写法。
    private func source(_ relativeToContracts: String) throws -> String {
        let url = contractsDir.appendingPathComponent(relativeToContracts)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }

    private let chartContainer = "Sources/KlineTrainerContracts/Render/ChartContainerView.swift"
    private let klineView      = "Sources/KlineTrainerContracts/Render/KLineView.swift"
    private let editRouter     = "Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift"
    private let session        = "Sources/KlineTrainerContracts/Drawing/DrawingSession.swift"
    private let renderBuilder  = "Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift"

    /// 切出某个函数体：从签名到**括号配平**的那个 `}`（用括号深度计数，不是靠缩进猜）。
    /// 找不到签名，或签名后找不到 `{`，或括号在文件结束前没配平 ⇒ 返回 nil，调用方必须 `Issue.record`。
    /// 用括号深度（而不是「下一个同缩进 `}`」）是刻意的：本文件里要切的函数有的签名跨多行
    /// （如 `applyNodeDragOverride`），「签名那一行的缩进」在那种写法下并不等于「函数体那一层的缩进」，
    /// 括号配平对两种写法都成立，且已经被下面的 `sliceHelperIsNotVacuous` 自检覆盖（含单行函数样本）。
    private func body(of signature: String, in code: String) -> String? {
        guard let sigRange = code.range(of: signature) else { return nil }
        // 签名字符串本身可能已经带着函数的开括号（大多数直接签名都这么传），也可能没带
        // （跨行签名/闭包赋值那几个，`{` 在后面另一行）——两种写法都要支持，不能只认一种。
        var depth = 1
        var idx: String.Index
        if signature.trimmingCharacters(in: .whitespaces).hasSuffix("{") {
            idx = sigRange.upperBound   // 签名已含开括号：深度从 1 起，直接从签名之后扫
        } else {
            guard let braceStart = code.range(of: "{", range: sigRange.upperBound..<code.endIndex) else { return nil }
            idx = braceStart.upperBound  // 签名不含开括号：先找到它，深度从 1 起
        }
        while idx < code.endIndex {
            let ch = code[idx]
            if ch == "{" { depth += 1 } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(code[sigRange.lowerBound..<code.index(after: idx)])
                }
            }
            idx = code.index(after: idx)
        }
        return nil   // 括号没配平（文件被截断/签名切错）—— 保守返回 nil
    }

    /// 二级切片：在**已经切好**的函数体里，从某个 `case` 头切到下一个 `case` 头（或切到末尾）。
    /// 与 `body(of:)` 不同——case 分支不是自带配对括号的语法单位，只能按文本锚点切。
    /// 找不到 `caseHeader` ⇒ nil；**给了 `until:` 但找不到 `nextHeader`** 同样 ⇒ nil（⛔ 不许静默退化成
    /// "切到末尾"——那会在 case 标签改名之后悄悄切出一个过宽的切片，诊断指错方向。只有**没给** `until:`
    /// 时"切到末尾"才是正常语义，两条路径不共用同一句 `return`）。调用方必须 `Issue.record`。
    private func caseSlice(_ caseHeader: String, in code: String, until nextHeader: String? = nil) -> String? {
        guard let start = code.range(of: caseHeader) else { return nil }
        guard let nextHeader else {
            return String(code[start.lowerBound..<code.endIndex])   // 没给 until：按原语义切到末尾
        }
        guard let end = code.range(of: nextHeader, range: start.upperBound..<code.endIndex) else {
            return nil   // 给了 until 但找不到 nextHeader ⇒ 锚点失效，不是"切到末尾"
        }
        return String(code[start.lowerBound..<end.lowerBound])
    }

    // MARK: - G2

    @Test("G2 起手路径（按下捕获候选）上不得出现 DrawingHitTester——命中走的是节点几何，不是线几何")
    func probeDoesNotConsultLines() throws {
        let code = try source(chartContainer)
        guard let b = body(of: "private func captureNodeDragCandidate(at point: CGPoint) {", in: code) else {
            Issue.record("切片锚点找不到 —— captureNodeDragCandidate 被改名/改签名？守卫失效，必须修"); return
        }
        #expect(b.contains("hitTestNode("))      // 防切片为空/切错 → 负向断言假绿
        #expect(!b.contains("DrawingHitTester"))
    }

    // MARK: - G3①

    @Test("G3① 触摸按下的处理必须纯只读：不得出现 settleDeceleration / rebuildRenderState")
    func touchDownHandlerIsReadOnly() throws {
        let code = try source(chartContainer)
        guard let b = body(of: "private func captureNodeDragCandidate(at point: CGPoint) {", in: code) else {
            Issue.record("切片锚点找不到 —— captureNodeDragCandidate 被改名/改签名？守卫失效，必须修"); return
        }
        #expect(b.contains("nodeDragPreconditions("))   // 防切片为空
        #expect(!b.contains("settleDeceleration("))
        #expect(!b.contains("rebuildRenderState("))
    }

    // MARK: - G3②

    @Test("G3② 拖动 .began 的四步顺序：settle → rebuild → 读 viewport → CoordinateMapper（顺序 load-bearing）")
    func nodeDragBeganOrder() throws {
        let code = try source(chartContainer)
        guard let b = body(of: "private func handleNodeDrag(translation: CGPoint, phase: GesturePhase) {", in: code)
        else { Issue.record("切片锚点找不到 —— handleNodeDrag 被改名/改签名？守卫失效，必须修"); return }
        guard let settle = b.range(of: "settleDeceleration(initiatedBy:"),
              let rebuild = b.range(of: "rebuildRenderState(", range: settle.upperBound..<b.endIndex),
              let vpRead = b.range(of: "view.renderState.viewport"),
              let mapper = b.range(of: "CoordinateMapper(") else {
            Issue.record("handleNodeDrag 的 .began 四个锚点（settle/rebuild/viewport 读取/CoordinateMapper）缺一个")
            return
        }
        #expect(settle.lowerBound < rebuild.lowerBound)   // ⭐先停再重建
        #expect(rebuild.lowerBound < vpRead.lowerBound)   // ⭐viewport 必须重建之后才读
        #expect(vpRead.lowerBound < mapper.lowerBound)    // ⭐读到的这个 viewport 才拿去建 mapper
    }

    // MARK: - G4

    @Test("G4 探针（nodeDragPreconditions）不得自己重抄 editableIgnoringGeometry 的非几何清单")
    func probeDoesNotReimplementGateList() throws {
        let code = try source(editRouter)
        guard let b = body(of: "static func nodeDragPreconditions(engine: TrainingEngine, panel: PanelId, point: CGPoint) -> Bool {", in: code)
        else { Issue.record("切片锚点找不到 —— nodeDragPreconditions 被改名/改签名？守卫失效，必须修"); return }
        #expect(b.contains("editableIgnoringGeometry("))   // 正向：确实调用了那份唯一清单，防切片为空
        for banned in ["locked", "hasKnownFutureEnumValues", "isEditableToolType", "flow.mode"] {
            #expect(!b.contains(banned), "nodeDragPreconditions 里重抄了 editableIgnoringGeometry 的判据：\(banned)")
        }
    }

    // MARK: - G6

    @Test("G6 拖动 .began 不得重做几何命中（hitTestNode）；按下处理里必须有")
    func beganDoesNotRehitTest() throws {
        let code = try source(chartContainer)
        guard let probeBody = body(of: "private func captureNodeDragCandidate(at point: CGPoint) {", in: code) else {
            Issue.record("切片锚点找不到 —— captureNodeDragCandidate 被改名/改签名？守卫失效，必须修"); return
        }
        guard let dragBody = body(of: "private func handleNodeDrag(translation: CGPoint, phase: GesturePhase) {", in: code)
        else { Issue.record("切片锚点找不到 —— handleNodeDrag 被改名/改签名？守卫失效，必须修"); return }
        guard let beganOnly = caseSlice("case .began:", in: dragBody, until: "case .changed:") else {
            Issue.record("handleNodeDrag 里找不到 case .began: —— 守卫失效，必须修"); return
        }
        #expect(probeBody.contains("hitTestNode("))   // 按下处理：必须有（防两侧切片都空导致两条都空洞成立）
        // ⭐ 修复环第 1/5 轮 S4：上面那条对 probeBody 的正向断言防不了 beganOnly 自己切空——
        //   若 beganOnly 真的切成了空串（如 caseHeader 紧跟 nextHeader），下面的负向断言会恒真。
        //   补一条**同切片**的正向断言：.began 分支体内必然存在、且在分支偏后位置的调用。
        #expect(beganOnly.contains("beginNodeDrag("))
        #expect(!beganOnly.contains("hitTestNode("))  // .began：不得重做
    }

    // MARK: - G7

    @Test("G7 触摸按下钩子只在单点触摸时发：判据必须用 event 的全量触摸数，不是 touches.count")
    func touchDownHookIsSingleTouchOnly() throws {
        let code = try source(klineView)
        guard let b = body(of: "public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {", in: code)
        else { Issue.record("切片锚点找不到 —— touchesBegan 被改名/改签名？守卫失效，必须修"); return }
        #expect(b.contains("onTouchDown?("))        // 防切片为空
        // ⚠️ touches 只含**本次新增**的触摸——第二指落下时它也是 1；必须读 event 的全量 allTouches。
        #expect(b.contains("event?.allTouches?.count ?? touches.count"))
    }

    // MARK: - G8

    @Test("G8 候选清除点的覆盖：4 处字面清空，分落 3 个作用域（按下自覆盖 / 多指 fail-closed / began 消费或放弃），且 .ended/.cancelled 里没有")
    func candidateClearSitesAreExactlyFour() throws {
        let code = try source(chartContainer)
        // ⚠️ 与简报原文的「三处」字面不同——按**行**数的是 4（见本文件 report 的订正记录），
        //    按**作用域**数（capture 自覆盖 / onMultiTouchBegan / handleNodeDrag.began 的两条退出路径）才是 3。
        //    本守卫按**可机械验证**的「行」计数，并逐一钉死它们分别落在哪个作用域。
        guard let probeBody = body(of: "private func captureNodeDragCandidate(at point: CGPoint) {", in: code) else {
            Issue.record("切片锚点找不到 —— captureNodeDragCandidate 被改名/改签名？守卫失效，必须修"); return
        }
        guard let multiTouchBody = body(of: "self.view?.onMultiTouchBegan = ", in: code) else {
            Issue.record("切片锚点找不到 —— onMultiTouchBegan 赋值闭包被改写？守卫失效，必须修"); return
        }
        guard let dragBody = body(of: "private func handleNodeDrag(translation: CGPoint, phase: GesturePhase) {", in: code)
        else { Issue.record("切片锚点找不到 —— handleNodeDrag 被改名/改签名？守卫失效，必须修"); return }
        guard let beganOnly = caseSlice("case .began:", in: dragBody, until: "case .changed:"),
              let endedOnly = caseSlice("case .ended, .cancelled:", in: dragBody) else {
            Issue.record("handleNodeDrag 里 case .began: / case .ended, .cancelled: 找不到 —— 守卫失效，必须修"); return
        }
        func clearCount(_ s: String) -> Int { s.components(separatedBy: "nodeDragCandidate = nil").count - 1 }
        #expect(clearCount(probeBody) == 1)                           // 作用域①：按下自覆盖旧候选
        #expect(clearCount(multiTouchBody) == 1)                      // 作用域②：多指 fail-closed
        #expect(clearCount(beganOnly) == 2)                           // 作用域③：消费成功 / 取不到几何都清
        #expect(clearCount(endedOnly) == 0)                           // 反向：终止相位不碰候选（候选只在 .began 有意义）
        let total = clearCount(code)
        #expect(total == 4, "全文件「nodeDragCandidate = nil」字面处数应为 4（1+1+2），实为 \(total)")
    }

    // MARK: - G9

    @Test("G9 探针与复核调同一具名判据（nodeDragPreconditions），且复核另有身份比对（探针没有）")
    func probeAndRevalidationShareOnePredicate() throws {
        let code = try source(chartContainer)
        guard let probeBody = body(of: "private func captureNodeDragCandidate(at point: CGPoint) {", in: code) else {
            Issue.record("切片锚点找不到 —— captureNodeDragCandidate 被改名/改签名？守卫失效，必须修"); return
        }
        guard let acceptBody = body(of: "private func acceptNodeDragCandidate() -> Bool {", in: code) else {
            Issue.record("切片锚点找不到 —— acceptNodeDragCandidate 被改名/改签名？守卫失效，必须修"); return
        }
        #expect(probeBody.contains("nodeDragPreconditions("))     // 方向①：探针调它
        #expect(acceptBody.contains("nodeDragPreconditions("))    // 方向②：复核也调它（同一个，不是另写一份）
        #expect(acceptBody.contains("selectedDrawingID == c.drawingID"))   // 方向③：复核另有身份比对
        #expect(!probeBody.contains("selectedDrawingID == "))     // 对照：探针没有这一步（身份还没成立）
    }

    // MARK: - G10

    @Test("G10 渲染读路径（applyNodeDragOverride）零写入")
    func renderReadPathHasNoWrites() throws {
        let code = try source(renderBuilder)
        guard let b = body(of: "private static func applyNodeDragOverride(", in: code) else {
            Issue.record("切片锚点找不到 —— applyNodeDragOverride 被改名/改签名？守卫失效，必须修"); return
        }
        #expect(b.contains("session.nodeDragOwner"))   // 防切片为空
        for banned in ["updateDrawingAnchor", "endNodeDrag", "finalizeNodeDragInPlace", "drawingsRevision"] {
            #expect(!b.contains(banned), "渲染读路径里出现了写入调用：\(banned)")
        }
    }

    // MARK: - G11

    @Test("G11 身份判据（activeNodeDrag）是一个具名函数，.changed / .ended-.cancelled 两处调用点共用它、不重抄身份比较")
    func identityPredicateIsSharedByThreePhases() throws {
        let code = try source(chartContainer)
        guard let dragBody = body(of: "private func handleNodeDrag(translation: CGPoint, phase: GesturePhase) {", in: code)
        else { Issue.record("切片锚点找不到 —— handleNodeDrag 被改名/改签名？守卫失效，必须修"); return }
        guard let changedOnly = caseSlice("case .changed:", in: dragBody, until: "case .ended, .cancelled:"),
              let endedOnly = caseSlice("case .ended, .cancelled:", in: dragBody) else {
            Issue.record("handleNodeDrag 里 case .changed: / case .ended, .cancelled: 找不到 —— 守卫失效，必须修"); return
        }
        #expect(changedOnly.contains("activeNodeDrag()"))   // 方向①：.changed 调它
        #expect(endedOnly.contains("activeNodeDrag()"))     // 方向②：.ended/.cancelled 也调它（同一个）
        // 反向：两个分支体内不得出现身份比较的字面——那应该全部折在 activeNodeDrag() 内部。
        for banned in ["selectedDrawingID", "selectedPanel"] {
            #expect(!changedOnly.contains(banned), ".changed 分支重抄了身份比较：\(banned)")
            #expect(!endedOnly.contains(banned), ".ended/.cancelled 分支重抄了身份比较：\(banned)")
        }
    }

    // MARK: - G12

    @Test("G12 点击选中两入口（setSelection / setCommittedSelection）各自有门、且门都是共用判据，不是各抄一份")
    func tapSelectionGatesAreShared() throws {
        let code = try source(session)
        guard let setSel = body(of: "func setSelection(id: DrawingID, panel: PanelId) {", in: code) else {
            Issue.record("切片锚点找不到 —— setSelection 被改名/改签名？守卫失效，必须修"); return
        }
        guard let setCommitted = body(of: "func setCommittedSelection(id: DrawingID, panel: PanelId) {", in: code) else {
            Issue.record("切片锚点找不到 —— setCommittedSelection 被改名/改签名？守卫失效，必须修"); return
        }
        for (name, b) in [("setSelection", setSel), ("setCommittedSelection", setCommitted)] {
            #expect(b.contains("assignSelection("), "\(name) 防切片为空")
            #expect(b.contains("tapSelectionAllowed()"), "\(name) 必须调共用判据")
            #expect(!b.contains("nodeDragOwner == nil"), "\(name) 不得自己重抄 tapSelectionAllowed 的判据")
        }
    }

    // MARK: - G13

    @Test("G13「没有选中 ⇒ 没有拖动态」由构造保证：clearSelection / assignSelection 都调 endNodeDrag，全文件恰好 2 个调用点")
    func clearSelectionDiscardsDrag() throws {
        let code = try source(session)
        guard let clear = body(of: "func clearSelection() {", in: code) else {
            Issue.record("切片锚点找不到 —— clearSelection 被改名/改签名？守卫失效，必须修"); return
        }
        guard let assign = body(of: "private func assignSelection(id: DrawingID, panel: PanelId) {", in: code) else {
            Issue.record("切片锚点找不到 —— assignSelection 被改名/改签名？守卫失效，必须修"); return
        }
        #expect(clear.contains("selectedDrawingID = nil"))   // 防切片为空
        #expect(clear.contains("endNodeDrag()"))             // 方向①：没有选中 ⇒ 不可能有拖动
        #expect(assign.contains("endNodeDrag()"))            // 方向②：换了选中 ⇒ 不可能有拖动
        // 全文件处数恰好：endNodeDrag 的**定义**之外，只应有这两处调用（防第三处悄悄长出另一份“清槧”逻辑）。
        let callCount = code.components(separatedBy: "endNodeDrag()").count - 1 - 1   // 减定义行自身的一次出现
        #expect(callCount == 2, "endNodeDrag() 的调用点应恰好 2 个，实为 \(callCount)")
    }

    // MARK: - G14

    /// 从「@discardableResult」紧跟的下一行取 `static func <name>(` 的 `<name>`。
    private func discardableResultFunctionNames(in code: String) -> Set<String> {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var names: Set<String> = []
        for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "@discardableResult" {
            var j = i + 1
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
            guard j < lines.count, let r = lines[j].range(of: "func ") else { continue }
            let rest = lines[j][r.upperBound...]
            if let paren = rest.firstIndex(of: "(") { names.insert(String(rest[rest.startIndex..<paren])) }
        }
        return names
    }

    /// 全文件按字面扫 `func <name>Enabled(` 形态的函数名（`<name>` 以 `Enabled` 结尾）。
    private func enabledPredicateNames(in code: String) -> Set<String> {
        var names: Set<String> = []
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            guard line.contains("Enabled("), let r = line.range(of: "func ") else { continue }
            let rest = line[r.upperBound...]
            if let paren = rest.firstIndex(of: "("), rest[rest.startIndex..<paren].hasSuffix("Enabled") {
                names.insert(String(rest[rest.startIndex..<paren]))
            }
        }
        return names
    }

    @Test("G14 拖动门的覆盖是集合等式：{写入入口} ∪ {Enabled 谓词} 恰好 10 个，每个都调 nodeDragInFlight；且该判据读 nodeDragOwner 不读 nodeDragCurrent")
    func dragGateCoverageIsSetEquality() throws {
        let code = try source(editRouter)
        let writes = discardableResultFunctionNames(in: code)
        let enabled = enabledPredicateNames(in: code)
        // ⛔ 「这几个各自存在」抓不到“多出来的第十一个”——必须是集合等式，不是逐个 contains。
        #expect(writes == ["applyStyle", "deleteSelected", "toggleLockSelected", "undo", "redo"])
        #expect(enabled == ["styleControlsEnabled", "deleteButtonEnabled", "lockButtonEnabled",
                            "undoButtonEnabled", "redoButtonEnabled"])
        for name in writes.union(enabled) {
            guard let b = body(of: "static func \(name)(", in: code) else {
                Issue.record("切片锚点找不到 —— \(name) 被改名/改签名？守卫失效，必须修"); continue
            }
            #expect(b.contains("nodeDragInFlight("), "\(name) 必须经 nodeDragInFlight 挡拖动中")
        }
        // 反向：共用判据本身读的是参与 observation 的那一半，⛔ 不是 @ObservationIgnored 的那一半——
        // 读错了 host 测照样全绿，真机上控件却不会变灰。
        guard let gate = body(of: "static func nodeDragInFlight(engine: TrainingEngine) -> Bool {", in: code) else {
            Issue.record("切片锚点找不到 —— nodeDragInFlight 被改名/改签名？守卫失效，必须修"); return
        }
        #expect(gate.contains("nodeDragOwner"))
        #expect(!code.contains("nodeDragCurrent"), "DrawingEditRouter.swift 不该出现 nodeDragCurrent 字面——那是 @ObservationIgnored 的那一半")
    }

    // MARK: - G15

    @Test("G15 nodeDragOwner 与 nodeDragCurrent 同生同死：beginNodeDrag / endNodeDrag 各自两半一起写，全文件 nodeDragOwner 赋值恰好 2 处")
    func bothHalvesAreAssignedTogether() throws {
        let code = try source(session)
        guard let begin = body(of: "func beginNodeDrag(_ owner: NodeDragOwner, anchor: DrawingAnchor) {", in: code) else {
            Issue.record("切片锚点找不到 —— beginNodeDrag 被改名/改签名？守卫失效，必须修"); return
        }
        guard let end = body(of: "func endNodeDrag() {", in: code) else {
            Issue.record("切片锚点找不到 —— endNodeDrag 被改名/改签名？守卫失效，必须修"); return
        }
        #expect(begin.contains("nodeDragOwner = owner") && begin.contains("nodeDragCurrent = anchor"))
        #expect(end.contains("nodeDragOwner = nil") && end.contains("nodeDragCurrent = nil"))
        // 反向自检：全文件对 nodeDragOwner 的字面赋值（`= `，排除 `==`）只应有这两处——
        // 没有第三处能把两半拆开写（updateNodeDragCurrent 只写 current 那一半，但它守着
        // `guard nodeDragOwner != nil` 不触碰 owner，故不计入「赋值」，只计 `nodeDragOwner =` 字面）。
        let ownerAssigns = code.components(separatedBy: "nodeDragOwner = ").count - 1
        #expect(ownerAssigns == 2, "nodeDragOwner 的字面赋值应恰好 2 处，实为 \(ownerAssigns)")
    }

    // MARK: - 切片工具自身双向自检（⛔ 判据自己不能空转）

    @Test("G 系列的切片工具自身双向自检")
    func sliceHelperIsNotVacuous() {
        // ⚠️ 下面这三组签名字面（"func f()" / "func h(" / "func zzzNoSuch()"）**全都不以 `{` 收尾**——
        //   它们只覆盖 `body(of:)` 里"签名不带 `{`"那一支，从未执行过"签名自带 `{`"那一支
        //   （修复环第 1/5 轮 Important：评审用变异证明过，把 `hasSuffix("{")` 那行改成 `if false`
        //   这三组样本仍然全绿，而 12 条生产守卫当场红——真正兜住那次 bug 回归的是生产守卫自己，
        //   不是这三组）。"签名自带 `{`" 那一支由下面新增的第 4 组样本 `guardFirstLine` 覆盖。
        let good = "func f() { a() }\nfunc g() { b() }"
        #expect(body(of: "func f()", in: good)?.contains("a(") == true)
        #expect(body(of: "func f()", in: good)?.contains("b(") == false, "切片吃到了下一个函数")
        #expect(body(of: "func zzzNoSuch()", in: good) == nil, "找不到时必须返回 nil 让调用方 Issue.record")
        // 多行签名样本（照 applyNodeDragOverride 的真实写法：签名跨行，`{` 在第二行末；签名字面同样不带 `{`）。
        let multiline = "func h(_ x: Int,\n       y: Int) {\n    use(x, y)\n}\nfunc i() { other() }"
        #expect(body(of: "func h(", in: multiline)?.contains("use(") == true)
        #expect(body(of: "func h(", in: multiline)?.contains("other(") == false, "切片吃到了下一个函数")
        // 第 4 组（修复环第 1/5 轮新增）：签名**自带 `{`**，且函数体**第一行就是**
        // `guard … else { return }`——这正是原 bug 的精确触发形状：若签名被误判成"不带 `{`"，
        // 会去找签名之后**下一个** `{`，而那恰好是这条 guard 自己的 `{`，于是在它的 `}` 处就提前
        // 收口，切不到函数末尾的 MARKER_END()。断言的是**同一个切片**里末尾附近的独有标记，
        // 不是只断言"非空"（空字符串也能通过"非 nil"检查，但过不了这条 contains）。
        let guardFirstLine = "func j() {\n    guard cond else { return }\n    MARKER_END()\n}\nfunc k() { other2() }"
        #expect(body(of: "func j() {", in: guardFirstLine)?.contains("MARKER_END(") == true)
        #expect(body(of: "func j() {", in: guardFirstLine)?.contains("other2(") == false, "切片吃到了下一个函数")
        // caseSlice 自检：找得到头 / 找不到头 / 给了 until 但 nextHeader 找不到（⛔ 不许退化成切到末尾）。
        let withCases = "case .a:\n    foo()\ncase .b:\n    bar()"
        #expect(caseSlice("case .a:", in: withCases, until: "case .b:")?.contains("foo(") == true)
        #expect(caseSlice("case .a:", in: withCases, until: "case .b:")?.contains("bar(") == false)
        #expect(caseSlice("case .zzz:", in: withCases) == nil)
        #expect(caseSlice("case .a:", in: withCases, until: "case .zzzNoSuch:") == nil,
                "给了 until 但找不到 nextHeader 时必须返回 nil，不能静默切到末尾")
    }
}

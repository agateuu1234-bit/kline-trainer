// ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift
// PR-4：交互 UI 与视口发布的接线守卫。**刻意不是 UIKit-gated** —— 它读源码文本，不需要 UIKit 渲染，
// 放 host 才能在每个 Task 里立刻拿到证据（View 的真实渲染断言另有 Catalyst 测试）。
// 文本来源纪律见计划 PD7：否定/结构断言走 `code()`（剥注释剥字面量），用户可见文案走 `raw()`。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("PR-4 交互 UI 接线守卫")
struct DrawingInteractionUISourceGuardTests {

    /// **剥注释、剥字符串字面量内容、删空白**的代码文本。**所有否定断言与结构断言都必须用它**
    /// （PD7）：读原始文本会被计划里那些「为什么不是 X」的承重注释打红，逼实施者删注释才能过测试。
    private func code(_ rel: String) throws -> String {
        try squeezedSource(contractsDirForGuards.appendingPathComponent(rel).path)
    }

    /// 原始文本。**只用于两件事**：① 用户可见文案（`squeezedSource` 会丢弃字符串字面量内容，
    /// 文案断言在它上面恒假）；② 「陈旧注释必须删掉」这类**对象就是注释**的断言。
    private func raw(_ rel: String) throws -> String {
        try String(contentsOfFile: contractsDirForGuards.appendingPathComponent(rel).path, encoding: .utf8)
    }

    @Test("PD1（codex plan-R3-F2 的确定性防线）：Coordinator 发布的是 `newState.viewport`，且它**不许**自己重推视口")
    func publisherUsesRenderedViewportOnly() throws {
        let cc = try code("Sources/KlineTrainerContracts/Render/ChartContainerView.swift")
        #expect(cc.contains(squeeze("CoordinateMapper(viewport: newState.viewport,")),
                "必须发布这一帧渲染真用过的视口")
        // 重推的入口一次都不许在本文件的**代码**里出现（注释里解释「为什么不重推」是正当的，故剥注释后判）
        #expect(!cc.contains("makeViewport"),
                "ChartContainerView 里出现了 makeViewport —— 重推的视口在聚合分支下与屏幕上的不一致（见 renderedViewportDivergesFromReDerivation）")
    }

    @Test("D57/PD4：setMode 在 Sources/ 里恰好 1 处调用，且在类型行 toggle 的接线上（不是 activate/deactivate）")
    func setModeHasExactlyOneCallSite() throws {
        let sites = try callSiteCount("setMode(")
        #expect(sites.count == 1 && sites.first?.count == 2,
                "setMode 应只出现在一个文件里、恰好两次（.draw / .select 两个方向），实际：\(sites)")
        #expect(sites.first?.file.hasSuffix("/UI/TrainingView.swift") == true,
                "唯一调用点必须在类型行 toggle 的接线处，实际：\(sites)")
        // 切回画线态**不得**走 activate（那是「开会话/换工具」的入口，会话本来就开着）。
        // 否定断言 → 剥注释后判（接线处的注释里正当地提到了 activate）。
        #expect(!(try code("Sources/KlineTrainerContracts/UI/TrainingView.swift"))
                    .contains(squeeze(".activate(tool:")), "切回画线态不得开新会话")
    }

    @Test("D38：图标点亮 == 画线态（判据是 mode，不是 activeDrawingTool 是否为 nil）")
    func typeIconLitMeansDrawMode() throws {
        let overlayCode = try code("Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift")
        #expect(overlayCode.contains("isDrawMode"), "图标亮灭必须由传入的 isDrawMode 决定")
        // 否定断言必须剥注释：本视图的文档注释里**正当地**写着「不是 activeDrawingTool == nil」（D57 的理由），
        // 读原始文本会被自己的注释打红（codex plan-R2-F1）。
        #expect(!overlayCode.contains("activeDrawingTool"),
                "D57 取代了 nil 编码 —— 视图层的**代码**里不得再用 activeDrawingTool 判态")
    }

    @Test("D38：作废的旧注释必须随本期删掉（否则文档与行为相反）—— 本条**刻意**读原始文本，它测的就是注释")
    func staleToggleCommentsRemoved() throws {
        let overlayRaw = try raw("Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift")
        #expect(overlayRaw.contains("DrawingTypeOverlay"), "先证明真读到了文件（防路径写错 → 空串 → 否定断言假绿）")
        for stale in ["不做 toggle", "本期短按 no-op", "恒亮"] {
            #expect(!overlayRaw.contains(stale), "作废注释仍在：\(stale)")
        }
    }

    @Test("交接⑥：复盘结构上进不去选择态 —— 类型行随样式面板挂载，而面板判据含 showsTradeButtons")
    func reviewCannotReachSelectMode() throws {
        let tvPath = contractsDirForGuards
            .appendingPathComponent("Sources/KlineTrainerContracts/UI/TrainingView.swift").path
        // 唯一的 toggle 入口在样式面板里，而面板可见性判据天然排除复盘（canBuySell()==false）
        #expect(try squeezedContains(tvPath,
            "private var stylePanelWillBeVisible: Bool { showsTradeButtons && isDrawingActive && typeRowExpanded }"))
        #expect(try squeezedContains(tvPath, "private var showsTradeButtons: Bool { engine.flow.canBuySell() }"))
        // 底栏同理：DrawingBottomBar 挂在 showsTradeButtons → isDrawingActive 分支内。
        // 邻接断言在**剥注释后**做——否则中间插一段注释就能把两者推开、守卫静默失效。
        let tv = try code("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        let dmb = try #require(tv.range(of: "DrawingBottomBar("), "DrawingBottomBar 未接入")
        #expect(String(tv[..<dmb.lowerBound].suffix(60)).contains(squeeze("if isDrawingActive {")))
    }
}

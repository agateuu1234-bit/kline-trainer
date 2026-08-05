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

    // ⭐fix round 1（评审变异 3 抓出，本 Task 自己的缺口）：`typeIconLitMeansDrawMode` 只查
    //   `isDrawMode` 这个**标识符存在**、`activeDrawingTool` **不存在**——把 `DrawingTypeOverlay.body`
    //   里描边色/前景色两处三元的 `isDrawMode ? … : …` 全改成常量 `Color.accentColor`，`isDrawMode`
    //   仍被 `accessibilityValue` 用着、`activeDrawingTool` 仍不出现，两条断言原样通过、全量测试零红——
    //   D38「图标点亮=画线态、熄灭=选择态」这条核心行为在 host 矩阵里因此是**零覆盖**的假设
    //   （该视图 UIKit-gated，Catalyst 才有像素级证据；但「三元有没有真绑 isDrawMode」是纯文本接线问题，
    //   不需要渲染就能测——不能把这条也推给 Catalyst）。
    //   两处**分别**断言（不用合并计数）：只改一处不绑 isDrawMode 时，未改的那条断言仍会因为改动的
    //   那一处缺失而单独变红，不依赖总数判据，杜绝「改一处漏网」。
    @Test("D38 fix round 1：描边色/前景色两处 ternary 都必须绑 isDrawMode（否则退化成恒亮/恒灭，Catalyst 之外无第二层覆盖）")
    func typeOverlayColorTernariesBothBoundToIsDrawMode() throws {
        let overlayCode = try code("Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift")
        #expect(overlayCode.contains(squeeze(
            ".stroke(isDrawMode ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 1.5)")),
            "描边色不是绑 isDrawMode 的三元——被硬编码成常量，图标会恒亮/恒灭")
        #expect(overlayCode.contains(squeeze(
            ".foregroundStyle(isDrawMode ? Color.accentColor : Color.secondary)")),
            "前景色不是绑 isDrawMode 的三元——被硬编码成常量，图标会恒亮/恒灭")
    }

    @Test("spec §1.1 #1 / PD5：底栏**恰好 2 个按钮**（类型 + ③🗑），②🔒④↩⑤↪ 属 1b-ii 一个都不渲染")
    func bottomBarHasExactlyTwoKeys() throws {
        let bar = try code("Sources/KlineTrainerContracts/UI/DrawingModeBar.swift")
        // ⚠️ **结构计数，不是「禁止图标名」黑名单**（PD7）：黑名单既漏（新图标名不在表里）
        //    又误伤注释（本视图注释里正当地写着 `locked` / 🔒 的去向）。恰好 2 个 `Button`
        //    机械且完备地表达了「只许有这两个控件」。`.buttonStyle` 是小写 b，不参与计数。
        #expect(bar.components(separatedBy: "Button").count - 1 == 2,
                "底栏按钮数不是 2 —— 多了就是把 1b-ii 的键提前 ship 了，少了就是 🗑 没接进来")
        #expect(bar.contains("deleteEnabled"), "🗑 必须由传入谓词置灰，不得自己判")
        #expect(bar.contains(squeeze(".disabled(!deleteEnabled)")))
        // 底栏与另两个 swap 底栏共享同一固定高度（既有不变量，别被本次改动碰掉）
        #expect(bar.contains("BottomBarMetrics.height"))
        // 用户可见文案 / SF Symbol 名是**字符串字面量** → squeezedSource 会丢弃它们，必须读原始文本，
        // 且带完整调用语法做锚（裸词会被注释里的同一个词假绿）。
        let barRaw = try raw("Sources/KlineTrainerContracts/UI/DrawingModeBar.swift")
        #expect(barRaw.contains("Text(\"类型\")"))
        #expect(barRaw.contains("Image(systemName: \"trash\")"), "③🗑 未接入")
        #expect(barRaw.contains(".accessibilityLabel(\"删除\")"))
    }

    @Test("spec §1.1 #5 / D65 R13-F1：🗑 只弹确认框；真正的删除在「删除」按钮的 action 里走路由")
    func deleteGoesThroughConfirmation() throws {
        // ① 用户可见文案 → 原始文本 + 完整调用语法锚
        let tvRaw = try raw("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(tvRaw.contains(".confirmationDialog(\"确定删除划线？\""))
        #expect(tvRaw.contains("Button(\"删除\", role: .destructive)"))
        #expect(tvRaw.contains("Button(\"取消\", role: .cancel)"))
        // ② 结构断言 → 剥注释后判
        let tv = try code("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        // 🗑 的 action **只置标志位**，绝不直接删（弹框有时间窗，线可能滑走 → N19e）。
        // 整段精确匹配，不用「取后 160 字符再找子串」那种会被排版/注释推偏的邻接判据。
        #expect(tv.contains(squeeze("onDelete: { confirmingDeleteDrawing = true }")),
                "🗑 的 action 必须只置标志位；出现别的语句即可能绕过确认框")
        // 唯一一处 deleteSelected 在确认框的「删除」按钮里
        #expect(tv.components(separatedBy: squeeze("DrawingEditRouter.deleteSelected(")).count - 1 == 1,
                "deleteSelected 在 TrainingView 的**代码**里应恰好出现 1 次")
        // 底栏置灰必须读 UI 观察量（deleteButtonEnabled），不得改用现算的 canDelete——两者语义在
        // DrawingEditRouter 里刻意分成两条路径（PD2：几何一现算给写入路由，一读 observable 提示给 UI），
        // canDelete 的几何分量非 @Observable 依赖，平移到线不可见时 SwiftUI 不会重绘、控件停在旧状态。
        #expect(tv.contains(squeeze("deleteEnabled: DrawingEditRouter.deleteButtonEnabled(engine: engine)")),
                "🗑 置灰必须接 deleteButtonEnabled（读提示），不得接 canDelete（现算）")
    }

    @Test("D49：面板样式是**派生值**，视图层既不存副本、也不自己从 DrawingObject 取字段")
    func panelStyleIsDerivedNotMirrored() throws {
        // 全部是否定/结构断言 → 一律剥注释后判（本视图的文档注释里正当地提到 `engine.drawings`、
        // `@State`、`session` 的去向，读原始文本会被自己的注释打红，codex plan-R2-F1）。
        let params = try code("Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift")
        #expect(params.contains(squeeze("let style: DrawingDefaultStyle")), "面板必须收调用方算好的派生值")
        #expect(!params.contains(squeeze("@State private var style")), "不得存第二份样式状态（常驻面板必然漂移）")
        #expect(!params.contains("session."), "面板的**代码**里不得再直读/直写 session —— 派生与路由都在调用方（D49）")
        #expect(!params.contains("engine."), "面板的**代码**里更不得直接碰引擎")
        // 5 个样式字段的逐字段取值只许出现在路由里（判据单点）
        let router = try code("Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift")
        #expect(router.contains(squeeze("s.lineSubType = d.lineSubType")))
        for f in ["lineSubType", "lineStyle", "thickness", "colorToken", "labelMode"] {
            #expect(!params.contains("d.\(f)"), "面板里出现了第二份派生：d.\(f)")
        }
    }

    @Test("D49 路由分流 + D65 置灰：有选中写路由、无选中写默认；enabled 来自 UI 版谓词")
    func panelRoutesBySelection() throws {
        let tv = try code("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(tv.contains(squeeze("DrawingEditRouter.panelStyle(engine: engine)")))
        #expect(tv.contains(squeeze("DrawingEditRouter.styleControlsEnabled(engine: engine)")))
        #expect(tv.contains(squeeze("DrawingEditRouter.deleteButtonEnabled(engine: engine)")))
        #expect(tv.contains(squeeze("DrawingEditRouter.applyStyle(")))
        #expect(tv.contains(squeeze("engine.drawingSession.setDefaultStyle(")))
        // 分流判据必须是「有没有选中」，不是别的
        #expect(tv.contains(squeeze("engine.drawingSession.selectedDrawingID != nil")))
        // applyStyle 在 Sources/ 里恰好 1 处（面板是唯一的样式写入入口，D58 末段：
        // 不得绕开面板另开编辑入口，否则 (ray,.left) 会变成只在编辑路径上可达的坏组合）
        let sites = try callSiteCount("DrawingEditRouter.applyStyle(")
        #expect(sites.count == 1 && sites.first?.count == 1, "applyStyle 调用点应恰好 1 处，实际：\(sites)")
    }

    // ⭐补（本 Task 自查发现的判别力缺口）：把 `.disabled(!enabled)` 从 DrawingStyleParams 根链删掉，
    //   跑一次全量 1794 测试——零条变红（`.opacity(enabled ? 1 : 0.4)` 只管视觉降饱和，控件此刻仍能点）。
    //   D65「改样式可用」若只降饱和不禁交互，灰态下仍能改样式/仍能污染选中线或默认，是真缺陷；
    //   `.disabled(!on)` 是逐选项那层已有覆盖，但整块面板级的 `.disabled(!enabled)` 此前无人守。
    @Test("D65：面板整体必须 `.disabled(!enabled)`（灰态禁交互，不止降饱和）")
    func panelDisablesInteractionNotJustOpacity() throws {
        let params = try code("Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift")
        #expect(params.contains(squeeze(".disabled(!enabled)")),
                "面板根链缺 .disabled(!enabled) —— 置灰时用户仍能点开控件改样式")
        #expect(params.contains(squeeze(".opacity(enabled ? 1 : 0.4)")),
                "面板根链缺灰态视觉反馈（.opacity），母 spec §3：灰＝只降饱和，无解释字")
    }
}

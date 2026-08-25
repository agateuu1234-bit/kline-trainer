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

    @Test("spec §1.1 / D24：底栏**恰好 3 个按钮**（类型 + ②🔒 + ③🗑），④↩⑤↪ 属 PR-2 一个都不渲染")
    func bottomBarHasExactlyThreeKeys() throws {
        let bar = try code("Sources/KlineTrainerContracts/UI/DrawingModeBar.swift")
        // 结构计数（PD7：不是「禁止图标名」黑名单）—— 1b-ii PR-1 把 2 改成 3
        #expect(bar.components(separatedBy: "Button").count - 1 == 3,
                "底栏按钮数不是 3 —— 多了就是把 PR-2 的 ↩↪ 提前 ship 了，少了就是 🔒 或 🗑 没接进来")
        #expect(bar.contains("deleteEnabled"), "🗑 必须由传入谓词置灰，不得自己判")
        #expect(bar.contains(squeeze(".disabled(!deleteEnabled)")))
        #expect(bar.contains("lockEnabled"), "🔒 必须由传入谓词置灰，不得自己判")
        #expect(bar.contains(squeeze(".disabled(!lockEnabled)")))
        // 底栏不得自己读 locked —— 判据必须在路由里（结构断言，读 squeezed 正确）
        #expect(!bar.contains(squeeze("drawing.locked")), "底栏不得自己读 DrawingObject.locked")
        #expect(bar.contains("BottomBarMetrics.height"))
        // ★ 用户可见文案 / SF Symbol 名是**字符串字面量** → 必须读原始文本，且带完整调用语法做锚
        let barRaw = try raw("Sources/KlineTrainerContracts/UI/DrawingModeBar.swift")
        #expect(barRaw.contains("Text(\"类型\")"))
        #expect(barRaw.contains("Image(systemName: \"trash\")"), "③🗑 未接入")
        #expect(barRaw.contains(".accessibilityLabel(\"删除\")"))
        #expect(barRaw.contains("Image(systemName: lockIsOn ? \"lock\" : \"lock.open\")"),
                "🔒 图标没接 lockIsOn —— 图标态不会反映选中线的锁定状态")
        #expect(barRaw.contains(".accessibilityLabel(lockIsOn ? \"解锁\" : \"锁定\")"))
        // ④↩⑤↪ 属 PR-2：本期一个占位都不许渲染（读原始文本才数得到字面量）
        for undoIcon in ["arrow.uturn.backward", "arrow.uturn.forward"] {
            #expect(!barRaw.contains(undoIcon), "\(undoIcon) 属 PR-2，本期不得渲染")
        }
    }

    /// ⚠️ 只查 `DrawingModeBar.swift` **挡不住**「按钮长得对但根本没接上」：
    ///   `DrawingBottomBar(lockEnabled: true, lockIsOn: false, onToggleLock: {}, …)` 会让上面那条
    ///   三键守卫**全绿**，而屏幕上那个 🔒 恒亮、点了没反应。可用性与动作的**真相在路由里**，
    ///   故必须钉死 `TrainingView` 传进去的就是路由那三个函数。
    @Test("底栏 🔒 的可用性/图标态/动作三者都必须接 DrawingEditRouter，不得传常量或空闭包")
    func trainingViewWiresLockToRouter() throws {
        let tv = try code("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(tv.contains(squeeze("lockEnabled: DrawingEditRouter.lockButtonEnabled(engine: engine)")),
                "🔒 的可用性没接路由 —— 可能传了常量")
        #expect(tv.contains(squeeze("lockIsOn: DrawingEditRouter.lockIsOn(engine: engine)")),
                "🔒 的图标态没接路由")
        #expect(tv.contains(squeeze("DrawingEditRouter.toggleLockSelected(engine: engine)")),
                "🔒 的动作没接路由 —— 可能是空闭包")
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
        // codex 整支 R3（本 PR 引入的回归修复）：TrainingView 只转发**变更意图**，不再自己先读一份
        // 快照/直接落盘——「现取当前真值 + 合并」全部下放给 DrawingEditRouter 的两个 mutation 入口。
        #expect(tv.contains(squeeze("DrawingEditRouter.applyStyleMutation(")))
        #expect(tv.contains(squeeze("DrawingEditRouter.applyDefaultStyleMutation(")))
        // 分流判据必须是「有没有选中」，不是别的
        #expect(tv.contains(squeeze("engine.drawingSession.selectedDrawingID != nil")))
        // applyStyleMutation 在 Sources/ 里恰好 1 处（面板是唯一的样式写入入口，D58 末段：
        // 不得绕开面板另开编辑入口，否则 (ray,.left) 会变成只在编辑路径上可达的坏组合）
        let sites = try callSiteCount("DrawingEditRouter.applyStyleMutation(")
        #expect(sites.count == 1 && sites.first?.count == 1,
                "applyStyleMutation 调用点应恰好 1 处，实际：\(sites)")
        // applyDefaultStyleMutation 同理恰好 1 处（无选中路径的唯一入口）。
        let defaultSites = try callSiteCount("DrawingEditRouter.applyDefaultStyleMutation(")
        #expect(defaultSites.count == 1 && defaultSites.first?.count == 1,
                "applyDefaultStyleMutation 调用点应恰好 1 处，实际：\(defaultSites)")
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

    // MARK: Task 7 — G4b / G4c / G6（本局默认 autosave 触发 + 视图层守卫，D94/D90）

    /// 共用小工具：从（已剥注释/字面量、空白已压掉的）squeezed 源码里，按大括号配对取出
    /// `needle`（内部先 squeeze）后第一个 `{...}` 的闭包体（同样是 squeezed 文本，无空白）。
    /// 为什么必须这么做：两条 `.onChange` 都在同一个文件里，任何「A 出现过 + B 出现过」式的
    /// 分离 contains 都会被**另一条**满足（codex plan-P-R1 high①：既有的 drawingsRevision
    /// 那条已经含 `lifecycle.autosave(immediate: true)`）。
    private func closureBody(after needle: String, in src: String) throws -> String {
        let n = squeeze(needle)
        guard let head = src.range(of: n) else {
            Issue.record("未找到 \(n)"); return ""      // 锚点失效必须报错，不得静默返回空
        }
        guard let open = src.range(of: "{", range: head.upperBound..<src.endIndex) else {
            Issue.record("\(n) 之后没有 `{`"); return ""
        }
        var depth = 0
        var i = open.lowerBound
        while i < src.endIndex {
            if src[i] == "{" { depth += 1 }
            if src[i] == "}" { depth -= 1; if depth == 0 { return String(src[open.upperBound..<i]) } }
            i = src.index(after: i)
        }
        Issue.record("\(n) 的闭包大括号未配对"); return ""
    }

    /// G6：D94 的**唯一**守门 —— host 够不着 TrainingView（UIKit-gated），行为测试受阻于
    /// 本仓已记录的平台限制。⚠️ **必须断言「那一条」闭包体内**有 autosave，不能分开判两个子串
    ///    （codex plan-P-R1 high①：分开判时，一个**空闭包**照样全绿）。
    @Test("Task 7 G6：本局默认样式的 onChange 闭包体内必须调 autosave(immediate: true)（D94）")
    func trainingViewDefaultStyleOnChangeBodyCallsAutosave() throws {
        let src = try code("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        let body = try closureBody(after: "onChange(of: engine.drawingSession.defaultStyle)", in: src)
        #expect(body.contains(squeeze("lifecycle.autosave(immediate: true)")),
                "本局默认的 onChange 闭包体内没有调 autosave（D94）——空闭包也会让旧版 G6 变绿")
    }

    /// G6 的**双向自检**：喂一个「有 onChange 但闭包为空」的样本必须**不**满足
    @Test("Task 7 G6 自检：空闭包必须被判不合格（防分离 contains 的假绿）")
    func g6RejectsEmptyOnChangeBody() throws {
        let fake = squeeze(
            ".onChange(of: engine.drawingsRevision) { _, _ in lifecycle.autosave(immediate: true) }\n"
          + ".onChange(of: engine.drawingSession.defaultStyle) { _, _ in }")
        let body = try closureBody(after: "onChange(of: engine.drawingSession.defaultStyle)", in: fake)
        #expect(!body.contains(squeeze("lifecycle.autosave")), "自检失败：空闭包竟被判为合格")
    }

    /// G6b（Task 8 修复轮 1）：**modifier 必须真的挂在 TrainingView 的 body 上**。
    /// task-8 spike 把 drawingsRevision + defaultStyle 两条 `.onChange` 抽进了
    /// `DrawingAutosaveTriggersModifier`（同文件，见其定义处）——抽取之后「onChange 存在于文件里」
    /// 不再等于「它生效」：删掉 body 里那句 `.modifier(...)`，G6 仍绿（onChange 还在 modifier 结构体
    /// 内，同一个文件）、spike 行为测试也仍绿（它们在自己的最小宿主里挂 modifier，根本不经过
    /// TrainingView 的 body），而生产上两条 autosave 触发（defaultStyle **与既有的 drawingsRevision**
    /// 一起）会静默失效——这个缺口比新增功能本身更严重，因为它把一条本来安全的既有触发也拖下水。
    @Test("Task 8 G6b：DrawingAutosaveTriggersModifier 必须挂在 TrainingView 的 body 上")
    func autosaveTriggersModifierIsAttachedInProduction() throws {
        let sites = try callSiteCount("DrawingAutosaveTriggersModifier(")
        let total = sites.reduce(0) { $0 + $1.count }
        #expect(total == 1, "Sources/ 里应恰好 1 处挂载，实测 \(total)：\(sites.map { "\($0.file)×\($0.count)" })")
        #expect(sites.first?.file.hasSuffix("TrainingView.swift") == true,
                "挂载点应在 TrainingView.swift，实测：\(sites.map(\.file))")
        // 必须是**挂在 body 上**的形态，不是别处随便构造一个实例
        let src = try code("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(src.contains(squeeze(".modifier(DrawingAutosaveTriggersModifier(")),
                "modifier 没有以 .modifier(...) 形态挂在 body 链上")
    }

    /// G6b 自检：只声明不挂载必须被判不合格。
    @Test("Task 8 G6b 自检：只声明不挂载必须被判不合格")
    func g6bRejectsDeclarationWithoutAttachment() {
        let fake = squeeze("struct DrawingAutosaveTriggersModifier: ViewModifier { func body(content: Content) -> some View { content } }")
        #expect(!fake.contains(squeeze(".modifier(DrawingAutosaveTriggersModifier(")))
    }

    /// 取 `private var X: Bool { <RHS> }` 的 RHS（squeezed，已无空白）。
    private func definitionRHS(of name: String, in src: String) throws -> String {
        try closureBody(after: "var \(name): Bool", in: src)
    }

    /// G4b：复盘排除依赖的是**整条合取式**。
    /// ⚠️ **不能用 `contains`**（codex plan-P-R1 high②）：`… && typeRowExpanded || isReview`
    ///    仍然包含原子串、照样绿。改为取出定义式右侧、squeeze 后**精确相等**。
    @Test("Task 7 G4b：stylePanelWillBeVisible 定义式必须精确等于三元合取（D90）")
    func stylePanelVisibilityPredicateIsExactlyTheThreeWayConjunction() throws {
        let src = try code("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        let rhs = try definitionRHS(of: "stylePanelWillBeVisible", in: src)
        #expect(rhs == squeeze("showsTradeButtons && isDrawingActive && typeRowExpanded"),
                "stylePanelWillBeVisible 的定义式被改动了，D90 的复盘排除失效，实测：\(rhs)")
    }

    /// G4b 的**双向自检**：放宽后的谓词必须被判不合格
    @Test("Task 7 G4b 自检：放宽后的谓词必须被判不合格（防 contains 假绿）")
    func g4bRejectsBroadenedPredicate() throws {
        let fake = squeeze(
            "private var stylePanelWillBeVisible: Bool { showsTradeButtons && isDrawingActive && typeRowExpanded || isReview }")
        let rhs = try definitionRHS(of: "stylePanelWillBeVisible", in: fake)
        #expect(rhs != squeeze("showsTradeButtons && isDrawingActive && typeRowExpanded"))
    }

    /// G4c：样式面板挂载点在 `Sources/` 里**恰好 1 处**（防「另开一条路径」绕过 G4/G4b）。
    /// ⚠️ 挂载点计数不得是空函数体式的恒绿 no-op（codex plan-P-R1 high②）——用 callSiteCount 真数。
    @Test("Task 7 G4c：DrawingStylePanel( 挂载点在 Sources/ 里恰好 1 处")
    func stylePanelHasExactlyOneMountSite() throws {
        let sites = try callSiteCount("DrawingStylePanel(")
        let total = sites.reduce(0) { $0 + $1.count }
        #expect(total == 1, "样式面板挂载点应恰好 1 处，实测 \(total)（\(sites)）—— 多一处 = 有绕过 G4/G4b 的新路径")
    }

    /// G4c 的**双向自检**：两处挂载的样本必须被数出 2（防「恒返回 1」的计数实现）
    @Test("Task 7 G4c 自检：两处挂载必须被数出 2")
    func g4cRejectsSecondMountSite() {
        let fake = "DrawingStylePanel(a: 1)\nDrawingStylePanel(b: 2)"
        let n = fake.components(separatedBy: "DrawingStylePanel(").count - 1
        #expect(n == 2)
    }
}

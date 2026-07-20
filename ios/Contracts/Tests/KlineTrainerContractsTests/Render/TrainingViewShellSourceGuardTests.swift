// Tests/KlineTrainerContractsTests/Render/TrainingViewShellSourceGuardTests.swift
// Spec: split-addendum §4.1.1/§4.1.3 + §4.3-1,2,2b（D26/R22-high 交易安全谓词拆分 + 交易边界 R3-high）。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("TrainingView 外壳结构守卫：谓词拆分 / 浮动钮 review-only / 交易边界")
struct TrainingViewShellSourceGuardTests {
    private var srcDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ rel: String) throws -> String {
        let text = try String(contentsOf: srcDir.appendingPathComponent(rel), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line); guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }
    private let tv = "Sources/KlineTrainerContracts/UI/TrainingView.swift"

    @Test("谓词拆成两个：floating=review-only（锚定 body），activePanel 高亮保原语义")
    func predicateSplit() throws {
        let code = try source(tv)
        // 必须锚定 **body 就是 review-only**（codex plan-R8-medium）——否则实现留个 showsTradeButtons||review
        // 的 floating 谓词也能过「名字存在」，训练/replay 浮动钮仍可达 = D26 双入口回归。
        #expect(code.contains("showsFloatingDrawingTool: Bool { engine.flow.mode == .review }"))
        // activePanel 高亮谓词保留 showsTradeButtons（否则训练下丢下单目标高亮）
        #expect(code.contains("showsActivePanelHighlight: Bool { showsTradeButtons || engine.flow.mode == .review }"))
    }

    @Test("浮动钮只受 showsFloatingDrawingTool 门控；DrawingBottomBar 只在训练/replay 底栏")
    func floatingRetiredBarWired() throws {
        let code = try source(tv)
        #expect(code.contains("if showsFloatingDrawingTool"))     // 浮动钮 gated review-only
        #expect(code.contains("画图"))                            // 入口钮 label
        // DrawingBottomBar 必须挂在「showsTradeButtons → isDrawingActive」分支内（复盘 showsTradeButtons==false
        // → 天然无底栏，D26/§4.3-1）。锚定其紧邻上文是 isDrawingActive 分支，而非文件任意处（codex plan-R8-medium）。
        let dmb = try #require(code.range(of: "DrawingBottomBar("), "DrawingBottomBar 未接入")
        let before = String(code[..<dmb.lowerBound].suffix(120))
        #expect(before.contains("if isDrawingActive {"))
    }

    @Test("画线底栏改用单行 DrawingBottomBar，不再在 VStack 直接塞两行 DrawingModeBar")
    func drawingBottomBarWiredSingleRow() throws {
        let code = try source(tv)
        // 底栏 swap 分支用 DrawingBottomBar（单行）
        #expect(code.contains("DrawingBottomBar("))
        // 不再把两行 DrawingModeBar 作为 VStack 成员塞进 trainingContent（改 overlay，见 Task 2）
        #expect(!code.contains("DrawingModeBar(typeRowExpanded"))
    }

    @Test("三个互斥 swap 底栏（TradeActionBar/DrawingBottomBar/ReviewControlBar）都显式钉同一个 BottomBarMetrics.height——防漂移回归（1a-iii 切片1 Task1 fix）")
    func threeBottomBarsShareFixedHeightConstant() throws {
        // 曾经指望「三者共享同一套 intrinsic 配方（buttonStyle/controlSize/padding 逐项照抄）天然等高」，
        // 但 Catalyst 真机测量证伪：内容量不同（图标 vs 图标+多文案按钮），配方相同不保证测出来的高度相同。
        // 现改为三者都显式钉同一个 BottomBarMetrics.height 常量；任一侧以后被改动/漏钉，本测试即失败。
        let trade = try source("Sources/KlineTrainerContracts/UI/TradeActionBar.swift")
        let drawing = try source("Sources/KlineTrainerContracts/UI/DrawingModeBar.swift")
        let review = try source("Sources/KlineTrainerContracts/UI/ReviewControlBar.swift")
        #expect(trade.contains(".frame(height: BottomBarMetrics.height)"), "TradeActionBar 未钉 BottomBarMetrics.height")
        #expect(drawing.contains(".frame(height: BottomBarMetrics.height)"), "DrawingBottomBar 未钉 BottomBarMetrics.height")
        #expect(review.contains(".frame(height: BottomBarMetrics.height)"), "ReviewControlBar 未钉 BottomBarMetrics.height")
    }

    @Test("交易边界：清 tradeStrip + overlay 门控 + onConfirm 经 TradeConfirmGuard.apply（窄锚定）")
    func tradeBoundary() throws {
        let code = try source(tv)
        #expect(code.contains("onChange(of: engine.drawingSession.drawingModeActive)"))
        // onChange 必须**无条件清 tradeStrip**（codex plan-R6/R9-high）——两个方向都清，不能只 `if active`，
        // 否则陈旧 tradeStrip 跨 round-trip 幸存 → 退出后 remount，同 tick/period 下放行旧请求成交。
        // 要求**精确无条件签名** `{ _, _ in`（codex plan-R11-high）：既拒 `_, active in`，也拒
        // `{ _, _ in if engine.drawingSession.drawingModeActive { … } }` 这种换条件的「只进画线清」——
        // 提取闭包体到首个 `}`，断言**根本没有 `if`**（任一 `if` 都意味着条件清，即漏了退出方向）。
        let ocStart = try #require(code.range(of: "onChange(of: engine.drawingSession.drawingModeActive) { _, _ in"),
                                   "onChange 必须是无条件闭包 { _, _ in }（进/出画线都清 tradeStrip）")
        let ocTail = String(code[ocStart.upperBound...])
        let ocEnd = try #require(ocTail.range(of: "}"), "找不到 onChange 闭包结尾")
        let ocBody = String(ocTail[..<ocEnd.lowerBound])
        #expect(ocBody.contains("tradeStrip = nil"))
        #expect(!ocBody.contains("if "))                 // 闭包体无任何条件 → 两个方向都清（不止某个 if 分支）
        // 同步纵深（codex rebased-R1-high）：唯一 UI 开/关入口 toggleDrawing() 必须**同步**清 tradeStrip，
        // 不能只靠会被 SwiftUI coalesce 的 onChange（drawingModeActive 一次 update 内 false→true→false 时 onChange 不触发）。
        let tdStart = try #require(code.range(of: "func toggleDrawing() {"), "找不到 toggleDrawing()")
        let tdTail = String(code[tdStart.upperBound...])
        let tdEnd = try #require(tdTail.range(of: "engine.toggleDrawingMode()"), "toggleDrawing 应调 toggleDrawingMode")
        let tdBody = String(tdTail[..<tdEnd.lowerBound])
        #expect(tdBody.contains("tradeStrip = nil"))     // 在调 engine.toggleDrawingMode() **之前**同步清
        // TradeBox overlay 挂载条件带 !drawingModeActive 纵深门控——**锚定到真实挂载条件**
        // （紧跟 showsTradeButtons，即 TradeBoxView 分支），不是文件里某处出现（codex plan-R5-high）。
        #expect(code.contains("showsTradeButtons, !engine.drawingSession.drawingModeActive,"))
        // 窄锚定（codex plan-R3-high）：performTrade 必须包在 apply 的 onProceed 闭包里，
        // 不是「文件里某处出现 apply」——取 onConfirm 起到 performTrade 的片段，断言 apply 在其中且
        // performTrade 出现在 onProceed: 之后（真挂在转换的成交分支上，unused helper 满足不了）。
        // 取 onConfirm 闭包整体（onConfirm: 到它的闭合 `},`），在这个片段里做强断言。
        let confirmStart = try #require(code.range(of: "onConfirm: { shares in"), "找不到 onConfirm 闭包（结构漂移）")
        let after = String(code[confirmStart.upperBound...])
        let confirmEnd = try #require(after.range(of: "},"), "找不到 onConfirm 闭包结尾")
        let body = String(after[..<confirmEnd.lowerBound])
        #expect(body.contains("TradeConfirmGuard.apply("))
        // apply 必须收**真实**的 drawingModeActive（codex plan-R5-high）——防 `drawingModeActive: false`
        // 硬编码/陈旧值绕过：pure 测试与「恰一次」都拦不住这种，唯有断言实参本身。
        #expect(body.contains("drawingModeActive: engine.drawingSession.drawingModeActive"))
        // periodTickStillValid 必须来自**真实** tradeStripStillValid(...)（codex plan-R11-high）——
        // 防硬编码 `periodTickStillValid: true` 复活过期 tick/period 的确认。
        #expect(body.contains("periodTickStillValid: tradeStripStillValid(capturedPeriod: strip.period"))
        // 唯一性 + 位置（codex plan-R4-high）：performTrade 在 onConfirm 里**恰出现一次**，且**就在 onProceed 闭包内**——
        // 杜绝「apply(onProceed:{}) 空转后又无条件 performTrade」的绕过。
        #expect(body.components(separatedBy: "performTrade(").count - 1 == 1)   // 恰一次
        #expect(body.contains("onProceed: { performTrade(strip.action"))       // 那一次就在 onProceed 内
    }

    /// 起止标记切出指定片段的正文（同 DrawingTapHitShieldTests.extractBody 的窄锚定手法，
    /// 1a-iii 切片2 Task2 Step5b 新增，与 tradeBoundary 守卫同一片段口径）。
    private func slice(_ text: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try #require(text.range(of: startMarker)?.upperBound)
        let end = try #require(text.range(of: endMarker, range: start..<text.endIndex)?.lowerBound)
        return String(text[start..<end])
    }

    @Test("进画线默认展开（codex 计划-R9-F3 / R10-F1）：重置放在 toggleDrawing 的『即将进入』分支")
    func drawingEntryResetsExpandedInToggle() throws {
        let tv = try source(tv)
        // 只取 toggleDrawing 到 engine.toggleDrawingMode() 之间——与既有 tradeBoundary 守卫同一片段口径。
        let body = try slice(tv, from: "private func toggleDrawing() {", to: "engine.toggleDrawingMode()")
        #expect(body.contains("tradeStrip = nil"), "既有交易安全：同步清 tradeStrip 不得丢")
        #expect(body.contains("if !engine.drawingSession.drawingModeActive { typeRowExpanded = true }"),
                "进画线未重置展开态 —— 收起后退出再进会停在收起态（spec §2.1 / §4.4 违规）")
    }

    @Test("交易安全不回退（codex 计划-R10-F1）：drawingModeActive 的 onChange 仍是无条件 { _, _ in }、体内无 if")
    func drawingModeOnChangeStaysUnconditional() throws {
        let code = try source(tv)
        // 与既有 TrainingViewShellSourceGuardTests.tradeBoundary 同向的**冗余**断言：本切片新增 UI 状态时
        // 极易顺手把这个闭包改成 `{ _, isActive in ... if isActive ... }`，那会让陈旧 tradeStrip 只在单方向被清。
        #expect(code.contains("onChange(of: engine.drawingSession.drawingModeActive) { _, _ in"),
                "闭包签名被改动 —— tradeBoundary 守卫会红，且交易边界被削弱")
        let chain = try slice(code, from: "onChange(of: engine.drawingSession.drawingModeActive) { _, _ in",
                              to: ".onChange(of: typeRowExpanded)")
        #expect(chain.contains("tradeStrip = nil"))
        // whole-branch fix（critical）：改调 setStylePanelVisible(true)（两面板 .pending，fail-closed），
        // 不再是 clearAllShields()——后者先清空、absent 等价放行，若恰逢 refreshShields() 因两面板 frame
        // 不变而不再重新触发，窗口会一直开着（详见 DrawingSession.setStylePanelVisible 文档）。
        #expect(chain.contains("setStylePanelVisible(true)"))
        #expect(!chain.contains("clearAllShields()"),
                "fail-open 回归：闭包体不得再调 clearAllShields()，只允许 .onDisappear 调用")
        #expect(!chain.contains("if "), "闭包体出现 if —— 清理变成条件性，退出方向可能漏清")
    }
}

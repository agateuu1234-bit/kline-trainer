// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift
// Spec: 2026-07-10-drawing-tools-P1b-split-addendum.md §3.3 #1 / #4b / #4c / #6。
// 结构守卫：spec 字面要求「断言某调用**不再存在**」——行为测试测不到「代码里还留着一行」，故读源码文本。
// 反踩坑（memory: acceptance grep 两坑）：先**剥掉注释行**再匹配，否则解释性注释里的字样会误判。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("1a-ii 结构守卫：re-arm 已删 / 切面板不取消画线 / 无新 UI")
struct DrawingSessionSourceGuardTests {

    /// ios/Contracts 目录（由本测试文件路径回推：Tests/KlineTrainerContractsTests/Drawing/<本文件> → 上溯 4 层）。
    private var contractsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Drawing
            .deletingLastPathComponent()    // KlineTrainerContractsTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // ios/Contracts
    }

    /// 读源码并**剥掉注释**后返回。
    /// 反踩坑（memory: acceptance grep 两坑）：不剥注释的话，「解释这行为什么删掉」的注释本身
    /// 会命中断言字样 → 假红/假绿。整行注释丢弃；行尾 `//` 之后截断。
    private func source(relativeURL url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }

    private func source(_ relativeToContracts: String) throws -> String {
        try source(relativeURL: contractsDir.appendingPathComponent(relativeToContracts))
    }

    private let chartContainer = "Sources/KlineTrainerContracts/Render/ChartContainerView.swift"
    private let trainingView   = "Sources/KlineTrainerContracts/UI/TrainingView.swift"
    private let floatingView   = "Sources/KlineTrainerContracts/UI/DrawingToolFloatingView.swift"
    private let engine         = "Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift"

    @Test("#1：ChartContainerView 里**不存在** manager.toggle 自动 re-arm，也不再持有 DrawingToolManager")
    func noRearmInChartContainer() throws {
        let code = try source(chartContainer)
        #expect(code.contains("func handleDrawingTap"))    // 先证明真读到了文件内容（防路径写错→空内容→负向断言假绿）
        #expect(!code.contains("manager.toggle("))
        #expect(!code.contains("DrawingToolManager("))     // Coordinator 不再私有持有暂存器
    }

    @Test("#5/D38：提交后**不再**调 engine.commitDrawing（那是「画一条就退出」）")
    func noCommitDrawingAfterTap() throws {
        let code = try source(chartContainer)
        #expect(code.contains("session.addAnchor("))       // 先证明真读到了文件内容（防路径写错→空内容→负向断言假绿）
        #expect(!code.contains("engine.commitDrawing("))
    }

    @Test("#4b：TrainingView 的 activePanel observer **不再**取消画线；toggleDrawingExclusive 已退役")
    func activePanelObserverNoLongerCancelsDrawing() throws {
        let code = try source(trainingView)
        #expect(!code.contains("cancelDrawingAllPanels"))      // 切下单目标面板绝不丢线（R30-medium）
        #expect(!code.contains("toggleDrawingExclusive"))      // 按 activePanel 作用域的互斥模型已退役
        #expect(code.contains("engine.toggleDrawingMode()"))   // 改走全局会话
    }

    @Test("#4b 强化：切 activePanel 的 observer 里**一个 engine 调用都不许有**（codex plan-R4）")
    func activePanelObserverTouchesNoEngineState() throws {
        let code = try source(trainingView)
        // 取 `.onChange(of: activePanel)` 到该闭包结束（首个「8 空格 + }」）之间的块。
        guard let start = code.range(of: ".onChange(of: activePanel)") else {
            Issue.record("找不到 activePanel observer —— 它被改名/删了？"); return
        }
        let rest = code[start.upperBound...]
        guard let end = rest.range(of: "\n        }") else {
            Issue.record("activePanel observer 闭包边界解析失败（缩进变了？）"); return
        }
        let block = String(rest[..<end.lowerBound])
        // 切「下单目标面板」纯属 View 侧状态：只许清买卖条（tradeStrip = nil），
        // 不许碰引擎任何状态 —— 画线会话/工具/pending 一律原封（D42 / R30-medium）。
        #expect(!block.contains("engine."), "activePanel observer 不得触碰引擎状态，实际内容：\(block)")
        #expect(block.contains("tradeStrip = nil"))            // 买卖条那条必须留（RFC-B）
    }

    @Test("#4：TrainingEngine 里 toggleDrawingExclusive 已删除（互斥模型退役）")
    func engineExclusiveToggleRemoved() throws {
        let code = try source(engine)
        #expect(!code.contains("func toggleDrawingExclusive"))
    }

    @Test("codex plan-R5-high：DrawingSession 的 mutator 一个都不许是 public（包外不得直接改会话）")
    func drawingSessionMutatorsAreNotPublic() throws {
        let code = try source("Sources/KlineTrainerContracts/Drawing/DrawingSession.swift")
        for m in ["func activate(", "func deactivate(", "func discardPendingAnchors(",
                  "func addAnchor(", "func commitPending("] {
            #expect(code.contains(m), "mutator \(m) 不见了？")                 // 先证明确实扫到了这些方法
            #expect(!code.contains("public " + m),
                    "\(m) 不得为 public —— 包外能直接改会话就绕开了 begin/endDrawingSession，漂移会回来")
        }
        // 只读态则必须仍是 public（TrainingView / 未来底栏要读）
        #expect(code.contains("public private(set) var drawingModeActive"))
    }

    @Test("codex plan-R5-high：只有 TrainingEngine 能开/关会话（Coordinator 只许落锚/提交）")
    func onlyEngineTogglesSession() throws {
        let chart = try source(chartContainer)
        #expect(!chart.contains(".activate(tool:"))     // Coordinator 不得自行开会话
        #expect(!chart.contains(".deactivate()"))       // 也不得自行关会话
        #expect(chart.contains("session.addAnchor("))   // 它该做的只有落锚
        #expect(chart.contains("session.commitPending("))
    }

    @Test("codex plan-R2-high：面板级 FSM 原语只许 TrainingEngine 自己调（防再接一条漂移路径）")
    func panelLevelDrawingPrimitivesAreEngineOnly() throws {
        let sourcesRoot = contractsDir.appendingPathComponent("Sources/KlineTrainerContracts")
        let files = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "TrainingEngine.swift" }
        #expect(!files.isEmpty)                       // 路径写错会静默通过 → 先证明真的扫到文件了
        for f in files {
            let code = try source(relativeURL: f)     // 同样剥注释
            #expect(!code.contains("activateDrawingTool("), "\(f.lastPathComponent) 不得直接调面板级画线原语")
            #expect(!code.contains("armPanelForDrawing("),  "\(f.lastPathComponent) 不得直接调面板级画线原语")
            #expect(!code.contains("commitDrawing("),       "\(f.lastPathComponent) 不得直接调面板级画线原语")
            #expect(!code.contains("cancelDrawing("),       "\(f.lastPathComponent) 不得直接调面板级画线原语")
        }
    }

    @Test("#4c/#6：本期不引入任何新 UI —— 浮动钮仍在，且无顶栏「画图」钮 / 底栏工具栏 / 设置面板")
    func noNewDrawingUI() throws {
        let code = try source(trainingView)
        #expect(code.contains("DrawingToolFloatingView("))     // 入口未变（退役在 1a-iii）
        #expect(!code.contains("画图"))                        // 顶栏「画图」钮（1a-iii）
        #expect(!code.contains("DrawingToolbar"))              // 两行底栏（1a-iii）
        #expect(!code.contains("DrawingSettingsPanel"))        // 设置面板（1a-iii）
    }

    // MARK: 真机验收回归守卫（模拟器实证修复；SwiftUI observation/view 行为单测测不到，只能源码钉死防误删）

    @Test("回归守卫（现象②：图表冻结）：rebuildRenderState 必须显式读面板 revision + tick 建立 observation 订阅")
    func rebuildRenderStateSubscribesToPanelState() throws {
        let code = try source(chartContainer)
        #expect(code.contains("rebuildRenderState"))                   // 先证明扫到了正确文件/函数
        // 这两行是 P1b-1a-ii 回归修复的订阅锚点：删掉任一行 → 首帧 bounds=0 后 updateUIView 不再订阅面板状态
        // → pan/切周期/买入改的 offset/period/tick 不触发重画 → K 线图永久冻结（真机/模拟器实证）。
        #expect(code.contains("upperPanel.revision"))
        #expect(code.contains("lowerPanel.revision"))
        #expect(code.contains("engine.tick.globalTickIndex"))
    }

    @Test("回归守卫（现象①：隐形卡死）：折叠态浮动钮必须随画线模式变外观 + 点它直接退出画线")
    func collapsedFloatingButtonReactsToDrawingActive() throws {
        let code = try source(floatingView)
        #expect(code.contains("if isDrawingActive { onToggleTool() }"))  // 画线模式开：点圆圈=直接退出（不是展开）
        #expect(code.contains(".tint(isDrawingActive ? .orange"))        // 画线模式开：圆圈变橙色（一眼看出在画线）
    }
}

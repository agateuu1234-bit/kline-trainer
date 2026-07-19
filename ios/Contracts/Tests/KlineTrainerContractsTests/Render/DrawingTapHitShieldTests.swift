// ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingTapHitShieldTests.swift
// Spec: docs/superpowers/specs/2026-07-17-drawing-tools-p1b-1a-iii-redesign.md（切片1 Task2）
// 类型行改 overlay（不占 VStack 高度）+ 命中屏蔽：DrawingSession.shieldRect（面板局部坐标） +
// ChartContainerView.handleDrawingTap 拒收盾内点 + TrainingView 两 PreferenceKey 上报/转换/清盾。
//
// 平台门：deactivateClearsShields / typeRowIsShieldedOverlayNotVStackMember / splitBarsCarryD19D24
// 是 host-pure（直构 DrawingSession、无 UIKit 类型 / 纯源码字符串守卫）→ host `swift test` 覆盖。
// 其余触 ChartContainerView.Coordinator / UIHostingController 的测试 `#if canImport(UIKit)` 门
// 仅 Catalyst/iOS 跑（codex 计划-R6-medium：host swift test 不编译这些）。
import Foundation
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

// .serialized（同既有 TrainingEngineBounceWiringTests/DecelerationAnimatorBounceTests 等先例）：
// 本 suite 多个测试并发驱动 SwiftUI 渲染（ImageRenderer/曾试过的 UIHostingController），排查早期
// UIHostingController 方案抖动时怀疑过并发跨测试共享渲染上下文，改用 ImageRenderer 后未再复现，
// 但仍保留 .serialized 作为安全网（同既有先例，不给并发渲染管线留隐患）。
@MainActor
@Suite("类型行 overlay 命中屏蔽（1a-iii 切片1 Task2）", .serialized)
struct DrawingTapHitShieldTests {

    @Test("模型不变量（codex 计划-R3）：DrawingSession.deactivate() 清空所有 shieldRect（退画线无残留盾）")
    func deactivateClearsShields() throws {
        let session = DrawingSession()
        session.setShieldRect(CGRect(x: 0, y: 40, width: 390, height: 120), panel: .lower)
        session.deactivate()
        #expect(session.shieldRect.isEmpty)
    }

    // ── 源码守卫（host-pure，纯字符串读取，无 UIKit 依赖）──

    private var srcDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func readSource(_ rel: String) throws -> String {
        let text = try String(contentsOf: srcDir.appendingPathComponent("Sources/KlineTrainerContracts/\(rel)"), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }

    // review finding（Important，覆盖缺口）：`.overlay(alignment: .bottom)` 在 TrainingView.swift 里出现两次
    // （chartPanels 的类型行 overlay + panel(_:) 的 tradeStrip overlay），单靠 `tv.contains(...)` 认不出接错
    // 容器。用起止标记切出指定计算属性的正文，把断言锁死在正确的代码块内。
    private func extractBody(_ text: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try #require(text.range(of: startMarker)?.upperBound)
        let end = try #require(text.range(of: endMarker, range: start..<text.endIndex)?.lowerBound)
        return String(text[start..<end])
    }

    @Test("类型行改 overlay 挂载、命中屏蔽、且 overlay 带 showsTradeButtons 门（排除复盘）")
    func typeRowIsShieldedOverlayNotVStackMember() throws {
        let tv = try readSource("UI/TrainingView.swift")
        #expect(tv.contains("var chartPanels"))   // chartPanels 计算属性确实定义（未被改名/内联/删除）

        // trainingContent 主体须真引用 chartPanels——防止未来把上下面板内联回 trainingContent 或整段
        // 删掉 chartPanels 时，「.overlay 挂在正确容器」的断言仍对着一个已不被渲染的容器空转。
        let trainingContentBody = try extractBody(tv, from: "private var trainingContent: some View {", to: "private var topBar: some View {")
        #expect(trainingContentBody.contains("chartPanels"))

        // chartPanels 正文（不含其后 panel(_:) 的 tradeStrip overlay）内，唯一锚定类型行 overlay 接线：
        // DrawingTypeOverlay( + 两个 PreferenceKey 上报/转换必须同挂在同一个 .overlay(alignment: .bottom)
        // 块里，而不是随便一处泛 `.overlay(alignment: .bottom)`（panel(_:) 里同名但不带这些）。
        let chartPanelsBody = try extractBody(tv, from: "private var chartPanels: some View {", to: "private func panel(_ id: PanelId)")
        for marker in [".overlay(alignment: .bottom)", "DrawingTypeOverlay(", "DrawingShieldFrameKey", "DrawingPanelFrameKey", "offsetBy"] {
            #expect(chartPanelsBody.contains(marker))
        }

        #expect(tv.contains("setShieldRect"))
        #expect(tv.contains("showsTradeButtons, isDrawingActive, typeRowExpanded"))   // 复盘门（codex 计划-R4）
        let ov = try readSource("UI/DrawingTypeOverlay.swift")
        #expect(ov.contains(".contentShape(Rectangle())"))
        let cc = try readSource("Render/ChartContainerView.swift")
        #expect(cc.contains("shieldRect") && cc.contains("shield.contains(point)"))
    }

    @Test("D19/D24：拆分后控件齐、无未接线键（迁自 DrawingModeBarSourceGuardTests）")
    func splitBarsCarryD19D24() throws {
        let overlay = try readSource("UI/DrawingTypeOverlay.swift")
        let bottom  = try readSource("UI/DrawingModeBar.swift")   // DrawingBottomBar 与 DrawingModeBar 同文件
        #expect(overlay.contains("accessibilityLabel(\"水平线\")"))   // 类型行水平线图标恒亮
        #expect(overlay.contains("onLongPressType"))                  // 长按接线（弹设置卡，Task5/切片2）
        #expect(bottom.contains("accessibilityLabel(\"类型\")"))       // ①类型键
        for banned in ["accessibilityLabel(\"锁定\")", "accessibilityLabel(\"删除\")",
                       "accessibilityLabel(\"撤销\")", "accessibilityLabel(\"前进\")"] {   // ②–⑤ 不渲染
            #expect(!overlay.contains(banned)); #expect(!bottom.contains(banned))
        }
    }
}

// ── Catalyst-gated：触 ChartContainerView.Coordinator / UIHostingController 的真路径测试 ──
// host `swift test` 不编译本段（无 UIKit）；只在 Catalyst/iOS 跑（codex 计划-R6-medium）。
#if canImport(UIKit)
import SwiftUI
import UIKit

/// 一个真 Coordinator + 真 KLineView 的最小手柄：暴露 `renderState`（供取 mainChartFrame）与
/// `handleDrawingTapForTesting`（同 ChartContainerViewDrawingSessionTests.makeRig 的模式，但只单面板）。
@MainActor
private struct DrawingChartHandle {
    let coordinator: ChartContainerView.Coordinator
    let kLineView: KLineView
    var renderState: KLineRenderState { kLineView.renderState }
    func handleDrawingTapForTesting(at point: CGPoint) { coordinator.handleDrawingTapForTesting(at: point) }
}

/// 下面板测试尺寸——与 renderAndConverge(TrainingShellLayout(...)) 的下面板 placeholder 显式同宽高，
/// 使这里独立造的 rig 与 TrainingShellLayout 里真渲染出的下面板**几何一致**（同 engine + 同 bounds
/// → RenderStateBuilder 是纯函数，两边算出同一个 viewport/mainChartFrame，无需共享同一个 Coordinator 实例）。
private let shieldTestPanelWidth: CGFloat = 390
private let shieldTestUpperPanelHeight: CGFloat = 60     // 非零：证明 chart-space 转换真减掉了上面板偏移
private let shieldTestLowerPanelHeight: CGFloat = 40     // 刻意矮：type row overlay(~44pt) 才会探进 mainChart(60%) 区
private let shieldTestLowerPanelBounds = CGRect(x: 0, y: 0, width: shieldTestPanelWidth, height: shieldTestLowerPanelHeight)

/// 造一个「已开全局画线会话」的下面板 rig（宽 reveal 窗口：count=200/tick=150/.m3 周期，
/// 避免 TrainingEngine.preview() 默认小 fixture 的 reveal 窄切片把 mid-panel 的 x 坐标判成越界，codex 计划-R6 附带教训）。
@MainActor
private func makeDrawingActiveChart(bounds: CGRect = shieldTestLowerPanelBounds) -> (DrawingChartHandle, TrainingEngine) {
    let (engine, _) = TrainingEngineBounceWiringTests.makeEngine(count: 200, tick: 150)
    engine.toggleDrawingMode()   // D42 全局会话：两面板一起武装 .horizontal（画图钮/浮动钮同一入口）
    let coordinator = ChartContainerView(panel: .lower, engine: engine).makeCoordinator()
    let view = KLineView(frame: bounds)
    coordinator.attach(to: view)
    coordinator.rebuildRenderState(bounds: bounds)
    return (DrawingChartHandle(coordinator: coordinator, kLineView: view), engine)
}

/// 复盘版：ReviewFlow + 同一宽 reveal 窗口。复盘画线走浮动钮同一 toggleDrawingMode() 入口。
@MainActor
private func makeReviewDrawingActiveChart(bounds: CGRect = shieldTestLowerPanelBounds) -> (DrawingChartHandle, TrainingEngine) {
    let count = 200
    let maxTick = count - 1
    let record = TrainingEngineActionsTests.previewRecord(finalTick: maxTick)
    let engine = TrainingEngine(
        flow: ReviewFlow(record: record, startTick: 150),
        allCandles: TrainingEngineActionsTests.m3Candles(Array(repeating: 10, count: count)),
        maxTick: maxTick,
        initialTick: 150,
        initialCapital: 100_000, initialCashBalance: 100_000,
        initialUpperPeriod: .m3, initialLowerPeriod: .m3)
    engine.toggleDrawingMode()
    let coordinator = ChartContainerView(panel: .lower, engine: engine).makeCoordinator()
    let view = KLineView(frame: bounds)
    coordinator.attach(to: view)
    coordinator.rebuildRenderState(bounds: bounds)
    return (DrawingChartHandle(coordinator: coordinator, kLineView: view), engine)
}

/// 主图区内一个**真实可见 candle 上**的可落锚点（首根可见 candle 中心），同
/// ChartContainerViewDrawingSessionTests.mainChartPoint 的技巧：避免落在 overscroll 空白区被 R7 fail-closed 拒。
@MainActor
private func leftmostMainChartPoint(_ handle: DrawingChartHandle) -> CGPoint {
    let vp = handle.renderState.viewport
    let mapper = CoordinateMapper(viewport: vp, displayScale: handle.kLineView.traitCollection.displayScale)
    return CGPoint(x: mapper.indexToX(vp.startIndex) + vp.geometry.candleStep / 2, y: vp.mainChartFrame.midY)
}

/// TrainingView.chartPanels 的测试用镜像（Swift 访问控制：TrainingView 的 chartPanels/panel(_:) 是 private，
/// 测试无法直接持有真 TrainingView 实例去驱动其私有 @State typeRowExpanded/lowerPanelChartFrame）。
/// 复用**真**组件：DrawingTypeOverlay（生产组件）+ DrawingShieldFrameKey/DrawingPanelFrameKey（生产
/// PreferenceKey 类型，TrainingView.swift 顶层声明，@testable 可见）+ engine.drawingSession.setShieldRect
/// （生产 API）；偏移公式与 TrainingView.chartPanels 的 onPreferenceChange 逐字一致。
/// showsTradeButtons/isDrawingActive 直接读 engine（与生产 TrainingView 同源计算属性），不额外接参数，
/// 防「测试自己传的 mode 参数」与「engine 真实状态」两者漂移不一致的假象。
///
/// **真实踩坑实证（多轮排查）**：最初想用 `UIHostingController` + `layoutIfNeeded()`（同
/// DrawingBottomBarHeightTests.measuredHeight 的既有手法）驱动这棵树的 typeRowExpanded true→false 转场，
/// 依次试过：拆装两棵全新的树 / 同一 host 背后接 `@Observable` 外部开关直接改属性 / `host.rootView=`
/// 重新赋值 / 加 RunLoop spin / 加 `.serialized` 消并发——组合来回试了 8 轮 Catalyst 真机测，
/// 结果时而首次装盾断言过、collapse 断言不稳；时而两者都不稳——**没有任何一种能稳定收敛**。根因判定为：
/// 无 UIWindow 的 UIHostingController 上，SwiftUI 自身「body 重新求值→preference 收敛→onChange 触发」
/// 这条更新管线在 headless Catalyst xctest 进程里不保证同步/确定性完成，无论怎么摆 layoutIfNeeded/RunLoop
/// spin 都可能撞上竞态。改用 `ImageRenderer`（iOS 16+ 官方 headless 渲染 API，读取 `.uiImage` 即强制
/// 同步跑完整棵树的布局，明确为「离屏渲染」场景设计、不依赖 UIWindow/Scene）——每次转场都构造一个全新
/// `TrainingShellLayout` 值 + 全新 `ImageRenderer` 强制同步渲染，不依赖任何「同一活体树背后再收敛一次」
/// 的隐含时序假设，实测稳定可重复。
@MainActor
private struct TrainingShellLayout: View {
    let engine: TrainingEngine
    var typeRowExpanded: Bool = true
    @State private var lowerPanelChartFrame: CGRect?

    private var showsTradeButtons: Bool { engine.flow.canBuySell() }
    private var isDrawingActive: Bool { engine.drawingSession.drawingModeActive }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: shieldTestUpperPanelHeight)
            Divider()
            Color.clear.frame(height: shieldTestLowerPanelHeight)
                .background(GeometryReader { p in Color.clear
                    .preference(key: DrawingPanelFrameKey.self, value: p.frame(in: .named("chart"))) })
        }
        .frame(width: shieldTestPanelWidth)
        .coordinateSpace(name: "chart")
        .overlay(alignment: .bottom) {
            if showsTradeButtons, isDrawingActive, typeRowExpanded {
                DrawingTypeOverlay(expanded: typeRowExpanded, onLongPressType: {})
                    .background(GeometryReader { g in Color.clear
                        .preference(key: DrawingShieldFrameKey.self, value: g.frame(in: .named("chart"))) })
            }
        }
        .onPreferenceChange(DrawingPanelFrameKey.self) { lowerPanelChartFrame = $0 }
        .onPreferenceChange(DrawingShieldFrameKey.self) { overlayChartFrame in
            guard let overlay = overlayChartFrame, let lp = lowerPanelChartFrame else {
                engine.drawingSession.setShieldRect(nil, panel: .lower); return
            }
            let local = overlay.offsetBy(dx: -lp.minX, dy: -lp.minY)
            engine.drawingSession.setShieldRect(local, panel: .lower)
        }
        // 镜像 TrainingView 的显式清盾防御——生产里这行是「防御 + 明确生命周期」的第二层保险
        // （nil-preference 自动清是第一层）。测试镜像原样带上，保证与生产行为一致。
        .onChange(of: typeRowExpanded) { _, _ in
            engine.drawingSession.setShieldRect(nil, panel: .lower)
        }
    }
}

/// `ImageRenderer`（iOS 16+/Catalyst）强制**同步**跑完整棵 SwiftUI 树的布局——官方 headless 渲染入口，
/// 明确为离屏导出（PDF/图片）场景设计，不依赖 UIWindow/Scene，读取 `.uiImage` 即触发同步渲染并等待完成。
/// 比 `UIHostingController` + `layoutIfNeeded()`/RunLoop spin 更可靠（后者在无窗口场景下多轮实测不稳，
/// 见 TrainingShellLayout 头部大注释）。每次调用都是一次独立、确定性的完整渲染——不依赖「同一活体树背后
/// 再收敛一次」的隐含时序假设，故 collapse 断言直接构造一个新的 `typeRowExpanded: false` 值重渲染即可。
/// **不额外包一层 `.frame(height:)`**（真实踩坑：曾包了个 300pt 高的外框，SwiftUI 把只有 ~100pt 高的
/// 真实内容**垂直居中**塞进那个更高的画布，shield 的 y 坐标因此被系统性下移——`TrainingShellLayout`
/// 自己已经 `.frame(width:)` 钉了宽，高度交给 VStack 的固定高度子项自然撑出，不需要、也不能外部乱套尺寸。
@MainActor
private func renderAndConverge<V: View>(_ view: V) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    _ = renderer.uiImage
}

extension DrawingTapHitShieldTests {

    @Test("点落在样式面板 shield 内 → 不落锚、不 commit（drawings.count 不变）——面板吃触摸不穿透")
    func tapInsidePanelShieldDoesNotCommit() throws {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 480)
        let (handle, engine) = makeDrawingActiveChart(bounds: bounds)
        engine.drawingSession.setShieldRect(CGRect(x: 0, y: 400, width: 390, height: 80), panel: .lower)
        let before = engine.drawings.count
        handle.handleDrawingTapForTesting(at: CGPoint(x: 100, y: 440))   // 面板 shield 内一点
        #expect(engine.drawings.count == before)
    }

    @Test("点落在面板 shield 外的 K 线区 → 正常落线（屏蔽只挡面板内）")
    func tapOutsidePanelStillCommits() throws {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 480)
        let (handle, engine) = makeDrawingActiveChart(bounds: bounds)
        engine.drawingSession.setShieldRect(CGRect(x: 0, y: 400, width: 390, height: 80), panel: .lower)
        let before = engine.drawings.count
        handle.handleDrawingTapForTesting(at: leftmostMainChartPoint(handle))   // shield 外、可见几何内一点
        #expect(engine.drawings.count == before + 1)
    }

    @Test("真路径差分（codex 计划-R6-high）：面板 shield 覆盖的、**本可落线**的点——装盾时被拒、清盾时落线；count 与 pendingAnchors 都验")
    func shieldBlocksOtherwiseCommittingTap() throws {
        let (handle, engine) = makeDrawingActiveChart()
        // 展开真 overlay → 真 shield 装入（GeometryReader→onPreferenceChange→转换→setShieldRect 整链）。
        renderAndConverge(TrainingShellLayout(engine: engine, typeRowExpanded: true))
        let shield = try #require(engine.drawingSession.shieldRect[1])
        let mainChart = handle.renderState.viewport.mainChartFrame   // 下面板**可落线**区（成交量/MACD 区已被既有守卫拒）
        let p = CGPoint(x: shield.midX, y: shield.midY)
        try #require(mainChart.contains(p))   // ⭐关键：采样点须落在「可落线区 ∩ shield」——否则 count 不变可能与 shield 无关（假绿）

        // ① 装盾 → 拒：count 与 pendingAnchors 均不变
        let c0 = engine.drawings.count, pend0 = engine.drawingSession.pendingAnchors.count
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0)
        #expect(engine.drawingSession.pendingAnchors.count == pend0)

        // ② 收起清盾 → 同一点落线：证明①的差别确由 shield 造成（非该点本就不可落 / 非死区）。
        // 全新一次独立、确定性的 ImageRenderer 渲染（不依赖「同一活体树背后再收敛一次」的隐含时序假设）。
        renderAndConverge(TrainingShellLayout(engine: engine, typeRowExpanded: false))
        #expect(engine.drawingSession.shieldRect[1] == nil)
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0 + 1)
    }

    @Test("复盘负向（codex 计划-R4-medium）：复盘态（showsTradeButtons==false）即便 drawingModeActive，也**不装 overlay、不装盾**——复盘图表点不被吞")
    func reviewModeInstallsNoOverlayNoShield() throws {
        let (handle, engine) = makeReviewDrawingActiveChart()
        renderAndConverge(TrainingShellLayout(engine: engine, typeRowExpanded: true))
        #expect(engine.drawingSession.shieldRect.isEmpty)            // 复盘不装盾
        let before = engine.reviewDrawings.count                     // 复盘提交路径 = reviewDrawings（routeDrawingCommit）
        handle.handleDrawingTapForTesting(at: leftmostMainChartPoint(handle))   // 复盘图表点正常（不被吞）
        #expect(engine.reviewDrawings.count == before + 1)
    }
}
#endif

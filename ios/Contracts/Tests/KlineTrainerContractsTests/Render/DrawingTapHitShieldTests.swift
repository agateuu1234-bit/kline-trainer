// ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingTapHitShieldTests.swift
// Spec: docs/superpowers/specs/2026-07-17-drawing-tools-P1b-1a-iii-shell-interaction.md（切片1 Task2）
//     + docs/superpowers/specs/2026-07-18-drawing-tools-P1b-1a-iii-panel-redesign-design.md（切片2 Task2）
// 类型行改 overlay（不占 VStack 高度）+ 命中屏蔽：DrawingSession.shield（PanelShield 三态，面板局部坐标） +
// ChartContainerView.handleDrawingTap 拒收盾内点/pending 窗口 + TrainingView 三 PreferenceKey 上报/求交/清盾。
// 切片2 Task2：屏蔽泛化到**两个面板**（overlay ∩ 每个面板 frame），并把切片1 的 shieldRect/setShieldRect
// 整体替换为 PanelShield 三态 API（.unshielded/.pending/.rect）——「面板可见却没有屏蔽」这一危险状态
// 从类型上不可表达，取代切片1 靠 nil-preference 侥幸清盾的设计。
//
// 平台门：deactivateClearsShields / typeRowIsShieldedOverlayNotVStackMember / splitBarsCarryD19D24 /
// clearAllShieldsClearsBothPanels / shieldWindowIsFailClosed / partialGeometryNeverSettles /
// shieldInstallIsGeometricNotPositionHardcoded 是 host-pure（直构 DrawingSession、无 UIKit 类型 /
// 纯源码字符串守卫）→ host `swift test` 覆盖。其余触 ChartContainerView.Coordinator / ImageRenderer 的
// 测试 `#if canImport(UIKit)` 门仅 Catalyst/iOS 跑（codex 计划-R6-medium：host swift test 不编译这些）。
import Foundation
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

// .serialized（同既有 TrainingEngineBounceWiringTests/DecelerationAnimatorBounceTests 等先例）：
// 本 suite 多个测试并发驱动 SwiftUI 渲染（ImageRenderer/曾试过的 UIHostingController），排查早期
// UIHostingController 方案抖动时怀疑过并发跨测试共享渲染上下文，改用 ImageRenderer 后未再复现，
// 但仍保留 .serialized 作为安全网（同既有先例，不给并发渲染管线留隐患）。
@MainActor
@Suite("类型行 overlay 命中屏蔽（1a-iii 切片1/2 Task2）", .serialized)
struct DrawingTapHitShieldTests {

    @Test("模型不变量（codex 计划-R3）：DrawingSession.deactivate() 清空所有面板屏蔽（退画线无残留盾）")
    func deactivateClearsShields() throws {
        let session = DrawingSession()
        session.setShield(.rect(CGRect(x: 0, y: 40, width: 390, height: 120)), panel: .lower)
        session.deactivate()
        #expect(session.shield.isEmpty)
    }

    @Test("模型不变量：clearAllShields() 清空所有面板的盾（防显式清盾时漏清某个面板留下死区）")
    func clearAllShieldsClearsBothPanels() throws {
        let session = DrawingSession()
        session.setShield(.rect(CGRect(x: 0, y: 0, width: 390, height: 80)), panel: .upper)
        session.setShield(.rect(CGRect(x: 0, y: 0, width: 390, height: 80)), panel: .lower)
        session.clearAllShields()
        #expect(session.shield.isEmpty)
    }

    @Test("盾未就位窗口 fail-closed（codex 计划-R14-F1）：面板可见但盾没算过 → 状态可表达且默认拒收")
    func shieldWindowIsFailClosed() throws {
        let s = DrawingSession()
        #expect(s.shield.isEmpty, "初始无任何面板屏蔽")
        s.setStylePanelVisible(true)
        #expect(s.shield[0] == .pending && s.shield[1] == .pending,
                "面板挂载即应把**两个**面板置 .pending（拒收窗口的唯一表达）")
        s.setShield(.unshielded, panel: .upper)
        s.setShield(.rect(CGRect(x: 0, y: 0, width: 10, height: 10)), panel: .lower)
        #expect(s.shield[0] == .unshielded)
        s.setStylePanelVisible(false)
        #expect(s.shield.isEmpty, "面板卸载即全清")
        s.setStylePanelVisible(true)
        s.clearAllShields()
        #expect(s.shield.isEmpty, "clearAllShields 全清；后续由 setStylePanelVisible/refreshShields 重新置位")
    }

    @Test("模型不变量（whole-branch fix，item4）：生命周期 onChange 现在调 setStylePanelVisible(true) 而非 clearAllShields()——即便两面板已收敛出真实值，再次调用也能把它们拉回 .pending（fail-closed 方向）")
    func setStylePanelVisibleRestoresPendingAfterSettledShields() throws {
        let s = DrawingSession()
        s.setStylePanelVisible(true)
        #expect(s.shield[0] == .pending && s.shield[1] == .pending, "面板挂载即两面板 .pending")

        // 模拟一次成功收敛的 refreshShields()：两面板都写入真实值（非 .pending）。
        s.setShield(.rect(CGRect(x: 0, y: 0, width: 10, height: 10)), panel: .upper)
        s.setShield(.unshielded, panel: .lower)
        #expect(s.shield[0] != .pending && s.shield[1] != .pending, "前置条件：确已收敛出真实值，而非仍是 .pending")

        // 生命周期事件（如 drawingModeActive/typeRowExpanded/stylePanelPosition 的 onChange）再次触发
        // setStylePanelVisible(true)——必须把两面板拉回 .pending，不是保留旧真实值，更不是变成 absent。
        s.setStylePanelVisible(true)
        #expect(s.shield[0] == .pending && s.shield[1] == .pending,
                "whole-branch fix：生命周期事件必须能把已收敛的盾拉回 .pending（fail-closed），不能是 no-op")
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

        // 1a-iii 切片1 Task3：chartPanels 正文抽成共享 ChartPanelsContainer（供
        // hosted 布局不变量测试复用，抽共享、不复制）——chartPanels 自身现在只是薄委托，真断言挪到
        // ChartPanelsContainer 的正文上；先确认薄委托真调用了共享容器（未被内联/复制回来）。
        let chartPanelsBody = try extractBody(tv, from: "private var chartPanels: some View {", to: "private func panel(_ id: PanelId)")
        #expect(chartPanelsBody.contains("ChartPanelsContainer("))

        // ChartPanelsContainer 正文内，唯一锚定类型行 overlay 接线：DrawingStylePanel( + 两个
        // PreferenceKey 上报/转换必须同挂在同一个 .overlay(alignment:) 块里，而不是随便一处
        // 泛 `.overlay(alignment: .bottom)`（panel(_:) 里同名但不带这些）。
        let containerBody = try extractBody(tv, from: "struct ChartPanelsContainer<Upper: View, Lower: View>: View {", to: "#if DEBUG")
        // 切片2 Task2：DrawingPanelFrameKey 改名 DrawingLowerPanelFrameKey + 新增 DrawingUpperPanelFrameKey
        // （两个面板都上报 frame，求交装两个面板的盾）。
        // 切片2 Task3：挂载点内容从 DrawingTypeOverlay( 换成 DrawingStylePanel(（常驻面板替代类型行 overlay）。
        // 切片2 Task4：alignment 随 stylePanelPosition 切（.top/.bottom），旧的固定 ".bottom" 字面量已消失。
        for marker in [".overlay(alignment: stylePanelPosition == .top ? .top : .bottom)", "DrawingStylePanel(", "DrawingShieldFrameKey",
                       "DrawingUpperPanelFrameKey", "DrawingLowerPanelFrameKey", "offsetBy"] {
            #expect(containerBody.contains(marker))
        }

        // 切片2 Task2：setShieldRect 已被 PanelShield 三态 API 取代，接线断言改锚 refreshShields。
        #expect(tv.contains("refreshShields"))
        // P1b-1a-iii 回归修复：旧三 bool 逗号门 `showsTradeButtons, isDrawingActive, typeRowExpanded` 已
        // 收敛成单一预测谓词 `stylePanelWillBeVisible`（TrainingView 唯一权威定义），本容器改读传入参数
        // `stylePanelVisible`。断言新形式仍锚定 showsTradeButtons（== 复盘门，天然排除复盘）。
        #expect(tv.contains("stylePanelWillBeVisible: Bool { showsTradeButtons && isDrawingActive && typeRowExpanded }"))
        // 切片2 Task3：第一道盾上移到 DrawingStylePanel 根（DrawingTypeOverlay 不再自带 contentShape）。
        let dsp = try readSource("UI/DrawingStylePanel.swift")
        #expect(dsp.contains(".contentShape(Rectangle())"))
        let cc = try readSource("Render/ChartContainerView.swift")
        // 切片2 Task2：ChartContainerView 侧断言也改锚新 API——session.shield[...] 三态 switch，
        // 本地绑定改名 shield（同旧变量名，保持 `shield.contains(point)` 字面锚不变）。
        #expect(cc.contains("session.shield[") && cc.contains("shield.contains(point)"))
    }

    @Test("到达顺序置换（codex 计划-R15-F1）：任何『几何未到齐』的中间态都不得标记收敛（fail-closed）")
    func partialGeometryNeverSettles() throws {
        // 纯状态推演：模拟 refreshShields 的开闸判据，穷举三个 frame 的到达顺序。
        func settles(overlay: Bool, upper: Bool, lower: Bool) -> Bool { overlay && upper && lower }
        let flags = [false, true]
        for o in flags { for u in flags { for l in flags {
            let complete = o && u && l
            #expect(settles(overlay: o, upper: u, lower: l) == complete,
                    "几何(overlay:\(o) upper:\(u) lower:\(l)) 的开闸判据错误 —— 部分几何开闸=裸奔窗口")
        } } }
        // 并断言判据真的写在生产代码里（防等价逻辑与生产漂移）。
        let tv = try readSource("UI/TrainingView.swift")
        #expect(tv.contains("stylePanelChartFrame != nil, upperPanelChartFrame != nil, lowerPanelChartFrame != nil"),
                "refreshShields 未按『几何到齐』开闸 —— 部分几何会打开 fail-closed 窗口")
    }

    @Test("源码快检：盾用『overlay ∩ 每个面板 frame』求交装盾，且显式清盾走 clearAllShields（非逐面板漏清）")
    func shieldInstallIsGeometricNotPositionHardcoded() throws {
        let tv = try readSource("UI/TrainingView.swift")
        #expect(tv.contains("refreshShields"))
        #expect(tv.contains(".intersection("))                       // 求交，而非按位置选面板
        #expect(tv.contains("DrawingUpperPanelFrameKey"))            // 上面板也上报 frame
        #expect(tv.contains("clearAllShields"))                      // 显式清盾一次清两面板
        #expect(!tv.contains("setShieldRect"))       // 切片1 的旧 API 必须整体绝迹（已被 PanelShield 三态取代）
        let cc = try readSource("Render/ChartContainerView.swift")
        #expect(cc.contains("session.shield[") && cc.contains("shield.contains(point)"))   // 输入层守卫仍在，新 API
        #expect(!cc.contains("shieldRect"))                          // 旧 API 在输入层也整体绝迹
    }

    @Test("D19/D24：拆分后控件齐、无未接线键（迁自 DrawingModeBarSourceGuardTests；切片2 去长按钩子）")
    func splitBarsCarryD19D24() throws {
        let overlay = try readSource("UI/DrawingTypeOverlay.swift")
        let bottom  = try readSource("UI/DrawingModeBar.swift")   // DrawingBottomBar 与 DrawingModeBar 同文件
        #expect(overlay.contains("accessibilityLabel(\"水平线\")"))   // 类型行水平线图标恒亮（不变）
        // ⭐切片2：长按卡片已被常驻面板取代 → 钩子必须消失（与 DrawingStylePanelSourceGuardTests
        //   .longPressCardRetired 同向，不再自相矛盾）。
        #expect(!overlay.contains("onLongPressType"))
        #expect(!overlay.contains("LongPressGesture"))
        // ⭐切片2 新增接线：⇅ 切上下半区（Task4 接真行为，Task3 已把按钮与回调放上）。
        #expect(overlay.contains("onTogglePosition"))
        #expect(bottom.contains("accessibilityLabel(\"类型\")"))       // ①类型键（不变）
        for banned in ["accessibilityLabel(\"锁定\")", "accessibilityLabel(\"删除\")",
                       "accessibilityLabel(\"撤销\")", "accessibilityLabel(\"前进\")"] {   // ②–⑤ 仍不渲染
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

/// 双高面板 fixture：上下面板都足够高，使展开的样式面板**整块**落在其中一个面板内
/// （下半区 ⇒ 只碰下面板；上半区 ⇒ 只碰上面板）。与既有 60/40 矮 fixture 分工：
///   - 矮 fixture（shieldTestUpperPanelHeight/LowerPanelHeight）：测「面板跨越两面板 ⇒ 两个盾都装」。
///   - 本 fixture：测「面板只碰一个面板 ⇒ 另一个面板必须无盾」+「切位置后旧盾必须清空（== nil，非『矮一点』）」。
/// 400 是起始值——若实测样式面板高于它，测试里的 #require 会明确报错要求调大。
private let shieldTestTallPanelHeight: CGFloat = 400

/// codex 计划-R5-F1 / R6-F1：让 Task2 阶段那个 ~44pt 的**贴底**类型行 overlay 能真正盖到
/// **上面板的可落线区**（mainChart = 面板顶部 60%）。关键几何：overlay 贴的是**整个容器**底部，所以
/// 往上探进上面板的量 = overlay高 − 下面板高——杠杆是下面板高度，不是上面板高度。
/// 正确判据：两个面板高度之和 < overlay 高度，贴底 overlay 就把上下面板整个盖满（实测校准，见 Task2 report）。
private let shieldTestShortUpperPanelHeight: CGFloat = 24
private let shieldTestShortLowerPanelHeight: CGFloat = 8

/// 一个真 Coordinator + 真 KLineView 的最小手柄，挂在**已存在的** engine 上（codex 计划-R11-F1，防跨 engine 假绿）。
/// 凡是「一个测试里同时驱动上下两个面板」的场景**必须**用它——`makeDrawingActiveChart` 每次新建 engine，
/// 二次调用会让两个 handle 绑到不同 engine。
@MainActor
private func makeChartHandle(engine: TrainingEngine, panel: PanelId, bounds: CGRect) -> DrawingChartHandle {
    let coordinator = ChartContainerView(panel: panel, engine: engine).makeCoordinator()
    let view = KLineView(frame: bounds)
    coordinator.attach(to: view)
    coordinator.rebuildRenderState(bounds: bounds)
    return DrawingChartHandle(coordinator: coordinator, kLineView: view)
}

/// 造一个「已开全局画线会话」的面板 rig（宽 reveal 窗口：count=200/tick=150/.m3 周期，
/// 避免 TrainingEngine.preview() 默认小 fixture 的 reveal 窄切片把 mid-panel 的 x 坐标判成越界，codex 计划-R6 附带教训）。
/// 切片2 Task2：加 `panel:` 参数（默认 `.lower`，保既有调用点源兼容），各 rig 工厂共用同一份接线（不复制）。
@MainActor
private func makeDrawingActiveChart(panel: PanelId = .lower, bounds: CGRect = shieldTestLowerPanelBounds) -> (DrawingChartHandle, TrainingEngine) {
    let (engine, _) = TrainingEngineBounceWiringTests.makeEngine(count: 200, tick: 150)
    engine.toggleDrawingMode()   // D42 全局会话：两面板一起武装 .horizontal（画图钮/浮动钮同一入口）
    return (makeChartHandle(engine: engine, panel: panel, bounds: bounds), engine)
}

/// 取某面板当前的**屏蔽矩形**；`.unshielded` / `.pending` 都返回 nil。
/// ⚠️断言「该面板不被屏蔽」时**不要**用 `shieldRectOf(...) == nil`——那把 `.pending`（正在 fail-closed
/// 拒收）也算成「不屏蔽」，会放过「几何未收敛却以为没事」的假绿。要证明真的开放，断言 `session.shield[k] == .unshielded`。
@MainActor
private func shieldRectOf(_ engine: TrainingEngine, _ key: Int) -> CGRect? {
    if case .rect(let r) = engine.drawingSession.shield[key] { return r }
    return nil
}

/// 差分测试第二阶段用：清掉所有盾，**并**显式标记两个面板为「几何已收敛、且确实不被覆盖」。
/// 不能用 `clearAllShields()` 代替——那会回到「无 key」，而面板此刻仍 `stylePanelVisible`，
/// 下一次 `setStylePanelVisible(true)` 或残留 `.pending` 会让 `handleDrawingTap` 继续拒收，
/// **正确实现反而让测试红**，进而诱导实施者去削弱 fail-closed。
@MainActor
private func settleWithNoShields(_ session: DrawingSession) {
    session.setShield(.unshielded, panel: .upper)
    session.setShield(.unshielded, panel: .lower)
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

/// 1a-iii 切片2 Task2：不再手抄一份 chartPanels 接线（切片1 遗留的镜像风险，reviewer 记为 Minor）。
/// 直接渲染**生产** `ChartPanelsContainer`，只把上下面板换成等尺寸占位——盾的整条链
/// （GeometryReader → PreferenceKey → refreshShields → setShield）测的就是生产那一份。
/// showsTradeButtons/isDrawingActive 直接读 engine（与生产 TrainingView 同源计算属性），不额外接参数，
/// 防「测试自己传的 mode 参数」与「engine 真实状态」两者漂移不一致的假象。
///
/// 切片2 Task3：`ChartPanelsContainer` 签名已改（去 `onLongPressType`，加 `scheme`/`stylePanelPosition`/
/// `onTogglePosition`）——本结构固定传 `stylePanelPosition: .bottom`（本 task 三个外壳都无自己的位置状态，
/// Task4 才让位置态可变）。
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
/// 值 + 全新 `ImageRenderer` 强制同步渲染，不依赖任何「同一活体树背后再收敛一次」的隐含时序假设，实测稳定可重复。
/// **实测发现（Task2）**：这条「不依赖同一活体树」的性质意味着 `.onDisappear` **不会**跨两次独立渲染触发
/// （每次都是全新 view graph，从未见过上一次的树，无「消失」可言）——故差分测试的第二阶段一律用
/// `settleWithNoShields`（直接置位，不靠再渲一次 `typeRowExpanded:false` 来触发生产的 onDisappear 清盾）。
@MainActor
private struct TrainingShellLayout: View {
    let engine: TrainingEngine
    var typeRowExpanded: Bool = true

    private var showsTradeButtons: Bool { engine.flow.canBuySell() }
    private var isDrawingActive: Bool { engine.drawingSession.drawingModeActive }

    var body: some View {
        // P1b-1a-iii 回归修复：ChartPanelsContainer 现只收一个收敛后的 stylePanelVisible 参数——
        // 本壳在调用处自己算好三 bool 合取（与 TrainingView.stylePanelWillBeVisible 同一表达式）。
        ChartPanelsContainer(
            engine: engine,
            stylePanelVisible: showsTradeButtons && isDrawingActive && typeRowExpanded,
            scheme: .light,                 // 测试固定日间，避免随宿主外观漂移
            stylePanelPosition: .bottom,    // 本 task 三个外壳都不带自己的 stylePanelPosition 状态，固定传 .bottom
            onTogglePosition: {},           // 测试不驱动 ⇅（Task4 的位置切换靠重新构造外壳值渲染，非回调）
            upperPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: shieldTestUpperPanelHeight) },
            lowerPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: shieldTestLowerPanelHeight) })
            .frame(width: shieldTestPanelWidth)
    }
}

/// 双高面板 fixture 外壳：上下面板都 `shieldTestTallPanelHeight` 高，供「面板整块落在单个面板内」的
/// 精确判据测试（不过度屏蔽 + 切位置后旧盾清空）用，见 fixture 常量注释。
@MainActor
private struct TallPanelsShellLayout: View {
    let engine: TrainingEngine
    var typeRowExpanded: Bool = true
    var stylePanelPosition: DrawingStylePanelPosition = .bottom   // Task4：位置切换靠重新构造外壳值渲染，非回调

    var body: some View {
        ChartPanelsContainer(
            engine: engine,
            stylePanelVisible: engine.flow.canBuySell() && engine.drawingSession.drawingModeActive && typeRowExpanded,
            scheme: .light,                 // 测试固定日间，避免随宿主外观漂移
            stylePanelPosition: stylePanelPosition,
            onTogglePosition: {},           // 测试不驱动 ⇅（Task4 的位置切换靠重新构造外壳值渲染，非回调）
            upperPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: shieldTestTallPanelHeight) },
            lowerPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: shieldTestTallPanelHeight) })
            .frame(width: shieldTestPanelWidth)
    }
}

/// 矮上/极矮下面板外壳：让 Task2 阶段那个贴底类型行 overlay 把上下面板**整个盖满**（见
/// shieldTestShortUpperPanelHeight/shieldTestShortLowerPanelHeight 注释的几何推导）。
@MainActor
private struct ShortUpperShellLayout: View {
    let engine: TrainingEngine
    var typeRowExpanded: Bool = true
    var body: some View {
        ChartPanelsContainer(
            engine: engine,
            stylePanelVisible: engine.flow.canBuySell() && engine.drawingSession.drawingModeActive && typeRowExpanded,
            scheme: .light,                 // 测试固定日间，避免随宿主外观漂移
            stylePanelPosition: .bottom,    // 本 task 三个外壳都不带自己的 stylePanelPosition 状态，固定传 .bottom
            onTogglePosition: {},           // 测试不驱动 ⇅（Task4 的位置切换靠重新构造外壳值渲染，非回调）
            upperPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: shieldTestShortUpperPanelHeight) },
            lowerPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: shieldTestShortLowerPanelHeight) })
            .frame(width: shieldTestPanelWidth)
    }
}

/// codex R2-medium 回归复现专用外壳：上下面板高度**各自独立可配**（既有外壳都把两者锁死相等或共用同一
/// 常量），用于精确构造「样式面板高 + 16pt 竖直 padding == 容器总高」这一退化条件——此时 `.top`/`.bottom`
/// 两种 alignment 会把（未加 padding 的）样式面板 frame 摆到**同一个** CGRect（对齐边界退化成同一位置），
/// 三个 `DrawingUpperPanelFrameKey`/`DrawingLowerPanelFrameKey`/`DrawingShieldFrameKey` preference 值在
/// 切位置前后**恒不变**，三条 `onPreferenceChange` 一条都不会触发，`refreshShields()` 从此再也不会重跑（见
/// `toggleWithIdenticalGeometryEventuallySettles` 的详细复现/验证手法说明）。
@MainActor
private struct AsymmetricPanelsShellLayout: View {
    let engine: TrainingEngine
    var stylePanelPosition: DrawingStylePanelPosition = .bottom
    let upperHeight: CGFloat
    let lowerHeight: CGFloat

    var body: some View {
        ChartPanelsContainer(
            engine: engine,
            stylePanelVisible: engine.flow.canBuySell() && engine.drawingSession.drawingModeActive,
            scheme: .light,                 // 测试固定日间，避免随宿主外观漂移
            stylePanelPosition: stylePanelPosition,
            onTogglePosition: {},           // 测试不驱动 ⇅（位置切换靠重新构造外壳值渲染，非回调）
            upperPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: upperHeight) },
            lowerPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: lowerHeight) })
            .frame(width: shieldTestPanelWidth)
    }
}

/// `ImageRenderer`（iOS 16+/Catalyst）强制**同步**跑完整棵 SwiftUI 树的布局——官方 headless 渲染入口，
/// 明确为离屏导出（PDF/图片）场景设计，不依赖 UIWindow/Scene，读取 `.uiImage` 即触发同步渲染并等待完成。
/// 比 `UIHostingController` + `layoutIfNeeded()`/RunLoop spin 更可靠（后者在无窗口场景下多轮实测不稳，
/// 见 TrainingShellLayout 头部大注释）。每次调用都是一次独立、确定性的完整渲染——不依赖「同一活体树背后
/// 再收敛一次」的隐含时序假设。**Task2 实测澄清**：正因为每次都是全新 view graph，`.onAppear` 会按当次
/// 参数如实触发，但 `.onDisappear` **不会**跨两次独立渲染触发（没有「上一次」可供对比出「消失」）——
/// 故第二阶段若要模拟「面板已收起、盾已清」，用 `settleWithNoShields` 直接置位，不要指望再渲一次
/// `typeRowExpanded:false` 就能让生产 `.onDisappear` 帮忙清盾。
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
        engine.drawingSession.setShield(.rect(CGRect(x: 0, y: 400, width: 390, height: 80)), panel: .lower)
        let before = engine.drawings.count
        handle.handleDrawingTapForTesting(at: CGPoint(x: 100, y: 440))   // 面板 shield 内一点
        #expect(engine.drawings.count == before)
    }

    @Test("点落在面板 shield 外的 K 线区 → 正常落线（屏蔽只挡面板内）")
    func tapOutsidePanelStillCommits() throws {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 480)
        let (handle, engine) = makeDrawingActiveChart(bounds: bounds)
        engine.drawingSession.setShield(.rect(CGRect(x: 0, y: 400, width: 390, height: 80)), panel: .lower)
        let before = engine.drawings.count
        handle.handleDrawingTapForTesting(at: leftmostMainChartPoint(handle))   // shield 外、可见几何内一点
        #expect(engine.drawings.count == before + 1)
    }

    @Test("真路径差分（codex 计划-R6-high）：面板 shield 覆盖的、**本可落线**的点——装盾时被拒、清盾时落线；count 与 pendingAnchors 都验")
    func shieldBlocksOtherwiseCommittingTap() throws {
        let (handle, engine) = makeDrawingActiveChart()
        // 展开真 overlay → 真 shield 装入（GeometryReader→onPreferenceChange→refreshShields→setShield 整链）。
        renderAndConverge(TrainingShellLayout(engine: engine, typeRowExpanded: true))
        let shield = try #require(shieldRectOf(engine, 1))
        let mainChart = handle.renderState.viewport.mainChartFrame   // 下面板**可落线**区（成交量/MACD 区已被既有守卫拒）
        let p = CGPoint(x: shield.midX, y: shield.midY)
        try #require(mainChart.contains(p))   // ⭐关键：采样点须落在「可落线区 ∩ shield」——否则 count 不变可能与 shield 无关（假绿）

        // ① 装盾 → 拒：count 与 pendingAnchors 均不变
        let c0 = engine.drawings.count, pend0 = engine.drawingSession.pendingAnchors.count
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0)
        #expect(engine.drawingSession.pendingAnchors.count == pend0)

        // ② 清盾 → 同一点落线：证明①的差别确由 shield 造成（非该点本就不可落 / 非死区）。
        // Task2 实测发现（migration-matrix 缺口）：原稿这里再渲一次 `typeRowExpanded:false` 期望
        // 生产 `.onDisappear` 帮忙清盾——但 `renderAndConverge` 每次都是全新 view graph，`.onDisappear`
        // 跨两次独立渲染不会触发（见 TrainingShellLayout / renderAndConverge 头部大注释），盾会停在
        // `.rect` 原值上，`#expect(... == nil)` 会假红。改用 `settleWithNoShields`（同新增
        // upperPanelShieldBlocksOtherwiseCommittingTap 的第二阶段手法）。
        settleWithNoShields(engine.drawingSession)
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0 + 1)
    }

    @Test("复盘负向（codex 计划-R4-medium）：复盘态（showsTradeButtons==false）即便 drawingModeActive，也**不装 overlay、不装盾**——复盘图表点不被吞")
    func reviewModeInstallsNoOverlayNoShield() throws {
        let (handle, engine) = makeReviewDrawingActiveChart()
        renderAndConverge(TrainingShellLayout(engine: engine, typeRowExpanded: true))
        #expect(engine.drawingSession.shield.isEmpty)                // 复盘不装盾
        let before = engine.reviewDrawings.count                     // 复盘提交路径 = reviewDrawings（routeDrawingCommit）
        handle.handleDrawingTapForTesting(at: leftmostMainChartPoint(handle))   // 复盘图表点正常（不被吞）
        #expect(engine.reviewDrawings.count == before + 1)
    }

    // P1b-1a-iii 回归修复（HIGH，codex adversarial review，6a84fa5 引入）：TrainingView 不可渲染
    // （无 renderable 宿主），故本测试不驱动真实 TrainingView 生命周期 onChange，而是直接模拟旧 bug
    // 制造出的模型态——三个生命周期 onChange 曾无条件调用 `setStylePanelVisible(true)`，即便样式面板
    // 在复盘态根本不会挂载（showsTradeButtons==false，overlay 从不出现）。一旦两面板卡在 `.pending`，
    // 复盘态没有任何 onPreferenceChange 会再触发 `ChartPanelsContainer.refreshShields()` 来解开它
    // （面板从未挂载，没有 GeometryReader 上报新 frame）——`ChartContainerView.handleDrawingTap` 读到
    // `.pending` 恒拒收，reviewDrawings 永久停止增长。本测试证明：①危害是真实的（两面板 `.pending` 时
    // 复盘 tap 被拒收，与 reviewModeInstallsNoOverlayNoShield 的「无 key 时正常放行」形成对照）；
    // ②`clearAllShields()`（即 TrainingView.syncPanelShields() 在 `stylePanelWillBeVisible == false`
    // 分支所做的事）确实是解除死锁的闸门——同一点在清盾后能落线。
    @Test("回归复现（P1b-1a-iii HIGH，6a84fa5）：复盘态两面板若卡在 .pending，tap 被永久拒收；clearAllShields() 后同点能落线")
    func reviewModePendingShieldsBlockTapUntilCleared() throws {
        let (handle, engine) = makeReviewDrawingActiveChart()
        let p = leftmostMainChartPoint(handle)
        // 复现旧 bug：模拟三个生命周期 onChange 曾经无条件调用的 setStylePanelVisible(true)——复盘态
        // 样式面板从不挂载，没有任何后续 onPreferenceChange 能重新触发 refreshShields() 来解开它。
        engine.drawingSession.setStylePanelVisible(true)
        #expect(engine.drawingSession.shield[0] == .pending && engine.drawingSession.shield[1] == .pending)
        let before = engine.reviewDrawings.count
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.reviewDrawings.count == before, ".pending 窗口内竟落了线 —— 未复现出回归本应有的拒收")
        // 修复后 syncPanelShields() 在 stylePanelWillBeVisible == false 时改调 clearAllShields()——
        // 同一点应恢复可落线，证明危害确由残留 .pending 造成、且清盾正是解除它的闸门。
        engine.drawingSession.clearAllShields()
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.reviewDrawings.count == before + 1, "clearAllShields() 后同一点仍落不了线 —— 拒收未被正确解除")
    }

    @Test("盾泛化真路径（trade-safety）：overlay 高到跨越上下两面板 → **两个**面板各自装盾，上面板不再裸奔")
    func tallOverlayShieldsBothPanels() throws {
        let (_, engine) = makeDrawingActiveChart()
        // 下面板仅 40pt 高、上面板 60pt；样式面板（类型行 + 5 组参数）必然高于 40pt → 必跨进上面板。
        renderAndConverge(TrainingShellLayout(engine: engine, typeRowExpanded: true))
        let lower = try #require(shieldRectOf(engine, 1), "下面板盾缺失")
        let upper = try #require(shieldRectOf(engine, 0),
                                 "上面板盾缺失 —— overlay 已探进上面板却无盾 = 点面板会在上半 K 线误落线")
        #expect(!lower.isEmpty && !upper.isEmpty)
        // 盾是**该面板局部**坐标：上面板盾必须贴着上面板底边（overlay 从下往上探进来的那一截），
        // 而不是原封不动的 chart 空间坐标（后者会把偏移一起带进来、挡错地方）。
        #expect(upper.maxY <= shieldTestUpperPanelHeight + 0.5)
    }

    @Test("收起态：无 overlay → 两面板都无盾（基础清盾，**不算**不过度屏蔽的证据）")
    func collapsedOverlayInstallsNoShield() throws {
        let (_, engine) = makeDrawingActiveChart()
        renderAndConverge(TrainingShellLayout(engine: engine, typeRowExpanded: false))
        // whole-branch fix（item9）：不用 shieldRectOf(...) == nil —— 那正是本文件 :237-238 自己禁止的
        // 反模式，`.pending`（正在 fail-closed 拒收）也会让 shieldRectOf 返回 nil，与「真的没有屏蔽」混为一谈。
        // 断言 shield.isEmpty 才证明真的没有任何 key（同 reviewModeInstallsNoOverlayNoShield 的做法）。
        #expect(engine.drawingSession.shield.isEmpty)
    }

    @Test("不过度屏蔽（codex 计划-R1-F1）：面板**可见且完全落在下面板内**时，上面板必须无盾、且上半 K 线照常落线")
    func visibleLowerOnlyOverlayLeavesUpperUnshielded() throws {
        // ⭐codex 计划-R1-F1：原稿这条用 typeRowExpanded:false（根本没 overlay）→ **空测试**：
        //   一个「只要有可见 overlay 就连上面板一起装盾」的错误实现照样能过，上半 K 线死区测不出来。
        //   必须让 overlay **真的可见**、且**整块落在下面板内**，才能证明「交到谁才挡谁」。
        // 故用双高面板 fixture（上下都 tallPanelHeight），下半区面板整块装得下。
        let (upperHandle, engine) = makeDrawingActiveChart(
            panel: .upper, bounds: CGRect(x: 0, y: 0, width: shieldTestPanelWidth, height: shieldTestTallPanelHeight))
        renderAndConverge(TallPanelsShellLayout(engine: engine, typeRowExpanded: true))

        let lower = try #require(shieldRectOf(engine, 1), "下半区时下面板必须有盾")
        // 前提自检：面板必须**真的装得下**在下面板内——否则本测试退化成「跨面板」场景、又变空测。
        try #require(lower.height < shieldTestTallPanelHeight,
                     "样式面板高于 fixture 面板高度 → 请调大 shieldTestTallPanelHeight（先打印实测高度，别猜）")
        #expect(engine.drawingSession.shield[0] == .unshielded,
                "上面板未处于 .unshielded（可能是 .pending 或被装了盾） —— overlay 明明没碰到上面板，属过度屏蔽（上半 K 线会出现死区）")
        // 差分正向：上半 K 线真能落线（光断言 shield==nil 不够，要证明「点得下去」）。
        let c0 = engine.drawings.count
        upperHandle.handleDrawingTapForTesting(at: leftmostMainChartPoint(upperHandle))
        #expect(engine.drawings.count == c0 + 1, "上半 K 线落不了线 —— 存在看不见的屏蔽")
    }

    @Test("上面板差分（trade-safety）：上面板被盾覆盖的、**本可落线**的点——装盾时被拒、清盾时落线")
    func upperPanelShieldBlocksOtherwiseCommittingTap() throws {
        // ⭐codex 计划-R5-F1/R6-F1（whole-branch fix：几何说明改述现状）：overlay 现在是常驻样式面板
        //   DrawingStylePanel（类型行 + 5 组参数整体），远高于早期仅类型行的 ~44pt，且贴底对齐。
        //   往上探进上面板的量 = overlay高 − 下面板高——用极矮的上/下面板 fixture，使两者高度之和
        //   < overlay 高度，贴底 overlay 就把上下面板整个盖满。fixture 数值（24/8）仍成立，几何原理不变。
        let (handle, engine) = makeDrawingActiveChart(panel: .upper,
                                                      bounds: CGRect(x: 0, y: 0,
                                                                     width: shieldTestPanelWidth,
                                                                     height: shieldTestShortUpperPanelHeight))
        renderAndConverge(ShortUpperShellLayout(engine: engine, typeRowExpanded: true))
        let shield = try #require(shieldRectOf(engine, 0), "上面板必须有盾")
        // 采样点取「盾 ∩ 可落线区」的真实交集中点——不盲取 shield.midY。
        let hit = shield.intersection(handle.renderState.viewport.mainChartFrame)
        try #require(!hit.isNull && !hit.isEmpty,
                     """
                     盾与上面板可落线区无交集 → fixture 几何不成立（非产品缺陷，别去改产品或放松断言）。
                     几何：贴底 overlay 往上探进上面板的量 = overlay高 − 下面板高；上面板可落线区是其顶部 60%。
                     修法：继续调小 shieldTestShortLowerPanelHeight（首选）与 shieldTestShortUpperPanelHeight，
                     直到两者之和 < 实测 overlay 高度。绝不是调大。
                     排查先打印：shield=\(shield) mainChart=\(handle.renderState.viewport.mainChartFrame)
                     """)
        let p = CGPoint(x: hit.midX, y: hit.midY)
        let c0 = engine.drawings.count
        let pend0 = engine.drawingSession.pendingAnchors.count
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0)
        #expect(engine.drawingSession.pendingAnchors.count == pend0)
        // 清盾 → **同一点**落线：证明上面那次被拒确由盾造成（非该点本就不可落）。
        settleWithNoShields(engine.drawingSession)
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0 + 1)
    }

    @Test("窗口期差分（codex 计划-R14-F1）：stylePanelVisible 且盾未收敛 → 本可落线的点被拒；收敛后同点落线")
    func tapRefusedWhileShieldsUnsettled() throws {
        let (handle, engine) = makeDrawingActiveChart()
        let p = leftmostMainChartPoint(handle)
        engine.drawingSession.setStylePanelVisible(true)      // 面板刚挂载 → 两面板 .pending
        let c0 = engine.drawings.count
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0, ".pending 窗口内竟落了线 —— fail-closed 未生效")
        settleWithNoShields(engine.drawingSession)            // 几何收敛且该面板不被覆盖
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0 + 1, "收敛后同点仍落不了线 → 拒收范围过大（面板外也被吞）")
    }

    // ⚠️命名与范围（codex 计划-R2-F2）：本测试验的是**第二道盾（输入层）**的边界——
    //   `handleDrawingTapForTesting` 绕过 SwiftUI 命中测试，**证明不了** contentShape 那道盾。
    //   故函数名带 `InputLayer`，别让后来人把它读成「第一道盾已覆盖」。
    @Test("透明外边距不进**输入层**盾（codex 计划-R1-F2）：面板可见外接矩形**之外**的 8pt 空隙里点一下 → 正常落线，不是死条")
    func transparentGutterOutsideVisiblePanelStillCommits_inputLayer() throws {
        let (handle, engine) = makeDrawingActiveChart()
        renderAndConverge(TrainingShellLayout(engine: engine, typeRowExpanded: true))
        let shield = try #require(shieldRectOf(engine, 1))
        // 盾右缘之外 4pt（落在 8pt 透明边距带内）——用户看到的是「图表」，就该能画线。
        let p = CGPoint(x: shield.maxX + 4, y: shield.midY)
        try #require(handle.renderState.viewport.mainChartFrame.contains(p),
                     "采样点必须落在可落线区，否则本测试无意义（假绿）")
        let c0 = engine.drawings.count
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0 + 1,
                "面板可见边缘外的透明边距被算进了盾 → 图表上有看不见的死条")
    }

    @Test("上半区（镜像）盾（精确判据）：面板整块落在上面板内 → 上面板有盾贴顶边、下面板盾 == nil")
    func topPositionShieldsUpperPanelOnly() throws {
        let (lowerHandle, engine) = makeDrawingActiveChart(
            panel: .lower, bounds: CGRect(x: 0, y: 0, width: shieldTestPanelWidth, height: shieldTestTallPanelHeight))
        renderAndConverge(TallPanelsShellLayout(engine: engine, typeRowExpanded: true, stylePanelPosition: .top))

        let upper = try #require(shieldRectOf(engine, 0), "上半区时上面板必须有盾")
        // 前提自检：面板必须真的装得下在上面板内，否则退化成跨面板场景、本测试失去意义。
        try #require(upper.height < shieldTestTallPanelHeight,
                     "样式面板高于 fixture 面板高度 → 调大 shieldTestTallPanelHeight（先打印实测，别猜）")
        // 顶边对齐：盾顶边 == 上面板顶边 + 8pt 离屏边距（spec §2.3「类型行顶边贴上半 K 线顶边」）。
        #expect(abs(upper.minY - 8) <= 0.5, "盾未贴上面板顶边（期望 8pt 边距，实测 \(upper.minY)）")
        // ⭐精确判据：下面板完全没有盾（不是「矮一点」）。
        #expect(engine.drawingSession.shield[1] == .unshielded, "下面板未处于 .unshielded = 过度屏蔽或未收敛")
        let c0 = engine.drawings.count
        lowerHandle.handleDrawingTapForTesting(at: leftmostMainChartPoint(lowerHandle))
        #expect(engine.drawings.count == c0 + 1, "下半 K 线落不了线 —— 面板在上半区却挡住了下面板")

        // ⭐codex 计划-R10-F2：光断言「上面板有盾 + minY≈8」证明不了 §4.4 的「点面板空隙不落线」——
        //   一个尺寸过小/错位的上面板盾照样满足这两条，而可见面板下方大片区域仍会穿透并 autosave 幽灵线。
        //   必须补上面板的真差分：盾内可落线点 → 装盾时被拒、清盾后落线。
        // ⭐codex 计划-R11-F1：必须挂在同一个 engine 上，用 makeChartHandle 复用已渲染、已被断言的那个 engine。
        let upperHandle = makeChartHandle(
            engine: engine, panel: .upper,
            bounds: CGRect(x: 0, y: 0, width: shieldTestPanelWidth, height: shieldTestTallPanelHeight))
        let upperHit = upper.intersection(upperHandle.renderState.viewport.mainChartFrame)
        try #require(!upperHit.isNull && !upperHit.isEmpty,
                     "上面板盾与其可落线区无交集 → 盾尺寸/位置不对，点面板会在上半 K 线误落线")
        let p = CGPoint(x: upperHit.midX, y: upperHit.midY)
        let c1 = engine.drawings.count
        let pend1 = engine.drawingSession.pendingAnchors.count
        upperHandle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c1, "上半区面板内的点竟落了线 = 幽灵线（§4.4「点面板空隙不落线」违规）")
        #expect(engine.drawingSession.pendingAnchors.count == pend1)
        settleWithNoShields(engine.drawingSession)   // 清盾并回到已收敛态
        upperHandle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c1 + 1, "清盾后同一点仍落不了线 → 上面那次被拒与盾无关（假绿）")
    }

    @Test("⇅ 切位置后旧盾精确清零：下半区 → 上半区，下面板盾必须 == nil，且旧盾位置能重新落线")
    func togglingPositionClearsStaleShieldExactly() throws {
        let (lowerHandle, engine) = makeDrawingActiveChart(
            panel: .lower, bounds: CGRect(x: 0, y: 0, width: shieldTestPanelWidth, height: shieldTestTallPanelHeight))
        // ① 下半区：下面板有盾、上面板无盾。记下旧盾中点，稍后拿它做差分。
        renderAndConverge(TallPanelsShellLayout(engine: engine, typeRowExpanded: true, stylePanelPosition: .bottom))
        let oldShield = try #require(shieldRectOf(engine, 1), "下半区时下面板必须有盾")
        // 实测发现（同 upperPanelShieldBlocksOtherwiseCommittingTap 的既有教训）：本 fixture 下盾是
        // 贴底 400pt 面板的下半段，raw shield.mid 落在 mainChart(60%) 之外——采样点须取「盾 ∩ 可落线区」
        // 的真实交集中点，不盲取 shield.midY，否则前置 #require 天然假红/假绿。
        let oldHit = oldShield.intersection(lowerHandle.renderState.viewport.mainChartFrame)
        try #require(!oldHit.isNull && !oldHit.isEmpty,
                     "下面板盾与其可落线区无交集 → fixture 几何不成立，本测试证明不了任何事（假绿）")
        let pInOldShield = CGPoint(x: oldHit.midX, y: oldHit.midY)
        let c0 = engine.drawings.count
        lowerHandle.handleDrawingTapForTesting(at: pInOldShield)
        #expect(engine.drawings.count == c0, "装盾时该点竟然落了线 —— 盾没生效，后续差分无意义")

        // ② 切到上半区：下面板盾必须精确清零，且同一个点现在能落线（证明旧盾真没了）。
        renderAndConverge(TallPanelsShellLayout(engine: engine, typeRowExpanded: true, stylePanelPosition: .top))
        #expect(engine.drawingSession.shield[1] == .unshielded, "切到上半区后下面板未回到 .unshielded = stale shield 死区")
        lowerHandle.handleDrawingTapForTesting(at: pInOldShield)
        #expect(engine.drawings.count == c0 + 1, "旧盾位置仍落不了线 —— 残留屏蔽（下半 K 线死区）")
    }

    /// codex R2-medium：`.pending` 唯一的解锁路径是三条 `onPreferenceChange`，而 SwiftUI 只在**新值≠旧值**
    /// 时才回调它们。切 `stylePanelPosition`（.top⇄.bottom）在「样式面板高 + 16pt 竖直 padding == 容器总高」
    /// 时（大字号 / iPad / 横屏可达）——未加 padding 的样式面板 frame 在两种 alignment 下算出**同一个**
    /// CGRect（贴顶 8pt 与贴底 8pt 的对齐边界退化成同一位置），而 `upperPanelChartFrame`/`lowerPanelChartFrame`
    /// 本就与 `stylePanelPosition` 无关、恒不变——三个 preference 值切位置前后**全都不变**，三条
    /// `onPreferenceChange` 一条都不会触发，`refreshShields()` 从此再也不会重跑；`TrainingView.syncPanelShields()`
    /// 在切位置的同一次状态转换里已把两面板摁进 `.pending`，于是永久卡住（`ChartContainerView.handleDrawingTap`
    /// 对 `.pending` 恒拒收，画线永久失效，直到某个无关的布局事件恰好再触发一次收敛）。
    ///
    /// **复现/验证手法**（与本文件其余测试的关键差异）：既有 `renderAndConverge` 每次都构造全新
    /// `ImageRenderer`（全新 view graph），`ChartPanelsContainer` 的 `@State`
    /// （`upperPanelChartFrame`/`lowerPanelChartFrame`/`stylePanelChartFrame`）**不会**跨调用存活——每次都是
    /// 「从 nil 变成非 nil」，onPreferenceChange 必然触发，天然测不出这条 bug（`.pending` 的死锁恰恰依赖同一个
    /// 容器实例的旧值与新值数值相同）。改用**同一个** `ImageRenderer` 实例、只重新赋值 `.content`——独立实测
    /// 验证过三件事（细节见 task report「codex R2 fix」小节）：①`.content` 重新赋值确实保留 view 身份/`@State`
    /// （`onAppear` 不会重复触发，与 `renderAndConverge` 每次触发一次形成对照）；②`onPreferenceChange` 确实只在
    /// 数值真变化时才回调（数值相同则不回调，与生产行为一致，这才是本 bug 能被复现的前提）；③`.task(id:)` 在
    /// 单次 `.uiImage()` 调用内**同步**跑完、无需额外 `await`/`Task.yield()`，可在同一个 hosted 测试方法里
    /// 直接断言其效果（不必依赖不确定的异步收敛窗口）。
    ///
    /// fixture 高度（**实测打印，非猜测**）：`DrawingStylePanel` 在 `shieldTestPanelWidth=390` 下的未加 padding
    /// 内容高度实测 = 209pt（与既有 `togglingPositionClearsStaleShieldExactly` 等测试独立测得的同一份几何一致）；
    /// 容器 divider 实测高度 = 1pt。退化条件要求容器总高 == 209+16(2×8pt 竖直 padding) == 225pt——本测试选
    /// `upperHeight=30 / lowerHeight=194`（30+1(divider)+194=225），使样式面板整块横跨两面板（上面板只留顶部
    /// 8pt 未被盖到、下面板只留底部 8pt 未被盖到），上面板那 8pt 缝隙落在其 mainChart（顶部60%）区内、可用来做
    /// 「面板外仍能落线」的真差分。
    @Test("codex R2-medium 回归：⇅ 切位置若测出**相同**样式面板几何，两面板必须仍能从 .pending 收敛，面板外的点仍可落线")
    func toggleWithIdenticalGeometryEventuallySettles() throws {
        let upperHeight: CGFloat = 30
        let lowerHeight: CGFloat = 194   // 30 + 1(divider) + 194 = 225 = 209(面板内容实测高) + 16(2×8pt padding)
        let (engine, _) = TrainingEngineBounceWiringTests.makeEngine(count: 200, tick: 150)
        engine.toggleDrawingMode()

        // ① 首次渲染（.bottom）：正常收敛，样式面板整块横跨两面板 → 两面板均非 .pending。
        let renderer = ImageRenderer(content: AsymmetricPanelsShellLayout(
            engine: engine, stylePanelPosition: .bottom, upperHeight: upperHeight, lowerHeight: lowerHeight))
        renderer.scale = 1
        _ = renderer.uiImage
        try #require(shieldRectOf(engine, 0) != nil, "上面板必须有盾 —— fixture 未达到跨面板退化条件，需重新实测 DrawingStylePanel 内容高度")
        try #require(shieldRectOf(engine, 1) != nil, "下面板必须有盾 —— 同上")

        // 上面板未被盖到的顶部 8pt 缝隙（局部坐标，见 shieldRectOf(engine,0) 的 minY≈8）落在其 mainChart 内——
        // 用它证明「样式面板外的点仍可落线」（不是死区、也不是穿透幽灵线）。
        let upperHandle = makeChartHandle(
            engine: engine, panel: .upper, bounds: CGRect(x: 0, y: 0, width: shieldTestPanelWidth, height: upperHeight))
        let vp = upperHandle.renderState.viewport
        let mapper = CoordinateMapper(viewport: vp, displayScale: upperHandle.kLineView.traitCollection.displayScale)
        let gapPoint = CGPoint(x: mapper.indexToX(vp.startIndex) + vp.geometry.candleStep / 2, y: 2)
        try #require(vp.mainChartFrame.contains(gapPoint), "采样点须落在可落线区，否则本测试证明不了任何事（假绿）")

        let c0 = engine.drawings.count
        upperHandle.handleDrawingTapForTesting(at: gapPoint)
        #expect(engine.drawings.count == c0 + 1, "首次渲染后、面板缝隙的点竟落不了线 —— fixture 未达预期，后续差分无意义")

        // ② 模拟 TrainingView.syncPanelShields() 在「切 stylePanelPosition」这同一次状态转换里已做的事——
        // 把两面板摁进 .pending（这正是生产代码在 .onChange(of: stylePanelPosition) 里无条件触发的效果）。
        engine.drawingSession.setStylePanelVisible(true)
        #expect(engine.drawingSession.shield[0] == .pending && engine.drawingSession.shield[1] == .pending)
        let c1 = engine.drawings.count
        upperHandle.handleDrawingTapForTesting(at: gapPoint)
        #expect(engine.drawings.count == c1, ".pending 窗口内竟落了线 —— fail-closed 前提都不成立，后续差分无意义")

        // ③ 切到 .top——**同一个** ImageRenderer 实例、只重新赋值 .content（保留 view 身份/@State）。
        //    退化条件下，样式面板的未加 padding frame 与①渲染时数值完全相同 → 三条 onPreferenceChange
        //    一条都不会触发。没有本次 fix（ChartPanelsContainer 的两条 .task(id:)）会让两面板永久卡在 .pending
        //    （已实测验证：见 task report「codex R2 fix」小节的 RED 步骤）。
        renderer.content = AsymmetricPanelsShellLayout(
            engine: engine, stylePanelPosition: .top, upperHeight: upperHeight, lowerHeight: lowerHeight)
        _ = renderer.uiImage

        #expect(engine.drawingSession.shield[0] != .pending, "上面板切位置后仍卡在 .pending —— .task(id:) 未能收敛")
        #expect(engine.drawingSession.shield[1] != .pending, "下面板切位置后仍卡在 .pending —— .task(id:) 未能收敛")
        let c2 = engine.drawings.count
        upperHandle.handleDrawingTapForTesting(at: gapPoint)
        #expect(engine.drawings.count == c2 + 1, "切位置收敛后，面板缝隙的点仍落不了线 —— 画线在这一退化几何下永久失效")
    }
}
#endif

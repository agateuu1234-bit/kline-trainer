// ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingLayoutInvariantTests.swift
// Spec: docs/superpowers/specs/2026-07-17-drawing-tools-p1b-1a-iii-redesign.md（切片1 Task3）
// 布局不变量——阻塞式 hosted 几何断言：K 线容器（chartPanels = 生产共享的 ChartPanelsContainer）本体
// frame 在 {训练态、画线-收起、画线-展开} 三态下必须逐像素相等——证明类型行 overlay（Task2）真的不
// reflow 图表（不是靠源码守卫自证放行，而是真渲染后的布局测量，codex 计划-R1-high：不得降级为源码守卫）。
// 底栏三者等高这半条证据链已由 DrawingBottomBarHeightTests（1a-iii 切片1 Task1）对真底栏单测证过，本文件
// 不重复——只断言"图表容器本身的 frame"，两者合起来才是"切换底栏零跳动"的完整证据链（同本文件既有分工）。
//
// 测量技术选型记录（TDD 实测踩坑，四条路依次证伪/受阻，最后一条实测 GREEN）：
//   ① 计划原稿建议 `accessibilityIdentifier("chartPanels")` + UIView 树遍历（`findView`）再 `convert(_:to:)`。
//      stub 掉 K 线渲染后 chartPanels 内容纯 SwiftUI 原生 VStack/Color/Divider（无 UIViewRepresentable），
//      SwiftUI 完全不为这层分配 UIView，`.accessibilityIdentifier` 只落 SwiftUI 可访问性树 → 遍历恒 nil。
//   ② 怀疑 headless UIHostingController 未挂 UIWindow 未"物化"，实测把 host 塞进真 UIWindow
//      （`makeKeyAndVisible()`）直接让 xctest 进程崩（headless Catalyst 撞 `NSApplication has not been
//      created yet`，整个 runner 异常退出）——这条路本身不可行，不只本例凑巧失败。
//   ③ 改 GeometryReader + PreferenceKey 自报（`ChartPanelsFrameKey`），但用 `UIHostingController` +
//      `layoutIfNeeded()` 驱动——实测 `onPreferenceChange` 在无 window 的 headless Catalyst 里不 flush，
//      捕获盒恒 nil（实测 GATE FAIL：`chartPanels 未上报 frame`）。
//   ④ 同 ③ 的 PreferenceKey 自报，改用 `ImageRenderer`（读 `.uiImage` 强制同步渲染 + preference 收敛，
//      本仓 DrawingTapHitShieldTests 已验证可靠）——但若渲染**整壳** TrainingShellLayout（含真底栏），
//      底栏内 segmented `Picker` 的 `PlatformViewRepresentableAdaptor<SystemSegmentedControl>` ImageRenderer
//      无法 flatten，实测整棵渲染塌成 frame=(0,0,0,0)（GATE FAIL）。
// 最终采用 ④ 的 `ImageRenderer` + PreferenceKey，但**只渲染纯 SwiftUI 的 `ChartPanelsContainer` 本体
// （不含底栏）**——把等尺寸占位当上下面板注入、按三态驱动类型行 overlay 门；容器外包一层
// `.coordinateSpace(name:) + .overlay { GeometryReader 上报本体 frame }`（同容器 DrawingShieldFrameKey 同款
// 「coordinateSpace 在前、overlay 内容在命名空间内」结构——实测这是 headless ImageRenderer 下唯一稳定
// flush 出真实几何的读法：`.local`、以及容器自身层的 `.background` 都实测回落 .zero，唯 overlay 内容解析
// 得到外包命名空间）。容器与 DrawingTypeOverlay 均无 UIViewRepresentable，故 ImageRenderer 稳定 flatten
//（同 DrawingTapHitShieldTests 对 DrawingTypeOverlay 的既有可靠手法）。这是真渲染后的真实几何读数，非
// 源码守卫（codex 计划-R1 红线）；底栏对图表可用高度的影响属 Task1 职责，不在本容器本体不变量内。
#if canImport(UIKit)
import Testing
import SwiftUI
import UIKit
@testable import KlineTrainerContracts

// 1a-iii 切片1 whole-branch fix（M3）：ChartPanelsFrameKey 原声明在 TrainingView.swift，但生产
// ChartPanelsContainer 正文从不引用它——唯一消费者就是本文件的 hosted 几何测量，故挪进来（测试专用
// PreferenceKey，不留在生产模块）。用途见下方 chartFrame(isDrawing:expanded:) 与本文件头部测量技术选型记录。
struct ChartPanelsFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// `onPreferenceChange` 闭包写入的引用型接收盒（测试 helper，仅本文件用；ImageRenderer 同步渲染期间
/// 回调在此落值，渲染返回后读取）。
@MainActor
private final class FrameBox {
    var rect: CGRect?
}

// 等尺寸占位面板宽/高：上下面板固定同宽，使 ChartPanelsContainer 有确定 intrinsic 尺寸（供 ImageRenderer
// 无 proposedSize 时按 ideal 渲染）；高度固定、非贪婪——这样"类型行若被误改成 VStack 成员而非 overlay"会真的
// 把容器撑高（展开态 frame 变大），断言才抓得住；贪婪填充则容器外框恒等于画布、反而放过该回归。
private let invariantPanelWidth: CGFloat = 390
private let invariantPanelHeight: CGFloat = 200
// 测试外包给容器的坐标系名（读容器本体 frame 用）；与容器内部 "chart" 命名空间互不干扰。
private let measureRoot = "measureRoot"

@Suite("布局不变量：chartPanels 容器 frame 逐像素不变（1a-iii 切片1 Task3，阻塞式几何断言）")
struct DrawingLayoutInvariantTests {

    /// 用 `ImageRenderer`（读 `.uiImage` 强制同步跑完整棵树布局 → GeometryReader→`ChartPanelsFrameKey`→
    /// `onPreferenceChange` 收敛）渲染**生产共享的** `ChartPanelsContainer` 本体，读其在测试外包的
    /// `measureRoot` 坐标系里的 frame（容器左上角恒 (0,0)，故 frame 等价自身 size）。外包结构
    /// = `.coordinateSpace(name:) + .overlay { GeometryReader 上报 }`，与同容器 DrawingShieldFrameKey 同款
    /// 「coordinateSpace 在前、overlay 内容在命名空间内」——实测这是 headless ImageRenderer 下唯一稳定
    /// flush 出真实几何的路子（`.local`/容器自身层 `.background` 都回落 .zero，见测量技术选型记录）。
    /// `showsTradeButtons` 恒 true（这是交易态类型行能出现的前提，正是要测的场景），三态由
    /// (isDrawingActive, typeRowExpanded) 驱动：训练/收起态 overlay 门不成立（无类型行），展开态真渲染
    /// 类型行 overlay——证明它不改容器尺寸。
    @MainActor
    private func chartFrame(isDrawing: Bool, expanded: Bool, position: DrawingStylePanelPosition = .bottom) throws -> CGRect {
        let engine = TrainingEngine.preview()
        let box = FrameBox()
        // P1b-1a-iii 回归修复：ChartPanelsContainer 现只收一个收敛后的 stylePanelVisible 参数——
        // showsTradeButtons 恒 true（这是交易态类型行能出现的前提，正是要测的场景），三态由
        // (isDrawing, expanded) 驱动，调用处自己算好三 bool 合取传入。
        let measured = ChartPanelsContainer(
            engine: engine,
            stylePanelVisible: isDrawing && expanded,
            scheme: .light,                 // 测试固定日间，避免随宿主外观漂移
            stylePanelPosition: position,   // Task4：四态断言需要覆盖 .top（参数化，默认 .bottom 保三态断言不变）
            onTogglePosition: {},           // 测试不驱动 ⇅
            upperPanel: { Color.clear.frame(width: invariantPanelWidth, height: invariantPanelHeight) },
            lowerPanel: { Color.clear.frame(width: invariantPanelWidth, height: invariantPanelHeight) })
            .coordinateSpace(name: measureRoot)
            .overlay {
                GeometryReader { g in Color.clear
                    .preference(key: ChartPanelsFrameKey.self, value: g.frame(in: .named(measureRoot))) }
            }
            .onPreferenceChange(ChartPanelsFrameKey.self) { box.rect = $0 }
        let renderer = ImageRenderer(content: measured)
        renderer.scale = 1
        _ = renderer.uiImage   // 强制同步渲染 → preference 收敛 → onPreferenceChange 落值
        let f = try #require(box.rect, "chartPanels 未上报 frame（isDrawing=\(isDrawing) expanded=\(expanded)）")
        // 防退化假绿：若渲染塌陷、preference 只回落 defaultValue(.zero)，三态会全 .zero、相等断言假过。
        try #require(f.width == invariantPanelWidth && f.height > 0, "测到退化 frame=\(f)（非真实布局，判据失效）")
        return f
    }

    @Test("四态布局不变量：训练 / 画线-收起 / 画线-展开(下半区) / 画线-展开(上半区)——chartPanels 容器 frame 逐像素相等")
    @MainActor
    func chartFrameIdenticalAcrossFourStates() throws {
        let training  = try chartFrame(isDrawing: false, expanded: false)
        let collapsed = try chartFrame(isDrawing: true,  expanded: false)
        let bottom    = try chartFrame(isDrawing: true,  expanded: true, position: .bottom)
        let top       = try chartFrame(isDrawing: true,  expanded: true, position: .top)
        #expect(collapsed == training)
        #expect(bottom == training,  "展开(下半区)改变了图表容器尺寸 → 面板在挤压 K 线，不是 overlay")
        #expect(top == training,     "切到上半区改变了图表容器尺寸 → 面板在挤压 K 线，不是 overlay")
    }

    // ── 补充源码快检（快检，非达标判据——阻塞判据是上面的 hosted 几何测试）──

    private var srcDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func readSource(_ rel: String) throws -> String {
        try String(contentsOf: srcDir.appendingPathComponent("Sources/KlineTrainerContracts/\(rel)"), encoding: .utf8)
    }

    @Test("补充快检：类型行只经 overlay、图表面板不在 typeRowExpanded 分支内")
    func chartNotInExpandedBranch_sourceGuard() throws {
        let tv = try readSource("UI/TrainingView.swift")
        // 切片2 Task3：挂载点内容从 DrawingTypeOverlay( 换成常驻面板 DrawingStylePanel(。
        #expect(tv.contains("DrawingStylePanel(") && tv.contains(".accessibilityIdentifier(\"chartPanels\")"))
    }
}
#endif

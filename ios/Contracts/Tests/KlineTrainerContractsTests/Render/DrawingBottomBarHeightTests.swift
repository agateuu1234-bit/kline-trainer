// ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingBottomBarHeightTests.swift
// 等高测试（1a-iii 切片1 Task1 fix）：TradeActionBar / DrawingBottomBar / ReviewControlBar 三个互斥
// swap 的底栏必须在同一固定宽度下测得同一高度——三者现在都显式钉同一个 BottomBarMetrics.height 常量，
// 所以本测试是确定性的（不再依赖任何一侧「配方相同→天然等高」的假设，那个假设已被 Catalyst 真机测量证伪）。
// 测量技术：UIHostingController + 强制 layout 后 sizeThatFits(in:)——三者的高度都被外层 `.frame(height:)`
// 钉死，无论用哪种测量技术读，结果都应与钉的常量一致，因此沿用既有测量 helper 不变。
// 只在 Catalyst 通道跑（真实 UIKit 渲染出布局）；host `swift test` 不编译本文件（无 UIKit）。
#if canImport(UIKit)
import Testing
import SwiftUI
import UIKit
@testable import KlineTrainerContracts

@Suite("三个互斥 swap 底栏等高（Catalyst 真渲染，防「切换底栏顶起图表」回归）")
struct DrawingBottomBarHeightTests {

    @MainActor
    private func measuredHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: view.frame(width: width))
        host.view.bounds = CGRect(x: 0, y: 0, width: width, height: 0)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    @MainActor
    private func tradeActionBarHeight(width: CGFloat) -> CGFloat {
        let bar = TradeActionBar(
            content: TradeActionBarContent(price: 100),
            upperPeriod: .m60,
            lowerPeriod: .daily,
            activePanel: .constant(.upper),
            buyEnabled: true,
            sellEnabled: true,
            holdLabel: "持有",
            onBuy: {}, onSell: {}, onHold: {})
        return measuredHeight(bar, width: width)
    }

    @MainActor
    private func drawingBottomBarHeight(width: CGFloat) -> CGFloat {
        let bar = DrawingBottomBar(typeRowExpanded: .constant(false), deleteEnabled: false, onDelete: {})
        return measuredHeight(bar, width: width)
    }

    @MainActor
    private func reviewControlBarHeight(width: CGFloat) -> CGFloat {
        let bar = ReviewControlBar(showsJumpToEnd: true, price: 100,
                                    upperPeriod: .m60, lowerPeriod: .daily,
                                    activePanel: .constant(.upper), onAction: { _ in })
        return measuredHeight(bar, width: width)
    }

    @Test("宽度 390pt：三个底栏等高（≤0.5pt 容差）")
    @MainActor
    func equalHeight_390() {
        let trade = tradeActionBarHeight(width: 390)
        let drawing = drawingBottomBarHeight(width: 390)
        let review = reviewControlBarHeight(width: 390)
        #expect(abs(trade - drawing) <= 0.5, "TradeActionBar=\(trade) DrawingBottomBar=\(drawing) @390pt")
        #expect(abs(trade - review) <= 0.5, "TradeActionBar=\(trade) ReviewControlBar=\(review) @390pt")
    }

    @Test("宽度 430pt：三个底栏等高（≤0.5pt 容差）")
    @MainActor
    func equalHeight_430() {
        let trade = tradeActionBarHeight(width: 430)
        let drawing = drawingBottomBarHeight(width: 430)
        let review = reviewControlBarHeight(width: 430)
        #expect(abs(trade - drawing) <= 0.5, "TradeActionBar=\(trade) DrawingBottomBar=\(drawing) @430pt")
        #expect(abs(trade - review) <= 0.5, "TradeActionBar=\(trade) ReviewControlBar=\(review) @430pt")
    }

    // trashButtonDisabledFollowsPredicate（PR-4，验 🗑 渲染出的 accessibilityTraits 真跟随
    // deleteEnabled）连同它专用的 traits(ofLabel:in:) helper 已删除，原因：
    // 原写法（UIHostingController + layoutIfNeeded()，不挂真 window）在 Catalyst 上真跑，
    // hostedTraits(deleteEnabled:) 恒为 nil——SwiftUI 的无障碍元素没有物化，
    // try #require(...) 前提自足断言如实失败（其余 1712 条测试全绿）。
    // 尝试把 hosting controller 挂进一个真 UIWindow 再遍历（唯一允许的补救尝试）：
    // Catalyst 上裸建 `UIWindow(frame:)` 在这个纯 SPM 测试宿主里没有 UIApplication，
    // 抛 `NSInternalInconsistencyException: NSApplication has not been created yet`，
    // **崩溃整个 xctest 进程**（比原失败更差——xcodebuild 崩溃重启后把几百条本来会过的
    // 测试错误计入 Failing tests）。两条路都不可行，遂整条删除，不留弱化断言顶替。
    // 🗑 置灰目前只有源码守卫覆盖（DrawingModeBar.swift 里 `.disabled(!deleteEnabled)` 的存在
    // 由 spec §1.1 #1 静态断言钉住），没有运行时证据；已列入真机验收必验项。
}
#endif

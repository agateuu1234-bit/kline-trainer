// ios/Contracts/Sources/KlineTrainerContracts/UI/BottomBarMetrics.swift
// 1a-iii 切片1 Task1 fix：三个互斥 swap 的底栏（TradeActionBar / DrawingBottomBar / ReviewControlBar）
// 共享同一个固定高度，使训练/画线/复盘之间切换零跳动（图不因底栏切换而顶起/下沉）。
// 曾指望「三者用同一套 intrinsic 配方（buttonStyle/controlSize/padding 逐项照抄）天然等高」，但 Catalyst
// 真机测量证伪：TradeActionBar 的图标+多文案按钮 与 DrawingBottomBar 单图标按钮内容量不同，配方相同不
// 保证测出来的高度相同（headless sizeThatFits 还会随宽度改变、不可靠）。改为显式钉一个共享常量。
// 数值来源：UIHostingController + view 自身 widthAnchor 约束（非 superview/window）+
// sizingOptions = [.intrinsicContentSize] 读取 TradeActionBar 单行内容在 390pt/430pt 下的真实布局高度
// （两处实测均为 43.0pt，向上取整=43）——选 TradeActionBar 是因为三者中它的按钮+文案最多、内容最高，
// 钉这个值能保证它不裁切，其余两栏内容更矮、居中即可。
#if canImport(UIKit)
import SwiftUI

enum BottomBarMetrics {
    static let height: CGFloat = 43
}
#endif

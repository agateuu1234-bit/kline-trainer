// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeDrag.swift
// Spec: docs/superpowers/specs/2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D134d / D137）
//
// 节点拖动的**纯几何决策层**：手指位移 → 锚点增量，以及夹取（幂等投影）。
// 工具无关的部分与 DrawingNodeGeometry 并排；跨平台仅 CoreGraphics（无 UIKit）⇒ host swift test 全覆盖。

import CoreGraphics

@MainActor
public enum DrawingNodeDrag {

    /// 一次拖动位移换算出的**锚点增量**。⛔ 两个分量都直接在锚点的量纲里，绝不经过屏幕投影。
    public struct AnchorDelta: Equatable, Sendable {
        public let price: Double
        public let index: Int
    }

    /// D134d：位移 → 锚点增量。**全程不碰屏幕投影**。
    ///
    /// ⛔ **绝不写成「原锚点投影 + translation 再反算」**：`priceToY` 把结果对齐到整像素
    /// （`Geometry.swift:143-148`）而 `yToPrice`（`:165`）不带舍入 ⇒ 往返**不是恒等**。
    /// 实测（spec D134d）：displayScale=3 / 高 401 / 价区 10…23.7 下，200 个合法价位往返最大偏差
    /// 0.0057；单点 15.123456 → 15.124688，`==` 为 false。后果：纯横拖静默改价、拖回原处恢复不了
    /// ⇒ 门 ⑥ 永远触发不了 ⇒ 白写一次盘并挤掉深度 1 撤销栈里那条真编辑。
    ///
    /// **符号**：`priceToY` 里 y 随价位**递减**（`raw = maxY - ratio × height`）⇒ 前面这个负号
    /// **是必须的**，⛔ 写掉它线会朝反方向跑。
    ///
    /// `candleStep <= 0`（空图表）→ `nil`：除法会产出 inf/NaN，而 `Int(NaN)` 是 **trap**（进程崩）。
    /// 既有 `handleDrawingTap` 有同款守卫（`ChartContainerView.swift:337`，另见 `:279` / `:295`）。
    public static func anchorDelta(translation: CGPoint, mapper: CoordinateMapper) -> AnchorDelta? {
        let step = mapper.viewport.geometry.candleStep
        let height = mapper.viewport.mainChartFrame.height
        guard step > 0, height > 0 else { return nil }
        let span = mapper.viewport.priceRange.max - mapper.viewport.priceRange.min
        guard span > 0, span.isFinite else { return nil }
        // translation.y == 0 ⇒ 乘 0 ⇒ 逐位为 0（幂等的地基）
        let priceDelta = -Double(translation.y) * span / Double(height)
        guard priceDelta.isFinite else { return nil }
        let rawIndex = (translation.x / step).rounded(.toNearestOrAwayFromZero)
        guard rawIndex.isFinite, abs(rawIndex) < CGFloat(Int.max / 2) else { return nil }
        return AnchorDelta(price: priceDelta, index: Int(rawIndex))
    }
}

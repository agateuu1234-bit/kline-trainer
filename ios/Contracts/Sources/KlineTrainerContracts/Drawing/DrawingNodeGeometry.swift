// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift
// Spec: docs/superpowers/specs/2026-09-21-drawing-tools-P1c-2-nodes-design.md（D107 / D111 / D121–D124 / D131）
//
// 选中态节点的**决策层**：把锚点投影成「真节点 / 代理标记 / 什么都不画」三选一，并提供节点命中。
// 工具无关 —— 本类型不认识任何具体工具；线可不可见由调用方经 `DrawingTool.isVisible` 传入。
// 跨平台：仅 CoreGraphics（与 DrawingTool / HorizontalLineTool 一致，无 UIKit）→ host swift test 全覆盖。

import CoreGraphics

@MainActor
public enum DrawingNodeGeometry {

    /// D124：节点**视觉**直径（pt）。线宽档 1–5 = 1.5…3.5pt ⇒ 7pt 是最粗线的 2 倍，
    /// 满足 D107「与线连成一体」又看得出是个点。
    public static let visualDiameter: CGFloat = 7

    /// D124：节点**命中**半径（pt）。与线的命中容差（8pt，`HorizontalLineTool.swift:24`）**各自一份** ——
    /// 两者量纲不同：线是一维带宽，节点是二维圆盘。11 ≥ 8 保证「节点附近凡线命中的点、节点也命中」。
    public static let hitRadius: CGFloat = 11

    /// D122：本构建**画得出节点**的工具表。P1c 后续切片加工具 = **加一行**。
    /// ⚠️ 与 `DrawingToolType.implemented` 的相等由 `nodeTableIsSetEquality` 钉死（集合等式，两个方向）。
    /// ⚠️ **P2 会打破这个等式**：母 spec §6 把周期线 / 斐波那契列为「无节点」工具，它们进 `implemented`
    ///    的那一天，该断言必须连同本表一起重新论证 —— ⛔ 不得简单地把它们塞进本表了事。
    public static let toolsWithNodes: Set<DrawingToolType> = [.horizontal]

    /// 一个节点记号。`index` 恒为该锚点在 `drawing.anchors` 里的**原下标**（D131 / §3.5）。
    public enum NodeMark: Equatable {
        /// 真节点：锚点落在主图横向范围内，**可拖（第 3 片）、可命中**。
        case real(index: Int, at: CGPoint)
        /// 代理标记：锚点被视口甩出屏幕，在对应边框画一个**不可拖、不可命中**的提示。
        case proxy(index: Int, at: CGPoint, pointingLeft: Bool)
    }

    /// 三选一决策（§3.3 那张表）。⛔ **真节点的 x 绝不 clamp** —— 恒等于 `indexToX(candleIndex)`。
    /// 「锚点绑定的 K 线永不改变」是持久化不变量；把节点画在不属于它的 K 线上会让拖动语义失真（D123）。
    /// `maxAnchors`：该工具**真正消费**的锚点数上界，调用方从 `DrawingTool.requiredAnchors.upperBound` 取。
    /// ⛔ 本函数仍**不认识任何具体工具** —— 它只收一个数字，与 `isVisible: Bool` 同构（D132 第 1 条）。
    public static func marks(for drawing: DrawingObject, mapper: CoordinateMapper,
                             isVisible: Bool, maxAnchors: Int) -> [NodeMark] {
        guard isVisible, toolsWithNodes.contains(drawing.toolType) else { return [] }
        let frame = mapper.viewport.mainChartFrame
        let startIndex = mapper.viewport.startIndex
        // D132 第 1 条：只投影该工具**真正消费**的那几个锚点。`anchors` 数组长度解码时零校验
        // （`RecordRepositoryImpl` 的 `LossyAnchor`），而 `HorizontalLineTool` 的渲染与可见性
        // 三处全部只用 `anchors.first`（`:19` / `:51` / `:74`）⇒ 不截断就会在多出来的锚点上长出
        // 「渲染画不出、命中却认」的幽灵节点，直接违反 D131。
        return drawing.anchors.prefix(max(0, maxAnchors)).enumerated().compactMap { (i, anchor) -> NodeMark? in
            // D132 第 2 条：锚点自身画不出来就不产生任何记号。
            // ⚠️ `price` 的有限性解码时零校验 —— 仓内 K 线（`DefaultTrainingSetReader.swift:97-100`）
            //    与设置项（`SettingsDAOImpl.swift:38`）都查 isFinite，唯独画线锚点不查。
            // ⚠️ NaN 的任何比较都是 false，下面的范围 guard 本已挡得住；isFinite 仍**显式写出**，
            //    ⛔ 不得依赖那个隐式性质（D132 的可读性要求）。
            let y = mapper.priceToY(anchor.price)
            guard y.isFinite, y >= frame.minY, y <= frame.maxY else { return nil }
            // ⛔⛔ 溢出保护（evaluation R3-high）：`indexToX` 内部是 `index - viewport.startIndex` 的
            // **Int 减法**（`Geometry.swift:139`），Swift 对 Int 溢出是 **trap（崩溃）**。
            // 而 `candleIndex` 从磁盘解码时**零范围校验**（`RecordRepositoryImpl.swift:227-230`）⇒
            // 一条 `candleIndex == Int.min` 的持久化直线今天能正常渲染与命中（`.straight` 的几何
            // 根本不看锚点 x，`HorizontalLineTool.swift:55`），**一旦本函数无保护地调 `indexToX`，
            // 选中它的那一刻就会崩**。⇒ 本函数是这条崩溃路径的唯一入口，保护必须落在这里。
            // 溢出只可能在两端发生，且此时两操作数必然异号 ⇒ 用 `candleIndex` 的符号定方向。
            let (_, overflowed) = anchor.candleIndex.subtractingReportingOverflow(startIndex)
            if overflowed {
                let left = anchor.candleIndex < 0          // 极远的过去 → 左；极远的未来 → 右
                return .proxy(index: i, at: CGPoint(x: left ? frame.minX : frame.maxX, y: y),
                              pointingLeft: left)
            }
            let x = mapper.indexToX(anchor.candleIndex)      // ⛔ 不 clamp（T4 钉死）
            guard x.isFinite else { return nil }            // 视口自身若带非有限值，同样不产生记号
            if x < frame.minX { return .proxy(index: i, at: CGPoint(x: frame.minX, y: y), pointingLeft: true) }
            if x > frame.maxX { return .proxy(index: i, at: CGPoint(x: frame.maxX, y: y), pointingLeft: false) }
            return .real(index: i, at: CGPoint(x: x, y: y))
        }
    }
}

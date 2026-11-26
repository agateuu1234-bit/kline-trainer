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
    /// 既有 `handleDrawingTap` 有同款守卫（`ChartContainerView.swift:349`，另见 `:291` / `:307`）。
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

    /// D137 的**唯一后置条件**：该锚点在 `marks()` 里产出 `.real`。
    ///
    /// ⛔ **不要退回「`visibleGeometry != nil`」**：`.straight` 的几何完全不看锚点 x
    /// （`HorizontalLineTool.swift:54-55`）⇒ 锚点被夹到右缘之外时**线照常可见**，而 `marks`
    /// 会把越界的 x 转成 `.proxy`（`DrawingNodeGeometry.swift:71-72`）、`hitTestNode` 又把 proxy
    /// 排除在命中集合之外（`:104`）⇒ **线还在、黑点却再也抓不住**。那条判据在 `.straight` 上
    /// 被**空洞地满足**（spec 第 12 轮实证）。
    ///
    /// 本条**蕴含**另外两件事：① 线可见（`marks` 在 `isVisible == false` 时直接返回空数组，`:41`）；
    /// ② 节点还抓得住（D131：命中集合 ≡ 渲染集合里的 `.real`）。
    public static func producesRealNode(anchor: DrawingAnchor, in drawing: DrawingObject,
                                        anchorIndex: Int, mapper: CoordinateMapper,
                                        tool: any DrawingTool) -> Bool {
        guard let candidate = candidateWithReplacedAnchor(anchor, in: drawing, anchorIndex: anchorIndex)
        else { return false }
        let marks = DrawingNodeGeometry.marks(
            for: candidate, mapper: mapper,
            isVisible: tool.isVisible(drawing: candidate, mapper: mapper),
            maxAnchors: tool.requiredAnchors.upperBound)
        return marks.contains { if case .real(let i, _) = $0 { return i == anchorIndex }; return false }
    }

    /// 整支评审 M1：`producesRealNode` 的 17 字段手抄（见下方实现）此前只能靠它自己的 `Bool`
    /// 返回值间接验证——而大多数字段（`thickness`/`colorToken`/`text`/… 共 9 个）不影响几何/
    /// 可见性判定，漏传它们时 `Bool` 返回值不会变，判别力恒为零。抽成具名 helper，production
    /// 与下面的 `...ForTesting` 入口**调同一份**，测试才能真的看见手抄构造出来的完整对象，
    /// 而不是另造一份与 production 脱节、会各自漂移的副本。
    private static func candidateWithReplacedAnchor(_ anchor: DrawingAnchor, in drawing: DrawingObject,
                                                     anchorIndex: Int) -> DrawingObject? {
        guard drawing.anchors.indices.contains(anchorIndex) else { return nil }
        var anchors = drawing.anchors
        anchors[anchorIndex] = anchor
        // ⚠️ `DrawingObject` **没有** `withAnchors`（实测）⇒ 就地用完整成员 init 逐字段拷贝，
        //    照 `setDrawingLocked`（`TrainingEngine.swift:1230` 起）的范式。
        //    ⛔ 不要为此给 `DrawingObject` 加新 API（YAGNI，且会扩大本片对 Models 的改动面）。
        //    ⚠️ `period` **显式传** `drawing.period`：init 的默认行为是从 `anchors.first?.period` 现取，
        //       候选锚点若周期不同会静默改掉整条线的周期。
        return DrawingObject(
            id: drawing.id, toolType: drawing.toolType, anchors: anchors,
            isExtended: drawing.isExtended, panelPosition: drawing.panelPosition,
            revealTick: drawing.revealTick, period: drawing.period,
            lineSubType: drawing.lineSubType, lineStyle: drawing.lineStyle,
            thickness: drawing.thickness, colorToken: drawing.colorToken,
            labelMode: drawing.labelMode, locked: drawing.locked,
            text: drawing.text, fontSize: drawing.fontSize,
            textColorToken: drawing.textColorToken, textForm: drawing.textForm,
            tailAnchor: drawing.tailAnchor)
    }

    /// 测试入口（照 `handleDrawingTapForTesting` 的先例）：暴露 `producesRealNode` 内部那份
    /// 17 字段手抄构造出来的完整对象，供往返恒等测试用。⛔ 不是另一份构造逻辑——调用的是
    /// 生产代码里**同一个** `candidateWithReplacedAnchor`。
    static func candidateWithReplacedAnchorForTesting(_ anchor: DrawingAnchor, in drawing: DrawingObject,
                                                       anchorIndex: Int) -> DrawingObject? {
        candidateWithReplacedAnchor(anchor, in: drawing, anchorIndex: anchorIndex)
    }

    /// D134d + D137：把一次位移变成**已夹取**的新锚点。
    ///
    /// ⭐⭐ **夹取是一个幂等的投影**：候选若已满足后置条件 ⇒ **原样返回、一个字节不改**；
    /// 只有不满足时才修正。幂等性直接给出三条保证：零位移恒等 / 纯横拖不改价 / 拖走再拖回逐位
    /// 恢复。⛔ **绝不无条件夹**：可见性按**像素舍入之后**的 y 判（`priceToY` 先舍入、`marks` 再比较），
    /// 比「价位落在 priceRange 内」更宽。实测（spec D137）：价位 23.701 已超区间上限，投影 y = -0.0293
    /// 舍入到 -0.0 ⇒ 仍是 `.real`；无条件夹会把它改成 23.7，**即使手指纵向一动没动**。
    ///
    /// 修正时**必须在像素舍入之后的坐标空间里选边界**，⛔ 不得直接用 `startIndex + visibleCount - 1`：
    /// 实测 candleStep=4.0025 / pixelShift=4 / 右缘 320.2 时，第 79 根舍入到 320.3333 已越界，
    /// 合法最大下标是 78。
    ///
    /// 返回 `nil` = 连边界都找不到合法位置（fail-closed；调用方丢弃本帧，⛔ 不得写出不合法锚点）。
    public static func draggedAnchor(drawing: DrawingObject, anchorIndex: Int, translation: CGPoint,
                                     mapper: CoordinateMapper, tool: any DrawingTool) -> DrawingAnchor? {
        guard drawing.anchors.indices.contains(anchorIndex) else { return nil }
        let old = drawing.anchors[anchorIndex]
        guard let d = anchorDelta(translation: translation, mapper: mapper) else { return nil }
        let (rawIndex, overflow) = old.candleIndex.addingReportingOverflow(d.index)
        let candidateIndex = overflow ? (d.index > 0 ? Int.max : Int.min) : rawIndex
        let candidate = DrawingAnchor(period: old.period, candleIndex: candidateIndex,
                                      price: old.price + d.price)
        // ① 幂等：已经合法就原样返回
        if producesRealNode(anchor: candidate, in: drawing, anchorIndex: anchorIndex,
                            mapper: mapper, tool: tool) {
            return candidate
        }
        // ② 不合法才修正：先把价位调到最近的合法值，再把下标调到最近的合法下标
        let priced = clampPrice(candidate, in: drawing, anchorIndex: anchorIndex,
                                mapper: mapper, tool: tool)
        return clampIndex(priced, in: drawing, anchorIndex: anchorIndex, mapper: mapper, tool: tool)
    }

    /// 价位方向的修正：在 `[priceRange.min, priceRange.max]` 内二分找最接近候选、且 y 落在框内的值。
    /// ⚠️ 判据用 `priceToY` **舍入之后**的结果比较（与 `marks` 同一判据），⛔ 不比较价位本身。
    ///
    /// ⚠️ **本函数与简报草稿的差异**：草稿版 lo/hi 更新分支是反的（对着一个 y **随价位递减**的函数，
    /// 却按「递增函数」的方向二分）⇒ 会收敛到**错误的那一侧**边界。实测钉死（脚本重放同一 candleStep /
    /// frame / priceRange）：`target = frame.minY`（应收敛到 price ≈ priceRange.max = 23.7）时，
    /// 反向版本收敛到 10.0（= priceRange.min，整整跑到对面）；`target = frame.maxY` 时反向版本又收敛
    /// 到 23.7。两侧都错，且给定的 `clampKeepsNodeReal` 测试**测不出来**——因为两侧本身都满足
    /// 「投影仍在 [minY,maxY] 内」而产出 `.real`，判据只问「还是不是 .real」，不问「夹到了哪一侧」。
    /// 这正是本片反复强调的「空洞成立」在这个函数内部的翻版：外部测试的判别力覆盖不到内部方向。
    private static func clampPrice(_ a: DrawingAnchor, in drawing: DrawingObject, anchorIndex: Int,
                                   mapper: CoordinateMapper, tool: any DrawingTool) -> DrawingAnchor {
        let frame = mapper.viewport.mainChartFrame
        let y = mapper.priceToY(a.price)
        guard !(y.isFinite && y >= frame.minY && y <= frame.maxY) else { return a }
        let target = y < frame.minY ? frame.minY : frame.maxY
        var lo = mapper.viewport.priceRange.min, hi = mapper.viewport.priceRange.max
        // 目标 y 对应的价位方向：y 越小价位越大 ⇒ y 是价位的**递减**函数。
        // 标准二分（递减函数找 f(p)=target）：my < target ⇒ p 已经太大 ⇒ 收窄上界 hi；
        // 否则 p 还不够大 ⇒ 收窄下界 lo。
        var best = mapper.yToPrice(target)
        for _ in 0..<64 {                       // 定次数二分：避免浮点比较写出死循环
            let mid = (lo + hi) / 2
            let my = mapper.priceToY(mid)
            if my.isFinite && my >= frame.minY && my <= frame.maxY { best = mid }
            if my < target { hi = mid } else { lo = mid }
        }
        return DrawingAnchor(period: a.period, candleIndex: a.candleIndex, price: best)
    }

    /// 下标方向的修正：**在像素舍入之后的空间里**，从候选往回找最近的合法下标。
    /// ⛔ 不得直接用 `startIndex + visibleCount - 1`（实测它可能已越界，见本类型头注）。
    private static func clampIndex(_ a: DrawingAnchor, in drawing: DrawingObject, anchorIndex: Int,
                                   mapper: CoordinateMapper, tool: any DrawingTool) -> DrawingAnchor? {
        if producesRealNode(anchor: a, in: drawing, anchorIndex: anchorIndex,
                            mapper: mapper, tool: tool) { return a }
        let vp = mapper.viewport
        let lo = vp.startIndex, hi = vp.startIndex + max(0, vp.visibleCount - 1)
        guard lo <= hi else { return nil }
        let start = min(max(a.candleIndex, lo), hi)
        // 从夹进窗口的那个下标出发，向**窗口内**双向扫，取第一个真正产出 .real 的
        for step in 0...(hi - lo) {
            for cand in [start - step, start + step] where cand >= lo && cand <= hi {
                let t = DrawingAnchor(period: a.period, candleIndex: cand, price: a.price)
                if producesRealNode(anchor: t, in: drawing, anchorIndex: anchorIndex,
                                    mapper: mapper, tool: tool) { return t }
            }
        }
        return nil                               // fail-closed：整个窗口都没有合法位置
    }
}

import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("DrawingLabelLayout")
struct DrawingLabelLayoutTests {
    static let frame = CGRect(x: 0, y: 0, width: 800, height: 360)
    static let sz = CGSize(width: 60, height: 16)
    @Test(".hidden → 无矩形")
    func hiddenNil() {
        #expect(DrawingLabelLayout.labelRect(mode: .hidden, lineY: 100,
            lineXRange: (0, 800), textSize: Self.sz, mainChartFrame: Self.frame) == nil)
    }
    @Test("不压线：标签底边在线上方（rect.maxY <= lineY）")
    func labelAboveLine() {
        for mode in [LabelMode.left, .right] {
            let r = DrawingLabelLayout.labelRect(mode: mode, lineY: 100,
                lineXRange: (0, 800), textSize: Self.sz, mainChartFrame: Self.frame)!
            #expect(r.maxY <= 100)
        }
    }
    @Test("右对齐 + 四位价不溢出：rect.maxX <= 主图右缘")
    func rightNoOverflow() {
        let r = DrawingLabelLayout.labelRect(mode: .right, lineY: 100,
            lineXRange: (0, 800), textSize: CGSize(width: 60, height: 16), mainChartFrame: Self.frame)!
        #expect(r.maxX <= 800)
    }
    @Test("左对齐锚在线左端；右对齐锚在线右端")
    func leftRightAnchoring() {
        let left = DrawingLabelLayout.labelRect(mode: .left, lineY: 100,
            lineXRange: (200, 800), textSize: Self.sz, mainChartFrame: Self.frame)!
        let right = DrawingLabelLayout.labelRect(mode: .right, lineY: 100,
            lineXRange: (200, 800), textSize: Self.sz, mainChartFrame: Self.frame)!
        #expect(left.minX >= 200)
        #expect(right.maxX <= 800)
        #expect(right.minX > left.minX)
    }
    @Test("顶边溢出：线贴主图上缘时标签改放线下方，仍在 frame 内且不压线（codex plan-medium）")
    func topEdgeFallsBelow() {
        // lineY=5, textHeight=16, frame.minY=0 → 上方 above=5-2-16=-13 < 0 → 改放线下方
        let r = DrawingLabelLayout.labelRect(mode: .left, lineY: 5,
            lineXRange: (0, 800), textSize: Self.sz, mainChartFrame: Self.frame)!
        #expect(r.minY >= Self.frame.minY)   // 不跑出主图上缘
        #expect(r.minY >= 5)                 // 放在线下方 → 顶边不高于线 → 不压线
    }
    @Test("上方有空间时仍放线上方（不压线）")
    func aboveWhenRoom() {
        let r = DrawingLabelLayout.labelRect(mode: .left, lineY: 100,
            lineXRange: (0, 800), textSize: Self.sz, mainChartFrame: Self.frame)!
        #expect(r.maxY <= 100)   // 底边不低于线
    }
    @Test("射线锚近右缘 + .left/.show：x 被裁不溢出右边界（codex plan-R3）")
    func leftShowNearRightEdgeClamped() {
        for mode in [LabelMode.left, .show] {
            let r = DrawingLabelLayout.labelRect(mode: mode, lineY: 100,
                lineXRange: (790, 800), textSize: Self.sz, mainChartFrame: Self.frame)!   // 锚 x=790，textW=60
            #expect(r.maxX <= 800)   // 不越右缘
            #expect(r.minX >= 0)     // 不越左缘
        }
    }
    // labelContent 决策（host 可测，覆盖「画不画/画什么/什么色/对齐」——codex plan-R8：这些逻辑不能只活在 UIKit 层）
    @Test("labelContent：hidden / 非水平线 / 线不可见 → nil；left/right → 文字+色+对齐")
    func labelContentDecision() {
        func d(_ mode: LabelMode, tool: DrawingToolType = .horizontal) -> DrawingObject {
            DrawingObject(toolType: tool, anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
                          isExtended: false, panelPosition: 0, labelMode: mode, textColorToken: .green)
        }
        #expect(DrawingLabelLayout.labelContent(for: d(.hidden), lineVisible: true) == nil)   // 隐藏不画
        #expect(DrawingLabelLayout.labelContent(for: d(.left), lineVisible: false) == nil)    // 线不可见（segment/超界射线）→ 标注也不画
        #expect(DrawingLabelLayout.labelContent(for: d(.left, tool: .trend), lineVisible: true) == nil)  // 本期只水平线接线
        let left = DrawingLabelLayout.labelContent(for: d(.left), lineVisible: true)!
        #expect(left.text == "15.00" && left.colorToken == .green && left.mode == .left)
        #expect(DrawingLabelLayout.labelContent(for: d(.show), lineVisible: true)!.mode == .left)   // .show 归左
        #expect(DrawingLabelLayout.labelContent(for: d(.right), lineVisible: true)!.mode == .right)
    }

    // codex branch-R2 medium：坏数据（持久化 fontSize 超大）导致 textSize 比主图还宽/高 → fail-closed 不画，不溢出
    @Test("文字宽度超过主图宽度 → nil（fail-closed）")
    func widthOverflowNil() {
        let oversized = CGSize(width: Self.frame.width + 1, height: 16)
        #expect(DrawingLabelLayout.labelRect(mode: .left, lineY: 100,
            lineXRange: (0, 800), textSize: oversized, mainChartFrame: Self.frame) == nil)
    }
    @Test("文字高度超过主图高度 → nil（fail-closed）")
    func heightOverflowNil() {
        let oversized = CGSize(width: 60, height: Self.frame.height + 1)
        #expect(DrawingLabelLayout.labelRect(mode: .left, lineY: 100,
            lineXRange: (0, 800), textSize: oversized, mainChartFrame: Self.frame) == nil)
    }
    // codex branch-R4 medium：上下都放不下（保 gap 前提下）时，旧实现会把 y clamp 回框内，
    // 使返回的 rect 压住线——这违反「不压线」不变量。新实现应 fail-closed 返回 nil，不再 clamp。
    @Test("下方 fallback 也放不下（保 gap 前提下）：fail-closed 不画，不压线（codex branch-R4 medium）")
    func belowFallbackNoRoomFailsClosed() {
        // frame 很矮（20pt）：above=lineY-gap-textH=10-2-16=-8<0 → 上方放不下；
        // 下方 y=lineY+gap=12，12+16=28 超出 frame.maxY(20) → 下方也放不下 → fail-closed
        let shortFrame = CGRect(x: 0, y: 0, width: 800, height: 20)
        let r = DrawingLabelLayout.labelRect(mode: .left, lineY: 10,
            lineXRange: (0, 800), textSize: Self.sz, mainChartFrame: shortFrame)
        #expect(r == nil)
    }
    @Test("文字尺寸恰好等于 frame 尺寸：上下都保不住 gap → fail-closed（codex branch-R4 medium）")
    func exactFrameSizeBothSidesNoRoomFailsClosed() {
        let exact = CGSize(width: Self.frame.width, height: Self.frame.height)
        let r = DrawingLabelLayout.labelRect(mode: .left, lineY: 100,
            lineXRange: (0, 800), textSize: exact, mainChartFrame: Self.frame)
        #expect(r == nil)
    }
    // codex 点名场景：frame.height=20, lineY=10, textSize.height=16 → 旧实现 clamp 出 y=4 的 rect（跨 4…20），
    // 盖住了 lineY=10 处的线。新实现须 fail-closed 返回 nil，绝不能盖线。
    @Test("codex 点名压线场景：frame.height=20 lineY=10 textSize.height=16 → nil（codex branch-R4 medium）")
    func codexPinpointedOverlapScenarioFailsClosed() {
        let shortFrame = CGRect(x: 0, y: 0, width: 800, height: 20)
        let r = DrawingLabelLayout.labelRect(mode: .left, lineY: 10,
            lineXRange: (0, 800), textSize: CGSize(width: 10, height: 16), mainChartFrame: shortFrame)
        #expect(r == nil)
    }
    // 核心不变量（codex branch-R4 medium）：凡返回非 nil 的 rect，必须完全落在 mainChartFrame 内，
    // 且不能包含 lineY（rect 与线之间必须保留 gap）——即便上下都放不下的场景（跳过，返回 nil）。
    @Test("不变量：非 nil 的 rect 必须完全落在 mainChartFrame 内，且不压线（codex branch-R4 medium）")
    func neverOverlapsLineWhenNonNil() {
        let gap: CGFloat = 2   // 与 DrawingLabelLayout 内部 gap 常量保持一致（生产值）
        let cases: [(LabelMode, CGFloat, (CGFloat, CGFloat), CGSize, CGRect)] = [
            (.left, 100, (0, 800), Self.sz, Self.frame),
            (.right, 100, (0, 800), Self.sz, Self.frame),
            (.left, 5, (0, 800), Self.sz, Self.frame),                 // 顶边溢出 → 改放下方
            (.left, 100, (790, 800), Self.sz, Self.frame),             // 射线锚近右缘
            (.left, 10, (0, 800), CGSize(width: 10, height: 16),
             CGRect(x: 0, y: 0, width: 800, height: 20)),              // 上下都放不下 → nil，跳过
        ]
        for (mode, lineY, xRange, sz, frame) in cases {
            guard let r = DrawingLabelLayout.labelRect(mode: mode, lineY: lineY,
                lineXRange: xRange, textSize: sz, mainChartFrame: frame) else { continue }
            #expect(r.minX >= frame.minX && r.maxX <= frame.maxX)
            #expect(r.minY >= frame.minY && r.maxY <= frame.maxY)
            #expect(r.maxY <= lineY - gap || r.minY >= lineY + gap)   // 不压线
        }
    }
    @Test("通用不变量：凡返回非 nil 的 rect 必须完全落在 mainChartFrame 内")
    func alwaysFullyContainedWhenNonNil() {
        let cases: [(LabelMode, CGFloat, (CGFloat, CGFloat), CGSize)] = [
            (.left, 100, (0, 800), Self.sz),
            (.right, 100, (0, 800), Self.sz),
            (.left, 5, (0, 800), Self.sz),                 // 顶边溢出场景
            (.left, 100, (790, 800), Self.sz),             // 射线锚近右缘
        ]
        for (mode, lineY, xRange, sz) in cases {
            guard let r = DrawingLabelLayout.labelRect(mode: mode, lineY: lineY,
                lineXRange: xRange, textSize: sz, mainChartFrame: Self.frame) else { continue }
            #expect(r.minX >= Self.frame.minX && r.maxX <= Self.frame.maxX)
            #expect(r.minY >= Self.frame.minY && r.maxY <= Self.frame.maxY)
        }
    }

    // codex branch-R5 medium：fontSize 是持久化的任意 Int，损坏/未来版本 blob 可写入负数或极大值。
    // 必须在创建 UIFont / 测量文字【之前】就 clamp——否则 CoreText 以荒谬字号排版会崩溃/卡死/极慢。
    @Test("sanitizedFontSize：负数与 0 → 下界 8；极大值 → 上界 48")
    func sanitizedFontSizeClampsCorruptValues() {
        #expect(DrawingLabelLayout.sanitizedFontSize(-5) == 8)
        #expect(DrawingLabelLayout.sanitizedFontSize(0) == 8)
        #expect(DrawingLabelLayout.sanitizedFontSize(Int.min) == 8)
        #expect(DrawingLabelLayout.sanitizedFontSize(1_000_000) == 48)
        #expect(DrawingLabelLayout.sanitizedFontSize(Int.max) == 48)
    }
    @Test("sanitizedFontSize：默认 14 与边界值原样返回（视觉零变化）")
    func sanitizedFontSizeIdentityInRange() {
        #expect(DrawingLabelLayout.sanitizedFontSize(14) == 14)   // DrawingObject.fontSize 默认值 → 不得漂移
        #expect(DrawingLabelLayout.sanitizedFontSize(8) == 8)
        #expect(DrawingLabelLayout.sanitizedFontSize(48) == 48)
    }
}

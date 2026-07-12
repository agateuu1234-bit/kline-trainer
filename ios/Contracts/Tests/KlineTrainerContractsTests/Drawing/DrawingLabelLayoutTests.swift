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
    @Test("下方 fallback 撞下边缘：clamp 回框内不溢出（codex branch-R2 medium）")
    func belowFallbackClampsToBottom() {
        // frame 很矮（20pt）：above=lineY-gap-textH=10-2-16=-8<0 → 走下方分支；
        // 下方 y=lineY+gap=12，12+16=28 超出 frame.maxY(20) → 须 clamp 回框内
        let shortFrame = CGRect(x: 0, y: 0, width: 800, height: 20)
        let r = DrawingLabelLayout.labelRect(mode: .left, lineY: 10,
            lineXRange: (0, 800), textSize: Self.sz, mainChartFrame: shortFrame)!
        #expect(r.maxY <= shortFrame.maxY)
        #expect(r.minY >= shortFrame.minY)
    }
    @Test("文字尺寸恰好等于 frame 尺寸：仍返回非 nil，贴边界不溢出（codex branch-R2 medium）")
    func exactFrameSizeFits() {
        let exact = CGSize(width: Self.frame.width, height: Self.frame.height)
        let r = DrawingLabelLayout.labelRect(mode: .left, lineY: 100,
            lineXRange: (0, 800), textSize: exact, mainChartFrame: Self.frame)!
        #expect(r.minX >= Self.frame.minX && r.maxX <= Self.frame.maxX)
        #expect(r.minY >= Self.frame.minY && r.maxY <= Self.frame.maxY)
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
}

// DrawingDefaultStyleSanitizeTests.swift
import Testing
@testable import KlineTrainerContracts

@Suite("DrawingDefaultStyle.sanitized")
struct DrawingDefaultStyleSanitizeTests {

    /// T6：磁盘上躺着 .segment → 必须回落，否则 commitPending 的 withStyle 恒返回 nil、用户一条线都画不出来
    @Test func horizontal_segment_falls_back_to_straight() {
        var s = DrawingDefaultStyle(); s.lineSubType = .segment
        #expect(s.sanitized(for: .horizontal).lineSubType == .straight)
    }

    /// T7：越域粗细夹回值域两端
    @Test func thickness_is_clamped_to_range() {
        var hi = DrawingDefaultStyle(); hi.thickness = 99
        var lo = DrawingDefaultStyle(); lo.thickness = 0
        #expect(hi.sanitized(for: .horizontal).thickness == DrawingDefaultStyle.thicknessRange.upperBound)
        #expect(lo.sanitized(for: .horizontal).thickness == DrawingDefaultStyle.thicknessRange.lowerBound)
    }

    /// T7b：(ray, .left) 是水平线下的非法组合 → 归一化到 .hidden
    @Test func horizontal_ray_with_left_label_is_normalized() {
        var s = DrawingDefaultStyle(); s.lineSubType = .ray; s.labelMode = .left
        #expect(s.sanitized(for: .horizontal).labelMode == .hidden)
    }

    /// T15b（不变量锁）：非水平工具**不得**被套上水平线规则。
    /// 本片调用点恒 .horizontal，故只能单元级构造 —— 但 P1c 一旦加工具，这条就是生产路径。
    ///
    /// ⚠️ **子类型分量必须用 `.segment`，不能用 `.ray`**（codex plan-P-R11 medium，**已实测**）：
    ///    `horizontalLineSubTypeEnabled` 里 `.straight/.ray → true`、**只有 `.segment → false`**
    ///    （`DrawingStyleAvailability.swift`）。用 `.ray` 时，正确实现（tool-aware 重载）与
    ///    错误实现（错调水平线专用谓词）**返回同一个值** ⇒ 该分量零判别力。
    ///    换 `.segment` 后：正确实现原样保留、错误实现会把它改写成 `.straight` —— 判据这才立起来。
    @Test func non_horizontal_tool_keeps_its_label_and_subtype() {
        var s = DrawingDefaultStyle(); s.lineSubType = .segment; s.labelMode = .left
        let out = s.sanitized(for: .trend)
        #expect(out.labelMode == .left)          // 横线的「射线不能配左」不得外溢
        #expect(out.lineSubType == .segment)     // 横线的「拒 .segment」同样不得外溢
    }

    /// 正向档：健康值原样穿过（防「全是拒了的套件」掩盖恒回落的实现）
    @Test func healthy_style_passes_through_unchanged() {
        var s = DrawingDefaultStyle()
        s.lineSubType = .ray; s.lineStyle = .dash2; s.thickness = 3
        s.colorToken = .purple; s.labelMode = .right
        #expect(s.sanitized(for: .horizontal) == s)
    }
}

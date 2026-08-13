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
    /// ⚠️ **必须拆成两档，不能只取一组值**（修复轮1，根因=计划前几轮评审改出的缺陷）：
    ///    `horizontalLabelModeEnabled(.left, lineSubType:)` 的判据是 `lineSubType != .ray`，
    ///    `horizontalLineSubTypeEnabled` 里**只有 `.segment → false`**（`DrawingStyleAvailability.swift`）。
    ///    这条不变量有两种正交的绕过，单一取值只抓得住一种：
    ///      · `.ray` + `.left` 的 **labelMode**：2 参重载给 `.hidden`、3 参 tool-aware 给 `.left` —— 只有它抓得住 M15b；
    ///      · `.segment` + `.left` 的 **lineSubType**：2 参重载给 `.straight`、3 参 tool-aware 给 `.segment` —— 只有它抓得住 M15d；
    ///      · 反过来（`.segment` 的 labelMode / `.ray` 的 lineSubType）两种实现**返回同一个值**，零判别力
    ///        （这正是原来单一测试 `non_horizontal_tool_keeps_its_label_and_subtype` 用 `.segment` 时，
    ///        M15b 变异全程零判别力的根因，已实测确认）。
    @Test func non_horizontal_tool_keeps_its_label() {
        var s = DrawingDefaultStyle(); s.lineSubType = .ray; s.labelMode = .left
        let out = s.sanitized(for: .trend)
        #expect(out.labelMode == .left)          // 横线的「射线不能配左」不得外溢（M15b 打这一条）
        #expect(out.lineSubType == .ray)
    }

    @Test func non_horizontal_tool_keeps_its_subtype() {
        var s = DrawingDefaultStyle(); s.lineSubType = .segment; s.labelMode = .left
        let out = s.sanitized(for: .trend)
        #expect(out.lineSubType == .segment)     // 横线的「拒 .segment」不得外溢（M15d 打这一条）
        #expect(out.labelMode == .left)
    }

    /// 正向档：健康值原样穿过（防「全是拒了的套件」掩盖恒回落的实现）
    @Test func healthy_style_passes_through_unchanged() {
        var s = DrawingDefaultStyle()
        s.lineSubType = .ray; s.lineStyle = .dash2; s.thickness = 3
        s.colorToken = .purple; s.labelMode = .right
        #expect(s.sanitized(for: .horizontal) == s)
    }
}

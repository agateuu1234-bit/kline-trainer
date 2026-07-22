// Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift
// 设置面板灰态判据（host 可测，非 View）。本期只实现水平线（母 spec §3.1 水平线行）；
// 其余工具的矩阵属 P1c，届时再泛化——本期不写不存在工具的分支（YAGNI）。
public enum DrawingStyleAvailability {
    /// 线型子类：水平线 直线✅/射线✅/线段灰。
    public static func horizontalLineSubTypeEnabled(_ sub: LineSubType) -> Bool {
        switch sub {
        case .straight, .ray: return true
        case .segment:        return false
        }
    }

    /// 标注：水平线 隐藏/左/右可选、显示恒灰；选射线时『左』再灰（母 spec §3.1）。
    public static func horizontalLabelModeEnabled(_ mode: LabelMode, lineSubType: LineSubType) -> Bool {
        switch mode {
        case .show:   return false
        case .hidden, .right: return true
        case .left:   return lineSubType != .ray
        }
    }

    /// 依赖字段规整：切线型子类后，若旧 labelMode 在新子类下不可用（如直线选『左』后切射线），
    /// 回落 .hidden；否则原样。**复用 horizontalLabelModeEnabled，规则单一真相不重复。**
    /// 设置卡片切线型时调它 → 矛盾组合（灰项却被当默认提交）从结构上进不来（codex plan-R1-medium）。
    public static func normalizedLabelMode(current: LabelMode, lineSubType: LineSubType) -> LabelMode {
        horizontalLabelModeEnabled(current, lineSubType: lineSubType) ? current : .hidden
    }
}

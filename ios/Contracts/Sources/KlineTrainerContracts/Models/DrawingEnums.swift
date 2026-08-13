// 画线样式/身份的值类型词汇表（画线工具扩充 P1a）。全部平台无关、host 可测。
import Foundation

public typealias DrawingID = String

public enum LineSubType: String, Codable, Equatable, Sendable, CaseIterable {
    case straight, ray, segment
}

public enum LineStyle: String, Codable, Equatable, Sendable, CaseIterable {
    case solid, dash1, dash2, dash3, dash4
}

public enum DrawingColorToken: String, Codable, Equatable, Sendable, CaseIterable {
    case red, orange, yellow, green, cyan, blue, purple, black, white
}

public enum LabelMode: String, Codable, Equatable, Sendable, CaseIterable {
    case hidden, show, left, right
}

public enum TextForm: String, Codable, Equatable, Sendable, CaseIterable {
    case borderTransparent, borderFilled, plain
}

/// 「下一条要画的线」的默认样式（1a-iii）。整局内存有效、不落盘（持久化全局默认属 P6）。
/// 是 DrawingSession 上的单一真相，提交路径 commitPending 原子消费它构造完整 DrawingObject。
public struct DrawingDefaultStyle: Codable, Equatable, Sendable {
    public var lineSubType: LineSubType = .straight
    public var lineStyle: LineStyle = .solid
    public var thickness: Int = 1                 // 1…5
    public var colorToken: DrawingColorToken = .orange
    public var labelMode: LabelMode = .hidden
    public init() {}
}

public extension DrawingDefaultStyle {
    /// 粗细值域的**唯一**字面量来源。面板与持久化解码器都必须引用它。
    /// ⚠️ 禁止任何地方再写 `1...5`（源码守卫 G5 钉死）。
    static let thicknessRange: ClosedRange<Int> = 1...5

    /// 把一份**可能来自磁盘 / 来自未来版本**的默认样式收敛成本构建一定能用的值。
    /// 三条规则各自复用既有单一真相，本函数**不新写任何判据**：
    ///   - `lineSubType` → `DrawingStyleAvailability.isRenderableSubType(_:toolType:)`
    ///   - `thickness`   → `thicknessRange`
    ///   - `labelMode`   → `DrawingStyleAvailability.normalizedLabelMode(current:lineSubType:toolType:)`
    /// ⚠️ **两处都必须用带 `toolType` 的重载**：两参版是**水平线专用**的，
    ///    对非水平工具套它会把合法的 `.show`/`.left` 静默改写成 `.hidden`
    ///    （`DrawingStyleAvailability` 里那个重载的头注逐字记录了这个后果）。
    func sanitized(for toolType: DrawingToolType) -> DrawingDefaultStyle {
        var out = self
        if !DrawingStyleAvailability.isRenderableSubType(out.lineSubType, toolType: toolType) {
            out.lineSubType = .straight
        }
        out.thickness = min(max(out.thickness, Self.thicknessRange.lowerBound),
                            Self.thicknessRange.upperBound)
        out.labelMode = DrawingStyleAvailability.normalizedLabelMode(
            current: out.labelMode, lineSubType: out.lineSubType, toolType: toolType)
        return out
    }
}

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
public struct DrawingDefaultStyle: Equatable, Sendable {
    public var lineSubType: LineSubType = .straight
    public var lineStyle: LineStyle = .solid
    public var thickness: Int = 1                 // 1…5
    public var colorToken: DrawingColorToken = .orange
    public var labelMode: LabelMode = .hidden
    public init() {}
}

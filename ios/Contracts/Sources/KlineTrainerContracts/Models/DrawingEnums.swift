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

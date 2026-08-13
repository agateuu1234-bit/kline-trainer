import Foundation
import KlineTrainerContracts

/// `drawing_default_style` 列的**唯一**编解码点。两个 pending repo 各调它一次（守卫 G7 钉死）。
///
/// ⚠️ **绝不 throw**（D92）：本列存的是**装饰性偏好**，它的一个坏字节**不得**让整局训练存档打不开。
///    这与 `settings` 表对财务键「malformed → .dbCorrupted」的策略**刻意不对称** —— 别为了"一致"改成抛。
/// ⚠️ 失败有**三类**，逐字段各自兜住：键缺失 / 值不是合法枚举 / **值的 JSON 类型就不对**。
///    故每个字段各自 `try?`，**不得**把五个字段包在同一个 `try` 里。
enum DrawingDefaultStyleColumn {

    static func encode(_ s: DrawingDefaultStyle?) -> String? {
        guard let s else { return nil }
        guard let data = try? JSONEncoder().encode(s) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// nil = 列为 NULL / 无任何可用内容。**任何解码失败都只影响对应字段**。
    static func decode(_ raw: String?) -> DrawingDefaultStyle? {
        guard let raw else { return nil }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return DrawingDefaultStyle().sanitized(for: .horizontal) }   // 整段坏 → 全量回落

        var s = DrawingDefaultStyle()
        if let v = obj["lineSubType"] as? String, let e = LineSubType(rawValue: v)   { s.lineSubType = e }
        if let v = obj["lineStyle"]   as? String, let e = LineStyle(rawValue: v)     { s.lineStyle = e }
        if let v = obj["thickness"]   as? Int                                        { s.thickness = v }
        if let v = obj["colorToken"]  as? String, let e = DrawingColorToken(rawValue: v) { s.colorToken = e }
        if let v = obj["labelMode"]   as? String, let e = LabelMode(rawValue: v)     { s.labelMode = e }
        // D93：解码边界即 sanitize —— 让「一个坏默认被读进内存」从构造上不可能。
        return s.sanitized(for: .horizontal)
    }
}

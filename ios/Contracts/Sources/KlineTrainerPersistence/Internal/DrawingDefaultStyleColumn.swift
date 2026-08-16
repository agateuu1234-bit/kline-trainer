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

    /// **只有列为 NULL 才返回 nil**（= 旧档 / 本局从未改过 ⇒ resume 不种子）。
    /// 整段 JSON 坏掉返回的是**出厂默认、非 nil**（取舍见下方注释）；
    /// 除此之外**任何解码失败都只影响对应字段**。
    static func decode(_ raw: String?) -> DrawingDefaultStyle? {
        guard let raw else { return nil }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // 整段坏 → 全量回落**出厂默认（非 nil）**，刻意不回落 nil。理由：
        //   · 无数据错误 —— 出厂值即全局默认，`sanitized` 对它是恒等变换，
        //     与「回 nil ⇒ resume 跳过种子 ⇒ 会话保持出厂值」殊途同归；
        //   · ⚠️ 但两者**语义强度不同**：非 nil 是**显式**把本局默认钉回已知良好值，
        //     nil 是**跳过**、听凭会话当时是什么。别为了"对称"改成 nil。
        // 已接受的代价：读回后「列损坏」与「从未改过」**不可区分**（可观测性损失，非数据错误）。
        else { return DrawingDefaultStyle().sanitized(for: .horizontal) }

        var s = DrawingDefaultStyle()
        if let v = obj["lineSubType"] as? String, let e = LineSubType(rawValue: v)   { s.lineSubType = e }
        if let v = obj["lineStyle"]   as? String, let e = LineStyle(rawValue: v)     { s.lineStyle = e }
        if let v = obj["thickness"]   as? Int                                        { s.thickness = v }
        if let v = obj["colorToken"]  as? String, let e = DrawingColorToken(rawValue: v) { s.colorToken = e }
        if let v = obj["labelMode"]   as? String, let e = LabelMode(rawValue: v)     { s.labelMode = e }
        // D93：解码边界即 sanitize —— 让「一个坏默认被读进内存」从构造上不可能。
        // ⚠️ **P1c 必须回来重判这个 `.horizontal` 实参**（spec §5.3 裁决「调用点恒 .horizontal、
        //    但保留入参」，本处是那个「恒 .horizontal」的落点）：一旦加入 `.trend` 等新工具，
        //    一份合法的 `.segment` 本局默认会**写得进磁盘、读回来被静默改成 .straight**，
        //    而 T15b 只锁单元级不变量、**那天不会有任何测试变红**。
        return s.sanitized(for: .horizontal)
    }
}

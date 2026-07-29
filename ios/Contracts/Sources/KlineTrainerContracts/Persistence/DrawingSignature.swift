// Sources/KlineTrainerContracts/Persistence/DrawingSignature.swift
// D56（1b-i）：replay clean-skip 的净状态判据 = drawing 规范语义签名。
// ⚠️ 不用 loadedDrawingsLossy.encoded() 的原始字节（codex R12-F2）：lossy 对编辑过的 known 行重序列化成
//   sorted-key JSON，edit+revert 后语义==baseline 但字节≠原始 raw → 字节相等误判脏 → 写净空槽覆盖别的记录。
//   必须先规范化：把每条 DrawingObject 的【全部字段】按固定顺序拼进签名（含 id），与 raw 字节格式无关。
// 与母 spec §6.3 D6 ReviewNetChange 的 per-drawing 全字段 key 同精神。
import Foundation

/// drawings 的规范语义签名：语义相等 ⟺ 签名相等，与磁盘 raw 的 key 顺序/格式无关。
/// 含 `id` + 全部已知字段（`DrawingObject.==` 排除 id，故不能直接用它）。顺序敏感（数组序 = z-order）。
/// ⚠️ **必须单射（codex plan-R2-F1）**：`id`/`text` 是普通 `String`，导入/损坏/未来数据可含任意字节
///   （含分隔符/控制字符）。用**长度前缀**编码每个字段（`"<utf8字节数>:<内容>"`），长度让边界无歧义 →
///   任意内容都不会碰撞；**不得**用裸分隔符 join（那样 `text` 里塞个分隔符就能伪造出等签名的不同 drawings，
///   导致 clean-skip 误判相等、丢编辑）。
public func canonicalDrawingsSignature(_ drawings: [DrawingObject]) -> String {
    // 长度前缀编码：任意 String s → "<s 的 utf8 字节数>:s"。拼接后按长度切回，无歧义（单射）。
    func lp(_ s: String) -> String { "\(s.utf8.count):\(s)" }
    return drawings.map { d -> String in
        // 每条：把所有字段都转成 String 后逐个 lp() 拼接。变长的 anchors 先放个数再逐字段。
        var fields: [String] = [d.id, d.toolType.rawValue, String(d.anchors.count)]
        for a in d.anchors {
            fields.append(String(a.candleIndex)); fields.append(String(a.price)); fields.append(a.period.rawValue)
        }
        fields.append(contentsOf: [
            d.period.rawValue, d.lineSubType.rawValue, d.lineStyle.rawValue, String(d.thickness),
            d.colorToken.rawValue, d.labelMode.rawValue, String(d.locked),
            d.text, String(d.fontSize), d.textColorToken.rawValue, d.textForm.rawValue,
            String(d.tailAnchor != nil),                       // 区分 tailAnchor==nil 与「有但字段恰好空」
            d.tailAnchor.map { lp(String($0.candleIndex)) + lp(String($0.price)) + lp($0.period.rawValue) } ?? "",
            String(d.isExtended), String(d.panelPosition), String(d.revealTick),
        ])
        return fields.map(lp).joined()
    }.map(lp).joined()                                          // 每条再 lp()：条边界也无歧义
}

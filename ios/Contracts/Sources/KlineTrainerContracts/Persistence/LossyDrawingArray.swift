// 所有画线数组持久化边界的容错编解码器（画线工具扩充 P1a，D21）。
// 坏/未知 toolType 单条只跳过、不整组失败；未识别条【原始字节级保真】回写，防「读时跳过+全量重写」丢线。
import Foundation

/// 平台无关、host 可测的顶层 JSON 数组切分器：按顶层元素切出各元素【原始字节文本】（去两侧空白、内部原样）。
/// 正确处理字符串内的转义与嵌套 {}[]。非顶层数组 → nil。空数组 → []。
enum JSONTopLevelArray {
    static func rawElementStrings(_ data: Data) -> [String]? {
        let b = [UInt8](data); let n = b.count; var i = 0
        func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func trimmedEmpty(_ lo: Int, _ hi: Int) -> Bool {   // 槽去空白后是否为空
            var a = lo; while a < hi, isWS(b[a]) { a += 1 }; return a >= hi
        }
        func slice(_ lo: Int, _ hi: Int) -> String {
            var a = lo, z = hi
            while a < z, isWS(b[a]) { a += 1 }
            while z > a, isWS(b[z - 1]) { z -= 1 }
            return String(decoding: b[a..<z], as: UTF8.self)
        }
        func tailAllWS(_ from: Int) -> Bool { var k = from; while k < n, isWS(b[k]) { k += 1 }; return k == n }
        while i < n, isWS(b[i]) { i += 1 }
        guard i < n, b[i] == UInt8(ascii: "[") else { return nil }
        i += 1
        // 空数组：`[` 后（跳空白）即 `]`（尾部须纯空白）
        var j = i; while j < n, isWS(b[j]) { j += 1 }
        if j < n, b[j] == UInt8(ascii: "]") { return tailAllWS(j + 1) ? [] : nil }
        var out: [String] = []
        var depth = 1, inString = false, escaped = false, start = i
        while i < n {
            let c = b[i]
            if inString {
                if escaped { escaped = false }
                else if c == UInt8(ascii: "\\") { escaped = true }
                else if c == UInt8(ascii: "\"") { inString = false }
                i += 1; continue
            }
            switch c {
            case UInt8(ascii: "\""): inString = true; i += 1
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1; i += 1
            case UInt8(ascii: "}"): depth -= 1; i += 1
            case UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 {
                    if trimmedEmpty(start, i) { return nil }        // 尾随逗号/空槽(如 `[x,]`) → 损坏
                    out.append(slice(start, i)); i += 1
                    return tailAllWS(i) ? out : nil                 // 尾部非纯空白(`[valid]]`/`[valid]{junk}`) → 损坏
                }
                i += 1
            case UInt8(ascii: ","):
                if depth == 1 {
                    if trimmedEmpty(start, i) { return nil }        // 前导/连续逗号/纯空白元素(`[,x]`/`[x,,y]`) → 损坏
                    out.append(slice(start, i)); i += 1; start = i
                } else { i += 1 }
            default: i += 1
            }
        }
        return nil   // 未闭合数组
    }
}

/// 有损画线数组的【有序】元素。**每条都携带原始 JSON 字节文本 `raw`**（W1/codex plan-R12-high）：
/// - `.known`：解码成功的条，**同时**保留其原始字节 → `encoded()` 原样重发，
///   保住**未来客户端在现有 toolType（如 horizontal）上加的未知字段**（Swift `JSONDecoder` 会忽略多余 key，
///   若重序列化会删掉它们）。
/// - `.unknownRaw`：解码失败的条（未知 toolType / 损坏）——只有原始字节。
/// 保序是正确性要求（codex plan-R2-high）；每条留 raw 是前向兼容要求（codex plan-R12-high）。
public enum LossyDrawingElement: Equatable, Sendable {
    case known(DrawingObject, raw: String)
    case unknownRaw(String)
}

public struct LossyDrawingArray: Equatable, Sendable {
    public let elements: [LossyDrawingElement]      // 已知/未识别按【原顺序】排列

    public init(elements: [LossyDrawingElement]) { self.elements = elements }
    /// 便捷：纯已知条（新写入路径）——raw = 该条编码（无未来字段，编码即权威）。
    public init(drawings: [DrawingObject]) {
        self.elements = drawings.map { .known($0, raw: LossyDrawingArray.encodeKnown($0)) }
    }

    /// 按序过滤已知条（供 Task 6/7 消费，名/类型不变）。
    public var drawings: [DrawingObject] {
        elements.compactMap { if case .known(let d, _) = $0 { return d } else { return nil } }
    }
    /// 按序取未识别条原文（诊断/测试用）。
    public var unknownRaw: [String] {
        elements.compactMap { if case .unknownRaw(let s) = $0 { return s } else { return nil } }
    }

    /// 良构 `DrawingObject` 的编码文本（DrawingObject 恒可编码；防御性 fallback）。
    static func encodeKnown(_ d: DrawingObject) -> String {
        guard let data = try? JSONEncoder().encode(d) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ data: Data) throws -> LossyDrawingArray {
        guard let rawElements = JSONTopLevelArray.rawElementStrings(data) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let decoder = JSONDecoder()
        var elems: [LossyDrawingElement] = []
        for (index, raw) in rawElements.enumerated() {
            if let d = try? decoder.decode(DrawingObject.self, from: Data(raw.utf8)) {
                if d.id.isEmpty {
                    // 无 id 的成功条 = 旧版本（pre-id）blob——按【原下标】回填命名空间唯一 id（D16）。
                    // 旧 blob 无未来未知字段，重编码安全且把回填 id 写进 raw（保证 id 持久）。
                    let withId = DrawingObject(
                        id: "legacy-idx-\(index)", toolType: d.toolType, anchors: d.anchors,
                        isExtended: d.isExtended, panelPosition: d.panelPosition, revealTick: d.revealTick,
                        period: d.period, lineSubType: d.lineSubType, lineStyle: d.lineStyle,
                        thickness: d.thickness, colorToken: d.colorToken, labelMode: d.labelMode,
                        locked: d.locked, text: d.text, fontSize: d.fontSize,
                        textColorToken: d.textColorToken, textForm: d.textForm, tailAnchor: d.tailAnchor)
                    elems.append(.known(withId, raw: encodeKnown(withId)))
                } else {
                    // 成功解码且有 id → 保留【原始字节】raw（含未来客户端可能加的未知字段，codex R12-high）。
                    elems.append(.known(d, raw: raw))
                }
            } else {
                elems.append(.unknownRaw(raw))      // 原始文本，字节级保留（【不】重序列化）、【保序】
            }
        }
        return LossyDrawingArray(elements: elems)
    }

    public func encoded() throws -> Data {
        // 按【原顺序】走 elements：**每条都用 raw 原样重发**（.known 也不重序列化 → 保未来字段），, 拼接包 []。
        var parts: [String] = []
        for e in elements {
            switch e {
            case .known(_, let raw): parts.append(raw)
            case .unknownRaw(let raw): parts.append(raw)
            }
        }
        return Data(("[" + parts.joined(separator: ",") + "]").utf8)
    }

    /// 本模型【全部已知磁盘 key】集（= `DrawingObject` 的 JSON key 全集）。merge 时据此清除
    /// 当前值为 nil 而被 `encodeIfPresent` 省略的可选已知字段（如 `tailAnchor`），防其从旧 raw 复活。
    /// 实施：与 `DrawingObject.CodingKeys.allCases`（或 spec §4.2 字段清单）逐一对齐，含
    /// id/toolType/anchors/isExtended/panelPosition/revealTick/period/lineSubType/lineStyle/thickness/
    /// colorToken/labelMode/locked/text/fontSize/textColorToken/textForm/tailAnchor。
    static let knownDiskKeys: Set<String> = [
        "id","toolType","anchors","isExtended","panelPosition","revealTick","period","lineSubType",
        "lineStyle","thickness","colorToken","labelMode","locked","text","fontSize",
        "textColorToken","textForm","tailAnchor"
    ]

    /// 把当前已知字段【覆盖进原始 JSON 对象、保留其未知 key】（编辑路径用；未知 key 必须存活，
    /// 字节不必全等——codex plan-R12）。原 raw 非对象 → fail-closed（保守）。
    static func mergeKnownFields(into rawJSON: String, from obj: DrawingObject) throws -> String {
        guard var dict = (try? JSONSerialization.jsonObject(with: Data(rawJSON.utf8))) as? [String: Any] else {
            throw AppError.persistence(.dbCorrupted)          // 原 raw 不是对象 → 无法安全 merge
        }
        guard let objDict = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(obj))) as? [String: Any] else {
            throw AppError.persistence(.dbCorrupted)
        }
        // ① 清除「已知 key 集里、但当前编码省略了的」可选已知字段（值改成 nil，如 tailAnchor）——
        //    否则旧 raw 里的该 key 会被误当"未知 key"保留、save/load 后复活（codex plan-R13-high）。
        for k in knownDiskKeys where objDict[k] == nil { dict.removeValue(forKey: k) }
        // ② 覆盖/新增当前编码里的已知 key；dict 里【非已知 key 集】的（未来未知 key）原样保留。
        for (k, v) in objDict { dict[k] = v }
        let merged = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(decoding: merged, as: UTF8.self)
    }

    /// 用「当前已知集合」（编辑/新增/删除后的最新内存态）与本数组已有的已知条按 **id** 对账：
    /// - 命中同 id 的原已知条 → `mergeKnownFields`（保原 raw 的未来未知 key，覆盖已知字段，位置不变）；
    /// - `currentKnown` 里未匹配到原已知条的 id → 视为新增，追加（raw = 全新编码）；
    /// - 原已知条的 id 不在 `currentKnown` 里 → 视为已删除，从结果移除；
    /// - `.unknownRaw` 条原样保留、位置不变（不受已知集合变化影响）。
    /// fail-closed（codex R14-high）：`currentKnown` 含重复 id 或空 id → `.dbCorrupted`（绝不静默去重/生成 id）。
    public func reconciled(currentKnown: [DrawingObject]) throws -> LossyDrawingArray {
        var seenIds = Set<DrawingID>()
        for d in currentKnown {
            if d.id.isEmpty { throw AppError.persistence(.dbCorrupted) }
            guard seenIds.insert(d.id).inserted else { throw AppError.persistence(.dbCorrupted) }
        }
        let currentById = Dictionary(uniqueKeysWithValues: currentKnown.map { ($0.id, $0) })
        var matchedIds = Set<DrawingID>()
        var out: [LossyDrawingElement] = []
        for e in elements {
            switch e {
            case .unknownRaw:
                out.append(e)
            case .known(let old, let raw):
                if let cur = currentById[old.id] {
                    matchedIds.insert(old.id)
                    let merged = try LossyDrawingArray.mergeKnownFields(into: raw, from: cur)
                    out.append(.known(cur, raw: merged))
                }
                // else: id 不在 currentKnown 里 → 已删除，丢弃
            }
        }
        // currentKnown 里未匹配到任何原已知条的 → 新增，按 currentKnown 原顺序追加在末尾。
        for d in currentKnown where !matchedIds.contains(d.id) {
            out.append(.known(d, raw: LossyDrawingArray.encodeKnown(d)))
        }
        return LossyDrawingArray(elements: out)
    }
}

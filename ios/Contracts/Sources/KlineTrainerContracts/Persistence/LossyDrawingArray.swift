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

    /// 用当前已知条重建 lossy：**按稳定 `DrawingObject.id` 归并**（非位置——否则删除一条 known 会把后续 known 挪到
    /// unknownRaw 前面破坏顺序，codex R11-medium；deleteDrawing/removeReviewDrawing 现已存在故 P1a 必须按 id）。
    /// **每条保 raw（W1/codex R12）**：`.unknownRaw` 原位保留；`.known` 若 id 仍在 currentKnown——
    /// **未编辑**（值相等）→ 原样 raw（保未来字段）、**已编辑** → `mergeKnownFields`（覆盖已知 key、保未知 key）；
    /// id 不在（被删）跳过；currentKnown 里原 elements 没有的（新增）追加末尾（raw=编码）。
    /// 编辑条若无法安全 merge（原 raw 非对象）→ throw fail-closed（不静默改写）。
    public func reconciled(currentKnown: [DrawingObject]) throws -> LossyDrawingArray {
        // fail-closed：id 必须唯一且非空——pending/review blob 无 DB 唯一约束，坏 blob 或旧 bug 的重复 id
        // 会让归并把首条复制到多槽 / 丢后续同 id 条（codex R14-high）。不静默折叠，抛 .dbCorrupted。
        func requireUniqueNonEmptyIds(_ ds: [DrawingObject]) throws {
            var seen = Set<DrawingID>()
            for d in ds {
                guard !d.id.isEmpty, seen.insert(d.id).inserted else {
                    throw AppError.persistence(.dbCorrupted)
                }
            }
        }
        try requireUniqueNonEmptyIds(currentKnown)
        try requireUniqueNonEmptyIds(elements.compactMap { if case .known(let d, _) = $0 { return d } else { return nil } })
        let byId = Dictionary(uniqueKeysWithValues: currentKnown.map { ($0.id, $0) })   // 已验唯一 → uniqueKeys
        var emitted = Set<DrawingID>()
        var out: [LossyDrawingElement] = []
        for el in elements {
            switch el {
            case .known(let old, let raw):
                guard let cur = byId[old.id] else { continue }                 // 被删 → 跳过
                if cur == old {
                    out.append(.known(old, raw: raw))                         // 未编辑 → 原样 raw（保未来字段）
                } else {
                    let merged = try LossyDrawingArray.mergeKnownFields(into: raw, from: cur)
                    out.append(.known(cur, raw: merged))                      // 已编辑 → merge 保未知 key
                }
                emitted.insert(old.id)
            case .unknownRaw(let r):
                out.append(.unknownRaw(r))                                    // 未识别条原位保留
            }
        }
        for k in currentKnown where !emitted.contains(k.id) {
            out.append(.known(k, raw: LossyDrawingArray.encodeKnown(k)))       // 真新增（原不在）追加末尾
        }
        return LossyDrawingArray(elements: out)
    }
}

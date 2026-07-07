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
    /// **throws（codex whole-branch High fix）**：`encodeKnown` 对非有限价（NaN/Infinity）DrawingObject
    /// fail-closed 抛错，此 init 必须传播（不得吞掉），否则一条不可编码的画线会让整批 fallback 成 `{}`
    /// （下次加载被当 unknownRaw，画线静默消失）。
    public init(drawings: [DrawingObject]) throws {
        self.elements = try drawings.map { .known($0, raw: try LossyDrawingArray.encodeKnown($0)) }
    }

    /// 按序过滤已知条（供 Task 6/7 消费，名/类型不变）。
    public var drawings: [DrawingObject] {
        elements.compactMap { if case .known(let d, _) = $0 { return d } else { return nil } }
    }
    /// 按序取未识别条原文（诊断/测试用）。
    public var unknownRaw: [String] {
        elements.compactMap { if case .unknownRaw(let s) = $0 { return s } else { return nil } }
    }

    /// `DrawingObject` 的编码文本。**throws（codex whole-branch High fix）**：非有限价（NaN/Infinity，
    /// 如 anchors[].price/tailAnchor.price）会让 `JSONEncoder` 抛错——此前 `try?` 吞掉后 fallback 成
    /// 字符串 `"{}"` 会被当作该条的 `raw` 静默持久化，下次加载 `"{}"` 解不出 DrawingObject → 被归类
    /// `.unknownRaw`，用户这条已知画线无声消失（durable data loss）。fail-closed：不再吞、不再伪造
    /// `{}`，让调用方（save 路径）失败并经既有 autosave 错误通路呈现给用户。
    static func encodeKnown(_ d: DrawingObject) throws -> String {
        let data = try JSONEncoder().encode(d)
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
                    elems.append(.known(withId, raw: try encodeKnown(withId)))
                } else {
                    // 成功解码且有 id → 保留【原始字节】raw（含未来客户端可能加的未知字段，codex R12-high）。
                    elems.append(.known(d, raw: raw))
                }
            } else {
                // codex whole-branch R11-high：`DrawingObject` 解码失败不代表这条是"合法但本版本不认识的
                // 未来画线"——`rawElementStrings` 只切分顶层元素，不证明元素本身是合法 JSON。若在此不加区分
                // 一律存成 `.unknownRaw`，畸形/损坏字节（`[not-json]`/`[123]`/`[{}]`）会被洗白成"看似正常"的
                // 持久数据：加载"成功"、`encoded()` 原样吐回、但 finalize 的 unknownRaw 门永久拒绝——用户卡在
                // 一个不可见、删不掉、永远无法 finalize 的会话里，反而绕开了 `.dbCorrupted` 本该触发的恢复路径。
                // 只有"合法 JSON 对象 + 带非空字符串 toolType"才算「像未来画线」，才保 unknownRaw（前向兼容）；
                // 其余（解析失败/标量/数组/无 toolType 的对象，含 `{}`）一律 fail-closed 抛 `.dbCorrupted`。
                //
                // codex whole-branch R12-high：上面这道门仍太松——一个 toolType 是【当前版本已认识】的合法
                // 工具（如 "horizontal"）、但 `DrawingObject` 解码仍失败（缺必填字段，如仅 `{"toolType":
                // "horizontal"}`；或字段类型错，如 `thickness` 是字符串），同样满足"合法 JSON 对象 + 非空
                // 字符串 toolType"，会被上面这道门误判成"未来画线"洗白成 unknownRaw——但它根本不是本版本不
                // 认识的未来工具，而是当前版本认识却损坏的数据，应 fail-closed 走 `.dbCorrupted` 恢复路径
                // （否则这条损坏数据会 durable/invisible/删不掉，永久卡住 finalize）。真正的「未来画线」判据
                // 是 toolType 不在当前 `DrawingToolType` 枚举里（`DrawingToolType(rawValue:) == nil`）——
                // 只有这种才保 unknownRaw；已识别工具解码失败 → 损坏 → 抛错。
                guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      let toolType = obj["toolType"] as? String, !toolType.isEmpty,
                      DrawingToolType(rawValue: toolType) == nil else {
                    throw AppError.persistence(.dbCorrupted)
                }
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

    /// codex whole-branch R9（两处 high 的共享根因）：「已知 drawing 未来字段」——`.known` 条 `raw` 除
    /// `knownDiskKeys` 外，【未来客户端】可能已经写进现有 toolType（如 horizontal）的额外顶层字段。这些字段
    /// 被 `JSONDecoder` 静默忽略（不会出现在解码出的 `DrawingObject` 里），只活在 `raw` 字节文本里——任何
    /// 「只读解码后的已知字段再重建」的路径（finalize 的表结构持久化 / 复盘 dirty 判定比较解码字段）都看
    /// 不见它们，若该路径清空/覆盖了原始 `raw`，这些字段就会不可逆丢失。本方法是这类数据的【唯一】读取
    /// 入口（finalize fail-closed 门 + 复盘 dirty 判定共享），防止两处各自实现出不一致的行为。
    ///
    /// 用 `JSONObjectScan.allTopLevelPairs`（字节级顶层键值扫描，同 wrapper 未知顶层 key 手法）取 `raw`
    /// 的全部顶层键值对，过滤出不在 `knownDiskKeys` 里的——值保持【原始字节文本】（未反转义/未重新格式化），
    /// 保证跨 raw 逐字节比较不受数值/字符串格式差异影响。
    ///
    /// 每个 `.known` 元素恒返回一条 `(id, future)`（即便 `future` 为空字典）——与 `elements` 里的已知条
    /// 一一对应、保持顺序/条数确定：调用方（dirty 判定）按【有序数组】逐条比较，"某条从有未来字段变没有"
    /// 与"顺序/条数变化"都能被此形状如实表达，不因"只收非空条"被压扁成模糊的长度变化。
    func knownFutureFieldPayloads() -> [(id: String, future: [String: String])] {
        elements.compactMap { element -> (id: String, future: [String: String])? in
            guard case .known(let d, let raw) = element else { return nil }
            var future: [String: String] = [:]
            // codex WB R14 finding 1：`knownDiskKeys` membership 须用语义反转义后的 key 判——转义过的已知
            // key（字节不同、语义相同，如 `toolType`）否则会被误判成「未来字段」。
            for pair in JSONObjectScan.allTopLevelPairs(Data(raw.utf8))
            where !LossyDrawingArray.knownDiskKeys.contains(JSONObjectScan.unescapeKey(pair.key)) {
                future[pair.key] = pair.rawValue
            }
            return (id: d.id, future: future)
        }
    }

    /// 是否存在任意 `.known` 元素携带未来字段（见 `knownFutureFieldPayloads` 注释）。
    var hasKnownFutureFields: Bool {
        knownFutureFieldPayloads().contains { !$0.future.isEmpty }
    }

    /// `hasKnownFutureFields` 的【存活】变体（codex WB R10 finding 1）：finalize 门本意是"这些未来字段
    /// 会不会随 finalize 永久丢失"——若用户已把携带未来字段的那条已知画线删除（`engine.drawings` 不再
    /// 含它），它已不会随 finalize 丢失，不应再计入。只统计 id 仍在 `liveIds`（调用方传 `engine.drawings`
    /// 的 id 集）里的已知条。
    func hasKnownFutureFields(liveIds: Set<DrawingID>) -> Bool {
        knownFutureFieldPayloads().contains { liveIds.contains($0.id) && !$0.future.isEmpty }
    }

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
            out.append(.known(k, raw: try LossyDrawingArray.encodeKnown(k)))   // 真新增（原不在）追加末尾
        }
        return LossyDrawingArray(elements: out)
    }

    /// codex WB R8 finding 2：load 时归一化——修复只应用一次（在 coordinator 把加载来的 lossy 种给 engine
    /// 之前），此后 engine 携带的 `.known` id 恒唯一非空，`reconciled(currentKnown:)` 的 dup/empty 门在正常
    /// 流程永不再 fail-close（那道门仍保留作 defense-in-depth，防运行期意外造出 dup id）。
    /// 只修复【损坏的】那部分：`.known` 元素里 id 为空、或与之前【已出现过】的 id 重复的，各自换发一个新
    /// `UUID().uuidString`（连带用 `mergeKnownFields` 把新 id 覆盖进该条【原始 raw】——保留原 raw 里任何
    /// 未来客户端字段，codex WB R10 finding 2；此前用 `encodeKnown` 重编码会丢掉它们）。
    /// `.unknownRaw` 元素与「id 唯一非空」的 `.known` 元素【原样字节不变】，元素【顺序不变】。
    public func normalizedUniqueIds() throws -> LossyDrawingArray {
        var seen = Set<DrawingID>()
        var out: [LossyDrawingElement] = []
        out.reserveCapacity(elements.count)
        for el in elements {
            switch el {
            case .unknownRaw:
                out.append(el)                                            // 原样不变
            case .known(let d, let raw):
                let isDuplicate = !d.id.isEmpty && !seen.insert(d.id).inserted
                if d.id.isEmpty || isDuplicate {
                    let renamed = DrawingObject(
                        id: UUID().uuidString, toolType: d.toolType, anchors: d.anchors,
                        isExtended: d.isExtended, panelPosition: d.panelPosition, revealTick: d.revealTick,
                        period: d.period, lineSubType: d.lineSubType, lineStyle: d.lineStyle,
                        thickness: d.thickness, colorToken: d.colorToken, labelMode: d.labelMode,
                        locked: d.locked, text: d.text, fontSize: d.fontSize,
                        textColorToken: d.textColorToken, textForm: d.textForm, tailAnchor: d.tailAnchor)
                    seen.insert(renamed.id)
                    let mergedRaw = try LossyDrawingArray.mergeKnownFields(into: raw, from: renamed)
                    out.append(.known(renamed, raw: mergedRaw))
                } else {
                    out.append(.known(d, raw: raw))                        // 唯一非空 id → 字节不变
                }
            }
        }
        return LossyDrawingArray(elements: out)
    }
}

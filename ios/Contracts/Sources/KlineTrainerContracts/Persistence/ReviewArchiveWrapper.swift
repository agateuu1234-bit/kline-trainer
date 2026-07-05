// 复盘存档列的 canonical 磁盘形状（画线工具扩充 P1a，§11.2/D14）。
// working_drawings/saved_drawings 列存 {"drawings":[…],"hiddenIds":[…]}；解码容错裸 [DrawingObject] 数组。
import Foundation

/// 顶层 JSON 对象按 key 取【原始值字节文本】（去两侧空白、内部字节原样）；非对象/找不到 → nil。
/// 让 wrapper 把 drawings 数组值的原始字节喂给 LossyDrawingArray（保真），不经 JSONSerialization 重序列化（codex plan-R2-high）。
enum JSONObjectScan {
    static func rawValueBytes(_ data: Data, key: String) -> String? {
        let b = [UInt8](data); let n = b.count; var i = 0
        func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func readString(_ i0: Int) -> (Int, Int, Int) {   // (内容start, 内容end, 闭引号后)
            var j = i0 + 1; let start = j; var esc = false
            while j < n { let c = b[j]
                if esc { esc = false } else if c == UInt8(ascii: "\\") { esc = true }
                else if c == UInt8(ascii: "\"") { return (start, j, j + 1) }
                j += 1 }
            return (start, j, j)
        }
        func skipValue(_ i0: Int) -> Int {
            var j = i0; guard j < n else { return j }
            let c = b[j]
            if c == UInt8(ascii: "\"") { return readString(j).2 }
            if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
                var depth = 0, inStr = false, esc = false
                while j < n { let ch = b[j]
                    if inStr { if esc { esc = false } else if ch == UInt8(ascii: "\\") { esc = true } else if ch == UInt8(ascii: "\"") { inStr = false } }
                    else if ch == UInt8(ascii: "\"") { inStr = true }
                    else if ch == UInt8(ascii: "{") || ch == UInt8(ascii: "[") { depth += 1 }
                    else if ch == UInt8(ascii: "}") || ch == UInt8(ascii: "]") { depth -= 1; if depth == 0 { return j + 1 } }
                    j += 1 }
                return j
            }
            while j < n { let ch = b[j]   // 数字/true/false/null → 读到分隔符
                if ch == UInt8(ascii: ",") || ch == UInt8(ascii: "}") || ch == UInt8(ascii: "]") || isWS(ch) { break }
                j += 1 }
            return j
        }
        while i < n, isWS(b[i]) { i += 1 }
        guard i < n, b[i] == UInt8(ascii: "{") else { return nil }
        i += 1
        let keyBytes = [UInt8](key.utf8)
        while i < n {
            while i < n, isWS(b[i]) { i += 1 }
            if i < n, b[i] == UInt8(ascii: "}") { return nil }
            guard i < n, b[i] == UInt8(ascii: "\"") else { return nil }
            let (ks, ke, afterKey) = readString(i); i = afterKey
            let thisKey = Array(b[ks..<ke])
            while i < n, isWS(b[i]) { i += 1 }
            guard i < n, b[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            while i < n, isWS(b[i]) { i += 1 }
            let vs = i, ve = skipValue(i)
            if thisKey == keyBytes {
                var a = vs, z = ve
                while a < z, isWS(b[a]) { a += 1 }
                while z > a, isWS(b[z - 1]) { z -= 1 }
                return String(decoding: b[a..<z], as: UTF8.self)
            }
            i = ve
            while i < n, isWS(b[i]) { i += 1 }
            if i < n, b[i] == UInt8(ascii: ",") { i += 1 } else { break }
        }
        return nil
    }

    /// 顶层对象 key 去重校验（codex R15-medium）：重复的 `drawings`/`hiddenIds` 等顶层 key → `.dbCorrupted`。
    /// （`JSONSerialization` 会静默取最后一个重复 key、而 `rawValueBytes` 取第一个，二者对损坏 blob 会分歧 → fail-closed。）
    static func requireNoDuplicateTopLevelKeys(_ data: Data) throws {
        let b = [UInt8](data); let n = b.count; var i = 0
        func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        while i < n, isWS(b[i]) { i += 1 }
        guard i < n, b[i] == UInt8(ascii: "{") else { return }   // 非对象由 caller 的整体校验拦
        i += 1
        var seen = Set<String>()
        while i < n {
            while i < n, isWS(b[i]) { i += 1 }
            if i < n, b[i] == UInt8(ascii: "}") { return }
            guard i < n, b[i] == UInt8(ascii: "\"") else { return }
            // 复用 rawValueBytes 的字符串读法读 key
            var j = i + 1; let ks = j; var esc = false
            while j < n { let c = b[j]
                if esc { esc = false } else if c == UInt8(ascii: "\\") { esc = true }
                else if c == UInt8(ascii: "\"") { break }
                j += 1 }
            let key = String(decoding: b[ks..<j], as: UTF8.self)
            guard seen.insert(key).inserted else { throw AppError.persistence(.dbCorrupted) }   // 重复顶层 key
            // 跳到该键的值末尾：借 rawValueBytes 定位后从 `,` 继续（简化：整体已由 caller JSONSerialization 验良构，
            // 这里只需数 key，用括号深度跳过值）
            i = j + 1
            while i < n, isWS(b[i]) { i += 1 }
            guard i < n, b[i] == UInt8(ascii: ":") else { return }
            i += 1
            // 跳过值（括号/字符串深度）
            while i < n, isWS(b[i]) { i += 1 }
            var depth = 0, inStr = false, e2 = false
            loop: while i < n { let ch = b[i]
                if inStr { if e2 { e2 = false } else if ch == UInt8(ascii: "\\") { e2 = true } else if ch == UInt8(ascii: "\"") { inStr = false } }
                else if ch == UInt8(ascii: "\"") { inStr = true }
                else if ch == UInt8(ascii: "{") || ch == UInt8(ascii: "[") { depth += 1 }
                else if ch == UInt8(ascii: "}") || ch == UInt8(ascii: "]") { if depth == 0 { break loop }; depth -= 1 }
                else if ch == UInt8(ascii: ",") && depth == 0 { break loop }
                i += 1 }
            if i < n, b[i] == UInt8(ascii: ",") { i += 1 }
        }
    }
}

public struct ReviewArchiveWrapper: Equatable, Sendable {
    public let lossy: LossyDrawingArray      // 有序 known/unknownRaw（保序 + 保真）
    public let hiddenIds: [DrawingID]

    public var drawings: [DrawingObject] { lossy.drawings }

    public init(lossy: LossyDrawingArray, hiddenIds: [DrawingID]) {
        self.lossy = lossy; self.hiddenIds = hiddenIds
    }
    /// 便捷：纯已知条（新写入）。
    public init(drawings: [DrawingObject], hiddenIds: [DrawingID]) {
        self.init(lossy: LossyDrawingArray(drawings: drawings), hiddenIds: hiddenIds)
    }

    public static func decodeColumn(_ json: String) throws -> ReviewArchiveWrapper {
        let data = Data(json.utf8)
        // 裸数组（旧形状）→ 整列就是 drawings；hiddenIds 空。
        if JSONTopLevelArray.rawElementStrings(data) != nil {
            return ReviewArchiveWrapper(lossy: try LossyDrawingArray.decode(data), hiddenIds: [])
        }
        // wrapper 对象：**先整体校验良构再切片**（codex R15-medium）——`rawValueBytes` 找到 key 即返、不验
        // 剩余字节，故 valid-prefix + 尾部垃圾/重复 key 会被误当合法后洗白。此处用 `JSONSerialization` 整体解析
        // 做 fail-closed 门（覆盖到 EOF、拒尾部垃圾）+ 顶层重复 key 检测；解析仅验证、**保真提取仍走 rawValueBytes**。
        guard let top = try? JSONSerialization.jsonObject(with: data, options: []),   // 整解成功=覆盖到 EOF、无尾部垃圾
              top is [String: Any] else {
            throw AppError.persistence(.dbCorrupted)
        }
        try JSONObjectScan.requireNoDuplicateTopLevelKeys(data)                        // 顶层 drawings/hiddenIds 重复 key → 损坏
        guard let drawingsRaw = JSONObjectScan.rawValueBytes(data, key: "drawings") else {
            throw AppError.persistence(.dbCorrupted)
        }
        let lossy = try LossyDrawingArray.decode(Data(drawingsRaw.utf8))
        // hiddenIds：缺失(旧 wrapper)→ []；**present 但 malformed（非 [String]）→ .dbCorrupted**（不静默当空，
        // 否则损坏/schema 漂移会覆盖唯一隐藏态副本使已隐藏原训练线重现，codex R10-medium）。
        var hidden: [DrawingID] = []
        if let hraw = JSONObjectScan.rawValueBytes(data, key: "hiddenIds") {   // 存在该键
            guard let decoded = try? JSONDecoder().decode([DrawingID].self, from: Data(hraw.utf8)) else {
                throw AppError.persistence(.dbCorrupted)                        // 存在但非 [String] → 损坏
            }
            hidden = decoded
        }
        return ReviewArchiveWrapper(lossy: lossy, hiddenIds: hidden)
    }

    public func encodedColumn() throws -> String {
        // 直接拼接：drawings 用 lossy 保真字节、hiddenIds 正常编码；不重序列化整体。
        let drawingsStr = String(decoding: try lossy.encoded(), as: UTF8.self)
        let hiddenStr = String(decoding: try JSONEncoder().encode(hiddenIds), as: UTF8.self)
        return "{\"drawings\":\(drawingsStr),\"hiddenIds\":\(hiddenStr)}"
    }
}

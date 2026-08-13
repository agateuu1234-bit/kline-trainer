import XCTest

/// G9：发现式守卫 —— 不信任任何人写的文件清单，自己遍历测试目录。
/// 判据：`PRAGMA user_version` 的断言值若为 `7`，则它上方最近一次 `.migrate(` **必须**带 `upTo:`
///（即它是「部分迁移的中间落点」）。跑完整 migrator 之后的终态断言在 0010 之后一律是 `8`。
final class UserVersionAssertionGuardTests: XCTestCase {

    struct Site: Equatable {
        let file: String, line: Int, value: Int
        /// 上方最近一行 `.migrate(` 是否带 `upTo:`；上方根本没有 `.migrate(` 时为 false
        let afterPartialMigrate: Bool
    }

    /// 扫一份源码。**先剥 `//` 之后的内容**再匹配 —— 注释里的断言不算数，
    /// 承重注释（行尾那串迁移史）也不得污染判据。
    /// ⚠️ 剥注释必须**跟踪字符串状态**：朴素地「见 `//` 就吃到行尾」会被
    /// `let u = "https://x"` 这种字面量骗到，把**同一行后面的真实代码**一起丢掉 ——
    /// 那是**反向漏**（少数了断言 ⇒ 守卫悄悄放宽），比误报危险。本仓
    /// `SourceGuardScanner.swift:49` 已把这个坑写在案。
    static func sites(in source: String, file: String) -> [Site] {
        let lines = source.components(separatedBy: "\n").map { stripLineComment($0) }
        var out: [Site] = []
        for (i, l) in lines.enumerated() where l.contains("PRAGMA user_version") {
            // `PRAGMA user_version = N` 是**写入**（fixture 造现场），不是断言
            if l.contains("PRAGMA user_version =") { continue }
            // 断言值可能就在本行，也可能在随后几行（`let uv = …` 换行再 `XCTAssertEqual(uv, 7)`）
            let window = lines[i..<min(i + 4, lines.count)].joined(separator: "\n")
            guard let v = firstComparedInt(window) else { continue }
            var partial = false
            for j in stride(from: i, through: 0, by: -1) where lines[j].contains(".migrate(") {
                partial = lines[j].contains("upTo:"); break
            }
            out.append(Site(file: file, line: i + 1, value: v, afterPartialMigrate: partial))
        }
        return out
    }

    /// 剥行注释，但**只在引号外**认 `//`（转义 `\"` 不计入配对）。
    static func stripLineComment(_ l: String) -> String {
        var out = "", inStr = false, esc = false
        let c = Array(l)
        var i = 0
        while i < c.count {
            if esc { esc = false; out.append(c[i]); i += 1; continue }
            if c[i] == "\\" { esc = true; out.append(c[i]); i += 1; continue }
            if c[i] == "\"" { inStr.toggle(); out.append(c[i]); i += 1; continue }
            if !inStr, c[i] == "/", i + 1 < c.count, c[i + 1] == "/" { break }
            out.append(c[i]); i += 1
        }
        return out
    }

    /// 抓窗口里第一个「被比较的整数」：`== 7` 与 `, 7)` 两种形态。
    private static func firstComparedInt(_ s: String) -> Int? {
        let ns = s as NSString
        var best: (loc: Int, val: Int)? = nil
        for p in ["== *([0-9]+)", ", *([0-9]+)\\)"] {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
                  let v = Int(ns.substring(with: m.range(at: 1))) else { continue }
            if best == nil || m.range.location < best!.loc { best = (m.range.location, v) }
        }
        return best?.val
    }

    static func scanTestsDirectory() throws -> [Site] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let me = URL(fileURLWithPath: #filePath).lastPathComponent
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { XCTFail("无法遍历 \(dir.path)"); return [] }
        var out: [Site] = []
        for case let u as URL in e where u.pathExtension == "swift" && u.lastPathComponent != me {
            out += sites(in: try String(contentsOf: u, encoding: .utf8), file: u.lastPathComponent)
        }
        return out.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    func test_no_terminal_user_version_assertion_still_reads_7() throws {
        let all = try Self.scanTestsDirectory()
        // 反向断言防空转：正则或目录遍历一坏，下面的 filter 就恒为空、守卫恒绿
        XCTAssertGreaterThanOrEqual(all.count, 10, "只扫到 \(all.count) 处断言 —— 扫描器坏了")
        XCTAssertGreaterThanOrEqual(Set(all.map(\.file)).count, 5,
            "只覆盖 \(Set(all.map(\.file)).count) 个文件 —— 目录遍历坏了")

        let bad = all.filter { $0.value == 7 && !$0.afterPartialMigrate }
        XCTAssertTrue(bad.isEmpty, "以下 user_version 终态断言仍停在 7（0010 之后应为 8）：\n"
            + bad.map { "  \($0.file):\($0.line)" }.joined(separator: "\n"))
    }

    /// 双向自检：判据本身既要抓得住违规，又不能误伤合法的中间落点，也不能把注释算进来。
    func test_scanner_discriminates_terminal_from_partial() {
        let violating = """
        try migrator.migrate(queue)
        let uv = try Int.fetchOne(db, sql: "PRAGMA user_version")
        XCTAssertEqual(uv, 7)
        """
        let legal = """
        try migrator.migrate(queue, upTo: "0009_v1.11_drawing_style")
        #expect((try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1) == 7)
        """
        let commented = """
        try migrator.migrate(queue)
        // let uv = try Int.fetchOne(db, sql: "PRAGMA user_version"); XCTAssertEqual(uv, 7)
        """
        let written = #"try db.execute(sql: "PRAGMA user_version = 2")"#
        // 反向漏样本：字符串里的 `//` 不得把同一行后面的真实代码吃掉
        let urlInString = """
        try migrator.migrate(queue)
        let note = "see https://example.com"; let uv = try Int.fetchOne(db, sql: "PRAGMA user_version")
        XCTAssertEqual(uv, 7)
        """

        let v = Self.sites(in: violating, file: "X")
        let l = Self.sites(in: legal, file: "X")
        XCTAssertEqual(v.map(\.value), [7])
        XCTAssertEqual(l.map(\.value), [7])
        XCTAssertFalse(v.first?.afterPartialMigrate ?? true, "跑完整 migrator 后的断言不得被当成中间落点")
        XCTAssertTrue(l.first?.afterPartialMigrate ?? false, "upTo: 之后的 7 是合法的")
        XCTAssertTrue(Self.sites(in: commented, file: "X").isEmpty, "注释里的断言不得计入")
        XCTAssertTrue(Self.sites(in: written, file: "X").isEmpty, "PRAGMA 写入语句不是断言")
        XCTAssertEqual(Self.sites(in: urlInString, file: "X").map(\.value), [7],
                       "字符串里的 // 不得把同一行后面的真实代码吃掉（反向漏 = 守卫悄悄放宽）")
    }
}

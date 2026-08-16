import XCTest

/// G9：发现式守卫 —— 不信任任何人写的文件清单，自己遍历测试目录。
/// 判据：`PRAGMA user_version` 的断言值若为 `7`，则它上方最近一次 `.migrate(` **必须**带 `upTo:`
///（即它是「部分迁移的中间落点」）。跑完整 migrator 之后的终态断言在 0010 之后一律是 `8`。
final class UserVersionAssertionGuardTests: XCTestCase {

    struct Site: Equatable {
        let file: String, line: Int
        /// `nil` = 找到了 `PRAGMA user_version` 的**读取**，但窗口内**抓不到被比较的整数**
        /// （书写形态超出扫描器能力，例如断言隔了 4 行以上）。
        /// ⚠️ 这一档必须**显式报出来**，绝不能像旧版那样 `continue` 静默丢弃：
        ///    锚点失效时静默跳过 ⇒ 发现式守卫悄悄少一个站点，而它的全部价值就是
        ///    「不信任任何人写的清单、自己把站点数全」。本仓已为同族问题栽过
        ///    （机械检查器被它该抓的损坏禁用了自身解析器 → 静默全绿）。
        ///    真实漂移另有运行时兜底（该测试自身会因 uv 实为 8 而失败），故本档定为
        ///    「守卫职能缺失」而非「数据错误」—— 但仍必须出声。
        let value: Int?
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
            // 只有**真执行 SQL 的代码行**才算站点。文档/样例里的纯提及（如
            // `M01MatrixSyncGuardTests` 里那份 m01 矩阵 markdown 表格，单元格文本恰好是
            // 「训练组 SQLite \`PRAGMA user_version\`」）不是断言，也永远抓不到被比较的整数。
            // ⚠️ 这条 `continue` 与下面「抓不到整数」那档**性质完全不同**，别合并：
            //    这里是**用正面结构判据断定它不是站点**（安全）；
            //    那里是**判据够不着、不知道**，必须出声（否则就是静默漏站）。
            // 实测依据：本树 `Tests/` 下 33 处 `PRAGMA user_version` 里，全部真实读/写站点
            // 都带 `sql:`；不带的只有注释（已剥）、守卫自身（扫描时排除）、以及上述表格样例。
            guard l.contains("sql:") else { continue }
            // 断言值可能就在本行，也可能在随后几行（`let uv = …` 换行再 `XCTAssertEqual(uv, 7)`）
            // ⚠️ 抓不到时**记成 value == nil 的站点**，不 `continue` —— 见 `Site.value` 的注释。
            let window = lines[i..<min(i + 4, lines.count)].joined(separator: "\n")
            let v = firstComparedInt(window)
            var partial = false
            for j in stride(from: i, through: 0, by: -1) {
                // 先撞到函数声明 ⇒ 本函数体内没有 .migrate( ⇒ 不是部分迁移落点（安全方向）
                if lines[j].contains("func ") { break }
                if lines[j].contains(".migrate(") { partial = lines[j].contains("upTo:"); break }
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

        // 锚点失效必须**出声**：抓不到被比较整数的站点在旧版被 `continue` 静默丢弃，
        // 于是 G9 的「把站点数全」这一职能对该书写形态无声失效。
        let unparsed = all.filter { $0.value == nil }
        XCTAssertTrue(unparsed.isEmpty,
            "以下站点找到了 PRAGMA user_version 读取、却在 4 行窗口内抓不到被比较的整数 ——\n"
            + "G9 对这种书写形态会漏站。请改写该测试、或调宽/增强扫描器，**不得**放任静默漏站：\n"
            + unparsed.map { "  \($0.file):\($0.line)" }.joined(separator: "\n"))

        let bad = all.filter { $0.value == 7 && !$0.afterPartialMigrate }
        XCTAssertTrue(bad.isEmpty, "以下 user_version 终态断言仍停在 7（0010 之后应为 8）：\n"
            + bad.map { "  \($0.file):\($0.line)" }.joined(separator: "\n"))
    }

    /// 双向自检：抓不到整数的站点必须被**记下并报出**，而不是被丢掉；
    /// 同时正常书写形态不得被误记成「未解析」。
    func test_scanner_reports_unparsable_site_instead_of_dropping_it() {
        // 断言隔了 4 行以上 —— 正是 R2 评审点名的那种书写形态
        let farAway = """
        try migrator.migrate(queue)
        let uv = try Int.fetchOne(db, sql: "PRAGMA user_version")
        let a = 1
        let b = 2
        let c = 3
        XCTAssertEqual(uv, 7)
        """
        let s = Self.sites(in: farAway, file: "X")
        XCTAssertEqual(s.count, 1, "站点必须被记下，不得静默丢弃")
        XCTAssertNil(s.first?.value, "窗口外取不到整数 ⇒ 必须记成未解析（value == nil），不是 continue")

        // 反向：正常形态不得被误记成未解析（否则这条守卫会在健康树上恒红）
        let normal = """
        try migrator.migrate(queue)
        let uv = try Int.fetchOne(db, sql: "PRAGMA user_version")
        XCTAssertEqual(uv, 8)
        """
        XCTAssertEqual(Self.sites(in: normal, file: "X").first?.value, 8,
                       "健康书写形态必须正常解析，不得误判为未解析")

        // 反向 2：**文档/样例里的纯提及不是站点** —— 本树真实存在这一档
        // （`M01MatrixSyncGuardTests` 的 m01 矩阵 markdown 样例），
        // 若把它当站点，会因永远抓不到整数而让上面那条「未解析」断言在健康树上恒红。
        let markdownMention = """
        | 维度 | 当前版本 | 变更触发 bump 的条件 |
        | 训练组 SQLite `PRAGMA user_version` | `1` | … |
        """
        XCTAssertTrue(Self.sites(in: markdownMention, file: "X").isEmpty,
                      "无 sql: 的纯文本提及不是执行站点，不得计入")
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

    /// 回扫不得跨函数边界：函数 A 以 `upTo:` 结尾，紧接着函数 B 自己不含 `.migrate(`
    /// （靠 helper 做 full migrate）却断言 `== 7` —— B 必须被判为终态断言（不合法），
    /// 不能因为文本上离 A 的 `upTo:` 最近就被误判成中间落点。
    func test_scanner_does_not_cross_function_boundary() {
        let crossFunction = """
        @Test func a() throws {
            try migrator.migrate(queue, upTo: "0009_v1.11_drawing_style")
            #expect((try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1) == 7)
        }
        @Test func b() throws {
            let uv = try Int.fetchOne(db, sql: "PRAGMA user_version")
            XCTAssertEqual(uv, 7)
        }
        """
        let sites = Self.sites(in: crossFunction, file: "X")
        XCTAssertEqual(sites.count, 2)
        XCTAssertTrue(sites[0].afterPartialMigrate, "A：同函数内有 upTo: ⇒ 合法中间落点")
        XCTAssertFalse(sites[1].afterPartialMigrate, "B：本函数体内无 .migrate( ⇒ 必须被判为终态")
    }
}

import XCTest

/// G8：m01 矩阵三行必须与本 PR 同步。
/// 为什么需要它：本片 spec 自己点名的「矩阵停在 0003、代码已到 0009」正是「要求同步但无人强制」的产物。
///
/// ⚠️ 判据必须**按行首标签取整格比对**，不能对整节做 `contains`（codex P-R7 medium）：
/// 矩阵章节里紧跟着一串「bump 记录」引用块，而 Step 5 会往那里**新加一条写着 `"1.13"`、
/// `0010_v1.13_drawing_default_style`、`1.4` 的记录**。整节 `contains` 会被这条新记录喂饱，
/// 于是「顶层行忘了改」照样绿 —— 那正是本守卫要防的那个失败。
final class M01MatrixSyncGuardTests: XCTestCase {

    private func matrixSection() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root
            .appendingPathComponent("docs/governance/m01-schema-versioning-contract.md"), encoding: .utf8)
        guard let start = doc.range(of: "## CONTRACT_VERSION 矩阵"),
              let end = doc.range(of: "**存储表位 速查**", range: start.upperBound..<doc.endIndex)
        else { XCTFail("m01 矩阵锚点失效，无法定位章节"); return "" }   // 锚点失效必须报错，不得静默返回空
        return String(doc[start.upperBound..<end.lowerBound])
    }

    /// 解析 markdown 表 → [首列标签: 第二列值]。**只收 `|---|` 分隔行之后的数据行**
    ///（bump 记录是 `>` 引用块，天然被排除）。
    ///
    /// ⚠️ **必须显式跳过表头行**（Task 4 实施者实测暴露、控制者复现确认）：
    ///    只靠「第二列全是 `-`/`:` 就跳过」**只能跳掉分隔行本身**，表头那行
    ///    （`| 维度 | 当前版本 | … |`）会被当成一条数据 ⇒ 解析出 6 行而不是 5 行，
    ///    自检里的防空转计数恒不成立。markdown 的语义就是「分隔行之前是表头」，
    ///    所以判据取「见到分隔行之后才开始收」——而不是把期望计数从 5 改成 6
    ///    （那是把错误固化，且 `rows()` 会继续返回一条根本不是数据的行）。
    static func rows(_ section: String) -> [String: String] {
        var out: [String: String] = [:]
        var seenDivider = false
        for raw in section.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|"), line.hasSuffix("|") else { continue }
            let cells = line.dropFirst().dropLast()
                .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2, !cells[1].isEmpty else { continue }
            if cells[1].allSatisfy({ $0 == "-" || $0 == ":" }) { seenDivider = true; continue }
            guard seenDivider else { continue }        // 分隔行之前 = 表头，不是数据
            out[cells[0]] = cells[1]
        }
        return out
    }

    func test_m01_matrix_three_rows_are_in_sync() throws {
        let r = Self.rows(try matrixSection())
        XCTAssertGreaterThanOrEqual(r.count, 5, "只解析出 \(r.count) 行 —— 表解析坏了（防空转）")
        XCTAssertEqual(r["`CONTRACT_VERSION`（顶层标识）"], "`\"1.13\"`", "m01 顶层版本行未同步")
        XCTAssertEqual(r["app.sqlite GRDB migration"], "`0010_v1.13_drawing_default_style`",
                       "m01 app.sqlite migration 行未同步")
        XCTAssertEqual(r["Swift 模型版本（`M0.3`）"], "`1.4`", "m01 Swift 模型版本行未同步")
    }

    /// 双向自检：**用同一个解析器**跑一份「三行都还是旧值、但 bump 记录里三个新值全都出现过」的样本。
    /// 旧稿的自检只对局部字符串调 `String.contains`，测的是标准库不是判据 —— 恒绿。
    func test_parser_is_immune_to_values_that_only_appear_in_bump_notes() {
        let sample = """
        | 维度 | 当前版本 | 变更触发 bump 的条件 |
        |---|---|---|
        | `CONTRACT_VERSION`（顶层标识） | `"1.12"` | … |
        | PostgreSQL schema（`schema.sql` migration id） | `0004_qmt_price_double_and_coverage` | … |
        | 训练组 SQLite `PRAGMA user_version` | `1` | … |
        | app.sqlite GRDB migration | `0003_v1.4_purge_leased` | … |
        | Swift 模型版本（`M0.3`） | `1.3` | … |

        > **bump 记录**：顶层 `CONTRACT_VERSION` `"1.12"` → `"1.13"`；app.sqlite 同步至
        > `0010_v1.13_drawing_default_style`；Swift 模型版本 `1.3` → `1.4`。
        """
        let r = Self.rows(sample)
        XCTAssertEqual(r.count, 5, "样本应解析出 5 行（防空转）")
        XCTAssertNotEqual(r["`CONTRACT_VERSION`（顶层标识）"], "`\"1.13\"`")
        XCTAssertNotEqual(r["app.sqlite GRDB migration"], "`0010_v1.13_drawing_default_style`")
        XCTAssertNotEqual(r["Swift 模型版本（`M0.3`）"], "`1.4`")
    }
}

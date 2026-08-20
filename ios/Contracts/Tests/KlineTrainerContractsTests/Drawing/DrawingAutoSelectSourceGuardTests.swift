// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift
// Spec: docs/superpowers/specs/2026-08-12-drawing-tools-P1b-autoselect-design.md §8
//
// 本文件是 XCTest（不是 swift-testing）：与 SourceGuardScanner.swift 的既有守卫同族，
// 且 `swift test | tail -3` 那行汇总**不包含** XCTest —— 判绿必须另读
// `Executed N tests, with 0 failures`（计划 Global Constraints G-3）。
//
// 纪律（spec §8，缺一即失效）：
//   · 一律**结构计数**，不写禁词黑名单；
//   · 匹配前必须**剥注释、剥字符串字面量**（用 squeezedSource / callCount）——否则本片要求写的
//     那些承重注释会把守卫自己打红，而「删掉那句注释」就成了合法绕过路径；
//   · 每条守卫配**双向自检**：本该命中的合成样本必须命中、本该不命中的必须不命中。
import XCTest
@testable import KlineTrainerContracts

final class DrawingAutoSelectSourceGuardTests: XCTestCase {

    private let routerPath  = "Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift"

    /// `Sources/` 里某调用 pattern 的调用点（file, count）。零调用的文件不出现。
    private func sites(_ pattern: String) throws -> [(file: String, count: Int)] {
        try callSiteCount(pattern)
    }

    /// 断言：`Sources/` 里 pattern 恰好 `n` 个调用点，且**全部**落在后缀为 `suffix` 的那个文件里。
    private func assertExactlyOneSite(_ pattern: String, inFileSuffixed suffix: String,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let s = try sites(pattern)
        let total = s.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, 1, "『\(pattern)』在 Sources/ 里有 \(total) 个调用点（期望 1）：\(s)",
                       file: file, line: line)
        XCTAssertEqual(s.count, 1, "『\(pattern)』散在多个文件里：\(s.map(\.file))", file: file, line: line)
        XCTAssertTrue(s.first?.file.hasSuffix(suffix) == true,
                      "『\(pattern)』的唯一调用点应在 \(suffix)，实际在 \(s.first?.file ?? "<无>")",
                      file: file, line: line)
    }

    // MARK: G2（本 task 落地：setCommittedSelection 的唯一调用点必须在路由里）

    func testG2_setCommittedSelectionHasExactlyOneCallSiteInRouter() throws {
        try assertExactlyOneSite("setCommittedSelection(id:",
                                 inFileSuffixed: "Drawing/DrawingEditRouter.swift")
    }

    func testG2SelfCheck_bothDirections() {
        let positive = """
        func caller() {
            engine.drawingSession.setCommittedSelection(id: committed.id, panel: panel)
        }
        """
        XCTAssertEqual(callCount(inSqueezed: squeezedText(positive),
                                 pattern: "setCommittedSelection(id:"), 1,
                       "自检①失败：真实调用没被数到 —— 守卫已失效")

        let negative = """
        func setCommittedSelection(id: DrawingID, panel: PanelId) { }
        // engine.drawingSession.setCommittedSelection(id: 注释里的不算)
        func caller() { session.setSelection(id: hit.id, panel: panel) }
        """
        XCTAssertEqual(callCount(inSqueezed: squeezedText(negative),
                                 pattern: "setCommittedSelection(id:"), 0,
                       "自检②失败：定义/注释/另一个入口被误计 —— 守卫会假红")
    }

    // MARK: G5（回归守卫 —— 改动前就已经是绿的，故与生产改动分开落库是合法的）

    func testG5_setSelectionHasExactlyOneCallSiteInChartContainerView() throws {
        // ⚠️ pattern 用**完整调用语法锚** `setSelection(id:`：裸写 `setSelection(` 在字面上不会被
        //    `setCommittedSelection(` 命中（那里 `setS` 不成串），但完整锚同时挡住未来任何改名带来的
        //    子串误命中，是更强也更便宜的写法（spec §8 G5 点名要求边界锚）。
        try assertExactlyOneSite("setSelection(id:", inFileSuffixed: "Render/ChartContainerView.swift")
    }

    func testG5SelfCheck_bothDirections() {
        // ① 本该命中：一次真实调用（换行 / 块注释排版都逃不掉，squeeze 后一样）
        let positive = """
        func caller() {
            session.setSelection(
                id: hit.id, panel: panel
            )
        }
        """
        XCTAssertEqual(callCount(inSqueezed: squeezedText(positive), pattern: "setSelection(id:"), 1,
                       "自检①失败：真实调用没被数到 —— 守卫已失效")

        // ② 本该**不**命中：定义行 / 注释里的字样 / 互斥入口 setCommittedSelection
        let negative = """
        func setSelection(id: DrawingID, panel: PanelId) { }
        // session.setSelection(id: 注释里的不算)
        func caller() {
            session.setCommittedSelection(id: committed.id, panel: panel)
        }
        """
        XCTAssertEqual(callCount(inSqueezed: squeezedText(negative), pattern: "setSelection(id:"), 0,
                       "自检②失败：定义/注释/互斥入口被误计 —— 守卫会假红")
    }
}

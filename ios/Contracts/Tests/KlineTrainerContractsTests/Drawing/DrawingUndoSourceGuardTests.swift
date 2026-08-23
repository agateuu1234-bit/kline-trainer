// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoSourceGuardTests.swift
// Spec: 2026-08-11-...-1b-ii-lock-undo-design.md §2.6（N-S / N-N3 的守卫那半）+ 计划决策 D102/D103
//
// 本文件是 XCTest（不是 swift-testing）：与 SourceGuardScanner.swift 的既有守卫同族，
// 且 `swift test | tail -3` 那行汇总**不包含** XCTest —— 判绿必须另读
// `Executed N tests, with 0 failures`（计划 Global Constraints G-3）。
//
// 纪律（G-5，缺一即失效）：结构计数不写黑名单；匹配前剥注释剥字面量；每条配双向自检。
import XCTest
@testable import KlineTrainerContracts

// ⚠️ 下面三个助手必须在**文件作用域**（类外），不能写成 `XCTestCase` 的实例方法
//    （codex plan-R7 high，**已核实为真**）：Task 4 的 `engineDrawingsWritesByFunction` 是文件级函数，
//    从它里面调实例方法 Swift 解析不了，整个守卫文件**编译不过**，后续所有 task 全部卡住。
//    放文件作用域后，XCTest 类与那个文件级函数**用的是同一份判据**，也不会漂移。

/// 读某个源文件的**保留边界**代码文本（剥注释、剥字符串字面量，但**保留空白**）。
/// 函数体切片必须在它上面做，见 `functionBodies` 的说明。
func boundaryCodeOf(_ path: String) throws -> String {
    codeTextPreservingBoundaries(try String(contentsOfFile: path, encoding: .utf8))
}

/// 取某个函数（含同名重载，全部）的**函数体**，返回值已 `squeeze`，可直接与 squeeze 过的 needle 比对。
    ///
    /// ⚠️ **必须在"保留边界"的文本上切，且用大括号配对定边界**（codex plan-R5 high，**已核实为真**）。
    ///    原稿是「在 `squeezedSource` 上切，从 `func <name>(` 到**下一个** `func ` 为止」——
    ///    `squeezedSource` 把空白**全删了**，`func ` 这个带空格的边界**永远匹配不到**
    ///    （`private func foo` 变成 `privatefuncfoo`），于是切出来的"函数体"一路吃到文件末尾。
    ///    后果：「某个调用在不在这个函数里」退化成「在不在这个文件里」——
    ///    U-G1 / U-G7 会在"要求的调用其实写在后面另一个函数里"时**假绿**，
    ///    而 U-G4 的逐函数计数（每个先出现的函数都会把后面所有写入算进来）**根本无法满足**。
    ///    也**不能**改成"在 squeezed 文本里找裸 `func` token"——`private`/`static` 前缀会让
    ///    `func` 紧邻标识符字符，token 边界在 squeeze 之后已经不存在了。
    ///
    /// 空数组 = 锚点失效，**调用方必须当场 XCTFail**，不得当成"零处、很干净"。
func functionBodies(_ code: String, funcName: String) -> [String] {
    let chars = Array(code)
    func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    let kw = Array("func ")
    var out: [String] = []
    var i = 0
    while i + kw.count <= chars.count {
        guard Array(chars[i ..< i + kw.count]) == kw else { i += 1; continue }
        if i > 0, isIdentChar(chars[i - 1]) { i += 1; continue }   // `func` 必须是独立 token
        var j = i + kw.count
        while j < chars.count, chars[j] == " " { j += 1 }
        var name = ""
        while j < chars.count, isIdentChar(chars[j]) { name.append(chars[j]); j += 1 }
        guard name == funcName else { i += 1; continue }
        while j < chars.count, chars[j] != "{" { j += 1 }          // 走到函数体开头
        guard j < chars.count else { break }
        var depth = 0, k = j, body = ""
        while k < chars.count {                                    // 大括号配对定结束
            if chars[k] == "{" { depth += 1 }
            else if chars[k] == "}" { depth -= 1; if depth == 0 { break } }
            if depth >= 1 { body.append(chars[k]) }
            k += 1
        }
        out.append(squeeze(body))
        i = k
    }
    return out
}

/// 单函数版（无重载时用）。抓不到 / 抓到多个都当场 `XCTFail` —— 返回空串会让所有
/// "必须包含"断言恒假、"不得包含"断言恒真，守卫静默失效（G-5 的锚点纪律）。
func functionBody(_ code: String, funcName: String,
                  file: StaticString = #filePath, line: UInt = #line) -> String {
    let bodies = functionBodies(code, funcName: funcName)
    guard bodies.count == 1 else {
        XCTFail("锚点失效：func \(funcName) 抓到 \(bodies.count) 个函数体（期望恰好 1）",
                file: file, line: line)
        return ""
    }
    return bodies[0]
}

final class DrawingUndoSourceGuardTests: XCTestCase {

    /// U-G1（N-S）：凡含 `drawingSession.activate(` 或 `drawingSession.deactivate(` 的函数，
    /// **必定**也含 `clearDrawingUndoStack()`。当前应命中三个函数。
    /// ⚠️ **不许**写成「只准出现在 begin/end 内」—— 那条在 `cancelDrawingAllPanels` 这行
    ///    **既有合法代码**上就是红的（spec §2.1 codex R4-F2）。
    /// ⚠️ 本守卫**拦不住**「清栈写在函数入口无条件执行」—— 那种实现照样共处、却会在早退与
    ///    冗余调用上误清。那一半由**行为测试** N-Q4 / N-Q5 兜住，**两者缺一不可**。
    func test_uG1_sessionFlipFunctionsAllClearUndoStack() throws {
        let code = try boundaryCodeOf(trainingEnginePath)      // ⚠️ 切函数体必须用保留边界的文本（R5）
        let expected = ["cancelDrawingAllPanels", "beginDrawingSession", "endDrawingSessionIfActive"]
        var hit: [String] = []
        for name in expected {
            let body = functionBody(code, funcName: name)
            XCTAssertFalse(body.isEmpty, "\(name) 函数体为空 —— 锚点失效")
            let touchesSession = body.contains(squeeze("drawingSession.activate("))
                              || body.contains(squeeze("drawingSession.deactivate("))
            XCTAssertTrue(touchesSession, "\(name) 里应当有 activate/deactivate —— 代码被挪走了，本守卫需重定位")
            XCTAssertTrue(body.contains(squeeze("clearDrawingUndoStack()")),
                          "\(name) 翻转了会话状态却没有清栈调用（N-S）")
            hit.append(name)
        }
        XCTAssertEqual(hit.count, 3)
    }

    /// U-G1 的**双向自检**：合成一段「含 deactivate 但不含清栈」的函数体必须被判出来，
    /// 合成一段「两者都含」的必须通过（防 pattern 打错字 → 恒真 → 守卫恒绿）。
    func test_uG1_scanner_is_not_vacuous() {
        let bad  = functionBodies(codeTextPreservingBoundaries(
            "private func f() { drawingSession.deactivate() }"), funcName: "f")
        let good = functionBodies(codeTextPreservingBoundaries(
            "private func f() { drawingSession.deactivate(); clearDrawingUndoStack() }"), funcName: "f")
        XCTAssertEqual(bad.count, 1, "`private func` 前缀不得让 func token 识别失败（R5 点名的坑）")
        XCTAssertTrue(bad[0].contains(squeeze("drawingSession.deactivate(")))
        XCTAssertFalse(bad[0].contains(squeeze("clearDrawingUndoStack()")), "缺清栈的样本必须被判出来")
        XCTAssertTrue(good[0].contains(squeeze("clearDrawingUndoStack()")))

        // ⭐R5 点名要的那条：要求的调用只存在于**后面另一个函数**里，绝不能被算给前一个函数。
        let leaked = functionBodies(codeTextPreservingBoundaries("""
            func a() { drawingSession.deactivate() }
            func b() { clearDrawingUndoStack() }
            """), funcName: "a")
        XCTAssertEqual(leaked.count, 1)
        XCTAssertFalse(leaked[0].contains(squeeze("clearDrawingUndoStack()")),
            "函数体切片吃到了下一个函数 —— 这正是 R5 报的缺陷（原稿用 `func ` 当边界，squeeze 后永不匹配）")

        // 嵌套大括号（闭包 / if 块）不得让配对提前收尾
        let nested = functionBodies(codeTextPreservingBoundaries(
            "func c() { if x { y() }; clearDrawingUndoStack() }"), funcName: "c")
        XCTAssertTrue(nested[0].contains(squeeze("clearDrawingUndoStack()")), "嵌套块让函数体提前截断了")

        // 锚点失效必须返回空数组（调用方据此 XCTFail），不得静默返回一个空函数体
        XCTAssertTrue(functionBodies(codeTextPreservingBoundaries("func g() {}"),
                                     funcName: "zzzNoSuchFunc").isEmpty)
    }
}

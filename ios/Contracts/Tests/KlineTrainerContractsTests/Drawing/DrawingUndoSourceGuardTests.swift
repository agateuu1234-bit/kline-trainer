// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoSourceGuardTests.swift
// Spec: 2026-08-11-...-1b-ii-lock-undo-design.md §2.6（N-S / N-N3 的守卫那半）+ 计划决策 D102/D103
//
// 本文件是 XCTest（不是 swift-testing）：与 SourceGuardScanner.swift 的既有守卫同族，
// 且 `swift test | tail -3` 那行汇总**不包含** XCTest —— 判绿必须另读
// `Executed N tests, with 0 failures`（计划 Global Constraints G-3）。
//
// 纪律（G-5，缺一即失效）：结构计数不写黑名单；匹配前剥注释剥字面量；每条配双向自检。
import XCTest
import Testing          // U-G2/U-G3（Task 3）：`expectEngineInternalOnly`/`expectIdentifierNeverVended`
                         // 的 `sourceLocation: SourceLocation = #_sourceLocation` 默认参数在**调用处**展开，
                         // 调用处（本文件）不 import Testing 就解析不到 `#_sourceLocation` 宏（编译期实测）。
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
    // ⚠️ Important-4 补 `init` 分类：Swift 初始化器**没有** `func` 关键字，锚点必须换成裸 `init`
    //    token 紧跟 `(`（中间允许空白）。两处额外排除，都是真实踩过的坑（实测 TrainingEngine.swift）：
    //    · 排除 `initialDrawings` 这类以 init 开头的更长标识符——`init` 后面紧跟标识符字符就不算；
    //    · 排除 `.init(` / `Type.init(`（隐式成员/显式构造**调用**，如默认参数值 `= .init()`）——
    //      它们不是声明，前一个字符是 `.`；若不排除，扫描器会把它当成第二条 init 声明，
    //      从那个 `(` 一路找到**下一个任意** `{`（不管是不是它的），切出一段完全不相干的"函数体"，
    //      污染 `init` 的写入计数、也会让逐函数之和对不上全文件总数。
    let isInit = (funcName == "init")
    let kw = Array(isInit ? "init" : "func ")
    var out: [String] = []
    var i = 0
    while i + kw.count <= chars.count {
        guard Array(chars[i ..< i + kw.count]) == kw else { i += 1; continue }
        if i > 0, isIdentChar(chars[i - 1]) { i += 1; continue }   // `func`/`init` 必须是独立 token
        if isInit, i > 0, chars[i - 1] == "." { i += 1; continue }        // `.init(` 调用，不是声明
        var j = i + kw.count
        if isInit {
            if j < chars.count, isIdentChar(chars[j]) { i += 1; continue }  // `initialDrawings` 这类要排除
        } else {
            var name = ""
            while j < chars.count, isIdentChar(chars[j]) { name.append(chars[j]); j += 1 }
            guard name == funcName else { i += 1; continue }
        }
        while j < chars.count, chars[j] == " " { j += 1 }
        if isInit {
            guard j < chars.count, chars[j] == "(" else { i += 1; continue }  // 必须紧跟参数列表
        }
        // ⚠️ 必须先**配对圆括号**跳过整段参数列表，再去找函数体的 `{`（实测 TrainingEngine.swift
        //    的 `init` 踩过：参数列表里有个闭包默认值 `= { onTick in RealFrameDriver(onTick: onTick) }`，
        //    这段默认值自己就带一对 `{ }`。原判据「见第一个 `{` 就当函数体开头」会在这里提前收尾，
        //    把闭包默认值那几个字符错当成整个 init 的"函数体"，真身体一个字都进不来）。
        //    只数圆括号、不理会中间任何 `{`/`}`，配对到深度回零即跳过整个参数列表。
        if j < chars.count, chars[j] == "(" {
            var pdepth = 0
            while j < chars.count {
                if chars[j] == "(" { pdepth += 1 }
                else if chars[j] == ")" { pdepth -= 1; if pdepth == 0 { j += 1; break } }
                j += 1
            }
        }
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

/// 按**具名函数**统计 `drawings` 的结构性写入处数（D79 第一层的穷尽性判据用）。
///
/// ⚠️ 入参是 **`codeTextPreservingBoundaries` 的输出**（保留空白），**不是** `squeezedSource`
///    （codex plan-R5 high，**已核实为真**）：squeeze 之后 `func ` 这个边界永远匹配不到，
///    每个先出现的函数都会把它后面所有函数的写入算到自己头上 —— 逐函数计数根本无法满足。
///    切片改由本文件的 `functionBodies` 用**大括号配对**完成（它返回的 body 已 squeeze，
///    正好是 `engineDrawingsStructuralWrites` 需要的形态）。
/// 同名重载（`deleteDrawing` 有 `(at:)` 与 `(id:)` 两个）会被**逐个**切片并累加 —— 这正是我们要的。
/// ⚠️ 找不到某个函数名 → 该键**缺席**（返回的字典里没有它），**不返回 0** ——
///    调用方的 `XCTAssertEqual(byFunc[name], want)` 会因 `nil != 某数` 而红，锚点失效因此出声。
/// ⚠️ 本函数依赖 `functionBodies`，故与它**同文件**（放 `DrawingUndoSourceGuardTests.swift`，
///    **不放** `SourceGuardScanner.swift`）—— 两个判据必须同生共死，分居两处必然漂移。
func engineDrawingsWritesByFunction(_ code: String, functions: [String]) -> [String: Int] {
    var out: [String: Int] = [:]
    for name in functions {
        let bodies = functionBodies(code, funcName: name)
        guard !bodies.isEmpty else { continue }        // 缺席 = 锚点失效，让调用方红
        out[name] = bodies.reduce(0) { $0 + engineDrawingsStructuralWrites($1) }
    }
    return out
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

    /// U-G2（D79 第三条 + D76）：`undoDrawing` / `redoDrawing` **不接受任何外部参数**，
    /// 且执行单点 `applyUndoEntry` **恰好被这两个函数各调 1 次**（共 2 次）。
    /// ⚠️ 「不接受外部参数」不是风格 —— 那个签名**本身就是信任边界**（spec §2.3 逐字）：
    ///    它保证恢复用的只能是引擎自己吐出的、已经过完整门列表的快照，所以才可以不走
    ///    D60 / D61 那些防外部坏数据的门。一旦允许传参，「撤销」就变成了一个绕过全部门的写入面。
    func test_uG2_undoRedoTakeNoExternalArgumentsAndShareOneApplySite() throws {
        let code = try squeezedSource(trainingEnginePath)
        XCTAssertTrue(code.contains(squeeze("func undoDrawing() -> Bool")), "undoDrawing 必须无参")
        XCTAssertTrue(code.contains(squeeze("func redoDrawing() -> Bool")), "redoDrawing 必须无参")
        // ⚠️ `callCount` = 总出现数 **减去** 定义处数（按 `"func"+pattern` 扣）⇒ 定义本身**不计**。
        //    故期望值是 **2**（undo / redo 各 1 处调用），不是 3。写成 3 会让本守卫恒红。
        XCTAssertEqual(callCount(inSqueezed: code, pattern: squeeze("applyUndoEntry(")), 2,
                       "应为 undo / redo 各 1 处调用 = 2（定义已被 callCount 自动扣除）；多了说明出现了第二条执行路径")
        // 两个入口都不得 public/package/open（信任边界的第二半）
        try expectEngineInternalOnly("undoDrawing()")
        try expectEngineInternalOnly("redoDrawing()")
    }

    /// U-G3：撤销栈的两个测试钩子**不得有任何生产使用**。
    ///
    /// ⚠️ **必须连 `TrainingEngine.swift` 一起扫**（codex plan-R4，**已核实为真**）：
    ///    钩子的声明**和引擎侧全部撤销实现在同一个文件里**。把整个文件过滤掉 ⇒
    ///    `undoDrawing` / `applyUndoEntry` 里真冒出一句 `injectDrawingUndoEntryForTesting(...)`
    ///    会被整段丢掉、守卫照样全绿 —— 而那种调用绕过快照与全部前置校验，能种一条**任意的**
    ///    陈旧栈项，随后删掉或改写**另一条**线（D79 要防的崩溃级 / 静默改写那一族）。
    ///    **正确判据**：引擎之外零处；`TrainingEngine.swift` 里**恰好等于"声明本身"的处数**（各 1）。
    ///    多出一处 = 引擎自己在用它。
    func test_uG3_testOnlyHooksHaveNoProductionUse() throws {
        // ── 引擎之外：两个钩子一处都不许出现 ──
        for hook in ["injectDrawingUndoEntryForTesting", "drawingUndoEntryForTesting"] {
            let outside = try filesMentioning(hook).filter { !$0.hasSuffix("/TrainingEngine.swift") }
            XCTAssertTrue(outside.isEmpty, "\(hook) 被引擎之外的生产文件提到：\(outside)")
        }
        // ── 引擎之内（R4 补上的关键那一半）──
        // 用**裸标识符**计数而不是子串计数：`injectDrawingUndoEntryForTesting` 里含的是
        // `DrawingUndoEntryForTesting`（大写 D），与属性名 `drawingUndoEntryForTesting`（小写 d）
        // 大小写不同、互不误计；属性体里的 `drawingUndoEntry` 也不会被算成它。
        // ⚠️ **两个钩子要用两种不同的判据**（实施计划自查实测 `SourceGuardScanner.swift:171-186 / 252-278`）：
        //    · `callCount` = **总出现数 − 定义处数**（定义按 `"func"+pattern` 扣）⇒ 只有声明时它是 **0**，
        //      冒出一次真调用才变 1。所以带括号的注入钩子用它，期望 **0**；
        //      **`callSiteCount` 对每个文件跑的就是它**，因此**根本不需要**把 `TrainingEngine.swift`
        //      过滤掉 —— 当初那个过滤才是 codex plan-R4 报的盲区本身。
        //    · `bareIdentifierReferences` 第 ③ 条明写「后面第一个非空格字符是 `(` 就不算」⇒ 它数的是
        //      **vend**（把方法当值传出去），声明与调用都不计。无括号的那个计算属性只能用它。
        //    两条判据搞反 = 守卫恒真、永远抓不到非法调用（本计划自查实测踩过一次）。
        let injCalls = try callSiteCount("injectDrawingUndoEntryForTesting(")
        XCTAssertTrue(injCalls.isEmpty,
            "注入钩子被生产代码调用了：\(injCalls)。它绕过快照与全部前置校验，能种一条**任意**陈旧栈项去删改另一条线。")
        // 第二层：vend 形式不出现调用 pattern，只数调用会放过它。
        try expectIdentifierNeverVended("injectDrawingUndoEntryForTesting",
                                        inFiles: try filesMentioning("injectDrawingUndoEntryForTesting"))
        // 只读钩子（计算属性，无括号）：引擎之内恰好 1 处 = 那行声明；多出来就是引擎自己在读它。
        XCTAssertEqual(bareIdentifierReferences(inCode: try boundaryCodeOf(trainingEnginePath),
                                                identifier: "drawingUndoEntryForTesting"), 1,
            "应恰好 1 处 = 那个只读计算属性的声明（它无括号，声明本身就算一次裸引用）。")
    }

    /// U-G3 的**反向自检**（codex plan-R4 点名要的）：合成一段「同文件里的生产调用」，
    /// 判据必须数到 2（声明 + 那次非法调用）—— 这正是修正前那版守卫的盲区。
    func test_uG3_scanner_catches_same_file_production_call() {
        let illicit = squeezedText("""
            func undoDrawing() -> Bool { injectDrawingUndoEntryForTesting(nil); return false }
            func injectDrawingUndoEntryForTesting(_ e: DrawingUndoEntry?) { drawingUndoEntry = e }
            """)
        XCTAssertEqual(callCount(inSqueezed: illicit,
                                 pattern: squeeze("injectDrawingUndoEntryForTesting(")), 1,
            "callCount 会**自动扣掉声明**那一处 ⇒ 剩下的 1 就是那次非法调用。数成 0 = 判据坏了或又把整个文件过滤掉了。")
        let clean = squeezedText("""
            func injectDrawingUndoEntryForTesting(_ e: DrawingUndoEntry?) { drawingUndoEntry = e }
            """)
        XCTAssertEqual(callCount(inSqueezed: clean,
                                 pattern: squeeze("injectDrawingUndoEntryForTesting(")), 0,
            "只有声明的样本必须数成 0（声明被自动扣掉）—— 数成 1 说明扣除逻辑的理解又反了")
        // 第二层各管一半：vend 形式不出现调用 pattern，只能靠裸引用判据抓
        let vended = codeTextPreservingBoundaries("func f() { let g = injectDrawingUndoEntryForTesting }")
        XCTAssertEqual(callCount(inSqueezed: squeeze(vended),
                                 pattern: squeeze("injectDrawingUndoEntryForTesting(")), 0,
            "vend 形式没有括号 → 调用计数抓不到它，这正是需要第二层的理由")
        XCTAssertEqual(bareIdentifierReferences(inCode: vended,
                                                identifier: "injectDrawingUndoEntryForTesting"), 1,
            "裸引用判据必须抓到 vend")
    }

    /// U-G2 / U-G3 的**双向自检**。
    func test_uG2_uG3_scanners_are_not_vacuous() throws {
        XCTAssertEqual(callCount(inSqueezed: squeezedText("applyUndoEntry(x)"), pattern: squeeze("applyUndoEntry(")), 1)
        XCTAssertEqual(callCount(inSqueezed: squeezedText("nothing here"), pattern: squeeze("applyUndoEntry(")), 0)
        XCTAssertTrue(try callSiteCount("injectDrawingUndoEntryForTestingZZZ(").isEmpty)
    }

    /// U-G4（D79 第一层，**穷尽性判据**）：`TrainingEngine.swift` 里 `drawings` 的结构性写入点，
    /// **全部**落在下表这 7 个具名函数里，且每个函数的处数与表一致；表外**零处**。
    ///
    /// ⚠️ 这条比既有 L12b（只数总数）强一档：总数对不上会红，但「把一处写入从 appendDrawing
    ///    挪到一个新的私有 helper 里」总数不变、L12b 全绿，而那个 helper 就是一条**没对栈表过态**
    ///    的新写入面。本条按**判据本身**穷尽（每处写入必须归属于表里某个函数），不是按这次
    ///    报告到的点位改。
    ///
    /// ⚠️ 作用域**只是 `TrainingEngine.swift`**，不是全 `Sources/` 的同名变量：
    ///    `drawings` 是 `public private(set)`，setter 是**文件作用域**，别的文件根本写不了它。
    func test_uG4_engineDrawingsWriteSitesAreExhaustivelyClassified() throws {
        let code = try boundaryCodeOf(trainingEnginePath)        // ⚠️ 切函数体用保留边界的文本（R5）
        let squeezed = try squeezedSource(trainingEnginePath)  // 全文件总数仍用 squeezed
        let expected: [String: Int] = [
            "deleteDrawing":           2,   // (at index:) 1 处 + (id:) 1 处 —— 两个重载同名，合并计数
            "appendDrawing":           1,
            "updateDrawingStyle":      1,
            "setDrawingLocked":        1,
            "applyUndoEntry":          3,   // remove + insert + 下标赋值
            // 整支终审②（Important-4）：整体赋值 `drawings = <表达式>` 现已计入结构性写入
            // （旧注释「不计入结构性写入」是本次要修的缺陷本身，不是既有事实）。
            "init":                     1,  // `self.drawings = seededLossy.drawings`（resume 重新种子）
            "injectDrawingsForTesting": 1,  // `drawings = ds`（测试专用换血口，同时是 U-N3a 的靶子）
        ]
        let byFunc = engineDrawingsWritesByFunction(code, functions: Array(expected.keys))
        for (name, want) in expected {
            XCTAssertEqual(byFunc[name], want,
                           "\(name) 的结构性写入处数应为 \(want)，实测 \(byFunc[name].map(String.init) ?? "锚点失效")")
        }
        // 表外零处：逐函数之和 == 全文件总数
        let total = engineDrawingsStructuralWrites(squeezed)
        XCTAssertEqual(byFunc.values.reduce(0, +), total,
                       """
                       有 \(total - byFunc.values.reduce(0, +)) 处 drawings 写入不在权威分类表里。
                       新增写入面必须先归入 D79 第一层那张表（入栈 / 作废 / 都不做，三选一），
                       再回来改本守卫 —— 不许直接改数字。
                       """)
        XCTAssertEqual(total, 10, "权威分类表的合计是 10（见计划 Task 4 那张表 + 整支终审②补的整体赋值 2 处）")
    }

    /// U-G4 的**双向自检**：合成一段「写入落在表外函数里」的样本必须被判出来。
    func test_uG4_scanner_is_not_vacuous() {
        let good = codeTextPreservingBoundaries("func appendDrawing() { drawings.append(x) }")
        XCTAssertEqual(engineDrawingsWritesByFunction(good, functions: ["appendDrawing"])["appendDrawing"], 1)

        // ⭐R5 点名要的那条：写入只存在于**后面另一个函数**里，绝不能被算给前一个函数。
        let leaked = codeTextPreservingBoundaries("""
            func appendDrawing() { }
            private func sneakyHelper() { drawings.append(x) }
            """)
        XCTAssertEqual(engineDrawingsWritesByFunction(leaked, functions: ["appendDrawing"])["appendDrawing"], 0,
            "切片吃到了下一个函数 —— 这正是 codex plan-R5 报的缺陷（原稿用 `func ` 当边界，squeeze 后永不匹配）")
        XCTAssertEqual(engineDrawingsStructuralWrites(squeeze(leaked)), 1,
            "全文件总数仍是 1 → 逐函数之和 0 ≠ 1，穷尽性断言会红（表外写入因此暴露）")

        // 同名重载必须**各切各的、累加**（`deleteDrawing` 就是两个重载）
        let overloads = codeTextPreservingBoundaries("""
            func deleteDrawing(at i: Int) { drawings.remove(at: i) }
            func deleteDrawing(id x: String) { drawings.remove(at: 0) }
            """)
        XCTAssertEqual(engineDrawingsWritesByFunction(overloads, functions: ["deleteDrawing"])["deleteDrawing"], 2)

        XCTAssertNil(engineDrawingsWritesByFunction(good, functions: ["noSuchFunc"])["noSuchFunc"],
                     "锚点失效必须返回 nil（缺键），不得静默返回 0")
    }

    /// U-G4 的 `init` 分类双向自检（整支终审②/Important-4）：`init` 没有 `func` 关键字，
    /// 锚点换成裸 `init(`；必须排除 `.init(` 调用与 `initialFoo` 这类更长标识符，否则会把
    /// 一段完全不相干的"函数体"错当成 init 的写入面（详见 `functionBodies` 里的承重注释）。
    func test_uG4_initClassification_isNotVacuous() {
        let real = codeTextPreservingBoundaries("""
            init(flow: X, initialPosition: PositionManager = .init()) {
                self.drawings = seededLossy.drawings
            }
            """)
        XCTAssertEqual(engineDrawingsWritesByFunction(real, functions: ["init"])["init"], 1,
            "真实 init 的整体赋值必须被数到，`.init()` 默认值与 `initialPosition` 参数名不得干扰锚点")

        // 只有 `.init(` 调用、没有真实声明 → `init` 这个键必须锚点失效（缺席），不能凭空数出内容。
        let onlyCall = codeTextPreservingBoundaries("""
            func make() -> PositionManager {
                let p: PositionManager = .init()
                return p
            }
            """)
        XCTAssertNil(engineDrawingsWritesByFunction(onlyCall, functions: ["init"])["init"],
            "`.init(` 是调用不是声明，不得被误判成 init 函数体（否则会把 `make()` 的内容错记到 init 头上）")
    }

    /// U-G5（D102）：`performDrawingAction` 在 `Sources/` 中的调用点**恰好 1 处**，且在
    /// `DrawingEditRouter.applyPanelStyleMutation` 里；作用域必须包住**整个**函数体
    /// （`performDrawingAction {` 紧跟在函数签名之后）。
    /// ⚠️ 只数调用点不够：把作用域只包住 `.draw` 那一个分支，调用点仍是 1 处、成对回滚的测试也照样绿，
    ///    但选择态那一支就落在作用域之外 —— 将来任何人给选择态补上「顺带写默认」的语义时，
    ///    那一对会静默拆成两条记录。故必须**同时**断言"紧跟在签名之后"。
    func test_uG5_actionScopeWrapsWholePanelStyleMutation() throws {
        // ⚠️ 不能用 `callSiteCount("performDrawingAction(")` —— 它数的是带括号的 pattern，
        //    而本函数的调用点是**尾随闭包**语法 `engine.performDrawingAction { … }`，源码里
        //    根本不出现 `(` ⇒ 那条判据恒为 0，与下面第三句「调用点必须正是无括号写法」互斥。
        //    改用裸标识符判据（同 U-G3 对无括号计算属性的处理）：它对**定义**不计数
        //    （`func performDrawingAction(` 后面是 `(`），恰好只数尾随闭包调用。
        var sites: [(file: String, count: Int)] = []
        for f in try filesMentioning("performDrawingAction") {
            let n = bareIdentifierReferences(inCode: try boundaryCodeOf(f),
                                             identifier: "performDrawingAction")
            if n > 0 { sites.append((f, n)) }
        }
        let total = sites.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, 1, "performDrawingAction 调用点应恰好 1 处，实测：\(sites)")
        XCTAssertEqual(sites.first?.file.hasSuffix("/Drawing/DrawingEditRouter.swift"), true,
                       "唯一调用点必须在路由里")

        let router = try squeezedSource(contractsDirForGuards
            .appendingPathComponent("Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift").path)
        let sig = squeeze("engine: TrainingEngine) { engine.performDrawingAction {")
        XCTAssertTrue(router.contains(sig),
                      "作用域必须紧跟 applyPanelStyleMutation 的签名、包住整个函数体（不是只包 .draw 分支）")
    }

    /// U-G5 的**双向自检**。
    func test_uG5_scanner_is_not_vacuous() throws {
        XCTAssertEqual(bareIdentifierReferences(
            inCode: codeTextPreservingBoundaries("f { engine.performDrawingAction { } }"),
            identifier: "performDrawingAction"), 1, "尾随闭包调用必须被判成裸引用")
        XCTAssertEqual(bareIdentifierReferences(
            inCode: codeTextPreservingBoundaries("func performDrawingAction(_ b: () -> Void) { }"),
            identifier: "performDrawingAction"), 0, "定义本身（后面紧跟 `(`）不得被误计成调用点")

        let onlyDrawBranch = squeezedText("""
            static func applyPanelStyleMutation(_ m: X, engine: TrainingEngine) {
                if session.mode == .draw { engine.performDrawingAction { } }
            }
            """)
        XCTAssertFalse(onlyDrawBranch.contains(squeeze("engine: TrainingEngine) { engine.performDrawingAction {")),
                       "只包住 .draw 分支的样本必须不满足邻接条件")
    }

    /// U-G6（D77，codex R5-F2）：`undoDrawing(` / `redoDrawing(` 在 `Sources/` 中的调用点
    /// **各恰好 1 处**、都在 `DrawingEditRouter.swift`。
    /// ⚠️ 底栏的 ↩ / ↪ 如果被**直接**接到 `engine.undoDrawing()` 上，引擎侧的往返测试照样全绿，
    ///    可选中态永远不同步 —— 撤销掉的正好是选中那条线时，`selectedDrawingID` 变成一个指向
    ///    已不存在的线的死值：高亮没了、🔒/🗑 灰着、要等用户再点一下别处才恢复。
    func test_uG6_undoRedoHaveExactlyOneRouterCallSiteEach() throws {
        // ⚠️ **不要过滤掉 `TrainingEngine.swift`**（与 codex plan-R4 报的是同一类盲区）：
        //    `callSiteCount` 内部用的 `callCount` 已经把「定义」那一处自动扣掉了，引擎文件本来就
        //    不会因为"声明在那儿"而出现在结果里；一旦过滤，引擎自己**真的调了** undo/redo
        //    （绕过路由 ⇒ 选中态永远不同步）反而看不见。
        for name in ["undoDrawing(", "redoDrawing("] {
            let sites = try callSiteCount(name)
            let total = sites.reduce(0) { $0 + $1.count }
            XCTAssertEqual(total, 1, "\(name) 应恰好 1 个调用点，实测：\(sites)")
            XCTAssertEqual(sites.first?.file.hasSuffix("/Drawing/DrawingEditRouter.swift"), true,
                           "\(name) 的唯一调用点必须是路由（选中态同步只在那里）—— 落在引擎里就是绕过了路由")
        }
    }

    /// U-G7（D77）：路由的 `undo` / `redo` 必须带 `defer { syncSelectionByState(engine: engine) }`，
    /// 且**不得**出现 `commitPendingAndSelect`（交接 §10.1 第 2 条：恢复回来的线不自动选中）。
    func test_uG7_routerUndoRedoSyncSelectionAndNeverAutoSelect() throws {
        let router = try boundaryCodeOf(contractsDirForGuards
            .appendingPathComponent("Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift").path)
        // ⚠️ `functionBody` 内部会自己拼上 `(`（needle = `func <name>(`），
        //    所以这里**只能传裸函数名** —— 传 "undo(engine" 会拼成 `func undo(engine(`，
        //    永远匹配不到 ⇒ 走 XCTFail 的锚点失效分支（幸好它会出声，不是静默恒绿）。
        for fn in ["undo", "redo"] {
            let body = functionBody(router, funcName: fn)
            XCTAssertFalse(body.isEmpty, "锚点失效：找不到路由的 \(fn)(engine:)")
            XCTAssertTrue(body.contains(squeeze("defer { syncSelectionByState(engine: engine) }")),
                          "\(fn) 缺少选中态同步 —— D77 的四行全靠它")
            XCTAssertFalse(body.contains(squeeze("commitPendingAndSelect(")),
                           "\(fn) 不得复用 commitPendingAndSelect（交接 §10.1 明令）")
            XCTAssertFalse(body.contains(squeeze("setCommittedSelection(")),
                           "\(fn) 不得建立选中 —— 恢复回来的线不自动选中")
        }
    }

    /// U-G6 / U-G7 的**双向自检**。
    func test_uG6_uG7_scanners_are_not_vacuous() throws {
        XCTAssertTrue(try callSiteCount("undoDrawingZZZ(").isEmpty)
        let bad = squeezedText("static func undo(engine: TrainingEngine) -> Bool { engine.undoDrawing() }")
        XCTAssertFalse(bad.contains(squeeze("defer { syncSelectionByState(engine: engine) }")),
                       "缺 defer 的样本必须被判出来")
    }
}

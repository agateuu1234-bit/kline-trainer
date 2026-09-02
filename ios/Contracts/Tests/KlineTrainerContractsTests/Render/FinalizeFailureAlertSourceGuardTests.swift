// Tests/KlineTrainerContractsTests/Render/FinalizeFailureAlertSourceGuardTests.swift
// Q13：「结算入账失败」弹窗的文案与「放弃」的实际行为相反 —— 文案说「进度保留至最近存档」，
// 而该按钮走 discardSession() → pendingRepo.clearPending()，**永久删除整局 pending**。
// 且它缺少非破坏性出口：重试撞同一道门必然再失败，用户只剩一个会删数据的按钮。
//
// ⚠️ 同一文件里紧挨着的另外两个弹窗**已经是正确做法**，本守卫要求这个落单的弹窗与它们一致：
//   · 「结算失败」（replay）：出口是「退出本局」→ lifecycle.back()（saveProgress + endSession，不清 pending）
//   · 「保存进度失败」：破坏性按钮标了 role: .destructive（iOS 才会渲染成红色）
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("Q13 结算入账失败弹窗：非破坏性出口 / 破坏性标注 / 文案属实")
struct FinalizeFailureAlertSourceGuardTests {

    private var srcDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 原始源码（`code` 的输入）。
    private func rawSource(_ rel: String) throws -> String {
        try String(contentsOf: srcDir.appendingPathComponent(rel), encoding: .utf8)
    }

    /// 源码 → **剥注释（含嵌套块注释）、保留字符串字面量内容、删光空白**。
    ///
    /// ⚠️ **为什么不能直接用仓库现成的 `squeezedText()`**（`SourceGuardScanner.swift`）：
    ///    那份扫描器会把**字符串字面量的内容整段丢弃**（它的头注逐字写明，为的是免掉
    ///    「字面量里的 `deleteDrawing(id:` 被当成调用」这类假阳性）。而本文件要断言的**恰恰是
    ///    用户可见文案与按钮名字** —— 它们全住在字面量里，一丢就什么都测不到了（实测：
    ///    `.alert("结算入账失败"` 会被压成 `.alert(""`，所有断言当场失去意义）。
    ///    ⇒ 两者需求正交，不是「同一件事的两份实现」：那份剥字面量，这份**必须留住字面量**。
    /// ⚠️ 但它剥注释的能力必须够 —— 上一稿是逐行 `range(of: "//")` 截断，**不认块注释**，
    ///    且字面量里的 `//`（如 URL）会把同一行后面的真代码吞掉。本实现是个小状态机，两者都处理。
    private func code(_ rel: String) throws -> String {
        let raw = Array(try rawSource(rel))
        var out = ""
        var i = 0
        while i < raw.count {
            // 块注释（可嵌套）
            if raw[i] == "/", i + 1 < raw.count, raw[i + 1] == "*" {
                var depth = 1; i += 2
                while i < raw.count, depth > 0 {
                    if raw[i] == "/", i + 1 < raw.count, raw[i + 1] == "*" { depth += 1; i += 2 }
                    else if raw[i] == "*", i + 1 < raw.count, raw[i + 1] == "/" { depth -= 1; i += 2 }
                    else { i += 1 }
                }
                continue
            }
            // 行注释
            if raw[i] == "/", i + 1 < raw.count, raw[i + 1] == "/" {
                while i < raw.count, raw[i] != "\n" { i += 1 }
                continue
            }
            // 字符串字面量：**原样保留**（含内容），且里面的 `//` 不当注释
            if raw[i] == "\"" {
                out.append(raw[i]); i += 1
                while i < raw.count {
                    if raw[i] == "\\", i + 1 < raw.count { out.append(raw[i]); out.append(raw[i + 1]); i += 2; continue }
                    out.append(raw[i])
                    if raw[i] == "\"" { i += 1; break }
                    i += 1
                }
                continue
            }
            if !raw[i].isWhitespace { out.append(raw[i]) }
            i += 1
        }
        return out
    }

    /// needle 也删光空白，使匹配与排版无关（`do { x }` 与 `do{x}` 等价）。
    /// ⚠️ 字面量里的空格会被一并删掉，故断言里的中文文案**不要带空格**。
    private func sq(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined()
    }

    private let tv = "Sources/KlineTrainerContracts/UI/TrainingView.swift"

    /// 只取「结算入账失败」这一个弹窗的源码块：从它的 `.alert(` 起，到**下一个** `.alert(` 之前。
    /// 不限定范围的话，断言会被同文件里另外三个弹窗的内容蒙混过去。
    ///
    /// ⚠️ **本块会连带圈进下一个弹窗的「前置注释」**（注释写在 `.alert(` 之上，边界切不掉它）。
    ///    实测踩过：replay 弹窗上方的注释里引用了它自己的文案「…可在历史记录返回训练」，
    ///    害本文件的文案断言误报。⇒ **所有断言一律喂剥掉注释的文本**（`source`）；
    ///    字符串字面量**不剥**，故用户可见文案照样测得到。
    private func finalizeAlertBlock(_ text: String) throws -> String {
        let start = try #require(text.range(of: ".alert(\"结算入账失败\""),
                                 "锚点失效：找不到「结算入账失败」弹窗（文件被改名或标题被改？）")
        let rest = text[start.upperBound...]
        guard let next = rest.range(of: ".alert(") else { return String(rest) }
        return String(rest[..<next.lowerBound])
    }

    /// 按标题取任一弹窗块（同 `finalizeAlertBlock` 的切法）。
    private func alertBlock(_ text: String, titled title: String) throws -> String {
        let start = try #require(text.range(of: ".alert(\"\(title)\""),
                                 "锚点失效：找不到「\(title)」弹窗")
        let rest = text[start.upperBound...]
        guard let next = rest.range(of: ".alert(") else { return String(rest) }
        return String(rest[..<next.lowerBound])
    }

    // MARK: - codex R6-high：放弃失败后不得跨语境回弹

    @Test("⭐⭐两处「放弃」失败必须各自记下**自己的**来源，⛔ 不得共用一个丢掉来源的 Bool")
    func discardFailureRecordsItsOrigin() throws {
        let code = try code(tv)
        #expect(code.contains(sq("discardFailedFrom = .settlementFailure")),
                "「结算入账失败」弹窗的放弃失败必须记来源")
        #expect(code.contains(sq("discardFailedFrom = .saveProgressFailure")),
                "「保存进度失败」弹窗的放弃失败必须记**它自己**的来源")
        #expect(!code.contains(sq("@State private var discardFailed = false")),
                "⛔ 退回成无来源的 Bool = 重新打开 R6-high 那个洞（未完局被入账）")
    }

    @Test("⭐⭐「放弃未完成」关掉后按来源回弹，⛔ 不得一律送回结算弹窗")
    func discardFailedAlertRestoresByOrigin() throws {
        let block = try alertBlock(try code(tv), titled: "放弃未完成")
        #expect(block.contains(sq("alertToRestore")),
                "必须走 alertToRestore 决定回哪个弹窗")
        #expect(block.contains(sq("backFailed")),
                "⛔ 缺这一支就是 R6-high：训练中途返回的用户被送进结算弹窗，「重试」直接 finalizeForSettlement() 把没打完的局入账")
        #expect(block.contains(sq("finalizeFailed")),
                "结算那一支也必须在（否则终局用户失去重试入口）")
    }

    @Test("锚点有效 + 恰好三个出口（重试 / 退出本局 / 放弃本局）")
    func anchorAndButtonCount() throws {
        let code = try code(tv)
        // 反向自检：先证明真的读到了这个弹窗，防「路径写错 → 零命中 → 恒过」
        #expect(code.contains(".alert(\"结算入账失败\""), "锚点失效：扫不到该弹窗")

        let block = try finalizeAlertBlock(code)
        #expect(block.contains(sq("Button(\"重试\")")), "重试按钮不见了")
        #expect(block.components(separatedBy: sq("Button(")).count - 1 == 3,
                "该弹窗应恰好三个按钮：重试 / 退出本局 / 放弃本局")
    }

    @Test("必须有非破坏性出口，且该出口**不依赖正在坏掉的存储层**（codex R1-high）")
    func nonDestructiveExitExists() throws {
        let block = try finalizeAlertBlock(try code(tv))
        #expect(block.contains(sq("Button(\"退出本局\"")), "缺少非破坏性出口 —— 用户只剩会删数据的按钮")
        // ⛔ 不得是 `lifecycle.back()`：它必须 saveProgress **成功**才 endSession，而本弹窗最现实的
        //    触发原因正是写盘失败 ⇒ 那条出口在最需要它的时候恰好也坏了（codex R1-high）。
        #expect(block.contains(sq("lifecycle.exitPreservingProgress()")),
                "退出本局必须走 exitPreservingProgress()（落盘失败也照样安全退出）")
        #expect(!block.contains(sq("lifecycle.back()")),
                "⛔ back() 依赖写盘成功，不能当作失败场景下的安全出口")
    }

    @Test("退出本局必须**分三态处置**，且『保不住』那一态⛔不得离开本局（codex R2-high）")
    func exitHandlesAllThreeOutcomes() throws {
        let block = try finalizeAlertBlock(try code(tv))
        // 必须真的分支处理，而不是拿到结果就丢掉
        #expect(block.contains(sq("case .savedCurrentState, .keptEarlierCheckpoint:")),
                "保住了东西的两态才允许 onExit()")
        #expect(block.contains(sq("case .cannotPreserve(")),
                "必须显式处理『什么都没保住』这一态（并把原因解构出来）")
        // ⛔ 核心：`.cannotPreserve` 表示会话**没有被结束**；此刻 onExit() 会把用户带走，
        //    而整局只剩内存里那一份 —— 等于亲手丢掉它。
        let tail = try #require(block.range(of: sq("case .cannotPreserve(")))
        let afterCannotPreserve = String(block[tail.upperBound...].prefix(120))
        #expect(!afterCannotPreserve.contains(sq("onExit()")),
                "⛔ 保不住任何东西时绝不能 onExit() —— 那正是本条要防的丢失")
    }

    @Test("放弃本局必须**成功才离开**，⛔ 不得吞掉错误就回首页（codex R2-medium）")
    func discardExitsOnlyOnSuccess() throws {
        let block = try finalizeAlertBlock(try code(tv))
        #expect(block.contains(sq("do { try await lifecycle.discard(); onExit() }")),
                "必须 do/catch：discardSession() 是故意在清槽失败时先抛错、不结束会话")
        #expect(!block.contains(sq("try? await lifecycle.discard()")),
                "⛔ try? 会造成『界面回了首页、会话还活着、pending 也还在』而用户被告知已丢弃")
    }

    @Test("破坏性按钮必须标 role: .destructive，且仍真的弃局")
    func destructiveButtonIsMarked() throws {
        let block = try finalizeAlertBlock(try code(tv))
        #expect(block.contains(sq("Button(\"放弃本局\", role: .destructive)")),
                "放弃必须标为破坏性（iOS 据此渲染成红色）——原来标的是 .cancel")
        // 反向对照：别为了「安全」把弃局做成不弃局 —— 用户确实想扔时得能扔干净
        #expect(block.contains(sq("lifecycle.discard()")), "放弃本局仍必须真的弃局")
    }

    @Test("⛔ 全仓判据：`body` 里**任何地方**都不许吞错弃局（不限于某一个弹窗）")
    func noSwallowedDiscardAnywhere() throws {
        // ⚠️ 上一稿把这条否定断言限定在「结算入账失败」那一个弹窗块内，结果同文件 100 行外
        //    「保存进度失败」弹窗里那句逐字相同的 `try?` 完全没被看见（Opus 评审 R1 实证）。
        //    这条判据要钉的是「**全仓不许出现吞错弃局**」，不是「这一个弹窗里不许」。
        let code = try code(tv)
        #expect(code.contains(sq("lifecycle.discard()")), "反向自检：文件里确实有弃局调用")
        #expect(!code.contains(sq("try? await lifecycle.discard()")),
                "⛔ 吞掉弃局的错误再 onExit() ⇒ 界面回首页、协调器里会话还活着、pending 也还在，而用户被告知已丢弃")
    }

    @Test("两个新弹窗必须真的接在 body 上，且回弹都放到下一个 MainActor 轮次")
    func recoveryAlertsAreWired() throws {
        // ⚠️ 上一稿六条守卫的扫描范围止于「下一个 .alert(」，两个新弹窗恰好落在边界之外
        //    ⇒ 把它们整段删掉，13 条测试照样全绿（变异实证）。本条改扫整个文件。
        let code = try code(tv)
        #expect(code.contains(sq(".alert(\"暂时退不出本局\", isPresented: $cannotPreserveOnExit)")),
                "「暂时退不出本局」没接在 body 上 —— 那条路会变成「点了没反应」")
        // 「放弃未完成」改用**承载来源**的可选态（codex R6-high）⇒ 走 Binding(get:set:)，
        // 与同文件既有的 reviewFailedAction 先例一致。
        #expect(code.contains(sq(".alert(\"放弃未完成\", isPresented: Binding(")),
                "「放弃未完成」没接在 body 上 —— 那条路会变成「点了没反应」")
        // 「知道了」必须把结算弹窗弹回来：否则用户回到训练页、屏幕上什么都没有，
        // 而 didFinalize 已置位 ⇒ maybeAutoEnd 不再触发 ⇒ 结算弹窗**永远回不来**。
        // ⚠️ 回弹必须放到**下一个 MainActor 轮次**（Opus 对抗评审，low）：
        //    同文件既有的重弹先例（backFailed / replaySettlementFailed）都是在 Task 的后续轮次里置位；
        //    而「在一个 alert 正被关闭的同一次刷新里，把另一个挂在同一视图上的 alert 置 true」
        //    有被 SwiftUI 吞掉的风险。一旦被吞：会话还活着（.cannotPreserve 刻意没结束它），
        //    但 didFinalize 已置位 ⇒ maybeAutoEnd 不再触发 ⇒ **结算弹窗永远回不来**。
        // ⚠️ 判据钉的是**下一轮 MainActor**这条性质本身，不是某一句字面写法 ——
        //    上一稿把「两处都置 finalizeFailed」写死进守卫，于是 R6-high 修复一到，
        //    这条守卫反过来要求我把那个洞留着（陈旧的门会把缺陷固化成预期行为）。
        for title in ["暂时退不出本局", "放弃未完成"] {
            let block = try alertBlock(code, titled: title)
            #expect(block.contains(sq("Task { @MainActor in")),
                    "「\(title)」的「知道了」必须在下一轮 MainActor 里回弹，否则可能被 SwiftUI 吞掉")
        }
    }

    @Test("『保不住』的三种原因必须分别给出诚实文案，⛔ 不得把原因写死成其中一种")
    func cannotPreserveCopyDistinguishesReasons() throws {
        let code = try code(tv)
        // ⚠️ hasDurablePendingCheckpoint 返回 false 有三个原因：①没有 pending ②pending 属于别的会话
        //    ③pending 在、是本局的，但训练组文件被缓存淘汰了。上一稿把三者压成同一句话，
        //    而那句话把原因写死成①（「本局还没有过任何自动存档」）——在③里那是**假的**，
        //    且随附建议「清理存储空间」对③**无效**（文件已删，腾空间也回不来）。
        // 判据不是「删掉那句话」，而是「**按原因分支**」：
        #expect(code.contains(sq("case .cannotPreserve(let")),
                "必须把原因解构出来消费掉 —— 否则文案不可能分得开")
        #expect(code.contains(sq("还没有过任何自动存档")),
                "①『本局一次都没存成』那一支的文案仍应存在（对它而言那是真话）")
        #expect(code.contains(sq("训练组数据文件")),
                "③『文件被淘汰』那一支必须如实说明是数据文件没了，⛔ 不得复用①那句假话")
        #expect(code.contains(sq("存档读取失败")),
                "④『存档读不出来』（数据库损坏 / IO）也必须有自己的说法 —— 报成①会让用户做无效补救")
        // ⛔ ③ 那一支不得建议「清理存储空间」——文件已被删除，腾出空间也回不来。
        // ⚠️ 范围必须切到**那一条字面量自己的收尾引号**为止：上一稿取「附近 160 字符」，
        //    会串进紧邻的①那一支（它本来就该有这条建议）⇒ 假阳性。
        let hit = try #require(code.range(of: sq("训练组数据文件")))
        let rest = code[hit.upperBound...]
        let endQuote = try #require(rest.firstIndex(of: "\""), "找不到该文案的收尾引号（锚点失效）")
        let missingBranchCopy = String(rest[..<endQuote])
        #expect(!missingBranchCopy.contains(sq("清理设备存储空间")),
                "⛔ 对『文件已被清理』那一支，建议清理存储空间是无效建议")
        // ④ 同理：存档读不出来时，清存储也解决不了
        let hit4 = try #require(code.range(of: sq("存档读取失败")))
        let rest4 = code[hit4.upperBound...]
        let end4 = try #require(rest4.firstIndex(of: "\""), "找不到该文案的收尾引号（锚点失效）")
        #expect(!String(rest4[..<end4]).contains(sq("清理设备存储空间")),
                "⛔ 对『存档读不出来』那一支，建议清理存储空间同样无效")
    }

    @Test("文案必须属实：不含旧假话、指对回去的地方、并说清「最坏保留到哪」")
    func alertCopyIsTruthful() throws {
        // ⚠️ 用 source（剥注释、**保留字符串字面量**）：文案住在 `Text("…")` 里，剥注释不影响它；
        //    而不剥注释会把下一个弹窗的前置注释圈进来造成误报（见 finalizeAlertBlock 头注）。
        let block = try finalizeAlertBlock(try code(tv))
        #expect(!block.contains("进度保留至最近存档"),
                "这句与「放弃」实际清空整局 pending 的行为相反 —— 会诱导用户放心点下破坏性动作")
        // 指路必须对（codex R1-medium）：正常局的 pending **不是**历史记录行（历史记录里放的是
        // 已入账的 TrainingRecord），它从首页那个主按钮回去 —— `HomeContent.swift:59`
        // 逐字：`hasPending ? "继续训练" : "开始训练"`。照抄 replay 弹窗的「历史记录」是错的：
        // replay 绑在一条已入账记录上，正常局的 pending 还没入账。
        #expect(!block.contains("历史记录返回训练"),
                "⛔ 指错地方：正常局的 pending 不在历史记录里，用户会以为进度丢了")
        #expect(block.contains("首页"), "必须指明回去的地方是首页")
        #expect(block.contains("继续训练"), "必须点名首页那个按钮的实际文字")
        // 诚实的下限：落盘失败时保留的是最近一次自动存档，不能笼统说「进度保留」
        #expect(block.contains("最近一次自动存档"), "必须说清最坏情况保留到哪一档")
        #expect(block.contains("丢弃"), "必须明示「放弃本局」会丢弃本局进度")
    }
}

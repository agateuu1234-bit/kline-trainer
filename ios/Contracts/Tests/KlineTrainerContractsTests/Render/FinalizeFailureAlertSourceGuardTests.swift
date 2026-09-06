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

    @Test("⭐⭐两处来源与两支回弹的**配对方向**必须钉死，⛔ 只钉『名字在不在』挡不住互换")
    func originAndRestoreDirectionsArePinned() throws {
        // Kimi R3-medium 实测：把两处赋值与两支回弹**同时互换**，R6-high 的洞原样回来，
        // 而当时的 26 条测试全绿 —— 因为两条守卫都只是 `contains(名字)` 的存在性断言，
        // 互换之后两个名字仍然都在文件里、都在弹窗块里。
        let code = try code(tv)

        // ① 赋值方向：各自只能出现在**自己那个**弹窗块里
        for (title, mine, other) in [("结算入账失败", "settlementFailure", "saveProgressFailure"),
                                     ("保存进度失败", "saveProgressFailure", "settlementFailure")] {
            let block = try alertBlock(code, titled: title)
            #expect(block.contains(sq("discardFailedFrom = .\(mine)")),
                    "「\(title)」的放弃失败必须记 .\(mine)")
            #expect(!block.contains(sq("discardFailedFrom = .\(other)")),
                    "⛔ 「\(title)」里出现 .\(other) = 来源记反，用户会被送去另一个弹窗")
        }

        // ② 回弹方向：case 与它置位的状态必须**紧邻成对**
        let restore = try alertBlock(code, titled: "放弃未完成")
        #expect(restore.contains(sq("case .settlementFailure: finalizeFailed = true")),
                "结算那一支必须弹回结算弹窗")
        #expect(restore.contains(sq("case .saveProgressFailure: backFailed = true")),
                "⛔ 返回那一支必须弹回「保存进度失败」—— 落到结算弹窗就是 R6-high")
    }

    @Test("⭐⭐来源必须在 Task **之外**捕获，⛔ Task 里再读就是读一个已被清空的值")
    func originIsCapturedBeforeTheDeferredHop() throws {
        let block = try alertBlock(try code(tv), titled: "放弃未完成")
        // 本弹窗的 isPresented 是个 Binding：关闭时它的 set 会把 discardFailedFrom 清成 nil。
        // 而回弹刻意放到**下一轮** MainActor（见 recoveryAlertsAreWired），那时来源早没了。
        // ⇒ 必须在跳到下一轮**之前**先把值取出来。
        let hop = try #require(block.range(of: sq("Task { @MainActor in")),
                               "锚点失效：找不到延迟回弹的那一跳")
        #expect(block[..<hop.lowerBound].contains(sq("let origin = discardFailedFrom")),
                "来源必须在跳到下一轮之前捕获")
        // ⛔ 关键的一半：跳之后不得再碰它。只查前半条会被「捕获了但不用」骗过去。
        // 实证：把捕获挪进 Task 内部，本文件其余守卫与全部行为测试**照样 24 条全绿**，
        //      而回弹会静默失效 —— 训练中途返回的用户被无声地留在原地（Kimi R1-low）。
        #expect(!block[hop.upperBound...].contains(sq("discardFailedFrom")),
                "⛔ 下一轮里读 discardFailedFrom 读到的是 nil —— 回弹静默失效，没有任何测试会红")
    }

    @Test("⭐验收清单里声称的守卫条数必须与实际相符（同一份文档已连栽两轮）")
    func acceptanceDocCountsMatchReality() throws {
        // 验收清单是给**非技术复核者**看的，那两个数字是他对账的唯一抓手；写错等于给假凭据。
        // 本条把「文档里的数」与「文件里真实的 @Test 数」机械绑定，让它不能再默默过期。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root
            .appendingPathComponent("docs/superpowers/acceptance/2026-09-01-finalize-alert-truthful-exit.md"),
                             encoding: .utf8)
        for (claim, file) in [("条源码守卫", "Render/FinalizeFailureAlertSourceGuardTests.swift"),
                              ("条真行为测试", "FinalizeAlertSafeExitTests.swift")] {
            let hit = try #require(doc.range(of: claim), "锚点失效：验收清单里找不到「\(claim)」")
            // 往前吃掉数字（文档里数字与量词之间有空格，先跳过空白）
            var digits = ""
            var i = hit.lowerBound
            while i > doc.startIndex, doc[doc.index(before: i)].isWhitespace {
                i = doc.index(before: i)
            }
            while i > doc.startIndex {
                let prev = doc.index(before: i)
                guard doc[prev].isNumber else { break }
                digits.insert(doc[prev], at: digits.startIndex)
                i = prev
            }
            let claimed = try #require(Int(digits), "「\(claim)」前面必须是阿拉伯数字（中文数字请改写）")
            let src = try String(contentsOf: root
                .appendingPathComponent("ios/Contracts/Tests/KlineTrainerContractsTests/\(file)"),
                                 encoding: .utf8)
            // ⛔ 只数**行首的真声明**：按子串数会把注释里提到的 `@Test` 字样一并算进去
            //    （本条自己的注释就提了两次，首版因此把 13 数成 15）。
            let actual = src.split(separator: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("@Test(") }.count
            #expect(claimed == actual,
                    "验收清单声称 \(claimed) 条，\(file) 实际 \(actual) 条 —— 复核者会按文档对账")
        }

        // ⚠️ 第三个会过期的数字：文档里写的 Catalyst 基线。它已经错过三轮（1890/1894/1896），
        //    每次都是我加完守卫忘了回头改（Kimi R6-medium）。⇒ 同样机械绑定到基线文件本身。
        let hit = try #require(doc.range(of: "跨轮累计 1864→"), "锚点失效：文档里找不到基线陈述")
        let claimedBaseline = String(doc[hit.upperBound...].prefix { $0.isNumber })
        let liveBaseline = try String(contentsOf: root
            .appendingPathComponent(".github/scripts/catalyst-total-baseline.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(claimedBaseline == liveBaseline,
                "验收清单写基线 \(claimedBaseline)，而 catalyst-total-baseline.txt 是 \(liveBaseline)")
    }

    /// 取 `cannotPreserveCopy` 里某一支 `case` 返回的**那一个字符串字面量**（不含代码与注释）。
    /// ⛔ 不是「取到下一个 case 之前」：最后一支后面没有下一个 case，那样会一路吃到文件末尾
    ///    （见下方实现里的 ⛔ 注释）。三支各自独立断言，防「改了一支殃及另一支」。
    private func copyBranch(_ text: String, caseName: String) throws -> String {
        let body = try #require(text.range(of: sq("private var cannotPreserveCopy: String {")),
                                "锚点失效：找不到 cannotPreserveCopy")
        let rest = text[body.upperBound...]
        let start = try #require(rest.range(of: sq("case .\(caseName)")),
                                 "锚点失效：找不到 case .\(caseName)")
        // ⛔ 只取该 case 返回的**那一个字符串字面量**，不能「取到下一个 case 为止」——
        //    最后一支后面没有下一个 case，会一路吃到文件末尾，断言就会被文件别处的字样蒙混。
        let after = rest[start.upperBound...]
        let open = try #require(after.range(of: "return\""), "锚点失效：case .\(caseName) 之后找不到 return 字面量")
        var body2 = after[open.upperBound...]
        var out = ""
        while let ch = body2.first {
            body2 = body2.dropFirst()
            if ch == "\\" { if let esc = body2.first { out.append(ch); out.append(esc); body2 = body2.dropFirst() }; continue }
            if ch == "\"" { break }
            out.append(ch)
        }
        return out
    }

    /// 「提到『放弃本局』的**每一句**都必须带否定/警告语气」——共用判据。
    /// ⛔ 不能靠「禁掉某一句原话」：换个措辞（「也可以回到结算弹窗选『放弃本局』试试」）就绕过了。
    ///    本仓在这条判据上已经连栽五次，每次都是「补被点名的那一条」，形态一变又漏（Kimi R5-low）。
    /// ⇒ 现行判据（见实现）：「放弃本局」在本支**至多出现一次**，且那一次必须落在一个
    ///    **固定的警告短语**里。⛔ 头注与实现必须同步 —— 本 PR 已经在别处栽过两次
    ///    「陈旧头注教后人把洞改回来」（TrainingSessionLifecycle:52、
    ///    TrainingSessionCoordinator:1034），这里是第三次（Kimi R7-low）：
    ///    上一稿头注还写着已被废弃的「同句共现」规则，而那条规则 Kimi R6 已证明可绕过。
    /// ⚠️ 本判据是**文本层**的，有固有极限（见实现内的说明）；真正兜底的是验收清单 8f/8g/8h。
    private func discardMentionsAreAllWarnings(_ branch: String) -> Bool {
        // ⚠️ 上一稿判据是「同句里同时出现『放弃本局』和『失败』」，Kimi R6 证明它分不清
        //    那个「失败」修饰的是谁：「若重试入账仍然失败，也可以选择『放弃本局』离开。」
        //    —— 共现成立，而句子实际是在**推荐**放弃。
        // ⇒ 收紧两处：①「放弃本局」在本支**至多出现一次**（多处提及无法逐一判性质）；
        //             ②那一次必须落在**固定的警告短语**里，措辞不许自由发挥。
        let occurrences = branch.components(separatedBy: "放弃本局").count - 1
        guard occurrences <= 1 else { return false }
        guard occurrences == 1 else { return true }          // 一次都不提，本来就没问题
        return branch.contains("「放弃本局」也会失败")
            || branch.contains("「放弃本局」也可能失败")
    }

    @Test("⭐⭐存储写不进去那一支：⛔ 不得把「放弃本局」说成出路（它同样要写库，必然也失败）")
    func noneBranchMustNotOfferDiscardAsAWayOut() throws {
        // 真机验收（2026-09-05）暴露：8c 情形下三个按钮构成闭环 —— 重试失败、退出被拦、
        // 放弃同样失败（`discardSession` 走 `pendingRepo.clearPending()`，**必须写库**）。
        // 而文案却让用户「去上一个提示里选择放弃本局」⇒ 把人支去做一件必然失败的事。
        let branch = try copyBranch(try code(tv), caseName: "none")
        #expect(discardMentionsAreAllWarnings(branch),
                "⛔ 存储坏掉时「放弃本局」必然失败 —— 提到它的每一句都必须是警告，不得写成建议")
        // ⚠️ 这里比对的是**字面量内部**的文案，而扫描器刻意保留字面量里的空白
        //    ⇒ 断言一律用原文，⛔ 不能套 sq()（它会把「关闭 App」压成「关闭App」而永远不匹配）。
        #expect(branch.contains("关闭 App"),
                "必须给出真实出路：关掉 App 重开（首页按钮看 hasPending，此时它是空的 ⇒ 人能出来）")
        #expect(branch.contains("这一局会丢失"),
                "出路的代价必须一并说清 —— 否则又是一句半真话")

        // ⚠️ **按「这一类」补齐，不是按被点到的那一条**（Kimi R3-medium）。
        //    同一片改动里「立了不变量却没人兑现」已经犯了三次：
        //      R1 → `.trainingSetMissing` 不给「关闭 App」；R2 → 两个方向都不许绝对断言；
        //      R3 → 8f① 的「必须明说放弃也会失败」。每次我只补被点名的那一条。
        //    这次把验收清单里**所有**对本支的要求逐条落成断言（8c 两项 + 8f 三项）：
        // ⚠️ 「同样会失败」曾是这里的必含项，已改为带条件的「也会失败」（Kimi R10-low）：
        //    `saveProgress` 还会因 `loadedDrawingsLossy.reconciled` 检出重复/空 id 而抛 `.dbCorrupted`
        //    （fail-closed 设计路径，TrainingSessionCoordinator:671）——那时**存储完全健康**、
        //    本局从未写成 pending ⇒ status 正是 `.none`，而 `clearPending()` 会成功。
        //    ⇒ 我在这一支下了全称断言，与我自己在 `.trainingSetMissing` 支批判的「成因外推」同型。
        for required in [
            "也会失败",              // 8f①：告知放弃可能白忙，但⛔不下全称断言
            "全部丢失",              // 8c：退出的后果必须说死
            "请先清理设备存储空间",   // 8c：给出可操作的补救
        ] {
            #expect(branch.contains(required),
                    "⛔ 验收清单要求本支说明「\(required)」，删掉它守卫必须变红")
        }
    }

    @Test("⭐存档读不出来那一支：同样不得对「放弃本局」打包票")
    func unreadableBranchMustNotPromiseDiscard() throws {
        let branch = try copyBranch(try code(tv), caseName: "unreadable")
        #expect(discardMentionsAreAllWarnings(branch),
                "⛔ 存档层出问题时清槽也可能失败 —— 提到它的每一句都必须是警告，不得写成建议")
        #expect(branch.contains("关闭 App"), "必须给出真实出路")

        // ⚠️ **横向对齐**（Kimi R4-low）：上一轮我给 `.none` 支补齐了正向必含断言，却没有
        //    同步到本支 ⇒ 本支只剩「禁那句旧原话」这一条否定判据，绕过方式一改措辞就成立：
        //    「若不要这一局了，直接点『放弃本局』即可。也可以关闭 App 再重新打开」——
        //    不含被禁原话、含「关闭 App」⇒ 全绿，而「前两支不得把放弃说成出路」已被破坏。
        //    ⇒「按这一类穷尽」不只是穷尽一支内的要求，还要横向对齐所有同类支。
        for required in [
            "也可能失败",      // 保留条件：⛔ 不得把「放弃本局」说成确定可行
            "这一局会丢失",    // 出路的代价必须说清（与 `.none` 支同一标准）
        ] {
            #expect(branch.contains(required),
                    "⛔ 本支必须保留「\(required)」—— 删掉它守卫必须变红")
        }
    }

    @Test("⭐⭐⭐文件被淘汰那一支：⛔ 既不得打包票说放弃能成，也不得断言它必然失败")
    func trainingSetMissingBranchMustNotMakeAbsoluteClaimsAboutDiscard() throws {
        // 这一支被我改了两稿，两次都错在**只看了路的一半**：
        //  · 初稿：「成因是缓存淘汰 ⇒ 存储是好的 ⇒ 放弃一定能成」——漏了「能进本弹窗说明写库失败过」；
        //  · 二稿（矫枉过正）：「写库失败过 ⇒ 放弃同样会失败」——**时态错了**。
        //    `exitPreservingProgress` 里 `saveProgress` **成功**也会继续查 status
        //    （`savedCurrent = true` 那条路照样往下走），而 `.trainingSetMissing` 只要求**读**成功
        //    + 文件不在 ⇒ 存在「写库刚刚成功、只是文件没了」的真实路径，此刻 `clearPending()`
        //    会成功、放弃是**真出路**。断言它「同样会失败」= 把用户从走得通的路前吓退（Kimi R1-medium）。
        // ⇒ 正确姿态：**带条件地**提，两个方向都不许下全称断言。
        let branch = try copyBranch(try code(tv), caseName: "trainingSetMissing")

        // ⛔ 两个方向的绝对说法都不许。
        // ⚠️ 上一稿只挡了「必然失败」这一边，且正向判据松到「全文任意位置含『若』即过」
        //    ⇒ 「……放弃本局，它一定能成功。若刚才是存储写满导致的，请先清理…」照样全绿
        //    （Kimi R2-medium 给出的绕过例子）。我在文档里声称「两个方向都钉死了」，其实没有
        //    —— 与上一轮刚被指出的「立了不变量却没人兑现」是同一个毛病。
        // ⚠️ 黑名单是**有限清单**，「必定会失败」这类新措辞仍能绕（Kimi R6 明确指出）。
        //    ⛔ 别再往上堆词 —— 文本判据在这里已到极限。真正兜住「文案说的是不是实话」的
        //    是验收清单 8f/8g/8h 三条**人工验收**；守卫只负责挡住已知的退化写法。
        for absolute in ["同样会失败", "必然会失败", "一定会失败", "肯定会失败", "必定会失败",
                         "一定能成功", "必然成功", "肯定能成功", "一定可以成功", "必定能成功"] {
            #expect(!branch.contains(absolute),
                    "⛔ 「\(absolute)」是全称断言 —— 此刻写库是好是坏，代码里没有任何东西能保证")
        }

        // 正向：提到「放弃本局」的**每一处**所在句都要带条件。
        // ⚠️ 上一稿只查**第一处**（`if let hit = ...`），第二处起无条件提及完全不受检（Kimi R6）。
        var scan = Substring(branch)
        while let hit = scan.range(of: "放弃本局") {
            let sentence = scan[hit.upperBound...].prefix { $0 != "。" && $0 != "；" }
            #expect(sentence.contains("如果") || sentence.contains("若"),
                    "⛔ 提「放弃本局」的每一句都必须自带条件限定，不能由别处的『若』代劳")
            scan = scan[hit.upperBound...]
        }
    }

    @Test("⭐⭐文件被淘汰那一支：⛔ 不得给「关闭 App」的建议（存档还在，关掉重开会引到坏状态）")
    func trainingSetMissingBranchMustNotSuggestClosingApp() throws {
        // ⚠️ 这条不变量我先写进了源码注释和验收清单 8g，却**没有任何守卫兑现它**
        //    （Kimi R1-medium 实测：全仓搜「关闭 App」只有另外两支的正向断言）。
        //    本仓踩过同款：写「必须 X」之前先核实既有机制兑现得了 X 吗。
        // 为什么这一支不能给：它的 pending 还在 ⇒ 关掉重开后首页是「继续训练」，
        // 点进去会因训练组数据文件不在而失败 —— 把人引到一个打不开的局里。
        let branch = try copyBranch(try code(tv), caseName: "trainingSetMissing")
        #expect(!branch.contains("关闭 App"),
                "⛔ 这一支给「关闭 App」= 把用户引向一个点进去就失败的「继续训练」")
    }

    @Test("⭐「关掉 App 重开能出来」这条出路的行为测试必须还在（⛔ 删了/改名了要报警）")
    func escapeHatchBehaviourTestsStillExist() throws {
        // 文案对用户许诺「可以直接关闭 App 再重新打开」，兑现它的是 AppRouterTests 里那两条。
        // ⚠️ 上一轮我在验收文档里写了「另有 2 条行为测试」，却没有任何机制绑定它
        //    ⇒ 有人删掉或改名，文档说法就静默过期（Kimi R5-low）。
        //    这里钉**函数名存在性**而不是条数：比数字更准，也不会因为同文件新增别的测试而失真。
        let src = try code("Tests/KlineTrainerContractsTests/AppRouterTests.swift")
        for fn in ["loadHome_unreadablePending_fallsBackToEmptyHomeSoUserCanEscape",
                   "loadHome_readablePending_showsResume"] {
            #expect(src.contains(fn),
                    "⛔ \(fn) 不见了 —— 文案许诺的逃生路失去行为测试保护")
        }
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
        //    且随附建议「清理存储空间」在③下**对找回文件无效**（文件已删，腾空间也回不来）。
        //    ⚠️ 但对「让**入账**写得进去」它是有效的 —— 订正后③支照样建议清存储（见下方 494 行起的判据）。
        //    ⛔ 本行曾写成绝对的「对③无效」；那句话与同一函数下方的新判据并排矛盾（Kimi R9-low）。
        // 判据不是「删掉那句话」，而是「**按原因分支**」：
        #expect(code.contains(sq("case .cannotPreserve(let")),
                "必须把原因解构出来消费掉 —— 否则文案不可能分得开")
        #expect(code.contains(sq("还没有过任何自动存档")),
                "①『本局一次都没存成』那一支的文案仍应存在（对它而言那是真话）")
        #expect(code.contains(sq("训练组数据文件")),
                "③『文件被淘汰』那一支必须如实说明是数据文件没了，⛔ 不得复用①那句假话")
        #expect(code.contains(sq("存档读取失败")),
                "④『存档读不出来』（数据库损坏 / IO）也必须有自己的说法 —— 报成①会让用户做无效补救")
        // ③ 那一支**可以**带条件地提「清理存储空间」（2026-09-06 订正，现行判据见下方 if 分支）。
        // ⛔ 本行曾是「不得建议清理存储空间——文件已被删除，腾出空间也回不来」，那只在
        //    「找回文件」这个目的下成立；重试入账要写库、写库要空间 ⇒ 另一个目的下它有效。
        //    旧禁令与下方新判据并排会误导后人把新文案改回去（Kimi R8-low）。
        // ⚠️ 范围必须切到**那一条字面量自己的收尾引号**为止：上一稿取「附近 160 字符」，
        //    会串进紧邻的①那一支（它本来就该有这条建议）⇒ 假阳性。
        let hit = try #require(code.range(of: sq("训练组数据文件")))
        let rest = code[hit.upperBound...]
        let endQuote = try #require(rest.firstIndex(of: "\""), "找不到该文案的收尾引号（锚点失效）")
        let missingBranchCopy = String(rest[..<endQuote])
        // ⚠️ **判据随前提订正**（2026-09-06）：上一稿在这里禁止本支出现「清理设备存储空间」，
        //    理由是「文件已删，腾空间也回不来」。那个理由只针对**找回文件**这一个目的成立。
        //    自查发现前提变了：能走到本弹窗说明写库已失败过，而**重试入账要写库** ⇒ 清理存储
        //    在这一支有了第二个、真实有效的用途。⛔ 沿用旧禁令会逼出一句对用户没用的空话。
        //    新判据：可以提清理存储，但**必须说清目的是重试入账**，绝不能暗示文件能回来。
        if missingBranchCopy.contains("清理设备存储空间") {
            #expect(missingBranchCopy.contains("重试入账"),
                    "⛔ 这一支提清理存储时必须说明是为了重试入账 —— 否则会被读成『腾空间就能找回文件』")
        }
        for lie in ["恢复训练组", "找回", "重新下载后即可继续"] {
            #expect(!missingBranchCopy.contains(lie),
                    "⛔ 不得暗示清理存储能让被删掉的训练组数据文件回来")
        }
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

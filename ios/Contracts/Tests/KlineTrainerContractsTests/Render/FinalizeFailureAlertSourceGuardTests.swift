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

    /// 剥掉行注释的源码（结构断言用）—— 否则注释里出现的字样会把守卫骗过去。
    private func source(_ rel: String) throws -> String {
        let text = try rawSource(rel)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line); guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }

    /// **原始**源码（`source` 的输入）。
    private func rawSource(_ rel: String) throws -> String {
        try String(contentsOf: srcDir.appendingPathComponent(rel), encoding: .utf8)
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

    @Test("锚点有效 + 恰好三个出口（重试 / 退出本局 / 放弃本局）")
    func anchorAndButtonCount() throws {
        let code = try source(tv)
        // 反向自检：先证明真的读到了这个弹窗，防「路径写错 → 零命中 → 恒过」
        #expect(code.contains(".alert(\"结算入账失败\""), "锚点失效：扫不到该弹窗")

        let block = try finalizeAlertBlock(code)
        #expect(block.contains("Button(\"重试\")"), "重试按钮不见了")
        #expect(block.components(separatedBy: "Button(").count - 1 == 3,
                "该弹窗应恰好三个按钮：重试 / 退出本局 / 放弃本局")
    }

    @Test("必须有非破坏性出口，且该出口**不依赖正在坏掉的存储层**（codex R1-high）")
    func nonDestructiveExitExists() throws {
        let block = try finalizeAlertBlock(try source(tv))
        #expect(block.contains("Button(\"退出本局\""), "缺少非破坏性出口 —— 用户只剩会删数据的按钮")
        // ⛔ 不得是 `lifecycle.back()`：它必须 saveProgress **成功**才 endSession，而本弹窗最现实的
        //    触发原因正是写盘失败 ⇒ 那条出口在最需要它的时候恰好也坏了（codex R1-high）。
        #expect(block.contains("lifecycle.exitPreservingProgress()"),
                "退出本局必须走 exitPreservingProgress()（落盘失败也照样安全退出）")
        #expect(!block.contains("lifecycle.back()"),
                "⛔ back() 依赖写盘成功，不能当作失败场景下的安全出口")
    }

    @Test("退出本局必须**分三态处置**，且『保不住』那一态⛔不得离开本局（codex R2-high）")
    func exitHandlesAllThreeOutcomes() throws {
        let block = try finalizeAlertBlock(try source(tv))
        // 必须真的分支处理，而不是拿到结果就丢掉
        #expect(block.contains("case .savedCurrentState, .keptEarlierCheckpoint:"),
                "保住了东西的两态才允许 onExit()")
        #expect(block.contains("case .cannotPreserve:"),
                "必须显式处理『什么都没保住』这一态")
        // ⛔ 核心：`.cannotPreserve` 表示会话**没有被结束**；此刻 onExit() 会把用户带走，
        //    而整局只剩内存里那一份 —— 等于亲手丢掉它。
        let tail = try #require(block.range(of: "case .cannotPreserve:"))
        let afterCannotPreserve = String(block[tail.upperBound...].prefix(120))
        #expect(!afterCannotPreserve.contains("onExit()"),
                "⛔ 保不住任何东西时绝不能 onExit() —— 那正是本条要防的丢失")
    }

    @Test("放弃本局必须**成功才离开**，⛔ 不得吞掉错误就回首页（codex R2-medium）")
    func discardExitsOnlyOnSuccess() throws {
        let block = try finalizeAlertBlock(try source(tv))
        #expect(block.contains("do { try await lifecycle.discard(); onExit() }"),
                "必须 do/catch：discardSession() 是故意在清槽失败时先抛错、不结束会话")
        #expect(!block.contains("try? await lifecycle.discard()"),
                "⛔ try? 会造成『界面回了首页、会话还活着、pending 也还在』而用户被告知已丢弃")
    }

    @Test("破坏性按钮必须标 role: .destructive，且仍真的弃局")
    func destructiveButtonIsMarked() throws {
        let block = try finalizeAlertBlock(try source(tv))
        #expect(block.contains("Button(\"放弃本局\", role: .destructive)"),
                "放弃必须标为破坏性（iOS 据此渲染成红色）——原来标的是 .cancel")
        // 反向对照：别为了「安全」把弃局做成不弃局 —— 用户确实想扔时得能扔干净
        #expect(block.contains("lifecycle.discard()"), "放弃本局仍必须真的弃局")
    }

    @Test("文案必须属实：不含旧假话、指对回去的地方、并说清「最坏保留到哪」")
    func alertCopyIsTruthful() throws {
        // ⚠️ 用 source（剥注释、**保留字符串字面量**）：文案住在 `Text("…")` 里，剥注释不影响它；
        //    而不剥注释会把下一个弹窗的前置注释圈进来造成误报（见 finalizeAlertBlock 头注）。
        let block = try finalizeAlertBlock(try source(tv))
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

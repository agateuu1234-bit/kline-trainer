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

    /// **原始**源码（用户可见文案断言用）—— 文案本身就住在字符串字面量里，剥不得。
    private func rawSource(_ rel: String) throws -> String {
        try String(contentsOf: srcDir.appendingPathComponent(rel), encoding: .utf8)
    }

    private let tv = "Sources/KlineTrainerContracts/UI/TrainingView.swift"

    /// 只取「结算入账失败」这一个弹窗的源码块：从它的 `.alert(` 起，到**下一个** `.alert(` 之前。
    /// 不限定范围的话，断言会被同文件里另外两个弹窗的内容蒙混过去。
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

    @Test("必须有非破坏性出口：退出本局 → lifecycle.back()（保存进度后退出，不清 pending）")
    func nonDestructiveExitExists() throws {
        let block = try finalizeAlertBlock(try source(tv))
        #expect(block.contains("Button(\"退出本局\""), "缺少非破坏性出口 —— 用户只剩会删数据的按钮")
        #expect(block.contains("lifecycle.back()"),
                "退出本局必须走 back()（saveProgress + endSession），⛔ 不得走 discard()")
    }

    @Test("破坏性按钮必须标 role: .destructive，且仍真的弃局")
    func destructiveButtonIsMarked() throws {
        let block = try finalizeAlertBlock(try source(tv))
        #expect(block.contains("Button(\"放弃本局\", role: .destructive)"),
                "放弃必须标为破坏性（iOS 据此渲染成红色）——原来标的是 .cancel")
        // 反向对照：别为了「安全」把弃局做成不弃局 —— 用户确实想扔时得能扔干净
        #expect(block.contains("lifecycle.discard()"), "放弃本局仍必须真的弃局")
    }

    @Test("文案必须属实：不得再声称「进度保留至最近存档」，且三条出口后果各自说清")
    func alertCopyIsTruthful() throws {
        let block = try finalizeAlertBlock(try rawSource(tv))
        #expect(!block.contains("进度保留至最近存档"),
                "这句与「放弃」实际清空整局 pending 的行为相反 —— 会诱导用户放心点下破坏性动作")
        #expect(block.contains("暂存进度保留"), "必须告诉用户哪条出口会保留进度")
        #expect(block.contains("丢弃"), "必须明示「放弃本局」会丢弃本局进度")
    }
}

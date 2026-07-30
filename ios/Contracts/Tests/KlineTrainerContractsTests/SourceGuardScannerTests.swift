// ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScannerTests.swift
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("源码守卫扫描器自检（a–f）")
struct SourceGuardScannerTests {
    @Test("守卫自检 a（codex plan-R1-F1 + R2-F1）：换行/括号前空白/块注释三种排版都逃不掉，注释里的不算")
    func scannerCatchesAwkwardFormatting() {
        let src = """
        func caller() {
            engine.deleteDrawing(
                id: a
            )
            engine.deleteDrawing
                (
                    id: b
                )
            engine.deleteDrawing/* 块注释 */(id: c)
            // engine.deleteDrawing(id: 行注释里的不算)
            /* engine.deleteDrawing(id: 块注释里的也不算) */
        }
        """
        let s = squeezedText(src)
        #expect(callCount(inSqueezed: s, pattern: "deleteDrawing(id:") == 3, "三种排版都该命中，实际 squeeze：\(s)")
        #expect(!s.contains("行注释里的不算"))
        #expect(!s.contains("块注释里的也不算"))
    }

    @Test("守卫自检 f（codex plan-R10-F1）：插值体里的注释按注释处理——注释中的 `)` 不算插值收尾")
    func scannerHandlesCommentsInsideInterpolation() {
        let src = ##"""
        func caller() {
            logger.debug("x \(/* ) */ engine.deleteDrawing(id: id))")
            let m = """
            y \(// ) 行注释里的右括号
            engine.updateDrawingStyle(id: i, style: st))
            """
        }
        """##
        let s = squeezedText(src)
        // 注释里的 `)` 若被当成插值收尾，真调用就会被当字面文本丢掉 → 计数变 0，本测试当场红
        #expect(callCount(inSqueezed: s, pattern: "deleteDrawing(id:") == 1, "实际 squeeze：\(s)")
        #expect(callCount(inSqueezed: s, pattern: "updateDrawingStyle(") == 1, "实际 squeeze：\(s)")
    }

    @Test("守卫自检 e（codex plan-R9-F1）：插值 \\(…) 里的调用与方法引用**照样算数**（它们真的会执行）")
    func scannerCountsCallsInsideStringInterpolation() {
        // ⚠️ 外层用 `##"""`：本 fixture 内部要出现 `\(` **和** `\#(` 两种插值前缀的**字面文本**，
        //    若外层只用 `#"""`，`\#(…)` 会被 Swift 当成**本测试文件自己的**插值 → 编译错误。
        let src = ##"""
        func caller() {
            logger.debug("deleted \(engine.deleteDrawing(id: id))")
            let s = "\(engine.updateDrawingStyle(id: i, style: st))"
            let f = "\(engine.appendDrawing)"
            let plain = "deleteDrawing(id: 纯文本不算)"
            let raw = #"\#(engine.routeDrawingCommit(d))"#
        }
        """##
        let s = squeezedText(src)
        #expect(callCount(inSqueezed: s, pattern: "deleteDrawing(id:") == 1, "实际 squeeze：\(s)")
        #expect(callCount(inSqueezed: s, pattern: "updateDrawingStyle(") == 1, "实际 squeeze：\(s)")
        #expect(callCount(inSqueezed: s, pattern: "routeDrawingCommit(") == 1, "原始串的插值前缀是 \\#(…)：\(s)")
        #expect(s.contains("appendDrawing"))          // 藏在插值里的**方法引用**，标识符扫描也看得见
        #expect(!s.contains("纯文本不算"))             // 纯文本仍不算数（不产生假阳性）
    }

    @Test("守卫自检 d（codex plan-R7-F1）：字符串里的注释定界符不得吞掉后面的真实调用；串内的调用不算数")
    func scannerHandlesStringLiteralsWithCommentDelimiters() {
        let src = #"""
        func caller() {
            let u = "https://example.com/a"; engine.deleteDrawing(id: x)
            let s = "/*"
            engine.updateDrawingStyle(id: y, style: st)
            let r = ##"deleteDrawing(id: 原始串里的不算)"##
            let m = """
            deleteDrawing(id: 多行串里的也不算)
            """
            let esc = "带转义的引号 \" 之后仍在串内：deleteDrawing(id: 不算)"
        }
        """#
        let s = squeezedText(src)
        // `"https://…"` 里的 `//` 没把同一行后面的真实调用吃掉；`"/*"` 没开启块注释吞掉下一行
        #expect(callCount(inSqueezed: s, pattern: "deleteDrawing(id:") == 1, "实际 squeeze：\(s)")
        #expect(callCount(inSqueezed: s, pattern: "updateDrawingStyle(") == 1, "实际 squeeze：\(s)")
        // 字符串内容整段丢弃 → 串里的调用字样不产生假阳性
        #expect(!s.contains("原始串里的不算"))
        #expect(!s.contains("多行串里的也不算"))
        #expect(!s.contains("不算"))
    }

    @Test("守卫自检 c（codex plan-R5-F1 + R6-F1）：方法引用不出现调用 pattern，但必被标识符扫描抓到")
    func scannerCatchesMethodReferences() {
        // 这三行都是**合法 Swift**，且都让调用点计数看不见（源码里没有 `xxx(` 这个形状）。
        let src = """
        func sneaky(engine: TrainingEngine) {
            let f = engine.appendDrawing
            let g: (DrawingID, DrawingDefaultStyle) -> Bool = engine.updateDrawingStyle
            let h = engine.routeDrawingCommit
            later(f, g, h)
        }
        """
        let s = squeezedText(src)
        // 调用点计数：全 0（这正是 R5/R6 指出的绕过）
        #expect(callCount(inSqueezed: s, pattern: "appendDrawing(") == 0)
        #expect(callCount(inSqueezed: s, pattern: "updateDrawingStyle(") == 0)
        #expect(callCount(inSqueezed: s, pattern: "routeDrawingCommit(") == 0)
        // 标识符扫描：三个都看得见 → `filesMentioning` 的白名单断言会把这种文件抓出来
        #expect(s.contains("appendDrawing"))
        #expect(s.contains("updateDrawingStyle"))
        #expect(s.contains("routeDrawingCommit"))
    }

    @Test("守卫自检 b（codex plan-R3-F1）：first-argument-label 的定义不得把真实调用扣成 0")
    func scannerCountsFirstArgumentLabelCallsExactly() {
        // `func deleteDrawing(at index: Int)` 与调用 `deleteDrawing(at: 0)` 形状不同：
        // 前者 squeeze 后是 `funcdeleteDrawing(atindex:`，**不含**调用 pattern。
        // 用「更宽的 defPattern」去扣就会把这次真实调用抹成 0（守卫恒绿 = 破坏性入口放行）。
        let src = """
        func deleteDrawing(at index: Int) {}
        func caller() { engine.deleteDrawing(at: 0) }
        """
        #expect(callCount(inSqueezed: squeezedText(src), pattern: "deleteDrawing(at:") == 1)
        // 对照：同名 id 版本的定义**确实**含调用 pattern（`func deleteDrawing(id: DrawingID)`）→ 必须被扣掉
        let src2 = """
        func deleteDrawing(id: DrawingID) -> Bool { true }
        """
        #expect(callCount(inSqueezed: squeezedText(src2), pattern: "deleteDrawing(id:") == 0)
        // 再对照：定义 + 一次真实调用 → 恰好 1
        let src3 = """
        func deleteDrawing(id: DrawingID) -> Bool { true }
        func caller() { _ = engine.deleteDrawing(id: "x") }
        """
        #expect(callCount(inSqueezed: squeezedText(src3), pattern: "deleteDrawing(id:") == 1)
    }
}

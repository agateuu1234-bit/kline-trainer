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

    @Test("守卫自检 g（PR-2 交接③）：白名单文件内部的 vend 方法引用必须被抓到，正常声明/调用不得误报")
    func scannerCatchesVendedMethodReference() {
        // ① 会被抓：三种真实 vend 写法
        let vended = """
        extension TrainingEngine {
            func handle() -> (DrawingID) -> Bool { deleteDrawing }
            func pick() -> ((DrawingID) -> Bool) {
                let f = deleteDrawing
                return f
            }
            var alias: (DrawingID) -> Bool { self.deleteDrawing }
        }
        """
        #expect(bareIdentifierReferences(inCode: codeTextPreservingBoundaries(vended),
                                         identifier: "deleteDrawing") == 3,
                "三处 vend 都该命中，实际文本：\(codeTextPreservingBoundaries(vended))")

        // ② 不得误报：声明 / 调用 / 更长标识符 / 注释 / 字符串字面量
        let clean = """
        extension TrainingEngine {
            func deleteDrawing(id: DrawingID) -> Bool { true }
            func deleteDrawing(at index: Int) {}
            func deleteDrawingForTesting() {}
            func caller() {
                _ = deleteDrawing(id: "a")
                self.deleteDrawing(at: 0)
                deleteDrawingForTesting()
            }
            // 注释里写 deleteDrawing 不算
            /* 块注释里的 deleteDrawing 也不算 */
            let s = "字符串里的 deleteDrawing 不算"
        }
        """
        #expect(bareIdentifierReferences(inCode: codeTextPreservingBoundaries(clean),
                                         identifier: "deleteDrawing") == 0,
                "误报了，实际文本：\(codeTextPreservingBoundaries(clean))")
    }

    @Test("守卫自检 g3（codex plan-R4-F2）：注释/字面量被剥掉时留下边界 —— 紧贴注释的 vend 逃不掉，紧贴注释的调用不误报")
    func scannerKeepsBoundaryAcrossComments() {
        // ① Swift 里注释本身就是 token 分隔符，下面两行都是**合法代码**里的真 vend
        let vendedAcrossComment = """
        extension TrainingEngine {
            func a() -> (DrawingID) -> Bool { return/*x*/deleteDrawing }
            func b() -> (DrawingID) -> Bool { return//x
                deleteDrawing }
        }
        """
        #expect(bareIdentifierReferences(inCode: codeTextPreservingBoundaries(vendedAcrossComment),
                                         identifier: "deleteDrawing") == 2,
                "紧贴注释的 vend 漏检 —— 第三层守卫可被绕过。实际文本：\(codeTextPreservingBoundaries(vendedAcrossComment))")

        // ② 反向：紧贴注释的**正当调用**不得被误报（边界空格把 `(` 推开了，判据必须跳空格再看）
        let callAcrossComment = """
        func caller() {
            engine.deleteDrawing/* c */(id: c)
            engine.deleteDrawing
                (id: d)
        }
        """
        #expect(bareIdentifierReferences(inCode: codeTextPreservingBoundaries(callAcrossComment),
                                         identifier: "deleteDrawing") == 0,
                "正当调用被误报成 vend，实际文本：\(codeTextPreservingBoundaries(callAcrossComment))")

        // ③ 边界不得把两个独立 token 粘成一个长标识符（①② 必须看紧邻字符）
        #expect(bareIdentifierReferences(inCode: "let x = deleteDrawing Foo", identifier: "deleteDrawing") == 1)
        #expect(bareIdentifierReferences(inCode: "deleteDrawingForTesting()", identifier: "deleteDrawing") == 0)

        // ④ 判据①：以目标标识符**结尾**的更长标识符不得被计成 vend（删掉 check① 本条即红——
        //    fix round 1 前该判据在 g/g3 里零判别力，评审变异实验实证：删掉 check① 上面 6 条断言一个都不红）。
        //    ⚠️ 第二条：`confirmDeleteDrawing()`（评审最初建议的带括号形态）已用变异脚本验过**没有判别力**——
        //    去掉 check① 后它仍判 0，因为末尾 `(` 让 check③ 独立把它挡下来，check① 从未被真正运行到；
        //    去掉尾部 `()`（本条形态）后末尾变成"匹配后无后继字符" → 走 fail-closed 的 `guard let a = after`
        //    分支，check① 才是唯一能挡住它的判据，去掉 check① 会真的从 0 变 1。
        #expect(bareIdentifierReferences(inCode: "let f = xdeleteDrawing", identifier: "deleteDrawing") == 0)
        #expect(bareIdentifierReferences(inCode: "confirmDeleteDrawing", identifier: "DeleteDrawing") == 0)
    }

    @Test("守卫自检 g2：`codeTextPreservingBoundaries` 与 `squeezedText` 是同一个词法器，只差空白处理")
    func boundaryPreservingSharesLexer() {
        let src = """
        func f() {
            // deleteDrawing 注释
            let s = "deleteDrawing 串"
            engine.deleteDrawing(id: x)
        }
        """
        // 两者都必须剥掉注释与串内容、都必须保留那一次真实调用
        #expect(!codeTextPreservingBoundaries(src).contains("注释"))
        #expect(!codeTextPreservingBoundaries(src).contains("串"))
        #expect(codeTextPreservingBoundaries(src).contains("engine.deleteDrawing(id: x)"))
        #expect(squeezedText(src).contains("engine.deleteDrawing(id:x)"))
    }

    @Test("守卫自检 h（整支终审①）：`engineDrawingsStructuralWrites` 覆盖全部数组变异方法族 + 嵌套下标配对，reviewDrawings/纯读不误报")
    func structuralWritesCoversFullMutationFamilyAndNestedSubscript() {
        func n(_ src: String) -> Int { engineDrawingsStructuralWrites(squeezedText(src)) }

        // 既有形态基线（回归，防本条自检自己先坏掉）
        #expect(n("drawings.append(x)") == 1)
        #expect(n("reviewDrawings.append(x)") == 0, "reviewDrawings 是另一个数组，不得被算进 drawings 的写入面")
        #expect(n("_ = drawings[$0].id == id") == 0, "下标读不算写")
        #expect(n("drawings[i] = x") == 1)
        #expect(n("_ = drawings[i] == x") == 0, "`==` 是比较不是赋值")

        // 整支终审①新增：z-order 打乱族，每条都必须被判据抓到（PR-2 崩溃级陈旧下标的根因就在这一族）。
        // 各自单独判 ==1（不是 ==2）顺带证明了新 needle 与既有 `drawings.remove(` 不重叠——
        // 若 `drawings.remove(` 也误配上 `drawings.removeAll(` 这种更长的形态，这里会变成 2。
        #expect(n("drawings.removeAll(where: { $0.id == id })") == 1)
        #expect(n("drawings.removeFirst()") == 1)
        #expect(n("drawings.removeLast()") == 1)
        #expect(n("_ = drawings.popLast()") == 1)
        #expect(n("drawings.swapAt(0, 1)") == 1, "swapAt 打乱 z-order")
        #expect(n("drawings.sort()") == 1, "sort 打乱 z-order")
        #expect(n("drawings.reverse()") == 1, "reverse 打乱 z-order")
        #expect(n("drawings.replaceSubrange(0..<1, with: [x])") == 1)
        #expect(n("drawings += [y]") == 1)

        // 嵌套下标：原判据「扫到第一个 `]` 就停」在这里会漏计（内层 `]` 被误当成下标收尾，
        // 紧邻的外层 `]` 而非 `=` 让赋值检查失败）——必须配对方括号才能算对。
        #expect(n("drawings[idx[k]] = z") == 1,
                "嵌套下标必须配对方括号，不能扫到第一个 `]` 就当下标结束")

        // 整支终审②（Important-4）新增：整体赋值 `drawings = <表达式>` 的双向自检。
        #expect(n("drawings = x") == 1, "整体赋值必须被算作结构性写入 —— 它是最彻底打乱下标的那一种")
        #expect(n("self.drawings = seededLossy.drawings") == 1,
                "带 `self.` 前缀的整体赋值也必须数到（`self`/`.` 都不是标识符字符，不挡前缀排除）")
        #expect(n("drawings == x") == 0, "`==` 是比较，不是赋值")
        // ⚠️ residual-fix C：`n("reviewDrawings = x") == 0` 曾经是恒真的——needle 是**全小写**的
        //    `drawings`，`reviewDrawings` 里是**大写 D** 的 `Drawings`，两者字符级根本匹配不上，
        //    删掉 `startsBare` 里的前缀排除（`i>0 && isIdentChar(chars[i-1])`）这条断言也纹丝不动。
        //    真正能踩到「前缀是标识符字符」这条排除的，必须是**大小写与 needle 完全一致**（全小写
        //    `drawings`）、且紧邻前一个字符是标识符字符的复合标识符——例如 `xdrawings`（`x` 是
        //    标识符字符）。变异证据见 residual-fix-report.md：删掉前缀排除后这条断言真的从 0 翻到 1。
        #expect(n("xdrawings = y") == 0,
                "`xdrawings` 是一个更长的复合标识符（前一个字符 `x` 是标识符字符），前缀排除必须把它挡在外面，不得被当成对 `drawings` 的整体赋值")
        // `drawings[i] = x` 已在上面断言为 1（非 2）：证明整体赋值判据与下标赋值判据不重叠、不双计
        // ——下标写法紧邻 `drawings` 的下一个字符是 `[`，不是 `=`，两段判据各管各的字符位置。
    }
}

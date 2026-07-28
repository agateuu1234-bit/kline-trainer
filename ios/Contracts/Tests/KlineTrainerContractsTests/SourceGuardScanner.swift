// ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScanner.swift
// 源码守卫共享扫描器（codex plan R1/R2/R3/R7/R8/R9/R10/R13 逐轮收紧的产物）。
// ⚠️ Swift import 是**文件级**的，本文件必须自带。
// ⚠️ 这些函数**不得**加 `private`（codex plan-R14-F2）：顶层 `private` 在 Swift 里是**文件作用域**，
//    加了之后 SourceGuardScannerTests / TrainingEngineDrawingSessionTests 根本调不到 → 整个 Task 编译失败。
import Foundation
import Testing
@testable import KlineTrainerContracts

/// ios/Contracts 目录（由本文件路径回推：Tests/KlineTrainerContractsTests/<本文件> → 上溯 3 层）。
var contractsDirForGuards: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// `Sources/` 下**全部 target** 的 .swift 绝对路径（codex plan-R8-F1：跨 target 调用者也要覆盖）。
func allSwiftFilesUnderSources() throws -> [String] {
    let root = contractsDirForGuards.appendingPathComponent("Sources")
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map(\.path)
}

var trainingEnginePath: String {
    contractsDirForGuards.appendingPathComponent(
        "Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift").path
}

// MARK: 空白无关的调用点扫描（codex plan-R1-F1 → R2-F1 → R3-F1 → R7-F1 → R8-F1 逐轮收紧）

/// ⚠️ **本 Task 同时把扫描根从 `Sources/KlineTrainerContracts` 放宽到整个 `Sources/`**（codex plan-R8-F1）：
///   本包有两个 target（`KlineTrainerContracts` / `KlineTrainerPersistence`，`Package.swift` 实测），
///   只扫前者的话，一个**跨 target** 的调用者根本不在扫描范围内。改法 = 把 PR-1 既有 helper
///   `allSwiftFilesUnderSources()` 的 root 从 `Sources/KlineTrainerContracts` 改成 `Sources/`。
///   **实测过不会引入假阳性**：`KlineTrainerPersistence` 当前对 `appendDrawing` / `appendReviewDrawing` /
///   `routeDrawingCommit` / `deleteDrawing` / `updateDrawingStyle` 五个标识符**一次都没提**
///   （`grep -rln <id> Sources/ | grep -v KlineTrainerContracts/` 全空）→ 各 pattern 计数不变。
///   实施时先跑一遍既有 `appendFamilyTrustBoundary` 确认仍绿，再往下写新守卫。

/// 删掉**全部**空白字符（用于 needle 与源码两侧，使匹配彻底与排版无关）。
func squeeze(_ s: String) -> String {
    s.split(whereSeparator: { $0.isWhitespace }).joined()
}

/// 一段源码文本 → **只剩代码**（剥行注释 / 嵌套块注释 / 字符串字面量内容）**且删光空白**。
/// ⚠️ 三次收紧的由来，别退回去（每一条都是 codex 用一段**合法 Swift** 打穿的）：
///   ① 逐行 substring 挡不住 `engine.deleteDrawing(\n id: x\n)`（R1-F1）；
///   ② 只折叠空白、只收紧 `"( "` 仍不够（R2-F1）：`engine.deleteDrawing\n(\n id: x\n)` 会留下
///      `deleteDrawing (id:`（左括号**前面**那个空格没人管）；`deleteDrawing/* c */(id:` 同理；
///   ③ **不跟踪字符串状态就会反向漏**（R7-F1）：`let u = "https://x"` 里的 `//` 会让「吃到行尾」
///      把**同一行后面的真实调用**当注释丢掉；`let s = "/*"` 更狠——块注释状态一开，能吞掉整片代码。
///      故这里是个**小词法器**：正确处理普通串 / 多行串 `"""` / 原始串 `#"…"#`（含 `\#` 转义），
///      并把字符串**内容整段丢弃**（字面量里的 `deleteDrawing(id:` 本来就不是调用，顺带免了假阳性）。
///   守卫漏掉一个调用点的后果不是"少测一条"，而是 PR-4 可以在**不补几何门**的情况下接上不可逆删除。
///   ④ **顶层与插值体各写一份循环 = 两档判据**（R10-F1）：插值那份不认注释 →
///      `"\(/* ) */ engine.deleteDrawing(id: id))"` 里**注释中的** `)` 被当成插值收尾，真调用反被
///      当字面文本丢掉。根因不是"再补一个 case"，是**同一件事有两份能力不同的实现**（本计划一路在
///      批评的同一个毛病）→ 现在**只有 `scanCode` 一个循环**，顶层与插值体走完全相同的注释/字符串
///      规则，唯一差别是"遇 `)` 是否收尾"。
func squeezedText(_ raw: String) -> String {
    var out = ""
    _ = scanCode(Array(raw), from: 0, parenDepth: nil, into: &out)
    return out
}

/// **唯一**的词法扫描循环。`parenDepth == nil` = 顶层（`)` 不收尾）；非 nil = 插值体（深度归零即返回，
/// 那个收尾 `)` 不写进 out）。注释 / 字符串 / 原始串 / 嵌套插值在两种模式下**判据完全一致**。
func scanCode(_ c: [Character], from start: Int, parenDepth: Int?, into out: inout String) -> Int {
    var i = start
    var depth = parenDepth ?? 0
    while i < c.count {
        if c[i] == "/", i + 1 < c.count, c[i + 1] == "*" {       // 块注释（可嵌套）
            var d = 1; i += 2
            while i < c.count, d > 0 {
                if c[i] == "/", i + 1 < c.count, c[i + 1] == "*" { d += 1; i += 2; continue }
                if c[i] == "*", i + 1 < c.count, c[i + 1] == "/" { d -= 1; i += 2; continue }
                i += 1
            }
            continue
        }
        if c[i] == "/", i + 1 < c.count, c[i + 1] == "/" {       // 行注释：吃到行尾
            while i < c.count, c[i] != "\n" { i += 1 }
            continue
        }
        if c[i] == "#" {                                         // 可能是原始串 #"…"# / ##"…"##
            var h = 0, j = i
            while j < c.count, c[j] == "#" { h += 1; j += 1 }
            if j < c.count, c[j] == "\"" { i = consumeStringLiteral(c, from: j, hashes: h, into: &out); continue }
            out.append(contentsOf: c[i..<j])                      // 不是原始串（如 #expect / #filePath）
            i = j; continue
        }
        if c[i] == "\"" { i = consumeStringLiteral(c, from: i, hashes: 0, into: &out); continue }
        if parenDepth != nil {                                   // 只有插值体在意括号深度
            if c[i] == "(" { depth += 1 }
            if c[i] == ")" {
                depth -= 1
                if depth == 0 { return i + 1 }                    // 插值收尾：这个 `)` 不写进 out
            }
        }
        if !c[i].isWhitespace { out.append(c[i]) }                // 空白一律丢弃
        i += 1
    }
    return c.count
}

/// 消费一个字符串字面量（`from` 指向首个 `"`），返回其后第一个下标。
/// **字面文本丢弃，但插值 `\(…)` 里的表达式当代码保留**（codex plan-R9-F1）——
/// ⚠️ 这条是我 R7 那次修复**自己引入**的失败面：为了不让串里的 `//` 吞代码，我把串内容整段丢了，
///   于是 `logger.debug("deleted \(engine.deleteDrawing(id: id))")` 这种**真的会执行**的调用
///   反而从守卫底下溜走。字面量里既有"不是代码的文本"也有"确实是代码的插值"，必须分开处理。
/// 支持多行 `"""…"""` 与原始串（`hashes` 个 `#`，其转义/插值前缀是 `\` + 同样数量的 `#`）。
func consumeStringLiteral(_ c: [Character], from: Int, hashes: Int, into out: inout String) -> Int {
    var i = from
    let isMultiline = (i + 2 < c.count) && c[i + 1] == "\"" && c[i + 2] == "\""
    let quoteLen = isMultiline ? 3 : 1
    i += quoteLen
    while i < c.count {
        if c[i] == "\\" {                                        // `\…` ：插值前缀或普通转义
            var j = i + 1, h = 0
            while j < c.count, c[j] == "#", h < hashes { h += 1; j += 1 }
            if h == hashes {
                if j < c.count, c[j] == "(" {                    // 插值 → 递归当**代码**扫
                    i = scanCode(c, from: j + 1, parenDepth: 1, into: &out); continue  // `(` 之后起扫
                }
                i = min(j + 1, c.count); continue                // 普通转义：连吃被转义的那个字符
            }
        }
        if c[i] == "\"" {                                        // 收尾：quoteLen 个 `"` + hashes 个 `#`
            var j = i, q = 0
            while j < c.count, c[j] == "\"", q < quoteLen { q += 1; j += 1 }
            if q == quoteLen {
                var h = 0
                while j < c.count, c[j] == "#", h < hashes { h += 1; j += 1 }
                if h == hashes { return j }
            }
        }
        i += 1                                                   // 字面文本：丢弃
    }
    return c.count                                               // 未闭合（坏源码）：吃到底，fail-safe
}

func squeezedSource(_ path: String) throws -> String {
    squeezedText(try String(contentsOfFile: path, encoding: .utf8))
}

/// 一段源码里 `pattern` 的**调用**次数 = 总出现数 − **定义**出现数。
/// ⚠️ 定义只按 `"func" + pattern` 扣，**绝不可**另传一个「更宽的 defPattern」（codex plan-R3-F1 实证的真 bug）：
///   `func deleteDrawing(at index: Int)` squeeze 后是 `funcdeleteDrawing(atindex:` ——
///   它**不含**调用 pattern `deleteDrawing(at:`（`at index:` ≠ `at:`），却会命中宽 defPattern
///   `funcdeleteDrawing(at` → 一次**真实的** `deleteDrawing(at: 0)` 调用被扣成 `1-1=0`，
///   守卫恒绿，正好放过它要挡的那条绕过 id 唯一/locked/几何三门的破坏性入口。
///   现在的形状里「扣掉的」必然也是「数进来的」，不可能扣多。
func callCount(inSqueezed s: String, pattern: String) -> Int {
    let p = squeeze(pattern)
    let total = s.components(separatedBy: p).count - 1
    let defs  = s.components(separatedBy: "func" + p).count - 1
    return total - defs
}

/// `Sources/` 里 `pattern` 的调用点（按文件），零调用的文件不出现。
func callSiteCount(_ pattern: String) throws -> [(file: String, count: Int)] {
    try allSwiftFilesUnderSources().compactMap { path in
        let n = callCount(inSqueezed: try squeezedSource(path), pattern: pattern)
        return n > 0 ? (path, n) : nil
    }
}

/// 某文件（squeeze 后）是否含某段文本——访问级别断言用，同样与排版无关。
func squeezedContains(_ path: String, _ needle: String) throws -> Bool {
    try squeezedSource(path).contains(squeeze(needle))
}

/// 断言某声明**存在**且**不是包外可见的**（`public` / `package` / `open` 一个都不行）。
/// ⚠️ 只查 `public` 不够（codex plan-R8-F1，已对 `Package.swift` 实测）：本包
///   `swift-tools-version: 6.0` → **`package` 访问级别可用**，`package func updateDrawingStyle`
///   能让**另一个 target**（`KlineTrainerPersistence`）直接调这两个写入面，而几何门只存在于
///   `KlineTrainerContracts` 里那条 UI 路由上 → 信任边界被绕开而守卫仍绿。
func expectEngineInternalOnly(_ decl: String,
                                      sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(try squeezedContains(trainingEnginePath, "func " + decl),
            "\(decl) 不见了？（先证明真读到文件，防负向断言假绿）", sourceLocation: sourceLocation)
    for mod in ["public func ", "package func ", "open func "] {
        #expect(try !squeezedContains(trainingEnginePath, mod + decl),
                "\(decl) 不得是 \(mod)——包外/跨 target 可达即绕过几何门", sourceLocation: sourceLocation)
    }
    // ⚠️ 还要挡 `public extension`（Opus-F9）：`public extension TrainingEngine { func updateDrawingStyle… }`
    //    里成员默认继承 public，源码中**不出现** `public func` 字样 → 上面三条负向断言全过，API 却已包外可达。
    for mod in ["public extension TrainingEngine", "package extension TrainingEngine",
                "open extension TrainingEngine"] {
        #expect(try !squeezedContains(trainingEnginePath, mod),
                "TrainingEngine 的 extension 不得包外可见（成员会默认继承该访问级别）",
                sourceLocation: sourceLocation)
    }
}

/// `Sources/` 里**提到过**该标识符的文件（剥注释后按裸标识符找，不看后面跟不跟左括号）。
/// ⚠️ 为什么必须按「标识符」而不是「调用 pattern」（codex plan-R5-F1）：
///   `let f = engine.updateDrawingStyle` / `let g: (DrawingID, DrawingDefaultStyle) -> Bool = engine.updateDrawingStyle`
///   这类**方法引用**把调用挪到了别处，源码里根本不出现 `updateDrawingStyle(` —— 只数调用 pattern 的守卫
///   会放它过去，而这两个 API 的几何门**只**靠「唯一调用点在已验几何的 UI 路由」这条源码守卫成立。
///   按标识符扫，方法引用也必然让标识符出现在那个文件里 → 照样被抓。
func filesMentioning(_ identifier: String) throws -> [String] {
    try allSwiftFilesUnderSources().filter { try squeezedSource($0).contains(identifier) }
}

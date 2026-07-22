// ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/DrawingGestureSourceGuardTests.swift
// Spec: 2026-07-10-drawing-tools-P1b-split-addendum.md §5.1 #1 / §5.3 #1（D32）。
// 结构守卫：spec 要求「画线模式下单指 pan 不再被无条件截获」。行为测试测不到「代码里还留着一条截获通路」——
// 纯函数已经与画线状态**完全无关**（参数都删了），能证明这一点的只有源码文本。
// 反踩坑（memory: acceptance grep 两坑）：先**剥掉注释行**再匹配，否则解释性注释里的字样会误判。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("1a-iv D32 结构守卫：画线截获单指 pan 的通路已原子删除")
struct DrawingGestureSourceGuardTests {

    /// ios/Contracts 目录（由本测试文件路径回推：Tests/KlineTrainerContractsTests/ChartEngine/<本文件> → 上溯 4 层）。
    private var contractsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // ChartEngine
            .deletingLastPathComponent()    // KlineTrainerContractsTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // ios/Contracts
    }

    /// 读源码并**剥掉注释**后返回（整行注释丢弃；行尾 `//` 之后截断）。
    private func source(_ relativeToContracts: String) throws -> String {
        let url = contractsDir.appendingPathComponent(relativeToContracts)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }

    private let classifiers = "Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift"
    private let arbiter     = "Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift"

    @Test("GestureClassifiers 里不再有任何画线截获通路（类型 / 函数 / 参数全删）")
    func noTakeoverPathInClassifiers() throws {
        let code = try source(classifiers)
        #expect(code.contains("func singlePanStep("))     // 防路径写错→空内容→负向断言假绿
        #expect(!code.contains("drawingTakesOver"))
        #expect(!code.contains("DrawingModePanPolicy"))
        #expect(!code.contains("panPolicyInDrawingMode"))
    }

    @Test("ChartGestureArbiter.handleSinglePan **完全不读** drawingMode（tap 落锚路径仍读，故只锁单指 pan handler）")
    func singlePanHandlerIsDrawingAgnostic() throws {
        let code = try source(arbiter)
        guard let start = code.range(of: "func handleSinglePan("),
              let end = code.range(of: "func handleTwoFingerPan(") else {
            Issue.record("切片锚点找不到（handleSinglePan / handleTwoFingerPan 被改名？）—— 守卫失效，必须修")
            return
        }
        let body = String(code[start.lowerBound..<end.lowerBound])
        #expect(body.contains("singlePanStep("))          // 防切片为空 → 负向断言假绿
        #expect(!body.contains("drawingMode"))
        #expect(!body.contains("panPolicyInDrawingMode"))
        // 对照：drawingMode 本身没被删（tap 落锚仍要用它），否则这条守卫等于测了个空气
        #expect(code.contains("drawingMode"))
    }
}

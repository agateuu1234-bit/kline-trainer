// ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift
// PR-4：交互 UI 与视口发布的接线守卫。**刻意不是 UIKit-gated** —— 它读源码文本，不需要 UIKit 渲染，
// 放 host 才能在每个 Task 里立刻拿到证据（View 的真实渲染断言另有 Catalyst 测试）。
// 文本来源纪律见计划 PD7：否定/结构断言走 `code()`（剥注释剥字面量），用户可见文案走 `raw()`。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("PR-4 交互 UI 接线守卫")
struct DrawingInteractionUISourceGuardTests {

    /// **剥注释、剥字符串字面量内容、删空白**的代码文本。**所有否定断言与结构断言都必须用它**
    /// （PD7）：读原始文本会被计划里那些「为什么不是 X」的承重注释打红，逼实施者删注释才能过测试。
    private func code(_ rel: String) throws -> String {
        try squeezedSource(contractsDirForGuards.appendingPathComponent(rel).path)
    }

    /// 原始文本。**只用于两件事**：① 用户可见文案（`squeezedSource` 会丢弃字符串字面量内容，
    /// 文案断言在它上面恒假）；② 「陈旧注释必须删掉」这类**对象就是注释**的断言。
    private func raw(_ rel: String) throws -> String {
        try String(contentsOfFile: contractsDirForGuards.appendingPathComponent(rel).path, encoding: .utf8)
    }

    @Test("PD1（codex plan-R3-F2 的确定性防线）：Coordinator 发布的是 `newState.viewport`，且它**不许**自己重推视口")
    func publisherUsesRenderedViewportOnly() throws {
        let cc = try code("Sources/KlineTrainerContracts/Render/ChartContainerView.swift")
        #expect(cc.contains(squeeze("CoordinateMapper(viewport: newState.viewport,")),
                "必须发布这一帧渲染真用过的视口")
        // 重推的入口一次都不许在本文件的**代码**里出现（注释里解释「为什么不重推」是正当的，故剥注释后判）
        #expect(!cc.contains("makeViewport"),
                "ChartContainerView 里出现了 makeViewport —— 重推的视口在聚合分支下与屏幕上的不一致（见 renderedViewportDivergesFromReDerivation）")
    }
}

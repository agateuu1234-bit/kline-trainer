// Tests/KlineTrainerContractsTests/Render/DrawingStyleCardSourceGuardTests.swift
// Spec: 母 spec §3 / split-addendum §4.1.4 / §4.3-7,8（灰态矩阵 + 面板文案洁净：无「不适用」字）。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("DrawingStyleCard 结构守卫：4 组控件 / 灰态判据消费 / 无解释文案")
struct DrawingStyleCardSourceGuardTests {
    private var srcDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ rel: String) throws -> String {
        let text = try String(contentsOf: srcDir.appendingPathComponent(rel), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }
    private let card = "Sources/KlineTrainerContracts/UI/DrawingStyleCard.swift"

    @Test("四组控件标签齐 + 消费灰态判据 + 写 setDefaultStyle")
    func hasGroupsAndWiring() throws {
        let code = try source(card)
        for label in ["线型", "线样式", "粗细", "颜色", "标注"] { #expect(code.contains(label)) }
        #expect(code.contains("DrawingStyleAvailability"))         // 灰态真被消费
        #expect(code.contains("normalizedLabelMode"))              // 切线型真规整 labelMode（codex plan-R1）
        #expect(code.contains("session.setDefaultStyle"))          // 选择真写单一真相
        #expect(code.contains("onDismiss"))                        // 遮罩关闭
    }

    @Test("面板文案洁净：无「不适用」类解释字（母 spec §3 逐字）")
    func noNotApplicableCopy() throws {
        let code = try source(card)
        for banned in ["不适用", "不可用", "N/A", "暂不支持"] { #expect(!code.contains(banned)) }
    }
}

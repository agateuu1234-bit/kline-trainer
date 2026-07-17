// Tests/KlineTrainerContractsTests/Render/DrawingModeBarSourceGuardTests.swift
// Spec: split-addendum §4.1.2 / §4.3-3,4（D24/D19：类型行只 1 图标、下行只①类型键、②–⑤不渲染）。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("DrawingModeBar 结构守卫：类型行 1 图标 / 下行只①类型键 / 无 ②–⑤")
struct DrawingModeBarSourceGuardTests {
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
    private let bar = "Sources/KlineTrainerContracts/UI/DrawingModeBar.swift"

    @Test("类型行恒亮的水平线图标存在、①类型键存在")
    func hasExpectedControls() throws {
        let code = try source(bar)
        #expect(code.contains("accessibilityLabel(\"水平线\")"))
        #expect(code.contains("accessibilityLabel(\"类型\")"))
        #expect(code.contains("onLongPressType"))
    }

    @Test("②锁定/③删除/④撤销/⑤前进 图标本期不渲染（D19）")
    func noUnwiredKeys() throws {
        let code = try source(bar)
        for banned in ["accessibilityLabel(\"锁定\")", "accessibilityLabel(\"删除\")",
                       "accessibilityLabel(\"撤销\")", "accessibilityLabel(\"前进\")"] {
            #expect(!code.contains(banned))
        }
    }
}

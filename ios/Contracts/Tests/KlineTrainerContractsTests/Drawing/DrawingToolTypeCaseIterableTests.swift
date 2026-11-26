// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolTypeCaseIterableTests.swift
// Spec: 2026-08-30-drawing-tools-P1c-1A-tool-matrix-design.md D118
// 为什么需要：样式矩阵真值表（DrawingToolStyleMatrixTests）必须遍历**生产枚举**才算真断言。
import Testing
@testable import KlineTrainerContracts

@Suite("DrawingToolType 形态锁定（D118）")
struct DrawingToolTypeCaseIterableTests {

    @Test("allCases 恰好 13 个 —— 11 个目标工具 + 2 个 legacy（ray / time）")
    func caseCountIsThirteen() {
        #expect(DrawingToolType.allCases.count == 13)
    }

    @Test("allCases 内容逐个对齐已声明的 case（防漏、防多、防改名）")
    func caseSetIsExact() {
        let expected: Set<DrawingToolType> = [
            .horizontal, .trend, .channel, .polyline, .golden, .wave,
            .cycle, .fib, .timeRuler, .rect, .text,          // 目标 11 工具（Models.swift:39）
            .ray, .time,                                      // legacy：历史 blob 容忍解码（Models.swift:41）
        ]
        // 反向自检：期望集自己没被写重复（否则 count 会掉到 12 而断言仍可能过）
        #expect(expected.count == 13)
        #expect(Set(DrawingToolType.allCases) == expected)
    }

    @Test("D118 边界：implemented 仍恰好是 [.horizontal]，本片不得顺手改")
    func implementedUnchanged() {
        #expect(DrawingToolType.implemented == [.horizontal])
    }
}

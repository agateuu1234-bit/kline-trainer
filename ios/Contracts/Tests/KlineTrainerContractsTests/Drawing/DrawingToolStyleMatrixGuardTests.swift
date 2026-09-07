// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolStyleMatrixGuardTests.swift
// Spec: 2026-08-30-drawing-tools-P1c-1A-tool-matrix-design.md §5-T2 / T2b / T1f
// ⚠️ 判据一律用**结构计数**，⛔ 不得写成「某文件里不许出现某个词」的禁词黑名单
//    （后者可被删注释 / 改写法绕过，也会被承重注释误伤）。
// ⚠️ 扫描一律经共享扫描器 squeezedSource()：剥行注释 / 嵌套块注释 / 字符串字面量内容，并删光空白。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("P1c 第 1 片结构守卫：单一真相 / 有效性列未接 UI / 锚数边界")
struct DrawingToolStyleMatrixGuardTests {

    private func fileNamed(_ suffix: String, in files: [String]) throws -> String {
        try #require(files.first { $0.hasSuffix(suffix) }, "扫描不到 \(suffix)（路径锚点失效）")
    }

    @Test("T2 单一真相：查表调用恰好 2 处且都在定义文件；工具集由表的键派生")
    func t2_singleSourceOfTruth() throws {
        let files = try allSwiftFilesUnderSources()
        #expect(!files.isEmpty)                       // 反向自检：真的扫到文件了

        var hits: [String: Int] = [:]
        for path in files {
            let n = try squeezedSource(path).components(separatedBy: squeeze("styleRules[")).count - 1
            if n > 0 { hits[URL(fileURLWithPath: path).lastPathComponent] = n }
        }
        // isRenderableSubType 与 normalizedLabelMode(三参) 各查一次，且只许出现在定义文件里
        #expect(hits == ["DrawingStyleAvailability.swift": 2], "查表点分布异常：\(hits)")

        let availPath = try fileNamed("Drawing/DrawingStyleAvailability.swift", in: files)
        let avail = try squeezedSource(availPath)
        // 工具集必须**派生**自表的键，不得是第二份写死清单
        #expect(avail.contains(squeeze("Set(styleRules.keys)")),
                "toolsWithStyleMatrix 必须由表的键派生")
        // 反向自检：这个文件确实含已知锚点（防「路径写对了但读到空文件也全绿」）
        #expect(avail.contains(squeeze("func isRenderableSubType(")))
        #expect(avail.contains(squeeze("func horizontalLineSubTypeEnabled(")))
        #expect(avail.contains(squeeze("func horizontalLabelModeEnabled(")))
    }
}

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

    @Test("T2b 有效性列没有被接到 UI 上（D120 的落地闸门）")
    func t2b_validityPredicateNotUsedByUI() throws {
        let files = try allSwiftFilesUnderSources()
        #expect(!files.isEmpty)

        var byFile: [String: Int] = [:]
        var uiHits: [String] = []
        for path in files {
            let n = try squeezedSource(path).components(separatedBy: squeeze("isRenderableSubType(")).count - 1
            guard n > 0 else { continue }
            byFile[URL(fileURLWithPath: path).lastPathComponent] = n
            if path.contains("/Sources/KlineTrainerContracts/UI/") { uiHits.append(path) }
        }
        // ① UI 层零命中 —— 有效性判据不得当灰态用
        #expect(uiHits.isEmpty, "有效性判据被接到 UI 层，违反 D120：\(uiHits)")
        // ② 反向自检：四处写入闸各自命中。
        //    只写「UI 零命中」会与「这个函数被整个删掉」这种坏实现**同时为绿**。
        #expect(byFile["TrainingEngine.swift"] != nil, "append 门不再经共享单点？\(byFile)")
        #expect(byFile["DrawingObjectStyleEdit.swift"] != nil, "withStyle 可用性闸不见了？\(byFile)")
        #expect(byFile["DrawingEnums.swift"] != nil, "sanitized(for:) 不再经共享单点？\(byFile)")
        #expect(byFile["DrawingStyleAvailability.swift"] != nil, "定义处不见了？\(byFile)")
    }

    @Test("T1f 边界：本片不碰锚数（D119）——定义仍只在输入控制器里，且它不引用样式表")
    func t1f_anchorCountBoundary() throws {
        let files = try allSwiftFilesUnderSources()
        #expect(!files.isEmpty)

        var defs: [String] = []
        for path in files where try squeezedSource(path).contains(squeeze("func minAnchors(")) {
            defs.append(URL(fileURLWithPath: path).lastPathComponent)
        }
        // ① 锚数定义恰好一处，且仍在原文件
        #expect(defs == ["DefaultDrawingInputController.swift"], "锚数定义处异常：\(defs)")

        let ctrlPath = try fileNamed("Drawing/DefaultDrawingInputController.swift", in: files)
        let ctrl = try squeezedSource(ctrlPath)
        // ② 该文件不得引用样式表 —— 锚数不是样式，单一真相归第 4 片的 requiredAnchors（D119/Q12）
        #expect(!ctrl.contains(squeeze("styleRules")), "锚数不得从样式表取值（D119 边界）")
        // ③ 反向自检：文件真被扫到（防「路径写错 → 零命中 → 恒过」）
        #expect(ctrl.contains(squeeze("func shouldCommit(")), "锚点失效：扫不到 shouldCommit")
    }
}

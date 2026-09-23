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
        // ① **消费方恰好是这四个文件**（spec §5-T2b 的前半条）。
        //    ⛔ 不得退化成「这四个各自 != nil」的存在性检查（本片首版就是那样写的，被对抗性评审
        //       用双臂变异实证打穿）：存在性检查抓不到**多出来的第五个消费方**，于是这条守卫的
        //       有效覆盖面塌缩成「仅 Sources/KlineTrainerContracts/UI/ 一个目录」。而 D120 那个矛盾
        //       （箱体要么画不出、要么面板错误可点）的第一现场恰恰**不在** UI/ ——
        //       `Render/KLineView+Drawing.swift:33` 就是「按 toolType 决定画不画」的渲染分支，
        //       把有效性判据接进渲染层是最自然的手滑方向，而旧写法对此一声不吭。
        //    ⇒ 精确集合断言同时兑现「恰好四处」+ 自动覆盖 Render/ 及任何未来新目录。
        //    ⚠️ 这四个文件 = **三处写入闸所在文件**（`TrainingEngine` 的两道 append 门 /
        //       `DrawingObjectStyleEdit` 的 withStyle 闸 / `DrawingEnums` 的 sanitized）
        //       **+ 定义处本身**（`DrawingStyleAvailability`，其命中就是 `func` 那一行）。
        //       ⛔ 别把这个集合读成「四处写入闸」——写入闸是 4 个**调用点**、分布在 3 个文件里。
        #expect(Set(byFile.keys) == ["TrainingEngine.swift", "DrawingObjectStyleEdit.swift",
                                     "DrawingEnums.swift", "DrawingStyleAvailability.swift"],
                "有效性判据的出现位置不再恰好是这四个文件（三处写入闸 + 定义处）。多出来的那个很可能是把它当 UI 灰态用了，违反 D120：\(byFile)")
        // ② UI 层零命中 —— 单列一条只为把「接进 UI」这个最典型的违规给出可读的失败文案。
        //    ⚠️ 它**不是**覆盖面的来源：覆盖面由上面那条集合断言承担。
        #expect(uiHits.isEmpty, "有效性判据被接到 UI 层，违反 D120：\(uiHits)")
        // ③ 反向自检：两道 append 门**逐个**仍在（⛔ 不能只看 TrainingEngine.swift 的命中数非零 ——
        //    该文件有 4 处命中，其中 :1299 是私有 helper 的定义、:1300 是它的转发，
        //    把 :1157/:1265 两道门整个删掉后计数仍为 2，旧写法照样绿）。
        let engineCode = try squeezedSource(try fileNamed("TrainingEngine/TrainingEngine.swift", in: files))
        #expect(engineCode.components(separatedBy: squeeze("guard isRenderableSubType(drawing) else { return false }")).count - 1 == 2,
                "两道 append 门不再各自经共享单点（D67）")
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

import Testing
import Foundation
@testable import KlineTrainerContracts

/// P1c 第 2 片（R6）：选中态节点**必须**画在所有持久内容之上、瞬时光标之下。
/// ⚠️ 这是**源码顺序**守卫：`KLineView.draw` 各阶段的先后决定谁盖谁，而顺序无法由纯函数表达。
/// 判据读的是**仓内源文件本体**（不是编译产物、不是注释复述），路径按既有守卫的同一套算法推得。
@Suite("SelectionNode draw order")
struct SelectionNodeDrawOrderGuardTests {

    static var contractsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Render
            .deletingLastPathComponent()    // KlineTrainerContractsTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // ios/Contracts
    }

    @Test("⭐节点必须在 drawMarkers / drawAxisLabels 之后、drawCrosshair 之前")
    func selectionNodesDrawAfterMarkersAndLabels() throws {
        let url = Self.contractsRoot
            .appendingPathComponent("Sources/KlineTrainerContracts/Render/KLineView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        // 从 draw(_:) 的声明处截到文件末尾再找调用序，避免被【它之前】的同名字符串干扰。
        // ⚠️ 今天 draw(_:) 恰好是本文件最后一个函数，故这段等价于函数体；
        //    将来若在它后面新增函数，本判据需收紧到真正的函数体边界。
        guard let bodyStart = src.range(of: "public override func draw(_ rect: CGRect)") else {
            Issue.record("找不到 draw(_:) —— 判据的文本来源坏了，⛔ 不得当作通过"); return
        }
        let body = String(src[bodyStart.lowerBound...])
        func pos(_ needle: String) -> Int? {
            body.range(of: needle).map { body.distance(from: body.startIndex, to: $0.lowerBound) }
        }
        guard let markers = pos("drawMarkers("),
              let labels  = pos("drawAxisLabels("),
              let nodes   = pos("drawSelectionNodes("),
              let cross   = pos("drawCrosshair(") else {
            Issue.record("四个绘制阶段必须都能在 draw(_:) 里找到；缺任何一个都说明判据失效"); return
        }
        #expect(nodes > markers,
                "节点必须画在交易标记【之后】—— 标记是直径 10pt 的实心圆，会把 7pt 的节点整个盖掉")
        #expect(nodes > labels, "节点必须画在轴标签之后 —— 代理三角贴边框，与轴标签同区域")
        #expect(nodes < cross, "节点必须画在十字光标【之前】—— 光标是瞬时交互反馈，不该被压住")
    }
}

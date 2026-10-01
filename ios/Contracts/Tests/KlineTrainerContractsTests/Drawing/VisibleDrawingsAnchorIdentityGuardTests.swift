// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/VisibleDrawingsAnchorIdentityGuardTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（Q24，task-9-brief.md 控制者订正 2 / 订正 5）
//
// 平台门：host-pure —— 只碰 TrainingEngine / RenderStateBuilder.visibleDrawings，无 UIKit 类型，
// macOS `swift test` 直接覆盖（与同目录下需要 Coordinator/KLineView 的 UIKit-gated 套件分开）。
//
// 本守卫钉住的契约（Q24）：`visibleDrawings` 只做 `filter`（面板归属 + revealTick 渐显），
// **绝不改锚点** —— `DrawingNodeGeometry.hitTestNode` 返回的下标才能原样喂给
// `engine.updateDrawingAnchor(anchorIndex:)`（Task 10）而不错位。
// ⚠️ 判据按控制者订正 5 收紧：只在「拖动不在进行中」时成立——Task 10 会让 visibleDrawings 在
// 拖动进行中返回「改过锚点的副本」，那一半由 Task 10 自己的测试承接，本守卫**不**覆盖、**不**预写。
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("Q24 下标契约守卫：visibleDrawings 只过滤、绝不改锚点")
struct VisibleDrawingsAnchorIdentityGuardTests {

    /// 造「上/下面板各 2 条线，锚点数各不相同（1/2/3/2），其中 1 条（上面板）revealTick 在未来」。
    /// 锚点数故意不同只是为了让「被 `.map` 改写」更容易被 `anchors` 相等断言抓到——
    /// 工具类型与锚点数不必语义自洽（本测试不碰渲染/命中，只碰 `visibleDrawings` 的过滤+相等）。
    private func makeEngine() -> TrainingEngine {
        let e = TrainingEngine.preview()
        let upperPeriod = e.upperPanel.period
        let lowerPeriod = e.lowerPanel.period
        func anchors(_ n: Int, period: Period) -> [DrawingAnchor] {
            (0..<n).map { DrawingAnchor(period: period, candleIndex: 0, price: 10 + Double($0)) }
        }
        e.injectDrawingsForTesting([
            DrawingObject(id: "U1", toolType: .horizontal, anchors: anchors(1, period: upperPeriod),
                         isExtended: false, panelPosition: 0, revealTick: 0, period: upperPeriod),
            // revealTick 远在未来（> tick.globalTickIndex==0）⇒ 必须被滤掉，证明「过滤真的在过滤」。
            DrawingObject(id: "U2", toolType: .horizontal, anchors: anchors(2, period: upperPeriod),
                         isExtended: false, panelPosition: 0, revealTick: 999_999, period: upperPeriod),
            DrawingObject(id: "L1", toolType: .horizontal, anchors: anchors(3, period: lowerPeriod),
                         isExtended: false, panelPosition: 1, revealTick: 0, period: lowerPeriod),
            DrawingObject(id: "L2", toolType: .horizontal, anchors: anchors(2, period: lowerPeriod),
                         isExtended: false, panelPosition: 1, revealTick: 0, period: lowerPeriod),
        ])
        return e
    }

    @Test("拖动不在进行中时：visibleDrawings 返回的每一条都与 engine.drawings 同 id 那条**整体 ==** 相等")
    func visibleDrawingsPreservesAnchorsIdentically() throws {
        let e = makeEngine()
        // ⭐ 判据的适用范围写进代码里（订正5）：契约只在拖动不进行中成立，Task 10 的另一半不在本守卫内。
        #expect(e.drawingSession.nodeDragOwner == nil,
                "前提：本契约只覆盖「拖动不在进行中」——Task 10 会让 visibleDrawings 在拖动中返回改过的副本")

        for panel: PanelId in [.upper, .lower] {
            let visible = RenderStateBuilder.visibleDrawings(engine: e, panel: panel, tick: e.tick.globalTickIndex)
            // 反向对照（订正2 ⭐）：条数必须严格小于 engine.drawings 总数，证明这份夹具里真的有被滤掉的条目，
            // 不是「全部放行」的恒真实现在骗断言。
            #expect(visible.count < e.drawings.count,
                    "反向对照：\(panel) 的 visibleDrawings 条数必须严格小于 engine.drawings 总数")
            #expect(!visible.isEmpty, "前提：\(panel) 至少要有一条通过过滤，否则下面的逐条断言是空转")
            for d in visible {
                let original = e.drawings.first(where: { $0.id == d.id })!
                // ⭐ 逐字段整体相等（不只比 anchors）——任何字段被变换都该让这条红。
                #expect(original == d, "visibleDrawings 不得改写任何字段（Q24）：id=\(d.id)")
                #expect(original.anchors == d.anchors, "visibleDrawings 不得改写锚点（Q24）：id=\(d.id)")
            }
        }
    }
}

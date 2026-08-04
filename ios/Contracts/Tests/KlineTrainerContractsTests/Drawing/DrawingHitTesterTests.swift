// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingHitTesterTests.swift
// Spec: docs/superpowers/specs/2026-07-23-drawing-tools-P1b-1b-i-select-edit-delete-design.md §3 / D33 / D40
// 命中判定的纯逻辑（无 UIKit → host 全跑）。真实 tap 路径的接线测试在
// Render/ChartContainerViewDrawingSessionTests.swift（UIKit-gated，Catalyst 才真跑）。

import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("DrawingHitTester（D33 逆序最上层优先 / D40 与渲染同源）")
struct DrawingHitTesterTests {

    static func mapper() -> CoordinateMapper {
        let viewport = ChartViewport(
            startIndex: 0, visibleCount: 80, pixelShift: 0,
            geometry: ChartGeometry(candleStep: 10, candleWidth: 7, gap: 3),
            priceRange: PriceRange(min: 90, max: 110),
            mainChartFrame: CGRect(x: 0, y: 0, width: 800, height: 200))
        return CoordinateMapper(viewport: viewport, displayScale: 2)
    }

    static func hLine(_ id: String, price: Double, sub: LineSubType = .straight,
                      candleIndex: Int = 5) -> DrawingObject {
        DrawingObject(id: id, toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m60, candleIndex: candleIndex, price: price)],
                      isExtended: sub == .ray, panelPosition: 0, lineSubType: sub)
    }

    static let tools: [DrawingToolType: any DrawingTool] = [.horizontal: HorizontalLineTool()]

    @Test("D33：两条重合线 → 命中**后画的那条**（数组序 = z-order，逆序取最上层）")
    func topmostWins() {
        let m = Self.mapper()
        let first = Self.hLine("FIRST", price: 100)
        let second = Self.hLine("SECOND", price: 100)
        let p = CGPoint(x: 400, y: m.priceToY(100))
        #expect(DrawingHitTester.firstHit(in: [first, second], point: p, mapper: m, tools: Self.tools)?.id == "SECOND")
        // 反转输入顺序 → 结果跟着反转（证明判据真的是"数组序"，不是"按 id 排序"之类的巧合）
        #expect(DrawingHitTester.firstHit(in: [second, first], point: p, mapper: m, tools: Self.tools)?.id == "FIRST")
    }

    @Test("未命中 → nil；命中容差外的线不算命中")
    func missReturnsNil() {
        let m = Self.mapper()
        let p = CGPoint(x: 400, y: m.priceToY(100) + 50)      // 远离横线 y，超 8pt 容差
        #expect(DrawingHitTester.firstHit(in: [Self.hLine("A", price: 100)], point: p, mapper: m, tools: Self.tools) == nil)
        #expect(DrawingHitTester.firstHit(in: [], point: p, mapper: m, tools: Self.tools) == nil)
    }

    @Test("D40：注册表里没有的工具**不命中** —— 与渲染 dispatch 的 `guard let tool … else { continue }` 同判据")
    func unregisteredToolNeverHits() {
        let m = Self.mapper()
        let p = CGPoint(x: 400, y: m.priceToY(100))
        // 空注册表 = 渲染层什么都画不出来 → 命中层也必须什么都命不中
        #expect(DrawingHitTester.firstHit(in: [Self.hLine("A", price: 100)], point: p, mapper: m, tools: [:]) == nil)
        #expect(DrawingHitTester.firstHit(in: [Self.hLine("A", price: 100)], point: p, mapper: m,
                                          tools: Self.tools)?.id == "A")   // 反向对照，防"一律不命中"骗过
    }

    @Test("D40 源码守卫：命中入口在 Sources/ 中各只有一处（防另开一条绕过 visibleDrawings 的命中路径）")
    func hitDispatchIsSinglePoint() throws {
        // ① `hitTest(` 的**调用**点恰好 1 处 = DrawingHitTester 内（协议声明与 HorizontalLineTool 的
        //    实现都带 `func`，被 callCount 扣掉，不计入调用）。
        let hits = try callSiteCount("hitTest(")
        try #require(hits.count == 1, "hitTest 的调用点不是 1 处：\(hits)")
        #expect(hits.first?.file.hasSuffix("/Drawing/DrawingHitTester.swift") == true)
        #expect(hits.first?.count == 1)
        // ② `firstHit(` 的调用点恰好 1 处 = tap 路由（`ChartContainerView.swift` 的 `.select` 分支）。
        //    PR-4 若要再加一个命中入口，这条当场红 —— 那个入口必须同样先过 `visibleDrawings`。
        let entries = try callSiteCount("firstHit(")
        try #require(entries.count == 1, "firstHit 的调用点不是 1 处：\(entries)")
        #expect(entries.first?.file.hasSuffix("/Render/ChartContainerView.swift") == true)
        #expect(entries.first?.count == 1)
        // ③ **只数调用点不够（codex plan-R5-F1）**：`firstHit(in: engine.drawings, …)` 同样只有 1 处调用点，
        //    却绕过了 belongsToPanel + revealTick 过滤 → 能选中本面板根本没渲染的线。故必须钉**入参来源**：
        //    唯一那处调用的列表必须来自 `RenderStateBuilder.visibleDrawings`。
        let route = try squeezedSource(entries[0].file)
        #expect(route.contains(squeeze("let ordered = RenderStateBuilder.visibleDrawings(")),
                "命中列表必须来自 visibleDrawings（D40 单一真相）")
        #expect(route.contains(squeeze("DrawingHitTester.firstHit(in: ordered,")),
                "firstHit 必须消费上面那个 ordered，不得另喂一个集合")
        // 反向：路由里不得直接把引擎数组喂进命中（这才是真正要挡的形状）
        #expect(!route.contains(squeeze("firstHit(in: engine.drawings")))
        #expect(!route.contains(squeeze("firstHit(in: engine.reviewDrawings")))
        #expect(!route.contains(squeeze("firstHit(in: view.renderState.drawings")))
        // ③ 自足断言：扫描器真的扫到东西了（防扫描根写错 → 空集合 → 上面 `count == 1` 直接红而非假绿，
        //    但仍显式钉一条，与既有守卫的纪律一致）。
        #expect(try !allSwiftFilesUnderSources().isEmpty)
    }

    @Test("D40/§8 #2：渲染不出的线同样命不中（visibleGeometry == nil），且不会挡住它下面那条")
    func invisibleGeometryDoesNotHitNorShadow() {
        let m = Self.mapper()
        let p = CGPoint(x: 400, y: m.priceToY(100))
        let ghost = Self.hLine("GHOST", price: 100, sub: .segment)      // 水平线的 .segment 恒不可渲染
        let real = Self.hLine("REAL", price: 100)
        #expect(DrawingHitTester.firstHit(in: [ghost], point: p, mapper: m, tools: Self.tools) == nil)
        // ghost 排在最上层，但它命不中 → 必须继续往下找到 REAL（不能"最上层没中就返回 nil"）
        #expect(DrawingHitTester.firstHit(in: [real, ghost], point: p, mapper: m, tools: Self.tools)?.id == "REAL")
    }
}

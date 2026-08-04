// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingHitTester.swift
// Spec: docs/superpowers/specs/2026-07-23-drawing-tools-P1b-1b-i-select-edit-delete-design.md §3（D40）+ D33
//
// 跨平台：仅 CoreGraphics（与 DrawingTool / HorizontalLineTool 一致，无 UIKit）→ host swift test 全覆盖。
// 真实 tap 路径的接线在 Render/ChartContainerView.swift 的 Coordinator（UIKit 层），那里只做"取集合 + 调本函数"。

import CoreGraphics

/// D33/D40（1b-i PR-3）：在**渲染序**列表上做命中判定。
///
/// 命中与渲染同源的三件套，缺一即分叉：
///   ① **同一个集合** —— 入参 `ordered` 必须来自 `RenderStateBuilder.visibleDrawings`（唯一真相）；
///   ② **同一张注册表** —— `tools` 必须是 `KLineView.drawingTools`（渲染 dispatch 用的那张）；
///   ③ **同一个几何判据** —— 各 tool 的 `hitTest` 与 `render` 共用 `visibleGeometry`（1a-i 已建）。
///
/// **逆序**遍历：数组序 = z-order，后画的在上，故最上层优先。
/// 已知限制（spec §8 #1，非缺陷）：不做选中循环 —— 容差内的两条线，单击**恒**选中最上层那条。
@MainActor
enum DrawingHitTester {
    static func firstHit(in ordered: [DrawingObject], point: CGPoint, mapper: CoordinateMapper,
                         tools: [DrawingToolType: any DrawingTool]) -> DrawingObject? {
        ordered.reversed().first { drawing in
            // 注册表里没有的工具**不命中** —— 与渲染 dispatch 的 `guard let tool = tools[...] else { continue }`
            // 逐字同判据（画不出的就选不中，spec §8 #2）。这里 fail-closed 成"不命中"而不是"跳过继续找"，
            // 因为 `first(where:)` 本来就会继续找下一条：返回 false 只是说"这一条不算命中"。
            guard let tool = tools[drawing.toolType] else { return false }
            return tool.hitTest(point: point, mapper: mapper, drawing: drawing)
        }
    }
}

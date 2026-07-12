// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DefaultDrawingInputController.swift
// Spec: docs/superpowers/specs/2026-06-13-wave3-pr4-drawing-mvp-design.md §一.2 + §四
// Wave 3 顺位 4：具体 DrawingInputController。tapToAnchor 经 CoordinateMapper 逆映射；
// shouldCommit 经显式 enum→最小锚数映射（requiredAnchors 在 DrawingTool 实例非 enum，评审 R2-L）。
//
// 跨平台：CoreGraphics + 跨平台值类型；无 UIKit。protocol 是 @MainActor → 本类 @MainActor final class。

import CoreGraphics

@MainActor
public final class DefaultDrawingInputController: DrawingInputController {
    public init() {}

    public func tapToAnchor(at point: CGPoint, panel: PanelViewState, mapper: CoordinateMapper) -> DrawingAnchor? {
        // codex branch-R4-high：落锚必须落在主图内。成交量/MACD 区的 tap 换算出的价格在可见价格区间之外，
        // 提交后既不渲染也不可命中（visibleGeometry fail-closed）→ 会在持久化数据里留下看不见的幽灵线。
        guard mapper.viewport.mainChartFrame.contains(point) else { return nil }
        return DrawingAnchor(period: panel.period,
                      candleIndex: mapper.xToIndex(point.x),
                      price: mapper.yToPrice(point.y))
    }

    /// MVP 显式映射 enum→最小锚数（requiredAnchors 是 tool 实例属性、非 enum 可达）。
    private func minAnchors(for tool: DrawingToolType) -> Int {
        switch tool {
        case .horizontal: return 1
        // 其余工具属 Phase 4（enabledTools 仅 .horizontal，不会到达）；drawing-P1a 新增 6 工具
        // （channel/polyline/fib/timeRuler/rect/text）暂沿用同一未决锚数占位，真实值待专属 task 定义。
        case .ray, .trend, .golden, .wave, .cycle, .time,
             .channel, .polyline, .fib, .timeRuler, .rect, .text: return Int.max
        }
    }

    public func shouldCommit(current: [DrawingAnchor], tool: DrawingToolType) -> Bool {
        current.count >= minAnchors(for: tool)
    }
}

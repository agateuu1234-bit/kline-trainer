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
        // codex R7-medium：持续画线模式下 `.drawing` reducer 吞 `.offsetApplied`（转屏/resize 成正常路径），
        // 主图内可出现 overscroll 空白区（无 candle）；点空白区 xToIndex 映射出**越界** candleIndex
        // （指向不存在的 candle），落锚提交即持久化坏数据（复盘 diff / hitTest / 跨版本迁移都踩）。
        // fail-closed：candleIndex 必须落在可见 slice 的 base 索引区间 `[startIndex, startIndex+visibleCount)`
        // （≡ renderState.visibleCandles.indices；**不可**改用 candle.globalIndex —— 进行中聚合根被
        // PartialAggregateCandle.synthesize 替换后 globalIndex 为 nil），否则不产锚（在源头拒坏数据，非 call-site 补丁）。
        let candleIndex = mapper.xToIndex(point.x)
        let vp = mapper.viewport
        guard vp.visibleCount > 0,
              candleIndex >= vp.startIndex,
              candleIndex < vp.startIndex + vp.visibleCount else { return nil }
        return DrawingAnchor(period: panel.period,
                      candleIndex: candleIndex,
                      price: mapper.yToPrice(point.y))
    }

    /// MVP 显式映射 enum→最小锚数（requiredAnchors 是 tool 实例属性、非 enum 可达）。
    /// **单一真相派生（codex whole-branch R2-high）**：非 `.implemented` 的工具恒 `Int.max`
    /// （永不提交）——不得在此处另写一份工具清单，否则会和 `TrainingEngine.beginDrawingSession`
    /// 的入口守卫各自维护、必然漂移。真实最小锚数待各工具专属 task 定义（1a-iii/1a-iv）。
    private func minAnchors(for tool: DrawingToolType) -> Int {
        guard DrawingToolType.implemented.contains(tool) else { return Int.max }
        switch tool {
        case .horizontal: return 1
        default: return Int.max   // 结构上不可达（implemented 目前只含 .horizontal），留作未来扩容占位
        }
    }

    public func shouldCommit(current: [DrawingAnchor], tool: DrawingToolType) -> Bool {
        current.count >= minAnchors(for: tool)
    }
}

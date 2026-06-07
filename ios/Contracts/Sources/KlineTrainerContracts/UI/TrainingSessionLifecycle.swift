// Kline Trainer Swift Contracts — U2 会话生命周期接线（Wave 2 顺位 9）
// Spec: docs/superpowers/specs/2026-06-02-wave2-outline-design.md §四 L124（U2 接线 E6
//       saveProgress/finalize/endSession，5 路径矩阵）+ kline_trainer_plan_v1.5.md §6.2.1/§6.2.5。
//
// 平台无关纯接线层（host 全测）：把 U2 的 UI 事件串接到 frozen E6 TrainingSessionCoordinator（PR #86）。
// 决议（D2/D3/D4/D5/D12）：
// - D2 不呈现 SettlementView（顺位 11 路由+repo owner 负责）；finalizeForSettlement 仅返 recordId? 上交。
// - D3 back = saveProgress（非 Normal no-op）+ endSession；统一调用，review/replay 走非保存分支。
// - D4 isAtEnd = tick 到 maxTick；D5 shouldAutoFinalize 把模式门+一次性门下放 host 测纯函数。

import Foundation

@MainActor
public struct TrainingSessionLifecycle {
    public let engine: TrainingEngine
    public let coordinator: TrainingSessionCoordinator

    public init(engine: TrainingEngine, coordinator: TrainingSessionCoordinator) {
        self.engine = engine
        self.coordinator = coordinator
    }

    /// 局是否已到末态（globalTickIndex 抵 maxTick）。调用方据 `engine.flow.mode` 决定是否触发结算（D4）。
    public var isAtEnd: Bool {
        engine.tick.globalTickIndex >= engine.tick.maxTick
    }

    /// 是否应触发自动结算（D5）：到末态 + 非 Review（Review 固定末态 isAtEnd 恒真但结算弹窗 ❌）+ 未结算过
    /// （一次性门，防 onChange 末态多次触发）。纯函数 host 全测；TrainingView.maybeAutoEnd 仅作壳触发器。
    public func shouldAutoFinalize(didFinalize: Bool) -> Bool {
        isAtEnd && engine.flow.mode != .review && !didFinalize
    }

    /// 返回按钮（plan v1.5 §6.2.1 L920）：保存进度（Normal 真存；review/replay 在 coordinator 内 no-op）
    /// 然后结束会话（D3）。
    public func back() async throws {
        try await coordinator.saveProgress(engine: engine)
        await coordinator.endSession()
    }

    /// 自动结束（plan v1.5 §6.2.5）：正式结束入账，返 recordId（Normal）/ nil（review/replay 非保存分支）。
    /// 不 endSession —— 结算确认后才结束（D2）。
    public func finalizeForSettlement() async throws -> Int64? {
        try await coordinator.finalize(engine: engine)
    }

    /// 结算确认后（plan v1.5 §6.3）：结束会话（reader 关闭 + 清活跃上下文）。
    public func endAfterSettlement() async {
        await coordinator.endSession()
    }
}

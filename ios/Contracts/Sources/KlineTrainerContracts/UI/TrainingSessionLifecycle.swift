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

    /// 是否应触发自动结算（D5）：到末态 + 该模式应弹结算窗 + 未结算过（一次性门，防 onChange 末态多次触发）。
    /// 用权威能力谓词 `flow.shouldShowSettlement()`（Normal=true / Review=false / Replay=true，capability
    /// matrix L842）而非硬编码 `mode != .review`，与 `buyEnabled` 用 `canBuySell()` 同范式——单一真值源、
    /// 抗矩阵/新模式漂移（code-review Task1 建议）。Review 固定末态 isAtEnd 恒真，靠此谓词为 false 抑制误结算。
    /// **Replay**：谓词 true → shouldAutoFinalize 同走真分支，但 `finalizeForSettlement` 因 `shouldSaveRecord()==false`
    /// 返 nil（不入账）；结算窗由顺位 11 据 engine 末态呈现（D13 / residual U2-R4）。纯函数 host 全测。
    public func shouldAutoFinalize(didFinalize: Bool) -> Bool {
        isAtEnd && engine.flow.shouldShowSettlement() && !didFinalize
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

    /// §4.7e：durable 放弃当前局（清 pending + 关 reader + 清 context）。清 pending 失败抛（caller 保留重试）。
    public func discard() async throws {
        try await coordinator.discardSession()
    }

    /// 顺位 8（RFC §4.4e/§4.5）：replay 结束的**非持久化**结算 payload。转发 frozen
    /// `coordinator.replaySettlementPayload`（只读终态 in-memory `TrainingRecord`；不写 `training_records`、
    /// 不触 `pending_training`、`finalize` 对 replay 仍返 nil）。**强平须 caller 先行**（壳层 manual
    /// `forceCloseManually` / auto maxTick 步进已强平，同 `finalizeForSettlement` 的终态前提）。
    /// 仅 replay + 活跃会话合法；否则 coordinator 抛 `.internalError`（caller 守卫）。
    public func replaySettlementRecord() throws -> TrainingRecord {
        try coordinator.replaySettlementPayload(engine: engine)
    }
}

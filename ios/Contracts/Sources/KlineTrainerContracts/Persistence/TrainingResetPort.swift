// Kline Trainer Swift Contracts — 重置资金「真正归零重来」原子端口
// Spec: docs/superpowers/specs/2026-06-19-reset-capital-true-restart-design.md §5.1
// 运行时 #1：重置在单一事务内清空全部训练记录 + 未完成的对局 + 资金回默认值。

/// 单事务训练进度重置：删除全部训练记录（含 ops/drawings 子行）、清空 pending、
/// 将 total_capital 写为 `toCapital` —— 要么全成要么全不（`DefaultAppDB.dbQueue.write` 事务边界）。
public protocol TrainingResetPort: Sendable {
    func resetAllTrainingProgress(toCapital: Double) throws
}

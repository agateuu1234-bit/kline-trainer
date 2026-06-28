// Kline Trainer Swift Contracts — Wave 3 顺位 10a session-finalization port
// Spec: kline_trainer_modules_v1.4.md:1749（§4.7b 单事务 port）+ :1751（§4.7c durable session key）
// RFC: docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md §4.7

/// 单事务会话终结：`insertRecord`（record+ops+drawings）与 `clearPending` 在**同一**
/// `DefaultAppDB` 事务内完成 —— 要么 record 入库且 pending 清，要么都不（§4.7b 原子契约）。
/// `sessionKey` 是幂等锚（§4.7c）：同 key 重试 → 不重插，返已存 recordId（前次事务已 commit 的场景）。
/// A4（RFC-A）：返回 `(id, totalCapital)` —— `totalCapital` 是**事务内从持久记录派生、随成功返回**的
/// 权威当前资金（`settings.total_capital`）。retry 幂等：同 key 重试返当前权威值（不回退）。caller
/// 用返回值刷活 `SettingsStore` 缓存（恒 == DB 权威，无 fallible 后置读）。
public protocol SessionFinalizationPort: Sendable {
    func finalizeSession(record: TrainingRecord,
                         ops: [TradeOperation],
                         drawings: [DrawingObject],
                         sessionKey: String) throws -> (id: Int64, totalCapital: Double)
}

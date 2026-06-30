// Kline Trainer Swift Contracts — E4 TrainingFlowController
// Spec: kline_trainer_modules_v1.4.md §E4（协议 10 成员 + Normal/Review/Replay 三实现）
//     + kline_trainer_plan_v1.5.md §5.0（Capability Matrix —— 行为权威表）
// M0.4: 豁免 — 纯 capability 查询，返 Bool/Int/ClosedRange<Int>，从不 throws AppError
//       (docs/governance/m04-apperror-translation-gate.md)
//
// 设计决策（见 plan docs/superpowers/plans/2026-05-24-pr-e4-trainingflowcontroller.md）：
// modules v1.4 §E4 的三个 struct 示例只列"差异化 override"，与 plan v1.5 §5.0 Capability
// Matrix 不自洽（矩阵要求 Review 全 ❌、Replay 的 shouldAccumulateCapital ❌）。本模块以
// Capability Matrix 为行为权威，每个 Flow 显式实现全部 6 个布尔方法 = 矩阵对应列的逐格
// 转写，不引入 protocol extension 默认实现（避免"默认 + 部分 override"交互——正是它令
// spec 示例 struct 自身出错）。

public protocol TrainingFlowController {
    var mode: TrainingMode { get }
    var feeSnapshot: FeeSnapshot { get }
    var initialTick: Int { get }
    var allowedTickRange: ClosedRange<Int> { get }

    func canBuySell() -> Bool
    func canAdvance() -> Bool
    func shouldSaveRecord() -> Bool
    func shouldAccumulateCapital() -> Bool
    func shouldShowSettlement() -> Bool
    func shouldGiveHapticFeedback() -> Bool
    func shouldPersistProgress() -> Bool
    func canJumpToEnd() -> Bool
}

/// 正常训练：全能力开放。
/// - Precondition: `maxTick >= 0`（来自训练组 K 线根数 - 1，调用方保证）。
///   `allowedTickRange` 用 `0...maxTick`，maxTick < 0 时会 trap——与 spec 字面一致，
///   不做防御性 clamp（clamp 会掩盖调用方 bug）。
public struct NormalFlow: TrainingFlowController {
    public let fees: FeeSnapshot
    public let maxTick: Int

    public init(fees: FeeSnapshot, maxTick: Int) {
        self.fees = fees
        self.maxTick = maxTick
    }

    public var mode: TrainingMode { .normal }
    public var feeSnapshot: FeeSnapshot { fees }
    public var initialTick: Int { 0 }
    public var allowedTickRange: ClosedRange<Int> { 0...maxTick }

    public func canBuySell() -> Bool { true }
    public func canAdvance() -> Bool { true }
    public func shouldSaveRecord() -> Bool { true }
    public func shouldAccumulateCapital() -> Bool { true }
    public func shouldShowSettlement() -> Bool { true }
    public func shouldGiveHapticFeedback() -> Bool { true }
    public func shouldPersistProgress() -> Bool { true }
    public func canJumpToEnd() -> Bool { false }
}

/// 复盘可步进重演：从 startTick 开始，逐 K 线步进到 finalTick，只读不交易。
/// - `startTick` 经防御性钳位（防 ClosedRange trap）：public init 可被直接传坏 startTick/corrupt record；
///   合法路径（0 ≤ startTick ≤ finalTick）下 safeStart==startTick / safeFinal==finalTick，语义不变。
/// - `make` 守卫是正确-错误路径（startTick > finalTick → 可恢复 AppError）；钳位是安全网（public init 直接构造）。
public struct ReviewFlow: TrainingFlowController {
    public let record: TrainingRecord
    public let startTick: Int

    public init(record: TrainingRecord, startTick: Int) {
        self.record = record
        self.startTick = startTick
    }

    public var mode: TrainingMode { .review }
    public var feeSnapshot: FeeSnapshot { record.feeSnapshot }
    private var safeFinalTick: Int { max(0, record.finalTick) }
    private var safeStartTick: Int { max(0, min(startTick, safeFinalTick)) }
    public var initialTick: Int { safeStartTick }
    public var allowedTickRange: ClosedRange<Int> { safeStartTick...safeFinalTick }

    public func canBuySell() -> Bool { false }
    public func canAdvance() -> Bool { true }           // 新需求10：复盘可步进重演
    public func shouldSaveRecord() -> Bool { false }
    public func shouldAccumulateCapital() -> Bool { false }
    public func shouldShowSettlement() -> Bool { false }
    public func shouldGiveHapticFeedback() -> Bool { false }
    public func shouldPersistProgress() -> Bool { false }
    public func canJumpToEnd() -> Bool { true }
}

/// 再来一次：可操作但不入账，沿用原局 FeeSnapshot。
/// - Precondition: `maxTick >= 0`（同 NormalFlow）。
public struct ReplayFlow: TrainingFlowController {
    public let feeSnapshotFromOriginal: FeeSnapshot
    public let maxTick: Int

    public init(feeSnapshotFromOriginal: FeeSnapshot, maxTick: Int) {
        self.feeSnapshotFromOriginal = feeSnapshotFromOriginal
        self.maxTick = maxTick
    }

    public var mode: TrainingMode { .replay }
    public var feeSnapshot: FeeSnapshot { feeSnapshotFromOriginal }
    public var initialTick: Int { 0 }
    public var allowedTickRange: ClosedRange<Int> { 0...maxTick }

    public func canBuySell() -> Bool { true }
    public func canAdvance() -> Bool { true }
    public func shouldSaveRecord() -> Bool { false }
    public func shouldAccumulateCapital() -> Bool { false }
    public func shouldShowSettlement() -> Bool { true }
    public func shouldGiveHapticFeedback() -> Bool { true }
    public func shouldPersistProgress() -> Bool { true }
    public func canJumpToEnd() -> Bool { false }
}

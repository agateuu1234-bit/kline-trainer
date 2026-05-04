// Kline Trainer Swift Contracts — P2 port 3
// Spec: kline_trainer_modules_v1.4.md §P2 line 1765-1769
//       不变量来源：modules L741（B2 不变量月线前 ≥30 / 之后 8 根月 K 时间窗口）
//                  plan_v1.5 L1062（assert before_count >= 30 for 所有周期）

import Foundation

public protocol TrainingSetDataVerifying: Sendable {
    /// 通过 P3b reader 加载 meta + 全部周期 candles，按 spec literal 强 invariant 校验：
    ///
    /// 对每个 `period in Period.allCases`：
    /// 1. `candles[period]` 必须有 key 且数组非空
    /// 2. **`startDatetime` 前 ≥30 candles**（spec L1062 字面，所有周期）
    /// 3. **monthly 周期**：`startDatetime` 起（含）后 ≥8 candles（spec L741 字面）
    /// 4. **其它 5 周期**：`startDatetime` 起（含）后 ≥1 candle（spec spirit 防 0-after trash）
    ///
    /// 任一条件不满足 → throw `AppError.trainingSet(.emptyData)`。
    ///
    /// **设计意图**：弱化"非空" → 单 candle sqlite 能 trivially pass，下游 ma66/boll/macd
    /// 依赖 30 row warmup 否则全 NaN（per codex round 1 finding 1）。
    func verifyNonEmpty(reader: TrainingSetReader) throws
}

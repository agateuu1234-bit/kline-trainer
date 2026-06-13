// ios/Contracts/Sources/KlineTrainerContracts/UI/TradeFeedback.swift
// Kline Trainer Swift Contracts — U2 交易反馈纯值（Wave 3 顺位 7）
// Spec: kline_trainer_plan_v1.5.md §6.2.4（买入/卖出确认后触觉 + 失败 Toast L735/L736）
//     + AppError.swift（M0.4 冻结：userMessage / shouldShowToast）。
//
// 平台无关纯值（host 全测）：把 engine.buy/sell 的 `Result<_, AppError>` 决策成两条 UI 效果——
// 是否触发 .heavy 触觉、是否打 Toast 及文案。壳层（TrainingView）只执行（不决策）。
// 决议（D1/D2/D4）：
// - D1 Toast 文案 = AppError.userMessage（M0.4 单一真值源，不重抄 plan 字面）；是否打用 shouldShowToast
//   （.trade(.disabled) → false，由按钮禁用态自然呈现）。
// - D2 触觉仅在成功时（买入/卖出成功）；失败不震动。
// - D4 init 泛型 over Success：反馈只依赖「成功 vs 失败」，与成功载荷 TradeOperation 无关 → 解耦 + host 测免构造。

import Foundation

public struct TradeFeedback: Equatable, Sendable {
    /// 是否触发 .heavy 触觉（仅交易成功）。
    public let firesHaptic: Bool
    /// 需展示的 Toast 文案；nil = 不打 Toast（成功 / disabled 等 shouldShowToast==false 的错误）。
    public let toastMessage: String?

    public init<Success>(result: Result<Success, AppError>) {
        switch result {
        case .success:
            self.firesHaptic = true
            self.toastMessage = nil
        case .failure(let error):
            self.firesHaptic = false
            self.toastMessage = error.shouldShowToast ? error.userMessage : nil
        }
    }
}

// Sources/KlineTrainerContracts/UI/TradeConfirmGuard.swift
// 买卖确认转换（host 可测，非 View）。交易边界：画线模式下一律不成交（codex plan-R1/R3-high）——
// 即便 TradeBox 因时序仍挂着，onConfirm 也必须经 apply 拒绝，防不可逆成交 + autosave。
public enum TradeConfirmGuard {
    public static func allowsConfirm(drawingModeActive: Bool, periodTickStillValid: Bool) -> Bool {
        !drawingModeActive && periodTickStillValid
    }
    /// confirm 转换：**仅当** allowsConfirm 才调 onProceed（= performTrade）。
    /// onProceed 用 spy 即可执行断言「画线中零成交」，不必测 SwiftUI 闭包。
    public static func apply(drawingModeActive: Bool, periodTickStillValid: Bool, onProceed: () -> Void) {
        if allowsConfirm(drawingModeActive: drawingModeActive, periodTickStillValid: periodTickStillValid) {
            onProceed()
        }
    }
}

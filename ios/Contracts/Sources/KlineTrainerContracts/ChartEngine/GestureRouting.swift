// ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureRouting.swift
// C8b 手势路由纯函数（平台无关，host 测）。arbiter onTwoFingerSwipe(SwipeDirection) →
// TrainingEngine.switchPeriodCombo(PeriodDirection) 的映射。
// spec 未钉死方向语义（plan v1.5 §4.4 仅「两指上下滑切周期」）；本 PR 决策（D9）：
//   上滑(.up) → .toLarger（较粗/较大周期），下滑(.down) → .toSmaller（较细/较小周期）。
// runtime-tunable：真机手感不符可调本函数，runbook 注明。

/// 两指上下滑方向 → 周期组合切换方向（D9）。
public func periodDirection(for swipe: SwipeDirection) -> PeriodDirection {
    switch swipe {
    case .up:   return .toLarger
    case .down: return .toSmaller
    }
}

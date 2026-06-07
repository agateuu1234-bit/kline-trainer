// ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsResetConfirmation.swift
// Kline Trainer — Wave 2 顺位 10：P6 破坏性恢复的 deliberate-intent 信号
// RFC docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md §四：
// public 类型（出现在 public forceResetAndReload(confirmation:) 签名）+ internal init
// → 包外（顺位 11 app target）无法构造，仅 KlineTrainerContracts 内（SettingsPanel 恢复 UX）可构造。
// 非抗 determined caller 的安全边界（同模块谁都能构造）；真正数据安全靠 SettingsStore 内的
// 错误类型门 + runtime 守卫 + 破坏前最后非破坏 reload。
public struct SettingsResetConfirmation: Sendable {
    internal init() {}
}

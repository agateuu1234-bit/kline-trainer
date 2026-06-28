// Kline Trainer Swift Contracts — P4 SettingsDAO
// Spec: kline_trainer_modules_v1.4.md §P4 (line 1863-1937，protocol 体 1885-1889)

public protocol SettingsDAO: Sendable {
    func loadSettings() throws -> AppSettings
    func saveSettings(_: AppSettings) throws
    func resetCapital() throws
    /// R-plan-24-1：腐坏恢复用——把**全部**键（含 total_capital）写默认。
    /// 单写者下 saveSettings 不再写 total_capital，故腐坏/负 total_capital 必须经此路径修复
    /// （仅 SettingsStore.forceResetAndReload 调用，不走偏好竞态路径）。
    func repairAllToDefaults() throws
}

public extension SettingsDAO {
    /// 默认：经 saveSettings(.default) 重写偏好键。**生产 `DefaultAppDB` 必须 override**
    /// （其 saveSettings 单写者豁免 total_capital，默认实现修不掉 total_capital 腐坏）。
    /// 测试替身（saveSettings 持久全键）用此默认即可。
    func repairAllToDefaults() throws { try saveSettings(.default) }
}

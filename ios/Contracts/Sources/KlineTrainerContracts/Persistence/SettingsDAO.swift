// Kline Trainer Swift Contracts — P4 SettingsDAO
// Spec: kline_trainer_modules_v1.4.md §P4 (line 1863-1937，protocol 体 1885-1889)

public protocol SettingsDAO: Sendable {
    func loadSettings() throws -> AppSettings
    func saveSettings(_: AppSettings) throws
    func resetCapital() throws
}

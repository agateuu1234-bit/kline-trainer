// Kline Trainer Swift Contracts — P6 SettingsStore (Wave 0 类壳)
// Spec: kline_trainer_modules_v1.4.md §P6 (line 1970-1983)
// Wave 0 范围：init(settingsDAO:) 签名 + 4 方法签名 + zero-value 默认 settings
// Wave 2 P6 PR 改为 init 内调用 settingsDAO.loadSettings() 实际加载
// preview() 静态工厂在 Task 5 添加（依赖 Task 4 的 InMemorySettingsDAO）

#if canImport(Observation)
import Observation
#endif

@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: AppSettings

    private let settingsDAO: SettingsDAO

    public init(settingsDAO: SettingsDAO) {
        self.settingsDAO = settingsDAO
        // Wave 0 stub: 默认 zero-value AppSettings（commissionRate=0 是有效的小数率，spec line 1976 只约束单位）
        // 字段顺序按 baseline grep（AppState.swift:159）：commissionRate / minCommissionEnabled / totalCapital / displayMode
        self.settings = AppSettings(commissionRate: 0,
                                    minCommissionEnabled: false,
                                    totalCapital: 0,
                                    displayMode: .system)
    }

    public func update(_ mutate: (inout AppSettings) -> Void) async throws {
        fatalError("Wave 2 P6 impl")
    }

    public func resetCapital() async throws {
        fatalError("Wave 2 P6 impl")
    }

    public func snapshotFees() -> FeeSnapshot {
        FeeSnapshot(commissionRate: settings.commissionRate,
                    minCommissionEnabled: settings.minCommissionEnabled)
    }
}

// MARK: - Preview Fixture (spec line 1689-1700 配套；依赖 InMemorySettingsDAO from PreviewFakes)

#if DEBUG
@MainActor
extension SettingsStore {
    public static func preview() -> SettingsStore {
        SettingsStore(settingsDAO: InMemorySettingsDAO())
    }
}
#endif

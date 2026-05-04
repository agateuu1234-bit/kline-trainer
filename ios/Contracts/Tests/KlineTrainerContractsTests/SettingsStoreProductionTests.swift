// ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift
import Foundation
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("SettingsStore production")
struct SettingsStoreProductionTests {

    @Test("init: dao 返合法 settings → settings 字段对齐 dao 返回值")
    func init_loadsSettingsFromDAO() throws {
        let want = AppSettings(
            commissionRate: 0.0001, minCommissionEnabled: true,
            totalCapital: 100_000, displayMode: .dark)
        let dao = StubSettingsDAO(load: .success(want))

        let store = SettingsStore(settingsDAO: dao)
        #expect(store.settings == want)
    }

    @Test("init: dao throws .dbCorrupted → fallback 到 zero-value，不崩")
    func init_daoThrowsCorrupted_fallsBackToZero() throws {
        let dao = StubSettingsDAO(load: .failure(AppError.persistence(.dbCorrupted)))
        let store = SettingsStore(settingsDAO: dao)
        #expect(store.settings == .zero)
    }

    // R4 H-1 regression: dbCorrupted 也阻塞写（防 silent 覆盖部分合法 keys）
    @Test("init: dbCorrupted 后 update 抛 dbCorrupted 阻塞，不持久化 zero")
    func init_dbCorrupted_updateBlocked() async throws {
        let dbErr = AppError.persistence(.dbCorrupted)
        let dao = StubSettingsDAO(load: .failure(dbErr))
        let store = SettingsStore(settingsDAO: dao)

        await #expect(throws: dbErr) {
            try await store.update { s in s.commissionRate = 0.0007 }
        }
        // dao.saveSettings 不应被调
        #expect(dao.savedSettings == nil)
    }

    // R2 H-3 regression: transient I/O 错误后 update 必须 throw 不能 silent 覆盖
    @Test("init: dao throws .ioError → update 抛同 error 阻塞写")
    func init_daoThrowsIOError_updateThrowsLoadError() async throws {
        let ioErr = AppError.persistence(.ioError("transient_lock"))
        let dao = StubSettingsDAO(load: .failure(ioErr))
        let store = SettingsStore(settingsDAO: dao)

        await #expect(throws: ioErr) {
            try await store.update { s in s.commissionRate = 0.0009 }
        }
        // dao.saveSettings 不应被调
        #expect(dao.savedSettings == nil)
    }

    @Test("init: dao throws .diskFull → resetCapital 抛同 error 阻塞写")
    func init_daoThrowsDiskFull_resetCapitalThrowsLoadError() async throws {
        let dfErr = AppError.persistence(.diskFull)
        let dao = StubSettingsDAO(load: .failure(dfErr))
        let store = SettingsStore(settingsDAO: dao)

        await #expect(throws: dfErr) {
            try await store.resetCapital()
        }
        #expect(!dao.resetCalled)
    }
}

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

    @Test("init: dao throws .diskFull → resetAllProgress 抛同 error 阻塞写（端口不被调）")
    func init_daoThrowsDiskFull_resetAllProgressThrowsLoadError() async throws {
        let dfErr = AppError.persistence(.diskFull)
        let dao = StubSettingsDAO(load: .failure(dfErr))
        let port = FakeTrainingResetPort()
        let store = SettingsStore(settingsDAO: dao, resetPort: port)
        await #expect(throws: dfErr) { try await store.resetAllProgress() }
        #expect(port.resetToCapital == nil)   // loadError 先拦截，端口未触
    }

    // MARK: - Task 6: update / resetCapital / concurrent / snapshot

    @Test("update: mutate block 修改 settings 后 dao.saveSettings 被调；本地 settings 同步更新")
    func update_persistsViaDAO_updatesLocalSettings() async throws {
        let dao = StubSettingsDAO(load: .success(.zero))
        let store = SettingsStore(settingsDAO: dao)

        try await store.update { s in
            s.commissionRate = 0.0003
            s.totalCapital = 50_000
        }

        #expect(dao.savedSettings?.commissionRate == 0.0003)
        #expect(dao.savedSettings?.totalCapital == 50_000)
        #expect(store.settings.commissionRate == 0.0003)
        #expect(store.settings.totalCapital == 50_000)
    }

    @Test("update: dao.saveSettings throws → 错误上抛 + 本地 settings 不变")
    func update_daoSaveThrows_localUnchanged() async throws {
        let initial = AppSettings(
            commissionRate: 0.0001, minCommissionEnabled: false,
            totalCapital: 10_000, displayMode: .system)
        let dao = StubSettingsDAO(load: .success(initial))
        dao.saveError = AppError.persistence(.diskFull)
        let store = SettingsStore(settingsDAO: dao)

        await #expect(throws: AppError.persistence(.diskFull)) {
            try await store.update { s in s.commissionRate = 0.99 }
        }
        #expect(store.settings == initial)
    }

    @Test("resetAllProgress: 端口被调（toCapital=10 万）；本地 totalCapital→10 万，其它字段不变")
    func resetAllProgress_callsPortAndSetsDefaultCapital() async throws {
        let initial = AppSettings(commissionRate: 0.0001, minCommissionEnabled: true,
                                  totalCapital: 999, displayMode: .dark)
        let dao = StubSettingsDAO(load: .success(initial))
        let port = FakeTrainingResetPort()
        let store = SettingsStore(settingsDAO: dao, resetPort: port)
        try await store.resetAllProgress()
        #expect(port.resetToCapital == 100_000)
        #expect(store.settings.totalCapital == 100_000)
        #expect(store.settings.commissionRate == 0.0001)
        #expect(store.settings.minCommissionEnabled == true)
        #expect(store.settings.displayMode == .dark)
    }

    @Test("resetAllProgress: 端口抛错 → 上抛 + 本地 capital 不变")
    func resetAllProgress_portThrows_localUnchanged() async throws {
        let initial = AppSettings(commissionRate: 0.0001, minCommissionEnabled: false,
                                  totalCapital: 555, displayMode: .system)
        let dao = StubSettingsDAO(load: .success(initial))
        let port = FakeTrainingResetPort()
        port.error = .persistence(.diskFull)
        let store = SettingsStore(settingsDAO: dao, resetPort: port)
        await #expect(throws: AppError.persistence(.diskFull)) { try await store.resetAllProgress() }
        #expect(store.settings.totalCapital == 555)
    }

    @Test("resetAllProgress: 未注入端口 → internalError")
    func resetAllProgress_noPort_throwsInternal() async throws {
        let store = SettingsStore(settingsDAO: StubSettingsDAO(load: .success(.zero)))  // resetPort 默认 nil
        await #expect(throws: AppError.self) { try await store.resetAllProgress() }
    }

    // R1 H-3 regression: 并发 update 不丢字段
    @Test("concurrent update: 并发改不同字段，最终 dao 写入和本地都包含两次修改")
    func concurrentUpdate_differentFields_neitherLost() async throws {
        let initial = AppSettings(
            commissionRate: 0, minCommissionEnabled: false,
            totalCapital: 0, displayMode: .system)
        let dao = StubSettingsDAO(load: .success(initial))
        let store = SettingsStore(settingsDAO: dao)

        async let a: Void = store.update { s in s.commissionRate = 0.0005 }
        async let b: Void = store.update { s in s.totalCapital = 77_777 }
        _ = try await (a, b)

        // 两个字段都应保留（chain 串行 + 后写包含前写）
        #expect(store.settings.commissionRate == 0.0005)
        #expect(store.settings.totalCapital == 77_777)
        // dao 最后一次写入也应同时含两个字段
        #expect(dao.savedSettings?.commissionRate == 0.0005)
        #expect(dao.savedSettings?.totalCapital == 77_777)
    }

    // R5 H-1 regression: snapshotFees 在 loadError 状态下返 zero（不 throw 不 crash），caller 可读 loadError guard
    @Test("snapshotFees: loadError 非 nil 时返 zero fees + loadError 公开 readable")
    func snapshotFees_loadErrorState_returnsZeroAndExposesLoadError() async throws {
        let dfErr = AppError.persistence(.diskFull)
        let dao = StubSettingsDAO(load: .failure(dfErr))
        let store = SettingsStore(settingsDAO: dao)

        // R5 H-1 contract: caller MUST guard via loadError before snapshotFees
        #expect(store.loadError == dfErr)

        // snapshotFees 不阻塞不抛；返当前 settings (zero-default) 的 fees
        let fees = store.snapshotFees()
        #expect(fees.commissionRate == 0)
        #expect(fees.minCommissionEnabled == false)

        // loadError 状态下 update / resetCapital 仍阻塞（同 H-3 测试已验）
    }

    // R6 H-1 partial regression: snapshotFeesIfReady throws on loadError
    @Test("snapshotFeesIfReady: loadError 时 throws；happy 时返正常 fees")
    func snapshotFeesIfReady_throwsOnLoadError_returnsFeesOnHappy() async throws {
        let dfErr = AppError.persistence(.diskFull)
        let failDao = StubSettingsDAO(load: .failure(dfErr))
        let failStore = SettingsStore(settingsDAO: failDao)
        #expect(throws: dfErr) {
            try failStore.snapshotFeesIfReady()
        }

        let goodSettings = AppSettings(
            commissionRate: 0.0001, minCommissionEnabled: true,
            totalCapital: 1000, displayMode: .dark)
        let goodDao = StubSettingsDAO(load: .success(goodSettings))
        let goodStore = SettingsStore(settingsDAO: goodDao)
        let fees = try goodStore.snapshotFeesIfReady()
        #expect(fees.commissionRate == 0.0001)
        #expect(fees.minCommissionEnabled == true)
    }

    // R1 H-3 regression: 并发 update + resetAllProgress（端口设 10 万，不被 update 旧值覆盖）
    @Test("concurrent update+reset: reset 不被 update 旧 totalCapital overwrite")
    func concurrentUpdate_andReset_resetWins() async throws {
        let initial = AppSettings(commissionRate: 0.0001, minCommissionEnabled: false,
                                  totalCapital: 50_000, displayMode: .system)
        let dao = StubSettingsDAO(load: .success(initial))
        let port = FakeTrainingResetPort()
        let store = SettingsStore(settingsDAO: dao, resetPort: port)

        async let a: Void = store.update { s in s.commissionRate = 0.0009 }
        async let b: Void = store.resetAllProgress()
        _ = try await (a, b)

        #expect(store.settings.totalCapital == 100_000)   // 串行结果稳定：reset 设默认 10 万
        #expect(store.settings.commissionRate == 0.0009)
    }
}

/// 测试 fake：单线程 MainActor 测试中使用。写发生在被 await 的 Task.detached 内，
/// `try await task.value` 建立 happens-before，读在 await 之后，故 @unchecked Sendable 安全。
final class FakeTrainingResetPort: TrainingResetPort, @unchecked Sendable {
    private(set) var resetToCapital: Double?
    var error: AppError?
    func resetAllTrainingProgress(toCapital: Double) throws {
        if let e = error { throw e }
        resetToCapital = toCapital
    }
}

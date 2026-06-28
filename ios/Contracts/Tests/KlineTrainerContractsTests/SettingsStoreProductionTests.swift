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

    // MARK: - Task 6: update / resetAllProgress / concurrent / snapshot

    @Test("update: 偏好（commission）持久化+刷缓存；total_capital 单写者保留不被 update 改（R-plan-22-1）")
    func update_persistsViaDAO_updatesLocalSettings() async throws {
        let dao = StubSettingsDAO(load: .success(.zero))   // 初始 totalCapital=0（权威）
        let store = SettingsStore(settingsDAO: dao)

        try await store.update { s in
            s.commissionRate = 0.0003
            s.totalCapital = 50_000        // 单写者：update 不得改权威 total_capital
        }

        #expect(dao.savedSettings?.commissionRate == 0.0003)
        #expect(store.settings.commissionRate == 0.0003)
        #expect(store.settings.totalCapital == 0)   // R-plan-22-1：保留权威（初始 0），未被 update 快照回滚
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
        await #expect(throws: AppError.internalError(module: "P6", detail: "resetAllProgress 需注入 TrainingResetPort")) {
            try await store.resetAllProgress()
        }
    }

    // R1 H-3 regression: 并发 update 不丢字段（用两个**偏好**字段；total_capital 单写者另测）
    @Test("concurrent update: 并发改不同偏好字段都保留（commission + minCommission）")
    func concurrentUpdate_differentFields_neitherLost() async throws {
        let initial = AppSettings(
            commissionRate: 0, minCommissionEnabled: false,
            totalCapital: 0, displayMode: .system)
        let dao = StubSettingsDAO(load: .success(initial))
        let store = SettingsStore(settingsDAO: dao)

        async let a: Void = store.update { s in s.commissionRate = 0.0005 }
        async let b: Void = store.update { s in s.minCommissionEnabled = true }
        _ = try await (a, b)

        // 两个偏好字段都应保留（chain 串行 + 后写包含前写）
        #expect(store.settings.commissionRate == 0.0005)
        #expect(store.settings.minCommissionEnabled == true)
        // dao 最后一次写入也应同时含两个字段
        #expect(dao.savedSettings?.commissionRate == 0.0005)
        #expect(dao.savedSettings?.minCommissionEnabled == true)
    }

    // A4：refreshTotalCapital 纯缓存刷新（finalize 成功后同步活缓存，主页即时反映）
    @Test("refreshTotalCapital: 活缓存即时反映新权威资金（不依赖 reload/重启）")
    func test_refreshTotalCapital_updates_cache() {
        let store = SettingsStore.preview()
        store.refreshTotalCapital(250_000)
        #expect(store.settings.totalCapital == 250_000)
    }

    // R-plan-22-1 race 回归：偏好 update 的 detached save 期间 total_capital 被推进（finalize/reset）
    // → update 提交缓存须保留**当前权威值**，不被旧快照回滚。
    @Test("race: update detached-save 期间 total_capital 推进 250_000 → update 不回滚（保留权威）")
    func test_update_does_not_rollback_concurrently_advanced_capital() async throws {
        let dao = GatedSettingsDAO(AppSettings(commissionRate: 0, minCommissionEnabled: false,
                                               totalCapital: 100_000, displayMode: .system))
        let store = SettingsStore(settingsDAO: dao)
        // 启动偏好 update：快照 total_capital=100_000，进入（被 gate 阻塞的）detached save。
        async let u: Void = store.update { $0.commissionRate = 0.0009 }
        await withCheckedContinuation { cont in                  // 等 save 进入（off MainActor，背景线程 wait）
            DispatchQueue.global().async { dao.didEnterSave.wait(); cont.resume() }
        }
        store.refreshTotalCapital(250_000)                       // detached save 期间推进权威资金
        dao.mayFinishSave.signal()                               // 放行 save
        try await u
        #expect(store.settings.totalCapital == 250_000)          // 保留权威，未被旧快照(100_000)回滚
        #expect(store.settings.commissionRate == 0.0009)         // 偏好仍生效
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

        // loadError 状态下 update / resetAllProgress 仍阻塞（同 H-3 测试已验）
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

/// 可门控 saveSettings（阻塞在 mayFinishSave 上）的测试替身——用于确定性 race 回归。
final class GatedSettingsDAO: SettingsDAO, @unchecked Sendable {
    let didEnterSave = DispatchSemaphore(value: 0)
    let mayFinishSave = DispatchSemaphore(value: 0)
    private let loaded: AppSettings
    init(_ s: AppSettings) { loaded = s }
    func loadSettings() throws -> AppSettings { loaded }
    func saveSettings(_ s: AppSettings) throws {
        didEnterSave.signal()
        mayFinishSave.wait()   // 阻塞至测试放行
    }
    func resetCapital() throws {}
}

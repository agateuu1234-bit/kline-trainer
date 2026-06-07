// ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreRecoveryTests.swift
// RFC docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md §四 11 场景。
import Foundation
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("SettingsStore 两层恢复")
struct SettingsStoreRecoveryTests {

    private static let userSettings = AppSettings(
        commissionRate: 0.0007, minCommissionEnabled: true,
        totalCapital: 88_888, displayMode: .dark)

    // ── 场景 1：transient loadError → retryReload 救回真实设置，零破坏 ──
    @Test("场景1 transient：retryReload 恢复原用户设置 + 解阻 + 未调 saveSettings")
    func s1_transientRetrySucceeds() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.ioError("transient"))),  // init 失败
            .success(Self.userSettings),                            // retryReload 成功
        ])
        let store = SettingsStore(settingsDAO: dao)
        #expect(store.loadError != nil)

        try await store.retryReload()

        #expect(store.settings == Self.userSettings)   // 原用户设置，非 default
        #expect(store.loadError == nil)
        #expect(dao.saveCallCount == 0)                 // 零破坏
        // 解阻：update 不再抛
        try await store.update { $0.totalCapital = 99_999 }
        #expect(store.settings.totalCapital == 99_999)
    }

    // ── 场景 3a：健康态 retryReload throws 不动 ──
    @Test("场景3a 健康态：retryReload throws + settings 不变")
    func s3a_healthyRetryThrows() async throws {
        let dao = RecoverySettingsDAO(loadScript: [.success(Self.userSettings)])
        let store = SettingsStore(settingsDAO: dao)
        #expect(store.loadError == nil)

        await #expect(throws: (any Error).self) { try await store.retryReload() }
        #expect(store.settings == Self.userSettings)
        #expect(dao.saveCallCount == 0)
    }

    // ── retryReload 失败 → loadError 更新为最新错误（场景 10/11 前置；公开可观测）──
    @Test("retryReload 失败：loadError 更新为最新 retry 错误（非 stale init 错误）")
    func retryFailUpdatesLoadError() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.ioError("init"))),   // init transient
            .failure(AppError.persistence(.dbCorrupted)),       // retry 暴露 dbCorrupted
        ])
        let store = SettingsStore(settingsDAO: dao)
        #expect(store.loadError == .persistence(.ioError("init")))

        await #expect(throws: AppError.persistence(.dbCorrupted)) {
            try await store.retryReload()
        }
        #expect(store.loadError == .persistence(.dbCorrupted))  // 更新为最新，非 stale
        #expect(dao.saveCallCount == 0)
    }

    // ── 场景 2：persistent malformed → retry throws → forceReset → default + 非零 fee ──
    @Test("场景2 persistent：retry 失败后 forceReset 重置为 default + snapshotFeesIfReady 非零")
    func s2_persistentForceReset() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),  // init
            .failure(AppError.persistence(.dbCorrupted)),  // retry throws
            .failure(AppError.persistence(.dbCorrupted)),  // forceReset 破坏前最后 reload
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }

        try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())

        #expect(store.settings == .default)
        #expect(store.loadError == nil)
        #expect(dao.saveCallCount == 1)
        let fees = try store.snapshotFeesIfReady()
        #expect(fees.commissionRate == 0.0001)   // 非零 default fee
    }

    // ── 场景 3b：健康态 forceReset throws 不动 ──
    @Test("场景3b 健康态：forceReset throws + settings 不变 + 未调 saveSettings")
    func s3b_healthyForceThrows() async throws {
        let dao = RecoverySettingsDAO(loadScript: [.success(Self.userSettings)])
        let store = SettingsStore(settingsDAO: dao)

        await #expect(throws: (any Error).self) {
            try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        }
        #expect(store.settings == Self.userSettings)
        #expect(dao.saveCallCount == 0)
    }

    // ── 场景 4：未先试 retryReload → forceReset throws + 零破坏 ──
    @Test("场景4 顺序守卫：未 retryReload 直接 forceReset throws + 未调 saveSettings")
    func s4_orderGuard() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),  // init（_retryReloadFailed 仍 false）
        ])
        let store = SettingsStore(settingsDAO: dao)

        await #expect(throws: (any Error).self) {
            try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        }
        #expect(dao.saveCallCount == 0)
    }

    // ── 场景 5：入口 dbCorrupted 但破坏前 reload 自愈 → 保留真实值，零破坏 ──
    @Test("场景5 破坏前自愈：forceReset 最后 reload 成功 → settings=DB 真实值 + 未调 saveSettings")
    func s5_selfHealBeforeDestroy() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),  // init
            .failure(AppError.persistence(.dbCorrupted)),  // retry throws（_loadError 仍 dbCorrupted）
            .success(Self.userSettings),                   // forceReset 破坏前 reload 自愈
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }

        try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())

        #expect(store.settings == Self.userSettings)  // 真实值，非 default
        #expect(store.loadError == nil)
        #expect(dao.saveCallCount == 0)               // 零破坏
    }

    // ── 场景 6：transient 未恢复 → 错误类型门 throws + 零破坏 ──
    @Test("场景6 transient 未恢复：forceReset 错误类型门 throws + 未调 saveSettings")
    func s6_transientGate() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.diskFull)),  // init transient
            .failure(AppError.persistence(.diskFull)),  // retry 仍 transient（_loadError=diskFull）
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }

        await #expect(throws: AppError.persistence(.diskFull)) {
            try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        }
        #expect(dao.saveCallCount == 0)   // 非 dbCorrupted 不破坏
    }

    // ── 场景 7：persistent corruption → 破坏路径 reset 成功 ──
    @Test("场景7 corruption：retry dbCorrupted → forceReset 写 default reset 成功 + 解阻")
    func s7_persistentCorruption() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),  // init
            .failure(AppError.persistence(.dbCorrupted)),  // retry
            .failure(AppError.persistence(.dbCorrupted)),  // forceReset 破坏前最后 reload
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }

        try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())

        #expect(store.settings == .default)
        #expect(store.loadError == nil)
        #expect(dao.saveCallCount == 1)
        try await store.update { $0.displayMode = .light }  // 解阻
        #expect(store.settings.displayMode == .light)
    }

    // ── 场景 8：混合错误（入口 dbCorrupted 但破坏前变 transient）→ throws + 零破坏 ──
    @Test("场景8 混合：入口 dbCorrupted 破坏前变 diskFull → loadError=diskFull + throws + 未调 saveSettings")
    func s8_mixedError() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),  // init
            .failure(AppError.persistence(.dbCorrupted)),  // retry（_loadError=dbCorrupted）
            .failure(AppError.persistence(.diskFull)),     // forceReset 破坏前 reload 变 transient
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }

        await #expect(throws: AppError.persistence(.diskFull)) {
            try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        }
        #expect(store.loadError == .persistence(.diskFull))  // 更新为 transient
        #expect(dao.saveCallCount == 0)                      // 不破坏
    }

    // ── 场景 9：破坏路径 saveSettings 失败 → loadError 保留 + throws ──
    @Test("场景9 破坏写失败：saveSettings throws → loadError 保留 dbCorrupted + throws")
    func s9_destroyWriteFails() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),  // init
            .failure(AppError.persistence(.dbCorrupted)),  // retry
            .failure(AppError.persistence(.dbCorrupted)),  // forceReset 破坏前最后 reload
        ])
        dao.saveError = AppError.persistence(.diskFull)    // 写库失败
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }

        await #expect(throws: (any Error).self) {
            try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        }
        #expect(store.loadError == .persistence(.dbCorrupted))  // 保留
    }

    // ── 场景 10：init transient → retry 暴露 dbCorrupted → forceReset 过门 reset 成功 ──
    @Test("场景10 init-transient→retry-dbCorrupted：forceReset 按最新错误过门 reset 成功")
    func s10_initTransientRetryCorrupted() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.ioError("init"))),  // init transient
            .failure(AppError.persistence(.dbCorrupted)),      // retry 暴露 dbCorrupted
            .failure(AppError.persistence(.dbCorrupted)),      // forceReset 破坏前最后 reload
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }
        #expect(store.loadError == .persistence(.dbCorrupted))  // 已更新为最新

        try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        #expect(store.settings == .default)
        #expect(dao.saveCallCount == 1)
    }

    // ── 场景 11：init dbCorrupted → retry 变 transient → forceReset 拒绝破坏 ──
    @Test("场景11 init-dbCorrupted→retry-transient：forceReset 按最新 transient 拒绝 + 未调 saveSettings")
    func s11_initCorruptedRetryTransient() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),       // init
            .failure(AppError.persistence(.ioError("later"))),  // retry 变 transient
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }
        #expect(store.loadError == .persistence(.ioError("later")))

        await #expect(throws: AppError.persistence(.ioError("later"))) {
            try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        }
        #expect(dao.saveCallCount == 0)
    }
}

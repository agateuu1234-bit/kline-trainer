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
}

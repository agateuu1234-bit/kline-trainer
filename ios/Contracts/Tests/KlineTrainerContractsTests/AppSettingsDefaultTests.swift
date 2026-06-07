// ios/Contracts/Tests/KlineTrainerContractsTests/AppSettingsDefaultTests.swift
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("AppSettings.default")
struct AppSettingsDefaultTests {

    @Test("default：佣金万一 / 资本 10 万 / 跟随系统 / 免5 关闭")
    func defaultValues() {
        let d = AppSettings.default
        #expect(d.commissionRate == 0.0001)
        #expect(d.totalCapital == 100_000)
        #expect(d.displayMode == .system)
        #expect(d.minCommissionEnabled == false)
    }

    @Test("default：fee 非零（RFC 场景 2：forceReset 后 snapshotFeesIfReady 返非零费率）")
    func defaultFeeNonZero() {
        #expect(AppSettings.default.commissionRate != 0)
        #expect(AppSettings.default.totalCapital != 0)
    }
}

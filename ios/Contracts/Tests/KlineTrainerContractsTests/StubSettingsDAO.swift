// ios/Contracts/Tests/KlineTrainerContractsTests/StubSettingsDAO.swift
import Foundation
@testable import KlineTrainerContracts

public final class StubSettingsDAO: SettingsDAO, @unchecked Sendable {
    public var stubLoadResult: Result<AppSettings, Error>
    public private(set) var savedSettings: AppSettings?
    public private(set) var resetCalled = false
    public var saveError: Error?

    public init(load: Result<AppSettings, Error> = .success(.zero)) {
        self.stubLoadResult = load
    }

    public func loadSettings() throws -> AppSettings {
        switch stubLoadResult {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }

    public func saveSettings(_ s: AppSettings) throws {
        if let e = saveError { throw e }
        savedSettings = s
    }

    public func resetCapital() throws {
        resetCalled = true
    }
}

extension AppSettings {
    /// 测试 helper：zero-value
    public static let zero = AppSettings(
        commissionRate: 0, minCommissionEnabled: false,
        totalCapital: 0, displayMode: .system)
}

// ios/Contracts/Tests/KlineTrainerContractsTests/RecoverySettingsDAO.swift
// 恢复状态机测试替身：脚本化 load 失败序列 + 写反映 + saveSettings 计数。
import Foundation
@testable import KlineTrainerContracts

final class RecoverySettingsDAO: SettingsDAO, @unchecked Sendable {
    private let lock = NSLock()
    /// 脚本化 loadSettings 结果，FIFO 消费一次一项；耗尽后返回 `stored`（反映写）。
    private var loadScript: [Result<AppSettings, Error>]
    private var idx = 0
    /// 「DB 里」的值；saveSettings 更新它，脚本耗尽后的 load 返回它。
    private var stored: AppSettings
    private(set) var saveCallCount = 0
    private(set) var lastSaved: AppSettings?
    /// 若设，saveSettings 抛此错误（计数前抛，模拟写失败）。
    var saveError: Error?

    init(loadScript: [Result<AppSettings, Error>], stored: AppSettings = .zero) {
        self.loadScript = loadScript
        self.stored = stored
    }

    func loadSettings() throws -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        if idx < loadScript.count {
            let r = loadScript[idx]; idx += 1
            switch r {
            case .success(let s): return s
            case .failure(let e): throw e
            }
        }
        return stored  // 脚本耗尽 → 反映写
    }

    func saveSettings(_ s: AppSettings) throws {
        lock.lock(); defer { lock.unlock() }
        if let e = saveError { throw e }   // 写失败：计数前抛
        saveCallCount += 1
        lastSaved = s
        stored = s
    }

    func resetCapital() throws {
        lock.lock(); defer { lock.unlock() }
        stored.totalCapital = 0
    }
}

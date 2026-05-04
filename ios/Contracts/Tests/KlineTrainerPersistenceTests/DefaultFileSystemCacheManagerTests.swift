// ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultFileSystemCacheManagerTests.swift
import Foundation
import Testing
@testable import KlineTrainerPersistence
import KlineTrainerContracts

@Suite("DefaultFileSystemCacheManager")
struct DefaultFileSystemCacheManagerTests {

    @Test("store: 把 src sqlite move 到 cache root，返回 TrainingSetFile 字段对齐")
    func store_happyPath_movesFileAndReturnsTrainingSetFile() throws {
        let cacheRoot = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(cacheRoot) }

        let cache = DefaultFileSystemCacheManager(cacheRoot: cacheRoot)
        let src = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        let meta = CacheFixture.meta(id: 42, filename: "stock_42.sqlite")

        let result = try cache.store(downloadedZip: src, meta: meta)

        #expect(result.id == 42)
        #expect(result.filename == "stock_42.sqlite")
        #expect(result.schemaVersion == 1)
        #expect(result.localURL.lastPathComponent == "42__stock_42.sqlite")
        #expect(FileManager.default.fileExists(atPath: result.localURL.path))
        // R6 M-2: src 用 copy，不被 move 走；caller 自己负责清 src
        #expect(FileManager.default.fileExists(atPath: src.path), "src 应保留（caller retry-safe）")
        #expect(result.lastAccessedAt > 0)
        #expect(result.downloadedAt > 0)
    }

    // R6 M-2 regression: store fail 后 src 仍可用于 retry
    @Test("store: PRAGMA validation fail 后 src 仍存在，可 retry")
    func store_validationFail_srcRemainsForRetry() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        // src 不是合法 sqlite → PRAGMA 读 fail → store throws
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("bogus-\(UUID()).sqlite")
        try Data("not sqlite".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        #expect(throws: AppError.persistence(.dbCorrupted)) {
            try cache.store(downloadedZip: bogus, meta: CacheFixture.meta(id: 1, filename: "x.sqlite"))
        }
        // src 必须仍在（caller 可换 fixture 重试 or report）
        #expect(FileManager.default.fileExists(atPath: bogus.path),
                "src 不应因 store fail 被消耗")
    }
}

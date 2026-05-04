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

    // MARK: - Task 2: list / pickRandom / touch / delete

    @Test("listAvailable: 多次 store 后按 mtime desc 列出")
    func listAvailable_returnsStoredFilesSortedByMtimeDesc() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        let src1 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        _ = try cache.store(downloadedZip: src1, meta: CacheFixture.meta(id: 1, filename: "a.sqlite"))
        Thread.sleep(forTimeInterval: 1.1)
        let src2 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        _ = try cache.store(downloadedZip: src2, meta: CacheFixture.meta(id: 2, filename: "b.sqlite"))

        let all = cache.listAvailable()
        #expect(all.count == 2)
        #expect(all[0].id == 2, "newest first")
        #expect(all[1].id == 1)
    }

    @Test("pickRandom: 空 cache 返 nil；非空返其中一个")
    func pickRandom_returnsNilWhenEmpty_returnsAnyWhenNonEmpty() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        #expect(cache.pickRandom() == nil)

        let src = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        _ = try cache.store(downloadedZip: src, meta: CacheFixture.meta(id: 7, filename: "x.sqlite"))

        let picked = cache.pickRandom()
        #expect(picked?.id == 7)
    }

    @Test("touch: 更新 mtime，listAvailable 排序受影响")
    func touch_updatesMtime_changesListSortOrder() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        let s1 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        let f1 = try cache.store(downloadedZip: s1, meta: CacheFixture.meta(id: 1, filename: "a.sqlite"))
        Thread.sleep(forTimeInterval: 1.1)
        let s2 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        _ = try cache.store(downloadedZip: s2, meta: CacheFixture.meta(id: 2, filename: "b.sqlite"))
        Thread.sleep(forTimeInterval: 1.1)
        cache.touch(f1)
        let after = cache.listAvailable()
        #expect(after[0].id == 1, "touch 后 1 应排到最前")
    }

    @Test("delete: 删除指定文件，listAvailable 不再包含")
    func delete_removesFile_listAvailableExcludesIt() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        let f = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: 9, filename: "x.sqlite"))
        try cache.delete(f)
        #expect(cache.listAvailable().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.localURL.path))
    }

    @Test("delete: 不存在的文件抛 .trainingSet(.fileNotFound)")
    func delete_nonExistentThrowsFileNotFound() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        let ghost = TrainingSetFile(
            id: 0, filename: "ghost.sqlite",
            localURL: root.appendingPathComponent("0__ghost.sqlite"),
            schemaVersion: 1, lastAccessedAt: 0, downloadedAt: 0)
        #expect(throws: AppError.trainingSet(.fileNotFound)) {
            try cache.delete(ghost)
        }
    }
}

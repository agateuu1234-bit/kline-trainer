import XCTest
@testable import KlineTrainerContracts

#if DEBUG
final class InMemoryCacheManagerTests: XCTestCase {

    // MARK: - 测试 helpers

    private func makeMeta(id: Int, filename: String, schemaVersion: Int = 1) -> TrainingSetMetaItem {
        TrainingSetMetaItem(
            id: id, stockCode: "TEST", stockName: "Test Stock",
            filename: filename, schemaVersion: schemaVersion,
            contentHash: "deadbeef"
        )
    }

    private let dummyZip = URL(fileURLWithPath: "/tmp/dummy.zip")

    // MARK: - 1. fresh init 默认空（保不破 cacheManagerDefaults 测试）

    func test_freshInit_listAvailable_isEmpty_and_pickRandom_nil() {
        let cache = InMemoryCacheManager()
        XCTAssertTrue(cache.listAvailable().isEmpty)
        XCTAssertNil(cache.pickRandom())
    }

    // MARK: - 2-4. store + filename 规范化

    func test_store_round_trip_listAvailable_returns_inserted_file() throws {
        let cache = InMemoryCacheManager()
        let f = try cache.store(downloadedZip: dummyZip,
                                meta: makeMeta(id: 1, filename: "a.sqlite"))
        XCTAssertEqual(f.id, 1)
        XCTAssertEqual(f.filename, "a.sqlite")
        XCTAssertEqual(f.schemaVersion, 1)
        let listed = cache.listAvailable()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0], f)
    }

    func test_store_zip_filename_normalized_to_sqlite() throws {
        // codex post-impl R7：REST meta.filename 是 .zip，cache 层规范化为 .sqlite
        let cache = InMemoryCacheManager()
        let f = try cache.store(downloadedZip: dummyZip,
                                meta: makeMeta(id: 1, filename: "600519_202001.zip"))
        XCTAssertEqual(f.filename, "600519_202001.sqlite")
        XCTAssertEqual(cache.listAvailable()[0].filename, "600519_202001.sqlite")
    }

    func test_store_sqlite_filename_passes_through() throws {
        let cache = InMemoryCacheManager()
        let f = try cache.store(downloadedZip: dummyZip,
                                meta: makeMeta(id: 1, filename: "x.sqlite"))
        XCTAssertEqual(f.filename, "x.sqlite")
    }

    // MARK: - 5-6. filename safety

    func test_store_other_extension_throws_internalError() {
        let cache = InMemoryCacheManager()
        XCTAssertThrowsError(try cache.store(
            downloadedZip: dummyZip,
            meta: makeMeta(id: 1, filename: "x.txt")
        )) { err in
            guard case AppError.internalError = err else {
                XCTFail("expected internalError, got \(err)"); return
            }
        }
    }

    func test_store_unsafe_filename_throws_internalError() {
        let cache = InMemoryCacheManager()
        let bad = ["", "a/b.sqlite", "a\\b.sqlite", "../x.sqlite", "a\u{0}b.sqlite", ".staging-x.sqlite"]
        for f in bad {
            XCTAssertThrowsError(try cache.store(
                downloadedZip: dummyZip,
                meta: makeMeta(id: 1, filename: f)
            )) { err in
                guard case AppError.internalError = err else {
                    XCTFail("filename '\(f)' expected internalError, got \(err)"); return
                }
            }
        }
    }

    // MARK: - 7-9. 同 id 替换 + downloadedAt 保留 + lastAccessedAt 更新

    func test_store_same_id_replaces_and_preserves_downloadedAt() throws {
        let cache = InMemoryCacheManager()
        let f1 = try cache.store(downloadedZip: dummyZip,
                                 meta: makeMeta(id: 1, filename: "a.sqlite"))
        let originalDownloadedAt = f1.downloadedAt

        // 等 1 秒确保 mtime 时间戳变化（Int64 秒精度）
        Thread.sleep(forTimeInterval: 1.1)

        let f2 = try cache.store(downloadedZip: dummyZip,
                                 meta: makeMeta(id: 1, filename: "b.sqlite"))
        let listed = cache.listAvailable()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].filename, "b.sqlite")
        XCTAssertEqual(listed[0].downloadedAt, originalDownloadedAt, "downloadedAt 替换后应保留原值")
        XCTAssertGreaterThan(listed[0].lastAccessedAt, f1.lastAccessedAt,
                             "lastAccessedAt 替换后应更新到 now")
        _ = f2  // 抑制 unused warning
    }

    // MARK: - 10-11. listAvailable LRU sort + tiebreaker

    func test_listAvailable_sorts_by_lastAccessedAt_desc() throws {
        let cache = InMemoryCacheManager()
        let f1 = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: 1, filename: "a.sqlite"))
        Thread.sleep(forTimeInterval: 1.1)
        let f2 = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: 2, filename: "b.sqlite"))
        Thread.sleep(forTimeInterval: 1.1)
        let f3 = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: 3, filename: "c.sqlite"))
        let listed = cache.listAvailable()
        XCTAssertEqual(listed.map(\.id), [3, 2, 1])
        _ = (f1, f2, f3)
    }

    /// §2 行为 #3 + §7 测试 #11：同 lastAccessedAt 用 downloadedAt desc → basename desc（mirror production line 256）。
    /// basename = `"\(id)__\(filename)"`（production `entry.deletingPathExtension().lastPathComponent`，
    /// 对 fake 等价：所有项同 `.sqlite` 后缀，basename `>` 与 `id__filename` 字符串 `>` 同序）。
    func test_listAvailable_tiebreaker_downloadedAt_desc_then_basename_desc() throws {
        // R1-H2 修订：basename 字典序，不是 id 序——故意用「id=10」+「id=2」反例覆盖跨数量级
        let cache = InMemoryCacheManager()
        let now: Int64 = 1_000
        let earlier: Int64 = 500
        let urlA = URL(fileURLWithPath: "/tmp/a.sqlite")
        // f1: 同 mtime / 较老 ctime → 排末尾
        let f1 = TrainingSetFile(id: 1, filename: "a.sqlite", localURL: urlA, schemaVersion: 1,
                                 lastAccessedAt: now, downloadedAt: earlier)
        // f2 / f10：同 mtime / 同 ctime → basename desc 比较
        // basename(f10) = "10__b.sqlite"；basename(f2) = "2__b.sqlite"
        // 字典序 "2..." > "10..." → f2 在 f10 前
        let f2  = TrainingSetFile(id: 2,  filename: "b.sqlite", localURL: urlA, schemaVersion: 1,
                                  lastAccessedAt: now, downloadedAt: now)
        let f10 = TrainingSetFile(id: 10, filename: "b.sqlite", localURL: urlA, schemaVersion: 1,
                                  lastAccessedAt: now, downloadedAt: now)
        cache._seedForTesting([f1, f2, f10])
        let listed = cache.listAvailable()
        // 期望顺序：[f2, f10, f1]
        // - f2 在 f10 前：同 mtime/ctime，basename "2__b" > "10__b" 字典序
        // - f1 末尾：ctime 较老
        XCTAssertEqual(listed.map(\.id), [2, 10, 1])
    }

    // MARK: - 12-13. touch

    func test_touch_updates_lastAccessedAt() throws {
        let cache = InMemoryCacheManager()
        let f = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: 1, filename: "a.sqlite"))
        Thread.sleep(forTimeInterval: 1.1)
        cache.touch(f)
        XCTAssertGreaterThan(cache.listAvailable()[0].lastAccessedAt, f.lastAccessedAt)
    }

    func test_touch_missing_id_is_silent_noop() {
        let cache = InMemoryCacheManager()
        let phantom = TrainingSetFile(id: 999, filename: "ghost.sqlite",
                                      localURL: URL(fileURLWithPath: "/tmp/g.sqlite"),
                                      schemaVersion: 1, lastAccessedAt: 0, downloadedAt: 0)
        cache.touch(phantom)  // 不抛
        XCTAssertTrue(cache.listAvailable().isEmpty)
    }

    // MARK: - 14-15. delete

    func test_delete_removes_file() throws {
        let cache = InMemoryCacheManager()
        let f = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: 1, filename: "a.sqlite"))
        try cache.delete(f)
        XCTAssertTrue(cache.listAvailable().isEmpty)
    }

    /// R1-H1 修订：production CacheErrorMapping 把缺失文件 NSFileNoSuchFileError 翻成 `.trainingSet(.fileNotFound)`
    /// 不是 `.persistence(.ioError)`（见 `Internal/CacheErrorMapping.swift:24-25` + production
    /// test `DefaultFileSystemCacheManagerTests.swift:118-128`）。R1-M3 修订：紧到具体子 case 避免通配 false-positive。
    func test_delete_missing_throws_trainingSet_fileNotFound() {
        let cache = InMemoryCacheManager()
        let phantom = TrainingSetFile(id: 999, filename: "ghost.sqlite",
                                      localURL: URL(fileURLWithPath: "/tmp/g.sqlite"),
                                      schemaVersion: 1, lastAccessedAt: 0, downloadedAt: 0)
        XCTAssertThrowsError(try cache.delete(phantom)) { err in
            XCTAssertEqual(err as? AppError, .trainingSet(.fileNotFound))
        }
    }

    // MARK: - 16-17. 20-cap evict

    func test_store_21st_evicts_oldest_lastAccessedAt() throws {
        let cache = InMemoryCacheManager()
        // store id=1...20 各间隔 dummy 时间（用 _seedForTesting 直接灌入 20 条）
        var files: [TrainingSetFile] = []
        for i in 1...20 {
            files.append(TrainingSetFile(
                id: i, filename: "f\(i).sqlite",
                localURL: URL(fileURLWithPath: "/tmp/\(i).sqlite"),
                schemaVersion: 1,
                lastAccessedAt: Int64(i),  // i=1 最旧, i=20 最新
                downloadedAt: Int64(i)
            ))
        }
        cache._seedForTesting(files)
        XCTAssertEqual(cache.listAvailable().count, 20)
        // 第 21 条 store 通过正常路径
        _ = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: 21, filename: "f21.sqlite"))
        let listed = cache.listAvailable()
        XCTAssertEqual(listed.count, 20, "20-cap 触发驱逐")
        XCTAssertNil(listed.first(where: { $0.id == 1 }), "id=1（lastAccessedAt 最旧）应被驱逐")
        XCTAssertNotNil(listed.first(where: { $0.id == 21 }), "新 store 的 id=21 应在")
    }

    // MARK: - 18. pickRandom

    func test_pickRandom_returns_member_when_nonempty() throws {
        let cache = InMemoryCacheManager()
        for i in 1...3 {
            _ = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: i, filename: "f\(i).sqlite"))
        }
        let picked = cache.pickRandom()
        XCTAssertNotNil(picked)
        XCTAssertTrue(cache.listAvailable().contains(picked!))
    }

    // MARK: - 19. 并发安全

    func test_concurrent_store_does_not_corrupt() {
        let cache = InMemoryCacheManager()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for i in 1...10 {
            group.enter()
            queue.async {
                _ = try? cache.store(downloadedZip: self.dummyZip,
                                     meta: self.makeMeta(id: i, filename: "f\(i).sqlite"))
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(cache.listAvailable().count, 10)
        XCTAssertEqual(Set(cache.listAvailable().map(\.id)), Set(1...10))
    }

    /// R1-L2 修订：mirror PR4b `DefaultFileSystemCacheManagerTests:194-200` 撞同 slot 模式——
    /// 100 次并发 store 同 id 应收敛到 1 条 dict slot（无 lock 时 dict 撞写会 trap 或 lose write）。
    func test_concurrent_store_same_id_converges_to_single_slot() {
        let cache = InMemoryCacheManager()
        let id = 42
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            _ = try? cache.store(
                downloadedZip: self.dummyZip,
                meta: self.makeMeta(id: id, filename: "racer-\(i).sqlite")
            )
        }
        let listed = cache.listAvailable()
        XCTAssertEqual(listed.count, 1, "100 次同 id 并发 store 应收敛到 1 条")
        XCTAssertEqual(listed[0].id, id)
    }
}
#endif

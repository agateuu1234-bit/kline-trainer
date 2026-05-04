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

    // MARK: - Task 3: LRU evict / same-id overwrite / concurrent store

    @Test("store: 超 maxCachedSets=20 时驱逐 mtime 最老的")
    func store_evictsOldestWhenExceedsMaxCachedSets() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        // 写 20 个，每个间隔确保 mtime 单调
        var firstFile: TrainingSetFile?
        for i in 1...20 {
            let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
            let f = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: i, filename: "f\(i).sqlite"))
            if i == 1 { firstFile = f }
            if i < 20 { Thread.sleep(forTimeInterval: 1.1) }
        }
        #expect(cache.listAvailable().count == 20)

        Thread.sleep(forTimeInterval: 1.1)
        // 第 21 个 → 应驱逐 id=1（mtime 最老）
        let s21 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        _ = try cache.store(downloadedZip: s21, meta: CacheFixture.meta(id: 21, filename: "f21.sqlite"))

        let after = cache.listAvailable()
        #expect(after.count == 20)
        #expect(!after.contains { $0.id == 1 }, "id=1 应被驱逐")
        #expect(after.contains { $0.id == 21 }, "id=21 应在")
        if let f = firstFile {
            #expect(!FileManager.default.fileExists(atPath: f.localURL.path),
                    "id=1 物理文件应被删")
        }
    }

    @Test("store: 同 id 重新 store 覆盖旧文件，listAvailable 仍只 1 条")
    func store_sameIdOverwritesOldFile() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        let s1 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        _ = try cache.store(downloadedZip: s1, meta: CacheFixture.meta(id: 5, filename: "x.sqlite"))
        let s2 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        let r2 = try cache.store(downloadedZip: s2, meta: CacheFixture.meta(id: 5, filename: "x.sqlite"))

        let all = cache.listAvailable()
        #expect(all.count == 1)
        #expect(all[0].id == 5)
        // /var/folders ↔ /private/var/folders 是 macOS symlink → 比较解析后的路径
        #expect(all[0].localURL.resolvingSymlinksInPath().path
                == r2.localURL.resolvingSymlinksInPath().path)
    }

    @Test("store: 并发 10 次不同 id 全部成功 + listAvailable count=10")
    func store_concurrentDifferentIds_allSucceed() async throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 1...10 {
                group.addTask {
                    let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
                    _ = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: i, filename: "p\(i).sqlite"))
                }
            }
            try await group.waitForAll()
        }
        #expect(cache.listAvailable().count == 10)
    }

    // MARK: - Task 4: error paths + R1-R6 regressions

    @Test("store: src 文件不存在抛 .trainingSet(.fileNotFound)")
    func store_srcMissingThrowsFileNotFound() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID()).sqlite")
        #expect(throws: AppError.trainingSet(.fileNotFound)) {
            try cache.store(downloadedZip: ghost,
                            meta: CacheFixture.meta(id: 1, filename: "x.sqlite"))
        }
    }

    @Test("store: src 不是合法 sqlite 抛 .persistence(.dbCorrupted)（PRAGMA 读失败）")
    func store_invalidSqliteThrowsDbCorrupted() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("bogus-\(UUID()).sqlite")
        try Data("not a sqlite".utf8).write(to: bogus)
        #expect(throws: AppError.persistence(.dbCorrupted)) {
            try cache.store(downloadedZip: bogus,
                            meta: CacheFixture.meta(id: 1, filename: "x.sqlite"))
        }
    }

    // R1 H-1 regression: 同 id 重新 store 的 src 损坏时，旧 cache 应保留
    @Test("store: 已存在 id 的 src 损坏时旧 cache 不丢（rollback safe）")
    func store_invalidNewSqlite_oldCachePreserved() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        let valid1 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        let f1 = try cache.store(downloadedZip: valid1, meta: CacheFixture.meta(id: 5, filename: "stk.sqlite"))
        #expect(FileManager.default.fileExists(atPath: f1.localURL.path))

        // 第二次 store 同 id 但 src 损坏
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("bogus-\(UUID()).sqlite")
        try Data("not a sqlite".utf8).write(to: bogus)
        #expect(throws: AppError.persistence(.dbCorrupted)) {
            try cache.store(downloadedZip: bogus,
                            meta: CacheFixture.meta(id: 5, filename: "stk.sqlite"))
        }

        // 旧 cache 应仍在 + 仍可读
        #expect(FileManager.default.fileExists(atPath: f1.localURL.path), "旧 cache 文件应保留")
        let listed = cache.listAvailable()
        #expect(listed.count == 1)
        #expect(listed[0].id == 5)
        #expect(listed[0].schemaVersion == 1)

        // 不应有 staging 残留
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let stagingResidue = entries.filter { $0.hasPrefix(".staging-") }
        #expect(stagingResidue.isEmpty, "staging 文件应被 defer 清理：\(stagingResidue)")
    }

    // R1 H-2 regression: src 文件 mtime 老不影响 evict
    @Test("store: src 文件 mtime 远古，store 后新 cache 不会被立刻 evict")
    func store_oldMtimeSrc_doesNotEvictNewCache() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        // 准备 19 个 fresh cache
        for i in 1...19 {
            let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
            _ = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: i, filename: "f\(i).sqlite"))
        }

        // 第 20 个：src 的 mtime 设到 2000-01-01（远古）
        let oldSrc = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 946_684_800)],  // 2000-01-01
            ofItemAtPath: oldSrc.path)
        let f20 = try cache.store(downloadedZip: oldSrc, meta: CacheFixture.meta(id: 20, filename: "f20.sqlite"))

        // 第 21 个 → 应驱逐 mtime 最老的；id=20 因 store 时 touch 过，mtime=now，不应被驱逐
        let s21 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        _ = try cache.store(downloadedZip: s21, meta: CacheFixture.meta(id: 21, filename: "f21.sqlite"))

        let after = cache.listAvailable()
        #expect(after.count == 20)
        #expect(after.contains { $0.id == 20 }, "id=20 不应因 src 老 mtime 被 evict")
        #expect(after.contains { $0.id == 21 })
        #expect(FileManager.default.fileExists(atPath: f20.localURL.path))
    }

    // R2 H-1 regression: 空 cache 首次 store 不应 throw（replaceItemAt 假定 target 存在）
    @Test("store: 空 cache 首次 store 走 moveItem 路径 success（不走 replaceItemAt）")
    func store_emptyCacheFirstStore_succeeds() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)
        // 确认 cache 是空的
        #expect(cache.listAvailable().isEmpty)

        let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        let r = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: 99, filename: "first.sqlite"))
        #expect(r.id == 99)
        #expect(FileManager.default.fileExists(atPath: r.localURL.path))
        #expect(cache.listAvailable().count == 1)
    }

    // R2 H-2 regression: 21 rapid same-second stores LRU 顺序稳定
    @Test("store: 21 个连续 store（无 sleep，多数同秒）evict 应删 id=1（最早 store）")
    func store_21RapidStores_evictsOldestStored() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        // 21 个连续 store，无 sleep。每次 setAttributes 调用 takes ~us，纳秒精度 mtime 差异化。
        for i in 1...21 {
            let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
            _ = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: i, filename: "r\(i).sqlite"))
        }

        let after = cache.listAvailable()
        #expect(after.count == 20)
        // id=21 必在（刚 store 的）
        #expect(after.contains { $0.id == 21 })
        // 按"最早 store 应最先被 evict"逻辑，id=1 应被删（21 个里 mtime/ctime 最旧）
        #expect(!after.contains { $0.id == 1 }, "首次 store 的 id=1 应被 evict")
    }

    // R3 H-2 + R4 H-2 regression: caller 传带 path traversal 或非 .sqlite 扩展的 filename → 拒收
    @Test("store: filename 含 / .. \\ NULL / staging 前缀 / 非 .sqlite 扩展应拒")
    func store_filenameValidationRejectsBadInputs() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)
        let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)

        let bad: [String] = [
            "../escape.sqlite",
            "sub/dir.sqlite",
            "with\\back.sqlite",
            "..",
            "",
            ".staging-stealth.sqlite",
            "with\u{0000}null.sqlite",
            // R4 H-2: 非 .sqlite 扩展应拒，否则 listAvailable 按 .sqlite 过滤 → 孤儿绕 LRU cap
            "foo.db",
            "noext",
            "trailingdot.sqlite.",
        ]
        for name in bad {
            #expect(throws: (any Error).self, "应拒 filename: \(name)") {
                try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: 1, filename: name))
            }
        }
    }

    // R3 H-2 regression: caller 给 file.localURL 指向 cache 外文件 → delete 不删该外部文件
    @Test("delete: 不信任 file.localURL，从 id+filename 内部派生；外部文件不被删")
    func delete_doesNotTrustLocalURL_externalFileSafe() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        // 在 cache 外创建一个 victim 文件
        let victim = FileManager.default.temporaryDirectory
            .appendingPathComponent("victim-\(UUID()).sqlite")
        try Data("important".utf8).write(to: victim)
        defer { try? FileManager.default.removeItem(at: victim) }

        // 构造一个 TrainingSetFile：id+filename 指向 cache 内一个不存在的项；localURL 指 victim
        let evil = TrainingSetFile(
            id: 999, filename: "ghost.sqlite",
            localURL: victim,  // ← caller 引导 cache 操作 victim
            schemaVersion: 1, lastAccessedAt: 0, downloadedAt: 0)

        // delete 应基于 id+filename 派生 → 派生路径 = cacheRoot/999__ghost.sqlite，不存在 → fileNotFound
        #expect(throws: AppError.trainingSet(.fileNotFound)) {
            try cache.delete(evil)
        }
        // victim 必须仍在
        #expect(FileManager.default.fileExists(atPath: victim.path), "外部文件不应被 cache 操作影响")
    }

    // R5 M-3 regression: pre-existing .staging-* 文件被清，不绕 LRU cap
    @Test("store: cache root 内残留 .staging-* 文件首次 store 时被清")
    func store_firstCallCleansStaleStagingFiles() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        // 预 - 留 2 个残留 staging 文件
        let stale1 = root.appendingPathComponent(".staging-OLD1__99__leftover.sqlite")
        let stale2 = root.appendingPathComponent(".staging-OLD2__88__leftover.sqlite")
        try Data("dummy".utf8).write(to: stale1)
        try Data("dummy".utf8).write(to: stale2)
        #expect(FileManager.default.fileExists(atPath: stale1.path))
        #expect(FileManager.default.fileExists(atPath: stale2.path))

        let cache = DefaultFileSystemCacheManager(cacheRoot: root)
        // 触发 cleanup（首次 store 进 queue.sync 内调）
        let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        _ = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: 7, filename: "x.sqlite"))

        // 残留 staging 应被清
        #expect(!FileManager.default.fileExists(atPath: stale1.path), "stale1 应被清")
        #expect(!FileManager.default.fileExists(atPath: stale2.path), "stale2 应被清")
        // 当前 store 的 cache 应在
        #expect(cache.listAvailable().count == 1)
    }

    // codex post-impl R7 regression: REST meta.filename 是 .zip，cache 应规范化为 .sqlite
    @Test("store: meta.filename=`<base>.zip` 时，cache 持久化为 `<id>__<base>.sqlite` + 返回 .sqlite")
    func store_zipMetaFilename_normalizesToSqliteOnDisk() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        // 模拟真实 REST shape：meta.filename 是 zip 名（e.g. RESTDTOsTests `600519_202001.zip`）
        let r = try cache.store(downloadedZip: s,
                                meta: CacheFixture.meta(id: 600519, filename: "600519_202001.zip"))

        // 返回的 TrainingSetFile.filename 应是规范化后的 .sqlite
        #expect(r.filename == "600519_202001.sqlite")
        #expect(r.localURL.lastPathComponent == "600519__600519_202001.sqlite")
        #expect(FileManager.default.fileExists(atPath: r.localURL.path))
        // listAvailable 也应能 round-trip 出来
        let listed = cache.listAvailable()
        #expect(listed.count == 1)
        #expect(listed[0].id == 600519)
        #expect(listed[0].filename == "600519_202001.sqlite")
    }

    // R3 H-2 regression: touch 同样不信任 localURL
    @Test("touch: 不信任 file.localURL，外部文件 mtime 不变")
    func touch_doesNotTrustLocalURL_externalFileMtimeUnchanged() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        let victim = FileManager.default.temporaryDirectory
            .appendingPathComponent("victim-\(UUID()).sqlite")
        try Data("important".utf8).write(to: victim)
        defer { try? FileManager.default.removeItem(at: victim) }
        // 设 victim mtime = 2000-01-01
        let oldDate = Date(timeIntervalSince1970: 946_684_800)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: victim.path)

        let evil = TrainingSetFile(
            id: 1234, filename: "fake.sqlite", localURL: victim,
            schemaVersion: 1, lastAccessedAt: 0, downloadedAt: 0)
        cache.touch(evil)  // best-effort，不抛；内部派生路径不存在 → no-op

        // victim mtime 必须仍为 2000-01-01
        let attrs = try FileManager.default.attributesOfItem(atPath: victim.path)
        let actualMtime = (attrs[.modificationDate] as? Date) ?? Date()
        #expect(abs(actualMtime.timeIntervalSince1970 - oldDate.timeIntervalSince1970) < 1,
                "外部文件 mtime 不应被 cache.touch 影响")
    }
}

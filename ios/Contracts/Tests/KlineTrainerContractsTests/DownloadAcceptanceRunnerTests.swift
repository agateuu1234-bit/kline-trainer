import Testing
import Foundation
@testable import KlineTrainerContracts

// MARK: - 测试本地 helper（仅本套件用，不进 Sources 公共 fake 面）

/// 可配置 APIClient 替身：download 返回固定 URL 或抛错；confirm 按序列 / 默认值决定成功/抛错。
private final class FakeAPIClient: APIClient, @unchecked Sendable {
    private let lock = NSLock()
    private let _download: Result<URL, AppError>
    private var _confirmSeq: [AppError?]          // 按调用顺序消费；nil = 成功
    private let _confirmDefault: AppError?         // 序列耗尽后的默认
    private var _downloadCalls: [Int] = []
    private var _confirmCalls: [(id: Int, leaseId: String)] = []

    init(download: Result<URL, AppError> = .success(URL(fileURLWithPath: "/tmp/ZipExtract-test/dl.zip")),
         confirmError: AppError? = nil,
         confirmSequence: [AppError?] = []) {
        _download = download
        _confirmDefault = confirmError
        _confirmSeq = confirmSequence
    }

    func reserveTrainingSets(count: Int) async throws -> LeaseResponse {
        throw AppError.internalError(module: "test", detail: "reserve_unused")
    }
    func downloadTrainingSet(id: Int) async throws -> URL {
        let r = lock.withLock { () -> Result<URL, AppError> in
            _downloadCalls.append(id)
            return _download
        }
        switch r { case .success(let u): return u; case .failure(let e): throw e }
    }
    func confirmTrainingSet(id: Int, leaseId: String) async throws {
        let err = lock.withLock { () -> AppError? in
            _confirmCalls.append((id, leaseId))
            return _confirmSeq.isEmpty ? _confirmDefault : _confirmSeq.removeFirst()
        }
        if let err { throw err }
    }
    var confirmCallCount: Int { lock.withLock { _confirmCalls.count } }
    var downloadCallCount: Int { lock.withLock { _downloadCalls.count } }
}

/// 极简 reader：dataVerifier 是 fake 会忽略它；唯一观测点是 close() 是否被调用。
private final class StubReader: TrainingSetReader, @unchecked Sendable {
    private let lock = NSLock()
    private var _closed = false
    func loadMeta() throws -> TrainingSetMeta {
        TrainingSetMeta(stockCode: "T", stockName: "T", startDatetime: 1, endDatetime: 1)
    }
    func loadAllCandles() throws -> [Period: [KLineCandle]] { [:] }
    func close() { lock.withLock { _closed = true } }
    var closed: Bool { lock.withLock { _closed } }
}

/// 可配置 factory：成功返回可观测 StubReader；或抛注入错误（测 .versionMismatch 分支）。
private final class StubDBFactory: TrainingSetDBFactory, @unchecked Sendable {
    private let error: AppError?
    private let lock = NSLock()
    private var _lastReader: StubReader?
    private var _lastExpectedVersion: Int?
    init(error: AppError? = nil) { self.error = error }
    func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
        lock.withLock { _lastExpectedVersion = expectedSchemaVersion }
        if let error { throw error }
        let r = StubReader()
        lock.withLock { _lastReader = r }
        return r
    }
    var lastReader: StubReader? { lock.withLock { _lastReader } }
    var lastExpectedVersion: Int? { lock.withLock { _lastExpectedVersion } }
}

/// 包装 InMemoryAcceptanceJournalDAO，额外记录所有「未抛错的 upsert 意图」状态序列，
/// 用于断言 runner 的状态推进顺序（含 stored→confirmPending→confirmed 的中间态）。
private final class RecordingJournalDAO: AcceptanceJournalDAO, @unchecked Sendable {
    let inner = InMemoryAcceptanceJournalDAO()
    private let lock = NSLock()
    private var _seq: [P2JournalState] = []
    func upsert(trainingSetId: Int, leaseId: String, state: P2JournalState,
                sqliteLocalPath: String?, contentHash: String?, lastError: String?) throws {
        try inner.upsert(trainingSetId: trainingSetId, leaseId: leaseId, state: state,
                         sqliteLocalPath: sqliteLocalPath, contentHash: contentHash, lastError: lastError)
        lock.withLock { _seq.append(state) }
    }
    func listByState(_ state: P2JournalState) throws -> [AcceptanceJournalRow] { try inner.listByState(state) }
    func deleteByIdLease(trainingSetId: Int, leaseId: String) throws {
        try inner.deleteByIdLease(trainingSetId: trainingSetId, leaseId: leaseId)
    }
    var sequence: [P2JournalState] { lock.withLock { _seq } }
}

/// integrity 抛 CancellationError 的替身（测 asAppError 取消映射分支）。
private struct CancellingIntegrity: ZipIntegrityVerifying {
    func verify(zipURL: URL, expectedCRC32Hex: String) throws { throw CancellationError() }
}

/// 让 id 越小睡越久（越晚完成）——用于验证 runBatch 按输入序而非完成序返回。
private final class DelayedDownloadAPIClient: APIClient, @unchecked Sendable {
    private let downloadURL: URL
    private let unitNanos: UInt64
    init(downloadURL: URL = URL(fileURLWithPath: "/tmp/ZipExtract-d/x.sqlite"),
         unitNanos: UInt64 = 20_000_000) {  // 20ms
        self.downloadURL = downloadURL; self.unitNanos = unitNanos
    }
    func reserveTrainingSets(count: Int) async throws -> LeaseResponse {
        throw AppError.internalError(module: "test", detail: "unused")
    }
    func downloadTrainingSet(id: Int) async throws -> URL {
        // 低 id 睡更久：id=1 睡 3*unit，id=2 睡 2*unit，id=3 睡 1*unit（假设 ids 1...N）
        try? await Task.sleep(nanoseconds: unitNanos * UInt64(max(1, 5 - id)))
        return downloadURL
    }
    func confirmTrainingSet(id: Int, leaseId: String) async throws {}  // 成功
}

/// store 固定抛错的 cache 替身（测 step 6 失败）。其它方法 no-op。
private final class ThrowingStoreCache: CacheManager, @unchecked Sendable {
    private let error: AppError
    init(error: AppError) { self.error = error }
    func listAvailable() -> [TrainingSetFile] { [] }
    func pickRandom() -> TrainingSetFile? { nil }
    func store(downloadedZip: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile { throw error }
    func touch(_: TrainingSetFile) {}
    func delete(_: TrainingSetFile) throws {}
}

// MARK: - 共享构造 helper

private func makeMeta(id: Int = 1, contentHash: String = "deadbeef") -> TrainingSetMetaItem {
    TrainingSetMetaItem(id: id, stockCode: "000001", stockName: "平安银行",
                        filename: "set\(id).zip", schemaVersion: 1, contentHash: contentHash)
}

@Suite("P2 DownloadAcceptanceRunner")
struct DownloadAcceptanceRunnerTests {

    @Test func constructs_withAllFakes_compilesAsSendable() {
        let runner = DownloadAcceptanceRunner(
            api: FakeAPIClient(),
            cache: InMemoryCacheManager(),
            dbFactory: StubDBFactory(),
            journal: InMemoryAcceptanceJournalDAO(),
            integrity: FakeZipIntegrityVerifier(),
            extractor: FakeZipExtractor(),
            dataVerifier: FakeTrainingSetDataVerifier(),
            cleaner: FakeDownloadAcceptanceCleaner())
        let _: any Sendable = runner   // 编译期断言 Sendable
    }

    /// 构造一个除指定失败点外全成功的 runner。
    private func makeRunner(
        api: any APIClient = FakeAPIClient(),
        cache: CacheManager = InMemoryCacheManager(),
        journal: AcceptanceJournalDAO = InMemoryAcceptanceJournalDAO(),
        factory: TrainingSetDBFactory = StubDBFactory(),
        integrity: ZipIntegrityVerifying = FakeZipIntegrityVerifier(),
        extractor: ZipExtracting = FakeZipExtractor(returnURL: URL(fileURLWithPath: "/tmp/ZipExtract-y/x.sqlite")),
        dataVerifier: TrainingSetDataVerifying = FakeTrainingSetDataVerifier(),
        cleaner: DownloadAcceptanceCleaning = FakeDownloadAcceptanceCleaner()
    ) -> DownloadAcceptanceRunner {
        DownloadAcceptanceRunner(api: api, cache: cache, dbFactory: factory, journal: journal,
                                 integrity: integrity, extractor: extractor,
                                 dataVerifier: dataVerifier, cleaner: cleaner)
    }

    @Test func run_happyPath_returnsConfirmed_walksFullStateMachine() async throws {
        let meta = makeMeta(id: 7, contentHash: "0badf00d")
        let api = FakeAPIClient(confirmError: nil)               // confirm 成功
        let cache = InMemoryCacheManager()
        let journal = RecordingJournalDAO()
        let cleaner = FakeDownloadAcceptanceCleaner()
        let factory = StubDBFactory()
        let runner = DownloadAcceptanceRunner(
            api: api, cache: cache, dbFactory: factory, journal: journal,
            integrity: FakeZipIntegrityVerifier(),
            extractor: FakeZipExtractor(returnURL: URL(fileURLWithPath: "/tmp/ZipExtract-x/set7.sqlite")),
            dataVerifier: FakeTrainingSetDataVerifier(),
            cleaner: cleaner)

        let result = await runner.run(meta: meta, leaseId: "11111111-1111-1111-1111-111111111111")

        // 1) 返回 confirmed + file 落在 cache
        guard case .confirmed(let file) = result else {
            Issue.record("expected .confirmed, got \(result)"); return
        }
        #expect(file.id == 7)
        #expect(cache.listAvailable().contains(where: { $0.id == 7 }))

        // 2) 状态推进顺序（含中间态；stored→confirmed 必经 confirmPending）
        #expect(journal.sequence == [.downloaded, .crcOK, .unzipped, .dbVerified, .stored, .confirmPending, .confirmed])

        // 3) 最终 applied 状态 = confirmed（1 行）
        #expect(try journal.listByState(.confirmed).count == 1)
        #expect(try journal.listByState(.stored).isEmpty)

        // 4) reader 已关闭；expectedSchemaVersion 传共享常量
        #expect(factory.lastReader?.closed == true)
        #expect(factory.lastExpectedVersion == TRAINING_SET_SCHEMA_VERSION)

        // 5) temp 已清理（下载 zip + 解压临时目录），cache 副本不在清理列表
        let cleaned = cleaner.cleanedURLs().map(\.path)
        #expect(cleaned.contains("/tmp/ZipExtract-test/dl.zip"))
        #expect(cleaned.contains("/tmp/ZipExtract-x"))   // = sqlite.deletingLastPathComponent()
    }

    @Test func run_downloadFails_rejected_noJournalRow() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cleaner = FakeDownloadAcceptanceCleaner()
        let runner = makeRunner(api: FakeAPIClient(download: .failure(.network(.offline))),
                                journal: journal, cleaner: cleaner)
        let result = await runner.run(meta: makeMeta(), leaseId: "lease")
        #expect(result == .rejected(.network(.offline)))
        // 无 journal 行（download 完成前不写）
        for s in P2JournalState.allCases { #expect(try journal.listByState(s).isEmpty) }
        // download 未成功 → 无 temp 可清
        #expect(cleaner.cleanedURLs().isEmpty)
    }

    @Test func run_crcFails_rejected_journalRejected_cleaned() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cleaner = FakeDownloadAcceptanceCleaner()
        let runner = makeRunner(journal: journal,
                                integrity: FakeZipIntegrityVerifier(throwing: .trainingSet(.crcFailed)),
                                cleaner: cleaner)
        let result = await runner.run(meta: makeMeta(), leaseId: "lease")
        #expect(result == .rejected(.trainingSet(.crcFailed)))
        #expect(try journal.listByState(.rejected).count == 1)
        #expect(cleaner.cleanedURLs().map(\.path).contains("/tmp/ZipExtract-test/dl.zip"))
    }

    @Test func run_extractFails_rejected_journalRejected() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cleaner = FakeDownloadAcceptanceCleaner()
        let runner = makeRunner(journal: journal,
                                extractor: FakeZipExtractor(throwing: .trainingSet(.unzipFailed)),
                                cleaner: cleaner)
        let result = await runner.run(meta: makeMeta(), leaseId: "lease")
        #expect(result == .rejected(.trainingSet(.unzipFailed)))
        #expect(try journal.listByState(.rejected).count == 1)
        #expect(cleaner.cleanedURLs().map(\.path).contains("/tmp/ZipExtract-test/dl.zip"))
    }

    @Test func run_openVerifyFails_rejected_versionMismatch() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let runner = makeRunner(journal: journal,
                                factory: StubDBFactory(error: .trainingSet(.versionMismatch(expected: 1, got: 2))))
        let result = await runner.run(meta: makeMeta(), leaseId: "lease")
        #expect(result == .rejected(.trainingSet(.versionMismatch(expected: 1, got: 2))))
        #expect(try journal.listByState(.rejected).count == 1)
    }

    @Test func run_verifyNonEmptyFails_rejected_emptyData_readerClosed() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let factory = StubDBFactory()
        let runner = makeRunner(journal: journal, factory: factory,
                                dataVerifier: FakeTrainingSetDataVerifier(throwing: .trainingSet(.emptyData)))
        let result = await runner.run(meta: makeMeta(), leaseId: "lease")
        #expect(result == .rejected(.trainingSet(.emptyData)))
        #expect(try journal.listByState(.rejected).count == 1)
        #expect(factory.lastReader?.closed == true)   // 失败路径也关闭 reader
    }

    @Test func run_cacheStoreFails_rejected_persistence() async throws {
        // 用抛错 cache：自定义一个只在 store 抛 diskFull 的替身
        let journal = InMemoryAcceptanceJournalDAO()
        let runner = makeRunner(cache: ThrowingStoreCache(error: .persistence(.diskFull)), journal: journal)
        let result = await runner.run(meta: makeMeta(), leaseId: "lease")
        #expect(result == .rejected(.persistence(.diskFull)))
        #expect(try journal.listByState(.rejected).count == 1)
        #expect(try journal.listByState(.stored).isEmpty)
    }

    @Test func run_confirm409_rejected_deletesLocalFile() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = InMemoryCacheManager()
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.leaseExpired)),
                                cache: cache, journal: journal)
        let result = await runner.run(meta: makeMeta(id: 3), leaseId: "lease")
        #expect(result == .rejected(.network(.leaseExpired)))
        #expect(try journal.listByState(.rejected).count == 1)
        #expect(cache.listAvailable().contains(where: { $0.id == 3 }) == false)  // 本地副本已删
    }

    @Test func run_confirm404_rejected_deletesLocalFile() async throws {
        let cache = InMemoryCacheManager()
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.leaseNotFound)), cache: cache)
        let result = await runner.run(meta: makeMeta(id: 4), leaseId: "lease")
        #expect(result == .rejected(.network(.leaseNotFound)))
        #expect(cache.listAvailable().contains(where: { $0.id == 4 }) == false)
    }

    @Test func run_confirmNetworkUncertain_rejected_butKeepsFileAndPending() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = InMemoryCacheManager()
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.timeout)),
                                cache: cache, journal: journal)
        let result = await runner.run(meta: makeMeta(id: 5), leaseId: "lease")
        #expect(result == .rejected(.network(.timeout)))
        // 文件保留 + journal 停 confirmPending（待启动重试）
        #expect(cache.listAvailable().contains(where: { $0.id == 5 }))
        #expect(try journal.listByState(.confirmPending).count == 1)
        #expect(try journal.listByState(.rejected).isEmpty)
    }

    @Test func run_confirmServerError5xx_keepsFileAndPending() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = InMemoryCacheManager()
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.serverError(code: 503))),
                                cache: cache, journal: journal)
        let result = await runner.run(meta: makeMeta(id: 6), leaseId: "lease")
        #expect(result == .rejected(.network(.serverError(code: 503))))
        #expect(cache.listAvailable().contains(where: { $0.id == 6 }))   // 5xx 非 409/404 → 保留
        #expect(try journal.listByState(.confirmPending).count == 1)
    }

    @Test func run_cancellationError_mappedToInternalP2() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let runner = makeRunner(journal: journal, integrity: CancellingIntegrity())
        let result = await runner.run(meta: makeMeta(), leaseId: "lease")
        #expect(result == .rejected(.internalError(module: "P2", detail: "cancelled")))
        #expect(try journal.listByState(.rejected).count == 1)
    }

    // MARK: - Task 5: retryPendingConfirmations

    /// 直接在 journal 灌一条已 stored 的行（绕过 run，模拟「上次运行落盘后崩溃」）。
    private func seedStored(_ journal: AcceptanceJournalDAO, id: Int, leaseId: String,
                           path: String, hash: String = "0badf00d") throws {
        // 状态机要求顺序推进 downloaded→crcOK→unzipped→dbVerified→stored；
        // 少灌任一步，InMemoryAcceptanceJournalDAO 会因非法 transition 抛 AppError.internalError。
        try journal.upsert(trainingSetId: id, leaseId: leaseId, state: .downloaded,
                           sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try journal.upsert(trainingSetId: id, leaseId: leaseId, state: .crcOK,
                           sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try journal.upsert(trainingSetId: id, leaseId: leaseId, state: .unzipped,
                           sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try journal.upsert(trainingSetId: id, leaseId: leaseId, state: .dbVerified,
                           sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try journal.upsert(trainingSetId: id, leaseId: leaseId, state: .stored,
                           sqliteLocalPath: path, contentHash: hash, lastError: nil)
    }

    @Test func retry_storedRow_confirmSuccess_becomesConfirmed() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        try seedStored(journal, id: 1, leaseId: "L1", path: "/tmp/a.sqlite")
        let runner = makeRunner(api: FakeAPIClient(confirmError: nil), journal: journal)
        await runner.retryPendingConfirmations()
        #expect(try journal.listByState(.confirmed).count == 1)
        #expect(try journal.listByState(.stored).isEmpty)
    }

    @Test func retry_storedRow_confirmSuccess_confirmedAndFileRetained() async throws {
        // spec §P2 L1835 验收 case 1：stored 后 kill → 启动 confirmed + 本地 sqlite 保留
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = InMemoryCacheManager()
        // 模拟「上次 store 完成后崩溃」：cache 有文件 + journal = stored
        let file = try cache.store(downloadedZip: URL(fileURLWithPath: "/tmp/s.sqlite"), meta: makeMeta(id: 1))
        try seedStored(journal, id: 1, leaseId: "L1", path: file.localURL.path)
        let runner = makeRunner(api: FakeAPIClient(confirmError: nil), cache: cache, journal: journal)
        await runner.retryPendingConfirmations()
        #expect(try journal.listByState(.confirmed).count == 1)         // 推进到 confirmed
        #expect(cache.listAvailable().contains(where: { $0.id == 1 }))  // sqlite 保留（未被删）
    }

    @Test func retry_confirmPendingRow_confirmSuccess_becomesConfirmed() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        try seedStored(journal, id: 2, leaseId: "L2", path: "/tmp/b.sqlite")
        try journal.upsert(trainingSetId: 2, leaseId: "L2", state: .confirmPending,
                           sqliteLocalPath: "/tmp/b.sqlite", contentHash: nil, lastError: nil)
        let runner = makeRunner(api: FakeAPIClient(confirmError: nil), journal: journal)
        await runner.retryPendingConfirmations()
        #expect(try journal.listByState(.confirmed).count == 1)
    }

    @Test func retry_scansBothStoredAndConfirmPending() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        try seedStored(journal, id: 1, leaseId: "L1", path: "/tmp/1.sqlite")          // stored
        try seedStored(journal, id: 2, leaseId: "L2", path: "/tmp/2.sqlite")
        try journal.upsert(trainingSetId: 2, leaseId: "L2", state: .confirmPending,
                           sqliteLocalPath: "/tmp/2.sqlite", contentHash: nil, lastError: nil)  // confirmPending
        let runner = makeRunner(api: FakeAPIClient(confirmError: nil), journal: journal)
        await runner.retryPendingConfirmations()
        #expect(try journal.listByState(.confirmed).count == 2)   // 两类都被扫到
    }

    @Test func retry_confirm409_rejectsAndDeletesCacheFile() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = InMemoryCacheManager()
        // 先把文件灌进 cache（id=9）
        _ = try cache.store(downloadedZip: URL(fileURLWithPath: "/tmp/9.zip"), meta: makeMeta(id: 9))
        try seedStored(journal, id: 9, leaseId: "L9", path: "/tmp/9.sqlite")
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.leaseNotFound)),
                                cache: cache, journal: journal)
        await runner.retryPendingConfirmations()
        #expect(try journal.listByState(.rejected).count == 1)
        #expect(cache.listAvailable().contains(where: { $0.id == 9 }) == false)  // 本地副本已删
    }

    @Test func retry_confirmNetworkUncertain_staysPending_keepsFile() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = InMemoryCacheManager()
        _ = try cache.store(downloadedZip: URL(fileURLWithPath: "/tmp/8.zip"), meta: makeMeta(id: 8))
        try seedStored(journal, id: 8, leaseId: "L8", path: "/tmp/8.sqlite")
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.offline)),
                                cache: cache, journal: journal)
        await runner.retryPendingConfirmations()
        #expect(try journal.listByState(.confirmPending).count == 1)
        #expect(try journal.listByState(.rejected).isEmpty)
        #expect(cache.listAvailable().contains(where: { $0.id == 8 }))  // 保留
    }

    @Test func retry_emptyJournal_noCrash() async {
        let runner = makeRunner(journal: InMemoryAcceptanceJournalDAO())
        await runner.retryPendingConfirmations()   // 无行 → 安全 no-op
    }

    // MARK: - Task 6: runBatch

    private func makeLease(ids: [Int], leaseId: String = "BL") -> LeaseResponse {
        LeaseResponse(leaseId: leaseId, expiresAt: "2026-12-31T00:00:00Z",
                      sets: ids.map { makeMeta(id: $0) })
    }

    @Test func runBatch_empty_returnsEmpty() async {
        let runner = makeRunner()
        let results = await runner.runBatch(lease: makeLease(ids: []))
        #expect(results.isEmpty)
    }

    @Test func runBatch_serial_resultsInInputOrder() async throws {
        let runner = makeRunner(api: FakeAPIClient(confirmError: nil))
        let results = await runner.runBatch(lease: makeLease(ids: [10, 11, 12]), concurrency: 1)
        #expect(results.count == 3)
        for r in results { if case .rejected = r { Issue.record("expected all confirmed") } }
        // 保序：confirmed file.id 与输入顺序一致
        let ids = results.map { r -> Int? in if case .confirmed(let f) = r { return f.id } else { return nil } }
        #expect(ids == [10, 11, 12])
    }

    @Test func runBatch_concurrency2_allProcessed_orderPreserved() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let runner = makeRunner(api: FakeAPIClient(confirmError: nil), journal: journal)
        let results = await runner.runBatch(lease: makeLease(ids: [1, 2, 3, 4, 5]), concurrency: 2)
        let ids = results.map { r -> Int? in if case .confirmed(let f) = r { return f.id } else { return nil } }
        #expect(ids == [1, 2, 3, 4, 5])
        // 并发写不互相污染 journal：每个 id 各有独立 confirmed 行（R1 Low-2 修订）
        #expect(try journal.listByState(.confirmed).count == 5)
    }

    @Test func runBatch_resultsOrderedByInputNotCompletion() async throws {
        // concurrency=3 同时起跑；id=3 最先完成、id=1 最后完成。
        // 若 runBatch 按完成序返回会是 [3,2,1]；正确实现按输入序 [1,2,3]。
        let runner = makeRunner(api: DelayedDownloadAPIClient())
        let results = await runner.runBatch(lease: makeLease(ids: [1, 2, 3]), concurrency: 3)
        let ids = results.map { r -> Int? in if case .confirmed(let f) = r { return f.id } else { return nil } }
        #expect(ids == [1, 2, 3])
    }

    @Test func runBatch_zeroConcurrency_treatedAsOne() async throws {
        let runner = makeRunner(api: FakeAPIClient(confirmError: nil))
        let results = await runner.runBatch(lease: makeLease(ids: [1, 2]), concurrency: 0)
        #expect(results.count == 2)
    }

    @Test func runBatch_mixedOutcomes_orderPreserved() async throws {
        // 全部 confirm 用 leaseNotFound → 全 rejected，但仍保序、数量正确
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.leaseNotFound)))
        let results = await runner.runBatch(lease: makeLease(ids: [20, 21]), concurrency: 1)
        #expect(results.count == 2)
        #expect(results == [.rejected(.network(.leaseNotFound)), .rejected(.network(.leaseNotFound))])
    }
}

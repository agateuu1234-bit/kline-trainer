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

    @Test func constructs_withAllFakes_isSendable() {
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
}

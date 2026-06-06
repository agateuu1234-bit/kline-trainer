import Testing
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts
@testable import KlineTrainerPersistence

/// 本地 APIClient 替身（Persistence 测试目标用；与 Contracts 测试里的同名 helper 各自独立）。
private final class FakeAPIClient: APIClient, @unchecked Sendable {
    private let _download: Result<URL, AppError>
    private let _confirmError: AppError?
    init(download: Result<URL, AppError>, confirmError: AppError? = nil) {
        _download = download; _confirmError = confirmError
    }
    func reserveTrainingSets(count: Int) async throws -> LeaseResponse {
        throw AppError.internalError(module: "test", detail: "unused")
    }
    func downloadTrainingSet(id: Int) async throws -> URL {
        switch _download { case .success(let u): return u; case .failure(let e): throw e }
    }
    func confirmTrainingSet(id: Int, leaseId: String) async throws {
        if let e = _confirmError { throw e }
    }
}

@Suite("P2 DownloadAcceptanceRunner 真实管道集成")
struct DownloadAcceptanceRunnerIntegrationTests {

    @Test func run_realPipeline_happyPath_storesAndConfirms() async throws {
        // 1) 造真训练组 sqlite（user_version=1 + meta + klines），读出字节
        let (sqliteFixtureURL, cleanupSqlite) = try TrainingSetSQLiteFixture.make()
        defer { cleanupSqlite() }
        let sqliteBytes = try Data(contentsOf: sqliteFixtureURL)

        // 2) 把字节打进真 zip + 算真 CRC（meta.contentHash 必须 = 此 CRC，否则真 integrity 抛 crcFailed）
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P2Integ-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (zipURL, crcHex) = try ZipFixture.makeMinimalSqliteZip(
            in: workDir, sqliteFileName: "training.sqlite", sqlitePayload: sqliteBytes)

        // 3) 真 cache root + 全真组件（dataVerifier 用 fake 放行——其规则由 DefaultTrainingSetDataVerifierTests 专测）
        let cacheRoot = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(cacheRoot) }
        let journal = InMemoryAcceptanceJournalDAO()
        let runner = DownloadAcceptanceRunner(
            api: FakeAPIClient(download: .success(zipURL), confirmError: nil),
            cache: DefaultFileSystemCacheManager(cacheRoot: cacheRoot),
            dbFactory: DefaultTrainingSetDBFactory(),
            journal: journal,
            integrity: DefaultZipIntegrityVerifier(),
            extractor: DefaultZipExtractor(),
            dataVerifier: FakeTrainingSetDataVerifier(),
            cleaner: DefaultDownloadAcceptanceCleaner())

        let meta = TrainingSetMetaItem(
            id: 42, stockCode: "600001", stockName: "测试股票",
            filename: "training.zip", schemaVersion: 1, contentHash: crcHex)

        let result = await runner.run(meta: meta, leaseId: "11111111-1111-1111-1111-111111111111")

        // confirmed + cache 真落盘一个可打开的 sqlite（schemaVersion 由真 store 的 PRAGMA 读出）
        guard case .confirmed(let file) = result else {
            Issue.record("expected .confirmed via real pipeline, got \(result)"); return
        }
        #expect(file.id == 42)
        #expect(FileManager.default.fileExists(atPath: file.localURL.path))
        #expect(file.schemaVersion == TRAINING_SET_SCHEMA_VERSION)
        #expect(try journal.listByState(.confirmed).count == 1)

        // 真 cleaner 已清掉下载 zip（位于系统临时目录子树内）
        #expect(FileManager.default.fileExists(atPath: zipURL.path) == false)
    }
}

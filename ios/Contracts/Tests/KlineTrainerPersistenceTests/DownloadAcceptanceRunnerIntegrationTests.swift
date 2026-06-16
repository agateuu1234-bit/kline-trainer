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

    @Test func run_realPipeline_storedSetIsDownstreamConsumable() async throws {
        let (sqliteFixtureURL, cleanupSqlite) = try TrainingSetSQLiteFixture.make()
        defer { cleanupSqlite() }
        let sqliteBytes = try Data(contentsOf: sqliteFixtureURL)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P2Smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (zipURL, crcHex) = try ZipFixture.makeMinimalSqliteZip(
            in: workDir, sqliteFileName: "training.sqlite", sqlitePayload: sqliteBytes)

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
            id: 77, stockCode: "600001", stockName: "测试股票",
            filename: "training.zip", schemaVersion: 1, contentHash: crcHex)

        let result = await runner.run(meta: meta, leaseId: "22222222-2222-2222-2222-222222222222")
        guard case .confirmed(let file) = result else {
            Issue.record("expected .confirmed via real pipeline, got \(result)"); return
        }

        // §D 核心：stored 组下游可消费——真 factory open + 读 meta + 读全蜡烛
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(
            file: file.localURL, expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
        defer { reader.close() }
        let loadedMeta = try reader.loadMeta()
        #expect(loadedMeta.stockCode == "600001")
        let candles = try reader.loadAllCandles()
        #expect((candles[.m3]?.isEmpty == false), "下载组真能被会话读取消费（m3 蜡烛非空）")
        #expect(candles[.m3]?.first?.globalIndex == 0)
    }

    /// 生成 verifier-valid candles：6 周期共享同一 datetime 网格（datetime = startDT − 30 + e，
    /// e = end_global_index），使非 m3 的 reader 校验 2 `partitioningIndex{m3.dt>=c.dt}=e <= endgidx=e` 临界成立；
    /// m3 globalIndex = endGlobalIndex = e 连续从 0。
    /// - dailyBeforeStart: 0 = 正向（daily e∈0…37 → 30 before + 8 after）；
    ///   1 = 反向（daily 丢 e=0 → e∈1…37 → 29 before + 8 after，仍保网格对齐过 reader 校验2）。
    private static func verifierValidCandles(
        startDT: Int64,
        dailyBeforeStart: Int = 0
    ) -> [(Period, [(datetime: Int64, gIdx: Int?, endGIdx: Int)])] {
        Period.allCases.map { period in
            let eStart = (period == .daily) ? dailyBeforeStart : 0
            // e 上界 37 = 38 根（eStart=0 时 30 before [e:0..29] + 8 after [e:30..37]）：
            // 满足真 verifier monthly after≥8 + 其余 before≥30；改 37 须同步上述阈值。
            let rows: [(datetime: Int64, gIdx: Int?, endGIdx: Int)] = (eStart...37).map { e in
                (datetime: startDT - 30 + Int64(e),
                 gIdx: period == .m3 ? e : nil,
                 endGIdx: e)
            }
            return (period, rows)
        }
    }

    @Test func run_realPipeline_withRealVerifier_confirmsAndDownstreamConsumable() async throws {
        let startDT: Int64 = 1_700_000_000   // == ConfigOptions 默认 meta.startDatetime
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = Self.verifierValidCandles(startDT: startDT)
        let (sqliteFixtureURL, cleanupSqlite) = try TrainingSetSQLiteFixture.make(opts)
        defer { cleanupSqlite() }
        let sqliteBytes = try Data(contentsOf: sqliteFixtureURL)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P2RealV-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (zipURL, crcHex) = try ZipFixture.makeMinimalSqliteZip(
            in: workDir, sqliteFileName: "training.sqlite", sqlitePayload: sqliteBytes)

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
            dataVerifier: DefaultTrainingSetDataVerifier(),   // 真 verifier（非 fake）
            cleaner: DefaultDownloadAcceptanceCleaner())
        let meta = TrainingSetMetaItem(
            id: 88, stockCode: "600001", stockName: "测试股票",
            filename: "training.zip", schemaVersion: 1, contentHash: crcHex)

        let result = await runner.run(meta: meta, leaseId: "33333333-3333-3333-3333-333333333333")
        guard case .confirmed(let file) = result else {
            Issue.record("expected .confirmed via real verifier pipeline, got \(result)"); return
        }
        #expect(file.id == 88)
        #expect(file.schemaVersion == TRAINING_SET_SCHEMA_VERSION)
        #expect(try journal.listByState(.confirmed).count == 1)

        // 下游可消费 + 复述真 verifier 通过条件（钉死真 verifier 真跑过：每周期 before≥30 / after 足）
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(
            file: file.localURL, expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
        defer { reader.close() }
        let loaded = try reader.loadAllCandles()
        for period in Period.allCases {
            let arr = try #require(loaded[period], "周期 \(period) 应非空")
            let before = arr.filter { $0.datetime < startDT }.count
            let after = arr.filter { $0.datetime >= startDT }.count
            #expect(before >= 30, "\(period) before=\(before) 应 ≥30")
            #expect(after >= (period == .monthly ? 8 : 1), "\(period) after=\(after) 不足")
        }
        #expect(loaded[.m3]?.first?.globalIndex == 0)
    }

    @Test func run_realPipeline_withRealVerifier_rejectsWhenPeriodUnderThirtyBefore() async throws {
        let startDT: Int64 = 1_700_000_000
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        // daily 丢 e=0 → 29 before（仍保 datetime=startDT−30+e 网格对齐，过 reader 校验2）；其余周期 38 根
        opts.candles = Self.verifierValidCandles(startDT: startDT, dailyBeforeStart: 1)
        let (sqliteFixtureURL, cleanupSqlite) = try TrainingSetSQLiteFixture.make(opts)
        defer { cleanupSqlite() }
        let sqliteBytes = try Data(contentsOf: sqliteFixtureURL)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P2RealVNeg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (zipURL, crcHex) = try ZipFixture.makeMinimalSqliteZip(
            in: workDir, sqliteFileName: "training.sqlite", sqlitePayload: sqliteBytes)

        let cacheRoot = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(cacheRoot) }
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = DefaultFileSystemCacheManager(cacheRoot: cacheRoot)
        let runner = DownloadAcceptanceRunner(
            api: FakeAPIClient(download: .success(zipURL), confirmError: nil),
            cache: cache,
            dbFactory: DefaultTrainingSetDBFactory(),
            journal: journal,
            integrity: DefaultZipIntegrityVerifier(),
            extractor: DefaultZipExtractor(),
            dataVerifier: DefaultTrainingSetDataVerifier(),   // 真 verifier
            cleaner: DefaultDownloadAcceptanceCleaner())
        let meta = TrainingSetMetaItem(
            id: 99, stockCode: "600001", stockName: "测试股票",
            filename: "training.zip", schemaVersion: 1, contentHash: crcHex)

        let result = await runner.run(meta: meta, leaseId: "44444444-4444-4444-4444-444444444444")
        guard case .rejected(let err) = result else {
            Issue.record("expected .rejected via real verifier (daily 29-before), got \(result)"); return
        }
        // 拒绝码精确 = verifier 的 trainingSet(.emptyData)（区分 reader 的 .persistence(.dbCorrupted) / confirm 的 .network*）
        #expect(err == .trainingSet(.emptyData), "真 verifier 拒绝码应为 trainingSet(.emptyData)，实得 \(err)")
        // verifier 在 cache.store 前抛错 → cache 无该组 + 无 confirmed journal
        #expect(cache.listAvailable().contains(where: { $0.id == 99 }) == false)
        #expect(try journal.listByState(.confirmed).isEmpty)
    }
}

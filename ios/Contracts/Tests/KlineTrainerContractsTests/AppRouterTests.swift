import Testing
import Foundation
@testable import KlineTrainerContracts

/// confirm 抛非-404/409 网络错误 → journal 行停留 confirmPending（可重扫）→ 坏 guard 给 2N、好 guard 给 N。
actor CountingAPIClient: APIClient {
    private(set) var confirmCount = 0
    func reserveTrainingSets(count: Int) async throws -> LeaseResponse { throw AppError.network(.offline) }
    func downloadTrainingSet(id: Int) async throws -> URL { throw AppError.network(.offline) }
    func confirmTrainingSet(id: Int, leaseId: String) async throws {
        confirmCount += 1
        throw AppError.network(.offline)   // 非 serverError(404/409) → attemptConfirm 归 .pending，行留 confirmPending
    }
}

@MainActor
@Suite("AppRouter")
struct AppRouterTests {

    // MARK: - fixtures（复用 PR #45/#46 public fakes + E6 coordinator 范式）

    static func validCandles(m3Count: Int = 8) -> [Period: [KLineCandle]] {
        func c(_ p: Period, gi: Int, egi: Int, close: Double) -> KLineCandle {
            KLineCandle(period: p, datetime: 1 + Int64(gi) * 180, open: 10, high: 11, low: 9,
                        close: close, volume: 1000, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: gi, endGlobalIndex: egi)
        }
        let m3 = (0..<m3Count).map { c(.m3, gi: $0, egi: $0, close: 10 + Double($0) * 0.1) }
        let last = m3Count - 1
        let m60 = [c(.m60, gi: 0, egi: last / 2, close: 10.3),
                   c(.m60, gi: last / 2 + 1, egi: last, close: 10.7)]
        let daily = [c(.daily, gi: 0, egi: last, close: 10.7)]
        return [.m3: m3, .m60: m60, .daily: daily]
    }

    struct CapitalDAO: SettingsDAO {
        let capital: Double
        var loadErr: AppError?
        func loadSettings() throws -> AppSettings {
            if let e = loadErr { throw e }
            return AppSettings(commissionRate: 0.0001, minCommissionEnabled: false,
                               totalCapital: capital, displayMode: .system)
        }
        func saveSettings(_: AppSettings) throws {}
        func resetCapital() throws {}
    }

    static func cachedFile(id: Int = 1) -> TrainingSetFile {
        TrainingSetFile(id: id, filename: "set\(id).sqlite",
                        localURL: URL(fileURLWithPath: "/tmp/set\(id).sqlite"),
                        schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)
    }

    // [C2 修] 注意：`InMemoryRecordRepository.insertRecord` 丢弃此处传入的 id，自增分配 insert-order id（1,2,3…，mirror 生产 server-assigned rowid）。
    // 故测试**查询时用 insert-order id（单 record→1）**，非这里传入值。下方 id 参数仅为可读性（被 fake 丢弃）。
    static func record(id: Int64, profit: Double = 0) -> TrainingRecord {
        // [H] 修：trainingSetFilename 必须匹配 cache 里 seed 的文件名（review/replay 据它在 cache 解析文件），否则 .trainingSet(.fileNotFound)
        TrainingRecord(id: id, trainingSetFilename: "set1.sqlite", createdAt: 0,
                       stockCode: "000001", stockName: "测试股", startYear: 2020, startMonth: 1,
                       totalCapital: 100_000, profit: profit, returnRate: 0, maxDrawdown: 0,
                       buyCount: 0, sellCount: 0,
                       feeSnapshot: FeeSnapshot(commissionRate: 0, minCommissionEnabled: false), finalTick: 2)  // [C] 修：无 FeeSnapshot.zero
    }

    /// 走状态机种入一条 confirmPending 行（downloaded→…→stored→confirmPending）。
    static func seedConfirmPending(_ j: InMemoryAcceptanceJournalDAO, tsId: Int, lease: String) throws {
        let path = "/tmp/\(tsId).sqlite"; let hash = "abcd1234"   // 8-char lowercase hex(CRC32)
        try j.upsert(trainingSetId: tsId, leaseId: lease, state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try j.upsert(trainingSetId: tsId, leaseId: lease, state: .crcOK, sqliteLocalPath: nil, contentHash: hash, lastError: nil)
        try j.upsert(trainingSetId: tsId, leaseId: lease, state: .unzipped, sqliteLocalPath: path, contentHash: hash, lastError: nil)
        try j.upsert(trainingSetId: tsId, leaseId: lease, state: .dbVerified, sqliteLocalPath: path, contentHash: hash, lastError: nil)
        try j.upsert(trainingSetId: tsId, leaseId: lease, state: .stored, sqliteLocalPath: path, contentHash: hash, lastError: nil)
        try j.upsert(trainingSetId: tsId, leaseId: lease, state: .confirmPending, sqliteLocalPath: path, contentHash: hash, lastError: nil)
    }

    /// 组装一个 router + 暴露其内部依赖供测试断言/seed。
    static func makeRouter(
        candles: [Period: [KLineCandle]] = validCandles(),
        capital: Double = 100_000,
        settingsLoadError: AppError? = nil,
        seedFiles: [TrainingSetFile] = [cachedFile()],
        seedRecords: [TrainingRecord] = [],
        api: any APIClient = CountingAPIClient()
    ) -> (router: AppRouter, records: InMemoryRecordRepository,
          pending: InMemoryPendingTrainingRepository, journal: InMemoryAcceptanceJournalDAO,
          cache: InMemoryCacheManager, api: any APIClient, coordinator: TrainingSessionCoordinator) {
        let records = InMemoryRecordRepository()
        for r in seedRecords { try? records.insertRecord(r, ops: [], drawings: []) }   // [C] 修：insertRecord 是 3 参
        let pending = InMemoryPendingTrainingRepository()
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = InMemoryCacheManager()
        cache._seedForTesting(seedFiles)
        let settings = SettingsStore(settingsDAO: CapitalDAO(capital: capital, loadErr: settingsLoadError))
        let coordinator = TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(candles: candles),
            recordRepo: records, pendingRepo: pending,
            finalization: InMemorySessionFinalizationPort(records: records, pending: pending),
            settingsDAO: InMemorySettingsDAO(), cache: cache, settings: settings)
        let runner = DownloadAcceptanceRunner(
            api: api, cache: cache, dbFactory: PreviewTrainingSetDBFactory(candles: candles),
            journal: journal, integrity: FakeZipIntegrityVerifier(),
            extractor: FakeZipExtractor(), dataVerifier: FakeTrainingSetDataVerifier(),
            cleaner: FakeDownloadAcceptanceCleaner())
        let router = AppRouter(coordinator: coordinator, settings: settings, acceptance: runner,
                               recordRepo: records, pendingRepo: pending, cache: cache)
        return (router, records, pending, journal, cache, api, coordinator)
    }

    // [C] 修：HomeContent 的 configuredCapital/hasPending 只是 init 参，非 stored property——断言改读 stored 派生属性
    //         （hasCachedSets / isHistoryEmpty 是 stored；hasPending→isResuming 派生）。
    @Test("loadHome 装配：有缓存集 + 有 records → hasCachedSets=true / isHistoryEmpty=false / 无错误")
    func loadHome_assembles() async {
        let f = Self.makeRouter(seedRecords: [Self.record(id: 1, profit: 100), Self.record(id: 2, profit: -50)])
        await f.router.loadHome()
        #expect(f.router.homeContent.hasCachedSets == true)
        #expect(f.router.homeContent.isHistoryEmpty == false)
        #expect(f.router.errorMessage == nil)
    }

    @Test("loadHome 空态：0 records + 无缓存 + settings loadError 不 crash")
    func loadHome_emptyState() async {
        let f = Self.makeRouter(settingsLoadError: .persistence(.dbCorrupted),
                                seedFiles: [], seedRecords: [])
        await f.router.loadHome()
        #expect(f.router.homeContent.hasCachedSets == false)
        #expect(f.router.homeContent.isHistoryEmpty == true)
    }

    @Test("startTraining 成功 → activeTraining 非 nil（normal 模式）")
    func startTraining_success() async {
        let f = Self.makeRouter()
        await f.router.startTraining()
        #expect(f.router.activeTraining != nil)
        #expect(f.router.activeTraining?.lifecycle.engine.flow.mode == .normal)
        #expect(f.router.errorMessage == nil)
    }

    @Test("startTraining 失败（无缓存集）→ errorMessage 且 activeTraining nil")
    func startTraining_noCache_error() async {
        let f = Self.makeRouter(seedFiles: [])
        await f.router.startTraining()
        #expect(f.router.activeTraining == nil)
        #expect(f.router.errorMessage != nil)
    }

    @Test("continueTraining 无 pending → 不 push")
    func continue_noPending() async {
        let f = Self.makeRouter()
        await f.router.continueTraining()
        #expect(f.router.activeTraining == nil)
    }

    @Test("selectRecord → activeModal=.history(对应 record)")
    func selectRecord_setsHistoryModal() async {
        let f = Self.makeRouter(seedRecords: [Self.record(id: 1)])   // [C2] 单 record → 实际 id=1
        await f.router.loadHome()              // 填 router.records 缓存
        f.router.selectRecord(id: 1)
        if case .history(let r)? = f.router.activeModal { #expect(r.id == 1) } else { Issue.record("expected .history") }
    }

    @Test("review(id) → push review 模式 engine")
    func review_pushesReviewMode() async {
        let f = Self.makeRouter(seedRecords: [Self.record(id: 1)])   // [C2] 查询用 insert-order id=1
        await f.router.review(id: 1)
        #expect(f.router.activeModal == nil)
        #expect(f.router.activeTraining?.lifecycle.engine.flow.mode == .review)
    }

    @Test("exitTraining → activeTraining nil + reload home")
    func exitTraining_clears() async {
        let f = Self.makeRouter()
        await f.router.startTraining()
        await f.router.exitTraining()
        #expect(f.router.activeTraining == nil)
    }

    @Test("runLaunchRecovery 恰一次：连调两次 → confirmCount==N 非 2N（router didRunLaunchRecovery 门）")
    func launchRecovery_exactlyOnce() async throws {
        let counting = CountingAPIClient()
        let f = Self.makeRouter(api: counting)
        try Self.seedConfirmPending(f.journal, tsId: 1, lease: "L1")
        await f.router.runLaunchRecovery()
        await f.router.runLaunchRecovery()
        #expect(await counting.confirmCount == 1)
    }

    @Test("sessionEnded normal recordId → activeModal=.settlement(record)")
    func sessionEnded_normalShowsSettlement() async {
        let f = Self.makeRouter(seedRecords: [Self.record(id: 1)])   // [C2] insert-order id=1
        await f.router.startTraining()                 // activeTraining = normal
        await f.router.sessionEnded(recordId: 1)
        if case .settlement(let r)? = f.router.activeModal { #expect(r.id == 1) } else { Issue.record("expected .settlement") }
    }

    @Test("sessionEnded normal nil（finalize 抛）→ errorMessage + activeTraining nil")
    func sessionEnded_normalNilError() async {
        let f = Self.makeRouter()
        await f.router.startTraining()
        await f.router.sessionEnded(recordId: nil)     // mode==normal + nil → 入账失败分支
        #expect(f.router.activeTraining == nil)
        #expect(f.router.errorMessage != nil)
    }

    @Test("[D7 防御路径] sessionEnded replay nil → retreat：activeTraining nil 且无 settlement")
    func sessionEnded_replayRetreat() async {
        let f = Self.makeRouter(seedRecords: [Self.record(id: 1)])   // [C2] insert-order id=1
        await f.router.replay(id: 1)                    // activeTraining = replay
        #expect(f.router.activeTraining?.lifecycle.engine.flow.mode == .replay)   // 证 replay 真成功（非静默抛错）
        await f.router.sessionEnded(recordId: nil)
        #expect(f.router.activeTraining == nil)
        #expect(f.router.activeModal == nil)
    }

    @Test("[D7 防御路径] teardown：replay nil 兜底后 coordinator.activeReader == nil（endAfterSettlement→endSession）")
    func sessionEnded_replayTearsDownReader() async {
        let f = Self.makeRouter(seedRecords: [Self.record(id: 1)])   // [C2] insert-order id=1
        await f.router.replay(id: 1)
        #expect(f.coordinator.activeReader != nil)      // replay 成功 → reader 开（前提：filename 匹配 + id=1，见 record fixture）
        await f.router.sessionEnded(recordId: nil)      // retreat 须 endAfterSettlement → endSession
        #expect(f.coordinator.activeReader == nil)      // 直接断言 reader 关闭（若漏调 endAfterSettlement 则非 nil → FAIL）
    }

    @Test("confirmSettlement → activeTraining nil + modal nil + reload")
    func confirmSettlement_clears() async {
        let f = Self.makeRouter(seedRecords: [Self.record(id: 1)])   // [C2] insert-order id=1
        await f.router.startTraining()
        await f.router.sessionEnded(recordId: 1)
        #expect(f.router.activeModal != nil)            // 证结算窗已弹（loadRecordBundle(1) 成功）
        await f.router.confirmSettlement()
        #expect(f.router.activeTraining == nil)
        #expect(f.router.activeModal == nil)
    }

    // MARK: - Wave 3 顺位 8：replay 结算窗（present 设 .settlement modal + 非持久化不变量）

    @Test("presentReplaySettlement: 设 .settlement(in-memory record) modal 且不持久化（records/pending 不变）")
    func presentReplaySettlement_showsModalNoPersist() async throws {
        let f = Self.makeRouter(seedRecords: [Self.record(id: 1)])   // [C2] insert-order id=1
        await f.router.replay(id: 1)                                  // activeTraining = replay，reader 开
        #expect(f.router.activeTraining?.lifecycle.engine.flow.mode == .replay)
        let recordsBefore = try f.records.listRecords(limit: nil).count   // = 1（仅 seed 源 record）
        let life = try #require(f.router.activeTraining?.lifecycle)
        let payload = try life.replaySettlementRecord()               // id==nil 非持久 payload
        f.router.presentReplaySettlement(record: payload)
        if case .settlement(let r)? = f.router.activeModal {
            #expect(r.id == nil)                                       // in-memory 非持久
            #expect(r.stockCode == payload.stockCode)                 // modal 携带的正是该 payload（无变换/串味）
            #expect(r.totalCapital == payload.totalCapital)
        } else { Issue.record("expected .settlement") }
        #expect(try f.records.listRecords(limit: nil).count == recordsBefore)   // 不写 record
        #expect(try f.pending.loadPending() == nil)                            // 不触 pending
    }

    @Test("replay 结算 confirm → teardown reader + activeTraining/modal nil + 仍不持久化")
    func presentReplaySettlement_confirmTearsDown() async throws {
        let f = Self.makeRouter(seedRecords: [Self.record(id: 1)])
        await f.router.replay(id: 1)
        #expect(f.coordinator.activeReader != nil)
        let life = try #require(f.router.activeTraining?.lifecycle)
        f.router.presentReplaySettlement(record: try life.replaySettlementRecord())
        let before = try f.records.listRecords(limit: nil).count
        await f.router.confirmSettlement()
        #expect(f.router.activeTraining == nil)
        #expect(f.router.activeModal == nil)
        #expect(f.coordinator.activeReader == nil)                    // endAfterSettlement→endSession 关 reader
        #expect(try f.records.listRecords(limit: nil).count == before)   // confirm 不持久化
        #expect(try f.pending.loadPending() == nil)
    }
}

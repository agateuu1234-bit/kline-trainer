// CoordinatorLossyPreserveTests.swift
// 画线工具扩充 P1a Task 12（Z1，codex plan-R9-high）：engine/coordinator 携带 lossy 穿过所有
// save 路径 —— coordinator 级保真验证。真 DefaultAppDB + 真 TrainingSessionCoordinator（镜像
// CoordinatorCapitalIntegrationTests 的真-DB 装配模式），种入含「未来版本画的线」的 blob，走真实
// resumePendingReplay/resumePendingReview → saveProgress/persistReviewWorkingIfChanged/commitReview，
// 断言未来条【逐字节】+【原位】存活、hiddenIds 不被覆盖成 []。
import Testing
import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerContracts
@testable import KlineTrainerPersistence

#if DEBUG
@MainActor
@Suite("coordinator 携带 lossy 保真（Z1）")
struct CoordinatorLossyPreserveTests {

    // MARK: - Fixtures（未来条 + 已知条字面量；对齐 PendingLossyTests.known 同款字段/真实 Period rawValue "3m"）

    let unknown = #"{"toolType":"__future__","z":1.0}"#
    func known(_ id: String) -> String {
        #"{"id":"\#(id)","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#
    }
    func decodedKnown(_ json: String) -> DrawingObject {
        try! JSONDecoder().decode(DrawingObject.self, from: Data(json.utf8))
    }

    // MARK: - Coordinator harness（镜像 CoordinatorCapitalIntegrationTests.makeCoordinator：真 DefaultAppDB
    // 作 repos + PreviewTrainingSetDBFactory 供 candles；m3Count=8 → maxTick=7，与 KlineTrainerContractsTests
    // 侧 CoordinatorTestHarness.makeCandles 同款几何）。

    private func makeFreshDB() throws -> (url: URL, db: DefaultAppDB) {
        let url = try AppDBFixture.makeFreshDB()
        return (url, try DefaultAppDB(dbPath: url))
    }

    private static func candles(m3Count: Int = 8) -> [Period: [KLineCandle]] {
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

    private func makeCoordinator(_ appDB: DefaultAppDB) -> TrainingSessionCoordinator {
        let cache = InMemoryCacheManager()
        cache._seedForTesting([TrainingSetFile(id: 1, filename: "set.sqlite",
            localURL: URL(fileURLWithPath: "/tmp/set.sqlite"),
            schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)])
        return TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(candles: Self.candles()),
            recordRepo: appDB, pendingRepo: appDB,
            pendingReplayRepo: appDB, reviewArchiveRepo: appDB,
            finalization: appDB, settingsDAO: appDB, cache: cache,
            settings: SettingsStore(settingsDAO: appDB))
    }

    /// 最小合法 finalized record（finalTick=7 与 candles 一致；profit/returnRate=0 ↔ ops=[]，满足
    /// review 入口终局等式；filename="set.sqlite" ↔ cache 注册的文件一致）。
    private func makeRecord(_ appDB: DefaultAppDB) throws -> Int64 {
        try appDB.insertRecord(TrainingRecord(
            id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
            stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
            totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: -0.03,
            buyCount: 0, sellCount: 0,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
            finalTick: 7), ops: [], drawings: [])
    }

    /// 先经真实 saveReplay 写一条合法行（drawings=[]），再裸 SQL 把 drawings 列换成任意（可含未知条）
    /// JSON——同 PendingLossyTests.seedPendingReplayRow 手法（避免手拼整条 INSERT 各列）。
    private func seedPendingReplayRow(_ appDB: DefaultAppDB, recordId: Int64, drawingsJSON: String) throws {
        // positionData 须是真合法 PositionManager JSON——coordinator resumePendingReplay 会 decodePosition，
        // 空 Data() 解码失败 → .dbCorrupted → clearReplay + nil（同 PendingLossyTests 的裸 repo 级测试不同，
        // 那边直接调 repo 不经 decodePosition，故可用空 Data 占位；这里须真编码）。
        let positionData = try JSONEncoder().encode(PositionManager())
        let base = PendingReplay(recordId: recordId, trainingSetFilename: "set.sqlite", globalTickIndex: 0,
                                  upperPeriod: .m60, lowerPeriod: .daily, positionData: positionData, cashBalance: 100_000,
                                  feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
                                  tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
                                  drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
        try appDB.dbQueue.write { db in
            try PendingReplayRepositoryImpl.saveReplay(db, replay: base)
            try db.execute(sql: "UPDATE pending_replay SET drawings = ? WHERE id = 1", arguments: [drawingsJSON])
        }
    }

    /// 裸 SQL 种一行 review_archive working（wrapper JSON `{"drawings":[...],"hiddenIds":[...]}`）——
    /// 同 ReviewArchiveRepositoryTests.reviewRepoPreservesUnknownAcrossLoadSave 手法。
    private func seedReviewWorking(_ appDB: DefaultAppDB, recordId: Int64, stepTick: Int, wrapperJSON: String) throws {
        try appDB.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO review_archive (record_id, working_step_tick, working_drawings, updated_at)
                VALUES (?, ?, ?, 0)
                """, arguments: [recordId, stepTick, wrapperJSON])
        }
    }

    // MARK: - pending_replay：autosave（saveProgress）保真

    @Test("pending_replay: load(含未来条)→saveProgress(autosave) 后未来条仍在、且在原位")
    func replayAutosavePreservesUnknown() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        try seedPendingReplayRow(appDB, recordId: rid, drawingsJSON: "[\(known("g1")),\(unknown),\(known("g2"))]")
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePendingReplay(recordId: rid))   // load：engine 携带 loadedDrawingsLossy
        try await coord.saveProgress(engine: engine)                                     // autosave：reconciled 重发
        let col: String = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT drawings FROM pending_replay WHERE id=1")!["drawings"]
        }
        #expect(col.contains(unknown))                                 // 未来条未被 known-only 覆盖
        let iA = col.range(of: #""g1""#)!.lowerBound, iU = col.range(of: "__future__")!.lowerBound,
            iB = col.range(of: #""g2""#)!.lowerBound
        #expect(iA < iU && iU < iB)                                    // 原位保序
    }

    @Test("已知工具 horizontal + 未来字段：pending_replay load→saveProgress 后未来字段仍在（W1/R12）")
    func replayAutosavePreservesKnownToolFutureField() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        // 现有 toolType（horizontal，全必填字段）+ 未来客户端加的 "futureX"
        let knownFuture = #"{"id":"g1","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","futureX":9}"#
        try seedPendingReplayRow(appDB, recordId: rid, drawingsJSON: "[\(knownFuture)]")
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePendingReplay(recordId: rid))    // 解码成功、raw 携带 futureX
        try await coord.saveProgress(engine: engine)                                      // 未编辑 autosave → 原样 raw
        let col: String = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT drawings FROM pending_replay WHERE id=1")!["drawings"]
        }
        #expect(col.contains("\"futureX\":9"))                         // 现有工具上的未来字段未被重序列化删掉
    }

    // MARK: - review working：autosave（persistReviewWorkingIfChanged）+ commit（commitReview）保真

    @Test("复盘 working: load(含未来条)→净改动 autosave 后未来条仍在")
    func reviewWorkingAutosavePreservesUnknown() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        try seedReviewWorking(appDB, recordId: rid, stepTick: 3,
                              wrapperJSON: #"{"drawings":[\#(known("g1")),\#(unknown)],"hiddenIds":[]}"#)
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePendingReview(recordId: rid))  // load：engine.loadedReviewLossy 携带
        engine.appendReviewDrawing(decodedKnown(known("g3")))          // 编辑：加一条已知（复盘唯一写入面）
        try coord.persistReviewWorkingIfChanged(engine: engine)        // autosave：reconciled(currentKnown) 重发
        let col: String = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT working_drawings FROM review_archive WHERE record_id=\(rid)")!["working_drawings"]
        }
        #expect(col.contains(unknown))                                 // 未来条经「编辑+autosave」仍存活
    }

    @Test("复盘 hiddenIds：load(wrapper 含 hiddenIds)→autosave 后 hiddenIds 原样保留（不被覆盖成 []）")
    func reviewHiddenIdsSurviveSave() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        // wrapper 含 hiddenIds（模拟 P5/未来版本写的隐藏态）
        try seedReviewWorking(appDB, recordId: rid, stepTick: 3,
                              wrapperJSON: #"{"drawings":[\#(known("g1"))],"hiddenIds":["h-1","h-2"]}"#)
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePendingReview(recordId: rid))  // engine.loadedReviewHiddenIds 携带
        engine.appendReviewDrawing(decodedKnown(known("g9")))
        try coord.persistReviewWorkingIfChanged(engine: engine)        // autosave 传回 loadedReviewHiddenIds
        let col: String = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT working_drawings FROM review_archive WHERE record_id=\(rid)")!["working_drawings"]
        }
        #expect(col.contains("h-1") && col.contains("h-2"))           // 隐藏态未被覆盖成 []
    }

    @Test("复盘 commit：load(含未来条+hiddenIds)→commitReview 后 saved 列未来条+hiddenIds 仍在（Global Constraints：commit 路径同款）")
    func reviewCommitPreservesUnknownAndHiddenIds() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        try seedReviewWorking(appDB, recordId: rid, stepTick: 3,
                              wrapperJSON: #"{"drawings":[\#(known("g1")),\#(unknown)],"hiddenIds":["h-1"]}"#)
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePendingReview(recordId: rid))
        engine.appendReviewDrawing(decodedKnown(known("g3")))
        try coord.commitReview(engine: engine)                         // commit：saved=reconciled 后完整有损集 + hiddenIds 原样
        let col: String = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT saved_drawings FROM review_archive WHERE record_id=\(rid)")!["saved_drawings"]
        }
        #expect(col.contains(unknown))
        #expect(col.contains("h-1"))
    }

    // MARK: - LossyDrawingArray.reconciled 单元测试（不需 coordinator）

    @Test("reconciled fail-closed：loaded 元素含重复 id → 抛 .dbCorrupted（不静默折叠）")
    func reconciledRejectsDuplicateLoadedIds() {
        let d = decodedKnown(known("dup"))
        let lossy = LossyDrawingArray(elements: [.known(d, raw: known("dup")), .known(d, raw: known("dup"))])
        #expect(throws: AppError.self) { _ = try lossy.reconciled(currentKnown: [d]) }
    }

    @Test("reconciled fail-closed：currentKnown 含重复 id → 抛 .dbCorrupted")
    func reconciledRejectsDuplicateCurrentIds() {
        let d = decodedKnown(known("dup"))
        let lossy = LossyDrawingArray(elements: [.known(d, raw: known("dup"))])
        #expect(throws: AppError.self) { _ = try lossy.reconciled(currentKnown: [d, d]) }   // 两条同 id
    }

    @Test("reconciled 按 id：删 unknown 之前的 known → 未来条仍在原位（不被后续 known 挤到前面）")
    func reconciledByIdPreservesOrderOnDelete() throws {
        let a = decodedKnown(known("gA")); let bK = decodedKnown(known("gB"))
        let lossy = LossyDrawingArray(elements: [.known(a, raw: known("gA")), .unknownRaw(unknown), .known(bK, raw: known("gB"))])
        let out = String(decoding: try lossy.reconciled(currentKnown: [bK]).encoded(), as: UTF8.self)  // 删了 A
        let iU = out.range(of: "__future__")!.lowerBound
        let iB = out.range(of: #""gB""#)!.lowerBound
        #expect(iU < iB)                                               // 未来条仍在 B 之前（原位），非位置法的 [B, 未来]
        #expect(!out.contains(#""gA""#))                              // A 已删
    }
}
#endif

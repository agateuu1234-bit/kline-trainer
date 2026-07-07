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
        let base = try PendingReplay(recordId: recordId, trainingSetFilename: "set.sqlite", globalTickIndex: 0,
                                  upperPeriod: .m60, lowerPeriod: .daily, positionData: positionData, cashBalance: 100_000,
                                  feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
                                  tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
                                  drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
        try appDB.dbQueue.write { db in
            try PendingReplayRepositoryImpl.saveReplay(db, replay: base)
            try db.execute(sql: "UPDATE pending_replay SET drawings = ? WHERE id = 1", arguments: [drawingsJSON])
        }
    }

    /// 先经真实 savePending 写一条合法行（drawings=[]），再裸 SQL 把 drawings 列换成任意（可含重复 id）
    /// JSON——同上面 seedPendingReplayRow 手法（pending_training 侧，供 Normal/`resumePending` 场景）。
    private func seedPendingTrainingRow(_ appDB: DefaultAppDB, sessionKey: String, drawingsJSON: String) throws {
        let positionData = try JSONEncoder().encode(PositionManager())
        let base = try PendingTraining(trainingSetFilename: "set.sqlite", globalTickIndex: 0,
                                  upperPeriod: .m60, lowerPeriod: .daily, positionData: positionData, cashBalance: 100_000,
                                  feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
                                  tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
                                  drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0), sessionKey: sessionKey)
        try appDB.dbQueue.write { db in
            try PendingTrainingRepositoryImpl.savePending(db, pending: base)
            try db.execute(sql: "UPDATE pending_training SET drawings = ? WHERE id = 1", arguments: [drawingsJSON])
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

    /// 裸 SQL 种一行 review_archive **仅 saved**（working 两列留 NULL，CHECK 约束允许）——
    /// 供「无 working 行」的 FRESH review() 入口路径测试（区别于上面 seedReviewWorking 的 resume 路径）。
    private func seedReviewSaved(_ appDB: DefaultAppDB, recordId: Int64, wrapperJSON: String) throws {
        try appDB.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO review_archive (record_id, saved_drawings, updated_at)
                VALUES (?, ?, 0)
                """, arguments: [recordId, wrapperJSON])
        }
    }

    /// 裸 SQL 种一行 review_archive **saved + working 均有**——供 hiddenIds-only 净改动测试：
    /// 两列画线集相同、hiddenIds 不同，专测 `ReviewNetChange.changed` 的 4-arg（含 hiddenIds）threading。
    private func seedReviewSavedAndWorking(_ appDB: DefaultAppDB, recordId: Int64,
                                            savedWrapperJSON: String, stepTick: Int, workingWrapperJSON: String) throws {
        try appDB.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO review_archive (record_id, saved_drawings, working_step_tick, working_drawings, updated_at)
                VALUES (?, ?, ?, ?, 0)
                """, arguments: [recordId, savedWrapperJSON, stepTick, workingWrapperJSON])
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

    @Test("复盘 wrapper 顶层未知 key：load(wrapper 顶层含 futureMeta)→resume-edit-autosave 后 futureMeta 原样保留（codex WB R7 finding 1）")
    func reviewWrapperUnknownTopLevelSurvivesAutosave() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        // wrapper 顶层含一个本版本不认识的 key（模拟未来客户端在 working 行加的顶层 review-metadata）。
        try seedReviewWorking(appDB, recordId: rid, stepTick: 3,
                              wrapperJSON: #"{"drawings":[\#(known("g1"))],"hiddenIds":[],"futureMeta":{"x":1}}"#)
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePendingReview(recordId: rid))  // engine.loadedReviewUnknownTopLevel 携带
        engine.appendReviewDrawing(decodedKnown(known("g9")))          // 编辑：加一条已知（触发脏 autosave）
        try coord.persistReviewWorkingIfChanged(engine: engine)        // autosave 须原样传回 loadedReviewUnknownTopLevel
        let col: String = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT working_drawings FROM review_archive WHERE record_id=\(rid)")!["working_drawings"]
        }
        #expect(col.contains(#""futureMeta":{"x":1}"#))               // 未知顶层 key 未被「只认识 drawings/hiddenIds」的新对象覆盖抹掉
    }

    @Test("复盘 wrapper 顶层未知 key：load(saved 列含 futureMeta，无 working 行)→FRESH 零编辑 commitReview 后 saved 列 futureMeta 仍在（codex WB R7 finding 1）")
    func reviewWrapperUnknownTopLevelSurvivesFreshCommit() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        try seedReviewSaved(appDB, recordId: rid,
                            wrapperJSON: #"{"drawings":[\#(known("g1"))],"hiddenIds":[],"futureMeta":{"x":1}}"#)
        let coord = makeCoordinator(appDB)
        let engine = try await coord.review(recordId: rid)   // FRESH 入口：无 working 行 → review()（非 resume）
        try coord.commitReview(engine: engine)                // 零用户编辑，直接「结束复盘并保存」
        let col: String = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT saved_drawings FROM review_archive WHERE record_id=\(rid)")!["saved_drawings"]
        }
        #expect(col.contains(#""futureMeta":{"x":1}"#))               // 未来顶层 key 未被无编辑 commit 抹掉（首次落 saved 行的时刻）
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

    @Test("复盘净改动须纳入 hiddenIds：working 画线集==saved 画线集但 hiddenIds 不同 → 判「有改动」，working 行不被 clearWorking 抹掉（codex WB High）")
    func reviewNetChangeHiddenIdsOnlyDiffPreventsClearWorking() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        // saved 与 working 画线集完全相同（[g1]），仅 hiddenIds 不同：saved=[]（committed 基线），working=["h-1"]
        // （模拟一个更新客户端写的 working 行只改了隐藏态，未动画线——P1a 的核心场景）。
        try seedReviewSavedAndWorking(appDB, recordId: rid,
                                       savedWrapperJSON: #"{"drawings":[\#(known("g1"))],"hiddenIds":[]}"#,
                                       stepTick: 3,
                                       workingWrapperJSON: #"{"drawings":[\#(known("g1"))],"hiddenIds":["h-1"]}"#)
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePendingReview(recordId: rid))  // resume：working 画线==committed 基线，hiddenIds 不同
        try coord.persistReviewWorkingIfChanged(engine: engine)   // 零画线编辑——净改动判定必须靠 hiddenIds 单独识别出「有改动」
        let workingCol: String? = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT working_drawings FROM review_archive WHERE record_id=\(rid)")?["working_drawings"]
        }
        // 2-arg 净改动判定会漏判「无改动」→ clearWorking 抹掉 working 行 → hiddenIds="h-1" 永久丢失，
        // 隐藏的原训练线在下次进入复盘时重新显示。修复后须判「有改动」→ working 行原样保留（含 hiddenIds）。
        #expect(workingCol != nil)                       // working 行未被 clearWorking 清空
        #expect(workingCol?.contains("h-1") == true)      // hiddenIds 未丢失
    }

    @Test("复盘净改动须纳入 unknownRaw：working 与 saved 已知画线集+hiddenIds 均相同，仅各自携带的 unknownRaw 不同 → 判「有改动」，working 行（含其 unknownRaw）不被 clearWorking 抹掉（codex WB R4 finding 1）")
    func reviewNetChangeUnknownRawOnlyDiffPreventsClearWorking() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        // saved 与 working 的已知画线集([g1])+hiddenIds([]) 完全相同，仅 working 额外携带一条 unknownRaw
        // （模拟一个更新客户端在 working 上加了未来版本画的线，未动已知画线/隐藏态——只比 known+hiddenIds
        // 的净改动判定对这种改动是盲区）。
        try seedReviewSavedAndWorking(appDB, recordId: rid,
                                       savedWrapperJSON: #"{"drawings":[\#(known("g1"))],"hiddenIds":[]}"#,
                                       stepTick: 3,
                                       workingWrapperJSON: #"{"drawings":[\#(known("g1")),\#(unknown)],"hiddenIds":[]}"#)
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePendingReview(recordId: rid))  // resume：working 已知+hiddenIds==committed，仅 unknownRaw 不同
        try coord.persistReviewWorkingIfChanged(engine: engine)   // 零画线编辑——净改动判定必须靠 unknownRaw 字节比较单独识别出「有改动」
        let workingCol: String? = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT working_drawings FROM review_archive WHERE record_id=\(rid)")?["working_drawings"]
        }
        // 只比 known+hiddenIds 的净改动判定会漏判「无改动」→ clearWorking 抹掉 working 行 → 这条 unknownRaw
        // （未来版本画的线）永久丢失。修复后须判「有改动」→ working 行原样保留（含 unknownRaw）。
        #expect(workingCol != nil)                            // working 行未被 clearWorking 清空
        #expect(workingCol?.contains("__future__") == true)   // unknownRaw 未丢失
    }

    @Test("复盘净改动(reviewNetChanged)须纳入 unknownRaw：known+hiddenIds 均与 committed 基线相同，仅 unknownRaw 不同 → reviewNetChanged() 判「有改动」，不得被 UI 误判「无改动」直接 discard 丢弃这条未来数据（codex WB R5：reviewNetChanged 与 persistReviewWorkingIfChanged 的脏判定须合一，不得分裂出新盲区）")
    func reviewNetChangedDetectsUnknownRawOnlyDiff() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        // saved(committed 基线) 与 working 的已知画线集([g1])+hiddenIds([]) 完全相同，仅 working 额外携带
        // 一条 unknownRaw——`reviewNetChanged()` 此前只比较 known+hiddenIds（`persistReviewWorkingIfChanged`
        // 已在 R4 finding 1 修过，但 `reviewNetChanged()` 是独立维护的第二份判定，未同步补）。
        try seedReviewSavedAndWorking(appDB, recordId: rid,
                                       savedWrapperJSON: #"{"drawings":[\#(known("g1"))],"hiddenIds":[]}"#,
                                       stepTick: 3,
                                       workingWrapperJSON: #"{"drawings":[\#(known("g1")),\#(unknown)],"hiddenIds":[]}"#)
        let coord = makeCoordinator(appDB)
        _ = try #require(try await coord.resumePendingReview(recordId: rid))  // resume：known+hiddenIds==committed，仅 unknownRaw 不同
        // 零画线编辑——`reviewNetChanged()` 必须靠 unknownRaw 字节比较单独识别出「有改动」。若误判「无改动」，
        // UI 端「结束复盘」流程会跳过保存提示、直接调 discard，永久丢失这条 unknownRaw（未来版本画的线）。
        #expect(coord.reviewNetChanged() == true)
    }

    // MARK: - review FRESH 入口（无 working 行）：commit 不丢 saved 列未来条/hiddenIds（Critical）

    @Test("复盘 FRESH 进入(无 working 行)：saved 列含未来条+hiddenIds → 无编辑 commit 后仍保留（曾被永久抹掉）")
    func reviewFreshEntryPreservesUnknownAndHiddenIdsOnCommit() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        // 仅 saved 列（working 两列 NULL）——模拟「已保存过复盘」的记录再次被打开（FRESH review() 入口，
        // 非 resumePendingReview）。saved blob 含未来 toolType 条 + 非空 hiddenIds（P5/未来版本写的隐藏态）。
        try seedReviewSaved(appDB, recordId: rid,
                            wrapperJSON: #"{"drawings":[\#(known("g1")),\#(unknown)],"hiddenIds":["h-1"]}"#)
        let coord = makeCoordinator(appDB)
        let engine = try await coord.review(recordId: rid)   // FRESH 入口：无 working 行 → review()（非 resume）
        try coord.commitReview(engine: engine)                // 零用户编辑，直接「结束复盘并保存」
        let col: String = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT saved_drawings FROM review_archive WHERE record_id=\(rid)")!["saved_drawings"]
        }
        #expect(col.contains(unknown))                        // 未来条未被已知投影覆盖抹掉
        #expect(col.contains("h-1"))                          // hiddenIds 未被覆盖成 []
    }

    // MARK: - finalize dup-id 门（codex whole-branch R6）：unknownRaw 门须 dup-tolerant，重复 id 走 insert 去重不 brick

    @Test("finalize: pending 含重复非空 id（无 unknownRaw）→ 不被 unknownRaw 门误伤，走 insert 去重成功、持久化 draw_uuid 互不相同（codex WB R6）")
    func finalizeDuplicateKnownIdsDedupedAtInsertSucceeds() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // pending_training 含两条【同 id】已知画线（无 unknownRaw）——resumable Normal 会话（两个真实客户端各画
        // 一条线、id 生成器坏/旧 bug 撞车等场景）。修复前：finalize 的 unknownRaw 门直接调用 `reconciled`，
        // 该函数对重复非空 id fail-closed 抛 `.dbCorrupted`——用户被永久卡死，即便 insertRecord 早已备好去重。
        try seedPendingTrainingRow(appDB, sessionKey: "SK-dup",
                                   drawingsJSON: "[\(known("dup")),\(known("dup"))]")
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePending())
        let recordId = try #require(try await coord.finalize(engine: engine))   // 不应抛
        let (_, _, drawings) = try appDB.loadRecordBundle(id: recordId)
        #expect(drawings.count == 2)                                            // 两条画线均保留（未被丢弃）
        let uuids: [String] = try await appDB.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT draw_uuid FROM drawings WHERE record_id = ?", arguments: [recordId])
        }
        #expect(Set(uuids).count == 2)                                          // 持久化 draw_uuid 互不相同（insert 去重生效）
    }

    @Test("finalize: pending 画线 id 与库中【另一条已 finalize record】的 draw_uuid 冲突（非本批重复）→ 全局去重成功、重新生成、原记录不受影响（codex WB R7）")
    func finalizeGlobalDrawUuidCollisionAcrossRecordsDedupedSucceeds() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // 先 finalize 一条已存在 record，其 drawings 表持久化 draw_uuid="collide-me"
        // （迁移 0009 GLOBALLY UNIQUE 的 draw_uuid 列）。
        let priorId = try appDB.insertRecord(TrainingRecord(
            id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
            stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
            totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: -0.03,
            buyCount: 0, sellCount: 0,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
            finalTick: 7), ops: [],
            drawings: [DrawingObject(id: "collide-me", toolType: .horizontal,
                                      anchors: [DrawingAnchor(period: .m3, candleIndex: 0, price: 10)],
                                      isExtended: false, panelPosition: 0)])
        // 一个全新（resumable）会话的 pending_training 携带一条【单独一条，本批内不重复】的 id，
        // 恰好与上面已入库的 id 相同——修复前的 batch-local Set 只在本批内查重，查不出这个跨批冲突，
        // 直接原样插 draw_uuid="collide-me" → 撞迁移 0009 的 UNIQUE 约束 → finalize 整体回滚、用户卡死。
        try seedPendingTrainingRow(appDB, sessionKey: "SK-global-collide",
                                   drawingsJSON: "[\(known("collide-me"))]")
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePending())
        let recordId = try #require(try await coord.finalize(engine: engine))   // 不应因 UNIQUE 冲突回滚
        let (_, _, drawings) = try appDB.loadRecordBundle(id: recordId)
        #expect(drawings.count == 1)                                            // 画线内容保留
        let uuids: [String] = try await appDB.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT draw_uuid FROM drawings WHERE record_id = ?", arguments: [recordId])
        }
        #expect(uuids.first != "collide-me")                                    // 全局冲突 → 重新生成新 id
        // 原记录的行完全不受影响（仍是它原来持久化的 draw_uuid）。
        let priorUuids: [String] = try await appDB.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT draw_uuid FROM drawings WHERE record_id = ?", arguments: [priorId])
        }
        #expect(priorUuids == ["collide-me"])
    }

    @Test("复盘净改动须纳入 unknownTopLevel：working 与 saved 已知画线集+hiddenIds+unknownRaw 均相同，仅 wrapper 顶层未来 key(futureMeta) 值不同 → reviewNetChanged()/persistReviewWorkingIfChanged 均判「有改动」，working 行（含其 futureMeta）不被 clearWorking 抹掉（codex WB R8 finding 1）")
    func reviewNetChangeUnknownTopLevelOnlyDiffPreventsClearWorking() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        // saved 与 working 的已知画线集([g1])+hiddenIds([])+unknownRaw(均无) 完全相同，仅 wrapper 顶层
        // futureMeta 的值不同（模拟一个更新客户端只改了 working 行携带的顶层 review-metadata，未动画线/
        // 隐藏态/unknownRaw——这是此前 4 项里唯独漏比的第 4 项）。
        try seedReviewSavedAndWorking(appDB, recordId: rid,
                                       savedWrapperJSON: #"{"drawings":[\#(known("g1"))],"hiddenIds":[],"futureMeta":{"x":1}}"#,
                                       stepTick: 3,
                                       workingWrapperJSON: #"{"drawings":[\#(known("g1"))],"hiddenIds":[],"futureMeta":{"x":2}}"#)
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePendingReview(recordId: rid))  // resume：known+hiddenIds+unknownRaw 均==committed，仅 unknownTopLevel 不同
        // reviewNetChanged() 须靠 unknownTopLevel 比较单独识别出「有改动」（同 R5 修的 unknownRaw-only 场景，
        // 但 unknownTopLevel 这第 4 项此前未纳入同一判定）。
        #expect(coord.reviewNetChanged() == true)
        // 零画线编辑——persistReviewWorkingIfChanged 同款须判「有改动」，working 行（含其 futureMeta）保留。
        try coord.persistReviewWorkingIfChanged(engine: engine)
        let workingCol: String? = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT working_drawings FROM review_archive WHERE record_id=\(rid)")?["working_drawings"]
        }
        // 修复前：只比 3 项 → 误判「无改动」→ clearWorking 抹掉 working 行 → working 独有的 futureMeta:{"x":2} 永久丢失。
        #expect(workingCol != nil)                                       // working 行未被 clearWorking 清空
        #expect(workingCol?.contains(#""futureMeta":{"x":2}"#) == true) // working 侧 futureMeta 值未丢失
    }

    @Test("复盘净改动须纳入 known 未来字段：working 与 saved 已知画线集([g1])+hiddenIds+unknownRaw+unknownTopLevel 均相同，仅 g1 raw 携带的未来字段(futureField)值不同 → reviewNetChanged()/persistReviewWorkingIfChanged 均判「有改动」，working 行（含其未来字段）不被 clearWorking 抹掉（codex WB R9 finding 2）")
    func reviewNetChangeKnownFutureFieldOnlyDiffPreventsClearWorking() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        // saved 与 working 的 g1 解码已知字段完全相同（DrawingObject 解码时未来字段被忽略），仅各自 raw
        // 携带的未来字段(futureField)值不同（1 vs 2）——已知字段/hiddenIds/unknownRaw/unknownTopLevel
        // 全同，唯独「已知条自身的未来字段」不同，这是此前 5 项判定里唯独漏比的第 5 项。
        func knownWithFuture(_ v: Int) -> String {
            String(known("g1").dropLast()) + #","futureField":\#(v)}"#
        }
        try seedReviewSavedAndWorking(appDB, recordId: rid,
                                       savedWrapperJSON: #"{"drawings":[\#(knownWithFuture(1))],"hiddenIds":[]}"#,
                                       stepTick: 3,
                                       workingWrapperJSON: #"{"drawings":[\#(knownWithFuture(2))],"hiddenIds":[]}"#)
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePendingReview(recordId: rid))  // resume：known+hiddenIds+unknownRaw+unknownTopLevel 均==committed，仅 g1 未来字段不同
        // reviewNetChanged() 须靠 known 未来字段比较单独识别出「有改动」（同 R4/R5/R8 修的其余 4 项盲区场景）。
        #expect(coord.reviewNetChanged() == true)
        // 零画线编辑——persistReviewWorkingIfChanged 同款须判「有改动」，working 行（含其未来字段）保留。
        try coord.persistReviewWorkingIfChanged(engine: engine)
        let workingCol: String? = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT working_drawings FROM review_archive WHERE record_id=\(rid)")?["working_drawings"]
        }
        // 修复前：只比 4 项 → 误判「无改动」→ clearWorking 抹掉 working 行 → working 独有的 futureField:2 永久丢失。
        #expect(workingCol != nil)                                  // working 行未被 clearWorking 清空
        #expect(workingCol?.contains(#""futureField":2"#) == true)  // working 侧未来字段值未丢失
    }

    @Test("复盘净改动须纳入 known 未来枚举值：working 与 saved 已知字段([g1]解码全同，colorToken 各自 fallback 成 .orange)+hiddenIds+unknownRaw+unknownTopLevel+未来 EXTRA 字段 均相同，仅 g1 raw 携带的 colorToken 未来值(futureNeon vs futureCyan)不同 → reviewNetChanged()/persistReviewWorkingIfChanged 均判「有改动」，working 行不被 clearWorking 抹掉（codex WB R18，红→绿）")
    func reviewNetChangeKnownFutureEnumValueOnlyDiffPreventsClearWorking() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rid = try makeRecord(appDB)
        // g1 的已知字段两侧完全相同（colorToken 未来值 R16 均 fallback 成 .orange），hiddenIds/unknownRaw/
        // unknownTopLevel/已知未来 EXTRA 字段全同——唯独「已知条自身 colorToken 的未来枚举值」不同
        // （"futureNeon" vs "futureCyan"），这是此前 5 项判定里唯独漏比的第 6 项（R9 finding 2 只比了
        // knownDiskKeys 之外的 EXTRA key，colorToken 本身在 knownDiskKeys 内，对那道判定不可见）。
        func knownWithColorToken(_ id: String, _ token: String) -> String {
            known(id).replacingOccurrences(of: #""colorToken":"orange""#, with: #""colorToken":"\#(token)""#)
        }
        try seedReviewSavedAndWorking(appDB, recordId: rid,
                                       savedWrapperJSON: #"{"drawings":[\#(knownWithColorToken("g1", "futureNeon"))],"hiddenIds":[]}"#,
                                       stepTick: 3,
                                       workingWrapperJSON: #"{"drawings":[\#(knownWithColorToken("g1", "futureCyan"))],"hiddenIds":[]}"#)
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePendingReview(recordId: rid))  // resume：known+hiddenIds+unknownRaw+unknownTopLevel+未来EXTRA字段 均==committed，仅 colorToken 未来值不同
        // reviewNetChanged() 须靠 known 未来枚举值比较单独识别出「有改动」（同 R4/R5/R8/R9 finding2 修的其余 5 项盲区场景）。
        #expect(coord.reviewNetChanged() == true)
        // 零画线编辑——persistReviewWorkingIfChanged 同款须判「有改动」，working 行（含其未来枚举值）保留。
        try coord.persistReviewWorkingIfChanged(engine: engine)
        let workingCol: String? = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT working_drawings FROM review_archive WHERE record_id=\(rid)")?["working_drawings"]
        }
        // 修复前：只比 5 项 → 误判「无改动」→ clearWorking 抹掉 working 行 → working 独有的 futureCyan 永久丢失。
        #expect(workingCol != nil)                                          // working 行未被 clearWorking 清空
        #expect(workingCol?.contains(#""colorToken":"futureCyan""#) == true)  // working 侧未来枚举值未丢失
    }

    // MARK: - load 时归一化重复已知 id（codex WB R8 finding 2）：resume 之后 autosave（saveProgress）不 brick

    @Test("pending_training: resume(pending 含重复非空已知 id)→saveProgress(autosave) 不抛，持久化 id 互不相同（codex WB R8 finding 2）")
    func resumePendingAutosaveToleratesDuplicateKnownIds() async throws {
        let (url, appDB) = try makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // pending_training 含两条【同 id】已知画线（无 unknownRaw）——同 finalize dup-id 场景（两个真实客户端
        // 各画一条线、id 生成器坏/旧 bug 撞车），但这里是【resume 之后未 finalize 就先触发一次 autosave】：
        // 修复前 `saveProgress` 走 `engine.loadedDrawingsLossy.reconciled(currentKnown:)`，loaded 侧含重复 id
        // → fail-closed 抛 `.dbCorrupted`（brick：每次 tick/画线后台 autosave 都抛，进度存不进去，直到用户
        // 走到 finalize 才被 insert-time 去重救回——但崩溃在 finalize 之前就会丢光）。
        try seedPendingTrainingRow(appDB, sessionKey: "SK-dup-autosave",
                                   drawingsJSON: "[\(known("dup")),\(known("dup"))]")
        let coord = makeCoordinator(appDB)
        let engine = try #require(try await coord.resumePending())
        try await coord.saveProgress(engine: engine)   // 不应抛（红→绿）
        let col: String = try await appDB.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT drawings FROM pending_training WHERE id = 1")!["drawings"]
        }
        let persisted = try LossyDrawingArray.decode(Data(col.utf8))
        let ids = persisted.drawings.map(\.id)
        #expect(ids.count == 2)                          // 两条画线均保留（未被丢弃）
        #expect(Set(ids).count == 2)                     // load 时归一化后持久化 id 互不相同
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

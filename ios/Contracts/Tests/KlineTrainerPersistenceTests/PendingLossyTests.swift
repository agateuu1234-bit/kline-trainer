// PendingLossyTests.swift
// 画线工具扩充 P1a Task 11：pending_training / pending_replay 有损保真解码。
// 验证 loadReplay/loadPending 对单条未知/未来 toolType 只跳过（不整组 .dbCorrupted）、
// saveReplay/savePending 保真+保序回写（未识别条原位保留、不跨记录串味）。
import Testing
import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerContracts
@testable import KlineTrainerPersistence

@Suite("Pending 有损保真")
struct PendingLossyTests {

    // MARK: - Helpers（对齐 PendingReplayPersistenceTests.swift / ReviewArchiveMigrationTests.swift 既有裸 GRDB 用法）

    private func makeMigratedDB() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()   // in-memory
        try AppDBMigrations.makeMigrator().migrate(queue)
        return queue
    }

    /// 良构已知条 JSON（`DrawingObject` 全字段；`period` 用真实 `Period.m3.rawValue == "3m"`）。
    private func known(_ id: String) -> String {
        #"{"id":"\#(id)","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#
    }

    private func makePendingReplay(recordId: Int64, drawings: [DrawingObject]) throws -> PendingReplay {
        try PendingReplay(recordId: recordId, trainingSetFilename: "seed.sqlite", globalTickIndex: 0,
                      upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
                      feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
                      tradeOperations: [], drawings: drawings, startedAt: 0, accumulatedCapital: 100_000,
                      drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    }

    private func makePendingTraining(sessionKey: String, drawings: [DrawingObject]) throws -> PendingTraining {
        try PendingTraining(trainingSetFilename: "seed.sqlite", globalTickIndex: 0,
                         upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
                         feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
                         tradeOperations: [], drawings: drawings, startedAt: 0, accumulatedCapital: 100_000,
                         drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0), sessionKey: sessionKey)
    }

    /// 先经真实 saveReplay 写一条合法行，再用裸 SQL 把 drawings 列换成任意（可含未知条）JSON——
    /// 避免手拼整条 INSERT 各列（易漏列/写错顺序），且不经过模型层（保证 drawingsJSON 就是磁盘字节）。
    private func seedPendingReplayRow(_ queue: DatabaseQueue, recordId: Int64, drawingsJSON: String) throws {
        let base = try makePendingReplay(recordId: recordId, drawings: [])
        try queue.write { db in
            try PendingReplayRepositoryImpl.saveReplay(db, replay: base)
            try db.execute(sql: "UPDATE pending_replay SET drawings = ? WHERE id = 1", arguments: [drawingsJSON])
        }
    }

    private func seedPendingTrainingRow(_ queue: DatabaseQueue, sessionKey: String, drawingsJSON: String) throws {
        let base = try makePendingTraining(sessionKey: sessionKey, drawings: [])
        try queue.write { db in
            try PendingTrainingRepositoryImpl.savePending(db, pending: base)
            try db.execute(sql: "UPDATE pending_training SET drawings = ? WHERE id = 1", arguments: [drawingsJSON])
        }
    }

    // MARK: - pending_replay

    @Test("pending_replay: [knownA, 未来条, knownB] → loadReplay 不抛得 2 已知；saveReplay 后未来条字节保留【且仍在中间】")
    func replayLossyLoadPreservesOrder() throws {
        let db = try makeMigratedDB()
        let unknown = #"{"toolType":"__future__","z":1.0}"#
        try seedPendingReplayRow(db, recordId: 42, drawingsJSON: "[\(known("g1")),\(unknown),\(known("g2"))]")
        let p = try db.read { try PendingReplayRepositoryImpl.loadReplay($0) }
        #expect(p != nil)                                  // 不再因一条未来条整体 .dbCorrupted
        #expect(p?.drawings.count == 2)                    // 两条已知（未来条不解码）
        try db.write { try PendingReplayRepositoryImpl.saveReplay($0, replay: p!) }   // 保真+保序回写（重发 p.lossy）
        let col: String = try db.read {
            try Row.fetchOne($0, sql: "SELECT drawings FROM pending_replay WHERE id=1")!["drawings"]
        }
        #expect(col.contains(unknown))                     // 未来条字节仍在
        let iA = col.range(of: #""g1""#)!.lowerBound        // 顺序断言：knownA → 未来条 → knownB
        let iU = col.range(of: "__future__")!.lowerBound
        let iB = col.range(of: #""g2""#)!.lowerBound
        #expect(iA < iU && iU < iB)                         // 未来条仍在中间（未被 append 到末尾）
    }

    @Test("saveReplay 换记录（record 变）→ 不把旧记录 unknownRaw 串进新记录")
    func replayNoCrossRecordLeak() throws {
        let db = try makeMigratedDB()
        try seedPendingReplayRow(db, recordId: 42, drawingsJSON: #"[{"toolType":"__future__"}]"#)
        let fresh = try makePendingReplay(recordId: 99, drawings: [])   // 新记录、无画线
        try db.write { try PendingReplayRepositoryImpl.saveReplay($0, replay: fresh) }
        let col: String = try db.read {
            try Row.fetchOne($0, sql: "SELECT drawings FROM pending_replay WHERE id=1")!["drawings"]
        }
        #expect(!col.contains("__future__"))               // 旧记录的未来条不串进 99
    }

    // MARK: - pending_training（同款镜像；PendingTrainingRepositoryImpl 走同一改动）

    @Test("pending_training: [knownA, 未来条, knownB] → loadPending 不抛得 2 已知；savePending 后未来条字节保留【且仍在中间】")
    func trainingLossyLoadPreservesOrder() throws {
        let db = try makeMigratedDB()
        let unknown = #"{"toolType":"__future__","z":1.0}"#
        try seedPendingTrainingRow(db, sessionKey: "SK-1", drawingsJSON: "[\(known("g1")),\(unknown),\(known("g2"))]")
        let p = try db.read { try PendingTrainingRepositoryImpl.loadPending($0) }
        #expect(p != nil)
        #expect(p?.drawings.count == 2)
        try db.write { try PendingTrainingRepositoryImpl.savePending($0, pending: p!) }
        let col: String = try db.read {
            try Row.fetchOne($0, sql: "SELECT drawings FROM pending_training WHERE id=1")!["drawings"]
        }
        #expect(col.contains(unknown))
        let iA = col.range(of: #""g1""#)!.lowerBound
        let iU = col.range(of: "__future__")!.lowerBound
        let iB = col.range(of: #""g2""#)!.lowerBound
        #expect(iA < iU && iU < iB)
    }

    @Test("savePending 换记录（sessionKey 变）→ 不把旧记录 unknownRaw 串进新记录")
    func trainingNoCrossRecordLeak() throws {
        let db = try makeMigratedDB()
        try seedPendingTrainingRow(db, sessionKey: "SK-old", drawingsJSON: #"[{"toolType":"__future__"}]"#)
        let fresh = try makePendingTraining(sessionKey: "SK-new", drawings: [])
        try db.write { try PendingTrainingRepositoryImpl.savePending($0, pending: fresh) }
        let col: String = try db.read {
            try Row.fetchOne($0, sql: "SELECT drawings FROM pending_training WHERE id=1")!["drawings"]
        }
        #expect(!col.contains("__future__"))
    }
}

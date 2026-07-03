import Testing
import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerContracts
@testable import KlineTrainerPersistence

@MainActor
@Test func migration0006_createsTable_userVersion6() throws {
    let queue = try DatabaseQueue()        // in-memory
    try AppDBMigrations.makeMigrator().migrate(queue)
    let uv = try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
    #expect(uv == 6)   // 完整 migrator 现终态 = 6（0008 drawing reveal_tick 新增）
    let exists = try queue.read {
        try Int.fetchOne($0, sql:
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='pending_replay'")
    }
    #expect(exists == 1)
}

@MainActor
@Test func pendingReplayImpl_roundTripAndClear() throws {
    let queue = try DatabaseQueue()
    try AppDBMigrations.makeMigrator().migrate(queue)
    let p = PendingReplay(recordId: 9, trainingSetFilename: "z.sqlite", globalTickIndex: 3,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data([7]), cashBalance: 88_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 123, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try queue.write { try PendingReplayRepositoryImpl.saveReplay($0, replay: p) }
    let back = try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) }
    #expect(back == p)
    try queue.write { try PendingReplayRepositoryImpl.clearReplay($0) }
    #expect(try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) } == nil)
}

// codex plan-R17-F1：GRDB-backed 测条件清的真 SQL（fake 测不护真 SQL：漏 WHERE record_id 会真丢档）
@MainActor
@Test func pendingReplayImpl_conditionalClear_onlyMatchingRecordId() throws {
    let queue = try DatabaseQueue()
    try AppDBMigrations.makeMigrator().migrate(queue)
    let slotA = PendingReplay(recordId: 101, trainingSetFilename: "a.sqlite", globalTickIndex: 1,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try queue.write { try PendingReplayRepositoryImpl.saveReplay($0, replay: slotA) }
    try queue.write { try PendingReplayRepositoryImpl.clearReplay($0, ifRecordId: 202) }   // 不匹配 → 不删
    #expect(try queue.read { try PendingReplayRepositoryImpl.loadReplaySlotInfo($0) }?.recordId == 101)
    try queue.write { try PendingReplayRepositoryImpl.clearReplay($0, ifRecordId: 101) }   // 匹配 → 删
    #expect(try queue.read { try PendingReplayRepositoryImpl.loadReplaySlotInfo($0) } == nil)
}

// 新需求10：resetAllTrainingProgress 连带清 pending_replay（单事务）
@MainActor
@Test func resetAllTrainingProgress_clears_bothPendingAndPendingReplay() throws {
    let dbPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_reset_\(UUID().uuidString).sqlite")
    let db = try DefaultAppDB(dbPath: dbPath)
    // 写一条 pending_training（使两个断言都有意义）
    let pendingTraining = PendingTraining(
        trainingSetFilename: "t.sqlite", globalTickIndex: 5,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(),
        cashBalance: 100_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0),
        sessionKey: "test-key")
    try db.savePending(pendingTraining)
    #expect(try db.loadPending() != nil)
    // 写一条 pending_replay
    let slot = PendingReplay(recordId: 9, trainingSetFilename: "z.sqlite", globalTickIndex: 3,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data([7]), cashBalance: 88_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 123, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try db.saveReplay(slot)
    #expect(try db.loadReplay() != nil)
    // reset 连带清两个表
    try db.resetAllTrainingProgress(toCapital: 100_000)
    #expect(try db.loadReplay() == nil)        // pending_replay 已清
    #expect(try db.loadPending() == nil)       // pending_training 也已清
}

// codex plan-R17-F1：payload 列损坏时 loadReplaySlotInfo 仍返元数据（不解码）；loadReplay 抛 .dbCorrupted（确定区分）
@MainActor
@Test func pendingReplayImpl_slotInfo_returnsMetadataDespiteCorruptPayload() throws {
    let queue = try DatabaseQueue()
    try AppDBMigrations.makeMigrator().migrate(queue)
    try queue.write { db in
        // 直接 SQL 插入：record_id/filename/period 合法，payload 列填非法 base64/JSON
        try db.execute(sql: """
            INSERT INTO pending_replay
              (id, record_id, training_set_filename, global_tick_index, upper_period, lower_period,
               position_data, fee_snapshot, trade_operations, drawings,
               started_at, accumulated_capital, cash_balance, drawdown)
            VALUES (1, 77, 'rec.sqlite', 1, '60m', 'daily', '!!notbase64!!', '{bad', '{bad', '{bad', 1, 100000, 100000, '{bad')
            """)
    }
    let info = try queue.read { try PendingReplayRepositoryImpl.loadReplaySlotInfo($0) }
    #expect(info?.recordId == 77)                       // 元数据不解码 → 返回
    #expect(info?.trainingSetFilename == "rec.sqlite")
    #expect(throws: AppError.self) {                    // 全量解码损坏 → .dbCorrupted
        _ = try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) }
    }
}

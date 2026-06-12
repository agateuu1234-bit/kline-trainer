import Testing
import Foundation
import GRDB
import KlineTrainerContracts
@testable import KlineTrainerPersistence

@Suite("SessionFinalizationPort（DefaultAppDB 单事务 + 幂等）")
struct SessionFinalizationPortTests {

    static func record(createdAt: Int64 = 1) -> TrainingRecord {
        TrainingRecord(id: nil, trainingSetFilename: "s.sqlite", createdAt: createdAt,
                       stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 3,
                       totalCapital: 50_000, profit: 1_000, returnRate: 0.02, maxDrawdown: -0.1,
                       buyCount: 1, sellCount: 1,
                       feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                       finalTick: 7)
    }

    static func op(tick: Int) -> TradeOperation {
        TradeOperation(globalTick: tick, period: .m3, direction: .buy, price: 10,
                       shares: 100, positionTier: .tier1, commission: 1,
                       stampDuty: 0, totalCost: 1001, createdAt: Int64(tick))
    }

    static func pending(sessionKey: String) -> PendingTraining {
        PendingTraining(trainingSetFilename: "s.sqlite", globalTickIndex: 7,
                        upperPeriod: .m60, lowerPeriod: .m3,
                        positionData: Data(), cashBalance: 50_000,
                        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                        tradeOperations: [], drawings: [], startedAt: 1,
                        accumulatedCapital: 50_000,
                        drawdown: .initial, sessionKey: sessionKey)
    }

    @Test("成功路径：record+ops+drawings 入库且 pending 清（单事务两效果）")
    func finalize_success_inserts_and_clears() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let db = try DefaultAppDB(dbPath: dbURL)
        try db.savePending(Self.pending(sessionKey: "SK-1"))
        let id = try db.finalizeSession(record: Self.record(), ops: [Self.op(tick: 1)],
                                        drawings: [], sessionKey: "SK-1")
        #expect(id > 0)
        #expect(try db.loadPending() == nil)
        let bundle = try db.loadRecordBundle(id: id)
        #expect(bundle.1.count == 1)
        // session_key 落列
        let key = try db.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT session_key FROM training_records WHERE id = ?",
                                arguments: [id])
        }
        #expect(key == "SK-1")
    }

    @Test("retry 幂等：同 sessionKey 第二次 finalize → 返同 id，不重插 record/ops")
    func finalize_same_key_is_idempotent() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let db = try DefaultAppDB(dbPath: dbURL)
        let id1 = try db.finalizeSession(record: Self.record(), ops: [Self.op(tick: 1)],
                                         drawings: [], sessionKey: "SK-R")
        let id2 = try db.finalizeSession(record: Self.record(createdAt: 99), ops: [Self.op(tick: 2)],
                                         drawings: [], sessionKey: "SK-R")
        #expect(id1 == id2)
        let counts = try db.dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM training_records") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trade_operations") ?? -1)
        }
        #expect(counts.0 == 1)
        #expect(counts.1 == 1)   // 第二次的 ops 未重插
    }

    @Test("不同 sessionKey → 各自入库（幂等不误伤正常多局）")
    func finalize_distinct_keys_insert_separately() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let db = try DefaultAppDB(dbPath: dbURL)
        let a = try db.finalizeSession(record: Self.record(), ops: [], drawings: [], sessionKey: "SK-A")
        let b = try db.finalizeSession(record: Self.record(createdAt: 2), ops: [], drawings: [], sessionKey: "SK-B")
        #expect(a != b)
    }

    @Test("crash-after-commit：finalize 成功后重开 DB（模拟 relaunch）→ pending 无、record 恰 1 条")
    func finalize_commit_then_relaunch_no_duplicate_surface() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        do {
            let db = try DefaultAppDB(dbPath: dbURL)
            try db.savePending(Self.pending(sessionKey: "SK-C"))
            _ = try db.finalizeSession(record: Self.record(), ops: [], drawings: [], sessionKey: "SK-C")
        }   // db 出作用域 = 进程死前最后状态已 commit
        let relaunched = try DefaultAppDB(dbPath: dbURL)   // relaunch：migrator 幂等重跑
        #expect(try relaunched.loadPending() == nil)        // 无 pending → 不会 resume → 不会二次 finalize
        #expect(try relaunched.listRecords(limit: nil).count == 1)
    }

    @Test("原子性：事务内 INSERT 失败（SQLITE_FULL 注入）→ record 0 条 + pending 原样保留")
    func finalize_failure_rolls_back_both_effects() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let db = try DefaultAppDB(dbPath: dbURL)
        try db.savePending(Self.pending(sessionKey: "SK-F"))
        // 注入：页上限压到当前已用页数 → 后续页分配失败 SQLITE_FULL
        try db.dbQueue.write { d in
            let pages = try Int.fetchOne(d, sql: "PRAGMA page_count") ?? 1
            try d.execute(sql: "PRAGMA max_page_count = \(pages)")
        }
        let bigOps = (0..<2_000).map { Self.op(tick: $0) }   // 足量 payload 强制页分配
        #expect(throws: (any Error).self) {
            _ = try db.finalizeSession(record: Self.record(), ops: bigOps,
                                       drawings: [], sessionKey: "SK-F")
        }
        // 解除上限后验证两效果都未发生（rollback 双向）
        try db.dbQueue.write { d in try d.execute(sql: "PRAGMA max_page_count = 1073741823") }
        #expect(try db.loadPending() != nil, "pending 须原样保留")
        #expect(try db.listRecords(limit: nil).isEmpty, "record 须未入库")
    }
}

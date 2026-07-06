import Testing
import XCTest
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

    static func pending(sessionKey: String) throws -> PendingTraining {
        try PendingTraining(trainingSetFilename: "s.sqlite", globalTickIndex: 7,
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
                                        drawings: [], sessionKey: "SK-1").id
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
                                         drawings: [], sessionKey: "SK-R").id
        let id2 = try db.finalizeSession(record: Self.record(createdAt: 99), ops: [Self.op(tick: 2)],
                                         drawings: [], sessionKey: "SK-R").id
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
        let a = try db.finalizeSession(record: Self.record(), ops: [], drawings: [], sessionKey: "SK-A").id
        let b = try db.finalizeSession(record: Self.record(createdAt: 2), ops: [], drawings: [], sessionKey: "SK-B").id
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
        defer { try? db.dbQueue.write { d in try d.execute(sql: "PRAGMA max_page_count = 1073741823") } }
        let bigOps = (0..<2_000).map { Self.op(tick: $0) }   // 足量 payload 强制页分配
        #expect(throws: (any Error).self) {
            _ = try db.finalizeSession(record: Self.record(), ops: bigOps,
                                       drawings: [], sessionKey: "SK-F")
        }
        // 验证两效果都未发生（rollback 双向）；defer 在作用域末尾解除上限
        #expect(try db.loadPending() != nil, "pending 须原样保留")
        #expect(try db.listRecords(limit: nil).isEmpty, "record 须未入库")
    }

    @Test("retry 幂等 + 残留 pending：幂等命中路径仍清 pending（§4.7c retry 完整语义）")
    func finalize_idempotent_hit_still_clears_stale_pending() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let db = try DefaultAppDB(dbPath: dbURL)
        try db.savePending(Self.pending(sessionKey: "SK-R2"))
        let id1 = try db.finalizeSession(record: Self.record(), ops: [], drawings: [], sessionKey: "SK-R2").id
        // 模拟 stale pending 复存（如 crash 前最后一次 autosave 落盘晚于 finalize 观测）
        try db.savePending(Self.pending(sessionKey: "SK-R2"))
        let id2 = try db.finalizeSession(record: Self.record(createdAt: 99), ops: [], drawings: [], sessionKey: "SK-R2").id
        #expect(id1 == id2)
        #expect(try db.loadPending() == nil, "幂等命中路径必须同样清 pending")
        #expect(try db.listRecords(limit: nil).count == 1)
    }
}

// MARK: - A4：finalize 派生权威资金 + retry 幂等 + fail-closed（RFC-A）

/// XCTest 套件（与上面的 Swift Testing 套件同 target 共存）：覆盖 finalize 返回值/写入权威资金 + 各 fail-closed 角。
final class SessionFinalizationCapitalTests: XCTestCase {
    private var dbURL: URL!
    private var db: DefaultAppDB!

    override func setUp() async throws {
        dbURL = try AppDBFixture.makeFreshDB()
        db = try DefaultAppDB(dbPath: dbURL)
    }
    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
    }

    // total_capital=100_000, profit=23_456 → 派生 123_456
    private func someRecord() -> TrainingRecord {
        TrainingRecord(id: nil, trainingSetFilename: "s.sqlite", createdAt: 1,
                       stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 3,
                       totalCapital: 100_000, profit: 23_456, returnRate: 0.23, maxDrawdown: -0.1,
                       buyCount: 1, sellCount: 1,
                       feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                       finalTick: 7)
    }
    private func someRecordWithProfit(_ p: Double) -> TrainingRecord {
        TrainingRecord(id: nil, trainingSetFilename: "s.sqlite", createdAt: 1,
                       stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 3,
                       totalCapital: 100_000, profit: p, returnRate: 0, maxDrawdown: 0,
                       buyCount: 0, sellCount: 0,
                       feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                       finalTick: 7)
    }
    // 构造 total_capital+profit == v 的记录（total_capital 固定 100_000，profit 补差）。
    private func recordWithCapital(_ v: Double) -> TrainingRecord {
        someRecordWithProfit(v - 100_000)
    }

    // 绕过 setTotalCapital/saveSettings 守卫，直写/删 settings 行模拟 DB 损坏/行丢失。
    private func rawWriteSetting(_ key: String, _ value: String) throws {
        try db.dbQueue.write { try $0.execute(sql:
            "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", arguments: [key, value]) }
    }
    private func rawDeleteSetting(_ key: String) throws {
        try db.dbQueue.write { try $0.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key]) }
    }

    func test_finalize_returns_and_writes_capital_from_persisted_record() throws {
        let r = try db.finalizeSession(record: someRecord(), ops: [], drawings: [], sessionKey: "k1")
        XCTAssertGreaterThan(r.id, 0)
        XCTAssertEqual(r.totalCapital, 123_456, accuracy: 1e-6)                      // 返回的权威值
        XCTAssertEqual(try db.loadSettings().totalCapital, 123_456, accuracy: 1e-6)  // 写入 DB = 同值
    }

    // codex R-plan-2-1/5-1：同 sessionKey retry 用「发散现值」record，返回值 + DB 仍=首次值（无更晚 session）
    func test_finalize_retry_same_key_returns_first_capital() throws {
        _ = try db.finalizeSession(record: someRecord(), ops: [], drawings: [], sessionKey: "k1")  // 123_456
        let divergent = someRecordWithProfit(999_999)
        let r2 = try db.finalizeSession(record: divergent, ops: [], drawings: [], sessionKey: "k1")
        XCTAssertEqual(r2.totalCapital, 123_456, accuracy: 1e-6)                      // 重复路径返回当前权威值(=首次)
        XCTAssertEqual(try db.loadSettings().totalCapital, 123_456, accuracy: 1e-6)   // DB 不被覆盖
    }

    // codex R-plan-9-1：finalize k1 → finalize k2(更新) → 过期重试 k1，权威资金**不回退**到 k1。
    func test_stale_retry_after_newer_session_keeps_newer_capital() throws {
        _ = try db.finalizeSession(record: recordWithCapital(110_000), ops: [], drawings: [], sessionKey: "k1")
        _ = try db.finalizeSession(record: recordWithCapital(130_000), ops: [], drawings: [], sessionKey: "k2")
        let r = try db.finalizeSession(record: recordWithCapital(110_000), ops: [], drawings: [], sessionKey: "k1")  // 过期重试
        XCTAssertEqual(r.totalCapital, 130_000, accuracy: 1e-6)                       // 返回当前(k2)，不回退
        XCTAssertEqual(try db.loadSettings().totalCapital, 130_000, accuracy: 1e-6)   // DB 仍 k2
    }

    // codex R-plan-10-1：过期 finalize 重试不得清掉**他人**在飞 pending。
    func test_stale_retry_does_not_clear_unrelated_pending() throws {
        _ = try db.finalizeSession(record: someRecord(), ops: [], drawings: [], sessionKey: "k1")  // k1 finalize
        try db.savePending(SessionFinalizationPortTests.pending(sessionKey: "k2"))                 // 新 in-progress 局
        _ = try db.finalizeSession(record: someRecord(), ops: [], drawings: [], sessionKey: "k1")  // k1 过期重试
        XCTAssertNotNil(try db.loadPending())                       // k2 pending 仍在（未被误清）
        XCTAssertEqual(try db.loadPending()?.sessionKey, "k2")
    }

    // codex R-plan-12-2/17-1：重复重试遇**损坏**的 total_capital（非有限/畸形/负）→ finalize 抛 .dbCorrupted。
    func test_retry_with_corrupt_capital_fails_closed() throws {
        for bad in ["abc", "-1.0", "inf"] {
            _ = try db.finalizeSession(record: someRecord(), ops: [], drawings: [], sessionKey: "k1")
            try rawWriteSetting("total_capital", bad)   // 绕过 setTotalCapital 守卫，模拟 DB 损坏
            XCTAssertThrowsError(try db.finalizeSession(record: someRecord(), ops: [], drawings: [], sessionKey: "k1"),
                                 "bad=\(bad)") { e in
                guard case AppError.persistence(.dbCorrupted) = e else { return XCTFail("expected .dbCorrupted for \(bad), got \(e)") }
            }
            try rawWriteSetting("total_capital", String(AppSettings.defaultTotalCapital))   // 复位供下一轮
        }
    }

    // codex R-plan-25-2：重复 finalize（记录已存在）但 total_capital **缺失** = 不一致状态 → fail-closed（不返 10万）。
    func test_retry_with_missing_capital_but_record_exists_fails_closed() throws {
        _ = try db.finalizeSession(record: someRecord(), ops: [], drawings: [], sessionKey: "k1")  // 首次：记录+权威写入
        try rawDeleteSetting("total_capital")   // 模拟 settings 行丢失/迁移偏差（记录仍在）
        XCTAssertThrowsError(try db.finalizeSession(record: someRecord(), ops: [], drawings: [], sessionKey: "k1")) { e in
            guard case AppError.persistence(.dbCorrupted) = e else { return XCTFail("expected .dbCorrupted, got \(e)") }
        }
    }

    // codex R-plan-13-1：退化局（total_capital+profit < 0）→ 权威资金 floor 到 0（不写负值）。
    func test_finalize_floors_negative_net_capital_to_zero() throws {
        let r = try db.finalizeSession(record: recordWithCapital(-5_000), ops: [], drawings: [], sessionKey: "kNeg")
        XCTAssertEqual(r.totalCapital, 0, accuracy: 1e-6)                        // 返回 floor 后 0
        XCTAssertEqual(try db.loadSettings().totalCapital, 0, accuracy: 1e-6)    // DB 写 0
    }
}

import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence
@preconcurrency import GRDB

final class TrainingResetPortTests: XCTestCase {
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

    // 造一条带 ops + drawings 的记录 + 一个 pending 行 + 旧 capital。
    private func seedProgress() throws {
        let rec = TrainingRecord(
            id: nil, trainingSetFilename: "t.sqlite", createdAt: 1_735_689_600,
            stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 3,
            totalCapital: 100_000, profit: 23_456, returnRate: 0.23,
            maxDrawdown: 0.1, buyCount: 2, sellCount: 1,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            finalTick: 40)
        let op = TradeOperation(
            globalTick: 10, period: .m3, direction: .buy, price: 10.0, shares: 100,
            positionTier: .tier1, commission: 1.0, stampDuty: 0.0, totalCost: 1001.0,
            createdAt: 1_735_689_601)
        let dr = DrawingObject(toolType: .horizontal,
                               anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 9.5)],
                               isExtended: true, panelPosition: 0)
        _ = try db.insertRecord(rec, ops: [op], drawings: [dr])
        try db.savePending(Self.makePending())
        try db.saveSettings(AppSettings(commissionRate: 0.0003, minCommissionEnabled: true,
                                        totalCapital: 123_456, displayMode: .dark))
    }

    private static func makePending() -> PendingTraining {
        PendingTraining(
            trainingSetFilename: "t.sqlite", globalTickIndex: 12,
            upperPeriod: .daily, lowerPeriod: .m3, positionData: Data([0x00]),
            cashBalance: 50_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], drawings: [], startedAt: 1_735_689_600,
            accumulatedCapital: 123_456, drawdown: DrawdownAccumulator(peakCapital: 0, maxDrawdown: 0),
            sessionKey: "sess-1")
    }

    // 主用例：重置后三表清空 + capital=10 万；不需迁移（user_version 仍 2）。
    func test_resetAllTrainingProgress_wipes_records_pending_and_sets_capital() throws {
        try seedProgress()
        XCTAssertEqual(try db.statistics().totalCount, 1)        // 前置：确有记录
        XCTAssertNotNil(try db.loadPending())                    // 前置：确有 pending

        try db.resetAllTrainingProgress(toCapital: 100_000)

        XCTAssertEqual(try db.statistics().totalCount, 0)        // 记录清空
        XCTAssertNil(try db.loadPending())                       // pending 清空
        XCTAssertEqual(try db.loadSettings().totalCapital, 100_000)  // 资金回 10 万

        // 物理验证：子表无 FK 残留。
        let queue = try AppDBFixture.openRaw(at: dbURL)
        let counts: (Int, Int, Int) = try queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM trade_operations") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM drawings") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM training_records") ?? -1)
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
        let uv: Int = try queue.read { d in try Int.fetchOne(d, sql: "PRAGMA user_version") ?? -1 }
        XCTAssertEqual(uv, 2)   // 纯数据操作，无新迁移
    }

    // 幂等：空库重置也合法，只确保 capital。
    func test_resetAllTrainingProgress_on_empty_db_is_idempotent() throws {
        try db.resetAllTrainingProgress(toCapital: 100_000)
        XCTAssertEqual(try db.statistics().totalCount, 0)
        XCTAssertNil(try db.loadPending())
        XCTAssertEqual(try db.loadSettings().totalCapital, 100_000)
    }

    // 真原子回滚证明（Medium-9）：用同款 dbQueue.write 事务，deleteAll 之后人为抛错，
    // 断言记录/pending/capital 全保持原样——证 resetAllTrainingProgress 依赖的事务边界确实回滚。
    // db.dbQueue 为 internal（@testable 可见）；deleteAll 为 internal static。
    func test_dbQueue_transaction_rolls_back_deleteAll_on_later_failure() throws {
        try seedProgress()
        XCTAssertThrowsError(try db.dbQueue.write { d in
            try RecordRepositoryImpl.deleteAll(d)
            try PendingTrainingRepositoryImpl.clearPending(d)
            throw AppError.persistence(.ioError("injected mid-transaction failure"))
        })
        // 整体回滚：三者都未变。
        XCTAssertEqual(try db.statistics().totalCount, 1)
        XCTAssertNotNil(try db.loadPending())
        XCTAssertEqual(try db.loadSettings().totalCapital, 123_456)
    }

    // 验证 toCapital 参数确实被透传（用 ≠ 默认 10 万 的值），且重置后零记录使下一局走 settings 分支。
    // 注：仅验持久层；真协调器路径由 Task 5 验证。
    func test_resetAllTrainingProgress_threads_toCapital_param() throws {
        try seedProgress()
        try db.resetAllTrainingProgress(toCapital: 88_000)
        XCTAssertEqual(try db.statistics().totalCount, 0)
        XCTAssertEqual(try db.loadSettings().totalCapital, 88_000)   // 参数透传，非硬编码 100_000
    }

    // setTotalCapital 的 isFinite 守卫：传 NaN → 抛 internalError，且事务整体回滚（记录/pending 不被删）。
    func test_resetAllTrainingProgress_rejects_nonFinite_capital_and_rolls_back() throws {
        try seedProgress()
        XCTAssertThrowsError(try db.resetAllTrainingProgress(toCapital: .nan)) { err in
            guard let appErr = err as? AppError, case .internalError = appErr else {
                return XCTFail("期望 .internalError，实际 \(err)")
            }
        }
        // 整体回滚：守卫在 setTotalCapital（事务最后一步）抛错 → deleteAll/clearPending 一并回滚。
        XCTAssertEqual(try db.statistics().totalCount, 1)
        XCTAssertNotNil(try db.loadPending())
        XCTAssertEqual(try db.loadSettings().totalCapital, 123_456)
    }
}

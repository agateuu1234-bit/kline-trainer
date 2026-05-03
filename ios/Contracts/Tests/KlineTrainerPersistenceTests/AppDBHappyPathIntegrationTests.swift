import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence

/// 端到端 happy-path：模拟 E6 TrainingSessionCoordinator 完整 session 生命周期。
final class AppDBHappyPathIntegrationTests: XCTestCase {

    func test_full_session_lifecycle_save_pending_settle_to_record() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let db = try DefaultAppDB(dbPath: dbURL)

        // ① 首次启动：无 pending、无 records、settings 默认
        XCTAssertNil(try db.loadPending())
        XCTAssertEqual(try db.listRecords(limit: nil).count, 0)
        XCTAssertEqual(try db.statistics().totalCount, 0)
        XCTAssertEqual(try db.loadSettings().displayMode, .system)

        // ② 用户进设置
        try db.saveSettings(AppSettings(commissionRate: 0.0003, minCommissionEnabled: true,
                                        totalCapital: 10_000, displayMode: .dark))

        // ③ 进入训练 → save pending
        let pending = PendingTraining(
            trainingSetFilename: "set-A.zip",
            globalTickIndex: 0,
            upperPeriod: .daily, lowerPeriod: .m60,
            positionData: Data(),
            cashBalance: 10_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0003, minCommissionEnabled: true),
            tradeOperations: [],
            drawings: [],
            startedAt: 1_700_000_000_000,
            accumulatedCapital: 10_000,
            drawdown: .initial)
        try db.savePending(pending)

        // ④ session 结算 → 写 record + clear pending
        let record = TrainingRecord(
            id: nil, trainingSetFilename: "set-A.zip", createdAt: 1_700_000_000_000,
            stockCode: "000001", stockName: "平安银行", startYear: 2024, startMonth: 1,
            totalCapital: 10_000, profit: 500, returnRate: 0.05, maxDrawdown: 200,
            buyCount: 1, sellCount: 1,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0003, minCommissionEnabled: true),
            finalTick: 100)
        let recordId = try db.insertRecord(record, ops: [], drawings: [])
        try db.clearPending()

        XCTAssertNil(try db.loadPending())
        XCTAssertEqual(try db.listRecords(limit: nil).count, 1)

        // ⑤ statistics 反映 win
        let stats = try db.statistics()
        XCTAssertEqual(stats.totalCount, 1)
        XCTAssertEqual(stats.winCount, 1)
        XCTAssertEqual(stats.currentCapital, 10_500)

        // ⑥ AcceptanceJournal 模拟 P2 一组 lease 全链路
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .unzipped,
                      sqliteLocalPath: "/tmp/set.sqlite", contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .dbVerified,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                      sqliteLocalPath: nil, contentHash: "deadbeef", lastError: nil)
        XCTAssertEqual(try db.listByState(.stored).count, 1)
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .confirmPending,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .confirmed,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        XCTAssertEqual(try db.listByState(.confirmed).count, 1)
        try db.deleteByIdLease(trainingSetId: 1, leaseId: "L1")
        XCTAssertEqual(try db.listByState(.confirmed).count, 0)

        // ⑦ load record bundle 完整恢复
        let bundle = try db.loadRecordBundle(id: recordId)
        XCTAssertEqual(bundle.0.profit, 500)
        XCTAssertEqual(bundle.1.count, 0)
        XCTAssertEqual(bundle.2.count, 0)
    }
}

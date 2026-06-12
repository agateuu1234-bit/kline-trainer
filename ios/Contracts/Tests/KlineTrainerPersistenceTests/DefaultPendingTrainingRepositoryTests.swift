import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class DefaultPendingTrainingRepositoryTests: XCTestCase {

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

    // 用例 1：fresh DB loadPending 返回 nil
    func test_loadPending_on_fresh_db_returns_nil() throws {
        XCTAssertNil(try db.loadPending())
    }

    // 用例 2：savePending → loadPending roundtrip 字段对等
    func test_savePending_then_loadPending_roundtrip() throws {
        let pending = makePending(globalTickIndex: 100, cashBalance: 9_500, accumulatedCapital: 10_500)
        try db.savePending(pending)
        let loaded = try db.loadPending()
        XCTAssertEqual(loaded?.globalTickIndex, 100)
        XCTAssertEqual(loaded?.cashBalance, 9_500)
        XCTAssertEqual(loaded?.accumulatedCapital, 10_500)
        XCTAssertEqual(loaded?.upperPeriod, pending.upperPeriod)
        XCTAssertEqual(loaded?.lowerPeriod, pending.lowerPeriod)
        XCTAssertEqual(loaded?.tradeOperations.count, pending.tradeOperations.count)
        XCTAssertEqual(loaded?.drawings.count, pending.drawings.count)
        XCTAssertEqual(loaded?.drawdown, pending.drawdown)
        XCTAssertEqual(loaded?.positionData, pending.positionData)
    }

    // 用例 3：savePending 二次覆盖旧值（singleton row 替换语义）
    func test_savePending_overwrites_existing() throws {
        try db.savePending(makePending(globalTickIndex: 1))
        try db.savePending(makePending(globalTickIndex: 200))
        let loaded = try db.loadPending()
        XCTAssertEqual(loaded?.globalTickIndex, 200)

        // 物理验证：表只有 1 行
        let queue = try AppDBFixture.openRaw(at: dbURL)
        let count: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_training") ?? -1
        }
        XCTAssertEqual(count, 1)
    }

    // 用例 4：clearPending → loadPending 返回 nil
    func test_clearPending_then_loadPending_nil() throws {
        try db.savePending(makePending(globalTickIndex: 100))
        try db.clearPending()
        XCTAssertNil(try db.loadPending())
    }

    // 用例 5：clearPending fresh DB 不抛错
    func test_clearPending_on_fresh_db_no_throw() throws {
        XCTAssertNoThrow(try db.clearPending())
    }

    // 用例 6：sessionKey round-trip（session_key 列读写，RFC §4.7c）
    func test_savePending_roundTrips_sessionKey() throws {
        let pending = makePending(globalTickIndex: 1, sessionKey: "SK-roundtrip-1")
        try db.savePending(pending)
        let loaded = try db.loadPending()
        XCTAssertEqual(loaded?.sessionKey, "SK-roundtrip-1")
    }

    // MARK: - Helper

    private func makePending(globalTickIndex: Int = 0,
                             cashBalance: Double = 10_000,
                             accumulatedCapital: Double = 10_000,
                             sessionKey: String = "SK-default") -> PendingTraining {
        PendingTraining(
            trainingSetFilename: "set-A.zip",
            globalTickIndex: globalTickIndex,
            upperPeriod: .daily, lowerPeriod: .m60,
            positionData: Data([0x01, 0x02, 0x03]),
            cashBalance: cashBalance,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0003, minCommissionEnabled: true),
            tradeOperations: [
                TradeOperation(globalTick: 50, period: .daily, direction: .buy,
                               price: 10, shares: 100, positionTier: .tier1,
                               commission: 1, stampDuty: 0, totalCost: 1001,
                               createdAt: 1_700_000_000_000)
            ],
            drawings: [
                DrawingObject(toolType: .ray,
                              anchors: [DrawingAnchor(period: .daily, candleIndex: 1, price: 10)],
                              isExtended: false, panelPosition: 0)
            ],
            startedAt: 1_700_000_000_000,
            accumulatedCapital: accumulatedCapital,
            drawdown: DrawdownAccumulator(peakCapital: 11_000, maxDrawdown: 500),
            sessionKey: sessionKey
        )
    }
}

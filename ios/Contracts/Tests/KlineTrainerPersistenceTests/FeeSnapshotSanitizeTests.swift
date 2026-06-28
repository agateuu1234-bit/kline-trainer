import XCTest
import GRDB
import KlineTrainerContracts
@testable import KlineTrainerPersistence

// MARK: - FeeSnapshot.sanitizedForLegacyCorruption 单元测试（无 DB 依赖）

final class FeeSnapshotSanitizeUnitTests: XCTestCase {

    // 负 commissionRate → 替换为 AppSettings.default.commissionRate
    func test_negative_commissionRate_is_replaced_with_default() {
        let raw = FeeSnapshot(commissionRate: -0.001, minCommissionEnabled: true)
        let sanitized = raw.sanitizedForLegacyCorruption()
        XCTAssertEqual(sanitized.commissionRate, AppSettings.default.commissionRate)
        XCTAssertEqual(sanitized.minCommissionEnabled, true, "minCommissionEnabled 不应改变")
    }

    // 非有限 commissionRate（NaN）→ 替换为默认
    func test_nan_commissionRate_is_replaced_with_default() {
        let raw = FeeSnapshot(commissionRate: Double.nan, minCommissionEnabled: false)
        let sanitized = raw.sanitizedForLegacyCorruption()
        XCTAssertEqual(sanitized.commissionRate, AppSettings.default.commissionRate)
    }

    // 非有限 commissionRate（+Inf）→ 替换为默认
    func test_positive_infinity_commissionRate_is_replaced_with_default() {
        let raw = FeeSnapshot(commissionRate: Double.infinity, minCommissionEnabled: false)
        let sanitized = raw.sanitizedForLegacyCorruption()
        XCTAssertEqual(sanitized.commissionRate, AppSettings.default.commissionRate)
    }

    // 合法 commissionRate（0.0003）→ 原样返回
    func test_valid_commissionRate_is_unchanged() {
        let raw = FeeSnapshot(commissionRate: 0.0003, minCommissionEnabled: true)
        let sanitized = raw.sanitizedForLegacyCorruption()
        XCTAssertEqual(sanitized.commissionRate, 0.0003)
        XCTAssertEqual(sanitized.minCommissionEnabled, true)
    }

    // 零 commissionRate（合法边界）→ 原样返回
    func test_zero_commissionRate_is_valid_and_unchanged() {
        let raw = FeeSnapshot(commissionRate: 0.0, minCommissionEnabled: false)
        let sanitized = raw.sanitizedForLegacyCorruption()
        XCTAssertEqual(sanitized.commissionRate, 0.0)
    }
}

// MARK: - 解码边界集成测试（via DefaultAppDB）

final class FeeSnapshotSanitizePersistenceTests: XCTestCase {

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

    // WB-1 pending：直写负 commissionRate → loadPending 返回 default
    func test_loadPending_sanitizes_negative_commissionRate() throws {
        // 绕过 savePending（它会用合法值），直写 raw JSON 进库
        let corruptFeeJSON = #"{"commissionRate":-0.99,"minCommissionEnabled":true}"#
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { rawDB in
            try rawDB.execute(sql: """
                INSERT OR REPLACE INTO pending_training
                  (id, training_set_filename, global_tick_index, upper_period, lower_period,
                   position_data, fee_snapshot, trade_operations, drawings,
                   started_at, accumulated_capital, cash_balance, drawdown, session_key)
                VALUES (1, 'set-A.zip', 10, 'daily', '60m',
                        'AQID', ?, '[]', '[]',
                        1700000000000, 10000, 10000,
                        '{"peakCapital":10000,"maxDrawdown":0}',
                        'SK-corrupt-pending')
                """, arguments: [corruptFeeJSON])
        }

        let loaded = try db.loadPending()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(
            loaded?.feeSnapshot.commissionRate,
            AppSettings.default.commissionRate,
            "负 commissionRate 应被 sanitize 为默认值"
        )
        XCTAssertEqual(loaded?.feeSnapshot.minCommissionEnabled, true,
                       "minCommissionEnabled 不应改变")
    }

    // WB-1 record：直写负 commissionRate → loadRecordBundle 返回 default
    func test_loadRecordBundle_sanitizes_negative_commissionRate() throws {
        let corruptFeeJSON = #"{"commissionRate":-5.0,"minCommissionEnabled":false}"#
        let queue = try AppDBFixture.openRaw(at: dbURL)
        var insertedID: Int64 = 0
        try queue.write { rawDB in
            try rawDB.execute(sql: """
                INSERT INTO training_records
                  (training_set_filename, created_at, stock_code, stock_name,
                   start_year, start_month, total_capital, profit, return_rate,
                   max_drawdown, buy_count, sell_count, fee_snapshot, final_tick, session_key)
                VALUES ('set-A.zip', 1700000000000, '000001', '平安银行',
                        2024, 1, 10000, 100, 0.01, 50, 1, 1, ?, 99, 'SK-corrupt-record')
                """, arguments: [corruptFeeJSON])
            insertedID = rawDB.lastInsertedRowID
        }

        let bundle = try db.loadRecordBundle(id: insertedID)
        XCTAssertEqual(
            bundle.0.feeSnapshot.commissionRate,
            AppSettings.default.commissionRate,
            "负 commissionRate 应被 sanitize 为默认值"
        )
        XCTAssertEqual(bundle.0.feeSnapshot.minCommissionEnabled, false,
                       "minCommissionEnabled 不应改变")
    }
}

import XCTest
@preconcurrency import GRDB
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class DefaultTrainingSetReaderTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups.removeAll()
        super.tearDown()
    }

    // MARK: - loadAllCandles

    func test_loadAllCandles_groupsByPeriod() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(1_000, 0, 0), (1_180, 1, 1), (1_360, 2, 2)]),
            (.daily, [(1_000, nil, 2)]),
        ]
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)

        let candles = try reader.loadAllCandles()

        XCTAssertEqual(candles.keys.count, 2)
        XCTAssertEqual(candles[.m3]?.count, 3)
        XCTAssertEqual(candles[.daily]?.count, 1)
        XCTAssertEqual(candles[.m3]?[0].datetime, 1_000)
        XCTAssertEqual(candles[.m3]?[0].globalIndex, 0)
        XCTAssertEqual(candles[.m3]?[0].endGlobalIndex, 0)
        XCTAssertEqual(candles[.daily]?[0].globalIndex, nil)
        XCTAssertEqual(candles[.daily]?[0].endGlobalIndex, 2)

        reader.close()
    }

    func test_loadAllCandles_unknownPeriodRawValue_throwsDbCorrupted() throws {
        let (url, cleanup) = try TrainingSetSQLiteFixture.make()
        cleanups.append(cleanup)

        // 注入坏 row：用 do-block 强制 ARC 释放 write queue，再 factory open
        do {
            let writeQueue = try GRDB.DatabaseQueue(path: url.path)
            try writeQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO klines (period, datetime, open, high, low, close, volume, end_global_index)
                    VALUES ('not_a_period', 999, 1.0, 2.0, 0.5, 1.5, 100, 99)
                    """)
            }
        }  // writeQueue 出作用域，ARC 释放

        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)

        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }

    func test_close_thenLoadMeta_throwsInternalError() throws {
        let (url, cleanup) = try TrainingSetSQLiteFixture.make()
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        reader.close()

        XCTAssertThrowsError(try reader.loadMeta()) { err in
            guard case AppError.internalError(let module, let detail) = err else {
                return XCTFail("Expected .internalError, got \(err)")
            }
            XCTAssertEqual(module, "P3b")
            XCTAssertEqual(detail, "reader closed")
        }
    }

    func test_close_isIdempotent() throws {
        let (url, cleanup) = try TrainingSetSQLiteFixture.make()
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        reader.close()
        reader.close()  // 再次 close 不抛
        XCTAssertTrue(true, "close() called twice without crash")
    }

    func test_close_thenLoadAllCandles_throwsInternalError() throws {
        let (url, cleanup) = try TrainingSetSQLiteFixture.make()
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        reader.close()

        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.internalError(let module, _) = err else {
                return XCTFail("Expected .internalError, got \(err)")
            }
            XCTAssertEqual(module, "P3b")
        }
    }
}

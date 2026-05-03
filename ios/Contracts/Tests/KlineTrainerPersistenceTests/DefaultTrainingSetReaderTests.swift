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

    // MARK: - corrupt row data（codex round 1 HIGH-2 加测）

    /// 列类型 mismatch（SQLite manifest typing 允许 INTEGER 列存 TEXT 字串）→ .dbCorrupted
    func test_loadAllCandles_wrongTypeInColumn_throwsDbCorrupted() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.skipKlinesTable = true
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        do {
            let writeQueue = try GRDB.DatabaseQueue(path: url.path)
            try writeQueue.write { db in
                // schema 不带 NOT NULL，模拟数据 corruption / 旧 schema
                try db.execute(sql: """
                CREATE TABLE klines (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    period TEXT, datetime INTEGER,
                    open REAL, high REAL, low REAL, close REAL,
                    volume INTEGER,
                    amount REAL, ma66 REAL,
                    boll_upper REAL, boll_mid REAL, boll_lower REAL,
                    macd_diff REAL, macd_dea REAL, macd_bar REAL,
                    global_index INTEGER, end_global_index INTEGER
                )
                """)
                // datetime 列存 TEXT 字串（SQLite manifest typing 允许）
                try db.execute(sql: """
                    INSERT INTO klines (period, datetime, open, high, low, close, volume, end_global_index)
                    VALUES ('m3', 'not_a_timestamp', 1.0, 2.0, 0.5, 1.5, 100, 0)
                    """)
            }
        }

        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }

    /// NULL 出现在 NOT NULL 语义列（KLineCandle.datetime 是 Int64）→ .dbCorrupted
    func test_loadAllCandles_nullInRequiredColumn_throwsDbCorrupted() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.skipKlinesTable = true
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        do {
            let writeQueue = try GRDB.DatabaseQueue(path: url.path)
            try writeQueue.write { db in
                try db.execute(sql: """
                CREATE TABLE klines (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    period TEXT, datetime INTEGER,
                    open REAL, high REAL, low REAL, close REAL,
                    volume INTEGER,
                    amount REAL, ma66 REAL,
                    boll_upper REAL, boll_mid REAL, boll_lower REAL,
                    macd_diff REAL, macd_dea REAL, macd_bar REAL,
                    global_index INTEGER, end_global_index INTEGER
                )
                """)
                // volume 列 NULL（KLineCandle.volume: Int64 是 NOT NULL 语义）
                try db.execute(sql: """
                    INSERT INTO klines (period, datetime, open, high, low, close, volume, end_global_index)
                    VALUES ('m3', 1000, 1.0, 2.0, 0.5, 1.5, NULL, 0)
                    """)
            }
        }

        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }

    // MARK: - endGlobalIndex 单调性校验（codex round 2 HIGH-2）

    /// duplicate end_global_index（同 period 内重复值）→ .dbCorrupted
    func test_loadAllCandles_duplicateEndGlobalIndexInPeriod_throwsDbCorrupted() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(1_000, 0, 0), (1_180, 1, 1), (1_360, 2, 1)]),  // endGIdx 1 重复
        ]
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)

        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }

    /// non-increasing end_global_index（同 period 内倒序）→ .dbCorrupted
    /// SQL ORDER BY 已按 end_global_index 升序，要构造 non-increasing 必须有重复或 NULL；
    /// 这里用 NULL 末位+先递增后 NULL 的边界（NULL 在 SQLite ORDER BY ASC 排首位）。
    /// 实际测试同 period 内出现两个值 ASC 后，第二个 SELECT 顺位反而 ≤ 前者只有 duplicate；
    /// 这个 test 用跨 period 边界（不同 period 间不校验）+ 同 period duplicate 双重覆盖。
    func test_loadAllCandles_nonStrictlyIncreasingAcrossSamePeriod_throwsDbCorrupted() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(1_000, 0, 5), (1_180, 1, 5)]),  // 两条 endGIdx 都是 5（duplicate）
            (.daily, [(1_000, nil, 1)]),
        ]
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)

        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }

    // MARK: - .m3 globalIndex contract（codex round 3 HIGH-1）

    /// .m3 行 globalIndex 为 nil → .dbCorrupted
    /// (spec: smallest-period global_index 是全局 tick 轴，必须非 nil)
    func test_loadAllCandles_m3GlobalIndexNil_throwsDbCorrupted() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(1_000, nil, 0), (1_180, nil, 1)]),
            (.daily, [(1_000, nil, 1)]),
        ]
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)

        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }

    /// .m3 globalIndex != endGlobalIndex（同一根 K 线起止索引应相等）→ .dbCorrupted
    func test_loadAllCandles_m3GlobalIndexMismatchEndGlobalIndex_throwsDbCorrupted() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(1_000, 0, 0), (1_180, 7, 1)]),  // 第二根 globalIndex=7 ≠ endGlobalIndex=1
            (.daily, [(1_000, nil, 1)]),
        ]
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)

        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }

    /// 高周期 endGlobalIndex 超出 m3 范围（不存在对应 m3 tick）→ .dbCorrupted
    func test_loadAllCandles_higherPeriodEndGlobalIndexOutOfRange_throwsDbCorrupted() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(1_000, 0, 0), (1_180, 1, 1)]),  // m3Max = 1
            (.daily, [(1_000, nil, 99)]),           // 99 > 1
        ]
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)

        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }

    // MARK: - klines numeric typeof + m3 missing fallthrough（codex round 4 HIGH-1 + MEDIUM）

    /// klines numeric 列存 TEXT 字串 → SQL typeof() 校验拦截 → .dbCorrupted
    /// （绕过 GRDB Decodable silent coerce-to-0/0.0；测试用非 m3 行确保不被 m3 contract 短路覆盖）
    func test_loadAllCandles_klinesWrongTypeInNumericColumn_throwsDbCorrupted() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.skipKlinesTable = true
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        do {
            let writeQueue = try GRDB.DatabaseQueue(path: url.path)
            try writeQueue.write { db in
                try db.execute(sql: """
                CREATE TABLE klines (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    period TEXT NOT NULL, datetime INTEGER NOT NULL,
                    open REAL NOT NULL, high REAL NOT NULL, low REAL NOT NULL, close REAL NOT NULL,
                    volume INTEGER NOT NULL,
                    amount REAL, ma66 REAL,
                    boll_upper REAL, boll_mid REAL, boll_lower REAL,
                    macd_diff REAL, macd_dea REAL, macd_bar REAL,
                    global_index INTEGER, end_global_index INTEGER NOT NULL
                )
                """)
                // 先插一条合法 m3 锚点（保证 m3 contract pass，不被短路）
                try db.execute(sql: """
                    INSERT INTO klines (period, datetime, open, high, low, close, volume, global_index, end_global_index)
                    VALUES ('3m', 1000, 1.0, 2.0, 0.5, 1.5, 100, 0, 0)
                    """)
                // daily 行 datetime 列存 TEXT 字串 → typeof = 'text' ≠ 'integer'/'null'
                try db.execute(sql: """
                    INSERT INTO klines (period, datetime, open, high, low, close, volume, end_global_index)
                    VALUES ('daily', 'not_a_timestamp', 1.0, 2.0, 0.5, 1.5, 100, 0)
                    """)
            }
        }

        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }

    /// m3 missing 但高周期数据存在 → 缺 global tick 轴锚点 → .dbCorrupted
    func test_loadAllCandles_m3MissingButHigherPeriodPresent_throwsDbCorrupted() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.daily, [(1_000, nil, 0)]),  // 仅 daily，无 m3
        ]
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)

        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }

    /// klines 表为空 → 返回空字典（plan §4 设计决策：caller 处理）
    func test_loadAllCandles_emptyKlinesTable_returnsEmptyDict() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = []  // 完全无数据
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)

        let candles = try reader.loadAllCandles()
        XCTAssertTrue(candles.isEmpty, "Expected empty dict for empty klines table")
        reader.close()
    }
}

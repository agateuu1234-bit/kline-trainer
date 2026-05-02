import XCTest
@preconcurrency import GRDB
@testable import KlineTrainerPersistence

final class TrainingSetSQLiteFixtureTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups.removeAll()
        super.tearDown()
    }

    func test_makeDefault_producesReadableSQLite() throws {
        let (url, cleanup) = try TrainingSetSQLiteFixture.make()
        cleanups.append(cleanup)

        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try queue.read { db in
            let userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1
            XCTAssertEqual(userVersion, 1)
            let metaCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meta") ?? -1
            XCTAssertEqual(metaCount, 1)
            let klineCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM klines") ?? -1
            XCTAssertEqual(klineCount, 3)  // 2 m3 + 1 daily
        }
    }

    func test_makeWithCustomVersion_appliedCorrectly() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.userVersion = 99
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        let queue = try DatabaseQueue(path: url.path)
        try queue.read { db in
            let userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1
            XCTAssertEqual(userVersion, 99)
        }
    }

    func test_makeSkipMetaTable_omitsTable() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.skipMetaTable = true
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        let queue = try DatabaseQueue(path: url.path)
        try queue.read { db in
            // 用 Int 不用 Bool，避免 GRDB BoolfromSQLite-INT 转换 edge case。
            let count = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='meta'") ?? -1
            XCTAssertEqual(count, 0)
        }
    }
}

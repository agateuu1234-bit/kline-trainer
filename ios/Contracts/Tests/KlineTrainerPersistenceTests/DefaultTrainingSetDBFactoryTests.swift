import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class DefaultTrainingSetDBFactoryTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups.removeAll()
        super.tearDown()
    }

    // MARK: - versionMismatch

    func test_openAndVerify_userVersionMismatch_throwsVersionMismatch() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.userVersion = 2
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        let factory = DefaultTrainingSetDBFactory()

        XCTAssertThrowsError(try factory.openAndVerify(file: url, expectedSchemaVersion: 1)) { err in
            guard case AppError.trainingSet(.versionMismatch(expected: 1, got: 2)) = err else {
                return XCTFail("Expected .trainingSet(.versionMismatch(1, 2)), got \(err)")
            }
        }
    }

    // MARK: - fileNotFound

    func test_openAndVerify_missingFile_throwsFileNotFound() {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).sqlite")

        let factory = DefaultTrainingSetDBFactory()

        XCTAssertThrowsError(try factory.openAndVerify(file: nonexistent, expectedSchemaVersion: 1)) { err in
            guard case AppError.trainingSet(.fileNotFound) = err else {
                return XCTFail("Expected .trainingSet(.fileNotFound), got \(err)")
            }
        }
    }

    // MARK: - emptyData

    func test_openAndVerify_emptyMetaTable_throwsEmptyData() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.meta = nil  // meta 表存在但 0 行
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        let factory = DefaultTrainingSetDBFactory()

        XCTAssertThrowsError(try factory.openAndVerify(file: url, expectedSchemaVersion: 1)) { err in
            guard case AppError.trainingSet(.emptyData) = err else {
                return XCTFail("Expected .trainingSet(.emptyData), got \(err)")
            }
        }
    }

    // MARK: - happy path

    func test_openAndVerify_validFile_returnsReaderWithMeta() throws {
        let (url, cleanup) = try TrainingSetSQLiteFixture.make()
        cleanups.append(cleanup)
        let factory = DefaultTrainingSetDBFactory()

        let reader = try factory.openAndVerify(file: url, expectedSchemaVersion: 1)
        let meta = try reader.loadMeta()

        XCTAssertEqual(meta.stockCode, "600001")
        XCTAssertEqual(meta.stockName, "测试股票")
        XCTAssertEqual(meta.startDatetime, 1_700_000_000)
        XCTAssertEqual(meta.endDatetime, 1_700_086_400)

        reader.close()
    }

    // MARK: - corrupt (missing meta table)

    func test_openAndVerify_missingMetaTable_throwsIoError() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.skipMetaTable = true
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        let factory = DefaultTrainingSetDBFactory()

        XCTAssertThrowsError(try factory.openAndVerify(file: url, expectedSchemaVersion: 1)) { err in
            // SQLite "no such table: meta" → DatabaseError.SQLITE_ERROR → .persistence(.ioError("sqlite_error_<code>"))
            // 精确 assert（不松绑 case AppError.persistence | .trainingSet）
            guard case AppError.persistence(.ioError(let token)) = err else {
                return XCTFail("Expected .persistence(.ioError), got \(err)")
            }
            XCTAssertTrue(token.hasPrefix("sqlite_error_"),
                          "Expected sanitized token sqlite_error_<code>, got \(token)")
        }
    }

    func test_openAndVerify_notSqliteFile_throwsDbCorrupted() throws {
        let perCallDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kline_trainer_persistence_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: perCallDir, withIntermediateDirectories: true)
        let url = perCallDir.appendingPathComponent("not_sqlite.sqlite")
        try "this is not sqlite".data(using: .utf8)!.write(to: url)
        cleanups.append { try? FileManager.default.removeItem(at: perCallDir) }

        let factory = DefaultTrainingSetDBFactory()

        XCTAssertThrowsError(try factory.openAndVerify(file: url, expectedSchemaVersion: 1)) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
    }
}

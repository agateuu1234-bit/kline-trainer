import XCTest
@testable import KlineTrainerContracts

#if DEBUG
final class P2FakesTests: XCTestCase {

    // MARK: - FakeZipIntegrityVerifier

    func test_zipIntegrity_default_init_does_not_throw() throws {
        let f = FakeZipIntegrityVerifier()
        XCTAssertNoThrow(try f.verify(zipURL: URL(fileURLWithPath: "/tmp/x.zip"),
                                      expectedCRC32Hex: "deadbeef"))
    }

    func test_zipIntegrity_throwing_init_throws_given_error() {
        let f = FakeZipIntegrityVerifier(throwing: .trainingSet(.crcFailed))
        XCTAssertThrowsError(try f.verify(zipURL: URL(fileURLWithPath: "/tmp/x.zip"),
                                          expectedCRC32Hex: "deadbeef")) { err in
            XCTAssertEqual(err as? AppError, .trainingSet(.crcFailed))
        }
    }

    // MARK: - FakeZipExtractor

    func test_zipExtractor_default_init_returns_default_url() throws {
        let f = FakeZipExtractor()
        let out = try f.extract(zipURL: URL(fileURLWithPath: "/tmp/x.zip"))
        XCTAssertEqual(out, URL(fileURLWithPath: "/tmp/fake.sqlite"))
    }

    func test_zipExtractor_custom_returnURL() throws {
        let custom = URL(fileURLWithPath: "/tmp/custom.sqlite")
        let f = FakeZipExtractor(returnURL: custom)
        XCTAssertEqual(try f.extract(zipURL: URL(fileURLWithPath: "/tmp/x.zip")), custom)
    }

    func test_zipExtractor_throwing_init_throws_given_error() {
        let f = FakeZipExtractor(throwing: .trainingSet(.unzipFailed))
        XCTAssertThrowsError(try f.extract(zipURL: URL(fileURLWithPath: "/tmp/x.zip"))) { err in
            XCTAssertEqual(err as? AppError, .trainingSet(.unzipFailed))
        }
    }

    // MARK: - FakeTrainingSetDataVerifier

    func test_dataVerifier_default_init_does_not_throw() throws {
        let f = FakeTrainingSetDataVerifier()
        let reader = StubReader()
        XCTAssertNoThrow(try f.verifyNonEmpty(reader: reader))
    }

    func test_dataVerifier_throwing_init_throws_given_error() {
        let f = FakeTrainingSetDataVerifier(throwing: .trainingSet(.emptyData))
        XCTAssertThrowsError(try f.verifyNonEmpty(reader: StubReader())) { err in
            XCTAssertEqual(err as? AppError, .trainingSet(.emptyData))
        }
    }

    // MARK: - FakeDownloadAcceptanceCleaner

    func test_cleaner_records_calls_in_order() {
        let c = FakeDownloadAcceptanceCleaner()
        let u1 = URL(fileURLWithPath: "/tmp/a")
        let u2 = URL(fileURLWithPath: "/tmp/b")
        let u3 = URL(fileURLWithPath: "/tmp/c")
        c.cleanup(tempURLs: [u1, u2])
        c.cleanup(tempURLs: [u3])
        XCTAssertEqual(c.cleanedURLs(), [u1, u2, u3])
    }

    func test_cleaner_empty_input_no_op() {
        let c = FakeDownloadAcceptanceCleaner()
        c.cleanup(tempURLs: [])
        XCTAssertTrue(c.cleanedURLs().isEmpty)
    }

    func test_cleaner_concurrent_records_all() {
        let c = FakeDownloadAcceptanceCleaner()
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)
        for i in 1...20 {
            group.enter()
            q.async {
                c.cleanup(tempURLs: [URL(fileURLWithPath: "/tmp/u\(i)")])
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(c.cleanedURLs().count, 20)
    }

    // MARK: - 辅助 stub reader（fake 不需要真 reader 内容）

    private final class StubReader: TrainingSetReader, @unchecked Sendable {
        func loadMeta() throws -> TrainingSetMeta {
            // 满足 production sanity（mirror PR5a §3 R4 修订占位）
            TrainingSetMeta(stockCode: "PREVIEW", stockName: "Preview Stock",
                            startDatetime: 1, endDatetime: 1)
        }
        func loadAllCandles() throws -> [Period: [KLineCandle]] { [:] }
        func close() {}
    }
}
#endif

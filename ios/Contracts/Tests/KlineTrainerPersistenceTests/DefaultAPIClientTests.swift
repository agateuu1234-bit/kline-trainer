import XCTest
@testable import KlineTrainerPersistence
import KlineTrainerContracts

final class DefaultAPIClientTests: XCTestCase {
    private let base = URL(string: "http://nas.local:8000")!
    private let validLease = "6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d"  // openapi format=uuid

    private func client(_ stub: FakeHTTPTransport.Stub) -> (DefaultAPIClient, FakeHTTPTransport) {
        let fake = FakeHTTPTransport(stub: stub)
        return (DefaultAPIClient(baseURL: base, transport: fake), fake)
    }

    // MARK: reserveTrainingSets

    func test_reserve_full_decodes_lease_response() async throws {
        let body = try ContractFixtures.data("lease_response_full")
        let (api, fake) = client(.init(body: body, statusCode: 200))
        let lease = try await api.reserveTrainingSets(count: 2)
        XCTAssertEqual(lease.sets.count, 2)
        XCTAssertEqual(lease.sets[0].stockCode, "600519")
        XCTAssertEqual(lease.sets[0].contentHash, "deadbeef")
        let req = fake.capturedRequests.first!
        XCTAssertEqual(req.url?.path(), "/training-sets/meta")
        XCTAssertTrue(req.url?.query()?.contains("count=2") == true)
    }

    func test_reserve_empty_returns_empty_sets_no_throw() async throws {
        let body = try ContractFixtures.data("lease_response_empty")
        let (api, _) = client(.init(body: body, statusCode: 200))
        let lease = try await api.reserveTrainingSets(count: 5)
        XCTAssertEqual(lease.sets.count, 0)
    }

    func test_reserve_partial_returns_fewer_than_requested() async throws {
        let body = try ContractFixtures.data("lease_response_partial")
        let (api, _) = client(.init(body: body, statusCode: 200))
        let lease = try await api.reserveTrainingSets(count: 3)
        XCTAssertEqual(lease.sets.count, 1)
    }

    func test_reserve_invalid_count_throws_without_issuing_request() async {
        for bad in [0, -1, 101] {
            let (api, fake) = client(.init(body: Data(), statusCode: 200))
            do {
                _ = try await api.reserveTrainingSets(count: bad)
                XCTFail("count=\(bad) should throw")
            } catch let err as AppError {
                guard case .internalError(let module, _) = err else {
                    return XCTFail("count=\(bad): expected internalError, got \(err)")
                }
                XCTAssertEqual(module, "P1")
            } catch { XCTFail("count=\(bad): non-AppError: \(error)") }
            XCTAssertTrue(fake.capturedRequests.isEmpty, "count=\(bad) must not issue side-effecting reserve")
        }
    }

    func test_reserve_overfull_response_throws_internalError() async {
        let body = try! ContractFixtures.data("lease_response_full")  // 2 sets
        let (api, _) = client(.init(body: body, statusCode: 200))
        do {
            _ = try await api.reserveTrainingSets(count: 1)
            XCTFail("overfull response should throw")
        } catch let err as AppError {
            guard case .internalError(let module, _) = err else {
                return XCTFail("expected internalError, got \(err)")
            }
            XCTAssertEqual(module, "P1")
        } catch { XCTFail("non-AppError: \(error)") }
    }

    func test_reserve_malformed_body_throws_internalError_p1() async {
        let (api, _) = client(.init(body: Data("{not json".utf8), statusCode: 200))
        do {
            _ = try await api.reserveTrainingSets(count: 1)
            XCTFail("expected throw")
        } catch let err as AppError {
            guard case .internalError(let module, _) = err else {
                return XCTFail("expected internalError, got \(err)")
            }
            XCTAssertEqual(module, "P1")
        } catch { XCTFail("non-AppError: \(error)") }
    }

    func test_reserve_http_500_throws_serverError() async {
        let (api, _) = client(.init(body: Data(), statusCode: 500))
        await assertThrowsAppError(.network(.serverError(code: 500))) {
            _ = try await api.reserveTrainingSets(count: 1)
        }
    }

    func test_reserve_timeout_throws_network_timeout() async {
        let (api, _) = client(.init(error: URLError(.timedOut)))
        await assertThrowsAppError(.network(.timeout)) {
            _ = try await api.reserveTrainingSets(count: 1)
        }
    }

    func test_reserve_offline_throws_network_offline() async {
        let (api, _) = client(.init(error: URLError(.notConnectedToInternet)))
        await assertThrowsAppError(.network(.offline)) {
            _ = try await api.reserveTrainingSets(count: 1)
        }
    }

    func test_reserve_non_http_response_throws_internalError() async {
        let body = try! ContractFixtures.data("lease_response_full")
        let (api, _) = client(.init(body: body, statusCode: 200, returnNonHTTPResponse: true))
        do {
            _ = try await api.reserveTrainingSets(count: 1)
            XCTFail("expected throw")
        } catch let err as AppError {
            guard case .internalError = err else { return XCTFail("expected internalError, got \(err)") }
        } catch { XCTFail("non-AppError: \(error)") }
    }

    // MARK: confirmTrainingSet

    func test_confirm_200_succeeds_and_builds_url() async throws {
        let (api, fake) = client(.init(body: try ContractFixtures.data("confirm_ok"), statusCode: 200))
        try await api.confirmTrainingSet(id: 42, leaseId: validLease)
        let req = fake.capturedRequests.first!
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path(), "/training-set/42/confirm")
        XCTAssertTrue(req.url?.query()?.contains("lease_id=\(validLease)") == true)
    }

    func test_confirm_idempotent_repeat_200() async throws {
        let (api, _) = client(.init(body: try ContractFixtures.data("confirm_ok"), statusCode: 200))
        try await api.confirmTrainingSet(id: 1, leaseId: validLease)
        try await api.confirmTrainingSet(id: 1, leaseId: validLease)
    }

    func test_confirm_invalid_lease_id_throws_without_request() async {
        let (api, fake) = client(.init(body: Data(), statusCode: 200))
        do {
            try await api.confirmTrainingSet(id: 1, leaseId: "not-a-uuid")
            XCTFail("invalid leaseId should throw")
        } catch let err as AppError {
            guard case .internalError(let module, _) = err else {
                return XCTFail("expected internalError, got \(err)")
            }
            XCTAssertEqual(module, "P1")
        } catch { XCTFail("non-AppError: \(error)") }
        XCTAssertTrue(fake.capturedRequests.isEmpty, "invalid leaseId must not issue confirm")
    }

    func test_confirm_200_malformed_body_throws_decode_failed() async {
        let (api, fake) = client(.init(body: Data("{not json".utf8), statusCode: 200))
        do {
            try await api.confirmTrainingSet(id: 1, leaseId: validLease)
            XCTFail("malformed 200 body should throw")
        } catch let err as AppError {
            guard case .internalError(let module, let detail) = err else {
                return XCTFail("expected internalError, got \(err)")
            }
            XCTAssertEqual(module, "P1")
            XCTAssertEqual(detail, "confirm_decode_failed")
        } catch { XCTFail("non-AppError: \(error)") }
        XCTAssertEqual(fake.capturedRequests.count, 1)
    }

    func test_confirm_200_ok_false_throws_not_ok() async {
        let (api, fake) = client(.init(body: Data(#"{"ok":false}"#.utf8), statusCode: 200))
        do {
            try await api.confirmTrainingSet(id: 1, leaseId: validLease)
            XCTFail("{ok:false} should throw")
        } catch let err as AppError {
            guard case .internalError(let module, let detail) = err else {
                return XCTFail("expected internalError, got \(err)")
            }
            XCTAssertEqual(module, "P1")
            XCTAssertEqual(detail, "confirm_not_ok")
        } catch { XCTFail("non-AppError: \(error)") }
        XCTAssertEqual(fake.capturedRequests.count, 1)
    }

    func test_confirm_409_throws_leaseExpired() async {
        let (api, _) = client(.init(body: try! ContractFixtures.data("error_lease_expired"), statusCode: 409))
        await assertThrowsAppError(.network(.leaseExpired)) {
            try await api.confirmTrainingSet(id: 1, leaseId: validLease)
        }
    }

    func test_confirm_404_throws_leaseNotFound() async {
        let (api, _) = client(.init(body: try! ContractFixtures.data("error_not_found"), statusCode: 404))
        await assertThrowsAppError(.network(.leaseNotFound)) {
            try await api.confirmTrainingSet(id: 1, leaseId: validLease)
        }
    }

    func test_confirm_500_throws_serverError() async {
        let (api, _) = client(.init(body: Data(), statusCode: 500))
        await assertThrowsAppError(.network(.serverError(code: 500))) {
            try await api.confirmTrainingSet(id: 1, leaseId: validLease)
        }
    }

    // codex branch-diff F2：非预期 4xx = terminal（不可重试）。
    func test_reserve_http_400_throws_terminal_internalError() async {
        let (api, _) = client(.init(body: Data(), statusCode: 400))
        await assertInternalErrorP1(detail: "http_400") {
            _ = try await api.reserveTrainingSets(count: 1)
        }
        XCTAssertFalse(AppError.internalError(module: "P1", detail: "http_400").isRecoverable)
    }

    func test_confirm_403_throws_terminal_internalError() async {
        let (api, _) = client(.init(body: Data(), statusCode: 403))
        await assertInternalErrorP1(detail: "http_403") {
            try await api.confirmTrainingSet(id: 1, leaseId: validLease)
        }
    }

    // MARK: downloadTrainingSet

    func test_download_200_returns_file_with_contents() async throws {
        let payload = Data("PK\u{03}\u{04}fakezip".utf8)
        let (api, fake) = client(.init(statusCode: 200, downloadFileContents: payload))
        let url = try await api.downloadTrainingSet(id: 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(fake.capturedRequests.first?.url?.path(), "/training-set/7/download")
        try? FileManager.default.removeItem(at: url)
    }

    func test_download_404_throws_fileNotFound_terminal() async {
        let (api, _) = client(.init(statusCode: 404))
        await assertThrowsAppError(.trainingSet(.fileNotFound)) {
            _ = try await api.downloadTrainingSet(id: 7)
        }
        XCTAssertFalse(AppError.trainingSet(.fileNotFound).isRecoverable)
    }

    func test_download_500_throws_serverError() async {
        let (api, _) = client(.init(statusCode: 500))
        await assertThrowsAppError(.network(.serverError(code: 500))) {
            _ = try await api.downloadTrainingSet(id: 7)
        }
    }

    func test_download_offline_throws_network_offline() async {
        let (api, _) = client(.init(error: URLError(.networkConnectionLost)))
        await assertThrowsAppError(.network(.offline)) {
            _ = try await api.downloadTrainingSet(id: 7)
        }
    }

    func test_download_non200_cleans_temp_file() async {
        let (api, fake) = client(.init(statusCode: 500, downloadFileContents: Data("garbage".utf8)))
        do {
            _ = try await api.downloadTrainingSet(id: 7)
            XCTFail("500 download should throw")
        } catch { /* 预期抛错；类型不重要，此处只验证临时文件清理 */ }
        let temp = fake.lastDownloadTempURL
        XCTAssertNotNil(temp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp!.path), "temp file must be cleaned on failure")
    }

    // MARK: cancellation

    func test_reserve_cancellationError_rethrows_as_cancellation() async {
        let (api, _) = client(.init(error: CancellationError()))
        do {
            _ = try await api.reserveTrainingSets(count: 1)
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch { XCTFail("expected CancellationError, got \(error)") }
    }

    func test_download_urlerror_cancelled_rethrows_as_cancellation() async {
        let (api, fake) = client(.init(error: URLError(.cancelled)))
        do {
            _ = try await api.downloadTrainingSet(id: 7)
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch { XCTFail("expected CancellationError, got \(error)") }
        XCTAssertNil(fake.lastDownloadTempURL, "cancel before file write → 无临时文件")
    }

    // MARK: meta 字段契约校验

    func test_reserve_invalid_lease_id_in_meta_throws() async {
        let bad = #"{"lease_id":"not-a-uuid","expires_at":"2026-05-22T12:00:00Z","sets":[]}"#
        let (api, _) = client(.init(body: Data(bad.utf8), statusCode: 200))
        await assertInternalErrorP1(detail: "meta_invalid_lease_id") {
            _ = try await api.reserveTrainingSets(count: 1)
        }
    }

    func test_reserve_invalid_expires_at_throws() async {
        let bad = #"{"lease_id":"6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d","expires_at":"not-a-date","sets":[]}"#
        let (api, _) = client(.init(body: Data(bad.utf8), statusCode: 200))
        await assertInternalErrorP1(detail: "meta_invalid_expires_at") {
            _ = try await api.reserveTrainingSets(count: 1)
        }
    }

    func test_reserve_invalid_content_hash_throws() async {
        let bad = #"""
        {"lease_id":"6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d","expires_at":"2026-05-22T12:00:00Z","sets":[{"id":1,"stock_code":"600519","stock_name":"x","filename":"a.zip","schema_version":1,"content_hash":"ZZZZ"}]}
        """#
        let (api, _) = client(.init(body: Data(bad.utf8), statusCode: 200))
        await assertInternalErrorP1(detail: "meta_invalid_content_hash") {
            _ = try await api.reserveTrainingSets(count: 1)
        }
    }

    func test_reserve_accepts_fractional_seconds_expires_at() async throws {
        let body = #"{"lease_id":"6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d","expires_at":"2026-05-22T12:34:56.123Z","sets":[]}"#
        let (api, _) = client(.init(body: Data(body.utf8), statusCode: 200))
        let lease = try await api.reserveTrainingSets(count: 1)
        XCTAssertEqual(lease.sets.count, 0)  // 带毫秒的合法 expires_at 不应被拒
    }

    // MARK: - helpers
    private func assertThrowsAppError(
        _ expected: AppError, _ op: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await op()
            XCTFail("expected throw \(expected)", file: file, line: line)
        } catch let err as AppError {
            XCTAssertEqual(err, expected, file: file, line: line)
        } catch {
            XCTFail("non-AppError thrown: \(error)", file: file, line: line)
        }
    }

    private func assertInternalErrorP1(
        detail expected: String, _ op: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await op()
            XCTFail("expected internalError \(expected)", file: file, line: line)
        } catch let err as AppError {
            guard case .internalError(let module, let detail) = err else {
                return XCTFail("expected internalError, got \(err)", file: file, line: line)
            }
            XCTAssertEqual(module, "P1", file: file, line: line)
            XCTAssertEqual(detail, expected, file: file, line: line)
        } catch {
            XCTFail("non-AppError thrown: \(error)", file: file, line: line)
        }
    }
}

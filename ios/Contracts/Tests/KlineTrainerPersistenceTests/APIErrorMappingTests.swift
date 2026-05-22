import XCTest
@testable import KlineTrainerPersistence
import KlineTrainerContracts

final class APIErrorMappingTests: XCTestCase {
    func test_timeout_maps_to_network_timeout() {
        let err = APIErrorMapping.translate(URLError(.timedOut))
        XCTAssertEqual(err, .network(.timeout))
    }

    func test_not_connected_maps_to_offline() {
        XCTAssertEqual(APIErrorMapping.translate(URLError(.notConnectedToInternet)), .network(.offline))
        XCTAssertEqual(APIErrorMapping.translate(URLError(.networkConnectionLost)), .network(.offline))
        XCTAssertEqual(APIErrorMapping.translate(URLError(.cannotConnectToHost)), .network(.offline))
    }

    func test_other_urlerror_maps_to_offline_conservative() {
        // NetworkReason 词汇内无 "unknown"；其它传输层 URLError 归 offline（可重试）。
        XCTAssertEqual(APIErrorMapping.translate(URLError(.badServerResponse)), .network(.offline))
    }

    func test_passthrough_existing_apperror() {
        let original = AppError.network(.leaseExpired)
        XCTAssertEqual(APIErrorMapping.translate(original), original)
    }

    func test_non_urlerror_maps_to_internalError_p1() {
        struct Weird: Error {}
        let err = APIErrorMapping.translate(Weird())
        guard case .internalError(let module, _) = err else {
            return XCTFail("expected internalError, got \(err)")
        }
        XCTAssertEqual(module, "P1")
    }
}

import XCTest
import KlineTrainerContracts

final class AcceptanceJournalDAOContractTests: XCTestCase {

    // MARK: - typealias AppDB 编译性测试
    func test_typealias_AppDB_composes_four_protocols() {
        // 仅编译期断言：声明一个 var: AppDB? = nil 必须能放下任意 4-protocol 复合实现
        var sink: AppDB? = nil
        XCTAssertNil(sink)
        // 编译 ok 即过；运行时不做事
    }

    // MARK: - P2JournalState rawValue 锚点（防 v1.4 删 leased 后回归）
    func test_P2JournalState_v1_4_states_only_no_leased() {
        let allRawValues: [String] = [
            P2JournalState.downloaded.rawValue,
            P2JournalState.crcOK.rawValue,
            P2JournalState.unzipped.rawValue,
            P2JournalState.dbVerified.rawValue,
            P2JournalState.stored.rawValue,
            P2JournalState.confirmPending.rawValue,
            P2JournalState.confirmed.rawValue,
            P2JournalState.rejected.rawValue,
        ]
        // 8 个状态，无 "leased"（v1.4 删除）
        XCTAssertEqual(Set(allRawValues).count, 8)
        XCTAssertFalse(allRawValues.contains("leased"))
        XCTAssertEqual(P2JournalState.downloaded.rawValue, "downloaded")
        XCTAssertEqual(P2JournalState.crcOK.rawValue, "crcOK")
        XCTAssertEqual(P2JournalState.confirmPending.rawValue, "confirmPending")
    }

    // MARK: - AcceptanceJournalRow 字段
    func test_AcceptanceJournalRow_has_eight_fields() {
        let row = AcceptanceJournalRow(
            id: 1,
            trainingSetId: 100,
            leaseId: "lease-abc",
            state: .downloaded,
            stateEnteredAt: 1_700_000_000_000,
            lastError: nil,
            sqliteLocalPath: "/tmp/x.sqlite",
            contentHash: "deadbeef"
        )
        XCTAssertEqual(row.id, 1)
        XCTAssertEqual(row.trainingSetId, 100)
        XCTAssertEqual(row.leaseId, "lease-abc")
        XCTAssertEqual(row.state, .downloaded)
        XCTAssertEqual(row.contentHash, "deadbeef")
    }

    // MARK: - InMemoryAcceptanceJournalDAO fake 接口存在性
    #if DEBUG
    func test_InMemoryAcceptanceJournalDAO_can_instantiate_and_satisfies_protocol() throws {
        let fake: AcceptanceJournalDAO = InMemoryAcceptanceJournalDAO()
        try fake.upsert(trainingSetId: 1, leaseId: "x", state: .downloaded,
                        sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let rows = try fake.listByState(.downloaded)
        XCTAssertEqual(rows.count, 0)  // Wave 0 fake 不实际持久化（与其它 P4 fake 一致）
        try fake.deleteByIdLease(trainingSetId: 1, leaseId: "x")
    }
    #endif
}

import XCTest
import GRDB
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class DefaultAcceptanceJournalDAOTests: XCTestCase {

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

    // 用例 1：upsert 第一次 = INSERT，listByState 找到
    func test_upsert_first_time_inserts_and_listByState_finds_it() throws {
        try db.upsert(trainingSetId: 1, leaseId: "lease-A",
                      state: .downloaded,
                      sqliteLocalPath: "/tmp/x.sqlite",
                      contentHash: "deadbeef",
                      lastError: nil)
        let rows = try db.listByState(.downloaded)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].trainingSetId, 1)
        XCTAssertEqual(rows[0].leaseId, "lease-A")
        XCTAssertEqual(rows[0].state, .downloaded)
        XCTAssertEqual(rows[0].sqliteLocalPath, "/tmp/x.sqlite")
        XCTAssertEqual(rows[0].contentHash, "deadbeef")
        XCTAssertNil(rows[0].lastError)
        XCTAssertGreaterThan(rows[0].stateEnteredAt, 0)
    }

    // 用例 2：upsert 同 (id, lease) 第二次 = UPDATE，state_entered_at 刷新
    func test_upsert_same_key_updates_state() throws {
        try db.upsert(trainingSetId: 1, leaseId: "lease-A",
                      state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let firstStamp = try db.listByState(.downloaded).first?.stateEnteredAt ?? 0

        Thread.sleep(forTimeInterval: 0.01)

        try db.upsert(trainingSetId: 1, leaseId: "lease-A",
                      state: .crcOK, sqliteLocalPath: nil, contentHash: nil, lastError: nil)

        XCTAssertEqual(try db.listByState(.downloaded).count, 0)
        let after = try db.listByState(.crcOK)
        XCTAssertEqual(after.count, 1)
        XCTAssertGreaterThanOrEqual(after[0].stateEnteredAt, firstStamp)
    }

    // 用例 3：listByState 多状态分桶
    func test_listByState_filters_correctly() throws {
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try walkToStored(trainingSetId: 2, leaseId: "L2",
                         path: "/tmp/2.sqlite", hash: "2deadbef")
        try walkToStored(trainingSetId: 3, leaseId: "L3",
                         path: "/tmp/3.sqlite", hash: "3deadbef")
        try walkToStored(trainingSetId: 4, leaseId: "L4",
                         path: "/tmp/4.sqlite", hash: "4deadbef")
        try db.upsert(trainingSetId: 4, leaseId: "L4", state: .confirmPending,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 4, leaseId: "L4", state: .confirmed,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)

        XCTAssertEqual(try db.listByState(.downloaded).count, 1)
        XCTAssertEqual(try db.listByState(.stored).count, 2)
        XCTAssertEqual(try db.listByState(.confirmed).count, 1)
        XCTAssertEqual(try db.listByState(.confirmPending).count, 0)
    }

    // 用例 4：deleteByIdLease 存在行
    func test_deleteByIdLease_removes_row() throws {
        try db.upsert(trainingSetId: 5, leaseId: "L5", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.deleteByIdLease(trainingSetId: 5, leaseId: "L5")
        XCTAssertEqual(try db.listByState(.downloaded).count, 0)
    }

    // 用例 5：deleteByIdLease 不存在行不抛错
    func test_deleteByIdLease_missing_row_no_throw() throws {
        XCTAssertNoThrow(try db.deleteByIdLease(trainingSetId: 999, leaseId: "missing"))
    }

    // 用例 6：upsert 包含 lastError 文本
    func test_upsert_carries_lastError_text() throws {
        try db.upsert(trainingSetId: 6, leaseId: "L6", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 6, leaseId: "L6", state: .rejected,
                      sqliteLocalPath: nil, contentHash: nil,
                      lastError: "crc_mismatch_at_byte_42")
        let rows = try db.listByState(.rejected).filter { $0.leaseId == "L6" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].lastError, "crc_mismatch_at_byte_42")
    }

    // 用例 7：raw SQL 注入 leased 行 → listByState fail-safe filter
    func test_listByState_with_unknown_state_in_db_does_not_return_them() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO download_acceptance_journal
                  (training_set_id, lease_id, state, state_entered_at)
                VALUES (?, ?, 'leased', ?)
                """, arguments: [99, "v13-leased", 1_700_000_000_000])
        }
        XCTAssertEqual(try db.listByState(.downloaded).count, 0)
        for s in P2JournalState.allCases {
            for r in try db.listByState(s) {
                XCTAssertNotEqual(r.leaseId, "v13-leased")
            }
        }
    }

    // 用例 8：晚到 retry 不能把 .stored 倒回 .downloaded
    func test_upsert_stale_state_is_NOOP_keeps_existing() throws {
        try walkToStored(trainingSetId: 1, leaseId: "L1",
                         path: "/tmp/set.sqlite", hash: "deadbeef")
        XCTAssertEqual(try db.listByState(.stored).count, 1)

        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)

        XCTAssertEqual(try db.listByState(.downloaded).count, 0)
        let stored = try db.listByState(.stored)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].sqliteLocalPath, "/tmp/set.sqlite")
        XCTAssertEqual(stored[0].contentHash, "deadbeef")
    }

    // 用例 9：终态 .confirmed 与 .rejected 不可互转
    func test_upsert_terminal_states_mutually_exclusive() throws {
        try walkToStored(trainingSetId: 2, leaseId: "L2",
                         path: "/tmp/2.sqlite", hash: "2deadbef")
        try db.upsert(trainingSetId: 2, leaseId: "L2", state: .confirmPending,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 2, leaseId: "L2", state: .confirmed,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 2, leaseId: "L2", state: .rejected,
                      sqliteLocalPath: nil, contentHash: nil, lastError: "should_not_apply")
        XCTAssertEqual(try db.listByState(.rejected).filter { $0.leaseId == "L2" }.count, 0)
        XCTAssertEqual(try db.listByState(.confirmed).filter { $0.leaseId == "L2" }.count, 1)

        try db.upsert(trainingSetId: 3, leaseId: "L3", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 3, leaseId: "L3", state: .rejected,
                      sqliteLocalPath: nil, contentHash: nil, lastError: "x")
        try db.upsert(trainingSetId: 3, leaseId: "L3", state: .confirmed,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        XCTAssertEqual(try db.listByState(.confirmed).filter { $0.leaseId == "L3" }.count, 0)
        XCTAssertEqual(try db.listByState(.rejected).filter { $0.leaseId == "L3" }.count, 1)
    }

    // 用例 10：同 state 重试合法 → state_entered_at 刷新 + 辅助列覆盖（nil 入参不擦）
    func test_upsert_same_state_retry_refreshes_entered_at_and_aux_fields() throws {
        try db.upsert(trainingSetId: 4, leaseId: "L4", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let firstStamp = try db.listByState(.downloaded).first?.stateEnteredAt ?? 0
        Thread.sleep(forTimeInterval: 0.01)
        try db.upsert(trainingSetId: 4, leaseId: "L4", state: .downloaded,
                      sqliteLocalPath: "/tmp/path", contentHash: "abc12345",
                      lastError: nil)
        let after = try db.listByState(.downloaded).first { $0.leaseId == "L4" }
        XCTAssertGreaterThanOrEqual(after?.stateEnteredAt ?? 0, firstStamp)
        XCTAssertEqual(after?.sqliteLocalPath, "/tmp/path")
        XCTAssertEqual(after?.contentHash, "abc12345")
    }

    @discardableResult
    private func walkToStored(trainingSetId tid: Int, leaseId lid: String,
                              path: String, hash: String) throws -> Bool {
        try db.upsert(trainingSetId: tid, leaseId: lid, state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: tid, leaseId: lid, state: .crcOK,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: tid, leaseId: lid, state: .unzipped,
                      sqliteLocalPath: path, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: tid, leaseId: lid, state: .dbVerified,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: tid, leaseId: lid, state: .stored,
                      sqliteLocalPath: nil, contentHash: hash, lastError: nil)
        return true
    }

    // 用例 11：stale .stored retry 传 nil aux → COALESCE 保留
    func test_upsert_stale_retry_with_nil_aux_does_not_clear_existing_path_and_hash() throws {
        try walkToStored(trainingSetId: 5, leaseId: "L5",
                         path: "/tmp/set5.sqlite", hash: "5deadbe5")
        try db.upsert(trainingSetId: 5, leaseId: "L5", state: .stored,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)

        let stored = try db.listByState(.stored).filter { $0.leaseId == "L5" }
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].sqliteLocalPath, "/tmp/set5.sqlite", "nil 入参不应清空已有 path")
        XCTAssertEqual(stored[0].contentHash, "5deadbe5", "nil 入参不应清空已有 hash")
    }

    // 用例 12：forward .confirmPending 传 nil → 已有 path/hash 保留
    func test_upsert_forward_with_nil_aux_preserves_existing_via_coalesce() throws {
        try walkToStored(trainingSetId: 6, leaseId: "L6",
                         path: "/tmp/set6.sqlite", hash: "6c0ffe11")
        try db.upsert(trainingSetId: 6, leaseId: "L6", state: .confirmPending,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)

        let cp = try db.listByState(.confirmPending).filter { $0.leaseId == "L6" }
        XCTAssertEqual(cp.count, 1)
        XCTAssertEqual(cp[0].sqliteLocalPath, "/tmp/set6.sqlite")
        XCTAssertEqual(cp[0].contentHash, "6c0ffe11")
    }

    // 用例 14：到 .stored 缺 sqliteLocalPath → .internalError
    func test_upsert_stored_without_path_throws_internalError() throws {
        try db.upsert(trainingSetId: 80, leaseId: "L80", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 80, leaseId: "L80", state: .crcOK,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 80, leaseId: "L80", state: .unzipped,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 80, leaseId: "L80", state: .dbVerified,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        XCTAssertThrowsError(try db.upsert(
            trainingSetId: 80, leaseId: "L80", state: .stored,
            sqliteLocalPath: nil, contentHash: "deadbeef", lastError: nil)
        ) { err in
            guard let appErr = err as? AppError,
                  case .internalError(let module, _) = appErr else {
                return XCTFail("期望 .internalError，实际 \(err)")
            }
            XCTAssertTrue(module.contains("AcceptanceJournalDAO"))
        }
    }

    // 用例 15：到 .stored contentHash 非 8-char hex → .internalError
    func test_upsert_stored_with_invalid_contentHash_throws_internalError() throws {
        try db.upsert(trainingSetId: 81, leaseId: "L81", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 81, leaseId: "L81", state: .crcOK,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 81, leaseId: "L81", state: .unzipped,
                      sqliteLocalPath: "/tmp/x.sqlite", contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 81, leaseId: "L81", state: .dbVerified,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        XCTAssertThrowsError(try db.upsert(
            trainingSetId: 81, leaseId: "L81", state: .stored,
            sqliteLocalPath: nil, contentHash: "deadbee", lastError: nil))
        XCTAssertThrowsError(try db.upsert(
            trainingSetId: 81, leaseId: "L81", state: .stored,
            sqliteLocalPath: nil, contentHash: "DEADBEEF", lastError: nil))
        XCTAssertThrowsError(try db.upsert(
            trainingSetId: 81, leaseId: "L81", state: .stored,
            sqliteLocalPath: nil, contentHash: "deadbeeg", lastError: nil))
    }

    // 用例 16：.stored inherit 历史 path → 允许
    func test_upsert_stored_inherits_existing_path_via_invariant_check() throws {
        try walkToStored(trainingSetId: 82, leaseId: "L82",
                         path: "/tmp/82.sqlite", hash: "82deadbe")
        let stored = try db.listByState(.stored).filter { $0.leaseId == "L82" }
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].sqliteLocalPath, "/tmp/82.sqlite")
        XCTAssertEqual(stored[0].contentHash, "82deadbe")
    }

    // 用例 18：跳步 .downloaded → .stored 必须 NOOP
    func test_upsert_skip_state_downloaded_to_stored_is_NOOP() throws {
        try db.upsert(trainingSetId: 90, leaseId: "L90", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 90, leaseId: "L90", state: .stored,
                      sqliteLocalPath: "/tmp/90.sqlite", contentHash: "90deadbe",
                      lastError: nil)

        XCTAssertEqual(try db.listByState(.stored).filter { $0.leaseId == "L90" }.count, 0)
        let dl = try db.listByState(.downloaded).filter { $0.leaseId == "L90" }
        XCTAssertEqual(dl.count, 1)
        XCTAssertNil(dl[0].sqliteLocalPath)
        XCTAssertNil(dl[0].contentHash)
    }

    // 用例 19：首次 INSERT 非 .downloaded → .internalError
    func test_first_insert_non_downloaded_throws_internalError() throws {
        XCTAssertThrowsError(try db.upsert(
            trainingSetId: 91, leaseId: "L91", state: .stored,
            sqliteLocalPath: "/tmp/91.sqlite", contentHash: "91deadbe", lastError: nil)
        ) { err in
            guard let appErr = err as? AppError,
                  case .internalError(let module, let detail) = appErr else {
                return XCTFail("期望 .internalError，实际 \(err)")
            }
            XCTAssertTrue(module.contains("AcceptanceJournalDAO"))
            XCTAssertTrue(detail.contains(".downloaded") || detail.contains("first INSERT"),
                          "detail 应说明首次 INSERT 必须 .downloaded")
        }
        XCTAssertEqual(try db.listByState(.stored).filter { $0.leaseId == "L91" }.count, 0)
    }

    // 用例 20：任何阶段都可推 .rejected
    func test_upsert_rejected_allowed_from_any_state() throws {
        try db.upsert(trainingSetId: 92, leaseId: "L92", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 92, leaseId: "L92", state: .rejected,
                      sqliteLocalPath: nil, contentHash: nil, lastError: "crc_failed")
        XCTAssertEqual(try db.listByState(.rejected).filter { $0.leaseId == "L92" }.count, 1)

        try db.upsert(trainingSetId: 93, leaseId: "L93", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 93, leaseId: "L93", state: .crcOK,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 93, leaseId: "L93", state: .unzipped,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 93, leaseId: "L93", state: .rejected,
                      sqliteLocalPath: nil, contentHash: nil, lastError: "verify_failed")
        XCTAssertEqual(try db.listByState(.rejected).filter { $0.leaseId == "L93" }.count, 1)
    }

    // 用例 17：state_entered_at 是 Unix 秒 UTC（非毫秒）
    func test_state_entered_at_is_unix_seconds_not_millis() throws {
        let beforeSec = Int64(Date().timeIntervalSince1970)
        try db.upsert(trainingSetId: 83, leaseId: "L83", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let afterSec = Int64(Date().timeIntervalSince1970) + 1

        let row = try db.listByState(.downloaded).first { $0.leaseId == "L83" }
        let stamp = row?.stateEnteredAt ?? 0
        XCTAssertGreaterThanOrEqual(stamp, beforeSec - 1)
        XCTAssertLessThanOrEqual(stamp, afterSec + 1)
        XCTAssertGreaterThan(stamp, 1_700_000_000)
        XCTAssertLessThan(stamp, 4_000_000_000)
    }

    // 用例 13：existing 是 unknown raw value → upsert NOOP，不覆盖
    func test_upsert_existing_unknown_state_is_NOOP_not_overwritten() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO download_acceptance_journal
                  (training_set_id, lease_id, state, state_entered_at,
                   last_error, sqlite_local_path, content_hash)
                VALUES (?, ?, 'leased', ?, NULL, '/tmp/v13.sqlite', 'd0d0beef')
                """, arguments: [77, "v13-leased", 1_700_000_000_000])
        }

        try db.upsert(trainingSetId: 77, leaseId: "v13-leased", state: .downloaded,
                      sqliteLocalPath: "/tmp/new.sqlite", contentHash: "deadbeef",
                      lastError: nil)

        XCTAssertEqual(try db.listByState(.downloaded).filter { $0.leaseId == "v13-leased" }.count, 0)

        let row = try queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT state, sqlite_local_path, content_hash
                FROM download_acceptance_journal
                WHERE training_set_id = ? AND lease_id = ?
                """, arguments: [77, "v13-leased"])
        }
        XCTAssertEqual(row?["state"] as String?, "leased", "unknown state 应原样保留")
        XCTAssertEqual(row?["sqlite_local_path"] as String?, "/tmp/v13.sqlite")
        XCTAssertEqual(row?["content_hash"] as String?, "d0d0beef")
    }
}

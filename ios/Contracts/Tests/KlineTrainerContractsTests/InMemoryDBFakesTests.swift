import XCTest
@testable import KlineTrainerContracts

#if DEBUG
final class InMemoryDBFakesTests: XCTestCase {

    // MARK: - InMemoryRecordRepository

    func test_recordRepo_insertRecord_assigns_id_and_persists() throws {
        let repo = InMemoryRecordRepository()
        let rec = makeRecord(id: nil, profit: 100, total: 1000)
        let id = try repo.insertRecord(rec, ops: [], drawings: [])
        XCTAssertEqual(id, 1)
        let listed = try repo.listRecords(limit: nil)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, 1)  // server-assigned id 写回
    }

    func test_recordRepo_loadRecordBundle_returns_inserted_ops_and_drawings() throws {
        let repo = InMemoryRecordRepository()
        let op = makeOp(direction: .buy)
        let dr = makeDrawing()
        let id = try repo.insertRecord(makeRecord(id: nil), ops: [op], drawings: [dr])
        let bundle = try repo.loadRecordBundle(id: id)
        XCTAssertEqual(bundle.0.id, id)
        XCTAssertEqual(bundle.1.count, 1)
        XCTAssertEqual(bundle.1.first?.direction, .buy)
        XCTAssertEqual(bundle.2.count, 1)
    }

    func test_recordRepo_loadRecordBundle_throws_dbCorrupted_for_unknown_id() {
        // mirror production RecordRepositoryImpl.swift line 74
        let repo = InMemoryRecordRepository()
        XCTAssertThrowsError(try repo.loadRecordBundle(id: 999)) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                XCTFail("expected .dbCorrupted, got \(err)"); return
            }
        }
    }

    func test_recordRepo_listRecords_limit_and_order_desc_by_createdAt() throws {
        let repo = InMemoryRecordRepository()
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 100), ops: [], drawings: [])
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 300), ops: [], drawings: [])
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 200), ops: [], drawings: [])
        let all = try repo.listRecords(limit: nil)
        XCTAssertEqual(all.map(\.createdAt), [300, 200, 100])
        let topTwo = try repo.listRecords(limit: 2)
        XCTAssertEqual(topTwo.count, 2)
        XCTAssertEqual(topTwo.map(\.createdAt), [300, 200])
    }

    /// R1 修订（codex round-1 med-2）：同 createdAt 多条时按 id DESC tiebreak（mirror production line 60）
    func test_recordRepo_listRecords_id_desc_tiebreaker_for_same_createdAt() throws {
        let repo = InMemoryRecordRepository()
        // 3 条 createdAt 全 = 100；插入顺序赋 id = 1, 2, 3
        let id1 = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: 1), ops: [], drawings: [])
        let id2 = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: 2), ops: [], drawings: [])
        let id3 = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: 3), ops: [], drawings: [])
        XCTAssertEqual([id1, id2, id3], [1, 2, 3])

        let all = try repo.listRecords(limit: nil)
        // (createdAt desc, id desc) → id 3 / 2 / 1
        XCTAssertEqual(all.map(\.id), [3, 2, 1])
    }

    func test_recordRepo_statistics_currentCapital_uses_latest_by_createdAt() throws {
        let repo = InMemoryRecordRepository()
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: 100, total: 1000), ops: [], drawings: [])
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 200, profit: 200, total: 1000), ops: [], drawings: [])
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 300, profit: -50, total: 1000), ops: [], drawings: [])
        let s = try repo.statistics()
        XCTAssertEqual(s.totalCount, 3)
        XCTAssertEqual(s.winCount, 2)
        XCTAssertEqual(s.currentCapital, 1000 + (-50))
    }

    /// R1 修订（codex round-1 med-2）：statistics.currentCapital 同 createdAt 时取 id 最大者（mirror production line 99）
    func test_recordRepo_statistics_id_desc_tiebreaker_for_same_createdAt() throws {
        let repo = InMemoryRecordRepository()
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: 100, total: 1000), ops: [], drawings: [])
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: 200, total: 1000), ops: [], drawings: [])
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: -50, total: 1000), ops: [], drawings: [])
        // 最后插入 id=3 的 profit=-50；同 createdAt 下 id 最大胜出
        let s = try repo.statistics()
        XCTAssertEqual(s.currentCapital, 1000 + (-50))
    }

    func test_recordRepo_statistics_empty_returns_zero() throws {
        let repo = InMemoryRecordRepository()
        let s = try repo.statistics()
        XCTAssertEqual(s.totalCount, 0)
        XCTAssertEqual(s.winCount, 0)
        XCTAssertEqual(s.currentCapital, 0)
    }

    /// R8 修订（codex round-8 med-3）：负 limit 不应 trap，应返回全量（mirror SQLite LIMIT 负值语义）
    func test_recordRepo_listRecords_negative_limit_returns_all() throws {
        let repo = InMemoryRecordRepository()
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 100), ops: [], drawings: [])
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 200), ops: [], drawings: [])
        XCTAssertEqual(try repo.listRecords(limit: -1).count, 2)  // 不 trap
        XCTAssertEqual(try repo.listRecords(limit: -100).count, 2)
        XCTAssertEqual(try repo.listRecords(limit: 0).count, 0)   // 0 = 空（合法 prefix）
    }

    // MARK: - InMemoryPendingTrainingRepository

    func test_pendingRepo_save_load_clear_round_trip() throws {
        let repo = InMemoryPendingTrainingRepository()
        XCTAssertNil(try repo.loadPending())

        try repo.savePending(makePending(filename: "S001.sqlite"))
        XCTAssertEqual(try repo.loadPending()?.trainingSetFilename, "S001.sqlite")

        try repo.savePending(makePending(filename: "S002.sqlite"))
        XCTAssertEqual(try repo.loadPending()?.trainingSetFilename, "S002.sqlite")

        try repo.clearPending()
        XCTAssertNil(try repo.loadPending())

        // clear 在已 nil 时合法
        try repo.clearPending()
    }

    // MARK: - InMemorySettingsDAO

    func test_settingsDAO_default_load_returns_zero_AppSettings() throws {
        let dao = InMemorySettingsDAO()
        let s = try dao.loadSettings()
        XCTAssertEqual(s.commissionRate, 0)
        XCTAssertEqual(s.totalCapital, 0)
        XCTAssertFalse(s.minCommissionEnabled)
        XCTAssertEqual(s.displayMode, .system)
    }

    func test_settingsDAO_save_then_load_round_trip() throws {
        let dao = InMemorySettingsDAO()
        let s = AppSettings(commissionRate: 0.0003, minCommissionEnabled: true, totalCapital: 50_000, displayMode: .dark)
        try dao.saveSettings(s)
        XCTAssertEqual(try dao.loadSettings(), s)
    }

    func test_settingsDAO_resetCapital_setsDefaultCapital() throws {
        let dao = InMemorySettingsDAO()
        try dao.saveSettings(AppSettings(commissionRate: 0.0003, minCommissionEnabled: true, totalCapital: 50_000, displayMode: .dark))
        try dao.resetCapital()
        let after = try dao.loadSettings()
        XCTAssertEqual(after.totalCapital, 100_000)
        XCTAssertEqual(after.commissionRate, 0.0003)
        XCTAssertTrue(after.minCommissionEnabled)
        XCTAssertEqual(after.displayMode, .dark)
    }

    /// R2 修订（codex round-2 med-2）：mirror production saveSettings 拒 NaN / +inf / -inf
    func test_settingsDAO_saveSettings_rejects_nonfinite_commissionRate_and_does_not_mutate() throws {
        let dao = InMemorySettingsDAO()
        let baseline = AppSettings(commissionRate: 0.0003, minCommissionEnabled: true, totalCapital: 1000, displayMode: .dark)
        try dao.saveSettings(baseline)

        for bad in [Double.nan, .infinity, -.infinity] {
            let payload = AppSettings(commissionRate: bad, minCommissionEnabled: true, totalCapital: 1000, displayMode: .dark)
            XCTAssertThrowsError(try dao.saveSettings(payload)) { err in
                guard case AppError.internalError = err else { XCTFail("expected internalError"); return }
            }
        }
        // 拒收后 settings 未被改（仍是 baseline）
        XCTAssertEqual(try dao.loadSettings(), baseline)
    }

    func test_settingsDAO_saveSettings_rejects_nonfinite_totalCapital_and_does_not_mutate() throws {
        let dao = InMemorySettingsDAO()
        let baseline = AppSettings(commissionRate: 0.0003, minCommissionEnabled: true, totalCapital: 1000, displayMode: .dark)
        try dao.saveSettings(baseline)

        for bad in [Double.nan, .infinity, -.infinity] {
            let payload = AppSettings(commissionRate: 0.0003, minCommissionEnabled: true, totalCapital: bad, displayMode: .dark)
            XCTAssertThrowsError(try dao.saveSettings(payload)) { err in
                guard case AppError.internalError = err else { XCTFail("expected internalError"); return }
            }
        }
        XCTAssertEqual(try dao.loadSettings(), baseline)
    }

    // MARK: - InMemoryAcceptanceJournalDAO（R1 修订：state machine + invariants + COALESCE 全镜像 production）

    // 1) 首插必须 .downloaded
    func test_journalDAO_first_insert_must_be_downloaded() {
        let dao = InMemoryAcceptanceJournalDAO()
        XCTAssertThrowsError(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK,
                                            sqliteLocalPath: nil, contentHash: nil, lastError: nil)) { err in
            guard case AppError.internalError = err else { XCTFail("expected internalError"); return }
        }
        // .downloaded OK
        XCTAssertNoThrow(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                                        sqliteLocalPath: nil, contentHash: nil, lastError: nil))
    }

    // 2) 合法转换 downloaded → crcOK 接受
    func test_journalDAO_legal_transition_downloaded_to_crcOK() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                       sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK,
                       sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        XCTAssertEqual(try dao.listByState(.downloaded).count, 0)
        XCTAssertEqual(try dao.listByState(.crcOK).count, 1)
    }

    // 3) 跳跃转换 = silent NOOP（不抛、不改 state）—— mirror production logger.info + return
    func test_journalDAO_skip_transition_downloaded_to_stored_is_noop() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                       sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        // 越级到 .stored —— 即使带齐 path+hash，也应被 nextAllowed 拒（NOOP）
        XCTAssertNoThrow(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                        sqliteLocalPath: "/tmp/x.sqlite", contentHash: "deadbeef",
                                        lastError: nil))
        // state 仍是 .downloaded
        XCTAssertEqual(try dao.listByState(.stored).count, 0)
        XCTAssertEqual(try dao.listByState(.downloaded).count, 1)
    }

    // 4) 终态 confirmed 不可再转
    func test_journalDAO_terminal_confirmed_to_rejected_is_noop() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        // 走完 downloaded → ... → confirmed
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .unzipped, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .dbVerified, sqliteLocalPath: "/tmp/x.sqlite", contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored, sqliteLocalPath: "/tmp/x.sqlite", contentHash: "deadbeef", lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .confirmPending, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .confirmed, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        XCTAssertEqual(try dao.listByState(.confirmed).count, 1)

        // confirmed → rejected = NOOP
        XCTAssertNoThrow(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .rejected,
                                        sqliteLocalPath: nil, contentHash: nil, lastError: "x"))
        XCTAssertEqual(try dao.listByState(.confirmed).count, 1) // 仍 confirmed
        XCTAssertEqual(try dao.listByState(.rejected).count, 0)
    }

    // 5) 任何 state 都可推 .rejected（除终态）
    func test_journalDAO_any_state_to_rejected_allowed() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .rejected, sqliteLocalPath: nil, contentHash: nil, lastError: "fail")
        XCTAssertEqual(try dao.listByState(.rejected).count, 1)
        XCTAssertEqual(try dao.listByState(.rejected).first?.lastError, "fail")
    }

    // 6) 同 state retry 允许（new == old → canApply true，重新 stamp）
    func test_journalDAO_same_state_retry_allowed_and_stamp_advances() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                       sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let firstAt = try XCTUnwrap(try dao.listByState(.downloaded).first?.stateEnteredAt)
        Thread.sleep(forTimeInterval: 1.05)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                       sqliteLocalPath: nil, contentHash: nil, lastError: "retry")
        let secondAt = try XCTUnwrap(try dao.listByState(.downloaded).first?.stateEnteredAt)
        XCTAssertGreaterThan(secondAt, firstAt)
    }

    // 7) state ∈ {.stored, .confirmPending, .confirmed} 缺 sqliteLocalPath → throw
    func test_journalDAO_stored_requires_path() throws {
        // Note: validateInvariants also requires path for .confirmPending / .confirmed,
        // but the state machine forces those states to be reached only after .stored,
        // which itself requires path. So .stored coverage exhausts the missing-path
        // branch reachable via public API. Same applies to invalid CRC32 hex on those
        // later states: once .stored succeeded with a valid path, COALESCE ensures path
        // is always present for subsequent .confirmPending / .confirmed upserts.
        let dao = InMemoryAcceptanceJournalDAO()
        // 走到 .dbVerified（合法且不要 path——production validateInvariants 只对 stored/confirmPending/confirmed 要 path）
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .unzipped, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .dbVerified, sqliteLocalPath: nil, contentHash: nil, lastError: nil)

        // .stored 缺 path 应抛
        XCTAssertThrowsError(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                            sqliteLocalPath: nil, contentHash: "deadbeef", lastError: nil)) { err in
            guard case AppError.internalError = err else { XCTFail("expected internalError"); return }
        }
    }

    // 8) .stored 缺 contentHash / hash 非 8-char 小写 hex → throw
    func test_journalDAO_stored_requires_valid_crc32_hex() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .unzipped, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .dbVerified, sqliteLocalPath: "/tmp/x.sqlite", contentHash: nil, lastError: nil)

        // hash nil
        XCTAssertThrowsError(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                            sqliteLocalPath: "/tmp/x.sqlite", contentHash: nil, lastError: nil))
        // hash 长度错（7 字符）
        XCTAssertThrowsError(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                            sqliteLocalPath: "/tmp/x.sqlite", contentHash: "deadbee", lastError: nil))
        // hash 大写（production 要小写）
        XCTAssertThrowsError(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                            sqliteLocalPath: "/tmp/x.sqlite", contentHash: "DEADBEEF", lastError: nil))
        // hash 含非 hex 字符
        XCTAssertThrowsError(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                            sqliteLocalPath: "/tmp/x.sqlite", contentHash: "zzzzzzzz", lastError: nil))
        // 合法 8-char 小写 hex 通过
        XCTAssertNoThrow(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                        sqliteLocalPath: "/tmp/x.sqlite", contentHash: "deadbeef", lastError: nil))
    }

    // 9) COALESCE：nil 入参不覆盖 existing 字段
    func test_journalDAO_coalesce_preserves_existing_path_and_hash_on_nil_inputs() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .unzipped, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .dbVerified, sqliteLocalPath: "/tmp/x.sqlite", contentHash: nil, lastError: "first")
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored, sqliteLocalPath: nil, contentHash: "deadbeef", lastError: nil)

        // .stored 入参 sqliteLocalPath = nil；COALESCE 应保留 .dbVerified 时写入的 "/tmp/x.sqlite"
        let row = try XCTUnwrap(try dao.listByState(.stored).first)
        XCTAssertEqual(row.sqliteLocalPath, "/tmp/x.sqlite")  // 未被 nil 覆盖
        XCTAssertEqual(row.contentHash, "deadbeef")            // 新写入
        XCTAssertEqual(row.lastError, "first")                 // 未被 nil 覆盖

        // 再 upsert 同 state 带新 lastError，hash 入 nil → 保留 deadbeef
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                       sqliteLocalPath: nil, contentHash: nil, lastError: "second")
        let row2 = try XCTUnwrap(try dao.listByState(.stored).first)
        XCTAssertEqual(row2.contentHash, "deadbeef")
        XCTAssertEqual(row2.lastError, "second")
    }

    // 10) upsert 合法转换保留 id（mirror SQLite UNIQUE + REPLACE）
    func test_journalDAO_legal_transition_keeps_id() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let firstId = try XCTUnwrap(try dao.listByState(.downloaded).first?.id)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        XCTAssertEqual(try dao.listByState(.crcOK).first?.id, firstId)
    }

    // 11) listByState 按 id ASC（mirror production line 143 ORDER BY id ASC）
    func test_journalDAO_listByState_orders_by_id_asc() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 2, leaseId: "L2", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 3, leaseId: "L3", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let rows = try dao.listByState(.downloaded)
        XCTAssertEqual(rows.map(\.id), [1, 2, 3]) // 按 insertion id ASC
    }

    // 12) deleteByIdLease 0 行删除合法
    func test_journalDAO_deleteByIdLease_zero_row_legal() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.deleteByIdLease(trainingSetId: 1, leaseId: "L1")
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.deleteByIdLease(trainingSetId: 1, leaseId: "L1")
        XCTAssertEqual(try dao.listByState(.downloaded).count, 0)
    }

    // MARK: - InMemorySessionFinalizationPort

    /// I-1 (1) success: finalizeSession inserts into records, clears pending, finalizeCallCount == 1
    func test_finalizationPort_success_inserts_record_and_clears_pending() throws {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)

        // 预存一个 pending，验证 finalize 后被清除
        try pending.savePending(makePending(filename: "S001.sqlite"))
        XCTAssertNotNil(try pending.loadPending())

        let id = try port.finalizeSession(
            record: makeRecord(id: nil), ops: [makeOp(direction: .buy)],
            drawings: [makeDrawing()], sessionKey: "SK-1").id

        XCTAssertEqual(port.finalizeCallCount, 1)
        XCTAssertEqual(id, 1)
        let listed = try records.listRecords(limit: nil)
        XCTAssertEqual(listed.count, 1)
        XCTAssertNil(try pending.loadPending())   // pending 已清
    }

    /// I-1 (2) atomic fail injection: failNextFinalize → throw, ZERO state change; keyed not poisoned
    func test_finalizationPort_failNextFinalize_throws_and_leaves_zero_state_change() throws {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)

        // 预存一个 pending
        try pending.savePending(makePending(filename: "S001.sqlite"))

        // 注入错误
        port.failNextFinalize = AppError.persistence(.ioError("inject-test"))

        XCTAssertThrowsError(
            try port.finalizeSession(record: makeRecord(id: nil), ops: [],
                                     drawings: [], sessionKey: "SK-atomic")
        ) { err in
            guard case AppError.persistence(.ioError) = err else {
                XCTFail("expected .persistence(.ioError), got \(err)"); return
            }
        }

        // finalizeCallCount 在错误路径也递增
        XCTAssertEqual(port.finalizeCallCount, 1)
        // 零状态变更：records 仍空，pending 仍存在
        XCTAssertEqual(try records.listRecords(limit: nil).count, 0)
        XCTAssertNotNil(try pending.loadPending())

        // 同 key 后续成功不受毒：keyed map 未被污染
        let id = try port.finalizeSession(record: makeRecord(id: nil), ops: [],
                                          drawings: [], sessionKey: "SK-atomic").id
        XCTAssertEqual(port.finalizeCallCount, 2)
        XCTAssertEqual(try records.listRecords(limit: nil).count, 1)
        XCTAssertEqual(id, 1)
    }

    /// I-1 (3) idempotent same-key: two calls with same sessionKey → same id, count stays 1
    func test_finalizationPort_idempotent_same_key_returns_same_id() throws {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)

        let id1 = try port.finalizeSession(record: makeRecord(id: nil), ops: [],
                                           drawings: [], sessionKey: "SK-idem").id
        XCTAssertEqual(try records.listRecords(limit: nil).count, 1)

        // 在两次调用之间存入一个 stale pending
        try pending.savePending(makePending(filename: "stale.sqlite"))
        XCTAssertNotNil(try pending.loadPending())

        let id2 = try port.finalizeSession(record: makeRecord(id: nil), ops: [],
                                           drawings: [], sessionKey: "SK-idem").id

        XCTAssertEqual(id1, id2)
        XCTAssertEqual(try records.listRecords(limit: nil).count, 1)  // 仍只有 1 条
        XCTAssertNil(try pending.loadPending())                        // 第二次调用也清了 pending
    }

    /// I-1 (4) distinct keys → two different ids, records count 2
    func test_finalizationPort_distinct_keys_produce_two_ids() throws {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)

        let id1 = try port.finalizeSession(record: makeRecord(id: nil, profit: 100), ops: [],
                                           drawings: [], sessionKey: "SK-A").id
        let id2 = try port.finalizeSession(record: makeRecord(id: nil, profit: 200), ops: [],
                                           drawings: [], sessionKey: "SK-B").id

        XCTAssertNotEqual(id1, id2)
        XCTAssertEqual(try records.listRecords(limit: nil).count, 2)
        XCTAssertEqual(port.finalizeCallCount, 2)
    }

    // MARK: - 并发安全 smoke

    func test_recordRepo_concurrent_inserts_no_data_race_or_lost_writes() throws {
        let repo = InMemoryRecordRepository()
        // R7 修订（codex round-7 high-1）：Swift 6 strict concurrency 下 q.async 闭包是 @Sendable，
        // 不能捕获非-Sendable 的 XCTestCase self。先在主线程同步构造 [TrainingRecord]（仍可调 self.makeRecord），
        // 再把已构造的 Sendable 值分发进闭包。
        let records: [TrainingRecord] = (0..<200).map { i in makeRecord(id: nil, createdAt: Int64(i)) }
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)
        for record in records {
            group.enter()
            q.async {
                defer { group.leave() }
                _ = try? repo.insertRecord(record, ops: [], drawings: [])
            }
        }
        group.wait()
        XCTAssertEqual(try repo.listRecords(limit: nil).count, 200)
    }

    // MARK: - Helpers

    private func makeRecord(id: Int64?, createdAt: Int64 = 0, profit: Double = 0, total: Double = 1000) -> TrainingRecord {
        TrainingRecord(id: id, trainingSetFilename: "x.sqlite", createdAt: createdAt,
                       stockCode: "000001", stockName: "S", startYear: 2020, startMonth: 1,
                       totalCapital: total, profit: profit, returnRate: 0, maxDrawdown: 0,
                       buyCount: 0, sellCount: 0,
                       feeSnapshot: FeeSnapshot(commissionRate: 0, minCommissionEnabled: false),
                       finalTick: 0)
    }

    private func makeOp(direction: TradeDirection) -> TradeOperation {
        TradeOperation(globalTick: 0, period: .daily, direction: direction,
                       price: 10, shares: 100, positionTier: .tier3,
                       commission: 0, stampDuty: 0, totalCost: 0, createdAt: 0)
    }

    private func makeDrawing() -> DrawingObject {
        DrawingObject(toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
    }

    private func makePending(filename: String) -> PendingTraining {
        PendingTraining(trainingSetFilename: filename, globalTickIndex: 0,
                        upperPeriod: .daily, lowerPeriod: .m15,
                        positionData: Data(), cashBalance: 0,
                        feeSnapshot: FeeSnapshot(commissionRate: 0, minCommissionEnabled: false),
                        tradeOperations: [], drawings: [],
                        startedAt: 0, accumulatedCapital: 0,
                        drawdown: .initial,
                        sessionKey: "SK-test")
    }
}
#endif

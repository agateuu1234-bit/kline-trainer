import Foundation
import os.log
@preconcurrency import GRDB
import KlineTrainerContracts

/// AcceptanceJournalDAO 静态方法实现。
/// 表 download_acceptance_journal UNIQUE(training_set_id, lease_id)。
/// **R1 修订**：upsert 加单调 rank guard（codex high-1）；listByState decode 加 fail-safe + os_log（codex med-3）
enum AcceptanceJournalDAOImpl {

    private static let logger = Logger(subsystem: "com.kline.trainer.persistence",
                                       category: "AcceptanceJournalDAO")

    /// 显式 next-state allowlist（R4 修订 codex high-2 — spec L1798+ P2 状态机线性顺序）：
    /// 任何状态只能转去显式列出的下一组 state。downloaded → stored 跳过 CRC/unzip/verify 不允许。
    /// `rejected` 是吸收终态；`confirmed` 是成功终态；终态间互斥不可转。
    /// 任何状态都可推到 `.rejected`（失败可在任何阶段发生）。
    private static func nextAllowed(_ s: P2JournalState) -> Set<P2JournalState> {
        switch s {
        case .downloaded:     return [.crcOK, .rejected]
        case .crcOK:          return [.unzipped, .rejected]
        case .unzipped:       return [.dbVerified, .rejected]
        case .dbVerified:     return [.stored, .rejected]
        case .stored:         return [.confirmPending, .rejected]
        case .confirmPending: return [.confirmed, .rejected]
        case .confirmed:      return []
        case .rejected:       return []
        }
    }

    /// 转换合法性判定（R4 修订 codex high-2 — 改 explicit allowlist 取代 rank>）：
    /// - `new == old` → 同 state 重试，允许
    /// - `new` ∈ `nextAllowed(old)` → 一步转换，允许
    /// - 其它 → NOOP
    private static func canApply(new: P2JournalState, over old: P2JournalState) -> Bool {
        if new == old { return true }
        return nextAllowed(old).contains(new)
    }

    /// state-dependent invariant（R3 修订 codex high-1）：
    /// 推进到 .stored / .confirmPending / .confirmed 时必须已有 sqliteLocalPath
    /// 推进到 .stored 时必须有 contentHash 且 8-char 小写 hex
    private static func validateInvariants(state: P2JournalState,
                                           existingPath: String?,
                                           existingHash: String?,
                                           newPath: String?,
                                           newHash: String?) throws {
        let resolvedPath = newPath ?? existingPath
        let resolvedHash = newHash ?? existingHash
        let needsPath: Set<P2JournalState> = [.stored, .confirmPending, .confirmed]
        if needsPath.contains(state), resolvedPath == nil {
            throw AppError.internalError(
                module: "P4-AcceptanceJournalDAO",
                detail: "state \(state.rawValue) requires sqliteLocalPath but neither new nor existing has it")
        }
        if state == .stored {
            guard let h = resolvedHash, isValidCRC32Hex(h) else {
                throw AppError.internalError(
                    module: "P4-AcceptanceJournalDAO",
                    detail: ".stored requires contentHash matching 8-char lowercase hex (CRC32)")
            }
        }
    }

    /// CRC32 hex 校验：8 个字符，全部 0-9a-f（小写）
    private static func isValidCRC32Hex(_ s: String) -> Bool {
        guard s.count == 8 else { return false }
        return s.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) }
    }

    static func upsert(_ db: Database,
                       trainingSetId: Int, leaseId: String,
                       state: P2JournalState,
                       sqliteLocalPath: String?,
                       contentHash: String?,
                       lastError: String?) throws {
        let stateEnteredAt = Int64(Date().timeIntervalSince1970)

        if let row = try Row.fetchOne(db, sql: """
            SELECT state, sqlite_local_path, content_hash FROM download_acceptance_journal
            WHERE training_set_id = ? AND lease_id = ?
            """, arguments: [trainingSetId, leaseId]) {
            let existingRaw: String = row["state"]
            let existingPath: String? = row["sqlite_local_path"]
            let existingHash: String? = row["content_hash"]
            guard let existing = P2JournalState(rawValue: existingRaw) else {
                logger.error("noop: refuse to overwrite unknown existing state '\(existingRaw, privacy: .public)' with '\(state.rawValue, privacy: .public)' for trainingSetId=\(trainingSetId) leaseId=\(leaseId, privacy: .public)")
                return
            }
            if !canApply(new: state, over: existing) {
                logger.info("noop: rejected upsert \(state.rawValue, privacy: .public) over \(existing.rawValue, privacy: .public) for trainingSetId=\(trainingSetId) leaseId=\(leaseId, privacy: .public)")
                return
            }
            try validateInvariants(state: state,
                                   existingPath: existingPath, existingHash: existingHash,
                                   newPath: sqliteLocalPath, newHash: contentHash)
            try update(db, trainingSetId: trainingSetId, leaseId: leaseId,
                       state: state, stateEnteredAt: stateEnteredAt,
                       sqliteLocalPath: sqliteLocalPath, contentHash: contentHash,
                       lastError: lastError)
        } else {
            guard state == .downloaded else {
                throw AppError.internalError(
                    module: "P4-AcceptanceJournalDAO",
                    detail: "first INSERT must be .downloaded; got .\(state.rawValue) for tid=\(trainingSetId) lid=\(leaseId)")
            }
            try validateInvariants(state: state,
                                   existingPath: nil, existingHash: nil,
                                   newPath: sqliteLocalPath, newHash: contentHash)
            try db.execute(sql: """
                INSERT INTO download_acceptance_journal
                  (training_set_id, lease_id, state, state_entered_at,
                   last_error, sqlite_local_path, content_hash)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    trainingSetId, leaseId, state.rawValue, stateEnteredAt,
                    lastError, sqliteLocalPath, contentHash
                ])
        }
    }

    private static func update(_ db: Database,
                               trainingSetId: Int, leaseId: String,
                               state: P2JournalState, stateEnteredAt: Int64,
                               sqliteLocalPath: String?, contentHash: String?,
                               lastError: String?) throws {
        try db.execute(sql: """
            UPDATE download_acceptance_journal
            SET state = ?,
                state_entered_at = ?,
                last_error = COALESCE(?, last_error),
                sqlite_local_path = COALESCE(?, sqlite_local_path),
                content_hash = COALESCE(?, content_hash)
            WHERE training_set_id = ? AND lease_id = ?
            """, arguments: [
                state.rawValue, stateEnteredAt, lastError,
                sqliteLocalPath, contentHash, trainingSetId, leaseId
            ])
    }

    static func listByState(_ db: Database, state: P2JournalState) throws -> [AcceptanceJournalRow] {
        let rows = try Row.fetchAll(db, sql:
            "SELECT * FROM download_acceptance_journal WHERE state = ? ORDER BY id ASC",
            arguments: [state.rawValue])
        return rows.compactMap { row -> AcceptanceJournalRow? in
            do {
                return try journalRowFromRow(row)
            } catch {
                let stateRaw: String = row["state"]
                let tid: Int = row["training_set_id"]
                let lid: String = row["lease_id"]
                logger.error("skip row: unknown state '\(stateRaw, privacy: .public)' tid=\(tid) lid=\(lid, privacy: .public)")
                return nil
            }
        }
    }

    static func deleteByIdLease(_ db: Database, trainingSetId: Int, leaseId: String) throws {
        try db.execute(sql: """
            DELETE FROM download_acceptance_journal
            WHERE training_set_id = ? AND lease_id = ?
            """, arguments: [trainingSetId, leaseId])
    }

    private static func journalRowFromRow(_ row: Row) throws -> AcceptanceJournalRow {
        let stateRaw: String = row["state"]
        guard let state = P2JournalState(rawValue: stateRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        return AcceptanceJournalRow(
            id: row["id"], trainingSetId: row["training_set_id"],
            leaseId: row["lease_id"], state: state,
            stateEnteredAt: row["state_entered_at"],
            lastError: row["last_error"],
            sqliteLocalPath: row["sqlite_local_path"],
            contentHash: row["content_hash"]
        )
    }
}

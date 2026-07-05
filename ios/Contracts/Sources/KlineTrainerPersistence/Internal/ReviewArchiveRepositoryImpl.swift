import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// ReviewArchiveRepository 静态方法实现。review_archive 表 PK=record_id（FK→training_records ON
/// DELETE CASCADE），CHECK((working_step_tick IS NULL) = (working_drawings IS NULL)) 防半行。
/// 镜像 PendingReplayRepositoryImpl。
enum ReviewArchiveRepositoryImpl {

    // 全量：saved/working 列改经 ReviewArchiveWrapper 解码（repo 边界无损），失败 → .dbCorrupted
    // （saved 损坏由 caller 走 clearSaved 恢复）。
    static func loadArchive(_ db: Database, recordId: Int64) throws -> ReviewArchive? {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT record_id, saved_drawings, working_step_tick, working_drawings FROM review_archive WHERE record_id = ?",
            arguments: [recordId]) else { return nil }
        let savedJSON: String? = row["saved_drawings"]
        let workJSON: String? = row["working_drawings"]
        let stepTick: Int? = row["working_step_tick"]
        do {
            let savedWrap = try savedJSON.map { try ReviewArchiveWrapper.decodeColumn($0) }
            let workWrap = try workJSON.map { try ReviewArchiveWrapper.decodeColumn($0) }
            return ReviewArchive(recordId: recordId,
                                 savedLossy: savedWrap?.lossy, savedHiddenIds: savedWrap?.hiddenIds,
                                 workingStepTick: stepTick,
                                 workingLossy: workWrap?.lossy, workingHiddenIds: workWrap?.hiddenIds)
        } catch let e as AppError { throw e } catch { throw AppError.persistence(.dbCorrupted) }
    }

    // 独立解码：只读 + 解码 working 两列（saved 列不 SELECT/不解码）→ saved 损坏不影响本方法。
    static func loadWorking(_ db: Database, recordId: Int64) throws -> ReviewWorking? {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT working_step_tick, working_drawings FROM review_archive WHERE record_id = ?",
            arguments: [recordId]) else { return nil }
        guard let stepTick = row["working_step_tick"] as Int?,
              let workJSON = row["working_drawings"] as String? else { return nil }   // 无 working
        do {
            let wrap = try ReviewArchiveWrapper.decodeColumn(workJSON)
            return ReviewWorking(stepTick: stepTick, lossy: wrap.lossy, hiddenOriginalIds: wrap.hiddenIds)
        } catch let e as AppError { throw e } catch { throw AppError.persistence(.dbCorrupted) }
    }

    // 独立解码：只读 + 解码 saved 列（working 列不碰）→ working 损坏不影响本方法。
    static func loadSaved(_ db: Database, recordId: Int64) throws -> [DrawingObject]? {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT saved_drawings FROM review_archive WHERE record_id = ?", arguments: [recordId]),
              let savedJSON = row["saved_drawings"] as String? else { return nil }
        do { return try ReviewArchiveWrapper.decodeColumn(savedJSON).drawings }
        catch let e as AppError { throw e } catch { throw AppError.persistence(.dbCorrupted) }
    }

    // repo 边界无损（codex plan-R4-high①）：接收完整 lossy（含 unknownRaw 有序），原样保真编码回写，
    // 不从 [DrawingObject] 重建（否则会在下次 save 时丢掉未识别条）。
    static func saveWorking(_ db: Database, recordId: Int64, stepTick: Int,
                            lossy: LossyDrawingArray, hiddenOriginalIds: [DrawingID] = []) throws {
        let json = try ReviewArchiveWrapper(lossy: lossy, hiddenIds: hiddenOriginalIds).encodedColumn()
        // 原子 UPSERT：两 working 列同写，saved 保留（INSERT 时 saved=NULL；已有行时用 ON CONFLICT 只改 working）
        try db.execute(sql: """
            INSERT INTO review_archive (record_id, saved_drawings, working_step_tick, working_drawings, updated_at)
            VALUES (?, NULL, ?, ?, ?)
            ON CONFLICT(record_id) DO UPDATE SET
                working_step_tick = excluded.working_step_tick,
                working_drawings = excluded.working_drawings,
                updated_at = excluded.updated_at
            """, arguments: [recordId, stepTick, json, Self.now()])
    }

    static func commitSaved(_ db: Database, recordId: Int64,
                            lossy: LossyDrawingArray, hiddenOriginalIds: [DrawingID] = []) throws {
        let json = try ReviewArchiveWrapper(lossy: lossy, hiddenIds: hiddenOriginalIds).encodedColumn()
        try db.execute(sql: """
            INSERT INTO review_archive (record_id, saved_drawings, working_step_tick, working_drawings, updated_at)
            VALUES (?, ?, NULL, NULL, ?)
            ON CONFLICT(record_id) DO UPDATE SET
                saved_drawings = excluded.saved_drawings,
                working_step_tick = NULL, working_drawings = NULL,
                updated_at = excluded.updated_at
            """, arguments: [recordId, json, Self.now()])
    }

    static func clearWorking(_ db: Database, recordId: Int64) throws {
        try db.execute(sql: """
            UPDATE review_archive SET working_step_tick = NULL, working_drawings = NULL, updated_at = ?
            WHERE record_id = ?
            """, arguments: [Self.now(), recordId])
        try db.execute(sql: "DELETE FROM review_archive WHERE record_id = ? AND saved_drawings IS NULL",
                       arguments: [recordId])
    }

    static func clearSaved(_ db: Database, recordId: Int64) throws {
        try db.execute(sql: "UPDATE review_archive SET saved_drawings = NULL, updated_at = ? WHERE record_id = ?",
                       arguments: [Self.now(), recordId])
        try db.execute(sql: "DELETE FROM review_archive WHERE record_id = ? AND working_step_tick IS NULL",
                       arguments: [recordId])
    }

    static func loadMarkers(_ db: Database) throws -> [Int64: ReviewMarker] {
        var out: [Int64: ReviewMarker] = [:]
        let rows = try Row.fetchAll(db, sql:
            "SELECT record_id, saved_drawings, working_step_tick FROM review_archive")
        for row in rows {
            let id: Int64 = row["record_id"]
            let hasWorking = (row["working_step_tick"] as Int?) != nil
            let hasSaved = (row["saved_drawings"] as String?) != nil
            let marker: ReviewMarker = hasWorking ? .inProgress : (hasSaved ? .saved : .none)
            if marker != .none { out[id] = marker }   // 全 NULL 异常行不返回
        }
        return out
    }

    static func reviewMarker(_ db: Database, recordId: Int64) throws -> ReviewMarker {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT saved_drawings, working_step_tick FROM review_archive WHERE record_id = ?",
            arguments: [recordId]) else { return .none }
        if (row["working_step_tick"] as Int?) != nil { return .inProgress }
        if (row["saved_drawings"] as String?) != nil { return .saved }
        return .none
    }

    // now(): epoch 秒。updated_at 仅信息列，非核心状态机不变量，故不做时钟注入。
    static func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
}

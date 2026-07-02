import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// P4 应用数据库 composition root。
/// Spec: kline_trainer_modules_v1.4.md §P4 (line 1863-1948)
///
/// 设计要点（plan §Design Decisions §1, §6, §13）：
/// - 单一 DatabaseQueue for app.sqlite（spec L684 单一 queue 串行化约束）
/// - 4 个 protocol surface 用 4 个 extension 分别实现
/// - 所有 GRDB 错误在 extension 边界 `try ... catch` 通过 PersistenceErrorMapping.translate
/// - init 时同步跑 AppDBMigrations.makeMigrator().migrate(queue) → 失败抛 AppError
public final class DefaultAppDB: AppDB, TrainingResetPort, PendingReplayRepository, ReviewArchiveRepository {

    /// 唯一 GRDB queue；所有 4 个 protocol 方法共享。internal 给 same-target tests 看。
    let dbQueue: DatabaseQueue

    /// 创建 / 打开 app.sqlite at `dbPath`，跑 migrator。
    /// throws AppError.persistence(.ioError) 若 GRDB 打开失败 / migrator 跑失败。
    /// throws AppError.persistence(.diskFull) 若磁盘满。
    public init(dbPath: URL) throws {
        do {
            // 父目录可能不存在 → 创建
            let parent = dbPath.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(
                    at: parent, withIntermediateDirectories: true)
            }

            var config = Configuration()
            // foreign_keys 默认 ON：trade_operations / drawings 的 FK 到 training_records 必须强制
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            let queue = try DatabaseQueue(path: dbPath.path, configuration: config)

            // 跑 migrator
            try AppDBMigrations.makeMigrator().migrate(queue)

            self.dbQueue = queue
        } catch let appErr as AppError {
            throw appErr
        } catch {
            // R3 修订（codex med-4）：不传 fileURL —— PersistenceErrorMapping 收到 fileURL+missing
            // 会判 .trainingSet(.fileNotFound)，那是训练组语义；app.sqlite 走 .persistence(.ioError)
            throw PersistenceErrorMapping.translate(error)
        }
    }

    // MARK: - RecordRepository

    public func insertRecord(_ r: TrainingRecord, ops: [TradeOperation],
                             drawings: [DrawingObject]) throws -> Int64 {
        do {
            return try dbQueue.write { db in
                try RecordRepositoryImpl.insertRecord(db, record: r, ops: ops, drawings: drawings)
            }
        } catch let appErr as AppError {
            throw appErr
        } catch {
            throw PersistenceErrorMapping.translate(error)
        }
    }

    public func listRecords(limit: Int?) throws -> [TrainingRecord] {
        do {
            return try dbQueue.read { db in
                try RecordRepositoryImpl.listRecords(db, limit: limit)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func loadRecordBundle(id: Int64) throws -> (TrainingRecord, [TradeOperation], [DrawingObject]) {
        do {
            return try dbQueue.read { db in
                try RecordRepositoryImpl.loadRecordBundle(db, id: id)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func statistics() throws -> (totalCount: Int, winCount: Int, currentCapital: Double) {
        do {
            return try dbQueue.read { db in
                try RecordRepositoryImpl.statistics(db)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    // MARK: - SessionFinalizationPort（Wave 3 顺位 10a，RFC §4.7b）

    /// 单事务：insert record(+ops+drawings, sessionKey 幂等) + 条件清 pending + 派生权威资金。
    /// A4（RFC-A）：事务内从持久记录 `total_capital+profit` 派生权威 `settings.total_capital` 并随成功
    /// 返回 `(id, totalCapital)`（retry 幂等：同 key 重试返当前权威值，不回退）。
    /// dbQueue.write 即事务边界 —— 任一步抛错整体 rollback（要么都成要么都不成）。
    public func finalizeSession(record: TrainingRecord, ops: [TradeOperation],
                                drawings: [DrawingObject], sessionKey: String)
        throws -> (id: Int64, totalCapital: Double) {
        do {
            return try dbQueue.write { db in
                // R-plan-9-1：插入前判定「是否已存在该 sessionKey」——区分「新 finalize」vs「重复重试」。
                let alreadyExisted = try Int64.fetchOne(db, sql:
                    "SELECT id FROM training_records WHERE session_key = ?", arguments: [sessionKey]) != nil
                let id = try RecordRepositoryImpl.insertRecord(
                    db, record: record, ops: ops, drawings: drawings, sessionKey: sessionKey)
                // R-plan-10-1：仅清「属于本次 finalize sessionKey」的 pending（pending_training 单例 id=1，0004 加了
                // session_key）。过期重试 k1 时若当前 pending 是更新的 k2 在飞局 → key 不符 → 不清 → 防误删数据。
                let pendingKey = try String.fetchOne(db, sql:
                    "SELECT session_key FROM pending_training WHERE id = 1")
                if pendingKey == sessionKey {
                    try PendingTrainingRepositoryImpl.clearPending(db)
                }
                if alreadyExisted {
                    // 重复 sessionKey（含「更晚 session 已 finalize 后、旧 session 的过期重试」）：
                    // **不改权威资金**（否则会把 settings.total_capital 回退到旧 session 值）；
                    // 返回**当前**权威 settings 值 → coordinator 缓存刷新为 no-op，不回退。
                    // codex R-plan-12-2/17-1/25-2：本分支 alreadyExisted=true ⇒ 记录已存在 ⇒ 首次 finalize
                    // 必已 setTotalCapital 写过权威值。故此处 total_capital **缺失/畸形/非有限/负** 都属
                    // **不一致 DB 状态**（settings 行丢失/迁移偏差），非「全新安装」→ 一律 fail-closed `.dbCorrupted`
                    // （**不静默兜底 10万**，否则把累积资金悄悄重置回 10万、下局从 10万起、丢弃已结算盈亏）。
                    // 恢复经 SettingsStore.forceResetAndReload→repairAllToDefaults（R-plan-24-1）。
                    let txt = try String.fetchOne(db, sql:
                        "SELECT value FROM settings WHERE key = 'total_capital'")
                    guard let txt, let v = Double(txt), v.isFinite, v >= 0 else {
                        throw AppError.persistence(.dbCorrupted)
                    }
                    return (id, v)
                }
                // 新插入（当前 session 首次 finalize）→ 推进权威资金 = 本记录 total_capital+profit。
                guard let row = try Row.fetchOne(db, sql:
                    "SELECT total_capital, profit FROM training_records WHERE id = ?",
                    arguments: [id]) else {
                    throw AppError.internalError(module: "P4-finalize",
                                                 detail: "persisted record id=\(id) not found")
                }
                let tc: Double = row["total_capital"]
                let p: Double = row["profit"]
                // codex R-plan-13-1（user 拍板：持久化边界 floor）：权威资金不得为负（"不能欠钱"不变量）。
                // 退化局（局终强平 手续费>持仓价值 → currentTotalCapital<0）→ floor 到 0（=破产；记录仍如实记负 profit）。
                let authoritativeCapital = max(0, tc + p)
                try SettingsDAOImpl.setTotalCapital(db, authoritativeCapital)   // setTotalCapital 自带 finite + ≥0 守卫
                return (id, authoritativeCapital)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    // MARK: - PendingTrainingRepository

    public func savePending(_ p: PendingTraining) throws {
        do {
            try dbQueue.write { db in
                try PendingTrainingRepositoryImpl.savePending(db, pending: p)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func loadPending() throws -> PendingTraining? {
        do {
            return try dbQueue.read { db in
                try PendingTrainingRepositoryImpl.loadPending(db)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func clearPending() throws {
        do {
            try dbQueue.write { db in
                try PendingTrainingRepositoryImpl.clearPending(db)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    // MARK: - PendingReplayRepository

    public func saveReplay(_ p: PendingReplay) throws {
        do {
            try dbQueue.write { db in
                try PendingReplayRepositoryImpl.saveReplay(db, replay: p)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func loadReplay() throws -> PendingReplay? {
        do {
            return try dbQueue.read { db in
                try PendingReplayRepositoryImpl.loadReplay(db)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func loadReplaySlotInfo() throws -> ReplaySlotInfo? {
        do {
            return try dbQueue.read { db in
                try PendingReplayRepositoryImpl.loadReplaySlotInfo(db)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func clearReplay() throws {
        do {
            try dbQueue.write { db in
                try PendingReplayRepositoryImpl.clearReplay(db)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func clearReplay(ifRecordId recordId: Int64) throws {
        do {
            try dbQueue.write { db in
                try PendingReplayRepositoryImpl.clearReplay(db, ifRecordId: recordId)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    // MARK: - ReviewArchiveRepository

    public func loadArchive(recordId: Int64) throws -> ReviewArchive? {
        do { return try dbQueue.read { try ReviewArchiveRepositoryImpl.loadArchive($0, recordId: recordId) } }
        catch let e as AppError { throw e } catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func loadWorking(recordId: Int64) throws -> ReviewWorking? {
        do { return try dbQueue.read { try ReviewArchiveRepositoryImpl.loadWorking($0, recordId: recordId) } }
        catch let e as AppError { throw e } catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func loadSaved(recordId: Int64) throws -> [DrawingObject]? {
        do { return try dbQueue.read { try ReviewArchiveRepositoryImpl.loadSaved($0, recordId: recordId) } }
        catch let e as AppError { throw e } catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func saveWorking(recordId: Int64, stepTick: Int, drawings: [DrawingObject]) throws {
        do {
            try dbQueue.write { db in
                try ReviewArchiveRepositoryImpl.saveWorking(db, recordId: recordId, stepTick: stepTick, drawings: drawings)
            }
        } catch let e as AppError { throw e } catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func commitSaved(recordId: Int64, drawings: [DrawingObject]) throws {
        do {
            try dbQueue.write { db in
                try ReviewArchiveRepositoryImpl.commitSaved(db, recordId: recordId, drawings: drawings)
            }
        } catch let e as AppError { throw e } catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func clearWorking(recordId: Int64) throws {
        do { try dbQueue.write { db in try ReviewArchiveRepositoryImpl.clearWorking(db, recordId: recordId) } }
        catch let e as AppError { throw e } catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func clearSaved(recordId: Int64) throws {
        do { try dbQueue.write { db in try ReviewArchiveRepositoryImpl.clearSaved(db, recordId: recordId) } }
        catch let e as AppError { throw e } catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func loadMarkers() throws -> [Int64: ReviewMarker] {
        do { return try dbQueue.read { try ReviewArchiveRepositoryImpl.loadMarkers($0) } }
        catch let e as AppError { throw e } catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func reviewMarker(recordId: Int64) throws -> ReviewMarker {
        do { return try dbQueue.read { try ReviewArchiveRepositoryImpl.reviewMarker($0, recordId: recordId) } }
        catch let e as AppError { throw e } catch { throw PersistenceErrorMapping.translate(error) }
    }

    // MARK: - SettingsDAO

    public func loadSettings() throws -> AppSettings {
        do {
            return try dbQueue.read { db in try SettingsDAOImpl.loadSettings(db) }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func saveSettings(_ s: AppSettings) throws {
        do {
            try dbQueue.write { db in try SettingsDAOImpl.saveSettings(db, settings: s) }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func resetCapital() throws {
        do {
            try dbQueue.write { db in try SettingsDAOImpl.resetCapital(db) }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    /// R-plan-24-1：腐坏恢复——写全部键含 total_capital=默认（override 协议默认，后者经 saveSettings
    /// 修不掉 total_capital，因单写者已豁免该键）。仅 SettingsStore.forceResetAndReload 调用。
    public func repairAllToDefaults() throws {
        do {
            try dbQueue.write { db in try SettingsDAOImpl.repairAllToDefaults(db) }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    // MARK: - TrainingResetPort（重置资金「真正归零重来」，运行时 #1）

    /// 单事务：清 pending + 清 pending_replay + setTotalCapital（**保留**历史记录）。
    /// RFC-A：去掉 deleteAll（推翻 #123），重置只清未完成对局 + 置资金；历史记录保留。
    /// 新需求10(A6)：reset 连带清 pending_replay（无条件清，reset 清全局状态）。
    /// review-redesign：reset 连带清 review_archive 的 working（未完成复盘），**保留** saved（已保存复盘存档）
    /// ——记录本身保留 → 复盘存档也保留；**禁止**整表 DELETE review_archive（会丢已保存复盘）。
    /// dbQueue.write 即事务边界 —— 任一步抛错整体 rollback（要么都成要么都不成）。
    public func resetAllTrainingProgress(toCapital: Double) throws {
        do {
            try dbQueue.write { db in
                try PendingTrainingRepositoryImpl.clearPending(db)
                try PendingReplayRepositoryImpl.clearReplay(db)     // 新需求10(A6)：reset 连带清 replay 槽
                // review-redesign：reset 清未完成复盘（working），保留已保存复盘存档（saved，记录留存 → 复盘留存）
                try db.execute(sql: "UPDATE review_archive SET working_step_tick = NULL, working_drawings = NULL, updated_at = ? WHERE working_step_tick IS NOT NULL",
                               arguments: [Int64(Date().timeIntervalSince1970)])
                try db.execute(sql: "DELETE FROM review_archive WHERE working_step_tick IS NULL AND saved_drawings IS NULL")
                try SettingsDAOImpl.setTotalCapital(db, toCapital)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    // MARK: - AcceptanceJournalDAO

    public func upsert(trainingSetId: Int, leaseId: String, state: P2JournalState,
                       sqliteLocalPath: String?, contentHash: String?,
                       lastError: String?) throws {
        do {
            try dbQueue.write { db in
                try AcceptanceJournalDAOImpl.upsert(
                    db, trainingSetId: trainingSetId, leaseId: leaseId,
                    state: state, sqliteLocalPath: sqliteLocalPath,
                    contentHash: contentHash, lastError: lastError)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func listByState(_ state: P2JournalState) throws -> [AcceptanceJournalRow] {
        do {
            return try dbQueue.read { db in
                try AcceptanceJournalDAOImpl.listByState(db, state: state)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func deleteByIdLease(trainingSetId: Int, leaseId: String) throws {
        do {
            try dbQueue.write { db in
                try AcceptanceJournalDAOImpl.deleteByIdLease(
                    db, trainingSetId: trainingSetId, leaseId: leaseId)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }
}

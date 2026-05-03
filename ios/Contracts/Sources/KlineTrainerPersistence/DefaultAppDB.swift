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
public final class DefaultAppDB: AppDB {

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

    // MARK: - RecordRepository（实现见 RecordRepositoryImpl + Task 4 extension）
    public func insertRecord(_ r: TrainingRecord, ops: [TradeOperation],
                             drawings: [DrawingObject]) throws -> Int64 {
        fatalError("Task 4 实现")
    }
    public func listRecords(limit: Int?) throws -> [TrainingRecord] {
        fatalError("Task 4 实现")
    }
    public func loadRecordBundle(id: Int64) throws -> (TrainingRecord, [TradeOperation], [DrawingObject]) {
        fatalError("Task 4 实现")
    }
    public func statistics() throws -> (totalCount: Int, winCount: Int, currentCapital: Double) {
        fatalError("Task 4 实现")
    }

    // MARK: - PendingTrainingRepository（Task 5）
    public func savePending(_ p: PendingTraining) throws { fatalError("Task 5 实现") }
    public func loadPending() throws -> PendingTraining? { fatalError("Task 5 实现") }
    public func clearPending() throws { fatalError("Task 5 实现") }

    // MARK: - SettingsDAO（Task 6）
    public func loadSettings() throws -> AppSettings { fatalError("Task 6 实现") }
    public func saveSettings(_ s: AppSettings) throws { fatalError("Task 6 实现") }
    public func resetCapital() throws { fatalError("Task 6 实现") }

    // MARK: - AcceptanceJournalDAO（Task 7）
    public func upsert(trainingSetId: Int, leaseId: String, state: P2JournalState,
                       sqliteLocalPath: String?, contentHash: String?,
                       lastError: String?) throws { fatalError("Task 7 实现") }
    public func listByState(_ state: P2JournalState) throws -> [AcceptanceJournalRow] {
        fatalError("Task 7 实现")
    }
    public func deleteByIdLease(trainingSetId: Int, leaseId: String) throws {
        fatalError("Task 7 实现")
    }
}

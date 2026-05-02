import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// P3a Factory 默认实现。每次 openAndVerify 创建独立 read-only DatabaseQueue。
/// 校验顺序（fail-fast）：
/// 1. 文件存在性（GRDB SQLITE_CANTOPEN 翻译）
/// 2. PRAGMA user_version 与 expectedSchemaVersion 一致
/// 3. meta 表至少 1 行（取首行）
/// 通过则返回 DefaultTrainingSetReader，已加载并 cache meta。
///
/// 设计：read closure 内只做 IO 取值（不抛 domain error）；校验逻辑全部在闭包外。
public struct DefaultTrainingSetDBFactory: TrainingSetDBFactory {
    public init() {}

    public func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
        do {
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: file.path, configuration: config)

            // 闭包内只取值，不抛 AppError，避免 GRDB transaction 行为对自定义 error 的处理歧义。
            let (userVersion, meta) = try queue.read { db -> (Int, TrainingSetMeta?) in
                guard let v = try Int.fetchOne(db, sql: "PRAGMA user_version") else {
                    // PRAGMA 永远返回 1 行；nil 表示 db 严重异常。Throw GRDB-level 错误，由外层 catch 翻译。
                    throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "pragma user_version returned nil")
                }
                let row = try Row.fetchOne(db, sql: """
                    SELECT stock_code, stock_name, start_datetime, end_datetime
                    FROM meta LIMIT 1
                    """)
                guard let row else { return (v, nil) }
                let m = TrainingSetMeta(
                    stockCode: row["stock_code"] as String,
                    stockName: row["stock_name"] as String,
                    startDatetime: row["start_datetime"] as Int64,
                    endDatetime: row["end_datetime"] as Int64
                )
                return (v, m)
            }

            // 闭包外做 domain 校验，明确语义
            if userVersion != expectedSchemaVersion {
                throw AppError.trainingSet(.versionMismatch(expected: expectedSchemaVersion, got: userVersion))
            }
            guard let cachedMeta = meta else {
                throw AppError.trainingSet(.emptyData)
            }
            return DefaultTrainingSetReader(queue: queue, cachedMeta: cachedMeta)
        } catch {
            throw PersistenceErrorMapping.translate(error, fileURL: file)
        }
    }
}

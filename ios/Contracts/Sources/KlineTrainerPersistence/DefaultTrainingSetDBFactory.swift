import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// P3a Factory 默认实现。每次 openAndVerify 创建独立 read-only DatabaseQueue。
/// 校验顺序（fail-fast）：
/// 1. 文件存在性（GRDB SQLITE_CANTOPEN 翻译）
/// 2. PRAGMA user_version 与 expectedSchemaVersion 一致
/// 3. meta 表至少 1 行（取首行；通过 MetaRow throwing decode 抗 corrupt rows）
/// 通过则返回 DefaultTrainingSetReader，已加载并 cache meta。
///
/// 设计：read closure 内只做 IO 取值（不抛 AppError）；校验逻辑全部在闭包外。
/// meta 取值用 FetchableRecord + Decodable（per codex round 2 HIGH-1）：
/// 列类型 mismatch / NULL 出现在 NOT NULL 语义列 → 抛 RowDecodingError，
/// 外层 catch 翻译为 AppError.persistence(.dbCorrupted)，不再 fatalError。
public struct DefaultTrainingSetDBFactory: TrainingSetDBFactory {
    public init() {}

    public func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
        do {
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: file.path, configuration: config)

            let (userVersion, metaRow) = try queue.read { db -> (Int, MetaRow?) in
                guard let v = try Int.fetchOne(db, sql: "PRAGMA user_version") else {
                    throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "pragma user_version returned nil")
                }
                let m = try MetaRow.fetchOne(db, sql: """
                    SELECT stock_code, stock_name, start_datetime, end_datetime
                    FROM meta LIMIT 1
                    """)
                return (v, m)
            }

            if userVersion != expectedSchemaVersion {
                throw AppError.trainingSet(.versionMismatch(expected: expectedSchemaVersion, got: userVersion))
            }
            guard let m = metaRow else {
                throw AppError.trainingSet(.emptyData)
            }
            let cachedMeta = TrainingSetMeta(
                stockCode: m.stockCode,
                stockName: m.stockName,
                startDatetime: m.startDatetime,
                endDatetime: m.endDatetime
            )
            return DefaultTrainingSetReader(queue: queue, cachedMeta: cachedMeta)
        } catch {
            throw PersistenceErrorMapping.translate(error, fileURL: file)
        }
    }
}

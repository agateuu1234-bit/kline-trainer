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

            // Phase 1：先校验 user_version，meta SELECT 之前不接触任何 schema-dependent 表
            // （per codex round 5 HIGH-1）：旧 / 新版本文件可能 meta 表已 renamed/missing，
            // 同 closure 内 fallthrough 会先抛 SQLITE_ERROR → 走 .ioError，破坏
            // .versionMismatch 恢复路径。先比对，再读 meta。
            let userVersion: Int = try queue.read { db in
                guard let v = try Int.fetchOne(db, sql: "PRAGMA user_version") else {
                    throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "pragma user_version returned nil")
                }
                return v
            }
            if userVersion != expectedSchemaVersion {
                throw AppError.trainingSet(.versionMismatch(expected: expectedSchemaVersion, got: userVersion))
            }

            // Phase 2：版本对齐后才读 meta（schema-dependent）
            let (metaRow, badTypeCount) = try queue.read { db -> (MetaRow?, Int) in
                // SQL 层 typeof() 校验，绕过 GRDB Decodable 在 TEXT-in-INT 列的 silent coerce-to-0
                // （per codex round 3 HIGH-2）
                let badCount = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM meta
                    WHERE typeof(stock_code) NOT IN ('text','null')
                       OR typeof(stock_name) NOT IN ('text','null')
                       OR typeof(start_datetime) NOT IN ('integer','null')
                       OR typeof(end_datetime) NOT IN ('integer','null')
                    """) ?? 0
                let m = try MetaRow.fetchOne(db, sql: """
                    SELECT stock_code, stock_name, start_datetime, end_datetime
                    FROM meta LIMIT 1
                    """)
                return (m, badCount)
            }

            if badTypeCount > 0 {
                throw AppError.persistence(.dbCorrupted)
            }
            guard let m = metaRow else {
                throw AppError.trainingSet(.emptyData)
            }
            // 边界 sanity check：stockCode / stockName 非空 + startDatetime > 0 + endDatetime ≥ startDatetime
            // （per codex round 3 HIGH-2 — meta 字段语义校验）
            if m.stockCode.isEmpty || m.stockName.isEmpty ||
               m.startDatetime <= 0 || m.endDatetime < m.startDatetime {
                throw AppError.persistence(.dbCorrupted)
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

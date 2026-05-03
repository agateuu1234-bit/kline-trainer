import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// P3b Reader 默认实现。
/// - 持有 var queue: DatabaseQueue?；close 设 nil 触发 ARC 释放（per spec L1848 "释放 DatabaseQueue"）
/// - cached meta 在 init 时已加载，loadMeta O(1)
/// - close 后 read 抛 AppError.internalError（caller 误用，不是 IO 故障）
/// - loadAllCandles row 取值用 throwing decode（per codex round 1 HIGH-2）：
///   列类型不匹配 / NULL 出现在 NOT NULL 列 → 抛 AppError.persistence(.dbCorrupted)，
///   不再 fatalError
public final class DefaultTrainingSetReader: TrainingSetReader, @unchecked Sendable {
    private var queue: DatabaseQueue?
    private let cachedMeta: TrainingSetMeta
    private var isClosed: Bool = false
    private let lock = NSLock()

    init(queue: DatabaseQueue, cachedMeta: TrainingSetMeta) {
        self.queue = queue
        self.cachedMeta = cachedMeta
    }

    public func loadMeta() throws -> TrainingSetMeta {
        try ensureOpen()
        return cachedMeta
    }

    public func loadAllCandles() throws -> [Period: [KLineCandle]] {
        let q = try ensureOpen()
        let kRows: [KLineRow]
        do {
            kRows = try q.read { db in
                // FetchableRecord + Decodable 走 GRDB 内部 throwing decode 路径：
                // 列类型 mismatch / NULL 出现在 NOT NULL 列 → 抛 RowDecodingError，
                // 由外层 catch 翻译为 AppError.persistence(.dbCorrupted)
                try KLineRow.fetchAll(db, sql: """
                SELECT period, datetime, open, high, low, close, volume,
                       amount, ma66, boll_upper, boll_mid, boll_lower,
                       macd_diff, macd_dea, macd_bar, global_index, end_global_index
                FROM klines
                ORDER BY period, end_global_index
                """)
            }
        } catch let app as AppError {
            throw app
        } catch let dbErr as DatabaseError {
            // SQLite IO 错误（缺表 / 损坏 / 权限）走 PersistenceErrorMapping 翻译
            throw PersistenceErrorMapping.translate(dbErr)
        } catch {
            // RowDecodingError / 其它 row decode 异常 → schema 与 data 不一致 = .dbCorrupted
            throw AppError.persistence(.dbCorrupted)
        }

        // 校验 per-period endGlobalIndex 严格递增（per codex round 2 HIGH-2）：
        // SQL 已 ORDER BY period, end_global_index，但 schema 无 UNIQUE 约束；
        // 二分查找 (E5 TrainingEngine) 依赖严格递增，duplicate / non-increasing 会污染步进。
        // Reader 是首道运行时边界，必须 reject malformed training-set file。
        var result: [Period: [KLineCandle]] = [:]
        var lastEnd: [Period: Int] = [:]
        for r in kRows {
            guard let period = Period(rawValue: r.period) else {
                throw AppError.persistence(.dbCorrupted)
            }
            if let prev = lastEnd[period], r.endGlobalIndex <= prev {
                throw AppError.persistence(.dbCorrupted)
            }
            lastEnd[period] = r.endGlobalIndex
            let candle = KLineCandle(
                period: period,
                datetime: r.datetime,
                open: r.open, high: r.high, low: r.low, close: r.close,
                volume: r.volume,
                amount: r.amount,
                ma66: r.ma66,
                bollUpper: r.bollUpper,
                bollMid: r.bollMid,
                bollLower: r.bollLower,
                macdDiff: r.macdDiff,
                macdDea: r.macdDea,
                macdBar: r.macdBar,
                globalIndex: r.globalIndex,
                endGlobalIndex: r.endGlobalIndex
            )
            result[period, default: []].append(candle)
        }
        return result
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        queue = nil  // ARC 释放 GRDB DatabaseQueue
        isClosed = true
    }

    @discardableResult
    private func ensureOpen() throws -> DatabaseQueue {
        lock.lock()
        defer { lock.unlock() }
        guard let q = queue, !isClosed else {
            throw AppError.internalError(module: "P3b", detail: "reader closed")
        }
        return q
    }
}

import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// P3b Reader 默认实现。
/// - 持有 var queue: DatabaseQueue?；close 设 nil 触发 ARC 释放（per spec L1848 "释放 DatabaseQueue"）
/// - cached meta 在 init 时已加载，loadMeta O(1)
/// - close 后 read 抛 AppError.internalError（caller 误用，不是 IO 故障）
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
        do {
            let rows = try q.read { db in
                try Row.fetchAll(db, sql: """
                SELECT period, datetime, open, high, low, close, volume,
                       amount, ma66, boll_upper, boll_mid, boll_lower,
                       macd_diff, macd_dea, macd_bar, global_index, end_global_index
                FROM klines
                ORDER BY period, end_global_index
                """)
            }
            var result: [Period: [KLineCandle]] = [:]
            for row in rows {
                let rawPeriod: String = row["period"]
                guard let period = Period(rawValue: rawPeriod) else {
                    throw AppError.persistence(.dbCorrupted)
                }
                let candle = KLineCandle(
                    period: period,
                    datetime: row["datetime"] as Int64,
                    open: row["open"] as Double,
                    high: row["high"] as Double,
                    low: row["low"] as Double,
                    close: row["close"] as Double,
                    volume: row["volume"] as Int64,
                    amount: row["amount"] as Double?,
                    ma66: row["ma66"] as Double?,
                    bollUpper: row["boll_upper"] as Double?,
                    bollMid: row["boll_mid"] as Double?,
                    bollLower: row["boll_lower"] as Double?,
                    macdDiff: row["macd_diff"] as Double?,
                    macdDea: row["macd_dea"] as Double?,
                    macdBar: row["macd_bar"] as Double?,
                    globalIndex: row["global_index"] as Int?,
                    endGlobalIndex: row["end_global_index"] as Int
                )
                result[period, default: []].append(candle)
            }
            return result
        } catch {
            throw PersistenceErrorMapping.translate(error)
        }
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

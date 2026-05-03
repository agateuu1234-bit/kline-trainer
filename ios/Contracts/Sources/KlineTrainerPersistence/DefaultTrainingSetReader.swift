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
                // SQL 层 typeof() 校验，绕过 GRDB Decodable 在 TEXT-in-INT/REAL 列的 silent
                // coerce-to-0/0.0（per codex round 4 HIGH-1，与 meta 同模式）：
                // klines 关键 NOT NULL 列必须 storage class 严格匹配 schema affinity。
                let badCount = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM klines
                    WHERE typeof(period) NOT IN ('text','null')
                       OR typeof(datetime) NOT IN ('integer','null')
                       OR typeof(open) NOT IN ('real','integer','null')
                       OR typeof(high) NOT IN ('real','integer','null')
                       OR typeof(low) NOT IN ('real','integer','null')
                       OR typeof(close) NOT IN ('real','integer','null')
                       OR typeof(volume) NOT IN ('integer','null')
                       OR typeof(end_global_index) NOT IN ('integer','null')
                       OR typeof(global_index) NOT IN ('integer','null')
                       OR typeof(amount) NOT IN ('real','integer','null')
                       OR typeof(ma66) NOT IN ('real','integer','null')
                       OR typeof(boll_upper) NOT IN ('real','integer','null')
                       OR typeof(boll_mid) NOT IN ('real','integer','null')
                       OR typeof(boll_lower) NOT IN ('real','integer','null')
                       OR typeof(macd_diff) NOT IN ('real','integer','null')
                       OR typeof(macd_dea) NOT IN ('real','integer','null')
                       OR typeof(macd_bar) NOT IN ('real','integer','null')
                    """) ?? 0
                if badCount > 0 {
                    throw AppError.persistence(.dbCorrupted)
                }
                // FetchableRecord + Decodable 走 GRDB 内部 throwing decode 路径：
                // 列类型 mismatch / NULL 出现在 NOT NULL 列 → 抛 RowDecodingError，
                // 由外层 catch 翻译为 AppError.persistence(.dbCorrupted)
                return try KLineRow.fetchAll(db, sql: """
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
            // OHLC 语义校验（per codex round 6 HIGH）：finite + positive + 序关系 + nonnegative volume/amount
            // + 可选指标 finite。下游 Geometry.PriceRange.calculate 假定正价，
            // 0 价 / low > high / NaN 会让坐标映射 division-by-zero / NaN 渲染。
            guard r.open.isFinite, r.open > 0,
                  r.high.isFinite, r.high > 0,
                  r.low.isFinite, r.low > 0,
                  r.close.isFinite, r.close > 0,
                  r.high >= max(r.open, r.close, r.low),
                  r.low <= min(r.open, r.close, r.high),
                  r.volume >= 0 else {
                throw AppError.persistence(.dbCorrupted)
            }
            // 可选指标 finite + amount nonnegative
            for opt in [r.amount, r.ma66, r.bollUpper, r.bollMid, r.bollLower,
                        r.macdDiff, r.macdDea, r.macdBar] {
                if let v = opt, !v.isFinite {
                    throw AppError.persistence(.dbCorrupted)
                }
            }
            if let a = r.amount, a < 0 {
                throw AppError.persistence(.dbCorrupted)
            }
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

        // 非 m3 endGlobalIndex 非负校验（per codex round 4 MEDIUM）— 提到 m3 if 外，
        // m3 missing 不影响这层基础 invariant：endGlobalIndex 恒非负。
        for (period, candles) in result where period != .m3 {
            for c in candles {
                if c.endGlobalIndex < 0 {
                    throw AppError.persistence(.dbCorrupted)
                }
            }
        }

        // .m3 是最小周期 = 全局 tick 轴（per codex round 3 HIGH-1 + round 4 MEDIUM
        // + spec L2242 "global_index/end_global_index 严格递增 + 前后端 assert"）：
        // - 每根 m3 candle 必须 globalIndex == endGlobalIndex（同一根 K 线起止索引相等）
        // - m3 globalIndex 必须从 0 开始严格递增 0,1,2,...（无 gap、无 nil）
        // - 其它周期的 endGlobalIndex 必须落在 m3 范围内（不超过 m3 最大 endGlobalIndex）
        // 任一不变量违反 → .dbCorrupted。
        // m3 missing 但 result 非空（只有高周期数据）= 真 corrupt（无 global axis 锚点）→ reject。
        // m3 missing 且 result 全空（整库无 candles）= plan §4 允许，返回空字典让 caller 处理。
        if let m3Candles = result[.m3] {
            for (i, c) in m3Candles.enumerated() {
                guard let g = c.globalIndex,
                      g == c.endGlobalIndex,
                      g == i else {
                    throw AppError.persistence(.dbCorrupted)
                }
            }
            let m3Max = m3Candles.last?.endGlobalIndex ?? -1
            for (period, candles) in result where period != .m3 {
                for c in candles {
                    if c.endGlobalIndex > m3Max {
                        throw AppError.persistence(.dbCorrupted)
                    }
                }
            }
        } else if !result.isEmpty {
            // 高周期数据存在但无 m3 = 缺全局 tick 轴锚点
            throw AppError.persistence(.dbCorrupted)
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

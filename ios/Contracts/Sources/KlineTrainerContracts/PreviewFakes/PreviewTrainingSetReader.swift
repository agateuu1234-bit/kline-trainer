// Kline Trainer Swift Contracts — Preview/Test Fixture: P3b TrainingSetReader fake
// Spec: kline_trainer_modules_v1.4.md §11.3 line 2200 (PreviewTrainingSetDBFactory + PreviewTrainingSetReader)
//       protocol 体 §P3b line 1840-1856
// R2 修订（codex round-2 high-1）：mirror DefaultTrainingSetReader 的 isClosed + ensureOpen
//       (KlineTrainerPersistence/DefaultTrainingSetReader.swift line 15-16, 184-191)
// R3 修订（codex round-3 high-1）：mirror DefaultTrainingSetReader.loadAllCandles 全套数据校验
//       (KlineTrainerPersistence/DefaultTrainingSetReader.swift line 84-173)
//       维护契约：production validateCandles 改了 → 这里同步改。
// persistence-scope RFC：mirror 校验 1（.m3 datetime 严格递增）+ 校验 2（聚合 open 落窗口）
// fake 不持有 DatabaseQueue，但必须镜像 close-then-read = throw + data invariants 才能让
// consumer 的 "reader 返回 = 已校验" 假设在测试和生产都成立。

#if DEBUG

import Foundation

public final class PreviewTrainingSetReader: TrainingSetReader, @unchecked Sendable {
    private let meta: TrainingSetMeta
    private let candles: [Period: [KLineCandle]]
    private var isClosed: Bool = false
    private let lock = NSLock()

    // R5 修订（codex round-5 med-2）：mirror production DefaultTrainingSetReader.init 是 internal。
    // 唯一公开构造路径 = PreviewTrainingSetDBFactory.openAndVerify（已含 validateMeta）。
    // 单测可通过 @testable import KlineTrainerContracts 拿 internal 访问。
    init(meta: TrainingSetMeta, candles: [Period: [KLineCandle]]) {
        self.meta = meta
        self.candles = candles
    }

    public func loadMeta() throws -> TrainingSetMeta {
        try ensureOpen()
        return meta
    }

    public func loadAllCandles() throws -> [Period: [KLineCandle]] {
        try ensureOpen()
        try Self.validateCandles(candles)
        return candles
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        isClosed = true
    }

    private func ensureOpen() throws {
        lock.lock(); defer { lock.unlock() }
        if isClosed {
            throw AppError.internalError(
                module: "PR5a-PreviewTrainingSetReader",
                detail: "reader closed")
        }
    }

    /// mirror of DefaultTrainingSetReader.loadAllCandles validation (line 84-173)
    /// 任一不变量违反 → AppError.persistence(.dbCorrupted)
    private static func validateCandles(_ data: [Period: [KLineCandle]]) throws {
        // 1) per-period strictly increasing endGlobalIndex（line 90-93）
        // 2) OHLC finite + positive + 序关系 + volume nonneg（line 97-105）
        // 3) optional indicator finite + amount nonneg（line 107-115）
        // R4 修订（codex round-4 med-1）：候选 c.period 必须 == dict key
        // production result[period, default:].append(candle) 用同一 row.period 构造 → 必然一致
        for (period, list) in data {
            var lastEnd: Int? = nil
            for c in list {
                guard c.period == period else {
                    throw AppError.persistence(.dbCorrupted)
                }
                if let prev = lastEnd, c.endGlobalIndex <= prev {
                    throw AppError.persistence(.dbCorrupted)
                }
                lastEnd = c.endGlobalIndex

                guard c.open.isFinite, c.open > 0,
                      c.high.isFinite, c.high > 0,
                      c.low.isFinite, c.low > 0,
                      c.close.isFinite, c.close > 0,
                      c.high >= max(c.open, c.close, c.low),
                      c.low <= min(c.open, c.close, c.high),
                      c.volume >= 0 else {
                    throw AppError.persistence(.dbCorrupted)
                }
                for opt in [c.amount, c.ma66, c.bollUpper, c.bollMid, c.bollLower,
                            c.macdDiff, c.macdDea, c.macdBar] {
                    if let v = opt, !v.isFinite {
                        throw AppError.persistence(.dbCorrupted)
                    }
                }
                if let a = c.amount, a < 0 {
                    throw AppError.persistence(.dbCorrupted)
                }
            }
            // 非 m3 endGlobalIndex 非负（line 137-143）
            if period != .m3 {
                for c in list {
                    if c.endGlobalIndex < 0 {
                        throw AppError.persistence(.dbCorrupted)
                    }
                }
            }
        }
        // 4) m3 global-axis invariants（line 153-160）+ 非 m3 ≤ m3Max（line 162-168）
        // 5) 非空 result 但缺 m3 → corrupt（line 169-172）
        if let m3 = data[.m3] {
            for (i, c) in m3.enumerated() {
                guard let g = c.globalIndex,
                      g == c.endGlobalIndex,
                      g == i else {
                    throw AppError.persistence(.dbCorrupted)
                }
            }
            // 校验 1（persistence-scope RFC，镜像 DefaultTrainingSetReader）：.m3 datetime 严格递增。
            for i in m3.indices.dropFirst() {
                guard m3[i].datetime > m3[i - 1].datetime else {
                    throw AppError.persistence(.dbCorrupted)
                }
            }
            let m3Max = m3.last?.endGlobalIndex ?? -1
            for (period, list) in data where period != .m3 {
                for c in list {
                    if c.endGlobalIndex > m3Max {
                        throw AppError.persistence(.dbCorrupted)
                    }
                }
            }
            // 校验 2（persistence-scope RFC，镜像 DefaultTrainingSetReader）：聚合 open 落 endGlobalIndex 窗口。
            for (period, list) in data where period != .m3 {
                for c in list {
                    let s = m3.partitioningIndex { $0.datetime >= c.datetime }
                    guard s <= c.endGlobalIndex else {
                        throw AppError.persistence(.dbCorrupted)
                    }
                }
            }
        } else if !data.isEmpty {
            throw AppError.persistence(.dbCorrupted)
        }
    }
}

#endif

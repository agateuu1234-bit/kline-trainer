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
        // Task 4 实现
        _ = try ensureOpen()
        return [:]
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

// Kline Trainer Swift Contracts — M0.4 Error Handling
// Spec: kline_trainer_modules_v1.4.md §M0.4
//
// 顶层错误类型 AppError + 4 个 Reason 子枚举。全部值类型，Error + Equatable + Sendable。
// 设计原则（M0.4 spec 重写）：**私有错误在本模块边界内转 AppError，调用方只消费 AppError**。
// 各模块（P1/P3/P4/E3/P2/UI）如何翻译自己的内部错误到 AppError 属模块实现约束，归各自
// module plan（Plan 2/3）落地；本 plan 只冻结 AppError 类型体 + 3 个 UI 扩展方法。

import Foundation

public enum AppError: Error, Equatable, Sendable {
    case network(NetworkReason)
    case persistence(PersistenceReason)
    case trade(TradeReason)
    case trainingSet(TrainingSetReason)
    /// internalError 强制标识来源模块 + detail 消息。
    /// CI lint 规则（未来 governance 层实现）：`.internalError` 仅当错误无法归入前 4 类时允许。
    case internalError(module: String, detail: String)
}

public enum NetworkReason: Error, Equatable, Sendable {
    case timeout
    case offline
    case serverError(code: Int)
    case leaseExpired
    case leaseNotFound
}

public enum PersistenceReason: Error, Equatable, Sendable {
    case diskFull
    case dbCorrupted
    case schemaMismatch(expected: Int, got: Int)
    case ioError(String)
}

public enum TradeReason: Error, Equatable, Sendable {
    case insufficientCash
    case insufficientHolding
    case disabled
    case invalidShareCount
}

public enum TrainingSetReason: Error, Equatable, Sendable {
    case crcFailed
    case unzipFailed
    case emptyData
    case versionMismatch(expected: Int, got: Int)
    case fileNotFound
}

// Kline Trainer Swift Contracts — PR5b P2 内部端口 Fakes
// Spec: kline_trainer_modules_v1.4.md §11.3 #7-#10 (line 2202-2205)
//
// 4 个 stateless behavior stub，覆盖 P2 4 内部端口（spec §P2 line 1751-1775）。
// 每个 fake 的设计哲学：spec L2202 措辞 "固定返回 OK / 失败" = 配置型 stub，
// 不是 stateful in-memory（与 P4 InMemoryRecordRepository 等 round-trip fake 对比）。
//
// **接口形状**：
// - `init(throwing: AppError? = nil)`：`nil` = success / no-op；非 nil = 该 method 抛该错
// - `FakeZipExtractor` 额外接 `returnURL`（protocol 签名要求返回 URL）
// - `FakeDownloadAcceptanceCleaner` 记录调用列表（production cleanup 不抛、不返回值，
//   唯一可观测点是「被调用了什么 URL」；其它 3 fake 的 throws 路径已是可断言信号）
//
// **不镜像**（不属本 fake 范畴）：
// - NSError → AppError 翻译细节（production internal logic，由 ZipErrorMapping / CacheErrorMapping 测）
// - production 严格 zip shape 校验（exactly 1 sqlite file 等；fake caller 关心的是 throw 与否，不关心翻译路径）

#if DEBUG

import Foundation

// MARK: - P2 port 1 fake

public struct FakeZipIntegrityVerifier: ZipIntegrityVerifying {
    private let throwing: AppError?

    public init(throwing: AppError? = nil) {
        self.throwing = throwing
    }

    public func verify(zipURL: URL, expectedCRC32Hex: String) throws {
        if let err = throwing { throw err }
    }
}

// MARK: - P2 port 2 fake

public struct FakeZipExtractor: ZipExtracting {
    private let throwing: AppError?
    private let returnURL: URL

    public init(returnURL: URL = URL(fileURLWithPath: "/tmp/fake.sqlite"),
                throwing: AppError? = nil) {
        self.returnURL = returnURL
        self.throwing = throwing
    }

    public func extract(zipURL: URL) throws -> URL {
        if let err = throwing { throw err }
        return returnURL
    }
}

// MARK: - P2 port 3 fake

public struct FakeTrainingSetDataVerifier: TrainingSetDataVerifying {
    private let throwing: AppError?

    public init(throwing: AppError? = nil) {
        self.throwing = throwing
    }

    public func verifyNonEmpty(reader: TrainingSetReader) throws {
        if let err = throwing { throw err }
    }
}

// MARK: - P2 port 4 fake (recording)

/// 记录所有 `cleanup` 调用的 URL 顺序，用于测试断言「runner 是否在状态机分支中正确清理临时文件」。
/// production `DefaultDownloadAcceptanceCleaner` 不抛、不返回值——recording 是 fake 唯一观测点。
public final class FakeDownloadAcceptanceCleaner: DownloadAcceptanceCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private var _cleanedURLs: [URL] = []

    public init() {}

    public func cleanup(tempURLs: [URL]) {
        lock.lock(); defer { lock.unlock() }
        _cleanedURLs.append(contentsOf: tempURLs)
    }

    /// 按 cleanup 调用顺序展开的 URL 列表（多次调用平铺）。
    public func cleanedURLs() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return _cleanedURLs
    }
}

#endif

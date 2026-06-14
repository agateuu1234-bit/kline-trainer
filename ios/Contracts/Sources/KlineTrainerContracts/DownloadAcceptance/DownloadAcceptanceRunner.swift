// Kline Trainer Swift Contracts — P2 DownloadAcceptanceRunner（Wave 2 顺位 6）
// Spec: kline_trainer_modules_v1.4.md §P2 (line 1761-1836) + M0.1 journal (230-300)
//
// 纯编排：注入 8 个依赖 = 4 内部端口（ZipIntegrityVerifying/ZipExtracting/TrainingSetDataVerifying/DownloadAcceptanceCleaning）
//         + P1 APIClient + P5 CacheManager + P3a TrainingSetDBFactory + P4 AcceptanceJournalDAO，
//         按 7 步 journal 状态机驱动；
// 提供 run / runBatch / retryPendingConfirmations（启动孤儿确认恢复）。
// 错误边界（M0.4 L659）：不接触私有错误，只消费 AppError。

import Foundation

/// 客户端可读的训练组 sqlite schema 版本（M0.1 共享常量，spec §11.3 L2202）。
/// 本 PR 是该常量的唯一定义点；P3a / 其它模块 import 复用，勿重复定义。
public let TRAINING_SET_SCHEMA_VERSION = 1

/// 下载验收的同步结果（spec §P2 L1764-1767）。
/// 注：`.rejected` 同时覆盖「服务端明确拒收(409/404)」与「网络不确定」两种结局——
/// 区别在 journal 状态 + 是否删本地文件，不在 return type（详见 plan 关键决策 5）。
public enum AcceptanceResult: Equatable, Sendable {
    case confirmed(TrainingSetFile)
    case rejected(AppError)
}

public final class DownloadAcceptanceRunner: Sendable {
    private let api: any APIClient
    private let cache: any CacheManager
    private let dbFactory: any TrainingSetDBFactory
    private let journal: any AcceptanceJournalDAO
    private let integrity: any ZipIntegrityVerifying
    private let extractor: any ZipExtracting
    private let dataVerifier: any TrainingSetDataVerifying
    private let cleaner: any DownloadAcceptanceCleaning

    public init(api: any APIClient,
                cache: any CacheManager,
                dbFactory: any TrainingSetDBFactory,
                journal: any AcceptanceJournalDAO,
                integrity: any ZipIntegrityVerifying,
                extractor: any ZipExtracting,
                dataVerifier: any TrainingSetDataVerifying,
                cleaner: any DownloadAcceptanceCleaning) {
        self.api = api
        self.cache = cache
        self.dbFactory = dbFactory
        self.journal = journal
        self.integrity = integrity
        self.extractor = extractor
        self.dataVerifier = dataVerifier
        self.cleaner = cleaner
    }

    public func run(meta: TrainingSetMetaItem, leaseId: String) async -> AcceptanceResult {
        // Step 1：下载 zip（download 完成前不写 journal 行——spec L1820 step 0/1）
        let zipURL: URL
        do {
            zipURL = try await api.downloadTrainingSet(id: meta.id)
        } catch {
            return .rejected(Self.asAppError(error))   // 网络失败，无 journal 行
        }

        var tempURLs: [URL] = [zipURL]
        do {
            // 首条 journal 行 .downloaded
            try journal.upsert(trainingSetId: meta.id, leaseId: leaseId, state: .downloaded,
                               sqliteLocalPath: nil, contentHash: nil, lastError: nil)

            // Step 2：CRC32
            try integrity.verify(zipURL: zipURL, expectedCRC32Hex: meta.contentHash)
            try journal.upsert(trainingSetId: meta.id, leaseId: leaseId, state: .crcOK,
                               sqliteLocalPath: nil, contentHash: nil, lastError: nil)

            // Step 3：解压（解压临时目录 = sqlite 的父目录，纳入清理）
            let sqliteURL = try extractor.extract(zipURL: zipURL)
            tempURLs.append(sqliteURL.deletingLastPathComponent())
            try journal.upsert(trainingSetId: meta.id, leaseId: leaseId, state: .unzipped,
                               sqliteLocalPath: nil, contentHash: nil, lastError: nil)

            // Step 4+5：openAndVerify + verifyNonEmpty（reader 在 cache.store/cleanup 前关闭）
            do {
                let reader = try dbFactory.openAndVerify(file: sqliteURL,
                                                         expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
                defer { reader.close() }
                try journal.upsert(trainingSetId: meta.id, leaseId: leaseId, state: .dbVerified,
                                   sqliteLocalPath: nil, contentHash: nil, lastError: nil)
                try dataVerifier.verifyNonEmpty(reader: reader)   // 保持 dbVerified
            }

            // Step 6：把**解压后的 sqlite** 存入 cache。
            // ⚠️ store 参数名 downloadedZip 是误导名——store 期望的是已解压 sqlite（内部开 DatabaseQueue 读 PRAGMA），
            // 不是 zip。故传 sqliteURL。详见 plan 决策 6。
            let file = try cache.store(downloadedZip: sqliteURL, meta: meta)
            try journal.upsert(trainingSetId: meta.id, leaseId: leaseId, state: .stored,
                               sqliteLocalPath: file.localURL.path, contentHash: meta.contentHash,
                               lastError: nil)

            // Step 7：confirm（stored → confirmPending → confirmed/rejected/停留）
            let outcome = await attemptConfirm(trainingSetId: meta.id, leaseId: leaseId,
                                               sqliteLocalPath: file.localURL.path)
            cleaner.cleanup(tempURLs: tempURLs)   // 清 temp zip + 解压目录（非 cache 副本）
            switch outcome {
            case .confirmed:
                return .confirmed(file)
            case .rejected(let e):                // 409/404 → 删本地 cache 副本
                try? cache.delete(file)
                return .rejected(e)
            case .pending(let e):                 // 网络不确定 → 保留 cache 副本待重试
                return .rejected(e)
            }
        } catch {
            let appErr = Self.asAppError(error)
            try? journal.upsert(trainingSetId: meta.id, leaseId: leaseId, state: .rejected,
                                sqliteLocalPath: nil, contentHash: nil, lastError: appErr.userMessage)
            cleaner.cleanup(tempURLs: tempURLs)
            return .rejected(appErr)
        }
    }

    public func runBatch(lease: LeaseResponse, concurrency: Int = 1) async -> [AcceptanceResult] {
        let sets = lease.sets
        guard !sets.isEmpty else { return [] }
        let limit = min(max(1, concurrency), sets.count)
        let leaseId = lease.leaseId
        var results = [AcceptanceResult?](repeating: nil, count: sets.count)

        await withTaskGroup(of: (Int, AcceptanceResult).self) { group in
            var next = 0
            // 初始注入至多 limit 个任务
            while next < limit {
                let i = next
                group.addTask { (i, await self.run(meta: sets[i], leaseId: leaseId)) }
                next += 1
            }
            // 完成一个补一个，维持在飞 ≤ limit
            while let (idx, res) = await group.next() {
                results[idx] = res
                if next < sets.count {
                    let i = next
                    group.addTask { (i, await self.run(meta: sets[i], leaseId: leaseId)) }
                    next += 1
                }
            }
        }
        // 每个 index 恰好被一个任务填充一次 → 全非 nil（force-unwrap 安全）。
        return results.map { $0! }
    }

    public func retryPendingConfirmations() async {
        let stored = (try? journal.listByState(.stored)) ?? []
        let pending = (try? journal.listByState(.confirmPending)) ?? []
        for row in stored + pending {
            let outcome = await attemptConfirm(trainingSetId: row.trainingSetId,
                                               leaseId: row.leaseId,
                                               sqliteLocalPath: row.sqliteLocalPath)
            if case .rejected = outcome {        // 409/404 → 清本地 cache 副本
                if let file = cache.listAvailable().first(where: { $0.id == row.trainingSetId }) {
                    try? cache.delete(file)
                }
            }
            // confirmed / pending：journal 已更新；pending 保留文件
        }
    }

    // MARK: - confirm 子状态机（run + retry 共用）

    private enum ConfirmOutcome { case confirmed; case rejected(AppError); case pending(AppError) }

    /// 先标 confirmPending（状态机要求 + 崩溃安全），再调 confirm。
    /// 成功 → confirmed；409/404 → rejected；其余 → 停留 confirmPending。
    private func attemptConfirm(trainingSetId: Int, leaseId: String,
                                sqliteLocalPath: String?) async -> ConfirmOutcome {
        try? journal.upsert(trainingSetId: trainingSetId, leaseId: leaseId, state: .confirmPending,
                            sqliteLocalPath: sqliteLocalPath, contentHash: nil, lastError: nil)
        do {
            try await api.confirmTrainingSet(id: trainingSetId, leaseId: leaseId)
            try? journal.upsert(trainingSetId: trainingSetId, leaseId: leaseId, state: .confirmed,
                                sqliteLocalPath: sqliteLocalPath, contentHash: nil, lastError: nil)
            return .confirmed
        } catch {
            let e = Self.asAppError(error)
            switch e {
            case .network(.leaseExpired), .network(.leaseNotFound):
                try? journal.upsert(trainingSetId: trainingSetId, leaseId: leaseId, state: .rejected,
                                    sqliteLocalPath: nil, contentHash: nil, lastError: e.userMessage)
                return .rejected(e)
            default:
                return .pending(e)   // 停留 confirmPending；本地文件保留
            }
        }
    }

    /// 边界翻译：上游协议已 throws AppError；DefaultAPIClient 协作取消重抛 CancellationError → 标 P2 内部。
    private static func asAppError(_ error: Error) -> AppError {
        if let e = error as? AppError { return e }
        if error is CancellationError { return .internalError(module: "P2", detail: "cancelled") }
        return .internalError(module: "P2", detail: "unexpected")
    }
}

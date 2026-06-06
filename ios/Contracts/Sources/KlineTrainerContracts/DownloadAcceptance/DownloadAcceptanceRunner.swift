// Kline Trainer Swift Contracts — P2 DownloadAcceptanceRunner（Wave 2 顺位 6）
// Spec: kline_trainer_modules_v1.4.md §P2 (line 1761-1836) + M0.1 journal (230-300)
//
// 纯编排：只依赖协议（P1/P5/P3a/P4-journal + 4 内部端口），按 7 步 journal 状态机驱动；
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
        fatalError("Task 2")
    }

    public func runBatch(lease: LeaseResponse, concurrency: Int = 1) async -> [AcceptanceResult] {
        fatalError("Task 6")
    }

    public func retryPendingConfirmations() async {
        fatalError("Task 5")
    }
}

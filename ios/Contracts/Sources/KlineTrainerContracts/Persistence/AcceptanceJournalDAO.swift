// Kline Trainer Swift Contracts — P4 AcceptanceJournalDAO
// Spec: kline_trainer_modules_v1.4.md §P4 (line 1891-1931)
//       kline_trainer_modules_v1.4.md §M0.1 download_acceptance_journal (line 230-289)

import Foundation

// MARK: - Journal state enum（v1.4 删 leased，per spec L250-262）

public enum P2JournalState: String, Codable, Equatable, Sendable, CaseIterable {
    case downloaded         // zip 下载完成（v1.4 首条 journal 行起点）
    case crcOK              // CRC32 校验通过
    case unzipped           // 解压完成
    case dbVerified         // 训练组 SQLite 校验通过（P3a openAndVerify）
    case stored             // 已存入 cache，可被 P5 选中
    case confirmPending     // 等待 server confirm；崩溃恢复扫描点之一
    case confirmed          // server 确认成功
    case rejected           // server 拒收 / 本地校验失败
}

// MARK: - Row 投影类型（DAO 读出的不可变快照）

public struct AcceptanceJournalRow: Equatable, Sendable {
    public let id: Int64
    public let trainingSetId: Int
    public let leaseId: String
    public let state: P2JournalState
    public let stateEnteredAt: Int64        // Unix 秒 UTC（per spec L241）
    public let lastError: String?
    public let sqliteLocalPath: String?
    public let contentHash: String?         // CRC32 hex（M0.1 CHAR(8)）

    public init(
        id: Int64, trainingSetId: Int, leaseId: String,
        state: P2JournalState, stateEnteredAt: Int64,
        lastError: String?, sqliteLocalPath: String?, contentHash: String?
    ) {
        self.id = id
        self.trainingSetId = trainingSetId
        self.leaseId = leaseId
        self.state = state
        self.stateEnteredAt = stateEnteredAt
        self.lastError = lastError
        self.sqliteLocalPath = sqliteLocalPath
        self.contentHash = contentHash
    }
}

// MARK: - Protocol surface

public protocol AcceptanceJournalDAO: Sendable {
    /// 按 (training_set_id, lease_id) upsert 状态。state_entered_at 由实现侧 stamp。
    func upsert(trainingSetId: Int, leaseId: String,
                state: P2JournalState,
                sqliteLocalPath: String?,
                contentHash: String?,
                lastError: String?) throws

    /// 列出指定 state 的全部行（App 启动扫 stored / confirmPending）。
    func listByState(_ state: P2JournalState) throws -> [AcceptanceJournalRow]

    /// 清理指定 (training_set_id, lease_id) 行（rejected 终态后或外部 GC 触发）。0 行删除合法。
    func deleteByIdLease(trainingSetId: Int, leaseId: String) throws
}

// MARK: - Composition root typealias（spec L1931）

public typealias AppDB = RecordRepository
                      & PendingTrainingRepository
                      & SettingsDAO
                      & AcceptanceJournalDAO
                      & SessionFinalizationPort

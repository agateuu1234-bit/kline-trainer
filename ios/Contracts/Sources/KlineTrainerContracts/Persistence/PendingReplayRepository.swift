// PendingReplayRepository.swift
// replay 续局单槽仓储（新需求10）。镜像 PendingTrainingRepository（sync throws，不得 async——
// autosave 协程 coalescing/fence 不变量依赖 save 同步，见 TrainingSessionCoordinator.swift:87-90）。

public protocol PendingReplayRepository: Sendable {
    func saveReplay(_: PendingReplay) throws
    func loadReplay() throws -> PendingReplay?
    /// 轻量元数据（只读 record_id/training_set_filename，**不解码 payload**）。codex plan-R11-F1：
    /// resume-first 用它先判槽归属，避免别记录的损坏 payload 阻塞所有 replay 入口。
    func loadReplaySlotInfo() throws -> ReplaySlotInfo?
    func clearReplay() throws                       // 无条件（reset 用）
    func clearReplay(ifRecordId: Int64) throws      // 仅当槽属于该记录才清（终局/discard 用，codex plan-R3-F1）
}

public struct ReplaySlotInfo: Equatable, Sendable {
    public let recordId: Int64
    public let trainingSetFilename: String
    public init(recordId: Int64, trainingSetFilename: String) {
        self.recordId = recordId
        self.trainingSetFilename = trainingSetFilename
    }
}

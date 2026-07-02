// ReviewArchiveRepository.swift
// 复盘存档单记录仓储（review-redesign RFC，v1.9）。镜像 PendingReplayRepository（sync throws，
// 不得 async——理由同 pendingReplayRepo：coordinator autosave/复盘持久化不变量依赖同步 GRDB 写）。

public enum ReviewMarker: Equatable, Sendable {
    case none, inProgress, saved
}

public struct ReviewArchive: Equatable, Sendable {
    public let recordId: Int64
    public let savedDrawings: [DrawingObject]?
    public let workingStepTick: Int?
    public let workingDrawings: [DrawingObject]?

    public init(recordId: Int64, savedDrawings: [DrawingObject]?,
                workingStepTick: Int?, workingDrawings: [DrawingObject]?) {
        self.recordId = recordId
        self.savedDrawings = savedDrawings
        self.workingStepTick = workingStepTick
        self.workingDrawings = workingDrawings
    }
}

public struct ReviewWorking: Equatable, Sendable {
    public let stepTick: Int
    public let drawings: [DrawingObject]

    public init(stepTick: Int, drawings: [DrawingObject]) {
        self.stepTick = stepTick
        self.drawings = drawings
    }
}

public protocol ReviewArchiveRepository: Sendable {
    // **独立解码（codex plan-R1-high）**：saved 与 working 解码互不牵连——saved 坏不得害有效 working。
    func loadWorking(recordId: Int64) throws -> ReviewWorking?            // 仅解码 working 两列（saved 不碰）；working 坏→.dbCorrupted
    func loadSaved(recordId: Int64) throws -> [DrawingObject]?           // 仅解码 saved 列（working 不碰）；saved 坏→.dbCorrupted
    func loadArchive(recordId: Int64) throws -> ReviewArchive?           // 全量（测试/一次性用）；coordinator 走上面两个独立解码
    func saveWorking(recordId: Int64, stepTick: Int, drawings: [DrawingObject]) throws  // 原子：两 working 列同写，saved 不动
    func commitSaved(recordId: Int64, drawings: [DrawingObject]) throws   // saved=drawings，清 working（原子）
    func clearWorking(recordId: Int64) throws                            // 清 working；若 saved 亦 NULL → DELETE 行
    func clearSaved(recordId: Int64) throws                              // 仅清 saved（corrupt 恢复）；若 working 亦 NULL → DELETE 行
    func loadMarkers() throws -> [Int64: ReviewMarker]                   // 批量轻量（不解码 payload），供首页
    func reviewMarker(recordId: Int64) throws -> ReviewMarker            // 单条轻量，供 action sheet
}

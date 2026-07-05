// ReviewArchiveRepository.swift
// 复盘存档单记录仓储（review-redesign RFC，v1.9）。镜像 PendingReplayRepository（sync throws，
// 不得 async——理由同 pendingReplayRepo：coordinator autosave/复盘持久化不变量依赖同步 GRDB 写）。

public enum ReviewMarker: Equatable, Sendable {
    case none, inProgress, saved
}

public struct ReviewArchive: Equatable, Sendable {
    public let recordId: Int64
    public let savedLossy: LossyDrawingArray?          // 携带有序 known+unknown（保 unknownRaw 跨 loadArchive→save，codex R10-high）
    public let savedHiddenIds: [DrawingID]?
    public let workingStepTick: Int?
    public let workingLossy: LossyDrawingArray?
    public let workingHiddenIds: [DrawingID]?
    public var savedDrawings: [DrawingObject]? { savedLossy?.drawings }       // 计算属性（app 消费的已知条）
    public var workingDrawings: [DrawingObject]? { workingLossy?.drawings }

    public init(recordId: Int64, savedLossy: LossyDrawingArray?, savedHiddenIds: [DrawingID]? = nil,
                workingStepTick: Int?, workingLossy: LossyDrawingArray?, workingHiddenIds: [DrawingID]? = nil) {
        self.recordId = recordId
        self.savedLossy = savedLossy
        self.savedHiddenIds = savedHiddenIds
        self.workingStepTick = workingStepTick
        self.workingLossy = workingLossy
        self.workingHiddenIds = workingHiddenIds
    }

    /// 兼容旧构造 API（Task 6 之前的 call-sites，Task 10 之前不改 repo load/save 逻辑）：
    /// 纯 `[DrawingObject]` 包成 `LossyDrawingArray`，hiddenIds 未知（该形状不携带）→ nil。
    public init(recordId: Int64, savedDrawings: [DrawingObject]?,
                workingStepTick: Int?, workingDrawings: [DrawingObject]?) {
        self.init(recordId: recordId,
                  savedLossy: savedDrawings.map { LossyDrawingArray(drawings: $0) }, savedHiddenIds: nil,
                  workingStepTick: workingStepTick,
                  workingLossy: workingDrawings.map { LossyDrawingArray(drawings: $0) }, workingHiddenIds: nil)
    }
}

public struct ReviewWorking: Equatable, Sendable {
    public let stepTick: Int
    public let lossy: LossyDrawingArray            // 携带有序 known+unknown → 支持 repo load→save 往返无损（codex R6-high①/Y）
    public let hiddenOriginalIds: [DrawingID]      // 复盘隐藏原训练线 id 集（§11.5/D12）
    public var drawings: [DrawingObject] { lossy.drawings }   // 计算属性：app 消费的已知条

    public init(stepTick: Int, lossy: LossyDrawingArray, hiddenOriginalIds: [DrawingID] = []) {
        self.stepTick = stepTick; self.lossy = lossy; self.hiddenOriginalIds = hiddenOriginalIds
    }
    /// 便捷：纯已知条（coordinator fresh save 用；活编辑保住 unknown = P1b 引擎携带 lossy，§Y 分层）。
    public init(stepTick: Int, drawings: [DrawingObject], hiddenOriginalIds: [DrawingID] = []) {
        self.init(stepTick: stepTick, lossy: LossyDrawingArray(drawings: drawings), hiddenOriginalIds: hiddenOriginalIds)
    }
}

/// 复盘 session 净改动判定（review-redesign Task 5）：工作画线集是否偏离 committed 基线。
public enum ReviewNetChange {
    /// 净改动 = 工作画线集与 committed 基线不等（顺序无关：按稳定序列化后排序比较）。
    public static func changed(working: [DrawingObject], committed: [DrawingObject]) -> Bool {
        func key(_ d: DrawingObject) -> String {
            // 稳定序：toolType|panel|isExtended|revealTick|anchors(period,candleIndex,price)
            let a = d.anchors.map { "\($0.period.rawValue):\($0.candleIndex):\($0.price)" }.joined(separator: ";")
            return "\(d.toolType.rawValue)|\(d.panelPosition)|\(d.isExtended)|\(d.revealTick)|\(a)"
        }
        return working.map(key).sorted() != committed.map(key).sorted()
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

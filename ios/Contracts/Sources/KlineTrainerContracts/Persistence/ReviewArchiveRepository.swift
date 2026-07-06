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
    /// codex WB R7 finding 1：saved 列 wrapper 顶层未知 key（原样字节，跨 loadArchive→save 保留）。
    public let savedUnknownTopLevel: [ReviewArchiveWrapper.UnknownTopLevelEntry]?
    public let workingStepTick: Int?
    public let workingLossy: LossyDrawingArray?
    public let workingHiddenIds: [DrawingID]?
    /// codex WB R7 finding 1：working 列 wrapper 顶层未知 key（同上，working 侧）。
    public let workingUnknownTopLevel: [ReviewArchiveWrapper.UnknownTopLevelEntry]?
    public var savedDrawings: [DrawingObject]? { savedLossy?.drawings }       // 计算属性（app 消费的已知条）
    public var workingDrawings: [DrawingObject]? { workingLossy?.drawings }

    public init(recordId: Int64, savedLossy: LossyDrawingArray?, savedHiddenIds: [DrawingID]? = nil,
                savedUnknownTopLevel: [ReviewArchiveWrapper.UnknownTopLevelEntry]? = nil,
                workingStepTick: Int?, workingLossy: LossyDrawingArray?, workingHiddenIds: [DrawingID]? = nil,
                workingUnknownTopLevel: [ReviewArchiveWrapper.UnknownTopLevelEntry]? = nil) {
        self.recordId = recordId
        self.savedLossy = savedLossy
        self.savedHiddenIds = savedHiddenIds
        self.savedUnknownTopLevel = savedUnknownTopLevel
        self.workingStepTick = workingStepTick
        self.workingLossy = workingLossy
        self.workingHiddenIds = workingHiddenIds
        self.workingUnknownTopLevel = workingUnknownTopLevel
    }

    /// 兼容旧构造 API（Task 6 之前的 call-sites，Task 10 之前不改 repo load/save 逻辑）：
    /// 纯 `[DrawingObject]` 包成 `LossyDrawingArray`，hiddenIds/unknownTopLevel 未知（该形状不携带）→ nil。
    /// throws（codex whole-branch High fix）：`LossyDrawingArray(drawings:)` 现在 throws。
    public init(recordId: Int64, savedDrawings: [DrawingObject]?,
                workingStepTick: Int?, workingDrawings: [DrawingObject]?) throws {
        self.init(recordId: recordId,
                  savedLossy: try savedDrawings.map { try LossyDrawingArray(drawings: $0) }, savedHiddenIds: nil,
                  workingStepTick: workingStepTick,
                  workingLossy: try workingDrawings.map { try LossyDrawingArray(drawings: $0) }, workingHiddenIds: nil)
    }
}

public struct ReviewWorking: Equatable, Sendable {
    public let stepTick: Int
    public let lossy: LossyDrawingArray            // 携带有序 known+unknown → 支持 repo load→save 往返无损（codex R6-high①/Y）
    public let hiddenOriginalIds: [DrawingID]      // 复盘隐藏原训练线 id 集（§11.5/D12）
    /// codex WB R7 finding 1：加载来的 wrapper 顶层未知 key（原样字节，穿过 coordinator save 路径原样传回）。
    public let unknownTopLevel: [ReviewArchiveWrapper.UnknownTopLevelEntry]
    public var drawings: [DrawingObject] { lossy.drawings }   // 计算属性：app 消费的已知条

    public init(stepTick: Int, lossy: LossyDrawingArray, hiddenOriginalIds: [DrawingID] = [],
                unknownTopLevel: [ReviewArchiveWrapper.UnknownTopLevelEntry] = []) {
        self.stepTick = stepTick; self.lossy = lossy; self.hiddenOriginalIds = hiddenOriginalIds
        self.unknownTopLevel = unknownTopLevel
    }
    /// 便捷：纯已知条（coordinator fresh save 用；活编辑保住 unknown = P1b 引擎携带 lossy，§Y 分层）。
    /// throws（codex whole-branch High fix）：`LossyDrawingArray(drawings:)` 现在 throws。
    public init(stepTick: Int, drawings: [DrawingObject], hiddenOriginalIds: [DrawingID] = []) throws {
        self.init(stepTick: stepTick, lossy: try LossyDrawingArray(drawings: drawings), hiddenOriginalIds: hiddenOriginalIds)
    }
}

/// 复盘 session 净改动判定：工作态 {drawings, hiddenIds} 是否偏离 committed 基线。
public enum ReviewNetChange {
    /// 净改动 = 画线集（按 id 归组、保留重数、全字段比较）或隐藏 id 集 与基线不等。
    public static func changed(working: [DrawingObject], committed: [DrawingObject],
                               workingHiddenIds: [DrawingID] = [],
                               committedHiddenIds: [DrawingID] = []) -> Bool {
        // 全字段稳定序列化（含 id + 所有样式/文本/tailAnchor/period），按 id 排序保留重数。
        func fullKey(_ d: DrawingObject) -> String {
            let a = d.anchors.map { "\($0.period.rawValue):\($0.candleIndex):\($0.price)" }.joined(separator: ";")
            let t = d.tailAnchor.map { "\($0.period.rawValue):\($0.candleIndex):\($0.price)" } ?? "-"
            return [d.id, d.toolType.rawValue, "\(d.panelPosition)", "\(d.isExtended)", "\(d.revealTick)",
                    d.period.rawValue, d.lineSubType.rawValue, d.lineStyle.rawValue, "\(d.thickness)",
                    d.colorToken.rawValue, d.labelMode.rawValue, "\(d.locked)", d.text, "\(d.fontSize)",
                    d.textColorToken.rawValue, d.textForm.rawValue, t, a].joined(separator: "|")
        }
        if working.map(fullKey).sorted() != committed.map(fullKey).sorted() { return true }
        return workingHiddenIds.sorted() != committedHiddenIds.sorted()
    }
}

public protocol ReviewArchiveRepository: Sendable {
    // **独立解码（codex plan-R1-high）**：saved 与 working 解码互不牵连——saved 坏不得害有效 working。
    func loadWorking(recordId: Int64) throws -> ReviewWorking?            // 仅解码 working 两列（saved 不碰）；working 坏→.dbCorrupted
    func loadSaved(recordId: Int64) throws -> [DrawingObject]?           // 仅解码 saved 列（working 不碰）；saved 坏→.dbCorrupted
    // P1a Task 12（Z1 Critical fix）：saved 列的 lossy-carrying 版本——mirror `loadWorking` 保真路径
    // （携带 unknownRaw + hiddenIds + 未知顶层 key），供 `review()` FRESH 入口种引擎，避免 `loadSaved`
    // 已知投影被重新包装成"全新" lossy 而在无编辑 commit 时丢弃 saved blob 里未识别条/隐藏态/未知顶层 key。
    // saved 坏→.dbCorrupted。unknownTopLevel：codex WB R7 finding 1（wrapper 顶层未知 key 保真）。
    func loadSavedLossy(recordId: Int64) throws
        -> (lossy: LossyDrawingArray, hiddenIds: [DrawingID], unknownTopLevel: [ReviewArchiveWrapper.UnknownTopLevelEntry])?
    func loadArchive(recordId: Int64) throws -> ReviewArchive?           // 全量（测试/一次性用）；coordinator 走上面两个独立解码
    // repo 边界无损（P1a Task 10，codex plan-R4-high①）：接收完整 lossy（含 unknownRaw 有序），原样保真回写，
    // 不从 [DrawingObject] 重建（否则下次 save 会丢未识别条）。unknownTopLevel（codex WB R7 finding 1）：
    // wrapper 顶层未知 key，原样传回、原样拼回磁盘（不得被默认 `[]` 覆盖已加载的未来数据）。
    func saveWorking(recordId: Int64, stepTick: Int, lossy: LossyDrawingArray, hiddenOriginalIds: [DrawingID],
                     unknownTopLevel: [ReviewArchiveWrapper.UnknownTopLevelEntry]) throws  // 原子：两 working 列同写，saved 不动
    func commitSaved(recordId: Int64, lossy: LossyDrawingArray, hiddenOriginalIds: [DrawingID],
                     unknownTopLevel: [ReviewArchiveWrapper.UnknownTopLevelEntry]) throws   // saved=lossy，清 working（原子）
    func clearWorking(recordId: Int64) throws                            // 清 working；若 saved 亦 NULL → DELETE 行
    func clearSaved(recordId: Int64) throws                              // 仅清 saved（corrupt 恢复）；若 working 亦 NULL → DELETE 行
    func loadMarkers() throws -> [Int64: ReviewMarker]                   // 批量轻量（不解码 payload），供首页
    func reviewMarker(recordId: Int64) throws -> ReviewMarker            // 单条轻量，供 action sheet
}

// P1a Task 10：`hiddenOriginalIds` 默认 `[]`（Swift 协议方法本身不支持默认参数值，用 extension 兜底
// 提供便捷重载）——coordinator 现有调用只需传 `lossy`，不需要跟着改传 `hiddenOriginalIds`
// （hide/show 写入行为在 P5，本 task 只透传加载来的 hiddenIds，不新增编辑）。
// codex WB R7 finding 1：同款兜底补 `unknownTopLevel` 默认 `[]`——保住既有（此前只传 lossy/hiddenOriginalIds
// 的）call-site 不必跟着改。
public extension ReviewArchiveRepository {
    func saveWorking(recordId: Int64, stepTick: Int, lossy: LossyDrawingArray) throws {
        try saveWorking(recordId: recordId, stepTick: stepTick, lossy: lossy, hiddenOriginalIds: [], unknownTopLevel: [])
    }
    func saveWorking(recordId: Int64, stepTick: Int, lossy: LossyDrawingArray, hiddenOriginalIds: [DrawingID]) throws {
        try saveWorking(recordId: recordId, stepTick: stepTick, lossy: lossy, hiddenOriginalIds: hiddenOriginalIds, unknownTopLevel: [])
    }
    func commitSaved(recordId: Int64, lossy: LossyDrawingArray) throws {
        try commitSaved(recordId: recordId, lossy: lossy, hiddenOriginalIds: [], unknownTopLevel: [])
    }
    func commitSaved(recordId: Int64, lossy: LossyDrawingArray, hiddenOriginalIds: [DrawingID]) throws {
        try commitSaved(recordId: recordId, lossy: lossy, hiddenOriginalIds: hiddenOriginalIds, unknownTopLevel: [])
    }
}

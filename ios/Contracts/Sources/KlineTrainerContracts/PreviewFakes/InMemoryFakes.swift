// Kline Trainer Swift Contracts — Wave 0 In-Memory Fakes for E6.preview() path
// Spec: kline_trainer_modules_v1.4.md §11.3 Test Fixture Ports list (line 2195-2206)
// 本 PR 只落 5 个 E6.preview() 调用路径上的 fake；其余 6 个属 PR 5 Fixture/Mock Ports
// `#if DEBUG` 包裹与 spec line 1671-1713 preview Fixture 一致：fakes 不进 Release binary

#if DEBUG

import Foundation

// MARK: - P3a fake

/// **Scope: preview/happy-path only.**
/// 此 factory 默认 happy-path 成功（`file` / `expectedSchemaVersion` 被忽略）。
/// 需要测试 .versionMismatch / .fileNotFound 等错误分支的用例请用专属 mock，
/// 不要 fork 本 fake（保 fake 行为面收敛）。
public struct PreviewTrainingSetDBFactory: TrainingSetDBFactory {
    private let meta: TrainingSetMeta
    private let candles: [Period: [KLineCandle]]
    /// Wave 3 顺位 10b Task 0 knob：命中 file.lastPathComponent → 抛 .persistence(.dbCorrupted)。
    public let corruptFilenames: Set<String>
    /// Wave 3 顺位 10b Task 0 knob：任意 file 抛此错误（测非损坏不删）；优先于 corruptFilenames。
    public let openErrorAll: AppError?

    public init(meta: TrainingSetMeta? = nil,
                candles: [Period: [KLineCandle]] = [:],
                corruptFilenames: Set<String> = [],
                openErrorAll: AppError? = nil) {
        // R4 修订（codex round-4 high-1）：占位 meta 必须满足 production
        // DefaultTrainingSetDBFactory line 65-68 的 sanity check（startDatetime > 0
        // + endDatetime >= startDatetime + 非空 stock fields），否则 fake/production
        // 接受度分叉。startDatetime/endDatetime = 1（最小合法 Unix 秒，避免 0 边界）
        self.meta = meta ?? TrainingSetMeta(
            stockCode: "PREVIEW",
            stockName: "Preview Stock",
            startDatetime: 1,
            endDatetime: 1)
        self.candles = candles
        self.corruptFilenames = corruptFilenames
        self.openErrorAll = openErrorAll
    }

    public func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
        if let e = openErrorAll { throw e }
        if corruptFilenames.contains(file.lastPathComponent) { throw AppError.persistence(.dbCorrupted) }
        // R4 修订（codex round-4 high-1）：每次 openAndVerify 校验注入的 meta
        // mirror DefaultTrainingSetDBFactory line 65-68
        try Self.validateMeta(meta)
        // file / expectedSchemaVersion 在 fake 中被忽略（§3 决策）；
        // 每次调用产生新 reader（spec L1830 契约）
        return PreviewTrainingSetReader(meta: meta, candles: candles)
    }

    private static func validateMeta(_ m: TrainingSetMeta) throws {
        if m.stockCode.isEmpty || m.stockName.isEmpty ||
           m.startDatetime <= 0 || m.endDatetime < m.startDatetime {
            throw AppError.persistence(.dbCorrupted)
        }
    }
}

// MARK: - P4 fakes

public final class InMemoryRecordRepository: RecordRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Int64: TrainingRecord] = [:]
    private var ops: [Int64: [TradeOperation]] = [:]
    private var drawings: [Int64: [DrawingObject]] = [:]
    private var nextId: Int64 = 1

    public init() {}

    public func insertRecord(_ rec: TrainingRecord,
                             ops opsIn: [TradeOperation],
                             drawings drawingsIn: [DrawingObject]) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let id = nextId
        nextId += 1
        // 把 server-assigned id 写回 record（mirror production INSERT lastInsertedRowID）
        let stored = TrainingRecord(
            id: id, trainingSetFilename: rec.trainingSetFilename, createdAt: rec.createdAt,
            stockCode: rec.stockCode, stockName: rec.stockName,
            startYear: rec.startYear, startMonth: rec.startMonth,
            totalCapital: rec.totalCapital, profit: rec.profit, returnRate: rec.returnRate,
            maxDrawdown: rec.maxDrawdown, buyCount: rec.buyCount, sellCount: rec.sellCount,
            feeSnapshot: rec.feeSnapshot, finalTick: rec.finalTick)
        records[id] = stored
        ops[id] = opsIn
        drawings[id] = drawingsIn
        return id
    }

    /// 按 (createdAt desc, id desc) 排序——mirror production RecordRepositoryImpl line 60/99
    /// 抽出供 listRecords 和 statistics 共用，避免双处维护漂移。
    /// 调用方须已持有 lock（本函数不加锁）。
    private func sortedRecordsLocked() -> [TrainingRecord] {
        records.values.sorted { (a, b) in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return (a.id ?? 0) > (b.id ?? 0)
        }
    }

    public func listRecords(limit: Int?) throws -> [TrainingRecord] {
        lock.lock(); defer { lock.unlock() }
        // R1 修订（codex round-1 med-2）：mirror production line 60 "ORDER BY created_at DESC, id DESC"
        let sorted = sortedRecordsLocked()
        // R8 修订（codex round-8 med-3）：负 limit 会 trap `Array.prefix` precondition；
        // mirror SQLite `LIMIT ?` 负值语义 = "无限制"，把负值视同 nil（全量返回）
        if let limit = limit, limit >= 0 { return Array(sorted.prefix(limit)) }
        return sorted
    }

    public func loadRecordBundle(id: Int64) throws -> (TrainingRecord, [TradeOperation], [DrawingObject]) {
        lock.lock(); defer { lock.unlock() }
        guard let r = records[id] else {
            // mirror production RecordRepositoryImpl.swift line 74：未知 id = caller 编程错误
            throw AppError.persistence(.dbCorrupted)
        }
        return (r, ops[id] ?? [], drawings[id] ?? [])
    }

    public func statistics() throws -> (totalCount: Int, winCount: Int, currentCapital: Double) {
        lock.lock(); defer { lock.unlock() }
        let total = records.count
        let wins = records.values.filter { $0.profit > 0 }.count
        // R1 修订（codex round-1 med-2）：mirror production line 99 "ORDER BY created_at DESC, id DESC LIMIT 1"
        let latest = sortedRecordsLocked().first
        let cap = latest.map { $0.totalCapital + $0.profit } ?? 0
        return (total, wins, cap)
    }
}

public final class InMemoryPendingTrainingRepository: PendingTrainingRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: PendingTraining?

    /// 注入下一次 savePending/clearPending/loadPending 抛错（消费后自动清除）；mirror 生产：抛前零状态变更。lock 保护读写。
    private var _failNextSavePending: AppError?
    public var failNextSavePending: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextSavePending }
        set { lock.lock(); defer { lock.unlock() }; _failNextSavePending = newValue }
    }
    private var _failNextClearPending: AppError?
    public var failNextClearPending: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextClearPending }
        set { lock.lock(); defer { lock.unlock() }; _failNextClearPending = newValue }
    }
    private var _failNextLoadPending: AppError?
    public var failNextLoadPending: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextLoadPending }
        set { lock.lock(); defer { lock.unlock() }; _failNextLoadPending = newValue }
    }
    /// savePending 成功落盘次数（coalescing/cadence 断言用）。lock 保护读。
    private var _saveCount = 0
    public var saveCount: Int {
        lock.lock(); defer { lock.unlock() }; return _saveCount
    }

    public init() {}

    public func savePending(_ p: PendingTraining) throws {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextSavePending { _failNextSavePending = nil; throw e }
        pending = p
        _saveCount += 1
    }

    public func loadPending() throws -> PendingTraining? {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextLoadPending { _failNextLoadPending = nil; throw e }
        return pending
    }

    public func clearPending() throws {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextClearPending { _failNextClearPending = nil; throw e }
        pending = nil
    }
}

public final class InMemoryPendingReplayRepository: PendingReplayRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: PendingReplay?

    private var _failNextSaveReplay: AppError?
    public var failNextSaveReplay: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextSaveReplay }
        set { lock.lock(); defer { lock.unlock() }; _failNextSaveReplay = newValue }
    }
    private var _failNextClearReplay: AppError?
    public var failNextClearReplay: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextClearReplay }
        set { lock.lock(); defer { lock.unlock() }; _failNextClearReplay = newValue }
    }
    private var _failNextLoadReplay: AppError?
    public var failNextLoadReplay: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextLoadReplay }
        set { lock.lock(); defer { lock.unlock() }; _failNextLoadReplay = newValue }
    }
    private var _saveCount = 0
    public var saveCount: Int { lock.lock(); defer { lock.unlock() }; return _saveCount }

    public init() {}

    public func saveReplay(_ p: PendingReplay) throws {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextSaveReplay { _failNextSaveReplay = nil; throw e }
        pending = p
        _saveCount += 1
    }
    public func loadReplay() throws -> PendingReplay? {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextLoadReplay { _failNextLoadReplay = nil; throw e }
        return pending
    }
    /// 元数据读取**不消费** `failNextLoadReplay`（生产 Impl 只读简单列、不解码 payload，故不受 payload 损坏影响）。
    /// 这样测试可"slotInfo 成功（返 recordId）+ loadReplay 抛 .dbCorrupted"模拟损坏 payload 的本记录槽。
    public func loadReplaySlotInfo() throws -> ReplaySlotInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let p = pending else { return nil }
        return ReplaySlotInfo(recordId: p.recordId, trainingSetFilename: p.trainingSetFilename)
    }
    public func clearReplay() throws {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextClearReplay { _failNextClearReplay = nil; throw e }
        pending = nil
    }
    public func clearReplay(ifRecordId recordId: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextClearReplay { _failNextClearReplay = nil; throw e }
        if pending?.recordId == recordId { pending = nil }
    }
}

/// review-redesign：ReviewArchiveRepository 的 in-memory fake（mirror ReviewArchiveRepositoryImpl 状态机：
/// 独立解码不适用于内存态——本 fake 无 JSON 序列化，saved/working 各自独立存储字段即天然独立）。
public final class InMemoryReviewArchiveRepository: ReviewArchiveRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [Int64: [DrawingObject]] = [:]
    private var savedHidden: [Int64: [DrawingID]] = [:]
    private var working: [Int64: (stepTick: Int, drawings: [DrawingObject])] = [:]
    private var workingHidden: [Int64: [DrawingID]] = [:]
    /// review-redesign Task 6：一次性故障注入（mirror `InMemoryPendingReplayRepository` 的 `failNextLoadReplay`
    /// 范式），供 coordinator saved-corrupt 恢复路径测试模拟 `.dbCorrupted` / clearSaved 失败。
    private var _failNextLoadSaved: AppError?
    public var failNextLoadSaved: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextLoadSaved }
        set { lock.lock(); defer { lock.unlock() }; _failNextLoadSaved = newValue }
    }
    private var _failNextClearSaved: AppError?
    public var failNextClearSaved: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextClearSaved }
        set { lock.lock(); defer { lock.unlock() }; _failNextClearSaved = newValue }
    }
    /// final-review T6：一次性故障注入，供测试模拟 `loadWorking` 的 `.dbCorrupted`（working 独立解码坏路径）。
    private var _failNextLoadWorking: AppError?
    public var failNextLoadWorking: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextLoadWorking }
        set { lock.lock(); defer { lock.unlock() }; _failNextLoadWorking = newValue }
    }
    /// codex whole-branch R2：一次性故障注入，供测试模拟 `reviewMarker` 瞬态错误（fail-closed resume 回归测试）。
    private var _failNextReviewMarker: AppError?
    public var failNextReviewMarker: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextReviewMarker }
        set { lock.lock(); defer { lock.unlock() }; _failNextReviewMarker = newValue }
    }
    /// codex whole-branch R2：一次性故障注入，供测试模拟 `clearWorking` 失败（abandonReview 稳健 teardown 回归测试）。
    private var _failNextClearWorking: AppError?
    public var failNextClearWorking: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextClearWorking }
        set { lock.lock(); defer { lock.unlock() }; _failNextClearWorking = newValue }
    }
    /// codex whole-branch R4 finding 1：一次性故障注入，供测试模拟 `saveWorking` 失败（review autosave/flush
    /// 可观察错误回归测试，mirror `failNextClearWorking` 范式）。
    private var _failNextSaveWorking: AppError?
    public var failNextSaveWorking: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextSaveWorking }
        set { lock.lock(); defer { lock.unlock() }; _failNextSaveWorking = newValue }
    }

    public init() {}

    public func loadArchive(recordId: Int64) throws -> ReviewArchive? {
        lock.lock(); defer { lock.unlock() }
        let s = saved[recordId]
        let w = working[recordId]
        guard s != nil || w != nil else { return nil }
        return ReviewArchive(recordId: recordId,
                             savedLossy: s.map { LossyDrawingArray(drawings: $0) }, savedHiddenIds: savedHidden[recordId],
                             workingStepTick: w?.stepTick,
                             workingLossy: w.map { LossyDrawingArray(drawings: $0.drawings) }, workingHiddenIds: workingHidden[recordId])
    }

    public func loadWorking(recordId: Int64) throws -> ReviewWorking? {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextLoadWorking { _failNextLoadWorking = nil; throw e }
        guard let w = working[recordId] else { return nil }
        return ReviewWorking(stepTick: w.stepTick, drawings: w.drawings, hiddenOriginalIds: workingHidden[recordId] ?? [])
    }

    public func loadSaved(recordId: Int64) throws -> [DrawingObject]? {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextLoadSaved { _failNextLoadSaved = nil; throw e }
        return saved[recordId]
    }

    // P1a Task 12（Z1 Critical fix）：fake 无 JSON 序列化（同类注释见上），故无真 unknownRaw 可携带——
    // 与 loadWorking 同款仅 wrap 已知条 + 附带独立存储的 hiddenIds（fake 层面已是该方法能提供的最大保真）。
    public func loadSavedLossy(recordId: Int64) throws -> (lossy: LossyDrawingArray, hiddenIds: [DrawingID])? {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextLoadSaved { _failNextLoadSaved = nil; throw e }
        guard let s = saved[recordId] else { return nil }
        return (LossyDrawingArray(drawings: s), savedHidden[recordId] ?? [])
    }

    public func saveWorking(recordId: Int64, stepTick: Int, lossy: LossyDrawingArray, hiddenOriginalIds: [DrawingID]) throws {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextSaveWorking { _failNextSaveWorking = nil; throw e }
        working[recordId] = (stepTick, lossy.drawings)
        workingHidden[recordId] = hiddenOriginalIds
    }

    public func commitSaved(recordId: Int64, lossy: LossyDrawingArray, hiddenOriginalIds: [DrawingID]) throws {
        lock.lock(); defer { lock.unlock() }
        saved[recordId] = lossy.drawings
        savedHidden[recordId] = hiddenOriginalIds
        working[recordId] = nil
        workingHidden[recordId] = nil
    }

    public func clearWorking(recordId: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextClearWorking { _failNextClearWorking = nil; throw e }
        working[recordId] = nil
        workingHidden[recordId] = nil
    }

    public func clearSaved(recordId: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextClearSaved { _failNextClearSaved = nil; throw e }
        saved[recordId] = nil
        savedHidden[recordId] = nil
    }

    public func loadMarkers() throws -> [Int64: ReviewMarker] {
        lock.lock(); defer { lock.unlock() }
        var out: [Int64: ReviewMarker] = [:]
        for id in Set(saved.keys).union(working.keys) {
            let marker: ReviewMarker = working[id] != nil ? .inProgress : (saved[id] != nil ? .saved : .none)
            out[id] = marker
        }
        return out.filter { $0.value != .none }
    }

    public func reviewMarker(recordId: Int64) throws -> ReviewMarker {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextReviewMarker { _failNextReviewMarker = nil; throw e }
        if working[recordId] != nil { return .inProgress }
        if saved[recordId] != nil { return .saved }
        return .none
    }
}

/// Wave 3 顺位 10a：SessionFinalizationPort 的 in-memory fake。
/// 组合既有 record/pending 两 fake（保证 fake 状态一致）；mirror 生产单事务语义：
/// 失败注入时**零状态变更**（原子）；同 sessionKey 重试幂等返已存 id。
/// 通常由 @MainActor 测试驱动；fake 本身标 @unchecked Sendable 以满足协议要求。
public final class InMemorySessionFinalizationPort: SessionFinalizationPort, @unchecked Sendable {
    private let lock = NSLock()
    private let records: InMemoryRecordRepository
    private let pending: InMemoryPendingTrainingRepository
    private var keyed: [String: Int64] = [:]
    /// A4：每 sessionKey 首次派生的权威资金（retry 返首次值，mirror 生产锚定首次记录）。
    private var keyedCapital: [String: Double] = [:]
    /// 注入下一次 finalizeSession 抛错（消费后自动清除）。lock 保护读写。
    private var _failNextFinalize: AppError?
    public var failNextFinalize: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextFinalize }
        set { lock.lock(); defer { lock.unlock() }; _failNextFinalize = newValue }
    }
    /// 调用计数（review/replay 不触 port 的断言用）。
    public private(set) var finalizeCallCount = 0

    public init(records: InMemoryRecordRepository, pending: InMemoryPendingTrainingRepository) {
        self.records = records
        self.pending = pending
    }

    public func finalizeSession(record: TrainingRecord, ops: [TradeOperation],
                                drawings: [DrawingObject], sessionKey: String)
        throws -> (id: Int64, totalCapital: Double) {
        // 自有 lock 只护 spy/keyed 状态；不持锁调用内层 fake（各有自锁），杜绝嵌套锁
        lock.lock()
        finalizeCallCount += 1
        if let err = _failNextFinalize {
            _failNextFinalize = nil
            lock.unlock()
            throw err            // 原子：抛前零状态变更（mirror 生产事务 rollback）
        }
        let existing = keyed[sessionKey]
        let existingCapital = keyedCapital[sessionKey]
        lock.unlock()

        if let existing, let existingCapital {  // 幂等：命中仍清 pending + 返首次派生权威值（mirror 生产 §4.7c）
            try pending.clearPending()
            return (existing, existingCapital)
        }
        let id = try records.insertRecord(record, ops: ops, drawings: drawings)
        try pending.clearPending()
        // A4：派生权威资金 = 本记录 total_capital+profit（floor 到 0，mirror 生产 R-plan-13-1）
        let capital = max(0, record.totalCapital + record.profit)
        lock.lock(); keyed[sessionKey] = id; keyedCapital[sessionKey] = capital; lock.unlock()
        return (id, capital)
    }
}

public final class InMemorySettingsDAO: SettingsDAO, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AppSettings = AppSettings(
        commissionRate: 0,
        minCommissionEnabled: false,
        totalCapital: 0,
        displayMode: .system)

    public init() {}

    public func loadSettings() throws -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    public func saveSettings(_ s: AppSettings) throws {
        // R2 修订（codex round-2 med-2）：mirror production SettingsDAOImpl.saveSettings line 64-73
        // 在 lock 外做 guard：拒收时不应锁也不应改字段
        guard s.commissionRate.isFinite else {
            throw AppError.internalError(
                module: "PR5a-InMemorySettingsDAO",
                detail: "saveSettings refused: commissionRate not finite (\(s.commissionRate))")
        }
        guard s.totalCapital.isFinite else {
            throw AppError.internalError(
                module: "PR5a-InMemorySettingsDAO",
                detail: "saveSettings refused: totalCapital not finite (\(s.totalCapital))")
        }
        lock.lock(); defer { lock.unlock() }
        settings = s
    }

    public func resetCapital() throws {
        lock.lock(); defer { lock.unlock() }
        // mirror production: resetCapital→默认 10 万（与 SettingsDAOImpl.resetCapital 一致）
        settings = AppSettings(commissionRate: settings.commissionRate,
                               minCommissionEnabled: settings.minCommissionEnabled,
                               totalCapital: AppSettings.defaultTotalCapital,
                               displayMode: settings.displayMode)
    }

    /// R-plan-24-1：腐坏恢复——写全部键为默认（含 total_capital=默认 10 万）。
    public func repairAllToDefaults() throws {
        lock.lock(); defer { lock.unlock() }
        settings = .default
    }
}

// R1 修订（codex round-1 high-1）：fake 必须镜像 AcceptanceJournalDAOImpl 的 state machine + invariants + COALESCE
// 否则 P2 runner / E6 coordinator 等使用 fake 写的测试会接受 production 拒绝的非法 sequence。
// 镜像源：ios/Contracts/Sources/KlineTrainerPersistence/Internal/AcceptanceJournalDAOImpl.swift line 14-138
// 维护契约：production 的 nextAllowed / canApply / validateInvariants / isValidCRC32Hex 改了 → 这里同步改。
public final class InMemoryAcceptanceJournalDAO: AcceptanceJournalDAO, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: AcceptanceJournalRow] = [:]
    private var nextId: Int64 = 1

    public init() {}

    private static func key(_ trainingSetId: Int, _ leaseId: String) -> String {
        "\(trainingSetId)::\(leaseId)"
    }

    // mirror production line 18-29
    private static func nextAllowed(_ s: P2JournalState) -> Set<P2JournalState> {
        switch s {
        case .downloaded:     return [.crcOK, .rejected]
        case .crcOK:          return [.unzipped, .rejected]
        case .unzipped:       return [.dbVerified, .rejected]
        case .dbVerified:     return [.stored, .rejected]
        case .stored:         return [.confirmPending, .rejected]
        case .confirmPending: return [.confirmed, .rejected]
        case .confirmed:      return []
        case .rejected:       return []
        }
    }

    // mirror production line 35-38
    private static func canApply(new: P2JournalState, over old: P2JournalState) -> Bool {
        if new == old { return true }
        return nextAllowed(old).contains(new)
    }

    // mirror production line 43-63
    private static func validateInvariants(state: P2JournalState,
                                            existingPath: String?, existingHash: String?,
                                            newPath: String?, newHash: String?) throws {
        let resolvedPath = newPath ?? existingPath
        let resolvedHash = newHash ?? existingHash
        let needsPath: Set<P2JournalState> = [.stored, .confirmPending, .confirmed]
        if needsPath.contains(state), resolvedPath == nil {
            throw AppError.internalError(
                module: "PR5a-InMemoryAcceptanceJournalDAO",
                detail: "state \(state.rawValue) requires sqliteLocalPath but neither new nor existing has it")
        }
        if state == .stored {
            guard let h = resolvedHash, isValidCRC32Hex(h) else {
                throw AppError.internalError(
                    module: "PR5a-InMemoryAcceptanceJournalDAO",
                    detail: ".stored requires contentHash matching 8-char lowercase hex (CRC32)")
            }
        }
    }

    // mirror production line 66-69
    private static func isValidCRC32Hex(_ s: String) -> Bool {
        guard s.count == 8 else { return false }
        return s.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) }
    }

    public func upsert(trainingSetId: Int, leaseId: String,
                       state: P2JournalState,
                       sqliteLocalPath: String?,
                       contentHash: String?,
                       lastError: String?) throws {
        lock.lock(); defer { lock.unlock() }
        let k = Self.key(trainingSetId, leaseId)
        let stamp = Int64(Date().timeIntervalSince1970)

        if let existing = rows[k] {
            // 已存在 → 检查 transition 是否合法（mirror production line 90-92：不合法 = silent NOOP）
            if !Self.canApply(new: state, over: existing.state) {
                return  // NOOP（不抛、不修改）
            }
            try Self.validateInvariants(state: state,
                                        existingPath: existing.sqliteLocalPath,
                                        existingHash: existing.contentHash,
                                        newPath: sqliteLocalPath,
                                        newHash: contentHash)
            // COALESCE：nil 入参保留 existing 字段（mirror production line 131-133）
            rows[k] = AcceptanceJournalRow(
                id: existing.id,  // 保留 id（mirror UNIQUE + UPDATE）
                trainingSetId: trainingSetId, leaseId: leaseId,
                state: state, stateEnteredAt: stamp,
                lastError: lastError ?? existing.lastError,
                sqliteLocalPath: sqliteLocalPath ?? existing.sqliteLocalPath,
                contentHash: contentHash ?? existing.contentHash)
        } else {
            // 首插：mirror production line 102-106：state 必须 .downloaded
            guard state == .downloaded else {
                throw AppError.internalError(
                    module: "PR5a-InMemoryAcceptanceJournalDAO",
                    detail: "first INSERT must be .downloaded; got .\(state.rawValue) for tid=\(trainingSetId) lid=\(leaseId)")
            }
            try Self.validateInvariants(state: state,
                                        existingPath: nil, existingHash: nil,
                                        newPath: sqliteLocalPath, newHash: contentHash)
            let id = nextId
            nextId += 1
            rows[k] = AcceptanceJournalRow(
                id: id, trainingSetId: trainingSetId, leaseId: leaseId,
                state: state, stateEnteredAt: stamp,
                lastError: lastError, sqliteLocalPath: sqliteLocalPath, contentHash: contentHash)
        }
    }

    public func listByState(_ state: P2JournalState) throws -> [AcceptanceJournalRow] {
        lock.lock(); defer { lock.unlock() }
        return rows.values.filter { $0.state == state }.sorted { $0.id < $1.id }
    }

    public func deleteByIdLease(trainingSetId: Int, leaseId: String) throws {
        lock.lock(); defer { lock.unlock() }
        rows.removeValue(forKey: Self.key(trainingSetId, leaseId))
    }
}

// MARK: - P5 fake

/// **Scope: preview/happy-path only.**
///
/// 此 fake 不读 sqlite 文件——`schemaVersion` 来自 caller 注入的 `meta.schemaVersion`，
/// `downloadedZip` URL 不被读取（只存进 `TrainingSetFile.localURL` 字段供 caller 持有）。
///
/// 镜像 production `DefaultFileSystemCacheManager` 行为（plan §2 8 条）：
/// - filename safety check（拒空 / `/` / `\` / `..` / `\0` / `.staging-` 前缀）
/// - `.zip → .sqlite` 文件名规范化（codex post-impl R7）
/// - listAvailable 排序：lastAccessedAt desc → downloadedAt desc → **basename desc**（R1-H2 修订；basename = `"\(id)__\(filename)"`，mirror production line 256）
/// - store: 同 id 替换；新插入 mtime = now；替换保留原 downloadedAt，lastAccessedAt = now
/// - maxCachedSets = 20；超容量驱逐尾部
/// - touch: best-effort，缺失 silent no-op
/// - delete: 缺失抛 **`.trainingSet(.fileNotFound)`**（R1-H1 修订；mirror `Internal/CacheErrorMapping.swift:24-25` `NSFileNoSuchFileError → .trainingSet(.fileNotFound)`）
/// - 全部 method 走 NSLock 串行
///
/// **不镜像**（fake-specific 简化）：
/// - PRAGMA user_version 读取（用 caller 注入 schemaVersion）
/// - 文件系统 stage / replaceItemAt / staging orphan 清扫
/// - 同 id 多 filename 共存（dict 单 id 唯一；后写覆盖前写）
/// - replaceItemAt ctime swap 边界
///
/// 需要测试真 sqlite IO 错误（diskFull / dbCorrupted via PRAGMA failure）的用例，
/// 请用 `DefaultFileSystemCacheManager` + 真临时目录 fixture，不要 fork 本 fake。
public final class InMemoryCacheManager: CacheManager, @unchecked Sendable {

    public static let maxCachedSets = 20

    private let lock = NSLock()
    private var store: [Int: TrainingSetFile] = [:]

    /// Wave 3 顺位 10b Task 0 knob：测试可注入确定性选取（默认 nil = randomElement）。根治 provenance 测试 flake。lock 保护读写。
    private var _pickOverride: (([TrainingSetFile]) -> TrainingSetFile?)?
    public var pickOverride: (([TrainingSetFile]) -> TrainingSetFile?)? {
        get { lock.lock(); defer { lock.unlock() }; return _pickOverride }
        set { lock.lock(); defer { lock.unlock() }; _pickOverride = newValue }
    }
    /// Wave 3 顺位 10b Task 0 spy：delete 调用文件名记录（provenance 删重试断言）。lock 保护读。
    private var _deletedFilenames: [String] = []
    public var deletedFilenames: [String] {
        lock.lock(); defer { lock.unlock() }; return _deletedFilenames
    }
    /// Wave 3 PR 13a §A spy：touch 调用文件名记录（touch-on-use 断言）。lock 保护读。
    private var _touchedFilenames: [String] = []
    public var touchedFilenames: [String] {
        lock.lock(); defer { lock.unlock() }; return _touchedFilenames
    }

    public init() {}

    public func listAvailable() -> [TrainingSetFile] {
        lock.lock(); defer { lock.unlock() }
        return sortedLocked()
    }

    public func pickRandom() -> TrainingSetFile? {
        lock.lock(); defer { lock.unlock() }
        let fs = sortedLocked()
        if let o = _pickOverride { return o(fs) }
        return fs.randomElement()
    }

    public func store(downloadedZip: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile {
        lock.lock(); defer { lock.unlock() }
        let cacheFilename = try Self.normalizedFilename(meta.filename)
        let now = Int64(Date().timeIntervalSince1970)
        let preservedDownloadedAt = self.store[meta.id]?.downloadedAt ?? now
        let file = TrainingSetFile(
            id: meta.id,
            filename: cacheFilename,
            localURL: downloadedZip,
            schemaVersion: meta.schemaVersion,
            lastAccessedAt: now,
            downloadedAt: preservedDownloadedAt
        )
        self.store[meta.id] = file
        evictIfNeededLocked()
        return file
    }

    public func touch(_ file: TrainingSetFile) {
        lock.lock(); defer { lock.unlock() }
        guard let existing = self.store[file.id] else { return }   // best-effort silent no-op
        let now = Int64(Date().timeIntervalSince1970)
        self.store[file.id] = TrainingSetFile(
            id: existing.id, filename: existing.filename, localURL: existing.localURL,
            schemaVersion: existing.schemaVersion,
            lastAccessedAt: now,
            downloadedAt: existing.downloadedAt
        )
        _touchedFilenames.append(existing.filename)
    }

    public func delete(_ file: TrainingSetFile) throws {
        lock.lock(); defer { lock.unlock() }
        // R1-H1 修订：mirror production CacheErrorMapping `NSFileNoSuchFileError → .trainingSet(.fileNotFound)`
        // (Internal/CacheErrorMapping.swift:24-25)；production test 期望同 case
        // (DefaultFileSystemCacheManagerTests.swift:118-128 delete_nonExistentThrowsFileNotFound)
        guard self.store.removeValue(forKey: file.id) != nil else {
            throw AppError.trainingSet(.fileNotFound)
        }
        _deletedFilenames.append(file.filename)
    }

    // MARK: - Internal helpers

    /// `.zip → .sqlite` 规范化 + filename safety；mirror `DefaultFileSystemCacheManager.normalizedCacheFilename` (line 148-159) + `validateFilenameSafety` (line 132-143)
    private static func normalizedFilename(_ raw: String) throws -> String {
        // safety check（先于扩展名规范化，避免被规范化掩盖）
        if raw.isEmpty
            || raw.contains("/")
            || raw.contains("\\")
            || raw.contains("..")
            || raw.contains("\0")
            || raw.hasPrefix(".staging-") {
            throw AppError.internalError(
                module: "PR5b-InMemoryCacheManager",
                detail: "invalid filename rejected: \(raw)"
            )
        }
        let lower = raw.lowercased()
        if lower.hasSuffix(".sqlite") {
            return raw
        }
        if lower.hasSuffix(".zip") {
            return String(raw.dropLast(4)) + ".sqlite"
        }
        throw AppError.internalError(
            module: "PR5b-InMemoryCacheManager",
            detail: "filename must end in .sqlite or .zip (case-insensitive): \(raw)"
        )
    }

    /// caller 已 lock。listAvailable 排序：lastAccessedAt desc → downloadedAt desc → basename desc。
    /// R1-H2 修订：mirror production `DefaultFileSystemCacheManager.swift:253-257`
    /// （basename = `entry.deletingPathExtension().lastPathComponent` = `"\(id)__\(filename_no_ext)"`；
    /// fake 等价比较 `"\(id)__\(filename)"` —— 所有项同 `.sqlite` 后缀，字符串 `>` 与 production 同序）。
    private func sortedLocked() -> [TrainingSetFile] {
        store.values.sorted { lhs, rhs in
            if lhs.lastAccessedAt != rhs.lastAccessedAt { return lhs.lastAccessedAt > rhs.lastAccessedAt }
            if lhs.downloadedAt != rhs.downloadedAt { return lhs.downloadedAt > rhs.downloadedAt }
            return Self.basename(lhs) > Self.basename(rhs)
        }
    }

    private static func basename(_ f: TrainingSetFile) -> String {
        "\(f.id)__\(f.filename)"
    }

    /// caller 已 lock。20-cap 驱逐：保留排序后前 20。
    private func evictIfNeededLocked() {
        if store.count <= Self.maxCachedSets { return }
        let keep = Set(sortedLocked().prefix(Self.maxCachedSets).map(\.id))
        for id in Array(store.keys) where !keep.contains(id) {
            store.removeValue(forKey: id)
        }
    }
}

/// 仅供 InMemoryCacheManagerTests 直接灌入预构造 file（绕过 store 路径，
/// 用于测 listAvailable tiebreaker / 20-cap 驱逐边界）。
/// R1-M2 修订：不嵌套 `#if DEBUG`——本 extension 已在文件级 `#if DEBUG` 块内（line 6 起）。
///
/// **Invariant (post-impl R1-L3)**：caller 必须传 `filename` 已是 `.sqlite` 后缀的 `TrainingSetFile`
/// （绕过 normalizedFilename 的 caller 自负）。否则 listAvailable basename tiebreaker 与 production
/// 行为发散（production 入口 `normalizedCacheFilename` 强制后缀）。
///
/// **Capacity note (self-review minor #1)**：`_seedForTesting` 不调用 `evictIfNeededLocked`。
/// 灌入超 `maxCachedSets`（20）项后 dict 暂时超容量，直到下一次 `store()` 调用才触发驱逐；
/// 当前 test #16 故意灌 20 + 走 store 第 21 验 evict，符合该 invariant。
internal extension InMemoryCacheManager {
    func _seedForTesting(_ files: [TrainingSetFile]) {
        lock.lock(); defer { lock.unlock() }
        for f in files {
            store[f.id] = f
        }
    }
}

#endif

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

    public init(meta: TrainingSetMeta? = nil,
                candles: [Period: [KLineCandle]] = [:]) {
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
    }

    public func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
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

    public init() {}

    public func savePending(_ p: PendingTraining) throws {
        lock.lock(); defer { lock.unlock() }
        pending = p
    }

    public func loadPending() throws -> PendingTraining? {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    public func clearPending() throws {
        lock.lock(); defer { lock.unlock() }
        pending = nil
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
        // mirror production: 只动 totalCapital
        settings = AppSettings(commissionRate: settings.commissionRate,
                               minCommissionEnabled: settings.minCommissionEnabled,
                               totalCapital: 0,
                               displayMode: settings.displayMode)
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

    public init() {}

    public func listAvailable() -> [TrainingSetFile] {
        lock.lock(); defer { lock.unlock() }
        return sortedLocked()
    }

    public func pickRandom() -> TrainingSetFile? {
        lock.lock(); defer { lock.unlock() }
        return sortedLocked().randomElement()
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
    }

    public func delete(_ file: TrainingSetFile) throws {
        lock.lock(); defer { lock.unlock() }
        // R1-H1 修订：mirror production CacheErrorMapping `NSFileNoSuchFileError → .trainingSet(.fileNotFound)`
        // (Internal/CacheErrorMapping.swift:24-25)；production test 期望同 case
        // (DefaultFileSystemCacheManagerTests.swift:118-128 delete_nonExistentThrowsFileNotFound)
        guard self.store.removeValue(forKey: file.id) != nil else {
            throw AppError.trainingSet(.fileNotFound)
        }
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

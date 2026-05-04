import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts
import os.log

/// P5 缓存管理生产实现。
/// Spec: kline_trainer_modules_v1.4.md §P5 (line 1950-1968)
///
/// 设计要点（plan §Design Decisions §1-§5 + R1-R6 codex review 修订）：
/// - 元数据 filesystem-derived（mtime/ctime + filename `<id>__<filename>` 前缀），无 sidecar
/// - serial DispatchQueue 串行 store/touch/delete，防并发写同一 path（spec L692）
/// - stage→validate→atomic replace via FileManager.replaceItemAt / moveItem（rollback safe）
/// - LRU by Date sub-second precision，maxCachedSets=20，evict 失败 log 不抛
/// - param `downloadedZip` 实为已解压 + 已 verify 的 .sqlite URL（spec drift 详 plan §2）
public final class DefaultFileSystemCacheManager: CacheManager, @unchecked Sendable {

    public static let maxCachedSets = 20

    private let cacheRoot: URL
    private let queue = DispatchQueue(label: "kline.cache.serial")
    private let log = Logger(subsystem: "kline.trainer", category: "cache")

    /// `cacheRoot` 应为 Application Support 子目录（生产）或 temp 子目录（测试）
    public init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
    }

    /// R5 M-3: lazy 一次性清残留 .staging-* 文件（前次 process kill 留下的 orphan）
    /// 由首次 store 调用触发（lazy one-shot，后续 store 不再 scan）
    private var cleanStaleStagingDone = false

    public func listAvailable() -> [TrainingSetFile] {
        queue.sync { listAvailableLocked() }
    }

    public func pickRandom() -> TrainingSetFile? {
        queue.sync { listAvailableLocked().randomElement() }
    }

    public func store(downloadedZip src: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile {
        try queue.sync {
            try ensureCacheRootExists()
            // R5 M-3: 清前一次 store 进程崩溃残留的 .staging-* 文件（防 orphan 绕过 LRU cap）
            cleanStaleStagingIfNeededLocked()
            // codex post-impl R7: REST meta.filename 是 .zip（e.g. "600519_202001.zip"），
            // cache 层规范化为 .sqlite（src 已是解压后的 sqlite）。.sqlite 直传则原样保留。
            let cacheFilename = try normalizedCacheFilename(meta.filename)
            let target = try cacheURL(forId: meta.id, filename: cacheFilename)
            let staging = cacheRoot.appendingPathComponent(".staging-\(UUID().uuidString)__\(meta.id)__\(cacheFilename)")

            // R1 H-1 fix: stage → validate → atomic replace；任意失败均不动 target
            try stageFile(from: src, to: staging)
            var stagingCleanupNeeded = true
            defer {
                if stagingCleanupNeeded {
                    try? FileManager.default.removeItem(at: staging)
                }
            }

            // R1 H-2 fix: 立即 touch staging，让新 store 的项 mtime = now
            try touchFile(staging)

            // R1 H-1 fix: 验证 sqlite 可读 + 拿 schemaVersion；失败 → throw + defer 清 staging，target 不动
            let schemaVersion = try readSchemaVersion(staging)

            // atomic replace（POSIX rename(2) 在同目录 APFS 上原子）
            try replaceFile(at: target, with: staging)
            stagingCleanupNeeded = false  // staging 已被 replace 走 / swap 走

            let attrs = try fileAttributes(target)
            evictIfNeededLocked()
            return TrainingSetFile(
                id: meta.id,
                filename: cacheFilename,
                localURL: target,
                schemaVersion: schemaVersion,
                lastAccessedAt: attrs.mtime,
                downloadedAt: attrs.ctime)
        }
    }

    public func touch(_ file: TrainingSetFile) {
        queue.sync {
            // R3 H-2: 不信任 caller 传的 file.localURL；从 id+filename 内部重新派生 cache 内 path
            guard let url = try? cacheURL(forId: file.id, filename: file.filename) else { return }
            // best-effort：失败不抛（spec hint：协议签名无 throws）
            try? touchFile(url)
        }
    }

    public func delete(_ file: TrainingSetFile) throws {
        try queue.sync {
            // R3 H-2: 同上，从 id+filename 重新派生
            let url = try cacheURL(forId: file.id, filename: file.filename)
            try removeFile(url)
        }
    }

    // MARK: - Internal helpers (all FileManager / DatabaseQueue I/O wrapped here)
    // M-4 gate 强制：public 方法零 raw `try FileManager.` / `try DatabaseQueue`，全部走以下 helpers。

    /// R5 M-3: 清前次 process kill 残留的 `.staging-*` 文件。
    private func cleanStaleStagingIfNeededLocked() {
        if cleanStaleStagingDone { return }
        cleanStaleStagingDone = true
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: cacheRoot, includingPropertiesForKeys: nil, options: [])) ?? []
        for entry in entries {
            let basename = entry.deletingPathExtension().lastPathComponent
            if basename.hasPrefix(".staging-") {
                do {
                    try removeFile(entry)
                    log.info("removed stale staging: \(entry.lastPathComponent, privacy: .public)")
                } catch {
                    log.error("failed to remove stale staging \(entry.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func ensureCacheRootExists() throws {
        if !FileManager.default.fileExists(atPath: cacheRoot.path) {
            do {
                try FileManager.default.createDirectory(
                    at: cacheRoot, withIntermediateDirectories: true)
            } catch {
                throw CacheErrorMapping.translate(error)
            }
        }
    }

    /// R3 H-2: filename 安全检查（path / staging 前缀 / 空 / NULL）；不检查扩展名。
    private func validateFilenameSafety(_ filename: String) throws {
        if filename.isEmpty
            || filename.contains("/")
            || filename.contains("\\")
            || filename.contains("..")
            || filename.contains("\0")
            || filename.hasPrefix(".staging-") {
            throw AppError.internalError(module: "P5-cache",
                detail: "invalid filename rejected by cache boundary")
        }
    }

    /// codex post-impl R7: REST `TrainingSetMetaItem.filename` 是上游 zip 名（e.g. `600519_202001.zip`），
    /// `downloadedZip` 入参实为已解压 .sqlite。Cache 把 `.zip` 规范化为 `.sqlite` 用于持久化与回报。
    /// `.sqlite` 直传 → 原样返回。其他扩展名 → 拒。
    private func normalizedCacheFilename(_ metaFilename: String) throws -> String {
        try validateFilenameSafety(metaFilename)
        let lower = metaFilename.lowercased()
        if lower.hasSuffix(".sqlite") {
            return metaFilename
        }
        if lower.hasSuffix(".zip") {
            return String(metaFilename.dropLast(4)) + ".sqlite"
        }
        throw AppError.internalError(module: "P5-cache",
            detail: "filename must end in .sqlite or .zip (case-insensitive)")
    }

    /// R3 H-2: cache 内 URL 的唯一构造路径。filename 必须已是 cache 内部 .sqlite 形式
    /// （store 走 normalizedCacheFilename；touch / delete 收到的 TrainingSetFile.filename 也已是 .sqlite）。
    private func cacheURL(forId id: Int, filename: String) throws -> URL {
        try validateFilenameSafety(filename)
        guard filename.lowercased().hasSuffix(".sqlite") else {
            throw AppError.internalError(module: "P5-cache",
                detail: "cache disk filename must end in .sqlite")
        }
        let candidate = cacheRoot.appendingPathComponent("\(id)__\(filename)")
        let stdCand = candidate.standardizedFileURL.path
        let stdRoot = cacheRoot.standardizedFileURL.path
        guard stdCand.hasPrefix(stdRoot + "/") else {
            throw AppError.internalError(module: "P5-cache",
                detail: "derived cache URL escaped cacheRoot")
        }
        return candidate
    }

    /// R6 M-2 fix: 用 copy 而非 move——src 保留给 caller retry
    /// codex post-impl R8: copyItem 在 ENOSPC / 短写时可能在 throw 前部分写入 dest；
    /// 清残留再上抛，否则 cleanStaleStagingDone=true 后同进程 retry 会累积 .staging-* orphans。
    private func stageFile(from src: URL, to staging: URL) throws {
        do {
            try FileManager.default.copyItem(at: src, to: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw CacheErrorMapping.translate(error)
        }
    }

    private func touchFile(_ url: URL) throws {
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: url.path)
        } catch {
            throw CacheErrorMapping.translate(error)
        }
    }

    private func replaceFile(at target: URL, with staging: URL) throws {
        // R2 H-1 fix: target 存在 → replaceItemAt（atomic swap）；不存在 → moveItem（atomic rename(2)）
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: target)
            }
        } catch {
            throw CacheErrorMapping.translate(error)
        }
    }

    private func removeFile(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw CacheErrorMapping.translate(error)
        }
    }

    // MARK: - Internal listing (locked = caller already in queue.sync)

    private func listAvailableLocked() -> [TrainingSetFile] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: cacheRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles])
        } catch {
            return []
        }
        // R2 H-2 fix: sort 用 Date（APFS 纳秒）+ tiebreaker（ctime/basename）
        struct CacheEntry { let file: TrainingSetFile; let mtimeDate: Date; let ctimeDate: Date; let basename: String }
        var staged: [CacheEntry] = []
        for entry in entries {
            guard entry.pathExtension.lowercased() == "sqlite" else { continue }
            let basename = entry.deletingPathExtension().lastPathComponent
            if basename.hasPrefix(".staging-") { continue }
            let parts = basename.components(separatedBy: "__")
            guard parts.count >= 2, let id = Int(parts[0]) else { continue }
            let filename = parts.dropFirst().joined(separator: "__") + ".sqlite"
            guard let dates = try? fileDateAttributes(entry),
                  let schemaVersion = try? readSchemaVersion(entry) else { continue }
            let file = TrainingSetFile(
                id: id, filename: filename, localURL: entry,
                schemaVersion: schemaVersion,
                lastAccessedAt: Int64(dates.mtime.timeIntervalSince1970),
                downloadedAt: Int64(dates.ctime.timeIntervalSince1970))
            staged.append(CacheEntry(file: file, mtimeDate: dates.mtime, ctimeDate: dates.ctime, basename: basename))
        }
        staged.sort { lhs, rhs in
            if lhs.mtimeDate != rhs.mtimeDate { return lhs.mtimeDate > rhs.mtimeDate }
            if lhs.ctimeDate != rhs.ctimeDate { return lhs.ctimeDate > rhs.ctimeDate }
            return lhs.basename > rhs.basename
        }
        return staged.map { $0.file }
    }

    private func evictIfNeededLocked() {
        let all = listAvailableLocked()
        guard all.count > Self.maxCachedSets else { return }
        let toEvict = all.suffix(all.count - Self.maxCachedSets)
        for f in toEvict {
            do {
                try removeFile(f.localURL)
            } catch {
                log.error("cache evict failed for \(f.localURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func fileAttributes(_ url: URL) throws -> (mtime: Int64, ctime: Int64) {
        let dates = try fileDateAttributes(url)
        return (Int64(dates.mtime.timeIntervalSince1970), Int64(dates.ctime.timeIntervalSince1970))
    }

    private func fileDateAttributes(_ url: URL) throws -> (mtime: Date, ctime: Date) {
        let raw: [FileAttributeKey: Any]
        do {
            raw = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw CacheErrorMapping.translate(error)
        }
        let mtime = (raw[.modificationDate] as? Date) ?? Date()
        let ctime = (raw[.creationDate] as? Date) ?? mtime
        return (mtime, ctime)
    }

    private func readSchemaVersion(_ url: URL) throws -> Int {
        do {
            let q = try DatabaseQueue(path: url.path)
            return try q.read { db in
                let row = try Row.fetchOne(db, sql: "PRAGMA user_version")
                return row.map { ($0[0] as Int64?) ?? 0 }.map(Int.init) ?? 0
            }
        } catch {
            throw CacheErrorMapping.translate(error)
        }
    }
}

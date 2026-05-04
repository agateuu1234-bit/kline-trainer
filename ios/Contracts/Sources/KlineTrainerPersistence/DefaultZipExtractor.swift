import Foundation
import ZIPFoundation
import KlineTrainerContracts

public struct DefaultZipExtractor: ZipExtracting {
    public init() { }

    public func extract(zipURL: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw AppError.trainingSet(.fileNotFound)
        }

        // R2: 解压前 inspect Archive entries — 严格 shape (exactly 1 regular .sqlite)，
        // 不允许任何其它 regular file payload（防 junk sidecar 消耗临时磁盘 / 混淆审计）。
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw AppError.trainingSet(.unzipFailed)
        }

        var sqliteEntries: [Entry] = []
        var hasOtherRegularFile = false
        for entry in archive {
            guard entry.type == .file else { continue }     // dir/symlink 不计
            if entry.path.lowercased().hasSuffix(".sqlite") {
                sqliteEntries.append(entry)
            } else {
                hasOtherRegularFile = true
                break
            }
        }
        guard sqliteEntries.count == 1, !hasOtherRegularFile else {
            throw AppError.trainingSet(.unzipFailed)
        }
        let sqliteEntry = sqliteEntries[0]

        // 形态校验通过，单 entry 解压。
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipExtract-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: outputDir, withIntermediateDirectories: true
            )
            // entry.path 可能含 subdir（如 "sub/x.sqlite"）；只取 lastPathComponent 平展输出
            let lastName = (sqliteEntry.path as NSString).lastPathComponent
            let outputURL = outputDir.appendingPathComponent(lastName)
            _ = try archive.extract(sqliteEntry, to: outputURL)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputDir)
            throw ZipErrorMapping.translate(error, fileURL: zipURL)
        }
    }
}

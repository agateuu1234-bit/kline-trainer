import Testing
import Foundation
import ZIPFoundation
import KlineTrainerContracts
@testable import KlineTrainerPersistence

@Suite("DefaultZipExtractor")
struct DefaultZipExtractorTests {

    @Test func extract_validZip_returnsSqliteURL() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (zipURL, _) = try ZipFixture.makeMinimalSqliteZip(in: dir)
        let extractor = DefaultZipExtractor()
        let resultURL = try extractor.extract(zipURL: zipURL)

        #expect(resultURL.lastPathComponent.hasSuffix(".sqlite"))
        #expect(FileManager.default.fileExists(atPath: resultURL.path))
    }

    @Test func extract_corruptedZip_throwsUnzipFailed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let badZipURL = dir.appendingPathComponent("bad.zip")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: badZipURL)
        let extractor = DefaultZipExtractor()

        #expect(throws: AppError.trainingSet(.unzipFailed)) {
            _ = try extractor.extract(zipURL: badZipURL)
        }
    }

    @Test func extract_zipWithoutSqlite_throwsUnzipFailed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let zipURL = dir.appendingPathComponent("nodb.zip")
        guard let archive = Archive(url: zipURL, accessMode: .create) else {
            throw NSError(domain: "test", code: 1)
        }
        let payload = Data("hello".utf8)
        try archive.addEntry(
            with: "readme.txt",
            type: .file,
            uncompressedSize: Int64(payload.count),
            provider: { _, _ in payload }
        )
        let extractor = DefaultZipExtractor()
        #expect(throws: AppError.trainingSet(.unzipFailed)) {
            _ = try extractor.extract(zipURL: zipURL)
        }
    }

    @Test func extract_missingZip_throwsFileNotFound() throws {
        let extractor = DefaultZipExtractor()
        #expect(throws: AppError.trainingSet(.fileNotFound)) {
            _ = try extractor.extract(
                zipURL: URL(fileURLWithPath: "/tmp/__not_exist__/missing.zip")
            )
        }
    }

    // R1 修订：strict shape — 多 sqlite / 嵌套 sqlite / dir-named-.sqlite 全拒
    // （per codex round 1 finding 2 + plan §4 修订）

    @Test func extract_multipleTopLevelSqlite_throwsUnzipFailed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let zipURL = dir.appendingPathComponent("multi.zip")
        guard let archive = Archive(url: zipURL, accessMode: .create) else {
            throw NSError(domain: "test", code: 1)
        }
        let payload = ZipFixture.sqliteHeaderBytes()
        for name in ["aaa.sqlite", "bbb.sqlite"] {
            try archive.addEntry(
                with: name, type: .file,
                uncompressedSize: Int64(payload.count),
                provider: { _, _ in payload }
            )
        }
        let extractor = DefaultZipExtractor()
        #expect(throws: AppError.trainingSet(.unzipFailed)) {
            _ = try extractor.extract(zipURL: zipURL)
        }
    }

    @Test func extract_topLevelSqlitePlusNestedSqlite_throwsUnzipFailed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let zipURL = dir.appendingPathComponent("nested.zip")
        guard let archive = Archive(url: zipURL, accessMode: .create) else {
            throw NSError(domain: "test", code: 1)
        }
        let payload = ZipFixture.sqliteHeaderBytes()
        // top-level
        try archive.addEntry(
            with: "training.sqlite", type: .file,
            uncompressedSize: Int64(payload.count),
            provider: { _, _ in payload }
        )
        // nested in subdir
        try archive.addEntry(
            with: "evil/secret.sqlite", type: .file,
            uncompressedSize: Int64(payload.count),
            provider: { _, _ in payload }
        )
        let extractor = DefaultZipExtractor()
        #expect(throws: AppError.trainingSet(.unzipFailed)) {
            _ = try extractor.extract(zipURL: zipURL)
        }
    }

    @Test func extract_dirNamedSqliteOnly_throwsUnzipFailed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let zipURL = dir.appendingPathComponent("dirname.zip")
        guard let archive = Archive(url: zipURL, accessMode: .create) else {
            throw NSError(domain: "test", code: 1)
        }
        let payload = Data("readme".utf8)
        // dir-typed entry 命名 .sqlite — 不应被识别为 sqlite
        try archive.addEntry(
            with: "fake.sqlite/", type: .directory,
            uncompressedSize: 0,
            provider: { (_: Int64, _: Int) in Data() }
        )
        try archive.addEntry(
            with: "readme.txt", type: .file,
            uncompressedSize: Int64(payload.count),
            provider: { _, _ in payload }
        )
        let extractor = DefaultZipExtractor()
        #expect(throws: AppError.trainingSet(.unzipFailed)) {
            _ = try extractor.extract(zipURL: zipURL)
        }
    }

    // R2 codex finding 2：1 sqlite + 1 junk file 必须 pre-extraction reject
    @Test func extract_sqlitePlusJunkSidecar_throwsUnzipFailed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let zipURL = dir.appendingPathComponent("withjunk.zip")
        guard let archive = Archive(url: zipURL, accessMode: .create) else {
            throw NSError(domain: "test", code: 1)
        }
        let sqlitePayload = ZipFixture.sqliteHeaderBytes()
        try archive.addEntry(
            with: "training.sqlite", type: .file,
            uncompressedSize: Int64(sqlitePayload.count),
            provider: { _, _ in sqlitePayload }
        )
        let junkPayload = Data([UInt8](repeating: 0xFF, count: 1024))
        try archive.addEntry(
            with: "junk.bin", type: .file,
            uncompressedSize: Int64(junkPayload.count),
            provider: { _, _ in junkPayload }
        )
        let extractor = DefaultZipExtractor()
        #expect(throws: AppError.trainingSet(.unzipFailed)) {
            _ = try extractor.extract(zipURL: zipURL)
        }
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultZipExtractorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

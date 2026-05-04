// ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultDownloadAcceptanceCleanerTests.swift
import Testing
import Foundation
import KlineTrainerContracts
@testable import KlineTrainerPersistence

@Suite("DefaultDownloadAcceptanceCleaner")
struct DefaultDownloadAcceptanceCleanerTests {

    @Test func cleanup_existingFile_removes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: fileURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let c = DefaultDownloadAcceptanceCleaner()
        c.cleanup(tempURLs: [fileURL])
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test func cleanup_missingFile_doesNotThrow() {
        let c = DefaultDownloadAcceptanceCleaner()
        // 注意：此路径在 NSTemporaryDirectory 子树内（macOS 一般 /var/folders/.../T/）
        let missingInTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("__not_exist__/never.txt")
        c.cleanup(tempURLs: [missingInTemp])
    }

    @Test func cleanup_directory_removesRecursively() throws {
        let dir = try makeTempDir()
        let nested = dir.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("a.txt"))

        let c = DefaultDownloadAcceptanceCleaner()
        c.cleanup(tempURLs: [dir])
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    @Test func cleanup_mixedExistingAndMissing_removesExistingIgnoresMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = dir.appendingPathComponent("real.txt")
        try Data("x".utf8).write(to: existing)
        let missing = dir.appendingPathComponent("missing.txt")

        let c = DefaultDownloadAcceptanceCleaner()
        c.cleanup(tempURLs: [missing, existing])
        #expect(FileManager.default.fileExists(atPath: existing.path) == false)
    }

    // R4 codex finding 2：tempRoot 本身不可删（strict descendant）
    @Test func cleanup_tempRootItself_doesNotRemove() throws {
        let tempRoot = FileManager.default.temporaryDirectory
        // 在 tempRoot 内造一个 sentinel 文件，cleanup tempRoot 后 sentinel 仍应在
        let sentinel = tempRoot.appendingPathComponent(
            "p2-cleanup-sentinel-\(UUID().uuidString).txt"
        )
        try Data("sentinel".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }

        let c = DefaultDownloadAcceptanceCleaner()
        c.cleanup(tempURLs: [tempRoot])

        #expect(FileManager.default.fileExists(atPath: tempRoot.path))
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    // R3 codex finding 1：path containment guard 必须拒删 NSTemporaryDirectory 之外的路径
    @Test func cleanup_pathOutsideTempRoot_doesNotRemove() throws {
        // 用 cachesDirectory 作为"非 temp"目标（writable + 非 NSTemporaryDirectory 子树）
        let nonTempBase = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first!
        try FileManager.default.createDirectory(
            at: nonTempBase, withIntermediateDirectories: true
        )
        let guardFile = nonTempBase.appendingPathComponent(
            "p2-cleanup-guard-\(UUID().uuidString).txt"
        )
        try Data("guard".utf8).write(to: guardFile)
        defer { try? FileManager.default.removeItem(at: guardFile) }

        let c = DefaultDownloadAcceptanceCleaner()
        c.cleanup(tempURLs: [guardFile])

        #expect(FileManager.default.fileExists(atPath: guardFile.path))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultDownloadAcceptanceCleanerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

import Testing
import Foundation
import KlineTrainerContracts
@testable import KlineTrainerPersistence

@Suite("DefaultZipIntegrityVerifier")
struct DefaultZipIntegrityVerifierTests {

    @Test func verify_matchingCRC32_passes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (zipURL, crcHex) = try ZipFixture.makeMinimalSqliteZip(in: dir)
        let v = DefaultZipIntegrityVerifier()
        try v.verify(zipURL: zipURL, expectedCRC32Hex: crcHex)        // 不抛即 pass
    }

    @Test func verify_mismatchedCRC32_throwsCrcFailed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (zipURL, _) = try ZipFixture.makeMinimalSqliteZip(in: dir)
        let v = DefaultZipIntegrityVerifier()

        #expect(throws: AppError.trainingSet(.crcFailed)) {
            try v.verify(zipURL: zipURL, expectedCRC32Hex: "deadbeef")
        }
    }

    @Test func verify_missingZip_throwsFileNotFound() throws {
        let v = DefaultZipIntegrityVerifier()
        #expect(throws: AppError.trainingSet(.fileNotFound)) {
            try v.verify(
                zipURL: URL(fileURLWithPath: "/tmp/__not_exist__/missing.zip"),
                expectedCRC32Hex: "deadbeef"
            )
        }
    }

    @Test func verify_uppercaseExpected_normalizesToLowercaseAndPasses() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (zipURL, crcHex) = try ZipFixture.makeMinimalSqliteZip(in: dir)
        let v = DefaultZipIntegrityVerifier()
        try v.verify(zipURL: zipURL, expectedCRC32Hex: crcHex.uppercased())
    }

    // R3 codex finding 3：streaming chunk CRC32 必须与一次 Data.crc32 等价
    @Test func verify_largeFileStreaming_matchesWholeFileCRC() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 写一个 256KB 文件（4 个 64KB chunks 边界）
        let payloadSize = 256 * 1024
        let payload = Data((0..<payloadSize).map { UInt8($0 & 0xFF) })
        let largeURL = dir.appendingPathComponent("large.bin")
        try payload.write(to: largeURL)

        // 一次算 reference CRC（只在 test 用，prod 走 streaming）
        let referenceHex = String(format: "%08x", payload.crc32(checksum: 0))

        let v = DefaultZipIntegrityVerifier()
        try v.verify(zipURL: largeURL, expectedCRC32Hex: referenceHex)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultZipIntegrityVerifierTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

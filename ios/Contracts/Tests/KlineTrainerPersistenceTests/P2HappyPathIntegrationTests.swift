import Testing
import Foundation
import ZIPFoundation
import KlineTrainerContracts
@testable import KlineTrainerPersistence

@Suite("P2 happy-path integration")
struct P2HappyPathIntegrationTests {

    @Test func zipLifecycle_verifyExtractCleanup_endToEnd() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P2-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let (zipURL, crcHex) = try ZipFixture.makeMinimalSqliteZip(in: dir)

        let integrity = DefaultZipIntegrityVerifier()
        try integrity.verify(zipURL: zipURL, expectedCRC32Hex: crcHex)

        let extractor = DefaultZipExtractor()
        let sqliteURL = try extractor.extract(zipURL: zipURL)
        #expect(sqliteURL.lastPathComponent.hasSuffix(".sqlite"))
        #expect(FileManager.default.fileExists(atPath: sqliteURL.path))

        let cleaner = DefaultDownloadAcceptanceCleaner()
        cleaner.cleanup(tempURLs: [sqliteURL.deletingLastPathComponent(), zipURL, dir])
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }
}

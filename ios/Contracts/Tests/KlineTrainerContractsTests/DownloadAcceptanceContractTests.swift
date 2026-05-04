import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("P2 4 内部端口 protocol shape")
struct DownloadAcceptanceContractTests {

    // 测试用 fake：仅证明 protocol 签名编译期可解析。
    private struct FakeIntegrity: ZipIntegrityVerifying {
        func verify(zipURL: URL, expectedCRC32Hex: String) throws { }
    }

    private struct FakeExtractor: ZipExtracting {
        func extract(zipURL: URL) throws -> URL { URL(fileURLWithPath: "/tmp/x.sqlite") }
    }

    private final class FakeReader: TrainingSetReader, @unchecked Sendable {
        func loadMeta() throws -> TrainingSetMeta { fatalError("not used") }
        func loadAllCandles() throws -> [Period: [KLineCandle]] { [:] }
        func close() { }
    }

    private struct FakeVerifier: TrainingSetDataVerifying {
        func verifyNonEmpty(reader: TrainingSetReader) throws { }
    }

    private struct FakeCleaner: DownloadAcceptanceCleaning {
        func cleanup(tempURLs: [URL]) { }
    }

    @Test func ZipIntegrityVerifying_signature() throws {
        let f = FakeIntegrity()
        try f.verify(zipURL: URL(fileURLWithPath: "/tmp/x.zip"), expectedCRC32Hex: "deadbeef")
    }

    @Test func ZipExtracting_signature() throws {
        let f = FakeExtractor()
        let _: URL = try f.extract(zipURL: URL(fileURLWithPath: "/tmp/x.zip"))
    }

    @Test func TrainingSetDataVerifying_signature() throws {
        let f = FakeVerifier()
        try f.verifyNonEmpty(reader: FakeReader())
    }

    @Test func DownloadAcceptanceCleaning_signature() {
        let f = FakeCleaner()
        f.cleanup(tempURLs: [URL(fileURLWithPath: "/tmp/x")])
    }

    @Test func protocols_areSendable() {
        let _: any Sendable = FakeIntegrity()
        let _: any Sendable = FakeExtractor()
        let _: any Sendable = FakeVerifier()
        let _: any Sendable = FakeCleaner()
    }
}

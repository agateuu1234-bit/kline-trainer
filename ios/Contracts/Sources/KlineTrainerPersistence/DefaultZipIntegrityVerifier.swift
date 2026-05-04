import Foundation
import ZIPFoundation
import KlineTrainerContracts

public struct DefaultZipIntegrityVerifier: ZipIntegrityVerifying {
    private static let chunkSize = 64 * 1024

    public init() { }

    public func verify(zipURL: URL, expectedCRC32Hex: String) throws {
        let crc: CRC32
        do {
            crc = try Self.streamingCRC32(of: zipURL)
        } catch {
            throw ZipErrorMapping.translate(error, fileURL: zipURL)
        }
        let actualHex = String(format: "%08x", crc)
        let expectedNormalized = expectedCRC32Hex.lowercased()
        guard actualHex == expectedNormalized else {
            throw AppError.trainingSet(.crcFailed)
        }
    }

    private static func streamingCRC32(of url: URL) throws -> CRC32 {
        // R4 codex finding 3：不显式 throw NSError 以兼容 Task 6 grep gate；
        // FileHandle(forReadingFrom:) 在文件不存在 / 不可读时会自然抛 NSCocoaErrorDomain
        // (NSFileNoSuchFileError / NSFileReadNoPermissionError)，由外层 verify 的
        // ZipErrorMapping.translate 翻译成 AppError.trainingSet(.fileNotFound) / .ioError
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var crc: CRC32 = 0
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            crc = chunk.crc32(checksum: crc)
        }
        return crc
    }
}

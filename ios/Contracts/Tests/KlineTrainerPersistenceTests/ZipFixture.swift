import Foundation
import ZIPFoundation

enum ZipFixture {
    /// 在 directoryURL 下生成一个含 1 个 sqlite 文件的最小 zip。
    /// 返回 (zipURL, expectedCRC32Hex 8 字符小写)。
    /// directoryURL 必须事先存在；调用方负责 cleanup。
    static func makeMinimalSqliteZip(
        in directoryURL: URL,
        zipFileName: String = "test.zip",
        sqliteFileName: String = "training.sqlite",
        sqlitePayload: Data = sqliteHeaderBytes()
    ) throws -> (zipURL: URL, expectedCRC32Hex: String) {
        let zipURL = directoryURL.appendingPathComponent(zipFileName)
        try? FileManager.default.removeItem(at: zipURL)

        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(
            with: sqliteFileName,
            type: .file,
            uncompressedSize: Int64(sqlitePayload.count),
            compressionMethod: .deflate,
            provider: { (position, size) in
                let p = Int(position)
                let s = Int(size)
                return sqlitePayload.subdata(in: p..<(p + s))
            }
        )
        let zipData = try Data(contentsOf: zipURL)
        let crc = zipData.crc32(checksum: 0)
        let crcHex = String(format: "%08x", crc)
        return (zipURL, crcHex)
    }

    /// SQLite header magic 字节（"SQLite format 3\0"）+ 16 字节 padding，
    /// 不构成可打开的 db，仅用于 zip entry 内容占位。
    static func sqliteHeaderBytes() -> Data {
        let magic = Array("SQLite format 3\0".utf8)
        return Data(magic + [UInt8](repeating: 0, count: 16))
    }

    /// 计算文件 IEEE CRC32 8 字符小写。
    static func crc32Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let crc = data.crc32(checksum: 0)
        return String(format: "%08x", crc)
    }
}

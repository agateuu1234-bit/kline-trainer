// Kline Trainer Swift Contracts — P2 port 1
// Spec: kline_trainer_modules_v1.4.md §P2 line 1753-1757

import Foundation

public protocol ZipIntegrityVerifying: Sendable {
    /// 校验 zipURL 的 CRC32 是否等于 expectedCRC32Hex（8 字符小写 IEEE polynomial）。
    /// 算法：对整个 zip 文件字节流算 zlib.crc32 等价 IEEE，输出 `%08x` 小写。
    /// - throws AppError.trainingSet(.crcFailed) 不匹配
    /// - throws AppError.trainingSet(.fileNotFound) zip 文件不存在
    /// - throws AppError.persistence(.ioError) 其它读取失败
    func verify(zipURL: URL, expectedCRC32Hex: String) throws
}

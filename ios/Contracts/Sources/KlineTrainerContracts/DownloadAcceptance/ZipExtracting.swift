// Kline Trainer Swift Contracts — P2 port 2
// Spec: kline_trainer_modules_v1.4.md §P2 line 1759-1763
//       B2 形态契约 modules L716 + plan_v1.5 L1087："压缩 zip" = exactly 1 sqlite

import Foundation

public protocol ZipExtracting: Sendable {
    /// 解压 zipURL 到新建的临时目录，返回唯一 sqlite 文件 URL。
    ///
    /// **strict shape 契约**（spec L716 B2 zip 形态 enforce）：
    /// - zip 必须 exactly 1 个 regular file 且 path 后缀 `.sqlite`（lowercased）
    /// - 0 个 sqlite / ≥2 个 sqlite / 含任何其它 regular file → throw `.unzipFailed`
    /// - dir entry / symlink entry 不计；嵌套路径（subdir 内）也算 entry
    /// - **必须解压前校验 archive 形态**，避免恶意 zip 用大量 junk sidecar 消耗临时磁盘
    ///
    /// 临时目录归调用方管理（典型经 DownloadAcceptanceCleaning.cleanup 释放）。
    ///
    /// - throws AppError.trainingSet(.unzipFailed) shape 不符 / 解压失败 / archive 损坏
    /// - throws AppError.trainingSet(.fileNotFound) zip 文件不存在
    /// - throws AppError.persistence(.diskFull) 临时目录写满
    /// - throws AppError.persistence(.ioError) 其它 IO 失败
    func extract(zipURL: URL) throws -> URL
}

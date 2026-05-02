import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// GRDB / Foundation IO 错误到 AppError 的边界翻译（per docs/governance/m04-apperror-translation-gate.md）。
/// 仅 KlineTrainerPersistence 模块内部使用；不暴露 GRDB 类型给 contracts 消费者。
///
/// 设计要点（per plan Design Decision §7）：
/// - ResultCode 是 struct（GRDB 6+），用 == 比较不能用 enum-style switch case
/// - ioError 关联值脱敏（不放 dbErr.message，避免泄漏路径 / 环境信息到崩溃上报）
enum PersistenceErrorMapping {
    /// 把任意 swift Error 转为 AppError。GRDB DatabaseError 按 result code 细分；其它走 .ioError。
    static func translate(_ error: Error, fileURL: URL? = nil) -> AppError {
        if let app = error as? AppError {
            return app  // 已是 AppError 直通（防双重翻译）
        }
        if let dbErr = error as? DatabaseError {
            // ResultCode 是 struct，用 == 比较
            if dbErr.resultCode == .SQLITE_CANTOPEN {
                if let url = fileURL,
                   !FileManager.default.fileExists(atPath: url.path) {
                    return .trainingSet(.fileNotFound)
                }
                return .persistence(.ioError("sqlite_cantopen"))
            }
            if dbErr.resultCode == .SQLITE_NOTADB || dbErr.resultCode == .SQLITE_CORRUPT {
                return .persistence(.dbCorrupted)
            }
            // 兜底：脱敏 token，不放 dbErr.message（含路径 / 环境信息）
            return .persistence(.ioError("sqlite_error_\(dbErr.resultCode.rawValue)"))
        }
        let nsErr = error as NSError
        if nsErr.domain == NSCocoaErrorDomain &&
           (nsErr.code == NSFileNoSuchFileError || nsErr.code == NSFileReadNoSuchFileError) {
            return .trainingSet(.fileNotFound)
        }
        return .persistence(.ioError("io_error"))
    }
}

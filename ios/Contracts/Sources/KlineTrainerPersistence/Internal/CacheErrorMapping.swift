import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// FileManager / Foundation IO 错误到 AppError 的边界翻译。
/// 仅 KlineTrainerPersistence 模块内部使用。
enum CacheErrorMapping {
    static func translate(_ error: Error) -> AppError {
        if let app = error as? AppError { return app }

        if let dbErr = error as? DatabaseError {
            if dbErr.resultCode == .SQLITE_CANTOPEN || dbErr.resultCode == .SQLITE_NOTADB
                || dbErr.resultCode == .SQLITE_CORRUPT {
                return .persistence(.dbCorrupted)
            }
            return .persistence(.ioError("sqlite_error_\(dbErr.resultCode.rawValue)"))
        }

        let nsErr = error as NSError
        if nsErr.domain == NSCocoaErrorDomain {
            switch nsErr.code {
            case NSFileWriteOutOfSpaceError:
                return .persistence(.diskFull)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .trainingSet(.fileNotFound)
            case NSFileWriteFileExistsError:
                return .persistence(.ioError("file_exists"))
            default:
                return .persistence(.ioError("filesystem_error"))
            }
        }
        return .persistence(.ioError("filesystem_error"))
    }
}

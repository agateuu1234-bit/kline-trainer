import Foundation
import ZIPFoundation
import KlineTrainerContracts

/// ZipFoundation / Foundation IO Error → AppError 边界翻译
/// （per docs/governance/m04-apperror-translation-gate.md，参考 PersistenceErrorMapping 模式）。
/// 仅 KlineTrainerPersistence 内部使用；不暴露 ZipFoundation 类型给 contracts 消费者。
enum ZipErrorMapping {
    static func translate(_ error: Error, fileURL: URL? = nil) -> AppError {
        if let app = error as? AppError {
            return app                                  // 已是 AppError 直通（防双翻译）
        }
        if let _ = error as? Archive.ArchiveError {
            return .trainingSet(.unzipFailed)           // 全部 Archive 错误归 unzipFailed
        }
        // R5 codex finding 2：递归 unwrap NSUnderlyingErrorKey 后再判 domain
        let unwrapped = unwrapUnderlying(error)
        if unwrapped.domain == NSCocoaErrorDomain {
            switch unwrapped.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return .trainingSet(.fileNotFound)
            case NSFileWriteOutOfSpaceError:
                return .persistence(.diskFull)
            default:
                break
            }
        }
        // POSIX ENOENT (2)：FileHandle(forReadingFrom:) 在父目录不存在时抛 NSPOSIXErrorDomain/ENOENT
        if unwrapped.domain == NSPOSIXErrorDomain &&
           unwrapped.code == Int(POSIXErrorCode.ENOENT.rawValue) {
            return .trainingSet(.fileNotFound)
        }
        // R5：POSIX ENOSPC (28) 与 cocoa NSFileWriteOutOfSpaceError 等价
        if unwrapped.domain == NSPOSIXErrorDomain &&
           unwrapped.code == Int(POSIXErrorCode.ENOSPC.rawValue) {
            return .persistence(.diskFull)
        }
        return .persistence(.ioError("zip_io_error"))   // 脱敏，不放原始 message
    }

    /// 递归 unwrap NSUnderlyingErrorKey 链，返回最深层 NSError。
    /// 防止 cocoa 包 POSIX 时 ENOSPC 被 .ioError 兜底吞掉。
    private static func unwrapUnderlying(_ error: Error) -> NSError {
        var current = error as NSError
        while let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError,
              underlying !== current {
            current = underlying
        }
        return current
    }
}

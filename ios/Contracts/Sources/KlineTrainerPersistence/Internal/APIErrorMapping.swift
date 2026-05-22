import Foundation
import KlineTrainerContracts

/// URLError → AppError.network 边界翻译（仅 KlineTrainerPersistence 模块内部使用；
/// 对齐 CacheErrorMapping 风格）。HTTP 状态码映射在 DefaultAPIClient 内联
/// （依赖具体 endpoint 语义，见各方法）。
enum APIErrorMapping {
    static func translate(_ error: Error) -> AppError {
        if let app = error as? AppError { return app }
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .timedOut:
                return .network(.timeout)
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dataNotAllowed, .internationalRoamingOff:
                return .network(.offline)
            default:
                // NetworkReason 词汇内无 unknown 类目（M0.4 L655）；其它传输层
                // URLError（badServerResponse / cannotParseResponse 等）保守归
                // offline（传输失败、isRecoverable=true，可重试）。
                return .network(.offline)
            }
        }
        // 非 URLError 的传输层异常（罕见）→ fail-closed 标 P1。
        return .internalError(module: "P1", detail: "transport_error")
    }
}

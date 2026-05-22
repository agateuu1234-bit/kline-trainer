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
                 .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
                 .callIsActive:
                // 真 transient connectivity → 可重试。
                return .network(.offline)
            default:
                // codex branch-diff F1：TLS/证书/ATS/auth/badServerResponse/unsupportedURL 等
                // 是 terminal（重试无意义 + 安全/配置问题不应静默重试）→ 标 P1 terminal。
                return .internalError(module: "P1", detail: "url_error_\(urlErr.code.rawValue)")
            }
        }
        // 非 URLError 的传输层异常（罕见）→ fail-closed 标 P1。
        return .internalError(module: "P1", detail: "transport_error")
    }
}

// Kline Trainer Swift Contracts — M0.4 Error Handling
// Spec: kline_trainer_modules_v1.4.md §M0.4
//
// 顶层错误类型 AppError + 4 个 Reason 子枚举。全部值类型，Error + Equatable + Sendable。
// 设计原则（M0.4 spec 重写）：**私有错误在本模块边界内转 AppError，调用方只消费 AppError**。
// 各模块（P1/P3/P4/E3/P2/UI）如何翻译自己的内部错误到 AppError 属模块实现约束，归各自
// module plan（Plan 2/3）落地；本 plan 只冻结 AppError 类型体 + 3 个 UI 扩展方法。

import Foundation

public enum AppError: Error, Equatable, Sendable {
    case network(NetworkReason)
    case persistence(PersistenceReason)
    case trade(TradeReason)
    case trainingSet(TrainingSetReason)
    /// internalError 强制标识来源模块 + detail 消息。
    /// CI lint 规则（未来 governance 层实现）：`.internalError` 仅当错误无法归入前 4 类时允许。
    case internalError(module: String, detail: String)
}

public enum NetworkReason: Error, Equatable, Sendable {
    case timeout
    case offline
    case serverError(code: Int)
    case leaseExpired
    case leaseNotFound
}

public enum PersistenceReason: Error, Equatable, Sendable {
    case diskFull
    case dbCorrupted
    case schemaMismatch(expected: Int, got: Int)
    case ioError(String)
}

public enum TradeReason: Error, Equatable, Sendable {
    case insufficientCash
    case insufficientHolding
    case disabled
    case invalidShareCount
}

public enum TrainingSetReason: Error, Equatable, Sendable {
    case crcFailed
    case unzipFailed
    case emptyData
    case versionMismatch(expected: Int, got: Int)
    case fileNotFound
}

// MARK: - UI / Recovery Extensions

public extension AppError {
    /// 用户可见文案（中文）。UI 层通过 Toast / Alert 展示。
    var userMessage: String {
        switch self {
        case .network(let r):
            switch r {
            case .timeout: return "网络超时，请稍后重试"
            case .offline: return "无网络连接"
            case .serverError(let code): return "服务器错误（\(code)）"
            case .leaseExpired: return "下载凭证已过期，请重新预占"
            case .leaseNotFound: return "下载凭证不存在"
            }
        case .persistence(let r):
            switch r {
            case .diskFull: return "存储空间不足"
            case .dbCorrupted: return "本地数据损坏"
            case .schemaMismatch(let exp, let got):
                return "数据版本不匹配（期望 \(exp)，实际 \(got)）"
            case .ioError:
                // 不暴露 raw detail（可能含路径 / DB 底层错误 / 环境信息，泄漏到 UI 不合适）。
                // detail 仅用于 debug 日志 / 崩溃上报——codex round 1 MEDIUM finding。
                return "读写失败，请稍后重试"
            }
        case .trade(let r):
            switch r {
            case .insufficientCash: return "可用资金不足"
            case .insufficientHolding: return "持仓不足"
            case .disabled: return "当前不可操作"
            case .invalidShareCount: return "股数非法"
            }
        case .trainingSet(let r):
            switch r {
            case .crcFailed: return "训练组文件校验失败"
            case .unzipFailed: return "训练组解压失败"
            case .emptyData: return "训练组数据为空"
            case .versionMismatch(let exp, let got):
                return "训练组版本不匹配（期望 \(exp)，实际 \(got)）"
            case .fileNotFound: return "训练组文件不存在"
            }
        case .internalError(let module, _):
            return "内部错误（\(module)）"
        }
    }

    /// 当前 operation 重试是否可能恢复。
    /// true = transient（同一操作重试大概率自愈）；false = terminal（同一操作再试无意义）。
    /// "用户在 UI 层点重试" 以上的恢复（比如 lease 过期后重新 /meta）属更高层状态机
    /// （P2 DownloadAcceptance），不在本契约 scope 内——codex round 1 HIGH finding 要求区分。
    var isRecoverable: Bool {
        switch self {
        case .network(.timeout), .network(.offline):
            return true                          // transient 网络问题
        case .network(.serverError):
            return true                          // 5xx/429 转瞬性居多；P1 APIClient 映射时决定具体码
        case .network(.leaseExpired), .network(.leaseNotFound):
            return false                         // terminal: 对当前 lease operation 重试无意义
        case .persistence: return false          // 磁盘 / 损坏 / 架构失配都是环境问题
        case .trade: return false                // 业务规则层，不是重试能解决
        case .trainingSet(.versionMismatch), .trainingSet(.fileNotFound):
            return false                         // 客户端版本旧 / 服务端清理：重试无意义
        case .trainingSet: return true           // 其它 training-set（crc / unzip / empty）可重下
        case .internalError: return false
        }
    }

    /// UI 是否通过 Toast 展示。
    /// trade.disabled 由按钮禁用态自然呈现，不打 Toast；internalError 走 debug log。
    var shouldShowToast: Bool {
        switch self {
        case .trade(.disabled): return false
        case .internalError: return false
        default: return true
        }
    }
}

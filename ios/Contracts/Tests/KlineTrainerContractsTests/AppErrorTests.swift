import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("AppError Equatable")
struct AppErrorEquatableTests {
    @Test func network_leaseExpired_vs_leaseNotFound_areDistinct() {
        let a: AppError = .network(.leaseExpired)
        let b: AppError = .network(.leaseNotFound)
        #expect(a != b)
    }

    @Test func trainingSet_versionMismatch_comparesAssociatedValues() {
        let a: AppError = .trainingSet(.versionMismatch(expected: 1, got: 2))
        let b: AppError = .trainingSet(.versionMismatch(expected: 1, got: 2))
        let c: AppError = .trainingSet(.versionMismatch(expected: 1, got: 3))
        #expect(a == b)
        #expect(a != c)
    }

    @Test func persistence_schemaMismatch_associatedValues() {
        let a: AppError = .persistence(.schemaMismatch(expected: 1, got: 2))
        let b: AppError = .persistence(.schemaMismatch(expected: 1, got: 3))
        #expect(a != b)
    }

    @Test func internalError_comparesModuleAndDetail() {
        let a = AppError.internalError(module: "P2", detail: "x")
        let b = AppError.internalError(module: "P2", detail: "x")
        let c = AppError.internalError(module: "P3", detail: "x")
        let d = AppError.internalError(module: "P2", detail: "y")
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test func persistence_ioError_associatedString() {
        let a: AppError = .persistence(.ioError("disk"))
        let b: AppError = .persistence(.ioError("disk"))
        let c: AppError = .persistence(.ioError("net"))
        #expect(a == b)
        #expect(a != c)
    }
}

@Suite("AppError Sendable conformance")
struct AppErrorSendableTests {
    /// 编译时检查：AppError 及所有 Reason 必须 Sendable（跨 actor 传递）。
    /// 若任一类型缺 Sendable，下面的函数签名编译不过（@Sendable 闭包捕获必须 Sendable）。
    @Test func allTypes_sendableCompilesInActorClosure() async {
        let err: AppError = .network(.timeout)
        let nr: NetworkReason = .offline
        let pr: PersistenceReason = .diskFull
        let tr: TradeReason = .disabled
        let tsr: TrainingSetReason = .crcFailed

        // Capture each type in a @Sendable closure; compile = pass
        let _: @Sendable () -> Void = { _ = err }
        let _: @Sendable () -> Void = { _ = nr }
        let _: @Sendable () -> Void = { _ = pr }
        let _: @Sendable () -> Void = { _ = tr }
        let _: @Sendable () -> Void = { _ = tsr }
        #expect(true)
    }
}

@Suite("AppError userMessage")
struct AppErrorUserMessageTests {
    @Test func networkOffline_hasChineseMessage() {
        let m = AppError.network(.offline).userMessage
        #expect(m.contains("网络") || m.contains("连接"))
        #expect(!m.isEmpty)
    }

    @Test func allReasons_produceNonEmptyUserMessage() {
        let cases: [AppError] = [
            .network(.timeout),
            .network(.offline),
            .network(.serverError(code: 500)),
            .network(.leaseExpired),
            .network(.leaseNotFound),
            .persistence(.diskFull),
            .persistence(.dbCorrupted),
            .persistence(.schemaMismatch(expected: 1, got: 2)),
            .persistence(.ioError("x")),
            .trade(.insufficientCash),
            .trade(.insufficientHolding),
            .trade(.disabled),
            .trade(.invalidShareCount),
            .trainingSet(.crcFailed),
            .trainingSet(.unzipFailed),
            .trainingSet(.emptyData),
            .trainingSet(.versionMismatch(expected: 1, got: 2)),
            .trainingSet(.fileNotFound),
            .internalError(module: "M0", detail: "some"),
        ]
        for c in cases {
            let m = c.userMessage
            #expect(!m.isEmpty, "empty userMessage for \(c)")
        }
    }

    @Test func schemaMismatch_interpolatesNumbers() {
        let m = AppError.persistence(.schemaMismatch(expected: 3, got: 7)).userMessage
        #expect(m.contains("3") && m.contains("7"))
    }

    @Test func serverError_interpolatesCode() {
        let m = AppError.network(.serverError(code: 503)).userMessage
        #expect(m.contains("503"))
    }

    @Test func internalError_mentionsModule() {
        let m = AppError.internalError(module: "P4", detail: "xyz").userMessage
        #expect(m.contains("P4"))
    }

    /// codex round 1 MEDIUM finding：ioError raw detail 不应泄漏到 UI 文案。
    /// detail 可能含本地文件路径 / DB 底层错误 / 环境信息。
    @Test func ioError_rawDetailNotLeakedToUserMessage() {
        let sensitive = "/Users/maziming/Library/.../sensitive-path-SECRET-KEY"
        let m = AppError.persistence(.ioError(sensitive)).userMessage
        #expect(!m.contains(sensitive), "ioError raw detail leaked into userMessage")
        #expect(!m.contains("SECRET-KEY"))
        #expect(!m.contains("/Users/"))
        #expect(!m.isEmpty)  // 但仍要有通用提示
    }
}

@Suite("AppError isRecoverable")
struct AppErrorIsRecoverableTests {
    @Test func networkTransient_isRecoverable() {
        #expect(AppError.network(.timeout).isRecoverable == true)
        #expect(AppError.network(.offline).isRecoverable == true)
        #expect(AppError.network(.serverError(code: 500)).isRecoverable == true)
    }

    @Test func networkLeaseIssues_areNotRecoverable() {
        // lease 过期 / 不存在 = terminal（对当前 operation）。spec M0.2 confirm 409/404
        // 对应 P2 DownloadAcceptance 转 `rejected` 状态 + 清本地文件；重试同一 operation 无意义。
        // 客户端若要重来走更高层（P2 重新 /meta → 新 lease），不属于本 isRecoverable 契约。
        // codex round 1 [HIGH] finding 要求区分 transient 与 terminal。
        #expect(AppError.network(.leaseExpired).isRecoverable == false)
        #expect(AppError.network(.leaseNotFound).isRecoverable == false)
    }

    @Test func dbCorrupted_isNotRecoverable() {
        #expect(AppError.persistence(.dbCorrupted).isRecoverable == false)
    }

    @Test func persistenceIoErrors_areNotRecoverable() {
        #expect(AppError.persistence(.diskFull).isRecoverable == false)
        #expect(AppError.persistence(.ioError("x")).isRecoverable == false)
        #expect(AppError.persistence(.schemaMismatch(expected: 1, got: 2)).isRecoverable == false)
    }

    @Test func tradeErrors_areNotRecoverable() {
        #expect(AppError.trade(.insufficientCash).isRecoverable == false)
        #expect(AppError.trade(.insufficientHolding).isRecoverable == false)
        #expect(AppError.trade(.disabled).isRecoverable == false)
        #expect(AppError.trade(.invalidShareCount).isRecoverable == false)
    }

    @Test func trainingSetTransient_isRecoverable() {
        // crc 失败 / unzip 失败 / 数据为空 → 重下可恢复
        #expect(AppError.trainingSet(.crcFailed).isRecoverable == true)
        #expect(AppError.trainingSet(.unzipFailed).isRecoverable == true)
        #expect(AppError.trainingSet(.emptyData).isRecoverable == true)
    }

    @Test func trainingSetHardFailures_areNotRecoverable() {
        // version 不匹配 / 文件没找到 → 客户端版本不够 / 服务端清理了，重试无意义
        #expect(AppError.trainingSet(.versionMismatch(expected: 1, got: 2)).isRecoverable == false)
        #expect(AppError.trainingSet(.fileNotFound).isRecoverable == false)
    }

    @Test func internalError_isNotRecoverable() {
        #expect(AppError.internalError(module: "M", detail: "d").isRecoverable == false)
    }
}

@Suite("AppError shouldShowToast")
struct AppErrorShouldShowToastTests {
    @Test func tradeDisabled_doesNotShowToast() {
        // 按钮禁用态自然呈现，不打 Toast
        #expect(AppError.trade(.disabled).shouldShowToast == false)
    }

    @Test func internalError_doesNotShowToast() {
        // 走 debug log，不打扰用户
        #expect(AppError.internalError(module: "M", detail: "d").shouldShowToast == false)
    }

    @Test func networkOffline_showsToast() {
        #expect(AppError.network(.offline).shouldShowToast == true)
    }

    @Test func otherErrors_showToast() {
        // 默认除 trade.disabled + internalError 外都 Toast
        #expect(AppError.network(.timeout).shouldShowToast == true)
        #expect(AppError.persistence(.dbCorrupted).shouldShowToast == true)
        #expect(AppError.trade(.insufficientCash).shouldShowToast == true)
        #expect(AppError.trainingSet(.crcFailed).shouldShowToast == true)
    }
}

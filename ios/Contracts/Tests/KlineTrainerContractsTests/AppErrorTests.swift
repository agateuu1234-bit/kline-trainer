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

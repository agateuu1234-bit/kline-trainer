// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/SpecLiteralGuardTests.swift
// Spec: docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md §5.4
// 1 spec literal guard test. Compile-time + runtime checks that protocol shape stays stable.
// 跨平台：仅依赖 CoreGraphics + DrawingTool + DrawingToolManager（均跨平台）。

import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
struct SpecLiteralGuardTests {

    @Test("§5.4 #17 protocol signature guards against spec drift")
    func protocolSignatureGuardsAgainstSpecDrift() {
        // Guard (a): DrawingTool 必须 @MainActor protocol —— 编译期实证
        // SignatureGuardTool: DrawingTool 是 @MainActor final class；如果 protocol 改为 nonisolated
        // 则 @MainActor conformer 会触发 ConformanceIsolation 错误（Task 1 fix 已验证此 invariant）。
        let _: any DrawingTool = SignatureGuardTool()

        // Guard (b): DrawingToolManager 必须 @MainActor —— 编译期实证
        // 在 @MainActor 闭包内同步调用 manager init 必须成功；若 Manager 改为 nonisolated 也仍 OK，
        // 但若改为不同 actor 则编译失败
        _requireManagerMainActorIsolated()

        // Guard (c): requiredAnchors 必须是 ClosedRange<Int> —— 编译期赋值约束
        // 如果 protocol 改成 Range<Int> 或其他类型，下方赋值会编译失败
        let req: ClosedRange<Int> = SignatureGuardTool().requiredAnchors
        #expect(req.lowerBound <= req.upperBound)
    }
}

// Guard (b) helper：@MainActor func 内同步调用 manager init 必须成功
@MainActor private func _requireManagerMainActorIsolated() {
    _ = DrawingToolManager(enabledTools: [])
}

// SignatureGuardTool 是 @MainActor final class（与 protocol @MainActor 隔离一致）；
// 不需要 @unchecked Sendable（protocol DrawingTool 是 @MainActor isolated 不要求 Sendable）。
@MainActor
private final class SignatureGuardTool: DrawingTool {
    static var type: DrawingToolType { .horizontal }
    var requiredAnchors: ClosedRange<Int> { 1...2 }
    func render(ctx: CGContext, mapper: CoordinateMapper, drawing: DrawingObject, scheme: AppColorScheme) {}
    func hitTest(point: CGPoint, mapper: CoordinateMapper, drawing: DrawingObject) -> Bool { false }
}

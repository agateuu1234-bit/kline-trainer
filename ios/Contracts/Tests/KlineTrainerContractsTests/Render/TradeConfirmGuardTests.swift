// Tests/KlineTrainerContractsTests/Render/TradeConfirmGuardTests.swift
// Spec: split-addendum §4.1 交易边界（codex branch-R3-high / plan-R1,R3-high）：画线中确认转换绝不触发成交。
import Testing
@testable import KlineTrainerContracts

@Suite("TradeConfirmGuard：画线模式下确认转换绝不成交（performTrade spy）")
struct TradeConfirmGuardTests {
    @Test("apply：画线中即使 period/tick 有效，onProceed（performTrade）零调用")
    func applyBlocksWhileDrawing() {
        var traded = 0
        TradeConfirmGuard.apply(drawingModeActive: true, periodTickStillValid: true,
                                onProceed: { traded += 1 })
        #expect(traded == 0)                                   // 画线中绝不成交
    }
    @Test("apply：非画线+有效 → onProceed 触发一次；非画线+失效 → 不再触发")
    func applyNormalPaths() {
        var traded = 0
        TradeConfirmGuard.apply(drawingModeActive: false, periodTickStillValid: true,
                                onProceed: { traded += 1 })
        #expect(traded == 1)
        TradeConfirmGuard.apply(drawingModeActive: false, periodTickStillValid: false,
                                onProceed: { traded += 1 })
        #expect(traded == 1)                                   // 失效未再增
    }
    @Test("allowsConfirm 判据：画线→false，非画线+有效→true")
    func predicate() {
        #expect(!TradeConfirmGuard.allowsConfirm(drawingModeActive: true, periodTickStillValid: true))
        #expect(TradeConfirmGuard.allowsConfirm(drawingModeActive: false, periodTickStillValid: true))
    }
}

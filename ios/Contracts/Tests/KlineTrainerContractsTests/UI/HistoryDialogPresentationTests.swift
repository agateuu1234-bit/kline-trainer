// ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryDialogPresentationTests.swift
// Spec: docs/superpowers/specs/2026-06-20-history-dialog-centered-design.md D6/High-1/D13
// 平台无关：只 import Foundation（host swift test 直跑）。纯路由谓词的红绿覆盖。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("HistoryDialogPresentation routing")
struct HistoryDialogPresentationTests {

    private func makeRecord() -> TrainingRecord {
        TrainingRecord(
            id: 1, trainingSetFilename: "t.sqlite", createdAt: 1_700_000_000,
            stockCode: "600519", stockName: "贵州茅台", startYear: 2021, startMonth: 8,
            totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
            buyCount: 0, sellCount: 0,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            finalTick: 1000
        )
    }

    // MARK: - sheetItem：滤掉 .history（分流契约 / D6）

    @Test("sheetItem 对 .history 返 nil（不经共享 sheet）")
    func sheetItemFiltersHistory() {
        #expect(HistoryDialogPresentation.sheetItem(for: .history(makeRecord())) == nil)
    }

    @Test("sheetItem 对 .settings 原样透传")
    func sheetItemPassesSettings() {
        #expect(HistoryDialogPresentation.sheetItem(for: .settings)?.id == "settings")
    }

    @Test("sheetItem 对 .settlement 原样透传")
    func sheetItemPassesSettlement() {
        #expect(HistoryDialogPresentation.sheetItem(for: .settlement(makeRecord()))?.id == "settlement-1")
    }

    @Test("sheetItem 对 nil 返 nil")
    func sheetItemNil() {
        #expect(HistoryDialogPresentation.sheetItem(for: nil) == nil)
    }

    // MARK: - isHistoryPresented：仅 .history 为 true（动画驱动值 / D13）

    @Test("isHistoryPresented 仅 .history → true")
    func isHistoryTrueOnlyForHistory() {
        #expect(HistoryDialogPresentation.isHistoryPresented(.history(makeRecord())) == true)
        #expect(HistoryDialogPresentation.isHistoryPresented(.settings) == false)
        #expect(HistoryDialogPresentation.isHistoryPresented(.settlement(makeRecord())) == false)
        #expect(HistoryDialogPresentation.isHistoryPresented(nil) == false)
    }

    // MARK: - sheetDismissMayApply：High-1 守卫（history 态下 set no-op）

    @Test("sheetDismissMayApply 对 .history 返 false（守卫防 dialog 秒关）")
    func dismissGuardBlocksHistory() {
        #expect(HistoryDialogPresentation.sheetDismissMayApply(current: .history(makeRecord())) == false)
    }

    @Test("sheetDismissMayApply 对 settings/settlement/nil 返 true（正常 dismiss）")
    func dismissGuardAllowsOthers() {
        #expect(HistoryDialogPresentation.sheetDismissMayApply(current: .settings) == true)
        #expect(HistoryDialogPresentation.sheetDismissMayApply(current: .settlement(makeRecord())) == true)
        #expect(HistoryDialogPresentation.sheetDismissMayApply(current: nil) == true)
    }
}

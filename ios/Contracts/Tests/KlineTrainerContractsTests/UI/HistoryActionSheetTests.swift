// ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryActionSheetTests.swift
// Task A7: host-testable static helper for replay button title toggle.
// 平台无关：只 import Foundation（host swift test 直跑，不需 Catalyst）。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("HistoryActionSheet host tests")
struct HistoryActionSheetTests {

    @Test func replayButtonTitle_toggles() {
        #expect(HistoryActionSheet.replayButtonTitle(hasResumableReplay: false) == "再次训练")
        #expect(HistoryActionSheet.replayButtonTitle(hasResumableReplay: true) == "返回训练")
    }

    // Task 12: nonisolated static — 见 HistoryActionSheet.reviewButtonTitle 注释同理（PR#137 CI 教训）。
    @Test func reviewButtonTitle_toggles() {
        #expect(HistoryActionSheet.reviewButtonTitle(inProgress: false) == "复盘")
        #expect(HistoryActionSheet.reviewButtonTitle(inProgress: true) == "返回复盘")
    }
}

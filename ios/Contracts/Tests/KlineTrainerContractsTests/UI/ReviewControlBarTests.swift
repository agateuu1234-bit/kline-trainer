// ios/Contracts/Tests/KlineTrainerContractsTests/UI/ReviewControlBarTests.swift
// host-testable：纯内容模型 + flow 谓词。SwiftUI 薄壳及 onAction 接线由 Catalyst 编译闸门覆盖。

import Testing
@testable import KlineTrainerContracts

@Suite("ReviewControlBar host tests")
struct ReviewControlBarTests {

    // MARK: - 谓词测试（B1 后即绿，B4 回归锚）

    @Test("showsReviewControls 谓词：review=true，normal/replay=false")
    func showsReviewControls_predicate() {
        let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        let rec = TrainingRecord(id: 1, trainingSetFilename: "x", createdAt: 0, stockCode: "1", stockName: "n",
            startYear: 2021, startMonth: 1, totalCapital: 100000, profit: 0, returnRate: 0,
            maxDrawdown: 0, buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: 100)
        func shows(_ f: TrainingFlowController) -> Bool { f.canAdvance() && !f.canBuySell() }
        #expect(shows(ReviewFlow(record: rec, startTick: 0)) == true)
        #expect(shows(NormalFlow(fees: fees, maxTick: 100)) == false)
        #expect(shows(ReplayFlow(feeSnapshotFromOriginal: fees, maxTick: 100)) == false)
    }

    // MARK: - 内容模型测试（真红测：B4 前 ReviewControlBarContent 不存在 → 编译失败/红）

    @Test("ReviewControlBarContent buttons：showsJumpToEnd=false → 仅[下一根]")
    func reviewControlBarContent_buttons() {
        #expect(ReviewControlBarContent(showsJumpToEnd: false).buttons
                == [ReviewControlButton(action: .step, title: "下一根")])
        #expect(ReviewControlBarContent(showsJumpToEnd: true).buttons
                == [ReviewControlButton(action: .step, title: "下一根"),
                    ReviewControlButton(action: .jumpToEnd, title: "快进到结尾")])
    }
}

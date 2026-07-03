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
        #expect(ReviewControlBarContent(showsJumpToEnd: false, price: 10).buttons
                == [ReviewControlButton(action: .step, title: "下一根")])
        #expect(ReviewControlBarContent(showsJumpToEnd: true, price: 10).buttons
                == [ReviewControlButton(action: .step, title: "下一根"),
                    ReviewControlButton(action: .jumpToEnd, title: "快进到结尾")])
    }

    // MARK: - Task 8：priceLabel（训练底栏样式重设计，复刻 TradeActionBarContent 格式）

    @Test("priceLabel 格式与 TradeActionBarContent 一致：下单价 ¥ X,XXX.XX")
    func priceLabelFormat() {
        let c = ReviewControlBarContent(showsJumpToEnd: true, price: 1718.0)
        #expect(c.priceLabel == "下单价 ¥ 1,718.00")
        #expect(c.buttons.map(\.title) == ["下一根", "快进到结尾"])
    }

    @Test("singleButtonWhenNoJump：showsJumpToEnd=false → 仅[下一根]")
    func singleButtonWhenNoJump() {
        let c = ReviewControlBarContent(showsJumpToEnd: false, price: 10)
        #expect(c.buttons.map(\.title) == ["下一根"])
    }
}

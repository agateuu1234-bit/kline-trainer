// ios/Contracts/Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift
@testable import KlineTrainerContracts

// 造一条水平线 DrawingObject,只传关心的字段,其余取默认/固定(isExtended:false, panelPosition:0)。
func makeHLine(id: String = "hl", candleIndex: Int = 3, price: Double = 10,
               period: Period = .daily, thickness: Int = 1, text: String = "") -> DrawingObject {
    DrawingObject(id: id, toolType: .horizontal,
                  anchors: [DrawingAnchor(period: period, candleIndex: candleIndex, price: price)],
                  isExtended: false, panelPosition: 0, period: period, thickness: thickness, text: text)
}

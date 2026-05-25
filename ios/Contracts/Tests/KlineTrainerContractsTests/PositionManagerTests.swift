import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("PositionManager 核心")
struct PositionManagerCoreTests {

    @Test func emptyPositionIsZero() {
        let p = PositionManager()
        #expect(p.shares == 0)
        #expect(p.averageCost == 0)
        #expect(p.totalInvested == 0)
        #expect(p.holdingCost == 0)
    }

    @Test func publicInitConstructsKnownState() {
        let p = PositionManager(shares: 200, averageCost: 11.0, totalInvested: 2200.0)
        #expect(p.shares == 200)
        #expect(p.averageCost == 11.0)
        #expect(p.totalInvested == 2200.0)
    }

    @Test func holdingCostIsAverageCostTimesShares() {
        let p = PositionManager(shares: 300, averageCost: 5.0, totalInvested: 1500.0)
        #expect(p.holdingCost == 1500.0)
    }

    @Test func equatable() {
        let a = PositionManager(shares: 100, averageCost: 10.0, totalInvested: 1000.0)
        let b = PositionManager(shares: 100, averageCost: 10.0, totalInvested: 1000.0)
        let c = PositionManager(shares: 200, averageCost: 10.0, totalInvested: 2000.0)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func codableRoundTripOfValidPosition() throws {
        let p = PositionManager(shares: 100, averageCost: 10.0, totalInvested: 1000.0)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(PositionManager.self, from: data)
        #expect(decoded == p)
    }

    @Test func decoderRejectsNegativeShares() {
        let json = Data(#"{"shares":-1,"averageCost":0.0,"totalInvested":0.0}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PositionManager.self, from: json)
        }
    }
}

@Suite("PositionManager 交易")
struct PositionManagerTradeTests {

    @Test func buySingleSetsAverageCost() {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000.0)
        #expect(p.shares == 100)
        #expect(p.totalInvested == 1000.0)
        #expect(abs(p.averageCost - 10.0) < 1e-9)
    }

    @Test func buyMultipleAccumulatesWeightedAverage() {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000.0)   // avg 10
        p.buy(shares: 100, totalCost: 1200.0)   // total 2200 / 200 = 11
        #expect(p.shares == 200)
        #expect(p.totalInvested == 2200.0)
        #expect(abs(p.averageCost - 11.0) < 1e-9)
    }

    @Test func sellPartialKeepsAverageCost() {
        var p = PositionManager()
        p.buy(shares: 300, totalCost: 3000.0)   // avg 10
        p.sell(shares: 100)
        #expect(p.shares == 200)
        #expect(abs(p.averageCost - 10.0) < 1e-9)
        #expect(abs(p.totalInvested - 2000.0) < 1e-9)
    }

    @Test func sellFullClearsToZero() {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000.0)
        p.sell(shares: 100)
        #expect(p == PositionManager())
    }

    // D1：§4.2.1 入口 1b force-close 全零报价 → sell(0) no-op（不 trap）
    @Test func sellZeroIsNoOp() {
        var p = PositionManager(shares: 300, averageCost: 5.0, totalInvested: 1500.0)
        let before = p
        p.sell(shares: 0)
        #expect(p == before)
    }

    // sell(0) 在空仓上也 no-op（force-close holding==shares==0 路径）
    @Test func sellZeroOnEmptyIsNoOp() {
        var p = PositionManager()
        p.sell(shares: 0)
        #expect(p == PositionManager())
    }
}

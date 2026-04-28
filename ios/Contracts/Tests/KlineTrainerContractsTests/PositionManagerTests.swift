import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("PositionManager initial state")
struct PositionManagerInitialTests {
    @Test func initial_isEmpty() {
        let pm = PositionManager()
        #expect(pm.shares == 0)
        #expect(pm.averageCost == 0)
        #expect(pm.totalInvested == 0)
        #expect(pm.holdingCost == 0)
    }
}

@Suite("PositionManager buy")
struct PositionManagerBuyTests {
    @Test func singleBuy_setsState() {
        var pm = PositionManager()
        pm.buy(shares: 1000, totalCost: 12_345.0)
        #expect(pm.shares == 1000)
        #expect(pm.averageCost == 12.345)
        #expect(pm.totalInvested == 12_345.0)
        #expect(pm.holdingCost == 12_345.0)
    }

    @Test func twoBuys_averagedCost() {
        var pm = PositionManager()
        pm.buy(shares: 1000, totalCost: 10_000.0)
        pm.buy(shares: 1000, totalCost: 12_000.0)
        #expect(pm.shares == 2000)
        #expect(pm.averageCost == 11.0)
        #expect(pm.totalInvested == 22_000.0)
        #expect(pm.holdingCost == 22_000.0)
    }

    @Test func threeBuys_weightedAverage() {
        var pm = PositionManager()
        pm.buy(shares: 100, totalCost: 1_000.0)
        pm.buy(shares: 200, totalCost: 2_400.0)
        pm.buy(shares: 700, totalCost: 7_700.0)
        #expect(pm.shares == 1000)
        #expect(pm.totalInvested == 11_100.0)
        #expect(pm.averageCost == 11.1)
    }
}

@Suite("PositionManager sell")
struct PositionManagerSellTests {
    @Test func partialSell_preservesAverageCost() {
        var pm = PositionManager()
        pm.buy(shares: 1000, totalCost: 11_000.0)
        pm.sell(shares: 400)
        #expect(pm.shares == 600)
        #expect(pm.averageCost == 11.0)
        #expect(pm.totalInvested == 6_600.0)
    }

    @Test func fullSell_clearsAllState() {
        var pm = PositionManager()
        pm.buy(shares: 1000, totalCost: 11_000.0)
        pm.sell(shares: 1000)
        #expect(pm.shares == 0)
        #expect(pm.averageCost == 0)
        #expect(pm.totalInvested == 0)
        #expect(pm.holdingCost == 0)
    }

    @Test func sellThenBuy_reaveragesFromZero() {
        var pm = PositionManager()
        pm.buy(shares: 1000, totalCost: 11_000.0)
        pm.sell(shares: 1000)
        pm.buy(shares: 500, totalCost: 6_000.0)
        #expect(pm.shares == 500)
        #expect(pm.averageCost == 12.0)
        #expect(pm.totalInvested == 6_000.0)
    }
}

@Suite("PositionManager positionTier")
struct PositionManagerPositionTierTests {
    @Test func emptyPosition_isTierZero() {
        let pm = PositionManager()
        #expect(pm.positionTier(totalCapital: 100_000, currentPrice: 10.0) == 0)
    }

    @Test func quarterPositionByCost_isTier1() {
        // 25% of 100k capital → 25k value → tier 1 (1/5 = 20%, closest)
        var pm = PositionManager()
        pm.buy(shares: 2500, totalCost: 25_000)
        #expect(pm.positionTier(totalCapital: 100_000, currentPrice: 10.0) == 1)
    }

    @Test func halfPosition_isTier2() {
        // 40% holding value at current price → between tier2 (40%) and tier3 (60%); 40% maps to tier2
        var pm = PositionManager()
        pm.buy(shares: 4000, totalCost: 40_000)
        #expect(pm.positionTier(totalCapital: 100_000, currentPrice: 10.0) == 2)
    }

    @Test func fullPosition_isTier5() {
        var pm = PositionManager()
        pm.buy(shares: 10_000, totalCost: 100_000)
        #expect(pm.positionTier(totalCapital: 100_000, currentPrice: 10.0) == 5)
    }

    @Test func roundsToNearestTier() {
        // 30% holding value → between tier1 (20%) and tier2 (40%); 30% rounds to tier2 (closer? equidistant rounds up)
        var pm = PositionManager()
        pm.buy(shares: 3000, totalCost: 30_000)
        let tier = pm.positionTier(totalCapital: 100_000, currentPrice: 10.0)
        #expect(tier == 1 || tier == 2)  // either rounding direction acceptable for equidistant case
    }

    @Test func zeroTotalCapital_isTierZero() {
        var pm = PositionManager()
        pm.buy(shares: 1000, totalCost: 10_000)
        #expect(pm.positionTier(totalCapital: 0, currentPrice: 10.0) == 0)
    }
}

@Suite("PositionManager Codable")
struct PositionManagerCodableTests {
    @Test func roundTrip_preservesState() throws {
        var pm = PositionManager()
        pm.buy(shares: 1500, totalCost: 16_500.0)
        pm.sell(shares: 500)

        let encoded = try JSONEncoder().encode(pm)
        let decoded = try JSONDecoder().decode(PositionManager.self, from: encoded)

        #expect(decoded == pm)
        #expect(decoded.shares == 1000)
        #expect(decoded.averageCost == 11.0)
        #expect(decoded.totalInvested == 11_000.0)
    }

    @Test func emptyPosition_roundTrips() throws {
        let pm = PositionManager()
        let encoded = try JSONEncoder().encode(pm)
        let decoded = try JSONDecoder().decode(PositionManager.self, from: encoded)
        #expect(decoded == pm)
    }
}

@Suite("PositionManager Equatable")
struct PositionManagerEquatableTests {
    @Test func sameState_areEqual() {
        var a = PositionManager()
        var b = PositionManager()
        a.buy(shares: 1000, totalCost: 10_000)
        b.buy(shares: 1000, totalCost: 10_000)
        #expect(a == b)
    }

    @Test func differentShares_areNotEqual() {
        var a = PositionManager()
        var b = PositionManager()
        a.buy(shares: 1000, totalCost: 10_000)
        b.buy(shares: 500, totalCost: 5_000)
        #expect(a != b)
    }
}

@Suite("PositionManager Sendable")
struct PositionManagerSendableTests {
    @Test func conformsToSendable() {
        // Compile-time check: passing to a Sendable-requiring context
        let pm: any Sendable = PositionManager()
        _ = pm
    }
}

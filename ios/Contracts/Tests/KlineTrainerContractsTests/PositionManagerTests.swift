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

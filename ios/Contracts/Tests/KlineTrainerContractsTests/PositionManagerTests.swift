import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("PositionManager")
struct PositionManagerTests {

    @Test("default init is empty position")
    func defaultInit() {
        let p = PositionManager()
        #expect(p.shares == 0)
        #expect(p.averageCost == 0)
        #expect(p.totalInvested == 0)
        #expect(p.holdingCost == 0)
    }

    @Test("single buy sets weighted state correctly")
    func singleBuy() {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000)
        #expect(p.shares == 100)
        #expect(p.totalInvested == 1000)
        #expect(p.averageCost == 10.0)
        #expect(p.holdingCost == 1000)                 // 10.0 × 100 = 1000 exact
    }

    @Test("multiple buys produce weighted average cost")
    func weightedAverageBuys() {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000)            // avg 10.0
        p.buy(shares: 100, totalCost: 1500)            // (1000+1500)/200 = 12.5 exact dyadic
        #expect(p.shares == 200)
        #expect(p.totalInvested == 2500)
        #expect(p.averageCost == 12.5)
        #expect(p.holdingCost == 2500)                 // 12.5 × 200 = 2500 exact
    }

    @Test("partial sell reduces shares, keeps averageCost, recomputes totalInvested = avg * remaining")
    func partialSell() {
        var p = PositionManager()
        p.buy(shares: 200, totalCost: 2500)            // avg 12.5
        p.sell(shares: 50)
        #expect(p.shares == 150)
        #expect(p.averageCost == 12.5)
        #expect(p.totalInvested == 1875)               // 12.5 × 150 = 1875 exact
        #expect(p.holdingCost == 1875)                 // 卖出后 holdingCost 同步更新（守门：防 stored 而非 computed 的回归）
    }

    @Test("full sell zeroes averageCost and totalInvested")
    func fullSellResets() {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000)
        p.sell(shares: 100)
        #expect(p.shares == 0)
        #expect(p.averageCost == 0)
        #expect(p.totalInvested == 0)
        #expect(p.holdingCost == 0)
    }

    @Test("Equatable: identical states are equal, different states are not")
    func equatable() {
        var a = PositionManager()
        a.buy(shares: 100, totalCost: 1000)
        var b = PositionManager()
        b.buy(shares: 100, totalCost: 1000)
        #expect(a == b)

        var c = PositionManager()
        c.buy(shares: 200, totalCost: 2000)
        #expect(a != c)
    }

    @Test("Codable round-trip preserves all state")
    func codableRoundTrip() throws {
        var original = PositionManager()
        original.buy(shares: 200, totalCost: 2500)         // avg 12.5

        let json = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PositionManager.self, from: json)

        #expect(decoded == original)
        #expect(decoded.shares == 200)
        #expect(decoded.averageCost == 12.5)
        #expect(decoded.totalInvested == 2500)
    }

    @Test("Codable JSON keys are camelCase (averageCost / totalInvested)")
    func codableJsonKeys() throws {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000)
        let data = try JSONEncoder().encode(p)
        // 用 JSONSerialization 解键名，避免 Double 渲染（"10" vs "10.0"）的字符串脆性。
        // Wave 0 §M0.1 position_data 列契约靠 round-trip 保证；本测试只锁键名约定。
        let dict = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict.keys.sorted() == ["averageCost", "shares", "totalInvested"])
    }
}

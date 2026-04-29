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
    func singleBuy() throws {
        var p = PositionManager()
        try p.buy(shares: 100, totalCost: 1000)
        #expect(p.shares == 100)
        #expect(p.totalInvested == 1000)
        #expect(p.averageCost == 10.0)
        #expect(p.holdingCost == 1000)                 // 10.0 × 100 = 1000 exact
    }

    @Test("multiple buys produce weighted average cost")
    func weightedAverageBuys() throws {
        var p = PositionManager()
        try p.buy(shares: 100, totalCost: 1000)        // avg 10.0
        try p.buy(shares: 100, totalCost: 1500)        // (1000+1500)/200 = 12.5 exact dyadic
        #expect(p.shares == 200)
        #expect(p.totalInvested == 2500)
        #expect(p.averageCost == 12.5)
        #expect(p.holdingCost == 2500)                 // 12.5 × 200 = 2500 exact
    }

    @Test("partial sell reduces shares, keeps averageCost, recomputes totalInvested = avg * remaining")
    func partialSell() throws {
        var p = PositionManager()
        try p.buy(shares: 200, totalCost: 2500)        // avg 12.5
        try p.sell(shares: 50)
        #expect(p.shares == 150)
        #expect(p.averageCost == 12.5)
        #expect(p.totalInvested == 1875)               // 12.5 × 150 = 1875 exact
        #expect(p.holdingCost == 1875)                 // 卖出后 holdingCost 同步更新（守门：防 stored 而非 computed 的回归）
    }

    @Test("full sell zeroes averageCost and totalInvested")
    func fullSellResets() throws {
        var p = PositionManager()
        try p.buy(shares: 100, totalCost: 1000)
        try p.sell(shares: 100)
        #expect(p.shares == 0)
        #expect(p.averageCost == 0)
        #expect(p.totalInvested == 0)
        #expect(p.holdingCost == 0)
    }

    @Test("Equatable: identical states are equal, different states are not")
    func equatable() throws {
        var a = PositionManager()
        try a.buy(shares: 100, totalCost: 1000)
        var b = PositionManager()
        try b.buy(shares: 100, totalCost: 1000)
        #expect(a == b)

        var c = PositionManager()
        try c.buy(shares: 200, totalCost: 2000)
        #expect(a != c)
    }

    @Test("Codable round-trip preserves all state")
    func codableRoundTrip() throws {
        var original = PositionManager()
        try original.buy(shares: 200, totalCost: 2500)     // avg 12.5

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
        try p.buy(shares: 100, totalCost: 1000)
        let data = try JSONEncoder().encode(p)
        // 用 JSONSerialization 解键名，避免 Double 渲染（"10" vs "10.0"）的字符串脆性。
        // Wave 0 §M0.1 position_data 列契约靠 round-trip 保证；本测试只锁键名约定。
        let dict = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict.keys.sorted() == ["averageCost", "shares", "totalInvested"])
    }

    @Test("Decoder rejects malformed JSON: negative shares")
    func decoderRejectsNegativeShares() {
        let json = #"{"shares":-5,"averageCost":10,"totalInvested":50}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PositionManager.self, from: json)
        }
    }

    @Test("Decoder rejects malformed JSON: non-finite averageCost")
    func decoderRejectsNonFiniteCost() {
        // JSON 不允许字面 NaN/Infinity；但负 averageCost 同样违反不变量
        let json = #"{"shares":100,"averageCost":-1,"totalInvested":100}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PositionManager.self, from: json)
        }
    }

    @Test("Decoder rejects malformed JSON: shares=0 with non-zero cost")
    func decoderRejectsInconsistentEmpty() {
        let json = #"{"shares":0,"averageCost":0,"totalInvested":50}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PositionManager.self, from: json)
        }
    }

    @Test("Decoder rejects malformed JSON: shares > 0 with totalInvested != avg * shares")
    func decoderRejectsInconsistentPositive() {
        // Codex R3：shares=100 + averageCost=10 ⟹ totalInvested 应 = 1000；JSON 给 1 → 拒收
        let json = #"{"shares":100,"averageCost":10,"totalInvested":1}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PositionManager.self, from: json)
        }
    }

    @Test("Decoder rejects malformed JSON: shares > 0 with zero cost basis")
    func decoderRejectsZeroCostPositive() {
        // Codex R4-1：shares=100 + 全零成本 = 实际不可达状态（trade 必有正成本）→ 拒收
        let json = #"{"shares":100,"averageCost":0,"totalInvested":0}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PositionManager.self, from: json)
        }
    }

    @Test("Decoder rejects malformed JSON: avg × shares overflows to +inf")
    func decoderRejectsOverflowProduct() {
        // Codex R4-2：averageCost=1e308 × shares=100 → 1e310 = +inf；防止容差变 +inf 而 fall-open
        let json = #"{"shares":100,"averageCost":1e308,"totalInvested":1e308}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PositionManager.self, from: json)
        }
    }

    // MARK: - Codex R7 spec drift: throwing API tests

    @Test("buy throws TradeReason.invalidShareCount on zero shares")
    func buyThrowsOnZeroShares() {
        var p = PositionManager()
        #expect(throws: TradeReason.invalidShareCount) {
            try p.buy(shares: 0, totalCost: 1000)
        }
    }

    @Test("buy throws TradeReason.invalidShareCount on non-positive cost")
    func buyThrowsOnZeroCost() {
        var p = PositionManager()
        #expect(throws: TradeReason.invalidShareCount) {
            try p.buy(shares: 100, totalCost: 0)
        }
    }

    @Test("sell throws TradeReason.insufficientHolding on oversell")
    func sellThrowsOnOversell() throws {
        var p = PositionManager()
        try p.buy(shares: 100, totalCost: 1000)
        #expect(throws: TradeReason.insufficientHolding) {
            try p.sell(shares: 200)
        }
    }

    @Test("sell throws TradeReason.invalidShareCount on zero shares")
    func sellThrowsOnZeroShares() throws {
        var p = PositionManager()
        try p.buy(shares: 100, totalCost: 1000)
        #expect(throws: TradeReason.invalidShareCount) {
            try p.sell(shares: 0)
        }
    }
}

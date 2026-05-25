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

@Suite("PositionManager 持久化 decoder 守门")
struct PositionManagerCodableTests {

    private func decode(_ json: String) throws -> PositionManager {
        try JSONDecoder().decode(PositionManager.self, from: Data(json.utf8))
    }

    // ---- 5 个 reject case（§4.2.8 各条；negative-shares 已在 Task 1 PositionManagerCoreTests 守 TDD，不重复）----

    @Test func rejectsNegativeTotalInvested() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"shares":0,"averageCost":0.0,"totalInvested":-1.0}"#)
        }
    }

    // 超界数值：JSONDecoder 对 1e400 在 parse 阶段即抛 DecodingError（Swift Double 不可表示）；
    // 不依赖 decoder 自身 isFinite 分支（JSON 无法表达 NaN/Inf 字面），但结果同 → DecodingError。
    @Test func rejectsNonFiniteValues() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"shares":100,"averageCost":1e400,"totalInvested":1e400}"#)
        }
    }

    // (shares==0) ⟺ (totalInvested==0) 违反：空仓但有投入
    @Test func rejectsZeroSharesWithNonZeroTotal() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"shares":0,"averageCost":0.0,"totalInvested":100.0}"#)
        }
    }

    // (shares==0) ⟺ (totalInvested==0) 违反：有持仓但零投入
    @Test func rejectsPositiveSharesWithZeroTotal() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"shares":100,"averageCost":10.0,"totalInvested":0.0}"#)
        }
    }

    // shares>0 ⟹ averageCost>0 违反：有持仓但零均价
    @Test func rejectsPositiveSharesWithZeroAverageCost() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"shares":100,"averageCost":0.0,"totalInvested":1000.0}"#)
        }
    }

    // ---- D4 tol 双向 demonstrator ----

    // 正向：buy 产生真实除-乘 ULP 误差的合法存档 → decode 成功（若用 == 会拒收 → 反证 tol 必要）
    @Test func acceptsAppWrittenArchiveWithRoundingError() throws {
        var p = PositionManager()
        p.buy(shares: 300, totalCost: 1001.0)   // averageCost = 1001/300；avg*300 与 1001 差 ~1.1e-13（ULP）
        // 自证这是真 demonstrator：avg*shares 与 totalInvested 有非零 round 误差（严格 == 会拒收），但在 tol 内
        let gap = abs(p.averageCost * Double(p.shares) - p.totalInvested)
        #expect(gap > 0)
        #expect(gap <= PositionManager.invariantTolerance * max(1.0, abs(p.totalInvested)))
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(PositionManager.self, from: data)
        #expect(decoded == p)
    }

    // 负向 / mutation：合法态 totalInvested 篡改 2× 远超 tol → decode 抛（若 fall-open 会漏过）
    @Test func rejectsCorruptedTotalInvestedBeyondTolerance() {
        // 合法基准: shares=100, avg=10 → totalInvested 应 ≈1000；篡改成 2000
        #expect(throws: DecodingError.self) {
            try decode(#"{"shares":100,"averageCost":10.0,"totalInvested":2000.0}"#)
        }
    }

    // 边界：just-within tol 接受 / just-beyond tol 拒绝（证明 tol 是真判别阈，非 fall-open）
    @Test func tolBoundaryDiscriminates() throws {
        let exact = 10.0 * 100.0   // 1000，avg*shares
        let tol = PositionManager.invariantTolerance
        let margin = tol * max(1.0, abs(exact))
        let within = exact + 0.5 * margin
        let beyond = exact + 2.0 * margin

        let withinJSON = "{\"shares\":100,\"averageCost\":10.0,\"totalInvested\":\(within)}"
        #expect(throws: Never.self) {
            try decode(withinJSON)
        }

        let beyondJSON = "{\"shares\":100,\"averageCost\":10.0,\"totalInvested\":\(beyond)}"
        #expect(throws: DecodingError.self) {
            try decode(beyondJSON)
        }
    }
}

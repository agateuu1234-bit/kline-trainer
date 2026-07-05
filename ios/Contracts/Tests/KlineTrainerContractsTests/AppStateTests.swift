import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("DrawdownAccumulator")
struct DrawdownAccumulatorTests {
    @Test func initial_isZero() {
        let dd = DrawdownAccumulator.initial
        #expect(dd.peakCapital == 0)
        #expect(dd.maxDrawdown == 0)
    }

    @Test func update_tracksRisingPeak() {
        var dd = DrawdownAccumulator.initial
        dd.update(currentCapital: 100)
        #expect(dd.peakCapital == 100)
        #expect(dd.maxDrawdown == 0)

        dd.update(currentCapital: 150)
        #expect(dd.peakCapital == 150)
        #expect(dd.maxDrawdown == 0)
    }

    @Test func update_recordsDrawdownFromPeak() {
        var dd = DrawdownAccumulator.initial
        dd.update(currentCapital: 100)
        dd.update(currentCapital: 150)
        dd.update(currentCapital: 120)
        #expect(dd.peakCapital == 150)
        #expect(dd.maxDrawdown == 30)
    }

    @Test func update_keepsLargestDrawdown() {
        var dd = DrawdownAccumulator.initial
        dd.update(currentCapital: 100)
        dd.update(currentCapital: 200)
        dd.update(currentCapital: 150)  // drawdown 50
        dd.update(currentCapital: 180)  // drawdown shrinks to 20
        dd.update(currentCapital: 170)  // drawdown becomes 30
        #expect(dd.peakCapital == 200)
        #expect(dd.maxDrawdown == 50)   // 不回退
    }

    @Test func update_newPeakDoesNotResetMaxDrawdown() {
        var dd = DrawdownAccumulator.initial
        dd.update(currentCapital: 100)
        dd.update(currentCapital: 50)   // drawdown 50
        dd.update(currentCapital: 300)  // new peak
        #expect(dd.peakCapital == 300)
        #expect(dd.maxDrawdown == 50)
    }
}

@Suite("AppState Codable round-trip")
struct AppStateCodableTests {
    @Test func trainingRecord_finalTickPersists() throws {
        let rec = TrainingRecord(
            id: 7,
            trainingSetFilename: "AAPL_2020.zip",
            createdAt: 1_700_000_000,
            stockCode: "AAPL",
            stockName: "Apple",
            startYear: 2020,
            startMonth: 1,
            totalCapital: 100_000,
            profit: 1500,
            returnRate: 0.015,
            maxDrawdown: -0.05,
            buyCount: 3,
            sellCount: 2,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            finalTick: 4242
        )
        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(TrainingRecord.self, from: data)
        #expect(decoded == rec)
        #expect(decoded.finalTick == 4242)
    }

    // codex whole-branch Finding 1 修复：PendingTraining 恢复 Codable（public 契约类型，Task 11 因加
    // `lossy: LossyDrawingArray`（非 Codable）误丢——source-compat 破坏）。恢复走显式
    // init(from:)/encode(to:)（非 synthesized），CodingKeys 对齐 Task 11 之前的旧字段集（旧快照仍可解
    // 码），`drawings` 走计算属性投影往返、decode 侧用 `LossyDrawingArray(drawings:)` 重建已知条
    // （纯已知——本路径只是 compat surface；真正字节级保真持久化走 repo 的 `p.lossy.encoded()` 列路径，不受影响）。
    @Test func pendingTraining_codableRoundTrip() throws {
        let pend = PendingTraining(
            trainingSetFilename: "foo.zip",
            globalTickIndex: 10,
            upperPeriod: .daily,
            lowerPeriod: .m60,
            positionData: Data([1, 2, 3]),
            cashBalance: 9000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            tradeOperations: [],
            drawings: [DrawingObject(id: "d1", toolType: .horizontal, anchors: [],
                                     isExtended: false, panelPosition: 0)],
            startedAt: 1_700_000_000,
            accumulatedCapital: 10_000,
            drawdown: DrawdownAccumulator(peakCapital: 10_000, maxDrawdown: 500),
            sessionKey: "SK-test"
        )
        let data = try JSONEncoder().encode(pend)
        let decoded = try JSONDecoder().decode(PendingTraining.self, from: data)
        // 逐字段比对（不用整体 `==`：那会连带比较 `lossy` 内部 `raw` 原始字节，那是内部实现细节，
        // JSONEncoder 对同结构体两次独立 encode 不保证 key 顺序一致，非本 compat surface 的契约）。
        #expect(decoded.trainingSetFilename == pend.trainingSetFilename)
        #expect(decoded.globalTickIndex == pend.globalTickIndex)
        #expect(decoded.positionData == pend.positionData)
        #expect(decoded.cashBalance == 9000)
        #expect(decoded.tradeOperations == pend.tradeOperations)
        #expect(decoded.sessionKey == pend.sessionKey)
        #expect(decoded.drawdown.maxDrawdown == 500)
        #expect(decoded.drawings == pend.drawings)          // 内容保留（DrawingObject 自定义 == 不比 id）
        #expect(decoded.drawings.map(\.id) == ["d1"])       // id 也保留
    }

    @Test func appSettings_mutableRoundTrip() {
        let s = AppSettings(
            commissionRate: 0.0001,
            minCommissionEnabled: true,
            totalCapital: 100_000,
            displayMode: .dark
        )
        var s2 = s
        s2.displayMode = .system
        #expect(s != s2)
        #expect(s2.displayMode == .system)
    }
}

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

    @Test func pendingTraining_hasCashBalanceAndDrawdown() throws {
        let pend = PendingTraining(
            trainingSetFilename: "foo.zip",
            globalTickIndex: 10,
            upperPeriod: .daily,
            lowerPeriod: .m60,
            positionData: Data([1, 2, 3]),
            cashBalance: 9000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            tradeOperations: [],
            drawings: [],
            startedAt: 1_700_000_000,
            accumulatedCapital: 10_000,
            drawdown: DrawdownAccumulator(peakCapital: 10_000, maxDrawdown: 500)
        )
        let data = try JSONEncoder().encode(pend)
        let decoded = try JSONDecoder().decode(PendingTraining.self, from: data)
        #expect(decoded == pend)
        #expect(decoded.cashBalance == 9000)
        #expect(decoded.drawdown.maxDrawdown == 500)
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

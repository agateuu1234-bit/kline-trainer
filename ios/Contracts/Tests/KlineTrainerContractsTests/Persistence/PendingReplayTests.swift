import Testing
import Foundation
@testable import KlineTrainerContracts

@Test func pendingReplay_codableRoundTrip() throws {
    let p = PendingReplay(
        recordId: 42,
        trainingSetFilename: "a.sqlite", globalTickIndex: 7,
        upperPeriod: .m60, lowerPeriod: .daily,
        positionData: Data([1, 2, 3]), cashBalance: 99_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [],
        startedAt: 1_700_000_000, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(PendingReplay.self, from: data)
    #expect(back == p)
}

@Test func inMemoryPendingReplay_saveLoadClear() throws {
    let repo = InMemoryPendingReplayRepository()
    #expect(try repo.loadReplay() == nil)
    let p = PendingReplay(recordId: 5, trainingSetFilename: "b.sqlite", globalTickIndex: 1,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try repo.saveReplay(p)
    #expect(try repo.loadReplay() == p)
    #expect(repo.saveCount == 1)
    try repo.clearReplay()
    #expect(try repo.loadReplay() == nil)
}

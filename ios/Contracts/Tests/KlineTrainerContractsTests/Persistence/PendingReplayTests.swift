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

// MARK: - A2 coverage: novel methods

@Test func inMemoryPendingReplay_loadSlotInfo_doesNotConsumeFailNextLoadReplay() throws {
    let repo = InMemoryPendingReplayRepository()
    let p = PendingReplay(recordId: 99, trainingSetFilename: "c.sqlite", globalTickIndex: 3,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try repo.saveReplay(p)
    repo.failNextLoadReplay = .persistence(.dbCorrupted)
    // loadReplaySlotInfo must NOT consume failNextLoadReplay and must succeed
    let slot = try repo.loadReplaySlotInfo()
    #expect(slot?.recordId == 99)
    #expect(slot?.trainingSetFilename == "c.sqlite")
    // failNextLoadReplay is still armed — loadReplay must throw
    #expect(throws: AppError.self) { try repo.loadReplay() }
}

@Test func inMemoryPendingReplay_clearReplayIfRecordId_matching_clears() throws {
    let repo = InMemoryPendingReplayRepository()
    let p = PendingReplay(recordId: 7, trainingSetFilename: "d.sqlite", globalTickIndex: 0,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try repo.saveReplay(p)
    try repo.clearReplay(ifRecordId: 7)
    #expect(try repo.loadReplay() == nil)
}

@Test func inMemoryPendingReplay_clearReplayIfRecordId_nonMatching_keeps() throws {
    let repo = InMemoryPendingReplayRepository()
    let p = PendingReplay(recordId: 7, trainingSetFilename: "d.sqlite", globalTickIndex: 0,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try repo.saveReplay(p)
    try repo.clearReplay(ifRecordId: 999)   // mismatched recordId — slot must be retained
    #expect(try repo.loadReplaySlotInfo()?.recordId == 7)
}

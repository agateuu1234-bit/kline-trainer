import Testing
import Foundation
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingSessionLifecycle")
struct TrainingSessionLifecycleTests {

    typealias H = TrainingSessionPersistenceTests   // 复用 E6b 内存全栈 harness

    static func seedRecord(_ records: InMemoryRecordRepository, total: Double = 100_000) throws -> Int64 {
        try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "X", stockName: "X", startYear: 2020, startMonth: 1,
                           totalCapital: total, profit: 0, returnRate: 0, maxDrawdown: 0,
                           buyCount: 0, sellCount: 0,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
    }

    @Test("back: Normal 局 → saveProgress 写 pending + endSession 清活跃")
    func back_normal_savesAndEnds() async throws {
        let (coord, _, pending, _) = H.makeCoordinator(candles: H.validCandles(), capital: 50_000)
        coord.now = { 111 }
        let engine = try await coord.startNewNormalSession()
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        try await life.back()
        #expect(try pending.loadPending() != nil)
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }

    @Test("back: Review 局 → 不写 pending（非保存分支）+ endSession")
    func back_review_noSaveButEnds() async throws {
        let (coord, records, pending, _) = H.makeCoordinator(candles: H.validCandles())
        let id = try Self.seedRecord(records)
        let engine = try await coord.review(recordId: id)
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        try await life.back()
        #expect(try pending.loadPending() == nil)
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }

    @Test("back: Replay 局 → 不写 pending（非保存分支）+ endSession")
    func back_replay_noSaveButEnds() async throws {
        let (coord, records, pending, _) = H.makeCoordinator(candles: H.validCandles())
        let id = try Self.seedRecord(records, total: 80_000)
        let engine = try await coord.replay(recordId: id)
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        try await life.back()
        #expect(try pending.loadPending() == nil)
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }

    @Test("isAtEnd: fresh Normal tick0 < maxTick → false")
    func isAtEnd_freshNormal_false() async throws {
        let (coord, _, _, _) = H.makeCoordinator(candles: H.validCandles())
        let engine = try await coord.startNewNormalSession()
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.isAtEnd == false)
        #expect(engine.tick.maxTick == 7)
    }

    @Test("auto-end: Normal 在 maxTick → isAtEnd true；finalizeForSettlement 入账返 id + 清 pending")
    func autoEnd_normal_finalizesAndReturnsId() async throws {
        let meta = TrainingSetMeta(stockCode: "600519", stockName: "贵州茅台",
                                   startDatetime: 1, endDatetime: 2)
        let (coord, records, pending, _) = try H.resumeCoordinator(meta: meta)
        coord.now = { 1_700_000_000 }
        let engine = try #require(try await coord.resumePending())
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.isAtEnd == true)
        let id = try #require(try await life.finalizeForSettlement())
        let (rec, _, _) = try records.loadRecordBundle(id: id)
        #expect(rec.finalTick == 7)
        #expect(try pending.loadPending() == nil)
    }

    @Test("auto-end: Review → finalizeForSettlement 返 nil，不入账")
    func autoEnd_review_returnsNil() async throws {
        let (coord, records, _, _) = H.makeCoordinator(candles: H.validCandles())
        let id = try Self.seedRecord(records)
        let before = try records.listRecords(limit: nil).count
        let engine = try await coord.review(recordId: id)
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(try await life.finalizeForSettlement() == nil)
        #expect(try records.listRecords(limit: nil).count == before)
    }

    @Test("auto-end: Replay → finalizeForSettlement 返 nil，不入账")
    func autoEnd_replay_returnsNil() async throws {
        let (coord, records, _, _) = H.makeCoordinator(candles: H.validCandles())
        let id = try Self.seedRecord(records, total: 80_000)
        let before = try records.listRecords(limit: nil).count
        let engine = try await coord.replay(recordId: id)
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(try await life.finalizeForSettlement() == nil)
        #expect(try records.listRecords(limit: nil).count == before)
    }

    @Test("settlement-confirm: endAfterSettlement → 仅 endSession 清活跃")
    func endAfterSettlement_endsSession() async throws {
        let (coord, _, _, _) = H.makeCoordinator(candles: H.validCandles())
        let engine = try await coord.startNewNormalSession()
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        await life.endAfterSettlement()
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }

    @Test("shouldAutoFinalize: Normal at-end 未结算 → true")
    func shouldAutoFinalize_normalAtEnd_true() async throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 2)
        let (coord, _, _, _) = try H.resumeCoordinator(meta: meta)
        let engine = try #require(try await coord.resumePending())
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.isAtEnd == true)
        #expect(life.shouldAutoFinalize(didFinalize: false) == true)
    }

    @Test("shouldAutoFinalize: Normal at-end 已结算 → false（once-gate）")
    func shouldAutoFinalize_alreadyFinalized_false() async throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 2)
        let (coord, _, _, _) = try H.resumeCoordinator(meta: meta)
        let engine = try #require(try await coord.resumePending())
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.shouldAutoFinalize(didFinalize: true) == false)
    }

    @Test("shouldAutoFinalize: Review at-end → false（mode-gate killer）")
    func shouldAutoFinalize_review_false() async throws {
        let (coord, records, _, _) = H.makeCoordinator(candles: H.validCandles())
        let id = try Self.seedRecord(records)
        let engine = try await coord.review(recordId: id)
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.isAtEnd == true)
        #expect(life.shouldAutoFinalize(didFinalize: false) == false)
    }

    @Test("shouldAutoFinalize: fresh Normal not-at-end → false（isAtEnd-gate）")
    func shouldAutoFinalize_freshNormal_false() async throws {
        let (coord, _, _, _) = H.makeCoordinator(candles: H.validCandles())
        let engine = try await coord.startNewNormalSession()
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.shouldAutoFinalize(didFinalize: false) == false)
    }
}

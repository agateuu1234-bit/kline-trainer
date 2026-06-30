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

    @Test("shouldAutoFinalize: Review（B3：从训练起点非末根）→ false（mode-gate killer）")
    func shouldAutoFinalize_review_false() async throws {
        let (coord, records, _, _) = H.makeCoordinator(candles: H.validCandles())
        let id = try Self.seedRecord(records)
        let engine = try await coord.review(recordId: id)
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.isAtEnd == false)   // B3: review 从派生 startTick 开始，不在末根
        #expect(life.shouldAutoFinalize(didFinalize: false) == false)
    }

    @Test("shouldAutoFinalize: fresh Normal not-at-end → false（isAtEnd-gate）")
    func shouldAutoFinalize_freshNormal_false() async throws {
        let (coord, _, _, _) = H.makeCoordinator(candles: H.validCandles())
        let engine = try await coord.startNewNormalSession()
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.shouldAutoFinalize(didFinalize: false) == false)
    }

    // MARK: - Wave 3 顺位 8：replaySettlementRecord（RFC §4.4e/§4.5 非持久 replay 结算 payload 转发）

    @Test("replaySettlementRecord: Replay 交易+强平后 → 非持久 payload（id nil + totalCapital=起始资金 + profit 直通 + 原局 fees）")
    func replaySettlementRecord_replay_returnsPayload() async throws {
        let (coord, records, _, _) = H.makeCoordinator(candles: H.validCandles())
        let id = try Self.seedRecord(records, total: 80_000)
        let engine = try await coord.replay(recordId: id)
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        _ = engine.buy(panel: .upper, shares: 1600)       // 建非平凡终态（replay 可交易；1600 = 20%×80_000÷10）
        engine.forceCloseManually()                       // 强平须 caller 先行（D4）→ 持仓平
        #expect(engine.position.shares == 0)
        let payload = try await life.replaySettlementRecord()
        #expect(payload.id == nil)                        // 非持久（无 server id）
        #expect(payload.totalCapital == engine.initialCapital)   // D1 方案 A：起始资金
        #expect(payload.profit == engine.currentTotalCapital - engine.initialCapital)   // 终态收益直通
        #expect(payload.feeSnapshot == engine.fees)       // 原局 FeeSnapshot
    }

    @Test("replaySettlementRecord: Normal → throws（非 replay 守卫，转发 coordinator caller-contract）")
    func replaySettlementRecord_normal_throws() async throws {
        let (coord, _, _, _) = H.makeCoordinator(candles: H.validCandles())
        let engine = try await coord.startNewNormalSession()
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        await #expect(throws: AppError.self) { _ = try await life.replaySettlementRecord() }
    }
}

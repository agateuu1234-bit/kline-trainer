import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("TrainingSession 跨 feature 持久化加固（drawing/trade/replay × autosave/fence，10b）")
@MainActor
struct TrainingSessionCrossFeatureTests {

    @Test("交易成功后 autosave → resume 含该笔交易（buy 推 tick，§4.6 覆盖交易脏写）")
    func buy_then_autosave_then_resume_has_trade() async throws {
        let (coord, _, _, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        let before = engine.tradeOperations.count
        let r = engine.buy(panel: .upper, tier: .tier1)              // 改 position/cash + 推 tick
        guard case .success = r else { Issue.record("buy 须成功（50_000 本金可成交 tier1）"); return }
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        await coord.endSession()
        let resumed = try await coord.resumePending()
        #expect(resumed != nil)
        #expect((resumed?.tradeOperations.count ?? 0) > before)
    }

    @Test("画线 commit 后 autosave → resume 含该画线（engine.drawings 单一真相，#103×10b）")
    func draw_then_autosave_then_resume_has_drawing() async throws {
        let (coord, _, _, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        engine.appendDrawing(PIFixtures.sampleDrawing())
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        await coord.endSession()
        let resumed = try await coord.resumePending()
        #expect((resumed?.drawings.count ?? 0) == 1)
    }

    @Test("replay 非持久不变量在 autosave 下成立：requestAutosave 不写 records/pending（§4.4e×§4.6）")
    func replay_nonpersisting_holds_under_autosave() async throws {
        let (coord, records, pending, _) = PIFixtures.makeCoordinator()
        let n = try await coord.startNewNormalSession()
        while n.tick.globalTickIndex < n.tick.maxTick { n.holdOrObserve(panel: .upper) }
        let id = try await coord.finalize(engine: n)
        await coord.endSession()
        let r = try await coord.replay(recordId: id!)
        r.holdOrObserve(panel: .upper)
        coord.requestAutosave(engine: r, immediate: true)            // replay 下脏写
        await coord.drainAutosaveForTesting()
        #expect(try pending.loadPending() == nil)                    // 不触 pending
        #expect(try records.listRecords(limit: nil).count == 1)      // 不增 record
    }

    @Test("discard 画线局 → resume 无复活（drawing checkpoint 被 durable 清）")
    func discard_drawing_session_no_resurrection() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        engine.appendDrawing(PIFixtures.sampleDrawing())
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        try await coord.discardSession()
        #expect(try await coord.resumePending() == nil)
        _ = pending
    }
}

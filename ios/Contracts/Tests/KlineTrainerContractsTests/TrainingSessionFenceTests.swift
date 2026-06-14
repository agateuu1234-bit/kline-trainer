import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("TrainingSession 终态 fence（finalize 前排空 autosave，RFC §4.7d）")
@MainActor
struct TrainingSessionFenceTests {

    @Test("save-before-finalize: 在飞 autosave 被 fence drain，finalize 后 pending 清且 record 1 条")
    func autosave_before_finalize_drained_no_resurrection() async throws {
        let (coord, records, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        coord.requestAutosave(engine: engine, immediate: true)   // 末态脏写排队
        let id = try await coord.finalize(engine: engine)        // fence → drain → 单事务
        #expect(id != nil)
        #expect(try pending.loadPending() == nil)
        #expect(try records.listRecords(limit: nil).count == 1)
    }

    @Test("save-after-finalize-start: finalize 后 requestAutosave 被拒（terminating），pending 不复活")
    func autosave_after_finalize_is_rejected() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        _ = try await coord.finalize(engine: engine)
        coord.requestAutosave(engine: engine, immediate: true)   // 终态后迟到脏写
        await coord.drainAutosaveForTesting()
        #expect(try pending.loadPending() == nil)
    }

    @Test("crash-after-commit relaunch: finalize 成功后无 pending → resume 返 nil（不二次 finalize）")
    func finalize_then_resume_returns_nil() async throws {
        let (coord, records, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        _ = try await coord.finalize(engine: engine)
        await coord.endSession()
        #expect(try await coord.resumePending() == nil)
        #expect(try records.listRecords(limit: nil).count == 1)
        _ = pending
    }

    @Test("新 session 重置栅栏: finalize 后开新局 → autosave 恢复工作（terminating 重置）")
    func new_session_resets_fence() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let e1 = try await coord.startNewNormalSession()
        while e1.tick.globalTickIndex < e1.tick.maxTick { e1.holdOrObserve(panel: .upper) }
        _ = try await coord.finalize(engine: e1)
        await coord.endSession()
        let e2 = try await coord.startNewNormalSession()         // terminating 须重置
        e2.holdOrObserve(panel: .upper)
        coord.requestAutosave(engine: e2, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(try pending.loadPending() != nil)
    }
}

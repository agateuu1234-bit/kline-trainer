import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("TrainingSession autosave（周期落盘 + coalescing + 失败可见，RFC §4.6）")
@MainActor
struct TrainingSessionAutosaveTests {

    @Test("requestAutosave(immediate): Normal 活跃局 → 落 pending 含当前状态")
    func immediate_autosave_persists_current_state() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        engine.holdOrObserve(panel: .upper)                  // 推一 tick = 脏
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        let loaded = try pending.loadPending()
        #expect(loaded != nil)
        #expect(loaded?.globalTickIndex == engine.tick.globalTickIndex)
    }

    @Test("coalescing: 同 runloop 多次 request → 合并为 1 次 savePending（latest-wins，不排队）")
    func coalescing_collapses_burst_to_single_write() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        for _ in 0..<5 { coord.requestAutosave(engine: engine, immediate: true) }  // 同 hop 连发
        await coord.drainAutosaveForTesting()
        #expect(pending.saveCount == 1)
    }

    @Test("N-cadence: 非 immediate 按 AUTOSAVE_TICK_INTERVAL 节流（N=3 → 每 3 次脏存 1 次）")
    func tick_cadence_throttles_non_immediate() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        coord.autosaveTickInterval = 3
        let engine = try await coord.startNewNormalSession()
        for _ in 0..<3 {
            engine.holdOrObserve(panel: .upper)
            coord.requestAutosave(engine: engine, immediate: false)
            // drain 在前 2 次（未达 cadence、无 Task）为 no-op；第 3 次落盘后排空
            await coord.drainAutosaveForTesting()
        }
        #expect(pending.saveCount == 1)                      // 第 3 次才落盘
    }

    @Test("失败可见: savePending 抛 → lastAutosaveError 置位 + session 不 teardown（§4.6）")
    func autosave_failure_is_visible_and_non_teardown() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        pending.failNextSavePending = .persistence(.diskFull)
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(coord.lastAutosaveError == .persistence(.diskFull))
        #expect(coord.activeEngine === engine)
        #expect(coord.activeReader != nil)
    }

    @Test("review/replay 非 Normal: requestAutosave no-op（无 pending 语义）")
    func autosave_noop_for_non_normal() async throws {
        let (coord, records, pending, _) = PIFixtures.makeCoordinator()
        let n = try await coord.startNewNormalSession()
        while n.tick.globalTickIndex < n.tick.maxTick { n.holdOrObserve(panel: .upper) }
        let id = try await coord.finalize(engine: n)
        await coord.endSession()
        let r = try await coord.replay(recordId: id!)
        coord.requestAutosave(engine: r, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(try pending.loadPending() == nil)
        _ = records
    }
}

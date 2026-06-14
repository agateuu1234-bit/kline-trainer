import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("autosaveBannerError：autosave 失败的 UI 信号字段（§B.2，与 lastAutosaveError 解耦）")
@MainActor
struct AutosaveBannerTests {

    @Test("autosave 失败 → autosaveBannerError 置位（含 userMessage 可读错误）+ session 不 teardown")
    func failure_setsBanner_andDoesNotTeardown() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        pending.failNextSavePending = .persistence(.diskFull)
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(coord.autosaveBannerError == .persistence(.diskFull))
        #expect(coord.autosaveBannerError?.userMessage == "存储空间不足")
        #expect(coord.activeEngine === engine)
        #expect(coord.activeReader != nil)
    }

    @Test("autosave 成功 → autosaveBannerError 保持 nil")
    func success_keepsBannerNil() async throws {
        let (coord, _, _, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        engine.holdOrObserve(panel: .upper)
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(coord.autosaveBannerError == nil)
    }

    @Test("endSession 后 autosaveBannerError 清零（防 stale toast 跨局复活）")
    func endSession_clearsBanner() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        pending.failNextSavePending = .persistence(.diskFull)
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(coord.autosaveBannerError != nil)
        await coord.endSession()
        #expect(coord.autosaveBannerError == nil)
    }

    @Test("新 session 启动（resetAutosaveState）清零 banner")
    func newSession_clearsBanner() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let e1 = try await coord.startNewNormalSession()
        pending.failNextSavePending = .persistence(.diskFull)
        coord.requestAutosave(engine: e1, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(coord.autosaveBannerError != nil)
        await coord.endSession()
        _ = try await coord.startNewNormalSession()
        #expect(coord.autosaveBannerError == nil)
    }
}

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

    // 真实用户场景：上一局 autosave 失败（banner 置位）→ 退出（endSession 清）→ 开新局 → 无 stale toast。
    // 注：本测试覆盖 end→new-session 整链；`resetAutosaveState` 的 banner 清零（coordinator 第二处）是
    // 防御性冗余——D10 precondition 保证 startNewNormalSession 前必 endSession（已清），故 reset 处的清零
    // 在合规调用序下恒见 nil。两处清零是 spec §B.2 要求的 belt-and-suspenders（code-quality review Low 记录）。
    @Test("end→新 session 整链：上一局失败 banner 退出后不复活（无跨局 stale toast）")
    func endThenNewSession_noStaleBanner() async throws {
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

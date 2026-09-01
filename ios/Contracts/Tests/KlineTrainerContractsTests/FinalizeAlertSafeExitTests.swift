// Tests/KlineTrainerContractsTests/FinalizeAlertSafeExitTests.swift
// Q13 后续（codex R1-high）：「结算入账失败」弹窗的安全出口**不得依赖正在坏掉的那条存储路**。
//
// 背景：该弹窗最现实的触发原因就是**写盘失败**（磁盘满 / DB 损坏 / IO 错误）。
// 若安全出口走 `back()`（必须 saveProgress 成功才 endSession），那么在触发它的那种场景下
// 保存同样会失败 → 落进「保存进度失败」弹窗（只有再写一次 或 破坏性弃局）
// ⇒ 用户仍然没有可靠的非破坏性出口，仍被推向数据丢失。
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("Q13 安全退出：落盘失败也必须能非破坏性地退出")
@MainActor
struct FinalizeAlertSafeExitTests {

    @Test("落盘成功时：当前进度写进 pending、会话结束、如实返回 true")
    func savesWhenPersistenceWorks() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        let lifecycle = TrainingSessionLifecycle(engine: engine, coordinator: coord)

        let saved = await lifecycle.exitPreservingProgress()

        #expect(saved, "落盘成功时必须如实返回 true")
        #expect(try pending.loadPending() != nil, "进度必须留在 pending 里")
        #expect(coord.activeEngine == nil, "会话必须已结束")
    }

    @Test("⭐落盘失败时：仍然退出，且 pending 原样留存（⛔ 绝不因为存不了就清掉）")
    func exitsNonDestructivelyWhenSaveFails() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        // 先成功存一次，制造出「最近一次自动存档」——没有它就分不清
        // 「pending 被清掉了」与「本来就没存过」，断言会失去判别力。
        try await coord.saveProgress(engine: engine)
        let checkpoint = try #require(try pending.loadPending(), "前置：先要有一份存档")

        let lifecycle = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        pending.failNextSavePending = .persistence(.diskFull)      // 模拟磁盘满

        let saved = await lifecycle.exitPreservingProgress()

        #expect(!saved, "必须如实报告『这次没存成』，⛔ 不得谎称成功")
        let after = try #require(try pending.loadPending(),
                                 "⛔ pending 被清掉了 —— 安全出口变成了破坏性动作")
        #expect(after.globalTickIndex == checkpoint.globalTickIndex,
                "必须原样保留最近一次自动存档")
        #expect(coord.activeEngine == nil,
                "会话仍必须结束 —— 否则用户卡在原地出不去，等于没有出口")
    }

    @Test("反向对照：安全退出**不是**弃局 —— 它一次都不该碰清空那条路")
    func neverClearsPending() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        try await coord.saveProgress(engine: engine)
        let lifecycle = TrainingSessionLifecycle(engine: engine, coordinator: coord)

        // 让「清空」这条路一旦被走到就抛错：若安全退出误调了它，本档当场红。
        pending.failNextClearPending = .persistence(.ioError("clear 不该被调用"))
        _ = await lifecycle.exitPreservingProgress()

        #expect(try pending.loadPending() != nil, "安全退出后 pending 必须还在")
        #expect(pending.failNextClearPending != nil, "注入的 clear 故障仍未被消费 ⇒ 证明 clear 一次都没被调用")
    }
}

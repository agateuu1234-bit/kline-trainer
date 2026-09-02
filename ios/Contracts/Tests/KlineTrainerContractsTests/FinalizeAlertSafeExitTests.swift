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

        let outcome = await lifecycle.exitPreservingProgress()

        #expect(outcome == .savedCurrentState, "落盘成功时必须如实报告『存的是当前进度』")
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

        let outcome = await lifecycle.exitPreservingProgress()

        #expect(outcome == .keptEarlierCheckpoint, "必须如实报告『退回到旧存档』，⛔ 不得谎称存成了当前进度")
        let after = try #require(try pending.loadPending(),
                                 "⛔ pending 被清掉了 —— 安全出口变成了破坏性动作")
        #expect(after.globalTickIndex == checkpoint.globalTickIndex,
                "必须原样保留最近一次自动存档")
        #expect(coord.activeEngine == nil,
                "会话仍必须结束 —— 否则用户卡在原地出不去，等于没有出口")
    }

    @Test("⭐⭐无存档 + 落盘失败：⛔ 绝不能结束会话（否则整局只在内存里，一退就没）")
    func keepsSessionWhenNothingIsDurable() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        // ⚠️ **刻意不预先存档** —— 实测：开新局时磁盘上什么都没有（loadPending() == nil）。
        //    上一版本测试恰恰先成功存了一次，把这条**真正会出事的路**排除在外了（codex R2-high）。
        #expect(try pending.loadPending() == nil, "前置：此刻磁盘上确实没有任何存档")

        let lifecycle = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        pending.failNextSavePending = .persistence(.diskFull)      // 整局都存不进去

        let outcome = await lifecycle.exitPreservingProgress()

        #expect(outcome == .cannotPreserve,
                "既没存成、磁盘上也没有旧存档 ⇒ 必须如实报告『保不住』")
        #expect(coord.activeEngine === engine,
                "⛔ 会话必须保留 —— 此刻结束会话 = 把整局唯一的副本扔掉")
    }

    @Test("有旧存档 + 落盘失败：可以退出，如实报告『退回到旧存档』")
    func fallsBackToCheckpoint() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        try await coord.saveProgress(engine: engine)
        let checkpoint = try #require(try pending.loadPending())

        let lifecycle = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        pending.failNextSavePending = .persistence(.diskFull)

        let outcome = await lifecycle.exitPreservingProgress()

        #expect(outcome == .keptEarlierCheckpoint, "必须区分『存成了』与『退回旧存档』")
        #expect(try pending.loadPending()?.globalTickIndex == checkpoint.globalTickIndex,
                "旧存档必须原样留着")
        #expect(coord.activeEngine == nil, "有东西保住了 ⇒ 可以安全退出")
    }

    @Test("存档必须**属于本局**：别的会话留下的 pending 不算数（codex R3-high）")
    func foreignCheckpointDoesNotCount() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        try await coord.saveProgress(engine: engine)
        let mine = try #require(try pending.loadPending())
        #expect(coord.hasDurablePendingCheckpoint(for: engine), "前置：自己的存档当然算数")

        // 把磁盘上那条换成**别的会话**留下的（只改 sessionKey，其余逐字段照抄）
        let foreign = PendingTraining(
            trainingSetFilename: mine.trainingSetFilename, globalTickIndex: mine.globalTickIndex,
            upperPeriod: mine.upperPeriod, lowerPeriod: mine.lowerPeriod,
            positionData: mine.positionData, cashBalance: mine.cashBalance,
            feeSnapshot: mine.feeSnapshot, tradeOperations: mine.tradeOperations,
            lossy: mine.lossy, startedAt: mine.startedAt,
            accumulatedCapital: mine.accumulatedCapital, drawdown: mine.drawdown,
            sessionKey: mine.sessionKey + "-别的会话",
            drawingDefaultStyle: mine.drawingDefaultStyle)
        try pending.savePending(foreign)

        // 它能读出来（非 nil），但**不是本局的** ⇒ 不得据此认为「退出是安全的」
        #expect(try pending.loadPending() != nil, "前置：磁盘上确实有一条能读出来的记录")
        #expect(!coord.hasDurablePendingCheckpoint(for: engine),
                "⛔ 只证明『那行能读出来』不够 —— 必须证明它属于本局")
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

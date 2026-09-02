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

        #expect(outcome == .cannotPreserve(reason: .none),
                "既没存成、磁盘上也没有旧存档 ⇒ 必须报告『保不住』**且原因是「没有存档」**")
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
        #expect(coord.pendingCheckpointStatus(for: engine) == .usable, "前置：自己的存档当然算数")

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
        #expect(coord.pendingCheckpointStatus(for: engine) == .none,
                "⛔ 只证明『那行能读出来』不够 —— 别的会话的记录必须归入『没有存档』")
    }

    @Test("⭐训练组文件已被缓存淘汰：存档行还在也**不算退得安全**（codex R4-high）")
    func evictedTrainingSetIsNotDurable() async throws {
        let (coord, _, cache, pending) = PIFixtures.makeProvenanceCoordinator(files: ["a.sqlite"], corrupt: [])
        let engine = try await coord.startNewNormalSession()
        try await coord.saveProgress(engine: engine)
        #expect(coord.pendingCheckpointStatus(for: engine) == .usable, "前置：文件还在时当然算数")

        // 模拟后台下载把它挤掉（缓存 LRU 淘汰**不保护在用文件**）。
        // ⚠️ 关键状态：此刻 reader **仍开着**，所以这一局其实还能继续玩 ——
        //    而「安全退出」会关掉它。若判据此时仍返回 true，我们就是**亲手**把一个
        //    还能用的会话变成了打不开的存档。
        let saved = try #require(try pending.loadPending())
        let f = try #require(try cache.listAvailable().first { $0.filename == saved.trainingSetFilename })
        try cache.delete(f)

        // ⚠️ 必须是 `.trainingSetMissing` 而不是笼统的「保不住」——两种成因要给用户完全不同的说法与建议
        #expect(coord.pendingCheckpointStatus(for: engine) == .trainingSetMissing,
                "⛔ 文件没了 ⇒ 续不回来 ⇒ 既不能关掉还开着的 reader，也不能说成『本局没存过档』")
    }

    @Test("⛔ 非正常局必须被显式挡住：复盘会谎称已落盘、回放会永远退不出去（Opus 对抗评审）")
    func rejectsNonNormalModes() async throws {
        // 复盘：saveProgress 因 shouldPersistProgress()==false 直接早返、**一个字节都没写**，
        //       若照旧返回 .savedCurrentState 就是谎称「当前进度已落盘」。
        // 回放：saveProgress 若抛错 → pendingCheckpointStatus 因 mode 守卫恒返 .none
        //       → 恒 .cannotPreserve ⇒ **会话永远结束不了**，调用方陷在「退不出去」的死循环。
        // ⇒ 与其让它给出与事实相反的结论，不如显式报「不适用」。
        let (coord, _, _, _) = PIFixtures.makeCoordinator()
        for mode in [TrainingMode.review, .replay] {
            let engine = TrainingEngine.preview(mode: mode)
            let lifecycle = TrainingSessionLifecycle(engine: engine, coordinator: coord)
            #expect(await lifecycle.exitPreservingProgress() == .notApplicable,
                    "\(mode) 不是本方法的适用场景，必须显式报『不适用』")
        }
    }

    @Test("⭐⭐落盘**成功**但文件已被淘汰：同样不许退（codex R5-high —— 检查不能只放在失败那条路上）")
    func successfulSaveStillChecksTrainingSet() async throws {
        let (coord, _, cache, pending) = PIFixtures.makeProvenanceCoordinator(files: ["a.sqlite"], corrupt: [])
        let engine = try await coord.startNewNormalSession()
        try await coord.saveProgress(engine: engine)
        let saved = try #require(try pending.loadPending())

        // 文件被淘汰。⚠️ 注意 saveProgress **仍会成功** —— 它只写 pending 那一行，根本不碰缓存。
        let f = try #require(try cache.listAvailable().first { $0.filename == saved.trainingSetFilename })
        try cache.delete(f)

        let lifecycle = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        let outcome = await lifecycle.exitPreservingProgress()

        #expect(outcome == .cannotPreserve(reason: .trainingSetMissing),
                "⛔ 落盘成功≠退得安全：文件没了，那条存档续不回来")
        #expect(coord.activeEngine === engine,
                "⛔ 会话必须留着 —— 关掉 reader 就等于毁掉最后一个能打开这局的句柄")
    }

    @Test("存档**读不出来**（数据库损坏 / IO 错误）必须与「压根没有存档」区分开（codex R5-medium）")
    func unreadableCheckpointIsNotReportedAsAbsent() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        try await coord.saveProgress(engine: engine)      // 确实存过档

        pending.failNextLoadPending = .persistence(.dbCorrupted)   // 读的时候坏了
        #expect(coord.pendingCheckpointStatus(for: engine) == .unreadable,
                "⛔ 读失败 ≠ 没有存档 —— 报成『没有』会让用户去做无效的补救（清存储），还可能让他放弃可恢复的数据")
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

// MARK: - codex R6-high：「放弃未完成」关掉后回哪个弹窗

/// 背景（我在 R2 自己引入的回归）：`discardFailed` 原本是个 Bool，两个弹窗的「放弃」失败都置它，
/// 而它的「知道了」**无条件**把用户送回「结算入账失败」弹窗。可那个弹窗的「重试」直接调
/// `finalizeForSettlement()` —— 不过 `didFinalize` / `forceCloseManually()` 任何一道终局门。
/// ⇒ 从**训练中途返回**那条路进来的用户，一局没打完（可能还持仓）就被入账进历史记录。
///
/// 根因不是路由写错，是那个 Bool **表达不出来源**。故把来源做成类型，让「丢掉来源」不可表达。
@Suite("放弃失败后的回弹目标（codex R6-high）")
struct DiscardFailureOriginTests {

    @Test("从结算失败弹窗发起的放弃失败 → 回结算失败弹窗")
    func settlementOriginRestoresSettlementAlert() {
        #expect(DiscardFailureOrigin.settlementFailure.alertToRestore == .settlementFailure)
    }

    @Test("⭐⭐从**返回保存失败**弹窗发起的放弃失败 → 回它自己，⛔ 绝不能落到结算弹窗")
    func saveProgressOriginMustNotRestoreSettlementAlert() {
        let restored = DiscardFailureOrigin.saveProgressFailure.alertToRestore
        #expect(restored == .saveProgressFailure)
        // 显式钉死这条路：落到结算弹窗 = 把「重试入账」按钮递给一局还没打完的用户。
        #expect(restored != .settlementFailure,
                "⛔ 这一局还没结束，结算弹窗的「重试」会直接 finalizeForSettlement() 把它入账")
    }

    @Test("两个来源不得映射到同一个弹窗（否则来源信息等于没用）")
    func distinctOriginsRestoreDistinctAlerts() {
        #expect(DiscardFailureOrigin.settlementFailure.alertToRestore
                != DiscardFailureOrigin.saveProgressFailure.alertToRestore)
    }
}

// Kline Trainer Swift Contracts — U2 会话生命周期接线（Wave 2 顺位 9）
// Spec: docs/superpowers/specs/2026-06-02-wave2-outline-design.md §四 L124（U2 接线 E6
//       saveProgress/finalize/endSession，5 路径矩阵）+ kline_trainer_plan_v1.5.md §6.2.1/§6.2.5。
//
// 平台无关纯接线层（host 全测）：把 U2 的 UI 事件串接到 frozen E6 TrainingSessionCoordinator（PR #86）。
// 决议（D2/D3/D4/D5/D12）：
// - D2 不呈现 SettlementView（顺位 11 路由+repo owner 负责）；finalizeForSettlement 仅返 recordId? 上交。
// - D3 back = saveProgress（非 Normal no-op）+ endSession；统一调用，review/replay 走非保存分支。
// - D4 isAtEnd = tick 到 maxTick；D5 shouldAutoFinalize 把模式门+一次性门下放 host 测纯函数。

import Foundation

@MainActor
public struct TrainingSessionLifecycle {
    public let engine: TrainingEngine
    public let coordinator: TrainingSessionCoordinator

    public init(engine: TrainingEngine, coordinator: TrainingSessionCoordinator) {
        self.engine = engine
        self.coordinator = coordinator
    }

    /// RFC-B D5：当前局的 record（review/replay 非 nil；normal/resume 为 nil → 盲测占位）。只读。
    public var activeRecord: TrainingRecord? { coordinator.activeRecord }

    /// 局是否已到末态（globalTickIndex 抵 maxTick）。调用方据 `engine.flow.mode` 决定是否触发结算（D4）。
    public var isAtEnd: Bool {
        engine.tick.globalTickIndex >= engine.tick.maxTick
    }

    /// 是否应触发自动结算（D5）：到末态 + 该模式应弹结算窗 + 未结算过（一次性门，防 onChange 末态多次触发）。
    /// 用权威能力谓词 `flow.shouldShowSettlement()`（Normal=true / Review=false / Replay=true，capability
    /// matrix L842）而非硬编码 `mode != .review`，与 `buyEnabled` 用 `canBuySell()` 同范式——单一真值源、
    /// 抗矩阵/新模式漂移（code-review Task1 建议）。Review 固定末态 isAtEnd 恒真，靠此谓词为 false 抑制误结算。
    /// **Replay**：谓词 true → shouldAutoFinalize 同走真分支，但 `finalizeForSettlement` 因 `shouldSaveRecord()==false`
    /// 返 nil（不入账）；结算窗由顺位 11 据 engine 末态呈现（D13 / residual U2-R4）。纯函数 host 全测。
    public func shouldAutoFinalize(didFinalize: Bool) -> Bool {
        isAtEnd && engine.flow.shouldShowSettlement() && !didFinalize
    }

    /// 返回按钮（plan v1.5 §6.2.1 L920）：保存进度（Normal 真存；review/replay 在 coordinator 内 no-op）
    /// 然后结束会话（D3）。
    public func back() async throws {
        try await coordinator.saveProgress(engine: engine)
        await coordinator.endSession()
    }

    /// Q13（codex R1-high）：**永不弃局**的安全退出。
    /// 先尽力把当前进度落盘，**再确认磁盘上确实留下了一份能用的存档**，两者都过了才结束会话。
    ///
    /// ⚠️ 本段曾写着「落盘失败也照样结束会话」—— 那是 R2-high 之前的行为，**现已相反**
    ///    （Kimi R1-low：陈旧头注会教后人把洞改回来）。今天的规则是：落盘成功与否都要再查一次，
    ///    查不到能用的存档就**不退**（`.cannotPreserve`，会话原样保留）。
    ///
    /// ⚠️ **它存在的理由**：`back()` 必须先 `saveProgress` **成功**才 `endSession`；而「结算入账失败」
    ///    弹窗最现实的触发原因**正是写盘失败**（磁盘满 / DB 损坏 / IO 错误）—— 让唯一的安全出口
    ///    依赖那条**正在坏掉的路**，等于没有出口：用户会被弹回「保存进度失败」（只有再写一次
    ///    或破坏性弃局），最终仍被推向数据丢失。
    /// ⛔ 本方法**绝不调用 `discardSession`** —— 它不是弃局，是「带着已有存档离开」。
    /// - Returns: 见 `SafeExitOutcome`（四个 case：两种「退成了」+ 保不住 + 非正常局）。
    @discardableResult
    public func exitPreservingProgress() async -> SafeExitOutcome {
        // ⛔ **显式挡住非正常局**（Opus 对抗评审）：把「今天只有一个调用点」这个前提写进代码，
        //    而不是只写在另一份文件的注释里 —— 这是个 public 方法，看起来像通用出口。
        //    · 复盘：`saveProgress` 因 `shouldPersistProgress() == false` 直接早返、**一个字节都没写**，
        //      若不挡住就会返回 `.savedCurrentState`（字面意思是「当前进度已落盘」）—— 与事实相反；
        //    · 回放：`saveProgress` 若抛错，`pendingCheckpointStatus` 因其自身的 mode 守卫恒返 `.none`
        //      ⇒ 恒 `.cannotPreserve` ⇒ **会话永远结束不了**，调用方陷在「退不出去」的死循环，
        //      哪怕 `pending_replay` 槽里其实躺着一份完好的存档。
        //    ⇒ 日后要给 replay 复用，必须先补 `pending_replay` 那一支，再放开这道守卫。
        guard engine.flow.mode == .normal else { return .notApplicable }

        var savedCurrent = true
        do { try await coordinator.saveProgress(engine: engine) } catch { savedCurrent = false }

        // ⛔⛔ **落盘成功与失败两条路都必须过这一关**（codex R5-high）。
        //    上一稿只在 `catch` 里检查 ⇒ 「落盘成功、但训练组文件已被淘汰」那条路径直接
        //    `endSession()` 走掉。而 `saveProgress` **只写 pending 那一行、根本不碰缓存** ——
        //    它成功**不代表**退得安全：关掉 reader 之后，那条存档指向一个已经不存在的文件，
        //    「继续训练」再也打不开，方法却报告 `.savedCurrentState`（一句假话）。
        //    ⚠️ 这是「同一道判据只加在两条路中的一条」——本片已经栽过一次，别再犯。
        // ⛔ 这道关本身也不能省（codex R2-high）：开新局时磁盘上本来就没有存档，
        //    若整局的自动存档又全部失败，无条件 `endSession()` 就把**整局唯一的副本**扔掉了。
        let status = coordinator.pendingCheckpointStatus(for: engine)
        guard status == .usable else {
            return .cannotPreserve(reason: status)   // ⛔ 刻意不 endSession：会话必须留着
        }
        await coordinator.endSession()
        return savedCurrent ? .savedCurrentState : .keptEarlierCheckpoint
    }

    /// 安全退出的结局（Q13 / codex R2-high）。
    /// ⚠️ 多态而非 Bool：`false` 分不清「退回旧存档」（安全）与「什么都没保住」（**绝不能退**），
    ///    而这两种的正确处置完全相反。
    /// ⚠️ 实际四个 case：`.savedCurrentState` / `.keptEarlierCheckpoint` 都表示退成了，
    ///    `.cannotPreserve` 表示**没退**，`.notApplicable` 表示这方法不该被用在这种局上。
    public enum SafeExitOutcome: Equatable, Sendable {
        /// 当前进度已落盘 —— 最好的情况。
        case savedCurrentState
        /// 当前进度没落成，但磁盘上**已有**一份更早的存档 ⇒ 退出是安全的，只是会回到那一档。
        case keptEarlierCheckpoint
        /// 落盘没成功、且磁盘上那份存档**不可用** ⇒ **未退出，会话原样保留**。
        /// 调用方必须如实告诉用户「现在退不出去」，⛔ 不得假装已经退了。
        /// ⚠️ **带上原因**：不同成因要给不同说法与不同建议（见 `CheckpointStatus`）。
        case cannotPreserve(reason: TrainingSessionCoordinator.CheckpointStatus)
        /// **本方法不适用于该模式**（今天只支持正常训练局），会话未被改动。
        /// ⚠️ 与 `cannotPreserve` 刻意分开：那个是「适用但此刻保不住」，这个是「压根不该问我」。
        case notApplicable
    }

    /// 自动结束（plan v1.5 §6.2.5）：正式结束入账，返 recordId（Normal）/ nil（review/replay 非保存分支）。
    /// 不 endSession —— 结算确认后才结束（D2）。
    public func finalizeForSettlement() async throws -> Int64? {
        try await coordinator.finalize(engine: engine)
    }

    /// 结算确认后（plan v1.5 §6.3）：结束会话（reader 关闭 + 清活跃上下文）。
    public func endAfterSettlement() async {
        await coordinator.endSession()
    }

    /// §4.7e：durable 放弃当前局（清 pending + 关 reader + 清 context）。清 pending 失败抛（caller 保留重试）。
    public func discard() async throws {
        try await coordinator.discardSession()
    }

    /// 脏状态动作后请求 autosave（immediate=交易/画线；非 immediate=tick 推进按 N 节流）。§4.6。
    public func autosave(immediate: Bool) {
        coordinator.requestAutosave(engine: engine, immediate: immediate)
    }

    /// scenePhase 后台/失活：立即 flush + 等写完成（OS 可能随后杀进程）。§4.6 item 4。
    public func flushForBackground() async {
        await coordinator.flushAutosave(engine: engine)
    }

    /// 顺位 8（RFC §4.4e/§4.5）：replay 结束的**非持久化**结算 payload。转发 frozen
    /// `coordinator.replaySettlementPayload`（只读终态 in-memory `TrainingRecord`；不写 `training_records`、
    /// 不触 `pending_training`、`finalize` 对 replay 仍返 nil）。**强平须 caller 先行**（壳层 manual
    /// `forceCloseManually` / auto maxTick 步进已强平，同 `finalizeForSettlement` 的终态前提）。
    /// 仅 replay + 活跃会话合法；否则 coordinator 抛 `.internalError`（caller 守卫）。
    /// 新需求10(A6)：async throws（镜像 coordinator.replaySettlementPayload 签名变更）。
    public func replaySettlementRecord() async throws -> TrainingRecord {
        try await coordinator.replaySettlementPayload(engine: engine)
    }

    // MARK: - review-redesign Task 7：复盘 autosave/终态 fence 转发（§6.3）
    // 显式 `engine:` 参数（非 self.engine 隐式）：镜像 plan §Task 9 UI 接线调用点
    // （`lifecycle.backReview(engine: engine)` 等，plan L1290-1292/1307/1326），与 coordinator 侧签名一致。

    /// 复盘中按需节流 autosave（画线/步进触发）。
    public func autosaveReview(engine: TrainingEngine) {
        coordinator.autosaveReview(engine: engine)
    }

    /// 复盘返回（drain → persistReviewWorkingIfChanged → endSession）。
    public func backReview(engine: TrainingEngine) async throws {
        try await coordinator.backReview(engine: engine)
    }

    /// 复盘保存结束（drain → commitReview → endSession）。
    public func endReviewSave(engine: TrainingEngine) async throws {
        try await coordinator.endReviewSave(engine: engine)
    }

    /// 复盘丢弃结束（drain → discardReviewWorking → endSession）。
    public func endReviewDiscard(engine: TrainingEngine) async throws {
        try await coordinator.endReviewDiscard(engine: engine)
    }

    /// codex whole-branch R2：稳健放弃（drain → best-effort 清 working → 恒 endSession，不因清档失败
    /// 而泄漏会话）。供失败 alert 的「放弃」按钮使用。
    public func abandonReview(engine: TrainingEngine) async {
        await coordinator.abandonReview(engine: engine)
    }

    /// 当前复盘 session 是否有净改动（转发，供 UI 判断是否有未保存改动）。
    public func reviewNetChanged() -> Bool {
        coordinator.reviewNetChanged()
    }

    /// codex whole-branch R1：scenePhase 后台/失活 flush review working 态（镜像 `flushForBackground`，
    /// 但仅对 review 模式生效，不 invalidate session token）。
    public func flushReviewForBackground(engine: TrainingEngine) async {
        await coordinator.flushReviewForBackground(engine: engine)
    }
}

// MARK: - 「放弃本局」失败后回弹到哪个弹窗（codex R6-high）

/// 谁发起了这次「放弃本局」。
///
/// ⛔ **不得退回成 Bool**：两个弹窗（「结算入账失败」与「保存进度失败」）都有「放弃」按钮，
///    都可能失败。丢掉来源就只能猜一个回，而猜错的代价不对称 ——
///    把「训练中途返回」的用户送进结算弹窗，他一点「重试」就会走 `finalizeForSettlement()`，
///    那条路**不过** `didFinalize` / `forceCloseManually()` 任何一道终局门，
///    于是一局没打完（甚至还持仓）的训练被当作完成局写进历史记录、pending 一并清掉。
public enum DiscardFailureOrigin: Equatable, Sendable {
    /// 本局已走到终局，结算入账失败后在那个弹窗里选了「放弃本局」。
    case settlementFailure
    /// 训练**中途**点返回、保存进度失败后在那个弹窗里选了「放弃」。本局尚未结束。
    case saveProgressFailure

    /// 关掉「放弃未完成」提示后必须回到的弹窗。
    /// 之所以不能「什么都不弹」：用户会回到训练页、屏幕上什么都没有，
    /// 以为刚才那一下没反应，比不给出口更糟。
    ///
    /// ⛔ **返回类型必须与本枚举不同**（Kimi R3-medium）：上一稿返回 `self`，于是这个映射
    ///    只能写成恒等式、**编译器保证它不可能写反** ⇒ 针对它的三条行为测试是恒真的。
    ///    实测：把两处来源赋值与两支回弹**同时互换**（R6-high 的洞原样回来），26 条测试全绿。
    ///    换成独立类型后，这个映射可以写反，那三条测试才真正在测东西。
    public var alertToRestore: RecoveryAlert {
        switch self {
        case .settlementFailure: return .settlementFailure
        case .saveProgressFailure: return .saveProgressFailure
        }
    }
}

/// 关掉「放弃未完成」之后要弹回来的那个弹窗。
/// ⚠️ 与 `DiscardFailureOrigin` 是**两个**类型，尽管 case 同名 —— 一个说「谁发起的」，
///    一个说「该弹哪个」。合成一个就等于把这条映射变成编译期恒等式（见上）。
public enum RecoveryAlert: Equatable, Sendable {
    /// 「结算入账失败」—— ⚠️ 它的「重试」直接 `finalizeForSettlement()`，只有终局的会话该被弹回这里。
    case settlementFailure
    /// 「保存进度失败」—— 训练中途返回那条路，本局尚未结束。
    case saveProgressFailure
}

// Kline Trainer Swift Contracts — E6 TrainingSessionCoordinator (Wave 0 契约 + preview)
// Spec: kline_trainer_modules_v1.4.md §E6 (line 1623-1700)
// Wave 0 范围：class + init + 7 方法签名（fatalError 体）+ static func preview()
// TrainingEnginePreviewFactory（TrainingEngine.preview(mode:)）：spec line 2111，
//   依赖 Wave 2 E5 完整 init + E4 flows，dep-graph 阻塞，本 PR 不交付

import Foundation

#if canImport(Observation)
import Observation
#endif

/// RFC §4.6：周期 autosave cadence floor（命名契约常量，modules:1747）。
/// N=1 = 每 state-dirtying 动作即存（coalesced）；不变量：未落盘进度丢失 ≤ N tick 等价脏窗。
public let AUTOSAVE_TICK_INTERVAL = 1
/// cadence 上限（实测写延迟超帧预算时可上调 N ≤ 此值；本 PR 不上调）。
public let AUTOSAVE_MAX_INTERVAL = 5

@MainActor
@Observable
public final class TrainingSessionCoordinator {
    private let dbFactory: TrainingSetDBFactory       // P3a
    private let recordRepo: RecordRepository          // P4
    private let pendingRepo: PendingTrainingRepository // P4
    private let pendingReplayRepo: PendingReplayRepository  // 新需求10：replay 续局单槽
    private let reviewArchiveRepo: ReviewArchiveRepository  // review-redesign：复盘存档单记录
    private let finalization: SessionFinalizationPort  // Wave 3 顺位 10a：单事务终结 port（RFC §4.7b）
    private let settingsDAO: SettingsDAO              // P4
    private let cache: CacheManager                   // P5
    private let settings: SettingsStore               // P6

    public private(set) var activeEngine: TrainingEngine?
    public private(set) var activeReader: (any TrainingSetReader)?
    /// RFC-B D5：review/replay 留存「已 loadRecordBundle 到内存」的 record（零新 I/O），供顶栏标的名。
    /// normal/resume 路径置 nil（盲测占位）。
    public private(set) var activeRecord: TrainingRecord?

    // MARK: - E6b 会话持久化上下文（saveProgress/finalize 需文件名+起始时间，engine 不携带）

    /// 当前 session 的训练组文件（4 open 方法成功时记录；endSession 清空）。
    @ObservationIgnored private var activeFile: TrainingSetFile?
    /// 当前 session 的起始时间（fresh Normal=now()；resume=保留 pending.startedAt；review/replay=nil）。
    @ObservationIgnored private var activeStartedAt: Int64?
    /// 可注入时钟（public init 已冻结，不能加参数）。默认系统时钟；@testable 测试可覆盖（D5）。
    @ObservationIgnored var now: () -> Int64 = { Int64(Date().timeIntervalSince1970) }

    /// 当前 Normal session 的 durable session key（RFC §4.7c）：fresh=makeSessionKey()；
    /// resume=pending.sessionKey；review/replay=nil；endSession 清空。finalize 幂等锚。
    @ObservationIgnored private(set) var activeSessionKey: String?
    /// 可注入 key 生成器（mirror `now` 范式，D5）。默认 UUID；@testable 测试可覆盖。
    @ObservationIgnored var makeSessionKey: () -> String = { UUID().uuidString }

    // 新需求10：当前 replay 会话创建时的状态基线（tick/交易数/画线数/上下周期）。
    // 含周期（codex plan-R14-F1）：单指竖滑切周期组合改 upper/lowerPanel.period 而不动 tick/ops/drawings，
    // 须纳入 clean-skip 比较，否则切周期后 Back/flush 被当 clean 跳过 → 丢 PendingReplay 序列化的 upper/lowerPeriod。
    @ObservationIgnored private var replayBaseline: (tick: Int, ops: Int, drawings: Int, upper: Period, lower: Period)?
    // 新需求10（codex plan-R6-F1）：本 replay 会话是否已成功写过槽（拥有槽）。
    // fresh=false、任一次成功 saveReplay 后=true。
    // clean-skip **仅在 !replayHasPersisted 时**生效——首写后永不跳过，否则"加画线→写→删画线(count 回基线)
    // →跳过"会残留已删画线。
    @ObservationIgnored private var replayHasPersisted = false

    // MARK: - review-redesign RFC：复盘 session 态（committed 基线 + 净改动判定，Task 5）

    /// 当前复盘 session 绑定的 record id（`review()`/`resumePendingReview()` 设置，Task 6）；nil=无复盘 session。
    @ObservationIgnored private var reviewRecordId: Int64?
    /// 复盘 committed 基线：进入时 = saved ?? []；`commitReview` 提交后前移 = 刚提交的工作画线集。
    /// 净改动判定 **恒对比 committed 基线**（非 resume 时加载的 working），见 `ReviewNetChange`。
    @ObservationIgnored private var reviewCommittedBaseline: [DrawingObject] = []
    /// P1a codex whole-branch High fix：committed 基线的 hiddenIds 侧（与上面 `reviewCommittedBaseline`
    /// 画线侧同源同步——恒来自 saved 列，见 `loadSavedLossy`）。净改动判定必须把它一并纳入比较，否则
    /// 「working 画线集==saved 画线集但 hiddenIds 不同」会被误判为「无改动」→ `clearWorking` 抹掉这份
    /// working 行，永久丢失其携带的隐藏态（forward-compat 数据丢失路径）。
    @ObservationIgnored private var reviewCommittedHiddenIds: [DrawingID] = []
    /// Task 6：saved 存档解码损坏、已 `clearSaved` 恢复为空基线时置位（UI 读后清、经 toast 呈现
    /// 「复盘存档损坏已清除，可重新复盘保存」）。
    public private(set) var pendingReviewCorruptToast = false
    /// UI（TrainingView.onAppear 或 AppRouter）消费后清位。
    public func clearPendingReviewCorruptToast() { pendingReviewCorruptToast = false }

    // MARK: - review-redesign Task 7：复盘 autosave 单写者 fence（token/revision/task，独立于下方 replay/normal autosave）

    /// 每次进入复盘（`review()`/`resumePendingReview()` 内部 `buildReviewEngine` 处 mint）新铸一枚；
    /// nil = 无复盘 session。终态方法（`backReview`/`endReviewSave`/`endReviewDiscard`）写前置 nil——
    /// 陈旧排队 autosave 捕获的旧 token 与之比对不等 → 早退丢弃（in-memory 栅栏，非 DB 列）。
    @ObservationIgnored private var reviewSessionToken: UUID?
    /// 单调递增请求计数：`autosaveReview` 每次调用 +1；排队 Task 用以判定"调度期间是否又有新请求"
    /// （同 token 内的陈旧合并，非跨 session 判据——跨 session 判据是上面的 token）。
    @ObservationIgnored private var reviewRevision = 0
    /// 在飞排队的节流 autosave Task（供终态 drain）。
    @ObservationIgnored private var reviewAutosaveTask: Task<Void, Never>?

    // MARK: - Wave 3 顺位 10b：周期 autosave 状态机（RFC §4.6）+ 终态 fence（§4.7d）

    @ObservationIgnored private var autosaveTask: Task<Void, Never>?     // 在飞写句柄（fence drain）
    @ObservationIgnored private var autosaveDirty = false                // 写中又脏 → 写完再存一次
    @ObservationIgnored private var terminating = false                  // §4.7d 栅栏
    @ObservationIgnored private var ticksSinceAutosave = 0               // N-tick cadence 计数
    /// 可注入 cadence（@testable）。clamp 到 [1, AUTOSAVE_MAX_INTERVAL]：防 0/负间隔（每 tick 永真）+ 兑现 N≤MAX 不变量。
    @ObservationIgnored var autosaveTickInterval = AUTOSAVE_TICK_INTERVAL {
        didSet { autosaveTickInterval = min(max(autosaveTickInterval, 1), AUTOSAVE_MAX_INTERVAL) }
    }
    /// §4.6 失败可见：最近一次 autosave 失败（不 teardown）。本 PR 在 coordinator 层闭合「记录 + 非阻塞 + 不拆毁」
    /// 机制；**user-facing 非阻塞指示（banner/toast）归顺位 10c 边界错误统一 Toast 层**（磁盘满可见性同类），
    /// 届时连同 §4.6 item5 一并 surface（@testable 现已读以证机制在位）。
    @ObservationIgnored public private(set) var lastAutosaveError: AppError?
    /// §B.2（PR 13a）user-facing autosave 失败信号（observable，供 TrainingView toast）。
    /// 与内部 `lastAutosaveError`（@ObservationIgnored 机制状态）解耦：本字段仅作 UI re-render 信号，
    /// 不参与 autosave coalescing/fence 状态机。置位/清零与 `lastAutosaveError` 同步（catch / endSession / reset）。
    public private(set) var autosaveBannerError: AppError?
    /// codex-13a-F1：autosave 失败的**单调事件计数**（observable）。每次失败 +1，使「重复同一错误」
    /// 也产生可观察变化 → TrainingView `.onChange` 重新弹 toast。**理由**：仅观察 `autosaveBannerError`
    /// 时，磁盘满每 tick 失败但错误值不变 → onChange 不再 fire → 首条 toast 过期后用户对持续的「进度未
    /// 落盘」完全无感知（数据持久性不可见的安全隐患，codex high）。本计数是该「可见性」契约的触发锚。
    /// 仅失败递增；成功不动；endSession/reset 归零。
    public private(set) var autosaveErrorGeneration: Int = 0

    /// §B.2 + codex whole-branch R4 finding 1：autosave 失败的共享记录器——normal `requestAutosave` 与
    /// review `autosaveReview`/`flushReviewForBackground` 均汇聚于此，确保两条路径产生同一套可观察信号
    /// （`autosaveBannerError` + 单调 `autosaveErrorGeneration`），复用既有机制而非新增并行信号。
    private func recordAutosaveError(_ error: Error) {
        let appError = (error as? AppError)
            ?? .internalError(module: "E6b", detail: "autosave: \(error)")
        lastAutosaveError = appError
        autosaveBannerError = appError             // §B.2：失败置 UI 信号（observable → toast）
        autosaveErrorGeneration += 1               // codex-13a-F1：每次失败递增 → 重复同错也触发 onChange（持久故障保持可见）
    }

    /// 请求 autosave（脏动作后调）。immediate=交易/画线/background flush（绕 N 节流）；
    /// 非 immediate=tick 推进（按 autosaveTickInterval 节流）。terminating/非 Normal → no-op（§4.7d/§4.6）。
    public func requestAutosave(engine: TrainingEngine, immediate: Bool) {
        guard !terminating, engine.flow.shouldPersistProgress() else { return }
        if !immediate {
            ticksSinceAutosave += 1
            guard ticksSinceAutosave >= autosaveTickInterval else { return }
        }
        ticksSinceAutosave = 0
        autosaveDirty = true
        guard autosaveTask == nil else { return }            // 已排程 → 合并
        // 不变量（coalescing/fence/flush 正确性所依）：`saveProgress`/`savePending` 是 @MainActor 上
        // 同步 throws（GRDB dbQueue.write 阻塞，非真 async）—— 故下方 while 循环 + `autosaveTask = nil`
        // 在单次 @MainActor 续跑内原子完成，无真挂起点供 endSession/finalize 交错抢写。改 repo 为真 async
        // 须同步重审本机制（协议签名为 sync throws，编译期锁此不变量）。
        autosaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.autosaveDirty && !self.terminating {
                self.autosaveDirty = false
                do {
                    try await self.saveProgress(engine: engine)
                    self.lastAutosaveError = nil
                    self.autosaveBannerError = nil                  // §B.2：成功清 UI 信号
                } catch {
                    self.recordAutosaveError(error)
                }
            }
            self.autosaveTask = nil
        }
    }

    /// background/inactive 立即 flush（绕 N）+ 等写完成（OS 可能随后杀进程）。§4.6 item 4。
    public func flushAutosave(engine: TrainingEngine) async {
        requestAutosave(engine: engine, immediate: true)
        await autosaveTask?.value
    }

    #if DEBUG
    /// 测试钩子：等在飞 autosave 写完成（生产无 await 点，测试需确定性排空）。
    func drainAutosaveForTesting() async { await autosaveTask?.value }
    /// 测试钩子：强置 activeRecord=nil，供 fail-closed 守卫测试制造缺上下文（镜像 drainAutosaveForTesting 范式）。
    func setActiveRecordNilForTesting() { activeRecord = nil }
    /// review-redesign Task 5 测试专用：注入复盘 session 态（`reviewRecordId`/`reviewCommittedBaseline`）。
    /// 生产路径由 Task 6 的 `review()`/`resumePendingReview()` 设置；本 task 尚无产出这些字段的公开方法，
    /// 故测试直接注入（镜像 `setActiveRecordNilForTesting` 范式）。
    func setReviewSessionForTesting(recordId: Int64?, committedBaseline: [DrawingObject],
                                     committedHiddenIds: [DrawingID] = []) {
        reviewRecordId = recordId
        reviewCommittedBaseline = committedBaseline
        reviewCommittedHiddenIds = committedHiddenIds
    }
    /// review-redesign Task 7 测试专用：等在飞 review autosave Task 完成（镜像 `drainAutosaveForTesting`）。
    func drainReviewAutosaveForTesting() async { await reviewAutosaveTask?.value }
    /// codex whole-branch R6 回归测试专用：读当前 `reviewRevision`（供断言陈旧 `autosaveReview` 调用
    /// 是否误递增计数，镜像其它 `xxxForTesting` 范式）。
    var reviewRevisionForTesting: Int { reviewRevision }
    /// codex whole-branch R6 回归测试专用：`reviewAutosaveTask` 是否已占用（供断言陈旧 `autosaveReview`
    /// 调用是否误占排队槽位）。
    var hasQueuedReviewAutosaveForTesting: Bool { reviewAutosaveTask != nil }
    #endif

    /// §4.7d 终态栅栏：置 terminating（拒新 autosave）+ 排空在飞写（排空时见 terminating 即退出不落盘）。
    /// 单线程 @MainActor 保证 finalize/discard 与 autosave Task 不并发（await 时 Task 运行并见 terminating）。
    private func fenceAndDrainAutosaves() async {
        terminating = true
        await autosaveTask?.value
    }

    public init(dbFactory: TrainingSetDBFactory,
                recordRepo: RecordRepository,
                pendingRepo: PendingTrainingRepository,
                pendingReplayRepo: PendingReplayRepository,
                reviewArchiveRepo: ReviewArchiveRepository,
                finalization: SessionFinalizationPort,
                settingsDAO: SettingsDAO,
                cache: CacheManager,
                settings: SettingsStore) {
        self.dbFactory = dbFactory
        self.recordRepo = recordRepo
        self.pendingRepo = pendingRepo
        self.pendingReplayRepo = pendingReplayRepo
        self.reviewArchiveRepo = reviewArchiveRepo
        self.finalization = finalization
        self.settingsDAO = settingsDAO
        self.cache = cache
        self.settings = settings
        self.activeEngine = nil
        self.activeReader = nil
    }

    /// 开始新 Normal 训练（spec L1664）：fail-closed 取费 → 随机选训练组 → 打开 reader →
    /// 累计本金构造 NormalFlow 引擎。loadError 时早抛、零副作用（D2/D9）。
    /// **前置（D10）**：caller 须先 `endSession()` 关闭上一 session 的 reader，否则上一
    /// `activeReader` 被覆盖泄漏（E6a 不替前一 session 收尾——E6b/caller 契约）。
    public func startNewNormalSession() async throws -> TrainingEngine {
        let fees = try settings.snapshotFeesIfReady()        // D2 fail-closed：loadError → throw（reader 未开）
        let start = try startingCapital()                    // app.sqlite source；reader 未开，throw 无副作用
        // §4.7f provenance：选训练组 → 打开；损坏（source=训练组只读 DB）→ 删 + 重试另一文件。
        var attempts = cache.listAvailable().count + 1       // 有界（即便 delete 静默失败仍终止）
        var opened: (reader: any TrainingSetReader, file: TrainingSetFile)?
        while attempts > 0, opened == nil {
            attempts -= 1
            guard let file = cache.pickRandom() else {
                throw AppError.trainingSet(.fileNotFound)    // 缓存耗尽 → caller 重下
            }
            do {
                opened = (try openReader(for: file), file)
            } catch where isCorruptTrainingSet(error) {
                try? cache.delete(file)   // best-effort 删损坏训练组（可弃）：.fileNotFound=已删 / .diskFull=留待下次；均不阻重试
            }
        }
        guard let (reader, file) = opened else {
            throw AppError.trainingSet(.fileNotFound)
        }
        do {
            let allCandles = try reader.loadAllCandles()
            let meta = try reader.loadMeta()                  // F2：起始点 tick 派生
            let mt = try maxTick(from: allCandles)            // D3
            let startTick = TrainingEngine.startTick(forStartDatetime: meta.startDatetime, in: allCandles)
            let engine = try TrainingEngine.make(
                .normal(fees: fees, maxTick: mt),
                allCandles: allCandles,
                initialTick: startTick,
                initialCapital: start, initialCashBalance: start)
            activeReader = reader
            activeEngine = engine
            activeFile = file
            cache.touch(file)                       // §A touch-on-use（E6a-R3）：仅在**完整读取 + 引擎构造成功**后刷 LRU mtime（codex-13a-F2：不在 openReader 后即 touch，防候选 candle 损坏文件假性续命）
            activeStartedAt = now()                 // D4：fresh Normal 局起始时间
            activeSessionKey = makeSessionKey()     // RFC §4.7c：fresh Normal 生成新 session key
            activeRecord = nil                      // RFC-B D5：盲测训练隐藏标的名
            resetAutosaveState()                     // 新 session：清栅栏/脏/cadence/错误（D3）
            return engine
        } catch {
            reader.close()                                   // D9：失败关闭已开 reader，不留半态
            // D11 M0.4：单表达式可静态证明类型（禁裸变量 `throw error`，m04 gate 规则1）
            throw (error as? AppError) ?? .internalError(module: "E6a", detail: String(describing: error))
        }
    }

    /// 继续中断训练（spec L1667）：loadPending → 按 filename 打开 reader → 从 pending 重建引擎（D7）。
    /// 无 pending 返回 nil（**仅**此情形返 nil；其它失败均 throw 可恢复 AppError）。
    public func resumePending() async throws -> TrainingEngine? {
        guard let pending = try pendingRepo.loadPending() else { return nil }
        // Note: loadPending() is app.sqlite source — its .dbCorrupted propagates ABOVE this catch (fail-closed).
        let file = try cachedFile(filename: pending.trainingSetFilename)
        let reader: any TrainingSetReader
        do {
            reader = try openReader(for: file)
        } catch where isCorruptTrainingSet(error) {
            try? cache.delete(file)                          // 同上（best-effort 可弃）：训练组损坏，孤儿 pending 不可恢复
            try pendingRepo.clearPending()                   // durable 清（app.sqlite 写，非删）
            return nil                                       // 首页降级到新局
        }
        do {
            let allCandles = try reader.loadAllCandles()
            let mt = try maxTick(from: allCandles)
            let position = try decodePosition(pending.positionData)
            let engine = try TrainingEngine.make(
                .normal(fees: pending.feeSnapshot, maxTick: mt),
                allCandles: allCandles,
                initialTick: pending.globalTickIndex,
                initialCapital: pending.accumulatedCapital,
                initialCashBalance: pending.cashBalance,
                initialPosition: position,
                initialMarkers: markers(from: pending.tradeOperations),
                initialDrawings: pending.drawings,
                initialDrawingsLossy: pending.lossy,   // P1a Task 12（Z1）：携带完整有损集（保未识别条穿过后续 save）
                initialTradeOperations: pending.tradeOperations,
                initialDrawdown: pending.drawdown,
                initialUpperPeriod: pending.upperPeriod,
                initialLowerPeriod: pending.lowerPeriod)
            activeReader = reader
            activeEngine = engine
            activeFile = file
            cache.touch(file)                        // §A touch-on-use：完整读取+引擎构造成功后刷 LRU mtime（codex-13a-F2）
            activeStartedAt = pending.startedAt      // D4：resume 保留原局起始时间
            activeSessionKey = pending.sessionKey    // RFC §4.7c：resume 恢复已存 session key
            activeRecord = nil                       // RFC-B D5：盲测训练隐藏标的名
            resetAutosaveState()                     // 新 session：清栅栏/脏/cadence/错误（D3）
            return engine
        } catch {
            reader.close()
            throw (error as? AppError) ?? .internalError(module: "E6a", detail: String(describing: error))
        }
    }

    /// Review 模式（spec L1670）：record bundle → 打开 reader → 构造只读 ReviewFlow 引擎，
    /// 还原全部标记/绘线、固定末态（D5）。费率/起始年月均来自 record，不读当前 settings。
    /// **D5 不变量**：review 仅供只读展示；`initialCashBalance = totalCapital + profit`（末态全现金，
    /// 强平后）使引擎实时 `returnRate == record.returnRate`（flat-ending-cash 假设下自洽）；**不**改写
    /// record 真值（settlement 若直读 record 则此重建只影响训练页状态栏显示，安全）。
    /// **前置（D10）**：caller 须先 `endSession()`（同 startNewNormalSession）。
    /// review-redesign Task 6：committed 基线 = saved（独立解码，坏 → 恢复为空 + toast），
    /// `engine.reviewDrawings` 与 committed 基线均种自该 baseline（fresh review：working==committed）。
    public func review(recordId: Int64) async throws -> TrainingEngine {
        let baseline = try loadCommittedBaselineRecovering(recordId: recordId)
        // P1a Task 12（Z1 Critical fix，codex whole-branch）：上一行 `loadCommittedBaselineRecovering` 走
        // `loadSaved` 只返回已知投影（saved 列的 unknownRaw/hiddenIds 未暴露）——若拿它重新包装成"全新" lossy
        // 种给引擎，fresh review 无编辑直接 commit 会用这份已知投影覆盖 saved 列，永久抹掉未识别（未来版本）
        // 画线条与非空 hiddenIds（数据丢失，零用户编辑）。改用 `loadSavedLossy` 单独再读一次 saved 列的
        // 保真版本（含 unknownRaw + hiddenIds）种给引擎；上一行已处理 saved 损坏恢复（clearSaved 若坏），
        // 此处读到的是已清理后的状态，坏 → 传播（不吞，corruption 已在上面收口，这里理应不会再坏）。
        let savedLossy = try reviewArchiveRepo.loadSavedLossy(recordId: recordId)
        return try await buildReviewEngine(recordId: recordId, startTickOverride: nil,
                                           reviewLossy: try savedLossy?.lossy ?? LossyDrawingArray(drawings: baseline),
                                           reviewHiddenIds: savedLossy?.hiddenIds ?? [],
                                           committedBaseline: baseline,
                                           committedHiddenIds: savedLossy?.hiddenIds ?? [])
    }

    /// review-redesign Task 6：resume-first 续复盘。命中 `.inProgress` → 从 `working.stepTick` 起、
    /// `engine.reviewDrawings` = working 画线集，committed 基线仍 = saved（独立解码，非 working）。
    /// **working 独立解码（codex plan-R1-high）**：working 坏 → 仅清 working、回退从头（不碰 saved）。
    /// 未命中 `.inProgress` / 竞态清空 → nil（router 回退 fresh `review()`）。
    public func resumePendingReview(recordId: Int64) async throws -> TrainingEngine? {
        // codex whole-branch R2（high）：不得用 `try?` 吞掉瞬态读错误——那会把它收敛为 `.none`，
        // 让 router 回退 fresh `review()`，随后放弃可能清掉仍有效的 `working_*` 行（数据丢失）。
        // 瞬态错误须传播（async throws）；只有干净返回的非 `.inProgress` marker 才是合法「无需 resume」。
        guard try reviewArchiveRepo.reviewMarker(recordId: recordId) == .inProgress else { return nil }
        let working: ReviewWorking?
        do {
            working = try reviewArchiveRepo.loadWorking(recordId: recordId)
        } catch let e as AppError where e.isDBCorrupted {
            try reviewArchiveRepo.clearWorking(recordId: recordId)
            return nil
        }
        guard let w = working else { return nil }             // 竞态：刚被清 → nil（router 从头）
        // codex whole-branch R5（high）：`w.stepTick` 校验须先于 `buildReviewEngine`——否则越界 tick（schema
        // 漂移/损坏；DB CHECK 只强制非空配对，不校验 tick 边界）会让 `TrainingEngine.make` 因
        // `flow.allowedTickRange` 不含该 tick 而 trap-guard throw，但坏 `working_*` 行仍 `.inProgress`，
        // 之后每次 tap 都重试同一失败 resume（永久 brick）。此处视越界为 WORKING 语义损坏（区别于
        // record-ops 入口终局校验的 `.dbCorrupted`）：clearWorking + nil（router 回退 fresh `review()`，
        // 不碰 saved/record）。顺带取一次 record bundle 供下方 `buildReviewEngine` 复用（避免重复加载）。
        // **注**（codex whole-branch R6）：本 guard 只挡 `0...finalTick` 之外——真正的下界是训练组
        // metadata 派生的 `metaStartTick`（可 >0），只有打开 reader/loadMeta 后才知道，故那段校验
        // 移到 `buildReviewEngine` 内部（见下方 do/catch）。
        let bundle = try recordRepo.loadRecordBundle(id: recordId)
        guard (0...max(0, bundle.0.finalTick)).contains(w.stepTick) else {
            try reviewArchiveRepo.clearWorking(recordId: recordId)
            return nil
        }
        let baseline = try loadCommittedBaselineRecovering(recordId: recordId)   // saved 坏 → 仅清 saved + toast，保住有效 working
        // codex whole-branch High fix：committed 基线的 hiddenIds 侧同样恒来自 saved 列（与上面 `baseline`
        // 画线侧同源），供下方 `buildReviewEngine` 种给 `reviewCommittedHiddenIds`——净改动判定须能识别
        // 「working 与 saved 画线集相同、仅 hiddenIds 不同」，否则会被误判为无改动而 `clearWorking` 抹掉
        // working 行的隐藏态。上一行 `loadCommittedBaselineRecovering` 已处理 saved 损坏恢复，此处读到的
        // 是已清理后的状态（坏 → 传播，不吞，同 `review()` 里 `loadSavedLossy` 调用点的处理）。
        let committedHiddenIds = try reviewArchiveRepo.loadSavedLossy(recordId: recordId)?.hiddenIds ?? []
        do {
            // P1a Task 12（Z1）：`w.lossy`/`w.hiddenOriginalIds` 携带 working 行完整有损集 + 隐藏态，
            // 使引擎携带的 `loadedReviewLossy`/`loadedReviewHiddenIds` 能在后续 save 路径原样传回。
            return try await buildReviewEngine(recordId: recordId, startTickOverride: w.stepTick,
                                               reviewLossy: w.lossy, reviewHiddenIds: w.hiddenOriginalIds,
                                               committedBaseline: baseline, committedHiddenIds: committedHiddenIds,
                                               preloadedRecordBundle: bundle)
        } catch let e as AppError where e == Self.invalidResumeTickError {
            // codex whole-branch R6（high）：`w.stepTick` 落在 `[0, metaStartTick)`——`buildReviewEngine`
            // 已 clearWorking，此处只需回退 nil（router 回退 fresh `review()`，不碰 saved/record，无 brick）。
            return nil
        }
    }

    /// review-redesign Task 6：committed 基线 = saved（独立解码，只碰 saved 列，working 不动）。
    /// saved 坏 → `clearSaved` + `pendingReviewCorruptToast=true` + 返回空基线继续（不致命）。
    /// **clearSaved 失败不吞**（codex plan-R4-high，不用 `try?`）：只有清库成功才回退空基线+toast；
    /// 清库失败 rethrow → review 入口失败（可重试），**绝不**在坏 saved 仍在库时以假空基线开界面。
    private func loadCommittedBaselineRecovering(recordId: Int64) throws -> [DrawingObject] {
        pendingReviewCorruptToast = false   // final-review M1：先复位，clean entry 绝不继承上次残留的 true
        do {
            return try reviewArchiveRepo.loadSaved(recordId: recordId) ?? []
        } catch let e as AppError where e.isDBCorrupted {
            try reviewArchiveRepo.clearSaved(recordId: recordId)
            pendingReviewCorruptToast = true
            return []
        }
    }

    /// codex whole-branch R6（high）：resume tick 落在 `[0, metaStartTick)`（下界越界）时的可捕获哨兵信号——
    /// `resumePendingReview` 精确捕获这一个值以回退 `nil`，与 ops-corruption 入口终局校验的
    /// `.persistence(.dbCorrupted)`（那个不清 working）保持可区分。
    private static let invalidResumeTickError = AppError.internalError(module: "review", detail: "invalidResumeTick")

    /// review-redesign Task 6：`review()`/`resumePendingReview()` 共享的引擎构造 + 入口终局校验。
    /// `startTickOverride`：nil=用 meta.startDatetime 派生的训练起点（fresh review）；
    /// 非 nil=resume 续到该 tick（committed 基线/flow 边界仍锚 meta 起点，不随 resume 漂移）。
    /// **入口终局等式强制（codex plan-R3/R5-high）**：构造后重折叠全部 `ops` 到 `record.finalTick`，
    /// 与 record 终局不符（损坏 op 序列 / totalCost 造假）→ `.dbCorrupted`（review 不开、reader 已关）。
    /// 这样顶栏每帧 `ReviewLedger.state` 可 `try?`（入口已验，永不兜底），杜绝逐帧 trap。
    /// `preloadedRecordBundle`：codex whole-branch R5——`resumePendingReview` 校验 `w.stepTick` 时已加载过
    /// 一次 bundle，传入此处复用（避免同一 recordId 重复 `loadRecordBundle`）；nil（`review()` 路径）→ 自行加载。
    private func buildReviewEngine(recordId: Int64, startTickOverride: Int?,
                                    reviewLossy: LossyDrawingArray,
                                    reviewHiddenIds: [DrawingID] = [],
                                    committedBaseline: [DrawingObject],
                                    committedHiddenIds: [DrawingID] = [],
                                    preloadedRecordBundle: (TrainingRecord, [TradeOperation], [DrawingObject])? = nil
                                    ) async throws -> TrainingEngine {
        let (record, ops, drawings) = try preloadedRecordBundle ?? recordRepo.loadRecordBundle(id: recordId)
        // Note: loadRecordBundle() is app.sqlite source — its .dbCorrupted propagates ABOVE this catch (fail-closed).
        let file = try cachedFile(filename: record.trainingSetFilename)
        let reader: any TrainingSetReader
        do {
            reader = try openReader(for: file)
        } catch where isCorruptTrainingSet(error) {
            try? cache.delete(file)                          // 同上（best-effort 可弃）：训练组损坏；record 仍在 app.sqlite（不删）
            throw AppError.persistence(.dbCorrupted)         // 无法替代，surface
        }
        let engine: TrainingEngine
        do {
            // maxTick 由 .review(record) 内部据 record.finalTick 派生；make 亦校验 .m3 非空 +
            // m3.last.endGlobalIndex >= finalTick，故此处不重复 maxTick(from:)（D3 / LOW#8）。
            let allCandles = try reader.loadAllCandles()
            let meta = try reader.loadMeta()                  // B3：起始点 tick 派生（review 从训练起点重演）
            let metaStartTick = TrainingEngine.startTick(forStartDatetime: meta.startDatetime, in: allCandles)
            // codex whole-branch R6（high）：R5 在 `resumePendingReview` 加的 guard 只挡 `w.stepTick`
            // 越出 `0...finalTick`，未验下界——`metaStartTick`（训练组起点，可 >0）才是 `ReviewFlow.
            // allowedTickRange` 真正的下界。`stepTick ∈ [0, metaStartTick)` 会绕过那条 guard，下方
            // `TrainingEngine.make` 因 `flow.allowedTickRange` 不含该 tick 而 throw
            // `AppError.trainingSet(.emptyData)`——若不在此拦截，该错误会直接冒泡给
            // `resumePendingReview` 的调用方，但坏 `working_*` 行仍 `.inProgress`，之后每次 tap 都重试
            // 同一失败 resume（永久 brick）。此处视越界为 WORKING 语义损坏（区别于 record-ops 入口
            // 终局校验的 `.dbCorrupted`）：clearWorking + 抛专属可捕获信号，`resumePendingReview` 捕获后
            // 回退 `nil`（fresh review()，不碰 saved/record）。仅在 resume 路径（`startTickOverride`
            // 非 nil）校验——fresh `review()` 恒用 `metaStartTick` 自身，不可能越界。
            if let override = startTickOverride,
               override < metaStartTick || override > record.finalTick || override < 0 {
                try reviewArchiveRepo.clearWorking(recordId: recordId)
                throw Self.invalidResumeTickError
            }
            engine = try TrainingEngine.make(
                .review(record: record, startTick: metaStartTick),
                allCandles: allCandles,
                initialTick: startTickOverride ?? metaStartTick,   // resume 续到该 tick；fresh=训练起点
                initialCapital: record.totalCapital,
                initialCashBalance: record.totalCapital + record.profit,   // 末态全现金（强平后）
                initialMarkers: markers(from: ops),
                initialDrawings: drawings,
                initialTradeOperations: ops)
        } catch {
            reader.close()
            throw (error as? AppError) ?? .internalError(module: "E6a", detail: String(describing: error))
        }
        // 入口终局等式强制校验（fail-closed）：损坏 op 序列（ReviewLedger.state 自身 throw）或终局不符
        // （guard 手动 throw）都在此统一 close reader（避免上面的 catch-all 块二次 close）。
        do {
            let finalState = try ReviewLedger.state(atTick: engine.tick.maxTick, ops: engine.tradeOperations,
                                                    initialCapital: engine.initialCapital,
                                                    markPriceAtTick: { engine.markPrice(atTick: $0) })
            // 显式容差（FP 折叠序噪声 ~1e-9 相对；毛损坏必远超）：profit 绝对 1e-4 元、rate 绝对 1e-7
            guard abs((finalState.totalCapital - engine.initialCapital) - record.profit) <= 1e-4,
                  abs(finalState.returnRate - record.returnRate) <= 1e-7
            else { throw AppError.persistence(.dbCorrupted) }
        } catch {
            reader.close()
            throw (error as? AppError) ?? .internalError(module: "E6a", detail: String(describing: error))
        }
        activeReader = reader
        activeEngine = engine
        activeFile = file
        cache.touch(file)                        // §A touch-on-use：完整读取+引擎构造成功后刷 LRU mtime（codex-13a-F2）
        activeStartedAt = nil                    // D4：review 只读，无进度保存
        activeSessionKey = nil                   // RFC §4.7c：review 无 session key
        activeRecord = record                    // RFC-B D5：复用已加载 record（零新 I/O）
        engine.setReviewLossy(reviewLossy, hiddenIds: reviewHiddenIds)
        reviewRecordId = recordId
        reviewCommittedBaseline = committedBaseline
        reviewCommittedHiddenIds = committedHiddenIds
        reviewSessionToken = UUID()     // Task 7：新复盘 session mint 新 token（陈旧排队 autosave 靠此失效）
        reviewAutosaveTask = nil        // final-review T7：belt-and-suspenders——新 token 已够，随手清掉陈旧排队引用
        reviewRevision = 0
        return engine
    }

    /// Replay 模式（spec L1673）：record → 打开 reader → 从头构造 ReplayFlow 引擎（只继承原局
    /// feeSnapshot，不还原标记/绘线、不入账，D6）。起始本金 = record 原局起始本金。
    public func replay(recordId: Int64) async throws -> TrainingEngine {
        let (record, _, _) = try recordRepo.loadRecordBundle(id: recordId)
        // Note: loadRecordBundle() is app.sqlite source — its .dbCorrupted propagates ABOVE this catch (fail-closed).
        let file = try cachedFile(filename: record.trainingSetFilename)
        let reader: any TrainingSetReader
        do {
            reader = try openReader(for: file)
        } catch where isCorruptTrainingSet(error) {
            try? cache.delete(file)                          // 同上（best-effort 可弃）：训练组损坏；record 仍在 app.sqlite（不删）
            throw AppError.persistence(.dbCorrupted)         // 无法替代，surface
        }
        do {
            let allCandles = try reader.loadAllCandles()
            let meta = try reader.loadMeta()                  // F2：起始点 tick 派生（replay 从头）
            let mt = try maxTick(from: allCandles)
            let startTick = TrainingEngine.startTick(forStartDatetime: meta.startDatetime, in: allCandles)
            let engine = try TrainingEngine.make(
                .replay(fees: record.feeSnapshot, maxTick: mt),
                allCandles: allCandles,
                initialTick: startTick,
                initialCapital: record.totalCapital,
                initialCashBalance: record.totalCapital)
            activeReader = reader
            activeEngine = engine
            activeFile = file
            cache.touch(file)                        // §A touch-on-use：完整读取+引擎构造成功后刷 LRU mtime（codex-13a-F2）
            activeStartedAt = now()                  // 新需求10：replay 会话起始，供 PendingReplay.started_at
            activeSessionKey = nil                   // RFC §4.7c：replay 无 session key
            activeRecord = record                    // RFC-B D5：复用已加载 record（原本被丢弃，零新 I/O）
            replayBaseline = (engine.tick.globalTickIndex, engine.tradeOperations.count, engine.drawings.count,
                              engine.upperPanel.period, engine.lowerPanel.period)  // fresh 基线（含周期，codex plan-R14-F1）
            replayHasPersisted = false              // fresh：尚未拥有槽（codex plan-R6-F1）
            resetAutosaveState()                    // 新需求10（codex plan-R7-F1）：重开 autosave 栅栏（terminating=false 等）
            return engine
        } catch {
            reader.close()
            throw (error as? AppError) ?? .internalError(module: "E6a", detail: String(describing: error))
        }
    }

    /// 保存进度（spec L1659/L1677：U2 退出 / 每 N tick 自动调用）。Normal/Replay 模式持久化
    /// （review 只读 → no-op，D3）。缺活跃上下文 → .internalError（D9）。
    public func saveProgress(engine: TrainingEngine) async throws {
        guard engine.flow.shouldPersistProgress() else { return }  // D3：仅 Normal/Replay 持久化
        if engine.flow.mode == .replay {
            // codex plan-R3-F2：fail-closed（镜像 normal saveProgress 的活跃上下文守卫）——
            // 缺上下文 throw（autosave/back 显错）而非静默 return（静默=用户无感的进度丢失）。
            guard activeEngine === engine, let file = activeFile,
                  let recordId = activeRecord?.id, let started = activeStartedAt else {
                throw AppError.internalError(module: "E6b", detail: "replay saveProgress without active session context")
            }
            // codex plan-R4-F1 + R6-F1：clean-skip **仅在尚未拥有槽时**生效。fresh 会话首写前、且当前态==基线
            // （无 tick/交易/画线变化）→ 跳过写，防 back()/后台 flush 用 fresh B 初始态覆盖另一记录 A 的槽。
            // **首写后(replayHasPersisted)永不跳过**——否则"加画线→写→删画线(count 回基线)→跳过"会残留已删画线。
            if !replayHasPersisted,
               let base = replayBaseline,
               base.tick == engine.tick.globalTickIndex,
               base.ops == engine.tradeOperations.count,
               base.drawings == engine.drawings.count,
               base.upper == engine.upperPanel.period,      // codex plan-R14-F1：切周期也算脏
               base.lower == engine.lowerPanel.period {
                return
            }
            let replay = PendingReplay(
                recordId: recordId,
                trainingSetFilename: file.filename,
                globalTickIndex: engine.tick.globalTickIndex,
                upperPeriod: engine.upperPanel.period,
                lowerPeriod: engine.lowerPanel.period,
                positionData: try encodePosition(engine.position),
                cashBalance: max(0, engine.cashBalance),
                feeSnapshot: engine.fees,
                tradeOperations: engine.tradeOperations,
                // P1a Task 12（Z1）：重发 reconciled 后的完整有损集（非纯 known）——保住加载 blob 里
                // 未识别（未来版本）的条穿过本次 autosave/resume-save；reconciled 按稳定 id 归并
                // known 的增/删/改，fail-closed（重复/空 id）抛 .dbCorrupted，随 saveProgress 的 throws 传播。
                lossy: try engine.loadedDrawingsLossy.reconciled(currentKnown: engine.drawings),
                startedAt: started,
                accumulatedCapital: engine.initialCapital,
                drawdown: engine.drawdown)
            try pendingReplayRepo.saveReplay(replay)
            replayHasPersisted = true     // codex plan-R6-F1：已拥有槽，此后 saveProgress 永不 clean-skip
            return
        }
        // D4 加固（final-review L2）：engine 必须是当前活跃 session 的引擎，否则会把活跃 session 的
        // 文件/起始时间记到外来 engine 上 → 写错存档。activeEngine 为 nil（无会话）时身份不符亦在此拒绝。
        guard activeEngine === engine, let file = activeFile, let started = activeStartedAt,
              let key = activeSessionKey else {
            throw AppError.internalError(module: "E6b", detail: "saveProgress without active session context")
        }
        let pending = PendingTraining(
            trainingSetFilename: file.filename,
            globalTickIndex: engine.tick.globalTickIndex,
            upperPeriod: engine.upperPanel.period,
            lowerPeriod: engine.lowerPanel.period,
            positionData: try encodePosition(engine.position),
            // R-plan-18-2/25-1：持久化边界 floor —— 退化局（局终强平 手续费>持仓价值 → cashBalance<0）若被
            // autosave 写进 pending，且崩溃在 finalize 清 pending 前 → 下次 make 拒负 initialCashBalance →
            // resume 被 brick。floor max(0,_) 防 brick。明确契约：仅崩溃恢复局按 floored(cash=0) 入历史记录
            // （少记 ≤ 一次强平佣金，偏保守）；正常 finalize 仍读 engine.currentTotalCapital 如实记负。
            cashBalance: max(0, engine.cashBalance),
            feeSnapshot: engine.fees,
            tradeOperations: engine.tradeOperations,
            // P1a Task 12（Z1）：同上 replay 分支——重发 reconciled 后的完整有损集，保住未识别条穿过 autosave/resume-save。
            lossy: try engine.loadedDrawingsLossy.reconciled(currentKnown: engine.drawings),
            startedAt: started,
            accumulatedCapital: engine.initialCapital,         // D4：本局起始资金
            drawdown: engine.drawdown,
            sessionKey: key)                                   // RFC §4.7c：durable session key
        try pendingRepo.savePending(pending)
    }

    /// 正式结束（spec L1663/L1679）：构造 TrainingRecord + ops + drawings 入账，清 pending，返回 recordId。
    /// `flow.shouldSaveRecord()==false`（Review/Replay）→ 早返 nil，不插记录、不动 pending（D2）。
    /// total_capital = 本局**起始**资金（方案 A / D1）；maxDrawdown 元→负比率（D6）；起始年月按 UTC+8（D7）。
    /// 缺活跃上下文 → .internalError（D9）。
    /// 通过 SessionFinalizationPort 单事务执行（§4.7b）；同 sessionKey 重试幂等（§4.7c）。
    public func finalize(engine: TrainingEngine) async throws -> Int64? {
        guard engine.flow.shouldSaveRecord() else { return nil }   // D2：Review/Replay 不入账（fence 前 return）
        await fenceAndDrainAutosaves()           // §4.7d：单事务入账前排空排队 autosave，防终态脏写复活 pending
        // D4 加固（final-review L2）：engine 必须是当前活跃 session 的引擎，否则会把活跃 session 的
        // 文件/股票元数据记到外来 engine 的交易数据上 → 写错历史记录。activeEngine 为 nil 时亦在此拒绝。
        guard activeEngine === engine, let file = activeFile, let reader = activeReader,
              let key = activeSessionKey else {
            throw AppError.internalError(module: "E6b", detail: "finalize without active session context")
        }
        let meta = try reader.loadMeta()
        let starting = engine.initialCapital                       // D1：起始资金
        let profit = engine.currentTotalCapital - starting
        let (year, month) = Self.startYearMonth(from: meta.startDatetime)
        let record = TrainingRecord(
            id: nil,
            trainingSetFilename: file.filename,
            createdAt: now(),                                      // D5
            stockCode: meta.stockCode,
            stockName: meta.stockName,
            startYear: year,
            startMonth: month,
            totalCapital: starting,                               // D1：本局起始资金
            profit: profit,
            returnRate: engine.returnRate,
            maxDrawdown: Self.drawdownRatio(absolute: engine.drawdown.maxDrawdown,
                                            peak: engine.drawdown.peakCapital),   // D6
            buyCount: engine.tradeOperations.filter { $0.direction == .buy }.count,    // D8
            sellCount: engine.tradeOperations.filter { $0.direction == .sell }.count,
            feeSnapshot: engine.fees,
            finalTick: engine.tick.globalTickIndex)
        // RFC §4.7b：单事务（insertRecord + clearPending 原子）+ §4.7c 幂等锚（sessionKey）
        let result = try finalization.finalizeSession(record: record,
                                                      ops: engine.tradeOperations,
                                                      drawings: engine.drawings,
                                                      sessionKey: key)
        // R-plan-5-1：刷缓存用「事务内产出、随成功返回的 DB 权威值」result.totalCapital —— retry 也 = 持久
        // 记录值（非 retry engine 现值）→ 缓存恒 == DB 权威；R-plan-4-2：值随成功返回、无 fallible 后置读。
        settings.refreshTotalCapital(result.totalCapital)
        return result.id
    }

    /// 非持久化 replay 结算 payload（RFC §4.4e）：replay 结束强平后，构造 in-memory `TrainingRecord`
    /// （复用类型）供顺位 8 SettlementView 呈现。**不持久化不变量**：不写 `training_records`、不触
    /// `pending_training`、不改 `finalize`（其对 replay 仍返 nil）。用**原局 FeeSnapshot**（replay 构造时
    /// 继承）+ 强平后终态。字段语义刻意镜像 `finalize`（D1 方案 A：totalCapital=起始资金；profit/收益率/
    /// 回撤比率/计数同口径），由 drift-guard 测试守；**有意不抽 finalize 共享 helper**，保 finalize 不在
    /// 本 PR diff 内（§4.7 finalize-gating residual 归顺位 10，不被本 PR 触碰）。
    /// 前置：replay 模式 + 活跃会话（caller=顺位 8 路由）。强平由 caller 先行（本方法只读终态）。
    /// 新需求10(A6)：async。顺序：①两 guard（fail-closed，含 recordId；缺则 throw、槽保留）→
    /// ②`fenceAndDrainAutosaves`（终态栅栏，排空排队 autosave）→ ③构建 payload（全部 throwing 工作，槽仍在）→
    /// ④成功后条件清槽（`clearReplay(ifRecordId:)`，防误删别记录槽）→ ⑤return record。
    /// clearReplay 抛 → 方法抛（caller 保留 session+槽，可重试，codex plan-R1-F2）。
    public func replaySettlementPayload(engine: TrainingEngine) async throws -> TrainingRecord {
        guard engine.flow.mode == .replay else {
            throw AppError.internalError(module: "E6b", detail: "replaySettlementPayload requires replay flow")
        }
        // 新需求10(A6)：recordId 纳入 guard（fail-closed，codex plan-R8-F1）——缺则 throw、保留会话（不静默成功留陈旧槽）。
        guard activeEngine === engine, let reader = activeReader, let file = activeFile,
              let recordId = activeRecord?.id else {
            throw AppError.internalError(module: "E6b", detail: "replaySettlementPayload without active session context")
        }
        // 新需求10(A6)：终态栅栏——排空排队 autosave，此后无并发写，自动 save 不复活已清槽（codex plan-R1-F2）。
        await fenceAndDrainAutosaves()
        // 全部 throwing payload 工作在此完成，槽仍在（任何抛错不清槽，fail-closed）。
        let meta = try reader.loadMeta()
        let starting = engine.initialCapital
        let profit = engine.currentTotalCapital - starting
        let (year, month) = Self.startYearMonth(from: meta.startDatetime)
        let record = TrainingRecord(
            id: nil,
            trainingSetFilename: file.filename,
            createdAt: now(),
            stockCode: meta.stockCode,
            stockName: meta.stockName,
            startYear: year,
            startMonth: month,
            totalCapital: starting,
            profit: profit,
            returnRate: engine.returnRate,
            maxDrawdown: Self.drawdownRatio(absolute: engine.drawdown.maxDrawdown,
                                            peak: engine.drawdown.peakCapital),
            buyCount: engine.tradeOperations.filter { $0.direction == .buy }.count,
            sellCount: engine.tradeOperations.filter { $0.direction == .sell }.count,
            feeSnapshot: engine.fees,
            finalTick: engine.tick.globalTickIndex)
        // 新需求10(A6)：payload 构建成功后才清槽（codex plan-R1-F2）。
        // 条件清（codex plan-R3-F1）：仅清属于当前 replay 记录的槽——防"开新 replay B 未存即到终局"
        // 误删另一记录 A 的暂停槽。recordId 来自顶部 guard 绑定（缺则已 throw=fail-closed）。
        // clearReplay 抛 → 方法抛、record 不返回 → caller 保留 session+槽、可重试。
        try pendingReplayRepo.clearReplay(ifRecordId: recordId)
        return record
    }

    /// 新需求10：该记录是否有可续局 replay 暂存。**display-only/advisory**（历史弹窗按钮文案）。
    /// 用轻量 `loadReplaySlotInfo`（不解码 payload，codex plan-R11-F1）：损坏 payload 不影响归属判断。
    /// 读失败保守返 false 安全：路由是 resume-first 权威（replay(id:) 总先试 resumePendingReplay），
    /// 故此处一次瞬态 false 至多让按钮文案短暂误显「再次训练」，点击仍走 resume-first 不会丢槽。
    public func hasResumableReplay(recordId: Int64) -> Bool {
        ((try? pendingReplayRepo.loadReplaySlotInfo()) ?? nil)?.recordId == recordId
    }

    /// review-redesign Task 11：当前 replay 续局单槽归属的 recordId（供首页"再次训练中"角标）。
    /// 镜像 `hasResumableReplay`：轻量 `loadReplaySlotInfo`（不解码 payload），try? 兜底 nil。
    public func replaySlotRecordId() -> Int64? {
        ((try? pendingReplayRepo.loadReplaySlotInfo()) ?? nil)?.recordId
    }

    /// 新需求10：续局 replay。元数据先判归属→本记录全量解码→校验记录/文件名→open reader→按存档 tick/状态重建。
    /// 错误纪律：**本记录 loadReplay `.dbCorrupted` → durable clearReplay + nil（回退从头）**；
    /// **非 `.dbCorrupted` 的 loadReplay / loadRecordBundle / loadAllCandles / make 错误 → 传播**（不清、不 fresh）；
    /// 清档点 = openReader `isCorruptTrainingSet`（cache.delete+clearReplay）/ 文件名不一致（clearReplay）/ 本记录 `.dbCorrupted`。
    /// 无槽 / recordId 不匹配 → nil（不清档）。**注意：不是"loadReplay 错误一律传播"**（那会让永久损坏槽卡死，R13-F1）。
    public func resumePendingReplay(recordId: Int64) async throws -> TrainingEngine? {
        // 1) 轻量元数据先判归属（codex plan-R11-F1）：不解码 payload → 别记录的损坏槽不阻塞本记录的 replay。
        //    slotInfo 自身错误=DB 级瞬态（whole-db 不可达）→ 传播。无槽/不匹配 → nil（不清档）。
        guard let info = try pendingReplayRepo.loadReplaySlotInfo(), info.recordId == recordId else { return nil }
        // 2) 本记录槽：全量解码 **含 position（codex plan-R18-F1：position 的 PositionManager JSON 解码也是 slot
        //    payload，须与 loadReplay 同走 .dbCorrupted→清 路径；decodePosition 已把所有解码错误包成 .dbCorrupted）**。
        //    .dbCorrupted（已验证损坏 payload）→ 清 + 回退从头；其他（瞬态）→ 传播。
        let pending: PendingReplay
        let position: PositionManager
        do {
            guard let p = try pendingReplayRepo.loadReplay() else { return nil }   // 竞态：刚被清 → nil
            pending = p
            position = try decodePosition(p.positionData)   // slot payload 解码（移到此处，与 loadReplay 同 .dbCorrupted 路径）
        } catch let e as AppError {
            if case .persistence(.dbCorrupted) = e {
                // 本记录损坏槽（loadReplay JSON 或 position JSON）→ durable 清 + 回退从头（router fresh）。**不用 try?**
                // （codex plan-R12-F1）：清失败=瞬态 DB（满/不可用）→ 传播可重试错误，**不**伪装"无暂存"而留损坏行卡死。
                try pendingReplayRepo.clearReplay()
                return nil
            }
            throw e                                    // 瞬态 → 传播（不清、不 fresh）
        }
        // 记录不会被单独删除（reset 连带清槽，无孤儿）→ loadRecordBundle 错误必瞬态 → 传播（不清档）
        let (record, _, _) = try recordRepo.loadRecordBundle(id: pending.recordId)
        // codex plan-R10-F1：pending 的文件名须与记录一致——否则 stale/corrupt 槽会让记录 A 的 id 配文件 B 的
        // candles/metadata（显错标的、终局清理失准）。内部不一致=已验证损坏槽 → 清 + 返回 nil（router 回退从头 replay，用记录权威文件名）。
        guard pending.trainingSetFilename == record.trainingSetFilename else {
            try pendingReplayRepo.clearReplay()
            return nil
        }
        let file = try cachedFile(filename: pending.trainingSetFilename)
        let reader: any TrainingSetReader
        do {
            reader = try openReader(for: file)
        } catch where isCorruptTrainingSet(error) {
            try? cache.delete(file)                 // best-effort：训练组损坏，孤儿槽不可恢复
            try pendingReplayRepo.clearReplay()      // durable 清（唯一清档点）
            return nil                               // 调用方回退从头 replay
        }
        let allCandles: [Period: [KLineCandle]]
        let mt: Int
        do {
            allCandles = try reader.loadAllCandles()
            mt = try maxTick(from: allCandles)
        } catch {
            reader.close()
            throw (error as? AppError) ?? .internalError(module: "E6b", detail: String(describing: error))
        }
        // 前置校验（codex whole-branch R1 HIGH + R2-F1 HIGH）：make L244-245 和 L220/L236-240 对同一条件抛
        // .trainingSet(.emptyData)，而 catch 仅 rethrow 不清槽 → AppRouter resume-first 每次都撞同一槽 → 永久 brick。
        // 在此提前检出 → reader.close + durable clearReplay（try: 失败向上传播，调用方可重试）+ nil。
        // 周期校验（codex whole-branch R2-F1）：saved period 不在 candle map 中 → make final-R6-F1 抛 emptyData →
        // 同 brick 路径；在此镜像 make L244-245 提前清槽。
        guard !(allCandles[pending.upperPeriod] ?? []).isEmpty,
              !(allCandles[pending.lowerPeriod] ?? []).isEmpty,
              (0...mt).contains(pending.globalTickIndex),
              pending.cashBalance.isFinite, pending.cashBalance >= 0,
              pending.accumulatedCapital.isFinite, pending.accumulatedCapital >= 0,
              pending.drawdown.peakCapital.isFinite, pending.drawdown.peakCapital >= 0,
              pending.drawdown.maxDrawdown.isFinite, pending.drawdown.maxDrawdown >= 0
        else {
            reader.close()
            try pendingReplayRepo.clearReplay()      // durable: clear failure propagates as retryable
            return nil
        }
        do {
            // position 已在 step 2 解码（slot payload，.dbCorrupted 已处理）；此块仅训练集/transient 错误 → 传播
            let engine = try TrainingEngine.make(
                .replay(fees: pending.feeSnapshot, maxTick: mt),
                allCandles: allCandles,
                initialTick: pending.globalTickIndex,
                initialCapital: pending.accumulatedCapital,
                initialCashBalance: pending.cashBalance,
                initialPosition: position,
                initialMarkers: markers(from: pending.tradeOperations),
                initialDrawings: pending.drawings,
                initialDrawingsLossy: pending.lossy,   // P1a Task 12（Z1）：携带完整有损集（保未识别条穿过后续 save）
                initialTradeOperations: pending.tradeOperations,
                initialDrawdown: pending.drawdown,
                initialUpperPeriod: pending.upperPeriod,
                initialLowerPeriod: pending.lowerPeriod)
            activeReader = reader
            activeEngine = engine
            activeFile = file
            cache.touch(file)                        // §A touch-on-use（同 resumePending）
            activeRecord = record                    // replay 续局需 record（fees/标的名 + 终局 payload）
            activeStartedAt = pending.startedAt
            activeSessionKey = nil                    // replay 无 sessionKey
            replayBaseline = (engine.tick.globalTickIndex, engine.tradeOperations.count, engine.drawings.count,
                              engine.upperPanel.period, engine.lowerPanel.period)  // 续局基线=resumed 态（含周期，codex plan-R4/R14-F1）
            replayHasPersisted = true                 // 续局本就拥有该记录的槽 → 永不 clean-skip（codex plan-R6-F1）
            resetAutosaveState()                      // 新 session：清栅栏/脏/cadence/错误
            return engine
        } catch {
            reader.close()
            throw (error as? AppError) ?? .internalError(module: "E6b", detail: String(describing: error))
        }
    }

    /// session 结束清理（spec L1666/L1684，不 throws）：关闭 reader 并清空全部活跃上下文（D10）。
    public func endSession() async {
        terminating = true          // fence：阻止 teardown 后排队 autosave 复活 pending（§4.7d 同型）
        autosaveTask = nil
        autosaveDirty = false
        lastAutosaveError = nil
        autosaveBannerError = nil                    // §B.2：清 UI 信号防跨局 stale toast
        autosaveErrorGeneration = 0                  // codex-13a-F1：归零失败计数（新局从 0 起）
        ticksSinceAutosave = 0
        reviewSessionToken = nil    // Task 7：软栅栏（同 terminating 范式）——陈旧排队 review autosave 靠 token 失效自然早退
        reviewAutosaveTask?.cancel()
        reviewAutosaveTask = nil
        // codex whole-branch R3（high，data resurrection）：清复盘 session 态本身——`flushReviewForBackground`
        // 此前只凭 `reviewRecordId != nil` 判活，若一枚在 endSession 前排队的后台 flush Task 捕获了旧
        // engine，在 endReviewDiscard/abandonReview/backReview 收尾之后才跑到，会拿这两个陈旧字段把已丢弃/
        // 已提交的工作态当"净改动"重新写回 working 行（用户已看到的丢弃/保存又"复活"）。终态收尾后二者必须
        // 归位，使该陈旧 flush 命中下面的早退 guard（no-op）。
        reviewRecordId = nil
        reviewCommittedBaseline = []
        reviewCommittedHiddenIds = []
        activeReader?.close()
        activeReader = nil
        activeEngine = nil
        activeFile = nil
        activeStartedAt = nil
        activeSessionKey = nil                       // RFC §4.7c：清空 session key
        activeRecord = nil                           // RFC-B D5：防 review 结束后 stale 标的名
        replayBaseline = nil
        replayHasPersisted = false
    }

    /// §4.7e discard 持久终态：fence autosaves → 清持久化槽 → endSession（durable 不复活）。
    /// 清槽失败 → 保留 active session（不 teardown）供 retry，透传 AppError。
    /// 新需求10(A6)：replay 清 pending_replay（条件清，fail-closed）；normal 清 pending_training（原逻辑）。
    public func discardSession() async throws {
        await fenceAndDrainAutosaves()
        do {
            // 新需求10(A6)：replay 局 discard 条件清 replay 槽（仅属当前记录，防误删别的记录槽，codex plan-R3-F1）；
            // fail-closed（codex plan-R8-F1）：replay 缺 activeRecord.id → throw、保留会话（不静默结束留陈旧槽）；
            // normal 清 pending_training（原逻辑）。
            if activeEngine?.flow.mode == .replay {
                guard let activeId = activeRecord?.id else {
                    throw AppError.internalError(module: "E6b", detail: "replay discard without active record")
                }
                try pendingReplayRepo.clearReplay(ifRecordId: activeId)
            } else {
                try pendingRepo.clearPending()
            }
        } catch {
            throw (error as? AppError)
                ?? .internalError(module: "E6b", detail: "discard clear: \(error)")
        }
        await endSession()
    }

    // MARK: - review-redesign RFC：复盘持久化核心（committed 基线 + 净改动判定，Task 5）

    /// 该记录是否有「进行中」复盘存档（display-only，供历史弹窗/首页角标）。try? 兜底 false。
    public func hasReviewInProgress(recordId: Int64) -> Bool {
        ((try? reviewArchiveRepo.reviewMarker(recordId: recordId)) ?? .none) == .inProgress
    }

    /// 批量加载全部复盘存档标记（供首页角标）。try? 兜底 [:]。
    public func loadReviewMarkers() -> [Int64: ReviewMarker] {
        (try? reviewArchiveRepo.loadMarkers()) ?? [:]
    }

    /// 当前复盘 session 是否有净改动：当前活跃引擎的 `reviewDrawings`/`loadedReviewHiddenIds` vs committed
    /// 基线（顺序无关）。codex whole-branch High fix：须纳入 hiddenIds——否则「画线集相同、仅 hiddenIds
    /// 不同」被误判无改动。
    public func reviewNetChanged() -> Bool {
        ReviewNetChange.changed(working: activeEngine?.reviewDrawings ?? [], committed: reviewCommittedBaseline,
                                workingHiddenIds: activeEngine?.loadedReviewHiddenIds ?? [],
                                committedHiddenIds: reviewCommittedHiddenIds)
    }

    /// 复盘中按需持久化：有净改动（vs committed 基线）→ 写 working（`stepTick`=当前 tick）；
    /// 无净改动 → 清 working（回退到 committed：saved 或删行）。无复盘 session（`reviewRecordId`==nil）→ no-op。
    public func persistReviewWorkingIfChanged(engine: TrainingEngine) throws {
        // codex whole-branch R3（high）：central review_archive 写者身份闸——`autosaveReview` 与
        // `flushReviewForBackground` 均汇聚于此。一枚捕获了旧（已被终态收尾丢弃/提交）engine 的陈旧
        // Task 即便 `reviewRecordId` 判活失败前碰巧未被 endSession 清（或跨 session 撞见另一局同名 id 的
        // 边界情况），身份不符也在此再拦一次，绝不用非当前活跃 engine 的数据落 review_archive。
        guard activeEngine === engine else { return }
        guard let id = reviewRecordId else { return }
        // codex whole-branch High fix：净改动判定须纳入 hiddenIds（4-arg 形式）——2-arg 形式只比较画线集，
        // 「working 画线集==committed 基线但 hiddenIds 不同」会被误判无改动 → 走下方 `clearWorking` 分支，
        // 抹掉这份 working 行携带的隐藏态（P1a 的 forward-compat 数据丢失路径）。
        if ReviewNetChange.changed(working: engine.reviewDrawings, committed: reviewCommittedBaseline,
                                    workingHiddenIds: engine.loadedReviewHiddenIds,
                                    committedHiddenIds: reviewCommittedHiddenIds) {
            // P1a Task 12（Z1）：重发 reconciled 后的完整有损集（非纯 known）+ 原样传回加载来的 hiddenIds
            // （不用默认 `[]` 覆盖 P5 写的隐藏态，codex R11-high）——保住加载 blob 里未识别的条穿过本次 autosave。
            try reviewArchiveRepo.saveWorking(recordId: id, stepTick: engine.tick.globalTickIndex,
                                              lossy: try engine.loadedReviewLossy.reconciled(currentKnown: engine.reviewDrawings),
                                              hiddenOriginalIds: engine.loadedReviewHiddenIds)
        } else {
            try reviewArchiveRepo.clearWorking(recordId: id)
        }
    }

    /// 提交复盘：saved = 当前 `reviewDrawings`，清 working；committed 基线前移到刚提交的画线集。
    /// 无复盘 session → no-op。
    /// codex whole-branch R4 finding 2：终态写者 fail-closed——`endReviewSave` 在此之前
    /// `await fenceAndDrainReviewAutosave()`，@MainActor 重入窗口内会话状态可能已先被换成另一记录
    /// （`activeEngine`/`reviewRecordId` 均已指向新 session）；陈旧调用方若仍持旧 `engine` 继续往下写，
    /// 会把旧数据错误提交进新 `reviewRecordId` 的存档。engine 与当前活跃会话不符 → throw（非静默 no-op），
    /// 绝不带着不明确的身份写 `review_archive`。
    public func commitReview(engine: TrainingEngine) throws {
        guard let id = reviewRecordId else { return }
        guard activeEngine === engine, engine.flow.mode == .review else {
            throw AppError.internalError(module: "review", detail: "terminal review write on stale/mismatched session")
        }
        // P1a Task 12（Z1）：同 `persistReviewWorkingIfChanged`——reconciled 重发完整有损集 + 传回加载来的 hiddenIds。
        try reviewArchiveRepo.commitSaved(recordId: id,
                                          lossy: try engine.loadedReviewLossy.reconciled(currentKnown: engine.reviewDrawings),
                                          hiddenOriginalIds: engine.loadedReviewHiddenIds)
        reviewCommittedBaseline = engine.reviewDrawings
        reviewCommittedHiddenIds = engine.loadedReviewHiddenIds   // 两基线同步前移（codex whole-branch High fix）
    }

    /// 丢弃复盘工作态：清 working（回退到 committed：saved 或删行）。无复盘 session → no-op。
    /// codex whole-branch R4 finding 2：同 `commitReview` 的 fail-closed 身份闸（见上方注释）。
    public func discardReviewWorking(engine: TrainingEngine) throws {
        guard let id = reviewRecordId else { return }
        guard activeEngine === engine, engine.flow.mode == .review else {
            throw AppError.internalError(module: "review", detail: "terminal review write on stale/mismatched session")
        }
        try reviewArchiveRepo.clearWorking(recordId: id)
    }

    // MARK: - review-redesign Task 7：复盘 autosave 节流 + 终态 drain（§6.3）

    /// 复盘中按需节流 autosave（画线/步进触发，无复盘 session → no-op）。token 于调用时同步捕获
    /// （非排队 Task 内），保证跨 session 陈旧判定正确：捕获后若 `reviewSessionToken` 变化（终态置 nil
    /// 或新 session 换新 token），排队写在执行时对比不等 → 早退丢弃。revision 用于同 token 内的合并
    /// （调度期间又有新请求 → 追上最新再等一轮"静默窗口"，收敛为一次落最新态的写，而非逐次都写）。
    /// 已有排队 Task（`reviewAutosaveTask != nil`）→ 仅递增 revision 合并，不重复排程。
    /// codex whole-branch R6（medium）：顶部先做 `flushReviewForBackground` 同款身份闸——一枚刚终态收尾的
    /// 陈旧 TrainingView 回调若在此之后才携旧 engine 调用本方法，此前会先递增 `reviewRevision` /
    /// 占用 `reviewAutosaveTask` 槽位（因为身份校验此前只在 `persistReviewWorkingIfChanged` 内部真正落盘
    /// 时才生效），导致新 session 紧随其后的合法 `autosaveReview` 因槽位已被占用而仅被合并（不重新排程）——
    /// 但排队 Task 闭包捕获的仍是陈旧 engine，最终 no-op，新 session 这次改动直到下次触发才真正落盘，
    /// 产生一个静默丢失窗口。在此提前拦截，陈旧 engine 早退、不占槽/不计数，新 session 的调用可正常排程。
    public func autosaveReview(engine: TrainingEngine) {
        guard activeEngine === engine, engine.flow.mode == .review, reviewRecordId != nil,
              let token = reviewSessionToken else { return }
        reviewRevision += 1
        guard reviewAutosaveTask == nil else { return }
        reviewAutosaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.reviewAutosaveTask = nil }
            var pendingRevision = self.reviewRevision
            while true {
                await Task.yield()                                             // 节流窗口
                guard self.reviewSessionToken == token else { return }         // 陈旧（session 已切换/终止）→ 丢弃
                guard self.reviewRevision == pendingRevision else {             // 窗口内又有新请求 → 追上重试
                    pendingRevision = self.reviewRevision
                    continue
                }
                break
            }
            // codex whole-branch R4 finding 1：不再用 `try?` 吞掉持久化失败——失败须走与 normal autosave
            // 同一套可观察信号（`recordAutosaveError`），否则用户可能后台/杀进程时以为已存实则未存。
            do {
                try self.persistReviewWorkingIfChanged(engine: engine)
            } catch {
                self.recordAutosaveError(error)
            }
        }
    }

    /// 终态栅栏：invalidate token（陈旧排队写靠此早退）+ cancel（协作式，belt-and-suspenders，实际
    /// 生效点是上面的 token 比对）+ await 排空在飞节流 Task，保证其后的权威终态写 last-wins。
    /// 镜像 replay/normal 的 `fenceAndDrainAutosaves`（`terminating` flag），但 review 用独立的
    /// token/revision/task ——不共用 `terminating`（review 有自己的生命周期，与 replay/normal saveProgress 无关）。
    private func fenceAndDrainReviewAutosave() async {
        reviewSessionToken = nil
        reviewAutosaveTask?.cancel()
        await reviewAutosaveTask?.value
    }

    /// 复盘返回（drain → persistReviewWorkingIfChanged → endSession）。
    public func backReview(engine: TrainingEngine) async throws {
        await fenceAndDrainReviewAutosave()
        try persistReviewWorkingIfChanged(engine: engine)
        await endSession()
    }

    /// 复盘保存结束（drain → commitReview → endSession）。
    public func endReviewSave(engine: TrainingEngine) async throws {
        await fenceAndDrainReviewAutosave()
        try commitReview(engine: engine)
        await endSession()
    }

    /// 复盘丢弃结束（drain → discardReviewWorking → endSession）。
    public func endReviewDiscard(engine: TrainingEngine) async throws {
        await fenceAndDrainReviewAutosave()
        try discardReviewWorking(engine: engine)
        await endSession()
    }

    /// codex whole-branch R2（medium）：稳健放弃——与 `endReviewDiscard` 不同，本方法**恒**收尾会话，
    /// 即便清 working 失败也不放弃 `endSession`（那会让 coordinator 保留活跃 reader/session，而 router
    /// 已摘视图 → 会话/reader 泄漏）。drain → best-effort 清 working（`try?`，失败不阻断）→ 恒 endSession。
    /// 语义：放弃恒干净退出；若清档失败，`复盘中` marker 简单保留（可恢复——用户可重新进入再次结束）。
    /// 供 UI「复盘保存失败」alert 的「放弃」按钮使用（不复用 `endReviewDiscard`——那个仍需在结束→不保存 /
    /// 重试路径上把清档失败 rethrow 出去以重弹 alert，语义不同，不改动）。
    public func abandonReview(engine: TrainingEngine) async {
        await fenceAndDrainReviewAutosave()
        try? discardReviewWorking(engine: engine)
        await endSession()
    }

    /// codex whole-branch R1（data-loss）：scenePhase 后台/失活 flush review working 态（镜像 normal/replay
    /// 的 `flushAutosave`，§4.6 item 4），补齐此前只有 `flushForBackground`（对 review no-op）的缺口——
    /// review 画线/步进只靠排队 `autosaveReview` 落盘，若 OS 在其排空前杀进程会丢工作态。
    /// 与 `fenceAndDrainReviewAutosave`（终态栅栏，供 back/endReviewSave/endReviewDiscard）的关键区别：
    /// **不** invalidate `reviewSessionToken`——这是后台 flush，非终态；回前台后 session 须能继续。
    /// cancel + await 排空在飞排队 autosave（若有）→ 再显式 `persistReviewWorkingIfChanged` 落当前态（best-effort
    /// 不阻断 teardown/不 throw；但**失败须走 `recordAutosaveError`**——codex whole-branch R4 finding 1：此前
    /// `try?` 静默吞错，回前台后用户对「后台未存成功」完全无感知；现失败置 `autosaveBannerError` +
    /// 递增 `autosaveErrorGeneration`，供回前台后既有 scenePhase `.active` replay 呈现 toast）。非 review 模式或
    /// 无复盘 session（`reviewRecordId == nil`）→ no-op。
    public func flushReviewForBackground(engine: TrainingEngine) async {
        // codex whole-branch R3（high）：同一身份闸提前到入口——陈旧 engine（session 已终态收尾，
        // `activeEngine` 已变）即便 `reviewRecordId` 判活仍为真（例如已切到另一复盘 session），也不该
        // 去 cancel/drain **当前**活跃 session 的 `reviewAutosaveTask`，更不该继续往下写。
        guard activeEngine === engine, engine.flow.mode == .review, reviewRecordId != nil else { return }
        reviewAutosaveTask?.cancel()
        await reviewAutosaveTask?.value
        reviewAutosaveTask = nil
        do {
            try persistReviewWorkingIfChanged(engine: engine)
        } catch {
            recordAutosaveError(error)
        }
    }

    // MARK: - 私有构造 helper（E6a）

    /// A4：新局起始资金 = 权威 `settings.total_capital`（直读 DB，绕开缓存陈旧）。
    /// finalize/reset 已把累积资金写进该字段（单写者）→ 不再从记录累计重算。
    private func startingCapital() throws -> Double {
        try settingsDAO.loadSettings().totalCapital
    }

    /// D8：按 M0.1 schema 版本打开训练组（每次新 reader 实例，spec L1830）。
    private func openReader(for file: TrainingSetFile) throws -> TrainingSetReader {
        // M0.1 TRAINING_SET_SCHEMA_VERSION = 1（modules L1847/L2202）。E6a 硬编码避免与并行
        // 顺位 6 P2 PR 重复定义共享常量致编译冲突；shared-constant 单一 owner 见 PR body（residual E6a-R1）。
        try dbFactory.openAndVerify(file: file.localURL, expectedSchemaVersion: 1)
    }

    /// D3：从已校验 candle 取 maxTick = .m3 末根 endGlobalIndex（连续轴 = count-1）。
    /// .m3 缺/空 → 可恢复 .emptyData（make 也二次校验，但 FlowInput.normal/.replay 需先得 maxTick）。
    private func maxTick(from allCandles: [Period: [KLineCandle]]) throws -> Int {
        guard let m3 = allCandles[.m3], let last = m3.last else {
            throw AppError.trainingSet(.emptyData)
        }
        return last.endGlobalIndex
    }

    /// 按 filename 在缓存中定位训练组文件；缺失 → 可恢复 .fileNotFound。
    private func cachedFile(filename: String) throws -> TrainingSetFile {
        guard let file = cache.listAvailable().first(where: { $0.filename == filename }) else {
            throw AppError.trainingSet(.fileNotFound)
        }
        return file
    }

    /// D11 M0.4 边界：positionData 反序列化（唯一内部错误源）。损坏/被篡改存档的
    /// PositionManager.init(from:) 抛 DecodingError（§4.2.1 入口 2）→ 翻译为可恢复 .dbCorrupted。
    /// decode 必须在此私有 helper（M0.4 Gate 2：public 方法体禁 raw .decode）。
    private func decodePosition(_ data: Data) throws -> PositionManager {
        do {
            return try JSONDecoder().decode(PositionManager.self, from: data)
        } catch {
            throw AppError.persistence(.dbCorrupted)
        }
    }

    /// D6：最大回撤额(元，非负) → 记录用比率(负值，如 -0.12)。peak<=0 → 0。
    /// 注：v1.3 `DrawdownAccumulator` 改存绝对额并只留最终 peak，无法精确还原原 plan v1.5 L744-747
    /// 的逐时刻比率；以**最终 peakCapital** 为基准换算（标准定义 回撤额/峰值）。lossy 性见 residual E6b-R2。
    static func drawdownRatio(absolute: Double, peak: Double) -> Double {
        guard peak > 0 else { return 0 }
        return -(absolute / peak)
    }

    /// D7：训练组起始 Unix 秒(UTC) → 年/月，按北京时 UTC+8（与 CrosshairLayout 显示口径一致；后端 UTC 存储）。
    /// 28800 在 TimeZone 合法范围（±64800）→ 强解包永不 nil。
    static func startYearMonth(from startDatetime: Int64) -> (year: Int, month: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let comps = cal.dateComponents([.year, .month],
                                       from: Date(timeIntervalSince1970: TimeInterval(startDatetime)))
        return (comps.year ?? 0, comps.month ?? 0)
    }

    /// D9 M0.4 边界：PositionManager 序列化（saveProgress 唯一编码点）。in-memory 不变量保证 finite，
    /// encode 失败 = 内部 bug（非可恢复存档损坏）→ .internalError（与 decodePosition 的 .dbCorrupted 非对称有意）。
    private func encodePosition(_ position: PositionManager) throws -> Data {
        do {
            return try JSONEncoder().encode(position)
        } catch {
            throw AppError.internalError(module: "E6b", detail: "position encode failed: \(error)")
        }
    }

    /// 从交易流水重建 UI 标记（TradeMarker 非 Codable，不持久 → resume/review 由 ops 重建）。
    private func markers(from ops: [TradeOperation]) -> [TradeMarker] {
        ops.map { TradeMarker(globalTick: $0.globalTick, price: $0.price, direction: $0.direction) }
    }

    /// session 启动重置 autosave 栅栏/状态（D3）。
    private func resetAutosaveState() {
        terminating = false
        autosaveDirty = false
        ticksSinceAutosave = 0
        lastAutosaveError = nil
        autosaveBannerError = nil                    // §B.2：新 session 清 UI 信号（防御性冗余：D10 下 endSession 必先清，belt-and-suspenders）
        autosaveErrorGeneration = 0                  // codex-13a-F1：归零失败计数
    }

    /// 10b-D7（§4.7f）：训练组文件可弃损坏判据（dbFactory.openAndVerify 对坏文件抛的可恢复错误）。
    /// 仅在 openReader 调用栈内用 → 保证 app.sqlite source 永不命中（安全红线，§4.7f）。
    private func isCorruptTrainingSet(_ error: Error) -> Bool {
        switch error as? AppError {
        case .persistence(.dbCorrupted): return true
        case .trainingSet(.emptyData), .trainingSet(.versionMismatch),
             .trainingSet(.crcFailed), .trainingSet(.unzipFailed): return true
        default: return false                      // fileNotFound/diskFull/internalError 不删
        }
    }
}

// MARK: - Preview Fixture (spec line 1689-1700)

#if DEBUG
@MainActor
extension TrainingSessionCoordinator {
    public static func preview() -> TrainingSessionCoordinator {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        return TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(),
            recordRepo: records,
            pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: InMemorySessionFinalizationPort(records: records, pending: pending),
            settingsDAO: InMemorySettingsDAO(),
            cache: InMemoryCacheManager(),
            settings: SettingsStore.preview()
        )
    }
}
#endif

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
                    let appError = (error as? AppError)
                        ?? .internalError(module: "E6b", detail: "autosave: \(error)")
                    self.lastAutosaveError = appError
                    self.autosaveBannerError = appError             // §B.2：失败置 UI 信号（observable → toast）
                    self.autosaveErrorGeneration += 1               // codex-13a-F1：每次失败递增 → 重复同错也触发 onChange（持久故障保持可见）
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
    public func review(recordId: Int64) async throws -> TrainingEngine {
        let (record, ops, drawings) = try recordRepo.loadRecordBundle(id: recordId)
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
            // maxTick 由 .review(record) 内部据 record.finalTick 派生；make 亦校验 .m3 非空 +
            // m3.last.endGlobalIndex >= finalTick，故此处不重复 maxTick(from:)（D3 / LOW#8）。
            let allCandles = try reader.loadAllCandles()
            let meta = try reader.loadMeta()                  // B3：起始点 tick 派生（review 从训练起点重演）
            let startTick = TrainingEngine.startTick(forStartDatetime: meta.startDatetime, in: allCandles)
            let engine = try TrainingEngine.make(
                .review(record: record, startTick: startTick),
                allCandles: allCandles,
                initialCapital: record.totalCapital,
                initialCashBalance: record.totalCapital + record.profit,   // 末态全现金（强平后）
                initialMarkers: markers(from: ops),
                initialDrawings: drawings,
                initialTradeOperations: ops)
            activeReader = reader
            activeEngine = engine
            activeFile = file
            cache.touch(file)                        // §A touch-on-use：完整读取+引擎构造成功后刷 LRU mtime（codex-13a-F2）
            activeStartedAt = nil                    // D4：review 只读，无进度保存
            activeSessionKey = nil                   // RFC §4.7c：review 无 session key
            activeRecord = record                    // RFC-B D5：复用已加载 record（零新 I/O）
            return engine
        } catch {
            reader.close()
            throw (error as? AppError) ?? .internalError(module: "E6a", detail: String(describing: error))
        }
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
                drawings: engine.drawings,
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
            drawings: engine.drawings,
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

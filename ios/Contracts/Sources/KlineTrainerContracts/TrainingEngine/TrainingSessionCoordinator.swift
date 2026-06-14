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
    private let finalization: SessionFinalizationPort  // Wave 3 顺位 10a：单事务终结 port（RFC §4.7b）
    private let settingsDAO: SettingsDAO              // P4
    private let cache: CacheManager                   // P5
    private let settings: SettingsStore               // P6

    public private(set) var activeEngine: TrainingEngine?
    public private(set) var activeReader: (any TrainingSetReader)?

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

    // MARK: - Wave 3 顺位 10b：周期 autosave 状态机（RFC §4.6）+ 终态 fence（§4.7d）

    @ObservationIgnored private var autosaveTask: Task<Void, Never>?     // 在飞写句柄（fence drain）
    @ObservationIgnored private var autosaveDirty = false                // 写中又脏 → 写完再存一次
    @ObservationIgnored private var terminating = false                  // §4.7d 栅栏
    @ObservationIgnored private var ticksSinceAutosave = 0               // N-tick cadence 计数
    /// 可注入 cadence（@testable）。clamp 到 [1, AUTOSAVE_MAX_INTERVAL]：防 0/负间隔（每 tick 永真）+ 兑现 N≤MAX 不变量。
    @ObservationIgnored var autosaveTickInterval = AUTOSAVE_TICK_INTERVAL {
        didSet { autosaveTickInterval = min(max(autosaveTickInterval, 1), AUTOSAVE_MAX_INTERVAL) }
    }
    /// §4.6 失败可见：最近一次 autosave 失败（非阻塞指示；UI/@testable 读；不 teardown）。
    @ObservationIgnored public private(set) var lastAutosaveError: AppError?

    /// 请求 autosave（脏动作后调）。immediate=交易/画线/background flush（绕 N 节流）；
    /// 非 immediate=tick 推进（按 autosaveTickInterval 节流）。terminating/非 Normal → no-op（§4.7d/§4.6）。
    public func requestAutosave(engine: TrainingEngine, immediate: Bool) {
        guard !terminating, engine.flow.mode == .normal else { return }
        if !immediate {
            ticksSinceAutosave += 1
            guard ticksSinceAutosave >= autosaveTickInterval else { return }
        }
        ticksSinceAutosave = 0
        autosaveDirty = true
        guard autosaveTask == nil else { return }            // 已排程 → 合并
        autosaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.autosaveDirty && !self.terminating {
                self.autosaveDirty = false
                do {
                    try await self.saveProgress(engine: engine)
                    self.lastAutosaveError = nil
                } catch {
                    self.lastAutosaveError = (error as? AppError)
                        ?? .internalError(module: "E6b", detail: "autosave: \(error)")
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
    #endif

    public init(dbFactory: TrainingSetDBFactory,
                recordRepo: RecordRepository,
                pendingRepo: PendingTrainingRepository,
                finalization: SessionFinalizationPort,
                settingsDAO: SettingsDAO,
                cache: CacheManager,
                settings: SettingsStore) {
        self.dbFactory = dbFactory
        self.recordRepo = recordRepo
        self.pendingRepo = pendingRepo
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
        guard let file = cache.pickRandom() else {
            throw AppError.trainingSet(.fileNotFound)         // 无可用缓存训练组
        }
        let start = try startingCapital()                    // D4 累计模型（reader 未开，throw 无副作用）
        let reader = try openReader(for: file)
        do {
            let allCandles = try reader.loadAllCandles()
            let mt = try maxTick(from: allCandles)            // D3
            let engine = try TrainingEngine.make(
                .normal(fees: fees, maxTick: mt),
                allCandles: allCandles,
                initialCapital: start, initialCashBalance: start)
            activeReader = reader
            activeEngine = engine
            activeFile = file
            activeStartedAt = now()                 // D4：fresh Normal 局起始时间
            activeSessionKey = makeSessionKey()     // RFC §4.7c：fresh Normal 生成新 session key
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
        let file = try cachedFile(filename: pending.trainingSetFilename)
        let reader = try openReader(for: file)
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
            activeStartedAt = pending.startedAt      // D4：resume 保留原局起始时间
            activeSessionKey = pending.sessionKey    // RFC §4.7c：resume 恢复已存 session key
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
        let file = try cachedFile(filename: record.trainingSetFilename)
        let reader = try openReader(for: file)
        do {
            // maxTick 由 .review(record) 内部据 record.finalTick 派生；make 亦校验 .m3 非空 +
            // m3.last.endGlobalIndex >= finalTick，故此处不重复 maxTick(from:)（D3 / LOW#8）。
            let allCandles = try reader.loadAllCandles()
            let engine = try TrainingEngine.make(
                .review(record: record),
                allCandles: allCandles,
                initialCapital: record.totalCapital,
                initialCashBalance: record.totalCapital + record.profit,   // 末态全现金（强平后）
                initialMarkers: markers(from: ops),
                initialDrawings: drawings,
                initialTradeOperations: ops)
            activeReader = reader
            activeEngine = engine
            activeFile = file
            activeStartedAt = nil                    // D4：review 只读，无进度保存
            activeSessionKey = nil                   // RFC §4.7c：review 无 session key
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
        let file = try cachedFile(filename: record.trainingSetFilename)
        let reader = try openReader(for: file)
        do {
            let allCandles = try reader.loadAllCandles()
            let mt = try maxTick(from: allCandles)
            let engine = try TrainingEngine.make(
                .replay(fees: record.feeSnapshot, maxTick: mt),
                allCandles: allCandles,
                initialCapital: record.totalCapital,
                initialCashBalance: record.totalCapital)
            activeReader = reader
            activeEngine = engine
            activeFile = file
            activeStartedAt = nil                    // D4：replay 不入账，无进度保存
            activeSessionKey = nil                   // RFC §4.7c：replay 无 session key
            return engine
        } catch {
            reader.close()
            throw (error as? AppError) ?? .internalError(module: "E6a", detail: String(describing: error))
        }
    }

    /// 保存进度（spec L1659/L1677：U2 退出 / 每 N tick 自动调用）。仅 Normal 模式持久化
    /// （review 只读、replay 不入账 → 无 pending 语义，D3 no-op）。缺活跃上下文 → .internalError（D9）。
    public func saveProgress(engine: TrainingEngine) async throws {
        guard engine.flow.mode == .normal else { return }     // D3：仅 Normal 持久化
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
            cashBalance: engine.cashBalance,
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
        guard engine.flow.shouldSaveRecord() else { return nil }   // D2：Review/Replay 不入账
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
        let id = try finalization.finalizeSession(record: record,
                                                  ops: engine.tradeOperations,
                                                  drawings: engine.drawings,
                                                  sessionKey: key)
        return id
    }

    /// 非持久化 replay 结算 payload（RFC §4.4e）：replay 结束强平后，构造 in-memory `TrainingRecord`
    /// （复用类型）供顺位 8 SettlementView 呈现。**不持久化不变量**：不写 `training_records`、不触
    /// `pending_training`、不改 `finalize`（其对 replay 仍返 nil）。用**原局 FeeSnapshot**（replay 构造时
    /// 继承）+ 强平后终态。字段语义刻意镜像 `finalize`（D1 方案 A：totalCapital=起始资金；profit/收益率/
    /// 回撤比率/计数同口径），由 drift-guard 测试守；**有意不抽 finalize 共享 helper**，保 finalize 不在
    /// 本 PR diff 内（§4.7 finalize-gating residual 归顺位 10，不被本 PR 触碰）。
    /// 前置：replay 模式 + 活跃会话（caller=顺位 8 路由）。强平由 caller 先行（本方法只读终态）。
    public func replaySettlementPayload(engine: TrainingEngine) throws -> TrainingRecord {
        guard engine.flow.mode == .replay else {
            throw AppError.internalError(module: "E6b", detail: "replaySettlementPayload requires replay flow")
        }
        guard activeEngine === engine, let reader = activeReader, let file = activeFile else {
            throw AppError.internalError(module: "E6b", detail: "replaySettlementPayload without active session context")
        }
        let meta = try reader.loadMeta()
        let starting = engine.initialCapital
        let profit = engine.currentTotalCapital - starting
        let (year, month) = Self.startYearMonth(from: meta.startDatetime)
        return TrainingRecord(
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
    }

    /// session 结束清理（spec L1666/L1684，不 throws）：关闭 reader 并清空全部活跃上下文（D10）。
    public func endSession() async {
        terminating = true          // fence：阻止 teardown 后排队 autosave 复活 pending（§4.7d 同型）
        autosaveTask = nil
        autosaveDirty = false
        lastAutosaveError = nil
        ticksSinceAutosave = 0
        activeReader?.close()
        activeReader = nil
        activeEngine = nil
        activeFile = nil
        activeStartedAt = nil
        activeSessionKey = nil                       // RFC §4.7c：清空 session key
    }

    // MARK: - 私有构造 helper（E6a）

    /// D4：新局起始资金 = 累计模型。有记录 → 末条 total_capital+profit；无记录 → settings 配置本金。
    private func startingCapital() throws -> Double {
        let stats = try recordRepo.statistics()
        return stats.totalCount > 0 ? stats.currentCapital : settings.settings.totalCapital
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
            finalization: InMemorySessionFinalizationPort(records: records, pending: pending),
            settingsDAO: InMemorySettingsDAO(),
            cache: InMemoryCacheManager(),
            settings: SettingsStore.preview()
        )
    }
}
#endif

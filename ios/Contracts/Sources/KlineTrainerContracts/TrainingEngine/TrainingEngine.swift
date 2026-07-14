// Kline Trainer Swift Contracts — E5a TrainingEngine 核心（Wave 2 顺位 2）
// Spec: kline_trainer_modules_v1.4.md §E5 (L1581-1639, preview L1690-1705)
//     + kline_trainer_plan_v1.5.md §4.2/§10.1（最大回撤、现价、初始周期组合 L777）
// 范围（E5a 顺位 2）：init + 运行时状态 + accessors + onSceneActivated（scenePhase 中继）+ preview。
// E5b（顺位 3，本文件后半）：buy/sell/holdOrObserve/switchPeriodCombo + buyEnabled/sellEnabled
//   + 局终自动强平（§4.2.1 入口 1b）。
//   activateDrawingTool/deleteDrawing 延后 Wave 2 顺位 7 C8（画线激活编排需 C8 viewport，用户 2026-06-06 裁决）。
// 设计判定见 docs/superpowers/plans/2026-06-05-pr-e5a-trainingengine-core.md（E5a）
//   + docs/superpowers/plans/2026-06-06-pr-e5b-trainingengine-actions.md（E5b D1-D9）。

#if canImport(Observation)
import Observation
#endif
import CoreGraphics

@MainActor
@Observable
public final class TrainingEngine {
    // 运行时状态（对外只读；写入留给 E5b 动作 PR）
    public private(set) var tick: TickEngine
    public private(set) var position: PositionManager
    public private(set) var cashBalance: Double
    public private(set) var drawdown: DrawdownAccumulator
    public private(set) var markers: [TradeMarker]
    public private(set) var drawings: [DrawingObject]
    /// P1a Task 12（Z1）：加载来的完整有损画线集（含 unknownRaw 原始字节）。`drawings` 是其已知投影
    /// （`loadedDrawingsLossy.drawings`）。coordinator save 路径经 `loadedDrawingsLossy.reconciled(currentKnown:)`
    /// 重发，使加载 blob 里未识别（未来版本）的条穿过 autosave/resume-save/commit 全路径存活。
    public private(set) var loadedDrawingsLossy = LossyDrawingArray(elements: [])
    /// review-redesign Task 5 最小 shim + **Task 10 落地**：复盘 session 的工作画线集，供 coordinator
    /// 持久化净改动判定（`ReviewNetChange.changed(working: engine.reviewDrawings, committed:)`）读取，
    /// 也是复盘新画线的唯一写入面——`appendReviewDrawing`/`removeReviewDrawing`；`ChartContainerView`
    /// commit 路径经 `routeDrawingCommit` 按 `flow.mode == .review` 路由至此，不污染 committed `drawings`
    /// （committed `drawings` 在 review 中只读）。
    public private(set) var reviewDrawings: [DrawingObject] = []
    /// P1a Task 12（Z1）：复盘加载来的完整有损画线集（同 `loadedDrawingsLossy`，复盘侧）；`reviewDrawings`
    /// 是其已知投影。
    public private(set) var loadedReviewLossy = LossyDrawingArray(elements: [])
    /// P1a Task 12（Z1）：复盘加载来的隐藏原训练线 id 集（§11.5/D12）。save 路径原样传回，
    /// 不得被默认 `[]` 覆盖已加载的隐藏态（codex R11-high）。P1a 只透传，hide/show 写入行为 = P5。
    public private(set) var loadedReviewHiddenIds: [DrawingID] = []
    /// codex WB R7 finding 1：复盘加载来的 wrapper 顶层未知 key（原样字节，同 `loadedReviewHiddenIds`
    /// 范式）。save 路径原样传回、原样拼回磁盘，不得被默认 `[]` 覆盖已加载的未来数据。
    public private(set) var loadedReviewUnknownTopLevel: [ReviewArchiveWrapper.UnknownTopLevelEntry] = []
    /// P1b-1a-ii D39：画线共享状态容器 —— 画线模式 / 工具 / pending 锚的**唯一真相**。
    /// 浮动钮（本期）与底栏画线工具栏（1a-iii）**共同消费**同一个实例；Coordinator 只读不存。
    /// **不变量**：`drawingSession.drawingModeActive == true` ⇔ 上下两面板 `interactionMode` 均为 `.drawing`
    /// （由 `beginDrawingSession` / `endDrawingSessionIfActive` 两个收口点维持，见 D45）。
    /// 会话是**局内瞬态**，不持久化；每局 `TrainingEngine.make` 新建 → 不会跨局泄漏。
    public let drawingSession = DrawingSession()
    public private(set) var upperPanel: PanelViewState
    public private(set) var lowerPanel: PanelViewState
    public private(set) var tradeOperations: [TradeOperation]

    // 构造后不变量
    public let flow: TrainingFlowController
    public let allCandles: [Period: [KLineCandle]]
    public let fees: FeeSnapshot
    public let initialCapital: Double

    private let animators: (upper: DecelerationAnimator, lower: DecelerationAnimator)

    /// C8b：渲染路径缓存的最近 bounds（按面板）。`activateDrawingTool` 算 candleRange 复用
    /// （spec `activateDrawingTool` 签名无 bounds 参数 → 缓存，D1）。`@ObservationIgnored`：
    /// 渲染层 `recordRenderBounds` 写入不得触发观察重建（否则 updateUIView 写 → 重渲染循环）。
    @ObservationIgnored private var lastRenderedBounds: (upper: CGRect, lower: CGRect) = (.zero, .zero)

    /// 顺位 3 pinch per-gesture 状态（设计 D6）：`.began` 捕获（base visibleCount, scaleAtBegan）；
    /// `.ended/.cancelled` 清空。scaleAtBegan 用于锁定点归一（D4，消 ±2% 死区）。
    @ObservationIgnored private var pinchBase:
        (upper: (base: Int, scaleAtBegan: CGFloat)?, lower: (base: Int, scaleAtBegan: CGFloat)?) = (nil, nil)

    /// R1b-wire（D9/D10）：进行中减速/bounce 的 numeric 边界 + 是否允许 overscroll（bounce=true/decel=false）。
    /// onUpdate 据此 floor（bounce 放最老边 overscroll）或 full（decel 硬停两边）clamp；interruptDeceleration 归一用。
    /// `@ObservationIgnored`：纯 numeric（无像素，D1）；endPan 写入不得触发观察重建（同 lastRenderedBounds）。
    struct ActiveDecel: Equatable, Sendable {
        let bounds: RenderStateBuilder.OffsetBounds
        let allowOverscroll: Bool
    }
    @ObservationIgnored private var activeBounds: (upper: ActiveDecel?, lower: ActiveDecel?) = (nil, nil)

    /// R1b-drag（D1）：单指 drag 期**未阻尼累计意图位移**（raw）。`beginPan` seed=归一后 offset；
    /// `applyPanOffset` 累加；`endPan`/`cancelPan` 清 nil；`recordRenderBounds` resize 时重同步（E5）。
    /// `@ObservationIgnored`：纯 numeric（同 activeBounds 模式）。
    @ObservationIgnored private var dragRaw: (upper: CGFloat?, lower: CGFloat?) = (nil, nil)

    /// 构造运行时引擎（D9 校验边界契约）。
    ///
    /// **`allCandles` 必须是已校验数据。** 训练组数据的「可恢复」校验（空 `[:]` / 缺 `.m3` /
    /// `c.period != key` / `.m3` 未覆盖 `maxTick`）是 **reader 层**的职责：`TrainingSetReader.read()`
    /// 与 `DefaultTrainingSetDataVerifier` 已对损坏/空数据抛 `AppError.trainingSet`，在 E6 构造本引擎
    /// **之前**就把可恢复错误呈现给用户。E6（顺位 4/5）必须只用 reader-已校验的 candle 构造引擎，
    /// 并 **重新校验**（而非信任）P5 缓存数据。
    ///
    /// 因此下方 `precondition`/`preconditionFailure` 是**末线不变量执行**：触发即表示 E6/调用方
    /// 违反「传入已校验数据」契约（程序 bug），与 `NormalFlow` 的 trap-on-caller-bug 同风格——
    /// 不是可恢复的运行时数据错误，故不 `throws`（spec init 非 throwing，modules L1607-1616）。
    ///
    /// **access = internal（final-R7-F1）：** `make` 是唯一 **public** 构造路径（校验全部数据派生不变量
    /// 并抛可恢复 `AppError`）。`init` 退为 internal trust-boundary（仅 `make`/`preview`/E6/`@testable` 测试
    /// 在模块内调用），杜绝「两条 public 路径、不同不变量」——外部无法绕过 `make` 造出 render-崩溃引擎。
    /// spec（modules L1591/1607）的 `init` 本就无 `public`，本改与之一致。
    init(flow: TrainingFlowController,
                allCandles: [Period: [KLineCandle]],
                maxTick: Int,
                initialTick: Int? = nil,                       // R6-F1 resume：PendingTraining.globalTickIndex；nil→flow.initialTick
                initialCapital: Double,
                initialCashBalance: Double,
                initialPosition: PositionManager = .init(),
                initialMarkers: [TradeMarker] = [],
                initialDrawings: [DrawingObject] = [],
                initialDrawingsLossy: LossyDrawingArray? = nil,   // P1a Task 12（Z1）：加载来的完整有损集；nil=纯 initialDrawings 包装
                initialTradeOperations: [TradeOperation] = [],
                initialDrawdown: DrawdownAccumulator = .initial,
                initialUpperPeriod: Period = .m60,             // 默认上区 60m（plan v1.5 L777）；resume 传 PendingTraining.upperPeriod
                initialLowerPeriod: Period = .daily,            // 默认下区 日线；resume 传 PendingTraining.lowerPeriod
                decelerationDriverFactory: @escaping (@escaping @MainActor (CGFloat) -> Bool) -> FrameDriving =
                    { onTick in RealFrameDriver(onTick: onTick) }) {   // C8b/D5：可注入减速帧驱动（默认真实）
        // 前置不变量（NormalFlow 同风格：trap 调用方 bug，不防御 clamp）
        precondition(maxTick >= 0, "maxTick must be >= 0")
        // R4-F1：fail-fast flow/maxTick 契约，杜绝 TickEngine 静默 clamp 掩盖 record/训练组版本错位。
        precondition(flow.allowedTickRange.upperBound == maxTick,
                     "flow.allowedTickRange.upperBound (\(flow.allowedTickRange.upperBound)) must equal maxTick (\(maxTick))")
        let startTick = initialTick ?? flow.initialTick   // R6-F1：resume 传入则用之，否则 flow.initialTick
        precondition(flow.allowedTickRange.contains(startTick),
                     "resolved initialTick (\(startTick)) must be within allowedTickRange \(flow.allowedTickRange)")
        // R4-F2：.m3 是规范驱动周期（reader 不变量：非空数据必含 .m3）；现价只来自 .m3。
        guard let m3 = allCandles[.m3], !m3.isEmpty else {
            preconditionFailure("allCandles must contain a non-empty .m3 driving series")
        }
        // R6-F2：.m3 必须覆盖到 maxTick（否则越界 tick 被 price clamp 成陈旧价）。
        // 用 >= 而非 ==：review 模式 m3 为训练组全集，末根 endGlobalIndex 可 > finalTick(=maxTick)。
        precondition(m3.last!.endGlobalIndex >= maxTick,
                     ".m3 末根 endGlobalIndex (\(m3.last!.endGlobalIndex)) must be >= maxTick (\(maxTick))")
        // final-R5-F1：.m3 轴连续从 0（currentPrice 二分依赖）末线不变量。
        precondition(TrainingEngine.isContiguousM3Axis(m3),
                     ".m3 global tick axis must be contiguous from 0 (globalIndex==endGlobalIndex==index)")
        // final-R4-F2 + R9-F1：钱字段 finite + 非负末线不变量（与 make() 同强度；make 已对数据派生失败抛
        // 可恢复 AppError；直调 init = trust-boundary，非 finite/负值视为调用方 bug）。
        precondition(initialCapital.isFinite && initialCapital >= 0
                     && initialCashBalance.isFinite && initialCashBalance >= 0
                     && initialDrawdown.peakCapital.isFinite && initialDrawdown.peakCapital >= 0
                     && initialDrawdown.maxDrawdown.isFinite && initialDrawdown.maxDrawdown >= 0,
                     "money fields (capital/cash/drawdown) must be finite and non-negative")

        self.flow = flow
        self.allCandles = allCandles
        self.fees = flow.feeSnapshot                 // D1
        self.initialCapital = initialCapital

        self.tick = TickEngine(maxTick: maxTick, initialTick: startTick)  // D5（前置已保证 startTick 在范围内，无 clamp）
        self.position = initialPosition
        self.cashBalance = initialCashBalance
        // D3：drawdown seeding（peak = 起始总资金，modules L1604）+ 用 update 把「当前回撤」并入
        // maxDrawdown，避免低报（codex R2-F1 + R5-F1）。fresh 局 dd=0；resume 局当前回撤 > 携带值时纠正。
        let startPrice = TrainingEngine.price(in: allCandles, atTick: startTick)
        let startTotal = initialCashBalance + Double(initialPosition.shares) * startPrice
        var seededDrawdown = DrawdownAccumulator(
            peakCapital: max(initialDrawdown.peakCapital, initialCapital, startTotal),   // R6-F3：含声明基线 initialCapital
            maxDrawdown: initialDrawdown.maxDrawdown)
        seededDrawdown.update(currentCapital: startTotal)   // peak>startTotal 时把当前回撤并入 maxDrawdown
        self.drawdown = seededDrawdown
        self.markers = initialMarkers
        // P1a Task 12（Z1）：`loadedDrawingsLossy` = 携带的完整有损集（含 unknownRaw）；`drawings` 是其已知投影。
        // 用局部变量而非读回 `self.loadedDrawingsLossy`（@Observable 宏访问器需 self 全初始化后才可读）。
        // `try!`（codex whole-branch High fix，`encodeKnown` 现在 throws）：本 init 是 spec 规定的
        // trust-boundary（非 throwing，L88 上方注释——不可恢复的运行时数据错误不在此 throw，同风格
        // trap）。`initialDrawings` 此处恒为 `make()` 默认空数组或已解码（finite 保证）数据；此分支只在
        // `initialDrawingsLossy == nil` 时求值，生产 3 处调用点均传了非 nil `initialDrawingsLossy`
        // （resume/review 均走 DB 解码后的 lossy），故此路径实际不可能非有限值触发。
        let seededLossy = initialDrawingsLossy ?? (try! LossyDrawingArray(drawings: initialDrawings))
        self.loadedDrawingsLossy = seededLossy
        self.drawings = seededLossy.drawings
        self.tradeOperations = initialTradeOperations

        // D7：初始周期组合默认 上区 60m / 下区 日线（plan v1.5 L777）；resume 传入保存的组合（R6）。
        // visibleCount seed 80（顺位 3 D5；zoom ephemeral 不持久，resume 重建恒 80）。
        self.upperPanel = PanelViewState(period: initialUpperPeriod, interactionMode: .autoTracking,
                                         visibleCount: RenderStateBuilder.defaultVisibleCount,
                                         offset: 0, revision: 0)
        self.lowerPanel = PanelViewState(period: initialLowerPeriod, interactionMode: .autoTracking,
                                         visibleCount: RenderStateBuilder.defaultVisibleCount,
                                         offset: 0, revision: 0)

        self.animators = (
            upper: DecelerationAnimator(makeDriver: decelerationDriverFactory),
            lower: DecelerationAnimator(makeDriver: decelerationDriverFactory))
        // C8b：减速每帧 delta 必经 reducer offsetApplied（spec §C2 闸门 #2 F2，禁直写 offset）。
        // self 此时已全初始化（animators 为最后一个无默认值的存储属性；lastRenderedBounds 有默认值）。
        // R1b-wire（D9）：减速/bounce 每帧 delta 经 floor-or-full clamp（bounce floor 放 overscroll / decel full 硬停）。
        self.animators.upper.onUpdate = { [weak self] delta in self?.floorOrFullClampedOffsetDelta(delta, panel: .upper) }
        self.animators.lower.onUpdate = { [weak self] delta in self?.floorOrFullClampedOffsetDelta(delta, panel: .lower) }
    }

    /// `make` 的构造输入：工厂内部据此**先验 maxTick 再建 flow**，杜绝外部传入会 trap 的非法 flow——
    /// NormalFlow/ReplayFlow 的 `0...maxTick` 在 maxTick<0 时一读即 trap，而协议不暴露原始 maxTick，
    /// 无法不 trap 地预判（codex final-R8-F1）。maxTick 由此输入单一派生，结构上无 flow/maxTick 错位。
    public enum FlowInput {
        case normal(fees: FeeSnapshot, maxTick: Int)
        case review(record: TrainingRecord, startTick: Int)
        case replay(fees: FeeSnapshot, maxTick: Int)
    }

    /// E6 推荐的**可恢复**、**唯一 public** 构造路径（D9 / Stage6 codex final-F1/R7/R8）。
    ///
    /// 所有**数据派生**输入（FlowInput 的 maxTick/record + candle + resume `startTick` + 钱 + 面板）都来自
    /// reader/cache/PendingTraining 边界，可能空/陈旧/损坏。本工厂**内部建 flow（先验 maxTick）**并逐项
    /// 校验，失败抛 `AppError.trainingSet(.emptyData)`（`isRecoverable==true`，由 UI 呈现），而非让 `init`
    /// 末线 `precondition` 把数据错误变进程 trap。E6（顺位 4/5）经此构造 + 对 P5 缓存数据**重新校验**。
    public static func make(
        _ input: FlowInput,
        allCandles: [Period: [KLineCandle]],
        initialTick: Int? = nil,
        initialCapital: Double,
        initialCashBalance: Double,
        initialPosition: PositionManager = .init(),
        initialMarkers: [TradeMarker] = [],
        initialDrawings: [DrawingObject] = [],
        initialDrawingsLossy: LossyDrawingArray? = nil,   // P1a Task 12（Z1）：加载来的完整有损集
        initialTradeOperations: [TradeOperation] = [],
        initialDrawdown: DrawdownAccumulator = .initial,
        initialUpperPeriod: Period = .m60,
        initialLowerPeriod: Period = .daily
    ) throws -> TrainingEngine {
        // 内部建 flow，先验 maxTick>=0 —— 杜绝外部非法 flow 在读 allowedTickRange 时 trap（final-R8-F1）。
        let maxTick: Int
        let flow: TrainingFlowController
        switch input {
        case .normal(let fees, let mt):
            guard mt >= 0 else { throw AppError.trainingSet(.emptyData) }   // 损坏 maxTick
            maxTick = mt; flow = NormalFlow(fees: fees, maxTick: mt)
        case .replay(let fees, let mt):
            guard mt >= 0 else { throw AppError.trainingSet(.emptyData) }
            maxTick = mt; flow = ReplayFlow(feeSnapshotFromOriginal: fees, maxTick: mt)
        case .review(let record, let startTick):
            // codex plan-R3-F3：startTick 越界（损坏 record/metadata）→ 可恢复 trainingSet 错误，非 ClosedRange trap
            guard startTick >= 0, record.finalTick >= startTick else {
                throw AppError.trainingSet(.emptyData)
            }
            maxTick = record.finalTick
            flow = ReviewFlow(record: record, startTick: startTick)
        }
        // flow 由 validated maxTick 建成 → allowedTickRange 安全、无 flow/maxTick 错位（R4-F1 由构造保证）。
        // final-R9-F2：佣金率 finite + 非负——负率 + 免5关闭会让 TradeCalculator 算出负佣金/虚增购买力。
        // 统一查 flow.feeSnapshot（normal/replay 来自 input fees、review 来自 record.feeSnapshot）。
        guard flow.feeSnapshot.commissionRate.isFinite, flow.feeSnapshot.commissionRate >= 0 else {
            throw AppError.trainingSet(.emptyData)
        }
        guard let m3 = allCandles[.m3], !m3.isEmpty else {
            throw AppError.trainingSet(.emptyData)            // 空 / 缺 .m3 驱动序列
        }
        guard let last = m3.last, last.endGlobalIndex >= maxTick else {
            throw AppError.trainingSet(.emptyData)            // .m3 未覆盖 maxTick（版本/数据残缺）
        }
        let startTick = initialTick ?? flow.initialTick
        guard flow.allowedTickRange.contains(startTick) else {
            throw AppError.trainingSet(.emptyData)            // 陈旧 resume tick 超出范围（训练组被替换）
        }
        // .m3 全局 tick 轴必须连续从 0（第 i 根 globalIndex==endGlobalIndex==i）——`currentPrice` 二分
        // （取首个 endGlobalIndex>=tick）直接依赖此轴：有 gap（如 [0,10]）会把 tick 1..9 定到未来 candle
        // 污染总资金/收益率/回撤（codex final-R4/R5-F1）。这是 E5a 自己代码依赖的轴不变量。
        // 更深的内容校验（OHLC 有限 / 30 根 warmup）属 reader 绑定的 TrainingSetDataVerifying，
        // 由 E6 构造前调用（其 verifyNonEmpty(reader:) 取 reader 非内存 dict，无法在此复用）。
        guard TrainingEngine.isContiguousM3Axis(m3) else {
            throw AppError.trainingSet(.emptyData)            // .m3 轴非连续（gap / 乱序 / period 错）
        }
        guard TrainingEngine.isStrictlyIncreasingM3Datetime(m3) else {
            throw AppError.trainingSet(.emptyData)            // .m3 datetime 非严格递增（损坏 / 非 GRDB 源）
        }
        // 钱字段 finite + 非负——`startTotal`/`currentTotalCapital`/`returnRate`/drawdown 数学的前置；
        // resume 状态可能 NaN/Inf 污染（codex final-R4-F2）。
        guard initialCapital.isFinite, initialCapital >= 0,
              initialCashBalance.isFinite, initialCashBalance >= 0,
              initialDrawdown.peakCapital.isFinite, initialDrawdown.peakCapital >= 0,
              initialDrawdown.maxDrawdown.isFinite, initialDrawdown.maxDrawdown >= 0 else {
            throw AppError.trainingSet(.emptyData)
        }
        // final-R6-F1：两个面板周期必须有非空 candle 数据——`buildRenderState` 读 `allCandles[panel.period]!`
        // （modules L1441 强解包），缺数据会崩。E5a 自身「面板↔candle」状态一致性。
        guard let up = allCandles[initialUpperPeriod], !up.isEmpty,
              let low = allCandles[initialLowerPeriod], !low.isEmpty else {
            throw AppError.trainingSet(.emptyData)            // 面板周期无 candle 数据
        }
        return TrainingEngine(
            flow: flow, allCandles: allCandles, maxTick: maxTick, initialTick: initialTick,
            initialCapital: initialCapital, initialCashBalance: initialCashBalance,
            initialPosition: initialPosition, initialMarkers: initialMarkers,
            initialDrawings: initialDrawings, initialDrawingsLossy: initialDrawingsLossy,
            initialTradeOperations: initialTradeOperations,
            initialDrawdown: initialDrawdown,
            initialUpperPeriod: initialUpperPeriod, initialLowerPeriod: initialLowerPeriod)
    }

    // MARK: - 派生 accessor（只读纯值计算属性；买卖可用门见 E5b / D4）

    /// 现价：`tick.globalTickIndex` 处的 `markPrice`（D2 / codex R4-F2）。
    public var currentPrice: Double {
        markPrice(atTick: tick.globalTickIndex)
    }

    /// review-redesign Task 6：复盘引擎播种 `reviewDrawings`（committed 基线 或 resume 的 working 画线集）
    /// 的生产入口（由 coordinator `buildReviewEngine` 调用）。Task 5 的 `setReviewDrawingsForTesting`
    /// 仅 DEBUG 测试专用，本方法是唯一生产路径。Task 10 补真实画线路由（appendReviewDrawing 等）后仍保留
    /// 本 setter 作初始播种入口。**P1a Task 12（Z1）**：携带完整有损集 + 加载来的隐藏 id 集（`hiddenIds`），
    /// 使 save 路径（`persistReviewWorkingIfChanged`/`commitReview`）能经 `loadedReviewLossy.reconciled(currentKnown:)`
    /// 重发，保住加载 blob 里未识别的条 + 原样传回 hiddenIds（不覆盖成 `[]`，codex R11-high）。
    public func setReviewLossy(_ l: LossyDrawingArray, hiddenIds: [DrawingID] = [],
                               unknownTopLevel: [ReviewArchiveWrapper.UnknownTopLevelEntry] = []) {
        loadedReviewLossy = l
        loadedReviewHiddenIds = hiddenIds
        loadedReviewUnknownTopLevel = unknownTopLevel
        reviewDrawings = l.drawings
    }
    /// 兼容旧调用（纯已知，无 unknownRaw/hiddenIds）：包成 lossy 走 `setReviewLossy` 唯一实现。
    public func setReviewDrawings(_ ds: [DrawingObject]) throws { setReviewLossy(try LossyDrawingArray(drawings: ds)) }

    /// 规范 mark price（Task 9 收口）：global tick `t` 处 `.m3` 收盘价，越界 clamp 到端根、非 nil。
    /// `currentPrice`／`ReviewLedger.state` 的 `markPriceAtTick`／finalize 三处共用同一入口，杜绝重复实现漂移。
    public func markPrice(atTick t: Int) -> Double {
        TrainingEngine.price(in: allCandles, atTick: t)
    }

    /// 本局实时总资金 = 现金 + 持仓市值（plan v1.5 L914）。
    public var currentTotalCapital: Double {
        cashBalance + Double(position.shares) * currentPrice
    }

    /// 持仓成本（plan v1.5 L909）。
    public var holdingCost: Double { position.holdingCost }

    /// 本局至今净收益率（plan v1.5 L917）。
    public var returnRate: Double {
        initialCapital == 0 ? 0 : (currentTotalCapital - initialCapital) / initialCapital
    }

    /// 最大回撤：透传 accumulator —— **非负绝对额，单位元**，运行时形态（modules L510/L1636）。
    /// 注意：`TrainingRecord.maxDrawdown` 是比率（如 -0.12），由 E6 finalize 换算（modules L537-538，D3）；
    /// 本 accessor 不做换算，调用方勿当比率使用。
    public var maxDrawdown: Double { drawdown.maxDrawdown }

    /// 当前持仓档位 X/5（0...5），read-only computed（RFC §4.4b / §4.1）。
    /// 基准 = 持仓市值 / 当前总资金（与顶栏「总资金 = 现金 + 持仓市值」同口径，plan v1.5 L914），
    /// round（四舍五入）非 floor（反映用户意图档位）。**派生非状态**：每次从 live 状态算
    /// （buy 以总资金、sell 以持仓为基准，无单一持久 tier 字段）。顺位 7 顶栏「仓位 X/5」显示。
    /// **非有限守卫（codex plan R1）**：`shares × price` 在极端有限价下可溢出至 inf → `inf/inf=NaN`，
    /// `Int(NaN)` 会 trap 崩溃。`total > 0` 不挡 `+inf`（inf>0 为真），故须显式 `isFinite` 守卫
    /// （与 `forceCloseOnEnd` 的 `price.isFinite`、init 的 finite money 前置同风格）→ 退化 0/5 不崩。
    public var currentPositionTier: Int {
        let holdingValue = Double(position.shares) * currentPrice
        let total = currentTotalCapital
        guard total > 0, total.isFinite, holdingValue.isFinite else { return 0 }
        // 此处 holdingValue 有限、total 有限且 >0 → ratio 有限、×5 有限、rounded 有限 → Int 安全。
        let raw = (holdingValue / total * 5).rounded(.toNearestOrAwayFromZero)
        return min(max(Int(raw), 0), 5)
    }

    // MARK: - 动作可用性门（E5b / D1）

    /// 买入按钮可用：当前模式允许交易 **且** fee-aware 至少能买 1 手（RFC-A D3）。
    public var buyEnabled: Bool {
        guard flow.canBuySell() else { return false }
        // RFC-A：能买至少 1 手即使能（fee-aware）。
        return TradeCalculator.maxBuyableShares(cash: cashBalance, price: currentPrice, fees: fees)
            >= TradeCalculator.shareLotSize
    }

    /// 卖出按钮可用：当前模式允许交易 **且** 有持仓（plan v1.5 L733 空仓灰置）。
    public var sellEnabled: Bool {
        flow.canBuySell() && position.shares > 0
    }

    // MARK: - 周期组合切换（E5b / D8）

    /// 完整组合序列（plan v1.5 L782）：3m/15m ←→ 15m/60m ←→ 60m/日 ←→ 日/周 ←→ 周/月。
    /// upper=较细、lower=较粗，整体随 direction 平移一档。
    private static let periodCombos: [(upper: Period, lower: Period)] = [
        (.m3, .m15), (.m15, .m60), (.m60, .daily), (.daily, .weekly), (.weekly, .monthly)
    ]

    /// 两指上下滑切换周期组合（plan v1.5 §4.4）。
    /// - 边界 / 当前组合不在序列(损坏 resume) / target 周期无数据 → no-op（不 advance、不 bump）。
    /// - 命中 → 改双面板 period + 对两面板派发 `.periodComboSwitched`（硬切 autoTracking + clearPendingDrawing；
    ///   后者 effect 在 E5b 无消费者，画线延后顺位 7，故无 pending 可清，忽略安全）。
    public func switchPeriodCombo(direction: PeriodDirection) {
        // P1b-1a-ii：画线会话开着时切周期 = **no-op**（fail-closed，codex plan-R7-high）。
        // 为什么不是「结束会话」也不是「丢 pending」：
        //   · `.periodComboSwitched` 会把两面板硬切 `.autoTracking`（Reducer:152-155）→ 若放行，会话还开着
        //     而面板已 autoTracking = 本期要消灭的漂移；且 pending 锚会绑在一个刚变过的周期组合上。
        //   · 但「周期改变 → 丢 pending」是 spec §3.2 **明确划给 1a-iv（D32）** 的语义，且必须用
        //     `discardPendingAnchors()`（保工具）而非整场取消 —— 本期不得提前实现。
        //   · 故本期取**最小且不可漂移**的一档：画线时干脆不换周期。这与手势层现状**完全一致**——
        //     `singlePanStep(drawingTakesOver:)` 的每个 return 都 `periodSwipe: nil`
        //     （GestureClassifiers.swift:113-121），两指切周期未接线 → 真实用户本来就切不动。
        //     守卫只是把「碰巧不可达」升级成「**结构上不可能**」（直接调也漂不了）。
        // 1a-iv 落 D32 时**删掉这条守卫**，改按 D31 用 discardPendingAnchors() + 维护会话不变量。
        guard !drawingSession.drawingModeActive else { return }
        let combos = TrainingEngine.periodCombos
        guard let cur = combos.firstIndex(where: {
            $0.upper == upperPanel.period && $0.lower == lowerPanel.period
        }) else { return }   // 当前组合不在序列（损坏 resume 数据）→ no-op
        let target = direction == .toLarger ? cur + 1 : cur - 1
        guard combos.indices.contains(target) else { return }   // 边界 → no-op
        let next = combos[target]
        // D8 数据完整性守卫：避免后续 stepsForPeriod/渲染落在无数据周期
        guard let u = allCandles[next.upper], !u.isEmpty,
              let l = allCandles[next.lower], !l.isEmpty else { return }
        stopAllDeceleration()                       // D7
        upperPanel.period = next.upper
        lowerPanel.period = next.lower
        _ = upperPanel.reduce(.periodComboSwitched)
        _ = lowerPanel.reduce(.periodComboSwitched)
        resetOffsetAfterAutoTracking(.upper)        // D8
        resetOffsetAfterAutoTracking(.lower)
    }

    // MARK: - 持有 / 观察（E5b）

    /// 持有(有仓)/观察(空仓)：仅推进 tick（plan v1.5 L944「直接推进 1 根当前周期 K 线」），
    /// 无成交、无 marker/operation。review 现 canAdvance()==true（新需求10 复盘可步进），
    /// advanceAndAccount 在 review 下无成交、无 forceClose（capability matrix L836）。
    public func holdOrObserve(panel: PanelId) {
        guard flow.canAdvance() else { return }
        advanceAndAccount(panel: panel)
    }

    // MARK: - 新需求10：复盘步进（B2）

    /// 复盘「快进到结尾」。仅 canJumpToEnd()（Review）生效；设 tick=maxTick + 镜头吸附 autoTracking。
    /// 无成交、无 marker；无 forceClose（复盘无持仓）。K线/标记随 currentIdx 自动全揭示。
    public func jumpToEnd() {
        guard flow.canJumpToEnd() else { return }
        stopAllDeceleration()
        tick.reset(to: tick.maxTick)
        _ = upperPanel.reduce(.tradeTriggered)
        _ = lowerPanel.reduce(.tradeTriggered)
        resetOffsetAfterAutoTracking(.upper)
        resetOffsetAfterAutoTracking(.lower)
        endDrawingSessionIfActive()      // D45
        drawdown.update(currentCapital: currentTotalCapital)
    }

    /// 复盘「下一根」逐根推进。**按两 panel 中更细（stepsForPeriod 更小的正数步）的周期步进**，
    /// 而非 activePanel（复盘隐藏了周期选择条，activePanel 停在默认 .lower=粗周期会一击跳一整天）。
    /// 复用 holdOrObserve（canAdvance 门控 + 只读无成交）。用户可单指竖滑切周期组合改粒度。
    /// 耗尽面板（stepsForPeriod==0）绝不被选中（codex whole-branch R2-F2）：若一方耗尽则选另一方；
    /// 皆耗尽时（已到结尾）no-op。
    public func stepReviewForward() {
        let upperSteps = stepsForPeriod(upperPanel.period)
        let lowerSteps = stepsForPeriod(lowerPanel.period)
        let panel: PanelId
        if upperSteps > 0 && lowerSteps > 0 {
            panel = upperSteps <= lowerSteps ? .upper : .lower   // 皆可推进 → 选更细
        } else if upperSteps > 0 {
            panel = .upper                                        // 仅 upper 能推进
        } else if lowerSteps > 0 {
            panel = .lower                                        // 仅 lower 能推进
        } else {
            return                                                // 皆耗尽=到结尾，no-op
        }
        holdOrObserve(panel: panel)
    }

    /// 复盘按指定面板步进一根（红框所选周期）。该面板已到末尾则步进另一面板；皆耗尽=到结尾 no-op。
    public func stepReviewForward(panel requested: PanelId) {
        let requestedSteps = stepsForPeriod(requested == .upper ? upperPanel.period : lowerPanel.period)
        if requestedSteps > 0 {
            holdOrObserve(panel: requested); return
        }
        let other: PanelId = requested == .upper ? .lower : .upper
        let otherSteps = stepsForPeriod(other == .upper ? upperPanel.period : lowerPanel.period)
        if otherSteps > 0 { holdOrObserve(panel: other) }   // 所选耗尽 → 用另一面板；皆耗尽 → no-op
    }

    // MARK: - 私有：步进 + 联动 + 记账（buy/sell/holdOrObserve 共用）

    /// 被点击面板对应的周期。
    private func period(of panel: PanelId) -> Period {
        switch panel {
        case .upper: return upperPanel.period
        case .lower: return lowerPanel.period
        }
    }

    /// 步进量（plan v1.5 §4.1）：该周期首个 `endGlobalIndex > currentTick` 的 K 线的
    /// `endGlobalIndex - currentTick`；无后续 K 线 → 0（已到该周期末尾）。
    /// 用 `?? []`（D9）：缺数据 → 0 步=不推进，不 crash（比 spec 强解包防御）。
    private func stepsForPeriod(_ period: Period) -> Int {
        let candles = allCandles[period] ?? []
        let current = tick.globalTickIndex
        let idx = candles.partitioningIndex { $0.endGlobalIndex > current }
        guard idx < candles.count else { return 0 }
        return candles[idx].endGlobalIndex - current
    }

    /// 两面板硬切 autoTracking（D4，plan v1.5 L235）→ 推进 tick → 更新回撤 → 局终强平（Task 6 接入）。
    private func advanceAndAccount(panel: PanelId) {
        stopAllDeceleration()                       // D7：立即中断 free-scrolling 惯性（spec L235）
        _ = upperPanel.reduce(.tradeTriggered)
        _ = lowerPanel.reduce(.tradeTriggered)
        resetOffsetAfterAutoTracking(.upper)        // D8：autoTracking ⇒ offset==0
        resetOffsetAfterAutoTracking(.lower)
        endDrawingSessionIfActive()                 // D45
        _ = tick.advance(steps: stepsForPeriod(period(of: panel)))
        drawdown.update(currentCapital: currentTotalCapital)
        forceCloseIfEnded()
    }

    /// 成交时刻（D5）：成交 tick 的 `.m3` candle datetime；超末根夹取末根，缺数据 0。
    private func candleDatetime(atTick target: Int) -> Int64 {
        let m3 = allCandles[.m3] ?? []
        guard let last = m3.last else { return 0 }
        let idx = m3.partitioningIndex { $0.endGlobalIndex >= target }
        return idx < m3.count ? m3[idx].datetime : last.datetime
    }

    // MARK: - RFC-A 按股数交易入口（A1）

    /// 按股数买入：当前 tick 价成交 → 记 marker/operation(entryTick) → 推进 → 联动 → 局终强平。
    /// 失败(模式不允许 / quoteBuy 校验失败)返 `.failure(.trade(...))`，**不** mutate、**不** advance（D9）。
    public func buy(panel: PanelId, shares: Int) -> Result<TradeOperation, AppError> {
        guard flow.canBuySell() else { return .failure(.trade(.disabled)) }
        let price = currentPrice
        let entryTick = tick.globalTickIndex
        let p = period(of: panel)
        let cashBefore = cashBalance
        switch TradeCalculator.quoteBuy(cash: cashBefore, shares: shares, price: price, fees: fees) {
        case .failure(let reason):
            return .failure(.trade(reason))
        case .success(let quote):
            position.buy(shares: quote.shares, totalCost: quote.totalCost)
            cashBalance -= quote.totalCost
            markers.append(TradeMarker(globalTick: entryTick, price: price, direction: .buy))
            // D4：positionTier 仅记录展示，由占比反推（cashBefore>0 已由 quote 成功保证）
            let tier = TradeCalculator.tierForFraction(cashBefore > 0 ? quote.totalCost / cashBefore : 1)
            let op = TradeOperation(
                globalTick: entryTick, period: p, direction: .buy, price: price,
                shares: quote.shares, positionTier: tier,
                commission: quote.commission, stampDuty: 0,
                totalCost: quote.totalCost, createdAt: candleDatetime(atTick: entryTick))
            tradeOperations.append(op)
            advanceAndAccount(panel: panel)
            return .success(op)
        }
    }

    /// 按股数卖出：当前 tick 价成交 → 记 marker/operation(entryTick) → 推进 → 联动 → 局终强平。
    /// R-plan-14-1：经集中契约的 quoteSell(cash:…)——success 已保证「输出有限 + cashBalance+proceeds≥0」，
    /// 故下方直接 mutate（与 TradeBoxContent 同一可执行性判定，UI/engine 不再发散）。
    public func sell(panel: PanelId, shares: Int) -> Result<TradeOperation, AppError> {
        guard flow.canBuySell() else { return .failure(.trade(.disabled)) }
        let price = currentPrice
        let entryTick = tick.globalTickIndex
        let p = period(of: panel)
        let holdingBefore = position.shares
        switch TradeCalculator.quoteSell(cash: cashBalance, holding: holdingBefore, shares: shares, price: price, fees: fees) {
        case .failure(let reason):
            return .failure(.trade(reason))
        case .success(let quote):
            position.sell(shares: quote.shares)
            cashBalance += quote.proceeds               // quoteSell 已保证 cashBalance+proceeds 有限且 ≥0
            markers.append(TradeMarker(globalTick: entryTick, price: price, direction: .sell))
            let tier = TradeCalculator.tierForFraction(
                holdingBefore > 0 ? Double(quote.shares) / Double(holdingBefore) : 1)
            let op = TradeOperation(
                globalTick: entryTick, period: p, direction: .sell, price: price,
                shares: quote.shares, positionTier: tier,
                commission: quote.commission, stampDuty: quote.stampDuty,
                totalCost: quote.proceeds, createdAt: candleDatetime(atTick: entryTick))
            tradeOperations.append(op)
            advanceAndAccount(panel: panel)
            return .success(op)
        }
    }

    // MARK: - 局终自动强平（E5b / §4.2.1 入口 1b / D7）

    /// 推进到 `>= maxTick` 且仍有持仓 → 按末根 .m3 收盘价强制全平（plan v1.5 L751）。
    /// 幂等：强平后 shares==0，再次到顶 guard 短路。
    private func forceCloseIfEnded() {
        guard tick.globalTickIndex >= tick.maxTick, position.shares > 0 else { return }
        performForceClose()
    }

    /// 手动 on-demand 强平（RFC §4.4a）：用户点「结束本局」时调用，去掉 `>= maxTick` 门。
    /// 前置 `flow.canBuySell()`（Normal/Replay ✅，Review ❌；opus R1-L4：「结束按钮」capability
    /// 行的 intentional load-bearing proxy，恰与「买卖按钮」行同值）。按当前 tick 价、不推进 tick。
    /// 幂等：空仓短路。**返回 `isSettlementSafe`** —— 顺位 7 caller 的路由信号（只在确认平仓**且**
    /// finalize 用到的全部派生财务量有限时才返 true；否则 false，caller 不路由结算）。
    /// **Review/disabled 恒返 false**（codex R3-medium：Review 禁手动结束，flat Review 不得误报可结算）。
    /// ended UI 态 / 结算路由本身归顺位 7/8，非 engine 契约。
    @discardableResult
    public func forceCloseManually() -> Bool {
        guard flow.canBuySell() else { return false }   // R3-medium：Review/disabled 永不经手动结束达成可结算
        if position.shares > 0 { performForceClose() }
        return isSettlementSafe
    }

    /// 终态结算安全谓词（codex plan R3/R4/R5）：持仓已平 **且** finalize 持久化用到的引擎级派生量全有限
    /// —— `currentTotalCapital`（→ totalCapital/profit）、`returnRate`（→ 收益率；`initialCapital` 极小如
    /// 1e-308 时 `(total-initial)/initial` 会溢出 inf，codex R5#2）、`drawdown`（→ maxDrawdown）。
    /// 任一非有限即 false → caller 不路由结算（**安全降级**），避免 finalize 持久化 NaN/inf。
    /// 注：污染源（init 派生 startTotal / advance drawdown / reader 病态价）根治归顺位 10；本谓词
    /// 仅做 engine 级诚实门。**finalize 真正持久化的输出**（含 maxDrawdown 比率换算）的完整 fail-closed
    /// 校验 + auto/manual 双路强制 = RFC §4.7 「单事务 finalization port」= 顺位 10a/10b（见 Scope 边界 3）。
    /// 另含 `currentTotalCapital >= 0`（codex R6#2）：与引擎**既有非负资金不变量**（init 前置
    /// `cashBalance >= 0`）一致。低面值清仓（如 100 股 ×0.01，最低佣金 5 → proceeds 负）会让 cash 转负；
    /// 该 mutation 是否允许（负债 / floor / 拒绝）= **预先存在的 spec 级语义决定，归顺位 10 + 治理 residual**；
    /// 本谓词只保证「结算门不把负资金态误报为可结算」。
    private var isSettlementSafe: Bool {
        position.shares == 0
            && currentTotalCapital.isFinite
            && currentTotalCapital >= 0
            && returnRate.isFinite
            && drawdown.peakCapital.isFinite
            && drawdown.maxDrawdown.isFinite
    }

    /// 强平共用体（局终自动 + 手动 on-demand 共用，仅触发门不同 → 杜绝两套强平逻辑漂移）：
    /// 按 `currentPrice` 全量清仓 → 记 sell marker/operation(.tier5) → `drawdown.update` 把
    /// 已扣费 realized 总资金并入回撤（否则末根手续费造成的回撤被低报）。caller 须先验 `shares > 0`。
    /// 走 E3 `forceCloseOnEnd`（裸 SellQuote，holding==position.shares 满足入口 1b caller 不变量）。
    /// **整笔原子性（codex plan R2/R4）**：先算完整终态 `newCash = cashBalance + proceeds` 并校验
    /// quote 各被写字段 **+ newCash** 全有限，**全有限才提交任一 mutation**；否则整笔原子 no-op 返 false。
    /// 覆盖三类病态：①price≤0/非有限 → forceCloseOnEnd 返全零报价（shares==0 短路）；②有限极端价
    /// → `makeSellQuote` 的 notional/proceeds 溢出 inf/NaN（quote 字段守）；③两有限值相加溢出
    /// （`cashBalance + proceeds` → inf，newCash 守）。杜绝把非有限写进 cash/record / 留半平仓态。
    @discardableResult
    private func performForceClose() -> Bool {
        let price = currentPrice
        let quote = TradeCalculator.forceCloseOnEnd(
            holding: position.shares, averageCost: position.averageCost, price: price, fees: fees)
        let newCash = cashBalance + quote.proceeds
        guard quote.shares > 0,
              quote.proceeds.isFinite, quote.commission.isFinite, quote.stampDuty.isFinite,
              newCash.isFinite
        else { return false }   // 报价溢出 / cash 和溢出 → 校验在 mutation 之前 → 整笔原子 no-op
        let tickAtClose = tick.globalTickIndex
        position.sell(shares: quote.shares)
        cashBalance = newCash                       // 用预校验过的终值（codex R4：mutation 前已验完整终态）
        markers.append(TradeMarker(globalTick: tickAtClose, price: price, direction: .sell))
        tradeOperations.append(TradeOperation(
            globalTick: tickAtClose, period: .m3, direction: .sell, price: price,
            shares: quote.shares, positionTier: .tier5,
            commission: quote.commission, stampDuty: quote.stampDuty,
            totalCost: quote.proceeds, createdAt: candleDatetime(atTick: tickAtClose)))
        drawdown.update(currentCapital: currentTotalCapital)
        return true
    }

    // MARK: - 场景生命周期中继（D6）

    /// 由 U2 TrainingView 顶层 `.onChange(of: scenePhase)` 触发（modules L1625-1629）。
    /// 仅中继到减速动画 reset，不触碰业务状态。
    public func onSceneActivated() {
        animators.upper.resetOnSceneActive()
        animators.lower.resetOnSceneActive()
    }

    /// 现价查找（静态，供 init seeding 与实例 `currentPrice` 复用）：`.m3` 驱动序列中首个
    /// `endGlobalIndex >= target` 的 K 线收盘价；超末根夹取末根（D2）。`.m3` 与全局 tick 1:1，
    /// 避免聚合周期 close 取到未来价（codex R4-F2）。init 已保证 `.m3` 非空。
    /// 从 meta.start_datetime 推训练起始点 tick：第一根 `datetime >= startDatetime` 的 `.m3` 下标。
    /// `.m3` 轴连续（globalIndex==endGlobalIndex==index），故下标 == global tick。
    /// 不变量：返回 0 **当且仅当** `startDatetime <= m3[0].datetime`；degenerate（start 超所有 m3）
    /// → 钳到 `maxTick`（保 `0...maxTick` + 不变量，valid 数据不触发）。空 m3 → 0（make 已先验非空）。
    nonisolated static func startTick(forStartDatetime startDatetime: Int64,
                                      in allCandles: [Period: [KLineCandle]]) -> Int {
        guard let m3 = allCandles[.m3], !m3.isEmpty else { return 0 }
        let idx = m3.partitioningIndex { $0.datetime >= startDatetime }
        return min(idx, m3.count - 1)
    }

    private static func price(in allCandles: [Period: [KLineCandle]], atTick target: Int) -> Double {
        let candles = allCandles[.m3] ?? []
        guard let last = candles.last else { return 0 }
        let idx = candles.partitioningIndex { $0.endGlobalIndex >= target }
        return idx < candles.count ? candles[idx].close : last.close
    }

    /// `.m3` 全局 tick 轴不变量：第 i 根 `period == .m3` 且 `globalIndex == endGlobalIndex == i`
    /// （连续从 0、无 gap）。`currentPrice` 的二分（首个 `endGlobalIndex >= tick`）依赖此轴——
    /// gap/乱序会把 tick 定到未来 candle（codex final-R5-F1）。`make` 校验为可恢复、`init` 为末线不变量。
    private static func isContiguousM3Axis(_ m3: [KLineCandle]) -> Bool {
        for (i, c) in m3.enumerated() {
            guard c.period == .m3, c.globalIndex == i, c.endGlobalIndex == i else { return false }
        }
        return true
    }

    /// persistence-scope RFC 纵深防御：.m3 datetime 严格递增（synthesize 的 partitioningIndex{datetime>=X}
    /// 谓词单调性前提）。reader 是生产主校验；此为 fake/非 GRDB 源喂 make 的普适末线——消除未定义行为，
    /// 不保证窗口正确性（窗口越界由 synthesize 的 min(rawStart,tick) clamp 兜底为 bounded-GIGO）。
    private static func isStrictlyIncreasingM3Datetime(_ m3: [KLineCandle]) -> Bool {
        for i in m3.indices.dropFirst() {
            guard m3[i].datetime > m3[i - 1].datetime else { return false }
        }
        return true
    }
}

// MARK: - C8b 交互编排（C7 手势接线下游 + 画线激活 H1 production handler）
// 同文件 extension：可访问 `private let animators` / `public private(set) var drawings`（setter 文件作用域）/
// `lastRenderedBounds`（Swift `private`/`private(set)` setter 文件作用域；免破坏 E5a init internal 的 trust boundary）。

extension TrainingEngine {

    // MARK: 私有 helper（面板/动画/bounds 取址 + 经 reducer 的 offset 派发）

    private func panelState(_ panel: PanelId) -> PanelViewState {
        panel == .upper ? upperPanel : lowerPanel
    }

    private func renderBounds(_ panel: PanelId) -> CGRect {
        panel == .upper ? lastRenderedBounds.upper : lastRenderedBounds.lower
    }

    private func animator(for panel: PanelId) -> DecelerationAnimator {
        panel == .upper ? animators.upper : animators.lower
    }

    /// 把 ChartAction 派给对应面板的 reducer（统一面板 mutate 入口）。
    @discardableResult
    private func reduce(_ action: ChartAction, on panel: PanelId) -> ChartReduceEffect {
        switch panel {
        case .upper: return upperPanel.reduce(action)
        case .lower: return lowerPanel.reduce(action)
        }
    }

    /// 减速 onUpdate + 单指 pan `.changed` 共用：每帧 delta 经 reducer offsetApplied
    /// （drawing 吞 / autoTracking·freeScrolling 累加 + bump，spec L1123-1129）。
    private func applyOffsetDelta(_ delta: CGFloat, panel: PanelId) {
        _ = reduce(.offsetApplied(deltaPixels: delta), on: panel)
    }

    // MARK: RFC #4 — 两图 pan 时间对齐联动（D5/D6/D8）

    /// 另一面板。
    private func follower(of panel: PanelId) -> PanelId { panel == .upper ? .lower : .upper }

    /// leader 帧后：把 follower 右缘对齐到 leader 右缘的同一 global tick（单向，经现有 .offsetApplied）。
    /// 只由三个具名 gesture 函数（beginPan/applyPanOffset/floorOrFull）调；不挂通用 applyOffsetDelta（防与
    /// lockstep reset 双驱，D5/R7）。drawing 态 follower 被 reducer 吞（D10）。无 bounds/空 candle → no-op。
    private func propagateLinkage(fromLeader leader: PanelId) {
        let f = follower(of: leader)
        let lBounds = renderBounds(leader), fBounds = renderBounds(f)
        let lCandles = allCandles[period(of: leader)] ?? []
        let fCandles = allCandles[period(of: f)] ?? []
        guard lBounds.width > 0, fBounds.width > 0, !lCandles.isEmpty, !fCandles.isEmpty else { return }
        let leaderTick = PanLinkage.rightEdgeTick(offset: panelState(leader).offset, candles: lCandles,
                            rawVisible: panelState(leader).visibleCount, bounds: lBounds, tick: tick.globalTickIndex)
        let fTarget = PanLinkage.followerOffset(targetTick: leaderTick, candles: fCandles,
                            rawVisible: panelState(f).visibleCount, bounds: fBounds, tick: tick.globalTickIndex)
        let fCur = panelState(f).offset
        if fTarget != fCur { applyOffsetDelta(fTarget - fCur, panel: f) }   // D6（drawing 态吞 D10）
    }

    // MARK: R1b-wire offset clamp（D9：drag full / decel·bounce floor-or-full / reducer 无界 D2）

    private func activeBoundsFor(_ panel: PanelId) -> ActiveDecel? {
        panel == .upper ? activeBounds.upper : activeBounds.lower
    }
    private func setActiveBounds(_ v: ActiveDecel?, panel: PanelId) {
        if panel == .upper { activeBounds.upper = v } else { activeBounds.lower = v }
    }
    private func dragRawFor(_ panel: PanelId) -> CGFloat? {
        panel == .upper ? dragRaw.upper : dragRaw.lower
    }
    private func setDragRaw(_ v: CGFloat?, panel: PanelId) {
        if panel == .upper { dragRaw.upper = v } else { dragRaw.lower = v }
    }

    /// 减速/bounce 每帧 delta（onUpdate）：bounce → floor `[min,+∞)`（放最老边 overscroll）；
    /// decel → full `[min,max]`（硬停两边，含 v>0 无滚动空间不 strand，C1）。无 activeBounds → 无界（旧路径兼容）。
    private func floorOrFullClampedOffsetDelta(_ delta: CGFloat, panel: PanelId) {
        guard let a = activeBoundsFor(panel) else { applyOffsetDelta(delta, panel: panel); return }
        let cur = panelState(panel).offset
        let target = a.allowOverscroll
            ? max(a.bounds.minOffset, cur + delta)                                  // bounce：仅 floor
            : min(max(cur + delta, a.bounds.minOffset), a.bounds.maxOffset)         // decel：full
        if target != cur { applyOffsetDelta(target - cur, panel: panel) }           // L2-new：省 0-delta 空 bump
        propagateLinkage(fromLeader: panel)                                          // RFC #4：减速/bounce 每帧驱动 follower
    }

    /// 中断进行中减速/bounce（新交互起手：beginPan/activateDrawingTool/pinch.began，D10）：停 + 仅当**活跃** run 时
    /// 把 overscroll 归界内。`isDecelerating`-guard：动画已 settle/cancel（activeBounds 残留旧几何）时不 clamp，防 stale 误钳。
    private func interruptDeceleration(panel: PanelId) {
        let a = animator(for: panel)
        let wasRunning = a.isDecelerating
        a.stop()
        if wasRunning, let act = activeBoundsFor(panel) {
            let cur = panelState(panel).offset
            let clamped = min(max(cur, act.bounds.minOffset), act.bounds.maxOffset)
            if clamped != cur { _ = reduce(.offsetApplied(deltaPixels: clamped - cur), on: panel) }   // overscroll(>max) 归 maxOffset
        }
    }

    /// 停两面板减速（D7：硬切 autoTracking / 画线激活前调）。
    private func stopAllDeceleration() {
        animators.upper.stop()
        animators.lower.stop()
    }

    /// D8：硬切 autoTracking 后经 reducer 把 offset 归零（spec L1153「offset 只经 reducer」）。
    /// 必须在 reduce(.tradeTriggered/.periodComboSwitched) **之后**调——此时 mode 已 autoTracking，
    /// offsetApplied 不被 drawing 吞、被 autoTracking 分支累加。autoTracking + makeViewport mode-agnostic
    /// 下，offset!=0 会令视口偏移，故须归零以「锁定最新」（D8）。
    private func resetOffsetAfterAutoTracking(_ panel: PanelId) {
        let off = panelState(panel).offset
        if off != 0 { _ = reduce(.offsetApplied(deltaPixels: -off), on: panel) }
    }

    // MARK: 单指 pan 手势派发（C7 arbiter onPan 回调下游）

    /// onPan `.began`：autoTracking → freeScrolling（spec 状态转换表 L231）。
    /// 新一次抓取必须**先停**本面板进行中的减速（标准惯性滚动语义：手指落下即截住惯性）——否则 re-grab 期间
    /// 残余减速 onUpdate 与手指 `applyPanOffset` 同时喂 `offsetApplied` 致跳动（final-review F1，与 D7 硬切同精神）。
    public func beginPan(panel: PanelId) {
        interruptDeceleration(panel: panel)                  // R1b-wire D10：停 + 归一中途 overscroll（H3），再 seed/.panStarted
        setDragRaw(panelState(panel).offset, panel: panel)   // R1b-drag D1：raw 基线=归一后 offset∈[0,maxOffset]（E1）
        _ = reduce(.panStarted, on: panel)
        _ = reduce(.panStarted, on: follower(of: panel))     // RFC #4 D7：follower 转 freeScrolling（drawing 态 .none 自然不动）
        propagateLinkage(fromLeader: panel)                  // RFC #4：起手对齐一次（含 interrupt-clamp 后新右缘，H1）
    }

    /// onPan `.changed`（旧签名，无界）。**internal（codex R2-M2）**：B4 后 offset>maxOffset 渲成 overscroll 间隙，
    /// 故不再暴露 public 无界 mutation 路径（生产 Coordinator 用带 bounds 的新重载；仅模块内测试 @testable 调本签名）。
    func applyPanOffset(deltaPixels: CGFloat, panel: PanelId) {
        applyOffsetDelta(deltaPixels, panel: panel)
    }

    /// onPan `.changed`（R1b-wire B3，**public** gesture API）：传渲染 `renderBounds`（CGRect，public 类型，
    /// 不暴露 internal `OffsetBounds`，codex R3）→ engine 内部算 offset 边界 + drag full-clamp 到 [min,max]（不跟手过边）。
    public func applyPanOffset(deltaPixels: CGFloat, renderBounds: CGRect, panel: PanelId) {
        let ob = RenderStateBuilder.offsetBounds(engine: self, panel: panel, bounds: renderBounds)
        let cur = panelState(panel).offset
        // R1b-drag D1：raw 累加器（未阻尼累计意图位移）。E1：beginPan 已 seed；防御惰性回退当前 offset。
        let raw0 = dragRawFor(panel) ?? cur
        let raw = max(0, raw0 + deltaPixels)                     // E2 下钳 0：最新边硬钳无给 + 无反拖死区
        setDragRaw(raw, panel: panel)
        // D2 单边映射
        let target: CGFloat
        if !ob.bounceEdges.contains(.max) {                      // E6 无滚动空间（maxOffset==0）→ 硬钳 0
            target = min(raw, ob.maxOffset)
        } else if raw <= ob.maxOffset {                          // 界内 1:1（回归）
            target = raw
        } else {                                                 // 最老边阻尼
            let mainW = ChartPanelFrames.split(in: renderBounds).mainChart.width
            target = ob.maxOffset + RubberBand.damp(over: raw - ob.maxOffset, dimension: mainW)
        }
        if target != cur { applyOffsetDelta(target - cur, panel: panel) }   // L2-new：省 0-delta 空 bump
        propagateLinkage(fromLeader: panel)                                  // RFC #4：drag 每帧驱动 follower
    }

    /// onPan `.ended`（旧签名，无界 plain decel）。**internal（codex R2-M2）**：同 applyPanOffset，不暴露 public 无界路径
    /// （生产用带 bounds 新重载；仅模块内测试 @testable 调）。H1：体首清 activeBounds 防 stale 喂 onUpdate。
    func endPan(velocity: CGFloat, panel: PanelId) {
        setActiveBounds(nil, panel: panel)
        if case .startDeceleration(let v) = reduce(.panEnded(velocity: velocity), on: panel) {
            animator(for: panel).start(initialVelocity: v)
        }
    }

    /// onPan `.ended`（R1b-wire B2 + 机制 A，**public** gesture API）：传 `renderBounds`（CGRect，不暴露 OffsetBounds，
    /// codex R3）→ engine 内部算边界 + 按速度方向分派（D8）。v>0 ∧ .max∈bounceEdges → 对称 bounce（最老边弹）；否则 plain decel。
    public func endPan(velocity: CGFloat, renderBounds: CGRect, panel: PanelId) {
        setDragRaw(nil, panel: panel)
        let ob = RenderStateBuilder.offsetBounds(engine: self, panel: panel, bounds: renderBounds)
        guard case .startDeceleration(let v) = reduce(.panEnded(velocity: velocity), on: panel) else { return }
        let offset = panelState(panel).offset
        // R1b-drag D3：drag-overscroll（offset>maxOffset）松手**不论速度方向**都弹簧回 maxOffset（防慢松手 no-op strand）；
        //   否则 R1b-wire 机制 A 既有分派。L1 不变量：post-drag 面板恒 .freeScrolling → .panEnded 返 .startDeceleration（含 v=0）
        //   → 本分支可达；**勿把 overscroll 检查移出本 guard / 勿放松 guard**（autoTracking/drawing 不经此路且已 offset=0）。
        if offset > ob.maxOffset || (v > 0 && ob.bounceEdges.contains(.max)) {
            setActiveBounds(ActiveDecel(bounds: ob, allowOverscroll: true), panel: panel)
            animator(for: panel).start(initialVelocity: v, fromOffset: offset,
                                       minOffset: ob.minOffset, maxOffset: ob.maxOffset)
        } else {
            setActiveBounds(ActiveDecel(bounds: ob, allowOverscroll: false), panel: panel)
            animator(for: panel).start(initialVelocity: v)
        }
    }

    /// onPan `.cancelled`（两指接管 / drawing 截获结算后）：结束本次拖动，**不**启动惯性。
    /// 经 reducer `panEnded(0)` bump revision 但**不改 interactionMode**（freeScrolling 维持，offset 冻结于当前值；
    /// 后续两指切周期/交易再硬切 autoTracking）；忽略其 `.startDeceleration(0)` effect（不调 start）。
    public func cancelPan(panel: PanelId) {
        setDragRaw(nil, panel: panel)
        _ = reduce(.panEnded(velocity: 0), on: panel)
        // R1b-drag E4：cancel-于-overscroll（两指接管/drawing 截获于越界）→ 归一 maxOffset 防残留间隙。
        //   复用 lastRenderedBounds（每帧 render 前 recordRenderBounds 已 seed；不改 public 签名）。
        let ob = RenderStateBuilder.offsetBounds(engine: self, panel: panel, bounds: renderBounds(panel))
        let cur = panelState(panel).offset
        let clamped = min(max(cur, ob.minOffset), ob.maxOffset)
        if clamped != cur { _ = reduce(.offsetApplied(deltaPixels: clamped - cur), on: panel) }
    }

    // MARK: pinch 缩放手势派发（C7 arbiter onPinch 回调下游；RFC §4.4d + 设计 D6）

    /// onPinch 全相位入口。autoTracking = 右锚缩放（offset 置 0，user 2026-06-13 裁决 A）；
    /// freeScrolling = focus 不变量（pinch 中点 candle x 不动，PinchZoomModel.rezoomOffset）；
    /// drawing 由 reducer 吞没（engine 不预判，统一派发）。
    /// scale 为识别器 per-gesture 累积值，按 `.began` 时刻 scaleAtBegan 归一（D4）。
    public func applyPinch(scale: CGFloat, focusX: CGFloat, phase: GesturePhase, panel: PanelId) {
        switch phase {
        case .began:
            interruptDeceleration(panel: panel)   // R1b-wire D10：同 beginPan 先例，停 + 归一中途 overscroll
            setPinchBase(seedPinchBase(scale: scale, panel: panel), panel: panel)
        case .changed:
            // R2-L1：非有限/非正 scale → 真无操作（不派发、状态零改动；防御在 engine 不在模型）
            guard scale.isFinite, scale > 0 else { return }
            let bounds = renderBounds(panel)
            guard bounds.width > 0, bounds.height > 0 else { return }   // 未渲染过 → no-op
            // 自愈（D6）：base 缺失或非法（began 携非法 scale）→ 以当前值+当前 scale 重 seed；
            // 重 seed 后首拍 effectiveScale=1 → target==current → 跳过，无跳变。
            var base = pinchBaseFor(panel) ?? seedPinchBase(scale: scale, panel: panel)
            if !(base.scaleAtBegan.isFinite && base.scaleAtBegan > 0) {
                base = seedPinchBase(scale: scale, panel: panel)
            }
            setPinchBase(base, panel: panel)
            let target = PinchZoomModel.targetVisibleCount(base: base.base,
                                                           effectiveScale: scale / base.scaleAtBegan)
            let ps = panelState(panel)
            guard target != effectiveVisibleCount(ps) else { return }   // N 不变 → 跳过（不 bump）
            switch ps.interactionMode {
            case .freeScrolling:
                assert(bounds.origin == .zero, "focus 数学假设 view-local bounds 原点 .zero（R1-L6）")
                let candles = allCandles[ps.period] ?? []
                guard !candles.isEmpty else { return }
                let vp = RenderStateBuilder.makeViewport(panelState: ps, candles: candles,
                                                         tick: tick.globalTickIndex, bounds: bounds)
                let cIdx = RenderStateBuilder.currentCandleIndex(candles: candles,
                                                                 tick: tick.globalTickIndex)
                let offset = PinchZoomModel.rezoomOffset(viewport: vp, currentIdx: cIdx,
                                                         focusX: focusX, newCount: target,
                                                         mainWidth: vp.mainChartFrame.width)
                _ = reduce(.zoomApplied(visibleCount: target, offset: offset), on: panel)
            case .autoTracking, .drawing:
                // autoTracking：reducer 右锚显式置 0；drawing：reducer 吞没（入参不被读取）
                _ = reduce(.zoomApplied(visibleCount: target, offset: 0), on: panel)
            }
        case .ended, .cancelled:
            setPinchBase(nil, panel: panel)
        }
    }

    /// 有效 visibleCount（≤0 → 80 fallback；engine init 已 seed 80，此处纯防御，D5/R1-L7）。
    private func effectiveVisibleCount(_ ps: PanelViewState) -> Int {
        ps.visibleCount > 0 ? ps.visibleCount : RenderStateBuilder.defaultVisibleCount
    }

    private func seedPinchBase(scale: CGFloat, panel: PanelId) -> (base: Int, scaleAtBegan: CGFloat) {
        (base: effectiveVisibleCount(panelState(panel)), scaleAtBegan: scale)
    }

    private func pinchBaseFor(_ panel: PanelId) -> (base: Int, scaleAtBegan: CGFloat)? {
        panel == .upper ? pinchBase.upper : pinchBase.lower
    }

    private func setPinchBase(_ v: (base: Int, scaleAtBegan: CGFloat)?, panel: PanelId) {
        switch panel {
        case .upper: pinchBase.upper = v
        case .lower: pinchBase.lower = v
        }
    }

    // MARK: bounds 记录（渲染路径每次 updateUIView 调）

    /// ChartContainerView.updateUIView 调：缓存该面板最近渲染 bounds，供 `activateDrawingTool` 算 range（D1）。
    public func recordRenderBounds(_ bounds: CGRect, panel: PanelId) {
        let previous = renderBounds(panel)
        switch panel {
        case .upper: lastRenderedBounds.upper = bounds
        case .lower: lastRenderedBounds.lower = bounds
        }
        // R1b-wire（codex branch-diff M1 + R2-M1）：bounds 变（resize/旋转）→ 按**新**几何归一 stale offset。
        // 冻结 activeBounds（中途 bounce）**或** settled/drag-ended 的 offset 在新几何下可能 >新 maxOffset，
        // B4 会渲成持久 overscroll 间隙直到下次手势。归一**不 gate on isDecelerating**（R2-M1：offset 可在无 animator 时 stale）；
        // 若有 active run 额外 stop+清 activeBounds。bounds 未变（常态每帧）→ no-op，不扰正常 bounce。承袭父 §B5「几何变更 → stop+归一 edge」。
        guard previous != bounds else { return }
        if animator(for: panel).isDecelerating {
            animator(for: panel).stop()
            setActiveBounds(nil, panel: panel)
        }
        let fresh = RenderStateBuilder.offsetBounds(engine: self, panel: panel, bounds: bounds)
        let cur = panelState(panel).offset
        let clamped = min(max(cur, fresh.minOffset), fresh.maxOffset)
        if clamped != cur { _ = reduce(.offsetApplied(deltaPixels: clamped - cur), on: panel) }
        // R1b-drag E5：resize 中途 active drag → 重同步 dragRaw 到归一后 offset（防下一帧 delta 基于 stale raw 跳变）。
        if dragRawFor(panel) != nil { setDragRaw(panelState(panel).offset, panel: panel) }
    }

    // MARK: 画线激活 H1 production handler（spec §C1b 闸门 #4 F3 + effect 合约 L1026-1032）

    /// 画线工具激活（spec `activateDrawingTool`；C8b 加 `panel` 参数，D2）。
    /// **顺序契约（spec Reducer effect L1026-1032，闸门 #2 F2）**：
    ///   ① `animator.stop()`（防 stale 漂移；必须在算 range 之前——停后无新帧可改 offset）
    ///   ② 基于当前（已冻结）面板状态算 candleRange（复用 C8a `visibleCandleRange`）
    ///   ③ 派 `setDrawingSnapshot`（同步无漂移 → 进 drawing；理论 stale → 留 autoTracking）
    public func activateDrawingTool(_ tool: DrawingToolType, panel: PanelId) {
        // R1b-wire R2-C1：interrupt 提顶（在捕获 baseRev 前）。其归一 `offsetApplied` 会 bump revision；若放在
        // `reduce(.activateDrawing)` 之后则 baseRev 失配 setDrawingSnapshot 的 staleness 闸门 → 永不进 drawing。
        // 提顶使 baseRev 捕获归一后 revision；含 stop（防 stale 漂移，原 ① 裸 stop 删除）+ 归一 overscroll（M3）。
        interruptDeceleration(panel: panel)
        guard case .requestDrawingSnapshotAfterStoppingAnimator(let t, let baseRev) =
                reduce(.activateDrawing(tool), on: panel) else {
            return   // 已在 drawing（.none）等 → no-op（interrupt 在 drawing 期无 animator 在跑 → no-op）
        }
        let ps = panelState(panel)                                    // 当前=已冻结+已归一 offset
        let range = RenderStateBuilder.visibleCandleRange(
            panelState: ps, candles: allCandles[ps.period] ?? [],
            tick: tick.globalTickIndex, bounds: renderBounds(panel))
        _ = reduce(.setDrawingSnapshot(tool: t, baseRevision: baseRev, candleRange: range), on: panel)   // baseRev==revision ✓
    }

    /// 删除已完成绘线（spec `deleteDrawing(at:)`）。越界 trap（caller bug，与 spec precondition 同风格）。
    public func deleteDrawing(at index: Int) {
        precondition(drawings.indices.contains(index), "deleteDrawing index out of bounds")
        drawings.remove(at: index)
    }

    /// 追加一条 committed 画线进 `engine.drawings`（RFC §4.4c）。`engine.drawings` 是唯一渲染 +
    /// 持久化真相（`@Observable` 数组突变自动触发重渲染，同 `deleteDrawing`；进入 finalize/pending
    /// 持久化路径）。顺位 4 `DrawingInputController` 在 `manager.commit()` 后调本方法，使
    /// `manager.completedDrawings → engine.drawings` 单一真相（manager 仅作输入暂存）。
    /// **review-redesign Task 10**：本方法保持不变（normal/replay 仍走它）——review 模式改经
    /// `routeDrawingCommit`/`appendReviewDrawing` 写 `reviewDrawings`，不再直接调本方法。
    public func appendDrawing(_ drawing: DrawingObject) {
        drawings.append(drawing)
    }

    /// review-redesign Task 10：复盘新画线唯一写入面——追加进 `reviewDrawings`（不触碰 `drawings`，
    /// 不污染原训练记录）。`RenderStateBuilder.make` review 模式据此叠加 `drawings + reviewDrawings`。
    public func appendReviewDrawing(_ drawing: DrawingObject) {
        reviewDrawings.append(drawing)
    }

    /// `deleteDrawing(at:)` 的 `reviewDrawings` 对应版本（复盘侧删除）。越界 trap，同风格。
    public func removeReviewDrawing(at index: Int) {
        precondition(reviewDrawings.indices.contains(index), "removeReviewDrawing index out of bounds")
        reviewDrawings.remove(at: index)
    }

    /// review-redesign Task 10：画线提交路由单一真相——`review` 模式写 `reviewDrawings`，其余
    /// （normal/replay）写 `drawings`。UIKit commit 路径（`ChartContainerView.handleDrawingTap`）调用
    /// 本方法而非直接判 `flow.mode`，使路由逻辑落在平台无关引擎层，可被 host `swift test` 覆盖
    /// （承载 commit 手势的 UIKit 文件本身在纯 macOS host 不编译）。
    /// **关键不变量**：review commit 绝不写 `drawings`（不污染原训练记录）。
    /// review-redesign Task 3：路由前先盖戳 `revealTick = tick.globalTickIndex`（提交那一刻的全局
    /// tick），使 `RenderStateBuilder.make` 的渐显判据（`revealTick <= tick`）对这条画线生效。
    public func routeDrawingCommit(_ drawing: DrawingObject) {
        let stamped = DrawingObject(
            id: drawing.id, toolType: drawing.toolType, anchors: drawing.anchors,
            isExtended: drawing.isExtended, panelPosition: drawing.panelPosition,
            revealTick: tick.globalTickIndex,               // 仅盖 revealTick
            period: drawing.period, lineSubType: drawing.lineSubType, lineStyle: drawing.lineStyle,
            thickness: drawing.thickness, colorToken: drawing.colorToken, labelMode: drawing.labelMode,
            locked: drawing.locked, text: drawing.text, fontSize: drawing.fontSize,
            textColorToken: drawing.textColorToken, textForm: drawing.textForm, tailAnchor: drawing.tailAnchor)
        if flow.mode == .review {
            appendReviewDrawing(stamped)
        } else {
            appendDrawing(stamped)
        }
    }

    /// 提交当前 drawing：dispatch reducer `.drawingCommitted` 退出 `.drawing` → `.autoTracking`
    /// （RFC §4.4 总纲注记：画线激活-FSM handler 家族，user 2026-06-13 裁决 supersede neck）。
    /// 封装 snapshot.frozen.baseRevision 细节（caller 不碰 revision）。非 drawing 态 no-op（幂等）。
    /// 不改 `drawings`（数据投影是 `appendDrawing` 的职责）；不 bump revision（reducer 契约）。
    public func commitDrawing(panel: PanelId) {
        // P1b-1a-ii 不变量守卫（fail-closed，生产期生效）：面板级 FSM 原语**不得**在全局画线会话开着时
        // 被单独调用 —— 那会把面板打回 .autoTracking 却留下 drawingModeActive==true（本期要消灭的漂移）。
        // 会话的正当收束路径是 endDrawingSessionIfActive()：它先 deactivate() 再 cancel，故此守卫恒放行。
        // 语义 = no-op（不是崩溃）：即便包外消费者误调，也只是什么都不发生，绝不会造出坏状态。
        guard !drawingSession.drawingModeActive else { return }
        guard case .drawing(let snap) = panelState(panel).interactionMode else { return }
        _ = reduce(.drawingCommitted(baseRevision: snap.frozen.baseRevision), on: panel)
    }

    /// 取消当前 drawing：dispatch reducer `.drawingCancelled` 退出 `.drawing` → `.autoTracking`。
    /// 非 drawing 态 no-op。无数据投影。
    public func cancelDrawing(panel: PanelId) {
        // P1b-1a-ii 不变量守卫（fail-closed，生产期生效）：面板级 FSM 原语**不得**在全局画线会话开着时
        // 被单独调用 —— 那会把面板打回 .autoTracking 却留下 drawingModeActive==true（本期要消灭的漂移）。
        // 会话的正当收束路径是 endDrawingSessionIfActive()：它先 deactivate() 再 cancel，故此守卫恒放行。
        // 语义 = no-op（不是崩溃）：即便包外消费者误调，也只是什么都不发生，绝不会造出坏状态。
        guard !drawingSession.drawingModeActive else { return }
        guard case .drawing(let snap) = panelState(panel).interactionMode else { return }
        _ = reduce(.drawingCancelled(baseRevision: snap.frozen.baseRevision), on: panel)
    }

    // MARK: P1b-1a-ii：全局画线会话（D42；review-redesign Task 4 的「按 activePanel 互斥」模型已退役）

    /// 指定面板当前是否处于画线态（面板级 FSM 查询；**不是**「能不能画」的判据——
    /// 那个判据是唯一的 `drawingSession.drawingModeActive`）。
    public func isDrawingActive(on panel: PanelId) -> Bool {
        if case .drawing = panelState(panel).interactionMode { return true }
        return false
    }

    /// 取消两面板画线态（`cancelDrawing` 对非 drawing 态 no-op，故两次调用安全）。
    /// 唯一调用者是 `endDrawingSessionIfActive()`（`TrainingView` 那处已在 3d 删除）。
    /// **保持 public（D46：不做 API 破坏）**；「不得在会话开着时单独调它」的保护来自
    /// `commitDrawing`/`cancelDrawing` 里的**生产期 fail-closed `guard`**（release 也生效，
    /// `assert` 会被剥掉所以没用）+ 源码守卫测试，而不是靠访问级别（internal 在包内照样可见，
    /// 挡不住真正的漂移源）。
    public func cancelDrawingAllPanels() {
        cancelDrawing(panel: .upper)   // 非 .drawing 态 no-op
        cancelDrawing(panel: .lower)
    }

    /// D42 浮动钮唯一入口：全局开/关画线会话（**不属于任何面板**，与 activePanel 无关）。
    public func toggleDrawingMode() {
        if drawingSession.drawingModeActive {
            endDrawingSessionIfActive()
        } else {
            beginDrawingSession(tool: .horizontal)   // 本期只有水平线（工具选择在 1a-iii）
        }
    }

    /// 开会话：**两个面板**一起进 `.drawing`（D42：上下都能画）+ 置真相。
    /// **事务性（commit-last，codex plan-R9-high）**：先武装两个面板，**两个都真的进了 `.drawing` 才**置
    /// `drawingModeActive`；有任何一个没进（`activateDrawingTool` 依赖 `renderBounds`/reducer 态，
    /// 理论上可能不生效）→ **回滚**，绝不留下「铅笔钮亮着、点图却没反应」的卡死态。
    /// 顺序不能反：先置真相再武装，中间一旦失败就是坏状态；先武装再置真相，失败时干净回滚。
    public func beginDrawingSession(tool: DrawingToolType) {
        activateDrawingTool(tool, panel: .upper)
        activateDrawingTool(tool, panel: .lower)
        guard isDrawingActive(on: .upper), isDrawingActive(on: .lower) else {
            cancelDrawingAllPanels()          // 回滚（此刻会话仍未开 → fail-closed 守卫放行）
            drawingSession.deactivate()       // 幂等；确保工具/pending 不残留
            return
        }
        drawingSession.activate(tool: tool)   // 两面板都武装好了，才认会话开启
    }

    /// 结束会话：清真相 + 两面板退出 `.drawing`。幂等（未开会话时全 no-op）。
    /// **D45 单一收口点**：所有会把面板硬切回 `.autoTracking` 的动作（`.tradeTriggered` /
    /// `.periodComboSwitched`）末尾都调它 —— 否则「全局开关还 true、面板已被打回 autoTracking」
    /// 就是一条静默漂移（铅笔钮亮着但点图没反应）。母 spec 终局是画线模式下底栏换成画线工具栏
    /// （1a-iii）→ 那时买卖钮不存在，本路径自然不可达；本期以「下单即隐式退出画线」收敛。
    public func endDrawingSessionIfActive() {
        guard drawingSession.drawingModeActive else { return }
        drawingSession.deactivate()
        cancelDrawingAllPanels()
    }
}

#if DEBUG
extension TrainingEngine {
    /// preview fixture 的 base K 线根数；maxTick 由它派生，保证 tick 不越界（codex R3-F2）。
    private static let previewCandleCount = 8

    /// Preview Fixture（取代 MockTrainingEngine；modules L1687-1705）。
    /// D8：内联构造最小 fixture，不新增公共 fixture 面；maxTick = previewCandleCount-1（非 spec 字面 1000）。
    public static func preview(mode: TrainingMode = .normal) -> TrainingEngine {
        let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        let candles = previewCandles()
        let maxTick = previewCandleCount - 1            // 末根 endGlobalIndex；tick 不越界
        let flow: TrainingFlowController
        switch mode {
        case .normal: flow = NormalFlow(fees: fees, maxTick: maxTick)
        case .review: flow = ReviewFlow(record: previewRecord(fees: fees, finalTick: maxTick), startTick: 0)
        case .replay: flow = ReplayFlow(feeSnapshotFromOriginal: fees, maxTick: maxTick)
        }
        return TrainingEngine(
            flow: flow,
            allCandles: candles,
            maxTick: maxTick,
            initialCapital: 100_000,
            initialCashBalance: 100_000)
    }

    /// codex R4-F3/R5-F2：合法 fixture —— 每根 c.period==key、含非空 `.m3` 驱动序列，
    /// 并为默认面板周期 `.m60`/`.daily` 提供合法聚合（endGlobalIndex ≤ m3Max=7）。
    private static func previewCandles() -> [Period: [KLineCandle]] {
        func candle(_ p: Period, start: Int, end: Int, close: Double) -> KLineCandle {
            KLineCandle(period: p, datetime: Int64(start) * 3600,
                        open: 10, high: 11, low: 9, close: close,
                        volume: 1000, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: start, endGlobalIndex: end)
        }
        let m3 = (0..<previewCandleCount).map { candle(.m3, start: $0, end: $0, close: 10 + Double($0) * 0.1) }
        let m60 = [candle(.m60, start: 0, end: 3, close: 10.3),
                   candle(.m60, start: 4, end: 7, close: 10.7)]
        let daily = [candle(.daily, start: 0, end: 7, close: 10.7)]
        return [.m3: m3, .m60: m60, .daily: daily]
    }

    private static func previewRecord(fees: FeeSnapshot, finalTick: Int) -> TrainingRecord {
        TrainingRecord(id: 1, trainingSetFilename: "preview.sqlite", createdAt: 0,
                       stockCode: "000001", stockName: "预览股",
                       startYear: 2020, startMonth: 1,
                       totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                       buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: finalTick)
    }
}
#endif

#if DEBUG
extension TrainingEngine {
    /// R1b-drag 测试专用：读 dragRaw（生命周期断言）。
    func debug_dragRawFor(_ panel: PanelId) -> CGFloat? { dragRawFor(panel) }

    /// review-redesign Task 5 测试专用：注入 `reviewDrawings`（Task 10 真实路由落地后仍保留——
    /// 供测试直接置状态，不经 `appendReviewDrawing`/`routeDrawingCommit` 手势路径）。
    func setReviewDrawingsForTesting(_ drawings: [DrawingObject]) { reviewDrawings = drawings }
}
#endif

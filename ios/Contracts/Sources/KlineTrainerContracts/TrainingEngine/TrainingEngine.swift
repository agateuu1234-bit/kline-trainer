// Kline Trainer Swift Contracts — E5a TrainingEngine 核心（Wave 2 顺位 2）
// Spec: kline_trainer_modules_v1.4.md §E5 (L1581-1639, preview L1690-1705)
//     + kline_trainer_plan_v1.5.md §4.2/§10.1（最大回撤、现价、初始周期组合 L777）
// 范围：init + 运行时状态 + accessors + onSceneActivated（scenePhase 中继）+ preview。
//   交易动作 buy/sell/holdOrObserve/switchPeriodCombo/activateDrawingTool/deleteDrawing
//   属 E5b（Wave 2 顺位 3），本 PR 不实现。
// 设计判定见 docs/superpowers/plans/2026-06-05-pr-e5a-trainingengine-core.md D1-D8。

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
    public private(set) var upperPanel: PanelViewState
    public private(set) var lowerPanel: PanelViewState
    public private(set) var tradeOperations: [TradeOperation]

    // 构造后不变量
    public let flow: TrainingFlowController
    public let allCandles: [Period: [KLineCandle]]
    public let fees: FeeSnapshot
    public let initialCapital: Double

    private let animators: (upper: DecelerationAnimator, lower: DecelerationAnimator)

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
                initialTradeOperations: [TradeOperation] = [],
                initialDrawdown: DrawdownAccumulator = .initial,
                initialUpperPeriod: Period = .m60,             // 默认上区 60m（plan v1.5 L777）；resume 传 PendingTraining.upperPeriod
                initialLowerPeriod: Period = .daily) {          // 默认下区 日线；resume 传 PendingTraining.lowerPeriod
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
        self.drawings = initialDrawings
        self.tradeOperations = initialTradeOperations

        // D7：初始周期组合默认 上区 60m / 下区 日线（plan v1.5 L777）；resume 传入保存的组合（R6）。
        self.upperPanel = PanelViewState(period: initialUpperPeriod, interactionMode: .autoTracking,
                                         visibleCount: 0, offset: 0, revision: 0)
        self.lowerPanel = PanelViewState(period: initialLowerPeriod, interactionMode: .autoTracking,
                                         visibleCount: 0, offset: 0, revision: 0)

        self.animators = (upper: DecelerationAnimator(), lower: DecelerationAnimator())
    }

    /// `make` 的构造输入：工厂内部据此**先验 maxTick 再建 flow**，杜绝外部传入会 trap 的非法 flow——
    /// NormalFlow/ReplayFlow 的 `0...maxTick` 在 maxTick<0 时一读即 trap，而协议不暴露原始 maxTick，
    /// 无法不 trap 地预判（codex final-R8-F1）。maxTick 由此输入单一派生，结构上无 flow/maxTick 错位。
    public enum FlowInput {
        case normal(fees: FeeSnapshot, maxTick: Int)
        case review(record: TrainingRecord)
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
        case .review(let record):
            guard record.finalTick >= 0 else { throw AppError.trainingSet(.emptyData) }
            maxTick = record.finalTick; flow = ReviewFlow(record: record)
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
            initialDrawings: initialDrawings, initialTradeOperations: initialTradeOperations,
            initialDrawdown: initialDrawdown,
            initialUpperPeriod: initialUpperPeriod, initialLowerPeriod: initialLowerPeriod)
    }

    // MARK: - 派生 accessor（只读纯值计算属性；买卖可用门见 E5b / D4）

    /// 现价：复用 Task 1 的静态 `price(...)`，固定 `.m3` 驱动序列（D2 / codex R4-F2）。
    private var currentPrice: Double {
        TrainingEngine.price(in: allCandles, atTick: tick.globalTickIndex)
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
        case .review: flow = ReviewFlow(record: previewRecord(fees: fees, finalTick: maxTick))
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

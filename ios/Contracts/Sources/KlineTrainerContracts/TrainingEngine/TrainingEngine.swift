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

    public init(flow: TrainingFlowController,
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

    /// 现价查找（静态，供 init seeding 与实例 `currentPrice` 复用）：`.m3` 驱动序列中首个
    /// `endGlobalIndex >= target` 的 K 线收盘价；超末根夹取末根（D2）。`.m3` 与全局 tick 1:1，
    /// 避免聚合周期 close 取到未来价（codex R4-F2）。init 已保证 `.m3` 非空。
    private static func price(in allCandles: [Period: [KLineCandle]], atTick target: Int) -> Double {
        let candles = allCandles[.m3] ?? []
        guard let last = candles.last else { return 0 }
        let idx = candles.partitioningIndex { $0.endGlobalIndex >= target }
        return idx < candles.count ? candles[idx].close : last.close
    }
}

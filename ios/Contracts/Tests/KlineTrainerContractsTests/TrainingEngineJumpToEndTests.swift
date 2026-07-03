// Task B2: TrainingEngine.jumpToEnd() + stepReviewForward() tests
// 新需求10：复盘快进到结尾 + 按更细周期逐根步进
import Testing
@testable import KlineTrainerContracts

// MARK: - Sparse candle map factory for stepReviewForward exhaustion tests

/// 为 F2 测试构建稀疏 candle map：
/// - .m3: 8 根连续（gi==egi==0..7, datetime 严格递增）
/// - .m60: 1 根 endGlobalIndex=3（tick 3 之后耗尽）
/// - .daily: 1 根 endGlobalIndex=7（tick 4 时仍可推进，steps=3）
@MainActor
private func makeSparseCandlesForStepTest() -> [Period: [KLineCandle]] {
    func c(_ p: Period, gi: Int, egi: Int) -> KLineCandle {
        KLineCandle(period: p, datetime: 1 + Int64(gi) * 180,
                    open: 10, high: 11, low: 9, close: 10,
                    volume: 1000, amount: nil, ma66: nil,
                    bollUpper: nil, bollMid: nil, bollLower: nil,
                    macdDiff: nil, macdDea: nil, macdBar: nil,
                    globalIndex: gi, endGlobalIndex: egi)
    }
    let m3 = (0..<8).map { c(.m3, gi: $0, egi: $0) }
    let m60 = [c(.m60, gi: 0, egi: 3)]       // 仅覆盖到 tick 3；tick 4+ 耗尽
    let daily = [c(.daily, gi: 0, egi: 7)]   // 覆盖 tick 7；tick 4 时 steps=3
    return [.m3: m3, .m60: m60, .daily: daily]
}

/// 构建 review 引擎用的 TrainingRecord（finalTick=7）。
@MainActor
private func makeReviewRecord() -> TrainingRecord {
    TrainingRecord(id: nil, trainingSetFilename: "test.sqlite", createdAt: 1,
                   stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
                   totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                   buyCount: 0, sellCount: 0,
                   feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                   finalTick: 7)
}

@MainActor
@Suite struct TrainingEngineJumpToEndTests {

    /// 复盘引擎快进到结尾 — tick 应跳到 maxTick。
    /// preview(mode: .review) 默认 upper=.m60 / lower=.daily，从 tick=0 开始，maxTick=7。
    @Test func jumpToEnd_review_setsMaxTick() {
        let engine = TrainingEngine.preview(mode: .review)
        #expect(engine.tick.globalTickIndex < engine.tick.maxTick)
        engine.jumpToEnd()
        #expect(engine.tick.globalTickIndex == engine.tick.maxTick)
    }

    /// 普通训练模式 jumpToEnd 是 no-op（canJumpToEnd()==false）。
    @Test func jumpToEnd_normal_noOp() {
        let engine = TrainingEngine.preview()
        let before = engine.tick.globalTickIndex
        engine.jumpToEnd()
        #expect(engine.tick.globalTickIndex == before)
    }

    /// stepReviewForward 按更细周期（upper=.m60，3步）而非粗周期（lower=.daily，7步）步进。
    /// 复盘隐藏了周期选择条，不能依赖 activePanel（默认 .lower=粗周期会一击跳一整天）。
    /// preview(mode: .review) 在 tick=0 时：stepsForPeriod(.m60)=3 < stepsForPeriod(.daily)=7。
    @Test func stepReviewForward_usesFinerPeriod_notCoarseDefault() {
        let e = TrainingEngine.preview(mode: .review)
        let t0 = e.tick.globalTickIndex   // 0
        e.stepReviewForward()
        let delta = e.tick.globalTickIndex - t0   // 期望 3（via upper=.m60）

        let coarse = TrainingEngine.preview(mode: .review)
        let c0 = coarse.tick.globalTickIndex
        coarse.holdOrObserve(panel: .lower)
        let coarseDelta = coarse.tick.globalTickIndex - c0   // 7（via lower=.daily）

        #expect(delta > 0)
        #expect(delta < coarseDelta)   // 细周期步进 < 粗周期一根
    }

    // MARK: - Task 4: stepReviewForward(panel:) 按红框所选面板步进

    /// stepReviewForward(panel:) 按「所选面板」的周期步进，而非固定选更细周期。
    /// preview(mode: .review) 在 tick=0 时：upper=.m60 steps=3，lower=.daily steps=7。
    /// 选 .lower（较粗）应比选 .upper（较细）步长更大。
    @Test func stepReviewForwardPanel_selectedPanelGovernsGranularity() {
        let upperEngine = TrainingEngine.preview(mode: .review)
        let u0 = upperEngine.tick.globalTickIndex
        upperEngine.stepReviewForward(panel: .upper)
        let upperDelta = upperEngine.tick.globalTickIndex - u0

        let lowerEngine = TrainingEngine.preview(mode: .review)
        let l0 = lowerEngine.tick.globalTickIndex
        lowerEngine.stepReviewForward(panel: .lower)
        let lowerDelta = lowerEngine.tick.globalTickIndex - l0

        #expect(upperDelta > 0)
        #expect(lowerDelta > upperDelta)   // 所选面板决定步进粒度：粗周期步长更大
    }

    // MARK: - codex whole-branch R2-F2 MEDIUM: exhausted panel is never chosen

    /// codex whole-branch R2-F2：upper(.m60) 耗尽（stepsForPeriod==0）时，stepReviewForward
    /// 应改选 lower(.daily)（仍有 steps）而非 upper → 引擎推进（不卡在 tick 4）。
    /// 稀疏 candle map：.m60 仅覆盖到 egi=3；起点 tick=4 → .m60 已耗尽，.daily steps=3。
    @Test func stepReviewForward_finerPeriodExhausted_advancesViaCoarser() throws {
        let candles = makeSparseCandlesForStepTest()
        let record = makeReviewRecord()  // finalTick=7
        let engine = try TrainingEngine.make(
            .review(record: record, startTick: 4),
            allCandles: candles,
            initialCapital: 100_000,
            initialCashBalance: 100_000,
            initialUpperPeriod: .m60,
            initialLowerPeriod: .daily)
        // 验证前提：tick 起点=4，.m60 耗尽，.daily 未耗尽
        #expect(engine.tick.globalTickIndex == 4)
        // stepReviewForward 应选 .daily 推进（fix 前：选 .m60 步进 0 → 卡在 4）
        engine.stepReviewForward()
        #expect(engine.tick.globalTickIndex > 4)    // 有推进（TDD：fix 前此行 FAIL）
        #expect(engine.tick.globalTickIndex == 7)   // .daily steps=3 → 4+3=7
    }

    /// codex whole-branch R2-F2：两个面板都耗尽（tick==maxTick）时，stepReviewForward 应 no-op，不崩溃。
    @Test func stepReviewForward_bothExhausted_noOp() throws {
        let candles = makeSparseCandlesForStepTest()
        let record = makeReviewRecord()  // finalTick=7
        let engine = try TrainingEngine.make(
            .review(record: record, startTick: 4),
            allCandles: candles,
            initialCapital: 100_000,
            initialCashBalance: 100_000,
            initialUpperPeriod: .m60,
            initialLowerPeriod: .daily)
        // 快进到 maxTick=7 → 两周期皆耗尽
        engine.jumpToEnd()
        let maxTick = engine.tick.maxTick
        #expect(engine.tick.globalTickIndex == maxTick)
        // stepReviewForward no-op（皆耗尽），不崩溃
        engine.stepReviewForward()
        #expect(engine.tick.globalTickIndex == maxTick)
    }

    // MARK: - Review Important gap: stepReviewForward(panel:) 回退/no-op 分支覆盖

    /// review Important 覆盖缺口：stepReviewForward(panel:) 所选面板耗尽（steps==0）时应回退到
    /// 另一面板推进，而非 no-op。复用稀疏 fixture：tick=4 时 .m60(upper) 已耗尽，.daily(lower) steps=3。
    /// 请求已耗尽的 .upper → 方法应改选 .lower 推进 tick 4→7（本测试前该回退分支从未被跑到）。
    @Test func stepReviewForwardPanel_selectedExhausted_fallsBackToOtherPanel() throws {
        let candles = makeSparseCandlesForStepTest()
        let record = makeReviewRecord()  // finalTick=7
        let engine = try TrainingEngine.make(
            .review(record: record, startTick: 4),
            allCandles: candles,
            initialCapital: 100_000,
            initialCashBalance: 100_000,
            initialUpperPeriod: .m60,
            initialLowerPeriod: .daily)
        // 验证前提：tick 起点=4，.m60(upper) 已耗尽，.daily(lower) 未耗尽
        #expect(engine.tick.globalTickIndex == 4)
        // 请求已耗尽的 upper → 应回退选 lower 推进（若回退分支失效则 tick 停在 4，本行会 FAIL）
        engine.stepReviewForward(panel: .upper)
        #expect(engine.tick.globalTickIndex > 4)
        #expect(engine.tick.globalTickIndex == 7)   // .daily steps=3 → 4+3=7
    }

    /// review Important 覆盖缺口：stepReviewForward(panel:) 两面板皆耗尽（已到结尾）时应 no-op，
    /// 无论请求哪个面板，都不应推进 tick、不崩溃。
    @Test func stepReviewForwardPanel_bothExhausted_noOp() throws {
        let candles = makeSparseCandlesForStepTest()
        let record = makeReviewRecord()  // finalTick=7
        let engine = try TrainingEngine.make(
            .review(record: record, startTick: 4),
            allCandles: candles,
            initialCapital: 100_000,
            initialCashBalance: 100_000,
            initialUpperPeriod: .m60,
            initialLowerPeriod: .daily)
        // 快进到 maxTick=7 → 两周期皆耗尽
        engine.jumpToEnd()
        let maxTick = engine.tick.maxTick
        #expect(engine.tick.globalTickIndex == maxTick)
        // 请求 upper（皆耗尽）→ no-op
        engine.stepReviewForward(panel: .upper)
        #expect(engine.tick.globalTickIndex == maxTick)
        // 请求 lower（皆耗尽）→ 同样 no-op
        engine.stepReviewForward(panel: .lower)
        #expect(engine.tick.globalTickIndex == maxTick)
    }
}

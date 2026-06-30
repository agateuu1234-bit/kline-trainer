// Task B2: TrainingEngine.jumpToEnd() + stepReviewForward() tests
// 新需求10：复盘快进到结尾 + 按更细周期逐根步进
import Testing
@testable import KlineTrainerContracts

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
}

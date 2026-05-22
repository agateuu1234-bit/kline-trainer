import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("DecelerationAnimator", .serialized)
struct DecelerationAnimatorTests {

    private let ref: CGFloat = 1.0 / 120.0

    /// 注入 fake 的 animator + 取最近一次创建的 fake。
    private func makeWithFake(friction: CGFloat = 0.94, stopThreshold: CGFloat = 0.5)
        -> (DecelerationAnimator, () -> FakeFrameDriver?) {
        final class Box { var fake: FakeFrameDriver? }
        let box = Box()
        let a = DecelerationAnimator(friction: friction, stopThreshold: stopThreshold,
                                     makeDriver: { onTick in
            let f = FakeFrameDriver(onTick: onTick); box.fake = f; return f
        })
        return (a, { box.fake })
    }

    // 1. start() 进入减速态 + 创建驱动
    @Test("start begins decelerating and creates a driver")
    func startBegins() {
        let (a, fake) = makeWithFake()
        a.start(initialVelocity: 1000)
        #expect(a.isDecelerating)
        #expect(fake() != nil)
    }

    // 2. handleTick .move → onUpdate 收到衰减后 delta
    @Test("handleTick move dispatches onUpdate with decayed delta")
    func tickDispatchesUpdate() {
        let (a, _) = makeWithFake()
        var updates: [CGFloat] = []
        a.onUpdate = { updates.append($0) }
        a.start(initialVelocity: 1000)
        a.handleTick(dt: ref, generation: a.currentGeneration)
        #expect(updates.count == 1)
        #expect(abs(updates[0] - 940 * ref) < 1e-6)
        #expect(a.isDecelerating)
    }

    // 3. 自然终止：onFinish 一次 + 失活驱动，无 onUpdate
    @Test("natural stop fires onFinish once and invalidates driver")
    func naturalStop() {
        let (a, fake) = makeWithFake()
        var updates = 0, finishes = 0
        a.onUpdate = { _ in updates += 1 }
        a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 0.52)
        a.handleTick(dt: ref, generation: a.currentGeneration)
        #expect(updates == 0)
        #expect(finishes == 1)
        #expect(!a.isDecelerating)
        #expect(fake()?.isInvalidated == true)
    }

    // 4. 外部 stop() 静默 + 失活驱动
    @Test("external stop is silent and invalidates driver")
    func externalStopSilent() {
        let (a, fake) = makeWithFake()
        var finishes = 0
        a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 1000)
        a.stop()
        #expect(finishes == 0)
        #expect(!a.isDecelerating)
        #expect(fake()?.isInvalidated == true)
    }

    // 5. resetOnSceneActive() 静默 + 停止
    @Test("resetOnSceneActive is silent and stops")
    func resetSilent() {
        let (a, _) = makeWithFake()
        var finishes = 0
        a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 1000)
        a.resetOnSceneActive()
        #expect(finishes == 0)
        #expect(!a.isDecelerating)
    }

    // 6. dt-guard：大 dt → onFinish + 失活，无 onUpdate
    @Test("handleTick with large dt finishes (background recovery)")
    func backgroundRecovery() {
        let (a, _) = makeWithFake()
        var updates = 0, finishes = 0
        a.onUpdate = { _ in updates += 1 }
        a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 1000)
        a.handleTick(dt: 2.0, generation: a.currentGeneration)
        #expect(updates == 0)
        #expect(finishes == 1)
        #expect(!a.isDecelerating)
    }

    // 7. 重复 start() 重置：旧驱动失活 + 新驱动 + 新初速度
    @Test("re-start invalidates old driver and resets velocity")
    func restartResets() {
        let (a, fake) = makeWithFake()
        var updates: [CGFloat] = []
        a.onUpdate = { updates.append($0) }
        a.start(initialVelocity: 1000)
        let firstFake = fake()
        a.handleTick(dt: ref, generation: a.currentGeneration)
        a.start(initialVelocity: 2000)
        #expect(firstFake?.isInvalidated == true)   // 旧驱动被失活
        #expect(fake() !== firstFake)               // 新驱动
        a.handleTick(dt: ref, generation: a.currentGeneration)
        #expect(updates.count == 2)
        #expect(abs(updates[1] - 1880 * ref) < 1e-6)
    }

    // 8. 未 start 时 handleTick no-op
    @Test("handleTick is no-op when not decelerating")
    func tickWhenIdleNoOp() {
        let (a, _) = makeWithFake()
        var updates = 0, finishes = 0
        a.onUpdate = { _ in updates += 1 }
        a.onFinish = { finishes += 1 }
        a.handleTick(dt: ref, generation: a.currentGeneration)
        #expect(updates == 0)
        #expect(finishes == 0)
    }

    // 9. 非有限初速度不启动
    @Test("non-finite initial velocity does not start")
    func nonFiniteInitialVelocityNoStart() {
        for bad: CGFloat in [.nan, .infinity, -.infinity] {
            let (a, fake) = makeWithFake()
            a.start(initialVelocity: bad)
            #expect(!a.isDecelerating)
            #expect(fake() == nil)
        }
    }

    // 9b. 低于停止阈值的初速度不启动（自审 I1：避免零/微速度 start 触发 spurious onFinish）
    @Test("sub-threshold initial velocity does not start")
    func subThresholdInitialVelocityNoStart() {
        let (a, fake) = makeWithFake()
        var updates = 0, finishes = 0
        a.onUpdate = { _ in updates += 1 }
        a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 0.3)   // < stopThreshold 0.5
        #expect(!a.isDecelerating)
        #expect(fake() == nil)
        #expect(updates == 0)
        #expect(finishes == 0)
    }

    // 10. 旧代次 handleTick 被忽略
    @Test("stale-generation tick is ignored after restart")
    func staleGenerationIgnored() {
        let (a, _) = makeWithFake()
        var updates = 0
        a.onUpdate = { _ in updates += 1 }
        a.start(initialVelocity: 1000)
        let staleGen = a.currentGeneration
        a.start(initialVelocity: 2000)
        a.handleTick(dt: ref, generation: staleGen)            // 旧代次 → 忽略
        #expect(updates == 0)
        a.handleTick(dt: ref, generation: a.currentGeneration) // 新代次 → 生效
        #expect(updates == 1)
    }

    // 11. 经驱动 fire 路由到 onUpdate（驱动真实 onTick 闭包）
    @Test("driver fire routes through onTick to onUpdate")
    func driverFireRoutesToUpdate() {
        let (a, fake) = makeWithFake()
        var updates: [CGFloat] = []
        a.onUpdate = { updates.append($0) }
        a.start(initialVelocity: 1000)
        let keepGoing = fake()!.fire(ref)
        #expect(updates.count == 1)
        #expect(abs(updates[0] - 940 * ref) < 1e-6)
        #expect(keepGoing == true)
    }

    // 12. 释放活跃 animator：驱动下一帧 fire 返回 false → 自失活（weak 清理）
    @Test("released animator: driver tick returns false (self-stop)")
    func releasedAnimatorDriverSelfStops() {
        final class Box { var fake: FakeFrameDriver? }
        let box = Box()
        var a: DecelerationAnimator? = DecelerationAnimator(makeDriver: { onTick in
            let f = FakeFrameDriver(onTick: onTick); box.fake = f; return f
        })
        a!.start(initialVelocity: 1000)
        #expect(box.fake != nil)
        a = nil
        #expect(box.fake!.fire(ref) == false)
    }

    // 12b. elapsedDelta：帧间真实经过时间（含延迟首帧，last=创建时刻）；大间隙 → advance 大-dt 停止（branch-diff R1/R2）
    @Test("elapsedDelta reflects real elapsed time including a delayed first frame")
    func elapsedDeltaReflectsRealGap() {
        // 延迟首帧 2s（last = 创建时刻）：dt = 2.0 → advance 因 dt>=1.0 停止
        #expect(RealFrameDriver.elapsedDelta(now: 100.0, last: 98.0) == 2.0)
        // 正常帧
        #expect(abs(RealFrameDriver.elapsedDelta(now: 1.0 + 1.0 / 120.0, last: 1.0) - 1.0 / 120.0) < 1e-9)
    }

    #if !canImport(UIKit)
    // 13. macOS 真 Timer 驱动 smoke：start() → onUpdate(≥1) → onFinish
    @Test("macOS real Timer driver produces updates then finishes")
    func macTimerDriverRuntime() {
        let a = DecelerationAnimator()
        var updates = 0, finishes = 0
        a.onUpdate = { _ in updates += 1 }
        a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 8)
        let deadline = Date().addingTimeInterval(3.0)
        while finishes == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(updates >= 1)
        #expect(finishes == 1)
        #expect(!a.isDecelerating)
    }
    #endif
}

/// 测试用确定性帧驱动：手动 `fire(dt:)` 模拟一帧；记录是否被 `invalidate()`。
@MainActor
final class FakeFrameDriver: FrameDriving {
    let onTick: (CGFloat) -> Bool
    private(set) var isInvalidated = false
    init(onTick: @escaping (CGFloat) -> Bool) { self.onTick = onTick }
    func invalidate() { isInvalidated = true }
    @discardableResult func fire(_ dt: CGFloat) -> Bool { onTick(dt) }
}

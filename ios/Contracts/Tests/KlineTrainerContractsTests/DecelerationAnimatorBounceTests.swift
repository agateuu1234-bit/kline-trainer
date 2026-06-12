import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("DecelerationAnimator bounce", .serialized)
struct DecelerationAnimatorBounceTests {

    private let ref: CGFloat = 1.0 / 120.0

    private func makeWithFake() -> (DecelerationAnimator, () -> FakeFrameDriver?) {
        final class Box { var fake: FakeFrameDriver? }
        let box = Box()
        let a = DecelerationAnimator(friction: 0.94, stopThreshold: 0.5, makeDriver: { onTick in
            let f = FakeFrameDriver(onTick: onTick); box.fake = f; return f
        })
        return (a, { box.fake })
    }

    /// 手动逐帧 fire 到终止，累积 onUpdate delta + onFinish 次数。
    private func driveToFinish(_ a: DecelerationAnimator, fake: () -> FakeFrameDriver?,
                               dt: CGFloat, updates: inout [CGFloat], finishes: () -> Int,
                               maxFrames: Int = 5000) {
        var n = 0
        while a.isDecelerating, n < maxFrames {
            n += 1
            _ = fake()?.fire(dt)
        }
    }

    // 1. bounce 越界回弹：onUpdate 序列累积 offset 落 edge + onFinish 一次
    @Test("bounce settles at edge and fires onFinish once")
    func bounceSettles() {
        let (a, fake) = makeWithFake()
        var updates: [CGFloat] = []; var finishes = 0
        a.onUpdate = { updates.append($0) }; a.onFinish = { finishes += 1 }
        // 起点 9 in [0,10], v=+1000 → 冲过 10 回弹
        a.start(initialVelocity: 1000, fromOffset: 9, minOffset: 0, maxOffset: 10)
        #expect(a.isDecelerating)
        var n = 0
        while a.isDecelerating, n < 5000 { n += 1; _ = fake()?.fire(ref) }
        let landed = 9 + updates.reduce(0, +)
        #expect(abs(landed - 10) < 1e-6)
        #expect(finishes == 1)
        #expect(!a.isDecelerating)
    }

    // 2. 无跨边 lifecycle parity（codex R9-F1）：bounce API 的 move-then-stop + onFinish 帧 与 start(initialVelocity:) 一致
    @Test("no-crossing bounce matches plain deceleration lifecycle frame-by-frame")
    func noCrossingLifecycleParity() {
        // plain
        let (a1, f1) = makeWithFake()
        var u1: [CGFloat] = []; var fin1 = 0
        a1.onUpdate = { u1.append($0) }; a1.onFinish = { fin1 += 1 }
        a1.start(initialVelocity: 100)
        var seq1: [Bool] = []   // 每帧 isDecelerating 快照
        var n = 0
        while a1.isDecelerating, n < 5000 { n += 1; _ = f1()?.fire(ref); seq1.append(a1.isDecelerating) }
        // bounce，宽边界不跨
        let (a2, f2) = makeWithFake()
        var u2: [CGFloat] = []; var fin2 = 0
        a2.onUpdate = { u2.append($0) }; a2.onFinish = { fin2 += 1 }
        a2.start(initialVelocity: 100, fromOffset: 0, minOffset: -100000, maxOffset: 100000)
        var seq2: [Bool] = []
        n = 0
        while a2.isDecelerating, n < 5000 { n += 1; _ = f2()?.fire(ref); seq2.append(a2.isDecelerating) }
        #expect(u1.count == u2.count)
        for i in 0..<min(u1.count, u2.count) { #expect(abs(u1[i] - u2[i]) < 1e-9) }
        #expect(fin1 == fin2 && fin1 == 1)
        #expect(seq1 == seq2)              // isDecelerating 翻转帧逐帧一致
    }

    // 3. P9 re-entrancy（codex R4-F3/Plan-R2-F2）：终止帧 onUpdate 内重入**真正的新 run** → 新 run 存活
    //    （新 driver 未被旧续延 invalidate）+ 旧 onFinish 抑制；新 run 仍可跑到完成各触发一次。
    @Test("re-entrant start in terminal onUpdate keeps the NEW run alive and suppresses old onFinish")
    func reentrantStartInTerminalUpdate() {
        let (a, fake) = makeWithFake()
        var finishes = 0; var restarted = false
        a.onFinish = { finishes += 1 }
        a.onUpdate = { _ in
            if !restarted {
                restarted = true
                // 重入一个**越界**新 run（shouldRun=true，真建新 driver）
                a.start(initialVelocity: 0, fromOffset: 15, minOffset: 0, maxOffset: 10)
            }
        }
        a.start(initialVelocity: 0, fromOffset: 15, minOffset: 0, maxOffset: 10)  // 第一 run（越界 spring）
        let firstDriver = fake()
        _ = firstDriver?.fire(2.0)   // abnormal-dt 终止帧外溢归一 delta（onUpdate）→ 重入 start 建新 run
        #expect(restarted)
        #expect(a.isDecelerating)                       // 新 run 存活
        let secondDriver = fake()
        #expect(secondDriver !== firstDriver)           // 确为新 driver
        #expect(secondDriver?.isInvalidated == false)   // 新 driver 未被旧续延 invalidate
        #expect(finishes == 0)                          // 旧 run onFinish 被 epoch 守门抑制（此刻仅旧 run 已终止）
        // 驱动新 run 到完成：证其真活 + 新 run 自身 onFinish 触发恰一次
        var n = 0
        while a.isDecelerating, n < 5000 { n += 1; _ = fake()?.fire(ref) }
        #expect(!a.isDecelerating)
        #expect(finishes == 1)                          // 新 run 完成触发一次（旧仍为 0，故总为 1）
    }

    // 4. P9 reset re-entrancy（codex R9-F2）：终止帧 onUpdate 内重入 resetOnSceneActive() → epoch bump → 旧 onFinish 不触发
    @Test("re-entrant resetOnSceneActive in terminal onUpdate suppresses old onFinish")
    func reentrantResetInTerminalUpdate() {
        let (a, fake) = makeWithFake()
        var finishes = 0; var did = false
        a.onFinish = { finishes += 1 }
        a.onUpdate = { _ in if !did { did = true; a.resetOnSceneActive() } }
        a.start(initialVelocity: 0, fromOffset: 15, minOffset: 0, maxOffset: 10)
        _ = fake()?.fire(2.0)   // abnormal-dt 终止帧外溢归一 delta（onUpdate）→ 重入 reset
        #expect(finishes == 0)  // 旧续延 onFinish 被 epoch 守门抑制
    }

    // 5. resetOnSceneActive 越界 → 归位 delta（consumer offset 真回 edge）+ onFinish 静默（codex Plan-R4-F1）
    @Test("resetOnSceneActive normalizes consumer offset back to edge silently")
    func resetNormalizesSilently() {
        let (a, fake) = makeWithFake()
        var updates: [CGFloat] = []; var finishes = 0
        a.onUpdate = { updates.append($0) }; a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 1000, fromOffset: 9, minOffset: 0, maxOffset: 10)
        _ = fake()?.fire(ref)        // 跨边进 spring（offset 越界 > 10）
        let updatesBeforeReset = updates.count
        a.resetOnSceneActive()       // 归位至 edge
        #expect(finishes == 0)       // 静默
        #expect(!a.isDecelerating)
        #expect(updates.count == updatesBeforeReset + 1)        // 发出一条归一 update（normalize 真发生）
        #expect(abs((9 + updates.reduce(0, +)) - 10) < 1e-6)    // **consumer offset 真回 edge 10**（破 normalize 即失败）
        #expect(fake()?.isInvalidated == true)                  // driver 失活
    }

    // 6. 零速越界 start（服务 cancelPan，codex R3-F2）→ 弹簧回弹，非 no-op
    @Test("zero-velocity overscrolled start springs back")
    func zeroVelocityOverscrolledRuns() {
        let (a, fake) = makeWithFake()
        var finishes = 0
        a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 0, fromOffset: 15, minOffset: 0, maxOffset: 10)
        #expect(a.isDecelerating)    // 非 no-op
        var n = 0
        while a.isDecelerating, n < 5000 { n += 1; _ = fake()?.fire(ref) }
        #expect(finishes == 1)
    }

    // 7. 界内亚阈速度 start → no-op
    @Test("in-bounds sub-threshold start is no-op")
    func inBoundsSubThresholdNoOp() {
        let (a, fake) = makeWithFake()
        a.start(initialVelocity: 0.1, fromOffset: 5, minOffset: 0, maxOffset: 10)
        #expect(!a.isDecelerating)
        #expect(fake() == nil)
    }

    // 8. ≤1 帧 finish 时序界（codex R7-F2/Plan-R6-F1）：zero-crossing 事件 tzc 在含它的 display tick 终止；
    //    模型 state 精确钉 edge。内向越界 offset 10.1/v=-50 → tzc≈0.00206s < 1 frame → 第 1 帧终止。
    @Test("bounce finish lands in the display tick containing the analytic zero-crossing event")
    func finishLandsInEventTick() {
        // 120Hz：tzc < ref → 第 1 帧终止
        let (a120, f120) = makeWithFake()
        var u120: [CGFloat] = []; var fin120 = 0; var finFrame120 = -1; var fr = 0
        a120.onUpdate = { u120.append($0) }; a120.onFinish = { fin120 += 1 }
        a120.start(initialVelocity: -50, fromOffset: 10.1, minOffset: 0, maxOffset: 10)
        while a120.isDecelerating, fr < 5000 {
            fr += 1; _ = f120()?.fire(ref)
            if !a120.isDecelerating, finFrame120 < 0 { finFrame120 = fr }
        }
        #expect(fin120 == 1)
        #expect(finFrame120 == 1)                                   // tzc < ref → 含事件的 tick = 第 1 帧
        #expect(abs((10.1 + u120.reduce(0, +)) - 10) < 1e-6)        // 模型 state 精确钉 edge
        // 60Hz：tzc < 2·ref → 仍第 1 帧终止（≤1 帧界跨帧率成立）
        let (a60, f60) = makeWithFake()
        var u60: [CGFloat] = []; var fin60 = 0; var finFrame60 = -1; fr = 0
        a60.onUpdate = { u60.append($0) }; a60.onFinish = { fin60 += 1 }
        a60.start(initialVelocity: -50, fromOffset: 10.1, minOffset: 0, maxOffset: 10)
        while a60.isDecelerating, fr < 5000 {
            fr += 1; _ = f60()?.fire(2 * ref)
            if !a60.isDecelerating, finFrame60 < 0 { finFrame60 = fr }
        }
        #expect(fin60 == 1)
        #expect(finFrame60 == 1)
        #expect(abs((10.1 + u60.reduce(0, +)) - 10) < 1e-6)
    }
}

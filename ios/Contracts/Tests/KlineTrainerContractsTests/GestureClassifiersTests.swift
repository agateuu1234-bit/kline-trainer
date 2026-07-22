// ios/Contracts/Tests/KlineTrainerContractsTests/GestureClassifiersTests.swift
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("classifyTwoFingerGesture")
struct ClassifyTwoFingerGestureTests {
    @Test("scale 放大超阈值 → pinch")
    func scaleZoomIn() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: 100), scale: 1.5) == .pinch)
    }
    @Test("scale 缩小超阈值 → pinch")
    func scaleZoomOut() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 999, y: 999), scale: 0.5) == .pinch)
    }
    @Test("scale 恰在上边界 1.02 不算 pinch（显式 > 1.02，R12 FP 修正）")
    func scaleAtBoundaryNotPinch() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: -100), scale: 1.02) == .switchPeriod(.up))
    }
    @Test("scale 略超上边界 → pinch")
    func scaleJustOverBoundary() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: -100), scale: 1.0201) == .pinch)
    }
    @Test("scale 恰在下边界 0.98 不算 pinch（对称）")
    func scaleAtLowerBoundaryNotPinch() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: -100), scale: 0.98) == .switchPeriod(.up))
    }
    @Test("scale 略低于下边界 → pinch")
    func scaleJustUnderLowerBoundary() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: -100), scale: 0.9799) == .pinch)
    }
    @Test("两指上滑 → switchPeriod up")
    func swipeUp() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 10, y: -100), scale: 1.0) == .switchPeriod(.up))
    }
    @Test("两指下滑 → switchPeriod down")
    func swipeDown() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 10, y: 100), scale: 1.0) == .switchPeriod(.down))
    }
    @Test("水平为主 → ignore")
    func horizontalIgnore() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 100, y: 50), scale: 1.0) == .ignore)
    }
    @Test("dy 恰为 dx*1.2 → ignore（严格 >）")
    func dyAtBoundaryIgnore() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 100, y: 120), scale: 1.0) == .ignore)
    }
}

@Suite("classifySingleFingerPan")
struct ClassifySingleFingerPanTests {
    @Test("微动低于阈值 → ambiguous")
    func belowThreshold() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 5, y: 5)) == .ambiguous)
    }
    @Test("右滑 → horizontal 正 delta")
    func horizontalRight() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 100, y: 10)) == .horizontal(delta: 100))
    }
    @Test("左滑 → horizontal 负 delta")
    func horizontalLeft() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: -100, y: 10)) == .horizontal(delta: -100))
    }
    @Test("垂直为主 → vertical")
    func vertical() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 10, y: 100)) == .vertical)
    }
    @Test("斜向 45° → ambiguous")
    func diagonalAmbiguous() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 50, y: 50)) == .ambiguous)
    }
    @Test("纯水平但幅度不足 → ambiguous（阈值先判）")
    func clearDirectionButTooSmall() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 5, y: 0)) == .ambiguous)
    }
    @Test("自定义阈值抬高门槛 → ambiguous")
    func customThreshold() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 30, y: 5), minThreshold: 40) == .ambiguous)
    }
}

@Suite("panIncrement")
struct PanIncrementTests {
    // 核心契约（修正 R1 finding 1）：累积 [10,20,30] 的逐帧增量为 [10,10,10]，和 == 末帧累积 30
    @Test("多帧累积换增量：增量和等于净位移")
    func multiFrameNetMovement() {
        let cumulative: [CGFloat] = [10, 20, 30]
        var last: CGFloat = 0
        var increments: [CGFloat] = []
        for c in cumulative {
            increments.append(panIncrement(current: c, last: last))
            last = c
        }
        #expect(increments == [10, 10, 10])
        #expect(increments.reduce(0, +) == 30)
        #expect(last == 30)
    }
    @Test("反向拖动增量为负")
    func reverseDirection() {
        #expect(panIncrement(current: -15, last: -5) == -10)
    }
    @Test("无移动增量为 0")
    func noMove() { #expect(panIncrement(current: 42, last: 42) == 0) }
}

@Suite("singlePanStep lifecycle")
struct SinglePanStepTests {
    // 垂直手势全程不产出回调（修正 R2 finding：不得触碰 reducer pan 状态）
    @Test("垂直单指手势全程 emissions 为空且 latch verticalRejected")
    func verticalNeverEmits() {
        let began = singlePanStep(phase: .began, cumulative: .zero, velocityX: 0, lifecycle: .idle, lastTranslationX: 99)
        #expect(began.emissions.isEmpty); #expect(began.lifecycle == .idle); #expect(began.lastTranslationX == 0)
        let changed = singlePanStep(phase: .changed, cumulative: CGPoint(x: 5, y: 100), velocityX: 800,
                                    lifecycle: began.lifecycle, lastTranslationX: began.lastTranslationX)
        #expect(changed.emissions.isEmpty); #expect(changed.lifecycle == .verticalRejected)
        let ended = singlePanStep(phase: .ended, cumulative: CGPoint(x: 5, y: 120), velocityX: 900,
                                  lifecycle: changed.lifecycle, lastTranslationX: changed.lastTranslationX)
        #expect(ended.emissions.isEmpty)   // 关键：垂直手势松手不发 panEnded，不启动减速
    }
    // R9 finding-1：垂直一旦判定即 latch，后续累积满足水平分类器也不得翻成 pan
    @Test("垂直 latch 后水平累积不翻成 pan")
    func verticalLatchedBlocksLaterHorizontal() {
        // 首帧垂直（5,100）→ verticalRejected
        let v = singlePanStep(phase: .changed, cumulative: CGPoint(x: 5, y: 100), velocityX: 0,
                              lifecycle: .idle, lastTranslationX: 0)
        #expect(v.lifecycle == .verticalRejected); #expect(v.emissions.isEmpty)
        // 后续累积变成明显水平（200,100）→ 仍 latch，零回调（不发 .began）
        let later = singlePanStep(phase: .changed, cumulative: CGPoint(x: 200, y: 100), velocityX: 500,
                                  lifecycle: v.lifecycle, lastTranslationX: v.lastTranslationX)
        #expect(later.emissions.isEmpty); #expect(later.lifecycle == .verticalRejected)
    }
    // ambiguous（斜向 / 微动）保持 idle、零回调（仍可后续锁定方向）
    @Test("ambiguous 手势保持 idle 零回调")
    func ambiguousStaysIdle() {
        let s = singlePanStep(phase: .changed, cumulative: CGPoint(x: 50, y: 50), velocityX: 100,
                              lifecycle: .idle, lastTranslationX: 0)
        #expect(s.emissions.isEmpty); #expect(s.lifecycle == .idle)
    }
    // 水平手势：首次锁定发 .began(delta 0)，后续发 .changed 增量，松手发末段残量 .changed + .ended
    @Test("水平手势激活→增量→松手残量+速度全链")
    func horizontalActivationLifecycle() {
        let begin = singlePanStep(phase: .began, cumulative: .zero, velocityX: 0, lifecycle: .idle, lastTranslationX: 0)
        #expect(begin.emissions.isEmpty)
        // 首个水平 .changed（累积 20）：发 .began，delta 0，基线设 20（deadzone 不计入）
        let lock = singlePanStep(phase: .changed, cumulative: CGPoint(x: 20, y: 3), velocityX: 600,
                                 lifecycle: begin.lifecycle, lastTranslationX: begin.lastTranslationX)
        #expect(lock.emissions == [SinglePanEmission(deltaX: 0, velocityX: 600, phase: .began)])
        #expect(lock.lifecycle == .horizontalActive); #expect(lock.lastTranslationX == 20)
        // 后续 .changed（累积 30）：发 .changed，delta 10
        let move = singlePanStep(phase: .changed, cumulative: CGPoint(x: 30, y: 4), velocityX: 700,
                                 lifecycle: lock.lifecycle, lastTranslationX: lock.lastTranslationX)
        #expect(move.emissions == [SinglePanEmission(deltaX: 10, velocityX: 700, phase: .changed)])
        // .ended（累积 35）：末段残量 5 → 先发 .changed(5) 再发 .ended(0)；两者携 velocity 900（R7 finding-2）
        let end = singlePanStep(phase: .ended, cumulative: CGPoint(x: 35, y: 4), velocityX: 900,
                                lifecycle: move.lifecycle, lastTranslationX: move.lastTranslationX)
        #expect(end.emissions == [SinglePanEmission(deltaX: 5, velocityX: 900, phase: .changed),
                                  SinglePanEmission(deltaX: 0, velocityX: 900, phase: .ended)])
        #expect(end.lifecycle == .idle)
    }
    // 残量为 0（松手时无新位移）→ 仅发终止一个
    @Test("松手无残量 → 仅终止一个 emission")
    func endedNoResidual() {
        let end = singlePanStep(phase: .ended, cumulative: CGPoint(x: 30, y: 4), velocityX: 900,
                                lifecycle: .horizontalActive, lastTranslationX: 30)
        #expect(end.emissions == [SinglePanEmission(deltaX: 0, velocityX: 900, phase: .ended)])
    }
    // R13 finding-1：horizontalActive 下 x 不变（current==last）→ 不发 .changed，避免下游 offsetApplied(0) 空 bump revision
    @Test("零 delta .changed 不发回调")
    func zeroDeltaChangedSuppressed() {
        let s = singlePanStep(phase: .changed, cumulative: CGPoint(x: 30, y: 7), velocityX: 700,
                              lifecycle: .horizontalActive, lastTranslationX: 30)
        #expect(s.emissions.isEmpty); #expect(s.lifecycle == .horizontalActive); #expect(s.lastTranslationX == 30)
    }
    // R14 finding：`.began` 已带过阈值水平 translation 直达 `.ended`（无 `.changed`）→ panStarted + 残量 + ended velocity 不丢 flick
    @Test("began 带水平 translation 直达 ended → flick 不丢")
    func beganToEndedFlickNoChanged() {
        let began = singlePanStep(phase: .began, cumulative: CGPoint(x: 25, y: 3), velocityX: 800,
                                  lifecycle: .idle, lastTranslationX: 0)
        #expect(began.emissions == [SinglePanEmission(deltaX: 0, velocityX: 800, phase: .began)])
        #expect(began.lifecycle == .horizontalActive); #expect(began.lastTranslationX == 25)
        let end = singlePanStep(phase: .ended, cumulative: CGPoint(x: 40, y: 3), velocityX: 950,
                                lifecycle: began.lifecycle, lastTranslationX: began.lastTranslationX)
        #expect(end.emissions == [SinglePanEmission(deltaX: 15, velocityX: 950, phase: .changed),
                                  SinglePanEmission(deltaX: 0, velocityX: 950, phase: .ended)])
    }
    // `.began` 垂直已过阈值 → 立即 latch verticalRejected（仍零回调）
    @Test("began 垂直过阈值 → 立即 latch verticalRejected")
    func beganVerticalLatchesImmediately() {
        let s = singlePanStep(phase: .began, cumulative: CGPoint(x: 3, y: 30), velocityX: 0,
                              lifecycle: .idle, lastTranslationX: 0)
        #expect(s.emissions.isEmpty); #expect(s.lifecycle == .verticalRejected)
    }
    // .cancelled 在已激活时发终止但速度归零（不启动减速的释放速度）；残量 10 先补
    @Test("cancelled 在激活态发残量+终止且 velocity 归零")
    func cancelledZeroVelocity() {
        let end = singlePanStep(phase: .cancelled, cumulative: CGPoint(x: 50, y: 4), velocityX: 999,
                                lifecycle: .horizontalActive, lastTranslationX: 40)
        #expect(end.emissions == [SinglePanEmission(deltaX: 10, velocityX: 0, phase: .changed),
                                  SinglePanEmission(deltaX: 0, velocityX: 0, phase: .cancelled)])
        #expect(end.lifecycle == .idle)
    }
    // R11 finding：多指接管同步关闭——horizontalActive 无残量（current==last）→ 恰发一个 .cancelled + 复位，不依赖回调投递
    @Test("supersede horizontalActive 无残量 → 恰一个 cancelled")
    func supersedeActiveNoResidual() {
        let s = singlePanSupersede(lifecycle: .horizontalActive, cumulative: CGPoint(x: 30, y: 5), lastTranslationX: 30)
        #expect(s.emissions == [SinglePanEmission(deltaX: 0, velocityX: 0, phase: .cancelled)])
        #expect(s.lifecycle == .idle); #expect(s.lastTranslationX == 0)
    }
    // R13 finding-2：supersede 时基线落后于当前累积 → 先补残量 .changed 再 .cancelled，不丢接管前位移
    @Test("supersede horizontalActive 有残量 → 残量 + cancelled")
    func supersedeActiveWithResidual() {
        let s = singlePanSupersede(lifecycle: .horizontalActive, cumulative: CGPoint(x: 55, y: 5), lastTranslationX: 40)
        #expect(s.emissions == [SinglePanEmission(deltaX: 15, velocityX: 0, phase: .changed),
                                SinglePanEmission(deltaX: 0, velocityX: 0, phase: .cancelled)])
    }
    // supersede 在 idle / verticalRejected → 无 emission，仍复位
    @Test("supersede 非活跃态无回调仍复位")
    func supersedeInactiveNoEmit() {
        #expect(singlePanSupersede(lifecycle: .idle, cumulative: CGPoint(x: 99, y: 0), lastTranslationX: 0).emissions.isEmpty)
        let v = singlePanSupersede(lifecycle: .verticalRejected, cumulative: CGPoint(x: 99, y: 0), lastTranslationX: 0)
        #expect(v.emissions.isEmpty); #expect(v.lifecycle == .idle)
    }
}

@Suite("twoFingerStep lifecycle")
struct TwoFingerStepTests {
    // R3 核心反例：先 pinch 越阈值 → 后回落 scale≈1.0 + 垂直平移结束 → 只发 pinch 生命周期，绝不切周期
    // （单识别器序列：pan 未参与，pinch began/changed/ended 即两 down 归零结算）
    @Test("pinch 锁定后末帧回落不触发切周期")
    func pinchLockSuppressesSwipe() {
        var st = TwoFingerState()
        let began = twoFingerStep(source: .pinch, phase: .began, scale: 1.0, translation: .zero, state: st); st = began.state
        #expect(began.emission == nil)
        let lock = twoFingerStep(source: .pinch, phase: .changed, scale: 1.05, translation: .zero, state: st); st = lock.state
        #expect(lock.emission == .pinch(scale: 1.05, phase: .began)); #expect(st.locked)
        // 末帧 scale 回落到 1.0 且垂直平移大 → 仍发 pinch(.ended)，不发 switchPeriod
        let end = twoFingerStep(source: .pinch, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: -200), state: st); st = end.state
        #expect(end.emission == .pinch(scale: 1.0, phase: .ended))
        #expect(st == TwoFingerState())
    }
    // R15 finding-2：快速 pinch `.began` 已带过阈值 scale 直达 `.ended`（无 `.changed`）→ pinch 生命周期不丢
    @Test("pinch began 带过阈值 scale 直达 ended → pinch 生命周期不丢")
    func quickPinchBeganToEnded() {
        var st = TwoFingerState()
        let began = twoFingerStep(source: .pinch, phase: .began, scale: 1.05, translation: .zero, state: st); st = began.state
        #expect(began.emission == .pinch(scale: 1.05, phase: .began)); #expect(st.locked)
        let end = twoFingerStep(source: .pinch, phase: .ended, scale: 1.05, translation: .zero, state: st); st = end.state
        #expect(end.emission == .pinch(scale: 1.05, phase: .ended))
        #expect(st == TwoFingerState())
    }
    // 反向失败模式：已 emit 的 pinch 末帧 scale 回落阈值内仍须关闭生命周期（不丢 .ended）
    @Test("锁定 pinch 末帧 scale 在阈值内仍发 ended")
    func pinchTerminalAlwaysClosed() {
        let st = TwoFingerState(pinchDown: true, panDown: false, locked: true)
        let end = twoFingerStep(source: .pinch, phase: .ended, scale: 1.001, translation: .zero, state: st)
        #expect(end.emission == .pinch(scale: 1.001, phase: .ended))
    }
    // 纯垂直两指 swipe（无 pinch）：changed 不发，ended 发一次 switchPeriod
    @Test("纯垂直两指 → ended 发一次 switchPeriod")
    func verticalSwipe() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        let changed = twoFingerStep(source: .pan, phase: .changed, scale: 1.0, translation: CGPoint(x: 5, y: -100), state: st); st = changed.state
        #expect(changed.emission == nil); #expect(st.locked == false)
        let end = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: CGPoint(x: 5, y: -120), state: st); st = end.state
        #expect(end.emission == .switchPeriod(.up))
        #expect(st == TwoFingerState())
    }
    // R5 finding-2 核心：pinch 锁定 + 先终止（另一识别器仍在按）→ 延后；滞后 pan 的 changed/ended 不泄漏切周期
    @Test("pinch 锁定先终止 + 滞后 pan 终止 → 只 pinch.ended 无 switchPeriod（顺序无关）")
    func lateRecognizerNoLeak() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pinch, phase: .began, scale: 1.0, translation: .zero, state: st).state
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        // pinch 锁定
        let lock = twoFingerStep(source: .pinch, phase: .changed, scale: 1.06, translation: .zero, state: st); st = lock.state
        #expect(lock.emission == .pinch(scale: 1.06, phase: .began))
        // pinch 先 ended（scale 1.06 记入 lastPinchScale），但 pan 仍 down → 延后，不发
        let pinchEnd = twoFingerStep(source: .pinch, phase: .ended, scale: 1.06, translation: .zero, state: st); st = pinchEnd.state
        #expect(pinchEnd.emission == nil); #expect(st.panDown == true && st.locked == true)
        // 滞后 pan 的 changed（pinch 已抬起，scale=1.0 是 stale）→ 抑制，不发 stale pinch.changed（R10 finding-2）
        let lagChanged = twoFingerStep(source: .pan, phase: .changed, scale: 1.0, translation: CGPoint(x: 0, y: -200), state: st); st = lagChanged.state
        #expect(lagChanged.emission == nil)
        // pan ended（两 down 归零）→ 结算发 pinch.ended，scale 用 lastPinchScale=1.06（非 stale 1.0），无 switchPeriod
        let panEnd = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: -240), state: st); st = panEnd.state
        #expect(panEnd.emission == .pinch(scale: 1.06, phase: .ended))
        #expect(st == TwoFingerState())
    }
    // R6 finding-1：锁定 pinch 先 .cancelled（pan 仍 down 延后）→ 滞后 pan .ended 结算须发 pinch(.cancelled) 不是 .ended
    @Test("锁定 pinch 先 cancelled 滞后 pan ended → 发 pinch(.cancelled)")
    func lockedPinchCancellationPreserved() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pinch, phase: .began, scale: 1.0, translation: .zero, state: st).state
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        let lock = twoFingerStep(source: .pinch, phase: .changed, scale: 1.08, translation: .zero, state: st); st = lock.state
        #expect(lock.emission == .pinch(scale: 1.08, phase: .began))
        let pinchCancel = twoFingerStep(source: .pinch, phase: .cancelled, scale: 1.08, translation: .zero, state: st); st = pinchCancel.state
        #expect(pinchCancel.emission == nil); #expect(st.pendingTerminal == .cancelled)
        let panEnd = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: .zero, state: st); st = panEnd.state
        #expect(panEnd.emission == .pinch(scale: 1.08, phase: .cancelled))   // 中断 pinch 不误报成功；scale 用 lastPinchScale 非 stale
        #expect(st == TwoFingerState())
    }
    // cancelled 的垂直两指手势不得切周期（离散成功动作只在正常 ended 触发）
    @Test("cancelled 垂直两指 → 不切周期")
    func cancelledSwipeSuppressed() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        let end = twoFingerStep(source: .pan, phase: .cancelled, scale: 1.0, translation: CGPoint(x: 0, y: -200), state: st)
        #expect(end.emission == nil)
    }
    // R7 finding-1：纯垂直 swipe，pan 先 ended（带垂直 translation）→ pinch 后 ended（translation 已失效为 .zero）→ swipe 不丢
    @Test("pan 先 ended 捕获方向 + pinch 后 ended 失效帧 → swipe 保留")
    func swipeSurvivesPanEndedFirst() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        st = twoFingerStep(source: .pinch, phase: .began, scale: 1.0, translation: .zero, state: st).state
        // pan 先 ended（垂直 -120），pinch 仍 down → 延后，捕获 pendingSwipe=.up
        let panEnd = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: -120), state: st); st = panEnd.state
        #expect(panEnd.emission == nil); #expect(st.pendingSwipe == .up)
        // pinch 后 ended，此刻 pan translation 已失效（.zero）→ 用 pendingSwipe 结算
        let pinchEnd = twoFingerStep(source: .pinch, phase: .ended, scale: 1.0, translation: .zero, state: st); st = pinchEnd.state
        #expect(pinchEnd.emission == .switchPeriod(.up))
        #expect(st == TwoFingerState())
    }
    // 对称：pinch 先 ended（读到 pan 实时垂直 translation 捕获方向）→ pan 后 ended → swipe 不丢
    @Test("pinch 先 ended 捕获方向 + pan 后 ended → swipe 保留")
    func swipeSurvivesPinchEndedFirst() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pinch, phase: .began, scale: 1.0, translation: .zero, state: st).state
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        // pinch 先 ended，handlePinch 读 pan 实时 translation = 垂直 120（向下）→ 捕获 .down，pan 仍 down → 延后
        let pinchEnd = twoFingerStep(source: .pinch, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: 120), state: st); st = pinchEnd.state
        #expect(pinchEnd.emission == nil); #expect(st.pendingSwipe == .down)
        let panEnd = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: 130), state: st); st = panEnd.state
        #expect(panEnd.emission == .switchPeriod(.down))
    }
    // R8 finding-1：旁观 pinch（从未 began）的 .failed→.cancelled 不得取消有效两指 swipe
    @Test("旁观 pinch failed 不取消有效两指 swipe")
    func failedPinchDoesNotCancelSwipe() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        // pinch 从未 began，却来 .cancelled（.failed 映射）→ 必须被忽略，不污染 pendingTerminal
        let pinchFail = twoFingerStep(source: .pinch, phase: .cancelled, scale: 1.0, translation: .zero, state: st); st = pinchFail.state
        #expect(pinchFail.emission == nil); #expect(st.pendingTerminal == nil); #expect(st.panDown == true)
        // pan 正常垂直结束 → 仍发 switchPeriod
        let panEnd = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: -150), state: st); st = panEnd.state
        #expect(panEnd.emission == .switchPeriod(.up))
    }
    // 顺序无关 + 不双发：在干净（空）状态收到孤立终止回调 no-op
    @Test("空状态孤立终止回调 no-op（不双发）")
    func strayTerminalNoOp() {
        let second = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: -200),
                                   state: TwoFingerState())
        #expect(second.emission == nil); #expect(second.state == TwoFingerState())
    }
}

@Suite("单指竖滑切周期")
struct SingleFingerVerticalSwipeTests {

    // 竖直锁定（dy > dx*1.5 且 dy>=8）→ verticalRejected，过程不发 pan
    @Test("竖直拖动过程不发 onPan emissions")
    func verticalNoPanDuringChange() {
        let began = singlePanStep(phase: .began, cumulative: CGPoint(x: 0, y: 30), velocityX: 0,
                                  lifecycle: .idle, lastTranslationX: 0)
        #expect(began.lifecycle == .verticalRejected)
        #expect(began.emissions.isEmpty)
        #expect(began.periodSwipe == nil)
    }

    // 松手净竖移 >= 阈值(40) → 发竖滑切周期；上滑(y<0)=up、下滑(y>0)=down
    @Test("松手净竖移 >= 40 → 切周期；上滑 up / 下滑 down")
    func endedAboveThresholdSwitches() {
        // 上滑：y = -50
        let up = singlePanStep(phase: .ended, cumulative: CGPoint(x: 0, y: -50), velocityX: 0,
                               lifecycle: .verticalRejected, lastTranslationX: 0)
        #expect(up.periodSwipe == .up)
        #expect(up.emissions.isEmpty)            // 竖滑不发 pan
        #expect(up.lifecycle == .idle)
        // 下滑：y = +50
        let dn = singlePanStep(phase: .ended, cumulative: CGPoint(x: 0, y: 50), velocityX: 0,
                               lifecycle: .verticalRejected, lastTranslationX: 0)
        #expect(dn.periodSwipe == .down)
    }

    // 松手净竖移 < 阈值 → 不切（防误触）
    @Test("松手净竖移 < 40 → 不切周期")
    func endedBelowThresholdNoSwitch() {
        let r = singlePanStep(phase: .ended, cumulative: CGPoint(x: 0, y: -30), velocityX: 0,
                              lifecycle: .verticalRejected, lastTranslationX: 0)
        #expect(r.periodSwipe == nil)
    }

    // .cancelled（被两指接管等）→ 不切
    @Test(".cancelled 不切周期")
    func cancelledNoSwitch() {
        let r = singlePanStep(phase: .cancelled, cumulative: CGPoint(x: 0, y: -80), velocityX: 0,
                              lifecycle: .verticalRejected, lastTranslationX: 0)
        #expect(r.periodSwipe == nil)
    }

    // 水平 pan 不受影响：仍发 onPan、periodSwipe == nil
    @Test("水平拖动仍发 pan、不切周期")
    func horizontalUnaffected() {
        let began = singlePanStep(phase: .began, cumulative: CGPoint(x: 30, y: 0), velocityX: 5,
                                  lifecycle: .idle, lastTranslationX: 0)
        #expect(began.lifecycle == .horizontalActive)
        #expect(began.periodSwipe == nil)
        #expect(began.emissions.contains { $0.phase == .began })
    }

}

@Suite("1a-iv D32：画线模式与非画线模式走同一条单指 pan 路径")
struct DrawingModePanReleaseTests {
    // 旧行为（1a-iii 及以前）：`singlePanStep(drawingTakesOver: true)` 早退 → emissions == []、periodSwipe == nil。
    // 本期该参数已随 `DrawingModePanPolicy` / `panPolicyInDrawingMode` 原子删除：纯函数**再也无法**表达
    // 「画线时吞掉平移」。行为侧由本 suite 钉死「同一输入照常出位移/切周期」，
    // 结构侧由 `DrawingGestureSourceGuardTests` 钉死「截获通路的代码真的没了」。

    @Test("水平 pan：锁定 horizontalActive 并发 .began（不再是空 emissions）")
    func horizontalPanEmits() {
        let s = singlePanStep(phase: .began, cumulative: CGPoint(x: 30, y: 2), velocityX: 500,
                              lifecycle: .idle, lastTranslationX: 0)
        #expect(s.lifecycle == .horizontalActive)
        #expect(s.emissions == [SinglePanEmission(deltaX: 0, velocityX: 500, phase: .began)])
        #expect(s.lastTranslationX == 30)
    }

    @Test("水平 pan 续帧：照常发增量 .changed（截获分支不再存在，不会被清成 0）")
    func horizontalPanKeepsEmittingDeltas() {
        let s = singlePanStep(phase: .changed, cumulative: CGPoint(x: 80, y: 4), velocityX: 700,
                              lifecycle: .horizontalActive, lastTranslationX: 40)
        #expect(s.emissions == [SinglePanEmission(deltaX: 40, velocityX: 700, phase: .changed)])
        #expect(s.lifecycle == .horizontalActive)
    }

    @Test("竖直甩动：periodSwipe 非 nil —— 画线模式内也能切周期")
    func verticalFlickProducesSwipe() {
        let s = singlePanStep(phase: .ended, cumulative: CGPoint(x: 0, y: -80), velocityX: 0,
                              lifecycle: .verticalRejected, lastTranslationX: 0)
        #expect(s.periodSwipe == .up)
        #expect(s.emissions.isEmpty)      // 切周期是离散动作，不发 pan 位移
    }

    @Test("阈值以下的竖直甩动仍不切周期（放开截获 ≠ 放宽防误触阈值）")
    func shortVerticalFlickStillNoSwipe() {
        let s = singlePanStep(phase: .ended, cumulative: CGPoint(x: 0, y: -20), velocityX: 0,
                              lifecycle: .verticalRejected, lastTranslationX: 0)
        #expect(s.periodSwipe == nil)
    }
}

@Suite("Gesture value types Equatable")
struct GestureValueTypeTests {
    @Test("switchPeriod 方向区分")
    func swipeDirDistinct() { #expect(TwoFingerIntent.switchPeriod(.up) != .switchPeriod(.down)) }
    @Test("horizontal delta 区分")
    func horizontalDeltaDistinct() {
        #expect(SingleFingerPanIntent.horizontal(delta: 1) != .horizontal(delta: 2))
    }
    @Test("GesturePhase 四相区分")
    func phasesDistinct() {
        #expect(GesturePhase.began != .changed)
        #expect(GesturePhase.ended != .cancelled)
    }
}

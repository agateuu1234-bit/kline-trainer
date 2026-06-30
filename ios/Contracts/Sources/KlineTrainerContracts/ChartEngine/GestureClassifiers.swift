// ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift
// Kline Trainer Swift Contracts — C7 手势分类/换算纯函数 + 值类型
// Spec: kline_trainer_modules_v1.4.md §C7（L1351-1406）+ kline_trainer_plan_v1.5.md §手势方案
// Plan: docs/superpowers/plans/2026-05-23-pr-c7-gesture-arbiter.md

import CoreGraphics

/// 单指竖滑切周期的最小净竖移（pt）。低于此不切（防误触）。真机手感可调（runbook 注明）。
let verticalSwitchThreshold: CGFloat = 40

/// 手势生命周期相位（spec §C7）。映射自 UIGestureRecognizer.State，本类型跨平台。
public enum GesturePhase: Equatable, Sendable {
    case began, changed, ended, cancelled
}

/// 两指手势意图（spec §C7 v1.1）。
public enum TwoFingerIntent: Equatable, Sendable {
    case switchPeriod(SwipeDirection)
    case pinch
    case ignore
}

/// 两指意图分类（spec L1363-1368）。scale 偏离 1.0 超 2% 判 pinch；否则垂直分量显著（dy > dx*1.2）判切周期方向；其余忽略。
///
/// **verify-and-correct（R12 finding）**：spec 字面 `abs(scale - 1.0) > 0.02` 在 IEEE754 Double 下，`1.02 - 1.0` 舍入到
/// 略大于 `0.02` → 恰好 2% 边界（scale==1.02 / 0.98）被误判为 pinch（codex `swift -e` 实证）。这里用**对称显式边界**
/// 表达同一意图（>2% 偏离判 pinch），使恰好 2% 边界确定为**非 pinch**、避免减法舍入。等价于 spec 意图，仅消除 FP 边界 wart
/// （C1a xToIndex verify-and-correct 同类先例；非功能性改写——真实连续 scale 不会落在 measure-zero 的精确边界）。
public func classifyTwoFingerGesture(translation: CGPoint, scale: CGFloat) -> TwoFingerIntent {
    if scale > 1.02 || scale < 0.98 { return .pinch }
    let dx = abs(translation.x); let dy = abs(translation.y)
    if dy > dx * 1.2 { return .switchPeriod(translation.y < 0 ? .up : .down) }
    return .ignore
}

/// 单指平移意图（spec §C7 v1.2）。
public enum SingleFingerPanIntent: Equatable, Sendable {
    case horizontal(delta: CGFloat)             // 触发平移（delta = 入参 translation.x，累积或增量由调用方语义决定）
    case vertical                                // 忽略
    case ambiguous                               // 等待更多数据
}

/// 单指平移分类（spec L1377-1385 逐字）。两轴均低于 minThreshold 时等待；
/// 水平/垂直分量超 1.5 倍判明确方向；其余等待。
public func classifySingleFingerPan(translation: CGPoint,
                                    minThreshold: CGFloat = 8) -> SingleFingerPanIntent {
    let dx = abs(translation.x)
    let dy = abs(translation.y)
    if dx < minThreshold && dy < minThreshold { return .ambiguous }
    if dx > dy * 1.5 { return .horizontal(delta: translation.x) }
    if dy > dx * 1.5 { return .vertical }
    return .ambiguous
}

/// Drawing 模式 Pan 截获策略（spec §C7 v1.2）。
public enum DrawingModePanPolicy: Equatable, Sendable {
    case drawingTakesOver    // Pan 被绘线工具吃掉
    case normalPass          // 普通透传
}

/// Drawing 模式下 Pan 归属（spec L1393-1395 逐字）。
public func panPolicyInDrawingMode(drawingMode: Bool) -> DrawingModePanPolicy {
    drawingMode ? .drawingTakesOver : .normalPass
}

/// 累积平移 → 帧间增量。`UIPanGestureRecognizer.translation(in:)` 是整手势累积值，
/// 而下游 `Reducer.offsetApplied(deltaPixels:)` 按增量累加，故 arbiter 必须发增量。
/// 逐帧调用：`delta = panIncrement(current: 当前累积.x, last: 上一帧累积.x)`，调用后更新 last。
public func panIncrement(current: CGFloat, last: CGFloat) -> CGFloat {
    current - last
}

// MARK: - 单指平移生命周期状态机（纯函数，修正 R2 finding：垂直/ambiguous 不得触碰 reducer pan 状态）

/// 单指平移一次回调应发出的事件。
struct SinglePanEmission: Equatable, Sendable {
    let deltaX: CGFloat
    let velocityX: CGFloat
    let phase: GesturePhase
}

/// 单指平移生命周期态（修正 R9 finding-1：垂直意图须 latch，不得后续翻成 pan）。
enum SinglePanLifecycle: Equatable, Sendable {
    case idle               // 方向未定，仍可锁定水平 / 拒绝为垂直
    case horizontalActive   // 已锁定水平平移
    case verticalRejected   // 已判定垂直，本手势剩余全程忽略（latch）
}

/// 单指平移生命周期一步的纯决策结果。`emissions` 按序发（0/1/2 个）——终止带残量时发 2 个（先 .changed 后终止）。
struct SinglePanStep: Equatable, Sendable {
    let emissions: [SinglePanEmission]   // [] = 本步不触发任何 onPan 回调
    let lifecycle: SinglePanLifecycle    // 本手势更新后的生命周期态
    let lastTranslationX: CGFloat        // 下一步增量基线
    let periodSwipe: SwipeDirection?     // 非 nil = 单指竖滑切周期（仅 .ended 终止且净竖移达阈值）
}

/// 单指平移生命周期纯决策。arbiter handler 把识别器原始值喂入、据返回更新状态并发回调。
/// 关键不变量：
/// - 仅 `horizontalActive` 才产出 pan emissions；`idle`(等待) / `verticalRejected`(已拒) 全程 emissions == []（R2 finding）；
/// - **垂直一旦判定即 latch 为 `verticalRejected`**，后续即便累积满足水平分类器也不再发回调（R9 finding-1）；
/// - `.began` **复位并立即按当前累积分类**（R14 finding：UIKit `.began` 可能已过阈值带 translation，防 `.began→.ended` 漏 flick）；`idle .changed` 同样分类；水平锁定时发 `.began`（消费者 panStarted）、基线设当前累积（deadzone 不计入 offset）；
/// - 终止（R7 finding-2）：`horizontalActive` 时若末段有残量，**先发 `.changed`(残量) 再发终止相位**，残量精确应用一次不丢。
func singlePanStep(phase: GesturePhase,
                   cumulative: CGPoint,
                   velocityX: CGFloat,
                   lifecycle: SinglePanLifecycle,
                   lastTranslationX: CGFloat,
                   minThreshold: CGFloat = 8,
                   drawingTakesOver: Bool = false) -> SinglePanStep {
    // Drawing 模式截获（修正 R4 + R5 finding-1 + R13 finding-2）：清空 per-gesture 状态防残留；
    // 若**已激活**水平 pan，先补末段残量 `.changed`(若非零) 再发 `.cancelled` 关闭生命周期——
    // 不丢截获前最后一段拖动位移（R13 finding-2），且避免下游 panStarted 悬空无终止（R5 finding-1）。
    if drawingTakesOver {
        if lifecycle == .horizontalActive {
            let residual = panIncrement(current: cumulative.x, last: lastTranslationX)
            var emissions: [SinglePanEmission] = []
            if residual != 0 { emissions.append(SinglePanEmission(deltaX: residual, velocityX: 0, phase: .changed)) }
            emissions.append(SinglePanEmission(deltaX: 0, velocityX: 0, phase: .cancelled))
            return SinglePanStep(emissions: emissions, lifecycle: .idle, lastTranslationX: 0, periodSwipe: nil)
        }
        return SinglePanStep(emissions: [], lifecycle: .idle, lastTranslationX: 0, periodSwipe: nil)
    }
    // 空闲态按当前累积分类（`.began` 与 idle `.changed` 共用）：水平→锁定+发 `.began`(panStarted)、基线设当前累积（deadzone 不计入）；
    // 垂直→latch verticalRejected；ambiguous→保持 idle 等待。
    func classifyFromIdle() -> SinglePanStep {
        switch classifySingleFingerPan(translation: cumulative, minThreshold: minThreshold) {
        case .horizontal:
            return SinglePanStep(emissions: [SinglePanEmission(deltaX: 0, velocityX: velocityX, phase: .began)],
                                 lifecycle: .horizontalActive, lastTranslationX: cumulative.x, periodSwipe: nil)
        case .vertical:
            return SinglePanStep(emissions: [], lifecycle: .verticalRejected, lastTranslationX: 0, periodSwipe: nil)
        case .ambiguous:
            return SinglePanStep(emissions: [], lifecycle: .idle, lastTranslationX: 0, periodSwipe: nil)
        }
    }
    switch phase {
    case .began:
        // 复位 + 立即分类（R14 finding：UIKit `.began` 可能已带过阈值 translation，防 `.began`→`.ended` 直达漏 flick）
        return classifyFromIdle()
    case .changed:
        switch lifecycle {
        case .horizontalActive:
            let delta = panIncrement(current: cumulative.x, last: lastTranslationX)
            // 零 delta（识别器重复回调 x 不变）→ 不发，避免下游 offsetApplied(0) 空 bump revision（R13 finding-1）
            if delta == 0 {
                return SinglePanStep(emissions: [], lifecycle: .horizontalActive, lastTranslationX: lastTranslationX, periodSwipe: nil)
            }
            return SinglePanStep(
                emissions: [SinglePanEmission(deltaX: delta, velocityX: velocityX, phase: .changed)],
                lifecycle: .horizontalActive, lastTranslationX: cumulative.x, periodSwipe: nil)
        case .verticalRejected:
            return SinglePanStep(emissions: [], lifecycle: .verticalRejected, lastTranslationX: lastTranslationX, periodSwipe: nil)  // latch
        case .idle:
            return classifyFromIdle()
        }
    case .ended, .cancelled:
        if lifecycle == .horizontalActive {
            let residual = panIncrement(current: cumulative.x, last: lastTranslationX)
            let v: CGFloat = phase == .ended ? velocityX : 0
            var emissions: [SinglePanEmission] = []
            if residual != 0 {   // 末段残量先补 offset（R7 finding-2），再发终止
                emissions.append(SinglePanEmission(deltaX: residual, velocityX: v, phase: .changed))
            }
            emissions.append(SinglePanEmission(deltaX: 0, velocityX: v, phase: phase))
            return SinglePanStep(emissions: emissions, lifecycle: .idle, lastTranslationX: cumulative.x, periodSwipe: nil)
        }
        // 竖直已锁定 + 正常结束 + 净竖移达阈值 → 单指竖滑切周期（一甩一档；.cancelled 不发）
        if lifecycle == .verticalRejected, phase == .ended, abs(cumulative.y) >= verticalSwitchThreshold {
            let dir: SwipeDirection = cumulative.y < 0 ? .up : .down
            return SinglePanStep(emissions: [], lifecycle: .idle, lastTranslationX: lastTranslationX,
                                 periodSwipe: dir)
        }
        return SinglePanStep(emissions: [], lifecycle: .idle, lastTranslationX: lastTranslationX, periodSwipe: nil)  // idle/verticalRejected → 复位
    }
}

/// 多指接管时**同步**关闭单指生命周期的纯决策（R11 finding：正确性不得依赖 `isEnabled` toggle 的 .cancelled 回调投递）。
/// `horizontalActive` → 先补末段残量 `.changed`(若非零，R13 finding-2 不丢接管前位移) 再发 `.cancelled` 关闭；
/// `idle`/`verticalRejected` → 无 emission。一律复位为 `.idle` + 基线 0（arbiter 据此同步更新，再物理 toggle 识别器作防御性清理）。
func singlePanSupersede(lifecycle: SinglePanLifecycle, cumulative: CGPoint, lastTranslationX: CGFloat) -> SinglePanStep {
    guard lifecycle == .horizontalActive else {
        return SinglePanStep(emissions: [], lifecycle: .idle, lastTranslationX: 0, periodSwipe: nil)
    }
    let residual = panIncrement(current: cumulative.x, last: lastTranslationX)
    var emissions: [SinglePanEmission] = []
    if residual != 0 { emissions.append(SinglePanEmission(deltaX: residual, velocityX: 0, phase: .changed)) }
    emissions.append(SinglePanEmission(deltaX: 0, velocityX: 0, phase: .cancelled))
    return SinglePanStep(emissions: emissions, lifecycle: .idle, lastTranslationX: 0, periodSwipe: nil)
}

// MARK: - 两指手势生命周期状态机（纯函数，修正 R3 finding：意图须锁定，不得跨回调重分类）

/// 两指手势一次应发出的事件（focus 由 arbiter 从识别器补）。
enum TwoFingerEmission: Equatable, Sendable {
    case pinch(scale: CGFloat, phase: GesturePhase)
    case switchPeriod(SwipeDirection)
}

/// 事件来源识别器（pinch 与两指 pan 同时识别，各发各的 began/changed/ended）。
enum TwoFingerSource: Equatable, Sendable { case pinch, pan }

/// 两指手势生命周期状态。跟踪两识别器是否在按（`pinchDown`/`panDown`）+ 是否锁定 pinch（`locked`）
/// + 延后结算时已记下的终止 phase（`pendingTerminal`，`.cancelled` 压倒 `.ended`）
/// + 延后时已捕获的切周期方向（`pendingSwipe`，防滞后识别器结算时 translation 已失效，R7 finding-1）。
struct TwoFingerState: Equatable, Sendable {
    var pinchDown = false
    var panDown = false
    var locked = false
    var pendingTerminal: GesturePhase? = nil
    var pendingSwipe: SwipeDirection? = nil
    var lastPinchScale: CGFloat = 1.0    // 最近一次 pinch 源报告的 scale；pan 源/终止结算复用，防 stale（R10 finding-2）
}

/// `twoFingerStep` 返回。
struct TwoFingerStepResult: Equatable, Sendable {
    let emission: TwoFingerEmission?
    let state: TwoFingerState
}

/// 两指生命周期纯决策。pinch 与两指 pan 两识别器**交错**调用、各喂对方实时值（scale / translation），
/// 并传 `source` 标识本次回调来自哪个识别器。关键不变量：
/// - 一旦 `classifyTwoFingerGesture == .pinch`，**锁定** intent，后续 `.changed` 全发 pinch、**不再可能切周期**（R3）；
/// - 已锁定 pinch 在终止相位**始终**发 `pinch(.ended/.cancelled)`，无论末帧 scale（不丢生命周期，R3）；
/// - 切周期仅在**未锁定** 且终止时垂直发一次（R3）；
/// - **真顺序无关**（R5 finding-2）：终止结算仅当 `pinchDown` 与 `panDown` 双双归 false 才发生；
///   一个识别器先终止只清自己的 down 标志、延后结算，滞后识别器的 `.changed/.ended` 不会重启手势或泄漏切周期。
func twoFingerStep(source: TwoFingerSource, phase: GesturePhase, scale: CGFloat, translation: CGPoint,
                   state: TwoFingerState) -> TwoFingerStepResult {
    var st = state
    func setDown(_ v: Bool) { switch source { case .pinch: st.pinchDown = v; case .pan: st.panDown = v } }
    switch phase {
    case .began:
        setDown(true)
        // R15 finding-2：.began 可能已带过阈值 scale（快速捏合）→ 立即按当前值分类，防 .began→.ended 无 .changed 漏 pinch
        if !st.locked, classifyTwoFingerGesture(translation: translation, scale: scale) == .pinch {
            st.locked = true
            st.lastPinchScale = scale
            return TwoFingerStepResult(emission: .pinch(scale: scale, phase: .began), state: st)
        }
        return TwoFingerStepResult(emission: nil, state: st)
    case .changed:
        setDown(true)   // .changed 蕴含本识别器活跃
        if st.locked {
            // 仅 pinch 源、或 pinch 仍在按时（scale 为 pinch 实时有效值）才发 pinch.changed 并记 lastPinchScale；
            // pinch 已抬起后 pan 源的 scale 是 stale（默认 1.0）→ 抑制，避免缩放跳变（R10 finding-2）
            if source == .pinch || st.pinchDown {
                st.lastPinchScale = scale
                return TwoFingerStepResult(emission: .pinch(scale: scale, phase: .changed), state: st)
            }
            return TwoFingerStepResult(emission: nil, state: st)
        }
        if classifyTwoFingerGesture(translation: translation, scale: scale) == .pinch {
            st.locked = true
            st.lastPinchScale = scale
            return TwoFingerStepResult(emission: .pinch(scale: scale, phase: .began), state: st)
        }
        return TwoFingerStepResult(emission: nil, state: st)   // 切周期延后到终止判定
    case .ended, .cancelled:
        // 本识别器从未参与（never began，如 .failed→.cancelled 的旁观 pinch）→ 完全忽略，不污染生命周期（R8 finding-1）
        let thisSourceWasDown = (source == .pinch) ? st.pinchDown : st.panDown
        guard thisSourceWasDown else { return TwoFingerStepResult(emission: nil, state: st) }
        setDown(false)
        if source == .pinch { st.lastPinchScale = scale }   // pinch 自身终止 scale 有效 → 记下供结算（R10 finding-2）
        // 合并终止意图：任一识别器 .cancelled 则整手势视为 cancelled（压倒 .ended），见 R6 finding-1
        let effectivePhase: GesturePhase = (phase == .cancelled || st.pendingTerminal == .cancelled) ? .cancelled : .ended
        // 本次终止回调时（translation 仍有效）捕获切周期方向；与已记 pendingSwipe 取首个非空（R7 finding-1）
        var swipe = st.pendingSwipe
        if swipe == nil, !st.locked,
           case .switchPeriod(let dir) = classifyTwoFingerGesture(translation: translation, scale: scale) {
            swipe = dir
        }
        // 另一识别器仍在按 → 记下 pending 终止 phase + 已捕获的切周期方向，延后结算（R5 finding-2 + R6 + R7 finding-1）
        if st.pinchDown || st.panDown {
            st.pendingTerminal = effectivePhase
            st.pendingSwipe = swipe
            return TwoFingerStepResult(emission: nil, state: st)
        }
        // 至此本识别器确曾参与（thisSourceWasDown）且两 down 皆归零 → 结算
        let reset = TwoFingerState()
        if st.locked {
            // 锁定 pinch：用合并后的 effectivePhase 关闭生命周期（中断的 pinch 不得误报成功，R6 finding-1）；
            // scale 用 lastPinchScale（pinch 源最后有效值），不用结算回调可能 stale 的 scale（R10 finding-2）
            return TwoFingerStepResult(emission: .pinch(scale: st.lastPinchScale, phase: effectivePhase), state: reset)
        }
        // 切周期是离散成功动作：仅正常结束（非 cancelled）才发；用 defer 时捕获的方向（防滞后帧 translation 失效，R7 finding-1）
        if effectivePhase == .ended, let dir = swipe {
            return TwoFingerStepResult(emission: .switchPeriod(dir), state: reset)
        }
        return TwoFingerStepResult(emission: nil, state: reset)
    }
}

// ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift
// Kline Trainer Swift Contracts — C7 ChartGestureArbiter（UIKit 手势绑定 + 仲裁）
// Spec: kline_trainer_modules_v1.4.md §C7（L1397-1405）+ kline_trainer_plan_v1.5.md §手势仲裁规则（L90-100）
// Plan: docs/superpowers/plans/2026-05-23-pr-c7-gesture-arbiter.md
//
// 平台门：整类 UIKit-only。macOS swift build 编译为空；Catalyst 编译校验落 required CI 闸门。
// 决策逻辑全在 GestureClassifiers.swift 纯函数（macOS 全量单测）；本类只读识别器原始值 → 调纯函数 → 触发回调。

#if canImport(UIKit)
import UIKit
import CoreGraphics

/// K 线图手势仲裁器（spec §C7）。在 KLineView 上挂 5 个识别器，把原始手势归类为业务回调。
///
/// 仲裁规则（spec plan v1.5 §手势仲裁规则 L90-100）：
/// - 单指左右滑动 = 平移（累积判方向、增量出 offset；1a-iv 起 Drawing 模式同样透传）
/// - 两指上下滑动 = 切周期；两指捏合 = 缩放（二者放行同时识别，由 classifyTwoFingerGesture 喂双实时值确定性仲裁）
/// - 长按 = 十字光标（与 Pan 共存）
/// - 单指点击 = 仅 Drawing 模式确定锚点
@MainActor
public final class ChartGestureArbiter: NSObject, UIGestureRecognizerDelegate {

    /// 单指水平平移：(incrementalDeltaX, velocityX, phase)。见 plan「下游契约」表。
    public var onPan: ((CGFloat, CGFloat, GesturePhase) -> Void)?
    /// 捏合缩放：(scale, focus, phase)。
    public var onPinch: ((CGFloat, CGPoint, GesturePhase) -> Void)?
    /// 长按：(location, phase)。
    public var onLongPress: ((CGPoint, GesturePhase) -> Void)?
    /// 单指点击：location。仅 Drawing 模式触发。
    public var onTap: ((CGPoint) -> Void)?
    /// 两指上下滑动切周期：松手离散触发一次。（RFC-C：Coordinator 已不接此回调，two-finger 不再切周期）
    public var onTwoFingerSwipe: ((SwipeDirection) -> Void)?

    /// RFC-C 单指竖滑切周期（普通态，一甩一档）。
    public var onVerticalSwipe: ((SwipeDirection) -> Void)?
    /// RFC-C 十字光标模式：crosshairMode 下单指拖动移动光标的绝对触点。
    public var onCrosshairMove: ((CGPoint) -> Void)?
    /// RFC-C 十字光标模式下单指点击 → 退出。
    public var onCrosshairExit: (() -> Void)?
    /// RFC-E follow-up（tap-anywhere）：本面板**非持有**光标时，是否有「别的面板」持光标。
    /// Coordinator 注入（读共享 crosshairOwner）。未注入（直接消费者）→ 视为 false → 退化旧 tap 行为（源/行为兼容）。
    public var onShouldExitRemoteCrosshair: (() -> Bool)?

    /// Drawing 模式开关。true 时单指点击 fire onTap（落锚）。**不影响**单指 Pan / 两指缩放（1a-iv D32）。
    public var drawingMode: Bool = false
    /// RFC-C 十字光标模式开关（Coordinator 长按进入时设 true、点击退出时设 false）。
    /// true 时：单指拖动 → onCrosshairMove（不平移）；两指/捏合抑制（整图冻结）；单指点击 → onCrosshairExit。
    /// **false→true 转换立即 supersede 进行中的单指 pan**（发残量 + .cancelled 给 onPan）——防长按前已激活的
    /// 小幅 pan 的终止事件被 crosshairMode 早返吞掉、致 engine pan/deceleration 状态悬空（codex R5-M1）。
    public var crosshairMode: Bool = false {
        didSet {
            if crosshairMode && !oldValue { supersedeSinglePanForMultitouch(in: attachedView) }
        }
    }

    // 弱引用：两指仲裁需跨识别器读对方实时值；view 持有识别器，weak 避免 arbiter↔recognizer 环。
    private weak var pinchRecognizer: UIPinchGestureRecognizer?
    private weak var twoFingerPanRecognizer: UIPanGestureRecognizer?
    private weak var singlePanRecognizer: UIPanGestureRecognizer?   // 两指起手时确定性取消单指（R10 finding-1）
    // 已挂载的目标视图（weak）；attach 幂等性判定用（R6 finding-2）。
    private weak var attachedView: UIView?

    // 单指平移 per-gesture 状态（生命周期决策在纯函数 singlePanStep，本类仅存状态）。
    private var lastSinglePanTranslationX: CGFloat = 0
    private var singlePanLifecycle: SinglePanLifecycle = .idle

    // 两指 per-gesture 状态（生命周期决策在纯函数 twoFingerStep）。
    private var twoFingerState = TwoFingerState()

    public override init() { super.init() }

    /// 在目标视图上创建并挂载 5 个识别器，全部以 self 为 delegate。
    /// **幂等（R6 finding-2）**：同 view 重复调用 no-op；换 view 时先卸载本 arbiter 装的旧识别器并复位状态，
    /// 防重复 attach 装两套识别器导致回调翻倍（pan delta / deceleration / tap / 切周期重复）。
    public func attach(to view: UIView) {
        if attachedView === view { return }                 // 同 view 幂等
        if let old = attachedView {                          // 换 view：卸载本 arbiter 的旧识别器
            for r in (old.gestureRecognizers ?? []) where r.delegate === self {
                old.removeGestureRecognizer(r)
            }
        }
        resetGestureState()

        let single = UIPanGestureRecognizer(target: self, action: #selector(handleSinglePan(_:)))
        single.maximumNumberOfTouches = 1
        single.delegate = self

        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.delegate = self

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self

        // 两指优先级（spec L95）：靠 maxTouches=1（单指）/ minTouches=2（两指）+ 委托对 pan+pan 返回 false（互斥）覆盖
        // **干净两指起手**——两指同时落 → 两指/pinch 识别器赢。
        // ⚠️ 不用 `single.require(toFail: twoFinger/pinch)`：那会让正常单指拖动一直卡 `.possible` 等两指失败，毁掉
        //   图表主交互单指滚动的响应性（R9 finding-2）。**交错起手（先 1 指微动再落第 2 指）的两指优先级**为
        //   device-tuning 残留（运行时 UX，真机/Catalyst 验收；静态无法两全于单指响应性，见 plan 设计约束 #4）。

        view.addGestureRecognizer(single)
        view.addGestureRecognizer(twoFinger)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(tap)

        pinchRecognizer = pinch
        twoFingerPanRecognizer = twoFinger
        singlePanRecognizer = single
        attachedView = view
    }

    /// 两指/pinch 起手时确定性接管：取消进行中的单指 pan（R10 finding-1；不用 require(toFail:) 故不伤单指响应）。
    /// **同步**关闭生命周期（R11 finding）：经纯函数 `singlePanSupersede` 直接发 `.cancelled` + 复位状态，
    /// **不依赖** `isEnabled` toggle 的回调投递；toggle 仅作防御性物理取消（其后续 .cancelled 命中 idle 被吞，不双发）。
    private func supersedeSinglePanForMultitouch(in view: UIView?) {
        // 读单指识别器当前累积，结算时补末段残量（R13 finding-2 不丢接管前位移）。
        // 注意顺序：translation 必须在下方 isEnabled toggle 取消识别器之前读取（此处为 toggle 前，cumulative 为实时有效值）。
        let cumulative = singlePanRecognizer?.translation(in: view) ?? .zero
        let step = singlePanSupersede(lifecycle: singlePanLifecycle, cumulative: cumulative,
                                      lastTranslationX: lastSinglePanTranslationX)
        singlePanLifecycle = step.lifecycle
        lastSinglePanTranslationX = step.lastTranslationX
        for e in step.emissions { onPan?(e.deltaX, e.velocityX, e.phase) }
        if let s = singlePanRecognizer, s.isEnabled { s.isEnabled = false; s.isEnabled = true }
    }

    /// 复位 per-gesture 状态（attach 切 view 时调，防跨 view/代次状态串）。
    private func resetGestureState() {
        lastSinglePanTranslationX = 0
        singlePanLifecycle = .idle
        twoFingerState = TwoFingerState()
    }

    // MARK: - State → GesturePhase（平凡映射；possible 无业务相位）

    private func phase(from state: UIGestureRecognizer.State) -> GesturePhase? {
        switch state {
        case .began: return .began
        case .changed: return .changed
        case .ended: return .ended
        case .cancelled, .failed: return .cancelled
        case .possible: return nil
        @unknown default: return nil
        }
    }

    // MARK: - Handlers

    @objc private func handleSinglePan(_ g: UIPanGestureRecognizer) {
        guard let ph = phase(from: g.state) else { return }
        // RFC-C：crosshairMode 下单指 = 移动光标（整图冻结，不发 onPan/切周期）
        if crosshairMode {
            if ph == .began || ph == .changed { onCrosshairMove?(g.location(in: g.view)) }
            return
        }
        // 生命周期决策全在纯函数 singlePanStep：垂直/ambiguous → emission==nil 不触碰 reducer。
        // 1a-iv D32：画线模式**不再**截获单指 pan —— 水平走平移、竖直甩动走切周期，与非画线态同一条路径。
        let step = singlePanStep(phase: ph,
                                 cumulative: g.translation(in: g.view),
                                 velocityX: g.velocity(in: g.view).x,
                                 lifecycle: singlePanLifecycle,
                                 lastTranslationX: lastSinglePanTranslationX)
        singlePanLifecycle = step.lifecycle
        lastSinglePanTranslationX = step.lastTranslationX
        for e in step.emissions { onPan?(e.deltaX, e.velocityX, e.phase) }
        if let dir = step.periodSwipe { onVerticalSwipe?(dir) }   // RFC-C 单指竖滑切周期
    }

    // 两指 pan 与 pinch 两识别器都喂入同一 twoFingerStep 状态机（顺序无关）；各读对方实时值。
    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        if crosshairMode { return }                                           // RFC-C：光标模式整图冻结
        guard let ph = phase(from: g.state) else { return }
        if ph == .began { supersedeSinglePanForMultitouch(in: g.view) }   // 第 2 指落 → 取消单指（R10 finding-1）
        let scale = pinchRecognizer?.scale ?? 1.0
        let focus = pinchRecognizer?.location(in: g.view) ?? g.location(in: g.view)
        emitTwoFinger(twoFingerStep(source: .pan, phase: ph, scale: scale, translation: g.translation(in: g.view),
                                    state: twoFingerState), focus: focus)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        if crosshairMode { return }                                           // RFC-C：光标模式不缩放
        guard let ph = phase(from: g.state) else { return }
        if ph == .began { supersedeSinglePanForMultitouch(in: g.view) }   // 捏合起手 → 取消单指（R10 finding-1）
        let translation = twoFingerPanRecognizer?.translation(in: g.view) ?? .zero
        emitTwoFinger(twoFingerStep(source: .pinch, phase: ph, scale: g.scale, translation: translation,
                                    state: twoFingerState), focus: g.location(in: g.view))
    }

    private func emitTwoFinger(_ result: TwoFingerStepResult, focus: CGPoint) {
        twoFingerState = result.state
        switch result.emission {
        case .pinch(let s, let p): onPinch?(s, focus, p)
        case .switchPeriod(let dir): onTwoFingerSwipe?(dir)
        case .none: break
        }
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard let ph = phase(from: g.state) else { return }
        onLongPress?(g.location(in: g.view), ph)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        // tap-anywhere：远端光标存在时优先退（先于 drawing，spec-R3-M1）；onTap 仍为 drawing 锚点回调（spec-R5-H1）。
        switch CrosshairTapResolver.resolve(localCrosshairMode: crosshairMode,
                                            drawingMode: drawingMode,
                                            remoteOwnerPresent: onShouldExitRemoteCrosshair?() ?? false) {
        case .exitLocal, .requestGlobalExit: onCrosshairExit?()              // 本地退 / 退远端：均经 onCrosshairExit
        case .drawingAnchor:                 onTap?(g.location(in: g.view))  // drawing 锚点：行为不变
        case .noop:                          break
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    /// 长按+Pan 共存（spec 仲裁表）；Pinch+两指Pan 共存（供 classifyTwoFingerGesture 同时拿 scale+translation 仲裁）；
    /// **单指Pan+两指Pan 共存**（R15 finding-1：让两指 pan 在单指已识别时仍能 `.began` → 触发 `supersedeSinglePanForMultitouch`
    /// 同步取消单指、确定性接管；否则委托互斥会挡死两指 began 使切周期无法发生）。
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let pair = [gestureRecognizer, other]
        let hasLongPress = pair.contains { $0 is UILongPressGestureRecognizer }
        let hasPinch = pair.contains { $0 is UIPinchGestureRecognizer }
        let hasPan = pair.contains { $0 is UIPanGestureRecognizer }
        let hasSinglePan = pair.contains { $0 === singlePanRecognizer }
        let hasTwoFingerPan = pair.contains { $0 === twoFingerPanRecognizer }
        if hasLongPress && hasPan { return true }
        if hasPinch && hasPan { return true }
        if hasSinglePan && hasTwoFingerPan { return true }   // 让两指 pan 能 began 触发 supersede 接管
        return false
    }
}
#endif

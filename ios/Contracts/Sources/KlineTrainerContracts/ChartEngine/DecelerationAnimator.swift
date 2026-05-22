// Kline Trainer Swift Contracts — C2 DecelerationAnimator（v1.3：offset 更新必须派发 action）
// Spec: kline_trainer_modules_v1.4.md §C2 + kline_trainer_plan_v1.5.md §3
// Plan: docs/superpowers/plans/2026-05-22-pr-c2-deceleration-animator.md

import Foundation
import CoreGraphics
import QuartzCore   // CACurrentMediaTime（两平台）；CADisplayLink（UIKit）
#if canImport(UIKit)
import UIKit
#endif

/// 帧驱动抽象（internal 测试缝）。每帧回调 `(dt) -> Bool`：返回 false 表示应停止
/// （owner 已释放 / 代次失效），实现据此自失活。可注入 fake 做确定性单测（DD-1 / DD-5）。
@MainActor
protocol FrameDriving: AnyObject {
    func invalidate()
}

/// C2 减速动画器：经注入工厂创建每平台帧驱动的惯性滚动。纯物理在 `DecelerationModel`。
///
/// 用法（C8 / E5 中）：
/// ```
/// animator.onUpdate = { [weak dispatcher] delta in
///     dispatcher?.dispatch(.offsetApplied(deltaPixels: delta))
/// }
/// ```
///
/// 防泄漏（DD-3 / R1-F1）：注入的 onTick 闭包以 `[weak self]` 持本对象；owner 释放后下一帧
/// 闭包返回 false，`RealFrameDriver` 自失活——无需 deinit、无独立 proxy。
/// 防 stale 回调（DD-3 / R2-F1）：`currentGeneration` 每 start 自增，闭包捕获该代次并校验。
@MainActor
public final class DecelerationAnimator {

    /// 每帧 delta offset（pt）。消费者**必须**封装为 `.offsetApplied(deltaPixels:)` 派发给 reducer 来移动面板，
    /// 不可绕过 reducer 直接改写面板偏移状态（spec §C2 v1.3 闸门 #2 F2）。
    /// （注：本类型不持有也不引用任何面板状态类型，故无法直接改写其 offset——验收 #7 以此为不变量。）
    public var onUpdate: ((CGFloat) -> Void)?

    /// 减速**自然结束**（速度 < 阈值 / 后台恢复 dt 异常）时触发一次。
    /// 外部 `stop()` / `resetOnSceneActive()` **不**触发（调用方主动终止）。
    public var onFinish: (() -> Void)?

    private var model: DecelerationModel

    /// 运行态单一真相（跨平台）。供测试断言；不由 driver 派生。
    private(set) var isDecelerating = false

    /// run identity：每次 start 自增；忽略 stale 旧驱动回调（R2-F1）。
    private(set) var currentGeneration = 0

    private var driver: FrameDriving?
    private let makeDriver: (@escaping @MainActor (CGFloat) -> Bool) -> FrameDriving

    public init(friction: CGFloat = 0.94, stopThreshold: CGFloat = 0.5) {
        self.model = DecelerationModel(friction: friction, stopThreshold: stopThreshold)
        self.makeDriver = { onTick in RealFrameDriver(onTick: onTick) }
    }

    /// 测试缝：注入帧驱动工厂（默认 = 真实平台驱动）。
    init(friction: CGFloat = 0.94, stopThreshold: CGFloat = 0.5,
         makeDriver: @escaping (@escaping @MainActor (CGFloat) -> Bool) -> FrameDriving) {
        self.model = DecelerationModel(friction: friction, stopThreshold: stopThreshold)
        self.makeDriver = makeDriver
    }

    /// 以初速度启动惯性滚动。重复调用会重置（先 stop 失活旧驱动 + 代次自增 + 归位）。
    public func start(initialVelocity: CGFloat) {
        stop()
        // DD-8 / R1-F2 + 自审 I1：非有限或低于停止阈值的初速度不算惯性滚动 → no-op（不建驱动、不触发 onFinish）
        guard initialVelocity.isFinite, abs(initialVelocity) >= model.stopThreshold else { return }
        currentGeneration &+= 1
        let gen = currentGeneration
        model.velocity = initialVelocity
        isDecelerating = true
        driver = makeDriver { [weak self] dt in
            // owner 已释放 / 代次失效 → 返回 false 令驱动自失活（DD-3）
            guard let self, self.currentGeneration == gen else { return false }
            self.handleTick(dt: dt, generation: gen)
            return self.isDecelerating
        }
    }

    /// 外部主动停止（如 drawing 激活防 stale 漂移，spec Reducer.swift:112）。静默，不触发 onFinish。
    public func stop() {
        isDecelerating = false
        model.velocity = 0
        driver?.invalidate()
        driver = nil
    }

    /// 由 E5.onSceneActivated() 调用：scene 恢复时复位，防后台 dt 爆炸跳帧。静默。
    public func resetOnSceneActive() {
        stop()
    }

    /// 同步拆解（branch-diff R3）：owner 释放本对象时立即失活帧驱动，不依赖后续 tick
    /// （帧暂停/后台时后续 tick 可能不来 → 否则 run-loop 持有的 driver 会滞留）。
    /// `isolated deinit`（SE-0371）使 deinit 在 main actor 运行，可调 @MainActor 的 `invalidate()`。
    isolated deinit {
        driver?.invalidate()
    }

    // MARK: - 测试缝（internal，经 @testable import 可见）

    /// 推进一帧并派发回调；代次不符直接忽略（R2-F1）。
    func handleTick(dt: CGFloat, generation: Int) {
        guard isDecelerating, generation == currentGeneration else { return }
        switch model.advance(dt: dt) {
        case .move(let delta):
            onUpdate?(delta)
        case .stop:
            isDecelerating = false
            driver?.invalidate()
            driver = nil
            onFinish?()
        }
    }
}

/// 真实平台帧驱动（internal）：iOS/Catalyst = CADisplayLink；plain macOS = Timer。
/// 是平台帧对象的 target；`onTick` 返回 false 时自失活（打断 runloop 强持有，DD-3）。
@MainActor
final class RealFrameDriver: FrameDriving {
    private let onTick: @MainActor (CGFloat) -> Bool
    private var lastTimestamp: CFTimeInterval
    #if canImport(UIKit)
    private var link: CADisplayLink?
    #else
    private var timer: Timer?
    #endif

    init(onTick: @escaping @MainActor (CGFloat) -> Bool) {
        self.onTick = onTick
        // 记录创建时刻（CACurrentMediaTime 与 CADisplayLink.timestamp 同 media 时钟）；
        // 使首帧 dt 反映 start→首帧 的真实经过（含停顿/后台），不漏 dt>=1.0 停止 guard（branch-diff R1/R2）。
        self.lastTimestamp = CACurrentMediaTime()
        #if canImport(UIKit)
        let l = CADisplayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        #else
        let t = Timer(timeInterval: 1.0 / 120.0, target: self,
                      selector: #selector(stepTimer), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        #endif
    }

    func invalidate() {
        #if canImport(UIKit)
        link?.invalidate()
        link = nil
        #else
        timer?.invalidate()
        timer = nil
        #endif
    }

    /// 帧间**真实经过时间**（秒）。用真实经过时间（而非 CADisplayLink 帧预算 targetTimestamp-timestamp），
    /// 让 `DecelerationModel.advance` 的大-dt 后台/停顿停止 guard 在 run loop 停顿后真正生效（branch-diff R1/R2）。
    nonisolated static func elapsedDelta(now: CFTimeInterval, last: CFTimeInterval) -> CFTimeInterval {
        now - last
    }

    #if canImport(UIKit)
    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = Self.elapsedDelta(now: now, last: lastTimestamp)
        lastTimestamp = now
        if !onTick(CGFloat(dt)) { invalidate() }
    }
    #else
    @objc private func stepTimer() {
        let now = CACurrentMediaTime()
        let dt = Self.elapsedDelta(now: now, last: lastTimestamp)
        lastTimestamp = now
        if !onTick(CGFloat(dt)) { invalidate() }
    }
    #endif
}

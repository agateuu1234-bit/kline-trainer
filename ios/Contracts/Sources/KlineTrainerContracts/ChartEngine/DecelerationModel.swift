// Kline Trainer Swift Contracts — C2 DecelerationModel（纯减速物理 + 数值校验）
// Spec: kline_trainer_modules_v1.4.md §C2 + kline_trainer_plan_v1.5.md §3
// Plan: docs/superpowers/plans/2026-05-22-pr-c2-deceleration-animator.md

import Foundation
import CoreGraphics

/// 纯减速物理：基于 deltaTime 的帧率无关指数衰减。
/// 无 UIKit / 无 run loop —— 可确定性单测。`DecelerationAnimator` 持有它做实际驱动。
struct DecelerationModel: Equatable, Sendable {

    /// 单帧推进结果。
    enum Outcome: Equatable, Sendable {
        case move(delta: CGFloat)   // 继续：派发 delta offset（pt）
        case stop                   // 终止：调用方应失活 driver + 触发 onFinish
    }

    let friction: CGFloat        // 每 refInterval 的衰减系数（默认 0.94）
    let stopThreshold: CGFloat   // 停止阈值（pt/s，默认 0.5）
    let refInterval: CGFloat     // 参考帧间隔（默认 1/120）
    var velocity: CGFloat

    /// boundary-aware 累加器的时间余量（跨 `advance(dt:boundaryDistance:)` 调用携带）。
    /// 既有 `advance(dt:)` 路径不使用（默认 0）。spec 方案 A（帧率无关回弹）。
    var carry: CGFloat = 0

    init(friction: CGFloat = 0.94,
         stopThreshold: CGFloat = 0.5,
         refInterval: CGFloat = 1.0 / 120.0,
         velocity: CGFloat = 0) {
        // DD-8 / R1-F2：非法 config 回退默认，杜绝 pow(负数,分数)=NaN / friction>=1 永不停
        self.friction = (friction.isFinite && friction > 0 && friction < 1) ? friction : 0.94
        self.stopThreshold = (stopThreshold.isFinite && stopThreshold > 0) ? stopThreshold : 0.5
        self.refInterval = (refInterval.isFinite && refInterval > 0) ? refInterval : (1.0 / 120.0)
        self.velocity = velocity
    }

    /// 推进一帧。`dt` 单位为秒（来自帧驱动 timestamp 差）。
    /// 按 refInterval 细分积分，使总位移在不同帧切分下一致（frame-rate independent offset，branch-diff R4-F1）。
    mutating func advance(dt: CGFloat) -> Outcome {
        // 后台恢复 / 异常 dt：直接停（plan §3 L63-67）
        guard dt > 0, dt < 1.0 else {
            velocity = 0
            return .stop
        }
        var remaining = dt
        var totalDelta: CGFloat = 0
        while remaining > 1e-9 {
            let step = Swift.min(remaining, refInterval)
            // 帧率无关指数衰减（plan §3 L68）
            velocity *= pow(friction, step / refInterval)
            // DD-8 / R1-F2 defense-in-depth：非有限速度终止，绝不外溢 NaN/inf delta
            guard velocity.isFinite else {
                velocity = 0
                return .stop
            }
            // 停止阈值（plan §3 L69-72）
            if abs(velocity) < stopThreshold {
                velocity = 0
                break
            }
            totalDelta += velocity * step
            remaining -= step
        }
        // 细分中途停下：派发已累积位移（若有），由下一帧 advance 返回 .stop
        if velocity == 0 {
            return totalDelta != 0 ? .move(delta: totalDelta) : .stop
        }
        return .move(delta: totalDelta)
    }

    /// 单帧 boundary-aware 推进结果。
    enum BoundaryOutcome: Equatable, Sendable {
        case moved(delta: CGFloat)                                            // 推进 delta（可为 0），仍在界内
        case stopped(delta: CGFloat)                                          // 界内自然停（速度 < 阈值）；delta 可为 0
        case crossed(delta: CGFloat, velocity: CGFloat, remainingTime: CGFloat) // 抵 edge：delta 恰到 edge；velocity=跨边速度；remainingTime=帧相对剩余
    }

    /// **持久固定步累加器**（spec 方案 A，帧率无关回弹）：同 damp-then-move 律，但**固定 refInterval 步、
    /// 跨 `advance` 调用携带余量 `carry`** → 物理推进与帧边界解耦 ⇒ 任意 dt 分区（不规则/亚-ref）下到达边界的
    /// 速度/时刻**精确无关**（P3 端到端）。`boundaryDistance`（带符号，= edge−当前offset）；跨边在固定步内解析
    /// 求子时、报帧相对 `remainingTime`。**注**：与既有 `advance(dt:)` 仅相差 sub-refInterval 余量延迟（P4 within-substep）。
    mutating func advance(dt: CGFloat, boundaryDistance: CGFloat) -> BoundaryOutcome {
        guard dt > 0, dt < 1.0 else { velocity = 0; carry = 0; return .stopped(delta: 0) }
        carry += dt
        // ULP-scaled 容差（codex Plan-R10-F1）：`carry += dt` 累积浮点误差，使 carry 在固定步整数倍处可差几 ULP，
        // 裸 `carry >= refInterval` 会丢一固定步 → 破坏分区不变（如 elapsed=5ref 在 dt=2.5ref 分区只跑 4 步）。
        let tol = refInterval * 1e-9
        var totalDelta: CGFloat = 0
        while carry >= refInterval - tol {                        // 容差防丢步
            velocity *= friction                                  // 整 refInterval 步衰减（step == refInterval）
            guard velocity.isFinite else { velocity = 0; carry = 0; return .stopped(delta: totalDelta) }
            if abs(velocity) < stopThreshold {
                velocity = 0; carry = 0
                return totalDelta != 0 ? .moved(delta: totalDelta) : .stopped(delta: 0)
            }
            let need = boundaryDistance - totalDelta
            let stepDelta = velocity * refInterval                // 固定步内匀速（velocity 已步首衰减）
            // 跨边：`need==0`（offset 恰在 outward edge → 立即跨，tWithin=0，用**已衰减**速度，与 edge-ε 极限连续，
            // 消除 exact-edge 用满速 vs edge-ε 用衰减速度的回弹幅度跳变，codex R12-F2）；或 need 与 velocity 同向且本步够达边。
            if (need == 0 && velocity != 0)
                || (need != 0 && (need > 0) == (velocity > 0) && abs(stepDelta) >= abs(need)) {
                let tWithin = (need == 0) ? 0 : need / velocity   // ∈ [0, refInterval]
                let remainingTime = Swift.max(0, carry - tWithin) // 跨边后本次 advance 剩余物理时间（含未消耗余量）
                carry = 0
                return .crossed(delta: boundaryDistance, velocity: velocity, remainingTime: remainingTime)
            }
            totalDelta += stepDelta
            carry -= refInterval
        }
        if carry < tol { carry = 0 }                              // clamp 微小（含 -tol..tol）残留，防累积偏差/下次丢步
        return .moved(delta: totalDelta)                          // 余量 carry < refInterval 留下次（本帧 totalDelta 可能为 0）
    }
}

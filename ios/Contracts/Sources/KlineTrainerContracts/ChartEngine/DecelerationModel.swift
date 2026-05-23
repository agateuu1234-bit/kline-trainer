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
}

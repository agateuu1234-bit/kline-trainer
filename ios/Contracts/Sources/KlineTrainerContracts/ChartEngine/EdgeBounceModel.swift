// Kline Trainer Swift Contracts — Wave 3 顺位 11 EdgeBounceModel（纯边缘回弹物理）
// Spec: docs/superpowers/specs/2026-06-11-pr-wave3-11-edge-bounce-design.md
// Plan: docs/superpowers/plans/2026-06-11-pr-wave3-11-edge-bounce.md
//
// 组件层隔离：注入 offset 边界（分离端点），零几何/零 UIKit。减速段复用 DecelerationModel
// damp-then-move（boundary-aware）；越界段临界阻尼解析弹簧（ζ=1）。实时可见接线属 residual W3-11-R1。

import Foundation
import CoreGraphics

/// 动画器与 bounce 模型共享的单帧结果（原子 snap+stop 所需，spec R3-F1/R4-F1）。
enum FrameOutcome: Equatable, Sendable {
    case move(delta: CGFloat)
    case finish(finalDelta: CGFloat?, notifyFinish: Bool)   // finalDelta=该 tick 全帧位移；notifyFinish=是否触发 onFinish
}

struct EdgeBounceModel: Equatable, Sendable {

    // 默认弹簧参数（plan-stage 选定）
    static let defaultStiffness: CGFloat = 200
    static let defaultPosTol: CGFloat = 0.5
    static let defaultVelTol: CGFloat = 5.0
    /// round-trip 安全的固定亚像素物理上限（init 可操作性 + springStep 动态校验共用，codex Plan-R15-F1/R18-F1）。
    static let roundTripCap: CGFloat = 1e-3

    // —— config（不可变）——
    private let minOffset: CGFloat
    private let maxOffset: CGFloat
    private let omega: CGFloat            // √stiffness
    private let posTol: CGFloat
    private let velTol: CGFloat
    private let geometryValid: Bool

    // —— state ——
    private var decel: DecelerationModel
    private var offset: CGFloat
    private var velocity: CGFloat
    private var springEdge: CGFloat
    private enum Phase: Equatable, Sendable { case decelerating, springing }
    private var phase: Phase

    init(initialVelocity: CGFloat, offset: CGFloat,
         minOffset: CGFloat, maxOffset: CGFloat,
         friction: CGFloat = 0.94, stopThreshold: CGFloat = 0.5,
         stiffness: CGFloat = EdgeBounceModel.defaultStiffness,
         posTol: CGFloat = EdgeBounceModel.defaultPosTol,
         velTol: CGFloat = EdgeBounceModel.defaultVelTol) {
        let boundsValid = minOffset.isFinite && maxOffset.isFinite
            && minOffset <= maxOffset && offset.isFinite
        let lo = boundsValid ? minOffset : 0
        let hi = boundsValid ? maxOffset : 0
        // 净化非有限速度（codex R10-F2）：几何有效时不因坏速度 strand 越界 offset
        let v = initialVelocity.isFinite ? initialVelocity : 0
        // 先定相 + springEdge（用校验后 lo/hi）
        let ph: Phase
        let edge: CGFloat
        if boundsValid, offset > hi {
            ph = .springing; edge = hi
        } else if boundsValid, offset < lo {
            ph = .springing; edge = lo
        } else {
            ph = .decelerating; edge = (v >= 0) ? hi : lo
        }
        // 可操作性（codex Plan-R3-F1/R11-F1/R12-F1/R13-F1）：到所选 edge 的归一修正须 **round-trippable**——
        // `offset + (edge−offset) ≈ edge`。**减速相也查**（R12-F1：减速跨边后 snap model 至 edge，而累积 delta 因量级悬殊
        // 使 consumer 失步；减速中 offset 仅更靠近 edge，init 查已足）。**用 ULP-scaled 容差**（R13-F1：裸 `==` 会误拒
        // 普通有限几何如 offset=-100/edge=-35.9 的 1-ULP 差；而量级悬殊失步的重构误差 ≈ |edge|（整端丢失）≫ 容差）。
        let correction = edge - offset
        let reconstructed = offset + correction
        // **固定物理上限容差（不随 edge 量级增长，codex Plan-R13-F1/R14-F1/R15-F1）**：
        // `8*edge.ulp` 在大 edge 处仍膨胀（edge=-1e21 → 容差 ~1e6 点）会误收百万点失步。改为**固定亚像素 cap**
        // `1e-3` 点 + **fail-closed 当 edge 表示分辨率（8 ULP）超 cap**（edge 大到无法亚像素精确归一即拒）。
        // ∴ 容差有上界、不可被更大 edge 撑开；普通几何（|edge| ≪ ~10¹¹ 点）的 1-ULP 噪声远小于 cap → 不误拒。
        let roundTripTol = EdgeBounceModel.roundTripCap
        let operable = boundsValid && correction.isFinite
            && 8 * edge.ulp <= roundTripTol
            && abs(reconstructed - edge) <= roundTripTol

        self.geometryValid = operable
        self.minOffset = lo
        self.maxOffset = hi
        let k = (stiffness.isFinite && stiffness > 0) ? stiffness : EdgeBounceModel.defaultStiffness
        self.omega = sqrt(k)
        self.posTol = (posTol.isFinite && posTol > 0) ? posTol : EdgeBounceModel.defaultPosTol
        self.velTol = (velTol.isFinite && velTol > 0) ? velTol : EdgeBounceModel.defaultVelTol
        self.velocity = v
        self.offset = offset
        self.decel = DecelerationModel(friction: friction, stopThreshold: stopThreshold, velocity: v)
        self.phase = ph
        self.springEdge = edge
    }

    /// 是否值得启动一次 run（几何无效 → 不运行；界内且亚阈速度 → 无可动 → 不运行）。
    var shouldRun: Bool {
        guard geometryValid else { return false }
        if phase == .springing { return true }                 // 已越界 → 需回弹
        return abs(velocity) >= decel.stopThreshold            // 界内 → 需有惯性
    }

    // 测试缝（internal，@testable 可见）
    var debugOffset: CGFloat { offset }
    var debugVelocity: CGFloat { velocity }
    /// 越过最近被违反边界的量（界内 = 0；正 = 越上界，负 = 越下界）。供峰值穿透测量。
    var debugOverscroll: CGFloat {
        if offset > maxOffset { return offset - maxOffset }
        if offset < minOffset { return offset - minOffset }
        return 0
    }

    mutating func advance(dt: CGFloat) -> FrameOutcome {
        let frameEntry = offset
        guard geometryValid else { return .finish(finalDelta: nil, notifyFinish: true) }
        // abnormal dt（含 dt≥1.0 后台恢复）：归位（越界）+ 触发 onFinish（与既有契约一致，codex R6-F3）。
        // 越界经 settleFinish（含 delta 有限性 guard，codex Plan-R3-F1：opposite-extreme 已在 init 拒为 inert）。
        guard dt > 0, dt < 1.0 else {
            switch phase {
            case .springing:
                offset = springEdge; velocity = 0
                return settleFinish(frameEntry: frameEntry)
            case .decelerating:
                return .finish(finalDelta: nil, notifyFinish: true)
            }
        }
        switch phase {
        case .decelerating: return advanceDecel(dt: dt, frameEntry: frameEntry)
        case .springing:    return springStep(tau: dt, frameEntry: frameEntry)
        }
    }

    // 减速相：boundary-aware；跨边即 seed 弹簧于 edge、对剩余帧时间走弹簧。
    // 起点恰在 outward edge（boundaryDistance==0）由 boundary-aware 的 `need==0` 分支处理（立即跨、用已衰减速度，
    // 与 edge-ε 极限连续，codex R1-F1/R12-F2）——故此处**不再**特判 atOrPastOutwardEdge（避免幅度跳变）。
    private mutating func advanceDecel(dt: CGFloat, frameEntry: CGFloat) -> FrameOutcome {
        let edge = (velocity >= 0) ? maxOffset : minOffset
        switch decel.advance(dt: dt, boundaryDistance: edge - offset) {
        case .moved(let d):
            offset += d
            return .move(delta: offset - frameEntry)              // 含 deferred-move 帧（保 move-then-stop，codex R9-F1）
        case .stopped(let d):
            offset += d
            let total = offset - frameEntry
            return .finish(finalDelta: total == 0 ? nil : total, notifyFinish: true)
        case .crossed(_, let crossVel, let remaining):
            offset = edge                                         // 精确钉 edge（overscroll=0）
            velocity = crossVel
            springEdge = edge
            phase = .springing
            return springStep(tau: remaining, frameEntry: frameEntry)   // 消耗本帧剩余时间
        }
    }

    // 弹簧相：临界阻尼 ζ=1 解析闭式；首次过边 clamp + 渐近 settle + 非有限防御
    private mutating func springStep(tau: CGFloat, frameEntry: CGFloat) -> FrameOutcome {
        let x = offset - springEdge
        let v = velocity
        let A = x
        let B = v + omega * x
        // 首次过边 zero-crossing（codex R1-F2）：x 跨 0 → clamp + settle
        if B.isFinite, B != 0 {
            let tzc = -A / B
            if tzc > 0, tzc <= tau {
                offset = springEdge; velocity = 0
                return settleFinish(frameEntry: frameEntry)
            }
        }
        // 解析推进 tau（任意分区精确，spec P3）
        let e = exp(-omega * tau)
        let xNew = (A + B * tau) * e
        let vNew = (B * (1 - omega * tau) - omega * A) * e
        // 派生值/重构 offset/delta 非有限 → 钉 edge 终止（codex Plan-R1-F2/R2-F1）。
        let newOffset = springEdge + xNew
        let moveDelta = newOffset - frameEntry
        // **动态 round-trip 安全（codex Plan-R18-F1）**：init 只校验起点 offset；但 huge **velocity**（如 v=MAX/2）可使
        // 弹簧生成 finite-but-enormous offset（~6e305，渲染器 offset→Int 转换 trap + reset 归一 `edge−offset` 丢 edge 致失步）。
        // 故每帧验：① delta 重构 `frameEntry+moveDelta≈newOffset`；② 该 offset 未来归一可逆 `newOffset+(edge−newOffset)≈edge`。
        // 任一失败（offset 大到无法亚像素归一）→ **不暴露不安全中间态**，钉 edge 终止。
        let cap = EdgeBounceModel.roundTripCap
        let safe = xNew.isFinite && vNew.isFinite && newOffset.isFinite && moveDelta.isFinite
            && abs((frameEntry + moveDelta) - newOffset) <= cap
            && abs((newOffset + (springEdge - newOffset)) - springEdge) <= cap
        guard safe else {
            offset = springEdge; velocity = 0
            return settleFinish(frameEntry: frameEntry)
        }
        offset = newOffset
        velocity = vNew
        // 渐近 settle-threshold（≤1 帧有界回调时序，spec R7-F2）
        if abs(xNew) < posTol && abs(vNew) < velTol {
            offset = springEdge; velocity = 0
            return settleFinish(frameEntry: frameEntry)
        }
        return .move(delta: moveDelta)
    }

    /// 终止时构造 finalDelta（钉 edge 后调）；delta 非有限或为 0 → nil（绝不外溢 inf/NaN）。
    private func settleFinish(frameEntry: CGFloat) -> FrameOutcome {
        let d = offset - frameEntry
        return .finish(finalDelta: (d.isFinite && d != 0) ? d : nil, notifyFinish: true)
    }

    /// 后台/reset 归位：越界 → 钉 edge，返回归一 delta（nil 若无需归位 / delta 非有限）。
    mutating func normalizeToEdgeDelta() -> CGFloat? {
        guard phase == .springing else { return nil }
        let prev = offset
        offset = springEdge; velocity = 0
        let d = offset - prev
        return (d.isFinite && d != 0) ? d : nil   // codex Plan-R3-F1：绝不外溢非有限 delta
    }
}

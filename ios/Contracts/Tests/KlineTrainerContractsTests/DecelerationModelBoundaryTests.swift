import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("DecelerationModel boundary-aware")
struct DecelerationModelBoundaryTests {

    private let f: CGFloat = 0.94
    private let ref: CGFloat = 1.0 / 120.0
    private let thr: CGFloat = 0.5

    // A0. ref 对齐时累加器 == advance(dt:) 逐帧（dt==refInterval 整步，无 partial 余量 → exact parity）
    @Test("ref-aligned: accumulator matches advance(dt:) frame-by-frame")
    func refAlignedParity() {
        var plain = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        var bounded = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        var safety = 0
        while true {
            safety += 1; #expect(safety < 5000)
            let p = plain.advance(dt: ref)
            let b = bounded.advance(dt: ref, boundaryDistance: 10_000)   // 边界远（永不跨边）
            switch (p, b) {
            case (.move(let dp), .moved(let db)): #expect(abs(dp - db) < 1e-12)
            case (.stop, .stopped(let db)): #expect(db == 0); return     // 两者同帧终止
            default: Issue.record("outcome mismatch: \(p) vs \(b)"); return
            }
        }
    }

    // A1. **累加器分区不变（方案 A 核心）**：同 elapsed、不同 dt 分区（ref / ref/3 / 不规则）→ velocity + 累计位移一致。
    @Test("accumulator is partition-invariant over equal elapsed time")
    func accumulatorPartitionInvariant() {
        func runFor(elapsed: CGFloat, dt: CGFloat) -> (vel: CGFloat, dist: CGFloat) {
            var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
            var dist: CGFloat = 0; var t: CGFloat = 0
            while t < elapsed - 1e-9 {
                let step = Swift.min(dt, elapsed - t)
                switch m.advance(dt: step, boundaryDistance: 1e9) {   // 边界极远（永不跨边）
                case .moved(let d), .stopped(let d): dist += d
                case .crossed: Issue.record("unexpected crossing"); return (m.velocity, dist)
                }
                t += step
            }
            return (m.velocity, dist)
        }
        let elapsed = 5 * ref
        let a = runFor(elapsed: elapsed, dt: ref)          // 基准：恰 5 固定步
        // 含 codex Plan-R10-F1 反例 dt=2.5ref（浮点累积曾丢一步）+ 整数倍邻域（ULP 容差稳健性）
        for dt in [ref / 3, 2.5 * ref, ref * 0.999999, ref * 1.000001, 5 * ref] {
            let r = runFor(elapsed: elapsed, dt: dt)
            #expect(abs(a.vel - r.vel) < 1e-6 && abs(a.dist - r.dist) < 1e-6)   // 同 5 固定步 → state 一致
        }
    }

    // A2. within-substep parity：累加器总滑行距离与 `advance(dt:)` 差 < 一个固定步位移（余量延迟，P4）。
    @Test("accumulator total glide distance within one substep of DecelerationModel")
    func accumulatorWithinSubstepParity() {
        var acc = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        var accDist: CGFloat = 0
        while true {
            switch acc.advance(dt: ref / 3, boundaryDistance: 1e9) {   // 非 ref 对齐 → 余量延迟显现
            case .moved(let d), .stopped(let d): accDist += d
            case .crossed: break
            }
            if acc.velocity == 0 { break }
        }
        var plain = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        var plainDist: CGFloat = 0
        while case .move(let d) = plain.advance(dt: ref) { plainDist += d }
        #expect(abs(accDist - plainDist) < 1000 * ref)     // < 一个固定步位移（≈8.3pt @v1000）
    }

    // B. 跨边：停在 edge，delta == boundaryDistance，crossingVelocity 满足 damp-then-move
    @Test("crossing stops at edge with frame-relative remainder (first substep)")
    func crossingFirstSubstep() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        // 单 refInterval 帧；首子步速度 = 1000*0.94 = 940，子步位移 = 940*ref ≈ 7.833pt
        // edge 5pt away → 在首子步内跨边
        let out = m.advance(dt: ref, boundaryDistance: 5)
        guard case .crossed(let delta, let vel, let remaining) = out else {
            Issue.record("expected .crossed, got \(out)"); return
        }
        #expect(abs(delta - 5) < 1e-12)                 // delta 恰好到 edge
        #expect(abs(vel - 940) < 1e-6)                  // 跨边子步速度（已衰减）
        // tWithin = need/vel = 5/940；remaining = ref - tWithin
        let tWithin: CGFloat = 5.0 / 940.0
        #expect(abs(remaining - (ref - tWithin)) < 1e-9)
    }

    // C. 多子步跨边帧无关（codex R10-F1）：edge 落第 2 子步 → 60Hz vs 120Hz 的 remaining 一致
    @Test("multi-substep crossing remainder is frame-rate independent")
    func crossingMultiSubstepFrameInvariant() {
        // edge 10pt away、v=1000。120Hz: dt=ref（1 子步，位移 7.83pt < 10 → 不跨边，返回 .moved）。
        // 60Hz: dt=2*ref（2 子步，累计 ≈ 7.83+7.36 ≈ 15.19pt → 第 2 子步跨边）。
        // 关键：把 120Hz 拆成两帧（各 ref）与 60Hz 一帧（2ref）比较「跨边时 offset 起点 + remaining」。
        // 120Hz 两帧：第 1 帧 .moved(7.83)；第 2 帧从剩余距离 (10-7.83)=2.17 跨边。
        var hz120 = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        var acc120: CGFloat = 0
        guard case .moved(let d1) = hz120.advance(dt: ref, boundaryDistance: 10) else {
            Issue.record("120Hz frame1 expected .moved"); return
        }
        acc120 += d1
        guard case .crossed(_, let v120, let rem120) =
                hz120.advance(dt: ref, boundaryDistance: 10 - acc120) else {
            Issue.record("120Hz frame2 expected .crossed"); return
        }
        // 60Hz 一帧（dt=2ref），同初值
        var hz60 = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        guard case .crossed(_, let v60, let rem60) = hz60.advance(dt: 2 * ref, boundaryDistance: 10) else {
            Issue.record("60Hz expected .crossed"); return
        }
        // 跨边速度 = 第 2 子步速度（两路均为 1000*0.94^2），remaining（帧相对、对齐到跨边后）一致
        #expect(abs(v120 - v60) < 1e-6)
        #expect(abs(rem120 - rem60) < 1e-9)
    }

    // D. 反向（负速度）跨下边界
    @Test("negative velocity crosses lower edge")
    func crossingNegative() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: -1000)
        let out = m.advance(dt: ref, boundaryDistance: -5)   // edge 5pt 在负方向
        guard case .crossed(let delta, let vel, _) = out else {
            Issue.record("expected .crossed, got \(out)"); return
        }
        #expect(abs(delta - (-5)) < 1e-12)
        #expect(vel < 0)
    }

    // E. 边界在运动反方向 → 不跨边（normal decel）
    @Test("edge behind motion does not cross")
    func edgeBehindNoCross() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        let out = m.advance(dt: ref, boundaryDistance: -5)   // 正速度但 edge 在负方向
        guard case .moved = out else { Issue.record("expected .moved, got \(out)"); return }
    }

    // F. abnormal dt → stopped(0)（与 advance(dt:) dt-guard 平行）
    @Test("abnormal dt stops with no movement")
    func abnormalDt() {
        for bad: CGFloat in [0, -0.1, 1.0, 2.0] {
            var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
            #expect(m.advance(dt: bad, boundaryDistance: 5) == .stopped(delta: 0))
            #expect(m.velocity == 0)
        }
    }
}

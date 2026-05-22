import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("DecelerationModel")
struct DecelerationModelTests {

    private let f: CGFloat = 0.94
    private let ref: CGFloat = 1.0 / 120.0
    private let thr: CGFloat = 0.5

    // 1. dt == refInterval 时速度恰好 *= friction，且 move delta == 衰减后速度 * dt
    @Test("dt equals refInterval decays velocity by exactly friction")
    func decayAtRefInterval() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        let outcome = m.advance(dt: ref)
        #expect(abs(m.velocity - 940) < 1e-6)          // 1000 * 0.94
        guard case .move(let delta) = outcome else { Issue.record("expected .move"); return }
        #expect(abs(delta - 940 * ref) < 1e-9)
    }

    // 2. 正速度下每步幅度严格递减
    @Test("velocity magnitude strictly decreases each step")
    func monotonicDecay() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 2000)
        var prev = m.velocity
        for _ in 0..<3 {
            _ = m.advance(dt: ref)
            #expect(m.velocity < prev)
            prev = m.velocity
        }
    }

    // 3. 负速度：符号保持，delta 为负
    @Test("negative velocity preserves sign in delta")
    func signPreserved() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: -1000)
        let outcome = m.advance(dt: ref)
        #expect(m.velocity < 0)
        guard case .move(let delta) = outcome else { Issue.record("expected .move"); return }
        #expect(delta < 0)
    }

    // 4. 衰减到 < 阈值 → .stop，velocity 归零
    @Test("velocity below threshold after decay stops and zeroes")
    func belowThresholdStops() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 0.52)
        let outcome = m.advance(dt: ref)   // 0.52 * 0.94 = 0.4888 < 0.5
        #expect(outcome == .stop)
        #expect(m.velocity == 0)
    }

    // 5. 衰减后仍 >= 阈值 → .move（test 4 边界互补）
    @Test("velocity just above threshold after decay keeps moving")
    func justAboveThresholdMoves() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 0.6)
        let outcome = m.advance(dt: ref)   // 0.6 * 0.94 = 0.564 >= 0.5
        guard case .move = outcome else { Issue.record("expected .move"); return }
        #expect(m.velocity > thr)
    }

    // 6. dt == 0 → .stop，归零，不衰减
    @Test("dt zero stops without decay")
    func dtZeroStops() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        #expect(m.advance(dt: 0) == .stop)
        #expect(m.velocity == 0)
    }

    // 7. dt 为负 → .stop
    @Test("negative dt stops")
    func dtNegativeStops() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        #expect(m.advance(dt: -0.1) == .stop)
        #expect(m.velocity == 0)
    }

    // 8. dt >= 1.0 → .stop（后台恢复 guard）
    @Test("dt one or larger stops (background recovery)")
    func dtTooLargeStops() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        #expect(m.advance(dt: 1.5) == .stop)
        #expect(m.velocity == 0)
    }

    // 9. 高初速度有限步内必终止
    @Test("high velocity terminates within finite steps")
    func terminatesFinite() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 5000)
        var steps = 0
        while case .move = m.advance(dt: ref) {
            steps += 1
            #expect(steps < 2000)
        }
        #expect(m.velocity == 0)
    }

    // 10. friction 越大衰减越慢
    @Test("higher friction retains more velocity")
    func higherFrictionSlowerDecay() {
        var slow = DecelerationModel(friction: 0.99, stopThreshold: thr, refInterval: ref, velocity: 1000)
        var fast = DecelerationModel(friction: 0.94, stopThreshold: thr, refInterval: ref, velocity: 1000)
        _ = slow.advance(dt: ref)
        _ = fast.advance(dt: ref)
        #expect(slow.velocity > fast.velocity)
    }

    // 11. 非法 friction → 回退默认 0.94
    @Test("invalid friction falls back to default")
    func invalidFrictionFallsBack() {
        for bad: CGFloat in [.nan, 0, -0.5, 1.0, 1.5, .infinity] {
            let m = DecelerationModel(friction: bad, stopThreshold: thr, refInterval: ref)
            #expect(m.friction == 0.94)
        }
    }

    // 12. 非法 stopThreshold → 回退默认 0.5
    @Test("invalid stopThreshold falls back to default")
    func invalidThresholdFallsBack() {
        for bad: CGFloat in [.nan, 0, -1, .infinity] {
            let m = DecelerationModel(friction: f, stopThreshold: bad, refInterval: ref)
            #expect(m.stopThreshold == 0.5)
        }
    }

    // 13. 非法 refInterval → 回退默认 1/120
    @Test("invalid refInterval falls back to default")
    func invalidRefIntervalFallsBack() {
        for bad: CGFloat in [.nan, 0, -0.1] {
            let m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: bad)
            #expect(abs(m.refInterval - 1.0 / 120.0) < 1e-12)
        }
    }

    // 14. advance 遇非有限速度 → .stop 兜底
    @Test("advance with non-finite velocity stops")
    func nonFiniteVelocityStops() {
        for bad: CGFloat in [.nan, .infinity, -.infinity] {
            var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: bad)
            #expect(m.advance(dt: ref) == .stop)
            #expect(m.velocity == 0)
        }
    }
}

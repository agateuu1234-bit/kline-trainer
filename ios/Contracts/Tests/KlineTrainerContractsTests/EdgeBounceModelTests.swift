import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("EdgeBounceModel")
struct EdgeBounceModelTests {

    private let ref: CGFloat = 1.0 / 120.0
    private let f: CGFloat = 0.94          // friction（与 DecelerationModel 默认一致；codex Plan-R13-F2：本 suite 自带）

    /// 跑到终止，返回 (累积位移, onFinish 是否触发, 帧数, 末速度峰值穿透绝对值)。
    @discardableResult
    private func run(_ m: inout EdgeBounceModel, dt: CGFloat, maxFrames: Int = 5000)
        -> (offsetDelta: CGFloat, finished: Bool, frames: Int, peakOverscroll: CGFloat) {
        var acc: CGFloat = 0
        var frames = 0
        var peak: CGFloat = 0
        while frames < maxFrames {
            frames += 1
            switch m.advance(dt: dt) {
            case .move(let d):
                acc += d
                peak = Swift.max(peak, abs(m.debugOverscroll))
            case .finish(let fd, let nf):
                if let fd { acc += fd }
                return (acc, nf, frames, peak)
            }
        }
        Issue.record("did not finish within \(maxFrames)")
        return (acc, false, frames, peak)
    }

    // P1: 外向 fling 越界 → 回弹精确钉 edge + onFinish
    @Test("outward fling settles exactly at edge")
    func outwardSettlesAtEdge() {
        // offset 0 在 [0,100] 内（已在 max=... 设大），用一个会冲过 max 的场景：
        // bounds [0, 10], offset 起点 9, velocity +1000 → 冲过 10 → 回弹钉 10
        var m = EdgeBounceModel(initialVelocity: 1000, offset: 9, minOffset: 0, maxOffset: 10)
        let r = run(&m, dt: ref)
        #expect(abs((9 + r.offsetDelta) - 10) < 1e-6)   // 末 offset == edge 10
        #expect(m.debugOffset == 10)                    // 精确钉 edge
        #expect(r.finished)
        #expect(r.peakOverscroll > 0)                   // 真有穿透（非空洞 demonstrator）
    }

    // P2: 强内向越界起点 → 首次过边 clamp，绝不进内侧（codex R1-F2 反例族）
    @Test("strong inward velocity clamps at edge, never crosses interior")
    func inwardClampsNoCrossing() {
        // 已越界 offset 10.1（> max 10），强内向 velocity -1000 → 应钉回 10，不冲进内侧（<10）
        var m = EdgeBounceModel(initialVelocity: -1000, offset: 10.1, minOffset: 0, maxOffset: 10)
        var minSeen: CGFloat = 10.1
        var frames = 0
        loop: while frames < 5000 {
            frames += 1
            switch m.advance(dt: ref) {
            case .move:
                minSeen = Swift.min(minSeen, m.debugOffset)
            case .finish:
                break loop
            }
        }
        #expect(m.debugOffset == 10)         // 钉 edge
        #expect(minSeen >= 10 - 1e-9)        // 全程从不进内侧（< 10）
    }

    // P3: 弹簧 state 分区不变 —— 比**固定 elapsed 时刻**（settle 前）的 offset+velocity，
    //     不同分区（单步/拆分/不规则/亚-ref）一致（codex Plan-R1-F3：避免「都 snap 到 edge」的恒等 tautology）
    @Test("spring offset+velocity invariant across partitions at fixed pre-settle elapsed")
    func springPartitionInvariantState() {
        // seed: 越界 offset 15 ∈ [0,10]，v=0 → x0=5, omega≈14.14；t=0.05 时 x≈4.2（仍越界、未 settle）
        func stateAt(elapsed: CGFloat, partition: [CGFloat]) -> (offset: CGFloat, velocity: CGFloat, finished: Bool) {
            var m = EdgeBounceModel(initialVelocity: 0, offset: 15, minOffset: 0, maxOffset: 10)
            var remaining = elapsed
            var i = 0
            var finished = false
            while remaining > 1e-12 {
                let step = Swift.min(partition[i % partition.count], remaining)
                if case .finish = m.advance(dt: step) { finished = true; break }
                remaining -= step
                i += 1
            }
            return (m.debugOffset, m.debugVelocity, finished)
        }
        let elapsed: CGFloat = 0.05
        let single    = stateAt(elapsed: elapsed, partition: [ref])
        let split     = stateAt(elapsed: elapsed, partition: [ref / 3])
        let irregular = stateAt(elapsed: elapsed, partition: [ref * 0.7, ref * 1.3, ref * 0.4])
        let subRef    = stateAt(elapsed: elapsed, partition: [ref / 5])
        // 仍在瞬态（未 settle、仍越界）→ 比的是真实弹簧 state，非 snap 后的恒等值
        #expect(!single.finished && single.offset > 10)
        for other in [split, irregular, subRef] {
            #expect(abs(single.offset - other.offset) < 1e-3)      // 解析组合精确（Euler 会大幅发散）
            #expect(abs(single.velocity - other.velocity) < 1e-1)
        }
    }

    // P1 exact-edge：起点恰在 outward edge + 外向速度 → 第一帧进弹簧（boundary-aware `need==0` 用**已衰减**速度
    //     seed，与 edge-ε 极限连续），完成内终止、精确钉 edge（codex Plan-R1-F1/R12-F2）。
    @Test("outward fling exactly on edge: continuous (damped-seed) spring then settles at edge")
    func exactEdgeOutwardFling() {
        let omega = sqrt(EdgeBounceModel.defaultStiffness)   // √200
        let damped = 1000 * f                                // need==0 用已衰减速度（= v0*friction）
        let expectedX = (damped * ref) * exp(-omega * ref)   // seed=edge, A=0, B=damped → 首帧 overscroll
        var hi = EdgeBounceModel(initialVelocity: 1000, offset: 10, minOffset: 0, maxOffset: 10)
        #expect(hi.shouldRun)
        guard case .move = hi.advance(dt: ref) else { Issue.record("expected first frame .move (hi)"); return }
        #expect(abs(hi.debugOverscroll - expectedX) < 1e-4)
        var n = 0; var finished = false
        while n < 5000, !finished { n += 1; if case .finish = hi.advance(dt: ref) { finished = true } }
        #expect(finished)
        #expect(hi.debugOffset == 10)
        // 下界对称：offset==min 0，v=-1000
        var lo = EdgeBounceModel(initialVelocity: -1000, offset: 0, minOffset: 0, maxOffset: 10)
        guard case .move = lo.advance(dt: ref) else { Issue.record("expected first frame .move (lo)"); return }
        #expect(abs(lo.debugOverscroll - (-expectedX)) < 1e-4)
        n = 0; finished = false
        while n < 5000, !finished { n += 1; if case .finish = lo.advance(dt: ref) { finished = true } }
        #expect(finished)
        #expect(lo.debugOffset == 0)
    }

    // P1 epsilon-limit：exact-edge（offset=max）与 edge-ε（offset=max-ε）首帧弹簧 overscroll **收敛**（codex R12-F2：
    //     连续 handoff，无幅度跳变）。ε→0 时两者首帧 overscroll 差 → 0。
    @Test("exact-edge and edge-epsilon spring seeds converge (no amplitude jump)")
    func exactEdgeEpsilonContinuity() {
        func firstOverscroll(offset: CGFloat) -> CGFloat {
            var m = EdgeBounceModel(initialVelocity: 1000, offset: offset, minOffset: 0, maxOffset: 10)
            _ = m.advance(dt: ref)
            return m.debugOverscroll
        }
        let exact = firstOverscroll(offset: 10)
        let nearE = firstOverscroll(offset: 10 - 1e-6)       // edge-ε
        #expect(abs(exact - nearE) < 1e-3)                   // 连续：跳变 → 0（旧 atOrPastOutwardEdge 会给 ~0.45pt 跳）
    }

    // P6 量级悬殊 non-round-trippable：offset=MAX/2、edge=10 → 修正 `edge−offset` 舍入为 -offset
    //   （consumer 落 0 而非 edge，model/consumer 失步）→ inert 拒绝（codex Plan-R11-F1）。
    @Test("magnitude-disparate non-round-trippable geometry is inert")
    func magnitudeDisparateInert() {
        var m = EdgeBounceModel(initialVelocity: 0,
                                offset: CGFloat.greatestFiniteMagnitude / 2,
                                minOffset: 0, maxOffset: 10)
        #expect(m.shouldRun == false)                 // 不可逆 → 不运行（consumer 不被改）
        let out = m.advance(dt: ref)                  // 防御：直接 advance 也 finish(nil)、offset 不变
        guard case .finish(let fd, _) = out else { Issue.record("expected finish"); return }
        #expect(fd == nil)
        #expect(m.debugOffset == CGFloat.greatestFiniteMagnitude / 2)
    }

    // P6 in-bounds 减速相不可逆（codex R12-F1）：offset 极端但 in-bounds、减速会向小 edge 跨边，
    //   修正 `edge−offset` 不可逆（量级悬殊）→ 减速相 round-trip 校验亦拒绝 → inert（防 consumer 跨边后失步）。
    @Test("in-bounds extreme decelerating toward non-round-trippable edge is inert")
    func inBoundsExtremeDecelInert() {
        let big = CGFloat.greatestFiniteMagnitude
        // offset=-MAX/2 in-bounds [-MAX, 10]，velocity+ → 向 edge 10 减速，但 10-(-MAX/2) 舍入丢小端 → 不可逆
        let m = EdgeBounceModel(initialVelocity: big * 0.5, offset: -big / 2, minOffset: -big, maxOffset: 10)
        #expect(m.shouldRun == false)                 // 减速相也查 round-trip → 拒绝
    }

    // P6 round-trip 容差不误拒普通几何（codex Plan-R13-F1）：裸 == 会因 1-ULP 误拒 offset=-100/edge=-35.9；
    //   ULP-scaled 容差应放行。+ 普通量级确定性扫（越界或界内有速度均应 shouldRun）。
    @Test("ordinary finite geometry not falsely rejected by round-trip tolerance")
    func ordinaryFiniteOperable() {
        #expect(EdgeBounceModel(initialVelocity: 0, offset: -100, minOffset: -35.9, maxOffset: 1000).shouldRun)
        for offI in stride(from: -2000, through: 2000, by: 173) {
            for hi in [CGFloat(10), 100, 1000] {
                let m = EdgeBounceModel(initialVelocity: 1000, offset: CGFloat(offI), minOffset: -hi, maxOffset: hi)
                #expect(m.shouldRun)                  // 普通量级 round-trip 必成立 → 不误拒
            }
        }
    }

    // P6 大 edge 点级失步（codex Plan-R14-F1/R15-F1）：固定 cap + edge 分辨率 fail-closed → 任意大 edge 量级悬殊均 inert
    //   （旧相对/8·ulp 容差会随 edge 膨胀放过百万点失步）。覆盖 codex R15 反例 edge=±1e15/1e21。
    @Test("large-edge magnitude-disparate offset is inert (fixed-cap fail-closed)")
    func largeEdgeDisparateInert() {
        // springEdge 量级大（ulp 超亚像素 cap）→ fail-closed，不论 offset：越上界（springEdge=max=1e15）
        #expect(EdgeBounceModel(initialVelocity: 0, offset: 1e21, minOffset: 0, maxOffset: 1e15).shouldRun == false)
        // 越上界，springEdge=max=-1e21（codex R15 反例量级）
        #expect(EdgeBounceModel(initialVelocity: 0, offset: 9.382072597219299e21, minOffset: -1e22, maxOffset: -1e21).shouldRun == false)
        // 越下界，springEdge=min=-1e15
        #expect(EdgeBounceModel(initialVelocity: 0, offset: -1e18, minOffset: -1e15, maxOffset: 1e15).shouldRun == false)
    }

    // P6 MAX 量级 edge 在固定 cap 下亦 inert（codex Plan-R2-F1→R11-F1→R15-F1 演进）：固定 cap fail-closed 后
    //   `|edge|` 大到 8·ulp > 亚像素 cap（含 0.99·MAX）一律 init 拒 → **spring 重构溢出 guard（springStep
    //   newOffset.isFinite，R2-F1）成为不可达 belt-and-suspenders 防御**（operable 路径 springEdge 有界、不溢出）。
    @Test("MAX-magnitude edge is inert under fixed-cap fail-closed")
    func maxMagnitudeEdgeInert() {
        let big = CGFloat.greatestFiniteMagnitude
        let m = EdgeBounceModel(initialVelocity: big * 0.9, offset: big * 0.995,
                                minOffset: -big, maxOffset: big * 0.99)
        #expect(m.shouldRun == false)                 // 0.99·MAX 的 ulp ≫ 亚像素 cap → fail-closed
    }

    // P6 极端有限 velocity 动态安全（codex Plan-R18-F1）：普通 edge（10）但巨大 velocity（MAX/2）→ 弹簧本会生成
    //   ~3.5e305 finite offset（渲染器 offset→Int trap + reset 归一失步）；springStep 动态 round-trip guard 应钉 edge、
    //   不暴露 enormous 中间态。覆盖 normal advance + abnormal-dt（reset 安全 by-construction：offset 从不变 huge）。
    @Test("extreme finite velocity never exposes unsafe spring offset")
    func extremeFiniteVelocitySafe() {
        let big = CGFloat.greatestFiniteMagnitude
        // normal advance
        var m = EdgeBounceModel(initialVelocity: big / 2, offset: 9, minOffset: 0, maxOffset: 10)
        #expect(m.shouldRun)
        var consumer: CGFloat = 9
        var maxAbs: CGFloat = 9; var frames = 0; var finished = false
        while frames < 5000, !finished {
            frames += 1
            switch m.advance(dt: ref) {
            case .move(let d): consumer += d; maxAbs = Swift.max(maxAbs, abs(m.debugOffset))
            case .finish(let fd, _): if let fd { consumer += fd }; finished = true
            }
        }
        #expect(finished)
        #expect(m.debugOffset == 10 && consumer == 10)   // 钉 edge、consumer 追到（无失步）
        #expect(maxAbs < 1e12)                            // 从不暴露 enormous offset（渲染器 Int 不 trap）
        // abnormal-dt：巨大速度 + 大 dt（界内）→ finish、不进弹簧、不暴露
        var m2 = EdgeBounceModel(initialVelocity: big / 2, offset: 9, minOffset: 0, maxOffset: 10)
        guard case .finish = m2.advance(dt: 2.0) else { Issue.record("expected abnormal-dt finish"); return }
        #expect(abs(m2.debugOffset) < 1e12)
    }

    // P6 opposite-extreme：offset 与 edge 异极、归一修正不可表示（codex Plan-R3-F1）→ inert（拒绝），
    //     绝不外溢 -inf delta、绝不内部 snap 致 model/consumer 失步（offset 不变）。
    @Test("opposite-extreme non-representable geometry is inert (no inf, no desync)")
    func oppositeExtremeInert() {
        let big = CGFloat.greatestFiniteMagnitude
        // bounds 都在 -MAX，offset 在 +MAX → 归一修正 edge−offset = -2·MAX 不可表示
        var m = EdgeBounceModel(initialVelocity: 0, offset: big, minOffset: -big, maxOffset: -big)
        #expect(m.shouldRun == false)              // 动画器据此 no-op，根本不启动
        // 防御：即便直接 advance（normal 与 abnormal dt 两路）均 finish(nil)，不外溢、offset 不变
        let normal = m.advance(dt: ref)
        guard case .finish(let fdN, _) = normal else { Issue.record("expected finish (normal)"); return }
        #expect(fdN == nil)
        #expect(m.debugOffset == big)              // 无 desync：未内部 snap
        let abnormal = m.advance(dt: 2.0)
        guard case .finish(let fdA, _) = abnormal else { Issue.record("expected finish (abnormal)"); return }
        #expect(fdA == nil)
        #expect(m.debugOffset == big)
    }

    // P3 端到端（codex Plan-R8-F1 方案 A 累加器 + R9-F1）：始界内·跨边·回弹，**比共时 elapsed 的 model state**
    //     （非帧采样峰值——帧采样会在不同帧率采到同一解析轨迹的不同点，~0.4pt 假差，codex R9-F1）。
    //     累加器使 floor(elapsed/refInterval) 固定步数与分区无关 ⇒ 共时 state **精确无关（紧容差）**；覆盖 v=1000/2000/5000。
    @Test("end-to-end crossing: model state at common elapsed time is partition-invariant")
    func endToEndCrossingFrameRates() {
        func stateAt(velocity: CGFloat, elapsed: CGFloat, partition: [CGFloat]) -> (offset: CGFloat, velocity: CGFloat, finished: Bool) {
            var m = EdgeBounceModel(initialVelocity: velocity, offset: 990, minOffset: 0, maxOffset: 1000)
            var rem = elapsed; var i = 0; var fin = false
            while rem > 1e-12 {
                let step = Swift.min(partition[i % partition.count], rem)
                if case .finish = m.advance(dt: step) { fin = true; break }
                rem -= step; i += 1
            }
            return (m.debugOffset, m.debugVelocity, fin)
        }
        let T: CGFloat = 0.04   // 跨边(~ms)后、settle 前的弹簧穿透段（spring 峰值时 ~1/ω≈0.07s）
        for v in [CGFloat(1000), 2000, 5000] {
            let s120 = stateAt(velocity: v, elapsed: T, partition: [ref])
            let s60  = stateAt(velocity: v, elapsed: T, partition: [2 * ref])
            let sSub = stateAt(velocity: v, elapsed: T, partition: [ref / 3])
            let sIrr = stateAt(velocity: v, elapsed: T, partition: [ref * 0.7, ref * 1.3, ref * 0.4])
            #expect(!s120.finished && s120.offset > 1000)   // 仍越界、未 settle（真瞬态）
            for s in [s60, sSub, sIrr] {
                #expect(abs(s120.offset - s.offset) < 1e-3 && abs(s120.velocity - s.velocity) < 1e-1)
            }
        }
    }

    // P3 zero-crossing 事件时刻解析精确（codex R6-F1）：内向越界 → 解析 tzc=-A/B；跨前轨迹分区无关 + 终止精确钉 edge
    @Test("spring zero-crossing: pre-crossing trajectory partition-invariant, terminates exactly at edge")
    func springZeroCrossingEventTime() {
        // offset 10.1（越上界 0.1），v=-50 内向 → 解析 tzc ≈ 0.00206s（< 1 frame）
        func stateAt(elapsed: CGFloat, partition: [CGFloat]) -> (offset: CGFloat, velocity: CGFloat, crossed: Bool) {
            var m = EdgeBounceModel(initialVelocity: -50, offset: 10.1, minOffset: 0, maxOffset: 10)
            var rem = elapsed; var i = 0; var crossed = false
            while rem > 1e-12 {
                let step = Swift.min(partition[i % partition.count], rem)
                if case .finish = m.advance(dt: step) { crossed = true; break }
                rem -= step; i += 1
            }
            return (m.debugOffset, m.debugVelocity, crossed)
        }
        let pre: CGFloat = 0.001   // < tzc → 尚未 cross
        let s1 = stateAt(elapsed: pre, partition: [ref])      // 单步（0.001<ref）
        let s2 = stateAt(elapsed: pre, partition: [pre / 4])  // 4 子步
        #expect(!s1.crossed && !s2.crossed)
        #expect(s1.offset > 10)                               // 仍越界（真瞬态）
        #expect(abs(s1.offset - s2.offset) < 1e-6 && abs(s1.velocity - s2.velocity) < 1e-3)  // 解析精确
        // cross 后精确钉 edge（单 ref 帧足够覆盖 tzc）
        var m = EdgeBounceModel(initialVelocity: -50, offset: 10.1, minOffset: 0, maxOffset: 10)
        guard case .finish = m.advance(dt: ref) else { Issue.record("expected zero-crossing within ref"); return }
        #expect(m.debugOffset == 10)
    }

    // P4: 界内不足达边 → 与 DecelerationModel 同律（无弹簧，末 offset 不越界）
    @Test("in-bounds insufficient velocity decelerates without spring")
    func inBoundsNoSpring() {
        // bounds 极宽 [-10000, 10000], offset 0, velocity 100（滑行远不到边）
        var m = EdgeBounceModel(initialVelocity: 100, offset: 0, minOffset: -10000, maxOffset: 10000)
        let r = run(&m, dt: ref)
        #expect(r.finished)
        #expect(abs(m.debugOverscroll) < 1e-9)          // 从未越界
        #expect((0 + r.offsetDelta) < 10000)            // 停在界内
    }

    // P6: 仅 velocity 非有限 + 有限越界 offset → 净化 + 归位（不 strand，codex R10-F2）
    @Test("non-finite velocity with overscrolled finite offset normalizes")
    func nonFiniteVelocityNormalizes() {
        for bad: CGFloat in [.nan, .infinity, -.infinity] {
            var m = EdgeBounceModel(initialVelocity: bad, offset: 15, minOffset: 0, maxOffset: 10)
            var frames = 0
            while frames < 5000 { frames += 1; if case .finish = m.advance(dt: ref) { break } }
            #expect(m.debugOffset == 10)                // 归位至 edge，不滞留 15
        }
    }

    // P6: 非有限 bounds → 安全（无 bounce，无 trap）
    @Test("non-finite bounds is inert")
    func nonFiniteBoundsInert() {
        let m = EdgeBounceModel(initialVelocity: 1000, offset: 5, minOffset: .nan, maxOffset: 10)
        #expect(m.shouldRun == false)                   // 几何无效 → 不运行
    }

    // P8: abnormal dt 越界 → 同帧归位 + finalDelta 全帧位移 + onFinish 触发（codex R6-F3）
    @Test("abnormal dt while overscrolled normalizes and finishes")
    func abnormalDtOverscrolled() {
        var m = EdgeBounceModel(initialVelocity: 0, offset: 15, minOffset: 0, maxOffset: 10)
        let out = m.advance(dt: 2.0)
        guard case .finish(let fd, let nf) = out else { Issue.record("expected .finish"); return }
        #expect(nf == true)                             // abnormal-dt 触发 onFinish
        #expect(fd != nil)
        #expect(abs(fd! - (10 - 15)) < 1e-9)            // finalDelta = edge - frameEntry
        #expect(m.debugOffset == 10)
    }

    // P8 same-tick 多相：一帧内 decel→跨边→spring→settle 全发生 → finalDelta = finalOffset - frameEntry
    //    （含 pre-snap 减速段，不丢，codex Plan-R7-F2：丢早期子段位移会致 consumer 与 model 失步）
    @Test("same-tick decel->cross->spring->settle reports full frame delta")
    func sameTickMultiPhaseFinalDelta() {
        // dt=0.6（大但 <1.0）：界内 offset 9，v=1000 → 一帧内减速跨边 10 + 弹簧充分 settle → finish
        var m = EdgeBounceModel(initialVelocity: 1000, offset: 9, minOffset: 0, maxOffset: 10)
        let out = m.advance(dt: 0.6)
        guard case .finish(let fd, let nf) = out else { Issue.record("expected one-tick finish, got \(out)"); return }
        #expect(nf == true)
        #expect(fd != nil)
        #expect(abs(fd! - 1.0) < 1e-6)                  // 全帧位移 = finalOffset(10) - frameEntry(9)（含减速段）
        #expect(m.debugOffset == 10)
    }

    // P5 单调性：峰值穿透随初速度增、随 stiffness 减（codex Plan-R7-F3；忽略/反转 stiffness 即失败）
    @Test("P5 peak overscroll increases with velocity and decreases with stiffness")
    func peakMonotonicity() {
        func peak(velocity: CGFloat, stiffness: CGFloat) -> CGFloat {
            // 起点恰在 edge（offset==max），外向 → 立即弹簧 seed 满速；峰值 = v/(omega·e)
            var m = EdgeBounceModel(initialVelocity: velocity, offset: 10,
                                    minOffset: 0, maxOffset: 10, stiffness: stiffness)
            var p: CGFloat = 0; var n = 0
            loop: while n < 5000 {
                n += 1
                switch m.advance(dt: ref) {
                case .move: p = Swift.max(p, m.debugOverscroll)
                case .finish: break loop
                }
            }
            return p
        }
        let k = EdgeBounceModel.defaultStiffness
        let pv1 = peak(velocity: 500, stiffness: k)
        let pv2 = peak(velocity: 1000, stiffness: k)
        let pv3 = peak(velocity: 2000, stiffness: k)
        #expect(pv1.isFinite && pv2.isFinite && pv3.isFinite)
        #expect(pv1 < pv2 && pv2 < pv3)                 // v↑ → 峰值↑
        let pk1 = peak(velocity: 1000, stiffness: 100)
        let pk2 = peak(velocity: 1000, stiffness: 400)
        let pk3 = peak(velocity: 1000, stiffness: 1600)
        #expect(pk1 > pk2 && pk2 > pk3)                 // k↑ → 峰值↓
    }
}

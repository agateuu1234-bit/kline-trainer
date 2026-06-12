# Wave 3 顺位 11 — 边缘 bounce 动画（组件层隔离）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一个纯物理、几何无关、可注入边界的边缘回弹组件（`EdgeBounceModel` + `DecelerationModel` boundary-aware 推进 + `DecelerationAnimator` additive bounce 路径），完全单测闭合；实时可见接线 deferred 为 residual `W3-11-R1`。

**Architecture（方案 A：帧率无关回弹，user 2026-06-12 裁决）：** 减速段用 **`DecelerationModel` damp-then-move 律 + 持久固定步累加器**（新增 boundary-aware 推进 `advance(dt:boundaryDistance:)` + additive `carry` 字段：固定 refInterval 步、跨 `advance` 携带余量 → 到达边界的速度/时刻**任意帧率/分区精确无关**，P3 端到端）；越界段用**临界阻尼解析弹簧**（ζ=1 闭式传播 + 首次过边 clamp + 渐近 settle）。动画器新增 bounce-enabled 启动面，经统一 `FrameOutcome` + 共享 re-entrancy-safe `terminate`。**既有 `start(initialVelocity:)` + `DecelerationModel.advance(dt:)` 行为 byte-for-byte 不变（P7）**；累加器与 `advance(dt:)` 仅相差 sub-refInterval 余量延迟（P4 within-substep，肉眼不可感知）。

**Tech Stack:** Swift 6 / Swift Testing（`@Suite`/`@Test`/`#expect`）/ CoreGraphics / SwiftPM package `KlineTrainerContracts`（macOS host 全测 + Mac Catalyst build-for-testing required CI）。

**Spec:** `docs/superpowers/specs/2026-06-11-pr-wave3-11-edge-bounce-design.md`（codex R1-R11 收敛 APPROVE）。

**范围判据（codex 可验证）：** `git diff --stat` 只应触碰 `ChartEngine/DecelerationModel.swift`（additive）、`ChartEngine/EdgeBounceModel.swift`（新）、`ChartEngine/DecelerationAnimator.swift`（additive）、三测试文件、design/plan/acceptance doc。**不得**改 `RenderStateBuilder.swift`/`TrainingEngine.swift`/`ChartContainerView.swift`/`Reducer.swift`。

**物理常量（plan-stage 选定）：** spring `stiffness = 200`（`omega = √200 ≈ 14.142`），`posTol = 0.5`（pt），`velTol = 5.0`（pt/s）。decel 沿用 `DecelerationModel` 默认 `friction 0.94 / stopThreshold 0.5 / refInterval 1/120`。

**基线：** worktree 起点 `cd ios/Contracts && swift test` = **799 tests / 120 suites / 0 fail**（已实测 2026-06-11）。每个 Task 末尾 `swift test` 必须仍全绿且既有测试零改动。

---

## File Structure

| 文件 | 责任 | Task |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationModel.swift` | **MODIFY（additive）**：加 `BoundaryOutcome` + `advance(dt:boundaryDistance:)`；既有 `Outcome`/`advance(dt:)` 字节不动 | 1 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationModelBoundaryTests.swift` | **CREATE**：boundary-aware 推进单测 | 1 |
| `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/EdgeBounceModel.swift` | **CREATE**：`FrameOutcome` + `EdgeBounceModel`（减速复用 + 解析弹簧 + 生命周期 outcome） | 2 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/EdgeBounceModelTests.swift` | **CREATE**：P1-P8 物理 + 边界 + 防御单测 | 2 |
| `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift` | **MODIFY（additive）**：`RunModel`/bounce start/共享 `terminate`/run-epoch/`resetOnSceneActive` 归一；既有 `start(initialVelocity:)` 行为不变 | 3 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationAnimatorBounceTests.swift` | **CREATE**：bounce 路径 + P9 re-entrancy + lifecycle parity 单测 | 3 |
| `docs/superpowers/acceptance/2026-06-11-pr-wave3-11-edge-bounce.md` | **CREATE**：非 coder 验收清单 + residual/runbook deferral | 4 |

---

## Task 1: `DecelerationModel` boundary-aware advancement（additive）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationModel.swift`（在 `struct DecelerationModel` 内追加，既有成员不动）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationModelBoundaryTests.swift`（新建）

- [ ] **Step 1: 写失败测试（新文件）**

创建 `DecelerationModelBoundaryTests.swift`：

```swift
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
```

- [ ] **Step 2: 跑测试确认编译失败**

Run: `cd ios/Contracts && swift test --filter "DecelerationModel boundary-aware"`
Expected: 编译失败（`advance(dt:boundaryDistance:)` / `BoundaryOutcome` 未定义）。

- [ ] **Step 3: 实现 boundary-aware advancement（additive）**

**(i)** 在 `struct DecelerationModel` 的 stored properties 区（紧随 `var velocity`）追加 **additive 字段**（既有 `advance(dt:)` **不碰它**，默认 0 → 既有行为/测试零改动；自定义 init 不设它用默认值）：
```swift
    /// boundary-aware 累加器的时间余量（跨 `advance(dt:boundaryDistance:)` 调用携带）。
    /// 既有 `advance(dt:)` 路径不使用（默认 0）。spec 方案 A（帧率无关回弹）。
    var carry: CGFloat = 0
```

**(ii)** 在 `advance(dt:)` 方法**之后**追加 `BoundaryOutcome` + **累加器** boundary-aware 推进（既有 `Outcome`/`advance(dt:)` 一行不改）：

```swift
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
            if need != 0, (need > 0) == (velocity > 0), abs(stepDelta) >= abs(need) {
                let tWithin = need / velocity                     // ∈ (0, refInterval]
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
```

- [ ] **Step 4: 跑测试确认通过 + 既有全绿**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: PASS；总数 ≥ 799 + 新（DecelerationModelBoundaryTests）；既有 `DecelerationModel` 15 测零改动通过（`carry` 默认 0、`advance(dt:)` 不碰它）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationModel.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationModelBoundaryTests.swift
git commit -m "feat(bounce): DecelerationModel additive boundary-aware advancement"
```

---

## Task 2: `EdgeBounceModel`（纯物理：减速复用 + 解析弹簧）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/EdgeBounceModel.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/EdgeBounceModelTests.swift`

- [ ] **Step 1: 写失败测试（新文件，核心 killer）**

创建 `EdgeBounceModelTests.swift`：

```swift
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("EdgeBounceModel")
struct EdgeBounceModelTests {

    private let ref: CGFloat = 1.0 / 120.0

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

    // P1 exact-edge：起点恰在 outward edge + 外向速度 → **第一帧立即进弹簧（seed 满速，无 decel 衰减）**，
    //     完成内终止、精确钉 edge（codex Plan-R1-F1 + Plan-R4-F2：删 atOrPastOutwardEdge guard 会先衰减再 strand → 须断言首帧 state + finished）
    @Test("outward fling exactly on edge: immediate full-velocity spring then settles at edge")
    func exactEdgeOutwardFling() {
        let omega = sqrt(EdgeBounceModel.defaultStiffness)   // √200
        let expectedX = (1000 * ref) * exp(-omega * ref)     // seed=edge, A=0, B=1000 → 首帧 overscroll
        // 上界：offset==max 10，v=+1000
        var hi = EdgeBounceModel(initialVelocity: 1000, offset: 10, minOffset: 0, maxOffset: 10)
        #expect(hi.shouldRun)
        guard case .move = hi.advance(dt: ref) else { Issue.record("expected first frame .move (hi)"); return }
        #expect(abs(hi.debugOverscroll - expectedX) < 1e-4)  // **满速 1000 seed**（破 guard → 用衰减 940 → 偏离）
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

    // P6 extreme-finite：极端有限 offset（弹簧数学溢出）→ 不外溢 inf/NaN delta，安全钉 edge（codex Plan-R1-F2）
    @Test("extreme finite overscroll never emits non-finite delta")
    func extremeFiniteNoNonFiniteDelta() {
        var m = EdgeBounceModel(initialVelocity: 0,
                                offset: CGFloat.greatestFiniteMagnitude / 2,
                                minOffset: 0, maxOffset: 10)
        var frames = 0
        var sawNonFinite = false
        var finished = false
        while frames < 5000, !finished {
            frames += 1
            switch m.advance(dt: ref) {
            case .move(let d):
                if !d.isFinite { sawNonFinite = true }
            case .finish(let fd, _):
                if let fd, !fd.isFinite { sawNonFinite = true }
                finished = true
            }
        }
        #expect(!sawNonFinite)
        #expect(finished)
        #expect(m.debugOffset == 10)   // 最终安全钉 edge
    }

    // P6 large-edge overflow：xNew 有限但 springEdge+xNew 溢出（codex Plan-R2-F1 反例）→ 仍不外溢 inf delta
    @Test("large finite edge: reconstructed offset overflow is guarded")
    func largeEdgeReconstructedOverflowGuarded() {
        let big = CGFloat.greatestFiniteMagnitude
        // edge=0.99·MAX，offset=0.995·MAX（越上界），velocity=0.9·MAX（有限）
        // → x、B、xNew 各自有限，但 springEdge(0.99·MAX)+xNew 溢出 → 须 guard 重构 offset
        var m = EdgeBounceModel(initialVelocity: big * 0.9, offset: big * 0.995,
                                minOffset: -big, maxOffset: big * 0.99)
        #expect(m.shouldRun)
        var sawNonFinite = false
        var finished = false
        var frames = 0
        while frames < 5000, !finished {
            frames += 1
            switch m.advance(dt: ref) {
            case .move(let d):
                if !d.isFinite { sawNonFinite = true }
            case .finish(let fd, _):
                if let fd, !fd.isFinite { sawNonFinite = true }
                finished = true
            }
        }
        #expect(!sawNonFinite)
        #expect(finished)
        #expect(m.debugOffset == big * 0.99)   // 安全钉 edge（不溢出 inf）
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
```

> **测试缝说明：** `EdgeBounceModel` 暴露 internal 只读 `debugOffset`/`debugOverscroll` + `shouldRun`（仅 `@testable import` 可见），供确定性断言。

- [ ] **Step 2: 跑测试确认编译失败**

Run: `cd ios/Contracts && swift test --filter "EdgeBounceModel"`
Expected: 编译失败（`EdgeBounceModel` 未定义）。

- [ ] **Step 3: 实现 `EdgeBounceModel`**

创建 `EdgeBounceModel.swift`：

```swift
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
        // 可操作性（codex Plan-R3-F1）：越界但归一修正 `edge−offset` 不可表示（offset 与 edge 异极致溢出）
        // → inert（拒绝；动画器 no-op，绝不外溢 ±inf delta、绝不内部 snap 致 model/consumer 失步）。
        let operable = boundsValid && (ph == .decelerating || (offset - edge).isFinite)

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

    // 减速相：boundary-aware；跨边即 seed 弹簧于 edge、对剩余帧时间走弹簧
    private mutating func advanceDecel(dt: CGFloat, frameEntry: CGFloat) -> FrameOutcome {
        let edge = (velocity >= 0) ? maxOffset : minOffset
        // 起点恰在/越过 outward edge（boundaryDistance==0，codex Plan-R1-F1）→ 立即进弹簧，
        // 否则 boundary-aware 的 `need != 0` 守门会吞掉跨边、把 offset 滑出界外永不回弹。
        let atOrPastOutwardEdge = (velocity >= 0) ? (offset >= maxOffset) : (offset <= minOffset)
        if atOrPastOutwardEdge {
            springEdge = edge
            phase = .springing
            return springStep(tau: dt, frameEntry: frameEntry)
        }
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
        // 极端有限输入溢出防御（codex Plan-R1-F2/R2-F1）：派生值**及重构 offset/delta**非有限 → 钉 edge + 终止。
        // 注意：xNew/vNew 有限不代表 `springEdge + xNew` 有限（大 edge 下其和可溢出，codex R2-F1）→ 须验重构值。
        let newOffset = springEdge + xNew
        let moveDelta = newOffset - frameEntry
        guard xNew.isFinite, vNew.isFinite, newOffset.isFinite, moveDelta.isFinite else {
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
```

- [ ] **Step 4: 跑测试确认通过 + 既有全绿**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: PASS；EdgeBounceModelTests 全过；总数 ≥ 799 + 6（Task1）+ EdgeBounce 测试数；既有零改动。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/EdgeBounceModel.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/EdgeBounceModelTests.swift
git commit -m "feat(bounce): EdgeBounceModel pure spring+decel physics"
```

---

## Task 3: `DecelerationAnimator` bounce 路径（additive + re-entrancy-safe）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationAnimatorBounceTests.swift`

- [ ] **Step 1: 写失败测试（新文件）**

创建 `DecelerationAnimatorBounceTests.swift`（复用既有 `FakeFrameDriver`，定义在 `DecelerationAnimatorTests.swift`，同 target 可见）：

```swift
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("DecelerationAnimator bounce", .serialized)
struct DecelerationAnimatorBounceTests {

    private let ref: CGFloat = 1.0 / 120.0

    private func makeWithFake() -> (DecelerationAnimator, () -> FakeFrameDriver?) {
        final class Box { var fake: FakeFrameDriver? }
        let box = Box()
        let a = DecelerationAnimator(friction: 0.94, stopThreshold: 0.5, makeDriver: { onTick in
            let f = FakeFrameDriver(onTick: onTick); box.fake = f; return f
        })
        return (a, { box.fake })
    }

    /// 手动逐帧 fire 到终止，累积 onUpdate delta + onFinish 次数。
    private func driveToFinish(_ a: DecelerationAnimator, fake: () -> FakeFrameDriver?,
                               dt: CGFloat, updates: inout [CGFloat], finishes: () -> Int,
                               maxFrames: Int = 5000) {
        var n = 0
        while a.isDecelerating, n < maxFrames {
            n += 1
            _ = fake()?.fire(dt)
        }
    }

    // 1. bounce 越界回弹：onUpdate 序列累积 offset 落 edge + onFinish 一次
    @Test("bounce settles at edge and fires onFinish once")
    func bounceSettles() {
        let (a, fake) = makeWithFake()
        var updates: [CGFloat] = []; var finishes = 0
        a.onUpdate = { updates.append($0) }; a.onFinish = { finishes += 1 }
        // 起点 9 in [0,10], v=+1000 → 冲过 10 回弹
        a.start(initialVelocity: 1000, fromOffset: 9, minOffset: 0, maxOffset: 10)
        #expect(a.isDecelerating)
        var n = 0
        while a.isDecelerating, n < 5000 { n += 1; _ = fake()?.fire(ref) }
        let landed = 9 + updates.reduce(0, +)
        #expect(abs(landed - 10) < 1e-6)
        #expect(finishes == 1)
        #expect(!a.isDecelerating)
    }

    // 2. 无跨边 lifecycle parity（codex R9-F1）：bounce API 的 move-then-stop + onFinish 帧 与 start(initialVelocity:) 一致
    @Test("no-crossing bounce matches plain deceleration lifecycle frame-by-frame")
    func noCrossingLifecycleParity() {
        // plain
        let (a1, f1) = makeWithFake()
        var u1: [CGFloat] = []; var fin1 = 0
        a1.onUpdate = { u1.append($0) }; a1.onFinish = { fin1 += 1 }
        a1.start(initialVelocity: 100)
        var seq1: [Bool] = []   // 每帧 isDecelerating 快照
        var n = 0
        while a1.isDecelerating, n < 5000 { n += 1; _ = f1()?.fire(ref); seq1.append(a1.isDecelerating) }
        // bounce，宽边界不跨
        let (a2, f2) = makeWithFake()
        var u2: [CGFloat] = []; var fin2 = 0
        a2.onUpdate = { u2.append($0) }; a2.onFinish = { fin2 += 1 }
        a2.start(initialVelocity: 100, fromOffset: 0, minOffset: -100000, maxOffset: 100000)
        var seq2: [Bool] = []
        n = 0
        while a2.isDecelerating, n < 5000 { n += 1; _ = f2()?.fire(ref); seq2.append(a2.isDecelerating) }
        #expect(u1.count == u2.count)
        for i in 0..<min(u1.count, u2.count) { #expect(abs(u1[i] - u2[i]) < 1e-9) }
        #expect(fin1 == fin2 && fin1 == 1)
        #expect(seq1 == seq2)              // isDecelerating 翻转帧逐帧一致
    }

    // 3. P9 re-entrancy（codex R4-F3/Plan-R2-F2）：终止帧 onUpdate 内重入**真正的新 run** → 新 run 存活
    //    （新 driver 未被旧续延 invalidate）+ 旧 onFinish 抑制；新 run 仍可跑到完成各触发一次。
    @Test("re-entrant start in terminal onUpdate keeps the NEW run alive and suppresses old onFinish")
    func reentrantStartInTerminalUpdate() {
        let (a, fake) = makeWithFake()
        var finishes = 0; var restarted = false
        a.onFinish = { finishes += 1 }
        a.onUpdate = { _ in
            if !restarted {
                restarted = true
                // 重入一个**越界**新 run（shouldRun=true，真建新 driver）
                a.start(initialVelocity: 0, fromOffset: 15, minOffset: 0, maxOffset: 10)
            }
        }
        a.start(initialVelocity: 0, fromOffset: 15, minOffset: 0, maxOffset: 10)  // 第一 run（越界 spring）
        let firstDriver = fake()
        _ = firstDriver?.fire(2.0)   // abnormal-dt 终止帧外溢归一 delta（onUpdate）→ 重入 start 建新 run
        #expect(restarted)
        #expect(a.isDecelerating)                       // 新 run 存活
        let secondDriver = fake()
        #expect(secondDriver !== firstDriver)           // 确为新 driver
        #expect(secondDriver?.isInvalidated == false)   // 新 driver 未被旧续延 invalidate
        #expect(finishes == 0)                          // 旧 run onFinish 被 epoch 守门抑制（此刻仅旧 run 已终止）
        // 驱动新 run 到完成：证其真活 + 新 run 自身 onFinish 触发恰一次
        var n = 0
        while a.isDecelerating, n < 5000 { n += 1; _ = fake()?.fire(ref) }
        #expect(!a.isDecelerating)
        #expect(finishes == 1)                          // 新 run 完成触发一次（旧仍为 0，故总为 1）
    }

    // 4. P9 reset re-entrancy（codex R9-F2）：终止帧 onUpdate 内重入 resetOnSceneActive() → epoch bump → 旧 onFinish 不触发
    @Test("re-entrant resetOnSceneActive in terminal onUpdate suppresses old onFinish")
    func reentrantResetInTerminalUpdate() {
        let (a, fake) = makeWithFake()
        var finishes = 0; var did = false
        a.onFinish = { finishes += 1 }
        a.onUpdate = { _ in if !did { did = true; a.resetOnSceneActive() } }
        a.start(initialVelocity: 0, fromOffset: 15, minOffset: 0, maxOffset: 10)
        _ = fake()?.fire(2.0)   // abnormal-dt 终止帧外溢归一 delta（onUpdate）→ 重入 reset
        #expect(finishes == 0)  // 旧续延 onFinish 被 epoch 守门抑制
    }

    // 5. resetOnSceneActive 越界 → 归位 delta（consumer offset 真回 edge）+ onFinish 静默（codex Plan-R4-F1）
    @Test("resetOnSceneActive normalizes consumer offset back to edge silently")
    func resetNormalizesSilently() {
        let (a, fake) = makeWithFake()
        var updates: [CGFloat] = []; var finishes = 0
        a.onUpdate = { updates.append($0) }; a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 1000, fromOffset: 9, minOffset: 0, maxOffset: 10)
        _ = fake()?.fire(ref)        // 跨边进 spring（offset 越界 > 10）
        let updatesBeforeReset = updates.count
        a.resetOnSceneActive()       // 归位至 edge
        #expect(finishes == 0)       // 静默
        #expect(!a.isDecelerating)
        #expect(updates.count == updatesBeforeReset + 1)        // 发出一条归一 update（normalize 真发生）
        #expect(abs((9 + updates.reduce(0, +)) - 10) < 1e-6)    // **consumer offset 真回 edge 10**（破 normalize 即失败）
        #expect(fake()?.isInvalidated == true)                  // driver 失活
    }

    // 6. 零速越界 start（服务 cancelPan，codex R3-F2）→ 弹簧回弹，非 no-op
    @Test("zero-velocity overscrolled start springs back")
    func zeroVelocityOverscrolledRuns() {
        let (a, fake) = makeWithFake()
        var finishes = 0
        a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 0, fromOffset: 15, minOffset: 0, maxOffset: 10)
        #expect(a.isDecelerating)    // 非 no-op
        var n = 0
        while a.isDecelerating, n < 5000 { n += 1; _ = fake()?.fire(ref) }
        #expect(finishes == 1)
    }

    // 7. 界内亚阈速度 start → no-op
    @Test("in-bounds sub-threshold start is no-op")
    func inBoundsSubThresholdNoOp() {
        let (a, fake) = makeWithFake()
        a.start(initialVelocity: 0.1, fromOffset: 5, minOffset: 0, maxOffset: 10)
        #expect(!a.isDecelerating)
        #expect(fake() == nil)
    }

    // 8. ≤1 帧 finish 时序界（codex R7-F2/Plan-R6-F1）：zero-crossing 事件 tzc 在含它的 display tick 终止；
    //    模型 state 精确钉 edge。内向越界 offset 10.1/v=-50 → tzc≈0.00206s < 1 frame → 第 1 帧终止。
    @Test("bounce finish lands in the display tick containing the analytic zero-crossing event")
    func finishLandsInEventTick() {
        // 120Hz：tzc < ref → 第 1 帧终止
        let (a120, f120) = makeWithFake()
        var u120: [CGFloat] = []; var fin120 = 0; var finFrame120 = -1; var fr = 0
        a120.onUpdate = { u120.append($0) }; a120.onFinish = { fin120 += 1 }
        a120.start(initialVelocity: -50, fromOffset: 10.1, minOffset: 0, maxOffset: 10)
        while a120.isDecelerating, fr < 5000 {
            fr += 1; _ = f120()?.fire(ref)
            if !a120.isDecelerating, finFrame120 < 0 { finFrame120 = fr }
        }
        #expect(fin120 == 1)
        #expect(finFrame120 == 1)                                   // tzc < ref → 含事件的 tick = 第 1 帧
        #expect(abs((10.1 + u120.reduce(0, +)) - 10) < 1e-6)        // 模型 state 精确钉 edge
        // 60Hz：tzc < 2·ref → 仍第 1 帧终止（≤1 帧界跨帧率成立）
        let (a60, f60) = makeWithFake()
        var u60: [CGFloat] = []; var fin60 = 0; var finFrame60 = -1; fr = 0
        a60.onUpdate = { u60.append($0) }; a60.onFinish = { fin60 += 1 }
        a60.start(initialVelocity: -50, fromOffset: 10.1, minOffset: 0, maxOffset: 10)
        while a60.isDecelerating, fr < 5000 {
            fr += 1; _ = f60()?.fire(2 * ref)
            if !a60.isDecelerating, finFrame60 < 0 { finFrame60 = fr }
        }
        #expect(fin60 == 1)
        #expect(finFrame60 == 1)
        #expect(abs((10.1 + u60.reduce(0, +)) - 10) < 1e-6)
    }
}
```

- [ ] **Step 2: 跑测试确认编译失败**

Run: `cd ios/Contracts && swift test --filter "DecelerationAnimator bounce"`
Expected: 编译失败（`start(initialVelocity:fromOffset:minOffset:maxOffset:)` 未定义）。

- [ ] **Step 3: 改造 `DecelerationAnimator`（additive + RunModel + 共享 terminate）**

按下列**逐字替换**改 `DecelerationAnimator.swift`（既有 `protocol FrameDriving` + `RealFrameDriver` 不动）。

3a. 把存储 `private var model: DecelerationModel` 替换为 config 模板 + RunModel + epoch：

替换：
```swift
    private var model: DecelerationModel
```
为：
```swift
    /// 配置模板（velocity 0）：读取校验后的 friction/stopThreshold，并派生每 run 的模型。
    private let configModel: DecelerationModel
    /// 当前 run 的模型（decel 或 bounce）。每次 start 重建。
    private var runModel: RunModel
    /// run-identity epoch：start/stop/terminate 均 bump；守护终止帧回调 re-entrancy（spec P9）。
    private var runEpoch = 0

    /// decel / bounce 两路统一推进抽象，消除 tick 处理重复。
    private enum RunModel {
        case decel(DecelerationModel)
        case bounce(EdgeBounceModel)
        mutating func advance(dt: CGFloat) -> FrameOutcome {
            switch self {
            case .decel(var m):
                let o = m.advance(dt: dt); self = .decel(m)
                switch o {
                case .move(let d): return .move(delta: d)
                case .stop:        return .finish(finalDelta: nil, notifyFinish: true)
                }
            case .bounce(var m):
                let o = m.advance(dt: dt); self = .bounce(m)
                return o
            }
        }
    }
```

3b. 两个 `init` 中 `self.model = DecelerationModel(...)` 替换为 configModel + runModel：

替换（两处 init 各一行）。**用 local `config`**（不可读 `self.configModel` 派生 `runModel`——`makeDriver` 等尚未初始化，Swift 报 "self used before all stored properties initialized"，codex Plan-R5-F1）：
```swift
        self.model = DecelerationModel(friction: friction, stopThreshold: stopThreshold)
```
为：
```swift
        let config = DecelerationModel(friction: friction, stopThreshold: stopThreshold)
        self.configModel = config
        self.runModel = .decel(config)
```

3c. 替换既有 `start(initialVelocity:)`（行为 byte-for-byte 不变，仅重构存储 + 抽 `beginRun`）+ 追加 bounce start：

替换整个 `public func start(initialVelocity:)`：
```swift
    public func start(initialVelocity: CGFloat) {
        stop()
        guard initialVelocity.isFinite, abs(initialVelocity) >= model.stopThreshold else { return }
        currentGeneration &+= 1
        let gen = currentGeneration
        model.velocity = initialVelocity
        isDecelerating = true
        driver = makeDriver { [weak self] dt in
            guard let self, self.currentGeneration == gen else { return false }
            self.handleTick(dt: dt, generation: gen)
            return self.isDecelerating
        }
    }
```
为：
```swift
    public func start(initialVelocity: CGFloat) {
        stop()
        guard initialVelocity.isFinite, abs(initialVelocity) >= configModel.stopThreshold else { return }
        var m = configModel
        m.velocity = initialVelocity
        runModel = .decel(m)
        beginRun()
    }

    /// 边缘回弹启动面（Wave 3 顺位 11）：注入初速度 + 当前 offset + 分离 offset 边界。
    /// 几何无效 / 界内亚阈速度 → no-op（不建驱动、不触发回调）。零速越界仍回弹（服务 cancelPan）。
    public func start(initialVelocity: CGFloat, fromOffset offset: CGFloat,
                      minOffset: CGFloat, maxOffset: CGFloat) {
        stop()
        let model = EdgeBounceModel(initialVelocity: initialVelocity, offset: offset,
                                    minOffset: minOffset, maxOffset: maxOffset,
                                    friction: configModel.friction,
                                    stopThreshold: configModel.stopThreshold)
        guard model.shouldRun else { return }
        runModel = .bounce(model)
        beginRun()
    }

    /// 共享启动尾：bump epoch + generation、置 isDecelerating、建驱动。
    private func beginRun() {
        runEpoch &+= 1
        currentGeneration &+= 1
        let gen = currentGeneration
        isDecelerating = true
        driver = makeDriver { [weak self] dt in
            guard let self, self.currentGeneration == gen else { return false }
            self.handleTick(dt: dt, generation: gen)
            return self.isDecelerating
        }
    }
```

3d. 替换 `stop()`（加 epoch bump；去掉对 `model.velocity` 的直接写——每 start 重建模型）：

替换：
```swift
    public func stop() {
        isDecelerating = false
        model.velocity = 0
        driver?.invalidate()
        driver = nil
    }
```
为：
```swift
    public func stop() {
        runEpoch &+= 1
        isDecelerating = false
        driver?.invalidate()
        driver = nil
    }
```

3e. 替换 `resetOnSceneActive()`（bounce 越界经共享 terminate 归位；decel 静默 stop）：

替换：
```swift
    public func resetOnSceneActive() {
        stop()
    }
```
为：
```swift
    public func resetOnSceneActive() {
        if isDecelerating, case .bounce(var m) = runModel {
            let norm = m.normalizeToEdgeDelta()
            runModel = .bounce(m)
            terminate(finalDelta: norm, notifyFinish: false)   // 归位 + 静默（spec §五）
        } else {
            stop()
        }
    }
```

3f. 替换 `handleTick(dt:generation:)`（经 RunModel + FrameOutcome + 共享 terminate）+ 追加 `terminate`：

替换整个 `func handleTick(dt:generation:)`：
```swift
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
```
为：
```swift
    func handleTick(dt: CGFloat, generation: Int) {
        guard isDecelerating, generation == currentGeneration else { return }
        switch runModel.advance(dt: dt) {
        case .move(let delta):
            if delta != 0 { onUpdate?(delta) }   // 累加器在 dt<refInterval 帧可返 0（既有路径 .move 恒非 0，guard 无害）
        case .finish(let finalDelta, let notifyFinish):
            terminate(finalDelta: finalDelta, notifyFinish: notifyFinish)
        }
    }

    /// 共享终止 handler（re-entrancy-safe，spec R4-F3/R5-F3/R9-F2）：handleTick `.finish`
    /// 与 resetOnSceneActive 归位都经此唯一路径。先脱离 run（bump epoch + 失活）再回调；
    /// onFinish 仅在未被重入的 start/stop/terminate 改动 run-identity 时触发。
    private func terminate(finalDelta: CGFloat?, notifyFinish: Bool) {
        runEpoch &+= 1
        let myEpoch = runEpoch
        isDecelerating = false
        driver?.invalidate()
        driver = nil
        // 集中的非有限守门（codex Plan-R3-F1）：绝不把 ±inf/NaN delta 转发给 consumer 污染 reducer。
        if let finalDelta, finalDelta.isFinite, finalDelta != 0 { onUpdate?(finalDelta) }   // 回调可能重入 start/stop/reset
        if notifyFinish, runEpoch == myEpoch { onFinish?() }
    }
```

- [ ] **Step 4: 跑测试确认通过 + 既有动画器测试零改动全绿**

Run: `cd ios/Contracts && swift test 2>&1 | tail -8`
Expected: PASS；`DecelerationAnimator bounce` 全过；**既有 `DecelerationAnimator` 13+ 测试零改动通过**（P7 回归门）；总数全绿。

> 若既有 `DecelerationAnimatorTests` 有失败：说明 P7 parity 破坏，**停下排查**（不得改既有测试）。重点查 `start(initialVelocity:)` 的 guard 是否仍用校验后的 `configModel.stopThreshold`、move-then-stop 序列是否保持。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationAnimatorBounceTests.swift
git commit -m "feat(bounce): DecelerationAnimator additive bounce path + re-entrancy-safe terminate"
```

---

## Task 4: 验收文档 + 全量验证 + 范围 gate

**Files:**
- Create: `docs/superpowers/acceptance/2026-06-11-pr-wave3-11-edge-bounce.md`

- [ ] **Step 1: 写验收文档**

创建 `docs/superpowers/acceptance/2026-06-11-pr-wave3-11-edge-bounce.md`，含（中文、非 coder 可执行、action/expected/pass-fail；禁用 `.claude/workflow-rules.json` forbidden phrases）：

1. **范围 gate**：`git diff --stat origin/main...HEAD` 仅列 `DecelerationModel.swift`/`EdgeBounceModel.swift`/`DecelerationAnimator.swift` + 3 测试 + 3 doc；**不含** `RenderStateBuilder/TrainingEngine/ChartContainerView/Reducer`。
2. **既有测试零改动**：`git diff origin/main...HEAD -- ios/Contracts/Tests/.../DecelerationModelTests.swift ios/Contracts/Tests/.../DecelerationAnimatorTests.swift` 为空（P7）。
3. **全量绿**：`cd ios/Contracts && swift test` → 0 failures，总数 = 799 + 新增。
4. **Catalyst CI**：`Mac Catalyst build-for-testing on macos-15` required check 通过（编译+链接，不跑运行时）。
5. **residual `W3-11-R1` 显式记**（live 可见接线 + stop() caller-intent + cancelPan + 全几何 bounds 失效 + bounce device/sim runbook 实测 deferred 折入顺位 3 / 3 后 fast-follow）。
6. **runbook deferral 诚实条款**：组件无可见运行时，bounce device/sim runbook 随 W3-11-R1 交付；本 PR 验证 = 确定性单测。

每条给 action（命令）/ expected（输出）/ pass-fail 勾选位。

- [ ] **Step 2: 运行范围 gate 自检（fail-closed 全仓 allowlist，codex Plan-R7-F1）**

Run（在 worktree 根）:
```bash
set -euo pipefail
ALLOW='ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationModel.swift
ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift
ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/EdgeBounceModel.swift
ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationModelBoundaryTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/EdgeBounceModelTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationAnimatorBounceTests.swift
docs/superpowers/specs/2026-06-11-pr-wave3-11-edge-bounce-design.md
docs/superpowers/plans/2026-06-11-pr-wave3-11-edge-bounce.md
docs/superpowers/acceptance/2026-06-11-pr-wave3-11-edge-bounce.md'
changed=$(git diff --name-only origin/main...HEAD)        # set -e：git 失败即 abort（fail-closed）
violations=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  grep -Fxq -- "$f" <<<"$ALLOW" || { echo "SCOPE-VIOLATION: $f"; violations=$((violations+1)); }
done <<<"$changed"
[ "$violations" -eq 0 ] && echo "SCOPE-OK" || { echo "SCOPE-FAIL ($violations 个越界文件)"; exit 1; }
```
Expected: `SCOPE-OK`（**每个** changed 文件都在 allowlist 内；任一越界文件 → 非零退出）。
> fail-closed：`set -e` 下 `git diff` 失败即 abort（不再误落 SCOPE-OK）；逐文件比对全仓 allowlist（不止 `ios/Contracts/Sources`）。

- [ ] **Step 3: 全量测试**

Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: `Test run with N tests in M suites passed`，0 failures，N ≥ 799 + 新增。

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/acceptance/2026-06-11-pr-wave3-11-edge-bounce.md
git commit -m "docs(bounce): acceptance checklist + W3-11-R1 residual/runbook deferral"
```

---

## Self-Review（plan 作者执行）

**Spec coverage：** P1 钉边界（outwardSettlesAtEdge + exactEdgeOutwardFling）/ P2 首次过边 clamp（inwardClampsNoCrossing）/ P3 帧率无关端到端（方案 A 累加器，紧容差，覆盖 v1000/2000/5000）+ 弹簧分区不变 + 累加器分区不变 + zero-crossing 事件时刻 + animator ≤1 帧界（endToEndCrossingFrameRates + springPartitionInvariantState + Task1 accumulatorPartitionInvariant + springZeroCrossingEventTime + Task3 finishLandsInEventTick）/ P4 within-substep parity（Task1 refAlignedParity + accumulatorWithinSubstepParity + inBoundsNoSpring + Task3 noCrossingLifecycleParity〔ref 对齐〕）/ **P5 单调性（peakMonotonicity：v↑→峰值↑ / k↑→峰值↓ + finiteness）**/ P6 防御（nonFiniteVelocityNormalizes + nonFiniteBoundsInert + extreme/largeEdge/oppositeExtreme + Task1 abnormalDt）/ P7 既有零改动（Task3 Step4 gate + Task1 refAlignedParity + carry 默认 0）/ P8 原子终止+finalDelta+onFinish 一致（abnormalDtOverscrolled + **sameTickMultiPhaseFinalDelta** + Task3 bounceSettles 累积落 edge）/ P9 re-entrancy（reentrantStart/ResetInTerminalUpdate）/ W3-11-R1 + runbook deferral（Task4）。**全覆盖。**

**类型一致性：** `BoundaryOutcome`（Task1）/ `FrameOutcome`（Task2 定义，Task3 复用）/ `EdgeBounceModel.advance→FrameOutcome` / `RunModel.advance→FrameOutcome` / `start(initialVelocity:fromOffset:minOffset:maxOffset:)` / `normalizeToEdgeDelta()` / `shouldRun`/`debugOffset`/`debugOverscroll` —— 跨 Task 签名一致。

**Placeholder 扫描：** 无 TBD/TODO；生产代码 + 关键测试均完整。EdgeBounceModelTests 的 `run` helper 含完整实现。

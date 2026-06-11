# Wave 3 顺位 11 — 边缘 bounce 动画（组件层隔离）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一个纯物理、几何无关、可注入边界的边缘回弹组件（`EdgeBounceModel` + `DecelerationModel` boundary-aware 推进 + `DecelerationAnimator` additive bounce 路径），完全单测闭合；实时可见接线 deferred 为 residual `W3-11-R1`。

**Architecture:** 减速段**复用 `DecelerationModel` damp-then-move 律**（新增 boundary-aware 推进，子步内跨边停在 edge 报帧相对剩余时间，无跨边时逐帧等价既有 `advance`）；越界段用**临界阻尼解析弹簧**（ζ=1 闭式传播 + 首次过边 clamp + 渐近 settle）。动画器新增 bounce-enabled 启动面，经统一 `FrameOutcome` + 共享 re-entrancy-safe `terminate`，既有 `start(initialVelocity:)`/`DecelerationModel.advance` 行为 byte-for-byte 不变。

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

    // A. 无跨边时与 advance(dt:) 逐帧 delta + 终止序列严格相等（P4/P7 reduce 证）
    @Test("no-crossing reduces to advance(dt:) frame-by-frame")
    func noCrossingParity() {
        // 边界远在前方（10_000pt），永不跨边
        var plain = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        var bounded = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        var safety = 0
        while true {
            safety += 1; #expect(safety < 5000)
            let p = plain.advance(dt: ref)
            let b = bounded.advance(dt: ref, boundaryDistance: 10_000)
            switch (p, b) {
            case (.move(let dp), .moved(let db)):
                #expect(abs(dp - db) < 1e-12)
            case (.stop, .stopped(let db)):
                #expect(db == 0)
                return                                  // 两者同帧终止
            default:
                Issue.record("outcome mismatch: \(p) vs \(b)"); return
            }
        }
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

在 `DecelerationModel.swift` 的 `struct DecelerationModel { ... }` **内部**、`advance(dt:)` 方法**之后**追加（既有成员一行不改）：

```swift
    /// 单帧 boundary-aware 推进结果。
    enum BoundaryOutcome: Equatable, Sendable {
        case moved(delta: CGFloat)                                            // 推进 delta，仍在界内
        case stopped(delta: CGFloat)                                          // 界内自然停（速度 < 阈值）；delta 可为 0
        case crossed(delta: CGFloat, velocity: CGFloat, remainingTime: CGFloat) // 抵 edge：delta 恰到 edge；velocity=跨边速度；remainingTime=帧相对剩余
    }

    /// 与 `advance(dt:)` 同 damp-then-move 子步律，但当累积位移在本帧内抵达 `boundaryDistance`
    /// （带符号，delta-空间，= edge−当前offset）时，停在 edge 并报跨边速度 + **帧相对**剩余时间
    /// （含跨边前所有完整子步，spec R10-F1）。无跨边时逐帧 delta 与 `advance(dt:)` 严格相等（spec P4/P7）。
    mutating func advance(dt: CGFloat, boundaryDistance: CGFloat) -> BoundaryOutcome {
        guard dt > 0, dt < 1.0 else { velocity = 0; return .stopped(delta: 0) }
        var remaining = dt
        var consumed: CGFloat = 0
        var totalDelta: CGFloat = 0
        while remaining > 1e-9 {
            let step = Swift.min(remaining, refInterval)
            velocity *= pow(friction, step / refInterval)
            guard velocity.isFinite else { velocity = 0; return .stopped(delta: totalDelta) }
            if abs(velocity) < stopThreshold { velocity = 0; break }
            // 子步内匀速（velocity 已在步首衰减）；检查是否抵达边界
            let need = boundaryDistance - totalDelta
            if need != 0, (need > 0) == (velocity > 0), abs(velocity * step) >= abs(need) {
                let tWithin = need / velocity                       // ∈ (0, step]
                return .crossed(delta: boundaryDistance, velocity: velocity,
                                remainingTime: dt - (consumed + tWithin))
            }
            totalDelta += velocity * step
            consumed += step
            remaining -= step
        }
        if velocity == 0 { return totalDelta != 0 ? .moved(delta: totalDelta) : .stopped(delta: 0) }
        return .moved(delta: totalDelta)
    }
```

- [ ] **Step 4: 跑测试确认通过 + 既有全绿**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: PASS；总数 ≥ 799 + 6 新（DecelerationModelBoundaryTests）；既有 `DecelerationModel` 15 测零改动通过。

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

    // P3: 弹簧 state 分区不变（给定同 seed，不同 dt 切分末态一致）
    @Test("spring state is partition-invariant given identical seed")
    func springPartitionInvariant() {
        // 越界起点（spring 相），同初值不同 dt 切分 → 末 offset 一致
        func endOffset(dt: CGFloat) -> CGFloat {
            var m = EdgeBounceModel(initialVelocity: 0, offset: 15, minOffset: 0, maxOffset: 10)
            var frames = 0
            while frames < 5000 {
                frames += 1
                if case .finish = m.advance(dt: dt) { break }
            }
            return m.debugOffset
        }
        #expect(abs(endOffset(dt: ref) - endOffset(dt: ref / 3)) < 1e-6)
        #expect(abs(endOffset(dt: ref) - 10) < 1e-6)
    }

    // P3 端到端（codex R8-F1/R10-F1）：始界内·跨边，多子步跨边 case → 不同帧率 seed/峰值容差内一致
    @Test("end-to-end crossing seeds spring near edge across frame rates")
    func endToEndCrossingFrameRates() {
        func peak(dt: CGFloat) -> CGFloat {
            // bounds [0, 1000], offset 990, velocity +1000 → 冲过 1000（约 130pt 总滑行 → 远超 → 跨边）
            var m = EdgeBounceModel(initialVelocity: 1000, offset: 990, minOffset: 0, maxOffset: 1000)
            var p: CGFloat = 0
            var frames = 0
            while frames < 5000 {
                frames += 1
                switch m.advance(dt: dt) {
                case .move: p = Swift.max(p, m.debugOverscroll)
                case .finish: return p
                }
            }
            return p
        }
        // 60Hz vs 120Hz 峰值穿透在 decel 子步容差内（非聚合整帧过冲的大差）
        #expect(abs(peak(dt: ref) - peak(dt: 2 * ref)) < 1.0)
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
        let geomValid = minOffset.isFinite && maxOffset.isFinite
            && minOffset <= maxOffset && offset.isFinite
        self.geometryValid = geomValid
        self.minOffset = geomValid ? minOffset : 0
        self.maxOffset = geomValid ? maxOffset : 0
        let k = (stiffness.isFinite && stiffness > 0) ? stiffness : EdgeBounceModel.defaultStiffness
        self.omega = sqrt(k)
        self.posTol = (posTol.isFinite && posTol > 0) ? posTol : EdgeBounceModel.defaultPosTol
        self.velTol = (velTol.isFinite && velTol > 0) ? velTol : EdgeBounceModel.defaultVelTol
        // 净化非有限速度（codex R10-F2）：几何有效时不因坏速度 strand 越界 offset
        let v = initialVelocity.isFinite ? initialVelocity : 0
        self.velocity = v
        self.offset = offset
        self.decel = DecelerationModel(friction: friction, stopThreshold: stopThreshold, velocity: v)
        // 初始相 + springEdge
        if geomValid, offset > maxOffset {
            self.phase = .springing; self.springEdge = self.maxOffset
        } else if geomValid, offset < minOffset {
            self.phase = .springing; self.springEdge = self.minOffset
        } else {
            self.phase = .decelerating; self.springEdge = (v >= 0) ? self.maxOffset : self.minOffset
        }
    }

    /// 是否值得启动一次 run（几何无效 → 不运行；界内且亚阈速度 → 无可动 → 不运行）。
    var shouldRun: Bool {
        guard geometryValid else { return false }
        if phase == .springing { return true }                 // 已越界 → 需回弹
        return abs(velocity) >= decel.stopThreshold            // 界内 → 需有惯性
    }

    // 测试缝（internal，@testable 可见）
    var debugOffset: CGFloat { offset }
    /// 越过最近被违反边界的量（界内 = 0；正 = 越上界，负 = 越下界）。供峰值穿透测量。
    var debugOverscroll: CGFloat {
        if offset > maxOffset { return offset - maxOffset }
        if offset < minOffset { return offset - minOffset }
        return 0
    }

    mutating func advance(dt: CGFloat) -> FrameOutcome {
        let frameEntry = offset
        guard geometryValid else { return .finish(finalDelta: nil, notifyFinish: true) }
        // abnormal dt（含 dt≥1.0 后台恢复）：归位（越界）+ 触发 onFinish（与既有契约一致，codex R6-F3）
        guard dt > 0, dt < 1.0 else {
            switch phase {
            case .springing:
                offset = springEdge; velocity = 0
                let d = offset - frameEntry
                return .finish(finalDelta: d == 0 ? nil : d, notifyFinish: true)
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

    // 弹簧相：临界阻尼 ζ=1 解析闭式；首次过边 clamp + 渐近 settle
    private mutating func springStep(tau: CGFloat, frameEntry: CGFloat) -> FrameOutcome {
        let x = offset - springEdge
        let v = velocity
        let A = x
        let B = v + omega * x
        // 首次过边 zero-crossing（codex R1-F2）：x 跨 0 → clamp + settle
        if B != 0 {
            let tzc = -A / B
            if tzc > 0, tzc <= tau {
                offset = springEdge; velocity = 0
                return .finish(finalDelta: offset - frameEntry, notifyFinish: true)
            }
        }
        // 解析推进 tau（任意分区精确，spec P3）
        let e = exp(-omega * tau)
        let xNew = (A + B * tau) * e
        let vNew = (B * (1 - omega * tau) - omega * A) * e
        offset = springEdge + xNew
        velocity = vNew
        // 渐近 settle-threshold（≤1 帧有界回调时序，spec R7-F2）
        if abs(xNew) < posTol && abs(vNew) < velTol {
            offset = springEdge; velocity = 0
            return .finish(finalDelta: offset - frameEntry, notifyFinish: true)
        }
        return .move(delta: offset - frameEntry)
    }

    /// 后台/reset 归位：越界 → 钉 edge，返回归一 delta（nil 若无需归位）。
    mutating func normalizeToEdgeDelta() -> CGFloat? {
        guard phase == .springing else { return nil }
        let prev = offset
        offset = springEdge; velocity = 0
        let d = offset - prev
        return d == 0 ? nil : d
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

    // 3. P9 re-entrancy：终止帧 onUpdate 内重入 start() → 新 run 存活 + 旧 onFinish 不触发
    @Test("re-entrant start in terminal onUpdate keeps new run, suppresses old onFinish")
    func reentrantStartInTerminalUpdate() {
        let (a, fake) = makeWithFake()
        var finishes = 0; var restarted = false
        a.onFinish = { finishes += 1 }
        a.onUpdate = { _ in
            if !restarted {
                restarted = true
                a.start(initialVelocity: 0, fromOffset: 5, minOffset: 0, maxOffset: 10) // 界内亚阈 → no-op? 用越界确保启动
            }
        }
        // 用一个会发出归一 delta 的终止：abnormal-dt 越界 → finish 带 finalDelta（触发 onUpdate）
        a.start(initialVelocity: 0, fromOffset: 15, minOffset: 0, maxOffset: 10)  // 越界 spring
        _ = fake()?.fire(2.0)   // abnormal dt → 归位 delta（onUpdate）+ 本应 onFinish；但 onUpdate 重入 start
        // onUpdate 里 start(.. fromOffset 5 界内 v=0) → shouldRun=false → no-op；epoch 仍 bump（stop 内）
        // 关键断言：旧 onFinish 因 epoch 改变被抑制
        #expect(finishes == 0)
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

    // 5. resetOnSceneActive 越界 → 归位 delta + onFinish 静默
    @Test("resetOnSceneActive normalizes overscroll silently")
    func resetNormalizesSilently() {
        let (a, fake) = makeWithFake()
        var updates: [CGFloat] = []; var finishes = 0
        a.onUpdate = { updates.append($0) }; a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 1000, fromOffset: 9, minOffset: 0, maxOffset: 10)
        _ = fake()?.fire(ref)        // 跨边进 spring（offset 越界）
        a.resetOnSceneActive()       // 归位至 edge
        #expect(finishes == 0)       // 静默
        #expect(!a.isDecelerating)
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

替换（两处 init 各一行）：
```swift
        self.model = DecelerationModel(friction: friction, stopThreshold: stopThreshold)
```
为：
```swift
        self.configModel = DecelerationModel(friction: friction, stopThreshold: stopThreshold)
        self.runModel = .decel(self.configModel)
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
            onUpdate?(delta)
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
        if let finalDelta, finalDelta != 0 { onUpdate?(finalDelta) }   // 此回调可能重入 start/stop/reset
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

- [ ] **Step 2: 运行范围 gate 自检**

Run:
```bash
cd "<worktree-root>" && git diff --stat origin/main...HEAD -- ios/Contracts/Sources \
 | grep -E "RenderStateBuilder|TrainingEngine|ChartContainerView|Reducer" && echo "SCOPE-VIOLATION" || echo "SCOPE-OK"
```
Expected: `SCOPE-OK`（无 engine/geometry 改动）。

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

**Spec coverage：** P1 钉边界（Task2 outwardSettlesAtEdge）/ P2 首次过边 clamp（inwardClampsNoCrossing）/ P3 弹簧分区不变 + 端到端跨边（springPartitionInvariant + endToEndCrossingFrameRates + Task1 multi-substep）/ P4 界内 parity（inBoundsNoSpring + Task3 noCrossingLifecycleParity）/ P5 穿透有界（peakOverscroll>0 + 端到端）/ P6 防御（nonFiniteVelocityNormalizes + nonFiniteBoundsInert + Task1 abnormalDt）/ P7 既有零改动（Task3 Step4 gate）/ P8 原子终止+finalDelta+onFinish 一致（abnormalDtOverscrolled）/ P9 re-entrancy（reentrantStart/ResetInTerminalUpdate）/ W3-11-R1 + runbook deferral（Task4）。**全覆盖。**

**类型一致性：** `BoundaryOutcome`（Task1）/ `FrameOutcome`（Task2 定义，Task3 复用）/ `EdgeBounceModel.advance→FrameOutcome` / `RunModel.advance→FrameOutcome` / `start(initialVelocity:fromOffset:minOffset:maxOffset:)` / `normalizeToEdgeDelta()` / `shouldRun`/`debugOffset`/`debugOverscroll` —— 跨 Task 签名一致。

**Placeholder 扫描：** 无 TBD/TODO；生产代码 + 关键测试均完整。EdgeBounceModelTests 的 `run` helper 含完整实现。

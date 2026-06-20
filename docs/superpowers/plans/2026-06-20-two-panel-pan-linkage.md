# 两图 pan 时间对齐联动（RFC #4）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 拖任一 K 线面板横向滚动时，另一面板按同一全局 tick 重锚（两图右缘时间对齐），含松手惯性减速逐帧同步。

**Architecture:** 新建平台无关纯逻辑 `PanLinkage`（tick↔offset 跨周期换算，复用 `RenderStateBuilder` 几何）；`TrainingEngine` 在三个具名 gesture 函数（`beginPan`/`applyPanOffset(renderBounds:)`/`floorOrFullClampedOffsetDelta`）的 leader 帧后追加 `propagateLinkage(fromLeader:)`，单向经现有 `.offsetApplied` 驱动 follower。复用 `.offsetApplied`/`.panStarted`，不碰冻结 C1b 契约/M0.3 类型，不 bump CONTRACT_VERSION。

**Tech Stack:** Swift 6 / SwiftUI（iOS 17+ / Mac Catalyst）/ Swift Testing / Swift Package `KlineTrainerContracts`（`ios/Contracts`）。

## Global Constraints

逐条来自 spec `docs/superpowers/specs/2026-06-20-two-panel-pan-linkage-design.md`，每个 Task 隐含遵守：

- **不碰冻结项**：`Period`/`PanelId`/`KLineCandle`（M0.3，`Models.swift:11/45/59`）、`ChartAction`/`PanelViewState`/`ChartReduceEffect`（C1b 契约）字面零改。**不新增 ChartAction case**；follower 驱动复用现有 `.offsetApplied(deltaPixels:)`，模式同步复用 `.panStarted`。
- **不 bump CONTRACT_VERSION**（无 Codable/DDL/模型/契约触点）。
- **leader 行为一字不改**（D12）：联动是在 leader 各帧**之后追加** follower 驱动；`beginPan`/`applyPanOffset`/`floorOrFull` 现有体不动，仅尾部追加。
- **联动只挂三个具名 gesture 函数**（D5）：`beginPan`/`applyPanOffset(deltaPixels:renderBounds:panel:)`/`floorOrFullClampedOffsetDelta`。**不**挂通用 `applyOffsetDelta`、不挂 `interruptDeceleration`、不挂 `resetOffsetAfterAutoTracking`（后者已对两面板 lockstep，挂上会双驱）。
- **单向 leader→follower 无反噬**（D8/R4）：`propagateLinkage` 经 `applyOffsetDelta`→`reduce(.offsetApplied)` 直接 reduce，不重入 gesture 函数。
- **follower clamp 是安全网**（M1）：`followerOffset` 末尾 clamp `[minOffset=0, maxOffset]`；跨周期 `wholeShift` 可为负，不依赖任何 wholeShift≥0 保证。
- **单一几何真相**（D9/M2）：`PanLinkage` 只经 `RenderStateBuilder.{geometryCore, currentCandleIndex, offsetBounds}` 派生 step/currentIdx，**不**在引擎调用点手算几何标量。
- **follower 模式一致性**（D7）：`beginPan(leader)` 时对 follower 也发 `.panStarted`（drawing 态 reducer 返 `.none` 自然不动，D10）。
- 测试边界：`PanLinkage` 纯逻辑 + `propagateLinkage` 引擎接线**都 host 测**（`@MainActor` 同步断言 follower offset，与现有 `TrainingEngineBounceWiringTests` 同款）；仅 `DisplayLink` 节奏/视觉观感靠 Catalyst 编译闸 + 模拟器人工。

---

## File Structure

| 文件 | 责任 | Task |
|------|------|------|
| `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/PanLinkage.swift` | **新建**。纯路由换算 `rightEdgeTick`/`followerOffset`，复用 RenderStateBuilder 几何 | 1 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/PanLinkageTests.swift` | **新建**。Task 1 红绿（跨周期换算/clamp 两端/round-trip/FP/退化） | 1 |
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | **改**：加 `follower(of:)`+`propagateLinkage(fromLeader:)` 私有 helper；3 个 gesture 函数尾追加 propagate + beginPan follower 模式同步 | 2 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePanLinkageTests.swift` | **新建**。Task 2 引擎接线 host 测（follower 被驱动/D7/D10/R7/减速帧跟随） | 2 |
| `kline_trainer_plan_v1.5.md` / `kline_trainer_modules_v1.4.md` | 双面板独立描述增补 pan 时间联动语义（不删「各自独立」） | 3 |
| `docs/superpowers/acceptance/2026-06-20-two-panel-pan-linkage-acceptance.md` | **新建**验收清单 | 3 |

---

## Task 1: PanLinkage 纯逻辑（host TDD）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/PanLinkage.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/PanLinkageTests.swift`

**Interfaces:**
- Consumes: `RenderStateBuilder.{geometryCore(mainFrameWidth:rawVisible:candleCount:currentIdx:)→GeometryCore(.candleStep/.visibleCount), offsetBounds(mainFrameWidth:rawVisible:candleCount:currentIdx:)→OffsetBounds(.minOffset/.maxOffset/.candleStep), currentCandleIndex(candles:tick:)→Int}`（均 internal static，同模块可调）；`ChartPanelFrames.split(in:).mainChart.width`；`KLineCandle.endGlobalIndex`。
- Produces（Task 2 消费）：`PanLinkage.rightEdgeTick(offset:candles:rawVisible:bounds:tick:)->Int` 与 `PanLinkage.followerOffset(targetTick:candles:rawVisible:bounds:tick:)->CGFloat`。

- [ ] **Step 1: Write the failing tests**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/PanLinkageTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/PanLinkageTests.swift
// Spec: docs/superpowers/specs/2026-06-20-two-panel-pan-linkage-design.md §4.2
// 平台无关纯逻辑：tick↔offset 跨周期换算的红绿覆盖（host 直跑）。
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("PanLinkage routing")
struct PanLinkageTests {
    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)   // mainChart 宽近 800；rawVisible=80 → step≈10
    static let rawVisible = 80

    /// 最小 candle：仅 endGlobalIndex 有意义（换算只读它），其余填占位。
    private func cand(_ end: Int, _ period: Period = .m3) -> KLineCandle {
        KLineCandle(period: period, datetime: Int64(end), open: 1, high: 1, low: 1, close: 1,
                    volume: 0, amount: nil, ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                    macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: end, endGlobalIndex: end)
    }
    /// 连续 endGlobalIndex = 1...n（m3 满轴语义）。
    private func contiguous(_ n: Int) -> [KLineCandle] { (1...n).map { cand($0) } }

    // MARK: - 同周期 round-trip：forward→inverse 还原到 whole-candle 粒度（核心 killer）

    @Test("同周期 round-trip：offset → tick → offset 还原（whole-candle 粒度）")
    func sameRoundTrip() {
        let c = contiguous(200)
        let tick = 150
        let t = PanLinkage.rightEdgeTick(offset: 300, candles: c, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        let back = PanLinkage.followerOffset(targetTick: t, candles: c, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        // offset=300, step≈10 → wholeShift=30 → 还原 offset≈300（whole-candle；sub-candle 余量不传播）
        #expect(abs(back - 300) < 10.0)   // 容差 1 个 candleStep（whole-candle 粒度）
    }

    // MARK: - 同 tick 对齐：offset=0 → 右缘=最新 → follower offset=0

    @Test("offset=0 → 右缘 tick = 当前 candle endGlobalIndex；followerOffset 还原 0")
    func zeroAligns() {
        let c = contiguous(200)
        let tick = 150
        let curIdx = RenderStateBuilder.currentCandleIndex(candles: c, tick: tick)
        let t = PanLinkage.rightEdgeTick(offset: 0, candles: c, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        #expect(t == c[curIdx].endGlobalIndex)
        let off = PanLinkage.followerOffset(targetTick: t, candles: c, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        #expect(off == 0)
    }

    // MARK: - 跨周期：follower 右缘重投影回同一 tick（不硬编码数值的真 killer）

    @Test("跨周期：follower offset 使其右缘 tick == leader 右缘 tick（候选粒度内）")
    func crossPeriodReprojects() {
        let upper = contiguous(200)                       // 细：endGlobalIndex 1..200（每 tick 一根）
        let lower = (1...50).map { cand($0 * 4) }          // 粗：endGlobalIndex 4,8,...,200（每 4 tick 一根）
        let tick = 160
        let leaderTick = PanLinkage.rightEdgeTick(offset: 250, candles: upper, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        let fOff = PanLinkage.followerOffset(targetTick: leaderTick, candles: lower, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        let fTick = PanLinkage.rightEdgeTick(offset: fOff, candles: lower, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        // follower 右缘候选的 endGlobalIndex 应 >= leaderTick 且为首个覆盖它的粗 candle（currentCandleIndex 谓词）
        #expect(fTick >= leaderTick)
        #expect(fTick - leaderTick < 4)                    // 落在同一粗 candle 跨度内（4 tick）
        #expect(fOff >= 0)
    }

    // MARK: - clamp 两端（M1 安全网）

    @Test("M1：targetTick 落 follower 末根 → wholeShift≤0 → clamp 0")
    func clampNewEnd() {
        let lower = (1...50).map { cand($0 * 4) }           // 末根 endGlobalIndex=200
        let off = PanLinkage.followerOffset(targetTick: 200, candles: lower, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: 160)
        #expect(off == 0)                                   // 右缘=最新，offset 钳 0
    }

    @Test("M1：targetTick 远早于可见 → clamp maxOffset")
    func clampOldEnd() {
        let lower = (1...50).map { cand($0 * 4) }
        let ob = RenderStateBuilder.offsetBounds(mainFrameWidth: 800, rawVisible: Self.rawVisible, candleCount: 50, currentIdx: RenderStateBuilder.currentCandleIndex(candles: lower, tick: 160))
        let off = PanLinkage.followerOffset(targetTick: 4, candles: lower, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: 160)
        #expect(off == ob.maxOffset)                        // 最老边
    }

    // MARK: - FP 非整除 step（roundTripEdge 复用）

    @Test("FP：非整除 step（1000/21）round-trip 不漂")
    func fpNonDivisible() {
        let c = contiguous(120)
        let w = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let t = PanLinkage.rightEdgeTick(offset: 200, candles: c, rawVisible: 21, bounds: w, tick: 100)
        let back = PanLinkage.followerOffset(targetTick: t, candles: c, rawVisible: 21, bounds: w, tick: 100)
        #expect(abs(back - 200) < 1000.0 / 21.0 + 1e-6)     // 容差 1 个非整除 step
    }

    // MARK: - 退化

    @Test("空 candles → rightEdgeTick 0 / followerOffset 0（不 crash）")
    func emptyDegenerate() {
        #expect(PanLinkage.rightEdgeTick(offset: 100, candles: [], rawVisible: 80, bounds: Self.bounds, tick: 10) == 0)
        #expect(PanLinkage.followerOffset(targetTick: 100, candles: [], rawVisible: 80, bounds: Self.bounds, tick: 10) == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/Contracts && swift test --filter PanLinkageTests`
Expected: 编译失败 —— `cannot find 'PanLinkage' in scope`。

- [ ] **Step 3: Write minimal implementation**

创建 `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/PanLinkage.swift`：

```swift
// ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/PanLinkage.swift
// Spec: docs/superpowers/specs/2026-06-20-two-panel-pan-linkage-design.md（RFC #4）
//
// 平台无关纯逻辑：两面板 pan 时间对齐联动的 tick↔offset 跨周期换算。
// 是 RenderStateBuilder.makeViewport 的 offset↔index forward/inverse，**复用其几何**（geometryCore/
// currentCandleIndex/offsetBounds），不重写（D9 单一几何真相）。引擎 propagateLinkage 消费本层。
//
// 决议：D6 follower 经 .offsetApplied 驱动 / D8 follower clamp[0,maxOffset] / M1 clamp 是安全网（跨周期
// wholeShift 可为负，不依赖 wholeShift≥0 保证） / M2 调用点只传 candles+bounds，几何在此内部派生。

import Foundation
import CoreGraphics

enum PanLinkage {

    /// forward：leader 当前 offset → 其右缘可见候选的 `endGlobalIndex`（= 右缘 tick）。
    /// 内部经 geometryCore 派生 step/visibleCount/currentIdx（与 makeViewport 同源）。
    /// `wholeShift=floor(offset/step)`；右缘候选 idx = clamp(currentIdx-wholeShift, oldestRightEdge, currentIdx)，
    /// 其中 oldestRightEdge=min(visibleCount-1,currentIdx)（startIndex==0 时右缘）。
    static func rightEdgeTick(offset: CGFloat, candles: [KLineCandle],
                             rawVisible: Int, bounds: CGRect, tick: Int) -> Int {
        guard !candles.isEmpty else { return 0 }
        let mainW = ChartPanelFrames.split(in: bounds).mainChart.width
        let currentIdx = RenderStateBuilder.currentCandleIndex(candles: candles, tick: tick)
        let core = RenderStateBuilder.geometryCore(mainFrameWidth: mainW, rawVisible: rawVisible,
                                                  candleCount: candles.count, currentIdx: currentIdx)
        guard core.candleStep.isFinite, core.candleStep > 0 else { return candles[currentIdx].endGlobalIndex }
        let wholeShift = Int((offset / core.candleStep).rounded(.down))
        let oldestRightEdge = min(core.visibleCount - 1, currentIdx)
        let idx = min(max(currentIdx - wholeShift, oldestRightEdge), currentIdx)
        return candles[idx].endGlobalIndex
    }

    /// inverse：目标 tick → follower offset（右缘候选 endGlobalIndex 首个 ≥ targetTick），clamp[0,maxOffset]。
    /// **M1：clamp 是 load-bearing 安全网**——follower 不同周期数组，currentCandleIndex(_, targetTick) 钳 count-1
    /// 时可致 targetIdx>currentIdx → wholeShift 负 → offset 负 → 被 clamp 兜回 0。
    static func followerOffset(targetTick: Int, candles: [KLineCandle],
                              rawVisible: Int, bounds: CGRect, tick: Int) -> CGFloat {
        guard !candles.isEmpty else { return 0 }
        let mainW = ChartPanelFrames.split(in: bounds).mainChart.width
        let currentIdx = RenderStateBuilder.currentCandleIndex(candles: candles, tick: tick)
        let targetIdx = RenderStateBuilder.currentCandleIndex(candles: candles, tick: targetTick)
        let ob = RenderStateBuilder.offsetBounds(mainFrameWidth: mainW, rawVisible: rawVisible,
                                                candleCount: candles.count, currentIdx: currentIdx)
        guard ob.candleStep.isFinite, ob.candleStep > 0 else { return 0 }
        let wholeShift = currentIdx - targetIdx
        let raw = CGFloat(wholeShift) * ob.candleStep
        return min(max(raw, ob.minOffset), ob.maxOffset)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/Contracts && swift test --filter PanLinkageTests`
Expected: PASS —— 8 个 `@Test` 全绿，0 failures。

- [ ] **Step 5: Run full host suite (regression)**

Run: `cd ios/Contracts && swift test`
Expected: 全量 0 failures（新增 8 测试；现有零回归）。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/PanLinkage.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/PanLinkageTests.swift
git commit -m "feat(RFC#4): PanLinkage 纯逻辑 tick↔offset 跨周期换算 + host 测"
```

---

## Task 2: 引擎接线 propagateLinkage（host TDD + 集成）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePanLinkageTests.swift`

**Interfaces:**
- Consumes: Task 1 `PanLinkage.{rightEdgeTick,followerOffset}`；现有 engine 私有 helper `panelState(_:)@577`/`renderBounds(_:)@581`/`period(of:)@360`/`reduce(_:on:)@591`/`applyOffsetDelta(_:panel:)@600`，`allCandles@32`/`tick.globalTickIndex`/`upperPanel`/`lowerPanel`（`public private(set) var`）。
- Produces: 集成后的双图时间联动（终态，供人工验收）。

> `propagateLinkage` 是 `@MainActor` 同步逻辑 → host 可测（同 `TrainingEngineBounceWiringTests` 范式）。

- [ ] **Step 1: Write the failing tests**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePanLinkageTests.swift`（同周期 m3/m3 fixture 证接线；跨周期数学已由 Task 1 覆盖）：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePanLinkageTests.swift
// Spec: docs/superpowers/specs/2026-06-20-two-panel-pan-linkage-design.md §4.1/§6（M3 引擎接线）
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingEngine pan 联动接线", .serialized)
struct TrainingEnginePanLinkageTests {
    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    // 同周期 m3/m3：follower 应被驱动到与 leader 相同 offset（1:1）；跨周期换算见 PanLinkageTests。
    static func makeEngine(count: Int, tick: Int) -> (TrainingEngine, () -> [FakeFrameDriver]) {
        final class Box { var fakes: [FakeFrameDriver] = [] }
        let box = Box()
        let maxTick = count - 1
        let e = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: maxTick),
            allCandles: TrainingEngineActionsTests.m3Candles(Array(repeating: 10, count: count)),
            maxTick: maxTick, initialTick: tick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { onTick in let f = FakeFrameDriver(onTick: onTick); box.fakes.append(f); return f })
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.recordRenderBounds(Self.bounds, panel: .lower)
        return (e, { box.fakes })
    }

    @Test("拖 upper → lower 被驱动到同一 offset（同周期 1:1）")
    func dragUpperDrivesLower() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 300, renderBounds: Self.bounds, panel: .upper)
        #expect(e.upperPanel.offset > 0)
        #expect(abs(e.lowerPanel.offset - e.upperPanel.offset) < 10.0)   // follower 右缘对齐 leader（whole-candle 容差）
    }

    @Test("拖 lower → upper 被驱动（双向对称）")
    func dragLowerDrivesUpper() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        e.beginPan(panel: .lower)
        e.applyPanOffset(deltaPixels: 250, renderBounds: Self.bounds, panel: .lower)
        #expect(abs(e.upperPanel.offset - e.lowerPanel.offset) < 10.0)
    }

    @Test("D7：leader beginPan → follower 转 freeScrolling")
    func followerEntersFreeScrolling() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        e.beginPan(panel: .upper)
        if case .freeScrolling = e.lowerPanel.interactionMode {} else { Issue.record("follower 应 freeScrolling") }
    }

    @Test("减速逐帧：leader 惯性减速时 follower 同步跟随至 settle")
    func followerTracksDeceleration() {
        let (e, fakes) = Self.makeEngine(count: 200, tick: 150)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 400, renderBounds: Self.bounds, panel: .upper)
        e.endPan(velocity: -3000, renderBounds: Self.bounds, panel: .upper)
        for _ in 0..<240 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(abs(e.lowerPanel.offset - e.upperPanel.offset) < 10.0)   // settle 后仍对齐
    }

    @Test("R7：买卖成交两面板 lockstep reset 仍对齐，无双驱异常")
    func tradeResetStaysAligned() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 300, renderBounds: Self.bounds, panel: .upper)
        _ = e.buy(panel: .upper, tier: .tier1)                            // trade → resetOffsetAfterAutoTracking 两面板
        #expect(e.upperPanel.offset == 0)
        #expect(e.lowerPanel.offset == 0)                                // 两图都归 0（reset 未被联动二次驱动成非零）
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/Contracts && swift test --filter TrainingEnginePanLinkageTests`
Expected: FAIL —— `dragUpperDrivesLower` 等断言失败（当前 follower 不被驱动，`lowerPanel.offset==0` ≠ `upperPanel.offset`）；`followerEntersFreeScrolling` 失败（follower 仍 autoTracking）。

- [ ] **Step 3: 加 helper + 三处尾追加 propagate**

在 `TrainingEngine.swift` 的私有 helper 区（紧接 `reduce(_:on:)` @591-596 之后）新增：

```swift
    // MARK: RFC #4 — 两图 pan 时间对齐联动（D5/D6/D8）

    /// 另一面板。
    private func follower(of panel: PanelId) -> PanelId { panel == .upper ? .lower : .upper }

    /// leader 帧后：把 follower 右缘对齐到 leader 右缘的同一 global tick（单向，经现有 .offsetApplied）。
    /// 只由三个具名 gesture 函数（beginPan/applyPanOffset/floorOrFull）调；不挂通用 applyOffsetDelta（防与
    /// lockstep reset 双驱，D5/R7）。drawing 态 follower 被 reducer 吞（D10）。无 bounds/空 candle → no-op。
    private func propagateLinkage(fromLeader leader: PanelId) {
        let f = follower(of: leader)
        let lBounds = renderBounds(leader), fBounds = renderBounds(f)
        let lCandles = allCandles[period(of: leader)] ?? []
        let fCandles = allCandles[period(of: f)] ?? []
        guard lBounds.width > 0, fBounds.width > 0, !lCandles.isEmpty, !fCandles.isEmpty else { return }
        let leaderTick = PanLinkage.rightEdgeTick(offset: panelState(leader).offset, candles: lCandles,
                            rawVisible: panelState(leader).visibleCount, bounds: lBounds, tick: tick.globalTickIndex)
        let fTarget = PanLinkage.followerOffset(targetTick: leaderTick, candles: fCandles,
                            rawVisible: panelState(f).visibleCount, bounds: fBounds, tick: tick.globalTickIndex)
        let fCur = panelState(f).offset
        if fTarget != fCur { applyOffsetDelta(fTarget - fCur, panel: f) }   // D6（drawing 态吞 D10）
    }
```

改 `beginPan`（@663-667），在体尾追加 follower 模式同步 + 对齐（**前 3 行不动**，D12）：

```swift
    public func beginPan(panel: PanelId) {
        interruptDeceleration(panel: panel)                  // R1b-wire D10：停 + 归一中途 overscroll（H3），再 seed/.panStarted
        setDragRaw(panelState(panel).offset, panel: panel)   // R1b-drag D1：raw 基线=归一后 offset∈[0,maxOffset]（E1）
        _ = reduce(.panStarted, on: panel)
        _ = reduce(.panStarted, on: follower(of: panel))     // RFC #4 D7：follower 转 freeScrolling（drawing 态 .none 自然不动）
        propagateLinkage(fromLeader: panel)                  // RFC #4：起手对齐一次（含 interrupt-clamp 后新右缘，H1）
    }
```

改 `applyPanOffset(deltaPixels:renderBounds:panel:)`（@677-695），在末行 `if target != cur { … }` **之后**追加（**该函数体其余不动**）：

```swift
        if target != cur { applyOffsetDelta(target - cur, panel: panel) }   // L2-new：省 0-delta 空 bump
        propagateLinkage(fromLeader: panel)                                  // RFC #4：drag 每帧驱动 follower
    }
```

改 `floorOrFullClampedOffsetDelta(_:panel:)`（@621-628），在末行 `if target != cur { … }` **之后**追加（**其余不动**）：

```swift
        if target != cur { applyOffsetDelta(target - cur, panel: panel) }           // L2-new：省 0-delta 空 bump
        propagateLinkage(fromLeader: panel)                                          // RFC #4：减速/bounce 每帧驱动 follower
    }
```

> 实现者注意：`applyPanOffset` 与 `floorOrFullClampedOffsetDelta` 末行文本相同（`if target != cur { applyOffsetDelta(target - cur, panel: panel) }`），编辑时各自定位到对应函数体内追加，勿误改另一个。`interruptDeceleration`/`resetOffsetAfterAutoTracking`/通用 `applyOffsetDelta` **不加** propagate（D5/R7）。

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/Contracts && swift test --filter TrainingEnginePanLinkageTests`
Expected: PASS —— 5 个 `@Test` 全绿。

- [ ] **Step 5: Run full host suite (regression)**

Run: `cd ios/Contracts && swift test`
Expected: 全量 0 failures（leader 路径未改，现有 pan/bounce/pinch/drag 测试零回归；新增 Task1(8)+Task2(5)）。

- [ ] **Step 6: Mac Catalyst build-for-testing 编译闸**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'`
Expected: `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 7: iOS app build（集成编译）**

Run: `xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/app-derived CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 8: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePanLinkageTests.swift
git commit -m "feat(RFC#4): TrainingEngine propagateLinkage 三 gesture 入口驱动 follower（D5/D7/R7）+ host 测"
```

---

## Task 3: 冻结 spec 措辞 + 验收清单

**Files:**
- Modify: `kline_trainer_plan_v1.5.md`（§双面板独立描述 + §4.1 disambiguation）
- Modify: `kline_trainer_modules_v1.4.md`（§C 图表交互如有「每面板独立 pan」描述）
- Create: `docs/superpowers/acceptance/2026-06-20-two-panel-pan-linkage-acceptance.md`

> 纯文档。验证 = grep 确认措辞增补 + 不删「各自独立」+ 不改任何类型名。

- [ ] **Step 1: 改 plan §双面板描述（增补 pan 联动，不删独立）**

在 `kline_trainer_plan_v1.5.md`（写 plan 时实测行号；**L109** = 「PanelViewState × 2（每面板独立）」、**L552** = 「每面板独立 period/mode/zoom」、**§6.2.3 L941-948** 双 K 线区域）：
- 在双面板描述处增补一句：「**pan/scroll 时间对齐联动（RFC #4）**：拖一面板，另一面板右缘按同一全局 tick 跟随（含惯性减速逐帧）；offset 仍各面板独立存储，由引擎 `PanLinkage` 跨周期换算单向驱动。」
- **不删**「每面板独立」原文（offset 存储仍独立，仅新增联动驱动）。

- [ ] **Step 2: 改 plan §4.1 加 disambiguation**

在 `kline_trainer_plan_v1.5.md` §4.1「多周期联动步进」（**L579-601**）处加注脚：「注：此处『联动』指 **tick 步进**（一笔交易推进 globalTickIndex → 所有周期按 end_global_index 追加 K 线，既有）；与 **RFC #4 的 pan 时间联动**（拖动一图另一图右缘跟随）是两回事，勿混淆。」

- [ ] **Step 3: 改 modules（如有「每面板独立 pan」措辞）**

在 `kline_trainer_modules_v1.4.md` 搜双面板/图表交互相关条目，若有「每面板独立 pan/scroll」描述则同步增补 pan 时间联动语义；若无则跳过（grep 确认）。

- [ ] **Step 4: 创建验收清单**

创建 `docs/superpowers/acceptance/2026-06-20-two-panel-pan-linkage-acceptance.md`：

```markdown
# 验收清单：两图 pan 时间对齐联动（RFC #4）

## 1. host 单测（机器执行）
- [ ] `cd ios/Contracts && swift test --filter PanLinkageTests` → 8 个全绿。
- [ ] `cd ios/Contracts && swift test --filter TrainingEnginePanLinkageTests` → 5 个全绿。
- [ ] `cd ios/Contracts && swift test` → 全量 0 failures；净 = +13（PanLinkage 8 + 引擎接线 5），现有零回归。

## 2. Mac Catalyst 编译（机器执行）
- [ ] `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'` → `TEST BUILD SUCCEEDED`。

## 3. iOS app build（机器执行）
- [ ] `xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/app-derived CODE_SIGNING_ALLOWED=NO` → `BUILD SUCCEEDED`。

## 4. 模拟器人工验收（iPhone + seed fixture，默认 upper=60m / lower=日线）
| # | 动作 | 预期 | 通过? |
|---|------|------|------|
| 1 | 拖上图（60m）向右回看历史 | 下图（日线）右缘同步滚到**同一时刻**（时间对齐，非同像素） | ☐ |
| 2 | 拖下图（日线）回看 | 上图（60m）同步跟随到同一时刻 | ☐ |
| 3 | 拖任一图后**松手**（带速度） | 两图惯性减速**逐帧同步**滚动至停，全程不脱节 | ☐ |
| 4 | 一直拖到最老边 | follower graceful clamp，无突兀跳变/越界 | ☐ |
| 5 | 不拖时 | 两图各自 autoTracking（offset=0），右缘都在当前 tick | ☐ |
| 6 | 在一图画线后拖另一图 | 画线图暂不跟（冻结），拖动图正常；退出画线/下次操作后复位 | ☐ |
| 7 | 买卖成交 / 两指切周期 | 两图一起 reset 到最新（lockstep），仍右缘对齐 | ☐ |
| 8 | 缩放（pinch）一图 | 仅该图缩放（pinch 不联动）；若恰在最老边 overscroll 中途起 pinch/画线，另一图右缘可瞬时不跟（D13/R8 已知边界），下次 pan/trade/combo 即复位 | ☐ |

## 5. 回归确认（非编码者执行）
| # | 动作 | 预期 | 通过? |
|---|------|------|------|
| 1 | 单图 pan 物理（rubber-band/惯性/reveal 禁前窥） | leader 行为一字未变（D12） | ☐ |
| 2 | 坐标轴/网格/markers/crosshair | RFC #3 轴 + markers 跨周期一切如常 | ☐ |

## 6. Opus 4.8 xhigh 对抗性 review ledger（代 codex，user explicit）
- spec：R1 NEEDS-ATTENTION（2H/3M/2L）→ 全修 → R2 APPROVE。commits 577f44c / eb314cc / fcec521。
- plan：<填 plan-stage review 结论>。
- 实现期（subagent-driven，3 task 两阶段）：<填>。
- verification：<填 host/Catalyst/app 三项实跑>。
- branch-diff：<填整体对抗性 review 结论>。
```

- [ ] **Step 5: 验证（不改类型名 + 措辞增补）**

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
grep -n "pan/scroll 时间对齐联动\|PanLinkage" kline_trainer_plan_v1.5.md
grep -c "每面板独立" kline_trainer_plan_v1.5.md   # 应 ≥ 原值（未删）
```
Expected：增补句命中；「每面板独立」计数未减。

- [ ] **Step 6: Commit**

```bash
git add kline_trainer_plan_v1.5.md kline_trainer_modules_v1.4.md \
        docs/superpowers/acceptance/2026-06-20-two-panel-pan-linkage-acceptance.md
git commit -m "docs(RFC#4): plan/modules 双面板描述增补 pan 时间联动（不删独立）+ 验收清单"
```

---

## 实现完成后（subagent-driven 收尾）

1. **verification-before-completion**（亲跑三绿）：`cd ios/Contracts && swift test`（全量 0 fail）+ Catalyst `build-for-testing`（SUCCEEDED）+ iOS app build（SUCCEEDED）。
2. **requesting-code-review / 整体 branch-diff**：Opus 4.8 xhigh whole-branch review（merge-base `b1bad1a` → HEAD）到收敛。
3. **finishing-a-development-branch → PR + merge**：`--admin` 旁路缺失 codex-verify-pass，CI 三项须绿。回填验收 §6 ledger。

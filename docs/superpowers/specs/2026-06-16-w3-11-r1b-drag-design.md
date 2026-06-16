# W3-11-R1b-drag 拖拽期跟手橡皮筋阻尼 —— 设计文档 v1

**日期**：2026-06-16
**性质**：Wave 3 fast-follow，R1b-wire（PR #117 `c7feea8`）的 follow-up。把当前 drag 期对 offset 的**硬钳**（手指拖过最老边内容停死）升级为**带渐进阻尼的跟手橡皮筋**（手指按住拖过最老边 → 内容带阻力跟随；松手 → 弹回最老边）。最新边（reveal RFC #113 硬钳，禁前窥）**保持无给**。改 `ios/**/*.swift`（trust-boundary）→ 经 **`codex:adversarial-review`**（配额耗尽 fallback opus 4.8 xhigh）。

**父设计（继承，不复述）**：
- `docs/superpowers/specs/2026-06-15-w3-11-r1-bounce-wiring-design.md`（v2.1，bounce 接线总设计），其 §八 packaging 明列「拖拽期跟手橡皮筋阻尼 = 另一独立 follow-up **R1b-drag**，本 spec out of scope」。
- `docs/superpowers/specs/2026-06-16-w3-11-r1b-wire-design.md`（v2.5，单边化 bounce 接线，机制 A）——本文档复用其 `offsetBounds`/`bounceEdges`/`activeBounds`/`EdgeBounceModel` 启动面 + B4 单边 overscroll 渲染，**不改其物理与 B4 渲染**。

**前置（已满足）**：R1a = PR #114 `64ad07e`；R1b-wire = PR #117 `c7feea8`；reveal RFC = #113 `bb0d597` + 聚合感知 reveal #115 `7b1849a`。本分支 `worktree-wave3-w3-11-r1b-drag` off `origin/main`（`49b9cd4`，含 #117/#118/#119）。

---

## 一、问题：drag 期硬钳 vs 跟手橡皮筋

R1b-wire 后，drag `.changed` 入口 `applyPanOffset(deltaPixels:renderBounds:panel:)`（`TrainingEngine.swift:665-670`）对 offset **双边硬钳** `[minOffset, maxOffset]`：

```swift
let ob = RenderStateBuilder.offsetBounds(engine: self, panel: panel, bounds: renderBounds)
let cur = panelState(panel).offset
let target = min(max(cur + deltaPixels, ob.minOffset), ob.maxOffset)   // ← 硬钳：拖过边停死
if target != cur { applyOffsetDelta(target - cur, panel: panel) }
```

后果：手指拖过最老边（>maxOffset）时内容**停死**，与系统级滚动「拖过边带阻力跟手」体验不符。**只有松手 fling** 才经 R1b-wire 机制 A 触发弹簧 overscroll。

**R1b-drag 目标**：手指**按住**拖过最老边时，内容**带渐进阻尼跟手**（iOS 橡皮筋）；松手回弹到 maxOffset。**单边**：最新边（minOffset=0）**保持硬钳无给**（reveal 禁前窥，与 R1b-wire 单边不变量一致）。

---

## 二、机制（本 PR 锁定决策）

三处协同改动，**全部局限在 `TrainingEngine` 单指 pan 方法 + 1 个新纯函数**；**零渲染层改动**（B4 已渲 `offset>maxOffset`）。

### D1 橡皮筋须基于**累计**位移 → engine 新增 `dragRaw` 累加器

iOS 橡皮筋是**位置函数**（damped offset = f(累计 raw 位移)）。对已 damped 的 offset 再做增量 damping **不可逆**（反向拖动解绕错误）。而 arbiter 发射的是**每帧增量 deltaX**（`ChartGestureArbiter.swift:24` `onPan:(incrementalDeltaX, velocityX, phase)`，内部跟踪 cumulative）。

故 engine 维护 per-panel **raw 累加器** `dragRaw`（**未阻尼**的累计意图位移）：
- `beginPan`：`dragRaw[panel] = 当前 offset`（不变量见 §四：恒 ∈[0,maxOffset]）。
- `applyPanOffset`（每帧 `.changed`）：`dragRaw += deltaPixels`（线性累加），再由纯函数映射为可视 offset。
- `endPan` / `cancelPan`：清 `dragRaw[panel] = nil`。

线性累加 raw + 纯函数映射 → 反向拖动**正确解绕**（raw 单调随手指、offset = f(raw) 连续跟随）。

### D2 raw→offset 映射（单边橡皮筋 + 最新边硬钳 + 无滚动空间硬钳）

```
canOverscroll = ob.bounceEdges.contains(.max)          // ⟺ maxOffset > minOffset(=0)，有最老边滚动空间
dragRaw = max(0, dragRaw + deltaPixels)                // 下钳 0：最新边硬钳无给、且无「反拖死区」(见 §四 E2)
offset =
    !canOverscroll        → min(dragRaw, maxOffset)    // 无滚动空间（maxOffset==0）→ 恒 0，不给（与 R1b-wire「满屏不弹」一致）
    dragRaw <= maxOffset  → dragRaw                     // 界内 1:1（回归，与硬钳 [0,maxOffset] 逐字等价）
    else                  → maxOffset + RubberBand.damp(over: dragRaw - maxOffset, dimension: mainW)   // 最老边阻尼
```

`mainW` = 主图宽度（`ChartPanelFrames.split(in: renderBounds).mainChart.width`，与 `offsetBounds` extraction 同源）。最终 `applyOffsetDelta(offset − cur, panel)`（`offset==cur` 不派 0-delta，省空 revision bump，承袭 R1b-wire L2-new）。

**单边不变量保持**：`offset` 只可能 `>maxOffset`（最老边 overscroll，由 `dragRaw>maxOffset` 阻尼产生）；`offset<0` 永不可达（`dragRaw` 下钳 0 → offset≥0）。∴ B4 单边渲染前提不破。

### D3 松手回弹：`endPan` 从 overscroll 位置无条件弹回（**必须改，否则 strand**）

R1b-wire 的 `endPan`（`TrainingEngine.swift:683-694`）按速度分派：`v>0 ∧ .max∈bounceEdges` → bounce；否则 plain decel（full-clamp）。

drag 跟手后松手时 `offset` 可能 `>maxOffset`。若慢速松手（`v≤0` 或 `v` 很小）落 else 分支：`start(initialVelocity: v)`，当 `abs(v)<stopThreshold` 被 guard **no-op** → 动画不启动、onUpdate 不触发 → **offset strand 在界外**（真 bug：内容卡在 overscroll 位置不回弹）。

**修**：`endPan` 体首加判——**若 `offset > maxOffset`（drag 已过界）→ 无论速度方向都启动弹簧**回 maxOffset：

```
若 reduce(.panEnded(velocity)) == .startDeceleration(v):
    if offset > ob.maxOffset {                                    // ← R1b-drag 新增：drag-overscroll 必弹回
        setActiveBounds(ActiveDecel(bounds: ob, allowOverscroll: true), panel)
        animator.start(initialVelocity: v, fromOffset: offset, minOffset: ob.minOffset, maxOffset: ob.maxOffset)
    } else if v > 0 && ob.bounceEdges.contains(.max) {            // 既有：界内正速甩动 → bounce
        setActiveBounds(ActiveDecel(bounds: ob, allowOverscroll: true), panel)
        animator.start(initialVelocity: v, fromOffset: offset, minOffset: ob.minOffset, maxOffset: ob.maxOffset)
    } else {                                                      // 既有：plain decel（full-clamp）
        setActiveBounds(ActiveDecel(bounds: ob, allowOverscroll: false), panel)
        animator.start(initialVelocity: v)
    }
```

复用 `EdgeBounceModel` 既有「**零速 overscrolled 起步回弹**」相（已有测试 `zero-velocity overscrolled start springs back` 证实）。从 overscroll 位置以任意速度（含 `v≤0` 内向）启动临界阻尼（ζ=1）弹簧 → 单调收敛 maxOffset、不过冲。**零改 `EdgeBounceModel` 物理**。

> **注**：`offset > maxOffset` 与 `v>0 ∧ .max∈bounceEdges` 两分支体**完全相同**（都是 bounce 启动）；分立仅为表达「drag-overscroll 必弹（不论 v）」这一新条件。实现可合并为 `if offset > ob.maxOffset || (v > 0 && ob.bounceEdges.contains(.max))`。

### 为何不改手势契约 / 不存 cumulative-in-arbiter
驳回「让 arbiter 改传 cumulative translation」：①改 R1b-wire 刚稳定的 `onPan` 下游契约（blast radius 大、动 C7 arbiter 仲裁层）；②engine 侧 `dragRaw` 累加器零接触手势层、纯 numeric、与既有「Coordinator 喂 numeric、engine 收数值」D1 架构一致。

### 为何不复用 internal 旧 `applyPanOffset(deltaPixels:panel:)`
旧无界签名（`:659-661`）保持**逐字不变**（@testable 测试用，R1b-wire H2）；R1b-drag 只改**带 bounds 的 public 新签名**。旧签名不涉 `dragRaw`。

---

## 三、数据流（增量叠加于 R1b-wire §三）

```
arbiter.onPan(.began)
  → engine.beginPan(panel)
       interruptDeceleration(panel)              // R1b-wire D10：停进行中弹簧 + 归一中途 overscroll 到 maxOffset
       dragRaw[panel] = panelState(panel).offset // ★ R1b-drag：raw 基线 = 归一后 offset ∈[0,maxOffset]
       reduce(.panStarted)

arbiter.onPan(.changed, deltaX)
  → engine.applyPanOffset(deltaPixels:deltaX, renderBounds:view.bounds, panel)   // ★ 改：D2 映射
       ob = offsetBounds(...)
       dragRaw[panel] = max(0, dragRaw[panel] + deltaX)
       offset' = D2 映射(dragRaw, ob, mainW)
       applyOffsetDelta(offset' − offset)         // offset'>maxOffset → B4 自动渲 overscroll 间隙
       · 界内 [0,maxOffset]：1:1（回归）
       · 过最老边：阻尼跟手；反拖：raw 减、offset' 连续解绕回 maxOffset 再 1:1

arbiter.onPan(.ended, velocityX)
  → engine.endPan(velocity:velocityX, renderBounds:view.bounds, panel)           // ★ 改：D3 弹回
       dragRaw[panel] = nil
       offset>maxOffset → 弹簧回 maxOffset（不论 v）；否则 R1b-wire 既有分派
  → onUpdate(delta) 每帧（R1b-wire floor/full，不变）→ settle maxOffset（精确）

arbiter.onPan(.cancelled)
  → engine.cancelPan(panel)
       dragRaw[panel] = nil                       // ★ 清；reduce(.panEnded(0))（R1b-wire 不变，不启动画）
       · 若 cancel 时 offset>maxOffset（两指接管/drawing 截获于 overscroll）→ 见 §四 E4
```

**渲染**：drag 改 engine offset → `ChartContainerView.updateUIView` 重建 renderState → `makeViewport` 见 `offset>maxOffset` → B4 渲最老边 overscroll 间隙（**既有路径，零改**）。手势本身每帧驱动 render，无需动画。

---

## 四、错误处理 / 边界

- **E1 `dragRaw` 初始化不变量**：`beginPan` 必先 `interruptDeceleration`（R1b-wire D10：停 + 把任何中途 overscroll 归一到 maxOffset），故 `dragRaw` 基线 `= offset` 恒 ∈[0,maxOffset]，不会以 damped 值为 raw 基线产生不连续。`applyPanOffset` 若 `dragRaw[panel]==nil`（防御：未经 beginPan 直接 changed，生产不发生）→ 惰性 `dragRaw = 当前 offset` 再累加。
- **E2 反拖无死区**：`dragRaw = max(0, …)` 下钳 0 → 手指在最新边方向硬推（raw 本应 <0）不累计负值，反向立即响应（无「先填回负 raw」死区）。最老边方向 raw 无上钳（橡皮筋可一直拉，阻尼渐近 d）。
- **E3 连续性 / 斜率**：映射在 `dragRaw==maxOffset` 处连续（`RubberBand.damp(0,·)==0`）；斜率自 1（界内）降为 `c=0.55`（界外起点，`damp'(0)=c`）—— iOS 标准「过边即觉阻力」手感，非 bug。
- **E4 cancel 于 overscroll（两指接管 / drawing 截获）**：`cancelPan` 清 `dragRaw` 但 R1b-wire 既有语义不启动画（offset 冻结当前值）。若此刻 `offset>maxOffset`：①两指接管 → 后续 pinch `.began` 经 `applyPinch` 的 `interruptDeceleration` 归一（R1b-wire M3，但 `isDecelerating==false` 时不归一——见下补强）；②drawing 截获 → `activateDrawingTool` 顶的 `interruptDeceleration` 同。**补强（R1b-drag）**：`interruptDeceleration` 现仅在 `isDecelerating` 时归一；cancel-于-overscroll 后无 animator 在跑 → 不归一 → 残留越界间隙。**处置**：`cancelPan` 在清 `dragRaw` 后，若 `offset>maxOffset(按当前 renderBounds)` 则经 reducer 归一到 maxOffset（与 `interruptDeceleration` 同源 `reduce(.offsetApplied(deltaPixels:))`）。见 §五 实现。
- **E5 resize 中途 active drag**（旋转/分屏，手指仍按住拖过边）：R1b-wire `recordRenderBounds` 已在 bounds 变时按新几何归一 offset 到 [new min,new max]（不 gate on isDecelerating）。R1b-drag 补：若归一发生且 drag 活跃（`dragRaw[panel]!=nil`）→ `dragRaw = 归一后 offset`（重同步 raw，防下一帧 delta 基于 stale raw 跳变）。MVP：归一（cut short），不追求 resize 中途无缝续拉。
- **E6 `maxOffset==0`（无滚动空间，满屏）**：`canOverscroll==false` → `offset=min(dragRaw,0)=0` 恒硬钳，drag 不给（与 R1b-wire「满屏甩动不弹」一致）。`endPan` 时 `offset==0` 不 `>maxOffset` → 走既有 plain decel（v 小 no-op），无 strand。
- **E7 两面板独立**：`dragRaw` per-panel（upper/lower 各一），与 `activeBounds`/`animators` 同构，互不串扰。

---

## 五、engine 实现（落地点）

### 新增存储
```swift
@ObservationIgnored private var dragRaw: (upper: CGFloat?, lower: CGFloat?) = (nil, nil)   // M1 同 activeBounds 模式：@ObservationIgnored 纯 numeric
// accessor 对称 activeBoundsFor / setActiveBounds：dragRawFor(panel) / setDragRaw(_:panel)
```

### 新纯函数（平台无关，host 全测）—— `RubberBand.damp`
```swift
// 新文件（lean ChartEngine/RubberBand.swift，与 EdgeBounceModel/DecelerationModel 同域 interaction 物理）
enum RubberBand {
    /// iOS UIScrollView 同款橡皮筋阻尼。over≥0（越界距离），dimension>0（主图宽）。
    /// f(x)=(1 − 1/(x·c/d + 1))·d，c=0.55。性质：f(0)=0、单调增、f(x)<x(x>0)、渐近上界 d、f'(0)=c。
    static func damp(over: CGFloat, dimension: CGFloat) -> CGFloat {
        guard over > 0, dimension > 0 else { return max(0, over) == 0 ? 0 : min(over, max(0, dimension)) }  // 退化：over≤0→0；dimension≤0→不阻尼但 floor 0
        let c: CGFloat = 0.55
        return (1 - 1 / (over * c / dimension + 1)) * dimension
    }
}
```
> 退化分支（`dimension<=0`，非有限几何）：返 `over`（不阻尼），上层 D2 仍 floor 在 [0,…]；正常路径 `dimension=mainW>0`。**plan 阶段定 final 退化语义 + 测**。

### `applyPanOffset(deltaPixels:renderBounds:panel:)`（改 D2）
替换 `:665-670` 体（硬钳 → dragRaw + RubberBand 映射，§二 D2 伪码）。**旧 internal `applyPanOffset(deltaPixels:panel:)` 不动**。

### `beginPan` / `endPan` / `cancelPan`
- `beginPan`（`:652-655`）：`interruptDeceleration` 后加 `setDragRaw(panelState(panel).offset, panel)`。
- `endPan`（带 bounds，`:683-694`）：体首 `setDragRaw(nil, panel)`；分派加 D3 的 `offset>maxOffset` 弹回分支。
- `cancelPan`（`:699-701`）：`setDragRaw(nil, panel)`；E4 归一（若 `offset>maxOffset(当前 renderBounds)`——但 `cancelPan` 当前**无 renderBounds 参数**：需评估是否加 bounds 重载，或复用 `lastRenderedBounds`。**plan 阶段定**：倾向复用 engine 已存的 last render bounds（`recordRenderBounds` 存的）算 ob 归一，避免改 `cancelPan` public 签名）。

### `recordRenderBounds`（E5 补，承袭 R1b-wire resize 归一）
bounds 变归一 offset 后，若 `dragRawFor(panel)!=nil` → `setDragRaw(归一后 offset, panel)`。

---

## 六、测试（host 平台无关优先；行为对拍，非公式自等）

1. **RubberBand 纯函数性质**：`damp(0,d)==0`；单调增（over↑→damp↑）；`damp(x,d)<x`(x>0)；渐近 `damp(大 x,d)→≈d`（断言 `< d` 且随 x 增逼近）；`damp(over,d)` 对固定 over 随 d 增而增。**退化**：`damp(负,d)==0`；`damp(over,0)` 走退化分支（断言定义值）。
2. **drag 过最老边阻尼（D2 killer）**：构造 `maxOffset>0` 状态，`applyPanOffset` 累计 raw 推过 maxOffset → `offset == maxOffset + damp(raw−maxOffset, mainW)` 且 **`maxOffset < offset < raw`**（证阻尼：既过界又被压缩，非 vacuous）。
3. **反拖正确解绕**：过界后再注入负 delta（往回拉）→ offset **连续单调降**回 maxOffset，越过后进入 [0,maxOffset] **1:1**（断言界内段斜率 1 = 回归）。证 raw 累加器解绕正确。
4. **界内 1:1 回归**：`[0,maxOffset]` 内 drag → 与 R1b-wire 硬钳逐字等价（offset==clamp(raw,0,maxOffset)）。
5. **最新边硬钳无给（单边 killer）**：offset 在 0 处继续往最新边推（负 delta）→ offset 恒 0、`dragRaw` 不累负、反向立即响应（E2）；offset 永不 <0。
6. **无滚动空间硬钳（E6）**：`maxOffset==0`（count≤visibleCount）→ 任意 drag → offset 恒 0、不给。
7. **endPan 从 overscroll 弹回（D3 killer）**：drag 到 `offset>maxOffset` 后 `endPan(velocity: 0)`（慢松手）→ **启动弹簧**（非 no-op strand）→ settle 精确 maxOffset；`endPan(velocity: 负值)`（内向甩）于 overscroll → 同样弹回 maxOffset 不过冲。**对照**：界内 `offset<maxOffset` + `v=0` endPan → 不弹（既有 R1b-wire 行为，回归）。
8. **dragRaw 生命周期**：`beginPan` 后 `dragRawFor!=nil` 且 == offset；`endPan`/`cancelPan` 后 == nil；两面板独立（upper drag 不动 lower dragRaw）。
9. **cancel-于-overscroll 归一（E4）**：drag 到 overscroll → `cancelPan` → offset 归一 maxOffset、dragRaw==nil、无残留越界。
10. **P7 回归**：既有 R1b-wire/R1a 全套（drag full-clamp 旧签名累加、机制 A 分派、onUpdate floor/full、B4 makeViewport、EdgeBounceModel/DecelerationModel、drawing/interaction）**保持绿不改**——R1b-drag 只改 public 新签名 `applyPanOffset` 体 + endPan 分派 + 新增 dragRaw/RubberBand。**注**：R1b-wire 的「drag full-clamp：推过 maxOffset → 钳 maxOffset」测试（`TrainingEngineBounceWiringTests`）**语义变更**（现为阻尼跟手，offset>maxOffset）→ 该条须**更新为 R1b-drag 新期望**（damped），非保持旧硬钳断言；§九 ledger 标注。
11. **device/sim runbook**（user 实测回填）：拖过最老边 → 内容**带阻力跟手**（越拖越沉、渐近一屏）；松手（轻放）→ **弹回贴最老边**；松手带速度（继续外甩）→ 弹簧 overscroll 后回落；拖向最新边 → **无给、停当前 tick**；满屏（无滚动空间）拖动 → 不动；过界拖动中途旋转/分屏 → 归一新几何无残留间隙；过界拖动中两指接管/开画线 → 无残留越界。

---

## 七、关键设计决策

- **D1 engine `dragRaw` 累加器**：橡皮筋须基于累计 raw 位移（damped 增量不可逆）；engine 侧累加（非改手势契约传 cumulative）→ 复用增量 onPan、零接触 C7 arbiter。`@ObservationIgnored` per-panel。
- **D2 单边映射**：`offset = f(max(0, raw))`，界内 1:1、最老边 `maxOffset+RubberBand`、最新边 / 无滚动空间硬钳 0。下钳 0 消反拖死区且守单边不变量（offset≥0）。
- **D3 endPan overscroll 必弹**：drag-overscroll 松手不论速度方向都弹簧回 maxOffset（防慢松手 strand），复用 EdgeBounceModel 零速回弹相，零改物理。
- **D4 iOS 标准橡皮筋公式**（user 2026-06-16 裁决）：`(1−1/(x·c/d+1))·d`，c=0.55，d=主图宽；asymptotic、过边觉阻力。驳回线性分数阻尼。
- **D5 零渲染改动**：B4 已渲 `offset>maxOffset` 最老边 overscroll → drag-overscroll 自动正确显示；`RenderStateBuilder` 一行不改。
- **承袭 R1b-wire**：`offsetBounds`/`bounceEdges` 单边、`activeBounds`/`allowOverscroll` floor、`EdgeBounceModel` 物理、`interruptDeceleration` D10、resize `recordRenderBounds` 归一——**全不改**，仅在其上叠加 dragRaw + 映射 + endPan 分派。

---

## 八、验收 / 治理

- **评审通道**：改 `ios/**/*.swift`（trust-boundary）→ **`codex:adversarial-review`**（配额耗尽 fallback opus 4.8 xhigh）+ Mac Catalyst build-for-testing + app-build。本 spec + plan 阶段评审用 **opus 4.8 xhigh 对抗性 review 到收敛**（user 指定）。
- **非-coder acceptance checklist**：host 测核（§六.1-10）+ §六.11 device runbook（user 实测回填）。forbidden phrases 见 `.claude/workflow-rules.json`。
- **ledger（承袭 R1b-wire ledger-B）**：本 PR 不碰 `wave3-completion.md`/`verify-wave3-completion.sh`/runtime-matrix（feature 门 `PENDING-W3-11-R1` 已由 R1b-wire 翻转）。仅记自身 `docs/superpowers/acceptance/2026-06-16-w3-11-r1b-drag-*.md`。**点名**：R1b-wire 的 `drag full-clamp` 测试语义因本 PR 变更（硬钳→阻尼），须更新该测试期望（§六.10）。
- **out of scope**：device 实测本身（runbook 交付，user 职责）；不改 `EdgeBounceModel` 物理 / 不改 `onPan` 手势契约 / 不碰 B4 渲染。

---

## Changelog

| 日期 | 版本 | 说明 |
|---|---|---|
| 2026-06-16 | v1 | 锁机制：engine `dragRaw` 累加器（D1）+ 单边 raw→offset 映射（D2，最老边 RubberBand 阻尼 / 最新边硬钳）+ `endPan` overscroll 必弹（D3）+ iOS 标准橡皮筋公式（D4，user 裁决）+ 零渲染改动（D5）。承袭 R1b-wire 全机制。边界 E1-E7（dragRaw 不变量 / 反拖无死区 / 连续性 / cancel-于-overscroll / resize 重同步 / 满屏硬钳 / 双面板独立）。 |
| 2026-06-16 | **v1.1（opus 4.8 xhigh 对抗性 review R1 = APPROVE，代 codex）** | reviewer 实编验证全部关键论断：橡皮筋公式性质（f(0)=0/单调/f(x)<x/渐近 d/f'(0)=0.55/巨值无 NaN）、dragRaw 反拖解绕（数值序列单调回 maxOffset 再 1:1、最新边 pin 0 无死区/无 offset<0）、D3 strand 真实（stopThreshold=0.5 慢松手 no-op）+ 弹回路径可达（EdgeBounceModel 零速/负速 overscrolled 起步 settle 精确 maxOffset 无过冲）、单边不变量、零渲染改、无滚动空间逻辑链、唯一 `dragFullClamp` 测试语义变。**0 Critical / 0 High**。2 Low **折入 plan**（非设计缺陷）：**L1** `endPan` overscroll 弹回分支须留在 `reduce(.panEnded)==.startDeceleration(v)` guard 内（post-drag 面板恒 `.freeScrolling` 不变量显式化，不外提/不放松）；**L2** §六.9 E4 `cancelPan` 归一测试须先 `recordRenderBounds` seed（`lastRenderedBounds != .zero` 前提，防归一 against [0,0] 致 vacuous）。**设计收敛。** |

# W3-11-R1b-wire 边缘 bounce 实时接线（单边化）—— 设计文档 v2

**日期**：2026-06-16
**性质**：Wave 3 fast-follow，关闭功能门 `feature-completeness: PENDING-W3-11-R1`。把已就绪的 bounce 物理（顺位 11 `EdgeBounceModel` / `DecelerationModel` / `DecelerationAnimator`）+ R1a 已落地的几何 helper（`geometryCore` / `offsetBounds` / `OffsetBounds.bounceEdges`，PR #114 `64ad07e`）接进真 app 的手势/渲染管线，使**甩动到最老边 → 弹簧 overscroll+回弹可见**。改 `ios/**/*.swift`（trust-boundary）→ 经 **`codex:adversarial-review`**。

**父设计（继承，不复述）**：`docs/superpowers/specs/2026-06-15-w3-11-r1-bounce-wiring-design.md`（v2.1 opus APPROVE）。本文档 = 其 §八 packaging 列的 **R1b-wire** 子项的实施级 spec，继承父 §二（B2–B5 架构骨架）、§四（错误/边界）、§五（D1–D7 决策）、§七（file refs）；**本文档负责父 §六 B4 NOTE 点名的 reveal 驱动「单边化重导」+ 锁实施机制（机制 A）+ 重导 §三 数据流 / §B4 渲染为单边 + 三 clamp 层 + strand 处置。**

**前置（已满足）**：R1a = **PR #114 `64ad07e`**；reveal RFC = #113 `bb0d597` + 聚合感知 reveal #115 `7b1849a`。本分支 `wave3-w3-11-r1b-wire` off `origin/main`（`7b1849a`）。

---

## 一、问题：对称弹簧 × reveal 禁前窥 = 单边化矛盾

`EdgeBounceModel`（顺位 11 **冻结**，本 PR **不改物理**）是**对称**弹簧（init L57-63）：`offset>maxOffset` → 弹 max；`offset<minOffset` → 弹 min；界内 → 按速度减速到 edge（`(v≥0)?max:min`）跨边 seed 弹簧。**任一端点都会 spring。**

reveal RFC（#113）后 `offsetBounds` 产 **`minOffset=0`（最新边=当前 tick，硬钳）/ `maxOffset=max(0,baseStartIndex)·step`（最老边）**。reveal 禁前窥 = 最新边前向不可越（offset<0 = 渲未来 K 线）。

**矛盾**：直接接对称模型 → 负速 fling（v<0）减速跨 0 → spring offset<0 = 前向揭示。R1a 已 render 层兜底（offset<0→startIndex 钳 upperBound+pixelShift=0），但 **codex R3 要求 R1b 显式单边、不依赖「invisible spring+render 兜底」**，并把非对称类型级编码进 `OffsetBounds.bounceEdges`（永不含 `.min`）。

**本 spec 核心任务**：选**零改 `EdgeBounceModel` 物理**的接线机制，使最老边弹簧 overscroll 可见、最新边硬钳无弹、且 engine offset 在任何中断后都不 strand 越界。

---

## 二、机制 A（本 PR 锁定决策 · D8）：endPan 按速度方向分派 + 三 clamp 层

### B2 dispatch（速度方向 + bounceEdges）
| fling | 条件 | 启动 | 物理 | onUpdate clamp（见下） |
|---|---|---|---|---|
| **朝最老边** | `v>0` **且** `.max∈bounceEdges` | `start(initialVelocity:v, fromOffset:offset, minOffset:min, maxOffset:max)`（对称 bounce） | 减速→maxOffset→跨边→临界阻尼弹簧 overscroll→settle | **floor `[min,+∞)`**（放 overscroll） |
| **朝最新边 / 无滚动空间** | `v≤0`，**或** `bounceEdges==[]` | `start(initialVelocity:v)`（plain 无界 decel） | 单调减速、无弹簧 | **full `[min,max]`**（硬停两边） |

- **v>0 bounce 天然单边**：`EdgeBounceModel` 减速 edge=`(v≥0)?max:min`=max，**只朝最老边、永不接近最新边** → 只可能在 max 弹。最新边在此路径不可达，无需改物理（已 opus R1 核实正确）。
- **v≤0 plain decel 单调无过冲**：`DecelerationModel` 速度乘 friction 衰减、**不反向** → offset 单调降，full-clamp 钳停 min(=0)，**无 spring-back**（已 opus R1 核实正确）。
- **v==0**：落 else，`start(initialVelocity:0)` 因 `abs(0)<stopThreshold` guard **no-op**（零速松手不弹，符父 D6，opus R1 核实）。

### B3/D9 三 clamp 层（offset 状态机关键不变量）
| 入口 | 当前 | R1b-wire 后 | clamp |
|---|---|---|---|
| `applyPanOffset`（drag `.changed`，**新签名**） | 直转 `applyOffsetDelta` 无界 | **full `[min,max]`**（drag 不跟手过边，MVP） | 双边 |
| `onUpdate`（decel/bounce 每帧） | `applyOffsetDelta` 无界 | **按 run 类型分**：bounce → **floor `[min,+∞)`**（放最老边 overscroll）；plain decel → **full `[min,max]`**（硬停两边） | 见上 |
| `applyOffsetDelta`（reducer `.offsetApplied`） | `offset += d` 无界累加 | **逐字不变**（clamp 在方法层，非 reducer，承袭父 D2） | 无 |

**C1 修正（opus R1）**：onUpdate **不是**一律 floor。floor 只放**最老边 overscroll**（bounce 路径）；plain decel 路径（含 **v>0 但无滚动空间** `bounceEdges==[]`）必须 **full-clamp**——否则 plain decel 的正速 delta 透传使 offset 涨成正值 strand（无滚动空间时尤甚）。故 onUpdate 的 clamp 类型由 run 携带的 **`allowOverscroll`** 决定（bounce=true→floor；decel=false→full）。

### 为何不选机制 B（给 `EdgeBounceModel` 加 per-edge 硬钳 flag）
驳回：①动顺位 11 冻结物理 + 全单测套件（回归面大）；②父 B4 NOTE 已把单边「归 R1b 接线层」；③机制 A 零新物理、纯复用既有两启动面 + clamp。

---

## 三、数据流（重导为单边，supersede 父 §三）

```
arbiter.onPan(.changed, deltaX)
  → Coordinator 算 bounds=offsetBounds(engine, panel, view.bounds)
  → engine.applyPanOffset(deltaPixels:deltaX, offsetBounds:bounds, panel)            [新签名]
       full-clamp：clampedDelta = clamp(offset+deltaX, min, max) − offset；reduce(.offsetApplied(clampedDelta))
       · drag offset 恒 ∈[min,max]（不跟手过边）

arbiter.onPan(.ended, velocityX)
  → Coordinator 算 bounds → engine.endPan(velocity:velocityX, offsetBounds:bounds, panel)   [新签名]
  → reduce(.panEnded) → 若 .startDeceleration(v)：
       v>0 ∧ .max∈bounceEdges → activeBounds[panel]=(bounds, allowOverscroll:true);  start(v, fromOffset:offset, min, max)   // bounce
       否则                    → activeBounds[panel]=(bounds, allowOverscroll:false); start(initialVelocity:v)                // plain decel
  → onUpdate(delta) 每帧（按 activeBounds[panel].allowOverscroll 决定 floor/full）：
       bounce：offset 升过 maxOffset（floor 不触发）→ B4 渲 overscroll → 弹回 settle maxOffset
       decel ：offset 单调降被 full-clamp 钳停 0（无弹簧/无过冲）；无滚动空间 v>0 也被 full-clamp 钳 0（C1）
  → makeViewport：offset>maxOffset → B4 左露 overscroll 间隙（仅弹簧期、仅最老边）；offset∈[0,maxOffset] → 现状
  → onFinish（自然 settle）→ offset == 落点 edge 精确（bounce:maxOffset / decel:0）
```

**单边不变量**：overscroll（offset>maxOffset）只可能由 **v>0 bounce** 产生于**最老边**；最新边（offset<0）**永不可达**（drag full-clamp 拦过边 + decel full-clamp 钳 0 + 无 v<0 bounce 路径）。∴ B4 单边渲染。

---

## 四、B4 makeViewport 单边 overscroll（重导，supersede 父 §B4 双边）

**唯一改动**：`RenderStateBuilder.makeViewport`（`:179-180`）pixelShift 边缘分支。

当前：
```swift
var pixelShift = panelState.offset - CGFloat(wholeShift) * candleStep
if startIndex == 0 || startIndex == upperBound { pixelShift = 0 }
```
R1b-wire 后（**最新边硬钉先判；最老边 overscroll 放开**）：
```swift
var pixelShift = panelState.offset - CGFloat(wholeShift) * candleStep
if startIndex == upperBound {
    pixelShift = 0                                   // 最新边硬钉（含早 tick upperBound==0；offset<minOffset 前向不可达）
} else if startIndex == 0 {
    // 最老边 overscroll：offset>maxOffset → 左露间隙（pixelShift>0=candles 右移，符 Geometry.swift L136）；否则钉边
    // M2：复用 core 已派生的 baseStartIndex/candleStep（== 本函数局部 baseStartIndex/candleStep），勿重算 geometryCore、勿用 upperBound
    let maxOffset = roundTripEdge(integer: baseStartIndex, step: candleStep)   // 与 offsetBounds.maxOffset 同源（D4）
    pixelShift = panelState.offset > maxOffset ? panelState.offset - maxOffset : 0
}
```
- **顺序关键**：`upperBound` 先判——早 tick `upperBound==0` 时 `startIndex==0==upperBound` 落硬钉。`startIndex==0 && !=upperBound` ⇒ `upperBound=max(0,base)>0` ⇒ `baseStartIndex==upperBound>0` ⇒ `roundTripEdge(正数)` 安全（opus R1 核实）。
- **overscroll 量可 > candleStep**（深甩）→ 用 `offset−maxOffset`（完整），非 sub-candle 余量。
- **D4 同源**：此分支 `baseStartIndex==upperBound`，故 `roundTripEdge(baseStartIndex)` == `offsetBounds.maxOffset=roundTripEdge(core.baseStartIndex)` 逐位同值，无漂移。
- **startIndex/visibleCount/slice 零改** → 防 OOB；partial-aggregate（`make` L33 `lastVisibleIdx==currentIdx`，最老边 overscroll 时 `lastVisibleIdx=visibleCount−1≠currentIdx` **不触发**）保真（opus R1 核实）。
- **不加 `offset<minOffset` 分支**（reveal 下不可达，删父双边下界叙述）。不二次阻尼（父 D3）。

---

## 五、engine / Coordinator 接线（落 D1 = Coordinator 算 numeric、engine 收数值）

### 签名（**additive overload**：新带 bounds / 旧无 bounds 保留，H1/H2 修正）
```swift
// 新（Coordinator 用）：
public func applyPanOffset(deltaPixels: CGFloat, offsetBounds: RenderStateBuilder.OffsetBounds, panel: PanelId)  // full-clamp
public func endPan(velocity: CGFloat, offsetBounds: RenderStateBuilder.OffsetBounds, panel: PanelId)              // 存 activeBounds + 分派
// 旧（既有测试/兼容；H1 修：旧 endPan 显式清 activeBounds，杜绝 stale 喂 onUpdate）：
public func applyPanOffset(deltaPixels: CGFloat, panel: PanelId)   // 无界（byte-preserved）
public func endPan(velocity: CGFloat, panel: PanelId)             // 无界 plain decel；体首 activeBounds[panel]=nil
```
**H1 修**：旧 `endPan(velocity:panel:)` 体首 `activeBounds[panel]=nil` → 其 `start(initialVelocity:)` 的 onUpdate 见 nil → 退化无界（不被前一次新-endPan 的 stale bounds 误钳）。旧 `applyPanOffset(deltaPixels:panel:)` byte 不变（drag 同步、不涉 activeBounds）。
**H2 修（P7 叙述）**：旧签名**逐字保留** → 既有调旧签名的测试（如 `applyPanOffset` 累加断言、drawing/interaction 测）**行为零变、保持绿、不改**。P7 回归 = onUpdate 的 floor/full-clamp 改动 + **新**签名的 clamp 测试，**非**重写旧签名测试。

### engine 新增存储 + onUpdate
```swift
struct ActiveDecel: Equatable, Sendable { let bounds: RenderStateBuilder.OffsetBounds; let allowOverscroll: Bool }
@ObservationIgnored private var activeBounds: (upper: ActiveDecel?, lower: ActiveDecel?) = (nil, nil)   // M1：@ObservationIgnored（同 lastRenderedBounds 模式），纯 numeric 无像素（D1）
```
onUpdate（init L141-142 改经 clamp helper）：
```
func floorOrFullClampedOffsetDelta(_ delta, panel):
    guard let a = activeBounds[panel] else { applyOffsetDelta(delta, panel); return }   // 无 → 无界（旧路径兼容）
    let cur = panelState(panel).offset
    let target = a.allowOverscroll ? max(a.bounds.minOffset, cur+delta)                 // bounce：仅 floor
                                    : min(max(cur+delta, a.bounds.minOffset), a.bounds.maxOffset)  // decel：full
    if target != cur { applyOffsetDelta(target - cur, panel) }   // L2-new：target==cur（decel 钳 0 后）不派 0 delta，省空 revision bump
```

### B2 dispatch 体（新 endPan）
```
若 reduce(.panEnded(velocity)) == .startDeceleration(v):
    if v > 0 && offsetBounds.bounceEdges.contains(.max):
        activeBounds[panel] = ActiveDecel(bounds: offsetBounds, allowOverscroll: true)
        animator.start(initialVelocity: v, fromOffset: panelState(panel).offset,
                       minOffset: offsetBounds.minOffset, maxOffset: offsetBounds.maxOffset)
    else:
        activeBounds[panel] = ActiveDecel(bounds: offsetBounds, allowOverscroll: false)
        animator.start(initialVelocity: v)
```
`fromOffset` = engine 当前 offset（drag full-clamp 保证 endPan 时 offset∈[0,maxOffset]，不触 bounce init springing 相）。`cancelPan` 不变（不启动画、不碰 activeBounds；**且 pan 期间无 bounce 在跑**——`beginPan` 已停前一次，M6）。

### B5 中断归一（H3/M3：`interruptDeceleration` 用 `isDecelerating` guard 防 stale-clamp）
新 helper 替换 `beginPan`/`activateDrawingTool`/`applyPinch(.began)` 处的裸 `animator.stop()`：
```
func interruptDeceleration(panel):
    let a = animator(for: panel)
    let wasRunning = a.isDecelerating          // 仅在中断 **活跃** run 时归一（非 resize 路径下 activeBounds 即当前几何，L1-new；resize 见 §七）
    a.stop()
    if wasRunning, let act = activeBounds[panel] {
        let cur = panelState(panel).offset
        let clamped = min(max(cur, act.bounds.minOffset), act.bounds.maxOffset)
        if clamped != cur { _ = reduce(.offsetApplied(deltaPixels: clamped - cur), on: panel) }   // overscroll(>max) 归 maxOffset（M1：deltaPixels 标签必带）
    }
```
- **H3**：re-grab 中途 overscroll → `beginPan` 经此把 offset 归 maxOffset（`EdgeBounceModel` 外部 stop 不自归一，故 engine 显式归）；随后 drag full-clamp / tap-release plain-decel no-op 都落界内。
- **M3**：`activateDrawingTool` 中 `interruptDeceleration` → snapshot 前 offset 已归界内，drawing 期无静态 overscroll 间隙。`applyPinch(.began)` 同。
  - **M2-new 顺序不变量（plan R2-C1 修：`interruptDeceleration` 须在 `reduce(.activateDrawing)` 捕获 `baseRev` **之前**）**：`interruptDeceleration` 的 `reduce(.offsetApplied)` 归一会 **bump revision**（freeScrolling 下 `offset+=d` 必 `revision&+=1`）。现 `activateDrawingTool` 序是 ① `reduce(.activateDrawing)` 捕获 `baseRev=revision` → ② `stop()` → ③ 算 range → ④ `setDrawingSnapshot(baseRevision: baseRev)`（Reducer 守 `baseRev==revision` 才进 drawing）。若把 interrupt 放在 ①②之间（原地替换 ② 的 `stop()`），其 revision bump 会令 ① 捕获的 `baseRev` 失配 ④ 的 staleness 闸门 → **永不进 drawing**（plan R2-C1 实证）。**修法 = 把 `interruptDeceleration` 提到 `activateDrawingTool` 最顶（在 ① `reduce(.activateDrawing)` 之前）**：interrupt 先归一+bump，① 再捕获**归一后**的 `baseRev`，④ 闸门匹配，snapshot 取归一 offset（=maxOffset）。原 ② 的裸 `stop()` 删除（interrupt 已含 stop）。**对既有 H1 测试无害**：旧 endPan 路径 `activeBounds==nil` → interrupt 只 `stop()` 不归一不 bump，`baseRev` 不变（实证 `rangeUsesFrozenOffsetAndDriverDeactivated` 仍绿）。「已在 drawing」早退场景下提前 interrupt = no-op（drawing 期无 animator 在跑）。
- **stale 自纠正（opus R1 隐患）**：`isDecelerating` guard 确保只在打断**活跃**动画时 clamp——动画早已 settle/cancel（activeBounds 残留旧几何）时 `isDecelerating==false` → 不 clamp → 不会用 stale bounds 误钳一个当前几何下合法的 offset。
- **周期切换/交易**（`switchPeriodCombo`/`advanceAndAccount`）：既有 `stopAllDeceleration()` + `resetOffsetAfterAutoTracking`（offset→0）已清 overscroll，**不改**。
- **scene-active**：既有 `resetOnSceneActive`——bounce 路径 `normalizeToEdgeDelta` 归 maxOffset；decel 路径 offset 已被 full-clamp 在界内。**不改**。
- **resize 中途 bounce（codex branch-diff R1 修，承袭父 §B5「几何变更 → stop+归一 edge」）**：bounce overscroll 进行中 `view.bounds` 变（旋转/分屏）→ 冻结的 `activeBounds.maxOffset`（旧几何）使 bounce settle 到旧 maxOffset；新几何下 makeViewport 视其为 `offset>maxOffset` → 渲**持久 overscroll 间隙**直到下次手势。**处置（本 PR 修）**：`recordRenderBounds`（updateUIView 每次调）检测 `bounds` 变 **且** `isDecelerating` → `stop()` + 按**新** bounds 算 `offsetBounds` 归一 offset 到 `[new min, new max]` + 清 activeBounds。`bounds` 未变（常态每帧）→ no-op，不扰正常 bounce。pinch 路径已由 `applyPinch(.began)` 的 `interruptDeceleration` 覆盖（pinch 是手势）；resize 是非手势几何变更，故须在 `recordRenderBounds` 接。测 `resizeMidBounceNormalizes`（缩 bounds 后 offset∈[new min,new max] 不 strand）。MVP：stop+归一（cut short 续弹），不追求无缝续弹（R1b/后续）。

### Coordinator 喂 bounds（`ChartContainerView.Coordinator.attach` 的 `onPan`）
```
.changed: let b = RenderStateBuilder.offsetBounds(engine:self.engine!, panel:self.panel, bounds:view.bounds)
          engine.applyPanOffset(deltaPixels:deltaX, offsetBounds:b, panel)
.ended:   let b = ...同上; engine.endPan(velocity:velocityX, offsetBounds:b, panel)
.began/.cancelled: 不变
```
新增 `RenderStateBuilder.offsetBounds(engine:panel:bounds:)` 便捷重载（复用 `make` 的 extraction）：
```swift
@MainActor static func offsetBounds(engine: TrainingEngine, panel: PanelId, bounds: CGRect) -> OffsetBounds {
    let ps = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
    let candles = engine.allCandles[ps.period] ?? []
    let mainW = ChartPanelFrames.split(in: bounds).mainChart.width
    let currentIdx = candles.isEmpty ? 0 : currentCandleIndex(candles: candles, tick: engine.tick.globalTickIndex)
    return offsetBounds(mainFrameWidth: mainW, rawVisible: ps.visibleCount,    // M4：传 **raw** visibleCount（与 makeViewport L164 一致；fallback 在 geometryCore 内）
                        candleCount: candles.count, currentIdx: currentIdx)
}
```
（Coordinator 持 `view.bounds`、算 numeric 喂 engine；engine 不反向依赖 `ChartPanelFrames`/像素，D1。）

---

## 六、测试（host 平台无关优先；行为对拍，非公式自等）

1. **B4 单边 overscroll**：freeScrolling offset>maxOffset → `startIndex==0`、`pixelShift==offset−maxOffset`(>0)、slice 非空且下标合法；offset==maxOffset → pixelShift==0；offset∈(0,maxOffset) → 与现状逐字一致（回归）。**L2 分立**：(a) 早 tick `upperBound==0`+任意 offset → pixelShift==0；(b) 中 tick `upperBound>0` 的最新边（offset 小/负，startIndex==upperBound）→ pixelShift==0——避免「两者恰为 0」的 vacuous pass。
2. **B4 不可达下界（L1：regression 非 novel）**：offset<0（人造）→ startIndex==upperBound、pixelShift==0（证 B4 改写保留最新边硬钉；与 R1a `offsetBounds_minOffsetIsHardClampNotSpring` 同族，标注为回归断言）。
3. **B3 drag full-clamp（新签名）**：`applyPanOffset(…offsetBounds:)` 推过 maxOffset → 钳 maxOffset；推过 0（负 delta）→ 钳 0；界内 → 正常累加。**旧签名** `applyPanOffset(…panel:)` 仍无界累加（H2：既有测试不变）。
4. **机制 A 分派（killer；L3 缝=注入 `decelerationDriverFactory` fake `FrameDriving` + 观察 `start` 选 bounce vs plain 的行为，非「探针 animator」——animator 非 protocol 不可换）**：
   - `v>0` 且有滚动空间 → bounce（**M5**：并断言 offset 实际**朝 maxOffset 移动**——非仅 routing；防符号反转幸存）；
   - `v<0` → plain decel（断言 offset **朝 0 移动**）、**C1**：onUpdate full-clamp 不越界；
   - `bounceEdges==[]`（无滚动空间）即便 `v>0` → plain decel + **full-clamp 钳 0**（C1 killer：offset 不 strand 成正值）。
5. **onUpdate clamp 类型（C1 killer）**：bounce run 注入正 delta 使 offset>maxOffset → **透传不钳**（overscroll 可见，证 floor）；decel run 注入正/负 delta → **full-clamp**（offset 恒∈[0,max]）。
6. **v>0 bounce overscroll 端到端**：注入弹簧轨迹 → offset 越 maxOffset → settle 精确 maxOffset；floor 全程不触发 0。
7. **v≤0 decel 单调硬停**：plain decel + full-clamp → offset 单调降、停 0、无正向反弹。
8. **B5 中断归一（H3/M3）**：bounce overscroll 中途 → `beginPan` 后 offset==maxOffset（不 strand）；`activateDrawingTool` 中途 overscroll → **snapshot 前 offset==maxOffset 且 candleRange 基于归一后 offset**（M2-new 顺序不变量；drawing 期无 overscroll 间隙）；scene-active 中途 bounce → normalize maxOffset；**stale 自纠正**：动画已 settle 后再 `beginPan`（`isDecelerating==false`）→ 不误钳一个当前合法 offset。
9. **P7 回归（H2 重述）**：既有调**旧签名**的 freeScrolling 累加/drawing/interaction 测**保持绿不改**；新增覆盖 = 新签名 clamp（§六.3）+ onUpdate floor/full（§六.5）；既有 `DecelerationAnimator`/`DecelerationModel`/界内 makeViewport/partial-aggregate 测全绿。
10. **device/sim runbook**（W3-11-R1 device 验收，user 实测回填）：**甩**到最老边松手 → 弹簧 overscroll+回弹+落边；**轻拖**到最老边零速松手 → 停边不弹（父 D6）；**甩/拖向最新边** → 平滑减速回 autoTracking、停当前 tick、**无前向间隙/无回弹**；满屏（无滚动空间）甩动 → 不动不弹；切周期/缩放后最老边 bounce 仍正确；bounce 中途切后台→前台 / 开画线 → 无残留越界；**bounce 中途旋转/分屏（codex R1 修）→ 立即 stop+归一新几何、无持久 overscroll 间隙**。

---

## 七、错误处理 / 边界（承袭父 §四）

- `count≤visibleCount` / 非有限几何 → `offsetBounds` 退化 `[0,0]`、`bounceEdges==[]` → 任意 fling 走 plain decel + **full-clamp 钳 0**（C1）。
- `activeBounds[panel]==nil`（旧路径 / 首次 endPan 前）→ onUpdate 退化无界（安全、兼容）。
- `interruptDeceleration` 仅在 `isDecelerating` 时归一 → 无 stale 误钳。
- `beginPan` re-grab：先 `interruptDeceleration`（停+归一）再 `.panStarted`。`cancelPan`/两指接管：pan 期无 bounce（`beginPan` 已停），`cancelPan` 不启动画（M6）。
- **resize 中途 bounce（codex branch-diff R1 修）**：`recordRenderBounds` 检测 bounds 变 + `isDecelerating` → stop + 按新几何归一 offset 到 [new min,new max]（防冻结 activeBounds 致持久 overscroll 间隙）。测 `resizeMidBounceNormalizes`；device §六.10 旋转项。

---

## 八、关键设计决策（增量；继承父 D1–D7）

- **D8 单边化 = endPan 速度方向分派（机制 A）**：`v>0 ∧ .max∈bounceEdges` → 对称 bounce（最老边弹）；否则 plain decel。零改 `EdgeBounceModel`。驳回机制 B。
- **D9 三 clamp 层**：drag full（applyPanOffset 新签名）/ decel·bounce 按 `allowOverscroll`（bounce floor 放 overscroll、decel full 硬停，**C1**）/ reducer 无界（D2 承袭，零改）。
- **D10 中断归一靠 `isDecelerating`-guarded `interruptDeceleration`**：仅打断活跃 run 才用其 activeBounds 归一 offset → 防 stale 几何误钳（H3/M3 + opus R1 隐患）。
- **D4 承袭强化**：B4 的 maxOffset 与 offsetBounds.maxOffset 同经 `roundTripEdge(baseStartIndex,step)`、单源（M2 复用 core.baseStartIndex）。
- **D1 承袭**：Coordinator 算 `offsetBounds`(numeric) 喂 engine；engine 存 `activeBounds`(numeric,@ObservationIgnored,M1)。新增 `offsetBounds(engine:panel:bounds:)` 重载承载 extraction（M4 传 raw visibleCount）。
- **附加（H1/H2）**：新签名带 bounds、旧签名保留——旧 endPan 体首清 activeBounds 防 stale；旧签名 byte-preserved 使既有测试不变。

---

## 九、验收 / 治理

- **评审通道**：改 `ios/**/*.swift`（trust-boundary）→ **`codex:adversarial-review`**（配额耗尽 fallback opus 4.8 xhigh）+ Mac Catalyst build-for-testing + app-build。本 spec + plan 阶段评审用 **opus 4.8 xhigh 对抗性 review 到收敛**（user 指定）。
- **非-coder acceptance checklist**：host 测核（§六.1-9）+ §六.10 device runbook（user 实测回填）。
- **ledger-B（承袭父 §九）**：本 PR 不碰 `wave3-completion.md`/`verify-wave3-completion.sh`/runtime-matrix；`feature-completeness: PENDING-W3-11-R1` 翻转 + 矩阵 bounce 行转 device 行留收尾 reconciliation PR。仅记自身 `docs/superpowers/acceptance/2026-06-16-w3-11-r1b-wire-*.md`。
- **out of scope**：R1b-drag（拖拽期跟手橡皮筋）；device 实测本身（runbook 交付，user 职责）。

---

## Changelog

| 日期 | 版本 | 说明 |
|---|---|---|
| 2026-06-16 | v1 | 锁机制 A；重导 §三/§B4 单边；三 clamp 层；engine activeBounds + Coordinator 喂 bounds；B5 strand。 |
| 2026-06-16 | v2（opus xhigh R1 修：1C+3H+6M+3L） | **C1** onUpdate clamp 按 run 类型（bounce floor / decel full），修「v>0 无滚动空间 plain decel strand 正 offset」；**H1** 旧 endPan 清 activeBounds 防 stale；**H2** 旧签名 byte-preserved → 既有测试不变、P7 重述；**H3/M3** `interruptDeceleration`（`isDecelerating`-guard，D10）在 beginPan/activateDrawingTool/pinch.began 归一 overscroll、防 stale 误钳；**M1** activeBounds `@ObservationIgnored`；**M2** B4 复用 core.baseStartIndex；**M4** offsetBounds 重载传 raw visibleCount；**M5** §六.4 加「bounce 朝 maxOffset 移动」断言；**M6** cancelPan/两指 pan 期无 bounce 澄清；**L1/L2/L3** 测试框架修正（offset<0=回归断言 / 早tick vs 最新边分立 / killer 缝=driver factory）。opus R1 已核实正确项：机制 A 单边性、v≤0 单调、v==0 no-op、符号约定、B4 顺序、D4 同源、floor 不触发 bounce、OOB/partial-aggregate 保真、offsetBounds 重载可行。 |
| 2026-06-16 | **v2.1（opus xhigh R2 = APPROVE）** | R2 独立核实 R1 全 1C+3H+6M+3L = RESOLVED + 机制 A/`isDecelerating`-guard/`allowOverscroll` floor-undershoot/同源 maxOffset 逐位相等/两面板独立/Sendable 全核实正确。折入 R2 实施级提示：**M1-new** resize 中途 bounce 残留显式 out-of-scope（承袭父 §B5）+ runbook 验证行；**M2-new** `activateDrawingTool` 的 `interruptDeceleration` 顺序不变量（在算 range 前）+ 测；**L1-new** `interruptDeceleration` 注释软化（非 resize 路径为当前几何）；**L2-new** onUpdate full-clamp `target==cur` 省 0-delta 空 bump。**设计收敛。** |
| 2026-06-16 | **v2.3（codex:adversarial-review branch-diff R1 修）** | codex 揪出真 medium：`endPan` 冻结 `activeBounds` 整个 bounce run，resize/旋转中途 bounce → settle 到旧 maxOffset → 新几何下持久 overscroll 间隙（no-ship）。**根因 = 我实现漏接 resize 非手势几何变更**（只接了 pinch 手势），比父 §B5「几何变更→stop+归一」更弱。**修：`recordRenderBounds` 检测 bounds 变 + isDecelerating → stop + 按新几何归一 offset + 清 activeBounds**（host 不可复现的 device 残留转为 host 可测）。+ 测 `resizeMidBounceNormalizes`；spec §五.B5/§七/§六.10 从「out-of-scope 残留」改「已修」。1061 host 绿。 |
| 2026-06-16 | **v2.2（plan opus xhigh R1→R2→R3 反馈回填）** | plan-stage review 揪出两处需回填 spec 的修正：**M1（标签）** `interruptDeceleration` 的 `reduce(.offsetApplied(deltaPixels: …))` 必带 `deltaPixels:` 标签（原 spec 漏）；**plan R2-C1（M2-new reorder）** `interruptDeceleration` 的归一 `offsetApplied` 会 bump revision，若放在 `reduce(.activateDrawing)` 捕获 `baseRev` **之后**会令 `setDrawingSnapshot` 的 `baseRev==revision` staleness 闸门失配 → 永不进 drawing；**修法 = `interruptDeceleration` 提到 `activateDrawingTool` 最顶（在捕获 baseRev 之前）**，baseRev 捕获归一后 revision（plan R3 实证 `.activateDrawing` 不自 bump、既有 H1/pinch/interaction 全套不破）。plan（R1 3C+4H+4M+4L → R2 1C → R3 APPROVE）+ spec 双收敛。 |

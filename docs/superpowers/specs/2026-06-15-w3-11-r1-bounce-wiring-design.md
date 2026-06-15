# W3-11-R1 边缘 bounce 实时接线（MVP 释放回弹）—— 设计文档 v2

**日期**：2026-06-15
**性质**：Wave 3 fast-follow，关闭 residual **W3-11-R1**（顺位 11 #96 `7eaf00b` 交付组件层 bounce 物理但未接线）。把已就绪的 bounce 物理接进真 app 的手势/渲染管线，使**甩动到边缘后弹簧 overscroll+回弹可见**，闭合 Wave 3 `feature-completeness: PENDING-W3-11-R1` 功能门。**改 `ios/**/*.swift`（trust-boundary）→ 经 `codex:adversarial-review`**。

**前置（已满足）**：顺位 3 Pinch（PR #98 `3187072`，去硬编码 `visibleCount`、动态视口几何）已 merged——这是顺位 11 把 bounce 接线 defer 的阻塞依赖。

**范围裁决（user 2026-06-15）**：**MVP 释放回弹**——**甩动**到边缘松手 → 弹簧 overscroll+回弹可见；手指拖拽期保持当前 clamp（不跟手过边）。**Out of scope**：拖拽期跟手橡皮筋阻尼（follow-up **R1b**）；device 实测本身（runbook 交付，user 职责）。

**v2 修订（opus spec-review R1：3 Critical + 4 High + 4 Med）**：bounds 坐标模型从「绝对 `[0,(count−visibleCount)·step]`」**纠正为锚相对带符号**（C1）；candleStep 几何纠正（C2）；drag-clamp 后零速松手不弹 → runbook 收窄（C3）；overscroll 只动 pixelShift 不动 startIndex（H3）+ 双边符号（H4）；drag-clamp 每帧需 bounds（H2）；strand 义务纳入（M3）；P7 回归面点名（M2）；bounds 测试改行为对拍（M4）；packaging 拆 2 子 PR（L1）。

---

## 一、现状与接线缺口（grep 核实 2026-06-15）

bounce 物理三组件**已就绪 + 全单测**（顺位 11，本 PR 不改）：
- `EdgeBounceModel`（`ChartEngine/EdgeBounceModel.swift`）：注入 `initialVelocity/offset/minOffset/maxOffset` 纯物理；`advance(dt)->FrameOutcome`；`normalizeToEdgeDelta()` 归一；`shouldRun` 守门（**亚阈速度且 offset 界内 → false 不弹**；越界即便零速 → true）。
- `DecelerationModel`：boundary-aware `advance(dt:boundaryDistance:)`，既有 `advance(dt:)` 逐字不变（P7）。
- `DecelerationAnimator.swift:104-116`：**已就绪未调用**的 `start(initialVelocity:fromOffset:minOffset:maxOffset:)`（分离端点 CGFloat 防 NaN-trap）；共享 `onUpdate`/`onFinish`/`stop()`/`resetOnSceneActive()`/generation 生命周期；既有无界 `start(initialVelocity:)` 保留（live 当前调用面）。

**接线缺口（= W3-11-R1）**：
1. `TrainingEngine.endPan(velocity:panel:)`（`TrainingEngine.swift:607-611`）只调 `animator.start(initialVelocity:)`（无边界）→ 永不进 bounce。
2. **几何 offset 边界无来源**（见 §二.B1 真实模型）：边界依赖渲染层像素几何（`mainFrame.width`/`target`/`currentIdx`），engine/reducer 不持有。
3. `RenderStateBuilder.makeViewport`（`:80-85`）边缘**静默 `pixelShift=0`**（无 overscroll 渲染）→ offset 越界也不可见。
4. 顺位 11 设计 §五 指派给 W3-11-R1 的归一/strand 义务（`cancelPan`/`resetOnSceneActive`/`activateDrawingTool`/视口几何变更期间）未接。

---

## 二、架构（接线，additive，不改 bounce 物理）

### B1. 共享 offset-bounds 纯函数（单一真相；落 Render 层，复用 makeViewport 子算）
**核实的真实 offset 坐标模型**（`RenderStateBuilder.swift:58-93` `makeViewport`，offset/几何分解 :60-85，opus C1/C2 纠正）：offset **非绝对位移**，是相对 autoTracking 锚 `baseStartIndex` 的带符号量：
- `mainFrame = ChartPanelFrames.split(in: bounds).mainChart`（**非** bounds 全宽——split 切掉量价/MACD 子面板）；
- `target = panelState.visibleCount>0 ? visibleCount : 80`；`visibleCount = min(target, count)`；
- `candleStep = mainFrame.width / CGFloat(target)`（**分母 target，非 visibleCount**）；
- `currentIdx = currentCandleIndex(candles, tick)`；`baseStartIndex = currentIdx − (visibleCount−1)`；`upperBound = max(0, baseStartIndex)`（**reveal RFC #113 后**：禁前窥，autoTracking 锚即最新可见边，前向不可越当前 tick）；
- `wholeShift = floor(offset / candleStep)`；`startIndex = clamp(baseStartIndex − wholeShift, 0, upperBound)`；正 offset → 最老边（startIndex→0）、负 offset → clamp 回 autoTracking（禁前窥，不渲未来）。

**故真实 offset 边界（带符号，reveal D5）**：
- **maxOffset（最老边，startIndex==0）= `max(0, baseStartIndex) · candleStep`**（≥0；早 tick base<0 → 0）；
- **minOffset（最新边 = 当前 tick）= `0`**（reveal 禁前窥：autoTracking rest offset=0 即最新边，前向不可越 → minOffset 恒 0，**消旧 `(base−upper)·step` 负值 + 死区 + 早 tick 歧义**）。

B1 纯函数签名（Render 层；输入须含 **currentIdx 与 mainFrameWidth**，opus C1：原 `(width,visibleCount,count)` 不足）：
```
offsetBounds(mainFrameWidth: CGFloat, visibleCount rawVisible: Int, candleCount: Int, currentIdx: Int)
  -> (minOffset: CGFloat, maxOffset: CGFloat, candleStep: CGFloat)
```
**共享几何内核（opus R2-M1：坐实 D4 单一真相，杜绝 startIndex 第二处推导）**：抽一个更底层的内核
```
geometryCore(mainFrameWidth: CGFloat, rawVisible: Int, candleCount: Int, currentIdx: Int)
  -> (baseStartIndex: Int, upperBound: Int, candleStep: CGFloat, visibleCount: Int)
```
（按 §二.B1 上式派生 target/visibleCount/candleStep/baseStartIndex/upperBound）。**B1 `offsetBounds` 由 `geometryCore` 派生 bounds**（max=base·step / min=(base−U)·step）；**makeViewport 亦调同一 `geometryCore` 派生 startIndex/pixelShift/slice**（startIndex=clamp(base−floor(offset/step),0,U)，pixelShift/slice 仍 makeViewport 内）。→ bounds 与 render clamp 共用**同一** baseStartIndex/upperBound/candleStep 派生，行为等价不变像素、无两套公式漂移。退化 `count ≤ visibleCount` → upperBound==0、baseStartIndex 可能 ≤0 → min/max 可能相等或 min>max 的退化区间，交 `EdgeBounceModel` 端点校验（`min>max`→安全无 bounce；`min==max`→单点回弹）。

### B2. 几何边界喂进 engine（D1：Coordinator 算 + 喂 numbers，engine 不持像素）
- `ChartContainerView.Coordinator`（Render 层，持 `view.bounds` + 可调 `ChartPanelFrames.split`/`currentCandleIndex` + 读 engine `visibleCount`/`candles.count`/`tick`）用 **B1 算 `(min,max)`**，把 **numeric 边界**喂进 engine（engine 收数值、零像素/几何知识）。
- **pan-end（release）**：`engine.endPan(velocity:offsetBounds:panel:)` → `startDeceleration` 时转发 `animator.start(initialVelocity:v, fromOffset:<engine 当前 offset>, minOffset:min, maxOffset:max)`。
- **drag（changed，H2：每帧需 bounds）**：`engine.applyPanOffset(deltaPixels:offsetBounds:panel:)` → 见 B3 clamp。
- 既有无界 `start(initialVelocity:)` / 不带 bounds 的旧 endPan 路径保留（P7）。

### B3. 拖拽期保持 pin（MVP，drag-clamp 在 applyPanOffset 不在 reducer）
- **clamp 在 `applyPanOffset`（drag 入口 engine 方法）**，**不在 reducer `.offsetApplied`**：`applyPanOffset(deltaPixels, offsetBounds, panel)` 算 `clampedDelta = clamp(offset+delta, min, max) − offset`，再 `reduce(.offsetApplied(clampedDelta))`。→ drag offset 恒 `∈[min,max]`，render 照旧 pin。
- **reducer `.offsetApplied` 逐字不变（无界累加）** → bounce 的 `onUpdate`→`applyOffsetDelta(delta)`→`.offsetApplied` **不经 clamp**，弹簧 overscroll 可突破边界。两路径在 **engine 方法层**区分（`applyPanOffset` clamp / `applyOffsetDelta` 不 clamp），reducer 无法按 action 区分（同为 `.offsetApplied`）。**D2 killer 测**：bounce delta 经 `applyOffsetDelta` 须能使 offset 越界。
- **结论**：overscroll 只可能由「松手后弹簧」产生 → B4 render 无状态判据「offset 越界即显 overscroll」成立。

### B4. render overscroll 橡皮筋（只动 pixelShift，不动 startIndex；双边符号）
> **⚠️ reveal RFC #113 含义（R1b-wire 待重导；本 R1a redux 不改本节机制）**：reveal 后 `minOffset=0`（最新边=当前 tick，禁前窥）→ **最新边无前向 overscroll/bounce**（offset<0 被 makeViewport clamp 回 autoTracking，不渲未来）。故下文「offset < minOffset 最新边越界」分支在 reveal 下**不可达**；bounce/overscroll **仅最老边**（offset>maxOffset）。R1b-wire 实施时据此收窄为单边（最老边）橡皮筋，并重导 §三数据流 + 本节双边叙述。

`makeViewport` 边缘分支改（opus H3/H4，**双边叙述待 R1b-wire 按上方 NOTE 收窄为单边**）：
- **offset > maxOffset（最老边越界）**：`startIndex` 仍 clamp ==0（**不动，防数组越界**），`pixelShift = offset − maxOffset`（**>0 = candles 右移、左露间隙**，符 `Geometry.swift:136` 符号契约）。
- **offset < minOffset（最新边越界）**：`startIndex` 仍 ==upperBound，`pixelShift = offset − minOffset`（**<0 = candles 左移、右露间隙**）。
- **offset ∈ [minOffset, maxOffset]（界内）**：**行为逐字不变**（现有 `startIndex` clamp + 边缘 `pixelShift=0` pin + 非边缘正常 pixelShift）。
- slice 仍 `candles[startIndex..<min(startIndex+visibleCount,count)]`，startIndex∈[0,upperBound] 不变 → **无 OOB**（H3 测须断言越界态 startIndex 仍合法、slice 非空）。
- **不二次阻尼**（D3）：弹簧物理已是阻尼轨迹，render 直接 1:1 平移 overscroll 像素。

### B5. 归一 / strand 接线（顺位 11 §五指派；opus M3：本 PR 即接线 PR，strand 现可显现须处理）
- `resetOnSceneActive()`（组件已有）→ 接 app scene-active 路径（engine `onSceneActivated` 中继）：中途 bounce 越界 offset 静默归 edge（防 strand）。
- `cancelPan`-越界 → 经 bounce 启动面零速归位（组件 `shouldRun` 越界即弹支持）。
- **`activateDrawingTool` / 周期切换 / pinch / 窗口 resize 期间正在 bounce**（顺位 11 §五 item 4/6，opus M3）：这些动作会 `animator.stop()` 或改视口几何使 bounds 失效。处置：任何中断 bounce 的动作（已有 `stop()` 调用面）后，若 offset 越界则下一次几何稳定时经 `resetOnSceneActive`-同源归一路径落 edge；**pinch/resize 改 visibleCount → bounds 变** → 进行中的 bounce 用旧 bounds，settle 后若新几何下越界则 scene/下一手势收口。**MVP 取：bounce 中途遇视口几何变更 → `stop()` + 归一到（旧或新）edge，不追求中途无缝续弹**（无缝续弹属 R1b/后续）。本 PR 须测「bounce 中途 activateDrawingTool/周期切换 → offset 不 strand 在界外」。
- 净效果：bounce 自然 settle / scene-active / cancel / 中断三类后 **engine offset 精确落 edge**，resume/持久化看到干净 clamped offset。

---

## 三、数据流（释放回弹）

```
手势 arbiter.onPan(.changed, deltaX)  → engine.applyPanOffset(deltaX, bounds=B1(...), panel)  [drag-clamp，offset∈[min,max]]
手势 arbiter.onPan(.ended, velocityX) → Coordinator B1 算 (min,max) → engine.endPan(velocityX, (min,max), panel)
  → reduce(.panEnded(velocity)) → 若 .startDeceleration(v)
  → animator.start(initialVelocity:v, fromOffset:engine.offset(==某 edge 或界内), minOffset, maxOffset)
       · 甩动朝界外 → 减速到 edge → cross → 弹簧 overscroll → settle 于 edge（可见回弹）
       · 甩动朝界内 → 纯减速、不 cross、不 overscroll（普通滚动，H1 主路径）
       · 轻拖到 edge 零速松手 → offset==edge 界内亚阈 → shouldRun=false → 不弹（只停 edge，C3）
  → onUpdate(delta) → engine.applyOffsetDelta(delta)（**不 clamp**）→ reduce(.offsetApplied(delta))
  → makeViewport：offset 越界 → B4 渲 overscroll 平移（弹簧期可见）；界内 → 现状
  → onFinish（自然 settle）→ offset==edge 精确
```

---

## 四、错误处理 / 边界

- `count ≤ visibleCount`（无滚动空间）→ B1 退化区间，`EdgeBounceModel` 端点校验守（min>max 无 bounce / min==max 单点）。
- 非有限几何（NaN/inf width/count/currentIdx）→ B1 须返安全值或 bounce-start 端点校验 → `shouldRun=false` 安全无 bounce。
- scene-active / 中断中途 bounce → `resetOnSceneActive`-同源归一（B5）。
- `beginPan` re-grab 中途 bounce → 既有 `animator.stop()` 保位（标准惯性，由后续松手 bounce 收口）。

---

## 五、关键设计决策

- **D1 边界来源 = Coordinator 算（B1）+ 喂 numeric 给 engine**：engine/reducer 不持像素几何（`mainFrame.width`/split 是 Render 层）；Coordinator 持 view + 可调 Render helper → 算 numeric bounds 喂入，engine 收数值。保 engine 不侵入 UIKit 像素层（不让 engine 反向依赖 `ChartPanelFrames`）。
- **D2 drag-clamp 只在 applyPanOffset、不在 reducer**（核心不变量，spec 级钉死）：drag 与 bounce delta 同经 `.offsetApplied`，reducer 不可区分 → clamp 在 `applyPanOffset`（drag 恒界内）、`applyOffsetDelta`（bounce）直传不 clamp（overscroll 突破、settle 由物理落 edge）。reducer 零改动。
- **D3 overscroll 不二次阻尼**：弹簧已含阻尼，B4 render 1:1 平移 overscroll 像素。
- **D4 单一真相 bounds**：B1 纯函数被 makeViewport clamp 与 bounce bounds 共用（makeViewport 重构调 B1）；杜绝两套几何公式漂移（顺位 3 动态 visibleCount 后尤甚）。
- **D5 锚相对带符号坐标（opus C1 核心纠正；reveal RFC #113 后更新）**：bounds = `maxOffset=max(0,baseStartIndex)·candleStep`（≥0，最老边）/ `minOffset=0`（最新边=当前 tick，reveal 禁前窥恒 0，**消旧 `(base−upper)·step` 负值 + 死区 + 早 tick 歧义**）；upperBound 随之收紧为 `max(0,baseStartIndex)`（geometryCore 单一真相，D4）；candleStep=mainFrame.width/target；依赖 currentIdx（tick）+ 像素宽。**tick 仅用户动作（交易/周期切换）推进、非 pan/bounce 中推进** → 单次 bounce 期间 bounds 稳定（pinch/resize 改 visibleCount 才变，B5 处置）。
- **D6 runbook 收窄（opus C3）**：MVP drag-clamp 下「轻拖到边缘零速松手」offset==edge 界内亚阈 → 不弹（iOS 原生一致）；**只有甩动（fling 速度≥阈）越界才回弹**。runbook §六.7 删/改「拖到边缘松手→回弹」为「甩到边缘→回弹 / 轻拖到边松手→停 edge 不弹」。
- **D7 治理边界**：`endPan`/`applyPanOffset` 扩 bounds + makeViewport overscroll + 归一接线 = **顺位 11 设计 §residual/§五 + 顺位 1 RFC 已预先指派给 W3-11-R1 的 wiring 义务**（非新契约）；**但 bounds 公式本身是本 PR 新设计**（opus M1），须经 codex/opus 数值核验。

---

## 六、测试（host，平台无关优先）

1. **B1 bounds 纯函数 + 行为对拍（opus M4，非公式自等）**：给 (mainFrameWidth, visibleCount, count, currentIdx) → 算 (min,max,step)；**把算出的 maxOffset/minOffset 喂回 `makeViewport` → 断言 `startIndex∈{0,upperBound}` 且 `pixelShift==0`**（真到 render 边缘）；maxOffset+ε → startIndex 仍 0 但 pixelShift>0（越界）；退化 count≤visibleCount。
2. **B2 endPan 带 bounds**：注入 fake `FrameDriving` + 探针 animator，断言 `startDeceleration` 时以**正确 fromOffset(engine 当前 offset)/min/max** 调 `start(...bounds)`；界内亚阈速度 → 不启 bounce（D6）。
3. **B3 drag clamp（D2 killer）**：`applyPanOffset` 推过边界 → offset clamp 到 `[min,max]`；**bounce `applyOffsetDelta` delta 不被 clamp → offset 可越界**（killer，证两路径分离）。
4. **B4 makeViewport overscroll（H3/H4）**：offset>maxOffset → pixelShift>0（左间隙）+ **startIndex==0 不变、slice 非空**（无 OOB）；offset<minOffset → pixelShift<0（右间隙）+ startIndex==upperBound；offset 界内 → 与现状逐字一致（回归）。
5. **B5 归一/strand**：scene-active 中途越界 → resetOnSceneActive 后 offset==edge；bounce 中途 `activateDrawingTool`/周期切换 → offset 不 strand 界外（归 edge）；bounce 自然 settle → offset==edge 精确。
6. **H1 主路径**：edge 起点 + 朝界内 velocity → 纯减速、无 overscroll、render 全程界内（不触 B4）。
7. **P7 回归（opus M2 点名）**：drag-clamp 改 `applyPanOffset` 行为 → 既有 freeScrolling **无界**累加断言测试（`TrainingEngineInteractionTests`/`ReducerTests` 中 offset 累加）须更新为「drag 经 bounds 后界内」——区分**真回归** vs **预期行为变更**，逐条标注；既有 `DecelerationAnimator`/`DecelerationModel`/plain-decel endPan/界内 makeViewport 测全绿。
8. **device/sim 运行时 runbook**（W3-11-R1 device 验收，闭合 Wave 3 矩阵 bounce 行；user 实测回填）：**甩**到最老/最新边松手 → 弹簧 overscroll+回弹+落边缘；**轻拖**到边松手（无甩）→ 停边缘**不**回弹（D6）；切周期/缩放后边缘 bounce 仍正确（消费动态 visibleCount/新 bounds）；bounce 中途切后台→前台 / 开画线工具 → 无残留越界。

---

## 七、file refs（grep 核实 2026-06-15）

- `ChartEngine/EdgeBounceModel.swift`（物理，就绪）/ `DecelerationModel.swift`（boundary-aware，就绪）/ `DecelerationAnimator.swift:104-116`（bounce 启动面，就绪未调用）+ `:141-142`(onUpdate setup)
- `TrainingEngine/TrainingEngine.swift:607-611`（endPan 缺口）+ `:596-604`（beginPan/applyPanOffset）+ `:572-574`（**applyOffsetDelta**，opus L2 纠正：原引 :499-501 错）
- `Reducer/Reducer.swift:138-143`（panEnded→startDeceleration）+ `:160-164`（offsetApplied 累加，**逐字不变**——clamp 在 applyPanOffset 非 reducer，D2）
- `Render/RenderStateBuilder.swift:58-93`（makeViewport：split/target/candleStep/baseStartIndex/startIndex/pixelShift——待抽 B1 + B4 overscroll）+ `:95-99`（currentCandleIndex）+ `ChartPanelFrames.split`/`Geometry.swift:136`（pixelShift 符号）
- `Render/ChartContainerView.swift:80-87`（Coordinator onPan 接线，待加每帧 bounds）
- 顺位 11 设计：`docs/superpowers/specs/2026-06-11-pr-wave3-11-edge-bounce-design.md`（§residual L43-47 / §五 stop 调用面归一指派）

---

## 八、Packaging（opus L1：5 单元 + 测 + runbook 超 ≤3 子项 → 拆 2 子 PR）

- **W3-11-R1a（纯几何 helper + 重构，行为中性，host 全测）**：B1 `geometryCore` + `offsetBounds` 纯函数 + makeViewport **重构调 geometryCore**（行为等价、不变像素、**零行为改**）。纯 Render 层 + host 测（既有 makeViewport 测全绿 = 等价证明 + bounds 行为对拍）。**不含 B4 overscroll 渲染**——见下方 planning 修正。
- **W3-11-R1b-wire（engine/gesture 接线 + B4 overscroll，一并交付）**：B4 overscroll 渲染 + B2 endPan/applyPanOffset 扩 bounds + B3 drag-clamp + Coordinator 每帧喂 bounds + B5 归一/strand + device runbook。依赖 R1a 的 `offsetBounds`/`geometryCore`。
- **planning 修正（B4 从 R1a 移入 R1b-wire）**：B4 overscroll 渲染**不可独立于 bounce/drag-clamp 单发**——若 R1a 仅加 B4 而 deceleration 仍是无界 plain（不 clamp drag、不 bounce settle），则 plain 减速的越界 overshoot 会被 B4 渲成**只增不回的静态间隙**（当前是 pin 边缘，无视觉间隙）= 行为回归。故 B4 必须与 R1b-wire 的 bounce（有界 overscroll + 回弹 settle）+ drag-clamp（拦 drag overshoot）**同 PR 交付**，使越界 offset 只来自有界弹簧。R1a 因此收窄为**纯行为中性 refactor + helper**（独立可 merge、零运行时行为变）。
- （拖拽期跟手橡皮筋阻尼 = 另一独立 follow-up **R1b-drag**，本 spec out of scope。）
- （拖拽期跟手橡皮筋阻尼 = 另一独立 follow-up **R1b-drag**，本 spec out of scope。）
- 注：W3-11-R1a/R1b-wire 同属 Render/engine 域、串行（R1b-wire 依赖 R1a 的 B1 + makeViewport overscroll）；与并行编排（`2026-06-15-wave3-fastfollow-parallelization.md`）Track A 一致。

---

## 九、验收 / 治理

- **评审通道**：改 `ios/**/*.swift` → `codex:adversarial-review`（配额耗尽 fallback opus 4.8 xhigh）+ Catalyst + app-build。
- **非-coder acceptance checklist**：host 测核 + §六.8 device runbook。
- **ledger**：本 PR（业务轨）**不碰** `wave3-completion.md`/`verify-wave3-completion.sh`/runtime-matrix（per 并行编排 §四 ledger-B）；`feature-completeness: PENDING-W3-11-R1` 的翻转 + 矩阵 bounce 行转 device 行留收尾 reconciliation PR。本 PR 仅记自身 `docs/acceptance/2026-06-15-w3-11-r1-*.md`。

---

## Changelog

| 日期 | 版本 | 说明 |
|---|---|---|
| 2026-06-15 | v1 | MVP 释放回弹接线设计；5 单元；user 裁决 MVP |
| 2026-06-15 | v2 (opus spec-review R1 修) | **C1 bounds 坐标纠正为锚相对带符号**（maxOffset=baseStartIndex·step / minOffset=(baseStartIndex−upperBound)·step，含 currentIdx+mainFrameWidth）；C2 candleStep=mainFrame.width/target；C3/D6 drag-clamp 后零速松手不弹→runbook 收窄（甩动才弹）；H1 朝界内主路径覆盖；H2 drag 每帧需 bounds；H3 overscroll 只动 pixelShift 不动 startIndex；H4 双边符号；M2 P7 freeScrolling 回归点名；M3 strand（activateDrawingTool/pinch/resize 中途 bounce）纳入处置；M4 bounds 测改行为对拍；L1 拆 R1a 几何/R1b-wire 接线 2 子 PR；L2 applyOffsetDelta 行号 :572-574；ledger-B（业务轨不碰治理 doc） |
| 2026-06-15 | v2.1 (opus spec-review R2 = APPROVE) | R2 从源码独立推导确认 bounds 公式数值精确+符号正确（3C+4H+4M+2L 全 RESOLVED，无数学新错）。折入 R2-M1：抽 `geometryCore→(baseStartIndex,upperBound,candleStep,visibleCount)` 共享内核，B1 bounds 与 makeViewport startIndex **同 core 派生**（坐实 D4 单一真相、消 startIndex 二处推导二义）；R2-L3 行号区间统一。**spec 收敛。** |
| 2026-06-15 | **R1a PARKED（codex R3 → reveal RFC 前置）** | R1a 实现（geometryCore+offsetBounds+makeViewport 重构）已交付：opus code-review APPROVE + 1017 host + Catalyst 绿；codex branch-diff R1（offsetBounds canonicalize/FP）+ R2（真运动区间消死区/NaN 安全）已修。**codex R3 揭出 makeViewport pre-existing 行为**：`upperBound=count−visibleCount`（全集）允许前向滚动渲未揭示**未来 candle**（KLineView 直接绘 slice 无 currentIdx 约束，已核实），offsetBounds 忠实镜像之。根治（约束 upperBound/slice 到 revealed prefix `currentIdx+1`）= **改顺位 3 冻结视口几何 + 产品决策**，超 R1a 行为中性 scope。**user 裁决（2026-06-15）：独立 RFC 先治 reveal**——R1a parked 在 branch `wave3-w3-11-r1-bounce-wiring`（不 merge），待 reveal RFC 修好 makeViewport 后 rebase（offsetBounds 改基于 revealed prefix、未来泄漏消、bounds 测随之更新），再续 R1a→R1b-wire。reveal RFC 见 `docs/superpowers/specs/2026-06-15-chart-reveal-constraint-*.md`（独立分支）。 |
| 2026-06-16 | **R1a UNPARKED + D5 rework（reveal RFC #113 merged）** | reveal RFC 已实现并 merge（PR #113 `bb0d597`：makeViewport `upperBound→max(0,baseStartIndex)` 禁前窥 + `sliceEnd→min(…,currentIdx+1)`）。本分支 rebase onto `bb0d597`：60b6744 冲突解析把 reveal 的 `upperBound=max(0,baseStartIndex)` 语义**下沉到 geometryCore**（makeViewport 输出 == reveal-on-main，行为保真）。**offsetBounds 代码零改**——它是 makeViewport startIndex clamp 的逆函数、与之共用 geometryCore（D4 红利），upperBound 一改即自动产出 D5：`maxOffset=roundTripEdge(baseStartIndex)`、`minOffset=roundTripEdge(baseStartIndex−upperBound)=roundTripEdge(0)=0`。改动：geometryCore.upperBound 公式 + offsetBounds/§三/§D5 docstring 按 D5（minOffset=0）+ 6 测试期望重算（geometryCore upper 120→71 / offsetBounds_known min −490→0 / matchesRenderClamp atMin 120→71·aboveMin 119→70 / earlyTick 改 [0,0] 无滚动空间 / span 0/710/1200 / roundTrip min 死分支→minOffset==0）。codex R2 旧解「真运动区间消死区」被 reveal superseded（早 tick 现 [0,0] 无滚动空间，非负区间）。1029 host + Catalyst 绿。R1b-wire 含义见 §六 B4 NOTE（最新边无前向 overscroll，bounce 仅最老边）。 |

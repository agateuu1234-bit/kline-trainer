# W3-11-R1 边缘 bounce 实时接线（MVP 释放回弹）—— 设计文档

**日期**：2026-06-15
**性质**：Wave 3 fast-follow，关闭 residual **W3-11-R1**（顺位 11 #96 `7eaf00b` 交付组件层 bounce 物理但未接线；live 接线 deferred）。把已就绪的 bounce 物理接进真 app 的手势/渲染管线，使**松手后的边缘回弹可见**，闭合 Wave 3 `feature-completeness: PENDING-W3-11-R1` 功能门之一。**改 `ios/**/*.swift`（trust-boundary）→ 经 `codex:adversarial-review`**。

**前置（已满足）**：顺位 3 Pinch（PR #98 `3187072`，去硬编码 `visibleCount`、动态视口几何）已 merged——这正是顺位 11 把 bounce 接线 defer 的阻塞依赖（设计 `2026-06-11-pr-wave3-11-edge-bounce-design.md` L11/L13/L25：「接线依赖 3 的视口几何，3 未开工故 defer」）。今接线不再返工。

**范围裁决（user 2026-06-15）**：**MVP 释放回弹**——甩动/拖到边缘**松手后**弹簧 overscroll+回弹可见；手指拖拽期保持当前 clamp（不跟手过边）。**Out of scope**：拖拽期跟手橡皮筋阻尼（独立 follow-up **R1b**）；device/sim 实测本身（runbook 交付，user 职责）。

---

## 一、现状与接线缺口（grep 核实 2026-06-15，见 §七 file refs）

bounce 物理三组件**已就绪 + 全单测**（顺位 11）：
- `EdgeBounceModel`（`ChartEngine/EdgeBounceModel.swift`）：注入 `initialVelocity/offset/minOffset/maxOffset` 的纯物理；`advance(dt)->FrameOutcome`（界内减速相用持久固定步累加器 + 越界临界阻尼弹簧相）；`normalizeToEdgeDelta()` scene-active 归一；`shouldRun` 守门。
- `DecelerationModel`（`DecelerationModel.swift`）：新增 `advance(dt:boundaryDistance:)->BoundaryOutcome`（`.moved/.stopped/.crossed`），既有 `advance(dt:)` 逐字不变（向后兼容 P7）。
- `DecelerationAnimator`（`DecelerationAnimator.swift:104-116`）：**已就绪但 live 未调用**的 bounce 启动面
  `public func start(initialVelocity:fromOffset:minOffset:maxOffset:)`（分离端点 CGFloat 防 NaN-trap；no-op guard = 亚阈速度**且** offset 界内才不弹，越界即便零速仍弹）。共享 generation/driver/`stop()`/`onUpdate`/`onFinish`/`resetOnSceneActive()` 生命周期。

**接线缺口（= W3-11-R1）**：
1. `TrainingEngine.endPan(velocity:panel:)`（`TrainingEngine.swift:607-611`）只调 `animator.start(initialVelocity:)`（**无边界**）→ 永不进 bounce。
2. **几何 offset 边界无来源**：`min=0` / `max=(count−visibleCount)·candleStep`，`candleStep=mainFrame.width/visibleCount` 是**渲染层像素几何**，engine/reducer 不持有 panel 像素宽 → endPan 拿不到 bounds。
3. `RenderStateBuilder.makeViewport`（`RenderStateBuilder.swift:82-85`）在边缘**静默钉死 `pixelShift=0`**（无 overscroll 渲染）→ 即便 offset 越界也看不到回弹。
4. 顺位 11 设计 §五**显式指派给 W3-11-R1** 的归一义务（`cancelPan` 越界归位 / `resetOnSceneActive` 接线）未接。

---

## 二、架构（5 个接线单元，additive，不改 bounce 物理）

### B1. 共享 offset-bounds 纯函数（单一真相，根治几何漂移）
把边界公式抽成**平台无关纯函数**（落 `Render/` 或 `ChartEngine/` 值类型层），供两处共用：
- 输入：`panelPixelWidth: CGFloat`、`visibleCount: Int`、`candleCount: Int`。
- 输出：`(minOffset: CGFloat, maxOffset: CGFloat, candleStep: CGFloat)`，其中 `candleStep = panelPixelWidth / CGFloat(visibleCount)`、`minOffset = 0`、`maxOffset = CGFloat(max(0, candleCount − visibleCount)) · candleStep`。
- **`RenderStateBuilder.makeViewport` 改为消费此函数**算 clamp（行为等价重构，不变像素）；**bounce-start 路径消费同一函数**算 bounds。→ render 钉死的边界与 bounce 弹回的边界**字节同源**。
- 退化：`candleCount ≤ visibleCount` → `maxOffset == minOffset == 0`（无滚动空间，合法；任意越界回弹至单点，`EdgeBounceModel` 已守 `min==max`）。

### B2. 几何边界喂进 engine（顺位 11 §residual 指派）
- `ChartContainerView.Coordinator`（持 panel 像素宽 `view.bounds.width` + 读 `renderState`/engine 的 `visibleCount` + `candleCount`）在 pan-end 用 B1 算 `(min,max)`。
- `TrainingEngine` 暴露 bounce-aware pan-end 接线面（**沿既有手势契约扩展，顺位 11 设计 + 顺位 1 RFC 已预指派**）：传 `(velocity, offsetBounds, panel)`；`startDeceleration` 效果触发时转发 `animator(for:panel).start(initialVelocity: v, fromOffset: <engine 当前 offset>, minOffset: min, maxOffset: max)`。`fromOffset` 取 engine 自身 panelState.offset（组件无状态，offset 真值在 engine）。
- **既有 `start(initialVelocity:)` 无边界面保留**（任何未提供 bounds 的旧调用路径行为不变，P7）。

### B3. 拖拽期保持 pin（MVP 无跟手橡皮筋）
- **在 `applyPanOffset`（手指 drag 入口 engine 方法）clamp**，**不**在 reducer `.offsetApplied` clamp（关键，见 D2）：`applyPanOffset(deltaPixels, offsetBounds, panel)` 算 `clampedDelta = clamp(offset+delta, min, max) − offset`，再 `reduce(.offsetApplied(clampedDelta))`。bounds 由 B2 的 Coordinator 同源喂入。→ 拖拽 offset 恒 `∈[min,max]`、不累积 overscroll，render 照旧 pin。
- **reducer `.offsetApplied` 逐字不变（仍无界累加）** → bounce 动画的 `onUpdate`→`applyOffsetDelta(delta)`→`.offsetApplied` **不经 clamp**，弹簧 overscroll 可正常突破边界（D2）。两条写入路径在 **engine 方法层** 区分（`applyPanOffset` clamp / `applyOffsetDelta` 不 clamp），非在 reducer action 层（二者同为 `.offsetApplied`，无法按 action 区分）。
- **结论：overscroll 只可能由「松手后弹簧」产生** → 使 B4 的 render 保持**无状态**判据「offset 越界即显 overscroll」，无需 render 耦合动画状态。
- 设计取舍（记录）：备选 = 不 clamp drag + render 加 `overscrollActive` flag（bounce 起置位/settle 清）；本设计选 **clamp drag-entry**（render 无状态更干净、杜绝「松手瞬间从 pin 跳到 drag 累积 overscroll」的视觉突跳、零 reducer 改动）。

### B4. render overscroll 橡皮筋（顺位 3 已 merged，视口几何可碰）
- `makeViewport`：当 `offset` 越界（`offset > maxOffset` 或 `< minOffset`，**仅弹簧期发生**）→ 把 overscroll 量（`offset − maxOffset` 或 `offset − minOffset`）渲成**面板平移**（边缘露出 rubber-band 间隙），取代 `pixelShift=0` 静默钉死。
- `offset` 界内（`[min,max]`）→ **行为逐字不变**（现有 clamp + 边缘 pin）。
- overscroll 渲染量纲：直接用 overscroll 像素作平移（弹簧物理本身已是阻尼轨迹，render 不再二次阻尼，避免双重衰减语义）。

### B5. 归一/cancel 接线（顺位 11 §五指派）
- `resetOnSceneActive()`（已在组件）→ 接进 app scene-active 路径（engine `onSceneActivated` 中继已存在，挂 animator 归一）使中途 bounce 越界 offset 归 edge（防 strand）。
- `cancelPan`-越界 → 经 bounce 启动面零速归位（组件 no-op guard 已支持「越界即便零速仍弹」）。
- 净效果：bounce 自然 settle / scene-active / cancel 三路径后 **engine offset 精确 == edge**，resume/持久化看到干净 clamped offset（无残留 overscroll）。

---

## 三、数据流（释放回弹）

```
手势 arbiter.onPan(.ended, velocityX)
  → ChartContainerView.Coordinator：B1 算 (min,max) from (view.width, visibleCount, candleCount)
  → engine bounce-aware endPan(velocity, offsetBounds, panel)
  → reduce(.panEnded(velocity)) → 若 .startDeceleration(v)
  → animator(panel).start(initialVelocity: v, fromOffset: engine.offset, minOffset, maxOffset)
  → 每帧 EdgeBounceModel.advance(dt) -> FrameOutcome
       界内减速相 → 到边界 cross → seed 弹簧于 edge → 越界弹簧相 → settle 于 edge
  → onUpdate(delta) → engine.applyOffsetDelta → reduce(.offsetApplied(delta))
       offset 沿 bounce 轨迹（overscroll 峰值 → 回落 edge），drag-clamp 不挡（B3 仅挡 drag 非 bounce delta，见 §五 D2）
  → RenderStateBuilder.makeViewport：offset 越界 → B4 渲 overscroll 平移（弹簧期可见）；落 edge 后回正
  → onFinish（自然 settle）→ offset == edge 精确
```

---

## 四、错误处理 / 边界

- `candleCount ≤ visibleCount`（无滚动空间，`min==max==0`）：B1 返单点边界；`EdgeBounceModel` `min==max` 合法（任意越界回弹至该点）；正常无 bounce（offset 恒 0）。
- 非有限几何（NaN/inf width/count）：B1 须返安全值（或 bounce-start 端点校验 → 组件 `shouldRun==false` 安全无 bounce）。
- scene-active 中途 bounce：`resetOnSceneActive()` 经组件共享 `terminate(notifyFinish:false)` 静默归 edge（B5）。
- `beginPan` re-grab 中途 bounce：既有 `animator.stop()` 保位（标准惯性语义，顺位 11 §五指派「保位由后续 pan/松手 bounce 收口」），不归一。
- drag-clamp 与 bounce delta 区分（§五 D2 关键不变量）：drag（`applyPanOffset`）clamp；bounce（`onUpdate`→`offsetApplied`）**不可被 clamp 挡**（否则弹簧 overscroll 被吞、无可见回弹）。

---

## 五、关键设计决策

- **D1 边界来源 = Coordinator 算 + 喂 engine**（非 engine 自算）：engine/reducer 不持 panel 像素宽（render-layer 值），故由持几何的 Coordinator 用 B1 算 bounds 喂入。保 engine 不侵入 UIKit 像素层。
- **D2 drag-clamp 不可误挡 bounce delta**（核心不变量，spec 级钉死）：clamp **只在 `applyPanOffset`（drag 入口）**，**不在 reducer `.offsetApplied`**——因 drag 与 bounce delta 同经 `.offsetApplied`（reducer 无法按 action 区分），若在 reducer clamp 则弹簧 overscroll 被吞、无可见回弹。故机制 = `applyPanOffset` 算 clampedDelta 后再 reduce（drag 恒界内）；bounce `applyOffsetDelta` 直传不 clamp（overscroll 突破边界，settle 由弹簧物理精确落 edge）。reducer 零改动。B3-3/D2 killer 测：注入 bounce delta 经 `applyOffsetDelta` 须能使 offset 越界。
- **D3 overscroll 渲染不二次阻尼**：弹簧物理已是阻尼轨迹，B4 render 直接平移 overscroll 像素，不再叠加 render 层阻尼（否则双重衰减、与物理 settle 点不一致）。
- **D4 单一真相 bounds**：B1 纯函数被 render clamp 与 bounce bounds 共用，杜绝两套几何公式漂移（顺位 3 动态 visibleCount 后尤其重要）。
- **D5 治理边界**：`endPan` 扩 bounds + 归一接线是**顺位 11 设计 §residual/§五 + 顺位 1 RFC 已预先指派给 W3-11-R1 的 wiring 义务**（非新 engine 契约），不另起 RFC；改 `RenderStateBuilder` 的 overscroll 渲染属顺位 3 已解锁的视口几何域。opus/codex review 复核此归属。

---

## 六、测试（host，平台无关优先）

1. **B1 bounds 纯函数**：given (width, visibleCount, candleCount) → (min,max,candleStep) 数值正确；**与 `makeViewport` clamp 公式一致**（同输入下 render clamp 的 upperBound·candleStep == maxOffset）；退化 count≤visibleCount → min==max==0。
2. **B2 endPan 带 bounds**：注入 fake `FrameDriving` + 探针 animator，断言 bounce-aware endPan 在 `startDeceleration` 时以**正确 `fromOffset`(engine 当前 offset)/min/max** 调 `start(...bounds)`；无 velocity（界内亚阈）→ 不启 bounce。
3. **B3 drag clamp**：`applyPanOffset` 推过边界 → offset clamp 到 `[min,max]`（不累积 overscroll）；**bounce onUpdate delta 不被 clamp**（overscroll 可越界，D2 killer 测）。
4. **B4 makeViewport overscroll**：offset 越界 → renderState 含 overscroll 平移（量纲 == overscroll 像素）；offset 界内 → 与现状逐字一致（pin 不变，回归）。
5. **B5 归一**：scene-active 中途越界 → resetOnSceneActive 后 offset==edge；bounce 自然 settle → offset==edge 精确。
6. **回归**：既有 `DecelerationAnimator`/`DecelerationModel`/plain-decel endPan 路径 host 测全绿（P7 向后兼容）；既有 makeViewport 界内测全绿。
7. **device/sim 运行时 runbook**（W3-11-R1 device 验收，闭合 Wave 3 矩阵 bounce 行）：非-coder 可执行——甩到最老/最新边缘松手 → 见弹簧 overscroll+回弹+落边缘；拖到边缘松手（无甩）→ 回弹；切周期/缩放后边缘 bounce 仍正确（消费动态 visibleCount）；中途切后台再回前台 → 无残留越界。**实测回填 = user 职责**。

---

## 七、file refs（grep 核实 2026-06-15）

- `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/EdgeBounceModel.swift`（物理，就绪）
- `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationModel.swift`（boundary-aware，就绪）
- `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift:104-116`（bounce 启动面，就绪未调用）
- `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift:607-611`（endPan 接线缺口）+ `:596-604`（beginPan/applyPanOffset）+ `:499-501`（applyOffsetDelta）+ `:141-142`（animator.onUpdate setup）
- `ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift:138-143`（panEnded→startDeceleration）+ `:160-164`（offsetApplied 无界累加，**逐字不变**——clamp 在 `applyPanOffset` engine 方法，非 reducer，D2）
- `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift:58-92`（makeViewport offset 分解 + 边缘 pin，待抽 B1 + overscroll）
- `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift:80-87`（Coordinator onPan 接线）
- 顺位 11 设计：`docs/superpowers/specs/2026-06-11-pr-wave3-11-edge-bounce-design.md`（§residual L43-47 / §五 stop 调用面归一指派）

---

## 八、验收 / 治理

- **评审通道**：改 `ios/**/*.swift` → `codex:adversarial-review`（唯一通道；配额耗尽 fallback opus 4.8 xhigh，documented）+ Catalyst + app-build required check。
- **非-coder acceptance checklist**（CLAUDE.md §2）：含 host 测核 + §六.7 device runbook。
- **闭环**：W3-11-R1 merged + device runbook 实测回填后，Wave 3 completion doc 的 `feature-completeness` 从 `PENDING-W3-11-R1` 解（更新 `residual-W3-11-R1-bounce-live-wiring: OPEN→CLOSED` + 矩阵 bounce 行从「排除/OPEN」转 device 行）——该 ledger 更新属本 PR 或紧随收尾。

---

## Changelog

| 日期 | 版本 | 说明 |
|---|---|---|
| 2026-06-15 | v1 (draft) | MVP 释放回弹接线设计；5 单元（bounds 纯函数 / 喂 engine / drag-clamp / render overscroll / 归一接线）；user 裁决 MVP（拖拽期橡皮筋 = R1b follow-up）；前置顺位 3 已 merged 解阻塞；待 opus 4.8 xhigh 对抗 review 到收敛 |

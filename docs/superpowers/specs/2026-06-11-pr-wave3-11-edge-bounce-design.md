# Wave 3 顺位 11 — 边缘 bounce 动画（组件层隔离交付）设计

**日期**：2026-06-11 ｜ **Anchor**：Wave 3 顺位 11（DAG ID，非执行序）｜ **轨**：G 图表/手势（DecelerationAnimator 扩展）
**Outline**：`docs/superpowers/specs/2026-06-09-wave3-outline-design.md` §二表行 11 + §三.2 + canonical DAG「11 Bounce ← 2（+3 若碰视口几何）」
**Spec 来源**：`kline_trainer_plan_v1.5.md` L88 + L1229「4. 边缘 bounce 动画（DecelerationAnimator 扩展）」（Phase 5 磨光，spec 无物理公式）

---

## 〇、用户范围裁决（2026-06-11）

完整可见 bounce 必须让 `RenderStateBuilder.makeViewport` 渲染 overscroll（把当前在边缘钉死的 `pixelShift` 橡皮筋化），那是**视口几何 = 顺位 3 Pinch 的领域**，而 3 未开工（无 branch/worktree；并行在场的是 6a engine）。用户裁决：**组件层隔离交付**——本 PR 只交付纯物理 bounce 组件 + 全单测，additive 不碰 `RenderStateBuilder`/`TrainingEngine` 几何与契约；**实时可见接线作 residual `W3-11-R1` 折入顺位 3 或 3 merged 后 fast-follow**。

理由：(a) 3 未 merged，对今日硬编码 `visibleCount=80` 几何接线 = 3 落地必返工（违 outline serial-neck/语义耦合纪律，codex R7-F1/R8-F1）；(b) 把 bounce 物理参数化在**注入边界**上，组件内零几何 → 真正隔离、可现在并行做、匹配 outline W1「11 bounce 若纯 DecelerationAnimator」预期。

---

## 一、Baseline 核实（grep-first，2026-06-09/06-11）

| 事实 | 证据 |
|---|---|
| `DecelerationAnimator` 故意 **panel-state/几何无关**（不变量 #7「本类型不持有也不引用任何面板状态类型」） | `ChartEngine/DecelerationAnimator.swift:36/37` |
| 动画器仅外溢 `onUpdate(delta)`；offset 真值在 `PanelViewState.offset` | `DecelerationAnimator.swift:37` + `modules:975` |
| `offset` **无 clamp**，经 `.offsetApplied` 自由累加 | `modules:1127` `offset += deltaPixels`；`TrainingEngine.swift:499-501` |
| 「边缘」只活在 `RenderStateBuilder.makeViewport`：clamp 显示 `startIndex ∈ [0, upperBound]`，边缘 `pixelShift=0`（静默钉死，无回弹反馈） | `Render/RenderStateBuilder.swift:82/86` |
| offset 边界几何依赖（`candleStep`/`visibleCount`），**顺位 3 去硬编码 `defaultVisibleCount=80` 会改该几何** | `RenderStateBuilder.swift:14/63-66`；outline §三.2 |
| 既有减速物理 = 帧率无关指数衰减，refInterval 子步积分 | `ChartEngine/DecelerationModel.swift:36-66` |
| `start(initialVelocity:)` 为 live 调用面（`TrainingEngine.endPan`），本 PR 不得回归 | `TrainingEngine.swift:534-538` |

**结论**：bounce 物理可做成「注入边界、组件内零几何」的纯值类型 → 隔离 + 并行安全；可见化需 makeViewport overscroll 渲染（3 领域，deferred）。

---

## 二、范围

### In scope（本 PR）
1. **`DecelerationModel` additive boundary-aware 推进 API（codex R8-F1）**：新增方法（如 `advance(dt:within:)`），跑**既有 damp-then-move 子步律**但子步内跨边即停在 edge、报 `(crossingVelocity, t_cross)`。**既有 `advance(dt:)` 与全部 `DecelerationModelTests` 逐字不动**（additive，无跨边时新 API reduce 为既有 advance）。
2. **`EdgeBounceModel`**（新纯值类型，`Sendable`/`Equatable`，零 UIKit/零几何）：注入 offset 边界（分离端点）上的「减速（用 boundary-aware 推进）→ 子帧跨边 seed 弹簧于 edge → 临界阻尼解析弹簧 ζ=1 → 回弹钉边界」完整轨迹物理。
3. **`DecelerationAnimator` additive bounce 路径**：新增 bounce-enabled 启动面（注入 `初速度 + 当前 offset + minOffset/maxOffset`），驱动 `EdgeBounceModel`。**既有 `start(initialVelocity:)` 无边界路径行为逐字不变**（向后兼容 `TrainingEngine` live 调用）。共享生命周期（generation / driver / `stop()` / `onUpdate` / `onFinish`）。
4. **全确定性单测**：`DecelerationModel` boundary-aware 测试 + `EdgeBounceModelTests` + `DecelerationAnimator` bounce 测试（见 §六）。
5. 验收文档（含 runtime runbook 处置说明，见 §七）。

### Out of scope（明列，避免 codex 攻击面外扩）
- **实时可见接线**（residual `W3-11-R1`，折入顺位 3 / 3 后 fast-follow）：
  - `RenderStateBuilder.makeViewport` overscroll 渲染（边缘 `pixelShift` 橡皮筋化，使 bounce 可见）；
  - `TrainingEngine.endPan` / `ChartContainerView` 把**真实几何 offset 边界**喂进 bounce 路径；
  - 手指拖拽期（`applyPanOffset`）的橡皮筋阻尼（gesture 层 + 几何，非「DecelerationAnimator 扩展」语义内）；
  - bounce 的 **device/sim 运行时 runbook 实测**（无可见运行时不可执行，随 W3-11-R1 交付）。
- 顺位 3 的 pinch/visibleCount 动态化、5 的十字光标、6 的 engine 契约——本 PR 零触碰。

### 范围边界判据（codex 可验证）
本 PR `git diff --stat` 只应触碰：`ChartEngine/EdgeBounceModel.swift`（新）、`ChartEngine/DecelerationModel.swift`（**additive** boundary-aware 方法，既有 advance 不动）、`ChartEngine/DecelerationAnimator.swift`（additive）、对应测试文件、本 design + plan + acceptance doc。**不得**出现 `RenderStateBuilder.swift` / `TrainingEngine.swift` / `ChartContainerView.swift` / `Reducer.swift` 改动（零几何/零 engine 契约）。

---

## 三、架构与组件

```
┌─────────────────────────────────────────────────────────────┐
│ DecelerationAnimator（@MainActor，UIKit/纯 macOS 帧驱动）      │
│                                                              │
│  既有路径（不变）：start(initialVelocity:) → RunModel.decel    │
│      └ DecelerationModel（指数衰减，无边界）                    │
│                                                              │
│  新增 bounce 路径（additive）：                                 │
│   start(initialVelocity:fromOffset:minOffset:maxOffset:)→.bounce│
│      └ EdgeBounceModel（复用 DecelerationModel 减速/越界弹簧）   │
│                                                              │
│  共享：currentGeneration / driver / isDecelerating /          │
│         stop() / resetOnSceneActive() / onUpdate / onFinish   │
│  每帧：handleTick(dt) → runModel.advance(dt) → move/stop       │
└─────────────────────────────────────────────────────────────┘
```

- **`FrameOutcome`**（internal enum，**原子 snap+stop 所需，codex R3-F1**）：`case move(delta: CGFloat)` / `case finish(finalDelta: CGFloat?, notifyFinish: Bool)`。`finish` 在**同一 tick** 内可外溢可选末 delta + 失活 driver + 按 `notifyFinish` 决定是否触发 `onFinish`——补足旧 `move/stop` 无法「外溢 snap 又静默停」的缺陷（P8）。映射：减速自然停 → `.finish(nil, true)`（= 旧 `.stop`+onFinish，P7 行为不变）；弹簧自然 settle → `.finish(snapDelta, true)`；越界异常归一（P8 静默）→ `.finish(edgeNormDelta, false)`。
- **`RunModel`**（internal enum，消除两条 tick 路径重复）：`case decel(DecelerationModel)` / `case bounce(EdgeBounceModel)`；`mutating func advance(dt:) -> FrameOutcome`。`.decel` 内部调既有 `DecelerationModel.advance`（**返回类型不改**，`.move→.move`/`.stop→.finish(nil,true)` 映射）→ **DecelerationModel 零改动（P7）**；`.bounce` 调 `EdgeBounceModel.advance` 直返 `FrameOutcome`。既有私有存储 `model: DecelerationModel` → `runModel: RunModel` 的内部重构（行为保留）：`handleTick` 统一经 `runModel.advance` + `FrameOutcome` 分支 + generation 校验；`start(initialVelocity:)` 构造 `.decel(...)`。**「additive」指公共/行为面**（公共 API 只新增、既有路径 byte-for-byte 不变，P7 守门）。
- **`EdgeBounceModel`** 拥有 offset 真值（检测越界需要）；动画器不再单独追踪 offset，仅转发模型外溢的 `delta`，使 wiring 后 `engine.offset` 沿 bounce 轨迹同步（deferred）。

### 数据流（单次 bounce 运行）
1. `start(initialVelocity:fromOffset:minOffset:maxOffset:)`（**分离端点 CGFloat，非 `ClosedRange`，codex R7-F3**——`ClosedRange` 在 NaN 端点构造即 trap，P6 守门不可达）：内部校验端点（非有限 / `min>max` → 安全无 bounce 退化），构造 `EdgeBounceModel`，`isDecelerating=true`，bump run-identity，建驱动。
   - **no-op guard（与既有 `start(initialVelocity:)` 区分，codex R3-F2）**：仅当 `velocity` 亚停止阈值 **且 `offset ∈ [min,max]`** 才 no-op；若 `offset` 已越界（即便 `velocity==0`）**仍须 start**——零速越界起点要弹簧回弹（服务 `cancelPan` 越界归位，§五.1）。
2. 每帧 `advance(dt) -> FrameOutcome`。记 `frameEntry = offset`；**每个 outcome 的 delta = `offset - frameEntry`**（该 tick 全位移，含同 tick 内减速+弹簧+snap，codex R4-F1：终止帧不丢早期子段位移）。异常 dt（`dt≥1.0`/`dt≤0`）：归一（越界→外溢 `edge-frameEntry`，界内→nil）+ `.finish(.., notifyFinish:true)`（与既有 `DecelerationModel` `dt≥1.0→.stop→onFinish` 一致，codex R6-F3；静默仅留显式 `stop()`/`resetOnSceneActive()`）。否则分两相：
   - **界内减速相（boundary-aware advancement，复用 damp-then-move 律 + 子帧跨边，codex R7-F1 + R8-F1）**：减速**用 `DecelerationModel` 既有 damp-then-move 律**（parity），但**不**用聚合 `advance(dt)`（聚合只在帧末报位移 → 跨边晚一帧 → seed 为**帧率依赖的过冲**：5pt away 下 120Hz≈2.83pt vs 60Hz≈10.20pt，bounce-specific 可见差，codex R8-F1）。改用**新增 boundary-aware 推进 API**（§二，**additive 加在 `DecelerationModel`**，既有 `advance(dt)` 与全测不动）：跑同一子步循环，**子步内若跨 `[min,max]` 则停在 edge**（用 damp-then-move 在该子步求精确跨边子时 `t_cross` + 跨边速度），报 `(crossingVelocity, t_cross)`。bounce 模型据此 **seed 弹簧于 edge（overscroll=0）、velocity=crossingVelocity，对该帧剩余 `dt−t_cross` 走弹簧**（消除帧率依赖过冲）。
     - **无跨边时 = `DecelerationModel.advance` 逐帧字节相同**（boundary-aware 推进在无边界事件时 reduce 为既有 advance）→ P4/P7 严格 parity。`.move(d)`：`offset+=d`；界内自然停（`|v|<stopThreshold`）→ `.finish(nil, true)`（= 既有自然停 + onFinish）。
     - **分区不变性边界（codex R7-F1）**：跨边 seed 在 edge（帧率一致）后，弹簧 state 分区不变（P3）；残余仅 crossingVelocity 受 damp-then-move **子步**粒度影响（与普通 fling 同量级，accepted），**非**聚合的整帧过冲差。
   - **弹簧相（临界阻尼 ζ=1，解析闭式，根治 codex R1-F3）**：`ω=√k`，`x=overscroll=offset−edge`；由 `(x,v)` 解析推进 τ：`A=x`、`B=v+ω·x`、`e=e^{-ωτ}`，则 `x'=(A+B·τ)·e`、`v'=(B(1−ω·τ)−ω·A)·e`。解析组合精确（推进 τ 一次 ≡ 拆两次，浮点容差内）→ **弹簧 state 任意分区精确无关**。
   - **首次过边事件 = 模型 state 精确，回调时序 ≤1 帧（codex R5-F1 + R7-F2）**：解析求 zero-crossing `t_zc=−A/B`（`B≠0` 且 `0<t_zc≤τ`，闭式）：存在 → 模型在 `t_zc` 把 offset 精确落 edge（clamp，**不进内侧** P2/R1-F2）→ `.finish(offset−frameEntry, true)`。**模型事件 state/time 解析精确**（model 测可经暴露的 consumed/event-time 严格断言）；但 `FrameOutcome` 不携时间戳，**动画器 onFinish/terminate 在包含 `t_zc` 的那个 display tick 触发 → 观测时序 ≤1 帧有界**（120Hz≈8.3ms vs 60Hz≈16.7ms），**非**严格帧无关（codex R7-F2 诚实化）。残余内向动量在 edge 吸收（带进内侧滚动属未来增强，out of scope）。
   - **settle-threshold（渐近衰减无 zero-crossing 角）**：`x(t)` 仅渐近趋 0（超越无闭式）→ 在满足 `|x|<posTol && |v|<velTol` 的帧终止 `.finish(offset−frameEntry, true)`；同属 **≤1 帧有界回调时序**，可见轨迹共时采样仍解析精确。
3. **共享终止 handler `terminate(finalDelta:notifyFinish:)`（re-entrancy-safe，codex R4-F3 + R5-F3）**——`handleTick` 的 `.finish` **与** `resetOnSceneActive` 的越界归一**都经此唯一路径**（不得各写一份，否则 reset 绕过保护）：
   1. **先脱离本 run**：捕获 run-identity token；`isDecelerating=false`；invalidate + nil driver；
   2. **再**回调 `if let fd, fd != 0 { onUpdate(fd) }`（此回调可能重入 `start()`/`stop()`）；
   3. **仅当 run-identity 未被重入的 start/stop 改动**才 `if notifyFinish { onFinish?() }`。
   `.move(d)` → `onUpdate(d)`（既有语义不变）。∴终止帧（含 reset 归一帧）onUpdate 里调 `start()`（启新 run）不被旧续延 invalidate；调 `stop()`（静默）不被旧续延误触 onFinish。run-identity = start/stop 均 bump 的内部 epoch（独立于既有 `generation` 的 stale-driver 用途，P7 不破）。`resetOnSceneActive` 越界 → `terminate(edge-offset, notifyFinish:false)`；界内 → `terminate(nil, false)`（= 既有静默 reset）。

---

## 四、物理契约（codify 不变量，弹簧细节归 plan-stage 调参）

弹簧**固定临界阻尼 ζ=1**（解析闭式，§三）。**`stiffness k` + settle 阈值（posTol/velTol）默认值归 plan-stage**，但下列**不变量确定性可测**，是正确性核心：

| # | 不变量 | 测试判据 |
|---|---|---|
| P1 | **钉边界收敛**：任意越界起点，轨迹收敛到**精确** edge 后停 | 末帧后 `offset==edge`（位精确，snap）；`.stop` 抵达 |
| P2 | **无内侧穿越（首次过边 clamp，任意 v0）**：回弹到 edge 即 clamp+stop，绝不进内侧——**靠首次过边 clamp 保证，非靠 ζ**（codex R1-F2：x0=10,k=100,v0=-1000 强内向起点临界阻尼解析解会过 0，必须 clamp）；ζ=1 额外保证外向穿透段无振荡 | 双边界 × 外向/内向初速度：overscroll 抵 0 即停于 edge，全程从不取内侧符号 |
| P3 | **帧率无关 = 弹簧 state + 子帧跨边 seed（codex R1-F3/R5-F1/R7-F1/R7-F2/R8-F1）**：弹簧 state 解析闭式 → 任意分区精确；**跨边 seed 经 boundary-aware 子帧推进落在 edge（overscroll=0）→ 消除聚合 advance 的整帧过冲帧依赖**（2.83@120 vs 10.20@60）。减速相轨迹本身仍继承 DecelerationModel 既有 partition-dependence（与普通 fling 同，不更差）；**回调时序 ≤1 帧有界**（R7-F2，onFinish 落含 `t_zc` 的 display tick） | **模型层**：弹簧 state 60/120/不规则/亚-refInterval → 严格浮点容差；zero-crossing event-time 解析精确；**端到端（始界内·跨边·回弹，codex R8-F1 恢复）**：60/120/不规则 → seed overscroll≈0（非 2.83 vs 10.20）+ 峰值穿透 在 **decel 子步容差**内一致（非整帧过冲差）。**动画器层**：onFinish 帧 ±1 帧有界 |
| P4 | **界内无跨边 = DecelerationModel parity（codex R6-F1/R7-F1）**：起点界内速度不足达边 → boundary-aware 推进**无边界事件时 reduce 为 `DecelerationModel.advance`**、零弹簧 → 与普通 fling **逐帧字节相同** | 无跨边时与同参 DecelerationModel **逐帧 delta 严格相等**（非近似/容差）；edge 判定与普通 fling 同；无越界 |
| P5 | **穿透有界**（外向起点）：最大 overscroll 有限，随初速度增、随 stiffness 减 | 单调性断言（v↑→峰值↑；k↑→峰值↓） |
| P6 | **防御（可达，codex R7-F3）**：非有限 velocity/offset/**bounds 端点** → 安全退化（无 bounce / 安全停），绝不外溢 NaN/inf delta。**bounds 用分离端点 CGFloat**（非 `ClosedRange`，后者 NaN 构造即 trap，守门不可达）→ 模型内校验后才用 | 注入 NaN/inf 端点（min/max/offset/velocity）→ 安全退化，无 trap、无 delta 含非有限；`min>max` → 安全无 bounce |
| P7 | **向后兼容**：`start(initialVelocity:)` 无边界路径 + `DecelerationModel.advance(dt:)` 既有路径**逐帧相同**；新增 boundary-aware 方法**纯 additive** | 既有 `DecelerationAnimatorTests`/`DecelerationModelTests` **不改全过**（既有 `advance(dt:)` 字节不动，仅新增方法 + 新测） |
| P8 | **bounce 终止归一（原子，codex R1-F1/R3-F1）+ finalDelta=全帧位移（codex R4-F1）+ onFinish 一致（codex R6-F3）**：终止帧 → **同一 tick** 外溢 `finalDelta=offset-frameEntry`（含该 tick 早期减速+弹簧子段，**不丢**）+ 失活；**onFinish 触发规则按终止来源**：abnormal-dt（`dt≥1.0`，advance 内）**触发** onFinish（与既有 `DecelerationModel` 契约一致）；**显式** `resetOnSceneActive()`/`stop()` **静默**不触发 | 越界中 `dt≥1.0` → 单 tick offset 落 edge + 失活 + **onFinish 触发**；`resetOnSceneActive()` 越界 → offset 落 edge + **onFinish 静默**；**多子段终止帧 finalDelta = 全帧位移**；re-grab `stop()` → 保位（见 §五） |
| P9 | **回调 re-entrancy 安全（codex R4-F3 + R5-F3）**：`handleTick.finish` **与 `resetOnSceneActive` 归一** 都经**共享 `terminate`**：回调前**先脱离 run**；onFinish 仅在未被重入 start/stop 改动 run-identity 时触发 | 终止帧/reset 归一帧 onUpdate 内调 `start()` → 新 run driver 不被旧续延 invalidate + 旧 onFinish 不触发；调 `stop()` → onFinish 静默不触发 |

**边界表示（codex R7-F3）**：公共面用**分离端点 `minOffset:maxOffset: CGFloat`**（**非** `ClosedRange<CGFloat>`——`min...max` 在 NaN/`min>max` 构造即 trap，P6 守门不可达）。模型内 `init` 校验：非有限端点或 `min>max` → 安全退化（无 bounce）；`min==max` 合法（无滚动空间，任意越界回弹至该单点）。

---

## 五、错误处理 / 边界情形

- **非有限输入**（velocity/offset/bounds 端点 NaN/inf）：mirror `DecelerationModel` 既有 defense（`isFinite` 守门）→ `.stop`，不建弹簧、不外溢非有限 delta（P6）。
- **起点已越界**（wiring 后：用户拖过边松手）：直接进弹簧相，seed `overscroll=offset-edge`、`velocity=initialVelocity`。
- **起点界内、速度不足达边**：纯减速自然停，无弹簧（P4）——`EdgeBounceModel` 自然 subsume 无 bounce 情形。
- **bounce 终止归一（codex R1-F1，核心）**：因动画器仅经 `onUpdate(delta)` 通信，越界中途终止会把 `offset` 永久留在界外（wiring 后 → 重启/resume 不连续 + 反复 bounce）。三类终止显式区分（**onFinish 触发与既有契约一致，codex R6-F3**）：
  - **`advance(dt)` 内 abnormal dt（`dt≥1.0` 或 `dt≤0`）**：经共享 `terminate(edge-offset 若越界 else nil, notifyFinish:**true**)`（§三.3）→ 外溢归一 delta + offset 落 edge + **触发 onFinish**（与既有 `DecelerationModel` `dt≥1.0→.stop→onFinish` 一致；consumer 经 onFinish 可靠观测完成）。
  - **显式 `resetOnSceneActive()`（scene-active 复位）**：经共享 `terminate(edge-offset 若越界 else nil, notifyFinish:**false**)` → 越界归一防 strand（P8）+ **静默不触发 onFinish**（与既有「外部 reset 不触发 onFinish」一致）。**不得**另写归一路径绕过该保护（re-entrancy，codex R5-F3）。
  - **`stop()` on re-grab（`beginPan`）**：**保持位置不归一**（新手势接管，标准惯性语义；wiring 后由后续 pan/松手 bounce 收口）；静默不触发 onFinish（既有语义）。
- **重复 start / stop**：复用既有 generation 自增 + driver 失活；`stop()`/`resetOnSceneActive()` 静默不触发 `onFinish`（既有语义不变，叠加上述 bounce 越界归一）。

### 五.1 `stop()` 调用面意图矩阵（codex R2-F1）

单一共享 `stop()` 不能同时满足「保位」与「归边」两种 caller 意图。**本 PR 组件 scope 禁改 `TrainingEngine`**，故此处**穷举**全部现有 `stop()` 调用面、判其是否 strand、并把需归一的接线义务**显式指派给 W3-11-R1**（含集成测试）：

| 现有调用面 | 文件:行 | 意图 | bounce 中途停是否 strand？ | 处置 |
|---|---|---|---|---|
| `beginPan`（re-grab） | `TrainingEngine.swift:524` | 保位（新手势接管） | 否——**当且仅当** re-grab 后以 `endPan`（松手）收口（启 bounce） | `stop()` 保位语义不变 |
| `cancelPan`（取消/多指接管，**不启 animator + 保 offset**，codex R3-F2） | `TrainingEngine.swift:543-545` | 保位 | **是**——re-grab→bounce 中途取消（多指接管/手势 cancelled，`ChartContainerView.swift:76` 路由）→ 无 animator、offset 永久滞留界外 | **W3-11-R1 义务**：cancelPan-while-overscrolled → 启**零速 bounce**（`start(initialVelocity:0,...)` 弹簧回弹，组件已支持 §三.1 guard）或 normalize；加「bounce→re-grab→cancel」集成测试 |
| `stopAllDeceleration` → `resetOffsetAfterAutoTracking`（trade/周期硬切 D7/D8） | `TrainingEngine.swift:504-516` | 归一 | 否——硬切后 `resetOffsetAfterAutoTracking` 把 offset→0（autoTracking 锚=最新边=in-bounds），**自愈** | 无需改 |
| `activateDrawingTool`（画线激活，停后用冻结 offset 算 range） | `TrainingEngine.swift:569` | 冻结当前 | **是（仅 wiring 后）**——若停于越界且 W3-11-R1 让 makeViewport 渲染 overscroll，则画线快照建于越界视口 + 冻结于可见 overscroll | **W3-11-R1 义务**：加显式 normalize-to-edge 取消 API，`activateDrawingTool` 改调之；加「越界中画线激活」集成测试 |

**组件 bounds 契约（codex R5-F2 + R6-F2）**：`EdgeBounceModel` 在 `start` **快照单一 `bounds`**（不订阅几何变更）——这是组件**刻意契约**（保持几何无关、隔离）。bounds 在 bounce 运行中保持新鲜是 **wiring 责任**：**任意视口几何变更（pinch + 窗口/Stage Manager/Split-View resize + inactive→active layout）** 须 normalize/stop 当前 bounce 或推新 bounds（§七 W3-11-R1 item 6）。

**组件 scope 非显现论证（直接答 codex「neither resolved nor tested」）**：本 PR **不把 bounce 接进 engine**（`TrainingEngine` 零改，§二范围判据），故**无任何 live 调用面（`beginPan`/`cancelPan`/`activateDrawingTool`/硬切）会停一个真实 bounce**，**亦无 pinch 接线改几何**（顺位 3 未在场）；且 `makeViewport` 当前仍在边缘 pin `pixelShift=0`（未渲染 overscroll，`RenderStateBuilder.swift:86`）→ 即便 offset 滞留界外也不可见。∴这些 strand（cancelPan / activateDrawingTool）**在本 PR scope 内不可显现、不可测**（无 wiring 即无 live bounce）。**组件已提供消解所需原语**：`resetOnSceneActive` 归一（P8，自身生命周期所需，已实现+测）+ 零速越界 `start` 弹簧回弹（§三.1 guard，服务 cancelPan）。需真实 caller 的部分（normalize 取消 API + `cancelPan`/`activateDrawingTool` 改接 + 两集成测试）按 YAGNI 不预造，整体**指派 W3-11-R1**，见 §七。

---

## 六、测试策略（全确定性、host 可跑、零运行时依赖）

- **`DecelerationModel` boundary-aware 测试（codex R8-F1）**：新 `advance(dt:within:)` —（a）**无跨边时与 `advance(dt:)` 逐帧 delta 严格相等**（P4/P7 reduce 证）；（b）跨边时停在 edge、报 `(crossingVelocity, t_cross)` 满足 damp-then-move（手算对照）；（c）**子帧跨边帧无关**：edge 5pt away、v=1000，60Hz vs 120Hz → 报告的 crossing state（offset=edge）一致、crossingVelocity 在子步容差内（驳聚合的 2.83 vs 10.20 过冲）。**既有 `DecelerationModelTests` 不改全过**（既有 advance 字节不动）。
- **`EdgeBounceModelTests`**：P1-P8 逐条 + 复用注入 fake dt 序列（确定性）。关键 killer：
  - settle 后 `offset` **精确** == edge（非近似，P1）；
  - **首次过边 clamp（P2，codex R1-F2）**：双边界 × 外向 + **强内向**起点（含 codex 反例 `x0=10,k=100,v0=-1000`）→ overscroll 抵 0 即停于 edge，全程从不取内侧符号；
  - **弹簧 state 分区不变（P3，codex R1-F3）**：**给定同一 seed** 的弹簧相，同 elapsed 下 60/120Hz/不规则/亚-refInterval 分区 → 末 offset + 峰值穿透 **严格浮点容差**内一致；「推进 τ 一次 ≡ 拆两次」直证解析组合性（**仅弹簧 state，不含 decel handoff seed**）；
  - **模型事件时刻解析精确（P3 model-layer，codex R5-F1/R7-F2）**：弹簧 zero-crossing `t_zc=−A/B` 经模型暴露的 consumed/event-time **解析精确断言**（与回调帧分离；动画器层 onFinish ±1 帧另测，见动画器 bullet）；
  - **decel 无跨边 parity（P4，codex R7-F1）**：界内不跨边时 boundary-aware 推进 reduce 为 `DecelerationModel.advance` → 与同参 `DecelerationModel` **逐帧 delta 严格相等**；
  - **端到端跨边帧无关 seed（P3 端到端，codex R8-F1 关键恢复）**：**始界内·跨边·回弹**，60Hz vs 120Hz vs 不规则 → seed overscroll **≈0**（非聚合 advance 的 2.83@120 vs 10.20@60）+ 峰值穿透在 **decel 子步容差**内一致（直证子帧跨边消除整帧过冲帧依赖）；
  - **零速越界回弹（codex R3-F2）**：`start(initialVelocity:0, fromOffset:越界, minOffset:maxOffset:)` **不 no-op**，弹簧回弹至 edge 停（服务 cancelPan）；`velocity` 亚阈 + `offset∈[min,max]` 才 no-op；
  - **多子段终止帧 finalDelta（P8，codex R4-F1）**：单 tick 内「减速→跨边→弹簧→settle」全发生 → `.finish.finalDelta == offset_final - frameEntry`（含全部子段位移，**非**仅末 snap）；界内速度衰到阈的终止帧亦报全帧位移不丢；
  - **bounds 端点防御可达（P6，codex R7-F3）**：注入 NaN/inf `minOffset`/`maxOffset` 或 `min>max` → 安全退化无 trap（分离端点使 P6 守门可达，非 `ClosedRange` 构造即 trap）；
  - **abnormal-dt onFinish 一致（codex R6-F3）**：`dt≥1.0` 终止 → 越界外溢 edge-归一 delta + **触发 onFinish**（与既有契约一致），区别于显式 reset 的静默；
  - mutation-style demonstrator：外向起点穿透峰值**非零**（避免空洞 demonstrator，per `feedback`：正向 FP demonstrator 须实测非零）。
- **`DecelerationAnimator` bounce 测试**：注入 fake `FrameDriving` + fake dt（复用既有 DD-1/DD-5 缝）；验证 bounce 路径外溢 delta 序列累加后 offset 落 edge、自然 settle `onFinish` 恰一次、generation/stale 与既有同守；**P8 原子终止 + onFinish 一致（codex R3-F1/R6-F3）**：越界中 `dt≥1.0` → **同一 tick** 外溢 edge-归一 delta + 失活 + **onFinish 触发**（既有契约一致）；越界中 `resetOnSceneActive()` → 外溢 edge-归一 delta + 失活 + **onFinish 静默**；越界中 re-grab `stop()` → 保位不归一（§五区分）；**P9 回调 re-entrancy（codex R4-F3 + R5-F3）**：终止帧 onUpdate 内调 `start()` → 新 run driver 存活不被旧续延 invalidate + 旧 onFinish 不触发；调 `stop()` → onFinish 静默不触发；**`resetOnSceneActive` 越界归一帧亦经共享 `terminate` → 同样 re-entrancy 安全**（reset 归一 onUpdate 内调 start/stop 同守，codex R5-F3）；**回调时序 ≤1 帧有界（codex R5-F1/R7-F2）**：弹簧 zero-crossing 的模型 state 精确落 edge，但动画器 onFinish/terminate 在含 `t_zc` 的 display tick 触发 → 断言 **±1 帧有界**（**不**断言 60/120Hz 严格同时刻）；**既有 `DecelerationAnimatorTests` 不改全过**（P7 回归门）。
- **基线**：worktree 起点 `swift test` = **799 tests / 120 suites / 0 fail**（已实测 2026-06-11）。

---

## 七、Residual / runtime runbook / 隔离证明

### Residual `W3-11-R1`（live 可见 bounce wiring）
折入**顺位 3 Pinch** 或 3 merged 后 fast-follow，至少含：
1. `makeViewport` overscroll 渲染（边缘 `pixelShift` 橡皮筋化，使 bounce 可见）；
2. `endPan`/`ChartContainerView` 喂**真实几何 offset 边界**进 bounce 启动面；
3. 拖拽期（`applyPanOffset`）橡皮筋阻尼；
4. **`stop()` caller-intent 收口（codex R2-F1）**：加显式 normalize-to-edge 取消 API + `activateDrawingTool` 改调之 + **「越界中画线激活」集成测试**（断言不 strand overscroll）；
5. **`cancelPan` 越界归位（codex R3-F2）**：cancelPan-while-overscrolled → 启零速 bounce 或 normalize + **「bounce→re-grab→cancel」集成测试**；
6. **任意视口几何变更时 bounds 失效防护（codex R5-F2 + R6-F2）**：bounce 在 `start` 快照单一 `bounds`；offset 边界经 `candleStep` 依赖**视口宽度 + visibleCount**，故**不止 pinch**——**窗口缩放 / Stage Manager / Split View / 后台→前台 layout 变更**均可在 bounce 中改几何 → 活跃 bounce snap 到**陈旧 edge**（可见跳变/非法 offset）。义务：**每一次视口几何变更（pinch + 窗口/Stage Manager/Split-View resize + inactive→active layout）都须原子 normalize/stop 当前 bounce 或推新 bounds** + 集成测试（「bounce→pinch」「bounce→窗口 resize」「inactive-resize→activation」）；
7. bounce device/sim 运行时 runbook 实测。

**Wave 3 收尾（顺位 13）的运行时矩阵 bounce 行依赖此 residual 完成，本 PR 不 claim bounce 可见/已运行时验证。**

### Runtime runbook 处置（诚实，预挡 codex「缺 runbook」）
outline §三.3 要求每新交互锚交付 runtime runbook 条目。**本 PR 组件无可见运行时**（未接线 → 真 app 看不到回弹），故 bounce 的 device/sim runbook **不可执行**、显式随 `W3-11-R1` deferred。本 PR 的验证 = §六确定性单测（物理正确性在此完全闭合）。验收文档须逐字记此 deferral，非遗漏。

### 隔离证明（构造式，回答 outline「plan 须先证隔离」）
1. **组件零几何**：`EdgeBounceModel`/动画器 bounce 路径只收**边界值**（分离端点 `minOffset:maxOffset: CGFloat`），从不计算 `candleStep`/`visibleCount`/viewport → 顺位 3 改几何不触碰本组件。
2. **零 engine 契约改动**：不加 public engine API、不改 `TrainingEngine`/`Reducer`/`RenderStateBuilder`；既有 `start(initialVelocity:)` 行为不变 → 与并行 6a engine 契约工作 disjoint。
3. **公共/行为面 additive**：新文件 + 动画器新增启动面；既有 `start(initialVelocity:)` 行为 byte-for-byte 不变、live 调用面（endPan）不改（内部 `model`→`runModel` 重构为私有消重，P7 回归门守）→ 零回归风险。
∴ 本 PR 与并行轨（6a engine / 未来 3 Pinch）文件 + 语义均 disjoint，真并行安全。

---

## 八、验收要点（占位，详表归 plan + acceptance doc）
- 全 grep gate：diff 不含 `RenderStateBuilder`/`TrainingEngine`/`ChartContainerView`/`Reducer` 改动（§二范围判据）。
- `swift test` 绿且 ≥ 799 + 新增 bounce 测试数；既有减速/动画器测试零改动通过（P7）。
- Catalyst build-for-testing required check 通过（编译 + 链接；无运行时）。
- 验收文档逐字记 `W3-11-R1` deferral + runbook deferral（§七诚实条款）。

---

## 九、codex 对抗性 review 收敛

| 轮 | scope | verdict | findings → 处置 |
|---|---|---|---|
| R1 | branch-diff | needs-attention | **F1[high]** 后台/reset/大-dt 终止把 offset 永久留界外（动画器仅经 onUpdate 通信）→ §五+P8 bounce 终止归一（reset/大-dt 越界先外溢 edge-归一 delta，re-grab 保位区分）+ 测试。**F2[med]** 临界阻尼**不**保证无内侧穿越（强内向 v0 解析解会过 0，反例 x0=10,k=100,v0=-1000）→ P2 改**首次过边 clamp**（任意 v0 保证）+ 双边界外/内向测试。**F3[med]** Euler 子步非真分区不变（松容差掩盖刷新率依赖运动）→ §三弹簧相改**解析临界阻尼闭式传播**（dt 切分精确无关）+ P3 严格容差 + 60/120/不规则/亚-refInterval 分区测试。 |
| R2 | branch-diff | needs-attention | **F1[high]** 共享 `stop()` 不能同时满足保位/归边两 caller 意图（`activateDrawingTool` 等也调 stop()），scope 禁改 engine → §五.1 穷举调用面意图矩阵 + 组件 scope 非显现论证（无 wiring 即无 live bounce + makeViewport 仍 pin）+ 把 normalize 取消 API/caller 改接/越界画线激活集成测试**指派 W3-11-R1**（§七）。**F2[med]** 整帧 decel 后才切相 → spring-start seed 帧率依赖（6.8@120 vs 14.2@60），解析弹簧救不了帧率依赖的 seed → §三改**子步级过边 handoff**（跨边子步 seed 弹簧于 edge + 推进余下时间，帧率无关至 refInterval）+ P3b 端到端（始界内·跨边·回弹）分区测试。 |
| R3 | branch-diff | needs-attention | **F1[high]** `move/stop` 不能同 tick 外溢 snap + 静默停 → §三新增 `FrameOutcome{move/finish(finalDelta:,notifyFinish:)}` 原子终止（DecelerationModel 仍零改，映射）+ P8 原子 + 测试 same-tick 失活/归一/抑制 onFinish。**F2[high]** 漏 `cancelPan`（不启 animator + 保 offset）：re-grab→bounce→cancel 永久滞留越界 → §五.1 加 cancelPan 行 + 组件支持零速越界 `start` 回弹（§三.1 guard）+ W3-11-R1 加 cancel 集成测试。**F3[med]** P3b 比 seed(恒 0)/末(恒 edge) = 恒等 tautology → 改比瞬态量（handoff 速度/时刻 + 峰值穿透 + settle 时长 + 逐采样轨迹）。 |
| R4 | branch-diff | needs-attention | **F1[high]** 终止帧丢早期子段位移（DecelerationModel 保留累积位移，`.finish(nil)` 会丢）→ `finalDelta=offset-frameEntry`（全帧位移）+ P8/§三 + 多子段终止帧测试。**F2[high]** refInterval 子步**每 advance 重启**→ 不规则帧抖动改 handoff（7.8333 vs 7.9518，边界 7.9pt away）→ §三减速相改**解析指数衰减闭式 + 解析求 t_cross**（全程解析，任意分区精确无关）+ P3 改「精确无关」+ P3c 抖动 straddle 测试 + P4 改连续极限容差。**F3[high]** finish 在 teardown 前调 onUpdate → 重入 start/stop 破坏 run（新 driver 被旧续延 invalidate / stop 后仍 onFinish）→ §三 finish **先脱离 run 再回调** + run-identity epoch 守 onFinish + P9 + 终止帧重入 start/stop 测试。 |
| R5 | branch-diff | needs-attention | **F1[high]** 解析 state 分区无关但**终止**不是：整帧推进后才判 crossing/settle → 事件落下一帧边界，settle 时长/峰值/onFinish 时序仍帧依赖 → §三弹簧改**在 τ 内解析求 zero-crossing `t_zc=−A/B` 按事件终止**（终止时刻帧率无关）；唯渐近 settle-threshold（超越）放宽 **≤1 帧有界方差**（P3(d)，共时状态仍精确）。**F2[med]** `start` 快照 bounds，pinch 改几何 → snap 陈旧 edge → 组件 bounds 契约（快照=刻意隔离）+ W3-11-R1 item 6（pinch-begin normalize/stop 或 bounds-update + 集成测试）+ 组件 scope 无 pinch 非显现。**F3[med]** `resetOnSceneActive` 归一绕过 detach-first 保护 → 重入风险 → §三.3 **共享 `terminate` handler**（handleTick `.finish` 与 reset 归一同经）+ reset 重入 start/stop 测试。 |
| R6 | branch-diff | needs-attention | **F1[high]** 解析连续积分减速 ≠ DecelerationModel 子步律（v=1000：134.61 vs 130.49pt，edge@132 从不跨变可见 bounce）→ 减速相改**持久固定步累加器（复用 DecelerationModel damp-then-move 同律 + 跨 advance 携带余量）**：达边判定与普通 fling 一致（消 ~3% 律差）且固定步与帧解耦（partition-invariant）；P3/P4 改述。**F2[med]** bounds 失效不止 pinch（窗口/Stage Manager/Split-View resize 经 candleStep 改边界）→ W3-11-R1 item 6 扩为**任意视口几何变更** + 3 集成测试。**F3[med]** abnormal-dt 仅越界时静默 onFinish 与既有契约不一致 → abnormal-dt **触发 onFinish**（一致），静默仅留显式 stop/reset（P8/§五）。 |
| R7 | branch-diff | needs-attention | **根因暴露（收敛点）**：**F1[high]** partition-invariant decel 与 DecelerationModel parity **互斥**（后者本就 partition-dependent，240Hz：132.54 vs 130.49pt）→ 选 parity：减速相**直接复用 `DecelerationModel.advance`**（逐帧字节相同，与普通 fling 无异），**放弃 decel 分区不变 claim**，分区不变只 claim 弹簧 state（P3/P4 重写，移除 P3b/P3c 端到端/straddle 测试）。**F2[high]** exact `t_zc` 只定模型 state，FrameOutcome 无时间戳 → onFinish 仍落 display tick（120Hz 8.3 vs 60Hz 16.7ms）→ 区分**模型 event-time（精确）vs 动画器回调（≤1 帧有界）**（P3 诚实化 + 测分层）。**F3[med]** `ClosedRange<CGFloat>` NaN 构造即 trap，P6 不可达 → 公共面改**分离端点 `minOffset:maxOffset:`** + 内部校验（P6 可达）。 |
| R8 | branch-diff | needs-attention（**1 finding，近收敛**） | **F1[high]** 复用聚合 `DecelerationModel.advance(dt)` → 跨边只在帧末检出 → seed 为**帧率依赖整帧过冲**（edge 5pt away：120Hz 2.83pt vs 60Hz 10.20pt，bounce-specific 可见差）→ §二/§三 加 **`DecelerationModel` additive boundary-aware 推进**（同 damp-then-move 律 + 子步内跨边停 edge 报 `(crossingVelocity, t_cross)`）+ EdgeBounce 据此 seed 弹簧于 edge、消耗剩余帧 → seed 帧无关；恢复端到端跨边测试（P3/P4 改述，无跨边 reduce 为既有 advance 保 parity）。 |

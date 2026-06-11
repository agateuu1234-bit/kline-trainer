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
1. **`EdgeBounceModel`**（新纯值类型，`Sendable`/`Equatable`，零 UIKit/零几何）：在注入 offset 边界上的「惯性减速 → 越界临界阻尼弹簧 → 回弹钉边界」完整轨迹物理。组合复用既有 `DecelerationModel` 做界内减速段，越界段用临界/过阻尼弹簧。
2. **`DecelerationAnimator` additive bounce 路径**：新增 bounce-enabled 启动面（注入 `初速度 + 当前 offset + 边界`），驱动 `EdgeBounceModel`。**既有 `start(initialVelocity:)` 无边界路径行为逐字不变**（向后兼容 `TrainingEngine` live 调用）。共享生命周期（generation / driver / `stop()` / `onUpdate` / `onFinish`）。
3. **全确定性单测**：`EdgeBounceModelTests` + `DecelerationAnimator` bounce 测试（见 §六）。
4. 验收文档（含 runtime runbook 处置说明，见 §七）。

### Out of scope（明列，避免 codex 攻击面外扩）
- **实时可见接线**（residual `W3-11-R1`，折入顺位 3 / 3 后 fast-follow）：
  - `RenderStateBuilder.makeViewport` overscroll 渲染（边缘 `pixelShift` 橡皮筋化，使 bounce 可见）；
  - `TrainingEngine.endPan` / `ChartContainerView` 把**真实几何 offset 边界**喂进 bounce 路径；
  - 手指拖拽期（`applyPanOffset`）的橡皮筋阻尼（gesture 层 + 几何，非「DecelerationAnimator 扩展」语义内）；
  - bounce 的 **device/sim 运行时 runbook 实测**（无可见运行时不可执行，随 W3-11-R1 交付）。
- 顺位 3 的 pinch/visibleCount 动态化、5 的十字光标、6 的 engine 契约——本 PR 零触碰。

### 范围边界判据（codex 可验证）
本 PR `git diff --stat` 只应触碰：`ChartEngine/EdgeBounceModel.swift`（新）、`ChartEngine/DecelerationAnimator.swift`（additive）、对应两测试文件、本 design + plan + acceptance doc。**不得**出现 `RenderStateBuilder.swift` / `TrainingEngine.swift` / `ChartContainerView.swift` / `Reducer.swift` 改动。

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
│      start(initialVelocity:fromOffset:within:) → RunModel.bounce│
│      └ EdgeBounceModel（注入边界；界内减速 / 越界弹簧 / 钉边界）  │
│                                                              │
│  共享：currentGeneration / driver / isDecelerating /          │
│         stop() / resetOnSceneActive() / onUpdate / onFinish   │
│  每帧：handleTick(dt) → runModel.advance(dt) → move/stop       │
└─────────────────────────────────────────────────────────────┘
```

- **`RunModel`**（internal enum，消除两条 tick 路径重复）：`case decel(DecelerationModel)` / `case bounce(EdgeBounceModel)`；`mutating func advance(dt:) -> Outcome`。既有私有存储 `model: DecelerationModel` → `runModel: RunModel` 的**内部重构**（非纯 additive，但**行为保留**）：`handleTick` 统一经 `runModel.advance`，逐字保留 move/stop 分支与 generation 校验；`start(initialVelocity:)` 构造 `.decel(...)`。**「additive」指公共/行为面**（公共 API 只新增、既有路径行为 byte-for-byte 不变，P7 守门）；内部存储为消重做最小重构，私有故不破契约。
- **`EdgeBounceModel`** 拥有 offset 真值（检测越界需要）；动画器不再单独追踪 offset，仅转发模型外溢的 `delta`，使 wiring 后 `engine.offset` 沿 bounce 轨迹同步（deferred）。

### 数据流（单次 bounce 运行）
1. `start(initialVelocity:fromOffset:within:)`：构造 `EdgeBounceModel(velocity, offset, bounds, spring)`，`isDecelerating=true`，generation++，建驱动。
2. 每帧 `advance(dt)`：
   - **界内**（`offset ∈ bounds`）→ 复用 `DecelerationModel` 指数衰减；若界内自然停（速度 < 阈值）→ `.stop`（无弹簧，等价纯减速）。
   - **越界临界**（衰减使 offset 跨出 bounds）→ 切弹簧相，seed `velocity=当前速度`、`overscroll=offset-edge`。
   - **弹簧相**：临界/过阻尼弹簧 `a=-k·x-c·v`（`x=overscroll`，`c=2√k·ζ`，`ζ≥1`）；refInterval 子步积分（帧率无关，同 DecelerationModel 风格）。penetrate → 反向回弹 → 进入 settle。
   - **settle**（`|overscroll|<posTol && |velocity|<velTol`）→ 外溢「钉边界」snap delta（`edge-offset`），offset 精确落 edge，下一帧 `.stop`。
3. `.stop` → 失活 driver + `onFinish?()`（与既有减速自然结束同语义）。

---

## 四、物理契约（codify 不变量，弹簧细节归 plan-stage 调参）

弹簧默认 `ζ=1`（临界阻尼）。**可调参（stiffness/ζ/阈值）的默认值归 plan-stage**，但下列**不变量与默认 `ζ≥1` 绑定、确定性可测**，是正确性核心：

| # | 不变量 | 测试判据 |
|---|---|---|
| P1 | **钉边界收敛**：任意越界起点，轨迹收敛到**精确** edge 后停 | 末帧后 `offset==edge`（位精确，snap）；`.stop` 抵达 |
| P2 | **无穿越（ζ≥1）**：回弹不冲过 edge 到反侧 | overscroll 符号全程不翻转（单调回归 0） |
| P3 | **帧率无关**：不同 dt 切分下 settle 位置 + 轨迹形状一致（子步 refInterval 积分） | 同初值，dt=1/120 单帧 vs 多小帧 → 末 offset + 峰值穿透 在容差内一致 |
| P4 | **界内 = 纯减速**：起点界内且速度不足达边 → 逐帧等价 `DecelerationModel`（零弹簧） | 与同参 DecelerationModel 轨迹逐帧相等；无越界 |
| P5 | **穿透有界**：最大 overscroll 有限，随初速度增、随 stiffness 减 | 单调性断言（v↑→峰值↑；k↑→峰值↓） |
| P6 | **防御**：非有限 velocity/offset/bounds 端点 → 安全停，绝不外溢 NaN/inf delta | 注入 NaN/inf → `.stop`，无 delta 含非有限 |
| P7 | **向后兼容**：`start(initialVelocity:)` 无边界路径与改造前**逐帧相同** | 既有 `DecelerationAnimator`/`DecelerationModel` 全测不改即过 |

**边界表示**：公共面用 `ClosedRange<CGFloat>`（几何保证 `min≤max`，单点 range 合法 = 无滚动空间）。模型内对**非有限端点**防御（P6）；`min==max` 退化 = 任意越界都回弹至该单点（合法）。

---

## 五、错误处理 / 边界情形

- **非有限输入**（velocity/offset/bounds 端点 NaN/inf）：mirror `DecelerationModel` 既有 defense（`isFinite` 守门）→ `.stop`，不建弹簧、不外溢非有限 delta（P6）。
- **起点已越界**（wiring 后：用户拖过边松手）：直接进弹簧相，seed `overscroll=offset-edge`、`velocity=initialVelocity`。
- **起点界内、速度不足达边**：纯减速自然停，无弹簧（P4）——`EdgeBounceModel` 自然 subsume 无 bounce 情形。
- **后台恢复 / 异常大 dt**：沿用 `DecelerationModel.advance` 的 `dt≥1.0` 直接停 guard（弹簧相同样守 dt 合法）。
- **重复 start / stop**：复用既有 generation 自增 + driver 失活；`stop()`/`resetOnSceneActive()` 静默不触发 `onFinish`（既有语义不变）。

---

## 六、测试策略（全确定性、host 可跑、零运行时依赖）

- **`EdgeBounceModelTests`**：P1-P6 逐条 + 复用注入 fake dt 序列（确定性）。关键 killer：
  - settle 后 `offset` **精确** == edge（非近似）；
  - ζ=1 下 overscroll 符号不翻转（P2 无穿越）；ζ<1（若暴露）下允许一次过冲做对照（证 ζ 真生效）；
  - 同初值不同 dt 切分末态一致（P3，容差对比，**非整除浮点用容差**，per `feedback_swift_local_toolchain_blindspot`）；
  - 界内不足达边 → 与 `DecelerationModel` 同参逐帧相等（P4）；
  - mutation-style demonstrator：穿透峰值**非零**（避免空洞 demonstrator，per `feedback`：正向 FP demonstrator 须实测非零）。
- **`DecelerationAnimator` bounce 测试**：注入 fake `FrameDriving` + fake dt（复用既有 DD-1/DD-5 缝）；验证 bounce 路径外溢的 delta 序列累加后 offset 落 edge、`onFinish` 恰一次、generation/stale 与既有同守；**既有 `DecelerationAnimatorTests` 不改全过**（P7 回归门）。
- **基线**：worktree 起点 `swift test` = **799 tests / 120 suites / 0 fail**（已实测 2026-06-11）。

---

## 七、Residual / runtime runbook / 隔离证明

### Residual `W3-11-R1`（live 可见 bounce wiring）
折入**顺位 3 Pinch** 或 3 merged 后 fast-follow：makeViewport overscroll 渲染 + endPan/ChartContainerView 喂真实几何边界 + 拖拽期橡皮筋 + bounce device/sim 运行时 runbook 实测。**Wave 3 收尾（顺位 13）的运行时矩阵 bounce 行依赖此 residual 完成，本 PR 不 claim bounce 可见/已运行时验证。**

### Runtime runbook 处置（诚实，预挡 codex「缺 runbook」）
outline §三.3 要求每新交互锚交付 runtime runbook 条目。**本 PR 组件无可见运行时**（未接线 → 真 app 看不到回弹），故 bounce 的 device/sim runbook **不可执行**、显式随 `W3-11-R1` deferred。本 PR 的验证 = §六确定性单测（物理正确性在此完全闭合）。验收文档须逐字记此 deferral，非遗漏。

### 隔离证明（构造式，回答 outline「plan 须先证隔离」）
1. **组件零几何**：`EdgeBounceModel`/动画器 bounce 路径只收**边界值**（`ClosedRange<CGFloat>`），从不计算 `candleStep`/`visibleCount`/viewport → 顺位 3 改几何不触碰本组件。
2. **零 engine 契约改动**：不加 public engine API、不改 `TrainingEngine`/`Reducer`/`RenderStateBuilder`；既有 `start(initialVelocity:)` 行为不变 → 与并行 6a engine 契约工作 disjoint。
3. **公共/行为面 additive**：新文件 + 动画器新增启动面；既有 `start(initialVelocity:)` 行为 byte-for-byte 不变、live 调用面（endPan）不改（内部 `model`→`runModel` 重构为私有消重，P7 回归门守）→ 零回归风险。
∴ 本 PR 与并行轨（6a engine / 未来 3 Pinch）文件 + 语义均 disjoint，真并行安全。

---

## 八、验收要点（占位，详表归 plan + acceptance doc）
- 全 grep gate：diff 不含 `RenderStateBuilder`/`TrainingEngine`/`ChartContainerView`/`Reducer` 改动（§二范围判据）。
- `swift test` 绿且 ≥ 799 + 新增 bounce 测试数；既有减速/动画器测试零改动通过（P7）。
- Catalyst build-for-testing required check 通过（编译 + 链接；无运行时）。
- 验收文档逐字记 `W3-11-R1` deferral + runbook deferral（§七诚实条款）。

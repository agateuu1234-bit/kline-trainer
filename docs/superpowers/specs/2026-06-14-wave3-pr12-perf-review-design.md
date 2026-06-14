# Wave 3 顺位 12 设计：性能评审 + Bitmap Cache 按需

**日期**：2026-06-14
**Anchor**：Wave 3 顺位 12（D 磨光组）
**类型**：性能评审 artifact + 帧预算验收判据 + Bitmap Cache 条件引入决议（docs + test-only，**0 生产代码改动**）
**依赖（Wave 3 上游）**：全渲染锚 3 Pinch（#98）/ 4 Drawing（#103）/ 5 Crosshair（#101）/ 11 Bounce（#96）—— **均已 merged**，依赖满足（outline §canonical DAG L91 `12 性能 ← 全渲染锚(3,4,5,11)`）。
**下游**：顺位 13 收尾 **阻塞依赖** = 本锚交付的帧预算判据 + C2/C7/C8 既有运行时实测的 device/sim 记录回填（outline residual L214）。

---

## 〇、一句话

把渲染热路径做一次**静态性能评审**、把「单帧 <4ms @ 120Hz」**钉成权威验收判据 + 可执行 runbook**、把 Bitmap Cache 的**条件引入决议 + 设计草图**写死（按需、当前 no-op），并加一条 **host 级 CI 回归绊线测试**——全程 **0 生产代码改动**。

---

## 一、背景与权威 spec 依据

### 1.1 渲染路径现状（grep + 代码核实，2026-06-14）

| 环节 | 文件 | 性质 |
|---|---|---|
| `buildRenderState` | `RenderStateBuilder.make(engine:panel:bounds:crosshair:)`（`Render/RenderStateBuilder.swift:18-43`） | 平台无关纯函数，host 全量可测；切片 + 装配 `KLineRenderState` |
| 视口几何 | `RenderStateBuilder.makeViewport`（同上 `:58-93`） | 纯函数；`partitioningIndex` O(log n) + 切片 O(visibleCount) |
| `draw` 派发 | `KLineView.draw(_:)`（`Render/KLineView.swift:33-60`） | UIKit-only；建 3 个 mapper + 派发 8 个 `drawXxx` |
| 8 绘制 pass | `KLineView+Candles/MACD/Crosshair.swift` 等 | UIKit-only；Core Graphics 描边/填充 |
| 重绘触发 | `KLineView.renderState.didSet`（`KLineView.swift:16-21`） | **Equatable 短路**：`renderState != oldValue` 才 `setNeedsDisplay()` |
| 重建触发 | `ChartContainerView.updateUIView`（`Render/ChartContainerView.swift:34-41`） | 每次 SwiftUI `@Bindable engine` 状态变更重建 renderState；长按十字光标走 `Coordinator.setCrosshair` 视图层旁路重建 |
| 帧驱动 | `DecelerationAnimator` + `RealFrameDriver`（`ChartEngine/DecelerationAnimator.swift`） | UIKit: `CADisplayLink`（原生 Hz，未设 `preferredFramesPerSecond`）；macOS: `Timer(1.0/120.0)`。每帧 1 个 `onUpdate(delta)`，**animator 内不调 `make()`** |

**关键不变量（modules v1.4 L1471 验收）**：相同 engine 状态重复 `updateUIView` 经 Equatable 短路**不触发 `draw`**。此短路是 Phase 1 纯 draw 策略的性能基石——它由 `KLineRenderState: Equatable` 保证。

### 1.2 权威 spec 判据（逐字引用）

- **plan v1.5 L18**：「K 线渲染｜Core Graphics 自绘引擎（Phase 1 纯 `draw(_:)`，单帧 >4ms 时引入 Bitmap Cache）｜… Bitmap Cache 非默认，按性能实测按需引入」
- **plan v1.5 L31**：「**Phase 1 策略：纯 `draw(_:)` 无 Bitmap 缓存，每帧完整重绘。** 可见蜡烛约 93 根，总计约 600-700 次 Core Graphics 调用/帧，A17 Pro 在 120Hz 下无压力（瓶颈线 > 5000 次）。**性能门槛：当 Instruments 测量单帧绘制超过 4ms 时，引入 Bitmap Cache 优化。**」
- **plan v1.5 L1233**：「性能优化（Instruments Profiler，单帧 >4ms 时引入 Bitmap Cache）」
- **plan v1.5 L1264**：「渲染性能｜Instruments 验证 120Hz 无卡顿，Phase 1 纯 draw 单帧 <4ms」
- **modules v1.4 L1471**：「验收：Instruments 120Hz 单帧 <4ms；Equatable 短路生效（相同 engine 状态重复 updateUIView 不触发 draw）」
- **modules v1.4 L2554**：「Phase 5 磨光前做一次**性能评审**｜**建议**｜用 Instruments 数据对照 v1.5 §一"单帧 <4ms" 目标，由 Codex 审视性能热点」
- **outline L67**：「性能评审 + Bitmap Cache 按需（Instruments 性能 pass；Bitmap Cache **仅当实测单帧 >4ms 才引入**；交付帧预算验收判据）」
- **outline L173**：「Bitmap Cache 为**条件性**引入（仅当 Instruments 实测单帧 >4ms），plan 阶段若实测达标则该子项 no-op，仅交付性能评审 artifact」

### 1.3 既有性能 scaffolding（核实：几乎为空）

- `Render/RenderStateBuilderTests.swift:246-259`：唯一既有 smoke，覆盖 `makeViewport()`（**非**完整 `make()`），用 `Date()` 测 5000 根 × 100 次，`#expect(ms < 50)` 极宽松，自标注「non-authoritative; not the spec frame budget」。
- `docs/runbooks/2026-06-07-c8b-runtime-acceptance.md:13`（item #3）：既有帧预算 runbook 步骤——「Instruments Time Profiler / Core Animation 录制滚动 + 减速｜`KLineView.draw(_:)` 单帧 < 4ms（120Hz 预算，spec L1467）；记录实测峰值 ms｜pass = 峰值单帧 < 4ms（填实测值：____ ms）」——**值 pending**，user device 回填职责。
- 无 `os_signpost` / `XCTest.measure` / Instruments 自动化 / CI 帧预算 gate。

### 1.4 核心约束：门控测量在 CI 内不可运行

「单帧 >4ms 才引入 Bitmap Cache」的**门控测量是 Instruments device/simulator 实测**——CLI/CI 只编译 UIKit、不运行（c8b runbook 性质注 L3）。故：
1. **本锚（Claude/CI）无法产出 >4ms 这个触发条件**——它是 user device 职责（同全 Wave 3 运行时矩阵）。
2. 因此 **Bitmap Cache 在本锚不实现**：条件门未触发 + 投机实现违反 spec「非默认/按需」+ 违反 YAGNI + 给 A17 Pro 据 spec 无压力的路径注入真实渲染风险。

这是本设计的中心结论，下文所有 scope 决策由它派生。

---

## 二、方案选择

| 方案 | 内容 | 取舍 |
|---|---|---|
| **A 纯文档** | 静态评审 + 权威判据 runbook + Bitmap Cache 决议；0 代码 | 忠实，但 CI 无回归保护 |
| **B 文档 + host 回归绊线（选定）** | A 全部 + **test-only**：把既有 smoke 从 `makeViewport()` 扩到完整 `make()`，宽松上界，CI 可跑 | 忠实 + 加一条廉价 CI 绊线 + 沿用既有 smoke 模式 + 0 行为改动 |
| **C 现在就建 Bitmap Cache** | 实现 5 静态层离屏 bitmap 缓存 | **驳回**：违 spec 条件门（无 >4ms 实测）+ 违 YAGNI + 为 spec 称无压力的问题注入渲染风险 |

**选定 B**。理由：在「忠实于 spec 条件门」与「留下 CI 可见的回归保护」之间取平衡；唯一代码是 test-only、沿用既有 smoke 既定模式、对生产 0 触碰、与并行轨（9 夜间 / 10b 持久化）文件零冲突。

---

## 三、交付物（5 节）

### 3.1 性能评审 artifact（doc：`docs/governance/2026-06-14-wave3-pr12-performance-review.md`）

落实 modules L2554「由 Codex 审视性能热点」的**静态**评审（device 实测归 runbook）。内容：

1. **热路径结构**：`make()`（纯，host）vs `draw()`（UIKit，8 pass）拆分；每帧工作量来源。
2. **每帧 CG 调用量级账**（代码核实，对照 plan L31 的 600-700 估算）：
   - `drawCandles`（`KLineView+Candles.swift:13-27`）：per-candle 1 `strokePath`（影线）+ 1 `fill`（实体）+ `setFill`/`setStroke` 颜色态；visibleCount 默认 80（`RenderStateBuilder.defaultVisibleCount=80`，非 plan 文案的 93）→ ~80×(2 path + 2 color) ≈ 320 ops。
   - `drawMA66`（`:30-44`）：1 条折线 stroke（~80 `addLine`）。
   - `drawBOLL`（`:47-67`）：3 轨虚线 stroke（~3×80 `addLine`）+ `setLineDash`。
   - `drawVolume` / `drawMACD`：~80 rect + diff/dea 折线 + ~80 histogram bar。
   - 合计量级与 plan L31「600-700 次/帧」**同阶**；远低于「瓶颈线 >5000」。**精确 device 单帧 ms 归 runbook（§3.2）**——静态评审不 claim 实测值。
3. **可识别热点（静态，供 Codex/opus 审）**：
   - **每帧分配**：`MainChartLayout.candleShapes/ma66Polyline/bollPolylines` 每帧新建数组（`make()` 侧 `slice.map`/`flatMap` 同理）。GC/ARC 压力来源候选；当前规模下据 plan 无压力，记录为「若 device 实测逼近预算，首查点」。
   - **per-candle 颜色态**：`drawCandles` 循环内 `color.setFill()/setStroke()` 每根设色（涨跌分组批绘是潜在优化，**仅当实测 >4ms 才值得**）。
   - **Equatable 短路依赖**：`KLineRenderState` 含 `visibleCandles: ArraySlice` 等大字段，短路靠值相等比较；评审确认短路语义正确（相同 engine 状态不重绘，modules L1471），并记录「短路本身的比较成本」为已接受。
4. **结论**：Phase 1 纯 draw 策略在 spec 规模假设下达标；**是否真达标的裁决权属 §3.2 device 实测**；本静态评审不放行也不否决帧预算，只交付热点清单 + 量级账 + 条件门。

### 3.2 帧预算验收判据（doc + runbook）

**权威判据（本锚 own）**：单帧 `buildRenderState(make) + draw(_:)` < 4ms @ 120Hz，在具名 device/sim profile 上经 Instruments Time Profiler / Core Animation 实测。

- 在性能评审 doc 内**复述并 own** 该判据（含 pass/fail 定义 + Bitmap Cache 决议门，见 §3.3）。
- **runbook 步骤**：新增 `docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md`，给出非编码者可执行的 Instruments 测量流程 + 回填栏（峰值单帧 ms / device 型号 / 触发场景：滚动+减速+pinch+绘线+十字光标）。**引用而不修改** c8b runbook item #3（保历史 + 避免与既有 PR 文件冲突）；新 runbook 作为顺位 12 自有、覆盖 Wave 3 新交互（pinch/绘线/HUD）的帧预算条目。
- **明示**：实测数值是 **user device 职责** + **顺位 13 收尾阻塞依赖**；本锚交付判据 + 流程，不交付数值。

### 3.3 Bitmap Cache 条件引入决议 + 设计草图（doc，**不编码**）

**决议门**：
- **实测峰值单帧 < 4ms** → Phase 1 纯 draw 充分，Bitmap Cache **不引入**，本子项 no-op（outline L173 字面）。
- **实测峰值单帧 ≥ 4ms** → 按下方设计草图引入 Bitmap Cache（**独立后续 anchor / track**，非本锚），引入后须重测回落 <4ms。

**设计草图（备而不用，使未来 >4ms 实测有现成方案，避免届时现编）**：
- **缓存对象**：5 个视口静态层 `Candles / MA66 / BOLL / Volume / MACD`（数据 immutable，位置 = f(viewport)）渲染到离屏 `CGLayer`/bitmap。
- **失效触发**：可见 candle 切片变化（新 tick / pan 跨 candle 边界）、geometry 缩放变化（pinch）、drawing/marker 增删。
- **合成**：缓存 blit 后，**动态层逐帧叠加**——`Crosshair`（`renderState.crosshairPoint` 每帧变）必须在缓存之上重绘；`Markers`/`Drawings`（viewport-dependent、非逐帧）随缓存一并失效重建。
- **风险记录**：缓存引入 displayScale/亚像素对齐 + 失效正确性 + 内存占用三类新风险，故 spec 才设「仅 >4ms 才引入」门——不达门不付此风险。

### 3.4 host 性能回归绊线（test-only，唯一代码）

- 在 `Render/RenderStateBuilderTests.swift` 扩既有 smoke：新增覆盖**完整 `make()`**（真 buildRenderState，非仅 `makeViewport()`）的 host smoke。
- 性质：**非权威**（host 无 CoreGraphics draw，不是 spec 帧预算）；宽松上界仅防病态退化（量级同既有 `#expect(ms < 50)`）；`print` 记录单次装配 ms。
- 价值：CI 可跑的回归绊线——若未来某改动让 `make()` 装配退化到病态，host 测试即报，无需等 device。
- **不**伪称帧预算 gate（draw 侧帧预算唯一权威 = §3.2 device runbook）。

### 3.5 验收清单（Chinese，非编码者可执行；governance backstop #2）

`docs/acceptance/2026-06-14-wave3-pr12-perf-review.md`，action/expected/pass-fail 三列，覆盖：评审 doc 存在性 + 量级账与代码一致 + 帧预算 runbook 可执行性 + Bitmap Cache 决议门表述 + host smoke 通过 + grep 断言无遗留占位。

---

## 四、Scope 边界

**In scope**：§3.1-§3.5 五交付物。文件触碰仅 `docs/**` + `RenderStateBuilderTests.swift`。

**Out of scope（显式排除）**：
- 实际 Instruments device 实测数值（user / 顺位 13 阻塞）。
- 任何 Bitmap Cache **生产代码**（条件门未触发）。
- 任何生产渲染路径改动（`RenderStateBuilder` / `KLineView*` / `MainChartLayout` 等一行不改——本锚是「评审」非「优化」；优化只在实测 >4ms 时按 §3.3 走独立 anchor）。
- C2/C7/C8 既有运行时实测的**数值回填**（顺位 13 收尾职责；本锚只交付判据）。
- 修改 c8b 既有 runbook（引用不改，避免跨 PR 冲突）。

---

## 五、测试策略

- **唯一新测试**：§3.4 host smoke 扩 `make()`。在 worktree `swift test`（macOS host）全绿 + Mac Catalyst build-for-testing 编译绿（required check）。
- 无生产代码改动 → 无新行为需 TDD；本锚以「评审 artifact + 判据 + 决议 + 绊线测试 + 验收清单」为成功标准（弱→强：见 §六验收判据）。
- 既有 261+ 测试零回归（docs + test-only PR，先证 baseline 绿再加测试）。

---

## 六、成功判据（goal-driven）

1. 性能评审 doc 落地，量级账与 `KLineView+*.swift` 实代码一致（可被 reviewer 核） → verify：grep 引用行号 + 人读对照。
2. 帧预算 runbook 非编码者可执行、判据 + 决议门表述无歧义 → verify：runbook 自检三列完整 + grep forbidden phrases。
3. Bitmap Cache 决议门 + 设计草图写死，明示当前 no-op → verify：决议门双分支均在 doc。
4. host smoke 扩 `make()` 后 `swift test` 全绿 + Catalyst 编译绿 → verify：测试输出。
5. 0 生产代码改动 → verify：`git diff --stat` 仅 `docs/**` + `RenderStateBuilderTests.swift`。

---

## 七、给对抗性 reviewer 的假设清单（须挑战）

1. **Bitmap Cache 不编码**是否正确？依据：条件门测量 CI 不可运行 + spec「非默认/按需」+ YAGNI。reviewer 若认为应建，须给出「如何在不实测 >4ms 下满足 spec 条件门」的论证。
2. **B（含 host 绊线测试）vs A（纯文档）**：扩 smoke 到 `make()` 是否过度？依据：廉价、沿用既有模式、CI 回归价值。
3. **量级账精度**：静态评审给「量级账」（~600-700 同阶）而非精确单帧 ms 是否足够？依据：精确 ms 是 device runbook 唯一权威，静态侧不可能产出。
4. **新建 runbook vs 改 c8b #3**：是否应改既有 runbook 而非新建？依据：避免跨 PR 文件冲突 + c8b 保历史。
5. **「评审非优化」边界**：本锚 0 生产改动是否使其「太薄」？依据：spec（outline L173 + modules L2554「建议」）正是此 scope；precedent PR #50（0 prod + tests + acceptance）。
6. **顺位 13 边界**：本锚交付判据、顺位 13 回填数值——这条分工是否清晰、有无遗漏本锚应 own 的部分。

# Wave 3 13c-R1 设计：渲染热路径 `os_signpost` 帧相关 instrumentation

**日期**：2026-06-16
**Anchor**：Wave 3 13c-R1 fast-follow（perf-instrumentation；从 PR #110 / #112 留下的 OPEN residual）
**类型**：生产代码 instrumentation（`os_signpost`）+ runbook 重写 + residual 账本 flip
**依赖（已 merged，origin/main c7feea8）**：顺位 12 性能评审 #104（判据：单帧 `make+draw` < 4ms）/ 顺位 13c #110 #112（13c-R1/R2 residual 来源）/ reveal #113 #115（`makeViewport` 已改，但本 PR 不触其内部）

---

## 〇、一句话

给渲染热路径的 `make`（视口/状态装配）与 `draw`（Core Graphics 自绘）加 **`os_signpost` 区间**（按 **panel × op** 打标），使 Instruments 能把**上/下两个图表实例各自的 make/draw 关联到同一 display frame、取最坏完整帧的真实合并耗时**——根治 13c-R1「采样≠帧相关」，替换帧预算 runbook 里「两峰值保守相加」这个**指示性上界**近似。**设备实测数值仍是 runtime-matrix ③ 的 device 职责，本 PR 不产出（CI 不能跑 Instruments）。**

---

## 一、背景与问题（13c-R1 / codex R8-H1）

帧预算权威判据（顺位 12，modules v1.4 L1471）：**单帧 `RenderStateBuilder.make` + `KLineView.draw(_:)` 合并 < 4ms @ 120Hz**。

现行 runbook（`docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md`）用 **Time Profiler** 分别过滤 `make` / `draw` 符号、各取峰值、**保守相加**。codex R8-H1 指出这**不等于**同一显示帧的真实合并耗时：

1. **采样 ≠ 区间**：Time Profiler 是统计**采样器**，符号峰值是采样估计，非精确区间耗时。
2. **make 与 draw 跨调用分离**：`make` 在 `ChartContainerView.updateUIView`（SwiftUI 更新阶段）跑，写 `view.renderState` → `didSet` → `setNeedsDisplay()` → `draw` 在随后的 Core Animation 提交阶段跑。两者不同调用、可能不同 runloop turn。
3. **一帧含 4 次未配对调用**：屏上有 **上/下两个 `KLineView` 实例**（`TrainingView` 的 `VStack { panel(.upper); panel(.lower) }`），各自一对 make/draw。一个 display frame 的主线程工作 = `make_upper + make_lower + draw_upper + draw_lower`。「峰值相加」取的是**跨帧**的 make 峰值与 draw 峰值，既可能高估（两峰值不在同帧）也可能漏算（只数一个实例）。

**严谨的单帧合并测量**需把每个 上/下 make/draw 关联到 display frame、对落在同一帧的全部区间求和、取最坏完整帧。这正是 `os_signpost` 区间（interval）的用途：区间携带精确 begin/end 时间戳，在 Instruments 时间轴上与 Core Animation 帧边界对齐即可按帧归并。

---

## 二、目标与 scope（**诚实边界**）

13c-R1 有两个**facet**，本 PR 只关其一：

| Facet | 内容 | 本 PR |
|---|---|---|
| (a) **机制缺口** | 「不存在帧相关的精确测量机制；只有峰值相加近似」 | **RESOLVED** — 交付 `os_signpost` 区间 instrumentation + 重写 runbook |
| (b) **device 实测** | 「用该机制在 Release device 上实测最坏帧 make+draw 是否 < 4ms」 | **不变** — 仍是既有 runtime-matrix 合取项 ③ 的 device-pending 职责；本 PR **不**产出数值、**不**新增 residual，只是让 ③ 现在有了严谨方法 |

> **本 PR 不 claim「帧预算达标」。** 它 claim 的是：测量机制从「指示性上界近似」升级为「帧相关精确区间」。是否 <4ms 仍待 device 回填（runtime-matrix ③）。

**In scope**：
1. 新增 `RenderSignposter`（平台无关，`os` 框架）—— make/draw 区间 + panel×op 打标的唯一封装。
2. 三处调用点接线：`updateUIView` 的 make、`Coordinator.setCrosshair` 的 make、`KLineView.draw(_:)` 的 draw。
3. `KLineView` 加 `panel: PanelId`（draw 区间按 上/下 归属所需）。
4. host 单测（命名契约 + 调用 smoke）。
5. 重写帧预算 runbook 的测量流程（signpost 帧归并法，替换峰值相加）。
6. 账本 flip：completion doc + runtime-matrix caveat 把 13c-R1 标 **RESOLVED（机制 facet）**，并明示 device facet 仍 pending。

**Out of scope（显式排除）**：
- device 实测数值（CI 不能跑 Instruments；user/runtime-matrix ③ 职责）。
- 任何 Bitmap Cache（条件门未触发，顺位 12 决议）。
- 任何渲染**行为/几何**改动（`RenderStateBuilder.make` 内部数学、`makeViewport`、8 个 `drawXxx` 一行不改——本 PR 只在调用**边界**加区间，不改渲染结果）。
- 改 #112 / 13c-R2 的**历史** acceptance 清单（point-in-time 记录，不回改）。
- 新增 CI 帧预算 gate（帧预算本质 device-only，c8b runbook 性质注 + 顺位 12 §1.4）。

---

## 三、方案选择（D1 = 帧相关策略，本设计中心）

| 方案 | 内容 | 取舍 |
|---|---|---|
| **A 纯 signpost 区间（选定）** | 单个共享 `OSSignposter`（subsystem `com.klinetrainer.render`，category `.pointsOfInterest`）；make/draw 各包一对 `beginInterval/endInterval`，按 panel×op 打 `%{public}` 标。**不**新增任何帧驱动。runbook：用 os_signpost instrument + Core Animation 帧轴，把落在同一帧的区间求和、取最坏完整帧。 | 区间=真实耗时（非采样）；panel×op 标使 4 个贡献全可见可配对；零新增运行时对象、零测量扰动；Apple 推荐用法 |
| **B signpost 区间 + 专用 CADisplayLink 帧标记** | A + 额外一条**常驻 CADisplayLink** 每 vsync 发帧边界 signpost，使「最坏完整帧」可显式分组 | **驳回**：常驻 CADisplayLink 在 **Release** 每帧跑 → 耗电 + 主线程开销 + **自身扰动被测对象**（instrumentation 改变它要测的时序）+ 多一个生命周期对象。帧边界 Instruments 已由 Core Animation 轨提供，收益边际 |
| **C app 内逐帧聚合** | 维护 per-vsync 累加器，app 内算 make+draw 合并并 log 最坏帧 | **驳回**：在 app 内重造 Instruments 的工作；常驻主线程记账 + 自身 bug 面；违 YAGNI + 非侵入原则 |

**选定 A**。理由：`os_signpost` 区间是 Apple 为「精确、低开销、可在 Release 录制」设计的机制；未录制时近零成本（正是判据要求的 Release 包可测）。帧边界由 Instruments 的 Core Animation/Points-of-Interest 时间轴提供，无需自造帧驱动去扰动测量。A 直接消解 R8-H1 的三条：(1) 区间是真实 elapsed（非采样）；(2) make/draw 各自成区间，时序分离被如实呈现；(3) panel×op 标让上/下 4 个调用都可见、可按帧求和。

---

## 四、设计决策

- **D1（帧相关策略）**：方案 A（见 §三）。
- **D2（API）**：`OSSignposter`（`import os`，macOS 12+/iOS 15+；Package 最低 macOS14/iOS17 ≥ 之，无需 per-decl `@available`）。优先于 C 风格 `os_signpost`（旧持久化层用的是 `OSLog`+`os.log`；signpost 区间用现代 `OSSignposter` 更安全：`beginInterval` 返回 `OSSignpostIntervalState`，强制 begin/end 配对）。
- **D3（build 门控）**：**不 `#if DEBUG`**。帧预算判据要求 **Release（优化）包** 实测（Debug 未优化虚高耗时不可用作 <4ms 判据，见 runbook 前置）；故 instrumentation **必须编进 Release**。`os_signpost` 未被 Instruments 录制时近零成本（无 if-debug、无 env 门控）。**这是对本仓「fixture 一律 #if DEBUG」纪律的有意例外，理由 = 被测对象就是 Release 包**——本设计将此显式写明供 reviewer 挑战。
- **D4（放置）**：包在 **UIKit 调用边界**，不进平台无关纯函数。
  - make：`ChartContainerView.updateUIView`（L38）+ `Coordinator.setCrosshair`（L122）——两处都在 `#if canImport(UIKit)` 内。
  - draw：`KLineView.draw(_:)`（L55）函数体。
  - **`RenderStateBuilder.make` 纯函数体一行不改**（保持平台无关、host 纯可测）。
- **D5（panel 归属）**：`KLineView` 加 `public var panel: PanelId = .upper`，由 `Coordinator.sync(panel:engine:view:)`（每次 updateUIView 调）赋值（attach 时亦设初值）。make 两处调用点本就持 `panel`。`PanelViewState` 无 上/下 字段（只有 `period`），故 draw 侧必须由 view 自带 panel 才能按「上/下」归属——R8-H1 明文要求「每个**上/下** make/draw」，panel 标是根治的一部分，非可选。
- **D6（封装类型）**：新增 `Render/RenderSignposter.swift`（平台无关，无 `#if canImport(UIKit)` 守卫——`os` 跨平台，host 可编可测）。
  - 持单个共享 `OSSignposter`（static `shared`）。
  - 暴露**稳定标识常量**：`subsystem`、interval 名 `make`/`draw`、panel 标值 `upper`/`lower`——runbook 据此 grep/操作，构成 **code↔runbook 契约**。
  - 方法：`beginMake(panel:) -> OSSignpostIntervalState` / `endMake(_:)`、`beginDraw(panel:) -> OSSignpostIntervalState` / `endDraw(_:)`（每区间用 `makeSignpostID()` 取新 id；返回 state 传回 end，强制配对）。
- **D7（draw 早返保护）**：`draw(_:)` 有 `guard let ctx … else { return }`。`beginDraw` 置于 guard **之前**，用 `defer { endDraw(state) }` 保证早返路径也闭合区间（否则空 ctx 帧留下未配对 begin，污染 Instruments）。
- **D8（测试）**：见 §六。host 命名契约测 + 调用 smoke。signpost 发射本身**无可观测产物**（Instruments-only），如实记录「不可单测」，不伪造行为断言。
- **D9（账本 flip 范围）**：见 §五。只 flip 机制 facet；device facet 明示仍 pending；不破 `verify-wave3-completion.sh`（其机器块无 13c-R1 key，只要保留帧预算 runbook 指针 + 不动 WAVE3-STATUS keys + runtime-matrix 仍 PARTIAL）。不回改 #112/13c-R2 历史清单。

---

## 五、交付物

### 5.1 `Render/RenderSignposter.swift`（新，唯一新生产文件）
平台无关。`OSSignposter` 封装 + 稳定常量 + begin/end make/draw。~40-60 行。

### 5.2 三处调用点接线（改 2 文件）
- `ChartContainerView.swift`：`updateUIView` make 包区间；`Coordinator.setCrosshair` make 包区间；`Coordinator.sync`/`attach` 设 `view.panel`。
- `KLineView.swift`：`draw(_:)` 包区间（begin 前置 + defer end）；加 `var panel: PanelId`。

### 5.3 帧预算 runbook 重写（改 1 文件）
`docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md`：
- 前置：Profile 模板从「Time Profiler 过滤符号」改「**os_signpost** instrument（+ Core Animation 帧轴）」，录制目标 = `com.klinetrainer.render` subsystem 的 make/draw 区间。
- 各场景测量法：从「分别过滤 make/draw 取峰值**相加**」改「**找最坏完整帧**：在该帧 vsync 窗口内对全部 make/draw 区间（上+下）**求和**，作合并耗时」。
- 回填栏：记录所测周期 + 该帧蜡烛数 + 最坏帧的 make_upper/make_lower/draw_upper/draw_lower 明细 + 合并。
- 保留 Bitmap Cache 决议门、L1471 判据、文件名（`verify-wave3-completion.sh` 谓词 3c 依赖该文件名指针）。

### 5.4 账本 flip（改 2 文件）
- `docs/acceptance/2026-06-14-wave3-pr13c-completion.md`：13c-R1 residual 行 → **RESOLVED（机制 facet，2026-06-16 本 PR）**，附「device 实测仍 runtime-matrix ③ pending」。
- `docs/governance/2026-06-14-wave3-completion.md`：运行时矩阵行 caveat ① 标 13c-R1 机制 RESOLVED + device pending。**不动** WAVE3-STATUS 机器块（无 13c-R1 key；runtime-matrix 仍 PARTIAL）。

### 5.5 本 PR 验收清单（中文，非编码者可执行；governance backstop #2）
`docs/acceptance/2026-06-16-wave3-13c-r1-signpost.md`：action/expected/pass-fail 三列。覆盖 RenderSignposter 存在性 + 三调用点接线 grep + host 测试通过 + runbook 已改为 signpost 帧归并法 + 账本 flip 正确（机制 RESOLVED + device pending 双陈述）+ 无 forbidden phrases。

---

## 六、测试策略

无渲染**行为**改动（区间只包边界，不改输出）→ 既有 1064 测试零回归是首要判据。

新测试 `Render/RenderSignposterTests.swift`（host）：
1. **命名契约**：`RenderSignposter.subsystem == "com.klinetrainer.render"`、interval 名常量 == `"make"`/`"draw"`、`label(for: .upper) == "upper"` / `.lower == "lower"`。**理由非 vacuous**：这些字符串是 runbook（人类分析师在 Instruments 里 grep/筛选）消费的公开契约；pin 它们防止改名静默破坏 runbook（正是 codex 关心的 honesty/drift）。
2. **调用 smoke**：`shared` 上 `beginMake/endMake/beginDraw/endDraw` 对 `.upper`/`.lower` 各跑一遍——断言不崩。signpost 在未录制时是 no-op，host 安全。

**诚实声明（写进 spec + 验收）**：signpost 的实际发射/帧归并**只能** Instruments 验证，host/CI 不可断言其产物；本 PR 不伪造「帧预算 gate」。draw 行为不变由「8 个 drawXxx 一行不改 + 区间只在函数体首尾」+ 既有渲染测试零回归保证。

验证门：worktree `swift test`（macOS host）全绿 + Mac Catalyst build-for-testing 编译绿（required check）。

---

## 七、风险与诚实 caveat

1. **Release 含 instrumentation**（D3）：有意例外于 #if DEBUG 纪律。缓解：`os_signpost` 未录制近零成本（Apple 框架自身在 Release 大量发 signpost）；subsystem 隔离，不污染日志。
2. **panel 默认 `.upper`**：首帧前若 sync 未跑则默认 upper。实际：makeUIView→attach→updateUIView(sync 设 panel + 设 renderState)→首 draw，panel 在首 draw 前已正确。低风险，记录。
3. **「最坏完整帧」仍需人工在 Instruments 判读**：A 不自动算最坏帧（B/C 才自动，但被驳回）。runbook 给出明确判读步骤；这是 device 手动验收的固有性质（同全 Wave 3 运行时矩阵）。
4. **device facet 仍 OPEN**：本 PR 不闭合「帧预算实测 <4ms」——如实记录于 runtime-matrix ③，避免 overclaim。

---

## 八、成功判据（goal-driven）

1. `RenderSignposter` 落地，三调用点接线（make×2 + draw×1）→ verify：grep + 人读。
2. `swift test` host 全绿（含新命名契约 + smoke）+ 既有 1064 零回归 + Catalyst 编译绿 → verify：测试输出。
3. runbook 测量法改为 signpost 帧归并（无「峰值相加」残留作为权威判据）→ verify：grep runbook。
4. 账本 13c-R1 机制 facet RESOLVED + device facet 明示 pending；`verify-wave3-completion.sh` 仍 PASS → verify：跑脚本。
5. 渲染**行为**零改动 → verify：`git diff` 仅触 RenderSignposter（新）+ 两调用点边界 + KLineView.panel + docs；8 个 drawXxx / RenderStateBuilder 数学零改。

---

## 九、给对抗性 reviewer 的假设清单（须挑战）

1. **D3 不 #if DEBUG** 是否正确？依据：帧预算测 Release 包 → instrumentation 必须在 Release；signpost 未录制近零成本。reviewer 若主张应门控，须说明「门控后如何在 Release 包测帧预算」。
2. **方案 A（不加帧驱动）** 是否足以「取最坏完整帧」？依据：Instruments Core Animation/PoI 帧轴 + 区间时间戳即可按帧归并；加 CADisplayLink 反而自扰动。reviewer 若主张需显式帧标记，须权衡 Release 常驻帧驱动的扰动/能耗代价。
3. **命名契约测试是否 vacuous**？依据：字符串是 runbook 消费的公开契约，pin 防 drift。reviewer 若认为无价值，须说明改名破坏 runbook 时何处会报。
4. **panel 加到 KLineView** 是否越界 scope？依据：R8-H1 要求「每个上/下」归属，`PanelViewState` 无上/下字段，draw 侧必须自带 panel。
5. **13c-R1 facet 拆分**（机制 RESOLVED / device pending）是否诚实、有无 overclaim？依据：CI 不能产 device 数值；机制与实测是两件事。
6. **不回改 #112/13c-R2 历史清单** 是否正确？依据：point-in-time 记录；本 PR 在 completion doc flip 当前态即可，历史快照不改写。
7. **draw 早返 defer**（D7）是否覆盖所有早返？依据：唯一早返是 `guard ctx`；begin 前置 + defer 覆盖。reviewer 须确认无其他早返路径。

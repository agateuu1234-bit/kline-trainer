# Wave 3 13c-R1 设计：渲染热路径 `os_signpost` 帧相关 instrumentation

**日期**：2026-06-16
**Anchor**：Wave 3 13c-R1 fast-follow（perf-instrumentation；从 PR #110 / #112 留下的 OPEN residual）
**类型**：生产代码 instrumentation（`os_signpost`）+ runbook 重写 + residual 账本 flip
**依赖（已 merged，origin/main c7feea8）**：顺位 12 性能评审 #104（判据：单帧 `make+draw` < 4ms）/ 顺位 13c #110 #112（13c-R1/R2 residual 来源）/ reveal #113 #115（`makeViewport` 已改，但本 PR 不触其内部）
**对抗性 review 收敛**：opus 4.8 adversarial review R1（0C/1H/3M/2L）→ R2 全修（见 §十 变更记录）

---

## 〇、一句话

给渲染热路径的 `make`（视口/状态装配）与 `draw`（Core Graphics 自绘）加 **`os_signpost` 区间**，区间名用 **per-panel × op 的 `StaticString`**（`make-upper`/`make-lower`/`draw-upper`/`draw-lower`，crosshair 旁路 make 另名 `make-crosshair-*`），使 Instruments 能把**上/下两个图表实例各自的 make/draw 关联到同一 display frame、取最坏完整帧的真实合并耗时**——根治 13c-R1「采样≠帧相关」，替换帧预算 runbook 里「两峰值保守相加」这个**指示性上界**近似。**设备实测数值仍是 runtime-matrix ③ 的 device 职责，本 PR 不产出（CI 不能跑 Instruments）。**

---

## 一、背景与问题（13c-R1 / codex R8-H1）

帧预算权威判据（顺位 12，modules v1.4 L1471）：**单帧 `RenderStateBuilder.make` + `KLineView.draw(_:)` 合并 < 4ms @ 120Hz**。

现行 runbook（`docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md`）用 **Time Profiler** 分别过滤 `make` / `draw` 符号、各取峰值、**保守相加**。codex R8-H1 指出这**不等于**同一显示帧的真实合并耗时：

1. **采样 ≠ 区间**：Time Profiler 是统计**采样器**，符号峰值是采样估计，非精确区间耗时。
2. **make 与 draw 跨调用分离**：`make` 在 `ChartContainerView.updateUIView`（SwiftUI 更新阶段）跑，写 `view.renderState` → `didSet` → `setNeedsDisplay()` → `draw` 在随后的 Core Animation 提交阶段跑。两者不同调用、可能不同 runloop turn。
3. **一帧含 4 次未配对调用**：屏上有 **上/下两个 `KLineView` 实例**（`TrainingView` 的 `VStack { panel(.upper); panel(.lower) }`），各自一对 make/draw。一个 display frame 的主线程工作 = `make_upper + make_lower + draw_upper + draw_lower`。「峰值相加」取的是**跨帧**的 make 峰值与 draw 峰值，既可能高估（两峰值不在同帧）也可能漏算（只数一个实例）。

> **crosshair 旁路 make（第 5 个可能贡献者）**：长按十字光标经 `Coordinator.setCrosshair` 触发一次视图层 make（不经 SwiftUI observation）。纯 crosshair 拖动时 engine 状态不变、`updateUIView` 通常不复触发，故同帧一般只有 crosshair make 而非两种 make 并存；但为消歧，本设计给它**独立区间名**（见 §四 D4），使分析师在「最坏 update-pass 帧」求和时能把 crosshair make 与 update-pass make 分开。

**严谨的单帧合并测量**需把每个 上/下 make/draw 关联到 display frame、对落在同一帧的同类区间求和、取最坏完整帧。这正是 `os_signpost` 区间（interval）的用途：区间携带精确 begin/end 时间戳，在 Instruments 时间轴上与 Core Animation 帧边界对齐即可按帧归并。

---

## 二、目标与 scope（**诚实边界**）

13c-R1 有两个 **facet**，本 PR 只关其一：

| Facet | 内容 | 本 PR |
|---|---|---|
| (a) **机制缺口** | 「不存在帧相关的精确测量机制；只有峰值相加近似」 | **交付（机制 facet 关闭）** — `os_signpost` 区间 instrumentation + 重写 runbook |
| (b) **device 实测** | 「用该机制在 Release device 上实测最坏帧 make+draw 是否 < 4ms」 | **仍 OPEN** — 既有 runtime-matrix 合取项 ③ 的 device-pending 职责；本 PR **不**产出数值、**不**新增 residual，只是让 ③ 现在有了严谨方法 |

> **本 PR 不 claim「帧预算达标」。** 它 claim 的是：测量机制从「指示性上界近似」升级为「帧相关精确区间」。是否 <4ms 仍待 device 回填（runtime-matrix ③）。
>
> **账本措辞纪律（adversarial R1-H/M2）**：13c-R1 是**部分**收敛（机制交付 / device 仍 OPEN），故账本**不**用裸 `RESOLVED` 动词（避免与 13c-R2 的无条件 RESOLVED 混读为「13c-R1 已关闭」）。统一用「**机制交付 2026-06-16 / device <4ms 仍 OPEN（runtime-matrix ③）**」。

**In scope**：
1. 新增 `RenderSignposter`（平台无关，`os` 框架）—— make/draw 区间 + per-panel×op StaticString 名的唯一封装。
2. 三处调用点接线：`updateUIView` 的 make、`Coordinator.setCrosshair` 的 crosshair-make、`KLineView.draw(_:)` 的 draw。
3. `KLineView` 加 `panel: PanelId`（draw 区间按 上/下 归属所需）。
4. host 单测（命名契约 + 调用 smoke）。
5. 重写帧预算 runbook 的测量流程（signpost 帧归并法，替换峰值相加）。
6. 账本 flip：completion / governance / runtime-matrix 三 doc，机制 facet 标「机制交付」+ device facet 明示仍 OPEN（措辞纪律见上）。

**Out of scope（显式排除）**：
- device 实测数值（CI 不能跑 Instruments；user/runtime-matrix ③ 职责）。
- 任何 Bitmap Cache（条件门未触发，顺位 12 决议）。
- 任何渲染**行为/几何**改动（`RenderStateBuilder.make` 内部数学、`makeViewport`、8 个 `drawXxx` 一行不改——本 PR 只在调用**边界**加区间，不改渲染结果）。
- 改 #112 / 13c-R2 的**历史** acceptance 清单（point-in-time 记录，不回改；见 §五 5.4 的 item-7 不变量保全策略）。
- 新增 CI 帧预算 gate（帧预算本质 device-only，c8b runbook 性质注 + 顺位 12 §1.4）。

---

## 三、方案选择（D1 = 帧相关策略，本设计中心）

| 方案 | 内容 | 取舍 |
|---|---|---|
| **A 纯 signpost 区间（选定）** | 单个共享 `OSSignposter`（subsystem `com.klinetrainer.render`，category `.pointsOfInterest`）；make/draw 各包一对 `beginInterval/endInterval`，**区间名 = per-panel×op 的 `StaticString`**（`make-upper`/`make-lower`/`draw-upper`/`draw-lower`/`make-crosshair-upper`/`make-crosshair-lower`）。**signpost 名是 StaticString → Instruments 恒可见，不依赖动态字符串参数（杜绝 `.private` 冗余）**。**不**新增任何帧驱动。runbook：用 os_signpost instrument + Core Animation 帧轴，把落在同一帧的同名区间按帧求和、取最坏完整帧。 | 区间=真实耗时（非采样）；名即贡献者，上/下×make/draw 4 个 update-pass 贡献全可见可配对、crosshair make 可分离；零新增运行时对象、零测量扰动；Apple 推荐用法 |
| **B signpost 区间 + 专用 CADisplayLink 帧标记** | A + 额外一条**常驻 CADisplayLink** 每 vsync 发帧边界 signpost，使「最坏完整帧」可显式分组 | **驳回**：常驻 CADisplayLink 在 **Release** 每帧跑 → 耗电 + 主线程开销 + **自身扰动被测对象**（instrumentation 改变它要测的时序）+ 多一个生命周期对象。帧边界 Instruments 已由 Core Animation 轨提供，收益边际 |
| **C app 内逐帧聚合** | 维护 per-vsync 累加器，app 内算 make+draw 合并并 log 最坏帧 | **驳回**：在 app 内重造 Instruments 的工作；常驻主线程记账 + 自身 bug 面；违 YAGNI + 非侵入原则 |

**选定 A**。理由：`os_signpost` 区间是 Apple 为「精确、低开销、可在 Release 录制」设计的机制；未录制时近零成本（正是判据要求的 Release 包可测）。帧边界由 Instruments 的 Core Animation/Points-of-Interest 时间轴提供，无需自造帧驱动去扰动测量。A 直接消解 R8-H1 的三条：(1) 区间是真实 elapsed（非采样）；(2) make/draw 各自成区间，时序分离被如实呈现；(3) per-panel×op 名让上/下 4 个调用都可见、可按帧求和、crosshair 可分离。

---

## 四、设计决策

- **D1（帧相关策略）**：方案 A（见 §三）。
- **D2（API + 命名）**：`OSSignposter`（`import os`，macOS 12+/iOS 15+；Package 最低 macOS14/iOS17 ≥ 之，无需 per-decl `@available`）。优先于 C 风格 `os_signpost`（旧持久化层用的是 `OSLog`+`os.log`；signpost 区间用现代 `OSSignposter` 更安全：`beginInterval` 返回 `OSSignpostIntervalState`，强制 begin/end 配对）。**区间名用 `StaticString`**——signpost 名在 Instruments 恒可见（StaticString 非动态值，无 `.private` 冗余问题），故 panel 归属编码进**名**而非动态参数。这是对 adversarial R1-M3（`%{public}` 不可 host-测）的根治：名是编译期常量、可 host 断言、且天然 public。
- **D3（build 门控）**：**不 `#if DEBUG`**。帧预算判据要求 **Release（优化）包** 实测（Debug 未优化虚高耗时不可用作 <4ms 判据，见 runbook 前置）；故 instrumentation **必须编进 Release**。`os_signpost` 未被 Instruments 录制时近零成本（无 if-debug、无 env 门控）。**这是对本仓「fixture 一律 #if DEBUG」纪律的有意例外，理由 = 被测对象就是 Release 包**——本设计将此显式写明供 reviewer 挑战。
- **D4（放置 + 区间边界）**：包在 **UIKit 调用边界**，不进平台无关纯函数。
  - make（update-pass）：`ChartContainerView.updateUIView`（L38）。**区间只界定 `RenderStateBuilder.make(...)` 求值**——`let t = beginMake(panel:)` → 计算到局部 → `end(t)` → 再赋 `view.renderState`，使 `didSet`/`setNeedsDisplay` 不计入 make 区间（L1471 判据测的是 `RenderStateBuilder.make` 符号，赋值/短路 Equatable 比较不属之，adversarial R1-L5）。
  - crosshair-make：`Coordinator.setCrosshair`（L122）同样 `let t = beginMakeCrosshair(panel:)` → 计算到局部 → `end(t)` → 赋值；用 `make-crosshair-*` 名与 update-pass make 分离（adversarial R1-M4）。
  - draw：`KLineView.draw(_:)`（L55）函数体。`let t = beginDraw(panel:)` 置于 `guard let ctx … else { return }`（L56，唯一早返）**之前**，`defer { end(t) }` 保证早返也闭合区间（adversarial R1-L 确认 draw 内仅此一早返）。统一 `end(_ token:)` API（D6）。
  - **`RenderStateBuilder.make` 纯函数体一行不改**（保持平台无关、host 纯可测）。
- **D5（panel 归属）**：`KLineView` 加 `public var panel: PanelId = .upper`，由 `Coordinator.sync(panel:engine:view:)`（每次 updateUIView 调）赋值（attach 时亦设初值）。make 两处调用点本就持 `panel`。`PanelViewState` 无 上/下 字段（只有 `period`，已核 Reducer.swift:24），故 draw 侧必须由 view 自带 panel 才能按「上/下」归属——R8-H1 明文要求「每个**上/下** make/draw」，panel 标是根治的一部分，非可选。默认 `.upper` 安全：makeUIView→attach→updateUIView(sync 设 panel + 设 renderState)→首 draw，panel 在首 draw 前已正确赋值。
- **D6（封装类型）**：新增 `Render/RenderSignposter.swift`（平台无关，无 `#if canImport(UIKit)` 守卫——`os` 跨平台，host 可编可测）。
  - 持单个共享 `OSSignposter`（subsystem `com.klinetrainer.render`，category `.pointsOfInterest`；`OSSignposter(subsystem:category:)` + `.pointsOfInterest` 已 adversarial R2 实证为真 API）。
  - **6 个 `StaticString` 区间名**（`make-upper`/`make-lower`/`make-crosshair-upper`/`make-crosshair-lower`/`draw-upper`/`draw-lower`），经 `name(op:panel:) -> StaticString` 纯选择函数选名（host 可测；**runtime 选 `StaticString` 已 adversarial R2 用 `swiftc -O` 实证可编可跑**——ternary/switch 在各臂返字面 StaticString 合法）。
  - **`endInterval` 需 name + state**（真实 SDK：`endInterval(_ name: StaticString, _ state: OSSignpostIntervalState)`，**无单 state 重载**；`OSSignpostIntervalState` 只携 `id` 不携 name，adversarial R2-H）。故 begin 返回**令牌** `struct RenderSignpost { let name: StaticString; let state: OSSignpostIntervalState }`（bundle 名 + 区间态），`end(_ token:)` 调 `signposter.endInterval(token.name, token.state)`。
  - 方法：`beginMake(panel:)`、`beginMakeCrosshair(panel:)`、`beginDraw(panel:)` 各返回 `RenderSignpost` 令牌；`end(_:)` 收口。**每区间用 `makeSignpostID()` 取新 id**——对非重叠主线程区间亦安全且是 Apple 推荐默认（id 复用仅在重叠区间会乱配对，此路径不重叠但 fresh-id 无害更稳，adversarial R1-L6）。
- **D7（draw 早返保护）**：见 D4 draw 项（begin 前置 + defer end + 唯一早返已核）。
- **D8（测试）**：见 §六。host 命名契约测（pin 6 名 + 选名函数）+ 调用 smoke。signpost 发射本身**无可观测产物**（Instruments-only），如实记录「不可单测」，不伪造行为断言；StaticString 名的可见性已由「名是编译期常量」保证，不再有 `.private` 风险（无需 host 断言 privacy 修饰符）。
- **D9（账本 flip 范围 + item-7 不变量保全）**：见 §五 5.4。机制 facet 标「机制交付」/ device facet 明示仍 OPEN；**不**在 `pr13c-completion.md` 的任何 `13c-R1` 命中行写 `RESOLVED`（保全 #112 13c-R2 acceptance item-7 grep 不变量逐字）；不破 `verify-wave3-completion.sh`（机器块无 13c-R1 key，保留帧预算 runbook 指针 + 不动 WAVE3-STATUS keys + runtime-matrix 仍 PARTIAL）。

---

## 五、交付物

### 5.1 `Render/RenderSignposter.swift`（新，唯一新生产文件）
平台无关。`OSSignposter` 封装 + 6 个 StaticString 名 + `name(op:panel:)` 纯选择 + `RenderSignpost` 令牌（name+state）+ begin{Make,MakeCrosshair,Draw}→令牌 / `end(_ token:)`→`endInterval(name,state)`。~50-70 行。

### 5.2 三处调用点接线（改 2 文件）
- `ChartContainerView.swift`：
  - `updateUIView`：`begin = beginMake(panel:)` → `let s = RenderStateBuilder.make(...)` → `end(begin)` → `view.renderState = s`（区间仅界定 make 求值，D4）。
  - `Coordinator.setCrosshair`：`begin = beginMakeCrosshair(panel:)` → 局部 make → `end(begin)` → 赋值。
  - `Coordinator.sync`（及 `attach` 设初值）：`view.panel = panel`。
- `KLineView.swift`：`draw(_:)` 包区间（`beginDraw(panel:)` 前置于 guard + `defer end`）；加 `public var panel: PanelId = .upper`。

### 5.3 帧预算 runbook 重写（改 1 文件）
`docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md`：
- 前置：Profile 模板从「Time Profiler 过滤符号」改「**os_signpost** instrument（+ Core Animation 帧轴）」，录制目标 = `com.klinetrainer.render` subsystem 的 6 个具名区间。
- 各场景测量法：从「分别过滤 make/draw 取峰值**相加**」改「**找最坏完整帧**：在该帧 vsync 窗口内对落入的 `make-upper/-lower` + `draw-upper/-lower` 区间**求和**（crosshair 场景另取 `make-crosshair-*`），作合并耗时」。
- 回填栏：记录所测周期 + 该帧蜡烛数 + 最坏帧的 make_upper/make_lower/draw_upper/draw_lower 明细 + 合并。
- 保留 Bitmap Cache 决议门、L1471 判据、文件名（`verify-wave3-completion.sh` 谓词 3c 依赖该**文件名**指针，内容重写不影响）。

### 5.4 账本 flip（改 2 文件 + 1 文件**仅加前向指针**）
- `docs/governance/2026-06-14-wave3-completion.md`（运行时矩阵行 L86 caveat ①）：13c-R1 从「accept residual / OPEN」改「**机制交付 2026-06-16**（os_signpost 帧相关 instrumentation shipped）/ **device <4ms 实测仍 OPEN**（runtime-matrix ③）」。**不动** WAVE3-STATUS 机器块（无 13c-R1 key；runtime-matrix 仍 PARTIAL；gate 谓词不破）。
- `docs/acceptance/2026-06-14-wave3-runtime-matrix.md`（R8-H1 caveat L73）：仿 R8-H2 的 addendum 形式，加「**【机制交付 2026-06-16，13c-R1 fast-follow】** os_signpost 帧相关 instrumentation 已 ship；runbook 已改帧归并法。**device 最坏帧 <4ms 实测仍 OPEN**（本节 ③）」。R8-H1 原文（caveat 本体）保留。
- `docs/acceptance/2026-06-14-wave3-pr13c-completion.md`（**item-7 不变量保全**）：13c-R1 residual 行**保持 `accept residual`、绝不写 `RESOLVED`**（保全 #112 item-7 逐字 grep）。**仅**在该行末尾加**前向指针**子句「（机制 facet 由 2026-06-16 13c-R1 fast-follow 交付 os_signpost instrumentation；device 实测仍 pending — 见 docs/superpowers/specs/2026-06-16-...）」——该子句含 `accept residual`、**不**含 `RESOLVED`，故 `grep 13c-R1 → 均含 accept residual、均不含 RESOLVED` 不变量逐字仍真。
- **不**回改 #112 的 `2026-06-15-wave3-13c-r2-perf-fixture.md`（历史 point-in-time 清单）；其 item-7 grep 因上策略**仍 PASS**。

### 5.5 本 PR 验收清单（中文，非编码者可执行；governance backstop #2）
`docs/acceptance/2026-06-16-wave3-13c-r1-signpost.md`：action/expected/pass-fail 三列。覆盖：
- RenderSignposter 存在性 + 6 名常量 grep。
- 三调用点接线 grep（make / make-crosshair / draw）+ KLineView.panel。
- host 测试通过（命名契约 + smoke）+ 既有全量零回归。
- runbook 已改 signpost 帧归并法（无「峰值相加」作权威判据残留）。
- 账本三 doc flip 正确（机制交付 + device OPEN 双陈述；`grep 13c-R1 pr13c-completion.md` 仍均含 `accept residual`、均不含 `RESOLVED`）。
- `bash scripts/governance/verify-wave3-completion.sh` 仍 PASS。
- **manual / Instruments-only 项（如实标）**：在真机 Release Profile 中确认 os_signpost instrument 出现 `com.klinetrainer.render` 的 6 个具名 lane（此项 device-only，非 host 可验，归 runtime-matrix ③ 回填时核）。
- **supersedes-note**：本清单显式声明「#112 `2026-06-15-...` item-7 是 point-in-time 记录；本 PR 经 5.4 策略保全其 grep 不变量逐字真」。
- 无 `.claude/workflow-rules.json` forbidden phrases。

---

## 六、测试策略

无渲染**行为**改动（区间只包边界，不改输出）→ 既有全量测试零回归是首要判据（worktree base `c7feea8` 实测基线 = **1064 tests in 146 suites**；impl 时以当次实测 N 为准，回归判据 = 0 failures 非定值 N）。

新测试 `Render/RenderSignposterTests.swift`（host）：
1. **命名契约**：`RenderSignposter.subsystem == "com.klinetrainer.render"`；`name(op:panel:)` 对 6 组合返对应名。**`StaticString` 非 `Equatable`（adversarial R2-L），故断言走 `.description`（String）**：`name(op: .make, panel: .upper).description == "make-upper"` …6 组逐一。**理由非 vacuous**：这些 `StaticString` 是 runbook（人类分析师在 Instruments 里按名筛选 lane）消费的公开契约；pin 它们防止改名静默破坏 runbook（正是 codex 关心的 honesty/drift）。
2. **调用 smoke**：`shared` 上 `beginMake/beginMakeCrosshair/beginDraw` 对 `.upper`/`.lower` 各跑一遍 + `end`——断言不崩。signpost 在未录制时是 no-op，host 安全。

**诚实声明（写进 spec + 验收）**：signpost 的实际发射/帧归并**只能** Instruments 验证，host/CI 不可断言其产物；本 PR 不伪造「帧预算 gate」。区间名可见性由「名是 StaticString 编译期常量」保证（无需也无法 host 断言 Instruments 渲染）。draw 行为不变由「8 个 drawXxx 一行不改 + 区间只在函数体首尾」+ 既有渲染测试零回归保证。

验证门：worktree `swift test`（macOS host）全绿 + Mac Catalyst build-for-testing 编译绿（required check）。

---

## 七、风险与诚实 caveat

1. **Release 含 instrumentation**（D3）：有意例外于 #if DEBUG 纪律。缓解：`os_signpost` 未录制近零成本（Apple 框架自身在 Release 大量发 signpost）；subsystem 隔离，不污染日志。
2. **panel 默认 `.upper`**：首帧前若 sync 未跑则默认 upper。实际：makeUIView→attach→updateUIView(sync 设 panel + 设 renderState)→首 draw，panel 在首 draw 前已正确（已核 attach/sync/updateUIView 顺序）。低风险，记录。
3. **「最坏完整帧」仍需人工在 Instruments 判读**：A 不自动算最坏帧（B/C 才自动，但被驳回）。runbook 给出明确判读步骤；这是 device 手动验收的固有性质（同全 Wave 3 运行时矩阵）。
4. **device facet 仍 OPEN**：本 PR 不闭合「帧预算实测 <4ms」——如实记录于 runtime-matrix ③ + 账本措辞纪律（§二），避免 overclaim。
5. **历史 doc 不变量**（adversarial R1-H）：经 5.4 的 item-7 保全策略，#112 13c-R2 acceptance item-7 grep 仍逐字 PASS；本 PR 验收附 supersedes-note 显式记录关系，contradiction 不留隐患。

---

## 八、成功判据（goal-driven）

1. `RenderSignposter` 落地，6 名 + 三调用点接线（make + make-crosshair + draw）→ verify：grep + 人读。
2. `swift test` host 全绿（含命名契约 + smoke）+ 既有全量零回归（base `c7feea8` 实测 1064）+ Catalyst 编译绿 → verify：测试输出。
3. runbook 测量法改为 signpost 帧归并（无「峰值相加」残留作为权威判据）→ verify：grep runbook。
4. 账本机制 facet「机制交付」+ device facet 明示 OPEN；`grep 13c-R1 pr13c-completion.md` 均含 `accept residual`、均不含 `RESOLVED`；`verify-wave3-completion.sh` 仍 PASS → verify：grep + 跑脚本。
5. 渲染**行为**零改动 → verify：`git diff` 仅触 RenderSignposter（新）+ 两调用点边界 + KLineView.panel + docs；8 个 drawXxx / RenderStateBuilder 数学零改。

---

## 九、给对抗性 reviewer 的假设清单（须挑战）

1. **D3 不 #if DEBUG**：帧预算测 Release 包 → instrumentation 必须在 Release；signpost 未录制近零成本。（R1 已确认 airtight）
2. **方案 A（不加帧驱动）**：Instruments Core Animation/PoI 帧轴 + 区间时间戳即可按帧归并；加 CADisplayLink 反而自扰动。（R1 已确认 sound）
3. **StaticString 命名契约测试**：名是 runbook 消费的公开契约，pin 防 drift；StaticString 天然 public 解了 R1-M3 的 `.private` 隐患。
4. **panel 加到 KLineView**：R8-H1 要求「每个上/下」归属，`PanelViewState` 无上/下字段，draw 侧必须自带 panel。（R1 已确认非 creep）
5. **13c-R1 facet 拆分**（机制交付 / device OPEN）+ 措辞纪律（不裸用 RESOLVED）：是否诚实、有无 overclaim。（R1-M2 已落实非裸 RESOLVED）
6. **item-7 不变量保全**（5.4）：`pr13c-completion.md` 13c-R1 行保持 `accept residual` 不写 `RESOLVED` + supersedes-note——是否真保全 #112 历史 grep 逐字。（R1-H 修复路径）
7. **crosshair-make 独立名**（M4）：是否足以与 update-pass make 分离、runbook 是否正确指示按场景取名。
8. **make 区间边界仅 make()**（L5）：是否正确排除赋值/didSet，对齐 L1471 判据符号。
9. **draw 早返 defer**（L/D7）：`guard ctx` 是唯一早返（R1 已核），begin 前置 + defer 覆盖。

---

## 十、变更记录

- **R1（opus 4.8 adversarial review，0C/1H/3M/2L）→ 全修**：
  - H（item-7 contradiction）→ §五 5.4：`pr13c-completion.md` 13c-R1 行保 `accept residual` 不写 `RESOLVED` + 前向指针 + supersedes-note，保全 #112 grep 不变量逐字。
  - M2（裸 RESOLVED 易误读）→ §二 措辞纪律：统一「机制交付 / device OPEN」，账本不裸用 RESOLVED。
  - M3（`%{public}` 不可 host 测）→ D2/D6：改 **StaticString per-panel×op 区间名**，名天然 public + host 可测，根除动态参数 privacy 隐患。
  - M4（crosshair 第 3 个 make 混淆 4-贡献者模型）→ §一/D4/5.2：crosshair-make 用独立名 `make-crosshair-*`。
  - L5（make 区间含赋值/didSet 会超 L1471 符号）→ D4/5.2：区间仅界定 `RenderStateBuilder.make()` 求值，计算到局部再赋值。
  - L6（fresh-id 未说明意图）→ D6：注明每区间 fresh `makeSignpostID()` 安全且 Apple 推荐。
  - 确认 sound 未改：D1/D2 availability/D3/D5/D7/gate-safety（R1 全部 verified）。
- **R2（fresh opus 4.8 adversarial review，0C/1H/0M/2L；R1 6 findings 全 verified RESOLVED）→ 全修**：
  - H（`endInterval` 需 name+state，无单 state 重载）→ D6/5.1：begin 返 `RenderSignpost` 令牌（name+state），`end(token)` 调 `endInterval(token.name, token.state)`。
  - L（`StaticString` 非 Equatable）→ §六.1：命名契约断言走 `.description`（String）。
  - L（"1064" 未溯源）→ §六/§八：标 base `c7feea8` 实测基线，回归判据 = 0 failures 非定值 N。
  - **R2 实证（reviewer `swiftc -O`）**：runtime 选 `StaticString`（ternary/switch）可编可跑；`OSSignposter(subsystem:category:.pointsOfInterest)` 真 API；平台无关 host 可编。中心命名方案获证 sound。
- **R3（fresh opus 4.8 adversarial convergence review）→ APPROVE（0C/0H/0M/1L）**：R1+R2 全 6 findings verified RESOLVED；唯一 Low = §四 D4 散文残留旧 end-method 名（`endMake`/`endMakeCrosshair`/`endDraw(state)`）与 D6 统一 `end(_ token:)` API 不一致 → 已改 D4 统一 `let t = begin…(panel:)` / `end(t)` / `defer { end(t) }`。spec 收敛。

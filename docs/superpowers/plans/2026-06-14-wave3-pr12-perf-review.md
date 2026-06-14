# Wave 3 顺位 12：性能评审 + Bitmap Cache 按需 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付渲染热路径的静态性能评审 artifact + 权威帧预算验收判据 runbook + Bitmap Cache 条件引入决议，并加一条 host 级 CI 回归绊线测试——**0 生产代码改动**。

**Architecture:** 4 个交付物：(1) 性能评审 doc（静态热点分析 + Bitmap Cache 决议，落 `docs/governance/`）；(2) 帧预算 runbook（device Instruments 测量流程，落 `docs/runbooks/`）；(3) host 回归绊线（扩既有 smoke 到完整 `make()`，唯一代码，test-only）；(4) 非编码者验收清单（`docs/acceptance/`）。门控测量（Instruments 单帧 >4ms）在 CI 不可运行，故 Bitmap Cache 不实现——决议门 + 设计草图备而不用。

**Tech Stack:** Swift Testing（host）、Core Graphics 渲染路径（只读分析）、Markdown 文档。

**Spec:** `docs/superpowers/specs/2026-06-14-wave3-pr12-perf-review-design.md`（opus 4.8 xhigh adversarial review R1 APPROVE 收敛）。

---

## File Structure

| 文件 | 动作 | 责任 |
|---|---|---|
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift` | Modify | 新增 1 个 `@MainActor` host smoke，覆盖完整 `make()`（非权威回归绊线） |
| `docs/governance/2026-06-14-wave3-pr12-performance-review.md` | Create | 静态性能评审 artifact + Bitmap Cache 条件引入决议 + 设计草图 |
| `docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md` | Create | device/sim Instruments 帧预算测量 runbook + 回填栏 |
| `docs/acceptance/2026-06-14-wave3-pr12-perf-review.md` | Create | 非编码者可执行验收清单（governance backstop #2） |

**0 生产代码改动**：`RenderStateBuilder` / `KLineView*` / `MainChartLayout` / `DecelerationAnimator` 等一行不改。验收时 `git diff --stat` 必须仅含上表 4 文件 + 本 plan/spec。

---

### Task 1: Host 性能回归绊线测试（唯一代码）

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`（在既有 `perfSmoke()`（约 L246-259）之后插入新测试）

**背景（已核实）**：既有 `perfSmoke()` 只覆盖 `makeViewport()`（不含 volumeRange/macdRange 的 `flatMap` 分配 + `KLineRenderState` 装配）。`RenderStateBuilder.make` 是 `@MainActor`（`RenderStateBuilder.swift:18`）。`TrainingEngine.preview()` 仅 8 根 candle（`previewCandleCount=8`），太小不能压装配；故用 `Self.candles(...)` 造 5000 根 + 直接构造 engine（`@testable` 可达 internal init）。`init` 需 `initialUpperPeriod: .m3` 才能让 upper 面板读到这 5000 根 .m3（默认 `.m60` 会因缺 `.m60` 数据使 `make()` 返回 `.empty`）。构造样式参照 `TrainingEnginePinchTests.swift:13-31`。

- [ ] **Step 1: 先确认 baseline 绿**

Run: `cd ios/Contracts && swift test 2>&1 | tail -20`
Expected: 既有全部测试 PASS（0 failures）。**记录 Step 1 实测测试总数**（以本次输出为准，勿用估值），作 Task 1 末尾回归对照（Step 4 应为该数 +1）。

- [ ] **Step 2: 写 host smoke（覆盖完整 `make()`）**

在 `RenderStateBuilderTests.swift` 的 `perfSmoke()` 之后插入：

```swift
    @Test("perf smoke（非权威）：完整 make() 装配开销（含 volume/macd range + 装配）")
    @MainActor
    func makePerfSmoke() {
        // make() 的成本由 ≤80 根可见切片的 map/flatMap + KLineRenderState 装配主导
        //（总根数仅影响 makeViewport 的 O(log n) 二分，已由既有 perfSmoke 覆盖）。
        // preview() 仅 8 根不足以压装配，故直接造 5000 根 .m3 engine。
        let cs = Self.candles(period: .m3, count: 5000, macd: true)
        let maxTick = cs.count - 1
        let engine = TrainingEngine(
            flow: NormalFlow(
                fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
                maxTick: maxTick),
            allCandles: [.m3: cs],
            maxTick: maxTick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3)
        let start = Date()
        for _ in 0..<100 {
            _ = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
        }
        let ms = Date().timeIntervalSince(start) * 1000 / 100
        // 非权威 host smoke：draw 侧帧预算唯一权威 = device Instruments runbook（2026-06-14 frame-budget）。
        print("[顺位12 perf smoke] make() avg = \(ms) ms (non-authoritative; not the spec frame budget)")
        #expect(ms < 50)   // 极宽松上界，仅防病态退化（同既有 perfSmoke 量级）
    }
```

- [ ] **Step 3: 运行新测试，确认 PASS + 打印 ms**

Run: `cd ios/Contracts && swift test --filter makePerfSmoke 2>&1 | tail -20`
Expected: PASS；stdout 含 `[顺位12 perf smoke] make() avg = … ms`（典型远 < 1ms）。
若 FAIL 因 `make()` 返 `.empty`（断言/0 candle）：核 `initialUpperPeriod: .m3` 是否漏写。

- [ ] **Step 4: 跑全量 suite 确认零回归**

Run: `cd ios/Contracts && swift test 2>&1 | tail -10`
Expected: Step 1 总数 +1，0 failures。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
git commit -m "顺位12 Task1：host make() 性能回归绊线 smoke（test-only，非权威）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: 性能评审 artifact doc

**Files:**
- Create: `docs/governance/2026-06-14-wave3-pr12-performance-review.md`

**性质**：落实 modules v1.4 L2554「Phase 5 磨光前做一次性能评审…由 Codex 审视性能热点」的**静态**评审（device 实测归 Task 3 runbook）。**禁用** `.claude/workflow-rules.json` forbidden phrases（验证通过即可 / 看起来正常 / 应该没问题 / should work / looks fine）。

- [ ] **Step 1: 写评审 doc**，须含以下小节与**核实过的**内容（行号引用必须与代码一致）：

  1. **〇 摘要 + 依赖状态**：顺位 12 = 静态评审 + 帧预算判据 + Bitmap Cache 决议 + host 绊线，0 生产代码；依赖锚 3/4/5/11 均 merged。
  2. **一 热路径结构**：`make()`（纯，host，`RenderStateBuilder.swift:18-43`）vs `draw()`（UIKit 8 pass，`KLineView.swift:36-63`，post-顺位4-rebase）拆分；重建触发 = `ChartContainerView.updateUIView`（`ChartContainerView.swift:34-41`）每次 `@Bindable` 变更；重绘触发 = `KLineView.renderState.didSet` Equatable 短路（`KLineView.swift:18-19`）；帧驱动 = `DecelerationAnimator`（UIKit `CADisplayLink` 原生 Hz、未设 `preferredFramesPerSecond`；macOS `Timer(1.0/120.0)`，`DecelerationAnimator.swift:200`），每帧 1 个 `onUpdate(delta)`，**animator 内不调 `make()`**。
  3. **二 每帧 CG 调用量级账**（对照 plan v1.5 L31「600-700 次/帧，瓶颈线 >5000」）：
     - `drawCandles`（`KLineView+Candles.swift:13-27`）：per-candle 1 `strokePath`（影线）+ 1 `fill`（实体）+ `setFill`/`setStroke`；可见根默认 **80**（`RenderStateBuilder.defaultVisibleCount=80`，**非** plan 文案的 93）→ ~80×(2 path + 2 color) ≈ 320 ops。
     - `drawMA66`（`:30-44`）1 折线；`drawBOLL`（`:47-67`）3 轨虚线 + `setLineDash`；`drawVolume`/`drawMACD` ~80 rect + 折线 + ~80 bar。
     - 合计与 plan L31 同阶、远低于瓶颈线。**精确单帧 ms 归 Task 3 device runbook**——本静态评审不 claim 实测值、不放行也不否决帧预算。
  4. **三 可识别热点清单（静态，供对抗 review）**：
     - **每帧分配（分两侧）**：draw() 侧 `MainChartLayout.candleShapes/ma66Polyline/bollPolylines` 每帧新建数组；make() 侧 `slice.map`（volumeRange）/`flatMap`（macdRange，`RenderStateBuilder.swift:29/31`）每帧新建数组。当前规模据 plan 无压力，记为「device 实测逼近预算时首查点」。
     - **per-candle 颜色态**：`drawCandles` 循环内每根 `setFill/setStroke`；涨跌分组批绘是潜在优化，**仅当实测 >4ms 才值得**。
     - **Equatable 短路成本**：`KLineRenderState` 含 `visibleCandles: ArraySlice` 等大字段；短路语义正确（相同 engine 状态不重绘，modules L1471），比较成本已接受。
  5. **四 Bitmap Cache 条件引入决议 + 设计草图**（**不编码**）：
     - **决议门**：实测峰值单帧 < 4ms → Phase 1 纯 draw 充分，**不引入**，本子项 no-op（outline L173）；≥ 4ms → 按下方草图引入（**独立后续 anchor**，非本锚），引入后须重测回落 <4ms。
     - **设计草图**：缓存 5 视口静态层（Candles/MA66/BOLL/Volume/MACD）到离屏 `CGLayer`/bitmap；失效触发 = 可见切片变化（新 tick / pan 跨 candle 边界）/ geometry 缩放（pinch）/ drawing·marker 增删；合成 = 缓存 blit 后动态层（`Crosshair` 逐帧）叠加，`Markers/Drawings`（viewport-dependent）随缓存失效重建。
     - **风险记录**：缓存引入 displayScale/亚像素对齐 + 失效正确性 + 内存三类新风险——故 spec 设「仅 >4ms 才引入」门，不达门不付此风险。
  6. **五 结论**：Phase 1 纯 draw 在 spec 规模假设下达标；裁决权属 Task 3 device 实测；本评审交付热点清单 + 量级账 + 条件门，不交付数值。

- [ ] **Step 2: 自检 forbidden phrases**

Run: `grep -nE "验证通过即可|看起来正常|应该没问题|should work|looks fine" docs/governance/2026-06-14-wave3-pr12-performance-review.md && echo "FOUND-FORBIDDEN" || echo "CLEAN"`
Expected: `CLEAN`

- [ ] **Step 3: Commit**

```bash
git add docs/governance/2026-06-14-wave3-pr12-performance-review.md
git commit -m "顺位12 Task2：静态性能评审 artifact + Bitmap Cache 条件引入决议

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: 帧预算 device runbook

**Files:**
- Create: `docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md`

**性质**：device/sim **手动**验收（CLI/CI 仅编译，不跑 UIKit 运行时）。执行者 = user，非编码者可执行。**引用而不修改** `docs/runbooks/2026-06-07-c8b-runtime-acceptance.md` item #3。**权威行号 = modules v1.4 L1471**（c8b 的「spec L1467」为陈旧行号，不沿袭）。**禁用** forbidden phrases。

- [ ] **Step 1: 写 runbook**，须含：

  1. **性质段**：device/sim 手动；CLI/CI 仅编译；执行者 user；本 runbook 覆盖 Wave 3 新交互（pinch/绘线/十字光标）帧预算，补 c8b #3（引用不改）。
  2. **权威判据**：单帧 `buildRenderState(make) + KLineView.draw(_:)` < 4ms @ 120Hz（modules v1.4 **L1471** / plan v1.5 L1264）。
  3. **action/expected/pass-fail 表**（≥ 以下场景，每行三列）：
     - Instruments Time Profiler / Core Animation 录制：纯水平滚动 + 惯性减速 → 峰值单帧 draw < 4ms（回填实测 ms：____）
     - pinch 缩放过程录制 → 峰值单帧 < 4ms（回填：____）
     - 水平线绘制 + 跨缩放/平移还原录制 → 峰值单帧 < 4ms（回填：____）
     - 长按十字光标拖动录制 → 峰值单帧 < 4ms（回填：____）
     - Equatable 短路验证：相同 engine 状态重复 `updateUIView` 不触发 `draw`（Core Animation 无多余 commit）→ pass = 无冗余重绘
  4. **Bitmap Cache 决议门**：任一场景峰值 ≥ 4ms → 触发性能评审 doc §四 决议门，引入 Bitmap Cache（独立 anchor）后重测；全 < 4ms → Phase 1 充分，Bitmap Cache no-op。
  5. **回填 + 归属**：device 型号 + iOS 版本 + 各场景峰值 ms 栏；明示实测数值是 user device 职责 + **顺位 13 收尾阻塞依赖**；本 runbook 链接进顺位 13 completion doc。

- [ ] **Step 2: 自检 forbidden phrases**

Run: `grep -nE "验证通过即可|看起来正常|应该没问题|should work|looks fine" docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md && echo "FOUND-FORBIDDEN" || echo "CLEAN"`
Expected: `CLEAN`

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md
git commit -m "顺位12 Task3：帧预算 device runbook（Wave3 新交互 + Bitmap Cache 决议门）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: 非编码者验收清单

**Files:**
- Create: `docs/acceptance/2026-06-14-wave3-pr12-perf-review.md`

**性质**：governance backstop #2——action/expected/pass-fail 三列、Chinese、非编码者可执行、**禁用** forbidden phrases。参照既有 `docs/acceptance/2026-06-13-wave3-pr8-replay-settlement.md` 格式。

- [ ] **Step 1: 写验收清单**，每行 action（可执行命令或可观察操作）/ expected（客观可判）/ pass-fail，覆盖：
  1. 性能评审 doc 存在：`test -f docs/governance/2026-06-14-wave3-pr12-performance-review.md` → exit 0。
  2. 量级账与代码一致：人读评审 §二 的行号引用，对照 `KLineView+Candles.swift:13-67` 实代码（per-candle stroke+fill / 80 分母 / 3 轨 BOLL）→ 一致。
  3. host smoke 通过：`cd ios/Contracts && swift test --filter makePerfSmoke` → PASS 且 stdout 含 `make() avg`。
  4. 帧预算 runbook 可执行：`test -f docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md` 且含 4 录制场景 + 4ms 判据 + 回填栏 + L1471（非 L1467）。
  5. Bitmap Cache 决议门双分支在 doc：`grep -c "no-op\|独立后续 anchor" docs/governance/2026-06-14-wave3-pr12-performance-review.md` ≥ 1。
  6. 0 生产代码改动：`git fetch origin -q && git diff --stat "origin/main...HEAD" -- ios/Contracts/Sources` → 空（**三点** merge-base 比较，免本地 `main` 滞后误报；仅显示本分支自身改动）。
  7. forbidden phrases 自检：`grep -rnE "验证通过即可|看起来正常|应该没问题|should work|looks fine" docs/governance/2026-06-14-wave3-pr12-performance-review.md docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md docs/acceptance/2026-06-14-wave3-pr12-perf-review.md` → 无输出（CLEAN）。

- [ ] **Step 2: 自检 forbidden phrases（清单自身）**

Run: `grep -nE "验证通过即可|看起来正常|应该没问题|should work|looks fine" docs/acceptance/2026-06-14-wave3-pr12-perf-review.md && echo "FOUND-FORBIDDEN" || echo "CLEAN"`
Expected: `CLEAN`（注意：清单引用 forbidden 词作为「禁用清单」时须用占位符或拆字，避免自命中——如写「禁用短语见 workflow-rules.json」而非逐字列出）。

- [ ] **Step 3: Commit**

```bash
git add docs/acceptance/2026-06-14-wave3-pr12-perf-review.md
git commit -m "顺位12 Task4：非编码者验收清单（backstop #2）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: 整体验证 + PR 准备

**Files:** 无新增（验证 + PR）

- [ ] **Step 1: 全量 host 测试绿**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: 0 failures。

- [ ] **Step 2: 0 生产代码改动确认**

Run: `git fetch origin -q && git diff --stat "origin/main...HEAD" -- ios/Contracts/Sources`
Expected: 空输出（三点 merge-base 比较，免本地 `main` 滞后误报）。
Run: `git diff --stat "origin/main...HEAD"`
Expected: 仅 `docs/**` + `RenderStateBuilderTests.swift`。

- [ ] **Step 3: 全仓 forbidden-phrase 终检**

Run: `grep -rnE "验证通过即可|看起来正常|应该没问题|should work|looks fine" docs/governance/2026-06-14-wave3-pr12-performance-review.md docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md docs/acceptance/2026-06-14-wave3-pr12-perf-review.md`
Expected: 无输出。

- [ ] **Step 4: 交 verification-before-completion + requesting-code-review + 整体 opus 4.8 xhigh 对抗性 review**（按会话主流程，非本 plan 步骤），收敛后 push + 开 PR + Mac Catalyst required check 绿。

---

## Self-Review（writing-plans 自检）

**1. Spec coverage**：
- spec §3.1 性能评审 artifact → Task 2 ✓
- spec §3.2 帧预算判据 + runbook → Task 3 ✓（L1471 校正含）
- spec §3.3 Bitmap Cache 决议 + 草图 → Task 2 §四 ✓
- spec §3.4 host 回归绊线 → Task 1 ✓
- spec §3.5 验收清单 → Task 4 ✓
- spec §四 0 生产代码 → Task 5 Step 2 ✓
- spec §七 reviewer 假设清单 → 在整体 review（Task 5 Step 4）暴露 ✓

**2. Placeholder scan**：Task 1 含完整可编译测试代码；doc 任务给 section + 核实行号 + 必含内容（非占位）。runbook/验收的「____」是**有意的回填栏**（device 数值待 user 填），非 plan 占位。✓

**3. Type consistency**：测试用 `TrainingEngine(flow:allCandles:maxTick:initialCapital:initialCashBalance:initialUpperPeriod:initialLowerPeriod:)`（核实 `TrainingEngine.swift:64-78`）、`NormalFlow(fees:maxTick:)`（核实 `TrainingEnginePinchTests.swift:19`）、`Self.candles(period:count:macd:)`（核实 `RenderStateBuilderTests.swift:12-24`）、`RenderStateBuilder.make(engine:panel:bounds:)` `@MainActor`（核实 `RenderStateBuilder.swift:18-19`）——签名一致。✓

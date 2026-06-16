# Wave 3 13c-R1 `os_signpost` 帧相关 instrumentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给渲染热路径 make/draw 加 `os_signpost` 区间（per-panel×op StaticString 名），使 Instruments 可按 display frame 归并上/下双实例 make/draw、取最坏完整帧真实合并耗时；根治 13c-R1「采样≠帧相关」并重写帧预算 runbook + flip 账本（机制交付 / device 仍 OPEN）。

**Architecture:** 新增平台无关 `RenderSignposter`（`OSSignposter` 封装 + 6 个 StaticString 区间名 + `RenderSignpost` 令牌 name+state）；在 3 个 UIKit 调用边界（`updateUIView` make、`setCrosshair` crosshair-make、`KLineView.draw`）包 begin/end 区间；`KLineView` 加 `panel` 供 draw 区间归属。**不 #if DEBUG**（帧预算测 Release 包）；**不改任何渲染数学/输出**（区间只包边界）。

**Tech Stack:** Swift 6（strict concurrency）/ `os`（`OSSignposter`，iOS15+/macOS12+，Package floor iOS17/macOS14 ≥ 之）/ Swift Testing（host）/ Mac Catalyst build-for-testing（required CI）。

**Spec:** `docs/superpowers/specs/2026-06-16-wave3-13c-r1-signpost-instrumentation-design.md`（opus 4.8 对抗性 review R1→R2→R3 APPROVE）。

---

## File Structure

| 文件 | 角色 | 动作 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderSignposter.swift` | 唯一新生产文件：`OSSignposter` 封装 + 6 名 + 令牌 + begin/end | Create |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderSignposterTests.swift` | host 命名契约 + 调用 smoke | Create |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift` | updateUIView make 区间 + setCrosshair crosshair-make 区间 + sync/attach 设 `view.panel` | Modify |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift` | draw 区间（begin 前置 + defer end）+ `panel` 属性 | Modify |
| `docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md` | 测量法 Time Profiler 峰值相加 → os_signpost 最坏帧归并 | Rewrite |
| `docs/governance/2026-06-14-wave3-completion.md` | 运行时矩阵行 caveat ①：13c-R1 机制交付 / device OPEN | Modify（surgical） |
| `docs/acceptance/2026-06-14-wave3-runtime-matrix.md` | R8-H1 caveat 加机制交付 addendum | Modify（surgical） |
| `docs/acceptance/2026-06-14-wave3-pr13c-completion.md` | 13c-R1 行加前向指针（**保 accept residual / 不写 RESOLVED**，保全 #112 item-7 grep） | Modify（surgical） |
| `docs/acceptance/2026-06-16-wave3-13c-r1-signpost.md` | 本 PR 验收清单（中文非编码者可执行） | Create |

**关键不变量**：
- `RenderStateBuilder.make` 纯函数体、`makeViewport`、8 个 `drawXxx` **一行不改**（行为中性）。
- `verify-wave3-completion.sh` 仍 PASS（机器块无 13c-R1 key；保留帧预算 runbook 文件名指针；runtime-matrix 仍 PARTIAL；不动 WAVE3-STATUS keys）。
- `grep -n "13c-R1" docs/acceptance/2026-06-14-wave3-pr13c-completion.md` → 每命中行仍均含 `accept residual`、均不含 `RESOLVED`（保全 #112 `2026-06-15-...` item-7）。

---

## Task 1: `RenderSignposter` + host tests（TDD）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderSignposter.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderSignposterTests.swift`

- [ ] **Step 1: 先写失败测试**（命名契约 + smoke）

Create `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderSignposterTests.swift`：

```swift
// Kline Trainer Swift Contracts — Wave 3 13c-R1 RenderSignposter host tests
// Spec: docs/superpowers/specs/2026-06-16-wave3-13c-r1-signpost-instrumentation-design.md
// 命名契约 = runbook（分析师在 os_signpost instrument 按名筛 lane）消费的公开契约；pin 防改名静默破坏 runbook。
// StaticString 非 Equatable → 断言走 .description（String）。signpost 未录制为 no-op，host smoke 安全。
import Testing
@testable import KlineTrainerContracts

@Suite("RenderSignposter 命名契约 + 调用 smoke（Wave 3 13c-R1）")
struct RenderSignposterTests {

    @Test("subsystem 常量稳定（runbook 按此 subsystem 筛 os_signpost lane）")
    func subsystemConstant() {
        #expect(RenderSignposter.subsystem == "com.klinetrainer.render")
    }

    @Test("name(op:panel:) 对 6 组合返预期名（StaticString 非 Equatable → 走 .description）")
    func nameContract() {
        #expect(RenderSignposter.name(op: .make, panel: .upper).description == "make-upper")
        #expect(RenderSignposter.name(op: .make, panel: .lower).description == "make-lower")
        #expect(RenderSignposter.name(op: .makeCrosshair, panel: .upper).description == "make-crosshair-upper")
        #expect(RenderSignposter.name(op: .makeCrosshair, panel: .lower).description == "make-crosshair-lower")
        #expect(RenderSignposter.name(op: .draw, panel: .upper).description == "draw-upper")
        #expect(RenderSignposter.name(op: .draw, panel: .lower).description == "draw-lower")
    }

    @Test("begin/end 三类区间对上下 panel 各跑一遍不崩（no-op when not recording）")
    func beginEndSmoke() {
        for panel in [PanelId.upper, PanelId.lower] {
            RenderSignposter.end(RenderSignposter.beginMake(panel: panel))
            RenderSignposter.end(RenderSignposter.beginMakeCrosshair(panel: panel))
            RenderSignposter.end(RenderSignposter.beginDraw(panel: panel))
        }
    }
}
```

- [ ] **Step 2: 运行测试，确认编译失败**

Run: `cd ios/Contracts && swift test --filter RenderSignposterTests 2>&1 | tail -20`
Expected: 编译失败（`cannot find 'RenderSignposter' in scope`）。

- [ ] **Step 3: 写最小实现**

Create `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderSignposter.swift`：

```swift
// Kline Trainer Swift Contracts — Wave 3 13c-R1 渲染热路径 os_signpost 帧相关 instrumentation
// Spec: docs/superpowers/specs/2026-06-16-wave3-13c-r1-signpost-instrumentation-design.md
//
// 平台无关（os 跨平台，host 可编可测）；**不** #if DEBUG 门控——帧预算判据（modules L1471）
// 测的是 Release（优化）包，故 instrumentation 必须编进 Release。os_signpost 未被 Instruments
// 录制时近零成本（Apple 框架自身在 Release 大量发 signpost）。
//
// 区间名 = per-panel×op 的 StaticString（Instruments 恒可见，无动态字符串 .private 隐患）。
// endInterval 真实 SDK 签名 = endInterval(_ name: StaticString, _ state:)（无单 state 重载；
// state 只携 id 不携 name），故 begin 返回令牌 bundle 名 + 态，end 收口时回传两者。

import os

enum RenderSignposter {
    /// runbook 在 os_signpost instrument 按此 subsystem 筛 lane。
    static let subsystem = "com.klinetrainer.render"

    /// 区间操作类别（update-pass make / crosshair 旁路 make / draw）。
    enum Op {
        case make, makeCrosshair, draw
    }

    /// begin 返回的令牌：bundle 区间名 + 区间态（end 需二者，见文件头）。
    struct Token {
        let name: StaticString
        let state: OSSignpostIntervalState
    }

    // OSSignposter 在 iOS17/macOS14 floor 为 Sendable（同 OSLog 在本包已用 static let，
    // 见 DefaultDownloadAcceptanceCleaner）；若个别 toolchain 报 strict-concurrency，
    // 加 `nonisolated(unsafe)`（os 句柄线程安全，注解语义正确）。
    private static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    /// (op, panel) → 区间名（编译期常量；runtime 选 StaticString 合法，已 spec R2 实证）。
    static func name(op: Op, panel: PanelId) -> StaticString {
        switch (op, panel) {
        case (.make, .upper): return "make-upper"
        case (.make, .lower): return "make-lower"
        case (.makeCrosshair, .upper): return "make-crosshair-upper"
        case (.makeCrosshair, .lower): return "make-crosshair-lower"
        case (.draw, .upper): return "draw-upper"
        case (.draw, .lower): return "draw-lower"
        }
    }

    static func beginMake(panel: PanelId) -> Token { begin(op: .make, panel: panel) }
    static func beginMakeCrosshair(panel: PanelId) -> Token { begin(op: .makeCrosshair, panel: panel) }
    static func beginDraw(panel: PanelId) -> Token { begin(op: .draw, panel: panel) }

    private static func begin(op: Op, panel: PanelId) -> Token {
        let n = name(op: op, panel: panel)
        return Token(name: n, state: signposter.beginInterval(n, id: signposter.makeSignpostID()))
    }

    static func end(_ token: Token) {
        signposter.endInterval(token.name, token.state)
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `cd ios/Contracts && swift test --filter RenderSignposterTests 2>&1 | tail -20`
Expected: PASS（3 tests）。若报 `static property 'signposter' is not concurrency-safe`，在 `private static let signposter` 前加 `nonisolated(unsafe) ` 重跑。

- [ ] **Step 5: 跑全量确认零回归**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: `Test run with 1067 tests in 147 suites passed`（base 1064 + 本 task 3 新测试；suites +1）。判据 = 0 failures。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderSignposter.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderSignposterTests.swift
git commit -m "feat(13c-R1): RenderSignposter os_signpost 区间封装 + host 命名契约/smoke 测试"
```

---

## Task 2: 三调用点接线 + KLineView.panel（行为中性）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift`（updateUIView L37-41 / setCrosshair L117-122 / sync L63-66 / attach L78-79）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift`（renderState 后加 panel / draw L55-56）

> **行为中性纪律**：所有改动只在调用**边界**加区间或设 panel；`RenderStateBuilder.make` 求值、8 个 drawXxx、渲染输出**一行不改**。make 区间**仅界定 make 求值**（计算到局部 → end → 再赋值），使 didSet/setNeedsDisplay 不计入 make（对齐 L1471 判据符号）。

- [ ] **Step 1: KLineView 加 `panel` 属性**

把 `KLineView.swift` 的 `renderState` 属性（verbatim old-string）：

```swift
    public var renderState: KLineRenderState = .empty {
        didSet {
            guard renderState != oldValue else { return }
            setNeedsDisplay()
        }
    }
```

替换为（原属性 + 紧随的 `panel` 属性）：

```swift
    public var renderState: KLineRenderState = .empty {
        didSet {
            guard renderState != oldValue else { return }
            setNeedsDisplay()
        }
    }

    /// Wave 3 13c-R1：本 view 的面板归属（上/下），由 ChartContainerView.Coordinator 设置。
    /// draw 的 os_signpost 区间按此打 upper/lower 名（PanelViewState 无上/下字段，故 draw 侧须自带）。
    public var panel: PanelId = .upper
```

- [ ] **Step 2: KLineView.draw 包区间**

`draw(_:)`（L55-56）由：

```swift
    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
```

改为（begin 前置于唯一早返 guard + defer 保证早返也闭合）：

```swift
    public override func draw(_ rect: CGRect) {
        // Wave 3 13c-R1：draw 区间（begin 前置于唯一早返 guard，defer 保证空 ctx 早返也闭合）
        let drawToken = RenderSignposter.beginDraw(panel: panel)
        defer { RenderSignposter.end(drawToken) }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
```

- [ ] **Step 3: ChartContainerView.updateUIView make 包区间（仅界定 make 求值）**

`updateUIView`（L37-41）由：

```swift
        context.coordinator.sync(panel: panel, engine: engine, view: view)
        engine.recordRenderBounds(view.bounds, panel: panel)   // D1：缓存 bounds 供 activateDrawingTool 算 range
        view.renderState = RenderStateBuilder.make(
            engine: engine, panel: panel, bounds: view.bounds,
            crosshair: context.coordinator.crosshairPoint)       // D3：透传视图层瞬态十字光标
```

改为：

```swift
        context.coordinator.sync(panel: panel, engine: engine, view: view)
        engine.recordRenderBounds(view.bounds, panel: panel)   // D1：缓存 bounds 供 activateDrawingTool 算 range
        // Wave 3 13c-R1：区间仅界定 make 求值（赋值/didSet 不计入；L1471 判据符号 = RenderStateBuilder.make）
        let makeToken = RenderSignposter.beginMake(panel: panel)
        let newState = RenderStateBuilder.make(
            engine: engine, panel: panel, bounds: view.bounds,
            crosshair: context.coordinator.crosshairPoint)       // D3：透传视图层瞬态十字光标
        RenderSignposter.end(makeToken)
        view.renderState = newState
```

- [ ] **Step 4: Coordinator.sync 设 view.panel**

`sync`（L63-66）由：

```swift
        func sync(panel: PanelId, engine: TrainingEngine, view: KLineView) {
            self.panel = panel
            self.engine = engine
            self.view = view
```

改为（加最后一行）：

```swift
        func sync(panel: PanelId, engine: TrainingEngine, view: KLineView) {
            self.panel = panel
            self.engine = engine
            self.view = view
            view.panel = panel                                    // Wave 3 13c-R1：draw 区间归属上/下
```

- [ ] **Step 5: Coordinator.attach 设初值 + setCrosshair crosshair-make 包区间**

attach（L78-79）由 `self.view = view as? KLineView` 改为：

```swift
            self.view = view as? KLineView
            self.view?.panel = panel                              // Wave 3 13c-R1：首帧前初值（sync 后续刷新）
```

setCrosshair（L117-122）由：

```swift
        private func setCrosshair(_ point: CGPoint?) {
            crosshairPoint = point
            guard let view, let engine else { return }
            view.renderState = RenderStateBuilder.make(
                engine: engine, panel: panel, bounds: view.bounds, crosshair: point)
        }
```

改为（crosshair 旁路 make 用独立名，与 update-pass make 分离）：

```swift
        private func setCrosshair(_ point: CGPoint?) {
            crosshairPoint = point
            guard let view, let engine else { return }
            // Wave 3 13c-R1：crosshair 旁路 make 用独立区间名（make-crosshair-*），与 update-pass make 分离
            let makeToken = RenderSignposter.beginMakeCrosshair(panel: panel)
            let newState = RenderStateBuilder.make(
                engine: engine, panel: panel, bounds: view.bounds, crosshair: point)
            RenderSignposter.end(makeToken)
            view.renderState = newState
        }
```

- [ ] **Step 6: host 全量 + 确认零回归**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: `Test run with 1067 tests ... passed`（0 failures；接线改动不增减测试）。

- [ ] **Step 7: Mac Catalyst build-for-testing 编译绿（UIKit 路径唯一编译验证）**

Run:
```bash
cd ios/KlineTrainer && xcodebuild build-for-testing \
  -project KlineTrainer.xcodeproj -scheme KlineTrainer \
  -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -15
```
Expected: `** TEST BUILD SUCCEEDED **`（验 `#if canImport(UIKit)` 路径 + RenderSignposter 在 Catalyst 编译）。

- [ ] **Step 8: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift
git commit -m "feat(13c-R1): 渲染热路径三调用点接线 os_signpost 区间 + KLineView.panel 归属"
```

---

## Task 3: 重写帧预算 runbook（Time Profiler 峰值相加 → os_signpost 帧归并）

**Files:**
- Rewrite: `docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md`

- [ ] **Step 1: 整文件重写**

用以下完整内容**覆盖** `docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md`：

```markdown
# 帧预算验收 Runbook — Wave 3 顺位 12（os_signpost 帧相关测量）

**日期**：2026-06-14（原）／**2026-06-16（13c-R1 重写：Time Profiler 峰值相加 → os_signpost 最坏完整帧归并）**
**性质**：device / simulator 手动执行；CLI/CI 仅编译 UIKit 不运行，帧预算测量无法自动化
**执行者**：user（非编码者可执行；Xcode + Instruments 即可，无需读懂 Swift 代码）
**覆盖范围**：Wave 3 新交互（pinch 缩放 / 绘线 / 十字光标 HUD）帧预算，补充既有 c8b runbook item #3

---

## 权威判据

**单帧 `RenderStateBuilder.make` + `KLineView.draw(_:)` 合并 < 4ms @ 120Hz**

出处：modules v1.4 **L1471**（「验收：Instruments 120Hz 单帧 <4ms；Equatable 短路生效」）/ plan v1.5 L1264。

> **行号勘误**：既有 c8b runbook item #3 引用「spec L1467」为陈旧行号，权威 = modules v1.4 **L1471**。c8b item #3 原文保留（历史完整性）。

---

## 测量方法（13c-R1：os_signpost 帧相关，替换「峰值相加」）

**为何不再用 Time Profiler 峰值相加（13c-R1 / codex R8-H1）**：Time Profiler 是采样器；分别过滤 `make` / `draw` 取峰值相加 ≠ 同一显示帧的真实合并耗时——屏上有**上/下两个图表实例**各自 make/draw，`make`（`updateUIView`）调度 `draw` 延后，一帧含最多 4 个未配对调用。峰值相加是**指示性上界**（可能高估或漏算），非严谨单帧合并。

**13c-R1 instrumentation（已 ship 2026-06-16）**：生产代码在渲染热路径加 `os_signpost` 区间（subsystem `com.klinetrainer.render`），按 panel × op 命名：

| 区间名 | 含义 |
|---|---|
| `make-upper` / `make-lower` | 上/下面板 update-pass 的 `RenderStateBuilder.make` 求值 |
| `draw-upper` / `draw-lower` | 上/下面板 `KLineView.draw(_:)` 全过程 |
| `make-crosshair-upper` / `make-crosshair-lower` | 上/下面板长按十字光标旁路 make（与 update-pass make 分离） |

区间携带精确 begin/end 时间戳（非采样），可在 Instruments 时间轴按 display frame 归并。

---

## 前置准备

1. 真机（推荐 A17 Pro / ProMotion 屏）或 Retina iPhone Simulator 构建 **Release（优化）包**（⌘I Profile 默认 Release；**勿用 Debug**——未优化虚高单帧耗时）。
2. Xcode → Product → Profile（⌘I）→ 选 **os_signpost**（Points of Interest）instrument；**并加 Core Animation / Animation Hitches** 以得 display frame 边界轴。
3. 录制前在 os_signpost detail 按 subsystem `com.klinetrainer.render` 过滤，确认上述 6 个具名 lane 可见。
4. 每场景独立录制 30 秒。

---

## 最坏完整帧判读法（每场景共用）

1. 在 Core Animation / Hitches 轨找该场景**最慢的一帧**（最长 commit / 有 hitch）。
2. 取该帧的 vsync 窗口（相邻两次 display 刷新之间）。
3. 在 os_signpost 轨读出落入该窗口的全部 `make-*` + `draw-*` 区间，**求和** = 该帧真实合并耗时：
   - 滚动 / 缩放 / 绘线场景：贡献者 = `make-upper`+`make-lower`+`draw-upper`+`draw-lower`。
   - 十字光标场景：update-pass make 通常不触发，贡献者 = 被拖动面板的 `make-crosshair-*` + `draw-*`。
4. 跨该场景所有帧取**最大合并值**作判据。

---

## 帧预算验收表

| # | 操作（action） | 预期（expected） | 通过/不通过 |
|---|---|---|---|
| 1 | os_signpost 录制 **纯水平滚动 + 惯性减速**；按「最坏完整帧判读法」取最坏帧合并 | 最坏帧 make-upper+make-lower+draw-upper+draw-lower 合并 < 4ms | 合并 < 4ms = 通过 |
| 2 | os_signpost 录制 **pinch 缩放**（双指开合 3-5 次）；同上取最坏帧 | 最坏帧合并 < 4ms | 合并 < 4ms = 通过 |
| 3 | os_signpost 录制 **水平线绘制 + 跨缩放/平移还原**（顶栏「水平线」→ 单指点击落锚 → 确认横线可见 → pinch+pan）；同上取最坏帧 | 最坏帧合并 < 4ms **且横线渲染可见** | 合并 < 4ms 且线可见 = 通过 |
| 4 | os_signpost 录制 **长按十字光标拖动**（缓慢横扫）；贡献者取 make-crosshair-* + draw-* | 最坏帧合并 < 4ms | 合并 < 4ms = 通过 |
| 5 | **Equatable 短路验证**：保持 engine 状态不变连续 updateUIView；观察 os_signpost 轨 | 无新 `draw-*` 区间（短路使 setNeedsDisplay 不触发）；frame timeline 稳定 | 无冗余 draw 区间 = 通过 |

---

## 回填信息

| 项目 | 回填值 |
|---|---|
| Device 型号 | **____** |
| iOS / iPadOS 版本 | **____** |
| 所测周期 + 该帧实际渲染蜡烛数（≥80 视为满载，见 runtime-matrix R8-H2） | **____** |
| 场景1 最坏帧 make-upper/make-lower/draw-upper/draw-lower / 合并 ms | **__**/**__**/**__**/**__** / **__** |
| 场景2 最坏帧 各贡献者 / 合并 ms | **____** / **__** |
| 场景3 最坏帧 各贡献者 / 合并 ms | **____** / **__** |
| 场景4 最坏帧 make-crosshair-*/draw-* / 合并 ms | **____** / **__** |
| 场景5 Equatable 短路 | 通过 / 未通过 |
| 实测日期 | **____** |

> **实测数值是 user device 职责 + 顺位 13 收尾阻塞依赖（runtime-matrix ③）。**

---

## Bitmap Cache 决议门

**全部场景最坏帧合并 ms < 4ms** → Phase 1 纯 draw 充分；Bitmap Cache **no-op**（outline L173）；本子项已关闭。
**任一场景最坏帧合并 ms ≥ 4ms** → 触发 `docs/governance/2026-06-14-wave3-pr12-performance-review.md` §四 决议门，引入 Bitmap Cache（独立后续 anchor），引入后须重测全场景回落 < 4ms 才可关闭。

---

## 13c-R1 残留状态

- **机制 facet（os_signpost 帧相关测量）**：本 runbook + 生产 instrumentation 已交付（2026-06-16）。
- **device facet（最坏帧 <4ms 实测）**：仍 **OPEN**（本表回填 = runtime-matrix ③ 的 device 职责）。
```

- [ ] **Step 2: 校验无「峰值相加」作权威判据残留 + 文件名指针未变**

Run:
```bash
grep -c "峰值相加" docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md
grep -c "最坏完整帧\|os_signpost\|com.klinetrainer.render" docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md
grep -Fq "2026-06-14-wave3-pr12-frame-budget.md" docs/acceptance/2026-06-14-wave3-runtime-matrix.md && echo "matrix 指针仍在(gate 谓词 3c)"
```
Expected: 「峰值相加」仅出现在「为何不再用…」解释句（计数 1，作历史对照非权威判据）；os_signpost/最坏完整帧 命中 ≥3；matrix 指针仍在。

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md
git commit -m "docs(13c-R1): 帧预算 runbook 重写 — os_signpost 最坏完整帧归并替换峰值相加近似"
```

---

## Task 4: 账本 flip（机制交付 / device OPEN；保 item-7 + gate）

**Files:**
- Modify: `docs/governance/2026-06-14-wave3-completion.md`（运行时矩阵行 caveat ①）
- Modify: `docs/acceptance/2026-06-14-wave3-runtime-matrix.md`（R8-H1 caveat addendum）
- Modify: `docs/acceptance/2026-06-14-wave3-pr13c-completion.md`（13c-R1 行前向指针）

> **纪律**：不动 WAVE3-STATUS 机器块（无 13c-R1 key；runtime-matrix 仍 PARTIAL）；不裸用 `RESOLVED` 标 13c-R1；`pr13c-completion.md` 的 13c-R1 行保 `accept residual`、绝不写 `RESOLVED`。**编辑前先 `Read` 确认精确文本再做精确 old→new。**

- [ ] **Step 1: governance completion doc — 运行时矩阵行 caveat ①**

`Read` `docs/governance/2026-06-14-wave3-completion.md` L86 行，定位子串 `①采样≠帧相关（**13c-R1，accept residual / OPEN**，根治 = os_signpost 生产 instrumentation，超 doc-only scope）`，精确替换为：

`①采样≠帧相关（**13c-R1**：机制 facet **交付 2026-06-16**——os_signpost 帧相关 instrumentation 已 ship + 帧预算 runbook 重写为最坏完整帧归并法；**device 最坏帧 <4ms 实测仍 OPEN**，归 runtime-matrix ③）`

（不触同行 `②fixture 欠载` 段；不触 WAVE3-STATUS 机器块。）

- [ ] **Step 2: runtime-matrix — R8-H1 caveat 加 addendum**

`Read` `docs/acceptance/2026-06-14-wave3-runtime-matrix.md`，定位 R8-H1 bullet 结尾子串 `临界值（接近 4ms）须以 signpost 实测复核。`，在其后**同段紧接**插入新行：

```
> **【机制交付 2026-06-16，13c-R1 fast-follow】** os_signpost 帧相关 instrumentation 已 ship（`com.klinetrainer.render` subsystem 的 make/draw per-panel 区间 + crosshair 独立名）+ 帧预算 runbook（`2026-06-14-wave3-pr12-frame-budget.md`）已重写为「最坏完整帧归并」法，替换峰值相加近似。**device 最坏帧 <4ms 实测仍 OPEN**（本节 ③ 的 device 回填职责）——本 PR 交付**机制**，不产出 device 数值。
```

（R8-H1 原 bullet 本体保留；不触 R8-H2 的 RESOLVED addendum。）

- [ ] **Step 3: pr13c-completion — 13c-R1 行加前向指针（保 accept residual / 不写 RESOLVED）**

`Read` `docs/acceptance/2026-06-14-wave3-pr13c-completion.md` L38（13c-R1 residual 行），定位该行结尾子串 `→ fast-follow perf-instrumentation PR |`，精确替换为：

`→ fast-follow perf-instrumentation PR。**【前向指针 2026-06-16】** 该 fast-follow 已交付（os_signpost 帧相关 instrumentation + runbook 重写）；本行**保持 accept residual**——机制 facet 交付，device 最坏帧 <4ms 实测仍 pending（详见 governance/runtime-matrix 账本 + 2026-06-16 设计/验收 doc）。 |`

（追加子句含 `accept residual`、**不**含 `RESOLVED`、不含大写 `13c-R1`，故 `grep "13c-R1" 该文件` 不变量逐字保全。不触 L41 收敛说明行。）

- [ ] **Step 4: 校验三不变量**

Run:
```bash
# (a) item-7：pr13c-completion 的 13c-R1 命中行均含 accept residual、均不含 RESOLVED
grep -n "13c-R1" docs/acceptance/2026-06-14-wave3-pr13c-completion.md
echo "--- 上方每行须含 accept residual、无 RESOLVED ---"
# (b) governance gate 仍 PASS
bash scripts/governance/verify-wave3-completion.sh
# (c) runtime-matrix WAVE3-STATUS runtime-matrix=PARTIAL 未被动
grep -n "runtime-matrix: PARTIAL" docs/governance/2026-06-14-wave3-completion.md
```
Expected：(a) 两命中行均见 `accept residual`、均无 `RESOLVED`；(b) `[verify-wave3-completion] PASS…`；(c) 命中 1 行。

- [ ] **Step 5: Commit**

```bash
git add docs/governance/2026-06-14-wave3-completion.md docs/acceptance/2026-06-14-wave3-runtime-matrix.md docs/acceptance/2026-06-14-wave3-pr13c-completion.md
git commit -m "docs(13c-R1): 账本 flip — 机制交付 2026-06-16 / device <4ms 仍 OPEN（保 item-7 grep + gate）"
```

---

## Task 5: 验收清单 + 最终全量验证

**Files:**
- Create: `docs/acceptance/2026-06-16-wave3-13c-r1-signpost.md`

- [ ] **Step 1: 写验收清单**

Create `docs/acceptance/2026-06-16-wave3-13c-r1-signpost.md`：

```markdown
# Wave 3 13c-R1 验收清单（os_signpost 帧相关 instrumentation）

**日期**：2026-06-16
**性质**：非编码者可执行；action / expected / pass-fail 三列。host/CI 可验项 + device-only 标注项。
**Spec**：`docs/superpowers/specs/2026-06-16-wave3-13c-r1-signpost-instrumentation-design.md`（opus 4.8 对抗性 review R1→R2→R3 APPROVE）

> **13c-R1 facet 边界**：本 PR 交付**机制 facet**（os_signpost 帧相关测量）；**device facet**（最坏帧 <4ms 实测）仍 OPEN，归 runtime-matrix ③。本清单不 claim 帧预算达标。

## host / CI 可验项

| # | 操作（action） | 预期（expected） | 通过/不通过 |
|---|---|---|---|
| 1 | `ls ios/Contracts/Sources/KlineTrainerContracts/Render/RenderSignposter.swift` | 文件存在 | ☐ Pass / ☐ Fail |
| 2 | `grep -c "make-upper\|make-lower\|make-crosshair-upper\|make-crosshair-lower\|draw-upper\|draw-lower" ios/Contracts/Sources/KlineTrainerContracts/Render/RenderSignposter.swift` | ≥ 6（6 个 per-panel×op 区间名） | ☐ Pass / ☐ Fail |
| 3 | `grep -c "RenderSignposter.begin" ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift; grep -c "RenderSignposter.begin" ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift`（`grep -c` 按文件分别计数，故分两条） | ChartContainerView 输出 `2`（beginMake + beginMakeCrosshair）、KLineView 输出 `1`（beginDraw）= 合计 3 调用点接线 | ☐ Pass / ☐ Fail |
| 4 | `grep -c "var panel: PanelId" ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift` | 1（KLineView.panel 归属属性） | ☐ Pass / ☐ Fail |
| 5 | `cd ios/Contracts && swift test 2>&1 \| tail -1` | `Test run with 1067 tests ... passed`（0 failures；含命名契约 + smoke） | ☐ Pass / ☐ Fail |
| 6 | Mac Catalyst：`cd ios/KlineTrainer && xcodebuild build-for-testing -project KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 \| tail -1` | `** TEST BUILD SUCCEEDED **` | ☐ Pass / ☐ Fail |
| 7 | `grep -c "最坏完整帧\|os_signpost" docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md` | ≥ 2（runbook 已改帧归并法） | ☐ Pass / ☐ Fail |
| 8 | `grep -n "13c-R1" docs/acceptance/2026-06-14-wave3-pr13c-completion.md` | 每命中行均含 `accept residual`、均不含 `RESOLVED`（保全 #112 item-7 grep 不变量） | ☐ Pass / ☐ Fail |
| 9 | `bash scripts/governance/verify-wave3-completion.sh` | `[verify-wave3-completion] PASS…`（gate 未被账本 flip 破坏） | ☐ Pass / ☐ Fail |
| 10 | `git diff --stat origin/main -- ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift` | 空（RenderStateBuilder 数学零改，行为中性） | ☐ Pass / ☐ Fail |

## device-only 项（runtime-matrix ③ 回填时核，非 host 可验）

| # | 操作（action） | 预期（expected） | 通过/不通过 |
|---|---|---|---|
| D1 | 真机 Release Profile，os_signpost instrument 按 `com.klinetrainer.render` 过滤 | 见 6 个具名 lane（make-upper/lower、draw-upper/lower、make-crosshair-upper/lower） | ☐ Pass / ☐ Fail（device pending） |
| D2 | 按 runbook「最坏完整帧判读法」取各场景最坏帧合并 ms | 全场景 < 4ms（或触发 Bitmap Cache 决议门） | ☐ Pass / ☐ Fail（device pending，runtime-matrix ③） |

## supersedes-note

#112 `docs/acceptance/2026-06-15-wave3-13c-r2-perf-fixture.md` item 7（断言 `grep 13c-R1 pr13c-completion.md` 均 accept residual / 无 RESOLVED）是 point-in-time 记录。本 PR 经 Task 4 Step 3 策略（13c-R1 行只追加含 `accept residual`、不含 `RESOLVED` 的前向指针子句）使该 item-7 grep 不变量**逐字仍 PASS**——故**不回改** #112 历史清单。
```

- [ ] **Step 2: 跑验收清单 host 项 1-10 自验**

Run（逐条对照预期）：
```bash
cd "$(git rev-parse --show-toplevel)"
ls ios/Contracts/Sources/KlineTrainerContracts/Render/RenderSignposter.swift
grep -c "make-upper\|make-lower\|make-crosshair-upper\|make-crosshair-lower\|draw-upper\|draw-lower" ios/Contracts/Sources/KlineTrainerContracts/Render/RenderSignposter.swift
grep -c "RenderSignposter.begin" ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift   # 期望 2
grep -c "RenderSignposter.begin" ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift            # 期望 1
grep -n "13c-R1" docs/acceptance/2026-06-14-wave3-pr13c-completion.md
bash scripts/governance/verify-wave3-completion.sh
git diff --stat origin/main -- ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift
```
Expected: 各条满足清单预期（item-7 行均 accept residual / 无 RESOLVED；gate PASS；RenderStateBuilder diff 空）。

- [ ] **Step 3: 验收清单自身无 forbidden phrases**

Run: `grep -nE "验证通过即可|看起来正常|应该没问题|should work|looks fine" docs/acceptance/2026-06-16-wave3-13c-r1-signpost.md; echo "exit=$?"`
Expected: 无输出（grep exit=1 = 无命中）。

- [ ] **Step 4: 最终全量 host + Catalyst 复跑**

Run:
```bash
cd ios/Contracts && swift test 2>&1 | tail -3
cd ../KlineTrainer && xcodebuild build-for-testing -project KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -3
```
Expected: host `... passed`（0 failures）+ Catalyst `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 5: Commit**

```bash
git add docs/acceptance/2026-06-16-wave3-13c-r1-signpost.md
git commit -m "docs(13c-R1): 验收清单（host/CI 可验 10 项 + device-only 2 项 + supersedes-note）"
```

---

## 验收判据（goal-driven 汇总）

1. `RenderSignposter` + 6 名 + 三调用点接线 + KLineView.panel → grep（验收 1-4）。
2. host 全量绿（含命名契约 + smoke）+ Catalyst 编译绿 → 验收 5-6。
3. runbook 改 os_signpost 帧归并（无峰值相加作权威判据）→ 验收 7 + Task3 Step2。
4. 账本机制交付 / device OPEN；item-7 grep 不变量 + gate 仍 PASS → 验收 8-9 + Task4 Step4。
5. 渲染行为零改动（RenderStateBuilder/drawXxx 数学零改）→ 验收 10。

---

## Self-Review（plan↔spec 覆盖）

- spec §5.1 RenderSignposter（令牌 + 6 名 + 选择器）→ Task 1。✓
- spec §5.2 三调用点 + KLineView.panel → Task 2。✓
- spec §5.3 runbook 重写 → Task 3。✓
- spec §5.4 账本三 doc flip（机制交付/device OPEN + item-7 保全）→ Task 4。✓
- spec §5.5 验收清单（含 supersedes-note + device-only 项）→ Task 5。✓
- spec §六 测试（命名契约 .description + smoke）→ Task 1 Step 1。✓
- spec 行为中性（RenderStateBuilder/drawXxx 零改）→ Task 2 纪律 + 验收 10。✓
- 类型一致性：`RenderSignposter.Token`/`name(op:panel:)`/`beginMake/beginMakeCrosshair/beginDraw`/`end(_:)` 在 Task 1 定义、Task 2 调用面一致；`Op` 三 case 与 6 名 switch 对齐。✓
- 无 placeholder：所有 code step 含完整代码；doc step 含完整文本或精确 old→new。✓
```


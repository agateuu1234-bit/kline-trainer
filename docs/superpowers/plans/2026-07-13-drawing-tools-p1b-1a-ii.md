# 划线工具扩充 P1b-1a-ii：画线状态搬家 + 全局画线会话 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把画线状态从「各面板 Coordinator 私有 + 按 activePanel 作用域」搬进引擎侧**单一真相容器** `DrawingSession`，使画线会话变成**全局**的（上下两面板都能画、提交后不退出、切下单目标面板不丢线）。

**Architecture:** 新增 `DrawingSession`（`@MainActor @Observable`，`TrainingEngine` 持有一个实例）作为 `drawingModeActive` / `activeDrawingTool` / `pendingAnchors` / `pendingAnchorPanel` 的**唯一真相**。`ChartContainerView.Coordinator` 退化为**纯消费者**：只读会话状态、把 tap 转成锚点喂回会话，**不再持有任何画线状态**、**不再在 `updateUIView` 里回写状态**。`TrainingEngine` 提供全局 `toggleDrawingMode()`，并在**每一处会把面板打回 `.autoTracking` 的动作**（`.tradeTriggered` / `.periodComboSwitched`）上**统一收口**画线会话，使不变量「`drawingModeActive` ⇔ 两面板都在 `.drawing`」**永不漂移**。

**Tech Stack:** Swift 6 / SwiftUI + UIKit（`UIViewRepresentable`）/ Observation / swift-testing（`@Test` / `#expect`）。

## Global Constraints

- **入口不变**：仍是浮动铅笔钮 `DrawingToolFloatingView`。**本期不引入任何新 UI 控件**（顶栏「画图」钮 / 两行底栏 / 设置面板全在 1a-iii）。
- **不做**：手势改动（1a-iv）、选中/编辑/删除（1b-i）、锁定/撤销（1b-ii）、退役浮动钮（1a-iii）。
- **不得回退 1a-i**：D29 周期绑定（`DrawingObject.period` ← `anchors.first.period`）与 D35 API 迁移必须保持全绿。
- **D31 只做前半**：`discardPendingAnchors()` API + 「**下一次落锚 tap 落在别的面板** → 只丢 pending 锚」触发。**不做**「周期组合实际改变 → 丢 pending」与 commit 前全锚同 period 断言（1a-iv，复用同一 API，不得另写一份取消语义）。
- **绝不能用 `cancel()` 语义丢 pending**：丢 pending 必须**保留** `activeDrawingTool` 与 `drawingModeActive`。
- **单一判据**：判断「现在能不能画」全链路只认 `engine.drawingSession.drawingModeActive`，**不得**另外再读面板 `interactionMode` 做第二重判断（两个判据 = 必然漂移，1a-i 血泪）。
- 三绿门（作者亲核）：① `cd ios/Contracts && swift test` ② `cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst'` ③ `xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator'`

---

## 本计划新增的两个决策（spec 未覆盖，实施前必须知道）

### D44：`DrawingToolManager` 在生产路径**退役为不再被调用**，pending 锚由 `DrawingSession` 自己持有

spec §3.1.1 的字面是「`DrawingToolManager` 退化为纯 pending-anchor 暂存」。但 §3.1.2（codex R31-high）随后要求 **pending 锚必须进共享容器**，两条合起来意味着「容器持有一个共享的 manager 实例，manager 只剩 pending」。**实测该写法有三处硬伤**，故本计划改由 `DrawingSession` 直接持有 pending 数组：

1. `DrawingToolManager.toggle(t)` 是 **toggle 不是 set**：`activeTool == t` 时再 toggle 会**把工具关掉**。容器要单向同步「真相 → manager」，就得在每个调用点条件判断，一处写漏即静默清空工具。
2. `DrawingToolManager` 有 `enabledTools` 闸门（现为 `[.horizontal]`）：`toggle` 对不在闸门内的工具是 **no-op**，于是 `activeTool` 仍为 `nil`，而随后的 `addAnchor` 是 **`precondition(activeTool != nil)` → 直接崩溃**。1a-iii 一加工具就踩。
3. `commit()` 会把每条线**再存一份**进 `completedDrawings`（`engine.drawings` 才是真相）——连续画线下这是一个只增不减的重复数组（双真相 + 无界增长）。

`DrawingObject` 的**唯一写入点**语义（`isExtended == (lineSubType == .ray)`，codex branch-R5）在 `DrawingSession.commitPending` 里**原样保留**，矛盾数据仍不可表达。

**`DrawingToolManager` 文件本身保留不删**：modules v1.4 §C6（已冻结）字面要求该类型存在，`SpecLiteralGuardTests` 正在守它；删它 = 改冻结的模块 spec，超出 1a-ii 范围。它变成生产路径不再调用、但契约与自有测试仍在的类型。**这是有意为之，不是遗留垃圾。**

### D45：本期「下单 / 步进即隐式退出画线会话」（user 2026-07-13 裁决）

`buy` / `sell` / `holdOrObserve` / 复盘「下一根」/「快进到结尾」都会对**两个面板**派 `.tradeTriggered`，reducer 对**任意**模式硬切 `.autoTracking`（`Reducer.swift:146-149`）；`switchPeriodCombo` 同理派 `.periodComboSwitched`（`:152-155`）。今天画线态只活一次 tap，所以看不出问题；**一旦画线会话变持久，这就是一条真漂移**：全局开关还是 true、铅笔钮还亮着，两面板却已被打回 `.autoTracking`。

母 spec §3 的终局是「画线模式下底栏换成画线工具栏」→ **画线时根本没有买卖按钮**（user 原话：「你只有退出了之后才能进行买卖」）。但底栏切换排在 **1a-iii**，本期 spec §3.2 明令不得改 UI，所以**本期屏幕上会同时存在**「画线模式」和「买卖条」。

**本期规则**：任何一次下单 / 步进 / 周期切换 → **结束整个画线会话**（`drawingModeActive=false`、工具清空、pending 丢弃、两面板 `cancelDrawing`）。等价于「替用户按了一下退出键」，正是 user 要的「先退出才能买卖」，且**用户可见行为与改造前完全一致**（今天下单也会退出画线态）。
实现上**只有一个收口点**（`endDrawingSessionIfActive()`），挂在**全部 3 处**派发上述 action 的地方（`advanceAndAccount` / `jumpToEnd` / `switchPeriodCombo`）——不是打地鼠，是让不变量在根上成立。1a-iii 底栏一换，这条路径自然不可达。

---

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift` | **新建** | D39 共享状态容器 = 画线的**唯一真相**（模式 / 工具 / pending 锚 / pending 归属面板）+ D31 `discardPendingAnchors()` + D38 提交后保留工具 |
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | 改 | 持有 `drawingSession`；新增全局 `toggleDrawingMode()` / `beginDrawingSession()` / `endDrawingSessionIfActive()`；删 `toggleDrawingExclusive`；在 3 处 mode-clobbering 派发点收口会话（D45） |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift` | 改 | Coordinator 删私有 `manager` + 删 `:107` 自动 re-arm；`sync()` 单向只读；`handleDrawingTap` 走 session；提交后**不再** `commitDrawing`（连续画线） |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` | 改 | 铅笔钮读全局 `drawingModeActive` / 调 `toggleDrawingMode()`；删 `.onChange(of: activePanel)` 里的 `cancelDrawingAllPanels()` |
| `ios/Contracts/Tests/.../Drawing/DrawingSessionTests.swift` | **新建** | 容器语义（host） |
| `ios/Contracts/Tests/.../TrainingEngineDrawingSessionTests.swift` | **新建** | 引擎接线 + 不变量（host） |
| `ios/Contracts/Tests/.../Render/ChartContainerViewDrawingSessionTests.swift` | **新建** | **两个真 Coordinator** 跨面板行为（UIKit-guarded，Catalyst 才跑） |
| `ios/Contracts/Tests/.../Drawing/DrawingSessionSourceGuardTests.swift` | **新建** | 结构守卫：re-arm 已删 / observer 不再取消画线 / 无新 UI（spec §3.3 #1 #4b #4c 字面要求） |

---

### Task 1: `DrawingSession` 共享状态容器（D39 / D42 / D31 / D38 的地基）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift`

**Interfaces:**
- Consumes: `DrawingToolType` / `DrawingAnchor` / `DrawingObject` / `LineSubType` / `PanelId`（均为既有跨平台值类型，`Models.swift`）
- Produces（后续 3 个 task 全靠它）:
  - `DrawingSession()` — `@MainActor @Observable final class`
  - `var drawingModeActive: Bool { get }`（`private(set)`）
  - `var activeDrawingTool: DrawingToolType? { get }`（`private(set)`）
  - `var pendingAnchors: [DrawingAnchor] { get }`（`private(set)`）
  - `var pendingAnchorPanel: PanelId? { get }`（`private(set)`）
  - `func activate(tool: DrawingToolType)`
  - `func deactivate()`
  - `func discardPendingAnchors()`
  - `func addAnchor(_ anchor: DrawingAnchor, panel: PanelId)`
  - `func commitPending(lineSubType: LineSubType = .straight, panelPosition: Int) -> DrawingObject?`

- [ ] **Step 1: 写失败测试**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift
// Spec: docs/superpowers/specs/2026-07-10-drawing-tools-P1b-split-addendum.md §3.1 / §3.3（1a-ii）
// D39 单一真相容器 / D42 全局会话 + 落锚归属被点击面板 / D31 只丢 pending 保工具 / D38 连续画线。
import Testing
@testable import KlineTrainerContracts

@Suite("DrawingSession：画线共享状态容器（D39/D42/D31/D38）")
@MainActor
struct DrawingSessionTests {

    private func anchor(_ price: Double, period: Period = .m3) -> DrawingAnchor {
        DrawingAnchor(period: period, candleIndex: 3, price: price)
    }

    @Test("初始：会话关、无工具、无 pending")
    func initialState() {
        let s = DrawingSession()
        #expect(s.drawingModeActive == false)
        #expect(s.activeDrawingTool == nil)
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
    }

    @Test("activate：开会话 + 置工具；同工具重复 activate 幂等且不丢 pending")
    func activateIsIdempotent() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        s.activate(tool: .horizontal)                       // 重复激活同一工具
        #expect(s.drawingModeActive == true)
        #expect(s.activeDrawingTool == .horizontal)
        #expect(s.pendingAnchors.count == 1)                // 未被误清
    }

    @Test("activate 换工具：丢 pending（旧工具的半成品不能混进新工具）")
    func switchingToolDiscardsPending() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        s.activate(tool: .trend)
        #expect(s.activeDrawingTool == .trend)
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
    }

    @Test("D31：discardPendingAnchors 只丢 pending —— 工具与会话必须存活（绝不是 cancel）")
    func discardPendingKeepsToolAndSession() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        s.discardPendingAnchors()
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
        #expect(s.activeDrawingTool == .horizontal)         // ← 保工具（cancel() 会清掉，本 API 不许）
        #expect(s.drawingModeActive == true)                // ← 保会话
    }

    @Test("D42：落锚归属 = 被点击的面板（与 activePanel 无关）")
    func anchorOwnershipFollowsTappedPanel() {
        let s = DrawingSession()
        s.activate(tool: .trend)                            // 多锚工具：pending 才留得住
        s.addAnchor(anchor(10), panel: .lower)
        #expect(s.pendingAnchorPanel == .lower)
        #expect(s.pendingAnchors.count == 1)
    }

    @Test("D31 触发：下一锚落在**别的**面板 → 只丢 pending，工具存活，新锚归新面板")
    func anchorOnOtherPanelDiscardsPendingButKeepsTool() {
        let s = DrawingSession()
        s.activate(tool: .trend)
        s.addAnchor(anchor(10), panel: .upper)
        s.addAnchor(anchor(20), panel: .lower)              // 换面板落锚
        #expect(s.pendingAnchors.count == 1)                // 上面板那个被丢；只剩新的
        #expect(s.pendingAnchors.first?.price == 20)
        #expect(s.pendingAnchorPanel == .lower)
        #expect(s.activeDrawingTool == .trend)              // ← 工具没被连带清掉
        #expect(s.drawingModeActive == true)
    }

    @Test("对照：下一锚仍在**同一**面板 → 不丢 pending（判据是落锚面板，不是 activePanel）")
    func anchorOnSamePanelKeepsPending() {
        let s = DrawingSession()
        s.activate(tool: .trend)
        s.addAnchor(anchor(10), panel: .upper)
        s.addAnchor(anchor(20), panel: .upper)
        #expect(s.pendingAnchors.count == 2)
        #expect(s.pendingAnchorPanel == .upper)
    }

    @Test("非画线模式落锚 = no-op（不可表达「没有工具却攒着 pending」）")
    func addAnchorIgnoredWhenInactive() {
        let s = DrawingSession()
        s.addAnchor(anchor(10), panel: .upper)              // 未 activate
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
    }

    @Test("D38 连续画线：commit 后只清 pending —— 工具与会话保持不变")
    func commitKeepsToolAndSession() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        let obj = s.commitPending(panelPosition: 0)
        #expect(obj != nil)
        #expect(s.pendingAnchors.isEmpty)                   // pending 清了
        #expect(s.activeDrawingTool == .horizontal)         // ← 工具还在（改造前这里会变 nil）
        #expect(s.drawingModeActive == true)                // ← 会话还在（改造前会退出画线模式）
    }

    @Test("commit 产出：D29 周期绑定 = 首锚周期；isExtended 由 lineSubType 派生（矛盾不可表达）")
    func commitProducesConsistentObject() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10, period: .m15), panel: .lower)
        let straight = s.commitPending(lineSubType: .straight, panelPosition: 1)
        #expect(straight?.period == .m15)                   // D29：跟首锚周期，不跟面板位置
        #expect(straight?.panelPosition == 1)
        #expect(straight?.isExtended == false)
        #expect(straight?.lineSubType == .straight)

        s.addAnchor(anchor(11, period: .m15), panel: .lower)
        let ray = s.commitPending(lineSubType: .ray, panelPosition: 1)
        #expect(ray?.isExtended == true)                    // 不变量：isExtended == (lineSubType == .ray)
        #expect(ray?.lineSubType == .ray)
    }

    @Test("commit 无 pending / 无工具 → nil，且不改会话状态")
    func commitWithoutPendingReturnsNil() {
        let s = DrawingSession()
        #expect(s.commitPending(panelPosition: 0) == nil)   // 未激活
        s.activate(tool: .horizontal)
        #expect(s.commitPending(panelPosition: 0) == nil)   // 激活但无锚
        #expect(s.drawingModeActive == true)
        #expect(s.activeDrawingTool == .horizontal)
    }

    @Test("deactivate：关会话 + 清工具 + 丢 pending（幂等）")
    func deactivateClearsEverything() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        s.deactivate()
        s.deactivate()                                      // 幂等
        #expect(s.drawingModeActive == false)
        #expect(s.activeDrawingTool == nil)
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter DrawingSessionTests`
Expected: **编译失败** — `cannot find 'DrawingSession' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift`：

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift
// Spec: docs/superpowers/specs/2026-07-10-drawing-tools-P1b-split-addendum.md §3.1（P1b-1a-ii）
// 母 spec: docs/superpowers/specs/2026-07-04-drawing-tools-expansion-design.md §2 / §3 / §10
//
// D39 共享状态容器：底栏（1a-iii）与 ChartContainerView.Coordinator **共同消费**的单一真相。
//   —— 状态**不得**再留在各面板 Coordinator 私有（否则 updateUIView 会撤销工具选择，codex R15-high；
//      且下面板清不掉上面板的 pending，codex R31-high）。1b-i 的 selectedDrawingID / selectedPanel 进**同一容器**。
// D42 全局画线会话：drawingModeActive **不属于任何单一面板**；上下两面板都能落锚，
//   归属由**被点击的那个面板**决定（与 activePanel＝下单目标面板**无关**）。
// D31（前半）：discardPendingAnchors() —— **只丢 pending 锚**，保留 activeDrawingTool / drawingModeActive。
// D38：commit 后**不退出**画线模式、**不清**工具 → 支持连续画。
//
// 跨平台：@MainActor + @Observable，仅依赖 Models 值类型；无 UIKit → host swift test 全覆盖。
// D44（见 plan）：pending 锚由本容器直接持有，**不再**经 DrawingToolManager（toggle 非 set / enabledTools
//   闸门会让 addAnchor 撞 precondition / completedDrawings 重复增长三处硬伤）。DrawingObject 的
//   **唯一写入点**语义（isExtended 由 lineSubType 派生）在 commitPending 内原样保留。

import Observation

@MainActor
@Observable
public final class DrawingSession {
    /// D42：全局画线会话开关。浮动钮（本期）/ 底栏「画图」钮（1a-iii）切换它。
    public private(set) var drawingModeActive: Bool = false

    /// D39：当前工具。**提交一条线后保持不变**（D38 连续画线）。
    public private(set) var activeDrawingTool: DrawingToolType?

    /// 未成形画线的锚点暂存（多锚工具用；.horizontal 落一锚即提交）。
    public private(set) var pendingAnchors: [DrawingAnchor] = []

    /// D31/D42：pending 锚的**归属面板** = 落锚时被点击的面板。**与 activePanel 无关**。
    public private(set) var pendingAnchorPanel: PanelId?

    public init() {}

    /// 进入/保持画线会话并选定工具。同工具重复调用**幂等且不丢 pending**；
    /// 换工具则丢弃旧工具的半成品锚（否则会把上一个工具的锚混进新工具）。
    public func activate(tool: DrawingToolType) {
        drawingModeActive = true
        guard activeDrawingTool != tool else { return }
        activeDrawingTool = tool
        discardPendingAnchors()
    }

    /// 结束整场画线会话：关模式 + 清工具 + 丢 pending。幂等。
    /// **唯一**「整场结束」入口（旧 DrawingToolManager.cancel() 的角色）。
    public func deactivate() {
        drawingModeActive = false
        activeDrawingTool = nil
        discardPendingAnchors()
    }

    /// D31：**只丢 pending 锚** —— activeDrawingTool 与 drawingModeActive 必须存活。
    /// 1a-iv 的「周期组合改变 → 丢 pending」复用本 API，**不得**另写一份取消语义。
    public func discardPendingAnchors() {
        pendingAnchors = []
        pendingAnchorPanel = nil
    }

    /// 落锚。D42：归属 = 被点击的面板。D31：落在 ≠ pendingAnchorPanel 的面板 →
    /// 先只丢 pending（**保工具**），再在新面板起新锚。
    /// 非画线模式 / 无工具 → no-op（fail-closed：「没有工具却攒着 pending」不可表达）。
    public func addAnchor(_ anchor: DrawingAnchor, panel: PanelId) {
        guard drawingModeActive, activeDrawingTool != nil else { return }
        if let owner = pendingAnchorPanel, owner != panel {
            discardPendingAnchors()
        }
        pendingAnchors.append(anchor)
        pendingAnchorPanel = panel
    }

    /// pending → DrawingObject。**DrawingObject 的唯一写入点**：isExtended 从 lineSubType 派生
    /// （不变量 isExtended == (lineSubType == .ray)；矛盾数据不可表达，codex branch-R5-high）。
    /// period 不传 → 由 DrawingObject.init 取 anchors.first.period（D29 周期绑定，1a-i 落地，不得回退）。
    /// revealTick 由 engine.routeDrawingCommit 盖真值。
    /// **D38：提交后只清 pending —— 工具与会话保持不变（连续画线）**。
    /// 无工具 / 无 pending → nil（caller 不得据此改会话状态）。
    public func commitPending(lineSubType: LineSubType = .straight,
                              panelPosition: Int) -> DrawingObject? {
        guard let tool = activeDrawingTool, !pendingAnchors.isEmpty else { return nil }
        let drawing = DrawingObject(
            toolType: tool,
            anchors: pendingAnchors,
            isExtended: lineSubType == .ray,
            panelPosition: panelPosition,
            revealTick: 0,
            lineSubType: lineSubType)
        discardPendingAnchors()
        return drawing
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter DrawingSessionTests`
Expected: PASS（12 个测试全绿）

- [ ] **Step 5: 全量回归 + 提交**

Run: `cd ios/Contracts && swift test`
Expected: 1538 + 12 全绿（baseline 1538 不得有新红）

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift
git commit -m "feat(drawing): DrawingSession 共享状态容器（D39/D42/D31/D38 地基）"
```

---

### Task 2: `TrainingEngine` 接线全局画线会话 + 不变量收口（D42 / D45）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`
  - 加属性 `drawingSession`（放在 `drawings` 声明附近，约 `:33` 一带）
  - 改 `switchPeriodCombo`（`:378-393`）、`jumpToEnd`（`:412-421`）、`advanceAndAccount`（`:477-486`）：末尾收口会话
  - 画线区（`:1063-1085`）：删 `toggleDrawingExclusive`，加 `toggleDrawingMode` / `beginDrawingSession` / `endDrawingSessionIfActive`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `DrawingSession`
- Produces（Task 3 / Task 4 消费）:
  - `public let drawingSession = DrawingSession()`
  - `public func toggleDrawingMode()` — 全局开/关（浮动钮唯一入口）
  - `public func endDrawingSessionIfActive()` — 结束会话 + 两面板 `cancelDrawing`（幂等）
  - **不变量**：`drawingSession.drawingModeActive == true` ⇔ 两面板 `interactionMode` 均为 `.drawing`
  - 既有保留：`cancelDrawingAllPanels()` / `isDrawingActive(on:)` / `activateDrawingTool(_:panel:)` / `routeDrawingCommit(_:)`
  - **删除**：`toggleDrawingExclusive(on:)`（按 activePanel 作用域的互斥模型已退役）

- [ ] **Step 1: 写失败测试**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift
// Spec: 2026-07-10-drawing-tools-P1b-split-addendum.md §3.1.2 / §3.3（#2 #4 #4b）+ plan D45。
// D42 全局会话（两面板同时可画、互斥模型退役）+ 不变量「drawingModeActive ⇔ 两面板 .drawing」。
import Testing
@testable import KlineTrainerContracts

@Suite("TrainingEngine × DrawingSession：全局画线会话 + 不变量")
@MainActor
struct TrainingEngineDrawingSessionTests {

    /// 不变量（本期唯一真相判据）：会话开 ⇔ 两面板都在 .drawing。
    private func assertInvariant(_ e: TrainingEngine, sourceLocation: SourceLocation = #_sourceLocation) {
        let on = e.drawingSession.drawingModeActive
        #expect(e.isDrawingActive(on: .upper) == on, sourceLocation: sourceLocation)
        #expect(e.isDrawingActive(on: .lower) == on, sourceLocation: sourceLocation)
    }

    @Test("D42：开画线模式 → **两个面板**同时进 .drawing（互斥模型已退役）")
    func toggleOnArmsBothPanels() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.drawingSession.activeDrawingTool == .horizontal)
        #expect(e.isDrawingActive(on: .upper) == true)
        #expect(e.isDrawingActive(on: .lower) == true)      // ← 改造前只有 activePanel 那一个
        assertInvariant(e)
    }

    @Test("再 toggle → 关会话 + 两面板退出 .drawing + pending 丢弃")
    func toggleOffEndsSession() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.drawingSession.addAnchor(DrawingAnchor(period: .m3, candleIndex: 1, price: 10), panel: .upper)
        e.toggleDrawingMode()
        #expect(e.drawingSession.drawingModeActive == false)
        #expect(e.drawingSession.activeDrawingTool == nil)
        #expect(e.drawingSession.pendingAnchors.isEmpty)
        assertInvariant(e)
    }

    @Test("D45：买入 → 隐式退出画线会话（不变量不漂移：不会「钮还亮着但画不了」）")
    func buyEndsDrawingSession() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.drawingSession.addAnchor(DrawingAnchor(period: .m3, candleIndex: 1, price: 10), panel: .upper)
        _ = e.buy(panel: .upper, shares: 100)
        #expect(e.drawingSession.drawingModeActive == false)
        #expect(e.drawingSession.pendingAnchors.isEmpty)
        assertInvariant(e)                                   // ← 核心：会话与面板 mode 同生同死
    }

    @Test("D45：持有/观察（复盘「下一根」同路径）→ 隐式退出画线会话")
    func holdEndsDrawingSession() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.holdOrObserve(panel: .upper)
        #expect(e.drawingSession.drawingModeActive == false)
        assertInvariant(e)
    }

    @Test("D45：切周期组合 → 隐式退出画线会话（.periodComboSwitched 同样把面板打回 autoTracking）")
    func periodSwitchEndsDrawingSession() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.switchPeriodCombo(direction: .toSmaller)
        #expect(e.drawingSession.drawingModeActive == false)
        assertInvariant(e)
    }

    @Test("endDrawingSessionIfActive 幂等：未开会话时调用不炸、不改任何状态")
    func endSessionIsIdempotent() {
        let e = TrainingEngine.preview()
        e.endDrawingSessionIfActive()
        e.endDrawingSessionIfActive()
        #expect(e.drawingSession.drawingModeActive == false)
        assertInvariant(e)
    }

    @Test("D42/#4b：切 activePanel 是纯 View 状态 —— 引擎**没有**任何按 activePanel 取消画线的 API")
    func noActivePanelScopedCancelAPI() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.drawingSession.addAnchor(DrawingAnchor(period: .m3, candleIndex: 1, price: 10), panel: .upper)
        // 切下单目标面板在 TrainingView 里只是改 @State activePanel —— 引擎不参与、pending 与会话原封不动。
        // （toggleDrawingExclusive 已删除；本测试锁死「引擎无 activePanel 语义」这一事实。）
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.drawingSession.pendingAnchors.count == 1)
        #expect(e.drawingSession.pendingAnchorPanel == .upper)
        assertInvariant(e)
    }
}
```

> **注**：`TrainingEngine.preview()` 是既有 DEBUG fixture。`activateDrawingTool` 依赖 `renderBounds(panel)` 算 candleRange，故每个测试先 `recordRenderBounds` 给两个面板有效 bounds，否则进不了 `.drawing`（`preview()` 默认 bounds 为 `.zero`）。**若实现后发现 `.drawing` 进不去，先查这里，不要改产品码。**

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingEngineDrawingSessionTests`
Expected: 编译失败 — `value of type 'TrainingEngine' has no member 'drawingSession'` / `'toggleDrawingMode'`。

- [ ] **Step 3: 写实现**

**3a.** 在 `TrainingEngine.swift` 的 `drawings` / `reviewDrawings` 属性声明附近（约 `:33` 之后）加：

```swift
    /// P1b-1a-ii D39：画线共享状态容器 —— 画线模式 / 工具 / pending 锚的**唯一真相**。
    /// 浮动钮（本期）与底栏画线工具栏（1a-iii）**共同消费**同一个实例；Coordinator 只读不存。
    /// **不变量**：`drawingSession.drawingModeActive == true` ⇔ 上下两面板 `interactionMode` 均为 `.drawing`
    /// （由 `beginDrawingSession` / `endDrawingSessionIfActive` 两个收口点维持，见 D45）。
    /// 会话是**局内瞬态**，不持久化；每局 `TrainingEngine.make` 新建 → 不会跨局泄漏。
    public let drawingSession = DrawingSession()
```

**3b.** 把画线区（`:1063-1085`，`// MARK: review-redesign Task 4：双面板划线互斥` 整段）替换为：

```swift
    // MARK: P1b-1a-ii：全局画线会话（D42；review-redesign Task 4 的「按 activePanel 互斥」模型已退役）

    /// 指定面板当前是否处于画线态（面板级 FSM 查询；**不是**「能不能画」的判据——
    /// 那个判据是唯一的 `drawingSession.drawingModeActive`）。
    public func isDrawingActive(on panel: PanelId) -> Bool {
        if case .drawing = panelState(panel).interactionMode { return true }
        return false
    }

    /// 取消两面板画线态（`cancelDrawing` 对非 drawing 态 no-op，故两次调用安全）。
    public func cancelDrawingAllPanels() {
        cancelDrawing(panel: .upper)   // 非 .drawing 态 no-op
        cancelDrawing(panel: .lower)
    }

    /// D42 浮动钮唯一入口：全局开/关画线会话（**不属于任何面板**，与 activePanel 无关）。
    public func toggleDrawingMode() {
        if drawingSession.drawingModeActive {
            endDrawingSessionIfActive()
        } else {
            beginDrawingSession(tool: .horizontal)   // 本期只有水平线（工具选择在 1a-iii）
        }
    }

    /// 开会话：置真相 + **两个面板**一起进 `.drawing`（D42：上下都能画）。
    /// 维持不变量「drawingModeActive ⇔ 两面板 .drawing」。
    public func beginDrawingSession(tool: DrawingToolType) {
        drawingSession.activate(tool: tool)
        activateDrawingTool(tool, panel: .upper)
        activateDrawingTool(tool, panel: .lower)
    }

    /// 结束会话：清真相 + 两面板退出 `.drawing`。幂等（未开会话时全 no-op）。
    /// **D45 单一收口点**：所有会把面板硬切回 `.autoTracking` 的动作（`.tradeTriggered` /
    /// `.periodComboSwitched`）末尾都调它 —— 否则「全局开关还 true、面板已被打回 autoTracking」
    /// 就是一条静默漂移（铅笔钮亮着但点图没反应）。母 spec 终局是画线模式下底栏换成画线工具栏
    /// （1a-iii）→ 那时买卖钮不存在，本路径自然不可达；本期以「下单即隐式退出画线」收敛。
    public func endDrawingSessionIfActive() {
        guard drawingSession.drawingModeActive else { return }
        drawingSession.deactivate()
        cancelDrawingAllPanels()
    }
}
```

（即：**删除** `toggleDrawingExclusive(on:)`，其余原样保留。）

**3c.** 三处 mode-clobbering 派发点末尾收口（**全部 3 处，一处不能漏**）：

`switchPeriodCombo`（`:392-393` 之后，函数末尾）：
```swift
        _ = upperPanel.reduce(.periodComboSwitched)
        _ = lowerPanel.reduce(.periodComboSwitched)
        endDrawingSessionIfActive()      // D45：面板已被打回 autoTracking → 会话必须同死，否则漂移
```

`jumpToEnd`（`:416-417` 之后，`drawdown.update(...)` 之前或之后皆可，但必须在同一函数内）：
```swift
        _ = upperPanel.reduce(.tradeTriggered)
        _ = lowerPanel.reduce(.tradeTriggered)
        resetOffsetAfterAutoTracking(.upper)
        resetOffsetAfterAutoTracking(.lower)
        endDrawingSessionIfActive()      // D45
        drawdown.update(currentCapital: currentTotalCapital)
```

`advanceAndAccount`（`:479-480` 之后；覆盖 buy / sell / holdOrObserve / stepReviewForward 全部四条路径）：
```swift
        _ = upperPanel.reduce(.tradeTriggered)
        _ = lowerPanel.reduce(.tradeTriggered)
        resetOffsetAfterAutoTracking(.upper)        // D8：autoTracking ⇒ offset==0
        resetOffsetAfterAutoTracking(.lower)
        endDrawingSessionIfActive()                 // D45
        _ = tick.advance(steps: stepsForPeriod(period(of: panel)))
        drawdown.update(currentCapital: currentTotalCapital)
        forceCloseIfEnded()
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingEngineDrawingSessionTests`
Expected: PASS（7 个）

编译若报「找不到 `toggleDrawingExclusive`」→ 是 `TrainingView.swift:82` 还在调（Task 4 才改）。**本 task 允许临时把 `TrainingView.swift:82` 改成 `engine.toggleDrawingMode()`、`:79` 改成 `engine.drawingSession.drawingModeActive` 让它编译过**（Task 4 会补齐 observer 与守卫测试）。

- [ ] **Step 5: 全量回归 + 提交**

Run: `cd ios/Contracts && swift test`
Expected: 全绿。**若 `ReducerTests` / `TrainingEngineInteractionTests` 里有断言「下单后仍在 drawing」之类的老测试红了 → 那是旧互斥模型的测试，按 D45 更新它，并在 commit message 里写明。**

```bash
git add -A && git commit -m "feat(drawing): TrainingEngine 全局画线会话 + 不变量单一收口（D42/D45）"
```

---

### Task 3: `ChartContainerView.Coordinator` 状态搬家（删 re-arm / 双面板可画 / 连续画线）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift`
  - `:59-60` 删私有 `manager`（`inputController` 保留）
  - `:98-110` `sync()` 改为单向只读
  - `:143` `onLongPress` 的 drawing 守卫改判据
  - `:194-198` `isDrawing(engine:panel:)` 改判据
  - `:256-279` `handleDrawingTap` 走 `drawingSession`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewDrawingSessionTests.swift`（**UIKit-guarded**：host `swift test` 整份跳过，Catalyst 才真跑）

**Interfaces:**
- Consumes: Task 1 `DrawingSession`、Task 2 `engine.drawingSession` / `engine.toggleDrawingMode()`
- Produces: 无新公共 API（Coordinator 内部改造）

- [ ] **Step 1: 写失败测试**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewDrawingSessionTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewDrawingSessionTests.swift
// Spec: 2026-07-10-drawing-tools-P1b-split-addendum.md §3.3（#1 #2 #3 #5）
// **必须跨两个真实 Coordinator**（codex R31-high）：只在同一个 manager 上调两次，测不出
// 「私有 pending 跨 Coordinator 不可见」这个真缺陷。
// 平台门：UIKit-only（Catalyst / 模拟器跑；macOS host swift test 整份不编译）。
#if canImport(UIKit)
import Testing
import SwiftUI
import UIKit
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("ChartContainerView × DrawingSession：全局会话 / 双面板 / 连续画线")
@MainActor
struct ChartContainerViewDrawingSessionTests {

    private let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)

    /// 造「一个 engine + 上下两个真 Coordinator（各自真 KLineView，已布局出有效 viewport）」。
    private func makeRig() -> (TrainingEngine, ChartContainerView.Coordinator, ChartContainerView.Coordinator,
                               KLineView, KLineView) {
        let engine = TrainingEngine.preview()
        let upperC = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let lowerC = ChartContainerView(panel: .lower, engine: engine).makeCoordinator()
        let upperV = KLineView(frame: bounds)
        let lowerV = KLineView(frame: bounds)
        upperC.attach(to: upperV)
        lowerC.attach(to: lowerV)
        upperC.rebuildRenderState(bounds: bounds)   // 出真 viewport（candleStep > 0）
        lowerC.rebuildRenderState(bounds: bounds)
        return (engine, upperC, lowerC, upperV, lowerV)
    }

    /// 主图区内一个可落锚的点（tapToAnchor 要求落在 mainChartFrame 内）。
    private func mainChartPoint(_ view: KLineView) -> CGPoint {
        let f = view.renderState.viewport.mainChartFrame
        return CGPoint(x: f.midX, y: f.midY)
    }

    @Test("#2 D42：上面板画一条、下面板画一条 —— 两条都提交，period 各自绑所在面板当时的周期")
    func bothPanelsCanDraw() {
        let (engine, upperC, lowerC, upperV, lowerV) = makeRig()
        engine.toggleDrawingMode()

        upperC.handleDrawingTapForTesting(at: mainChartPoint(upperV))
        lowerC.handleDrawingTapForTesting(at: mainChartPoint(lowerV))

        #expect(engine.drawings.count == 2)                       // ← 改造前：下面板那一下没反应
        #expect(engine.drawings[0].period == engine.upperPanel.period)   // D29 周期绑定
        #expect(engine.drawings[1].period == engine.lowerPanel.period)
        #expect(engine.drawings[0].panelPosition == 0)
        #expect(engine.drawings[1].panelPosition == 1)
    }

    @Test("#5 连续画线：同一面板连点三次 → 三条线；每次提交后会话与工具仍在")
    func continuousDrawing() {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)

        upperC.handleDrawingTapForTesting(at: p)
        #expect(engine.drawingSession.drawingModeActive == true)   // ← 改造前：画完一条就退出了
        #expect(engine.drawingSession.activeDrawingTool == .horizontal)
        upperC.handleDrawingTapForTesting(at: p)
        upperC.handleDrawingTapForTesting(at: p)

        #expect(engine.drawings.count == 3)
        #expect(engine.drawingSession.drawingModeActive == true)
        #expect(engine.drawingSession.activeDrawingTool == .horizontal)
        #expect(engine.drawingSession.pendingAnchors.isEmpty)      // 提交后 pending 清空
    }

    @Test("#3 D31 跨 Coordinator：上面板 pending + 下面板落锚 → 只丢 pending，工具/会话存活")
    func crossCoordinatorPendingDiscard() {
        let (engine, upperC, lowerC, upperV, lowerV) = makeRig()
        // 人造多锚工具场景：.trend 需 ≥2 锚（DefaultDrawingInputController.minAnchors 非 .horizontal
        // 恒 Int.max）→ 落一锚不会提交，pending 留得住。
        engine.beginDrawingSession(tool: .trend)
        upperC.handleDrawingTapForTesting(at: mainChartPoint(upperV))
        #expect(engine.drawingSession.pendingAnchors.count == 1)
        #expect(engine.drawingSession.pendingAnchorPanel == .upper)

        lowerC.handleDrawingTapForTesting(at: mainChartPoint(lowerV))   // 打到**另一个** Coordinator

        #expect(engine.drawingSession.pendingAnchors.count == 1)        // 上面板那个被丢，只剩下面板的新锚
        #expect(engine.drawingSession.pendingAnchorPanel == .lower)     // ← 私有 pending 时下面板清不掉上面板的
        #expect(engine.drawingSession.activeDrawingTool == .trend)      // ← 走 discardPendingAnchors，不是 cancel()
        #expect(engine.drawingSession.drawingModeActive == true)
        #expect(engine.drawings.isEmpty)                                 // 未成形，不提交
    }

    @Test("#1 D39：反复 sync/updateUIView **不改写**工具（1b-i 的类型行 toggle 不会被撤销）")
    func repeatedSyncNeverRewritesTool() {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.beginDrawingSession(tool: .trend)          // 模拟「未来底栏选了别的工具」
        for _ in 0..<5 {
            upperC.sync(panel: .upper, engine: engine, view: upperV)   // = updateUIView 反复触发
        }
        #expect(engine.drawingSession.activeDrawingTool == .trend)     // ← 改造前会被 re-arm 成 .horizontal
        #expect(engine.drawingSession.drawingModeActive == true)
    }

    @Test("#1 D39：未开会话时 sync **不会**自动武装任何工具（re-arm 已删除）")
    func syncNeverArmsToolWhenSessionOff() {
        let (engine, upperC, _, upperV, _) = makeRig()
        for _ in 0..<5 {
            upperC.sync(panel: .upper, engine: engine, view: upperV)
        }
        #expect(engine.drawingSession.drawingModeActive == false)
        #expect(engine.drawingSession.activeDrawingTool == nil)
    }

    @Test("未开会话时点图 = 不画线")
    func tapDoesNothingWhenSessionOff() {
        let (engine, upperC, _, upperV, _) = makeRig()
        upperC.handleDrawingTapForTesting(at: mainChartPoint(upperV))
        #expect(engine.drawings.isEmpty)
    }
}
#endif
```

> `handleDrawingTapForTesting` 与 `sync(panel:engine:view:)`：`handleDrawingTap` 现为 `private`，`sync` 为 internal 且带 crosshair 默认参数。Step 3 里把 `handleDrawingTap` 的可见性改为 internal 并加一个 `@testable` 可见的转发方法（见下），**不要**为测试放开 public API。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -20`
Expected: 编译失败（`handleDrawingTapForTesting` 不存在）。
（host `swift test` 对本文件是**整份跳过**——UIKit 门；这正是必须跑 Catalyst 的原因。）

- [ ] **Step 3: 写实现**

**3a.** 删私有 manager（`:57-60`），只留 inputController：

```swift
        private let arbiter = ChartGestureArbiter()
        /// P1b-1a-ii D39：画线状态**不再**由 Coordinator 私有持有 —— 真相在 `engine.drawingSession`
        /// （共享容器）。Coordinator 只做「tap → 锚点」的逆映射与投影，不存任何画线状态。
        private let inputController: DrawingInputController = DefaultDrawingInputController()
```

**3b.** `sync()` 里（原 `:98-110`）改为单向只读：

```swift
            // drawing 模式下 arbiter 截获单指 pan（spec §C7）。
            // P1b-1a-ii D39：**单向**从真相读 —— sync 绝不回写画线状态。
            // 原 `if manager.activeTool == nil { manager.toggle(.horizontal) }` 自动 re-arm 已删除：
            // 它会在**每一次** updateUIView 撤销底栏的工具选择（codex R15-high）。
            let drawing = isDrawing(engine: engine)
            if drawing && crosshairActive {                       // RFC-C：进画线模式先退黏滞光标（双向互斥，codex R5-M2）
                exitCrosshair(releaseOwnership: false)            // 本地清（view-update 期安全）
                let release = setCrosshairOwner
                DispatchQueue.main.async { release?(nil) }        // 释放共享 owner 延后到 update 后（不在 view-update 期改 @State）
            }
            arbiter.drawingMode = drawing
```

**3c.** 判据统一（原 `:194-198`）——**全局**会话，不再按面板：

```swift
        /// P1b-1a-ii D42：「现在能不能画」的**唯一判据** = 全局会话开关。
        /// **不得**再读面板 `interactionMode` 作第二判据（两个判据必然漂移；引擎侧不变量
        /// 「drawingModeActive ⇔ 两面板 .drawing」由 begin/endDrawingSessionIfActive 维持）。
        private func isDrawing(engine: TrainingEngine) -> Bool {
            engine.drawingSession.drawingModeActive
        }
```

同步改 `onLongPress`（原 `:143`）的调用点：
```swift
                    guard let engine = self.engine, !self.isDrawing(engine: engine) else { return }
```

**3d.** `handleDrawingTap`（原 `:256-279`）改为：

```swift
        /// P1b-1a-ii：drawing 模式单指点击落锚 → 投影 engine.drawings/reviewDrawings。
        /// 全链路：tapToAnchor（逆映射）→ drawingSession.addAnchor（归属=**被点的这个面板**，D42）
        ///        → shouldCommit → drawingSession.commitPending → engine.routeDrawingCommit。
        /// **不再调 engine.commitDrawing(panel:)** —— 那会退出 `.drawing`，即旧的「画一条就退出」（D38）。
        /// 测试入口：`handleDrawingTapForTesting`（internal；生产路径仍只经 arbiter.onTap）。
        func handleDrawingTapForTesting(at point: CGPoint) { handleDrawingTap(at: point) }

        private func handleDrawingTap(at point: CGPoint) {
            guard let engine, let view else { return }
            let session = engine.drawingSession
            guard session.drawingModeActive, let tool = session.activeDrawingTool else { return }
            // 空图表（candleStep==0）→ xToIndex 会 Int(NaN) 崩溃 → 守卫（spec §四 load-bearing）。
            let viewport = view.renderState.viewport
            guard viewport.geometry.candleStep > 0 else { return }
            let mapper = CoordinateMapper(viewport: viewport, displayScale: view.traitCollection.displayScale)
            let ps = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
            guard let anchor = inputController.tapToAnchor(at: point, panel: ps, mapper: mapper) else { return }
            session.addAnchor(anchor, panel: panel)          // D31：落在 ≠ pendingAnchorPanel 的面板 → 容器内部只丢 pending
            guard inputController.shouldCommit(current: session.pendingAnchors, tool: tool) else { return }
            // 本期无线型选择器（→1a-iii），新线一律 .straight。
            guard let committed = session.commitPending(panelPosition: panel == .upper ? 0 : 1) else { return }
            engine.routeDrawingCommit(committed)             // review→reviewDrawings；否则→drawings（Task 10）
            // ← 此处**故意没有** engine.commitDrawing(panel:)：连续画线（D38），会话与工具保持不变。
        }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | grep -E "Test Suite.*(passed|failed)|error:" | tail -20`
Expected: 全绿，含新 6 个测试。

Run: `cd ios/Contracts && swift test`（host 回归不得红）
Expected: 全绿。

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "feat(drawing): Coordinator 状态搬家 — 删 re-arm、双面板可画、连续画线（D39/D42/D38）"
```

---

### Task 4: `TrainingView` 接线 + 结构守卫（退役 activePanel 作用域取消路径 / 无新 UI）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（`:76-83` 谓词与 toggle；`:234-241` observer）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `engine.drawingSession` / `engine.toggleDrawingMode()`
- Produces: 无新 API

- [ ] **Step 1: 写失败测试**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift
// Spec: 2026-07-10-drawing-tools-P1b-split-addendum.md §3.3 #1 / #4b / #4c / #6。
// 结构守卫：spec 字面要求「断言某调用**不再存在**」——行为测试测不到「代码里还留着一行」，故读源码文本。
// 反踩坑（memory: acceptance grep 两坑）：先**剥掉注释行**再匹配，否则解释性注释里的字样会误判。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("1a-ii 结构守卫：re-arm 已删 / 切面板不取消画线 / 无新 UI")
struct DrawingSessionSourceGuardTests {

    /// 由本测试文件路径回推仓库根 → 读产品源码。
    /// Tests/KlineTrainerContractsTests/Drawing/<本文件> → 上溯 4 层 = ios/Contracts。
    private func source(_ relativeToContracts: String) throws -> [String] {
        let contractsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Drawing
            .deletingLastPathComponent()    // KlineTrainerContractsTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // ios/Contracts
        let url = contractsDir.appendingPathComponent(relativeToContracts)
        let text = try String(contentsOf: url, encoding: .utf8)
        // 剥注释：整行注释直接丢；行尾注释切掉（够用——本仓无「代码里带 // 的字符串字面量」在这些行上）。
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private let chartContainer = "Sources/KlineTrainerContracts/Render/ChartContainerView.swift"
    private let trainingView   = "Sources/KlineTrainerContracts/UI/TrainingView.swift"
    private let engine         = "Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift"

    @Test("#1：ChartContainerView 里**不存在** manager.toggle 自动 re-arm，也不再持有 DrawingToolManager")
    func noRearmInChartContainer() throws {
        let code = try source(chartContainer).joined(separator: "\n")
        #expect(!code.contains("manager.toggle("))
        #expect(!code.contains("DrawingToolManager("))     // Coordinator 不再私有持有暂存器
    }

    @Test("#5/D38：提交后**不再**调 engine.commitDrawing（那是「画一条就退出」）")
    func noCommitDrawingAfterTap() throws {
        let code = try source(chartContainer).joined(separator: "\n")
        #expect(!code.contains("engine.commitDrawing("))
    }

    @Test("#4b：TrainingView 的 activePanel observer **不再**取消画线；toggleDrawingExclusive 已退役")
    func activePanelObserverNoLongerCancelsDrawing() throws {
        let code = try source(trainingView).joined(separator: "\n")
        #expect(!code.contains("cancelDrawingAllPanels"))      // 切下单目标面板绝不丢线（R30-medium）
        #expect(!code.contains("toggleDrawingExclusive"))      // 按 activePanel 作用域的互斥模型已退役
        #expect(code.contains("engine.toggleDrawingMode()"))   // 改走全局会话
    }

    @Test("#4：TrainingEngine 里 toggleDrawingExclusive 已删除（互斥模型退役）")
    func engineExclusiveToggleRemoved() throws {
        let code = try source(engine).joined(separator: "\n")
        #expect(!code.contains("func toggleDrawingExclusive"))
    }

    @Test("#4c/#6：本期不引入任何新 UI —— 浮动钮仍在，且无顶栏「画图」钮 / 底栏工具栏 / 设置面板")
    func noNewDrawingUI() throws {
        let code = try source(trainingView).joined(separator: "\n")
        #expect(code.contains("DrawingToolFloatingView("))     // 入口未变（退役在 1a-iii）
        #expect(!code.contains("画图"))                        // 顶栏「画图」钮（1a-iii）
        #expect(!code.contains("DrawingToolbar"))              // 两行底栏（1a-iii）
        #expect(!code.contains("DrawingSettingsPanel"))        // 设置面板（1a-iii）
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter DrawingSessionSourceGuardTests`
Expected: `activePanelObserverNoLongerCancelsDrawing` FAIL（`cancelDrawingAllPanels` 仍在 `TrainingView.swift:240`）。
其余若已在 Task 2/3 顺带满足则 PASS——**不要**因此跳过本 task。

- [ ] **Step 3: 写实现**

`TrainingView.swift` `:76-83` 改为：

```swift
    // P1b-1a-ii D42：画线会话是**全局**的（不属于任何面板）——按钮选中态与 toggle 都读/写唯一真相
    // `engine.drawingSession`。旧的「按 activePanel 互斥」模型（toggleDrawingExclusive）已退役。
    private var isDrawingActive: Bool {
        engine.drawingSession.drawingModeActive
    }
    private func toggleDrawing() {
        engine.toggleDrawingMode()
    }
```

`:234-241` 的 observer 改为（**只删画线那一句**，买卖条那句必须留）：

```swift
        .onChange(of: activePanel) { _, _ in
            // RFC-B(codex R1-medium 修)：切分段钮(下单目标 panel)即清掉打开的买卖档位条——
            // 否则条内捕获的 strip.panel 会过期（条显示在旧 panel、成交也按旧 panel），
            // 切目标后再选档会对错 panel 下单（autosave 后不可逆）。切目标=取消未确认下单。
            tradeStrip = nil
            // P1b-1a-ii D42/R30-medium：**不再**取消画线。activePanel 是「下单目标面板」，
            // 与画线会话无关；切它不产生新落锚，故 drawingModeActive / activeDrawingTool /
            // pending 锚**全部原封保留**（丢 pending 只发生在「下一次落锚 tap 落在别的面板」时）。
        }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter DrawingSessionSourceGuardTests`
Expected: PASS（5 个）

- [ ] **Step 5: 三绿门全量 + 提交**

```bash
cd ios/Contracts && swift test                                    # ① host
cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package \
  -destination 'platform=macOS,variant=Mac Catalyst'              # ② Catalyst 真跑
xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer \
  -destination 'generic/platform=iOS Simulator'                   # ③ iOS build
```
Expected: 三条全绿。

```bash
git add -A && git commit -m "feat(drawing): TrainingView 接全局会话 + 退役 activePanel 作用域取消路径（D42）"
```

---

## 交叉路径自查表（状态/时序，1a-i 血泪教训专项）

实施完成后**逐条**核对（这是 codex 一定会挖的面）：

| # | 交叉路径 | 期望 | 由谁保证 |
|---|---|---|---|
| 1 | 反复 `updateUIView` / `sync()` | 工具与 pending 不被改写 | Task 3（re-arm 删除；sync 单向只读）+ 测试 `repeatedSyncNeverRewritesTool` |
| 2 | 切 activePanel（有 pending / 无 pending） | 会话、工具、pending **全部原封** | Task 4（observer 删 cancel）+ 守卫测试 + `noActivePanelScopedCancelAPI` |
| 3 | 下一次落锚 tap 落在**别的**面板 | **只**丢 pending，工具存活 | Task 1 `addAnchor` + Task 3 跨 Coordinator 测试 |
| 4 | 下单 / 持有 / 复盘下一根 / 快进 | 会话与两面板 mode **同生同死**（D45） | Task 2 `endDrawingSessionIfActive` 挂 `advanceAndAccount` / `jumpToEnd` |
| 5 | 切周期组合（竖滑） | 同上（画线模式下竖滑被吞 → 实际不可达；但不变量仍成立） | Task 2 挂 `switchPeriodCombo` |
| 6 | 复盘模式（reviewDrawings 路由） | 连续画线 / 双面板同样成立；线进 `reviewDrawings` 不污染 `drawings` | `routeDrawingCommit` 未改（1a-i 既有）|
| 7 | 跨局泄漏 | 每局 `TrainingEngine.make` 新建 engine → `drawingSession` 必为初值 | `public let drawingSession = DrawingSession()` |
| 8 | 空图 / 非主图区落锚 | no-op，不产生幽灵线 | `candleStep > 0` 守卫 + `tapToAnchor` 的 `mainChartFrame` 守卫（均保留）|

---

## 非程序员验收清单（真机 iPhone 15 Pro Max）

> 装机前必读 memory `project_device_testing_requires_seed_fixture`：NAS 后端未部署，**必须 seed fixture 启动**，否则必报「训练组文件不存在」——那是环境缺口，不是回归。

| # | 动作 | 预期 | 通过/不通过 |
|---|---|---|---|
| 1 | 进入训练，看整个界面 | 还是原来那个浮动铅笔钮，**没有任何新按钮** | |
| 2 | 点浮动钮进画线模式，在上半图点一下 | 画出一条线 | |
| 3 | **接着再点两下** | **又画出两条线**（改造前：画完一条就自动退出画线模式了） | |
| 4 | 还在画线模式里，**在下半面板**点一下 | 下半面板也画出一条线（改造前：另一个面板点了没反应） | |
| 5 | 看下半面板那条线，竖滑切周期让它的周期挪走 | 它跟着自己的周期走/消失（1a-i 周期绑定仍生效） | |
| 6 | 再点一次浮动钮 | 退出画线模式，点图表不再画线 | |
| 7 | 进画线模式，画一条；**点底部 [上图/下图] 分段钮切换下单目标面板** | **画线模式还在**（铅笔钮仍是「结束画线」），刚画的线还在，接着还能画（改造前：切分段钮会把画线模式踢掉） | |
| 8 | 在画线模式里**点「买入」并成交** | **自动退出画线模式**（铅笔钮变回「水平线」），买卖正常成交；想接着画就再点一次铅笔钮 | |
| 9 | 退出 App 重进、续上这一局 | 画的线全都还在 | |
| 10 | 进复盘，用浮动钮画线 | 钮的样子和点法**一字未改**；同样**能连续画、两个面板都能画** | |
| 11 | 复盘里画一条，点「下一根」 | 步进正常；**画线模式自动退出**（同第 8 条，同一条规则） | |
| 12 | 反复切周期、来回画 | 上下两个面板**永远不会同时显示同一条线** | |

> 第 8 / 11 条是本期新增的**有意行为**（D45，user 2026-07-13 裁决：「你只有退出了之后才能进行买卖」）。等 1a-iii 底栏换成画线工具栏后，画线模式下**根本不会有**买卖钮/下一根钮，这条路径自然消失。

---

## Self-Review（对照 spec §3 逐条）

| spec §3.1 / §3.3 要求 | 落点 |
|---|---|
| D39 共享容器（drawingModeActive + activeDrawingTool） | Task 1 `DrawingSession` |
| 删 `ChartContainerView.swift:107` 自动 re-arm；sync 单向 | Task 3 · 3b + 守卫测试 #1 |
| pending 锚 + `pendingAnchorPanel` 进共享容器（不得 Coordinator 私有） | Task 1（容器持有）+ Task 3（Coordinator 无状态）|
| D42 全局会话、两面板都能画、归属=被点面板 | Task 2 `beginDrawingSession`（两面板一起 arm）+ Task 3 测试 #2 |
| 退役 `toggleDrawingExclusive` | Task 2 · 3b（删除）+ 守卫测试 |
| 退役 `TrainingView:234-240` 的 `cancelDrawingAllPanels()` | Task 4 · Step 3 + 守卫测试 #4b |
| 切 activePanel：会话/工具/pending 全保留 | Task 4 + `noActivePanelScopedCancelAPI` |
| D38 连续画线（提交后不退出、工具不变） | Task 1 `commitPending` + Task 3（不再 `commitDrawing`）+ 测试 #5 |
| D31 前半：`discardPendingAnchors()` + 跨面板落锚触发；**不得用 cancel()** | Task 1 + Task 3 跨 Coordinator 测试 #3 |
| 负向测试 #3 必须跨**两个真实 Coordinator** | Task 3 `makeRig()` 造 upper/lower 两个真 Coordinator |
| #4c 不引入新 UI | Task 4 守卫测试 `noNewDrawingUI` |
| #6 三处入口仍渲染浮动钮 | Task 4 守卫（`DrawingToolFloatingView(` 仍在）+ `showsDrawingTools` 未动 |
| #7 D29/D35 回归保护 | 全量 `swift test` + `commitPending` 不传 period（仍由首锚派生）|
| §3.2 不做项（新 UI / 手势 / 选中 / 周期改变丢 pending / commit 前同 period 断言） | 全部未触碰 |

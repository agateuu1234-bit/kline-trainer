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
- **`switchPeriodCombo` 在画线会话开着时 = fail-closed no-op**（`guard !drawingSession.drawingModeActive else { return }`）。**不得**在那里「结束会话」或「丢 pending」——「周期改变 → 丢 pending」是 spec §3.2 划给 1a-iv（D32）的语义，且必须用 `discardPendingAnchors()`（保工具）而非整场取消。守卫与手势层现状一致（画线模式下竖滑本就被 `singlePanStep(drawingTakesOver:)` 吞掉、两指切周期未接线），只是把「碰巧不可达」升级为「结构上不可能」（直接调也漂不了，codex plan-R7）。
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

`buy` / `sell` / `holdOrObserve` / 复盘「下一根」/「快进到结尾」都会对**两个面板**派 `.tradeTriggered`，reducer 对**任意**模式硬切 `.autoTracking`（`Reducer.swift:146-149`）。今天画线态只活一次 tap，所以看不出问题；**一旦画线会话变持久，这就是一条真漂移**：全局开关还是 true、铅笔钮还亮着，两面板却已被打回 `.autoTracking`。

（`switchPeriodCombo` 派的 `.periodComboSwitched` 有同样的破坏力。它在画线模式下经手势**不可达**（竖滑被吞，已实证），但**「不可达」不是不变量边界**——它是 public，直接调就能漂（codex plan-R7-high）。故本期给它加一条 **fail-closed 守卫**：画线会话开着时**整个函数 no-op**。这既不结束会话、也不丢 pending（那两样分别是 D31 禁止的 / 1a-iv 的活），只是「画线时不换周期」——与用户实际能做的操作**完全一致**。1a-iv 落 D32 时删掉守卫、按 D31 正经处理。）

母 spec §3 的终局是「画线模式下底栏换成画线工具栏」→ **画线时根本没有买卖按钮**（user 原话：「你只有退出了之后才能进行买卖」）。但底栏切换排在 **1a-iii**，本期 spec §3.2 明令不得改 UI，所以**本期屏幕上会同时存在**「画线模式」和「买卖条」。

**本期规则**：任何一次下单 / 步进（buy / sell / holdOrObserve / 复盘下一根 / 快进到结尾）→ **结束整个画线会话**（`drawingModeActive=false`、工具清空、pending 丢弃、两面板 `cancelDrawing`）。等价于「替用户按了一下退出键」，正是 user 要的「先退出才能买卖」，且**用户可见行为与改造前完全一致**（今天下单也会退出画线态）。
实现上**只有一个收口点**（`endDrawingSessionIfActive()`），挂在**全部 2 处**派发 `.tradeTriggered` 的地方（`advanceAndAccount` —— 覆盖 buy/sell/holdOrObserve/stepReviewForward 四条路径 —— 与 `jumpToEnd`）——不是打地鼠，是让不变量在根上成立。1a-iii 底栏一换，这条路径自然不可达。

### D46：面板级 FSM 原语 —— **保持 public，零 API 破坏**；护栏＝DEBUG 断言 + 源码守卫（终裁）

`activateDrawingTool(_:panel:)` / `commitDrawing(panel:)` / `cancelDrawing(panel:)` / `cancelDrawingAllPanels()` 能单方面把面板推入/推出 `.drawing`，是真实的漂移杠杆。codex 在 R2-high 要求把它们降 internal，又在 R6-high / R8-high 反过来指出「降 internal = 打断 SwiftPM 包的 public 消费面，而 `@testable` 测试根本测不出这种破坏」。**两边都对，说明降访问级别这条路本身就是错的**：

- **它挡不住真正的风险**：漂移的实际来源是**包内**的 `ChartContainerView` / `TrainingView`（历史上就是它们在乱调），而 `internal` 在包内**完全可见** —— 降级一寸护栏都没多。
- **它却要付真代价**：`KlineTrainerContracts` 是 SwiftPM library product，删 `public` 就是 API 破坏；而唯一能证伪「无消费者受影响」的手段（非-`@testable` 的公共面 fixture）纯属为一个**当前并不存在**的包外消费者新建维护负担。

**终裁：本期不改任何既有 API 的访问级别（零破坏）。**不变量改由两件**真正会咬人**的东西护住：

1. **生产期 fail-closed 守卫**（`commitDrawing` / `cancelDrawing` 体内第一行）：`guard !drawingSession.drawingModeActive else { return }` —— 会话开着时，面板级退出**一律 no-op**。它在 **release 也生效**（`assert` 会被剥掉，等于没护栏，codex plan-R9-high），且对**任何**调用者生效（包内、包外 SwiftPM 消费者一视同仁）。**覆盖面严格大于访问级别**：internal 只挡包外，这条连包内乱调都挡。
2. **源码守卫**（Task 4）：`Sources/` 下除 `TrainingEngine.swift` 外**任何文件**都不得调用这三个原语 → 把「未来有人从 view 层再接一条面板级退出路径」这个**真实发生过**的回归钉死在 CI 上。

（`DrawingSession` 的 mutator 仍是 **internal** —— 那是本期**新建**的类型，从未 public 过，不存在兼容面，且它是唯一能绕开 `begin/endDrawingSession` 改会话真相的入口，必须锁死。见 codex plan-R5-high。）

### D47：codex plan review 收口 —— 10 轮，真 bug 全修；**1 条 residual 接受并 override**

**codex 挖出并已修的真问题**（本计划因此比初稿硬得多）：

| 轮次 | findings | 处置 |
|---|---|---|
| R1 | SwiftPM 先编译**全部**测试文件再套 `--filter` → 删 API 与迁移旧测试必须同 commit | 修：Task 2 · 3d 原子清理 |
| R2 | 面板级 FSM 原语是漂移窄门 | 修：生产期 fail-closed 守卫 + 源码守卫 |
| R4 | 我加的守卫会**炸我自己的中间态**（Task 2 仍有 active-session 调用者） | 修：守卫排到 Task 4（所有调用者干净之后） |
| R5 | `DrawingSession` mutator 若 public → 绕开 `begin/endDrawingSession` 改真相 | 修：只读态 public / mutator 全 internal（新类型，无兼容面） |
| R6 | 在 `switchPeriodCombo` 里结束会话 = 提前实现 1a-iv 的 D32，且用了 D31 禁止的整场取消语义 | 修：改 fail-closed no-op |
| R7 | 「手势不可达」不是不变量边界（API 可直接调） | 修：守卫 + 直接调 API 的测试 |
| R9 | ① `assert` 在 release 被剥掉 = 没护栏 ② **`beginDrawingSession` 非事务性**：先置会话再武装面板，武装失败即「铅笔亮着但画不了」的卡死态 | 修：① `assert`→生产期 `guard` ② commit-last + 回滚 + 零/单侧 bounds 测试 |

**R10 residual（接受 + override，不再改）**：codex 主张「保留 public 的 legacy 原语 + fail-closed 守卫」对**包外 SwiftPM 消费者**是「行为破坏陷阱」，要求做 deprecation 仪式或非-`@testable` 公共面兼容测试。

**不采纳，理由**：
1. **那个消费者不存在**。`KlineTrainerContracts` 的消费者只有本仓 App target 与测试（`grep` 实证零命中）；这是单 App 私有仓，不是对外发布的库。为一个假想消费者建 deprecation + 公共面 fixture 的维护负担，正是 CLAUDE.md §2 禁止的投机复杂度。
2. **codex 在这条轴上自相矛盾地转了三圈**：R2 要求降 internal → R6/R8 反对降 internal（破坏兼容）→ R9 要求生产期守卫 → R10 又说生产期守卫是陷阱。每一轮都在攻击上一轮自己开的药方，已无收敛迹象（对照 memory: `feedback_codex_round6_self_contradiction`）。
3. **真实风险已被更强的手段覆盖**：包内漂移（**唯一真实发生过**的那种）被生产期 fail-closed 守卫 + 源码守卫 + 不变量测试三重钉死，覆盖面严格大于任何访问级别方案。

按项目守则如实记录：**codex 未 approve；verdict = needs-attention；本条为已接受 residual，走 override 收口。**

### D48：whole-branch codex 收口（5 轮）—— 4 个真 bug 全修；**R5 legacy 公共 API 兼容性 residual 接受 + override**

| 轮次 | finding | 处置 |
|---|---|---|
| R1 | ① `cancelDrawingAllPanels()` 在会话真开着时**静默 no-op**（名不副实的公共 API）② `activateDrawingTool` 能把面板武装成 `.drawing` 却不开会话 → **裂脑**（点了没反应、该面板还平移不了） | **修**：面板级原语收进 `armPanelForDrawing`（internal）；公共 `activateDrawingTool` 委托全局会话；`cancelDrawingAllPanels` 改为「整场收干净」，永不 no-op |
| R2 | **本分支自己弄丢的闸门**：旧 `DrawingToolManager(enabledTools:[.horizontal])` 被新容器丢掉 → 可用**未实现工具**（`.trend` 等，`shouldCommit` 恒 `Int.max` 锚）开会话 → **点一辈子画不出线、只能取消** | **修**：`DrawingToolType.implemented` 单一清单（`minAnchors` 与入口守卫都读它，杜绝两处漂移）+ 入口 **fail-closed** |
| R3 | 上一轮的守卫**把失败面挪了位**：既有公共序列 `activateDrawingTool → commitDrawing/cancelDrawing` 撞守卫 no-op → **永久卡死在画线模式出不来** | **修**：会话开着时，面板级「退出画线」**语义上就等于结束整场会话** → 路由到 `endDrawingSessionIfActive()`；会话没开则保持原面板级 FSM 语义 |
| R4 | **连续画线**把一条老路径变成真实可达：`.drawing` 吞 `.offsetApplied` → 画线期间转屏/resize 的 offset 归一被吞 → 退出后 bounds 没再变、归一永不补跑 → 图表持续挂 **overscroll 间隙** | **修**：归一抽成 `normalizeOffsetForCurrentBounds`，会话结束时补跑（已 mutation 验证：去掉即红，offset=300 vs maxOffset=177.5） |

**R5 residual（接受 + override，不再改）**：codex 主张「公共 `activateDrawingTool` 对未实现工具 fail-closed = 静默 no-op = 对包外 SwiftPM 消费者的兼容性陷阱」，建议改为「legacy-arm 未实现工具」或做 deprecation/契约版本迁移。

**不采纳，理由（三条，逐条可证伪）**：
1. **它与自己 R2 的要求直接矛盾，且新方案更差**：R2 明确要求「fail closed at the public session entry points: only allow `.horizontal`」，我照做；R5 又说这个 fail-closed 是陷阱，建议 legacy-arm 未实现工具 —— 那**正好把 R2 判定为 high 的 bug 原样装回去**（进得去、画不出、只能取消）。**静默 no-op 严格优于卡死会话**。
2. **那个消费者不存在**：`grep` 实证包外零调用（App target 与 Persistence 模块均无）；本仓是单 App 私有仓，不是对外发布的库。为不存在的消费者做 deprecation + 非-`@testable` 公共面 fixture，是 CLAUDE.md §2 禁止的投机复杂度。
3. **App 内不可达**：唯一的画线入口是浮动铅笔钮 → `toggleDrawingMode()` → `beginDrawingSession(.horizontal)`。**没有任何 UI 能选中未实现工具**；1a-iii 引入类型行时，工具会连同真实提交阈值一起落地（届时 `implemented` 扩容，这条守卫自然放行）。

按项目守则如实记录：**codex 未 approve；verdict = needs-attention；本条为已接受 residual，走 override 收口。**（同 plan 阶段 D47 的 R10 —— 是同一条轴上的第 2 次复述。）

---

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift` | **新建** | D39 共享状态容器 = 画线的**唯一真相**（模式 / 工具 / pending 锚 / pending 归属面板）+ D31 `discardPendingAnchors()` + D38 提交后保留工具 |
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | 改 | 持有 `drawingSession`；新增全局 `toggleDrawingMode()` / `beginDrawingSession()` / `endDrawingSessionIfActive()`；删 `toggleDrawingExclusive`；在 3 处 mode-clobbering 派发点收口会话（D45） |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift` | 改 | Coordinator 删私有 `manager` + 删 `:107` 自动 re-arm；`sync()` 单向只读；`handleDrawingTap` 走 session；提交后**不再** `commitDrawing`（连续画线） |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` | 改 | 铅笔钮读全局 `drawingModeActive` / 调 `toggleDrawingMode()`；`.onChange(of: activePanel)` 里的 `cancelDrawingAllPanels()` **删除**（切下单目标面板不再取消画线）|
| `ios/Contracts/Tests/.../TrainingEngineDrawingCommitTests.swift` | 改 | 删旧「按 activePanel 互斥」测试（Task 2 删 3 个 `toggleDrawingExclusive_*`；Task 4 删 `cancelDrawingAllPanels_clearsBoth`）——**必须与删 API 同步**，否则整包编译不过（codex plan-R1）|
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
  - `public final class DrawingSession` — `@MainActor @Observable`
  - **只读态（public）**：`drawingModeActive: Bool` / `activeDrawingTool: DrawingToolType?` /
    `pendingAnchors: [DrawingAnchor]` / `pendingAnchorPanel: PanelId?`（全部 `public private(set)`）
  - **mutator（一律 internal，无 `public`；codex plan-R5-high）**：`activate(tool:)` / `deactivate()` /
    `discardPendingAnchors()` / `addAnchor(_:panel:)` / `commitPending(lineSubType:panelPosition:) -> DrawingObject?`
    —— 包外**不可**直接改会话（否则绕开 `beginDrawingSession`/`endDrawingSessionIfActive`，重新造出漂移）；
    包内合法调用者只有 `TrainingEngine`（开关）与 `ChartContainerView.Coordinator`（落锚/提交），由 Task 4 守卫钉死。

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

/// **访问级别是 load-bearing 的（codex plan-R5-high）**：类与**状态**是 `public`（只读，`private(set)`），
/// 但**所有 mutator 一律 internal**（`activate` / `deactivate` / `addAnchor` / `discardPendingAnchors` /
/// `commitPending` 前面**没有** `public`，别手贱加上）。理由：`TrainingEngine.drawingSession` 是 `public let`，
/// 若 mutator 也 public，包外任何 client 都能 `engine.drawingSession.deactivate()` —— 绕过
/// `beginDrawingSession` / `endDrawingSessionIfActive` 这两个**唯一会同时更新两个面板 reducer** 的入口，
/// 于是「会话关了但面板还在 .drawing」/「会话开着但面板是 autoTracking」**又回来了**，正是本期要消灭的漂移。
/// 包内调用者只有两个：`TrainingEngine`（会话开关）与 `ChartContainerView.Coordinator`（落锚/提交），
/// 均由 Task 4 的源码守卫钉死；测试经 `@testable import` 照常可调。
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
    func activate(tool: DrawingToolType) {
        drawingModeActive = true
        guard activeDrawingTool != tool else { return }
        activeDrawingTool = tool
        discardPendingAnchors()
    }

    /// 结束整场画线会话：关模式 + 清工具 + 丢 pending。幂等。
    /// **唯一**「整场结束」入口（旧 DrawingToolManager.cancel() 的角色）。
    func deactivate() {
        drawingModeActive = false
        activeDrawingTool = nil
        discardPendingAnchors()
    }

    /// D31：**只丢 pending 锚** —— activeDrawingTool 与 drawingModeActive 必须存活。
    /// 1a-iv 的「周期组合改变 → 丢 pending」复用本 API，**不得**另写一份取消语义。
    func discardPendingAnchors() {
        pendingAnchors = []
        pendingAnchorPanel = nil
    }

    /// 落锚。D42：归属 = 被点击的面板。D31：落在 ≠ pendingAnchorPanel 的面板 →
    /// 先只丢 pending（**保工具**），再在新面板起新锚。
    /// 非画线模式 / 无工具 → no-op（fail-closed：「没有工具却攒着 pending」不可表达）。
    func addAnchor(_ anchor: DrawingAnchor, panel: PanelId) {
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
    func commitPending(lineSubType: LineSubType = .straight,
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
  - 改 `jumpToEnd`（`:412-421`）与 `advanceAndAccount`（`:477-486`）：末尾收口会话（**`switchPeriodCombo` 不动**，见 3c）
  - 画线区（`:1063-1085`）：删 `toggleDrawingExclusive`，加 `toggleDrawingMode` / `beginDrawingSession` / `endDrawingSessionIfActive`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `DrawingSession`
- Produces（Task 3 / Task 4 消费）:
  - `public let drawingSession = DrawingSession()`
  - `public func toggleDrawingMode()` — 全局开/关（浮动钮唯一入口）
  - `public func beginDrawingSession(tool:)` / `public func endDrawingSessionIfActive()`（幂等）
  - **不变量**：`drawingSession.drawingModeActive == true` ⇔ 两面板 `interactionMode` 均为 `.drawing`
  - 既有保留（**public 不变**）：`isDrawingActive(on:)`（只读查询）/ `routeDrawingCommit(_:)`
  - **访问级别一律不动**（D46 终裁）：`activateDrawingTool(_:panel:)` / `commitDrawing(panel:)` /
    `cancelDrawing(panel:)` / `cancelDrawingAllPanels()` **保持 public**，本期**不做任何 API 破坏**。
    它们能单方面把面板推入/推出 `.drawing`，但**访问级别根本挡不住真正的风险**——漂移来自**包内**
    （`ChartContainerView` / `TrainingView`），而 internal 在包内一样可见。真正生效的护栏是
    **DEBUG 不变量断言 + 源码守卫**（Task 2 · 3b-2 / Task 4 守卫测试）。
  - **删除**：`toggleDrawingExclusive(on:)`（按 activePanel 作用域的互斥模型已退役）

- [ ] **Step 1: 写失败测试**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift
// Spec: 2026-07-10-drawing-tools-P1b-split-addendum.md §3.1.2 / §3.3（#2 #4 #4b）+ plan D45。
// D42 全局会话（两面板同时可画、互斥模型退役）+ 不变量「drawingModeActive ⇔ 两面板 .drawing」。
import CoreGraphics        // CGRect（本包不 re-export CoreGraphics；漏了整包编译不过，codex plan-R2-medium）
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

    // ⚠️ 这两个测试**必须**用 `engineMultiPeriod()`，**不能**用 `TrainingEngine.preview()`：
    // preview 的 allCandles 只有 .m3/.m60/.daily（**没有 .m15**），当前组合 (.m60,.daily) 无论
    // toSmaller（→ 需 .m15）还是 toLarger（→ 需 .weekly）都会撞 switchPeriodCombo 的「target 周期无数据 → no-op」
    // 守卫 → **加不加画线守卫都 no-op**，测试恒绿 = 假守卫，什么也没测到。
    // engineMultiPeriod() 备了 .m15/.m60/.daily，(.m60,.daily) --toSmaller--> (.m15,.m60) 是能真切成功的。

    @Test("codex plan-R7：**直接调** switchPeriodCombo（绕过手势）在画线时是 no-op —— 不变量结构上破不了")
    func periodSwitchIsNoOpWhileDrawing() {
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        let upBefore = e.upperPanel.period            // .m60
        let lowBefore = e.lowerPanel.period           // .daily
        e.beginDrawingSession(tool: .trend)
        e.drawingSession.addAnchor(DrawingAnchor(period: upBefore, candleIndex: 1, price: 10), panel: .upper)

        e.switchPeriodCombo(direction: .toSmaller)    // 直接调（不经手势）；无守卫时这里会真切成 (.m15,.m60)

        #expect(e.upperPanel.period == upBefore)      // 周期没变（fail-closed no-op）
        #expect(e.lowerPanel.period == lowBefore)
        #expect(e.drawingSession.drawingModeActive == true)      // 会话没被取消（不是 cancel 语义，D31）
        #expect(e.drawingSession.activeDrawingTool == .trend)    // 工具还在
        #expect(e.drawingSession.pendingAnchors.count == 1)      // pending 没丢（丢 pending 是 1a-iv 的 D32）
        assertInvariant(e)                                       // 两面板仍 .drawing —— 没被 .periodComboSwitched 打回
    }

    @Test("对照（防假绿）：**退出**画线后切周期恢复正常 —— 守卫不是把功能焊死")
    func periodSwitchWorksAfterLeavingDrawing() {
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()          // 开
        e.toggleDrawingMode()          // 关
        e.switchPeriodCombo(direction: .toSmaller)
        #expect(e.upperPanel.period == .m15)          // 真的切了（证明上一个测试的 no-op 是守卫造成的）
        #expect(e.lowerPanel.period == .m60)
        assertInvariant(e)
    }

    @Test("codex plan-R6：手势层同样切不了周期（画线吞竖滑）；1a-iv 放开 D32 时本测试变红")
    func periodSwitchUnreachableWhileDrawing() {
        // 切周期的**唯一**产生条件（见 GestureClassifiersTests:407-420）：phase == .ended
        // + lifecycle == .verticalRejected + 净竖移 >= 40。用这个精确形状造，否则测的是空气。
        let swipeUp = CGPoint(x: 0, y: -50)

        // 画线模式：drawingTakesOver 分支的每个 return 都 periodSwipe == nil（GestureClassifiers.swift:113-121）
        let drawing = singlePanStep(phase: .ended, cumulative: swipeUp, velocityX: 0,
                                    lifecycle: .verticalRejected, lastTranslationX: 0,
                                    drawingTakesOver: true)
        #expect(drawing.periodSwipe == nil,
                "画线模式下竖滑不得切周期。若本条变红 = 1a-iv 的 D32 放开了竖滑 → 必须按 D31 用 discardPendingAnchors() 处理 pending，并同步维护「会话 ⇔ 两面板 .drawing」不变量，不许静默漂移")

        // 对照（防假绿）：非画线模式下**同样**的手势确实会切周期 —— 证明上面的 nil 不是参数造错造出来的
        let normal = singlePanStep(phase: .ended, cumulative: swipeUp, velocityX: 0,
                                   lifecycle: .verticalRejected, lastTranslationX: 0,
                                   drawingTakesOver: false)
        #expect(normal.periodSwipe == .up)
    }

    @Test("codex plan-R9：零 render bounds（首帧未布局）下开会话 —— 不变量仍成立，绝不出现「钮亮着但画不了」")
    func beginSessionWithZeroBoundsKeepsInvariant() {
        let e = TrainingEngine.preview()          // 故意**不**调 recordRenderBounds → bounds 全是 .zero
        e.toggleDrawingMode()
        // 事务性：要么两面板都进 .drawing 且会话开；要么全都没开。**不允许**一半一半。
        assertInvariant(e)
        if e.drawingSession.drawingModeActive {
            #expect(e.drawingSession.activeDrawingTool == .horizontal)
        } else {
            #expect(e.drawingSession.activeDrawingTool == nil)   // 回滚干净：工具不残留
            #expect(e.drawingSession.pendingAnchors.isEmpty)
        }
    }

    @Test("codex plan-R9：只有一个面板有 render bounds —— 同样不许出现半开状态")
    func beginSessionWithOneSidedBoundsKeepsInvariant() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)   // 只给上面板
        e.toggleDrawingMode()
        assertInvariant(e)                        // 会话开 ⇔ **两个**面板都在 .drawing
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
    /// 唯一调用者是 `endDrawingSessionIfActive()`（`TrainingView` 那处已在 3d 删除）。
    /// **保持 public（D46：不做 API 破坏）**；「不得在会话开着时单独调它」由 `cancelDrawing` 里的
    /// DEBUG 断言 + Task 4 源码守卫保证，而不是靠访问级别（internal 在包内照样可见，挡不住真正的漂移源）。
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

    /// 开会话：**两个面板**一起进 `.drawing`（D42：上下都能画）+ 置真相。
    /// **事务性（commit-last，codex plan-R9-high）**：先武装两个面板，**两个都真的进了 `.drawing` 才**置
    /// `drawingModeActive`；有任何一个没进（`activateDrawingTool` 依赖 `renderBounds`/reducer 态，
    /// 理论上可能不生效）→ **回滚**，绝不留下「铅笔钮亮着、点图却没反应」的卡死态。
    /// 顺序不能反：先置真相再武装，中间一旦失败就是坏状态；先武装再置真相，失败时干净回滚。
    public func beginDrawingSession(tool: DrawingToolType) {
        activateDrawingTool(tool, panel: .upper)
        activateDrawingTool(tool, panel: .lower)
        guard isDrawingActive(on: .upper), isDrawingActive(on: .lower) else {
            cancelDrawingAllPanels()          // 回滚（此刻会话仍未开 → fail-closed 守卫放行）
            drawingSession.deactivate()       // 幂等；确保工具/pending 不残留
            return
        }
        drawingSession.activate(tool: tool)   // 两面板都武装好了，才认会话开启
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

**3b-2. 面板级 FSM 原语：访问级别不动，靠断言 + 源码守卫护栏（D46 终裁）。**

`activateDrawingTool(_:panel:)` / `commitDrawing(panel:)` / `cancelDrawing(panel:)` 都能**单方面**把面板推入/推出 `.drawing`，是真实的漂移杠杆。但**降 internal 解决不了这个问题**：漂移的实际来源是**包内**的 `ChartContainerView` / `TrainingView`，而 internal 在包内完全可见——降级只是把 API 破坏的代价付了，护栏一寸没多。

**故：三个函数（以及 `cancelDrawingAllPanels()`）全部保持 `public` 原样，本期零 API 破坏。**护栏改由两件真正生效的东西提供：

1. **DEBUG 不变量断言**（Task 4 · 3d 加，**不能现在加**——codex plan-R4-high：此刻 `ChartContainerView` 仍在调 `engine.commitDrawing(panel:)`（Task 3 才删）、`TrainingView` 仍在调 `cancelDrawingAllPanels()`（本 task 3d 才删），提前加断言会让中间那个 commit 在 DEBUG 下必炸）。
2. **源码守卫**（Task 4）：`Sources/` 下**除 `TrainingEngine.swift` 自己**外，任何文件都不得调用这三个原语——把「未来有人从 view 层再接一条面板级退出路径」钉死在 CI 上。

**3c.** 三处 mode-clobbering 派发点末尾收口（**全部 3 处，一处不能漏**）：

`switchPeriodCombo`（`:378`，**函数体第一行**）：加**fail-closed 守卫**（codex plan-R6 + R7 的合解）：

```swift
    public func switchPeriodCombo(direction: PeriodDirection) {
        // P1b-1a-ii：画线会话开着时切周期 = **no-op**（fail-closed，codex plan-R7-high）。
        // 为什么不是「结束会话」也不是「丢 pending」：
        //   · `.periodComboSwitched` 会把两面板硬切 `.autoTracking`（Reducer:152-155）→ 若放行，会话还开着
        //     而面板已 autoTracking = 本期要消灭的漂移；且 pending 锚会绑在一个刚变过的周期组合上。
        //   · 但「周期改变 → 丢 pending」是 spec §3.2 **明确划给 1a-iv（D32）** 的语义，且必须用
        //     `discardPendingAnchors()`（保工具）而非整场取消 —— 本期不得提前实现。
        //   · 故本期取**最小且不可漂移**的一档：画线时干脆不换周期。这与手势层现状**完全一致**——
        //     `singlePanStep(drawingTakesOver:)` 的每个 return 都 `periodSwipe: nil`
        //     （GestureClassifiers.swift:113-121），两指切周期未接线 → 真实用户本来就切不动。
        //     守卫只是把「碰巧不可达」升级成「**结构上不可能**」（直接调也漂不了）。
        // 1a-iv 落 D32 时**删掉这条守卫**，改按 D31 用 discardPendingAnchors() + 维护会话不变量。
        guard !drawingSession.drawingModeActive else { return }
        ...（其余原样不动，含末尾两句 reduce(.periodComboSwitched)）
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

**3d. 同步迁移所有会被「删 API」打断编译的调用点（codex plan-R1-medium：SwiftPM 会先编译**全部**测试文件再套 `--filter`，任何一处残留引用都会让下面的 checkpoint 编译失败）。**

必须在**本步之内**一起改完，否则 Step 4 跑不起来：

**本步是原子的**：`cancelDrawingAllPanels` 的所有外部调用者必须与「删 API / 降 private」在**同一个 commit**内一起清掉，中间不留任何「会话开着却能把面板打回 autoTracking」的坏状态（codex plan-R4-high）。

（i）`ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift:221-255` —— 删掉**整段 4 个** `@Test`（`toggleDrawingExclusive_activatesSelectedPanelOnly` / `toggleDrawingExclusive_switchingPanels_cancelsOther` / `toggleDrawingExclusive_secondTapSamePanel_togglesOff` / `cancelDrawingAllPanels_clearsBoth`），替换为一段交代去向的注释：

```swift
    // MARK: - P1b-1a-ii D42：「按 activePanel 双面板互斥」模型已退役
    // 旧的 toggleDrawingExclusive 三连测试（激活选中面板 / 切面板取消另一面板 / 同面板二次点击 toggle off）
    // 与 cancelDrawingAllPanels_clearsBoth 随该模型一并删除：
    //   · 画线会话现在是**全局**的 —— 开 = **两面板一起**进 .drawing，不存在「另一面板被取消」这回事；
    //   · cancelDrawingAllPanels 的唯一调用者已是 endDrawingSessionIfActive（会话收口点），不再单独直呼。
    // 等价且更强的覆盖（含「会话 ⇔ 两面板 mode」不变量断言）见 TrainingEngineDrawingSessionTests。
```

（ii）`ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` —— **两处一起改**：

`:78-83` 铅笔钮接全局会话：
```swift
    private var isDrawingActive: Bool {
        engine.drawingSession.drawingModeActive
    }
    private func toggleDrawing() {
        engine.toggleDrawingMode()
    }
```

`:234-241` observer **删掉 `engine.cancelDrawingAllPanels()` 那一句**（买卖条那句必须留；完整替换代码见 Task 4 · Step 3b，此处按同样内容改）。

（iii）自检：
```bash
grep -rn "toggleDrawingExclusive" ios/Contracts/Sources ios/Contracts/Tests   # → 必须零命中（API 已删）
grep -rn "cancelDrawingAllPanels" ios/Contracts/Sources ios/Contracts/Tests   # → 只剩 TrainingEngine.swift 内 2 处（public 定义 + endDrawingSessionIfActive 调用）
```
（`cancelDrawingAllPanels` **保持 public**，不降级——D46：访问级别挡不住包内漂移，护栏是断言 + 源码守卫。）

> 注：`activateDrawingTool(_:panel:)` / `commitDrawing(panel:)` / `cancelDrawing(panel:)` **访问级别一律不动、保持 public**
> （D46 终裁：零 API 破坏；护栏＝生产期 fail-closed 守卫 + 源码守卫）。`TrainingEngineDrawingHandlerH1Tests` /
> `TrainingEngineInteractionTests` / `TrainingEnginePanLinkageTests` / `TrainingEngineDrawingCommitTests` 仍用它们
> 测面板级 FSM，**一行都不用改**（这些测试调用时会话未开，守卫恒放行）。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingEngineDrawingSessionTests`
Expected: PASS（7 个）。**整包必须先编译通过**——若报 `toggleDrawingExclusive` / `cancelDrawingAllPanels` 找不到，说明 3d 有遗漏调用点。

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

    /// ios/Contracts 目录（由本测试文件路径回推：Tests/KlineTrainerContractsTests/Drawing/<本文件> → 上溯 4 层）。
    private var contractsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Drawing
            .deletingLastPathComponent()    // KlineTrainerContractsTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // ios/Contracts
    }

    /// 读源码并**剥掉注释**后返回。
    /// 反踩坑（memory: acceptance grep 两坑）：不剥注释的话，「解释这行为什么删掉」的注释本身
    /// 会命中断言字样 → 假红/假绿。整行注释丢弃；行尾 `//` 之后截断。
    private func source(relativeURL url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }

    private func source(_ relativeToContracts: String) throws -> String {
        try source(relativeURL: contractsDir.appendingPathComponent(relativeToContracts))
    }

    private let chartContainer = "Sources/KlineTrainerContracts/Render/ChartContainerView.swift"
    private let trainingView   = "Sources/KlineTrainerContracts/UI/TrainingView.swift"
    private let engine         = "Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift"

    @Test("#1：ChartContainerView 里**不存在** manager.toggle 自动 re-arm，也不再持有 DrawingToolManager")
    func noRearmInChartContainer() throws {
        let code = try source(chartContainer)
        #expect(!code.contains("manager.toggle("))
        #expect(!code.contains("DrawingToolManager("))     // Coordinator 不再私有持有暂存器
    }

    @Test("#5/D38：提交后**不再**调 engine.commitDrawing（那是「画一条就退出」）")
    func noCommitDrawingAfterTap() throws {
        let code = try source(chartContainer)
        #expect(!code.contains("engine.commitDrawing("))
    }

    @Test("#4b：TrainingView 的 activePanel observer **不再**取消画线；toggleDrawingExclusive 已退役")
    func activePanelObserverNoLongerCancelsDrawing() throws {
        let code = try source(trainingView)
        #expect(!code.contains("cancelDrawingAllPanels"))      // 切下单目标面板绝不丢线（R30-medium）
        #expect(!code.contains("toggleDrawingExclusive"))      // 按 activePanel 作用域的互斥模型已退役
        #expect(code.contains("engine.toggleDrawingMode()"))   // 改走全局会话
    }

    @Test("#4b 强化：切 activePanel 的 observer 里**一个 engine 调用都不许有**（codex plan-R4）")
    func activePanelObserverTouchesNoEngineState() throws {
        let code = try source(trainingView)
        // 取 `.onChange(of: activePanel)` 到该闭包结束（首个「8 空格 + }」）之间的块。
        guard let start = code.range(of: ".onChange(of: activePanel)") else {
            Issue.record("找不到 activePanel observer —— 它被改名/删了？"); return
        }
        let rest = code[start.upperBound...]
        guard let end = rest.range(of: "\n        }") else {
            Issue.record("activePanel observer 闭包边界解析失败（缩进变了？）"); return
        }
        let block = String(rest[..<end.lowerBound])
        // 切「下单目标面板」纯属 View 侧状态：只许清买卖条（tradeStrip = nil），
        // 不许碰引擎任何状态 —— 画线会话/工具/pending 一律原封（D42 / R30-medium）。
        #expect(!block.contains("engine."), "activePanel observer 不得触碰引擎状态，实际内容：\(block)")
        #expect(block.contains("tradeStrip = nil"))            // 买卖条那条必须留（RFC-B）
    }

    @Test("#4：TrainingEngine 里 toggleDrawingExclusive 已删除（互斥模型退役）")
    func engineExclusiveToggleRemoved() throws {
        let code = try source(engine)
        #expect(!code.contains("func toggleDrawingExclusive"))
    }

    @Test("codex plan-R5-high：DrawingSession 的 mutator 一个都不许是 public（包外不得直接改会话）")
    func drawingSessionMutatorsAreNotPublic() throws {
        let code = try source("Sources/KlineTrainerContracts/Drawing/DrawingSession.swift")
        for m in ["func activate(", "func deactivate(", "func discardPendingAnchors(",
                  "func addAnchor(", "func commitPending("] {
            #expect(code.contains(m), "mutator \(m) 不见了？")                 // 先证明确实扫到了这些方法
            #expect(!code.contains("public " + m),
                    "\(m) 不得为 public —— 包外能直接改会话就绕开了 begin/endDrawingSession，漂移会回来")
        }
        // 只读态则必须仍是 public（TrainingView / 未来底栏要读）
        #expect(code.contains("public private(set) var drawingModeActive"))
    }

    @Test("codex plan-R5-high：只有 TrainingEngine 能开/关会话（Coordinator 只许落锚/提交）")
    func onlyEngineTogglesSession() throws {
        let chart = try source(chartContainer)
        #expect(!chart.contains(".activate(tool:"))     // Coordinator 不得自行开会话
        #expect(!chart.contains(".deactivate()"))       // 也不得自行关会话
        #expect(chart.contains("session.addAnchor("))   // 它该做的只有落锚
        #expect(chart.contains("session.commitPending("))
    }

    @Test("codex plan-R2-high：面板级 FSM 原语只许 TrainingEngine 自己调（防再接一条漂移路径）")
    func panelLevelDrawingPrimitivesAreEngineOnly() throws {
        let sourcesRoot = contractsDir.appendingPathComponent("Sources/KlineTrainerContracts")
        let files = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "TrainingEngine.swift" }
        #expect(!files.isEmpty)                       // 路径写错会静默通过 → 先证明真的扫到文件了
        for f in files {
            let code = try source(relativeURL: f)     // 同样剥注释
            #expect(!code.contains("activateDrawingTool("), "\(f.lastPathComponent) 不得直接调面板级画线原语")
            #expect(!code.contains("commitDrawing("),       "\(f.lastPathComponent) 不得直接调面板级画线原语")
            #expect(!code.contains("cancelDrawing("),       "\(f.lastPathComponent) 不得直接调面板级画线原语")
        }
    }

    @Test("#4c/#6：本期不引入任何新 UI —— 浮动钮仍在，且无顶栏「画图」钮 / 底栏工具栏 / 设置面板")
    func noNewDrawingUI() throws {
        let code = try source(trainingView)
        #expect(code.contains("DrawingToolFloatingView("))     // 入口未变（退役在 1a-iii）
        #expect(!code.contains("画图"))                        // 顶栏「画图」钮（1a-iii）
        #expect(!code.contains("DrawingToolbar"))              // 两行底栏（1a-iii）
        #expect(!code.contains("DrawingSettingsPanel"))        // 设置面板（1a-iii）
    }
}
```

- [ ] **Step 2: 跑测试 + **mutation 验证守卫真的会咬**

本 task 是**锁死回归**的：Task 2/3 已经把代码改干净了，所以这些守卫**一上来就会绿**——而「一上来就绿的守卫」最容易是**假守卫**（路径写错→读不到文件→静默通过；正则写错→永不命中）。**必须逐条 mutation 验证**（memory: FP demonstrator 须 mutation-verify）：

```bash
cd ios/Contracts && swift test --filter DrawingSessionSourceGuardTests   # 先确认全绿
```

然后**逐个**临时注入坏味道，确认对应测试**变红**，再 `git checkout --` 还原：

| 临时注入 | 必须变红的测试 |
|---|---|
| 在 `TrainingView` 的 activePanel observer 里加回 `engine.cancelDrawingAllPanels()`（先把它改回 public） | `activePanelObserverNoLongerCancelsDrawing` + `activePanelObserverTouchesNoEngineState` |
| 在 `ChartContainerView.sync()` 里加回一行 `manager.toggle(.horizontal)`（连同一个假 manager） | `noRearmInChartContainer` |
| 在 `ChartContainerView.handleDrawingTap` 末尾加回 `engine.commitDrawing(panel: panel)` | `noCommitDrawingAfterTap` + `panelLevelDrawingPrimitivesAreEngineOnly` |
| 在 `TrainingView` 里加一个 `Text("画图")` | `noNewDrawingUI` |
| 给 `DrawingSession.deactivate()` 加上 `public` | `drawingSessionMutatorsAreNotPublic` |
| 在 `ChartContainerView.sync()` 里加一行 `engine.drawingSession.deactivate()` | `onlyEngineTogglesSession` |

**任何一条注入后测试仍然绿 = 那个守卫是假的**（多半是路径回推写错），修好再往下走。

- [ ] **Step 3: 写实现**

**3a.** `TrainingView.swift` `:76-83` 的谓词与 toggle（Task 2 · 3d(ii) 已提前接线，此处只补注释；若已一致则跳过）：

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

**3b.** `:234-241` 的 observer 改为（**只删画线那一句**，买卖条那句必须留）：

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

**3c.**（observer 与铅笔钮接线、旧测试删除**均已在 Task 2 · 3d 原子完成**——若此刻 `TrainingView` 里还留着 `engine.cancelDrawingAllPanels()`，说明 Task 2 没做完，回去补。访问级别一律不动，见 D46。）

**3d. 现在（且只有现在）才能上不变量守卫**（R4-high：必须等**所有**调用者干净了再上，否则中间 commit 自炸）。

此刻 `commitDrawing` / `cancelDrawing` 的「会话开着时的调用者」已全部清零：`ChartContainerView` 的
`engine.commitDrawing(panel:)` 在 Task 3 删掉；`TrainingView` 的 `cancelDrawingAllPanels()` 在 Task 2 · 3d 删掉；
`cancelDrawingAllPanels` 只被 `endDrawingSessionIfActive()` 调用，而它**先 `deactivate()` 再 cancel**。

给 `TrainingEngine.commitDrawing(panel:)` 与 `cancelDrawing(panel:)` 的**函数体第一行**各加一条
**生产期 fail-closed 守卫**（**不是 `assert`** —— codex plan-R9-high：`assert` 在 release 会被剥掉，
等于没有护栏；`guard` 在**所有构建**、对**任何调用者**（含包外 SwiftPM 消费者）都生效）：

```swift
        // P1b-1a-ii 不变量守卫（fail-closed，生产期生效）：面板级 FSM 原语**不得**在全局画线会话开着时
        // 被单独调用 —— 那会把面板打回 .autoTracking 却留下 drawingModeActive==true（本期要消灭的漂移）。
        // 会话的正当收束路径是 endDrawingSessionIfActive()：它先 deactivate() 再 cancel，故此守卫恒放行。
        // 语义 = no-op（不是崩溃）：即便包外消费者误调，也只是什么都不发生，绝不会造出坏状态。
        guard !drawingSession.drawingModeActive else { return }
```

现有 FSM 测试（`TrainingEngineDrawingHandlerH1Tests` / `TrainingEngineInteractionTests` /
`TrainingEngineDrawingCommitTests`）调这两个 API 时**会话都没开**（它们用 `activateDrawingTool` 直接推面板，
不碰 `beginDrawingSession`）→ 守卫恒放行，**一行不用改**。
**若实现后有测试被这条守卫改变了行为：先查是不是真漂移，不要直接删守卫。**

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter DrawingSessionSourceGuardTests`
Expected: PASS（5 个）

Run: `cd ios/Contracts && swift test`
Expected: 全绿（`cancelDrawingAllPanels` 私有化后**不得**有任何测试仍引用它）

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
| 5 | 切周期组合（竖滑 **或直接调 API**） | 画线会话开着 → `switchPeriodCombo` **整个 no-op**（周期不变、会话/工具/pending 全保留、两面板仍 .drawing） | Task 2 fail-closed 守卫 + `periodSwitchIsNoOpWhileDrawing`（直接调）+ `periodSwitchWorksAfterLeavingDrawing`（防假绿）+ `periodSwitchUnreachableWhileDrawing`（手势层）|
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
| 5 | **先点浮动钮退出画线模式**，再竖滑切周期，让下半面板那条线的周期挪走 | 它跟着自己的周期走/消失（1a-i 周期绑定仍生效）。<br>注：**画线模式开着时竖滑是切不了周期的**（手势被画线吃掉），这是当前设计，1a-iv 才放开 | |
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

# PR C6 — DrawingTools + DrawingInputController infrastructure design

**Wave 1 顺位 12（按交付序为第 14 个 PR）**

**Spec 源**：
- `kline_trainer_modules_v1.4.md` §C6（L1315–1349）—— protocol + Manager class 形状定义
- `kline_trainer_plan_v1.5.md` §Phase 2.5 / §Phase 4 —— 应用阶段映射
- `docs/superpowers/specs/2026-05-19-wave1-outline-design.md` 顺位 12 行 —— **scope 权威**："仅 infrastructure + tool 框架；Phase 2.5 水平线 MVP 归 Wave 3"

**冻结上游**：PR #54 `wave0-frozen-v1.4`（spec + modules + signing-rules + acceptance template）

**直接上游依赖（Wave 1 已 merge）**：
- PR #51 PR8（`KLineView+Drawing.swift` drawDrawings stub + `KLineRenderState.drawings` 字段）
- PR #48 PR7b1（ChartReducer drawing FSM，含 `activateDrawing` / `drawingCommitted(baseRevision:)` / `drawingCancelled(baseRevision:)` / `setDrawingSnapshot` / `requestDrawingSnapshotAfterStoppingAnimator` / `staleDrawingSnapshot`）—— **本 PR 不改 reducer 一行代码**
- PR #53 PR F1（`DrawingToolType` enum + `DrawingAnchor` / `DrawingObject` Codable 值类型）
- PR #61 PR C7（ChartGestureArbiter `drawingMode` flag —— 不在本 PR 改）

---

## 一、Scope 边界

### 在本 PR scope

1. `DrawingTool` protocol（4 成员，字面对齐 modules L1318–1323）
2. `DrawingInputController` protocol（2 方法，字面对齐 modules L1325–1328）—— **只 protocol 不实现**
3. `DrawingToolManager` class（`@MainActor @Observable final class`），4 属性 + 5 方法真实现 —— **纯内存 state 容器**，无 ChartReducer 接缝
4. `drawDrawings` 真 dispatch 实现（替换 PR #51 stub 空 body），扩签名增 `tools:` 字典参数
5. `KLineView.swift` L55 一处调用方同步加 `tools: [:]` 占位（不引入注册逻辑）
6. modules acceptance §A 行 L2149 同步：「Phase 2.5 水平线先行」→「infrastructure + tool 框架；Phase 2.5 水平线 MVP 归 Wave 3」
7. 单元测试 17 项（Manager state 10 + protocol 契约 3 + drawDrawings dispatch 3 + spec-literal grep guard 1）+ 中文非程序员验收清单

### 不在本 PR scope（明确退出）

- 任何具体 `DrawingTool` 实现（HorizontalLineTool / RayTool / TrendLineTool / 等 7 种）—— Wave 3 Phase 2.5 + Phase 4
- `DrawingInputController` 的具体实现体（DefaultDrawingInputController）—— 与水平线 MVP 同期 Wave 3 交付
- `drawings` SQLite 表持久化（P4 AppDB drawings DAO 已在 PR #42 内 schema 落地；本 PR 不调用 DAO；持久化责任归属在 Wave 3 实施时通过新 service / repository 层封装，**不**加到 `DrawingToolManager` 类——保持 manager 是纯 UI state 容器）
- 顶栏画线按钮 UI —— Wave 3 / U2 TrainingView
- gesture / tap → anchor 的坐标映射逻辑 —— Wave 3 配合具体 tool
- 跨周期 anchor 还原 / hit-test 选中删除交互 —— Wave 3 / Phase 4
- ChartGestureArbiter.drawingMode flag 的 setter 链路 —— Wave 3
- **`ChartReducer` ChartAction 流转**（`.activateDrawing` / `.drawingCommitted` / `.drawingCancelled` / `.setDrawingSnapshot` / 等）—— PR #48 已落地 reducer，本 PR 既不调用、也不持有 reducer 引用；reducer 集成责任归 Wave 3 UI 层（详 §三）
- `manager.completedDrawings` → `renderState.drawings` 投影实现 —— Wave 3 UI 层负责（本 PR 仅保证 manager state 公开可读使投影可实施）

---

## 二、组件

### 2.1 文件清单（新增 / 修改）

| # | 文件 | 状态 | 行数估算 | 内容 |
|---|---|---|---|---|
| 1 | `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift` | 新增 | ~30 | `protocol DrawingTool` |
| 2 | `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingInputController.swift` | 新增 | ~20 | `protocol DrawingInputController` |
| 3 | `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift` | 新增 | ~140 | `@MainActor @Observable final class` + 4 属性 + 5 方法 + init |
| 4 | `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift` | 改 | ~40（net +~30） | drawDrawings 真 dispatch + tools 参数 |
| 5 | `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift` | 改 1 行 | +0 net | L55 调用加 `tools: [:]` 占位 |
| 6 | `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolManagerTests.swift` | 新增 | ~180 | Manager state machine 10 tests |
| 7 | `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingProtocolTests.swift` | 新增 | ~80 | DrawingTool / Controller protocol 契约 3 tests |
| 8 | `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift` | 新增 | ~80 | drawDrawings dispatch 3 tests |
| 9 | `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/SpecLiteralGuardTests.swift` | 新增 | ~40 | spec literal grep guard 1 test（防 protocol 签名漂移） |
| 10 | `kline_trainer_modules_v1.4.md`（acceptance §A L2149） | 改 1 行 | +0 net | 文案同步 outline v20 |
| 11 | `docs/acceptance/2026-05-26-pr-c6-drawing-tools-infrastructure.md` | 新增 | ~120 | 中文非程序员验收清单 |
| 12 | `docs/superpowers/plans/2026-05-26-pr-c6-drawing-tools-infrastructure.md` | 新增（writing-plans 阶段产出） | — | plan 文档 |

**预计 prod 行数**：~240 行（4 件 prod swift 文件合计：~30 + ~20 + ~140 + ~40 + 1 = ~231，含 import / 注释 / spec 引用约 +10% → ~250）；测试 ~380 行；合计 prod ~250 ≪ 500 硬规则上限。

### 2.2 关键 protocol 形状

```swift
public protocol DrawingTool: Sendable {
    static var type: DrawingToolType { get }
    var requiredAnchors: ClosedRange<Int> { get }
    @MainActor func render(ctx: CGContext, mapper: CoordinateMapper, anchors: [DrawingAnchor])
    @MainActor func hitTest(point: CGPoint, mapper: CoordinateMapper, anchors: [DrawingAnchor]) -> Bool
}

public protocol DrawingInputController: AnyObject {
    @MainActor func tapToAnchor(at point: CGPoint, panel: PanelViewState, mapper: CoordinateMapper) -> DrawingAnchor
    @MainActor func shouldCommit(current: [DrawingAnchor], tool: DrawingToolType) -> Bool
}
```

字面对齐 modules L1318–1328，**只增加可见性修饰符 `public` + concurrency 修饰符**（`Sendable` / `@MainActor`，per M0.5 §并发契约）。

**`requiredAnchors` 归属**：留在 `DrawingTool` protocol 上（实例成员），由具体 tool 实现负责。**Manager 不调用此属性**（详 §四：commit 不查 anchor count 上下界）；anchor 数量边界约束由 `DrawingInputController.shouldCommit` 守，是 caller 责任。

### 2.3 DrawingToolManager 形状

```swift
@MainActor
@Observable
public final class DrawingToolManager {
    public var activeTool: DrawingToolType?
    public var enabledTools: Set<DrawingToolType>
    public var pendingAnchors: [DrawingAnchor]
    public var completedDrawings: [DrawingObject]

    public init(enabledTools: Set<DrawingToolType> = [])

    public func toggle(_ t: DrawingToolType)
    public func addAnchor(_ a: DrawingAnchor)
    public func commit()
    public func cancel()
    public func deleteDrawing(at index: Int)
}
```

**与 spec §C6 L1330–1343 字面差异（最小附加，acceptance §A 同步标注）**：
- 增 `public` 可见性
- 增 init 签名带 `enabledTools` 默认 `[]`（spec 未给 init 签名 → 此为 spec gap 补全）；默认值为空集对齐 outline v20 "infrastructure + 框架未启用任何具体 tool"，调用方按需注入
- 5 方法签名与 spec 一致
- **Manager 不持有任何 ChartReducer 引用 / dispatch 闭包 / revision 读取通路**（详 §三）

---

## 三、数据流 / 责任划分

### 3.1 Manager 五方法内部状态机

所有状态变更**仅**改 Manager 内部 4 属性，**不**发送任何 ChartAction，**不**调用任何外部 API。

```
toggle(_ t: DrawingToolType)
  ├─ if !enabledTools.contains(t): return  (no-op)
  ├─ if activeTool == t:                    (互斥：同 tool 再 toggle = 关闭)
  │   ├─ activeTool = nil
  │   └─ pendingAnchors = []
  └─ else:                                  (切到新 tool 或首次激活)
      ├─ activeTool = t                     (隐含取消上一个 tool：activeTool 直接覆写)
      └─ pendingAnchors = []                (清空旧 tool 的 pending)

addAnchor(_ a: DrawingAnchor)
  ├─ precondition(activeTool != nil)        // invariant: caller 必须先 toggle
  └─ pendingAnchors.append(a)

commit()
  ├─ precondition(activeTool != nil)        // invariant: caller 必须先 toggle
  ├─ precondition(!pendingAnchors.isEmpty)  // invariant: caller (shouldCommit) 必须保证非空
  ├─ let drawing = DrawingObject(
  │       toolType: activeTool!,
  │       anchors: pendingAnchors,
  │       isExtended: false,                // Wave 1 default; Wave 3 配 tool 调整
  │       panelPosition: 0                  // Wave 1 default; Wave 3 配 panel 调整
  │   )
  ├─ completedDrawings.append(drawing)
  ├─ activeTool = nil
  └─ pendingAnchors = []

cancel()
  ├─ if activeTool == nil: return           (幂等 no-op)
  ├─ activeTool = nil
  └─ pendingAnchors = []

deleteDrawing(at index: Int)
  ├─ precondition(completedDrawings.indices.contains(index))
  └─ completedDrawings.remove(at: index)
```

**关键架构不变量**：
- Manager 完全不感知 ChartReducerState、revision、interactionMode
- Manager 所有方法都是同步 + 纯状态变更（无 async / await / effect）
- 调用任意方法不产生外部 side effect（无 dispatch、无 logging、无 IO）
- `completedDrawings` 是 drawing 数据的 **source-of-truth**

### 3.2 drawDrawings render dispatch

```swift
@MainActor
extension KLineView {
    func drawDrawings(ctx: CGContext,
                      mapper: CoordinateMapper,
                      drawings: [DrawingObject],
                      period: Period,
                      tools: [DrawingToolType: any DrawingTool]) {
        for drawing in drawings {
            guard let tool = tools[drawing.toolType] else { continue }
            tool.render(ctx: ctx, mapper: mapper, anchors: drawing.anchors)
        }
    }
}
```

调用方（`KLineView.swift` L55）：

```swift
drawDrawings(ctx: ctx, mapper: mapper,
             drawings: renderState.drawings,
             period: renderState.period,
             tools: [:])  // Wave 1: 空字典；Wave 3 注册 HorizontalLineTool 等
```

签名 `tools:` 参数**不**给默认值——强制调用方显式传入（即使是空字典），明示本 PR 的"infrastructure only"边界。本 PR 调用方一律传 `[:]` → for 循环每次走 `continue` 路径 → runtime 实际未画任何 drawing。

### 3.3 责任划分（UI 层是 manager + reducer 共同 driver）

```
                  ┌──────────────────────┐
                  │   UI 层（Wave 3）     │
                  │  observe & dispatch   │
                  └──────────┬───────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼                             ▼
     ┌─────────────────┐          ┌───────────────────┐
     │ DrawingToolMgr  │          │  ChartReducerState │
     │ (本 PR 交付)     │          │  (PR #48 已落地)   │
     │  - activeTool   │          │  - interactionMode │
     │  - pending      │          │  - revision        │
     │  - completed◀───┼─src───   │  - snapshot        │
     └─────────────────┘          └───────────────────┘
              ▲                             ▲
              │ read                        │ read
              └─────────────┬───────────────┘
                            │
                    ┌───────▼────────┐
                    │  renderState   │
                    │  .drawings ←─  │  (Wave 3 投影 manager.completedDrawings)
                    └────────────────┘
```

**职责矩阵**：

| 组件 | 拥有的 state | 不感知的 state | 流向 |
|---|---|---|---|
| `DrawingToolManager`（本 PR） | activeTool / enabledTools / pendingAnchors / completedDrawings | reducer 任何 state、renderState、drawings DAO | Wave 3 UI 层读 |
| `ChartReducer`（PR #48） | interactionMode（含 .drawing(snap) 与 frozen baseRevision）、revision | Manager 任何 state、completedDrawings 列表 | Wave 3 UI 层读 + dispatch |
| Wave 3 UI 层（本 PR 不交付） | 无独立 state | — | 同时观察 Manager + Reducer，dispatch ChartAction，投影 `manager.completedDrawings → renderState.drawings`，同步 `drawingMode flag` 给 ChartGestureArbiter |
| `drawDrawings`（本 PR 改） | 无 state（pure function） | — | UIKit draw cycle 内消费 renderState.drawings + tools 字典 |

**Wave 3 UI 层典型流程**（**本 PR 不实施、仅作为本 PR 接口契约的证据**）：

```
[user 点顶栏画线按钮]
  └─ UI 层:
      ├─ manager.toggle(.horizontal)
      └─ chartView.send(.activateDrawing(.horizontal))    // 直接调 reducer，不经过 manager
          └─ reducer 返 .requestDrawingSnapshotAfterStoppingAnimator(.horizontal, baseRevision: X)
              └─ handler: stop animator + 计算 candleRange + chartView.send(.setDrawingSnapshot(.horizontal, X, range))
                  └─ reducer 进 .drawing(snap)；UI 同步 drawingMode flag → gesture arbiter

[user tap chart 画 anchor]
  └─ UI 层:
      ├─ anchor = controller.tapToAnchor(at: pt, ...)
      ├─ manager.addAnchor(anchor)
      └─ if controller.shouldCommit(current: manager.pendingAnchors, tool: manager.activeTool!):
          ├─ manager.commit()                                           // 改 completedDrawings + 重置 activeTool
          └─ chartView.send(.drawingCommitted(baseRevision: snap.frozen.baseRevision))  // 用 reducer 内 snap 的 baseRevision
              └─ reducer 退 .autoTracking；UI 同步 drawingMode = false

[user 取消画线]
  └─ UI 层:
      ├─ manager.cancel()
      └─ chartView.send(.drawingCancelled(baseRevision: snap.frozen.baseRevision))

[reducer 因 tradeTriggered/periodCombo 自行退出 drawing]
  └─ UI 层 observe reducer.interactionMode 变化:
      └─ manager.cancel()                                              // 同步取消 manager 状态
```

**关键设计约束**：
- baseRevision 一律来自 `reducer.interactionMode.snap.frozen.baseRevision`（reducer 自己持有），**不**由 Manager 提供
- Manager 与 reducer state 同步（如 reducer 自行退出 drawing 时 Manager 也要 cancel）责任在 UI 层，**不**在 Manager 内部
- 此 design 直接对齐 reducer L168-169 注释「drawing 模式下切工具由 DrawingToolManager 处理」字面（manager 自己管，不发 reducer action）

---

## 四、错误处理 / precondition 策略

对齐 PR #65 E2 PositionManager 方向 B（precondition trap for 进程内违反不变量；throwing 仅在持久化反序列化）。Manager 全部操作进程内、不涉及反序列化 + 无外部 IO → **统一 precondition 策略，零 throws、零 dispatch**。

| API | 失败场景 | 行为 |
|---|---|---|
| `toggle(t)` | `enabledTools.contains(t) == false` | no-op return（不 precondition；UI 信号源可能未同步） |
| `addAnchor(a)` | `activeTool == nil` | `precondition` trap（caller 必须先 toggle） |
| `commit()` | `activeTool == nil` | `precondition` trap |
| `commit()` | `pendingAnchors.isEmpty` | `precondition` trap（caller `shouldCommit` 必须 gate） |
| `cancel()` | `activeTool == nil` | no-op return（幂等） |
| `deleteDrawing(at:)` | 索引越界 | `precondition` trap |
| `drawDrawings` 内 `tools[type]` 缺失 | 静默跳过（不抛、不 precondition） |

**关于 anchor 数量上下界**：Manager.commit() **只**验 `!pendingAnchors.isEmpty`，**不**查 `activeTool.requiredAnchors`。原因：
1. Manager 持有 `activeTool: DrawingToolType?`（enum case），不持有 tool 实例 → 无法读 protocol 实例成员 `requiredAnchors`
2. anchor 数量上下界由 `DrawingInputController.shouldCommit(current:, tool:)` gate，是 caller 责任
3. 把 `requiredAnchors` 搬到 `DrawingToolType` enum extension 是另一可选 spec amendment，但会强制本 PR 给所有 7 种 tool 填值——超出 outline v20 scope（Phase 2.5 之外 6 种 tool 的 anchor 数量定义本不在 Wave 1）

**precondition 测试**：Swift Testing 不支持 crash 断言；不写 crash test。改为：
- **正向**：每个 precondition 在合法路径上**不 trap**（即测试程序能跑完）
- **文档断言**：在 spec / acceptance §B 字面写明"由调用方保证 X，违反后果 = crash"
- **lint**：source 文件内 precondition 前一行加注释 `// invariant: <condition>` 作 grep 锚（与 PR #65 一致）

---

## 五、测试矩阵

落 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/`，4 文件合计 17 tests（10 + 3 + 3 + 1）。每个 test 名带 spec 引用锚便于 grep。

### 5.1 `DrawingToolManagerTests.swift`（10 tests）

| # | 测试名 | 覆盖 |
|---|---|---|
| 1 | `toggleFirstActivatesTool` | 首次 toggle → activeTool = t；pendingAnchors == []；completedDrawings 不变 |
| 2 | `toggleSameToolDeactivates` | 同 tool 再 toggle → activeTool == nil；pendingAnchors == [] |
| 3 | `toggleDifferentToolOverridesAndClearsPending` | 切到新 tool（pending 非空）→ activeTool = newTool；pendingAnchors 重置为 [] |
| 4 | `toggleDisabledToolIsNoOp` | toggle 不在 enabledTools 内的 type → 全部 4 属性不变 |
| 5 | `addAnchorAppends` | 正常 addAnchor → pendingAnchors 长度 +1，元素相等 |
| 6 | `commitMovesToCompletedAndResets` | commit → completedDrawings 长度 +1 + 最后一项 toolType/anchors 匹配；activeTool == nil；pendingAnchors == [] |
| 7 | `cancelExplicitResetsActiveAndPending` | activeTool 非 nil 时 cancel → activeTool == nil；pendingAnchors == [];completedDrawings 不变 |
| 8 | `cancelIdempotentNoChange` | activeTool == nil 时 cancel → 全部 4 属性不变（含 completedDrawings） |
| 9 | `deleteDrawingRemovesAtIndex` | 多次 commit 后 deleteDrawing(at: 1) → completedDrawings 长度 -1；剩余顺序与索引对应正确 |
| 10 | `enabledToolsDefaultsToEmptySet` | 默认 init 后 enabledTools == [] 空集；显式 init 注入 7 种后 enabledTools 大小 == 7 |

**注**：所有 10 测试都是纯状态断言，**不**涉及 dispatch spy 或 currentRevision spy（Manager 无外部接缝）。

### 5.2 `DrawingProtocolTests.swift`（3 tests）

| # | 测试名 | 覆盖 |
|---|---|---|
| 11 | `fakeDrawingToolConforms` | 实现 `FakeDrawingTool: DrawingTool`，断言 4 成员可访问 + `type` 静态返回 `.horizontal` + `requiredAnchors` 返回 `1...1` |
| 12 | `requiredAnchorsRangeIsClosed` | `FakeDrawingTool.requiredAnchors` 是 `ClosedRange<Int>`（不是 `Range<Int>`），断言 `.contains(lower)` && `.contains(upper)` 均 true |
| 13 | `fakeInputControllerConforms` | 实现 `FakeInputController: DrawingInputController`，断言 2 方法可调用并返回预期值 |

### 5.3 `DrawDrawingsDispatchTests.swift`（3 tests）

| # | 测试名 | 覆盖 |
|---|---|---|
| 14 | `drawDrawingsEmptyListNoRenderCalls` | drawings = [] → SpyTool.render 调用次数 == 0（任何 tool 都不被调） |
| 15 | `drawDrawingsRegisteredToolRenderCalledOnce` | drawings = [一项 toolType=.horizontal]，tools = [.horizontal: SpyTool] → SpyTool.render 调用次数 == 1；参数 anchors 透传相等 |
| 16 | `drawDrawingsMissingToolSkipsSilently` | drawings = [一项 toolType=.horizontal]，tools = [:] → 不 crash；任何 SpyTool.render 调用次数 == 0（本 PR 调用方默认路径） |

### 5.4 `SpecLiteralGuardTests.swift`（1 test）

| # | 测试名 | 覆盖 |
|---|---|---|
| 17 | `protocolSignatureGuardsAgainstSpecDrift` | 静态编译期 + 反射约束：(a) `DrawingTool` protocol 必须 conform `Sendable`；(b) `DrawingToolManager` 必须 `@MainActor`（通过 `_ = MainActor.assumeIsolated` 闭包内访问验证）；(c) `requiredAnchors` 返回类型必须是 `ClosedRange<Int>`（编译期类型检查 fake.requiredAnchors as? ClosedRange<Int>） |

**Spec literal grep 锚**（acceptance §A 手动 checklist）：
- `grep -n 'static var type: DrawingToolType' DrawingTool.swift` → 1 hit
- `grep -n 'var requiredAnchors: ClosedRange<Int>' DrawingTool.swift` → 1 hit
- `grep -n '@MainActor func render(ctx: CGContext' DrawingTool.swift` → 1 hit
- `grep -n '@MainActor func hitTest(point: CGPoint' DrawingTool.swift` → 1 hit
- `grep -n '@MainActor func tapToAnchor(at point: CGPoint' DrawingInputController.swift` → 1 hit
- `grep -n '@MainActor func shouldCommit(current:' DrawingInputController.swift` → 1 hit
- `grep -n '@MainActor' DrawingToolManager.swift` → ≥1 hit
- `grep -n '@Observable' DrawingToolManager.swift` → 1 hit
- `grep -n 'final class DrawingToolManager' DrawingToolManager.swift` → 1 hit
- `grep -n 'func drawDrawings(ctx: CGContext' KLineView+Drawing.swift` → 1 hit（5 参签名含 `tools:` 字典）
- `grep -n 'tools: \[DrawingToolType: any DrawingTool\]' KLineView+Drawing.swift` → 1 hit

**测试 helper**：
- `SpyDrawingTool`：记录 `render` / `hitTest` 调用参数 + 次数（actor isolation 使用 `@MainActor` 闭包包裹累加）
- `FakeDrawingTool`：最小 conformance（type=.horizontal, requiredAnchors=1...1, render/hitTest no-op）
- `FakeInputController`：最小 conformance（返回 fixed DrawingAnchor / fixed bool）

---

## 六、Acceptance §A 同步

`kline_trainer_modules_v1.4.md` 三处 amendment（统一作 plan-stage Task 0 ledger 落地，对齐 PR #54 spec amendment 模式）：

| # | 位置 | 原文 | 改为 |
|---|---|---|---|
| 1 | L2149 acceptance §A | `- [ ] C6 DrawingTools + DrawingInputController（Phase 2.5 水平线先行）` | `- [ ] C6 DrawingTools + DrawingInputController（infrastructure + tool 框架；Phase 2.5 水平线 MVP 归 Wave 3，per outline v20 顺位 12）` |
| 2 | L1224-1225 §C6 KLineView demo | `extension KLineView { func drawDrawings(ctx: CGContext, mapper: CoordinateMapper, drawings: [DrawingObject], period: Period) }` | 5 参签名（加 `tools: [DrawingToolType: any DrawingTool]`）；标注 "Wave 1 PR C6 amendment：tools 字典由 KLineView 调用方注入，Wave 1 调用方传 `[:]`" |
| 3 | L1346-1348 §C6 protocol 块同处签名 | 同 #2 4 参签名 | 同 #2 5 参签名（保 §C6 protocol 块与 KLineView demo 字面一致） |

—— 三条统一对齐 outline v20 权威 + 新签名。与 §F1 Models / §M0.3 Codable 同模式的 spec amendment 走法（与 PR #54 amendment ledger 一致）。

---

## 七、风险 + 缓解（codex 已知 reject pattern）

| 风险 | 缓解 |
|---|---|
| codex 提"Manager 应该 dispatch ChartAction 给 reducer 让 toggle/commit/cancel 联动 drawing FSM" | **reject**：违反 §3.3 责任划分——Manager 不感知 reducer state，dispatch reducer 责任在 UI 层。Manager 若 dispatch 会撞 reducer cross-session guard（L187-203）+ assertionFailure trap（L200-203）；直接对齐 reducer L168-169 注释字面要求 |
| codex 提"加 DrawingTool 注册表 singleton 把 tools 字典塞进 Manager" | **reject**：违反 §3.3 责任划分——drawDrawings 是 render 时刻消费 tools；Manager 是 state 入口；二者职责分离。tools 字典由 KLineView 调用方注入（Wave 3 配合具体 tool 注册） |
| codex 提"DrawingTool.render 应该 throws / Result" | **reject**：render 是 UIKit draw cycle 内调用，throw 在 draw 内无处接；hitTest 同理。spec §C6 L1321–1322 未声明 throws |
| codex 提"`tools: [:]` 默认参数让调用方忘传" | **reject**：本 PR 调用方 KLineView.swift L55 显式 `tools: [:]`；签名**不**给默认值，强制调用方显式标 scope 边界 |
| codex 提"Manager 应该订阅 reducer state 让 toolbar UI 一处真相" | **reject**：违反 §3.3 责任划分——UI 层应自己订阅 reducer state（PR #48 ChartReducerState 已 @Observable），不经过 Manager。Manager 是 drawing tool **自身**的 state |
| codex 提"toggle 不互斥的话 Manager 应该支持多 tool 并发激活" | **reject**：modules L2149 acceptance "工具选择、互斥"字面要求；spec §C6 L1333 `activeTool: DrawingToolType?` 字面是 Optional 单值；多 tool 并发不在 spec scope |
| codex 提"commit 应该验 `pendingAnchors.count ∈ activeTool.requiredAnchors`" | **reject**：详 §四 anchor 数量上下界一节——Manager 不持有 tool 实例无法读 requiredAnchors；上下界守约是 `DrawingInputController.shouldCommit` 的 caller 责任 |
| codex 提"persistence 应该在本 PR 接 P4 AppDB drawings DAO" | **reject**：scope §一 / Wave 3 明确隔离；本 PR 无 GRDB import |
| codex 提"DrawingInputController 应该有 Default 实现" | **reject**：modules L1325 protocol；实现体需要坐标映射 + tap 容差，逻辑量 ~100 行 = 跨出 outline v20 scope |
| codex 提"completedDrawings 应该同步到 renderState.drawings 在 Manager 内部" | **reject**：详 §3.3 责任划分——投影责任在 UI 层；Manager 公开可读使投影可实施，但不负责投影 |
| codex 提"enabledTools 默认应该是 7 种全启用" | **reject**：详 §3.3 + §2.3——默认 `[]` 对齐 outline v20 "infrastructure 完备但未启用任何具体 tool"；调用方按需注入 |
| Manager 内多步状态变更顺序敏感（commit / toggle 隐含切换） | 测试 #3 / #6 / #7 显式断言顺序（completedDrawings.append 在 activeTool=nil 之前；pendingAnchors=[] 与 activeTool=nil 同步） |

---

## 八、Plan 流程衔接

本 spec 之后路径（在 writing-plans 阶段确定 Task 颗粒度）：

1. **writing-plans** → 把 §一/二/三/四/五/六 拆 Task 0/1/2/3 + 验收检查点
2. **opus 4.7 xhigh adversarial review plan** → 直到 APPROVE
3. **subagent-driven-development** → Sonnet subagent 跑 TDD（红/绿/审）
4. **verification-before-completion** → swift test 全绿 + grep 锚 + acceptance 9 节
5. **requesting-code-review**（self-review）
6. **opus 4.7 xhigh adversarial review on branch diff** → 直到 APPROVE
7. → admin merge + memory 落地

---

## 九、Changelog

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-05-26 | v1 (draft) | 初稿；brainstorming 4 个 scope 决策对齐 user：纯框架 / Manager 全实现 / 不持久化不 Controller / 互斥+全7种 enabled |
| 2026-05-26 | v2 (opus xhigh R1 修订) | R1 verdict NEEDS-ATTENTION 12 findings（3C/3H/4M/2L）全部处理：(a) **删 Manager → ChartReducer 接缝**（消除 F1/F3/F5/F8：commit revision sync / toggle 隐含 cancel 撞 reducer assertionFailure / 切工具与 reducer L168 矛盾 / dispatch 闭包丢 effect）—— Manager 改纯内存 state 容器，reducer ChartAction 流转责任全归 Wave 3 UI 层；(b) commit 不查 requiredAnchors（消除 F2 Swift 编译 mismatch + F6 commit 下界 user-facing trap）—— anchor 数量上下界由 caller shouldCommit 守；(c) §3.3 显式 `completedDrawings` source-of-truth + UI 层负责投影 renderState.drawings（消除 F4 两份真值源缺接缝 + F12 持久化责任归属）；(d) enabledTools 默认 `[]`（消除 F7 scope 边界冲突）；(e) 删 revision 接缝 3 tests（消除 F9 测试命名陷阱）；(f) 加 spec literal grep guard test + acceptance §A manual grep checklist（消除 F10 spec drift 无 guard）；(g) §2.1 行数估算 ~280 → ~250 prod / 总 prod ~250（消除 F11，估算更保守，删 dispatch 接缝后 Manager 从 ~180 → ~140）；(h) §一 §不在 scope 加 "ChartReducer ChartAction 流转 / renderState 投影实现 / 持久化责任" 三条退出；(i) §七 risks 表加 4 条新 reject pattern（Manager dispatch reducer / completedDrawings 内部投影 / commit 验 requiredAnchors / enabledTools 默认 7） |
| 2026-05-26 | v3 (opus xhigh R2 修订) | R2 verdict APPROVE-with-minor-caveat，R1 12 findings 全部真收敛；R2 新 finding R2-F1 [Medium] drawDrawings 签名 spec amendment 覆盖面不全 + grep guard 漏一条 → v3 直接修：(1) §六 acceptance amendment 从 1 行改 3 行表格（加 modules L1224-1225 + L1346-1348 两条 drawDrawings 5 参签名同步责任）；(2) §5.4 grep 锚加 2 条覆盖 drawDrawings 签名 + tools 字典字面 |

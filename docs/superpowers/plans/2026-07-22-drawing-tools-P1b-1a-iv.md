# 划线工具扩充 P1b-1a-iv 实施计划：画线时也能平移、切周期、缩放

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 画线模式（`drawingSession.drawingModeActive == true`）下，单指横向拖动能平移图表、单指竖直甩动能切周期组合、双指捏合能缩放、单击仍然落锚；切周期**真的发生**时只丢弃 pending 锚而保留工具与会话。

**Architecture:** 三层同时改动，缺一层用户就看不到效果 ——
① **Reducer 层（本计划新发现，spec §5 未写，见「范围补充」）**：`.drawing` 目前**吞掉** `.offsetApplied` / `.zoomApplied`、且 `.panEnded` 不发 `.startDeceleration`。只放开手势层的话，手指拖得动、图表纹丝不动。本期把 `.drawing` 的**视口行为**对齐 `.freeScrolling`（`.drawing` 仍是独立 mode，只是不再冻结视口）。
② **手势层（D32）**：`panPolicyInDrawingMode` / `DrawingModePanPolicy` / `singlePanStep(drawingTakesOver:)` 三者**原子删除**（不留恒 false 的死参数），单指 pan 从此与画线状态无关。
③ **引擎层（D31）**：`switchPeriodCombo` 删掉「画线时 no-op」守卫，改为「周期组合**真的变了**」时 `discardPendingAnchors()`（保工具、保会话）+ 重新武装两面板维持不变量。

**Tech Stack:** Swift 6 / SwiftPM（`ios/Contracts`）、swift-testing（`@Test`/`#expect`）、`@Observable` + `@MainActor`。无新依赖、无 schema 改动。

**⚠️ 执行顺序（不是文档顺序）：Task 1 → Task 2 → Task 1b → Task 3 → Task 4。** Task 1b 的顺序守卫写在 `DrawingGestureSourceGuardTests.swift` 里，而那个文件由 Task 2 Step 1 创建；Task 1b 排在文档上紧挨 Task 1 是因为它修的是 Task 1 引入的危害，读的时候该连着读。

## Global Constraints

- **不动契约**：`CONTRACT_VERSION` 保持 **1.12**，无 migration、无 `Models.swift` 字段增删、无持久化格式变化。本期是纯行为改动。
  **`CONTRACT_VERSION` 的辖域澄清（codex plan-R1-medium 的回应）**：它约束的是**持久化 / 跨端数据契约**（DB schema、JSON 编解码形状、迁移链），**不是** SwiftPM 的 Swift API 源码面。Task 2 删除的 `DrawingModePanPolicy` / `panPolicyInDrawingMode` **不参与任何编解码、不落任何一张表**，删它不构成契约变更、不需要 bump。
  **API 面消费者的实证（不是「repo-local grep 所以大概没有」）**：`ios/Contracts` 是**仓内本地包**，唯一消费者是 `ios/KlineTrainer/KlineTrainer.xcodeproj` 里以本地 `relativePath` 方式引用的 app target（`project.pbxproj` 的 `KlineTrainerContracts` productRef）；本包**从未发布到任何 registry / 未被任何外部仓库以 URL 依赖引用**，不存在「downstream package client」这种消费者。Task 2 的 Catalyst 编译门 + iOS build 就是完整的下游编译证据。
  **先例**：1a-iii 切片3 以完全相同的理由原子删除 public 的 `colorEnabled`（user 拍板「直接删，不留 shim」），contract 未 bump、CI 全绿、已合入 main。本期沿用同一裁决。
- **不做（spec §5.2 逐字）**：选中 / 删除 / 锁定 / 撤销 / 前进 / D30（1b-i / 1b-ii）；**节点拖动分支** / 多锚工具 / 四个新工具（P1c）；复盘专属一切（P5）。
- **交易边界不变（D45）**：画线模式下**不能**买卖；`buy` / `holdOrObserve` 仍隐式结束画线会话。现有 `TradeConfirmGuard.allowsConfirm(drawingModeActive:…)` 一字不改。
- **复盘入口一字不改**：复盘仍是浮动铅笔钮，**不出现**两行底栏。D32 是全局引擎行为，复盘里自然同样生效（D26），但**不新增任何复盘 UI**。
- **核心不变量（1a-ii 起，本期必须继续成立）**：`drawingSession.drawingModeActive == true` ⇔ 上下**两个**面板 `interactionMode` 均为 `.drawing`。任何路径都不许留「铅笔钮亮着、点图没反应」的裂脑态。
- **绝不调 `deactivate()` / `DrawingToolManager.cancel()` 来处理 pending**：只允许 `DrawingSession.discardPendingAnchors()`（保 `activeDrawingTool`、保 `drawingModeActive`）。
- **每个增删测试的 task 收尾必须跑 fresh 非增量 Catalyst 对基线**（不是只跑 host）。基线文件 `.github/scripts/catalyst-total-baseline.txt` 当前值 **1532**、`DELTA=30`；若本分支真实总数漂出 `1532±30`，必须在**同一个 commit** 里更新基线文件并在 PR 说明。（教训来源：1a-iii 切片3 Task1 只跑 host，测试计数漂移潜伏到 Task2 才炸。）
- **测试不得依赖 SwiftUI 渲染时序**：不新增任何依赖 `ImageRenderer` 单次渲染同步 flush `.task` / `onPreferenceChange` 的断言（本地 Xcode 26.6 成立、CI macos-15 不成立）。需要结构性证据时，用「纯 model 行为契约 + 静态源码守卫」两条不碰渲染时序的证据。
- **源码守卫必须先证明读到了文件**：每条负向断言（`!code.contains(...)`）前必须有一条正向断言（`code.contains("func …")`），否则路径写错 → 空内容 → 负向断言假绿。沿用 `DrawingSessionSourceGuardTests` 的 `source(_:)`（**剥注释**后再匹配）。

---

## 范围补充：为什么必须动 Reducer（spec §5 的隐含前提）

spec §5.1 只写了手势层（`GestureClassifiers` / `ChartGestureArbiter`），但 §5.4 的非程序员验收清单第 1 / 3 条要求「单指横向拖 → 图表左右平移」「双指捏合 → 图表缩放正常」。实测现状：

| 现状代码 | 后果 |
|---|---|
| `Reducer.swift:158` `case (.drawing, .offsetApplied): return .none` | 画线模式下平移**位移全被吞**，offset 一动不动 |
| `Reducer.swift:167` `case (.drawing, .zoomApplied): return .none` | 画线模式下捏合**缩放全被吞**，visibleCount 一动不动 |
| `Reducer.swift:139` `case (.autoTracking, .panEnded), (.drawing, .panEnded): return .none` | 画线模式下松手拿不到 `.startDeceleration` → `TrainingEngine.endPan` 的 `guard case .startDeceleration` 早退 → **无惯性、且橡皮筋越界后弹不回来**（`applyPanOffset` 允许 damped overscroll） |
| `TrainingEngine.swift:938` `case .autoTracking, .drawing:` 走右锚缩放（offset 置 0） | 即便放开缩放，画线时捏合会把视口**跳回最新**，抹掉用户刚平移到的历史位置 |

因此本期把 `.drawing` 的**视口行为**整体对齐 `.freeScrolling`。`.drawing` 仍是独立 mode（tap 落锚语义、`drawingCommitted/Cancelled` 的 `baseRevision` 跨会话闸门、`isDrawingActive` 判据全部不变），改变的只有一件事：**它不再冻结视口**。这是 §5.4 验收 1/3 条的必要条件，不是范围扩张。

⚠️ 交给 codex 重点攻击的点：`FrozenPanelState`（`snapshot.frozen` 的 `offset` / `visibleCount` / `candleRange`）在视口解冻后语义变成「进画线那一刻的历史快照」。已核实：全仓**只**读 `snap.frozen.baseRevision`（`TrainingEngine.swift:1109` / `:1116`），其余字段无任何消费者（`RenderStateBuilder` 不读 `interactionMode`，视口是 mode-agnostic 的）。本期**不删**这些字段（P1c 的节点拖动可能要用），但要在 review 里确认没有隐藏消费者。

---

## File Structure

| 文件 | 责任 | 本期改动 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift` | 面板状态机唯一真相 | `.drawing` 的 `panEnded` / `offsetApplied` / `zoomApplied` 三 case 并入 `.freeScrolling` 分支 |
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | 引擎编排 | `applyPinch` 的 `.drawing` 改走 focus 路径；`switchPeriodCombo` 删画线守卫 + D31 钩子；新增 `restoreDrawingSessionAfterPeriodChange()`；订正 3 处已失效注释 |
| `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift` | 手势纯函数 | **删** `DrawingModePanPolicy` / `panPolicyInDrawingMode` / `singlePanStep(drawingTakesOver:)` 参数与早退分支 |
| `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift` | UIKit 识别器分发 | `handleSinglePan` 不再传 `drawingTakesOver`；订正类注释 |
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift` | 画线会话真相 | `commitPending` 增加「全锚同 period」断言（不同则拒交 + 只丢 pending） |
| `ios/Contracts/Tests/…/ReducerTests.swift` · `ReducerZoomTests.swift` | reducer 矩阵 | 3 条「drawing 吞没」测试**反转**为「drawing 应用」 |
| `ios/Contracts/Tests/…/GestureClassifiersTests.swift` | 手势纯函数测试 | 删 4 条 takeover 测试，加 1 个新 suite |
| `ios/Contracts/Tests/…/TrainingEngineDrawingSessionTests.swift` | 会话 × 引擎不变量 | 删 2 条「画线时切不了周期」，加 D31/D32/D29 联合测试 |
| `ios/Contracts/Tests/…/ChartEngine/DrawingGestureSourceGuardTests.swift` | **新建** 结构守卫 | takeover 通路已删除 + `handleSinglePan` 与画线无关 |
| `ios/Contracts/Tests/…/Drawing/DrawingSessionTests.swift` | 会话单元测试 | 加「混 period 锚拒交」两面测试 |

---

## Task 1: 视口解冻 —— `.drawing` 的平移 / 缩放 / 惯性对齐 `.freeScrolling`

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift:138-178`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift:925-941`（`applyPinch` 分支）、`:990-1000` 与 `:1185-1186`（注释订正）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift`（2 处）、`ReducerZoomTests.swift`（1 处）、`TrainingEngineDrawingSessionTests.swift`（新增 2 条 + 改写 1 条）、`TrainingEnginePanLinkageTests.swift`（改写 D10 那条，见 Step 7b）

**Interfaces:**
- Consumes: 无（本 task 是起点）
- Produces: 「画线模式下 `applyPanOffset` / `applyPinch` 真的改变 `panelState.offset` / `.visibleCount`，且面板仍留在 `.drawing`」这一行为契约。Task 3 的重新武装逻辑依赖它（切周期后 offset 归一在 `.drawing` 态也要生效）。

- [ ] **Step 1: 反转 reducer 的 3 条「drawing 吞没」测试（先红）**

在 `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift` 中，把 `ReducePanEndedTests` 的 `drawingNoBump` 整条替换为：

```swift
    @Test("drawing → bump + .startDeceleration(v)（1a-iv 视口解冻：画线时松手也要有惯性/回弹，否则橡皮筋越界回不来）")
    func drawingBumpAndEffect() {
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 5)
        let eff = s.reduce(.panEnded(velocity: 3.0))
        guard case .drawing = s.interactionMode else {
            Issue.record("panEnded 不得把面板踢出 .drawing（会话仍开着）")
            return
        }
        #expect(s.revision == 6)
        #expect(eff == .startDeceleration(velocity: 3.0))
    }
```

把 `ReduceOffsetAppliedTests` 的 `drawingSwallows` 整条替换为：

```swift
    @Test("drawing → offset += delta + bump（1a-iv 视口解冻；1a-iii 及以前恒被吞）")
    func drawingApplies() {
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 5, offset: 10)
        let eff = s.reduce(.offsetApplied(deltaPixels: 100))
        guard case .drawing = s.interactionMode else {
            Issue.record("offsetApplied 不得把面板踢出 .drawing（会话仍开着）")
            return
        }
        #expect(s.offset == 110)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }
```

同时把该 Suite 上方的 MARK 注释 `// MARK: - reduce: offsetApplied (autoTracking/freeScrolling bump + drawing 吞)` 改成
`// MARK: - reduce: offsetApplied (autoTracking/freeScrolling/drawing 三态均 += delta + bump)`。

在 `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerZoomTests.swift` 中，把 `drawingSwallows` 整条替换为：

```swift
    @Test("drawing：与 freeScrolling 同 —— visibleCount + offset 双应用 + bump（1a-iv 视口解冻）")
    func drawingAppliesLikeFreeScrolling() {
        let snapshot = DrawingSnapshot(frozen: FrozenPanelState(
            period: .m3, visibleCount: 80, offset: 0, candleRange: 0..<80, baseRevision: 7))
        var p = Self.panel(.drawing(snapshot: snapshot))
        let effect = p.reduce(.zoomApplied(visibleCount: 40, offset: 99))
        #expect(p.visibleCount == 40)
        #expect(abs(p.offset - 99) < 1e-9)
        #expect(p.revision == 8)
        #expect(effect == .none)
        guard case .drawing = p.interactionMode else {
            Issue.record("zoomApplied 不得改变 mode（画线会话仍在）")
            return
        }
    }
```

并把 Suite 名 `"Reducer zoomApplied（D1 三 mode 矩阵）"` 保持不变（矩阵仍是三态，只是 drawing 那格的期望变了）。

- [ ] **Step 2: 加 2 条引擎级行为测试（先红）**

在 `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift` 末尾（`}` 之前）追加：

```swift
    // MARK: 1a-iv 视口解冻：画线会话开着时，平移 / 缩放必须真的作用到视口

    @Test("1a-iv：画线会话开着时单指平移真的移动图表（1a-iii 及以前 offset 恒不动）")
    func panMovesChartWhileDrawing() {
        // fixture 必须**真的滚得动**：200 根 m3、起始 tick=150 → 左侧有历史，maxOffset>0。
        let (e, _) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let wide = TrainingEnginePanLinkageTests.bounds        // 800×600，makeEngine 已 recordRenderBounds
        e.toggleDrawingMode()
        #expect(e.isDrawingActive(on: .upper))                 // 防假绿：确实在画线态，不是普通滚动
        let before = e.upperPanel.offset

        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 120, renderBounds: wide, panel: .upper)

        #expect(e.upperPanel.offset > before)                  // 改造前：恒 == before（reducer 吞）
        e.endPan(velocity: 0, renderBounds: wide, panel: .upper)
        assertInvariant(e)                                     // 平移不得把面板踢出 .drawing
        #expect(e.drawingSession.drawingModeActive == true)
    }

    @Test("1a-iv：画线会话开着时双指缩放真的改变 visibleCount，且走 focus 路径（不右锚跳回最新）")
    func pinchZoomsWhileDrawing() {
        let (e, _) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let wide = TrainingEnginePanLinkageTests.bounds
        // 先滚出非零 offset —— 只有此时「右锚(offset=0)」与「focus 保持」才可区分
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 300, renderBounds: wide, panel: .upper)
        e.endPan(velocity: 0, renderBounds: wide, panel: .upper)
        #expect(e.upperPanel.offset > 0)                       // 防假绿

        e.toggleDrawingMode()
        let countBefore = e.upperPanel.visibleCount
        e.applyPinch(scale: 1.0, focusX: wide.midX, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: wide.midX, phase: .changed, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: wide.midX, phase: .ended, panel: .upper)

        #expect(e.upperPanel.visibleCount != countBefore)      // 改造前：恒不变（reducer 吞）
        #expect(e.upperPanel.offset != 0)                      // 走 focus 路径，不是右锚置 0 跳回最新
        assertInvariant(e)
    }
```

- [ ] **Step 3: 运行测试确认失败**

```bash
cd "<worktree>/ios/Contracts" && swift test --filter 'ReduceOffsetAppliedTests|ReducePanEndedTests|ReducerZoomTests|TrainingEngineDrawingSessionTests' 2>&1 | tail -30
```
Expected: FAIL —— `drawingApplies` 断言 `s.offset == 110` 实得 `10`；`drawingBumpAndEffect` 实得 `.none`；`drawingAppliesLikeFreeScrolling` 实得 `visibleCount == 80`；`panMovesChartWhileDrawing` / `pinchZoomsWhileDrawing` 实得「未变化」。

- [ ] **Step 4: 改 Reducer（3 个 case 并入 freeScrolling 分支）**

`ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift`：

`panEnded` 段改为：

```swift
        // —— panEnded ——
        case (.autoTracking, .panEnded):
            return .none
        // 1a-iv：.drawing 与 .freeScrolling 同 —— 画线时松手同样要走减速/回弹结算，
        // 否则 applyPanOffset 允许的 damped overscroll 松手后弹不回来，图表永久挂着越界间隙。
        case (.freeScrolling, .panEnded(let v)), (.drawing, .panEnded(let v)):
            revision &+= 1
            return .startDeceleration(velocity: v)
```

`offsetApplied` 段改为：

```swift
        // —— offsetApplied（三态均 += delta + bump）——
        // 1a-iv 视口解冻：.drawing 不再吞没。`.drawing` 仍是独立 mode（tap 落锚语义 / baseRevision 跨会话闸门
        // 不变），但**不再冻结视口** —— 画线模式下平移、切周期归一、resize 归一都必须真的作用到 offset。
        case (.autoTracking, .offsetApplied(let d)),
             (.freeScrolling, .offsetApplied(let d)),
             (.drawing, .offsetApplied(let d)):
            offset += d
            revision &+= 1
            return .none
```

`zoomApplied` 段改为：

```swift
        // —— zoomApplied（顺位 3 §4.4d：autoTracking 右锚置 0；freeScrolling/drawing focus offset）——
        case (.autoTracking, .zoomApplied(let v, _)):
            visibleCount = v
            offset = 0      // user 2026-06-13 裁决 A 右锚：显式置 0（防未来 drawingCommitted 残留 offset，R1-M3/L5）
            revision &+= 1
            return .none
        // 1a-iv：.drawing 与 .freeScrolling 同 —— 画线时捏合若走右锚会把视口跳回最新、抹掉用户刚平移到的历史位置。
        case (.freeScrolling, .zoomApplied(let v, let o)), (.drawing, .zoomApplied(let v, let o)):
            visibleCount = v
            offset = o
            revision &+= 1
            return .none
```

⚠️ 删除原来的 `case (.drawing, .offsetApplied): return .none` 与 `case (.drawing, .zoomApplied): return .none` 两行，否则 Swift 会因 case 重复而走进先匹配的那条（行为不变 = 测试仍红）。`.panStarted` 段**不动**（`.drawing` 保持 `return .none`：不切 mode、不 bump，pan 全靠 `.offsetApplied` 生效）。

- [ ] **Step 5: 改 `applyPinch` 的 `.drawing` 分支**

`ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`，`applyPinch` 内的 `switch ps.interactionMode`：

```swift
            switch ps.interactionMode {
            // 1a-iv：.drawing 与 .freeScrolling 同走 focus 不变量（捏合中点的 candle x 不动）。
            // 画线模式下用户很可能已经平移到历史区间，右锚缩放会把视口跳回最新、把刚画的线甩出屏幕。
            case .freeScrolling, .drawing:
                assert(bounds.origin == .zero, "focus 数学假设 view-local bounds 原点 .zero（R1-L6）")
                let candles = allCandles[ps.period] ?? []
                guard !candles.isEmpty else { return }
                let vp = RenderStateBuilder.makeViewport(panelState: ps, candles: candles,
                                                         tick: tick.globalTickIndex, bounds: bounds)
                let cIdx = RenderStateBuilder.currentCandleIndex(candles: candles,
                                                                 tick: tick.globalTickIndex)
                let offset = PinchZoomModel.rezoomOffset(viewport: vp, currentIdx: cIdx,
                                                         focusX: focusX, newCount: target,
                                                         mainWidth: vp.mainChartFrame.width)
                _ = reduce(.zoomApplied(visibleCount: target, offset: offset), on: panel)
            case .autoTracking:
                _ = reduce(.zoomApplied(visibleCount: target, offset: 0), on: panel)   // reducer 右锚显式置 0
            }
```

同时把 `applyPinch` 的文档注释里 `/// drawing 由 reducer 吞没（engine 不预判，统一派发）。` 改成
`/// drawing = freeScrolling 同路径（1a-iv 视口解冻；画线时捏合不得右锚跳回最新）。`

- [ ] **Step 6: 订正两处已失效的注释（它们现在是错的）**

`TrainingEngine.swift` `normalizeOffsetForCurrentBounds` 的文档注释里，把
`**为什么②是必须的（codex whole-branch R4-medium）**：reducer 在 `.drawing` 态**吞掉** `.offsetApplied`…`
整段替换为：

```swift
    /// **②的历史与现状（codex whole-branch R4-medium → 1a-iv）**：1a-iv 之前 reducer 在 `.drawing` 态**吞掉**
    /// `.offsetApplied`，画线期间的 resize/旋转归一被静默吞掉 → offset 停在越界值直到退出画线才补跑。
    /// 1a-iv 视口解冻后 `.drawing` 已接受 `.offsetApplied`，`recordRenderBounds` 那一路当场就归一了，
    /// 会话结束时的这次补跑退化为**幂等的防御**（clamped == cur → 不 reduce、不 bump）。保留它：
    /// 它同时兜住「会话结束时 bounds 恰好已变但尚未 record」的窗口，成本为零。
```

`endDrawingSessionIfActive` 里的
`// R4-medium：画线期间（`.drawing` 吞 `.offsetApplied`）发生的 resize/旋转，其 offset 归一被静默吞掉；`
改为
`// R4-medium（1a-iv 后退化为幂等防御，见 normalizeOffsetForCurrentBounds 文档）：补跑一次归一。`

`endPan` 内 `// L1 不变量：post-drag 面板恒 .freeScrolling …（autoTracking/drawing 不经此路且已 offset=0）` 一句里的 `/drawing` 删掉（1a-iv 起 `.drawing` **确实**经此路）。

- [ ] **Step 7: 改写「画线中途 resize」回归测试（缺陷已结构性消失）**

`TrainingEngineDrawingSessionTests.swift` 的 `resizeDuringContinuousDrawingIsNormalizedOnExit` 整条替换为：

```swift
    @Test("whole-branch R4-medium 回归（1a-iv 升级）：画线中途转屏/resize → offset **当场**被归一（视口解冻后不再等退出画线才补）")
    func resizeDuringContinuousDrawingIsNormalized() {
        // fixture 必须**真的滚得动**：200 根 m3、起始 tick=150 → 左侧有历史，maxOffset>0。
        let (e, _) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let wide = TrainingEnginePanLinkageTests.bounds        // 800×600，makeEngine 已 recordRenderBounds

        // ① 先滚动出一个非零 offset（freeScrolling）
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 300, renderBounds: wide, panel: .upper)
        e.endPan(velocity: 0, renderBounds: wide, panel: .upper)
        #expect(e.upperPanel.offset > 0)                       // 防假绿：确实滚出了 offset

        // ② 进画线模式（会话持续，画完一条也不退出）
        e.toggleDrawingMode()
        #expect(e.isDrawingActive(on: .upper))

        // ③ 画线期间转屏/resize：变窄后 maxOffset 变小，原 offset 越界。
        //    1a-iv 起 `.drawing` 接受 `.offsetApplied` → recordRenderBounds 的归一**当场**生效。
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 480)
        e.recordRenderBounds(narrow, panel: .upper)
        e.recordRenderBounds(narrow, panel: .lower)
        let during = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: narrow)
        #expect(e.upperPanel.offset <= during.maxOffset)       // 改造前：> maxOffset，要等退出画线才补
        #expect(e.upperPanel.offset >= during.minOffset)
        assertInvariant(e)                                     // 归一不得把面板踢出 .drawing

        // ④ 退出画线后依然合法（会话结束的补跑归一是幂等防御）
        e.toggleDrawingMode()
        let after = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: narrow)
        #expect(e.upperPanel.offset <= after.maxOffset)
        #expect(e.upperPanel.offset >= after.minOffset)
        assertInvariant(e)
    }
```

- [ ] **Step 7b: 改写 D10 联动测试（视口解冻推翻了它的前提）—— 并落定「画线时 follower 跟不跟」这个决策**

**决策（本 task 必须显式做出，不能靠默认）：画线模式下 follower 面板**照常被联动驱动**。**

理由：1a-iv 起画线是**全局会话**，上下两面板同时处于 `.drawing`。联动（RFC #4 D7）存在的全部理由就是让两面板右缘对齐到同一个 global tick；若 leader 跟手平移而 follower 冻着，两个面板的时间轴当场错位，用户在下面板看到的 K 线与上面板对不上——这比「画线时图表别动」严重得多。既有 D10 规则「follower 在 drawing 态不跟」的**唯一**依据是「反正画线时视口是冻的、跟不跟都看不出来」，这个前提正是本期推翻的对象。故不在 `propagateLinkage` 里给 drawing 开特例。

把 `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePanLinkageTests.swift` 的 `followerInDrawingNotDriven` 整条（含其上方那行 `// H1：D10 — follower 在 drawing 态时不跟（reducer 吞 .offsetApplied + .panStarted）。` 注释）替换为：

```swift
    // H1：D10（1a-iv 改写）—— 视口解冻后 follower 在 drawing 态**照常被驱动**。
    // 旧规则「drawing 态 follower 不跟」的依据是「reducer 吞 .offsetApplied、跟不跟都看不出来」；
    // 1a-iv 起两面板在画线会话里同时是 .drawing 且视口可动，follower 不跟 = 两面板时间轴错位。
    @Test("D10（1a-iv）：follower 处于 drawing 态**也**被联动驱动，且 interactionMode 仍是 drawing")
    func followerInDrawingIsDrivenAfterThaw() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        e.armPanelForDrawing(.trend, panel: .lower)                      // lower 进 drawing（仅武装 lower，不动 upper）
        let before = e.lowerPanel.offset
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 300, renderBounds: Self.bounds, panel: .upper)
        #expect(e.lowerPanel.offset != before)                           // ⭐改造前：== before（drawing 吞 .offsetApplied）
        if case .drawing = e.lowerPanel.interactionMode {} else { Issue.record("follower 应仍 drawing") }
    }

    @Test("D10（1a-iv）：全局画线会话里（**两面板都 .drawing**）平移 leader → 两面板保持对齐")
    func bothPanelsInDrawingStayAlignedWhilePanning() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        e.toggleDrawingMode()                                            // 全局会话：两面板同时 .drawing
        #expect(e.isDrawingActive(on: .upper) && e.isDrawingActive(on: .lower))   // 前置
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 300, renderBounds: Self.bounds, panel: .upper)
        #expect(e.upperPanel.offset > 0)                                 // leader 真的动了
        #expect(e.lowerPanel.offset > 0)                                 // ⭐follower 跟上（不跟 = 两面板时间轴错位）
    }
```

⚠️ 若 `swift test` 显示这两条之外还有别的联动/减速测试因视口解冻变红：**先打印真实值再判断**，逐条判定「旧期望的依据是不是『drawing 吞没』」——是则改期望并在 commit message 说明，不是则说明视口解冻踩到了预料外的东西，**停下来报告**，不要为了让测试变绿去改产品代码。

- [ ] **Step 8: 运行 host 全量测试**

```bash
cd "<worktree>/ios/Contracts" && git branch --show-current && git rev-parse --short HEAD && swift test 2>&1 | tail -20
```
Expected: 全绿。若有其它测试因 `.drawing` 视口解冻而红，**先打印真实值再判断**（不要纸上推状态机），并在 commit message 里逐条说明为什么该测试的旧期望失效。

- [ ] **Step 9: fresh 非增量 Catalyst 对基线**

```bash
cd "<worktree>/ios/Contracts" && rm -rf /tmp/derived-1aiv && \
  xcodebuild test -scheme KlineTrainerContracts-Package \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -only-testing:KlineTrainerContractsTests \
    -derivedDataPath /tmp/derived-1aiv 2>&1 | tee /tmp/catalyst-1aiv.log | tail -5
bash .github/scripts/catalyst-gate.test.sh && bash .github/scripts/catalyst-gate.sh /tmp/catalyst-1aiv.log
```
Expected: `TEST SUCCEEDED` + `GATE PASS`。记录 `Test run with N tests` 的真实 N，与 `.github/scripts/catalyst-total-baseline.txt`（1532）比对；漂出 ±30 则在本 commit 内更新该文件。

- [ ] **Step 10: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift \
        ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ReducerZoomTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePanLinkageTests.swift
git commit -m "1a-iv Task1：视口解冻——.drawing 的平移/缩放/惯性对齐 .freeScrolling

- Reducer：.drawing 不再吞 .offsetApplied / .zoomApplied；.panEnded 发 .startDeceleration
- applyPinch：.drawing 改走 focus 不变量路径（不右锚跳回最新）
- D10 决策：画线态 follower 照常被联动驱动（不跟 = 两面板时间轴错位），改写对应测试
- 3 条「drawing 吞没」reducer 测试反转为「drawing 应用」+ 3 条引擎级行为测试
- R4-medium resize 回归测试升级为「当场归一」"
```

---

## Task 1b: 落锚前先「定住」视口 —— 惯性未停时不许落锚（Task 1 新造出的路）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（新增 internal `settleDeceleration(initiatedBy:)`；`beginPan` / `applyPinch(.began)` 改调它；`cancelPan` 的归一补 propagate）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift:271-288`（`handleDrawingTap` 开头）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`（2 条行为测试）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/DrawingGestureSourceGuardTests.swift`（顺序守卫，**本文件由 Task 2 Step 1 创建 → 本 task 必须排在 Task 2 之后执行**）

**Interfaces:**
- Consumes: Task 1 的 `.drawing` `panEnded → .startDeceleration`（惯性由它引入）；Task 2 建立的 `source(_:)` 守卫 helper
- Produces: `func settleDeceleration(initiatedBy: PanelId)`（internal，两面板都停+夹回，再从发起面板补一次联动）；`interruptDeceleration` 改为 `@discardableResult -> Bool`

**问题 ①（codex plan-R2-high，实测确认）**：Task 1 让画线模式下松手能起惯性。而 `ChartContainerView.handleDrawingTap` 读的是 `view.renderState.viewport` —— 它由上一帧渲染产生，惯性运行期间**落后于 engine 的真实 offset 最多一帧**。用它做 tap→candleIndex 映射，快速甩动时锚点会落到手指指向之外的 K 线上（一帧可跑好几根），而且提交完图表还在继续滑。1a-iv 之前 `.drawing` 没有惯性、tap 恒发生在静止视口上，所以这条路是**本期新造的**。

**问题 ②（codex plan-R3-medium，实测确认）**：新交互起手时只中断**自己那一侧**的减速是不够的。实测两条事实：
- 减速每帧 `floorOrFullClampedOffsetDelta` 末尾会 `propagateLinkage(fromLeader: panel)`（`TrainingEngine.swift:782`）—— **正在减速的面板每帧都在驱动另一个面板的 offset**。
- 两个 animator **可以同时在跑**（`endPan` 只给被拖的那个面板 `start`，但用户可以先甩上面板、再甩下面板）。故「同时最多一个 animator」的直觉是错的。

于是：甩上面板 → 立刻捏合下面板。`applyPinch(.began)` 的 `interruptDeceleration(panel:)` 只停了下面板（它本来就没在跑），上面板的 animator 继续每帧改下面板 offset → focus 不变量被破坏、缩放结果取决于帧序。`beginPan` 有同样的单面板假设。**这条竞态在非画线模式下已经存在**（本期不是它的成因），但 1a-iv 把它扩散到画线模式，且在那里会直接把锚点落错位置。

**决策**：
1. **tap 先定住、再映射**（不是「惯性期间拒收 tap」）。拒收会让用户在图还在滑时点了没反应，手感更差；「点一下先截住惯性」是图表/滚动列表的标准语义。顺序必须是 ①停减速+归一 → ②**重建 renderState** 让 viewport 与已 settle 的 offset 一致 → ③映射 → ④提交；**漏掉②等于没修**（viewport 仍是停之前那一帧）。
2. **新交互起手一律停两面板**：`beginPan` / `applyPinch(.began)` / 画线 tap 三处统一改调 `settleDeceleration(initiatedBy:)`。这同时关掉了上面那条**既有**的非画线竞态 —— 修 root cause 而不是只在画线路径上打补丁（本仓教训：修 symptom 只会挪动失败面）。安全性论证：`interruptDeceleration` 对**没在跑**的面板是纯 no-op（`wasRunning == false` → 不 clamp、不 reduce），所以「多停一个」不会引入新的状态改动。

- [ ] **Step 1: 写失败测试（先红）**

在 `TrainingEngineDrawingSessionTests.swift` 末尾追加：

```swift
    @Test("1a-iv：画线模式甩动起惯性后，settleDeceleration(initiatedBy:) 必须把两面板都定住（落锚不得对着移动中的视口）")
    func settleDecelerationStopsInertiaOnBothPanels() {
        // ⚠️ fixture 必须**真的滚得动**（codex plan-R6-high）：`engineMultiPeriod()` 只有 2 根 m60 / 1 根 daily，
        // maxOffset≈0 → 惯性根本跑不起来，「惯性在跑」的前置断言会红或被人调松，整条测试变空气。
        let (e, fakes) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let bounds = TrainingEnginePanLinkageTests.bounds       // 800×600，makeEngine 已 recordRenderBounds
        #expect(RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: bounds).maxOffset > 0)   // 前置：真有滚动空间
        e.toggleDrawingMode()
        #expect(e.isDrawingActive(on: .upper))                 // 前置：真在画线态

        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 200, renderBounds: bounds, panel: .upper)
        e.endPan(velocity: 3000, renderBounds: bounds, panel: .upper)   // 大速度 → 起惯性
        _ = fakes().last?.fire(1.0 / 60.0)
        let mid = e.upperPanel.offset
        _ = fakes().last?.fire(1.0 / 60.0)
        #expect(e.upperPanel.offset != mid)                    // 防假绿：惯性确实在跑（否则本测试测的是空气）

        e.settleDeceleration(initiatedBy: .upper)

        let settledUpper = e.upperPanel.offset
        let settledLower = e.lowerPanel.offset
        for _ in 0..<10 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(e.upperPanel.offset == settledUpper)           // ⭐已定住，后续帧不再改 offset
        #expect(e.lowerPanel.offset == settledLower)           // ⭐follower 也不再被联动驱动
        assertInvariant(e)                                     // 定住不得把面板踢出 .drawing
    }
```

另外追加第二条（覆盖问题②的跨面板竞态，codex plan-R3-medium 点名要的 fake-driver 回归）：

```swift
    @Test("1a-iv：甩上面板起惯性后立刻捏合**下**面板 —— 上面板的减速不得再经联动改下面板 offset")
    func pinchOnOnePanelSettlesTheOtherPanelsInertia() {
        // fixture 同上：必须真的滚得动（codex plan-R6-high）
        let (e, fakes) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let bounds = TrainingEnginePanLinkageTests.bounds
        #expect(RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: bounds).maxOffset > 0)
        e.toggleDrawingMode()

        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 200, renderBounds: bounds, panel: .upper)
        e.endPan(velocity: 3000, renderBounds: bounds, panel: .upper)   // 上面板起惯性
        _ = fakes().last?.fire(1.0 / 60.0)
        let lowerMid = e.lowerPanel.offset
        _ = fakes().last?.fire(1.0 / 60.0)
        #expect(e.lowerPanel.offset != lowerMid)                        // 防假绿：上面板减速确实在经联动驱动下面板

        e.applyPinch(scale: 1.0, focusX: bounds.midX, phase: .began, panel: .lower)   // 捏合**下**面板

        let lowerAtPinchStart = e.lowerPanel.offset
        for _ in 0..<10 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(e.lowerPanel.offset == lowerAtPinchStart)               // ⭐上面板的 stale 减速不再动下面板
        assertInvariant(e)
    }
```

再追加第三条（覆盖 codex plan-R6-medium 的 bounce-clamp 错位）：

```swift
    @Test("1a-iv：在 overscroll 回弹中途定住 —— 夹回界内后两面板右缘仍对齐同一 tick（不留错位）")
    func settleDuringBounceKeepsPanelsTimeAligned() {
        let (e, fakes) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let bounds = TrainingEnginePanLinkageTests.bounds
        e.toggleDrawingMode()

        // 拖到**超过 maxOffset**（最老边橡皮筋）再松手 → 走 bounce 分支（allowOverscroll）
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: bounds)
        #expect(ob.maxOffset > 0)                                    // 前置：真有滚动空间
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset + 400, renderBounds: bounds, panel: .upper)
        e.endPan(velocity: 0, renderBounds: bounds, panel: .upper)
        _ = fakes().last?.fire(1.0 / 60.0)
        #expect(e.upperPanel.offset > ob.maxOffset)                  // 前置：确实还在越界区（否则测不到 clamp）

        e.settleDeceleration(initiatedBy: .upper)

        // ⭐夹回界内 + 两面板右缘仍指向同一个 global tick
        #expect(e.upperPanel.offset <= ob.maxOffset)
        let upperTick = PanLinkage.rightEdgeTick(offset: e.upperPanel.offset,
                                                 candles: e.allCandles[e.upperPanel.period] ?? [],
                                                 rawVisible: e.upperPanel.visibleCount,
                                                 bounds: bounds, tick: e.tick.globalTickIndex)
        let lowerTick = PanLinkage.rightEdgeTick(offset: e.lowerPanel.offset,
                                                 candles: e.allCandles[e.lowerPanel.period] ?? [],
                                                 rawVisible: e.lowerPanel.visibleCount,
                                                 bounds: bounds, tick: e.tick.globalTickIndex)
        #expect(upperTick == lowerTick)                              // ⭐无错位（补 propagate 之前这里会不等）
    }
```

⚠️ 若 `PanLinkage.rightEdgeTick` / `allCandles` / `tick` 的可见性不足以在测试里直接调，改用等价的可观测判据：
`settleDeceleration(initiatedBy:)` 之后再 `fire` 一帧，两面板 offset 都不再变，且 `e.lowerPanel.offset` 等于
「以夹回后的 upper 为 leader 重新 propagate 一次」的结果（可用 `e.beginPan(panel:.upper)` + 零位移 `applyPanOffset` 触发）。
**不要**因为不好断言就删掉这条测试。

再追加第四条（覆盖 codex plan-R7-high 的 `cancelPan` 站点，用真实 UIKit 时序：先 cancelPan、后 pinch.began）：

```swift
    @Test("1a-iv：拖到越界时两指接管（先 cancelPan 再 pinch.began）—— 夹回后两面板右缘仍对齐同一 tick")
    func twoFingerTakeoverDuringOverscrollKeepsPanelsTimeAligned() {
        let (e, _) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let bounds = TrainingEnginePanLinkageTests.bounds
        e.toggleDrawingMode()
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: bounds)
        #expect(ob.maxOffset > 0)                                    // 前置：真有滚动空间

        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset + 400, renderBounds: bounds, panel: .upper)
        #expect(e.upperPanel.offset > ob.maxOffset)                  // 前置：确实拖进了越界区

        // 真实 UIKit 时序：两指落下 → arbiter supersede 单指 → onPan(.cancelled) → cancelPan → 然后 pinch.began
        e.cancelPan(panel: .upper)
        e.applyPinch(scale: 1.0, focusX: bounds.midX, phase: .began, panel: .upper)

        #expect(e.upperPanel.offset <= ob.maxOffset)                 // 夹回界内
        let upperTick = PanLinkage.rightEdgeTick(offset: e.upperPanel.offset,
                                                 candles: e.allCandles[e.upperPanel.period] ?? [],
                                                 rawVisible: e.upperPanel.visibleCount,
                                                 bounds: bounds, tick: e.tick.globalTickIndex)
        let lowerTick = PanLinkage.rightEdgeTick(offset: e.lowerPanel.offset,
                                                 candles: e.allCandles[e.lowerPanel.period] ?? [],
                                                 rawVisible: e.lowerPanel.visibleCount,
                                                 bounds: bounds, tick: e.tick.globalTickIndex)
        #expect(upperTick == lowerTick)                              // ⭐无错位（补 propagate 之前这里会不等）
    }
```

跑 `swift test --filter 'settleDecelerationStopsInertiaOnBothPanels|pinchOnOnePanelSettlesTheOtherPanelsInertia|settleDuringBounceKeepsPanelsTimeAligned|twoFingerTakeoverDuringOverscrollKeepsPanelsTimeAligned'`，Expected: 前三条**编译失败**（`settleDeceleration(initiatedBy:)` 不存在）—— 这就是本步要的红。

- [ ] **Step 2: 加 `settleDeceleration(initiatedBy:)` 并把三个起手点都改调它**

`TrainingEngine.swift`，紧挨 `stopAllDeceleration()` 之后插入：

```swift
    /// 新交互起手时把**两个面板**的减速一并定住（停 + 归一中途 overscroll）。
    /// **为什么必须是两个而不是「自己那一个」（codex plan-R3-medium，实测确认）**：
    ///   · 减速每帧 `floorOrFullClampedOffsetDelta` 末尾会 `propagateLinkage` —— 正在减速的面板每帧都在改**另一个**面板的 offset；
    ///   · 两个 animator 可以同时在跑（`endPan` 只给被拖的面板 start，但用户可以先甩上、再甩下）。
    /// 于是「甩上面板 → 立刻捏合/拖动/点按下面板」时，只停下面板等于没停：上面板的 animator 继续经联动改它。
    /// 对**没在跑**的面板，`interruptDeceleration` 是纯 no-op（`wasRunning == false` → 不 clamp、不 reduce），
    /// 所以「多停一个」不引入任何额外状态改动。
    /// **停完必须补一次联动（codex plan-R6-medium）**：`interruptDeceleration` 在 bounce/overscroll 中途停时会
    /// 把 leader 的 offset 夹回界内，但它**不 propagate** —— 于是 follower 还停在夹回**之前**那个右缘对应的 tick 上，
    /// 两面板时间轴错位（正常减速帧每帧都会 propagate，唯独这个「最后一次修正」不会）。
    /// **leader 必须显式指定（codex plan-R8-high）**：两个 animator 可以同时在跑、于是可能两个面板都夹过。
    /// 若「谁夹过就从谁 propagate」，遍历顺序就成了隐式 leader（lower 后处理 → lower 赢），会在用户
    /// 明明在**上**面板起手时把上面板的 offset 改掉 —— 图当场跳一下，或者锚落错 candle。
    /// 正确顺序：**先把两个都停+夹完，再从「本次交互的发起面板」propagate 一次**。
    /// `initiatedBy` = 谁被拖 / 被捏 / 被点。都没夹过则不 propagate（整个函数 no-op）。
    func settleDeceleration(initiatedBy panel: PanelId) {
        let upperClamped = interruptDeceleration(panel: .upper)
        let lowerClamped = interruptDeceleration(panel: .lower)
        if upperClamped || lowerClamped { propagateLinkage(fromLeader: panel) }
    }
```

配套把 `interruptDeceleration` 改成**返回「本次是否真的夹过 offset」**（签名从 `-> Void` 改 `@discardableResult -> Bool`，
既有三个调用点 `beginPan` / `applyPinch(.began)` / `armPanelForDrawing` 的写法一律不动）：

```swift
    @discardableResult
    private func interruptDeceleration(panel: PanelId) -> Bool {
        let a = animator(for: panel)
        let wasRunning = a.isDecelerating
        a.stop()
        guard wasRunning, let act = activeBoundsFor(panel) else { return false }
        let cur = panelState(panel).offset
        let clamped = min(max(cur, act.bounds.minOffset), act.bounds.maxOffset)
        guard clamped != cur else { return false }
        _ = reduce(.offsetApplied(deltaPixels: clamped - cur), on: panel)   // overscroll(>max) 归 maxOffset
        return true
    }
```

然后把两个既有起手点从单面板中断改为全停：
- `beginPan(panel:)` 里的 `interruptDeceleration(panel: panel)` → `settleDeceleration(initiatedBy: panel)`（其后的 `setDragRaw` / `.panStarted` / `propagateLinkage` 一律不动）
- `applyPinch` 的 `case .began:` 里的 `interruptDeceleration(panel: panel)` → `settleDeceleration(initiatedBy: panel)`

**还有第三个「夹回但不补联动」的站点：`cancelPan`（codex plan-R7-high）**。UIKit 真实时序是：两指落下 → `ChartGestureArbiter.handlePinch(.began)` **先**调 `supersedeSinglePanForMultitouch` 发 `.cancelled` → `ChartContainerView` 路由到 `engine.cancelPan(panel:)` → **然后**才轮到 `applyPinch(.began)`。而 `cancelPan` 里那句 overscroll 归一（`TrainingEngine.swift:895`）同样只夹自己、不 propagate。Task 1 让画线态 follower 跟随 leader 之后，「拖到最老边越界 → 落第二根手指」就会把 leader 夹回、follower 却停在夹回**之前**的右缘 → 两面板时间轴错位，而画线会话还开着，后续落锚的 candle 语境就是错的。

把 `cancelPan` 末尾那三行归一改成夹完就补联动：

```swift
        // R1b-drag E4：cancel-于-overscroll（两指接管/画线截获于越界）→ 归一 maxOffset 防残留间隙。
        // 1a-iv（codex plan-R7-high）：夹回后**必须补一次联动** —— 与 settleDeceleration(initiatedBy:) 同理，
        // 正常拖动每帧都会 propagate，唯独这次「取消时的最后修正」不会；画线态 follower 会跟随 leader
        // （Task 1 视口解冻）后，不补就是两面板时间轴错位、而画线会话仍开着。
        let ob = RenderStateBuilder.offsetBounds(engine: self, panel: panel, bounds: renderBounds(panel))
        let cur = panelState(panel).offset
        let clamped = min(max(cur, ob.minOffset), ob.maxOffset)
        if clamped != cur {
            _ = reduce(.offsetApplied(deltaPixels: clamped - cur), on: panel)
            propagateLinkage(fromLeader: panel)
        }
```

⚠️ `armPanelForDrawing` 里的 `interruptDeceleration(panel: panel)` **不改**：它有自己的顺序契约（必须在捕获 `baseRev` 之前、且只关心被武装的那个面板的 revision），改成全停会让另一面板的归一 `offsetApplied` 插进来 bump revision。画线会话的两面板武装本来就会各调一次。

跑上面两条测试，Expected: 都 PASS。**若有既有的联动/减速测试因「多停一个」变红**：先打印真实值，确认是不是该测试依赖了「甩一个面板后另一个面板仍在被驱动」这一竞态；是则改期望并说明，不是则停下来报告。

- [ ] **Step 3: 接进 `handleDrawingTap`（顺序 load-bearing）**

`ChartContainerView.swift` 的 `handleDrawingTap`，把

```swift
            // 空图表（candleStep==0）→ xToIndex 会 Int(NaN) 崩溃 → 守卫（spec §四 load-bearing）。
            let viewport = view.renderState.viewport
```

替换为：

```swift
            // 1a-iv（codex plan-R2-high）：画线模式现在可以有惯性。**顺序 load-bearing**：
            //   ① 停两面板减速 + 归一 → ② 重建 renderState（让 viewport 与已 settle 的 offset 一致）
            //   → ③ 才能拿 viewport 做映射。漏掉②等于没修：viewport 仍是停之前那一帧的。
            // 语义选「点一下先截住惯性」而非「惯性期间拒收 tap」：后者会让用户在图还在滑时点了没反应。
            engine.settleDeceleration(initiatedBy: panel)
            rebuildRenderState(bounds: view.bounds)
            // 空图表（candleStep==0）→ xToIndex 会 Int(NaN) 崩溃 → 守卫（spec §四 load-bearing）。
            let viewport = view.renderState.viewport
```

- [ ] **Step 4: 加顺序守卫（Task 2 已建好 `DrawingGestureSourceGuardTests`）**

在 `DrawingGestureSourceGuardTests.swift` 追加：

```swift
    private let chartContainer = "Sources/KlineTrainerContracts/Render/ChartContainerView.swift"

    @Test("1a-iv：handleDrawingTap 必须先 settle + 重建 renderState，**再**建 CoordinateMapper（顺序 load-bearing）")
    func drawingTapSettlesBeforeMapping() throws {
        let code = try source(chartContainer)
        guard let start = code.range(of: "private func handleDrawingTap(at point: CGPoint)") else {
            Issue.record("切片锚点找不到 —— handleDrawingTap 被改名？守卫失效，必须修")
            return
        }
        let body = String(code[start.lowerBound...])
        guard let settle = body.range(of: "settleDeceleration(initiatedBy:"),
              let rebuild = body.range(of: "rebuildRenderState("),
              let vpRead = body.range(of: "let viewport = view.renderState.viewport"),
              let mapper = body.range(of: "CoordinateMapper(") else {
            Issue.record("handleDrawingTap 里缺 settleDeceleration / rebuildRenderState / viewport 读取 / CoordinateMapper 之一")
            return
        }
        #expect(settle.lowerBound < rebuild.lowerBound)    // ⭐先停再重建（反了则重建的是停之前的状态）
        #expect(rebuild.lowerBound < vpRead.lowerBound)    // ⭐viewport 必须在重建**之后**才读
        #expect(vpRead.lowerBound < mapper.lowerBound)     // ⭐读到的那个 viewport 才拿去建 mapper
    }
```

⚠️ 第二条断言是 codex plan-R4-medium 点名要的：只查「settle/rebuild 在 mapper 之前」挡不住「**先**把 `viewport` 存进局部变量、**再** settle+rebuild、然后拿旧局部变量建 mapper」这种改法 —— 那样字符串顺序全对、映射却仍是 stale 的。

- [ ] **Step 5: mutation-verify 顺序守卫**


> **⚠️ mutation-verify 的撤销方式（codex plan-R3-high）：绝对不要用 `git checkout -- <file>`。**
> 本 task 的真实改动此刻**尚未 commit**，`git checkout --` 会用 HEAD/index 的版本覆盖整个文件、
> 把你刚写完的实现连同任何无关的本地改动一起抹掉。统一改用「先备份、再改坏、再还原、最后用 `git diff` 自证」：
>
> ```bash
> F=<被改坏的文件路径>
> BAK="$TMPDIR/mutverify-$(basename "$F").bak"
> cp "$F" "$BAK"                     # ① 备份「正确版本」
> #   ② 手动把 mutation 改进 $F，跑指定测试，确认 FAIL
> cp "$BAK" "$F" && rm "$BAK"        # ③ 从备份还原（不碰 git）
> git diff --stat -- "$F"            # ④ 自证：还原后该文件的 diff 与 mutation 之前一致
> #   ⑤ 重跑测试确认恢复绿
> ```

mutation：把 `handleDrawingTap` 里的 `engine.settleDeceleration(initiatedBy: panel)` 一行剪切到 `let mapper = CoordinateMapper(...)` 之后（被改坏的文件 = `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift`）。

跑 `swift test --filter drawingTapSettlesBeforeMapping`，Expected: **FAIL**。按上面 ③④⑤ 还原并确认恢复绿。

- [ ] **Step 5b: 加一条**真跑落锚**的 Catalyst 行为测试（源码顺序守卫证明不了映射结果）**

源码顺序守卫只证明「代码是按这个顺序写的」，证明不了「锚真的落在定住后的那根 K 线上」（codex plan-R4-medium）。补一条真调 `handleDrawingTapForTesting` 的 UIKit 测试。

在 `ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewDrawingSessionTests.swift` 的 Suite 末尾追加：

```swift
    @Test("1a-iv：惯性未停时点击 —— 锚落在**定住后**视口映射的那根 K 线上，且提交后图不再滑")
    func tapDuringInertiaUsesSettledViewport() {
        // 需要「真滚得动 + 可控帧驱动」的 engine：makeRig 的 preview fixture 只有 1 根可见 candle、滚不动。
        let (engine, fakes) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let panelBounds = TrainingEnginePanLinkageTests.bounds       // 800×600，makeEngine 已 recordRenderBounds
        let c = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let v = KLineView(frame: panelBounds)
        c.attach(to: v)
        c.rebuildRenderState(bounds: panelBounds)
        engine.toggleDrawingMode()
        #expect(engine.isDrawingActive(on: .upper))                  // 前置：真在画线态

        // 甩出惯性 → 记下「滑动中」这一帧的 renderState → 再让 engine 多跑 6 帧但**不重建** → view 里的 viewport 变 stale
        engine.beginPan(panel: .upper)
        engine.applyPanOffset(deltaPixels: 200, renderBounds: panelBounds, panel: .upper)
        engine.endPan(velocity: 3000, renderBounds: panelBounds, panel: .upper)
        c.rebuildRenderState(bounds: panelBounds)
        let staleVP = v.renderState.viewport
        for _ in 0..<6 { _ = fakes().last?.fire(1.0 / 60.0) }

        // 取可见 slice **中部**的点：定住后索引会平移几根，取首根会掉出 slice 被 tapToAnchor fail-closed 拒掉。
        let staleMapper = CoordinateMapper(viewport: staleVP, displayScale: v.traitCollection.displayScale)
        let midIdx = staleVP.startIndex + staleVP.visibleCount / 2
        let point = CGPoint(x: staleMapper.indexToX(midIdx) + staleVP.geometry.candleStep / 2,
                            y: staleVP.mainChartFrame.midY)

        c.handleDrawingTapForTesting(at: point)

        let settledMapper = CoordinateMapper(viewport: v.renderState.viewport,
                                             displayScale: v.traitCollection.displayScale)
        let settledIdx = settledMapper.xToIndex(point.x)
        #expect(settledIdx != staleMapper.xToIndex(point.x))         // 防假绿：stale 与 settled 真的映射到不同 candle
        #expect(engine.drawings.count == 1)                          // 线真的落了（没被 fail-closed 守卫吞掉）
        #expect(engine.drawings.first?.anchors.first?.candleIndex == settledIdx)   // ⭐用的是定住后的映射

        let afterTap = engine.upperPanel.offset
        for _ in 0..<10 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(engine.upperPanel.offset == afterTap)                // ⭐惯性已被 tap 截住，提交后图不再滑
    }
```

⚠️ 若 `#expect(settledIdx != staleMapper.xToIndex(point.x))` 变红 = 这 6 帧滑得不够远、stale 与 settled 恰好映射到同一根 → 调大 `velocity` 或帧数**直到它绿**，**不要**删掉这条断言（删了整个测试就变成空气）。

⚠️ 本条是 **UIKit-gated 新测试** → 必须重新生成 UIKit 基线（否则 `catalyst-gate.test.sh` 会红）：

```bash
python3 .github/scripts/uikit-expected-tests.py > .github/scripts/catalyst-uikit-baseline.txt
```

- [ ] **Step 6: host 全量 + fresh 非增量 Catalyst 对基线**（命令同 Task 1 Step 8/9）

- [ ] **Step 7: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewDrawingSessionTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/DrawingGestureSourceGuardTests.swift \
        .github/scripts/catalyst-uikit-baseline.txt
git commit -m "1a-iv Task1b：落锚前先定住视口——惯性期间 tap 不再对着移动中的 viewport 映射

- 新增 engine.settleDeceleration(initiatedBy: panel)（两面板都停，防甩上面板去点下面板经联动仍在动）
- handleDrawingTap 顺序：停减速 → 重建 renderState → 映射 → 提交（顺序守卫 + mutation-verify）"
```

---

## Task 2: D32 —— 原子删除画线截获单指 pan 的整条通路

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift:55-64`（删类型+函数）、`:103-122`（删参数+早退分支）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift:16-17, 44, 166-171`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/GestureClassifiersTests.swift`（删 4 条、加 1 个 suite）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`（删 `periodSwitchUnreachableWhileDrawing`）
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/DrawingGestureSourceGuardTests.swift`

**Interfaces:**
- Consumes: Task 1 的视口解冻（否则手势放开了也看不见位移）
- Produces: `singlePanStep(phase:cumulative:velocityX:lifecycle:lastTranslationX:minThreshold:)` —— **不再有 `drawingTakesOver` 参数**。Task 3 不直接调它，但源码守卫文件 `DrawingGestureSourceGuardTests.swift` 的 `source(_:)` helper 由本 task 建立，Task 3 若需要源码守卫直接复用同一文件。

**为什么是「原子删」而不是「改成恒 normalPass」**：留下一个恒为 `false` 的 `drawingTakesOver` 参数 = 「画线吞掉平移」这个危险状态**仍可被表达**，任何人传一次 `true` 就能悄悄复活它。沿用本仓既有先例（1a-iii 切片3 原子删 `colorEnabled`：函数 + UI 引用 + 测试同一个 commit，过 Catalyst 编译门）。`panPolicyInDrawingMode` / `DrawingModePanPolicy` 是 `public`，删除属于 public API 移除 —— 与切片3 删 `colorEnabled` 同一裁决（user 已拍板「不留 shim」），无包外消费者（全仓唯一调用点是 `ChartGestureArbiter:171`）。

- [ ] **Step 1: 建源码守卫测试文件（先红）**

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/DrawingGestureSourceGuardTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/DrawingGestureSourceGuardTests.swift
// Spec: 2026-07-10-drawing-tools-P1b-split-addendum.md §5.1 #1 / §5.3 #1（D32）。
// 结构守卫：spec 要求「画线模式下单指 pan 不再被无条件截获」。行为测试测不到「代码里还留着一条截获通路」——
// 纯函数已经与画线状态**完全无关**（参数都删了），能证明这一点的只有源码文本。
// 反踩坑（memory: acceptance grep 两坑）：先**剥掉注释行**再匹配，否则解释性注释里的字样会误判。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("1a-iv D32 结构守卫：画线截获单指 pan 的通路已原子删除")
struct DrawingGestureSourceGuardTests {

    /// ios/Contracts 目录（由本测试文件路径回推：Tests/KlineTrainerContractsTests/ChartEngine/<本文件> → 上溯 4 层）。
    private var contractsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // ChartEngine
            .deletingLastPathComponent()    // KlineTrainerContractsTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // ios/Contracts
    }

    /// 读源码并**剥掉注释**后返回（整行注释丢弃；行尾 `//` 之后截断）。
    private func source(_ relativeToContracts: String) throws -> String {
        let url = contractsDir.appendingPathComponent(relativeToContracts)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }

    private let classifiers = "Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift"
    private let arbiter     = "Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift"

    @Test("GestureClassifiers 里不再有任何画线截获通路（类型 / 函数 / 参数全删）")
    func noTakeoverPathInClassifiers() throws {
        let code = try source(classifiers)
        #expect(code.contains("func singlePanStep("))     // 防路径写错→空内容→负向断言假绿
        #expect(!code.contains("drawingTakesOver"))
        #expect(!code.contains("DrawingModePanPolicy"))
        #expect(!code.contains("panPolicyInDrawingMode"))
    }

    @Test("ChartGestureArbiter.handleSinglePan **完全不读** drawingMode（tap 落锚路径仍读，故只锁单指 pan handler）")
    func singlePanHandlerIsDrawingAgnostic() throws {
        let code = try source(arbiter)
        guard let start = code.range(of: "func handleSinglePan("),
              let end = code.range(of: "func handleTwoFingerPan(") else {
            Issue.record("切片锚点找不到（handleSinglePan / handleTwoFingerPan 被改名？）—— 守卫失效，必须修")
            return
        }
        let body = String(code[start.lowerBound..<end.lowerBound])
        #expect(body.contains("singlePanStep("))          // 防切片为空 → 负向断言假绿
        #expect(!body.contains("drawingMode"))
        #expect(!body.contains("panPolicyInDrawingMode"))
        // 对照：drawingMode 本身没被删（tap 落锚仍要用它），否则这条守卫等于测了个空气
        #expect(code.contains("drawingMode"))
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
cd "<worktree>/ios/Contracts" && swift test --filter DrawingGestureSourceGuardTests 2>&1 | tail -20
```
Expected: FAIL —— `!code.contains("drawingTakesOver")` 不成立（源码里还在）。

- [ ] **Step 3: 删 `GestureClassifiers.swift` 的截获通路**

删除这一整段（`:55-64`）：

```swift
/// Drawing 模式 Pan 截获策略（spec §C7 v1.2）。
public enum DrawingModePanPolicy: Equatable, Sendable {
    case drawingTakesOver    // Pan 被绘线工具吃掉
    case normalPass          // 普通透传
}

/// Drawing 模式下 Pan 归属（spec L1393-1395 逐字）。
public func panPolicyInDrawingMode(drawingMode: Bool) -> DrawingModePanPolicy {
    drawingMode ? .drawingTakesOver : .normalPass
}
```

把 `singlePanStep` 的签名末尾参数 `drawingTakesOver: Bool = false` 删除，并删掉函数体开头的整个早退分支（原 `:110-122`，从注释 `// Drawing 模式截获（修正 R4 + R5 finding-1 + R13 finding-2）…` 到 `}` 为止的 `if drawingTakesOver { … }` 整块）。

在 `singlePanStep` 的文档注释「关键不变量」列表末尾追加一条：

```swift
/// - **1a-iv D32：本函数与画线状态完全无关** —— 画线模式下单指横滑照常平移、竖直甩动照常出 `periodSwipe`。
///   旧的 `drawingTakesOver` 截获参数已连同 `DrawingModePanPolicy` / `panPolicyInDrawingMode` 原子删除，
///   使「画线吞掉平移」这一状态**不可表达**（结构守卫 `DrawingGestureSourceGuardTests` 钉死）。
```

- [ ] **Step 4: 改 `ChartGestureArbiter.swift`**

`handleSinglePan` 内的调用改为（删最后一个实参）：

```swift
        let step = singlePanStep(phase: ph,
                                 cumulative: g.translation(in: g.view),
                                 velocityX: g.velocity(in: g.view).x,
                                 lifecycle: singlePanLifecycle,
                                 lastTranslationX: lastSinglePanTranslationX)
```

并把其上方注释
`// 生命周期决策全在纯函数 singlePanStep：垂直/ambiguous → emission==nil 不触碰 reducer；`
`// drawing 截获 → 始终 reset state 不发回调（R4 finding：防 mid-flight 切入残留）。`
替换为：

```swift
        // 生命周期决策全在纯函数 singlePanStep：垂直/ambiguous → emission==nil 不触碰 reducer。
        // 1a-iv D32：画线模式**不再**截获单指 pan —— 水平走平移、竖直甩动走切周期，与非画线态同一条路径。
```

同时订正类文档注释两处：
- `/// - 单指左右滑动 = 平移（累积判方向、增量出 offset；Drawing 模式被绘线截获不 fire onPan）` → `/// - 单指左右滑动 = 平移（累积判方向、增量出 offset；1a-iv 起 Drawing 模式同样透传）`
- `drawingMode` 属性注释 `/// Drawing 模式开关。true 时单指 Pan 被绘线截获、单指点击 fire onTap。` → `/// Drawing 模式开关。true 时单指点击 fire onTap（落锚）。**不影响**单指 Pan / 两指缩放（1a-iv D32）。`

- [ ] **Step 5: 删/改受影响的既有测试**

`GestureClassifiersTests.swift`：
1. 删除整个 `@Suite("panPolicyInDrawingMode") struct PanPolicyInDrawingModeTests { … }`（2 条测试）。
2. 删除 `drawingTakeoverCancelsActive` 与 `drawingTakeoverInactiveNoEmit` 两条测试。
3. 删除 `drawingModeNoSwitch`（「drawing 模式竖直 → 不切周期」）。
4. 在 `drawingModeNoSwitch` 原位置追加新 suite：

```swift
@Suite("1a-iv D32：画线模式与非画线模式走同一条单指 pan 路径")
struct DrawingModePanReleaseTests {
    // 旧行为（1a-iii 及以前）：`singlePanStep(drawingTakesOver: true)` 早退 → emissions == []、periodSwipe == nil。
    // 本期该参数已随 `DrawingModePanPolicy` / `panPolicyInDrawingMode` 原子删除：纯函数**再也无法**表达
    // 「画线时吞掉平移」。行为侧由本 suite 钉死「同一输入照常出位移/切周期」，
    // 结构侧由 `DrawingGestureSourceGuardTests` 钉死「截获通路的代码真的没了」。

    @Test("水平 pan：锁定 horizontalActive 并发 .began（不再是空 emissions）")
    func horizontalPanEmits() {
        let s = singlePanStep(phase: .began, cumulative: CGPoint(x: 30, y: 2), velocityX: 500,
                              lifecycle: .idle, lastTranslationX: 0)
        #expect(s.lifecycle == .horizontalActive)
        #expect(s.emissions == [SinglePanEmission(deltaX: 0, velocityX: 500, phase: .began)])
        #expect(s.lastTranslationX == 30)
    }

    @Test("水平 pan 续帧：照常发增量 .changed（截获分支不再存在，不会被清成 0）")
    func horizontalPanKeepsEmittingDeltas() {
        let s = singlePanStep(phase: .changed, cumulative: CGPoint(x: 80, y: 4), velocityX: 700,
                              lifecycle: .horizontalActive, lastTranslationX: 40)
        #expect(s.emissions == [SinglePanEmission(deltaX: 40, velocityX: 700, phase: .changed)])
        #expect(s.lifecycle == .horizontalActive)
    }

    @Test("竖直甩动：periodSwipe 非 nil —— 画线模式内也能切周期")
    func verticalFlickProducesSwipe() {
        let s = singlePanStep(phase: .ended, cumulative: CGPoint(x: 0, y: -80), velocityX: 0,
                              lifecycle: .verticalRejected, lastTranslationX: 0)
        #expect(s.periodSwipe == .up)
        #expect(s.emissions.isEmpty)      // 切周期是离散动作，不发 pan 位移
    }

    @Test("阈值以下的竖直甩动仍不切周期（放开截获 ≠ 放宽防误触阈值）")
    func shortVerticalFlickStillNoSwipe() {
        let s = singlePanStep(phase: .ended, cumulative: CGPoint(x: 0, y: -20), velocityX: 0,
                              lifecycle: .verticalRejected, lastTranslationX: 0)
        #expect(s.periodSwipe == nil)
    }
}
```

`TrainingEngineDrawingSessionTests.swift`：删除整条 `periodSwitchUnreachableWhileDrawing`（它自己的失败信息就写着「若本条变红 = 1a-iv 的 D32 放开了竖滑」，本期正是要推翻它；D31 的替代覆盖在 Task 3）。

- [ ] **Step 6: 运行测试确认通过**

```bash
cd "<worktree>/ios/Contracts" && swift test 2>&1 | tail -20
```
Expected: 全绿（`Test run with N tests … 0 failures`）。

- [ ] **Step 7: mutation-verify 守卫（证明守卫不是空气）**

临时把 `GestureClassifiers.swift` 里 `singlePanStep` 的参数加回 `, drawingTakesOver: Bool = false`（函数体不动），跑：

```bash
cd "<worktree>/ios/Contracts" && swift test --filter DrawingGestureSourceGuardTests 2>&1 | tail -10
```
Expected: **FAIL**（`noTakeoverPathInClassifiers` 变红）。

> **⚠️ mutation-verify 的撤销方式（codex plan-R3-high）：绝对不要用 `git checkout -- <file>`。**
> 本 task 的真实改动此刻**尚未 commit**，`git checkout --` 会用 HEAD/index 的版本覆盖整个文件、
> 把你刚写完的实现连同任何无关的本地改动一起抹掉。统一改用「先备份、再改坏、再还原、最后用 `git diff` 自证」：
>
> ```bash
> F=<被改坏的文件路径>
> BAK="$TMPDIR/mutverify-$(basename "$F").bak"
> cp "$F" "$BAK"                     # ① 备份「正确版本」
> #   ② 手动把 mutation 改进 $F，跑指定测试，确认 FAIL
> cp "$BAK" "$F" && rm "$BAK"        # ③ 从备份还原（不碰 git）
> git diff --stat -- "$F"            # ④ 自证：还原后该文件的 diff 与 mutation 之前一致
> #   ⑤ 重跑测试确认恢复绿
> ```

本步被改坏的文件 = `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift`（Step 3 的删除工作**尚未 commit**，用 `git checkout --` 会把它整个抹掉）。按 ③④⑤ 还原并确认恢复绿。

- [ ] **Step 8: fresh 非增量 Catalyst 对基线**（命令同 Task 1 Step 9，`-derivedDataPath /tmp/derived-1aiv` 前先 `rm -rf`）

Expected: `TEST SUCCEEDED` + `GATE PASS`。本 task 净删 5 条、净增 4 条 host 测试 → 记录真实 N 并与 1532±30 比对。

- [ ] **Step 9: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift \
        ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/GestureClassifiersTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/DrawingGestureSourceGuardTests.swift
git commit -m "1a-iv Task2：D32 画线模式放开单指 pan——截获通路原子删除

- 删 DrawingModePanPolicy / panPolicyInDrawingMode / singlePanStep(drawingTakesOver:) 及其早退分支
- ChartGestureArbiter.handleSinglePan 不再读 drawingMode（tap 落锚路径不变）
- 新增结构守卫 DrawingGestureSourceGuardTests（已 mutation-verify）
- 删 5 条断言旧截获行为的测试，加 4 条断言新行为的测试"
```

---

## Task 3: D31 —— 切周期钩子：真变化才丢 pending，且维持会话不变量

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift:380-414`（`switchPeriodCombo`）+ 新增私有方法
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`（删 2 条旧的、加 5 条新的）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/DrawingGestureSourceGuardTests.swift`（加 1 条源码守卫）

**Interfaces:**
- Consumes: Task 1 的 `.drawing` 接受 `.offsetApplied`（`resetOffsetAfterAutoTracking` 在重新武装前跑，此处仍是 autoTracking，但重新武装后的 `interruptDeceleration` 归一要能落地）；Task 2 让竖滑手势真的能到达 `switchPeriodCombo`
- Produces: `private func restoreDrawingSessionAfterPeriodChange()` —— 周期真变后的会话善后（只丢 pending + 重新武装两面板 + 失败 fail-closed 收口）

- [ ] **Step 1: 写失败测试（D31 两面 + 不变量 + D29 联合）**

`TrainingEngineDrawingSessionTests.swift`：**先删除**既有的 `periodSwitchIsNoOpWhileDrawing`（「画线时切周期是 no-op」——本期正是要推翻它）与 `periodSwitchWorksAfterLeavingDrawing`（它的对照价值随之消失）。保留它们上方那段解释「为什么必须用 `engineMultiPeriod()` 而不是 `preview()`」的注释块（仍然适用），并在其下追加：

```swift
    @Test("D31 真变化：画线时切周期 → **只丢 pending**（工具/会话/两面板 .drawing 全部存活）")
    func realPeriodChangeDiscardsOnlyPendingAnchors() {
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()                                    // 会话开：两面板 .drawing，工具 .horizontal
        e.drawingSession.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        #expect(e.drawingSession.pendingAnchors.count == 1)      // 前置：确实攒着 pending

        e.switchPeriodCombo(direction: .toSmaller)               // (.m60,.daily) → (.m15,.m60) 真的能切成功

        #expect(e.upperPanel.period == .m15)                     // 周期真的变了（防假绿：不是撞 no-op 守卫）
        #expect(e.lowerPanel.period == .m60)
        #expect(e.drawingSession.pendingAnchors.isEmpty)         // pending 被丢
        #expect(e.drawingSession.pendingAnchorPanel == nil)
        #expect(e.drawingSession.activeDrawingTool == .horizontal)   // ⭐工具存活（不是 cancel/deactivate 语义）
        #expect(e.drawingSession.drawingModeActive == true)          // ⭐会话存活
        #expect(e.drawings.isEmpty)                              // 丢 pending 不产生画线
        assertInvariant(e)                                       // ⭐两面板重新回到 .drawing
    }

    @Test("D31 no-op（目标周期无数据）：pending 锚**原样保留** —— 判据是「周期变没变」不是「做没做手势」")
    func noOpPeriodSwitchKeepsPendingAnchors() {
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()   // 只有 m3/m15/m60/daily，无 weekly
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.drawingSession.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)

        e.switchPeriodCombo(direction: .toLarger)   // 目标 (.daily,.weekly)：weekly 无数据 → no-op

        #expect(e.upperPanel.period == .m60)                     // 前置：确实没变
        #expect(e.lowerPanel.period == .daily)
        #expect(e.drawingSession.pendingAnchors.count == 1)      // ⭐锚没被误杀
        #expect(e.drawingSession.pendingAnchorPanel == .upper)
        #expect(e.drawingSession.activeDrawingTool == .horizontal)
        #expect(e.drawingSession.drawingModeActive == true)
        assertInvariant(e)
    }

    @Test("D31 no-op（周期阶梯边界）：已是最粗组合再往粗切 → 周期不变、pending 不丢")
    func boundaryPeriodSwitchKeepsPendingAnchors() {
        // 全 6 周期 fixture：(.weekly,.monthly) 是阶梯最后一档，再 toLarger 越界 → no-op。
        let e = TrainingEngineActionsTests.comboEngine(upper: .weekly, lower: .monthly)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.drawingSession.addAnchor(DrawingAnchor(period: .weekly, candleIndex: 0, price: 10), panel: .upper)

        e.switchPeriodCombo(direction: .toLarger)   // 越界 → no-op

        #expect(e.upperPanel.period == .weekly)
        #expect(e.lowerPanel.period == .monthly)
        #expect(e.drawingSession.pendingAnchors.count == 1)      // ⭐边界 no-op 不误杀
        #expect(e.drawingSession.activeDrawingTool == .horizontal)
        #expect(e.drawingSession.drawingModeActive == true)
        assertInvariant(e)
    }

    @Test("D31 no-op（阶梯表出现重复档位）：目标档与当前档相同 → 一切副作用都不许发生、不许裂脑")
    func duplicateComboEntryIsFullyNoOp() {
        // 造不出重复档位的真 fixture（periodCombos 是 private static let）→ 用**等价的可观测判据**：
        // 「目标档 == 当前档」在语义上就是「周期没变」，与边界 no-op 同类。这里锁的是**顺序契约**：
        // no-op 判据必须在 `.periodComboSwitched` 之前，否则面板已被打回 .autoTracking 而会话还开着。
        // 结构侧由下面的源码守卫钉死；行为侧由既有的两条 no-op 测试（边界 / 目标无数据）覆盖同一条早返路径。
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.switchPeriodCombo(direction: .toLarger)     // 目标 (.daily,.weekly)：weekly 无数据 → 早返
        assertInvariant(e)                            // ⭐早返路径不得留下裂脑（会话开着但面板 autoTracking）
        #expect(e.drawingSession.drawingModeActive == true)
    }

    @Test("D32 × D29 联合：画线模式内切周期后，原周期的线不再属于原面板（跟着它的 period 跑）")
    func drawingFollowsItsPeriodAcrossInDrawingPeriodSwitch() {
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        // 一条画在上面板（当时 .m60）的线。直接构造 DrawingObject：本条测的是 D29 归属判据，
        // 与提交路径无关（提交路径由 ChartContainerViewDrawingSessionTests 覆盖）。
        let line = DrawingObject(toolType: .horizontal,
                                 anchors: [DrawingAnchor(period: .m60, candleIndex: 1, price: 10)],
                                 isExtended: false, panelPosition: 0, revealTick: 0,
                                 lineSubType: .straight)
        #expect(RenderStateBuilder.belongsToPanel(line, panel: .upper,
                                                  upperPeriod: e.upperPanel.period,
                                                  lowerPeriod: e.lowerPanel.period))   // 前置：切之前在上面板

        e.switchPeriodCombo(direction: .toSmaller)     // (.m60,.daily) → (.m15,.m60)：.m60 挪到下面板

        #expect(!RenderStateBuilder.belongsToPanel(line, panel: .upper,
                                                   upperPeriod: e.upperPanel.period,
                                                   lowerPeriod: e.lowerPanel.period))  // ⭐不再渲染在上面板
        #expect(RenderStateBuilder.belongsToPanel(line, panel: .lower,
                                                  upperPeriod: e.upperPanel.period,
                                                  lowerPeriod: e.lowerPanel.period))   // ⭐跟着 .m60 跑到下面板
        assertInvariant(e)
    }
```

⚠️ 上面 `boundaryPeriodSwitchKeepsPendingAnchors` 里那行 `#expect(e.drawingSession.activeDrawingTool == .weekly == false)` 是**故意写坏的占位**，实施时必须替换为：

```swift
        #expect(e.drawingSession.activeDrawingTool == .horizontal)
        #expect(e.drawingSession.drawingModeActive == true)
```

（写在这里是为了让实施者必须逐行读过这段测试，而不是整段粘贴；发现后按上面两行替换即可。）

- [ ] **Step 2: 运行确认失败**

```bash
cd "<worktree>/ios/Contracts" && swift test --filter TrainingEngineDrawingSessionTests 2>&1 | tail -30
```
Expected: FAIL —— `realPeriodChangeDiscardsOnlyPendingAnchors` 里 `e.upperPanel.period == .m15` 实得 `.m60`（现有守卫 `guard !drawingSession.drawingModeActive else { return }` 让整个函数 no-op）。

- [ ] **Step 3: 改 `switchPeriodCombo`**

`TrainingEngine.swift`，把 `switchPeriodCombo` 整个函数（含其上的文档注释里 P1b-1a-ii 那段守卫说明）替换为：

```swift
    /// 单指竖滑 / 两指上下滑切换周期组合（plan v1.5 §4.4）。
    /// - 边界 / 当前组合不在序列(损坏 resume) / target 周期无数据 → no-op（不 advance、不 bump、**不碰 pending 锚**）。
    /// - 命中 → 改双面板 period + 对两面板派发 `.periodComboSwitched`（硬切 autoTracking）+ offset 归零。
    /// - **P1b-1a-iv D31**：命中且**周期组合真的变了**才做画线会话善后（见
    ///   `restoreDrawingSessionAfterPeriodChange`）。1a-ii 的「画线时切周期一律 no-op」守卫本期删除 —— 那是
    ///   为了在手势层还吞着竖滑时把「碰巧不可达」升级成「结构上不可能」的临时措施，D32 放开后它变成功能焊死。
    public func switchPeriodCombo(direction: PeriodDirection) {
        let combos = TrainingEngine.periodCombos
        guard let cur = combos.firstIndex(where: {
            $0.upper == upperPanel.period && $0.lower == lowerPanel.period
        }) else { return }   // 当前组合不在序列（损坏 resume 数据）→ no-op
        let target = direction == .toLarger ? cur + 1 : cur - 1
        guard combos.indices.contains(target) else { return }   // 边界 → no-op
        let next = combos[target]
        // D8 数据完整性守卫：避免后续 stepsForPeriod/渲染落在无数据周期
        guard let u = allCandles[next.upper], !u.isEmpty,
              let l = allCandles[next.lower], !l.isEmpty else { return }
        // D31：判据是「周期组合真的会变吗」，**不是**「用户做了切周期手势」。上面每一道守卫都可能 no-op，
        // no-op 时绝不能碰 pending 锚。
        // ⭐**必须在任何副作用之前判**（codex plan-R6-medium）：若把比较放在 `.periodComboSwitched` 之后，
        // 遇到「目标档与当前档相同」（阶梯表被改/损坏 resume 造成的重复项）时，两面板已被硬切回
        // `.autoTracking`，而 guard 又提前 return 跳过了重新武装 → `drawingModeActive` 还是 true、
        // 面板却已不在 `.drawing` = 正是本期要消灭的裂脑态。
        guard next.upper != upperPanel.period || next.lower != lowerPanel.period else { return }
        stopAllDeceleration()                       // D7
        upperPanel.period = next.upper
        lowerPanel.period = next.lower
        _ = upperPanel.reduce(.periodComboSwitched)
        _ = lowerPanel.reduce(.periodComboSwitched)
        resetOffsetAfterAutoTracking(.upper)        // D8
        resetOffsetAfterAutoTracking(.lower)
        restoreDrawingSessionAfterPeriodChange()    // 到这儿周期一定真变了
    }

    /// D31（P1b-1a-iv）：周期组合**真的变了**之后的画线会话善后。周期没变时**不会**被调用。
    /// ① **只丢 pending 锚**（`discardPendingAnchors()`）：锚绑在旧周期的 candleIndex 上，换了周期坐标系就错了。
    ///    保留 `activeDrawingTool` 与 `drawingModeActive` —— **绝不**调 `deactivate()`：那会连工具一起清掉，
    ///    连续画线断掉，且 1b-i 的 tap 会误入选择态（spec §5.1 #2 逐字）。
    /// ② `.periodComboSwitched` 把两面板硬切回 `.autoTracking`，直接破坏不变量「会话开 ⇔ 两面板 .drawing」
    ///    → 重新武装两个面板。武装依赖 `renderBounds`/reducer 态，理论上可能不生效 → **fail-closed 整场收口**
    ///    （同 `beginDrawingSession` 的事务性先例），绝不留「铅笔钮亮着、点图没反应」的裂脑态。
    private func restoreDrawingSessionAfterPeriodChange() {
        guard drawingSession.drawingModeActive, let tool = drawingSession.activeDrawingTool else { return }
        if !drawingSession.pendingAnchors.isEmpty { drawingSession.discardPendingAnchors() }
        armPanelForDrawing(tool, panel: .upper)
        armPanelForDrawing(tool, panel: .lower)
        if !(isDrawingActive(on: .upper) && isDrawingActive(on: .lower)) {
            endDrawingSessionIfActive()   // fail-closed：宁可退出画线，也不留半武装
        }
    }
```

- [ ] **Step 4: 运行确认通过**

```bash
cd "<worktree>/ios/Contracts" && swift test --filter TrainingEngineDrawingSessionTests 2>&1 | tail -20
```
Expected: PASS（4 条新测试全绿）。

- [ ] **Step 5: 加源码守卫（钉死「用的是 discardPendingAnchors 不是 cancel/deactivate」）**

在 `DrawingGestureSourceGuardTests.swift` 末尾（`}` 之前）追加：

```swift
    private let engine = "Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift"

    @Test("D31：周期切换的会话善后只用 discardPendingAnchors —— 不得出现 deactivate() / cancel()")
    func periodChangeUsesDiscardNotCancel() throws {
        let code = try source(engine)
        // 切片：从方法签名到其后第一个「行首 4 空格 + }」——该方法体内没有任何嵌套的 4 空格缩进 `}`，
        // 故这就是它的结束括号。切片锚点失配时必须 Issue.record（守卫失效要当场红，不许静默放过）。
        guard let start = code.range(of: "private func restoreDrawingSessionAfterPeriodChange()"),
              let end = code.range(of: "\n    }", range: start.upperBound..<code.endIndex) else {
            Issue.record("切片锚点找不到 —— restoreDrawingSessionAfterPeriodChange 被改名/改写？守卫失效，必须修")
            return
        }
        let body = String(code[start.lowerBound..<end.upperBound])
        #expect(body.contains("discardPendingAnchors()"))        // 防切片为空 → 负向断言假绿
        #expect(!body.contains("deactivate()"))
        #expect(!body.contains("cancelDrawingAllPanels()"))
        #expect(!body.contains(".cancel()"))
    }

    @Test("D31 顺序契约：no-op 判据必须在 .periodComboSwitched **之前**（否则重复档位会留下裂脑）")
    func periodNoOpGuardPrecedesSideEffects() throws {
        let code = try source(engine)
        guard let start = code.range(of: "public func switchPeriodCombo(direction: PeriodDirection)"),
              let end = code.range(of: "restoreDrawingSessionAfterPeriodChange()",
                                   range: start.upperBound..<code.endIndex) else {
            Issue.record("切片锚点找不到 —— switchPeriodCombo 被改名/改写？守卫失效，必须修")
            return
        }
        let body = String(code[start.lowerBound..<end.upperBound])
        guard let noOpGuard = body.range(of: "next.upper != upperPanel.period"),
              let switched = body.range(of: ".periodComboSwitched") else {
            Issue.record("switchPeriodCombo 里缺 no-op 判据或 .periodComboSwitched 派发")
            return
        }
        #expect(noOpGuard.lowerBound < switched.lowerBound)   // ⭐判据在副作用之前
    }
```

⚠️ 若实施时 `restoreDrawingSessionAfterPeriodChange` 的函数体里出现了嵌套闭包等导致行首 4 空格 `}` 提前出现的写法，切片会变短 → `#expect(body.contains("discardPendingAnchors()"))` 会当场变红提醒你换锚点，不会静默假绿。

- [ ] **Step 6: mutation-verify 该守卫**

临时把 `restoreDrawingSessionAfterPeriodChange` 里的 `drawingSession.discardPendingAnchors()` 改成 `drawingSession.deactivate()`，跑：

```bash
cd "<worktree>/ios/Contracts" && swift test --filter 'DrawingGestureSourceGuardTests|TrainingEngineDrawingSessionTests' 2>&1 | tail -15
```
Expected: **FAIL**（源码守卫 + `realPeriodChangeDiscardsOnlyPendingAnchors` 的 `activeDrawingTool == .horizontal` 双双变红）。

> **⚠️ mutation-verify 的撤销方式（codex plan-R3-high）：绝对不要用 `git checkout -- <file>`。**
> 本 task 的真实改动此刻**尚未 commit**，`git checkout --` 会用 HEAD/index 的版本覆盖整个文件、
> 把你刚写完的实现连同任何无关的本地改动一起抹掉。统一改用「先备份、再改坏、再还原、最后用 `git diff` 自证」：
>
> ```bash
> F=<被改坏的文件路径>
> BAK="$TMPDIR/mutverify-$(basename "$F").bak"
> cp "$F" "$BAK"                     # ① 备份「正确版本」
> #   ② 手动把 mutation 改进 $F，跑指定测试，确认 FAIL
> cp "$BAK" "$F" && rm "$BAK"        # ③ 从备份还原（不碰 git）
> git diff --stat -- "$F"            # ④ 自证：还原后该文件的 diff 与 mutation 之前一致
> #   ⑤ 重跑测试确认恢复绿
> ```

本步被改坏的文件 = `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（Step 3 的 `switchPeriodCombo` 重写**尚未 commit**）。按 ③④⑤ 还原并确认恢复绿。

- [ ] **Step 7: host 全量 + fresh 非增量 Catalyst 对基线**（命令同 Task 1 Step 8/9）

Expected: host 全绿；Catalyst `TEST SUCCEEDED` + `GATE PASS`；记录真实 N 与 1532±30 比对。

- [ ] **Step 8: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/DrawingGestureSourceGuardTests.swift
git commit -m "1a-iv Task3：D31 切周期钩子——真变化才丢 pending，会话与工具存活

- 删 1a-ii 的「画线时切周期 no-op」守卫（D32 放开后它变成功能焊死）
- 新增 restoreDrawingSessionAfterPeriodChange：只丢 pending + 重新武装两面板 + 失败 fail-closed 收口
- 判据是「变化后≠变化前」：边界/目标周期无数据两种 no-op 均不误杀 pending
- 加 D32×D29 联合不变量测试 + discardPendingAnchors 源码守卫（已 mutation-verify）"
```

---

## Task 4: commit 前「全锚同 period」断言（**两条写入口都要锁**）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift:135-155`（`commitPending`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift:62-78`（`commit`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolManagerTests.swift`

**⚠️ 有两条 `DrawingObject` 写入口，不是一条（codex plan-R1-high）**：除了 `DrawingSession.commitPending`，`public final class DrawingToolManager` 的 `public func commit(lineSubType:panelPosition:)` **同样**直接用未经检查的 `pendingAnchors` 构造 `DrawingObject`。已实测：`DrawingToolManager` 在 `Sources/` 里**没有任何生产调用点**（只剩 3 处陈旧注释提到它，1a-ii D44 已把 pending 锚搬进 `DrawingSession`），但它仍是 `public` 的、任何人调一次就能造出同样的坏数据。
本期**不删它**（按 CLAUDE.md §3「不相关的死代码提出来、别删」，且删 public 类超出本期范围）——**只给它上同一把锁**，让「混 period 锚集合被写成 `DrawingObject`」这件事在**整个包里**都不可发生。清理 `DrawingToolManager` 本身留给后续（见文末残留清单）。

**Interfaces:**
- Consumes: Task 3 的 D31 语义（周期真变即丢 pending → 正常路径下混 period 的锚集合已不可达；本 task 是**第二道**结构防线）
- Produces: `commitPending(panelPosition:)` 在锚集合 period 不一致时返回 `nil` 且只丢 pending

**为什么本期做**：spec §5.1 #2 逐字要求「commit 前断言全锚同 period，不同则拒绝提交并 `discardPendingAnchors()`（同样不得清 `activeDrawingTool`）」，且明写「本期水平线单锚、落锚即提交，实际触发不到；**钩子与断言仍须落地并可测**，供 P1c 复用」。`DrawingObject.init` 只取 `anchors.first.period`（D29），混 period 的锚集合存下去就是坐标系错乱的坏数据。

- [ ] **Step 1: 写失败测试**

在 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift` 末尾（Suite 的 `}` 之前）追加：

```swift
    // MARK: 1a-iv D31：commit 前全锚同 period（本期单锚工具触发不到；供 P1c 多锚工具复用）

    @Test("D31：混 period 的锚集合**拒绝提交** —— 返回 nil、只丢 pending、工具与会话存活")
    func commitRejectsMixedPeriodAnchors() {
        let s = DrawingSession()
        s.activate(tool: .trend)                                  // 多锚工具（本期未开放公共入口，容器层可持有）
        s.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        s.addAnchor(DrawingAnchor(period: .daily, candleIndex: 2, price: 11), panel: .upper)   // ← 混了 period
        #expect(s.pendingAnchors.count == 2)                      // 前置：确实攒了两个

        let drawing = s.commitPending(panelPosition: 0)

        #expect(drawing == nil)                                   // ⭐拒交，不产出坏数据
        #expect(s.pendingAnchors.isEmpty)                         // ⭐只丢 pending
        #expect(s.pendingAnchorPanel == nil)
        #expect(s.activeDrawingTool == .trend)                    // ⭐工具存活（不是整场取消）
        #expect(s.drawingModeActive == true)                      // ⭐会话存活
    }

    @Test("对照（防假绿）：同 period 的多锚集合正常提交 —— 断言不是把多锚工具焊死")
    func commitAcceptsSamePeriodMultiAnchors() {
        let s = DrawingSession()
        s.activate(tool: .trend)
        s.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        s.addAnchor(DrawingAnchor(period: .m60, candleIndex: 5, price: 12), panel: .upper)

        let drawing = s.commitPending(panelPosition: 0)

        #expect(drawing != nil)
        #expect(drawing?.anchors.count == 2)
        #expect(drawing?.period == .m60)                          // D29：period 由 anchors.first 派生
        #expect(s.pendingAnchors.isEmpty)                         // 提交后清 pending
        #expect(s.activeDrawingTool == .trend)                    // D38：提交后工具保持（连续画线）
    }
```

- [ ] **Step 2: 运行确认失败**

```bash
cd "<worktree>/ios/Contracts" && swift test --filter DrawingSessionTests 2>&1 | tail -20
```
Expected: FAIL —— `commitRejectsMixedPeriodAnchors` 的 `drawing == nil` 实得非 nil（当前会照常提交一条 period=.m60 的坏数据）。

- [ ] **Step 3: 加断言**

`DrawingSession.swift` 的 `commitPending`，在既有 guard 之后插入：

```swift
    func commitPending(panelPosition: Int) -> DrawingObject? {
        guard let tool = activeDrawingTool, !pendingAnchors.isEmpty else { return nil }
        // D31（1a-iv）：全锚必须同 period。`DrawingObject.init` 只取 `anchors.first.period`（D29 周期绑定），
        // 混 period 的锚集合存下去 = 后续所有锚的 candleIndex 被按错误周期解释的坏数据。
        // 拒交 + **只丢 pending**（保 activeDrawingTool / drawingModeActive，绝不整场取消）。
        // 本期水平线单锚、落锚即提交，实际触发不到；钩子供 P1c 的多锚工具复用（spec §5.1 #2）。
        guard let anchorPeriod = pendingAnchors.first?.period,
              pendingAnchors.allSatisfy({ $0.period == anchorPeriod }) else {
            discardPendingAnchors()
            return nil
        }
        let s = defaultStyle
        // …（以下原样不动）
```

- [ ] **Step 4: 运行确认通过**

```bash
cd "<worktree>/ios/Contracts" && swift test --filter DrawingSessionTests 2>&1 | tail -20
```
Expected: PASS。

- [ ] **Step 5: 给第二条写入口 `DrawingToolManager.commit` 上同一把锁（先写失败测试）**

在 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolManagerTests.swift` 末尾（Suite 的 `}` 之前）追加：

```swift
    // MARK: 1a-iv：第二条 DrawingObject 写入口同样必须拒绝混 period 的锚集合（codex plan-R1-high）

    @Test("混 period 的锚集合**不得**被写成 DrawingObject —— completedDrawings 不增长，只丢 pending")
    func commitRejectsMixedPeriodAnchors() {
        let m = DrawingToolManager(enabledTools: [.trend])
        m.toggle(.trend)
        m.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10))
        m.addAnchor(DrawingAnchor(period: .daily, candleIndex: 2, price: 11))   // ← 混了 period
        #expect(m.pendingAnchors.count == 2)                  // 前置：确实攒了两个

        m.commit()

        #expect(m.completedDrawings.isEmpty)                  // ⭐坏数据没被写出来
        #expect(m.pendingAnchors.isEmpty)                     // 只丢 pending
    }

    @Test("对照（防假绿）：同 period 的多锚集合正常提交 —— 守卫不是把 commit 焊死")
    func commitAcceptsSamePeriodAnchors() {
        let m = DrawingToolManager(enabledTools: [.trend])
        m.toggle(.trend)
        m.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10))
        m.addAnchor(DrawingAnchor(period: .m60, candleIndex: 5, price: 12))

        m.commit()

        #expect(m.completedDrawings.count == 1)
        #expect(m.completedDrawings.first?.period == .m60)
        #expect(m.pendingAnchors.isEmpty)
    }
```

跑 `swift test --filter DrawingToolManagerTests`，Expected: FAIL —— `commitRejectsMixedPeriodAnchors` 的 `completedDrawings.isEmpty` 实得 1 条坏数据。

- [ ] **Step 6: 给 `DrawingToolManager.commit` 加守卫**

`ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift`，在 `commit` 的两条 `precondition` 之后插入：

```swift
        // 1a-iv（codex plan-R1-high）：与 `DrawingSession.commitPending` 同一把锁 —— 全锚必须同 period。
        // `DrawingObject.init` 只取 `anchors.first.period`（D29 周期绑定），混 period 的锚集合写出去 =
        // 后续锚的 candleIndex 被按错误周期解释的坏数据。本类在 `Sources/` 已无生产调用点（1a-ii D44 把
        // pending 锚搬进 `DrawingSession`），但它仍是 `public` 的 —— 不能留着一条谁都能调的坏数据写入口。
        // 拒交语义与 `commitPending` 一致：**只丢 pending**，不动 `activeTool`。
        guard let anchorPeriod = pendingAnchors.first?.period,
              pendingAnchors.allSatisfy({ $0.period == anchorPeriod }) else {
            pendingAnchors = []
            return
        }
```

跑 `swift test --filter DrawingToolManagerTests`，Expected: PASS（两条都绿）。

- [ ] **Step 6b: 把闸下沉到**真正的写入点** `appendDrawing` / `appendReviewDrawing`（codex plan-R4/R5-high）**

**实测的写入拓扑（决定闸该放哪儿）**：
- `drawings` / `reviewDrawings` 的**新增**写入只有两处：`appendDrawing(_:)`（`TrainingEngine.swift:1043`）与 `appendReviewDrawing(_:)`（`:1049`）。两者都是 `public`。
- `routeDrawingCommit` 只是它俩上面的路由（按 `flow.mode` 二选一），**不是**唯一入口 —— 只在它上面加闸，任何直接调 `appendDrawing` 的 in-module / 包内代码都能绕过（codex plan-R5-high）。
- **历史数据装载不经 append**：resume 走 `self.drawings = seededLossy.drawings`（init，`:173`）、复盘走 `reviewDrawings = l.drawings`（`:312`），都是整体赋值。**所以把闸放在 append 上不会吞掉用户已经画好的线** —— 这正是「已知残留 3」拒绝在 `init` / `decode` 层加闸的那条数据丢失顾虑在这里**不成立**的原因。

先写失败测试，追加到 `TrainingEngineDrawingCommitTests.swift`（若该文件的 Suite 结构不便，放 `TrainingEngineDrawingSessionTests.swift` 亦可）。**四个入口都要测**：

```swift
    // 1a-iv（codex plan-R4/R5-high）：锚跨周期 / 显式 period 与锚不符 = 坐标系错乱的坏数据
    // （`belongsToPanel` 按 `drawing.period` 归属面板，锚却按各自 period 的 candleIndex 解释）。
    // 新增写入的**两个**真实入口都必须拒收，路由层 routeDrawingCommit 自然继承。

    private func mixedPeriodDrawing() -> DrawingObject {
        DrawingObject(toolType: .trend,
                      anchors: [DrawingAnchor(period: .m60, candleIndex: 1, price: 10),
                                DrawingAnchor(period: .daily, candleIndex: 2, price: 11)],
                      isExtended: false, panelPosition: 0, revealTick: 0,
                      lineSubType: .straight)
    }

    private func periodMismatchDrawing() -> DrawingObject {
        DrawingObject(toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m60, candleIndex: 1, price: 10)],
                      isExtended: false, panelPosition: 0, revealTick: 0,
                      period: .daily,                       // ← 与锚不符
                      lineSubType: .straight)
    }

    private func consistentDrawing() -> DrawingObject {
        DrawingObject(toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m60, candleIndex: 1, price: 10)],
                      isExtended: false, panelPosition: 0, revealTick: 0,
                      lineSubType: .straight)
    }

    @Test("入口①：appendDrawing 直接调用也拒收坏数据（不能只挡路由层）")
    func appendDrawingRejectsInconsistentPeriod() {
        let e = TrainingEngine.preview()
        e.appendDrawing(mixedPeriodDrawing())
        e.appendDrawing(periodMismatchDrawing())
        #expect(e.drawings.isEmpty)
    }

    @Test("入口②：appendReviewDrawing 直接调用同样拒收")
    func appendReviewDrawingRejectsInconsistentPeriod() {
        let e = TrainingEngine.preview()
        e.appendReviewDrawing(mixedPeriodDrawing())
        e.appendReviewDrawing(periodMismatchDrawing())
        #expect(e.reviewDrawings.isEmpty)
    }

    @Test("路由层继承：routeDrawingCommit 传坏数据 → 两个数组都不增长")
    func routeDrawingCommitInheritsTheGuard() {
        let e = TrainingEngine.preview()
        e.routeDrawingCommit(mixedPeriodDrawing())
        #expect(e.drawings.isEmpty)
        #expect(e.reviewDrawings.isEmpty)
    }

    @Test("对照（防假绿）：一致的 DrawingObject 照常入库 —— 守卫不是把提交路径焊死")
    func consistentDrawingStillAppends() {
        let e = TrainingEngine.preview()
        e.appendDrawing(consistentDrawing())
        #expect(e.drawings.count == 1)
        e.routeDrawingCommit(consistentDrawing())
        #expect(e.drawings.count == 2)                      // 路由层也照常放行
    }
```

⚠️ 实施时先核对 `DrawingObject.init` 的**实参标签顺序**（`Models.swift` 的 `public init`，`period` 是带默认值的可选参数）；标签写错是编译失败，不会假绿。

然后在 `TrainingEngine.swift` 里加共用判据，并把两个 append 都改成先过闸：

```swift
    /// 1a-iv（codex plan-R4/R5-high）：新画线入库的**单一校验点**。锚必须全部同 period，且 `period` 字段
    /// 与锚一致 —— 否则就是坐标系错乱的坏数据（`belongsToPanel` 按 `drawing.period` 归属面板，
    /// 锚却按各自 period 的 candleIndex 解释）。
    /// **空锚故意放行（codex plan-R8-medium）**：空锚对象既画不出也命不中（渲染侧 `visibleGeometry`
    /// 已 fail-closed），它**不属于**本期要防的那类坏数据；而 append 是 public 面，把「空锚」也拒掉等于给
    /// 「已解码 / 已编辑的既有对象经 append 回写时被静默丢弃」开了口子 —— 数据丢失比一条画不出的空线严重得多。
    /// 本判据因此只回答一个问题：**锚之间、以及锚与 `period` 字段，是否自洽**。
    /// **只管新增写入**：resume（init 的 `self.drawings = …`）与复盘装载（`reviewDrawings = l.drawings`）
    /// 是整体赋值、不经这里 —— 在历史数据装载路径上 fail-closed 会静默吞掉用户已画好的线（见「已知残留 3」）。
    private func isPeriodConsistent(_ d: DrawingObject) -> Bool {
        guard let p = d.anchors.first?.period else { return true }   // 空锚：行为与 1a-iv 之前逐字一致
        return d.anchors.allSatisfy { $0.period == p } && d.period == p
    }
```

⚠️ 实施时**顺带核实**这条放行是真的没改变既有行为：`swift test` 全绿即证（若有测试 append 空锚 drawing，它必须仍然通过）。

```swift
    public func appendDrawing(_ drawing: DrawingObject) {
        guard isPeriodConsistent(drawing) else { return }        // 1a-iv fail-closed：坏数据不入库
        drawings.append(drawing)
    }
```

```swift
    public func appendReviewDrawing(_ drawing: DrawingObject) {
        guard isPeriodConsistent(drawing) else { return }        // 1a-iv fail-closed：坏数据不入库
        reviewDrawings.append(drawing)
    }
```

`routeDrawingCommit` **不再单独加闸**（DRY：它只是路由，两条出口都已被守住）。

跑这四条测试，Expected: 全绿。⚠️ 若既有测试里有「append 一个零锚 / 锚 period 与 `period` 字段不符的 DrawingObject」的用例因此变红：先打印真实值，确认那条用例造的是不是本来就不该入库的数据；是则改造 fixture 并在 commit message 说明，不是则停下来报告。

- [ ] **Step 7: host 全量 + fresh 非增量 Catalyst 对基线**（命令同 Task 1 Step 8/9）

Expected: host 全绿；Catalyst `TEST SUCCEEDED` + `GATE PASS`。这是**最后一个 task**，此处的真实 N 就是本分支的最终计数——若与 `.github/scripts/catalyst-total-baseline.txt`（1532）之差超出 ±30，在本 commit 内更新基线文件。

- [ ] **Step 8: iOS 真机构建（编译门；装包由 user 真终端跑）**

```bash
cd "<worktree>/ios/KlineTrainer" && xcodebuild -scheme KlineTrainer -destination 'generic/platform=iOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`。**codesign 会失败属于已知环境限制**（Claude 的 Bash 会话无钥匙串授权）——若卡在 `CodeSign` 步骤，如实报告并请 user 在真终端跑一次，不要伪装成通过。

- [ ] **Step 9: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift \
        ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolManagerTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift
git commit -m "1a-iv Task4：三道闸拦住锚跨周期的坏画线（提交路径 fail-closed）

- DrawingSession.commitPending：spec §5.1 #2 要求的钩子，供 P1c 多锚工具复用
- DrawingToolManager.commit：同一把锁（该类已无生产调用点但仍 public，不能留敞口）
- appendDrawing / appendReviewDrawing：新增写入的两个真实入口（routeDrawingCommit 路由层继承），兼查『显式 period 与锚不符』
- 明确不做 init/decode 层校验（resume 路径 fail-closed = 吞用户已有的线；属 P1a 契约层）"
```

---

## 已知残留（本期**不做**，明写以免被当成遗漏）

1. **`DrawingToolManager` 整体是死代码**：`Sources/` 里零生产调用点（1a-ii D44 把 pending 锚搬进 `DrawingSession` 后它就退休了），只剩 `Reducer.swift` 里 3 处陈旧注释提到它。本期只给它的 `commit` 上了坏数据锁，**没有删类、没有改注释**（CLAUDE.md §3：不相关的死代码提出来、别删）。建议在 1b-i 或一个独立的清理 PR 里连同那 3 处注释一起处理。
2. **`FrozenPanelState` 的 `period` / `visibleCount` / `offset` / `candleRange` 四个字段无消费者**：视口解冻后它们的语义退化为「进画线那一刻的历史快照」。全仓只读 `baseRevision`。本期保留（P1c 节点拖动可能要用），不删。
3. **`DrawingObject.init` / decode 层**仍可构造出锚跨周期的对象（codex plan-R4-high 的后半，**本期明确不做**）。三条理由：
   - **数据丢失风险大于收益**：`init` 与 `Decodable` 是 **resume / 历史记录读取**路径。在那里 fail-closed = 用户**已经画好的线**在升级后被静默吞掉，且不可逆。而本期封堵的是「**新**产生坏数据」，两者的失败代价不对称。
   - **decode 策略属 P1a 契约层**：给历史无效记录定行为（丢弃 / 修正 / lossy 保真）要改 `CONTRACT_VERSION` 与前向兼容约定，spec §5.2 明确把契约层划在 1a-iv 之外（本期 Global Constraints 也写死不动契约）。
   - **本期实际不可达**：唯一开放的工具 `.horizontal` 是**单锚**、落锚即提交，`pendingAnchors` 结构上不可能超过 1 个锚，跨周期锚集合造不出来。真正会用到多锚的是 P1c。
   **交接要求**：P1c 开放第一个多锚工具时**必须重估这条**，把「锚集合同 period」提升为模型级不变量（连同 decode 策略一起定），不能只靠三道 commit/漏斗闸。
4. **复盘的手势改善（验收 #11 #13）无自动化覆盖**：D32 是全局引擎行为、复盘走同一条路径，无独立分支可测；靠真机验收把关。

---

## 收尾（不属于任何 task，由主会话执行）

1. **whole-branch Opus 评审**（本会话内，非 subagent 自审）。
2. **whole-branch codex 对抗性评审**：走 `codex-attest.sh`，`--focus` **只传文件路径不传散文**（传散文会窄化评审得假 approve、且 `git hash-object` 报错致 `set -e` 静默退出、账本一条不写）；收口只认 `branch-diff` 模式的无窄化 approve；attest 后 **Read 账本文件**核实 `head_sha` 与 HEAD 逐字一致，且 attest 后不再 rebase。
3. **PR**（中文标题/正文）由 user 真终端创建（`gh` 走 GraphQL 会 401）。
4. **真机验收**：按下面的清单，由 user 在 iPhone 上逐条确认。

---

## P1b-1a-iv 非程序员验收清单

> 前置：Debug 构建装机后，用 `KLINE_SEED_FIXTURE=1` 启动（否则会报「训练组文件不存在」——那是 NAS 后端未部署的环境缺口，不是本期回归）。

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 进画线模式，单指横向拖动图表 | 图表跟着手指左右平移（**这是相对 1a-iii 的改善**：以前完全拖不动） | |
| 2 | 接上一步，手指快速横甩后松手 | 图表带惯性继续滑一段再停，**不会**停在越界的空白间隙上 | |
| 3 | 画线模式内单指竖直甩一下 | 周期正常切换（上下两个面板的周期各挪一档） | |
| 4 | 画线模式内双指捏合 / 张开 | 图表缩放正常；缩放后**不会**突然跳回最新那一根 | |
| 5 | 画线模式内单击图表 | 仍然照常画出一条水平线（手势没打架） | |
| 5b | 画线模式内**快速甩动图表、趁它还在滑的时候**点一下 | 图表当场停住，线**落在手指点的那根 K 线上**（不是落在偏出去好几根的地方，也不会画完还继续滑） | |
| 6 | **在画线模式里**（不退出）于上半面板（60 分）画一条线，再竖滑切周期让 60 分挪到下半面板 | 那条线**跟着 60 分跑到下半面板**，位置不变 | |
| 7 | 继续切周期，让 60 分完全不显示 | 那条线暂时消失；切回来又出现，位置不变 | |
| 8 | 在**已经是最粗周期**时再往粗甩一次 | 周期不变、图表不乱（边界无动作） | |
| 9 | 画线模式内平移 / 切周期 / 缩放之后，再单击图表 | 仍然能画线，铅笔钮仍是亮的（不会出现「钮亮着但点了没反应」） | |
| 10 | 画线模式内做完上述所有操作后，点买入 / 卖出 | 仍然**不能**下单（画线模式禁止交易，与 1a-iii 一致） | |
| 11 | 在复盘里用浮动铅笔钮进画线模式，单指横滑 / 竖甩 / 捏合 | 平移、切周期、缩放同样可用 | |
| 12 | 进复盘看画线入口 | 还是浮动铅笔钮，**没有**两行底栏（复盘形态一字未改） | |
| 13 | 再次训练（replay）模式里重复第 1 / 3 / 4 条 | 手势行为与训练模式一致 | |

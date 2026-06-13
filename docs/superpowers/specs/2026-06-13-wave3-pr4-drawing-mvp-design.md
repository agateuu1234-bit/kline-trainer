# Wave 3 顺位 4 — 水平线绘线 MVP + 画线 source-of-truth 全链路（设计）

**日期**：2026-06-13
**Anchor**：Wave 3 顺位 4（轨 G 图表/手势，编号=标识符非执行顺序）
**分支**：`worktree-wave3-pr4-drawing-mvp`
**上游依赖（全部 merged）**：1 RFC(#94) / 2 CI+竖屏(#93) / 3 Pinch(#98) / 6a(#95) / 6b(#97 `appendDrawing`) / 10a(#99)
**outline 来源**：`docs/superpowers/specs/2026-06-09-wave3-outline-design.md` §二·顺位 4 行 + §三.2 画线全链路 + §四 residual（U2-R2 / C6 deferred）
**契约来源**：`docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` §4.4c（`appendDrawing` 投影单一真相）
**C6 基础设施**：`docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md`（protocol + manager + reducer FSM 框架，显式 defer 实施到 Wave 3）

---

## 〇、起点核实（grep-first，2026-06-13）

C6（PR #69）+ C1b reducer FSM（PR #48）+ C8b（PR #87）+ 6b（PR #97）已把画线链的**大部分**落地。顺位 4 的真实工作面比 outline §三.2 字面（"input→投影→reducer→持久化/还原+E2E 全链路"）**窄**——多数环节已 ship，顺位 4 只补**缺失的端点**。逐项核实：

| 链路环节 | 现状 | 证据 | 顺位 4 工作 |
|---|---|---|---|
| `DrawingInputController` protocol | protocol-only（`tapToAnchor`/`shouldCommit` 二方法） | `Drawing/DrawingInputController.swift:12-15` | **实现 `DefaultDrawingInputController`** |
| `DrawingTool` protocol | protocol-only | `Drawing/DrawingTool.swift:14-20` | **实现 `HorizontalLineTool`** |
| `DrawingToolManager` 输入暂存 FSM | 真实现（toggle/addAnchor/commit/cancel/deleteDrawing） | `Drawing/DrawingToolManager.swift` | **消费**（Coordinator 持有 + 接线） |
| reducer 画线 FSM（activateDrawing/setDrawingSnapshot/drawingCommitted/drawingCancelled + cross-session guard） | 真实现（27 格矩阵测试） | `Reducer/Reducer.swift:95-217` | **触发**（经 engine 方法 dispatch） |
| `engine.activateDrawingTool(_:panel:)`（进 .drawing：停 animator + 算 candleRange + setDrawingSnapshot） | 真实现 | `TrainingEngine.swift:706-717` | **消费**（toggle 按钮进入） |
| `engine.appendDrawing(_:)`（投影 manager→engine.drawings） | 真实现（6b） | `TrainingEngine.swift:729-731`（RFC §4.4c） | **消费**（commit 后投影） |
| `engine.deleteDrawing(at:)` | 真实现 | `TrainingEngine.swift:720-723` | 不消费（hit-test 删除属 Phase 4） |
| 持久化：`engine.drawings → pending` | 真实现 | `Coordinator.saveProgress:205,210`（`PendingTraining(...,drawings: engine.drawings,...)`） | **0 新代码**，仅 E2E 测试 |
| 持久化：`engine.drawings → finalize record bundle` | 真实现 | `Coordinator.finalize:250` | 0 新代码 |
| 恢复：resume → `initialDrawings: pending.drawings` | 真实现 | `Coordinator:109` | **0 新代码**，仅 E2E 测试 |
| 恢复：review → `initialDrawings: drawings`（record bundle） | 真实现 | `Coordinator:146` | 0 新代码 |
| 渲染：`engine.drawings → renderState.drawings → drawDrawings` | 真实现 dispatch loop，但 `tools:[:]` 硬编码空字典 → **不 paint** | `KLineView.swift:55-56`（`tools: [:]`），`KLineView+Drawing.swift:21-26` | **注册 `[.horizontal: HorizontalLineTool()]`** |
| 手势：`arbiter.drawingMode` + `onTap`（仅 drawing 模式 fire）+ 单指 pan 抑制 | 真实现 | `ChartGestureArbiter.swift:34-35,185-188,138-151` | **接 `onTap`**（Coordinator:94 显式留口"顺位 4 接"） |
| 坐标逆映射 `point→{candleIndex,price}` | 真实现 | `Geometry.swift CoordinateMapper.xToIndex:153 / yToPrice:165` | **消费** |
| **FSM 退出**（reducer `.drawing` 唯一出口 = `.drawingCommitted`/`.drawingCancelled`） | reducer 支持，但 **engine 无 public 方法 dispatch**（`reduce` 是 `private:563`；`activateDrawingTool` 只进不出） | grep `TrainingEngine` 仅 activate/append/delete | **新增 `engine.commitDrawing/cancelDrawing`**（见 D-ENGINE） |
| toggle 按钮 UI（进入/退出绘线模式） | 缺（U2 D7 显式 defer 到本锚） | `TrainingView.swift:12`（"延后 D7 画线面板...U2-R2"） | **新增 toggle 按钮** |

**结论**：顺位 4 = **接通已铺好的链路的两个开放端点（输入端 + 渲染端）+ 补 FSM 退出方法 + toggle 按钮**，而非"从零建全链路"。持久化/恢复/reducer FSM/投影 API **均已 ship**，顺位 4 对它们是 0 新代码（仅 E2E 验证）。

---

## 一、范围边界

### In scope
1. **`HorizontalLineTool`**：唯一具体 `DrawingTool`（`.horizontal`，`requiredAnchors = 1...1`，render 画横线，hitTest）。
2. **`DefaultDrawingInputController`**：具体 `DrawingInputController`（`tapToAnchor` 逆映射；`shouldCommit` 按 tool 最小锚数判定）。
3. **`engine.commitDrawing(panel:)` + `engine.cancelDrawing(panel:)`**：FSM 退出（D-ENGINE）。
4. **渲染接通**：`KLineView` 注册 horizontal tool + 按 `panelPosition` 过滤（D-PANELFILTER）。
5. **手势接线**：`ChartContainerView.Coordinator` 持 manager + inputController + tool，接 `arbiter.onTap`（输入→anchor→manager.commit→engine.appendDrawing→engine.commitDrawing）。
6. **toggle 按钮**：`TrainingView` 增"水平线"开关（进入/退出绘线模式；U2-R2 / D7）。
7. **E2E 持久化测试**：draw → saveProgress → resume → drawings 还原（消费已 ship 路径）。
8. **运行时 runbook 条目**：水平线绘制 + 跨缩放/平移还原（outline §三.3 要求）。

### Out of scope（明列排除，preempt 评审）
- **6 种其余画线工具**（ray/trend/golden/wave/cycle/time）→ Phase 4，独立后续 track（outline §六）。
- **hit-test 选中删除交互** → Phase 4（C6 deferred L39）。`HorizontalLineTool.hitTest` 实现但**不接删除 UI**（protocol 要求故实现，无 caller）。
- **下栏（volume/MACD）画线** → MVP 仅上栏（price 面板）；横价线在指标面板无语义。
- **周期 autosave**（每 N tick / background flush，RFC §4.6）→ 顺位 10b。顺位 4 的持久化触发沿用现状（saveProgress 仅 Back 触发）；新增的画线 commit **不**额外触发 autosave（那是 §4.6 / 顺位 10 scope）。
- **非水平工具的跨周期 candleIndex 重映射** → Phase 4（水平线 price 周期无关，天然规避，见 D-CROSSPERIOD）。
- **CONTRACT_VERSION bump / schema 迁移** → 无：`drawings` 列自 P4（PR #42）已在，`DrawingObject` 已 Codable，无序列化变更。

---

## 二、架构与数据流

### 端到端流程（进入 → 落锚 → 投影 → 退出）

```
[进入] TrainingView "水平线" 按钮（仅 .upper 面板）
  └─ engine.activateDrawingTool(.horizontal, panel: .upper)
       ├─ reducer .autoTracking →(.activateDrawing)→ 返 effect requestDrawingSnapshotAfterStoppingAnimator
       ├─ animator.stop()（冻结 offset，停 tick 漂移）
       ├─ 算 candleRange（基于已冻结 panelState）
       └─ reduce(.setDrawingSnapshot) → interactionMode = .drawing(snapshot)
  ⇒ 下一次 updateUIView：Coordinator.sync 见 isDrawing==true
       ├─ arbiter.drawingMode = true（单指 pan 被抑制，tap 启用）
       └─ manager.activeTool==nil → manager.toggle(.horizontal)（对齐）

[落锚] 用户单指点击图表 → arbiter.onTap(point)（仅 drawing 模式 fire）
  └─ Coordinator.handleTap(point):
       ├─ guard isDrawing && manager.activeTool != nil（防御）
       ├─ mapper = CoordinateMapper(viewport: view.renderState.viewport, displayScale: view.traitCollection.displayScale)
       ├─ anchor = inputController.tapToAnchor(at: point, panel: ps, mapper: mapper)
       │             = DrawingAnchor(period: ps.period, candleIndex: mapper.xToIndex(point.x), price: mapper.yToPrice(point.y))
       ├─ manager.addAnchor(anchor)
       ├─ guard inputController.shouldCommit(current: manager.pendingAnchors, tool: .horizontal)  // count>=1 → true
       ├─ manager.commit(isExtended: true, panelPosition: 0)        // → DrawingObject 入 completedDrawings
       ├─ engine.appendDrawing(manager.completedDrawings.last!)     // 投影：单一真相 engine.drawings += [drawing]
       └─ engine.commitDrawing(panel: .upper)                       // reducer .drawing →(.drawingCommitted)→ .autoTracking
  ⇒ 下一次 updateUIView：isDrawing==false → arbiter.drawingMode=false；engine.drawings 含新线 → drawDrawings 经
       HorizontalLineTool.render paint；RenderStateBuilder 按 panelPosition 过滤（横线只上栏）

[退出/取消] 再点 "水平线" 按钮（drawing 模式中）→ engine.cancelDrawing(.upper)
  └─ reducer .drawing →(.drawingCancelled)→ .autoTracking；manager.cancel()（sync 对齐）；无 append
```

### 组件清单（文件级）

**新增 prod（2 文件 · ~80 行）**
| 文件 | 内容 |
|---|---|
| `Drawing/DefaultDrawingInputController.swift` | `final class DefaultDrawingInputController: DrawingInputController`（`tapToAnchor` 逆映射 + `shouldCommit` 按 tool 最小锚数；纯函数，host 全测） |
| `Drawing/HorizontalLineTool.swift` | `struct HorizontalLineTool: DrawingTool`（`type=.horizontal`，`requiredAnchors=1...1`，render/hitTest；几何抽纯 helper `lineGeometry`/`hitTestDistance` host 测，render 仅 stroke） |

**修改 prod（5 文件）**
| 文件 | 改动 |
|---|---|
| `TrainingEngine/TrainingEngine.swift`（drawing extension） | 新增 `commitDrawing(panel:)` + `cancelDrawing(panel:)`（D-ENGINE，~15 行） |
| `Render/RenderStateBuilder.swift` | `make` 内 `drawings:` 改为按 `panelPosition` 过滤 engine.drawings（D-PANELFILTER，~2 行） |
| `Render/KLineView.swift` | `drawDrawings(..., tools:)` 由 `[:]` 改为注册 `[.horizontal: HorizontalLineTool()]`（D-TOOLREG，~3 行） |
| `Render/ChartContainerView.swift` | Coordinator 持 `manager`/`inputController`；`sync` 对齐 manager；接 `arbiter.onTap`（~50 行 UIKit shell） |
| `UI/TrainingView.swift` | "水平线" toggle 按钮（D-BUTTON / U2-R2，~25 行 SwiftUI） |

**新增 test（host + E2E）**
| 文件 | 覆盖 |
|---|---|
| `Drawing/DefaultDrawingInputControllerTests.swift` | tapToAnchor round-trip（point↔anchor，含 pixelShift/缩放）；shouldCommit 边界 |
| `Drawing/HorizontalLineToolTests.swift` | lineGeometry（y=priceToY、x 全宽）；hitTest 命中/未命中容差；requiredAnchors |
| `TrainingEngineDrawingCommitTests.swift`（或并入既有 H1 test 文件） | commitDrawing/cancelDrawing FSM 转移 + baseRevision 守卫 + 非 drawing 态 no-op + 幂等 |
| `Render/RenderStateBuilderTests.swift`（扩） | panelPosition 过滤（上栏线不渲下栏，反之） |
| `Drawing/DrawingPersistenceE2ETests.swift` | draw→saveProgress→loadPending→resume：drawings 逐字段还原（消费真 Coordinator + in-memory repos） |

UIKit 层（`ChartContainerView` Coordinator onTap、`TrainingView` 按钮、`KLineView` 注册）= `#if canImport(UIKit)`，host 不编译 → **Catalyst build-for-testing 闸门 + 运行时 runbook** 验证（沿用既有 pure-core host-test + UIKit-shell Catalyst 模式）。

---

## 三、设计决策（D-items，供对抗性评审逐条挑战）

### D-ENGINE：新增 `engine.commitDrawing/cancelDrawing`（FSM 退出）
**问题**：reducer `.drawing` 态唯一出口是 `.drawingCommitted`/`.drawingCancelled`；engine 的 `reduce` 是 `private`，且只有 `activateDrawingTool`（进），无方法 dispatch 退出 → 顺位 4 进得去出不来。

**决策**：在 engine drawing extension 增两薄方法：
```swift
public func commitDrawing(panel: PanelId) {
    guard case .drawing(let snap) = panelState(panel).interactionMode else { return }   // 非 drawing 态 no-op
    _ = reduce(.drawingCommitted(baseRevision: snap.frozen.baseRevision), on: panel)
}
public func cancelDrawing(panel: PanelId) {
    guard case .drawing(let snap) = panelState(panel).interactionMode else { return }
    _ = reduce(.drawingCancelled(baseRevision: snap.frozen.baseRevision), on: panel)
}
```
**为何不违反 RFC §4.4「消费锚不改 engine 契约 / engine 变更集中顺位 6」**：
1. **它们不属顺位 6 冻结的业务 API 面**。顺位 6 serial-neck 冻结的是 trade/tier/`appendDrawing`/zoom/replay-payload（RFC §4.4 总纲枚举）。`commitDrawing/cancelDrawing` 是 **`activateDrawingTool` 激活-handler 家族**的兄弟方法——而 `activateDrawingTool` 本身是 **C8b（Wave 2 顺位 7）** 加的，**不在**顺位 6 surface。即"画线激活 FSM 编排 handler"是 C8b 起、顺位 4 收的一条独立家族，与顺位-6-冻结业务面正交。
2. **serial-neck 的目的（避免两轨并发改 engine，codex outline R8-F1）已消解**：3/6a/6b/10a/11 全 merged，无 open PR，顺位 4 是唯一活跃工作 → 无并发冲突风险。
3. **它们只 dispatch reducer 已 ship 的 action**（PR #48 的 `.drawingCommitted`/`.drawingCancelled`，含 27 格矩阵测试），不引入新 reducer 语义；并**封装** baseRevision/snapshot 细节（caller 不碰 revision），保持 reducer 内部私有。
4. RFC §4.4c"缺口仅此一个=appendDrawing"是对**数据投影**缺口的枚举，未否定 FSM-退出 handler 的存在（同 RFC 的 commit 流隐含需要 `.drawingCommitted`）。

**反方案（评审若否决可退守）**：(a) 把这两方法挪进一个 §4.4c 微修订 PR（6c）先 merge——但 6 已收口、无并发风险、改动极小，独立 PR 过重；(b) 让 Coordinator 绕过 reducer `.drawing` 态、纯靠 UI flag 驱动 drawingMode——但放弃 snapshot-freeze（停 animator + 冻视口）机制，违 C6/C1b/C8b 既定架构，吸引更多评审火力。**主选 = 本决策**。

### D-PANELFILTER：渲染按 `panelPosition` 过滤
**问题**：`renderState.drawings = engine.drawings`（全部），`KLineView.draw` 在**每个**面板渲染 → 上栏横价线会同时画到下栏（错）。
**决策**：`RenderStateBuilder.make` 内 `drawings:` 改为 `engine.drawings.filter { $0.panelPosition == (panel == .upper ? 0 : 1) }`，使 `renderState.drawings` = "本面板应渲的画线"。无行为回归（当前 `tools:[:]` 无 paint）。语义正确：`panelPosition` 是 `DrawingObject` 既有字段（C6 commit 写入）。
**备选**：在 `KLineView.drawDrawings` 调用前过滤——但渲染状态语义应在 `RenderStateBuilder`（单一真相），故落 builder。

### D-TOOLREG：tool 注册位置
**问题**：`KLineView.swift:56` 硬编码 `tools: [:]` → horizontal 永不 paint。
**决策**：改为 `tools: [.horizontal: HorizontalLineTool()]`。MVP 单工具内联即可（无需注册表机制——YAGNI；6 种工具的注册/互斥/快捷按钮属 Phase 4）。`HorizontalLineTool` 是无状态 `struct`，每帧新建零成本。

### D-MANAGER：manager 归属 + completedDrawings 语义
**决策**：`DrawingToolManager(enabledTools: [.horizontal])` 由 `ChartContainerView.Coordinator` 持有（输入暂存与手势处理同层）。流程经 C6 既有 API：`toggle→addAnchor→commit`，commit 产 `DrawingObject` 后 `engine.appendDrawing` 投影。
**completedDrawings 语义（RFC §4.4c 把真相从 manager 降级到 engine.drawings）**：`engine.drawings` 是唯一渲染+持久化真相；`manager.completedDrawings` 是 **C6 遗留的 vestigial 暂存**（commit() 副产，本锚不读、不渲、不持久）。它仅累积本 Coordinator 生命期内的提交（resume 后 manager 空而 engine.drawings 满——二者**故意发散**，因 manager 非真相）。累积有界（每会话寥寥几条 + Coordinator 随图表 teardown），benign。
**考虑过的替代**：commit 后 `manager.deleteDrawing(at:last)` 保持 manager 纯瞬态——更"干净"但引入 commit-then-delete 怪舞；**主选 = 接受 vestigial 累积 + 文档说明**。评审若判累积不可接受则切删除舞。

### D-BUTTON：toggle 按钮归属与语义
**决策**：按钮在 `TrainingView`（U2 D7 显式 defer 到本锚 = U2-R2）。仅作用 `.upper` 面板。**可见性门 = `engine.flow.canBuySell()`**（与 `showsTradeButtons` 同源，Normal/Replay 可见、Review 隐藏；见 D-REVIEWMODE）。toggle 语义读 `engine.upperPanel.interactionMode`：
- 非 `.drawing` → `engine.activateDrawingTool(.horizontal, panel: .upper)`（进入）。
- `.drawing` 中 → `engine.cancelDrawing(panel: .upper)`（退出/取消）。
按钮选中态绑 `engine.upperPanel.interactionMode == .drawing`（@Observable 自动反映；commit 成功后 engine 自动退 .drawing → 按钮自动复位）。MVP 单按钮（非 6 工具面板）。

### D-CROSSPERIOD：水平线天然规避跨周期重映射
水平线锚仅 `price` 承重（横线全宽、`candleIndex` 不参与 render）。`price` 是**周期无关**的纵轴量 → render 用**当前**面板 `mapper.priceToY(anchor.price)`，切周期/缩放/平移后横线仍画在正确价位。故"跨缩放/平移还原"对横线 = render 用实时 mapper 即得，**无需** anchor 重映射逻辑（那是 Phase 4 斜线工具的难题）。`anchor.period`/`candleIndex` 作元数据存储（DrawingObject 完整性），render 不消费。

### D-NOSPLIT：不拆 4a/4b
prod 估算 ~180-230 行（2 新文件 ~80 + 5 改文件 ~100-150），远低于 outline 的 500 行拆分阈值。持久化"全链路"已 ship（0 新代码）大幅压缩了 outline 预估的 4b 体量。**单 PR 交付**。

---

## 四、坐标映射细节

`tapToAnchor` 逆映射经 `CoordinateMapper`（`Geometry.swift`）：
- `candleIndex = mapper.xToIndex(point.x)`（verify-and-correct round-trip 恒等，独立 fractional pixelShift/candleStep/displayScale）。
- `price = mapper.yToPrice(point.y)`（线性 priceRange 逆插值）。
- `period = panel.period`（reducer PanelViewState 的 period）。

mapper 在 onTap 时由 Coordinator 构造：`CoordinateMapper(viewport: view.renderState.viewport, displayScale: view.traitCollection.displayScale)`。`view.renderState.viewport` 是上次 `updateUIView` 算出的 `ChartViewport`。**关键不变量**：`.drawing` 态下 animator 已停、offset 已冻 → renderState.viewport == 落锚时刻视口（无漂移）。`renderState == .empty`（无 candle）时 onTap 守卫 return（不落锚）。

---

## 五、错误处理 / 边界

| 场景 | 处理 |
|---|---|
| 空图表（renderState.empty）落锚 | onTap 守卫 return，不落锚（无 viewport 可映射） |
| 非 drawing 态收到 onTap | arbiter.onTap 仅 drawing 模式 fire（`ChartGestureArbiter:186`）；Coordinator 再 guard `isDrawing` 双保险 |
| 重复点按钮（已 drawing 再 activate） | `activateDrawingTool` guard effect 不匹配 → 早返 no-op（`TrainingEngine:707-710`） |
| commitDrawing/cancelDrawing 在非 drawing 态 | guard case .drawing → no-op（幂等） |
| setDrawingSnapshot 理论 stale（revision 漂移） | reducer 留 .autoTracking（`Reducer:118`）；同步路径下不发生（animator 已停） |
| review 模式绘线 | **MVP 决策（D-REVIEWMODE）**：绘线 toggle 按钮仅 `engine.flow.canBuySell()`（Normal/Replay=true、Review=false）可见——与交易按钮同源谓词（`TrainingView.showsTradeButtons`），杜绝谓词漂移。理由：Review 是只读历史回放，允许绘线会引出"是否覆盖已 finalize record"的污染争议；Normal 绘线经 saveProgress/finalize 持久化、Replay 绘线 render-only（saveProgress no-op + finalize 返 nil，天然瞬态）——二者均无污染。Review 绘线（瞬态注解）作可能的后续增强，非 MVP。 |
| 下栏面板进入 drawing | MVP 按钮只发 `.upper`；下栏 Coordinator onTap 即便接线也因下栏永不 .drawing 而不触发 |

---

## 六、测试策略

1. **host 纯逻辑**（macOS swift test）：
   - `DefaultDrawingInputController`：tapToAnchor round-trip（构造已知 viewport → point → anchor → 验 candleIndex/price/period）；shouldCommit（horizontal 1 锚→true，0 锚→false）。
   - `HorizontalLineTool`：lineGeometry（y == priceToY(price)，x 横跨 mainChartFrame 全宽）；hitTest 容差命中/边界；`requiredAnchors == 1...1`；`type == .horizontal`。
   - `commitDrawing/cancelDrawing`：构 engine 进 .drawing → commit → 验 interactionMode==.autoTracking + revision bump + offset==0；cancel 同；非 drawing 态 no-op；append 与 commit 独立（append 不改 mode、commit 不改 drawings）。
   - `RenderStateBuilder` panelPosition 过滤：上栏线（panelPosition=0）在 .upper renderState.drawings 在、.lower 不在。
2. **E2E 持久化**（host，真 Coordinator + InMemory repos）：构 Normal 局 → engine.appendDrawing 一条 horizontal → coordinator.saveProgress → loadPending → 验 pending.drawings 含该线（逐字段）→ resumeIfAny → 验 engine.drawings 逐字段还原。覆盖 outline "E2E save/resume"。
3. **Catalyst build-for-testing**：`ChartContainerView`/`TrainingView`/`KLineView` UIKit 改动编译 + 链接（required CI 闸门）。
4. **运行时 runbook**（outline §三.3 + §五）：交付 runbook 条目"水平线绘制 + 跨缩放/平移还原"——device/sim 手动步骤（点按钮→点图表→见横线→pinch/pan→横线维持正确价位→Back→重进→横线还原）。运行时实测是 user device 职责，其完成是顺位 13 阻塞依赖；本锚交付 runbook **条目**（步骤定义）。

mutation-sanity（per `feedback_swift_local_toolchain_blindspot` + FP demonstrator 教训）：tapToAnchor round-trip 用**非零** pixelShift/offset/缩放 viewport（非默认 80 视口）做 demonstrator，证逆映射在真实缩放/平移下成立，非空洞恒等。

---

## 七、验收（非-coder 可执行清单大纲）

交付时出独立 `docs/acceptance/2026-06-13-wave3-pr4-drawing-mvp.md`（action/expected/pass-fail，中文，禁用语见 `.claude/workflow-rules.json`）。要点：
- 新文件 `DefaultDrawingInputController.swift` / `HorizontalLineTool.swift` 在 PR。
- `KLineView.swift` 不再含 `tools: [:]`（grep 反向断言，用 `-F` 字面 + if/exit 防 set -e 死闸门，per `feedback_acceptance_grep_anchoring`）。
- `engine.commitDrawing`/`cancelDrawing` 存在。
- host 测试套件全绿 + 新增 N 测试。
- Catalyst build-for-testing SUCCEEDED。
- runbook 条目"水平线绘制+跨缩放还原"在 acceptance/runbook 文件。

---

## 八、Residual / 后续

| Residual | 归属 |
|---|---|
| 6 种其余画线工具 + 工具面板 + 互斥/快捷键 | Phase 4（独立 track） |
| hit-test 选中删除交互 | Phase 4 |
| 下栏画线 | Phase 4 / 后续 |
| 周期 autosave 触发画线 commit（RFC §4.6） | 顺位 10b |
| review 模式瞬态绘线（MVP 经 canBuySell 排除 Review，D-REVIEWMODE） | 后续增强（非 MVP） |
| manager.completedDrawings vestigial 累积（若评审判不可接受） | 本 plan-stage 切删除舞 |

---

## 九、对齐既有教训（memory feedback）

- `feedback_acceptance_grep_anchoring`：验收负向断言用 `grep -F` 字面 + `if ...; then exit 1`，不用裸 `! grep`（set -e 死闸门）/ ERE `\|`。
- `feedback_swift_local_toolchain_blindspot`：本地 swift test 绿 ≠ Catalyst 绿；UIKit 层靠 Catalyst 闸门；非整除浮点用容差。
- `feedback_codex_round6_self_contradiction` / `feedback_big_pr_codex_noncovergence`：对抗性评审 ≥3 轮就同一论点复述 = permanent-bias → escalate + attest override。
- FP demonstrator 须 mutation-verify（非零参数证非空洞）。
- spec 示例 illustrative、矩阵/契约权威（C6 §3.3 "典型流程"是 illustrative，RFC §4.4c 契约权威）。

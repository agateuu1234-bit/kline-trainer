# 划线 P1b-1b-i 切片4（PR-4）：交互 UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 PR-1/2/3 建好的引擎地基（`drawingsRevision` / 写入边界 API / 命中与选中渲染）第一次接到用户手上——底栏 ③🗑 删除键 + 类型行图标 toggle（画线态/选择态）+ 删除确认框 + 常驻样式面板作用于选中线（选中即回显），**这是 1b-i 四个切片里第一个用户看得见的**。

**Architecture:** 三层，每层只干一件事。① **几何真相发布**：UIKit `Coordinator` 在 `rebuildRenderState` 末尾把**它这一帧真实渲染用的** `CoordinateMapper` 发布进 `DrawingSession`（`@ObservationIgnored`，不参与 observation），因为 SwiftUI 层没有 mapper、而重新推导会与真实渲染视口分叉（`RenderStateBuilder.make:39-46` 的聚合分支会重算 `priceRange`）。② **单一写入路由** `DrawingEditRouter`（无 UIKit、host 可测）：承载 D65 两个可用性谓词 + D58 候选预检 + D64 存在性清空，是 `updateDrawingStyle` / `deleteDrawing(id:)` 在 `Sources/` 里**唯一**的调用点。③ **SwiftUI 只做呈现与分发**：🗑 / toggle / 5 组样式控件读谓词置灰、写路由，自己**不做任何几何判断、不存任何样式副本**。

**Tech Stack:** Swift 6 / SwiftPM（`ios/Contracts`，`swift-tools-version: 6.0`）· Swift Testing（`@Test` / `#expect`）· SwiftUI（`confirmationDialog` / `.disabled`）· CoreGraphics（几何判据，无 UIKit）· UIKit（`KLineView` / `ChartContainerView.Coordinator` / 全部 View 层测试，**Catalyst `xcodebuild test` 才真跑**）· `@Observable` + `@MainActor`

---

## Global Constraints

以下每一条对**每个** Task 都隐含生效。数值逐字取自 spec / 本机实测，不得改写。

- **契约**：`CONTRACT_VERSION` 保持 **1.12**、`user_version` 保持 **7**、**零迁移**。`DrawingObject` **不新增、不修改任何持久化字段**；选中态、`selectionGeometryVisible`、视口 mapper 全是**瞬时 UI 状态**，绝不进任何存储路径（D55 / spec §5）。
- **base**：`2432d5f`（= `origin/main`，含 PR-3 #156 squash `46fba04`，其上还有 QMT #155/#157）。分支 `drawing-tools-p1b-1b-i-pr4`，worktree `.claude/worktrees/drawing-p1b-1b-i-pr4`。
- **host 基线（本机亲跑，已确认）**：`swift test` = **1752 passed / 213 suites / exit 0**。
- **Catalyst 闸门基线（已读文件确认）**：`total` = **1663**（`.github/scripts/catalyst-total-baseline.txt`）、`uikit` = **71 行**（`.github/scripts/catalyst-uikit-baseline.txt`）、G7 容差 `DELTA` = **30**（`catalyst-gate.sh`）。本切片**必然新增 UIKit-gated 测试** →
  - `catalyst-uikit-baseline.txt` **无条件必须重新生成**（`python3 .github/scripts/uikit-expected-tests.py > …`，**禁手打测试名**）——它与 total 是否漂移**无关**：`catalyst-gate.test.sh` 会对当前源码活推导并与基线**逐行比对**，不一致即自测 FAIL；
  - uikit 基线一改，`fixtures/pass-main-current.log` **必须用一份真 fresh Catalyst 日志脚本逐行重裁，禁手打伪造行**；
  - `catalyst-total-baseline.txt` **只在** total 漂出 `1663 ± 30`（即 1633–1693）时才动。
  - ⚠️ `catalyst-gate.sh` **不跑 xcodebuild**——必须自己先跑 `xcodebuild test` 产出日志再把路径传给它。完整命令见 Task 7。
- **本切片不做（越界即停下报告）**：🔒 / 锁定解锁动作 / `setDrawingLocked` / 撤销 / 前进 / 底栏 ②🔒④↩⑤↪ → **1b-ii**；节点 / 多锚 / 四个新工具 → **P1c**；复盘的选中 → **P5**；主页全局默认设置 → **P6**。**不删** `DrawingToolManager` 死代码（spec §1.2 / §8 #5）。**不动** `reviewDrawings` 的 `.count` 触发器（D56）。
- **UI 置灰谓词必须与引擎门逐条对齐**（PR-2 交接②）：引擎比 spec D65 字面多**三道**——`hasKnownFutureFields`（未来顶层字段）、`DrawingStyleAvailability.isEditableToolType`（本构建懂不懂这个工具的样式语义）、`flow.mode != .review`。谓词漏任何一道 = 「控件亮着、点了没反应」。
- **访问级别纪律**（`DrawingSession.swift:21-28` 大注释）：容器**状态** `public private(set)`，**mutator 一律 internal**（前面不加 `public`）。新增的 `setViewportMapper` / `setSelectionGeometryVisible` 同样 internal，并纳入既有源码守卫（`DrawingSessionSourceGuardTests` 的 mutator 清单）。
- **fail-closed 门必须限定到它真适用的那一类**（PR-1 `.segment` 门误管所有工具 → 非水平线被静默丢弃的教训）。
- **测试判别力**：每条新测试写完都要做一次**变异验证**（把被测那行改坏 → 测试必须红 → 再改回来）。**UIKit-gated 文件在 host 上 `canImport(UIKit)==false`、根本不参与编译 → host 全绿不构成它们的任何证据，针对它们的变异必须上 Catalyst 真跑**。判绿**读执行量**（`Test run with N tests`）不读 `TEST SUCCEEDED` 字样。
- **命名一致性**（后续 Task 依赖，不得改名）：`DrawingEditRouter.selectionGeometryVisible(engine:)`（现算）/ `.canEditStyle(engine:)` / `.canDelete(engine:)`（现算，**路由用**）/ `.styleControlsEnabled(engine:)` / `.deleteButtonEnabled(engine:)`（读 observable 提示，**UI 用**）/ `.panelStyle(engine:)` / `.applyStyle(_:engine:)` / `.deleteSelected(engine:)` / `DrawingSession.setViewportMapper(_:panel:)` / `.viewportMapper(for:)` / `.selectionGeometryVisible` / `.setSelectionGeometryVisible(_:)` / `bareIdentifierReferences(inCode:identifier:)` / `codeTextPreservingBoundaries(_:)` / `expectIdentifierNeverVended(_:inFiles:)`。
- **两条读法不得混用**（PD2）：`Sources/` 里 **UI 层只许调 `styleControlsEnabled` / `deleteButtonEnabled`**，**路由内部只许调 `canEditStyle` / `canDelete`**；反过来任一处都是缺陷（UI 调现算 → 不重绘；路由调提示 → 用陈旧值放行写入）。由 Task 3 的源码守卫钉死。
- **注释里不得嵌「跑某命令应得 N」式自验证**（终点是 HEAD 会把后续提交算进去，一落地就自证伪）。
- **源码守卫的文本来源纪律（PD7，codex plan-R2-F1 定的规矩，全计划统一遵守）**——本仓已被这条坑过多次（[[feedback_acceptance_grep_anchoring]]）：

  | 断言类型 | 用哪份文本 | 为什么 |
  |---|---|---|
  | **否定**断言（「这个标识符不许出现」） | `squeezedSource(path)`（**剥注释、剥字符串字面量内容**）+ needle 过 `squeeze()` | 读原始文本会被**注释里的同名字**打红。计划里那些「为什么不用 X」的承重注释**必然**提到 X；用原始文本 = 逼实施者删注释才能过测试 |
  | **肯定**的**结构**断言（「这行代码在」） | 同上（`squeezedContains(path, needle)`） | 与排版无关，且不会被注释里的相似文字假绿 |
  | **肯定**的**用户可见文案**断言（`Text("类型")` / `"确定删除划线？"`） | **原始文本**，且 needle 必须带**完整调用语法**做锚（`.confirmationDialog("确定删除划线？"`），不许只写裸词 | `squeezedSource` 会**丢弃字符串字面量内容** → 文案断言在它上面恒假。裸词锚会被注释里的同一个词假绿 |
  | 「陈旧注释必须删掉」断言 | **原始文本**（这类断言的对象**就是**注释） | 唯一正当的原始文本否定断言；写清楚它测的是注释 |

  ⚠️ **不要用「禁止出现的图标名/关键词黑名单」表达「只许有这两个控件」**——黑名单既会漏（新图标名不在表里）又会误伤注释。改用**结构计数**（如「本视图恰好 2 个 `Button`」），机械且完备。

---

## 已核实的源码事实（对 `2432d5f` 逐条实测，非从 spec 推断）

实施时若与实际不符 **先停下报告**，不要硬改。

| 事实 | 位置 | 状态 |
|---|---|---|
| 底栏是**单行**，只有「类型」键 + `Spacer()` | `UI/DrawingModeBar.swift:13-25` | 无 🗑，需新增 |
| 类型行水平线图标**恒亮、短按 no-op** | `UI/DrawingTypeOverlay.swift:25-31` | 注释写死「本期无选中、不做 toggle」 |
| `setMode(` 在 `Sources/` **零调用点** | `Drawing/DrawingSession.swift:76` | → 生产里 `mode` 恒 `.draw`，`.select` 不可达 |
| `updateDrawingStyle(` / `deleteDrawing(id:` / `deleteDrawing(at:` 在 `Sources/` **零调用点** | `TrainingEngine.swift:1089/1109/1156` | 三者均 internal |
| 引擎 `updateDrawingStyle` 的门**共 6 道** | `TrainingEngine.swift:1157-1178` | ⓪review ①id非空唯一 ②locked ②b`isEditableToolType` ③`hasKnownFutureEnumValues`+`hasKnownFutureFields` ④`withStyle` |
| 引擎 `deleteDrawing(id:)` 的门**共 3 道** | `TrainingEngine.swift:1110-1114` | ⓪review ①id非空唯一 ②locked（**刻意不查未来数据**） |
| `withStyle` 另有 **thickness 值域闸**（1…5 **或**与本对象当前值相同） | `Drawing/DrawingObjectStyleEdit.swift:27` | 高版本 `thickness=8` 的线原样带回可放行 |
| `DrawingStyleParams` 直读 `session.defaultStyle` / 直写 `session.setDefaultStyle` | `UI/DrawingStyleParams.swift:15,20` | D49 要改成 `style` + `onChange` |
| 样式面板挂载条件 | `UI/TrainingView.swift:115` | `stylePanelWillBeVisible = showsTradeButtons && isDrawingActive && typeRowExpanded` |
| `showsTradeButtons = engine.flow.canBuySell()` | `UI/TrainingView.swift:82` | **复盘为 false** → 复盘既无底栏也无类型行 → **结构上进不去 `.select`**（交接⑥） |
| 底栏挂载点 / 面板挂载点 | `UI/TrainingView.swift:254` / `:702-704` | `ChartPanelsContainer` 持 `engine`，是「同时持有 engine 与 session」那一层（D49 要求路由放这里） |
| `CoordinateMapper` 只在 UIKit 侧构造 | `Render/ChartContainerView.swift:251,298` / `KLineView.swift:84` | SwiftUI 层拿不到 → 必须发布 |
| 真实渲染视口**可能 ≠** `makeViewport` 输出 | `Render/RenderStateBuilder.swift:39-46` | 进行中聚合 K 线会**重算 `priceRange`** → SwiftUI 侧重新推导会与渲染/命中分叉 |
| `rebuildRenderState` 末行 | `Render/ChartContainerView.swift:204` | `view.renderState = newState` —— 发布点接在它后面 |
| `updateUIView` 期间改 @Observable 会出事 | `TrainingEngine.swift:70-71` 注释 + `ChartContainerView.swift:105` | 既有逃生门 = `DispatchQueue.main.async` |
| `scanCode` **丢弃全部空白** | `Tests/.../SourceGuardScanner.swift:99` | → 裸标识符判据**不能**跑在 squeezed 文本上（见 Task 1） |
| vend 缺口真实存在 | `SourceGuardScanner.swift:152-157,199-203` | `callSiteCount` 只数「后跟 `(`」；`filesMentioning` 白名单内不再细查 → 白名单文件**内部** `{ deleteDrawing }` 两层全过 |
| `confirmationDialog` 是本仓既有先例 | `UI/TrainingView.swift:201-211` | `Button(role: .destructive)` + `Button(role: .cancel)`，点框外可关 |
| 会被签名改动打红的既有守卫 | `Tests/.../DrawingStylePanelSourceGuardTests.swift:27-34, 85-90, 174, 232` | 锚 `session.setDefaultStyle` / `session.defaultStyle` / `"DrawingStylePanel(session:"` / `"DrawingStyleParams(session: session, scheme: scheme)"` |
| 共享测试 fixture | `Tests/.../DrawingTestFixtures.swift:23-38` | `makeStyledHLine(id:…period:candleIndex:price:)`，默认 `period: .daily`、`revealTick: 7` |
| `TrainingEngine.preview()` 面板周期 | `TrainingEngine.swift:1402` 注释 | upper=`.m60`、lower=`.daily` |
| `DrawingDefaultStyle` 只有 `init()`，5 个字段全 `var` | `Models/DrawingEnums.swift:28-35` | 构造靠逐字段赋值 |

---

## 本计划定稿的实现决策（PD1–PD6）

spec D49–D67 已冻结，下列是 spec 留给实施的自由度，**在本计划里定死**，实施者不得自行改选。

### PD1　几何真相 = Coordinator 发布「它真实渲染用的那个 mapper」，不在 SwiftUI 侧重新推导

**为什么不重新推导**：`RenderStateBuilder.make:39-46` 在「最后一根可见 K 线是进行中聚合」时会用 m3 合成 partial candle 并**重算 `priceRange`**，返回的 `renderViewport` 与 `makeViewport()` 的输出**不同**。SwiftUI 侧再推一遍 = 第二份几何真相，会在这个分支上与渲染/命中分叉——正是 D40「命中集合 ≡ 渲染集合」要消灭的那类缺陷。
**形状**：`DrawingSession` 存 `@ObservationIgnored` 的 `[Int: CoordinateMapper]`，`Coordinator.rebuildRenderState` 在 `view.renderState = newState` **之后**发布本面板的 mapper。

### PD2　几何分量有**两个读法**，且必须刻意分开（codex plan-R1-F2 纠正本计划初稿）

| | 谁用 | 几何怎么读 | 为什么 |
|---|---|---|---|
| **门**（唯一强制点） | `applyStyle` / `deleteSelected` 两条写入路由 | 用 `session.viewportMapper(for:)` **现算** `HorizontalLineTool.visibleGeometry` | D65 R13-F1：确认框有时间窗，只在点 🗑 那刻判是时序 bug |
| **提示**（置灰） | 🗑 与 5 组样式控件的 `.disabled` | 读 **observable** 的 `session.selectionGeometryVisible` | **只有读这个 observable 才能让 SwiftUI 建立依赖**——mapper 是 `@ObservationIgnored`，UI 若也走现算，平移到线看不见时**根本不会重绘**，控件就一直停在旧的亮/灰状态（验收 #18c 当场失效） |

> ⚠️ **本计划初稿在这里写错过**：初稿让 UI 直接调现算版谓词，等于把 observable 提示晾在一边、白建一套信号。codex plan-R1-F2 抓出。**修法不是二选一，而是把两个读法都显式命名**（`canEditStyle` / `canDelete` = 现算，路由用；`styleControlsEnabled` / `deleteButtonEnabled` = 读提示，UI 用），并把**非几何分量抽成共享 helper**，保证两条路径只在「几何怎么读」这一点上不同、不可能在别的分量上漂移。

- **提示陈旧的最坏后果只是控件亮/灰晚一帧**——写入永远不会因此放行（门在路由那一侧）。
- **两个读法调的是同一个 `visibleGeometry` 实现**（spec D65 明写：单点约束指**函数实现**只有一份，不是调用点只有一处）。
- **`setSelection` 顺手把提示置 `true`**：选中**只可能**由 `hitTest` 命中产生，而 `hitTest` 内部就是 `visibleGeometry != nil`（D40 同一个函数）——**命中即证明此刻几何可见**。这不是第三份真相，是同一份真相在建立选中那一刻的直接结论；不这么做，验收 #9「单击一条线 → 🗑 从灰变亮」要等一个 runloop 才生效。

### PD2b　面板置灰谓词必须区分「有选中」与「无选中」（codex plan-R1-F1 纠正本计划初稿）

**初稿的错**：`styleEnabled` 无条件取 `canEditStyle(engine:)`，而该谓词在**没有选中**时返回 `false`（`uniqueSelected == nil`）→ 面板控件会在无选中时全灰，用户**改不了「下一条线的默认」**——那是 1a-iii 就有的能力，会被本切片直接回归掉，且砸掉验收 #13（取消选中后改默认、再画一条新线）。

**定稿**：
```
样式控件可用 ⟺ 无选中 → **恒可用**（此刻它在改「下一条线的默认」，与任何线的状态无关）
              有选中 → 由 D65「改样式可用」决定
🗑 可用      ⟺ 有选中 且 D65「删除可用」（无选中恒灰，spec §1.1 #1 原文）
```
两者**不对称是对的**：样式面板在无选中时有正当工作要做（改默认），🗑 在无选中时没有操作对象。
- **为什么不能省掉提示、靠 engine 的 observable 顺带刷新**：平移改的是 `engine.upperPanel`（会触发 SwiftUI 失效），但 mapper 是在**那次失效引发的 `updateUIView` 里**才更新的 → 面板本帧读到的仍是上一帧的 mapper，惯性停止后这个滞后**不会自动纠正**，验收 #18c 的「平移到看不见 → 变灰」就会不生效。
- **写入必须延后一个 runloop**（`DispatchQueue.main.async`）：`rebuildRenderState` 的调用点之一是 `updateUIView`（视图更新期），期间改 @Observable 是 SwiftUI 明令的未定义行为。本仓已有同一条逃生门先例（`ChartContainerView.swift:105` 释放 `crosshairOwner`）。**且只在值真的会变时才 dispatch**（平移每帧都写会造成 写→失效→再 update 的循环 + 每帧一次派发）。

### PD3　写入路由是**无 UIKit** 的 `Drawing/DrawingEditRouter.swift`

- 它只依赖 `TrainingEngine` / `DrawingSession` / `CoordinateMapper` / `HorizontalLineTool` —— 全都无 UIKit → **host `swift test` 可测**。
- 收益是直接对着本项目最痛的坑：几何门、时间窗（N19e）、失败原因 × 选中生命期（N17）这些**最危险**的判据全部拿到 host 上的真证据，Catalyst 只需覆盖「Coordinator 真发布 mapper」与「SwiftUI 控件真接线」。
- 源码守卫白名单**只加这一个文件**。

### PD4　类型行 toggle 两个方向**都走 `setMode`**（不走 `activate`）

`activate(tool:)` 是「开会话/换工具」的入口（唯一调用点在 `TrainingEngine.beginDrawingSession`，`DrawingSessionSourceGuardTests` 钉死 Coordinator 不得调它）。切回画线态**不是**开会话——会话一直开着、`activeDrawingTool` 在选择态恒非 nil（D57）。故两个方向都是 `setMode(.select)` / `setMode(.draw)`，`setMode(` 在 `Sources/` 恰好 **1 处**。

### PD5　🗑 是 D24 五键骨架的**第③键**，不是第②键

split addendum D23 原文：1b-i = 底栏 **③🗑**；1b-ii = 底栏 **②🔒④↩⑤↪**。本 spec §0 表格「②🔒④↩⑤⏎ 仍留 1b-ii」与之一致。
→ 底栏顺序 `类型` → `🗑` → `Spacer()`；②🔒 的位置**不渲染任何占位**（母 spec D19 / D24：不 ship 恒灰的未接线按钮），1b-ii 落 🔒 时插在两者之间。

### PD6　编辑被拒 = **静默 no-op**，不加任何提示文案

spec D58 写「给反馈」，但：① §7 的 25 条验收里**没有**任何一条描述提示；② 母 spec §3 明令样式面板内**不得**出现解释文案（既有守卫 `noNotApplicableCopy` 钉死）；③ 反馈天然存在——面板显示的样式是选中线的**派生值**，写入被拒 → 线没变 → 控件**原地不动弹回**，用户看到的就是「这一下没生效」。
本期唯一可达的拒绝路径是「把可见的 `.straight` 改成锚点在右缘外的 `.ray`」。**如实记录为对 spec 措辞的偏离**，交 codex / user 裁决。

---

## 文件结构

**新建（源码 1 个）**

| 文件 | 职责 |
|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift` | 唯一写入路由 + D65 两个可用性谓词 + D49 面板派生样式 + D58 候选预检 + D64 存在性清空。**无 UIKit、host 可测**、`@MainActor` |

**新建（测试 2 个）**

| 文件 | 职责 |
|---|---|
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditRouterTests.swift` | 上者的 host 测试（N1 / N12b·c / N13d / N14d / N16 / N17 / N18 / N19c·e / N21d） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift` | PR-4 的接线源码守卫（视口发布 / `setMode` 唯一调用点 / 🗑 接线 / 复盘不可达 / 两条读法不混用）。**Task 2 Step 6c 建，后续 Task 只追加** |

**修改（源码 6 个）**

| 文件 | 改动 |
|---|---|
| `Drawing/DrawingSession.swift` | `@ObservationIgnored viewportMappers` + `setViewportMapper` / `viewportMapper(for:)`；`selectionGeometryVisible` + `setSelectionGeometryVisible`（等值不写）；`clearSelection()` 复位它 |
| `Render/ChartContainerView.swift` | `rebuildRenderState` 末尾发布 mapper + 延后刷新几何提示 |
| `UI/DrawingModeBar.swift` | `DrawingBottomBar` 增 ③🗑（`deleteEnabled` / `onDelete`） |
| `UI/DrawingTypeOverlay.swift` | 水平线图标改 toggle（`isDrawMode` / `onToggleMode`），点亮=画线态 |
| `UI/DrawingStylePanel.swift` | 透传 toggle 与样式三参（`style` / `styleEnabled` / `onStyleChange`） |
| `UI/DrawingStyleParams.swift` | 改收 `style` / `enabled` / `onChange`（D49 派生值，不再直读直写 session） |
| `UI/TrainingView.swift` | 底栏 🗑 接线 + 删除确认框 + `ChartPanelsContainer` 里算派生样式/谓词/路由分发 |

**修改（测试）**：`Tests/.../SourceGuardScanner.swift`（+`codeTextPreservingBoundaries` / `bareIdentifierReferences` / `expectIdentifierNeverVended`）、`SourceGuardScannerTests.swift`（自检）、`TrainingEngineDrawingSessionTests.swift`（N15 / N19a 由 0 改 1）、`Drawing/DrawingSessionTests.swift`、`Drawing/DrawingSessionSourceGuardTests.swift`、`Render/DrawingStylePanelSourceGuardTests.swift`、`Render/TrainingViewShellSourceGuardTests.swift`、`Render/DrawingBottomBarHeightTests.swift`、`Render/ChartContainerViewDrawingSessionTests.swift`

---

## Task 0：基线确认（不写代码，不 commit）

**Files:** 无

- [ ] **Step 1: 确认工作区**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
pwd; git rev-parse --abbrev-ref HEAD; git rev-parse HEAD; git status --porcelain
```

Expected：`branch = drawing-tools-p1b-1b-i-pr4`、`HEAD = 2432d5fbc48860d2d7ae3c6cdd2db52ae908f2d8`（首个 task 时）、工作区只有本计划文件。
⚠️ **每条闸门命令都要同时打印 branch/HEAD**（评审 subagent 在主仓 checkout 造成的假绿，本项目踩过）。

- [ ] **Step 2: 跑 host 基线并对账**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test 2>&1 | tail -5
```

Expected：`Test run with 1752 tests in 213 suites passed`。数字对不上 → **停下报告**（别继续，基线错了后面每个 Task 的对账都是假的）。
⚠️ 判绿**读输出内容**，不看 exit code（管道会吞退出码，本项目踩过 2 次）。

---

## Task 1：关掉「白名单文件内部 vend 方法引用」缺口（PR-2 交接③）

**为什么必须先做**：PR-2 终审探针 P2 实证——既有两层守卫（`callSiteCount` 只数「后跟 `(`」；`filesMentioning` 只判「哪些文件提到过」）对**白名单文件内部**的 `func handle() -> (DrawingID) -> Bool { deleteDrawing }` 双双放行。今天零调用点故不可达；**Task 3 要把路由文件加进白名单 = 打开攻击面**，必须先堵。本 Task 结束时 `Sources/` 仍是零调用点，行为零变化。

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScanner.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScannerTests.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`（两条既有守卫各加一句）

**Interfaces:**
- Produces：`codeTextPreservingBoundaries(_ raw: String) -> String`、`bareIdentifierReferences(inCode: String, identifier: String) -> Int`、`expectIdentifierNeverVended(_ identifier: String, inFiles: [String]) throws`

- [ ] **Step 1: 写失败测试（扫描器自检 g，合成字符串，两个方向都钉）**

追加到 `SourceGuardScannerTests.swift`：

```swift
    @Test("守卫自检 g（PR-2 交接③）：白名单文件内部的 vend 方法引用必须被抓到，正常声明/调用不得误报")
    func scannerCatchesVendedMethodReference() {
        // ① 会被抓：三种真实 vend 写法
        let vended = """
        extension TrainingEngine {
            func handle() -> (DrawingID) -> Bool { deleteDrawing }
            func pick() -> ((DrawingID) -> Bool) {
                let f = deleteDrawing
                return f
            }
            var alias: (DrawingID) -> Bool { self.deleteDrawing }
        }
        """
        #expect(bareIdentifierReferences(inCode: codeTextPreservingBoundaries(vended),
                                         identifier: "deleteDrawing") == 3,
                "三处 vend 都该命中，实际文本：\(codeTextPreservingBoundaries(vended))")

        // ② 不得误报：声明 / 调用 / 更长标识符 / 注释 / 字符串字面量
        let clean = """
        extension TrainingEngine {
            func deleteDrawing(id: DrawingID) -> Bool { true }
            func deleteDrawing(at index: Int) {}
            func deleteDrawingForTesting() {}
            func caller() {
                _ = deleteDrawing(id: "a")
                self.deleteDrawing(at: 0)
                deleteDrawingForTesting()
            }
            // 注释里写 deleteDrawing 不算
            /* 块注释里的 deleteDrawing 也不算 */
            let s = "字符串里的 deleteDrawing 不算"
        }
        """
        #expect(bareIdentifierReferences(inCode: codeTextPreservingBoundaries(clean),
                                         identifier: "deleteDrawing") == 0,
                "误报了，实际文本：\(codeTextPreservingBoundaries(clean))")
    }

    @Test("守卫自检 g3（codex plan-R4-F2）：注释/字面量被剥掉时留下边界 —— 紧贴注释的 vend 逃不掉，紧贴注释的调用不误报")
    func scannerKeepsBoundaryAcrossComments() {
        // ① Swift 里注释本身就是 token 分隔符，下面两行都是**合法代码**里的真 vend
        let vendedAcrossComment = """
        extension TrainingEngine {
            func a() -> (DrawingID) -> Bool { return/*x*/deleteDrawing }
            func b() -> (DrawingID) -> Bool { return//x
                deleteDrawing }
        }
        """
        #expect(bareIdentifierReferences(inCode: codeTextPreservingBoundaries(vendedAcrossComment),
                                         identifier: "deleteDrawing") == 2,
                "紧贴注释的 vend 漏检 —— 第三层守卫可被绕过。实际文本：\(codeTextPreservingBoundaries(vendedAcrossComment))")

        // ② 反向：紧贴注释的**正当调用**不得被误报（边界空格把 `(` 推开了，判据必须跳空格再看）
        let callAcrossComment = """
        func caller() {
            engine.deleteDrawing/* c */(id: c)
            engine.deleteDrawing
                (id: d)
        }
        """
        #expect(bareIdentifierReferences(inCode: codeTextPreservingBoundaries(callAcrossComment),
                                         identifier: "deleteDrawing") == 0,
                "正当调用被误报成 vend，实际文本：\(codeTextPreservingBoundaries(callAcrossComment))")

        // ③ 边界不得把两个独立 token 粘成一个长标识符（①② 必须看紧邻字符）
        #expect(bareIdentifierReferences(inCode: "let x = deleteDrawing Foo", identifier: "deleteDrawing") == 1)
        #expect(bareIdentifierReferences(inCode: "deleteDrawingForTesting()", identifier: "deleteDrawing") == 0)
    }

    @Test("守卫自检 g2：`codeTextPreservingBoundaries` 与 `squeezedText` 是同一个词法器，只差空白处理")
    func boundaryPreservingSharesLexer() {
        let src = """
        func f() {
            // deleteDrawing 注释
            let s = "deleteDrawing 串"
            engine.deleteDrawing(id: x)
        }
        """
        // 两者都必须剥掉注释与串内容、都必须保留那一次真实调用
        #expect(!codeTextPreservingBoundaries(src).contains("注释"))
        #expect(!codeTextPreservingBoundaries(src).contains("串"))
        #expect(codeTextPreservingBoundaries(src).contains("engine.deleteDrawing(id: x)"))
        #expect(squeezedText(src).contains("engine.deleteDrawing(id:x)"))
    }
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test 2>&1 | tail -20
```

Expected：编译失败 —— `cannot find 'bareIdentifierReferences' in scope` / `cannot find 'codeTextPreservingBoundaries' in scope`。

- [ ] **Step 3: 给 `scanCode` 加保留空白的开关（**参数化，绝不复制第二份词法器**）**

在 `SourceGuardScanner.swift` 里改 3 处签名 + 1 处行为，**其余一字不动**：

```swift
// ① scanCode 签名加参数（默认 false，既有调用点全部不用改）
func scanCode(_ c: [Character], from start: Int, parenDepth: Int?, into out: inout String,
              keepWhitespace: Bool = false) -> Int {
```

```swift
// ② scanCode 内部的空白处理那一行（原 `if !c[i].isWhitespace { out.append(c[i]) }`）
        if !c[i].isWhitespace { out.append(c[i]) }
        else if keepWhitespace, out.last != " " { out.append(" ") }   // 空白折成**一个空格**，保住 token 边界
```

```swift
// ②b ⚠️ **注释与字符串字面量被剥掉时也必须留下边界**（codex plan-R4-F2）：
//    Swift 里注释本身就是 token 分隔符，`return/*x*/deleteDrawing` 是**合法**代码。
//    只折叠真空白的话它会被压成 `returndeleteDrawing` → 裸标识符判据看到前一个字符是 `n`
//    → 当成「更长标识符的尾巴」跳过 → **vend 漏检，第三层守卫可被绕过**。
//    故：行注释 / 块注释 / 字符串字面量三处 `continue` 之前，各补一次边界。
//    抽成一个小闭包，三处共用（三处各写一遍必然漏掉其中一处）：
        func emitBoundary() { if keepWhitespace, out.last != " " { out.append(" ") } }
//    —— 块注释那段 `while i < c.count, d > 0 { … }` 之后、`continue` 之前：`emitBoundary()`
//    —— 行注释那段 `while i < c.count, c[i] != "\n" { i += 1 }` 之后、`continue` 之前：`emitBoundary()`
//    —— 两处 `i = consumeStringLiteral(...)` 之后、`continue` 之前：`emitBoundary()`
```

```swift
// ③ scanCode 内部两处递归调用要把开关传下去
            if j < c.count, c[j] == "\"" {
                i = consumeStringLiteral(c, from: j, hashes: h, into: &out, keepWhitespace: keepWhitespace); continue
            }
...
        if c[i] == "\"" {
            i = consumeStringLiteral(c, from: i, hashes: 0, into: &out, keepWhitespace: keepWhitespace); continue
        }
```

```swift
// ④ consumeStringLiteral 签名与它内部对 scanCode 的递归调用
func consumeStringLiteral(_ c: [Character], from: Int, hashes: Int, into out: inout String,
                          keepWhitespace: Bool = false) -> Int {
...
                if j < c.count, c[j] == "(" {
                    i = scanCode(c, from: j + 1, parenDepth: 1, into: &out,
                                 keepWhitespace: keepWhitespace); continue
                }
```

- [ ] **Step 4: 加三个新 helper**

追加到 `SourceGuardScanner.swift` 末尾：

```swift
// MARK: 裸标识符引用（方法 vend）扫描 —— PR-4 打开攻击面前必须先关掉的缺口（PR-2 交接③）

/// 与 `squeezedText` **同一个** `scanCode` 循环（剥行注释 / 嵌套块注释 / 字符串字面量内容、
/// 保留插值体），唯一差别是**空白折成一个空格而不是删掉**。
/// ⚠️ 为什么必须有这一版：`squeezedText` 把空白全删了，`return deleteDrawing` 会变成
/// `returndeleteDrawing` —— 裸标识符判据要看「前后是不是标识符字符」，在 squeezed 文本上
/// 这个判据**两个方向都会错**（把 `return` 的 `n` 当成标识符前缀 → 漏掉真 vend）。
func codeTextPreservingBoundaries(_ raw: String) -> String {
    var out = ""
    _ = scanCode(Array(raw), from: 0, parenDepth: nil, into: &out, keepWhitespace: true)
    return out
}

/// 一段（已剥注释/字符串、保留 token 边界的）代码里，`identifier` 以**裸引用**形式出现的次数。
/// 裸引用 = 方法 vend（`{ deleteDrawing }` / `let f = deleteDrawing` / `{ self.deleteDrawing }`），
/// 它把调用挪到了别处：源码里不出现 `deleteDrawing(`，`callSiteCount` 数不到；
/// 而 `filesMentioning` 的白名单对**文件内部**不再细查 → 两层守卫双双放行（PR-2 终审探针 P2 实证）。
///
/// 判据（一次出现算裸引用 ⟺ 三条同时成立）：
///   ① **紧邻**的前一个字符不是标识符字符（否则是更长标识符的尾巴，如 `xdeleteDrawing`）；
///   ② **紧邻**的后一个字符不是标识符字符（否则是更长标识符的头，如 `deleteDrawingForTesting`）；
///   ③ 后面**第一个非空格**字符不是 `(`（那是**声明或调用**，归 `callSiteCount` 那一层管）。
/// 末尾无后继字符 → **按裸引用算**（fail-closed）。
///
/// ⚠️ **①② 看紧邻、③ 跳空格，两者刻意不同**（codex plan-R4-F2 连带暴露）：
///   - ①② 若跳空格：`deleteDrawing Foo` 这两个独立 token 会被当成一个长标识符 → **漏检**；
///   - ③ 若看紧邻：`engine.deleteDrawing/* c */(id: c)` 经边界处理后是 `engine.deleteDrawing (id: c)`，
///     紧邻字符是空格而不是 `(` → 一次**正当调用**被误报成 vend → **假阳性**（既有自检 a 当场红）。
func bareIdentifierReferences(inCode s: String, identifier: String) -> Int {
    let chars = Array(s), idf = Array(identifier)
    func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    var count = 0, i = 0
    while i + idf.count <= chars.count {
        guard Array(chars[i ..< i + idf.count]) == idf else { i += 1; continue }
        let before: Character? = i > 0 ? chars[i - 1] : nil
        let end = i + idf.count
        let after: Character? = end < chars.count ? chars[end] : nil
        i = end
        if let b = before, isIdentChar(b) { continue }        // ①（紧邻）
        guard let a = after else { count += 1; continue }     // 文件末尾 → fail-closed
        if isIdentChar(a) { continue }                        // ②（紧邻）
        var j = end                                            // ③（跳空格再看）
        while j < chars.count, chars[j] == " " { j += 1 }
        if j < chars.count, chars[j] == "(" { continue }
        count += 1
    }
    return count
}

/// 断言 `identifier` 在给定文件集合里**从不**以裸引用（vend）形式出现。
func expectIdentifierNeverVended(_ identifier: String, inFiles files: [String],
                                 sourceLocation: SourceLocation = #_sourceLocation) throws {
    // 自足断言：文件集合为空 → 下面的循环恒真通过，扫描器/白名单写错也测不出来。
    #expect(!files.isEmpty, "\(identifier) 的 vend 守卫拿到空文件集 —— 守卫已失效",
            sourceLocation: sourceLocation)
    for path in files {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let n = bareIdentifierReferences(inCode: codeTextPreservingBoundaries(raw), identifier: identifier)
        #expect(n == 0, "\(path) 里有 \(n) 处 `\(identifier)` 裸引用（方法 vend）—— 会绕过唯一调用点守卫",
                sourceLocation: sourceLocation)
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test 2>&1 | tail -5
```

Expected：`Test run with 1755 tests ... passed`（1752 + 3：自检 g / g2 / g3）。

- [ ] **Step 6: 把新守卫挂进两条既有信任边界测试**

在 `TrainingEngineDrawingSessionTests.swift` 的 `updateDrawingStyleTrustBoundary` 里，`mentions` 那两句 `#expect` **之后**追加：

```swift
        // PR-4：白名单文件**内部**的方法 vend（`{ updateDrawingStyle }`）能绕过上面两层
        // （不出现调用 pattern + 文件本身在白名单里）→ 第三层按「裸标识符」钉死。
        try expectIdentifierNeverVended("updateDrawingStyle", inFiles: mentions)
```

在 `deleteByIdTrustBoundary` 里，`mentions` 那两句 `#expect` **之后**追加：

```swift
        try expectIdentifierNeverVended("deleteDrawing", inFiles: mentions)
```

- [ ] **Step 7: 变异验证（判别力，必须真看红）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
cp Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift /tmp/TE.bak.swift
```
在 `TrainingEngine.swift` 里 `deleteDrawing(id:)` 定义**下面**临时插入一行 vend：
```swift
    func vendForMutationCheck() -> (DrawingID) -> Bool { deleteDrawing }
```
```bash
swift test --filter deleteByIdTrustBoundary 2>&1 | tail -12
```
Expected：**FAIL**，报 `TrainingEngine.swift 里有 1 处 deleteDrawing 裸引用`。
复原（⚠️ **必须用 cp，禁 `git checkout <file>`**——后者会抹掉该文件所有未提交改动，本项目踩过）：
```bash
cp /tmp/TE.bak.swift Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift
swift test --filter deleteByIdTrustBoundary 2>&1 | tail -5
```
Expected：PASS，且 `git diff --stat Sources/` 对该文件为空。

- [ ] **Step 8: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
git add ios/Contracts/Tests/KlineTrainerContractsTests/
git commit -m "划线 P1b-1b-i PR-4 Task1：源码守卫补第三层——白名单文件内部的方法 vend 引用（PR-2 交接③）"
```

---

## Task 2：发布真实渲染视口 + 几何可见提示信号（PD1 / PD2）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift`（本 Task 只放 `selectionGeometryVisible`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift:174-205`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditRouterTests.swift`（新建）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift`（**新建**，Step 6c；Task 4/5/6 只追加）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`（追加，Step 6b）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift`（追加）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewDrawingSessionTests.swift`（追加，**UIKit-gated**）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift`（mutator 清单加两个新名字）

**Interfaces:**
- Produces：`DrawingSession.setViewportMapper(_ m: CoordinateMapper, panel: PanelId)`、`DrawingSession.viewportMapper(for panel: PanelId) -> CoordinateMapper?`、`DrawingSession.selectionGeometryVisible: Bool`（`public private(set)`）、`DrawingSession.setSelectionGeometryVisible(_ v: Bool)`、`DrawingEditRouter.selectionGeometryVisible(engine: TrainingEngine) -> Bool`

- [ ] **Step 1: 写失败测试（host，会话侧）**

追加到 `Drawing/DrawingSessionTests.swift`：

```swift
    @MainActor
    private func fixtureMapper(priceMin: Double = 0, priceMax: Double = 100) -> CoordinateMapper {
        CoordinateMapper(
            viewport: ChartViewport(startIndex: 0, visibleCount: 10, pixelShift: 0,
                                    geometry: ChartGeometry(candleStep: 10, candleWidth: 8, gap: 2),
                                    priceRange: PriceRange(min: priceMin, max: priceMax),
                                    mainChartFrame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            displayScale: 2)
    }

    @Test("PR-4：视口 mapper 按面板隔离存取，未发布过的面板返回 nil（fail-closed）")
    @MainActor func viewportMapperIsPerPanel() {
        let s = DrawingSession()
        #expect(s.viewportMapper(for: .upper) == nil)
        #expect(s.viewportMapper(for: .lower) == nil)
        let m = fixtureMapper()
        s.setViewportMapper(m, panel: .upper)
        #expect(s.viewportMapper(for: .upper) == m)
        #expect(s.viewportMapper(for: .lower) == nil, "写上面板不得污染下面板")
    }

    @Test("PR-4：几何提示随选中生命期走 —— 默认 false；setSelection 置 true（命中即证明可见）；clearSelection 复位")
    @MainActor func geometryHintFollowsSelectionLifetime() {
        let s = DrawingSession()
        #expect(s.selectionGeometryVisible == false)
        s.activate(tool: .horizontal)
        s.setMode(.select)
        s.setSelection(id: "A", panel: .upper)
        #expect(s.selectionGeometryVisible == true,
                "选中只可能来自 hitTest 命中，而 hitTest 内部就是 visibleGeometry != nil —— 命中即证明此刻可见。"
                + "不置 true 的话，验收 #9「单击一条线 → 🗑 从灰变亮」要等一个 runloop 才生效")
        s.clearSelection()
        #expect(s.selectionGeometryVisible == false, "清空选中必须一并复位几何提示，否则 🗑 会对着空选中亮着")
        // 被拒的 setSelection（非选择态 / 空 id）不得留下一个「亮着」的提示
        let t = DrawingSession()
        t.activate(tool: .horizontal)                 // mode == .draw
        t.setSelection(id: "A", panel: .upper)        // fail-closed：画线态不建立选中
        #expect(t.selectedDrawingID == nil)
        #expect(t.selectionGeometryVisible == false, "选中没建立成，提示不许被置亮")
    }
```

新建 `Drawing/DrawingEditRouterTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditRouterTests.swift
// PR-4：写入路由与可用性谓词的 host 测试。
// ⚠️ 本文件**刻意不是** UIKit-gated：`DrawingEditRouter` 只依赖 TrainingEngine / DrawingSession /
//    CoordinateMapper / HorizontalLineTool，全部无 UIKit —— 几何门、确认框时间窗、失败原因 ×
//    选中生命期这些最危险的判据因此能在 host 上拿到真证据，不必赌 Catalyst。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("DrawingEditRouter：可用性谓词与写入路由")
@MainActor
struct DrawingEditRouterTests {

    /// 主图 y ∈ [0,100]、价格区间 [0,100] → 价格 50 落在图中央（可见）；价格 500 落在图外（不可见）。
    private func mapper(priceMin: Double = 0, priceMax: Double = 100) -> CoordinateMapper {
        CoordinateMapper(
            viewport: ChartViewport(startIndex: 0, visibleCount: 10, pixelShift: 0,
                                    geometry: ChartGeometry(candleStep: 10, candleWidth: 8, gap: 2),
                                    priceRange: PriceRange(min: priceMin, max: priceMax),
                                    mainChartFrame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            displayScale: 2)
    }

    /// 造「画线会话已开 + 处于选择态 + 上面板选中一条 .m60 直线（价格 50）+ mapper 已发布」。
    /// upper 面板周期是 .m60（`TrainingEngine.preview()`），线的 period 必须与之一致才进得了 appendDrawing。
    private func makeSelected(price: Double = 50, id: String = "A",
                              lineSubType: LineSubType = .straight,
                              candleIndex: Int = 0) -> TrainingEngine {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: id, lineSubType: lineSubType,
                                                period: e.upperPanel.period,
                                                candleIndex: candleIndex, price: price)) == true)
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: id, panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        return e
    }

    @Test("几何真相：线在图内 → true；价格滑出纵向范围 → false；mapper 未发布 → false（fail-closed）")
    func geometryTruth() {
        let e = makeSelected(price: 50)
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == true)

        // 平移/缩放使价格区间变成 [200,300] → 价格 50 落在图外
        e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == false)

        // 从没发布过 mapper 的会话 → 不许乐观放行
        let fresh = TrainingEngine.preview()
        #expect(fresh.appendDrawing(makeStyledHLine(id: "B", period: fresh.upperPanel.period,
                                                    candleIndex: 0, price: 50)) == true)
        fresh.toggleDrawingMode()
        fresh.drawingSession.setMode(.select)
        fresh.drawingSession.setSelection(id: "B", panel: .upper)
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: fresh) == false,
                "没有视口就判不了几何 —— 必须 fail-closed")
    }

    @Test("几何真相：无选中恒 false（没有对象就没有几何）")
    func geometryFalseWithoutSelection() {
        let e = TrainingEngine.preview()
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == false)
    }

    @Test("几何真相按 selectedPanel 取 mapper：只发布了**另一个**面板的视口 → false")
    func geometryUsesSelectedPanelMapper() {
        let e = makeSelected(price: 50)
        // 上面板选中，却只有下面板有视口 → 判不了 → false
        let s = e.drawingSession
        s.setViewportMapper(mapper(), panel: .lower)
        #expect(s.selectedPanel == .upper)
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == true)   // 上面板的仍在，仍 true
        // 换成「选中下面板、只有上面板发布过」的对照
        let e2 = TrainingEngine.preview()
        #expect(e2.appendDrawing(makeStyledHLine(id: "C", period: e2.lowerPanel.period,
                                                 panelPosition: 1, candleIndex: 0, price: 50)) == true)
        e2.toggleDrawingMode()
        e2.drawingSession.setMode(.select)
        e2.drawingSession.setSelection(id: "C", panel: .lower)
        e2.drawingSession.setViewportMapper(mapper(), panel: .upper)      // 只发布上面板
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e2) == false,
                "取错面板的 mapper 会让下面板的线用上面板的坐标系判可见性")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test 2>&1 | tail -20
```

Expected：编译失败 —— `value of type 'DrawingSession' has no member 'setViewportMapper'` / `cannot find 'DrawingEditRouter' in scope`。

- [ ] **Step 3: `DrawingSession` 加视口 mapper 与几何提示**

在 `DrawingSession.swift` 的 `selectedPanel` 声明**之后**、`setSelection` 之前插入：

```swift
    /// PR-4（PD1）：某面板**最近一次真实渲染所用**的坐标映射器，由
    /// `ChartContainerView.Coordinator.rebuildRenderState` 在写完 `view.renderState` 后发布。
    /// **必须是渲染真的用过的那一个**，不能在别处重新推导：`RenderStateBuilder.make` 在
    /// 「最后一根可见 K 线是进行中聚合」时会重算 `priceRange`，重推出来的视口与屏幕上的不一致
    /// → 几何门与渲染/命中分叉（正是 D40 要消灭的那类缺陷）。
    /// `@ObservationIgnored` 是 **load-bearing**：平移/惯性期间每帧都写，若参与 observation 会在
    /// `updateUIView` 里造成 写 → 失效 → 再 `updateUIView` 的循环（`TrainingEngine.swift:70` 同一条陷阱）。
    @ObservationIgnored private var viewportMappers: [Int: CoordinateMapper] = [:]

    func setViewportMapper(_ m: CoordinateMapper, panel: PanelId) {
        viewportMappers[panel == .upper ? 0 : 1] = m
    }

    func viewportMapper(for panel: PanelId) -> CoordinateMapper? {
        viewportMappers[panel == .upper ? 0 : 1]
    }

    /// PR-4（PD2）：选中线此刻在它所属面板上**几何可见**吗。
    /// ⚠️ **这是给置灰用的提示，不是门。** 真正的门是 `DrawingEditRouter` 在**写入那一刻**
    /// 用 `viewportMapper(for:)` 现算的那次 `visibleGeometry`（D65 R13-F1：确认框有时间窗，
    /// 只在点 🗑 那一刻判几何是时序 bug）。本标志短暂陈旧最坏只是控件亮/灰晚一帧，
    /// **写入永远不会因此放行**。
    /// 观察语义：**值没变就不写**——`@Observable` 的 setter 无条件通知，每帧无条件写会造成
    /// 「写 → SwiftUI 失效 → 再 update → 再写」的循环。
    public private(set) var selectionGeometryVisible: Bool = false

    func setSelectionGeometryVisible(_ v: Bool) {
        guard selectionGeometryVisible != v else { return }
        selectionGeometryVisible = v
    }
```

在 `setSelection(id:panel:)` 体内、两句赋值**之后**追加一行（**必须在 guard 之后**——被拒的选中不得留下亮着的提示）：

```swift
        selectionGeometryVisible = true            // 命中即证明此刻几何可见（hitTest 内部就是 visibleGeometry != nil，D40）
```

在 `clearSelection()` 体内追加一行（在两句清空**之后**）：

```swift
        selectionGeometryVisible = false           // 没有选中就没有可操作对象（🗑 与样式控件一并回灰）
```

⚠️ `DrawingSession.swift` 顶部已 `import CoreGraphics`，`CoordinateMapper` 在同 module 的 `Geometry/Geometry.swift`，**不需要新 import**。

- [ ] **Step 4: 新建 `DrawingEditRouter.swift`（本 Task 只放几何真相）**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift
// PR-4（1b-i 切片4）：选中对象的**唯一**写入路由 + D65 两个可用性谓词。
//
// 为什么单独一个类型而不是塞进 View：
//   ① D62/D51 要求 `updateDrawingStyle` / `deleteDrawing(id:)` 在 `Sources/` 里**恰好一个**调用点，
//      且那一处必须已先验 `visibleGeometry`；把它固定在一个无 UIKit 的类型里，源码守卫的白名单
//      就只需放行一个文件，SwiftUI 那边加多少控件都不会再开新的写入口。
//   ② 无 UIKit ⇒ host `swift test` 就能跑——几何门 / 确认框时间窗 / 失败原因 × 选中生命期
//      这些最危险的判据不必赌 Catalyst 才有证据。
// 本类型**不持有任何状态**：所有输入都从 engine / session 现读，所有判据都是纯函数。
import CoreGraphics

@MainActor
enum DrawingEditRouter {

    /// 选中线此刻在 `selectedPanel` 上几何可见吗（D63 的「几何性可见」维度）。
    /// 判据**复用** `HorizontalLineTool.visibleGeometry`（与渲染 / 命中 / 标注同一个实现，D40），
    /// 视口取 `session.viewportMapper(for: selectedPanel)` —— 即那个面板**真实渲染用过**的视口。
    /// 任何一环缺失（无选中 / 无视口 / 线已不在 `drawings`）一律 **false（fail-closed）**：
    /// 判不了就不许动，绝不乐观放行。
    /// 当前选中的那条线（不存在 / 不唯一 / **不在渲染可见集合里** → nil，D66：绝不"取第一条碰到的"）。
    ///
    /// ⚠️ **必须从 `RenderStateBuilder.visibleDrawings` 里取，不能从 `engine.drawings` 里取**
    /// （codex plan-R5-F1）：后者只是全局数组，**不含** D40 那三条判据——review 叠加层 /
    /// `belongsToPanel`（D29 周期归属 + 同周期 fail-safe）/ `revealTick <= tick` 渐显。
    /// 只按 id 从全局数组捞，等于把 D63 的**结构性**可见维度整个略过，只重算了几何那一半：
    /// 一条**渲染不出、也命不中**的线（迁到了另一面板 / 渐显未到），只要价位恰好映进
    /// `selectedPanel` 就能通过几何检查 → **可被改样式、可被不可逆删除**。
    /// 「结构性不可见时选中会被别处清掉」是靠**事件**（切周期善后）保证的，而 D64 的全部论点就是
    /// **能从状态算出来的就不要靠事件传递**——我对「存在性」维度守了这条纪律，这里必须一并守。
    /// `visibleDrawings` **没有 mapper**、只判结构 → 几何性不可见的线**仍在**集合里（D63 分流照旧：
    /// 保留选中、面板照常回显、只是控件灰），不会把 D63 退化成「一平移就丢选中」。
    private static func uniqueSelected(engine: TrainingEngine) -> DrawingObject? {
        guard let id = engine.drawingSession.selectedDrawingID, !id.isEmpty,
              let panel = engine.drawingSession.selectedPanel else { return nil }
        let visible = RenderStateBuilder.visibleDrawings(
            engine: engine, panel: panel, tick: engine.tick.globalTickIndex)
        let matches = visible.filter { $0.id == id }
        return matches.count == 1 ? matches.first : nil
    }

    /// ⚠️ 目标对象**经 `uniqueSelected` 取**（见其头注，codex plan-R5-F1）—— 那里已经把
    /// 「结构性可见」（`visibleDrawings` 的三条判据）挡在前面；本函数只负责**几何**那一层。
    /// 两层叠起来才等于「屏幕上真的看得见这条线」。
    static func selectionGeometryVisible(engine: TrainingEngine) -> Bool {
        let session = engine.drawingSession
        guard let panel = session.selectedPanel,
              let mapper = session.viewportMapper(for: panel),
              let drawing = uniqueSelected(engine: engine) else { return false }
        return HorizontalLineTool.visibleGeometry(for: drawing, mapper: mapper) != nil
    }
}
```

- [ ] **Step 5: 跑 host 测试确认通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test 2>&1 | tail -5
```

Expected：`Test run with 1760 tests ... passed`（1755 + 本 Step 前新增的 5 条：会话侧 2 + 路由几何 3）。
⚠️ 本 Task 走完全部 Step 后还会再加 2 条（Step 6b 的 `renderedViewportDivergesFromReDerivation` + Step 6c 的 `publisherUsesRenderedViewportOnly`）→ **Task 2 收尾时应为 1762**（1755 + 7）。数字对不上就停下报告（别硬改，基线错了后面每个 Task 的对账都是假的）。

- [ ] **Step 6: Coordinator 发布 mapper + 延后刷新提示（UIKit 侧）**

在 `ChartContainerView.swift` 的 `rebuildRenderState` 里，把末行 `view.renderState = newState` 之后补上：

```swift
            view.renderState = newState
            // PR-4（PD1/PD2）：发布**这一帧真的用过**的视口 —— SwiftUI 层（🗑 / 样式面板）没有 mapper，
            // 而重新推导会与 `make` 的聚合分支（重算 priceRange）分叉。
            let session = engine.drawingSession
            session.setViewportMapper(
                CoordinateMapper(viewport: newState.viewport,
                                 displayScale: view.traitCollection.displayScale), panel: panel)
            // 置灰提示：只有**选中所在的那个面板**负责刷新（另一个面板的视口与它无关），
            // 且只在值**真的会变**时才派发（平移每帧都派发 = 无谓开销）。
            // ⚠️ **必须延后一个 runloop**：本函数的调用点之一是 `updateUIView`（视图更新期），
            //    期间改 @Observable 是 SwiftUI 明令的未定义行为；`:105` 释放 crosshairOwner 用的是
            //    同一条逃生门。提示晚一拍无害——真正的门是路由在写入瞬刻的那次重算（PD2）。
            if session.selectedPanel == panel,
               DrawingEditRouter.selectionGeometryVisible(engine: engine) != session.selectionGeometryVisible {
                DispatchQueue.main.async { [weak engine] in
                    guard let engine else { return }
                    // 在**执行时**重算，不用捕获的旧值（期间状态可能又变了）。
                    engine.drawingSession.setSelectionGeometryVisible(
                        DrawingEditRouter.selectionGeometryVisible(engine: engine))
                }
            }
```

- [ ] **Step 6b: 把 PD1 的前提钉成 host 上可机械检查的事实（codex plan-R3-F2）**

> ⚠️ **codex 抓到的真问题**：`makeRig()` 用的 `TrainingEngine.preview()` 里**每一根 K 线都是 `high:11 / low:9`**
> （`TrainingEngine.swift:1417` 实测）→ 聚合分支即使触发，合成出来的 partial 与原 aggregate 的 high/low **相同**
> → `priceRange` 不变 → `make(...).viewport == makeViewport(...)`。
> 于是 Task 7 那条「把 `newState.viewport` 换成 `makeViewport(...)`」的变异**在这个 rig 上杀不死**，
> Catalyst 那条相等断言并不能证明 PD1 声称的分叉。**PD1 的前提必须自己有测试**，否则它只是一段源码阅读结论。

先在 `Render/RenderStateBuilderTests.swift` 追加一条 **host** 测试（两个函数都是纯函数，不需要 UIKit）：

```swift
    @Test("PD1 前提（codex plan-R3-F2）：进行中聚合会让 make 的视口与 makeViewport 重推的**真的不同** —— 这就是「不许在别处重新推导」的理由")
    @MainActor func renderedViewportDivergesFromReDerivation() {
        // 构造要点（缺一条分叉就出不来）：
        //   ① 面板周期是**聚合**周期（.m60），其当前那根 aggregate 的 endGlobalIndex > tick（还没走完）；
        //   ② 该 aggregate 自报一个**宽**区间（high 30 / low 1），而它已揭示的 m3 前缀是**窄**的（high 11 / low 9）
        //      → 合成 partial 后 PriceRange 必然不同（`PriceRange.calculate` 的 ×0.95/×1.05 不会把差异抹平）；
        //   ③ 可见 slice 的最后一根就是当前那根（preview 的 reveal 钳位天然满足）。
        let e = makeAggregateDivergenceEngine()          // 见下方 helper
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        let panelState = e.upperPanel
        let candles = e.allCandles[panelState.period] ?? []
        let reDerived = RenderStateBuilder.makeViewport(
            panelState: panelState, candles: candles, tick: e.tick.globalTickIndex, bounds: bounds)
        let rendered = RenderStateBuilder.make(engine: e, panel: .upper, bounds: bounds).viewport

        // 前提自足断言：先证明两者都是**有效**视口（都退化成 .empty 的话下面的不等式毫无意义）
        #expect(rendered.geometry.candleStep > 0, "rendered 视口退化了，本测试无判别力")
        #expect(reDerived.geometry.candleStep > 0, "reDerived 视口退化了，本测试无判别力")
        // 结论：两者**必须**不同，且差异就在 priceRange 上
        #expect(rendered.priceRange != reDerived.priceRange,
                "聚合分支没造出分叉 —— fixture 不满足①②③，**停下报告**："
                + "要么修 fixture，要么 PD1「重新推导会分叉」的前提不成立、须重新评估整个设计")
        #expect(rendered != reDerived)
    }
```

helper（放同文件底部；`allCandles` 形状照抄 `TrainingEngine.previewCandles()`，只把 aggregate 的 high/low 撑宽）：

```swift
    /// 造一个「当前 aggregate 自报宽区间、已揭示 m3 前缀是窄区间」的引擎 —— 聚合分支一触发，
    /// 合成 partial 的 PriceRange 就与直接用 aggregate 的不同。
    @MainActor
    private func makeAggregateDivergenceEngine() -> TrainingEngine {
        func candle(_ p: Period, start: Int, end: Int, high: Double, low: Double) -> KLineCandle {
            KLineCandle(period: p, datetime: Int64(start) * 3600,
                        open: 10, high: high, low: low, close: 10,
                        volume: 1000, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: start, endGlobalIndex: end)
        }
        let m3 = (0..<8).map { candle(.m3, start: $0, end: $0, high: 11, low: 9) }      // 窄
        let m60 = [candle(.m60, start: 0, end: 3, high: 30, low: 1),                    // 宽（未走完）
                   candle(.m60, start: 4, end: 7, high: 30, low: 1)]
        return TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: 7),
            allCandles: [.m3: m3, .m60: m60],
            maxTick: 7, initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m60, initialLowerPeriod: .m60)
    }
```

⚠️ **`TrainingEngine` 的内部 `init` 参数以 `DrawingTestFixtures.makeEngineWithLossy`（`:46-51`）为准**——
上面这份是照它删掉 `initialDrawingsLossy` 写的，签名若对不上就照那一处补齐，**不要新造 init**。
⚠️ **本 Step 单独跑一次再往下走**：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test --filter renderedViewportDivergesFromReDerivation 2>&1 | tail -20
```
Expected：**跑了 1 条且 PASS**。若报「聚合分支没造出分叉」→ **停下报告**（fixture 不对，或 PD1 前提不成立）；
若跑了 0 条 → filter 没匹配上，**别当通过**（本仓踩过「0 个测试却报 SUCCEEDED」）。

- [ ] **Step 6c: 源码守卫 —— 发布的必须是渲染真用过的那个视口（确定能杀死 Task 7 变异 #2）**

⚠️ **本 Step 要 `Render/DrawingInteractionUISourceGuardTests.swift` 这个文件，它由本 Step 创建**
（codex plan-R4-F1：初稿把它排在 Task 4 才建，Task 2 却先往里追加 → 要么编译失败、要么守卫被静默丢掉，
而这条守卫正是「不许发布重推视口」的确定性防线）。**新建**该文件，写入文件头 + 两个共享 helper + 本条守卫；
Task 4/5/6 只往里**追加**：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift
// PR-4：交互 UI 与视口发布的接线守卫。**刻意不是 UIKit-gated** —— 它读源码文本，不需要 UIKit 渲染，
// 放 host 才能在每个 Task 里立刻拿到证据（View 的真实渲染断言另有 Catalyst 测试）。
// 文本来源纪律见计划 PD7：否定/结构断言走 `code()`（剥注释剥字面量），用户可见文案走 `raw()`。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("PR-4 交互 UI 接线守卫")
struct DrawingInteractionUISourceGuardTests {

    /// **剥注释、剥字符串字面量内容、删空白**的代码文本。**所有否定断言与结构断言都必须用它**
    /// （PD7）：读原始文本会被计划里那些「为什么不是 X」的承重注释打红，逼实施者删注释才能过测试。
    private func code(_ rel: String) throws -> String {
        try squeezedSource(contractsDirForGuards.appendingPathComponent(rel).path)
    }

    /// 原始文本。**只用于两件事**：① 用户可见文案（`squeezedSource` 会丢弃字符串字面量内容，
    /// 文案断言在它上面恒假）；② 「陈旧注释必须删掉」这类**对象就是注释**的断言。
    private func raw(_ rel: String) throws -> String {
        try String(contentsOfFile: contractsDirForGuards.appendingPathComponent(rel).path, encoding: .utf8)
    }

    @Test("PD1（codex plan-R3-F2 的确定性防线）：Coordinator 发布的是 `newState.viewport`，且它**不许**自己重推视口")
    func publisherUsesRenderedViewportOnly() throws {
        let cc = try code("Sources/KlineTrainerContracts/Render/ChartContainerView.swift")
        #expect(cc.contains(squeeze("CoordinateMapper(viewport: newState.viewport,")),
                "必须发布这一帧渲染真用过的视口")
        // 重推的入口一次都不许在本文件的**代码**里出现（注释里解释「为什么不重推」是正当的，故剥注释后判）
        #expect(!cc.contains("makeViewport"),
                "ChartContainerView 里出现了 makeViewport —— 重推的视口在聚合分支下与屏幕上的不一致（见 renderedViewportDivergesFromReDerivation）")
    }
}
```

⚠️ Task 4/5/6 往本文件追加测试时，都是插在**最后那个 `}` 之前**，不要重复写文件头与两个 helper。

- [ ] **Step 7: 写 Catalyst 测试（Coordinator 真发布）**

追加到 `Render/ChartContainerViewDrawingSessionTests.swift`：

```swift
    @Test("PR-4：rebuildRenderState 发布的是**这一帧渲染真用过**的视口（与 view.renderState.viewport 逐字相等）")
    func coordinatorPublishesRenderedViewport() {
        let (engine, upperC, lowerC, upperV, lowerV) = makeRig()
        let published = try! #require(engine.drawingSession.viewportMapper(for: .upper))
        #expect(published.viewport == upperV.renderState.viewport,
                "发布的视口与真实渲染态不一致 —— 几何门会与屏幕上看到的分叉")
        #expect(published.displayScale == upperV.traitCollection.displayScale)
        // 两个面板各自发布、互不覆盖
        let lower = try! #require(engine.drawingSession.viewportMapper(for: .lower))
        #expect(lower.viewport == lowerV.renderState.viewport)
        _ = (upperC, lowerC)
    }

    @Test("PR-4（codex plan-R1-F2 专项）：几何提示由 **Coordinator 真实路径**刷新 —— 选中一条价位远在视口外的线 → 提示转 false")
    func coordinatorRefreshesGeometryHint() async throws {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        upperC.handleDrawingTapForTesting(at: mainChartPoint(upperV))     // 画一条**可见**的
        let visibleID = try #require(engine.drawings.last?.id)
        // 再注入一条价位远在视口外的（用注入而非画，因为画不出一条自己看不见的线）
        engine.injectDrawingsForTesting(engine.drawings + [
            makeStyledHLine(id: "FAR", period: engine.upperPanel.period,
                            candleIndex: 0, price: 1_000_000)])
        engine.drawingSession.setMode(.select)

        engine.drawingSession.setSelection(id: visibleID, panel: .upper)
        upperC.rebuildRenderState(bounds: bounds)
        await drainMainQueue()
        #expect(engine.drawingSession.selectionGeometryVisible == true)

        engine.drawingSession.setSelection(id: "FAR", panel: .upper)
        upperC.rebuildRenderState(bounds: bounds)
        await drainMainQueue()
        #expect(engine.drawingSession.selectionGeometryVisible == false,
                "Coordinator 没有按真实视口把提示改回来 —— 平移到线看不见时控件不会变灰（验收 #18c）")
    }
```

并在本 Suite 里加一个排空 helper（**不要用固定时长 sleep 赌时序**）：

```swift
    /// 排空 main queue：`rebuildRenderState` 用 `DispatchQueue.main.async` 延后写提示
    /// （视图更新期不得改 @Observable），必须等那一跳真的执行完再断言。
    private func drainMainQueue() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }
```

- [ ] **Step 8: 更新 `DrawingSessionSourceGuardTests` 的 mutator 清单**

在 `codex plan-R5-high：DrawingSession 的 mutator 一个都不许是 public` 那条测试的 mutator 名字数组里，追加两项：

```swift
            "func setViewportMapper(", "func setSelectionGeometryVisible(",
```

- [ ] **Step 9: 跑 host + 变异验证**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test 2>&1 | tail -5
```
Expected：`1760 passed`（Catalyst 那两条 host 不编译）。

变异（host 可验的那条）：把 `DrawingEditRouter.selectionGeometryVisible` 的 `guard let mapper = …` 改成 `let mapper = session.viewportMapper(for: panel) ?? CoordinateMapper(viewport: .init(startIndex: 0, visibleCount: 0, pixelShift: 0, geometry: .init(candleStep: 0, candleWidth: 0, gap: 0), priceRange: .init(min: 0, max: 1), mainChartFrame: .zero))`（= 乐观放行）→
```bash
swift test --filter geometryTruth 2>&1 | tail -10
```
Expected：**FAIL**（`没有视口就判不了几何` 那条）。用 `cp` 复原后重跑确认 PASS。

- [ ] **Step 10: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
git add ios/Contracts/
git commit -m "划线 P1b-1b-i PR-4 Task2：发布真实渲染视口 + 几何可见提示（SwiftUI 层第一次拿得到几何真相）"
```

---

## Task 3：写入路由与两个可用性谓词（D49 / D58 / D64 / D65）+ 守卫 0 → 1

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditRouterTests.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`（N15 / N19a：零调用点 → 恰好 1 处、白名单加路由文件）

**Interfaces:**
- Consumes：Task 2 的 `DrawingEditRouter.selectionGeometryVisible(engine:)` / `DrawingSession.viewportMapper(for:)`
- Produces：`DrawingEditRouter.canEditStyle(engine:) -> Bool`、`.canDelete(engine:) -> Bool`（现算，路由用）、`.styleControlsEnabled(engine:) -> Bool`、`.deleteButtonEnabled(engine:) -> Bool`（读提示，UI 用）、`.panelStyle(engine:) -> DrawingDefaultStyle`、`.applyStyle(_ style: DrawingDefaultStyle, engine:) -> Bool`、`.deleteSelected(engine:) -> Bool`

- [ ] **Step 1: 写失败测试（host，一次写全 N 系列）**

追加到 `Drawing/DrawingEditRouterTests.swift`（沿用 Step 1 已定义的 `mapper()` / `makeSelected()`）：

```swift
    // ============ D65 两个谓词 ============

    @Test("N18a/N16b（D65）：几何不可见 → 改样式与删除**同进同退**全部不可用")
    func bothPredicatesFollowGeometry() {
        let e = makeSelected(price: 50)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == true)
        #expect(DrawingEditRouter.canDelete(engine: e) == true)
        e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false)
        #expect(DrawingEditRouter.canDelete(engine: e) == false)
    }

    @Test("N18c（防做成永久禁用）：滑回来两个谓词自动恢复，且此时改样式真能成功、revision +1")
    func predicatesRecover() {
        let e = makeSelected(price: 50)
        e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        #expect(DrawingEditRouter.canDelete(engine: e) == false)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)               // 滑回来
        #expect(DrawingEditRouter.canEditStyle(engine: e) == true)
        #expect(DrawingEditRouter.canDelete(engine: e) == true)
        let rev = e.drawingsRevision
        var s = DrawingEditRouter.panelStyle(engine: e); s.thickness = 4
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == true)
        #expect(e.drawings[0].thickness == 4)
        #expect(e.drawingsRevision == rev + 1)
    }

    @Test("N18b（D60）：locked 线两个谓词都假、写入被拒、选中原样保留")
    func lockedDisablesBoth() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "L", locked: true, period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "L", panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false)
        #expect(DrawingEditRouter.canDelete(engine: e) == false)
        let rev = e.drawingsRevision
        var s = DrawingEditRouter.panelStyle(engine: e); s.thickness = 5
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == false)
        #expect(DrawingEditRouter.deleteSelected(engine: e) == false)
        #expect(e.drawings.count == 1)
        #expect(e.drawings[0].thickness == 1)
        #expect(e.drawingsRevision == rev)
        #expect(e.drawingSession.selectedDrawingID == "L", "上游 §7.2：锁定线仍可被选中（否则无法解锁）")
    }

    @Test("N14d（D65 分岔）：携带未来枚举值的线 —— 样式控件灰、🗑 亮，删除真能成功")
    func futureEnumLineSplitsPredicates() throws {
        let e = try engineWithFutureEnumLine(id: "F")
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false, "未来枚举值线改不动样式（D61）")
        #expect(DrawingEditRouter.canDelete(engine: e) == true, "但删整条允许（不产生部分抹除）")
        #expect(DrawingEditRouter.deleteSelected(engine: e) == true)
        #expect(e.drawings.isEmpty)
    }

    @Test("N16a 同族（codex plan-R5-F1 专项，不可省）：**结构性**不可见的线一律判死 —— 渐显未到 / 归属另一面板")
    func structurallyInvisibleIsAlwaysGated() {
        // ① revealTick > tick：线在 drawings 里、价位也映得进视口，但**渲染不出、也命不中**
        let e = TrainingEngine.preview()
        let far = makeStyledHLine(id: "R", period: e.upperPanel.period, candleIndex: 0, price: 50)
        // makeStyledHLine 默认 revealTick: 7 —— 先确认它确实还没到（前提自足断言）
        #expect(far.revealTick > e.tick.globalTickIndex, "fixture 前提不成立：渐显已到，本测试无判别力")
        e.injectDrawingsForTesting([far])
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "R", panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(RenderStateBuilder.visibleDrawings(engine: e, panel: .upper,
                                                   tick: e.tick.globalTickIndex).isEmpty,
                "前提：这条线确实不在渲染/命中集合里")
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == false,
                "只按 id 从 engine.drawings 捞就会漏掉 revealTick —— 用户看不见的线不许过门")
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false)
        #expect(DrawingEditRouter.canDelete(engine: e) == false)
        let rev = e.drawingsRevision
        var s = DrawingEditRouter.panelStyle(engine: e); s.thickness = 5
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == false)
        #expect(DrawingEditRouter.deleteSelected(engine: e) == false)
        #expect(e.drawings.count == 1, "被拒必须零改动 —— 不可逆删除尤其不能漏过去")
        #expect(e.drawingsRevision == rev)

        // ② 陈旧的 selectedPanel：线归属**下**面板（period == lowerPanel.period），选中却记着上面板
        let e2 = TrainingEngine.preview()
        #expect(e2.upperPanel.period != e2.lowerPanel.period, "前提：两面板周期不同，belongsToPanel 才按 period 判")
        #expect(e2.appendDrawing(makeStyledHLine(id: "L", period: e2.lowerPanel.period,
                                                 panelPosition: 1, candleIndex: 0, price: 50)) == true)
        e2.toggleDrawingMode(); e2.drawingSession.setMode(.select)
        e2.drawingSession.setSelection(id: "L", panel: .upper)      // 陈旧二元组：id 属下面板、panel 记着上
        e2.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(DrawingEditRouter.canEditStyle(engine: e2) == false,
                "按 selectedPanel 取渲染集合就自动判死；只按 id 捞则会拿另一面板的线去过上面板的几何")
        #expect(DrawingEditRouter.canDelete(engine: e2) == false)
        #expect(DrawingEditRouter.deleteSelected(engine: e2) == false)
        #expect(e2.drawings.count == 1)
    }

    @Test("D63 不回归（防 R5 修复过头）：**几何性**不可见仍留在结构集合里 —— 选中不抖、面板照常回显")
    func geometricallyInvisibleStaysStructurallyPresent() {
        let e = makeSelected(price: 50)
        e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        #expect(DrawingEditRouter.selectionGeometryVisible(engine: e) == false)   // 几何判死
        #expect(e.drawingSession.selectedDrawingID == "A", "选中不许被几何不可见抖掉（D63 的全部价值）")
        // 面板仍回显那条线的真实样式（N18d：看得见、改不动）
        #expect(DrawingEditRouter.panelStyle(engine: e).thickness == e.drawings[0].thickness)
        #expect(DrawingEditRouter.panelStyle(engine: e).colorToken == e.drawings[0].colorToken)
    }

    @Test("PD2b（codex plan-R1-F1 专项，不可省）：**无选中**时样式控件仍可用（改「下一条线的默认」），但 🗑 恒灰")
    func noSelectionKeepsStyleControlsUsable() {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        #expect(e.drawingSession.selectedDrawingID == nil)
        #expect(DrawingEditRouter.styleControlsEnabled(engine: e) == true,
                "无选中时面板在改默认样式 —— 灰掉它就把 1a-iii 的能力回归掉了（验收 #13）")
        #expect(DrawingEditRouter.deleteButtonEnabled(engine: e) == false, "无选中时 🗑 恒灰（spec §1.1 #1）")
        // 反向对照：选中一条**看不见**的线 → 样式控件才该灰（证明上面的 true 不是「一律放行」骗过来的）
        let e2 = makeSelected(price: 50)
        e2.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        e2.drawingSession.setSelectionGeometryVisible(false)          // 模拟 Coordinator 刷新后的提示
        #expect(DrawingEditRouter.styleControlsEnabled(engine: e2) == false)
        #expect(DrawingEditRouter.deleteButtonEnabled(engine: e2) == false)
    }

    @Test("PD2（codex plan-R1-F2 专项，不可省）：UI 谓词读 observable 提示、路由谓词现算 —— 提示陈旧时两者必须分岔")
    func displayReadsHintWhileRouteRecomputes() {
        let e = makeSelected(price: 50)
        #expect(e.drawingSession.selectionGeometryVisible == true)     // setSelection 置的
        // 制造「提示还没被 Coordinator 刷新」的那一帧：视口已经变了，提示仍是旧值
        e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        #expect(e.drawingSession.selectionGeometryVisible == true, "前提：提示此刻是陈旧的")
        #expect(DrawingEditRouter.deleteButtonEnabled(engine: e) == true,
                "UI 读提示 —— 这一帧它还亮着，这是可接受的一帧延迟")
        #expect(DrawingEditRouter.canDelete(engine: e) == false,
                "路由现算 —— 必须已经判死；若这里也是 true，说明路由读了提示，陈旧值会放行真删除")
        #expect(DrawingEditRouter.deleteSelected(engine: e) == false, "门在路由那一侧：写入必须被拦住")
        #expect(e.drawings.count == 1)
    }

    @Test("PR-2 交接②：谓词必须包含引擎那三道 spec D65 字面没写的门（否则控件亮着点了没反应）")
    func predicateCoversExtraEngineGates() {
        // ②b 工具已实现：`.trend` 是已知枚举 case，raw-aware 门看不见它，只有 isEditableToolType 挡得住
        let e = TrainingEngine.preview()
        let trend = DrawingObject(id: "T", toolType: .trend,
                                  anchors: [DrawingAnchor(period: e.upperPanel.period,
                                                          candleIndex: 0, price: 50)],
                                  isExtended: false, panelPosition: 0, revealTick: 0,
                                  period: e.upperPanel.period)
        e.injectDrawingsForTesting([trend])
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "T", panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(DrawingStyleAvailability.isEditableToolType(.trend) == false)   // 前提坐实
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false,
                "本构建不懂 .trend 的样式语义，控件必须灰 —— 否则会拿横线假设改写它")
    }

    // ============ D58 候选预检 ============

    @Test("N12b：把可见的 .straight 改成锚点在右缘外的 .ray → 拒、线逐字段不变、revision 不动、选中仍在")
    func candidatePrecheckRejectsInvisibleRay() {
        // candleIndex 40 在 visibleCount=10 的视口里，indexToX = 400 ≥ mainChartFrame.maxX(100)
        let e = makeSelected(price: 50, candleIndex: 40)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == true, "改之前它是可见的 .straight（全宽）")
        let before = e.drawings[0], rev = e.drawingsRevision
        var s = DrawingEditRouter.panelStyle(engine: e); s.lineSubType = .ray
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == false)
        #expect(e.drawings[0] == before)
        #expect(e.drawings[0].lineSubType == .straight)
        #expect(e.drawings[0].isExtended == false)
        #expect(e.drawingsRevision == rev)
        #expect(e.drawingSession.selectedDrawingID == "A", "用户不该因为这次拒绝失去对它的控制")
    }

    @Test("N12c 反向对照（防一律拒绝改 lineSubType）：锚点在图内 → 改 .ray 成功、isExtended 真、revision +1")
    func candidatePrecheckAllowsVisibleRay() {
        let e = makeSelected(price: 50, candleIndex: 0)
        let rev = e.drawingsRevision
        var s = DrawingEditRouter.panelStyle(engine: e); s.lineSubType = .ray
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == true)
        #expect(e.drawings[0].lineSubType == .ray)
        #expect(e.drawings[0].isExtended == true)
        #expect(e.drawingsRevision == rev + 1)
    }

    @Test("候选预检只对 lineSubType：只改粗细时不得因为「改完还看不看得见」再判一次（不引入无谓视口依赖）")
    func precheckOnlyForSubType() {
        // 一条 .ray、锚点在右缘外 → 当前就不可见 → 当前门先挡下（根本走不到候选预检）
        let e = makeSelected(price: 50, lineSubType: .ray, candleIndex: 40)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false)
        var s = DrawingEditRouter.panelStyle(engine: e); s.thickness = 3
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == false, "看不见的东西一律不许改（D65），不是候选预检的功劳")
        #expect(e.drawings[0].thickness == 1)
    }

    // ============ D49 派生回显 ============

    @Test("N1（D49）：面板样式是派生值 —— 有选中显示那条线的、改动只作用于它、defaultStyle 逐字段不变；取消选中回默认")
    func panelStyleIsDerived() {
        let e = TrainingEngine.preview()
        var defaults = DrawingDefaultStyle()
        defaults.lineSubType = .straight; defaults.lineStyle = .dash2
        defaults.thickness = 3; defaults.colorToken = .blue; defaults.labelMode = .right
        e.drawingSession.setDefaultStyle(defaults)
        #expect(e.appendDrawing(makeStyledHLine(id: "A", lineStyle: .solid, thickness: 1,
                                                colorToken: .orange, labelMode: .hidden,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "A", panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)

        // 选中 → 派生值 == 那条线（逐字段）
        let shown = DrawingEditRouter.panelStyle(engine: e)
        #expect(shown.lineSubType == .straight); #expect(shown.lineStyle == .solid)
        #expect(shown.thickness == 1); #expect(shown.colorToken == .orange)
        #expect(shown.labelMode == .hidden)

        // 改成 C → 线变成 C、defaultStyle 逐字段仍是 A
        var c = shown; c.colorToken = .green; c.thickness = 5
        #expect(DrawingEditRouter.applyStyle(c, engine: e) == true)
        #expect(e.drawings[0].colorToken == .green); #expect(e.drawings[0].thickness == 5)
        #expect(e.drawingSession.defaultStyle == defaults, "改选中线不得污染「下一条线的默认」")

        // 取消选中 → 派生值回到默认
        e.drawingSession.clearSelection()
        #expect(DrawingEditRouter.panelStyle(engine: e) == defaults)
    }

    // ============ D64 存在性谓词 ============

    @Test("N17（D64）：id 不存在 → 清空选中；locked / 语义不成立 / 未来枚举 / 预检拒 → 选中保留；删除成功 → 清空")
    func selectionLifetimeByExistenceOnly() throws {
        // ① id 不存在（被别的路径移除后再调路由）
        let e1 = makeSelected()
        e1.injectDrawingsForTesting([])                                  // 绕过路由直接移除
        #expect(DrawingEditRouter.deleteSelected(engine: e1) == false)
        #expect(e1.drawingSession.selectedDrawingID == nil, "线真没了 → 清空")

        // ② 语义不成立（直接传 .segment，绕开面板）
        let e2 = makeSelected()
        var seg = DrawingEditRouter.panelStyle(engine: e2); seg.lineSubType = .segment
        #expect(DrawingEditRouter.applyStyle(seg, engine: e2) == false)
        #expect(e2.drawingSession.selectedDrawingID == "A", "线还在 → 保留")

        // ③ 未来枚举值
        let e3 = try engineWithFutureEnumLine(id: "F")
        e3.drawingSession.setViewportMapper(mapper(), panel: .upper)
        var s3 = DrawingEditRouter.panelStyle(engine: e3); s3.thickness = 4
        #expect(DrawingEditRouter.applyStyle(s3, engine: e3) == false)
        #expect(e3.drawingSession.selectedDrawingID == "F")

        // ④ UI 预检拒（引擎根本没被调用）
        let e4 = makeSelected(candleIndex: 40)
        var s4 = DrawingEditRouter.panelStyle(engine: e4); s4.lineSubType = .ray
        #expect(DrawingEditRouter.applyStyle(s4, engine: e4) == false)
        #expect(e4.drawingSession.selectedDrawingID == "A")

        // ⑤ 删除成功
        let e5 = makeSelected()
        #expect(DrawingEditRouter.deleteSelected(engine: e5) == true)
        #expect(e5.drawingSession.selectedDrawingID == nil)
    }

    @Test("N21c/d（D66）：两条同 id → update/delete 都 fail 且不打第一条；正常三条 id 互异各打各的")
    func duplicateIdsFailClosed() {
        let e = TrainingEngine.preview()
        let a = makeStyledHLine(id: "X", thickness: 1, period: e.upperPanel.period, candleIndex: 0, price: 50)
        let b = makeStyledHLine(id: "X", thickness: 2, period: e.upperPanel.period, candleIndex: 0, price: 50)
        e.injectDrawingsForTesting([a, b])                               // 绕过 append 门注入坏状态
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "X", panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        let rev = e.drawingsRevision
        var s = DrawingEditRouter.panelStyle(engine: e); s.thickness = 5
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == false)
        #expect(DrawingEditRouter.deleteSelected(engine: e) == false)
        #expect(e.drawings.count == 2)
        #expect(e.drawings[0].thickness == 1); #expect(e.drawings[1].thickness == 2)
        #expect(e.drawingsRevision == rev)
        #expect(e.drawingSession.selectedDrawingID == "X", "坏状态不是用户的错，别顺手夺走选中")
    }

    // ============ N19e 确认框时间窗（D65 R13-F1）============

    @Test("N19e：确认框期间线滑出屏 → 点「删除」在确认那一刻重算几何 → 不调引擎、不删、选中保留")
    func deleteRechecksGeometryAtConfirmMoment() {
        let e = makeSelected(price: 50)
        #expect(DrawingEditRouter.canDelete(engine: e) == true)         // 点 🗑 那一刻：可删，弹框
        // 弹框期间惯性/自动推进把线带出屏
        e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
        let rev = e.drawingsRevision
        #expect(DrawingEditRouter.deleteSelected(engine: e) == false,   // 点「删除」
                "只在点 🗑 那一刻判几何是时序 bug —— 必须在确认那一刻重算")
        #expect(e.drawings.count == 1)
        #expect(e.drawingsRevision == rev)
        #expect(e.drawingSession.selectedDrawingID == "A")
    }
```

在本文件底部加一个 fixture helper（**复用 PR-2 已建的共享 fixture，不新造测试逃生舱**）：

```swift
    /// 一条**携带未来未知枚举值**的线（`colorToken:"futureNeon"` / `textColorToken:"futureCyan"`，
    /// 双双 fallback 成 `.orange`）经 lossy 解码进 engine，并选中它。
    /// raw 逐字取自 `DrawingEditDurabilityGateTests.futureRaw`（PR-2 已用它钉 N14a/b），
    /// 构造走 `DrawingTestFixtures` 的 `lossyFromRaw` + `makeEngineWithLossy`（该引擎 upper=lower=`.m3`，
    /// 故 raw 里的 `period` 必须是 `"3m"`；价格 9.0 落在本文件 `mapper()` 的 [0,100] 区间内 → 几何可见）。
    private func engineWithFutureEnumLine(id: String) throws -> TrainingEngine {
        let raw = #"{"id":"F","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"futureNeon","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"futureCyan","textForm":"plain"}"#
        let e = makeEngineWithLossy(try lossyFromRaw(raw))
        #expect(e.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: [id]) == true,
                "fixture 前提：raw-aware 门必须命中，否则这条测试测的是别的东西")
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: id, panel: .upper)
        return e
    }
```

> **已核实的既有测试入口（本机 grep 确认，实施时直接用，不要另造）**：
> - `injectDrawingsForTesting(_ ds: [DrawingObject])`（`TrainingEngine.swift:1452`，internal）—— 绕过 append 门直接注入 `drawings`；**没有** `seedDrawingsForTesting` 这个名字。
> - `makeEngineWithLossy(_ lossy: LossyDrawingArray) -> TrainingEngine`（`DrawingTestFixtures.swift:45`）—— upper=lower=`.m3`、maxTick 99。
> - `lossyFromRaw(_ raw: String) throws -> LossyDrawingArray`（`:55`）—— 内部是 `LossyDrawingArray.decode(Data(...))`，**位置参数，没有 `from:` 标签**。
> - `expectDrawingsUnchanged(_ e:_ before:revisionBefore:)`（`:65`）—— 「拒绝 = 零改动」的**统一**断言（它同时比 id 序列，因为 `DrawingObject.==` 排除 `id`）。**每一处「被拒后不变」都用它，别各写各的。**
> - `makeStyledHLine(id:lineSubType:lineStyle:thickness:colorToken:labelMode:locked:textColorToken:text:fontSize:textForm:tailAnchor:panelPosition:period:candleIndex:price:)`（`:23`）。

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test 2>&1 | tail -20
```

Expected：编译失败 —— `type 'DrawingEditRouter' has no member 'canEditStyle'`。

- [ ] **Step 3: 实现谓词与路由**

追加到 `DrawingEditRouter.swift`（`selectionGeometryVisible` 之后）：

```swift
    // MARK: 可用性谓词（D65）—— **必须与引擎门逐条对齐**

    // ⚠️ `uniqueSelected` 已在 Task 2 Step 4 随本文件建好（`selectionGeometryVisible` 依赖它），**本 Task 不要重复定义**。

    /// 「改样式可用」的**非几何分量**（review / 唯一 / `locked` / 工具已实现 / 未来数据）。
    /// ⚠️ **判据以引擎门为准，不是以 spec D65 的字面为准**（PR-2 交接②）：`updateDrawingStyle`
    /// 比 D65 写的三分量多**三道**——`flow.mode != .review`（D34 纵深）、`isEditableToolType`
    /// （本构建懂不懂这个工具的样式语义）、`hasKnownFutureFields`（未来顶层字段）。
    /// 少一道 = 控件亮着、点了没反应；多一道 = 过度置灰。两边都是缺陷。
    /// （引擎第 ④ 道 `withStyle` 语义闸**不在**本谓词里：它依赖**具体要写的样式**，
    ///   不是「这条线能不能改」的属性，由 `applyStyle` 逐次传播失败。）
    /// **抽出来是为了让「现算」与「读提示」两条路径只在几何这一点上不同**（PD2）——
    /// 若各写一份，早晚有一天两边的非几何分量会漂移。
    private static func editableIgnoringGeometry(engine: TrainingEngine) -> Bool {
        guard engine.flow.mode != .review else { return false }
        guard let d = uniqueSelected(engine: engine) else { return false }
        guard !d.locked else { return false }
        guard DrawingStyleAvailability.isEditableToolType(d.toolType) else { return false }
        return !engine.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: [d.id])
            && !engine.loadedDrawingsLossy.hasKnownFutureFields(liveIds: [d.id])
    }

    /// 「删除可用」的**非几何分量** —— 与上者共享 review / 唯一 / `locked` 三个分量，
    /// **不含**未来数据与工具两个分量：删整条不产生"部分抹除"（raw 随之整体移除），
    /// 且它是这类线唯一的用户侧处置通道（D61）。与引擎 `deleteDrawing(id:)` 的三道门逐条对齐。
    private static func deletableIgnoringGeometry(engine: TrainingEngine) -> Bool {
        guard engine.flow.mode != .review else { return false }
        guard let d = uniqueSelected(engine: engine) else { return false }
        return !d.locked
    }

    // MARK: 两个读法（PD2）—— 几何**现算**给写入路由，几何**读 observable 提示**给 UI 置灰

    /// **路由用**（唯一的门）：几何现算。
    static func canEditStyle(engine: TrainingEngine) -> Bool {
        editableIgnoringGeometry(engine: engine) && selectionGeometryVisible(engine: engine)
    }

    /// **路由用**（唯一的门）：几何现算。
    static func canDelete(engine: TrainingEngine) -> Bool {
        deletableIgnoringGeometry(engine: engine) && selectionGeometryVisible(engine: engine)
    }

    /// **UI 用**：5 组样式控件是否可用。
    /// ⚠️ 两处刻意与上面不同，**都不是笔误**（codex plan-R1-F1/F2）：
    ///   ① **无选中 → 恒可用**：此刻面板在改「下一条线的默认」，与任何线的状态无关。
    ///      写成 `canEditStyle` 会让无选中时控件全灰 —— 那是 1a-iii 就有的能力，会被直接回归掉
    ///      （验收 #13：取消选中后改默认、再画一条新线）。
    ///   ② 几何读 **observable** 的 `selectionGeometryVisible`，**不是**现算：
    ///      mapper 是 `@ObservationIgnored`，UI 若走现算，SwiftUI 建立不了依赖 →
    ///      平移到线看不见时**不重绘** → 控件停在旧状态（验收 #18c 失效）。
    ///      提示陈旧最坏只是晚一帧，写入仍会被 `canEditStyle` 那道现算的门拦住。
    static func styleControlsEnabled(engine: TrainingEngine) -> Bool {
        guard engine.drawingSession.selectedDrawingID != nil else { return true }   // ①
        return editableIgnoringGeometry(engine: engine)
            && engine.drawingSession.selectionGeometryVisible                        // ②
    }

    /// **UI 用**：🗑 是否可用。与 `styleControlsEnabled` **刻意不对称**——无选中时 🗑 没有操作对象，
    /// 恒灰（spec §1.1 #1 原文：「无选中时灰」）。几何同样读 observable 提示（理由同上）。
    static func deleteButtonEnabled(engine: TrainingEngine) -> Bool {
        deletableIgnoringGeometry(engine: engine) && engine.drawingSession.selectionGeometryVisible
    }

    // MARK: D49 面板派生样式（**唯一**一处从 DrawingObject 取 5 个样式字段）

    /// 常驻面板此刻该显示的样式：有选中 → 那条线的当前样式；无选中 → 「下一条线的默认」。
    /// **是每次求值现算的派生值，不是拷贝进某个 @State 的副本**（D49：常驻面板长期存活，
    /// 任何第二份样式状态都会与 `engine.drawings` 里的真值漂移）。
    static func panelStyle(engine: TrainingEngine) -> DrawingDefaultStyle {
        guard let d = uniqueSelected(engine: engine) else { return engine.drawingSession.defaultStyle }
        var s = DrawingDefaultStyle()
        s.lineSubType = d.lineSubType
        s.lineStyle = d.lineStyle
        s.thickness = d.thickness
        s.colorToken = d.colorToken
        s.labelMode = d.labelMode
        return s
    }

    // MARK: 两条写入路由（`Sources/` 里 updateDrawingStyle / deleteDrawing(id:) 的**唯一**调用点）

    /// D54 clause 3 + D64：写入之后（无论成败、无论有没有真的调过引擎）按**状态**同步选中。
    /// **绝不读任何 API 的返回值**：失败原因有五类，其中三类必须保留选中，一个 Bool 表达不了
    /// （spec D64 的全部理由）。
    ///
    /// 判据 = D64 原文那个析取式「清空 ⟺（**结构性**不含 **或** 存在性缺失）」，而
    /// `visibleDrawings(for: selectedPanel)` **不含该 id** 已经把两项一并覆盖（线被删了就哪个集合都不在）
    /// → 一个谓词表达完整语义，没有第二处可以写漏（codex plan-R5-F1）。
    /// ⚠️ **绝不能改用带 mapper 的几何判据**：`visibleDrawings` 无 mapper、**只判结构**，
    /// 几何性不可见的线仍在集合里 → 不会把 D63 退化成「一次惯性平移就把选中抖掉」（那正是
    /// D63 明确拒绝 codex 原处方的理由）。
    private static func syncSelectionByState(engine: TrainingEngine) {
        guard engine.drawingSession.selectedDrawingID != nil else { return }
        if uniqueSelected(engine: engine) == nil { engine.drawingSession.clearSelection() }
    }

    /// 改选中线的样式。执行顺序（D65 明写，不得调换）：
    ///   ① D65 当前几何门（**在写入这一刻现算**）→ ② 仅当 `lineSubType` 真的变了才跑 D58 候选预检
    ///   → ③ 才调引擎（引擎自己再把 viewport 无关的六道门跑一遍）。
    @discardableResult
    static func applyStyle(_ style: DrawingDefaultStyle, engine: TrainingEngine) -> Bool {
        defer { syncSelectionByState(engine: engine) }
        guard let id = engine.drawingSession.selectedDrawingID,
              let panel = engine.drawingSession.selectedPanel,
              let old = uniqueSelected(engine: engine) else { return false }
        guard canEditStyle(engine: engine) else { return false }                       // ①
        if style.lineSubType != old.lineSubType {                                      // ②
            // 候选对象**必须**用 `withStyle` 造（语义单点 D59），不许自己拼一个 DrawingObject。
            guard let candidate = old.withStyle(style),
                  let mapper = engine.drawingSession.viewportMapper(for: panel),
                  HorizontalLineTool.visibleGeometry(for: candidate, mapper: mapper) != nil
            else { return false }
        }
        return engine.updateDrawingStyle(id: id, style: style)                         // ③
    }

    /// 删除选中线。**唯一合法调用点是确认框「删除」按钮的 action**——几何必须在**确认那一刻**
    /// 重算（`canDelete` 内部现算），只在点 🗑 那一刻判是时序 bug（D65 R13-F1 / N19e）。
    @discardableResult
    static func deleteSelected(engine: TrainingEngine) -> Bool {
        defer { syncSelectionByState(engine: engine) }
        guard let id = engine.drawingSession.selectedDrawingID else { return false }
        guard canDelete(engine: engine) else { return false }
        return engine.deleteDrawing(id: id)
    }
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test 2>&1 | tail -8
```

Expected：全绿。若 `predicateCoversExtraEngineGates` / 未来枚举那两条因为 fixture 入口名字不对而编译失败 → 按 Step 1 的 ⚠️ 处理（grep 真实入口，别新造）。

- [ ] **Step 5: 守卫 0 → 1（N15 / N19a）**

在 `TrainingEngineDrawingSessionTests.swift` 的 `updateDrawingStyleTrustBoundary` 里，把零调用点断言换成：

```swift
        // PR-4 已接线：`Sources/` 里**恰好 1 处**调用，且必须在那条已先验几何的 UI 编辑路由里。
        let sites = try callSiteCount("updateDrawingStyle(")
        #expect(sites.count == 1, "updateDrawingStyle 的调用文件数应为 1，实际：\(sites)")
        #expect(sites.first?.count == 1, "同一文件内也只许 1 处，实际：\(sites)")
        #expect(sites.first?.file.hasSuffix("/Drawing/DrawingEditRouter.swift") == true,
                "唯一调用点必须是 UI 编辑路由，实际：\(sites)")
        // 那条路由必须**在调用之前**先验几何（D58 候选预检 + D65 当前门）——只钉"调用点唯一"不够，
        // 唯一的那处若不验几何，几何完整性同样失守。
        let router = contractsDirForGuards
            .appendingPathComponent("Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift").path
        #expect(try squeezedContains(router, "HorizontalLineTool.visibleGeometry("),
                "路由里没有几何判据 —— D58/D65 的门不存在")
        let code = try squeezedSource(router)
        let geoIdx = try #require(code.range(of: squeeze("HorizontalLineTool.visibleGeometry("))).lowerBound
        let callIdx = try #require(code.range(of: squeeze("engine.updateDrawingStyle("))).lowerBound
        #expect(geoIdx < callIdx, "几何判据必须排在 updateDrawingStyle 调用之前")
```

并把白名单那条改成：

```swift
        #expect(mentions.allSatisfy {
            $0.hasSuffix("/TrainingEngine/TrainingEngine.swift")
                || $0.hasSuffix("/Drawing/DrawingEditRouter.swift")
        }, "updateDrawingStyle 被引擎与唯一路由以外的文件提到（含方法引用）：\(mentions)")
        try expectIdentifierNeverVended("updateDrawingStyle", inFiles: mentions)
```

同样改 `deleteByIdTrustBoundary`：

```swift
        let idSites = try callSiteCount("deleteDrawing(id:")
        #expect(idSites.count == 1 && idSites.first?.count == 1,
                "deleteDrawing(id:) 应恰好 1 处调用，实际：\(idSites)")
        #expect(idSites.first?.file.hasSuffix("/Drawing/DrawingEditRouter.swift") == true,
                "唯一调用点必须是 UI 删除路由，实际：\(idSites)")
        // N19d 不回归：index 版本仍零调用点、仍非 public。
        let atSites = try callSiteCount("deleteDrawing(at:")
        #expect(atSites.isEmpty, "deleteDrawing(at:) 应零调用点：\(atSites)")
        try expectEngineInternalOnly("deleteDrawing(at index:")
        let mentions = try filesMentioning("deleteDrawing")
        #expect(!mentions.isEmpty, "扫描器返回空 —— 守卫已失效")
        #expect(mentions.allSatisfy {
            $0.hasSuffix("/TrainingEngine/TrainingEngine.swift")
                || $0.hasSuffix("/Drawing/DrawingToolManager.swift")
                || $0.hasSuffix("/Drawing/DrawingEditRouter.swift")
        }, "deleteDrawing 被白名单以外的文件提到（含方法引用）：\(mentions)")
        try expectIdentifierNeverVended("deleteDrawing", inFiles: mentions)
```

再加一条**新守卫**（钉死删除路由的几何在「确认之后」而不是「点 🗑 那一刻」）：

```swift
    @Test("PD2 结构守卫（codex plan-R1-F2）：两条读法不得混用 —— UI 只调 *Enabled，路由只调 can*")
    func twoGeometryReadsNeverCrossWired() throws {
        // UI 层（TrainingView / 底栏 / 面板）不得出现现算版谓词
        for rel in ["Sources/KlineTrainerContracts/UI/TrainingView.swift",
                    "Sources/KlineTrainerContracts/UI/DrawingModeBar.swift",
                    "Sources/KlineTrainerContracts/UI/DrawingStylePanel.swift",
                    "Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift"] {
            let code = try squeezedSource(contractsDirForGuards.appendingPathComponent(rel).path)
            #expect(!code.contains(squeeze("DrawingEditRouter.canEditStyle(")),
                    "\(rel) 调了现算版谓词 —— SwiftUI 建立不了 observation 依赖，平移后控件不重绘")
            #expect(!code.contains(squeeze("DrawingEditRouter.canDelete(")), "\(rel) 同上")
        }
        // 路由内部不得读 observable 提示（陈旧值会放行真写入）
        let router = try squeezedSource(contractsDirForGuards
            .appendingPathComponent("Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift").path)
        let liveOnly = try #require(router.range(of: squeeze("static func canEditStyle(")))
        let displayStart = try #require(router.range(of: squeeze("static func styleControlsEnabled(")))
        let liveBlock = String(router[liveOnly.lowerBound..<displayStart.lowerBound])
        #expect(!liveBlock.contains(squeeze("session.selectionGeometryVisible")),
                "现算版谓词里读到了 observable 提示 —— 确认框时间窗内会用陈旧值放行删除（N19e）")
        // 反向自足断言：UI 版确实读了提示（防上面两条在「谁都没调」的空状态下恒真）
        #expect(router.contains(squeeze("engine.drawingSession.selectionGeometryVisible")),
                "UI 版谓词没读 observable 提示 —— 那套信号白建了")
    }

    @Test("N19e 结构守卫：删除路由自己现算几何（不接受调用方传进来的陈旧布尔）")
    func deleteRouteRecomputesGeometryItself() throws {
        let router = contractsDirForGuards
            .appendingPathComponent("Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift").path
        let code = try squeezedSource(router)
        // deleteSelected 体内必须调 canDelete（它内部现算 visibleGeometry），
        // 而不是收一个 `geometryVisible: Bool` 参数（那就把判定时刻交给了调用方 = 时序 bug）。
        #expect(code.contains(squeeze("static func deleteSelected(engine: TrainingEngine) -> Bool")),
                "deleteSelected 签名变了？它不得新增任何几何入参")
        #expect(code.contains(squeeze("guard canDelete(engine: engine)")),
                "deleteSelected 必须自己调 canDelete 现算几何")
    }
```

- [ ] **Step 6: 变异验证（三条，逐条真看红）**

⚠️ 一次只改一处，**用 `cp` 备份/复原，禁 `git checkout <file>`**。

| # | 把什么改坏 | 期望哪条红 |
|---|---|---|
| 1 | `applyStyle` 里删掉候选预检整个 `if` 块 | `candidatePrecheckRejectsInvisibleRay` |
| 2 | `deleteSelected` 里把 `guard canDelete(...)` 删掉 | `deleteRechecksGeometryAtConfirmMoment` + `bothPredicatesFollowGeometry` |
| 3 | `canEditStyle` 里删掉 `isEditableToolType` 那一行 | `predicateCoversExtraEngineGates` |

```bash
swift test --filter DrawingEditRouterTests 2>&1 | tail -12
```
每次都必须看到 **真的 FAIL**（不是 0 个测试跑过），复原后重跑确认 PASS。

- [ ] **Step 7: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
git add ios/Contracts/
git commit -m "划线 P1b-1b-i PR-4 Task3：唯一写入路由 + D65 两个可用性谓词 + D58 候选预检 + D64 存在性清空（守卫 0→1）"
```

---

## Task 4：类型行图标改 toggle —— 画线态 / 选择态（D38 语义 + D57 显式 mode）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStylePanel.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（`ChartPanelsContainer` 的挂载处）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift`（**追加**，文件已由 Task 2 Step 6c 建好）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditRouterTests.swift`（追加复盘不可达行为测试）

**Interfaces:**
- Consumes：`DrawingSession.mode` / `setMode(_:)`（PR-1 已建）
- Produces：`DrawingTypeOverlay(isDrawMode:onToggleMode:onTogglePosition:)`、`DrawingStylePanel` 增 `onToggleMode`

- [ ] **Step 1: 写失败测试（源码守卫，host 可跑）**

**追加**到 `Render/DrawingInteractionUISourceGuardTests.swift`（文件与两个 helper 已由 Task 2 Step 6c 建好，
插在末尾那个 `}` 之前，**不要重复写文件头**）：

```swift
    @Test("D57/PD4：setMode 在 Sources/ 里恰好 1 处调用，且在类型行 toggle 的接线上（不是 activate/deactivate）")
    func setModeHasExactlyOneCallSite() throws {
        let sites = try callSiteCount("setMode(")
        #expect(sites.count == 1 && sites.first?.count == 2,
                "setMode 应只出现在一个文件里、恰好两次（.draw / .select 两个方向），实际：\(sites)")
        #expect(sites.first?.file.hasSuffix("/UI/TrainingView.swift") == true,
                "唯一调用点必须在类型行 toggle 的接线处，实际：\(sites)")
        // 切回画线态**不得**走 activate（那是「开会话/换工具」的入口，会话本来就开着）。
        // 否定断言 → 剥注释后判（接线处的注释里正当地提到了 activate）。
        #expect(!(try code("Sources/KlineTrainerContracts/UI/TrainingView.swift"))
                    .contains(squeeze(".activate(tool:")), "切回画线态不得开新会话")
    }

    @Test("D38：图标点亮 == 画线态（判据是 mode，不是 activeDrawingTool 是否为 nil）")
    func typeIconLitMeansDrawMode() throws {
        let overlayCode = try code("Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift")
        #expect(overlayCode.contains("isDrawMode"), "图标亮灭必须由传入的 isDrawMode 决定")
        // 否定断言必须剥注释：本视图的文档注释里**正当地**写着「不是 activeDrawingTool == nil」（D57 的理由），
        // 读原始文本会被自己的注释打红（codex plan-R2-F1）。
        #expect(!overlayCode.contains("activeDrawingTool"),
                "D57 取代了 nil 编码 —— 视图层的**代码**里不得再用 activeDrawingTool 判态")
    }

    @Test("D38：作废的旧注释必须随本期删掉（否则文档与行为相反）—— 本条**刻意**读原始文本，它测的就是注释")
    func staleToggleCommentsRemoved() throws {
        let overlayRaw = try raw("Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift")
        #expect(overlayRaw.contains("DrawingTypeOverlay"), "先证明真读到了文件（防路径写错 → 空串 → 否定断言假绿）")
        for stale in ["不做 toggle", "本期短按 no-op", "恒亮"] {
            #expect(!overlayRaw.contains(stale), "作废注释仍在：\(stale)")
        }
    }

    @Test("交接⑥：复盘结构上进不去选择态 —— 类型行随样式面板挂载，而面板判据含 showsTradeButtons")
    func reviewCannotReachSelectMode() throws {
        let tvPath = contractsDirForGuards
            .appendingPathComponent("Sources/KlineTrainerContracts/UI/TrainingView.swift").path
        // 唯一的 toggle 入口在样式面板里，而面板可见性判据天然排除复盘（canBuySell()==false）
        #expect(try squeezedContains(tvPath,
            "private var stylePanelWillBeVisible: Bool { showsTradeButtons && isDrawingActive && typeRowExpanded }"))
        #expect(try squeezedContains(tvPath, "private var showsTradeButtons: Bool { engine.flow.canBuySell() }"))
        // 底栏同理：DrawingBottomBar 挂在 showsTradeButtons → isDrawingActive 分支内。
        // 邻接断言在**剥注释后**做——否则中间插一段注释就能把两者推开、守卫静默失效。
        let tv = try code("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        let dmb = try #require(tv.range(of: "DrawingBottomBar("), "DrawingBottomBar 未接入")
        #expect(String(tv[..<dmb.lowerBound].suffix(60)).contains(squeeze("if isDrawingActive {")))
    }
```

追加到 `Drawing/DrawingEditRouterTests.swift`（行为侧，证明复盘就算被塞进选择态也一无所获）：

```swift
    @Test("交接⑥ 纵深：复盘模式下两个谓词恒假、两条路由恒拒（结构上进不去，进去了也动不了）")
    func reviewModeIsInert() {
        let e = TrainingEngine.preview(mode: .review)
        #expect(e.appendDrawing(makeStyledHLine(id: "R", period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode(); e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "R", panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(DrawingEditRouter.canEditStyle(engine: e) == false)
        #expect(DrawingEditRouter.canDelete(engine: e) == false)
        var s = DrawingEditRouter.panelStyle(engine: e); s.thickness = 5
        #expect(DrawingEditRouter.applyStyle(s, engine: e) == false)
        #expect(DrawingEditRouter.deleteSelected(engine: e) == false)
        #expect(e.drawings.count == 1)
    }
```

> **已核实**：`TrainingEngine.preview(mode: TrainingMode = .normal)`（`TrainingEngine.swift:1394`）存在；`appendDrawing`（`:1129`）**没有**复盘门（只有 `updateDrawingStyle` / `deleteDrawing(id:)` 带 ⓪ review 门）→ review 引擎上照样 append 得进去，这正是本测试要的前提。

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test --filter DrawingInteractionUISourceGuardTests 2>&1 | tail -20
```

Expected：FAIL（`setMode` 零调用点 / `isDrawMode` 不存在）。

- [ ] **Step 3: 改 `DrawingTypeOverlay`**

把文件头注释里那两句已过时的话删掉，并改 `body`：

```swift
struct DrawingTypeOverlay: View {
    /// D38/D57（1b-i PR-4）：图标**点亮 = 画线态**、熄灭 = 选择态。判据是 `DrawingSession.mode`
    /// 这个**显式**状态，**不是** `activeDrawingTool == nil`——nil 编码会让切周期善后早退致裂脑（D57）。
    let isDrawMode: Bool
    let onToggleMode: () -> Void              // 1b-i PR-4：短按在画线态 / 选择态之间切
    let onTogglePosition: () -> Void          // 1a-iii 切片2 Task3：⇅ 切换面板上/下半区

    // 类型行：本期只 1 个水平线图标，点亮（浅蓝框）= 画线态，熄灭 = 选择态。
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleMode) {
                Image(systemName: "minus")
                    .frame(width: 40, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(isDrawMode ? Color.accentColor : Color.secondary.opacity(0.35),
                                lineWidth: 1.5))
                    .foregroundStyle(isDrawMode ? Color.accentColor : Color.secondary)
            }
            .accessibilityLabel("水平线")
            .accessibilityValue(isDrawMode ? "画线态" : "选择态")
            Spacer()
            Button(action: onTogglePosition) {
                Image(systemName: "arrow.up.arrow.down")
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Color.secondary)
            }
            .accessibilityLabel("切换面板位置")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}
```

- [ ] **Step 4: `DrawingStylePanel` 透传**

给 `DrawingStylePanel` 加两个属性（**保留 `session`**，既有守卫锚 `"DrawingStylePanel(session:"`）：

```swift
    let session: DrawingSession
    let scheme: AppColorScheme
    let position: DrawingStylePanelPosition
    let onToggleMode: () -> Void              // 1b-i PR-4：类型行图标短按（画线态 ⇄ 选择态）
    let onTogglePosition: () -> Void
```

`body` 里两处 `DrawingTypeOverlay(onTogglePosition: onTogglePosition)` 都改成：

```swift
                DrawingTypeOverlay(isDrawMode: session.mode == .draw,
                                   onToggleMode: onToggleMode, onTogglePosition: onTogglePosition)
```

- [ ] **Step 5: `TrainingView` 接线**

`ChartPanelsContainer` 加一个属性并透传（放在 `onTogglePosition` 旁边）：

```swift
    let onToggleMode: () -> Void                   // 1b-i PR-4：类型行图标短按（画线态 ⇄ 选择态）
```

挂载处（`:702-704`）改成：

```swift
                DrawingStylePanel(session: engine.drawingSession, scheme: scheme,
                                  position: stylePanelPosition,
                                  onToggleMode: onToggleMode, onTogglePosition: onTogglePosition)
```

`TrainingView.chartPanels` 里构造 `ChartPanelsContainer` 的那处（`:498`）补上闭包：

```swift
            onToggleMode: {
                // D38/D57：两个方向都走 setMode —— 会话一直开着、工具在选择态恒非 nil（D57），
                // 切回画线态**不是**开会话，不得走 activate（那是 beginDrawingSession 的专属入口）。
                let session = engine.drawingSession
                if session.mode == .draw { session.setMode(.select) } else { session.setMode(.draw) }
            },
```

⚠️ 本文件下方还有**三个测试外壳**也构造 `ChartPanelsContainer`（`DrawingStylePanelSourceGuardTests` 提到过），编译会一起报错 → 逐个补 `onToggleMode: {}`。

- [ ] **Step 6: 跑测试确认通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test 2>&1 | tail -8
```

Expected：全绿（新增 4 条）。

- [ ] **Step 7: 变异验证**

把 `TrainingView` 的 toggle 闭包改成 `session.setMode(.select)`（去掉分支，只能进不能回）→ `setModeHasExactlyOneCallSite` 里 `count == 2` 那条应红。复原确认绿。

- [ ] **Step 8: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
git add ios/Contracts/
git commit -m "划线 P1b-1b-i PR-4 Task4：类型行图标改 toggle —— 点亮=画线态 / 熄灭=选择态（D38 语义 + D57 显式 mode）"
```

---

## Task 5：底栏 ③🗑 + 删除确认框（spec §1.1 #1/#5，PD5/PD6）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingModeBar.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift`（追加）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingBottomBarHeightTests.swift`（既有构造调用要补参数）

**Interfaces:**
- Consumes：Task 3 的 `DrawingEditRouter.canDelete(engine:)` / `.deleteSelected(engine:)`
- Produces：`DrawingBottomBar(typeRowExpanded:deleteEnabled:onDelete:)`

- [ ] **Step 1: 写失败测试**

追加到 `Render/DrawingInteractionUISourceGuardTests.swift`：

```swift
    @Test("spec §1.1 #1 / PD5：底栏**恰好 2 个按钮**（类型 + ③🗑），②🔒④↩⑤↪ 属 1b-ii 一个都不渲染")
    func bottomBarHasExactlyTwoKeys() throws {
        let bar = try code("Sources/KlineTrainerContracts/UI/DrawingModeBar.swift")
        // ⚠️ **结构计数，不是「禁止图标名」黑名单**（PD7）：黑名单既漏（新图标名不在表里）
        //    又误伤注释（本视图注释里正当地写着 `locked` / 🔒 的去向）。恰好 2 个 `Button`
        //    机械且完备地表达了「只许有这两个控件」。`.buttonStyle` 是小写 b，不参与计数。
        #expect(bar.components(separatedBy: "Button").count - 1 == 2,
                "底栏按钮数不是 2 —— 多了就是把 1b-ii 的键提前 ship 了，少了就是 🗑 没接进来")
        #expect(bar.contains("deleteEnabled"), "🗑 必须由传入谓词置灰，不得自己判")
        #expect(bar.contains(squeeze(".disabled(!deleteEnabled)")))
        // 底栏与另两个 swap 底栏共享同一固定高度（既有不变量，别被本次改动碰掉）
        #expect(bar.contains("BottomBarMetrics.height"))
        // 用户可见文案 / SF Symbol 名是**字符串字面量** → squeezedSource 会丢弃它们，必须读原始文本，
        // 且带完整调用语法做锚（裸词会被注释里的同一个词假绿）。
        let barRaw = try raw("Sources/KlineTrainerContracts/UI/DrawingModeBar.swift")
        #expect(barRaw.contains("Text(\"类型\")"))
        #expect(barRaw.contains("Image(systemName: \"trash\")"), "③🗑 未接入")
        #expect(barRaw.contains(".accessibilityLabel(\"删除\")"))
    }

    @Test("spec §1.1 #5 / D65 R13-F1：🗑 只弹确认框；真正的删除在「删除」按钮的 action 里走路由")
    func deleteGoesThroughConfirmation() throws {
        // ① 用户可见文案 → 原始文本 + 完整调用语法锚
        let tvRaw = try raw("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(tvRaw.contains(".confirmationDialog(\"确定删除划线？\""))
        #expect(tvRaw.contains("Button(\"删除\", role: .destructive)"))
        #expect(tvRaw.contains("Button(\"取消\", role: .cancel)"))
        // ② 结构断言 → 剥注释后判
        let tv = try code("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        // 🗑 的 action **只置标志位**，绝不直接删（弹框有时间窗，线可能滑走 → N19e）。
        // 整段精确匹配，不用「取后 160 字符再找子串」那种会被排版/注释推偏的邻接判据。
        #expect(tv.contains(squeeze("onDelete: { confirmingDeleteDrawing = true }")),
                "🗑 的 action 必须只置标志位；出现别的语句即可能绕过确认框")
        // 唯一一处 deleteSelected 在确认框的「删除」按钮里
        #expect(tv.components(separatedBy: squeeze("DrawingEditRouter.deleteSelected(")).count - 1 == 1,
                "deleteSelected 在 TrainingView 的**代码**里应恰好出现 1 次")
    }
```

`DrawingBottomBarHeightTests.swift:42` 的构造改成：

```swift
        let bar = DrawingBottomBar(typeRowExpanded: .constant(false), deleteEnabled: false, onDelete: {})
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test --filter DrawingInteractionUISourceGuardTests 2>&1 | tail -20
```

Expected：FAIL（`③🗑 未接入`）。

- [ ] **Step 3: 底栏加 🗑**

改 `DrawingModeBar.swift` 的头注释与 `DrawingBottomBar`：

```swift
/// 画线底栏（单行）：①「类型」键（收/展类型行）+ **③🗑 删除键（1b-i PR-4）**。
/// ②🔒④↩⑤↪ 属 1b-ii，本期**一个占位都不渲染**（母 spec D19 / D24：不 ship 恒灰的未接线按钮）；
/// 1b-ii 落 🔒 时插在「类型」与 🗑 之间。
/// 与 TradeActionBar/ReviewControlBar 共享同一个 `BottomBarMetrics.height` 固定高度 → 三者切换零跳动。
struct DrawingBottomBar: View {
    @Binding var typeRowExpanded: Bool
    /// D65「删除可用」谓词的结果。**本视图自己不判任何东西**——几何/locked/唯一性/复盘四个分量
    /// 都在 `DrawingEditRouter.canDelete` 里，视图只负责显示。
    let deleteEnabled: Bool
    /// 只负责**弹确认框**，绝不直接删（D65 R13-F1：弹框期间线可能滑出屏，几何必须在确认那一刻重算）。
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { typeRowExpanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "minus")
                    Text("类型")
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(typeRowExpanded ? 0 : 180))
                }
            }
            .accessibilityLabel("类型")
            Button(action: onDelete) { Image(systemName: "trash") }
                .accessibilityLabel("删除")
                .disabled(!deleteEnabled)
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .font(.system(size: 14).weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .frame(height: BottomBarMetrics.height)
        .background(.bar, ignoresSafeAreaEdges: .bottom)
    }
}
```

- [ ] **Step 4: `TrainingView` 接线 + 确认框**

加 `@State`（挨着既有的 `confirmingEnd`）：

```swift
    @State private var confirmingDeleteDrawing = false      // 1b-i PR-4：🗑 的删除确认框
```

底栏挂载处（`:254`）改成：

```swift
                    DrawingBottomBar(typeRowExpanded: $typeRowExpanded,
                                     deleteEnabled: DrawingEditRouter.deleteButtonEnabled(engine: engine),
                                     onDelete: { confirmingDeleteDrawing = true })
```

在 `body` 的 modifier 段落里（挨着既有的两个 `confirmationDialog`）加：

```swift
        // 1b-i PR-4（spec §1.1 #5）：删除必须确认。**几何在这里重算**（`deleteSelected` 内部调
        // `canDelete`）——弹框期间惯性/自动推进可能把线带出屏，只在点 🗑 那一刻判是时序 bug（D65 R13-F1）。
        .confirmationDialog("确定删除划线？", isPresented: $confirmingDeleteDrawing,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { DrawingEditRouter.deleteSelected(engine: engine) }
            Button("取消", role: .cancel) {}
        }
```

- [ ] **Step 5: 跑测试确认通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test 2>&1 | tail -8
```

Expected：全绿。

- [ ] **Step 6: 写 Catalyst 真渲染测试（🗑 的置灰是真的）**

追加到 `Render/DrawingBottomBarHeightTests.swift`（同 Suite，已是 UIKit-gated）：

> ⚠️ **本计划初稿在这里写了一条恒真测试**（codex plan-R2-F2 抓出）：它唯一的断言是「渲染没触发闭包」，
> 而**删掉 `.disabled(!deleteEnabled)` 它照样通过**——测的是「渲染不会自己点按钮」，不是置灰。
> 🗑 是本切片唯一的破坏性入口，这种假绿最不能留。下面这条改为**真的读渲染出来的可用性状态**：

```swift
    /// 在 hosted 视图树里按 accessibilityLabel 找元素，返回它的 accessibilityTraits。
    /// SwiftUI 的按钮在 Catalyst 上既可能是 subview、也可能挂在 `accessibilityElements` 里，两边都要走。
    @MainActor
    private func traits(ofLabel label: String, in root: UIView) -> UIAccessibilityTraits? {
        func walk(_ node: Any) -> UIAccessibilityTraits? {
            if let e = node as? NSObject, e.accessibilityLabel == label { return e.accessibilityTraits }
            if let v = node as? UIView {
                for child in (v.accessibilityElements ?? []) { if let t = walk(child) { return t } }
                for sub in v.subviews { if let t = walk(sub) { return t } }
            }
            return nil
        }
        return walk(root)
    }

    @Test("PR-4（codex plan-R2-F2 专项）：🗑 渲染出来的可用性**真的**跟随 deleteEnabled")
    @MainActor func trashButtonDisabledFollowsPredicate() throws {
        func hostedTraits(deleteEnabled: Bool) -> UIAccessibilityTraits? {
            let host = UIHostingController(
                rootView: DrawingBottomBar(typeRowExpanded: .constant(true),
                                           deleteEnabled: deleteEnabled, onDelete: {}).frame(width: 390))
            host.view.bounds = CGRect(x: 0, y: 0, width: 390, height: BottomBarMetrics.height)
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            return traits(ofLabel: "删除", in: host.view)
        }
        // 前提自足断言：先证明真的找到了那个按钮（找不到 → 下面两条会在 nil 上恒过 = 假绿）
        let off = try #require(hostedTraits(deleteEnabled: false), "hosted 树里找不到「删除」元素，本测试无判别力")
        let on  = try #require(hostedTraits(deleteEnabled: true),  "hosted 树里找不到「删除」元素，本测试无判别力")
        #expect(off.contains(.notEnabled), "deleteEnabled == false 时 🗑 必须渲染成不可用")
        #expect(!on.contains(.notEnabled), "deleteEnabled == true 时 🗑 必须可用（防「一律置灰」骗过上一条）")
        // 置灰只降可交互性，不改布局（三个 swap 底栏等高不变量）
        let bar = DrawingBottomBar(typeRowExpanded: .constant(true), deleteEnabled: false, onDelete: {})
        #expect(measuredHeight(bar, width: 390) == BottomBarMetrics.height)
    }
```

> 🔴 **本条必须在 Catalyst 上做变异验证才算数**（Task 7 Step 9 第 3 项）：删掉 `.disabled(!deleteEnabled)` → 它必须**真的红**。
> **如果 `traits(ofLabel:in:)` 在 Catalyst 上找不到该元素**（SwiftUI 无障碍树的暴露方式随版本变化，本计划无法预先证实）：
> **不许把它降级成一条弱断言留在库里** —— 那正是本条要消灭的假绿。届时二选一：
> ① 换一种能真读到状态的探测方式并重做变异验证；
> ② **整条删掉**，在 PR body 里如实记录「🗑 置灰只有源码守卫、无运行时证据」，并写进真机验收第一批必验项。
> 两条路都可以，**唯独不许留一条杀不死的测试**。

- [ ] **Step 7: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
git add ios/Contracts/
git commit -m "划线 P1b-1b-i PR-4 Task5：底栏 ③🗑 + 删除确认框（几何在确认那一刻重算）"
```

---

## Task 6：常驻样式面板作用于选中线（D49 选中即回显 + D65 置灰）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStylePanel.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingStylePanelSourceGuardTests.swift`（3 条既有守卫要跟着改）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift`（追加）

**Interfaces:**
- Consumes：Task 3 的 `DrawingEditRouter.panelStyle(engine:)` / `.canEditStyle(engine:)` / `.applyStyle(_:engine:)`
- Produces：`DrawingStyleParams(style:enabled:scheme:onChange:)`、`DrawingStylePanel` 增 `style` / `styleEnabled` / `onStyleChange`

- [ ] **Step 1: 写失败测试**

追加到 `Render/DrawingInteractionUISourceGuardTests.swift`：

```swift
    @Test("D49：面板样式是**派生值**，视图层既不存副本、也不自己从 DrawingObject 取字段")
    func panelStyleIsDerivedNotMirrored() throws {
        // 全部是否定/结构断言 → 一律剥注释后判（本视图的文档注释里正当地提到 `engine.drawings`、
        // `@State`、`session` 的去向，读原始文本会被自己的注释打红，codex plan-R2-F1）。
        let params = try code("Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift")
        #expect(params.contains(squeeze("let style: DrawingDefaultStyle")), "面板必须收调用方算好的派生值")
        #expect(!params.contains(squeeze("@State private var style")), "不得存第二份样式状态（常驻面板必然漂移）")
        #expect(!params.contains("session."), "面板的**代码**里不得再直读/直写 session —— 派生与路由都在调用方（D49）")
        #expect(!params.contains("engine."), "面板的**代码**里更不得直接碰引擎")
        // 5 个样式字段的逐字段取值只许出现在路由里（判据单点）
        let router = try code("Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift")
        #expect(router.contains(squeeze("s.lineSubType = d.lineSubType")))
        for f in ["lineSubType", "lineStyle", "thickness", "colorToken", "labelMode"] {
            #expect(!params.contains("d.\(f)"), "面板里出现了第二份派生：d.\(f)")
        }
    }

    @Test("D49 路由分流 + D65 置灰：有选中写路由、无选中写默认；enabled 来自 UI 版谓词")
    func panelRoutesBySelection() throws {
        let tv = try code("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(tv.contains(squeeze("DrawingEditRouter.panelStyle(engine: engine)")))
        #expect(tv.contains(squeeze("DrawingEditRouter.styleControlsEnabled(engine: engine)")))
        #expect(tv.contains(squeeze("DrawingEditRouter.deleteButtonEnabled(engine: engine)")))
        #expect(tv.contains(squeeze("DrawingEditRouter.applyStyle(")))
        #expect(tv.contains(squeeze("engine.drawingSession.setDefaultStyle(")))
        // 分流判据必须是「有没有选中」，不是别的
        #expect(tv.contains(squeeze("engine.drawingSession.selectedDrawingID != nil")))
        // applyStyle 在 Sources/ 里恰好 1 处（面板是唯一的样式写入入口，D58 末段：
        // 不得绕开面板另开编辑入口，否则 (ray,.left) 会变成只在编辑路径上可达的坏组合）
        let sites = try callSiteCount("DrawingEditRouter.applyStyle(")
        #expect(sites.count == 1 && sites.first?.count == 1, "applyStyle 调用点应恰好 1 处，实际：\(sites)")
    }
```

改 3 条既有守卫（`DrawingStylePanelSourceGuardTests.swift`）。⚠️ 该文件既有的 `source(_:)`（`:16`）返回的是
**原始文本**；按 PD7，本期新增/改动的**否定与结构断言**一律改走 `squeezedSource(...)`（同 test module 顶层函数，
无需 import），否则会被本期新写的承重注释打红（codex plan-R2-F1 就是这么抓出来的）：

```swift
// ① :27 hasGroupsAndWiring —— 写入从 session 改成 onChange（结构断言 → 剥注释）
        let codeStripped = try squeezedSource(contractsDirForGuards.appendingPathComponent(params).path)
        #expect(codeStripped.contains("onChange("))     // 选择真经调用方路由（D49，1b-i PR-4）
        // （删掉 `#expect(code.contains("session.setDefaultStyle"))`——那一处已上移到 TrainingView）
        // ⚠️ 那 5 个组名（"线型"/"线样式"/"粗细"/"颜色"/"标注"）是**用户可见文案**，
        //    仍留在既有的原始文本 `code` 上判（squeezedSource 会丢弃字符串字面量内容 → 在它上面恒假）。
```

```swift
// ② :85 readsSessionDirectlyWithoutLocalMirror —— 判据从「直读 session」改成「读传入的派生值」
    @Test("常驻面板读**调用方算好的派生样式**单一真相（不留本地 @State 镜像，防常驻期漂移）")
    func readsDerivedStyleWithoutLocalMirror() throws {
        // 全是否定/结构断言 → 剥注释（本视图注释里正当地写着「绝不拷成 @State」「不再直读 session」）
        let code = try squeezedSource(contractsDirForGuards.appendingPathComponent(params).path)
        #expect(!code.contains(squeeze("private var style: DrawingDefaultStyle")))   // 不许再自己算
        #expect(code.contains(squeeze("let style: DrawingDefaultStyle")))
        #expect(!code.contains(squeeze("@State private var style")))
    }
```

```swift
// ③ :232 mirrorFlipsOnlyTwoBlocks 的锚点（结构断言 → 剥注释 + squeeze needle）
        let panelCode = try squeezedSource(contractsDirForGuards.appendingPathComponent(self.panel).path)
        #expect(panelCode.contains(squeeze("DrawingStyleParams(style: style, enabled: styleEnabled,")))
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test --filter DrawingInteractionUISourceGuardTests 2>&1 | tail -20
```

Expected：FAIL。

- [ ] **Step 3: 改 `DrawingStyleParams`**

头部三处改动，其余（5 组控件、图标、可访问性标签、颜色行）**一字不动**：

```swift
struct DrawingStyleParams: View {
    /// D49（1b-i PR-4）：**调用方算好的派生值** —— 有选中就是那条线的当前样式，无选中是
    /// 「下一条线的默认」。**绝不在本视图里拷成 @State**：常驻面板长期存活，任何第二份
    /// 样式状态都会与 `engine.drawings` 里的真值漂移（1a-iii 消灭过一次，别再引入）。
    let style: DrawingDefaultStyle
    /// D65「改样式可用」谓词的结果。视图**自己不判任何东西**（几何 / locked / 未来数据 /
    /// 工具已实现 / 复盘五个分量都在 `DrawingEditRouter.canEditStyle` 里）。
    /// 置灰只降饱和 + `.disabled`，**绝不写任何解释文案**（母 spec §3 逐字）。
    let enabled: Bool
    let scheme: AppColorScheme
    /// D49：写入路由由调用方提供（有选中 → 改那条线；无选中 → 改默认）。
    let onChange: (DrawingDefaultStyle) -> Void

    private func commit(_ mutate: (inout DrawingDefaultStyle) -> Void) {
        var next = style
        mutate(&next)
        onChange(next)
    }
```

`body` 的最外层加一句（在既有 `.padding` 之后）：

```swift
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)      // 灰＝只降饱和，无解释字（母 spec §3）
```

⚠️ `body` 里所有 `style.xxx` 的读取**保持不变**（`style` 现在是传入属性而不是计算属性，读法逐字一致）。

- [ ] **Step 4: `DrawingStylePanel` 透传**

加三个属性并改两处调用：

```swift
    let style: DrawingDefaultStyle          // D49 派生值（调用方算）
    let styleEnabled: Bool                  // D65「改样式可用」
    let onStyleChange: (DrawingDefaultStyle) -> Void
```

```swift
                DrawingStyleParams(style: style, enabled: styleEnabled,
                                   scheme: scheme, onChange: onStyleChange)
```

- [ ] **Step 5: `TrainingView` 算派生值与路由**

`ChartPanelsContainer` 加三个属性并透传；`TrainingView.chartPanels` 的构造处补：

```swift
            // D49：派生值**每次求值现算**（`panelStyle` 内部：有选中取那条线、无选中取 defaultStyle）。
            style: DrawingEditRouter.panelStyle(engine: engine),
            styleEnabled: DrawingEditRouter.styleControlsEnabled(engine: engine),
            onStyleChange: { next in
                // D49：有选中 → 只作用于那条线（改动**不回写**「下一条线的默认」）；
                //      无选中 → 改默认。分流判据是「有没有选中」，别的都不是。
                if engine.drawingSession.selectedDrawingID != nil {
                    DrawingEditRouter.applyStyle(next, engine: engine)
                } else {
                    engine.drawingSession.setDefaultStyle(next)
                }
            },
```

⚠️ 同文件下方三个测试外壳也要补这三个参数。

- [ ] **Step 6: 跑测试确认通过 + 变异验证**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
swift test 2>&1 | tail -8
```
Expected：全绿。

变异：把 `onStyleChange` 的分流改成无条件 `setDefaultStyle(next)` → `panelRoutesBySelection` 里 `applyStyle` 调用点数那条应红。复原确认绿。

- [ ] **Step 7: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
git add ios/Contracts/
git commit -m "划线 P1b-1b-i PR-4 Task6：常驻样式面板作用于选中线（D49 选中即回显 / 派生值不存副本 + D65 置灰）"
```

---

## Task 7：三绿门 + Catalyst 基线同步

**Files:**
- Modify（**本切片必改**）：`.github/scripts/catalyst-uikit-baseline.txt`、`.github/scripts/fixtures/pass-main-current.log`
- Modify（**仅当 total 漂出 1663 ± 30，即 <1633 或 >1693**）：`.github/scripts/catalyst-total-baseline.txt`、`.github/scripts/catalyst-gate.test.sh`（「活基线覆盖」回显数字）

> ⚠️ 两条纪律（已对脚本核实）：① `catalyst-gate.sh` **不跑 xcodebuild**，只解析一份已存在的日志 → 必须自己先跑再喂路径。② **新增 UIKit-gated 测试就必须重新生成 uikit 基线，与 total 是否漂移无关**——`catalyst-gate.test.sh` 有一条独立断言，对当前源码活推导后与签入基线**逐行比对**。

- [ ] **Step 1: host swift test（非增量）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
git rev-parse --abbrev-ref HEAD; git rev-parse HEAD
rm -rf .build/arm64-apple-macosx
swift test 2>&1 | tail -8
```
Expected：`Test run with N tests ... passed`。⚠️ 先删增量产物——`@Observable` 改 stored property 后陈旧增量构建会在没碰过的 target 上 SIGSEGV（本项目踩过）。**本切片给 `DrawingSession` 加了 stored property，这条不是可选项。**

- [ ] **Step 2: 逐条人工过新增 UIKit-gated 测试（进基线之前）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
git diff origin/main...HEAD -- ios/Contracts/Tests | grep -n '^+.*@Test(\|^+.*func \|^+.*#expect(' | head -80
```
判据：**任何一条新 `@Test` 的函数体里若一个 `#expect` 都没有 → 停下补齐，不许进基线**（基线一更新，它就成了「闸门声称在守护」的测试）。

- [ ] **Step 3: 重新生成 uikit 基线**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
wc -l < .github/scripts/catalyst-uikit-baseline.txt          # 改之前：应为 71
python3 .github/scripts/uikit-expected-tests.py > .github/scripts/catalyst-uikit-baseline.txt
wc -l < .github/scripts/catalyst-uikit-baseline.txt          # 改之后：71 + 本切片新增的 UIKit-gated 测试数
git diff --stat .github/scripts/catalyst-uikit-baseline.txt
```
⚠️ **必须用这条生成命令，禁手打测试名**。Expected：diff 里**只有新增行**、没有删除行。出现删除行 → **停下报告**（改动误伤了既有 UIKit 测试）。

- [ ] **Step 4: 闸门自测**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
bash .github/scripts/catalyst-gate.test.sh 2>&1 | tee /tmp/gate-selftest-pr4.log | tail -30
```
Expected：`UIKit-gated 期望测试清单基线一致性检测（F1）：  ok`。此时「活基线覆盖」那条**大概率会红**（fixture 里还没有新测试的 `passed` 行）——**这正是 Step 6 要修的**，先记下红在哪条，别现在改。

- [ ] **Step 5: fresh Catalyst 全量**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4/ios/Contracts"
git rev-parse --abbrev-ref HEAD; git rev-parse HEAD
rm -rf /tmp/derived-pr4
set -o pipefail
xcodebuild test \
  -scheme KlineTrainerContracts-Package \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:KlineTrainerContractsTests \
  -derivedDataPath /tmp/derived-pr4 2>&1 | tee /tmp/catalyst-pr4.log
echo "XCODEBUILD_EXIT=$?"
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
bash .github/scripts/catalyst-gate.sh /tmp/catalyst-pr4.log; echo "GATE_EXIT=$?"
grep 'Test run with' /tmp/catalyst-pr4.log | tail -2
```
⚠️ 命令逐字取自 `.github/workflows/catalyst-build.yml`——**实施时先 `grep -n xcodebuild .github/workflows/catalyst-build.yml` 核对一遍**，别照抄这里的可能已漂移的版本。
Expected：日志尾部 `** TEST SUCCEEDED **`、闸门 `GATE PASS`、`Test run with N tests` 的 N ≫ 0。**判绿读输出内容与执行量，不看退出码、不看 `TEST SUCCEEDED` 四个字本身。**

- [ ] **Step 6: 用这一次的真日志重裁 `pass-main-current.log`**

1. **先读**现有 fixture 的形状照它裁（`head -20 .github/scripts/fixtures/pass-main-current.log`）——保留 DerivedData / worktree 绝对路径与任何 `XCTestOutputBarrier` 插花，**不修剪**；
2. 用**脚本**从 `/tmp/catalyst-pr4.log` 逐行取：`** TEST SUCCEEDED **` 标记行 + `Test run with … passed` 汇总行 + 基线里**每一个**测试名对应的 `passed` 行；
3. **禁手打伪造行**。脚本取不到某个基线测试名 → **fail-closed 报错并停下**，不许补一行假的；
4. 重跑 `bash .github/scripts/catalyst-gate.test.sh` → 全部用例通过。

- [ ] **Step 7: total 基线（仅当漂出 1663 ± 30）**

只有 G7 报「高于上限 / 低于下限」时才做：把 Step 5 实测的 total 写进 `.github/scripts/catalyst-total-baseline.txt`，同步 `catalyst-gate.test.sh` 里「活基线覆盖」用例的回显数字，然后**重跑 Step 4 与 Step 5**。
本切片预计新增 host 测试约 25 条 + UIKit-gated 约 3 条 → **很可能顶出上限 1693 → 大概率要 bump**。以实测数为准，别按估算提前改。

⚠️ 本 Task 动了 `.github/**` = trust-boundary → **必须触发重新 attest**（Task 8）。

- [ ] **Step 8: iOS build（**真的跑构建**，不是 grep workflow）**

> ⚠️ 本计划初稿这一步**只 grep 了 `app-build.yml` 就宣布 Expected: BUILD SUCCEEDED**，等于这道必需门根本不执行（codex plan-R3-F1）。
> 本切片**大改 SwiftUI 签名与 `TrainingView` 调用点**，是最可能只在 app scheme 上炸的一次——这道门必须真跑。

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
git rev-parse --abbrev-ref HEAD; git rev-parse HEAD
# 先确认下面的命令仍与 workflow 一致（漂移了就以 workflow 为准，改这里）
grep -n -A 8 "Build iOS app target" .github/workflows/app-build.yml
set -o pipefail
xcodebuild build \
  -project ios/KlineTrainer/KlineTrainer.xcodeproj \
  -scheme KlineTrainer \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/app-derived-pr4 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/app-build-pr4.log
echo "XCODEBUILD_EXIT=$?"
# 闸门判据逐字取自 app-build.yml:49-51（三条，缺一条都可能放过真失败）
grep -F "** BUILD SUCCEEDED **" /tmp/app-build-pr4.log || { echo "BUILD SUCCEEDED 缺失"; exit 1; }
grep -F "** BUILD FAILED **" /tmp/app-build-pr4.log && { echo "BUILD FAILED 触发 gate"; exit 1; }
grep -E "(^|[[:space:]])error:" /tmp/app-build-pr4.log && { echo "编译/链接 error: 触发 gate"; exit 1; }
echo "GATE PASS: app target 编译守护"
```

命令逐字取自 `.github/workflows/app-build.yml:41-51`（只把 derivedData / 日志路径加了 `-pr4` 后缀，避免覆盖别的 run）。
模拟器 + `CODE_SIGNING_ALLOWED=NO` → **不碰钥匙串**，我或 user 均可跑（真机签名安装才需 user 真终端）。
**判绿读日志内容**（那三条 grep），不看 exit code。

- [ ] **Step 9: 三条 UIKit-gated 变异必须在 Catalyst 上真跑（不许只做逻辑推演）**

UIKit-gated 文件在 host 上 `canImport(UIKit)==false`、**根本不参与编译** → host 全绿不构成它们的任何证据。逐条做（每次只改一处，`cp` 备份复原）：

| # | 把什么改坏 | 期望哪条 Catalyst 测试红 |
|---|---|---|
| 1 | `rebuildRenderState` 里删掉 `session.setViewportMapper(...)` 那一句 | `coordinatorPublishesRenderedViewport` |
| 2 | 发布的 mapper 改用 `RenderStateBuilder.makeViewport(...)` 重推而不是 `newState.viewport` | **`publisherUsesRenderedViewportOnly`（host 源码守卫，确定杀死）**。⚠️ **不要指望 `coordinatorPublishesRenderedViewport` 杀它**——`preview()` 的 K 线全是 `high:11/low:9`，聚合分支即使触发也不产生 priceRange 分叉，那条相等断言在这个 rig 上杀不死本变异（codex plan-R3-F2）。分叉本身由 host 的 `renderedViewportDivergesFromReDerivation` 单独钉住 |
| 3 | `DrawingBottomBar` 里删掉 `.disabled(!deleteEnabled)` | `trashButtonDisabledFollowsPredicate` —— **它红不了就说明它是假绿**，按 Task 5 Step 6 的两条出路处置（换探测方式重验，或整条删掉并如实记录 gap），**不许留着** |
| 4 | `rebuildRenderState` 里把延后刷新提示那整段删掉（codex plan-R1-F2 专项） | `coordinatorRefreshesGeometryHint` |

每次都必须看到 **`Test run with N tests` 的 N ≫ 0 且 `TEST FAILED`**（0 个测试跑过 + `TEST SUCCEEDED` = 假绿，本项目踩过）。
⚠️ `-only-testing` 对 swift-testing 的 `@Test` 显示名**语法不匹配**会静默跑 0 条 → 变异验证一律**跑全量**，靠日志里的 `✘`/`failed` 行定位。

- [ ] **Step 10: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
git add .github/scripts/
git commit -m "划线 P1b-1b-i PR-4：同步 Catalyst uikit 基线 + 真 fresh 日志重裁 fixture"
```

---

## Task 8：整支评审与收口

- [ ] **Step 1: whole-branch Opus 终审**（对 `2432d5f..HEAD` 全 diff，逐条核实源码）
  ⚠️ 派发 prompt **不得预判 finding**（不写「已知残留…不要当缺陷报」「最多 Minor」「计划已选 X」）——让评审自由报，由控制者 adjudicate。

- [ ] **Step 2: whole-branch codex 对抗性评审**
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr4"
bash .claude/scripts/codex-attest.sh --scope branch-diff > /tmp/codex-pr4-r1.log 2>&1
tail -40 /tmp/codex-pr4-r1.log
```
⚠️ **不加任何 `--focus` 窄化**（`--focus` 只收文件路径，传散文会被当路径 `git hash-object` 报错致 `set -e` 静默退出、账本全不写 → 假 approve）。全文**重定向到文件**，不要管道 `tail`（会截断 findings）。
⚠️ 判据：任务被 kill（`Terminated: 15` + 日志无 `Verdict:`）**不是 verdict** → 重跑且**不计轮次**。
⚠️ attest 之后 **Read 账本文件**核实 `head_sha` 与 `git rev-parse HEAD` 一致；**attest 后别再 rebase**。

- [ ] **Step 3: 收口**
  codex ≥5 轮不收敛 → **停下问 user**（不自行 override）。approve / user 裁决 override 后进 `superpowers:finishing-a-development-branch`。

- [ ] **Step 4: 合并后盯 main 真绿**
  判 CI 状态**显式判 `.status == "completed"`**，**绝不用 jq 的 `//` 合并 `conclusion` 和 `status`**（未完成的 run 返回的 `conclusion` 是空字符串不是 null，`//` 不回退 → 假绿）。
  Catalyst 的 per-test grep 有一个被并发 stderr（`[settings]loadSettings`）插花的 flake：红了先判断是不是它，是就 `gh run rerun --failed`。

---

## 非程序员验收清单（真机，user 执行）

> **前置**：Debug 构建 + `devicectl` 带 `KLINE_SEED_FIXTURE=1` 启动。
> ⚠️ **NAS 后端至今未部署**（`kline-trainer.local` 解析不了）→ 装完必报「训练组文件不存在」，**这是环境缺口不是回归**。
> ⚠️ 本清单的每一条 UI 陈述都已对**本分支源码**核过（不是从 spec 抄的）。spec §7 的 25 条 + PR-3 积压的 12 条「不回归」项一并列出，Task 8 完成后另出独立交付单。

（清单正文在 Task 8 完成后随交付单出，条目 = spec §7 的 #1–#25 + PR-3 不回归 12 条；⚠️ 出单前必须**再核一次真机行为**，1a-iv 与 PR-3 各错过一条照 spec 抄的 UI 陈述。）

---

## codex 对抗性评审记录（如实）

**R1（`619fa5b`，branch-diff 无窄化）= needs-attention，2 条 high，两条都是真 finding、已全修**：

| 轮 | 级别 | finding | 我的处置 |
|---|---|---|---|
| R1 | high | `styleEnabled` 无条件取 `canEditStyle`，而该谓词**无选中时返回 false** → 面板在无选中时全灰 → 用户改不了「下一条线的默认」，**回归 1a-iii 的既有能力**，且砸掉验收 #13 | **全采纳**。新增 **PD2b**：样式控件与 🗑 的可用性**刻意不对称**（无选中时面板恒可用、🗑 恒灰），拆出 `styleControlsEnabled` / `deleteButtonEnabled`，并加 `noSelectionKeepsStyleControlsUsable`（带反向对照，防「一律放行」骗过） |
| R1 | high | `selectionGeometryVisible` 被设计成 observable 信号，但 `canEditStyle` / `canDelete` 返回的是**现算**结果，UI 直接调它们 → SwiftUI **从未读过**那个 observable → 建立不了依赖 → 只改视口的平移不会让底栏/面板重绘，控件停在旧状态（**验收 #18c 失效**） | **全采纳**（codex 给的处方即我采用的形状）。**PD2 重写成两个读法的对照表**：路由用现算（唯一的门）、UI 用 observable 提示；**非几何分量抽成 `editableIgnoringGeometry` / `deletableIgnoringGeometry` 共享**，保证两条路径只在「几何怎么读」这一点上不同。新增 `displayReadsHintWhileRouteRecomputes`（构造「提示陈旧的那一帧」，断言 UI 版仍亮而路由版已判死、真删除被拦）+ 源码守卫 `twoGeometryReadsNeverCrossWired`（UI 文件不得出现现算版、路由内部不得读提示，含反向自足断言）+ Catalyst 的 `coordinatorRefreshesGeometryHint`（走**真实** Coordinator 路径，取代初稿里那条自己手动置位的假测试） |

**R2（`0d8aa07`）= needs-attention，1 high + 1 medium，两条都是真 finding、已全修**：

| 轮 | 级别 | finding | 我的处置 |
|---|---|---|---|
| R2 | high | 新写的源码守卫读**原始文件文本**，而计划自己指示写的**承重注释**恰好包含被禁词：`DrawingTypeOverlay` 注释写「不是 `activeDrawingTool == nil`」而守卫禁 `activeDrawingTool`；底栏注释写「几何/`locked`/唯一性」而守卫禁 `lock`；面板注释写「与 `engine.drawings` 里的真值漂移」而守卫禁 `engine.`。**照计划实施必然 `swift test` 红**，而绕过它的方式是删掉承重注释 | **全采纳**。立 **PD7 文本来源纪律**（否定/结构断言 → `squeezedSource` 剥注释剥字面量；用户可见文案 → 原始文本 + 完整调用语法锚；「陈旧注释必须删」→ 原始文本且写明它测的是注释），并把新写的 8 条守卫 + 改动的 3 条既有守卫**逐条**按表归位。另把「禁止图标名黑名单」换成**结构计数**（「底栏恰好 2 个 `Button`」）——黑名单既漏又误伤注释 |
| R2 | medium | Catalyst 的 🗑 置灰测试**是恒真的**：唯一断言是「渲染没触发闭包」，删掉 `.disabled(!deleteEnabled)` 照样过。而 🗑 是本切片唯一的破坏性入口 | **全采纳**。改成真读渲染出来的 `accessibilityTraits.notEnabled`（含**前提自足断言**「先证明找到了那个元素」+ 反向对照「enabled 时不得 notEnabled」防一律置灰骗过），并写死一条出路约束：Catalyst 变异**杀不死它**就必须换探测方式或**整条删掉 + 如实记录 gap**，**不许留一条杀不死的测试** |

**R3（`4f6d1ec` 前一提交）= needs-attention，1 high + 1 medium，两条都是真 finding、已全修**：

| 轮 | 级别 | finding | 我的处置 |
|---|---|---|---|
| R3 | high | Task 7 Step 8 号称是 iOS 构建门，命令块却**只打印 branch/HEAD 并 grep `app-build.yml`**，从没调用过 xcodebuild，就直接写下 Expected `BUILD SUCCEEDED` → **这道必需门根本不执行**。而本切片大改 SwiftUI 签名与 `TrainingView` 调用点，恰恰最可能只在 app scheme 上炸 | **全采纳**。把 `.github/workflows/app-build.yml:41-51` 的**真实**命令与三条闸门 grep 逐字嵌进去（只加 `-pr4` 路径后缀），并保留一条「先 grep workflow 确认命令没漂移」的前置检查 |
| R3 | medium | Catalyst 的 `coordinatorPublishesRenderedViewport` **杀不死** Task 7 变异 #2：`preview()` 的每根 K 线都是 `high:11/low:9`（已实测 `TrainingEngine.swift:1417`）→ 聚合分支即使触发，合成 partial 与原 aggregate 的 high/low **相同** → `priceRange` 不变 → `make(...).viewport == makeViewport(...)`。于是「重推视口会分叉」这条 **PD1 的前提本身没有测试**，只是一段源码阅读结论 | **全采纳**。补两道：① **host** 测试 `renderedViewportDivergesFromReDerivation` —— 自造「aggregate 自报宽区间(30/1)、已揭示 m3 前缀是窄区间(11/9)」的 fixture，断言 `make` 的视口与 `makeViewport` 重推的**真的不等**，且带自足断言（两个视口都不许退化成 `.empty`）与「造不出分叉就停下报告」的出口；② 源码守卫 `publisherUsesRenderedViewportOnly` —— 发布必须来自 `newState.viewport` 且 `ChartContainerView` 代码里**不许出现 `makeViewport`**，这条**确定**能杀死变异 #2。变异表已改注，明写「不要指望那条 Catalyst 相等断言杀它」 |

**R4 = needs-attention，1 high + 1 medium，两条都是真 finding、已全修**：

| 轮 | 级别 | finding | 我的处置 |
|---|---|---|---|
| R4 | high | **Task 排序错**：Task 2 Step 6c 往 `DrawingInteractionUISourceGuardTests.swift` **追加**守卫，而该文件我排在 **Task 4 才创建** → 实施者要么编译失败、要么静默丢掉这条守卫、要么被 Task 4 建文件时覆盖掉。而它正是「不许发布重推视口」的**确定性防线**，丢了就把 R3 刚补上的几何/渲染分叉防护重新打开。另外 Task 2 的期望计数也没算上它 | **全采纳**。文件改由 **Task 2 Step 6c 创建**（文件头 + 两个共享 helper + 本条守卫），Task 4/5/6 一律**只追加**并明写「插在末尾 `}` 之前、不要重复写文件头」；Files 列表、文件结构表、期望计数全部同步（Task 1 收尾 1755、Task 2 收尾 1762） |
| R4 | medium | `codeTextPreservingBoundaries` 只把**真空白**折成空格，而 `scanCode` **剥掉注释/字面量时不产生任何边界** → `return/*x*/deleteDrawing`（合法 Swift）被压成 `returndeleteDrawing` → 裸标识符判据看到前一字符是 `n`、当成「更长标识符的尾巴」跳过 → **vend 漏检，第三层信任边界守卫在白名单文件内可被绕过** | **全采纳**。行注释 / 块注释 / 字符串字面量三处各补一次 `emitBoundary()`（抽成闭包共用，三处各写一遍必漏其一）。⚠️ **连带暴露我判据里的一个假阳性**：补了边界之后 `deleteDrawing/*c*/(id:)` 变成 `deleteDrawing (id:`，`(` 不再紧邻 → 一次正当调用会被误报成 vend（既有自检 a 当场红）。故判据同步改成 **①② 看紧邻字符（防把两个独立 token 粘成一个长标识符）、③ 跳空格再看 `(`**，并加自检 g3 双向钉死（紧贴注释的 vend 必被抓、紧贴注释的调用不得误报、`deleteDrawing Foo` 与 `deleteDrawingForTesting` 各自判对） |

**R5 = needs-attention，1 条 high（无 medium），真 finding、已修**：

| 轮 | 级别 | finding | 我的处置 |
|---|---|---|---|
| R5 | high | `selectionGeometryVisible` 用 `engine.drawings.first(where:)` 找目标，**绕过了 `RenderStateBuilder.visibleDrawings`** —— PR-3 刚建立的「命中集合 ≡ 渲染集合」唯一真相，它还含 `belongsToPanel`（D29 周期归属 + 同周期 fail-safe）与 `revealTick <= tick`。只重算几何那一半，等于把 D63 的**结构性**维度整个略过、改为依赖「切周期时别处会清选中」这个**事件** → 一条渲染不出也命不中的线，只要价位恰好映进 `selectedPanel` 就能过门，**可被改样式、可被不可逆删除** | **全采纳**。`uniqueSelected` 改从 `visibleDrawings(engine:panel:tick:)` 取（四个谓词 + 两条路由 + `panelStyle` 全部继承结构维度）；`syncSelectionByExistence` → `syncSelectionByState`，判据换成 D64 原文那个析取式「结构性不含 **或** 存在性缺失」——`visibleDrawings` 不含该 id 已一并覆盖两项，一个谓词表达完整语义。补两条测试：`structurallyInvisibleIsAlwaysGated`（渐显未到 / 陈旧 selectedPanel 两种形状，各断言四个谓词 + 两条路由全判死且零改动）与 **`geometricallyInvisibleStaysStructurallyPresent`（防修过头）**——`visibleDrawings` 无 mapper、只判结构，几何性不可见的线**仍在**集合里，选中不抖、面板照常回显（否则就把 D63 退化成 codex 当初被 spec 明确拒绝的那个处方） |

**如实记录**：我没能构造出**当前可达**的洞（选中只能由 hitTest 产生、而 hitTest 就走 `visibleDrawings`；切周期已在 PR-3 清选中）→ 这是**纵深加固**，不是已证实的 live bug。但修法极小、严格更安全，且正是 spec 自己的纪律：D64 说「能从状态算出来的就不要靠事件传递」——我对**存在性**维度守了，对**结构性**维度没守。
⚠️ 本轮修复**差点重犯 R4-F1 的排序错误**两次（`uniqueSelected` 被 Task 2 依赖却定义在 Task 3；两条新测试用了 Task 3 的谓词却被我放进 Task 2）——已各自归位。

## 收口 = **user override（非 approve），如实记录**

codex 计划评审（`branch-diff`，无 `--focus` 窄化）跑了 **R1–R5 共 5 轮、从未 approve**；账本**无 approve 条目**（needs-attention 时脚本拒写，未伪造）。user 2026-08-05 裁决 **停止计划评审、进实施**，approve 目标移到 whole-branch。override 理由：

1. **严重性稳步递减**：R1 会回归用户可见能力（无选中时面板全灰）→ R2 守卫照做必红 + 恒真测试 → R3 门不执行 → R4 排序与扫描器边界 → R5 我**构造不出当前可达路径**的纵深加固。
2. **9 条 finding 全是真的、全已修**，且每轮都在挖**新机制**——无自相矛盾、无复述已接受决策，不构成 [[feedback_codex_round6_self_contradiction]] 的停止信号；停在这里是**成本判断**，不是「它开始胡说了」。
3. **纯计划分支在本仓 codex 0 战 3 负、从未 approve**（PR-1 计划 9 轮、PR-2 计划 24 轮后配额耗尽转 Opus、PR-3 计划 7 轮且 R7 是范畴误判「分支没有实现代码」）→ 在此等 approve 历史上无依据。
4. **后面还有四道关**：逐 task spec+质量双评审 → 三绿门 → whole-branch Opus → whole-branch codex。

---

**这九条都是我计划自身的缺陷，不是实施风险**——与 [[feedback_plan_code_blocks_cause_vacuous_tests]] 同族：F2 尤其典型，我在 PD2 里**写明了**「靠 engine observable 顺带刷新会滞后」，然后在谓词实现里**自己踩了同一个坑**（让 UI 读现算值，连滞后的机会都没有）。识别出陷阱 ≠ 避开陷阱，判据必须写成可被机械检查的形状——故本轮修复同时补了源码守卫，而不只是改代码。

顺带修掉的自查项：初稿 Catalyst 测试 `geometryHintFollowsViewport` **自己调 `setSelectionGeometryVisible` 再断言它变了** = 恒真测试（测的是 setter 而不是 Coordinator），已换成走真实 `rebuildRenderState` 路径并用 `drainMainQueue()` 等 async 跳转（不用固定时长 `sleep` 赌时序）。

---

## Self-Review（写完后自查记录）

**1. spec 覆盖**

| spec §1.1 交付项 | 落在 |
|---|---|
| #1 底栏 🗑（含 D65 删除谓词置灰） | Task 5 + Task 3 |
| #2 类型行 toggle（D38 / D57） | Task 4 |
| #3 选中（hitTest / D33 / 高亮 / 🗑 转亮） | **PR-3 已交付**；本期只把 🗑 亮灭接上（Task 5） |
| #4 改（5 组控件作用于选中线，D49 选中即回显） | Task 6 + Task 3（`panelStyle` / `applyStyle`） |
| #5 删（确认框「确定删除划线？[删除][取消]」） | Task 5 |
| #6 `drawingsRevision` | **PR-1 已交付** |
| #7 命中集合 ≡ 渲染集合 | **PR-3 已交付** |
| #8 复盘门控 | **PR-3 已交付**（`.select` 分支门）+ Task 4（结构不可达 + 纵深） |

| spec §6 负向测试 | 落在 |
|---|---|
| N1 回显是派生的 | Task 3 `panelStyleIsDerived` |
| N8 面板收起不清选中 | **无代码路径可改**——收起只切 `typeRowExpanded`，不碰 session；由验收 #19 覆盖 + Task 4 的 `stylePanelWillBeVisible` 守卫钉住判据 |
| N12b/c 候选预检与反向对照 | Task 3 |
| N13d locked 线仍可选中 | Task 3 `lockedDisablesBoth` 末条断言 |
| N14d UI 灰置分岔 | Task 3 `futureEnumLineSplitsPredicates` |
| N15 / N19a/d 源码守卫 0→1 | Task 3 Step 5 |
| N16b/c 几何性保留选中 + 恢复 | Task 3 `bothPredicatesFollowGeometry` / `predicatesRecover` |
| N16a 结构性清空 | **PR-3 已交付**（`restoreDrawingSessionAfterPeriodChange`） |
| N16d 判据同源 | Task 3 Step 5 的路由几何守卫 |
| N17 失败原因 × 选中生命期 | Task 3 `selectionLifetimeByExistenceOnly` |
| N18a/b/c/d | Task 3（d 由 `panelStyle` 不受谓词影响保证：`panelStyle` 不读任何谓词）；置灰读的是 UI 版谓词（PD2） |
| 验收 #13 无选中改默认 | Task 3 `noSelectionKeepsStyleControlsUsable`（codex R1-F1 补） |
| 验收 #18c 平移到看不见就变灰 | Task 2 `coordinatorRefreshesGeometryHint`（Catalyst 真路径）+ Task 3 `displayReadsHintWhileRouteRecomputes`（codex R1-F2 补） |
| PD1「重推视口会分叉」的**前提** | Task 2 Step 6b `renderedViewportDivergesFromReDerivation`（host）+ Step 6c 源码守卫（codex R3-F2 补） |
| N19c 几何门在路由 / N19e 时间窗 | Task 3 |
| N21c/d id 唯一 | Task 3 `duplicateIdsFailClosed` |
| N2–N7 / N10–N14 / N19b / N20 / N22 / N23 | **PR-1/PR-2/PR-3 已交付**（已 grep 确认在库） |

**2. 占位符扫描**：无 TBD / TODO / 「类似 Task N」/ 无代码的代码步骤。
计划初稿里我凭印象写的三个测试入口名（`seedDrawingsForTesting` / `seedLoadedDrawingsLossyForTesting` / `LossyDrawingArray.decode(from:)`）**全部是错的**，已逐条 grep 改成真名（`injectDrawingsForTesting` / `makeEngineWithLossy` + `lossyFromRaw` / `decode(_:)` 位置参数）——[[feedback_plan_embedded_facts_unreliable]] 的又一次实证：计划里嵌的**代码**能靠 dry-run 兜住，嵌的**事实**必须逐条实测。
仍留两处「实施时先读原文件再照抄」的指示（`app-build.yml` / `catalyst-build.yml` 的 xcodebuild 行），因为那两处是 CI workflow、会随基础设施变动，写死反而更危险。

**3. 类型一致性**：`DrawingEditRouter` 的 5 个入口（`selectionGeometryVisible` / `canEditStyle` / `canDelete` / `panelStyle` / `applyStyle` / `deleteSelected`）在 Task 2–6 中签名逐字一致；`DrawingSession` 新增的 4 个成员名在 Task 2/3/Coordinator 三处一致；`DrawingStyleParams(style:enabled:scheme:onChange:)` 在 Task 6 的实现、`DrawingStylePanel` 调用、守卫锚点三处一致。

**4. 已知会踩到的既有测试（本计划已逐条点名，实施时必然要改）**：`DrawingBottomBarHeightTests:42`、`DrawingStylePanelSourceGuardTests:27/85/232`、`DrawingSessionSourceGuardTests` 的 mutator 清单、`TrainingEngineDrawingSessionTests` 的两条信任边界守卫、`TrainingView.swift` 下方三个 `ChartPanelsContainer` 测试外壳。

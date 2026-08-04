# 划线 P1b-1b-i 切片3（PR-3）：命中与渲染层 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「命中集合 ≡ 渲染集合」抽成唯一真相函数，让选中态（`selectedPanel`+`selectedDrawingID` 二元组）落地并流进渲染态与高亮渲染，并第一次把 `hitTest` 接进生产 tap 路径（带复盘门控）——**零交互控件、用户看不到任何变化**。

**Architecture:** 三条互相咬合的边界。① `RenderStateBuilder.visibleDrawings(engine:panel:tick:)` 成为「某面板此刻看得见哪些线、按什么顺序」的**唯一**判据，渲染方原样消费、命中方逆序消费（D40/D33）。② 选中态是 `(selectedPanel, selectedDrawingID)` **二元组**，存在 1a-ii 建立的 `DrawingSession` 容器里，只在渲染 `selectedPanel` 那个面板时才带进 `KLineRenderState`（D41/D55）——只带 id 不带 panel 会让切周期迁走的线在用户没选的面板里继续高亮。③ `handleDrawingTap` 在**盾判定之后**按 `session.mode` 分叉：`.draw` 一字不改（保住复盘/训练的落线能力），`.select` 才走 hitTest 且**只有这一支**被 `flow.mode != .review` 门控（D34 trust-boundary；把门提到分叉之前 = 复盘画线功能回归）。

**Tech Stack:** Swift 6 / SwiftPM（`ios/Contracts`，`swift-tools-version: 6.0`）· Swift Testing（`@Test` / `#expect`）· CoreGraphics（渲染与命中，无 UIKit）· UIKit（仅 `KLineView` / `ChartContainerView.Coordinator`，Catalyst `xcodebuild test` 才真跑）· `@Observable` + `@MainActor`

---

## Global Constraints

以下每一条对**每个** Task 都隐含生效。数值逐字取自 spec / 实测，不得改写。

- **契约**：`CONTRACT_VERSION` 保持 **1.12**、`user_version` 保持 **7**、**零迁移**。`DrawingObject` **不新增、不修改任何持久化字段**；选中态是**瞬时 UI 状态**，绝不进任何存储路径（D55 / spec §5）。
- **base**：`f21cca1`（= main，含 PR-2 #154）。分支 `drawing-tools-p1b-1b-i-pr3`，worktree `.claude/worktrees/drawing-p1b-1b-i-pr3`。
- **本切片零交互控件**：不做 🗑 键、不做确认框、不做类型行 toggle、不让样式面板作用于选中线 —— **全属 PR-4**。不做 🔒 / 撤销 / `setDrawingLocked` —— **全属 1b-ii**。
- **PR-2 的两条零调用点守卫必须保持绿**：`TrainingEngineDrawingSessionTests.updateDrawingStyleTrustBoundary`（`updateDrawingStyle(` 在 `Sources/` 零调用点、`filesMentioning("updateDrawingStyle")` 只许出现在 `TrainingEngine.swift`）与 `deleteByIdTrustBoundary`（`deleteDrawing(id:` / `deleteDrawing(at:` 零调用点、`filesMentioning("deleteDrawing")` 白名单 = `TrainingEngine.swift` + `DrawingToolManager.swift`）。→ **本切片的任何新代码、新注释都不得提到这两个标识符**（守卫扫描剥注释，但 `filesMentioning` 按标识符扫剥注释后的代码；注释里提到是安全的，但仍不要写，避免评审误读）。
- **Catalyst 闸门基线**（实测）：`total` = **1625**（`.github/scripts/catalyst-total-baseline.txt`）、`uikit` = **59**（`.github/scripts/catalyst-uikit-baseline.txt` 行数）、G7 容差 `DELTA` = **30**（`catalyst-gate.sh:227`）。本切片**新增 UIKit-gated 测试** →
  - `catalyst-uikit-baseline.txt` **无条件必须重新生成**（`python3 .github/scripts/uikit-expected-tests.py > …`，禁手打测试名）——它与 total 是否漂移**无关**：`catalyst-gate.test.sh:47-65` 会对当前源码活推导并与基线**逐行比对**，不一致即自测 FAIL；
  - uikit 基线一改，`fixtures/pass-main-current.log` **必须用一份真 fresh Catalyst 日志脚本逐行重裁，禁手打伪造行**（`catalyst-gate.test.sh:379-380` 的维护规则）；
  - `catalyst-total-baseline.txt` **只在** total 漂出 `1625 ± 30` 时才动。
  - ⚠️ `catalyst-gate.sh` **不跑 xcodebuild**（`:24` `LOG="${1:?usage: catalyst-gate.sh <log-path>}"`）——必须自己先跑 `xcodebuild test` 产出日志再把路径传给它。完整命令见 Task 7。
- **host 基线**（实测，PR-2 合并后 main）：待 Task 0 亲跑确认；PR-2 收尾时本地是 `1726 passed / 212 skipped`。
- **命名一致性**（后续 Task 依赖，不得改名）：`visibleDrawings(engine:panel:tick:)` / `DrawingHitTester.firstHit(in:point:mapper:tools:)` / `DrawingSession.setSelection(id:panel:)` / `DrawingSession.clearSelection()` / `DrawingSession.selectedDrawingID` / `DrawingSession.selectedPanel` / `KLineRenderState.selectedDrawingID` / `DrawingColorResolver.selectionRGBA(scheme:)` / `DrawingTool.render(ctx:mapper:drawing:scheme:isSelected:)`。
- **访问级别纪律**（1a-ii 起，`DrawingSession.swift:21-28` 大注释）：容器的**状态**是 `public private(set)`，**mutator 一律 internal**（前面不加 `public`）。新增的 `setSelection` / `clearSelection` 同样 internal，并纳入既有源码守卫。
- **fail-closed 门必须限定到它真适用的那一类**（PR-1 `.segment` 门误管所有工具 → 非水平线被静默丢弃的教训）：复盘门只包 `.select` 分支，不包整个 tap 处理器。
- **测试判别力**：每条新测试都要做一次**变异验证**（把被测那行改坏 → 测试必须红 → 再改回来）。「测试写了却测不到」是本项目反复踩的坑，读代码发现不了。

---

## 已核实的源码事实（对 `f21cca1` 实测，非从 spec 推断）

写计划前逐条 grep / 读文件核实过，实施时若与实际不符 **先停下报告**，不要硬改：

| 事实 | 位置 | 状态 |
|---|---|---|
| 渲染过滤是**内联**的，没有共享函数 | `Render/RenderStateBuilder.swift:67-71` | `visibleDrawings` 全仓不存在（`:77` 只有一句前瞻注释） |
| `belongsToPanel` 已是共享判据（D29 + 同周期 fail-safe） | `Render/RenderStateBuilder.swift:78-89` | `Sources/` 中唯一调用点就是 `:68` |
| `revealTick <= tick` 渐显判据 | `Render/RenderStateBuilder.swift:70` | `Sources/` 中只此一处（`:62` 是注释） |
| `KLineRenderState` **没有** selected 概念 | `Render/KLineRenderState.swift` 全 80 行 | 需新增字段 |
| `DrawingTool.render` **没有** `isSelected` 入参 | `Drawing/DrawingTool.swift:18` | 需破坏 protocol（D28/D55：源码 API 面不 bump 契约、不留 shim） |
| `hitTest` 协议 + 实现俱在，**生产零调用点** | `Drawing/DrawingTool.swift:19` / `Drawing/HorizontalLineTool.swift:97` | 只有测试调它 |
| 工具注册表是 `private static let` | `Render/KLineView.swift:44` | `private` = **文件作用域**，Coordinator 够不到 → 需降为 internal |
| `handleDrawingTap` 盾判定在 mapper 之前 | `Render/ChartContainerView.swift:287-291` | 分叉必须放在盾**之后**（D53） |
| `DrawingSession` 已有 `mode` / `setMode`，**无选中态** | `Drawing/DrawingSession.swift:41-49` | `setMode(` 在 `Sources/` **零调用点**（PR-4 才接） |
| `session.activate(tool:)` 唯一调用点 | `TrainingEngine.swift:1352`（`beginDrawingSession` 内） | 它会写 `mode = .draw` |
| `restoreDrawingSessionAfterPeriodChange` **无**清空选中 | `TrainingEngine.swift:426-434` | 本切片补（D57 表格末行） |
| 面板 period 唯一赋值点 | `TrainingEngine.swift:410-411`（`switchPeriodCombo` 内） | → 「结构性迁面板」只可能由切周期触发 |
| `endDrawingSessionIfActive` 会调 `deactivate()` | `TrainingEngine.swift:1368` | fail-closed 分支的清空由 `deactivate()` 兜住 |
| `preview()` 默认面板周期 | `TrainingEngine.swift:1402` 注释 + `previewCandles()` | upper=`.m60`、lower=`.daily`；`.m3` 为驱动序列 |
| `DrawingObject.init` 必填参数 | `Models/Models.swift:265-274` | `toolType` / `anchors` / `isExtended` / `panelPosition` 必填，其余有默认 |
| `DrawingID` | `Models/DrawingEnums.swift:4` | `typealias DrawingID = String` |
| `HorizontalLineToolTests` **不是** UIKit-gated | 该文件无 `#if canImport(UIKit)` | → `render` 像素测试可以放 host，只有 `drawDrawings` / Coordinator 测试才进 Catalyst |
| `wcagContrastRatio` 是 `private` | `Tests/.../ThemePaletteTests.swift:13` | 文件作用域 → 对比度测试**必须**写进 `ThemePaletteTests.swift` |
| `AccentColor.colorset` **没有自定义色值** | `ios/KlineTrainer/.../AccentColor.colorset/Contents.json` | 只有 `{"idiom":"universal"}` → `Color.accentColor` 落系统蓝 |

---

## 文件结构

**新建（2 个）**

| 文件 | 职责 |
|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingHitTester.swift` | D33/D40：在**渲染序**列表上逆序取第一个命中。纯 CoreGraphics、无 UIKit → host 可测 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingHitTesterTests.swift` | 上者的 host 测试（逆序 / 未注册工具 / 不可见几何） |

**修改（源码 8 个）**

| 文件 | 改动 |
|---|---|
| `Render/RenderStateBuilder.swift` | 抽 `visibleDrawings(engine:panel:tick:)`；`make` 消费它；`make` 派生 `selectedDrawingID` 二元组 |
| `Render/KLineRenderState.swift` | 新增 `public let selectedDrawingID: DrawingID?`（init 末位、默认 `nil`） |
| `Render/KLineView.swift` | `drawingTools` `private` → internal（唯一注册表，命中方复用）；`drawDrawings` 调用传 `selectedDrawingID` |
| `Render/KLineView+Drawing.swift` | `drawDrawings` 增 `selectedDrawingID:` 入参，按 id 派发 `isSelected` |
| `Render/ChartContainerView.swift` | `handleDrawingTap` 在盾之后按 `session.mode` 分叉；`.select` 支带复盘门 + hitTest + 选中/清空 |
| `Drawing/DrawingTool.swift` | `render` 增 `isSelected: Bool` |
| `Drawing/HorizontalLineTool.swift` | `render` 消费 `isSelected`：选中时换描边色 |
| `Drawing/DrawingColorResolver.swift` | 新增 `selectionRGBA(scheme:)` |
| `Drawing/DrawingSession.swift` | 新增 `selectedDrawingID` / `selectedPanel` + `setSelection` / `clearSelection`；`setMode` / `activate` / `deactivate` 清选中 |
| `TrainingEngine/TrainingEngine.swift` | `restoreDrawingSessionAfterPeriodChange` 追加 `clearSelection()` |

**修改（测试 6 个）**：`Drawing/DrawingProtocolTests.swift`、`Drawing/DrawDrawingsDispatchTests.swift`、`Drawing/SpecLiteralGuardTests.swift`（三个 `DrawingTool` 测试替身要跟着改签名）、`Drawing/HorizontalLineToolTests.swift`、`Drawing/DrawingSessionTests.swift`、`Drawing/DrawingSessionSourceGuardTests.swift`、`Render/RenderStateBuilderTests.swift`、`Render/KLineRenderStateTests.swift`、`Render/ChartContainerViewDrawingSessionTests.swift`、`TrainingEngineDrawingSessionTests.swift`、`ThemePaletteTests.swift`

---

## Task 0：基线确认（不写代码，不 commit）

**Files:** 无

- [ ] **Step 1: 确认工作区**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr3"
pwd; git rev-parse --abbrev-ref HEAD; git rev-parse HEAD; git status --porcelain
```

Expected：`branch = drawing-tools-p1b-1b-i-pr3`、`HEAD = f21cca1bbe4513ff9ed9bace01a09424a4a07ccd`、工作区干净。
⚠️ **每条闸门命令都要同时打印 branch/HEAD**（评审 subagent 在主仓 checkout 造成的假绿，本项目踩过）。

- [ ] **Step 2: 跑 host 基线并记下数字**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr3/ios/Contracts"
swift test 2>&1 | tail -5; echo "EXIT=$?"
```

Expected：`Test run with N tests ... passed`，**记下 N**（后续每个 Task 用它对账）。
⚠️ 判绿**读输出内容**，不看 exit code（管道会吞退出码，本项目踩过 2 次）。

---

## Task 1：抽 `visibleDrawings` —— 命中集合 ≡ 渲染集合的唯一真相（D40 / spec §3）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift:67-71`（内联 filter → 调共享函数）+ 新增函数
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`（追加）

**Interfaces:**
- Consumes: 既有 `RenderStateBuilder.belongsToPanel(_:panel:upperPeriod:lowerPeriod:) -> Bool`
- Produces: `@MainActor static func visibleDrawings(engine: TrainingEngine, panel: PanelId, tick: Int) -> [DrawingObject]`（internal；**返回渲染序**，数组序 = z-order，后画的在上）。Task 5 的命中方逆序消费同一函数。

- [ ] **Step 1: 写失败测试（5 条：渲染方等价 / review 两层叠加 / committed 层渐显 / 非 review 不叠加 / 判据单点守卫）**

追加到 `Render/RenderStateBuilderTests.swift` 的 suite 内（若该文件用 `@Suite struct`，加进同一个 struct）：

```swift
    // MARK: - D40（1b-i PR-3）：命中集合 ≡ 渲染集合

    @MainActor
    @Test("D40：make(...).drawings 与 visibleDrawings(...) **逐条相等** —— 渲染方原样消费共享函数")
    func renderStateDrawingsEqualsVisibleDrawings() {
        let e = TrainingEngine.preview()                       // upper=.m60 / lower=.daily
        let up = DrawingAnchor(period: .m60, candleIndex: 0, price: 10.3)
        let low = DrawingAnchor(period: .daily, candleIndex: 0, price: 10.7)
        #expect(e.appendDrawing(DrawingObject(id: "U", toolType: .horizontal, anchors: [up],
                                              isExtended: false, panelPosition: 0)) == true)
        #expect(e.appendDrawing(DrawingObject(id: "L", toolType: .horizontal, anchors: [low],
                                              isExtended: false, panelPosition: 1)) == true)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        for panel in [PanelId.upper, PanelId.lower] {
            let rs = RenderStateBuilder.make(engine: e, panel: panel, bounds: bounds)
            let vd = RenderStateBuilder.visibleDrawings(engine: e, panel: panel,
                                                        tick: e.tick.globalTickIndex)
            #expect(rs.drawings == vd, "\(panel) 的渲染集合必须**就是**共享函数的返回值")
        }
        // 分派正确（防两边都空导致上面恒真）
        #expect(RenderStateBuilder.visibleDrawings(engine: e, panel: .upper,
                                                   tick: e.tick.globalTickIndex).map(\.id) == ["U"])
        #expect(RenderStateBuilder.visibleDrawings(engine: e, panel: .lower,
                                                   tick: e.tick.globalTickIndex).map(\.id) == ["L"])
    }

    @MainActor
    @Test("D40：review 下叠加**两层** —— 原训练线 drawings + 复盘新画线 reviewDrawings，顺序 committed 在前")
    func visibleDrawingsOverlaysBothLayersInReview() {
        let r = TrainingEngine.preview(mode: .review)          // upper=.m60 / lower=.daily
        let a = DrawingAnchor(period: .m60, candleIndex: 0, price: 10.3)
        // ⚠️ **两层都必须种上**：只测 reviewDrawings 那一半的话，一个漏掉 `engine.drawings +` 的
        //    `visibleDrawings` 实现照样全绿，而它会让**复盘里原训练线整片消失**（codex plan-R2-F2）。
        //    review 模式下 `appendDrawing` 被 `flow.mode != .review` 拒（`TrainingEngine.swift:1147`），
        //    故 committed 层用 DEBUG 注入钩子 `injectDrawingsForTesting`（`TrainingEngine.swift:1442`）种。
        r.injectDrawingsForTesting([DrawingObject(id: "TRAIN", toolType: .horizontal, anchors: [a],
                                                  isExtended: false, panelPosition: 0, revealTick: 0)])
        #expect(r.drawings.map(\.id) == ["TRAIN"])              // 前提：committed 层真的种进去了
        #expect(r.appendReviewDrawing(DrawingObject(id: "LATE", toolType: .horizontal, anchors: [a],
                                                    isExtended: false, panelPosition: 0,
                                                    revealTick: 5)) == true)
        // tick=0：复盘线未揭示 → 只剩原训练线（**这一条钉死 committed 层没被丢**）
        #expect(RenderStateBuilder.visibleDrawings(engine: r, panel: .upper, tick: 0).map(\.id) == ["TRAIN"])
        // tick=5：两层都在，顺序 = drawings 在前、reviewDrawings 在后（渲染序 = z-order，复盘线画在上面）
        #expect(RenderStateBuilder.visibleDrawings(engine: r, panel: .upper, tick: 5).map(\.id) == ["TRAIN", "LATE"])
    }

    @MainActor
    @Test("D40：渐显门对**两层一视同仁** —— committed 层的 revealTick 同样生效，不是无条件放行")
    func revealGateAppliesToCommittedLayerToo() {
        let r = TrainingEngine.preview(mode: .review)
        let a = DrawingAnchor(period: .m60, candleIndex: 0, price: 10.3)
        r.injectDrawingsForTesting([DrawingObject(id: "TRAIN_LATE", toolType: .horizontal, anchors: [a],
                                                  isExtended: false, panelPosition: 0, revealTick: 4)])
        #expect(r.drawings.map(\.id) == ["TRAIN_LATE"])        // 前提成立
        #expect(RenderStateBuilder.visibleDrawings(engine: r, panel: .upper, tick: 3).isEmpty,
                "revealTick=4 在 tick=3 时未揭示 —— committed 层也要过渐显门")
        #expect(RenderStateBuilder.visibleDrawings(engine: r, panel: .upper, tick: 4).map(\.id) == ["TRAIN_LATE"])
    }

    @MainActor
    @Test("D40：**非** review 模式不叠加 reviewDrawings（叠加层是 review 专属）")
    func visibleDrawingsExcludesReviewLayerOutsideReview() {
        let n = TrainingEngine.preview(mode: .normal)
        let a = DrawingAnchor(period: .m60, candleIndex: 0, price: 10.3)
        #expect(n.appendDrawing(DrawingObject(id: "N", toolType: .horizontal, anchors: [a],
                                              isExtended: false, panelPosition: 0)) == true)
        // normal 模式下 `appendReviewDrawing` 走不通 → 用 DEBUG 钩子直接置（`TrainingEngine.swift:1437`），
        // 否则 reviewDrawings 恒空、"不叠加" 这条断言恒真 = 什么也没测到。
        n.setReviewDrawingsForTesting([DrawingObject(id: "R", toolType: .horizontal, anchors: [a],
                                                     isExtended: false, panelPosition: 0, revealTick: 0)])
        #expect(n.reviewDrawings.map(\.id) == ["R"])           // 前提成立（防恒真）
        #expect(RenderStateBuilder.visibleDrawings(engine: n, panel: .upper, tick: 9).map(\.id) == ["N"],
                "非 review 模式绝不能把复盘层混进渲染/命中集合")
    }

    @Test("D40 源码守卫：可见性判据在 Sources/ 中**各只出现一次**（不得各写一遍）")
    func visibilityCriteriaAreSinglePoint() throws {
        // ① belongsToPanel 的调用点恰好 1 处（= visibleDrawings 内），且在 RenderStateBuilder.swift
        let belongs = try callSiteCount("belongsToPanel(")
        #expect(belongs.count == 1, "belongsToPanel 的调用点不是 1 处：\(belongs)")
        #expect(belongs.first?.file.hasSuffix("/Render/RenderStateBuilder.swift") == true)
        #expect(belongs.first?.count == 1)
        // ② revealTick 渐显判据整个 Sources/ 只出现一次
        var revealHits: [(String, Int)] = []
        for path in try allSwiftFilesUnderSources() {
            let n = try squeezedSource(path).components(separatedBy: squeeze("revealTick <= tick")).count - 1
            if n > 0 { revealHits.append((path, n)) }
        }
        #expect(revealHits.count == 1, "revealTick 渐显判据出现在多处：\(revealHits)")
        #expect(revealHits.first?.0.hasSuffix("/Render/RenderStateBuilder.swift") == true)
        #expect(revealHits.first?.1 == 1)
        // ③ 自足断言：扫描器真的扫到东西了（防扫描根写错 → 空集合 → 上面恒真）
        #expect(try !allSwiftFilesUnderSources().isEmpty)
    }
```

⚠️ 上面用到的两个 DEBUG 钩子已对源码核实存在（`TrainingEngine.swift` 末尾 `#if DEBUG extension TrainingEngine`）：
- `injectDrawingsForTesting(_ ds: [DrawingObject])`（`:1442`，注释原文「仅测试：直接置换 `drawings`，绕过全部写入门」，**不动 `drawingsRevision`**）
- `setReviewDrawingsForTesting(_ drawings: [DrawingObject])`（`:1437`）

实施第一步仍先 `grep -n "ForTesting" ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` 确认签名没变；**不得**为这几条测试新开任何生产写入面。

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "…/ios/Contracts" && swift test --filter RenderStateBuilder 2>&1 | tail -20
```

Expected：编译失败，`value of type 'RenderStateBuilder' has no member 'visibleDrawings'`。

- [ ] **Step 3: 抽出共享函数**

在 `RenderStateBuilder.swift` 的 `belongsToPanel` **上方**插入：

```swift
    /// **D40（1b-i PR-3）：命中集合 ≡ 渲染集合的唯一真相。** 返回某面板此刻看得见的画线，**按渲染序**
    /// （数组序 = z-order，后画的在上）。渲染方（`make`）**原样消费**；命中方（`DrawingHitTester`）
    /// `.reversed()` 后取第一个命中（D33 最上层优先）。
    /// 三条判据只在这里出现一次，**不得在别处再写一遍**（spec §3）：
    ///   ① review 叠加层（只读原训练线 `drawings` + 复盘新画线 `reviewDrawings`）；
    ///   ② `belongsToPanel`（D29 周期绑定 + `upper.period == lower.period` 损坏态下退回 `panelPosition`）；
    ///   ③ `revealTick <= tick` 渐显。
    /// 各写一遍的后果不是"多一份代码"：同周期 fail-safe 那个损坏态下，点一个面板会命中甚至（PR-4 起）
    /// 删除**渲染在另一个面板上**的线。
    @MainActor
    static func visibleDrawings(engine: TrainingEngine, panel: PanelId, tick: Int) -> [DrawingObject] {
        (engine.drawings + (engine.flow.mode == .review ? engine.reviewDrawings : [])).filter { drawing in
            belongsToPanel(drawing, panel: panel,
                           upperPeriod: engine.upperPanel.period, lowerPeriod: engine.lowerPanel.period)
                && drawing.revealTick <= tick
        }
    }
```

- [ ] **Step 4: 让 `make` 消费它**

把 `RenderStateBuilder.swift:53-74` 的 `return KLineRenderState(` 之前插入一行，并把 `drawings:` 那一整段（现 `:61-71`，含 4 行注释）替换掉：

```swift
        // review-redesign Task 3 / Task 10 的渐显与双层叠加语义**原样保留**，只是判据搬进了
        // `visibleDrawings`（D40 单一真相，1b-i PR-3）——渲染方从此原样消费，不再内联过滤。
        let visible = visibleDrawings(engine: engine, panel: panel, tick: tick)
        return KLineRenderState(
            panel: panelState,
            frames: ChartPanelFrames.split(in: bounds),
            viewport: renderViewport,
            visibleCandles: slice,
            volumeRange: volumeRange,
            macdRange: macdRange,
            markers: engine.markers,
            drawings: visible,
            crosshairPoint: crosshair,   // C8b：长按十字光标由 ChartContainerView.Coordinator 视图层透传（D3）
            previousCloseBeforeVisible: previousCloseBeforeVisible(candles: candles, startIndex: viewport.startIndex))
```

并把 `belongsToPanel` 文档注释里那句「1b-i 的命中集合 `visibleDrawings` 将复用本函数」改成「命中集合 `visibleDrawings`（1b-i PR-3）复用本函数」。

- [ ] **Step 5: 跑测试确认通过 + 全量不回归**

```bash
cd "…/ios/Contracts" && swift test 2>&1 | tail -5
```

Expected：全绿，总数 = Task 0 的 N + 5。

- [ ] **Step 6: 变异验证（3 次，逐条看红）**

| 变异 | 应该红的测试 |
|---|---|
| `visibleDrawings` 里删掉 `&& drawing.revealTick <= tick` | `revealGateAppliesToCommittedLayerToo` |
| `make` 改回内联 filter（`visibleDrawings` 保留但没人调） | `visibilityCriteriaAreSinglePoint`（`belongsToPanel` 变 2 处） |
| `visibleDrawings` 里去掉 review 三元式，恒 `engine.drawings` | `visibleDrawingsOverlaysBothLayersInReview` |

每次改坏 → 跑 → **确认真的红** → `git checkout -- <file>` 复原 → 再跑一次确认绿。

- [ ] **Step 7: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
git commit -m "划线 P1b-1b-i PR-3 T1：抽 visibleDrawings 共享函数（D40 命中集合 ≡ 渲染集合单一真相）"
```

---

## Task 2：选中态进 `DrawingSession`（D41 二元组 + D54 生命期）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift`（追加）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift:106`（mutator 列表扩两项）

**Interfaces:**
- Produces:
  - `public private(set) var selectedDrawingID: DrawingID?`
  - `public private(set) var selectedPanel: PanelId?`
  - `func setSelection(id: DrawingID, panel: PanelId)`（internal；`guard drawingModeActive, mode == .select`）
  - `func clearSelection()`（internal，无条件）
  - 不变量：**`mode == .draw` ⟹ `selectedDrawingID == nil`**

- [ ] **Step 1: 写失败测试**

追加到 `Drawing/DrawingSessionTests.swift`：

```swift
    // MARK: - 1b-i PR-3：选中态（D41 二元组 / D54 生命期）

    @MainActor
    @Test("选中是二元组：setSelection 同时写 id 与 panel；clearSelection 两个一起清")
    func selectionIsPanelIdPair() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.setMode(.select)
        s.setSelection(id: "A", panel: .lower)
        #expect(s.selectedDrawingID == "A")
        #expect(s.selectedPanel == .lower)
        s.clearSelection()
        #expect(s.selectedDrawingID == nil)
        #expect(s.selectedPanel == nil)          // 只清 id 不清 panel = 半个二元组，禁止
    }

    @MainActor
    @Test("D54/D57 不变量：mode == .draw 时选中恒为空（画线态选中不可表达）")
    func drawModeCannotHoldSelection() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        #expect(s.mode == .draw)                 // 前提成立：现在确实处在画线态
        // ① 画线态下 setSelection 直接被拒（fail-closed，不是"先设上再清掉"）
        s.setSelection(id: "A", panel: .upper)
        #expect(s.selectedDrawingID == nil)
        #expect(s.selectedPanel == nil)
        // ② 选择态设上 → 切回画线态 → 清空（D54 clause 2）
        s.setMode(.select)
        s.setSelection(id: "A", panel: .upper)
        #expect(s.selectedDrawingID == "A")
        s.setMode(.draw)
        #expect(s.selectedDrawingID == nil, "从选择态切回画线态必须清空选中（D54 clause 2）")
        #expect(s.selectedPanel == nil)
        // ③ 会话未开时也不许设（fail-closed）
        let t = DrawingSession()
        #expect(t.drawingModeActive == false)    // 前提成立：会话确实没开
        t.setSelection(id: "A", panel: .upper)
        #expect(t.selectedDrawingID == nil)
    }

    @MainActor
    @Test("D54 clause 1/2：activate 与 deactivate 都清空选中")
    func activateAndDeactivateClearSelection() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.setMode(.select)
        s.setSelection(id: "A", panel: .upper)
        #expect(s.selectedDrawingID == "A")      // 前提成立：不先钉这句，下面「被清空」恒真通过
        // activate 同工具（PR-4 的"点亮图标切回画线态"走这条）——D57 已让 mode 在幂等 guard 之前置 .draw
        s.activate(tool: .horizontal)
        #expect(s.mode == .draw)
        #expect(s.selectedDrawingID == nil, "activate 把 mode 打回 .draw，选中必须一起清")
        // deactivate（退出画线模式，D54 clause 1）
        s.setMode(.select)
        s.setSelection(id: "B", panel: .lower)
        #expect(s.selectedDrawingID == "B")      // 同上：前提成立
        s.deactivate()
        #expect(s.selectedDrawingID == nil)
        #expect(s.selectedPanel == nil)
        #expect(s.mode == .draw)
    }

    @MainActor
    @Test("N10 扩列：三个「清」语义对**选中态**的差分（discardPendingAnchors 不碰选中）")
    func threeClearSemanticsDifferOnSelection() {
        // discardPendingAnchors：只丢 pending 锚，**选中原样保留**
        let a = DrawingSession()
        a.activate(tool: .horizontal); a.setMode(.select); a.setSelection(id: "X", panel: .upper)
        a.discardPendingAnchors()
        #expect(a.selectedDrawingID == "X", "discardPendingAnchors 只管 pending 锚，不得顺手清选中")
        #expect(a.mode == .select)
        #expect(a.drawingModeActive == true)
        #expect(a.activeDrawingTool == .horizontal)
        // setMode：清选中、保工具与会话
        let b = DrawingSession()
        b.activate(tool: .horizontal); b.setMode(.select); b.setSelection(id: "X", panel: .upper)
        #expect(b.selectedDrawingID == "X")      // 前提成立：不先钉这句，下面「被清空」恒真通过
        b.setMode(.draw)
        #expect(b.selectedDrawingID == nil)
        #expect(b.drawingModeActive == true)
        #expect(b.activeDrawingTool == .horizontal)
        // deactivate：全清
        let c = DrawingSession()
        c.activate(tool: .horizontal); c.setMode(.select); c.setSelection(id: "X", panel: .upper)
        c.deactivate()
        #expect(c.selectedDrawingID == nil)
        #expect(c.drawingModeActive == false)
        #expect(c.activeDrawingTool == nil)
    }

    @MainActor
    @Test("反向对照（防过度 fail-closed）：选择态下 setSelection 换选另一条 —— 直接替换，不需要先 clear")
    func selectionReplacesPreviousWithoutClearing() {
        let s = DrawingSession()
        s.activate(tool: .horizontal); s.setMode(.select)
        s.setSelection(id: "A", panel: .upper)
        s.setSelection(id: "B", panel: .lower)
        #expect(s.selectedDrawingID == "B")
        #expect(s.selectedPanel == .lower)
    }
```

在 `Drawing/DrawingSessionSourceGuardTests.swift:106` 的 mutator 列表里追加两项：

```swift
        for m in ["func activate(", "func deactivate(", "func discardPendingAnchors(",
                  "func addAnchor(", "func commitPending(", "func setDefaultStyle(",
                  "func setSelection(", "func clearSelection("] {     // ← 1b-i PR-3 新增两个 mutator
```

并在同一 `@Test` 末尾追加（只读态必须仍 public，PR-4 的底栏与渲染方要读）：

```swift
        #expect(code.contains("public private(set) var selectedDrawingID"))
        #expect(code.contains("public private(set) var selectedPanel"))
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "…/ios/Contracts" && swift test --filter DrawingSession 2>&1 | tail -20
```

Expected：编译失败，`has no member 'setSelection'`。

- [ ] **Step 3: 实现**

在 `DrawingSession.swift` 的 `mode` 声明（`:42`）**下方**、`setMode`（`:46`）**上方**插入：

```swift
    /// D41（1b-i PR-3）：选中态是 **`(selectedPanel, selectedDrawingID)` 二元组**，与 `activeDrawingTool`
    /// 同源存在本容器里（底栏、样式面板、tap 处理读写**同一份**，任何一方都不得私存副本）。
    /// **只带 id 不带 panel 会出错**：D29 周期绑定下，一条线会随切周期从 `selectedPanel` 迁到**另一个**
    /// 面板——它全局仍在 `drawings` 里，id-only 判据会让它在用户没选的那个面板里继续高亮、继续可操作。
    /// **D55：瞬时 UI 状态，绝不落盘**（`DrawingObject` 不新增字段，本容器不进任何存储路径）。
    public private(set) var selectedDrawingID: DrawingID?
    public private(set) var selectedPanel: PanelId?

    /// D54：建立选中。**fail-closed**：非选择态 / 无会话一律拒——这让「画线态里挂着一个选中」
    /// 这个坏状态**不可表达**（而不是靠每个调用点自觉先 setMode）。internal（同容器 mutator 纪律）。
    func setSelection(id: DrawingID, panel: PanelId) {
        guard drawingModeActive, mode == .select else { return }
        selectedDrawingID = id
        selectedPanel = panel
    }

    /// D54：清空选中。**二元组整体清**（只清 id 会留下半个二元组）。
    /// ⚠️ 判据一律是**状态**（态变了 / 结构性不可见 / id 不在 `drawings` 里），
    /// **绝不是**「某个写入 API 返回了 false」（D64；写入 API 的接线属 PR-4）。
    func clearSelection() {
        selectedDrawingID = nil
        selectedPanel = nil
    }
```

改 `setMode`（`:46-49`）：

```swift
    /// D57：切换画线/选择态。切 `.select` 保留 activeDrawingTool、丢 pending（半成品多锚线不跨态存活）。
    /// D54 clause 2（1b-i PR-3）：**任何一次态切换都清空选中** —— 切回 `.draw` 时必须清（画线态不该有选中）；
    /// 切进 `.select` 时本来就没有可清的，无条件清让不变量「`mode == .draw` ⟹ 选中为空」由构造保证。
    /// internal（同容器 mutator 纪律）。
    func setMode(_ m: DrawingSessionMode) {
        mode = m
        clearSelection()
        discardPendingAnchors()
    }
```

改 `activate(tool:)`（`:105-111`）—— **在 `mode = .draw` 那一行下面**加一行：

```swift
    func activate(tool: DrawingToolType) {
        drawingModeActive = true
        mode = .draw                              // ← 在幂等 guard 之前（D57，否则选择态点回同工具态切不回）
        clearSelection()                          // ← D54 clause 2：跟着 mode 走，同样必须在幂等 guard 之前
        guard activeDrawingTool != tool else { return }
        activeDrawingTool = tool
        discardPendingAnchors()
    }
```

⚠️ **`clearSelection()` 必须在 `guard activeDrawingTool != tool else { return }` 之前**——PR-4 的「点亮同一个工具图标切回画线态」正是同工具重复 activate，放在 guard 之后会被吞掉，选中留在画线态里 = 本 Task 要消灭的坏状态。

改 `deactivate()`（`:115-121`）—— 在 `mode = .draw` 下面加一行：

```swift
        mode = .draw                              // 复位，防下次开会话继承旧态
        clearSelection()                          // D54 clause 1：退出画线模式即清空选中
```

- [ ] **Step 4: 跑测试确认通过 + 全量不回归**

```bash
cd "…/ios/Contracts" && swift test 2>&1 | tail -5
```

Expected：全绿，总数 = 上一 Task + 5。

- [ ] **Step 5: 变异验证（4 次）**

| 变异 | 应该红的测试 |
|---|---|
| `setSelection` 去掉 `mode == .select` 条件 | `drawModeCannotHoldSelection` |
| `activate` 里把 `clearSelection()` 挪到幂等 guard **之后** | `activateAndDeactivateClearSelection` |
| `clearSelection` 只清 `selectedDrawingID` 不清 `selectedPanel` | `selectionIsPanelIdPair` |
| `discardPendingAnchors` 里顺手加 `clearSelection()` | `threeClearSemanticsDifferOnSelection` |

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift
git commit -m "划线 P1b-1b-i PR-3 T2：选中态二元组进 DrawingSession（D41/D54，画线态选中不可表达）"
```

---

## Task 3：选中态流进 `KLineRenderState`（D41 / D55 二元组门 + 不落盘）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineRenderState.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift`（`make` 的 `return` 追加一个入参）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift:184-185`（订阅锚点追加两行）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/KLineRenderStateTests.swift`（追加）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`（追加）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift:143-152`（订阅守卫扩两条）

**Interfaces:**
- Consumes: Task 2 的 `DrawingSession.selectedDrawingID` / `selectedPanel`
- Produces: `KLineRenderState.selectedDrawingID: DrawingID?`（`public let`，init 末位、默认 `nil`）；`make` 的派生规则 `selectedPanel == panel ? selectedDrawingID : nil`

- [ ] **Step 1: 写失败测试**

追加到 `Render/KLineRenderStateTests.swift`：

```swift
    @Test("D55：selectedDrawingID 默认 nil —— 既有 init 调用点一律不受影响（源码兼容）")
    func selectedDrawingIDDefaultsToNil() {
        #expect(KLineRenderState.empty.selectedDrawingID == nil)
    }
```

追加到 `Render/RenderStateBuilderTests.swift`：

```swift
    @MainActor
    @Test("D41 二元组门：只有渲染 selectedPanel 那个面板时才带 selectedDrawingID 进渲染态")
    func selectedIDOnlyReachesItsOwnPanel() {
        let e = TrainingEngine.preview()                       // upper=.m60 / lower=.daily
        let up = DrawingAnchor(period: .m60, candleIndex: 0, price: 10.3)
        let low = DrawingAnchor(period: .daily, candleIndex: 0, price: 10.7)
        #expect(e.appendDrawing(DrawingObject(id: "U", toolType: .horizontal, anchors: [up],
                                              isExtended: false, panelPosition: 0)) == true)
        #expect(e.appendDrawing(DrawingObject(id: "L", toolType: .horizontal, anchors: [low],
                                              isExtended: false, panelPosition: 1)) == true)
        // ⚠️ 必须先喂两面板 renderBounds，否则 beginDrawingSession fail-closed 回滚、会话开不起来，
        //    setSelection 被 guard 挡下 → 测试假红。范式见 TrainingEngineDrawingSessionTests.swift:391。
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.beginDrawingSession(tool: .horizontal)
        #expect(e.drawingSession.drawingModeActive == true)   // 前提成立（防会话没开导致后面断言恒真）
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "U", panel: .upper)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(RenderStateBuilder.make(engine: e, panel: .upper, bounds: bounds).selectedDrawingID == "U")
        #expect(RenderStateBuilder.make(engine: e, panel: .lower, bounds: bounds).selectedDrawingID == nil,
                "选中属于 upper，lower 的渲染态绝不能带上它")
    }

    @MainActor
    @Test("D41：id-only 判据会出错的那个场景 —— 选中记在 upper，但该 id 现在归 lower 渲染 → 两个面板都不高亮")
    func staleSelectedPanelNeverHighlightsElsewhere() {
        let e = TrainingEngine.preview()
        let low = DrawingAnchor(period: .daily, candleIndex: 0, price: 10.7)
        #expect(e.appendDrawing(DrawingObject(id: "MIGRATED", toolType: .horizontal, anchors: [low],
                                              isExtended: false, panelPosition: 1)) == true)
        // ⚠️ 必须先喂两面板 renderBounds，否则 beginDrawingSession fail-closed 回滚、会话开不起来，
        //    setSelection 被 guard 挡下 → 测试假红。范式见 TrainingEngineDrawingSessionTests.swift:391。
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.beginDrawingSession(tool: .horizontal)
        #expect(e.drawingSession.drawingModeActive == true)   // 前提成立（防会话没开导致后面断言恒真）
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "MIGRATED", panel: .upper)   // 人为造出「线在 lower、选中记在 upper」
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        // lower：id 匹配但 panel 不匹配 → 不带（这正是"只带 id 不带 panel"会画错的那一条）
        #expect(RenderStateBuilder.make(engine: e, panel: .lower, bounds: bounds).selectedDrawingID == nil)
        // upper：panel 匹配，字段照带；那条线本就不在 upper 的 drawings 里 → 渲染方自然找不到、不会高亮
        let upper = RenderStateBuilder.make(engine: e, panel: .upper, bounds: bounds)
        #expect(upper.selectedDrawingID == "MIGRATED")
        #expect(upper.drawings.isEmpty)
    }

    @MainActor
    @Test("N7：选中态绝不落盘 —— 选中前后 DrawingObject 逐字段一致、契约仍 1.12")
    func selectionNeverPersists() {
        let e = TrainingEngine.preview()
        let a = DrawingAnchor(period: .m60, candleIndex: 0, price: 10.3)
        let original = DrawingObject(id: "P", toolType: .horizontal, anchors: [a],
                                     isExtended: false, panelPosition: 0)
        #expect(e.appendDrawing(original) == true)
        let before = e.drawings
        let revBefore = e.drawingsRevision
        // ⚠️ 必须先喂两面板 renderBounds，否则 beginDrawingSession fail-closed 回滚、会话开不起来，
        //    setSelection 被 guard 挡下 → 测试假红。范式见 TrainingEngineDrawingSessionTests.swift:391。
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.beginDrawingSession(tool: .horizontal)
        #expect(e.drawingSession.drawingModeActive == true)   // 前提成立（防会话没开导致后面断言恒真）
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "P", panel: .upper)
        // 前提成立：不先钉这两句，下面四条「不落盘」断言在 setSelection 变 no-op 时会**全部恒真通过**
        #expect(e.drawingSession.selectedDrawingID == "P")
        #expect(e.drawingSession.selectedPanel == .upper)
        #expect(e.drawings == before, "选中不得改动任何 DrawingObject")
        #expect(e.drawings.map(\.id) == before.map(\.id))
        #expect(e.drawingsRevision == revBefore, "选中不是内容变更，绝不能 bump revision（否则会触发 autosave）")
        #expect(CONTRACT_VERSION == "1.12")
    }
```

⚠️ `CONTRACT_VERSION` 的**实际标识符与类型**先核实再写：

```bash
grep -rn "CONTRACT_VERSION" ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift | head -3
```

若它不是裸常量（例如是 `Contracts.version` 之类），按实际写；对不上就**删掉这一行断言**（契约不变本来就由「没改任何持久化字段」保证），不要硬凑一个编译不过的断言。

- [ ] **Step 2: 跑测试确认失败**

Expected：`has no member 'selectedDrawingID'`。

- [ ] **Step 3: 给 `KLineRenderState` 加字段**

`KLineRenderState.swift`：字段区（`:24` 之后）加

```swift
    /// D41/D55（1b-i PR-3）：本面板此刻**被选中**的那条线的 id。**瞬时 UI 状态、不进任何存储路径**。
    /// `RenderStateBuilder.make` **只在渲染 `selectedPanel` 那个面板时**才带值，其余面板恒 nil
    /// （选中是 `(panel, id)` 二元组；只按 id 判会让切周期迁走的线在用户没选的面板里继续高亮）。
    public let selectedDrawingID: DrawingID?
```

init 签名末位追加 `selectedDrawingID: DrawingID? = nil,`（放在 `previousCloseBeforeVisible` **之后**，两者都有默认值 → 既有全部调用点零改动），body 追加 `self.selectedDrawingID = selectedDrawingID`。

⚠️ `Foundation` 已 import，`DrawingID` = `String` 在同模块，无需新 import。

- [ ] **Step 4: 让 `make` 派生二元组**

`RenderStateBuilder.make` 的 `return KLineRenderState(` 末尾追加：

```swift
            previousCloseBeforeVisible: previousCloseBeforeVisible(candles: candles, startIndex: viewport.startIndex),
            // D41/D55：选中是 `(selectedPanel, selectedDrawingID)` **二元组** —— 只在渲染 `selectedPanel`
            // 那个面板时才带 id 进渲染态。**只带 id 不带 panel 会出错**：D29 下一条线会随切周期迁到
            // 另一个面板，id-only 判据会让它在用户没选的那个面板里继续高亮、继续可操作。
            selectedDrawingID: engine.drawingSession.selectedPanel == panel
                ? engine.drawingSession.selectedDrawingID : nil)
```

- [ ] **Step 5: 建立选中态的 observation 订阅（否则**另一个**面板的旧高亮擦不掉，codex plan-R4-F1）**

从本 Task 起，`KLineRenderState` 依赖选中态 → **两个**面板的 `updateUIView` 都必须订阅它。风险是本仓踩过的同一个坑：SwiftUI 只订阅 `updateUIView` **执行时实际读到**的 `@Observable`，而 `rebuildRenderState` 的 `make` 在 `bounds <= 0` 时被守卫跳过 → 订阅根本没建立 → 图表冻结（`ChartContainerView.swift:176-185` 大注释记录了这次真机实证的回归）。

**具体危害**（codex 指出，成立）：选中态是**全局**的，但 `selectedDrawingID` 被**缓存在每个面板各自的 `KLineRenderState` 里**。先选中下面板一条、再选中上面板一条 → 会话状态正确，但下面板的 view 若不刷新，**旧高亮会一直留在屏幕上**（两条同时看起来被选中）。

修法 = **照抄该文件既有的订阅锚点范式**：在 `rebuildRenderState` 的 `bounds` 守卫**之前**无条件读一次选中二元组。

`ChartContainerView.swift:184-185` 之后追加：

```swift
            _ = (panel == .upper) ? engine.upperPanel.revision : engine.lowerPanel.revision
            _ = engine.tick.globalTickIndex
            // 1b-i PR-3：选中态进了 KLineRenderState（D41/D55）→ **两个面板**都必须订阅它，
            // 否则「在另一个面板选中」时，本面板缓存的旧 selectedDrawingID 不会被刷掉，旧高亮留在屏上。
            // 与上面两行同理由、同位置（bounds 守卫**之前**）：`make` 在 bounds<=0 时被跳过，
            // 把读取留在 make 里就等于首帧不订阅（`:176-185` 记录的那次真机冻结回归就是这么来的）。
            _ = engine.drawingSession.selectedPanel
            _ = engine.drawingSession.selectedDrawingID
```

并扩既有源码守卫 `DrawingSessionSourceGuardTests.rebuildRenderStateSubscribesToPanelState`（`:143-152`）——SwiftUI observation 行为**单测测不到**，本仓对这一类一贯用源码钉死防误删（该测试的 MARK 原文：「SwiftUI observation/view 行为单测测不到，只能源码钉死防误删」）：

```swift
        #expect(code.contains("engine.tick.globalTickIndex"))
        // 1b-i PR-3：选中二元组同样是订阅锚点（删掉任一行 → 在另一面板选中时本面板旧高亮擦不掉）
        #expect(code.contains("engine.drawingSession.selectedPanel"))
        #expect(code.contains("engine.drawingSession.selectedDrawingID"))
```

- [ ] **Step 6: 跑测试确认通过 + 全量不回归**

Expected：全绿，总数 = 上一 Task + 4。

- [ ] **Step 7: 变异验证（4 次）**

| 变异 | 应该红的测试 |
|---|---|
| `make` 改成 id-only（去掉 `selectedPanel == panel` 条件） | `selectedIDOnlyReachesItsOwnPanel` + `staleSelectedPanelNeverHighlightsElsewhere` |
| `make` 恒传 `nil` | `selectedIDOnlyReachesItsOwnPanel` |
| 删掉 `rebuildRenderState` 里那两行订阅锚点 | `rebuildRenderStateSubscribesToPanelState` |
| `setSelection` 里顺手 `drawingsRevision += 1`（模拟"选中当成内容变更"） | `selectionNeverPersists`（该变异需改引擎；若不便，改为在 `setSelection` 里改一条 `drawings` 元素） |

- [ ] **Step 8: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineRenderState.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/KLineRenderStateTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift
git commit -m "划线 P1b-1b-i PR-3 T3：选中二元组流进 KLineRenderState + 两面板订阅锚点（D41/D55）"
```

---

## Task 4：选中高亮渲染（D55）—— `DrawingTool.render` 增 `isSelected`

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift:18`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift:82-95`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingColorResolver.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift:16-25`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift:44, 106-109`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/HorizontalLineToolTests.swift`（追加，host）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/ThemePaletteTests.swift`（追加对比度，host）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift`（追加，**UIKit-gated**）
- Test（跟签名迁移）: `Drawing/DrawingProtocolTests.swift:61`、`Drawing/SpecLiteralGuardTests.swift:44`、`Drawing/DrawDrawingsDispatchTests.swift:181`

**Interfaces:**
- Consumes: Task 3 的 `KLineRenderState.selectedDrawingID`
- Produces:
  - `DrawingTool.render(ctx:mapper:drawing:scheme:isSelected:)`（**破坏源码 API 面**；按 D28 不 bump 契约、不留 shim，4 个 conformer 同 PR 迁完）
  - `DrawingColorResolver.selectionRGBA(scheme: AppColorScheme) -> AppColorRGBA`
  - `KLineView.drawingTools`（`private` → internal，供 Task 5 的命中方复用**同一张**注册表）
  - `KLineView.drawDrawings(ctx:mapper:drawings:period:scheme:selectedDrawingID:tools:)`

- [ ] **Step 1: 写失败测试**

追加到 `Drawing/HorizontalLineToolTests.swift`（host，复用文件内既有 `renderPixels` / `litColumn` / `mapper()`）：

```swift
    // MARK: - D55（1b-i PR-3）选中高亮

    @MainActor
    static func renderPixelsSelected(_ drawing: DrawingObject, scheme: AppColorScheme, isSelected: Bool)
        -> (data: [UInt8], w: Int, h: Int) {
        let w = 800, h = 360
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        HorizontalLineTool().render(ctx: ctx, mapper: Self.mapper(), drawing: drawing,
                                    scheme: scheme, isSelected: isSelected)
        return (data, w, h)
    }

    @MainActor
    @Test("D55：isSelected == true 时描边改用选中色；false 时仍是 colorToken 的色（同一条线两次渲染可区分）")
    func selectedStrokeUsesSelectionColor() {
        // ⚠️ `price: 15` / `period: .m3` 是本文件 `Self.mapper()` 的量纲（`priceRange(min:10,max:20)`，
        //    `:11-18` 实测；既有测试全用 15）。用 100 会让 `visibleGeometry` 返 nil → 一条线都画不出来，
        //    下面「必须画出了线」当场红（codex plan-R5-F2）。
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
                              isExtended: false, panelPosition: 0, colorToken: .orange)
        let normal = Self.renderPixelsSelected(d, scheme: .light, isSelected: false)
        let picked = Self.renderPixelsSelected(d, scheme: .light, isSelected: true)
        let cn = Self.litColumn(normal.data, w: normal.w, h: normal.h)
        let cp = Self.litColumn(picked.data, w: picked.w, h: picked.h)
        #expect(!cn.isEmpty, "对照组必须真的画出了线（否则下面的差异断言恒真）")
        #expect(!cp.isEmpty, "选中组必须真的画出了线")
        let expOrange = DrawingColorResolver.resolve(.orange, scheme: .light)
        let expSel = DrawingColorResolver.selectionRGBA(scheme: .light)
        #expect(cn.contains { abs($0.r - CGFloat(expOrange.red)) < 0.06 && abs($0.b - CGFloat(expOrange.blue)) < 0.06 })
        #expect(cp.contains { abs($0.r - CGFloat(expSel.red)) < 0.06 && abs($0.b - CGFloat(expSel.blue)) < 0.06 })
        #expect(expOrange != expSel, "选中色与 legacy 橙必须不同，否则高亮看不出来")
    }

    @MainActor
    @Test("D55：选中高亮只换颜色 —— 线宽 / 线型 / 几何一字不动")
    func selectionChangesColorOnly() {
        let d = DrawingObject(toolType: .horizontal,                 // 同上：15 在 mapper 的 10...20 内
                              anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
                              isExtended: false, panelPosition: 0,
                              lineStyle: .dash1, thickness: 4, colorToken: .orange)
        let normal = Self.renderPixelsSelected(d, scheme: .light, isSelected: false)
        let picked = Self.renderPixelsSelected(d, scheme: .light, isSelected: true)
        // 亮起来的像素**位置集合**必须完全一致（只有颜色变），故只比 alpha 通道
        let alphaN = (0..<(normal.w * normal.h)).map { normal.data[$0 * 4 + 3] > 76 }
        let alphaP = (0..<(picked.w * picked.h)).map { picked.data[$0 * 4 + 3] > 76 }
        #expect(alphaN.contains(true), "对照组必须真的画出了线")
        #expect(alphaN == alphaP, "选中不得改变线宽/dash/几何——亮起的像素位置必须逐点相同")
    }

    @Test("D55：选中色不占用 DrawingColorToken 值域（与 7 个彩色 + 自适应 ink 都不相等）")
    func selectionColorIsOutsideTokenRange() {
        for scheme in [AppColorScheme.light, .dark] {
            let sel = DrawingColorResolver.selectionRGBA(scheme: scheme)
            for token in DrawingColorToken.allCases {
                #expect(DrawingColorResolver.resolve(token, scheme: scheme) != sel,
                        "选中色撞上了 token \(token)（scheme \(scheme)）——高亮会与普通线混淆")
            }
        }
    }
```

⚠️ `DrawingColorToken.allCases` 先核实存在（`grep -n "CaseIterable" ios/Contracts/Sources/KlineTrainerContracts/Models/DrawingEnums.swift`）。不是 `CaseIterable` 就**手写 9 个 case 的数组**，不要给生产枚举加 `CaseIterable` 只为测试。

追加到 `ThemePaletteTests.swift`（紧挨 `drawingStrokeContrastWCAG`，为的是复用文件内 `private func wcagContrastRatio`）：

```swift
    @MainActor
    @Test("D55 选中高亮色 vs light/dark 底 对比 ≥ 3:1（图形元素阈，同 drawingStrokeContrastWCAG）")
    func selectionStrokeContrastWCAG() {
        #expect(wcagContrastRatio(DrawingColorResolver.selectionRGBA(scheme: .light),
                                  AppPalette.light.background) >= 3.0)
        #expect(wcagContrastRatio(DrawingColorResolver.selectionRGBA(scheme: .dark),
                                  AppPalette.dark.background) >= 3.0)
    }
```

追加到 `Drawing/DrawDrawingsDispatchTests.swift`（**UIKit-gated**，会让 uikit 基线 +2）：

```swift
    @Test("D55 dispatch：只有 id == selectedDrawingID 的那一条拿到 isSelected == true")
    func dispatchPassesIsSelectedForMatchingIDOnly() {
        let view = makeViewFixture()
        let spy = SpyDrawingTool()
        let a = DrawingAnchor(period: .m60, candleIndex: 5, price: 120)
        let d1 = DrawingObject(id: "A", toolType: .horizontal, anchors: [a], isExtended: false, panelPosition: 0)
        let d2 = DrawingObject(id: "B", toolType: .horizontal, anchors: [a], isExtended: false, panelPosition: 0)
        view.drawDrawings(ctx: makeCtxFixture(), mapper: makeMapperFixture(),
                          drawings: [d1, d2], period: .m60, scheme: .light,
                          selectedDrawingID: "B", tools: [.horizontal: spy])
        #expect(spy.received.map(\.isSelected) == [false, true])
    }

    @Test("D55 dispatch：selectedDrawingID == nil → 一条都不高亮")
    func dispatchNoSelectionHighlightsNothing() {
        let view = makeViewFixture()
        let spy = SpyDrawingTool()
        let a = DrawingAnchor(period: .m60, candleIndex: 5, price: 120)
        let d = DrawingObject(id: "A", toolType: .horizontal, anchors: [a], isExtended: false, panelPosition: 0)
        view.drawDrawings(ctx: makeCtxFixture(), mapper: makeMapperFixture(),
                          drawings: [d], period: .m60, scheme: .light,
                          selectedDrawingID: nil, tools: [.horizontal: spy])
        #expect(spy.received.map(\.isSelected) == [false])
    }
```

并把 `SpyDrawingTool`（`DrawDrawingsDispatchTests.swift:176-186`）的 `received` 元组扩一维：

```swift
    private(set) var received: [(drawing: DrawingObject, scheme: AppColorScheme, isSelected: Bool)] = []
    func render(ctx: CGContext, mapper: CoordinateMapper, drawing: DrawingObject,
                scheme: AppColorScheme, isSelected: Bool) {
        received.append((drawing, scheme, isSelected))
    }
```

- [ ] **Step 2: 跑测试确认失败**

Expected：编译失败（`selectionRGBA` 不存在 / `render` 参数不匹配）。

- [ ] **Step 3: 加选中色**

`DrawingColorResolver.swift` 末尾（`resolve` 之后、`}` 之前）加：

```swift
    /// D55（1b-i PR-3）：**选中高亮色**。与常驻面板类型图标的高亮框同源 —— 那里用 SwiftUI
    /// `Color.accentColor`（`UI/DrawingTypeOverlay.swift:28-29`），而 `AccentColor.colorset` 里
    /// **没有自定义色值**（实测 `Contents.json` 只有 `{"idiom":"universal"}`）→ 落系统蓝。
    /// 渲染层在包内、只有 CoreGraphics，取不到 asset catalog，故这里按系统蓝的两套取值内联；
    /// 不精确匹配也只是观感差异，不影响任何判据。
    /// **不占用 `DrawingColorToken` 值域**（与 9 个 token 的解析结果两两不等，`selectionColorIsOutsideTokenRange` 钉死）。
    /// 对比度：light 底 4.02:1 / dark 底 5.76:1，均 ≥3:1（图形元素阈，`selectionStrokeContrastWCAG` 测）。
    public static func selectionRGBA(scheme: AppColorScheme) -> AppColorRGBA {
        scheme == .dark ? AppColorRGBA(red: 0.039, green: 0.518, blue: 1.0)   // 夜：systemBlue dark
                        : AppColorRGBA(red: 0.0,   green: 0.478, blue: 1.0)   // 日：systemBlue light
    }
```

- [ ] **Step 4: 破 protocol + 迁 4 个 conformer**

`DrawingTool.swift:18`：

```swift
    /// `isSelected`（D55，1b-i PR-3）：该条是否处于选中态。**瞬时 UI 状态**，由渲染 dispatch 按
    /// `KLineRenderState.selectedDrawingID` 逐条派发，不来自 `DrawingObject` 任何持久化字段。
    /// 源码 API 面破坏按 D28 不 bump `CONTRACT_VERSION`、不留 shim（仓内模块、无外部 conformer）。
    func render(ctx: CGContext, mapper: CoordinateMapper, drawing: DrawingObject,
                scheme: AppColorScheme, isSelected: Bool)
```

`HorizontalLineTool.swift:82-95`：

```swift
    public func render(ctx: CGContext, mapper: CoordinateMapper, drawing: DrawingObject,
                       scheme: AppColorScheme, isSelected: Bool) {
        guard let g = Self.visibleGeometry(for: drawing, mapper: mapper) else { return }
        ctx.saveGState()
        // D55：选中高亮**只换描边色** —— 线宽 / dash / 几何一字不动（`selectionChangesColorOnly` 钉死），
        // 且不写回 `drawing.colorToken`（瞬时 UI 状态，绝不落盘）。
        let rgba = isSelected ? DrawingColorResolver.selectionRGBA(scheme: scheme)
                              : DrawingColorResolver.resolve(drawing.colorToken, scheme: scheme)
        ctx.setStrokeColor(...)   // 以下原样不动
```

**⚠️ 签名迁移必须一次扫全（codex plan-R3-F1：原稿只列了 conformer，漏了调用点 → 整个 Task 编译不过）。**
`render` 是 protocol requirement，Swift **不允许**在协议要求上给默认值 → **每一个** conformer 与**每一个**调用点都必须同 Task 迁完。`drawDrawings` 的 `selectedDrawingID` **刻意不给默认值**（给了默认值就等于允许未来某个调用点静默丢掉高亮）。

**实测的全部迁移点（对 `f21cca1` 逐条 grep 得到，共 11 处）**：

| 类别 | 位置 | 改法 |
|---|---|---|
| protocol 声明 | `Drawing/DrawingTool.swift:18` | 加 `isSelected: Bool` |
| 生产 conformer | `Drawing/HorizontalLineTool.swift:82` | 加 `isSelected: Bool` + 消费它 |
| 测试替身 ×3 | `Drawing/DrawingProtocolTests.swift:61` `FakeDrawingTool`／`Drawing/SpecLiteralGuardTests.swift:44` `SignatureGuardTool`／`Drawing/DrawDrawingsDispatchTests.swift:181` `SpyDrawingTool` | 加 `isSelected: Bool`（Spy 还要把 `received` 扩一维，见上） |
| `render` 旧调用点 ×3 | `Render/KLineView+Drawing.swift:25`（生产）／`Drawing/DrawingProtocolTests.swift:25`／`Drawing/HorizontalLineToolTests.swift:102`（既有 `renderPixels` helper） | 生产处传 `drawing.id == selectedDrawingID`；两处测试传 `isSelected: false`（保持既有行为） |
| `drawDrawings` 旧调用点 ×8 | `Render/KLineView.swift:106`（生产）＋ `Drawing/DrawDrawingsDispatchTests.swift:23, 41, 61, 80, 102, 127, 152` | 生产处传 `renderState.selectedDrawingID`；7 处既有测试传 `selectedDrawingID: nil`（保持既有行为） |

- [ ] **Step 4b: 旧签名清扫（commit 前必跑，输出必须为空）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr3"
# 旧 render 签名（scheme 之后直接收尾，没有 isSelected）
grep -rn "\.render(ctx:.*scheme: [^)]*)" ios/Contracts --include="*.swift" | grep -v "isSelected"
# 旧 drawDrawings 签名（没有 selectedDrawingID）
grep -rnA 4 "drawDrawings(" ios/Contracts --include="*.swift" | grep -v "func drawDrawings" | grep -B 4 "tools:" | grep -c "selectedDrawingID" 
```
Expected：第一条命令**无输出**；第二条的计数 == `drawDrawings` 调用点总数（8）。
⚠️ 别只靠 `swift build` 报错来找——`#if canImport(UIKit)` 里的调用点在 host 上**根本不编译**，host 绿不代表 Catalyst 绿（本项目踩过：UIKit-gated 代码两头落空）。这条清扫是 host 阶段唯一能抓到它们的手段。

- [ ] **Step 5: 接 dispatch**

`KLineView+Drawing.swift`：`drawDrawings` 签名在 `scheme:` 之后、`tools:` 之前插入 `selectedDrawingID: DrawingID?,`；循环体首行改：

```swift
        for drawing in drawings {
            guard let tool = tools[drawing.toolType] else { continue }
            // D55：逐条按 id 派发选中态。`selectedDrawingID` 已在 `RenderStateBuilder.make` 过了
            // 二元组门（只有 `selectedPanel` 那个面板才拿得到非 nil），此处不再判 panel。
            tool.render(ctx: ctx, mapper: mapper, drawing: drawing, scheme: scheme,
                        isSelected: drawing.id == selectedDrawingID)
```

`KLineView.swift:44` 去掉 `private`（并加注释说明为什么）：

```swift
    /// **唯一**的工具注册表：渲染 dispatch（`draw(_:)`）与命中 dispatch（`ChartContainerView.Coordinator`
    /// 的 `.select` 分支，1b-i PR-3）**共用它**。D40 要求命中与渲染同源 —— 各持一份注册表就意味着
    /// 「画得出却命不中」或反之。故这里是 internal 而非 private（`private` 在 Swift 是**文件作用域**）。
    static let drawingTools: [DrawingToolType: any DrawingTool] = [.horizontal: HorizontalLineTool()]
```

`KLineView.swift:106-109` 的调用补一个入参：

```swift
        drawDrawings(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
                     period: renderState.panel.period,
                     scheme: themeController.resolve(trait: traitCollection),
                     selectedDrawingID: renderState.selectedDrawingID,
                     tools: Self.drawingTools)
```

- [ ] **Step 6: 跑测试确认通过 + 全量不回归**

```bash
cd "…/ios/Contracts" && swift test 2>&1 | tail -5
```

Expected：全绿，host 总数 = 上一 Task + 4（两条 dispatch 测试是 UIKit-gated，host 上 skip）。

- [ ] **Step 7: 变异验证（4 次）**

| 变异 | 应该红的测试 |
|---|---|
| `HorizontalLineTool.render` 忽略 `isSelected`，恒用 token 色 | `selectedStrokeUsesSelectionColor` |
| 选中时顺手把 `lineWidth` 加粗 2pt | `selectionChangesColorOnly` |
| dispatch 写成 `isSelected: true`（恒真） | `dispatchNoSelectionHighlightsNothing` |
| `selectionRGBA` 改成 `resolve(.blue, scheme:)` | `selectionColorIsOutsideTokenRange` |

- [ ] **Step 8: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingColorResolver.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/HorizontalLineToolTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingProtocolTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/SpecLiteralGuardTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ThemePaletteTests.swift
git commit -m "划线 P1b-1b-i PR-3 T4：选中高亮渲染（D55 render 增 isSelected + 选中色不占 token 值域）"
```

---

## Task 5：`hitTest` 第一次接进生产路径（D33 / D34 / D37 / D40）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingHitTester.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingHitTesterTests.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift:292-306`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewDrawingSessionTests.swift`（追加 **10 条，全部 UIKit-gated**：复盘门正反两条 / D37 未命中清空（含渲染态断言）/ D54 画线态不 hitTest / 盾 × 选择态两条 / D40 路由行为级两条（未揭示线、他面板线）/ 选中高亮像素级端到端 / 跨面板 sibling 不残留高亮）

**Interfaces:**
- Consumes: Task 1 的 `visibleDrawings`、Task 2 的 `setSelection`/`clearSelection`、Task 4 的 `KLineView.drawingTools`
- Produces: `@MainActor enum DrawingHitTester { static func firstHit(in:point:mapper:tools:) -> DrawingObject? }`

- [ ] **Step 1: 写失败测试（host 部分）**

新建 `Drawing/DrawingHitTesterTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingHitTesterTests.swift
// Spec: docs/superpowers/specs/2026-07-23-drawing-tools-P1b-1b-i-select-edit-delete-design.md §3 / D33 / D40
// 命中判定的纯逻辑（无 UIKit → host 全跑）。真实 tap 路径的接线测试在
// Render/ChartContainerViewDrawingSessionTests.swift（UIKit-gated，Catalyst 才真跑）。

import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("DrawingHitTester（D33 逆序最上层优先 / D40 与渲染同源）")
struct DrawingHitTesterTests {

    static func mapper() -> CoordinateMapper {
        let viewport = ChartViewport(
            startIndex: 0, visibleCount: 80, pixelShift: 0,
            geometry: ChartGeometry(candleStep: 10, candleWidth: 7, gap: 3),
            priceRange: PriceRange(min: 90, max: 110),
            mainChartFrame: CGRect(x: 0, y: 0, width: 800, height: 200))
        return CoordinateMapper(viewport: viewport, displayScale: 2)
    }

    static func hLine(_ id: String, price: Double, sub: LineSubType = .straight,
                      candleIndex: Int = 5) -> DrawingObject {
        DrawingObject(id: id, toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m60, candleIndex: candleIndex, price: price)],
                      isExtended: sub == .ray, panelPosition: 0, lineSubType: sub)
    }

    static let tools: [DrawingToolType: any DrawingTool] = [.horizontal: HorizontalLineTool()]

    @Test("D33：两条重合线 → 命中**后画的那条**（数组序 = z-order，逆序取最上层）")
    func topmostWins() {
        let m = Self.mapper()
        let first = Self.hLine("FIRST", price: 100)
        let second = Self.hLine("SECOND", price: 100)
        let p = CGPoint(x: 400, y: m.priceToY(100))
        #expect(DrawingHitTester.firstHit(in: [first, second], point: p, mapper: m, tools: Self.tools)?.id == "SECOND")
        // 反转输入顺序 → 结果跟着反转（证明判据真的是"数组序"，不是"按 id 排序"之类的巧合）
        #expect(DrawingHitTester.firstHit(in: [second, first], point: p, mapper: m, tools: Self.tools)?.id == "FIRST")
    }

    @Test("未命中 → nil；命中容差外的线不算命中")
    func missReturnsNil() {
        let m = Self.mapper()
        let p = CGPoint(x: 400, y: m.priceToY(100) + 50)      // 远离横线 y，超 8pt 容差
        #expect(DrawingHitTester.firstHit(in: [Self.hLine("A", price: 100)], point: p, mapper: m, tools: Self.tools) == nil)
        #expect(DrawingHitTester.firstHit(in: [], point: p, mapper: m, tools: Self.tools) == nil)
    }

    @Test("D40：注册表里没有的工具**不命中** —— 与渲染 dispatch 的 `guard let tool … else { continue }` 同判据")
    func unregisteredToolNeverHits() {
        let m = Self.mapper()
        let p = CGPoint(x: 400, y: m.priceToY(100))
        // 空注册表 = 渲染层什么都画不出来 → 命中层也必须什么都命不中
        #expect(DrawingHitTester.firstHit(in: [Self.hLine("A", price: 100)], point: p, mapper: m, tools: [:]) == nil)
        #expect(DrawingHitTester.firstHit(in: [Self.hLine("A", price: 100)], point: p, mapper: m,
                                          tools: Self.tools)?.id == "A")   // 反向对照，防"一律不命中"骗过
    }

    @Test("D40 源码守卫：命中入口在 Sources/ 中各只有一处（防另开一条绕过 visibleDrawings 的命中路径）")
    func hitDispatchIsSinglePoint() throws {
        // ① `hitTest(` 的**调用**点恰好 1 处 = DrawingHitTester 内（协议声明与 HorizontalLineTool 的
        //    实现都带 `func`，被 callCount 扣掉，不计入调用）。
        let hits = try callSiteCount("hitTest(")
        #expect(hits.count == 1, "hitTest 的调用点不是 1 处：\(hits)")
        #expect(hits.first?.file.hasSuffix("/Drawing/DrawingHitTester.swift") == true)
        #expect(hits.first?.count == 1)
        // ② `firstHit(` 的调用点恰好 1 处 = tap 路由（`ChartContainerView.swift` 的 `.select` 分支）。
        //    PR-4 若要再加一个命中入口，这条当场红 —— 那个入口必须同样先过 `visibleDrawings`。
        let entries = try callSiteCount("firstHit(")
        #expect(entries.count == 1, "firstHit 的调用点不是 1 处：\(entries)")
        #expect(entries.first?.file.hasSuffix("/Render/ChartContainerView.swift") == true)
        #expect(entries.first?.count == 1)
        // ③ **只数调用点不够（codex plan-R5-F1）**：`firstHit(in: engine.drawings, …)` 同样只有 1 处调用点，
        //    却绕过了 belongsToPanel + revealTick 过滤 → 能选中本面板根本没渲染的线。故必须钉**入参来源**：
        //    唯一那处调用的列表必须来自 `RenderStateBuilder.visibleDrawings`。
        let route = try squeezedSource(entries[0].file)
        #expect(route.contains(squeeze("let ordered = RenderStateBuilder.visibleDrawings(")),
                "命中列表必须来自 visibleDrawings（D40 单一真相）")
        #expect(route.contains(squeeze("DrawingHitTester.firstHit(in: ordered,")),
                "firstHit 必须消费上面那个 ordered，不得另喂一个集合")
        // 反向：路由里不得直接把引擎数组喂进命中（这才是真正要挡的形状）
        #expect(!route.contains(squeeze("firstHit(in: engine.drawings")))
        #expect(!route.contains(squeeze("firstHit(in: engine.reviewDrawings")))
        #expect(!route.contains(squeeze("firstHit(in: view.renderState.drawings")))
        // ③ 自足断言：扫描器真的扫到东西了（防扫描根写错 → 空集合 → 上面 `count == 1` 直接红而非假绿，
        //    但仍显式钉一条，与既有守卫的纪律一致）。
        #expect(try !allSwiftFilesUnderSources().isEmpty)
    }

    @Test("D40/§8 #2：渲染不出的线同样命不中（visibleGeometry == nil），且不会挡住它下面那条")
    func invisibleGeometryDoesNotHitNorShadow() {
        let m = Self.mapper()
        let p = CGPoint(x: 400, y: m.priceToY(100))
        let ghost = Self.hLine("GHOST", price: 100, sub: .segment)      // 水平线的 .segment 恒不可渲染
        let real = Self.hLine("REAL", price: 100)
        #expect(DrawingHitTester.firstHit(in: [ghost], point: p, mapper: m, tools: Self.tools) == nil)
        // ghost 排在最上层，但它命不中 → 必须继续往下找到 REAL（不能"最上层没中就返回 nil"）
        #expect(DrawingHitTester.firstHit(in: [real, ghost], point: p, mapper: m, tools: Self.tools)?.id == "REAL")
    }
}
```

⚠️ `CoordinateMapper` 的初始化器与 `priceToY` 先照 `HorizontalLineToolTests.swift` 里既有的 `mapper()` helper 抄一遍实际写法，不要凭上面这段猜。

- [ ] **Step 2: 跑测试确认失败**

Expected：`cannot find 'DrawingHitTester' in scope`。

- [ ] **Step 3: 实现 `DrawingHitTester`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingHitTester.swift
// Spec: docs/superpowers/specs/2026-07-23-drawing-tools-P1b-1b-i-select-edit-delete-design.md §3（D40）+ D33
//
// 跨平台：仅 CoreGraphics（与 DrawingTool / HorizontalLineTool 一致，无 UIKit）→ host swift test 全覆盖。
// 真实 tap 路径的接线在 Render/ChartContainerView.swift 的 Coordinator（UIKit 层），那里只做"取集合 + 调本函数"。

import CoreGraphics

/// D33/D40（1b-i PR-3）：在**渲染序**列表上做命中判定。
///
/// 命中与渲染同源的三件套，缺一即分叉：
///   ① **同一个集合** —— 入参 `ordered` 必须来自 `RenderStateBuilder.visibleDrawings`（唯一真相）；
///   ② **同一张注册表** —— `tools` 必须是 `KLineView.drawingTools`（渲染 dispatch 用的那张）；
///   ③ **同一个几何判据** —— 各 tool 的 `hitTest` 与 `render` 共用 `visibleGeometry`（1a-i 已建）。
///
/// **逆序**遍历：数组序 = z-order，后画的在上，故最上层优先。
/// 已知限制（spec §8 #1，非缺陷）：不做选中循环 —— 容差内的两条线，单击**恒**选中最上层那条。
@MainActor
enum DrawingHitTester {
    static func firstHit(in ordered: [DrawingObject], point: CGPoint, mapper: CoordinateMapper,
                         tools: [DrawingToolType: any DrawingTool]) -> DrawingObject? {
        ordered.reversed().first { drawing in
            // 注册表里没有的工具**不命中** —— 与渲染 dispatch 的 `guard let tool = tools[...] else { continue }`
            // 逐字同判据（画不出的就选不中，spec §8 #2）。这里 fail-closed 成"不命中"而不是"跳过继续找"，
            // 因为 `first(where:)` 本来就会继续找下一条：返回 false 只是说"这一条不算命中"。
            guard let tool = tools[drawing.toolType] else { return false }
            return tool.hitTest(point: point, mapper: mapper, drawing: drawing)
        }
    }
}
```

- [ ] **Step 4: 跑 host 测试**

```bash
cd "…/ios/Contracts" && swift test --filter DrawingHitTester 2>&1 | tail -20
```

Expected：**4 条行为测试全绿**；`hitDispatchIsSinglePoint` **仍红**（`firstHit(` 在 `ChartContainerView.swift` 里还没有调用点——它要到 Step 6 才接上）。这是预期的中间态，**不要**为了让它变绿而提前接线或放宽断言；Step 7 会确认它转绿。

- [ ] **Step 5: 写 UIKit 接线测试（10 条，uikit 基线 +10）**

全部追加到 `Render/ChartContainerViewDrawingSessionTests.swift`（**同一个 `@Suite struct` 内**，复用它既有的 `bounds` / `makeRig()` / `mainChartPoint(_:)` 三个 private 成员 —— 实测在 `:17` / `:20-32` / `:39-45`）。
⚠️ **禁止把测试体写成占位注释**（`/* 见下方要点 */` 之类）：Swift Testing 会把空测试记成「通过」，uikit 基线一更新就等于给这几条最高危的信任边界发了假绿通行证。**没有断言的测试 = 没有测试**。

```swift
    // MARK: - 1b-i PR-3：选择态 tap 接线（D34 复盘门 / D37 未命中清空 / D53 盾优先 / D54 画线态不 hitTest）

    /// 复盘 rig：与 `makeRig()` 同构，但 engine 是 review flow。
    /// engine 复用既有 `TrainingEngineDrawingCommitTests.reviewEngine()`（`:76-90`，两面板均 `.m3`）。
    private func makeReviewRig() -> (TrainingEngine, ChartContainerView.Coordinator, KLineView) {
        let engine = TrainingEngineDrawingCommitTests.reviewEngine()
        let c = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let v = KLineView(frame: bounds)
        c.attach(to: v)
        c.rebuildRenderState(bounds: bounds)     // 出真 viewport（candleStep > 0）
        return (engine, c, v)
    }

    @Test("D34 反向对照（防过度 fail-closed）：复盘的**画线态** tap 照常落线 —— 复盘画线是既有功能，不得回归")
    func reviewModeStillDrawsInDrawMode() {
        let (engine, c, v) = makeReviewRig()
        engine.toggleDrawingMode()
        #expect(engine.drawingSession.drawingModeActive == true)   // 前提成立
        #expect(engine.drawingSession.mode == .draw)               // 前提：默认就是画线态

        c.handleDrawingTapForTesting(at: mainChartPoint(v))

        #expect(engine.reviewDrawings.count == 1, "复盘画线是 1a-iii 起的既有功能，本切片不得回归")
        #expect(engine.drawings.isEmpty, "复盘新画线不得污染原训练线")
    }

    @Test("D34 trust-boundary：复盘的**选择态** tap 不选中（否则可改写已归档 record 里的原训练线）")
    func reviewModeNeverSelects() {
        let (engine, c, v) = makeReviewRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(v)
        c.handleDrawingTapForTesting(at: p)                        // 先在画线态落一条，保证 p 上真有线可命中
        #expect(engine.reviewDrawings.count == 1)                  // 前提成立（否则下面全是恒真）
        engine.drawingSession.setMode(.select)
        #expect(engine.drawingSession.mode == .select)

        c.handleDrawingTapForTesting(at: p)                        // 同一点，选择态

        #expect(engine.drawingSession.selectedDrawingID == nil, "复盘不得获得选中能力（D34 trust-boundary）")
        #expect(engine.drawingSession.selectedPanel == nil)
        #expect(engine.reviewDrawings.count == 1, "选择态也不落锚：不得又画出第二条")
        #expect(engine.drawings.isEmpty)
    }

    @Test("D37：选择态未命中 → 清空选中、且不落锚（先命中建立选中，再点空白处）")
    func selectModeMissClearsSelectionAndDrawsNothing() {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let onLine = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: onLine)              // 画线态落一条
        #expect(engine.drawings.count == 1)                        // 前提成立
        engine.drawingSession.setMode(.select)
        upperC.handleDrawingTapForTesting(at: onLine)              // 选择态命中它
        let hitID = engine.drawings[0].id
        #expect(engine.drawingSession.selectedDrawingID == hitID)  // 前提成立（否则"被清空"恒真）
        #expect(engine.drawingSession.selectedPanel == .upper)

        // 同一列、纵向挪开 60pt（远超 8pt 命中容差），仍落在主图内
        let frame = upperV.renderState.viewport.mainChartFrame
        let missY = onLine.y - 60 >= frame.minY ? onLine.y - 60 : onLine.y + 60
        #expect(abs(missY - onLine.y) > 8)                         // 自证：这确实是个"未命中"的点
        #expect(missY >= frame.minY && missY <= frame.maxY)        // 自证：仍在主图内（不是靠出界侥幸未命中）
        // ⭐ 命中那一刻，**渲染态**也必须立刻带上它（只断言 session 状态证明不了用户看得见高亮）
        #expect(upperV.renderState.selectedDrawingID == hitID,
                "命中后必须立刻重建渲染态，否则本帧画的还是旧选中（D41/D55）")

        upperC.handleDrawingTapForTesting(at: CGPoint(x: onLine.x, y: missY))

        #expect(engine.drawingSession.selectedDrawingID == nil, "未命中必须清空选中（D37）")
        #expect(engine.drawingSession.selectedPanel == nil)
        #expect(engine.drawings.count == 1, "选择态未命中也绝不落锚")
        #expect(upperV.renderState.selectedDrawingID == nil, "清空后渲染态也必须立刻不再高亮")
    }

    @Test("D41/D55 端到端：tap 命中 → 该条真的以选中色画出来（像素级，不只是状态位）")
    func selectedLineActuallyRendersHighlighted() {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: p)                   // 画线态落一条
        #expect(engine.drawings.count == 1)                        // 前提成立
        // ⚠️ `.draw` 分支在 `routeDrawingCommit` 之后**不**重建渲染态（既有行为，生产靠 observation
        //    刷新；本 rig 是直连 Coordinator，不经 updateUIView）→ 不补这一次重建，`upperV.renderState`
        //    里还没有这条线，下面的 `before` 会是空的（codex plan-R4-F2）。
        upperC.rebuildRenderState(bounds: bounds)
        #expect(upperV.renderState.drawings.count == 1)             // 前提成立：线真的进渲染态了
        engine.drawingSession.setMode(.select)

        // 选中前：画出来的是它自己的 colorToken 色
        let before = Self.litPixels(of: upperV)
        #expect(!before.isEmpty, "对照组必须真的画出了线（否则下面的差异断言恒真）")

        upperC.handleDrawingTapForTesting(at: p)                   // 选择态命中
        #expect(engine.drawingSession.selectedDrawingID == engine.drawings[0].id)   // 前提成立

        let after = Self.litPixels(of: upperV)
        #expect(!after.isEmpty, "选中后线仍要画出来（不能因为高亮反而消失）")
        // ⚠️ 不假设测试环境的 scheme（`KLineView.draw` 取 `themeController.resolve(trait:)`，
        //    CI 上是 light 还是 dark 不由本测试决定）→ 两套选中色都认，判据仍然有力：
        //    两者都 ≠ 任何 DrawingColorToken 的解析结果（`selectionColorIsOutsideTokenRange` 已钉死）。
        let sels = [DrawingColorResolver.selectionRGBA(scheme: .light),
                    DrawingColorResolver.selectionRGBA(scheme: .dark)]
        #expect(after.contains { px in
            sels.contains { abs(px.r - CGFloat($0.red)) < 0.06 && abs(px.b - CGFloat($0.blue)) < 0.06 }
        }, "选中的线必须以选中色画出（D55）")
        #expect(before != after, "选中前后画面必须真的不同，否则高亮等于没做")
    }

    @Test("D40 路由（行为级）：最上层但**未揭示**的线不得被选中 —— 证明命中吃的是 visibleDrawings 不是 engine.drawings")
    func hitIgnoresUnrevealedTopmostLine() {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: p)                   // 画线态落一条（revealTick = 当时 tick）
        #expect(engine.drawings.count == 1)                        // 前提成立
        let visible = engine.drawings[0]
        // 在它**之上**（数组末尾 = z-order 最上层）注入一条同几何、但 revealTick 远在未来的线。
        // 命中若直接吃 `engine.drawings`（绕过渐显过滤），逆序第一个命中的就是这条幽灵线。
        let ghost = DrawingObject(id: "UNREVEALED", toolType: visible.toolType, anchors: visible.anchors,
                                  isExtended: visible.isExtended, panelPosition: visible.panelPosition,
                                  revealTick: engine.tick.globalTickIndex + 9_999, period: visible.period)
        engine.injectDrawingsForTesting([visible, ghost])
        engine.drawingSession.setMode(.select)

        upperC.handleDrawingTapForTesting(at: p)

        #expect(engine.drawingSession.selectedDrawingID == visible.id,
                "未揭示的线不在渲染集合里 → 也不该在命中集合里（D40）")
    }

    @Test("D40 路由（行为级）：属于**另一个面板**的线不得在本面板被选中（belongsToPanel 过滤真的生效）")
    func hitIgnoresOtherPanelLine() {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == 1)                        // 前提成立
        let mine = engine.drawings[0]
        #expect(mine.period == engine.upperPanel.period)           // 前提：它确实属于上面板
        #expect(engine.upperPanel.period != engine.lowerPanel.period)   // 前提：两面板周期不同（非 fail-safe 态）
        // 同几何、同 revealTick，但 period 绑到**下**面板 → belongsToPanel 判它不属于上面板
        let other = DrawingObject(id: "OTHER_PANEL", toolType: mine.toolType,
                                  anchors: [DrawingAnchor(period: engine.lowerPanel.period,
                                                          candleIndex: mine.anchors[0].candleIndex,
                                                          price: mine.anchors[0].price)],
                                  isExtended: mine.isExtended, panelPosition: 1,
                                  revealTick: mine.revealTick, period: engine.lowerPanel.period)
        engine.injectDrawingsForTesting([mine, other])
        engine.drawingSession.setMode(.select)

        upperC.handleDrawingTapForTesting(at: p)

        #expect(engine.drawingSession.selectedDrawingID == mine.id,
                "另一个面板的线不在本面板渲染集合里 → 也不该在本面板命中集合里（D40/D29）")
        #expect(engine.drawingSession.selectedPanel == .upper)
    }

    @Test("D41 跨面板：在另一个面板选中后，原面板刷新时高亮必须消失（不得两条同时高亮）")
    func selectingInOtherPanelUnhighlightsSibling() {
        let (engine, upperC, lowerC, upperV, lowerV) = makeRig()
        engine.toggleDrawingMode()
        let pUp = mainChartPoint(upperV), pLow = mainChartPoint(lowerV)
        upperC.handleDrawingTapForTesting(at: pUp)                 // 上面板一条
        lowerC.handleDrawingTapForTesting(at: pLow)                // 下面板一条
        #expect(engine.drawings.count == 2)                        // 前提成立
        engine.drawingSession.setMode(.select)

        lowerC.handleDrawingTapForTesting(at: pLow)                // 先选中下面板那条
        let lowID = engine.drawingSession.selectedDrawingID
        #expect(lowID != nil)                                      // 前提成立
        #expect(lowerV.renderState.selectedDrawingID == lowID)     // 下面板确实高亮着
        upperC.rebuildRenderState(bounds: bounds)
        #expect(upperV.renderState.selectedDrawingID == nil, "上面板不该被下面板的选中点亮（二元组门）")

        upperC.handleDrawingTapForTesting(at: pUp)                 // 改选上面板那条
        #expect(engine.drawingSession.selectedPanel == .upper)
        #expect(upperV.renderState.selectedDrawingID == engine.drawingSession.selectedDrawingID)

        // ⚠️ 本 rig 是直连 Coordinator、不经 `updateUIView` → sibling 不会自动刷新，必须手动触发一次
        //    （生产靠 observation：`rebuildRenderState` 在 bounds 守卫**之前**显式读了选中二元组，
        //     Task 3 Step 5 已建立该订阅，并由 `rebuildRenderStateSubscribesToPanelState` 源码守卫钉死；
        //     observation 的真实触发**单测测不到**，同本仓「图表冻结」那次回归的处置）。
        lowerC.rebuildRenderState(bounds: bounds)
        #expect(lowerV.renderState.selectedDrawingID == nil,
                "下面板刷新后必须不再高亮 —— 否则屏幕上会同时有两条选中线")
    }

    /// ⚠️ **必须是具名 `Equatable` 结构体，不能用元组**（codex plan-R6-F1）：Swift 的元组**不遵循协议**，
    /// 故 `[(r: CGFloat, g: CGFloat, b: CGFloat)]` 不是 `Equatable` 的 `Array`，`before != after`
    /// **类型检查就过不了**。而这段是 UIKit-gated 的 → host `swift test` 整份不编译、发现不了，
    /// 要等到 Catalyst 闸门才炸。（既有的 `HorizontalLineToolTests.litColumn` 返回元组数组是安全的，
    /// 因为那边只 `contains {…}` 逐元素比，从不比整个数组。）
    private struct Px: Equatable { let r: CGFloat; let g: CGFloat; let b: CGFloat }

    /// 把 `view` 当前 renderState 画进一张 bitmap，返回线像素的（反 premultiplied）颜色。
    /// 与 `HorizontalLineToolTests.litColumn` 同思路，但走的是**真实 `KLineView.draw(_:)` 派发链**
    /// （renderState → drawDrawings → tool.render），这才证明得了「选中态一路流到了像素」。
    private static func litPixels(of view: KLineView) -> [Px] {
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        UIGraphicsPushContext(ctx)
        view.draw(view.bounds)
        UIGraphicsPopContext()
        var out: [Px] = []
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let a = CGFloat(data[i + 3]) / 255
            guard a > 0.3 else { continue }
            out.append(Px(r: CGFloat(data[i]) / 255 / a,
                          g: CGFloat(data[i + 1]) / 255 / a,
                          b: CGFloat(data[i + 2]) / 255 / a))
        }
        return out
    }

    @Test("D54：画线态单击**恒落锚**、绝不 hitTest —— 点在已有线上是又叠一条，不是选中它（验收 #5）")
    func drawModeTapAlwaysAnchorsNeverSelects() {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == 1)                        // 前提成立
        #expect(engine.drawingSession.mode == .draw)

        upperC.handleDrawingTapForTesting(at: p)                   // 同一点再来一下

        #expect(engine.drawings.count == 2, "画线态点在已有线上 = 又叠一条重合线，不是选中")
        #expect(engine.drawingSession.selectedDrawingID == nil, "画线态永远不建立选中")
    }

    @Test("N6/D53：`.pending` 盾对**选择态**同样拒收 —— 既不选中也不落锚")
    func pendingShieldRejectsSelectTap() {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: p)                   // 无盾时先落一条（保证 p 上有线）
        #expect(engine.drawings.count == 1)                        // 前提成立
        engine.drawingSession.setMode(.select)
        engine.drawingSession.setStylePanelVisible(true)           // 两面板 → .pending（fail-closed 窗口）
        #expect(engine.drawingSession.shield[0] == .pending)       // 前提成立

        upperC.handleDrawingTapForTesting(at: p)

        #expect(engine.drawingSession.selectedDrawingID == nil, ".pending 拒收一切 tap，选择态不例外（D53）")
        #expect(engine.drawings.count == 1)
    }

    @Test("N6/D53：`.rect` 区内的选择态 tap 被挡、区外正常选中（证明分叉在盾之后、且盾不过度屏蔽）")
    func rectShieldBlocksSelectInsideOnly() {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == 1)                        // 前提成立
        let hitID = engine.drawings[0].id
        engine.drawingSession.setMode(.select)

        // ① 盾盖住 p → 拒收
        let covering = CGRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40)
        #expect(covering.contains(p))                              // 自证：这个盾确实盖住了 p
        engine.drawingSession.setShield(.rect(covering), panel: .upper)
        upperC.handleDrawingTapForTesting(at: p)
        #expect(engine.drawingSession.selectedDrawingID == nil, "盾内的 tap 既不落锚也不选中")

        // ② 盾挪到别处（区外）→ 同一点正常选中。**没有这一半**，实现完全可以用「有盾就一律拒收」骗过 ①
        let far = CGRect(x: 0, y: 0, width: 8, height: 8)
        #expect(!far.contains(p))                                  // 自证：这个盾没盖住 p
        engine.drawingSession.setShield(.rect(far), panel: .upper)
        upperC.handleDrawingTapForTesting(at: p)
        #expect(engine.drawingSession.selectedDrawingID == hitID, "盾外的 tap 应正常命中选中")
        #expect(engine.drawings.count == 1, "选择态命中不落锚")
    }
```

⚠️ 三条实施注意：
- `TrainingEngineDrawingCommitTests.reviewEngine()` 是 `static func`（非 private，实测 `:77`）→ 跨文件可调；但**先核实**它仍是 `static` 且签名带默认参数，变了就照实际写。
- `mainChartPoint(_:)` 的注释（`:36-38`）说明了为什么不能用 `mainChartFrame.midX`——preview rig 可见 slice 只有 1 根、midX 落在 overscroll 空白区会被 fail-closed 拒掉。`makeReviewRig()` 的 engine 是 `.m3`×100 根，情况不同但同一个 helper 依然正确（它按 `viewport.startIndex` 算）。
- 十条测试都**必须**先断言「前提成立」再断言结论（每条都写了）——否则 rig 一坏（比如 tap 根本没落线）所有"不应发生"的断言全部恒真。

- [ ] **Step 6: 接 `handleDrawingTap`**

`ChartContainerView.swift:292-306`，把 mapper 之后的整段改成分叉（**盾判定 `:287-291` 原封不动、仍在分叉之前**，D53）：

```swift
            let mapper = CoordinateMapper(viewport: viewport, displayScale: view.traitCollection.displayScale)
            // D38/D54（1b-i PR-3）：盾之后才分叉 —— 落在面板上的点击**既不落锚、也不选中**（D53）。
            switch session.mode {
            case .draw:
                // ⚠️ 本分支**一字未改**（1a-ii/1a-iii/1a-iv 的落线链路原样）：训练与复盘的画线能力
                //    是既有功能，本切片只是在它旁边加了一条新分支。
                let ps = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
                guard let anchor = inputController.tapToAnchor(at: point, panel: ps, mapper: mapper) else { return }
                session.addAnchor(anchor, panel: panel)          // D31：落在 ≠ pendingAnchorPanel 的面板 → 容器内部只丢 pending
                guard inputController.shouldCommit(current: session.pendingAnchors, tool: tool) else { return }
                // 1a-iii：样式（含 lineSubType）由 session.defaultStyle 单一真相决定，commitPending 原子读取。
                guard let committed = session.commitPending(panelPosition: panel == .upper ? 0 : 1) else { return }
                // codex rebased-R2：拒绝**不可见**画线再落库（1a-iii 起 ray 可被用户选中）。落在右缘的射线
                // lineXRange==nil → 既画不出（HorizontalLineTool.render 跳过）、又命不中（hitTest fail-closed），
                // 但仍会 append+autosave 一条 1b-i 前无从选中/删除的幽灵线。与 tapToAnchor 的源头 fail-closed 同理，
                // 扩到 ray 右缘几何：可见几何为 nil 就不落库。本期只 .horizontal。
                guard HorizontalLineTool.visibleGeometry(for: committed, mapper: mapper) != nil else { return }
                engine.routeDrawingCommit(committed)             // review→reviewDrawings；否则→drawings（Task 10）
                // ← 此处**故意没有** engine.commitDrawing(panel:)：连续画线（D38），会话与工具保持不变。

            case .select:
                // D34 / spec §4（**trust-boundary**）：复盘**不得**获得选中能力 —— 复盘的选中要带
                // `(layer, id)` 层权限门控，那是 P5；本期若放行，复盘就能改写**已归档 record 里的原训练线**。
                // ⚠️ 门**只包这一支**：`.draw` 在复盘下照常落线（浮动铅笔钮，1a-iii 起的既有功能）。
                //    把 guard 提到 switch 之前 = 复盘画线功能回归 —— 与 PR-1 那道 `.segment` 门误管所有
                //    工具是同一类错误：fail-closed 的门必须限定到它真适用的那一类。
                guard engine.flow.mode != .review else { return }
                // D40：命中集合 ≡ 渲染集合 —— 同一个 `visibleDrawings`、同一张 `drawingTools` 注册表。
                let ordered = RenderStateBuilder.visibleDrawings(
                    engine: engine, panel: panel, tick: engine.tick.globalTickIndex)
                if let hit = DrawingHitTester.firstHit(in: ordered, point: point, mapper: mapper,
                                                       tools: KLineView.drawingTools) {
                    session.setSelection(id: hit.id, panel: panel)   // 命中 → 选中它（替换原选中）
                } else {
                    session.clearSelection()                         // D37：未命中 → 先清空选中，**且不落锚**
                }
                // ⚠️ 选中态变了必须**立刻**重建渲染态（codex plan-R3-F2）：本函数开头 `:280` 的
                //    `rebuildRenderState` 发生在选中改变**之前**，而高亮渲染读的是
                //    `KLineRenderState.selectedDrawingID` → 不补这一次重建，本帧画出来的还是旧选中。
                //    `KLineRenderState` 是 `Equatable` 且 `KLineView.renderState` 有
                //    `didSet { guard renderState != oldValue else { return }; setNeedsDisplay() }`
                //    （`KLineView.swift:16-21`）→ 只有 `selectedDrawingID` 变了的新状态照样触发重绘，
                //    没变则不重绘（无多余绘制）。**不要**改成依赖 SwiftUI observation 顺带刷新：
                //    Coordinator 这条直连路径不经过 `updateUIView`，那样等于没有证据。
                rebuildRenderState(bounds: view.bounds)
            }
```

⚠️ 三条实施注意：
- `let tool` 来自 `:274` 的 guard，`.select` 分支用不到它 —— Swift 不会报 unused（`.draw` 分支用了）。若编译器仍抱怨，**不要**把 guard 改成 `session.activeDrawingTool != nil`（D57 要求会话存活期间工具恒非 nil，这个 guard 是不变量的一部分），改用 `_ = tool` 也不要 —— 直接确认它确实被 `.draw` 用到即可。
- `engine.tick.globalTickIndex` 与 `rebuildRenderState`（`:280`）用的是**同一帧同一个 engine** → 与渲染集合天然一致。
- `KLineView.drawingTools` 与 Coordinator 都在 `#if canImport(UIKit)` 内，跨文件访问靠 Task 4 把 `private` 降成 internal。

- [ ] **Step 7: 跑测试确认通过 + 全量不回归**

```bash
cd "…/ios/Contracts" && swift test 2>&1 | tail -5
```

Expected：host 全绿，**含 Step 4 那条一直红着的 `hitDispatchIsSinglePoint` 现在转绿**（接线补上了它要求的那个调用点）。UIKit 测试在 host 上 skip，留到三绿门的 Catalyst 统一跑。

- [ ] **Step 8: 变异验证（5 次；UIKit 那几条须在 Catalyst 上验）**

| 变异 | 应该红的测试 |
|---|---|
| `firstHit` 去掉 `.reversed()` | `topmostWins` |
| `firstHit` 去掉 `guard let tool = tools[...]`（改成硬取 `HorizontalLineTool()`） | `unregisteredToolNeverHits` |
| Coordinator 里绕过 `visibleDrawings`，直接对 `engine.drawings` 逐条 `tool.hitTest` | `hitDispatchIsSinglePoint`（`hitTest(` 变 2 处） |
| 复盘门从 `.select` 分支**提到 switch 之前** | `reviewModeStillDrawsInDrawMode`（Catalyst） |
| 删掉 `else { session.clearSelection() }` | `selectModeMissClearsSelectionAndDrawsNothing`（Catalyst） |

- [ ] **Step 9: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingHitTester.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingHitTesterTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewDrawingSessionTests.swift
git commit -m "划线 P1b-1b-i PR-3 T5：hitTest 接进生产 tap 路径（D33 逆序 + D34 复盘门只包选择态 + D37 未命中清空）"
```

---

## Task 6：切周期善后清空选中（D54 clause 3 / D57 表格末行 / D63 对照）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift:426-434`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`（追加）

**Interfaces:**
- Consumes: Task 2 的 `clearSelection()`

- [ ] **Step 1: 写失败测试**

追加到 `TrainingEngineDrawingSessionTests.swift`：

⚠️ **fixture 必须是 `engineMultiPeriod()`，绝不能用 `TrainingEngine.preview()`** —— 这不是风格问题，是同文件 `:76-80` 已经写死的警告：`preview()` 的 `allCandles` 只有 `.m3`/`.m60`/`.daily`（**没有 `.m15`**），当前组合 `(.m60,.daily)` 无论 `toSmaller`（需 `.m15`）还是 `toLarger`（需 `.weekly`）都会撞 `switchPeriodCombo` 的「target 周期无数据 → no-op」守卫（`TrainingEngine.swift:400-401`）→ **加不加清空选中都 no-op，测试恒绿 = 假守卫，什么也没测到**。下面两条测试照抄同文件 `realPeriodChangeDiscardsOnlyPendingAnchors`（`:83-100`）的 setup。

```swift
    // MARK: - 1b-i PR-3（D54 clause 3 / D57 表格末行）：切周期 = 结构性不可见 → 清空选中
    // ⚠️ 同 :76-80 的警告：这两个测试**必须**用 `engineMultiPeriod()`，用 `preview()` 会撞
    //    「target 周期无数据 → no-op」守卫 → 恒绿假守卫。

    @Test("N11 扩条：选择态下切周期 —— 选中被清空，但会话/态/两面板武装全部完好（不裂脑）")
    func periodSwitchClearsSelectionWithoutSplitBrain() {
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        // 一条 .m60 线：切周期前归**上**面板（upper==.m60），切完 (.m15,.m60) 后归**下**面板
        // —— 正是 D54 clause 3 说的「该线改由另一面板显示」，id 仍在 drawings 里（存在性谓词判"保留"），
        //    但结构归属判"清空"。
        #expect(e.appendDrawing(DrawingObject(
            id: "S", toolType: .horizontal,
            anchors: [DrawingAnchor(period: .m60, candleIndex: 1, price: 10)],
            isExtended: false, panelPosition: 0)) == true)
        e.toggleDrawingMode()                                    // 会话开：两面板 .drawing，工具 .horizontal
        #expect(e.drawingSession.drawingModeActive == true)      // 前提成立（防会话没开→后面断言恒真）
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "S", panel: .upper)
        #expect(e.drawingSession.selectedDrawingID == "S")       // 前提成立（防下面恒真）

        e.switchPeriodCombo(direction: .toSmaller)               // (.m60,.daily) → (.m15,.m60) 真的能切成功

        #expect(e.upperPanel.period == .m15)                     // 周期真的变了（防假绿：不是撞 no-op 守卫）
        #expect(e.lowerPanel.period == .m60)
        #expect(e.drawingSession.selectedDrawingID == nil, "结构性不可见 → 必须清空选中（D54 clause 3）")
        #expect(e.drawingSession.selectedPanel == nil)
        #expect(e.drawings.map(\.id) == ["S"], "清的是**选中**，不是那条线本身")
        // 以下四条是 1a-iv + D57 的不变量，本 Task 不得破坏：
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.drawingSession.mode == .select, "切周期不改变用户所处的态")
        #expect(e.drawingSession.activeDrawingTool == .horizontal)
        assertInvariant(e)                                       // ⭐两面板重新回到 .drawing
    }

    @Test("D63 对照：不是「任何看不见都清空」—— no-op 的切周期不得碰选中（D31 同一条纪律）")
    func noOpPeriodSwitchKeepsSelection() {
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        #expect(e.appendDrawing(DrawingObject(
            id: "S", toolType: .horizontal,
            anchors: [DrawingAnchor(period: .m60, candleIndex: 1, price: 10)],
            isExtended: false, panelPosition: 0)) == true)
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "S", panel: .upper)
        #expect(e.drawingSession.selectedDrawingID == "S")

        // toLarger：目标 (.daily,.weekly)，engineMultiPeriod 无 .weekly 数据 → D8 守卫 no-op，
        // `restoreDrawingSessionAfterPeriodChange` **根本不被调用**。
        e.switchPeriodCombo(direction: .toLarger)

        #expect(e.upperPanel.period == .m60, "前提：这一次切换确实是 no-op（周期没变）")
        #expect(e.drawingSession.selectedDrawingID == "S", "no-op 的切周期不得碰选中（D31 同一条纪律）")
        #expect(e.drawingSession.selectedPanel == .upper)
        assertInvariant(e)
    }
```

⚠️ 写之前先读一遍这三样的**实际**写法，不要照抄上面的调用：`TrainingEngineInteractionTests.engineMultiPeriod()` 的返回元组形状、`assertInvariant(_:)` 的签名、以及 `engineMultiPeriod()` 到底备了哪几个周期（同文件 `:80` 注释说是 `.m15/.m60/.daily`，实施时以源码为准）。

```bash
grep -n "func engineMultiPeriod" -A 15 ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineInteractionTests.swift
grep -n "func assertInvariant" -A 6 ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift
```

若 `engineMultiPeriod()` 实际备了 `.weekly`，第二条测试的 no-op 触发方式要改（换成走到序列边界，或换方向），**判据不变**：必须构造出一次**真的 no-op**（断言周期没变）再验选中原样保留。

- [ ] **Step 2: 跑测试确认失败**

Expected：`periodSwitchClearsSelectionWithoutSplitBrain` 红在 `selectedDrawingID == nil`（当前实现不清）。

- [ ] **Step 3: 实现**

`TrainingEngine.swift:426-434`，在 `discardPendingAnchors()` 那行之后插入：

```swift
    private func restoreDrawingSessionAfterPeriodChange() {
        guard drawingSession.drawingModeActive, let tool = drawingSession.activeDrawingTool else { return }
        if !drawingSession.pendingAnchors.isEmpty { drawingSession.discardPendingAnchors() }
        // ③ D54 clause 3 / D57 表格末行（1b-i PR-3）：**结构性不可见 → 清空选中**。
        //    锚点绑在旧周期的 candleIndex 上，换了周期坐标系就错了；而且 D29 周期绑定下，这条线
        //    可能已经**迁到另一个面板**去渲染了 —— 它的 id 仍在 `drawings` 里（存在性谓词判"保留"），
        //    但结构归属判"清空"，两维正交、取并集（D64）。
        //    ⚠️ **几何性**不可见（平移把线滑出屏）**不**清空（D63）：那会让一次滑动的惯性余速把选中
        //    悄悄抖掉。本函数只在**周期真的变了**时被调用（`switchPeriodCombo:408` 的守卫），
        //    平移根本走不到这里 —— 判据的分流是由"谁调用它"保证的，不是靠这里再判一次。
        drawingSession.clearSelection()
        armPanelForDrawing(tool, panel: .upper)
        armPanelForDrawing(tool, panel: .lower)
        if !(isDrawingActive(on: .upper) && isDrawingActive(on: .lower)) {
            // fail-closed：宁可退出画线，也不留半武装。`endDrawingSessionIfActive` → `deactivate()`
            // 里已再清一次选中并复位 `mode`（D57 fail-closed 分支要求），此处无需重复。
            endDrawingSessionIfActive()
        }
    }
```

- [ ] **Step 4: 跑测试确认通过 + 全量不回归**

Expected：全绿，host 总数 = 上一 Task + 2。

- [ ] **Step 5: 变异验证（2 次）**

| 变异 | 应该红的测试 |
|---|---|
| 删掉 `drawingSession.clearSelection()` | `periodSwitchClearsSelectionWithoutSplitBrain` |
| 把 `clearSelection()` 换成 `deactivate()`（过度清空） | 同上（`drawingModeActive`/`mode`/两面板武装四条断言全红） |

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift
git commit -m "划线 P1b-1b-i PR-3 T6：切周期善后清空选中（D54 clause 3 结构性不可见，几何性不清）"
```

---

## Task 7：三绿门 + 基线同步

**Files:**
- Modify（**本切片必改**，因为新增了 UIKit-gated 测试）：`.github/scripts/catalyst-uikit-baseline.txt`、`.github/scripts/fixtures/pass-main-current.log`
- Modify（**仅当 total 漂出 1625±30**）：`.github/scripts/catalyst-total-baseline.txt`、`.github/scripts/catalyst-gate.test.sh`（「活基线覆盖」回显数字）

> ⚠️ **本 Task 的两条纪律来自 codex plan-R1 的两条真 finding（已逐条对脚本核实）**：
> ① `catalyst-gate.sh` 的第一行就是 `LOG="${1:?usage: catalyst-gate.sh <log-path>}"`（`:24`）——**它不跑 xcodebuild，只解析一份已存在的日志**。必须先自己跑 `xcodebuild test` 产出日志，再把日志路径传给它。
> ② **新增 UIKit-gated 测试就必须重新生成 uikit 基线，与 total 是否漂移无关**。`catalyst-gate.test.sh:47-65` 有一条独立的一致性断言：对当前源码活推导 `uikit-expected-tests.py`，与签入的 `catalyst-uikit-baseline.txt` **逐行精确比对**，不一致即自测 FAIL。`.github/scripts/catalyst-gate.test.sh:379-380` 也把这条写成了维护规则：「任何改动 `catalyst-uikit-baseline.txt`、或让真实总用例数漂出基线±30 的 PR，**必须同时用一次真 Catalyst 构建日志重裁 `pass-main-current.log`**（禁手打伪造行）」。
> （如实记录：codex 这条 finding 的**后果**描述说过头了——它说「gate 会绿而基线静默陈旧」，实际是 `catalyst-gate.test.sh` 这个独立 CI 步骤会红。但**计划里的错是真的**：原稿写成「只有 G7 FAIL 才同步基线」，照做必然让自测红。）

- [ ] **Step 1: host swift test（非增量）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr3/ios/Contracts"
rm -rf .build/arm64-apple-macosx
git rev-parse --abbrev-ref HEAD; git rev-parse HEAD
swift test 2>&1 | tail -8
```
Expected：`N passed`、`0 failures`。⚠️ 先 `rm -rf .build/arm64-apple-macosx`——`@Observable` 改 stored property 后陈旧增量构建会在没碰过的 target 上 SIGSEGV（本项目踩过）。

- [ ] **Step 2: 重新生成 uikit 基线（本切片必做，先于跑 Catalyst）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr3"
git rev-parse --abbrev-ref HEAD; git rev-parse HEAD
wc -l < .github/scripts/catalyst-uikit-baseline.txt          # 改之前：应为 59
python3 .github/scripts/uikit-expected-tests.py > .github/scripts/catalyst-uikit-baseline.txt
wc -l < .github/scripts/catalyst-uikit-baseline.txt          # 改之后：59 + 本切片新增的 UIKit-gated 测试数
git diff --stat .github/scripts/catalyst-uikit-baseline.txt
```

⚠️ **必须用这条生成命令，禁手打测试名**（`catalyst-uikit-baseline-reader.py:12-13` 明写「不要手打测试名，转录错误无法复核」）。
Expected：diff 里**只有新增行**、没有删除行（本切片没删任何 UIKit-gated 测试）。若出现删除行 → **停下报告**，说明改动误伤了既有 UIKit 测试。

⚠️ **重生成基线之前，先逐条检查新增的 UIKit-gated 测试体不是空的 / 没有断言**（codex plan-R2-F1）：基线一更新，这几条就成了「闸门声称在守护」的测试；若其中有空体或只写了注释的，等于给最高危的信任边界发了一张假绿通行证。逐条打开确认每个测试都**既有前提断言、也有结论断言**：

```bash
# 列出本切片新增的 UIKit-gated 测试名与它们所在的行，逐条人工过一遍（不是 grep 就算数）
git diff origin/main...HEAD -- ios/Contracts/Tests | grep -n '^+.*@Test(\|^+.*func \|^+.*#expect(' | head -60
```
判据：**任何一条新 `@Test` 的函数体里若一个 `#expect` 都没有 → 停下补齐，不许进基线。**

- [ ] **Step 3: 闸门自测（先于 xcodebuild，验基线一致性）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr3"
bash .github/scripts/catalyst-gate.test.sh 2>&1 | tee /tmp/gate-selftest-pr3.log | tail -30
```
Expected：`UIKit-gated 期望测试清单基线一致性检测（F1）：  ok — …` + 全部用例通过。
此时「活基线覆盖」那条用例**大概率会红**——它拿真基线去跑 `fixtures/pass-main-current.log`，而那份 fixture 里还没有新测试的 `passed` 行。**这正是 Step 5 要修的**，先记下红在哪条，别现在改。

- [ ] **Step 4: fresh Catalyst 全量（自己跑 xcodebuild，再把日志喂给闸门）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr3/ios/Contracts"
git rev-parse --abbrev-ref HEAD; git rev-parse HEAD
rm -rf /tmp/derived                                  # 非增量（fresh）
set -o pipefail
xcodebuild test \
  -scheme KlineTrainerContracts-Package \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:KlineTrainerContractsTests \
  -derivedDataPath /tmp/derived 2>&1 | tee /tmp/catalyst-pr3.log
echo "XCODEBUILD_EXIT=$?"
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr3"
bash .github/scripts/catalyst-gate.sh /tmp/catalyst-pr3.log; echo "GATE_EXIT=$?"
```

命令逐字取自 `.github/workflows/catalyst-build.yml:65-76`（只把日志路径从 `/tmp/catalyst-build.log` 换成 `/tmp/catalyst-pr3.log`，避免覆盖别的 run 的日志）。
Expected：日志尾部 `** TEST SUCCEEDED **`；闸门输出 `GATE PASS`。判绿**读输出内容**，不看退出码。
```bash
grep -c '✔' /tmp/catalyst-pr3.log; grep 'Test run with' /tmp/catalyst-pr3.log | tail -2   # 记下实测 total
```

- [ ] **Step 5: 重裁 `pass-main-current.log` fixture（本切片必做）**

`catalyst-uikit-baseline.txt` 变了 → 按 `catalyst-gate.test.sh:379-380` 的维护规则，**必须**用**这一次**的真日志 `/tmp/catalyst-pr3.log` 重裁 fixture。

1. **先读**现有 fixture 的形状，照它裁（`head -20 .github/scripts/fixtures/pass-main-current.log`）——保留 DerivedData / worktree 绝对路径与任何 `XCTestOutputBarrier` 插花，**不修剪**；
2. 用**脚本**从 `/tmp/catalyst-pr3.log` 逐行取：`** TEST SUCCEEDED **` 标记行 + `Test run with … passed` 汇总行 + 基线里**每一个**测试名对应的 `passed` 行；
3. **禁手打伪造行**（codex R9 的教训）。脚本取不到某个基线测试名 → **fail-closed 报错并停下**，不许补一行假的；
4. 重跑 `bash .github/scripts/catalyst-gate.test.sh` → 「活基线覆盖」转绿、**全部用例通过**。

- [ ] **Step 6: total 基线（仅当漂出 1625 ± 30）**

只有 G7 报「高于上限 / 低于下限」时才做：把 Step 4 实测的 total 写进 `.github/scripts/catalyst-total-baseline.txt`，并同步 `catalyst-gate.test.sh` 里「活基线覆盖」用例的回显数字，然后**重跑 Step 3 与 Step 4**。
本切片预计新增 UIKit-gated 测试 **12 条**（Task 4 的 dispatch 2 条 + Task 5 的 10 条）+ host 测试约 23 条 → 合计约 **+35**，**很可能把 total 顶出 `1625 ± 30`（上限 1655）→ 大概率要 bump**。以 Step 4 的实测数为准，别按这里的估算提前改。uikit 基线则**无论如何都要**改（Step 2）。

⚠️ 本 Task 动了 `.github/**` = trust-boundary → **必须触发重新 attest**（Task 8）。

- [ ] **Step 7: iOS build**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr3"
git rev-parse --abbrev-ref HEAD; git rev-parse HEAD
```
⚠️ **命令逐字取自 `.github/workflows/app-build.yml`**（先读那个 workflow，别照抄下面这行猜的）：
```bash
grep -n "xcodebuild" .github/workflows/app-build.yml
```
Expected：`** BUILD SUCCEEDED **`（模拟器 + `CODE_SIGNING_ALLOWED=NO`，不碰钥匙串，我或 user 均可跑；真机签名安装才需 user 真终端）。判绿读输出内容，不看退出码。

- [ ] **Step 8: Commit**

```bash
git add .github/scripts/
git commit -m "划线 P1b-1b-i PR-3：同步 Catalyst uikit 基线 + 真 fresh 日志重裁 fixture"
```

---

## Task 8：整支评审与收口

- [ ] **Step 1: whole-branch Opus 终审**（对 `f21cca1..HEAD` 全 diff，逐条核实源码，不预判 finding）
- [ ] **Step 2: whole-branch codex 对抗性评审**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/drawing-p1b-1b-i-pr3"
pwd; git rev-parse --abbrev-ref HEAD; git rev-parse HEAD
bash .claude/scripts/codex-attest.sh --scope branch-diff   # ⚠️ 不加任何 --focus（窄化会跑出假 approve）
```
- [ ] **Step 3: Read 账本文件核实 `head_sha` == HEAD**（不是 grep 输出，是真读文件）
- [ ] **Step 4: HEAD 一动（哪怕只改 `.github`）就重新 attest**
- [ ] **Step 5: `git push`**（我跑，bare 命令避 guard）→ **`gh pr create` 由 user 真终端跑**（PR title/body 中文）

---

## 交接：PR-4 接线前必须做的（在本 PR 的基础上）

1. **PR-2 的两条零调用点守卫要在 PR-4 改成「恰好 1 处」**（`TrainingEngineDrawingSessionTests.swift:851` / `:1002`），并把 UI 路由文件加进 `filesMentioning` 白名单——**只加那一个**。
2. **D64 存在性谓词到 PR-4 才第一次可达**：本切片的选中清空全部由**态变化**与**结构性不可见**驱动（`deactivate` / `setMode` / `activate` / 切周期 / tap 未命中），一次都没有读过任何 API 的返回值。PR-4 接上 `updateDrawingStyle` / `deleteDrawing(id:)` 之后，必须按 D64 用 `selectedDrawingID ∈ engine.drawings` 的**状态谓词**判清空，**绝不能**退回「返 `false` 就清空」——那六种失败原因里有三类要求**保留**选中。
3. **UI 置灰谓词以引擎门为准**（PR-2 交接②）：引擎比 spec D65 多三道（未来顶层字段 / 工具已实现 / 复盘模式），否则会出现「控件亮着、点了没反应」。
4. **PR-2 已知缺口仍未闭合**（PR-2 交接③）：在白名单文件**内部** vend 方法引用（`func handle() -> (DrawingID) -> Bool { deleteDrawing }`）能绕过两层守卫；本切片零调用点故不可达，**PR-4 打开攻击面前必须处理**。
5. **D61「换色修复高版本线」在 PR-4 前需独立定稿**（PR-2 已整块移出）。
6. **1b-ii 落 `setDrawingLocked` 时必须翻转 N14h 的预期**（`DrawingEditDurabilityGateTests`）——它现在钉住的是「locked + 未来数据线归不了档」这个已接受残留。

---

## 非程序员验收清单

> ⚠️ **本切片零交互控件、用户看不到任何变化** —— 没有 🗑、没有类型行 toggle、选择态在生产里进不去（`setMode` 在 `Sources/` 仍是零调用点，PR-4 才接）。
> 因此下表**全部是「不回归」项**，没有一条是新功能。
> **执行时机**：user 已明示 PR-3 不安排真机验收 → 本清单**并入 PR-4 的真机验收一次性执行**。
> 下表每条的「预期」都对着 `f21cca1` 的真实 UI 与本 PR 的实际改动写，**不是**从 spec 抄的。

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 训练模式点顶栏「画图」进画线模式，在主图 K 线区连点三下 | 画出**三条**线，和这次改动之前**一模一样** | |
| 2 | 接上：在**已有一条线的同一价位**再点一下 | **又叠画一条重合的线**（不是选中原来那条）——画线态的行为没变 | |
| 3 | 点底栏「类型」键收起 / 展开样式面板，各点几次 | 面板照常收放，K 线图尺寸不变，图表不冻结 | |
| 4 | 画线模式下点击**常驻样式面板本身**（面板盖住 K 线那块） | **什么都不发生**：不画线（面板挡住了）——盾没被这次改动碰坏 | |
| 5 | 画线模式下上下竖滑**切周期** | 周期照常切换；切完之后**还能继续画线**（点一下就出线）——切周期没把画线会话弄坏 | |
| 6 | 画线模式下左右平移图表、双指缩放 | 平移 / 缩放照常，线跟着图走，松手后有惯性——1a-iv 的手势没被改坏 | |
| 7 | 改一下线的颜色 / 线型 / 粗细，再画一条 | 新线是刚设的样式；**已有的线颜色一点没变**（本切片不碰任何已有线的样式） | |
| 8 | 点「退出」离开画线模式，再单击图表 | 出十字光标（正常的看盘手势），**不画线也不选中** | |
| 9 | 进复盘，用**浮动铅笔钮**进画线模式，在图上点一下 | **照常画出一条新线**（复盘画线能力必须完好；这是本切片最容易被改坏的一条） | |
| 10 | 接上：复盘里再单击一条训练时画的线 | 只会**再落一条新线**，原训练线的颜色 / 粗细**一点没变**、也不高亮 | |
| 11 | 画一条线 → **直接从后台划掉 App** → 重开续这一局 | 那条线**还在**（autosave 链路没被改动影响） | |
| 12 | 进复盘看画线入口和底栏 | 还是浮动铅笔钮，**没有**画线底栏、**没有** 🗑（🗑 是 PR-4 的事） | |

---

## Self-Review（写完后自查记录）

**1. spec 覆盖**（只核 PR-3 范围；其余条款明确属 PR-4 / 1b-ii）

| spec 条款 | 落在 |
|---|---|
| §3 命中集合 ≡ 渲染集合（共享纯函数 + 渲染方原样消费 + 命中方逆序） | Task 1 + Task 5 |
| §4 复盘门控（D34 trust-boundary） | Task 5 |
| D33 命中平局取最上层 | Task 5（`topmostWins`） |
| D37 未命中先清空选中、不落锚 | Task 5 |
| D40 判据不得各写一遍（源码守卫） | Task 1 |
| D41 选中态与 `activeDrawingTool` 同源 + 必须流进 `KLineRenderState` | Task 2 + Task 3 |
| D54 选中生命期 clause 1/2/3 + 二元组 + 新线不自动选中 | Task 2 + Task 6（clause 4 存在性谓词 → PR-4，已写进交接） |
| D55 高亮 = 瞬时 UI 状态、不落盘、`render` 增 `isSelected`、不占 token 值域 | Task 3 + Task 4 |
| D57 表格末行「切周期善后必须追加清空选中 + fail-closed 分支同样清」 | Task 6 |
| D63 几何性不可见**不**清空（只禁破坏性操作，禁用属 PR-4） | Task 6 的对照测试 + `restoreDrawing…` 注释 |
| §5 契约 1.12 / 零迁移 | Global Constraints + Task 3 的 `selectionNeverPersists` |
| §8 #1 不做选中循环、#2 渲染不出的线也选不中 | Task 5（`DrawingHitTester` 文档 + `invisibleGeometryDoesNotHitNorShadow`） |

**明确不覆盖（PR-4 / 1b-ii，已在 §1.2 与交接里写死）**：🗑 键与确认框、类型行 toggle、样式面板作用于选中线、`updateDrawingStyle`/`deleteDrawing(id:)` 接线与几何门、置灰谓词、D61 换色修复、🔒/撤销/`setDrawingLocked`。

**2. 占位符扫描**：无 TBD / TODO / 「类似 Task N」/ 「补上适当的错误处理」。所有代码步骤都给了可直接粘贴的代码。**四处刻意留的「先核实再写」**——① `setDrawingsForTesting` 是否存在（Task 1）② `CONTRACT_VERSION` 标识符形状（Task 3）③ `CoordinateMapper` 初始化写法（Task 5）④ `engineMultiPeriod()` / `assertInvariant` 的实际签名与备了哪些周期（Task 6）——**每一处都给了核实命令 + 对不上时的具体退路**，不是把决定推给实施者。Task 5 的四条 UIKit 测试只给了要点没给完整代码，因为它们必须照 `ChartContainerViewDrawingSessionTests.swift` 既有 fixture 写；已明写「先读一遍文件再写、不要新造一套 fixture」。

**3. 类型一致性**：`visibleDrawings(engine:panel:tick:)`（Task 1 定义 → Task 3 注释引用 → Task 5 调用）· `firstHit(in:point:mapper:tools:)`（Task 5 定义即调用）· `setSelection(id:panel:)` / `clearSelection()`（Task 2 定义 → Task 5、Task 6 调用）· `selectedDrawingID`（`DrawingSession` Task 2 → `KLineRenderState` Task 3 → dispatch Task 4）· `selectionRGBA(scheme:)`（Task 4 定义即调用）· `render(…isSelected:)`（Task 4 protocol + 1 生产 conformer + 3 测试替身，全部同 Task 迁完）—— 全对得上。

**4. 已知取舍（如实记录，供评审直接挑战）**
- `DrawingHitTester` 是新建文件而不是塞进 `RenderStateBuilder`：前者管「顺序 + tools dispatch」，后者管「集合 + 几何」，职责不同；且新文件不带 UIKit → host 可测（`RenderStateBuilder` 也不带，但把命中逻辑塞进"渲染状态构造器"会让职责糊掉）。
- 选中色内联系统蓝常量而不是读 asset catalog：渲染层在 SwiftPM 包内、只有 CoreGraphics，够不到 app target 的 `Assets.xcassets`；且 `AccentColor.colorset` 实测**没有自定义色值**，内联值与它一致。不精确匹配只是观感差异。
- `activate(tool:)` 无条件清选中（而不是只在 mode 真的从 `.select` 翻到 `.draw` 时清）：`activate` 本来就无条件写 `mode = .draw`，跟着它走判据最简单、也让不变量由构造保证；代价是「画线态里重复 activate」多跑一次 no-op 清空。

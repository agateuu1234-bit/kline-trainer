# 划线 P1c 第 3 片：拖节点 + §14 手势分支 · 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让选中线的黑点（节点）真的能拖，并把母 spec §14 剩下的那条单指手势分支补完 —— 且证明「没有可拖节点时，平移 / 切周期 / 缩放与今天逐字相同」。

**Architecture:** 分叉发生在**手指真正按下那一刻**（`KLineView.touchesBegan` 的只读钩子）捕获候选节点；pan `.began` 只按候选路由、不重做几何命中。拖动全程**不碰** `engine.drawings`（每写一次就立即写盘），几何走 `DrawingSession` 里一份瞬时覆盖，由 `RenderStateBuilder.visibleDrawings` 这个渲染/命中唯一真相**替换副本**；抬手或被接管时才调引擎第 5 个写入面**一次** ⇒「一次拖动 = 一条撤销记录」由构造保证。位移换算**直接在锚点量纲里做**（⛔ 不经屏幕投影往返），夹取是**幂等投影**（候选已合法就原样返回）。

**Tech Stack:** Swift 5 / SwiftPM（`ios/Contracts`）；`swift-testing`（`@Test`/`#expect`）与 XCTest 并存（跟随被改文件的既有风格）；UIKit 仅在 `#if canImport(UIKit)` 内，决策逻辑一律落 host 可测纯函数。

**Spec:** `docs/superpowers/specs/2026-09-28-drawing-tools-P1c-3-node-drag-design.md`（D134–D144，含 D134b/c/d/e、D135b/c/d、D140b/c；已 codex approve，账本键 `branch:drawing/p1c-3-node-drag@598cafc4`）

---

## Global Constraints

逐条从 spec 抄来，**每个任务的要求都隐含包含本节**。

- **worktree / 分支**：`.dev/worktree/drawing-p1c-3`，分支 `drawing/p1c-3-node-drag`，base `origin/main @ 25ad1c2a`。⛔ 不得 `cd` 回主仓。
- **契约**：`CONTRACT_VERSION` **不变**，`user_version` **不变（8）**，**无迁移**（D144）。
- **本片对 `DrawingEditRouter.swift` 只许三处改动**（D135d）：① `editableIgnoringGeometry` 访问级别 `private` → `internal`（⛔ 函数体一个字不改）；② 新增**一个** `private` 拖动门谓词；③ W1–W5 / E1–E5 十处各调它一次。**另加**本片新增的 `nodeDragPreconditions`（D134e）。⛔ 不得改任何既有判据的内容。
- **`DrawingSession` 的 mutator 一律 `internal`**（该文件头部大注释：mutator 一旦 public，包外就能绕过 `beginDrawingSession` / `endDrawingSessionIfActive`）。新增的拖动态 mutator 同此纪律。
- **`nodeDragOwner` 参与 observation；`nodeDragCurrent` 必须 `@ObservationIgnored`**（D135）。⛔ 不得把每帧写的那一半做成 observable。
- **⛔ 拖动中不得写 `engine.drawings`、不得递增 `drawingsRevision`**（D135；每 +1 即 `autosave(immediate: true)`，`TrainingView.swift:49-50`）。
- **⛔ 渲染读路径零写入**：`RenderStateBuilder.visibleDrawings` 不变量不成立时**只是不施加覆盖**，绝不收尾、绝不写状态（D135b 末段）。
- **⛔ `touchesBegan` 钩子零 engine 写入**：不 `settleDeceleration`、不 `rebuildRenderState`、不改任何状态（D140b）。
- **⛔ 候选的清除时机只有三个**：新的单指按下（覆盖）/ 按下时已有 ≥2 触摸 / 拖动手势终止或路由完毕。**一律不看 `touchesEnded` / `touchesCancelled`**（D140c）。
- **处置总则**（D135b）：**能写就写（就地定住），写下去是坏数据才作废**。周期变 ⇒ 作废；选中换线 / 第二根手指 ⇒ 就地定住。
- **测试纪律**：每条断言先自问「如果被测的那件事根本没发生，这条断言还会通过吗？」；⛔ 没有反假绿自检的断言不得写进代码。
- **`@Observable` 新增存储属性会改内存布局** ⇒ 本片给 `DrawingSession` 加了属性，**下任何结论前先 `rm -rf ios/Contracts/.build`**（否则 `swift test` 会在随机的、与改动无关的位置 SIGSEGV）。
- **数编译错误前先剥 ANSI 颜色码**：`swift test 2>&1 | sed 's/\x1b\[[0-9;]*m//g'`，否则「有错误」会被数成 0。
- **Catalyst**：scheme **`KlineTrainerContracts-Package`**，必须在 **`ios/Contracts`** 目录下跑，`xcodebuild test`（真执行，不是 `build-for-testing`）。
- **⛔ 跑构建 / 跑变异时不得改动工作树**（第 2 片实证：后台构建期间做变异 ⇒ 读到改到一半的源码，报 3 条假失败）。
- **⛔ 变异复原一律 `cp` 往返，禁止 `git checkout <file>`。**
- **⛔ 编辑脚本与 `git commit` 不得串在同一条命令里**（本片 spec 阶段实证：脚本失败而 commit 照跑 ⇒ 提交信息过度声称）。脚本前台跑 + 当场核验，commit 单独一条。

### 交付边界（给 user 的一个选择，⛔ 实施者不得自行决定）

本片实现面明显大于第 2 片。**Task 1–7 是零 UI 的纯逻辑 + 引擎层，自成一个可独立评审、可独立合入的单元**（与第 1 片拆成 1A / 1B 的先例同形，D109c）。

- **默认：整片一个 PR**（D110「逐片合入 main」的字面读法）。
- **备选：按 Task 7 / Task 8 之间的缝拆成两个顺序 PR**（先合 A 再开 B，⛔ 不叠罗汉）。

⚠️ **拆分需要 user 同意**（spec §11 的纪律是「不得合并两片」，拆一片为两个顺序 PR 属 D109c 那一类，需重走一次论证）。实施者**按默认走**，到 Task 12 前若体量明显失控，**停下来问 user**，⛔ 不得自行拆。

---

## 文件结构

### 新建（生产）

| 文件 | 职责 |
|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeDrag.swift` | 拖动的**纯几何决策层**：位移 → 锚点增量（D134d）+ 幂等夹取（D137）。仅 CoreGraphics，无 UIKit ⇒ host 全覆盖。与 `DrawingNodeGeometry.swift` 并排、同款风格 |

### 修改（生产）

| 文件 | 改什么 |
|---|---|
| `Drawing/DrawingSession.swift` | 拖动态两半（`nodeDragOwner` / `nodeDragCurrent`）+ 三个 mutator；点击选中门（D135c）；`clearSelection` / `assignSelection` 连带丢弃 |
| `Drawing/DrawingEditRouter.swift` | `editableIgnoringGeometry` 改 `internal`；新增 `nodeDragPreconditions`；新增 `private` 拖动门谓词 + 十处调用 |
| `TrainingEngine/TrainingEngine.swift` | 第 5 个写入面 `updateDrawingAnchor(id:anchorIndex:anchor:)` |
| `Render/RenderStateBuilder.swift` | `visibleDrawings` 在不变量成立时替换被拖那条的副本 |
| `ChartEngine/GestureClassifiers.swift` | 新增 `SinglePanRoute` + `singlePanRouteStep`（纯函数，host 可测）。⛔ `singlePanStep` 一个字不改 |
| `ChartEngine/ChartGestureArbiter.swift` | 两个新回调 + 路由 latch；`supersedeSinglePanForMultitouch` 的拖动分支 |
| `Render/KLineView.swift` | `onTouchDown` 钩子（与既有 `onBoundsChange` 同款） |
| `Render/ChartContainerView.swift` | 候选捕获（探针）+ 三个拖动回调接线 + D140 的四步顺序 |

### 新建（测试）

| 文件 | 覆盖 |
|---|---|
| `Tests/.../Drawing/DrawingNodeDragGeometryTests.swift` | T9④ / T10 四档 / N7 全档 |
| `Tests/.../Drawing/UpdateDrawingAnchorTests.swift` | T7 七门 / T7b 两档 |
| `Tests/.../Drawing/DrawingNodeDragSessionTests.swift` | 拖动态状态机 / T14 / T14b |
| `Tests/.../Drawing/NodeDragPreconditionsTests.swift` | N2 / N3 / N6 六档 / T1 / T13 |
| `Tests/.../Drawing/NodeDragEditRouterGateTests.swift` | T15 十档 / T15b |
| `Tests/.../ChartEngine/SinglePanRouteTests.swift` | N1 / T8 / T9①②③ |
| `Tests/.../Render/NodeDragCandidateTests.swift` | T11 / T12 规则层 / T3 / T6 / N4 / N8 / T4 |
| `Tests/.../Render/NodeDragPixelEvidenceTests.swift` | T5（Catalyst，UIKit-gated） |
| `Tests/.../ChartEngine/NodeDragSourceGuardTests.swift` | G2–G15 |

### 修改（测试 / 闸门）

| 文件 | 改什么 |
|---|---|
| `Tests/.../Drawing/DrawingUndoSourceGuardTests.swift` | U-G4 表 10 → 11，新接口独立一行（N5） |
| `.github/scripts/catalyst-uikit-baseline.txt` | 重新生成（脚本，⛔ 不手打） |
| `.github/scripts/fixtures/pass-main-current.log` | 用本轮真冷构建日志重裁 |
| `.github/scripts/catalyst-gate.test.sh` | 硬编码回显数字 |
| `docs/superpowers/acceptance/2026-09-01-finalize-alert-truthful-exit.md` | Catalyst 总数 |

### 新建（文档）

| 文件 | 内容 |
|---|---|
| `docs/superpowers/acceptance/2026-09-28-drawing-p1c-3-node-drag.md` | 非程序员验收清单（spec §9 补齐 + Q27 的 `.ray` 一条） |

---

# 阶段 A：纯逻辑 + 引擎（零 UI，host 全覆盖）

## Task 1: 位移换算 —— 直接在锚点量纲里算增量

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeDrag.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeDragGeometryTests.swift`

**Interfaces:**
- Consumes: `CoordinateMapper`（`Geometry/Geometry.swift:127`）、`DrawingAnchor`
- Produces:
  ```swift
  @MainActor public enum DrawingNodeDrag {
      public struct AnchorDelta: Equatable, Sendable {
          public let price: Double
          public let index: Int
      }
      /// D134d：位移 → 锚点增量。candleStep <= 0（空图）→ nil（调用方丢弃本帧）
      public static func anchorDelta(translation: CGPoint, mapper: CoordinateMapper) -> AnchorDelta?
  }
  ```

- [ ] **Step 1: 写失败测试（T9④ 的换算 + T10①② 的零位移恒等）**

新建 `DrawingNodeDragGeometryTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeDragGeometryTests.swift
// Spec: docs/superpowers/specs/2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D134d / D137）
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 拖动几何：位移换算（D134d）")
struct DrawingNodeDragDeltaTests {

    /// 造一个「投影落在非整像素上」的视口——⭐ 整像素参数会让缺陷碰巧不暴露（spec T10 自检）
    static func mapper(candleStep: CGFloat = 4.0025, pixelShift: CGFloat = 4,
                       startIndex: Int = 0, visibleCount: Int = 80,
                       frame: CGRect = CGRect(x: 0, y: 0, width: 320.2, height: 401),
                       priceMin: Double = 10, priceMax: Double = 23.7,
                       displayScale: CGFloat = 3) -> CoordinateMapper {
        let geo = ChartGeometry(candleStep: candleStep, candleWidth: candleStep * 0.8, gap: candleStep * 0.2)
        let vp = ChartViewport(startIndex: startIndex, visibleCount: visibleCount,
                               pixelShift: pixelShift, geometry: geo,
                               priceRange: PriceRange(min: priceMin, max: priceMax),
                               mainChartFrame: frame)
        return CoordinateMapper(viewport: vp, displayScale: displayScale)
    }

    @Test("零位移 ⇒ 两个轴的增量都逐位为 0（⇒ 新锚点恒等于原锚点）")
    func zeroTranslationIsIdentity() {
        let m = Self.mapper()
        let d = DrawingNodeDrag.anchorDelta(translation: .zero, mapper: m)
        #expect(d != nil)
        #expect(d?.price == 0.0)        // ⛔ 用 == 不用近似：乘 0 必须逐位为 0
        #expect(d?.index == 0)
    }

    @Test("纯横拖（translation.y == 0）⇒ 价位增量逐位为 0，只有下标变")
    func pureHorizontalDragDoesNotTouchPrice() {
        let m = Self.mapper()
        let d = DrawingNodeDrag.anchorDelta(translation: CGPoint(x: 40, y: 0), mapper: m)
        #expect(d?.price == 0.0)
        #expect(d?.index != 0)          // ⭐ 反假绿：证明这一档真的拖动了，不是「什么都没发生」
        #expect(d?.index == 10)         // 40 / 4.0025 = 9.994 → 四舍五入 10
    }

    @Test("纵向增量 = -translation.y × span / height，且**符号朝上为正**")
    func verticalDeltaSignAndMagnitude() {
        let m = Self.mapper()
        // 屏幕 y 向下为正 ⇒ 手指向上拖（负 y）应让价位**变大**
        let up = DrawingNodeDrag.anchorDelta(translation: CGPoint(x: 0, y: -40.1), mapper: m)
        #expect((up?.price ?? 0) > 0)   // ⭐ 负号写掉这条就红
        let span = 23.7 - 10.0
        #expect(abs((up?.price ?? 0) - 40.1 * span / 401.0) < 1e-12)
        let down = DrawingNodeDrag.anchorDelta(translation: CGPoint(x: 0, y: 40.1), mapper: m)
        #expect((down?.price ?? 0) < 0)
    }

    @Test("空图表（candleStep <= 0）⇒ 返回 nil，⛔ 绝不 Int(NaN) 崩")
    func emptyChartReturnsNil() {
        let geo = ChartGeometry(candleStep: 0, candleWidth: 0, gap: 0)
        let vp = ChartViewport(startIndex: 0, visibleCount: 0, pixelShift: 0, geometry: geo,
                               priceRange: PriceRange(min: 10, max: 23.7),
                               mainChartFrame: CGRect(x: 0, y: 0, width: 320.2, height: 401))
        let m = CoordinateMapper(viewport: vp, displayScale: 3)
        #expect(DrawingNodeDrag.anchorDelta(translation: CGPoint(x: 40, y: 40), mapper: m) == nil)
        // ⭐ 反假绿：同一串输入在正常视口下**确实**返回非 nil
        #expect(DrawingNodeDrag.anchorDelta(translation: CGPoint(x: 40, y: 40), mapper: Self.mapper()) != nil)
    }
}
```

⚠️ 上面三个构造已按**实测**签名写好：`ChartGeometry(candleStep:candleWidth:gap:)`（`Geometry.swift:15`）、`PriceRange(min:max:)`（`:83`）、`DrawingAnchor(period:candleIndex:price:)`（`Models.swift:214`，**period 在最前**）。⛔ 不要凭印象改成别的顺序。

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd "ios/Contracts" && swift test --filter DrawingNodeDragDeltaTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -30
```
Expected: 编译失败，`cannot find 'DrawingNodeDrag' in scope`。

- [ ] **Step 3: 写最小实现**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeDrag.swift
// Spec: docs/superpowers/specs/2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D134d / D137）
//
// 节点拖动的**纯几何决策层**：手指位移 → 锚点增量，以及夹取（幂等投影）。
// 工具无关的部分与 DrawingNodeGeometry 并排；跨平台仅 CoreGraphics（无 UIKit）⇒ host swift test 全覆盖。

import CoreGraphics

@MainActor
public enum DrawingNodeDrag {

    /// 一次拖动位移换算出的**锚点增量**。⛔ 两个分量都直接在锚点的量纲里，绝不经过屏幕投影。
    public struct AnchorDelta: Equatable, Sendable {
        public let price: Double
        public let index: Int
    }

    /// D134d：位移 → 锚点增量。**全程不碰屏幕投影**。
    ///
    /// ⛔ **绝不写成「原锚点投影 + translation 再反算」**：`priceToY` 把结果对齐到整像素
    /// （`Geometry.swift:143-148`）而 `yToPrice`（`:165`）不带舍入 ⇒ 往返**不是恒等**。
    /// 实测（spec D134d）：displayScale=3 / 高 401 / 价区 10…23.7 下，200 个合法价位往返最大偏差
    /// 0.0057；单点 15.123456 → 15.124688，`==` 为 false。后果：纯横拖静默改价、拖回原处恢复不了
    /// ⇒ 门 ⑥ 永远触发不了 ⇒ 白写一次盘并挤掉深度 1 撤销栈里那条真编辑。
    ///
    /// **符号**：`priceToY` 里 y 随价位**递减**（`raw = maxY - ratio × height`）⇒ 前面这个负号
    /// **是必须的**，⛔ 写掉它线会朝反方向跑。
    ///
    /// `candleStep <= 0`（空图表）→ `nil`：除法会产出 inf/NaN，而 `Int(NaN)` 是 **trap**（进程崩）。
    /// 既有 `handleDrawingTap` 有同款守卫（`ChartContainerView.swift:337`，另见 `:279` / `:295`）。
    public static func anchorDelta(translation: CGPoint, mapper: CoordinateMapper) -> AnchorDelta? {
        let step = mapper.viewport.geometry.candleStep
        let height = mapper.viewport.mainChartFrame.height
        guard step > 0, height > 0 else { return nil }
        let span = mapper.viewport.priceRange.max - mapper.viewport.priceRange.min
        guard span > 0, span.isFinite else { return nil }
        // translation.y == 0 ⇒ 乘 0 ⇒ 逐位为 0（幂等的地基）
        let priceDelta = -Double(translation.y) * span / Double(height)
        guard priceDelta.isFinite else { return nil }
        let rawIndex = (translation.x / step).rounded(.toNearestOrAwayFromZero)
        guard rawIndex.isFinite, abs(rawIndex) < CGFloat(Int.max / 2) else { return nil }
        return AnchorDelta(price: priceDelta, index: Int(rawIndex))
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd "ios/Contracts" && swift test --filter DrawingNodeDragDeltaTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -20
```
Expected: 4 tests passed。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeDrag.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeDragGeometryTests.swift
git commit -m "P1c-3 Task1：位移换算直接在锚点量纲里做（D134d）

两个轴都从 translation 直接算增量，⛔ 不经屏幕投影往返（priceToY 舍入而
yToPrice 不舍入 ⇒ 往返不恒等 ⇒ 纯横拖会静默改价、拖回原处恢复不了）。
零位移乘 0 ⇒ 逐位恒等，这是 D137 幂等性的地基。
candleStep <= 0 返 nil（Int(NaN) 是 trap）。"
```

---

## Task 2: 幂等夹取 —— 判据是「锚点必须产出 `.real`」

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeDrag.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeDragGeometryTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `DrawingNodeDrag.anchorDelta(translation:mapper:) -> AnchorDelta?`；`DrawingNodeGeometry.marks(for:mapper:isVisible:maxAnchors:)`（`DrawingNodeGeometry.swift:39`）；`DrawingTool.isVisible(drawing:mapper:)`
- Produces:
  ```swift
  /// 该锚点在 marks() 里是否产出 .real（D137 的唯一后置条件）
  public static func producesRealNode(anchor: DrawingAnchor, in drawing: DrawingObject,
                                      anchorIndex: Int, mapper: CoordinateMapper,
                                      tool: any DrawingTool) -> Bool
  /// D134d + D137：位移 → 新锚点（已夹取）。nil = 连边界都找不到合法位置（fail-closed）
  public static func draggedAnchor(drawing: DrawingObject, anchorIndex: Int, translation: CGPoint,
                                   mapper: CoordinateMapper, tool: any DrawingTool) -> DrawingAnchor?
  ```

- [ ] **Step 1: 写失败测试（N7 全档 + T10 四档）**

追加到 `DrawingNodeDragGeometryTests.swift`：

```swift
@MainActor
@Suite("P1c-3 拖动几何：幂等夹取（D137）")
struct DrawingNodeDragClampTests {

    static func hLine(price: Double, candleIndex: Int, sub: LineSubType = .straight) -> DrawingObject {
        DrawingObject(toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m15, candleIndex: candleIndex, price: price)],
                      isExtended: sub == .ray, panelPosition: 0, revealTick: 0,
                      period: .m15, lineSubType: sub)
    }

    // ⭐ 非整像素价位：整像素价位会让往返**碰巧**恒等 ⇒ 缺陷原样存在而测试全绿
    static let oddPrice = 15.123456

    @Test("① 零位移 ⇒ 新锚点**逐字段**等于原锚点（price 用 ==，⛔ 不用近似）")
    func zeroTranslationReturnsIdenticalAnchor() {
        let m = DrawingNodeDragDeltaTests.mapper()
        let d = Self.hLine(price: Self.oddPrice, candleIndex: 40)
        let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0, translation: .zero,
                                                mapper: m, tool: HorizontalLineTool())
        #expect(out?.price == Self.oddPrice)
        #expect(out?.candleIndex == 40)
        #expect(out?.period == .m15)
    }

    @Test("② 纯横拖 ⇒ price 逐位不变，只有 candleIndex 变")
    func pureHorizontalKeepsPriceBitExact() {
        let m = DrawingNodeDragDeltaTests.mapper()
        let d = Self.hLine(price: Self.oddPrice, candleIndex: 40)
        let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0,
                                                translation: CGPoint(x: 20, y: 0),
                                                mapper: m, tool: HorizontalLineTool())
        #expect(out?.price == Self.oddPrice)        // ⛔ ==，不是近似
        #expect(out?.candleIndex == 45)             // 20/4.0025 = 4.997 → 5
    }

    @Test("④ 边界档：价位略超 priceRange 但舍入后仍可见 ⇒ 零位移照样逐位恒等")
    func boundaryPriceOutsideRangeButStillRealIsUntouched() {
        let m = DrawingNodeDragDeltaTests.mapper()
        let boundary = 23.701                        // ⭐ 必须真的超出上限
        #expect(boundary > m.viewport.priceRange.max)       // ⭐ 先断言它确实超出，否则这档只是①的复制品
        let d = Self.hLine(price: boundary, candleIndex: 40)
        // ⭐ 先断言它确实产出 .real，否则「夹了也无所谓」的实现会假绿
        #expect(DrawingNodeDrag.producesRealNode(anchor: d.anchors[0], in: d, anchorIndex: 0,
                                                 mapper: m, tool: HorizontalLineTool()))
        let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0, translation: .zero,
                                                mapper: m, tool: HorizontalLineTool())
        #expect(out?.price == boundary)              // ⛔ 无条件夹会把它改成 23.7 ⇒ 这条红
    }

    @Test("N7 框内不夹：拖到仍然合法的位置 ⇒ 锚点就是候选值本身，没有被额外修正")
    func inBoundsCandidateIsNotModified() {
        let m = DrawingNodeDragDeltaTests.mapper()
        let d = Self.hLine(price: Self.oddPrice, candleIndex: 40)
        let delta = DrawingNodeDrag.anchorDelta(translation: CGPoint(x: 8, y: -8), mapper: m)!
        let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0,
                                                translation: CGPoint(x: 8, y: -8),
                                                mapper: m, tool: HorizontalLineTool())
        #expect(out?.price == Self.oddPrice + delta.price)   // ⭐「恒夹到边界」的实现这条会红
        #expect(out?.candleIndex == 40 + delta.index)
    }

    @Test("N7 四个方向：拖到框外任意远 ⇒ 夹回后**仍产出 .real**")
    func clampKeepsNodeReal() {
        let m = DrawingNodeDragDeltaTests.mapper()
        let tool = HorizontalLineTool()
        for (dx, dy) in [(0.0, -5000.0), (0.0, 5000.0), (-5000.0, 0.0), (5000.0, 0.0)] {
            let d = Self.hLine(price: Self.oddPrice, candleIndex: 40)
            let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0,
                                                    translation: CGPoint(x: dx, y: dy),
                                                    mapper: m, tool: tool)
            #expect(out != nil, "方向 (\(dx),\(dy)) 夹取返回了 nil")
            let moved = Self.hLine(price: out!.price, candleIndex: out!.candleIndex)
            // ⛔ 判据是「产出 .real」，不是 visibleGeometry != nil —— 后者在 .straight 上空洞成立
            #expect(DrawingNodeDrag.producesRealNode(anchor: out!, in: moved, anchorIndex: 0,
                                                     mapper: m, tool: tool),
                    "方向 (\(dx),\(dy)) 夹取后节点不是 .real")
        }
    }

    @Test("N7 `.ray` 右缘：严格 fail-closed ⇒ 夹取必须避开最后一根，线不得整条消失")
    func rayRightEdgeIsFailClosed() {
        let m = DrawingNodeDragDeltaTests.mapper()
        let tool = HorizontalLineTool()
        let d = Self.hLine(price: Self.oddPrice, candleIndex: 40, sub: .ray)
        let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0,
                                                translation: CGPoint(x: 5000, y: 0),
                                                mapper: m, tool: tool)
        #expect(out != nil)
        let moved = Self.hLine(price: out!.price, candleIndex: out!.candleIndex, sub: .ray)
        #expect(HorizontalLineTool.visibleGeometry(for: moved, mapper: m) != nil, "`.ray` 被夹成了不可见")
        #expect(DrawingNodeDrag.producesRealNode(anchor: out!, in: moved, anchorIndex: 0,
                                                 mapper: m, tool: tool))
    }

    @Test("N7 非整像素右缘：`.straight` 线照常可见，坏的是节点变 proxy ⇒ 必须仍能再次抓住")
    func straightNonPixelAlignedRightEdgeKeepsNodeGrabbable() {
        // ⭐ 实证参数：最后一根(79) 未舍入 320.1975 → 舍入 320.3333 > 右缘 320.2；合法最大下标 78
        let m = DrawingNodeDragDeltaTests.mapper()
        let tool = HorizontalLineTool()
        let d = Self.hLine(price: Self.oddPrice, candleIndex: 40)
        let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0,
                                                translation: CGPoint(x: 5000, y: 0),
                                                mapper: m, tool: tool)
        #expect(out != nil)
        #expect(out!.candleIndex <= 78, "夹到了 \(out!.candleIndex)：边界下标必须在**像素舍入之后**的空间里选")
        let moved = Self.hLine(price: out!.price, candleIndex: out!.candleIndex)
        // ⭐ 关键：`.straight` 的 visibleGeometry 恒非 nil（不看锚点 x）⇒ 只有 hitTestNode 接得住
        #expect(HorizontalLineTool.visibleGeometry(for: moved, mapper: m) != nil)
        let hit = DrawingNodeGeometry.hitTestNode(
            point: CGPoint(x: m.indexToX(out!.candleIndex), y: m.priceToY(out!.price)),
            drawing: moved, mapper: m,
            isVisible: tool.isVisible(drawing: moved, mapper: m),
            maxAnchors: tool.requiredAnchors.upperBound)
        #expect(hit == 0, "夹取后节点抓不住了（变成 proxy）")
    }
}
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd "ios/Contracts" && swift test --filter DrawingNodeDragClampTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -30
```
Expected: 编译失败（`draggedAnchor` / `producesRealNode` 未定义）。

- [ ] **Step 3: 写实现**

追加进 `DrawingNodeDrag.swift`（`anchorDelta` 之后）：

```swift
    /// D137 的**唯一后置条件**：该锚点在 `marks()` 里产出 `.real`。
    ///
    /// ⛔ **不要退回「`visibleGeometry != nil`」**：`.straight` 的几何完全不看锚点 x
    /// （`HorizontalLineTool.swift:54-55`）⇒ 锚点被夹到右缘之外时**线照常可见**，而 `marks`
    /// 会把越界的 x 转成 `.proxy`（`DrawingNodeGeometry.swift:73-74`）、`hitTestNode` 又把 proxy
    /// 排除在命中集合之外（`:104`）⇒ **线还在、黑点却再也抓不住**。那条判据在 `.straight` 上
    /// 被**空洞地满足**（spec 第 12 轮实证）。
    ///
    /// 本条**蕴含**另外两件事：① 线可见（`marks` 在 `isVisible == false` 时直接返回空数组，`:41`）；
    /// ② 节点还抓得住（D131：命中集合 ≡ 渲染集合里的 `.real`）。
    public static func producesRealNode(anchor: DrawingAnchor, in drawing: DrawingObject,
                                        anchorIndex: Int, mapper: CoordinateMapper,
                                        tool: any DrawingTool) -> Bool {
        guard drawing.anchors.indices.contains(anchorIndex) else { return false }
        var anchors = drawing.anchors
        anchors[anchorIndex] = anchor
        // ⚠️ `DrawingObject` **没有** `withAnchors`（实测）⇒ 就地用完整成员 init 逐字段拷贝，
        //    照 `setDrawingLocked`（`TrainingEngine.swift:1230` 起）的范式。
        //    ⛔ 不要为此给 `DrawingObject` 加新 API（YAGNI，且会扩大本片对 Models 的改动面）。
        //    ⚠️ `period` **显式传** `drawing.period`：init 的默认行为是从 `anchors.first?.period` 现取，
        //       候选锚点若周期不同会静默改掉整条线的周期。
        let candidate = DrawingObject(
            id: drawing.id, toolType: drawing.toolType, anchors: anchors,
            isExtended: drawing.isExtended, panelPosition: drawing.panelPosition,
            revealTick: drawing.revealTick, period: drawing.period,
            lineSubType: drawing.lineSubType, lineStyle: drawing.lineStyle,
            thickness: drawing.thickness, colorToken: drawing.colorToken,
            labelMode: drawing.labelMode, locked: drawing.locked,
            text: drawing.text, fontSize: drawing.fontSize,
            textColorToken: drawing.textColorToken, textForm: drawing.textForm,
            tailAnchor: drawing.tailAnchor)
        let marks = DrawingNodeGeometry.marks(
            for: candidate, mapper: mapper,
            isVisible: tool.isVisible(drawing: candidate, mapper: mapper),
            maxAnchors: tool.requiredAnchors.upperBound)
        return marks.contains { if case .real(let i, _) = $0 { return i == anchorIndex }; return false }
    }

    /// D134d + D137：把一次位移变成**已夹取**的新锚点。
    ///
    /// ⭐⭐ **夹取是一个幂等的投影**：候选若已满足后置条件 ⇒ **原样返回、一个字节不改**；
    /// 只有不满足时才修正。幂等性直接给出三条保证：零位移恒等 / 纯横拖不改价 / 拖走再拖回逐位恢复。
    /// ⛔ **绝不无条件夹**：可见性按**像素舍入之后**的 y 判（`priceToY` 先舍入、`marks` 再比较），
    /// 比「价位落在 priceRange 内」更宽。实测（spec D137）：价位 23.701 已超区间上限，投影 y = -0.0293
    /// 舍入到 -0.0 ⇒ 仍是 `.real`；无条件夹会把它改成 23.7，**即使手指纵向一动没动**。
    ///
    /// 修正时**必须在像素舍入之后的坐标空间里选边界**，⛔ 不得直接用 `startIndex + visibleCount - 1`：
    /// 实测 candleStep=4.0025 / pixelShift=4 / 右缘 320.2 时，第 79 根舍入到 320.3333 已越界，
    /// 合法最大下标是 78。
    ///
    /// 返回 `nil` = 连边界都找不到合法位置（fail-closed；调用方丢弃本帧，⛔ 不得写出不合法锚点）。
    public static func draggedAnchor(drawing: DrawingObject, anchorIndex: Int, translation: CGPoint,
                                     mapper: CoordinateMapper, tool: any DrawingTool) -> DrawingAnchor? {
        guard drawing.anchors.indices.contains(anchorIndex) else { return nil }
        let old = drawing.anchors[anchorIndex]
        guard let d = anchorDelta(translation: translation, mapper: mapper) else { return nil }
        let (rawIndex, overflow) = old.candleIndex.addingReportingOverflow(d.index)
        let candidateIndex = overflow ? (d.index > 0 ? Int.max : Int.min) : rawIndex
        let candidate = DrawingAnchor(period: old.period, candleIndex: candidateIndex,
                                      price: old.price + d.price)
        // ① 幂等：已经合法就原样返回
        if producesRealNode(anchor: candidate, in: drawing, anchorIndex: anchorIndex,
                            mapper: mapper, tool: tool) {
            return candidate
        }
        // ② 不合法才修正：先把价位调到最近的合法值，再把下标调到最近的合法下标
        let priced = clampPrice(candidate, in: drawing, anchorIndex: anchorIndex,
                                mapper: mapper, tool: tool)
        return clampIndex(priced, in: drawing, anchorIndex: anchorIndex, mapper: mapper, tool: tool)
    }

    /// 价位方向的修正：在 `[priceRange.min, priceRange.max]` 内二分找最接近候选、且 y 落在框内的值。
    /// ⚠️ 判据用 `priceToY` **舍入之后**的结果比较（与 `marks` 同一判据），⛔ 不比较价位本身。
    private static func clampPrice(_ a: DrawingAnchor, in drawing: DrawingObject, anchorIndex: Int,
                                   mapper: CoordinateMapper, tool: any DrawingTool) -> DrawingAnchor {
        let frame = mapper.viewport.mainChartFrame
        let y = mapper.priceToY(a.price)
        guard !(y.isFinite && y >= frame.minY && y <= frame.maxY) else { return a }
        let target = y < frame.minY ? frame.minY : frame.maxY
        var lo = mapper.viewport.priceRange.min, hi = mapper.viewport.priceRange.max
        // 目标 y 对应的价位方向：y 越小价位越大
        var best = mapper.yToPrice(target)
        for _ in 0..<64 {                       // 定次数二分：避免浮点比较写出死循环
            let mid = (lo + hi) / 2
            let my = mapper.priceToY(mid)
            if my.isFinite && my >= frame.minY && my <= frame.maxY { best = mid }
            if my < target { lo = mid } else { hi = mid }
        }
        return DrawingAnchor(period: a.period, candleIndex: a.candleIndex, price: best)
    }

    /// 下标方向的修正：**在像素舍入之后的空间里**，从候选往回找最近的合法下标。
    /// ⛔ 不得直接用 `startIndex + visibleCount - 1`（实测它可能已越界，见本类型头注）。
    private static func clampIndex(_ a: DrawingAnchor, in drawing: DrawingObject, anchorIndex: Int,
                                   mapper: CoordinateMapper, tool: any DrawingTool) -> DrawingAnchor? {
        if producesRealNode(anchor: a, in: drawing, anchorIndex: anchorIndex,
                            mapper: mapper, tool: tool) { return a }
        let vp = mapper.viewport
        let lo = vp.startIndex, hi = vp.startIndex + max(0, vp.visibleCount - 1)
        guard lo <= hi else { return nil }
        let start = min(max(a.candleIndex, lo), hi)
        // 从夹进窗口的那个下标出发，向**窗口内**双向扫，取第一个真正产出 .real 的
        for step in 0...(hi - lo) {
            for cand in [start - step, start + step] where cand >= lo && cand <= hi {
                let t = DrawingAnchor(period: a.period, candleIndex: cand, price: a.price)
                if producesRealNode(anchor: t, in: drawing, anchorIndex: anchorIndex,
                                    mapper: mapper, tool: tool) { return t }
            }
        }
        return nil                               // fail-closed：整个窗口都没有合法位置
    }
```

⚠️ **已实测确认**：`DrawingObject` **没有** `withAnchors`（只有 `withStyle`），且 `DrawingAnchor` 的 init 是 **`(period:candleIndex:price:)`** 这个顺序、`ChartGeometry` 是 **`(candleStep:candleWidth:gap:)`** —— 上面的代码已按真实签名写好，⛔ 不要再改回去。

- [ ] **Step 4: 跑测试确认通过**

```bash
cd "ios/Contracts" && swift test --filter DrawingNodeDragClampTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -20
```
Expected: 7 tests passed。⚠️ 若 `straightNonPixelAlignedRightEdgeKeepsNodeGrabbable` 失败并报「夹到了 79」，说明 `clampIndex` 退化成了朴素写法 —— 那正是这条测试存在的理由。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeDrag.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeDragGeometryTests.swift
git commit -m "P1c-3 Task2：幂等夹取，判据是「锚点必须产出 .real」（D137）

候选已合法就原样返回（幂等）⇒ 零位移恒等 / 纯横拖不改价 / 拖走再拖回逐位
恢复三条都是推论。后置条件用 marks() 产出 .real 表达，蕴含「线可见」与
「节点还抓得住」——⛔ 不用 visibleGeometry != nil，它在 .straight 上空洞成立。
边界下标在**像素舍入之后**的空间里选（实测最后一根可能已越界）。"
```

---

## Task 3: 引擎第 5 个写入面 `updateDrawingAnchor`

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（紧邻 `setDrawingLocked`，`:1230` 之后）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoSourceGuardTests.swift:291-315`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/UpdateDrawingAnchorTests.swift`

**Interfaces:**
- Consumes: `recordDrawingUndoDelta(.replaced(before:after:at:))`（`:1554`）、`drawingsRevision`
- Produces: `func updateDrawingAnchor(id: DrawingID, anchorIndex: Int, anchor: DrawingAnchor) -> Bool`（`@discardableResult`，`internal`）

- [ ] **Step 1: 写失败测试（T7 七门 + T7b 两档）**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/UpdateDrawingAnchorTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D136 门列表 / T7 / T7b）
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 引擎第 5 个写入面：updateDrawingAnchor（D136）")
struct UpdateDrawingAnchorTests {

    /// ⭐ 每一档的形状都是「先证明放行、再关掉那道门证明被拒」——⛔ 只断言 false 会被恒 false 的实现骗过
    static func engineWithOneLine() -> (TrainingEngine, DrawingObject) { /* 见 Step 1b */ }

    @Test("T7b② 不相等档：真的改了 ⇒ 写进 drawings、revision +1、撤销栈恰好多一条")
    func changedAnchorIsActuallyWritten() throws {
        let (e, line) = Self.engineWithOneLine()
        let base = e.drawingsRevision
        let newAnchor = DrawingAnchor(period: line.period,
                                      candleIndex: line.anchors[0].candleIndex + 3,
                                      price: line.anchors[0].price + 1.5)
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: newAnchor))
        // ⛔ 不得只断言返回值——返 true 不等于真的写了（门⑥ 写反时正是「返 true 但没写」）
        #expect(e.drawings.first(where: { $0.id == line.id })?.anchors[0] == newAnchor)
        #expect(e.drawingsRevision == base + 1)
        #expect(e.drawingUndoEntryForTesting != nil)
    }

    @Test("T7b① 相等档：内容没变 ⇒ 返 true 但 revision 不变、撤销栈不变")
    func unchangedAnchorIsZeroSideEffect() throws {
        let (e, line) = Self.engineWithOneLine()
        _ = e.updateDrawingAnchor(id: line.id, anchorIndex: 0,
                                  anchor: DrawingAnchor(period: line.period,
                                                        candleIndex: line.anchors[0].candleIndex + 3,
                                                        price: line.anchors[0].price + 1.5))
        let afterFirst = e.drawingsRevision
        let stack = e.drawingUndoEntryForTesting
        let same = e.drawings.first(where: { $0.id == line.id })!.anchors[0]
        #expect(e.updateDrawingAnchor(id: line.id, anchorIndex: 0, anchor: same))
        #expect(e.drawingsRevision == afterFirst)      // ⛔ 零副作用
        #expect(e.drawingUndoEntryForTesting == stack) // ⛔ 不得把那条真编辑挤掉
    }
}
```

- [ ] **Step 1b: 补齐测试夹具**

`engineWithOneLine()` 照既有测试的造法写 —— **先读** `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift` 里已有的引擎夹具（搜 `func engine` / `injectDrawingsForTesting`），**复用**它，⛔ 不新造一套：

```bash
grep -n "injectDrawingsForTesting\|static func engine" ios/Contracts/Tests/KlineTrainerContractsTests/*.swift | head -20
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd "ios/Contracts" && swift test --filter UpdateDrawingAnchorTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -20
```
Expected: `value of type 'TrainingEngine' has no member 'updateDrawingAnchor'`。

- [ ] **Step 3: 写实现**

在 `TrainingEngine.swift` 的 `setDrawingLocked` 之后插入：

```swift
    /// D136（P1c 第 3 片）：`drawings` 的**第 5 个**写入面 —— 改某条线的某个锚点。
    /// 唯一生产调用点 = 节点拖动的收尾路径（`ChartContainerView.Coordinator`）。
    ///
    /// **门列表**（逐条对照既有写入面重新论证，⛔ 不照抄）：
    ///   ⓪ 非复盘（D34 纵深，同 `updateDrawingStyle` / `deleteDrawing(id:)`）
    ///   ① id 非空 + 全局**恰好**一条（D66）
    ///   ② `!old.locked`（D60）——⚠️ 这是**第二层**，第一层在探针（D139）
    ///   ②b 工具门（本构建不懂其样式语义的工具，同样不懂它的锚点语义）
    ///   ③ raw-aware 两道（D61）：改锚点是「部分改写」，与删整条性质不同
    ///   ④ `anchorIndex` 在范围内 —— Swift 数组越界是 **trap**，`do/catch` 接不住
    ///   ⑤ `anchor.period == old.period`（D29 + N8）：混周期锚点 = 后续 candleIndex 被按错误周期解释
    ///   ⑥ **内容未变 ⇒ 返 `true` 且零副作用**（D80）
    ///
    /// ⛔ **本接口不含、也不声称含几何门** —— 引擎没有 mapper（同 `deleteDrawing(id:)` 头注）。
    /// 夹回边界发生在界面层（D137）。
    @discardableResult
    func updateDrawingAnchor(id: DrawingID, anchorIndex: Int, anchor: DrawingAnchor) -> Bool {
        guard flow.mode != .review else { return false }                       // ⓪
        guard !id.isEmpty else { return false }                                // ①
        let matches = drawings.indices.filter { drawings[$0].id == id }
        guard matches.count == 1, let i = matches.first else { return false }  // ①
        let old = drawings[i]
        guard !old.locked else { return false }                                // ②
        guard DrawingStyleAvailability.isEditableToolType(old.toolType) else { return false }  // ②b
        guard !loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: [id]),
              !loadedDrawingsLossy.hasKnownFutureFields(liveIds: [id]) else { return false }   // ③
        guard old.anchors.indices.contains(anchorIndex) else { return false }  // ④
        guard anchor.period == old.period else { return false }                // ⑤
        var anchors = old.anchors
        anchors[anchorIndex] = anchor
        // 逐字段拷贝，只换 anchors。⚠️ `isExtended` 由 lineSubType 派生、**不由锚点派生**
        //（`Models.swift:260` / `:320-322`）⇒ 拷贝即可；`period` **显式传 old.period**
        //（⛔ 不让 init 从 anchors.first 现取——那会让门 ⑤ 变成摆设）。
        let updated = DrawingObject(
            id: old.id, toolType: old.toolType, anchors: anchors,
            isExtended: old.isExtended, panelPosition: old.panelPosition,
            revealTick: old.revealTick, period: old.period,
            lineSubType: old.lineSubType, lineStyle: old.lineStyle,
            thickness: old.thickness, colorToken: old.colorToken,
            labelMode: old.labelMode, locked: old.locked,
            text: old.text, fontSize: old.fontSize,
            textColorToken: old.textColorToken, textForm: old.textForm,
            tailAnchor: old.tailAnchor)
        // ⑥ D80：**短路的条件是「相等」**（生产范式 `guard updated != old else { return true }`，`:1212`）。
        // ⛔ 写反成「不相等就短路」会恰好覆盖所有真正改变锚点的拖动 ⇒ 松手报成功却没写、线当场弹回。
        guard updated != old else { return true }
        drawings[i] = updated
        recordDrawingUndoDelta(.replaced(before: old, after: updated, at: i))
        drawingsRevision += 1
        return true
    }
```

- [ ] **Step 4: 跑测试确认通过 + 同步 U-G4 穷尽性守卫（N5）**

先跑：
```bash
cd "ios/Contracts" && swift test --filter UpdateDrawingAnchorTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -20
```
Expected: 2 passed。

再跑穷尽性守卫，**它必须当场变红**（新写入面还没进表）：
```bash
cd "ios/Contracts" && swift test --filter DrawingUndoSourceGuardTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -25
```
Expected: `test_uG4_engineDrawingsWriteSitesAreExhaustivelyClassified` **FAIL**，报「有 1 处 drawings 写入不在权威分类表里」+ 总数 10 ≠ 11。
⭐ **这条红是必须的** —— 它证明那道守卫真的在看着新写入面；若它没红，说明守卫已失效，**先修守卫再继续**。

然后改 `DrawingUndoSourceGuardTests.swift:291-315`：
```swift
        let expected: [String: Int] = [
            "deleteDrawing":           2,
            "appendDrawing":           1,
            "updateDrawingStyle":      1,
            "updateDrawingAnchor":     1,   // P1c 第 3 片新增（D136）：一次写入，紧贴 recordDrawingUndoDelta
            "setDrawingLocked":        1,
            "applyUndoEntry":          3,
            "init":                     1,
            "injectDrawingsForTesting": 1,
        ]
```
以及总数断言：
```swift
        XCTAssertEqual(total, 11, "权威分类表的合计是 11（P1c 第 3 片新增 updateDrawingAnchor，D136）")
```

重跑，Expected: PASS。

- [ ] **Step 5: 复跑相邻守卫（L12），确认本片没把它撞红**

```bash
cd "ios/Contracts" && swift test --filter TrainingEngineDrawingSessionTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -20
```
⚠️ spec D136 末段：`setDrawingLocked` 有一条「非拷贝直传的 `locked:` 写入恰好 1 处」的 L12 守卫。本接口写的是 `locked: old.locked`（拷贝直传），**预期不计入** —— 但这是**预期，不是事实**。
- 若它**绿**：在提交信息里写明「L12 实跑确认不受影响」。
- 若它**红**：⛔ 不许改守卫的数字来凑绿；先读它的判据（`TrainingEngineDrawingSessionTests.swift` 搜 `locked:`），确认它到底在数什么，再决定是调整本接口的写法还是**有理有据地**更新守卫。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/UpdateDrawingAnchorTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoSourceGuardTests.swift
git commit -m "P1c-3 Task3：引擎第 5 个写入面 updateDrawingAnchor（D136）+ U-G4 同步 10→11

七道拒收门逐条论证（⛔ 不照抄既有面），门⑥ 的短路条件是**相等**
（写反会恰好覆盖所有真正改变锚点的拖动 ⇒ 松手报成功却没写、线当场弹回）。
U-G4 穷尽性守卫在加表之前**先实测变红**，证明它真的在看着新写入面。"
```

---

## Task 4: `DrawingSession` 的拖动态两半 + 同生同死

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift`（`pendingAnchors`（`:148`）附近，与既有瞬时态放一起）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeDragSessionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct NodeDragOwner: Equatable, Sendable {
      public let panel: PanelId
      public let drawingID: DrawingID
      public let anchorIndex: Int
      public let grabPoint: CGPoint
  }
  public private(set) var nodeDragOwner: NodeDragOwner?          // 参与 observation
  @ObservationIgnored public private(set) var nodeDragCurrent: DrawingAnchor?
  func beginNodeDrag(_ owner: NodeDragOwner, anchor: DrawingAnchor)   // 占槽：两半同时赋值
  func updateNodeDragCurrent(_ anchor: DrawingAnchor)                 // 每帧：只动 current
  func endNodeDrag()                                                   // 清槽：两半同时清
  ```

- [ ] **Step 1: 写失败测试（两半同生同死 + 每帧只动 current）**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeDragSessionTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D135 两半 / D135c 生命周期）
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 拖动态：两半同生同死（D135）")
struct DrawingNodeDragSessionTests {

    static func owner(_ id: DrawingID = "L1") -> DrawingSession.NodeDragOwner {
        .init(panel: .upper, drawingID: id, anchorIndex: 0, grabPoint: CGPoint(x: 10, y: 20))
    }
    static func anchor(_ price: Double) -> DrawingAnchor {
        DrawingAnchor(period: .m15, candleIndex: 40, price: price)
    }

    @Test("占槽 ⇒ 两半同时非空；清槽 ⇒ 两半同时为空")
    func bothHalvesLiveAndDieTogether() {
        let s = DrawingSession()
        #expect(s.nodeDragOwner == nil && s.nodeDragCurrent == nil)   // ⭐ 起点对照
        s.beginNodeDrag(Self.owner(), anchor: Self.anchor(15.5))
        #expect(s.nodeDragOwner != nil && s.nodeDragCurrent != nil)
        s.endNodeDrag()
        #expect(s.nodeDragOwner == nil && s.nodeDragCurrent == nil)
    }

    @Test("每帧更新只动 current，owner 一个字节不变")
    func perFrameUpdateTouchesOnlyCurrent() {
        let s = DrawingSession()
        let o = Self.owner()
        s.beginNodeDrag(o, anchor: Self.anchor(15.5))
        s.updateNodeDragCurrent(Self.anchor(16.5))
        #expect(s.nodeDragCurrent?.price == 16.5)     // ⭐ 反假绿：证明它真的变了
        #expect(s.nodeDragOwner == o)                  // owner 不受影响
    }

    @Test("没占槽时的每帧更新是 no-op（fail-closed，⛔ 不得凭空造出半个拖动态）")
    func updateWithoutOwnerIsNoOp() {
        let s = DrawingSession()
        s.updateNodeDragCurrent(Self.anchor(16.5))
        #expect(s.nodeDragCurrent == nil)
        // ⭐ 反向对照：占槽之后同一次调用**确实**生效
        s.beginNodeDrag(Self.owner(), anchor: Self.anchor(15.5))
        s.updateNodeDragCurrent(Self.anchor(16.5))
        #expect(s.nodeDragCurrent?.price == 16.5)
    }
}
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd "ios/Contracts" && rm -rf .build && swift test --filter DrawingNodeDragSessionTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -20
```
⚠️ **先 `rm -rf .build`** —— 本任务给 `@Observable` 类加存储属性，会改实例内存布局；增量产物没全重建时 `swift test` 会在**随机的、与改动无关的位置** SIGSEGV。
Expected: `has no member 'beginNodeDrag'`。

- [ ] **Step 3: 写实现**

在 `DrawingSession.swift` 的 `pendingAnchorPanel` 之后插入：

```swift
    /// D135（P1c 第 3 片）：节点拖动的**瞬时态**，与 `pendingAnchors` 同族 —— 瞬时、**绝不落盘**、
    /// 退出画线即清。⛔ 拖动期间**不碰** `engine.drawings`：`drawingsRevision` 每 +1 就触发一次
    /// `autosave(immediate: true)`（`UI/TrainingView.swift:49-50`）⇒ 逐帧写正式数组 = 每秒约 60 次写盘。
    ///
    /// **按「写入频率」拆两半**（⭐ 不是把同一个事实存两份：归属是**每次手势**一个事实，
    /// 当前锚点是**每帧**一个事实，两者不相交）：
    public struct NodeDragOwner: Equatable, Sendable {
        public let panel: PanelId
        public let drawingID: DrawingID
        public let anchorIndex: Int
        /// D134e：盾判据要用的**按下点**（本面板局部坐标）
        public let grabPoint: CGPoint
        public init(panel: PanelId, drawingID: DrawingID, anchorIndex: Int, grabPoint: CGPoint) {
            self.panel = panel; self.drawingID = drawingID
            self.anchorIndex = anchorIndex; self.grabPoint = grabPoint
        }
    }

    /// **参与 observation**：每次拖动只写 2 次（占槽 / 清槽）⇒ 建得起 SwiftUI 依赖、又不会造成
    /// 「写 → 失效 → 再更新 → 再写」的循环。D135d 的五个 `...Enabled` 谓词读的就是它。
    public private(set) var nodeDragOwner: NodeDragOwner?

    /// **`@ObservationIgnored` 是 load-bearing 的**：每帧都写，理由与 `viewportMappers`（`:57-59`）逐字相同。
    @ObservationIgnored public private(set) var nodeDragCurrent: DrawingAnchor?

    /// 占槽。**两半同时赋值**（G15 钉死「同生同死」）。
    func beginNodeDrag(_ owner: NodeDragOwner, anchor: DrawingAnchor) {
        nodeDragOwner = owner
        nodeDragCurrent = anchor
    }

    /// 每帧更新。⛔ 没占槽时 no-op —— fail-closed：「有 current 没有 owner」这个坏状态不可表达。
    func updateNodeDragCurrent(_ anchor: DrawingAnchor) {
        guard nodeDragOwner != nil else { return }
        nodeDragCurrent = anchor
    }

    /// 清槽。**两半同时清**（G15）。幂等。
    func endNodeDrag() {
        nodeDragOwner = nil
        nodeDragCurrent = nil
    }
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd "ios/Contracts" && swift test --filter DrawingNodeDragSessionTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
```
Expected: 3 passed。

- [ ] **Step 5: 跑一次全量 host 测试，确认新增存储属性没撞坏别处**

```bash
cd "ios/Contracts" && swift test 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
```
Expected: 全绿。⚠️ 若出现与本改动无关的 SIGSEGV，⛔ 不要去改那些测试 —— 先 `rm -rf .build` 重跑。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeDragSessionTests.swift
git commit -m "P1c-3 Task4：拖动态按写入频率拆两半（D135）

nodeDragOwner 参与 observation（每次拖动只写 2 次，D135d 的置灰要读它）；
nodeDragCurrent 每帧写、必须 @ObservationIgnored（否则写→失效→再更新→再写）。
两半同生同死由「只在占槽/清槽两处同时赋值」保证；没占槽时的每帧更新 no-op，
让「有 current 没有 owner」这个坏状态不可表达。"
```

---

## Task 5: `nodeDragPreconditions` —— 探针与复核共用的那一个具名函数

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift`（`editableIgnoringGeometry`（`:76`）之后）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/NodeDragPreconditionsTests.swift`

**Interfaces:**
- Consumes: `DrawingEditRouter.editableIgnoringGeometry(engine:)`（本任务把它从 `private` 改成 `internal`）
- Produces: `static func nodeDragPreconditions(engine: TrainingEngine, panel: PanelId, point: CGPoint) -> Bool`

- [ ] **Step 1: 写失败测试（N6 六档探针层 + T13 探针路径三档）**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/NodeDragPreconditionsTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D134 前置条件 / D134b / D134e / N6 / T13）
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 探针前置条件（D134e）")
struct NodeDragPreconditionsTests {

    /// ⭐ 每一档的形状固定为「先证明放行 → 制造该档成因 → 证明被拒 → 撤掉成因 → 再证明放行」
    /// ⛔ 只断言 false 会被「恒 false」的实现骗过。

    @Test("N6 六档：引擎能判的非几何拒收门，探针必须**先**答「没有」")
    func allNonGeometricGatesRejectAtProbe() throws {
        // 六档：locked / 未来顶层字段 / 未来枚举值 / 全局 id 重复(一可见一隐藏) / 不可编辑工具 / 复盘
        // 逐档构造见 Step 1b；每档都断言：
        //   ① 成因加上之前 nodeDragPreconditions == true
        //   ② 加上之后 == false
        //   ③ 撤掉之后 == true
    }

    @Test("T13 探针路径三档：盾 .pending 拒 / .rect 区内拒 / .rect 区外放行")
    func shieldThreeCases() throws {
        // ⭐ 三档缺一不可：少了「区外放行」，「恒拒」会全绿
    }
}
```

- [ ] **Step 1b: 把上面三个 `// 逐档构造` 写成真代码**

⚠️ 这一步**不是占位**，是把夹具从既有测试里**取出来复用**。先读：

```bash
grep -n "hasKnownFutureFields\|hasKnownFutureEnumValues\|loadedDrawingsLossy\|LossyDrawingArray" \
  ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/*.swift | head -20
grep -n "flow.mode = \|setFlowModeForTesting\|injectDrawingsForTesting" \
  ios/Contracts/Tests/KlineTrainerContractsTests/**/*.swift | head -20
```

六档的成因造法（⛔ 逐档都要有对照）：

| 档 | 成因怎么造 | 撤掉成因怎么做 |
|---|---|---|
| ① `locked` | `engine.setDrawingLocked(id:locked: true)` | 再设回 `false` |
| ② 未来顶层字段 | 经 `loadedDrawingsLossy` 注入一条带未知顶层 key 的 raw（照既有 D61 测试的造法） | 换成不带未来字段的同 id 线 |
| ③ 未来枚举值 | 同上，注入未知枚举值 | 同上 |
| ④ **全局 id 重复** | `injectDrawingsForTesting` 塞**两条同 id**：一条属本面板周期（可见）、一条 `period` 不同（结构性不可见）⇒ 可见域唯一而全局不唯一 | 删掉隐藏那条 |
| ⑤ 不可编辑工具 | 把线的 `toolType` 换成 `.trend`（`DrawingStyleAvailability.isEditableToolType` 为 false） | 换回 `.horizontal` |
| ⑥ 复盘 | `engine.flow.mode = .review`（用既有测试同款入口） | 换回 `.normal` |

⚠️ ④ **必须这么造** —— 「可见域唯一而全局不唯一」正是 `DrawingEditRouter.swift:64-70` 区分两种唯一性的理由；随便造两条同 id 同周期的线会**两个判据一起失败**，该档就失去判别力。

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd "ios/Contracts" && swift test --filter NodeDragPreconditionsTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -20
```
Expected: `has no member 'nodeDragPreconditions'`。

- [ ] **Step 3: 写实现**

① 把 `editableIgnoringGeometry` 的 `private` 改成 `internal`（⛔ **函数体一个字不改**，G5 钉死其归一化文本）：

```swift
    internal static func editableIgnoringGeometry(engine: TrainingEngine) -> Bool {
```

② 在它之后插入：

```swift
    /// D134e：节点拖动的**非几何前置条件**，探针与 `.began` 的复核**调同一个**。
    ///
    /// ⛔ **这是唯一一份清单** —— 上一稿把它写成散文让调用方各自照抄，于是复核只引用了一个
    /// **子集**，「第二份更弱的副本」立刻长了出来（spec 第 7 轮评审）。
    ///
    /// ⛔ **本函数不做几何命中**（`hitTestNode`）：那是几何层，只有探针问，复核**绝不重问**（D140b）。
    ///
    /// `point` 的契约（D134e）：探针传**那一次触摸的按下点**，复核传**候选记下的那个按下点**
    /// ——⇒ 同一个点。坐标空间一律是**本面板视图的局部坐标**，与 `PanelShield.rect`
    /// （`DrawingSession.swift:168` 注释「面板局部坐标」）和 `handleDrawingTap` 拿到的 `point` 同一空间。
    static func nodeDragPreconditions(engine: TrainingEngine, panel: PanelId, point: CGPoint) -> Bool {
        let session = engine.drawingSession
        // ① 选择态：画线态下点图表是落锚、恒不做命中判定（D38），节点也不存在
        guard session.drawingModeActive, session.mode == .select else { return false }
        // ② 本面板就是 selectedPanel：选中是 (selectedPanel, selectedDrawingID) 二元组（D41）。
        //    ⛔ 少了它，选中在上面板时下面板按同一屏幕位置也会拖动上面板的线。
        guard session.selectedPanel == panel else { return false }
        // ③ 盾：与 handleDrawingTap（ChartContainerView.swift:342-344）**逐字同判据**
        switch session.shield[panel == .upper ? 0 : 1] ?? .unshielded {
        case .unshielded:       break
        case .pending:          return false
        case .rect(let shield): if shield.contains(point) { return false }
        }
        // ④ 引擎所有**不需要 mapper 就能判**的拒收门 —— ⛔ 不在这里重抄一份（D134b）
        return editableIgnoringGeometry(engine: engine)
    }
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd "ios/Contracts" && swift test --filter NodeDragPreconditionsTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
```
Expected: 全绿，且每档的三个断言（放行 → 拒 → 放行）都在。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/NodeDragPreconditionsTests.swift
git commit -m "P1c-3 Task5：探针前置条件收成一个具名函数 nodeDragPreconditions（D134e）

四条非几何前置条件（选择态 / 本面板==selectedPanel / 盾 / 引擎那份门）落在
**一个**函数里，探针与 .began 复核调同一个 ⇒ 不会再长出第二份更弱的副本。
第四条直接复用 editableIgnoringGeometry（private→internal，函数体一字不改）。
⛔ 不做几何命中——那是探针独有的一步，复核绝不重问。"
```

---

## Task 6: 点击选中的门 + 「没有选中 ⇒ 没有拖动态」由构造保证

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift`（`setSelection`（`:97`）/ `setCommittedSelection`（`:114`）/ `assignSelection`（`:122`）/ `clearSelection`（`:131`））
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeDragSessionTests.swift`（追加）

**Interfaces:**
- Consumes: Task 4 的 `nodeDragOwner` / `endNodeDrag()`
- Produces: `private func tapSelectionAllowed() -> Bool`（`DrawingSession` 内部；两个入口各自调它）

- [ ] **Step 1: 写失败测试（T14 ①②④ + T14b 三档）**

追加到 `DrawingNodeDragSessionTests.swift`：

```swift
@MainActor
@Suite("P1c-3 拖动进行中点击不改选中（D135c）")
struct NodeDragSelectionGateTests {

    static func armedSession() -> DrawingSession {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.setMode(.select)
        s.setSelection(id: "A", panel: .upper)
        s.beginNodeDrag(.init(panel: .upper, drawingID: "A", anchorIndex: 0,
                              grabPoint: CGPoint(x: 10, y: 20)),
                        anchor: DrawingAnchor(period: .m15, candleIndex: 40, price: 15.5))
        return s
    }

    @Test("T14① 拖动中 setSelection ⇒ 选中**仍是 A**（正面断言，⛔ 不是「没崩」）")
    func tapSelectionIsBlockedDuringDrag() {
        let s = Self.armedSession()
        s.setSelection(id: "B", panel: .lower)
        #expect(s.selectedDrawingID == "A")
        #expect(s.selectedPanel == .upper)
        #expect(s.nodeDragOwner != nil)          // 拖动态没被顺手清掉
    }

    @Test("T14④ 抬手之后再选 B ⇒ 这时选中**才**变（①的对照，缺了它「选中整个坏掉」也全绿）")
    func tapSelectionWorksAfterDragEnds() {
        let s = Self.armedSession()
        s.endNodeDrag()
        s.setSelection(id: "B", panel: .lower)
        #expect(s.selectedDrawingID == "B")
        #expect(s.selectedPanel == .lower)
    }

    @Test("T14b 生命周期清理连带丢弃拖动态：退画线 / setMode / clearSelection 各一档")
    func lifecycleCleanupDiscardsDrag() {
        for trigger in ["deactivate", "setMode", "clearSelection"] {
            let s = Self.armedSession()
            #expect(s.nodeDragOwner != nil)      // ⭐ 正面对照：先证明它确实建立过
            switch trigger {
            case "deactivate":     s.deactivate()
            case "setMode":        s.setMode(.draw)
            default:               s.clearSelection()
            }
            #expect(s.nodeDragOwner == nil, "\(trigger) 之后拖动态没被丢弃")
            #expect(s.nodeDragCurrent == nil, "\(trigger) 之后 current 没被丢弃")
        }
    }
}
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd "ios/Contracts" && swift test --filter NodeDragSelectionGateTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -20
```
Expected: `tapSelectionIsBlockedDuringDrag` FAIL（选中被换成了 B）、`lifecycleCleanupDiscardsDrag` FAIL。

- [ ] **Step 3: 写实现**

① 新增 `private` 谓词（放在 `setSelection` 之前）：

```swift
    /// D135c：**拖动进行中，点击不改选中**。
    /// 「B 在 A 的拖动进行中被选中」结构上不可表达 ⇒「两条拖动重叠」「陈旧回调提交了别人的拖动」
    /// 这两个问题**写不出来**（spec 第 7 / 9 / 10 轮连出三条，两条 high，根源都是它）。
    /// ⛔ 两个入口**各自保留自己的守卫**调本谓词，不得合并成一个带参数的函数
    ///（与本文件 `setSelection` / `setCommittedSelection` 共用 `assignSelection` 但各自守卫的既有纪律同形）。
    private func tapSelectionAllowed() -> Bool { nodeDragOwner == nil }
```

② `setSelection` 与 `setCommittedSelection` 各加一行守卫：

```swift
    func setSelection(id: DrawingID, panel: PanelId) {
        guard tapSelectionAllowed() else { return }                 // D135c
        guard drawingModeActive, mode == .select, !id.isEmpty else { return }
        assignSelection(id: id, panel: panel)
    }
    // …
    func setCommittedSelection(id: DrawingID, panel: PanelId) {
        guard tapSelectionAllowed() else { return }                 // D135c（画线态不可能有拖动态，对称保留）
        guard drawingModeActive, mode == .draw, !id.isEmpty else { return }
        assignSelection(id: id, panel: panel)
    }
```

③ `assignSelection` 与 `clearSelection` 各加一行丢弃：

```swift
    private func assignSelection(id: DrawingID, panel: PanelId) {
        endNodeDrag()                              // D135c：「没有/换了选中 ⇒ 不可能有节点拖动」
        selectedDrawingID = id
        selectedPanel = panel
        selectionGeometryVisible = true
    }

    func clearSelection() {
        endNodeDrag()                              // D135c：同上，语义恒等式
        selectedDrawingID = nil
        selectedPanel = nil
        selectionGeometryVisible = false
    }
```

⚠️ **为什么是「丢弃」不是「就地定住」**：`DrawingSession` 是纯状态容器、**写不了引擎** ⇒ 它只能丢弃。而这两条路径本就该丢（周期变了是坏数据；退画线是用户主动放弃）。「就地定住」只发生在手势回调里（Task 11）。

- [ ] **Step 4: 跑测试确认通过 + 复跑既有选中测试**

```bash
cd "ios/Contracts" && swift test --filter NodeDragSelectionGateTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
cd "ios/Contracts" && swift test --filter DrawingSession 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
cd "ios/Contracts" && swift test --filter DrawingEditRouter 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
```
⚠️ **既有选中测试必须全绿** —— 本任务动了 `assignSelection` / `clearSelection` 这两个被广泛复用的收口点。若有既有测试变红，⛔ 不许改那些测试，先确认是不是 `endNodeDrag()` 放错了位置。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeDragSessionTests.swift
git commit -m "P1c-3 Task6：拖动中点击不改选中 + 没有选中就没有拖动态（D135c）

塌层（user 2026-09-29 拍板）：在选中变更的收口处加门，让「B 在 A 的拖动中
被选中」结构上不可表达 ⇒ 跨面板重叠与陈旧回调提交别人的拖动都写不出来。
判据抽成一个 private 谓词，两个入口各自保留守卫调它（与本文件既有纪律同形）。
assignSelection / clearSelection 各一处连带丢弃，让语义恒等式由构造保证。"
```

---

## Task 7: `DrawingEditRouter` 的拖动门（十处，集合等式）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/NodeDragEditRouterGateTests.swift`

**Interfaces:**
- Consumes: Task 4 的 `engine.drawingSession.nodeDragOwner`
- Produces: `private static func nodeDragInFlight(engine: TrainingEngine) -> Bool`；W1–W5 / E1–E5 十处各调一次

- [ ] **Step 1: 写失败测试（T15 十档 + T15b 端到端）**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/NodeDragEditRouterGateTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D135d / T15 / T15b）
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 拖动期间底栏/面板写入全族被拒（D135d）")
struct NodeDragEditRouterGateTests {

    /// ⭐ 每一档三段式：拖动前放行 → 拖动中被拒 → 拖动后恢复
    /// ⭐ 谓词那五档的**拖动前必须为 true** —— `deleteButtonEnabled` 在「无选中」时本来就是 false，
    ///    样本没有可用的选中时该档恒真而无意义（spec T15 自检点名）。

    @Test("T15 E1–E5：五个置灰谓词在拖动中一律 false，拖动前后都 true")
    func enabledPredicatesGoFalseDuringDrag() throws {
        let (e, line) = /* 见 Step 1b：一条可编辑、已选中、几何可见的线 */
        for (name, probe) in [
            ("styleControlsEnabled", DrawingEditRouter.styleControlsEnabled),
            ("deleteButtonEnabled",  DrawingEditRouter.deleteButtonEnabled),
            ("lockButtonEnabled",    DrawingEditRouter.lockButtonEnabled),
            ("undoButtonEnabled",    DrawingEditRouter.undoButtonEnabled),
            ("redoButtonEnabled",    DrawingEditRouter.redoButtonEnabled),
        ] as [(String, (TrainingEngine) -> Bool)] {
            #expect(probe(e), "\(name) 拖动前就是 false ⇒ 这一档恒真而无意义，样本要改")
            e.drawingSession.beginNodeDrag(/* owner for line */, anchor: line.anchors[0])
            #expect(!probe(e), "\(name) 拖动中没被门挡住")
            e.drawingSession.endNodeDrag()
            #expect(probe(e), "\(name) 拖动后没恢复")
        }
    }

    @Test("T15 W1–W5：五个写入入口在拖动中一律 no-op（drawings 与 revision 零改动）")
    func writeEntriesAreNoOpDuringDrag() throws {
        // 逐个：applyStyle(经 applyPanelStyleMutation) / deleteSelected / toggleLockSelected / undo / redo
        // 每档断言：拖动前调用**确实**产生了副作用（revision 变了或状态变了）→ 复位 →
        //          拖动中调用 revision **一点没变** → 拖动后再调又**确实**生效
    }

    @Test("T15b 端到端：拖动已偏移 → 点 🔒 → 继续移动 → 松手 ⇒ 锁没生效、正常写入、调整没丢")
    func lockDuringDragDoesNotLoseTheAdjustment() throws {
        // ① 断言 line.locked **仍是 false**（⛔ 不是「toggleLock 返回了 false」——返回值与状态是两件事）
        // ② 断言 drawingsRevision **+1**
        // ③ 断言 drawings 里那条的锚点 == **松手那一刻**的值（⛔ 不是「线还在」）
    }
}
```

- [ ] **Step 1b: 把三处 `/* … */` 写成真代码**

⚠️ 这一步**不是占位**。夹具要求：一条 `.horizontal`、`locked == false`、不带未来数据、全局唯一、**已选中且几何可见**的线，且 `flow.mode != .review`、撤销栈里**有**一条记录（否则 `undoButtonEnabled` 拖动前就是 false，那一档恒真）。

```bash
# 先看既有测试怎么把一条线做到「选中且几何可见」
grep -n "setViewportMapper\|setSelection\|selectionGeometryVisible" \
  ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditRouterTests.swift | head -20
```
**复用** `DrawingEditRouterTests.swift` 里已有的夹具，⛔ 不新造一套。

⚠️ `undoButtonEnabled` 的前置：先做一次真编辑（如 `toggleLockSelected` 往返，或 `applyStyle` 改个颜色）把撤销栈填上，再解锁复位。

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd "ios/Contracts" && swift test --filter NodeDragEditRouterGateTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -25
```
Expected: 十档全 FAIL（门还没加）。

- [ ] **Step 3: 写实现**

① 新增 `private` 谓词：

```swift
    /// D135d：拖动进行中，选中对象的**所有**写入面一律拒，且控件**真的变灰**。
    ///
    /// ⛔ 读的是 **`nodeDragOwner`**（参与 observation 的那一半），⛔ 不得读 `nodeDragCurrent`
    /// —— 读错了 host 测**照样全绿**（两半的值一致），而真机上 SwiftUI 建不起依赖、控件不变灰。
    ///
    /// **⭐ 置灰必须是真的变灰**，不是「亮着、点了没反应」—— 后者在本仓是具名缺陷（1b-i PR-2 交接②）。
    private static func nodeDragInFlight(engine: TrainingEngine) -> Bool {
        engine.drawingSession.nodeDragOwner != nil
    }
```

② 十处各加一行。**写入面**（W1–W5）在函数体**第一行**：

```swift
    static func applyStyle(_ style: DrawingDefaultStyle, engine: TrainingEngine) -> Bool {
        guard !nodeDragInFlight(engine: engine) else { return false }   // D135d
        defer { syncSelectionByState(engine: engine) }
        // …既有逻辑一字不改…
    }
```
`deleteSelected` / `toggleLockSelected` / `undo` / `redo` 同款各加一行。
⚠️ `applyPanelStyleMutation`（`:253`）**不单独加门** —— 它经 `applyStyle` 进来，W1 那道门已经覆盖；但它还会写 `session.setDefaultStyle`（改「本局默认」），**那一半不属于选中对象的写入面** ⇒ ⛔ 不挡。**这一条要在 plan 执行时实测确认**：拖动中改样式，默认值该变、线不该变。

**置灰谓词**（E1–E5）在 `return` 处合取：

```swift
    static func deleteButtonEnabled(engine: TrainingEngine) -> Bool {
        !nodeDragInFlight(engine: engine)                              // D135d
            && deletableIgnoringGeometry(engine: engine)
            && engine.drawingSession.selectionGeometryVisible
    }
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd "ios/Contracts" && swift test --filter NodeDragEditRouterGateTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
cd "ios/Contracts" && swift test --filter DrawingEditRouterTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
```
⚠️ 既有 `DrawingEditRouterTests` 必须全绿（它们都在「没有拖动」的状态下跑，新门恒不触发）。

- [ ] **Step 5: 实测确认 `applyPanelStyleMutation` 的分叉行为**

```bash
# 在 NodeDragEditRouterGateTests 里加一条：拖动中经 applyPanelStyleMutation 改颜色
#   ⇒ session.defaultStyle **变了**；drawings 里那条线 **没变**、drawingsRevision **没变**
cd "ios/Contracts" && swift test --filter NodeDragEditRouterGateTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
```
把实测结果写进提交信息。⚠️ 若实测发现「本局默认也该挡」，**回到 spec D135d 那张表重新定性**，⛔ 不要在代码里悄悄多挡一处。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/NodeDragEditRouterGateTests.swift
git commit -m "P1c-3 Task7：拖动期间底栏/面板写入全族加门 + 控件真变灰（D135d）

按 Sources/ 的字面清单加门：写入 W1-W5 + 置灰谓词 E1-E5 共十处，各调同一个
private 谓词；明确不加门的 7 处在 spec 里已逐条定性。谓词读 nodeDragOwner
（observation 那一半）——读错了 host 照样全绿而真机不变灰。
T15 每一档三段式（拖动前放行→拖动中被拒→拖动后恢复），⛔ 少了对照「恒 false」
会十档全绿。"
```

---

# 阶段 B：手势接线 + 渲染（含 UIKit）

> ⚠️ **进入阶段 B 前先确认阶段 A 全绿**：`cd ios/Contracts && swift test 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -5`
>
> ⚠️ **交付边界**：若到此处体量已明显失控，按「Global Constraints · 交付边界」**停下来问 user** 要不要拆成两个顺序 PR。⛔ 不得自行决定。

## Task 8: 单指路由的纯函数 + 仲裁器接线

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift`（文件末尾，⛔ `singlePanStep` 一个字不改）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/SinglePanRouteTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum SinglePanRoute: Equatable, Sendable { case chart, nodeDrag }
  /// D134：只在 `.began` 询问候选；其余相位按 latch 转发。终止相位复位为 .chart
  func singlePanRouteStep(phase: GesturePhase, candidateAccepted: Bool,
                          current: SinglePanRoute) -> SinglePanRoute
  // ChartGestureArbiter 新增：
  public var onHasNodeDragCandidate: (() -> Bool)?          // `.began` 问一次（含 fail-closed 复核）
  public var onNodeDrag: ((CGPoint, GesturePhase) -> Void)? // (translation, phase)
  ```

- [ ] **Step 1: 写失败测试（N1 + T8 + T9①②③）**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/SinglePanRouteTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D134 / D138 末段 / N1 / T8）
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

@Suite("P1c-3 单指路由（D134）")
struct SinglePanRouteTests {

    @Test("N1 没有候选 ⇒ 路由恒为 .chart（⇒ 平移/切周期/缩放一字不变）")
    func noCandidateKeepsChartRoute() {
        var r = SinglePanRoute.chart
        r = singlePanRouteStep(phase: .began, candidateAccepted: false, current: r)
        #expect(r == .chart)
        r = singlePanRouteStep(phase: .changed, candidateAccepted: false, current: r)
        #expect(r == .chart)
    }

    @Test("N1 的反向对照：有候选 ⇒ 路由确实变成 .nodeDrag（⛔ 缺了它「分叉没接上」也全绿）")
    func candidateSwitchesRoute() {
        var r = SinglePanRoute.chart
        r = singlePanRouteStep(phase: .began, candidateAccepted: true, current: r)
        #expect(r == .nodeDrag)
    }

    @Test("T9①② latch：`.began` 之后不再重新询问 —— 中途 candidateAccepted 翻转也不改路由")
    func routeIsLatchedAfterBegan() {
        var r = singlePanRouteStep(phase: .began, candidateAccepted: true, current: .chart)
        // ⭐ 喂一个「此刻已经没有候选」的 .changed —— 路由必须仍是 .nodeDrag
        r = singlePanRouteStep(phase: .changed, candidateAccepted: false, current: r)
        #expect(r == .nodeDrag)
        // 反向：没进拖动的手势，中途「突然有候选」也不得转过去
        var c = singlePanRouteStep(phase: .began, candidateAccepted: false, current: .chart)
        c = singlePanRouteStep(phase: .changed, candidateAccepted: true, current: c)
        #expect(c == .chart)
    }

    @Test("T8 终止相位复位为 .chart（下一次手势从干净状态起手）")
    func terminalPhaseResets() {
        for ph in [GesturePhase.ended, .cancelled] {
            let r = singlePanRouteStep(phase: ph, candidateAccepted: false, current: .nodeDrag)
            #expect(r == .chart, "\(ph) 之后路由没复位")
        }
    }
}
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd "ios/Contracts" && swift test --filter SinglePanRouteTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -20
```
Expected: `cannot find 'singlePanRouteStep' in scope`。

- [ ] **Step 3: 写纯函数**

追加到 `GestureClassifiers.swift` **末尾**（⛔ 不改 `singlePanStep`，`DrawingGestureSourceGuardTests` 钉死它）：

```swift
// MARK: - 单指路由（P1c 第 3 片 D134）：节点拖动 vs 图表手势

/// 本次单指手势整体走哪条路。**`.began` 决定，其余相位只转发**（D134）。
enum SinglePanRoute: Equatable, Sendable { case chart, nodeDrag }

/// D134：路由 latch 的纯决策。
///
/// **为什么必须在 `.began` 分叉**：`singlePanStep` 一旦把手势判成竖直就 latch 成 `.verticalRejected`
/// （`:72`），后续即便累积满足水平分类也不再发平移，抬手按 `verticalSwitchThreshold` 发切周期。
/// 而拖节点主要就是上下拖 ⇒ **等方向分类器判完，节点已经拖不动了**。
///
/// ⛔ **`.changed` 不重新询问**：候选可能在拖动中失效（选中被清 / 周期变），但那要的是
/// 「作废并忽略后续回调」（D138），**不是**回落成图表平移 —— 后者会让「周期刚切完、手指还没抬」
/// 变成一次用户没要的平移（D138 末段）。
func singlePanRouteStep(phase: GesturePhase, candidateAccepted: Bool,
                        current: SinglePanRoute) -> SinglePanRoute {
    switch phase {
    case .began:              return candidateAccepted ? .nodeDrag : .chart
    case .changed:            return current
    case .ended, .cancelled:  return .chart
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd "ios/Contracts" && swift test --filter SinglePanRouteTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
```
Expected: 4 passed。

- [ ] **Step 5: 接进仲裁器**

`ChartGestureArbiter.swift`：① 在 `onVerticalSwipe`（`:35`）附近加两个回调声明：

```swift
    /// P1c 第 3 片（D134）：`.began` 时问一句「此刻有没有一个已通过复核的可拖节点候选」。
    /// ⛔ 本闭包**不认识**「画线模式」这个概念 —— 没有会话 / 没有选中时它必然回答 false，
    ///    故既有守卫「`handleSinglePan` 体内不得出现 `drawingMode`」继续绿且**仍有判别力**。
    public var onHasNodeDragCandidate: (() -> Bool)?
    /// P1c 第 3 片：节点拖动的位移转发。(translation, phase)
    /// ⛔ 传的是 **`translation`** 不是 `location` —— 位移换算全程不碰屏幕投影（D134c / D134d）。
    public var onNodeDrag: ((CGPoint, GesturePhase) -> Void)?
```

② 加 per-gesture 状态（与 `singlePanLifecycle` 并排）：

```swift
    // 单指路由 latch（P1c 第 3 片 D134）。`.began` 决定，终止相位复位。
    private var singlePanRouteState: SinglePanRoute = .chart
```
并在 `resetGestureState()` 里加 `singlePanRouteState = .chart`。

③ `handleSinglePan` 在 crosshair 早退**之后**、`singlePanStep` **之前**插入分叉：

```swift
        // P1c 第 3 片（D134）：节点拖动分支。⛔ 必须在 singlePanStep **之前** ——
        // 方向分类器一旦 latch 成 .verticalRejected，上下拖就再也回不来了。
        singlePanRouteState = singlePanRouteStep(
            phase: ph,
            candidateAccepted: ph == .began ? (onHasNodeDragCandidate?() ?? false) : false,
            current: singlePanRouteState)
        if singlePanRouteState == .nodeDrag {
            onNodeDrag?(g.translation(in: g.view), ph)
            if ph == .ended || ph == .cancelled { singlePanRouteState = .chart }
            return                                   // ⛔ 整个手势不进 singlePanStep
        }
```

④ `supersedeSinglePanForMultitouch`（`:123`）开头加拖动分支（D138「第二根手指 ⇒ 就地定住」）：

```swift
        // D138：拖节点时第二根手指落下 ⇒ **就地定住**，走与抬手**同一条**收尾路径。
        // ⛔ 不走 singlePanSupersede —— 那是图表平移的收尾，会给 onPan 发 .cancelled。
        if singlePanRouteState == .nodeDrag {
            let t = singlePanRecognizer?.translation(in: view) ?? .zero
            onNodeDrag?(t, .ended)                   // .ended 而非 .cancelled：定住不是作废
            singlePanRouteState = .chart
            if let s = singlePanRecognizer, s.isEnabled { s.isEnabled = false; s.isEnabled = true }
            return
        }
```

- [ ] **Step 6: 编译 + 复跑既有手势守卫（G1）**

```bash
cd "ios/Contracts" && swift build 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -10
cd "ios/Contracts" && swift test --filter DrawingGestureSourceGuardTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
```
⚠️ **G1 必须仍绿**：`handleSinglePan` 体内不得出现 `drawingMode`（我们用的是 `onHasNodeDragCandidate`）、`GestureClassifiers` 里不得出现 `drawingTakesOver` / `DrawingModePanPolicy` / `panPolicyInDrawingMode`。⛔ 若它红了，**不许改守卫**，改实现。

- [ ] **Step 7: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift \
        ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/SinglePanRouteTests.swift
git commit -m "P1c-3 Task8：单指路由纯函数 + 仲裁器分叉（D134 / D138）

分叉在 .began、在 singlePanStep **之前**（方向分类器一旦 latch 成竖直，
上下拖就再也回不来）。.changed 不重新询问——候选中途失效要的是「作废并忽略」
而不是回落成平移（D138 末段）。两指接管走 onNodeDrag(.ended) 就地定住，
⛔ 不走 singlePanSupersede（那是图表平移的收尾）。
G1 两条既有守卫实跑确认仍绿：探针闭包不认识「画线模式」这个概念。"
```

---

> ## ❗❗❗ Task 8 订正（2026-09-30，实施后评审发现 —— **本节上面的代码有一个 Critical，⛔ 不得再当依据**）
>
> **缺陷**：上面给出的仲裁器片段把赋值写在判断之前 ——
> `singlePanRouteState = singlePanRouteStep(...)` 先执行，`if singlePanRouteState == .nodeDrag` 后执行。
> 而原 `singlePanRouteStep` 对 `.ended` / `.cancelled` **无条件**返回 `.chart` ⇒ 到终止相位时
> 「刚才是不是在拖节点」这个信息**已被前一行抹掉** ⇒ 那个 `if` **恒假** ⇒
> **单指自然抬手时 `onNodeDrag` 永远收不到 `.ended`（`.cancelled` 同理）**
> ⇒ **拖动的收尾信号被静默吞掉、线永远提交不了**（本片主交付物失效），且执行跌进 `singlePanStep`。
> 片段里那句 `if ph == .ended || ph == .cancelled { singlePanRouteState = .chart }` 是**死代码**，
> 恰是「本意想在此判断」的内部证据。
>
> **为什么四道检查都没抓到**：单测只喂纯函数（纯函数单独看是对的）＋ 仲裁器整类在
> `#if canImport(UIKit)` 内、host 测试**根本不执行它** ＋ Catalyst 只做**类型检查**
> （提前跑的那次 `** TEST BUILD SUCCEEDED **` **不能**证明它是对的）。
>
> **订正后的定稿形状**（判断整个搬进纯函数，仲裁器退化成零判断的傻转发）：
>
> ```swift
> // GestureClassifiers.swift —— 返回「要做什么 + 新状态」，照该文件既有 SinglePanStep 的范式
> struct SinglePanRouteStep: Equatable, Sendable {
>     let forwardToNodeDrag: Bool
>     let route: SinglePanRoute
> }
>
> func singlePanRouteStep(phase: GesturePhase, candidateAccepted: Bool,
>                         current: SinglePanRoute) -> SinglePanRouteStep {
>     switch phase {
>     case .began:
>         return candidateAccepted
>             ? SinglePanRouteStep(forwardToNodeDrag: true,  route: .nodeDrag)
>             : SinglePanRouteStep(forwardToNodeDrag: false, route: .chart)
>     case .changed:
>         return SinglePanRouteStep(forwardToNodeDrag: current == .nodeDrag, route: current)
>     case .ended, .cancelled:
>         // 终止相位**必须**按 current 决定是否转发（否则收尾信号被吞），再无条件复位
>         return SinglePanRouteStep(forwardToNodeDrag: current == .nodeDrag, route: .chart)
>     }
> }
> ```
>
> ```swift
> // ChartGestureArbiter.handleSinglePan —— ⛔ 这里不许再有任何判断
> let routeStep = singlePanRouteStep(
>     phase: ph,
>     candidateAccepted: ph == .began ? (onHasNodeDragCandidate?() ?? false) : false,
>     current: singlePanRouteState)
> singlePanRouteState = routeStep.route
> if routeStep.forwardToNodeDrag {
>     onNodeDrag?(g.translation(in: g.view), ph)
>     return
> }
> ```
>
> **为什么不采用「在仲裁器里记一个覆盖前的值」那种修法**：那会留下「两值舞蹈」——
> 同一文件里两指分支读覆盖前、单指分支读覆盖后，正是这个 bug 的来源，修一处不等于修一族；
> 且仲裁器在 host 上**不可测**，判别力留在那儿等于放在测不到的地方，而纯函数层可测。
>
> **⛔ 本节以下行号的内容已全部失效，读它们会得到错的结论**：
> - 接口声明（`singlePanRouteStep` 返回 `SinglePanRoute`）—— 约 `:1364-1367`、`:1449-1456`
> - Step 2 的四档测试（断言返回值是 `SinglePanRoute`）—— 约 `:1376-1420`
> - Step 5③ 的仲裁器片段（**Critical 本体**）—— 约 `:1493-1500`
>
> **实际落地**：`86e559de`。`SinglePanRouteTests` 7 档（原 4 档改写 + 2 条 Critical 回归 + 1 条反向对照），
> 变异反证「终止分支硬编码 `forward = false`」时**恰好且只有**那两条回归转红；全量 1907/1907 绿。
>
> **⭐ 教训（已写入记忆）**：纯函数单独正确，**不代表**调用它的那一层用对了。
> 当判别力所在的那一层在本机不可执行时，把判断**搬进可执行的那一层**，让不可执行的那层零判断。
>

## Task 9: `KLineView` 触摸钩子 + 候选捕获

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift`（`onBoundsChange`（`:31`）附近）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/NodeDragCandidateTests.swift`

**Interfaces:**
- Consumes: Task 5 的 `nodeDragPreconditions(engine:panel:point:)`、`DrawingNodeGeometry.hitTestNode`
- Produces:
  - `KLineView.onTouchDown: ((CGPoint) -> Void)?`（单点触摸时触发；多点触摸时触发 `onMultiTouchBegan`）
  - `Coordinator` 内部：`private var nodeDragCandidate: DrawingSession.NodeDragOwner?`
  - `Coordinator.captureNodeDragCandidateForTesting(at:) `（internal 测试入口，照 `handleDrawingTapForTesting`（`:323`）的先例）

- [ ] **Step 1: 先读 `KLineView.swift`，确认它有没有既有的 touches 覆写**

```bash
sed -n '1,60p' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift
grep -n "override func touches" ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift
```
⚠️ 若已有 `touchesBegan` 覆写，**在既有实现里加钩子**，⛔ 不要新写一个覆盖掉它。

- [ ] **Step 2: 写失败测试（T11 ④ 六档 + T12 规则层 ④⑤ + G7 的行为面）**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Render/NodeDragCandidateTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D140b / D140c / T11 / T12）
#if canImport(UIKit)
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 候选捕获与生命周期（D140b / D140c）")
struct NodeDragCandidateTests {

    @Test("T12④ 触摸被取消之后候选**仍在**（⛔「取消」不等于「手指抬起」）")
    func candidateSurvivesTouchesCancelled() throws {
        // 造 Coordinator + 一条选中的线 → 在节点上捕获候选 → 喂 touchesCancelled → 候选仍非 nil
    }

    @Test("T12⑤ 陈旧候选不泄漏：节点上按下后抬手不拖，再到远处按下 ⇒ 候选被**覆盖**")
    func newTouchDownOverwritesStaleCandidate() throws {
        // ⭐ 这一档证明「不留陈旧候选」靠的是**覆盖**，不是「记得清」
    }

    @Test("G7 行为面：两点触摸 ⇒ 不产生候选（⛔ 只做源码守卫不够，判据写成 >= 1 源码上照样出现）")
    func multiTouchProducesNoCandidate() throws { }

    @Test("T11④ 候选中途失效的**六个**成因，各自 fail-closed 不进拖动")
    func candidateRevalidationRejectsSixCauses() throws {
        // 线被删 / 选中被清 / 被锁 / 进复盘 / 选中换成**同面板**另一条可编辑线 / 换成**另一面板**的可编辑线
        // ⭐ 后两档必须**断言新选中的那条确实可编辑** —— 否则谓词本身为假，档位退化成「选中被清」的复制品
    }
}
#endif
```

⚠️ **T11①②③（惯性 / overscroll）在 host 上构造成本很高** —— 它们要真实的 `settleDeceleration` 与减速动画。
**本步的处置**：先尝试用 `TrainingEngineInteractionTests` 里既有的 `FakeFrameDriver` 夹具驱动减速（`grep -n "FakeFrameDriver" ios/Contracts/Tests/**/*.swift`）。
- **做得到** → 三档落 host；
- **做不到** → ⛔ **不得静默降级**：把三档逐条写进真机验收清单，并在 spec §10 新开一条具名残留（照 Q28 的格式），**逐条列出**未被自动化覆盖的断言。

- [ ] **Step 3: 写 `KLineView` 钩子**

```swift
    /// P1c 第 3 片（D140b）：**手指真正按下**那一刻的只读钩子，与 `onBoundsChange`（`:31`）同款范式。
    /// ⛔⛔ 消费者**零 engine 写入**：不 settleDeceleration、不 rebuildRenderState、不改任何状态。
    ///    理由：今天惯性要到 pan `.began` 才被 `beginPan` 截住；在这里刹车会让**每一次触摸**
    ///    （含纯平移、纯点击）都提前截停惯性 —— 那是对 D32 既有行为的改动，直接违反 N1。
    public var onTouchDown: ((CGPoint) -> Void)?
    /// P1c 第 3 片（D140c）：按下时已有 ≥2 个触摸 —— 消费者据此清候选（fail-closed）。
    public var onMultiTouchBegan: (() -> Void)?

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        // G7：**只在单点触摸时**发按下钩子。判据用 event 的全量触摸数，⛔ 不是 touches.count
        //（touches 只含**本次新增**的那些，第二指落下时它也是 1）。
        let total = event?.allTouches?.count ?? touches.count
        if total == 1, let t = touches.first {
            onTouchDown?(t.location(in: self))       // 本面板局部坐标（D134e 的坐标空间契约）
        } else {
            onMultiTouchBegan?()
        }
    }
```

⚠️ ⛔ **不覆写 `touchesEnded` / `touchesCancelled`** —— D140c：候选的清除时机只有三个，都不含它们。

- [ ] **Step 4: 写 Coordinator 的候选捕获**

在 `ChartContainerView.Coordinator` 的 `attach(to:)` 里加：

```swift
            self.view?.onTouchDown = { [weak self] point in
                self?.captureNodeDragCandidate(at: point)
            }
            self.view?.onMultiTouchBegan = { [weak self] in
                self?.nodeDragCandidate = nil            // D140c fail-closed
            }
            arbiter.onHasNodeDragCandidate = { [weak self] in
                self?.acceptNodeDragCandidate() ?? false
            }
```

并新增（⛔ **纯只读**，G3 的 ① 分支钉死）：

```swift
        /// D140b：**手指按下那一刻**捕获候选。⛔⛔ 本函数零 engine 写入 —— 用的是
        /// `view.renderState.viewport`（= 屏幕上**正在显示**的那一帧，就是用户看着按下去的那一帧）。
        /// ⚠️ 它是**上一帧**的结果，惯性快速滑动时与手指落下那一瞬最多差**一帧**；这是 UIKit
        ///    触摸模型下的下界，⛔ 不得声称「精确」。它替代的是「一个 deadzone + 一次 overscroll
        ///    夹取」的误差，数量级小一到两个档（spec D140b 末段，如实登记）。
        private func captureNodeDragCandidate(at point: CGPoint) {
            nodeDragCandidate = nil                       // 新按下**直接覆盖**旧候选（D140c）
            guard let engine, let view else { return }
            let vp = view.renderState.viewport
            guard vp.geometry.candleStep > 0 else { return }
            guard DrawingEditRouter.nodeDragPreconditions(engine: engine, panel: panel, point: point)
            else { return }
            guard let id = engine.drawingSession.selectedDrawingID,
                  let drawing = RenderStateBuilder.visibleDrawings(
                      engine: engine, panel: panel, tick: engine.tick.globalTickIndex)
                      .last(where: { $0.id == id }),
                  let tool = KLineView.drawingTools[drawing.toolType] else { return }
            let mapper = CoordinateMapper(viewport: vp, displayScale: view.traitCollection.displayScale)
            guard let idx = DrawingNodeGeometry.hitTestNode(
                point: point, drawing: drawing, mapper: mapper,
                isVisible: tool.isVisible(drawing: drawing, mapper: mapper),
                maxAnchors: tool.requiredAnchors.upperBound) else { return }
            nodeDragCandidate = .init(panel: panel, drawingID: id, anchorIndex: idx, grabPoint: point)
        }

        /// pan `.began` 的 **fail-closed 复核**（D134e）。⛔ **不重做任何几何命中**（D140b）。
        private func acceptNodeDragCandidate() -> Bool {
            guard let engine, let c = nodeDragCandidate else { return false }
            guard DrawingEditRouter.nodeDragPreconditions(
                    engine: engine, panel: panel, point: c.grabPoint) else { return false }
            guard engine.drawingSession.selectedDrawingID == c.drawingID else { return false }
            return true
        }

        /// 测试入口（照 `handleDrawingTapForTesting`（`:323`）的先例）
        func captureNodeDragCandidateForTesting(at point: CGPoint) { captureNodeDragCandidate(at: point) }
        func acceptNodeDragCandidateForTesting() -> Bool { acceptNodeDragCandidate() }
        var nodeDragCandidateForTesting: DrawingSession.NodeDragOwner? { nodeDragCandidate }
```

- [ ] **Step 5: 跑测试**

```bash
cd "ios/Contracts" && swift test --filter NodeDragCandidateTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -20
```
⚠️ 该套件在 `#if canImport(UIKit)` 内 ⇒ **host 上整份跳过**。本步真正的验证在 Catalyst（Task 13）。**host 这一跑只为确认它不破坏编译**。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/NodeDragCandidateTests.swift
git commit -m "P1c-3 Task9：按下那一刻捕获候选 + .began 只复核不重查（D140b / D140c）

钩子在 touchesBegan、**零 engine 写入**（在这里刹车会改变每一次触摸的既有
行为、违反 N1）。用 view.renderState.viewport（用户看着按下去的那一帧）——
如实登记它是上一帧、最多差一帧，⛔ 不声称精确。
⛔ 不覆写 touchesEnded/Cancelled：清除时机只有三个，都不含它们；不留陈旧
候选靠「新按下直接覆盖」。G7 的触摸数判据用 event.allTouches，⛔ 不是
touches.count（后者在第二指落下时也是 1）。"
```

---

## Task 10: 渲染覆盖 + 每帧身份判据

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift:84`（`visibleDrawings`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/NodeDragCandidateTests.swift`（追加，host 段）

**Interfaces:**
- Consumes: `session.nodeDragOwner` / `session.nodeDragCurrent`
- Produces: `visibleDrawings` 在不变量成立时**返回替换了锚点的副本**

- [ ] **Step 1: 写失败测试（T3 实时跟随 + T6 拖动中零写盘 + 不变量不成立时不覆盖）**

```swift
@MainActor
@Suite("P1c-3 渲染覆盖（D135 / D135b）")
struct NodeDragRenderOverrideTests {

    @Test("T3 实时跟随：visibleDrawings 里那条线的锚点 == 当前拖动锚点")
    func overrideAppliesToVisibleDrawings() throws {
        // ⭐ 必须先断言**帧与帧之间几何确实变了**（差值非 0），否则「两边取同一个常数」恒真
    }

    @Test("T6 拖动中一次盘都不写：drawingsRevision 全程不变")
    func noPersistDuringDrag() throws {
        // ⭐ 正向对照：收尾之后它 +1
    }

    @Test("D135b 不变量不成立（归属 ≠ 当前选中）⇒ **不施加覆盖**，且⛔ 不写任何状态")
    func overrideIsSkippedWhenOwnershipBroken() throws {
        // 造：nodeDragOwner.drawingID == "A"，而 session 选中已是 "B"
        // 断言：visibleDrawings 返回的是 engine.drawings 里的原值；
        //       且调用前后 nodeDragOwner / nodeDragCurrent / drawingsRevision **一个都没变**
        //       ⭐ 最后这条是 G10 的行为面：渲染读路径零写入
    }
}
```

- [ ] **Step 2: 跑测试确认它失败**

- [ ] **Step 3: 写实现**

`RenderStateBuilder.visibleDrawings` 改为：

```swift
    @MainActor
    static func visibleDrawings(engine: TrainingEngine, panel: PanelId, tick: Int) -> [DrawingObject] {
        let base = (engine.drawings + (engine.flow.mode == .review ? engine.reviewDrawings : []))
            .filter { drawing in
                belongsToPanel(drawing, panel: panel,
                               upperPeriod: engine.upperPanel.period, lowerPeriod: engine.lowerPanel.period)
                    && drawing.revealTick <= tick
            }
        return applyNodeDragOverride(base, engine: engine, panel: panel)
    }

    /// D135 第 2 条：把**正在被拖**的那一条替换成拖动中的样子。落在这一处（而不是只落渲染路径），
    /// 是为了让 D40「命中集合 ≡ 渲染集合」在拖动的**每一个瞬间**都字面成立。
    ///
    /// ⛔⛔ **本函数零写入**（D135b 末段 / G10）：不变量不成立时**只是不施加覆盖**（fail-closed 读）。
    /// 「就地定住」是**写入**，只允许发生在手势回调里 —— 在渲染求值里写状态会造成
    /// 「写 → 失效 → 再渲染」的循环（同 `DrawingSession.swift:57-59` 记录的那条陷阱）。
    @MainActor
    private static func applyNodeDragOverride(_ list: [DrawingObject], engine: TrainingEngine,
                                              panel: PanelId) -> [DrawingObject] {
        let session = engine.drawingSession
        guard let owner = session.nodeDragOwner, let current = session.nodeDragCurrent,
              owner.panel == panel,
              owner.panel == session.selectedPanel,
              owner.drawingID == session.selectedDrawingID           // D135b 不变量
        else { return list }
        return list.map { d in
            guard d.id == owner.drawingID, d.anchors.indices.contains(owner.anchorIndex) else { return d }
            var anchors = d.anchors
            anchors[owner.anchorIndex] = current
            return DrawingObject(
                id: d.id, toolType: d.toolType, anchors: anchors,
                isExtended: d.isExtended, panelPosition: d.panelPosition,
                revealTick: d.revealTick, period: d.period,
                lineSubType: d.lineSubType, lineStyle: d.lineStyle,
                thickness: d.thickness, colorToken: d.colorToken,
                labelMode: d.labelMode, locked: d.locked,
                text: d.text, fontSize: d.fontSize,
                textColorToken: d.textColorToken, textForm: d.textForm,
                tailAnchor: d.tailAnchor)
        }
    }
```

- [ ] **Step 4: 跑测试 + 复跑所有消费 `visibleDrawings` 的既有测试**

```bash
cd "ios/Contracts" && swift test --filter NodeDragRenderOverrideTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
cd "ios/Contracts" && swift test 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -10
```
⚠️ `visibleDrawings` 是渲染 / 命中 / 几何门**共用**的唯一真相 ⇒ 全量跑，⛔ 不能只跑新套件。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/NodeDragCandidateTests.swift
git commit -m "P1c-3 Task10：渲染/命中唯一真相里替换被拖那条的副本（D135 / D135b）

落在 visibleDrawings 而不是只落渲染路径 ⇒ D40「命中集合 ≡ 渲染集合」在拖动的
每一个瞬间都字面成立。⛔ 本函数零写入：不变量不成立时只是不施加覆盖
（就地定住是写入、只许在手势回调里；渲染求值里写状态会造成写→失效→再渲染）。"
```

---

## Task 11: 拖动回调接线 + 收尾路径（D138 三分）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift:447`（`restoreDrawingSessionAfterPeriodChange`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/NodeDragCandidateTests.swift`（追加）

**Interfaces:**
- Consumes: Task 2 `draggedAnchor`、Task 3 `updateDrawingAnchor`、Task 4 三个 mutator
- Produces: `Coordinator.handleNodeDrag(translation:phase:)`

- [ ] **Step 1: 写失败测试（N4 一条撤销记录 + T4 就地定住 + N8 切周期作废 + T14⑤ 陈旧回调）**

⚠️ **N4 的四条断言缺一不可**（spec 点名）：① 撤销栈深度**恰好 1**；② ↩ 一次锚点**整个**回到拖前；③ 拖动后锚点**确实 ≠** 拖前（否则「撤销后等于拖前」因为压根没改而恒真）；④ `drawingsRevision` 相对基线**恰好 +1**。

⚠️ **N8 必须用 `TrainingEngineInteractionTests.engineMultiPeriod()` + `.toSmaller`**（`TrainingEngineInteractionTests.swift:189`）—— `preview()` 只有 `.m3/.m60/.daily`，两个方向都会撞「目标周期无数据 → no-op」守卫而**恒绿**。

- [ ] **Step 2: 写实现**

```swift
        /// P1c 第 3 片：节点拖动的三个相位。**唯一**调用 `updateDrawingAnchor` 的生产路径。
        private func handleNodeDrag(translation: CGPoint, phase: GesturePhase) {
            guard let engine, let view else { return }
            let session = engine.drawingSession
            switch phase {
            case .began:
                // D140：路由到拖动之后才刹车，顺序与落锚逐字相同（G3 的 ② 分支钉死）
                engine.settleDeceleration(initiatedBy: panel)
                rebuildRenderState(bounds: view.bounds)
                let viewport = view.renderState.viewport
                guard viewport.geometry.candleStep > 0 else { return }
                let mapper = CoordinateMapper(viewport: viewport,
                                              displayScale: view.traitCollection.displayScale)
                guard let c = nodeDragCandidate,
                      let drawing = RenderStateBuilder.visibleDrawings(
                          engine: engine, panel: panel, tick: engine.tick.globalTickIndex)
                          .last(where: { $0.id == c.drawingID }),
                      let tool = KLineView.drawingTools[drawing.toolType],
                      let anchor = DrawingNodeDrag.draggedAnchor(
                          drawing: drawing, anchorIndex: c.anchorIndex, translation: translation,
                          mapper: mapper, tool: tool)
                else { nodeDragCandidate = nil; return }
                session.beginNodeDrag(c, anchor: anchor)
                nodeDragCandidate = nil                 // 候选已被消费（D140b 第三行）
                rebuildRenderState(bounds: view.bounds)

            case .changed:
                guard let (owner, drawing, tool, mapper) = activeNodeDrag() else { return }
                guard let anchor = DrawingNodeDrag.draggedAnchor(
                        drawing: drawing, anchorIndex: owner.anchorIndex, translation: translation,
                        mapper: mapper, tool: tool) else { return }
                session.updateNodeDragCurrent(anchor)
                rebuildRenderState(bounds: view.bounds)   // ⛔ 直连重绘：nodeDragCurrent 不参与 observation

            case .ended, .cancelled:
                guard let (owner, drawing, tool, mapper) = activeNodeDrag() else { return }
                let anchor = DrawingNodeDrag.draggedAnchor(
                    drawing: drawing, anchorIndex: owner.anchorIndex, translation: translation,
                    mapper: mapper, tool: tool) ?? (session.nodeDragCurrent ?? drawing.anchors[owner.anchorIndex])
                session.endNodeDrag()                    // 先清槽再写：避免覆盖影响写入读到的 old
                _ = engine.updateDrawingAnchor(id: owner.drawingID, anchorIndex: owner.anchorIndex,
                                               anchor: anchor)
                rebuildRenderState(bounds: view.bounds)
            }
        }

        /// D135b 的**每帧身份判据**，三条相位分支**调同一个**（G11 钉死）。
        /// **⛔ 两种失败必须分开处理**（顺序 load-bearing）：
        ///   ① 槽为空 / 回调来自别的面板 ⇒ **直接忽略，不提交、不清槽、不碰任何状态**
        ///      （这是**别人的**槽或空槽，本回调已经陈旧）；
        ///   ② 归属 ≠ 当前选中 ⇒ **就地定住** + 清槽，然后忽略本次回调。
        /// ⛔ 合并成一支会让 A 的陈旧回调把正在拖的 B **提前提交并清槽**（spec 第 10 轮 R1-high）。
        private func activeNodeDrag()
            -> (DrawingSession.NodeDragOwner, DrawingObject, any DrawingTool, CoordinateMapper)? {
            guard let engine, let view else { return nil }
            let session = engine.drawingSession
            // ① 先判来源
            guard let owner = session.nodeDragOwner, owner.panel == panel else { return nil }
            // ② 再判归属
            guard owner.drawingID == session.selectedDrawingID,
                  owner.panel == session.selectedPanel else {
                finalizeNodeDragInPlace(owner)          // 就地定住（能写就写，D135b 总则）
                return nil
            }
            let viewport = view.renderState.viewport
            guard viewport.geometry.candleStep > 0,
                  let drawing = RenderStateBuilder.visibleDrawings(
                      engine: engine, panel: panel, tick: engine.tick.globalTickIndex)
                      .last(where: { $0.id == owner.drawingID }),
                  let tool = KLineView.drawingTools[drawing.toolType] else { return nil }
            return (owner, drawing, tool,
                    CoordinateMapper(viewport: viewport,
                                     displayScale: view.traitCollection.displayScale))
        }

        /// 就地定住：写一次、记一条撤销，与抬手**同一条**收尾语义（D138）。
        private func finalizeNodeDragInPlace(_ owner: DrawingSession.NodeDragOwner) {
            guard let engine, let anchor = engine.drawingSession.nodeDragCurrent else { return }
            engine.drawingSession.endNodeDrag()
            _ = engine.updateDrawingAnchor(id: owner.drawingID, anchorIndex: owner.anchorIndex,
                                           anchor: anchor)
        }
```

并在 `attach(to:)` 里接：
```swift
            arbiter.onNodeDrag = { [weak self] translation, phase in
                self?.handleNodeDrag(translation: translation, phase: phase)
            }
```

⚠️ **N8 的落点**：`TrainingEngine.restoreDrawingSessionAfterPeriodChange`（`:447`）里，在既有 `discardPendingAnchors()` 旁边加 `drawingSession.endNodeDrag()`。
⛔ 既有守卫 `periodChangeUsesDiscardNotCancel`（`DrawingGestureSourceGuardTests.swift:84`）钉死该函数体内**不得出现** `deactivate()` / `cancelDrawingAllPanels()` / `.cancel()` —— `endNodeDrag()` 不在禁列，但**加完必须复跑它**。

- [ ] **Step 3: 跑测试 + 复跑周期守卫**

```bash
cd "ios/Contracts" && swift test --filter DrawingGestureSourceGuardTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
cd "ios/Contracts" && swift test 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -10
```

- [ ] **Step 4: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift \
        ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/NodeDragCandidateTests.swift
git commit -m "P1c-3 Task11：拖动三相位接线 + 收尾路径（D138 三分 / D135b 两支失败）

一次拖动只在收尾调一次 updateDrawingAnchor ⇒「一次拖动 = 一条撤销记录」由
构造保证。身份判据抽成一个函数、三条相位分支调同一个，且**两种失败分开**：
来源不匹配 ⇒ 直接忽略（⛔ 不提交不清槽）；归属对不上 ⇒ 才就地定住。
顺序 load-bearing——合并会让陈旧回调把正在拖的另一条提前提交。
周期变化的作废落在既有善后单点，⛔ 不另写一份取消语义。"
```

---

## Task 12: 源码守卫 G2–G15

**Files:**
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/NodeDragSourceGuardTests.swift`

**Interfaces:**
- Consumes: 所有前序任务落地的源码文本（本任务不新增任何生产 API）

- [ ] **Step 1: 把「读源码 + 剥注释 + 切函数体」的工具从既有守卫里抄过来**

```bash
sed -n '1,40p' ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/DrawingGestureSourceGuardTests.swift
```
⚠️ **复用它的 `contractsDir` / `source(_:)` 写法**（逐行剥行尾 `//` 之后的内容）。⛔ 不新造一套 —— 两份剥注释逻辑早晚会漂。

- [ ] **Step 2: 写 14 条守卫**

每条遵守同一骨架：**切片锚点找不到 ⇒ `Issue.record` 当场红**（⛔ 不得静默通过）+ **防切片为空的正向断言** + **两个（或三个）方向**。

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/NodeDragSourceGuardTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md §8.3（G2–G15）
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("P1c-3 源码守卫（G2–G15）")
struct NodeDragSourceGuardTests {

    private var contractsDir: URL { /* 照 DrawingGestureSourceGuardTests 的四层上溯写 */ }
    private func source(_ rel: String) throws -> String { /* 逐行剥行尾注释，同款 */ }
    /// 切出某个函数体：从签名到**下一个同缩进的 `}`**。找不到 ⇒ 返回 nil，调用方必须 Issue.record
    private func body(of signature: String, in code: String) -> String? { /* … */ }

    @Test("G2 起手路径上不得出现 DrawingHitTester（D134 的结构不变量）")
    func probeDoesNotConsultLines() throws {
        let code = try source("Sources/KlineTrainerContracts/Render/ChartContainerView.swift")
        guard let b = body(of: "private func captureNodeDragCandidate(at point: CGPoint)", in: code) else {
            Issue.record("切片锚点找不到 —— captureNodeDragCandidate 被改名？守卫失效，必须修"); return
        }
        #expect(b.contains("hitTestNode("))          // ⭐ 防切片为空，否则负向断言假绿
        #expect(!b.contains("DrawingHitTester"))
    }

    @Test("G3① 触摸按下的处理必须**纯只读**：不得出现 settle / rebuild / 任何 engine mutator")
    func touchDownHandlerIsReadOnly() throws { /* 同骨架；⭐ 正向断言体内含 nodeDragPreconditions( */ }

    @Test("G3② 拖动 .began 的四步顺序：settle → rebuild → 读 viewport → CoordinateMapper")
    func nodeDragBeganOrder() throws { /* 四个锚点缺任何一个都 Issue.record */ }

    @Test("G4 探针不得自己重抄那份非几何清单")
    func probeDoesNotReimplementGateList() throws {
        // 反向：nodeDragPreconditions 体内不出现 locked / hasKnownFuture / isEditableToolType / flow.mode
        // 正向：体内**确实**出现 editableIgnoringGeometry(
    }

    @Test("G6 .began 路由不得重做几何命中；按下处理里必须有")
    func beganDoesNotRehitTest() throws { /* 两个方向缺一不可 */ }

    @Test("G7 触摸钩子只在单点触摸时发")
    func touchDownHookIsSingleTouchOnly() throws { /* ⚠️ 另有 Task9 的行为测试兜底「>= 1」这种写法 */ }

    @Test("G8 候选清除点恰好三处，且都不在触摸结束/取消里")
    func candidateClearSitesAreExactlyThree() throws { /* 两个方向：总数 + 取消里没有 */ }

    @Test("G9 探针与复核调同一具名函数，且复核另有身份比对")
    func probeAndRevalidationShareOnePredicate() throws { /* 三个方向 */ }

    @Test("G10 渲染读路径零写入")
    func renderReadPathHasNoWrites() throws {
        let code = try source("Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift")
        guard let b = body(of: "private static func applyNodeDragOverride(", in: code) else {
            Issue.record("切片锚点找不到 —— applyNodeDragOverride 被改名？守卫失效，必须修"); return
        }
        #expect(b.contains("session.nodeDragOwner"))     // ⭐ 防切片为空
        for banned in ["updateDrawingAnchor", "endNodeDrag", "finalizeNodeDragInPlace", "drawingsRevision"] {
            #expect(!b.contains(banned), "渲染读路径里出现了写入调用：\(banned)")
        }
    }

    @Test("G11 身份判据是一个具名函数、三条相位分支调同一个")
    func identityPredicateIsSharedByThreePhases() throws { /* 两个方向；三条分支各自切片 */ }

    @Test("G12 点击选中两入口各自有门、且不自己抄条件")
    func tapSelectionGatesAreShared() throws { /* 两个入口各自切片 */ }

    @Test("G13「没有选中 ⇒ 没有拖动态」由构造保证")
    func clearSelectionDiscardsDrag() throws { /* 两个方向：两处都有 + 全文件处数恰好 */ }

    @Test("G14 拖动门的覆盖是**集合等式**（两个方向）")
    func dragGateCoverageIsSetEquality() throws {
        // ⛔ 必须集合等式：枚举 DrawingEditRouter.swift 里所有 @discardableResult 写入入口
        //    与所有以 Enabled 结尾的谓词，**集合** == {W1…W5} ∪ {E1…E5}
        //    ——「这十个都有」抓不到**第十一个**新入口（本仓有「存在性检查表达不了穷尽性」的具名记录）
        // ⚠️ 反向：五个 Enabled 谓词体内必须读 nodeDragOwner，⛔ 不得读 nodeDragCurrent
        //    （读错了 host 照样全绿、真机却不变灰）
    }

    @Test("G15 nodeDragOwner 与 nodeDragCurrent 同生同死")
    func bothHalvesAreAssignedTogether() throws { /* 两个方向 + 反向自检样本 */ }

    @Test("G 系列的切片工具**自身**双向自检（⛔ 判据自己不能空转）")
    func sliceHelperIsNotVacuous() {
        let good = "func f() { a() }\nfunc g() { b() }"
        #expect(body(of: "func f()", in: good)?.contains("a(") == true)
        #expect(body(of: "func f()", in: good)?.contains("b(") == false, "切片吃到了下一个函数")
        #expect(body(of: "func zzzNoSuch()", in: good) == nil, "找不到时必须返回 nil 让调用方 Issue.record")
    }
}
```

- [ ] **Step 3: 逐条「先红后绿」**

对**每一条**守卫：`cp` 备份对应生产文件 → 故意改坏 → 跑 → 确认**当场红** → `cp` 还原 → 再跑确认绿。
⛔ **一条都不许跳过** —— 没先红过的守卫，绿着也说明不了任何事（本仓「报 0 违反必须先证明它能报非 0」）。

```bash
cd ios/Contracts && swift test --filter NodeDragSourceGuardTests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -25
```

- [ ] **Step 4: 提交**

提交信息里**逐条列出**「改坏了什么 ⇒ 红的是哪条守卫」，⛔ 不要只写「都验过了」。

---

## Task 13: T5 像素证据（Catalyst）+ 四处基线同步

**Files:**
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/NodeDragPixelEvidenceTests.swift`
- Modify: `.github/scripts/catalyst-uikit-baseline.txt`（现 **80 行**）
- Modify: `.github/scripts/fixtures/pass-main-current.log`
- Modify: `.github/scripts/catalyst-gate.test.sh`
- Modify: `docs/superpowers/acceptance/2026-09-01-finalize-alert-truthful-exit.md`（现 **1935**）

**Interfaces:**
- Consumes: 第 2 片已落地的 `KLineView.drawSelectionNodes`（`Render/KLineView+Drawing.swift`）与 `drawMarkers`（`Render/KLineView+Markers.swift`）

- [ ] **Step 1: 写 T5**

```swift
// Spec §8-T5 + §2.4：成交标记是半径 5（直径 10pt）的实心圆，节点直径 7pt ⇒ 画在节点之后会整个盖住。
// §2.4 已实跑核实：MarkersLayout.findCandleIndex 返回的是**全局下标**（ArraySlice 保留原下标，
// RenderStateBuilder.swift:34 注释自陈 slice.startIndex == viewport.startIndex），与锚点的
// candleIndex **同一个 x 坐标空间** ⇒ 这条像素证据构造得出来。
#if canImport(UIKit)
@Test("T5 同一根 K 线 + 同一价位上既有成交标记又有选中节点 ⇒ 节点中心是**节点的颜色**")
func nodeIsNotCoveredByTradeMarker() throws {
    // ① 造 bitmap context；按 KLineView.draw 的真实顺序（`KLineView.swift:120` 一带）
    //    先 drawMarkers 再 drawSelectionNodes
    // ② 构造：marker.globalTick 落在第 N 根；线的锚点 candleIndex == N、price == 该根的 close
    // ③ 取节点中心像素，断言 == 节点色（日间纯黑）
    // ⭐ 正向对照：**移走标记**后同一点仍是节点色 —— 证明这条不是恒真
    // ⭐ 反向对照：把两次绘制**换序**（本测试内部，不改生产代码）⇒ 同一点变成标记色
    //    ——⭐ 这一条让 T5 自己证明了它有判别力，⛔ 不要省
}
#endif
```

- [ ] **Step 2: 回答 Q28 —— 能不能驱动真实长按识别器（T12①）**

```bash
grep -rn "UILongPressGestureRecognizer" ios/Contracts/Tests | head -20
```
**实跑二选一，把结论写进 spec §10 的 Q28 那一行**：
- **(a) 做得到** → T12① 落 Catalyst，Q28 改注「已闭合」；
- **(b) 做不到** → ⛔ **不得静默降级**。须同时做三件事：① 确认候选生命周期的规则层已被 Task 9 的 host 测试覆盖（T12 ③④⑤）；② 把「真识别器那一环」**逐条**写进真机验收清单；③ Q28 保留为具名残留并**逐条列出**未被自动化覆盖的断言（⛔ 不许只写数量 —— 本仓「延后的发现必须逐条列出」）。

- [ ] **Step 3: 冷构建取数**

```bash
cd ios/Contracts
DD=$(mktemp -d)
xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:KlineTrainerContractsTests -derivedDataPath "$DD" 2>&1 | tee /tmp/p1c3-catalyst.log | tail -20
```
⛔ **绝不删全局 DerivedData**（本仓有 20+ worktree）。

- [ ] **Step 4: 同步四处基线（漏一份 = 本地全绿、CI 才红）**

```bash
python3 .github/scripts/uikit-expected-tests.py > .github/scripts/catalyst-uikit-baseline.txt
wc -l .github/scripts/catalyst-uikit-baseline.txt
grep -c "macabi" /tmp/p1c3-catalyst.log
grep -n "1935" .github/scripts/catalyst-gate.test.sh docs/superpowers/acceptance/2026-09-01-finalize-alert-truthful-exit.md
```
- ① UIKit 基线**必须用脚本重新生成**，⛔ 不手打；
- ② 重裁 `pass-main-current.log` 用**本轮真冷构建**日志，且 macabi 证据行须含 **`macabi`** 字样（⛔ 不是路径里的 `maccatalyst`）⇒ 上面 `grep -c` 必须 > 0；
- ③④ 两处硬编码数字同步。
**净增用例数由本步实测填写，⛔ 不得估算。**

- [ ] **Step 5: 跑闸门**

```bash
.github/scripts/catalyst-gate.sh 2>&1 | tail -20
bash .github/scripts/catalyst-gate.test.sh 2>&1 | tail -20
```

- [ ] **Step 6: 提交**（把实测的新 Catalyst 总数与 UIKit 行数写进提交信息）

---

## Task 14: 变异验证（spec §8.4 的 45 条，逐条实跑）

**Files:**
- Create: `docs/superpowers/plans/2026-09-29-drawing-p1c-3-mutation-results.md`

- [ ] **Step 1: 确认工作树干净且实现已全部提交**

```bash
git status --porcelain
```
必须为空 —— ⛔ **先提交实现、再跑变异**（spec §8.4）。

- [ ] **Step 2: 逐条跑那 45 条**

每条固定流程：
```bash
cp <目标文件> /tmp/mut-backup.swift
# …改坏…
cd ios/Contracts && rm -rf .build && swift test --filter <相关套件> 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "failed|✘" | head
cp /tmp/mut-backup.swift <目标文件>
```

纪律（逐条适用）：
- **必须记录「红的是哪一条测试名」** —— 「有测试变红」是假信号；
- ⚠️ **每条期望一律实跑验证，⛔ 不得推理**（第 2 片在这上面栽了两次：spec 写「拿掉 y 守卫 ⇒ T1 变红」实测**不红**；写「拿掉锚数截断 ⇒ 两档都红」实测**第二档不红**）；
- ⚠️ spec 表里标了「**预期不红**」的档**也要实跑确认**（`priceDelta` 负号 → T10②；只给 🔒 加门 → 🔒 那档；后置条件退回弱判据 → `.ray` 档；未舍入空间选下标 → 其余档；探针只查 locked → ① 档）。**若它们红了，说明测试串了，要查**；
- ⚠️ ⛔ **跑变异期间不得改动工作树的其它部分**（第 2 片实证：构建期间改文件 ⇒ 读到改到一半的源码，报 3 条假失败）；
- ⚠️ 每条跑之前 `rm -rf .build` —— 本片给 `@Observable` 类加了存储属性，陈旧增量产物会在**随机位置** SIGSEGV。

- [ ] **Step 3: 写结果表**

`2026-09-29-drawing-p1c-3-mutation-results.md`，四栏：**变异** / **spec 的期望** / **实测红的是哪条测试名** / **一致？**
⚠️ 凡「实测 ≠ 期望」的行**必须**给出处置：① 补测试让它红；或 ② **有理有据地订正 spec 的期望**。⛔ **不得改判据去凑红**。

- [ ] **Step 4: 提交**

---

## Task 15: 验收清单 + 残留登记 + 三绿 + 整支评审

**Files:**
- Create: `docs/superpowers/acceptance/2026-09-28-drawing-p1c-3-node-drag.md`
- Modify: `docs/superpowers/specs/2026-09-28-drawing-tools-P1c-3-node-drag-design.md` §10（Q26 / Q27 / Q28 三行）

- [ ] **Step 1: 写验收清单**

照 spec §9 的 12 条骨架 + **开头五条已知限制**，另补 **Q27 的 `.ray` 一条**：

| # | 动作 | 预期 | 通过/不通过 |
|---|---|---|---|
| 13 | 选中一条横线，在样式面板把线型**从「直线」改成「射线」**，再按住黑点**横着**拖一段 | 线的**左端起点**跟着黑点一起移动（射线只朝右画），这是对的 | ☐ 通过 ☐ 不通过 |

⚠️ **三条纪律逐条自查**（spec §9）：
① **术语翻译成动作**，⛔ 不抄开发者说法（例：「点熄水平线图标」→「把横线图标**点成灰框**」）；
② **每条自查「真机上做不做得到」** —— 尤其第 13 条：先确认样式面板上「射线」这一档**真的可选**（`DrawingStyleAvailability.swift:6-11` 实测 `.straight` / `.ray` 都可选、只有 `.segment` 恒灰）；
③ **已知限制写在开头**（五条，见 spec §9）。

⚠️ **第 12 条**（成交标记不盖住黑点）必须补一句**怎么确认它们确实重合了**的可观察判据 —— 建议：先在十字光标下读出那根 K 线的收盘价，落锚时对准同一价位，**放大后**目视黑点与 B/S 圆点**同心**。

- [ ] **Step 2: 填实 spec §10 的三条残留**

- **Q26**（夹取 × 视口变化）：本片实现是「每帧重取当前 mapper」⇒ **补一条测试钉死它**（拖动中改视口 → 断言夹取用的是**新**边界）。写不出 ⇒ **升级为交接项并写明理由**，⛔ 不得默默跳过；
- **Q27**（`.ray` 横向拖动）：由 Step 1 的第 13 条覆盖 ⇒ 改注「**已闭合**」；
- **Q28**（真识别器）：填 Task 13 Step 2 的实测结论（(a) 或 (b)）；(b) 时**逐条列出**未覆盖的断言。

- [ ] **Step 3: 三绿门（作者亲核，clean build）**

```bash
cd ios/Contracts && rm -rf .build && swift test 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -15
cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$(mktemp -d)" 2>&1 | tail -15
.github/scripts/catalyst-gate.sh 2>&1 | tail -10
```
⚠️ 三条都要**贴出真实输出**，⛔ 不得只说「全绿」。

- [ ] **Step 4: 整支对抗性评审**

```bash
.claude/scripts/codex-attest.sh --scope branch-diff --head drawing/p1c-3-node-drag --base origin/main
```
⛔ 不得传任何未知参数（含 `--help` —— 兜底分支会把它当 focus 目标，产出**假 approve + 脏账本**）。
⚠️ 拿到 approve 后**连「它没能跑起来什么」一起读**并如实转述；⚠️ 账本条目要核 `head_sha` 吻合、`kind: branch`、**无 focus 字段**。

- [ ] **Step 5: 落一行脚本交给 user 推分支开 PR**

⚠️ 本仓的 guard 分支指纹检查自 #167 起恒不通过 ⇒ **Claude 的 Bash 推不了分支、也开不了 PR**，只能 user 在终端跑。
把推送与建 PR 的全部步骤写进 `.dev/push-p1c3.sh`（含 `--match-head-commit`），然后给 user **一行**：`bash .dev/push-p1c3.sh`
⛔ 给 user 的命令**超过一行会被终端换行截断**，所以一律落脚本。
⚠️ PR 描述用**中文**（本仓约定）。

---

## 自检（写完计划后跑的那一遍）

**1. spec 覆盖**（逐条指到任务）：

| 决策 | 落点 | 决策 | 落点 |
|---|---|---|---|
| D134 | Task 8 / 9 | D137 | Task 2 |
| D134b | Task 5 | D138 | Task 8 / 11 |
| D134c / D134d | Task 1 / 11 | D139 | Task 5（探针层）+ Task 3（引擎层） |
| D134e | Task 5 / 9 | D140 / D140b / D140c | Task 9 / 11 |
| D135 | Task 4 / 10 | D141 | 无需实现（**不动** `performDrawingAction`） |
| D135b | Task 11 | D142 / D143 | 无需实现（显式**不做**） |
| D135c | Task 6 | D144 | 无需实现（不 bump） |
| D135d | Task 7 | N1–N8 / T1–T15b / G1–G15 | Task 1–13 |

**无缺口。**

**2. 类型一致性**（已按**实测**签名核对，⛔ 不是凭印象）：`DrawingAnchor(period:candleIndex:price:)`（`Models.swift:214`，period 在**最前**）、`ChartGeometry(candleStep:candleWidth:gap:)`（`Geometry.swift:15`）、`PriceRange(min:max:)`（`:83`）、`DrawingObject` 的完整成员 init（`Models.swift:265-274`）。`DrawingObject` **没有** `withAnchors`（实测）⇒ 两处构造候选都就地写完整 init。

**3. 有三个步骤「按设计必须先失败」**（⚠️ 不是缺陷，是判别力的证明）：
- Task 3 Step 4：U-G4 穷尽性守卫**必须先红**（证明它真的在看着新写入面）；
- Task 12 Step 3：14 条源码守卫**逐条先红后绿**；
- Task 13 Step 1：T5 的换序对照**必须变成标记色**（证明它有判别力）。

**4. 留给实施者的四处「必须实跑决定」**（⛔ 一律不得推理）：
- Task 3 Step 5：`setDrawingLocked` 的 L12 守卫是否被本接口撞红；
- Task 7 Step 5：拖动中 `applyPanelStyleMutation` 的分叉行为（默认该变、线不该变）；
- Task 9 Step 2：T11 ①②③（惯性 / overscroll）在 host 上构造得出来吗；
- Task 13 Step 2：Q28 —— 真实长按识别器驱动得起来吗。

**5. 无占位符**：全计划无 TBD / TODO / 「类似 Task N」。三处 `/* … */` 各自配了**明确的补齐步骤**（Task 5 Step 1b、Task 7 Step 1b、Task 12 Step 2 的骨架），⛔ 不是「自己看着办」。

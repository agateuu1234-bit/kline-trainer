# 划线 P1c 第 2 片实施计划：节点显示 + 选中态终局

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 选中一条划线时在它的锚点上画出节点（黑/白实心圆），同时取消「选中 → 线变蓝」；锚点被视口甩出屏幕时在对应边框画一个不可拖的代理三角。

**Architecture:** 三层。① **决策层**（`DrawingNodeGeometry`，纯 CoreGraphics、工具无关）：把锚点投影成「真节点 / 代理标记 / 什么都不画」三选一，并提供节点命中的两层函数；② **绘制层**（`DrawingNodeRenderer`，纯 CoreGraphics）：只按决策机械绘制，零判断；③ **接线层**（`KLineView+Drawing` 的 dispatch，UIKit）：一行调用。可见性由新增的 `DrawingTool.isVisible` 提供 —— 它与各工具自己的 `render` / `hitTest` 共用同一判据，使「命中集合 ≡ 渲染集合」在结构上不可能分叉。

**Tech Stack:** Swift 6 / swift-testing（`@Test` + `#expect`）/ CoreGraphics（跨平台，host `swift test` 可跑像素断言）/ UIKit 仅在 dispatch 接线处。

**Spec:** `docs/superpowers/specs/2026-09-21-drawing-tools-P1c-2-nodes-design.md`（D121–D131，codex `approve` @ `28fa2a17`）

## Global Constraints

逐条抄自 spec，**每个 Task 的要求都隐含包含本节**：

- **节点视觉直径 = 7pt**；**节点命中半径 = 11pt**；**线的命中容差仍是 8pt，本片一个字不动**（D124）。
- **节点颜色**：`scheme == .dark` → 纯白；否则 → 纯黑。**无描边**（D107）。代理标记**同色族**，⛔ 不跟线的颜色走（D123）。
- ⛔ **节点的 x 绝不 clamp / 夹取** —— 恒等于 `mapper.indexToX(anchor.candleIndex)`。锚点出屏就是不画真节点（D123 硬约束，守卫 T4）。
- **命中集合 ≡ 渲染集合**：画得出的节点才命中得了；出屏锚点与代理标记**一律不可命中**（D131）。
- **命中返回的必须是原 `anchors` 下标**，⛔ 不得是筛选后数组的下标（D131 / §3.5）。⚠️ 本片无法证伪（水平线单锚），已交接 Q24。
- **只裁剪节点与代理标记**，⛔ **绝不给线加裁剪**（D125）。
- **登记表只登记 `.horizontal` 一行**；漂移告警必须是**集合等式**，⛔ 不得写成存在性检查（D122）。
- **`DrawingTool` 协议签名的 `isSelected` 参数保留**，仅含义从「画成蓝」变「画出节点」（D130 / B2）。
- **不 bump `CONTRACT_VERSION`**、不新增 `DrawingObject` 字段、不碰任何持久化路径（D130）。
- 所有新测试**优先落 host 层**（纯 CoreGraphics）；只有 Task 6 会动一条 Catalyst UIKit 测试（D121 / §8.4）。

## 文件结构

**新建**

| 文件 | 职责 |
|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift` | 登记表 + 三选一决策 + 命中两层。**纯 CoreGraphics，无 UIKit，工具无关** |
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeRenderer.swift` | 按决策机械绘制圆与三角 + 裁剪。**零判断** |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeGeometryTests.swift` | Task 2/3 的断言 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeRendererTests.swift` | Task 4 的像素断言 |
| `docs/superpowers/acceptance/2026-09-21-drawing-p1c-2-nodes.md` | 非程序员验收清单（spec §9 定稿版） |

**修改**

| 文件 | 改什么 |
|---|---|
| `Drawing/DrawingTool.swift` | 加 `isVisible` 协议成员；改 `isSelected` 头注 |
| `Drawing/HorizontalLineTool.swift` | 实现 `isVisible`；`render` 去掉换色三目 |
| `Drawing/DrawingColorResolver.swift` | 删 `selectionRGBA` |
| `Render/KLineView+Drawing.swift` | dispatch 接线（一处） |
| `Tests/.../Drawing/HorizontalLineToolTests.swift` | 翻转 A3 / A4，删 A5 |
| `Tests/.../ThemePaletteTests.swift` | 删 A6 |
| `Tests/.../Render/ChartContainerViewDrawingSessionTests.swift` | 翻转 A7 |
| `Tests/.../Drawing/DrawDrawingsDispatchTests.swift`、`DrawingProtocolTests.swift`、`SpecLiteralGuardTests.swift` | 三个 mock 各补 `isVisible` |
| `.github/scripts/catalyst-uikit-baseline.txt` / `catalyst-total-baseline.txt` | 基线同步（Task 6） |
| `docs/superpowers/mockups/2026-07-03-drawing-tools-expansion.html` | caption 加订正批注（Task 7） |

**任务 ↔ spec 的三个子项**（对应仓内「每 PR ≤3 子项」纪律）：① 决策与命中（Task 1–3）；② 绘制与接线（Task 4–5）；③ 取消变蓝与文档（Task 6–7）。

---

### Task 1: 给 `DrawingTool` 加可见性成员（纯加法，零行为变化）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift:14-24`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift`（新增一个方法）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift:201`（`SpyDrawingTool`）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingProtocolTests.swift:57`（`FakeDrawingTool`）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/SpecLiteralGuardTests.swift:40`（`SignatureGuardTool`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/HorizontalLineToolTests.swift`（追加）

**Interfaces:**
- Produces: `DrawingTool.isVisible(drawing:mapper:) -> Bool`，Task 3 与 Task 5 消费。

**为什么加协议成员而不是在 dispatch 里写死 `.horizontal`**：dispatch 今天**已经**写死了一处（`KLineView+Drawing.swift:33` 的标签分支，即第 1 片交接的 Q10）。再写死一处就是第三处，且直接违反 D121「工具无关」。协议成员让第 4/5/6 片加新工具时**编译器强制**它们实现（fail-closed），并让 D131 在结构上成立。

- [ ] **Step 1: 写失败测试**

追加到 `HorizontalLineToolTests.swift` 末尾（`}` 之前）：

```swift
    @MainActor
    @Test("D131：isVisible 与 visibleGeometry != nil 逐格等价（render/hitTest/节点共用同一判据）")
    func isVisibleMatchesVisibleGeometry() {
        let m = Self.mapper()   // mainChartFrame x∈[0,800] y∈[0,360]，price∈[10,20]
        let tool = HorizontalLineTool()
        // 逐格穷举：3 种线型 × 3 个价位（区间内 / 区间外上 / 区间外下） × 3 个锚点 x（屏内 / 左外 / 右外）
        var checked = 0
        for sub in [LineSubType.straight, .ray, .segment] {
            for price in [15.0, 5.0, 25.0] {
                for idx in [5, -50, 500] {
                    let d = DrawingObject(toolType: .horizontal,
                                          anchors: [DrawingAnchor(period: .m3, candleIndex: idx, price: price)],
                                          isExtended: sub == .ray, panelPosition: 0, lineSubType: sub)
                    #expect(tool.isVisible(drawing: d, mapper: m)
                            == (HorizontalLineTool.visibleGeometry(for: d, mapper: m) != nil),
                            "逐格等价失败：sub=\(sub) price=\(price) idx=\(idx)")
                    checked += 1
                }
            }
        }
        #expect(checked == 27, "必须真的跑满 27 格，否则这条断言是空转")
        // 判别力自检：这 27 格里 true 和 false 都必须出现，否则等价断言可能恒真
        let anyTrue = tool.isVisible(drawing: DrawingObject(
            toolType: .horizontal, anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
            isExtended: false, panelPosition: 0, lineSubType: .straight), mapper: m)
        let anyFalse = tool.isVisible(drawing: DrawingObject(
            toolType: .horizontal, anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
            isExtended: false, panelPosition: 0, lineSubType: .segment), mapper: m)
        #expect(anyTrue == true, "正向档：可见的线必须报 true")
        #expect(anyFalse == false, "负向档：.segment 必须报 false —— 证明本函数报得出非 true")
    }
```

- [ ] **Step 2: 跑测试，确认它因「没有这个方法」而编译失败**

```bash
cd ios/Contracts && swift test --filter isVisibleMatchesVisibleGeometry 2>&1 | tail -20
```

Expected: 编译错误 `value of type 'HorizontalLineTool' has no member 'isVisible'`

- [ ] **Step 3: 加协议成员**

`DrawingTool.swift` 在 `hitTest` 声明之后加：

```swift
    /// D131（P1c 第 2 片）：这条线此刻**画不画得出来**。
    /// **节点的渲染与命中共用它** —— 各 tool 必须让它与自己的 `render` / `hitTest` 走**同一个判据**
    /// （水平线三者共用 `visibleGeometry`），使「命中集合 ≡ 渲染集合」在结构上不可能分叉。
    /// ⛔ 新工具不得为它单写一份可见性逻辑。
    func isVisible(drawing: DrawingObject, mapper: CoordinateMapper) -> Bool
```

- [ ] **Step 4: 实现（生产 + 三个测试 mock）**

`HorizontalLineTool.swift` 在 `hitTest` 之后加：

```swift
    /// D131：与 `render` / `hitTest` **同一个判据**（三者都问 `visibleGeometry`）。
    public func isVisible(drawing: DrawingObject, mapper: CoordinateMapper) -> Bool {
        Self.visibleGeometry(for: drawing, mapper: mapper) != nil
    }
```

三个测试 mock 各加一行（它们只需满足协议，语义取「恒可见」即可 —— 它们的测试目的与可见性无关）：

```swift
    func isVisible(drawing: DrawingObject, mapper: CoordinateMapper) -> Bool { true }
```

- [ ] **Step 5: 跑测试，确认通过**

```bash
cd ios/Contracts && swift test --filter isVisibleMatchesVisibleGeometry 2>&1 | tail -10
```

Expected: PASS

- [ ] **Step 6: 跑全量，确认没碰坏别的**

```bash
cd ios/Contracts && swift test 2>&1 | tail -5
```

Expected: `Test run with 1834 tests in 211 suites passed`（起点 1833 + 本条 1）

- [ ] **Step 7: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/
git commit -m "P1c-2 Task1：DrawingTool 加 isVisible（D131 的结构前提，零行为变化）

节点的渲染与命中必须共用同一可见性判据。水平线实现为 visibleGeometry != nil，
与 render / hitTest 同源。27 格逐格等价 + 正负向判别力自检。"
```

---

### Task 2: 节点登记表 + 三选一决策（工具无关）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeGeometryTests.swift`

**Interfaces:**
- Consumes: `DrawingTool.isVisible`（Task 1）—— 以 `isVisible: Bool` 参数形式传入，**本类型自己不认识任何具体工具**。
- Produces:
  - `DrawingNodeGeometry.NodeMark`（`.real(index:at:)` / `.proxy(index:at:pointingLeft:)`，`Equatable`）
  - `DrawingNodeGeometry.marks(for:mapper:isVisible:) -> [NodeMark]`
  - `DrawingNodeGeometry.toolsWithNodes: Set<DrawingToolType>`
  - `DrawingNodeGeometry.visualDiameter: CGFloat`（7）、`hitRadius: CGFloat`（11）
  - Task 3 用命中、Task 4 用绘制、Task 5 用接线。

- [ ] **Step 1: 写失败测试**

新建 `DrawingNodeGeometryTests.swift`：

```swift
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("DrawingNodeGeometry")
struct DrawingNodeGeometryTests {

    /// 与 HorizontalLineToolTests 同量纲：mainChartFrame x∈[0,800] y∈[0,360]，price∈[10,20]，candleStep=10。
    static func mapper(startIndex: Int = 0) -> CoordinateMapper {
        let main = CGRect(x: 0, y: 0, width: 800, height: 360)
        let vp = ChartViewport(
            startIndex: startIndex, visibleCount: 80, pixelShift: 0,
            geometry: ChartGeometry(candleStep: 10, candleWidth: 7, gap: 3),
            priceRange: PriceRange(min: 10, max: 20), mainChartFrame: main)
        return CoordinateMapper(viewport: vp, displayScale: 2.0)
    }

    static func line(idx: Int, price: Double = 15, sub: LineSubType = .straight) -> DrawingObject {
        DrawingObject(toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m3, candleIndex: idx, price: price)],
                      isExtended: sub == .ray, panelPosition: 0, lineSubType: sub)
    }

    @Test("T2：登记表漂移告警是集合等式（两个方向都成立，⛔ 不是存在性检查）")
    func nodeTableIsSetEquality() {
        #expect(DrawingToolType.implemented == DrawingNodeGeometry.toolsWithNodes,
                "有工具画得出却没登记节点（或反之）：implemented=\(DrawingToolType.implemented) nodes=\(DrawingNodeGeometry.toolsWithNodes)")
        #expect(DrawingNodeGeometry.toolsWithNodes == [.horizontal],
                "P1c 第 2 片表里只应有水平线一行（D122）")
    }

    @Test("T1：三态互斥且穷尽 —— 任给输入恰好命中一种，且三种都出现过")
    func threeOutcomesAreMutuallyExclusiveAndExhaustive() {
        let m = Self.mapper()
        var seenNone = false, seenReal = false, seenProxy = false
        var cases = 0
        // idx=5 → x=50（屏内）；idx=-50 → x=-500（左外）；idx=500 → x=5000（右外）
        for idx in [5, -50, 500] {
            for price in [15.0, 25.0] {           // 15 在区间内、25 在区间外（线不可见）
                for vis in [true, false] {
                    let marks = DrawingNodeGeometry.marks(for: Self.line(idx: idx, price: price),
                                                          mapper: m, isVisible: vis)
                    let isNone  = marks.isEmpty
                    var isReal = false, isProxy = false
                    if marks.count == 1 {
                        if case .real  = marks[0] { isReal  = true }
                        if case .proxy = marks[0] { isProxy = true }
                    }
                    #expect([isNone, isReal, isProxy].filter { $0 }.count == 1,
                            "三态必须恰好命中一种：idx=\(idx) price=\(price) vis=\(vis) marks=\(marks)")
                    seenNone = seenNone || isNone; seenReal = seenReal || isReal; seenProxy = seenProxy || isProxy
                    cases += 1
                }
            }
        }
        #expect(cases == 12, "必须真的跑满 12 格")
        // ⭐ 判别力：三种都必须真的出现过，否则「恰好命中一种」可能因为恒返同一种而全绿
        #expect(seenNone && seenReal && seenProxy,
                "三态必须都出现过：none=\(seenNone) real=\(seenReal) proxy=\(seenProxy)")
    }

    @Test("N4：真节点坐标 ≡ 锚点经 mapper 的投影（先断言个数，防空数组恒真）")
    func realNodeEqualsAnchorProjection() {
        let m = Self.mapper()
        let d = Self.line(idx: 5)
        let marks = DrawingNodeGeometry.marks(for: d, mapper: m, isVisible: true)
        #expect(marks.count == d.anchors.count, "节点个数必须等于锚点个数（否则下面逐个比较恒真）")
        guard case let .real(i, p) = marks[0] else {
            Issue.record("屏内锚点必须产生真节点，实得 \(marks[0])"); return
        }
        #expect(i == 0, "必须是原 anchors 下标")
        #expect(p.x == m.indexToX(d.anchors[0].candleIndex))
        #expect(p.y == m.priceToY(d.anchors[0].price))
    }

    @Test("⭐T4：出屏锚点绝不被 clamp 成真节点（D123 硬约束的守卫）")
    func offscreenAnchorNeverBecomesRealNode() {
        let m = Self.mapper()
        for idx in [-50, -1, 81, 500] {     // x = -500, -10, 810, 5000，全在 [0,800] 之外
            let marks = DrawingNodeGeometry.marks(for: Self.line(idx: idx), mapper: m, isVisible: true)
            #expect(marks.count == 1, "线可见时必须产生恰好一个记号：idx=\(idx)")
            if case .real = marks[0] {
                Issue.record("idx=\(idx)：出屏锚点被画成了真节点 —— 真节点被挪到了不属于它的 K 线上（D123 硬约束破坏）")
            }
        }
        // 正向对照：屏内锚点确实产生真节点 ⇒ 证明上面不是因为恒不产生 .real 而绿
        let inside = DrawingNodeGeometry.marks(for: Self.line(idx: 5), mapper: m, isVisible: true)
        if case .real = inside[0] {} else { Issue.record("正向对照失败：屏内锚点必须是真节点") }
    }

    @Test("T3：代理标记的朝向与落点 —— 左外朝左贴左框、右外朝右贴右框（两个方向各自单独断言）")
    func proxyMarkSideAndDirection() {
        let m = Self.mapper()
        let frame = m.viewport.mainChartFrame
        // 左外
        guard case let .proxy(li, lp, lLeft) = DrawingNodeGeometry.marks(
            for: Self.line(idx: -50), mapper: m, isVisible: true)[0] else {
            Issue.record("左外锚点必须产生代理标记"); return
        }
        #expect(li == 0); #expect(lp.x == frame.minX, "左外必须贴左边框"); #expect(lLeft == true, "左外必须朝左")
        // 右外
        guard case let .proxy(ri, rp, rLeft) = DrawingNodeGeometry.marks(
            for: Self.line(idx: 500), mapper: m, isVisible: true)[0] else {
            Issue.record("右外锚点必须产生代理标记"); return
        }
        #expect(ri == 0); #expect(rp.x == frame.maxX, "右外必须贴右边框"); #expect(rLeft == false, "右外必须朝右")
        // 两者的 y 都等于该锚点的价位投影（与线同高）
        #expect(lp.y == m.priceToY(15)); #expect(rp.y == m.priceToY(15))
    }

    @Test("N6：线不可见 → 节点与代理标记都不画（三者同进同退）")
    func invisibleLineDrawsNothing() {
        let m = Self.mapper()
        for idx in [5, -50, 500] {
            #expect(DrawingNodeGeometry.marks(for: Self.line(idx: idx), mapper: m, isVisible: false).isEmpty,
                    "不可见时必须一个记号都不产生：idx=\(idx)")
        }
        // 正向对照：同样的输入在可见时产生记号 ⇒ 证明不是因为函数恒返空而绿
        #expect(!DrawingNodeGeometry.marks(for: Self.line(idx: 5), mapper: m, isVisible: true).isEmpty)
    }

    @Test("登记表之外的工具不产生任何节点（本片只登记水平线）")
    func unregisteredToolHasNoNodes() {
        let m = Self.mapper()
        let trend = DrawingObject(toolType: .trend,
                                  anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
                                  isExtended: false, panelPosition: 0)
        #expect(DrawingNodeGeometry.marks(for: trend, mapper: m, isVisible: true).isEmpty,
                ".trend 未登记，不得产生节点")
    }

    @Test("N5：节点跟着视口走 —— 平移与缩放后各自等于【当时那个 mapper】的投影")
    func nodeFollowsViewport() {
        let d = Self.line(idx: 20)
        // ① 平移：startIndex 0 → 10，锚点 x 必须真的左移 100pt
        let m0 = Self.mapper(startIndex: 0), m1 = Self.mapper(startIndex: 10)
        guard case let .real(_, p0) = DrawingNodeGeometry.marks(for: d, mapper: m0, isVisible: true)[0],
              case let .real(_, p1) = DrawingNodeGeometry.marks(for: d, mapper: m1, isVisible: true)[0] else {
            Issue.record("两档都必须是真节点"); return
        }
        #expect(p0.x != p1.x, "⭐ 平移后节点 x 必须真的变了，否则下面的等式可能因为节点被写死而恒真")
        #expect(p0.x == m0.indexToX(20) && p1.x == m1.indexToX(20),
                "每一档都必须等于【那一档自己的】mapper 投影（不得停在旧视口）")
        #expect(p1.x - p0.x == -100, "startIndex +10 × candleStep 10 ⇒ 左移 100pt，实得 \(p1.x - p0.x)")
        // ② 缩放：candleStep 10 → 5，同一根 K 线的 x 必须随之减半
        let mZoom = CoordinateMapper(viewport: ChartViewport(
            startIndex: 0, visibleCount: 160, pixelShift: 0,
            geometry: ChartGeometry(candleStep: 5, candleWidth: 3, gap: 2),
            priceRange: PriceRange(min: 10, max: 20),
            mainChartFrame: CGRect(x: 0, y: 0, width: 800, height: 360)), displayScale: 2.0)
        guard case let .real(_, pz) = DrawingNodeGeometry.marks(for: d, mapper: mZoom, isVisible: true)[0] else {
            Issue.record("缩放档必须是真节点"); return
        }
        #expect(pz.x == mZoom.indexToX(20) && pz.x != p0.x, "缩放后节点 x 必须跟着新的 candleStep 走")
        // ③ 节点 y 与线 y 同源（F2）：两档的 y 都等于同一个 priceToY
        #expect(p0.y == m0.priceToY(15) && p1.y == m1.priceToY(15))
    }

    @Test("T7：.ray 锚点滚出右缘 → 整条线不画，因此也没有代理标记")
    func rayBeyondRightEdgeDrawsNothing() {
        let m = Self.mapper()
        let tool = HorizontalLineTool()
        let rayOut = Self.line(idx: 500, sub: .ray)          // x = 5000 > frame.maxX = 800
        #expect(tool.isVisible(drawing: rayOut, mapper: m) == false,
                "前提：.ray 锚点超右缘时 lineXRange 返 nil ⇒ 线不可见")
        #expect(DrawingNodeGeometry.marks(for: rayOut, mapper: m,
                                          isVisible: tool.isVisible(drawing: rayOut, mapper: m)).isEmpty,
                "线都不画了，节点与代理标记也一个都不许有")
        // 正向对照：同一条 .ray 锚点在框内 ⇒ 线可见且有真节点 ⇒ 证明上面不是恒空
        let rayIn = Self.line(idx: 5, sub: .ray)
        #expect(tool.isVisible(drawing: rayIn, mapper: m) == true)
        guard case .real = DrawingNodeGeometry.marks(for: rayIn, mapper: m, isVisible: true)[0] else {
            Issue.record("正向对照：框内 .ray 必须有真节点"); return
        }
    }
}
```

- [ ] **Step 2: 跑测试，确认因类型不存在而编译失败**

```bash
cd ios/Contracts && swift test --filter DrawingNodeGeometry 2>&1 | tail -20
```

Expected: 编译错误 `cannot find 'DrawingNodeGeometry' in scope`

- [ ] **Step 3: 写实现**

新建 `DrawingNodeGeometry.swift`：

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift
// Spec: docs/superpowers/specs/2026-09-21-drawing-tools-P1c-2-nodes-design.md（D107 / D111 / D121–D124 / D131）
//
// 选中态节点的**决策层**：把锚点投影成「真节点 / 代理标记 / 什么都不画」三选一，并提供节点命中。
// 工具无关 —— 本类型不认识任何具体工具；线可不可见由调用方经 `DrawingTool.isVisible` 传入。
// 跨平台：仅 CoreGraphics（与 DrawingTool / HorizontalLineTool 一致，无 UIKit）→ host swift test 全覆盖。

import CoreGraphics

@MainActor
public enum DrawingNodeGeometry {

    /// D124：节点**视觉**直径（pt）。线宽档 1–5 = 1.5…3.5pt ⇒ 7pt 是最粗线的 2 倍，
    /// 满足 D107「与线连成一体」又看得出是个点。
    public static let visualDiameter: CGFloat = 7

    /// D124：节点**命中**半径（pt）。与线的命中容差（8pt，`HorizontalLineTool.swift:24`）**各自一份** ——
    /// 两者量纲不同：线是一维带宽，节点是二维圆盘。11 ≥ 8 保证「节点附近凡线命中的点、节点也命中」。
    public static let hitRadius: CGFloat = 11

    /// D122：本构建**画得出节点**的工具表。P1c 后续切片加工具 = **加一行**。
    /// ⚠️ 与 `DrawingToolType.implemented` 的相等由 `nodeTableIsSetEquality` 钉死（集合等式，两个方向）。
    /// ⚠️ **P2 会打破这个等式**：母 spec §6 把周期线 / 斐波那契列为「无节点」工具，它们进 `implemented`
    ///    的那一天，该断言必须连同本表一起重新论证 —— ⛔ 不得简单地把它们塞进本表了事。
    public static let toolsWithNodes: Set<DrawingToolType> = [.horizontal]

    /// 一个节点记号。`index` 恒为该锚点在 `drawing.anchors` 里的**原下标**（D131 / §3.5）。
    public enum NodeMark: Equatable {
        /// 真节点：锚点落在主图横向范围内，**可拖（第 3 片）、可命中**。
        case real(index: Int, at: CGPoint)
        /// 代理标记：锚点被视口甩出屏幕，在对应边框画一个**不可拖、不可命中**的提示。
        case proxy(index: Int, at: CGPoint, pointingLeft: Bool)
    }

    /// 三选一决策（§3.3 那张表）。⛔ **真节点的 x 绝不 clamp** —— 恒等于 `indexToX(candleIndex)`。
    /// 「锚点绑定的 K 线永不改变」是持久化不变量；把节点画在不属于它的 K 线上会让拖动语义失真（D123）。
    public static func marks(for drawing: DrawingObject, mapper: CoordinateMapper,
                             isVisible: Bool) -> [NodeMark] {
        guard isVisible, toolsWithNodes.contains(drawing.toolType) else { return [] }
        let frame = mapper.viewport.mainChartFrame
        return drawing.anchors.enumerated().map { (i, anchor) -> NodeMark in
            let x = mapper.indexToX(anchor.candleIndex)      // ⛔ 不 clamp（T4 钉死）
            let y = mapper.priceToY(anchor.price)
            if x < frame.minX { return .proxy(index: i, at: CGPoint(x: frame.minX, y: y), pointingLeft: true) }
            if x > frame.maxX { return .proxy(index: i, at: CGPoint(x: frame.maxX, y: y), pointingLeft: false) }
            return .real(index: i, at: CGPoint(x: x, y: y))
        }
    }
}
```

- [ ] **Step 4: 跑测试，确认全部通过**

```bash
cd ios/Contracts && swift test --filter DrawingNodeGeometry 2>&1 | tail -12
```

Expected: 9 个测试全 PASS

- [ ] **Step 5: 变异验证 —— 证明 T4 真的守得住**

```bash
cp ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift /tmp/nodegeo.bak
# 把「不 clamp」改成「clamp 到边框」：出屏锚点会被画成真节点
perl -0pi -e 's/if x < frame\.minX \{ return \.proxy\(index: i, at: CGPoint\(x: frame\.minX, y: y\), pointingLeft: true\) \}\n            if x > frame\.maxX \{ return \.proxy\(index: i, at: CGPoint\(x: frame\.maxX, y: y\), pointingLeft: false\) \}\n            return \.real\(index: i, at: CGPoint\(x: x, y: y\)\)/return .real(index: i, at: CGPoint(x: min(max(x, frame.minX), frame.maxX), y: y))/' \
  ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift
cd ios/Contracts && rm -rf .build/*/debug/*.build 2>/dev/null; swift test --filter DrawingNodeGeometry 2>&1 | grep -E '✘|failed|Issue recorded' | head
```

Expected: **`offscreenAnchorNeverBecomesRealNode` 变红**（记录具体是哪条测试名；「有测试变红」不算数）。
另外 `proxyMarkSideAndDirection` 与 `threeOutcomesAreMutuallyExclusiveAndExhaustive` 也应变红。

```bash
cp /tmp/nodegeo.bak ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift   # ⛔ 不用 git checkout
cd ios/Contracts && swift test --filter DrawingNodeGeometry 2>&1 | tail -3   # 确认复原后全绿
```

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeGeometryTests.swift
git commit -m "P1c-2 Task2：节点登记表 + 三选一决策（工具无关，⛔ 真节点绝不 clamp）

T1 三态互斥穷尽（含三种都出现过的判别力自检）、T2 集合等式、T3 朝向、T4 no-clamp
守卫、N4 投影等价、N6 同进同退。变异验证：把 no-clamp 改成 clamp ⇒
offscreenAnchorNeverBecomesRealNode 变红。"
```

---

### Task 3: 节点命中（两层，D131）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift`（追加两个函数）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeGeometryTests.swift`（追加）

**Interfaces:**
- Consumes: `marks(for:mapper:isVisible:)`、`hitRadius`（Task 2）
- Produces:
  - 内层 `nearestNode(to:among:radius:) -> Int?`（收 `[(index: Int, at: CGPoint)]`，返回**原下标**）
  - 外层 `hitTestNode(point:drawing:mapper:isVisible:) -> Int?`
  - 第 3 片消费外层；⛔ 本片不接任何手势。

**两层的分工（D131 的第 ② 条结果要求）**：内层只做「最近距离选择」，不认识视口，因此可以**直接喂两个靠得很近的坐标** ⇒ 水平线只有 1 个锚点也能测 N7；外层负责**用与渲染共用的判据筛出可见真实节点**，T5 / T8 / T9 验的就是这一层。⛔ 内层测试不得冒充外层测试。

- [ ] **Step 1: 写失败测试**

追加到 `DrawingNodeGeometryTests.swift` 的 `}` 之前：

```swift
    /// T9 需要把锚点精确放在「出边框 N pt」处。indexToX(i) = i*candleStep + pixelShift，
    /// 故用 pixelShift 做亚格微调（candleStep=10 无法整除出 1pt 的偏移）。
    static func mapperShifted(_ pixelShift: CGFloat) -> CoordinateMapper {
        let main = CGRect(x: 0, y: 0, width: 800, height: 360)
        let vp = ChartViewport(
            startIndex: 0, visibleCount: 80, pixelShift: pixelShift,
            geometry: ChartGeometry(candleStep: 10, candleWidth: 7, gap: 3),
            priceRange: PriceRange(min: 10, max: 20), mainChartFrame: main)
        return CoordinateMapper(viewport: vp, displayScale: 2.0)
    }

    // MARK: - 内层（N7）

    @Test("N7：命中半径内 / 外各一档")
    func nearestNodeRespectsRadius() {
        let n = [(index: 0, at: CGPoint(x: 100, y: 100))]
        #expect(DrawingNodeGeometry.nearestNode(to: CGPoint(x: 110, y: 100), among: n, radius: 11) == 0,
                "距离 10 < 11 必须命中")
        #expect(DrawingNodeGeometry.nearestNode(to: CGPoint(x: 112, y: 100), among: n, radius: 11) == nil,
                "距离 12 > 11 必须不命中")
    }

    @Test("N7：两个靠得很近的节点 —— 取距离最近者（不依赖遍历顺序）")
    func nearestNodePicksClosest() {
        let n = [(index: 0, at: CGPoint(x: 100, y: 100)), (index: 1, at: CGPoint(x: 104, y: 100))]
        #expect(DrawingNodeGeometry.nearestNode(to: CGPoint(x: 101, y: 100), among: n, radius: 11) == 0)
        #expect(DrawingNodeGeometry.nearestNode(to: CGPoint(x: 103, y: 100), among: n, radius: 11) == 1)
        // 倒序喂同样的两个节点，答案必须不变 ⇒ 证明它不是靠数组顺序
        #expect(DrawingNodeGeometry.nearestNode(to: CGPoint(x: 101, y: 100),
                                                among: Array(n.reversed()), radius: 11) == 0)
    }

    @Test("N7：距离相等时取【原下标】较小者 —— 同时钉死返回的是原下标而非数组位置")
    func nearestNodeTieBreaksOnOriginalIndex() {
        // 故意让数组顺序与原下标相反：数组第 0 位的原下标是 7，第 1 位才是 3
        let n = [(index: 7, at: CGPoint(x: 100, y: 100)), (index: 3, at: CGPoint(x: 110, y: 100))]
        #expect(DrawingNodeGeometry.nearestNode(to: CGPoint(x: 105, y: 100), among: n, radius: 11) == 3,
                "距离都是 5 ⇒ 必须取原下标小的 3；若返回 7 说明按数组位置破的平局，若返回 0/1 说明返回的是数组位置")
    }

    // MARK: - 外层（T5 / T8 / T9）

    @Test("T5：可见真实节点附近，凡线命中的点节点也命中（前提限定为「可见真实节点」）")
    func visibleNodeCoversLineHitsNearby() {
        let m = Self.mapper()
        let d = Self.line(idx: 5)                      // x = 50，屏内
        let tool = HorizontalLineTool()
        #expect(tool.isVisible(drawing: d, mapper: m), "前提①：本例的线必须可见")
        guard case let .real(_, center) = DrawingNodeGeometry.marks(for: d, mapper: m, isVisible: true)[0] else {
            Issue.record("前提②：本例必须有可见真实节点"); return
        }
        var lineHits = 0
        for dx in stride(from: -8.0, through: 8.0, by: 2.0) {
            for dy in stride(from: -8.0, through: 8.0, by: 2.0) {
                guard dx*dx + dy*dy <= 64 else { continue }          // 半径 8 的圆盘（= 线容差）
                let p = CGPoint(x: center.x + dx, y: center.y + dy)
                guard tool.hitTest(point: p, mapper: m, drawing: d) else { continue }
                lineHits += 1
                #expect(DrawingNodeGeometry.hitTestNode(point: p, drawing: d, mapper: m, isVisible: true) == 0,
                        "线命中却节点不命中：p=\(p)")
            }
        }
        #expect(lineHits > 0, "⭐ 采样点里必须真的有线命中的，否则上面的蕴含式恒真")
    }

    @Test("T8：代理标记不参与命中 —— 同一条线把锚点移回屏内则有答案")
    func proxyMarkIsNotHittable() {
        let mOut = Self.mapperShifted(9)                 // idx=-1 → x = -10+9 = -1（出左缘 1pt）
        let d = Self.line(idx: -1)
        let probe = CGPoint(x: 0, y: mOut.priceToY(15))  // 正是代理标记所在处（贴左边框）
        #expect(DrawingNodeGeometry.hitTestNode(point: probe, drawing: d, mapper: mOut, isVisible: true) == nil,
                "代理标记处必须无答案")
        // 正向对照：同一条线、同一个探针点，把视口挪到让锚点恰好落在边框上 ⇒ 变成真节点 ⇒ 有答案
        let mIn = Self.mapperShifted(10)                 // idx=-1 → x = -10+10 = 0（恰在左边框上）
        #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: 0, y: mIn.priceToY(15)),
                                                drawing: d, mapper: mIn, isVisible: true) == 0,
                "⭐ 正向对照：锚点回到屏内必须有答案，否则上面那条只是因为函数恒返空")
    }

    @Test("⭐T9：锚点出左/右边缘 1/8/11pt 共 6 档，在代理标记处命中均为空（+ 边框上的正向对照）")
    func offscreenAnchorIsNeverHittableAtAnyDistance() {
        // 左侧：idx=-1 → x = -10 + shift。要 x = -1/-8/-11 ⇒ shift = 9/2/-1
        for (shift, expectedX) in [(9.0, -1.0), (2.0, -8.0), (-1.0, -11.0)] {
            let m = Self.mapperShifted(CGFloat(shift))
            let d = Self.line(idx: -1)
            #expect(m.indexToX(-1) == CGFloat(expectedX), "构造自检：锚点 x 必须真的是 \(expectedX)")
            #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: 0, y: m.priceToY(15)),
                                                    drawing: d, mapper: m, isVisible: true) == nil,
                    "左外 \(expectedX)pt：代理标记处必须无答案")
        }
        // 右侧：idx=80 → x = 800 + shift。要 x = 801/808/811 ⇒ shift = 1/8/11
        for (shift, expectedX) in [(1.0, 801.0), (8.0, 808.0), (11.0, 811.0)] {
            let m = Self.mapperShifted(CGFloat(shift))
            let d = Self.line(idx: 80)
            #expect(m.indexToX(80) == CGFloat(expectedX), "构造自检：锚点 x 必须真的是 \(expectedX)")
            #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: 800, y: m.priceToY(15)),
                                                    drawing: d, mapper: m, isVisible: true) == nil,
                    "右外 \(expectedX)pt：代理标记处必须无答案")
        }
        // ⭐ 正向对照（⛔ 不可省）：锚点恰好落在边框【上】= 未出屏 ⇒ 同一个探针点必须有答案。
        //    没有这一条，上面 6 档全空可能只是因为函数恒返空。
        let mL = Self.mapperShifted(10)                  // idx=-1 → x = 0（左边框上）
        #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: 0, y: mL.priceToY(15)),
                                                drawing: Self.line(idx: -1), mapper: mL, isVisible: true) == 0)
        let mR = Self.mapperShifted(0)                   // idx=80 → x = 800（右边框上）
        #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: 800, y: mR.priceToY(15)),
                                                drawing: Self.line(idx: 80), mapper: mR, isVisible: true) == 0)
    }

    @Test("外层：线不可见时一律无答案")
    func invisibleLineIsNotHittable() {
        let m = Self.mapper()
        let d = Self.line(idx: 5)
        #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: m.indexToX(5), y: m.priceToY(15)),
                                                drawing: d, mapper: m, isVisible: false) == nil)
        // 正向对照：同一个点、可见时有答案
        #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: m.indexToX(5), y: m.priceToY(15)),
                                                drawing: d, mapper: m, isVisible: true) == 0)
    }
```

- [ ] **Step 2: 跑测试，确认因函数不存在而编译失败**

```bash
cd ios/Contracts && swift test --filter DrawingNodeGeometry 2>&1 | tail -15
```

Expected: 编译错误 `type 'DrawingNodeGeometry' has no member 'nearestNode'`

- [ ] **Step 3: 写实现**

追加到 `DrawingNodeGeometry.swift` 的最后一个 `}` 之前：

```swift
    /// **内层**（纯）：在一组 `(原下标, 坐标)` 里找离 `point` 最近且在 `radius` 内的那个，返回**原下标**。
    /// 距离相等时取**原下标较小**者 —— ⛔ 不得依赖数组顺序 / 字典序（确定性由 N7 钉死）。
    /// 不认识视口，故可直接喂任意坐标 ⇒ 水平线只有 1 个锚点也测得了「两个节点靠得很近」（§8.3）。
    public static func nearestNode(to point: CGPoint,
                                   among nodes: [(index: Int, at: CGPoint)],
                                   radius: CGFloat) -> Int? {
        var best: (index: Int, d2: CGFloat)?
        for n in nodes {
            let dx = n.at.x - point.x, dy = n.at.y - point.y
            let d2 = dx * dx + dy * dy
            guard d2 <= radius * radius else { continue }
            if let b = best, !(d2 < b.d2 || (d2 == b.d2 && n.index < b.index)) { continue }
            best = (n.index, d2)
        }
        return best?.index
    }

    /// **外层**：先按**与渲染共用的判据**（`marks`）筛出可见真实节点，再交给内层。
    /// ⇒ **命中集合 ≡ 渲染集合**（D131）：出屏锚点与代理标记一律不可命中。
    /// 返回值是该锚点在 `drawing.anchors` 里的**原下标**（⛔ 不是筛选后数组的位置）。
    /// ⚠️ 本片只提供本函数，**不接任何手势**；第 3 片接拖动时必须自己定「先问节点还是先问线」（Q19）。
    public static func hitTestNode(point: CGPoint, drawing: DrawingObject,
                                   mapper: CoordinateMapper, isVisible: Bool) -> Int? {
        let visible: [(index: Int, at: CGPoint)] = marks(for: drawing, mapper: mapper, isVisible: isVisible)
            .compactMap { mark -> (index: Int, at: CGPoint)? in
                guard case let .real(i, p) = mark else { return nil }   // 代理标记不进命中集合
                return (index: i, at: p)
            }
        return nearestNode(to: point, among: visible, radius: hitRadius)
    }
```

- [ ] **Step 4: 跑测试，确认全部通过**

```bash
cd ios/Contracts && swift test --filter DrawingNodeGeometry 2>&1 | tail -12
```

Expected: 16 个测试全 PASS（Task 2 的 9 条 + 本任务 7 条）

- [ ] **Step 5: 变异验证 —— 证明 D131 的守卫真的守得住**

```bash
cp ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift /tmp/nodegeo2.bak
# 变异①：外层拿掉可见性筛选 —— 把代理标记也当成可命中的节点
perl -0pi -e 's/guard case let \.real\(i, p\) = mark else \{ return nil \}   \/\/ 代理标记不进命中集合/switch mark { case let .real(i, p): return (index: i, at: p); case let .proxy(i, p, _): return (index: i, at: p) }/' \
  ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift
cd ios/Contracts && swift test --filter DrawingNodeGeometry 2>&1 | grep -E '✘|Issue recorded' | head
```

Expected: **`proxyMarkIsNotHittable` 与 `offscreenAnchorIsNeverHittableAtAnyDistance` 双双变红**（逐条记下测试名）。

```bash
cp /tmp/nodegeo2.bak ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift
# 变异②：命中半径从 11 改成 5（< 线容差 8）
perl -pi -e 's/public static let hitRadius: CGFloat = 11/public static let hitRadius: CGFloat = 5/' \
  ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift
cd ios/Contracts && swift test --filter visibleNodeCoversLineHitsNearby 2>&1 | grep -E '✘|Issue recorded' | head
```

Expected: **`visibleNodeCoversLineHitsNearby` 变红**（覆盖不变量被破坏）。

```bash
cp /tmp/nodegeo2.bak ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift   # ⛔ 不用 git checkout
cd ios/Contracts && swift test --filter DrawingNodeGeometry 2>&1 | tail -3
```

- [ ] **Step 6: ⚠️ 如实登记一条本片做不了的变异**

变异「把内层返回值从**原下标**改成**筛后数组下标**」在本片**无法变红** —— 水平线只有 1 个锚点，筛前筛后下标恒为 0。
`nearestNodeTieBreaksOnOriginalIndex` 覆盖的是**内层**的破平局（喂的数组顺序与原下标相反），覆盖不到**外层**的筛选丢下标。
⛔ 不得声称本片测到了它。已交接 **spec §11-Q24**（第 4 片趋势线 2 锚时第一次具备构造条件）。

- [ ] **Step 7: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeGeometry.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeGeometryTests.swift
git commit -m "P1c-2 Task3：节点命中两层（D131 命中集合 ≡ 渲染集合）

内层只做最近距离选择（可直接喂坐标 ⇒ 单锚也测得了 N7 的多节点确定性）；
外层用与渲染共用的 marks 筛出可见真实节点。T5 覆盖不变量（含两重空真自检）、
T8/T9 出屏与代理标记一律不可命中（含边框上的正向对照）。
变异：拿掉可见性筛选 ⇒ T8+T9 双红；半径 11→5 ⇒ T5 红。
⚠️ 「返回原下标」在本片无变异可做（单锚），已交接 Q24。"
```

---

### Task 4: 节点与代理标记的绘制（零判断 + 裁剪）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeRenderer.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeRendererTests.swift`

**Interfaces:**
- Consumes: `DrawingNodeGeometry.NodeMark`、`visualDiameter`（Task 2）
- Produces: `DrawingNodeRenderer.draw(ctx:marks:scheme:clipTo:)`、`DrawingNodeRenderer.inkRGBA(scheme:)`；Task 5 接线消费。

**⚠️ 代理三角必须整个画在框内**：尖头**顶在边框上**、底边在**内侧**。若把尖头画到框外，D125 的裁剪会把尖削掉，屏幕上只剩半个三角（看起来像根竖条），方向感就没了。

- [ ] **Step 1: 写失败测试**

新建 `DrawingNodeRendererTests.swift`：

```swift
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("DrawingNodeRenderer")
struct DrawingNodeRendererTests {

    /// bitmap 特意比 mainChartFrame **高**（400 vs 360），这样「裁剪有没有生效」才看得出来 ——
    /// 若 bitmap 与 frame 等高，超出部分本来就写不进去，裁剪测试会恒真。
    static let W = 800, H = 400
    static let frame = CGRect(x: 0, y: 0, width: 800, height: 360)

    static func render(_ marks: [DrawingNodeGeometry.NodeMark],
                       scheme: AppColorScheme = .light) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: W * H * 4)
        let ctx = CGContext(data: &data, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        DrawingNodeRenderer.draw(ctx: ctx, marks: marks, scheme: scheme, clipTo: frame)
        return data
    }

    /// 某一列上不透明像素的个数（= 该列被画到的垂直厚度）。
    static func columnInk(_ data: [UInt8], x: Int) -> Int {
        (0..<H).reduce(0) { acc, y in acc + (data[(y * W + x) * 4 + 3] > 76 ? 1 : 0) }
    }

    /// 某像素的（反 premultiplied）颜色，alpha 太低则 nil。
    static func pixel(_ data: [UInt8], x: Int, y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let i = (y * W + x) * 4
        let a = CGFloat(data[i+3]) / 255
        guard a > 0.3 else { return nil }
        return (CGFloat(data[i])/255/a, CGFloat(data[i+1])/255/a, CGFloat(data[i+2])/255/a)
    }

    @Test("D107：真节点是纯黑实心圆（夜间纯白），直径 7pt")
    func realNodeIsInkFilledCircle() {
        let c = CGPoint(x: 400, y: 180)
        let light = Self.render([.real(index: 0, at: c)], scheme: .light)
        guard let p = Self.pixel(light, x: 400, y: 180) else {
            Issue.record("节点中心必须有像素 —— 否则下面的颜色断言恒真"); return
        }
        #expect(p.r < 0.1 && p.g < 0.1 && p.b < 0.1, "日间必须是纯黑，实得 \(p)")
        let dark = Self.render([.real(index: 0, at: c)], scheme: .dark)
        guard let q = Self.pixel(dark, x: 400, y: 180) else { Issue.record("夜间中心无像素"); return }
        #expect(q.r > 0.9 && q.g > 0.9 && q.b > 0.9, "夜间必须是纯白，实得 \(q)")
        // 直径：中心列的墨量应约等于 7（允许抗锯齿 ±2）
        let ink = Self.columnInk(light, x: 400)
        #expect(ink >= 5 && ink <= 9, "中心列墨量应接近直径 7pt，实得 \(ink)")
        // 离中心 10pt 处必须没有墨 ⇒ 证明它是个点，不是一整片
        #expect(Self.columnInk(light, x: 410) == 0, "离中心 10pt 处不该有墨")
    }

    @Test("⭐T3：代理三角的朝向可分辨 —— 左三角越往右越厚、右三角越往左越厚")
    func proxyTriangleDirectionIsDistinguishable() {
        let y = 180
        let left = Self.render([.proxy(index: 0, at: CGPoint(x: 0, y: CGFloat(y)), pointingLeft: true)])
        let nearTipL = Self.columnInk(left, x: 1), farL = Self.columnInk(left, x: 5)
        #expect(nearTipL > 0, "左三角必须真的画出来了")
        #expect(nearTipL < farL, "左三角尖头在左 ⇒ 越往右越厚（x1=\(nearTipL) x5=\(farL)）")

        let right = Self.render([.proxy(index: 0, at: CGPoint(x: 800, y: CGFloat(y)), pointingLeft: false)])
        let nearTipR = Self.columnInk(right, x: 798), farR = Self.columnInk(right, x: 794)
        #expect(nearTipR > 0, "右三角必须真的画出来了")
        #expect(nearTipR < farR, "右三角尖头在右 ⇒ 越往左越厚（x798=\(nearTipR) x794=\(farR)）")

        // ⭐ 左右互换守卫：把左三角的厚度走向拿去比右三角，必须不成立
        #expect(!(Self.columnInk(right, x: 794) < Self.columnInk(right, x: 798)),
                "若左右被互换实现，这条会成立 —— 说明朝向没真的被区分")
    }

    @Test("D125：节点被裁剪到主图框内（贴下沿时不溢出到副图区）")
    func nodeIsClippedToMainChartFrame() {
        // 圆心 y=358，半径 3.5 ⇒ 无裁剪会画到 361.5；frame.maxY = 360
        let data = Self.render([.real(index: 0, at: CGPoint(x: 400, y: 358))])
        #expect(Self.pixel(data, x: 400, y: 358) != nil, "前提：圆心处必须有墨（否则下面恒真）")
        for y in 361..<365 {
            #expect(Self.pixel(data, x: 400, y: y) == nil,
                    "y=\(y) 超出主图框 maxY=360，必须被裁掉 —— 否则会画到成交量面板上")
        }
    }

    @Test("空记号 → 一个像素都不画（接线层传空时的零开销路径）")
    func emptyMarksDrawNothing() {
        let data = Self.render([])
        #expect((0..<Self.W).allSatisfy { Self.columnInk(data, x: $0) == 0 })
    }
}
```

- [ ] **Step 2: 跑测试，确认因类型不存在而编译失败**

```bash
cd ios/Contracts && swift test --filter DrawingNodeRenderer 2>&1 | tail -15
```

Expected: 编译错误 `cannot find 'DrawingNodeRenderer' in scope`

- [ ] **Step 3: 写实现**

新建 `DrawingNodeRenderer.swift`：

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeRenderer.swift
// Spec: docs/superpowers/specs/2026-09-21-drawing-tools-P1c-2-nodes-design.md（D107 / D121 / D123 / D125）
//
// 选中态节点的**绘制层**：按 `DrawingNodeGeometry` 已经算好的记号机械绘制，**零判断**
// （画不画 / 画在哪 / 画真节点还是代理标记，全在决策层）。
// 跨平台：仅 CoreGraphics，无 UIKit → host swift test 可做像素级断言。

import CoreGraphics

@MainActor
public enum DrawingNodeRenderer {

    /// D107：节点色 = 自适应纯 ink（日纯黑 / 夜纯白），**无描边**。
    /// D123：代理标记**同色族** —— ⛔ 不跟线的 `colorToken` 走，它属于「选中记号」这一家。
    public static func inkRGBA(scheme: AppColorScheme) -> AppColorRGBA {
        scheme == .dark ? AppColorRGBA(white: 1) : AppColorRGBA(white: 0)
    }

    /// D125：**只把节点与代理标记裁剪到主图框**。
    /// ⛔ 调用方绝不能把线的绘制包进这道裁剪里 —— 线今天就是不裁剪的，给它加上会让贴边的线变细
    ///    （那是本片范围之外的行为改动，`selectionLeavesLinePixelsUntouched` 钉死）。
    public static func draw(ctx: CGContext, marks: [DrawingNodeGeometry.NodeMark],
                            scheme: AppColorScheme, clipTo frame: CGRect) {
        guard !marks.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: frame)
        let c = inkRGBA(scheme: scheme)
        ctx.setFillColor(CGColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green),
                                 blue: CGFloat(c.blue), alpha: CGFloat(c.alpha)))
        let d = DrawingNodeGeometry.visualDiameter
        for mark in marks {
            switch mark {
            case let .real(_, p):
                ctx.fillEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
            case let .proxy(_, p, pointingLeft):
                // 尖头**顶在边框上**（p 就是边框上那个点），底边在**内侧** —— 整个三角都在框内，
                // 裁剪只作用于 y 方向的溢出。⛔ 尖头不得画到框外，否则会被裁成一根竖条。
                let baseX = pointingLeft ? p.x + d : p.x - d
                ctx.beginPath()
                ctx.move(to: p)
                ctx.addLine(to: CGPoint(x: baseX, y: p.y - d / 2))
                ctx.addLine(to: CGPoint(x: baseX, y: p.y + d / 2))
                ctx.closePath()
                ctx.fillPath()
            }
        }
    }
}
```

- [ ] **Step 4: 跑测试，确认通过**

```bash
cd ios/Contracts && swift test --filter DrawingNodeRenderer 2>&1 | tail -10
```

Expected: 4 个测试全 PASS

- [ ] **Step 5: 变异验证**

```bash
cp ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeRenderer.swift /tmp/noderend.bak
# 变异①：左右朝向互换
perl -pi -e 's/let baseX = pointingLeft \? p\.x \+ d : p\.x - d/let baseX = pointingLeft ? p.x - d : p.x + d/' \
  ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeRenderer.swift
cd ios/Contracts && swift test --filter proxyTriangleDirectionIsDistinguishable 2>&1 | grep -E '✘|Issue' | head
```

Expected: **`proxyTriangleDirectionIsDistinguishable` 变红**。

```bash
cp /tmp/noderend.bak ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeRenderer.swift
# 变异②：拿掉裁剪
perl -pi -e 's/        ctx\.clip\(to: frame\)\n//' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeRenderer.swift
cd ios/Contracts && swift test --filter nodeIsClippedToMainChartFrame 2>&1 | grep -E '✘|Issue' | head
```

Expected: **`nodeIsClippedToMainChartFrame` 变红**。

```bash
cp /tmp/noderend.bak ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeRenderer.swift   # ⛔ 不用 git checkout
cd ios/Contracts && swift test --filter DrawingNodeRenderer 2>&1 | tail -3
```

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeRenderer.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeRendererTests.swift
git commit -m "P1c-2 Task4：节点与代理三角的绘制（零判断 + 裁剪到主图框）

纯黑/纯白实心圆无描边；代理三角尖头顶在边框上、底边在内侧（整个在框内，
不会被裁成竖条）。朝向用「厚度随 x 的走向」断言 ⇒ 左右互换会当场红。
裁剪测试用 400 高的 bitmap 对 360 高的 frame，否则恒真。
变异：朝向互换 ⇒ T3 红；拿掉裁剪 ⇒ 裁剪测试红。"
```

---

### Task 5: dispatch 接线（节点开始显示；**此时变蓝仍在**）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift:24-30`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewDrawingSessionTests.swift:264`（**在既有测试内追加断言，测试名不变**）

**Interfaces:**
- Consumes: `DrawingNodeGeometry.marks`、`DrawingNodeRenderer.draw`（Task 2/4）、`DrawingTool.isVisible`（Task 1）

**⚠️ 顺序是有意的**：先接线（节点出现）、Task 6 再取消变蓝。中间态是「既变蓝又有节点」——视觉冗余但**仍然可用**。反过来做会产生一段「变蓝已拿掉、节点还没有 ⇒ 选中一条线屏幕上完全无反馈」的中间态，正是上游 D108 落点明令要避免的。

**⚠️ 本任务新增 1 个 UIKit-gated 测试名**（下面的 N1）⇒ **Catalyst 基线本任务要加 1 行**。
⛔ spec §8.4 原写「基线改动只有一处」**不准确**，已在本 plan 的 Step 6 一并订正 spec。

- [ ] **Step 1: 在既有端到端测试里追加断言**

在 `ChartContainerViewDrawingSessionTests.swift` 的 `D41/D55 端到端…` 那条测试里，最后一个 `#expect(before != after, ...)` **之后**追加：

```swift
        // P1c 第 2 片 Task 5：选中的线必须**同时**画出节点。节点是自适应纯 ink（日黑 / 夜白），
        // 与线的 colorToken（本例是出厂橙）和选中蓝都可区分。
        // ⚠️ 不假设测试环境的 scheme（同上面那段注释），故两套 ink 都认。
        #expect(after.contains { px in
            (px.r < 0.12 && px.g < 0.12 && px.b < 0.12) || (px.r > 0.88 && px.g > 0.88 && px.b > 0.88)
        }, "选中后必须出现节点像素（纯黑或纯白实心圆）—— P1c 第 2 片")
        #expect(!before.contains { px in
            (px.r < 0.12 && px.g < 0.12 && px.b < 0.12) || (px.r > 0.88 && px.g > 0.88 && px.b > 0.88)
        }, "⭐ 未选中时不得有节点像素 —— 否则上面那条可能是被别的东西撞上的")
```

- [ ] **Step 1b: 补 N1 —— 两条同价位重合的线，只有被选中的那条画节点**

⚠️ 这一档**必须在 dispatch 层测**：`marks()` 根本不认识「谁被选中」，门控写在 dispatch 的
`if drawing.id == selectedDrawingID` 上。若实现错成「给所有线都画节点」，Step 1 的 before/after
对照**抓不到**（before 本来就没有选中项）。

追加到 `DrawDrawingsDispatchTests.swift` 的 `dispatchNoSelectionHighlightsNothing()` 之后：

```swift
    @Test("N1：两条同价位重合的线 —— 只有被选中的那条画节点（选中项在数组首/尾各验一次）")
    func onlySelectedLineDrawsNodes() {
        let mapper = makeMapperFixture()        // frame 320×200, candleStep 8, price 100...200, scale 1
        let yLine = Int(mapper.priceToY(150))   // 100
        let xA = Int(mapper.indexToX(10)), xB = Int(mapper.indexToX(30))   // 80 / 240
        // 同价位 ⇒ 两条线的 y 相同、视觉上完全重合；锚点落在不同 K 线上 ⇒ 节点 x 可分辨
        let a = DrawingObject(id: "A", toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m60, candleIndex: 10, price: 150)],
                              isExtended: false, panelPosition: 0)
        let b = DrawingObject(id: "B", toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m60, candleIndex: 30, price: 150)],
                              isExtended: false, panelPosition: 0)

        /// 渲染一次，返回「A 的锚点处 / B 的锚点处」是否有纯黑 ink（= 节点）。
        /// 线是出厂橙、节点是纯黑 ⇒ 用纯黑把节点从线里区分出来。
        func inkAt(selecting id: DrawingID) -> (atA: Bool, atB: Bool) {
            let w = 320, h = 200
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            makeViewFixture().drawDrawings(ctx: ctx, mapper: mapper, drawings: [a, b], period: .m60,
                                           scheme: .light, selectedDrawingID: id,
                                           tools: [.horizontal: HorizontalLineTool()])
            let snap = data                      // 先快照，避免与 CGContext 的 inout 访问重叠
            func isInk(_ x: Int) -> Bool {
                let i = (yLine * w + x) * 4
                let al = CGFloat(snap[i+3]) / 255
                guard al > 0.5 else { return false }
                return CGFloat(snap[i])/255/al < 0.12 && CGFloat(snap[i+1])/255/al < 0.12
                    && CGFloat(snap[i+2])/255/al < 0.12
            }
            return (isInk(xA), isInk(xB))
        }

        // ① 选中数组【首位】—— ⭐ 这一档是关键：若节点画在逐条循环内，
        //    后画的 B 的橙色描边会盖掉 A 节点的中心，本条当场红（codex plan-R1）
        let first = inkAt(selecting: "A")
        #expect(first.atA, "选中数组首位时它的节点必须仍在 —— 不得被后画的重合线盖掉")
        #expect(!first.atB, "未选中的 B 不得有节点 —— 哪怕它与 A 同价位、视觉上完全重合")
        // ② 选中数组【末位】—— 与 ① 对照：只测这一档抓不到覆盖问题
        let last = inkAt(selecting: "B")
        #expect(last.atB, "选中数组末位时必须有节点")
        #expect(!last.atA, "未选中的 A 不得有节点")
    }
```

**⚠️ 实施后必做的变异**：把第二遍的节点绘制**挪回循环内**（`tool.render` 之后）⇒
`onlySelectedLineDrawsNodes` 的 **① 选中首位**那一档必须变红、② 那一档仍绿。
若两档都绿，说明这条测试没真的测到叠加顺序。

- [ ] **Step 2: 跑 Catalyst，确认新断言失败（节点还没接线）**

```bash
DD=$(mktemp -d)
xcodebuild test -scheme KlineTrainer-Catalyst -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DD" -only-testing:KlineTrainerContractsTests 2>&1 | tail -30
```

Expected: `D41/D55 端到端…` FAIL，消息含「选中后必须出现节点像素」

- [ ] **Step 3: 接线**

**⛔⛔ 节点必须画成第二遍，不能插在逐条循环里**（codex plan-R1-medium，**已核实为真**）：

> 把节点插在循环内 `tool.render` 之后，则**后画的线会盖掉先画那条的节点**。实测构造：同价位的
> `[A, B]` 两条线、选中 A —— 先画 A 的线与黑节点，再画 B 的线；B 横贯全屏且 y 与 A 相同，
> 其橙色描边正好覆盖 A 节点的**中心**（节点直径 7pt、线宽 1.5pt）。
> ⚠️ **这不只是测试问题**：取消变蓝后节点是**唯一的图内选中反馈**，被盖住等于没有。

`KLineView+Drawing.swift` 的 `drawDrawings` 改成两遍。① 在 `for drawing in drawings {` **之前**插入：

```swift
        // P1c 第 2 片（D121）：选中态节点要**叠加在所有线与标签之上**，故先记下来、循环后再画。
        // ⛔ 不得画在循环内 —— 后画的重合线会盖掉它的中心（codex plan-R1 实证）。
        var selectedForNodes: (tool: any DrawingTool, drawing: DrawingObject)?
```

② 在循环内 `tool.render(...)` 调用**之后**插入一行（**只记录，不绘制**）：

```swift
            if drawing.id == selectedDrawingID { selectedForNodes = (tool, drawing) }
```

③ 在 `for` 循环的右花括号 `}` **之后**、函数结束之前，插入第二遍：

```swift
        // 第二遍：选中态的节点与代理标记，叠加在所有线与标签之上。
        // **工具无关** —— 决策全在 `DrawingNodeGeometry`，绘制全在 `DrawingNodeRenderer`，
        // 本层只负责问一次「这条线画不画得出来」并转发。
        // ⛔ 不得在此写死任何 `toolType`（那正是上面标签分支的问题，第 1 片交接为 Q10）。
        // D125：裁剪只作用于节点与代理标记 —— `DrawingNodeRenderer.draw` 内部自带
        // saveGState/clip/restoreGState，故循环里 `tool.render` 画的线**一点不受影响**。
        if let sel = selectedForNodes {
            let marks = DrawingNodeGeometry.marks(
                for: sel.drawing, mapper: mapper,
                isVisible: sel.tool.isVisible(drawing: sel.drawing, mapper: mapper))
            DrawingNodeRenderer.draw(ctx: ctx, marks: marks, scheme: scheme,
                                     clipTo: mapper.viewport.mainChartFrame)
        }
```

⚠️ 若 `drawings` 里出现重复 id（`injectDrawingsForTesting` 可造），循环会让**最后一条**胜出 —— 与数组序即 z-order 的既有约定一致（后画的在上）。

- [ ] **Step 4: 跑 Catalyst，确认通过**

```bash
DD=$(mktemp -d)
xcodebuild test -scheme KlineTrainer-Catalyst -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DD" -only-testing:KlineTrainerContractsTests 2>&1 | tail -15
```

Expected: 全绿。⚠️ 数编译错误**不得用** `grep -c 'error:'`（会把 macOS 的 XPC 噪音算进去），要用：
`grep -cE '^/.*\.swift:[0-9]+:[0-9]+: error:'`

- [ ] **Step 5: 跑 host 全量，确认没碰坏别的**

```bash
cd ios/Contracts && swift test 2>&1 | tail -3
```

- [ ] **Step 6: 同步 Catalyst 基线（新增 1 行）并订正 spec §8.4**

```bash
DD=$(mktemp -d)
xcodebuild test -scheme KlineTrainer-Catalyst -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DD" -only-testing:KlineTrainerContractsTests 2>&1 | tee /tmp/catalyst.log | tail -3
python3 .github/scripts/uikit-expected-tests.py > .github/scripts/catalyst-uikit-baseline.txt
git diff --stat .github/scripts/catalyst-uikit-baseline.txt     # 期望：+1 行（onlySelectedLineDrawsNodes 的测试名）
```

同时把 spec `§8.4` 那张表改成**两处改动**：第 29 行随 A7 改名（Task 6）**＋新增一行** N1
（`N1：两条同价位重合的线 —— 只有被选中的那条画节点`，Task 5）。⛔ 不得让 spec 继续写着「只有一处」。

- [ ] **Step 7: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewDrawingSessionTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift \
        .github/scripts/catalyst-uikit-baseline.txt \
        docs/superpowers/specs/2026-09-21-drawing-tools-P1c-2-nodes-design.md
git commit -m "P1c-2 Task5：dispatch 接线，选中态开始画节点（变蓝暂留）

工具无关：本层只问一次 isVisible 再转发，决策与绘制都在下层，⛔ 不写死 toolType。
在既有端到端测试内追加「选中出现节点像素 + 未选中不得有」的正负两档 ⇒
测试名不变，Catalyst 基线本次不动。
顺序有意：先让节点出现、下一个任务再取消变蓝，避免出现选中零反馈的中间态。"
```

---

### Task 6: 取消变蓝 + 翻转被推翻的 5 条测试 + Catalyst 基线

**Files:**
- Modify: `Drawing/DrawingColorResolver.swift:24-34`（删 `selectionRGBA`）
- Modify: `Drawing/HorizontalLineTool.swift:86-89`（去掉换色三目）
- Modify: `Drawing/DrawingTool.swift:18-22`（改 `isSelected` 头注）
- Modify: `Tests/.../Drawing/HorizontalLineToolTests.swift:287,303,326,341`（A3 翻转 / A4 翻转 / A5 删 / MARK 改名）
- Modify: `Tests/.../ThemePaletteTests.swift:84-90`（A6 删）
- Modify: `Tests/.../Render/ChartContainerViewDrawingSessionTests.swift:264,298`（A7 翻转 + 改名）
- Modify: `.github/scripts/catalyst-uikit-baseline.txt`（第 29 行）、`catalyst-total-baseline.txt`

**本任务整体 = spec §8.1-N3「被推翻的断言逐条翻转」。逐条对应 spec §7.1 的 A1–A7。⛔ 同节 B1–B12 那 12 处一律不动**（它们写着 D55 但测的是派发 / 时机 / 状态位，与颜色无关）。

- [ ] **Step 1: 翻转 host 侧的三条测试**

`HorizontalLineToolTests.swift`：

① `:287` 的 MARK 改为：`// MARK: - D108（P1c 第 2 片）选中态终局：取消变蓝`

② `:303` 整条 `selectedStrokeUsesSelectionColor` 替换为（A3 翻转，按上游 N2 必须断言**取到的是哪个颜色值**）：

```swift
    @MainActor
    @Test("D108/N2：变蓝真的没了 —— 选中与否，描边都是这条线自己的 colorToken 色")
    func selectionNeverChangesStrokeColor() {
        // ⚠️ 用 .red 而不是出厂默认 .orange：撞上出厂默认值就分不出「真的取了 colorToken」还是「碰巧」
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
                              isExtended: false, panelPosition: 0, colorToken: .red)
        let expRed = DrawingColorResolver.resolve(.red, scheme: .light)
        for selected in [false, true] {
            let px = Self.renderPixelsSelected(d, scheme: .light, isSelected: selected)
            let col = Self.litColumn(px.data, w: px.w, h: px.h)
            #expect(!col.isEmpty, "isSelected=\(selected) 时必须真的画出了线（否则下面的断言恒真）")
            #expect(col.contains { abs($0.r - CGFloat(expRed.red)) < 0.06
                                && abs($0.g - CGFloat(expRed.green)) < 0.06
                                && abs($0.b - CGFloat(expRed.blue)) < 0.06 },
                    "isSelected=\(selected) 时描边必须就是红色 \(expRed)，实得 \(col.first!)")
        }
    }
```

③ `:326` 整条 `selectionChangesColorOnly` 替换为（A4 翻转并收紧 = spec §8.2-T6）：

```swift
    @MainActor
    @Test("D108/T6：选中不改变线本身的任何像素 —— 两次渲染逐字节完全相同")
    func selectionLeavesLinePixelsUntouched() {
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
                              isExtended: false, panelPosition: 0,
                              lineStyle: .dash1, thickness: 4, colorToken: .red)
        let normal = Self.renderPixelsSelected(d, scheme: .light, isSelected: false)
        let picked = Self.renderPixelsSelected(d, scheme: .light, isSelected: true)
        #expect(!Self.litColumn(normal.data, w: normal.w, h: normal.h).isEmpty,
                "前提：必须真的画出了线，否则「两张空图相同」恒真")
        #expect(normal.data == picked.data,
                "选中不得改变线的任何像素（颜色 / 线宽 / dash / 几何 / 裁剪都不许动）")
        // 说明：节点由 dispatch 层的 DrawingNodeRenderer 画，不在 tool.render 内 ⇒ 这里应当逐字节相同。
    }
```

④ 删掉 `:341` 整条 `selectionColorIsOutsideTokenRange`（A5：选中色没了，无值域可占）。

- [ ] **Step 2: 删掉 `ThemePaletteTests.swift` 的 `selectionStrokeContrastWCAG`**（A6，`:83-90` 整条含 `@MainActor` 与 `@Test`）。
⚠️ 同文件 `:78-82` 的 `drawingStrokeContrastWCAG`（测画线描边色）**保留不动**。

- [ ] **Step 3: 跑 host，确认这三条因 `selectionRGBA` 还在而仍能编译、且新断言已通过**

```bash
cd ios/Contracts && swift test --filter 'HorizontalLineTool|ThemePalette' 2>&1 | tail -8
```

Expected: `selectionNeverChangesStrokeColor` **FAIL**（变蓝还在，选中时画的是蓝不是红）；`selectionLeavesLinePixelsUntouched` **FAIL**。

- [ ] **Step 4: 取消变蓝（生产改动）**

`HorizontalLineTool.swift` 把 `:86-89` 那段换成：

```swift
        // D108（P1c 第 2 片）：**取消「选中变蓝」**。选中反馈 = 节点（dispatch 层画）+ 底栏 🗑/🔒 变亮。
        // 理由：变蓝会盖掉用户自己给这条线设的颜色 —— 样式面板此刻正显示着「红色」让他改，屏幕上却是蓝的。
        // ⇒ 描边恒取这条线自己的 colorToken；`isSelected` 在本工具的渲染里**不再有任何作用**。
        let rgba = DrawingColorResolver.resolve(drawing.colorToken, scheme: scheme)
```

`DrawingColorResolver.swift` 删掉 `:24-34` 整个 `selectionRGBA`（含头注）。

`DrawingTool.swift` 的 `isSelected` 头注改为：

```swift
    /// `isSelected`（D55 引入，D108 改义）：该条是否处于选中态。**瞬时 UI 状态**，由渲染 dispatch 按
    /// `KLineRenderState.selectedDrawingID` 逐条派发，不来自 `DrawingObject` 任何持久化字段。
    /// ⚠️ **P1c 第 2 片起它不再表示「画成选中蓝」** —— 选中的视觉是**节点**（dispatch 层统一画，
    /// 见 `DrawingNodeGeometry` / `DrawingNodeRenderer`），各 tool 的 `render` 通常**不需要**用它。
    /// 参数保留是为了让将来确有需要的工具能拿到这一位；签名不变（D130）。
```

- [ ] **Step 5: 跑 host，确认翻转后的断言通过**

```bash
cd ios/Contracts && swift test 2>&1 | tail -4
```

Expected: 全绿。⚠️ 若报 `selectionRGBA` 未定义，说明还有引用没清干净：
`git grep -n 'selectionRGBA' -- 'ios/**/*.swift'` **必须返回空**。

- [ ] **Step 6: 翻转 Catalyst 端到端测试（A7）并改名**

`ChartContainerViewDrawingSessionTests.swift`：把 `:264` 的测试名与 `:293-299` 的选中蓝断言替换为：

```swift
    @Test("D41/D108 端到端：tap 命中 → 线仍是自己的颜色 + 画出节点（像素级，不只是状态位）")
```

并把那段 `let sels = [...]` 到 `}, "选中的线必须以选中色画出（D55）")` 整体替换为：

```swift
        // D108：线**不再变色** —— 选中前后都必须能找到它自己的 colorToken 色（本例出厂橙）。
        let expOrange = DrawingColorResolver.resolve(.orange, scheme: .light)
        let expOrangeDark = DrawingColorResolver.resolve(.orange, scheme: .dark)
        #expect(after.contains { px in
            [expOrange, expOrangeDark].contains { e in
                abs(px.r - CGFloat(e.red)) < 0.06 && abs(px.g - CGFloat(e.green)) < 0.06
                && abs(px.b - CGFloat(e.blue)) < 0.06 }
        }, "选中后线必须仍是它自己的颜色（D108 取消变蓝）")
```

Step 1 追加的两条节点断言**保持不变**（它们现在是这条测试的主断言）。
⚠️ `#expect(before != after, ...)` **保留** —— 选中前后画面仍然必须不同（现在的差异来自节点而不是线色）。

- [ ] **Step 7: 重新生成 Catalyst 基线（⛔ 不得手打测试名）**

```bash
DD=$(mktemp -d)
xcodebuild test -scheme KlineTrainer-Catalyst -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DD" -only-testing:KlineTrainerContractsTests 2>&1 | tee /tmp/catalyst.log | tail -5
python3 .github/scripts/uikit-expected-tests.py > .github/scripts/catalyst-uikit-baseline.txt
git diff --stat .github/scripts/catalyst-uikit-baseline.txt
```

Expected: 基线**只有 1 行内容变化**（第 29 行 A7 的测试名；N1 那一行已在 Task 5 加过）。⚠️ 若**行数**变了，说明又新增/丢失了 UIKit-gated 测试，必须查清原因再继续。

总数基线：从 `/tmp/catalyst.log` 读**实测**用例数写入 `catalyst-total-baseline.txt`，⛔ 不得估算。

- [ ] **Step 8: 跑闸门**

```bash
bash .github/scripts/catalyst-gate.sh /tmp/catalyst.log
```

Expected: 通过。⚠️ 「八进制转义」那条判据要问的是**转义有没有落在基线要逐条匹配的测试名上**，不是「有没有转义」。

- [ ] **Step 9: 变异验证**

```bash
cp ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift /tmp/hlt.bak
perl -pi -e 's/let rgba = DrawingColorResolver\.resolve\(drawing\.colorToken, scheme: scheme\)/let rgba = isSelected ? AppColorRGBA(red: 0, green: 0.478, blue: 1) : DrawingColorResolver.resolve(drawing.colorToken, scheme: scheme)/' \
  ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift
cd ios/Contracts && swift test --filter 'selectionNeverChangesStrokeColor|selectionLeavesLinePixelsUntouched' 2>&1 | grep -E '✘|Issue' | head
cp /tmp/hlt.bak ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift
```

Expected: **两条都变红**（逐条记测试名）。

- [ ] **Step 10: 提交**

```bash
git add -A ios/Contracts .github/scripts
git commit -m "P1c-2 Task6：取消「选中变蓝」，删 selectionRGBA，翻转被推翻的 5 条测试

D108 落地：描边恒取这条线自己的 colorToken；isSelected 在本工具渲染里不再有作用
（参数保留、签名不变）。selectionRGBA 是本片造成的孤儿，整个删除 ——
第 6 片若要「节点选中态」的强调色必须自己定义，⛔ 不得复活这条路（Q20）。

逐条对应 spec §7.1：A1 删函数 / A2 去三目 / A3 翻转（断言取到的是红色本身，
不是「不等于蓝」）/ A4 翻转并收紧为逐字节相同 / A5+A6 删 / A7 翻转并改名。
B1–B12 那 12 处写着 D55 但测派发、时机、状态位的，一处未动。
Catalyst 基线用 uikit-expected-tests.py 重新生成，实测只有 1 行变化。"
```

---

### Task 7: 验收清单 + 交互稿订正批注

**Files:**
- Create: `docs/superpowers/acceptance/2026-09-21-drawing-p1c-2-nodes.md`
- Modify: `docs/superpowers/mockups/2026-07-03-drawing-tools-expansion.html:2113`

- [ ] **Step 1: 落地验收清单**

把 spec `§9` 的 **30 条**（9.1–9.6 六组）逐条抄进新文件，**一条不删**，并在抄写时补三处真机执行细节：

1. 文件开头写明前置条件：
   - 真机部署需 Xcode 内**已登录** Apple 开发者账号（未登录报 `No profiles ... were found`，换终端无用，必须 GUI 登录）；
   - 个人开发者证书**仅 7 天有效**，过期后手机上 App 打不开，需重签重装；
   - 灌数据用 `KLINE_SEED_FIXTURE=1` 冷启动，且有「四样全空才执行」的守卫 ⇒ **判断是否真灌进去要看前后差分**（训练记录条数、训练组缓存目录），⛔ 不能只看「启动成功」。
2. 第 9 条（放大挤出锚点）补一句备选路径：「若双指放大不足以把锚点挤出左边，改用推进 K 线 —— 默认一屏 80 根，推满 80 根锚点必然出屏」。
3. 第 23 条（阻塞级那条）单独加粗提示：**若颜色跟着变了，立即停止验收并报回**。

**格式要求**（`.claude/workflow-rules.json`）：三栏 = 动作 / 预期 / 通过-不通过；中文；⛔ 禁用短语「验证通过即可」「看起来正常」「应该没问题」「should work」「looks fine」。

- [ ] **Step 2: 自查禁用短语**

```bash
grep -nE '验证通过即可|看起来正常|应该没问题|should work|looks fine' \
  docs/superpowers/acceptance/2026-09-21-drawing-p1c-2-nodes.md && echo "❌ 命中禁用短语" || echo "✅ 无禁用短语"
```

⚠️ 上面这条命令**自身**要先证明它报得出非空：把 `looks fine` 临时写进文件跑一次，确认它能命中，再删掉重跑。

- [ ] **Step 3: 核对条数**

```bash
echo "spec §9 条数：$(sed -n '/^## 9\. 非程序员验收清单/,/^## 10\./p' docs/superpowers/specs/2026-09-21-drawing-tools-P1c-2-nodes-design.md | grep -cE '^\| [0-9]+ \|')"
echo "验收文件条数：$(grep -cE '^\| [0-9]+ \|' docs/superpowers/acceptance/2026-09-21-drawing-p1c-2-nodes.md)"
```

Expected: 两个数**相等**（30）。不相等就是抄漏了。

- [ ] **Step 4: 给交互稿加订正批注**

在 `2026-07-03-drawing-tools-expansion.html:2113` 那条 caption 的 `</div>` **之前**追加：

```html
 <br><b style="color:#c00">【2026-09-21 订正】</b>本句两处已被推翻：①「线变蓝」被 <b>D108</b> 推翻（P1c 拆分补充 §D108 / 第 2 片 spec D127）——
 选中态<b>不再改变线的颜色</b>，选中 ⇔ 显示节点 + 底栏 🗑/🔒 变亮；②「带蓝色外圈」被 <b>D107</b> 推翻 ——
 节点是<b>纯黑实心圆（夜间纯白）、无描边</b>。⚠️ 本页 SVG 里的 <code>.anchorSel</code> 类（16 处）<b>仍画着蓝外圈，尚未重画</b>，
 照图实现会做出与 D107 不符的节点（第 2 片 spec §11-Q23）。
```

⛔ **不重画 SVG** —— 那是第 3–6 片陆续要用的图，重画属范围外（D128）。

- [ ] **Step 5: 确认批注真的落在那一条 caption 上**

```bash
sed -n '2113,2116p' docs/superpowers/mockups/2026-07-03-drawing-tools-expansion.html
grep -c '2026-09-21 订正' docs/superpowers/mockups/2026-07-03-drawing-tools-expansion.html
```

Expected: 第一条输出里能同时看到原句「命中判定后线变蓝」与新批注；第二条输出 `1`。

- [ ] **Step 6: 提交**

```bash
git add docs/superpowers/acceptance/2026-09-21-drawing-p1c-2-nodes.md \
        docs/superpowers/mockups/2026-07-03-drawing-tools-expansion.html
git commit -m "P1c-2 Task7：非程序员验收清单（30 条）+ 交互稿订正批注

验收清单含真机前置（Xcode 须 GUI 登录 / 证书 7 天有效 / 灌数据看前后差分）、
第 9 条的备选路径、第 23 条阻塞级提示。条数与 spec §9 逐条核对相等。
交互稿只在 caption 加批注指明 D107/D108 两处推翻，⛔ 不重画 SVG（D128）；
SVG 里 16 处蓝外圈仍在，已登记 Q23 让后续片自查。"
```

---

## 收尾（所有 Task 完成后）

- [ ] **三绿门**（作者亲核，clean build）
  1. host：`cd ios/Contracts && swift test` 全绿（起点 1833，本片净增由实测填写）
  2. Catalyst：**必须 `xcodebuild test` 真执行**（本片改了一条 UIKit-gated 测试），用 `mktemp -d` 的专属 `-derivedDataPath`；⛔ 绝不删全局 DerivedData（本仓 28 个 worktree）
  3. `bash .github/scripts/catalyst-gate.sh /tmp/catalyst.log` 通过
- [ ] **先跟上 main，最后再跑整支评审**（rebase / 新提交会让账本里按 head SHA 索引的条目失效）
- [ ] **整支对抗性评审**：`.claude/scripts/codex-attest.sh --scope branch-diff --head feat/drawing-p1c-2-nodes --base origin/main`
      ⛔ 不得传任何未知参数（含 `--help`）
- [ ] **push 与开 PR 由 user 在自己终端执行** —— 把命令落成**一行能跑的脚本**交给他（⛔ 超过一行的命令会被换行截断）
- [ ] **真机验收**：user 自跑 30 条清单 + 截图/输出贴 PR 评论

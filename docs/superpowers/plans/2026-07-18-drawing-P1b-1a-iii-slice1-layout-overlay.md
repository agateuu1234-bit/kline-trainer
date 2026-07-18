# 划线 1a-iii · 切片 1「布局不变量 + overlay 命中屏蔽」实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 逐 task 实施。步骤用 `- [ ]`。

**Goal:** 进画线后 K 线区域尺寸恒定——画线底栏与训练底栏等高、类型行改为**盖在 K 线上的 overlay**（不再挤压图表），且该 overlay 是**全 bounds 命中屏蔽**（点面板不在下方误落线）。

**Architecture:** 拆现有 `DrawingModeBar`（两行、VStack 成员、更高→顶起图表）为：①`DrawingBottomBar`（只①类型键，VStack 成员，**高度 == TradeActionBar**）；②类型行移到 `trainingContent` 的 `.overlay(alignment:.bottom)`（浮在下面板上、不占 VStack 高度）。命中屏蔽在**输入层**做（`handleDrawingTap` 拒绝落在 overlay frame 内的点），比只靠 SwiftUI 命中路由稳、且可单测。

**Tech Stack:** SwiftUI（`#if canImport(UIKit)`，host `swift test` 跳过 View、Catalyst/iOS 编译）；swift-testing；源码结构守卫。

## Global Constraints
- 契约不变：`CONTRACT_VERSION` "1.11"、无迁移、无新枚举值。
- 本切片**不动**：样式面板参数内容 / 上下镜像 / ⇅ / 图标化 / 颜色（属切片 2/3）；类型行本期仍只 1 水平线图标、恒亮无 toggle（D38）；②–⑤ 不渲染（D19/D24）。
- **不动引擎 `buy/sell`**、D45「下单即隐式退出画线」不变量；交易边界只 UI 层。
- 复盘仍浮动铅笔钮、无两行栏（`showsFloatingDrawingTool == review`）。
- overlay 引入与命中屏蔽守卫 + 测试**必须同 PR**（codex R5-high：禁 overlay-only 切片）。
- 既有 1a-i/1a-ii/1a-iii 初版测试全绿；不可见边射线 fail-closed（`handleDrawingTap` 的 `visibleGeometry!=nil`）保留。

---

## Task 1: 画线底栏与训练底栏等高（消除进画线的图表顶起）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingModeBar.swift`（拆出 `DrawingBottomBar`——只①类型键那一行）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift:217-233`（底栏 swap：drawing 分支用 `DrawingBottomBar`，不再整块塞两行 `DrawingModeBar`）
- **Modify（既有守卫，codex 计划-R3-medium 必改，否则红）**：`TrainingViewShellSourceGuardTests.swift:floatingRetiredBarWired`（`:40` 现 `#require(...range(of: "DrawingModeBar("))`）——改成 `#require(...range(of: "DrawingBottomBar("))`、断言仍在「`showsTradeButtons → isDrawingActive`」分支内；去掉对 `DrawingModeBar(` 的要求。
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/TrainingViewShellSourceGuardTests.swift`

**Interfaces:**
- Produces: `DrawingBottomBar(typeRowExpanded: Binding<Bool>)`——单行、`.frame(height: TradeActionBar 等高常量)`、含①类型键（`accessibilityLabel("类型")`、toggle `typeRowExpanded`）。
- Consumes（切片 2 用）：`typeRowExpanded` 仍是 TrainingView 的 `@State`。

- [ ] **Step 1: 写失败的源码守卫测试**（等高 + 底栏不再直接内嵌两行）

```swift
@Test("画线底栏改用单行 DrawingBottomBar、与训练底栏等高常量，不再在 VStack 直接塞两行 DrawingModeBar")
func drawingBottomBarIsHeightNeutralSingleRow() throws {
    let tv = try readSource("UI/TrainingView.swift")
    // 底栏 swap 分支用 DrawingBottomBar（单行）
    #expect(tv.contains("DrawingBottomBar("))
    // 不再把两行 DrawingModeBar 作为 VStack 成员塞进 trainingContent（改 overlay，见 Task 2）
    #expect(!tv.contains("DrawingModeBar(typeRowExpanded"))
    let bar = try readSource("UI/DrawingBottomBar.swift")
    // 与训练底栏共享等高常量（防更高顶起图表）
    #expect(bar.contains("DrawingBarMetrics.barHeight") || bar.contains(".frame(height:"))
}
```
（`readSource` = 既有测试 helper：读源文件、剥 `//` 注释后返回文本。若无则按 `TrainingViewShellSourceGuardTests` 既有方式读。）

- [ ] **Step 2: 运行 → 确认失败**（`DrawingBottomBar` 尚不存在）
Run: `cd ios/Contracts && swift test --filter drawingBottomBarIsHeightNeutralSingleRow`
Expected: FAIL（编译不过 / 断言不满足）

- [ ] **Step 3: 实现 `DrawingBottomBar` + 等高常量**

在 `DrawingModeBar.swift` 内新增（或新文件 `DrawingBottomBar.swift`）：
```swift
#if canImport(UIKit)
import SwiftUI

/// 训练/画线底栏共享高度常量（与 TradeActionBar 一致 → 进画线不顶图表）。
enum DrawingBarMetrics { static let barHeight: CGFloat = 52 }   // ← 用 TradeActionBar 实测高度替换

/// 画线底栏（单行）：只①类型键（收/展类型行 overlay）。②–⑤ 不渲染（D19/D24）。
struct DrawingBottomBar: View {
    @Binding var typeRowExpanded: Bool
    var body: some View {
        HStack(spacing: 12) {
            Button { typeRowExpanded.toggle() } label: {
                Image(systemName: "list.bullet").frame(width: 40, height: 32)
            }
            .accessibilityLabel("类型")
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: DrawingBarMetrics.barHeight)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }
}
#endif
```
> ⚠️ 实施须**实测 `TradeActionBar` 渲染高度**（含 padding），把 `barHeight` 设为与之相等；`DrawingBottomBar` 与 `TradeActionBar` 高度不等则本 task 失败（图表仍会跳）。

- [ ] **Step 4: TrainingView 底栏 swap 改用 DrawingBottomBar**

`TrainingView.swift:217-233` drawing 分支：
```swift
if isDrawingActive {
    DrawingBottomBar(typeRowExpanded: $typeRowExpanded)   // 单行、等高；类型行 overlay 见 Task 2
} else {
    TradeActionBar( ... 原样 ... )
}
```

- [ ] **Step 5: 运行守卫 + 既有壳测试全绿**
Run: `cd ios/Contracts && swift test --filter TrainingViewShellSourceGuard`
Expected: PASS

- [ ] **Step 6: Commit**
```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI ios/Contracts/Tests/KlineTrainerContractsTests/Render/TrainingViewShellSourceGuardTests.swift
git commit -m "划线1a-iii切片1 Task1：画线底栏改单行 DrawingBottomBar 等高，消除进画线图表顶起"
```

---

## Task 2: 类型行改 overlay（不占 VStack 高度）+ 命中屏蔽状态

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift`（类型行 overlay + hit-test 盾）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（`chartPanels` 容器上挂 `.overlay(alignment:.bottom)`；两 PreferenceKey 上报+转换清盾）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift`（`shieldRect`/`setShieldRect` + `deactivate()` 清盾）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift`（`handleDrawingTap` 拒绝落在面板局部 shield 内的点）
- **Delete（typeRow 已移 DrawingTypeOverlay、bottomRow 已移 DrawingBottomBar → 旧结构无引用）**：`DrawingModeBar.swift` 旧 `DrawingModeBar` struct + `DrawingModeBarSourceGuardTests.swift`（测的老两行结构已不存在，删之防 stale/红）。
- Test: `TrainingViewShellSourceGuardTests.swift` + 新 `DrawingTapHitShieldTests.swift`（含手填-setter 单测 + `#if canImport(UIKit)` 真路径 hosted 集成/生命周期测试）

**Interfaces:**
- Produces: `DrawingTypeOverlay(expanded: Bool, onLongPressType: ()->Void)`——仅 `expanded` 时渲染类型行（1 水平线图标恒亮）；根 `.contentShape(Rectangle())` + 吞点手势（第一道盾）。
- Produces: overlay frame 经 `PreferenceKey`（chart 坐标系）传到 ChartContainerView；`handleDrawingTap` 内 `guard !shieldRect.contains(point)`（第二道盾，可单测）。

- [ ] **Step 1: 写失败的命中屏蔽单测**（输入层拒绝面板内点）

```swift
// host-pure（直构 DrawingSession、无 UIKit 类型 → 跑于 host swift test）
@Test("模型不变量（codex 计划-R3）：DrawingSession.deactivate() 清空所有 shieldRect（退画线无残留盾）")
func deactivateClearsShields() throws {
    let session = DrawingSession()
    session.setShieldRect(CGRect(x: 0, y: 40, width: 390, height: 120), panel: .lower)
    session.deactivate()
    #expect(session.shieldRect.isEmpty)
}

#if canImport(UIKit)   // codex 计划-R5-high：以下触 ChartContainerView.Coordinator（UIKit-gated）→ **仅 Catalyst/iOS 跑**，不进 host swift test
@MainActor
@Test("点落在样式面板 shield 内 → 不落锚、不 commit（drawings.count 不变）——面板吃触摸不穿透")
func tapInsidePanelShieldDoesNotCommit() throws {
    let (view, engine) = makeDrawingActiveChart()          // 进画线态 ChartContainerView.Coordinator
    engine.drawingSession.setShieldRect(CGRect(x: 0, y: 40, width: 390, height: 120), panel: .lower)  // 面板局部坐标
    let before = engine.drawings.count
    view.handleDrawingTapForTesting(at: CGPoint(x: 100, y: 80))    // 面板内一点（面板局部）
    #expect(engine.drawings.count == before)               // 未落线
}
@MainActor
@Test("点落在面板 shield 外的 K 线区 → 正常落线（屏蔽只挡面板内）")
func tapOutsidePanelStillCommits() throws {
    let (view, engine) = makeDrawingActiveChart()
    engine.drawingSession.setShieldRect(CGRect(x: 0, y: 40, width: 390, height: 120), panel: .lower)
    let before = engine.drawings.count
    view.handleDrawingTapForTesting(at: CGPoint(x: 100, y: 200))   // 面板外、可见几何内一点
    #expect(engine.drawings.count == before + 1)
}
#endif

#if canImport(UIKit)
@MainActor
@Test("真路径差分（codex 计划-R6-high）：面板 shield 覆盖的、**本可落线**的点——装盾时被拒、清盾时落线；count 与 pendingAnchors 都验")
func shieldBlocksOtherwiseCommittingTap() throws {
    let (view, engine) = makeDrawingActiveChart()          // view.handleDrawingTap 读同一 engine.drawingSession
    // 展开真 overlay → 真 shield 装入（GeometryReader→onPreferenceChange→**转换**→setShieldRect 整链）
    hostAndFlush(TrainingShellLayout(engine: engine, isDrawingActive: true, typeRowExpanded: true))
    let shield = try #require(engine.drawingSession.shieldRect[1])
    let mainChart = view.renderState.viewport.mainChartFrame   // 下面板**可落线**区（成交量/MACD 区本就被既有守卫拒 → 必须排除）
    let p = CGPoint(x: shield.midX, y: shield.midY)
    try #require(mainChart.contains(p))                        // ⭐关键：采样点须落在「可落线区 ∩ shield」——否则 count 不变可能与 shield 无关（假绿）
    // ① 装盾 → 拒：count 与 pendingAnchors 均不变
    let c0 = engine.drawings.count, pend0 = engine.drawingSession.pendingAnchors.count
    view.handleDrawingTapForTesting(at: p)
    #expect(engine.drawings.count == c0)
    #expect(engine.drawingSession.pendingAnchors.count == pend0)
    // ② 收起清盾 → **同一点**落线：证明①的差别确由 shield 造成（非该点本就不可落 / 非死区）
    hostAndFlush(TrainingShellLayout(engine: engine, isDrawingActive: true, typeRowExpanded: false))
    #expect(engine.drawingSession.shieldRect[1] == nil)
    view.handleDrawingTapForTesting(at: p)
    #expect(engine.drawings.count == c0 + 1)
}
#endif
```
> `setShieldRect`/`shieldRect` 存 `DrawingSession`（单一真相），**面板局部坐标**、按 panel key；`handleDrawingTap` 读它。`deactivate()` 内 `shieldRect.removeAll()`（Step 3）。清盾由 nil-default preference + `.onChange`/`.onDisappear` + `deactivate()` 三重保证。**`shieldBlocksOtherwiseCommittingTap` 是本 task 达标判据**（差分 + 真路径 + 采样点强制落在可落线区）；手填坐标单测仅辅助逻辑、不算达标。`hostAndFlush` = host `UIHostingController` + `layoutIfNeeded` 刷 preference。

- [ ] **Step 2: 运行 → 失败（Catalyst，codex 计划-R6-medium：UIKit-gated 测试**不能**用 host `swift test` 红）**
Run: `xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:KlineTrainerContractsTests/DrawingTapHitShieldTests/shieldBlocksOtherwiseCommittingTap`
Expected: FAIL（`shieldRect` / 守卫 / 转换尚不存在）。**「no tests matched」/未编译 = 判失败**（测试没跑 = 没证据、非绿）。host `swift test` 只用于 `deactivateClearsShields`。

- [ ] **Step 3: DrawingSession 加 shieldRect（按 panel）**

`DrawingSession.swift`（**codex 计划-R4-high：文件现只 `import Observation`，加 `CGRect` 须补 `import CoreGraphics`**）：
```swift
import CoreGraphics   // ← 新增（CGRect）

public private(set) var shieldRect: [Int: CGRect] = [:]     // key 0=upper/1=lower → 面板**局部**坐标的 overlay frame（同 tap point 空间）
func setShieldRect(_ rect: CGRect?, panel: PanelId) {  // internal（同 setDefaultStyle 先例）
    let key = panel == .upper ? 0 : 1
    if let rect { shieldRect[key] = rect } else { shieldRect[key] = nil }
}
```
并在既有 `deactivate()`（`DrawingSession:62`，末尾 `drawingModeActive=false` 处）加 `shieldRect.removeAll()`（codex 计划-R3 模型不变量：退画线无残留盾）。

- [ ] **Step 4: handleDrawingTap 加屏蔽守卫**（`ChartContainerView.swift:271` 顶部、bounds 守卫后）

```swift
// codex R4/R5：样式面板 overlay 命中屏蔽——落在面板 frame 内的点不落锚（防误画+autosave）。
let shieldKey = panel == .upper ? 0 : 1
if let shield = session.shieldRect[shieldKey], shield.contains(point) { return }
```

- [ ] **Step 5: DrawingTypeOverlay + 挂在「仅图表面板」容器 + frame 上报（nil 默认 → 隐藏即清）**

`DrawingTypeOverlay.swift`（类型行内容 = 从旧 `DrawingModeBar.typeRow` 平移，含长按钩子）；根加 `.contentShape(Rectangle())` + `.onTapGesture {}`（吞点第一道盾）。

**codex 计划-R2-high**：overlay 必须挂在「**仅上下 K 线面板**」的容器、**不是整个 `trainingContent`**（否则 `.bottom` 对齐到含底栏的整栈底、盖住 `DrawingBottomBar`、遮住类型键）。抽出 `chartPanels`：
```swift
// 两个 PreferenceKey，值均 CGRect?、defaultValue = nil（隐藏即回 nil → 自动清盾）
struct DrawingShieldFrameKey: PreferenceKey { static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value } }
struct DrawingPanelFrameKey: PreferenceKey { static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value } }

@State private var lowerPanelChartFrame: CGRect?

private var chartPanels: some View {
    VStack(spacing: 0) {
        panel(.upper)
        Divider()
        panel(.lower)
            .background(GeometryReader { p in Color.clear
                .preference(key: DrawingPanelFrameKey.self, value: p.frame(in: .named("chart"))) })
    }
    .coordinateSpace(name: "chart")
    .overlay(alignment: .bottom) {
        // codex 计划-R4-medium：**必带 showsTradeButtons 门**——排除复盘（复盘用浮动铅笔钮、本切片不改其行为）。
        // 否则复盘经浮动钮 drawingModeActive 时也会挂 overlay+装下面板盾、吞复盘图表点。
        if showsTradeButtons, isDrawingActive, typeRowExpanded {
            DrawingTypeOverlay(expanded: typeRowExpanded, onLongPressType: { showingStyleCard = true })
                .background(GeometryReader { g in Color.clear
                    .preference(key: DrawingShieldFrameKey.self, value: g.frame(in: .named("chart"))) })
        }
    }
    .accessibilityIdentifier("chartPanels")
    .onPreferenceChange(DrawingPanelFrameKey.self) { lowerPanelChartFrame = $0 }
    .onPreferenceChange(DrawingShieldFrameKey.self) { overlayChartFrame in
        // codex 计划-R3-high：chart 空间 → 下面板局部空间转换（**不可**直接存 chart 空间，否则含上面板偏移、下面板漏挡）
        guard let overlay = overlayChartFrame, let lp = lowerPanelChartFrame else {
            engine.drawingSession.setShieldRect(nil, panel: .lower); return          // 隐藏/无帧 → 清盾
        }
        let local = overlay.offsetBy(dx: -lp.minX, dy: -lp.minY)                     // = handleDrawingTap 用的下面板局部坐标
        engine.drawingSession.setShieldRect(local, panel: .lower)
    }
}
```
canonical 空间 = **下面板局部**（与 tap point 同）。`handleDrawingTap` 直接 `shieldRect[1].contains(point)`，无需再转换。
`trainingContent` 用 `chartPanels` 取代原 `panel(.upper); Divider(); panel(.lower)` 三行。
- **`DrawingShieldFrameKey` 值 = `CGRect?`、`defaultValue = nil`**（codex 计划-R3-medium）：overlay 隐藏（收起 / 退画线 / view 消失）时无 descendant 设 preference → 值回落 nil → `onPreferenceChange` 收 nil → `setShieldRect(nil)` **自动清盾、无死区**。
- **额外显式清盾**（防御 + 明确生命周期）：`TrainingView` 加 `.onChange(of: engine.drawingSession.drawingModeActive)`、`.onChange(of: typeRowExpanded)`、`.onDisappear` → 三处都 `engine.drawingSession.setShieldRect(nil, panel: .lower)`（幂等，与 nil-preference 双保险）。
- **坐标系（codex 计划-R2-high，必对，否则下面板漏挡）**：tap point 是**目标面板局部**坐标；shield **必须存成同一面板局部空间**。overlay frame 经 GeometryReader 得的是「chart」空间（**含上面板偏移**）——须**减去该面板在「chart」空间的原点**转成面板局部再 `setShieldRect`。实现：`panel(.lower)` 也上报自身「chart」frame（`DrawingPanelFrameKey`）；报盾时 `shieldLocal = overlayFrame_chart.offsetBy(dx: -lowerPanelFrame_chart.minX, dy: -lowerPanelFrame_chart.minY)`。canonical 空间 = **目标面板局部**。
- **真路径 hosted 集成测试（codex 计划-R2-high，防 false-green）**：Step 1 那两个 unit 测试**手填坐标**、只验 `contains` 逻辑、**不算达标**。必须另加 `#if canImport(UIKit)` hosted 测试：渲染**真** `chartPanels` + 展开的真 overlay，捕获**真实** overlay frame 与面板 frame（经上述转换写入 `shieldRect`），再走**真** lower-panel `handleDrawingTap`——断言 overlay 内点被拒 / overlay 外点落线，证明 PreferenceKey→转换→handler **整条链**正确、非手填巧合。此测试为本 task 达标判据。

- [ ] **Step 6: 源码守卫——类型行在 overlay、不在 VStack 成员**
```swift
@Test("类型行改 overlay 挂载、命中屏蔽、且 overlay 带 showsTradeButtons 门（排除复盘）")
func typeRowIsShieldedOverlayNotVStackMember() throws {
    let tv = try readSource("UI/TrainingView.swift")
    #expect(tv.contains("DrawingTypeOverlay("))
    #expect(tv.contains(".overlay(alignment: .bottom)"))
    #expect(tv.contains("setShieldRect"))
    #expect(tv.contains("showsTradeButtons, isDrawingActive, typeRowExpanded"))   // 复盘门（codex 计划-R4）
    let ov = try readSource("UI/DrawingTypeOverlay.swift")
    #expect(ov.contains(".contentShape(Rectangle())"))
    let cc = try readSource("Render/ChartContainerView.swift")
    #expect(cc.contains("shieldRect") && cc.contains("shield.contains(point)"))
}

#if canImport(UIKit)
@MainActor
@Test("复盘负向（codex 计划-R4-medium）：复盘态（showsTradeButtons==false）即便 drawingModeActive，也**不装 overlay、不装盾**——复盘图表点不被吞")
func reviewModeInstallsNoOverlayNoShield() throws {
    let (view, engine) = makeReviewDrawingActiveChart()          // 复盘 + 浮动钮 drawingModeActive
    hostAndFlush(TrainingShellLayout(engine: engine, mode: .review, isDrawingActive: true, typeRowExpanded: true))
    #expect(engine.drawingSession.shieldRect.isEmpty)            // 复盘不装盾
    let before = engine.drawings.count
    view.handleDrawingTapForTesting(at: CGPoint(x: 100, y: 340)) // 复盘图表点正常（不被吞）
    #expect(engine.drawings.count == before + 1)
}
#endif
```
（`TrainingShellLayout` 加 `mode` 参数；复盘 = `showsTradeButtons==false`。复盘的画线仍走既有浮动钮路径、不受本切片影响。）

- [ ] **Step 6b: 迁移 D19/D24 结构守卫到拆分后的新文件（codex 计划-R5-medium，删旧守卫前必做）**
删 `DrawingModeBarSourceGuardTests` 前，把其「控件齐 / 无未接线键」断言迁到 `DrawingBottomBar`/`DrawingTypeOverlay`：
```swift
@Test("D19/D24：拆分后控件齐、无未接线键（迁自 DrawingModeBarSourceGuardTests）")
func splitBarsCarryD19D24() throws {
    let overlay = try readSource("UI/DrawingTypeOverlay.swift")
    let bottom  = try readSource("UI/DrawingBottomBar.swift")
    #expect(overlay.contains("accessibilityLabel(\"水平线\")"))   // 类型行水平线图标恒亮
    #expect(overlay.contains("onLongPressType"))                  // 长按接线（弹设置卡，Task5/切片2）
    #expect(bottom.contains("accessibilityLabel(\"类型\")"))       // ①类型键
    for banned in ["accessibilityLabel(\"锁定\")","accessibilityLabel(\"删除\")",
                   "accessibilityLabel(\"撤销\")","accessibilityLabel(\"前进\")"] {   // ②–⑤ 不渲染
        #expect(!overlay.contains(banned)); #expect(!bottom.contains(banned))
    }
}
```
迁移测试**通过后**再删 `DrawingModeBarSourceGuardTests.swift` + 旧 `DrawingModeBar` struct（Files 的 Delete），确保 D19/D24 全程有守卫覆盖、无空窗。

- [ ] **Step 7: 运行三绿等价（host 纯逻辑/守卫 + Catalyst 触-UIKit hosted 测试）**
Run（host：纯逻辑 + 源码守卫，**无 UIKit 类型**）：`cd ios/Contracts && swift test --filter "deactivateClearsShields|SourceGuard"`
Run（**Catalyst：所有触 ChartContainerView/UIHostingController 的测试——达标判据**）：`xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:KlineTrainerContractsTests/DrawingTapHitShieldTests`（`tapInside/tapOutside` + PreferenceKey→转换→handler 整链 + `shieldLifecycleThroughProductionView` + `reviewModeInstallsNoOverlayNoShield`）
然后全量 host `swift test` + Catalyst gate。
Expected: PASS（既有全绿；手填坐标单测不算达标、Catalyst hosted 真路径才算）

- [ ] **Step 8: Commit**
```bash
git add ios/Contracts/Sources ios/Contracts/Tests
git commit -m "划线1a-iii切片1 Task2：类型行改 overlay(不占图表高度)+双层命中屏蔽(contentShape+输入层 shieldRect 拒点)"
```

---

## Task 3: 布局不变量——**阻塞式 hosted-UIKit 几何断言**（codex 计划-R1-high，非源码守卫兜底）

**Files:**
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingLayoutInvariantTests.swift`（`#if canImport(UIKit)`，随 UIKit-gated 测试跑于 Catalyst/iOS）
- Modify: `TrainingView.swift`——给 `chartPanels` 容器加 `.accessibilityIdentifier("chartPanels")`；抽一个**可宿主的布局壳** `TrainingShellLayout`（注入 `isDrawingActive`/`typeRowExpanded` + stub 上下面板占位），使几何可在 host 里驱动三态。

**判据（阻塞，进三绿门）**：K 线容器 frame 在 {训练态、画线-收起、画线-展开} 三态**逐像素相等**。用 `UIHostingController` 真布局测量，**不得**用源码守卫替代（源码守卫作为**补充**快检保留，但不算达标）。

- [ ] **Step 1: 写失败的 hosted 几何测试**
```swift
#if canImport(UIKit)
import UIKit
@MainActor
@Test("进画线 / 展开 / 收起——chartPanels 容器 frame 逐像素不变（布局不变量，阻塞）")
func chartFrameIdenticalAcrossDrawingStates() throws {
    func chartFrame(isDrawing: Bool, expanded: Bool) throws -> CGRect {
        let root = TrainingShellLayout(isDrawingActive: isDrawing, typeRowExpanded: expanded)
        let host = UIHostingController(rootView: root)
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)   // 固定视口
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        let chart = try #require(findView(id: "chartPanels", in: host.view))
        return chart.convert(chart.bounds, to: host.view)
    }
    let training = try chartFrame(isDrawing: false, expanded: false)
    let collapsed = try chartFrame(isDrawing: true,  expanded: false)
    let expanded  = try chartFrame(isDrawing: true,  expanded: true)
    #expect(collapsed == training)     // 进画线不改图表尺寸
    #expect(expanded  == training)     // 展开类型行不改图表尺寸（overlay 不 reflow）
    // codex 计划-R2-medium：两底栏实测高度直接相等（真 TradeActionBar intrinsic vs 真 DrawingBottomBar）
    func barHeight(id: String, isDrawing: Bool) throws -> CGFloat {
        let host = UIHostingController(rootView: TrainingShellLayout(isDrawingActive: isDrawing, typeRowExpanded: false))
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        return try #require(findView(id: id, in: host.view)).bounds.height
    }
    #expect(try barHeight(id: "tradeActionBar", isDrawing: false)
            == (try barHeight(id: "drawingBottomBar", isDrawing: true)))
}
#endif
```
`findView(id:in:)` = 遍历 UIView 树按 `accessibilityIdentifier` 找（测试 helper，若无则本 task 加）。

- [ ] **Step 2: 运行 → 失败**（`TrainingShellLayout` 未建 / 三态 frame 不等——正是当前 bug）
Run（Catalyst）：`xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:KlineTrainerContractsTests/DrawingLayoutInvariantTests`
Expected: FAIL

- [ ] **Step 3: 实现 `TrainingShellLayout` 布局壳（用**真** bar、只 stub 图表渲染）+ id**
`TrainingShellLayout` 必须用**生产真组件**：真 `topBar`、真 `TradeActionBar`、真 `DrawingBottomBar`，**只把 K 线渲染（KLineView，需 engine）换成等尺寸占位**（codex 计划-R2-medium：stub 掉 bar 会让测试对着假布局绿、放过真实 `TradeActionBar` intrinsic 高度 ≠ `DrawingBottomBar` 引起的图表跳）。与生产 `trainingContent` **共用同一 `chartPanels` + 底栏 swap 逻辑**（抽共享、不复制）。`chartPanels` 加 `.accessibilityIdentifier("chartPanels")`；`TradeActionBar`/`DrawingBottomBar` 各加 id 供测量。
- **统一签名（所有 hosted 测试一致用）**：`TrainingShellLayout(engine: TrainingEngine, mode: FlowMode = .training, isDrawingActive: Bool, typeRowExpanded: Bool)`。测试用共享 `makeTestEngine()` 建最小 engine（本文各 hosted 片段里省略 `engine:`/`mode:` 处均按此签名补全）。`mode: .review` ⇒ `showsTradeButtons==false`（驱动复盘负向测试）。

- [ ] **Step 4: 运行 → 通过**（三态 frame 相等）
Run（同 Step 2）
Expected: PASS

- [ ] **Step 5: 补充源码守卫（快检，非达标判据）**
```swift
@Test("补充快检：类型行只经 overlay、图表面板不在 typeRowExpanded 分支内")
func chartNotInExpandedBranch_sourceGuard() throws {
    let tv = try readSource("UI/TrainingView.swift")
    #expect(tv.contains("DrawingTypeOverlay(") && tv.contains(".accessibilityIdentifier(\"chartPanels\")"))
}
```

- [ ] **Step 6: Commit**
```bash
git add ios/Contracts/Sources ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingLayoutInvariantTests.swift
git commit -m "划线1a-iii切片1 Task3：阻塞式 hosted-UIKit 几何断言(三态 chartPanels frame 逐像素相等)+补充源码快检"
```

> **实施注意**：hosted 几何测试须**确定性**（固定视口 + `layoutIfNeeded` 后测量）。若在 harness 里证实**根本无法**稳定测量（非"麻烦"而是"不可能"），这是**阻塞级 escalation**——回报 controller、由 codex/ user 裁决，**不得**私自降级回源码守卫（这正是 codex 计划-R1 red 的点）。

---

## 三绿门（切片 1 收尾，作者亲跑）
1. `cd ios/Contracts && swift test`（host 全绿）
2. `bash .claude/scripts/catalyst-gate.test.sh`（自测）
3. Catalyst `xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:KlineTrainerContractsTests` + `catalyst-gate.sh <log>`（GATE PASS）
4. iOS Simulator `xcodebuild build ...`（BUILD SUCCEEDED）

## Self-Review（写完自查）
- **spec 覆盖**：§2.4 底栏等高✓(T1) / overlay 挂 chartPanels 不 reflow✓(T2) / 双层命中屏蔽 + 清盾生命周期✓(T2) / 可验证性✓(T3，**阻塞式 hosted 几何断言**) / §8 切片1 shield 同 PR✓。
- **占位扫描**：`barHeight=52` 是**占位数**——实施须实测替换（Step3 已标 ⚠️）；`readSource` helper 名以既有测试文件为准。
- **类型一致**：`setShieldRect(_:panel:)` / `shieldRect[key]` / `DrawingBarMetrics.barHeight` 跨 task 一致。
- **不做项**：参数面板/镜像/⇅/图标/颜色不在本切片（切片 2/3）。

## Execution Handoff
计划存 `docs/superpowers/plans/2026-07-18-drawing-P1b-1a-iii-slice1-layout-overlay.md`。下一步：**codex 对抗评审本计划到收敛** → subagent-driven-development 逐 task 实施。

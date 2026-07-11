# P1b-1a-i「渲染层正确性」实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让划线的样式（颜色 / 线型 / 粗细 / 线型子类 / 标注）真正抵达渲染层并被正确绘制，并把渲染过滤判据从 `panelPosition` 改为 `period`（D29），除此之外用户可见行为不变。

**Architecture:** 三步——① 把 `DrawingTool.render/hitTest` 的签名从「只收 anchors」迁移到「收整个 `DrawingObject` + 主题」（D35），让样式能进渲染层；② 让 `HorizontalLineTool` 消费这些样式（颜色解析纯函数 + 线宽 / 线型 / 几何子类）；③ 把 `RenderStateBuilder` 的面板过滤判据改为按 `period`，并加 `upper==lower` fail-safe（D29）。价格标注文字由 dispatch 层（`KLineView+Drawing.swift`，已在 UIKit guard 内）绘制，`DrawingTool` 保持纯 CoreGraphics 跨平台；标注位置计算是 host 可测纯函数。

**Tech Stack:** Swift 6 / CoreGraphics / SwiftUI（`KlineTrainerContracts` SPM 模块）；Swift Testing（`@Test`/`#expect`）；Mac Catalyst `build-for-testing` 门。

## Global Constraints

- **视觉零变化是硬约束（安全网）**：用**默认样式**（`thickness=1 / colorToken=.orange / lineStyle=.solid / labelMode=.hidden / lineSubType=.straight`，见 `Models.swift:258-266`）构造的 `DrawingObject`，在**昼 / 夜两套主题**下渲染出的描边色与线宽**必须都等于迁移前常量**：橙色 `AppColorRGBA(0.82, 0.40, 0.0)`、`1.5pt`、全宽横线、无标注。
- **`.orange` 默认色主题无关**：昼夜都解析为 legacy `(0.82, 0.40, 0.0)`。7 个彩色 token（红橙黄绿青蓝紫）全部主题无关；只有 `.black`/`.white` 主题相关。
- **不留兼容 shim、不留旧签名重载**（D28）：D35 改签名时，所有 conformer / mock / 测试替身在**同一 PR** 内更新，靠 Swift 编译器强制。
- **纯函数 host 可测**：颜色解析、几何 helper、标注位置计算必须是**非 `View`、非 `@MainActor` 隔离**的纯函数（可在 host `swift test` 里跑，不依赖 UIKit 渲染上下文）。
- **契约不 bump**：`CONTRACT_VERSION` 保持 `1.11`、`user_version` 保持 `7`、零迁移（本 PR 只写入 `.horizontal`，不碰持久层）。
- **D43（user 决策）**：legacy `style_json IS NULL` + `is_extended=1` 的行经 `lineSubType = isExtended ? .ray : .straight` 派生为 `.ray`，渲染为**射线**——**不做外观兼容、不改 `legacyFallback`**。
- **三绿门（作者亲核，clean build）**：host `swift test` 全绿 + Mac Catalyst `build-for-testing` SUCCEEDED + iOS build。

---

### Task 1: D35 `DrawingTool` 渲染 / 命中 API 迁移（全链先决）

把 `render/hitTest` 的签名从 `anchors: [DrawingAnchor]` 改为收整个 `DrawingObject` + 主题 `AppColorScheme`，让样式字段能抵达渲染层。本 task **不改任何渲染逻辑**——`HorizontalLineTool` 过渡实现只是把 `drawing.anchors` 从新入参里取出来，行为与今天逐字节相同（视觉零变化）。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift:18-19`（protocol 两个方法签名）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift:31,44`（过渡实现，签名对齐、逻辑不变）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift:16-26`（dispatch loop 传 drawing + scheme）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift:106-107`（caller 传当前 scheme）
- Modify（测试替身，同 PR 强制更新，D28）:
  - `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingProtocolTests.swift`（`FakeDrawingTool`）
  - `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/SpecLiteralGuardTests.swift`（`SignatureGuardTool`）
  - `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift`（`SpyDrawingTool` + `view.drawDrawings(...)` 调用点）
  - `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/HorizontalLineToolTests.swift`（`.render/.hitTest` 直调）

**Interfaces:**
- Produces（后续所有 task 依赖）：
  ```swift
  // DrawingTool.swift
  func render(ctx: CGContext, mapper: CoordinateMapper, drawing: DrawingObject, scheme: AppColorScheme)
  func hitTest(point: CGPoint, mapper: CoordinateMapper, drawing: DrawingObject) -> Bool
  ```
  （`AppColorScheme` 定义在 `Theme/Theme.swift:9-12`：`case light; case dark`。传 `drawing` 而非 `anchors`，因为 tool 要读 `colorToken/lineStyle/thickness/lineSubType`；`hitTest` 需 `lineSubType` 判方向，故也收整个 drawing。）
- Consumes：`DrawingObject`（`Models.swift:236-266`）、`AppColorScheme`。

- [ ] **Step 1: 改 dispatch 举证测试（先失败）** —— 把 `DrawDrawingsDispatchTests.swift` 的 `SpyDrawingTool` 与调用点改成新签名，并新增一条「样式抵达」断言：

```swift
// DrawDrawingsDispatchTests.swift —— SpyDrawingTool 改签名 + 记录【每一次】render 调用（codex plan-medium：
// 只记 lastDrawing 会让「所有 dispatch 复用第一条」的错误实现蒙混过关）
final class SpyDrawingTool: DrawingTool {
    static var type: DrawingToolType { .horizontal }
    var requiredAnchors: ClosedRange<Int> { 1...1 }
    private(set) var received: [(drawing: DrawingObject, scheme: AppColorScheme)] = []
    func render(ctx: CGContext, mapper: CoordinateMapper, drawing: DrawingObject, scheme: AppColorScheme) {
        received.append((drawing, scheme))
    }
    func hitTest(point: CGPoint, mapper: CoordinateMapper, drawing: DrawingObject) -> Bool { false }
}

@Test("D35：两条不同样式的 drawing 各自带自己的样式 + scheme 按顺序抵达渲染层")
func drawDrawingsPassesEachDrawingDistinctly() {
    let view = makeViewFixture()
    let spy = SpyDrawingTool()
    let d1 = DrawingObject(toolType: .horizontal,
        anchors: [DrawingAnchor(period: .m60, candleIndex: 5, price: 120)],
        isExtended: false, panelPosition: 0, colorToken: .blue, thickness: 4)
    let d2 = DrawingObject(toolType: .horizontal,
        anchors: [DrawingAnchor(period: .m60, candleIndex: 9, price: 130)],
        isExtended: false, panelPosition: 0, colorToken: .red, thickness: 2)
    view.drawDrawings(ctx: makeCtxFixture(), mapper: makeMapperFixture(),
        drawings: [d1, d2], period: .m60, scheme: .dark, tools: [.horizontal: spy])
    #expect(spy.received.count == 2)
    // 逐条样式各不相同（防「复用第一条 / 样式串味」）
    #expect(spy.received[0].drawing.colorToken == .blue && spy.received[0].drawing.thickness == 4)
    #expect(spy.received[1].drawing.colorToken == .red && spy.received[1].drawing.thickness == 2)
    #expect(spy.received[0].drawing.id != spy.received[1].drawing.id)   // 顺序/身份不被混淆
    #expect(spy.received.allSatisfy { $0.scheme == .dark })
}
```

- [ ] **Step 2: 跑测试确认失败** — Run: `swift test --filter DrawDrawingsDispatch`；Expected: 编译失败（旧签名/新参数不匹配）。

- [ ] **Step 3: 改 protocol 签名**

```swift
// DrawingTool.swift:18-19
func render(ctx: CGContext, mapper: CoordinateMapper, drawing: DrawingObject, scheme: AppColorScheme)
func hitTest(point: CGPoint, mapper: CoordinateMapper, drawing: DrawingObject) -> Bool
```
（`DrawingTool.swift` 需 `import` 到 `AppColorScheme`/`DrawingObject` 所在模块——同模块内无需额外 import，`AppColorScheme` 在 `Theme.swift`、`DrawingObject` 在 `Models.swift`，均 `KlineTrainerContracts` 内。）

- [ ] **Step 4: 改 dispatch loop**

```swift
// KLineView+Drawing.swift:16-26
func drawDrawings(ctx: CGContext,
                  mapper: CoordinateMapper,
                  drawings: [DrawingObject],
                  period: Period,
                  scheme: AppColorScheme,
                  tools: [DrawingToolType: any DrawingTool]) {
    _ = period  // reserved（周期过滤在 RenderStateBuilder，见 Task 6；此处仍不消费）
    for drawing in drawings {
        guard let tool = tools[drawing.toolType] else { continue }
        tool.render(ctx: ctx, mapper: mapper, drawing: drawing, scheme: scheme)
    }
}
```

- [ ] **Step 5: 改 caller 传 scheme**

```swift
// KLineView.swift:106-107（scheme 来自本 view 的 themeController，见 :36/:39）
drawDrawings(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
             period: renderState.panel.period,
             scheme: themeController.resolve(trait: traitCollection),
             tools: Self.drawingTools)
```

- [ ] **Step 6: `HorizontalLineTool` 过渡实现（签名对齐、逻辑逐字不变）**

```swift
// HorizontalLineTool.swift —— 只改签名，从 drawing.anchors 取锚；颜色/线宽/几何仍是今天的写死值
public func render(ctx: CGContext, mapper: CoordinateMapper, drawing: DrawingObject, scheme: AppColorScheme) {
    guard let y = lineY(anchors: drawing.anchors, mapper: mapper) else { return }
    let frame = mapper.viewport.mainChartFrame
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(srgbRed: CGFloat(Self.strokeRGBA.red), green: CGFloat(Self.strokeRGBA.green),
                               blue: CGFloat(Self.strokeRGBA.blue), alpha: CGFloat(Self.strokeRGBA.alpha)))
    ctx.setLineWidth(1.5)
    ctx.move(to: CGPoint(x: frame.minX, y: y))
    ctx.addLine(to: CGPoint(x: frame.maxX, y: y))
    ctx.strokePath()
    ctx.restoreGState()
}
public func hitTest(point: CGPoint, mapper: CoordinateMapper, drawing: DrawingObject) -> Bool {
    guard let y = lineY(anchors: drawing.anchors, mapper: mapper) else { return false }
    return abs(point.y - y) <= Self.hitTolerance
}
```

- [ ] **Step 7: 改其余 3 个测试替身 + 直调点** — `FakeDrawingTool`（`DrawingProtocolTests.swift`）、`SignatureGuardTool`（`SpecLiteralGuardTests.swift`）改签名；`HorizontalLineToolTests.swift` 的 `.render(...)`/`.hitTest(...)` 直调改为传 `drawing:` + `scheme:`（构造 `DrawingObject(toolType:.horizontal, anchors:[...], isExtended:false, panelPosition:0)` 传入）。

- [ ] **Step 8: 跑测试确认通过** — Run: `swift test --filter Drawing`；Expected: 全绿（含 Step 1 的样式抵达断言）。

- [ ] **Step 9: Commit**
```bash
git add -A && git commit -m "feat(drawing): D35 DrawingTool render/hitTest 签名迁移到 DrawingObject+scheme（1a-i Task1，逻辑零变化）"
```

---

### Task 2: `DrawingColorToken` 主题解析纯函数（D36）

新建一个 host 可测的纯函数，把 9 个 `DrawingColorToken` 解析成 `AppColorRGBA`。7 个彩色主题无关；`.black`/`.white` 主题相关（避免与背景同色不可读）。**仓库里不存在**这个映射（既有 `AppColorTokens`/`UIChartPalette` 服务的是蜡烛/MA/MACD 的 13-token 体系，语义不重叠，不得复用）。

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingColorResolver.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingColorResolverTests.swift`

**Interfaces:**
- Produces（Task 3 依赖）：`DrawingColorResolver.resolve(_ token: DrawingColorToken, scheme: AppColorScheme) -> AppColorRGBA`
- Consumes：`DrawingColorToken`（`DrawingEnums.swift`）、`AppColorScheme`、`AppColorRGBA`（`Theme.swift:26`）。

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import KlineTrainerContracts

@Suite("DrawingColorResolver")
struct DrawingColorResolverTests {
    @Test("默认橙昼夜都是 legacy (0.82,0.40,0.0)——视觉零变化锚")
    func orangeIsLegacyBothSchemes() {
        for s in [AppColorScheme.light, .dark] {
            let c = DrawingColorResolver.resolve(.orange, scheme: s)
            #expect(c.red == 0.82 && c.green == 0.40 && c.blue == 0.0)
        }
    }
    @Test("7 个彩色 token 主题无关（昼夜解析相同）")
    func sevenChromaticSchemeIndependent() {
        for t in [DrawingColorToken.red, .orange, .yellow, .green, .cyan, .blue, .purple] {
            #expect(DrawingColorResolver.resolve(t, scheme: .light) == DrawingColorResolver.resolve(t, scheme: .dark))
        }
    }
    @Test("black/white 主题相关，且不与背景同色（可读）")
    func blackWhiteSchemeDependentReadable() {
        // white 在白天背景(≈1,1,1)下必须不是纯白；black 在夜间背景(≈0,0,0)下必须不是纯黑
        let whiteLight = DrawingColorResolver.resolve(.white, scheme: .light)
        let blackDark = DrawingColorResolver.resolve(.black, scheme: .dark)
        #expect(!(whiteLight.red == 1 && whiteLight.green == 1 && whiteLight.blue == 1))
        #expect(!(blackDark.red == 0 && blackDark.green == 0 && blackDark.blue == 0))
        // 主题相关：white 昼≠夜，black 昼≠夜
        #expect(DrawingColorResolver.resolve(.white, scheme: .light) != DrawingColorResolver.resolve(.white, scheme: .dark))
        #expect(DrawingColorResolver.resolve(.black, scheme: .light) != DrawingColorResolver.resolve(.black, scheme: .dark))
    }
}
```
（前置：`AppColorRGBA` 需 `Equatable` 才能用 `==`/`!=`。若它当前不是 `Equatable`，本 task 顺带给它加 `Equatable` conformance——这是本 task 自己的测试需要，属 D28「同 PR 更新」范围；若已是则跳过。实现时先 `grep "struct AppColorRGBA" -A3` 确认。）

- [ ] **Step 2: 跑测试确认失败** — Run: `swift test --filter DrawingColorResolver`；Expected: 编译失败（`DrawingColorResolver` 未定义）。

- [ ] **Step 3: 实现解析器**

```swift
// DrawingColorResolver.swift
// 划线颜色 token → RGBA 的纯解析（host 可测，非 View / 非 @MainActor）。
// 与图表 AppColorTokens（蜡烛/MA/MACD 13-token）无关：那是另一套语义。
// 7 彩色主题无关；black/white 主题相关（避免与背景同色不可读，母 spec §4.2 / D36）。

public enum DrawingColorResolver {
    public static func resolve(_ token: DrawingColorToken, scheme: AppColorScheme) -> AppColorRGBA {
        switch token {
        case .red:    return AppColorRGBA(red: 0.85, green: 0.20, blue: 0.20)
        case .orange: return AppColorRGBA(red: 0.82, green: 0.40, blue: 0.00)  // legacy 默认，昼夜同
        case .yellow: return AppColorRGBA(red: 0.90, green: 0.70, blue: 0.00)
        case .green:  return AppColorRGBA(red: 0.20, green: 0.65, blue: 0.30)
        case .cyan:   return AppColorRGBA(red: 0.00, green: 0.65, blue: 0.70)
        case .blue:   return AppColorRGBA(red: 0.20, green: 0.45, blue: 0.90)
        case .purple: return AppColorRGBA(red: 0.55, green: 0.30, blue: 0.80)
        case .black:  return scheme == .dark  ? AppColorRGBA(red: 0.85, green: 0.85, blue: 0.85)   // 夜间黑不可读→浅灰
                                              : AppColorRGBA(red: 0.00, green: 0.00, blue: 0.00)
        case .white:  return scheme == .light ? AppColorRGBA(red: 0.20, green: 0.20, blue: 0.20)   // 白天白不可读→深灰
                                              : AppColorRGBA(red: 1.00, green: 1.00, blue: 1.00)
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过** — Run: `swift test --filter DrawingColorResolver`；Expected: PASS。

- [ ] **Step 5: Commit**
```bash
git add -A && git commit -m "feat(drawing): DrawingColorToken 主题解析纯函数（1a-i Task2，D36）"
```

---

### Task 3: `HorizontalLineTool` 消费 color / lineStyle / thickness（视觉零变化）

让 `render` 用 Task 2 的解析器取色、按 `thickness` 定线宽、按 `lineStyle` 定虚线 pattern。默认样式必须仍渲染成今天的橙 + 1.5pt + 实线（视觉零变化）。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift`（`render` 消费样式）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/HorizontalLineToolTests.swift`（新增映射测试）

**Interfaces:**
- Produces（Task 4 复用）：两个 host 可测静态纯函数。**必须 `nonisolated`**（codex plan-high）：`HorizontalLineTool` conform `@MainActor DrawingTool`，其 static 成员默认继承 main-actor 隔离 → host 非隔离测试在 Swift 6 strict concurrency / Mac Catalyst 会编译失败（本地 Mac-mini 常漏报，见 memory `feedback_swift_local_toolchain_blindspot`）。
  ```swift
  nonisolated static func lineWidth(forThickness t: Int) -> CGFloat   // 1→1.5, 2→2.0, 3→2.5, 4→3.0, 5→3.5（clamp 1...5）
  nonisolated static func dashPattern(for style: LineStyle) -> [CGFloat]  // .solid→[]；dash1…dash4 四种互不相同
  ```
- Consumes：`DrawingColorResolver.resolve`（Task 2）。

- [ ] **Step 1: 写失败测试**

```swift
@Test("视觉零变化：默认样式在昼夜下都是 legacy 橙 + 1.5pt")
func defaultStyleUnchangedBothSchemes() {
    #expect(HorizontalLineTool.lineWidth(forThickness: 1) == 1.5)
    for s in [AppColorScheme.light, .dark] {
        let c = DrawingColorResolver.resolve(.orange, scheme: s)   // 默认 colorToken=.orange
        #expect(c.red == 0.82 && c.green == 0.40 && c.blue == 0.0)
    }
    #expect(HorizontalLineTool.dashPattern(for: .solid).isEmpty)
}
@Test("thickness 五档产出五个不同线宽")
func thicknessFiveDistinctWidths() {
    let ws = (1...5).map { HorizontalLineTool.lineWidth(forThickness: $0) }
    #expect(Set(ws).count == 5)
    #expect(ws[0] == 1.5)   // 档 1 = 今天线宽
}
@Test("thickness 越界被 clamp 到 1...5")
func thicknessClamped() {
    #expect(HorizontalLineTool.lineWidth(forThickness: 0) == HorizontalLineTool.lineWidth(forThickness: 1))
    #expect(HorizontalLineTool.lineWidth(forThickness: 99) == HorizontalLineTool.lineWidth(forThickness: 5))
}
@Test("lineStyle：solid 无 pattern；dash1…4 四种互不相同")
func dashPatternsDistinct() {
    #expect(HorizontalLineTool.dashPattern(for: .solid).isEmpty)
    let ds = [LineStyle.dash1, .dash2, .dash3, .dash4].map { HorizontalLineTool.dashPattern(for: $0) }
    #expect(ds.allSatisfy { !$0.isEmpty })
    for i in 0..<ds.count { for j in (i+1)..<ds.count { #expect(ds[i] != ds[j]) } }
}
```

**render 输出边界测试（codex plan-R3-medium：纯 helper 不证明 `render` 真的用了它们——实现可能留着 legacy `strokeRGBA`、漏掉 `setLineWidth`/`setLineDash` 仍全绿）。** 画到 bitmap、采样像素，验证 color/thickness/lineStyle 真经 `HorizontalLineTool.render` 生效。加进同一测试文件（`@MainActor @Suite`，`render` 是 @MainActor）：

```swift
import CoreGraphics
// 采样 helper：render 到 sRGB premultiplied bitmap，返回展开后的像素（不假设坐标方向——扫列/行找线像素）。
@MainActor
static func renderPixels(_ drawing: DrawingObject, scheme: AppColorScheme)
    -> (data: [UInt8], w: Int, h: Int) {
    let w = 800, h = 360
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    HorizontalLineTool().render(ctx: ctx, mapper: Self.mapper(), drawing: drawing, scheme: scheme)
    return (data, w, h)
}
// x=400 列上（线贯穿全宽，此列必有线像素），反 premultiplied 还原颜色；只取 alpha 明显的像素。
static func litColumn(_ data: [UInt8], w: Int, h: Int, x: Int = 400)
    -> [(r: CGFloat, g: CGFloat, b: CGFloat)] {
    var out: [(CGFloat, CGFloat, CGFloat)] = []
    for yy in 0..<h {
        let i = (yy * w + x) * 4
        let a = CGFloat(data[i+3]) / 255
        guard a > 0.3 else { continue }
        out.append((CGFloat(data[i])/255/a, CGFloat(data[i+1])/255/a, CGFloat(data[i+2])/255/a))
    }
    return out
}

@Test("render 输出：默认样式画出 legacy 橙（走真实 render，非纯 helper）")
func renderDefaultIsLegacyOrange() {
    let def = DrawingObject(toolType: .horizontal,
        anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)], isExtended: false, panelPosition: 0)
    let (data, w, h) = Self.renderPixels(def, scheme: .light)
    let lit = Self.litColumn(data, w: w, h: h)
    #expect(!lit.isEmpty)   // 线真的画出来了
    #expect(lit.contains { abs($0.r-0.82)<0.15 && abs($0.g-0.40)<0.15 && $0.b<0.15 })   // 橙
}
@Test("render 输出：colorToken=.blue 画蓝（证明 render 消费了 colorToken，没留 legacy strokeRGBA）")
func renderConsumesColorToken() {
    let blue = DrawingObject(toolType: .horizontal,
        anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
        isExtended: false, panelPosition: 0, colorToken: .blue)
    let (data, w, h) = Self.renderPixels(blue, scheme: .light)
    #expect(Self.litColumn(data, w: w, h: h).contains { $0.b > $0.r && $0.b > 0.5 })   // 蓝占主导、非橙
}
@Test("render 输出：thickness=5 覆盖行数 > thickness=1（证明 render 消费 thickness）")
func renderConsumesThickness() {
    func litRows(_ t: Int) -> Int {
        let d = DrawingObject(toolType: .horizontal,
            anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
            isExtended: false, panelPosition: 0, thickness: t)
        let (data, w, h) = Self.renderPixels(d, scheme: .light)
        return Self.litColumn(data, w: w, h: h).count
    }
    #expect(litRows(5) > litRows(1))
}
@Test("render 输出：solid 沿线连续、dash1 有间断（证明 render 消费 lineStyle）")
func renderConsumesLineStyle() {
    func gaps(_ style: LineStyle) -> Int {
        let d = DrawingObject(toolType: .horizontal,
            anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
            isExtended: false, panelPosition: 0, lineStyle: style)
        let (data, w, h) = Self.renderPixels(d, scheme: .light)
        // 找线所在行（x=400 列 alpha 最大的行），再沿该行 x∈[100,700] 数「亮→暗」跳变
        let lineY = (0..<h).max(by: { data[($0*w+400)*4+3] < data[($1*w+400)*4+3] })!
        var g = 0, prevLit = false
        for x in 100..<700 {
            let lit = data[(lineY*w + x)*4 + 3] > 60
            if prevLit && !lit { g += 1 }
            prevLit = lit
        }
        return g
    }
    #expect(gaps(.solid) == 0)     // 实线：中段无间断
    #expect(gaps(.dash1) >= 1)     // 虚线：有间断
}
```
（**注**：bitmap 坐标方向不影响这些断言——采样一律「扫列/行找线像素」，不假设行号；颜色断言留 0.15 容差吸收抗锯齿边缘混合。）

- [ ] **Step 2: 跑测试确认失败** — Run: `swift test --filter HorizontalLineTool`；Expected: 编译失败（`lineWidth`/`dashPattern` 未定义）。

- [ ] **Step 3: 实现映射 + 让 render 消费**

```swift
// HorizontalLineTool.swift —— 新增静态纯函数（nonisolated：见 Interfaces，host 可测且不吃 main-actor 隔离）
nonisolated static func lineWidth(forThickness t: Int) -> CGFloat {
    let clamped = min(max(t, 1), 5)
    return 1.0 + 0.5 * CGFloat(clamped)   // 1→1.5, 2→2.0, 3→2.5, 4→3.0, 5→3.5
}
nonisolated static func dashPattern(for style: LineStyle) -> [CGFloat] {
    switch style {
    case .solid: return []
    case .dash1: return [6, 3]
    case .dash2: return [2, 3]
    case .dash3: return [10, 4]
    case .dash4: return [10, 3, 2, 3]
    }
}

// render 描边段改为消费样式（几何仍全宽，几何升级在 Task 4）：
let rgba = DrawingColorResolver.resolve(drawing.colorToken, scheme: scheme)
ctx.setStrokeColor(CGColor(srgbRed: CGFloat(rgba.red), green: CGFloat(rgba.green),
                           blue: CGFloat(rgba.blue), alpha: CGFloat(rgba.alpha)))
ctx.setLineWidth(Self.lineWidth(forThickness: drawing.thickness))
let dash = Self.dashPattern(for: drawing.lineStyle)
if dash.isEmpty { ctx.setLineDash(phase: 0, lengths: []) } else { ctx.setLineDash(phase: 0, lengths: dash) }
```
（`strokeRGBA` 静态常量此后不再被 `render` 使用；若无其它 caller，删掉它——属「我的改动造成的 orphan」，CLAUDE.md §3 允许清理。实现时先 grep 确认无其它引用。）

- [ ] **Step 4: 跑测试确认通过** — Run: `swift test --filter HorizontalLineTool`；Expected: PASS。

- [ ] **Step 5: Commit** — `feat(drawing): HorizontalLineTool 消费 color/lineStyle/thickness（1a-i Task3，默认值视觉零变化）`

---

### Task 4: 水平线几何子类（直线 / 射线）+ hitTest 方向性 + D43 legacy 锁定

按 `lineSubType` 分支：`.straight` 全宽横线（今天行为），`.ray` 自落点向右到主图右缘。`hitTest` 同步分支：射线只在落点**右侧**命中。落点 x = `mapper.indexToX(anchor.candleIndex)`。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift`（几何 helper + render + hitTest 分支）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/HorizontalLineToolTests.swift`

**Interfaces:**
- Produces：`nonisolated static func lineXRange(for drawing: DrawingObject, mapper: CoordinateMapper) -> (minX: CGFloat, maxX: CGFloat)?`
  （`.straight` → `(frame.minX, frame.maxX)`；`.ray` → clamp 后 `(max(minX, anchorX), maxX)`，anchorX 在右缘外 → nil；**`.segment` → nil（水平线无线段语义，fail-closed，codex plan-R4-high）**；空锚 → nil。纯函数，host 可测；**`nonisolated`** 理由同 Task 3 Interfaces。）
- Consumes：`mapper.indexToX`（`Geometry.swift:138`）、`mapper.viewport.mainChartFrame`。

- [ ] **Step 1: 写失败测试**（几何 straight/ray + hitTest 方向性 + D43 解码派生）

```swift
@Test("几何：straight 全宽（minX…maxX）")
func straightSpansFullWidth() {
    let m = Self.mapper()   // mainChartFrame x∈[0,800]
    let d = DrawingObject(toolType: .horizontal,
        anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
        isExtended: false, panelPosition: 0, lineSubType: .straight)
    let r = HorizontalLineTool.lineXRange(for: d, mapper: m)!
    #expect(r.minX == 0 && r.maxX == 800)
}
@Test("几何：ray 自落点向右到右缘")
func raySpansAnchorToRight() {
    let m = Self.mapper()
    let d = DrawingObject(toolType: .horizontal,
        anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
        isExtended: false, panelPosition: 0, lineSubType: .ray)
    let r = HorizontalLineTool.lineXRange(for: d, mapper: m)!
    #expect(r.minX == m.indexToX(5) && r.maxX == 800)
}
@Test("射线屏幕外锚点：右缘外→nil；左缘外→clamp 到 minX，render/hitTest 区间一致（codex plan-medium）")
func rayOffscreenAnchorNormalized() {
    let m = Self.mapper()   // indexToX(i)=i*10，mainChartFrame x∈[0,800]
    // 右缘外：candleIndex=100 → indexToX=1000 > 800 → 整段不可见
    let offRight = DrawingObject(toolType: .horizontal,
        anchors: [DrawingAnchor(period: .m3, candleIndex: 100, price: 15)],
        isExtended: false, panelPosition: 0, lineSubType: .ray)
    #expect(HorizontalLineTool.lineXRange(for: offRight, mapper: m) == nil)
    let y = m.priceToY(15)
    #expect(HorizontalLineTool().hitTest(point: CGPoint(x: 400, y: y), mapper: m, drawing: offRight) == false)
    // 左缘外：candleIndex=-5 → indexToX=-50 < 0 → clamp minX=0，右缘外点仍在 [0,800] 内可命中
    let offLeft = DrawingObject(toolType: .horizontal,
        anchors: [DrawingAnchor(period: .m3, candleIndex: -5, price: 15)],
        isExtended: false, panelPosition: 0, lineSubType: .ray)
    let rl = HorizontalLineTool.lineXRange(for: offLeft, mapper: m)!
    #expect(rl.minX == 0 && rl.maxX == 800)
    #expect(HorizontalLineTool().hitTest(point: CGPoint(x: 400, y: y), mapper: m, drawing: offLeft) == true)
}
@Test("射线 hitTest 方向性：右侧命中、左侧不命中；直线两侧都命中")
func rayHitTestDirectional() {
    let m = Self.mapper()
    let y = m.priceToY(15)
    let anchorX = m.indexToX(5)
    func mk(_ sub: LineSubType) -> DrawingObject {
        DrawingObject(toolType: .horizontal,
            anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
            isExtended: false, panelPosition: 0, lineSubType: sub)
    }
    let tool = HorizontalLineTool()
    #expect(tool.hitTest(point: CGPoint(x: anchorX + 50, y: y), mapper: m, drawing: mk(.ray)) == true)
    #expect(tool.hitTest(point: CGPoint(x: anchorX - 50, y: y), mapper: m, drawing: mk(.ray)) == false)
    #expect(tool.hitTest(point: CGPoint(x: anchorX - 50, y: y), mapper: m, drawing: mk(.straight)) == true)
}
@Test("D43：legacy blob（无 lineSubType 键 + isExtended=true）解码派生 .ray 并渲染为射线")
func legacyIsExtendedRendersAsRay() {
    // 走【解码路径】而非 init 默认——init 默认 lineSubType=.straight；只有解码 legacy blob 才派生 .ray（Models.swift:311-313）
    let json = #"{"toolType":"horizontal","anchors":[{"period":"3m","candleIndex":5,"price":15}],"isExtended":true,"panelPosition":0}"#
    let decoded = try! JSONDecoder().decode(DrawingObject.self, from: Data(json.utf8))
    #expect(decoded.lineSubType == .ray)
    let r = HorizontalLineTool.lineXRange(for: decoded, mapper: Self.mapper())!
    #expect(r.minX == Self.mapper().indexToX(5))   // 射线起点，不是全宽 minX=0
}
@Test("水平线 .segment fail-closed：不渲染、不命中（codex plan-R4-high）")
func horizontalSegmentFailsClosed() {
    let m = Self.mapper()
    let seg = DrawingObject(toolType: .horizontal,
        anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
        isExtended: false, panelPosition: 0, lineSubType: .segment)   // 水平线不支持的持久化值
    #expect(HorizontalLineTool.lineXRange(for: seg, mapper: m) == nil)   // 不渲染
    #expect(HorizontalLineTool().hitTest(point: CGPoint(x: 400, y: m.priceToY(15)), mapper: m, drawing: seg) == false)  // 不命中
}
```
（**关键**：D43 锁定的是**解码派生**，测试必须走 JSON 解码路径，不能用 `init`。`.segment` fail-closed 防止未来/损坏数据被当全宽假线渲染。）

- [ ] **Step 2: 跑测试确认失败** — Run: `swift test --filter HorizontalLineTool`；Expected: 编译失败（`lineXRange` 未定义）。

- [ ] **Step 3: 实现几何分支**

```swift
nonisolated static func lineXRange(for drawing: DrawingObject, mapper: CoordinateMapper) -> (minX: CGFloat, maxX: CGFloat)? {
    guard let anchor = drawing.anchors.first else { return nil }
    let frame = mapper.viewport.mainChartFrame
    switch drawing.lineSubType {
    case .straight:
        return (frame.minX, frame.maxX)
    case .ray:
        let anchorX = mapper.indexToX(anchor.candleIndex)
        if anchorX > frame.maxX { return nil }              // 落点已在右缘外 → 射线整段不可见（codex plan-R3-medium）
        return (max(frame.minX, anchorX), frame.maxX)       // 落点在左缘外 → clamp 到 minX，保 render/hitTest 区间一致
    case .segment:
        // 水平线无线段语义（母 spec §5.1）。.segment 是已持久化枚举值，损坏/未来版本数据可解码出它——
        // fail-closed（codex plan-R4-high）：返回 nil → 不渲染、不命中、不标注（dispatch 层的 guard 会一并跳过）。
        // UI 禁选 .segment 是后续期（线型子类选择器，1a-ii/iii）的事；本期渲染层不 fail-open 成全宽假线。
        return nil
    }
}

// render 用 lineXRange 画线段（其余描边设置同 Task 3）：
guard let y = lineY(anchors: drawing.anchors, mapper: mapper),
      let xr = Self.lineXRange(for: drawing, mapper: mapper) else { return }
ctx.move(to: CGPoint(x: xr.minX, y: y))
ctx.addLine(to: CGPoint(x: xr.maxX, y: y))
ctx.strokePath()

// hitTest 分支：命中区间由 lineXRange 自然导出（射线左侧 point.x < minX 不命中）
public func hitTest(point: CGPoint, mapper: CoordinateMapper, drawing: DrawingObject) -> Bool {
    guard let y = lineY(anchors: drawing.anchors, mapper: mapper),
          let xr = Self.lineXRange(for: drawing, mapper: mapper) else { return false }
    return abs(point.y - y) <= Self.hitTolerance && point.x >= xr.minX && point.x <= xr.maxX
}
```

- [ ] **Step 4: 跑测试确认通过** — Run: `swift test --filter HorizontalLineTool`；Expected: PASS。
- [ ] **Step 5: Commit** — `feat(drawing): 水平线 straight/ray 几何 + hitTest 方向性 + D43 legacy→射线锁定（1a-i Task4）`

---

### Task 5: 价格标注（labelMode 隐藏 / 左 / 右）

按 `labelMode` 画价格标签。标签位置计算抽成 host 可测纯函数；绘制在 dispatch 层（`KLineView+Drawing.swift`，已在 `#if canImport(UIKit)` guard 内），用既有 `str.draw(at:withAttributes:)` 范式。

**架构决策（surface）**：标注归 dispatch 层而非 tool——画文字需 UIKit（`NSAttributedString`），而 `DrawingTool` 协议刻意保持纯 CoreGraphics 跨平台（`DrawingTool.swift:9-10` 注释）。标注与 markers/crosshair 同为「图表叠加文字」，同层同风格。tool 只画线。

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingLabelLayout.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingLabelLayoutTests.swift`

**Interfaces:**
- Produces：`DrawingLabelLayout.labelRect(mode:lineY:lineXRange:textSize:mainChartFrame:) -> CGRect?`
  （已做「不压线」上移 + 「右缘不溢出」右边界裁剪；`.hidden` → nil）
- Consumes：`HorizontalLineTool.lineXRange`（Task 4）。

- [ ] **Step 1: 写失败测试**

```swift
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("DrawingLabelLayout")
struct DrawingLabelLayoutTests {
    static let frame = CGRect(x: 0, y: 0, width: 800, height: 360)
    static let sz = CGSize(width: 60, height: 16)
    @Test(".hidden → 无矩形")
    func hiddenNil() {
        #expect(DrawingLabelLayout.labelRect(mode: .hidden, lineY: 100,
            lineXRange: (0, 800), textSize: Self.sz, mainChartFrame: Self.frame) == nil)
    }
    @Test("不压线：标签底边在线上方（rect.maxY <= lineY）")
    func labelAboveLine() {
        for mode in [LabelMode.left, .right] {
            let r = DrawingLabelLayout.labelRect(mode: mode, lineY: 100,
                lineXRange: (0, 800), textSize: Self.sz, mainChartFrame: Self.frame)!
            #expect(r.maxY <= 100)
        }
    }
    @Test("右对齐 + 四位价不溢出：rect.maxX <= 主图右缘")
    func rightNoOverflow() {
        let r = DrawingLabelLayout.labelRect(mode: .right, lineY: 100,
            lineXRange: (0, 800), textSize: CGSize(width: 60, height: 16), mainChartFrame: Self.frame)!
        #expect(r.maxX <= 800)
    }
    @Test("左对齐锚在线左端；右对齐锚在线右端")
    func leftRightAnchoring() {
        let left = DrawingLabelLayout.labelRect(mode: .left, lineY: 100,
            lineXRange: (200, 800), textSize: Self.sz, mainChartFrame: Self.frame)!
        let right = DrawingLabelLayout.labelRect(mode: .right, lineY: 100,
            lineXRange: (200, 800), textSize: Self.sz, mainChartFrame: Self.frame)!
        #expect(left.minX >= 200)
        #expect(right.maxX <= 800)
        #expect(right.minX > left.minX)
    }
    @Test("顶边溢出：线贴主图上缘时标签改放线下方，仍在 frame 内且不压线（codex plan-medium）")
    func topEdgeFallsBelow() {
        // lineY=5, textHeight=16, frame.minY=0 → 上方 above=5-2-16=-13 < 0 → 改放线下方
        let r = DrawingLabelLayout.labelRect(mode: .left, lineY: 5,
            lineXRange: (0, 800), textSize: Self.sz, mainChartFrame: Self.frame)!
        #expect(r.minY >= Self.frame.minY)   // 不跑出主图上缘
        #expect(r.minY >= 5)                 // 放在线下方 → 顶边不高于线 → 不压线
    }
    @Test("上方有空间时仍放线上方（不压线）")
    func aboveWhenRoom() {
        let r = DrawingLabelLayout.labelRect(mode: .left, lineY: 100,
            lineXRange: (0, 800), textSize: Self.sz, mainChartFrame: Self.frame)!
        #expect(r.maxY <= 100)   // 底边不低于线
    }
    @Test("射线锚近右缘 + .left/.show：x 被裁不溢出右边界（codex plan-R3）")
    func leftShowNearRightEdgeClamped() {
        for mode in [LabelMode.left, .show] {
            let r = DrawingLabelLayout.labelRect(mode: mode, lineY: 100,
                lineXRange: (790, 800), textSize: Self.sz, mainChartFrame: Self.frame)!   // 锚 x=790，textW=60
            #expect(r.maxX <= 800)   // 不越右缘
            #expect(r.minX >= 0)     // 不越左缘
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败** — Run: `swift test --filter DrawingLabelLayout`；Expected: 编译失败。

- [ ] **Step 3: 实现纯函数**

```swift
// DrawingLabelLayout.swift —— 价格标签矩形（纯函数，host 可测）。
// 「不压线」= 标签底边贴在线上方 gap 处；「右缘不溢出」= 右对齐时右边界裁到主图右缘内。
import CoreGraphics

public enum DrawingLabelLayout {
    private static let gap: CGFloat = 2   // 标签与线的间隙

    public static func labelRect(mode: LabelMode, lineY: CGFloat,
                                 lineXRange: (minX: CGFloat, maxX: CGFloat),
                                 textSize: CGSize, mainChartFrame: CGRect) -> CGRect? {
        let x: CGFloat
        switch mode {
        case .hidden:       return nil
        case .show, .left:  x = lineXRange.minX                    // 锚线左端（水平线只 隐藏/左/右，.show 归左）
        case .right:        x = lineXRange.maxX - textSize.width   // 锚线右端
        }
        return placed(x: x, lineY: lineY, textSize: textSize, mainChartFrame: mainChartFrame)
    }

    // 统一裁剪（codex plan-R3）：x 收进 [minX, maxX-textWidth]——左右都不溢出，含射线锚近右缘时的 .left/.show；
    // y 优先线【上方】（不压线），上方顶到主图上缘放不下时改放线【下方】（仍不压线）。
    private static func placed(x: CGFloat, lineY: CGFloat, textSize: CGSize, mainChartFrame: CGRect) -> CGRect {
        let maxX = max(mainChartFrame.minX, mainChartFrame.maxX - textSize.width)
        let clampedX = min(max(x, mainChartFrame.minX), maxX)
        let above = lineY - gap - textSize.height
        let y = above >= mainChartFrame.minY ? above : lineY + gap   // 上方无空间 → 线下方
        return CGRect(x: clampedX, y: y, width: textSize.width, height: textSize.height)
    }
}
```

- [ ] **Step 4: dispatch 层按 labelMode 绘制**

```swift
// KLineView+Drawing.swift —— 在 tool.render 之后，按 labelMode 画价格标签（仅 .horizontal 本期接线）
// 文字绘制范式同 KLineView+Markers.swift:46-51 / KLineView+Crosshair.swift:112-123
if drawing.labelMode != .hidden, drawing.toolType == .horizontal,
   let y = HorizontalLineTool().lineY(anchors: drawing.anchors, mapper: mapper),
   let xr = HorizontalLineTool.lineXRange(for: drawing, mapper: mapper) {
    let text = String(format: "%.2f", drawing.anchors.first?.price ?? 0)
    let rgba = DrawingColorResolver.resolve(drawing.textColorToken, scheme: scheme)
    let color = UIColor(red: CGFloat(rgba.red), green: CGFloat(rgba.green), blue: CGFloat(rgba.blue), alpha: CGFloat(rgba.alpha))
    let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: CGFloat(drawing.fontSize)), .foregroundColor: color]
    let textSize = (text as NSString).size(withAttributes: attrs)
    if let rect = DrawingLabelLayout.labelRect(mode: drawing.labelMode, lineY: y, lineXRange: xr,
                                               textSize: textSize, mainChartFrame: mapper.viewport.mainChartFrame) {
        (text as NSString).draw(at: rect.origin, withAttributes: attrs)
    }
}
```

- [ ] **Step 5: 跑测试确认通过** — Run: `swift test --filter "DrawingLabelLayout|Drawing"`；Expected: PASS。iOS build 验证文字真的画出。
- [ ] **Step 6: Commit** — `feat(drawing): 价格标注 labelMode 隐藏/左/右 + 防溢出/不压线（1a-i Task5，标注在 dispatch 层）`

---

### Task 6: D29 周期绑定渲染过滤 + 同周期 fail-safe

把 `RenderStateBuilder.make` 的面板过滤判据从 `panelPosition == (panel==.upper ?0:1)` 改为 `drawing.period == 该面板当前 period`；`upper==lower` 时退回 `panelPosition` 兜底。三模式共用这一行，复盘两层都按新判据。**不改签名**——`engine` 本身带 `upperPanel/lowerPanel`。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift:67-69`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`

**Interfaces:**
- Produces：`static func belongsToPanel(_ drawing: DrawingObject, panel: PanelId, upperPeriod: Period, lowerPeriod: Period) -> Bool`
  （抽成纯函数，1b-i 的命中集合 `visibleDrawings` 将复用；本 PR 先只服务渲染）
- Consumes：`engine.upperPanel.period` / `engine.lowerPanel.period`（`TrainingEngine.swift:45-46`）、`engine.flow.mode`。

- [ ] **Step 1: 写失败测试**

```swift
@Test("D29：按 period 落面板，panelPosition 不再影响")
func filtersByPeriodNotPanelPosition() {
    let d = DrawingObject(toolType: .horizontal, anchors: [DrawingAnchor(period: .m60, candleIndex: 0, price: 1)],
                          isExtended: false, panelPosition: 1, period: .m60)   // period=.m60 但 panelPosition=1（冲突）
    #expect(RenderStateBuilder.belongsToPanel(d, panel: .upper, upperPeriod: .m60, lowerPeriod: .m15) == true)
    #expect(RenderStateBuilder.belongsToPanel(d, panel: .lower, upperPeriod: .m60, lowerPeriod: .m15) == false)
}
@Test("D29：某 period 不在任一面板 → 两面板都不含")
func periodNotShownHiddenBoth() {
    let d = DrawingObject(toolType: .horizontal, anchors: [DrawingAnchor(period: .weekly, candleIndex: 0, price: 1)],
                          isExtended: false, panelPosition: 0, period: .weekly)
    for p in [PanelId.upper, .lower] {
        #expect(RenderStateBuilder.belongsToPanel(d, panel: p, upperPeriod: .m60, lowerPeriod: .m15) == false)
    }
}
@Test("D29 fail-safe：upper==lower==线period → 只落 panelPosition 指定的那个面板")
func failSafeSamePeriodSinglePanel() {
    let up0 = DrawingObject(toolType: .horizontal, anchors: [DrawingAnchor(period: .m60, candleIndex: 0, price: 1)],
                            isExtended: false, panelPosition: 0, period: .m60)
    let low1 = DrawingObject(toolType: .horizontal, anchors: [DrawingAnchor(period: .m60, candleIndex: 0, price: 1)],
                             isExtended: false, panelPosition: 1, period: .m60)
    #expect(RenderStateBuilder.belongsToPanel(up0, panel: .upper, upperPeriod: .m60, lowerPeriod: .m60) == true)
    #expect(RenderStateBuilder.belongsToPanel(up0, panel: .lower, upperPeriod: .m60, lowerPeriod: .m60) == false)
    #expect(RenderStateBuilder.belongsToPanel(low1, panel: .upper, upperPeriod: .m60, lowerPeriod: .m60) == false)
    #expect(RenderStateBuilder.belongsToPanel(low1, panel: .lower, upperPeriod: .m60, lowerPeriod: .m60) == true)
}
@Test("D29 fail-safe：upper==lower 但 ≠ 线period → 两面板都 false（period 先于 panelPosition，codex plan-high）")
func failSafeWrongPeriodExcludedBoth() {
    // 两面板都 .m60，一条 .weekly 线 panelPosition=0：period 不符，绝不能被 panelPosition 硬塞进 .m60 面板
    let wk = DrawingObject(toolType: .horizontal, anchors: [DrawingAnchor(period: .weekly, candleIndex: 0, price: 1)],
                           isExtended: false, panelPosition: 0, period: .weekly)
    #expect(RenderStateBuilder.belongsToPanel(wk, panel: .upper, upperPeriod: .m60, lowerPeriod: .m60) == false)
    #expect(RenderStateBuilder.belongsToPanel(wk, panel: .lower, upperPeriod: .m60, lowerPeriod: .m60) == false)
}
```
（复盘两层 + legacy period 兜底 + revealTick 过滤不变，另在 `make(engine:panel:...)` 层测：用 `TrainingEngine.preview(mode:.review)`，`engine.drawings` 与 `engine.reviewDrawings` 各放一条不同 period 的线，断言只有匹配当前面板 period 的进 `rs.drawings`。参照 `RenderStateBuilderTests.swift:162` 的 `preview()` 范式。）

- [ ] **Step 2: 跑测试确认失败** — Run: `swift test --filter RenderStateBuilder`；Expected: 编译失败（`belongsToPanel` 未定义）。

- [ ] **Step 3: 实现纯函数 + 接进过滤行**

```swift
// RenderStateBuilder.swift —— 新增静态纯函数
static func belongsToPanel(_ drawing: DrawingObject, panel: PanelId,
                           upperPeriod: Period, lowerPeriod: Period) -> Bool {
    // 先 period 匹配（codex plan-high）：period 不符一律不属于本面板——即使在同周期 fail-safe 下也不例外，
    // 否则一条 .weekly 线会在两面板都 .m60 的损坏态下被 panelPosition 硬塞进 .m60 面板，坐标系错。
    let panelPeriod = (panel == .upper) ? upperPeriod : lowerPeriod
    guard drawing.period == panelPeriod else { return false }
    // fail-safe（D29）：period 已匹配，且两面板同周期（损坏/版本错位 resume）→ 再用 panelPosition 破平局，只渲染在一个面板
    if upperPeriod == lowerPeriod {
        return drawing.panelPosition == (panel == .upper ? 0 : 1)
    }
    return true
}

// 过滤行（:67-69）改为：
drawings: (engine.drawings + (engine.flow.mode == .review ? engine.reviewDrawings : [])).filter { drawing in
    RenderStateBuilder.belongsToPanel(drawing, panel: panel,
        upperPeriod: engine.upperPanel.period, lowerPeriod: engine.lowerPanel.period)
        && drawing.revealTick <= tick
},
```

- [ ] **Step 4: 跑测试确认通过** — Run: `swift test --filter RenderStateBuilder`；Expected: PASS。
- [ ] **Step 5: Commit** — `feat(drawing): D29 周期绑定渲染过滤 + upper==lower fail-safe（1a-i Task6，三模式共用）`

---

## 收尾（三绿门 + 验收）

- [ ] **全量测试**：`swift test`（host 全绿）
- [ ] **Mac Catalyst 门**：`xcodebuild build-for-testing`（macos-15 严格 Sendable/@MainActor 隔离，本地 Mac-mini 可能漏报，见 memory）
- [ ] **iOS build**：确认 UIKit 路径（标注绘制）真的编译
- [ ] **非程序员验收清单**：spec §2.4（11 条），交付时附上
- [ ] **whole-branch codex** → approve → PR（user 真 TTY 跑 `attest-override.sh` + admin merge）

## Self-Review 记录

- **Spec 覆盖**：§2.1 五工作项 → Task 1(D35) / Task 2+3(样式+D36) / Task 4(几何+D43) / Task 5(标注) / Task 6(D29)。§2.3 八条负向测试全部有对应 Step（视觉零变化=T3；dispatch 举证=T1；射线方向性=T4；D43=T4；线宽/线型=T3；昼夜色=T2；标注位置/隐藏=T5；周期绑定/fail-safe=T6）。
- **类型一致**：`render(ctx:mapper:drawing:scheme:)` / `hitTest(point:mapper:drawing:)` / `lineWidth(forThickness:)` / `dashPattern(for:)` / `lineXRange(for:mapper:)` / `labelRect(...)` / `belongsToPanel(...)` 在各 task 间签名一致。
- **待实施者注意**：① `AppColorRGBA` 若非 `Equatable`，Task 2 顺带加（其测试用 `==`）；② Task 3 删 `strokeRGBA` 前 grep 确认无其它 caller；③ Task 5 `AppColorRGBA → UIColor` 若有既有转换 helper 优先复用，无则内联。

# C8a ChartContainerView 渲染路径 — 设计（Wave 2 顺位 7 上半）

**性质**：业务代码 PR（iOS Swift）。Wave 2 outline 顺位 7（C8 ChartContainerView + C7 手势接线 + H1 production handler 集成测试）经 brainstorming 拆为 **C8a（渲染路径，本 PR）** + **C8b（交互路径 + H1 闭环，下一 PR）**。

**前置**：Wave 2 outline（`docs/superpowers/specs/2026-06-02-wave2-outline-design.md`）§二 顺位 7 + §四 residual 映射；H1 RFC（`docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md`）。E5a/E5b（PR #80/#81）、C2（PR #60）、C7（PR #61）、C1a-c/C3-C6（Wave 0/1）均已 merged 在场。

**user 决策（2026-06-07 brainstorming）**：
- D-split：顺位 7 拆 C8a/C8b（沿用 E5a/b、E6a/b 拆法；每锚 ≤500 行 / ≤3 子项；H1 闭环落 C8b）。
- D-loc：视口几何 + buildRenderState 落**平台无关** `RenderStateBuilder`（非 spec-literal 的 `UIViewRepresentable` 内 private func）——唯一能 macOS host 单测 + 被 C8b H1 handler 复用的形态。

---

## 一、目标与边界

### 1.1 C8a 交付（In scope）
1. **`RenderStateBuilder`**（新建，无 UIKit）：纯静态函数把 `TrainingEngine` 运行时状态 + view bounds 装配为 `KLineRenderState`（含视口几何推导 + 可见切片 + volumeRange/macdRange）。
2. **`ChartContainerView`**（新建，`#if canImport(UIKit)`）：`UIViewRepresentable` 薄桥接，`makeUIView → KLineView`、`updateUIView → view.renderState = RenderStateBuilder.make(...)`。**不挂手势**（C8b）。
3. **host 全量单测**：视口几何 / 值域 / 空数据 / Equatable 短路 / perf。
4. **C3–C6 渲染收口核对**：buildRenderState 用 `NonDegenerateRange.make` 算 volumeRange/macdRange（residual 表项）；plan 阶段逐项核对 C3–C6 deferred 项是否落本 PR。
5. **C8 性能验收**：buildRenderState <4ms（host 证据）+ Equatable 短路生效。

### 1.2 Out of scope（→ C8b 或更后）
- C7 `ChartGestureArbiter` 生产接线（attach + callback 路由）。
- 生产 handler：`activateDrawing → requestDrawingSnapshotAfterStoppingAnimator` effect → `animator.stop()` → 算 candleRange → `setDrawingSnapshot`；`panEnded → startDeceleration → animator.onUpdate → offsetApplied`。
- `TrainingEngine.activateDrawingTool` / `deleteDrawing`（E5b 延后至此，归 **C8b**）。
- **H1 production handler 集成测试**（归 C8b——三模块在场 + handler 存在才可写）。
- C2/C7 运行时验收 artifact（CADisplayLink / 手势仲裁运行时；归 C8b + 顺位 9）。
- pinch 缩放改 visibleCount、十字光标点（长按）、drawing 渲染联动（C8b/Wave 3）。

### 1.3 与冻结契约的关系（不改）
- 不改 `KLineRenderState`（9 let 字段）/ `Geometry.swift`（ChartViewport/CoordinateMapper/PriceRange/NonDegenerateRange/ChartPanelFrames）/ `Reducer.swift` / `TrainingEngine`（E5a/b 冻结面）/ `KLineView` shell。C8a 只**消费**它们。
- `KLineView.renderState` 已有 `didSet { guard != oldValue }` 短路（Equatable）；C8a 不改，靠它实现「相同状态不重绘」（**device 运行期行为**，host 仅验 builder 输出相等前提，见 §六-8）。

### 1.4 顺位-7 residual traceability（C8a-1：拆 C8a/C8b 后不得遗漏 outline §四 顺位-7 项）

**C8b = 顺位 7 的子锚（非新顺位）**：沿用 outline §一「E5/E6 大模块按需拆为子 anchor」+ §三.2 拆法（E5a/b、E6a/b 先例）。outline §四 residual 表把多项标「顺位 7」；拆分后**C8a + C8b 联合 = 顺位 7**，逐项归属如下表，**无 residual 悬空**。outline §四 文本不需 governance 改写（拆子锚是 plan 阶段允许的分解，非改 anchor 集），但 **Wave 2 收尾 completion doc 须记 C8a/C8b 为顺位 7 子锚**，使 §四「顺位 7」行可审计。

| outline §四 顺位-7 residual（行号） | C8a | C8b | 备注 |
|---|---|---|---|
| H1 production handler 集成测试（L118） | — | ✅ 闭环 | 三模块在场 + handler 存在才可写 |
| C7 手势 arbiter 生产接线（L125） | — | ✅ 闭环 | attach-once + callback 路由 |
| `activateDrawingTool`/`deleteDrawing`（E5b L7 延后至顺位 7） | — | ✅ 闭环 | 画线激活编排需 viewport |
| C3-C6 渲染收口：volumeRange/macdRange 经 `NonDegenerateRange.make`（L119） | ✅ 闭环 | — | 其余 C3-C6 deferred 项 plan 阶段逐项核对，确认是否本 PR |
| C8 性能：host 装配开销 smoke（L120） | ✅ smoke（**非权威**） | — | 仅 builder 计时 |
| C8 性能：spec「120Hz 单帧 <4ms」完整 draw 帧预算（L120 device 证据） | — | ✅ 闭环 | C8a-5：与 C2/C7 runtime artifact 同批，device/sim |
| C2/C7 运行时 gate artifact（L121；CADisplayLink/手势仲裁 runtime） | — | ✅ 闭环（+ 顺位 9 U2 手势 runtime） | 不得仅凭编译宣告 clean |

---

## 二、架构

```
TrainingEngine (@Observable, @MainActor)         ← E5a/b（只读 accessor: tick/upperPanel/lowerPanel/allCandles/markers/drawings）
        │ (engine, panel, bounds)
        ▼
RenderStateBuilder (平台无关纯函数)               ← C8a 新建
        │ makeViewport(...) → ChartViewport
        │ 可见切片 + volumeRange/macdRange
        ▼
KLineRenderState (值类型)                          ← Wave 0 冻结
        │ view.renderState = ...（Equatable 短路）
        ▼
ChartContainerView (UIViewRepresentable, UIKit)   ← C8a 新建（薄 glue）
        ▼
KLineView.draw(_:) → C3–C6 drawXxx                 ← Wave 0/1 冻结
```

- **层次纪律**：视口几何是**呈现层**逻辑（依赖 bounds），不进业务 engine（D-loc）；不进 UIKit-only 的 `ChartContainerView`（否则 host 不可测、C8b 不可复用）。故独立 `RenderStateBuilder`。
- **C8b 复用点**：`RenderStateBuilder.makeViewport(...)` 与「可见 candleRange」推导 = C8b H1 handler 在 `animator.stop()` 后算 `setDrawingSnapshot(candleRange:)` 的同一函数。C8a 把它设计为 public（模块内）静态函数即可被 C8b 直接调用，无需 C8b 改 builder。

### 2.1 `RenderStateBuilder` API（草案）

```swift
// Render/RenderStateBuilder.swift（无 UIKit import；import CoreGraphics + Foundation）
public enum RenderStateBuilder {
    /// C8a 渲染常量（spec 无公式，本 PR 占位；标注 Wave 3 pinch 缩放/磨光可改）。
    static let defaultVisibleCount = 80
    static let candleWidthRatio: CGFloat = 0.7

    /// 主入口：装配完整 KLineRenderState。空 candle / bounds.width<=0 → .empty。
    /// 不取 displayScale（renderState 不含该字段；亚像素对齐在 KLineView.draw 用
    /// traitCollection.displayScale 构造 mapper 时做——见 C8a-2 修订，对齐 spec L1426 签名）。
    public static func make(engine: TrainingEngine, panel: PanelId, bounds: CGRect) -> KLineRenderState

    /// C8b H1 handler 复用：当前可见 candle 索引半开区间。**委托 makeViewport 单一真相**
    /// （不重复 offset/clamp 数学，防双路径漂移；见 C8a-3 修订）：
    ///   `let vp = makeViewport(...); return vp.startIndex ..< vp.startIndex + vp.visibleCount`
    /// 〔C8b 调用面 provisional〕：H1 handler 在 `animator.stop()` 后取**当时 engine** 的
    /// panelState（offset 已被 stop 冻结、无 in-flight pan 余震）+ candles + tick + bounds 调本函数；
    /// 若 C8b 实测签名不足（如需 displayScale/帧时刻），按 C8b 自有 review 调整，不回改 C8a 已测数学。
    public static func visibleCandleRange(panelState: PanelViewState, candles: [KLineCandle],
                                          tick: Int, bounds: CGRect) -> Range<Int>

    /// 视口几何推导（autoTracking startIndex from tick + freeScrolling offset 分解 + pixelShift）。
    /// 唯一拥有 offset→startIndex→pixelShift 装配的函数（make 与 visibleCandleRange 都经它）。
    static func makeViewport(panelState: PanelViewState, candles: [KLineCandle],
                             tick: Int, bounds: CGRect) -> ChartViewport
}
```

注：`make` 取 `engine: TrainingEngine`（@MainActor），故 `make` 标 `@MainActor`；`makeViewport`/`visibleCandleRange` 取已解出的纯值（panelState/candles/tick/bounds），**不依赖 engine、不依赖 MainActor、不依赖 UIKit** → host 纯函数单测 + C8b 复用。`make` 内部从 engine 解出 panelState/candles/tick 后调它们。host @MainActor 测试已是既有范式（TrainingEngineCoreTests/ActionsTests 经 `@testable` internal init），故 `make` 也可 host 测。

---

## 三、视口几何推导 ⚠️（spec 无公式，本 PR 决策）

spec（modules §C1a/§C8、plan §坐标映射）只给 `ChartViewport` 字段与 `CoordinateMapper` 数学，**未给** candleStep/candleWidth/visibleCount 从 bounds 的推导公式，也未给 tick/offset → startIndex/pixelShift 的装配。本 PR 决策（**标注 Wave 2 占位，pinch 缩放属 Wave 3/C8b**）：

### 3.1 几何（candleStep / candleWidth / gap）
- `mainChartFrame = ChartPanelFrames.split(in: bounds).mainChart`。
- `visibleCount = min(defaultVisibleCount, candles.count)`（默认 80，clamp 到可用根数；candles 为空走 .empty）。
- `candleStep = mainChartFrame.width / CGFloat(defaultVisibleCount)`（**用常量 80 而非 clamp 后的 visibleCount 当分母**，保证早期数据少时 candle 宽度稳定、不被拉伸铺满）。
- `candleWidth = candleStep * candleWidthRatio`（0.7）；`gap = candleStep - candleWidth`。
- **决策理由**：target-count 而非 fixed-width——count 固定便于推理与测试，且 C8a 无 pinch 缩放，固定 count 充分。bounds.width==0（layout 前）→ candleStep=0 → 走 .empty 守卫。
- **固定 80 分母的后果（F4）**：`candles.count < defaultVisibleCount` 时整屏放不满，candle 从**左**填充、最新 candle **不在右缘**（见 §3.2 条件锚定）。这是刻意的左对齐填充 UX（保 candle 宽度稳定），非 bug。

### 3.2 startIndex（autoTracking：数据足够锁最右；不足左对齐填充）
- 当前 candle 索引 `currentIdx` = **该面板自己 period** 的 candles 中首个 `endGlobalIndex >= tick`（超末根取末根 `count-1`）。
- **与 E5 `currentPrice` 仅 *谓词* 同款**（`首个 endGlobalIndex >= tick`）；**序列不同**：`currentPrice`/`price(...)`（TrainingEngine.swift L431-436）固定 `.m3` 驱动序列（避免聚合周期取未来价），而 C8a 锚定**面板自身 period**（.m60 面板必须在 .m60 序列定位，否则聚合面板锚错）。**勿据「同款」把面板锚改读 .m3**（C8a-8）。
- `baseStartIndex = currentIdx - (visibleCount - 1)`，随后 §3.3 clamp 到 `0 ... max(0, count - visibleCount)`。
- **条件锚定（F1 + R3-H1：区分「最右*被绘制*槽位」与「面板*物理*右缘」）**：autoTracking（offset=0）下当前 candle 的被绘制槽位 = `currentIdx - startIndex`。
  - **落面板物理右缘** ⟺ `count >= defaultVisibleCount`（visibleCount==80）**且** `currentIdx >= visibleCount - 1` → `startIndex = currentIdx - (visibleCount-1) >= 0`、槽位 == 79 == 物理右缘（标准 auto-tracking）。
  - **否则 `startIndex == 0`，当前 candle 落槽位 `currentIdx`**（< 物理右缘），两子情形：
    - `count < defaultVisibleCount`（历史不足，如聚合 `.m60` 早期）：visibleCount==count、upperBound==0 → startIndex 恒 0；`currentIdx==count-1`（最新）落**最右*被绘制*槽位（count-1）但非物理右缘**（其右侧 80-count 个槽位空着，因 candleStep 固定 = width/80）。
    - `count >= 80` 但 `currentIdx < visibleCount-1`（训练早期 tick 靠前）：baseStartIndex<0 → clamp 0；当前 candle 落槽位 currentIdx（左区），随 tick 推进右移直至锁物理右缘。
  - 故 §六 测试须按「count 是否 >=80」+「currentIdx 与 visibleCount-1 关系」三分流，**不**统一断言「落最右/物理右缘」。

### 3.3 offset 分解（freeScrolling：C8a 无非零 offset，但 builder 现在实现 + 测，C8b 直接喂）
- `panelState.offset`（pt，C8b 由 `offsetApplied` reducer 累积；符号契约见 `CoordinateMapper`：pixelShift>0 = candles 右移）。
- 整根位移 `wholeShift = floor(offset / candleStep)`；`unclampedStart = baseStartIndex - wholeShift`；
  `upperBound = max(0, candles.count - visibleCount)`；`startIndex = clamp(unclampedStart, 0 ... upperBound)`。
- pixelShift 余量 = `offset - CGFloat(wholeShift) * candleStep`（构造上 0 ≤ < candleStep）。
- **pixelShift 与边界协同（C8a-4 + F3：按 startIndex *落位* 判饱和，非按 clamp 是否改值）**：当 `startIndex == 0`（最老）**或** `startIndex == upperBound`（最新）即处硬边界、无更多可揭示 → **`pixelShift = 0`**（边缘 candle 钉面板边，不留空隙/不橡皮筋）；否则保留余量。
  - **为何不能仅判「clamp 是否改值」（F3）**：`unclampedStart` 恰好落在边界值（==0 或 ==upperBound）且带非零余量时，clamp **不改值**故旧逻辑走「保留余量」分支 → 边缘 candle 仍被 pixelShift 推离面板边留空隙。按落位判则覆盖此例。
- candleStep<=0 时跳过分解（已被 §四 `.empty` 守卫挡住，防除零）。
- 〔C8a 实际 offset 恒 0 → wholeShift=0、未 clamp 或仅 early-data 左 clamp、pixelShift=0；以上分解为 C8b 复用而**现在实现 + host 测**，非 C8a 运行期可达。〕

### 3.4 priceRange / 装配
- 可见切片 = `candles[clampedStart ..< min(clampedStart+visibleCount, candles.count)]`（ArraySlice）。
- `priceRange = PriceRange.calculate(from: 可见切片)`（含 BOLL/MA66 + 5% 扩展，Wave 0 冻结）。
- `ChartViewport(startIndex: clampedStart, visibleCount: 可见切片.count, pixelShift:, geometry:, priceRange:, mainChartFrame:)`。
  - 注：viewport.visibleCount 用**实际切片根数**（边界处可能 < 80），保证 mapper/draw 不越界。

---

## 四、buildRenderState（`RenderStateBuilder.make`）

```
panelState = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
candles    = engine.allCandles[panelState.period] ?? []     // 防御 ?? []（engine.make 已保证面板周期非空，但 builder 不信任）
guard !candles.isEmpty, bounds.width > 0, bounds.height > 0 else { return .empty }   // C8a-7：width>0 已含非零；加 height>0 防零高面板（priceToY 除以 frame.height）
viewport   = makeViewport(...)
slice      = candles[viewport.startIndex ..< viewport.startIndex + viewport.visibleCount]
volumeRange = NonDegenerateRange.make(values: [0.0] + slice.map { Double($0.volume) }, fallback: 0.0...1.0)
macdRange   = NonDegenerateRange.make(values: slice.flatMap { [$0.macdDiff, $0.macdDea, $0.macdBar].compactMap { $0 } },
                                      fallback: -0.001...0.001)
return KLineRenderState(panel: panelState, frames: ChartPanelFrames.split(in: bounds), viewport:,
                        visibleCandles: slice, volumeRange:, macdRange:,
                        markers: engine.markers, drawings: engine.drawings, crosshairPoint: nil)
```

- **crosshairPoint = nil**（长按十字光标属 C8b）。
- **markers/drawings** 直接透传 engine（drawings 在 C8a 渲染但激活属 C8b；E5 现有 `drawings` 为 init 注入值，C8a 只读渲染）。
- **C3–C6 收口**：volumeRange/macdRange 用 `NonDegenerateRange.make` + 下界 0 / nil·全零 fallback，字面对齐 modules L1443-1452。

---

## 五、ChartContainerView（UIKit glue）

```swift
// Render/ChartContainerView.swift
#if canImport(UIKit)
import SwiftUI; import UIKit
public struct ChartContainerView: UIViewRepresentable {
    let panel: PanelId
    @Bindable var engine: TrainingEngine
    public func makeUIView(context: Context) -> KLineView { KLineView(frame: .zero) }
    public func updateUIView(_ view: KLineView, context: Context) {
        view.renderState = RenderStateBuilder.make(engine: engine, panel: panel, bounds: view.bounds)
    }
}
#endif
```

- **spec 实现约束对齐**：不订阅 ObservationRegistrar（约束1）；靠 `@Bindable` 触发重建（约束2）；KLineView 只收值类型不持 @Observable（约束3）；buildRenderState 算值域（约束4，已下放 builder）；不监听 scenePhase（约束5）。
- `panel: PanelId` + `@Bindable engine`：与 spec L1420-1428 签名一致（spec L1421 字面 `let panel: PanelId`）。
- `bounds.width<=0`（首次 makeUIView 后 layout 前 bounds==.zero）→ builder 返 .empty → KLineView 画空，layout 后 SwiftUI 再次 updateUIView 刷新。

---

## 六、测试计划（host 全量；Catalyst 仅 build-for-testing）

`Tests/Render/RenderStateBuilderTests.swift`（Swift Testing）：
1. **几何**：给定 bounds + visibleCount → candleStep/candleWidth/gap 数值（容差，非整除浮点用 `isApproximatelyEqual`/abs 差，per `feedback_swift_local_toolchain_blindspot`）。
2. **startIndex 条件锚定（F1 + R3-H1，三分流）**：(a) `count>=80 且 currentIdx>=visibleCount-1`（tick 中段/末根）→ `startIndex==currentIdx-(visibleCount-1)`、当前 candle 落**物理右缘**（槽位 79）；(b) `count>=80 但 currentIdx<visibleCount-1`（tick 靠前）→ `startIndex==0`、当前 candle 槽位 currentIdx（左区，非右缘）；(c) **`count<80 且 currentIdx==count-1`（短聚合面板最新根，如 .m60 早期）→ `startIndex==0`、`viewport.visibleCount==count`、当前 candle 落最右*被绘制*槽位 `count-1` 但 `count-1 < defaultVisibleCount-1` 故非物理右缘**（R3-H1 补的测试 gap）。**不**统一断言「落最右」。
3. **聚合面板锚定（C8a-8）**：.m60 面板在 .m60 序列定位，断言右锚 candle ≠ 用 .m3 序列会得到的锚（防未来误改读 .m3）。
4. **offset 分解（C8b 复用数学，C8a 现测）**：正/负 offset → wholeShift + pixelShift（中段未达边界时 0≤pixelShift<candleStep）；边界 pixelShift==0 须覆盖**两种饱和**：(a) offset 把 startIndex *顶过* 0 / `upperBound`（clamp 改值）→ `pixelShift==0`；(b) **F3：offset 使 unclampedStart 恰好落在 0 或 upperBound 且带非零余量（clamp 不改值）→ 仍 `pixelShift==0`**（按落位判，非按 clamp 改值判）。左右两边界各测一次。
5. **可见切片边界**：startIndex+visibleCount 超数组 → 切片 clamp，viewport.visibleCount==实际根数。
6. **值域**：正常 / 全 nil macd → fallback / 全零 volume → fallback 下界 0 padding。
7. **空 / 退化**：candles 空 → .empty；bounds==.zero → .empty；bounds.width==0 / height==0 → .empty（防除零）。
8. **Equatable 短路前提（C8a-6 诚实化）**：同 engine 状态两次 `make` → 结果 `==`。**这是短路的*前提***——本 host 测**只**证 builder 输出相等，**不**证 `KLineView.renderState.didSet` 的 `guard != oldValue` 抑制了 `setNeedsDisplay()`（didSet 为 UIKit-only，host 不可跑）。didSet 实际抑制行为属 Catalyst/device 运行期，非 host 验证。
9. **perf smoke（C8a-5 诚实化，非权威）**：~5000 根 .m3 + 默认面板，`make` 单次 host 计时（记录实测毫秒，**非权威**）。⚠️ spec L1467「Instruments 120Hz **单帧 <4ms**」量的是 device 上**完整 `draw(_:)` 帧**（~600+ CG 调用），与 host `make()`（零 CoreGraphics）不同物、host≠device。故本测仅作装配开销 smoke；**spec 权威帧预算验证（device/sim 完整 draw）= 顺位-7 residual，归 C8b/顺位 9**（见 §一.4 traceability）。C8a checklist **不**得宣称 spec perf gate 已满足。

`ChartContainerView` 不写 host 行为测试（UIViewRepresentable 在 macOS host 无 SwiftUI 渲染管线）；其编译落 **Catalyst build-for-testing required check**。可加一个 `#if canImport(UIKit)` 编译期存在性 smoke（如 C1c `KLineViewCompileTests` 先例）。

---

## 七、验收 checklist（中文，action/expected/pass-fail；plan 阶段细化）
- buildRenderState 在 ~5000 根下 host 计时记录毫秒数（**装配开销 smoke，非权威**；spec「120Hz 单帧 <4ms」完整 draw 帧预算归 C8b/顺位 9，见 §一.4）。
- 相同 engine 状态两次 make → 结果相等（**Equatable 短路的*前提***；didSet 抑制 setNeedsDisplay 属 device 运行期，host 不验证）。
- volumeRange/macdRange 经 `NonDegenerateRange.make`（grep 锚定 + 测试断言 fallback）。
- 空数据 / layout 前 bounds（width 或 height <=0）→ .empty 不崩。
- swift test 全绿（host）+ Mac Catalyst build-for-testing required check 真过（不绕过）。

---

## 八、流程 / 评审策略（Task 0）
- **worktree 隔离**：`.claude/worktrees/wave2-p7-c8a-chart-render`（p2 P2-runner 并行中）。
- **评审通道**：本次 user 明确用 **Claude Opus 4.8 xhigh 对抗性 review**（设计 / plan / branch-diff 三道），非 codex（codex 周配额 + 本仓 iOS PR required check 为 Catalyst）。设计稿本身也走一道 opus 4.8 xhigh 对抗到收敛（user 2026-06-07）。
- **CI**：顺位 2-11 触 `Mac Catalyst build-for-testing on macos-15` required check；本地 swift test 绿 ≠ CI 绿（per `feedback_swift_local_toolchain_blindspot`：新 toolchain 漏 Sendable/字面浮点漂移，CI macos-15 才报）。
- **merge ceremony**：worktree 分支 attest 写 worktree-local ledger；主仓 `gh pr create`/`merge` 被 guard 拦 → user 真终端跑（per `feedback_worktree_local_ledger_user_tty_pr`）。

## 九、风险 / 待 review 攻击面
- **R1 视口几何无 spec 锚**：defaultVisibleCount=80 / ratio=0.7 是本 PR 占位决策；攻击点=数值合理性、early-data candle 宽度、Wave 3 pinch 改 count 的兼容。缓解：常量命名 + 注释标占位 + count 固定语义清晰。
- **R2 offset 分解在 C8a 无产生路径**：C8a 无 gesture 故 offset 恒 0；实现+测 offset 分解是为 C8b 不改 builder。攻击点=YAGNI vs 复用 seam。判定：builder 是 C8b H1 复用点，offset 分解是其核心数学，host 可测，纳入 C8a 合理（非投机）。**C8a-3/C8a-4 修订后** seam 成立：`visibleCandleRange` 委托 `makeViewport` 单一真相 + clamp/pixelShift 协同。
- **R3 startIndex/clamp 边界**：currentIdx 二分、负 startIndex clamp、超界切片——纯函数边界，测试矩阵覆盖。
- **R4 ChartContainerView host 不可测**：UIViewRepresentable 行为不在 host 验证，仅编译（Catalyst）。缓解：所有逻辑在 builder（host 测）；glue 极薄。
- **R5 drawings/markers 透传语义**：C8a 渲染 engine.drawings 但激活属 C8b；确认 C8a 只读透传不引入 drawing 状态机。

## 十、变更日志
| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-06-07 | v1 (draft) | brainstorming 落盘；D-split（C8a/C8b）+ D-loc（RenderStateBuilder）；视口几何占位决策；待 opus 4.8 xhigh 设计对抗 review |
| 2026-06-07 | v2 (opus 4.8 xhigh 设计 review R1 修) | **C8a-1**(H)：加 §1.4 顺位-7 residual traceability（C8b=顺位 7 子锚，逐项归属，无悬空）；**C8a-2**(H)：删 `make` 死参 `displayScale`（renderState 无该字段，亚像素在 draw 做，对齐 spec L1426）；**C8a-3**(M)：`visibleCandleRange` 委托 `makeViewport` 单一真相 + C8b 调用面标 provisional；**C8a-4**(M)：offset 分解 clamp/pixelShift 协同（饱和→pixelShift=0）；**C8a-5**(M)：perf 重锚——host `make` 计时仅 smoke 非权威，spec 120Hz 单帧帧预算归 C8b/顺位 9；**C8a-6**(L)：Equatable 验收诚实化（host 仅证输出相等前提，didSet 抑制属 device）；**C8a-7**(L)：guard 简化 width>0+height>0；**C8a-8**(L)：currentIdx 仅谓词同 currentPrice、序列为面板自身 period 非 .m3 + 加聚合面板锚定测试；**C8a-9**(L)：删 PanelId 混淆注释 |
| 2026-06-07 | v3 (opus 4.8 xhigh 设计 review R2 修) | **F1**(H)：「锁最右」只在 `currentIdx>=visibleCount-1` 成立——固定 80 分母下 `count<80` 或 tick 靠前时左对齐填充、最新非右缘；§3.2 改条件锚定 + §六-2 测试分流；**F2**(M)：删 §1.1 残留 `+ displayScale`（C8a-2 漏改）；**F3**(M)：clamp/pixelShift 饱和判据改**按 startIndex 落位**（==0 或 ==upperBound）非按 clamp 是否改值——堵 unclampedStart 恰落边界且带非零余量的漏洞；§六-4 加该 case；**F4**(L)：§3.1 显式注固定 80 分母 → count<80 左对齐填充语义 |
| 2026-06-07 | v4 (opus 4.8 xhigh 设计 review R3 修) | **R3-H1**(H)：F1 残留——`count<80 且 currentIdx==count-1`（短聚合面板最新根）下 §3.2 误称「落右缘」而 F4 称「不在右缘」、§六-2 测试 gap；§3.2 改为区分「最右*被绘制*槽位」vs「物理右缘」（物理右缘 ⟺ count>=80 且 currentIdx>=visibleCount-1）+ §六-2 加第三分流 (c) 子情形；R2 验证 F2/F3/F4 + 全冻结契约签名正确 |

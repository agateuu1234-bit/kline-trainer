# 划线 1a-iii · 切片 2「常驻样式面板 + 图标化 + 上下镜像」实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 逐 task 实施。步骤用 `- [ ]`。

**Goal:** 把「长按弹临时卡片」的样式设置改成**常驻样式面板**（类型行 + 5 组参数一体，底栏「类型」键开合、画线全程可随时改样式再接着画、记住上次工具与参数）；线型 / 线样式 / 粗细**画成图标不写文字**；面板可经类型行右端 **⇅** 手动切上 / 下半区（镜像）；删掉旧 `DrawingStyleCard`。

**Architecture:** 切片 1 已把「类型行」做成挂在 `ChartPanelsContainer` 上的 `.overlay(alignment: .bottom)` + 双层命中屏蔽。切片 2 在同一挂载点把 overlay 内容从「一行类型行」长成「整块样式面板」，并让挂载 alignment 随 `stylePanelPosition` 在 `.bottom` / `.top` 间切。
**关键安全前提**：面板一变高 / 一能上移，它就会盖住**上面板**，而切片 1 的盾**只装下面板**（`setShieldRect(..., panel: .lower)` 三处硬编码）→ 会出现「点面板却在上半 K 线误落一条线并 autosave」的不可逆缺陷。故本切片**先做盾的泛化（Task 2），再让面板变高 / 可移动（Task 3/4）**，全程不存在「无盾的大 overlay」窗口（延续切片 1 codex R5-high「禁 overlay-only 切片」的同一条红线）。
盾的泛化走**根因修法**：不按「面板停在哪就挡哪个 panel」硬编码，而是「overlay frame 与**每个**面板 frame 求交，交到谁就挡谁」——面板跨越上下两个面板时两个盾同时装，位置 / 高度怎么变都不用改判据。

**Tech Stack:** SwiftUI（`#if canImport(UIKit)`，host `swift test` 不编 View 体、Catalyst/iOS 编译并跑 hosted 测试）；swift-testing；hosted 几何测量统一用 `ImageRenderer` + PreferenceKey（**不得**用 `UIHostingController.makeKeyAndVisible()`——headless Catalyst 无 scene 会崩整个 runner，切片 1 已实证）；源码结构守卫作补充快检、不作达标判据。

## Global Constraints

- **契约不变**：`CONTRACT_VERSION` "1.11"、无 DB 迁移、**不新增任何枚举值 / 持久化键**。本切片一行持久化格式都不碰。
- **颜色语义本切片一律不动**（属切片 3）：颜色组**原样搬进新面板**——仍是 `DrawingColorToken.allCases` 全 9 色（含 `.black`/`.white`）、仍消费 `DrawingStyleAvailability.colorEnabled` 昼夜禁色灰态、仍经 `DrawingColorResolver.resolve` 取色板颜色。**不得**在本切片改成「7 彩 + 线色」、**不得**删 `colorEnabled`。
- **标注组维持文字**（spec §3 表格最后一行）：「隐藏 / 显示 / 左 / 右」仍是文字按钮 + 灰态；「无文字」只约束线型 / 线样式 / 粗细三组的**选项**，组名 caption（「线型」「线样式」「粗细」「颜色」「标注」）保留。
- **面板内绝不出现解释文案**：`不适用` / `不可用` / `N/A` / `暂不支持` 一个都不许有（母 spec §3 逐字要求，既有守卫 `noNotApplicableCopy` 必须随面板迁移、不得出现无守卫空窗）。
- 类型行本期**只渲染水平线 1 个图标、恒亮无 toggle**（D22/D38）；②锁定 / ③删除 / ④撤销 / ⑤前进**不渲染**（D19/D24）。mock 里第 2、3 个虚线工具图标只是 P1c 示意，**不实现**。
- **不动引擎 `buy/sell`**、D45「下单即隐式退出画线」不变量保持；交易边界只在 UI 层。
- 复盘仍走浮动铅笔钮、**不挂本面板、不装盾**（`showsTradeButtons` 门必须保留在 overlay 条件里）。
- 面板位置 / 展开态是**纯 UI 状态**，`@State` 存在视图里，**不落盘**（持久化全局默认属 P6）。样式默认值仍存 `DrawingSession.defaultStyle`、整局内存有效、不落盘。
- 既有 1a-i（D29/D35）/ 1a-ii（D39/D42/连续画线）/ 切片 1 全部测试**必须全绿、断言不改**（除本计划显式指明要迁移 / 改写的那几条）。
- 新增 / 删除测试后**必须**同步两个闸门基线，且**改法不同、别搞混**（已实测核实，非凭记忆）：
  - `.github/scripts/catalyst-uikit-baseline.txt`（现 43 行）：**脚本生成、不手写** —— `python3 .github/scripts/uikit-expected-tests.py > .github/scripts/catalyst-uikit-baseline.txt`。任何 `#if canImport(UIKit)` 下的 `@Test` 增 / 删 / 改名都要重跑。`catalyst-gate.test.sh` 会独立校验「签入基线 vs 当前源码现推导」是否漂移，手写必被抓。
  - `.github/scripts/catalyst-total-baseline.txt`（现 `1488`）：单个整数，**按真实构建日志的 `✔ Test run with N tests` 改**；闸门容差 ±30，小幅波动可不动，本切片新增测试较多、须实测后更新。
- **hosted 测量只能用 `ImageRenderer` + PreferenceKey**，且**被测子树必须是纯 SwiftUI**：树里一旦混入 `UIViewRepresentable`（如真 `TradeActionBar` 里的 segmented `Picker`），`ImageRenderer` 无法 flatten、整棵塌成 `frame=(0,0,0,0)` 假绿（切片 1 实测记录在 `DrawingLayoutInvariantTests.swift` 头部）。本切片新增的 `Canvas` 图标属纯 SwiftUI，但**Task 1 Step 6 必须先实测确认 `ImageRenderer` 能 flatten `Canvas`**，再往下走 Task 4 的几何断言。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| **Create** `Sources/KlineTrainerContracts/Drawing/DrawingStyleIconSpec.swift` | 图标的**纯数值规格**（dash pattern / 图标线宽表）。无 UIKit、非 View → host `swift test` 可覆盖。 |
| **Create** `Sources/KlineTrainerContracts/UI/DrawingStyleIcons.swift` | 三个图标 View（线型 / 线样式 / 粗细），只消费 `DrawingStyleIconSpec`。 |
| **Create** `Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift` | 5 组参数控件（读写 `session.defaultStyle`），从 `DrawingStyleCard` 平移改造而来。 |
| **Create** `Sources/KlineTrainerContracts/UI/DrawingStylePanel.swift` | 面板容器：按 `stylePanelPosition` 决定「类型行 ↔ 参数」两大块的上下顺序（镜像），组内顺序不翻。 |
| **Modify** `Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift` | 类型行加右端 **⇅** 按钮；去掉长按钩子 `onLongPressType`（卡片没了）。 |
| **Modify** `Sources/KlineTrainerContracts/UI/TrainingView.swift` | `ChartPanelsContainer`：盾泛化到两面板 + alignment 随位置切 + 挂 `DrawingStylePanel`；`TrainingView`：加 `stylePanelPosition` `@State`、删 `showingStyleCard` 与卡片 overlay、三处显式清盾改 `clearAllShields()`。 |
| **Modify** `Sources/KlineTrainerContracts/Drawing/DrawingSession.swift` | 加 `clearAllShields()`（internal），消灭「显式清盾时漏清某个面板」这一类错误。 |
| **Delete** `Sources/KlineTrainerContracts/UI/DrawingStyleCard.swift` | 被常驻面板替代（**守卫迁移通过后**才删）。 |
| **Modify/Rename** `Tests/.../Render/DrawingStyleCardSourceGuardTests.swift` → `DrawingStylePanelSourceGuardTests.swift` | 守卫改指新面板 + 加「无文字选项」「读 session 单一真相」断言。 |
| **Modify** `Tests/.../Render/DrawingTapHitShieldTests.swift` | `TrainingShellLayout` 改为**直接复用生产 `ChartPanelsContainer`**（不再手抄一份镜像接线）；新增两面板 / 上半区盾的差分测试。 |
| **Modify** `Tests/.../Render/DrawingLayoutInvariantTests.swift` | 三态几何断言扩到**四态**（+ 上半区展开）。 |
| **Create** `Tests/.../Drawing/DrawingStyleIconSpecTests.swift` | host 纯逻辑：dash 表两两不等、线宽严格递增。 |

---

## ⭐既有测试迁移矩阵（codex 计划-R7-F1 + 实施者穷尽 grep 补全）

**本切片改的是切片 1 刚立的接线，多条既有守卫会因此变成「要求旧形态」而与新断言互斥、或直接编译失败。**
下表是**穷尽 `grep -rn` 全仓核实**的结果（不是凭印象列的）。**每一条都必须在指定 task 内同步改掉，否则那个 task 过不了全量测试门**——这不是风格问题，是会红的硬门。

| 既有断言 / 引用 | 位置 | 断在 | 为什么断 | 改成 |
|---|---|---|---|---|
| `#expect(overlay.contains("onLongPressType"))` | `DrawingTapHitShieldTests.swift:93`（`splitBarsCarryD19D24`） | **Task 3** | 长按钩子被删，与新守卫 `longPressCardRetired` 互斥 | 改断言其**不存在** + 加 `onTogglePosition`（见 Task 3 Step 5b） |
| marker `"DrawingPanelFrameKey"` | `DrawingTapHitShieldTests.swift:76`（`typeRowIsShieldedOverlayNotVStackMember`） | **Task 2** | 改名 `DrawingLowerPanelFrameKey`——**旧名不是新名的子串**，`contains` 直接假 | 换成 `"DrawingLowerPanelFrameKey"` **并加** `"DrawingUpperPanelFrameKey"`（上面板也上报是本 task 的核心） |
| marker `"DrawingTypeOverlay("`（在 `containerBody` 内） | 同上 :76 | **Task 3** | 挂载点内容换成 `DrawingStylePanel(` | 换成 `"DrawingStylePanel("` |
| marker `".overlay(alignment: .bottom)"` | 同上 :76 | **Task 4** | 改成三元 `stylePanelPosition == .top ? .top : .bottom` | 换成 `".overlay(alignment: stylePanelPosition == .top ? .top : .bottom)"` |
| `ov.contains(".contentShape(Rectangle())")` 读 `UI/DrawingTypeOverlay.swift` | 同上 :83 | **Task 3** | 第一道盾上移到 `DrawingStylePanel`（整块面板统一吞点，留在类型行只护住一条） | 改读 `UI/DrawingStylePanel.swift`；与 `firstShieldPresentAndPrecedesPadding` 同向 |
| `ChartPanelsContainer(... onLongPressType: {} ...)` | `DrawingLayoutInvariantTests.swift:81` | **Task 3** | 容器签名变更 → **编译失败**（不是断言失败） | 去掉 `onLongPressType:`，补 `scheme:` / `stylePanelPosition:` / `onTogglePosition:` |
| `#expect(tv.contains("DrawingTypeOverlay(") && tv.contains(".accessibilityIdentifier(\"chartPanels\")"))` | `DrawingLayoutInvariantTests.swift:125`（`chartNotInExpandedBranch_sourceGuard`） | **Task 3** | `TrainingView` 挂载点换成 `DrawingStylePanel(` → 前半条失败（codex 计划-R8-F1） | 前半条换成 `tv.contains("DrawingStylePanel(")`；`.accessibilityIdentifier("chartPanels")` 那半条**不变**。若仍要证「类型行存在」，去 `DrawingStylePanel.swift` / `DrawingTypeOverlay.swift` 单独断言，别塞在这条 TrainingView 快检里 |
| `TrainingShellLayout` 手抄的 chartPanels 接线 | `DrawingTapHitShieldTests.swift:189-228` | **Task 2** | 改为直接复用生产 `ChartPanelsContainer`（消灭镜像漂移） | 见 Task 2 Step 1 |
| **全部 5 个 `ChartPanelsContainer(` 调用点** | `TrainingView.chartPanels:460` · `DrawingLayoutInvariantTests.chartFrame:76` · `TrainingShellLayout` · `TallPanelsShellLayout` · `ShortUpperShellLayout` | **Task 3** | 签名变更（去 `onLongPressType`，加 `scheme` / `stylePanelPosition` / `onTogglePosition`）→ **全部编译失败**（codex 计划-R9-F2） | 见下方「**容器签名定稿**」小节，5 处逐一按最终形态改 |

### 容器签名定稿（Task 3 起生效，5 个调用点全部照此）

```swift
// 最终签名（Task 3 落地；Task 4 只改 alignment、不再动签名）
struct ChartPanelsContainer<Upper: View, Lower: View>: View {
    let engine: TrainingEngine
    let showsTradeButtons: Bool
    let isDrawingActive: Bool
    let typeRowExpanded: Bool
    let scheme: AppColorScheme                    // 新增：面板色板取色（切片2 仍走 DrawingColorResolver）
    let stylePanelPosition: DrawingStylePanelPosition   // 新增：上/下半区
    let onTogglePosition: () -> Void              // 新增：⇅（替代已删的 onLongPressType）
    @ViewBuilder let upperPanel: () -> Upper
    @ViewBuilder let lowerPanel: () -> Lower
    ...
}
```
**测试外壳统一传法**（三个 hosted 外壳 + 布局不变量测试照抄，避免各写各的又漂移）：
```swift
            scheme: .light,                 // 测试固定日间，避免随宿主外观漂移
            stylePanelPosition: stylePanelPosition,   // 外壳自身的参数；无此参数的外壳传 .bottom
            onTogglePosition: {},           // 测试不驱动 ⇅（Task4 的位置切换靠**重新构造外壳值**渲染，非回调）
```
> **Task 2 阶段的过渡处理**：Task 2 时容器还是旧签名（无 `scheme`/`stylePanelPosition`/`onTogglePosition`，仍有 `onLongPressType`）。Task 2 新写的外壳**按当时签名接**（传 `onLongPressType: {}`、不传新三项）；**Task 3 改签名时，5 个调用点一次性全改**——这是 Task 3 的必做项，不是可延后项，否则 Catalyst 屏蔽测试当场编译失败。
| marker `"offsetBy"` | `DrawingTapHitShieldTests.swift:76` | — | `refreshShields` 仍用 `.offsetBy(dx:dy:)` 转局部坐标 | **不变**（已核实） |
| `tv.contains("showsTradeButtons, isDrawingActive, typeRowExpanded")` | 同上 :81 | — | 复盘门条件与顺序保持原样 | **不变**（已核实） |

> **实施纪律（R7/R8 两轮 finding 的共同根因对策）**：删 / 改名任何被守卫引用的符号**之前**，先跑下面这条**完整**命令，把所有引用列出来逐一处理：
> ```bash
> for s in 'DrawingTypeOverlay' 'onLongPressType' 'LongPressGesture' 'DrawingPanelFrameKey' \
>          'overlay(alignment: .bottom)' 'DrawingStyleCard' 'showingStyleCard' \
>          'DrawingBottomBar' 'ChartPanelsContainer' 'colorEnabled' 'DrawingStyleAvailability'; do
>   echo "=== $s ==="; grep -rn "$s" ios/Contracts/Tests ios/Contracts/Sources --include="*.swift"
> done
> ```
> **两轮的教训是叠加的**：R7 的 finding 是我只迁了 `DrawingStyleCardSourceGuardTests`、漏了另一文件的第二条守卫；我据此立了 grep 纪律并补出 5 条——但 **R8 又被抓到一条**（`DrawingLayoutInvariantTests.swift:125`），原因是**我自己跑的符号清单不完整**：grep 了 `onLongPressType` 等，却**没 grep 被替换的组件名 `DrawingTypeOverlay(` 本身**。所以上面的清单是**固定的、不许手挑**——要改的组件名、被删的参数名、被改名的类型名、被换掉的修饰符字面量，**四类都要在列**。
> **已交叉核实不受影响的**（本切片不动其语义，无需迁移）：`DrawingStyleAvailabilityTests` 的 6 条 `colorEnabled` 断言（颜色语义留切片 3）、`TrainingViewShellSourceGuardTests` 的 3 条 `DrawingBottomBar` 断言、`DrawingBottomBarHeightTests` 全部、`extractBody(... "struct ChartPanelsContainer<Upper: View, Lower: View>: View {" ...)` 锚（容器泛型签名不变）。
> **本表若在实施中发现遗漏项，补进表里再继续，不要就地改了了事**——表是下一个 task 的输入。

---

## Task 1: 图标规格 + 图标 View（线型 / 线样式 / 粗细「画出来」）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingStyleIconSpec.swift`
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStyleIcons.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingStyleIconSpecTests.swift`

**Interfaces:**
- Consumes（**关键：单一真相**）：`HorizontalLineTool.dashPattern(for: LineStyle) -> [CGFloat]` 与 `HorizontalLineTool.lineWidth(forThickness: Int) -> CGFloat`（`Drawing/HorizontalLineTool.swift:31-45`，`nonisolated static`、internal，同模块可直接调）——这是**真实渲染到 K 线上**的那份 dash / 线宽。
- Produces: `DrawingStyleIconSpec.dashPattern(for: LineStyle) -> [CGFloat]`（= 渲染层原值转发）、`DrawingStyleIconSpec.iconLineWidth(forThickness: Int) -> CGFloat`（= 渲染层线宽 × 放大系数）。
- Produces（Task 3 消费）：`LineSubTypeIcon(subType: LineSubType)`、`LineStyleIcon(style: LineStyle)`、`ThicknessIcon(thickness: Int)`——三个 `View`，颜色继承外层 `.foregroundStyle`（选中态染色由调用方给）。

> **⭐设计决定（Explore 交叉核实后修正原稿）**：`HorizontalLineTool` **已经**持有 dash / 线宽的真值（dash1 `[6,3]`、dash2 `[2,3]`、dash3 `[10,4]`、dash4 `[10,3,2,3]`；线宽 `1.0 + 0.5×档位` = 1.5→3.5pt）。计划原稿曾照设计 mock 的 SVG 值另起一张表——那会造成**两份真相**：面板里画的样子与真正落到 K 线上的线**不一致**，且以后调渲染值时图标不会跟着变（spec §3 要求的是「画出**真实**样子」）。故本 task 一律**从渲染层派生**：
> - **dash**：原值转发，一个数字都不改（30pt 图标画布足够展示这几种 pattern 的差异）。
> - **线宽**：真实 1.5→3.5pt 在 26pt 图标里五档几乎看不出差别，故按**固定放大系数**放大（保持严格单调 + 与渲染层同序），系数写在一处并有测试钉住「派生自渲染层、非独立表」。
> - **不再有 `isRoundCapped`**：渲染层没有圆端帽语义，图标凭空加一个就又是一处不一致。

- [ ] **Step 1: 写失败的 host 纯逻辑测试**

Create `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingStyleIconSpecTests.swift`:
```swift
// Tests/KlineTrainerContractsTests/Drawing/DrawingStyleIconSpecTests.swift
// Spec: 2026-07-18-drawing-tools-P1b-1a-iii-panel-redesign-design.md §3（图标化：把样式「画出来」）。
// 这些是纯数值规格（无 UIKit / 非 View）→ 跑于 host swift test，防「5 个档位画出来长得一模一样」的假绿。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("图标规格：派生自渲染层真值，且五档两两可区分（1a-iii 切片2 Task1）")
struct DrawingStyleIconSpecTests {

    @Test("dash 图标就是**渲染层真值**原样转发——面板里画的虚线与真正落到 K 线上的虚线一致（防两份真相）")
    func dashPatternMirrorsRenderer() throws {
        for style in LineStyle.allCases {
            #expect(DrawingStyleIconSpec.dashPattern(for: style)
                    == HorizontalLineTool.dashPattern(for: style),
                    "\(style) 的图标 dash 与渲染层不一致 —— 面板在骗人")
        }
    }

    @Test("5 种线样式的 dash pattern 两两不等——任何两档画出来都不会一样")
    func dashPatternsArePairwiseDistinct() throws {
        let all = LineStyle.allCases
        for i in all.indices {
            for j in all.indices where j > i {
                #expect(DrawingStyleIconSpec.dashPattern(for: all[i])
                        != DrawingStyleIconSpec.dashPattern(for: all[j]),
                        "\(all[i]) 与 \(all[j]) 的 dash pattern 相同 → 图标不可区分")
            }
        }
    }

    @Test("实线 dash 为空、四档虚线非空（实线不得画成虚的）")
    func solidHasNoDash() throws {
        #expect(DrawingStyleIconSpec.dashPattern(for: .solid).isEmpty)
        for s in LineStyle.allCases where s != .solid {
            #expect(!DrawingStyleIconSpec.dashPattern(for: s).isEmpty)
        }
    }

    @Test("图标线宽**派生自**渲染层线宽（同一放大系数），不是另写一张表——渲染层改了图标自动跟着改")
    func iconLineWidthIsDerivedFromRenderer() throws {
        for t in 1...5 {
            #expect(DrawingStyleIconSpec.iconLineWidth(forThickness: t)
                    == HorizontalLineTool.lineWidth(forThickness: t) * DrawingStyleIconSpec.iconWidthAmplification,
                    "第 \(t) 档图标线宽不是渲染层线宽的等比放大 → 两份真相")
        }
    }

    @Test("粗细 1…5 的图标线宽严格递增且够粗看得出差别——不是 5 根几乎同宽的线")
    func iconLineWidthStrictlyIncreasesAndIsLegible() throws {
        let widths = (1...5).map { DrawingStyleIconSpec.iconLineWidth(forThickness: $0) }
        for i in 1..<widths.count {
            #expect(widths[i] > widths[i - 1], "第 \(i + 1) 档线宽未大于第 \(i) 档：\(widths)")
        }
        #expect(widths.allSatisfy { $0 > 0 })
        // 放大的意义就在于肉眼可辨：最粗与最细至少差 3pt，否则面板上五档看起来一样、放大系数形同虚设。
        #expect(widths.last! - widths.first! >= 3, "五档跨度仅 \(widths.last! - widths.first!)pt，肉眼分不出")
    }

    @Test("越界档位 fail-closed 得到正数宽度（坏输入不产出 0 宽 / 负宽的不可见图标）")
    func outOfRangeThicknessClampsToPositiveWidth() throws {
        for t in [-3, 0, 6, 99] {
            #expect(DrawingStyleIconSpec.iconLineWidth(forThickness: t) > 0)
        }
    }
}
```

- [ ] **Step 2: 运行 → 确认失败**

Run: `cd ios/Contracts && swift test --filter DrawingStyleIconSpecTests`
Expected: FAIL（`DrawingStyleIconSpec` 未定义 → 编译不过）。**「no tests matched」也判失败**（测试没跑 = 没证据）。

- [ ] **Step 3: 实现 `DrawingStyleIconSpec`（纯数值，无 UIKit）**

Create `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingStyleIconSpec.swift`:
```swift
// Sources/KlineTrainerContracts/Drawing/DrawingStyleIconSpec.swift
// 1a-iii 切片2 Task1：样式面板图标的**纯数值规格**，全部**派生自渲染层 HorizontalLineTool**。
//
// ⭐为什么不照设计 mock 另写一张表：`HorizontalLineTool` 已经持有真正画到 K 线上的 dash / 线宽
// （dashPattern(for:) / lineWidth(forThickness:)）。图标另起一张表 = 两份真相：面板里展示的样子会与
// 用户真正画出来的线不一致，且以后调渲染值时图标不会跟着变——而 spec §3 要的恰恰是「画出**真实**样子」。
// 故 dash **原样转发**；线宽因真实值（1.5→3.5pt）在 26pt 图标里五档几乎看不出差别，按**单一放大系数**
// 等比放大（保持与渲染层同序、严格单调，DrawingStyleIconSpecTests 钉死「派生关系」本身）。
//
// 放在非-View 的 enum 里 → host swift test 可直接覆盖（View 体在 host 上根本不编译，测不到）。
import CoreGraphics

public enum DrawingStyleIconSpec {

    /// 图标线宽相对**渲染层真实线宽**的放大系数。唯一的自由数值，改它即整排图标同步变化。
    /// 取 2.0：真实 1.5…3.5pt → 图标 3…7pt，五档跨度 4pt，26pt 画布里肉眼可辨且不糊成一坨。
    public static let iconWidthAmplification: CGFloat = 2.0

    /// 线样式图标的 dash pattern = **渲染层真值原样转发**（实线 = 空数组）。
    /// 不在此处做任何缩放/改写——面板画的必须就是用户会得到的。
    public static func dashPattern(for style: LineStyle) -> [CGFloat] {
        HorizontalLineTool.dashPattern(for: style)
    }

    /// 粗细档位 → 图标线宽 = 渲染层线宽 × 放大系数（画**真实粗细**的相对关系，不写数字）。
    /// 越界档位由 `HorizontalLineTool.lineWidth` 内部 clamp(1...5) 兜住 → 恒为正数，绝不产出不可见图标。
    public static func iconLineWidth(forThickness thickness: Int) -> CGFloat {
        HorizontalLineTool.lineWidth(forThickness: thickness) * iconWidthAmplification
    }
}
```

- [ ] **Step 4: 运行 → 通过**

Run: `cd ios/Contracts && swift test --filter DrawingStyleIconSpecTests`
Expected: PASS（4 个测试全绿）

- [ ] **Step 5: 实现三个图标 View**

Create `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStyleIcons.swift`:
```swift
// Sources/KlineTrainerContracts/UI/DrawingStyleIcons.swift
// 1a-iii 切片2 Task1：线型 / 线样式 / 粗细的「画出来」图标（spec §3：面板内这三组不写文字）。
// 数值规格全部来自 DrawingStyleIconSpec（单一真相，host 可测）；本文件只负责把它画出来。
// 颜色继承外层 foregroundStyle（选中态染色由 DrawingStyleParams 给），故图标本身不写死颜色。
#if canImport(UIKit)
import SwiftUI

/// 线型：直线 = 一段实线；射线 = 起点圆点 + 朝右箭头；线段 = 两端带端点竖杠。
struct LineSubTypeIcon: View {
    let subType: LineSubType
    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            switch subType {
            case .straight:
                var p = Path()
                p.move(to: CGPoint(x: 2, y: midY)); p.addLine(to: CGPoint(x: size.width - 2, y: midY))
                ctx.stroke(p, with: .style(.foreground), lineWidth: 2)
            case .ray:
                var line = Path()
                line.move(to: CGPoint(x: 4, y: midY)); line.addLine(to: CGPoint(x: size.width - 4, y: midY))
                ctx.stroke(line, with: .style(.foreground), lineWidth: 2)
                ctx.fill(Path(ellipseIn: CGRect(x: 1.6, y: midY - 2.4, width: 4.8, height: 4.8)),
                         with: .style(.foreground))                       // 起点圆点
                var arrow = Path()                                        // 朝右箭头
                arrow.move(to: CGPoint(x: size.width - 6, y: midY - 4))
                arrow.addLine(to: CGPoint(x: size.width, y: midY))
                arrow.addLine(to: CGPoint(x: size.width - 6, y: midY + 4))
                arrow.closeSubpath()
                ctx.fill(arrow, with: .style(.foreground))
            case .segment:
                var p = Path()
                p.move(to: CGPoint(x: 5, y: midY)); p.addLine(to: CGPoint(x: size.width - 5, y: midY))
                p.move(to: CGPoint(x: 5, y: midY - 4)); p.addLine(to: CGPoint(x: 5, y: midY + 4))
                p.move(to: CGPoint(x: size.width - 5, y: midY - 4))
                p.addLine(to: CGPoint(x: size.width - 5, y: midY + 4))
                ctx.stroke(p, with: .style(.foreground), lineWidth: 2)
            }
        }
        .frame(width: 30, height: 14)
        .accessibilityHidden(true)     // 可访问性标签挂在外层按钮上（选项语义），图标本身不重复播报
    }
}

/// 线样式：各画一小段真实 dash（实线 + 虚线 1~4）。
struct LineStyleIcon: View {
    let style: LineStyle
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 2, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
            ctx.stroke(p, with: .style(.foreground),
                       style: StrokeStyle(lineWidth: 2,
                                          dash: DrawingStyleIconSpec.dashPattern(for: style)))
        }
        .frame(width: 30, height: 12)
        .accessibilityHidden(true)
    }
}

/// 粗细：5 档各画**真实粗细**的一条线（非数字）。
struct ThicknessIcon: View {
    let thickness: Int
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 2, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
            ctx.stroke(p, with: .style(.foreground),
                       lineWidth: DrawingStyleIconSpec.iconLineWidth(forThickness: thickness))
        }
        .frame(width: 26, height: 14)
        .accessibilityHidden(true)
    }
}
#endif
```

- [ ] **Step 6: 运行全量 host + Catalyst 编译 + ⚠️`ImageRenderer` 能否 flatten `Canvas` 的前置实测**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: 全绿（新增 6 个 host 测试）。
Run（Catalyst 编译，确认 View 体在真 toolchain 下能编——host 不编 `#if canImport(UIKit)` 体，是本仓踩过的盲区）：
`cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

**⚠️阻塞级前置实测（现在做，别等到 Task 4 才发现）**：切片 1 实测过——被 `ImageRenderer` 渲染的子树里只要混进 `UIViewRepresentable`，整棵会塌成 `frame=(0,0,0,0)` 的**假绿**。`Canvas` 是纯 SwiftUI，理论上没问题，但**没实测过**。

> ⚠️**本探针触 SwiftUI/UIKit 类型，必须放在 UIKit-gated 段并补齐 import 与 helper**（codex 计划-R13-F1：原稿把它塞进只 `import Foundation/Testing` 的文件，还引用了从未定义的 `IconProbeFrameBox` —— **又一次「声称了没写」**，同 R3-F1）。**放在文件末尾独立的 `#if canImport(UIKit)` 段**：

```swift
#if canImport(UIKit)
import SwiftUI
import UIKit

/// `onPreferenceChange` 写入的接收盒（本文件专用；`DrawingLayoutInvariantTests` 里的同款是 private、跨文件不可见）。
@MainActor
private final class IconProbeFrameBox {
    var rect: CGRect?
}

/// 本文件专用测量 key（不复用 `ChartPanelsFrameKey`——那是布局不变量测试的语义，别混用）。
private struct IconProbeFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

@Suite("图标渲染（Catalyst，1a-iii 切片2 Task1）")
@MainActor
struct DrawingStyleIconRenderTests {

    @Test("前置实测：ImageRenderer 能 flatten Canvas 图标（子树不塌成零尺寸）——Task4 几何断言的前提")
    func imageRendererFlattensCanvasIcons() throws {
        let box = IconProbeFrameBox()
        let probe = HStack { LineStyleIcon(style: .dash1); ThicknessIcon(thickness: 5) }
            .coordinateSpace(name: "probe")
            .overlay { GeometryReader { g in Color.clear
                .preference(key: IconProbeFrameKey.self, value: g.frame(in: .named("probe"))) } }
            .onPreferenceChange(IconProbeFrameKey.self) { box.rect = $0 }
        let r = ImageRenderer(content: probe); r.scale = 1; _ = r.uiImage
        let f = try #require(box.rect)
        #expect(f.width > 0 && f.height > 0, "Canvas 子树被 ImageRenderer 塌成零尺寸 → Task4 几何断言会假绿")
    }

    // ⭐codex 计划-R13-F2：**没有这组测试，画白板也能全绿**——源码守卫只查符号在不在、文字有没有，
    //   flatten 探针只查 frame 非零，**没有一条验证真的画出了像素**。Canvas 实现写错（描边色、
    //   零长路径、坐标算错）就会 ship 三排空白方块，而本切片的全部意义正是「用户能看见并分辨这些图标」。
    //   故读真实像素：白底 + 黑前景渲染，统计墨点数与像素签名。

    /// 渲染一个图标到 8-bit 灰度位图，返回（墨点数, 像素签名）。白底黑线 → 暗像素即墨。
    private func inkSignature<V: View>(_ view: V, size: CGSize) throws -> (ink: Int, bytes: [UInt8]) {
        let renderer = ImageRenderer(content:
            view.foregroundStyle(.black)
                .frame(width: size.width, height: size.height)
                .background(.white))
        renderer.scale = 1
        let cg = try #require(renderer.uiImage?.cgImage, "图标渲染不出位图")
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h)
        let ctx = try #require(CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (buf.filter { $0 < 128 }.count, buf)
    }

    @Test("像素级：三种线型图标都**真的画出了东西**，且两两可分辨（防 ship 空白方块）")
    func lineSubTypeIconsRenderDistinctInk() throws {
        var sigs: [LineSubType: [UInt8]] = [:]
        for s in LineSubType.allCases {
            let (ink, bytes) = try inkSignature(LineSubTypeIcon(subType: s), size: CGSize(width: 30, height: 14))
            #expect(ink > 0, "\(s) 图标是空白的 —— 用户看到的是个空框")
            sigs[s] = bytes
        }
        let all = LineSubType.allCases
        for i in all.indices { for j in all.indices where j > i {
            #expect(sigs[all[i]] != sigs[all[j]], "\(all[i]) 与 \(all[j]) 画出来一模一样，用户分不出")
        } }
    }

    @Test("像素级：5 种线样式都画出东西，且两两可分辨（dash 真的落到像素上）")
    func lineStyleIconsRenderDistinctInk() throws {
        var sigs: [LineStyle: [UInt8]] = [:]
        for s in LineStyle.allCases {
            let (ink, bytes) = try inkSignature(LineStyleIcon(style: s), size: CGSize(width: 30, height: 12))
            #expect(ink > 0, "\(s) 图标是空白的")
            sigs[s] = bytes
        }
        // 实线墨最多（无空档）——顺带验证 dash 真的在断线，而不是被忽略后全画成实线。
        let solidInk = try inkSignature(LineStyleIcon(style: .solid), size: CGSize(width: 30, height: 12)).ink
        for s in LineStyle.allCases where s != .solid {
            let ink = try inkSignature(LineStyleIcon(style: s), size: CGSize(width: 30, height: 12)).ink
            #expect(ink < solidInk, "\(s) 的墨量不少于实线 —— dash pattern 没生效，五档看起来都是实线")
        }
        let all = LineStyle.allCases
        for i in all.indices { for j in all.indices where j > i {
            #expect(sigs[all[i]] != sigs[all[j]], "\(all[i]) 与 \(all[j]) 画出来一模一样，用户分不出")
        } }
    }

    @Test("像素级：粗细 1…5 的墨量**严格递增**（图标真的越来越粗，不是 5 根同宽线）")
    func thicknessIconsRenderIncreasingInk() throws {
        let inks = try (1...5).map {
            try inkSignature(ThicknessIcon(thickness: $0), size: CGSize(width: 26, height: 14)).ink
        }
        #expect(inks.allSatisfy { $0 > 0 }, "有档位画成了空白：\(inks)")
        for i in 1..<inks.count {
            #expect(inks[i] > inks[i - 1], "第 \(i + 1) 档墨量未多于第 \(i) 档：\(inks) —— 粗细没体现在像素上")
        }
    }
}
#endif
```
> **这三条是 Task 1 的达标判据**（源码守卫与 flatten 探针都只是辅助）：它们是「用户真能看见并分辨图标」这件事唯一的机器可查证据，直接对应 §4.4 里那条「线型/线样式/粗细都是**画出来的图标**」。
> **实施注意**：若某条因抗锯齿/渲染精度在 Catalyst 上不稳（例如相邻档墨量只差 1-2 像素），**允许调整图标画布尺寸或放大系数拉开差距，但不许把「严格递增」改成「不减」、也不许删掉两两可分辨断言**——那等于把这条守卫的价值清零。
Run（⭐codex 计划-R14-F3：**必须同时跑 `DrawingStyleIconRenderTests`**——原稿只 filter 了 `…IconSpecTests`，那会让刚加的「图标不是空白」像素证据**根本不被执行**）：
```bash
cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:KlineTrainerContractsTests/DrawingStyleIconSpecTests \
  -only-testing:KlineTrainerContractsTests/DrawingStyleIconRenderTests 2>&1 | tail -20
```
Expected: PASS（两个 suite 都出现在通过清单里；**任一 suite「no tests matched」判失败**）。
**若实测 FAIL**（`Canvas` 真的 flatten 不了）：这是**阻塞级 escalation**——回报 controller，不得私自把 Task 4 的几何断言降级成源码守卫（切片 1 codex 计划-R1 红线）。备选方向：图标改用 `Path`/`Shape` + `.stroke`（更原生、更可能被 flatten），或几何断言改测不含图标的容器外框。**由 codex/user 裁决，实施者不自决。**

- [ ] **Step 7: 同步 Catalyst 基线（codex 计划-R14-F3：本 task 新增了 UIKit-gated 测试，不同步必闸门红）**

本 task 新增 `DrawingStyleIconRenderTests` 的 4 个 `#if canImport(UIKit)` 测试 → uikit 基线与 total 基线都会漂。**必须在 commit 前同步**（否则下一个 task 一跑全量闸门就红，还得回头查是谁引入的）：
```bash
# uikit 基线：脚本生成、不手写
python3 .github/scripts/uikit-expected-tests.py > .github/scripts/catalyst-uikit-baseline.txt
git diff --stat .github/scripts/catalyst-uikit-baseline.txt    # 核一眼：增量应正好等于本 task 新增的 UIKit-gated 测试
# total 基线：按真实日志计数
cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:KlineTrainerContractsTests 2>&1 | tee /tmp/cat-slice2-t1.log | tail -5
grep -o '✔ Test run with [0-9]* tests' /tmp/cat-slice2-t1.log | tail -1   # 据此更新 catalyst-total-baseline.txt
bash .github/scripts/catalyst-gate.test.sh                                # 自测（会校验基线与源码是否漂移）
bash .github/scripts/catalyst-gate.sh /tmp/cat-slice2-t1.log              # 期望 GATE PASS
```

- [ ] **Step 8: Commit**
```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingStyleIconSpec.swift \
        ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStyleIcons.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingStyleIconSpecTests.swift \
        .github/scripts/catalyst-uikit-baseline.txt .github/scripts/catalyst-total-baseline.txt
git commit -m "划线1a-iii切片2 Task1：线型/线样式/粗细图标化（数值派生自渲染层 + 像素级非空白/可分辨证据）"
```

---

## Task 2: 命中屏蔽泛化到**两个面板**（安全地基，必须先于面板变高 / 可移动）

> **为什么必须排在 Task 3/4 之前**：切片 1 的盾三处硬编码 `panel: .lower`。面板一长高（5 组参数 ~200pt）就会从下面板溢进上面板；一支持 ⇅ 上移就整块坐在上面板上。此时上面板**无盾** → 点面板参数的空隙会在上半 K 线**误落一条线并 autosave（不可逆）**。这与切片 1 codex R5-high「引入 overlay 的 PR 必须同带命中屏蔽」是同一条红线：**防护先行，绝不留无盾窗口**。
>
> **另一条本 task 必修的真 bug**：`TrainingView` 三处显式清盾（`onChange(drawingModeActive)` / `onChange(typeRowExpanded)` / `onDisappear`）目前只清 `.lower`。盾泛化后若不一并修，上面板的盾会**残留** → 上半 K 线出现「怎么点都画不了线」的死区。改法是加 `DrawingSession.clearAllShields()` 让「漏清某个面板」在结构上不可表达，而不是在三处各补一行。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift`（加 `clearAllShields()`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（`ChartPanelsContainer` 盾泛化；`TrainingView` 三处清盾改 `clearAllShields()`）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingTapHitShieldTests.swift`（`TrainingShellLayout` 改为复用生产 `ChartPanelsContainer`；新增两面板盾的差分测试）

**Interfaces:**
- Consumes: 切片 1 的 `DrawingSession.setShieldRect(_:panel:)` 与 `handleDrawingTap` 的 `shieldRect[key].contains(point)` 守卫——**本切片将两者一并替换为 `PanelShield` 三态 API**（见 Step 3），旧 API 实施后不再存在。
- Produces: `DrawingSession.clearAllShields()`（internal）。
- Produces: 生产 PreferenceKey `DrawingUpperPanelFrameKey` / `DrawingLowerPanelFrameKey` / `DrawingShieldFrameKey`（值均 `CGRect?`、`defaultValue = nil`）。
- Produces（Task 3/4 消费）：`ChartPanelsContainer` 内部 `refreshShields()`——三个 frame 任一变化都重算，overlay frame 与**每个**面板 frame 求交、转该面板局部坐标后装盾；不相交则清该面板的盾。

- [ ] **Step 1: 写失败的差分测试（两面板盾 + 清盾无残留）**

先把 `DrawingTapHitShieldTests.swift` 里私有的 `TrainingShellLayout` 改成**直接复用生产容器**（消灭「测试自抄一份接线、悄悄与生产漂移」的假绿面——切片 1 已把它记为 Minor 待偿）：
```swift
/// 1a-iii 切片2 Task2：不再手抄一份 chartPanels 接线（切片 1 遗留的镜像风险，reviewer 记为 Minor）。
/// 直接渲染**生产** `ChartPanelsContainer`，只把上下面板换成等尺寸占位——盾的整条链
/// （GeometryReader → PreferenceKey → refreshShields → setShield）测的就是生产那一份。
@MainActor
private struct TrainingShellLayout: View {
    let engine: TrainingEngine
    var typeRowExpanded: Bool = true
    var stylePanelPosition: DrawingStylePanelPosition = .bottom   // Task 3 引入；本 task 先固定 .bottom

    private var showsTradeButtons: Bool { engine.flow.canBuySell() }
    private var isDrawingActive: Bool { engine.drawingSession.drawingModeActive }

    var body: some View {
        ChartPanelsContainer(
            engine: engine,
            showsTradeButtons: showsTradeButtons,
            isDrawingActive: isDrawingActive,
            typeRowExpanded: typeRowExpanded,
            stylePanelPosition: stylePanelPosition,
            upperPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: shieldTestUpperPanelHeight) },
            lowerPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: shieldTestLowerPanelHeight) })
            .frame(width: shieldTestPanelWidth)
    }
}
```
**再加一套「双高面板」fixture 与外壳**（codex 计划-R1-F1/F3 要求：只有让面板**整块装得进单个面板**，才能测「不过度屏蔽」与「切位置后旧盾清空」这两条精确判据）：
```swift
/// 双高面板 fixture：上下面板都足够高，使展开的样式面板**整块**落在其中一个面板内
/// （下半区 ⇒ 只碰下面板；上半区 ⇒ 只碰上面板）。与既有 60/40 矮 fixture 分工：
///   - 矮 fixture（shieldTestUpperPanelHeight/LowerPanelHeight）：测「面板跨越两面板 ⇒ 两个盾都装」。
///   - 本 fixture：测「面板只碰一个面板 ⇒ 另一个面板必须无盾」+「切位置后旧盾必须清空（== nil，非『矮一点』）」。
/// 400 是起始值——若实测样式面板高于它，测试里的 #require 会明确报错要求调大（**不许猜、不许把断言改松**）。
private let shieldTestTallPanelHeight: CGFloat = 400

@MainActor
private struct TallPanelsShellLayout: View {
    let engine: TrainingEngine
    var typeRowExpanded: Bool = true
    var stylePanelPosition: DrawingStylePanelPosition = .bottom

    var body: some View {
        ChartPanelsContainer(
            engine: engine,
            showsTradeButtons: engine.flow.canBuySell(),
            isDrawingActive: engine.drawingSession.drawingModeActive,
            typeRowExpanded: typeRowExpanded,
            stylePanelPosition: stylePanelPosition,
            upperPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: shieldTestTallPanelHeight) },
            lowerPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: shieldTestTallPanelHeight) })
            .frame(width: shieldTestPanelWidth)
    }
}
```

> ⚠️ 本 task 里 `ChartPanelsContainer` 还没有 `stylePanelPosition` 参数（Task 3 才加），也还没去掉 `onLongPressType`（Task 3 才去）。**实施顺序**：本 step 先按**当前**签名接（去掉 `stylePanelPosition:` 那行、补 `onLongPressType: {}`），Task 3 改签名时同步更新这里。计划里写成最终形态是为了让 Task 3 的实施者看到目标；**实施者以「当前编译得过」为准**，不得为了对齐本文片段而提前引入未定义类型。

新增测试（追加到 `DrawingTapHitShieldTests` suite 内）：
```swift
    @Test("模型不变量：clearAllShields() 清空所有面板的盾（防显式清盾时漏清某个面板留下死区）")
    func clearAllShieldsClearsBothPanels() throws {
        let session = DrawingSession()
        session.setShield(.rect(CGRect(x: 0, y: 0, width: 390, height: 80)), panel: .upper)
        session.setShield(.rect(CGRect(x: 0, y: 0, width: 390, height: 80)), panel: .lower)
        session.clearAllShields()
        #expect(session.shieldRect.isEmpty)
    }

    @Test("盾泛化真路径（trade-safety）：overlay 高到跨越上下两面板 → **两个**面板各自装盾，上面板不再裸奔")
    func tallOverlayShieldsBothPanels() throws {
        let (_, engine) = makeDrawingActiveChart()
        // 下面板仅 40pt 高、上面板 60pt；样式面板（类型行 + 5 组参数）必然高于 40pt → 必跨进上面板。
        renderAndConverge(TrainingShellLayout(engine: engine, typeRowExpanded: true))
        let lower = try #require(shieldRectOf(engine, 1), "下面板盾缺失")
        let upper = try #require(shieldRectOf(engine, 0),
                                 "上面板盾缺失 —— overlay 已探进上面板却无盾 = 点面板会在上半 K 线误落线")
        #expect(!lower.isEmpty && !upper.isEmpty)
        // 盾是**该面板局部**坐标：上面板盾必须贴着上面板底边（overlay 从下往上探进来的那一截），
        // 而不是原封不动的 chart 空间坐标（后者会把偏移一起带进来、挡错地方）。
        #expect(upper.maxY <= shieldTestUpperPanelHeight + 0.5)
    }

    @Test("收起态：无 overlay → 两面板都无盾（基础清盾，**不算**不过度屏蔽的证据）")
    func collapsedOverlayInstallsNoShield() throws {
        let (_, engine) = makeDrawingActiveChart()
        renderAndConverge(TrainingShellLayout(engine: engine, typeRowExpanded: false))
        #expect(shieldRectOf(engine, 0) == nil)
        #expect(shieldRectOf(engine, 1) == nil)
    }

    @Test("不过度屏蔽（codex 计划-R1-F1）：面板**可见且完全落在下面板内**时，上面板必须无盾、且上半 K 线照常落线")
    func visibleLowerOnlyOverlayLeavesUpperUnshielded() throws {
        // ⭐codex 计划-R1-F1：原稿这条用 typeRowExpanded:false（根本没 overlay）→ **空测试**：
        //   一个「只要有可见 overlay 就连上面板一起装盾」的错误实现照样能过，上半 K 线死区测不出来。
        //   必须让 overlay **真的可见**、且**整块落在下面板内**，才能证明「交到谁才挡谁」。
        // 故用双高面板 fixture（上下都 tallPanelHeight），下半区面板整块装得下。
        let (upperHandle, engine) = makeDrawingActiveChart(
            panel: .upper, bounds: CGRect(x: 0, y: 0, width: shieldTestPanelWidth, height: shieldTestTallPanelHeight))
        renderAndConverge(TallPanelsShellLayout(engine: engine, typeRowExpanded: true, stylePanelPosition: .bottom))

        let lower = try #require(shieldRectOf(engine, 1), "下半区时下面板必须有盾")
        // 前提自检：面板必须**真的装得下**在下面板内——否则本测试退化成「跨面板」场景、又变空测。
        try #require(lower.height < shieldTestTallPanelHeight,
                     "样式面板高于 fixture 面板高度 → 请调大 shieldTestTallPanelHeight（先打印实测高度，别猜）")
        #expect(engine.drawingSession.shield[0] == .unshielded,
                "上面板未处于 .unshielded（可能是 .pending 或被装了盾） —— overlay 明明没碰到上面板，属过度屏蔽（上半 K 线会出现死区）")
        // 差分正向：上半 K 线真能落线（光断言 shield==nil 不够，要证明「点得下去」）。
        let c0 = engine.drawings.count
        upperHandle.handleDrawingTapForTesting(at: leftmostMainChartPoint(upperHandle))
        #expect(engine.drawings.count == c0 + 1, "上半 K 线落不了线 —— 存在看不见的屏蔽")
    }

    @Test("上面板差分（trade-safety）：上面板被盾覆盖的、**本可落线**的点——装盾时被拒、清盾时落线")
    func upperPanelShieldBlocksOtherwiseCommittingTap() throws {
        // ⭐codex 计划-R5-F1：本 task 的 overlay 还是切片1 那个**矮**类型行（~44pt，Task3 才长高），
        //   且贴底对齐。用「上60/下40」fixture 时它只探进上面板底部几点，而可落线的 mainChart 是面板
        //   **顶部 60%** → 采样点必然落在 mainChart 外，`#require` 因**fixture 几何**而红、与产品行为无关。
        //   正确方向是把上面板**改矮**（不是原稿说的「调大」——那让贴底薄片离顶部 60% 更远，方向反了），
        //   矮到 44pt 的贴底 overlay 能把整个上面板连同其 mainChart 一起盖住。
        let (handle, engine) = makeDrawingActiveChart(panel: .upper,
                                                      bounds: CGRect(x: 0, y: 0,
                                                                     width: shieldTestPanelWidth,
                                                                     height: shieldTestShortUpperPanelHeight))
        renderAndConverge(ShortUpperShellLayout(engine: engine, typeRowExpanded: true))
        let shield = try #require(shieldRectOf(engine, 0), "上面板必须有盾")
        // 采样点取「盾 ∩ 可落线区」的真实交集中点——不再盲取 shield.midY。
        let hit = shield.intersection(handle.renderState.viewport.mainChartFrame)
        try #require(!hit.isNull && !hit.isEmpty,
                     """
                     盾与上面板可落线区无交集 → fixture 几何不成立（**非产品缺陷，别去改产品或放松断言**）。
                     几何：贴底 overlay 往上探进上面板的量 = overlay高 − 下面板高；上面板可落线区是其顶部 60%。
                     修法：**继续调小 shieldTestShortLowerPanelHeight（首选）与 shieldTestShortUpperPanelHeight**，
                     直到两者之和 < 实测 overlay 高度。**绝不是调大**（codex 计划-R5/R6 连续两次栽在方向反）。
                     排查先打印：shield=\(shield) mainChart=\(handle.renderState.viewport.mainChartFrame)
                     """)
        let p = CGPoint(x: hit.midX, y: hit.midY)
        let c0 = engine.drawings.count
        let pend0 = engine.drawingSession.pendingAnchors.count
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0)
        #expect(engine.drawingSession.pendingAnchors.count == pend0)
        // 清盾 → **同一点**落线：证明上面那次被拒确由盾造成（非该点本就不可落）。
        settleWithNoShields(engine.drawingSession)   // 见下方 helper：清盾**并**回到已收敛态
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0 + 1)
    }
```
配套 fixture（与既有 60/40、双高 400 并列，各司其职）：
```swift
/// codex 计划-R5-F1 / **R6-F1**：让 Task2 阶段那个 ~44pt 的**贴底**类型行 overlay 能真正盖到
/// **上面板的可落线区**（mainChart = 面板顶部 60%）。
///
/// ⭐**关键几何（R6-F1 纠正 R5 的错误修法）**：overlay 贴的是**整个容器**底部，所以
///   `往上探进上面板的量 = overlay高 − 下面板高`。**杠杆是下面板高度，不是上面板高度**——
///   R5 只把上面板从 60 缩到 24，探进量仍是 `44 − 40 = 4pt`、且探的是上面板**底部** 4pt，
///   与顶部 60% 的 mainChart 交集**依然为空**，等于把问题挪进了新 fixture 而非解决。
///
/// **正确判据**：让**两个面板高度之和 < overlay 高度**，贴底 overlay 就把上下面板**整个盖满**，
///   两个盾都必然非空、且各自完整覆盖该面板的 mainChart。24 + 8 = 32 < ~44 ✓。
private let shieldTestShortUpperPanelHeight: CGFloat = 24
private let shieldTestShortLowerPanelHeight: CGFloat = 8

@MainActor
private struct ShortUpperShellLayout: View {
    let engine: TrainingEngine
    var typeRowExpanded: Bool = true
    var body: some View {
        ChartPanelsContainer(
            engine: engine,
            showsTradeButtons: engine.flow.canBuySell(),
            isDrawingActive: engine.drawingSession.drawingModeActive,
            typeRowExpanded: typeRowExpanded,
            upperPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: shieldTestShortUpperPanelHeight) },
            // ⭐R6-F1：下面板也必须极矮——它才是决定 overlay 还剩多少往上探的那个量。
            lowerPanel: { Color.clear.frame(width: shieldTestPanelWidth, height: shieldTestShortLowerPanelHeight) },
            onLongPressType: {})     // Task2 阶段签名；Task3 改签名时同步更新
            .frame(width: shieldTestPanelWidth)
    }
}
```
> **实施第一步（别跳过）**：先把真实的 `DrawingTypeOverlay` 渲染高度**打印出来**（`ImageRenderer` + PreferenceKey 量一次即可），确认 `shieldTestShortUpperPanelHeight + shieldTestShortLowerPanelHeight < 实测 overlay 高度`。**若不成立，继续调小这两个值（尤其是下面板），绝不是调大**——R5/R6 连续两次栽在方向搞反上。测试内的 `#require` 会把这条前提 fail-closed 钉住并给出正确方向。
> `makeDrawingActiveChart` 现在写死 `panel: .lower`（第 132 行）——本 step 给它加 `panel: PanelId = .lower` 参数，各 rig 工厂共用。
>
> **⭐测试读盾的唯一入口（codex 计划-R17-F2 重设计后）**：
> ```swift
> /// 取某面板当前的**屏蔽矩形**；`.unshielded` / `.pending` 都返回 nil。
> /// ⚠️断言「该面板不被屏蔽」时**不要**用 `shieldRectOf(...) == nil`——那把 `.pending`（正在 fail-closed
> /// 拒收）也算成「不屏蔽」，会放过「几何未收敛却以为没事」的假绿。要证明真的开放，断言
> /// `session.shield[k] == .unshielded`。
> @MainActor
> private func shieldRectOf(_ engine: TrainingEngine, _ key: Int) -> CGRect? {
>     if case .rect(let r) = engine.drawingSession.shield[key] { return r }
>     return nil
> }
> ```
>
> **⭐差分测试的「清盾」必须显式回到已收敛态（codex 计划-R15-F2）**：
> ```swift
> /// 差分测试第二阶段用：清掉所有盾，**并**显式标记已收敛。
> /// 直接调 `clearAllShields()` 是**错的**——它按契约会把 `shieldsSettled` 置 false，而面板此刻仍
> /// `stylePanelVisible`，于是 `handleDrawingTap` 的 fail-closed 守卫会拒收 → **正确实现反而让测试红**，
> /// 而红了之后最省事的「修法」就是把 `shieldsSettled = false` 从 `clearAllShields()` 里删掉
> /// —— 那会重新打开裸奔窗口。**测试绝不能把实施者推向不安全的代码。**
> /// 本 helper 表达的是真实存在的合法状态：「几何已收敛，且两个面板都确实不被覆盖」。
> /// **不能**用 `clearAllShields()` 代替——那会回到「无 key」，而面板仍挂载时下一次
> /// `setStylePanelVisible(true)` 或残留 `.pending` 会让 `handleDrawingTap` 继续拒收，
> /// **正确实现反而让测试红**，进而诱导实施者去削弱 fail-closed。
> @MainActor
> private func settleWithNoShields(_ session: DrawingSession) {
>     session.setShield(.unshielded, panel: .upper)
>     session.setShield(.unshielded, panel: .lower)
> }
> ```
>
> **⭐同时抽出「复用既有 engine」的 handle 工厂（codex 计划-R11-F1，防跨 engine 假绿）**：
> ```swift
> /// 在**已存在的** engine 上再挂一个面板的 rig。凡是「一个测试里同时驱动上下两个面板」的场景
> /// **必须**用它——`makeDrawingActiveChart` 每次新建 engine，二次调用会让两个 handle 绑到不同 engine：
> /// 对 A 断言 count、却把 tap 打到 B，「不落线」天然成立（假绿），「清盾后落线」则必然假红。
> @MainActor
> private func makeChartHandle(engine: TrainingEngine, panel: PanelId, bounds: CGRect) -> DrawingChartHandle {
>     let coordinator = ChartContainerView(panel: panel, engine: engine).makeCoordinator()
>     let view = KLineView(frame: bounds)
>     coordinator.attach(to: view)
>     coordinator.rebuildRenderState(bounds: bounds)
>     return DrawingChartHandle(coordinator: coordinator, kLineView: view)
> }
> ```
> `makeDrawingActiveChart` 重构为：建 engine + `toggleDrawingMode()` 后调 `makeChartHandle`，两者共用同一份接线（不复制）。
> **实施自检**：本切片凡出现两次 `makeDrawingActiveChart(` 的测试都是**跨 engine 假绿**嫌疑——一个测试里只许调它一次，其余面板一律走 `makeChartHandle(engine:)`。
> **`upperPanelShieldBlocksOtherwiseCommittingTap` 与 `tallOverlayShieldsBothPanels` 是本 task 的达标判据**（真路径 + 差分 + 采样点取「盾 ∩ 可落线区」真实交集）；`clearAllShieldsClearsBothPanels` 只是模型单测、不算达标。
> **三套 fixture 分工**（别混用）：`60/40` 矮 fixture = overlay 跨两面板；`shieldTestShortUpperPanelHeight=24` = Task2 阶段矮 overlay 也能真盖住上面板（本条测试专用）；`shieldTestTallPanelHeight=400` 双高 = Task3/4 阶段「面板整块落在单个面板内」的精确 nil 判据。

- [ ] **Step 2: 运行 → 确认失败（Catalyst）**

Run: `cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:KlineTrainerContractsTests/DrawingTapHitShieldTests 2>&1 | tail -30`
Expected: FAIL（`clearAllShields` / 上面板盾均不存在）。**「no tests matched」或编译不过 = 判失败**。

- [ ] **Step 3: `DrawingSession` 加 `clearAllShields()` + 盾未就位窗口 fail-closed（codex 计划-R14-F1）**

> **codex R14-F1 与我的处理**：codex 要求加「合成真实 tap 的 Catalyst UI 测试」来覆盖第一道盾。**该建议在本仓 harness 不可行**——切片 1 已实证 headless Catalyst 挂 `UIWindow` 直接崩（无 `NSApplication`），而合成命中测试需要 window/hit-test 树；codex 自己也给了 fallback「做不到就当阻塞风险」。
> **我改为消除风险本身**：codex 指出的具体危险是**面板已可见、但 `shieldRect` 尚未经 GeometryReader→PreferenceKey 装好**的那个窗口期——此时唯一防线是未经测试的第一道盾。与其去测它，不如让这个窗口**不可表达**：窗口期内**拒收一切画线 tap**（fail-closed）。这样即使第一道盾完全失效，也落不出幽灵线。

> ⭐**设计简化（codex 计划-R17-F2 之后重做）**：R14 我用**三个变量**（`shieldRect` × `stylePanelVisible` × `shieldsSettled`）配**三路异步 preference** 表达同一件事，结果 **R15/R16/R17 连续三轮 high 全出在这套状态机上**（无条件开闸 / 生产误用测试逃生舱 / 两份 `refreshShields` 分歧）。根因是「**面板可见但没有盾**」这个危险状态**可以被表达出来**，只能靠额外守卫去拦——拦漏一次就是幽灵线。
> 改成**每面板一个三态枚举**，让该状态**从类型上不可表达**：

```swift
    /// 某个面板当前的命中屏蔽状态。三态互斥 —— 「面板可见却没有任何屏蔽」这一危险状态
    /// **无法被表达**（它就是 `.pending`，而 `.pending` 一律拒收），故不需要额外的布尔量与守卫。
    public enum PanelShield: Equatable, Sendable {
        // ⚠️**刻意不叫 `.none`**：`shield` 是 `[Int: PanelShield]`，取值是 `PanelShield?`，
        //   `shield[0] == .none` 会被 Swift 解析成 `Optional.none`（「字典里没这个 key」），
        //   与「该面板无屏蔽」混为一谈 —— 撞名陷阱，改名规避。
        case unshielded        // 无面板覆盖本面板 → 正常落线
        case pending           // 面板已挂载、真实几何尚未收敛 → **拒收一切 tap**（fail-closed）
        case rect(CGRect)      // 已知覆盖区（**面板局部坐标**）→ 只挡区内，区外正常落线
    }

    /// key 0=upper / 1=lower。缺省（无 key）等价 `.none`。
    public private(set) var shield: [Int: PanelShield] = [:]

    /// 面板挂载/卸载：挂载即把**两个**面板置 `.pending`（同步、不经 preference），
    /// 卸载即全清。这是「窗口期」的唯一来源，也是它唯一的表达方式。
    func setStylePanelVisible(_ visible: Bool) {
        if visible { shield[0] = .pending; shield[1] = .pending } else { shield.removeAll() }
    }

    /// 几何收敛后由 `refreshShields()` 写入某面板的最终状态（`.rect` 或 `.none`）。
    func setShield(_ s: PanelShield, panel: PanelId) { shield[panel == .upper ? 0 : 1] = s }

    /// 一次清掉**所有**面板的屏蔽（退画线 / view 消失 / 切位置）。切位置后由 `setStylePanelVisible(true)`
    /// 重新置 `.pending`，或由下一轮 `refreshShields()` 写入实值——**不存在「清掉后裸奔」的中间态**。
    func clearAllShields() { shield.removeAll() }
```
`deactivate()` 里那行 `shieldRect.removeAll()` 改调 `clearAllShields()`。

`ChartContainerView.handleDrawingTap` 的守卫（**取代**原先的 `shieldRect.contains` 那行）：
```swift
        // codex 计划-R14-F1/R17-F2（trade-safety）：三态互斥，无需再判布尔量。
        // `.pending` = 面板已挂载但几何未收敛 → 拒收一切（代价：刚展开面板的极短瞬间少响应一次点击；
        // 收益：**永远不会**因盾未就位而落出幽灵线并 autosave，不可逆）。
        switch session.shield[panel == .upper ? 0 : 1] ?? .unshielded {
        case .unshielded:      break
        case .pending:         return
        case .rect(let r):     if r.contains(point) { return }
        }
```
`DrawingStylePanel` 根上加（在 `contentShape` 之后、`accessibilityIdentifier` 之前）：
```swift
        .onAppear { session.setStylePanelVisible(true) }
        .onDisappear { session.setStylePanelVisible(false) }
```
**`refreshShields()` 的收敛判据（codex 计划-R15-F1 修正——原稿「末尾无条件 `markShieldsSettled()`」是错的）**：
`refreshShields()` 由**三个** `onPreferenceChange` 各自触发，到达顺序不保证。若 overlay frame **先到**、两个面板 frame 还没到，原稿会走 `guard ... else { setShieldRect(nil) }` 把盾清光，**却照样标记已收敛** → overlay 可见、零个盾、fail-closed 守卫被关掉 —— **正是本方案要消灭的窗口，被方案自身重新打开**。
故收敛判据改为「**计算所需的几何全部到齐**」：

### ⭐`refreshShields()` 唯一权威实现（全计划只此一处，codex 计划-R17-F2）

> 原稿在 Step 3 与 Task 2 Step 4 各写了一份，**后者漏了开闸调用** → 照它实现则面板一可见就**整个图表所有点击全被拒**，功能彻底废掉。**第 6 次「两份真相」**。现收敛为一处，其余位置一律引用本节。

```swift
    @MainActor
    private func refreshShields() {
        // ⭐几何未到齐 → **直接返回**，保持两个面板的 `.pending`（fail-closed）。
        //   绝不能在缺帧时写 `.none`——那正是 R15-F1 的裸奔窗口。
        guard let overlay = stylePanelChartFrame,
              let upper = upperPanelChartFrame,
              let lower = lowerPanelChartFrame else { return }

        for (panel, pf) in [(PanelId.upper, upper), (PanelId.lower, lower)] {
            let hit = overlay.intersection(pf)
            if hit.isNull || hit.isEmpty {
                engine.drawingSession.setShield(.unshielded, panel: panel)          // 面板没盖到这半 → 正常落线
            } else {
                // canonical 空间 = 目标面板局部（与 handleDrawingTap 的 tap point 同一空间）
                engine.drawingSession.setShield(.rect(hit.offsetBy(dx: -pf.minX, dy: -pf.minY)), panel: panel)
            }
        }
    }
```
> 与三变量版的关键差别：**开闸不再是一个独立动作**。几何齐备时逐面板写入 `.rect`/`.none`（即"开闸"），不齐备时**什么都不写**（保持 `.pending`）。于是「已收敛但没有盾」与「未收敛却开了闸」两种错误状态**都无法表达**——不再需要 `markShieldsSettled()`/`shieldsSettled` 这类独立开闸量，也不需要为它写守卫。

**到达顺序置换测试（host 纯逻辑，codex 计划-R15-F1 要求）**——把三个 frame 的到达顺序全排列，证明**部分几何恒不开闸**：
```swift
    @Test("到达顺序置换（codex 计划-R15-F1）：任何『几何未到齐』的中间态都不得标记收敛（fail-closed）")
    func partialGeometryNeverSettles() throws {
        // 纯状态推演：模拟 refreshShields 的开闸判据，穷举三个 frame 的到达顺序。
        func settles(overlay: Bool, upper: Bool, lower: Bool) -> Bool { overlay && upper && lower }
        let flags = [false, true]
        for o in flags { for u in flags { for l in flags {
            let complete = o && u && l
            #expect(settles(overlay: o, upper: u, lower: l) == complete,
                    "几何(overlay:\(o) upper:\(u) lower:\(l)) 的开闸判据错误 —— 部分几何开闸=裸奔窗口")
        } } }
        // 并断言判据真的写在生产代码里（防等价逻辑与生产漂移）。
        let tv = try readSource("UI/TrainingView.swift")
        #expect(tv.contains("stylePanelChartFrame != nil, upperPanelChartFrame != nil, lowerPanelChartFrame != nil"),
                "refreshShields 未按『几何到齐』开闸 —— 部分几何会打开 fail-closed 窗口")
    }
```

**host 纯逻辑测试**（无 UIKit，跑 `swift test`）：
```swift
    @Test("盾未就位窗口 fail-closed（codex 计划-R14-F1）：面板可见但盾没算过 → 状态可表达且默认拒收")
    func shieldWindowIsFailClosed() throws {
        let s = DrawingSession()
        #expect(s.shield.isEmpty, "初始无任何面板屏蔽")
        s.setStylePanelVisible(true)
        #expect(s.shield[0] == .pending && s.shield[1] == .pending,
                "面板挂载即应把**两个**面板置 .pending（拒收窗口的唯一表达）")
        s.setShield(.unshielded, panel: .upper)
        s.setShield(.rect(CGRect(x: 0, y: 0, width: 10, height: 10)), panel: .lower)
        #expect(s.shield[0] == .unshielded)
        s.setStylePanelVisible(false)
        #expect(s.shield.isEmpty, "面板卸载即全清")
        s.setStylePanelVisible(true)
        s.clearAllShields()
        #expect(s.shield.isEmpty, "clearAllShields 全清；后续由 setStylePanelVisible/refreshShields 重新置位")
    }
```
**Catalyst 差分测试**（证明窗口期真的拒收、收敛后恢复正常）：
```swift
    @Test("窗口期差分（codex 计划-R14-F1）：stylePanelVisible 且盾未收敛 → 本可落线的点被拒；收敛后同点落线")
    func tapRefusedWhileShieldsUnsettled() throws {
        let (handle, engine) = makeDrawingActiveChart()
        let p = leftmostMainChartPoint(handle)
        engine.drawingSession.setStylePanelVisible(true)      // 面板刚挂载 → 两面板 .pending
        let c0 = engine.drawings.count
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0, ".pending 窗口内竟落了线 —— fail-closed 未生效")
        settleWithNoShields(engine.drawingSession)            // 几何收敛且该面板不被覆盖
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0 + 1, "收敛后同点仍落不了线 → 拒收范围过大（面板外也被吞）")
    }
```
> **残留（如实记录，不假装消除）**：第一道盾（SwiftUI `contentShape` + 吞点手势）本身**仍无自动化覆盖**，只有源码守卫。但经本 step 后它**不再是任何时刻的唯一防线**——窗口期由 fail-closed 兜住，窗口期之后由输入层 `shieldRect`（有真差分测试）兜住。第一道盾退化为纯体验优化（避免点击穿透到下层视图的视觉反馈），**不再承载 trade-safety**。§4.4 人工验收仍会实点面板空隙确认。

- [ ] **Step 3b: `DrawingSession` 加 `clearAllShields()`**（并入 Step 3 一起实现，见上）

在 `DrawingSession.swift` 中**以 `PanelShield` 三态 API 取代**切片 1 的 `shieldRect`/`setShieldRect`（见 Step 3 的唯一权威定义）；本处补充：
```swift
> ⛔**`clearAllShields()` 的唯一定义在 Step 3**。此处**不再重复给实现**——原稿曾在这里另写一份分歧实现（codex 计划-R15-F2）。**同一个函数在计划里只能有一处实现**；本次评审已 6 次栽在「两份真相」上。
> 语义：一次清掉**所有**面板的屏蔽（回到「无 key」）。显式清盾的调用方（进/出画线、收起面板、切上下、view 消失）一律用它，而不是逐个面板单独置位——面板能停上半区也能停下半区，「漏清某一个」会留下「那半边 K 线怎么点都画不了线」的死区。
```
并把既有 `deactivate()` 里那行 `shieldRect.removeAll()` 改成 `clearAllShields()`（单一真相，语义不变）。

- [ ] **Step 4: `ChartPanelsContainer` 盾泛化（求交 → 每面板局部坐标）**

`TrainingView.swift`：把 `DrawingPanelFrameKey` 改名为 `DrawingLowerPanelFrameKey` 并新增 `DrawingUpperPanelFrameKey`（同款 `CGRect?` / `defaultValue = nil` / `reduce { value = nextValue() ?? value }`），然后把 `ChartPanelsContainer` 的 body 改成：
```swift
    @State private var upperPanelChartFrame: CGRect?
    @State private var lowerPanelChartFrame: CGRect?
    @State private var stylePanelChartFrame: CGRect?

    var body: some View {
        VStack(spacing: 0) {
            upperPanel()
                .background(GeometryReader { p in Color.clear
                    .preference(key: DrawingUpperPanelFrameKey.self, value: p.frame(in: .named("chart"))) })
            Divider()
            lowerPanel()
                .background(GeometryReader { p in Color.clear
                    .preference(key: DrawingLowerPanelFrameKey.self, value: p.frame(in: .named("chart"))) })
        }
        .coordinateSpace(name: "chart")
        .overlay(alignment: .bottom) {
            // showsTradeButtons 门必须保留：排除复盘（复盘用浮动铅笔钮，不挂本面板、不装盾）。
            if showsTradeButtons, isDrawingActive, typeRowExpanded {
                DrawingTypeOverlay(expanded: typeRowExpanded, onLongPressType: onLongPressType)
                    .background(GeometryReader { g in Color.clear
                        .preference(key: DrawingShieldFrameKey.self, value: g.frame(in: .named("chart"))) })
            }
        }
        .accessibilityIdentifier("chartPanels")
        // 三个 frame **任一**变化都重算盾：不假设 preference 的到达顺序。
        // （切片 1 只在 shield frame 变化时算、把 panel frame 当已知值读——若 panel frame 后到，
        //   盾会被算成 nil 并永远停在那，是一条靠收敛顺序侥幸的隐患。）
        .onPreferenceChange(DrawingUpperPanelFrameKey.self) { upperPanelChartFrame = $0; refreshShields() }
        .onPreferenceChange(DrawingLowerPanelFrameKey.self) { lowerPanelChartFrame = $0; refreshShields() }
        .onPreferenceChange(DrawingShieldFrameKey.self) { stylePanelChartFrame = $0; refreshShields() }
    }

    // ⛔ refreshShields() 的实现**不在此处重复**——见 Step 3 的「`refreshShields()` 唯一权威实现」一节。
    //    原稿在这里另写了一份（漏了几何未齐时的 fail-closed 返回），照它实现会让面板一可见就
    //    整个图表拒收所有点击。**同一函数在计划里只能有一处实现**（codex 计划-R17-F2，第 6 次「两份真相」）。
```
> **语义要点（实现见 Step 3）**：判据是**几何相交**，**不是**「面板停在上半区就挡上面板」——面板变高 / 上下切 / 跨越两面板时全都自动正确，位置语义变化不需要回来改它。canonical 空间 = 目标面板局部（与 `handleDrawingTap` 的 tap point 同一空间）。

- [ ] **Step 5: `TrainingView` 三处显式清盾改 `clearAllShields()` + 进画线时重置为展开态**

`TrainingView.swift` 把这三处的 `engine.drawingSession.setShieldRect(nil, panel: .lower)` 全部改成 `engine.drawingSession.clearAllShields()`：
- `.onChange(of: engine.drawingSession.drawingModeActive)`（约 :284）
- `.onChange(of: typeRowExpanded)`（约 :288）
- `.onDisappear`（约 :336）

> 🚫**这个 `onChange` 闭包必须保持无条件 `{ _, _ in }`、体内不得出现任何 `if`**（codex 计划-R10-F1）。
> `TrainingViewShellSourceGuardTests.tradeBoundary` 经切片 1 的 codex **R6/R9/R11 三轮加固**，精确要求
> `onChange(of: engine.drawingSession.drawingModeActive) { _, _ in` 签名 **且** 断言闭包体 `!contains("if ")`。
> 理由是**交易安全**：`tradeStrip` 必须**进出两个方向都清**——一旦退化成「只进画线时清」，一个跨 round-trip
> 幸存的陈旧买卖框会在退出画线后 remount，在**同 tick/period** 下被 `TradeConfirmGuard` 放行成交（不可逆）。
> **实施者注意：若你为了加 UI 状态而想改这个闭包签名或往里塞 `if`，那是错的方向——去下面 Step 5a。
> 绝不允许为此放松 `tradeBoundary` 守卫。**

- [ ] **Step 5a: 「进画线默认展开」放进 `toggleDrawing()`（codex 计划-R9-F3 的行为缺陷 + R10-F1 的正确落点）**

**缺陷**：`typeRowExpanded` 是 `@State`、只初始化一次 → 用户「收起面板 → 退出画线 → 再进画线」会停在**收起态**，样式控件被藏住、必须多点一次，违反 spec §2.1 与 §4.4 验收首行。
**落点**：不碰上面那个被守卫钉死的 `onChange`，改放 `toggleDrawing()`——它是**所有**进入画线路径的唯一 UI 入口（训练/replay 的「画图」钮与复盘的浮动铅笔钮共用它），且守卫只要求其闭包体在调 `engine.toggleDrawingMode()` 前含 `tradeStrip = nil`、**不禁止 `if`**。

```swift
    private func toggleDrawing() {
        tradeStrip = nil                       // 既有：同步清（防 onChange 被 SwiftUI coalesce）
        // spec §2.1：每次**进入**画线，面板默认展开。此处 drawingModeActive 仍是**切换前**的值，
        // 故 `!active` == 「即将进入」。退出方向不动展开态（避免与退出动画/清理抢状态）。
        if !engine.drawingSession.drawingModeActive { typeRowExpanded = true }
        engine.toggleDrawingMode()
    }
```
> **语义澄清（防与 spec §2.1「记住上次」混淆）**：「记住上次」指的是**工具与样式参数**（存 `DrawingSession.defaultStyle`，整局有效）；**展开/收起是每次进画线重置的会话内 UI 态**。两者不是一回事——面板每次都展开，但展开后显示的是你上次调好的线型/粗细/颜色。

- [ ] **Step 5b: 「进画线必展开」的守卫，且不得削弱 `tradeBoundary`**

```swift
    @Test("进画线默认展开（codex 计划-R9-F3 / R10-F1）：重置放在 toggleDrawing 的『即将进入』分支")
    func drawingEntryResetsExpandedInToggle() throws {
        let tv = try source("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        // 只取 toggleDrawing 到 engine.toggleDrawingMode() 之间——与既有 tradeBoundary 守卫同一片段口径。
        let body = try slice(tv, from: "private func toggleDrawing() {", to: "engine.toggleDrawingMode()")
        #expect(body.contains("tradeStrip = nil"), "既有交易安全：同步清 tradeStrip 不得丢")
        #expect(body.contains("if !engine.drawingSession.drawingModeActive { typeRowExpanded = true }"),
                "进画线未重置展开态 —— 收起后退出再进会停在收起态（spec §2.1 / §4.4 违规）")
    }

    @Test("交易安全不回退（codex 计划-R10-F1）：drawingModeActive 的 onChange 仍是无条件 { _, _ in }、体内无 if")
    func drawingModeOnChangeStaysUnconditional() throws {
        let tv = try source("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        // 与既有 TrainingViewShellSourceGuardTests.tradeBoundary 同向的**冗余**断言：本切片新增 UI 状态时
        // 极易顺手把这个闭包改成 `{ _, isActive in ... if isActive ... }`，那会让陈旧 tradeStrip 只在单方向被清。
        #expect(tv.contains("onChange(of: engine.drawingSession.drawingModeActive) { _, _ in"),
                "闭包签名被改动 —— tradeBoundary 守卫会红，且交易边界被削弱")
        let chain = try slice(tv, from: "onChange(of: engine.drawingSession.drawingModeActive) { _, _ in",
                              to: ".onChange(of: typeRowExpanded)")
        #expect(chain.contains("tradeStrip = nil"))
        #expect(chain.contains("clearAllShields()"))
        #expect(!chain.contains("if "), "闭包体出现 if —— 清理变成条件性，退出方向可能漏清")
    }
```

- [ ] **Step 6: 源码守卫——盾按几何求交、不按位置硬编码**

追加到 `DrawingTapHitShieldTests`：
```swift
    @Test("源码快检：盾用『overlay ∩ 每个面板 frame』求交装盾，且显式清盾走 clearAllShields（非逐面板漏清）")
    func shieldInstallIsGeometricNotPositionHardcoded() throws {
        let tv = try readSource("UI/TrainingView.swift")
        #expect(tv.contains("refreshShields"))
        #expect(tv.contains(".intersection("))                       // 求交，而非按位置选面板
        #expect(tv.contains("DrawingUpperPanelFrameKey"))            // 上面板也上报 frame
        #expect(tv.contains("clearAllShields"))                      // 显式清盾一次清两面板
        #expect(!tv.contains("setShieldRect"))       // 切片1 的旧 API 必须整体绝迹（已被 PanelShield 三态取代）
        let cc = try readSource("Render/ChartContainerView.swift")
        #expect(cc.contains("shieldRect") && cc.contains("shield.contains(point)"))   // 输入层守卫仍在
    }
```

- [ ] **Step 7: 运行 → 通过（host + Catalyst）**

Run（host）：`cd ios/Contracts && swift test 2>&1 | tail -5` → Expected: 全绿
Run（Catalyst，达标判据）：`cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:KlineTrainerContractsTests/DrawingTapHitShieldTests 2>&1 | tail -30`
Expected: PASS（含 `tallOverlayShieldsBothPanels` + `upperPanelShieldBlocksOtherwiseCommittingTap`）

- [ ] **Step 8: Commit**
```bash
git add ios/Contracts/Sources ios/Contracts/Tests
git commit -m "划线1a-iii切片2 Task2：命中屏蔽泛化到两面板（overlay∩面板求交装盾）+ clearAllShields 消灭漏清死区"
```

---

## Task 3: 常驻样式面板（类型行 + 5 组参数）替换长按卡片 `DrawingStyleCard`

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift`
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStylePanel.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift`（去掉 `onLongPressType`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（overlay 内容换成 `DrawingStylePanel`；删 `showingStyleCard` 与卡片 overlay；`ChartPanelsContainer` 去掉 `onLongPressType`）
- **Rename + Modify（守卫迁移，删卡片前必做）**: `Tests/.../Render/DrawingStyleCardSourceGuardTests.swift` → `DrawingStylePanelSourceGuardTests.swift`
- **Delete（守卫迁移通过后才删）**: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStyleCard.swift`

**Interfaces:**
- Consumes: Task 1 的 `LineSubTypeIcon` / `LineStyleIcon` / `ThicknessIcon`。
- Produces: `DrawingStyleParams(session: DrawingSession, scheme: AppColorScheme)`——5 组参数控件，**直接读 `session.defaultStyle`**（`@Observable`，无本地 `@State` 镜像）、每次选择即 `session.setDefaultStyle(...)`。
- Produces（Task 4 消费）：`DrawingStylePanel(session:scheme:position:onTogglePosition:)`。本 task 先按 `position` 固定 `.bottom` 渲染「参数在上 / 类型行在下」，镜像与 ⇅ 接线在 Task 4。
> ⚠️**签名里没有 `expanded:`**（codex 计划-R10-F3）：展开与否由 `ChartPanelsContainer` 的挂载条件
> （`if showsTradeButtons, isDrawingActive, typeRowExpanded`）单独决定——面板存在即是展开态。
> 再给面板一个 `expanded` 参数就是**第二份真相**（挂载条件说展开、参数说收起时该渲染什么？），
> 同类问题在 `DrawingTypeOverlay` 上已由 Step 5 一并删除。守卫见下条。

> **设计决定（去掉本地 `@State` 镜像）**：旧 `DrawingStyleCard` 用 `@State private var style` 镜像 `session.defaultStyle`，靠「每次弹卡片重建 View」保证不漂移。面板改成**常驻**后这个前提没了——本地镜像会与 session 长期共存并可能漂移（收 / 展、切上下、外部改默认值都可能让两者不一致）。故面板**直接读 session**（单一真相），把「两份状态」这个 bug 类别整个删掉，而不是去修某一次不同步。

- [ ] **Step 1: 写失败的守卫测试（迁移 + 加强）**

`git mv` 后改写为 `DrawingStylePanelSourceGuardTests.swift`：
```swift
// Tests/KlineTrainerContractsTests/Render/DrawingStylePanelSourceGuardTests.swift
// Spec: 2026-07-18-...-panel-redesign-design.md §2/§3 + 母 spec §3/§3.1。
// 迁自 DrawingStyleCardSourceGuardTests（长按卡片 → 常驻面板，1a-iii 切片2 Task3）——
// 灰态矩阵与「无解释文案」这两条母 spec 逐字要求全程有守卫覆盖，不留空窗。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("常驻样式面板结构守卫：5 组控件 / 灰态判据 / 图标化 / 无解释文案（1a-iii 切片2）")
struct DrawingStylePanelSourceGuardTests {
    private var srcDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ rel: String) throws -> String {
        let text = try String(contentsOf: srcDir.appendingPathComponent(rel), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }
    private let params = "Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift"
    private let panel  = "Sources/KlineTrainerContracts/UI/DrawingStylePanel.swift"

    @Test("五组控件标签齐 + 消费灰态判据 + 写 setDefaultStyle（迁自卡片守卫）")
    func hasGroupsAndWiring() throws {
        let code = try source(params)
        for label in ["线型", "线样式", "粗细", "颜色", "标注"] { #expect(code.contains(label)) }
        #expect(code.contains("DrawingStyleAvailability"))         // 灰态真被消费
        #expect(code.contains("normalizedLabelMode"))              // 切线型真规整 labelMode
        #expect(code.contains("session.setDefaultStyle"))          // 选择真写单一真相
    }

    @Test("面板文案洁净：无「不适用」类解释字（母 spec §3 逐字，迁自卡片守卫）")
    func noNotApplicableCopy() throws {
        for file in [params, panel] {
            let code = try source(file)
            for banned in ["不适用", "不可用", "N/A", "暂不支持"] { #expect(!code.contains(banned)) }
        }
    }

    @Test("图标化（spec §3）：线型/线样式/粗细三组**可见处**无文字（但 accessibilityLabel 必须有语义）")
    func lineGroupsAreIconsNotText() throws {
        let code = try source(params)
        #expect(code.contains("LineSubTypeIcon(") && code.contains("LineStyleIcon(") && code.contains("ThicknessIcon("))
        // ⭐codex 计划-R14-F2：守卫的**意图**是「界面上不显示文字」，原稿却实现成「这些字串整个文件都不许有」，
        //   于是逼出 `线型一` / `线样式solid` 这种无意义 accessibilityLabel —— 图标-only 控件配无语义标签，
        //   VoiceOver 用户**无法分辨直线/射线、实线/虚线**，是真可访问性缺陷（本 App 可能公开上架）。
        //   正确判据：只禁**可见 `Text(...)`** 里出现这些词；`.accessibilityLabel(...)` 里**必须**出现。
        for banned in ["Text(\"直线\")", "Text(\"射线\")", "Text(\"线段\")",
                       "Text(\"实线\")", "Text(\"虚线1\")", "Text(\"虚线2\")",
                       "Text(\"虚线3\")", "Text(\"虚线4\")"] {
            #expect(!code.contains(banned), "线型/线样式在界面上写了文字：\(banned)")
        }
        // 旧卡片的文字标签函数仍须绝迹（它们是「把枚举渲染成可见文字」的实现手段）。
        for banned in ["func subLabel(", "func styleLabel("] {
            #expect(!code.contains(banned), "仍留着渲染可见文字的标签函数：\(banned)")
        }
        // 粗细不得再用数字文案渲染档位。
        #expect(!code.contains("Text(\"\\($0)\")") && !code.contains("title: { \"\\($0)\" }"))
    }

    @Test("可访问性（codex 计划-R14-F2）：图标-only 控件必须带**语义** accessibilityLabel，VoiceOver 可分辨")
    func iconOnlyControlsCarrySemanticAccessibilityLabels() throws {
        let code = try source(params)
        // 线型三档 + 线样式五档 + 粗细五档，每一档都要有人话标签（图标看不见时的唯一依据）。
        for label in ["\"直线\"", "\"射线\"", "\"线段\"",
                      "\"实线\"", "\"虚线1\"", "\"虚线2\"", "\"虚线3\"", "\"虚线4\""] {
            #expect(code.contains(label), "缺语义可访问性标签 \(label) —— VoiceOver 用户分辨不出这一档")
        }
        #expect(code.contains("accessibilityLabel"), "图标控件未挂 accessibilityLabel")
        // 粗细用「粗细N」（1…5），见实现里的 label 闭包。
        #expect(code.contains("粗细"), "粗细档位缺语义标签")
    }

    @Test("标注组维持文字 + 灰态（spec §3 表格：唯一保留文字的组）")
    func labelGroupStaysTextual() throws {
        let code = try source(params)
        for word in ["隐藏", "显示", "左", "右"] { #expect(code.contains(word)) }
        #expect(code.contains("horizontalLabelModeEnabled"))
    }

    @Test("常驻面板读 session.defaultStyle 单一真相（不留本地 @State 镜像，防常驻期漂移）")
    func readsSessionDirectlyWithoutLocalMirror() throws {
        let code = try source(params)
        #expect(code.contains("session.defaultStyle"))
        #expect(!code.contains("@State private var style"))
    }

    @Test("颜色语义本切片不动（切片3 才改）：仍全 9 色 + 仍消费 colorEnabled 昼夜禁色")
    func colorSemanticsUnchangedInThisSlice() throws {
        let code = try source(params)
        #expect(code.contains("DrawingColorToken.allCases"))
        #expect(code.contains("colorEnabled"))
    }

    // ⭐codex 计划-R3-F1：R2 里我声称「第一道盾由源码守卫覆盖」，却**没真去加这条断言**——
    //   等于拿一个不存在的守卫去 justify「不跑真 SwiftUI 命中测试」这个残留风险。现补齐。
    //   这是第一道盾**唯一**的自动化覆盖（第二道盾走 handleDrawingTap 输入层测试），必须精确到修饰符顺序。
    // 从 text 中切出 [startMarker, endMarker) 之间的片段；两个 marker 都必须**恰好出现一次**
    // （出现 0 次 = 接线没了；出现多次 = 切片有歧义、顺序判据不可信）→ 都 fail-closed。
    // codex 计划-R4-F1：不这么切就只能拿「全文首次匹配」比先后，而 TrainingView.swift 有几十处
    // `.padding(`，全文首个 padding 与全文首个 GeometryReader 根本不在同一条修饰符链上，比出来无意义。
    private func slice(_ text: String, from startMarker: String, to endMarker: String) throws -> String {
        #expect(text.components(separatedBy: startMarker).count == 2, "起始锚 \(startMarker) 非唯一出现，切片有歧义")
        #expect(text.components(separatedBy: endMarker).count == 2, "结束锚 \(endMarker) 非唯一出现，切片有歧义")
        let start = try #require(text.range(of: startMarker)).lowerBound
        let end = try #require(text.range(of: endMarker, range: start..<text.endIndex)).lowerBound
        return String(text[start..<end])
    }

    @Test("第一道盾（codex 计划-R3-F1 / R4-F1）：面板根修饰符链上有 contentShape+吞点手势，且面板本体**零 padding**")
    func firstShieldPresentAndPrecedesPadding() throws {
        let code = try source(panel)
        // ⭐R4-F1：不再全文搜。切出 body 的根修饰符链（从可见材质到 body 结束）再判顺序。
        // ⭐codex 计划-R5-F2：切到文件级 `#endif` **不是根链边界**——中间可以夹任意 helper / extension，
        //   一个「根链上没有 contentShape、但后面某个 helper 里有一处」的文件照样能过唯一性检查。
        //   改用**根链专属终止锚**：生产代码必须在根 `.onTapGesture {}` 之后紧跟
        //   `.accessibilityIdentifier("drawingStylePanel")`，切片切到它为止 → 切出来的必是根链本身。
        let rootChain = try slice(code, from: ".background(.regularMaterial",
                                  to: ".accessibilityIdentifier(\"drawingStylePanel\")")
        // 根链内不得出现任何声明边界——出现即说明锚之间夹了别的 helper/extension，切片不可信。
        for boundary in ["func ", "struct ", "extension ", "var body"] {
            #expect(!rootChain.contains(boundary),
                    "根链切片内出现声明边界 `\(boundary)` —— 切到的不是单一根修饰符链，顺序判据不可信")
        }
        let shapeIdx = try #require(rootChain.range(of: ".contentShape(Rectangle())"),
                                    "面板**根链**上缺第一道盾 contentShape —— 点面板会穿透到下层图表").lowerBound
        let tapIdx = try #require(rootChain.range(of: ".onTapGesture {}"),
                                  "根链缺吞点手势，contentShape 单独不吞 tap").lowerBound
        #expect(shapeIdx < tapIdx, "contentShape 必须在吞点手势之前（否则命中形状不作用于该手势）")
        // ⭐R4-F1：禁**任何写法**的 padding，不只 8pt 那两种拼法（`.padding(8)`/`.padding(.all, 8)` 同样致命）。
        // 面板本体一旦自带 padding，call-site 的 GeometryReader 量到的就是含透明边距的框 → 死条（R1-F2 回归）。
        #expect(!code.contains(".padding("),
                "DrawingStylePanel.swift 出现 .padding( —— 面板本体不得自带任何边距，离屏边距只能加在 call site 测量之后")
        // contentShape 必须唯一：文件里另有一个嵌套/闲置的 contentShape 会让上面的断言假绿。
        #expect(code.components(separatedBy: ".contentShape(Rectangle())").count == 2,
                "contentShape(Rectangle()) 非唯一出现 —— 无法确定护住的是面板根")
    }

    @Test("call-site 顺序（codex 计划-R3-F1 / R4-F1）：**同一条链上** GeometryReader 先量、两个方向的 8pt padding 后加")
    func callSiteMeasuresBeforePadding() throws {
        let tv = try source("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        // ⭐R4-F1：切出 overlay 里挂 DrawingStylePanel 的**那一条链**，只在链内比顺序。
        let chain = try slice(tv, from: "DrawingStylePanel(session:", to: ".accessibilityIdentifier(\"chartPanels\")")
        let geoIdx = try #require(chain.range(of: "DrawingShieldFrameKey.self"),
                                  "链上缺 shield frame 上报").lowerBound
        let hIdx = try #require(chain.range(of: ".padding(.horizontal, 8)"),
                                "链上缺水平 8pt 离屏边距").lowerBound
        let vIdx = try #require(chain.range(of: ".padding(.vertical, 8)"),
                                "链上缺垂直 8pt 离屏边距（上半区 minY==8 断言依赖它）").lowerBound
        // 两个方向都必须在测量**之后**——只查「存在」不够，垂直 padding 排在测量前同样会把边距量进盾。
        #expect(geoIdx < hIdx, "水平 padding 在测量之前 → 透明边距进盾，图表出现看不见的死条（R1-F2 回归）")
        #expect(geoIdx < vIdx, "垂直 padding 在测量之前 → 同上")
        // 链内不得有**任何**排在测量之前的 padding（含 `.padding(8)` 等其它拼法）。
        let beforeMeasure = String(chain[chain.startIndex..<geoIdx])
        #expect(!beforeMeasure.contains(".padding("),
                "测量之前就有 padding —— 量到的不是可见面板本体（R1-F2 回归）")
    }

    @Test("fail-closed 接线（codex 计划-R16-F2）：DrawingStylePanel 根上挂了可见性钩子，否则整套防护静默失效")
    func panelCarriesVisibilityHooks() throws {
        let code = try source(panel)
        #expect(code.contains(".onAppear { session.setStylePanelVisible(true) }"),
                "缺 onAppear → stylePanelVisible 恒 false → handleDrawingTap 的 fail-closed 守卫永不生效")
        #expect(code.contains(".onDisappear { session.setStylePanelVisible(false) }"),
                "缺 onDisappear → 面板消失后仍被判为可见 → 整个图表变成死区")
    }

    @Test("单一真相（codex 计划-R10-F3）：DrawingStylePanel 无 expanded 参数/存储属性（展开态只由挂载条件决定）")
    func panelHasNoExpandedParameter() throws {
        let code = try source(panel)
        #expect(!code.contains("expanded"),
                "DrawingStylePanel 出现 expanded —— 与 ChartPanelsContainer 的挂载条件构成第二份真相")
        let overlay = try source("Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift")
        #expect(!overlay.contains("let expanded"), "DrawingTypeOverlay 的 expanded 参数应随 Step 5 删除")
    }

    @Test("旧长按卡片已删除、长按钩子已摘除（不留两套设置入口）")
    func longPressCardRetired() throws {
        let cardPath = srcDir.appendingPathComponent("Sources/KlineTrainerContracts/UI/DrawingStyleCard.swift")
        #expect(!FileManager.default.fileExists(atPath: cardPath.path))
        let tv = try source("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(!tv.contains("DrawingStyleCard("))
        #expect(!tv.contains("showingStyleCard"))
        let overlay = try source("Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift")
        #expect(!overlay.contains("onLongPressType"))
        #expect(!overlay.contains("LongPressGesture"))
    }
}
```

- [ ] **Step 2: 运行 → 确认失败**

Run: `cd ios/Contracts && swift test --filter DrawingStylePanelSourceGuardTests 2>&1 | tail -20`
Expected: FAIL（新文件不存在 / 卡片还在）

- [ ] **Step 3: 实现 `DrawingStyleParams`（5 组，三组图标化，直读 session）**

Create `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift`:
```swift
// Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift
// 1a-iii 切片2 Task3：常驻样式面板的 5 组参数控件（由 DrawingStyleCard 平移改造）。
// 与旧卡片的三点差异：①线型/线样式/粗细改「画出来」的图标（spec §3）；②不再持有本地 @State 镜像，
// 直接读 session.defaultStyle 单一真相（常驻面板长期存活，两份状态必然漂移）；③无「完成」/遮罩关闭语义。
// 颜色组本切片**原样保留** 9 色 + colorEnabled 昼夜禁色灰态（收成「7 彩 + 线色」是切片 3 的事）。
// 灰掉的项只降饱和 + .disabled，绝不写任何解释文案（母 spec §3 逐字）。
#if canImport(UIKit)
import SwiftUI

struct DrawingStyleParams: View {
    let session: DrawingSession
    let scheme: AppColorScheme

    private var style: DrawingDefaultStyle { session.defaultStyle }

    private func commit(_ mutate: (inout DrawingDefaultStyle) -> Void) {
        var next = session.defaultStyle
        mutate(&next)
        session.setDefaultStyle(next)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            group("线型") {
                options(LineSubType.allCases, current: style.lineSubType,
                        enabled: { DrawingStyleAvailability.horizontalLineSubTypeEnabled($0) },
                        label: { subTypeAccessibilityLabel($0) },
                        icon: { LineSubTypeIcon(subType: $0) }) { picked in
                    // 切线型即规整依赖的 labelMode（直线选『左』后切射线 → 回落 hidden），
                    // 杜绝「显示为灰却仍作默认被提交」的矛盾组合。规则单一真相在 DrawingStyleAvailability。
                    commit {
                        $0.lineSubType = picked
                        $0.labelMode = DrawingStyleAvailability.normalizedLabelMode(current: $0.labelMode,
                                                                                    lineSubType: picked)
                    }
                }
            }
            group("线样式") {
                options(LineStyle.allCases, current: style.lineStyle,
                        enabled: { _ in true },
                        label: { lineStyleAccessibilityLabel($0) },
                        icon: { LineStyleIcon(style: $0) }) { picked in commit { $0.lineStyle = picked } }
            }
            group("粗细") {
                options(Array(1...5), current: style.thickness,
                        enabled: { _ in true },
                        label: { "粗细\($0)" },
                        icon: { ThicknessIcon(thickness: $0) }) { picked in commit { $0.thickness = picked } }
            }
            group("颜色") { colorRow }
            group("标注") { labelModeRow }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    // 一组 = 组名 caption + 一排选项。caption 是组名，不是解释文案。
    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Text(title).font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    // 图标化选项排（线型/线样式/粗细共用）。可访问性标签挂在按钮上——图标无文字，但读屏仍可用。
    // enabled/label/icon/pick 必须 @escaping：它们被 ForEach 的**逃逸** ViewBuilder 闭包捕获，
    // 非逃逸参数在 Catalyst/iOS 会编译报错（host swift test 不编 #if canImport(UIKit) 体、只有真机门才炸）。
    private func options<T: Hashable, I: View>(_ items: [T], current: T,
                                               enabled: @escaping (T) -> Bool,
                                               label: @escaping (T) -> String,
                                               @ViewBuilder icon: @escaping (T) -> I,
                                               pick: @escaping (T) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                let on = enabled(item)
                Button { pick(item) } label: {
                    icon(item)
                        .padding(.horizontal, 4)
                        .frame(height: 26)
                        .background(item == current ? Color.accentColor.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(item == current ? Color.accentColor : Color.secondary.opacity(0.35),
                                    lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(!on)
                .foregroundStyle(on ? (item == current ? Color.accentColor : Color.primary) : Color.secondary)
                .opacity(on ? 1 : 0.4)          // 灰＝只降饱和，无解释字
                .accessibilityLabel(label(item))
            }
        }
    }

    // 颜色行：本切片**不动语义**——仍 9 色、仍昼夜禁色灰态（切片 3 收成「7 彩 + 线色」并删 colorEnabled）。
    private var colorRow: some View {
        HStack(spacing: 6) {
            ForEach(DrawingColorToken.allCases, id: \.self) { token in
                let on = DrawingStyleAvailability.colorEnabled(token, scheme: scheme)
                Button { commit { $0.colorToken = token } } label: {
                    Circle().fill(swatchColor(token))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.accentColor,
                                                 lineWidth: token == style.colorToken ? 2.5 : 0))
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!on)
                .opacity(on ? 1 : 0.3)
                .accessibilityLabel(colorAccessibilityLabel(token))
            }
        }
    }

    // 标注组：spec §3 表格明确「维持现状」——本组是面板里唯一保留文字的组。
    private var labelModeRow: some View {
        HStack(spacing: 6) {
            ForEach(LabelMode.allCases, id: \.self) { mode in
                let on = DrawingStyleAvailability.horizontalLabelModeEnabled(mode, lineSubType: style.lineSubType)
                Button { commit { $0.labelMode = mode } } label: {
                    Text(labelModeText(mode)).font(.caption)
                        .padding(.horizontal, 8).frame(height: 26)
                        .background(mode == style.labelMode ? Color.accentColor.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(mode == style.labelMode ? Color.accentColor : Color.secondary.opacity(0.35),
                                    lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(!on)
                .foregroundStyle(on ? (mode == style.labelMode ? Color.accentColor : Color.primary) : Color.secondary)
                .opacity(on ? 1 : 0.4)
            }
        }
    }

    private func swatchColor(_ token: DrawingColorToken) -> Color {
        let c = DrawingColorResolver.resolve(token, scheme: scheme)
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    // 可访问性标签（读屏用）——这些字符串**不渲染成可见文字**（可见内容是图标），但必须**有语义**：
    // codex 计划-R14-F2：图标-only 控件若配 `线型一`/`线样式solid` 这类无意义标签，VoiceOver 用户
    // 无法分辨直线/射线、实线/各档虚线 → 会选错线型样式且无任何文字兜底。故用人话。
    private func subTypeAccessibilityLabel(_ s: LineSubType) -> String {
        ["straight": "直线", "ray": "射线", "segment": "线段"][s.rawValue] ?? s.rawValue
    }
    private func lineStyleAccessibilityLabel(_ s: LineStyle) -> String {
        ["solid": "实线", "dash1": "虚线1", "dash2": "虚线2",
         "dash3": "虚线3", "dash4": "虚线4"][s.rawValue] ?? s.rawValue
    }
    private func labelModeText(_ m: LabelMode) -> String {
        ["hidden": "隐藏", "show": "显示", "left": "左", "right": "右"][m.rawValue] ?? m.rawValue
    }
    private func colorAccessibilityLabel(_ c: DrawingColorToken) -> String {
        ["red": "赤", "orange": "橙", "yellow": "黄", "green": "绿", "cyan": "青",
         "blue": "蓝", "purple": "紫", "black": "黑", "white": "白"][c.rawValue] ?? c.rawValue
    }
}
#endif
```
> ⚠️ **守卫与实现的一致性（codex 计划-R14-F2 修正）**：`lineGroupsAreIconsNotText` 只禁**可见 `Text("直线")` 一类**，**不禁** `.accessibilityLabel("直线")`；配套的 `iconOnlyControlsCarrySemanticAccessibilityLabels` **要求**这些语义标签必须在。原稿把禁词写成「整个文件都不许出现这些字串」，逼出了 `线型一`/`线样式solid` 这类无意义读屏标签——**守卫的意图是「界面上不显示文字」，不是「这些词不许存在」**，写错判据会把可访问性一起禁掉。若实施中发现更精确的判据（例如断言 `Text(` 在本文件只出现于 `labelModeRow` 与 `group(` 内），**优先换成那个**并在 commit message 说明；但**任何情况下都不许**为了过守卫而删掉语义 accessibilityLabel。

- [ ] **Step 4: 实现 `DrawingStylePanel` 容器（本 task 只做 `.bottom` 形态）**

Create `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStylePanel.swift`:
```swift
// Sources/KlineTrainerContracts/UI/DrawingStylePanel.swift
// 1a-iii 切片2 Task3：常驻样式面板 = 「类型行 + 参数」一个整体，由底栏①「类型」键统一开/合。
// 盖在 K 线上的 overlay（遮挡、**不挤压** K 线——布局不变量见 DrawingLayoutInvariantTests）。
// 上下摆放与镜像在 Task4 接线；本 task 先固定下半区形态：视觉自上而下 = 参数 → 类型行（类型行贴底栏）。
#if canImport(UIKit)
import SwiftUI

struct DrawingStylePanel: View {
    let session: DrawingSession
    let scheme: AppColorScheme
    let position: DrawingStylePanelPosition
    let onTogglePosition: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 镜像只翻「类型行 ↔ 参数」两大块；参数内部 5 组顺序两态相同、不翻（user 确认）。
            if position == .top {
                DrawingTypeOverlay(onTogglePosition: onTogglePosition)
                Divider()
                DrawingStyleParams(session: session, scheme: scheme)
            } else {
                DrawingStyleParams(session: session, scheme: scheme)
                Divider()
                DrawingTypeOverlay(onTogglePosition: onTogglePosition)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        // 第一道盾：吞掉落在面板上的点击，不穿透到下层图表（第二道盾 = ChartPanelsContainer 的 shieldRect）。
        // ⭐codex 计划-R1-F2：`.contentShape` 必须**紧贴可见内容**、在任何 padding **之前**——
        //   本视图的边界 == 用户看得见的那块圆角材质，一个像素的透明外边距都不许算进来。
        .contentShape(Rectangle())
        .onTapGesture {}
        // ⭐codex 计划-R16-F2：fail-closed 的**非 preference** 可见性信号，必须挂在这里。
        //   缺了它 `stylePanelVisible` 恒 false → `handleDrawingTap` 的 fail-closed 守卫**永不生效**，
        //   「面板已可见但盾未装好」的窗口就又只剩那道测不了的 SwiftUI 手势盾。
        //   （原稿只在 Step 3 散文里写了「根上加 onAppear/onDisappear」，**没写进这个可粘贴的实现块**
        //     —— 第 4 次「声称了没写」，实施者照块粘贴就会漏掉整个防护。）
        .onAppear { session.setStylePanelVisible(true) }
        .onDisappear { session.setStylePanelVisible(false) }
        // ⭐codex 计划-R5-F2：这个 id 是**根链专属终止锚**，供源码守卫精确框定「根修饰符链」到此为止
        //   （切到文件级 #endif 会把后面的 helper/extension 一并吞进来 → 守卫可被非根代码假绿满足）。
        //   它同时也是可测性契约的一部分，**不要删**。
        .accessibilityIdentifier("drawingStylePanel")
        // ⚠️**本视图刻意不加 .padding**：离屏边距由调用方在**量完 frame 之后**施加（见 Task3 Step6）。
        //   否则 call-site 的 GeometryReader 量到的是「含 8pt 透明外边距」的框，那圈看不见的边距会被
        //   写进 shieldRect → 图表上出现**看不见的死条**（点了没反应、也画不了线），且上半区时
        //   还与「类型行顶边贴上半 K 线顶边」的对齐语义打架。
    }
}
#endif
```
> **⭐不变量（codex 计划-R2-F2 修正为诚实版本）**：原稿写的是「第一道盾 / 第二道盾 / 可见像素**三者逐像素一致**」——**这是假的**，codex 戳穿得对：面板画的是 `cornerRadius: 12` 的**圆角**材质，而 `contentShape` 与 `shieldRect` 都是**矩形**，圆角外那四个透明小三角照样被挡。改成能站得住的版本：
>
> **不变量（bounding-box 版）**：第一道盾（`contentShape` 矩形）、第二道盾（`shieldRect`，API 就是 `CGRect`）、以及可见面板的**外接矩形**，三者逐像素一致。任何 padding / offset 只能加在这三者之外。
> **已记录的已知过度屏蔽**：四个圆角外的透明三角（每角约 `(1−π/4)·12² ≈ 31pt²`，肉眼几乎不可察）仍被挡。**明确接受**——`shieldRect` 是 `CGRect` API，要消掉它得把盾改成圆角路径或把面板改成直角，两者代价都远大于这点收益。写在这里是为了**不假装它不存在**（P1a 教训：矛盾要么消灭、要么显式记录，不许糊过去）。
>
> **⭐同样诚实地记一笔：第一道盾本计划没有真测到。** `handleDrawingTapForTesting` 走的是**输入层**（`ChartContainerView.handleDrawingTap`），**完全绕过 SwiftUI 命中测试**——所以本计划所有屏蔽测试验的都是**第二道盾**。这是可接受的，因为**第二道盾才是承重的那道**：`handleDrawingTap` 是通往 `commitPending` → `appendDrawing` 的**唯一**路径，它拒了就绝无幽灵线。第一道盾（`contentShape` + 吞点手势）是纵深防御的第二层，本计划只用**源码守卫**覆盖（Task 3 Step 1 断言 `contentShape(Rectangle())` 存在且在 padding 之前）。
> **不得**把「gutter 差分测试通过」说成「第一道盾已验证」——它证明的只是输入层盾的边界正确。headless Catalyst 下驱动真 SwiftUI 命中测试的手段本仓尚无先例（`UIWindow` 会崩），若 codex/user 认为必须覆盖，属**阻塞级 escalation**、由其裁决，实施者不自决。
> **第一道盾的实际覆盖 = Task 3 Step 1 的 `firstShieldPresentAndPrecedesPadding`**（断言根上有 `contentShape(Rectangle())` + `.onTapGesture {}`、面板本体不自带 padding、且 contentShape 排在任何 padding 之前）**+ `callSiteMeasuresBeforePadding`**（断言 call site 的 GeometryReader 在 padding 之前、两态 8pt 边距都在）。codex 计划-R3-F1 抓到原稿只**声称**有这层守卫却没真写——现已补齐，声称与实现对齐。
> `DrawingStylePanelPosition` 在 Task 4 定义。**本 task 实施时**：若想让 Task 3 独立编译通过，就在本 task 先建这个两 case 的 enum（Task 4 只加 ⇅ 接线与 alignment 切换），**不要**为了绕开它把 position 写成 `Bool`。

- [ ] **Step 5: `DrawingTypeOverlay` 摘掉长按钩子 + 让位给面板容器**

改 `DrawingTypeOverlay.swift`：
- 删 `let onLongPressType: () -> Void` 与 `.simultaneousGesture(LongPressGesture...)`（长按卡片没了）。
- 删 `let expanded: Bool` 与 `if expanded {}` 包裹（展开与否已由 `ChartPanelsContainer` 的挂载条件决定，此处再判一次是重复真相）。
- 删根上的 `.contentShape(Rectangle())` / `.onTapGesture {}`（第一道盾上移到 `DrawingStylePanel` 根，整块面板统一吞点；留在这里只护住类型行那一条、参数区反而漏）。
- 加 `let onTogglePosition: () -> Void` 与右端 ⇅ 按钮（Task 4 接真行为，本 task 先把按钮和 accessibilityLabel("切换面板位置") 放上并调用 `onTogglePosition`）。
- `.background(.thinMaterial)` 改为透明（外层 `DrawingStylePanel` 已给整块背景，双层材质会糊）。

- [ ] **Step 5b: 迁移既有 `splitBarsCarryD19D24` 守卫（codex 计划-R7-F1，删长按钩子前必做）**

`Tests/.../Render/DrawingTapHitShieldTests.swift:93` 现有一行 `#expect(overlay.contains("onLongPressType"))`——**与 Step 1 新增的「长按钩子已摘除」断言直接互斥**。不改它，Task 3 跑不过全量测试门（两条测试要求相反）。
这与切片 1 Task 2 Step 6b 是**同一条守则**：删掉被守卫的东西之前，先把守卫迁到新形态，全程不留 D19/D24 覆盖空窗。

```swift
    @Test("D19/D24：拆分后控件齐、无未接线键（迁自 DrawingModeBarSourceGuardTests；切片2 去长按钩子）")
    func splitBarsCarryD19D24() throws {
        let overlay = try readSource("UI/DrawingTypeOverlay.swift")
        let bottom  = try readSource("UI/DrawingModeBar.swift")   // DrawingBottomBar 与 DrawingModeBar 同文件
        #expect(overlay.contains("accessibilityLabel(\"水平线\")"))   // 类型行水平线图标恒亮（不变）
        // ⭐切片2：长按卡片已被常驻面板取代 → 钩子必须消失（与 DrawingStylePanelSourceGuardTests
        //   .longPressCardRetired 同向，不再自相矛盾）。
        #expect(!overlay.contains("onLongPressType"))
        #expect(!overlay.contains("LongPressGesture"))
        // ⭐切片2 新增接线：⇅ 切上下半区（Task4 接真行为，Task3 已把按钮与回调放上）。
        #expect(overlay.contains("onTogglePosition"))
        #expect(bottom.contains("accessibilityLabel(\"类型\")"))       // ①类型键（不变）
        for banned in ["accessibilityLabel(\"锁定\")", "accessibilityLabel(\"删除\")",
                       "accessibilityLabel(\"撤销\")", "accessibilityLabel(\"前进\")"] {   // ②–⑤ 仍不渲染
            #expect(!overlay.contains(banned)); #expect(!bottom.contains(banned))
        }
    }
```
> **顺序要求**：本 step 必须在 Step 5（`DrawingTypeOverlay` 摘钩子）**之后、Step 7（删卡片）之前**跑一次全量，确认新旧断言不再互斥。
> **实施自查（防同类漏网）**：删任何被守卫的符号前，**跑「既有测试迁移矩阵」章节里那条固定的 11 符号 grep 循环**（原样粘贴，**不许手挑子集**），并对照矩阵逐行处理。
> ⚠️**本处刻意不再复述一份短清单**（codex 计划-R9-F1）：原稿在这里手写了「至少有 `onLongPressType`/`LongPressGesture`/`DrawingStyleCard`/`showingStyleCard`/`DrawingPanelFrameKey`」——**正是这份漏了 `DrawingTypeOverlay(` 的清单造成了 R8 的漏网**。清单只能有**一份真相**（矩阵章节那条循环），本地 step 只引用、不复制；两份清单必然漂移，而漂移的那份会被就近阅读的实施者当权威。

- [ ] **Step 6: `TrainingView` 换挂载 + 删卡片**

- `ChartPanelsContainer`：把参数 `onLongPressType: () -> Void` 换成 `stylePanelPosition: DrawingStylePanelPosition` + `onTogglePosition: () -> Void`；overlay 内容由 `DrawingTypeOverlay(...)` 换成：
```swift
                DrawingStylePanel(session: engine.drawingSession, scheme: scheme,
                                  position: stylePanelPosition, onTogglePosition: onTogglePosition)
                    // ⭐codex 计划-R1-F2：GeometryReader 必须量**未加 padding 的可见面板本体**——
                    //   量到的 frame 就是写进 shieldRect 的盾。先量、后 padding：
                    .background(GeometryReader { g in Color.clear
                        .preference(key: DrawingShieldFrameKey.self, value: g.frame(in: .named("chart"))) })
                    // 离屏边距加在测量之后 → 只影响面板摆放位置，不进盾（无看不见的死条）。
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
```
（`scheme` 由 `TrainingView` 按既有 `colorScheme == .dark ? .dark : .light` 传入，新增一个 `let scheme: AppColorScheme` 参数。）

**并加一条透明边距的差分测试**（codex 计划-R1-F2 明确要求，追加到 `DrawingTapHitShieldTests`）：
```swift
    // ⚠️命名与范围（codex 计划-R2-F2）：本测试验的是**第二道盾（输入层）**的边界——
    //   `handleDrawingTapForTesting` 绕过 SwiftUI 命中测试，**证明不了** contentShape 那道盾。
    //   故函数名带 `InputLayer`，别让后来人把它读成「第一道盾已覆盖」。
    @Test("透明外边距不进**输入层**盾（codex 计划-R1-F2）：面板可见外接矩形**之外**的 8pt 空隙里点一下 → 正常落线，不是死条")
    func transparentGutterOutsideVisiblePanelStillCommits_inputLayer() throws {
        let (handle, engine) = makeDrawingActiveChart()
        renderAndConverge(TrainingShellLayout(engine: engine, typeRowExpanded: true))
        let shield = try #require(shieldRectOf(engine, 1))
        // 盾右缘之外 4pt（落在 8pt 透明边距带内）——用户看到的是「图表」，就该能画线。
        let p = CGPoint(x: shield.maxX + 4, y: shield.midY)
        try #require(handle.renderState.viewport.mainChartFrame.contains(p),
                     "采样点必须落在可落线区，否则本测试无意义（假绿）")
        let c0 = engine.drawings.count
        handle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c0 + 1,
                "面板可见边缘外的透明边距被算进了盾 → 图表上有看不见的死条")
    }
```
- `TrainingView`：删 `@State private var showingStyleCard`（:47）与 `.overlay { if showingStyleCard { DrawingStyleCard(...) } }`（:212-218）；`chartPanels` 的 `onLongPressType:` 实参换成 `stylePanelPosition:` / `onTogglePosition:`（`@State private var stylePanelPosition: DrawingStylePanelPosition = .bottom`，Task 4 接 ⇅）。
- 同步更新 `DrawingTapHitShieldTests.TrainingShellLayout` 的构造实参（Task 2 Step 1 已提示）。

- [ ] **Step 7: 守卫通过后再删卡片**

先跑守卫确认新面板已就位（除 `longPressCardRetired` 外全绿），再：
```bash
git rm ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStyleCard.swift
```
Run: `cd ios/Contracts && swift test --filter DrawingStylePanelSourceGuardTests 2>&1 | tail -20`
Expected: PASS（7 个守卫测试全绿，含 `longPressCardRetired`）

- [ ] **Step 8: 全量三绿等价 + Catalyst 基线同步**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5` → Expected: 全绿
Run: `cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:KlineTrainerContractsTests 2>&1 | tee /tmp/cat-slice2-t3.log | tail -5`
然后更新两个基线（**改法不同，见 Global Constraints**）：
```bash
# ① UIKit 基线：脚本生成，绝不手写（catalyst-gate.test.sh 会校验签入基线与源码现推导是否漂移）
python3 .github/scripts/uikit-expected-tests.py > .github/scripts/catalyst-uikit-baseline.txt
git diff --stat .github/scripts/catalyst-uikit-baseline.txt   # 人工核一眼：增删项是否正好等于本 task 的测试增删
# ② total 基线：按真实日志里的 `✔ Test run with N tests` 改（不许拍脑袋）
grep -o '✔ Test run with [0-9]* tests' /tmp/cat-slice2-t3.log | tail -1
```
Run: `bash .github/scripts/catalyst-gate.test.sh` → Expected: 自测全绿
Run: `bash .github/scripts/catalyst-gate.sh /tmp/cat-slice2-t3.log` → Expected: `GATE PASS`

- [ ] **Step 9: Commit**
```bash
git add -A ios/Contracts .github/scripts
git commit -m "划线1a-iii切片2 Task3：常驻样式面板（类型行+5组参数、三组图标化、直读 session 单一真相）替换长按卡片"
```

---

## Task 4: 上下摆放（⇅ 手动切 + 镜像）+ 四态布局不变量 + 上半区盾

**Files:**
- Create/Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStylePanel.swift`（`DrawingStylePanelPosition` 定稿 + 镜像已在 Task 3 落，本 task 补 ⇅ 真行为）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（overlay alignment 随位置切；⇅ 翻转 `stylePanelPosition`；位置变化清盾）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingLayoutInvariantTests.swift`（三态 → **四态**）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingTapHitShieldTests.swift`（上半区盾的差分测试）

**Interfaces:**
- Produces: `enum DrawingStylePanelPosition { case top, bottom }`（`Equatable`；纯 UI 状态、**不落盘、不进任何持久化模型**）。

- [ ] **Step 1: 写失败的四态几何断言 + 上半区盾测试**

`DrawingLayoutInvariantTests.swift`——把 `chartFrame(isDrawing:expanded:)` 加一个 `position` 参数（默认 `.bottom`），并新增：
```swift
    @Test("四态布局不变量：训练 / 画线-收起 / 画线-展开(下半区) / 画线-展开(上半区)——chartPanels 容器 frame 逐像素相等")
    func chartFrameIdenticalAcrossFourStates() throws {
        let training  = try chartFrame(isDrawing: false, expanded: false)
        let collapsed = try chartFrame(isDrawing: true,  expanded: false)
        let bottom    = try chartFrame(isDrawing: true,  expanded: true, position: .bottom)
        let top       = try chartFrame(isDrawing: true,  expanded: true, position: .top)
        #expect(collapsed == training)
        #expect(bottom == training,  "展开(下半区)改变了图表容器尺寸 → 面板在挤压 K 线，不是 overlay")
        #expect(top == training,     "切到上半区改变了图表容器尺寸 → 面板在挤压 K 线，不是 overlay")
    }
```
> **mutation-verify（必做，防假绿）**：临时把 `DrawingStylePanel` 从 `.overlay` 改成 VStack 成员，确认本测试 **FAIL**；改回后 PASS。**在 commit message 或 task report 里写明这次 mutation 的实测结果**——只说「测试绿」不算证据（切片 1 Task3 的既有做法）。

`DrawingTapHitShieldTests.swift` 新增：
```swift
> ⭐**codex 计划-R1-F3 修正**：原稿这两条用 60/40 矮 fixture + `lower.height < 下面板高` 这种**松散启发式**，
> 两个方向都不成立——正确实现若整块覆盖 40pt 的下面板会被**误判失败**；而一个几乎全量的**残留旧盾**只要
> 矮一点就**蒙混过关**。改用 Task 2 引入的**双高面板 fixture**（上下都 400pt），让面板**整块**落在单个面板内 →
> 判据变成**精确的 nil / 非 nil**，没有「多矮才算清干净」的模糊地带。

    @Test("上半区（镜像）盾（精确判据）：面板整块落在上面板内 → 上面板有盾贴顶边、**下面板盾 == nil**")
    func topPositionShieldsUpperPanelOnly() throws {
        let (lowerHandle, engine) = makeDrawingActiveChart(
            panel: .lower, bounds: CGRect(x: 0, y: 0, width: shieldTestPanelWidth, height: shieldTestTallPanelHeight))
        renderAndConverge(TallPanelsShellLayout(engine: engine, typeRowExpanded: true, stylePanelPosition: .top))

        let upper = try #require(shieldRectOf(engine, 0), "上半区时上面板必须有盾")
        // 前提自检：面板必须真的装得下在上面板内，否则退化成跨面板场景、本测试失去意义。
        try #require(upper.height < shieldTestTallPanelHeight,
                     "样式面板高于 fixture 面板高度 → 调大 shieldTestTallPanelHeight（先打印实测，别猜）")
        // 顶边对齐：盾顶边 == 上面板顶边 + 8pt 离屏边距（spec §2.3「类型行顶边贴上半 K 线顶边」）。
        #expect(abs(upper.minY - 8) <= 0.5, "盾未贴上面板顶边（期望 8pt 边距，实测 \(upper.minY)）")
        // ⭐精确判据：下面板**完全没有**盾（不是「矮一点」）。
        #expect(engine.drawingSession.shield[1] == .unshielded, "下面板未处于 .unshielded = 过度屏蔽或未收敛")
        let c0 = engine.drawings.count
        lowerHandle.handleDrawingTapForTesting(at: leftmostMainChartPoint(lowerHandle))
        #expect(engine.drawings.count == c0 + 1, "下半 K 线落不了线 —— 面板在上半区却挡住了下面板")

        // ⭐codex 计划-R10-F2：光断言「上面板有盾 + minY≈8」**证明不了 §4.4 的「点面板空隙不落线」**——
        //   一个尺寸过小/错位的上面板盾照样满足这两条，而可见面板下方大片区域仍会穿透并 autosave 幽灵线。
        //   必须补**上面板的真差分**：盾内可落线点 → 装盾时被拒、清盾后落线。
        // ⭐codex 计划-R11-F1：**必须挂在同一个 engine 上**。`makeDrawingActiveChart` 每次都新建一个
        //   TrainingEngine——若在这里再调它一次，upperHandle 会绑到**另一个** engine：
        //   ①「装盾被拒」阶段对着本 engine 断言 count 不变 → 天然成立、**假绿**（根本没往这个 engine 落线）；
        //   ②「清盾后落线」阶段对正确实现**必然失败**（clearAllShields 清的是本 engine、tap 落在另一个）。
        //   故用 `makeChartHandle(engine:panel:bounds:)` 复用**已渲染、已被断言**的那个 engine。
        let upperHandle = makeChartHandle(
            engine: engine, panel: .upper,
            bounds: CGRect(x: 0, y: 0, width: shieldTestPanelWidth, height: shieldTestTallPanelHeight))
        let upperHit = upper.intersection(upperHandle.renderState.viewport.mainChartFrame)
        try #require(!upperHit.isNull && !upperHit.isEmpty,
                     "上面板盾与其可落线区无交集 → 盾尺寸/位置不对，点面板会在上半 K 线误落线")
        let p = CGPoint(x: upperHit.midX, y: upperHit.midY)
        let c1 = engine.drawings.count
        let pend1 = engine.drawingSession.pendingAnchors.count
        upperHandle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c1, "上半区面板内的点竟落了线 = 幽灵线（§4.4「点面板空隙不落线」违规）")
        #expect(engine.drawingSession.pendingAnchors.count == pend1)
        settleWithNoShields(engine.drawingSession)   // 见下方 helper：清盾**并**回到已收敛态
        upperHandle.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == c1 + 1, "清盾后同一点仍落不了线 → 上面那次被拒与盾无关（假绿）")
    }

    @Test("⇅ 切位置后旧盾**精确清零**：下半区 → 上半区，下面板盾必须 == nil，且旧盾位置能重新落线")
    func togglingPositionClearsStaleShieldExactly() throws {
        let (lowerHandle, engine) = makeDrawingActiveChart(
            panel: .lower, bounds: CGRect(x: 0, y: 0, width: shieldTestPanelWidth, height: shieldTestTallPanelHeight))
        // ① 下半区：下面板有盾、上面板无盾。记下旧盾中点，稍后拿它做差分。
        renderAndConverge(TallPanelsShellLayout(engine: engine, typeRowExpanded: true, stylePanelPosition: .bottom))
        let oldShield = try #require(shieldRectOf(engine, 1), "下半区时下面板必须有盾")
        let pInOldShield = CGPoint(x: oldShield.midX, y: oldShield.midY)
        try #require(lowerHandle.renderState.viewport.mainChartFrame.contains(pInOldShield),
                     "旧盾中点须落在可落线区，否则后面的差分证明不了任何事（假绿）")
        let c0 = engine.drawings.count
        lowerHandle.handleDrawingTapForTesting(at: pInOldShield)
        #expect(engine.drawings.count == c0, "装盾时该点竟然落了线 —— 盾没生效，后续差分无意义")

        // ② 切到上半区：下面板盾必须**精确清零**，且**同一个点**现在能落线（证明旧盾真没了）。
        renderAndConverge(TallPanelsShellLayout(engine: engine, typeRowExpanded: true, stylePanelPosition: .top))
        #expect(engine.drawingSession.shield[1] == .unshielded, "切到上半区后下面板未回到 .unshielded = stale shield 死区")
        lowerHandle.handleDrawingTapForTesting(at: pInOldShield)
        #expect(engine.drawings.count == c0 + 1, "旧盾位置仍落不了线 —— 残留屏蔽（下半 K 线死区）")
    }
```

- [ ] **Step 2: 运行 → 确认失败（Catalyst）**

Run: `cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:KlineTrainerContractsTests/DrawingLayoutInvariantTests -only-testing:KlineTrainerContractsTests/DrawingTapHitShieldTests 2>&1 | tail -30`
Expected: FAIL（`position` 参数 / `.top` 挂载尚不存在）

- [ ] **Step 3: `ChartPanelsContainer` 的 alignment 随位置切**

```swift
        .overlay(alignment: stylePanelPosition == .top ? .top : .bottom) {
            if showsTradeButtons, isDrawingActive, typeRowExpanded {
                DrawingStylePanel(session: engine.drawingSession, scheme: scheme,
                                  position: stylePanelPosition, onTogglePosition: onTogglePosition)
                    // ⭐先量、后 padding（R1-F2）：量到的就是写进 shieldRect 的盾，透明边距不得进盾。
                    .background(GeometryReader { g in Color.clear
                        .preference(key: DrawingShieldFrameKey.self, value: g.frame(in: .named("chart"))) })
                    // ⭐codex 计划-R3-F2：这两行**必须保留**，`.top` / `.bottom` 两态都要。
                    //   计划原稿改 Task4 时漏抄了它们——照那版粘贴会让面板 flush 到 0，
                    //   与本 task「上半区 minY == 8」的断言直接打架（把 R2-F1 的矛盾搬进 Task4）。
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
            }
        }
```
> **本块是 overlay 挂载的最终形态**（Task 3 Step 6 的版本只差 `alignment` 与 `position` 接线）。实施者以本块为准，**两行 padding 不是可选项**——`callSiteMeasuresBeforePadding` 守卫会钉住「GeometryReader 在 padding 之前」且「两个方向的 8pt 边距都在」。
> **⭐「贴顶边」的精确定义（codex 计划-R2-F1 消歧，实施者必读）**：spec §2.3 / §4.4 的措辞是「类型行顶边**与**上半 K 线区顶边**对齐 / 贴**」，而 user 已锁定的设计 mock 里是 `.screen.pos-top .stylePanel { top: 8 }`（左右也是 `left/right: 8`）——**两者不一致**，计划原稿同时声称了这两件事（既写「对齐」又断言 `minY == 8`），自相矛盾：实施者若为满足 spec 措辞去掉 padding，Task 4 的断言就会红，且把 F2 的「padding 不进盾」修复一并退回去。
>
> **本计划定为：8pt 内边距（以 mock 为准）**。理由：①mock 是 spec 头部标注「设计已锁定」的产物，比语音转写的散文措辞精确；②上下左右统一 8pt 才视觉自洽（只有顶边贴死、左右留边会很怪）；③圆角面板紧贴容器边缘观感差。spec 散文里的「贴」按**贴近**理解，不是 flush。
> **连带修正**：本计划 §4.4 验收清单的措辞同步改成「类型行顶边**贴近**上半 K 线顶边（约留一指窄边）」，不再写「贴边 / 对齐」。**这是一处 user 可见的视觉决定**——若 user 要真 flush（`minY == 0`），改法是：`.top` 分支不加 `.padding(.vertical, 8)`（只留水平 8pt），并把 Task 4 断言改成 `abs(upper.minY) <= 0.5`。**二选一，计划里不得再同时声称两者。**
>
> 机制上：alignment `.top` 让面板（含 8pt 外边距）顶边贴 `chartPanels` 顶边 = **上半 K 线区顶边**；镜像后类型行是 VStack 第一个成员 → 类型行就是面板最上面那块，无需另算偏移。

- [ ] **Step 4: `TrainingView` 接 ⇅ 与位置变化清盾**

```swift
    @State private var stylePanelPosition: DrawingStylePanelPosition = .bottom
```
`chartPanels` 传 `onTogglePosition: { stylePanelPosition = (stylePanelPosition == .bottom ? .top : .bottom) }`。
并加一条显式清盾（与既有 `typeRowExpanded` 那条同款防御——位置一变，旧位置的盾必须立刻作废，不能等下一轮 preference 收敛）：
```swift
        // 1a-iii 切片2 Task4：切面板上/下半区即清所有盾——旧位置的盾若残留，那半边 K 线会变成
        // 「怎么点都画不了线」的死区（nil-preference 自动重算是第一层，本行是明确的生命周期第二层）。
        // ⭐codex 计划-R16-F1：这里**只能** clearAllShields()，**绝不能**用 settleWithNoShields()。
        //   切位置**正是几何尚未重新收敛的时刻**——清盾后立刻标记「已收敛」等于在最需要保护的瞬间
        //   关掉 fail-closed：新位置的面板已可见、盾还没算出来，此时的 tap 会穿透并 autosave 幽灵线。
        //   正确语义 = 清盾并**保持未收敛**，直到 refreshShields() 见到 overlay + 两个面板 frame 齐备才开闸。
        .onChange(of: stylePanelPosition) { _, _ in
            engine.drawingSession.clearAllShields()      // 全清；随后由 refreshShields 按新几何重置（Step 3 唯一定义）
        }
```
> **`settleWithNoShields(_:)` 是测试专用逃生舱，生产代码一律不得引用**（codex 计划-R16-F1）。守卫：
> ```swift
>     @Test("生产不得使用测试逃生舱（codex 计划-R16-F1）：TrainingView 不引用 settleWithNoShields")
>     func productionNeverUsesTestOnlySettleHelper() throws {
>         let tv = try source("Sources/KlineTrainerContracts/UI/TrainingView.swift")
>         #expect(!tv.contains("settleWithNoShields"),
>                 "生产代码引用了测试逃生舱 —— 会在几何未收敛时开闸，重开幽灵线窗口")
>         let chain = try slice(tv, from: ".onChange(of: stylePanelPosition)", to: "}")
>         #expect(chain.contains("clearAllShields()"), "切位置未清盾 → 旧位置盾残留成死区")
>     }
> ```

- [ ] **Step 5: 运行 → 通过 + mutation-verify**

Run: `cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:KlineTrainerContractsTests/DrawingLayoutInvariantTests -only-testing:KlineTrainerContractsTests/DrawingTapHitShieldTests 2>&1 | tail -30`
Expected: PASS
然后做 Step 1 里要求的 mutation-verify（overlay → VStack 成员 → 四态测试必须 FAIL），**记录实测结果**。

- [ ] **Step 6: 源码守卫（补充快检，非达标判据）**

追加到 `DrawingStylePanelSourceGuardTests`：
```swift
    @Test("镜像只翻两大块、参数内部 5 组顺序两态相同（user 确认）+ ⇅ 在类型行右端")
    func mirrorFlipsOnlyTwoBlocks() throws {
        let panel = try source(self.panel)
        #expect(panel.contains("position == .top"))                 // 两态分支存在
        // 参数区在两个分支里都是**同一个** DrawingStyleParams 调用 → 组内顺序结构上不可能被翻。
        #expect(panel.contains("DrawingStyleParams(session: session, scheme: scheme)"))
        let overlay = try source("Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift")
        #expect(overlay.contains("onTogglePosition"))
        #expect(overlay.contains("Spacer()"))                       // ⇅ 被 Spacer 推到右端
        let tv = try source("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(tv.contains("stylePanelPosition == .top ? .top : .bottom"))   // alignment 随位置切
        #expect(tv.contains("onChange(of: stylePanelPosition)"))             // 位置变化清盾
    }
```

- [ ] **Step 7: 全量三绿 + 基线同步 + Commit**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5` → 全绿
Run: `cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:KlineTrainerContractsTests 2>&1 | tee /tmp/cat-slice2-t4.log | tail -5`
按 Task 3 Step 8 的同一套路更新两个基线（UIKit 基线**重跑 `uikit-expected-tests.py` 生成**、total 基线按日志真实计数改）
→ `bash .github/scripts/catalyst-gate.test.sh`（自测全绿）→ `bash .github/scripts/catalyst-gate.sh /tmp/cat-slice2-t4.log` → `GATE PASS`
```bash
git add -A ios/Contracts .github/scripts
git commit -m "划线1a-iii切片2 Task4：面板上下摆放(⇅手动切+镜像)+四态布局不变量+上半区盾与切位置清盾"
```

---

## 三绿门（切片 2 收尾，作者亲跑，**每条命令同时打印 branch/HEAD**）

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/drawing-p1b-1a-iii" && \
  pwd && git branch --show-current && git rev-parse --short HEAD && git status --porcelain
```
1. `cd ios/Contracts && swift test`（host 全绿）
2. `bash .github/scripts/catalyst-gate.test.sh`（闸门自测全绿）
3. Catalyst `xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:KlineTrainerContractsTests` + `catalyst-gate.sh <log>`（`GATE PASS`，**且 total 与 uikit 基线均 exact 无漂移**）
4. iOS Simulator `xcodebuild build`（`BUILD SUCCEEDED`）

> **反假绿**：Catalyst 若跑的是缓存结果，须 `rm -rf .build/arm64-apple-macosx` 后重跑一次 fresh 全量（`@Observable` 改 stored property 后的 SIGSEGV 陈旧增量构建是本仓踩过的坑）。

## §4.4 人工验收（累积到切片 3 完成后一并交付；本切片新增条目）

| 动作 | 预期 | 通过 / 不通过 |
|---|---|---|
| 进画线 | 面板**默认展开**（类型行 + 参数一起），无需二次点击 | |
| **收起面板 → 点「退出」离开画线 → 再点「画图」进画线** | 面板**又是展开的**（不会停在上次收起的样子）；里面的线型/粗细/颜色**仍是你上次调的** | |
| 点底栏「类型」键 | 整块收起、只剩底栏；**K 线一点没变大变小** | |
| 再点「类型」键 | 整块展开、**回到上次的线型/线样式/粗细/颜色/标注**（没被重置） | |
| 看线型 / 线样式 / 粗细三行 | 全是**画出来的图标**（真实虚线疏密、真实粗细），**一个字都没有** | |
| 看标注行 | 仍是「隐藏 / 显示 / 左 / 右」文字，「显示」是灰的 | |
| 点面板上的空隙 / 背景 / 灰按钮 | **不会在 K 线上多出一条线** | |
| 点类型行右端 ⇅ | 面板整块跳到上半区，**类型行顶边贴近上半 K 线顶边**（约留一指窄边，与左右边距一致）；再点回下半区 | |
| 面板在上半区时点面板空隙 | **上半 K 线不会多出一条线** | |
| 面板在上半区时点下半 K 线 | **正常落线**（没被误挡） | |
| ⇅ 切来切去、收起展开 | K 线区**尺寸自始至终不变**（不被顶起、不被压扁） | |
| 连续画几条，中途改粗细 / 线样式 | **新线用新样式、旧线一点没变** | |
| 长按类型行水平线图标 | **不再弹出**旧的设置卡片（已被常驻面板取代） | |
| 进复盘 | 仍是浮动铅笔钮、**没有**样式面板 | |

## codex 对抗评审修正史

**R1（needs-attention，3 finding 全为真、全部已修）**：
- **F1-high 空测试**：原「不过度屏蔽」测试用 `typeRowExpanded: false`（根本没 overlay）→ 只证明了「没面板⇒没盾」，一个「有任何 overlay 就连上面板一起装盾」的错误实现照样能过。**已改**：新增双高面板 fixture，让 overlay **真的可见且整块落在下面板内**，断言上面板盾 == nil **且**上半 K 线真能落线（`visibleLowerOnlyOverlayLeavesUpperUnshielded`）。
- **F2-high 透明边距进盾**：原 `DrawingStylePanel` 先 `.background(材质)` 再 `.padding(8)`，call-site 的 GeometryReader 量的是含边距的框 → 8pt 透明外边距被写进 `shieldRect`，图表上出现**看不见的死条**；`.contentShape` 同样在 padding 之后。**已改**：面板本体不带 padding、`contentShape` 紧贴可见材质；padding 移到 call site **测量之后**；立不变量「第一道盾 / 第二道盾 / 可见像素三者逐像素同框」；补透明边距差分测试（`transparentGutterOutsideVisiblePanelStillCommits`）。
- **F3-medium 松散启发式**：原 stale-shield 断言 `lower.height < 下面板高` 在 60/40 矮 fixture 下两个方向都不成立（正确实现可能被误判失败、几乎全量的残留旧盾可蒙混过关）。**已改**：换双高面板 fixture，判据变成**精确 nil**，并加「同一点装盾时被拒 / 清盾后落线」的真差分（`topPositionShieldsUpperPanelOnly`、`togglingPositionClearsStaleShieldExactly`）。

**R2（needs-attention，2 finding 全为真、全部已修）**：
- **F1-high 顶边对齐自相矛盾**：计划同时声称「类型行顶边与上半 K 线顶边**对齐**」（spec 散文）和断言 `minY == 8`（mock `top:8`）。实施者按 spec 去 padding → 断言红且 F2 修复退回。**已改**：明确定为 **8pt 内边距、以 mock 为准**（理由三条写在 Task 4 Step 3），§4.4 验收措辞同步改成「贴近（约留一指窄边）」，并写明「若 user 要真 flush 该怎么改」——**计划不再同时声称两者**。⚠️这是一处 user 可见的视觉决定，已在交付汇报中点名。
- **F2-high「三者逐像素同框」不变量是假的**：面板画**圆角**材质而两道盾都是**矩形**，圆角外透明三角仍被挡；且 gutter 测试走 `handleDrawingTapForTesting`、**绕过 SwiftUI 命中测试**，根本验不了第一道盾。**已改**：①不变量降级为**外接矩形**版（能站得住）；②圆角四角约 31pt²/角的过度屏蔽**显式记录并接受**（`shieldRect` 是 `CGRect` API，消掉它代价远大于收益）；③**明写「第一道盾本计划没有真测到」**，只由源码守卫覆盖，承重的是第二道盾（`handleDrawingTap` 是通往 `appendDrawing` 的唯一路径）；④测试改名带 `_inputLayer`，防后来人误读成第一道盾已覆盖。

**R3（needs-attention，2 finding 全为真、全部已修）**：
- **F1-high 声称的第一道盾守卫根本不存在**：R2 里我写「第一道盾由 Task 3 Step 1 源码守卫覆盖」来 justify「不跑真 SwiftUI 命中测试」这个残留风险——但**回头没去加那条断言**，守卫块里 `contentShape` 一个字都没有。等于拿不存在的守卫兑现诚实承诺。**已改**：补 `firstShieldPresentAndPrecedesPadding`（根有 `contentShape(Rectangle())` + `.onTapGesture {}`、面板本体不自带 padding、contentShape 在任何 padding 之前）与 `callSiteMeasuresBeforePadding`（GeometryReader 在 padding 之前、两态 8pt 边距都在）。
- **F2-high Task 4 最终代码块漏抄两行 padding**：我改 Task 4 时重写 overlay 块，把 Task 3 加的 `.padding(.horizontal/.vertical, 8)` 漏了 → 照它粘贴会让面板 flush 到 0，与本 task「上半区 `minY == 8`」断言打架，等于把 R2-F1 的矛盾搬进 Task 4。**已改**：两行 padding 补回最终块并标注「两态都要、不是可选项」，且由 `callSiteMeasuresBeforePadding` 守卫钉死。
- **本轮教训（自记）**：R2/R3 连续两次都是「修复动作本身引入新问题」——R2 立了条验证不了的不变量，R3 是承诺了守卫却没写、改一处代码块漏抄另一处。**改完必须回头核对自己引用的东西真的存在**，这与 memory 里「修 symptom 会挪动失败面」是同一类。

**R4（needs-attention，1 finding、为真、已修）**：
- **F1-high 两条新守卫是「全文首次匹配」→ 可假绿**：`firstShieldPresentAndPrecedesPadding` 只禁 `.padding(.horizontal/.vertical, 8)` 两种**拼法**（`.padding(8)` / `.padding(.all, 8)` 照样过），且全文搜 `contentShape`（文件里另有嵌套/闲置的就够骗过它）；`callSiteMeasuresBeforePadding` 在 670 行、几十处 `.padding(` 的 `TrainingView.swift` 里拿**全文首个** `DrawingShieldFrameKey` 与**全文首个** `.padding(.horizontal, 8)` 比先后——两者根本不在同一条修饰符链上，顺序判据无意义；垂直 padding 更只查了「存在」。而这是第一道盾 + 透明边距不变量的**唯一**自动化覆盖，假绿 = 幽灵线/死区整类问题放行。**已改**：加 `slice(_:from:to:)` helper（两个锚点必须**恰好各出现一次**，否则 fail-closed），把顺序判据全部收进「面板根修饰符链」与「挂 DrawingStylePanel 的那条 overlay 链」内部；面板本体**禁任何写法的 `.padding(`**；`contentShape` 必须唯一；call site 两个方向的 padding 都必须在测量之后，且测量之前不得有任何 padding。

**R5（needs-attention，2 finding 全为真、全部已修；user 拍板「修完再跑一轮就收」）**：
- **F1-high Task2 上面板测试几何上跑不起来**：Task2 阶段 overlay 仍是切片1 那个 ~44pt 贴底类型行，用 60/40 fixture 只探进上面板底部几点，而可落线的 mainChart 是面板**顶部 60%** → 采样点必落在 mainChart 外，`#require` 因 **fixture 几何**而红、与产品行为无关；且原稿的补救建议「调大上面板高度」**方向是反的**（贴底薄片会离顶部 60% 更远）。**已改**：新增 `shieldTestShortUpperPanelHeight = 24` + `ShortUpperShellLayout`——把上面板改**矮**到贴底 overlay 完整覆盖它；采样点改取「盾 ∩ mainChartFrame」**真实交集中点**（不再盲取 `shield.midY`）；错误的补救建议已删除并写明正确方向。
- **F2-high 根链切片仍未真正框住根链**：切到文件级 `#endif` 会把后续 helper/extension 一并吞入 → 一个「根链无 `contentShape`、但后面 helper 里有一处」的文件可假绿满足守卫。**已改**：生产代码在根 `.onTapGesture {}` 后紧跟 `.accessibilityIdentifier("drawingStylePanel")` 作**根链专属终止锚**，切片切到它为止；并加「切片内不得出现 `func `/`struct `/`extension `/`var body` 声明边界」的 fail-closed 检查。
- **三套 shield fixture 分工已在 Task2 显式写明**（60/40 跨面板 · 24 矮上面板 · 400 双高），防实施者混用。

**R6（末轮，needs-attention，1 finding、为真、已修；user 授权本轮后收口，故修完**未再送审**）**：
- **F1-high R5 的修法没闭合、只是把问题挪进新 fixture**：overlay 贴的是**整个容器**底部 → `往上探进上面板的量 = overlay高 − 下面板高`。**杠杆是下面板高度**，而 R5 只缩了上面板（60→24），探进量仍是 `44−40 = 4pt` 且探的是上面板**底部**，与顶部 60% 的 mainChart 交集**依然为空**。**已修**：新增 `shieldTestShortLowerPanelHeight = 8`，判据改成「**两面板高度之和 < overlay 高度**」→ 贴底 overlay 整个盖满上下面板，两个盾必然非空且完整覆盖各自 mainChart；`#require` 失败信息改写成多行诊断（含正确修法方向 + 实测值打印），明确标注「非产品缺陷、别放松断言」。
- **收口状态（如实记录）**：本计划经 codex 对抗评审 **6 轮**（finding 3→2→2→1→2→1），**每一轮的每一条我都核为真、无一驳回**，但**始终未获干净 approve**；R6 的修复**未经再次评审**。按 user 拍板（「修完 R5 两条再跑一轮就收」）**accept 残留 + override 进实施**。
- **残留风险与兜防**：①R6 修复未经评审——实施 Task 2 时**第一步就实测 overlay 高度**验证 fixture 前提，`#require` 已 fail-closed 钉住；②第一道盾仍只有源码守卫、无真 SwiftUI 命中测试（R2-F2 已记录接受）；③圆角四角约 31pt²/角过度屏蔽（R2-F2 已记录接受）。三者均在实施阶段的**逐 task 评审 + whole-branch Opus 评审 + 三绿门**重点盯防。
- **6 轮弧线的自我复盘**：6 条 finding 里只有 2 条是原始设计缺陷（透明边距进盾、顶边对齐矛盾），**其余 4 条全是我的修复动作自己引入的**（立了验证不了的不变量 / 声称了没写的守卫 / 改代码块漏抄 / 守卫用全文首次匹配 / fixture 方向搞反两次）。教训：**改完必须回头核自己引用的东西是否真存在、并把几何类判据真正算一遍再写数**——这与 memory 里「修 symptom 会挪动失败面」同源。

**R7（needs-attention，1 finding、**medium**、为真、已修 + 我据此自查又补 5 条）**：
- codex 确认 **R6-F1 的 fixture 几何已闭合**（"now plausible"），本轮无 high 级问题——自 R1 以来首次。
- **F1-medium 既有 `splitBarsCarryD19D24` 与新守卫互斥**：该测试（`DrawingTapHitShieldTests.swift:93`）断言 `overlay.contains("onLongPressType")`，而 Task 3 要删钩子并新增断言其**不存在** → 两条测试要求相反，Task 3 过不了全量门。这是**切片 1 Task 2 Step 6b「守卫先迁移再删」那条守则的原样复发**——我把它用在了 `DrawingStyleCardSourceGuardTests` 上，却漏了另一个文件里的第二条守卫。**已修**：新增 Task 3 **Step 5b** 显式迁移该守卫。
- **⭐据 F1 的根因对策（穷尽 grep）又自查出 5 条 codex 未提到的破坏**，其中一条会**直接编译失败**：`DrawingPanelFrameKey` 改名（Task2，旧名非新名子串）、`DrawingTypeOverlay(` marker（Task3）、`.overlay(alignment: .bottom)` marker（Task4）、`contentShape` 读错文件（Task3）、`DrawingLayoutInvariantTests.swift:81` 传 `onLongPressType:`（Task3，编译失败）。**已修**：新增「**既有测试迁移矩阵**」章节，逐条列出位置 / 断在哪个 task / 为什么断 / 改成什么，并写明「删改任何被守卫引用的符号前必须先全仓 grep」的实施纪律。
- **本轮体会**：codex 找到 1 条，按它给的根因对策自查又找到 5 条——**对策比 finding 本身值钱**。

**R8（needs-attention，1 finding、medium、为真、已修）**：
- **F1-medium 迁移矩阵仍不穷尽**：漏了 `DrawingLayoutInvariantTests.swift:125`（`chartNotInExpandedBranch_sourceGuard` 断言 `tv.contains("DrawingTypeOverlay(")`），Task 3 换挂载后必红。**已修**：补进矩阵并给出改法（前半条换 `DrawingStylePanel(`，`accessibilityIdentifier("chartPanels")` 半条不变）。
- **⭐根因（比 finding 本身重要）**：R7 我刚立了「删符号前先全仓 grep」的纪律，R8 却仍被抓到——因为**我自己跑的符号清单不完整**：grep 了被删的参数名（`onLongPressType`）、被改名的类型（`DrawingPanelFrameKey`），却**没 grep 被替换的组件名 `DrawingTypeOverlay(` 本身**。纪律对了，执行清单错了。**已修**：把 grep 清单写成**固定的、可直接粘贴的 11 个符号 for 循环**，并明确「要改的组件名 / 被删的参数名 / 被改名的类型名 / 被换掉的修饰符字面量**四类都要在列**」，不许临场手挑。
- **本轮我另做的交叉核实**（跑完整清单后确认**不受影响**、无需迁移）：`DrawingStyleAvailabilityTests` 的 6 条 `colorEnabled` 断言（颜色语义留切片 3，故仍绿——反向印证 Global Constraints 里「切片 2 不动颜色」这条切分是自洽的）、`TrainingViewShellSourceGuardTests` 的 3 条 `DrawingBottomBar` 断言、`DrawingBottomBarHeightTests` 全部、`ChartPanelsContainer` 泛型签名锚。

**R9（needs-attention，3 finding、全 medium、全为真、全部已修）**：
- **F1-medium 根因对策自己出现了「两份真相」**：R8 后我在矩阵章节立了固定 11 符号 grep 循环，但 **Task 3 Step 5b 仍留着那份手挑短清单**（正是漏掉 `DrawingTypeOverlay(` 造成 R8 的那份）。就近阅读的实施者会把短的当权威、原样复现失败。**已修**：删掉本地短清单，改为**只引用**矩阵那条循环，并写明「清单只能有一份真相，本地 step 只引用不复制」。
- **F2-medium 5 个 `ChartPanelsContainer(` 调用点未按最终签名迁移** → Task 3 改签名时**全部编译失败**。**已修**：新增「**容器签名定稿**」小节给出最终签名 + 测试外壳统一传法（`scheme: .light` / `onTogglePosition: {}`），矩阵加一行覆盖全部 5 处，并写明 Task 2 过渡期按旧签名接、Task 3 一次性全改。
- **F3-medium ⭐产品行为缺陷（非测试问题）**：`typeRowExpanded` 是 `@State` 只初始化一次 → 用户「收起面板 → 退出画线 → 再进画线」会停在**收起态**，样式控件被藏住，违反 spec §2.1「进画线默认展开」和我自己写的 §4.4 验收行。我的实施步骤里**完全没有这一笔**。**已修**：补可执行守卫 + §4.4 增一条验收行；并澄清「记住上次」指**工具与样式参数**（存 session、整局有效），**展开态是每次进画线重置的会话内 UI 态**，两者不是一回事。
  > ⛔**本条当轮的落点已被 R10-F1 推翻，勿照此实施**：R9 时我把重置塞进 `.onChange(of: drawingModeActive)` 并给闭包加了 `if`——那会削弱 `tradeBoundary` 交易安全守卫。**正确落点见 R10-F1 与 Task 3 Step 5a：放 `toggleDrawing()`**。此处保留原文只为记录判断过程，**不是可实施内容**。
- **本轮观察**：finding 从 1 回升到 3，但**全部 medium、且 F3 是真实产品行为**——说明评审已从「计划自洽性」下沉到「行为完整性」层面。high 连续三轮清零。

**R10（needs-attention，3 finding、含 1 high、全为真、全部已修）**：
- **F1-high ⭐我 R9 的修复会逼人削弱一条交易安全守卫**：R9-F3 我把展开重置塞进 `.onChange(of: drawingModeActive)`，改签名为 `{ _, isActive in }` 并加 `if`。但 `TrainingViewShellSourceGuardTests.tradeBoundary` 经切片 1 codex **R6/R9/R11 三轮加固**，精确要求 `{ _, _ in` 签名**且**断言闭包体 `!contains("if ")`——理由是 `tradeStrip` 必须**进出两方向都清**，否则陈旧买卖框跨 round-trip 幸存、退出后 remount 在同 tick/period 被放行成交（不可逆）。我的改法会让实施者二选一：门红，或**削弱交易安全守卫**。**已修**：**根本不碰那个闭包**，把重置移到 `toggleDrawing()`——所有进入路径的唯一 UI 入口（训练/replay 画图钮 + 复盘浮动钮共用），且 `drawingModeActive` 在此仍是**切换前**的值，`!active` 即「即将进入」。另加冗余守卫 `drawingModeOnChangeStaysUnconditional` 钉死该闭包不被改动，并在计划里插入 🚫 警示段。
- **F2-medium 上半区测试证明不了 §4.4「点面板空隙不落线」**：原只断言上面板盾非 nil + `minY≈8` + 下面板 nil，一个尺寸过小/错位的盾照样满足，可见面板下方仍会穿透 autosave 幽灵线。**已修**：补上面板**真差分**（盾 ∩ 可落线区取点 → 装盾被拒、清盾落线）。
- **F3-medium `expanded:` 残留造成第二份 API 真相**：Interfaces 行写 `DrawingStylePanel(session:scheme:position:expanded:onTogglePosition:)`，而实现块与 Step 5 都已去掉 `expanded`。**已修**：Interfaces 行删 `expanded:` + 说明「展开态只由挂载条件决定」+ 加守卫 `panelHasNoExpandedParameter`。
- **⭐本轮最重要的教训**：这是**第 5 次**「我的修复引入新问题」，但性质最严重——前几次是文档/测试自洽性，这次会**直接侵蚀交易安全**。根因是我只盯着「让新行为成立」，没问「这个落点被什么既有不变量守着」。**加新状态/新副作用前，先 grep 该落点是否已被守卫钉死、以及那条守卫是为什么立的。**

**R11（needs-attention，1 finding、high、为真、已修）**：
- **F1-high 我 R10 补的上半区差分测试挂错了 engine**：`makeDrawingActiveChart` **每次都新建 TrainingEngine**，我在同一测试里二次调用它取 `upperHandle`，却把 tap 打到新 engine、断言打在旧 engine 上 → ①「装盾被拒」阶段天然成立（**假绿**，压根没往被断言的 engine 落线）；②「清盾后落线」阶段对**正确实现必然失败**（假红）。R10-F2 因此并未闭合。**已修**：抽出 `makeChartHandle(engine:panel:bounds:)` 复用**已渲染、已被断言**的那个 engine，`makeDrawingActiveChart` 重构为其上层（共用接线不复制）；并立自检规则「**一个测试里只许调一次 `makeDrawingActiveChart`**，其余面板一律走 `makeChartHandle(engine:)`——出现两次即跨 engine 假绿嫌疑」。
- **我本轮自查另修一处（codex 未提）**：R9 修正史里仍写着被 R10 推翻的危险落点（往 `onChange` 闭包塞 `if`），实施者翻修正史可能照做 → 已加 ⛔ 标注「本条落点已被 R10-F1 推翻、勿照此实施、正确落点见 Task 3 Step 5a」。**修正史本身也会变成第二份真相**，这是本次评审第四次出现该形态。
- **本轮教训**：R10-F2 我补的是「测试覆盖不足」，补的时候**新测试自己是坏的**——「补测试」和「补对的测试」是两件事。多面板/多 rig 场景的第一检查项应是**共享同一个被断言对象**。

**R12（approve）→ R13（needs-attention，2 finding、含 1 high、全为真、全部已修）**：
- ⚠️**R12 的 approve 不作数，原因要记清楚**：R12 我在 `--focus` 里塞了大段散文，把评审**窄化**到「R11-F1 是否闭合」，codex 据此给了 approve（其结论原文也只声称「R11-F1 appears closed…no remaining **same-test object/engine mismatch**」）。改用**文件路径**作 focus（脚本本来的用法）重跑 → 无窄化的全文评审 → 立刻 needs-attention。**教训：带定向 focus 的 approve ≠ 整份文档 approve；收口必须以无窄化的全文评审为准。**
- **附带发现的工具缺陷**：`codex-attest.sh` 在 working-tree 模式把 `--focus` 同时当作「给 codex 的关注点文本」与「写账本用的文件路径」（`git hash-object "$f"`）。我 12 轮传散文 → codex 收到了关注点、但账本写入 fatal、`set -e` 下静默退出 → **12 轮全部没写账本**。属 attest 脚本的语义冲突，切片 2 之外单独处理。
- **F1-high 探针片段无法编译**：用了 `HStack`/`GeometryReader`/`ImageRenderer` 却在只 `import Foundation/Testing` 的文件里，且引用了**从未定义**的 `IconProbeFrameBox`——**第三次「声称了没写」**（R3-F1、R11 修正史、本条）。**已修**：整段移入文件末独立 `#if canImport(UIKit)` 段，补 `import SwiftUI/UIKit`、定义 `IconProbeFrameBox` 与本文件专用 `IconProbeFrameKey`（不复用布局不变量测试的 key，语义不混用）。
- **F2-medium ⭐画白板也能全绿**：源码守卫只查符号在不在、文字有没有；flatten 探针只查 frame 非零——**没有一条验证真的画出了像素**。Canvas 写错就 ship 三排空白方块而全绿，而本切片的**全部意义**正是「用户能看见并分辨这些图标」。**已修**：加三条**像素级**测试（白底黑前景渲染 → 8-bit 灰度位图 → 统计墨点与像素签名）：①三种线型都有墨且两两签名不同；②五种线样式都有墨、两两不同、且**非实线墨量必须少于实线**（证明 dash 真的在断线而非被忽略）；③粗细 1…5 墨量**严格递增**。并写明「不稳时可调画布/放大系数拉开差距，**但不许把严格递增改成不减、不许删两两可分辨断言**」。
- **本轮教训**：前 12 轮我一直在验「计划自洽 / 测试能不能测到行为」，却漏了最朴素的一问——**这个功能做出来长什么样，有没有任何测试能证明它不是空白的**。

**R14（needs-attention，3 finding、含 1 high、全为真；F2/F3 照修，F1 我提了反方案）**：
- **F1-high 第一道盾无实测 —— 我不照建议做，改为消除风险本身**。codex 要求加「合成真实 tap 的 Catalyst UI 测试」。**该建议在本仓 harness 不可行**：切片 1 已实证 headless Catalyst 挂 `UIWindow` 直接崩（无 `NSApplication`），合成命中测试需要 window/hit-test 树；codex 自己也给了 fallback「做不到就当阻塞风险」。**我的处理**：codex 指出的具体危险是「面板已可见、但 `shieldRect` 尚未经 preference 链装好」的窗口期——此时唯一防线是测不了的第一道盾。故加 `stylePanelVisible` / `shieldsSettled` 两个**同步置位**（不经 preference）的状态，`handleDrawingTap` 在「面板可见 && 盾未收敛」时**拒收一切 tap**（fail-closed），配 host 纯逻辑测试 + Catalyst 窗口期差分测试。**效果**：第一道盾**不再是任何时刻的唯一防线**——窗口期由 fail-closed 兜，窗口期后由有真差分测试的输入层盾兜；第一道盾退化为纯体验优化，不再承载 trade-safety。**残留如实记录**：第一道盾本身仍只有源码守卫，无自动化覆盖。
- **F2-medium ⭐我的守卫判据写错，把可访问性一起禁掉了**：`lineGroupsAreIconsNotText` 原禁「`"直线"/"射线"/"实线"/"虚线"` **整个文件**都不许出现」，逼出 `线型一`/`线样式solid` 这类无意义读屏标签 → 图标-only 控件对 VoiceOver 用户**不可用**（选不出直线还是射线），而本 App 可能公开上架。守卫的**意图**是「界面上不显示文字」，不是「这些词不许存在」。**已修**：禁词精确到**可见 `Text("直线")` 一类**；标签改回人话（直线/射线/线段/实线/虚线1-4/粗细N）；新增 `iconOnlyControlsCarrySemanticAccessibilityLabels` **强制**这些语义标签必须在；并改掉原先那段自相矛盾的「刻意不用这些词」说明。
- **F3-medium Task 1 闸门漏跑新测试 + 基线未同步**：Task 1 的 Catalyst 命令只 filter `DrawingStyleIconSpecTests`，而刚加的像素证据在 `DrawingStyleIconRenderTests` → **根本不执行**；且 Task 1 commit 未同步基线，新增 UIKit-gated 测试必致后续闸门红。**已修**：命令加第二个 `-only-testing` 并写明「任一 suite『no tests matched』判失败」；新增 Step 7 基线同步（uikit 基线脚本生成 + total 按真实日志 + 自测 + GATE PASS）后再 commit。

**R15（needs-attention，2 finding、全 high、全为真、全部已修）——两条都在打我 R14 的反方案**：
- **F1-high 我的 fail-closed 修复自己打开了它要关的窗口**：`refreshShields()` 由**三个** `onPreferenceChange` 各自触发、到达顺序不保证。overlay frame 先到而两个面板 frame 未到时，它会 `guard ... else { setShieldRect(nil) }` 把盾清光，**末尾却无条件 `markShieldsSettled()`** → overlay 可见、零个盾、fail-closed 守卫被关掉。**已修**：开闸判据改为「overlay + 两个面板 frame **全部到齐**」才 `markShieldsSettled()`，任一缺失保持未收敛；补**到达顺序全排列**的 host 测试 + 生产代码判据的源码守卫。
- **F2-high ⭐我的测试会把实施者推向不安全的代码**：差分测试里 `clearAllShields()` 后立刻期望同点落线，但按契约它会置 `shieldsSettled = false`、而面板仍可见 → **正确实现反而让测试红**；红了之后最省事的「修法」正是把 `shieldsSettled = false` 从 `clearAllShields()` 删掉——**重新打开裸奔窗口**。**已修**：加 `settleWithNoShields(_:)` helper（清盾**并**显式标记收敛，表达「几何已收敛且该面板确实不被覆盖」这一真实合法状态），三处差分测试改用它；并写明「测试绝不能把实施者推向不安全的代码」。
- **F2 附带：第 5 次「两份真相」**——计划里有两份 `clearAllShields()` 实现，早先那份漏了 `shieldsSettled = false`。**已修**：只保留 Step 3 一处实现，另一处改为⛔引用并标注「同一函数在计划里只能有一处实现」。
- **本轮教训（比前几轮更尖锐）**：R14 我拒绝了 codex「加测试」的建议、改为「消除风险」，方向是对的——但**我实现的消除方案本身有缺陷，且配套测试会诱导实施者把缺陷放大**。提反方案的门槛应当**高于**照做：既然选择不按建议走，就得对自己的方案做更严的边界推演（尤其是异步/顺序不确定的输入）。

**R16（needs-attention，2 finding、全 high、全为真、全部已修）——两条都是我 R15 修复的直接后果**：
- **F1-high ⭐我用 `replace_all` 把测试逃生舱塞进了生产代码，还向 user 报告说"生产代码完好"**：R15 我用 `replace_all` 把 `engine.drawingSession.clearAllShields()` 换成 `settleWithNoShields(...)`，命中 3 处；我**只 grep 了行号就断言"3 处全在测试上下文"**，没读上下文——其中一处在 Task 4 的**生产** `.onChange(of: stylePanelPosition)` 里。后果：切位置时「清盾 + 立刻标记已收敛」，而**切位置正是几何尚未重新收敛的时刻**，等于在最需要保护的瞬间关掉 fail-closed；且生产引用测试 helper 可能编译不过。**已修**：该处改回 `clearAllShields()`（保持未收敛直到几何齐备）；加守卫 `productionNeverUsesTestOnlySettleHelper` 钉死「生产不得引用测试逃生舱」；并**逐处读上下文**复核，确认现只剩 2 处测试用 + 1 处定义。
- **F2-high 第 4 次「声称了没写」**：`stylePanelVisible` 的 `onAppear/onDisappear` 只写在 Step 3 的**散文**里，**没进可粘贴的 `DrawingStylePanel` 实现块**。照块粘贴 → `stylePanelVisible` 恒 false → **整套 fail-closed 防护静默失效**，窗口期又只剩那道测不了的手势盾。**已修**：两个钩子写进实现块；加守卫 `panelCarriesVisibilityHooks`。
- **⭐本轮教训（针对我自己的工具使用）**：①**`replace_all` 是危险操作**——它跨越了「测试 / 生产」这条语义边界而我没察觉；此类替换后必须**逐处读上下文**，不能用「grep 出行号 + 看起来都在测试段」代替。②**我据此向 user 做了一次错误陈述**（"生产代码调用全部完好"）。verification-before-completion 的铁律在这里被我违反了：我用 grep 行号当证据，而它证明不了上下文归属。

## Self-Review（写完自查）

**1. spec 覆盖**
- §2.1 触发与生命周期（默认展开 / 类型键开合 / 常驻 / 记住上次）→ Task 3（面板挂载 + 直读 session 保证「记住」）✓；「收 / 展只切 overlay 可见性、不增删布局高度」→ Task 4 四态几何断言✓。
- §2.2 结构（类型行 + 5 组参数 + ⇅）→ Task 3/4 ✓。
- §2.3 上下摆放与镜像（手动 ⇅、上半区类型行顶边对齐、只翻两大块）→ Task 4 ✓。
- §2.4 布局不变量 + 命中屏蔽 → Task 2（盾泛化）+ Task 4（四态断言）✓。
- §3 图标化（线型 / 线样式 / 粗细画出来、灰态只灰无文字、标注维持文字）→ Task 1 + Task 3 ✓。
- §7-3 面板生命周期 / §7-4 上下镜像 / §7-5 布局不变量 / §7-6 图标化 source-guard / §7-8 命中屏蔽 → 分别落在 Task 3 / 4 / 4 / 3 / 2 ✓。
- §4 自适应线色（§7-1/2/9）**本切片明确不做** → 切片 3；Global Constraints 已写死「颜色语义不动」防实施者顺手做掉。
- §7-7 前作回归 → 三绿门跑全量既有测试✓。

**2. 占位扫描**：无 TBD / 无「类似 Task N」/ 每个代码步骤都给了完整可粘贴代码。三处**显式标注的实测项**均写明「先实测再调、不许猜」及处理方式，非占位：
- Task 1 Step 6：`ImageRenderer` 能否 flatten `Canvas`（**阻塞级**，失败即 escalate，不得私自降级几何断言）。
- Task 2 Step 1：`shieldTestUpperPanelHeight` 是否够容采样点（先打印实测 frame 再调数值）。
- Task 3 Step 3：可访问性文案与守卫禁词表的一致性（要么改文案、要么换更精确判据，**不许把守卫改松**）。
- Task 2 Step 1：`shieldTestTallPanelHeight = 400` 是否真的装得下样式面板——测试内已用 `#require` 把这个前提**显式钉住**，装不下会明确报错要求调大（**不许改松断言把它绕过去**）。

**3. 类型一致**：`DrawingStylePanelPosition`（非 `PanelId`、非 `PanelPosition`）、`clearAllShields()`、`refreshShields()`、`PanelShield`(`.unshielded`/`.pending`/`.rect`)、`setShield(_:panel:)`、`setStylePanelVisible(_:)`、`clearAllShields()`、`shieldRectOf(_:_:)`(测试)、`DrawingUpperPanelFrameKey`/`DrawingLowerPanelFrameKey`/`DrawingShieldFrameKey`、`DrawingStyleIconSpec.iconWidthAmplification`/`.dashPattern(for:)`/`.iconLineWidth(forThickness:)`（均派生自 `HorizontalLineTool.dashPattern(for:)`/`.lineWidth(forThickness:)`）、`LineSubTypeIcon`/`LineStyleIcon`/`ThicknessIcon`、`DrawingStyleParams(session:scheme:)`、`DrawingStylePanel(session:scheme:position:onTogglePosition:)` — 跨 task 逐一核对一致。**已删的名字**：`DrawingStyleIconSpec.isRoundCapped`（渲染层无圆端帽语义，加了又是一处不一致）——计划全文不得再出现。
`ChartPanelsContainer` 签名演进：Task 2 保持切片 1 原签名 + 内部盾泛化；Task 3 去 `onLongPressType`、加 `scheme`/`stylePanelPosition`/`onTogglePosition`；Task 4 只改 alignment。测试里的 `TrainingShellLayout` 每次随之更新（Task 2 Step 1 与 Task 3 Step 6 均已点名）。

**4. 不做项**：自适应线色渲染 / 删 `colorEnabled` / 7 彩 + 线色（切片 3）；平移 / 切周期 / 缩放（1a-iv）；选中 / 删除 / 锁定 / 撤销（1b）；②–⑤ 键与多工具（D19/D24/P1c）；面板位置或默认样式落盘（P6）。

## Execution Handoff

计划存 `docs/superpowers/plans/2026-07-19-drawing-P1b-1a-iii-slice2-resident-style-panel.md`。
下一步：**codex 对抗性评审本计划到收敛** → `superpowers:subagent-driven-development` 逐 task 实施（subagent 一律 Sonnet high）。

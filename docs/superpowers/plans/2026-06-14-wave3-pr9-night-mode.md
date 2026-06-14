# Wave 3 顺位 9：夜间模式（白天/夜间/跟随系统）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让全 app 颜色随用户 `display_mode` 设置（白天/夜间/跟随系统）切换：SwiftUI 界面经单一 `.preferredColorScheme` 适配系统色，UIKit 图表（`KLineView`）按 scheme 选取 light/dark 两套 13-token 调色板并在 trait 变化时重渲染。

**Architecture:** 三层最小改动。① 纯值层：新增 light `AppColorRGBA` 集（现有 13 token = dark 集，按 RFC 复用零破坏）+ scheme 选取器。② UIKit render 层：`KLineView` 经 `themeController.resolve(trait:)` 解析当前 scheme，所有 `AppColor.X` 静态消费点改读 scheme-aware `currentPalette.X`；override `registerForTraitChanges` → `setNeedsDisplay`。③ App 接线：`AppRootView` 按 `settings.displayMode` 加 `.preferredColorScheme(...)`，一处即把强制 scheme 推给所有 SwiftUI 系统色 + 经 trait 传播到嵌入的 `KLineView`。

**Tech Stack:** Swift 6 / SwiftUI（App 生命周期）/ UIKit（`KLineView` Core Graphics 绘制）/ Swift Testing（`@Suite`/`@Test`）/ Swift Package（`ios/Contracts`，host macOS swift test + Catalyst build-for-testing CI）。

**Spec 权威：** `docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` §4.3（夜间调色板 + display_mode，codex 18 轮收敛）。outline `docs/superpowers/specs/2026-06-09-wave3-outline-design.md` §二 顺位 9。

---

## 背景与约束（实现前必读）

### 已存在的基础设施（不重建）
- `Models.swift:41` `DisplayMode {light, dark, system}`（M0.3，Codable）。
- `Theme.swift:9` `AppColorScheme {light, dark}` + `:14` `resolveColorScheme(displayMode:traitIsDark:)` + `:79` `ThemeController.resolve(trait:)`（@MainActor @Observable，default `displayMode == .system`）。
- `Theme.swift:45-64` `AppColorTokens`（13 个 `AppColorRGBA` 默认色，**dark 取向**，background `0.10,0.10,0.12` 近黑）。
- `Theme.swift:102-116` `AppColor`（13 个 UIKit `UIColor` 桥 = `AppColorTokens` 同名 token）。
- `AppState.swift:161` `AppSettings.displayMode` + `SettingsDAOImpl.swift:12` settings key `display_mode` 持久化（已落，无 schema 改动）。
- `SettingsStore`（`@MainActor @Observable`，`public private(set) var settings: AppSettings`）。
- `SettingsPanel.swift:69-74` **三模式 Picker 已接线**（绑定 `settings.displayMode`，`set` 经 `settings.update`），label `白天模式/夜间模式/跟随系统`（`SettingsPanelContent.displayModeLabel`）。**toggle UI + 持久化已完整，本 PR 不改 SettingsPanel。**

### 冻结面（F2 PR #39，**禁止破坏**）
- `AppColorTokens.X`（13 dark 静态）+ `AppColor.X`（13 UIKit 桥）+ `ThemeTests.swift` 全部断言（13 token 计数 / D-3 派生 alias / DIF 白 DEA 黄字面 / D-9/D-10 contrast / `AppColorBridgeTests` 桥保真 / `ThemeControllerTests`）。
- RFC §4.3 item 1/设计理由明定：**现有 token 集 = dark/夜间集，复用为 dark 集零破坏；只新增 light 集 + scheme 选取，最小面**。⇒ `AppColorTokens.X` / `AppColor.X` 数值与签名**保持不变**，light 集为**增量新增**。

### 当前缺口（本 PR 要补）
1. 无 light 变体 token；render 层不按 scheme 选取。
2. `KLineView.draw(_:)` 的 8 个 `drawXxx` 直接读 `AppColor.X`（单一 dark）——见 `KLineView+Candles/Volume/MACD/Markers/Crosshair.swift`。
3. `ThemeController` 当前**仅被测试引用，从未注入 app**。
4. 切换 `display_mode` 或系统切暗/亮时，图表不重渲染（无 trait 监听）。

### 范围边界（明确排除）
- **SwiftUI chrome 无需逐视图改色**：全 UI 显式色均为系统/语义色（`.secondary`/`.primary`/`.red`/`.green`/`.orange`/`.regularMaterial`，见 HomeView/Settlement/SettingsPanel/TrainingView），**原生随 `colorScheme` 适配**，单一 `.preferredColorScheme` 即覆盖。
  - **两条独立色轨澄清（R1-Med5）**：SwiftUI 盈亏色（`HomeView.swift:128-129` `.red`/`.green`）= SwiftUI 系统 `.red/.green`（light/dark 两个系统值），与 UIKit 图表 light/dark 集（定制 RGBA）是**独立两轨**：仅保证「红涨绿跌」**方向**一致，**不**保证与图表 token 逐字同深浅（dark 模式下已是现状，非本 PR 引入）。统一两轨超本 PR 范围（YAGNI，不做）。acceptance/runbook 据此措辞，勿以「HomeView light red ≠ 图表 light candleUp」判不一致。
- **画线工具颜色不 token 化**：`HorizontalLineTool.swift:30` 固定橙 `CGColor(srgbRed:0.95,green:0.6,blue:0.1)`，源注释「MVP 固定橙；token 化属后续」——橙在近白/近黑底均有对比，**不属本 PR 13-token 契约**，保持不变。
- **gridLine 不强制高对比**：与 dark 集一致，网格线刻意低对比（dark 用 alpha 0.25），light 集同理刻意 subtle，不纳入 ≥0.4 对比断言。

---

## 关键决策

### D1：统一机制 = `.preferredColorScheme`（SwiftUI 驱动）+ 图表 `themeController.resolve(trait:)`（消费 trait）
单一真相 = `settings.displayMode`。`AppRootView` 一处 `.preferredColorScheme(displayModePrefersDark(mode).map { $0 ? .dark : .light })`：
- `.light`→`.light`、`.dark`→`.dark`、`.system`→`nil`（跟随系统）。
- 该修饰符（a）令所有 SwiftUI 系统色随 scheme 适配；（b）把**强制后的 trait** 经 SwiftUI→UIViewRepresentable 传播给嵌入的 `KLineView`，使其 `traitCollection.userInterfaceStyle` 反映生效 scheme。

**传播依据（R1-High2：D1 不可作公理，须给依据）**：SwiftUI `.preferredColorScheme(_:)` 通过宿主 `UIHostingController` 把 forced `userInterfaceStyle` 注入 UIKit trait 环境，沿视图层级下传到经 `UIViewRepresentable` 宿主的子 `UIView`（`KLineView`）的 `traitCollection`——这是 SwiftUI/UIKit trait bridge 的既定语义（iOS 13+）。`registerForTraitChanges([UITraitUserInterfaceStyle.self])` 为 iOS 17 API，与 `Package.swift .iOS(.v17)` 吻合。**风险隔离**：切 `display_mode`（非系统切换）时 `ChartContainerView.updateUIView` 只依赖 `engine`、不会被触发——故图表换色**唯一**触发 = trait-change 回调 → `setNeedsDisplay`。这条链的**决策逻辑**（trait→scheme→选哪套 palette）已被纯值/UIKit 单测逐环节锚定（见下「测试分层」）；仅「preferredColorScheme→trait 注入 + 实际重绘像素」属视图层端到端，由 Task 4 runbook 设备实测（与本项目 C5 十字光标 / C8 交互 / U1-U6 视图壳同款 runtime-runbook 先例，outline §三.3 把运行时矩阵列为顺位 13 收尾阻塞依赖、非各 PR merge 门——本 PR 沿用该治理模型，不另设矛盾的 merge 门）。

**测试分层（R1-High2：核心机制须有可单测锚，不能全外包 runbook）**：
- 决策逻辑（scheme 选取）：`AppPalette.forScheme` + `resolveColorScheme(displayMode:traitIsDark:)` 均为**纯值，macOS host 直跑**（Task1 `forScheme` 测 + F2 既有 `ResolveColorSchemeTests`）——「scheme→哪套色」正确性 host 已锁。
- UIKit 桥 + trait→scheme 组合：`UIChartPalette.forScheme` + `ThemeController.resolve(trait:)`（UIKit-gated；用 `UITraitCollection(userInterfaceStyle:)` 构造 trait 直接断言 `currentPalette` 选取，无需 host 窗口，见 Task 2 测试）——Catalyst 编译验证 + CI test run 执行断言。
- 端到端（preferredColorScheme 注入 + 像素重绘）：Task 4 runbook 设备实测（不可纯单测）。

图表侧：`KLineView` 以 `themeController.resolve(trait: traitCollection)` 解析 scheme。因 `preferredColorScheme` 已把 override「烤进」trait，`ThemeController.displayMode` 保持默认 `.system`，`resolve` 返回 dark ⟺ trait 为 dark——与直接读 trait 等价，且**逐字命中 RFC §4.3 item 3「render 层读 token 时按 `themeController.resolve(trait:)` 返回的 `AppColorScheme` 选 light/dark 集」**。

**为何不让 `ThemeController.displayMode` 承载 override（即不走 window.overrideUserInterfaceStyle 路线）**：本 app 是 SwiftUI App 生命周期（`@main struct KlineTrainerApp: App`），无现成 `UIWindow` 注入点；`preferredColorScheme` 是 SwiftUI+UIKit 统一的惯用路径，单点驱动、不双重施加 override（若 `preferredColorScheme` 强制 trait + `ThemeController` 再按 displayMode 强制 = 双源），故 override 只经 `preferredColorScheme`，`ThemeController` 只读 trait。RFC item 3 的 `themeController.resolve(trait:)` 是**机制锚**，本决策逐字满足。**本 PR 由此首次把 `ThemeController` 接入 app（之前仅测试引用）。**

### D2：light 集取值（dark 派生，WCAG AA 取向；单元测试用 maxChannelDiff 代理，真 AA 设备实测）
按 RFC §4.3 item 2「light = dark 派生：背景反相至近白 / 文本至近黑 / 语义色保红涨绿跌色相 / 辅助线按白底降明度保对比」。具体 RGBA（本 plan 定，遵守 outline「不内联 RGBA 到 outline」纪律——RGBA 落 plan/code 而非 outline）：

| token | dark（现有，冻结） | light（新增） | 理由 |
|---|---|---|---|
| background | 0.10,0.10,0.12 | 0.98,0.98,0.99 | 近白 |
| text | white 0.92 | white 0.13 | 近黑 |
| gridLine | white 0.5 α0.25 | white 0.45 α0.30 | 白底 subtle |
| candleUp（红涨）| 0.86,0.18,0.20 | 0.82,0.10,0.12 | 保红相，白底加深 |
| candleDown（绿跌）| 0.16,0.66,0.36 | 0.05,0.55,0.25 | 保绿相，白底加深（浅绿白底失对比）|
| ma66 | 0.55,0.40,0.85 | 0.42,0.25,0.72 | 紫加深 |
| bollLine | 0.95,0.70,0.20 | 0.75,0.50,0.05 | 金加深（亮黄白底失对比）|
| macdDIF | white 1.0 | 0.15,0.15,0.18 | 白底白线不可见→近黑 |
| macdDEA | 1.00,0.84,0.20 | 0.70,0.45,0.0 | 黄加深为暗琥珀（codex R1-F1：0.80/0.55/0 仅 2.74:1<3，改 3.76:1）|
| macdBarPositive | =candleUp | =candleUp(light) | D-3 alias 保持 |
| macdBarNegative | =candleDown | =candleDown(light) | D-3 alias 保持 |
| profitRed | =candleUp | =candleUp(light) | D-3 alias 保持 |
| lossGreen | =candleDown | =candleDown(light) | D-3 alias 保持 |

**对比测试（codex R1-F1 升级）**：单元测试用**真 WCAG 相对亮度对比**（`wcagContrastRatio`：sRGB→线性 + `0.2126R+0.7152G+0.0722B` + `(L_hi+0.05)/(L_lo+0.05)`），断言 light 7 个图形前景 token vs 近白底 **≥ 3:1**（图形元素阈），替换原 `maxChannelDiff ≥ 0.4` 通道距离代理（该代理放过 DEA 2.74:1）。**marker 字母对比（codex R1-F2）**：交易标记字母为饱和涨/跌圆点上的覆盖文字 = **固定白**（scheme-independent，不用 `currentPalette.text`——light 下 text 近黑会在彩色点上失对比，属回归），断言固定白 vs light/dark 涨跌点 **≥ 3:1**。设备真观感（亮/色温）仍是运行时矩阵项（outline §三.3）。gridLine 刻意 subtle 不计对比。

**`background` token 作用域澄清（R1-Med4）**：`KLineView.backgroundColor = .clear`（`KLineView.swift:28`），图表画布**透明、无 chart-area 底色填充**——图表大面积底色来自 SwiftUI 宿主窗口背景（系统色，随 `colorScheme` 经 `.preferredColorScheme` 适配）。`background` token **仅**用于 `KLineView+Crosshair.drawLabelBox` 的十字光标价签/时签框填充。故 light `background=0.98,0.98,0.99` 只改标签框底色，不改图表大底色（那由 SwiftUI 侧适配）。runbook/acceptance 据此措辞，勿把 `background` token 当图表画布底色契约。

### D3：最小签名扰动——`currentPalette` 计算属性，零 drawXxx 签名改动
不给 8 个 `drawXxx` 加 `palette:` 参数（会触碰 §15.1 #3「方法签名与 draw 派发点逐字匹配」契约 + `DrawDrawingsDispatchTests` + crosshair「spec 字面 3-arg」D1）。改为：`KLineView` 暴露 `var currentPalette: UIChartPalette { UIChartPalette.forScheme(themeController.resolve(trait: traitCollection)) }`；各 `extension KLineView` 方法把 `AppColor.X` 就地改读 `currentPalette.X`（隐式 self）。**所有 draw 派发点签名不变。** `forScheme` 返回缓存 static（`.dark`/`.light`），无逐帧分配。

### D4：`UIChartPalette.dark` 由 `AppPalette.dark` 桥接，`AppColorTokens` 单一真相
`AppPalette.dark` 字段 = `AppColorTokens.X`（冻结值单一来源），`UIChartPalette` 经 `init(_ p: AppPalette)` 桥成 `UIColor`。`AppColor.X` 静态桥保留（F2 冻结公共 API + `AppColorBridgeTests` 断言；本 PR render 改走 `currentPalette` 后 `AppColor.X` 不再被生产消费，但作为冻结公共面 + 测试锚保留，不删——符合「不删既有公共面」纪律）。

---

## 文件结构

| 文件 | 动作 | 责任 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Theme/Theme.swift` | Modify | 纯值层加 `AppPalette`（13 字段 + `.dark`/`.light`/`forScheme`）+ `displayModePrefersDark(_:)`；UIKit 层加 `UIChartPalette`（13 `UIColor` + `.dark`/`.light`/`forScheme`）。`AppColorTokens`/`AppColor` 不动。 |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift` | Modify | 加 `private let themeController = ThemeController()` + `var currentPalette` + init 内 `registerForTraitChanges([UITraitUserInterfaceStyle.self])`→`setNeedsDisplay()`。draw 派发不变。 |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift` | Modify | `AppColor.candleUp/Down/ma66/bollLine` → `currentPalette.X`。 |
| `.../Render/KLineView+Volume.swift` | Modify | `AppColor.candleUp/Down` → `currentPalette.X`。 |
| `.../Render/KLineView+MACD.swift` | Modify | `AppColor.macdBarPositive/Negative/macdDIF/macdDEA` → `currentPalette.X`。 |
| `.../Render/KLineView+Markers.swift` | Modify | `AppColor.text/candleUp/candleDown` → `currentPalette.X`。 |
| `.../Render/KLineView+Crosshair.swift` | Modify | `AppColor.text/background` → `currentPalette.X`（含 private `drawLabelBox`）。 |
| `ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift` | Modify | body 末加 `.preferredColorScheme(displayModePrefersDark(settings.settings.displayMode).map { $0 ? .dark : .light })`。 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/ThemePaletteTests.swift` | Create | 纯值层 light 集断言（完整性/alias/hue/对比/distinctness/forScheme/displayModePrefersDark）+ UIKit `UIChartPalette` 桥保真/distinctness。 |
| `docs/runbooks/2026-06-14-wave3-pr9-night-mode-runtime-acceptance.md` | Create | 三模式切换 + 跟随系统 + 图表重渲染运行时 runbook（outline §三.3）。 |
| `docs/acceptance/2026-06-14-wave3-pr9-night-mode.md` | Create | 非-coder 可执行中文验收清单。 |
| `kline_trainer_modules_v1.4.md` §F2 / `kline_trainer_plan_v1.5.md` §Phase 5 | Modify | 加 light/dark 双集 + scheme 选取契约块 + changelog 行 + RFC 引用（RFC §三 item 3 amend 指示）。 |

未改：`KLineView+Drawing.swift`（画线工具自持橙色，D 边界）、`SettingsPanel*.swift`（toggle 已接线）、`AppColorTokens`/`AppColor`（冻结）。

---

## Task 1：纯值层 light 调色板 + scheme 选取器

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Theme/Theme.swift`（在 `AppColorTokens` 枚举之后、`#if canImport(UIKit)` 之前插入）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/ThemePaletteTests.swift`（新建）

- [ ] **Step 1：写失败测试（纯值层 light 集）**

新建 `ThemePaletteTests.swift`，先只放纯值（非 UIKit）部分：

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("AppPalette light/dark 双集 + scheme 选取（顺位9 夜间）")
struct AppPaletteTests {

    // light 集 13 字段齐全（与 dark 同字段；逐字段非 nil 由类型保证，这里断言计数 + 取值就绪）
    @Test("light 集 13 token 计数")
    func lightThirteen() {
        let p = AppPalette.light
        let all: [AppColorRGBA] = [
            p.candleUp, p.candleDown, p.ma66, p.bollLine, p.macdDIF, p.macdDEA,
            p.macdBarPositive, p.macdBarNegative, p.profitRed, p.lossGreen,
            p.background, p.gridLine, p.text,
        ]
        #expect(all.count == 13)
    }

    // D-3 派生 alias 在 light 集保持（MACD bar / 盈亏 与 candle 同色簇）
    @Test("light D-3 alias：macdBar/盈亏 = candle 同色")
    func lightAlias() {
        let p = AppPalette.light
        #expect(p.macdBarPositive == p.candleUp)
        #expect(p.macdBarNegative == p.candleDown)
        #expect(p.profitRed == p.candleUp)
        #expect(p.lossGreen == p.candleDown)
    }

    // 红涨绿跌色相保持：candleUp 红通道主导、candleDown 绿通道主导，且跨色对比
    @Test("light 红涨绿跌色相：candleUp 红主导 / candleDown 绿主导")
    func lightHue() {
        let up = AppPalette.light.candleUp
        let down = AppPalette.light.candleDown
        #expect(up.red > up.green && up.red > up.blue)         // 红主导
        #expect(down.green > down.red && down.green > down.blue) // 绿主导
        #expect(up.red > down.red)       // 涨更红
        #expect(down.green > up.green)   // 跌更绿
    }

    // 前景 token vs light 背景 maxChannelDiff ≥ 0.4（沿用 F2 dark 集同阈值同方法；gridLine 刻意 subtle 不计）
    @Test("light 对比代理：前景 token vs 近白背景 通道差 ≥ 0.4")
    func lightContrast() {
        let bg = AppPalette.light.background
        let p = AppPalette.light
        for c in [p.text, p.candleUp, p.candleDown, p.ma66, p.bollLine, p.macdDIF, p.macdDEA] {
            #expect(c.maxChannelDiff(to: bg) >= 0.4)
        }
    }

    // light 真的不同于 dark（防 copy-paste：背景/文字/语义色必须切换）
    @Test("light ≠ dark：关键 token 取值切换")
    func lightDistinctFromDark() {
        #expect(AppPalette.light.background != AppPalette.dark.background)
        #expect(AppPalette.light.text != AppPalette.dark.text)
        #expect(AppPalette.light.candleUp != AppPalette.dark.candleUp)
        #expect(AppPalette.light.macdDIF != AppPalette.dark.macdDIF)
    }

    // dark 集 = F2 冻结 AppColorTokens（单一真相，零漂移）
    @Test("dark 集逐字段 = AppColorTokens（冻结复用）")
    func darkEqualsTokens() {
        let d = AppPalette.dark
        #expect(d.candleUp == AppColorTokens.candleUp)
        #expect(d.candleDown == AppColorTokens.candleDown)
        #expect(d.background == AppColorTokens.background)
        #expect(d.text == AppColorTokens.text)
        #expect(d.macdDIF == AppColorTokens.macdDIF)
        #expect(d.bollLine == AppColorTokens.bollLine)
    }

    @Test("forScheme 映射：.dark→dark / .light→light")
    func forScheme() {
        #expect(AppPalette.forScheme(.dark) == AppPalette.dark)
        #expect(AppPalette.forScheme(.light) == AppPalette.light)
    }
}

@Suite("displayModePrefersDark（preferredColorScheme 映射）")
struct DisplayModePrefersDarkTests {
    @Test(".light→false / .dark→true / .system→nil")
    func mapping() {
        #expect(displayModePrefersDark(.light) == false)
        #expect(displayModePrefersDark(.dark) == true)
        #expect(displayModePrefersDark(.system) == nil)
    }
}
```

- [ ] **Step 2：跑测试确认失败（编译错误：`AppPalette`/`displayModePrefersDark` 未定义）**

Run: `cd ios/Contracts && swift test --filter "AppPaletteTests|DisplayModePrefersDarkTests" 2>&1 | tail -20`
Expected: 编译失败，`cannot find 'AppPalette' in scope` / `cannot find 'displayModePrefersDark' in scope`。

- [ ] **Step 3：实现纯值层（Theme.swift 插入）**

在 `Theme.swift` 中 `AppColorTokens` 枚举闭合 `}`（约 L64）之后、`// MARK: - UIKit shell 层` 之前插入：

```swift
// MARK: - 顺位9 夜间：light/dark 双调色板 + scheme 选取（纯值，macOS host 直跑）

/// 13-token 调色板值集。`AppColorScheme` 选取 light/dark（RFC §4.3）。
/// `.dark` = F2 已 ship 的 `AppColorTokens`（PR #39，复用为夜间集，零破坏）；
/// `.light` = dark 派生白天集（背景近白 / 文本近黑 / 红涨绿跌色相保 / 辅助线白底加深保对比）。
public struct AppPalette: Equatable, Sendable {
    public let candleUp, candleDown, ma66, bollLine, macdDIF, macdDEA: AppColorRGBA
    public let macdBarPositive, macdBarNegative, profitRed, lossGreen: AppColorRGBA
    public let background, gridLine, text: AppColorRGBA

    /// 夜间集 = `AppColorTokens` 同名 token（单一真相；冻结复用）。
    public static let dark = AppPalette(
        candleUp: AppColorTokens.candleUp, candleDown: AppColorTokens.candleDown,
        ma66: AppColorTokens.ma66, bollLine: AppColorTokens.bollLine,
        macdDIF: AppColorTokens.macdDIF, macdDEA: AppColorTokens.macdDEA,
        macdBarPositive: AppColorTokens.macdBarPositive, macdBarNegative: AppColorTokens.macdBarNegative,
        profitRed: AppColorTokens.profitRed, lossGreen: AppColorTokens.lossGreen,
        background: AppColorTokens.background, gridLine: AppColorTokens.gridLine, text: AppColorTokens.text)

    /// 白天集 = dark 派生。`up`/`down` 抽出复用，保证 D-3 alias（macdBar/盈亏 = candle）与红涨绿跌色相。
    /// RGBA 取值见 plan §D2；maxChannelDiff ≥ 0.4 代理对比，真 WCAG AA 设备实测（运行时矩阵）。
    public static let light: AppPalette = {
        let up   = AppColorRGBA(red: 0.82, green: 0.10, blue: 0.12)   // 红涨（白底加深）
        let down = AppColorRGBA(red: 0.05, green: 0.55, blue: 0.25)   // 绿跌（白底加深）
        return AppPalette(
            candleUp: up, candleDown: down,
            ma66: AppColorRGBA(red: 0.42, green: 0.25, blue: 0.72),
            bollLine: AppColorRGBA(red: 0.75, green: 0.50, blue: 0.05),
            macdDIF: AppColorRGBA(red: 0.15, green: 0.15, blue: 0.18),
            macdDEA: AppColorRGBA(red: 0.80, green: 0.55, blue: 0.0),
            macdBarPositive: up, macdBarNegative: down,
            profitRed: up, lossGreen: down,
            background: AppColorRGBA(red: 0.98, green: 0.98, blue: 0.99),
            gridLine: AppColorRGBA(white: 0.45, alpha: 0.30),
            text: AppColorRGBA(white: 0.13))
    }()

    public static func forScheme(_ scheme: AppColorScheme) -> AppPalette {
        scheme == .dark ? .dark : .light
    }
}

/// `display_mode` → `preferredColorScheme` 偏好：true=强制夜间 / false=强制白天 / nil=跟随系统。
/// `AppRootView` 据此把 `ColorScheme?` 推给整窗（含嵌入 UIKit 图表的 trait）。
public func displayModePrefersDark(_ mode: DisplayMode) -> Bool? {
    switch mode {
    case .light:  return false
    case .dark:   return true
    case .system: return nil
    }
}
```

- [ ] **Step 4：跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter "AppPaletteTests|DisplayModePrefersDarkTests" 2>&1 | tail -20`
Expected: PASS（8 个 test 全绿）。若 `lightContrast` 失败，按 §D2 表加深对应 light 取值至通道差 ≥ 0.4 后重跑。

- [ ] **Step 5：跑全量纯值测试确认无回归（F2 冻结断言仍绿）**

Run: `cd ios/Contracts && swift test --filter "ThemeTests|AppColor|DisplayMode|resolveColorScheme|AppPalette" 2>&1 | tail -15`
Expected: 全 PASS（含 F2 `AppColorTokensTests`/`ResolveColorSchemeTests` 等冻结断言）。

- [ ] **Step 6：Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Theme/Theme.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ThemePaletteTests.swift
git commit -m "feat(顺位9): AppPalette light/dark 双调色板纯值层 + displayModePrefersDark 映射"
```

---

## Task 2：UIKit `UIChartPalette` + render 层 scheme 接线 + trait 重渲染

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Theme/Theme.swift`（`#if canImport(UIKit)` 块内，`AppColor` 枚举之后）
- Modify: `.../Render/KLineView.swift`、`KLineView+Candles.swift`、`KLineView+Volume.swift`、`KLineView+MACD.swift`、`KLineView+Markers.swift`、`KLineView+Crosshair.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/ThemePaletteTests.swift`（追加 UIKit-gated 套件）

- [ ] **Step 1：写失败测试（UIChartPalette 桥保真 + distinctness）**

在 `ThemePaletteTests.swift` 末尾追加：

```swift
#if canImport(UIKit)
import UIKit

@Suite("UIChartPalette（UIKit 桥；scheme 选取）")
struct UIChartPaletteTests {

    private func channels(_ c: UIColor) -> (Double, Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }

    private func expectBridges(_ ui: UIColor, _ rgba: AppColorRGBA) {
        let (r, g, b, a) = channels(ui)
        #expect(abs(r - rgba.red) < 0.01)
        #expect(abs(g - rgba.green) < 0.01)
        #expect(abs(b - rgba.blue) < 0.01)
        #expect(abs(a - rgba.alpha) < 0.01)
    }

    @Test("forScheme(.dark) 13 字段桥 = AppPalette.dark")
    func darkBridge() {
        let u = UIChartPalette.forScheme(.dark); let p = AppPalette.dark
        expectBridges(u.candleUp, p.candleUp);       expectBridges(u.candleDown, p.candleDown)
        expectBridges(u.ma66, p.ma66);               expectBridges(u.bollLine, p.bollLine)
        expectBridges(u.macdDIF, p.macdDIF);         expectBridges(u.macdDEA, p.macdDEA)
        expectBridges(u.macdBarPositive, p.macdBarPositive); expectBridges(u.macdBarNegative, p.macdBarNegative)
        expectBridges(u.profitRed, p.profitRed);     expectBridges(u.lossGreen, p.lossGreen)
        expectBridges(u.background, p.background);    expectBridges(u.gridLine, p.gridLine)
        expectBridges(u.text, p.text)
    }

    @Test("forScheme(.light) 13 字段桥 = AppPalette.light")
    func lightBridge() {
        let u = UIChartPalette.forScheme(.light); let p = AppPalette.light
        expectBridges(u.candleUp, p.candleUp);       expectBridges(u.candleDown, p.candleDown)
        expectBridges(u.ma66, p.ma66);               expectBridges(u.bollLine, p.bollLine)
        expectBridges(u.macdDIF, p.macdDIF);         expectBridges(u.macdDEA, p.macdDEA)
        expectBridges(u.macdBarPositive, p.macdBarPositive); expectBridges(u.macdBarNegative, p.macdBarNegative)
        expectBridges(u.profitRed, p.profitRed);     expectBridges(u.lossGreen, p.lossGreen)
        expectBridges(u.background, p.background);    expectBridges(u.gridLine, p.gridLine)
        expectBridges(u.text, p.text)
    }

    @Test("light/dark UIColor 真不同（防退化为单集）")
    func uiDistinct() {
        let l = UIChartPalette.light, d = UIChartPalette.dark
        let (lr, _, _, _) = channels(l.background); let (dr, _, _, _) = channels(d.background)
        #expect(abs(lr - dr) > 0.5)   // 近白 0.98 vs 近黑 0.10
    }

    // R1-High2：trait→scheme→palette 选取链（= currentPalette 内部逻辑）用构造 trait 直接断言，无需 host 窗口。
    // 复刻 `KLineView.currentPalette` 的组合：UIChartPalette.forScheme(ThemeController().resolve(trait:))。
    @MainActor
    @Test("trait dark → 选 dark 集 / trait light → 选 light 集（currentPalette 选取链）")
    func traitSelectsPalette() {
        let tc = ThemeController()   // displayMode == .system（override 由 preferredColorScheme 烤进 trait）
        let darkSel  = UIChartPalette.forScheme(tc.resolve(trait: UITraitCollection(userInterfaceStyle: .dark)))
        let lightSel = UIChartPalette.forScheme(tc.resolve(trait: UITraitCollection(userInterfaceStyle: .light)))
        let (dr, _, _, _) = channels(darkSel.background)
        let (lr, _, _, _) = channels(lightSel.background)
        #expect(abs(dr - 0.10) < 0.02)   // dark 集 background 近黑
        #expect(abs(lr - 0.98) < 0.02)   // light 集 background 近白
    }
}
#endif
```

- [ ] **Step 2：跑测试确认失败（macOS 跳过 UIKit 套件；本步在 Catalyst/iOS 下编译失败）**

macOS host 下 `#if canImport(UIKit)` 套件被跳过——本步以编译验证为准：
Run: `cd ios/Contracts && swift build 2>&1 | tail -10`（macOS：UIKit 块不编译，`UIChartPalette` 仍未定义但被 `#if` 守卫，故 build 可能通过——以下一步实现后由 Catalyst CI 真编译断言）。
本地确认失败的可行路径：`swift test --filter UIChartPaletteTests`（macOS 下该 `#if canImport(UIKit)` 套件不存在→0 test，**不作为失败信号**）。**权威失败/通过验证 = Task 末 Catalyst build-for-testing**（见 Step 9）。

> 说明：`UIChartPalette` 是 UIKit-gated，macOS swift test 不覆盖其 UIColor 桥；其纯值来源 `AppPalette`（Task 1）已 host 全测。UIKit 套件 + render 接线由 Catalyst CI 闸门保证（与 C5/C8 render 层先例一致）。

- [ ] **Step 3：实现 `UIChartPalette`（Theme.swift UIKit 块）**

在 `Theme.swift` 的 `public enum AppColor { ... }` 闭合之后、`#endif` 之前插入：

```swift
/// scheme-aware UIKit 调色板：`AppPalette` 经 `UIColor(rgba:)` 桥。
/// `.dark`/`.light` 为缓存 static（无逐帧分配）；`KLineView.currentPalette` 据 trait 选取。
/// `: Sendable`（R1-Low6）：Swift 6 strict-concurrency 下 `public static let` 全局须 Sendable；
/// 字段 `UIColor` 在当前 SDK 视为 Sendable（既有 `AppColor` 同款 static UIColor 已编译过）。
public struct UIChartPalette: Sendable {
    public let candleUp, candleDown, ma66, bollLine, macdDIF, macdDEA: UIColor
    public let macdBarPositive, macdBarNegative, profitRed, lossGreen: UIColor
    public let background, gridLine, text: UIColor

    public init(_ p: AppPalette) {
        candleUp = UIColor(rgba: p.candleUp);   candleDown = UIColor(rgba: p.candleDown)
        ma66 = UIColor(rgba: p.ma66);           bollLine = UIColor(rgba: p.bollLine)
        macdDIF = UIColor(rgba: p.macdDIF);     macdDEA = UIColor(rgba: p.macdDEA)
        macdBarPositive = UIColor(rgba: p.macdBarPositive); macdBarNegative = UIColor(rgba: p.macdBarNegative)
        profitRed = UIColor(rgba: p.profitRed); lossGreen = UIColor(rgba: p.lossGreen)
        background = UIColor(rgba: p.background); gridLine = UIColor(rgba: p.gridLine)
        text = UIColor(rgba: p.text)
    }

    public static let dark  = UIChartPalette(.dark)
    public static let light = UIChartPalette(.light)
    public static func forScheme(_ scheme: AppColorScheme) -> UIChartPalette {
        scheme == .dark ? dark : light
    }
}
```

- [ ] **Step 4：`KLineView` 加 themeController + currentPalette + trait 重渲染**

`KLineView.swift`：在 `renderState` 属性之后、`drawingTools` static 之前加：

```swift
    /// 顺位9 夜间：图表 scheme 解析器。`displayMode` 保持 `.system`——override 由 SwiftUI
    /// `AppRootView.preferredColorScheme` 烤进 trait，本控制器只读生效 trait（RFC §4.3 item 3）。
    private let themeController = ThemeController()

    /// 当前生效调色板：按 trait 解析 scheme 选 light/dark 集（`forScheme` 返缓存 static，无逐帧分配）。
    var currentPalette: UIChartPalette {
        UIChartPalette.forScheme(themeController.resolve(trait: traitCollection))
    }
```

> **`.unspecified` 首帧瞬态（R1-Med3，已知、可接受）**：`ThemeController.resolve` 对 `.unspecified` trait 返 `.light`（D-7，ThemeTests 已锁）。若 `KLineView` 在尚未进窗口层级时首次 `draw`（trait 瞬态 `.unspecified`），夜间模式下首帧可能短暂落 light 再被 trait-change 回调纠正。这是瞬态非持久错配；**不**引入 `displayMode` 透传进 `KLineView`（会破坏 D1 单源、引入双源 override）。runbook 第 1 条留「首帧无明显闪白」观察栏。

在 `init(frame:)` 内 `backgroundColor = .clear` 之后加：

```swift
        // 顺位9：trait 的 userInterfaceStyle 变化（系统切暗/亮，或 preferredColorScheme 改 display_mode）→ 重绘。
        // 用「系统传入实例」重载 (view, previousTrait)，零 self 捕获，无 retain cycle（R1-Low7：勿改成捕获 self）。
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: KLineView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
```

`draw(_:)` 派发**不变**（不加 palette 参数，D3）。

- [ ] **Step 5：render 各 extension 把 `AppColor.X` → `currentPalette.X`**

`KLineView+Candles.swift`：
- `drawCandles`：`let color = shape.isUp ? AppColor.candleUp : AppColor.candleDown` → `... ? currentPalette.candleUp : currentPalette.candleDown`
- `drawMA66`：`AppColor.ma66.setStroke()` → `currentPalette.ma66.setStroke()`
- `drawBOLL`：`AppColor.bollLine.setStroke()` → `currentPalette.bollLine.setStroke()`

`KLineView+Volume.swift`：
- `drawVolume`：`let color = bar.isUp ? AppColor.candleUp : AppColor.candleDown` → `... ? currentPalette.candleUp : currentPalette.candleDown`

`KLineView+MACD.swift`：
- `drawMACD` 柱：`let color = bar.isPositive ? AppColor.macdBarPositive : AppColor.macdBarNegative` → `... ? currentPalette.macdBarPositive : currentPalette.macdBarNegative`
- `AppColor.macdDIF.setStroke()` → `currentPalette.macdDIF.setStroke()`
- `AppColor.macdDEA.setStroke()` → `currentPalette.macdDEA.setStroke()`

`KLineView+Markers.swift`：
- `textAttrs` 内 `.foregroundColor: AppColor.text` → `.foregroundColor: currentPalette.text`
- `case .buy: color = AppColor.candleUp` → `currentPalette.candleUp`；`case .sell: color = AppColor.candleDown` → `currentPalette.candleDown`

`KLineView+Crosshair.swift`：
- `drawCrosshair`：`AppColor.text.setStroke()` → `currentPalette.text.setStroke()`
- `drawLabelBox`（private）：`AppColor.background.setFill()` → `currentPalette.background.setFill()`；attrs `.foregroundColor: AppColor.text` → `currentPalette.text`

> 注意：`drawLabelBox` 是 `KLineView` 的 private 方法（`extension KLineView`），可直接读 `currentPalette`。所有改动均「字面 token 替换」，不动几何/控制流/签名。

- [ ] **Step 6：本地 macOS 全量 swift test（确认纯值无回归 + 不引入跨平台编译错）**

Run: `cd ios/Contracts && swift test 2>&1 | tail -8`
Expected（R1-High1：相对断言，不硬编码计数）：`Test run with N tests ... passed`，**0 failures**；N = 已核实基线（本 worktree `origin/main` 836acba 实测 **942 tests in 131 suites**）**净增** Task1 新加的 host 纯值 `@Test` 数（`AppPaletteTests` 7 + `DisplayModePrefersDarkTests` 1 = 8 → 期望 950），且**无既有套件消失**。实施时若基线漂移，以「跑前先 `swift test 2>&1 | grep 'Test run'` 取真实基线、本 PR 只增不减」为准，不认死 942。

- [ ] **Step 7：Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Theme/Theme.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Volume.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Markers.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ThemePaletteTests.swift
git commit -m "feat(顺位9): UIChartPalette scheme-aware UIKit 调色板 + KLineView trait 重渲染接线"
```

- [ ] **Step 8：Catalyst build-for-testing（UIKit 套件 + render 接线真编译验证）**

Run（本地若有 Xcode；否则依 CI 闸门）：
```bash
xcodebuild build-for-testing -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -15
```
Expected: `** TEST BUILD SUCCEEDED **`（`UIChartPalette`/`currentPalette`/`registerForTraitChanges`/`UIChartPalette: Sendable` 真编译；`UIChartPaletteTests` 套件随 build 收录）。

> **build vs run 诚实区分（R1-Low8）**：`build-for-testing` 只证**编译**通过，**不执行** `UIChartPaletteTests` 断言（与既有 `AppColorBridgeTests` 等 UIKit-gated 套件同——host swift test 跳过、build-for-testing 不 run）。若本机有 Xcode，**追加真跑**以执行 UIColor 桥保真 + `traitSelectsPalette` 断言：
> ```bash
> xcodebuild test -scheme KlineTrainerContracts \
>   -destination 'platform=macOS,variant=Mac Catalyst' \
>   -only-testing:KlineTrainerContractsTests/UIChartPaletteTests 2>&1 | tail -20
> ```
> Expected: `** TEST SUCCEEDED **`，`UIChartPaletteTests` 4 test 全 pass。若 CI/本机仅 build 不 run，则桥保真断言仅编译验证（如实记，沿用既有 pattern）。

---

## Task 3：`AppRootView` `.preferredColorScheme` 接线

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift`

- [ ] **Step 1：实现 `.preferredColorScheme` 接线**

`AppRootView.body` 的 `.task { await router.runLaunchRecovery() }` 之后追加修饰符（读 `settings.settings.displayMode`——`SettingsStore` 为 `@Observable`，body 内访问建立依赖，mode 变即重算 scheme 重渲染整窗）：

```swift
        .task { await router.runLaunchRecovery() }
        .preferredColorScheme(displayModePrefersDark(settings.settings.displayMode).map { $0 ? .dark : .light })
```

> `displayModePrefersDark` 返回 `Bool?`：`.map { $0 ? .dark : .light }` 把 true→`.dark`、false→`.light`、nil→nil（`ColorScheme?` 的 nil = 跟随系统）。`.light`/`.dark` 为 SwiftUI `ColorScheme`（已 `import SwiftUI`）。

- [ ] **Step 2：本地全量 swift test（macOS 确认无编译/逻辑回归）**

Run: `cd ios/Contracts && swift test 2>&1 | tail -6`
Expected: 全 PASS（`displayModePrefersDark` 映射由 Task1 `DisplayModePrefersDarkTests` 覆盖；本 step 仅接线，逻辑已测）。

> SwiftUI `.preferredColorScheme` 的视图层效果（三模式即时切换 + 跟随系统 + 重渲染）不在单元测试范围，由 Task 4 运行时 runbook 设备/模拟器实测验收（outline §三.3 运行时矩阵；与 C5/C8 view glue 先例一致）。映射方向正确性已由 `DisplayModePrefersDarkTests` 单测锁定，防「light/dark 接反」。

- [ ] **Step 3：Catalyst build-for-testing（AppRootView 真编译）**

Run:
```bash
xcodebuild build-for-testing -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -15
```
Expected: `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 4：Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift
git commit -m "feat(顺位9): AppRootView preferredColorScheme 据 display_mode 驱动全窗 scheme"
```

---

## Task 4：spec amendment + 运行时 runbook + acceptance 清单

**Files:**
- Modify: `kline_trainer_modules_v1.4.md`（§F2 区块）+ `kline_trainer_plan_v1.5.md`（§Phase 5 / L472 邻近）
- Create: `docs/runbooks/2026-06-14-wave3-pr9-night-mode-runtime-acceptance.md`
- Create: `docs/acceptance/2026-06-14-wave3-pr9-night-mode.md`

- [ ] **Step 1：spec amendment——amend 既有 RFC PR 块，勿新增并列块（R2-F7/F8）**

> **关键（R2-F7）**：RFC PR #79 已在 `kline_trainer_modules_v1.4.md` **L851-853**（`#### F2 Wave 3 顺位 1 RFC 契约增量…顺位 9 实现`）+ `kline_trainer_plan_v1.5.md` **L1230-1231** 写入「顺位 9 实现」前向指针块。本 PR **amend 这两块为「已落地」**，**不**新增并列契约块（避免双块重叠）。
> **RFC 机器闸门保护（R2-F7）**：`scripts/governance/verify-wave3-pr1-rfc.sh:54` 断言短语 `"light/dark 双 token 集"` 必须在 modules 在位——amend 时**保留该短语原文**（在 L853 块内），否则 RFC gate 回归 FAIL。

modules `L853`：把句末 `**具体 RGBA 归顺位 9 plan 依 WCAG AA 设备实测**` 改为 `**具体 RGBA 已落地：见 plan §D2 + `AppPalette.light`（13 token，maxChannelDiff≥0.4 代理对比，真 WCAG AA 设备实测属运行时矩阵）；render 选取 = `UIChartPalette.forScheme(themeController.resolve(trait:))`，系统切换经 `registerForTraitChanges` 重渲染，`AppRootView.preferredColorScheme` 据 display_mode 驱动全窗**`。**保留** `light/dark 双 token 集`、`per-scheme`、`themeController.resolve(trait:)`、`无 schema 改动` 等既有短语原文。L851 标题行 `顺位 9 实现` 可改为 `顺位 9 已落地（PR #<本 PR 号>）`。

plan `L1231`：把 `具体 RGBA 归顺位 9 plan 依 WCAG AA 设备实测` 改为 `具体 RGBA 已落地（plan §D2 / `AppPalette.light`）`，保留 `双 token 集` + `per-scheme 选取接线` + `无 schema 改动` 短语。

实施后**立即跑 RFC gate 确认无回归**：
```bash
bash scripts/governance/verify-wave3-pr1-rfc.sh 2>&1 | tail -5
```
Expected: gate PASS（`light/dark 双 token 集` 等短语仍命中）。

- [ ] **Step 2：运行时 runbook（outline §三.3：顺位 9 主题切换视觉）**

创建 `docs/runbooks/2026-06-14-wave3-pr9-night-mode-runtime-acceptance.md`，含设备/模拟器步骤：
1. 设置面板切「白天模式」→ 全 UI + 图表即时变白底深字、红涨绿跌仍辨；**观察首帧无明显闪白**（R1-Med3 `.unspecified` 瞬态）；
2. 切「夜间模式」→ 即时变近黑底浅字（= F2 原观感）；
3. 切「跟随系统」→ 与系统外观一致；
4. 系统控制中心切暗/亮（app 处「跟随系统」）→ app 含图表跟随重渲染（验 `registerForTraitChanges`）；
5. 重启 app → display_mode 持久化保留（验 settings 落库）；
6. 图表 light 模式下 K 线/MA66/BOLL/MACD/十字光标价签均清晰可读（验 light 集对比，真 WCAG AA 目测/取色）。
每条留 Pass/Fail + 设备型号/iOS 版本栏。
**runbook 头注（R1-Med4/Med5）**：(a) 图表画布 = clear，大面积底色随系统 colorScheme 适配；`background` token 仅染十字光标标签框。(b) SwiftUI 盈亏色 = 系统 `.red/.green`（独立于图表 token），仅验红涨绿跌**方向**，不验与图表逐字同深浅。

- [ ] **Step 3：acceptance 非-coder 中文清单**

创建 `docs/acceptance/2026-06-14-wave3-pr9-night-mode.md`（action/expected/pass-fail 表，遵守 `.claude/workflow-rules.json` 禁用措辞）。覆盖：PR 文件清单、light 集 13 token 齐全且语义保红涨绿跌、三模式 Picker 切换即时生效 + 持久化、跟随系统重渲染、图表 light 可读、frozen F2 测试仍绿、`AppColorTokens`/`AppColor` 数值未改、RFC gate `verify-wave3-pr1-rfc.sh` 仍 PASS、runbook 文件在列。**注（R2-F9）**：`UIChartPaletteTests`（4 test）为 UIKit-gated，macOS host swift test 不计入（仅 Catalyst 收录/run），验收员核 host 计数时 +0、Catalyst 计数时 +4，勿误判 host 端缺测。

- [ ] **Step 4：Commit**

```bash
git add kline_trainer_modules_v1.4.md kline_trainer_plan_v1.5.md \
        docs/runbooks/2026-06-14-wave3-pr9-night-mode-runtime-acceptance.md \
        docs/acceptance/2026-06-14-wave3-pr9-night-mode.md
git commit -m "docs(顺位9): F2 双集契约 amendment + 夜间模式运行时 runbook + acceptance 清单"
```

---

## Self-Review（plan 对 RFC §4.3 五项契约逐条核）

1. **双 token 集**（item 1）→ Task 1 `AppPalette.dark`(=AppColorTokens) + `.light`（13 字段）。✅
2. **light = dark 派生 + 红涨绿跌保 + 辅助线白底保对比**（item 2）→ Task 1 §D2 取值 + `lightHue`/`lightContrast`/`lightAlias` 测试。✅
3. **per-scheme 选取接线（render 经 `themeController.resolve(trait:)`）**（item 3）→ Task 2 `KLineView.currentPalette = UIChartPalette.forScheme(themeController.resolve(trait:))` + 各 drawXxx 改 `currentPalette.X`。✅
4. **跟随系统 + trait 变化重解析重渲染**（item 4）→ Task 2 `registerForTraitChanges`→`setNeedsDisplay` + Task 3 `.preferredColorScheme(system→nil)`。✅
5. **持久化（display_mode 落 settings，无 schema 改动）**（item 5）→ 已存在（SettingsPanel Picker + SettingsDAO `display_mode`）；本 PR 不改，acceptance 验重启保留。✅
- **acceptance（三模式即时 + 持久化跨重启 + system 跟随重渲染 + light 13 齐全保红涨绿跌）**（RFC §4.3 acceptance）→ Task 4 runbook + acceptance 清单。✅

**Placeholder 扫描**：无 TBD/TODO（HorizontalLineTool 橙为既有源注释非本 plan 占位）；每改色步给出字面 token 映射；每 test 给完整代码。✅
**类型一致性**：`AppPalette`/`UIChartPalette`/`forScheme`/`currentPalette`/`displayModePrefersDark` 跨 Task 命名统一。✅
**冻结面**：`AppColorTokens`/`AppColor` 数值与签名零改动；`AppPalette.dark` 逐字段 == `AppColorTokens`（`darkEqualsTokens` 测试锁定）。✅

## 成功判据（loop until verified）
- `swift test`（macOS host）**0 failures**，净增 `AppPaletteTests`(7)+`DisplayModePrefersDarkTests`(1) 且无既有套件消失（基线 942→期望 950；以跑前实测基线为准，不认死数字，R1-High1）；F2 冻结套件 0 回归。
- Catalyst build-for-testing `TEST BUILD SUCCEEDED`（`UIChartPalette: Sendable`/`currentPalette`/`registerForTraitChanges`/`AppRootView.preferredColorScheme` 真编译 + UIKit 套件收录）；本机有 Xcode 则追加 `xcodebuild test -only-testing:.../UIChartPaletteTests` 真跑桥保真 + `traitSelectsPalette`（R1-Low8）。
- 选取链分层有锚（R1-High2）：决策逻辑 `forScheme`+`resolveColorScheme`（host 已测）→ UIKit 桥+trait 组合 `traitSelectsPalette`（Catalyst 测）→ 端到端 preferredColorScheme 注入+像素（runbook 设备实测）。
- 运行时 runbook 6 条设备/模拟器实测留待 user device（outline §三.3 收尾阻塞依赖，非本 PR merge 门——与 C5/C8/U1-U6 runtime-runbook 同款治理模型）。

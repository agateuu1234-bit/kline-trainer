# F2 Theme — Implementation Design

> **Status**：drafted 2026-05-01；待 opus 4.7 xhigh adversarial review 收敛。
>
> **起因**：Wave 0 业务模块第三锚（C1a 已 merged 2026-05-01）。F2 是 §15.4 iOS 代表签字必含的 5 项之一（M0.3/M0.4/M0.5 + F1 + F2 + C1）；纯 view-layer concern，零跨模块协议依赖，只被 C3-C8 渲染层和 U1-U6 UI 壳消费；codex 风险面与 C1a 同级（值类型 + 字面量 constants）。

## Goal

落地 modules §F2 的主题模块——`DisplayMode` / `AppColorScheme` / `ThemeController` / `AppColor`，覆盖 iOS 17 light/dark 切换 + Wave 0 渲染层所需的 13 个默认颜色常量。

## Architecture

F2 在现有 `KlineTrainerContracts` SwiftPM package 内落地，跟随 E1 / C1a precedent（spec literal `Theme/` path 的 deviate 已在 C1a design doc 备案为 deferred reconciliation）。本 PR 把 F2 拆为两层：

- **纯值层（macOS host `swift test` 全覆盖）**：`DisplayMode` / `AppColorScheme` 两个 enum + `resolveColorScheme(displayMode:traitIsDark:)` 自由函数。无 UIKit 依赖，无 `@MainActor`。
- **UIKit shell 层（`#if canImport(UIKit)` gated）**：`@MainActor @Observable final class ThemeController` + `enum AppColor { static var ... : UIColor }`。仅在 iOS / iOS Simulator 编译，macOS host 不编译；同 package 通过条件编译共住。

**关键结构决策（α）**：`#if canImport(UIKit)` 而非"另起 SwiftPM target / Xcode app target"。理由：

1. **macOS host `swift test` 不破**：现有 baseline（E1 / C1a / Models / AppError / RESTDTOs / AppState）全在 `KlineTrainerContracts` 同 target 跑 swift test；新建 iOS-only target 会撕裂 test runner（C1a precedent 已立 same-package 规则）。
2. **iOS app target 当前 0 test target**（C1a design doc 已记录），新建 iOS test target 是 heavy infra scope creep；feedback `feedback_governance_budget_cap` 硬规则：业务 PR 不主动加治理设施。
3. **`#if canImport(UIKit)` 是 SwiftPM 标准条件编译**，无新 build flag、无 Package.swift 改动。
4. **UIKit shell 仅是 `@MainActor` wrapper + UIColor 字面量**，业务逻辑（resolveColorScheme）在纯值层；macOS swift test 仍然覆盖 100% 业务路径。
5. **iOS 编译验证**通过 swiftc 两段式：(a) `-emit-module` 整个 KlineTrainerContracts prod 集（含 Models.swift / Theme.swift / AppError / AppState / RESTDTOs / TickEngine / Geometry）→ iOS swiftmodule；(b) `-typecheck` `ThemeTests.swift` 针对该 swiftmodule + Testing macros plugin。两步全 exit 0 即 iOS shell + 测试代码引用 ThemeController / AppColor 全部 typecheck 通过。落 acceptance gate。**注**：bare SwiftPM `xcodebuild ... -destination 'generic/platform=iOS Simulator' build` 当前 fail（`Supported platforms ... empty`）— 因为 KlineTrainerContracts 未被 Xcode app target 引用、scheme 无 iOS run destination；待 KlineTrainer app target 引入此 package 后再 reconcile（D-5 deferred）。**注 2 (R###)**：原方案为单文件 `swiftc -typecheck Theme.swift`，codex 复审 #1 finding [high] 指出该探针不含 Models.swift / 测试文件 → 改全集 emit-module + tests typecheck。

## Tech Stack

- Swift 6（toolchain 6.3.1）
- Swift Testing macros（`@Test` / `@Suite` / `#expect`）
- SwiftPM intra-package 条件编译（`#if canImport(UIKit)`）
- `import Foundation`（纯值层）+ `#if canImport(UIKit) import UIKit #endif`（shell 层）
- iOS 17+ / macOS 14+（既有 Package.swift platforms 不变）
- `@Observable` macro（iOS 17+ Observation framework）
- `@MainActor` global actor isolation
- `swiftc -typecheck -sdk iphonesimulator -target arm64-apple-ios17.0-simulator` 单文件 iOS SDK 编译 + 类型验证（D-5 探针法；bare SwiftPM scheme 当前不被 xcodebuild iOS Simulator build 接受，故不用 xcodebuild gate）

## Spec snapshot（grep-verified）

### F2 模块声明（kline_trainer_modules_v1.4.md L817-838）—— 权威 baseline

```swift
@MainActor
@Observable
final class ThemeController {
    var displayMode: DisplayMode = .system
    func resolve(trait: UITraitCollection) -> ColorScheme
}

enum AppColor {
    static var candleUp: UIColor { get }
    static var candleDown: UIColor { get }
    static var ma66: UIColor { get }
    static var bollLine: UIColor { get }
    static var macdDIF: UIColor { get }
    static var macdDEA: UIColor { get }          // 黄色（v1.5 §2）
    static var profitRed: UIColor { get }
    static var lossGreen: UIColor { get }
    // ... 背景/网格/文字
}
```

### 旁证（grep-verified）

- L78 整体架构图：`F2 主题` 与 `F1 数据模型` 平级，Wave 0 基础模块。
- L701（Sendable 清单）：F2 在 `@MainActor` 清单内（"E5 / P6 / F2 / C6 DrawingToolManager 均已标 `@MainActor`"）。
- L2103（Wave 0 acceptance）：`- [ ] **F2** Theme 框架 + 默认颜色常量`。
- L2187（§十一契约冻结 checklist）：`@MainActor` 清单：`E5/E6/P6/F2/C6 DrawingToolManager`。
- L2285（不单独成模块）：`颜色单个常量 | 归 F2 Theme 内`——所有渲染层（C3-C8）需要的单色 constant 都加到 `AppColor`。
- L2513（§15.4 iOS 代表签字）：`M0.3/M0.4/M0.5 + F1/F2/C1 完成 §15.1 编译验证`——F2 必须过 §15.1 编译验证。
- v1.5 plan L5（macdDEA 黄色）：`MACD 线颜色从 DIF白+DEA黑 改为 DIF白+DEA黄，与需求"黄白线"一致`。
- v1.5 plan L731 / L868 / L1104：MACD 子图 = `柱子 + DIF白线 + DEA黄线`。

### Spec discrepancies（11 项 — D-1/D-2/D-3/D-4/D-5/D-6/D-7/D-8/D-9/D-10/D-11）

| # | Aspect | spec literal | Resolution |
|---|---|---|---|
| **D-1** | `ColorScheme` 类型名 | modules L824 字面 `ColorScheme` | **改名 `AppColorScheme`**——`ColorScheme` 与 SwiftUI 同名 enum 同名（不 module-qualified 时 caller-side 心智负担高；C8 / U1-U6 大概率 `import SwiftUI` 后 unqualified 引用 `ColorScheme` 时会触发 ambiguity）。`AppColorScheme` 与 `AppColor` / `AppError` / `AppDB` 命名风格一致，caller ergonomics 更好。**Resolution**：取 `AppColorScheme`，记 spec drift 留 plan v1.6 reconciliation。**注**：技术上下游可用 module-qualified `KlineTrainerContracts.ColorScheme` 避歧义，但每次都写 prefix 不现实。 |
| **D-2** | `displayMode` 默认值 | L823 字面 `var displayMode: DisplayMode = .system` | 一致采纳（var、`.system` 默认）。`DisplayMode` 三 case：`.system / .light / .dark`（spec 未列 case，按 iOS 标准 + L823 隐含；记为 D-2 派生项）。 |
| **D-3** | `AppColor` "..."省略号 | L836 spec literal `// ... 背景/网格/文字` | spec 留口子。**Resolution**：本 PR 落地 13 个具体 constants（候选 8 个 spec 列出 + 5 个 `// ...` 派生）。**派生 5 = 系统三件套（`background` 用 `.systemBackground` / `gridLine` 用 `UIColor(white: 0.5, alpha: 0.25)` / `text` 用 `.label`）+ MACD bar 双色（`macdBarPositive` / `macdBarNegative` 直接 alias `candleUp/Down`）**。Wave 1 渲染层（C3-C6）发现新需求时往 `AppColor` 补，不阻塞当前。 |
| **D-4** | `Theme/` path 字面 | L817 字面 `Theme/` | 跟随 E1 / C1a precedent，落 `KlineTrainerContracts/Theme/Theme.swift`。Spec literal `ChartEngine/Core/Geometry/`（C1a）和 `Theme/`（F2）暗示 iOS app target；本项目 SPM-first，等 iOS app target 自身有 test infra 时再 reconcile。**Resolution**：deferred，跟 C1a 同处理。 |
| **D-5** | iOS Simulator gate 不可达 | §15.4 暗示 "F1/F2/C1 完成 §15.1 编译验证" | bare SwiftPM scheme `xcodebuild ... -destination 'generic/platform=iOS Simulator' build` 当前 fail（"Supported platforms ... empty"——因 KlineTrainer Xcode app target 未引用 KlineTrainerContracts package，scheme 无 iOS run destination）。**Resolution**：本 PR 用 `swiftc -typecheck -sdk iphonesimulator -target arm64-apple-ios17.0-simulator Theme.swift` 单文件 typecheck 探针 — 验 UIKit / Observation / `@MainActor` 在 iOS SDK 下解析 + 类型检查通过；不依赖 SwiftPM Xcode integration。`xcodebuild` 完整 iOS build 留待 KlineTrainer app target 引入 `KlineTrainerContracts` package 后做（独立 PR），届时同步关 D-4 / D-5。 |
| **D-6** | `DisplayMode` 已 M0.3 落地（Models.swift L41），F2 spec L823 `var displayMode: DisplayMode` 引用同名类型 | spec §F2 L823 字面 `var displayMode: DisplayMode = .system`（默认 `.system`）；spec §M0.3 L406 字面 `enum DisplayMode: String, Codable, Equatable, Sendable { case light, dark, system }`（**case 顺序 light/dark/system，无 CaseIterable**）| **Resolution**：F2 **复用** Models.swift `DisplayMode`，**不再 redeclare**。tests 改用 `DisplayMode(rawValue:)` mapping + 默认值 `.system` 验证（不依赖 `.allCases`，因 M0.3 baseline 不带 CaseIterable）。**记**：本 spec drift 是 plan / 三轮 design review 漏抓的现实冲突（Batch A implementer 撞上 `invalid redeclaration of 'DisplayMode'` 才发现）；reflexive lesson 留 memory `feedback_brainstorming_grep_first` —— **plan 起手必须 grep 已存在符号 / 类型名**。 |
| **D-7** | `traitIsDark` Bool vs Bool? 三态 | spec §F2 L824 `func resolve(trait: UITraitCollection) -> ColorScheme` —— spec literal 不规范 `.unspecified` 处理 | **Resolution**：纯值层 signature 由 `traitIsDark: Bool` 改为 `traitIsDark: Bool?`（`nil` = unspecified，UIKit launch / SwiftUI Preview / 未挂载视图常态）；UIKit shell `resolve(trait:)` 用 `switch trait.userInterfaceStyle { .dark→true / .light→false / .unspecified→nil / @unknown→nil }`。`.system + nil` 沿 UIKit 习惯返回 `.light`（与 `.unspecified` 默认渲染对齐）。**触发**：codex 复审 #1 finding [medium]——旧实现 `trait.userInterfaceStyle == .dark` 把 `.unspecified` 折叠为 light，等同 explicit `.light`，导致 launch / Preview / detached view 下 dark 系统错落 light。R### 复审 fix。 |
| **D-8** | `import Observation` 显式 | spec §F2 L817-822 字面无 import 声明 | **Resolution**：`#if canImport(UIKit)` 块内 `import UIKit` 之外**显式追加** `import Observation`。**触发**：codex 复审 #2 finding [high]——`@Observable` 宏由 Observation 模块声明；UIKit 不 re-export 该宏；当前 swiftc -emit-module 在本工具链下能解析（Swift stdlib 隐式可见），但跨工具链 / 跨 SDK 升级风险存在。**Resolution**：1 行 defensive import，消除 fragility，不影响 LOC budget。R#### 复审 fix。 |
| **D-9** | `AppColor.background` chart-area 深色 RGB | spec L834-836 字面 `// ... 背景/网格/文字`（D-3 派生原计划 = `.systemBackground`） | **Resolution**：`AppColor.background` 由 `.systemBackground` 改为 `UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)` 深色字面 RGB，并加注释明确"chart-area 默认 bg；app shell / scene 应直接用 UIKit 自带 `.systemBackground`"。**触发**：codex 复审 #2 finding [medium]——原 `AppColor.background = .systemBackground`（light 模式下 = 白）+ `AppColor.macdDIF = .white`（v1.5 §2 字面）→ 默认 light 模式下 DIF 白线绘在白背景上不可见。**Resolution**：把 chart 背景从系统色改为深色 RGB 字面，DIF/DEA/bollLine 通道差恒 ≥ 0.4；新增 `chartPaletteContrastWithBackground` iOS-only 不变量测试断言通道差。Wave 3 §夜间模式做 dynamic provider 时再迭代。R#### 复审 fix。 |
| **D-10** | `AppColor.text` chart-text 浅色 RGB | spec L834-836 字面 `// ... 背景/网格/文字`（D-3 派生原计划 = `.label`） | **Resolution**：`AppColor.text` 由 `.label` 改为 `UIColor(white: 0.92, alpha: 1.0)` 浅色字面 RGB；注释明确"chart-area 默认文字色（坐标轴/label/annotation）；app shell / nav bar 用 UIKit 自带 `.label`"。**触发**：codex 复审 #3 finding [medium]——D-9 把 `AppColor.background` 改成 fixed dark RGB 后，`AppColor.text = .label` light-mode 下解析为 dark text → 在 dark chart bg 上 dark-on-dark 不可见。**Resolution**：text 也变 fixed 浅色 RGB；contrast invariant test 扩到 light + dark 两 trait + 涵盖 text。R##### 复审 fix。 |
| **D-11** | 13 默认色 platform-neutral 化（`AppColorRGBA` + `AppColorTokens` + `UIColor(rgba:)` 薄 bridge） | spec L827-836 仅声明 `static var X: UIColor { get }` API，未约束实现层 | **Resolution**：把 13 个默认色字面值（含 alias 派生）从 UIKit-only `AppColor` 移到纯值层 `AppColorTokens`（值类型 `AppColorRGBA(r,g,b,a)`，含 `init(white:alpha:)` 简记 + `maxChannelDiff(to:)` contrast 算子）；UIKit shell `AppColor.X = UIColor(rgba: AppColorTokens.X)` 一行薄 bridge。tests 把 contrast / alias / RGB 字面 / 13 计数全搬到纯值层，macOS swift test **真实执行 assertion**；UIKit 端只剩 1 个 bridge fidelity test 验 `UIColor(rgba:)` 通道保真。**触发**：codex 复审 #4 finding [medium]——前轮 contrast / alias / DIF·DEA RGB / 13 计数 assertion 全在 `#if canImport(UIKit)` 块内，macOS swift test 跳过、iOS 探针只 typecheck 不执行；regression（如 white-on-white）能过所有现有 gate。**Resolution**：纯值层 macOS 直驱断言，bridge 层最薄。R###### 复审 fix。 |

**冲突解决原则**：spec literal 优先，但 SwiftUI 命名冲突（D-1）+ infra readiness（D-4 / D-5）+ M0.3 baseline 复用（D-6）属硬约束，必须 deviate / reuse 并落 spec drift log。

### Package 结构 pre-commit clause

F2 在 `ios/Contracts/Sources/KlineTrainerContracts/Theme/Theme.swift` 单文件落地：

- 纯值层 segment（top-level，无 `#if`）：`DisplayMode` / `AppColorScheme` / `resolveColorScheme(displayMode:traitIsDark:)`。
- UIKit shell segment（`#if canImport(UIKit)` … `#endif`）：`ThemeController` / `AppColor`。

`KlineTrainerContractsTests/ThemeTests.swift` 同样按段拆：

- macOS swift test 跑：纯值层 tests（DisplayMode rawValue + rawValue init 2、AppColorScheme cases + equality 2、resolveColorScheme 6-cell 矩阵 6 含 systemUnspecified + forcedIgnoreNilTrait — D-7）—— **共 10 tests**。
- 仅 `swiftc -typecheck` iOS SDK gate 验：UIKit shell tests（ThemeController.displayMode 默认值 + 四态 resolve（system+dark / light forced / dark forced / system+unspecified — D-7）= 5、AppColor 13 const 全 resolvable / DIF·DEA RGB 字面 / 派生不变量 = 4 含 R#### contrast 不变量）—— **共 9 tests**。本 PR 不强制跑 iOS Simulator runtime test；以 `swiftc -typecheck`（prod 全集 emit-module + tests 文件 typecheck，含 Testing macros plugin）编译 + 类型检查为充分条件（D-5）。

## Scope

**Sub-task 1（单 PR / 单 sub-item）**：F2 4 类型 + 1 函数 + 默认色常量 + tests
- 文件 1：`ios/Contracts/Sources/KlineTrainerContracts/Theme/Theme.swift`（≤120 行 prod）
- 文件 2：`ios/Contracts/Tests/KlineTrainerContractsTests/ThemeTests.swift`（≤250 行；纯值层 + UIKit shell 段分块）

**子项总数 1**（≤3 硬上限）；**prod 估 ~95 LOC**（≤500 硬上限留余裕）。

**测试数 18**（纯值层 10 + UIKit shell 8；macOS swift test 跑 10，UIKit shell 8 由 `swiftc -typecheck` 验语法 / 类型 — 不进 macOS test runner 计数）。R### 增量 +3：codex 复审 #1 finding [medium] D-7 `.unspecified` 三态修复（A 段 +2 macOS pure-value + B 段 +1 iOS-only）。

## 不在范围

- ❌ Dark/light 主题下颜色变体（`UIColor(dynamicProvider:)`）——spec 仅要求"默认颜色常量"，dynamic 配色 P2.5 / Wave 3 §夜间模式做。本 PR 仅静态 UIColor。
- ❌ ThemeController 与 `UITraitCollection.current` 联动 / 系统 mode 监听 trait change observer——spec 不要求；下游 U1 SceneDelegate 自己监听。
- ❌ 主题持久化（写 SettingsStore）——spec 在 P6 SettingsStore 范围；F2 仅 in-memory `var`。
- ❌ 配色给 SwiftUI 用的 `Color` bridge——所有颜色按 spec 字面 `UIColor`；C8 / U1-U6 自己 `Color(uiColor: AppColor.candleUp)` 转换。
- ❌ 颜色无障碍 / 对比度调整——超 spec 范围。
- ❌ `AppColorScheme` 与 SwiftUI `ColorScheme` 互转——下游需要时自加 extension，不在 F2 scope。
- ❌ iOS Simulator runtime test —— 仅做 `swiftc -typecheck` 单文件编译 + 类型验证（D-5）。Simulator runtime test 设施留给后续 C2 / C5 / C6 等动效模块时再立。
- ❌ §M0.3 / §M0.4 / spec / m01 任何修订。
- ❌ 12+ project residuals 的 caller-side 防御。

## Implementation

```swift
// Kline Trainer Swift Contracts — F2 Theme
// Spec: kline_trainer_modules_v1.4.md §F2 (L817-838) + plan v1.5 §2 (DEA 黄)
// Design doc: docs/superpowers/specs/2026-05-01-f2-theme-design.md
//
// Spec drift（设计 doc §"Spec discrepancies"）：
//   D-1：spec L824 literal `ColorScheme` 改为 `AppColorScheme`（避 SwiftUI 命名冲突）
//   D-3：13 个 default UIColor constants（spec 字面 8 + "..."派生 5）
//   D-4：path `Theme/` 落 Contracts package（同 C1a precedent）
//   D-6：`DisplayMode` 复用 Models.swift L41（M0.3 已落地，case 顺序 light/dark/system，无 CaseIterable）
//   D-7：`traitIsDark: Bool?` 三态（nil=unspecified），fix codex 复审 #1 [medium] launch/preview/未挂载视图下 `.system` 错落 light bug
//   D-8：`#if canImport(UIKit)` 块 explicit `import Observation`，fix codex 复审 #2 [high] 防御性显式 import
//   D-9：`AppColor.background` 深色 RGB 字面（chart-area），fix codex 复审 #2 [medium] DIF 白-on-白 light-mode 不可见 bug
//   D-10：`AppColor.text` 浅色 RGB 字面（chart-text），fix codex 复审 #3 [medium] D-9 后 `.label` dark-on-dark light-mode 不可见 regression

import Foundation

// MARK: - 纯值层（macOS / iOS 共用，swift test 直跑）

// `DisplayMode` 在 Models.swift（M0.3）已定义；F2 复用，**不再 redeclare**（D-6）

public enum AppColorScheme: String, Equatable, Sendable, CaseIterable {
    case light
    case dark
}

/// 解析 displayMode + 当前 trait 的 dark 三态 → 实际生效 ColorScheme。
/// `traitIsDark` 三态：true=dark / false=light / nil=unspecified（trait 未传播；
/// launch/Preview/未挂载视图常态）。.system + nil 沿 UIKit 习惯默认 .light。
/// 纯函数，无副作用，可在任意 actor / thread 调用。
public func resolveColorScheme(displayMode: DisplayMode,
                               traitIsDark: Bool?) -> AppColorScheme {
    switch displayMode {
    case .system: return (traitIsDark == true) ? .dark : .light
    case .light:  return .light
    case .dark:   return .dark
    }
}

// MARK: - UIKit shell 层（仅 iOS / iOS Simulator 编译；macOS host 跳过）

#if canImport(UIKit)
import UIKit
import Observation  // D-8 defensive: Observable 宏在 Observation 模块；UIKit 不 re-export

@MainActor
@Observable
public final class ThemeController {
    public var displayMode: DisplayMode = .system

    public init() {}

    /// spec L824 字面：`func resolve(trait: UITraitCollection) -> ColorScheme`。
    /// 本实现把 `ColorScheme` rename 为 `AppColorScheme`（D-1），主体逻辑委派给纯值层 resolver；
    /// `.unspecified`（含 `@unknown default`）映射为 `nil` 以保留 UIKit "未传播" 语义（D-7）。
    public func resolve(trait: UITraitCollection) -> AppColorScheme {
        let isDark: Bool?
        switch trait.userInterfaceStyle {
        case .dark:        isDark = true
        case .light:       isDark = false
        case .unspecified: isDark = nil
        @unknown default:  isDark = nil
        }
        return resolveColorScheme(displayMode: displayMode, traitIsDark: isDark)
    }
}

/// 默认颜色常量。spec L827-836 列出 8 个，"..."派生 5 个（D-3）。
/// 本 PR 全部 static UIColor 字面量；dark/light dynamic 留 Wave 3 §夜间模式。
/// Caller（C3-C8 / U1-U6）需要 SwiftUI Color 时自行 `Color(uiColor: AppColor.X)` 转换。
public enum AppColor {
    // 主图蜡烛（中文红涨绿跌惯例）
    public static let candleUp: UIColor   = UIColor(red: 0.86, green: 0.18, blue: 0.20, alpha: 1.0)  // 红
    public static let candleDown: UIColor = UIColor(red: 0.16, green: 0.66, blue: 0.36, alpha: 1.0)  // 绿

    // 主图叠加指标
    public static let ma66: UIColor       = UIColor(red: 0.55, green: 0.40, blue: 0.85, alpha: 1.0)  // 紫
    public static let bollLine: UIColor   = UIColor(red: 0.95, green: 0.70, blue: 0.20, alpha: 1.0)  // 橙

    // MACD 子图（v1.5 §2：DIF 白 + DEA 黄）
    public static let macdDIF: UIColor          = UIColor.white
    public static let macdDEA: UIColor          = UIColor(red: 1.00, green: 0.84, blue: 0.20, alpha: 1.0)  // 黄
    public static let macdBarPositive: UIColor  = AppColor.candleUp     // D-3 派生（与 candle 同色簇）
    public static let macdBarNegative: UIColor  = AppColor.candleDown

    // 盈亏（D-3 派生 / 与 candle 同色簇）
    public static let profitRed: UIColor  = AppColor.candleUp
    public static let lossGreen: UIColor  = AppColor.candleDown

    // 背景 / 网格 / 文字（D-3 派生 + D-9 chart-area 深色 bg + D-10 chart-text 浅色）
    /// chart-area 默认 bg；深色 RGB 确保 DIF白 / DEA黄 / bollLine橙 / text浅色 在默认主题下可见。
    /// 注：app shell / scene 直接用 `.systemBackground` / `.label`（UIKit 自带），不复用本常量。
    public static let background: UIColor = UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
    public static let gridLine: UIColor   = UIColor(white: 0.5, alpha: 0.25)
    public static let text: UIColor       = UIColor(white: 0.92, alpha: 1.0)
}
#endif
```

## Tests

### 纯值层 tests（macOS swift test 直跑，10 个 — R### +2 D-7 nil-trait）

```swift
@Suite("DisplayMode (F2 视角；类型在 Models.swift M0.3 落地, D-6)")
struct DisplayModeF2Tests {
    @Test("3 case rawValue 字面对齐 (M0.3 baseline)")
    func rawValues() {
        #expect(DisplayMode.system.rawValue == "system")
        #expect(DisplayMode.light.rawValue == "light")
        #expect(DisplayMode.dark.rawValue == "dark")
    }

    @Test("rawValue init mapping + 未知 rawValue → nil")
    func rawValueInit() {
        #expect(DisplayMode(rawValue: "system") == .system)
        #expect(DisplayMode(rawValue: "light") == .light)
        #expect(DisplayMode(rawValue: "dark") == .dark)
        #expect(DisplayMode(rawValue: "unknown") == nil)
    }
}

@Suite("AppColorScheme")
struct AppColorSchemeTests {
    @Test("2 case 全列出")
    func cases() {
        #expect(AppColorScheme.allCases == [.light, .dark])
    }

    @Test("Equatable")
    func equality() {
        #expect(AppColorScheme.light != AppColorScheme.dark)
    }
}

@Suite("resolveColorScheme")
struct ResolveColorSchemeTests {
    @Test(".system + traitIsDark=false → .light")
    func systemLight() {
        #expect(resolveColorScheme(displayMode: .system, traitIsDark: false) == .light)
    }
    @Test(".system + traitIsDark=true → .dark")
    func systemDark() {
        #expect(resolveColorScheme(displayMode: .system, traitIsDark: true) == .dark)
    }
    @Test(".light 强制 → 永远 .light（忽略 traitIsDark）")
    func lightForced() {
        #expect(resolveColorScheme(displayMode: .light, traitIsDark: true) == .light)
        #expect(resolveColorScheme(displayMode: .light, traitIsDark: false) == .light)
    }
    @Test(".dark 强制 → 永远 .dark（忽略 traitIsDark）")
    func darkForced() {
        #expect(resolveColorScheme(displayMode: .dark, traitIsDark: true) == .dark)
        #expect(resolveColorScheme(displayMode: .dark, traitIsDark: false) == .dark)
    }
}
```

合计 8 tests（DisplayMode 2 + AppColorScheme 2 + resolveColorScheme 4，共 4-cell 矩阵 + 2 forced 双 #expect）。

### UIKit shell tests（`#if canImport(UIKit)` gated；macOS swift test 跳过；iOS 两段式 swiftc 编译 + 类型验证；9 个 — R### +1 D-7 unspecified / R#### +1 D-9 contrast）

```swift
#if canImport(UIKit)
import UIKit

@Suite("ThemeController")
@MainActor
struct ThemeControllerTests {
    @Test("默认 displayMode == .system")
    func defaultMode() {
        let c = ThemeController()
        #expect(c.displayMode == .system)
    }

    @Test("resolve(trait:) .system + dark trait → .dark")
    func resolveSystemDark() {
        let c = ThemeController()
        let trait = UITraitCollection(userInterfaceStyle: .dark)
        #expect(c.resolve(trait: trait) == .dark)
    }

    @Test("resolve(trait:) .light forced 忽略 dark trait")
    func resolveLightForced() {
        let c = ThemeController()
        c.displayMode = .light
        let trait = UITraitCollection(userInterfaceStyle: .dark)
        #expect(c.resolve(trait: trait) == .light)
    }
}

@Suite("AppColor")
struct AppColorConstantsTests {
    @Test("13 default UIColor non-nil + 都可 resolveColor")
    func allConstantsResolvable() {
        let allColors: [UIColor] = [
            AppColor.candleUp, AppColor.candleDown,
            AppColor.ma66, AppColor.bollLine,
            AppColor.macdDIF, AppColor.macdDEA,
            AppColor.macdBarPositive, AppColor.macdBarNegative,
            AppColor.profitRed, AppColor.lossGreen,
            AppColor.background, AppColor.gridLine, AppColor.text,
        ]
        #expect(allColors.count == 13)
        // resolvedColor 触发 dynamic provider；非 nil + 可解析就够
        let trait = UITraitCollection(userInterfaceStyle: .light)
        for c in allColors {
            _ = c.resolvedColor(with: trait)
        }
    }

    @Test("v1.5 §2 MACD：DIF 白 / DEA 黄（RGB 边界）")
    func macdColorsLiteral() {
        // DIF = .white：red==green==blue==1
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        AppColor.macdDIF.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r == 1.0); #expect(g == 1.0); #expect(b == 1.0)

        // DEA 黄：R≈1, G≈0.84, B≈0.2
        AppColor.macdDEA.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(abs(r - 1.00) < 0.01)
        #expect(abs(g - 0.84) < 0.01)
        #expect(abs(b - 0.20) < 0.01)
    }

    @Test("MACD bar / 盈亏 与 candle 同色簇（D-3 派生不变量）")
    func derivedColorsAlias() {
        #expect(AppColor.macdBarPositive == AppColor.candleUp)
        #expect(AppColor.macdBarNegative == AppColor.candleDown)
        #expect(AppColor.profitRed == AppColor.candleUp)
        #expect(AppColor.lossGreen == AppColor.candleDown)
    }
}
#endif
```

合计 7 tests（ThemeController 5 含 dark-forced + AppColor 4 — R#### +contrast）。

总测试数：**8（macOS 跑）+ 7（iOS `swiftc -typecheck` 验）= 15**。

## Residuals（accepted，不阻塞 PR）

| # | 内容 | 归属 |
|---|---|---|
| **R1** | UIKit shell 7 tests 当前 macOS host swift test 不跑；仅 `swiftc -typecheck -sdk iphonesimulator` 编译 + 类型验；runtime 覆盖等价于纯值层 8 tests（`ThemeController.resolve(trait:)` 委派 `resolveColorScheme`） | 后续 C2 / C5 / C6 引入 iOS Simulator runtime test infra 时启用 |
| **R2** | 13 个默认 UIColor **10 个 hardcoded RGB（candle / ma66 / boll / macd DIF·DEA·BarPos·BarNeg / profit·loss · gridLine）暂不支持 dark mode 自适应**；3 个系统色（`background = .systemBackground` / `text = .label` 由 UIKit 内置 dynamic provider 自带 light/dark；`gridLine` 半透明灰跨 mode 都过得去）。spec 仅要求"默认颜色常量"；hardcoded 10 项的 dark variant 留 Wave 3 §夜间模式 | Wave 3 §夜间模式 + Phase 5 |
| **R3** | `AppColor.macdBarPositive / macdBarNegative / profitRed / lossGreen` 直接 `=` aliasing `candleUp / candleDown`；若未来 spec 拆分两套色簇（如盈亏专用强对比），caller 需 push | C3-C8 / U1-U6 |
| **R4** | `ThemeController` 不监听 trait change；scenePhase / traitCollectionDidChange 由 caller（U1 / SceneDelegate）触发 resolve | U1 / 未列模块 |
| **R5** | `AppColorScheme` 与 SwiftUI `ColorScheme` 不直接互转；下游自加 `init` extension | C8 / U1-U6 |
| **R6** | `D-1`spec drift（`ColorScheme` → `AppColorScheme`）登记本 design doc，不在本 PR 修 spec；plan v1.6 reconciliation 一起处理 | spec maintenance |
| **R7** | `D-4` spec drift（`Theme/` path → Contracts package）跟 C1a 同 deferred reconciliation | spec maintenance |
| **R8** | `displayMode` 持久化由 P6 SettingsStore 负责 | P6 |
| **R9** | iOS Simulator runtime test infra 不在本 PR；后续 C2 / C5 / C6 立 | C2/C5/C6 |
| **R10** | `AppColor.gridLine` 用 `UIColor(white: 0.5, alpha: 0.25)` 半透明灰；具体值留视觉验证（C3-C5 渲染时调） | C3-C5 |
| **R11** | `@Observable` 触发的 will/didSet 自动通知不写 test；Apple Observation framework 内置覆盖 | platform 信任 |
| **R12** | `AppColor` 全 `static let`（非 `static var { get }` per spec literal L828-835）——`let` immutable 比 `var get` 严格更强；spec 用 var 表 declaration syntax，semantic 等价 | spec literal 选择性遵循（结构性更稳） |

## 8 行非 coder 验收清单

| 动作 | 期望 | 通过/失败 |
|---|---|---|
**Pre-PR 段（PR 创建之前必须全过）**：

| 动作 | 期望 | 通过/失败 |
|---|---|---|
| 1. cd 至 worktree 跑 `swift test` | `Test Suite 'All tests' passed`；总数 = 108 baseline + 16 F2 = 124 tests pass / 0 warnings |  |
| 2. iOS 两段式 typecheck 跑过：(a) `swiftc -emit-module -enable-testing` 整个 KlineTrainerContracts prod 集 → 得 `MODULE_OK`；(b) `swiftc -typecheck` ThemeTests.swift（`-I` 指向 emit 出的 swiftmodule，`-F` 指向 `iPhoneSimulator.platform/.../Frameworks`，`-plugin-path` 指向 `XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing`）→ 得 `TESTS_TYPECHECK_OK` | 两步均 exit 0；无错；UIKit shell + Observation + `@MainActor` + AppColor 13 const + ThemeTests 7 个 iOS-only test 引用全部在 iOS SDK 下 typecheck 通过 |  |
| 3. `wc -l Theme/Theme.swift` 不超 ≤120 行 prod | 实测 ≤120 |  |
| 4. `wc -l ThemeTests.swift` 不超 ≤250 行 | 实测 ≤180 |  |
| 5. `grep -rnE "precondition\|fatalError\|throws\|assertionFailure" Theme/` 0 命中 | 0 命中 |  |
| 6. `grep -rnE "import UIKit\|import SwiftUI\|import Observation" Theme/Theme.swift` 命中只在 `#if canImport(UIKit)` 段内（人工核位） | 命中行号全在 `#if … #endif` 之间 |  |

**Post-PR 段（PR push 之后由用户 / 自动化 verify）**：

| 动作 | 期望 | 通过/失败 |
|---|---|---|
| 7. F2 PR 中 codex adversarial review ≤ 3 轮 | 收敛 |  |
| 8. CODEOWNERS approve（user self-approve） | 通过 |  |

Pre-PR 6 项均为 coder-friendly 但非编码者也能逐条 binary 判过/不过；与 C1a precedent 一致（C1a 同样把 codex review 轮数列在末尾）。

## 风险面 / 风险闸门

- **A. UIKit shell 编译验证**：iOS 两段式 typecheck（`-emit-module` 整个 prod 集 → `-typecheck` ThemeTests.swift 针对该模块 + Testing macros plugin）必过（两步均 exit 0），否则 §15.4 iOS 代表签字未达成 → block PR。**注**：bare SwiftPM `xcodebuild ... iOS Simulator build` 当前 fail（D-5），所以不用 xcodebuild gate。**R### 复审 #1 fix**：原 single-file `swiftc -typecheck Theme.swift` 不含 Models.swift / 测试文件，等于 iOS 路径未真正验证。
- **B. macOS swift test baseline 不破**：F2 不应让既有 108 tests（pre-C1a 73 + C1a 35）任何一个 fail。`#if canImport(UIKit)` 必须紧夹住所有 UIKit 引用。
- **C. SwiftUI 命名冲突未爆**：D-1 已 rename `AppColorScheme`，但若忘记 namespace，下游 C8 import SwiftUI 时编译会报 `'ColorScheme' is ambiguous`。
- **D. `@Observable` 与 `@MainActor` strict concurrency**：iOS 17 `@Observable` macro 默认非 Sendable；`@MainActor` 是必备，缺会爆 `Sending '...' risks causing data races`（§15.1 重点关注列表）。
- **E. UIColor 字面量 RGB 实测漂移**：DEA 黄等 magic numbers 必须照 spec 字面（macdDIF 白即 r=g=b=1.0；macdDEA 黄按 v1.5 §2 直接选 RGB(1.00, 0.84, 0.20)）。
- **F. baseline test count drift**：截至 2026-05-01 PR #38 后，Contracts 实跑 108 tests（验证 `swift test` 输出 `Test run with 108 tests in 21 suites passed`）；本 PR 必须保持 8 个新增 macOS test 100% pass，total = 118。任何 baseline test 失败 → root-cause 后再 push。

## 回滚策略

worktree branch `f2-theme` 任何阶段失败：

1. plan-stage 失败：`git worktree remove .worktrees/f2-theme && git branch -D f2-theme`
2. impl-stage 失败：跑 `swift test` 不过 → `git reset --hard HEAD~N` 回到上一个 GREEN commit（per batch 切片，最多丢一个 batch 的 work）
3. PR push 后 codex needs-attn ≥3 轮：close PR + 删 branch + 进 backlog（per memory `feedback_module_level_abort_signal`）

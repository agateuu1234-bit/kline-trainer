// Kline Trainer Swift Contracts — F2 Theme
// Spec: kline_trainer_modules_v1.4.md §F2 (L817-838) + plan v1.5 §2 (DEA 黄)
// Design doc: docs/superpowers/specs/2026-05-01-f2-theme-design.md
//
// Spec drift（design doc §"Spec discrepancies"）：
//   D-1：spec L824 literal `ColorScheme` 改为 `AppColorScheme`（避 SwiftUI 命名冲突）
//   D-3：13 个 default UIColor constants（spec 字面 8 + "..."派生 5）
//   D-4：path `Theme/` 落 Contracts package（同 C1a precedent）
//   D-6：`DisplayMode` 复用 Models.swift L41（M0.3 已落地，case 顺序 light/dark/system，无 CaseIterable）
//   D-7：`traitIsDark: Bool?` 三态（nil=unspecified），fix codex 复审 #1 [medium] launch/preview/未挂载视图下 `.system` 错落 light bug
//   D-8：`#if canImport(UIKit)` 块 explicit `import Observation`（@Observable 宏在 Observation 模块；UIKit 不 re-export — codex 复审 #2 [high] 防御性显式 import）
//   D-9：`AppColor.background` 由 `.systemBackground` 改为深色 RGB 字面（chart-area 默认 bg），fix codex 复审 #2 [medium] DIF 白-on-systemBackground 白 light-mode 不可见 bug

// MARK: - 纯值层（macOS / iOS 共用，swift test 直跑）

// `DisplayMode` 在 Models.swift（M0.3）已定义；F2 复用，**不再 redeclare**（D-6）

public enum AppColorScheme: String, Equatable, Sendable, CaseIterable {
    case light
    case dark
}

/// 解析 displayMode + 当前 trait 的 dark 三态 → 实际生效 ColorScheme。
/// `traitIsDark` 三态：true=dark / false=light / nil=unspecified（trait 未传播，
/// 例如 launch / Preview / 未挂载视图）。.system + nil 沿 UIKit 习惯默认 .light。
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
import Observation

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
    public static let candleUp: UIColor   = UIColor(red: 0.86, green: 0.18, blue: 0.20, alpha: 1.0)
    public static let candleDown: UIColor = UIColor(red: 0.16, green: 0.66, blue: 0.36, alpha: 1.0)

    // 主图叠加指标
    public static let ma66: UIColor       = UIColor(red: 0.55, green: 0.40, blue: 0.85, alpha: 1.0)
    public static let bollLine: UIColor   = UIColor(red: 0.95, green: 0.70, blue: 0.20, alpha: 1.0)

    // MACD 子图（v1.5 §2：DIF 白 + DEA 黄）
    public static let macdDIF: UIColor          = UIColor.white
    public static let macdDEA: UIColor          = UIColor(red: 1.00, green: 0.84, blue: 0.20, alpha: 1.0)
    public static let macdBarPositive: UIColor  = AppColor.candleUp
    public static let macdBarNegative: UIColor  = AppColor.candleDown

    // 盈亏（D-3 派生）
    public static let profitRed: UIColor  = AppColor.candleUp
    public static let lossGreen: UIColor  = AppColor.candleDown

    // 背景 / 网格 / 文字（D-3 派生 + D-9 chart-area 深色 bg / 自定 alpha 灰 / label）
    /// chart-area 默认 bg；深色 RGB 确保 `macdDIF`(白) / `macdDEA`(黄) / `bollLine`(橙) 等
    /// 高亮指标在默认主题下可见。Wave 3 §夜间模式做 dynamic 时再迭代。
    /// 注：app shell / scene / nav bar 应直接用 `.systemBackground`（UIKit 自带），
    /// 不要复用本常量——本常量语义是"k 线主图 / MACD 子图绘图区"背景。
    public static let background: UIColor = UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
    public static let gridLine: UIColor   = UIColor(white: 0.5, alpha: 0.25)
    public static let text: UIColor       = .label
}
#endif

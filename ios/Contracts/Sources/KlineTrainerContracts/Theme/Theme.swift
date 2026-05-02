// Kline Trainer Swift Contracts — F2 Theme
// Spec: kline_trainer_modules_v1.4.md §F2 (L817-838) + plan v1.5 §2 (DEA 黄)
// Design doc: docs/superpowers/specs/2026-05-01-f2-theme-design.md
//
// Spec drift D-1/D-3/D-4/D-6/D-7/D-8/D-9/D-10/D-11 详见 design doc §"Spec discrepancies"。

// MARK: - 纯值层（macOS / iOS 共用，swift test 直跑）

public enum AppColorScheme: String, Equatable, Sendable, CaseIterable {
    case light
    case dark
}

public func resolveColorScheme(displayMode: DisplayMode,
                               traitIsDark: Bool?) -> AppColorScheme {
    switch displayMode {
    case .system: return (traitIsDark == true) ? .dark : .light
    case .light:  return .light
    case .dark:   return .dark
    }
}

/// platform-neutral RGBA token；13 个默认色字面 + 派生 alias 全部以本结构表达，
/// 让 macOS swift test 直接断言 RGB 值 / alias / 通道差 contrast invariant（D-11）。
public struct AppColorRGBA: Equatable, Sendable {
    public let red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public init(white: Double, alpha: Double = 1.0) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }
    /// 任一通道（R/G/B）差的最大值。判 contrast 是否充分（用 ≥ 0.4 阈值）。
    public func maxChannelDiff(to other: AppColorRGBA) -> Double {
        max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
    }
}

/// 13 默认色 token（spec 字面 8 + "..."派生 5；中文红涨绿跌；v1.5 §2 DIF白/DEA黄）。
/// caller 取 UIKit 则用下方 `AppColor.X`；caller 取 RGBA 直接读 `AppColorTokens.X`。
public enum AppColorTokens {
    // 主图蜡烛
    public static let candleUp        = AppColorRGBA(red: 0.86, green: 0.18, blue: 0.20)
    public static let candleDown      = AppColorRGBA(red: 0.16, green: 0.66, blue: 0.36)
    // 主图叠加指标
    public static let ma66            = AppColorRGBA(red: 0.55, green: 0.40, blue: 0.85)
    public static let bollLine        = AppColorRGBA(red: 0.95, green: 0.70, blue: 0.20)
    // MACD（v1.5 §2：DIF 白 + DEA 黄）
    public static let macdDIF         = AppColorRGBA(white: 1.0)
    public static let macdDEA         = AppColorRGBA(red: 1.00, green: 0.84, blue: 0.20)
    public static let macdBarPositive = AppColorTokens.candleUp     // D-3 派生
    public static let macdBarNegative = AppColorTokens.candleDown
    // 盈亏（D-3 派生）
    public static let profitRed       = AppColorTokens.candleUp
    public static let lossGreen       = AppColorTokens.candleDown
    // chart-area 背景 / 网格 / 文字（D-9 / D-10：chart-area 深色 bg + 浅色 text）
    public static let background      = AppColorRGBA(red: 0.10, green: 0.10, blue: 0.12)
    public static let gridLine        = AppColorRGBA(white: 0.5, alpha: 0.25)
    public static let text            = AppColorRGBA(white: 0.92)
}

// MARK: - UIKit shell 层（仅 iOS / iOS Simulator 编译；macOS host 跳过）

#if canImport(UIKit)
import UIKit
import Observation  // D-8 defensive

@MainActor
@Observable
public final class ThemeController {
    public var displayMode: DisplayMode = .system

    public init() {}

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

extension UIColor {
    /// platform-neutral `AppColorRGBA` → `UIColor` 薄 bridge（D-11）。
    public convenience init(rgba: AppColorRGBA) {
        self.init(red: CGFloat(rgba.red), green: CGFloat(rgba.green),
                  blue: CGFloat(rgba.blue), alpha: CGFloat(rgba.alpha))
    }
}

/// 13 默认 UIColor const = `AppColorTokens` 同名 token 的 UIKit bridge（D-11）。
/// 业务逻辑（contrast / alias / 字面 RGB）由 macOS swift test 在 token 层断言；
/// 本枚举仅做 UIColor 转换，下游 SwiftUI 用 `Color(uiColor: AppColor.X)` 转换。
public enum AppColor {
    public static let candleUp        = UIColor(rgba: AppColorTokens.candleUp)
    public static let candleDown      = UIColor(rgba: AppColorTokens.candleDown)
    public static let ma66            = UIColor(rgba: AppColorTokens.ma66)
    public static let bollLine        = UIColor(rgba: AppColorTokens.bollLine)
    public static let macdDIF         = UIColor(rgba: AppColorTokens.macdDIF)
    public static let macdDEA         = UIColor(rgba: AppColorTokens.macdDEA)
    public static let macdBarPositive = UIColor(rgba: AppColorTokens.macdBarPositive)
    public static let macdBarNegative = UIColor(rgba: AppColorTokens.macdBarNegative)
    public static let profitRed       = UIColor(rgba: AppColorTokens.profitRed)
    public static let lossGreen       = UIColor(rgba: AppColorTokens.lossGreen)
    public static let background      = UIColor(rgba: AppColorTokens.background)
    public static let gridLine        = UIColor(rgba: AppColorTokens.gridLine)
    public static let text            = UIColor(rgba: AppColorTokens.text)
}
#endif

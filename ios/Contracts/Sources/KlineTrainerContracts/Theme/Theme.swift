// Kline Trainer Swift Contracts — F2 Theme
// Spec: kline_trainer_modules_v1.4.md §F2 (L817-838) + plan v1.5 §2 (DEA 黄)
// Design doc: docs/superpowers/specs/2026-05-01-f2-theme-design.md
//
// Spec drift D-1/D-3/D-4/D-6/D-7/D-8/D-9/D-10/D-11/D-12 详见 design doc §"Spec discrepancies"。

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

/// platform-neutral RGBA token；13 个默认色字面 + 派生 alias 全部以本结构表达（D-11）。
/// 公共 API：所有通道值在 init 静默 clamp 到 [0, 1]（D-12），保证 `UIColor(rgba:)`
/// 桥接永不触发 UIKit 运行时越界。无 precondition / throws（项目 grep gate 禁用）。
public struct AppColorRGBA: Equatable, Sendable {
    public let red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red   = min(max(0, red),   1)
        self.green = min(max(0, green), 1)
        self.blue  = min(max(0, blue),  1)
        self.alpha = min(max(0, alpha), 1)
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
    public static let ma66            = AppColorRGBA(red: 0.60, green: 0.42, blue: 0.95)  // RFC-B D7：提饱和
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
    /// RGBA 取值见 plan §D2；前景 token 经 WCAG 相对亮度对比 ≥ 3:1 vs 白底（`lightForegroundContrastWCAG` 测；
    /// codex R1-F1 修：旧 maxChannelDiff 代理放过 DEA 2.74:1，改真亮度对比闸门）。
    public static let light: AppPalette = {
        let up   = AppColorRGBA(red: 0.82, green: 0.10, blue: 0.12)   // 红涨（白底加深）
        let down = AppColorRGBA(red: 0.05, green: 0.55, blue: 0.25)   // 绿跌（白底加深）
        return AppPalette(
            candleUp: up, candleDown: down,
            ma66: AppColorRGBA(red: 0.42, green: 0.25, blue: 0.72),
            bollLine: AppColorRGBA(red: 0.75, green: 0.50, blue: 0.05),
            macdDIF: AppColorRGBA(red: 0.15, green: 0.15, blue: 0.18),
            macdDEA: AppColorRGBA(red: 0.70, green: 0.45, blue: 0.0),  // codex R1-F1：0.80/0.55→0.70/0.45（2.74:1→3.76:1 ≥3）
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

/// scheme-aware UIKit 调色板：`AppPalette` 经 `UIColor(rgba:)` 桥。
/// `.dark`/`.light` 为缓存 static（无逐帧分配）；`KLineView.currentPalette` 据 trait 选取。
/// `: Sendable`：Swift 6 strict-concurrency 下 `public static let` 全局须 Sendable；
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
#endif

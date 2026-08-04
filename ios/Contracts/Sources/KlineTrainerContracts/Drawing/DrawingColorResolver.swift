// DrawingColorResolver.swift
// 划线颜色 token → RGBA 的纯解析（host 可测，非 View / 非 @MainActor）。
// 与图表 AppColorTokens（蜡烛/MA/MACD 13-token）无关：那是另一套语义。
// 7 彩色主题无关；black/white 自适应纯 ink（日纯黑/夜纯白，母 spec §4.2 / D36，切片3 §4.3）。

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
        // 切片3：自适应「线色」——.black/.white 都解析成纯 ink（日纯黑、夜纯白），删糊色 fallback。
        // 复用既有值域（不新增枚举）；两者成同义自适应 ink。根治「日间黑线切夜间不可读」。
        case .black, .white:
            return scheme == .dark ? AppColorRGBA(red: 1, green: 1, blue: 1)   // 夜：纯白
                                   : AppColorRGBA(red: 0, green: 0, blue: 0)   // 日：纯黑
        }
    }

    /// D55（1b-i PR-3）：**选中高亮色**。与常驻面板类型图标的高亮框同源 —— 那里用 SwiftUI
    /// `Color.accentColor`（`UI/DrawingTypeOverlay.swift:28-29`），而 `AccentColor.colorset` 里
    /// **没有自定义色值**（实测 `Contents.json` 只有 `{"idiom":"universal"}`）→ 落系统蓝。
    /// 渲染层在包内、只有 CoreGraphics，取不到 asset catalog，故这里按系统蓝的两套取值内联；
    /// 不精确匹配也只是观感差异，不影响任何判据。
    /// **不占用 `DrawingColorToken` 值域**（与 9 个 token 的解析结果两两不等，`selectionColorIsOutsideTokenRange` 钉死）。
    /// 对比度：light 底 4.02:1 / dark 底 5.76:1，均 ≥3:1（图形元素阈，`selectionStrokeContrastWCAG` 测）。
    public static func selectionRGBA(scheme: AppColorScheme) -> AppColorRGBA {
        scheme == .dark ? AppColorRGBA(red: 0.039, green: 0.518, blue: 1.0)   // 夜：systemBlue dark
                        : AppColorRGBA(red: 0.0,   green: 0.478, blue: 1.0)   // 日：systemBlue light
    }
}

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

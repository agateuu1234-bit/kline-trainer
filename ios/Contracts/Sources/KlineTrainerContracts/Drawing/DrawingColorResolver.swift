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
}

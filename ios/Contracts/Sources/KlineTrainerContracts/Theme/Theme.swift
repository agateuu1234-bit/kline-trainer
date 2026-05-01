// Kline Trainer Swift Contracts — F2 Theme
// Spec: kline_trainer_modules_v1.4.md §F2 (L817-838) + plan v1.5 §2 (DEA 黄)
// Design doc: docs/superpowers/specs/2026-05-01-f2-theme-design.md
//
// Spec drift（design doc §"Spec discrepancies"）：
//   D-1：spec L824 literal `ColorScheme` 改为 `AppColorScheme`（避 SwiftUI 命名冲突）
//   D-3：13 个 default UIColor constants（spec 字面 8 + "..."派生 5）
//   D-4：path `Theme/` 落 Contracts package（同 C1a precedent）
//   D-6：`DisplayMode` 复用 Models.swift L41（M0.3 已落地，case 顺序 light/dark/system，无 CaseIterable）

import Foundation

// MARK: - 纯值层（macOS / iOS 共用，swift test 直跑）

// `DisplayMode` 在 Models.swift（M0.3）已定义；F2 复用，**不再 redeclare**（D-6）

public enum AppColorScheme: String, Equatable, Sendable, CaseIterable {
    case light
    case dark
}

/// 解析 displayMode + 当前 trait 的 dark 标志 → 实际生效 ColorScheme。
/// `traitIsDark` 来源：iOS `UITraitCollection.userInterfaceStyle == .dark`，由 caller 抽离。
/// 纯函数，无副作用，可在任意 actor / thread 调用。
public func resolveColorScheme(displayMode: DisplayMode,
                               traitIsDark: Bool) -> AppColorScheme {
    switch displayMode {
    case .system: return traitIsDark ? .dark : .light
    case .light:  return .light
    case .dark:   return .dark
    }
}

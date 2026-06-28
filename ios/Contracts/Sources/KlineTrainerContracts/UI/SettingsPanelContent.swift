// ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift
// 平台无关纯值 helper：commission 边界换算/格式 + 下载数量校验 + displayMode label。
// 仅 import Foundation（host swift test 全测）；SettingsPanel 壳调用，不重复逻辑。
// Spec: kline_trainer_modules_v1.4.md L2009/L2013（commission 换算）+ plan_v1.5 §6.4（5 控件）
import Foundation

public enum SettingsPanelContent {

    // MARK: - commission 边界换算（spec L2009/L2013：UI 万分之一 ↔ 存储小数率）
    public static func commissionRate(fromUIInputTenThousandth x: Double) -> Double { x * 0.0001 }
    public static func uiDisplayTenThousandth(fromCommissionRate r: Double) -> Double { r * 10000 }

    /// §6.4「精确到小数点后 3 位」：把存储小数率显示成 UI 万分之一字符串。
    public static func formatCommissionUIInput(_ rate: Double) -> String {
        String(format: "%.3f", uiDisplayTenThousandth(fromCommissionRate: rate))
    }

    /// §6.4「不能为空」：解析 UI 万分之一输入 → 存储小数率；空/非数字/负数 → nil。
    /// R-plan-6-1：输入层拒负费率，与 SettingsDAOImpl.saveSettings 守卫形成双层防护。
    public static func parseCommissionUIInput(_ input: String) -> Double? {
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let ui = Double(t), ui >= 0 else { return nil }
        return commissionRate(fromUIInputTenThousandth: ui)
    }

    // MARK: - 下载数量校验（§6.4：整数 1~20）
    public enum DownloadCountValidation: Equatable, Sendable {
        case valid(Int)
        case empty
        case notInteger
        case outOfRange
    }

    public static func validateDownloadCount(_ input: String) -> DownloadCountValidation {
        let t = input.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .empty }
        guard let n = Int(t) else { return .notInteger }
        guard (1...20).contains(n) else { return .outOfRange }
        return .valid(n)
    }

    // MARK: - 重置资金文案（运行时 #1：破坏性，须如实披露清空训练记录）
    public static let resetButtonLabel = "重置资金（清空记录 → ¥100,000）"
    public static let resetConfirmTitle = "确认重置？将清空训练记录"
    public static let resetConfirmMessage = "此操作会删除全部训练记录与未完成的对局，并将资金恢复为 ¥100,000，且不可撤销。"

    // MARK: - 显示模式 label（§6.4：白天/夜间/跟随系统）
    public static func displayModeLabel(_ mode: DisplayMode) -> String {
        switch mode {
        case .light: return "白天模式"
        case .dark: return "夜间模式"
        case .system: return "跟随系统"
        }
    }
    public static let displayModeOrder: [DisplayMode] = [.light, .dark, .system]
}

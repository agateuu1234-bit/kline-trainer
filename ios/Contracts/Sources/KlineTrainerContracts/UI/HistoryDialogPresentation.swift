// ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryDialogPresentation.swift
// Spec: docs/superpowers/specs/2026-06-20-history-dialog-centered-design.md（RFC #2）
//
// 平台无关纯路由谓词：把 AppRouter.Modal? 翻译成「共享 sheet 该呈现什么 / 是否该弹居中 history 弹窗 /
// sheet 的 dismiss 回写是否可生效」。仅 import Foundation —— host swift test 全测（D10 例外：这是纯逻辑）。
//
// 决议来源：
// - D6：.history 经 .overlay 居中呈现，不进共享 .sheet → sheetItem 把它滤成 nil。
// - High-1：sheet 自身 dismiss 的 set(nil) 不得清掉刚置位的 .history（dialog 秒关）→ sheetDismissMayApply 守卫。
// - D13：.animation(_:value:) 需 Equatable 驱动值；Modal 仅 Identifiable 无 Equatable → 用 Bool 投影 isHistoryPresented。

import Foundation

public enum HistoryDialogPresentation {

    /// 共享 `.sheet(item:)` 的 item 过滤：`.history`（居中 overlay）→ nil；`.settings`/`.settlement` 原样透传。
    /// 注：settings 的「popover 专属滤出 sheet」下沉到用 popover 的 AppRootView 本地处理（WB-R4 功能退路），
    /// 本通用谓词保持中立（settings 经共享 sheet 是 legacy 消费者的默认路由）。
    public static func sheetItem(for modal: AppRouter.Modal?) -> AppRouter.Modal? {
        if case .history = modal { return nil }
        return modal
    }

    /// 是否应呈现居中 history 弹窗（驱动 overlay 条件 + `.animation(value:)`）。
    public static func isHistoryPresented(_ modal: AppRouter.Modal?) -> Bool {
        if case .history = modal { return true }
        return false
    }

    /// RFC-E：当前态是否为设置（驱动锚齿轮 popover 呈现 + dismiss 守卫）。
    public static func isSettings(_ modal: AppRouter.Modal?) -> Bool {
        if case .settings = modal { return true }
        return false
    }

    /// High-1 守卫：共享 sheet 的 dismiss 回写是否可生效。`.history`（居中 overlay）态返 false（其 set(nil) 回写须拦）；其余 true。
    /// 注：settings 的 popover dismiss 守卫下沉 AppRootView 本地（WB-R4 功能退路）。
    public static func sheetDismissMayApply(current: AppRouter.Modal?) -> Bool {
        if case .history = current { return false }
        return true
    }
}

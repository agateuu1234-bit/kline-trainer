// ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift
// Spec: kline_trainer_plan_v1.5.md §6.1.3 L871-895 + plan 2026-05-29-pr-u6-history-action-sheet.md
//
// 平台无关纯值类型：把 TrainingRecord 翻译成历史动作表显示用的单个标题字符串。
// 平台守卫：仅 import Foundation，不 import SwiftUI/UIKit/CoreGraphics —— host swift test 全测。
//
// 决议（D3-D5/D14）：
// - D3 弹窗只显示识别本条记录的标题（股票名（代码）），不重复历史行已有的明细字段
// - D4 自包含 formatStock，不复用 U3 SettlementContent.formatStock（避免 sibling UI content 耦合）
// - D5 全角括号 （ U+FF08 / ） U+FF09（spec §6.1.3 L880 字面）
// - D14 值快照：init 一次性算 title；static func 便于 Self. 调用

import Foundation

public struct HistoryActionContent: Equatable, Sendable {
    public let title: String   // "贵州茅台（600519）"

    public init(record: TrainingRecord) {
        self.title = Self.formatStock(name: record.stockName, code: record.stockCode)
    }

    /// D4/D5：name（code），全角括号。
    static func formatStock(name: String, code: String) -> String {
        "\(name)（\(code)）"
    }
}

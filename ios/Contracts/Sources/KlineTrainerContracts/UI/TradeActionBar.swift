// ios/Contracts/Sources/KlineTrainerContracts/UI/TradeActionBar.swift
// RFC-B T2 底部交易薄条：Period.shortLabel + TradeActionBarContent 纯值 + TradeActionBar 视图。

import Foundation

extension Period {
    /// T2 分段钮短标签（RFC-B D10）。
    public var shortLabel: String {
        switch self {
        case .m3:      return "3分"
        case .m15:     return "15分"
        case .m60:     return "60分"
        case .daily:   return "日线"
        case .weekly:  return "周线"
        case .monthly: return "月线"
        }
    }
}

/// 平台无关纯值：T2 薄条显示串。价 = 全局 currentPrice（中性措辞，非 per-period，RFC-B §5）。host 测。
public struct TradeActionBarContent: Equatable, Sendable {
    public let priceLabel: String

    public init(price: Double) {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let body = f.string(from: NSNumber(value: price)) ?? String(format: "%.2f", price)
        self.priceLabel = "下单价 ¥ \(body)"
    }
}

/// 防过期下单守卫（codex R2-high）：买卖档位条捕获「开条时的下单周期」；选档执行前比对该 panel
/// 当前周期。周期被切（分段钮换 activePanel / 两指滑 `switchPeriodCombo`）后捕获值与当前不符 →
/// 该条作废，**不得对新周期下单**（否则推进错周期 + autosave 不可逆）。平台无关纯函数，host 测。
public func tradeStripStillValid(capturedPeriod: Period, currentPeriod: Period) -> Bool {
    capturedPeriod == currentPeriod
}

#if canImport(UIKit)
import SwiftUI

/// RFC-B T2：底部固定薄条。周期分段钮(active 切换) + 中性下单价 + 买/卖/持有。
struct TradeActionBar: View {
    let content: TradeActionBarContent
    let upperPeriod: Period
    let lowerPeriod: Period
    @Binding var activePanel: PanelId
    let buyEnabled: Bool
    let sellEnabled: Bool
    let holdLabel: String           // "持有" / "观察"
    let onBuy: () -> Void
    let onSell: () -> Void
    let onHold: () -> Void

    var body: some View {
        // 单行：周期钮 + 小下单价 + 买/卖/持有 大按钮（controlSize 大=更高更大点击区）。
        // 整条 ignoresSafeArea(.bottom) 下探进底部 home-indicator 空白 → 增加的高度来自那条 strip，
        // 不从上方 K 线/顶栏借（保证图与顶栏高度不变）。横向内收 16pt 离开底部圆角两角。
        HStack(spacing: 8) {
            Picker("下单周期", selection: $activePanel) {
                Text(upperPeriod.shortLabel).tag(PanelId.upper)
                Text(lowerPeriod.shortLabel).tag(PanelId.lower)
            }
            .pickerStyle(.segmented)
            .frame(width: 104)
            .accessibilityLabel("下单周期")
            Text(content.priceLabel)
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            Button("买入", action: onBuy).disabled(!buyEnabled).tint(.red)
                .accessibilityLabel("买入").frame(maxWidth: .infinity)
            Button("卖出", action: onSell).disabled(!sellEnabled).tint(.green)
                .accessibilityLabel("卖出").frame(maxWidth: .infinity)
            Button(holdLabel, action: onHold)
                .accessibilityLabel(holdLabel).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)       // 默认大小：large 会让条体高过原始高度 → 盖住下图 MACD
        .font(.system(size: 14).weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)        // ≈ 原始高度 → 图区不压缩、不盖 MACD
        .frame(maxWidth: .infinity)
        // 仅**背景**下探到屏幕底（吃 home-indicator 空白的视觉），按钮内容留在安全区内 → 不进 home-indicator、不盖图
        .background(.bar, ignoresSafeAreaEdges: .bottom)
    }
}
#endif

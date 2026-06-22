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
        HStack(spacing: 6) {
            Picker("下单周期", selection: $activePanel) {
                Text(upperPeriod.shortLabel).tag(PanelId.upper)
                Text(lowerPeriod.shortLabel).tag(PanelId.lower)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .accessibilityLabel("下单周期")
            Text(content.priceLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("买入", action: onBuy).disabled(!buyEnabled).tint(.red).accessibilityLabel("买入")
            Button("卖出", action: onSell).disabled(!sellEnabled).tint(.green).accessibilityLabel("卖出")
            Button(holdLabel, action: onHold).accessibilityLabel("持有")
        }
        .buttonStyle(.bordered)
        .font(.system(size: 13).weight(.semibold))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.bar)
    }
}
#endif

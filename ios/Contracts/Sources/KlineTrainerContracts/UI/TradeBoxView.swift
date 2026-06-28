// ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBoxView.swift
// RFC-A A2：买卖框（方案 D）。数量框 + −/＋(±100) + 比例快捷填入 + 可买可卖 + 预估 + 右上✕ + 全宽确认。
// 弹出位置/红框由 caller(TrainingView) 的 active-panel overlay 决定（沿用 RFC-B 机制）。

import SwiftUI

public struct TradeBoxView: View {
    private let content: TradeBoxContent
    @State private var qty: Int
    @FocusState private var qtyFocused: Bool   // R-plan-23-1：失焦规范化数量
    private let onConfirm: (Int) -> Void
    private let onCancel: () -> Void

    public init(action: TradeAction, price: Double, cash: Double, holding: Int,
                fees: FeeSnapshot, initialQty: Int,
                onConfirm: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self._qty = State(initialValue: initialQty)
        self.content = TradeBoxContent(action: action, price: price, cash: cash,
                                       holding: holding, fees: fees, qty: initialQty)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    // 用当前 qty 重算的瞬时 content（步进/填入后刷新标签）
    private var live: TradeBoxContent {
        TradeBoxContent(action: content.action, price: content.price, cash: content.cash,
                        holding: content.holding, fees: content.fees, qty: qty)
    }
    private var tint: Color { content.action == .buy ? .red : .green }

    public var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(content.action == .buy ? "买入" : "卖出").foregroundStyle(tint).bold()
                Text("现价 ¥\(String(format: "%.2f", content.price))").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(live.limitLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                Button(action: onCancel) { Image(systemName: "xmark") }.buttonStyle(.bordered)
                    .accessibilityLabel("关闭")
            }
            HStack(spacing: 8) {
                Button("−100") { setQty(live.effectiveShares - TradeCalculator.shareLotSize) }
                    .buttonStyle(.bordered).accessibilityLabel("减100股")
                TextField("数量", value: $qty, format: .number)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("数量")
                    .focused($qtyFocused)
                    .onSubmit { qty = normalize(qty) }
                    // R-plan-23-1：**失焦**时规范化（手动输入期间不抖；输入完移焦即 floor/clamp 进 state）。
                    .onChange(of: qtyFocused) { _, focused in if !focused { qty = normalize(qty) } }
                Button("+100") { setQty(live.effectiveShares + TradeCalculator.shareLotSize) }
                    .buttonStyle(.bordered).accessibilityLabel("加100股")
            }
            Text(live.estimateLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Array(zip(PositionTier.allCases, live.tierLabels)), id: \.0) { tier, label in
                    Button(label) { setQty(live.fillShares(tier)) }   // R-plan-23-1：填入即 clamp（高费率超买亦不超 limit）
                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        .accessibilityLabel(label)
                }
            }
            Button(action: { let s = live.effectiveShares; qty = s; onConfirm(s) }) {  // R-plan-23-1：提交前把字段=提交值
                Text(live.confirmLabel).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).tint(tint).disabled(!live.confirmEnabled)
            .accessibilityLabel(live.confirmLabel)
        }
        .padding(12).background(.thinMaterial)
    }

    // R-plan-23-1：把任意原始数量规范化为有效下单股数（lot-floor + clamp [0,limit]，含 D7 清仓例外），
    // 写回 qty @State → 字段显示**始终 == 将提交的 effectiveShares**（步进/填入/编辑/确认四处统一）。
    private func normalize(_ raw: Int) -> Int {
        TradeBoxContent(action: content.action, price: content.price, cash: content.cash,
                        holding: content.holding, fees: content.fees, qty: raw).effectiveShares
    }
    private func setQty(_ raw: Int) { qty = normalize(raw) }
}

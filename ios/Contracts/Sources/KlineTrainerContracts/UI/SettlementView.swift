// ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
// Spec: kline_trainer_modules_v1.4.md §U3 L2065-2071 字面 init 签名 +
//       kline_trainer_plan_v1.5.md §6.3 L988-1009 ASCII 布局
//
// 薄 SwiftUI shell：body 仅装配 VStack/HStack/Button；所有格式化交 SettlementContent（Task 1）。
//
// 决议（D1/D2/D9-D11）：
// - D1 SwiftUI 跨 iOS17/macOS14/Catalyst 三平台原生支持，不加 #if canImport(UIKit)
// - D2 数值不分盈亏色，默认 .primary（spec §6.3 不规定，Simplicity）
// - D9 TrainingRecord.preview() 内联本文件 #if DEBUG 区，U6 顺位 15 再看是否抽取
// - D10 不单测 SwiftUI shell，靠 Catalyst build-for-testing 闸门
// - D11 onConfirm 闭包语义（Normal 保存 / Replay 跳过）属 caller，本 View 只触发

import SwiftUI

public struct SettlementView: View {
    private let content: SettlementContent
    private let onConfirm: () -> Void

    public init(record: TrainingRecord, onConfirm: @escaping () -> Void) {
        self.content = SettlementContent(record: record)
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本局结算")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 8)

            // 第一组：股票 + 起始
            VStack(alignment: .leading, spacing: 8) {
                row(label: "股票", value: content.stock)
                row(label: "起始", value: content.startMonth)
            }

            Divider()

            // 第二组：5 数值
            VStack(alignment: .leading, spacing: 8) {
                row(label: "总资金", value: content.totalCapital)
                row(label: "总收益率", value: content.returnRate)
                row(label: "最大回撤", value: content.maxDrawdown)
                row(label: "买入次数", value: content.buyCount)
                row(label: "卖出次数", value: content.sellCount)
            }

            Spacer().frame(height: 8)

            Button(action: onConfirm) {
                Text("确认")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - DEBUG-only preview fixture (D9 + R1-H4 — fileprivate 防跨模块污染)

#if DEBUG
fileprivate extension TrainingRecord {
    /// Preview fixture。决议 D9 + R1-H4：**fileprivate** 真单 use site；U6 顺位 15 再看是否抽取到 PreviewFakes
    /// 或各自 fileprivate 内联各自 fixture。public 会污染下游 DEBUG 编译 → 破坏 PreviewFakes 单一来源约定。
    static func preview() -> TrainingRecord {
        TrainingRecord(
            id: 1,
            trainingSetFilename: "preview.sqlite",
            createdAt: 1_700_000_000,
            stockCode: "600519",
            stockName: "贵州茅台",
            startYear: 2021,
            startMonth: 8,
            totalCapital: 102_345.67,
            profit: 2_345.67,
            returnRate: 0.0234,
            maxDrawdown: -0.0832,
            buyCount: 4,
            sellCount: 3,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            finalTick: 1000
        )
    }
}

#Preview {
    SettlementView(record: .preview(), onConfirm: {})
}
#endif

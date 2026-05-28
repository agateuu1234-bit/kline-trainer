// ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift
// Spec: kline_trainer_modules_v1.4.md §U6 L2094-2103 字面 init 签名 +
//       kline_trainer_plan_v1.5.md §6.1.3 L871-895 历史记录点击弹窗
//
// 薄 SwiftUI shell：body 仅装配 VStack/Button；标题映射交 HistoryActionContent（Task 1）。
//
// 决议（D1/D2/D6-D13）：
// - D1 SwiftUI 跨 iOS17/macOS14/Catalyst 三平台原生支持，不加 #if canImport(UIKit)
// - D2 内容 View（无 Binding），由 caller 装进 sheet/popover 呈现
// - D6 三按钮：复盘 / 再来一次 / 取消（取消置底；取消补满 init onCancel 契约）
// - D7 按钮文案字面 复盘 / 再来一次 / 取消
// - D8 三按钮 .bordered，不分盈亏色 / 不 RGB 硬编码 / 不用 .borderedProminent 暗示主次
// - D9 onReview / onReplay / onCancel 闭包 @escaping（Swift 编译强制）；不加 @Sendable
// - D10 不单测 SwiftUI shell，靠 Catalyst build-for-testing 闸门
// - D11 fileprivate extension TrainingRecord.preview() 内联本文件 #if DEBUG 区，不污染 PreviewFakes
// - D12 仅语义依赖 E4（caller 用 onReview/onReplay 路由 Review/Replay 模式）；本文件不引业务运行时类型
// - D13 Button tap 仅 fire callback，不调 dismiss（caller 负责 presentation）

import SwiftUI

public struct HistoryActionSheet: View {
    private let content: HistoryActionContent
    private let onReview: () -> Void
    private let onReplay: () -> Void
    private let onCancel: () -> Void

    public init(record: TrainingRecord,
                onReview: @escaping () -> Void,
                onReplay: @escaping () -> Void,
                onCancel: @escaping () -> Void) {
        self.content = HistoryActionContent(record: record)
        self.onReview = onReview
        self.onReplay = onReplay
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // D3: 标题 = 股票名（代码），识别本条记录
            Text(content.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 8)

            // D6: 复盘 → onReview
            Button(action: onReview) {
                Text("复盘")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)

            // D6: 再来一次 → onReplay
            Button(action: onReplay) {
                Text("再来一次")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)

            Spacer().frame(height: 8)

            // D6: 取消置底 → onCancel（补满 modules §U6 init 字面要求）
            Button(action: onCancel) {
                Text("取消")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
    }
}

// MARK: - DEBUG-only preview fixture (D11 — fileprivate extension 防跨模块污染，机制与 U3/U5 同款)

#if DEBUG
fileprivate extension TrainingRecord {
    /// Preview fixture。决议 D11：**fileprivate** 文件作用域，与 U3 SettlementView 内同名 fixture 不冲突
    /// （均文件作用域，Swift 允许）；不抽到 PreviewFakes（public 会污染下游 DEBUG 编译，U3 R1-H4 同款）。
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
    HistoryActionSheet(
        record: .preview(),
        onReview: {},
        onReplay: {},
        onCancel: {}
    )
}
#endif

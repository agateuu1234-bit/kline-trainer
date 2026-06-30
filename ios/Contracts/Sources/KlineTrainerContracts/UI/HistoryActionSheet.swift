// ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift
// Spec: kline_trainer_modules_v1.4.md §U6 字面 init 签名 +
//       kline_trainer_plan_v1.5.md §6.1.3 历史记录点击弹窗 +
//       docs/superpowers/specs/2026-06-20-history-dialog-centered-design.md（RFC #2：改屏幕居中弹窗）
//
// 命名沿用 iOS action-sheet（动作选择器）语义；**自 RFC #2 起呈现为屏幕居中弹窗（非底部 sheet）**：
// body 为全屏 ZStack = 半透明遮罩（点击=取消）+ 居中卡片；由 AppRootView 经 .overlay 装载（非 .sheet）。
//
// 决议（D1/D2/D6-D13，RFC #2 修订）：
// - D1 自定义居中卡片（遮罩 + 居中 ZStack），不用系统 .alert；跨 iOS17/macOS14/Catalyst 原生 SwiftUI
// - D2 点半透明遮罩 = 取消（onCancel）；卡片内仍保留显式「取消」按钮
// - D7 维持 import SwiftUI（不加 #if canImport(UIKit)）；Color/RoundedRectangle/.regularMaterial 均跨平台
// - D9 遮罩 Color.black.opacity(0.4).ignoresSafeArea()；卡片 .frame(maxWidth:280) + .regularMaterial 圆角16 + 阴影
// - D10 inner（标题 + 三 .bordered 按钮 + 各 frame/padding + 末 .padding(24)）字面不变；外层 ZStack/frame/background/shadow 新增
// - D13（原文件）Button tap 仅 fire callback，不调 dismiss（presentation 由 caller/router 负责）
// - 文件不引业务运行时类型；onReview/onReplay/onCancel @escaping（Swift 编译强制）

import SwiftUI

public struct HistoryActionSheet: View {
    private let content: HistoryActionContent
    private let hasResumableReplay: Bool
    private let onReview: () -> Void
    private let onReplay: () -> Void
    private let onCancel: () -> Void

    public init(record: TrainingRecord,
                hasResumableReplay: Bool,
                onReview: @escaping () -> Void,
                onReplay: @escaping () -> Void,
                onCancel: @escaping () -> Void) {
        self.content = HistoryActionContent(record: record)
        self.hasResumableReplay = hasResumableReplay
        self.onReview = onReview
        self.onReplay = onReplay
        self.onCancel = onCancel
    }

    /// A7: 可测 static helper — 按是否有续局切换 replay 钮文案。
    public static func replayButtonTitle(hasResumableReplay: Bool) -> String {
        hasResumableReplay ? "返回训练" : "再次训练"
    }

    public var body: some View {
        ZStack {
            // D2: 半透明遮罩，点击=取消
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            // 居中卡片：以下 VStack….padding(24) = 原 body 字面不变（D10 inner）；
            //          .frame/.background/.shadow = RFC #2 外层新增（D9）
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

                // A7: replay 钮文案随 hasResumableReplay 切换；「取消」按钮已移除（遮罩点击即取消）。
                Button(action: onReplay) {
                    Text(Self.replayButtonTitle(hasResumableReplay: hasResumableReplay))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
        }
    }
}

// MARK: - DEBUG-only preview fixture (fileprivate extension 防跨模块污染，机制同 U3/U5)

#if DEBUG
fileprivate extension TrainingRecord {
    /// Preview fixture。**fileprivate** 文件作用域，与同名 fixture 不冲突；不抽 PreviewFakes。
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
    // D12: 渲染整体居中弹窗（含遮罩）
    HistoryActionSheet(
        record: .preview(),
        hasResumableReplay: false,
        onReview: {},
        onReplay: {},
        onCancel: {}
    )
}
#endif

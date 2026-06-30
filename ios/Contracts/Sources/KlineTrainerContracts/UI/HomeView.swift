// ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift
// Spec: kline_trainer_plan_v1.5.md §6.1 L849-899 + docs/superpowers/specs/2026-06-07-wave2-u1-home-view-design.md
//
// 薄 SwiftUI shell：消费 HomeContent + 4 注入导航意图闭包，渲染首页四区（统计栏/开始·继续/历史列表/齿轮）。
// 无业务逻辑，不 import coordinator/settings/acceptance（view-only，D1）。
//
// 决议：
// - D1 view-only；coordinator 接线/路由归顺位 11
// - D6 点击历史行只 fire onSelectRecord(id)；U6 sheet + 复盘/再来一次 路由归顺位 11
// - D11 空缓存提示 inline .alert（hasCachedSets==false 且非 resuming）
// - 闭包不加 @Sendable（沿用 U6 D9，SwiftUI 主线程调用）
// - SwiftUI 跨 iOS17/macOS14/Catalyst 原生，不加 #if canImport(UIKit)（沿用 U6 D1）

import SwiftUI

public struct HomeView: View {
    private let content: HomeContent
    private let onStartTraining: () -> Void
    private let onContinueTraining: () -> Void
    private let onSelectRecord: (Int64) -> Void
    private let onOpenSettings: () -> Void
    private let isSettingsPresented: Binding<Bool>
    private let settingsContent: () -> AnyView

    @State private var showEmptyCacheAlert = false

    /// 源兼容 deprecated overload（codex whole-branch WB-2）：保留旧 5 参 init 不破坏下游编译，
    /// 但 `@available(deprecated)` 使「不接线设置 popover」**显式非静默**（codex WB-1 的静默丢 UI 顾虑）。
    /// 委托新 init 传 `.constant(false)`+`EmptyView`：本 init 构造的 HomeView **不呈现设置 popover**——
    /// 要呈现设置须用下方带 `isSettingsPresented`/`settingsContent` 的 init（如 AppRootView）。
    /// 仅声明保留（内部不使用，故 Catalyst 零-warning gate 不破；使用点才告警，提示下游迁移）。
    @available(*, deprecated, message: "此 init 不接线设置 popover（settingsContent=EmptyView）。要呈现设置请用带 isSettingsPresented/settingsContent 的 init；本重载仅为源兼容保留。")
    public init(content: HomeContent,
                onStartTraining: @escaping () -> Void,
                onContinueTraining: @escaping () -> Void,
                onSelectRecord: @escaping (Int64) -> Void,
                onOpenSettings: @escaping () -> Void) {
        self.init(content: content,
                  onStartTraining: onStartTraining, onContinueTraining: onContinueTraining,
                  onSelectRecord: onSelectRecord, onOpenSettings: onOpenSettings,
                  isSettingsPresented: .constant(false), settingsContent: { EmptyView() })
    }

    /// RFC-E：主 init —— 类型擦除 settingsContent → AnyView（仅设置 popover，非热路径）。
    /// HomeView 本体保持非泛型 concrete（类型标识不变，codex spec-R6-H1）。保 view-only D1：不 import settings/acceptance。
    /// 呈现设置须经此 init 注入 `isSettingsPresented`/`settingsContent`；不呈现设置的调用方显式传 `.constant(false)`+`{ EmptyView() }`。
    public init<SettingsContent: View>(content: HomeContent,
                onStartTraining: @escaping () -> Void,
                onContinueTraining: @escaping () -> Void,
                onSelectRecord: @escaping (Int64) -> Void,
                onOpenSettings: @escaping () -> Void,
                isSettingsPresented: Binding<Bool>,
                @ViewBuilder settingsContent: @escaping () -> SettingsContent) {
        self.content = content
        self.onStartTraining = onStartTraining
        self.onContinueTraining = onContinueTraining
        self.onSelectRecord = onSelectRecord
        self.onOpenSettings = onOpenSettings
        self.isSettingsPresented = isSettingsPresented
        self.settingsContent = { AnyView(settingsContent()) }
    }

    public var body: some View {
        VStack(spacing: 16) {
            statsBar
            primaryButton
            historyList
        }
        .padding()
        .alert("暂无可用训练数据，请先在设置中下载离线缓存",
               isPresented: $showEmptyCacheAlert) {
            Button("好", role: .cancel) {}
        }
    }

    // §6.1.1 统计栏 + §6.1.4 右上角齿轮
    private var statsBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("总局次：\(content.totalSessions)")
                Text("胜率：\(content.winRate)")
                Text("总资金：\(content.totalCapital)")
            }
            .font(.subheadline)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").font(.title2)
            }
            .accessibilityLabel("设置")
            .popover(isPresented: isSettingsPresented) {
                ScrollView {                                          // 强制布局契约：内容可滚动，最坏情况全部可达（spec §3.4）
                    settingsContent()
                }
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 320, maxHeight: 480)   // **上限宽 320 + 限高 480**：防长标签撑宽（idealWidth 非上限，codex plan-R1-M1）
                .presentationCompactAdaptation(.popover)              // iPhone 强制 popover 样式（iOS16.4+；项目 iOS17 满足）
            }
        }
    }

    // §6.1.2 开始/继续训练按钮（单一主 CTA → borderedProminent；与 U6 leaf-sheet sibling 钮语境不同）
    private var primaryButton: some View {
        Button(action: handlePrimaryAction) {
            Text(content.primaryActionLabel)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
    }

    private func handlePrimaryAction() {
        if content.isResuming {
            onContinueTraining()           // 继续从 pending 恢复，不查 cache
        } else if content.hasCachedSets {
            onStartTraining()
        } else {
            showEmptyCacheAlert = true     // D11 空缓存提示
        }
    }

    // §6.1.3 历史列表（可滚动；空 → 占位）
    @ViewBuilder
    private var historyList: some View {
        if content.isHistoryEmpty {
            Text("暂无训练记录")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(content.rows) { row in
                Button {
                    onSelectRecord(row.id)   // D6 仅 fire 意图，不 present sheet
                } label: {
                    historyRow(row)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func historyRow(_ row: HomeHistoryRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.dateTime).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(row.stock).font(.subheadline.bold())
            }
            HStack {
                Text(row.startMonth).font(.caption)
                Spacer()
                Text(row.totalCapital).font(.caption)
            }
            Text(row.profitAndRate)
                .font(.subheadline)
                .foregroundStyle(color(for: row.sign))   // A 股红涨绿跌 §6.1.3
        }
        .padding(.vertical, 4)
    }

    private func color(for sign: ProfitSign) -> Color {
        switch sign {
        case .positive: return .red
        case .negative: return .green
        case .zero: return .primary
        }
    }
}

// MARK: - DEBUG-only preview fixture（fileprivate 文件作用域，沿用 U3/U6 D11，不污染 PreviewFakes）

#if DEBUG
fileprivate extension HomeContent {
    static func preview(hasPending: Bool = true, hasCachedSets: Bool = true,
                        records: [TrainingRecord]) -> HomeContent {
        HomeContent(
            statistics: (totalCount: records.count, winCount: 2, currentCapital: 108_900.00),
            configuredCapital: 100_000, records: records,
            hasPending: hasPending, hasCachedSets: hasCachedSets,
            timeZone: TimeZone(identifier: "Asia/Shanghai") ?? .current)
    }
}

private func previewRecords() -> [TrainingRecord] {
    [
        TrainingRecord(id: 1, trainingSetFilename: "a.sqlite", createdAt: 1_710_532_800,
                       stockCode: "600519", stockName: "贵州茅台", startYear: 2021, startMonth: 8,
                       totalCapital: 102_345.67, profit: 2_345.67, returnRate: 0.0234, maxDrawdown: -0.0832,
                       buyCount: 4, sellCount: 3,
                       feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), finalTick: 1000),
        TrainingRecord(id: 2, trainingSetFilename: "b.sqlite", createdAt: 1_710_000_000,
                       stockCode: "000001", stockName: "平安银行", startYear: 2022, startMonth: 11,
                       totalCapital: 98_765.43, profit: -1_234.57, returnRate: -0.0123, maxDrawdown: -0.0501,
                       buyCount: 2, sellCount: 2,
                       feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), finalTick: 800),
    ]
}

#Preview("有历史 + 继续训练") {
    HomeView(content: .preview(records: previewRecords()),
             onStartTraining: {}, onContinueTraining: {}, onSelectRecord: { _ in }, onOpenSettings: {},
             isSettingsPresented: .constant(false), settingsContent: { EmptyView() })   // preview 不呈现设置（显式退出）
}

#Preview("空历史 + 空缓存") {
    HomeView(content: .preview(hasPending: false, hasCachedSets: false, records: []),
             onStartTraining: {}, onContinueTraining: {}, onSelectRecord: { _ in }, onOpenSettings: {},
             isSettingsPresented: .constant(false), settingsContent: { EmptyView() })   // preview 不呈现设置（显式退出）
}
#endif

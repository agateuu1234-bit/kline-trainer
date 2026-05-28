// ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
// Spec: kline_trainer_modules_v1.4.md §U5 L2084-2092 字面 init 签名 +
//       kline_trainer_plan_v1.5.md §6.2.4 L946-952 ASCII 布局
//
// 薄 SwiftUI shell：body 仅装配 VStack/HStack/Button；所有数据映射交 PositionPickerContent（Task 1）。
//
// 决议（D1/D2/D6-D11/D14-D16）：
// - D1 SwiftUI 跨 iOS17/macOS14/Catalyst 三平台原生支持，不加 #if canImport(UIKit)
// - D2 HStack 横向 5 按钮
// - D6 5-tier 行下方加显式"取消"按钮触发 onCancel（modules §U5 init 字面要求）
// - D7 标题"仓位选择"
// - D8 单 tap fire onPick，无 selected-then-confirm 中间态
// - D9 fileprivate preview fixture 内联本文件 #if DEBUG 区，不污染 PreviewFakes
// - D10 不单测 SwiftUI shell，靠 Catalyst build-for-testing 闸门
// - D11 onPick / onCancel 闭包 @escaping（Swift 编译强制）
// - D14 仅语义依赖 E2（caller 由持仓状态推导 enabledTiers）；本文件不引业务运行时类型
// - D15 Button tap 直接 fire onPick，不调 dismiss（caller 负责 presentation）
// - D16 不实现 RGB 硬编码 / 不分盈亏色，默认 SwiftUI Button style

import SwiftUI

public struct PositionPickerView: View {
    private let content: PositionPickerContent
    private let onPick: (PositionTier) -> Void
    private let onCancel: () -> Void

    public init(enabledTiers: Set<PositionTier>,
                onPick: @escaping (PositionTier) -> Void,
                onCancel: @escaping () -> Void) {
        self.content = PositionPickerContent(enabledTiers: enabledTiers)
        self.onPick = onPick
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("仓位选择")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 8)

            // D2: 5 档位横向（spec L949 ASCII）
            HStack(spacing: 12) {
                ForEach(content.tiers, id: \.tier) { item in
                    Button(action: { onPick(item.tier) }) {
                        Text(item.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!item.enabled)
                }
            }

            Spacer().frame(height: 8)

            // D6: 取消按钮触发 onCancel（modules §U5 init 字面要求）
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

// MARK: - DEBUG-only preview fixture (D9 — fileprivate extension 防跨模块污染，机制与 U3 D9 同款)

#if DEBUG
fileprivate extension PositionTier {
    /// Preview fixture：部分启用前 3 档（演示 disabled 视觉态）。
    /// `fileprivate` 防 public extension 跨模块污染下游 DEBUG 编译（U3 D9 + R1-H4 同款）。
    static func previewEnabledTiers() -> Set<PositionTier> {
        [.tier1, .tier2, .tier3]
    }
}

#Preview("部分启用") {
    PositionPickerView(
        enabledTiers: PositionTier.previewEnabledTiers(),
        onPick: { _ in },
        onCancel: {}
    )
}

#Preview("全启用") {
    PositionPickerView(
        enabledTiers: Set(PositionTier.allCases),
        onPick: { _ in },
        onCancel: {}
    )
}

#Preview("全 disabled") {
    PositionPickerView(
        enabledTiers: [],
        onPick: { _ in },
        onCancel: {}
    )
}
#endif

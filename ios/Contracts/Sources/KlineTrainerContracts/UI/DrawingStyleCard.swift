// Sources/KlineTrainerContracts/UI/DrawingStyleCard.swift
// 长按水平线图标弹出的统一设置卡片（1a-iii，母 spec §3）。4 组控件；不可用项只灰、不写任何解释字；
// 昼夜禁色。每次选择即写 DrawingSession.defaultStyle 单一真相（提交路径原子消费，Task 1）。
// 关闭 = 点卡外半透明遮罩（无「完成」钮）。作用对象 = 下一条要画的线（本期无选中，故无歧义）。
#if canImport(UIKit)
import SwiftUI

struct DrawingStyleCard: View {
    let session: DrawingSession
    let scheme: AppColorScheme
    let onDismiss: () -> Void

    // 本地镜像 defaultStyle，改动即回写 session（单一真相）。
    @State private var style: DrawingDefaultStyle

    init(session: DrawingSession, scheme: AppColorScheme, onDismiss: @escaping () -> Void) {
        self.session = session; self.scheme = scheme; self.onDismiss = onDismiss
        _style = State(initialValue: session.defaultStyle)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { onDismiss() }                     // 点遮罩即关
            card
                .contentShape(Rectangle())                       // 卡内点击不穿透到遮罩
                .padding(.horizontal, 12)
        }
    }

    private func commit(_ mutate: (inout DrawingDefaultStyle) -> Void) {
        mutate(&style); session.setDefaultStyle(style)           // 每次选择即写单一真相
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("线型") {
                seg(LineSubType.allCases, current: style.lineSubType,
                    enabled: { DrawingStyleAvailability.horizontalLineSubTypeEnabled($0) },
                    title: { subLabel($0) }) { picked in
                        // codex plan-R1-medium：切线型即规整依赖的 labelMode（如直线选『左』后切射线 → 回落 hidden），
                        // 杜绝「显示为灰却仍作默认被提交」的矛盾组合。card 是 setDefaultStyle 唯一写入者 → 规整在此即闭合。
                        commit {
                            $0.lineSubType = picked
                            $0.labelMode = DrawingStyleAvailability.normalizedLabelMode(current: $0.labelMode, lineSubType: picked)
                        }
                    }
            }
            group("线样式") {
                seg(LineStyle.allCases, current: style.lineStyle,
                    enabled: { _ in true }, title: { styleLabel($0) }) { picked in commit { $0.lineStyle = picked } }
            }
            group("粗细") {
                seg(Array(1...5), current: style.thickness,
                    enabled: { _ in true }, title: { "\($0)" }) { picked in commit { $0.thickness = picked } }
            }
            group("颜色") { colorRow }              // codex plan-R3-medium：9 色用色板网格，窄屏自动换行不溢出
            group("标注") {
                seg(LabelMode.allCases, current: style.labelMode,
                    enabled: { DrawingStyleAvailability.horizontalLabelModeEnabled($0, lineSubType: style.lineSubType) },
                    title: { labelLabel($0) }) { picked in commit { $0.labelMode = picked } }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // 一组：标题 + 一排可选项。标题只标组名，绝不写「不适用」。
    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); content() }
    }

    // 通用「一排分段选项」：横向 ScrollView 兜底，窄屏（375pt）任何一档都不会被裁掉/够不到（codex plan-R3-medium）。
    // 灰态由 enabled 决定；灰掉的点击无副作用（.disabled）。
    // enabled/title **必须 @escaping**（codex plan-R8-high）：它们被 ForEach 的**逃逸** ViewBuilder 闭包捕获，
    // 非逃逸参数在此会让 Catalyst/iOS 编译报错（host swift test 不编 #if canImport(UIKit) 体，只有真机门才炸）。
    private func seg<T: Hashable>(_ items: [T], current: T, enabled: @escaping (T) -> Bool,
                                  title: @escaping (T) -> String, pick: @escaping (T) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    let on = enabled(item)
                    Button { pick(item) } label: {
                        Text(title(item)).font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(item == current ? Color.accentColor.opacity(0.2) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .disabled(!on)
                    .foregroundStyle(on ? .primary : .secondary)  // 灰＝只降饱和，无解释字
                    .opacity(on ? 1 : 0.4)
                }
            }
        }
    }

    // 颜色行：9 色实心圆板放**自适应网格**，窄屏自动换行到多行、每色都可见可点（不挤在一 HStack 溢出）。
    // 昼夜禁色（白天禁白/夜间禁黑）→ 灰 + .disabled，仍显示色板（不写解释字）。
    private var colorRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 8)], spacing: 8) {
            ForEach(DrawingColorToken.allCases, id: \.self) { token in
                let on = DrawingStyleAvailability.colorEnabled(token, scheme: scheme)
                Button { commit { $0.colorToken = token } } label: {
                    Circle().fill(swatchColor(token))
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Color.accentColor,
                                                 lineWidth: token == style.colorToken ? 3 : 0))
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                }
                .disabled(!on)
                .opacity(on ? 1 : 0.3)
                .accessibilityLabel(colorLabel(token))
            }
        }
    }

    // token → SwiftUI Color（复用渲染层同一解析，昼夜一致）。
    private func swatchColor(_ token: DrawingColorToken) -> Color {
        let c = DrawingColorResolver.resolve(token, scheme: scheme)
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    private func subLabel(_ s: LineSubType) -> String { ["straight":"直线","ray":"射线","segment":"线段"][s.rawValue] ?? s.rawValue }
    private func styleLabel(_ s: LineStyle) -> String { s == .solid ? "实线" : "虚线" + String(s.rawValue.dropFirst(4)) }
    private func labelLabel(_ m: LabelMode) -> String { ["hidden":"隐藏","show":"显示","left":"左","right":"右"][m.rawValue] ?? m.rawValue }
    private func colorLabel(_ c: DrawingColorToken) -> String {
        ["red":"赤","orange":"橙","yellow":"黄","green":"绿","cyan":"青","blue":"蓝","purple":"紫","black":"黑","white":"白"][c.rawValue] ?? c.rawValue
    }
}
#endif

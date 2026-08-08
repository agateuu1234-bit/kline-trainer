// Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift
// 1a-iii 切片2 Task3：常驻样式面板的 5 组参数控件（由 DrawingStyleCard 平移改造）。
// 与旧卡片的三点差异：①线型/线样式/粗细改「画出来」的图标（spec §3）；②不再持有本地 @State 镜像，
// 改收调用方算好的派生值 `style`（1b-i PR-4：D49 选中即回显 + D65 置灰，见 style/enabled 字段注释）；
// ③无「完成」/遮罩关闭语义。
// 颜色组（切片3）收成「7 彩 + 1 线色」：无独立黑/白格、无禁色灰态；「线色」落 .black canonical，
// 经 DrawingColorResolver 自适应渲染（日纯黑/夜纯白），删 DrawingStyleAvailability.colorEnabled。
// 灰掉的项只降饱和 + .disabled，绝不写任何解释文案（母 spec §3 逐字）。
#if canImport(UIKit)
import SwiftUI

struct DrawingStyleParams: View {
    /// D49（1b-i PR-4）：**调用方算好的派生值** —— 有选中就是那条线的当前样式，无选中是
    /// 「下一条线的默认」。**绝不在本视图里拷成 @State**：常驻面板长期存活，任何第二份
    /// 样式状态都会与 `engine.drawings` 里的真值漂移（1a-iii 消灭过一次，别再引入）。
    let style: DrawingDefaultStyle
    /// D65「改样式可用」谓词的结果。视图**自己不判任何东西**（几何 / locked / 未来数据 /
    /// 工具已实现 / 复盘五个分量都在 `DrawingEditRouter.canEditStyle` 里）。
    /// 置灰只降饱和 + `.disabled`，**绝不写任何解释文案**（母 spec §3 逐字）。
    let enabled: Bool
    let scheme: AppColorScheme
    /// D49：写入路由由调用方提供（有选中 → 改那条线；无选中 → 改默认）。
    /// ⚠️ codex 整支 R3（本 PR 引入的回归修复）：传的是**变更意图**（mutation 闭包），不是完整对象。
    ///   `commit` **绝不能**再从 `style`（本视图渲染那一刻捕获的快照）出发拼下一个值——若两个控件
    ///   在 SwiftUI 完成重渲染之前先后触发，第二次会拿旧快照把第一次的改动 revert 掉（选中线路径
    ///   还会经 `drawingsRevision` 被 autosave 持久化，回退是真丢数据）。「现取当前真值 + 合并」
    ///   下放给调用方（`DrawingEditRouter.applyStyleMutation`/`applyDefaultStyleMutation`），
    ///   本视图只负责转发意图。
    let onChange: (@escaping (inout DrawingDefaultStyle) -> Void) -> Void

    private func commit(_ mutate: @escaping (inout DrawingDefaultStyle) -> Void) {
        onChange(mutate)   // ⚠️ 这里不许再读 `style`——见上方 onChange 注释。
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            group("线型") {
                options(LineSubType.allCases, current: style.lineSubType,
                        enabled: { DrawingStyleAvailability.horizontalLineSubTypeEnabled($0) },
                        label: { subTypeAccessibilityLabel($0) },
                        icon: { LineSubTypeIcon(subType: $0) }) { picked in
                    // 切线型即规整依赖的 labelMode（直线选『左』后切射线 → 回落 hidden），
                    // 杜绝「显示为灰却仍作默认被提交」的矛盾组合。规则单一真相在 DrawingStyleAvailability。
                    commit {
                        $0.lineSubType = picked
                        $0.labelMode = DrawingStyleAvailability.normalizedLabelMode(current: $0.labelMode,
                                                                                    lineSubType: picked)
                    }
                }
            }
            group("线样式") {
                options(LineStyle.allCases, current: style.lineStyle,
                        enabled: { _ in true },
                        label: { lineStyleAccessibilityLabel($0) },
                        icon: { LineStyleIcon(style: $0) }) { picked in commit { $0.lineStyle = picked } }
            }
            group("粗细") {
                options(Array(1...5), current: style.thickness,
                        enabled: { _ in true },
                        label: { "粗细\($0)" },
                        icon: { ThicknessIcon(thickness: $0) }) { picked in commit { $0.thickness = picked } }
            }
            group("颜色") { colorRow }
            group("标注") { labelModeRow }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)      // 灰＝只降饱和，无解释字（母 spec §3）
    }

    // 一组 = 组名 caption + 一排选项。caption 是组名，不是解释文案。
    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Text(title).font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    // 图标化选项排（线型/线样式/粗细共用）。可访问性标签挂在按钮上——图标无文字，但读屏仍可用。
    // enabled/label/icon/pick 必须 @escaping：它们被 ForEach 的**逃逸** ViewBuilder 闭包捕获，
    // 非逃逸参数在 Catalyst/iOS 会编译报错（host swift test 不编 #if canImport(UIKit) 体、只有真机门才炸）。
    private func options<T: Hashable, I: View>(_ items: [T], current: T,
                                               enabled: @escaping (T) -> Bool,
                                               label: @escaping (T) -> String,
                                               @ViewBuilder icon: @escaping (T) -> I,
                                               pick: @escaping (T) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                let on = enabled(item)
                Button { pick(item) } label: {
                    icon(item)
                        .padding(.horizontal, 4)
                        .frame(height: 26)
                        .background(item == current ? Color.accentColor.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(item == current ? Color.accentColor : Color.secondary.opacity(0.35),
                                    lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(!on)
                .foregroundStyle(on ? (item == current ? Color.accentColor : Color.primary) : Color.secondary)
                .opacity(on ? 1 : 0.4)          // 灰＝只降饱和，无解释字
                .accessibilityLabel(label(item))
            }
        }
    }

    // 颜色行（切片3）：7 彩 + 1「线色」。「线色」= .black canonical，随昼夜自动反色（日纯黑/夜纯白，
    // 经 DrawingColorResolver 自适应渲染）。无独立黑/白格、无禁色灰态——.black/.white 现恒可读。
    private static let chromaticColors: [DrawingColorToken] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple]

    private var colorRow: some View {
        HStack(spacing: 6) {
            ForEach(Self.chromaticColors, id: \.self) { token in
                colorSwatch(token, label: colorAccessibilityLabel(token))
            }
            // 「线色」格：canonical .black，圈内颜色 = resolver 自适应结果（日黑夜白），
            // 即「选它画出来是什么色，格子就显什么色」，所见即所得。
            colorSwatch(.black, label: "线色")
        }
    }

    private func colorSwatch(_ token: DrawingColorToken, label: String) -> some View {
        Button { commit { $0.colorToken = token } } label: {
            Circle().fill(swatchColor(token))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.accentColor,
                                         lineWidth: token == style.colorToken ? 2.5 : 0))
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // 标注组：spec §3 表格明确「维持现状」——本组是面板里唯一保留文字的组。
    private var labelModeRow: some View {
        HStack(spacing: 6) {
            ForEach(LabelMode.allCases, id: \.self) { mode in
                let on = DrawingStyleAvailability.horizontalLabelModeEnabled(mode, lineSubType: style.lineSubType)
                Button { commit { $0.labelMode = mode } } label: {
                    Text(labelModeText(mode)).font(.caption)
                        .padding(.horizontal, 8).frame(height: 26)
                        .background(mode == style.labelMode ? Color.accentColor.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(mode == style.labelMode ? Color.accentColor : Color.secondary.opacity(0.35),
                                    lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(!on)
                .foregroundStyle(on ? (mode == style.labelMode ? Color.accentColor : Color.primary) : Color.secondary)
                .opacity(on ? 1 : 0.4)
            }
        }
    }

    private func swatchColor(_ token: DrawingColorToken) -> Color {
        let c = DrawingColorResolver.resolve(token, scheme: scheme)
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    // 可访问性标签（读屏用）——这些字符串**不渲染成可见文字**（可见内容是图标），但必须**有语义**：
    // codex 计划-R14-F2：图标-only 控件若配 `线型一`/`线样式solid` 这类无意义标签，VoiceOver 用户
    // 无法分辨直线/射线、实线/各档虚线 → 会选错线型样式且无任何文字兜底。故用人话。
    private func subTypeAccessibilityLabel(_ s: LineSubType) -> String {
        ["straight": "直线", "ray": "射线", "segment": "线段"][s.rawValue] ?? s.rawValue
    }
    private func lineStyleAccessibilityLabel(_ s: LineStyle) -> String {
        ["solid": "实线", "dash1": "虚线1", "dash2": "虚线2",
         "dash3": "虚线3", "dash4": "虚线4"][s.rawValue] ?? s.rawValue
    }
    private func labelModeText(_ m: LabelMode) -> String {
        ["hidden": "隐藏", "show": "显示", "left": "左", "right": "右"][m.rawValue] ?? m.rawValue
    }
    private func colorAccessibilityLabel(_ c: DrawingColorToken) -> String {
        ["red": "赤", "orange": "橙", "yellow": "黄", "green": "绿", "cyan": "青",
         "blue": "蓝", "purple": "紫", "black": "黑", "white": "白"][c.rawValue] ?? c.rawValue
    }
}
#endif

// Sources/KlineTrainerContracts/Drawing/DrawingStyleIconSpec.swift
// 1a-iii 切片2 Task1：样式面板图标的**纯数值规格**，全部**派生自渲染层 HorizontalLineTool**。
//
// ⭐为什么不照设计 mock 另写一张表：`HorizontalLineTool` 已经持有真正画到 K 线上的 dash / 线宽
// （dashPattern(for:) / lineWidth(forThickness:)）。图标另起一张表 = 两份真相：面板里展示的样子会与
// 用户真正画出来的线不一致，且以后调渲染值时图标不会跟着变——而 spec §3 要的恰恰是「画出**真实**样子」。
// 故 dash **原样转发**；线宽因真实值（1.5→3.5pt）在 26pt 图标里五档几乎看不出差别，按**单一放大系数**
// 等比放大（保持与渲染层同序、严格单调，DrawingStyleIconSpecTests 钉死「派生关系」本身）。
//
// 放在非-View 的 enum 里 → host swift test 可直接覆盖（View 体在 host 上根本不编译，测不到）。
import CoreGraphics

public enum DrawingStyleIconSpec {

    /// 图标线宽相对**渲染层真实线宽**的放大系数。唯一的自由数值，改它即整排图标同步变化。
    /// 取 4.0：真实 1.5…3.5pt → 图标 6…14pt。实测 2.0（3…7pt）时相邻档间距仅 1pt，
    /// Catalyst 上抗锯齿把奇数 pt 线宽的边缘覆盖像素判进阈值以下、与相邻偶数档墨量打平
    /// （像素级证据：4pt/5pt 与 6pt/7pt 两两同墨）；4.0 令五档间距全部 ≥2pt 从而两两分辨。
    public static let iconWidthAmplification: CGFloat = 4.0

    /// 线样式图标的 dash pattern = **渲染层真值原样转发**（实线 = 空数组）。
    /// 不在此处做任何缩放/改写——面板画的必须就是用户会得到的。
    public static func dashPattern(for style: LineStyle) -> [CGFloat] {
        HorizontalLineTool.dashPattern(for: style)
    }

    /// 粗细档位 → 图标线宽 = 渲染层线宽 × 放大系数（画**真实粗细**的相对关系，不写数字）。
    /// 越界档位由 `HorizontalLineTool.lineWidth` 内部 clamp(1...5) 兜住 → 恒为正数，绝不产出不可见图标。
    public static func iconLineWidth(forThickness thickness: Int) -> CGFloat {
        HorizontalLineTool.lineWidth(forThickness: thickness) * iconWidthAmplification
    }
}

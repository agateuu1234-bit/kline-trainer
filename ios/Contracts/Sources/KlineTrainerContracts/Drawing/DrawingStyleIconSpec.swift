// Sources/KlineTrainerContracts/Drawing/DrawingStyleIconSpec.swift
// 1a-iii 切片2 Task1：样式面板图标的**纯数值规格**，全部**派生自渲染层 HorizontalLineTool**。
//
// ⭐为什么不照设计 mock 另写一张表：`HorizontalLineTool` 已经持有真正画到 K 线上的 dash / 线宽
// （dashPattern(for:) / lineWidth(forThickness:)）。图标另起一张表 = 两份真相：面板里展示的样子会与
// 用户真正画出来的线不一致，且以后调渲染值时图标不会跟着变——而 spec §3 要的恰恰是「画出**真实**样子」。
// 故 dash 与线宽**原样转发，逐字相等**——真机验收（iPhone 15 Pro Max @3x）用户明确指出「图示里的线的
// 粗细，就是实际中画到 K 线图上的粗细，这个要一致」：此前按放大系数等比放大图标线宽（6…14pt）与真实
// 1.5…3.5pt 不符 = 图标在骗人。可辨性改由渲染 scale（@3x）与图标画布尺寸保证，不再靠线宽放大。
//
// 放在非-View 的 enum 里 → host swift test 可直接覆盖（View 体在 host 上根本不编译，测不到）。
import CoreGraphics

public enum DrawingStyleIconSpec {

    /// 线样式图标的 dash pattern = **渲染层真值原样转发**（实线 = 空数组）。
    /// 不在此处做任何缩放/改写——面板画的必须就是用户会得到的。
    public static func dashPattern(for style: LineStyle) -> [CGFloat] {
        HorizontalLineTool.dashPattern(for: style)
    }

    /// 粗细档位 → 图标线宽 = **渲染层线宽，逐字相等**（图标就是用户会画出来的粗细，不做任何放大）。
    /// 越界档位由 `HorizontalLineTool.lineWidth` 内部 clamp(1...5) 兜住 → 恒为正数，绝不产出不可见图标。
    public static func iconLineWidth(forThickness thickness: Int) -> CGFloat {
        HorizontalLineTool.lineWidth(forThickness: thickness)
    }
}

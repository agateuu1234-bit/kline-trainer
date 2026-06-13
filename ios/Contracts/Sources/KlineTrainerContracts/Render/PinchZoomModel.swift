// Kline Trainer Swift Contracts — 顺位 3 Pinch 缩放纯数学（RFC §4.4d）
// Design: docs/superpowers/specs/2026-06-13-wave3-pr3-pinch-zoom-design.md D3/D4
//
// 平台无关：host 全量单测。clamp/灵敏度常量集中此处（runbook 实测不适即一行改，D4）。

import CoreGraphics

public enum PinchZoomModel {
    /// clamp 边界（D4）：默认 80 居中偏左；240 = 3×默认（step≈3pt 密集可辨），20 = 默认÷4（step≈37pt 粗看形态）。
    public static let minVisibleCount = 20
    public static let maxVisibleCount = 240

    /// 目标可见根数：clamp(round(base / effectiveScale), MIN, MAX)。
    /// effectiveScale = scale / scaleAtBegan（锁定点归一，消 ±2% 死区，D4/R1-L1）；>1 张开 → 根数变少 → 放大。
    /// **前置条件**：effectiveScale 有限且 > 0（engine applyPinch 守卫，R2-L1——防御不在本模型）。
    /// clamp 在 CGFloat 域先做再转 Int，防极端 scale 下 Int 转换溢出。
    public static func targetVisibleCount(base: Int, effectiveScale: CGFloat) -> Int {
        let raw = (CGFloat(base) / effectiveScale).rounded(.toNearestOrAwayFromZero)
        let clamped = min(max(raw, CGFloat(minVisibleCount)), CGFloat(maxVisibleCount))
        return Int(clamped)
    }

    /// focus 不变量（D3）：解新 offset 使 pinch 中点 fx 下连续 candle 索引不变。
    /// before 端用**实际渲染视口**（makeViewport 输出，含 clamp/边缘饱和后的值——用户看到什么就锚什么）；
    /// after 端用连续模型：
    ///   u_before = startIndex + (fx − pixelShift) / candleStep
    ///   offset′  = fx − (u_before − currentIdx + N′ − 1) · (W / N′)
    /// 返回值不二次 clamp：渲染端 makeViewport 边界饱和兜底（同 pan 先例；饱和 > focus 优先级）。
    /// **前置条件**：newCount ≥ 1、mainWidth > 0（engine bounds-zero no-op 已挡）。
    public static func rezoomOffset(viewport: ChartViewport, currentIdx: Int,
                                    focusX: CGFloat, newCount: Int,
                                    mainWidth: CGFloat) -> CGFloat {
        let uBefore = CGFloat(viewport.startIndex)
            + (focusX - viewport.pixelShift) / viewport.geometry.candleStep
        let newStep = mainWidth / CGFloat(newCount)
        return focusX - (uBefore - CGFloat(currentIdx) + CGFloat(newCount) - 1) * newStep
    }
}

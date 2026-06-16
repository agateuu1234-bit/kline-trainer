// RubberBand.swift
import CoreGraphics

/// iOS UIScrollView 同款橡皮筋阻尼（拖拽期跟手过界压缩）。平台无关纯函数。
/// f(x) = (1 − 1/(x·c/d + 1))·d，c=0.55。性质：f(0)=0、单调增、f(x)<x(x>0)、渐近上界 d、f'(0)=c。
enum RubberBand {
    static let c: CGFloat = 0.55

    /// - Parameters:
    ///   - over: 越界距离（应 ≥0；<0 视作 0）。
    ///   - dimension: 主图宽（应 >0；≤0 退化为不阻尼，直接返 over，由上层 floor 兜底）。
    static func damp(over: CGFloat, dimension: CGFloat) -> CGFloat {
        guard over > 0 else { return 0 }
        guard dimension > 0 else { return over }       // 非有限/退化几何：不阻尼
        return (1 - 1 / (over * c / dimension + 1)) * dimension
    }
}

// Kline Trainer Swift Contracts — C1a Geometry
// Spec: kline_trainer_modules_v1.4.md §C1a + kline_trainer_plan_v1.5.md §3
// Design doc: docs/superpowers/specs/2026-04-30-c1a-geometry-design.md

import Foundation
import CoreGraphics

// MARK: - 几何 + 面板

public struct ChartGeometry: Equatable, Sendable {
    public let candleStep: CGFloat
    public let candleWidth: CGFloat
    public let gap: CGFloat

    public init(candleStep: CGFloat, candleWidth: CGFloat, gap: CGFloat) {
        self.candleStep = candleStep
        self.candleWidth = candleWidth
        self.gap = gap
    }
}

public struct ChartPanelFrames: Equatable, Sendable {
    public let mainChart: CGRect
    public let volumeChart: CGRect
    public let macdChart: CGRect

    public init(mainChart: CGRect, volumeChart: CGRect, macdChart: CGRect) {
        self.mainChart = mainChart
        self.volumeChart = volumeChart
        self.macdChart = macdChart
    }

    /// 60/15/25 纵向堆叠（modules L884-886）
    public static func split(in rect: CGRect) -> ChartPanelFrames {
        let mainH = rect.height * 0.60
        let volH = rect.height * 0.15
        let macdH = rect.height * 0.25
        let main = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: mainH)
        let vol = CGRect(x: rect.minX, y: rect.minY + mainH, width: rect.width, height: volH)
        let macd = CGRect(x: rect.minX, y: rect.minY + mainH + volH, width: rect.width, height: macdH)
        return ChartPanelFrames(mainChart: main, volumeChart: vol, macdChart: macd)
    }
}

// MARK: - 非退化值域（副图 mapper 用）

public struct NonDegenerateRange: Equatable, Sendable {
    public let lower: Double
    public let upper: Double                    // 强制 upper > lower（无 public init，外部只能走 .make）

    // memberwise init 不显式声明 → Swift 合成 internal init；外部只能 .make
    // 同 package test 可直接 internal init 验证 Equatable / span / 边界

    /// modules L924-925 字面：empty / 全等值都返回可用 range
    public static func make(values: [Double],
                            fallback: ClosedRange<Double> = 0.0...1.0,
                            paddingRatio: Double = 0.02) -> NonDegenerateRange {
        guard let minV = values.min(), let maxV = values.max() else {
            return NonDegenerateRange(lower: fallback.lowerBound, upper: fallback.upperBound)
        }
        if minV == maxV {
            let pad = Swift.max(abs(minV) * paddingRatio, 1e-6)
            return NonDegenerateRange(lower: minV - pad, upper: maxV + pad)
        }
        let span = maxV - minV
        let pad = span * paddingRatio
        return NonDegenerateRange(lower: minV - pad, upper: maxV + pad)
    }

    public var span: Double { upper - lower }
}

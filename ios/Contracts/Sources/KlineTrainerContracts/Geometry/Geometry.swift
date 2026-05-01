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

    /// modules L924-925 字面：empty / 全等值都返回可用 range
    /// 退化 fallback (lower==upper) 走 single-value padding 路径，保 span > 0 不变量
    public static func make(values: [Double],
                            fallback: ClosedRange<Double> = 0.0...1.0,
                            paddingRatio: Double = 0.02) -> NonDegenerateRange {
        guard let minV = values.min(), let maxV = values.max() else {
            let lo = fallback.lowerBound
            let hi = fallback.upperBound
            if lo == hi {
                let pad = max(abs(lo) * paddingRatio, 1e-6)
                return NonDegenerateRange(lower: lo - pad, upper: hi + pad)
            }
            return NonDegenerateRange(lower: lo, upper: hi)
        }
        if minV == maxV {
            let pad = max(abs(minV) * paddingRatio, 1e-6)
            return NonDegenerateRange(lower: minV - pad, upper: maxV + pad)
        }
        let span = maxV - minV
        let pad = span * paddingRatio
        return NonDegenerateRange(lower: minV - pad, upper: maxV + pad)
    }

    public var span: Double { upper - lower }
}

// MARK: - 价格值域

public struct PriceRange: Equatable, Sendable {
    public let min: Double
    public let max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }

    /// plan §3 L142-161 字面：含 BOLL / MA66 + 5% 上下扩展
    public static func calculate(from candles: ArraySlice<KLineCandle>) -> PriceRange {
        guard !candles.isEmpty else { return PriceRange(min: 0, max: 1) }
        var lo = candles.map(\.low).min()!
        var hi = candles.map(\.high).max()!
        for c in candles {
            if let bu = c.bollUpper { hi = Swift.max(hi, bu) }
            if let bl = c.bollLower { lo = Swift.min(lo, bl) }
            if let ma = c.ma66 { hi = Swift.max(hi, ma); lo = Swift.min(lo, ma) }
        }
        lo *= 0.95
        hi *= 1.05
        return PriceRange(min: lo, max: hi)
    }
}

// MARK: - 视口

public struct ChartViewport: Equatable, Sendable {
    public let startIndex: Int
    public let visibleCount: Int
    public let pixelShift: CGFloat
    public let geometry: ChartGeometry
    public let priceRange: PriceRange
    public let mainChartFrame: CGRect

    public init(startIndex: Int, visibleCount: Int, pixelShift: CGFloat,
                geometry: ChartGeometry, priceRange: PriceRange, mainChartFrame: CGRect) {
        self.startIndex = startIndex
        self.visibleCount = visibleCount
        self.pixelShift = pixelShift
        self.geometry = geometry
        self.priceRange = priceRange
        self.mainChartFrame = mainChartFrame
    }
}

// MARK: - 坐标映射

public struct CoordinateMapper: Equatable, Sendable {
    public let viewport: ChartViewport
    public let displayScale: CGFloat

    public init(viewport: ChartViewport, displayScale: CGFloat) {
        self.viewport = viewport
        self.displayScale = displayScale
    }

    /// pixelShift 符号契约：pixelShift > 0 = candles 向右平移 pixelShift 像素（亚像素 pan offset）
    /// indexToX 加 pixelShift；xToIndex 减 pixelShift（symmetric round-trip）
    public func indexToX(_ index: Int) -> CGFloat {
        let raw = CGFloat(index - viewport.startIndex) * viewport.geometry.candleStep + viewport.pixelShift
        return (raw * displayScale).rounded(.toNearestOrAwayFromZero) / displayScale
    }

    public func priceToY(_ price: Double) -> CGFloat {
        let frame = viewport.mainChartFrame
        let span = viewport.priceRange.max - viewport.priceRange.min
        let ratio = (price - viewport.priceRange.min) / span
        let raw = frame.maxY - CGFloat(ratio) * frame.height
        return (raw * displayScale).rounded(.toNearestOrAwayFromZero) / displayScale
    }

    /// verify-and-correct：先算 approx，再用 rounded indexToX 做 boundary classifier 修正±1。
    /// 保 indexToX(xToIndex(indexToX(i))) round-trip 恒等，独立于 fractional pixelShift / candleStep / displayScale。
    public func xToIndex(_ x: CGFloat) -> Int {
        let logical = x - viewport.pixelShift
        let approx = viewport.startIndex + Int((logical / viewport.geometry.candleStep).rounded(.down))
        if indexToX(approx + 1) <= x {
            return approx + 1
        }
        if indexToX(approx) > x {
            return approx - 1
        }
        return approx
    }

    public func yToPrice(_ y: CGFloat) -> Double {
        let frame = viewport.mainChartFrame
        let ratio = Double((frame.maxY - y) / frame.height)
        return viewport.priceRange.min + ratio * (viewport.priceRange.max - viewport.priceRange.min)
    }
}

public struct IndicatorMapper: Equatable, Sendable {
    public let frame: CGRect
    public let valueRange: NonDegenerateRange
    public let geometry: ChartGeometry
    public let viewport: ChartViewport
    public let displayScale: CGFloat

    public init(frame: CGRect, valueRange: NonDegenerateRange,
                geometry: ChartGeometry, viewport: ChartViewport, displayScale: CGFloat) {
        self.frame = frame
        self.valueRange = valueRange
        self.geometry = geometry
        self.viewport = viewport
        self.displayScale = displayScale
    }

    /// pixelShift 与 CoordinateMapper 同符号契约：通过 viewport.pixelShift 平移
    public func indexToX(_ index: Int) -> CGFloat {
        let raw = CGFloat(index - viewport.startIndex) * geometry.candleStep + viewport.pixelShift
        return (raw * displayScale).rounded(.toNearestOrAwayFromZero) / displayScale
    }

    public func valueToY(_ value: Double) -> CGFloat {
        let ratio = (value - valueRange.lower) / valueRange.span    // span > 0 when constructed via .make (外部 caller 契约 — 见 design doc §Residuals #9)
        let raw = frame.maxY - CGFloat(ratio) * frame.height
        return (raw * displayScale).rounded(.toNearestOrAwayFromZero) / displayScale
    }
}

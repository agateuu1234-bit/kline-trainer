// Kline Trainer Swift Contracts — C5/顺位5 CrosshairLayout host tests
// Spec: docs/superpowers/specs/2026-06-13-wave3-pr5-crosshair-snap-hud-design.md
// 平台无关：只 import CoreGraphics（host swift test 直跑，不需 Catalyst）。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

private func mc(_ idx: Int, datetime: Int64, close: Double = 10) -> KLineCandle {
    KLineCandle(period: .m3, datetime: datetime,
                open: close, high: close + 1, low: close - 1, close: close,
                volume: 100, amount: nil, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: nil, macdDea: nil, macdBar: nil,
                globalIndex: idx, endGlobalIndex: idx)
}

/// 连续蜡烛数组（globalIndex = 0..<count）。slice 用 `candles[startIndex..<end]` 取，保 ArraySlice.startIndex == viewport.startIndex。
private func makeCandles(count: Int,
                        startDatetime: Int64 = 1735689600,   // 2025-01-01 00:00 UTC = 08:00 北京
                        stepSeconds: Int64 = 180) -> [KLineCandle] {
    (0..<count).map { i in mc(i, datetime: startDatetime + Int64(i) * stepSeconds) }
}

/// 灵活 mapper 构造（显式 startIndex/visibleCount/candleStep/pixelShift/displayScale）。
/// candleWidth/gap 沿用 0.7/0.3 比例（与 RenderStateBuilder 一致），但吸附只用 candleStep/pixelShift。
private func makeMapper(startIndex: Int = 0, visibleCount: Int = 10,
                       candleStep: CGFloat = 10, pixelShift: CGFloat = 0,
                       displayScale: CGFloat = 2,
                       frameWidth: CGFloat = 1000, frameHeight: CGFloat = 600) -> CoordinateMapper {
    let geom = ChartGeometry(candleStep: candleStep,
                             candleWidth: candleStep * 0.7, gap: candleStep * 0.3)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: visibleCount,
                           pixelShift: pixelShift, geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100),
                           mainChartFrame: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    return CoordinateMapper(viewport: vp, displayScale: displayScale)
}

@Suite("CrosshairLayout.snappedCandleIndex 吸附核心")
struct SnappedIndexTests {

    // 矩阵 1：nearest-center round 跳变（candleStep=10, scale=2 → 中心 = i*10）
    @Test("过中点前吸附较小 candle、过后吸附较大 candle")
    func roundJump() {
        let m = makeMapper(visibleCount: 10)              // 中心 0,10,...,90
        let c = makeCandles(count: 10)[0..<10]
        #expect(CrosshairLayout.snappedCandleIndex(at: 14, mapper: m, candles: c) == 1)  // 14<15 → idx1
        #expect(CrosshairLayout.snappedCandleIndex(at: 16, mapper: m, candles: c) == 2)  // 16>15 → idx2
    }

    // 矩阵 1b：恰中点精确 IEEE tie（logical>0）→ 取较小 index；seed 会取较大（2），tie-break 必须覆盖为 1
    @Test("恰落两中心中点（15.0，|10−15|==|20−15|）→ tie-break 取较小 index（非 seed 的较大）")
    func exactMidpointTieTakesSmaller() {
        let m = makeMapper(visibleCount: 10)              // indexToX(1)=10.0, indexToX(2)=20.0
        let c = makeCandles(count: 10)[0..<10]
        // seed = round((15−0)/10)=round(1.5)= 2（away-from-zero，较大）；两侧 {1,2} 距离均 5.0 → tie 取 1
        #expect(CrosshairLayout.snappedCandleIndex(at: 15.0, mapper: m, candles: c) == 1)
    }

    // 矩阵 3：count < target → clamp 到最末可见（viewport.visibleCount = slice.count = 5）
    @Test("右侧 padding 空白区长按 → 吸附最末可见蜡烛（clamp 右）")
    func clampRight() {
        let m = makeMapper(visibleCount: 5)               // 仅中心 0,10,20,30,40；右侧空白
        let c = makeCandles(count: 5)[0..<5]
        #expect(CrosshairLayout.snappedCandleIndex(at: 500, mapper: m, candles: c) == 4)  // clamp → 末根
    }

    // 矩阵 4：logical<0（point.x 在首中心左侧，pixelShift=30）→ clamp 到 startIndex
    @Test("首蜡烛中心左侧长按 → clamp 到第一可见蜡烛（clamp 左）")
    func clampLeft() {
        let m = makeMapper(visibleCount: 10, pixelShift: 30)  // indexToX(0)=30
        let c = makeCandles(count: 10)[0..<10]
        #expect(CrosshairLayout.snappedCandleIndex(at: 5, mapper: m, candles: c) == 0)
    }

    // 矩阵 11：结构 bounds 不变量（含 startIndex 偏移的绝对索引）
    @Test("任意 in-frame point → candles.startIndex <= snappedIndex < candles.endIndex")
    func boundsInvariant() {
        // 偏移切片：startIndex=5，候选索引 [5,15)
        let m = makeMapper(startIndex: 5, visibleCount: 10)   // indexToX(i)=(i−5)*10
        let c = makeCandles(count: 15)[5..<15]
        for x: CGFloat in [0, 5, 95, 300, 750, 999] {
            let idx = CrosshairLayout.snappedCandleIndex(at: x, mapper: m, candles: c)
            #expect(idx >= c.startIndex && idx < c.endIndex)
        }
    }
}

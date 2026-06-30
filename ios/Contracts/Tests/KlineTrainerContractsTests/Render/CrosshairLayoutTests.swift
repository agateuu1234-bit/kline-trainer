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

@Suite("CrosshairLayout.resolve 聚合 + HUD")
struct ResolveTests {

    // 矩阵 2：snappedX == indexToX(snappedIndex)，竖线两端点同 x（mirror-the-mapper）
    @Test("竖线 x = indexToX(snappedIndex)（两端点一致，经 mapper 推导）")
    func verticalSnapsToCenter() {
        let m = makeMapper(visibleCount: 10)
        let c = makeCandles(count: 10)[0..<10]
        let r = CrosshairLayout.resolve(at: CGPoint(x: 23, y: 300), mapper: m, candles: c)
        #expect(r != nil)
        guard let r else { return }
        let snappedX = m.indexToX(r.snappedIndex)
        #expect(r.lines.vertical.from.x == snappedX)
        #expect(r.lines.vertical.to.x == snappedX)
        #expect(r.snappedIndex == 2)                       // 23 → 中心 20（idx2）
        // 横线自由 Y：跨 frame 全宽、y == point.y
        #expect(r.lines.horizontal.from == CGPoint(x: 0, y: 300))
        #expect(r.lines.horizontal.to == CGPoint(x: 1000, y: 300))
    }

    // 矩阵 5：价格 label 自由 Y（吸附不影响）+ 镜像 yToPrice
    @Test("价格 label 文本恒 = yToPrice(point.y)，与 point.x（吸附）无关 + 镜像 mapper")
    func priceLabelFreeY() {
        let m = makeMapper(visibleCount: 10)
        let c = makeCandles(count: 10)[0..<10]
        for x: CGFloat in [3, 23, 47, 500] {               // 变 x（吸附不同蜡烛）
            let r = CrosshairLayout.resolve(at: CGPoint(x: x, y: 300), mapper: m, candles: c)
            #expect(r?.priceLabel.text == String(format: "%.2f", m.yToPrice(300)))  // y=300 → 50.00
        }
        for y: CGFloat in [50, 150, 450, 550] {            // 镜像 yToPrice
            let r = CrosshairLayout.resolve(at: CGPoint(x: 100, y: y), mapper: m, candles: c)
            #expect(r?.priceLabel.text == String(format: "%.2f", m.yToPrice(y)))
        }
        // 价签左贴 frame.minX、垂直居中 point.y
        let r = CrosshairLayout.resolve(at: CGPoint(x: 100, y: 300), mapper: m, candles: c)
        #expect(r?.priceLabel.rect.minX == 0)
        #expect(r?.priceLabel.rect.midY == 300)
    }

    // 矩阵 6：时间 label 吸附 X + 吸附蜡烛 datetime（mirror-the-mapper）
    @Test("时间 label midX = indexToX(snappedIndex)（非原始 x）+ 文本 = 吸附蜡烛 datetime")
    func timeLabelSnapsX() {
        let m = makeMapper(visibleCount: 3)
        let candles = [mc(0, datetime: 1735781400),        // 2025-01-02 09:30 北京
                       mc(1, datetime: 1735781580),        // 09:33
                       mc(2, datetime: 1735781760)]        // 09:36
        let c = candles[0..<3]
        // point.x=16 → 吸附 idx2（中心 20，16>15）；时签 midX == indexToX(2)=20
        let r = CrosshairLayout.resolve(at: CGPoint(x: 16, y: 300), mapper: m, candles: c)
        #expect(r != nil)
        #expect(r?.snappedIndex == 2)
        #expect(r?.timeLabel.rect.midX == m.indexToX(2))
        #expect(r?.timeLabel.text == "2025-01-02 09:36")
        #expect(r?.timeLabel.rect.maxY == 600)
    }

    // 矩阵 7：frame 外 → nil（4 角半开区间）+ point==nil → nil
    @Test("frame 外 point → nil（半开 [minX,maxX)×[minY,maxY)）；nil point → nil")
    func outsideFrameNil() {
        let m = makeMapper(visibleCount: 10)
        let c = makeCandles(count: 10)[0..<10]
        #expect(CrosshairLayout.resolve(at: nil, mapper: m, candles: c) == nil)
        #expect(CrosshairLayout.resolve(at: CGPoint(x: 0, y: 0), mapper: m, candles: c) != nil)      // 左上 ∈
        #expect(CrosshairLayout.resolve(at: CGPoint(x: 1000, y: 0), mapper: m, candles: c) == nil)   // 右上 ∉
        #expect(CrosshairLayout.resolve(at: CGPoint(x: 0, y: 600), mapper: m, candles: c) == nil)    // 左下 ∉
        #expect(CrosshairLayout.resolve(at: CGPoint(x: 1000, y: 600), mapper: m, candles: c) == nil) // 右下 ∉
    }

    // 矩阵 8：post-pinch demonstrator（同 x，不同 candleStep → 不同蜡烛中心，证 candleStep 被消费）。
    // displayScale=3 = 真实非默认 scale；竖线 x 期望经 mapper.indexToX 推导（mirror-the-mapper，对像素取整稳健）。
    // 注：本向量 x=300 恰落整数中心（300/12.5=24、300/25=12），indexToX 取整无偏移；非 vacuous 由 ==24/==12/!= 索引断言保证。
    @Test("post-pinch：同 point.x 在 zoom 前后吸附到不同蜡烛中心（消费 candleStep 变化）")
    func postPinchSnap() {
        let c = makeCandles(count: 80)
        // 默认 viewport：visibleCount=80, candleStep=1000/80=12.5
        let mDefault = makeMapper(visibleCount: 80, candleStep: 1000.0 / 80.0,
                                  displayScale: 3, frameWidth: 1000)
        // pinch 后 viewport：visibleCount=40, candleStep=1000/40=25
        let mPinch = makeMapper(visibleCount: 40, candleStep: 1000.0 / 40.0,
                                displayScale: 3, frameWidth: 1000)
        let idxDefault = CrosshairLayout.snappedCandleIndex(at: 300, mapper: mDefault, candles: c[0..<80])
        let idxPinch = CrosshairLayout.snappedCandleIndex(at: 300, mapper: mPinch, candles: c[0..<40])
        #expect(idxDefault == 24)                          // round(300/12.5)=24
        #expect(idxPinch == 12)                            // round(300/25)=12
        #expect(idxDefault != idxPinch)                    // mutation：固定 80 分母则二者相等 → 失败
        // resolve 的竖线 x 用各自 mapper 的 indexToX（mirror）
        let r = CrosshairLayout.resolve(at: CGPoint(x: 300, y: 300), mapper: mPinch, candles: c[0..<40])
        #expect(r?.lines.vertical.from.x == mPinch.indexToX(12))
    }

    // 矩阵 9：locale 中性时间格式
    @Test("时间格式跨设备 locale 稳定（en_US_POSIX + UTC+8）")
    func localeNeutral() {
        let m = makeMapper(visibleCount: 1)
        let c = [mc(0, datetime: 1735689600)][0..<1]       // 2025-01-01 00:00 UTC = 08:00 北京
        let r = CrosshairLayout.resolve(at: CGPoint(x: 0, y: 300), mapper: m, candles: c)
        #expect(r?.timeLabel.text == "2025-01-01 08:00")
    }

    // 矩阵 10：空切片守卫（visibleCount==0 + 非 .zero frame + in-frame point）→ nil（不崩）
    @Test("空切片 → resolve nil（先于 clamp，不触发窗口反转崩溃）")
    func emptyCandlesNil() {
        let m = makeMapper(visibleCount: 0)                // 非 .zero frame
        let empty = makeCandles(count: 0)[0..<0]
        #expect(CrosshairLayout.resolve(at: CGPoint(x: 100, y: 300), mapper: m, candles: empty) == nil)
    }
}

private func makeFrames(mainTop: CGFloat = 0, mainH: CGFloat = 360,
                       volH: CGFloat = 90, macdH: CGFloat = 150,
                       width: CGFloat = 1000) -> ChartPanelFrames {
    let main = CGRect(x: 0, y: mainTop, width: width, height: mainH)
    let vol = CGRect(x: 0, y: mainTop + mainH, width: width, height: volH)
    let macd = CGRect(x: 0, y: mainTop + mainH + volH, width: width, height: macdH)
    return ChartPanelFrames(mainChart: main, volumeChart: vol, macdChart: macd)
}

@Suite("CrosshairLayout frames 贯穿整 panel")
struct CrosshairWholePanelTests {

    @Test("传 frames → 竖线从 mainChart.minY 到 macdChart.maxY（贯穿三子图）")
    func verticalSpansWholePanel() {
        let m = makeMapper(visibleCount: 10, frameHeight: 360)
        let c = makeCandles(count: 10)[0..<10]
        let frames = makeFrames()                                 // macdChart.maxY = 600
        let r = CrosshairLayout.resolve(at: CGPoint(x: 35, y: 100), mapper: m, candles: c, frames: frames)
        #expect(r != nil)
        #expect(r!.lines.vertical.from.y == 0)                    // mainChart.minY
        #expect(r!.lines.vertical.to.y == 600)                    // macdChart.maxY
    }

    @Test("传 frames → 时签底贴 macdChart.maxY")
    func timeLabelAtPanelBottom() {
        let m = makeMapper(visibleCount: 10, frameHeight: 360)
        let c = makeCandles(count: 10)[0..<10]
        let frames = makeFrames()
        let r = CrosshairLayout.resolve(at: CGPoint(x: 35, y: 100), mapper: m, candles: c, frames: frames)
        #expect(r!.timeLabel.rect.maxY == 600)
    }

    @Test("不传 frames（nil）→ 保持现状（竖线/时签限 mainChartFrame）")
    func nilFramesKeepsLegacy() {
        let m = makeMapper(visibleCount: 10, frameHeight: 360)
        let c = makeCandles(count: 10)[0..<10]
        let r = CrosshairLayout.resolve(at: CGPoint(x: 35, y: 100), mapper: m, candles: c)
        #expect(r!.lines.vertical.to.y == 360)
        #expect(r!.timeLabel.rect.maxY == 360)
    }

    @Test("价标在左缘：priceLabel.rect.minX == mainChartFrame.minX")
    func priceLabelOnLeftEdge() {
        let m = makeMapper(visibleCount: 10, frameHeight: 360)
        let c = makeCandles(count: 10)[0..<10]
        let r = CrosshairLayout.resolve(at: CGPoint(x: 35, y: 100), mapper: m, candles: c, frames: makeFrames())
        #expect(r!.priceLabel.rect.minX == 0)
        #expect(r!.priceLabel.rect.midY == 100)
    }
}

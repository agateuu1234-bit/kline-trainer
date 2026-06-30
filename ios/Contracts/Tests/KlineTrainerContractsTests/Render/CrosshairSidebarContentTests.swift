// ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairSidebarContentTests.swift
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

private func candle(period: Period = .m60,
                    datetime: Int64 = 1_711_605_600,   // 2024-03-28 14:00 UTC+8
                    open: Double = 1672.40, high: Double = 1689.00,
                    low: Double = 1668.20, close: Double = 1683.50,
                    volume: Int64 = 12_840, amount: Double? = 1683.0 * 12_840) -> KLineCandle {
    KLineCandle(period: period, datetime: datetime,
                open: open, high: high, low: low, close: close,
                volume: volume, amount: amount, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: nil, macdDea: nil, macdBar: nil,
                globalIndex: 0, endGlobalIndex: 0)
}

@Suite("CrosshairSidebarContent 装配")
struct CrosshairSidebarContentTests {

    // 停靠：snappedX > 主图中点 → 靠左；否则 → 靠右（含恰中点 = 右）
    @Test("光标偏右(snappedX > midX) → dock = left")
    func dockLeftWhenRight() {
        let c = CrosshairSidebarContent.make(candle: candle(), previousClose: 1672.40,
                                             cursorPrice: 1681.20, snappedX: 700, mainChartMidX: 500)
        #expect(c.dock == .left)
    }

    @Test("光标偏左/恰中点(snappedX <= midX) → dock = right")
    func dockRightWhenLeftOrCenter() {
        let left = CrosshairSidebarContent.make(candle: candle(), previousClose: 1672.40,
                                                cursorPrice: 1660, snappedX: 300, mainChartMidX: 500)
        let center = CrosshairSidebarContent.make(candle: candle(), previousClose: 1672.40,
                                                  cursorPrice: 1660, snappedX: 500, mainChartMidX: 500)
        #expect(left.dock == .right)
        #expect(center.dock == .right)   // 恰中点归右（确定性）
    }

    // 光标价颜色：vs prevClose（> 红、< 绿、== 白）
    @Test("光标价 vs 前收：高=up、低=down、平=flat")
    func cursorPriceColor() {
        let up = CrosshairSidebarContent.make(candle: candle(), previousClose: 1680,
                                              cursorPrice: 1690, snappedX: 100, mainChartMidX: 500)
        let dn = CrosshairSidebarContent.make(candle: candle(), previousClose: 1680,
                                              cursorPrice: 1670, snappedX: 100, mainChartMidX: 500)
        let fl = CrosshairSidebarContent.make(candle: candle(), previousClose: 1680,
                                              cursorPrice: 1680, snappedX: 100, mainChartMidX: 500)
        #expect(up.cursorPriceColor == .up)
        #expect(dn.cursorPriceColor == .down)
        #expect(fl.cursorPriceColor == .flat)
    }

    // 开/高/低/收 全按方向 vs 前收上色（红高/绿低/白平）——主流对齐，开高低不再 neutral
    @Test("开/高/低/收 全 vs 前收上色")
    func ohlcColors() {
        // candle(): open 1672.40 / high 1689.00 / low 1668.20 / close 1683.50；前收 1672.40
        let c = CrosshairSidebarContent.make(candle: candle(close: 1683.50), previousClose: 1672.40,
                                             cursorPrice: 1683.5, snappedX: 100, mainChartMidX: 500)
        #expect(c.rows.first { $0.label == "收" }?.color == .up)    // 1683.5 > 1672.4 红
        #expect(c.rows.first { $0.label == "开" }?.color == .flat)  // 1672.4 == 1672.4 持平白
        #expect(c.rows.first { $0.label == "高" }?.color == .up)    // 1689.0 > 1672.4 红
        #expect(c.rows.first { $0.label == "低" }?.color == .down)  // 1668.2 < 1672.4 绿
    }

    // 涨跌 / 涨跌幅 派生 + 颜色
    @Test("涨跌额/涨跌幅 = 收 − 前收 / ÷ 前收，红涨")
    func changeDerivation() {
        let c = CrosshairSidebarContent.make(candle: candle(close: 1683.50), previousClose: 1672.40,
                                             cursorPrice: 1683.5, snappedX: 100, mainChartMidX: 500)
        let chg = c.rows.first { $0.label == "涨跌" }
        let pct = c.rows.first { $0.label == "涨跌幅" }
        #expect(chg?.value == "+11.10")
        #expect(chg?.color == .up)
        #expect(pct?.value == "+0.66%")     // 11.10/1672.40 = 0.6637% → +0.66%
        #expect(pct?.color == .up)
    }

    // 首根无 prevClose → 涨跌「—」+ flat
    @Test("首根无 prevClose → 涨跌『—』中性白")
    func firstCandleNoPrev() {
        let c = CrosshairSidebarContent.make(candle: candle(), previousClose: nil,
                                             cursorPrice: 1683.5, snappedX: 100, mainChartMidX: 500)
        let chg = c.rows.first { $0.label == "涨跌" }
        #expect(chg?.value == "—")
        #expect(chg?.color == .flat)
        #expect(c.cursorPriceColor == .flat)   // 无基准 → 光标价也中性
    }

    // 均价单位自检：落 [低,高] → 显示；越界 → 隐藏
    @Test("均价 ∈ [低,高] 显示")
    func avgPriceInRange() {
        // amount = 1679.8 * 12840 → 均价 = 1679.8 ∈ [1668.2,1689]
        let c = CrosshairSidebarContent.make(candle: candle(amount: 1679.8 * 12_840),
                                             previousClose: 1672.40, cursorPrice: 1683.5,
                                             snappedX: 100, mainChartMidX: 500)
        let avg = c.rows.first { $0.label == "均价" }
        #expect(avg?.value == "1679.80")
        #expect(avg?.color == .up)   // 均价 1679.8 > 前收 1672.4 → 红（价格字段按方向上色）
    }

    @Test("均价越界([低,高]外, 如手/元差100倍) → 隐藏该行")
    func avgPriceOutOfRangeHidden() {
        // volume 当「手」时 amount/volume = 100× 价 → 越界
        let c = CrosshairSidebarContent.make(candle: candle(volume: 128, amount: 1679.8 * 12_840),
                                             previousClose: 1672.40, cursorPrice: 1683.5,
                                             snappedX: 100, mainChartMidX: 500)
        #expect(!c.rows.contains { $0.label == "均价" })
    }

    @Test("amount==nil → 均价 + 成交额两行都隐藏")
    func amountNilHidesAvgAndTurnover() {
        let c = CrosshairSidebarContent.make(candle: candle(amount: nil),
                                             previousClose: 1672.40, cursorPrice: 1683.5,
                                             snappedX: 100, mainChartMidX: 500)
        #expect(!c.rows.contains { $0.label == "均价" })
        #expect(!c.rows.contains { $0.label == "成交额" })
    }

    // 日期/时间：日内显时分；日/周/月只显日期
    @Test("日内周期(m60) → date + time")
    func intradayDateTime() {
        let c = CrosshairSidebarContent.make(candle: candle(period: .m60),
                                             previousClose: 1672.40, cursorPrice: 1683.5,
                                             snappedX: 100, mainChartMidX: 500)
        #expect(c.dateText == "2024-03-28")
        #expect(c.timeText == "14:00")
    }

    @Test("日线周期(daily) → 只 date，time == nil")
    func dailyDateOnly() {
        let c = CrosshairSidebarContent.make(candle: candle(period: .daily),
                                             previousClose: 1672.40, cursorPrice: 1683.5,
                                             snappedX: 100, mainChartMidX: 500)
        #expect(c.dateText == "2024-03-28")
        #expect(c.timeText == nil)
    }

    // 单位一致性（codex R3）：importer 约定 amount = close × volume → 均价 = close ∈[低,高] 显示；成交量单位「股」非「手」
    @Test("amount=close×volume → 均价=close 显示；成交量标『股』")
    func volumeUnitConsistency() {
        let close = 10.0, vol: Int64 = 1000
        let c = candle(open: 9.8, high: 10.2, low: 9.7, close: close,
                       volume: vol, amount: close * Double(vol))     // amount = 10000
        let r = CrosshairSidebarContent.make(candle: c, previousClose: 9.9,
                                             cursorPrice: close, snappedX: 100, mainChartMidX: 500)
        #expect(r.rows.first { $0.label == "均价" }?.value == "10.00")       // amount/volume = close ∈ [低,高]
        #expect(r.rows.first { $0.label == "成交量" }?.value == "1,000 股")   // 单位 = 股（非手）
    }
}

import Testing
import Foundation
@testable import KlineTrainerPersistence
@testable import KlineTrainerContracts

#if DEBUG
@Suite("DebugFixtureData：确定性 rich 训练组蜡烛生成（§C，host 全测）")
struct DebugFixtureDataTests {

    @Test("m3 蜡烛满足 reader 不变量：0 基严格递增 + global==end + 有效 OHLC + volume>=0")
    func m3Candles_satisfyReaderInvariants() {
        let data = DebugFixtureData.make(m3Count: 240)
        let m3 = data.candles.first(where: { $0.period == .m3 })!.rows
        #expect(m3.count == 240)
        for (i, c) in m3.enumerated() {
            #expect(c.globalIndex == i)
            #expect(c.endGlobalIndex == i)
            #expect(c.high >= max(c.open, c.close, c.low))
            #expect(c.low <= min(c.open, c.close, c.high))
            #expect(c.open > 0 && c.close > 0 && c.high > 0 && c.low > 0)
            #expect(c.open.isFinite && c.close.isFinite && c.high.isFinite && c.low.isFinite)
            #expect(c.volume >= 0)
        }
    }

    @Test("daily 蜡烛：global_index nil + end_global_index <= max m3 end + 递增")
    func dailyCandles_endIndexWithinM3Range() {
        let data = DebugFixtureData.make(m3Count: 240)
        let m3 = data.candles.first(where: { $0.period == .m3 })!.rows
        let maxM3End = m3.map(\.endGlobalIndex).max()!
        let daily = data.candles.first(where: { $0.period == .daily })!.rows
        #expect(!daily.isEmpty)
        var prevEnd = -1
        for c in daily {
            #expect(c.globalIndex == nil)
            #expect(c.endGlobalIndex <= maxM3End)
            #expect(c.endGlobalIndex > prevEnd)
            prevEnd = c.endGlobalIndex
        }
        #expect(daily.last!.endGlobalIndex == maxM3End)
    }

    @Test("MA66：前 65 根 NULL，第 66 根起 = 近 66 根 close 均值")
    func ma66_rollingMean() {
        let data = DebugFixtureData.make(m3Count: 240)
        let m3 = data.candles.first(where: { $0.period == .m3 })!.rows
        #expect(m3[0].ma66 == nil)
        #expect(m3[64].ma66 == nil)
        let expected65 = (0...65).map { m3[$0].close }.reduce(0, +) / 66.0
        #expect(abs((m3[65].ma66 ?? -1) - expected65) < 1e-4)   // D7：ma66 现 round 4dp
    }

    @Test("确定性：两次生成完全相同（无随机）")
    func deterministic() {
        let a = DebugFixtureData.make(m3Count: 100)
        let b = DebugFixtureData.make(m3Count: 100)
        let am3 = a.candles.first(where: { $0.period == .m3 })!.rows
        let bm3 = b.candles.first(where: { $0.period == .m3 })!.rows
        #expect(am3.map(\.close) == bm3.map(\.close))
    }

    @Test("records/pending/settings 描述非空且自洽")
    func seedDescriptors_present() {
        let data = DebugFixtureData.make(m3Count: 240)
        #expect(data.records.count >= 2)
        #expect(data.pending != nil)
        #expect(data.settings.totalCapital == 100_000)
        #expect(data.trainingSetFilename.hasSuffix(".sqlite"))
        #expect(data.pending!.trainingSetFilename == data.trainingSetFilename)
        // seed pending 的周期组合**必须是 periodCombos 阶梯里相邻一档**——否则 switchPeriodCombo 永久 no-op
        // （历史 bug：曾误设 (m3,daily) 非法档，单指竖滑切不动）。默认 60分/日线（路线图 P1）。
        #expect(data.pending!.upperPeriod == .m60)
        #expect(data.pending!.lowerPeriod == .daily)
    }

    // codex-13b-R2-F1：全 6 周期非空（make 默认 .m60/.daily + 周期切换 combo 须全覆盖 → fresh start/review/replay 可开）。
    @Test("全 6 周期非空 + 每周期 end_global_index 单调 <= max m3 end（含 make 默认 .m60/.daily）")
    func allSixPeriods_present_andValid() {
        let data = DebugFixtureData.make(m3Count: 240)
        let maxM3End = data.candles.first(where: { $0.period == .m3 })!.rows.map(\.endGlobalIndex).max()!
        for period in Period.allCases {
            guard let pc = data.candles.first(where: { $0.period == period }) else {
                Issue.record("周期 \(period) 缺失"); continue
            }
            #expect(!pc.rows.isEmpty, "周期 \(period) 须非空")
            var prevEnd = -1
            for c in pc.rows {
                #expect(c.endGlobalIndex <= maxM3End)
                if period != .m3 { #expect(c.globalIndex == nil) }
                #expect(c.endGlobalIndex > prevEnd)   // 单调递增（m3 逐根 / 聚合逐组）
                prevEnd = c.endGlobalIndex
            }
        }
        #expect(data.candles.first(where: { $0.period == .m60 })?.rows.isEmpty == false, "make 默认上区 .m60")
        #expect(data.candles.first(where: { $0.period == .daily })?.rows.isEmpty == false, "make 默认下区 .daily")
    }

    // 13c-R2 根治：满载 fixture——每周期 ≥ defaultVisibleCount(80)，默认面板 .m60/.daily ≥ maxVisibleCount(240)。
    // 断言用渲染常量（非循环），把 fixture 直接绑到真实渲染负载。
    @Test("满载常量 fullLoadM3Count：每周期 ≥ defaultVisibleCount(80)，默认面板 .m60/.daily ≥ maxVisibleCount(240)")
    func fullLoadFixture_everyPeriodMeetsRenderLoad() {
        let data = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count)
        for period in Period.allCases {
            let count = data.candles.first(where: { $0.period == period })?.rows.count ?? 0
            #expect(count >= RenderStateBuilder.defaultVisibleCount,
                    "周期 \(period) 蜡烛数 \(count) 须 ≥ defaultVisibleCount(\(RenderStateBuilder.defaultVisibleCount))（非欠载）")
        }
        let m60 = data.candles.first(where: { $0.period == .m60 })?.rows.count ?? 0
        let daily = data.candles.first(where: { $0.period == .daily })?.rows.count ?? 0
        #expect(m60 >= PinchZoomModel.maxVisibleCount,
                "默认上区 .m60 蜡烛数 \(m60) 须 ≥ maxVisibleCount(\(PinchZoomModel.maxVisibleCount))（pinch 最远档满载）")
        #expect(daily >= PinchZoomModel.maxVisibleCount,
                "默认下区 .daily 蜡烛数 \(daily) 须 ≥ maxVisibleCount(\(PinchZoomModel.maxVisibleCount))（pinch 最远档满载）")
    }

    // 满载根数（19200）下，既有 reader 结构不变量仍成立（防大 count 触发聚合 off-by-one / end_global_index 越界）。
    @Test("满载下：全 6 周期 end_global_index 单调递增 + <= max m3 end + 末行 == max m3 end")
    func fullLoadFixture_invariantsStillHold() {
        let data = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count)
        let maxM3End = data.candles.first(where: { $0.period == .m3 })!.rows.map(\.endGlobalIndex).max()!
        for period in Period.allCases {
            guard let rows = data.candles.first(where: { $0.period == period })?.rows else {
                Issue.record("周期 \(period) 缺失于满载 fixture"); continue
            }
            #expect(!rows.isEmpty)
            var prevEnd = -1
            for c in rows {
                #expect(c.endGlobalIndex <= maxM3End)
                #expect(c.endGlobalIndex > prevEnd)
                if period != .m3 { #expect(c.globalIndex == nil) }
                prevEnd = c.endGlobalIndex
            }
            #expect(rows.last!.endGlobalIndex == maxM3End, "周期 \(period) 末行 end 须覆盖到 max m3 end")
        }
    }

    // 监 #7 指标看不到回归：满载下每周期暖机后 MA66/BOLL/MACD 均非 nil（每周期满载根数：m3=19200..monthly=80，均 ≥66/≥20）
    @Test("满载：每周期暖机后 MA66@65 / BOLL@19 三轨 / MACD@0 均非 nil（监 #7）")
    func fullLoad_everyPeriodHasIndicators() {
        let data = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count)
        for period in Period.allCases {
            let rows = data.candles.first(where: { $0.period == period })!.rows
            #expect(rows.count >= 66, "周期 \(period) 满载根数应 ≥66")
            #expect(rows[65].ma66 != nil, "周期 \(period) MA66@65 应非 nil")
            #expect(rows[19].bollUpper != nil && rows[19].bollMid != nil && rows[19].bollLower != nil,
                    "周期 \(period) BOLL@19 三轨应非 nil")
            #expect(rows[0].macdDiff != nil && rows[0].macdDea != nil && rows[0].macdBar != nil,
                    "周期 \(period) MACD@0 应非 nil（无暖机）")
        }
    }

    @Test("满载：所有非 nil 指标值均有限")
    func fullLoad_indicatorsFinite() {
        let data = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count)
        for pc in data.candles {
            for c in pc.rows {
                for v in [c.ma66, c.bollUpper, c.bollMid, c.bollLower, c.macdDiff, c.macdDea, c.macdBar] {
                    if let v { #expect(v.isFinite) }
                }
            }
        }
    }

    // 监 D4：旧版聚合周期 ma66=nil；现逐周期算 → 聚合周期 MA66 亦非 nil
    @Test("MA66 在 m3 与聚合周期(daily)均非 nil（监 D4 旧版聚合 nil 缺陷）")
    func ma66_presentOnAggregatedPeriods() {
        let data = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count)
        let m3 = data.candles.first(where: { $0.period == .m3 })!.rows
        let daily = data.candles.first(where: { $0.period == .daily })!.rows
        #expect(m3[65].ma66 != nil)
        #expect(daily[65].ma66 != nil, "聚合周期 daily 的 MA66 现应非 nil（旧版为 nil）")
    }

    @Test("满载 before/after 结构：每周期根数 = 权威表 + startDatetime 指起始点")
    func fullLoadBeforeAfterStructure() {
        let data = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count,
                                         beforeM3Count: DebugFixtureData.fullLoadBeforeM3Count)
        func total(_ p: Period) -> Int { data.candles.first { $0.period == p }!.rows.count }
        #expect(total(.m3) == 19_200)
        #expect(total(.m15) == 3_840)
        #expect(total(.m60) == 960)
        #expect(total(.daily) == 240)
        #expect(total(.weekly) == 120)
        #expect(total(.monthly) == 80)
        // 起始点 = 第 12000 根 m3 的 datetime（before=12000 根历史在其前）
        let m3 = data.candles.first { $0.period == .m3 }!.rows
        #expect(data.meta.startDatetime == m3[12_000].datetime)
        // before 段：m3[0..<12000] datetime 严格 < startDatetime
        #expect(m3[11_999].datetime < data.meta.startDatetime)
    }

    @Test("默认 beforeM3Count=0 → startDatetime 仍为首根（向后兼容）")
    func defaultZeroBeforeBackCompat() {
        let data = DebugFixtureData.make(m3Count: 240)
        let m3 = data.candles.first { $0.period == .m3 }!.rows
        #expect(data.meta.startDatetime == m3[0].datetime)
    }
}
#endif

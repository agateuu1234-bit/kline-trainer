import Testing
import Foundation
@testable import KlineTrainerPersistence
import KlineTrainerContracts

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
        #expect(abs((m3[65].ma66 ?? -1) - expected65) < 1e-9)
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
}
#endif

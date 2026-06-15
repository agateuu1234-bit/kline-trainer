// 聚合感知 reveal 合成纯函数 host 测
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("PartialAggregateCandle.synthesize")
struct PartialAggregateCandleTests {

    /// m3 工厂：第 i 根 datetime=i*180、endGlobalIndex==globalIndex==i、OHLC 可控。
    static func m3(_ count: Int,
                   highs: [Int: Double] = [:], lows: [Int: Double] = [:],
                   closes: [Int: Double] = [:], vols: [Int: Int64] = [:]) -> [KLineCandle] {
        (0..<count).map { i in
            // 字段先 hoist 到 typed local（避免 dict-coalescing + 算术挤爆 Swift 类型检查器，opus plan-R1-H）
            let h: Double = highs[i] ?? (Double(i) + 1)
            let lo: Double = lows[i] ?? (Double(i) - 1)
            let cl: Double = closes[i] ?? (Double(i) + 0.5)
            let v: Int64 = vols[i] ?? 100
            return KLineCandle(period: .m3, datetime: Int64(i) * 180,
                               open: Double(i), high: h, low: lo, close: cl, volume: v,
                               amount: 999, ma66: 1, bollUpper: 1, bollMid: 1, bollLower: 1,
                               macdDiff: 1, macdDea: 1, macdBar: 1, globalIndex: i, endGlobalIndex: i)
        }
    }

    /// 聚合根（含未来的 vendor 整根；合成应忽略其 OHLC/指标）。datetime 对齐某根 m3 的 datetime。
    static func agg(period: Period, datetime: Int64, endGlobalIndex: Int) -> KLineCandle {
        KLineCandle(period: period, datetime: datetime,
                    open: 9999, high: 9999, low: -9999, close: 9999, volume: 999_999,
                    amount: 999, ma66: 8, bollUpper: 8, bollMid: 8, bollLower: 8,
                    macdDiff: 8, macdDea: 8, macdBar: 8, globalIndex: nil, endGlobalIndex: endGlobalIndex)
    }

    @Test("多 m3：open=首 / high=max / low=min / close=末 / volume=sum；指标+amount nil；endGlobalIndex=tick")
    func multiM3() {
        let series = Self.m3(12, highs: [1: 50], lows: [2: -50], closes: [2: 7.7], vols: [0: 10, 1: 20, 2: 30])
        let a = Self.agg(period: .m60, datetime: 0, endGlobalIndex: 3)
        let s = PartialAggregateCandle.synthesize(original: a, m3: series, tick: 2)
        #expect(s.open == 0)
        #expect(s.high == 50)
        #expect(s.low == -50)
        #expect(s.close == 7.7)
        #expect(s.volume == 60)
        #expect(s.endGlobalIndex == 2)
        #expect(s.period == .m60)
        #expect(s.datetime == 0)
        #expect(s.amount == nil)
        #expect(s.ma66 == nil && s.bollUpper == nil && s.bollMid == nil && s.bollLower == nil)
        #expect(s.macdDiff == nil && s.macdDea == nil && s.macdBar == nil)
        #expect(s.globalIndex == nil)
    }

    @Test("单 m3（start==tick）：成分仅 1 根")
    func singleM3() {
        let series = Self.m3(12)
        let a = Self.agg(period: .m60, datetime: Int64(4) * 180, endGlobalIndex: 7)
        let s = PartialAggregateCandle.synthesize(original: a, m3: series, tick: 4)
        #expect(s.open == 4)
        #expect(s.close == 4.5)
        #expect(s.volume == 100)
        #expect(s.endGlobalIndex == 4)
    }

    @Test("datetime 定位 start：predecessor endGlobalIndex clamp 到 0 不影响（R1-H1 killer）")
    func datetimeStartImmuneToClampedPredecessor() {
        let series = Self.m3(12, highs: [0: 77])
        let a = Self.agg(period: .m60, datetime: 0, endGlobalIndex: 3)
        let s = PartialAggregateCandle.synthesize(original: a, m3: series, tick: 1)
        #expect(s.open == 0)
        #expect(s.high == 77)
    }

    @Test("聚合 open datetime 早于 m3[0]（pre-window）→ start clamp 到 0")
    func aggOpenBeforeFirstM3() {
        let series = Self.m3(12)
        let a = Self.agg(period: .daily, datetime: -1000, endGlobalIndex: 5)
        let s = PartialAggregateCandle.synthesize(original: a, m3: series, tick: 3)
        #expect(s.open == 0)
        #expect(s.endGlobalIndex == 3)
    }

    @Test("trigger 下 rawStart ≤ tick（clamp 无操作，正常路径）")
    func startWithinTick() {
        let series = Self.m3(12)
        let a = Self.agg(period: .m60, datetime: Int64(8) * 180, endGlobalIndex: 11)
        let s = PartialAggregateCandle.synthesize(original: a, m3: series, tick: 9)
        #expect(s.open == 8)
        #expect(s.endGlobalIndex == 9)
    }

    @Test("容损 fail-safe（codex R1-H）：聚合 datetime 越界（> m3[tick]）→ start clamp 到 tick，单根合成不崩不泄漏")
    func malformedAggregateDatetimeClampsNoTrap() {
        // 损坏/恶意数据：聚合 datetime 远超所有已揭示 m3 → rawStart > tick（partitioningIndex==count）。
        // clamp 到 tick → 单根 m3[tick] 合成：渲染期不 trap、成分 ⊆ 已揭示（不泄漏未来）。
        let series = Self.m3(12)              // datetimes 0..11*180=1980
        let a = Self.agg(period: .m60, datetime: 999_999, endGlobalIndex: 7)
        let s = PartialAggregateCandle.synthesize(original: a, m3: series, tick: 5)
        #expect(s.open == 5)                   // clamp start=5 → 单根 m3[5]
        #expect(s.high == 6)                    // m3[5].high（仅已揭示，非未来）
        #expect(s.close == 5.5)                 // m3[5].close
        #expect(s.endGlobalIndex == 5)          // == tick
        #expect(s.datetime == 5 * 180)          // 已揭示 m3[5].datetime（非 vendor 999_999；codex R2-H sanitize）
    }

    @Test("容损 fail-safe（codex R2-H）：巨量 m3 volume 累加饱和到 Int64.max 不 trap")
    func volumeOverflowSaturates() {
        let series = Self.m3(4, vols: [0: Int64.max, 1: 100])   // 损坏数据：单根近上限
        let a = Self.agg(period: .m60, datetime: 0, endGlobalIndex: 3)
        let s = PartialAggregateCandle.synthesize(original: a, m3: series, tick: 1)  // 成分 m3[0,1]
        #expect(s.volume == .max)              // Int64.max + 100 饱和到 .max，不 trap
    }
}

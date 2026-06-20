// ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/FixturePriceSeries.swift
// Kline Trainer — DEBUG fixture 价格序列（确定性对数空间均值回复种子游走）
//
// #if DEBUG only：SplitMix64 固定种子驱动的 OHLCV 生成器，替换旧正弦 close。
// 均值回复(κ>0)+vol_min>0 杜绝钳位退化平台（守 #7 不局部复发）；硬 floor/ceil 仅有限性安全网。

#if DEBUG
import Foundation

enum FixturePriceSeries {
    struct OHLCV: Equatable {
        let open: Double, high: Double, low: Double, close: Double
        let volume: Int
    }

    /// 确定性 PRNG（整数运算，bit-identical）。
    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// [0,1) 取高 53 位尾数。
        mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    }

    static let priceSeed: UInt64 = 0x9E37_79B9_7F4A_7C15
    private static let logCenter = log(10.0)
    private static let kappa = 0.02            // 均值回复强度
    private static let floorPrice = 2.0        // 硬安全网（操作上永不触及）
    private static let ceilPrice = 80.0
    private static let trendSegLen = 200       // 趋势段长（m3 根）
    private static let driftMag = 0.0012       // 每根趋势漂移（log）
    private static let volSegLen = 150         // 波动率段长
    private static let volMin = 0.012          // 波动率下限 > 0（保每根变动）
    private static let volHigh = 0.024
    private static let spreadFactor = 0.5      // 影线 = close·vol·factor
    private static let volumeBase = 1000
    private static let volumeScale = 60_000.0

    static func generate(count: Int) -> [OHLCV] {
        guard count > 0 else { return [] }
        var rng = SplitMix64(seed: priceSeed)
        var result: [OHLCV] = []
        result.reserveCapacity(count)

        // i=0：r_0 := 0，close = 中枢 = 10，open == close
        var logPrice = logCenter
        var prevClose = exp(logPrice)
        let spread0 = prevClose * volMin * spreadFactor
        result.append(OHLCV(open: prevClose, high: prevClose + spread0,
                            low: prevClose - spread0, close: prevClose, volume: volumeBase))

        var drift = driftMag
        var vol = volMin
        for i in 1..<count {
            if i % trendSegLen == 0 { drift = rng.unit() < 0.5 ? -driftMag : driftMag }
            if i % volSegLen == 0 { vol = rng.unit() < 0.5 ? volMin : volHigh }
            let noise = rng.unit() * 2 - 1                                  // [-1,1]
            logPrice = logPrice + drift + kappa * (logCenter - logPrice) + vol * noise
            var close = exp(logPrice)
            close = min(max(close, floorPrice), ceilPrice)                  // 安全网（不操作性触发）
            let open = prevClose
            let spread = close * vol * spreadFactor
            let high = max(open, close) + spread
            let low = min(open, close) - spread
            let volume = volumeBase + Int((volumeScale * abs(vol * noise)).rounded())
            result.append(OHLCV(open: open, high: high, low: low, close: close, volume: volume))
            prevClose = close
        }
        return result
    }
}
#endif

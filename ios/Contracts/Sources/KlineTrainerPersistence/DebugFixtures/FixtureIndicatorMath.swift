// ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/FixtureIndicatorMath.swift
// Kline Trainer — DEBUG fixture 指标计算（逐字复刻后端 backend/import_csv.py:69-89）
//
// #if DEBUG only：纯函数，把 close 序列算成 MA66/BOLL/MACD，供 DebugFixtureData 逐周期填值。
// 公式与舍入与后端一致（跨语言契约），使 fixture 忠实预览真实预计算数据。

#if DEBUG
import Foundation

enum FixtureIndicatorMath {
    private static func round4(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }
    private static func round6(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }

    /// SMA(close, 66)，min_periods 66 → 前 65 根 nil，round 4dp。(import_csv.py:74)
    static func ma66(_ close: [Double]) -> [Double?] {
        let window = 66
        return close.indices.map { i in
            guard i >= window - 1 else { return nil }
            let sum = close[(i - window + 1)...i].reduce(0, +)
            return round4(sum / Double(window))
        }
    }

    /// BOLL：window 20，min_periods 20，mid=SMA，±2·总体 std(ddof=0)，round 4dp。(import_csv.py:76-80)
    static func boll(_ close: [Double]) -> (upper: [Double?], mid: [Double?], lower: [Double?]) {
        let window = 20
        var upper = [Double?](repeating: nil, count: close.count)
        var mid = [Double?](repeating: nil, count: close.count)
        var lower = [Double?](repeating: nil, count: close.count)
        for i in close.indices where i >= window - 1 {
            let w = close[(i - window + 1)...i]
            let m = w.reduce(0, +) / Double(window)
            let variance = w.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(window) // ddof=0 总体
            let std = variance.squareRoot()
            mid[i] = round4(m)
            upper[i] = round4(m + 2 * std)
            lower[i] = round4(m - 2 * std)
        }
        return (upper, mid, lower)
    }

    /// MACD：EMA12−EMA26 / EMA(dif,9) / bar=(dif−dea)×2；ewm(adjust=False) 首值播种；round 6dp；无暖机 nil。(import_csv.py:82-88)
    static func macd(_ close: [Double]) -> (diff: [Double?], dea: [Double?], bar: [Double?]) {
        guard !close.isEmpty else { return ([], [], []) }
        func ewm(_ x: [Double], span: Int) -> [Double] {
            let alpha = 2.0 / (Double(span) + 1.0)
            var out = [Double](repeating: 0, count: x.count)
            out[0] = x[0]                                   // adjust=False 首值播种 y[0]=x[0]
            for i in 1..<x.count { out[i] = alpha * x[i] + (1 - alpha) * out[i - 1] }
            return out
        }
        let ema12 = ewm(close, span: 12)
        let ema26 = ewm(close, span: 26)
        let dif = zip(ema12, ema26).map { $0 - $1 }
        let dea = ewm(dif, span: 9)
        let diffOut = dif.map { Optional(round6($0)) }
        let deaOut = dea.map { Optional(round6($0)) }
        let barOut = zip(dif, dea).map { Optional(round6(($0 - $1) * 2)) }
        return (diffOut, deaOut, barOut)
    }
}
#endif

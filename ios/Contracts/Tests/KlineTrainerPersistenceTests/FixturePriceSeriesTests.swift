import Testing
import Foundation
@testable import KlineTrainerPersistence

#if DEBUG
@Suite("FixturePriceSeries：确定性对数均值回复 OHLCV 种子游走（host 全测）")
struct FixturePriceSeriesTests {

    @Test("确定性：同种子两次生成完全相同（无随机/无时钟）")
    func deterministic() {
        #expect(FixturePriceSeries.generate(count: 500) == FixturePriceSeries.generate(count: 500))
    }

    @Test("正值且有限；volume≥0")
    func positiveFinite() {
        for c in FixturePriceSeries.generate(count: 1000) {
            #expect(c.open > 0 && c.high > 0 && c.low > 0 && c.close > 0)
            #expect(c.open.isFinite && c.high.isFinite && c.low.isFinite && c.close.isFinite)
            #expect(c.volume >= 0)
        }
    }

    @Test("OHLC 不变量：high≥max(o,c)、low≤min(o,c)、high≥low")
    func ohlcInvariants() {
        for c in FixturePriceSeries.generate(count: 1000) {
            #expect(c.high >= max(c.open, c.close))
            #expect(c.low <= min(c.open, c.close))
            #expect(c.high >= c.low)
        }
    }

    @Test("首根 r_0:=0：open[0] == close[0]")
    func firstBarFlat() {
        let s = FixturePriceSeries.generate(count: 10)
        #expect(s[0].open == s[0].close)
    }

    @Test("计数 == n；空输入 == []；count==1 == 1")
    func countMatches() {
        #expect(FixturePriceSeries.generate(count: 0).isEmpty)
        #expect(FixturePriceSeries.generate(count: 1).count == 1)
        #expect(FixturePriceSeries.generate(count: 9600).count == 9600)
    }

    // D10 退化守门：full-load 9600 任意连续 20 close 总体 std > ε(≈窗口均值·1e-3) → BOLL 永不三线重叠（守 #7 不局部复发）
    @Test("非退化守门：full-load 任意 20 窗口 close 总体 std > ε(≈mean·1e-3)")
    func noDegenerate20Window() {
        let closes = FixturePriceSeries.generate(count: 9600).map(\.close)
        for start in 0...(closes.count - 20) {
            let w = closes[start..<start + 20]
            let mean = w.reduce(0, +) / 20
            let variance = w.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / 20
            let std = variance.squareRoot()
            #expect(std > mean * 1e-3, "窗口[\(start)] std=\(std) 退化（≤ \(mean * 1e-3)）")
        }
    }

    // 安全网 tripwire：均值回复保证操作上永不触及硬 floor/ceil
    @Test("永不贴边：全序列无 close 触及 floor(2)/ceil(80)")
    func neverTouchesBounds() {
        for c in FixturePriceSeries.generate(count: 9600) { #expect(c.close > 2.0 && c.close < 80.0) }
    }

    @Test("整序列 return 标准差 > 0（真实波动非常量）")
    func returnsVary() {
        let closes = FixturePriceSeries.generate(count: 1000).map(\.close)
        let rets = (1..<closes.count).map { closes[$0] - closes[$0 - 1] }
        let mean = rets.reduce(0, +) / Double(rets.count)
        let varr = rets.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rets.count)
        #expect(varr.squareRoot() > 0)
    }
}
#endif

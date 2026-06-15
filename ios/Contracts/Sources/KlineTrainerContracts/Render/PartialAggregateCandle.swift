// 聚合感知 reveal —— 进行中聚合 K 线 partial 合成
// Spec: docs/superpowers/specs/2026-06-15-aggregate-aware-reveal-design.md
//
// 平台无关纯函数：从已揭示 m3 合成进行中聚合 K 线的 partial OHLC/volume，
// 指标/amount nil（D2：vendor 整根指标含未来、不在端上重算），endGlobalIndex=tick（D3）。

import Foundation

public enum PartialAggregateCandle {
    /// 合成进行中聚合 K 线。
    /// - start = 首个 `datetime >= original.datetime` 的 m3（匹配 backend `[open,nextOpen)` 下界；
    ///   对 pre-window predecessor `endGlobalIndex` clamp 到 0 免疫，spec R1-H1）。
    /// - 前置：`m3` 非空、按 datetime 升序（.m3 连续轴）、`tick < m3.count`；`start <= tick`（trigger 保证，assert 钉死）。
    public static func synthesize(original: KLineCandle, m3: [KLineCandle], tick: Int) -> KLineCandle {
        let start = m3.partitioningIndex { $0.datetime >= original.datetime }
        assert(start <= tick, "PartialAggregateCandle.synthesize: start(\(start)) must be <= tick(\(tick))")
        let constituents = m3[start ... tick]
        return KLineCandle(
            period: original.period,
            datetime: original.datetime,
            open: constituents.first!.open,
            high: constituents.map(\.high).max()!,
            low: constituents.map(\.low).min()!,
            close: constituents.last!.close,
            volume: constituents.reduce(Int64(0)) { $0 + $1.volume },
            amount: nil, ma66: nil,
            bollUpper: nil, bollMid: nil, bollLower: nil,
            macdDiff: nil, macdDea: nil, macdBar: nil,
            globalIndex: nil, endGlobalIndex: tick)
    }
}

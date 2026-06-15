// 聚合感知 reveal —— 进行中聚合 K 线 partial 合成
// Spec: docs/superpowers/specs/2026-06-15-aggregate-aware-reveal-design.md
//
// 平台无关纯函数：从已揭示 m3 合成进行中聚合 K 线的 partial OHLC/volume，
// 指标/amount nil（D2：vendor 整根指标含未来、不在端上重算），endGlobalIndex=tick（D3）。

import Foundation

public enum PartialAggregateCandle {
    /// 合成进行中聚合 K 线。
    /// - rawStart = 首个 `datetime >= original.datetime` 的 m3（匹配 backend `[open,nextOpen)` 下界；
    ///   对 pre-window predecessor `endGlobalIndex` clamp 到 0 免疫，spec R1-H1）。
    /// - 前置：`m3` 非空、`tick < m3.count`（make() 守）。
    /// - **容损 fail-safe（codex R1-H）**：`start = min(rawStart, tick)` clamp 到 `[0, tick]`。良性数据下
    ///   trigger 已保证 rawStart ≤ tick（clamp 无操作）；恶意/损坏数据（`.m3` datetime 非单调 / 聚合 datetime
    ///   越界）可能令 rawStart > tick → 不再于渲染热路径 trap，而是 fail-closed：`m3[start...tick]` 恒有效
    ///   （不崩）+ 成分恒 ⊆ 已揭示 m3（不渲染 vendor 整根、不泄漏未来）。temporal 一致性的强校验属
    ///   reader/persistence trust-boundary（本渲染 RFC 作用域外）；clamp 使渲染路径对其失效亦安全。
    public static func synthesize(original: KLineCandle, m3: [KLineCandle], tick: Int) -> KLineCandle {
        let rawStart = m3.partitioningIndex { $0.datetime >= original.datetime }
        let start = min(rawStart, tick)
        let constituents = m3[start ... tick]
        // 成交量 overflow-safe（codex R2-H）：损坏数据下巨量累加饱和到 Int64.max，不在渲染期 trap。
        var volume: Int64 = 0
        for c in constituents {
            let (sum, overflow) = volume.addingReportingOverflow(c.volume)
            volume = overflow ? .max : sum
        }
        return KLineCandle(
            period: original.period,
            // datetime 取已揭示首成分（codex R2-H）：良性数据 == original.datetime（聚合 open 对齐其首根 m3）；
            // 损坏数据（聚合 datetime 越界）下不把未来时间戳带进 crosshair/HUD（fail-closed）。
            datetime: constituents.first!.datetime,
            open: constituents.first!.open,
            high: constituents.map(\.high).max()!,
            low: constituents.map(\.low).min()!,
            close: constituents.last!.close,
            volume: volume,
            amount: nil, ma66: nil,
            bollUpper: nil, bollMid: nil, bollLower: nil,
            macdDiff: nil, macdDea: nil, macdBar: nil,
            globalIndex: nil, endGlobalIndex: tick)
    }
}

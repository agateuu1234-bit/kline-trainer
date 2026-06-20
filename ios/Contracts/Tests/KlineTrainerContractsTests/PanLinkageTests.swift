// ios/Contracts/Tests/KlineTrainerContractsTests/PanLinkageTests.swift
// Spec: docs/superpowers/specs/2026-06-20-two-panel-pan-linkage-design.md §4.2
// 平台无关纯逻辑：tick↔offset 跨周期换算的红绿覆盖（host 直跑）。
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("PanLinkage routing")
struct PanLinkageTests {
    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)   // ChartPanelFrames.split 只切 height → mainChart.width = 800；rawVisible=80 → step=10（整除）
    static let rawVisible = 80

    /// 最小 candle：仅 endGlobalIndex 有意义（换算只读它），其余填占位。
    private func cand(_ end: Int, _ period: Period = .m3) -> KLineCandle {
        KLineCandle(period: period, datetime: Int64(end), open: 1, high: 1, low: 1, close: 1,
                    volume: 0, amount: nil, ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                    macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: end, endGlobalIndex: end)
    }
    /// 连续 endGlobalIndex = 1...n（m3 满轴语义）。
    private func contiguous(_ n: Int) -> [KLineCandle] { (1...n).map { cand($0) } }

    // MARK: - 同周期 round-trip：forward→inverse 还原到 whole-candle 粒度（核心 killer）

    @Test("同周期 round-trip：offset → tick → offset 还原（whole-candle 粒度）")
    func sameRoundTrip() {
        let c = contiguous(200)
        let tick = 150
        let t = PanLinkage.rightEdgeTick(offset: 300, candles: c, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        let back = PanLinkage.followerOffset(targetTick: t, candles: c, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        // offset=300 = 30·step（整除）→ wholeShift=30 → 还原 offset=300 **精确**（M1：同周期整除应精确，非 1-step 容差掩盖 off-by-one）
        #expect(abs(back - 300) < 1e-6)
    }

    // MARK: - 同 tick 对齐：offset=0 → 右缘=最新 → follower offset=0

    @Test("offset=0 → 右缘 tick = 当前 candle endGlobalIndex；followerOffset 还原 0")
    func zeroAligns() {
        let c = contiguous(200)
        let tick = 150
        let curIdx = RenderStateBuilder.currentCandleIndex(candles: c, tick: tick)
        let t = PanLinkage.rightEdgeTick(offset: 0, candles: c, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        #expect(t == c[curIdx].endGlobalIndex)
        let off = PanLinkage.followerOffset(targetTick: t, candles: c, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        #expect(off == 0)
    }

    // MARK: - 跨周期：follower 右缘重投影回同一 tick（不硬编码数值的真 killer）

    @Test("跨周期：follower offset 使其右缘 tick == leader 右缘 tick（候选粒度内）")
    func crossPeriodReprojects() {
        // C1：lower 必须有滚动空间（count=200 > visibleCount=80，且 currentIdx-base>0），否则 maxOffset=0 测试失真。
        let upper = contiguous(800)                        // 细：endGlobalIndex 1..800（每 tick 一根）
        let lower = (1...200).map { cand($0 * 4) }          // 粗：endGlobalIndex 4,8,...,800（每 4 tick 一根，200 根）
        let tick = 400                                      // currentIdx(upper)=399 / currentIdx(lower)=99，两者 base>0
        let leaderTick = PanLinkage.rightEdgeTick(offset: 250, candles: upper, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        let fOff = PanLinkage.followerOffset(targetTick: leaderTick, candles: lower, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        let fTick = PanLinkage.rightEdgeTick(offset: fOff, candles: lower, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: tick)
        // 实算：leaderTick=375 → fOff=60 → fTick=376（首个覆盖 375 的粗 candle，currentCandleIndex 谓词）
        #expect(fTick >= leaderTick)
        #expect(fTick - leaderTick < 4)                    // 落在同一粗 candle 跨度内（4 tick）
        #expect(fOff > 0)                                   // 坐实真用了滚动空间（非退化钳 0）
    }

    // MARK: - clamp 两端（M1 安全网）

    @Test("M1：targetTick 落 follower 当前右缘 → wholeShift=0 → clamp 0")
    func clampNewEnd() {
        let lower = (1...200).map { cand($0 * 4) }           // 200 根有滚动空间；tick=400 → 右缘 endGlobalIndex=400
        let off = PanLinkage.followerOffset(targetTick: 400, candles: lower, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: 400)
        #expect(off == 0)                                    // 右缘=最新，offset 钳 0
    }

    @Test("M1：targetTick 远早于可见 → clamp maxOffset（坐实非退化）")
    func clampOldEnd() {
        let lower = (1...200).map { cand($0 * 4) }
        let curIdx = RenderStateBuilder.currentCandleIndex(candles: lower, tick: 400)   // =99
        let ob = RenderStateBuilder.offsetBounds(mainFrameWidth: 800, rawVisible: Self.rawVisible, candleCount: 200, currentIdx: curIdx)
        #expect(ob.maxOffset > 0)                            // C2：坐实有滚动空间（maxOffset=200），否则 clamp 分支空洞
        let off = PanLinkage.followerOffset(targetTick: 4, candles: lower, rawVisible: Self.rawVisible, bounds: Self.bounds, tick: 400)
        #expect(off == ob.maxOffset)                         // raw≈990 被钳到最老边 maxOffset
    }

    // MARK: - FP 非整除 step（roundTripEdge 复用）

    @Test("FP：非整除 step（1000/21）round-trip 不漂")
    func fpNonDivisible() {
        let c = contiguous(120)
        let w = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let t = PanLinkage.rightEdgeTick(offset: 200, candles: c, rawVisible: 21, bounds: w, tick: 100)
        let back = PanLinkage.followerOffset(targetTick: t, candles: c, rawVisible: 21, bounds: w, tick: 100)
        #expect(abs(back - 200) < 1000.0 / 21.0 + 1e-6)     // 容差 1 个非整除 step
    }

    // MARK: - 退化

    @Test("空 candles → rightEdgeTick 0 / followerOffset 0（不 crash）")
    func emptyDegenerate() {
        #expect(PanLinkage.rightEdgeTick(offset: 100, candles: [], rawVisible: 80, bounds: Self.bounds, tick: 10) == 0)
        #expect(PanLinkage.followerOffset(targetTick: 100, candles: [], rawVisible: 80, bounds: Self.bounds, tick: 10) == 0)
    }
}

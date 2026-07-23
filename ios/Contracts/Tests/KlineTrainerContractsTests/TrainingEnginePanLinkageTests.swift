// ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePanLinkageTests.swift
// Spec: docs/superpowers/specs/2026-06-20-two-panel-pan-linkage-design.md §4.1/§6（M3 引擎接线）
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingEngine pan 联动接线", .serialized)
struct TrainingEnginePanLinkageTests {
    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    // 同周期 m3/m3：follower 应被驱动到与 leader 相同 offset（1:1）；跨周期换算见 PanLinkageTests。
    static func makeEngine(count: Int, tick: Int) -> (TrainingEngine, () -> [FakeFrameDriver]) {
        final class Box { var fakes: [FakeFrameDriver] = [] }
        let box = Box()
        let maxTick = count - 1
        let e = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: maxTick),
            allCandles: TrainingEngineActionsTests.m3Candles(Array(repeating: 10, count: count)),
            maxTick: maxTick, initialTick: tick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { onTick in let f = FakeFrameDriver(onTick: onTick); box.fakes.append(f); return f })
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.recordRenderBounds(Self.bounds, panel: .lower)
        return (e, { box.fakes })
    }

    @Test("拖 upper → lower 被驱动到同一 offset（同周期 1:1）")
    func dragUpperDrivesLower() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 300, renderBounds: Self.bounds, panel: .upper)   // 300=30·step 整除 → 1:1 精确
        #expect(e.upperPanel.offset > 0)
        #expect(abs(e.lowerPanel.offset - e.upperPanel.offset) < 1e-6)   // 同周期整除 1:1 应精确（M1，非 1-step 容差）
    }

    @Test("拖 lower → upper 被驱动（双向对称）")
    func dragLowerDrivesUpper() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        e.beginPan(panel: .lower)
        e.applyPanOffset(deltaPixels: 250, renderBounds: Self.bounds, panel: .lower)   // 250=25·step 整除
        #expect(abs(e.upperPanel.offset - e.lowerPanel.offset) < 1e-6)
    }

    @Test("D7：leader beginPan → follower 转 freeScrolling")
    func followerEntersFreeScrolling() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        e.beginPan(panel: .upper)
        if case .freeScrolling = e.lowerPanel.interactionMode {} else { Issue.record("follower 应 freeScrolling") }
    }

    @Test("减速逐帧：leader 惯性减速时 follower 同步跟随至 settle")
    func followerTracksDeceleration() {
        let (e, fakes) = Self.makeEngine(count: 200, tick: 150)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 400, renderBounds: Self.bounds, panel: .upper)
        e.endPan(velocity: -3000, renderBounds: Self.bounds, panel: .upper)
        for _ in 0..<240 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(abs(e.lowerPanel.offset - e.upperPanel.offset) < 10.0)   // settle 后仍对齐
    }

    // H2 诚实定位：这是「lockstep reset 后两图仍对齐」**健全性**测试，**非** double-drive killer——
    // 双驱（误把 propagate 挂 resetOffsetAfterAutoTracking）与正确实现都收敛到 offset=0，行为不可区分。
    // 双驱避免靠 D5 **结构性**保证（propagate 只在 3 个具名 gesture 函数、不挂 reset），由 plan/spec 文字 + code review 把关。
    @Test("健全性：买卖后两面板 lockstep reset 到 offset=0（联动驱 follower 离 0 后 reset 仍归零）")
    func tradeResetStaysAligned() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 300, renderBounds: Self.bounds, panel: .upper)
        #expect(e.lowerPanel.offset > 0)                                 // 联动已驱 follower 离 0（使下面归零有意义）
        _ = e.buy(panel: .upper, shares: 2000)                           // trade → resetOffsetAfterAutoTracking 两面板
        #expect(e.upperPanel.offset == 0)
        #expect(e.lowerPanel.offset == 0)                                // 两图都归 0（reset 路径未被联动破坏）
    }

    // H1：D10（1a-iv 改写）—— 视口解冻后 follower 在 drawing 态**照常被驱动**。
    // 旧规则「drawing 态 follower 不跟」的依据是「reducer 吞 .offsetApplied、跟不跟都看不出来」；
    // 1a-iv 起两面板在画线会话里同时是 .drawing 且视口可动，follower 不跟 = 两面板时间轴错位。
    @Test("D10（1a-iv）：follower 处于 drawing 态**也**被联动驱动，且 interactionMode 仍是 drawing")
    func followerInDrawingIsDrivenAfterThaw() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        e.armPanelForDrawing(.trend, panel: .lower)                      // lower 进 drawing（仅武装 lower，不动 upper）
        let before = e.lowerPanel.offset
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 300, renderBounds: Self.bounds, panel: .upper)
        #expect(e.lowerPanel.offset != before)                           // ⭐改造前：== before（drawing 吞 .offsetApplied）
        if case .drawing = e.lowerPanel.interactionMode {} else { Issue.record("follower 应仍 drawing") }
    }

    @Test("D10（1a-iv）：全局画线会话里（**两面板都 .drawing**）平移 leader → 两面板保持对齐")
    func bothPanelsInDrawingStayAlignedWhilePanning() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        e.toggleDrawingMode()                                            // 全局会话：两面板同时 .drawing
        #expect(e.isDrawingActive(on: .upper) && e.isDrawingActive(on: .lower))   // 前置
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 300, renderBounds: Self.bounds, panel: .upper)
        #expect(e.upperPanel.offset > 0)                                 // leader 真的动了
        #expect(e.lowerPanel.offset > 0)                                 // ⭐follower 跟上（不跟 = 两面板时间轴错位）
    }

    // M2：跨周期引擎集成 —— upper=.m3 / lower=.m15，证 propagateLinkage 用对各自 period（同周期 1:1 抓不到 period-swap）。
    static func makeCrossEngine(m3Count: Int, tick: Int) -> TrainingEngine {
        var all = TrainingEngineActionsTests.m3Candles(Array(repeating: 10, count: m3Count))   // [.m3: endGlobalIndex 0..m3Count-1]
        let m15 = stride(from: 4, to: m3Count, by: 5).map { end -> KLineCandle in              // 粗：每 5 个 m3-tick 一根
            KLineCandle(period: .m15, datetime: Int64(end), open: 10, high: 10, low: 10, close: 10,
                        volume: 1, amount: nil, ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: end, endGlobalIndex: end)
        }
        all[.m15] = m15
        let maxTick = m3Count - 1
        let e = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: maxTick),
            allCandles: all, maxTick: maxTick, initialTick: tick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m15,
            decelerationDriverFactory: { onTick in FakeFrameDriver(onTick: onTick) })
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.recordRenderBounds(Self.bounds, panel: .lower)
        return e
    }

    @Test("M2 跨周期：拖 upper(.m3) → lower(.m15) 右缘对齐同一 tick（非 1:1，证 period 取对）")
    func crossPeriodEngineAligns() {
        let e = Self.makeCrossEngine(m3Count: 1200, tick: 800)            // 两面板均有充足滚动空间
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 250, renderBounds: Self.bounds, panel: .upper)
        #expect(e.lowerPanel.offset > 0)                                 // follower 跟了
        #expect(e.lowerPanel.offset < e.upperPanel.offset)               // 粗周期同时间跨度移动更少像素（非 1:1；若 period 取错→1:1==）
        // 两面板右缘 tick 在 m15 粒度（5 tick）内对齐（实算 upTick=775 / loTick=779 / diff=4）；tick 未推进=initialTick 800。
        let upTick = PanLinkage.rightEdgeTick(offset: e.upperPanel.offset, candles: e.allCandles[.m3]!, rawVisible: e.upperPanel.visibleCount, bounds: Self.bounds, tick: 800)
        let loTick = PanLinkage.rightEdgeTick(offset: e.lowerPanel.offset, candles: e.allCandles[.m15]!, rawVisible: e.lowerPanel.visibleCount, bounds: Self.bounds, tick: 800)
        #expect(abs(loTick - upTick) <= 5)
    }
}

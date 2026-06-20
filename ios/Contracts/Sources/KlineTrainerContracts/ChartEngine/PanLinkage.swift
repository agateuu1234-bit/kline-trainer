// ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/PanLinkage.swift
// Spec: docs/superpowers/specs/2026-06-20-two-panel-pan-linkage-design.md（RFC #4）
//
// 平台无关纯逻辑：两面板 pan 时间对齐联动的 tick↔offset 跨周期换算。
// 是 RenderStateBuilder.makeViewport 的 offset↔index forward/inverse，**复用其几何**（geometryCore/
// currentCandleIndex/offsetBounds），不重写（D9 单一几何真相）。引擎 propagateLinkage 消费本层。
//
// 决议：D6 follower 经 .offsetApplied 驱动 / D8 follower clamp[0,maxOffset] / M1 clamp 是安全网（跨周期
// wholeShift 可为负，不依赖 wholeShift≥0 保证） / M2 调用点只传 candles+bounds，几何在此内部派生。

import Foundation
import CoreGraphics

enum PanLinkage {

    /// forward：leader 当前 offset → 其右缘可见候选的 `endGlobalIndex`（= 右缘 tick）。
    /// 内部经 geometryCore 派生 step/visibleCount/currentIdx（与 makeViewport 同源）。
    /// `wholeShift=floor(offset/step)`；右缘候选 idx = clamp(currentIdx-wholeShift, oldestRightEdge, currentIdx)，
    /// 其中 oldestRightEdge=min(visibleCount-1,currentIdx)（startIndex==0 时右缘）。
    static func rightEdgeTick(offset: CGFloat, candles: [KLineCandle],
                             rawVisible: Int, bounds: CGRect, tick: Int) -> Int {
        guard !candles.isEmpty else { return 0 }
        let mainW = ChartPanelFrames.split(in: bounds).mainChart.width
        let currentIdx = RenderStateBuilder.currentCandleIndex(candles: candles, tick: tick)
        let core = RenderStateBuilder.geometryCore(mainFrameWidth: mainW, rawVisible: rawVisible,
                                                  candleCount: candles.count, currentIdx: currentIdx)
        guard core.candleStep.isFinite, core.candleStep > 0 else { return candles[currentIdx].endGlobalIndex }
        let wholeShift = Int((offset / core.candleStep).rounded(.down))
        let oldestRightEdge = min(core.visibleCount - 1, currentIdx)
        let idx = min(max(currentIdx - wholeShift, oldestRightEdge), currentIdx)
        return candles[idx].endGlobalIndex
    }

    /// inverse：目标 tick → follower offset（右缘候选 endGlobalIndex 首个 ≥ targetTick），clamp[0,maxOffset]。
    /// **M1：clamp 是 load-bearing 安全网**——follower 不同周期数组，currentCandleIndex(_, targetTick) 钳 count-1
    /// 时可致 targetIdx>currentIdx → wholeShift 负 → offset 负 → 被 clamp 兜回 0。
    static func followerOffset(targetTick: Int, candles: [KLineCandle],
                              rawVisible: Int, bounds: CGRect, tick: Int) -> CGFloat {
        guard !candles.isEmpty else { return 0 }
        let mainW = ChartPanelFrames.split(in: bounds).mainChart.width
        let currentIdx = RenderStateBuilder.currentCandleIndex(candles: candles, tick: tick)
        let targetIdx = RenderStateBuilder.currentCandleIndex(candles: candles, tick: targetTick)
        let ob = RenderStateBuilder.offsetBounds(mainFrameWidth: mainW, rawVisible: rawVisible,
                                                candleCount: candles.count, currentIdx: currentIdx)
        guard ob.candleStep.isFinite, ob.candleStep > 0 else { return 0 }
        let wholeShift = currentIdx - targetIdx
        let raw = CGFloat(wholeShift) * ob.candleStep
        return min(max(raw, ob.minOffset), ob.maxOffset)
    }
}

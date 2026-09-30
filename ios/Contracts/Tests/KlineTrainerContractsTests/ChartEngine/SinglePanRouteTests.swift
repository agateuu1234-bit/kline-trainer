// ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/SinglePanRouteTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D134 / D138 末段 / N1 / T8）
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

@Suite("P1c-3 单指路由（D134）")
struct SinglePanRouteTests {

    @Test("N1 没有候选 ⇒ 路由恒为 .chart（⇒ 平移/切周期/缩放一字不变）")
    func noCandidateKeepsChartRoute() {
        var r = SinglePanRoute.chart
        r = singlePanRouteStep(phase: .began, candidateAccepted: false, current: r)
        #expect(r == .chart)
        r = singlePanRouteStep(phase: .changed, candidateAccepted: false, current: r)
        #expect(r == .chart)
    }

    @Test("N1 的反向对照：有候选 ⇒ 路由确实变成 .nodeDrag（⛔ 缺了它「分叉没接上」也全绿）")
    func candidateSwitchesRoute() {
        var r = SinglePanRoute.chart
        r = singlePanRouteStep(phase: .began, candidateAccepted: true, current: r)
        #expect(r == .nodeDrag)
    }

    @Test("T9①② latch：`.began` 之后不再重新询问 —— 中途 candidateAccepted 翻转也不改路由")
    func routeIsLatchedAfterBegan() {
        var r = singlePanRouteStep(phase: .began, candidateAccepted: true, current: .chart)
        // ⭐ 喂一个「此刻已经没有候选」的 .changed —— 路由必须仍是 .nodeDrag
        r = singlePanRouteStep(phase: .changed, candidateAccepted: false, current: r)
        #expect(r == .nodeDrag)
        // 反向：没进拖动的手势，中途「突然有候选」也不得转过去
        var c = singlePanRouteStep(phase: .began, candidateAccepted: false, current: .chart)
        c = singlePanRouteStep(phase: .changed, candidateAccepted: true, current: c)
        #expect(c == .chart)
    }

    @Test("T8 终止相位复位为 .chart（下一次手势从干净状态起手）")
    func terminalPhaseResets() {
        for ph in [GesturePhase.ended, .cancelled] {
            let r = singlePanRouteStep(phase: ph, candidateAccepted: false, current: .nodeDrag)
            #expect(r == .chart, "\(ph) 之后路由没复位")
        }
    }
}

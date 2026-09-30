// ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/SinglePanRouteTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D134 / D138 末段 / N1 / T8）
// 第 1 轮修复环：singlePanRouteStep 从「只返回新 route」改为「返回 forwardToNodeDrag + route」，
// 判别力搬进纯函数——本文件的测试要能在 host 上钉死「终止相位必须转发」这条 Critical 的回归。
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

@Suite("P1c-3 单指路由（D134）")
struct SinglePanRouteTests {

    @Test("N1 没有候选 ⇒ 路由恒为 .chart、不转发（⇒ 平移/切周期/缩放一字不变）")
    func noCandidateKeepsChartRoute() {
        var step = singlePanRouteStep(phase: .began, candidateAccepted: false, current: .chart)
        #expect(step.route == .chart)
        #expect(step.forwardToNodeDrag == false)
        step = singlePanRouteStep(phase: .changed, candidateAccepted: false, current: step.route)
        #expect(step.route == .chart)
        #expect(step.forwardToNodeDrag == false)
    }

    @Test("N1 的反向对照：有候选 ⇒ 路由确实变成 .nodeDrag 且转发本次 .began（⛔ 缺了它「分叉没接上」也全绿）")
    func candidateSwitchesRoute() {
        let step = singlePanRouteStep(phase: .began, candidateAccepted: true, current: .chart)
        #expect(step.route == .nodeDrag)
        #expect(step.forwardToNodeDrag == true)
    }

    @Test("T9①② latch：`.began` 之后不再重新询问 —— 中途 candidateAccepted 翻转也不改路由/转发")
    func routeIsLatchedAfterBegan() {
        let began = singlePanRouteStep(phase: .began, candidateAccepted: true, current: .chart)
        // ⭐ 喂一个「此刻已经没有候选」的 .changed —— 路由必须仍是 .nodeDrag、仍转发
        let changed = singlePanRouteStep(phase: .changed, candidateAccepted: false, current: began.route)
        #expect(changed.route == .nodeDrag)
        #expect(changed.forwardToNodeDrag == true)
        // 反向：没进拖动的手势，中途「突然有候选」也不得转过去
        let beganChart = singlePanRouteStep(phase: .began, candidateAccepted: false, current: .chart)
        let changedChart = singlePanRouteStep(phase: .changed, candidateAccepted: true, current: beganChart.route)
        #expect(changedChart.route == .chart)
        #expect(changedChart.forwardToNodeDrag == false)
    }

    @Test("⭐ Critical 回归：.began(候选)→若干 .changed→.ended ⇒ 终止那一步必须转发，且复位为 .chart")
    func nodeDragEndedForwardsTerminalAndResets() {
        var route: SinglePanRoute = .chart
        let began = singlePanRouteStep(phase: .began, candidateAccepted: true, current: route)
        route = began.route
        for _ in 0..<3 {
            let mid = singlePanRouteStep(phase: .changed, candidateAccepted: false, current: route)
            route = mid.route
        }
        let ended = singlePanRouteStep(phase: .ended, candidateAccepted: false, current: route)
        #expect(ended.forwardToNodeDrag == true, "拖动的 .ended 没有被转发——收尾信号会被吞、线永远提交不了")
        #expect(ended.route == .chart, "下一次手势必须从干净状态起手")
    }

    @Test("⭐ Critical 回归的 .cancelled 同款：拖动中被取消 ⇒ 也必须转发终止相位")
    func nodeDragCancelledForwardsTerminalAndResets() {
        let began = singlePanRouteStep(phase: .began, candidateAccepted: true, current: .chart)
        let cancelled = singlePanRouteStep(phase: .cancelled, candidateAccepted: false, current: began.route)
        #expect(cancelled.forwardToNodeDrag == true, "拖动的 .cancelled 没有被转发")
        #expect(cancelled.route == .chart)
    }

    @Test("反向对照：图表手势的终止相位（.ended / .cancelled）⇒ 不转发（⛔ 防「恒 true」全绿）")
    func chartGestureTerminalDoesNotForward() {
        for ph in [GesturePhase.ended, .cancelled] {
            let step = singlePanRouteStep(phase: ph, candidateAccepted: false, current: .chart)
            #expect(step.forwardToNodeDrag == false, "\(ph)：图表手势不该被当成节点拖动转发")
            #expect(step.route == .chart)
        }
    }

    @Test(".changed 两个方向：拖动中（current==.nodeDrag）转发；图表中（current==.chart）不转发")
    func changedForwardsOnlyWhenDragging() {
        let dragging = singlePanRouteStep(phase: .changed, candidateAccepted: false, current: .nodeDrag)
        #expect(dragging.forwardToNodeDrag == true)
        #expect(dragging.route == .nodeDrag)

        let charting = singlePanRouteStep(phase: .changed, candidateAccepted: false, current: .chart)
        #expect(charting.forwardToNodeDrag == false)
        #expect(charting.route == .chart)
    }
}

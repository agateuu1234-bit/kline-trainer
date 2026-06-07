// C8b H1 production handler 集成测试（Wave 2 顺位 7 下半）—— 闭合 spec §C1b 闸门 #4 F3 Wave 2 验收。
// 三模块在场：C2 DecelerationAnimator + E5a/E5b TrainingEngine + C8 RenderStateBuilder/ChartContainerView。
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("H1 production handler 集成（animator.stop → range → setDrawingSnapshot）")
struct TrainingEngineDrawingHandlerH1Tests {

    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    static let ref: CGFloat = 1.0 / 120.0

    // MARK: H1-1 range 取冻结 offset + 驱动已失活
    // 注（F2 诚实化）：`DecelerationAnimator.stop()` 只置 isDecelerating=false / 失活驱动，**不改 offset**
    // （animator L84-89）→ 「先 stop 再算 range」对 snapshot 的 range *值* 是顺序无关的（同步 handler 无插帧）。
    // 本测试**不**声称证明时序顺序；它证明：① 驱动确被 stop（失活）② range 来自冻结 offset。
    // 真正 load-bearing 的「stop-before-return（停后无未来漂移）」由 H1-2 证明。

    @Test("activateDrawing：range 取冻结 offset + 驱动已失活（非时序证明，见上注）")
    func rangeUsesFrozenOffsetAndDriverDeactivated() {
        let (e, fakes) = TrainingEngineInteractionTests.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 30, panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)              // 启动减速
        let upperFake = fakes()[0]
        _ = upperFake.fire(Self.ref)                         // 减速跑一帧 → offset 进一步漂移
        // 捕获激活时刻的「预期 range」（仍 freeScrolling、offset=漂移后值）
        let psAtActivation = e.upperPanel
        let expected = RenderStateBuilder.visibleCandleRange(
            panelState: psAtActivation, candles: e.allCandles[.m3]!,
            tick: e.tick.globalTickIndex, bounds: Self.bounds)
        e.activateDrawingTool(.trend, panel: .upper)
        #expect(upperFake.isInvalidated == true)             // ① stop 已调（驱动失活）
        guard case .drawing(let snap) = e.upperPanel.interactionMode else {
            Issue.record("应进入 drawing"); return
        }
        #expect(snap.frozen.candleRange == expected)         // ② range 来自冻结 offset
        #expect(snap.frozen.offset == psAtActivation.offset) // offset 冻结一致
    }

    // MARK: H1-2 drawing 后无 offsetApplied 漂移（延迟 animator 回调被 stop 自失活吞掉）

    @Test("drawing 进入后延迟减速帧不漂移 offset（stop 后驱动自失活，无 onUpdate）")
    func staleDecelerationTickAfterDrawingNoDrift() {
        let (e, fakes) = TrainingEngineInteractionTests.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 30, panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)
        let upperFake = fakes()[0]
        _ = upperFake.fire(Self.ref)
        e.activateDrawingTool(.trend, panel: .upper)
        let offsetFrozen = e.upperPanel.offset
        let revFrozen = e.upperPanel.revision
        let fired = upperFake.fire(Self.ref)                 // 延迟帧（stop 后）
        #expect(fired == false)                              // 驱动自失活，不再回调
        #expect(e.upperPanel.offset == offsetFrozen)         // 无漂移
        #expect(e.upperPanel.revision == revFrozen)          // 无额外 bump
    }

    // MARK: H1-3 drawing 模式 reducer 兜底吞 offsetApplied（即便有杂散回调到达）

    @Test("drawing 模式直派 offsetApplied 被吞（reducer 兜底，spec L1123）")
    func drawingModeSwallowsOffsetApplied() {
        let (e, _) = TrainingEngineInteractionTests.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.activateDrawingTool(.trend, panel: .upper)
        guard case .drawing(let snap0) = e.upperPanel.interactionMode else {
            Issue.record("应进入 drawing"); return
        }
        let offsetBefore = e.upperPanel.offset
        e.applyPanOffset(deltaPixels: 99, panel: .upper)     // 模拟杂散 offsetApplied
        #expect(e.upperPanel.offset == offsetBefore)         // 被吞，offset 不变
        guard case .drawing(let snap1) = e.upperPanel.interactionMode else {
            Issue.record("仍应 drawing"); return
        }
        #expect(snap1.frozen.baseRevision == snap0.frozen.baseRevision)
    }

    // MARK: H1-4 drawing 退出后无 offsetApplied 漂移（spec L1182 字面「drawing 退出后」）
    // 退出 drawing 的**生产路径** = 交易硬切（tradeTriggered：drawing→autoTracking，C8b 已实现）。
    // 关键：退出到 autoTracking 后 offsetApplied **不再被吞**（reducer 只在 drawing 吞，L1123），故唯一保护是
    // 「进入 drawing 时 stop 动画 + 交易再 stopAllDeceleration（D7）使其后无减速帧」。本测试正向覆盖 spec 字面
    // 「退出 (exit)」路径（补 F1；drawingCommitted/onTap 提交触发归 Wave 3，此处用已实现的交易退出路径）。

    @Test("drawing 退出（交易→autoTracking）后延迟减速帧不漂移 offset（spec L1182 退出路径）")
    func noOffsetAppliedAfterDrawingExit() {
        let (e, fakes) = TrainingEngineInteractionTests.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 30, panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)            // 启动减速
        let upperFake = fakes()[0]
        _ = upperFake.fire(Self.ref)
        e.activateDrawingTool(.trend, panel: .upper)        // 进 drawing（① stop 动画 → 驱动失活）
        #expect({ if case .drawing = e.upperPanel.interactionMode { return true }; return false }())
        e.holdOrObserve(panel: .upper)                      // 退出：tradeTriggered → autoTracking（生产路径）
        #expect(e.upperPanel.interactionMode == .autoTracking)
        let off = e.upperPanel.offset                       // D8：归零后应为 0
        let fired = upperFake.fire(Self.ref)               // 退出后延迟减速帧
        #expect(fired == false)                            // 驱动早已失活 → 无 onUpdate
        #expect(e.upperPanel.offset == off)                // autoTracking 不吞 offsetApplied，但无帧到达故无漂移
    }
}

// Kline Trainer Swift Contracts — C8 ChartContainerView（@Observable→UIKit 桥接 + C7 手势接线）
// Spec: kline_trainer_modules_v1.4.md §C8 (L1409-1467) + §C7 (L1397-1406)
// Design: docs/superpowers/specs/2026-06-07-pr-c8a-chart-container-render-design.md（C8a 渲染）
//        + docs/superpowers/plans/2026-06-07-pr-c8b-chart-interaction-h1.md（C8b 交互）
//
// 平台门：UIKit-only。macOS swift build 编译为空；Catalyst build-for-testing 落 required CI 闸门。
// spec 实现约束：不订阅 ObservationRegistrar（1）；靠 @Bindable 触发重建（2）；KLineView 只收值类型（3）；
// buildRenderState 算值域（4，RenderStateBuilder）；不监听 scenePhase（5）。
// C8b：Coordinator 持 C7 ChartGestureArbiter，attach-once，把手势回调路由进 engine（D1）；
//      长按十字光标为视图层瞬态（Coordinator 本地 + make(crosshair:) 透传，D3）。

#if canImport(UIKit)
import SwiftUI
import UIKit
import CoreGraphics

public struct ChartContainerView: UIViewRepresentable {
    public let panel: PanelId
    @Bindable public var engine: TrainingEngine
    /// RFC-C 跨面板光标互斥：当前持有十字光标的面板（nil=无）。共享 view-state（**不进 engine**，守 spec §4.2 原则）。
    @Binding public var crosshairOwner: PanelId?

    /// `crosshairOwner` 默认 `.constant(nil)`：保旧 2-arg `init(panel:engine:)` 源兼容（public API 不破坏，codex WB-high）；
    /// TrainingView 传真 binding 启用跨面板互斥，其余调用方（含测试 2-arg）走默认=无跨面板协调。
    public init(panel: PanelId, engine: TrainingEngine, crosshairOwner: Binding<PanelId?> = .constant(nil)) {
        self.panel = panel
        self._engine = Bindable(wrappedValue: engine)
        self._crosshairOwner = crosshairOwner
    }

    public func makeCoordinator() -> Coordinator { Coordinator(panel: panel, engine: engine) }

    public func makeUIView(context: Context) -> KLineView {
        let view = KLineView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    public func updateUIView(_ view: KLineView, context: Context) {
        // 每次重建刷新 Coordinator 的 engine/panel 引用（ChartContainerView 是值类型，可能换 engine）。
        // RFC-C：传当前 crosshairOwner（跨面板互斥读）+ 刷新 setter（Coordinator 写共享态，仅手势回调/延后触发）。
        context.coordinator.sync(panel: panel, engine: engine, view: view,
                                 crosshairOwner: crosshairOwner,
                                 setCrosshairOwner: { crosshairOwner = $0 })
        // codex R3-F1：observation 路径与 layout 路径共用同一带 guard 的 rebuild helper（消除无效 bounds
        // guard 在两路径漂移；SwiftUI 在视图瞬态零尺寸期触发 updateUIView 也不会 clamp offset 吞滚动位置）。
        context.coordinator.rebuildRenderState(bounds: view.bounds)
    }

    /// C7 手势仲裁接线（spec §C7 + plan v1.5 §手势仲裁规则）。持 arbiter + 视图层十字光标本地状态。
    @MainActor
    public final class Coordinator {
        private var panel: PanelId
        private weak var engine: TrainingEngine?
        private weak var view: KLineView?
        private let arbiter = ChartGestureArbiter()
        /// Wave 3 顺位 4：画线输入暂存（仅 .horizontal）+ 逆映射 controller。manager 是输入暂存，
        /// engine.drawings 才是单一真相（spec §D-MANAGER）。
        private let manager = DrawingToolManager(enabledTools: [.horizontal])
        private let inputController: DrawingInputController = DefaultDrawingInputController()
        /// 视图层瞬态十字光标（D3，不进 engine）。RFC-C：黏滞——长按进入、点击才清。
        public private(set) var crosshairPoint: CGPoint?
        /// RFC-C 黏滞模式是否激活（= crosshairPoint 已置且未点击退出）。
        private var crosshairActive = false
        /// RFC-C 吸附 haptic 去重：上次吸附到的 candle index。
        private var lastSnappedIndex: Int?
        /// RFC-C 吸附震动发生器（UIKit）。
        private let snapHaptic = UIImpactFeedbackGenerator(style: .light)
        /// RFC-C 跨面板光标互斥：写共享 crosshairOwner（updateUIView 每帧刷新；仅手势回调/延后调用，不在 view-update 期同步改 @State）。
        private var setCrosshairOwner: ((PanelId?) -> Void)?
        /// RFC-E follow-up（tap-anywhere）：上一次 sync 观察到的共享 owner（供 self→nil 跃迁判定 + 谓词读）。
        private var lastSyncedOwner: PanelId?

        public init(panel: PanelId, engine: TrainingEngine) {
            self.panel = panel
            self.engine = engine
        }

        /// updateUIView 每次调：刷新引用（值类型 ChartContainerView 可能携新 engine/panel）。
        func sync(panel: PanelId, engine: TrainingEngine, view: KLineView,
                  crosshairOwner: PanelId? = nil,
                  setCrosshairOwner: ((PanelId?) -> Void)? = nil) {
            self.panel = panel
            self.engine = engine
            self.view = view
            self.setCrosshairOwner = setCrosshairOwner
            view.panel = panel                                    // Wave 3 13c-R1：draw 区间归属上/下
            // RFC-C 跨面板互斥 + RFC-E tap-anywhere 对称退出（纯函数决策，含 standalone 黏滞持久性门控）。
            switch CrosshairTapResolver.resolveSyncExit(incomingOwner: crosshairOwner,
                                                        previousOwner: lastSyncedOwner,
                                                        panel: panel, crosshairActive: crosshairActive) {
            case .exitTakenOver, .exitOwnerCleared:
                exitCrosshair(releaseOwnership: false)   // owner 已是对方/nil，本面板仅清自身不重写共享态
            case .none:
                break
            }
            lastSyncedOwner = crosshairOwner             // 末尾刷新：下次 sync 的 previousOwner
            // drawing 模式下 arbiter 截获单指 pan（spec §C7）+ 对齐 manager.activeTool（顺位 4）。
            let drawing = isDrawing(engine: engine, panel: panel)
            if drawing && crosshairActive {                       // RFC-C：进画线模式先退黏滞光标（双向互斥，codex R5-M2）
                exitCrosshair(releaseOwnership: false)            // 本地清（view-update 期安全）
                let release = setCrosshairOwner
                DispatchQueue.main.async { release?(nil) }        // 释放共享 owner 延后到 update 后（不在 view-update 期改 @State）
            }
            arbiter.drawingMode = drawing
            if drawing {
                if manager.activeTool == nil { manager.toggle(.horizontal) }     // 进入：对齐（条件 toggle，非每帧盲翻）
            } else if manager.activeTool != nil {
                manager.cancel()                                                  // 退出：复位暂存
            }
        }

        /// attach-once（C7 R6 幂等）：makeUIView 调一次；路由 5 类回调进 engine。
        func attach(to view: UIView) {
            self.view = view as? KLineView
            self.view?.panel = panel                              // Wave 3 13c-R1：首帧前初值（sync 后续刷新）
            // Wave 3 修 #2：layout 拿到有效 bounds 时用当前 engine 重算 renderState。
            // 静态 engine（Review：tick 冻结无 observation 触发 updateUIView）首帧零 bounds → .empty 后永不重算致空白；
            // 本回调补此路径（attach-once，闭包读 self.engine/self.panel，sync 后续刷新引用故恒为当前值）。
            self.view?.onBoundsChange = { [weak self] bounds in
                self?.rebuildRenderState(bounds: bounds)
            }
            arbiter.onPan = { [weak self] deltaX, velocityX, phase in
                guard let self, let engine = self.engine, let view = self.view else { return }
                switch phase {
                case .began:   engine.beginPan(panel: self.panel)
                case .changed:   // R1b-wire：传 view.bounds，engine 内部算边界 + drag full-clamp（D1）
                    engine.applyPanOffset(deltaPixels: deltaX, renderBounds: view.bounds, panel: self.panel)
                case .ended:     // R1b-wire：传 view.bounds，engine 内部算边界 + 机制 A 速度方向分派
                    engine.endPan(velocity: velocityX, renderBounds: view.bounds, panel: self.panel)
                case .cancelled: engine.cancelPan(panel: self.panel)
                }
            }
            // RFC-C：two-finger 不再切周期（改单指竖滑）——不接 onTwoFingerSwipe。
            arbiter.onVerticalSwipe = { [weak self] swipe in
                guard let self, let engine = self.engine else { return }
                engine.switchPeriodCombo(direction: periodDirection(for: swipe))
            }
            arbiter.onLongPress = { [weak self] location, phase in
                guard let self else { return }
                switch phase {
                case .began:
                    guard let engine = self.engine, !self.isDrawing(engine: engine, panel: self.panel) else { return }
                    self.enterCrosshair(at: location)            // drawing 优先：drawing 时不进光标
                case .changed:
                    if self.crosshairActive { self.moveCrosshair(to: location) }
                case .ended, .cancelled:
                    break                                         // 黏滞：松手保留，不清
                }
            }
            arbiter.onCrosshairMove = { [weak self] location in
                guard let self, self.crosshairActive else { return }
                self.moveCrosshair(to: location)                 // 松手后再拖动移光标（图仍冻结）
            }
            arbiter.onCrosshairExit = { [weak self] in
                self?.exitCrosshair()
            }
            arbiter.onShouldExitRemoteCrosshair = { [weak self] in
                guard let self else { return false }
                // 「有**别的**面板持光标」——必须排除自持（codex WB-3）：drawing 激活的异步 owner 释放窗口内
                // crosshairMode 已 false 但 lastSyncedOwner 仍==自己，若不排除会把首个画线 tap 误判成退光标吞掉。
                return CrosshairTapResolver.remoteOwnerPresent(syncedOwner: self.lastSyncedOwner, panel: self.panel)
            }
            arbiter.onPinch = { [weak self] scale, focus, phase in
                guard let self, let engine = self.engine else { return }
                engine.applyPinch(scale: scale, focusX: focus.x, phase: phase, panel: self.panel)
            }
            arbiter.onTap = { [weak self] point in
                self?.handleDrawingTap(at: point)
            }
            arbiter.attach(to: view)
        }

        /// Wave 3 修 #2：bounds 依赖渲染的**唯一**入口——updateUIView（observation 驱动）与 KLineView.layoutSubviews
        /// （layout 驱动，经 onBoundsChange）都经此。先记录 bounds 再 make，含无效 bounds guard（两路径不漂移）。
        /// 覆盖静态界面（Review）无 observation 触发 updateUIView 的路径 + observation/layout 瞬态零尺寸的 offset 保护。
        func rebuildRenderState(bounds: CGRect) {
            guard let view, let engine else { return }
            // codex R2-F1：瞬态零尺寸 layout（导航/分屏/旋转过渡）不得改 engine 状态。recordRenderBounds(.zero)
            // 会被当 resize → 零宽 offsetBounds → 把 panel offset clamp 到 0（吞掉用户滚动位置，不可逆）；
            // make(.zero) 也只返 .empty。故无效 bounds 直接早返——零→有效的后续 layout 仍会重建（lastLaidOutBounds 已记 .zero）。
            guard bounds.width > 0, bounds.height > 0 else { return }
            // codex R1-F1：与 updateUIView 同序先记录 bounds——pinch（读 engine 缓存 bounds，无 bounds 入参）/
            // 画线 range / resize 归一都依赖 lastRenderedBounds。静态界面（Review）只走本路径，若不同步则
            // 缓存停在 .zero → 出图后 pinch no-op。recordRenderBounds 内 `previous!=bounds` 守卫保幂等，不扰常态。
            engine.recordRenderBounds(bounds, panel: panel)
            let makeToken = RenderSignposter.beginMake(panel: panel)
            let newState = RenderStateBuilder.make(
                engine: engine, panel: panel, bounds: bounds, crosshair: crosshairPoint)
            RenderSignposter.end(makeToken)
            view.renderState = newState
        }

        private func isDrawing(engine: TrainingEngine, panel: PanelId) -> Bool {
            let mode = (panel == .upper) ? engine.upperPanel.interactionMode : engine.lowerPanel.interactionMode
            if case .drawing = mode { return true }
            return false
        }

        /// 设置/清空十字光标并即时重渲染（视图层瞬态，不经 SwiftUI observation）。
        private func setCrosshair(_ point: CGPoint?) {
            crosshairPoint = point
            guard let view, let engine else { return }
            // Wave 3 13c-R1：crosshair 旁路 make 用独立区间名（make-crosshair-*），与 update-pass make 分离
            let makeToken = RenderSignposter.beginMakeCrosshair(panel: panel)
            let newState = RenderStateBuilder.make(
                engine: engine, panel: panel, bounds: view.bounds, crosshair: point)
            RenderSignposter.end(makeToken)
            view.renderState = newState
        }

        /// RFC-C 进入黏滞十字光标：**先守卫（仅主图区 + 有效渲染态）再置状态**——防 volume/MACD/轴区
        /// 长按导致「隐形冻结」（codex M1）。守卫不过 = no-op，不冻结、不置 crosshairMode。
        private func enterCrosshair(at location: CGPoint) {
            guard let view else { return }
            let vp = view.renderState.viewport
            guard vp.geometry.candleStep > 0,
                  !view.renderState.visibleCandles.isEmpty,
                  vp.mainChartFrame.contains(location) else { return }   // 非主图区 → 不进光标、不冻结
            crosshairActive = true
            arbiter.crosshairMode = true
            setCrosshairOwner?(panel)              // RFC-C：宣示持有光标 → 另一面板 sync 见 owner≠自己即退出（跨面板互斥）
            snapHaptic.prepare()
            lastSnappedIndex = nil
            moveCrosshair(to: location)
        }

        /// RFC-C 移动光标：**先守卫（主图区内）再刷新**；出主图区则忽略本次移动（保留上次有效位置，不消失）。
        /// 吸附 index 变化时震一次（去重）。
        private func moveCrosshair(to location: CGPoint) {
            guard let view else { return }
            let vp = view.renderState.viewport
            guard vp.geometry.candleStep > 0,                            // 空图守卫（Int(NaN) 防崩）
                  !view.renderState.visibleCandles.isEmpty,
                  vp.mainChartFrame.contains(location) else { return }   // 出主图区忽略本次（保留上次）
            setCrosshair(location)                                       // 既有：置点 + rebuild renderState
            let mapper = CoordinateMapper(viewport: vp, displayScale: view.traitCollection.displayScale)
            let idx = CrosshairLayout.snappedCandleIndex(at: location.x, mapper: mapper,
                                                         candles: view.renderState.visibleCandles)
            if idx != lastSnappedIndex {                                 // 每根一次（去重）
                snapHaptic.impactOccurred()
                lastSnappedIndex = idx
            }
        }

        /// RFC-C 退出黏滞：清光标 + arbiter 解冻 + 复位 haptic 去重。
        /// `releaseOwnership`：user 主动退出（点击）/进画线 → true 释放共享 owner；被另一面板接管退出 → false（对方持有，不碰）。
        private func exitCrosshair(releaseOwnership: Bool = true) {
            crosshairActive = false
            arbiter.crosshairMode = false
            lastSnappedIndex = nil
            setCrosshair(nil)
            if releaseOwnership { setCrosshairOwner?(nil) }
        }

        /// 顺位 4：drawing 模式单指点击落锚 → 投影 engine.drawings/reviewDrawings → 退出 .drawing。
        /// 全链路：tapToAnchor（逆映射）→ manager.addAnchor/commit → engine.routeDrawingCommit → engine.commitDrawing。
        /// review-redesign Task 10：投影目标改经 `routeDrawingCommit`——review 模式写 `reviewDrawings`，
        /// 其余（normal/replay）写 `drawings`，防止复盘新画线污染原训练记录。
        private func handleDrawingTap(at point: CGPoint) {
            guard let engine, let view else { return }
            guard isDrawing(engine: engine, panel: panel), manager.activeTool != nil else { return }
            // 空图表（candleStep==0）→ xToIndex 会 Int(NaN) 崩溃 → 守卫（spec §四 load-bearing）。
            let viewport = view.renderState.viewport
            guard viewport.geometry.candleStep > 0 else { return }
            let mapper = CoordinateMapper(viewport: viewport, displayScale: view.traitCollection.displayScale)
            let ps = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
            let anchor = inputController.tapToAnchor(at: point, panel: ps, mapper: mapper)
            manager.addAnchor(anchor)
            guard inputController.shouldCommit(current: manager.pendingAnchors, tool: .horizontal) else { return }
            manager.commit(isExtended: true, panelPosition: panel == .upper ? 0 : 1)
            if let committed = manager.completedDrawings.last {
                engine.routeDrawingCommit(committed)          // review→reviewDrawings；否则→drawings（Task 10）
            }
            engine.commitDrawing(panel: panel)               // 退出 reducer .drawing
        }
    }
}
#endif

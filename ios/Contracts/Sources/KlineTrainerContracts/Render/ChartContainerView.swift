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
        /// P1b-1a-ii D39：画线状态**不再**由 Coordinator 私有持有 —— 真相在 `engine.drawingSession`
        /// （共享容器）。Coordinator 只做「tap → 锚点」的逆映射与投影，不存任何画线状态。
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
            // drawing 模式下 arbiter 截获单指 pan（spec §C7）。
            // P1b-1a-ii D39：**单向**从真相读 —— sync 绝不回写画线状态。
            // 原 `if manager.activeTool == nil { manager.toggle(.horizontal) }` 自动 re-arm 已删除：
            // 它会在**每一次** updateUIView 撤销底栏的工具选择（codex R15-high）。
            let drawing = isDrawing(engine: engine)
            if drawing && crosshairActive {                       // RFC-C：进画线模式先退黏滞光标（双向互斥，codex R5-M2）
                exitCrosshair(releaseOwnership: false)            // 本地清（view-update 期安全）
                let release = setCrosshairOwner
                DispatchQueue.main.async { release?(nil) }        // 释放共享 owner 延后到 update 后（不在 view-update 期改 @State）
            }
            arbiter.drawingMode = drawing
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
                    guard let engine = self.engine, !self.isDrawing(engine: engine) else { return }
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
            self.view?.onTouchDown = { [weak self] point in
                self?.captureNodeDragCandidate(at: point)
            }
            self.view?.onMultiTouchBegan = { [weak self] in
                self?.nodeDragCandidate = nil            // D140c fail-closed
            }
            arbiter.onHasNodeDragCandidate = { [weak self] in
                self?.acceptNodeDragCandidate() ?? false
            }
            arbiter.onNodeDrag = { [weak self] translation, phase in
                self?.handleNodeDrag(translation: translation, phase: phase)
            }
            arbiter.attach(to: view)
        }

        /// Wave 3 修 #2：bounds 依赖渲染的**唯一**入口——updateUIView（observation 驱动）与 KLineView.layoutSubviews
        /// （layout 驱动，经 onBoundsChange）都经此。先记录 bounds 再 make，含无效 bounds guard（两路径不漂移）。
        /// 覆盖静态界面（Review）无 observation 触发 updateUIView 的路径 + observation/layout 瞬态零尺寸的 offset 保护。
        func rebuildRenderState(bounds: CGRect) {
            guard let view, let engine else { return }
            // ⚠️ P1b-1a-ii 回归修复（真机/模拟器实证：拖动后 offset 变了、K 线图却冻结不重画）：
            // SwiftUI 用 withObservationTracking 包裹 updateUIView，**只订阅其执行时实际读取的 @Observable**。
            // 首帧 view.bounds 常为 0 → 下面的 make 被 `bounds > 0` 守卫跳过 → 未读任何面板渲染状态 → 未建立订阅
            // → 之后 pan / 切周期 / 买入改变的 upper/lowerPanel（offset/period/interactionMode，均 bump revision）
            // 都不再触发 updateUIView → 图永久冻结（直到某次 bounds 恰变化、走 layout 路径才偶然重画）。
            // 改造前 sync 读 `panelState.interactionMode` **隐式**承担了这个订阅；本期把 sync 判据改成读
            // `drawingSession.drawingModeActive` 后订阅丢失。故在 bounds 守卫**之前**无条件读一次面板 revision
            // + tick 显式重建订阅（值类型 PanelViewState 任一字段变即整体替换 → 通知；layout 路径读了无副作用）。
            _ = (panel == .upper) ? engine.upperPanel.revision : engine.lowerPanel.revision
            _ = engine.tick.globalTickIndex
            // 1b-i PR-3：选中态进了 KLineRenderState（D41/D55）→ **两个面板**都必须订阅它，
            // 否则「在另一个面板选中」时，本面板缓存的旧 selectedDrawingID 不会被刷掉，旧高亮留在屏上。
            // 与上面两行同理由、同位置（bounds 守卫**之前**）：`make` 在 bounds<=0 时被跳过，
            // 把读取留在 make 里就等于首帧不订阅（`:176-185` 记录的那次真机冻结回归就是这么来的）。
            _ = engine.drawingSession.selectedPanel
            _ = engine.drawingSession.selectedDrawingID
            // codex R2-F1：瞬态零尺寸 layout（导航/分屏/旋转过渡）不得改 engine 状态。recordRenderBounds(.zero)
            // 会被当 resize → 零宽 offsetBounds → 把 panel offset clamp 到 0（吞掉用户滚动位置，不可逆）；
            // make(.zero) 也只返 .empty。故无效 bounds 直接早返——零→有效的后续 layout 仍会重建（lastLaidOutBounds 已记 .zero）。
            guard bounds.width > 0, bounds.height > 0 else {
                // codex R2-M2 fix：这条早退发生在 mapper 发布（下方 `setViewportMapper`）之前——若不清，
                // `DrawingSession.viewportMappers` 会保留上一帧的旧值，几何门（`DrawingEditRouter`）拿它
                // 误判「此刻仍可见」。失败方向不安全：可能放行 `deleteSelected`/`applyStyle`，而当下
                // 根本没有任何有效渲染视口。⚠️ 只清 mapper（DrawingSession 的 `@ObservationIgnored`
                // 纯 UI 状态）——绝不碰 engine，理由与上面这条早退存在的原因相同（`recordRenderBounds(.zero)`
                // 会吞掉用户滚动位置，不可逆）。
                engine.drawingSession.clearViewportMapper(panel: panel)
                refreshSelectionGeometryHint(engine: engine)
                return
            }
            // codex R1-F1：与 updateUIView 同序先记录 bounds——pinch（读 engine 缓存 bounds，无 bounds 入参）/
            // 画线 range / resize 归一都依赖 lastRenderedBounds。静态界面（Review）只走本路径，若不同步则
            // 缓存停在 .zero → 出图后 pinch no-op。recordRenderBounds 内 `previous!=bounds` 守卫保幂等，不扰常态。
            engine.recordRenderBounds(bounds, panel: panel)
            let makeToken = RenderSignposter.beginMake(panel: panel)
            let newState = RenderStateBuilder.make(
                engine: engine, panel: panel, bounds: bounds, crosshair: crosshairPoint)
            RenderSignposter.end(makeToken)
            view.renderState = newState
            // PR-4（PD1/PD2）：发布**这一帧真的用过**的视口 —— SwiftUI 层（🗑 / 样式面板）没有 mapper，
            // 而重新推导会与 `make` 的聚合分支（重算 priceRange）分叉。
            let session = engine.drawingSession
            if newState.visibleCandles.isEmpty {
                // codex R2-M2 fix 顺带项（已实测坐实，非猜测）：本面板此刻没有 candles → `make` 返回
                // `.empty`，其 `mainChartFrame` 全零。这种退化视口对 `.straight` 子类型**不会**
                // fail-closed —— `priceToY` 在 `frame.height==0` 时恒算出 `y=0`，而 `frame.minY==maxY==0`
                // 让 `y∈[minY,maxY]` 恒真，`visibleGeometry` 因此返回非 nil 的退化几何
                // （`(y:0,minX:0,maxX:0)`），不是 nil。发布这种 mapper 会让几何门在"图根本没数据"时
                // 仍判「可见」。故同样清掉、不发布。
                session.clearViewportMapper(panel: panel)
            } else {
                session.setViewportMapper(
                    CoordinateMapper(viewport: newState.viewport,
                                     displayScale: view.traitCollection.displayScale), panel: panel)
            }
            refreshSelectionGeometryHint(engine: engine)
        }

        /// PD2：只在值真的变了时才刷新几何提示（延后到 view-update 期之后写 `@Observable`）。
        /// 三处调用共用同一份，避免各写一遍漂移——正常渲染完之后 / 无效 bounds 早退 / 本面板尚无
        /// candles，`rebuildRenderState` 这三个分支都会让 mapper 变化，提示都要跟着走。
        /// 置灰提示：只有**选中所在的那个面板**负责刷新（另一个面板的视口与它无关），
        /// 且只在值**真的会变**时才派发（平移每帧都派发 = 无谓开销）。
        /// ⚠️ **必须延后一个 runloop**：本函数的调用点之一是 `updateUIView`（视图更新期），
        ///    期间改 @Observable 是 SwiftUI 明令的未定义行为；`:105` 释放 crosshairOwner 用的是
        ///    同一条逃生门。提示晚一拍无害——真正的门是路由在写入瞬刻的那次重算（PD2）。
        private func refreshSelectionGeometryHint(engine: TrainingEngine) {
            let session = engine.drawingSession
            guard session.selectedPanel == panel,
                  DrawingEditRouter.selectionGeometryVisible(engine: engine) != session.selectionGeometryVisible
            else { return }
            DispatchQueue.main.async { [weak engine] in
                guard let engine else { return }
                // 在**执行时**重算，不用捕获的旧值（期间状态可能又变了）。
                engine.drawingSession.setSelectionGeometryVisible(
                    DrawingEditRouter.selectionGeometryVisible(engine: engine))
            }
        }

        /// P1b-1a-ii D42：「现在能不能画」的**唯一判据** = 全局会话开关。
        /// **不得**再读面板 `interactionMode` 作第二判据（两个判据必然漂移；引擎侧不变量
        /// 「drawingModeActive ⇔ 两面板 .drawing」由 begin/endDrawingSessionIfActive 维持）。
        private func isDrawing(engine: TrainingEngine) -> Bool {
            engine.drawingSession.drawingModeActive
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

        /// P1b-1a-ii：drawing 模式单指点击落锚 → 投影 engine.drawings/reviewDrawings。
        /// 全链路：tapToAnchor（逆映射）→ drawingSession.addAnchor（归属=**被点的这个面板**，D42）
        ///        → shouldCommit → DrawingEditRouter.commitPendingAndSelect → rebuildRenderState（D85）。
        /// **不再调 engine.commitDrawing(panel:)** —— 那会退出 `.drawing`，即旧的「画一条就退出」（D38）。
        /// 测试入口：`handleDrawingTapForTesting`（internal；生产路径仍只经 arbiter.onTap）。
        func handleDrawingTapForTesting(at point: CGPoint) { handleDrawingTap(at: point) }

        private func handleDrawingTap(at point: CGPoint) {
            guard let engine, let view else { return }
            let session = engine.drawingSession
            guard session.drawingModeActive, let tool = session.activeDrawingTool else { return }
            // 1a-iv（codex plan-R2-high）：画线模式现在可以有惯性。**顺序 load-bearing**：
            //   ① 停两面板减速 + 归一 → ② 重建 renderState（让 viewport 与已 settle 的 offset 一致）
            //   → ③ 才能拿 viewport 做映射。漏掉②等于没修：viewport 仍是停之前那一帧的。
            // 语义选「点一下先截住惯性」而非「惯性期间拒收 tap」：后者会让用户在图还在滑时点了没反应。
            engine.settleDeceleration(initiatedBy: panel)
            rebuildRenderState(bounds: view.bounds)
            // 空图表（candleStep==0）→ xToIndex 会 Int(NaN) 崩溃 → 守卫（spec §四 load-bearing）。
            let viewport = view.renderState.viewport
            guard viewport.geometry.candleStep > 0 else { return }
            // 1a-iii 切片2 Task2（codex 计划-R14-F1/R17-F2）：三态互斥，无需再判布尔量。
            // `.pending` = 面板已挂载但几何未收敛 → 拒收一切（代价：刚展开面板的极短瞬间少响应一次点击；
            // 收益：**永远不会**因盾未就位而落出幽灵线并 autosave，不可逆）。`.rect` 是面板局部坐标，与 point 同一空间。
            switch session.shield[panel == .upper ? 0 : 1] ?? .unshielded {
            case .unshielded:      break
            case .pending:         return
            case .rect(let shield): if shield.contains(point) { return }
            }
            let mapper = CoordinateMapper(viewport: viewport, displayScale: view.traitCollection.displayScale)
            // D38/D54（1b-i PR-3）：盾之后才分叉 —— 落在面板上的点击**既不落锚、也不选中**（D53）。
            switch session.mode {
            case .draw:
                let ps = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
                guard let anchor = inputController.tapToAnchor(at: point, panel: ps, mapper: mapper) else { return }
                session.addAnchor(anchor, panel: panel)          // D31：落在 ≠ pendingAnchorPanel 的面板 → 容器内部只丢 pending
                // D83 分支 3 的边界（spec §3.4）：`shouldCommit` 是「还没发起提交」与「已尝试提交」的
                // 天然分水岭。它之前返回 = 连锚都没成形 → **不动选中**（一次误触不该夺走选中，
                // 而画线态无法重新选中：D38 画线态恒不做命中判定）。
                guard inputController.shouldCommit(current: session.pendingAnchors, tool: tool) else { return }
                // D85：整段「尝试提交」收口进路由 —— 四道 guard 变一次调用，UIKit-gated 文件里的判据
                // **净减少两条**；分支 2 的六条出口从此在同一个函数体内，host `swift test` 就能验。
                // ⚠️ **不得**在这里另写 clearSelection（spec §3.4 明令）：判据散进三处、其中两处
                //    在本文件里（host 上不编译），且「三处保持一致」没有任何机制保证。
                DrawingEditRouter.commitPendingAndSelect(panel: panel, mapper: mapper, engine: engine)
                // ⚠️ 选中态变了必须**立刻**重建渲染态（理由与下面 `.select` 分支那一句逐字相同，spec §5.3）：
                //    本函数开头的 `rebuildRenderState` 发生在选中改变**之前**，而高亮渲染读的是
                //    `KLineRenderState.selectedDrawingID` → 不补这一次重建，本帧画出来的还是旧选中。
                //    **不要**改成依赖 SwiftUI observation 顺带刷新：Coordinator 这条直连路径不经
                //    `updateUIView`，那样等于没有证据。
                rebuildRenderState(bounds: view.bounds)
                // ← 此处**故意没有** engine.commitDrawing(panel:)：连续画线（D38），会话与工具保持不变。

            case .select:
                // D34 / spec §4（**trust-boundary**）：复盘**不得**获得选中能力 —— 复盘的选中要带
                // `(layer, id)` 层权限门控，那是 P5；本期若放行，复盘就能改写**已归档 record 里的原训练线**。
                // ⚠️ 门**只包这一支**：`.draw` 在复盘下照常落线（浮动铅笔钮，1a-iii 起的既有功能）。
                //    把 guard 提到 switch 之前 = 复盘画线功能回归 —— 与 PR-1 那道 `.segment` 门误管所有
                //    工具是同一类错误：fail-closed 的门必须限定到它真适用的那一类。
                guard engine.flow.mode != .review else { return }
                // P1c 第 3 片 Task 11（订正 3，Task 6 传下来的裁定，spec D135c `:253`）：
                // 「点击造成的选中变更」范围明写包含「tap 未命中时的清空」——但 `clearSelection()`
                // 内部会连带 `endNodeDrag()`（D135c 的生命周期语义：没有选中 ⇒ 不可能有拖动）。
                // ⇒ 拖动进行中，另一只手在空白处点一下，会把正在进行的拖动**悄悄作废**，而 D138
                // 对「第二根手指」定的是**就地定住**，不是作废 —— 这条路径不经 `setSelection` /
                // `setCommittedSelection`（那两个各自有 `tapSelectionAllowed` 守卫），必须单独挡。
                // ⛔ 只挡 `.select` 这一支（落锚 `.draw` 分支不受影响，超出 D135c 范围）；
                // ⛔ 复用 Task 5 的既有判据，不新写一份「拖动中」判断。
                guard !DrawingEditRouter.nodeDragInFlight(engine: engine) else { return }
                // D40：命中集合 ≡ 渲染集合 —— 同一个 `visibleDrawings`、同一张 `drawingTools` 注册表。
                let ordered = RenderStateBuilder.visibleDrawings(
                    engine: engine, panel: panel, tick: engine.tick.globalTickIndex)
                if let hit = DrawingHitTester.firstHit(in: ordered, point: point, mapper: mapper,
                                                       tools: KLineView.drawingTools) {
                    session.setSelection(id: hit.id, panel: panel)   // 命中 → 选中它（替换原选中）
                } else {
                    session.clearSelection()                         // D37：未命中 → 先清空选中，**且不落锚**
                }
                // ⚠️ 选中态变了必须**立刻**重建渲染态（codex plan-R3-F2）：本函数开头 `:280` 的
                //    `rebuildRenderState` 发生在选中改变**之前**，而高亮渲染读的是
                //    `KLineRenderState.selectedDrawingID` → 不补这一次重建，本帧画出来的还是旧选中。
                //    `KLineRenderState` 是 `Equatable` 且 `KLineView.renderState` 有
                //    `didSet { guard renderState != oldValue else { return }; setNeedsDisplay() }`
                //    （`KLineView.swift:16-21`）→ 只有 `selectedDrawingID` 变了的新状态照样触发重绘，
                //    没变则不重绘（无多余绘制）。**不要**改成依赖 SwiftUI observation 顺带刷新：
                //    Coordinator 这条直连路径不经过 `updateUIView`，那样等于没有证据。
                rebuildRenderState(bounds: view.bounds)
            }
        }

        /// P1c 第 3 片（D140b）：按下那一刻捕获的候选，供 `.began` 复核（`acceptNodeDragCandidate`）。
        /// ⛔ 瞬时态，绝不落盘、不进 `DrawingSession`——那边 `nodeDragOwner` 才是真正占槽的那份（D135）。
        private var nodeDragCandidate: DrawingSession.NodeDragOwner?

        /// D140b：**手指按下那一刻**捕获候选。⛔⛔ 本函数零 engine 写入 —— 用的是
        /// `view.renderState.viewport`（= 屏幕上**正在显示**的那一帧，就是用户看着按下去的那一帧）。
        /// ⚠️ 它是**上一帧**的结果，惯性快速滑动时与手指落下那一瞬最多差**一帧**；这是 UIKit
        ///    触摸模型下的下界，⛔ 不得声称「精确」。它替代的是「一个 deadzone + 一次 overscroll
        ///    夹取」的误差，数量级小一到两个档（spec D140b 末段，如实登记）。
        private func captureNodeDragCandidate(at point: CGPoint) {
            nodeDragCandidate = nil                       // 新按下**直接覆盖**旧候选（D140c）
            guard let engine, let view else { return }
            let vp = view.renderState.viewport
            guard vp.geometry.candleStep > 0 else { return }
            guard DrawingEditRouter.nodeDragPreconditions(engine: engine, panel: panel, point: point)
            else { return }
            guard let id = engine.drawingSession.selectedDrawingID,
                  let drawing = RenderStateBuilder.visibleDrawings(
                      engine: engine, panel: panel, tick: engine.tick.globalTickIndex)
                      .last(where: { $0.id == id }),
                  let tool = KLineView.drawingTools[drawing.toolType] else { return }
            let mapper = CoordinateMapper(viewport: vp, displayScale: view.traitCollection.displayScale)
            guard let idx = DrawingNodeGeometry.hitTestNode(
                point: point, drawing: drawing, mapper: mapper,
                isVisible: tool.isVisible(drawing: drawing, mapper: mapper),
                maxAnchors: tool.requiredAnchors.upperBound) else { return }
            nodeDragCandidate = .init(panel: panel, drawingID: id, anchorIndex: idx, grabPoint: point)
        }

        /// pan `.began` 的 **fail-closed 复核**（D134e）。⛔ **不重做任何几何命中**（D140b）。
        private func acceptNodeDragCandidate() -> Bool {
            guard let engine, let c = nodeDragCandidate else { return false }
            guard DrawingEditRouter.nodeDragPreconditions(
                    engine: engine, panel: panel, point: c.grabPoint) else { return false }
            guard engine.drawingSession.selectedDrawingID == c.drawingID else { return false }
            return true
        }

        /// 测试入口（照 `handleDrawingTapForTesting`（`:323`）的先例）
        func captureNodeDragCandidateForTesting(at point: CGPoint) { captureNodeDragCandidate(at: point) }
        func acceptNodeDragCandidateForTesting() -> Bool { acceptNodeDragCandidate() }
        var nodeDragCandidateForTesting: DrawingSession.NodeDragOwner? { nodeDragCandidate }

        // MARK: - Task 11：拖动三相位接线 + 收尾路径（D138 三分 / D135b 两支失败）

        /// P1c 第 3 片：拖动几何基准的**唯一**取法 —— **提交值**（`engine.drawings`）。
        ///
        /// ⛔⛔ **订正 1（Critical）**：`translation` 是「自手指按下以来的累计位移」
        /// （`DrawingNodeDrag.draggedAnchor` 内部 `old = drawing.anchors[anchorIndex]` 再加
        /// `anchorDelta(translation:)`）。而 `RenderStateBuilder.visibleDrawings` 在拖动进行中会把
        /// 被拖那条的锚点换成**拖动中间值**（Task 10 的 `applyNodeDragOverride`）——若拿它当 `old`，
        /// 上一帧已经叠过的位移会在这一帧被**再加一次**，逐帧复利叠加、节点二次函数式飞走
        /// （报告「订正 1」一节有逐帧实测数字）。
        ///
        /// `visibleDrawings` 仍然要用——但**只用于存在性/可见性判断**：它是渲染/命中的唯一真相
        /// （D40），一条已经结构性不可见（迁到了另一面板 / `revealTick` 未到）的线不该再被拖。
        /// ⛔ 两件事都要、缺一不可：几何基准用提交值，存在性判据用 `visibleDrawings`。
        private func committedDraggableDrawing(drawingID: DrawingID)
            -> (drawing: DrawingObject, tool: any DrawingTool)? {
            guard let engine else { return nil }
            guard RenderStateBuilder.visibleDrawings(
                    engine: engine, panel: panel, tick: engine.tick.globalTickIndex)
                    .contains(where: { $0.id == drawingID })
            else { return nil }
            guard let committed = engine.drawings.first(where: { $0.id == drawingID }),
                  let tool = KLineView.drawingTools[committed.toolType]
            else { return nil }
            return (committed, tool)
        }

        /// `activeNodeDrag()` 的判别结果。**G11**：`.changed` / `.ended` / `.cancelled` 三条相位分支
        /// 共用这一个身份判据，⛔ 分支体内不出现 `selectedDrawingID` / `selectedPanel` 的字面比较——
        /// 把「来源不符」「归属不符」两种失败都折进这一个函数的返回值里，调用方只管 switch。
        private enum NodeDragLookup {
            /// ① 来源不符：槧为空，或本次回调不属于本面板（别人的槧 / 已经陈旧）。
            case notOurs
            /// ② 归属不符：`finalizeNodeDragInPlace` 已经在本函数内部**就地定住 + 清槧**，调用方忽略本次回调。
            case finalized
            /// 几何/工具都齐——正常相位可以继续算这一帧。
            case ready(owner: DrawingSession.NodeDragOwner, drawing: DrawingObject,
                       tool: any DrawingTool, mapper: CoordinateMapper)
            /// ⚠️ 订正 2：归属**对得上**，但 viewport/线/工具任一取不到——**仍然是本面板正在进行的拖动**，
            /// 调用方（终止相位）必须无条件收尾，⛔ 不许当成「忽略」处理。
            case ownedButGeometryUnavailable(owner: DrawingSession.NodeDragOwner)
        }

        /// D135b 的**每帧身份判据**，三条相位分支**调同一个**（G11）。
        private func activeNodeDrag() -> NodeDragLookup {
            guard let engine, let view else { return .notOurs }
            let session = engine.drawingSession
            // ① 先判来源：槧非空 且 本次回调来自 nodeDrag.panel。
            guard let owner = session.nodeDragOwner, owner.panel == panel else { return .notOurs }
            // ② 再判归属：(owner.panel, owner.drawingID) == (selectedPanel, selectedDrawingID)。
            guard owner.drawingID == session.selectedDrawingID,
                  owner.panel == session.selectedPanel else {
                finalizeNodeDragInPlace(owner)
                return .finalized
            }
            let viewport = view.renderState.viewport
            guard viewport.geometry.candleStep > 0,
                  let (drawing, tool) = committedDraggableDrawing(drawingID: owner.drawingID)
            else { return .ownedButGeometryUnavailable(owner: owner) }
            return .ready(owner: owner, drawing: drawing, tool: tool,
                          mapper: CoordinateMapper(viewport: viewport,
                                                   displayScale: view.traitCollection.displayScale))
        }

        /// 收尾的共用写法：**先清槧、再写**（避免覆盖影响写入读到的 `old`）；取不到锚点就只清槧不写
        /// （fail-closed，D138 既有纪律）。`finalizeNodeDragInPlace`（D135b ②）与 `.ended`/`.cancelled`
        /// 的收尾分支**共用**本函数，⛔ 不三处各写一遍。
        private func finalizeAndCommit(owner: DrawingSession.NodeDragOwner, anchor: DrawingAnchor?) {
            guard let engine else { return }
            engine.drawingSession.endNodeDrag()
            if let anchor {
                _ = engine.updateDrawingAnchor(id: owner.drawingID, anchorIndex: owner.anchorIndex, anchor: anchor)
            }
        }

        /// 就地定住：写一次、记一条撤销，与抬手**同一条**收尾语义（D138）。用的是**已有的**
        /// `nodeDragCurrent`（上一帧已夹取好的值），⛔ 不重新算几何——这是「归属已经不对得上」的分支，
        /// 没有可信的「本帧 translation」可用。
        private func finalizeNodeDragInPlace(_ owner: DrawingSession.NodeDragOwner) {
            finalizeAndCommit(owner: owner, anchor: engine?.drawingSession.nodeDragCurrent)
        }

        /// P1c 第 3 片：节点拖动的三个相位。**唯一**调用 `updateDrawingAnchor` 的生产路径。
        private func handleNodeDrag(translation: CGPoint, phase: GesturePhase) {
            guard let engine, let view else { return }
            let session = engine.drawingSession
            switch phase {
            case .began:
                // D140：路由到拖动之后才刹车，顺序与落锚逐字相同（G3 的 ② 分支钉死）。
                engine.settleDeceleration(initiatedBy: panel)
                rebuildRenderState(bounds: view.bounds)
                let viewport = view.renderState.viewport
                guard viewport.geometry.candleStep > 0 else { return }
                let mapper = CoordinateMapper(viewport: viewport, displayScale: view.traitCollection.displayScale)
                // 几何基准用 `committedDraggableDrawing`（提交值 + 可见性判据），理由见该函数头注；
                // 本相位是否受 Task 10 覆盖影响与此无关（下面那道 fail-closed 兜底才是唯一相关的事）。
                guard let c = nodeDragCandidate,
                      let (drawing, tool) = committedDraggableDrawing(drawingID: c.drawingID),
                      let anchor = DrawingNodeDrag.draggedAnchor(
                          drawing: drawing, anchorIndex: c.anchorIndex, translation: translation,
                          mapper: mapper, tool: tool)
                else { nodeDragCandidate = nil; return }
                // spec `:236`/`:665-667`：D135c 之后这一支**实际不可达**——B 压根选不中（全局选中
                // 唯一，拖动要求「选择态 + 有选中」，到不了别的面板/线的 `.began` 占槽路径）——
                // 但 spec 明令**保留为 fail-closed 兜底**：① 将来放宽 D135c（允许拖动中换选中）时，
                // 这是唯一能在下一次 `.began` 收掉残留槧的地方；② 槧一旦因任何原因残留（终止相位
                // 丢失、面板视图在拖动中被 SwiftUI 重建导致 Coordinator 换人），Task 7 的十道写入门
                // 会把底栏永久锁灰，而 `handleDrawingTap` 的 `.select` 分支又被**同一道门**挡住 ⇒
                // 点图表也解不开，用户只能切模式/退出画线自救——这一支堵住的正是「静默丢掉上一次
                // 调整、且界面卡死」这个后果。⛔ 不得因为测不了就删掉它，⛔ 也不得假装测到了。
                if let staleOwner = session.nodeDragOwner {
                    finalizeNodeDragInPlace(staleOwner)
                }
                session.beginNodeDrag(c, anchor: anchor)
                nodeDragCandidate = nil                 // 候选已被消费（D140b 第三行）
                rebuildRenderState(bounds: view.bounds)

            case .changed:
                guard case .ready(let owner, let drawing, let tool, let mapper) = activeNodeDrag()
                else { return }
                guard let anchor = DrawingNodeDrag.draggedAnchor(
                        drawing: drawing, anchorIndex: owner.anchorIndex, translation: translation,
                        mapper: mapper, tool: tool) else { return }
                session.updateNodeDragCurrent(anchor)
                rebuildRenderState(bounds: view.bounds)   // ⛔ 直连重绘：nodeDragCurrent 不参与 observation

            case .ended, .cancelled:
                switch activeNodeDrag() {
                case .notOurs:
                    return                                // ① 陈旧回调/别人的槧 —— 不碰任何状态
                case .finalized:
                    return                                // ② 归属不符 —— activeNodeDrag 内部已就地定住 + 清槧
                case .ready(let owner, let drawing, let tool, let mapper):
                    // ⭐ 订正 2：无条件终止——先尽力按本帧真实位移算一个锚点，算不出就退回已有的
                    //   nodeDragCurrent，再清槧、再写（顺序理由同 finalizeAndCommit 头注）。
                    let anchor = DrawingNodeDrag.draggedAnchor(
                        drawing: drawing, anchorIndex: owner.anchorIndex, translation: translation,
                        mapper: mapper, tool: tool) ?? session.nodeDragCurrent
                    finalizeAndCommit(owner: owner, anchor: anchor)
                case .ownedButGeometryUnavailable(let owner):
                    // ⭐⭐ 订正 2（Critical）本体：归属对得上，但 viewport/线/工具这一帧取不到——
                    //   仍必须无条件收尾，⛔ 不许 `return` 丢在这里不管，否则 nodeDragOwner 残留，
                    //   Task 7 的十道写入门把底栏永久锁灰（界面卡死，不是"这次拖动失败"）。
                    finalizeAndCommit(owner: owner, anchor: session.nodeDragCurrent)
                }
                rebuildRenderState(bounds: view.bounds)
            }
        }

        /// 测试入口（照 `handleDrawingTapForTesting`（`:323`）的先例）。
        func handleNodeDragForTesting(translation: CGPoint, phase: GesturePhase) {
            handleNodeDrag(translation: translation, phase: phase)
        }
    }
}
#endif

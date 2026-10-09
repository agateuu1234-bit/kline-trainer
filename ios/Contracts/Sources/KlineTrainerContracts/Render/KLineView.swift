// Kline Trainer Swift Contracts — C1c KLineView UIKit shell
// Spec: kline_trainer_modules_v1.4.md §六 C1c (L1179-1211) + §15.1 #3 编译验证
// Cross-platform precedent: Theme.swift L66-117（UIKit 部分 #if canImport(UIKit) 守卫）
//
// 本文件实现 KLineView：UIView 子类，renderState 驱动 setNeedsDisplay，
// draw(_:) 派发到 C3-C6 八个 drawXxx extension 方法（散在 6 个 +Xxx.swift 文件，由 Task 3-6 提供）。
// 所有 drawXxx 在 PR 8 内为 Wave 1 占位空 stub；本 shell 关闭 §15.1 #3 编译验证闸门。

import Foundation

#if canImport(UIKit)
import UIKit
import CoreGraphics

public final class KLineView: UIView {
    public var renderState: KLineRenderState = .empty {
        didSet {
            guard renderState != oldValue else { return }
            setNeedsDisplay()
        }
    }

    /// Wave 3 13c-R1：本 view 的面板归属（上/下），由 ChartContainerView.Coordinator 设置。
    /// draw 的 os_signpost 区间按此打 upper/lower 名（PanelViewState 无上/下字段，故 draw 侧须自带）。
    public var panel: PanelId = .upper

    /// Wave 3 修 #2：bounds 变化（layoutSubviews）回调，供 Coordinator 用当前 engine + 真实 bounds 重算 renderState。
    /// renderState 仅在 ChartContainerView.updateUIView（@Bindable engine observation 变化）时用 bounds 重算；
    /// 静态 engine（Review：tick 冻结 / canAdvance false / 无交易）首帧若 bounds 未定（.zero）算出 .empty 后，
    /// 再无 observation 触发 updateUIView → 永久空白。本回调使 layout 拿到有效 bounds 时补算，不依赖 observation。
    public var onBoundsChange: ((CGRect) -> Void)?
    private var lastLaidOutBounds: CGRect = .zero

    /// P1c 第 3 片（D140b）：**手指真正按下**那一刻的只读钩子，与 `onBoundsChange`（`:31`）同款范式。
    /// ⛔⛔ 消费者**零 engine 写入**：不 settleDeceleration、不 rebuildRenderState、不改任何状态。
    ///    理由：今天惯性要到 pan `.began` 才被 `beginPan` 截住；在这里刹车会让**每一次触摸**
    ///    （含纯平移、纯点击）都提前截停惯性 —— 那是对 D32 既有行为的改动，直接违反 N1。
    public var onTouchDown: ((CGPoint) -> Void)?
    /// P1c 第 3 片（D140c）：按下时已有 ≥2 个触摸 —— 消费者据此清候选（fail-closed）。
    public var onMultiTouchBegan: (() -> Void)?

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        // G7：**只在单点触摸时**发按下钩子。判据用 event 的全量触摸数，⛔ 不是 touches.count
        //（touches 只含**本次新增**的那些，第二指落下时它也是 1）。
        let total = event?.allTouches?.count ?? touches.count
        if total == 1, let t = touches.first {
            onTouchDown?(t.location(in: self))       // 本面板局部坐标（D134e 的坐标空间契约）
        } else {
            onMultiTouchBegan?()
        }
    }

    /// 顺位9 夜间：图表 scheme 解析器。`displayMode` 保持 `.system`——override 由 SwiftUI
    /// `AppRootView.preferredColorScheme` 烤进 trait，本控制器只读生效 trait（RFC §4.3 item 3）。
    private let themeController = ThemeController()

    /// 当前生效调色板：按 trait 解析 scheme 选 light/dark 集（`forScheme` 返缓存 static，无逐帧分配）。
    var currentPalette: UIChartPalette {
        UIChartPalette.forScheme(themeController.resolve(trait: traitCollection))
    }

    /// Wave 3 顺位 4：注册具体 DrawingTool。MVP 单工具内联（6 种工具 + 注册表机制属 Phase 4）。
    /// **唯一**的工具注册表：渲染 dispatch（`draw(_:)`）与命中 dispatch（`ChartContainerView.Coordinator`
    /// 的 `.select` 分支，1b-i PR-3）**共用它**。D40 要求命中与渲染同源 —— 各持一份注册表就意味着
    /// 「画得出却命不中」或反之。故这里是 internal 而非 private（`private` 在 Swift 是**文件作用域**）。
    static let drawingTools: [DrawingToolType: any DrawingTool] = [.horizontal: HorizontalLineTool()]

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // 顺位9/codex R4-F1：画布透明（底色来自 SwiftUI 系统背景，随 preferredColorScheme 适配）须配 isOpaque=false。
        // UIView 默认 opaque——opaque 视图绘制上下文不在帧间清空，且要求填满 bounds；本 view draw() 仅稀疏描绘
        // candle/线/标记，不填整 bounds。切换 scheme 重绘时残留旧 scheme 像素 → 明暗混杂伪影。isOpaque=false
        // 令 UIKit 每帧清空上下文 + 透出 SwiftUI 底色，消除伪影并符合透明画布设计意图。
        isOpaque = false
        // 整支评审 Important 1：`isMultipleTouchEnabled` 默认 `false` ⇒ 第二指落在**同一个**
        // KLineView 上时，UIKit **根本不会再调一次** `touchesBegan`（本视图只收多点序列里的第一个
        // 触摸）⇒ `:40` 的 `else { onMultiTouchBegan?() }` 分支永远走不到，候选在「同面板第二指」
        // 这条路径上**不会**被清——真机症状：按住黑点、候选已捕获、pan 还没 `.began`，这时落第二指
        // 捏合缩放、再抬第二指、继续移动第一指 ⇒ pan 这才 `.began`，拿到的是**陈旧候选**（复核按
        // D140b 刻意不重做几何），用户以为在继续平移，结果却开始拖节点。
        // 打开本开关只影响**本视图自己**收不收多点触摸、不影响任何手势识别器（pan/pinch/长按都是
        // 独立于视图 `isMultipleTouchEnabled` 的通道，两指缩放今天已经工作证明了这一点）；本文件
        // 只覆写了 `touchesBegan` 一个方法，`:40` 的分支判据早已按 `total != 1` 写好、只是此前够
        // 不到——打开开关即可让它真正接住。
        isMultipleTouchEnabled = true
        // 顺位9：trait 的 userInterfaceStyle 变化（系统切暗/亮，或 preferredColorScheme 改 display_mode）→ 重绘。
        // 用「系统传入实例」重载 (view, previousTrait)，零 self 捕获，无 retain cycle（勿改成捕获 self）。
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: KLineView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported; KLineView is constructed via init(frame:)")
    }

    /// Wave 3 修 #2：bounds 真正变化时（首帧 .zero→有效尺寸、旋转/resize）回调 Coordinator 重算 renderState。
    /// 仅 bounds 改变才触发（去重，避免重复 make）；回调内只改 renderState（didSet→setNeedsDisplay，不再触发 layout，无环）。
    public override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != lastLaidOutBounds else { return }
        lastLaidOutBounds = bounds
        onBoundsChange?(bounds)
    }

    public override func draw(_ rect: CGRect) {
        // Wave 3 13c-R1：draw 区间（begin 前置于唯一早返 guard，defer 保证空 ctx 早返也闭合）
        let drawToken = RenderSignposter.beginDraw(panel: panel)
        defer { RenderSignposter.end(drawToken) }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let scale = traitCollection.displayScale
        let mapper = CoordinateMapper(viewport: renderState.viewport, displayScale: scale)
        let volMapper = IndicatorMapper(
            frame: renderState.frames.volumeChart,
            valueRange: renderState.volumeRange,
            geometry: renderState.viewport.geometry,
            viewport: renderState.viewport,
            displayScale: scale)
        let macdMapper = IndicatorMapper(
            frame: renderState.frames.macdChart,
            valueRange: renderState.macdRange,
            geometry: renderState.viewport.geometry,
            viewport: renderState.viewport,
            displayScale: scale)

        let axisGrid = AxisGridLayout.resolve(
            mapper: mapper, volumeMapper: volMapper, macdMapper: macdMapper,
            candles: renderState.visibleCandles, period: renderState.panel.period,
            frames: renderState.frames)
        drawGridLines(ctx: ctx, resolved: axisGrid)

        drawCandles(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawMA66(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawBOLL(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawVolume(ctx: ctx, mapper: volMapper, candles: renderState.visibleCandles)
        drawMACD(ctx: ctx, mapper: macdMapper, candles: renderState.visibleCandles)
        drawDrawings(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
                     period: renderState.panel.period,
                     scheme: themeController.resolve(trait: traitCollection),
                     selectedDrawingID: renderState.selectedDrawingID,
                     tools: Self.drawingTools)
        drawMarkers(ctx: ctx, viewport: renderState.viewport, mapper: mapper,
                    markers: renderState.markers, candles: renderState.visibleCandles)
        drawAxisLabels(ctx: ctx, resolved: axisGrid)

        // P1c 第 2 片：选中态节点画在所有**持久**内容之上（K 线 / 画线 / 交易标记 / 轴标签），
        // 但在**瞬时**的十字光标之下 —— 光标是用户此刻正在用的交互反馈，不该被压住。
        drawSelectionNodes(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
                           scheme: themeController.resolve(trait: traitCollection),
                           selectedDrawingID: renderState.selectedDrawingID,
                           tools: Self.drawingTools)
        drawCrosshair(ctx: ctx, at: renderState.crosshairPoint, viewport: renderState.viewport)
    }
}

#endif

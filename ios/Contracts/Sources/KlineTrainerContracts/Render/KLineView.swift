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

    /// 顺位9 夜间：图表 scheme 解析器。`displayMode` 保持 `.system`——override 由 SwiftUI
    /// `AppRootView.preferredColorScheme` 烤进 trait，本控制器只读生效 trait（RFC §4.3 item 3）。
    private let themeController = ThemeController()

    /// 当前生效调色板：按 trait 解析 scheme 选 light/dark 集（`forScheme` 返缓存 static，无逐帧分配）。
    var currentPalette: UIChartPalette {
        UIChartPalette.forScheme(themeController.resolve(trait: traitCollection))
    }

    /// Wave 3 顺位 4：注册具体 DrawingTool。MVP 单工具内联（6 种工具 + 注册表机制属 Phase 4）。
    private static let drawingTools: [DrawingToolType: any DrawingTool] = [.horizontal: HorizontalLineTool()]

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // 顺位9/codex R4-F1：画布透明（底色来自 SwiftUI 系统背景，随 preferredColorScheme 适配）须配 isOpaque=false。
        // UIView 默认 opaque——opaque 视图绘制上下文不在帧间清空，且要求填满 bounds；本 view draw() 仅稀疏描绘
        // candle/线/标记，不填整 bounds。切换 scheme 重绘时残留旧 scheme 像素 → 明暗混杂伪影。isOpaque=false
        // 令 UIKit 每帧清空上下文 + 透出 SwiftUI 底色，消除伪影并符合透明画布设计意图。
        isOpaque = false
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
                     tools: Self.drawingTools)
        drawMarkers(ctx: ctx, viewport: renderState.viewport, mapper: mapper,
                    markers: renderState.markers, candles: renderState.visibleCandles)
        drawAxisLabels(ctx: ctx, resolved: axisGrid)
        drawCrosshair(ctx: ctx, at: renderState.crosshairPoint, viewport: renderState.viewport)
    }
}

#endif

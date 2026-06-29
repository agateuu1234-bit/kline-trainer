// Kline Trainer Swift Contracts — C3 主图渲染 extension（Wave 1 真实现）
// Spec: kline_trainer_modules_v1.4.md §C3（主图蜡烛 + MA66 + BOLL）
// 几何来自 MainChartLayout（平台无关，host 已测）；本文件仅 UIKit 描边/填充薄层。
// §15.1 #3 编译验证：本文件 3 个方法签名与 KLineView.draw(_:) 派发点逐字匹配。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C3 主图蜡烛：实体矩形（涨/跌色填充）+ 影线（1 设备像素描边）。
    /// 几何来自 MainChartLayout.candleShapes（host 已测）；本方法仅 UIKit 描边/填充。
    func drawCandles(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>) {
        guard !candles.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(1 / mapper.displayScale)
        for shape in MainChartLayout.candleShapes(for: candles, mapper: mapper) {
            let color = shape.isUp ? currentPalette.candleUp : currentPalette.candleDown
            color.setFill()
            color.setStroke()
            ctx.move(to: shape.wickTop)
            ctx.addLine(to: shape.wickBottom)
            ctx.strokePath()
            ctx.fill(shape.bodyRect)
        }
    }

    /// C3 MA66：读预计算 candle.ma66 折线（实线），currentPalette.ma66 着色（D1/D4；顺位9 scheme-aware）。
    func drawMA66(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>) {
        let segments = MainChartLayout.ma66Polyline(for: candles, mapper: mapper)
        guard !segments.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        currentPalette.ma66.setStroke()
        ctx.setLineWidth(3 / mapper.displayScale)
        ctx.setLineJoin(.round)
        // 单点段无法成线，跳过（D9：polylineSegments 在 nil 处断段，孤立单点是边角产物）。
        for segment in segments where segment.count >= 2 {
            ctx.move(to: segment[0])
            for point in segment.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()
        }
    }

    /// C3 BOLL：上/中/下三轨虚线（D3 plan v1.5 L6），无填充（D2），currentPalette.bollLine 着色（D4；顺位9 scheme-aware）。
    func drawBOLL(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>) {
        let boll = MainChartLayout.bollPolylines(for: candles, mapper: mapper)
        let lines = [boll.upper, boll.mid, boll.lower]
        guard lines.contains(where: { !$0.isEmpty }) else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        currentPalette.bollLine.setStroke()
        ctx.setLineWidth(2.2 / mapper.displayScale)
        // D3：BOLL 虚线。dash 段长由 host 已测的 MainChartLayout.dashPattern 提供（H1 修订）。
        // saveGState/restoreGState（上方 defer）配对保证 dash 不泄漏给后续 drawVolume/drawMACD——
        // 此配对正确性靠 defer 紧跟 saveGState 的惯用法 + code review，无运行期自动验证（H1 如实记录）。
        ctx.setLineDash(phase: 0, lengths: MainChartLayout.dashPattern(displayScale: mapper.displayScale))
        for line in lines {
            // 单点段无法成线，跳过（D9，同 drawMA66）。
            for segment in line where segment.count >= 2 {
                ctx.move(to: segment[0])
                for point in segment.dropFirst() { ctx.addLine(to: point) }
                ctx.strokePath()
            }
        }
    }
}

#endif

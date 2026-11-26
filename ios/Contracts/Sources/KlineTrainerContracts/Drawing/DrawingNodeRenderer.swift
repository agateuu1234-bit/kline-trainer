// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingNodeRenderer.swift
// Spec: docs/superpowers/specs/2026-09-21-drawing-tools-P1c-2-nodes-design.md（D107 / D121 / D123 / D125）
//
// 选中态节点的**绘制层**：按 `DrawingNodeGeometry` 已经算好的记号机械绘制，**零判断**
// （画不画 / 画在哪 / 画真节点还是代理标记，全在决策层）。
// 跨平台：仅 CoreGraphics，无 UIKit → host swift test 可做像素级断言。

import CoreGraphics

@MainActor
public enum DrawingNodeRenderer {

    /// D107：节点色 = 自适应纯 ink（日纯黑 / 夜纯白），**无描边**。
    /// D123：代理标记**同色族** —— ⛔ 不跟线的 `colorToken` 走，它属于「选中记号」这一家。
    public static func inkRGBA(scheme: AppColorScheme) -> AppColorRGBA {
        scheme == .dark ? AppColorRGBA(white: 1) : AppColorRGBA(white: 0)
    }

    /// D125：**只把节点与代理标记裁剪到主图框**。
    /// ⛔ 调用方绝不能把线的绘制包进这道裁剪里 —— 线今天就是不裁剪的，给它加上会让贴边的线变细
    ///    （那是本片范围之外的行为改动，`selectionLeavesLinePixelsUntouched` 钉死）。
    public static func draw(ctx: CGContext, marks: [DrawingNodeGeometry.NodeMark],
                            scheme: AppColorScheme, clipTo frame: CGRect) {
        guard !marks.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: frame)
        let c = inkRGBA(scheme: scheme)
        ctx.setFillColor(CGColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green),
                                 blue: CGFloat(c.blue), alpha: CGFloat(c.alpha)))
        let d = DrawingNodeGeometry.visualDiameter
        for mark in marks {
            switch mark {
            case let .real(_, p):
                ctx.fillEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
            case let .proxy(_, p, pointingLeft):
                // 尖头**顶在边框上**（p 就是边框上那个点），底边在**内侧** —— 整个三角都在框内，
                // 裁剪只作用于 y 方向的溢出。⛔ 尖头不得画到框外，否则会被裁成一根竖条。
                let baseX = pointingLeft ? p.x + d : p.x - d
                ctx.beginPath()
                ctx.move(to: p)
                ctx.addLine(to: CGPoint(x: baseX, y: p.y - d / 2))
                ctx.addLine(to: CGPoint(x: baseX, y: p.y + d / 2))
                ctx.closePath()
                ctx.fillPath()
            }
        }
    }
}

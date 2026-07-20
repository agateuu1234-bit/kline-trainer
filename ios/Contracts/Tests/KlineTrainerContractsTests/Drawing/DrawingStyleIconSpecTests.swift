// Tests/KlineTrainerContractsTests/Drawing/DrawingStyleIconSpecTests.swift
// Spec: 2026-07-18-drawing-tools-P1b-1a-iii-panel-redesign-design.md §3（图标化：把样式「画出来」）。
// 这些是纯数值规格（无 UIKit / 非 View）→ 跑于 host swift test，防「5 个档位画出来长得一模一样」的假绿。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("图标规格：派生自渲染层真值，且五档两两可区分（1a-iii 切片2 Task1）")
struct DrawingStyleIconSpecTests {

    @Test("dash 图标就是**渲染层真值**原样转发——面板里画的虚线与真正落到 K 线上的虚线一致（防两份真相）")
    func dashPatternMirrorsRenderer() throws {
        for style in LineStyle.allCases {
            #expect(DrawingStyleIconSpec.dashPattern(for: style)
                    == HorizontalLineTool.dashPattern(for: style),
                    "\(style) 的图标 dash 与渲染层不一致 —— 面板在骗人")
        }
    }

    @Test("5 种线样式的 dash pattern 两两不等——任何两档画出来都不会一样")
    func dashPatternsArePairwiseDistinct() throws {
        let all = LineStyle.allCases
        for i in all.indices {
            for j in all.indices where j > i {
                #expect(DrawingStyleIconSpec.dashPattern(for: all[i])
                        != DrawingStyleIconSpec.dashPattern(for: all[j]),
                        "\(all[i]) 与 \(all[j]) 的 dash pattern 相同 → 图标不可区分")
            }
        }
    }

    @Test("实线 dash 为空、四档虚线非空（实线不得画成虚的）")
    func solidHasNoDash() throws {
        #expect(DrawingStyleIconSpec.dashPattern(for: .solid).isEmpty)
        for s in LineStyle.allCases where s != .solid {
            #expect(!DrawingStyleIconSpec.dashPattern(for: s).isEmpty)
        }
    }

    @Test("图标线宽**派生自**渲染层线宽（同一放大系数），不是另写一张表——渲染层改了图标自动跟着改")
    func iconLineWidthIsDerivedFromRenderer() throws {
        for t in 1...5 {
            #expect(DrawingStyleIconSpec.iconLineWidth(forThickness: t)
                    == HorizontalLineTool.lineWidth(forThickness: t) * DrawingStyleIconSpec.iconWidthAmplification,
                    "第 \(t) 档图标线宽不是渲染层线宽的等比放大 → 两份真相")
        }
    }

    @Test("粗细 1…5 的图标线宽严格递增且够粗看得出差别——不是 5 根几乎同宽的线")
    func iconLineWidthStrictlyIncreasesAndIsLegible() throws {
        let widths = (1...5).map { DrawingStyleIconSpec.iconLineWidth(forThickness: $0) }
        for i in 1..<widths.count {
            #expect(widths[i] > widths[i - 1], "第 \(i + 1) 档线宽未大于第 \(i) 档：\(widths)")
        }
        #expect(widths.allSatisfy { $0 > 0 })
        // 放大的意义就在于肉眼可辨：最粗与最细至少差 3pt，否则面板上五档看起来一样、放大系数形同虚设。
        #expect(widths.last! - widths.first! >= 3, "五档跨度仅 \(widths.last! - widths.first!)pt，肉眼分不出")
    }

    @Test("越界档位 fail-closed 得到正数宽度（坏输入不产出 0 宽 / 负宽的不可见图标）")
    func outOfRangeThicknessClampsToPositiveWidth() throws {
        for t in [-3, 0, 6, 99] {
            #expect(DrawingStyleIconSpec.iconLineWidth(forThickness: t) > 0)
        }
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

/// `onPreferenceChange` 写入的接收盒（本文件专用；`DrawingLayoutInvariantTests` 里的同款是 private、跨文件不可见）。
@MainActor
private final class IconProbeFrameBox {
    var rect: CGRect?
}

/// 本文件专用测量 key（不复用 `ChartPanelsFrameKey`——那是布局不变量测试的语义，别混用）。
private struct IconProbeFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

@Suite("图标渲染（Catalyst，1a-iii 切片2 Task1）")
@MainActor
struct DrawingStyleIconRenderTests {

    @Test("前置实测：ImageRenderer 能 flatten Canvas 图标（子树不塌成零尺寸）——Task4 几何断言的前提")
    func imageRendererFlattensCanvasIcons() throws {
        let box = IconProbeFrameBox()
        let probe = HStack { LineStyleIcon(style: .dash1); ThicknessIcon(thickness: 5) }
            .coordinateSpace(name: "probe")
            .overlay { GeometryReader { g in Color.clear
                .preference(key: IconProbeFrameKey.self, value: g.frame(in: .named("probe"))) } }
            .onPreferenceChange(IconProbeFrameKey.self) { box.rect = $0 }
        let r = ImageRenderer(content: probe); r.scale = 1; _ = r.uiImage
        let f = try #require(box.rect)
        #expect(f.width > 0 && f.height > 0, "Canvas 子树被 ImageRenderer 塌成零尺寸 → Task4 几何断言会假绿")
    }

    // ⭐codex 计划-R13-F2：**没有这组测试，画白板也能全绿**——源码守卫只查符号在不在、文字有没有，
    //   flatten 探针只查 frame 非零，**没有一条验证真的画出了像素**。Canvas 实现写错（描边色、
    //   零长路径、坐标算错）就会 ship 三排空白方块，而本切片的全部意义正是「用户能看见并分辨这些图标」。
    //   故读真实像素：白底 + 黑前景渲染，统计墨点数与像素签名。

    /// 渲染一个图标到 8-bit 灰度位图，返回（墨点数, 像素签名）。白底黑线 → 暗像素即墨。
    private func inkSignature<V: View>(_ view: V, size: CGSize) throws -> (ink: Int, bytes: [UInt8]) {
        let renderer = ImageRenderer(content:
            view.foregroundStyle(.black)
                .frame(width: size.width, height: size.height)
                .background(.white))
        renderer.scale = 1
        let cg = try #require(renderer.uiImage?.cgImage, "图标渲染不出位图")
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h)
        let ctx = try #require(CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (buf.filter { $0 < 128 }.count, buf)
    }

    @Test("像素级：三种线型图标都**真的画出了东西**，且两两可分辨（防 ship 空白方块）")
    func lineSubTypeIconsRenderDistinctInk() throws {
        var sigs: [LineSubType: [UInt8]] = [:]
        for s in LineSubType.allCases {
            let (ink, bytes) = try inkSignature(LineSubTypeIcon(subType: s), size: CGSize(width: 30, height: 14))
            #expect(ink > 0, "\(s) 图标是空白的 —— 用户看到的是个空框")
            sigs[s] = bytes
        }
        let all = LineSubType.allCases
        for i in all.indices { for j in all.indices where j > i {
            #expect(sigs[all[i]] != sigs[all[j]], "\(all[i]) 与 \(all[j]) 画出来一模一样，用户分不出")
        } }
    }

    @Test("像素级：5 种线样式都画出东西，且两两可分辨（dash 真的落到像素上）")
    func lineStyleIconsRenderDistinctInk() throws {
        var sigs: [LineStyle: [UInt8]] = [:]
        for s in LineStyle.allCases {
            let (ink, bytes) = try inkSignature(LineStyleIcon(style: s), size: CGSize(width: 30, height: 12))
            #expect(ink > 0, "\(s) 图标是空白的")
            sigs[s] = bytes
        }
        // 实线墨最多（无空档）——顺带验证 dash 真的在断线，而不是被忽略后全画成实线。
        let solidInk = try inkSignature(LineStyleIcon(style: .solid), size: CGSize(width: 30, height: 12)).ink
        for s in LineStyle.allCases where s != .solid {
            let ink = try inkSignature(LineStyleIcon(style: s), size: CGSize(width: 30, height: 12)).ink
            #expect(ink < solidInk, "\(s) 的墨量不少于实线 —— dash pattern 没生效，五档看起来都是实线")
        }
        let all = LineStyle.allCases
        for i in all.indices { for j in all.indices where j > i {
            #expect(sigs[all[i]] != sigs[all[j]], "\(all[i]) 与 \(all[j]) 画出来一模一样，用户分不出")
        } }
    }

    @Test("像素级：粗细 1…5 的墨量**严格递增**（图标真的越来越粗，不是 5 根同宽线）")
    func thicknessIconsRenderIncreasingInk() throws {
        let inks = try (1...5).map {
            try inkSignature(ThicknessIcon(thickness: $0), size: CGSize(width: 26, height: 14)).ink
        }
        #expect(inks.allSatisfy { $0 > 0 }, "有档位画成了空白：\(inks)")
        for i in 1..<inks.count {
            #expect(inks[i] > inks[i - 1], "第 \(i + 1) 档墨量未多于第 \(i) 档：\(inks) —— 粗细没体现在像素上")
        }
    }
}
#endif

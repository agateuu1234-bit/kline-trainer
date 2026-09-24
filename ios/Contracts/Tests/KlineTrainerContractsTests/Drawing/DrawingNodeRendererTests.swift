import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("DrawingNodeRenderer")
struct DrawingNodeRendererTests {

    /// bitmap 特意比 mainChartFrame **高**（400 vs 360），这样「裁剪有没有生效」才看得出来 ——
    /// 若 bitmap 与 frame 等高，超出部分本来就写不进去，裁剪测试会恒真。
    static let W = 800, H = 400
    static let frame = CGRect(x: 0, y: 0, width: 800, height: 360)

    static func render(_ marks: [DrawingNodeGeometry.NodeMark],
                       scheme: AppColorScheme = .light,
                       clipTo clip: CGRect? = nil) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: W * H * 4)
        let ctx = CGContext(data: &data, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        DrawingNodeRenderer.draw(ctx: ctx, marks: marks, scheme: scheme, clipTo: clip ?? frame)
        return data
    }

    /// 某一列上不透明像素的个数（= 该列被画到的垂直厚度）。
    /// ⚠️ 整列求和，**不受行序影响** —— 与 `pixel(_:x:y:)` 不同，这里无需做 bottom-up 换算。
    static func columnInk(_ data: [UInt8], x: Int) -> Int {
        (0..<H).reduce(0) { acc, y in acc + (data[(y * W + x) * 4 + 3] > 76 ? 1 : 0) }
    }

    /// 某像素的（反 premultiplied）颜色，alpha 太低则 nil。`y` 是 **CG 坐标**。
    /// ⛔⛔ **`data` 的行序是 bottom-up：内存行 = H - 1 - CG的y**。
    /// 实测（800×400 bitmap，在 CG (400,180) 画直径 7 的圆）：有墨的内存行是 **216…223**，
    /// 而内存行 180 的 alpha 是 **0**。⇒ 直接拿 CG 的 y 当行号会读到完全无关的位置。
    static func pixel(_ data: [UInt8], x: Int, y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let i = ((H - 1 - y) * W + x) * 4
        let a = CGFloat(data[i+3]) / 255
        guard a > 0.3 else { return nil }
        return (CGFloat(data[i])/255/a, CGFloat(data[i+1])/255/a, CGFloat(data[i+2])/255/a)
    }

    @Test("D107：真节点是纯黑实心圆（夜间纯白），直径 7pt")
    func realNodeIsInkFilledCircle() {
        let c = CGPoint(x: 400, y: 180)
        let light = Self.render([.real(index: 0, at: c)], scheme: .light)
        guard let p = Self.pixel(light, x: 400, y: 180) else {
            Issue.record("节点中心必须有像素 —— 否则下面的颜色断言恒真"); return
        }
        #expect(p.r < 0.1 && p.g < 0.1 && p.b < 0.1, "日间必须是纯黑，实得 \(p)")
        let dark = Self.render([.real(index: 0, at: c)], scheme: .dark)
        guard let q = Self.pixel(dark, x: 400, y: 180) else { Issue.record("夜间中心无像素"); return }
        #expect(q.r > 0.9 && q.g > 0.9 && q.b > 0.9, "夜间必须是纯白，实得 \(q)")
        // 直径：中心列的墨量应约等于 7（允许抗锯齿 ±2）
        let ink = Self.columnInk(light, x: 400)
        #expect(ink >= 5 && ink <= 9, "中心列墨量应接近直径 7pt，实得 \(ink)")
        // 离中心 10pt 处必须没有墨 ⇒ 证明它是个点，不是一整片
        #expect(Self.columnInk(light, x: 410) == 0, "离中心 10pt 处不该有墨")
    }

    @Test("⭐T3：代理三角的朝向可分辨 —— 左三角越往右越厚、右三角越往左越厚")
    func proxyTriangleDirectionIsDistinguishable() {
        let y = 180
        let left = Self.render([.proxy(index: 0, at: CGPoint(x: 0, y: CGFloat(y)), pointingLeft: true)])
        let nearTipL = Self.columnInk(left, x: 1), farL = Self.columnInk(left, x: 5)
        #expect(nearTipL > 0, "左三角必须真的画出来了")
        #expect(nearTipL < farL, "左三角尖头在左 ⇒ 越往右越厚（x1=\(nearTipL) x5=\(farL)）")

        let right = Self.render([.proxy(index: 0, at: CGPoint(x: 800, y: CGFloat(y)), pointingLeft: false)])
        let nearTipR = Self.columnInk(right, x: 798), farR = Self.columnInk(right, x: 794)
        #expect(nearTipR > 0, "右三角必须真的画出来了")
        #expect(nearTipR < farR, "右三角尖头在右 ⇒ 越往左越厚（x798=\(nearTipR) x794=\(farR)）")

        // ⭐ 左右互换守卫：把左三角的厚度走向拿去比右三角，必须不成立
        #expect(!(Self.columnInk(right, x: 794) < Self.columnInk(right, x: 798)),
                "若左右被互换实现，这条会成立 —— 说明朝向没真的被区分")
    }

    @Test("D125：节点被裁剪到主图框内（贴下沿时不溢出到副图区）")
    func nodeIsClippedToMainChartFrame() {
        // 圆心 CG y=358、半径 3.5 ⇒ 圆覆盖 CG y 354.5…361.5；frame.maxY = 360。
        // ⭐ **对照式**断言：同一个记号，裁到 frame（360 高）vs 裁到全图（400 高），
        //    在 CG y=360 这一行必须**一有一无**。⛔ 单看「裁剪后那里没墨」是恒真的 ——
        //    实测：无裁剪时 CG y=360 的 alpha=255、有裁剪时=0；而更远的 y=362 两种情况都是 0。
        let mark = DrawingNodeGeometry.NodeMark.real(index: 0, at: CGPoint(x: 400, y: 358))
        let clipped   = Self.render([mark])                                             // clipTo: frame
        let unclipped = Self.render([mark], clipTo: CGRect(x: 0, y: 0, width: 800, height: 400))
        #expect(Self.pixel(unclipped, x: 400, y: 360) != nil,
                "⭐ 前提：不裁剪时 CG y=360 必须有墨，否则下面那条断言是空的")
        #expect(Self.pixel(clipped, x: 400, y: 360) == nil,
                "裁剪后 CG y=360（已达 frame.maxY）必须没墨 —— 否则节点会画到成交量面板上")
        #expect(Self.pixel(clipped, x: 400, y: 358) != nil, "圆心仍须有墨（别把整个圆裁没了）")
    }

    @Test("空记号 → 一个像素都不画（接线层传空时的零开销路径）")
    func emptyMarksDrawNothing() {
        let data = Self.render([])
        #expect((0..<Self.W).allSatisfy { Self.columnInk(data, x: $0) == 0 })
    }
}

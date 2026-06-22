import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Test func clamp_keepsWithinBounds() {
    let bounds = CGRect(x: 0, y: 0, width: 390, height: 800)
    let size = CGSize(width: 44, height: 44)
    // 拖出右下角 → 回拉到边界内
    let p = DrawingFloatLayout.clampedOffset(proposed: CGPoint(x: 500, y: 900), bounds: bounds, size: size)
    #expect(p.x <= bounds.maxX - size.width)
    #expect(p.y <= bounds.maxY - size.height)
    #expect(p.x >= bounds.minX)
    #expect(p.y >= bounds.minY)
}
@Test func clamp_passesThroughWhenInside() {
    let bounds = CGRect(x: 0, y: 0, width: 390, height: 800)
    let size = CGSize(width: 44, height: 44)
    let p = DrawingFloatLayout.clampedOffset(proposed: CGPoint(x: 100, y: 100), bounds: bounds, size: size)
    #expect(p == CGPoint(x: 100, y: 100))
}

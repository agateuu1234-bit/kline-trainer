// RubberBandTests.swift
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("RubberBand 橡皮筋阻尼纯函数")
struct RubberBandTests {
    @Test("damp(0,d)==0、负 over→0")
    func zeroAndNegative() {
        #expect(RubberBand.damp(over: 0, dimension: 800) == 0)
        #expect(RubberBand.damp(over: -50, dimension: 800) == 0)
    }

    @Test("单调增 + 永远 < over（被压缩）")
    func monotonicAndCompressed() {
        var prev: CGFloat = 0
        for x in stride(from: CGFloat(1), through: 5000, by: 50) {
            let y = RubberBand.damp(over: x, dimension: 800)
            #expect(y > prev)          // 单调增
            #expect(y < x)             // 阻尼压缩
            prev = y
        }
    }

    @Test("渐近上界 d：大 over → 趋近但 < dimension；巨值无 NaN/overflow")
    func asymptote() {
        // damp(100_000,800) = (1 − 1/(100000·0.55/800+1))·800 ≈ 788.53（98.5% of d，已逼近但 < 800）
        #expect(RubberBand.damp(over: 100_000, dimension: 800) < 800)
        #expect(RubberBand.damp(over: 100_000, dimension: 800) > 785)         // 已逼近 d（实际 ≈788.53）
        let huge = RubberBand.damp(over: .greatestFiniteMagnitude, dimension: 800)
        #expect(huge.isFinite)
        #expect(huge <= 800)
    }

    @Test("退化 dimension<=0 → 不阻尼（返 over）")
    func degenerateDimension() {
        #expect(RubberBand.damp(over: 123, dimension: 0) == 123)
        #expect(RubberBand.damp(over: 123, dimension: -5) == 123)
    }

    @Test("f'(0)≈c=0.55：边缘起点斜率")
    func slopeAtEdge() {
        let eps: CGFloat = 0.001
        let slope = RubberBand.damp(over: eps, dimension: 800) / eps
        #expect(abs(slope - 0.55) < 0.01)
    }
}

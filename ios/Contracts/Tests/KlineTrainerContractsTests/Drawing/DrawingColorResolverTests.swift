import Testing
@testable import KlineTrainerContracts

@Suite("DrawingColorResolver")
struct DrawingColorResolverTests {
    @Test("默认橙昼夜都是 legacy (0.82,0.40,0.0)——视觉零变化锚")
    func orangeIsLegacyBothSchemes() {
        for s in [AppColorScheme.light, .dark] {
            let c = DrawingColorResolver.resolve(.orange, scheme: s)
            #expect(c.red == 0.82 && c.green == 0.40 && c.blue == 0.0)
        }
    }
    @Test("7 个彩色 token 主题无关（昼夜解析相同）")
    func sevenChromaticSchemeIndependent() {
        for t in [DrawingColorToken.red, .orange, .yellow, .green, .cyan, .blue, .purple] {
            #expect(DrawingColorResolver.resolve(t, scheme: .light) == DrawingColorResolver.resolve(t, scheme: .dark))
        }
    }
    @Test("black/white 主题相关，且不与背景同色（可读）")
    func blackWhiteSchemeDependentReadable() {
        // white 在白天背景(≈1,1,1)下必须不是纯白；black 在夜间背景(≈0,0,0)下必须不是纯黑
        let whiteLight = DrawingColorResolver.resolve(.white, scheme: .light)
        let blackDark = DrawingColorResolver.resolve(.black, scheme: .dark)
        #expect(!(whiteLight.red == 1 && whiteLight.green == 1 && whiteLight.blue == 1))
        #expect(!(blackDark.red == 0 && blackDark.green == 0 && blackDark.blue == 0))
        // 主题相关：white 昼≠夜，black 昼≠夜
        #expect(DrawingColorResolver.resolve(.white, scheme: .light) != DrawingColorResolver.resolve(.white, scheme: .dark))
        #expect(DrawingColorResolver.resolve(.black, scheme: .light) != DrawingColorResolver.resolve(.black, scheme: .dark))
    }
}

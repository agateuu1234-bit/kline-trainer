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
        // 切片3：自适应纯 ink——white 在白天 = 纯黑(0,0,0)；black 在夜间 = 纯白(1,1,1)，不再是糊灰
        let whiteLight = DrawingColorResolver.resolve(.white, scheme: .light)
        let blackDark = DrawingColorResolver.resolve(.black, scheme: .dark)
        #expect(whiteLight.red == 0 && whiteLight.green == 0 && whiteLight.blue == 0)
        #expect(blackDark.red == 1 && blackDark.green == 1 && blackDark.blue == 1)
        // 主题相关：white 昼≠夜，black 昼≠夜
        #expect(DrawingColorResolver.resolve(.white, scheme: .light) != DrawingColorResolver.resolve(.white, scheme: .dark))
        #expect(DrawingColorResolver.resolve(.black, scheme: .light) != DrawingColorResolver.resolve(.black, scheme: .dark))
    }

    @Test("线色自适应（切片3）：.black/.white 都解析成纯 ink——日近黑、夜近白，无糊色 fallback")
    func adaptiveInkNoMuddyFallback() throws {
        // 日间：纯黑（0,0,0），不再是白天的 .white→0.20 深灰
        #expect(DrawingColorResolver.resolve(.black, scheme: .light) == AppColorRGBA(red: 0, green: 0, blue: 0))
        #expect(DrawingColorResolver.resolve(.white, scheme: .light) == AppColorRGBA(red: 0, green: 0, blue: 0))
        // 夜间：纯白（1,1,1），不再是夜间的 .black→0.85 浅灰
        #expect(DrawingColorResolver.resolve(.black, scheme: .dark) == AppColorRGBA(red: 1, green: 1, blue: 1))
        #expect(DrawingColorResolver.resolve(.white, scheme: .dark) == AppColorRGBA(red: 1, green: 1, blue: 1))
        // .black 与 .white 现在是同义自适应 ink
        #expect(DrawingColorResolver.resolve(.black, scheme: .light) == DrawingColorResolver.resolve(.white, scheme: .light))
        #expect(DrawingColorResolver.resolve(.black, scheme: .dark) == DrawingColorResolver.resolve(.white, scheme: .dark))
    }

    @Test("线色永远与背景反色、看得见（根治『黑线夜间消失』）：日夜两态的 ink 与各自背景对比度拉满")
    func adaptiveInkAlwaysReadable() throws {
        // 纯黑 vs 白底、纯白 vs 黑底——各通道差 1.0（对比度最大），不会与背景同色
        let dayInk = DrawingColorResolver.resolve(.black, scheme: .light)
        let nightInk = DrawingColorResolver.resolve(.black, scheme: .dark)
        #expect(dayInk.red == 0 && dayInk.green == 0 && dayInk.blue == 0)      // 日：纯黑
        #expect(nightInk.red == 1 && nightInk.green == 1 && nightInk.blue == 1) // 夜：纯白
        #expect(dayInk != nightInk)   // 昼夜真的反了
    }

    @Test("legacy 渲染 fixture（codex 计划-R1-F1 / spec §4.3）：老 .black/.white 记录在新端的自适应渲染逐一钉死")
    func legacyTokensRenderAdaptiveInkBothSchemes() throws {
        // 老记录里持久化的 raw 值仍是 .black / .white（字节不变）；变的只有 resolve 的输出。
        // 日间：两者都纯黑（老 .white 曾是 0.20 深灰 → 现 0）
        #expect(DrawingColorResolver.resolve(.black, scheme: .light) == AppColorRGBA(red: 0, green: 0, blue: 0))
        #expect(DrawingColorResolver.resolve(.white, scheme: .light) == AppColorRGBA(red: 0, green: 0, blue: 0))
        // 夜间：两者都纯白（老 .black 曾是 0.85 浅灰 → 现 1）
        #expect(DrawingColorResolver.resolve(.black, scheme: .dark) == AppColorRGBA(red: 1, green: 1, blue: 1))
        #expect(DrawingColorResolver.resolve(.white, scheme: .dark) == AppColorRGBA(red: 1, green: 1, blue: 1))
        // 反向钉：绝不回退到糊灰（0.85 / 0.20 任一出现即漂移被破坏）
        for s in [AppColorScheme.light, .dark] {
            for t in [DrawingColorToken.black, .white] {
                let c = DrawingColorResolver.resolve(t, scheme: s)
                #expect(c.red == 0 || c.red == 1, "出现糊灰值 \(c.red) —— 自适应纯 ink 语义被破坏")
            }
        }
    }
}

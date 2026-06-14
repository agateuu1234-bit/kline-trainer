import Testing
import Foundation
@testable import KlineTrainerContracts

// MARK: - WCAG 相对亮度对比 helper（codex R1-F1：替换 maxChannelDiff 代理为真亮度对比闸门）
// WCAG 2.x：先 sRGB→线性，再 L=0.2126R+0.7152G+0.0722B；对比比 =(L_hi+0.05)/(L_lo+0.05)。
private func wcagLinear(_ c: Double) -> Double {
    c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}
private func wcagRelativeLuminance(_ c: AppColorRGBA) -> Double {
    0.2126 * wcagLinear(c.red) + 0.7152 * wcagLinear(c.green) + 0.0722 * wcagLinear(c.blue)
}
private func wcagContrastRatio(_ a: AppColorRGBA, _ b: AppColorRGBA) -> Double {
    let la = wcagRelativeLuminance(a), lb = wcagRelativeLuminance(b)
    let hi = max(la, lb), lo = min(la, lb)
    return (hi + 0.05) / (lo + 0.05)
}
private let wcagWhite = AppColorRGBA(white: 1.0)

@Suite("AppPalette light/dark 双集 + scheme 选取（顺位9 夜间）")
struct AppPaletteTests {

    @Test("light 集 13 token 计数")
    func lightThirteen() {
        let p = AppPalette.light
        let all: [AppColorRGBA] = [
            p.candleUp, p.candleDown, p.ma66, p.bollLine, p.macdDIF, p.macdDEA,
            p.macdBarPositive, p.macdBarNegative, p.profitRed, p.lossGreen,
            p.background, p.gridLine, p.text,
        ]
        #expect(all.count == 13)
    }

    @Test("light D-3 alias：macdBar/盈亏 = candle 同色")
    func lightAlias() {
        let p = AppPalette.light
        #expect(p.macdBarPositive == p.candleUp)
        #expect(p.macdBarNegative == p.candleDown)
        #expect(p.profitRed == p.candleUp)
        #expect(p.lossGreen == p.candleDown)
    }

    @Test("light 红涨绿跌色相：candleUp 红主导 / candleDown 绿主导")
    func lightHue() {
        let up = AppPalette.light.candleUp
        let down = AppPalette.light.candleDown
        #expect(up.red > up.green && up.red > up.blue)
        #expect(down.green > down.red && down.green > down.blue)
        #expect(up.red > down.red)
        #expect(down.green > up.green)
    }

    @Test("light WCAG 对比：前景 token vs 近白背景 相对亮度对比 ≥ 3:1（图形元素，codex R1-F1）")
    func lightForegroundContrastWCAG() {
        let bg = AppPalette.light.background
        let p = AppPalette.light
        // 7 个图形前景 token（gridLine 刻意 subtle 不计；text 同时是文字，下限更高自然满足）。
        for c in [p.text, p.candleUp, p.candleDown, p.ma66, p.bollLine, p.macdDIF, p.macdDEA] {
            #expect(wcagContrastRatio(c, bg) >= 3.0)
        }
        // macdDEA 是 codex R1-F1 修复点：确保它真过 3:1（旧 0.80/0.55/0 仅 2.74:1）。
        #expect(wcagContrastRatio(p.macdDEA, bg) >= 3.0)
    }

    @Test("marker 字母（固定白）vs 涨/跌彩色圆点 对比 ≥ 3:1（light+dark，codex R1-F2）")
    func markerGlyphContrastWCAG() {
        // 交易标记字母为饱和圆点上的覆盖文字 = 固定白；两 scheme 的涨/跌点底色均须与白足够对比。
        for pal in [AppPalette.light, AppPalette.dark] {
            #expect(wcagContrastRatio(wcagWhite, pal.candleUp) >= 3.0)
            #expect(wcagContrastRatio(wcagWhite, pal.candleDown) >= 3.0)
        }
    }

    @MainActor
    @Test("画线描边（固定暗橙）vs light/dark 底 对比 ≥ 3:1（codex R2-F1）")
    func drawingStrokeContrastWCAG() {
        let stroke = HorizontalLineTool.strokeRGBA
        #expect(wcagContrastRatio(stroke, AppPalette.light.background) >= 3.0)
        #expect(wcagContrastRatio(stroke, AppPalette.dark.background) >= 3.0)
    }

    @Test("light ≠ dark：关键 token 取值切换")
    func lightDistinctFromDark() {
        #expect(AppPalette.light.background != AppPalette.dark.background)
        #expect(AppPalette.light.text != AppPalette.dark.text)
        #expect(AppPalette.light.candleUp != AppPalette.dark.candleUp)
        #expect(AppPalette.light.macdDIF != AppPalette.dark.macdDIF)
    }

    @Test("dark 集逐字段 = AppColorTokens（冻结复用；全 13 字段防转置）")
    func darkEqualsTokens() {
        let d = AppPalette.dark
        #expect(d.candleUp == AppColorTokens.candleUp)
        #expect(d.candleDown == AppColorTokens.candleDown)
        #expect(d.ma66 == AppColorTokens.ma66)
        #expect(d.bollLine == AppColorTokens.bollLine)
        #expect(d.macdDIF == AppColorTokens.macdDIF)
        #expect(d.macdDEA == AppColorTokens.macdDEA)
        #expect(d.macdBarPositive == AppColorTokens.macdBarPositive)
        #expect(d.macdBarNegative == AppColorTokens.macdBarNegative)
        #expect(d.profitRed == AppColorTokens.profitRed)
        #expect(d.lossGreen == AppColorTokens.lossGreen)
        #expect(d.background == AppColorTokens.background)
        #expect(d.gridLine == AppColorTokens.gridLine)
        #expect(d.text == AppColorTokens.text)
    }

    @Test("forScheme 映射：.dark→dark / .light→light")
    func forScheme() {
        #expect(AppPalette.forScheme(.dark) == AppPalette.dark)
        #expect(AppPalette.forScheme(.light) == AppPalette.light)
    }
}

@Suite("displayModePrefersDark（preferredColorScheme 映射）")
struct DisplayModePrefersDarkTests {
    @Test(".light→false / .dark→true / .system→nil")
    func mapping() {
        #expect(displayModePrefersDark(.light) == false)
        #expect(displayModePrefersDark(.dark) == true)
        #expect(displayModePrefersDark(.system) == nil)
    }
}

#if canImport(UIKit)
import UIKit

@Suite("UIChartPalette（UIKit 桥；scheme 选取）")
struct UIChartPaletteTests {

    private func channels(_ c: UIColor) -> (Double, Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }

    private func expectBridges(_ ui: UIColor, _ rgba: AppColorRGBA) {
        let (r, g, b, a) = channels(ui)
        #expect(abs(r - rgba.red) < 0.01)
        #expect(abs(g - rgba.green) < 0.01)
        #expect(abs(b - rgba.blue) < 0.01)
        #expect(abs(a - rgba.alpha) < 0.01)
    }

    @Test("forScheme(.dark) 13 字段桥 = AppPalette.dark")
    func darkBridge() {
        let u = UIChartPalette.forScheme(.dark); let p = AppPalette.dark
        expectBridges(u.candleUp, p.candleUp);       expectBridges(u.candleDown, p.candleDown)
        expectBridges(u.ma66, p.ma66);               expectBridges(u.bollLine, p.bollLine)
        expectBridges(u.macdDIF, p.macdDIF);         expectBridges(u.macdDEA, p.macdDEA)
        expectBridges(u.macdBarPositive, p.macdBarPositive); expectBridges(u.macdBarNegative, p.macdBarNegative)
        expectBridges(u.profitRed, p.profitRed);     expectBridges(u.lossGreen, p.lossGreen)
        expectBridges(u.background, p.background);    expectBridges(u.gridLine, p.gridLine)
        expectBridges(u.text, p.text)
    }

    @Test("forScheme(.light) 13 字段桥 = AppPalette.light")
    func lightBridge() {
        let u = UIChartPalette.forScheme(.light); let p = AppPalette.light
        expectBridges(u.candleUp, p.candleUp);       expectBridges(u.candleDown, p.candleDown)
        expectBridges(u.ma66, p.ma66);               expectBridges(u.bollLine, p.bollLine)
        expectBridges(u.macdDIF, p.macdDIF);         expectBridges(u.macdDEA, p.macdDEA)
        expectBridges(u.macdBarPositive, p.macdBarPositive); expectBridges(u.macdBarNegative, p.macdBarNegative)
        expectBridges(u.profitRed, p.profitRed);     expectBridges(u.lossGreen, p.lossGreen)
        expectBridges(u.background, p.background);    expectBridges(u.gridLine, p.gridLine)
        expectBridges(u.text, p.text)
    }

    @Test("light/dark UIColor 真不同（防退化为单集）")
    func uiDistinct() {
        let l = UIChartPalette.light, d = UIChartPalette.dark
        let (lr, _, _, _) = channels(l.background); let (dr, _, _, _) = channels(d.background)
        #expect(abs(lr - dr) > 0.5)
    }

    @MainActor
    @Test("trait dark → 选 dark 集 / trait light → 选 light 集（currentPalette 选取链）")
    func traitSelectsPalette() {
        let tc = ThemeController()
        let darkSel  = UIChartPalette.forScheme(tc.resolve(trait: UITraitCollection(userInterfaceStyle: .dark)))
        let lightSel = UIChartPalette.forScheme(tc.resolve(trait: UITraitCollection(userInterfaceStyle: .light)))
        let (dr, _, _, _) = channels(darkSel.background)
        let (lr, _, _, _) = channels(lightSel.background)
        #expect(abs(dr - 0.10) < 0.02)
        #expect(abs(lr - 0.98) < 0.02)
    }
}
#endif

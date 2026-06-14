import Testing
import Foundation
@testable import KlineTrainerContracts

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

    @Test("light 对比代理：前景 token vs 近白背景 通道差 ≥ 0.4")
    func lightContrast() {
        let bg = AppPalette.light.background
        let p = AppPalette.light
        for c in [p.text, p.candleUp, p.candleDown, p.ma66, p.bollLine, p.macdDIF, p.macdDEA] {
            #expect(c.maxChannelDiff(to: bg) >= 0.4)
        }
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

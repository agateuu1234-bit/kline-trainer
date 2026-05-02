import Testing
import Foundation
@testable import KlineTrainerContracts

// `DisplayMode` 在 Models.swift（M0.3）已定义；F2 测试角度复用 baseline，不 redeclare（D-6）。
@Suite("DisplayMode (F2 视角；类型在 M0.3 Models.swift)")
struct DisplayModeF2Tests {

    @Test("3 case rawValue 字面对齐 (M0.3 baseline)")
    func rawValues() {
        #expect(DisplayMode.system.rawValue == "system")
        #expect(DisplayMode.light.rawValue == "light")
        #expect(DisplayMode.dark.rawValue == "dark")
    }

    @Test("rawValue init mapping + 未知 rawValue → nil")
    func rawValueInit() {
        #expect(DisplayMode(rawValue: "system") == .system)
        #expect(DisplayMode(rawValue: "light") == .light)
        #expect(DisplayMode(rawValue: "dark") == .dark)
        #expect(DisplayMode(rawValue: "unknown") == nil)
    }
}

@Suite("AppColorScheme")
struct AppColorSchemeTests {

    @Test("2 case 全列出")
    func cases() {
        #expect(AppColorScheme.allCases == [.light, .dark])
    }

    @Test("Equatable")
    func equality() {
        #expect(AppColorScheme.light != AppColorScheme.dark)
        #expect(AppColorScheme.light == AppColorScheme.light)
    }
}

@Suite("resolveColorScheme")
struct ResolveColorSchemeTests {

    @Test(".system + traitIsDark=false → .light")
    func systemLight() {
        #expect(resolveColorScheme(displayMode: .system, traitIsDark: false) == .light)
    }

    @Test(".system + traitIsDark=true → .dark")
    func systemDark() {
        #expect(resolveColorScheme(displayMode: .system, traitIsDark: true) == .dark)
    }

    @Test(".light forced 永远 .light（忽略 traitIsDark）")
    func lightForced() {
        #expect(resolveColorScheme(displayMode: .light, traitIsDark: true) == .light)
        #expect(resolveColorScheme(displayMode: .light, traitIsDark: false) == .light)
    }

    @Test(".dark forced 永远 .dark（忽略 traitIsDark）")
    func darkForced() {
        #expect(resolveColorScheme(displayMode: .dark, traitIsDark: true) == .dark)
        #expect(resolveColorScheme(displayMode: .dark, traitIsDark: false) == .dark)
    }

    @Test(".system + traitIsDark=nil（unspecified）→ .light（D-7 UIKit 默认）")
    func systemUnspecified() {
        #expect(resolveColorScheme(displayMode: .system, traitIsDark: nil) == .light)
    }

    @Test(".light/.dark forced 忽略 nil traitIsDark")
    func forcedIgnoreNilTrait() {
        #expect(resolveColorScheme(displayMode: .light, traitIsDark: nil) == .light)
        #expect(resolveColorScheme(displayMode: .dark, traitIsDark: nil) == .dark)
    }
}

// MARK: - AppColorRGBA / AppColorTokens 纯值断言（D-11 — macOS swift test 直跑，
// 不再依赖 UIKit-only typecheck-only block；assertion 真实执行）

@Suite("AppColorRGBA struct 不变量")
struct AppColorRGBAStructTests {

    @Test("init 默认 alpha=1.0 + init(white:) 派生 R=G=B + Equatable")
    func initAndEquality() {
        let c1 = AppColorRGBA(red: 0.1, green: 0.2, blue: 0.3)
        #expect(c1.alpha == 1.0)
        let c2 = AppColorRGBA(white: 0.5, alpha: 0.25)
        #expect(c2.red == 0.5); #expect(c2.green == 0.5); #expect(c2.blue == 0.5); #expect(c2.alpha == 0.25)
        #expect(AppColorRGBA(red: 0.5, green: 0.5, blue: 0.5) == AppColorRGBA(white: 0.5))
    }

    @Test("maxChannelDiff：self == 0；通道差取最大值")
    func maxChannelDiffLogic() {
        let a = AppColorRGBA(red: 0.5, green: 0.5, blue: 0.5)
        #expect(a.maxChannelDiff(to: a) == 0)
        let b = AppColorRGBA(red: 0.1, green: 0.5, blue: 0.9)
        let c = AppColorRGBA(red: 0.2, green: 0.5, blue: 0.4)
        #expect(abs(b.maxChannelDiff(to: c) - 0.5) < 1e-9)
    }

    @Test("D-12 init clamp：越界 RGBA 值静默 clamp 到 [0,1]")
    func clampOutOfRange() {
        let c = AppColorRGBA(red: -0.5, green: 1.5, blue: 0.5, alpha: 2.0)
        #expect(c.red == 0); #expect(c.green == 1); #expect(c.blue == 0.5); #expect(c.alpha == 1)
        let w = AppColorRGBA(white: 2.0, alpha: -1.0)
        #expect(w.red == 1); #expect(w.green == 1); #expect(w.blue == 1); #expect(w.alpha == 0)
    }
}

@Suite("AppColorTokens 13 const + alias + RGB 字面 + contrast")
struct AppColorTokensTests {

    @Test("v1.5 §2 MACD：DIF 白 (1,1,1) / DEA 黄 (1.00, 0.84, 0.20)")
    func macdLiterals() {
        #expect(AppColorTokens.macdDIF == AppColorRGBA(white: 1.0))
        let dea = AppColorTokens.macdDEA
        #expect(abs(dea.red - 1.00) < 0.01)
        #expect(abs(dea.green - 0.84) < 0.01)
        #expect(abs(dea.blue - 0.20) < 0.01)
    }

    @Test("D-3 派生不变量：MACD bar / 盈亏 与 candle 同色簇")
    func derivedAlias() {
        #expect(AppColorTokens.macdBarPositive == AppColorTokens.candleUp)
        #expect(AppColorTokens.macdBarNegative == AppColorTokens.candleDown)
        #expect(AppColorTokens.profitRed == AppColorTokens.candleUp)
        #expect(AppColorTokens.lossGreen == AppColorTokens.candleDown)
    }

    /// D-9/D-10 contrast 不变量：高亮指标 + 文字 vs chart bg 任一通道差 ≥ 0.4。
    @Test("D-9/D-10 contrast：DIF/DEA/bollLine/text vs background 通道差 ≥ 0.4")
    func chartPaletteContrastWithBackground() {
        let bg = AppColorTokens.background
        for c in [AppColorTokens.macdDIF, AppColorTokens.macdDEA,
                  AppColorTokens.bollLine, AppColorTokens.text] {
            #expect(c.maxChannelDiff(to: bg) >= 0.4)
        }
    }

    @Test("13 token 计数")
    func thirteenTokens() {
        let all: [AppColorRGBA] = [
            AppColorTokens.candleUp, AppColorTokens.candleDown, AppColorTokens.ma66,
            AppColorTokens.bollLine, AppColorTokens.macdDIF, AppColorTokens.macdDEA,
            AppColorTokens.macdBarPositive, AppColorTokens.macdBarNegative,
            AppColorTokens.profitRed, AppColorTokens.lossGreen,
            AppColorTokens.background, AppColorTokens.gridLine, AppColorTokens.text,
        ]
        #expect(all.count == 13)
    }
}

// MARK: - UIKit shell 层 tests（`#if canImport(UIKit)` gated；macOS 跳过；iOS 探针法 typecheck）

#if canImport(UIKit)
import UIKit

@Suite("ThemeController")
@MainActor
struct ThemeControllerTests {

    @Test("默认 displayMode == .system")
    func defaultMode() {
        let c = ThemeController()
        #expect(c.displayMode == .system)
    }

    @Test("resolve(trait:) .system + dark trait → .dark")
    func resolveSystemDark() {
        let c = ThemeController()
        let trait = UITraitCollection(userInterfaceStyle: .dark)
        #expect(c.resolve(trait: trait) == .dark)
    }

    @Test("resolve(trait:) .light forced 忽略 dark trait")
    func resolveLightForced() {
        let c = ThemeController()
        c.displayMode = .light
        let trait = UITraitCollection(userInterfaceStyle: .dark)
        #expect(c.resolve(trait: trait) == .light)
    }

    @Test("resolve(trait:) .dark forced 忽略 light trait")
    func resolveDarkForced() {
        let c = ThemeController()
        c.displayMode = .dark
        let trait = UITraitCollection(userInterfaceStyle: .light)
        #expect(c.resolve(trait: trait) == .dark)
    }

    @Test("resolve(trait:) .system + .unspecified → .light（D-7：UIKit 未传播状态默认）")
    func resolveSystemUnspecified() {
        let c = ThemeController()
        let trait = UITraitCollection(userInterfaceStyle: .unspecified)
        #expect(c.resolve(trait: trait) == .light)
    }
}

@Suite("UIColor(rgba:) bridge + AppColor 13 const")
struct AppColorBridgeTests {

    @Test("UIColor(rgba:) 桥接保持通道值 + 13 const 全 = token 桥接（D-11）")
    func bridgeFidelityAndAllConstants() {
        let pairs: [(UIColor, AppColorRGBA)] = [
            (AppColor.candleUp, AppColorTokens.candleUp),
            (AppColor.candleDown, AppColorTokens.candleDown),
            (AppColor.ma66, AppColorTokens.ma66),
            (AppColor.bollLine, AppColorTokens.bollLine),
            (AppColor.macdDIF, AppColorTokens.macdDIF),
            (AppColor.macdDEA, AppColorTokens.macdDEA),
            (AppColor.macdBarPositive, AppColorTokens.macdBarPositive),
            (AppColor.macdBarNegative, AppColorTokens.macdBarNegative),
            (AppColor.profitRed, AppColorTokens.profitRed),
            (AppColor.lossGreen, AppColorTokens.lossGreen),
            (AppColor.background, AppColorTokens.background),
            (AppColor.gridLine, AppColorTokens.gridLine),
            (AppColor.text, AppColorTokens.text),
        ]
        #expect(pairs.count == 13)
        for (ui, rgba) in pairs {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            #expect(abs(Double(r) - rgba.red) < 0.01)
            #expect(abs(Double(g) - rgba.green) < 0.01)
            #expect(abs(Double(b) - rgba.blue) < 0.01)
            #expect(abs(Double(a) - rgba.alpha) < 0.01)
        }
    }
}
#endif

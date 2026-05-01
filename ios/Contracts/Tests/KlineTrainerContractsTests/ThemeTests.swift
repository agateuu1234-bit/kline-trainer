import Testing
import Foundation
@testable import KlineTrainerContracts

// `DisplayMode` 在 Models.swift（M0.3）已定义；F2 测试角度复用 baseline，不 redeclare（D-6）。
// M0.3 baseline 不带 CaseIterable，所以用 rawValue mapping 覆盖 3 case。
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
}

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
}
#endif

#if canImport(UIKit)

@Suite("AppColor constants")
struct AppColorConstantsTests {

    @Test("13 default UIColor 全 non-nil + resolveColor 不崩")
    func allConstantsResolvable() {
        let allColors: [UIColor] = [
            AppColor.candleUp, AppColor.candleDown,
            AppColor.ma66, AppColor.bollLine,
            AppColor.macdDIF, AppColor.macdDEA,
            AppColor.macdBarPositive, AppColor.macdBarNegative,
            AppColor.profitRed, AppColor.lossGreen,
            AppColor.background, AppColor.gridLine, AppColor.text,
        ]
        #expect(allColors.count == 13)
        let trait = UITraitCollection(userInterfaceStyle: .light)
        for c in allColors {
            _ = c.resolvedColor(with: trait)
        }
    }

    @Test("v1.5 §2 MACD：DIF 白 / DEA 黄（RGB 字面）")
    func macdColorsLiteral() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        AppColor.macdDIF.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r == 1.0); #expect(g == 1.0); #expect(b == 1.0); #expect(a == 1.0)

        AppColor.macdDEA.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(abs(r - 1.00) < 0.01)
        #expect(abs(g - 0.84) < 0.01)
        #expect(abs(b - 0.20) < 0.01)
    }

    @Test("D-3 派生不变量：MACD bar / 盈亏 与 candle 同色簇")
    func derivedColorsAlias() {
        #expect(AppColor.macdBarPositive == AppColor.candleUp)
        #expect(AppColor.macdBarNegative == AppColor.candleDown)
        #expect(AppColor.profitRed == AppColor.candleUp)
        #expect(AppColor.lossGreen == AppColor.candleDown)
    }
}
#endif

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

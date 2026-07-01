// ios/Contracts/Tests/KlineTrainerContractsTests/UI/HomeViewSourceCompatTests.swift
// Spec: docs/superpowers/specs/2026-06-30-tap-anywhere-settings-popover-design.md §0/§3.1/§4（codex spec-R6-H1）
// 类型标识守卫：HomeView 必须保持非泛型 concrete 类型。
// `let _: HomeView`（bare 类型标识）—— 一旦泛型化为 HomeView<...> 本文件即编译失败（codex spec-R6-H1）。
// 注：WB-R4 功能退路——旧 5 参 init 保留为可用 legacy sheet 路由（去 deprecated）；本守卫改用旧 5 参 init 构造，
// 仍把 HomeView 当**裸 concrete 类型**引用以守类型标识（一旦泛型化或重加 deprecated 即编译错/告警）。
import SwiftUI
import Testing
@testable import KlineTrainerContracts

@Suite("HomeView source compatibility")
struct HomeViewSourceCompatTests {

    private func makeContent() -> HomeContent {
        HomeContent(statistics: (totalCount: 0, winCount: 0, currentCapital: 100_000),
                    configuredCapital: 100_000, records: [],
                    hasPending: false, hasCachedSets: true, timeZone: .current)
    }

    @Test("HomeView 为 bare concrete 类型 + 旧 5 参 init 可用无 deprecation（WB-R4 功能退路 / codex spec-R6-H1）")
    @MainActor func bareConcreteTypeAndLegacyInit() {
        let _: HomeView = HomeView(content: makeContent(),
                                   onStartTraining: {}, onContinueTraining: {},
                                   onSelectRecord: { _ in }, onOpenSettings: {})
    }
}

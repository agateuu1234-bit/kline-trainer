// Kline Trainer Swift Contracts — C8a ChartContainerView 编译反射（Catalyst build gate）
// Mirror: KLineViewCompileTests（UIKit-only；macOS host 编译为空）
#if canImport(UIKit)
import Testing
import SwiftUI
import UIKit
@testable import KlineTrainerContracts

@Suite("ChartContainerView 编译反射（Catalyst compile gate）")
struct ChartContainerViewCompileTests {

    @Test("ChartContainerView 可构造 + 符合 UIViewRepresentable")
    @MainActor
    func instantiates() {
        let engine = TrainingEngine.preview()
        let view = ChartContainerView(panel: .upper, engine: engine)
        #expect(view.panel == .upper)
        let _: any UIViewRepresentable = view   // 编译期符合性
    }
}
#endif

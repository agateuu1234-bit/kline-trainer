// Tests/KlineTrainerContractsTests/Render/DrawingAutosaveTriggersSpikeTests.swift
// task-8 spike（可选 Step 1）：D94 目前只有结构证据（G6 源码守卫，见
// DrawingInteractionUISourceGuardTests.swift）——`.onChange(of: engine.drawingSession.defaultStyle)`
// 是否**真的**在 SwiftUI 渲染时触发 autosave 从未被行为证据覆盖，因为 host `swift test` 根本不编译
// TrainingView（UIKit-gated，见 DrawingLayoutInvariantTests.swift:9-28 记录的四条测量技术选型踩坑）。
//
// 本文件把两条 autosave 触发（既有 drawingsRevision + 本片新增 defaultStyle）抽出的
// `DrawingAutosaveTriggersModifier`（纯 SwiftUI ViewModifier，无 UIViewRepresentable）装进一个最小纯
// SwiftUI 宿主，用 `ImageRenderer`（本仓 DrawingTapHitShieldTests 已验证可靠的 headless 渲染入口）
// 驱动：**同一个** ImageRenderer 实例、重新赋值 `.content`（保留 view 身份/onChange 追踪基线——该手法
// 已在 DrawingTapHitShieldTests.toggleWithIdenticalGeometryEventuallySettles 头部注释验证过①保留身份
// ②onPreferenceChange 只在真变化时回调），再 `drainAutosaveForTesting()` 排空在飞写，
// 用 `InMemoryPendingTrainingRepository.saveCount` 断言真的发生了一次落盘写入 —— 不是 spy 闭包，是
// 走 TrainingSessionCoordinator 真实 autosave 路径的行为证据。
#if canImport(UIKit)
import Testing
import SwiftUI
@testable import KlineTrainerContracts

/// 最小纯 SwiftUI 宿主：只挂 DrawingAutosaveTriggersModifier，无 ChartContainerView/Picker 等
/// UIViewRepresentable —— 避开 DrawingLayoutInvariantTests 头部注释记录的「整壳渲染塌成
/// frame=(0,0,0,0)」坑（那条坑只在渲染含 UIViewRepresentable 的整壳时出现，本宿主不含）。
private struct AutosaveTriggerSpikeHost: View {
    let engine: TrainingEngine
    let lifecycle: TrainingSessionLifecycle
    var body: some View {
        Color.clear.modifier(DrawingAutosaveTriggersModifier(engine: engine, lifecycle: lifecycle))
    }
}

@Suite("task-8 spike：D94 行为证据 —— headless ImageRenderer 下 onChange(defaultStyle) 是否真触发 autosave")
@MainActor
struct DrawingAutosaveTriggersSpikeTests {

    @Test("D94 spike：defaultStyle 变化 → onChange 触发 → coordinator 真落盘一次")
    func onChangeOfDefaultStyleTriggersRealAutosave() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        let lifecycle = TrainingSessionLifecycle(engine: engine, coordinator: coord)

        let renderer = ImageRenderer(content: AutosaveTriggerSpikeHost(engine: engine, lifecycle: lifecycle))
        renderer.scale = 1
        _ = renderer.uiImage                      // 首次渲染：建立 onChange 追踪基线，不应触发（无「旧值」可比）
        await coord.drainAutosaveForTesting()
        #expect(pending.saveCount == 0, "首次渲染不该触发 autosave —— 基线前提不成立，后续差分无意义")

        var s = DrawingDefaultStyle()
        s.thickness = 4
        engine.drawingSession.setDefaultStyle(s)   // 引用类型 engine 原地变更，view 身份不变
        renderer.content = AutosaveTriggerSpikeHost(engine: engine, lifecycle: lifecycle)  // 同一 renderer，重新赋值
        _ = renderer.uiImage
        await coord.drainAutosaveForTesting()

        #expect(pending.saveCount == 1,
                "D94：.onChange(of: engine.drawingSession.defaultStyle) 未在 headless ImageRenderer 下触发 autosave")
    }

    @Test("对照组：既有 drawingsRevision 触发同一路径（供判定 spike 手法本身是否可靠）")
    func onChangeOfDrawingsRevisionTriggersRealAutosave() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        let lifecycle = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        let sample = PIFixtures.sampleDrawing()
        engine.injectDrawingsForTesting([sample])   // 不动 drawingsRevision（同文件既有注释），故仍是干净基线

        let renderer = ImageRenderer(content: AutosaveTriggerSpikeHost(engine: engine, lifecycle: lifecycle))
        renderer.scale = 1
        _ = renderer.uiImage
        await coord.drainAutosaveForTesting()
        #expect(pending.saveCount == 0, "首次渲染不该触发 autosave —— 基线前提不成立，后续差分无意义")

        let deleted = engine.deleteDrawing(id: sample.id)   // 真实生产写入面：删除即递增 drawingsRevision
        try #require(deleted, "deleteDrawing 未生效 —— 对照组前提不成立，后续差分无意义")
        renderer.content = AutosaveTriggerSpikeHost(engine: engine, lifecycle: lifecycle)
        _ = renderer.uiImage
        await coord.drainAutosaveForTesting()

        #expect(pending.saveCount == 1,
                "对照组失手：连既有已知在生产中工作的 drawingsRevision 触发都测不出来 —— spike 手法本身不可靠，非 D94 特有问题")
    }
}
#endif

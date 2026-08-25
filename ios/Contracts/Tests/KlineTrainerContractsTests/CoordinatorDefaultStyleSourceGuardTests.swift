// CoordinatorDefaultStyleSourceGuardTests.swift
// 画线 P1b 本局默认持久化 Task 6：G1 + G3 源码守卫（D94-D96）。
// ⚠️ 必须落在 KlineTrainerContractsTests——SourceGuardScanner（callSiteCount/squeeze/squeezedSource/
//    contractsDirForGuards）是该测试模块内的 internal 顶层函数，跨 target 取不到。
import Testing
@testable import KlineTrainerContracts

/// G1（D96 + 自动选中 PR 的 D86）：`setDefaultStyle` 的调用点**恰好 4 个** ——
/// `DrawingEditRouter.applyPanelStyleMutation` **2 处**（D86：画线态分支写「本局默认」+
/// 无选中分支写「下一条线的默认」）+ `resumePending` + `resumePendingReplay`（两处续训种子）。
/// ⚠️ 3→4 是**自动选中 PR 有意为之**：D86 让画线态的一次改样式同时写「那条线」与「本局默认」，
///    这是新增的第四条写默认路径，已按本守卫头注的要求重审并接受（spec §6.1 / §6.3）。
/// 多于 4 ⇒ 又出现了新的写默认路径，必须再次回来重审；
/// 少于 4 ⇒ 有一处没接上（种子漏接，或 D86 的某个分支没写默认）。
@Test func g1_setDefaultStyle_has_exactly_four_call_sites() throws {
    let sites = try callSiteCount("setDefaultStyle(")
    let total = sites.reduce(0) { $0 + $1.count }
    #expect(total == 4, "setDefaultStyle 调用点应恰好 4 个，实测 \(total)：\(sites.map { "\($0.file)×\($0.count)" })")
    // 逐文件计数（只数总数会漏「两处挤成一处、另一处多出一次」这种互相抵消的坏状态）
    #expect(sites.first { $0.file.hasSuffix("DrawingEditRouter.swift") }?.count == 2,
            "路由里应恰好 2 处（D86 画线态分支 + 无选中分支），实测：\(sites.map { "\($0.file)×\($0.count)" })")
    #expect(sites.first { $0.file.hasSuffix("TrainingSessionCoordinator.swift") }?.count == 2,
            "coordinator 里应恰好 2 处（resumePending + resumePendingReplay）")
}

/// G3（D95）：`replayBaseline` 的元组构造点**恰好 3 处**，且**每一处都带 defaultStyle 分量**。
/// 只数处数挡不住「加了字段但某一处基线捕获忘了带」—— 那正是 clean-skip 静默失效的形态。
@Test func g3_replayBaseline_captures_all_include_defaultStyle() throws {
    let path = contractsDirForGuards
        .appendingPathComponent("Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift").path
    let src = try squeezedSource(path)
    let assigns = src.components(separatedBy: squeeze("replayBaseline = (")).count - 1
    #expect(assigns == 3, "replayBaseline 的元组构造点应恰好 3 处，实测 \(assigns)")

    // 每一处都必须带 defaultStyle：构造点数 == 「构造点且其后不远处出现 defaultStyle」的数量
    let withStyle = src.components(separatedBy: squeeze("replayBaseline = ("))
        .dropFirst()
        .filter { $0.prefix(400).contains(squeeze("defaultStyle")) }
        .count
    #expect(withStyle == 3, "有 \(assigns - withStyle) 处 replayBaseline 捕获没带 defaultStyle（D95 会静默失效）")
}

/// G1 / G3 的**双向自检**：不存在的符号必须数出 0，样本里缺分量必须被判出来
///（防「pattern 打错字 → 恒 0 / 恒真 → 守卫恒绿」）。
@Test func g1_g3_scanners_are_not_vacuous() throws {
    #expect(try callSiteCount("setDefaultStyleZZZ(").isEmpty)
    let sample = squeeze("replayBaseline = (engine.tick.globalTickIndex, engine.tradeOperations.count, sig, up, low)")
    #expect(!sample.contains(squeeze("defaultStyle")), "缺分量的样本必须不满足 G3 的内容条")
}

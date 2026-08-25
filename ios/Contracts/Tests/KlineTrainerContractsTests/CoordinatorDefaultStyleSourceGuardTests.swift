// CoordinatorDefaultStyleSourceGuardTests.swift
// 画线 P1b 本局默认持久化 Task 6：G1 + G3 源码守卫（D94-D96）。
// ⚠️ 必须落在 KlineTrainerContractsTests——SourceGuardScanner（callSiteCount/squeeze/squeezedSource/
//    contractsDirForGuards）是该测试模块内的 internal 顶层函数，跨 target 取不到。
import Testing
@testable import KlineTrainerContracts

/// G1（D96 + 自动选中 PR 的 D86 + 1b-ii 撤销 PR 的 D102）：`setDefaultStyle` 的调用点**恰好 5 个** ——
/// `DrawingEditRouter.applyPanelStyleMutation` **2 处** + `resumePending` + `resumePendingReplay`
/// + **`TrainingEngine.applyUndoEntry` 1 处**（撤销 / 前进时把本局默认一并回滚 / 一并重做）。
/// ⚠️ 4→5 是**1b-ii 撤销 PR 有意为之**：D102 让「画线态改样式」的两处写入成为一个可撤销动作，
///    撤销执行单点因此必须能写回默认。这是第五条写默认路径，已按本守卫头注的要求重审并接受。
/// 多于 5 ⇒ 又出现了新的写默认路径，必须再次回来重审；
/// 少于 5 ⇒ 有一处没接上（种子漏接、D86 某分支没写默认，或撤销漏了默认那一半 = 成对回滚失效）。
@Test func g1_setDefaultStyle_has_exactly_five_call_sites() throws {
    let sites = try callSiteCount("setDefaultStyle(")
    let total = sites.reduce(0) { $0 + $1.count }
    #expect(total == 5, "setDefaultStyle 调用点应恰好 5 个，实测 \(total)：\(sites.map { "\($0.file)×\($0.count)" })")
    #expect(sites.first { $0.file.hasSuffix("DrawingEditRouter.swift") }?.count == 2,
            "路由里应恰好 2 处（D86 画线态分支 + 无选中分支），实测：\(sites.map { "\($0.file)×\($0.count)" })")
    #expect(sites.first { $0.file.hasSuffix("TrainingSessionCoordinator.swift") }?.count == 2,
            "coordinator 里应恰好 2 处（resumePending + resumePendingReplay）")
    #expect(sites.first { $0.file.hasSuffix("TrainingEngine.swift") }?.count == 1,
            "引擎里应恰好 1 处（applyUndoEntry 的成对回滚）—— 0 处 = 撤销没回滚默认（D102 失效）")
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

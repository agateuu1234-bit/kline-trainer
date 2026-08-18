// CoordinatorDefaultStyleSourceGuardTests.swift
// 画线 P1b 本局默认持久化 Task 6：G1 + G3 源码守卫（D94-D96）。
// ⚠️ 必须落在 KlineTrainerContractsTests——SourceGuardScanner（callSiteCount/squeeze/squeezedSource/
//    contractsDirForGuards）是该测试模块内的 internal 顶层函数，跨 target 取不到。
import Testing
@testable import KlineTrainerContracts

/// G1（D96）：`setDefaultStyle` 的调用点**恰好 3 个** ——
/// `DrawingEditRouter`（面板写入，既有）+ `resumePending` + `resumePendingReplay`（本片新增两处种子）。
/// 多于 3 ⇒ 出现了第四条写默认的路径，必须回来重审「哪些时机允许改本局默认」；
/// 少于 3 ⇒ 有一处种子没接上（正是 M9 / M10 要造的形态）。
@Test func g1_setDefaultStyle_has_exactly_three_call_sites() throws {
    let sites = try callSiteCount("setDefaultStyle(")
    let total = sites.reduce(0) { $0 + $1.count }
    #expect(total == 3, "setDefaultStyle 调用点应恰好 3 个，实测 \(total)：\(sites.map { "\($0.file)×\($0.count)" })")
    for needle in ["DrawingEditRouter.swift", "TrainingSessionCoordinator.swift"] {
        #expect(sites.contains { $0.file.hasSuffix(needle) },
                "\(needle) 里应有 setDefaultStyle 调用点，实测：\(sites.map(\.file))")
    }
    // 两处 resume 都在 coordinator 同一个文件里 ⇒ 该文件应占 2 次（只数总数会漏「两处种子挤成一处」）
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
